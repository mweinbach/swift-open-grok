// LiveSchedulerToolsTests.swift
//
// The scheduler runtime + surface, at its seams (AGENTS.md §3):
//
//   * the tool surface through the REAL `LiveToolExecutor.invoke` dispatch —
//     never a direct handler call, which would pass just as happily when the
//     executor advertises nothing;
//   * the host's DETERMINISTIC fire trigger (`fireDue(now:)` against an
//     injected clock) — no test here sleeps a real interval to see a fire;
//   * `/loop`'s registration gate and dispatch outcome;
//   * the `/tasks` Scheduled section, byte-exact per `status_blocks.rs:150-166`.
//
// The end-to-end fire (Cron enqueue → drain → real turn → persisted
// `.schedulerFired` item) lives in `LiveSchedulerFireTests.swift`; the
// controller-side queue semantics live in
// `Tests/OpenGrokPagerTests/PagerCronPromptTests.swift`.

import Foundation
import OpenGrokPager
import OpenGrokSamplingTypes
import OpenGrokScheduler
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokToolsAPI
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private actor InertShellBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "", stdout: "", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "bg")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}

/// An isolated workspace + `$HOME`/`$OPENGROK_HOME` so the executor's hook
/// and MCP discovery cannot pick up the developer's real configuration.
private struct SchedulerWorkspace {
    let root: URL
    let environment: [String: String]

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-scheduler-live-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("repo", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let grokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        for directory in [root, home, grokHome] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": grokHome.path,
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// A settable test clock. The host's every time read goes through the
/// injected closure, so advancing this IS advancing scheduler time — the
/// determinism seam the design guardrail demands.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) { now = start }

    var current: Date {
        lock.withLock { now }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { now = now.addingTimeInterval(seconds) }
    }
}

/// Collects delivered fires — the sink the composition wires to the
/// interactive controller.
private actor FireCollector {
    private(set) var fires: [LiveSchedulerFire] = []
    func record(_ fire: LiveSchedulerFire) { fires.append(fire) }
}

private func makeExecutor(
    _ workspace: SchedulerWorkspace,
    schedulerHost: LiveSchedulerHost?
) async throws -> LiveToolExecutor {
    try await LiveToolExecutor(
        processBackend: InertShellBackend(),
        sessionID: "scheduler-live",
        workingDirectory: workspace.root,
        toolPolicy: nil,
        telemetryBootstrapContext: .empty,
        fileAccessPolicy: .allowAll,
        environment: workspace.environment,
        schedulerHost: schedulerHost
    )
}

private func schedulerCall(_ name: String, _ arguments: [String: Any]) -> ToolCall {
    ToolCall(
        id: "sched-call",
        name: name,
        arguments: String(
            data: try! JSONSerialization.data(withJSONObject: arguments),
            encoding: .utf8
        )!
    )
}

private func invoke(
    _ executor: LiveToolExecutor,
    _ workspace: SchedulerWorkspace,
    _ call: ToolCall
) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
    await executor.invoke(
        sessionID: "scheduler-live",
        workingDirectory: workspace.root,
        call: call
    )
}

// MARK: - Tool surface through real dispatch

@Suite("scheduler tools: advertisement and real dispatch", .serialized)
struct LiveSchedulerToolSurfaceTests {
    @Test("the trio is advertised exactly when a scheduler host exists")
    func advertisedOnlyWithHost() async throws {
        let workspace = SchedulerWorkspace()
        defer { workspace.cleanup() }

        let with = try await makeExecutor(workspace, schedulerHost: LiveSchedulerHost())
        let withNames = Set(with.tools.map(\.name))
        #expect(withNames.contains("scheduler_create"))
        #expect(withNames.contains("scheduler_delete"))
        #expect(withNames.contains("scheduler_list"))
        await with.shutdown()

        // No host (headless/ACP shape): nothing advertised, and calling the
        // name anyway is undispatchable — the §4 pin that a session with no
        // fire path never accepts a create whose fires cannot run.
        let without = try await makeExecutor(workspace, schedulerHost: nil)
        let withoutNames = Set(without.tools.map(\.name))
        #expect(!withoutNames.contains("scheduler_create"))
        #expect(!withoutNames.contains("scheduler_delete"))
        #expect(!withoutNames.contains("scheduler_list"))
        let refused = await invoke(without, workspace, schedulerCall(
            "scheduler_create", ["interval": "5m", "prompt": "check"]
        ))
        guard case .failure = refused else {
            Issue.record("an unadvertised scheduler_create must not dispatch, got \(refused)")
            return
        }
        await without.shutdown()
    }

