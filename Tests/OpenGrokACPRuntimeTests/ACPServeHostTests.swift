// ACPServeHostTests.swift
//
// End-to-end coverage for `open-grok serve`: a real `ACPAgentRuntime` served
// over a real loopback TCP socket, driven by a WebSocket client that performs
// the RFC 6455 handshake and speaks real frames.
//
// The client is the shipping `WebSocketConnection` in client role over a real
// dialled socket, so the handshake, the frame codec, the accept loop and the
// ACP runtime are all the production code paths — nothing here is a stand-in
// for the thing being tested except the prompt driver.

import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

// MARK: - Drivers

/// Emits one chunk, then answers. Used for the round-trip paths.
private struct ServeEchoPromptDriver: ACPPromptDriver {
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

/// Emits a chunk and then parks until cancelled.
///
/// The park is the point: a `session/cancel` has to be read and acted on while
/// the prompt it interrupts is still running, which only works because
/// `ACPAgentRuntime.serve` dispatches each inbound message concurrently.
private final class ServeParkingPromptDriver: ACPPromptDriver, @unchecked Sendable {
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

    private func record(_ sessionId: AcpSessionId) {
        lock.lock()
        cancelledSessions.append(sessionId)
        lock.unlock()
    }
}

// MARK: - Message helpers

private func serveInitialize(id: Int64) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.initialize,
        params: .object([
            "protocolVersion": .number(.int64(1)),
            "clientCapabilities": .object([:]),
        ])
    )
}

private func serveNewSession(id: Int64, cwd: String) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionNew,
        params: .object(["cwd": .string(cwd), "mcpServers": .array([])])
    )
}

private func servePrompt(id: Int64, sessionId: String, text: String) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionPrompt,
        params: .object([
            "sessionId": .string(sessionId),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])
    )
}

private func serveCancel(sessionId: String) -> ACPMessage {
    .notification(
        method: AgentMethodNames.sessionCancel,
        params: .object(["sessionId": .string(sessionId)])
    )
}

private func serveDrain(
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

private func serveSessionID(from response: ACPMessage) throws -> String {
    guard case .response(_, let result, _) = response,
          case .object(let object)? = result,
          case .string(let id)? = object["sessionId"]
    else { throw ACPTransportError.invalidMessage("no sessionId in \(response)") }
    return id
}

/// Bring up a host on an ephemeral loopback port and dial it.
private func connectClient(
    to endpoint: ACPServeEndpoint,
    query: String
) async throws -> ACPWebSocketConnectionTransport {
    let channel = try await WebSocketNetworkChannel.connect(
        host: endpoint.host,
        port: endpoint.port
    )
    let connection = try await WebSocketClientUpgrade.connect(
        channel: channel,
        host: endpoint.address,
        target: endpoint.path + query
    )
    return ACPWebSocketConnectionTransport(connection: connection)
}

// MARK: - Unit-level tests

@Suite("ACP serve inbound normalization")
struct ACPServeNormalizationTests {
    @Test func stripsTrailingLineTerminators() {
        // `server.rs:222` trims trailing CR/LF before parsing.
        #expect(ACPWebSocketConnectionTransport.normalize("{\"a\":1}\r\n") == "{\"a\":1}")
        #expect(ACPWebSocketConnectionTransport.normalize("{\"a\":1}\n") == "{\"a\":1}")
        #expect(ACPWebSocketConnectionTransport.normalize("{\"a\":1}") == "{\"a\":1}")
    }

    @Test func skipsBrowserKeepalivesAndEmptyFrames() {
        // `server.rs:224-226`: browsers send the literal text `ping` as an
        // application keepalive. Parsing it as JSON would fail every 15s.
        #expect(ACPWebSocketConnectionTransport.normalize("ping") == nil)
        #expect(ACPWebSocketConnectionTransport.normalize("ping\n") == nil)
        #expect(ACPWebSocketConnectionTransport.normalize("") == nil)
        #expect(ACPWebSocketConnectionTransport.normalize("\r\n") == nil)
        // Only the exact token is skipped; a message that merely mentions it
        // is still a message.
        #expect(ACPWebSocketConnectionTransport.normalize("pinged") == "pinged")
    }
}

@Suite("ACP serve authorization")
struct ACPServeAuthorizationTests {
    private func request(bearer: String? = nil, serverKey: String? = nil) -> WebSocketHandshakeRequest {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer \(bearer)" }
        var query: [String: String] = [:]
        if let serverKey { query["server-key"] = serverKey }
        return WebSocketHandshakeRequest(
            method: "GET",
            target: "/ws",
            path: "/ws",
            queryItems: query,
            headers: headers
        )
    }

    @Test func acceptsAMatchingBearerToken() {
        let auth = ACPServeAuthorization(secret: "s3cret")
        #expect(auth.authorize(request(bearer: "s3cret")))
    }

    @Test func acceptsAMatchingQueryParameter() {
        let auth = ACPServeAuthorization(secret: "s3cret")
        #expect(auth.authorize(request(serverKey: "s3cret")))
    }

    @Test func aPresentBearerTokenDecidesAlone() {
        // `server.rs:96-104`: the query fallback is reached only when the
        // header is absent. A wrong bearer token is not rescued by a right
        // `?server-key=`, and copying that ordering matters — the other order
        // would let a stale header be bypassed by appending a query param.
        let auth = ACPServeAuthorization(secret: "s3cret")
        #expect(!auth.authorize(request(bearer: "wrong", serverKey: "s3cret")))
    }

    @Test func rejectsWhenNeitherIsPresent() {
        let auth = ACPServeAuthorization(secret: "s3cret")
        #expect(!auth.authorize(request()))
    }

    @Test func rejectsAPrefixOrSuffixOfTheSecret() {
        let auth = ACPServeAuthorization(secret: "s3cret")
        #expect(!auth.authorize(request(bearer: "s3cre")))
        #expect(!auth.authorize(request(bearer: "s3crett")))
        #expect(!auth.authorize(request(bearer: "")))
    }

    @Test func constantTimeComparisonAgreesWithEquality() {
        let samples = ["", "a", "abc", "abd", "abcd", "s3cret", "S3CRET"]
        for left in samples {
            for right in samples {
                #expect(
                    ACPServeAuthorization.constantTimeEquals(left, right) == (left == right),
                    "\(left) vs \(right)"
                )
            }
        }
    }
}

