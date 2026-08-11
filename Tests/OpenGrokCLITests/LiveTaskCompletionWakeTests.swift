// LiveTaskCompletionWakeTests.swift
//
// The TaskCompleted auto-wake: exactly-once wake per completed task,
// correct formatting for bash and monitor tasks, suppression of
// block-waited tasks, and integration with the monitor pipeline.

import Foundation
import OpenGrokShell
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

/// Captures wake sink messages without mutating a non-Sendable local `var`
/// from a `@Sendable` closure (Swift 6 / macOS 27 SDK).
private final class WakeMessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    var count: Int { all.count }
    var isEmpty: Bool { all.isEmpty }
    subscript(_ index: Int) -> String { all[index] }
}

// MARK: - Formatting pins (task_completion.rs tests)

@Suite("TaskCompleted formatting")
struct LiveTaskCompletionFormattingTests {
    @Test("monitor completion: exit 0 carries the ended wording and poll pointer")
    func monitorExitZero() {
        let task = ShellTaskSnapshot(
            taskID: "mon-1",
            command: "tail -f /var/log/app",
            displayCommand: "[monitor] app logs",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 0,
            completed: true,
            kind: .monitor
        )
        let msg = LiveTaskCompletionFormatting.formatMonitorCompletion(task)
        #expect(msg.contains("[monitor ended: exited (code 0)]"))
        #expect(msg.contains("app logs"))
        #expect(msg.contains("tail -f /var/log/app"))
        #expect(msg.contains("get_command_or_subagent_output(\"mon-1\")"))
    }

    @Test("monitor completion: signal renders killed wording")
    func monitorSignal() {
        let task = ShellTaskSnapshot(
            taskID: "mon-sig",
            command: "sleep 999",
            displayCommand: "[monitor] sleep",
            cwd: FileManager.default.temporaryDirectory,
            signal: "SIGTERM",
            completed: true,
            kind: .monitor
        )
        let msg = LiveTaskCompletionFormatting.formatMonitorCompletion(task)
        #expect(msg.contains("[monitor ended: killed by signal SIGTERM]"))
        #expect(msg.contains("get_command_or_subagent_output(\"mon-sig\")"))
    }

    @Test("monitor completion: no display command falls back to 'monitor'")
    func monitorNoDescription() {
        let task = ShellTaskSnapshot(
            taskID: "mon-bare",
            command: "watch log",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 1,
            completed: true,
            kind: .monitor
        )
        let msg = LiveTaskCompletionFormatting.formatMonitorCompletion(task)
        #expect(msg.contains("Description: monitor"))
    }

    @Test("bash completion: exit 0 renders correctly")
    func bashExitZero() {
        let task = ShellTaskSnapshot(
            taskID: "bg-1",
            command: "cargo test",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 0,
            completed: true
        )
        let msg = LiveTaskCompletionFormatting.formatBashCompletion(task)
        #expect(msg.contains("bg-1"))
        #expect(msg.contains("exit code: 0"))
        #expect(msg.contains("cargo test"))
        #expect(msg.contains("get_command_or_subagent_output(\"bg-1\")"))
    }

    @Test("bash completion: signal with short duration adds the pkill hint")
    func bashSignalShortDuration() {
        let now = Date()
        let task = ShellTaskSnapshot(
            taskID: "sig-short",
            command: "pkill -f ./server && ./server",
            cwd: FileManager.default.temporaryDirectory,
            startTime: now,
            endTime: now,
            signal: "SIGTERM",
            completed: true
        )
        let msg = LiveTaskCompletionFormatting.formatBashCompletion(task)
        #expect(msg.contains("terminated by signal SIGTERM"))
        #expect(msg.contains("wrapper bash may have been killed"))
    }

