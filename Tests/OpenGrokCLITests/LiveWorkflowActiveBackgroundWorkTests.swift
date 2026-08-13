// LiveWorkflowActiveBackgroundWorkTests.swift
//
// Status-chip push for active workflow runs through the live registry seam
// used by `/tasks` (`RhaiWorkflowRunRegistry` via
// `LiveWorkflowActiveBackgroundWork` → `LiveActiveBackgroundWorkSink`).
//
// Count definition: Rust `TasksPane::running_count` workflow half — every
// run with status `active` (`views/workflows.rs:55-57`). Workflow child
// agents are excluded structurally (`LiveWorkflowChildAgent`), not via this
// sink.

import Foundation
import OpenGrokSessionPersistence
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokWorkflow
import Testing
@testable import OpenGrokCLI

// MARK: - Fakes

/// Parks agent spawns so a run stays `.active` long enough for sink asserts.
private actor ParkingWorkflowHost: RhaiWorkflowHost {
    private let gate: WorkflowSampleGate
    private var used: UInt64 = 0

    nonisolated let maxConcurrentAgents: Int = 4

    init(gate: WorkflowSampleGate) {
        self.gate = gate
    }

    func reserveAgentCalls(_ count: UInt64) throws {}
    func releaseAgentCalls(_ count: UInt64) {}

    func spawnAgent(_ options: RhaiAgentOptions) async throws -> RhaiAgentResult {
        await gate.wait()
        if Task.isCancelled || gate.isCancelled {
            throw RhaiHostError.cancelled
        }
        used += 1
        return RhaiAgentResult(
            agentID: options.label ?? "parked-\(used)",
            success: true,
            output: .object([:]),
            tokensUsed: 1
        )
    }

    func phase(title: String, replayed: Bool) {}
    func log(message: String, replayed: Bool) {}
    func telemetry(name: String, fields: JSONValue, replayed: Bool) {}
    func budgetState() -> RhaiBudgetState {
        RhaiBudgetState(total: 64, spent: used, reserved: 0, remaining: 64 - used)
    }
    func renderTemplate(name: String, variables: JSONValue) -> String { "" }
    func writeScratchFile(name: String, content: String) -> String { name }
    func readScratchFile(name: String) -> String { "" }
    func gitDiffSince(commit: String) -> String { "" }
}

private actor QuickWorkflowHost: RhaiWorkflowHost {
    nonisolated let maxConcurrentAgents: Int = 4
    private var used: UInt64 = 0

    func reserveAgentCalls(_ count: UInt64) throws {}
    func releaseAgentCalls(_ count: UInt64) {}

    func spawnAgent(_ options: RhaiAgentOptions) async throws -> RhaiAgentResult {
        used += 1
        return RhaiAgentResult(
            agentID: options.label ?? "quick-\(used)",
            success: true,
            output: .object([:]),
            tokensUsed: 1
        )
    }

    func phase(title: String, replayed: Bool) {}
    func log(message: String, replayed: Bool) {}
    func telemetry(name: String, fields: JSONValue, replayed: Bool) {}
    func budgetState() -> RhaiBudgetState {
        RhaiBudgetState(total: 64, spent: used, reserved: 0, remaining: 64 - used)
    }
    func renderTemplate(name: String, variables: JSONValue) -> String { "" }
    func writeScratchFile(name: String, content: String) -> String { name }
    func readScratchFile(name: String) -> String { "" }
    func gitDiffSince(commit: String) -> String { "" }
}

private final class WorkflowSampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Park until `release` / `cancelAndRelease`. Lock work stays in the
    /// synchronous `enqueueOrResume` helper so the async region never
    /// touches `NSLock`, and so `release` cannot sneak between a
    /// released-check and append (cancel-then-fire → lost waiter).
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueueOrResume(continuation)
        }
    }

    func release() {
        let waiting = takeWaiters(cancel: false)
        for continuation in waiting {
            continuation.resume()
        }
    }

    func cancelAndRelease() {
        let waiting = takeWaiters(cancel: true)
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// Either resumes immediately (gate already open) or parks under the
    /// lock. Called only from the `withCheckedContinuation` setup closure,
    /// which runs synchronously before suspension.
    private func enqueueOrResume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if released {
            lock.unlock()
            continuation.resume()
            return
        }
        continuations.append(continuation)
        lock.unlock()
    }

    private func takeWaiters(cancel: Bool) -> [CheckedContinuation<Void, Never>] {
        lock.lock()
        if cancel { cancelled = true }
        released = true
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        return waiting
    }
}

