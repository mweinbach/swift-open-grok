// LiveSchedulerHost.swift
//
// The session-actor half of the scheduler: the port of `SchedulerActor`'s
// timer + in-memory task ownership (`xai-grok-tools/src/implementations/
// grok_build/scheduler/actor.rs`) fused with the pager's scheduled-task
// display map (`agent.session.scheduled_tasks`, `app/agent.rs:804`). Upstream
// splits the two across a process boundary and reconciles them with
// `ScheduledTaskCreated`/`Fired`/`Removed` notifications; this port is one
// process, so the store the tools mutate IS the store `/tasks` renders — the
// display can never lag or disagree with the scheduler.
//
// Fires ride a DEDICATED sleep-until-due timer (`Task.sleep` until the
// earliest `nextFireAt`, re-armed on every create/update/delete/fire), the
// port of the actor's `tokio::time::sleep(next_fire)` select arm
// (`actor.rs:185-204`). Never the PagerMotion UI ticker, never the
// interjection seam: the UI ticker parks when the screen is still, and the
// interjection seam only exists mid-turn — both would silently drop fires
// exactly when the session is idle, which is when a loop matters.
//
// Determinism: the clock is injected and `fireDue(now:)` is the public fire
// trigger the timer itself calls. A test constructs the host with a fixed
// clock and calls `fireDue(now:)` with a due instant — no test ever sleeps a
// real interval to see a fire.

import Foundation
import OpenGrokScheduler

/// One in-session scheduler fire, handed to the fire sink. The payload of
/// upstream's `x.ai/scheduled_task_inject_prompt` notification
/// (`xai-grok-shell/src/tools/notification_bridge.rs:690-696`): the RAW
/// prompt — framing for the model happens at the send seam, the UI shows
/// the raw text.
struct LiveSchedulerFire: Sendable, Equatable {
    var taskID: String
    var prompt: String
    var humanSchedule: String
    /// RFC 3339 next fire; `nil` when this fire removed the task.
    var nextFireAt: String?
    /// The loop subagent this fire spawned — upstream's
    /// `ScheduledTaskFired.subagent_id` (actor.rs:485-498). `nil` for an
    /// in-session Cron fire; only fires with `nil` reach the Cron sink,
    /// exactly as upstream's inject-prompt notification is gated on
    /// `subagent_id.is_none()` (notification_bridge.rs:689).
    var subagentID: String? = nil
}

/// What the previous loop iteration is doing right now, as the spawn seam
/// reports it. The port of the actor's `SubagentEvent::Query` snapshot read
/// (actor.rs:522-566): each case maps onto one arm of upstream's decision.
enum LiveSchedulerPreviousIteration: Sendable, Equatable {
    /// `Initializing`/`Running` — this fire is skipped (actor.rs:568-580).
    case running
    /// `Completed { output }` — the chain anchor is usable and `output`
    /// seeds the fresh-restart summary (actor.rs:620-625).
    case completed(output: String)
    /// Snapshot absent, failed, or cancelled: the anchor is unusable and
    /// the next iteration starts a fresh chain (actor.rs:625-632).
    case gone
    /// The query could not be answered at all — upstream's channel-closed /
    /// timeout arms (actor.rs:538-563). Skip rather than risk running two
    /// iterations at once.
    case unknown
}

/// One Detached loop-iteration spawn, handed to the spawn seam. Field-for-
/// field the parts of upstream's `SubagentRequest` the fire path decides
/// (actor.rs:657-680): the framed prompt, the `loop:` description, the
/// pre-assigned subagent id, and the resume anchor.
struct LiveSchedulerLoopSpawn: Sendable, Equatable {
    var subagentID: String
    var taskID: String
    var framedPrompt: String
    var description: String
    /// `resume_from` — the previous iteration's subagent id when the chain
    /// continues; `nil` for a fresh chain.
    var resumeFrom: String?
}

/// The Detached fire seam: how a due fire reaches the session's real
/// subagent host. Installed by the composition alongside the Cron fire
/// sink; absent (headless, tests without a subagent surface) every fire
/// falls back to the in-session Cron path, upstream's
/// `events.zip(session)`-is-`None` arm (actor.rs:420-423).
struct LiveSchedulerLoopSpawner: Sendable {
    /// Query the previous iteration — `SubagentEvent::Query`
    /// (actor.rs:522-566).
    var probePrevious: @Sendable (_ subagentID: String) async -> LiveSchedulerPreviousIteration
    /// Dispatch the spawn. `true` means the subagent was registered;
    /// `false` is upstream's failed `SubagentEvent::Spawn` send
    /// (actor.rs:682-702), which falls the fire back to the Cron path.
    var spawn: @Sendable (_ request: LiveSchedulerLoopSpawn) async -> Bool
}

