// WebSocketClientTests.swift
//
// URL parsing, the relay backoff schedule, and dial-time failure.

import Foundation
import Testing

@testable import OpenGrokHTTP

@Suite("WebSocket URL parsing")
struct WebSocketURLTests {
    @Test("ws and wss default to 80 and 443")
    func schemeDefaultsThePort() throws {
        #expect(try WebSocketURL.parse("ws://example.com/ws").port == 80)
        #expect(try WebSocketURL.parse("wss://example.com/ws").port == 443)
    }

    @Test("the production relay URL parses into its parts")
    func productionRelayURL() throws {
        let url = try WebSocketURL.parse("wss://code.grok.com/ws/code-agent")
        #expect(url.isSecure)
        #expect(url.host == "code.grok.com")
        #expect(url.port == 443)
        #expect(url.path == "/ws/code-agent")
        #expect(url.query == nil)
        #expect(url.target == "/ws/code-agent")
    }

    @Test("an explicit port is kept and appears in the Host header")
    func explicitPort() throws {
        let url = try WebSocketURL.parse("ws://127.0.0.1:2419/ws")
        #expect(url.port == 2419)
        #expect(url.hostHeader == "127.0.0.1:2419")
    }

    /// A `Host` carrying a default port breaks virtual-host matching on some
    /// servers, so the port must be elided exactly when it is the default.
    @Test("a default port is elided from the Host header")
    func defaultPortElided() throws {
        #expect(try WebSocketURL.parse("wss://grok.com:443/ws").hostHeader == "grok.com")
        #expect(try WebSocketURL.parse("ws://grok.com:80/ws").hostHeader == "grok.com")
        #expect(try WebSocketURL.parse("wss://grok.com:8443/ws").hostHeader == "grok.com:8443")
    }

    @Test("the query survives and rejoins the target")
    func queryRoundTrips() throws {
        let url = try WebSocketURL.parse("ws://host:9/ws?server-key=abc&x=1")
        #expect(url.path == "/ws")
        #expect(url.query == "server-key=abc&x=1")
        #expect(url.target == "/ws?server-key=abc&x=1")
    }

    /// The colon inside an IPv6 literal is not a port separator; splitting on
    /// the last colon without bracket handling would produce host `[::1` .
    @Test("IPv6 literals keep their colons")
    func ipv6Literal() throws {
        let bare = try WebSocketURL.parse("ws://[::1]/ws")
        #expect(bare.host == "::1")
        #expect(bare.port == 80)

        let ported = try WebSocketURL.parse("ws://[::1]:2419/ws")
        #expect(ported.host == "::1")
        #expect(ported.port == 2419)
        #expect(ported.hostHeader == "[::1]:2419")
    }

    @Test("a missing path becomes /")
    func emptyPathIsRoot() throws {
        #expect(try WebSocketURL.parse("ws://example.com").path == "/")
        #expect(try WebSocketURL.parse("ws://example.com?a=1").target == "/?a=1")
    }

    @Test("non-WebSocket schemes and malformed input are refused")
    func rejections() {
        #expect(throws: WebSocketURLError.self) { try WebSocketURL.parse("https://example.com") }
        #expect(throws: WebSocketURLError.self) { try WebSocketURL.parse("example.com/ws") }
        #expect(throws: WebSocketURLError.self) { try WebSocketURL.parse("ws:///ws") }
        #expect(throws: WebSocketURLError.self) { try WebSocketURL.parse("ws://host:0/ws") }
        #expect(throws: WebSocketURLError.self) { try WebSocketURL.parse("ws://host:notaport/ws") }
    }

    @Test("absoluteString round-trips through parse")
    func roundTrip() throws {
        for text in [
            "wss://code.grok.com/ws/code-agent",
            "ws://127.0.0.1:2419/ws?server-key=abc",
            "ws://[::1]:9000/ws",
        ] {
            #expect(try WebSocketURL.parse(text).absoluteString == text)
        }
    }
}

@Suite("Relay reconnect schedule")
struct WebSocketReconnectPolicyTests {
    /// `relay.rs:341-353` increments the delay before the first sleep, so the
    /// first wait is 2s, not the 1s base. Pinned because an off-by-one here
    /// silently doubles reconnect latency at every point on the curve.
    @Test("the relay schedule is 2, 4, 8, 16, 32, 60, 60")
    func relaySchedule() {
        let policy = WebSocketReconnectPolicy.relay
        let observed = (1...7).map { policy.delaySeconds(forAttempt: $0) }
        #expect(observed == [2, 4, 8, 16, 32, 60, 60])
    }

    @Test("the relay retries forever")
    func relayIsUnbounded() {
        #expect(WebSocketReconnectPolicy.relay.maximumAttempts == nil)
        #expect(WebSocketReconnectPolicy.relay.shouldRetry(afterAttempt: 10_000))
    }

