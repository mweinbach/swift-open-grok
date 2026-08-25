import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

private struct AgentRelayEchoDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(
                    ContentChunk(content: .text(TextContent(text: "relay answered")))
                )
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private final class AgentRelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var xaiCount = 0
    private var codexCount = 0
    private var browserCount = 0
    private var launches: [LiveACPLaunch] = []

    var counts: (xai: Int, codex: Int, browser: Int, launches: Int) {
        lock.withLock { (xaiCount, codexCount, browserCount, launches.count) }
    }

    var provider: String? { lock.withLock { launches.first?.options.common.provider } }

    func recordXAI() { lock.withLock { xaiCount += 1 } }
    func recordCodex() { lock.withLock { codexCount += 1 } }
    func recordBrowser() { lock.withLock { browserCount += 1 } }
    func recordLaunch(_ launch: LiveACPLaunch) { lock.withLock { launches.append(launch) } }
}

private struct AgentRelayFixture {
    let root: URL
    let home: URL
    let environment: [String: String]
    let recorder: AgentRelayRecorder
    let streams: (streams: CLIStreams, out: BufferedStream, err: BufferedStream)
    let authServices: LiveAuthServices
    let services: LiveACPServices

    init(
        replacement: GrokAuth? = nil,
        failure: (any Error & Sendable)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-agent-relay-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(root, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        #else
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        #endif
        environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_MANAGED_CONFIG": "false",
            "GROK_TEST_VERSION": "9.8.7",
        ]
        streams = CLIStreams.buffered()
        let recorder = AgentRelayRecorder()
        self.recorder = recorder
        let transport = MockHTTPTransport()
        let resolved = replacement ?? Self.account(userID: "replacement-user")
        authServices = LiveAuthServices(
            makeTransport: { transport },
            codexBrowserLogin: { _, _, _, _ in
                recorder.recordCodex()
                throw AuthError.notLoggedIn
            },
            codexDeviceLogin: { _, _, _, _ in
                recorder.recordCodex()
                throw AuthError.notLoggedIn
            },
            openBrowser: { _ in recorder.recordBrowser() },
            readSecretLine: { nil },
            isInteractive: { false },
            xaiBrowserLogin: { manager, _, _, announce in
                recorder.recordXAI()
                announce?(URL(string: "https://accounts.x.ai/authorize")!)
                if let failure { throw failure }
                try await manager.loginWithSession(resolved)
                return resolved
            }
        )
        services = LiveACPServices(makeComponents: { launch in
            recorder.recordLaunch(launch)
            return LiveACPLaunchComponents(
                promptDriver: LiveACPPromptDriver(driver: AgentRelayEchoDriver())
            )
        })
    }

    var authFile: URL { home.appendingPathComponent("auth.json") }
    var codexFile: URL { home.appendingPathComponent("codex-auth.json") }

