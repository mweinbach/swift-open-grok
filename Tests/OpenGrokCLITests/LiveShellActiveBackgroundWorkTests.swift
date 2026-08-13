// LiveShellActiveBackgroundWorkTests.swift
//
// Status-chip push events for shell/monitor background tasks through the
// real owned-process bridge (`OpenGrokShellOwnedProcessExecution`) and
// `LiveShellActiveBackgroundWork` translator — not a composition mock.
//
// Monitors share `.shell` (they register via `runBackground` on the same
// ownership map); asserting a single upsert per monitor task id guards
// against a second emit from `LiveMonitorHost.track`.

import Foundation
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

// MARK: - Recorders / fakes

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LiveActiveBackgroundWorkEvent] = []

    /// Sink is `async`; lock mutation stays in this synchronous helper so the
    /// concurrency checker does not see `NSLock` inside an async region.
    var sink: LiveActiveBackgroundWorkSink {
        { [self] event in
            self.record(event)
        }
    }

    func record(_ event: LiveActiveBackgroundWorkEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [LiveActiveBackgroundWorkEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func waitUntilCount(
        _ count: Int,
        timeoutSeconds: TimeInterval = 5
    ) async -> [LiveActiveBackgroundWorkEvent] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let current = snapshot()
            if current.count >= count { return current }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return snapshot()
    }
}

/// Controllable backend for demotion / terminal races without a real process.
/// Completion uses `waitForCompletion` (OwnedProcessExecution's non-local
/// fallback) — `LocalShellProcessBackend` is covered separately via the
/// registry output-stream path.
private actor ControllableShellBackend: ShellProcessBackend {
    private var nextOrdinal = 0
    private var completed: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var owners: [String: String] = [:]
    private(set) var backgroundRequests: [ShellCommandRequest] = []

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        nextOrdinal += 1
        let taskID = "auto-\(nextOrdinal)"
        owners[taskID] = request.ownerSessionID ?? ""
        return ShellCommandResult(
            combinedOutput: "partial",
            backgrounded: true,
            taskID: taskID
        )
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        backgroundRequests.append(request)
        nextOrdinal += 1
        let taskID = "bg-\(nextOrdinal)"
        owners[taskID] = request.ownerSessionID ?? ""
        return ShellBackgroundHandle(taskID: taskID)
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? {
        guard owners[taskID] != nil else { return nil }
        return snapshot(taskID: taskID)
    }

    func killTask(_ taskID: String) async -> ShellKillOutcome {
        guard owners[taskID] != nil else { return .notFound }
        if completed.contains(taskID) { return .alreadyExited }
        finish(taskID)
        return .killed
    }

    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {
        for taskID in owners.keys where !completed.contains(taskID) {
            finish(taskID)
        }
    }

    func killAllBackgroundTasks(ownerSessionID: String) async {
        for (taskID, owner) in owners where owner == ownerSessionID && !completed.contains(taskID) {
            finish(taskID)
        }
    }

    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }

    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        guard owners[taskID] != nil else { return nil }
        if !completed.contains(taskID) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[taskID, default: []].append(continuation)
            }
        }
        return snapshot(taskID: taskID)
    }

    func listTasks() async -> [ShellTaskSnapshot] {
        owners.keys.sorted().map { snapshot(taskID: $0) }
    }

    func shellCWD() async -> URL? { nil }

    func complete(_ taskID: String) {
        finish(taskID)
    }

    private func finish(_ taskID: String) {
        guard !completed.contains(taskID) else { return }
        completed.insert(taskID)
        let pending = waiters.removeValue(forKey: taskID) ?? []
        for continuation in pending {
            continuation.resume()
        }
    }

    private func snapshot(taskID: String) -> ShellTaskSnapshot {
        ShellTaskSnapshot(
            taskID: taskID,
            command: "controllable",
            cwd: URL(fileURLWithPath: "/tmp"),
            completed: completed.contains(taskID),
            ownerSessionID: owners[taskID],
            isBackgrounded: true
        )
    }
}

