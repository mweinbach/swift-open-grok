// LiveMonitorToolTests.swift
//
// The `monitor` tool at its seams:
//
//   * the line processor / batcher / `<monitor-event>` wrap, pinned to
//     upstream's own `event.rs` test vectors;
//   * the rate limiter against an injected clock — token bucket, catch-up
//     notice, and the 30s auto-kill (`rate_limiter.rs`), with zero sleeps;
//   * the pipeline body `tick(now:)` against a stub execution and a real
//     output file — deterministic, no poll loop;
//   * dispatch against the REAL shell backend: a monitor is a real
//     `kind: .monitor` background task the session's own execution owns,
//     `/tasks` renders it with upstream's `is_monitor` arm
//     (`status_blocks.rs:128`), and its stdout arrives through the event
//     sink as wrapped events;
//   * advertisement gating through the real executor: no monitor host, no
//     `monitor` tool.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

// MARK: - Line processing pins (event.rs tests)

@Suite("monitor line processing")
struct LiveMonitorLineProcessingTests {
    @Test("push splits complete lines, buffers partials, skips empties")
    func pushSemantics() {
        var processor = LiveMonitorLineProcessor()
        #expect(processor.push(Array("hello world\n".utf8)) == ["hello world"])
        #expect(processor.push(Array("line1\nline2\nline3\n".utf8)) == ["line1", "line2", "line3"])
        #expect(processor.push(Array("partial".utf8)).isEmpty)
        #expect(processor.push(Array(" line\n".utf8)) == ["partial line"])
        #expect(processor.push(Array("hello\n\n\nworld\n".utf8)) == ["hello", "world"])
    }

    @Test("CRLF-delimited streams split at every boundary (the recorded byte-scan trap)")
    func crlfBoundaries() {
        var processor = LiveMonitorLineProcessor()
        #expect(processor.push(Array("one\r\ntwo\r\n".utf8)) == ["one", "two"])
    }

    @Test("long lines truncate at 500 bytes on a scalar boundary")
    func longLineTruncates() {
        var processor = LiveMonitorLineProcessor()
        let lines = processor.push(Array((String(repeating: "x", count: 600) + "\n").utf8))
        #expect(lines.count == 1)
        #expect(lines[0] == String(repeating: "x", count: 500) + "...(truncated)")
        // Multi-byte scalars never split mid-scalar (event.rs:189-204).
        let cjk = String(repeating: "\u{4E16}\u{754C}", count: 200)
        let truncated = LiveMonitorLineProcessor.truncateLine(cjk)
        #expect(truncated.hasSuffix("...(truncated)"))
        #expect(truncated.utf8.count <= 500 + "...(truncated)".utf8.count)
    }

    @Test("flush returns the buffered partial once, or nothing")
    func flushSemantics() {
        var processor = LiveMonitorLineProcessor()
        _ = processor.push(Array("no newline".utf8))
        #expect(processor.flush() == "no newline")
        #expect(processor.flush() == nil)
    }

    @Test("batching joins with newlines and truncates at 3000 bytes")
    func batchSemantics() {
        #expect(LiveMonitorLineProcessor.batchLines(["line1", "line2", "line3"]) == "line1\nline2\nline3")
        let long = String(repeating: "x", count: 2_000)
        let batched = LiveMonitorLineProcessor.batchLines([long, long])
        #expect(batched.hasSuffix("\n...(truncated)"))
        #expect(batched.utf8.count < 5_000)
    }

    @Test("the XML wrap and its description sanitizer, byte-exact (event.rs:215-223, 100-107)")
    func wrapPins() {
        #expect(
            wrapMonitorEvent(description: "errors in log", eventText: "ERROR: disk full", taskID: "task-123")
                == "<monitor-event description=\"errors in log\" task_id=\"task-123\">\n"
                + "ERROR: disk full\n"
                + "</monitor-event>"
        )
        let wrapped = wrapMonitorEvent(description: "watch \"prod\"\nlogs", eventText: "line", taskID: "t-1")
        #expect(wrapped.hasPrefix(
            "<monitor-event description=\"watch 'prod' logs\" task_id=\"t-1\">"
        ))
    }
}