/// Per-session scheduler runtime: task store, sleep-until-due timer, and the
/// in-session fire delivery seam.
actor LiveSchedulerHost {
    private var state = SchedulerState()
    private let clock: @Sendable () -> Date

    /// The resolved `[scheduler] background_loops` value, read at fire time —
    /// the port of the actor's `SchedulerBackgroundLoops` resource read
    /// (actor.rs:414-416). Resolved once at session build (upstream resolves
    /// at session spawn, acp_session_impl/spawn.rs:1208-1212, and rebuilds
    /// refresh the resource); this port has no mid-session rebuild seam, so
    /// the value is construction-fixed — recorded divergence.
    private let backgroundLoopsEnabled: Bool

    /// Delivers an in-session fire into the interactive controller's prompt
    /// queue. Installed by the composition after the controller exists —
    /// upstream has the same window and polls for wiring before firing due
    /// tasks (`await_subagent_wiring_for_due_tasks`, actor.rs:224-253); here
    /// the timer simply stays parked until the sink lands, so a due task
    /// fires on installation instead of being lost.
    private var fireSink: (@Sendable (LiveSchedulerFire) async -> Void)?

    /// The Detached loop-subagent spawn seam. Installed with the fire sink;
    /// while absent, every fire — whatever `background_loops` says — runs
    /// the in-session Cron path, the analog of the actor finding no
    /// `SubagentEventSender`/`SessionIdResource` (actor.rs:420-423).
    private var loopSpawner: LiveSchedulerLoopSpawner?

    /// The armed sleep-until-due task, if any, and the generation stamp that
    /// invalidates a stale one: every re-arm bumps the generation, so a timer
    /// that slept across a delete cannot fire against the new schedule.
    private var timer: Task<Void, Never>?
    private var timerGeneration: UInt64 = 0

    /// Display-facing creation instants, keyed by task id. Upstream's pager
    /// stamps `Instant::now()` when the `ScheduledTaskCreated` notification
    /// arrives (`acp_handler/background.rs:347`); a `fireImmediately` task's
    /// stored `createdAt` is backdated one interval, so the display age must
    /// not read it.
    private var displayCreatedAt: [String: Date] = [:]

    /// Provisional `/loop` previews, shown until `scheduler_create` lands the
    /// real row. The port of the pager's `provisional-` entries
    /// (`app/dispatch/prompt.rs:779-794`).
    private var provisional: [ScheduledTaskInfo] = []

    init(
        clock: @escaping @Sendable () -> Date = { Date() },
        backgroundLoopsEnabled: Bool = true
    ) {
        self.clock = clock
        self.backgroundLoopsEnabled = backgroundLoopsEnabled
    }

    /// Stop the timer. Called from the executor's shutdown so a dying session
    /// cannot fire into a torn-down controller.
    func shutdown() {
        timerGeneration &+= 1
        timer?.cancel()
        timer = nil
    }

    // MARK: - Fire delivery

    func setFireSink(_ sink: (@Sendable (LiveSchedulerFire) async -> Void)?) async {
        fireSink = sink
        // A task that came due while no sink existed fires now rather than
        // waiting one more interval.
        await fireDue(now: clock())
    }

    /// Install the Detached spawn seam. Installed BEFORE the fire sink at
    /// composition wiring: the sink install is the "wired" moment that
    /// delivers fires held over from startup, so a due Detached task must
    /// already see its spawner then — upstream's startup wiring-grace poll
    /// covers the same window (`await_subagent_wiring_for_due_tasks`,
    /// actor.rs:224-253).
    func setLoopSpawner(_ spawner: LiveSchedulerLoopSpawner?) {
        loopSpawner = spawner
    }

    /// A spawned loop iteration failed after registration: drop the chain
    /// anchor so the next fire starts fresh instead of resuming a broken
    /// chain. Port of the actor's spawn-result guard (actor.rs:707-730);
    /// matching on `lastSubagentId == spawnedSubagentID` rather than task id
    /// is upstream's own choice — a task whose anchor already moved on must
    /// not lose the newer chain.
    func clearChainAnchor(spawnedSubagentID: String) {
        guard let index = state.tasks.firstIndex(where: {
            $0.lastSubagentId == spawnedSubagentID
        }) else { return }
        state.tasks[index].lastSubagentId = nil
        state.tasks[index].iterationsSinceFresh = 0
    }

    /// Fire every task due at `now`, in store order, one at a time — the port
    /// of `fire_next_task`'s first-due selection (`actor.rs:283-285`) run to
    /// quiescence, which is what the actor's loop does via a zero next-fire
    /// delay. Returns the delivered fires so tests assert on what actually
    /// happened, never on a side effect three steps downstream.
    ///
    /// This is the deterministic fire trigger: the timer calls it with the
    /// injected clock's now, and tests call it directly with a fixed instant.
    @discardableResult
    func fireDue(now: Date) async -> [LiveSchedulerFire] {
        defer { rearmTimer() }
        guard fireSink != nil else { return [] }
        var fires: [LiveSchedulerFire] = []
        // A task fires at most once per pass. Guards the decoded-legacy
        // corner where `intervalSecs == 0` (parseInterval clamps at 60 on
        // create, but persisted state is not re-validated) would otherwise
        // stay due forever and spin this loop.
        var firedTaskIDs: Set<String> = []
        while let index = state.tasks.firstIndex(where: {
            $0.isDue(now: now) && !firedTaskIDs.contains($0.id)
        }) {
            var task = state.tasks[index]
            firedTaskIDs.insert(task.id)
            if task.recurring, task.isExpired(now: now) {
                // Expiry removes without firing (`actor.rs:395-404`).
                state.tasks.remove(at: index)
                displayCreatedAt.removeValue(forKey: task.id)
                continue
            }
            // Advance the cadence before delivering, so a re-entrant look at
            // the store never re-selects this fire (`actor.rs:406-408`).
            task.markFired(at: now)
            let shouldRemove = !task.recurring
            let nextFireAt: String?
            if task.recurring {
                state.tasks[index] = task
                nextFireAt = RFC3339.string(from: task.nextFireAt())
            } else {
                // A non-recurring task is removed at fire (`actor.rs:294,
                // 410-412`). `scheduler_create` refuses one-shots, so this
                // arm only serves decoded legacy state.
                state.tasks.remove(at: index)
                displayCreatedAt.removeValue(forKey: task.id)
                nextFireAt = nil
            }
            // Fire-mode selection, upstream's `spawn_deps` decision
            // (actor.rs:414-423): `foreground: true`, a task removed at
            // fire, background loops resolved off, or no spawn seam — each
            // forces the in-session Cron path. Everything else fires as a
            // Detached loop subagent.
            if let loopSpawner,
               backgroundLoopsEnabled,
               !task.foreground,
               !shouldRemove {
                guard let fire = await fireAsLoopSubagent(
                    firedTask: task,
                    nextFireAt: nextFireAt,
                    spawner: loopSpawner
                ) else {
                    // Skipped (actor.rs:453-466): the cadence already
                    // advanced, so this interval's fire is consumed; nothing
                    // is delivered anywhere.
                    continue
                }
                fires.append(fire)
                // A failed spawn dispatch falls back to the Cron inject path
                // — upstream's `LoopFireOutcome::Foreground` return from
                // `fire_as_loop_subagent` (actor.rs:701).
                if fire.subagentID == nil, let fireSink {
                    await fireSink(fire)
                }
                continue
            }
            let fire = LiveSchedulerFire(
                taskID: task.id,
                prompt: task.prompt,
                humanSchedule: intervalToHuman(task.intervalSecs),
                nextFireAt: nextFireAt
            )
            fires.append(fire)
            if let fireSink {
                await fireSink(fire)
            }
        }
        return fires
    }

    /// One Detached fire — the port of `fire_as_loop_subagent`
    /// (actor.rs:511-733). Returns `nil` for a skipped fire, a fire with
    /// `subagentID` set for a dispatched spawn, and a fire with `subagentID`
    /// nil for the Foreground fallback after a failed spawn dispatch.
    ///
    /// `firedTask` is the post-`markFired` snapshot. The probe and the spawn
    /// dispatch both suspend this actor, so every store mutation after an
    /// await re-finds the task by id — the port of upstream re-taking the
    /// resources lock, and the seam through which its deleted-mid-fire
    /// guard (actor.rs:648-650) stays reachable here.
    ///
    /// Deliberately absent (recorded): upstream's `LoopUnitActive`
    /// descendant guard (actor.rs:582-618) skips a fire while a descendant
    /// spawned BY the previous iteration still runs. This port's children
    /// cannot nest-spawn (`allowNestedSubagents: false`,
    /// LiveSubagentHost.spawn), so a previous iteration can have no live
    /// descendants and the guard has nothing to observe.
    private func fireAsLoopSubagent(
        firedTask: ScheduledTask,
        nextFireAt: String?,
        spawner: LiveSchedulerLoopSpawner
    ) async -> LiveSchedulerFire? {
        let humanSchedule = intervalToHuman(firedTask.intervalSecs)
        let preFireAnchor = firedTask.lastSubagentId
        let preFireIterations = firedTask.iterationsSinceFresh
        let preFireChainReset = firedTask.chainResetPending

        var prevCompletedOutput: String?
        if let previousID = preFireAnchor {
            switch await spawner.probePrevious(previousID) {
            case .unknown:
                // Cannot verify whether the previous iteration still runs —
                // skip rather than risk a double execution, upstream's
                // channel-closed and query-timeout arms (actor.rs:538-563).
                return nil
            case .running:
                // "Skipping loop fire: previous iteration still running"
                // (actor.rs:568-580).
                return nil
            case .completed(let output):
                prevCompletedOutput = output
            case .gone:
                prevCompletedOutput = nil
            }
        }

        // Chain bookkeeping (actor.rs:620-635): a pending reset starts
        // fresh with no summary; a chain due for restart (or an unusable
        // anchor) starts fresh seeded with the previous output truncated to
        // 600 chars; otherwise the chain resumes from the anchor.
        let chainDueForRestart = firedTask.iterationsSinceFresh >= loopFreshChainEvery
        let anchorUsable = prevCompletedOutput != nil && preFireAnchor != nil
        let resumeFrom: String?
        let priorSummary: String?
        let nextIterationsSinceFresh: UInt32
        if preFireChainReset {
            resumeFrom = nil
            priorSummary = nil
            nextIterationsSinceFresh = 1
        } else if chainDueForRestart || !anchorUsable {
            resumeFrom = nil
            priorSummary = prevCompletedOutput.map { truncateChars($0, maxChars: 600) }
            nextIterationsSinceFresh = 1
        } else {
            resumeFrom = preFireAnchor
            priorSummary = nil
            nextIterationsSinceFresh = preFireIterations + 1
        }

        // Upstream assigns `Uuid::now_v7()` (actor.rs:637); the port's spawn
        // surface already uses lowercase v4 ids (the recorded LiveSubagentHost
        // divergence), so the fire path matches it.
        let subagentID = UUID().uuidString.lowercased()
        let framedPrompt = formatLoopIterationPrompt(
            firedTask.prompt,
            taskID: firedTask.id,
            humanSchedule: humanSchedule,
            priorIterationSummary: priorSummary
        )
        let description = loopIterationDescription(
            prompt: firedTask.prompt,
            humanSchedule: humanSchedule
        )

        // Anchor update BEFORE the dispatch (actor.rs:645-655), so a
        // re-entrant fire sees the new chain head. The probe suspended this
        // actor: a delete may have interleaved, and a vanished task means
        // "deleted mid-fire; not spawning" (actor.rs:648-650).
        guard let index = state.tasks.firstIndex(where: { $0.id == firedTask.id }) else {
            return nil
        }
        state.tasks[index].lastSubagentId = subagentID
        state.tasks[index].iterationsSinceFresh = nextIterationsSinceFresh
        state.tasks[index].chainResetPending = false

        let spawned = await spawner.spawn(LiveSchedulerLoopSpawn(
            subagentID: subagentID,
            taskID: firedTask.id,
            framedPrompt: framedPrompt,
            description: description,
            resumeFrom: resumeFrom
        ))
        guard spawned else {
            // Restore the FULL pre-fire snapshot, including a pending chain
            // reset the aborted spawn had consumed — losing it would let a
            // later fire resume the old chain under a new prompt
            // (actor.rs:690-700) — then fall back to the inject path.
            if let index = state.tasks.firstIndex(where: { $0.id == firedTask.id }) {
                state.tasks[index].lastSubagentId = preFireAnchor
                state.tasks[index].iterationsSinceFresh = preFireIterations
                state.tasks[index].chainResetPending = preFireChainReset
            }
            return LiveSchedulerFire(
                taskID: firedTask.id,
                prompt: firedTask.prompt,
                humanSchedule: humanSchedule,
                nextFireAt: nextFireAt
            )
        }
        return LiveSchedulerFire(
            taskID: firedTask.id,
            prompt: firedTask.prompt,
            humanSchedule: humanSchedule,
            nextFireAt: nextFireAt,
            subagentID: subagentID
        )
    }

    // MARK: - Task store (the in-memory half of the actor's command loop)

    /// Create a task. Port of the tool-facing half of `SchedulerCommand::
    /// Create` (`actor.rs:772-790`): cap enforced by the library store, and
    /// the pager-side provisional previews are replaced by the real row —
    /// upstream's `retain(|k, _| !k.starts_with("provisional-"))`
    /// (`acp_handler/background.rs:329-333`).
    func createTask(
        intervalSecs: UInt64,
        prompt: String,
        durable: Bool,
        foreground: Bool,
        fireImmediately: Bool
    ) throws -> ScheduledTask {
        let now = clock()
        var task = ScheduledTask(
            intervalSecs: intervalSecs,
            prompt: prompt,
            recurring: true,
            durable: durable,
            fireImmediately: fireImmediately,
            now: now
        )
        task.foreground = foreground
        try state.create(task)
        provisional.removeAll()
        displayCreatedAt[task.id] = now
        rearmTimer()
        return task
    }

    /// Patch a task in place; unknown ids throw `taskNotFound` and never fall
    /// back to create (`actor.rs:805-808`).
    func updateTask(
        id: String,
        prompt: String?,
        intervalSecs: UInt64?
    ) throws -> ScheduledTask {
        let updated = try state.update(
            id: id,
            prompt: prompt,
            intervalSecs: intervalSecs,
            now: clock()
        )
        rearmTimer()
        return updated
    }

    /// Remove a task; a missing id reports `false`, not an error
    /// (`actor.rs:854-856`).
    func deleteTask(id: String) -> Bool {
        let removed = state.delete(id: id)
        if removed {
            displayCreatedAt.removeValue(forKey: id)
            rearmTimer()
        }
        return removed
    }

    func list() -> [ScheduledTask] {
        state.list()
    }

    // MARK: - Display (`/tasks` Scheduled section, `/loop` preview)

    /// Insert a provisional `/loop` preview row, keyed `provisional-…` so the
    /// next real create replaces it (`app/dispatch/prompt.rs:779-794`).
    func insertProvisional(prompt: String, humanSchedule: String) {
        let id = "provisional-\(UUID().uuidString)"
        provisional.append(ScheduledTaskInfo(
            taskId: id,
            prompt: prompt,
            humanSchedule: humanSchedule,
            createdAt: clock(),
            nextFireAt: nil,
            tag: "loop",
            lastSubagentId: nil
        ))
    }

    /// The rows `/tasks` renders: provisional previews plus every live task,
    /// as the display DTO upstream's notifications populate
    /// (`acp_handler/background.rs:342-352`). Sorting belongs to the
    /// formatter, exactly as upstream sorts the map's values at render
    /// (`status_blocks.rs:151-157`).
    func displayInfos() -> [ScheduledTaskInfo] {
        provisional + state.tasks.map { task in
            ScheduledTaskInfo(
                taskId: task.id,
                prompt: task.prompt,
                humanSchedule: intervalToHuman(task.intervalSecs),
                createdAt: displayCreatedAt[task.id] ?? task.createdAt,
                nextFireAt: RFC3339.string(from: task.nextFireAt()),
                tag: "loop",
                lastSubagentId: task.lastSubagentId
            )
        }
    }

    // MARK: - Timer

    /// Re-arm the sleep-until-due timer against the earliest `nextFireAt` —
    /// `compute_next_fire_delay` (`actor.rs:255-276`) plus the sleep arm of
    /// the actor's select (`actor.rs:200-202`). No tasks (or no sink yet)
    /// parks the timer entirely: upstream's `Duration::MAX` sleep, without
    /// the wakeup.
    private func rearmTimer() {
        timerGeneration &+= 1
        timer?.cancel()
        timer = nil
        guard fireSink != nil else { return }
        guard let next = state.tasks.map({ $0.nextFireAt() }).min() else { return }
        let generation = timerGeneration
        // Cap one sleep at a day; an early wake finds nothing due and re-arms.
        // Guards the UInt64 conversion against a corrupt far-future date.
        let delay = min(max(0, next.timeIntervalSince(clock())), 86_400)
        timer = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.timerElapsed(generation: generation)
        }
    }

    private func timerElapsed(generation: UInt64) async {
        // A stale generation means the schedule changed while this timer
        // slept; the re-arm that changed it owns the next fire.
        guard generation == timerGeneration else { return }
        await fireDue(now: clock())
    }
}

