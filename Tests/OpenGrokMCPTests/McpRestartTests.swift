// McpRestartTests.swift
//
// Unit tests for Bounded Stdio MCP Auto-Restart, Exponential Backoff, Guard Rails,
// and Status Update Notifications.

import Foundation
import OpenGrokShared
import OpenGrokToolTypes
import Testing
@testable import OpenGrokMCP

private actor MockRestartActions: McpRestartActions {
    private var configuredServers: Set<String> = []
    private var httpConfiguredServers: Set<String> = []
    private var shuttingDownServers: Set<String> = []
    private var clientStates: [String: ClientStateKind] = [:]
    private var inFlightServers: Set<String> = []
    private var respawnOutcomes: [Result<Void, McpRestartError>] = []
    private var respawnCalls: [String] = []
    private var pushes: [McpServerStatusPayload] = []
    private var unregisterCalls: [String] = []
    private var resetCalls: [String] = []
    private var resetOutcomes: [Result<Void, McpRestartError>] = []

    func configureStdio(_ server: String) {
        configuredServers.insert(server)
    }

    func unconfigureStdio(_ server: String) {
        configuredServers.remove(server)
    }

    func configureHttp(_ server: String) {
        httpConfiguredServers.insert(server)
    }

    func markShuttingDown(_ server: String) {
        shuttingDownServers.insert(server)
    }

    func setClientStateKind(_ server: String, _ kind: ClientStateKind) {
        clientStates[server] = kind
    }

    func scriptRespawnOutcome(_ outcome: Result<Void, McpRestartError>) {
        respawnOutcomes.append(outcome)
    }

    func scriptResetOutcome(_ outcome: Result<Void, McpRestartError>) {
        resetOutcomes.append(outcome)
    }

    // MARK: - McpRestartActions

    func isStdioServerConfigured(server: String) async -> Bool {
        configuredServers.contains(server)
    }

    func isInShuttingDown(server: String) async -> Bool {
        shuttingDownServers.contains(server)
    }

    func respawnStdio(server: String) async -> Result<Void, McpRestartError> {
        respawnCalls.append(server)
        if !respawnOutcomes.isEmpty {
            return respawnOutcomes.removeFirst()
        }
        return .failure("not scripted")
    }

    func pushStatus(payload: McpServerStatusPayload) async {
        pushes.append(payload)
    }

    func beginRestart(server: String) async -> Bool {
        if inFlightServers.contains(server) {
            return false
        }
        inFlightServers.insert(server)
        return true
    }

    func endRestart(server: String) async {
        inFlightServers.remove(server)
    }

    func isHttpServerConfigured(server: String) async -> Bool {
        httpConfiguredServers.contains(server)
    }

    func resetHttpClient(server: String) async -> Result<Void, McpRestartError> {
        resetCalls.append(server)
        if !resetOutcomes.isEmpty {
            return resetOutcomes.removeFirst()
        }
        return .failure("not scripted")
    }

    func unregisterServerTools(server: String) async {
        unregisterCalls.append(server)
    }

    func serverClientStateKind(server: String) async -> ClientStateKind? {
        clientStates[server]
    }

    // MARK: - Test Observers

    var respawnCallCount: Int {
        respawnCalls.count
    }

    var recordedPushes: [McpServerStatusPayload] {
        pushes
    }

    var recordedUnregisterCalls: [String] {
        unregisterCalls
    }
}

private actor TestRecorder {
    var recordedSleeps: [TimeInterval] = []
    var stateTransitions: [McpRestartState] = []
    var iteration: Int = 0

    func recordSleep(_ wait: TimeInterval) {
        recordedSleeps.append(wait)
    }

    func recordState(_ state: McpRestartState) {
        stateTransitions.append(state)
    }

    func nextIteration() -> Int {
        iteration += 1
        return iteration
    }

    var allSleeps: [TimeInterval] { recordedSleeps }
    var allStates: [McpRestartState] { stateTransitions }
}

@Suite("MCP Auto-Restart & Backoff Tests")
struct McpRestartTests {
    @Test("Backoff constants and timing schedule invariants")
    func backoffConstantsAndTimingSchedule() {
        #expect(McpRestartState.BACKOFF == [1.0, 4.0, 16.0])
        #expect(McpRestartState.maxAttempts == 3)
        #expect(McpRestartState.totalExhaustionWindow == 21.0)

        #expect(McpRestartState.delay(forAttempt: 1) == 1.0)
        #expect(McpRestartState.delay(forAttempt: 2) == 4.0)
        #expect(McpRestartState.delay(forAttempt: 3) == 16.0)
        #expect(McpRestartState.delay(forAttempt: 0) == nil)
        #expect(McpRestartState.delay(forAttempt: 4) == nil)

        #expect(McpRestartState.cumulativeDelay(forAttempt: 1) == 1.0)
        #expect(McpRestartState.cumulativeDelay(forAttempt: 2) == 5.0)
        #expect(McpRestartState.cumulativeDelay(forAttempt: 3) == 21.0)
    }