    /// `leader/mod.rs:113-118` — the bounded variant caps at 30s and stops
    /// after 5 attempts, so a headless client fails instead of hanging.
    @Test("the bounded leader-client schedule caps at 30s and stops at 5")
    func boundedSchedule() {
        let policy = WebSocketReconnectPolicy.boundedLeaderClient
        #expect((1...6).map { policy.delaySeconds(forAttempt: $0) } == [2, 4, 8, 16, 30, 30])
        #expect(policy.shouldRetry(afterAttempt: 4))
        #expect(!policy.shouldRetry(afterAttempt: 5))
    }

    @Test("attempt zero waits not at all")
    func zeroAttempt() {
        #expect(WebSocketReconnectPolicy.relay.delaySeconds(forAttempt: 0) == 0)
        #expect(WebSocketReconnectPolicy.relay.delayNanoseconds(forAttempt: 0) == 0)
    }

    @Test("nanoseconds match the seconds")
    func nanosecondsAgree() {
        #expect(WebSocketReconnectPolicy.relay.delayNanoseconds(forAttempt: 1) == 2_000_000_000)
    }
}

@Suite("Dial options")
struct WebSocketDialOptionsTests {
    @Test("defaults match the relay's connect timeout")
    func defaults() {
        let options = WebSocketDialOptions()
        #expect(options.connectTimeoutSeconds == 30)
        #expect(options.maximumMessageSize == WebSocketLimits.defaultMaximumMessageSize)
        #expect(options.headers.isEmpty)
    }

    @Test("outbound backend is portable off Network.framework")
    func backendSelection() {
        #if canImport(Network)
        #expect(WebSocketDialer.outboundBackend == .networkFramework)
        #else
        #expect(WebSocketDialer.outboundBackend == .urlSession)
        #endif
    }
}

@Suite("Windows named-pipe names")
struct WindowsNamedPipeNameTests {
    @Test("leader paths map deterministically to bounded pipe names")
    func deterministicName() {
        let first = WindowsNamedPipeName.fullName(forPath: "C:\\Users\\me\\.grok\\leader.sock")
        let repeated = WindowsNamedPipeName.fullName(forPath: "C:\\Users\\me\\.grok\\leader.sock")
        let other = WindowsNamedPipeName.fullName(forPath: "C:\\Users\\other\\.grok\\leader.sock")

        #expect(first == repeated)
        #expect(first != other)
        #expect(first.hasPrefix("\\\\.\\pipe\\grok-leader-"))
        #expect(first.utf8.count < 80)
    }
}

@Suite("Dialling a live socket", .serialized)
struct WebSocketDialerLiveTests {
    /// A refused connection must fail at dial time with the endpoint named,
    /// not later as an end-of-stream partway through the handshake.
    @Test("a closed port fails at dial time", .timeLimit(.minutes(1)))
    func refusedConnection() async throws {
        // Bind and immediately release, so the port is almost certainly unused
        // while staying inside the ephemeral range the OS just handed out.
        let probe = WebSocketServer(
            configuration: WebSocketServerConfiguration(host: "127.0.0.1", port: 0)
        )
        let port = try await probe.start()
        await probe.stop()

        let url = WebSocketURL(isSecure: false, host: "127.0.0.1", port: port, path: "/ws")
        await #expect(throws: (any Error).self) {
            _ = try await WebSocketDialer.connect(
                to: url,
                options: WebSocketDialOptions(connectTimeoutSeconds: 2)
            )
        }
    }

    @Test("a rejected upgrade surfaces the HTTP status", .timeLimit(.minutes(1)))
    func rejectedUpgrade() async throws {
        let server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(path: "/ws", authorize: { _ in false })
            )
        )
        let port = try await server.start()
        let accepted = Task { for await _ in await server.connections {} }
        defer {
            accepted.cancel()
            Task { await server.stop() }
        }

        let url = WebSocketURL(isSecure: false, host: "127.0.0.1", port: port, path: "/ws")
        do {
            _ = try await WebSocketDialer.connect(
                to: url,
                options: WebSocketDialOptions(connectTimeoutSeconds: 5)
            )
            Issue.record("expected the unauthorized upgrade to be rejected")
        } catch let error as WebSocketChannelError {
            guard case .handshakeRejected(let status, _) = error else {
                Issue.record("expected handshakeRejected, got \(error)")
                return
            }
            #expect(status == 401)
        }
    }

    @Test("an authorized dial reaches the server", .timeLimit(.minutes(1)))
    func successfulDial() async throws {
        let server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(path: "/ws")
            )
        )
        let port = try await server.start()
        let echoed = Task {
            for await accepted in await server.connections {
                guard let message = try? await accepted.connection.receive() else { continue }
                if case .text(let text) = message {
                    try? await accepted.connection.send(.text("echo:" + text))
                }
            }
        }
        defer {
            echoed.cancel()
            Task { await server.stop() }
        }

        let url = WebSocketURL(isSecure: false, host: "127.0.0.1", port: port, path: "/ws")
        let connection = try await WebSocketDialer.connect(
            to: url,
            options: WebSocketDialOptions(
                headers: [("x-grok-client-mode", "headless")],
                connectTimeoutSeconds: 5
            )
        )
        try await connection.send(.text("hello"))
        let reply = try await connection.receive()
        #expect(reply == .text("echo:hello"))
        await connection.close()
    }
}
