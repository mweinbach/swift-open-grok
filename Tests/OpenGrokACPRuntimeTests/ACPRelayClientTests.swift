// ACPRelayClientTests.swift
//
// The leader's outbound half, end to end: a stand-in relay listening on an
// ephemeral loopback port, and a real `ACPRelayClient` dialling it.
//
// The stand-in relay is a bare `WebSocketServer` driven by hand rather than an
// `ACPServeHost`, because the relay is the *driver* in this topology: it sends
// `initialize` and `session/prompt`, and the leader's runtime answers. Two
// runtimes facing each other would leave nobody driving.

import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

// MARK: - Drivers

private struct RelayEchoPromptDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "ack"))))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

/// Emits a chunk and parks until cancelled, so a `session/cancel` has to be
/// read while the prompt it interrupts is still running.
private final class RelayParkingPromptDriver: ACPPromptDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledSessions: [AcpSessionId] = []

    var cancelled: [AcpSessionId] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledSessions
    }

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "working"))))
            ),
            .durable
        )
        while true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func cancel(sessionId: AcpSessionId) async { record(sessionId) }

    /// Synchronous because `NSLock.lock()` is unavailable from an async
    /// context.
    private func record(_ sessionId: AcpSessionId) {
        lock.lock()
        cancelledSessions.append(sessionId)
        lock.unlock()
    }
}

// MARK: - Message helpers

private func relayInitialize(id: Int64) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.initialize,
        params: .object([
            "protocolVersion": .number(.int64(1)),
            "clientCapabilities": .object([:]),
        ])
    )
}

private func relayNewSession(id: Int64, cwd: String) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionNew,
        params: .object(["cwd": .string(cwd), "mcpServers": .array([])])
    )
}

private func relayPrompt(id: Int64, sessionId: String, text: String) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionPrompt,
        params: .object([
            "sessionId": .string(sessionId),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])
    )
}

private func relayCancel(sessionId: String) -> ACPMessage {
    .notification(
        method: AgentMethodNames.sessionCancel,
        params: .object(["sessionId": .string(sessionId)])
    )
}

private func relayAuthError(id: Int64 = 99) -> ACPMessage {
    .response(
        id: .number(id),
        result: nil,
        error: AcpError(code: -32000, message: "expired")
    )
}

private func relayDrain(
    _ transport: any ACPTransport,
    limit: Int = 40,
    until match: (ACPMessage) -> Bool
) async throws -> ACPMessage {
    for _ in 0..<limit {
        let message = try await transport.receive()
        if match(message) { return message }
    }
    throw ACPTransportError.closed
}

private func relaySessionID(from response: ACPMessage) throws -> String {
    guard case .response(_, let result, _) = response,
        case .object(let object)? = result,
        case .string(let id)? = object["sessionId"]
    else { throw ACPTransportError.invalidMessage("no sessionId in \(response)") }
    return id
}

// MARK: - Unit tests

@Suite("Relay handshake headers")
struct ACPRelayHeaderTests {
    private func configuration(
        authorization: ACPRelayAuthorization? = ACPRelayAuthorization(
            token: "tok",
            userID: "user-1"
        )
    ) -> ACPRelayConfiguration {
        ACPRelayConfiguration(
            url: try! WebSocketURL.parse(ACPRelayConfiguration.productionURL),
            authorization: authorization,
            clientVersion: "9.9.9"
        )
    }

