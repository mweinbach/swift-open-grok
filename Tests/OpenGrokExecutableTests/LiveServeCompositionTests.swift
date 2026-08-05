// LiveServeCompositionTests.swift
//
// The `serve` CLI route. The argument-shaped pieces (bind parsing, secret
// precedence, banner) are tested directly; the route as a whole is tested by
// binding a real ephemeral loopback port and connecting a real WebSocket
// client to it, because "the server starts" and "an ACP client can talk to it"
// are different claims.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokCLI

// MARK: - Harness

/// Answers every prompt with one chunk and an end-of-turn.
private struct ServeStubPromptDriver: ACPPromptDriver {
    let reply: String

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: reply))))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

/// Collects whatever the composition writes to stderr.
private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined()
    }

    func append(_ value: String) {
        lock.lock()
        lines.append(value)
        lock.unlock()
    }
}

private func makeContext(
    environment: [String: String] = [:],
    recorder: StreamRecorder
) -> CLIApplicationContext {
    CLIApplicationContext(
        environment: environment,
        streams: CLIStreams(out: { _ in }, err: { recorder.append($0) }),
        control: CLIExecutionControl(isCancelled: { false }, waitForCancellation: {})
    )
}

private func serveServices(reply: String = "ack") -> LiveACPServices {
    LiveACPServices { _ in
        LiveACPPromptDriver(driver: ServeStubPromptDriver(reply: reply))
    }
}

/// Pull the bound port out of the startup banner.
///
/// Reading it back from the banner rather than from an internal handle is
/// deliberate: it checks that the banner reports the port actually bound, not
/// the `0` that was requested.
private func portFromBanner(_ banner: String) throws -> UInt16 {
    guard let range = banner.range(of: "Address:  127.0.0.1:") else {
        throw CLIApplicationError.failed("no address line in banner:\n\(banner)")
    }
    let rest = banner[range.upperBound...].prefix { $0.isNumber }
    guard let port = UInt16(rest), port != 0 else {
        throw CLIApplicationError.failed("no bound port in banner:\n\(banner)")
    }
    return port
}

private func acpInitialize(id: Int64) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.initialize,
        params: .object([
            "protocolVersion": .number(.int64(1)),
            "clientCapabilities": .object([:]),
        ])
    )
}

// MARK: - Routing

@Suite("Live serve composition routing")
struct LiveServeCompositionRoutingTests {
    @Test func claimsServeAndLeaderOnly() {
        #expect(LiveServeComposition.handles(.serve(CLIServeOptions())))
        #expect(LiveServeComposition.handles(.leader(CLILeaderOptions())))
        #expect(!LiveServeComposition.handles(.launch(CLIExecutionOptions(mode: .acp))))
        #expect(!LiveServeComposition.handles(.version(json: false)))
    }

    @Test func leaderRefusesWithTheMissingPieceNamed() async {
        let recorder = StreamRecorder()
        await #expect(throws: CLIApplicationError.self) {
            _ = try await LiveServeComposition.session(
                for: .leader(CLILeaderOptions()),
                context: makeContext(recorder: recorder)
            )
        }
        let message = LiveServeComposition.leaderUnsupported(CLILeaderOptions()).description
        // The refusal has to name the actual gap. A vague "not supported"
        // sends the next person looking in the wrong place — especially now
        // that `serve` works and the two routes look adjacent.
        #expect(message.contains("leader.sock"))
        #expect(message.contains("4-byte big-endian length prefix"))
        #expect(message.contains("Register/Acp/Control/Ping/Disconnect"))
        #expect(message.contains("`serve` is a different protocol"))
        #expect(message.contains("open-grok acp"))
    }
}

// MARK: - Arguments

@Suite("Live serve bind parsing")
struct LiveServeBindTests {
    @Test func parsesHostAndPort() throws {
        let parsed = try LiveServeComposition.parseBind("127.0.0.1:2419")
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.port == 2419)
    }

    @Test func parsesTheUpstreamDefault() throws {
        // `CLIServeOptions.bind` already defaults to upstream's value
        // (`cli.rs:337`); this pins that the default survives parsing.
        let parsed = try LiveServeComposition.parseBind(CLIServeOptions().bind)
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.port == 2419)
    }

    @Test func parsesABracketedIPv6Literal() throws {
        let parsed = try LiveServeComposition.parseBind("[::1]:9000")
        #expect(parsed.host == "::1")
        #expect(parsed.port == 9000)
    }

    @Test func acceptsPortZeroForAnEphemeralBind() throws {
        #expect(try LiveServeComposition.parseBind("127.0.0.1:0").port == 0)
    }

    @Test func rejectsMalformedAddresses() {
        for value in ["127.0.0.1", "127.0.0.1:", ":2419", "127.0.0.1:70000", "127.0.0.1:abc"] {
            #expect(throws: CLIApplicationError.self, "accepted \(value)") {
                _ = try LiveServeComposition.parseBind(value)
            }
        }
    }

    @Test func recognizesLoopbackHosts() {
        #expect(LiveServeComposition.isLoopback("127.0.0.1"))
        #expect(LiveServeComposition.isLoopback("localhost"))
        #expect(LiveServeComposition.isLoopback("::1"))
        #expect(LiveServeComposition.isLoopback("127.0.0.53"))
        #expect(!LiveServeComposition.isLoopback("0.0.0.0"))
        #expect(!LiveServeComposition.isLoopback("192.168.1.10"))
    }
}