// MARK: - Rate limiter pins (rate_limiter.rs tests, injected clock)

@Suite("monitor rate limiter")
struct LiveMonitorRateLimiterTests {
    @Test("the bucket starts full and suppresses the 11th burst event")
    func bucketStartsFull() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var limiter = LiveMonitorRateLimiter(killToolName: "kill_command_or_subagent", now: start)
        for _ in 0..<10 {
            guard case .allowed(catchUpNotice: nil) = limiter.processEvent(now: start) else {
                Issue.record("burst within capacity must pass without a notice")
                return
            }
        }
        #expect(limiter.processEvent(now: start) == .suppressed)
    }

    @Test("recovery delivers a catch-up notice naming the suppressed count")
    func catchUpNotice() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var limiter = LiveMonitorRateLimiter(killToolName: "kill_command_or_subagent", now: start)
        for _ in 0..<10 { _ = limiter.processEvent(now: start) }
        for _ in 0..<3 {
            #expect(limiter.processEvent(now: start) == .suppressed)
        }
        // One refill interval restores one token; the allowed event carries
        // the notice (rate_limiter.rs:219-237).
        let later = start.addingTimeInterval(2.1)
        guard case .allowed(catchUpNotice: let notice?) = limiter.processEvent(now: later) else {
            Issue.record("expected an allowed event with a catch-up notice")
            return
        }
        #expect(notice.contains("3 events suppressed"))
        #expect(notice.contains("kill_command_or_subagent"))
    }

    @Test("sustained overload for 30s auto-kills the monitor")
    func autoKillAfterSustainedOverload() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var limiter = LiveMonitorRateLimiter(killToolName: "kill_command_or_subagent", now: start)
        // Drain the bucket, then hold the pressure past the threshold. Each
        // suppressed event also earns refilled tokens back, so pressure at
        // +31s must first exhaust the refills; what matters is that the
        // KILLED state eventually fires from suppression that began at
        // `start` (rate_limiter.rs:121-137).
        for _ in 0..<10 { _ = limiter.processEvent(now: start) }
        #expect(limiter.processEvent(now: start) == .suppressed)
        var killed = false
        var instant = start
        outer: for step in 1...40 {
            instant = start.addingTimeInterval(Double(step))
            for _ in 0..<3 {
                if case .autoKill(let message) = limiter.processEvent(now: instant) {
                    #expect(message.contains("Monitor stopped"))
                    killed = true
                    break outer
                }
            }
        }
        #expect(killed, "sustained overload must trip the auto-kill")
        #expect(limiter.isKilled)
        // Killed discards everything, even with tokens available.
        #expect(limiter.processEvent(now: instant.addingTimeInterval(60)) == .suppressed)
    }
}

// MARK: - Input validation pins (types.rs:87-107 + its tests)

@Suite("monitor input resolution")
struct LiveMonitorInputTests {
    @Test("default timeout is 10h; persistent resolves to 0")
    func timeoutResolution() {
        #expect(LiveMonitorTools.resolvedTimeoutMS(timeoutMS: nil, persistent: false) == 36_000_000)
        #expect(LiveMonitorTools.resolvedTimeoutMS(timeoutMS: nil, persistent: true) == 0)
        #expect(LiveMonitorTools.resolvedTimeoutMS(timeoutMS: 600_000, persistent: false) == 600_000)
        #expect(LiveMonitorTools.resolvedTimeoutMS(timeoutMS: 99_999_999, persistent: true) == 0)
    }

    @Test("the spec advertises upstream's schema: command+description required")
    func specPins() throws {
        let spec = LiveMonitorTools.toolSpec()
        #expect(spec.name == "monitor")
        let description = try #require(spec.description)
        #expect(description.contains(
            "Start a background monitor that streams events from a long-running script."
        ))
        #expect(description.contains("`grep --line-buffered`"))
        #expect(description.contains(
            "the monitor runs until you call kill_command_or_subagent or until the session ends"
        ))
        guard case .object(let parameters) = spec.parameters,
              case .array(let required)? = parameters["required"],
              case .object(let properties)? = parameters["properties"]
        else {
            Issue.record("monitor spec parameters must be an object schema")
            return
        }
        #expect(required == [.string("command"), .string("description")])
        #expect(Set(properties.keys) == ["command", "description", "timeout_ms", "persistent"])
    }
}