    /// `relay.rs:370-397`. Header *names* are what a relay authenticates on, so
    /// they are pinned verbatim — a casing or spelling drift here is a 401 in
    /// production with no local signal.
    @Test("every upstream header is present with its exact name")
    func headerNames() {
        let headers = configuration().handshakeHeaders
        let names = headers.map(\.0)
        #expect(
            names == [
                "Origin",
                "Authorization",
                "X-XAI-Token-Auth",
                "x-userid",
                "x-grok-client-version",
                "x-grok-client-mode",
            ]
        )
        let byName = Dictionary(uniqueKeysWithValues: headers.map { ($0.0, $0.1) })
        #expect(byName["Origin"] == "https://grok.com")
        #expect(byName["Authorization"] == "Bearer tok")
        #expect(byName["X-XAI-Token-Auth"] == "xai-grok-cli")
        #expect(byName["x-userid"] == "user-1")
        #expect(byName["x-grok-client-version"] == "9.9.9")
        #expect(byName["x-grok-client-mode"] == "headless")
    }

    /// A leader with no relay-eligible session still runs; it just must not
    /// send an empty `Authorization: Bearer `, which reads as a malformed
    /// credential rather than as no credential.
    @Test("no credentials means no auth headers at all")
    func unauthenticatedHeaders() {
        let names = configuration(authorization: nil).handshakeHeaders.map(\.0)
        #expect(!names.contains("Authorization"))
        #expect(!names.contains("x-userid"))
        #expect(names.contains("Origin"))
    }

    @Test("the production endpoint matches upstream")
    func productionEndpoint() {
        #expect(ACPRelayConfiguration.productionURL == "wss://code.grok.com/ws/code-agent")
        #expect(ACPRelayConfiguration.productionOrigin == "https://grok.com")
    }

    @Test("the defaults are the upstream timings")
    func defaultTimings() {
        let config = configuration()
        #expect(config.keepAliveSeconds == 15)
        #expect(config.readLivenessSeconds == 60)
        #expect(config.connectTimeoutSeconds == 30)
        #expect(config.reconnect == .relay)
    }

    @Test("the auth error code is -32000")
    func authErrorCode() {
        #expect(ACPRelayTransport.authErrorCode == -32000)
    }
}

// MARK: - Live tests

#if canImport(Network)

private final class RelayAuthRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String?) {
        guard let value else { return }
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var tokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class RelayRecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedReasons: [ACPRelayAuthRecoveryReason] = []

    func record(_ reason: ACPRelayAuthRecoveryReason) {
        lock.lock()
        recordedReasons.append(reason)
        lock.unlock()
    }

    var reasons: [ACPRelayAuthRecoveryReason] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReasons
    }
}

/// A stand-in relay: a plain WebSocket listener that hands back the ACP
/// transport for whichever connection arrived, so a test can drive the leader.
private actor StandInRelay {
    private let server: WebSocketServer
    private let secrets: Set<String>
    private let authRecorder: RelayAuthRecorder
    private var accepted: [ACPWebSocketConnectionTransport] = []
    private var connections: [WebSocketConnection] = []
    private var pump: Task<Void, Never>?

    init(secret: String) {
        let allowed: Set<String> = [secret]
        let recorder = RelayAuthRecorder()
        self.secrets = allowed
        self.authRecorder = recorder
        self.server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(
                    path: "/ws",
                    authorize: { [allowed, recorder] request in
                        recorder.record(request.bearerToken)
                        if let bearer = request.bearerToken { return allowed.contains(bearer) }
                        return request.queryItems["server-key"].map(allowed.contains) ?? false
                    }
                )
            )
        )
    }

    init(secrets: Set<String>) {
        let recorder = RelayAuthRecorder()
        self.secrets = secrets
        self.authRecorder = recorder
        self.server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(
                    path: "/ws",
                    authorize: { [secrets, recorder] request in
                        recorder.record(request.bearerToken)
                        // Same posture as `serve`: a bearer token decides
                        // alone, and only its absence falls through to the
                        // query parameter.
                        if let bearer = request.bearerToken { return secrets.contains(bearer) }
                        return request.queryItems["server-key"].map(secrets.contains) ?? false
                    }
                )
            )
        )
    }

    func start() async throws -> WebSocketURL {
        let port = try await server.start()
        let stream = await server.connections
        pump = Task { [weak self] in
            for await accepted in stream {
                await self?.record(accepted.connection)
            }
        }
        return WebSocketURL(isSecure: false, host: "127.0.0.1", port: port, path: "/ws")
    }

    private func record(_ connection: WebSocketConnection) {
        connections.append(connection)
        accepted.append(ACPWebSocketConnectionTransport(connection: connection))
    }

    /// Wait for connection number `index` (0-based) to arrive.
    func transport(_ index: Int, timeoutSeconds: Double = 10) async throws -> ACPWebSocketConnectionTransport {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if accepted.count > index { return accepted[index] }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ACPTransportError.closed
    }

    func connectionCount() -> Int { accepted.count }

    func bearerTokens() -> [String] { authRecorder.tokens }

    /// Drop connection `index` without a close handshake, the way a lost
    /// network leg does.
    func drop(_ index: Int) async {
        guard connections.count > index else { return }
        await connections[index].close(code: 1006, reason: "dropped")
    }

    func stop() async {
        pump?.cancel()
        for connection in connections {
            await connection.close()
        }
        await server.stop()
    }
}

