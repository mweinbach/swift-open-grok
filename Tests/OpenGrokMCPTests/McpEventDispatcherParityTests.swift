import Foundation
import Testing
@testable import OpenGrokMCP

private struct DispatcherSnapshot: Sendable {
    var statuses: [McpServerStatusPayload]
    var removed: [String]
    var refreshedTools: [String]
    var refreshedResources: [String]
    var sleeps: [TimeInterval]
    var respawns: [String]
    var httpResets: [String]
    var unregistered: [String]
    var begins: [String]
    var ends: [String]
    var operations: [String]
}

private actor DispatcherRecorder: McpRestartActions {
    private var disabled: Set<String> = []
    private var stdioServers: Set<String> = []
    private var httpServers: Set<String> = []
    private var currentClients: [String: UInt64] = [:]
    private var shuttingDown: Set<String> = []
    private var inFlight: Set<String> = []
    private var outcomes: [Result<Void, McpRestartError>] = []
    private var snapshot = DispatcherSnapshot(
        statuses: [], removed: [], refreshedTools: [], refreshedResources: [],
        sleeps: [], respawns: [], httpResets: [], unregistered: [],
        begins: [], ends: [], operations: []
    )
    private var statusWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    nonisolated func callbacks() -> McpEventDispatcherCallbacks {
        McpEventDispatcherCallbacks(
            isConfiguredAndEnabled: { await self.isEnabled($0) },
            currentClientID: { await self.currentClient($0) },
            removeClient: { await self.remove($0) },
            refreshTools: { await self.refreshToolList($0) },
            refreshResources: { await self.refreshResourceList($0) },
            pushStatus: { await self.pushStatus(payload: $0) }
        )
    }

    func disable(_ server: String) { disabled.insert(server) }
    func configureStdio(_ server: String) { stdioServers.insert(server) }
    func configureHTTP(_ server: String) { httpServers.insert(server) }
    func setCurrentClient(_ server: String, id: UInt64) { currentClients[server] = id }
    func script(_ outcome: Result<Void, McpRestartError>) { outcomes.append(outcome) }
    func recordSleep(_ interval: TimeInterval) { snapshot.sleeps.append(interval) }
    func values() -> DispatcherSnapshot { snapshot }

    func waitForStatuses(_ minimum: Int) async {
        guard snapshot.statuses.count < minimum else { return }
        await withCheckedContinuation { continuation in
            statusWaiters.append((minimum, continuation))
        }
    }

    private func isEnabled(_ server: String) -> Bool {
        !disabled.contains(server)
    }

    private func currentClient(_ server: String) -> UInt64? {
        currentClients[server]
    }

    private func remove(_ server: String) {
        currentClients.removeValue(forKey: server)
        snapshot.removed.append(server)
        snapshot.operations.append("remove:\(server)")
    }

    private func refreshToolList(_ server: String) {
        snapshot.refreshedTools.append(server)
        snapshot.operations.append("tools:\(server)")
    }

    private func refreshResourceList(_ server: String) {
        snapshot.refreshedResources.append(server)
        snapshot.operations.append("resources:\(server)")
    }

    func isStdioServerConfigured(server: String) -> Bool {
        stdioServers.contains(server) && !disabled.contains(server)
    }

    func isInShuttingDown(server: String) -> Bool {
        shuttingDown.contains(server)
    }

    func respawnStdio(server: String) -> Result<Void, McpRestartError> {
        snapshot.respawns.append(server)
        if outcomes.isEmpty { return .success(()) }
        return outcomes.removeFirst()
    }

    func pushStatus(payload: McpServerStatusPayload) {
        snapshot.statuses.append(payload)
        snapshot.operations.append("status:\(payload.name):\(payload.reason.rawValue)")

        let ready = statusWaiters.filter { $0.0 <= snapshot.statuses.count }
        statusWaiters.removeAll { $0.0 <= snapshot.statuses.count }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    func beginRestart(server: String) -> Bool {
        guard inFlight.insert(server).inserted else { return false }
        snapshot.begins.append(server)
        return true
    }

    func endRestart(server: String) {
        inFlight.remove(server)
        snapshot.ends.append(server)
    }

    func isHttpServerConfigured(server: String) -> Bool {
        httpServers.contains(server) && !disabled.contains(server)
    }

    func resetHttpClient(server: String) -> Result<Void, McpRestartError> {
        snapshot.httpResets.append(server)
        return .success(())
    }

    func unregisterServerTools(server: String) {
        snapshot.unregistered.append(server)
    }

    func serverClientStateKind(server: String) -> ClientStateKind? {
        nil
    }
}

private actor DispatcherCloseRecordingTransport: MCPTransport {
    private var count = 0

    func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        nil
    }

    func close() async {
        count += 1
    }

    func closeCount() -> Int { count }
}