@Suite("ACP serve endpoint formatting")
struct ACPServeEndpointTests {
    @Test func rendersTheURLUpstreamPrints() {
        let endpoint = ACPServeEndpoint(host: "127.0.0.1", port: 2419, path: "/ws")
        #expect(endpoint.address == "127.0.0.1:2419")
        #expect(endpoint.url == "ws://127.0.0.1:2419/ws")
        // `main.rs:97-100` prints exactly this shape.
        #expect(endpoint.url(withSecret: "abc") == "ws://127.0.0.1:2419/ws?server-key=abc")
    }
}

// MARK: - End-to-end over a real socket

@Suite("ACP serve host over a live socket", .serialized)
struct ACPServeHostLiveTests {
    private func makeHost(
        driver: any ACPPromptDriver,
        store: any ACPSessionStore = InMemoryACPSessionStore(),
        secret: String = "test-secret"
    ) -> ACPServeHost {
        ACPServeHost(
            configuration: ACPServeConfiguration(
                host: "127.0.0.1",
                // Port 0 takes an ephemeral port so tests never collide with a
                // developer's real `open-grok serve` on 2419.
                port: 0,
                secret: secret,
                // Disabled so a 15s ping cannot race a short test.
                keepAliveInterval: nil
            ),
            makeRuntime: { ACPAgentRuntime(store: store, promptDriver: driver) }
        )
    }

    @Test("initialize, session/new and prompt round-trip over ws://")
    func liveRoundTrip() async throws {
        let host = makeHost(driver: ServeEchoPromptDriver())
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let client = try await connectClient(to: endpoint, query: "?server-key=test-secret")
        try await client.send(serveInitialize(id: 1))
        let initialized = try await serveDrain(client) { $0.id == .number(1) }
        guard case .response(_, _, let initializeError) = initialized else {
            Issue.record("expected an initialize response, got \(initialized)")
            return
        }
        #expect(initializeError == nil)

        try await client.send(serveNewSession(id: 2, cwd: FileManager.default.currentDirectoryPath))
        let created = try await serveDrain(client) { $0.id == .number(2) }
        let sessionId = try serveSessionID(from: created)
        #expect(!sessionId.isEmpty)

        try await client.send(servePrompt(id: 3, sessionId: sessionId, text: "hello"))
        var sawChunk = false
        var stopReason: String?
        for _ in 0..<40 {
            let message = try await client.receive()
            if message.method == ClientMethodNames.sessionUpdate { sawChunk = true }
            if message.id == .number(3) {
                if case .response(_, .object(let object)?, _) = message,
                   case .string(let reason)? = object["stopReason"] {
                    stopReason = reason
                }
                break
            }
        }
        // The streaming half matters as much as the response: an ACP client
        // over WebSocket must get the same `session/update` fan-out stdio gets.
        #expect(sawChunk)
        #expect(stopReason == "end_turn")
        await client.close()
    }

