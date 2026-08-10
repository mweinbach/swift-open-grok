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
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokShared
import OpenGrokTerminalCore
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

private final class LeaderInteractiveTerminalFixture: PagerTerminalSink, @unchecked Sendable {
    let capabilities = PagerTerminalCapabilities.standard

    private let lock = NSLock()
    private var storage = Data()

    var terminal: OpenGrokLiveTerminal {
        let fixture = self
        return OpenGrokLiveTerminal(
            isTTY: { true },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 32) },
            write: { data in fixture.append(data) }
        )
    }

    var paintedText: String {
        var result = ""
        var iterator = output[...]
        while let escape = iterator.firstIndex(of: "\u{1B}") {
            result += iterator[iterator.startIndex..<escape]
            var cursor = iterator.index(after: escape)
            guard cursor < iterator.endIndex else { break }
            if iterator[cursor] == "[" || iterator[cursor] == "]" {
                let isOSC = iterator[cursor] == "]"
                cursor = iterator.index(after: cursor)
                while cursor < iterator.endIndex {
                    let scalar = iterator[cursor].unicodeScalars.first!.value
                    let isFinal = isOSC
                        ? (scalar == 0x07 || iterator[cursor] == "\\")
                        : (scalar >= 0x40 && scalar <= 0x7E)
                    cursor = iterator.index(after: cursor)
                    if isFinal { break }
                }
            } else {
                cursor = iterator.index(after: cursor)
            }
            iterator = iterator[cursor...]
        }
        result += iterator
        return result
    }

    func write(bytes: [UInt8]) throws {
        append(Data(bytes))
    }

    func flush() throws {}

    func waitForPaintedText(_ marker: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if paintedText.contains(marker) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return paintedText.contains(marker)
    }

    private var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }

    private func append(_ data: Data) {
        lock.lock()
        storage.append(data)
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
            userID: "user-1",
            refreshToken: "refresh-token",
            oidcIssuer: xaiOAuth2Issuer,
            oidcClientID: defaultOAuth2ClientID
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

    @Test("production auth dependencies install an xAI OIDC refresher")
    func productionAuthDependencies() {
        let auth = auth(key: "tok")
        let config = GrokComConfig.default(environment: [:])
        let dependencies = LiveLeaderAuthDependencies.production(
            transport: MockHTTPTransport()
        )
        #expect(dependencies.makeRefresher(auth, config) is OIDCTokenRefresher)
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

#if !os(Windows)

@Suite("Interactive leader dashboard bridge", .serialized)
struct LiveLeaderInteractiveDashboardTests {
    @Test(
        "typed roster snapshot and delta render, then selection resumes the remote cwd",
        .timeLimit(.minutes(1))
    )
    func snapshotDeltaAttachAndShutdown() async throws {
        let home = try makeShortHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pair = InMemoryWebSocketChannel.makePair()
        let client = ACPLeaderClient(channel: pair.a, clientType: "grok-tui")
        let terminal = LeaderInteractiveTerminalFixture()
        let (releaseDelta, releaseDeltaContinuation) = AsyncStream<Void>.makeStream()

        let server = Task { () throws -> ResumeSessionRequest in
            let reader = ACPLeaderChannelReader(
                channel: pair.b,
                maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
            )
            guard case .register = try await reader.next(ACPLeaderClientMessage.self) else {
                throw ACPLeaderProtocolError.connectionClosed
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.registered(
                    clientID: 21,
                    ready: true,
                    protocolVersion: ACPLeaderProtocolLimits.protocolVersion,
                    binaryVersion: "test",
                    capabilities: .supported
                )
            ))

            guard case .acp(let initializePayload) = try await reader.next(ACPLeaderClientMessage.self),
                  let initialize = try? ACPMessage(data: Data(initializePayload.utf8)),
                  case .request(let initializeID, let initializeMethod, _) = initialize,
                  initializeMethod == AgentMethodNames.initialize
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected initialize request")
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.response(
                    id: initializeID,
                    result: JSONValue.encode(InitializeResponse(protocolVersion: .v1)),
                    error: nil
                ).encodedData(), as: UTF8.self))
            ))

            guard case .acp(let rosterPayload) = try await reader.next(ACPLeaderClientMessage.self),
                  let rosterRequest = try? ACPMessage(data: Data(rosterPayload.utf8)),
                  case .request(let rosterID, let rosterMethod, _) = rosterRequest,
                  rosterMethod == ACPLeaderRosterMethods.sessionsList
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected roster snapshot request")
            }
            let idleEntry = ACPLeaderRosterEntry(
                sessionId: "remote-session",
                title: "Remote target",
                cwd: "/remote/cwd",
                isWorktree: false,
                modelId: "grok-4",
                yolo: false,
                activity: .idle,
                resident: true,
                lastChangeUnixMs: 1,
                origin: .remote(host: "other-process")
            )
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.response(
                    id: rosterID,
                    result: JSONValue.encode(ACPLeaderRosterListResponse(sessions: [idleEntry])),
                    error: nil
                ).encodedData(), as: UTF8.self))
            ))

            var releaseIterator = releaseDelta.makeAsyncIterator()
            _ = await releaseIterator.next()
            var workingEntry = idleEntry
            workingEntry.activity = .working
            workingEntry.lastChangeUnixMs = 2
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.notification(
                    method: ACPLeaderRosterMethods.sessionsChanged,
                    params: JSONValue.encode(ACPLeaderRosterChanged(upserted: [workingEntry]))
                ).encodedData(), as: UTF8.self))
            ))

            while let message = try await reader.next(ACPLeaderClientMessage.self) {
                guard case .acp(let payload) = message,
                      let request = try? ACPMessage(data: Data(payload.utf8)),
                      case .request(let requestID, let method, let params) = request,
                      method == AgentMethodNames.sessionResume
                else { continue }
                let resume = try params.decode(ResumeSessionRequest.self)
                try await pair.b.write(try ACPLeaderCodec.encode(
                    ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.response(
                        id: requestID,
                        result: JSONValue.encode(ResumeSessionResponse()),
                        error: nil
                    ).encodedData(), as: UTF8.self))
                ))
                return resume
            }
            throw ACPLeaderProtocolError.connectionClosed
        }

        let (input, inputContinuation) = AsyncThrowingStream<InputEvent, Error>.makeStream()
        let inputDriver = Task { () -> (snapshot: Bool, delta: Bool, resumed: Bool, cwd: Bool) in
            inputContinuation.yield(.key(KeyEvent(
                key: .char("\\"), modifiers: .control, character: "\\"
            )))
            let paintedDashboard = await terminal.waitForPaintedText("Agent Dashboard")
            let paintedCWD = await terminal.waitForPaintedText("/remote/cwd")
            let paintedIdle = await terminal.waitForPaintedText("idle")
            let snapshot = paintedDashboard && paintedCWD && paintedIdle
            releaseDeltaContinuation.yield(())
            let delta = await terminal.waitForPaintedText("working")
            inputContinuation.yield(.key(KeyEvent(key: .down)))
            inputContinuation.yield(.key(KeyEvent(key: .down)))
            inputContinuation.yield(.key(KeyEvent(key: .enter)))
            let resumed = await terminal.waitForPaintedText("Resumed session remote-s")
            let cwd = await terminal.waitForPaintedText("/remote/cwd")
            inputContinuation.yield(.key(KeyEvent(
                key: .char("d"), modifiers: .control, character: "d"
            )))
            inputContinuation.finish()
            return (snapshot, delta, resumed, cwd)
        }

        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                throw CLIApplicationError.failed("leader bridge test must not create a local sampler")
            },
            terminal: terminal.terminal,
            makeInteractiveInput: {
                OpenGrokLiveInteractiveInput(events: input, close: {})
            },
            makeTerminalSink: { terminal },
            makeLeaderClient: { _ in
                _ = try await client.start()
                return LiveLeaderClientLease(client: client)
            }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["interactive", "--leader", "--fullscreen"],
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.appendingPathComponent("state").path,
                "TERM": "xterm-256color",
            ],
            streams: streams,
            application: application
        )

        let observations = await inputDriver.value
        let resume = try await server.value
        releaseDeltaContinuation.finish()

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(observations.snapshot)
        #expect(observations.delta)
        #expect(observations.resumed)
        #expect(observations.cwd)
        #expect(resume.sessionId.rawValue == "remote-session")
        #expect(resume.cwd == nil)
        #expect(terminal.paintedText.contains("Agent Dashboard"))
        #expect(terminal.paintedText.contains("idle"))
        #expect(terminal.paintedText.contains("working"))
        do {
            _ = try await client.events()
            Issue.record("leader client should be closed after interactive session shutdown")
        } catch {
            // The client closes after the roster task is cancelled and joined.
        }
        await client.close()
    }
}

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
                "GROK_TEST_VERSION": "11.2.3-test",
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
        guard case .registered(
            let clientID,
            let ready,
            let version,
            let binaryVersion,
            let capabilities
        ) = registered else {
            Issue.record("expected registered, got \(registered)")
            return
        }
        #expect(clientID == 1)
        #expect(ready)
        #expect(version == ACPLeaderProtocolLimits.protocolVersion)
        #expect(binaryVersion == "11.2.3-test")
        #expect(capabilities?.controlV1 == true)
        #expect(capabilities?.workspaceExposure == true)

        try await channel.write(
            try ACPLeaderCodec.encode(
                ACPLeaderClientMessage.control(
                    requestID: "leader-info",
                    command: ["type": "get_leader_info"]
                )
            )
        )
        var receivedLeaderInfo: ACPLeaderInfo?
        for _ in 0..<20 {
            guard let message = try await reader.next(ACPLeaderServerMessage.self) else { break }
            guard case .controlResult("leader-info", .leaderInfo(let info)) = message else { continue }
            receivedLeaderInfo = info
            break
        }
        let leaderInfo = try #require(receivedLeaderInfo)
        let expectedPaths = ACPLeaderSocketPaths.resolve(
            openGrokHome: home,
            relayURL: "wss://staging.invalid/ws",
            environment: context.environment
        )
        #expect(leaderInfo.socketPath == expectedPaths.socket.path)
        #expect(leaderInfo.lockPath == expectedPaths.lock.path)
        #expect(leaderInfo.wsURLSuffix == ACPLeaderSocketPaths.suffix(forRelayURL: "wss://staging.invalid/ws"))
        #expect(leaderInfo.leaderBinaryVersion == "11.2.3-test")

        // Workspace control must survive the production composition too. The
        // test home has no credentials, so the real connector reaches its
        // typed auth-backed refusal instead of fabricating a running exposure.
        try await channel.write(
            try ACPLeaderCodec.encode(
                ACPLeaderClientMessage.control(
                    requestID: "workspace-status-before",
                    command: ["type": "workspace_status"]
                )
            )
        )
        let beforeStart = try await readControlReply(
            reader: reader,
            channel: channel,
            requestID: "workspace-status-before"
        )
        guard case .controlResult(
            "workspace-status-before",
            .workspaceStatus(let initialStatus)
        ) = beforeStart else {
            Issue.record("expected workspace_status result, got \(beforeStart)")
            return
        }
        #expect(initialStatus.state == "none")
        #expect(initialStatus.pid == leaderInfo.pid)

        try await channel.write(
            try ACPLeaderCodec.encode(
                ACPLeaderClientMessage.control(
                    requestID: "workspace-start",
                    command: [
                        "type": "workspace_start",
                        "hub_url": "wss://hub.test/ws",
                        "cwd": home.path,
                    ]
                )
            )
        )
        let startReply = try await readControlReply(
            reader: reader,
            channel: channel,
            requestID: "workspace-start"
        )
        guard case .controlError("workspace-start", let code, let message) = startReply else {
            Issue.record("expected typed workspace_start refusal, got \(startReply)")
            return
        }
        #expect(code == ACPLeaderControlErrorCode.workspaceError)
        #expect(message.contains("failed to connect workspace to hub"))

        try await channel.write(
            try ACPLeaderCodec.encode(
                ACPLeaderClientMessage.control(
                    requestID: "workspace-status-after",
                    command: ["type": "workspace_status"]
                )
            )
        )
        let afterStart = try await readControlReply(
            reader: reader,
            channel: channel,
            requestID: "workspace-status-after"
        )
        guard case .controlResult(
            "workspace-status-after",
            .workspaceStatus(let finalStatus)
        ) = afterStart else {
            Issue.record("expected post-refusal workspace_status result, got \(afterStart)")
            return
        }
        #expect(finalStatus.state == "none")
        #expect(finalStatus.pid == leaderInfo.pid)

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

    private func readControlReply(
        reader: ACPLeaderChannelReader,
        channel: any WebSocketByteChannel,
        requestID: String
    ) async throws -> ACPLeaderServerMessage {
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await channel.close()
        }
        defer { deadline.cancel() }

        while true {
            guard let message = try await reader.next(ACPLeaderServerMessage.self) else {
                throw ACPLeaderProtocolError.connectionClosed
            }
            switch message {
            case .controlResult(let replyID, _) where replyID == requestID:
                return message
            case .controlError(let replyID, _, _) where replyID == requestID:
                return message
            default:
                continue
            }
        }
    }
}