@Suite("Leader relay over a live socket", .serialized)
struct ACPRelayClientLiveTests {
    private func makeConfiguration(
        url: WebSocketURL,
        secret: String?,
        reconnect: WebSocketReconnectPolicy
    ) -> ACPRelayConfiguration {
        var url = url
        if let secret { url.query = "server-key=\(secret)" }
        return ACPRelayConfiguration(
            url: url,
            authorization: ACPRelayAuthorization(token: secret ?? "", userID: "user-1"),
            connectTimeoutSeconds: 5,
            // Disabled so a 15s ping and a 60s watchdog cannot race a short
            // test.
            keepAliveSeconds: nil,
            readLivenessSeconds: nil,
            reconnect: reconnect
        )
    }

    /// The whole leader relay path in one test: the far side drives
    /// `initialize` → `session/new` → `session/prompt`, sees the streamed
    /// notification, and cancels an in-flight prompt.
    @Test("initialize, prompt, notifications and cancel travel through the relay", .timeLimit(.minutes(1)))
    func endToEndThroughTheRelay() async throws {
        let relay = StandInRelay(secret: "relay-secret")
        let url = try await relay.start()
        defer { Task { await relay.stop() } }

        let driver = RelayParkingPromptDriver()
        let runtime = ACPAgentRuntime(promptDriver: driver)
        let client = ACPRelayClient(
            configuration: makeConfiguration(url: url, secret: "relay-secret", reconnect: .relay),
            makeRuntime: { runtime }
        )
        let running = Task { await client.run() }
        defer { running.cancel() }

        let remote = try await relay.transport(0)

        try await remote.send(relayInitialize(id: 1))
        let initialized = try await relayDrain(remote) { message in
            if case .response(.number(1), _, _) = message { return true }
            return false
        }
        guard case .response(_, let result, let error) = initialized else {
            Issue.record("initialize did not produce a response")
            return
        }
        #expect(error == nil)
        #expect(result != nil)

        try await remote.send(relayNewSession(id: 2, cwd: FileManager.default.currentDirectoryPath))
        let created = try await relayDrain(remote) { message in
            if case .response(.number(2), _, _) = message { return true }
            return false
        }
        let sessionID = try relaySessionID(from: created)

        try await remote.send(relayPrompt(id: 3, sessionId: sessionID, text: "hello"))

        // The streamed notification proves the agent's fan-out reaches the far
        // side of the relay, not just that the request was answered.
        let update = try await relayDrain(remote) { message in
            message.method == ClientMethodNames.sessionUpdate
        }
        #expect(update.method == ClientMethodNames.sessionUpdate)

        // Cancelling while the prompt is parked is only possible because the
        // runtime dispatches each inbound message concurrently.
        try await remote.send(relayCancel(sessionId: sessionID))
        let cancelled = try await relayDrain(remote) { message in
            if case .response(.number(3), _, _) = message { return true }
            return false
        }
        if case .response(_, let result, _) = cancelled, case .object(let object)? = result {
            #expect(object["stopReason"] == .string("cancelled"))
        }
        #expect(driver.cancelled.contains(AcpSessionId(sessionID)))

        await client.stop()
    }