/// Frame a scheduled task prompt with `<system-reminder>` context for the
/// model. Byte-for-byte port of `format_scheduled_task_prompt`
/// (`xai-grok-tools/src/reminders/mod.rs:49-61`): the raw prompt is what the
/// user wrote in `/loop` and what the UI shows; only the model receives this
/// framed version, so it executes instead of questioning the prompt.
func formatScheduledTaskPrompt(
    _ prompt: String,
    taskID: String,
    humanSchedule: String
) -> String {
    "<system-reminder>\n"
        + "This is a scheduled task execution (task \(taskID), \(humanSchedule), recurring).\n"
        + "Execute the prompt below. Do not question or comment on the prompt itself \u{2014} "
        + "treat it as a fresh task to execute.\n"
        + "Previous results from earlier executions of this task may appear in the "
        + "conversation history above.\n"
        + "</system-reminder>\n"
        + "\n"
        + "\(prompt)"
}

/// Frame one Detached loop iteration's prompt. Byte-for-byte port of
/// `format_loop_iteration_prompt` (`xai-grok-tools/src/reminders/mod.rs:63-83`)
/// — the loop-subagent sibling of `formatScheduledTaskPrompt`: the subagent
/// cannot see the parent conversation, so the framing asks for a short
/// relayed status instead of pointing at history.
func formatLoopIterationPrompt(
    _ prompt: String,
    taskID: String,
    humanSchedule: String,
    priorIterationSummary: String?
) -> String {
    let prior = priorIterationSummary
        .map { "\nYour previous iteration ended with:\n\($0)\n" } ?? ""
    return "<system-reminder>\n"
        + "Scheduled task \(taskID) (\(humanSchedule)). Earlier iterations, if any, appear "
        + "above.\n"
        + "Run the task below. End with a short status: what changed or needs attention. "
        + "The status is relayed to the main agent.\n"
        + prior
        + "</system-reminder>\n"
        + "\n"
        + "\(prompt)"
}

