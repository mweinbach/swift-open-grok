// LiveLeaderCompositionTests.swift
//
// The `leader` CLI route: routing, endpoint and eagerness resolution, the
// relay-eligibility gate, and a live run that binds a real Unix socket and
// drives a real IPC client through it.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokCLI

// MARK: - Harness

private struct LeaderStubPromptDriver: ACPPromptDriver {
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

private final class LeaderStreamRecorder: @unchecked Sendable {
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

private func makeLeaderContext(
    environment: [String: String],
    recorder: LeaderStreamRecorder
) -> CLIApplicationContext {
    CLIApplicationContext(
        environment: environment,
        streams: CLIStreams(out: { _ in }, err: { recorder.append($0) }),
        control: CLIExecutionControl(isCancelled: { false }, waitForCancellation: {})
    )
}

private func leaderServices(reply: String = "ack") -> LiveACPServices {
    LiveACPServices { _ in
        LiveACPPromptDriver(driver: LeaderStubPromptDriver(reply: reply))
    }
}

/// A scratch directory short enough to stay inside the `sockaddr_un` limit.
///
/// `FileManager.temporaryDirectory` under a test runner can already be ~60
/// bytes, and a UUID pushes the socket path past 104 — which `bind(2)` would
/// truncate silently rather than reject.
private func makeShortHome() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp")
        .appendingPathComponent("og-ldr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Routing

@Suite("Live leader composition routing")
struct LiveLeaderCompositionRoutingTests {
    /// `.serve` stays with `LiveServeComposition`; claiming it here would make
    /// the launcher's ordering decide which implementation of `serve` runs.
    @Test func claimsLeaderOnly() {
        #expect(LiveLeaderComposition.handles(.leader(CLILeaderOptions())))
        #expect(!LiveLeaderComposition.handles(.serve(CLIServeOptions())))
        #expect(!LiveLeaderComposition.handles(.launch(CLIExecutionOptions(mode: .acp))))
    }

    @Test func nonLeaderCommandsAreUnsupported() async {
        let recorder = LeaderStreamRecorder()
        await #expect(throws: CLIApplicationError.self) {
            _ = try await LiveLeaderComposition.session(
                for: .serve(CLIServeOptions()),
                context: makeLeaderContext(environment: [:], recorder: recorder),
                services: leaderServices()
            )
        }
    }
}

// MARK: - Endpoint and eagerness

@Suite("Leader relay endpoint resolution")
struct LiveLeaderEndpointTests {
    @Test("the default endpoint is the production relay")
    func defaults() {
        let resolved = LiveLeaderComposition.resolveRelayEndpoint(
            options: CLILeaderOptions(),
            environment: [:]
        )
        #expect(resolved.url == ACPRelayConfiguration.productionURL)
        #expect(resolved.origin == ACPRelayConfiguration.productionOrigin)
    }

    @Test("the environment overrides the default")
    func environmentOverride() {
        let resolved = LiveLeaderComposition.resolveRelayEndpoint(
            options: CLILeaderOptions(),
            environment: [
                "GROK_WS_URL": "wss://staging.example/ws",
                "GROK_WS_ORIGIN": "https://staging.example",
            ]
        )
        #expect(resolved.url == "wss://staging.example/ws")
        #expect(resolved.origin == "https://staging.example")
    }

    /// A spawned leader is told which relay its parent chose via
    /// `--grok-ws-url` (`leader/mod.rs:1697-1698`); an inherited `GROK_WS_URL`
    /// must not override that or the child would join the wrong relay.
    @Test("the flag outranks the environment")
    func flagWins() {
        let resolved = LiveLeaderComposition.resolveRelayEndpoint(
            options: CLILeaderOptions(
                grokWSOrigin: "https://flag.example",
                grokWSURL: "wss://flag.example/ws"
            ),
            environment: ["GROK_WS_URL": "wss://env.example/ws"]
        )
        #expect(resolved.url == "wss://flag.example/ws")
        #expect(resolved.origin == "https://flag.example")
    }