    /// A dropped leg must be redialled. This is the half-open case the relay's
    /// backoff exists for; without it a leader silently stops answering remote
    /// prompts while still looking healthy locally.
    @Test("the relay reconnects after the connection drops", .timeLimit(.minutes(1)))
    func reconnectsAfterDrop() async throws {
        let relay = StandInRelay(secret: "relay-secret")
        let url = try await relay.start()
        defer { Task { await relay.stop() } }

        let runtime = ACPAgentRuntime(promptDriver: RelayEchoPromptDriver())
        let client = ACPRelayClient(
            configuration: makeConfiguration(
                url: url,
                secret: "relay-secret",
                // Same curve, wound down so the test does not wait 2s for the
                // first retry.
                reconnect: WebSocketReconnectPolicy(
                    baseDelaySeconds: 0.01,
                    maximumDelaySeconds: 0.05
                )
            ),
            makeRuntime: { runtime }
        )
        let running = Task { await client.run() }
        defer { running.cancel() }

        _ = try await relay.transport(0)
        await relay.drop(0)

        // The second connection is what proves the redial happened; waiting for
        // it beats sleeping for a fixed interval.
        let second = try await relay.transport(1)
        #expect(await relay.connectionCount() >= 2)

        // And the redialled connection is a working ACP link, not just an open
        // socket.
        try await second.send(relayInitialize(id: 1))
        let initialized = try await relayDrain(second) { message in
            if case .response(.number(1), _, _) = message { return true }
            return false
        }
        if case .response(_, _, let error) = initialized {
            #expect(error == nil)
        }

        #expect(await client.successfulConnectionCount() >= 2)
        await client.stop()
    }

    @Test("an in-band auth error refreshes the bearer before reconnecting", .timeLimit(.minutes(1)))
    func inBandAuthRecoveryUsesNewBearer() async throws {
        let relay = StandInRelay(secrets: ["old-token", "new-token"])
        let url = try await relay.start()
        defer { Task { await relay.stop() } }

        let recovery = RelayRecoveryRecorder()
        let runtime = ACPAgentRuntime(promptDriver: RelayEchoPromptDriver())
        let client = ACPRelayClient(
            configuration: makeConfiguration(
                url: url,
                secret: "old-token",
                reconnect: WebSocketReconnectPolicy(baseDelaySeconds: 0.01, maximumDelaySeconds: 0.05)
            ),
            makeRuntime: { runtime },
            authRecovery: { reason in
                recovery.record(reason)
                return .recovered(
                    ACPRelayAuthorization(token: "new-token", userID: "user-1")
                )
            }
        )
        let running = Task { await client.run() }
        defer { Task { await client.stop() } }

        let first = try await relay.transport(0)
        try await first.send(relayAuthError())
        let second = try await relay.transport(1)
        try await second.send(relayInitialize(id: 1))
        let initialized = try await relayDrain(second) { message in
            if case .response(.number(1), _, _) = message { return true }
            return false
        }
        if case .response(_, _, let error) = initialized {
            #expect(error == nil)
        }

        #expect(recovery.reasons == [.authError])
        #expect(await relay.bearerTokens() == ["old-token", "new-token"])
        await client.stop()
        await running.value
    }

    @Test("a handshake 401 refreshes the bearer before retrying", .timeLimit(.minutes(1)))
    func handshakeUnauthorizedRecoveryUsesNewBearer() async throws {
        let relay = StandInRelay(secrets: ["new-token"])
        let url = try await relay.start()
        defer { Task { await relay.stop() } }

        let recovery = RelayRecoveryRecorder()
        let runtime = ACPAgentRuntime(promptDriver: RelayEchoPromptDriver())
        let client = ACPRelayClient(
            configuration: makeConfiguration(
                url: url,
                secret: "old-token",
                reconnect: WebSocketReconnectPolicy(baseDelaySeconds: 0.01, maximumDelaySeconds: 0.05)
            ),
            makeRuntime: { runtime },
            authRecovery: { reason in
                recovery.record(reason)
                return .recovered(
                    ACPRelayAuthorization(token: "new-token", userID: "user-1")
                )
            }
        )
        let running = Task { await client.run() }
        defer { Task { await client.stop() } }

        let second = try await relay.transport(0)
        try await second.send(relayInitialize(id: 1))
        let initialized = try await relayDrain(second) { message in
            if case .response(.number(1), _, _) = message { return true }
            return false
        }
        if case .response(_, _, let error) = initialized {
            #expect(error == nil)
        }

        #expect(recovery.reasons == [.handshakeUnauthorized])
        #expect(await relay.bearerTokens() == ["old-token", "new-token"])
        await client.stop()
        await running.value
    }