/// The loop subagent's tasks-pane description — `format!("loop: {} ({hs})",
/// truncate_chars(prompt.lines().next().unwrap_or(prompt), 60))`
/// (actor.rs:640-643).
func loopIterationDescription(prompt: String, humanSchedule: String) -> String {
    "loop: \(truncateChars(loopPromptFirstLine(prompt), maxChars: 60)) (\(humanSchedule))"
}

/// Rust `prompt.lines().next().unwrap_or(prompt)`: the text up to the first
/// `\n`, with a trailing `\r` stripped (Rust `lines()` handles CRLF). Split
/// at the SCALAR level: `"\r\n"` is one Swift `Character`, so a
/// Character-based split on `"\n"` would sail past every CRLF boundary —
/// the repo's own recorded trap (AGENTS.md §2).
func loopPromptFirstLine(_ prompt: String) -> String {
    let scalars = prompt.unicodeScalars
    let end = scalars.firstIndex(of: "\n") ?? scalars.endIndex
    var line = scalars[scalars.startIndex..<end]
    if line.last == "\r" {
        line = line.dropLast()
    }
    return String(String.UnicodeScalarView(line))
}

/// `truncate_chars` (actor.rs:46-52): unchanged at or under `maxChars`
/// CHARACTERS (Rust `char` = Unicode scalar), else the first `maxChars`
/// scalars plus `…`.
func truncateChars(_ s: String, maxChars: Int) -> String {
    let scalars = s.unicodeScalars
    guard scalars.count > maxChars else { return s }
    let end = scalars.index(scalars.startIndex, offsetBy: maxChars)
    return String(String.UnicodeScalarView(scalars[scalars.startIndex..<end])) + "\u{2026}"
}