// MARK: - The deterministic pipeline body

/// A stub execution whose snapshots the test scripts — the seam `tick`
/// consults for completion, with the output FILE carrying the bytes exactly
/// as the real backend writes them.
private actor StubMonitorExecution: OpenGrokShellProcessExecution {
    nonisolated let sessionID = "monitor-stub"
    nonisolated let workingDirectory = FileManager.default.temporaryDirectory

    private var snapshots: [String: ShellTaskSnapshot] = [:]

    func set(_ snapshot: ShellTaskSnapshot) {
        snapshots[snapshot.taskID] = snapshot
    }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        throw CLIApplicationError.failed("stub does not run foreground commands")
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        throw CLIApplicationError.failed("stub does not start tasks")
    }

    func cancel(toolCallID: String) async {}
    func cancelAll() async {}
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func taskSnapshot(_ taskID: String) async -> ShellTaskSnapshot? { snapshots[taskID] }

    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        snapshots[taskID]
    }

    func listTasks() async -> [ShellTaskSnapshot] { Array(snapshots.values) }
}

private actor MonitorEventCollector {
    private(set) var events: [LiveMonitorEvent] = []
    func record(_ event: LiveMonitorEvent) { events.append(event) }
}

private func makeMonitorWorkspace() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("og-monitor-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("monitor pipeline: deterministic ticks")
struct LiveMonitorPipelineTests {
    @Test("a tick drains new stdout into one batched, wrapped event")
    func tickDeliversBatchedEvent() async throws {
        let directory = makeMonitorWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFile = directory.appendingPathComponent("monitor-t1.log")
        let host = LiveMonitorHost(context: LiveMonitorHost.Context(
            sessionID: "monitor-stub",
            outputDirectory: directory
        ))
        let collector = MonitorEventCollector()
        await host.setEventSink { event in await collector.record(event) }
        let execution = StubMonitorExecution()
        await execution.set(ShellTaskSnapshot(
            taskID: "t1",
            command: "tail -f log",
            cwd: directory,
            kind: .monitor
        ))
        await host.track(taskID: "t1", description: "watch log", outputFile: outputFile)

        // No output yet: a tick delivers nothing and keeps polling.
        #expect(await host.tick(taskID: "t1", process: execution) == false)
        #expect(await collector.events.isEmpty)

        try "line one\nline two\n".write(to: outputFile, atomically: false, encoding: .utf8)
        #expect(await host.tick(taskID: "t1", process: execution) == false)
        let events = await collector.events
        try #require(events.count == 1)
        #expect(events[0] == LiveMonitorEvent(
            taskID: "t1",
            eventText: "<monitor-event description=\"watch log\" task_id=\"t1\">\n"
                + "line one\nline two\n"
                + "</monitor-event>"
        ))

        // The same bytes never deliver twice: the offset advanced.
        #expect(await host.tick(taskID: "t1", process: execution) == false)
        #expect(await collector.events.count == 1)
    }

    @Test("completion flushes the partial line and ends the pipeline with NO terminal event")
    func completionFlushesWithoutEndedEvent() async throws {
        let directory = makeMonitorWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFile = directory.appendingPathComponent("monitor-t2.log")
        let host = LiveMonitorHost(context: LiveMonitorHost.Context(
            sessionID: "monitor-stub",
            outputDirectory: directory
        ))
        let collector = MonitorEventCollector()
        await host.setEventSink { event in await collector.record(event) }
        let execution = StubMonitorExecution()
        await execution.set(ShellTaskSnapshot(
            taskID: "t2",
            command: "echo done",
            cwd: directory,
            completed: true,
            kind: .monitor
        ))
        await host.track(taskID: "t2", description: "done watch", outputFile: outputFile)
        try "no trailing newline".write(to: outputFile, atomically: false, encoding: .utf8)

        // Completed task: the tick flushes the partial and reports finished.
        #expect(await host.tick(taskID: "t2", process: execution) == true)
        let events = await collector.events
        try #require(events.count == 1)
        #expect(events[0].eventText.contains("no trailing newline"))
        // NO `[monitor ended]` terminal event (tool.rs:312-318): upstream
        // reserves the completion wake for TaskCompleted; this port's
        // TaskCompleted auto-wake is a recorded deferral, so completion is
        // visible via /tasks and get_command_or_subagent_output only.
        #expect(!events[0].eventText.contains("monitor ended"))
        // A finished pipeline stays finished.
        #expect(await host.tick(taskID: "t2", process: execution) == true)
        #expect(await collector.events.count == 1)
    }

    @Test("events raised before the sink installs are buffered, never dropped")
    func preSinkEventsBuffer() async throws {
        let directory = makeMonitorWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFile = directory.appendingPathComponent("monitor-t3.log")
        let host = LiveMonitorHost(context: LiveMonitorHost.Context(
            sessionID: "monitor-stub",
            outputDirectory: directory
        ))
        let execution = StubMonitorExecution()
        await execution.set(ShellTaskSnapshot(
            taskID: "t3",
            command: "tail -f log",
            cwd: directory,
            kind: .monitor
        ))
        await host.track(taskID: "t3", description: "early", outputFile: outputFile)
        try "early line\n".write(to: outputFile, atomically: false, encoding: .utf8)
        #expect(await host.tick(taskID: "t3", process: execution) == false)

        let collector = MonitorEventCollector()
        await host.setEventSink { event in await collector.record(event) }
        let events = await collector.events
        try #require(events.count == 1)
        #expect(events[0].eventText.contains("early line"))
    }
}