private func makeWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-shell-abw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func bridgeRequest(
    command: String,
    callID: String,
    cwd: URL,
    kind: ShellTaskKind = .bash,
    autoBackgroundOnTimeout: Bool = false
) -> ShellCommandRequest {
    ShellCommandRequest(
        command: command,
        workingDirectory: cwd,
        timeout: .seconds(30),
        toolCallID: callID,
        autoBackgroundOnTimeout: autoBackgroundOnTimeout,
        kind: kind,
        ownerSessionID: nil
    )
}

// MARK: - Controllable bridge sequences

@Suite("shell active-background-work sink", .serialized)
struct LiveShellActiveBackgroundWorkSinkTests {
    @Test("explicit background upserts then removes on completion")
    func explicitBackgroundComplete() async throws {
        let cwd = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let backend = ControllableShellBackend()
        let process = try OpenGrokShellOwnedProcessExecution(
            sessionID: "shell-abw",
            workingDirectory: cwd,
            backend: backend
        )
        let recorder = EventRecorder()
        await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
            recorder.sink,
            on: process
        )

        let handle = try await process.runBackground(
            bridgeRequest(command: "sleep 1", callID: "call-bg", cwd: cwd)
        )
        let afterUpsert = await recorder.waitUntilCount(1)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .shell,
            id: handle.taskID
        ))
        #expect(afterUpsert == [upsert])

        await backend.complete(handle.taskID)
        let events = await recorder.waitUntilCount(2)
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .shell,
            id: handle.taskID
        ))
        #expect(events == [upsert, remove])
    }

    @Test("foreground demotion upserts after ownership registration")
    func demotionUpserts() async throws {
        let cwd = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let backend = ControllableShellBackend()
        let process = try OpenGrokShellOwnedProcessExecution(
            sessionID: "shell-abw-demote",
            workingDirectory: cwd,
            backend: backend
        )
        let recorder = EventRecorder()
        await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
            recorder.sink,
            on: process
        )

        let result = try await process.run(
            bridgeRequest(command: "sleep 60", callID: "call-demote", cwd: cwd)
        )
        #expect(result.backgrounded)
        let taskID = try #require(result.taskID)
        let afterUpsert = await recorder.waitUntilCount(1)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .shell,
            id: taskID
        ))
        #expect(afterUpsert == [upsert])

        await backend.complete(taskID)
        let events = await recorder.waitUntilCount(2)
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .shell,
            id: taskID
        ))
        #expect(events == [upsert, remove])
    }

    @Test("kill removes once; duplicate terminal flush does not double-emit")
    func killThenFlushNoDoubleRemove() async throws {
        let cwd = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let backend = ControllableShellBackend()
        let process = try OpenGrokShellOwnedProcessExecution(
            sessionID: "shell-abw-kill",
            workingDirectory: cwd,
            backend: backend
        )
        let recorder = EventRecorder()
        await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
            recorder.sink,
            on: process
        )

        let handle = try await process.runBackground(
            bridgeRequest(command: "sleep 60", callID: "call-kill", cwd: cwd)
        )
        _ = await recorder.waitUntilCount(1)

        let outcome = await process.killTask(handle.taskID)
        #expect(outcome == .killed)
        let afterKill = await recorder.waitUntilCount(2)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .shell,
            id: handle.taskID
        ))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .shell,
            id: handle.taskID
        ))
        #expect(afterKill == [upsert, remove])

        // cancelAll flushes remaining counted ids; latch must suppress a
        // second remove for an already-terminal task.
        await process.cancelAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.snapshot() == [upsert, remove])
    }

    @Test("cancelAll / host shutdown removes still-active ids")
    func shutdownRemovesActive() async throws {
        let cwd = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let backend = ControllableShellBackend()
        let process = try OpenGrokShellOwnedProcessExecution(
            sessionID: "shell-abw-shutdown",
            workingDirectory: cwd,
            backend: backend
        )
        let recorder = EventRecorder()
        await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
            recorder.sink,
            on: process
        )

        let handle = try await process.runBackground(
            bridgeRequest(command: "sleep 60", callID: "call-shutdown", cwd: cwd)
        )
        let afterUpsert = await recorder.waitUntilCount(1)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .shell,
            id: handle.taskID
        ))
        #expect(afterUpsert == [upsert])

        await process.cancelAll()
        let events = await recorder.waitUntilCount(2)
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .shell,
            id: handle.taskID
        ))
        #expect(events == [upsert, remove])
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.snapshot() == [upsert, remove])
    }

    @Test("monitor rides shell backend — one .shell upsert, not a double count")
    func monitorSingleShellUpsert() async throws {
        let cwd = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let backend = ControllableShellBackend()
        let process = try OpenGrokShellOwnedProcessExecution(
            sessionID: "shell-abw-monitor",
            workingDirectory: cwd,
            backend: backend
        )
        let recorder = EventRecorder()
        await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
            recorder.sink,
            on: process
        )
        let host = LiveMonitorHost(context: LiveMonitorHost.Context(
            sessionID: "shell-abw-monitor",
            outputDirectory: cwd
        ))

        let result = await LiveMonitorTools.invoke(
            args: .object([
                "command": .string("printf 'line\\n'"),
                "description": .string("chip monitor"),
            ]),
            callID: "mon-abw-1",
            process: process,
            host: host
        )
        guard case .success(let output) = result else {
            Issue.record("monitor dispatch failed: \(result)")
            await host.shutdown()
            return
        }
        guard case .object(let value) = output.value,
              case .string(let taskID)? = value["taskId"]
        else {
            Issue.record("monitor output must carry taskId, got \(output.value)")
            await host.shutdown()
            return
        }

        let afterUpsert = await recorder.waitUntilCount(1)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .shell,
            id: taskID
        ))
        #expect(afterUpsert == [upsert])
        // No second upsert from pipeline track — monitors share `.shell`.
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(recorder.snapshot() == [upsert])

        await backend.complete(taskID)
        let events = await recorder.waitUntilCount(2)
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .shell,
            id: taskID
        ))
        #expect(events == [upsert, remove])
        await host.shutdown()
    }
}