    var context: CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: streams.streams,
            control: .never
        )
    }

    static func account(
        userID: String,
        key: String = "first-party-session",
        zdr: Bool = false,
        authMode: AuthMode = .oidc,
        issuer: String? = xaiOAuth2Issuer
    ) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: authMode,
            userID: userID,
            teamBlockedReasons: zdr ? ["BLOCKED_REASON_NO_LOGS"] : [],
            refreshToken: authMode == .oidc ? "first-party-refresh-token" : nil,
            expiresAt: Date().addingTimeInterval(3600),
            oidcIssuer: issuer,
            oidcClientID: defaultOAuth2ClientID
        )
    }

    func persist(_ account: GrokAuth, preservingOtherScope: Bool = false) throws {
        let configuration = try LiveAuthComposition.effectiveGrokComConfig(
            environment: environment
        )
        var store = [configuration.authScope: account]
        if preservingOtherScope {
            store["independent-xai-scope"] = Self.account(userID: "other-scope")
        }
        try writeAuthJSON(at: authFile, store: store)
    }

    func options(
        provider: String? = nil,
        reauthenticate: Bool = false,
        url: String? = nil,
        origin: String? = nil
    ) -> CLIExecutionOptions {
        CLIExecutionOptions(
            mode: .headless,
            common: CLICommonOptions(cwd: root.path, provider: provider),
            advanced: CLIAdvancedOptions(reauthenticate: reauthenticate),
            agentRelay: CLIAgentRelayOptions(grokWSOrigin: origin, grokWSURL: url)
        )
    }

    func start(
        _ options: CLIExecutionOptions,
        remoteSettings: RemoteSettings? = nil
    ) async throws -> CLIApplicationSession {
        try await LiveAgentRelayComposition.session(
            options: options,
            context: context,
            services: services,
            authServices: authServices,
            authDependencies: LiveLeaderAuthDependencies(makeRefresher: { _, _ in nil }),
            remoteSettings: remoteSettings
        )
    }

    func dispose() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor AgentRelayLoopback {
    private let server: WebSocketServer
    private var accepted: [WebSocketServerConnection] = []
    private var pump: Task<Void, Never>?

    init(secret: String) {
        server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(
                    path: "/ws",
                    authorize: { $0.bearerToken == secret }
                )
            )
        )
    }

    func start() async throws -> String {
        let port = try await server.start()
        let connections = await server.connections
        pump = Task { [weak self] in
            for await connection in connections {
                await self?.record(connection)
            }
        }
        return "ws://127.0.0.1:\(port)/ws"
    }

    private func record(_ connection: WebSocketServerConnection) {
        accepted.append(connection)
    }

    func firstConnection() async throws -> WebSocketServerConnection {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let connection = accepted.first { return connection }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ACPTransportError.closed
    }

    func stop() async {
        pump?.cancel()
        for connection in accepted {
            await connection.connection.close()
        }
        await server.stop()
    }
}

private func drainAgentRelay(
    _ transport: ACPWebSocketConnectionTransport,
    until predicate: (ACPMessage) -> Bool
) async throws -> ACPMessage {
    for _ in 0..<30 {
        let message = try await transport.receive()
        if predicate(message) { return message }
    }
    throw ACPTransportError.closed
}

@Suite("Persistent first-party agent relay parity", .serialized)
struct LiveAgentRelayParityTests {
    @Test("missing sessions and API keys cannot create a first-party remote agent")
    func missingAndAPIKeyAccountsFailClosed() async throws {
        let fixture = try AgentRelayFixture()
        defer { fixture.dispose() }

        do {
            let session = try await fixture.start(fixture.options())
            await session.shutdown()
            Issue.record("missing first-party session unexpectedly created a relay")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("requires a grok.com session"))
        }