private final class WorkflowEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LiveActiveBackgroundWorkEvent] = []

    /// Sink is `async`; lock mutation stays in the synchronous `record`
    /// helper so the concurrency checker does not see `NSLock` inside an
    /// async region.
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

    func reset() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

private func temporaryWorkflowDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("workflow-abw-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func quickScript(name: String = "quick") -> String {
    """
    let meta = #{ name: "\(name)", description: "d", when_to_use: "w" };
    agent("do", #{ label: "worker" });
    complete(#{ ok: true })
    """
}

private func parkedScript(name: String = "parked") -> String {
    """
    let meta = #{ name: "\(name)", description: "d", when_to_use: "w" };
    agent("hold", #{ label: "worker" });
    complete(#{ ok: true })
    """
}

// MARK: - Tests

@Suite("workflow active-background-work sink", .serialized)
struct LiveWorkflowActiveBackgroundWorkSinkTests {

    @Test("active→completed upserts then removes through LiveActiveBackgroundWorkSink")
    func activeToTerminalCompleted() async throws {
        let directory = temporaryWorkflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(
            store: WorkflowSessionStore(directory: directory)
        )
        let recorder = WorkflowEventRecorder()
        await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
            on: registry,
            recorder.sink
        )

        let record = try await registry.start(
            script: quickScript(),
            hostFactory: RhaiWorkflowHostFactory(make: { _ in QuickWorkflowHost() })
        )
        let final = try await registry.awaitCompletion(runID: record.runID)
        #expect(final.status == .completed)