    @Test("bash completion: signal with long duration has no hint")
    func bashSignalLongDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let task = ShellTaskSnapshot(
            taskID: "sig-long",
            command: "./server",
            cwd: FileManager.default.temporaryDirectory,
            startTime: start,
            endTime: start.addingTimeInterval(5),
            signal: "SIGTERM",
            completed: true
        )
        let msg = LiveTaskCompletionFormatting.formatBashCompletion(task)
        #expect(msg.contains("terminated by signal SIGTERM"))
        #expect(!msg.contains("wrapper bash may have been killed"))
    }

    @Test("bash completion: unknown exit code renders 'unknown'")
    func bashUnknownExit() {
        let task = ShellTaskSnapshot(
            taskID: "bg-unk",
            command: "server",
            cwd: FileManager.default.temporaryDirectory,
            completed: true
        )
        let msg = LiveTaskCompletionFormatting.formatBashCompletion(task)
        #expect(msg.contains("exit code: unknown"))
    }

    @Test("bash completion: display command preferred over raw command")
    func bashDisplayCommand() {
        let task = ShellTaskSnapshot(
            taskID: "bg-dc",
            command: "unshare --mount -- cargo test",
            displayCommand: "cargo test",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 0,
            completed: true
        )
        let msg = LiveTaskCompletionFormatting.formatBashCompletion(task)
        #expect(msg.contains("cargo test"))
        #expect(!msg.contains("unshare"))
    }
}

// MARK: - Exactly-once wake semantics

@Suite("TaskCompleted wake: exactly-once")
struct LiveTaskCompletionWakeExactlyOnceTests {
    @Test("a completed task fires exactly one wake")
    func exactlyOnce() async {
        let wake = LiveTaskCompletionWake(ownerSessionID: nil)
        let delivered = WakeMessageBox()
        await wake.setWakeSink { msg in delivered.append(msg) }
        let task = ShellTaskSnapshot(
            taskID: "t1",
            command: "echo done",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 0,
            completed: true
        )
        let first = await wake.reportIfNew(task)
        #expect(first == true)
        #expect(delivered.count == 1)

        let second = await wake.reportIfNew(task)
        #expect(second == false)
        #expect(delivered.count == 1)
    }

    @Test("a running task does not fire a wake")
    func noWakeWhileRunning() async {
        let wake = LiveTaskCompletionWake(ownerSessionID: nil)
        let delivered = WakeMessageBox()
        await wake.setWakeSink { msg in delivered.append(msg) }
        let task = ShellTaskSnapshot(
            taskID: "t-running",
            command: "sleep 100",
            cwd: FileManager.default.temporaryDirectory,
            completed: false
        )
        let result = await wake.reportIfNew(task)
        #expect(result == false)
        #expect(delivered.isEmpty)
    }

    @Test("a block-waited task is suppressed (the model already saw it)")
    func blockWaitedSuppressed() async {
        let wake = LiveTaskCompletionWake(ownerSessionID: nil)
        let delivered = WakeMessageBox()
        await wake.setWakeSink { msg in delivered.append(msg) }
        let task = ShellTaskSnapshot(
            taskID: "t-waited",
            command: "echo hi",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 0,
            completed: true,
            blockWaited: true
        )
        let result = await wake.reportIfNew(task)
        #expect(result == false)
        #expect(delivered.isEmpty)
        #expect(await wake.reported.contains("t-waited"))
    }

    @Test("suppress prevents a subsequent wake")
    func suppressPreventsWake() async {
        let wake = LiveTaskCompletionWake(ownerSessionID: nil)
        let delivered = WakeMessageBox()
        await wake.setWakeSink { msg in delivered.append(msg) }
        await wake.suppress("t-pre")
        let task = ShellTaskSnapshot(
            taskID: "t-pre",
            command: "echo hi",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 0,
            completed: true
        )
        let result = await wake.reportIfNew(task)
        #expect(result == false)
        #expect(delivered.isEmpty)
    }