    @Test("scheduler_create's spec is upstream's copy, with recurring hidden")
    func createSpecPinned() async throws {
        let spec = LiveSchedulerTools.createSpec()
        // create.rs:107-117, byte for byte.
        #expect(spec.description == """
        Create a scheduled task that runs a prompt on a recurring interval, or update an existing one in place.

        Set fire_immediately: true to also fire once on creation; by default the first run waits for the interval.

        To change an existing task, pass its task_id: provided fields replace old values, omitted ones are unchanged, and the schedule keeps its phase. An unknown id errors.

        Usage notes:
        - Interval format: "5m" (minutes), "2h" (hours), "1d" (days), "60s" (seconds, min 60)
        - Maximum 50 scheduled tasks at once
        - Tasks auto-expire after 7 days
        - For one-time delayed work, run a background terminal command (e.g. `sleep 1800 && <command>`) instead; its completion notifies you
        """)
        // `recurring` is a hidden legacy flag (`#[schemars(skip)]`,
        // create.rs:40); `task_id` is advertised — upstream's own schema pin.
        let encoded = String(
            data: try JSONEncoder().encode(spec.parameters),
            encoding: .utf8
        ) ?? ""
        #expect(!encoded.contains("recurring"))
        #expect(encoded.contains("task_id"))

        #expect(LiveSchedulerTools.deleteSpec().description == """
        Cancel a scheduled task by ID.

        Returns success: true if the task was found and removed, false if no task with that ID exists.
        """)
        #expect(LiveSchedulerTools.listSpec().description ==
            "List all active scheduled tasks with their IDs, prompts, intervals, and next fire times.")
    }

    @Test("create through real dispatch persists the task and the display map shows it")
    func createPersistsAndDisplays() async throws {
        let workspace = SchedulerWorkspace()
        defer { workspace.cleanup() }
        let host = LiveSchedulerHost()
        let executor = try await makeExecutor(workspace, schedulerHost: host)
        defer { Task { await executor.shutdown() } }

        let result = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["interval": "5m", "prompt": "check deploy status"]
        ))
        guard case .success(let output) = result else {
            Issue.record("scheduler_create failed through live dispatch: \(result)")
            return
        }
        #expect(output.promptText.contains("\"humanSchedule\":\"every 5 minutes\""))
        #expect(output.promptText.contains("\"updated\":false"))

        // The task landed in the host store (300 s, recurring, 7-day expiry)…
        let tasks = await host.list()
        try #require(tasks.count == 1)
        #expect(tasks[0].intervalSecs == 300)
        #expect(tasks[0].prompt == "check deploy status")
        #expect(tasks[0].recurring)
        #expect(tasks[0].expiresAt != nil)

        // …and the display map — the `/tasks` source — shows the same row.
        let display = await host.displayInfos()
        try #require(display.count == 1)
        #expect(display[0].taskId == tasks[0].id)
        #expect(display[0].humanSchedule == "every 5 minutes")
        #expect(display[0].tag == "loop")
    }

    @Test("create argument errors carry upstream's exact texts")
    func createArgumentErrors() async throws {
        let workspace = SchedulerWorkspace()
        defer { workspace.cleanup() }
        let host = LiveSchedulerHost()
        let executor = try await makeExecutor(workspace, schedulerHost: host)
        defer { Task { await executor.shutdown() } }

        let noInterval = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["prompt": "check"]
        ))
        guard case .failure(let error1) = noInterval else {
            Issue.record("create without interval must fail"); return
        }
        #expect(error1.description.contains("interval is required when creating a task"))

        let noPrompt = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["interval": "5m"]
        ))
        guard case .failure(let error2) = noPrompt else {
            Issue.record("create without prompt must fail"); return
        }
        #expect(error2.description.contains("prompt is required when creating a task"))

        // The legacy one-shot flag steers to sleep (create.rs:231-236).
        let oneShot = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["interval": "5m", "prompt": "check", "recurring": false]
        ))
        guard case .failure(let error3) = oneShot else {
            Issue.record("one-shot must be rejected"); return
        }
        #expect(error3.description.contains(
            "one-shot tasks are not supported; run a background terminal command instead (`sleep <secs> && <command>`, background: true) or do the work now"
        ))

        // A bad interval surfaces the LIBRARY's thrown message — upstream's
        // `invalid_arguments(e.to_string())` (create.rs:171-176).
        let badInterval = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["interval": "5x", "prompt": "check"]
        ))
        guard case .failure(let error4) = badInterval else {
            Issue.record("a bad interval suffix must fail"); return
        }
        #expect(error4.description.contains(
            "invalid interval suffix: \"x\" (expected s, m, h, or d)"
        ))
        #expect(await host.list().isEmpty, "no failed create may leave a task behind")
    }

    @Test("update patches in place; an unknown id errors and never creates")
    func updateSemantics() async throws {
        let workspace = SchedulerWorkspace()
        defer { workspace.cleanup() }
        let host = LiveSchedulerHost()
        let executor = try await makeExecutor(workspace, schedulerHost: host)
        defer { Task { await executor.shutdown() } }

        let unknown = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["task_id": "nonexistent", "prompt": "new prompt"]
        ))
        guard case .failure(let unknownError) = unknown else {
            Issue.record("unknown id must error"); return
        }
        #expect(unknownError.description.contains("no scheduled task with id"))
        #expect(await host.list().isEmpty, "strict update must not fall back to create")

        let emptyPatch = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["task_id": "abc123"]
        ))
        guard case .failure(let emptyError) = emptyPatch else {
            Issue.record("empty patch must error"); return
        }
        #expect(emptyError.description.contains(
            "nothing to update: provide interval and/or prompt alongside task_id"
        ))

        guard case .success = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["interval": "5m", "prompt": "check deploy"]
        )) else {
            Issue.record("create failed"); return
        }
        let taskID = try #require(await host.list().first).id
        let updated = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["task_id": taskID, "interval": "10m", "recurring": false]
        ))
        guard case .success(let output) = updated else {
            Issue.record("update failed: \(updated)"); return
        }
        // `updated: true`, new schedule, same identity, no second task —
        // and the legacy `recurring` flag is ignored on the update path
        // (create.rs `update_ignores_legacy_recurring_flag`).
        #expect(output.promptText.contains("\"updated\":true"))
        #expect(output.promptText.contains("\"humanSchedule\":\"every 10 minutes\""))
        let tasks = await host.list()
        try #require(tasks.count == 1)
        #expect(tasks[0].id == taskID)
        #expect(tasks[0].intervalSecs == 600)
        #expect(tasks[0].recurring)
    }

    @Test("delete removes the task and reports the miss with upstream's copy")
    func deleteSemantics() async throws {
        let workspace = SchedulerWorkspace()
        defer { workspace.cleanup() }
        let host = LiveSchedulerHost()
        let executor = try await makeExecutor(workspace, schedulerHost: host)
        defer { Task { await executor.shutdown() } }

        guard case .success = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["interval": "5m", "prompt": "check deploy"]
        )) else {
            Issue.record("create failed"); return
        }
        let taskID = try #require(await host.list().first).id

        let removed = await invoke(executor, workspace, schedulerCall(
            "scheduler_delete", ["id": taskID]
        ))
        guard case .success(let removal) = removed else {
            Issue.record("delete failed: \(removed)"); return
        }
        #expect(removal.promptText.contains("\"success\":true"))
        #expect(removal.promptText.contains("Scheduled task \(taskID) cancelled."))
        #expect(await host.list().isEmpty)
        #expect(await host.displayInfos().isEmpty, "the display map must drop the row too")

        let missed = await invoke(executor, workspace, schedulerCall(
            "scheduler_delete", ["id": taskID]
        ))
        guard case .success(let miss) = missed else {
            Issue.record("a missing id is Ok(false), not an error: \(missed)"); return
        }
        #expect(miss.promptText.contains("\"success\":false"))
        #expect(miss.promptText.contains(
            "No scheduled task with ID \(taskID) found. Use scheduler_list to see active tasks."
        ))
    }

    @Test("list reports camelCase summaries with the 80-byte prompt cut")
    func listSemantics() async throws {
        let workspace = SchedulerWorkspace()
        defer { workspace.cleanup() }
        let host = LiveSchedulerHost()
        let executor = try await makeExecutor(workspace, schedulerHost: host)
        defer { Task { await executor.shutdown() } }

        let longPrompt = String(repeating: "x", count: 100)
        guard case .success = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["interval": "2h", "prompt": longPrompt]
        )) else {
            Issue.record("create failed"); return
        }
        let listed = await invoke(executor, workspace, schedulerCall("scheduler_list", [:]))
        guard case .success(let output) = listed else {
            Issue.record("list failed: \(listed)"); return
        }
        #expect(output.promptText.contains("\"intervalHuman\":\"every 2 hours\""))
        #expect(output.promptText.contains("\"recurring\":true"))
        // 80 bytes then "..." (list.rs:127-132).
        #expect(output.promptText.contains(String(repeating: "x", count: 80) + "..."))
        #expect(!output.promptText.contains(String(repeating: "x", count: 81)))
    }
}

// MARK: - Deterministic fires

@Suite("scheduler host: deterministic fires (injected clock, no sleeps)")
struct LiveSchedulerHostFireTests {
    @Test("a due task fires through the trigger and re-anchors its cadence")
    func fireDueDeliversAndReanchors() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let host = LiveSchedulerHost(clock: { clock.current })
        let collector = FireCollector()
        await host.setFireSink { fire in await collector.record(fire) }

        let task = try await host.createTask(
            intervalSecs: 300,
            prompt: "check deploy status",
            durable: false,
            foreground: true,
            fireImmediately: true
        )

        // `fireImmediately` backdates the anchor, so the task is due NOW —
        // fired by the deterministic trigger, not by any wall-clock sleep.
        let fires = await host.fireDue(now: clock.current)
        try #require(fires.count == 1)
        #expect(fires[0].taskID == task.id)
        #expect(fires[0].prompt == "check deploy status")
        #expect(fires[0].humanSchedule == "every 5 minutes")
        #expect(fires[0].nextFireAt == RFC3339.string(
            from: clock.current.addingTimeInterval(300)
        ))
        #expect(await collector.fires == fires, "the sink must receive what fireDue reports")

        // The cadence advanced: the same instant fires nothing more…
        #expect(await host.fireDue(now: clock.current).isEmpty)

        // …and one interval later it fires again. Time is the injected
        // clock, advanced synchronously.
        clock.advance(by: 300)
        let second = await host.fireDue(now: clock.current)
        #expect(second.count == 1)
        #expect(await collector.fires.count == 2)
    }

    @Test("with no sink installed a due task waits, and fires on installation")
    func noSinkHoldsTheFire() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let host = LiveSchedulerHost(clock: { clock.current })
        _ = try await host.createTask(
            intervalSecs: 60,
            prompt: "ping",
            durable: false,
            foreground: true,
            fireImmediately: true
        )

        // No sink: the trigger must not consume the fire (upstream's startup
        // wiring grace, actor.rs:224-253) — firing into nowhere would mark
        // the task fired and silently drop the prompt.
        #expect(await host.fireDue(now: clock.current).isEmpty)

        let collector = FireCollector()
        await host.setFireSink { fire in await collector.record(fire) }
        // Installation delivers the held fire.
        #expect(await collector.fires.count == 1)
        #expect(await collector.fires.first?.prompt == "ping")
    }

    @Test("an expired recurring task is removed without firing")
    func expiryRemovesWithoutFiring() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let host = LiveSchedulerHost(clock: { clock.current })
        let collector = FireCollector()
        await host.setFireSink { fire in await collector.record(fire) }
        _ = try await host.createTask(
            intervalSecs: 3600,
            prompt: "hourly",
            durable: false,
            foreground: true,
            fireImmediately: false
        )

        // Eight days on: past the 7-day expiry. The tick removes the task
        // instead of firing it (actor.rs:395-404).
        clock.advance(by: 8 * 86_400)
        #expect(await host.fireDue(now: clock.current).isEmpty)
        #expect(await collector.fires.isEmpty)
        #expect(await host.list().isEmpty)
    }

    @Test("delete disarms: a deleted due task never fires")
    func deleteDisarms() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let host = LiveSchedulerHost(clock: { clock.current })
        let task = try await host.createTask(
            intervalSecs: 60,
            prompt: "ping",
            durable: false,
            foreground: true,
            fireImmediately: true
        )
        #expect(try await host.deleteTask(id: task.id))

        let collector = FireCollector()
        await host.setFireSink { fire in await collector.record(fire) }
        #expect(await host.fireDue(now: clock.current).isEmpty)
        #expect(await collector.fires.isEmpty)
    }
}

// MARK: - /loop

@Suite("/loop: registration gate and dispatch")
struct LiveLoopCommandTests {
    @Test("registered exactly when scheduler_create is advertised, verbatim copy")
    func registrationGate() async throws {
        let workspace = SchedulerWorkspace()
        defer { workspace.cleanup() }

        // Through the REAL advertised list, the same one the composition
        // reads (`toolExecutor.tools`), not a hand-built set.
        let with = try await makeExecutor(workspace, schedulerHost: LiveSchedulerHost())
        let registered = LiveLoopCommand.registrations(
            advertisedToolNames: Set(with.tools.map(\.name))
        )
        try #require(registered.count == 1)
        #expect(registered[0].name == "loop")
        #expect(registered[0].summary == "Run a prompt on a recurring interval")
        #expect(registered[0].usage == "/loop [interval] <prompt>")
        await with.shutdown()

        let without = try await makeExecutor(workspace, schedulerHost: nil)
        #expect(LiveLoopCommand.registrations(
            advertisedToolNames: Set(without.tools.map(\.name))
        ).isEmpty)
        await without.shutdown()
    }

    @Test("empty args echo the usage message with no host-side default")
    func usageOnEmpty() {
        guard case .usage(let message) = LiveLoopCommand.dispatch(rawArgumentTail: "   ") else {
            Issue.record("blank args must yield the usage message")
            return
        }
        #expect(message == loopUsageMessage())
        #expect(message.contains("Usage: /loop"))
        #expect(!message.contains("10m"), "usage must not claim a default")
    }

    @Test("dispatch injects the exact shared instruction plus the provisional preview")
    func dispatchInjectsInstruction() {
        guard case .schedule(let instruction, let preview) =
            LiveLoopCommand.dispatch(rawArgumentTail: "30m check deploy status")
        else {
            Issue.record("args must dispatch a schedule")
            return
        }
        // The instruction is the SHARED helper's output for the in-session
        // mode — this port's only fire path; the wording must describe the
        // runtime the user actually has.
        #expect(instruction == loopScheduleInstruction("30m check deploy status", mode: .inSession))
        #expect(preview.humanSchedule == "every 30 minutes")
        #expect(preview.prompt == "check deploy status")
    }

    @Test("no leading token means the neutral placeholder, never a fabricated cadence")
    func placeholderNotDefault() {
        guard case .schedule(let instruction, let preview) =
            LiveLoopCommand.dispatch(rawArgumentTail: "check deploy status every 30 minutes")
        else {
            Issue.record("args must dispatch a schedule")
            return
        }
        #expect(preview.humanSchedule == "scheduling\u{2026}")
        #expect(preview.humanSchedule != "every 10 minutes")
        #expect(preview.prompt == "check deploy status every 30 minutes")
        // Behaviour-bearing instruction tokens (loop_cmd.rs:329-347).
        #expect(!instruction.contains("10m"))
        #expect(instruction.contains("30 minutes"))
        #expect(instruction.contains("<number><unit>"))
        #expect(instruction.contains("ask the user how often"))
        #expect(instruction.contains("Do NOT execute the prompt inline"))
    }

    @Test("arg parsing matches upstream's catalogue")
    func parseCatalogue() {
        func expectParse(
            _ input: String, token: String?, prompt: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let parsed = LiveLoopCommand.parseLoopArgs(input)
            #expect(parsed.intervalToken == token, sourceLocation: sourceLocation)
            #expect(parsed.prompt == prompt, sourceLocation: sourceLocation)
        }
        // parse_with_explicit_interval / hours / days / seconds.
        expectParse("5m check deploy status", token: "5m", prompt: "check deploy status")
        expectParse("2h run tests", token: "2h", prompt: "run tests")
        expectParse("1d daily report", token: "1d", prompt: "daily report")
        expectParse("60s ping health", token: "60s", prompt: "ping health")
        // Without a leading token, the whole input is the prompt.
        expectParse("check deploy status", token: nil, prompt: "check deploy status")
        // A bare token has no prompt to schedule.
        expectParse("5m", token: nil, prompt: "5m")
        expectParse("check 5m deploy", token: nil, prompt: "check 5m deploy")
        expectParse("   ", token: nil, prompt: "")
        // Every rejecting branch of `is_interval_token`
        // (loop_cmd.rs:213-232): bad suffix, no suffix, too short,
        // multi-char suffix, zero values, alphabetic, u64 overflow.
        for input in [
            "5x do x", "5 do x", "m do x", "55mm do x",
            "0m do x", "0s do x", "abc do x", "99999999999999999999m do x",
        ] {
            let (token, prompt) = LiveLoopCommand.parseLoopArgs(input)
            #expect(token == nil, "input \(input) must not yield a token")
            #expect(prompt == input)
        }
        // Natural-language cadences are never defaulted host-side.
        for input in [
            "every 30 minutes do x", "30 min check deploy",
            "1 hour run report", "run the report every 1h",
        ] {
            let (token, prompt) = LiveLoopCommand.parseLoopArgs(input)
            #expect(token == nil, "input \(input) must not yield a token")
            #expect(prompt == input)
        }
    }

    @Test("the preview's token formatter matches upstream's goldens")
    func intervalTokenToHumanGoldens() {
        #expect(LiveLoopCommand.intervalTokenToHuman("5m") == "every 5 minutes")
        #expect(LiveLoopCommand.intervalTokenToHuman("1m") == "every 1 minute")
        #expect(LiveLoopCommand.intervalTokenToHuman("2h") == "every 2 hours")
        #expect(LiveLoopCommand.intervalTokenToHuman("1h") == "every 1 hour")
        #expect(LiveLoopCommand.intervalTokenToHuman("1d") == "every 1 day")
        #expect(LiveLoopCommand.intervalTokenToHuman("7d") == "every 7 days")
        #expect(LiveLoopCommand.intervalTokenToHuman("60s") == "every 60 seconds")
    }
}

// MARK: - /tasks Scheduled section

@Suite("/tasks: Scheduled section")
struct LivePagerTasksScheduledSectionTests {
    private func info(
        taskId: String,
        prompt: String,
        humanSchedule: String,
        tag: String = "loop"
    ) -> ScheduledTaskInfo {
        ScheduledTaskInfo(
            taskId: taskId,
            prompt: prompt,
            humanSchedule: humanSchedule,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            nextFireAt: nil,
            tag: tag,
            lastSubagentId: nil
        )
    }

    @Test("rows are byte-exact and sorted by tag, schedule, then id")
    func scheduledRowsByteExact() {
        let text = LivePagerTasksBlock.text(
            workflowRows: [],
            subagents: [],
            tasks: [],
            scheduled: [
                info(taskId: "bbb", prompt: "second\nline", humanSchedule: "every 5 minutes"),
                info(taskId: "aaa", prompt: "check deploy", humanSchedule: "every 30 minutes"),
                info(taskId: "ccc", prompt: "watch ci", humanSchedule: "every 5 minutes"),
            ]
        )
        // `"  {:<9}{} · {} · {}"` with a nine-character status: NO space
        // between "scheduled" and the tag — upstream's own rendering
        // (status_blocks.rs:158-166); byte parity keeps it. Sort is tag,
        // then human_schedule, then task_id; the prompt renders its first
        // non-empty line.
        #expect(text == """
        Tasks (3):
          scheduledloop · every 30 minutes · check deploy
          scheduledloop · every 5 minutes · second
          scheduledloop · every 5 minutes · watch ci
        """)
    }

    @Test("scheduled rows count toward the header and coexist with task rows")
    func headerCountsScheduledRows() {
        let text = LivePagerTasksBlock.text(
            workflowRows: [],
            subagents: [],
            tasks: [],
            scheduled: [info(taskId: "aaa", prompt: "check", humanSchedule: "every 1 hour")]
        )
        #expect(text == """
        Task (1):
          scheduledloop · every 1 hour · check
        """)
    }

    @Test("no scheduled rows leaves the block exactly as before")
    func emptyScheduledIsAbsent() {
        #expect(LivePagerTasksBlock.text(
            workflowRows: [], subagents: [], tasks: [], scheduled: []
        ) == "No background tasks, workflows, or subagents.")
    }

    @Test("a /loop provisional preview shows until the real create replaces it")
    func provisionalRowLifecycle() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let host = LiveSchedulerHost(clock: { clock.current })
        await host.insertProvisional(
            prompt: "check deploy status",
            humanSchedule: "scheduling\u{2026}"
        )
        let before = await host.displayInfos()
        try #require(before.count == 1)
        #expect(before[0].taskId.hasPrefix("provisional-"))
        #expect(before[0].humanSchedule == "scheduling\u{2026}")
        #expect(before[0].tag == "loop")

        // The real create replaces every provisional row
        // (acp_handler/background.rs:329-333).
        let task = try await host.createTask(
            intervalSecs: 300,
            prompt: "check deploy status",
            durable: false,
            foreground: true,
            fireImmediately: false
        )
        let after = await host.displayInfos()
        try #require(after.count == 1)
        #expect(after[0].taskId == task.id)
        #expect(after[0].humanSchedule == "every 5 minutes")
    }
}

// MARK: - Cron framing

@Suite("cron prompt framing")
struct LiveSchedulerFramingTests {
    @Test("the model frame is reminders.rs's format_scheduled_task_prompt, byte for byte")
    func framePinned() {
        let framed = formatScheduledTaskPrompt(
            "check deploy status",
            taskID: "task-9",
            humanSchedule: "every 5 minutes"
        )
        #expect(framed == "<system-reminder>\n"
            + "This is a scheduled task execution (task task-9, every 5 minutes, recurring).\n"
            + "Execute the prompt below. Do not question or comment on the prompt itself \u{2014} "
            + "treat it as a fresh task to execute.\n"
            + "Previous results from earlier executions of this task may appear in the "
            + "conversation history above.\n"
            + "</system-reminder>\n"
            + "\n"
            + "check deploy status")
    }
}