@Suite("Live leader pager runtime")
struct LiveLeaderPagerRuntimeAdapterTests {
    @Test("resume attaches the selected leader session without replacing its cwd", .timeLimit(.minutes(1)))
    func resumeSelectedSession() async throws {
        let pair = InMemoryWebSocketChannel.makePair()
        let client = ACPLeaderClient(channel: pair.a, clientType: "roster-viewer")
        let server = Task { () throws -> ResumeSessionRequest in
            let reader = ACPLeaderChannelReader(
                channel: pair.b,
                maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
            )
            guard case .register = try await reader.next(ACPLeaderClientMessage.self) else {
                throw ACPLeaderProtocolError.connectionClosed
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.registered(
                    clientID: 11,
                    ready: true,
                    protocolVersion: ACPLeaderProtocolLimits.protocolVersion,
                    binaryVersion: "test",
                    capabilities: .supported
                )
            ))

            guard case .acp(let initializePayload) = try await reader.next(ACPLeaderClientMessage.self),
                  let initialize = try? ACPMessage(data: Data(initializePayload.utf8)),
                  case .request(let initializeID, let initializeMethod, _) = initialize,
                  initializeMethod == AgentMethodNames.initialize
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected initialize request")
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.response(
                    id: initializeID,
                    result: JSONValue.encode(InitializeResponse(protocolVersion: .v1)),
                    error: nil
                ).encodedData(), as: UTF8.self))
            ))

            guard case .acp(let resumePayload) = try await reader.next(ACPLeaderClientMessage.self),
                  let resume = try? ACPMessage(data: Data(resumePayload.utf8)),
                  case .request(let resumeID, let resumeMethod, let params) = resume,
                  resumeMethod == AgentMethodNames.sessionResume
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected session/resume request")
            }
            let request = try params.decode(ResumeSessionRequest.self)
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.response(
                    id: resumeID,
                    result: JSONValue.encode(ResumeSessionResponse()),
                    error: nil
                ).encodedData(), as: UTF8.self))
            ))
            return request
        }

        _ = try await client.start()
        let runtime = LiveLeaderPagerRuntimeAdapter(
            client: client,
            workingDirectory: URL(fileURLWithPath: "/viewer")
        )
        #expect(try await runtime.resumeSession(sessionID: "remote-session") == "remote-session")

        let request = try await server.value
        #expect(request.sessionId.rawValue == "remote-session")
        #expect(request.cwd == nil)
        #expect(request.additionalDirectories.isEmpty)
        #expect(request.mcpServers.isEmpty)
        await client.close()
    }
}