    @Test("owner scoping: another session's tasks do not wake this session")
    func ownerScoping() async {
        let wake = LiveTaskCompletionWake(ownerSessionID: "session-A")
        let delivered = WakeMessageBox()
        await wake.setWakeSink { msg in delivered.append(msg) }
        let foreign = ShellTaskSnapshot(
            taskID: "t-foreign",
            command: "echo bye",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 0,
            completed: true,
            ownerSessionID: "session-B"
        )
        await wake.startWatching(process: StubWakeExecution(tasks: [foreign]))
        try? await Task.sleep(nanoseconds: 50_000_000)
        await wake.shutdown()
        #expect(delivered.isEmpty)
    }

    @Test("monitor completion routes through monitor formatter")
    func monitorRouting() async {
        let wake = LiveTaskCompletionWake(ownerSessionID: nil)
        let delivered = WakeMessageBox()
        await wake.setWakeSink { msg in delivered.append(msg) }
        let task = ShellTaskSnapshot(
            taskID: "mon-route",
            command: "tail -f log",
            displayCommand: "[monitor] log watcher",
            cwd: FileManager.default.temporaryDirectory,
            exitCode: 0,
            completed: true,
            kind: .monitor
        )
        await wake.reportIfNew(task)
        #expect(delivered.count == 1)
        #expect(delivered[0].contains("Monitor \"mon-route\" ended"))
        #expect(delivered[0].contains("[monitor ended: exited (code 0)]"))
    }
}

// MARK: - Monitor pipeline integration

@Suite("TaskCompleted wake: monitor pipeline integration")
struct LiveTaskCompletionWakeMonitorTests {
    @Test("monitor completion fires exactly one wake through the host")
    func monitorPipelineFiresWake() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-wake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFile = directory.appendingPathComponent("monitor-wake.log")

        let host = LiveMonitorHost(context: LiveMonitorHost.Context(
            sessionID: "wake-test",
            outputDirectory: directory
        ))
        let wake = LiveTaskCompletionWake(ownerSessionID: nil)
        let wakeMessages = WakeMessageBox()
        await wake.setWakeSink { msg in wakeMessages.append(msg) }
        await host.setCompletionWake(wake)

        let collector = MonitorWakeEventCollector()
        await host.setEventSink { event in await collector.record(event) }

        let execution = StubWakeExecution(tasks: [])
        let completedSnapshot = ShellTaskSnapshot(
            taskID: "mon-w1",
            command: "echo done",
            displayCommand: "[monitor] build watcher",
            cwd: directory,
            exitCode: 0,
            completed: true,
            kind: .monitor
        )
        await execution.set(completedSnapshot)
        await host.track(taskID: "mon-w1", description: "build watcher", outputFile: outputFile)
        try "final output\n".write(to: outputFile, atomically: false, encoding: .utf8)

        let finished = await host.tick(taskID: "mon-w1", process: execution)
        #expect(finished == true)

        #expect(wakeMessages.count == 1)
        #expect(wakeMessages[0].contains("Monitor \"mon-w1\" ended"))
        #expect(wakeMessages[0].contains("[monitor ended: exited (code 0)]"))
        #expect(wakeMessages[0].contains("build watcher"))

        let secondTick = await host.tick(taskID: "mon-w1", process: execution)
        #expect(secondTick == true)
        #expect(wakeMessages.count == 1)

        let events = await collector.events
        for event in events {
            #expect(!event.eventText.contains("monitor ended"))
        }
    }
}

// MARK: - Test helpers

private actor StubWakeExecution: OpenGrokShellProcessExecution {
    nonisolated let sessionID = "wake-stub"
    nonisolated let workingDirectory = FileManager.default.temporaryDirectory

    private var snapshots: [String: ShellTaskSnapshot] = [:]

    init(tasks: [ShellTaskSnapshot]) {
        for task in tasks {
            snapshots[task.taskID] = task
        }
    }

    func set(_ snapshot: ShellTaskSnapshot) {
        snapshots[snapshot.taskID] = snapshot
    }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        throw CLIApplicationError.failed("stub")
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        throw CLIApplicationError.failed("stub")
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

private actor MonitorWakeEventCollector {
    private(set) var events: [LiveMonitorEvent] = []
    func record(_ event: LiveMonitorEvent) { events.append(event) }
}