        try fixture.persist(AgentRelayFixture.account(
            userID: "api-user",
            authMode: .apiKey,
            issuer: nil
        ))
        do {
            let session = try await fixture.start(fixture.options())
            await session.shutdown()
            Issue.record("API-key account unexpectedly created a relay")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("requires a grok.com session"))
        }
        #expect(fixture.recorder.counts.launches == 0)
    }

    @Test("Codex and every other explicit provider are rejected before auth or runtime creation")
    func nonFirstPartyProvidersNeverReachCredentialsOrTools() async throws {
        let fixture = try AgentRelayFixture()
        defer { fixture.dispose() }
        try fixture.persist(AgentRelayFixture.account(userID: "preserved-user"))
        let original = try Data(contentsOf: fixture.authFile)

        for provider in ["codex", "kimi", "deepseek"] {
            do {
                let session = try await fixture.start(
                    fixture.options(provider: provider, reauthenticate: true)
                )
                await session.shutdown()
                Issue.record("\(provider) unexpectedly created a first-party relay")
            } catch let error as CLIApplicationError {
                #expect(error.description.contains("first-party xAI provider"))
            }
        }

        #expect(fixture.recorder.counts.xai == 0)
        #expect(fixture.recorder.counts.codex == 0)
        #expect(fixture.recorder.counts.launches == 0)
        #expect(try Data(contentsOf: fixture.authFile) == original)
    }

    @Test("forced xAI reauthentication replaces only its account after browser success")
    func successfulReauthenticationIsScopedAndTransactional() async throws {
        let fixture = try AgentRelayFixture()
        defer { fixture.dispose() }
        try fixture.persist(
            AgentRelayFixture.account(userID: "previous-user"),
            preservingOtherScope: true
        )
        let codex = Data("independent-codex-credential".utf8)
        try codex.write(to: fixture.codexFile)

        let session = try await fixture.start(fixture.options(reauthenticate: true))
        await session.shutdown()

        let configuration = try LiveAuthComposition.effectiveGrokComConfig(
            environment: fixture.environment
        )
        let store = try readAuthJSON(at: fixture.authFile)
        #expect(store[configuration.authScope]?.userID == "replacement-user")
        #expect(store["independent-xai-scope"]?.userID == "other-scope")
        #expect(try Data(contentsOf: fixture.codexFile) == codex)
        #expect(fixture.recorder.counts.xai == 1)
        #expect(fixture.recorder.counts.codex == 0)
        #expect(fixture.recorder.counts.browser == 1)
        #expect(fixture.recorder.provider == "xai")
        #expect(fixture.streams.err.contents.contains("https://accounts.x.ai/authorize"))
    }

    @Test("failed forced login preserves the existing xAI scope and Codex bytes")
    func failedReauthenticationNeverClearsExistingAccounts() async throws {
        let fixture = try AgentRelayFixture(failure: AuthError.notLoggedIn)
        defer { fixture.dispose() }
        try fixture.persist(
            AgentRelayFixture.account(userID: "previous-user"),
            preservingOtherScope: true
        )
        let original = try Data(contentsOf: fixture.authFile)
        let codex = Data("independent-codex-credential".utf8)
        try codex.write(to: fixture.codexFile)

        do {
            let session = try await fixture.start(fixture.options(reauthenticate: true))
            await session.shutdown()
            Issue.record("failing xAI authentication unexpectedly created a relay")
        } catch AuthError.notLoggedIn {}

        #expect(try Data(contentsOf: fixture.authFile) == original)
        #expect(try Data(contentsOf: fixture.codexFile) == codex)
        #expect(fixture.recorder.counts.xai == 1)
        #expect(fixture.recorder.counts.codex == 0)
        #expect(fixture.recorder.counts.launches == 0)
    }

    @Test("managed account and zero-data-retention gates run before reauthentication")
    func accessPoliciesRemainFailClosed() async throws {
        let fixture = try AgentRelayFixture()
        defer { fixture.dispose() }
        try fixture.persist(AgentRelayFixture.account(userID: "private-user", zdr: true))
        let original = try Data(contentsOf: fixture.authFile)

        do {
            let session = try await fixture.start(fixture.options(reauthenticate: true))
            await session.shutdown()
            Issue.record("private account unexpectedly bypassed the ZDR gate")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("zero-data-retention"))
        }

        var remote = RemoteSettings()
        remote.zdrAccessEnabled = true
        remote.gateMessage = "Administrator denied access."
        do {
            let session = try await fixture.start(
                fixture.options(reauthenticate: true),
                remoteSettings: remote
            )
            await session.shutdown()
            Issue.record("remote account gate unexpectedly allowed reauthentication")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("Administrator denied access"))
        }

        #expect(fixture.recorder.counts.xai == 0)
        #expect(try Data(contentsOf: fixture.authFile) == original)
    }

    @Test("a managed team mismatch is rejected without clearing the previous account")
    func managedTeamPinRejectsExistingPrincipalBeforeMutation() async throws {
        let fixture = try AgentRelayFixture()
        defer { fixture.dispose() }
        var account = AgentRelayFixture.account(userID: "wrong-team-user")
        account.principalID = "different-team"
        account.teamID = "different-team"
        try fixture.persist(account)
        let original = try Data(contentsOf: fixture.authFile)
        try "[auth]\nforce_login_team_uuid = \"required-team\"\n".write(
            to: fixture.home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        do {
            let session = try await fixture.start(fixture.options(reauthenticate: true))
            await session.shutdown()
            Issue.record("a mismatched managed team unexpectedly started reauthentication")
        } catch let error as AuthError {
            guard case .pinnedTeamMismatch = error else {
                Issue.record("unexpected managed-account failure: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: fixture.authFile) == original)
        #expect(fixture.recorder.counts.xai == 0)
        #expect(fixture.recorder.counts.launches == 0)
    }

    @Test("invalid relay endpoints and one-shot flags fail before browser login")
    func malformedEndpointsAndSinglePromptOptionsFailClosed() async throws {
        let fixture = try AgentRelayFixture()
        defer { fixture.dispose() }
        try fixture.persist(AgentRelayFixture.account(userID: "existing-user"))

        let malformed: [CLIExecutionOptions] = [
            fixture.options(reauthenticate: true, url: "https://grok.com/ws"),
            fixture.options(reauthenticate: true, url: "ws://user@127.0.0.1/ws"),
            fixture.options(reauthenticate: true, url: "ws://relay.example/ws"),
            fixture.options(reauthenticate: true, origin: "http://relay.example"),
            fixture.options(reauthenticate: true, origin: "https://grok.com\r\nX-Evil: yes"),
        ]
        for options in malformed {
            do {
                let session = try await fixture.start(options)
                await session.shutdown()
                Issue.record("malformed relay endpoint unexpectedly passed validation")
            } catch is CLIApplicationError {}
        }

        var prompted = fixture.options(reauthenticate: true)
        prompted.prompt = "must not be ignored"
        do {
            let session = try await fixture.start(prompted)
            await session.shutdown()
            Issue.record("a one-shot prompt unexpectedly created a persistent relay")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("--prompt"))
        }
        #expect(fixture.recorder.counts.xai == 0)
        #expect(fixture.recorder.counts.launches == 0)
    }

    @Test("the real authenticated relay carries ACP initialize, session creation, and a streamed prompt", .timeLimit(.minutes(1)))
    func realSocketServesAuthenticatedACPPrompts() async throws {
        let fixture = try AgentRelayFixture()
        defer { fixture.dispose() }
        try fixture.persist(AgentRelayFixture.account(
            userID: "relay-user",
            key: "relay-session-bearer"
        ))

        let loopback = AgentRelayLoopback(secret: "relay-session-bearer")
        let endpoint = try await loopback.start()
        let session = try await fixture.start(fixture.options(
            url: endpoint,
            origin: "https://relay.example"
        ))
        let running = Task { try await session.waitForExit() }
        defer {
            running.cancel()
            Task {
                await session.shutdown()
                await loopback.stop()
            }
        }

        let connection = try await loopback.firstConnection()
        #expect(connection.request.bearerToken == "relay-session-bearer")
        #expect(connection.request.header("origin") == "https://relay.example")
        #expect(connection.request.header("x-userid") == "relay-user")
        #expect(connection.request.header("x-grok-client-version") == "9.8.7")
        #expect(connection.request.header("x-grok-client-mode") == "headless")
        #expect(connection.request.header("x-xai-token-auth") == "xai-grok-cli")

        let transport = ACPWebSocketConnectionTransport(connection: connection.connection)
        try await transport.send(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object([
                "protocolVersion": .number(.int64(1)),
                "clientCapabilities": .object([:]),
            ])
        ))
        let initialized = try await drainAgentRelay(transport) {
            if case .response(.number(1), _, _) = $0 { return true }
            return false
        }
        if case .response(_, _, let error) = initialized {
            #expect(error == nil)
        }

        try await transport.send(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: .object([
                "cwd": .string(fixture.root.path),
                "mcpServers": .array([]),
            ])
        ))
        let created = try await drainAgentRelay(transport) {
            if case .response(.number(2), _, _) = $0 { return true }
            return false
        }
        guard case .response(_, let result, nil) = created,
              case .object(let object)? = result,
              case .string(let sessionID)? = object["sessionId"]
        else {
            Issue.record("authenticated relay did not create an ACP session")
            return
        }

        try await transport.send(.request(
            id: .number(3),
            method: AgentMethodNames.sessionPrompt,
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([
                    .object(["type": .string("text"), "text": .string("hello")]),
                ]),
            ])
        ))
        let streamed = try await drainAgentRelay(transport) {
            $0.method == ClientMethodNames.sessionUpdate
        }
        #expect(streamed.method == ClientMethodNames.sessionUpdate)
        let completed = try await drainAgentRelay(transport) {
            if case .response(.number(3), _, _) = $0 { return true }
            return false
        }
        if case .response(_, let result, let error) = completed,
           case .object(let object)? = result {
            #expect(error == nil)
            #expect(object["stopReason"] == .string("end_turn"))
        } else {
            Issue.record("relayed ACP prompt did not complete successfully")
        }

        await session.shutdown()
        await loopback.stop()
        try await running.value
        #expect(fixture.recorder.provider == "xai")
        #expect(fixture.recorder.counts.codex == 0)
    }
}