@Suite("Live leader roster bridge")
struct LiveLeaderRosterBridgeTests {
    @Test("rejects a second subscriber while the snapshot is in flight", .timeLimit(.minutes(1)))
    func concurrentStart() async throws {
        let pair = InMemoryWebSocketChannel.makePair()
        let client = ACPLeaderClient(channel: pair.a, clientType: "roster-viewer")
        let (requestObserved, requestContinuation) = AsyncStream<Void>.makeStream()
        let (releaseResponse, releaseContinuation) = AsyncStream<Void>.makeStream()
        let server = Task { () throws -> Void in
            let reader = ACPLeaderChannelReader(
                channel: pair.b,
                maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
            )
            guard case .register = try await reader.next(ACPLeaderClientMessage.self) else {
                throw ACPLeaderProtocolError.connectionClosed
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.registered(
                    clientID: 10,
                    ready: true,
                    protocolVersion: ACPLeaderProtocolLimits.protocolVersion,
                    binaryVersion: "test",
                    capabilities: .supported
                )
            ))

            guard case .acp(let payload) = try await reader.next(ACPLeaderClientMessage.self),
                  let request = try? ACPMessage(data: Data(payload.utf8)),
                  case .request(let requestID, let method, _) = request,
                  method == ACPLeaderRosterMethods.sessionsList
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected roster snapshot request")
            }
            requestContinuation.yield(())
            var releaseIterator = releaseResponse.makeAsyncIterator()
            _ = await releaseIterator.next()
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.response(
                    id: requestID,
                    result: JSONValue.encode(ACPLeaderRosterListResponse(sessions: [])),
                    error: nil
                ).encodedData(), as: UTF8.self))
            ))
        }

        _ = try await client.start()
        let bridge = LiveLeaderRosterBridge(client: client)
        let first = Task { try await bridge.events() }
        var observedIterator = requestObserved.makeAsyncIterator()
        _ = await observedIterator.next()

        await #expect(throws: LiveLeaderRosterBridgeError.alreadyStarted) {
            _ = try await bridge.events()
        }

        releaseContinuation.yield(())
        _ = try await first.value
        try await server.value
        await bridge.stop()
        await client.close()
    }

    @Test("subscribes before snapshot and reconciles an in-flight delta", .timeLimit(.minutes(1)))
    func snapshotDeltaRace() async throws {
        let pair = InMemoryWebSocketChannel.makePair()
        let client = ACPLeaderClient(channel: pair.a, clientType: "roster-viewer")
        let server = Task { () throws -> Void in
            let reader = ACPLeaderChannelReader(
                channel: pair.b,
                maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
            )
            guard case .register = try await reader.next(ACPLeaderClientMessage.self) else {
                throw ACPLeaderProtocolError.connectionClosed
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.registered(
                    clientID: 9,
                    ready: true,
                    protocolVersion: ACPLeaderProtocolLimits.protocolVersion,
                    binaryVersion: "test",
                    capabilities: .supported
                )
            ))

            guard case .acp(let payload) = try await reader.next(ACPLeaderClientMessage.self),
                  let request = try? ACPMessage(data: Data(payload.utf8)),
                  case .request(let requestID, let method, _) = request,
                  method == ACPLeaderRosterMethods.sessionsList
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected roster snapshot request")
            }

            let late = ACPLeaderRosterChanged(upserted: [
                ACPLeaderRosterEntry(
                    sessionId: "late",
                    cwd: "/late",
                    isWorktree: false,
                    yolo: false,
                    activity: .working,
                    resident: true,
                    lastChangeUnixMs: 2,
                    origin: .local
                )
            ])
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.notification(
                    method: ACPLeaderRosterMethods.sessionsChanged,
                    params: JSONValue.encode(late)
                ).encodedData(), as: UTF8.self))
            ))

            let initial = ACPLeaderRosterListResponse(sessions: [
                ACPLeaderRosterEntry(
                    sessionId: "initial",
                    cwd: "/initial",
                    isWorktree: false,
                    yolo: false,
                    activity: .idle,
                    resident: true,
                    lastChangeUnixMs: 1,
                    origin: .local
                )
            ])
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(payload: String(decoding: try ACPMessage.response(
                    id: requestID,
                    result: JSONValue.encode(initial),
                    error: nil
                ).encodedData(), as: UTF8.self))
            ))
        }

        _ = try await client.start()
        let bridge = LiveLeaderRosterBridge(client: client)
        let events = try await bridge.events()
        var iterator = events.makeAsyncIterator()

        guard case .snapshot(let snapshot)? = try await iterator.next() else {
            Issue.record("expected the initial roster snapshot")
            return
        }
        #expect(snapshot.map(\.sessionId) == ["initial"])

        guard case .changed(let sessions, let delta)? = try await iterator.next() else {
            Issue.record("expected the queued roster delta")
            return
        }
        #expect(delta.upserted.map(\.sessionId) == ["late"])
        #expect(sessions.map(\.sessionId) == ["late", "initial"])

        try await server.value
        await bridge.stop()
        await client.close()
    }
}