@Suite("MCP coalescing dispatcher Rust parity")
struct McpEventDispatcherParityTests {
    @Test("One hundred repeated notifications produce one refresh and one status")
    func repeatedNotificationsCoalesce() async {
        let recorder = DispatcherRecorder()
        let dispatcher = McpEventDispatcher(sessionID: "s", callbacks: recorder.callbacks())

        for _ in 0..<100 {
            let accepted = await dispatcher.submit(.toolsChanged(server: "github"))
            #expect(accepted)
        }
        await dispatcher.flush()

        let result = await recorder.values()
        #expect(result.refreshedTools == ["github"])
        #expect(result.statuses.count == 1)
        #expect(result.statuses.first?.reason == .configChanged)
        await dispatcher.close()
    }

    @Test("Coalescing keys preserve both server and event kind")
    func eventKeysPreserveServerAndKind() async {
        let recorder = DispatcherRecorder()
        let dispatcher = McpEventDispatcher(sessionID: "s", callbacks: recorder.callbacks())

        #expect(await dispatcher.submit(.toolsChanged(server: "github")))
        #expect(await dispatcher.submit(.toolsChanged(server: "linear")))
        #expect(await dispatcher.submit(.resourcesChanged(server: "github")))
        await dispatcher.flush()

        let result = await recorder.values()
        #expect(result.statuses.count == 3)
        #expect(result.refreshedTools == ["github", "linear"])
        #expect(result.refreshedResources == ["github"])
        await dispatcher.close()
    }

    @Test("The latest handshake failure wins without truncating its detail")
    func latestHandshakeFailureWins() async {
        let recorder = DispatcherRecorder()
        let dispatcher = McpEventDispatcher(sessionID: "s", callbacks: recorder.callbacks())

        #expect(await dispatcher.submit(.handshakeFailed(server: "github", reason: "first")))
        #expect(await dispatcher.submit(.handshakeFailed(server: "github", reason: "proxy: 502 Unauthorized")))
        await dispatcher.flush()

        let result = await recorder.values()
        #expect(result.statuses.count == 1)
        #expect(result.statuses.first?.detail == "proxy: 502 Unauthorized")
        #expect(result.statuses.first?.status == .unavailable)
        await dispatcher.close()
    }

