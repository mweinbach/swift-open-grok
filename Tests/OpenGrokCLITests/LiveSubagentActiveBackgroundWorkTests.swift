// LiveSubagentActiveBackgroundWorkTests.swift
//
// Status-chip push events for running subagents through the live host seam:
// real `LiveSubagentHost.spawn` / cancel / failure / shutdown, asserting the
// `LiveActiveBackgroundWorkSink` sequence (not a composition mock).
//
// Count filter matches Rust `TasksPane::running_count` subagent half
// (`tasks_pane.rs:1143-1146`): running children with no workflow run id.
// Swarm members share `withActiveBackgroundWorkCounting` so they count once.

import Foundation
import OpenGrokAgentCoordinator
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
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

/// Parks the first sample until `release()` so cancel/shutdown can observe
/// the upserted running state.
private final class SampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    /// Park until `release`. Lock work stays in the synchronous
    /// `enqueueOrResume` helper so the async region never touches `NSLock`,
    /// and so `release` cannot sneak between a released-check and append
    /// (cancel-then-fire → lost waiter).
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueueOrResume(continuation)
        }
    }

    func release() {
        let waiting = takeWaiters()
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

    private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
        lock.lock()
        released = true
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        return waiting
    }
}

private final class EventRecorder: @unchecked Sendable {
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
}

private struct SampleError: Error, Sendable {}

private struct ActiveBackgroundHostFixture {
    let home: URL
    let workspace: URL
    let host: LiveSubagentHost
    let recorder: EventRecorder
    private let root: URL

    enum SamplerMode {
        case succeed
        case fail
        case park(SampleGate)
    }

    init(sampler: SamplerMode = .succeed) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-subagent-abw-\(UUID().uuidString)",
                isDirectory: true
            )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]
        let securityContext = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false
        )
        recorder = EventRecorder()

        let liveSampler: OpenGrokLiveSampler
        switch sampler {
        case .succeed:
            liveSampler = OpenGrokLiveSampler { _, _ in
                OpenGrokLiveSamplingResponse(output: "child done")
            }
        case .fail:
            liveSampler = OpenGrokLiveSampler { _, _ in
                throw SampleError()
            }
        case .park(let gate):
            liveSampler = OpenGrokLiveSampler { _, _ in
                await gate.wait()
                return OpenGrokLiveSamplingResponse(output: "child done")
            }
        }

        host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: liveSampler,
            parentModel: "grok-4.5",
            workingDirectory: workspace,
            sessionID: "abw-session",
            openGrokHome: home,
            conversationStore: LiveConversationStore(openGrokHome: home),
            processBackend: InertShellBackend(),
            securityContext: securityContext,
            sandboxDecision: LiveSandboxDecision(
                profileName: "none",
                mode: .none,
                enforced: false
            ),
            permissionOptions: CLIPermissionOptions(),
            fileAccessPolicy: .allowAll,
            telemetryBootstrapContext: .empty,
            imageToolContext: nil,
            webToolContext: nil,
            environment: environment,
            parentCapabilityCeiling: nil,
            definitionContext: DefinitionResolutionContext(
                cwd: workspace,
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: ["grok-4.5"]
        ))
    }

    func installSink() async {
        await host.setActiveBackgroundWorkSink(recorder.sink)
    }

    func dispose() async {
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    static func spawnArgs(
        background: Bool,
        taskID: String? = nil,
        resumeFrom: String? = nil,
        prompt: String = "probe"
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "prompt": .string(prompt),
            "description": .string("abw probe"),
            "subagent_type": .string("general-purpose"),
            "background": .bool(background),
        ]
        if let taskID {
            object["task_id"] = .string(taskID)
        }
        if let resumeFrom {
            object["resume_from"] = .string(resumeFrom)
        }
        return .object(object)
    }
}

/// Await `fixture.dispose` after `operation` succeeds or throws — never
/// `defer { Task { … } }`. Serialized sink tests must not hand off a still-
/// parked host/sampler to the next case.
private func withAwaitedFixtureDispose(
    _ fixture: ActiveBackgroundHostFixture,
    releaseGate gate: SampleGate? = nil,
    operation: () async throws -> Void
) async rethrows {
    do {
        try await operation()
    } catch {
        gate?.release()
        await fixture.dispose()
        throw error
    }
    gate?.release()
    await fixture.dispose()
}