@Suite("Live serve secret resolution")
struct LiveServeSecretTests {
    @Test func prefersTheFlag() {
        let resolved = LiveServeComposition.resolveSecret(
            options: CLIServeOptions(secret: "from-flag"),
            environment: ["GROK_AGENT_SECRET": "from-env"],
            generate: { "generated" }
        )
        #expect(resolved.value == "from-flag")
        #expect(resolved.source == .flag)
    }

    @Test func fallsBackToTheEnvironmentVariable() {
        // `cli.rs:340` reads exactly this variable.
        let resolved = LiveServeComposition.resolveSecret(
            options: CLIServeOptions(),
            environment: ["GROK_AGENT_SECRET": "from-env"],
            generate: { "generated" }
        )
        #expect(resolved.value == "from-env")
        #expect(resolved.source == .environment)
    }

    @Test func generatesWhenNothingIsSupplied() {
        // Never "no secret". Upstream always has one, so this port must too —
        // falling through to an unauthenticated socket would open a surface
        // upstream never opens.
        let resolved = LiveServeComposition.resolveSecret(
            options: CLIServeOptions(),
            environment: [:],
            generate: { "generated" }
        )
        #expect(resolved.value == "generated")
        #expect(resolved.source == .generated)
    }

    @Test func treatsAnEmptyValueAsAbsent() {
        let resolved = LiveServeComposition.resolveSecret(
            options: CLIServeOptions(secret: ""),
            environment: ["GROK_AGENT_SECRET": ""],
            generate: { "generated" }
        )
        #expect(resolved.source == .generated)
    }

    @Test func generatesA12CharacterAlphanumericKey() {
        // `generate_random_key(12)` (`cli.rs:364-367`).
        let keys = (0..<20).map { _ in LiveServeComposition.generateKey() }
        for key in keys {
            #expect(key.count == 12)
            #expect(key.allSatisfy { $0.isHexDigit })
        }
        #expect(Set(keys).count == keys.count)
    }
}