    @Test("terminal auth recovery stops without another connection", .timeLimit(.minutes(1)))
    func terminalAuthRecoveryStopsRelay() async throws {
        let relay = StandInRelay(secret: "old-token")
        let url = try await relay.start()
        defer { Task { await relay.stop() } }

        let runtime = ACPAgentRuntime(promptDriver: RelayEchoPromptDriver())
        let client = ACPRelayClient(
            configuration: makeConfiguration(
                url: url,
                secret: "old-token",
                reconnect: WebSocketReconnectPolicy(baseDelaySeconds: 0.01, maximumDelaySeconds: 0.05)
            ),
            makeRuntime: { runtime },
            authRecovery: { _ in .terminalFailure }
        )
        let running = Task { await client.run() }
        let first = try await relay.transport(0)
        try await first.send(relayAuthError())
        await running.value

        #expect(await relay.connectionCount() == 1)
        #expect(await client.mostRecentEndReason() == .authError)
    }

    @Test("retryable auth recovery keeps bounded reconnect active", .timeLimit(.minutes(1)))
    func retryableAuthRecoveryBacksOffAndRetries() async throws {
        let relay = StandInRelay(secret: "old-token")
        let url = try await relay.start()
        defer { Task { await relay.stop() } }

        let recovery = RelayRecoveryRecorder()
        let runtime = ACPAgentRuntime(promptDriver: RelayEchoPromptDriver())
        let client = ACPRelayClient(
            configuration: makeConfiguration(
                url: url,
                secret: "old-token",
                reconnect: WebSocketReconnectPolicy(baseDelaySeconds: 0.01, maximumDelaySeconds: 0.05)
            ),
            makeRuntime: { runtime },
            authRecovery: { reason in
                recovery.record(reason)
                return .retryableFailure
            }
        )
        let running = Task { await client.run() }
        defer { Task { await client.stop() } }

        let first = try await relay.transport(0)
        try await first.send(relayAuthError())
        _ = try await relay.transport(1)

        #expect(recovery.reasons == [.authError])
        #expect(await relay.connectionCount() >= 2)
        await client.stop()
        await running.value
    }

    /// A wrong secret is a 401 at the handshake. With a bounded policy the
    /// client gives up rather than hammering an endpoint that will keep
    /// refusing it.
    @Test("a wrong secret is rejected and the bounded policy gives up", .timeLimit(.minutes(1)))
    func wrongSecretIsRejected() async throws {
        let relay = StandInRelay(secret: "relay-secret")
        let url = try await relay.start()
        defer { Task { await relay.stop() } }

        let runtime = ACPAgentRuntime(promptDriver: RelayEchoPromptDriver())
        let client = ACPRelayClient(
            configuration: makeConfiguration(
                url: url,
                secret: "wrong-secret",
                reconnect: WebSocketReconnectPolicy(
                    baseDelaySeconds: 0.005,
                    maximumDelaySeconds: 0.01,
                    maximumAttempts: 2
                )
            ),
            makeRuntime: { runtime }
        )

        // `run()` returns on its own once the bounded policy is exhausted; if
        // it did not, the time limit would fail the test rather than hanging
        // the suite.
        await client.run()

        #expect(await client.successfulConnectionCount() == 0)
        #expect(await relay.connectionCount() == 0)
        guard case .transportFailure = await client.mostRecentEndReason() else {
            Issue.record("expected a transport failure, got \(String(describing: await client.mostRecentEndReason()))")
            return
        }
    }

    /// The dial itself must report the 401, so a misconfigured secret is
    /// diagnosable from the error rather than only from a silence.
    @Test("the rejected handshake reports HTTP 401", .timeLimit(.minutes(1)))
    func rejectionSurfacesStatus() async throws {
        let relay = StandInRelay(secret: "relay-secret")
        var url = try await relay.start()
        defer { Task { await relay.stop() } }
        url.query = "server-key=nope"

        do {
            _ = try await WebSocketDialer.connect(
                to: url,
                options: WebSocketDialOptions(connectTimeoutSeconds: 5)
            )
            Issue.record("expected the wrong secret to be refused")
        } catch let error as WebSocketChannelError {
            guard case .handshakeRejected(let status, _) = error else {
                Issue.record("expected handshakeRejected, got \(error)")
                return
            }
            #expect(status == 401)
        }
    }
}

#endif