    /// `app.rs:842-887` — eager is the default, and not merely as a preference:
    /// a bare leader has no IPC clients, so a demand-gated relay would never
    /// connect and every remote prompt would fail with "No online agents".
    @Test("the relay is eager unless --relay-on-demand is passed")
    func eagerness() {
        #expect(LiveLeaderComposition.relayIsEager(CLILeaderOptions()))
        #expect(!LiveLeaderComposition.relayIsEager(CLILeaderOptions(relayOnDemand: true)))
    }
}

@Suite("Relay eligibility")
struct LiveLeaderRelayEligibilityTests {
    private func auth(key: String) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: .oidc,
            createTime: Date(),
            userID: "user-1"
        )
    }

    /// `relay.rs:64-81` — only an x.ai OIDC session is relay-eligible. The
    /// others are excluded because the relay authenticates the bearer as a
    /// grok.com session and those tokens are not one.
    @Test("an OIDC session with a key is eligible")
    func oidcSessionIsEligible() {
        let authorization = LiveLeaderComposition.relayAuthorization(
            auth: auth(key: "tok"),
            tokenType: .oidcSession,
            tokenHeader: "xai-grok-cli"
        )
        #expect(authorization?.token == "tok")
        #expect(authorization?.userID == "user-1")
        #expect(authorization?.tokenHeader == "xai-grok-cli")
    }

    @Test("api keys, external binaries and legacy sessions are not eligible")
    func otherTokenTypesAreIneligible() {
        for type in [TokenType.apiKey, .externalBinary, .legacySession, .none] {
            #expect(
                LiveLeaderComposition.relayAuthorization(
                    auth: auth(key: "tok"),
                    tokenType: type,
                    tokenHeader: "xai-grok-cli"
                ) == nil,
                "\(type) should not be relay-eligible"
            )
        }
    }

    /// An empty key would send `Authorization: Bearer `, which reads as a
    /// malformed credential rather than as no credential.
    @Test("no auth and an empty key are both ineligible")
    func emptyCredentials() {
        #expect(
            LiveLeaderComposition.relayAuthorization(
                auth: nil,
                tokenType: .oidcSession,
                tokenHeader: "xai-grok-cli"
            ) == nil
        )
        #expect(
            LiveLeaderComposition.relayAuthorization(
                auth: auth(key: ""),
                tokenType: .oidcSession,
                tokenHeader: "xai-grok-cli"
            ) == nil
        )
    }
}

@Suite("Leader messages")
struct LiveLeaderMessageTests {
    @Test("the banner names the socket, the relay and the relay's state")
    func banner() {
        let banner = LiveLeaderComposition.startupBanner(
            socket: URL(fileURLWithPath: "/tmp/leader.sock"),
            relayURL: ACPRelayConfiguration.productionURL,
            relayState: "connecting"
        )
        #expect(banner.contains("Socket:   /tmp/leader.sock"))
        #expect(banner.contains("Relay:    wss://code.grok.com/ws/code-agent"))
        #expect(banner.contains("Status:   connecting"))
    }

    /// The refusal must say what to do instead and why it is a refusal rather
    /// than an adoption, so it cannot rot into a bare "already running".
    @Test("the already-running message names the holder and the socket")
    func alreadyRunningMessage() {
        let message = LiveLeaderComposition.leaderAlreadyRunningMessage(
            .held(byProcess: 4321, path: "/tmp/leader.lock"),
            socket: URL(fileURLWithPath: "/tmp/leader.sock")
        )
        #expect(message.contains("process 4321"))
        #expect(message.contains("/tmp/leader.lock"))
        #expect(message.contains("/tmp/leader.sock"))
        #expect(message.contains("connect-or-spawn"))
    }
}

// MARK: - Live

#if canImport(Network)