    @Test("Config diffs fan out additions, removals and modified tool refreshes")
    func configDiffFansOut() async {
        let recorder = DispatcherRecorder()
        let dispatcher = McpEventDispatcher(sessionID: "s", callbacks: recorder.callbacks())

        #expect(await dispatcher.submit(.configDiff(
            added: ["new-a", "new-b"],
            removed: ["old"],
            modified: ["changed"]
        )))
        await dispatcher.flush()

        let result = await recorder.values()
        #expect(result.statuses.map(\.name) == ["new-a", "new-b", "old", "changed"])
        #expect(result.statuses.map(\.reason) == [
            .configAdded, .configAdded, .configRemoved, .configChanged
        ])
        #expect(result.refreshedTools == ["changed"])
        await dispatcher.close()
    }

    @Test("Every lifecycle payload matches upstream status, reason and managed origin")
    func lifecyclePayloadParity() {
        let cases: [(McpClientEvent, McpServerStatus, McpServerStatusReason)] = [
            (.transportClosed(server: "managed_gateway:linear", clientId: 7), .unavailable, .transportClosed),
            (.handshakeFailed(server: "local", reason: "failure"), .unavailable, .handshakeFailed),
            (.toolsChanged(server: "local"), .ready, .configChanged),
            (.resourcesChanged(server: "local"), .ready, .configChanged),
            (.ready(server: "local"), .ready, .initialized),
            (.configAdded(server: "local"), .initializing, .configAdded),
            (.configRemoved(server: "local"), .unavailable, .configRemoved)
        ]

        for (event, expectedStatus, expectedReason) in cases {
            let payload = McpEventDispatcher.statusPayload(sessionID: "session-42", event: event)
            #expect(payload?.sessionId == "session-42")
            #expect(payload?.status == expectedStatus)
            #expect(payload?.reason == expectedReason)
            #expect(payload?.source == (event.serverName?.hasPrefix("managed_gateway:") == true ? .managed : .local))
        }

        #expect(McpEventDispatcher.statusPayload(
            sessionID: "s", event: .configDiff(added: [], removed: [], modified: [])
        ) == nil)
    }

    @Test("Bounded coalescing retains the newest distinct keys")
    func bufferRemainsBounded() async {
        let recorder = DispatcherRecorder()
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), bufferLimit: 2
        )

        #expect(await dispatcher.submit(.ready(server: "oldest")))
        #expect(await dispatcher.submit(.ready(server: "middle")))
        #expect(await dispatcher.submit(.ready(server: "newest")))
        await dispatcher.flush()

        let result = await recorder.values()
        #expect(result.statuses.map(\.name) == ["middle", "newest"])
        await dispatcher.close()
    }

    @Test("A stale transport close cannot evict, notify or restart a replacement")
    func staleTransportCloseIsCompletelyInert() async {
        let recorder = DispatcherRecorder()
        await recorder.configureStdio("github")
        await recorder.setCurrentClient("github", id: 22)
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), restartActions: recorder,
            sleeper: { await recorder.recordSleep($0) }
        )

        #expect(await dispatcher.submit(.transportClosed(server: "github", clientId: 11)))
        await dispatcher.flush()
        await dispatcher.waitForPendingRestarts()

        let result = await recorder.values()
        #expect(result.statuses.isEmpty)
        #expect(result.removed.isEmpty)
        #expect(result.respawns.isEmpty)
        await dispatcher.close()
    }

    @Test("Every coalesced close identity remains eligible to evict the matching client")
    func everyCloseIdentityIsPreserved() async {
        let recorder = DispatcherRecorder()
        await recorder.setCurrentClient("github", id: 7)
        let dispatcher = McpEventDispatcher(sessionID: "s", callbacks: recorder.callbacks())

        #expect(await dispatcher.submit(.transportClosed(server: "github", clientId: 7)))
        #expect(await dispatcher.submit(.transportClosed(server: "github", clientId: 99)))
        await dispatcher.flush()

        let result = await recorder.values()
        #expect(result.removed == ["github"])
        #expect(result.statuses.count == 1)
        #expect(result.operations == [
            "remove:github", "status:github:transport_closed"
        ])
        await dispatcher.close()
    }

    @Test("Disabled servers never refresh their registry or schedule recovery")
    func disabledServerCannotRefreshOrRestart() async {
        let recorder = DispatcherRecorder()
        await recorder.configureStdio("github")
        await recorder.disable("github")
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), restartActions: recorder,
            sleeper: { await recorder.recordSleep($0) }
        )

        #expect(await dispatcher.submit(.toolsChanged(server: "github")))
        #expect(await dispatcher.submit(.resourcesChanged(server: "github")))
        #expect(await dispatcher.submit(.handshakeFailed(server: "github", reason: "closed")))
        await dispatcher.flush()

        let result = await recorder.values()
        #expect(result.refreshedTools.isEmpty)
        #expect(result.refreshedResources.isEmpty)
        #expect(result.respawns.isEmpty)
        #expect(result.sleeps.isEmpty)
        #expect(result.statuses.last?.reason == .handshakeFailed)
        await dispatcher.close()
    }

    @Test("A removed configuration suppresses restart without labeling crashes as teardown")
    func configurationRemovalSuppressesRestart() async {
        let recorder = DispatcherRecorder()
        await recorder.configureStdio("github")
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), restartActions: recorder,
            sleeper: { await recorder.recordSleep($0) }
        )

        #expect(await dispatcher.submit(.transportClosed(server: "github", clientId: 3)))
        #expect(await dispatcher.submit(.configRemoved(server: "github")))
        await dispatcher.flush()

        let result = await recorder.values()
        #expect(result.statuses.map(\.reason) == [.transportClosed, .configRemoved])
        #expect(result.respawns.isEmpty)
        await dispatcher.close()
    }

    @Test("A stdio crash restarts once and emits the successful lifecycle")
    func stdioCrashRestartsSuccessfully() async {
        let recorder = DispatcherRecorder()
        await recorder.configureStdio("github")
        await recorder.setCurrentClient("github", id: 1)
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), restartActions: recorder,
            sleeper: { await recorder.recordSleep($0) }
        )

        #expect(await dispatcher.submit(.transportClosed(server: "github", clientId: 1)))
        await dispatcher.flush()
        await dispatcher.waitForPendingRestarts()

        let result = await recorder.values()
        #expect(result.removed == ["github"])
        #expect(result.sleeps == [1.0])
        #expect(result.respawns == ["github"])
        #expect(result.statuses.map(\.reason) == [.transportClosed, .restartSucceeded])
        #expect(result.begins == ["github"])
        #expect(result.ends == ["github"])
        await dispatcher.close()
    }

    @Test("Exhausted stdio restart preserves Rust's 1, 4, 16 backoff without sleeping")
    func exhaustedRestartUsesExactInjectedBackoff() async {
        let recorder = DispatcherRecorder()
        await recorder.configureStdio("github")
        await recorder.script(.failure("one"))
        await recorder.script(.failure("two"))
        await recorder.script(.failure("three"))
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), restartActions: recorder,
            sleeper: { await recorder.recordSleep($0) }
        )

        #expect(await dispatcher.submit(.handshakeFailed(server: "github", reason: "initial")))
        await dispatcher.flush()
        await dispatcher.waitForPendingRestarts()

        let result = await recorder.values()
        #expect(result.sleeps == [1.0, 4.0, 16.0])
        #expect(result.respawns == ["github", "github", "github"])
        #expect(result.unregistered == ["github"])
        #expect(result.statuses.filter { $0.reason == .restartFailed }.count == 4)
        #expect(result.ends == ["github"])
        await dispatcher.close()
    }

    @Test("HTTP transport death recovers in place without evicting its live client")
    func httpTransportRecoversInPlace() async {
        let recorder = DispatcherRecorder()
        await recorder.configureHTTP("remote")
        await recorder.setCurrentClient("remote", id: 5)
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), restartActions: recorder,
            sleeper: { await recorder.recordSleep($0) }
        )

        #expect(await dispatcher.submit(.transportClosed(server: "remote", clientId: 5)))
        await dispatcher.flush()
        await dispatcher.waitForPendingRestarts()

        let result = await recorder.values()
        #expect(result.removed.isEmpty)
        #expect(result.httpResets == ["remote"])
        #expect(result.respawns.isEmpty)
        #expect(result.statuses.first?.reason == .transportClosed)
        #expect(result.ends == ["remote"])
        await dispatcher.close()
    }

    @Test("Concurrent failure kinds share one supervised restart")
    func concurrentFailureKindsDeduplicateRestart() async {
        let recorder = DispatcherRecorder()
        await recorder.configureStdio("github")
        let suspendedSleep = McpRestartCancellationToken()
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), restartActions: recorder,
            sleeper: { interval in
                await recorder.recordSleep(interval)
                await suspendedSleep.cancelled()
            }
        )

        #expect(await dispatcher.submit(.transportClosed(server: "github", clientId: 1)))
        #expect(await dispatcher.submit(.handshakeFailed(server: "github", reason: "closed")))
        await dispatcher.flush()

        let duringRestart = await recorder.values()
        #expect(duringRestart.begins == ["github"])
        await dispatcher.close()

        let afterClose = await recorder.values()
        #expect(afterClose.ends == ["github"])
        #expect(afterClose.respawns.isEmpty)
    }

    @Test("Closing twice deterministically cancels and joins the only restart")
    func closeIsOnceOnlyAndReleasesRestartClaim() async {
        let recorder = DispatcherRecorder()
        await recorder.configureStdio("github")
        let suspendedSleep = McpRestartCancellationToken()
        let dispatcher = McpEventDispatcher(
            sessionID: "s", callbacks: recorder.callbacks(), restartActions: recorder,
            sleeper: { _ in await suspendedSleep.cancelled() }
        )

        #expect(await dispatcher.submit(.handshakeFailed(server: "github", reason: "closed")))
        await dispatcher.flush()
        await dispatcher.close()
        await dispatcher.close()

        let result = await recorder.values()
        #expect(result.begins == ["github"])
        #expect(result.ends == ["github"])
        #expect(result.respawns.isEmpty)
        #expect(await dispatcher.isClosed)
        #expect(!(await dispatcher.submit(.ready(server: "github"))))
    }

    @Test("The bounded transport broadcaster reaches and drains the dispatcher")
    func producerStreamReachesDispatcher() async {
        let recorder = DispatcherRecorder()
        let dispatcher = McpEventDispatcher(sessionID: "s", callbacks: recorder.callbacks())
        let broadcaster = MCPEventStream(bufferLimit: 8)

        await dispatcher.start(events: broadcaster.subscribe())
        broadcaster.publish(.toolsChanged(server: "github"))
        broadcaster.publish(.toolsChanged(server: "github"))
        broadcaster.finish()

        await recorder.waitForStatuses(1)
        await dispatcher.close()

        let result = await recorder.values()
        #expect(result.statuses.count == 1)
        #expect(result.refreshedTools == ["github"])
    }

    @Test("MCPClient closes its underlying transport exactly once")
    func clientTransportCloseIsOnceOnly() async {
        let transport = DispatcherCloseRecordingTransport()
        let client = MCPClient(transport: transport)

        async let firstClose: Void = client.close()
        async let secondClose: Void = client.close()
        await firstClose
        await secondClose
        await client.close()

        #expect(await transport.closeCount() == 1)
    }
}