#endif

#if os(Windows)

@Suite("Windows leader refusal")
struct LiveLeaderCompositionWindowsTests {
    @Test("leader refuses before prompt startup or endpoint creation")
    func leaderRefusesWithoutArtifacts() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-ldr-\(UUID().uuidString)")
        let environment = [
            "OPENGROK_HOME": home.path,
            "GROK_WS_URL": "wss://staging.invalid/ws",
        ]
        let paths = ACPLeaderSocketPaths.resolve(
            openGrokHome: home,
            relayURL: environment["GROK_WS_URL"],
            environment: environment
        )
        let services = LiveACPServices { _ in
            throw CLIApplicationError.failed("prompt driver should not be requested before Windows refusal")
        }

        do {
            _ = try await LiveLeaderComposition.session(
                for: .leader(CLILeaderOptions()),
                context: makeLeaderContext(
                    environment: environment,
                    recorder: LeaderStreamRecorder()
                ),
                services: services
            )
            Issue.record("expected Windows leader mode to refuse")
        } catch let error as CLIApplicationError {
            guard case .failed(let message) = error else {
                Issue.record("expected .failed, got \(error)")
                return
            }
            #expect(message.contains("unavailable on Windows"))
            #expect(message.contains(paths.lock.path))
            #expect(message.contains("named-pipe transport"))
        }

        #expect(!FileManager.default.fileExists(atPath: home.path))
        #expect(!FileManager.default.fileExists(atPath: paths.lock.path))
        #expect(!FileManager.default.fileExists(atPath: paths.socket.path))
    }
}

#endif