    @Test("session/cancel interrupts a prompt that is still running")
    func liveCancel() async throws {
        let driver = ServeParkingPromptDriver()
        let host = makeHost(driver: driver)
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let client = try await connectClient(to: endpoint, query: "?server-key=test-secret")
        try await client.send(serveInitialize(id: 1))
        _ = try await serveDrain(client) { $0.id == .number(1) }
        try await client.send(serveNewSession(id: 2, cwd: FileManager.default.currentDirectoryPath))
        let sessionId = try serveSessionID(from: try await serveDrain(client) { $0.id == .number(2) })

        try await client.send(servePrompt(id: 3, sessionId: sessionId, text: "park"))
        // Wait for the first chunk so the prompt is definitely in flight; a
        // cancel that arrives before the prompt starts would prove nothing.
        _ = try await serveDrain(client) { $0.method == ClientMethodNames.sessionUpdate }

        try await client.send(serveCancel(sessionId: sessionId))
        let response = try await serveDrain(client) { $0.id == .number(3) }
        guard case .response(_, .object(let object)?, _) = response,
              case .string(let reason)? = object["stopReason"]
        else {
            Issue.record("expected a stopReason in \(response)")
            return
        }
        #expect(reason == "cancelled")
        #expect(driver.cancelled.map(\.rawValue).contains(sessionId))
        await client.close()
    }

    @Test("a wrong secret is refused with HTTP 401 before the upgrade")
    func liveRejectsABadSecret() async throws {
        let host = makeHost(driver: ServeEchoPromptDriver())
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let channel = try await WebSocketNetworkChannel.connect(
            host: endpoint.host,
            port: endpoint.port
        )
        do {
            _ = try await WebSocketClientUpgrade.connect(
                channel: channel,
                host: endpoint.address,
                target: endpoint.path + "?server-key=wrong"
            )
            Issue.record("a wrong secret must not upgrade")
        } catch let error as WebSocketChannelError {
            guard case .handshakeRejected(let status, let body) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(status == 401)
            #expect(body == "Invalid or missing authorization token")
        }
    }

    @Test("an absent secret is refused")
    func liveRejectsAMissingSecret() async throws {
        let host = makeHost(driver: ServeEchoPromptDriver())
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let channel = try await WebSocketNetworkChannel.connect(
            host: endpoint.host,
            port: endpoint.port
        )
        await #expect(throws: WebSocketChannelError.self) {
            _ = try await WebSocketClientUpgrade.connect(
                channel: channel,
                host: endpoint.address,
                target: endpoint.path
            )
        }
    }

    @Test("a request to another path is refused with 404")
    func liveRejectsAnotherPath() async throws {
        let host = makeHost(driver: ServeEchoPromptDriver())
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let channel = try await WebSocketNetworkChannel.connect(
            host: endpoint.host,
            port: endpoint.port
        )
        do {
            _ = try await WebSocketClientUpgrade.connect(
                channel: channel,
                host: endpoint.address,
                target: "/socket?server-key=test-secret"
            )
            Issue.record("only /ws is served")
        } catch let error as WebSocketChannelError {
            guard case .handshakeRejected(let status, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            // Upstream mounts exactly one route, so anything else is a 404 —
            // and a 404 rather than a 401 is what tells an operator they have
            // the path wrong, not the token.
            #expect(status == 404)
        }
    }

    @Test("a bearer token authorizes as well as the query parameter")
    func liveAcceptsABearerToken() async throws {
        let host = makeHost(driver: ServeEchoPromptDriver())
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let channel = try await WebSocketNetworkChannel.connect(
            host: endpoint.host,
            port: endpoint.port
        )
        let connection = try await WebSocketClientUpgrade.connect(
            channel: channel,
            host: endpoint.address,
            target: endpoint.path,
            headers: [("Authorization", "Bearer test-secret")]
        )
        let client = ACPWebSocketConnectionTransport(connection: connection)
        try await client.send(serveInitialize(id: 1))
        let initialized = try await serveDrain(client) { $0.id == .number(1) }
        #expect(initialized.id == .number(1))
        await client.close()
    }

    @Test("session state survives a reconnect")
    func liveReconnectKeepsTheSession() async throws {
        // The shared store is what makes reconnect resume rather than restart:
        // upstream keeps one `MvpAgent` alive across reconnects
        // (`server.rs:293-343`); this port rebuilds the runtime per connection
        // over the same store, which preserves the session the client holds.
        let store = InMemoryACPSessionStore()
        let host = makeHost(driver: ServeEchoPromptDriver(), store: store)
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let first = try await connectClient(to: endpoint, query: "?server-key=test-secret")
        try await first.send(serveInitialize(id: 1))
        _ = try await serveDrain(first) { $0.id == .number(1) }
        try await first.send(serveNewSession(id: 2, cwd: FileManager.default.currentDirectoryPath))
        let sessionId = try serveSessionID(from: try await serveDrain(first) { $0.id == .number(2) })
        await first.close()

        let second = try await connectClient(to: endpoint, query: "?server-key=test-secret")
        try await second.send(serveInitialize(id: 10))
        _ = try await serveDrain(second) { $0.id == .number(10) }
        // The session created on the first connection is still addressable.
        try await second.send(servePrompt(id: 11, sessionId: sessionId, text: "again"))
        let response = try await serveDrain(second) { $0.id == .number(11) }
        guard case .response(_, _, let error) = response else {
            Issue.record("expected a prompt response, got \(response)")
            return
        }
        #expect(error == nil)
        await second.close()
    }
}
