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
}

/// Per-session scheduler runtime: task store, sleep-until-due timer, and the
/// in-session fire delivery seam.
actor LiveSchedulerHost {
    private var state = SchedulerState()
    private let clock: @Sendable () -> Date

    /// Delivers an in-session fire into the interactive controller's prompt
    /// queue. Installed by the composition after the controller exists —
    /// upstream has the same window and polls for wiring before firing due
    /// tasks (`await_subagent_wiring_for_due_tasks`, actor.rs:224-253); here
    /// the timer simply stays parked until the sink lands, so a due task
    /// fires on installation instead of being lost.
    private var fireSink: (@Sendable (LiveSchedulerFire) async -> Void)?

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

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
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