// MARK: - Predicate

@Suite("subagent active-background-work predicate")
struct LiveSubagentActiveBackgroundWorkPredicateTests {
    @Test("workflow markers are excluded; task/swarm/antigravity count")
    func workflowMarkersExcluded() {
        let task = OpenGrokChildRequest(
            id: "a",
            parentSessionID: "s",
            owner: .task
        )
        #expect(LiveSubagentHost.countsTowardActiveBackgroundWork(task))

        let swarm = OpenGrokChildRequest(
            id: "b",
            parentSessionID: "s",
            owner: .swarm
        )
        #expect(LiveSubagentHost.countsTowardActiveBackgroundWork(swarm))

        let antigravity = OpenGrokChildRequest(
            id: "c",
            parentSessionID: "s",
            owner: .antigravity
        )
        #expect(LiveSubagentHost.countsTowardActiveBackgroundWork(antigravity))

        let workflowOwner = OpenGrokChildRequest(
            id: "d",
            parentSessionID: "s",
            owner: .workflow
        )
        #expect(!LiveSubagentHost.countsTowardActiveBackgroundWork(workflowOwner))

        let workflowRunID = OpenGrokChildRequest(
            id: "e",
            parentSessionID: "s",
            workflowRunID: "run-1",
            owner: .task
        )
        #expect(!LiveSubagentHost.countsTowardActiveBackgroundWork(workflowRunID))
    }
}

// MARK: - Live host sequences