// MARK: - Advertisement gate (AGENTS.md §4)

private actor InertMonitorShellBackend: ShellProcessBackend {
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

@Suite("monitor tool: advertisement gate", .serialized)
struct LiveMonitorAdvertisementTests {
    @Test("monitor is advertised exactly when a monitor host exists")
    func advertisedOnlyWithHost() async throws {
        let workspace = makeMonitorWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]

        let without = try await LiveToolExecutor(
            processBackend: InertMonitorShellBackend(),
            sessionID: "monitor-adv",
            workingDirectory: workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment
        )
        #expect(
            !without.tools.contains { $0.name == "monitor" },
            "no monitor host, no monitor tool — an event with no delivery seam is the §3 failure"
        )
        await without.shutdown()

        let with = try await LiveToolExecutor(
            processBackend: InertMonitorShellBackend(),
            sessionID: "monitor-adv",
            workingDirectory: workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment,
            monitorHost: LiveMonitorHost(context: LiveMonitorHost.Context(
                sessionID: "monitor-adv",
                outputDirectory: workspace
            ))
        )
        #expect(with.tools.contains { $0.name == "monitor" })
        await with.shutdown()
    }
}

// MARK: - Dispatch against the real shell backend

@Suite("monitor tool: real dispatch", .serialized)
struct LiveMonitorDispatchTests {
    @Test("the timeout/persistent validation errors match upstream's catalogue")
    func validationErrors() async throws {
        let directory = makeMonitorWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = LiveMonitorHost(context: LiveMonitorHost.Context(
            sessionID: "monitor-live",
            outputDirectory: directory
        ))
        let execution = StubMonitorExecution()

        let overMax = await LiveMonitorTools.invoke(
            args: .object([
                "command": .string("tail -f log"),
                "description": .string("watch"),
                "timeout_ms": .number(.uint64(36_000_001)),
            ]),
            callID: "mon-invalid",
            process: execution,
            host: host
        )
        guard case .failure(.invalidCall(let message)) = overMax else {
            Issue.record("an over-max timeout without persistent must be refused, got \(overMax)")
            return
        }
        #expect(message == "persistent must be true when timeout_ms exceeds 36000000ms")

        let missingCommand = await LiveMonitorTools.invoke(
            args: .object(["description": .string("watch")]),
            callID: "mon-missing",
            process: execution,
            host: host
        )
        guard case .failure(.invalidCall) = missingCommand else {
            Issue.record("a missing command must be refused, got \(missingCommand)")
            return
        }
    }