@Suite("Live serve banner")
struct LiveServeBannerTests {
    @Test func matchesTheUpstreamLayout() {
        // `print_serve_startup_info` (`main.rs:89-102`).
        let banner = LiveServeComposition.startupBanner(
            endpoint: ACPServeEndpoint(host: "127.0.0.1", port: 2419, path: "/ws"),
            secret: "abc123"
        )
        #expect(banner == """

               Open Grok agent server starting...

               Address:  127.0.0.1:2419
               Secret:   abc123

               WebSocket URL: ws://127.0.0.1:2419/ws?server-key=abc123


            """)
    }
}

// MARK: - End to end

@Suite("Live serve composition end to end", .serialized)
struct LiveServeCompositionLiveTests {
    /// Bring the route up on an ephemeral port and hand back the banner.
    private func startServe(
        options: CLIServeOptions,
        environment: [String: String] = [:],
        recorder: StreamRecorder
    ) async throws -> (session: CLIApplicationSession, port: UInt16, served: Task<Void, Never>) {
        let session = try await LiveServeComposition.session(
            for: .serve(options),
            context: makeContext(environment: environment, recorder: recorder),
            services: serveServices()
        )
        // `_ =` discards the `Void?` that `try?` produces, so the closure
        // returns `Void` outright rather than relying on the compiler to drop
        // it for us.
        let served = Task<Void, Never> { _ = try? await session.waitForExit() }
        let port = try portFromBanner(recorder.text)
        return (session, port, served)
    }

    @Test("an ACP client over ws:// gets the same session surface as stdio")
    func liveClientCanInitializeAndPrompt() async throws {
        let recorder = StreamRecorder()
        let started = try await startServe(
            options: CLIServeOptions(bind: "127.0.0.1:0", secret: "route-secret"),
            recorder: recorder
        )
        defer {
            started.served.cancel()
            Task { await started.session.shutdown() }
        }

        let channel = try await WebSocketNetworkChannel.connect(host: "127.0.0.1", port: started.port)
        let connection = try await WebSocketClientUpgrade.connect(
            channel: channel,
            host: "127.0.0.1:\(started.port)",
            target: "/ws?server-key=route-secret"
        )
        let client = ACPWebSocketConnectionTransport(connection: connection)

        try await client.send(acpInitialize(id: 1))
        let initialized = try await client.receive()
        guard case .response(let id, _, let error) = initialized else {
            Issue.record("expected an initialize response, got \(initialized)")
            return
        }
        #expect(id == .number(1))
        #expect(error == nil)

        try await client.send(
            .request(
                id: .number(2),
                method: AgentMethodNames.sessionNew,
                params: .object([
                    "cwd": .string(FileManager.default.currentDirectoryPath),
                    "mcpServers": .array([]),
                ])
            )
        )
        let created = try await client.receive()
        guard case .response(_, .object(let object)?, _) = created,
              case .string(let sessionId)? = object["sessionId"]
        else {
            Issue.record("expected a sessionId, got \(created)")
            return
        }

        try await client.send(
            .request(
                id: .number(3),
                method: AgentMethodNames.sessionPrompt,
                params: .object([
                    "sessionId": .string(sessionId),
                    "prompt": .array([.object([
                        "type": .string("text"),
                        "text": .string("hello"),
                    ])]),
                ])
            )
        )
        var sawChunk = false
        for _ in 0..<40 {
            let message = try await client.receive()
            if message.method == ClientMethodNames.sessionUpdate { sawChunk = true }
            if message.id == .number(3) { break }
        }
        // The prompt driver the composition injected is the one that answered,
        // which is what proves the route reached the real stack rather than a
        // stub that accepts connections.
        #expect(sawChunk)
        await client.close()
    }

    @Test("the banner names the bound port and the pasteable URL")
    func liveBannerReportsTheRealEndpoint() async throws {
        let recorder = StreamRecorder()
        let started = try await startServe(
            options: CLIServeOptions(bind: "127.0.0.1:0", secret: "banner-secret"),
            recorder: recorder
        )
        defer {
            started.served.cancel()
            Task { await started.session.shutdown() }
        }
        let banner = recorder.text
        #expect(banner.contains("Open Grok agent server starting..."))
        #expect(banner.contains("Secret:   banner-secret"))
        #expect(banner.contains("ws://127.0.0.1:\(started.port)/ws?server-key=banner-secret"))
        #expect(!banner.contains(":0/ws"))
    }

    @Test("a client without the secret is refused")
    func liveRefusesAnUnauthenticatedClient() async throws {
        let recorder = StreamRecorder()
        let started = try await startServe(
            options: CLIServeOptions(bind: "127.0.0.1:0", secret: "route-secret"),
            recorder: recorder
        )
        defer {
            started.served.cancel()
            Task { await started.session.shutdown() }
        }

        let channel = try await WebSocketNetworkChannel.connect(host: "127.0.0.1", port: started.port)
        do {
            _ = try await WebSocketClientUpgrade.connect(
                channel: channel,
                host: "127.0.0.1:\(started.port)",
                target: "/ws"
            )
            Issue.record("serve must never accept an unauthenticated client")
        } catch let error as WebSocketChannelError {
            guard case .handshakeRejected(let status, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(status == 401)
        }
    }

    @Test("the secret comes from the environment when no flag is given")
    func liveUsesTheEnvironmentSecret() async throws {
        let recorder = StreamRecorder()
        let started = try await startServe(
            options: CLIServeOptions(bind: "127.0.0.1:0"),
            environment: ["GROK_AGENT_SECRET": "env-secret"],
            recorder: recorder
        )
        defer {
            started.served.cancel()
            Task { await started.session.shutdown() }
        }

        let channel = try await WebSocketNetworkChannel.connect(host: "127.0.0.1", port: started.port)
        let connection = try await WebSocketClientUpgrade.connect(
            channel: channel,
            host: "127.0.0.1:\(started.port)",
            target: "/ws",
            headers: [("Authorization", "Bearer env-secret")]
        )
        let client = ACPWebSocketConnectionTransport(connection: connection)
        try await client.send(acpInitialize(id: 1))
        #expect(try await client.receive().id == .number(1))
        await client.close()
    }

    @Test("a generated secret is printed so the operator can use it")
    func liveGeneratedSecretIsUsable() async throws {
        let recorder = StreamRecorder()
        let started = try await startServe(
            options: CLIServeOptions(bind: "127.0.0.1:0"),
            recorder: recorder
        )
        defer {
            started.served.cancel()
            Task { await started.session.shutdown() }
        }

        // A generated secret that is not reported would make the server
        // unusable, so this reads it back out of the banner and connects.
        let banner = recorder.text
        guard let range = banner.range(of: "Secret:   ") else {
            Issue.record("banner has no secret line:\n\(banner)")
            return
        }
        let secret = String(banner[range.upperBound...].prefix { !$0.isNewline })
        #expect(secret.count == 12)

        let channel = try await WebSocketNetworkChannel.connect(host: "127.0.0.1", port: started.port)
        let connection = try await WebSocketClientUpgrade.connect(
            channel: channel,
            host: "127.0.0.1:\(started.port)",
            target: "/ws?server-key=\(secret)"
        )
        let client = ACPWebSocketConnectionTransport(connection: connection)
        try await client.send(acpInitialize(id: 1))
        #expect(try await client.receive().id == .number(1))
        await client.close()
    }

    @Test("--remote is accepted but reported as having no effect")
    func liveWarnsAboutRemote() async throws {
        let recorder = StreamRecorder()
        let started = try await startServe(
            options: CLIServeOptions(bind: "127.0.0.1:0", secret: "s", remote: "ws://elsewhere/ws"),
            recorder: recorder
        )
        defer {
            started.served.cancel()
            Task { await started.session.shutdown() }
        }
        #expect(recorder.text.contains("`serve --remote` is accepted for compatibility but has no effect"))
    }
}