// MARK: - Real LocalShellProcessBackend (output-stream completion)

@Suite("shell active-background-work local backend", .serialized)
struct LiveShellActiveBackgroundWorkLocalBackendTests {
    @Test("real registry completion removes without marking blockWaited")
    func localBackendCompletePreservesBlockWaited() async throws {
        let cwd = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let backend = LocalShellProcessBackend(
            inheritedEnvironment: ProcessInfo.processInfo.environment
        )
        let process = try OpenGrokShellOwnedProcessExecution(
            sessionID: "shell-abw-local",
            workingDirectory: cwd,
            backend: backend
        )
        let recorder = EventRecorder()
        await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
            recorder.sink,
            on: process
        )

        let handle = try await process.runBackground(
            bridgeRequest(command: "printf done\\n", callID: "call-local", cwd: cwd)
        )
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .shell,
            id: handle.taskID
        ))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .shell,
            id: handle.taskID
        ))
        let events = await recorder.waitUntilCount(2, timeoutSeconds: 15)
        #expect(events == [upsert, remove])

        // Chip waiter must not stamp blockWaited — TaskCompleted wakes stay live.
        let snapshot = await process.taskSnapshot(handle.taskID)
        #expect(snapshot?.completed == true)
        #expect(snapshot?.blockWaited == false)

        await process.cancelAll()
        await backend.killAllBackgroundTasks()
    }

    @Test("composition install reaches registered session execution")
    func compositionInstall() async throws {
        let cwd = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let backend = ControllableShellBackend()
        let composition = OpenGrokShellToolRuntimeComposition(
            processBackend: backend,
            runtime: ClosureOpenGrokShellToolRuntime { _, _ in
                .failure(.unsupported("unused"))
            }
        )
        try await composition.registerSession(
            sessionID: "comp-abw",
            workingDirectory: cwd
        )
        let recorder = EventRecorder()
        await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
            recorder.sink,
            on: composition
        )

        let process = try await composition.execution(
            for: "comp-abw",
            workingDirectory: cwd
        )
        let handle = try await process.runBackground(
            bridgeRequest(command: "sleep 1", callID: "call-comp", cwd: cwd)
        )
        _ = await recorder.waitUntilCount(1)
        await backend.complete(handle.taskID)
        let events = await recorder.waitUntilCount(2)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .shell,
            id: handle.taskID
        ))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .shell,
            id: handle.taskID
        ))
        #expect(events == [upsert, remove])
        await composition.shutdown()
    }
}