    @Test("Full 3-attempt backoff timing schedule execution and recordings")
    func fullThreeAttemptBackoffSchedule() async {
        let mock = MockRestartActions()
        await mock.configureStdio("test-server")
        await mock.scriptRespawnOutcome(.failure("err1"))
        await mock.scriptRespawnOutcome(.failure("err2"))
        await mock.scriptRespawnOutcome(.failure("err3"))

        let recorder = TestRecorder()

        let finalState = await McpRestart.autoRestartStdio(
            actions: mock,
            sessionId: "sess-1",
            server: "test-server",
            sleeper: { wait in
                await recorder.recordSleep(wait)
            },
            onStateChange: { state in
                await recorder.recordState(state)
            }
        )

        let sleeps = await recorder.allSleeps
        let callCount = await mock.respawnCallCount
        let unregisterCalls = await mock.recordedUnregisterCalls
        let pushes = await mock.recordedPushes

        // 3 sleeps at 1.0, 4.0, 16.0
        #expect(sleeps == [1.0, 4.0, 16.0])
        #expect(callCount == 3)
        #expect(finalState.isExhausted == true)
        #expect(finalState.attempt == 3)
        #expect(finalState.statusReason == .unavailable)

        // Status update pushes: 3 intermediate RestartFailed + 1 final exhausted RestartFailed
        #expect(pushes.count == 4)
        #expect(pushes[0].reason == .restartFailed)
        #expect(pushes[0].status == .unavailable)
        #expect(pushes[0].detail?.contains("attempt 1 of 3") == true)

        #expect(pushes[1].reason == .restartFailed)
        #expect(pushes[1].status == .unavailable)
        #expect(pushes[1].detail?.contains("attempt 2 of 3") == true)

        #expect(pushes[2].reason == .restartFailed)
        #expect(pushes[2].status == .unavailable)
        #expect(pushes[2].detail?.contains("attempt 3 of 3") == true)

        #expect(pushes[3].reason == .restartFailed)
        #expect(pushes[3].status == .unavailable)
        #expect(pushes[3].detail == "exhausted after 3 attempts")

        // Unregister server tools was called
        #expect(unregisterCalls == ["test-server"])
    }

    @Test("HTTP/OAuth transport skip: non-stdio does not trigger auto-restart")
    func httpTransportSkip() async {
        let mock = MockRestartActions()
        // Configured as HTTP, but NOT stdio
        await mock.configureHttp("http-server")

        let scheduled = await McpRestart.maybeScheduleRestart(
            actions: mock,
            sessionId: "sess-1",
            server: "http-server",
            kind: .transportClosed
        )

        let callCount = await mock.respawnCallCount
        let pushes = await mock.recordedPushes

        #expect(scheduled == false)
        #expect(callCount == 0)
        #expect(pushes.isEmpty)
    }

    @Test("Intentional shutdown skip: killOnDrop / shutting_down does not restart")
    func intentionalShutdownSkip() async {
        let mock = MockRestartActions()
        await mock.configureStdio("stopping-server")
        await mock.markShuttingDown("stopping-server")

        let scheduled = await McpRestart.maybeScheduleRestart(
            actions: mock,
            sessionId: "sess-1",
            server: "stopping-server",
            kind: .transportClosed
        )

        let callCount = await mock.respawnCallCount
        let pushes = await mock.recordedPushes

        #expect(scheduled == false)
        #expect(callCount == 0)
        #expect(pushes.isEmpty)
    }

    @Test("Disabled config mid-loop exit emits disabled status and stops")
    func disabledConfigMidLoopExit() async {
        let mock = MockRestartActions()
        await mock.configureStdio("dynamic-server")
        let recorder = TestRecorder()

        let finalState = await McpRestart.autoRestartStdio(
            actions: mock,
            sessionId: "sess-1",
            server: "dynamic-server",
            sleeper: { _ in
                let iter = await recorder.nextIteration()
                if iter == 1 {
                    // Disable / unconfigure the server during the first sleep
                    await mock.unconfigureStdio("dynamic-server")
                }
            }
        )

        let callCount = await mock.respawnCallCount
        let pushes = await mock.recordedPushes

        #expect(finalState.statusReason == .disabled)
        #expect(finalState.isExhausted == false)
        #expect(callCount == 0)

        #expect(pushes.count == 1)
        #expect(pushes[0].reason == .disabled)
        #expect(pushes[0].status == .unavailable)
    }

    @Test("Exhaustion transition to unavailable and tool unregistration")
    func exhaustionTransitionToUnavailable() async {
        let mock = MockRestartActions()
        await mock.configureStdio("failing-svr")
        await mock.scriptRespawnOutcome(.failure("crash1"))
        await mock.scriptRespawnOutcome(.failure("crash2"))
        await mock.scriptRespawnOutcome(.failure("crash3"))

        let finalState = await McpRestart.autoRestartStdio(
            actions: mock,
            sessionId: "sess-1",
            server: "failing-svr",
            sleeper: { _ in }
        )

        let callCount = await mock.respawnCallCount
        let unregisterCalls = await mock.recordedUnregisterCalls
        let pushes = await mock.recordedPushes

        #expect(finalState.isExhausted == true)
        #expect(finalState.statusReason == .unavailable)
        #expect(callCount == 3)
        #expect(unregisterCalls == ["failing-svr"])

        #expect(pushes.count == 4)
        #expect(pushes.last?.reason == .restartFailed)
        #expect(pushes.last?.status == .unavailable)
        #expect(pushes.last?.detail == "exhausted after 3 attempts")
    }