@Suite("subagent active-background-work sink", .serialized)
struct LiveSubagentActiveBackgroundWorkSinkTests {
    @Test("background spawn upserts then removes on normal completion")
    func backgroundSpawnSequence() async throws {
        let fixture = try ActiveBackgroundHostFixture(sampler: .succeed)
        await fixture.installSink()
        try await withAwaitedFixtureDispose(fixture) {
            let result = await fixture.host.spawn(
                args: ActiveBackgroundHostFixture.spawnArgs(
                    background: true,
                    taskID: "bg-child-1"
                ),
                toolCallID: "call-abw-bg"
            )
            guard case .success = result else {
                Issue.record("background spawn failed: \(result)")
                return
            }
            let events = await fixture.recorder.waitUntilCount(2)
            let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .subagent,
                id: "bg-child-1"
            ))
            let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .subagent,
                id: "bg-child-1"
            ))
            #expect(events == [upsert, remove])
        }
    }

    @Test("foreground failure terminalizes with upsert then remove")
    func failureSequence() async throws {
        let fixture = try ActiveBackgroundHostFixture(sampler: .fail)
        await fixture.installSink()
        try await withAwaitedFixtureDispose(fixture) {
            let result = await fixture.host.spawn(
                args: ActiveBackgroundHostFixture.spawnArgs(
                    background: false,
                    taskID: "fail-child-1"
                ),
                toolCallID: "call-abw-fail"
            )
            // Failure is still a completed coordinator child; the tool surfaces
            // an invalidCall, but counting must have removed.
            guard case .failure = result else {
                Issue.record("expected failure spawn, got \(result)")
                return
            }
            let events = await fixture.recorder.waitUntilCount(2)
            let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .subagent,
                id: "fail-child-1"
            ))
            let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .subagent,
                id: "fail-child-1"
            ))
            #expect(events == [upsert, remove])
        }
    }

    @Test("cancel while running emits exactly one remove")
    func cancelSequence() async throws {
        let gate = SampleGate()
        let fixture = try ActiveBackgroundHostFixture(sampler: .park(gate))
        await fixture.installSink()
        try await withAwaitedFixtureDispose(fixture, releaseGate: gate) {
            let result = await fixture.host.spawn(
                args: ActiveBackgroundHostFixture.spawnArgs(
                    background: true,
                    taskID: "cancel-child-1"
                ),
                toolCallID: "call-abw-cancel"
            )
            guard case .success = result else {
                Issue.record("background spawn failed: \(result)")
                return
            }
            let afterUpsert = await fixture.recorder.waitUntilCount(1)
            let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .subagent,
                id: "cancel-child-1"
            ))
            #expect(afterUpsert == [upsert])

            let outcome = await fixture.host.cancelSubagent(id: "cancel-child-1")
            #expect(outcome == .cancelled)
            gate.release()

            let events = await fixture.recorder.waitUntilCount(2)
            let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .subagent,
                id: "cancel-child-1"
            ))
            #expect(events == [upsert, remove])
        }
    }

    @Test("host shutdown removes still-counted children once")
    func shutdownSequence() async throws {
        let gate = SampleGate()
        let fixture = try ActiveBackgroundHostFixture(sampler: .park(gate))
        await fixture.installSink()
        try await withAwaitedFixtureDispose(fixture, releaseGate: gate) {
            let result = await fixture.host.spawn(
                args: ActiveBackgroundHostFixture.spawnArgs(
                    background: true,
                    taskID: "shutdown-child-1"
                ),
                toolCallID: "call-abw-shutdown"
            )
            guard case .success = result else {
                Issue.record("background spawn failed: \(result)")
                return
            }
            let afterUpsert = await fixture.recorder.waitUntilCount(1)
            let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .subagent,
                id: "shutdown-child-1"
            ))
            #expect(afterUpsert == [upsert])

            await fixture.host.shutdown()
            gate.release()

            let events = await fixture.recorder.waitUntilCount(2)
            let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .subagent,
                id: "shutdown-child-1"
            ))
            #expect(events == [upsert, remove])
            // Late child cleanup must not emit a second remove.
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(fixture.recorder.snapshot() == [upsert, remove])
        }
    }

    @Test("resume creates a new child id that counts while running")
    func resumeNewIDCounts() async throws {
        let fixture = try ActiveBackgroundHostFixture(sampler: .succeed)
        await fixture.installSink()
        try await withAwaitedFixtureDispose(fixture) {
            let first = await fixture.host.spawn(
                args: ActiveBackgroundHostFixture.spawnArgs(
                    background: false,
                    taskID: "resume-source-1"
                ),
                toolCallID: "call-abw-resume-1"
            )
            guard case .success = first else {
                Issue.record("source spawn failed: \(first)")
                return
            }
            _ = await fixture.recorder.waitUntilCount(2)

            let resumed = await fixture.host.spawn(
                args: ActiveBackgroundHostFixture.spawnArgs(
                    background: false,
                    taskID: "resume-child-2",
                    resumeFrom: "resume-source-1",
                    prompt: "continue"
                ),
                toolCallID: "call-abw-resume-2"
            )
            guard case .success = resumed else {
                Issue.record("resume spawn failed: \(resumed)")
                return
            }
            let events = await fixture.recorder.waitUntilCount(4)
            let sourceUpsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .subagent,
                id: "resume-source-1"
            ))
            let sourceRemove = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .subagent,
                id: "resume-source-1"
            ))
            let resumeUpsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .subagent,
                id: "resume-child-2"
            ))
            let resumeRemove = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .subagent,
                id: "resume-child-2"
            ))
            #expect(events == [sourceUpsert, sourceRemove, resumeUpsert, resumeRemove])
        }
    }

    @Test("failed coordinator registration emits no sink events")
    func failedRegistrationSilent() async throws {
        let fixture = try ActiveBackgroundHostFixture(sampler: .succeed)
        await fixture.installSink()
        await withAwaitedFixtureDispose(fixture) {
            // First registration claims the id.
            let first = await fixture.host.spawn(
                args: ActiveBackgroundHostFixture.spawnArgs(
                    background: false,
                    taskID: "dup-child-1"
                ),
                toolCallID: "call-abw-dup-1"
            )
            guard case .success = first else {
                Issue.record("first spawn failed: \(first)")
                return
            }
            _ = await fixture.recorder.waitUntilCount(2)

            // Duplicate id is refused by the coordinator before the operation
            // body (and therefore before upsert).
            let duplicate = await fixture.host.spawn(
                args: ActiveBackgroundHostFixture.spawnArgs(
                    background: true,
                    taskID: "dup-child-1"
                ),
                toolCallID: "call-abw-dup-2"
            )
            guard case .failure = duplicate else {
                Issue.record("expected duplicate registration failure, got \(duplicate)")
                return
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            #expect(fixture.recorder.snapshot().count == 2)
        }
    }
}