    @Test("a monitor is a real .monitor-kind background task whose stdout reaches the sink")
    func monitorRunsRealProcess() async throws {
        let directory = makeMonitorWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = LocalShellProcessBackend(inheritedEnvironment: ProcessInfo.processInfo.environment)
        let execution = try OpenGrokShellOwnedProcessExecution(
            sessionID: "monitor-live",
            workingDirectory: directory,
            backend: backend
        )
        let host = LiveMonitorHost(context: LiveMonitorHost.Context(
            sessionID: "monitor-live",
            outputDirectory: directory
        ))
        let collector = MonitorEventCollector()
        await host.setEventSink { event in await collector.record(event) }

        let result = await LiveMonitorTools.invoke(
            args: .object([
                "command": .string("printf 'hello\\nworld\\n'"),
                "description": .string("watch demo"),
            ]),
            callID: "mon-live-1",
            process: execution,
            host: host
        )
        guard case .success(let output) = result else {
            Issue.record("monitor dispatch failed: \(result)")
            return
        }
        guard case .object(let value) = output.value,
              case .string(let taskID)? = value["taskId"]
        else {
            Issue.record("monitor output must carry taskId, got \(output.value)")
            return
        }
        #expect(value["persistent"] == .bool(false))
        #expect(value["timeoutMs"] == .number(.uint64(36_000_000)))
        #expect(output.promptText.contains("\"taskId\""))

        // The task is REAL and owned by this session, stamped `.monitor` —
        // the field `/tasks`'s is_monitor arm reads.
        var observed = await execution.waitForCompletion(taskID, timeout: .seconds(15))
        if observed == nil {
            observed = await execution.taskSnapshot(taskID)
        }
        let snapshot = try #require(
            observed,
            "the monitor's task must be visible through the owning execution"
        )
        #expect(snapshot.kind == .monitor)
        #expect(snapshot.displayCommand == "[monitor] watch demo")
        #expect(snapshot.description == "watch demo")

        // Its stdout arrives through the sink as wrapped events (the real
        // poll loop; bounded wait, no fixed sleeps).
        let sawEvents = await pollUntil(seconds: 15) {
            let events = await collector.events
            return events.contains {
                $0.taskID == taskID
                    && $0.eventText.contains("hello")
                    && $0.eventText.hasPrefix("<monitor-event description=\"watch demo\" task_id=\"\(taskID)\">")
            }
        }
        #expect(sawEvents, "monitor stdout must reach the event sink wrapped")

        // `/tasks` renders the row with upstream's is_monitor arm
        // (status_blocks.rs:128): "Monitor", never "Task".
        let block = LivePagerTasksBlock.text(
            workflowRows: [],
            subagents: [],
            tasks: [snapshot],
            now: snapshot.endTime ?? Date()
        )
        #expect(block.contains("Monitor · watch demo"))
        #expect(!block.contains("Task · "))

        await host.shutdown()
        await backend.killAllBackgroundTasks()
    }

    @Test("the /tasks monitor row is byte-exact against status_blocks.rs:128,144-147")
    func tasksBlockMonitorRowBytePin() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ShellTaskSnapshot(
            taskID: "mon-1",
            command: "tail -f prod.log",
            cwd: FileManager.default.temporaryDirectory,
            startTime: start,
            kind: .monitor,
            description: "watch prod"
        )
        let block = LivePagerTasksBlock.text(
            workflowRows: [],
            subagents: [],
            tasks: [snapshot],
            now: start.addingTimeInterval(5)
        )
        #expect(block == "Task (1):\n  running  Monitor · watch prod  (5.0s)")
    }
}

private func pollUntil(
    seconds: Double,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