    @Test("Successful restart on second attempt emits restartSucceeded")
    func successfulRestartSecondAttempt() async {
        let mock = MockRestartActions()
        await mock.configureStdio("recovering-svr")
        await mock.scriptRespawnOutcome(.failure("transient disconnect"))
        await mock.scriptRespawnOutcome(.success(()))

        let finalState = await McpRestart.autoRestartStdio(
            actions: mock,
            sessionId: "sess-1",
            server: "recovering-svr",
            sleeper: { _ in }
        )

        let callCount = await mock.respawnCallCount
        let unregisterCalls = await mock.recordedUnregisterCalls
        let pushes = await mock.recordedPushes

        #expect(finalState.statusReason == .restartSucceeded)
        #expect(finalState.isExhausted == false)
        #expect(finalState.attempt == 2)
        #expect(callCount == 2)
        #expect(unregisterCalls.isEmpty)

        #expect(pushes.count == 2)
        #expect(pushes[0].reason == .restartFailed)
        #expect(pushes[0].status == .unavailable)
        #expect(pushes[1].reason == .restartSucceeded)
        #expect(pushes[1].status == .ready)
    }

    @Test("Non-restart event kinds do not schedule restarts")
    func nonRestartEventKinds() async {
        let mock = MockRestartActions()
        await mock.configureStdio("idle-svr")

        let nonRestartEvents: [McpClientEventKind] = [
            .ready,
            .toolsChanged,
            .resourcesChanged,
            .configAdded,
            .configRemoved,
            .configDiff
        ]

        for kind in nonRestartEvents {
            let scheduled = await McpRestart.maybeScheduleRestart(
                actions: mock,
                sessionId: "sess-1",
                server: "idle-svr",
                kind: kind
            )
            #expect(scheduled == false)
        }

        let callCount = await mock.respawnCallCount
        #expect(callCount == 0)
    }

    @Test("Already empty client state skips restart")
    func alreadyEmptyClientStateSkip() async {
        let mock = MockRestartActions()
        await mock.configureStdio("empty-svr")
        await mock.setClientStateKind("empty-svr", .empty)

        let scheduled = await McpRestart.maybeScheduleRestart(
            actions: mock,
            sessionId: "sess-1",
            server: "empty-svr",
            kind: .transportClosed
        )

        let callCount = await mock.respawnCallCount
        #expect(scheduled == false)
        #expect(callCount == 0)
    }

    @Test("Dedup in-flight restart tasks")
    func dedupInFlightRestartTasks() async {
        let mock = MockRestartActions()
        await mock.configureStdio("busy-svr")
        _ = await mock.beginRestart(server: "busy-svr")

        let scheduled = await McpRestart.maybeScheduleRestart(
            actions: mock,
            sessionId: "sess-1",
            server: "busy-svr",
            kind: .transportClosed
        )

        let callCount = await mock.respawnCallCount
        #expect(scheduled == false)
        #expect(callCount == 0)
    }

    @Test("Cancellation aborts before respawn")
    func cancellationAbortsBeforeRespawn() async {
        let mock = MockRestartActions()
        await mock.configureStdio("cancel-svr")
        await mock.scriptRespawnOutcome(.success(()))

        let cancelToken = McpRestartCancellationToken()
        cancelToken.cancel()

        let finalState = await McpRestart.autoRestartStdio(
            actions: mock,
            sessionId: "sess-1",
            server: "cancel-svr",
            cancellationToken: cancelToken,
            sleeper: { _ in }
        )

        let callCount = await mock.respawnCallCount
        let pushes = await mock.recordedPushes

        #expect(callCount == 0)
        #expect(pushes.isEmpty)
        #expect(finalState.statusReason == .restarting)
    }

    @Test("McpRestartState and McpServerStatusPayload Codable round-trips")
    func codableRoundTrips() throws {
        let state = McpRestartState(
            attempt: 2,
            nextBackoffDelay: 4.0,
            statusReason: .restarting,
            isExhausted: false,
            lastError: "timeout"
        )
        let encodedState = try JSONEncoder().encode(state)
        let decodedState = try JSONDecoder().decode(McpRestartState.self, from: encodedState)
        #expect(decodedState == state)

        let payload = McpServerStatusPayload(
            sessionId: "s123",
            name: "test-server",
            source: .local,
            status: .unavailable,
            reason: .restartFailed,
            detail: "attempt 1 of 3: error",
            tools: nil
        )
        let encodedPayload = try JSONEncoder().encode(payload)
        let decodedPayload = try JSONDecoder().decode(McpServerStatusPayload.self, from: encodedPayload)
        #expect(decodedPayload == payload)
    }
}