        let events = await recorder.waitUntilCount(2)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .workflow,
            id: record.runID
        ))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .workflow,
            id: record.runID
        ))
        #expect(events == [upsert, remove])

        var cache = LiveActiveBackgroundWorkCache()
        for event in events { _ = cache.apply(event) }
        #expect(cache.count(of: .workflow) == 0)
    }

    @Test("failure (host unavailable) removes after upsert")
    func failureSequence() async throws {
        let directory = temporaryWorkflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(
            store: WorkflowSessionStore(directory: directory)
        )
        let recorder = WorkflowEventRecorder()
        await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
            on: registry,
            recorder.sink
        )

        struct HostBoom: Error {}
        let record = try await registry.start(
            script: quickScript(name: "fail"),
            hostFactory: RhaiWorkflowHostFactory(make: { _ in throw HostBoom() })
        )
        let final = try await registry.awaitCompletion(runID: record.runID)
        #expect(final.status == .failed)

        let events = await recorder.waitUntilCount(2)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .workflow,
            id: record.runID
        ))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .workflow,
            id: record.runID
        ))
        #expect(events == [upsert, remove])
    }

    @Test("cancel while active emits upsert then remove")
    func cancelSequence() async throws {
        let directory = temporaryWorkflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(
            store: WorkflowSessionStore(directory: directory)
        )
        let gate = WorkflowSampleGate()
        let recorder = WorkflowEventRecorder()
        await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
            on: registry,
            recorder.sink
        )
        defer { gate.cancelAndRelease() }

        let record = try await registry.start(
            script: parkedScript(name: "cancel"),
            hostFactory: RhaiWorkflowHostFactory(make: { _ in ParkingWorkflowHost(gate: gate) })
        )
        let upserted = await recorder.waitUntilCount(1)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .workflow,
            id: record.runID
        ))
        #expect(upserted == [upsert])

        try await registry.cancel(runID: record.runID)
        gate.cancelAndRelease()
        let final = try await registry.awaitCompletion(runID: record.runID)
        #expect(final.status == .cancelled)

        let events = await recorder.waitUntilCount(2)
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .workflow,
            id: record.runID
        ))
        #expect(events == [upsert, remove])
    }

    @Test("sink install publishes already-active loaded run ids")
    func loadedActivePublishedOnInstall() async throws {
        let directory = temporaryWorkflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowSessionStore(directory: directory)
        try await store.insert(WorkflowRunRecord(
            runID: "wf_loaded_active",
            workflowName: "loaded",
            scriptHash: "h",
            argumentsHash: "h",
            status: .active,
            agentBudget: 8
        ))

        let registry = RhaiWorkflowRunRegistry(store: store)
        let recorder = WorkflowEventRecorder()
        await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
            on: registry,
            recorder.sink
        )

        let events = await recorder.waitUntilCount(1)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .workflow,
            id: "wf_loaded_active"
        ))
        #expect(events == [upsert])

        // Restore reconciles active→interrupted and removes from the chip.
        _ = try await registry.restore()
        let afterRestore = await recorder.waitUntilCount(2)
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .workflow,
            id: "wf_loaded_active"
        ))
        #expect(afterRestore == [upsert, remove])
    }

    @Test("repeated active status and reinstall are idempotent on the cache")
    func repeatedStatusIdempotent() async throws {
        let directory = temporaryWorkflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(
            store: WorkflowSessionStore(directory: directory)
        )
        let gate = WorkflowSampleGate()
        let recorder = WorkflowEventRecorder()
        defer { gate.cancelAndRelease() }

        let record = try await registry.start(
            script: parkedScript(name: "idempotent"),
            hostFactory: RhaiWorkflowHostFactory(make: { _ in ParkingWorkflowHost(gate: gate) })
        )
        // No sink yet — start must not require an observer.
        #expect(recorder.snapshot().isEmpty)

        await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
            on: registry,
            recorder.sink
        )
        _ = await recorder.waitUntilCount(1)

        // Reinstall republishes the same active id (generation-safe replace).
        await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
            on: registry,
            recorder.sink
        )
        let events = await recorder.waitUntilCount(2)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .workflow,
            id: record.runID
        ))
        #expect(events.allSatisfy { $0 == upsert })
        #expect(events.count == 2)

        var cache = LiveActiveBackgroundWorkCache()
        for event in events { _ = cache.apply(event) }
        #expect(cache.count(of: .workflow) == 1)
        #expect(cache.hasActive)

        // Terminal remove once; a second remove (shutdown after finish) is a
        // latch no-op at the registry — shutdown with empty published emits
        // nothing further.
        gate.release()
        let final = try await registry.awaitCompletion(runID: record.runID)
        #expect(final.status == .completed)
        let withRemove = await recorder.waitUntilCount(3)
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .workflow,
            id: record.runID
        ))
        #expect(withRemove.last == remove)
        for event in withRemove.dropFirst(events.count) {
            _ = cache.apply(event)
        }
        #expect(cache.count(of: .workflow) == 0)

        let countBeforeShutdown = recorder.snapshot().count
        await LiveWorkflowActiveBackgroundWork.shutdownActiveBackgroundWork(on: registry)
        #expect(recorder.snapshot().count == countBeforeShutdown)
    }

    @Test("shutdown removes still-active ids and clears the sink")
    func shutdownRemovesActive() async throws {
        let directory = temporaryWorkflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(
            store: WorkflowSessionStore(directory: directory)
        )
        let gate = WorkflowSampleGate()
        let recorder = WorkflowEventRecorder()
        await LiveWorkflowActiveBackgroundWork.setActiveBackgroundWorkSink(
            on: registry,
            recorder.sink
        )
        defer { gate.cancelAndRelease() }

        let record = try await registry.start(
            script: parkedScript(name: "shutdown"),
            hostFactory: RhaiWorkflowHostFactory(make: { _ in ParkingWorkflowHost(gate: gate) })
        )
        _ = await recorder.waitUntilCount(1)

        await LiveWorkflowActiveBackgroundWork.shutdownActiveBackgroundWork(on: registry)
        let events = await recorder.waitUntilCount(2)
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
            kind: .workflow,
            id: record.runID
        ))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
            kind: .workflow,
            id: record.runID
        ))
        #expect(events == [upsert, remove])

        // Cleared sink: a later terminal finish must not deliver to the
        // retired recorder.
        recorder.reset()
        gate.release()
        _ = try await registry.awaitCompletion(runID: record.runID)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.snapshot().isEmpty)
    }
}
