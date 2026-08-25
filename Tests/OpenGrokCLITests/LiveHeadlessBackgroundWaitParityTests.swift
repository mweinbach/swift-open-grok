import Foundation
import OpenGrokAgentCoordinator
import OpenGrokShell
import OpenGrokShellBase
import Testing

@testable import OpenGrokCLI

private struct HeadlessBackgroundWaitFixture {
    let root: URL
    let workspace: URL
    let home: URL
    let backend: LocalShellProcessBackend
    let execution: OpenGrokShellOwnedProcessExecution
    let sessionID: String
    let environment: [String: String]

    init(sessionID: String = "headless-owner") throws {
        self.sessionID = sessionID
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-headless-wait-\(UUID().uuidString)",
            isDirectory: true
        )
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        backend = LocalShellProcessBackend(inheritedEnvironment: environment)
        execution = try OpenGrokShellOwnedProcessExecution(
            sessionID: sessionID,
            workingDirectory: workspace,
            backend: backend
        )
    }

    func startShellTask(
        command: String,
        id: String,
        execution override: OpenGrokShellOwnedProcessExecution? = nil
    ) async throws -> ShellBackgroundHandle {
        let owned = override ?? execution
        return try await owned.runBackground(ShellCommandRequest(
            command: command,
            workingDirectory: workspace,
            timeout: .seconds(5),
            toolCallID: id
        ))
    }

    func waiter(
        policy: LiveHeadlessBackgroundWait.Policy,
        coordinator: OpenGrokAgentCoordinator? = nil
    ) throws -> LiveHeadlessBackgroundWait {
        try LiveHeadlessBackgroundWait(
            sessionID: sessionID,
            workingDirectory: workspace,
            execution: execution,
            coordinator: coordinator,
            policy: policy
        )
    }

    func dispose() async {
        await execution.cancelAll()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Headless background wait parity", .serialized)
struct LiveHeadlessBackgroundWaitParityTests {
    @Test("launch defaults match Rust's 600-second wait and 750-millisecond no-wait grace")
    func launchPolicyDefaultsAndOverrides() {
        let defaults = LiveHeadlessBackgroundWait.Policy(options: CLIAdvancedOptions())
        #expect(defaults.waitForBackground)
        #expect(defaults.timeoutMilliseconds == 600_000)
        #expect(defaults.noWaitGraceMilliseconds == 750)

        let custom = LiveHeadlessBackgroundWait.Policy(options: CLIAdvancedOptions(
            backgroundWaitTimeoutSeconds: 37
        ))
        #expect(custom.waitForBackground)
        #expect(custom.timeoutMilliseconds == 37_000)

        let noWait = LiveHeadlessBackgroundWait.Policy(options: CLIAdvancedOptions(
            noWaitForBackground: true,
            backgroundWaitTimeoutSeconds: 37
        ))
        #expect(!noWait.waitForBackground)
        #expect(noWait.effectiveBudgetMilliseconds == 750)

        let hostile = LiveHeadlessBackgroundWait.Policy(options: CLIAdvancedOptions(
            backgroundWaitTimeoutSeconds: UInt64.max
        ))
        #expect(hostile.timeoutMilliseconds == 86_400_000)
    }

    @Test("an idle authenticated session exits without sleeping for its full timeout")
    func idleSessionReturnsImmediately() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let waiter = try fixture.waiter(policy: .init(
            waitForBackground: true,
            timeoutMilliseconds: 5_000
        ))

        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .completed)
        #expect(result.pending.isEmpty)
        #expect(result.elapsedMilliseconds < 200)
    }

    @Test("a genuinely running owned shell process finishes before headless teardown")
    func waitsForRealBackgroundProcess() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let process = try await fixture.startShellTask(
            command: "sleep 0.15",
            id: "real-owned-shell"
        )
        let waiter = try fixture.waiter(policy: .init(
            waitForBackground: true,
            timeoutMilliseconds: 2_000,
            pollIntervalMilliseconds: 10
        ))

        let initial = await waiter.pendingWork()
        #expect(initial.shellTaskIDs == [process.taskID])
        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .completed)
        #expect(result.pending.isEmpty)
        #expect(result.elapsedMilliseconds >= 60)
        let terminal = await fixture.execution.taskSnapshot(process.taskID)
        #expect(terminal?.completed == true)
        #expect(terminal?.explicitlyKilled == false)
    }

    @Test("the configured deadline returns owned work without killing it")
    func deadlineDoesNotKillRunningProcess() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let process = try await fixture.startShellTask(
            command: "sleep 2",
            id: "timeout-owned-shell"
        )
        let waiter = try fixture.waiter(policy: .init(
            waitForBackground: true,
            timeoutMilliseconds: 70,
            pollIntervalMilliseconds: 10
        ))

        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .timedOut)
        #expect(result.pending.shellTaskIDs == [process.taskID])
        #expect(result.elapsedMilliseconds >= 50)
        #expect(result.elapsedMilliseconds < 500)
        let stillRunning = await fixture.execution.taskSnapshot(process.taskID)
        #expect(stillRunning?.completed == false)
        #expect(stillRunning?.explicitlyKilled == false)
    }

    @Test("no-wait still observes its bounded lifecycle-drain grace window")
    func noWaitHonorsGraceWithoutWaitingForLongProcess() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let process = try await fixture.startShellTask(
            command: "sleep 2",
            id: "grace-owned-shell"
        )
        let waiter = try fixture.waiter(policy: .init(
            waitForBackground: false,
            timeoutMilliseconds: 60_000,
            noWaitGraceMilliseconds: 80,
            pollIntervalMilliseconds: 10
        ))

        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .graceExpired)
        #expect(result.pending.shellTaskIDs == [process.taskID])
        #expect(result.elapsedMilliseconds >= 60)
        #expect(result.elapsedMilliseconds < 500)
        #expect(await fixture.execution.taskSnapshot(process.taskID)?.completed == false)
    }

    @Test("short-lived process completions remain visible throughout no-wait grace")
    func noWaitGraceDrainsFastCompletion() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let process = try await fixture.startShellTask(
            command: "sleep 0.04",
            id: "fast-grace-shell"
        )
        let waiter = try fixture.waiter(policy: .init(
            waitForBackground: false,
            timeoutMilliseconds: 60_000,
            noWaitGraceMilliseconds: 100,
            pollIntervalMilliseconds: 10
        ))

        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .graceExpired)
        #expect(result.pending.isEmpty)
        #expect(result.elapsedMilliseconds >= 80)
        #expect(await fixture.execution.taskSnapshot(process.taskID)?.completed == true)
    }

    @Test("a genuine coordinator-owned background subagent is allowed to complete")
    func waitsForOwnedBackgroundSubagent() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(
            id: "owned-background-child",
            parentSessionID: fixture.sessionID,
            owner: .task,
            runInBackground: true
        )
        let registered = try await coordinator.spawn(request) {
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                return OpenGrokChildResult(id: request.id, success: true, output: "child finished")
            } catch {
                return OpenGrokChildResult(id: request.id, success: false, cancelled: true)
            }
        }
        #expect(registered == request.id)
        let waiter = try fixture.waiter(
            policy: .init(
                waitForBackground: true,
                timeoutMilliseconds: 2_000,
                pollIntervalMilliseconds: 10
            ),
            coordinator: coordinator
        )

        #expect(await waiter.pendingWork().subagentIDs == [request.id])
        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .completed)
        #expect(result.pending.subagentIDs.isEmpty)
        #expect(result.elapsedMilliseconds >= 60)
        let completed = await coordinator.listCompleted()
        #expect(completed.contains { $0.request.id == request.id && $0.result?.success == true })
    }

    @Test("a subagent left at the deadline remains live until its real owner reaps it")
    func subagentDeadlineDoesNotCancelChild() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(
            id: "still-running-child",
            parentSessionID: fixture.sessionID,
            owner: .task,
            runInBackground: true
        )
        let registered = try await coordinator.spawn(request) {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return OpenGrokChildResult(id: request.id, success: true)
            } catch {
                return OpenGrokChildResult(id: request.id, success: false, cancelled: true)
            }
        }
        #expect(registered == request.id)
        let waiter = try fixture.waiter(
            policy: .init(
                waitForBackground: true,
                timeoutMilliseconds: 60,
                pollIntervalMilliseconds: 10
            ),
            coordinator: coordinator
        )

        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .timedOut)
        #expect(result.pending.subagentIDs == [request.id])
        #expect(await coordinator.listActive(parentSessionID: fixture.sessionID).count == 1)
        #expect(await coordinator.cancel(.childID(request.id)) == 1)
    }

    @Test("one exit gate waits for both owned shell work and owned child sessions")
    func waitsForMixedBackgroundWork() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let process = try await fixture.startShellTask(
            command: "sleep 0.08",
            id: "mixed-owned-shell"
        )
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(
            id: "mixed-owned-child",
            parentSessionID: fixture.sessionID,
            owner: .swarm
        )
        let registered = try await coordinator.spawn(request) {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                return OpenGrokChildResult(id: request.id, success: true)
            } catch {
                return OpenGrokChildResult(id: request.id, success: false, cancelled: true)
            }
        }
        #expect(registered == request.id)
        let waiter = try fixture.waiter(
            policy: .init(
                waitForBackground: true,
                timeoutMilliseconds: 2_000,
                pollIntervalMilliseconds: 10
            ),
            coordinator: coordinator
        )

        let initial = await waiter.pendingWork()
        #expect(initial.shellTaskIDs == [process.taskID])
        #expect(initial.subagentIDs == [request.id])
        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .completed)
        #expect(result.pending.isEmpty)
        #expect(result.elapsedMilliseconds >= 90)
    }

    @Test("shared process backends never expose or reap another root session")
    func excludesOtherSessionProcessesAndChildren() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let foreignExecution = try OpenGrokShellOwnedProcessExecution(
            sessionID: "different-root",
            workingDirectory: fixture.workspace,
            backend: fixture.backend
        )
        defer { Task { await foreignExecution.cancelAll() } }
        let foreign = try await fixture.startShellTask(
            command: "sleep 2",
            id: "foreign-owned-shell",
            execution: foreignExecution
        )
        let coordinator = OpenGrokAgentCoordinator()
        let foreignChild = OpenGrokChildRequest(
            id: "foreign-owned-child",
            parentSessionID: "different-root",
            owner: .task,
            runInBackground: true
        )
        let registered = try await coordinator.spawn(foreignChild) {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return OpenGrokChildResult(id: foreignChild.id, success: true)
            } catch {
                return OpenGrokChildResult(id: foreignChild.id, success: false, cancelled: true)
            }
        }
        #expect(registered == foreignChild.id)
        let waiter = try fixture.waiter(
            policy: .init(waitForBackground: true, timeoutMilliseconds: 1_000),
            coordinator: coordinator
        )

        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .completed)
        #expect(result.pending.isEmpty)
        #expect(result.elapsedMilliseconds < 200)
        #expect(await foreignExecution.taskSnapshot(foreign.taskID)?.completed == false)
        #expect(await coordinator.listActive(parentSessionID: "different-root").count == 1)
        #expect(await coordinator.cancel(.childID(foreignChild.id)) == 1)
    }

    @Test("mismatched process ownership and workspace identity fail closed")
    func rejectsMismatchedOwnerAndWorkspace() throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        #expect(throws: LiveHeadlessBackgroundWait.OwnershipError.sessionMismatch) {
            try LiveHeadlessBackgroundWait(
                sessionID: "different-root",
                workingDirectory: fixture.workspace,
                execution: fixture.execution,
                policy: .init(waitForBackground: true, timeoutMilliseconds: 1_000)
            )
        }
        #expect(throws: LiveHeadlessBackgroundWait.OwnershipError.workingDirectoryMismatch) {
            try LiveHeadlessBackgroundWait(
                sessionID: fixture.sessionID,
                workingDirectory: fixture.root,
                execution: fixture.execution,
                policy: .init(waitForBackground: true, timeoutMilliseconds: 1_000)
            )
        }
    }

    @Test("cancelling the waiter returns promptly without killing another owned task")
    func cancellationPreservesOwnedProcess() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let process = try await fixture.startShellTask(
            command: "sleep 2",
            id: "cancelled-wait-shell"
        )
        let waiter = try fixture.waiter(policy: .init(
            waitForBackground: true,
            timeoutMilliseconds: 5_000,
            pollIntervalMilliseconds: 20
        ))

        let waiting = Task { try await waiter.awaitBackgroundWork() }
        try await Task.sleep(nanoseconds: 40_000_000)
        waiting.cancel()
        do {
            let result = try await waiting.value
            Issue.record("cancelled wait unexpectedly completed: \(result)")
        } catch is CancellationError {
        } catch {
            Issue.record("cancelled wait produced the wrong error: \(error)")
        }
        let survivor = await fixture.execution.taskSnapshot(process.taskID)
        #expect(survivor?.completed == false)
        #expect(survivor?.explicitlyKilled == false)
    }

    @Test("the production executor initializer authenticates and observes its actual process table")
    func productionExecutorSeamWaitsForRealProcess() async throws {
        let fixture = try HeadlessBackgroundWaitFixture()
        defer { Task { await fixture.dispose() } }
        let executor = try await LiveToolExecutor(
            processBackend: fixture.backend,
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: fixture.environment
        )
        defer { Task { await executor.shutdown() } }
        let owned = try #require(await executor.processExecution(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace
        ))
        let background = try await owned.runBackground(ShellCommandRequest(
            command: "sleep 0.10",
            workingDirectory: fixture.workspace,
            timeout: .seconds(5),
            toolCallID: "production-owned-shell"
        ))

        let waiter = try await LiveHeadlessBackgroundWait(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workspace,
            executor: executor,
            subagents: nil,
            options: CLIAdvancedOptions(backgroundWaitTimeoutSeconds: 2)
        )
        let initial = await waiter.pendingWork()
        #expect(initial.shellTaskIDs == [background.taskID])
        let result = try await waiter.awaitBackgroundWork()
        #expect(result.reason == .completed)
        #expect(result.pending.isEmpty)
    }
}