@Suite("Live leader route", .serialized)
struct LiveLeaderCompositionLiveTests {
    /// The whole route: bind a real Unix socket, dial it with a real IPC
    /// client, and drive a session. "The leader starts" and "a client can talk
    /// to it" are different claims.
    @Test("a client registers and runs a session over the leader socket", .timeLimit(.minutes(1)))
    func liveLeaderSocket() async throws {
        let home = try makeShortHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let recorder = LeaderStreamRecorder()
        let context = makeLeaderContext(
            environment: [
                "OPENGROK_HOME": home.path,
                // No credentials, so the relay parks and the test exercises the
                // IPC half without reaching the network.
                "GROK_WS_URL": "wss://staging.invalid/ws",
            ],
            recorder: recorder
        )

        let session = try await LiveLeaderComposition.session(
            for: .leader(CLILeaderOptions()),
            context: context,
            services: leaderServices()
        )
        let running = Task { try await session.waitForExit() }
        defer {
            running.cancel()
            Task { await session.shutdown() }
        }

        let banner = recorder.text
        #expect(banner.contains("Open Grok leader starting"))
        // A leader with no grok.com session must say so rather than appearing
        // connected.
        #expect(banner.contains("no grok.com session token"))

        let socketPath = try socketPath(fromBanner: banner)
        #expect(FileManager.default.fileExists(atPath: socketPath))

        let channel = try await dialUnixSocket(path: socketPath)
        let reader = ACPLeaderChannelReader(
            channel: channel,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )

        try await channel.write(
            try ACPLeaderCodec.encode(
                ACPLeaderClientMessage.register(
                    clientType: "grok-tui",
                    mode: .stdio,
                    capabilities: ACPLeaderClientCapabilities()
                )
            )
        )
        let registered = try #require(try await reader.next(ACPLeaderServerMessage.self))
        guard case .registered(let clientID, let ready, let version, _, _) = registered else {
            Issue.record("expected registered, got \(registered)")
            return
        }
        #expect(clientID == 1)
        #expect(ready)
        #expect(version == ACPLeaderProtocolLimits.protocolVersion)

        // And the socket carries real ACP, not just the envelope.
        let initialize = ACPMessage.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object([
                "protocolVersion": .number(.int64(1)),
                "clientCapabilities": .object([:]),
            ])
        )
        try await channel.write(
            try ACPLeaderCodec.encode(
                ACPLeaderClientMessage.acp(
                    payload: String(decoding: try initialize.encodedData(), as: UTF8.self)
                )
            )
        )

        var answered = false
        for _ in 0..<20 {
            guard let message = try await reader.next(ACPLeaderServerMessage.self) else { break }
            guard case .acp(let payload) = message,
                let decoded = try? ACPMessage(data: Data(payload.utf8)),
                case .response(let id, _, let error) = decoded
            else { continue }
            // The id the client sent is the id it gets back; the namespacing is
            // the leader's business, not the client's.
            #expect(id == .number(1))
            #expect(error == nil)
            answered = true
            break
        }
        #expect(answered, "the leader never answered initialize")

        await channel.close()
    }

    /// A second leader for the same endpoint must be refused, and the refusal
    /// must say where the first one is.
    @Test("a second leader on the same socket is refused", .timeLimit(.minutes(1)))
    func secondLeaderRefused() async throws {
        let home = try makeShortHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = [
            "OPENGROK_HOME": home.path,
            "GROK_WS_URL": "wss://staging.invalid/ws",
        ]
        let first = try await LiveLeaderComposition.session(
            for: .leader(CLILeaderOptions()),
            context: makeLeaderContext(environment: environment, recorder: LeaderStreamRecorder()),
            services: leaderServices()
        )
        let running = Task { try await first.waitForExit() }
        defer {
            running.cancel()
            Task { await first.shutdown() }
        }

        do {
            _ = try await LiveLeaderComposition.session(
                for: .leader(CLILeaderOptions()),
                context: makeLeaderContext(
                    environment: environment,
                    recorder: LeaderStreamRecorder()
                ),
                services: leaderServices()
            )
            Issue.record("expected the second leader to be refused")
        } catch let error as CLIApplicationError {
            guard case .failed(let message) = error else {
                Issue.record("expected .failed, got \(error)")
                return
            }
            #expect(message.contains("already running"))
            // The socket carries the relay-URL suffix (`leader-<hash>.sock`),
            // so match the extension rather than the default stem.
            #expect(message.contains(".sock"))
        }
    }

    private func socketPath(fromBanner banner: String) throws -> String {
        guard let range = banner.range(of: "Socket:   ") else {
            throw CLIApplicationError.failed("no socket line in banner:\n\(banner)")
        }
        let rest = banner[range.upperBound...].prefix { !$0.isNewline }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private func dialUnixSocket(path: String) async throws -> any WebSocketByteChannel {
        try await UnixSocketDialer.connect(path: path)
    }
}

#endif
