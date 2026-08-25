#if os(Windows)

import Foundation
import Testing

@testable import OpenGrokHTTP

@Suite("Native Windows WebSocket parity", .serialized)
struct WindowsWebSocketParityTests {
    @Test("WinHTTP enforces the Rust relay's 15-second keepalive")
    func nativeKeepaliveMatchesUpstream() {
        #expect(WindowsWebSocketClient.nativeKeepaliveIntervalMilliseconds == 15_000)
        #expect(WebSocketLimits.keepAliveIntervalSeconds == 15)
    }

    @Test("handshake header injection fails before opening a connection")
    func injectedHeadersAreRejected() async throws {
        let endpoint = try WebSocketURL.parse("wss://127.0.0.1:1/ws")
        let prohibitedHeaders = [
            ("X-Injected\r\nAuthorization", "Bearer secret-one"),
            ("Authorization", "Bearer secret-two\r\nX-Leak: yes"),
            ("Host", "secret-three.example"),
            ("Cookie", "secret-four"),
            ("Proxy-Authorization", "Bearer secret-five"),
        ]

        for header in prohibitedHeaders {
            do {
                _ = try await WindowsWebSocketClient.connect(
                    to: endpoint,
                    options: WebSocketDialOptions(
                        headers: [header],
                        connectTimeoutSeconds: 1
                    ),
                    extraRootCertificates: []
                )
                Issue.record("a prohibited WebSocket header unexpectedly reached the network")
            } catch let error as WebSocketDialError {
                guard case .connectionFailed(_, let detail) = error else {
                    Issue.record("expected a header validation failure, got \(error)")
                    continue
                }
                #expect(!detail.contains("secret-"))
                #expect(!detail.contains("Bearer"))
            }
        }
    }

    @Test("unsupported enterprise TLS roots fail closed")
    func unsupportedEnterpriseRootsAreRejected() async throws {
        let endpoint = try WebSocketURL.parse("wss://127.0.0.1:1/ws")
        do {
            _ = try await WindowsWebSocketClient.connect(
                to: endpoint,
                options: WebSocketDialOptions(connectTimeoutSeconds: 1),
                extraRootCertificates: [Data([0x30, 0x01, 0x00])]
            )
            Issue.record("configured TLS roots unexpectedly bypassed the Windows trust boundary")
        } catch let error as WebSocketDialError {
            guard case .unsupportedPlatform(let detail) = error else {
                Issue.record("expected unsupportedPlatform, got \(error)")
                return
            }
            #expect(detail.contains("additional TLS trust roots"))
        }
    }

    @Test("native upgrade preserves relay headers and exchanges text and binary", .timeLimit(.minutes(1)))
    func nativeClientExchangesTextAndBinary() async throws {
        let server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(
                    path: "/ws",
                    authorize: { request in
                        request.bearerToken == "windows-test-token"
                            && request.header("x-grok-client-mode") == "headless"
                            && request.queryItems["channel"] == "native"
                    }
                )
            )
        )
        let port = try await server.start()
        let served = Task {
            for await accepted in await server.connections {
                do {
                    guard let first = try await accepted.connection.receive() else { continue }
                    if case .text(let value) = first {
                        try await accepted.connection.send(.text("echo:" + value))
                    }
                    guard let second = try await accepted.connection.receive() else { continue }
                    if case .data(let value) = second {
                        try await accepted.connection.send(.data(value))
                    }
                } catch {
                    return
                }
            }
        }
        defer {
            served.cancel()
            Task { await server.stop() }
        }

        let endpoint = WebSocketURL(
            isSecure: false,
            host: "127.0.0.1",
            port: port,
            path: "/ws",
            query: "channel=native"
        )
        let client = try await WindowsWebSocketClient.connect(
            to: endpoint,
            options: WebSocketDialOptions(
                headers: [
                    ("Authorization", "Bearer windows-test-token"),
                    ("x-grok-client-mode", "headless"),
                ],
                connectTimeoutSeconds: 5
            ),
            extraRootCertificates: []
        )

        try await client.send(.text("hello"))
        #expect(try await client.receive() == .text("echo:hello"))

        let binary = Data([0, 1, 127, 255])
        try await client.send(.data(binary))
        #expect(try await client.receive() == .data(binary))

        try await client.ping()
        await client.close(code: 1000, reason: "finished")
    }

    @Test("rejected native upgrades preserve the HTTP authorization status", .timeLimit(.minutes(1)))
    func rejectedUpgradePreservesHTTPStatus() async throws {
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

        do {
            _ = try await WindowsWebSocketClient.connect(
                to: WebSocketURL(isSecure: false, host: "127.0.0.1", port: port, path: "/ws"),
                options: WebSocketDialOptions(connectTimeoutSeconds: 5),
                extraRootCertificates: []
            )
            Issue.record("an unauthorized native WebSocket upgrade unexpectedly succeeded")
        } catch let error as WebSocketChannelError {
            guard case .handshakeRejected(let status, _) = error else {
                Issue.record("expected handshakeRejected, got \(error)")
                return
            }
            #expect(status == 401)
        }
    }

    @Test("native receive enforces the configured maximum message size", .timeLimit(.minutes(1)))
    func oversizedMessagesAreRejected() async throws {
        let server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(path: "/ws")
            )
        )
        let port = try await server.start()
        let served = Task {
            for await accepted in await server.connections {
                do {
                    try await accepted.connection.send(.text(String(repeating: "a", count: 33)))
                } catch {
                    return
                }
            }
        }
        defer {
            served.cancel()
            Task { await server.stop() }
        }

        let client = try await WindowsWebSocketClient.connect(
            to: WebSocketURL(isSecure: false, host: "127.0.0.1", port: port, path: "/ws"),
            options: WebSocketDialOptions(connectTimeoutSeconds: 5, maximumMessageSize: 32),
            extraRootCertificates: []
        )

        do {
            _ = try await client.receive()
            Issue.record("an oversized native WebSocket message was accepted")
        } catch let error as WebSocketProtocolError {
            guard case .messageTooLarge(let limit) = error else {
                Issue.record("expected messageTooLarge, got \(error)")
                return
            }
            #expect(limit == 32)
        }
    }

    @Test("secure URLs never downgrade to a plaintext listener", .timeLimit(.minutes(1)))
    func secureConnectionsNeverDowngrade() async throws {
        let server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(path: "/ws")
            )
        )
        let port = try await server.start()
        let accepted = Task { for await _ in await server.connections {} }
        defer {
            accepted.cancel()
            Task { await server.stop() }
        }

        let endpoint = WebSocketURL(isSecure: true, host: "127.0.0.1", port: port, path: "/ws")
        await #expect(throws: WebSocketDialError.self) {
            _ = try await WindowsWebSocketClient.connect(
                to: endpoint,
                options: WebSocketDialOptions(connectTimeoutSeconds: 2),
                extraRootCertificates: []
            )
        }
    }
}

#endif
