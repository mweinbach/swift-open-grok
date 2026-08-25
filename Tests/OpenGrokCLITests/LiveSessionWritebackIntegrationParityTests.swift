import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private struct LiveWritebackIntegrationFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let endpoint = "http://127.0.0.1:45123"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-live-writeback-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("owner", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(root, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        try OpenGrokConfig.createDirAllOwnerOnly(workspace, stateRoot: root)
        #else
        for directory in [root, home, workspace] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        #endif
    }

    var authFile: URL { home.appendingPathComponent("auth.json") }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
            "GROK_MANAGED_CONFIG": "false",
            "GROK_SANDBOX": "off",
            "GROK_CODE_BACKEND_URL": endpoint,
            "XDG_STATE_HOME": root.appendingPathComponent("xdg-state").path,
        ]
    }

    static func account(
        token: String = "PRIVATE_FIRST_PARTY_OIDC_BEARER",
        userID: String = "writeback-owner",
        zeroDataRetention: Bool = false,
        refreshable: Bool = true,
        optedOut: Bool = true
    ) -> GrokAuth {
        GrokAuth(
            key: token,
            authMode: .oidc,
            userID: userID,
            email: "owner@example.invalid",
            teamBlockedReasons: zeroDataRetention ? ["BLOCKED_REASON_NO_LOGS"] : [],
            codingDataRetentionOptOut: optedOut,
            refreshToken: refreshable ? "PRIVATE_FIRST_PARTY_REFRESH_BEARER" : nil,
            expiresAt: Date().addingTimeInterval(3600),
            oidcIssuer: xaiOAuth2Issuer,
            oidcClientID: defaultOAuth2ClientID
        )
    }

    func persist(_ account: GrokAuth) throws {
        let configuration = try LiveAuthComposition.effectiveGrokComConfig(
            environment: environment
        )
        try writeAuthJSON(at: authFile, store: [configuration.authScope: account])
    }

    func backend(responses: Int = 20) -> MockHTTPTransport {
        MockHTTPTransport(responses: (0..<responses).map { _ in
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data("{}".utf8)
            )
        })
    }

    func run(
        sessionID: String,
        arguments: [String] = [],
        environment overrides: [String: String] = [:],
        transport: any HTTPTransport
    ) async -> (status: Int32, output: String, errors: String) {
        var selectedEnvironment = environment
        selectedEnvironment.merge(overrides) { _, override in override }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    let output = "WRITEBACK_PRIVATE_ASSISTANT"
                    await emit(.output(output))
                    return OpenGrokLiveSamplingResponse(output: output)
                }
            },
            makeImageTransport: { transport }
        )
        let (streams, output, errors) = CLIStreams.buffered()
        let status = await CLIRunner.run(
            [
                "headless",
                "--prompt", "WRITEBACK_PRIVATE_USER_PROMPT",
                "--cwd", workspace.path,
                "--model", "grok-4.5",
                "--session-id", sessionID,
            ] + arguments,
            environment: selectedEnvironment,
            streams: streams,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )
        return (status, output.contents, errors.contents)
    }

    func seedClosedBoundary(sessionID: String) async throws {
        var record = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: workspace
        )
        record.currentModelID = "grok-4.5"
        record.currentProvider = .xai
        record.everUsedNonXAI = true
        record.items = [.user("PREVIOUSLY_FOREIGN_PRIVATE_TRANSCRIPT")]
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func dispose() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class LiveWritebackRotatingTransport: HTTPTransport, @unchecked Sendable {
    private let wrapped: MockHTTPTransport
    private let lock = NSLock()
    private var rotated = false
    private let rotate: @Sendable () throws -> Void

    init(
        wrapped: MockHTTPTransport,
        rotate: @escaping @Sendable () throws -> Void
    ) {
        self.wrapped = wrapped
        self.rotate = rotate
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await wrapped.send(request)
        let shouldRotate = lock.withLock {
            guard !rotated else { return false }
            rotated = true
            return true
        }
        if shouldRotate {
            try rotate()
        }
        return response
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        wrapped.stream(request)
    }
}

private func liveWritebackJSONObject(_ request: HTTPRequest) throws -> [String: Any] {
    let body = try #require(request.body)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Suite("Live headless session writeback integration parity", .serialized)
struct LiveSessionWritebackIntegrationParityTests {
    @Test("the real headless launch writes durable ACP updates and metadata to its first-party backend")
    func explicitWritebackLaunchUploadsDurableConversation() async throws {
        let fixture = try LiveWritebackIntegrationFixture()
        defer { fixture.dispose() }
        try fixture.persist(LiveWritebackIntegrationFixture.account())
        let backend = fixture.backend()
        let sessionID = "writeback-explicit-live-session"

        let outcome = await fixture.run(
            sessionID: sessionID,
            arguments: [
                "--storage-mode", "writeback",
                "--client-identifier", "writeback-parity-client",
            ],
            environment: ["GROK_STORAGE_MODE": "local"],
            transport: backend
        )

        #expect(outcome.status == CLIRunner.ExitCode.success.rawValue)
        #expect(outcome.output.contains("WRITEBACK_PRIVATE_ASSISTANT"))
        let requests = backend.recordedRequests
        let data = try #require(requests.first { $0.method == .post })
        let metadata = try #require(requests.first { $0.method == .put })
        #expect(data.url.absoluteString
            == "\(fixture.endpoint)/sessions/\(sessionID)/data")
        #expect(metadata.url.absoluteString
            == "\(fixture.endpoint)/sessions/\(sessionID)")

        for request in requests {
            #expect(request.url.host == "127.0.0.1")
            #expect(request.headers["Authorization"]
                == "Bearer PRIVATE_FIRST_PARTY_OIDC_BEARER")
            #expect(request.headers["X-XAI-Token-Auth"] == "xai-grok-cli")
            #expect(request.headers["x-userid"] == "writeback-owner")
            #expect(request.headers["x-email"] == "owner@example.invalid")
            #expect(request.headers["x-grok-client-identifier"] == "writeback-parity-client")
            #expect(request.headers["x-grok-client-mode"] == "headless")
        }

        let dataBody = try liveWritebackJSONObject(data)
        let messages = try #require(dataBody["messages"] as? [[String: Any]])
        #expect(!messages.isEmpty)
        let content = messages.compactMap { $0["content"] as? String }
        #expect(content.contains { $0.contains("WRITEBACK_PRIVATE_USER_PROMPT") })
        #expect(content.contains { $0.contains("WRITEBACK_PRIVATE_ASSISTANT") })
        for raw in content {
            let rawBytes = try #require(raw.data(using: .utf8))
            let envelope = try #require(
                JSONSerialization.jsonObject(with: rawBytes) as? [String: Any]
            )
            let params = try #require(envelope["params"] as? [String: Any])
            #expect(envelope["method"] as? String == "session/update")
            #expect(params["sessionId"] as? String == sessionID)
            #expect(params["update"] as? [String: Any] != nil)
        }

        let metadataBody = try liveWritebackJSONObject(metadata)
        let session = try #require(metadataBody["session"] as? [String: Any])
        let persisted = try #require(session["metadata"] as? [String: Any])
        #expect(session["status"] as? String == "active")
        #expect(session["cwd"] as? String == fixture.workspace.path)
        #expect(persisted["cwd"] as? String == fixture.workspace.path)
        #expect(persisted["model_id"] as? String == "grok-4.5")
        #expect((metadataBody["agentId"] as? String)?.isEmpty == false)
    }

    @Test("environment writeback is live while explicit local mode takes precedence")
    func environmentModeAndExplicitLocalPrecedence() async throws {
        let fixture = try LiveWritebackIntegrationFixture()
        defer { fixture.dispose() }
        try fixture.persist(LiveWritebackIntegrationFixture.account())

        let enabledTransport = fixture.backend()
        let enabled = await fixture.run(
            sessionID: "writeback-from-environment",
            environment: ["GROK_STORAGE_MODE": "writeback"],
            transport: enabledTransport
        )
        #expect(enabled.status == CLIRunner.ExitCode.success.rawValue)
        #expect(enabledTransport.recordedRequests.contains { $0.method == .post })
        #expect(enabledTransport.recordedRequests.contains { $0.method == .put })

        let explicitlyLocal = fixture.backend()
        let disabled = await fixture.run(
            sessionID: "writeback-explicit-local-wins",
            arguments: ["--storage-mode", "local"],
            environment: ["GROK_STORAGE_MODE": "writeback"],
            transport: explicitlyLocal
        )
        #expect(disabled.status == CLIRunner.ExitCode.success.rawValue)
        #expect(explicitlyLocal.recordedRequests.isEmpty)

        let defaultLocal = fixture.backend()
        let defaultOutcome = await fixture.run(
            sessionID: "writeback-default-local",
            transport: defaultLocal
        )
        #expect(defaultOutcome.status == CLIRunner.ExitCode.success.rawValue)
        #expect(defaultLocal.recordedRequests.isEmpty)
    }

    @Test("invalid CLI and environment storage modes fail without transmitting a transcript")
    func invalidStorageModesNeverCreateRemoteRequests() async throws {
        let fixture = try LiveWritebackIntegrationFixture()
        defer { fixture.dispose() }
        try fixture.persist(LiveWritebackIntegrationFixture.account())

        let invalidCLI = fixture.backend()
        let cliOutcome = await fixture.run(
            sessionID: "writeback-invalid-cli-mode",
            arguments: ["--storage-mode", "remote"],
            transport: invalidCLI
        )
        #expect(cliOutcome.status != CLIRunner.ExitCode.success.rawValue)
        #expect(invalidCLI.recordedRequests.isEmpty)

        let invalidEnvironment = fixture.backend()
        let environmentOutcome = await fixture.run(
            sessionID: "writeback-invalid-env-mode",
            environment: ["GROK_STORAGE_MODE": "remote"],
            transport: invalidEnvironment
        )
        #expect(environmentOutcome.status != CLIRunner.ExitCode.success.rawValue)
        #expect(invalidEnvironment.recordedRequests.isEmpty)
    }

    @Test("API keys, non-refreshable sessions, Codex routes, and ZDR accounts cannot export")
    func unauthorizedAccountsAndProvidersNeverExport() async throws {
        let apiKeyFixture = try LiveWritebackIntegrationFixture()
        defer { apiKeyFixture.dispose() }
        try apiKeyFixture.persist(LiveWritebackIntegrationFixture.account())
        let apiKeyTransport = apiKeyFixture.backend()
        let apiKey = await apiKeyFixture.run(
            sessionID: "writeback-api-key-denied",
            arguments: ["--storage-mode", "writeback"],
            environment: ["XAI_API_KEY": "PRIVATE_XAI_API_KEY_ONLY"],
            transport: apiKeyTransport
        )
        #expect(apiKey.status != CLIRunner.ExitCode.success.rawValue)
        #expect(apiKeyTransport.recordedRequests.isEmpty)

        let legacyFixture = try LiveWritebackIntegrationFixture()
        defer { legacyFixture.dispose() }
        try legacyFixture.persist(LiveWritebackIntegrationFixture.account(refreshable: false))
        let legacyTransport = legacyFixture.backend()
        let legacy = await legacyFixture.run(
            sessionID: "writeback-unrefreshable-denied",
            arguments: ["--storage-mode", "writeback"],
            transport: legacyTransport
        )
        #expect(legacy.status != CLIRunner.ExitCode.success.rawValue)
        #expect(legacyTransport.recordedRequests.isEmpty)

        let codexFixture = try LiveWritebackIntegrationFixture()
        defer { codexFixture.dispose() }
        try codexFixture.persist(LiveWritebackIntegrationFixture.account())
        let codexTransport = codexFixture.backend()
        let codex = await codexFixture.run(
            sessionID: "writeback-codex-denied",
            arguments: [
                "--storage-mode", "writeback",
                "--provider", "codex",
                "--model", "gpt-5.4",
            ],
            environment: ["OPENAI_API_KEY": "PRIVATE_CODEX_API_KEY"],
            transport: codexTransport
        )
        #expect(codex.status != CLIRunner.ExitCode.success.rawValue)
        #expect(codexTransport.recordedRequests.isEmpty)

        let privateFixture = try LiveWritebackIntegrationFixture()
        defer { privateFixture.dispose() }
        try privateFixture.persist(LiveWritebackIntegrationFixture.account(
            zeroDataRetention: true
        ))
        let privateTransport = privateFixture.backend()
        let privateAccount = await privateFixture.run(
            sessionID: "writeback-zdr-denied",
            arguments: ["--storage-mode", "writeback"],
            transport: privateTransport
        )
        #expect(privateAccount.status != CLIRunner.ExitCode.success.rawValue)
        #expect(privateTransport.recordedRequests.isEmpty)
    }

    @Test("a previously closed durable provider boundary stays closed after returning to xAI")
    func previouslyForeignConversationCannotResumeRemoteExport() async throws {
        let fixture = try LiveWritebackIntegrationFixture()
        defer { fixture.dispose() }
        try fixture.persist(LiveWritebackIntegrationFixture.account())
        let sessionID = "writeback-permanently-closed-boundary"
        try await fixture.seedClosedBoundary(sessionID: sessionID)
        let backend = fixture.backend()

        let outcome = await fixture.run(
            sessionID: sessionID,
            arguments: ["--storage-mode", "writeback", "--provider", "xai"],
            transport: backend
        )

        #expect(outcome.status != CLIRunner.ExitCode.success.rawValue)
        #expect(backend.recordedRequests.isEmpty)
        let persisted = try #require(try await LiveConversationStore(
            openGrokHome: fixture.home
        ).loadIfPresent(sessionID: sessionID))
        #expect(persisted.everUsedNonXAI == true)
    }

    @Test("real owner-scoped writeback excludes durable Code Mode wrappers while retaining same-name plugin tools")
    func durableCodeModeTransportSecretsNeverReachBackend() async throws {
        let fixture = try LiveWritebackIntegrationFixture()
        defer { fixture.dispose() }
        try fixture.persist(LiveWritebackIntegrationFixture.account())
        let backend = fixture.backend()
        let sessionID = "writeback-code-mode-privacy"
        let command = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "unused foundation prompt",
            "--cwd", fixture.workspace.path,
            "--model", "grok-4.5",
            "--session-id", sessionID,
            "--storage-mode", "writeback",
        ], environment: fixture.environment)
        guard case .launch(let options) = command else {
            Issue.record("the writeback privacy fixture did not parse a launch")
            return
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "unused")
                }
            },
            makeImageTransport: { backend }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: CLIApplicationContext(
                environment: fixture.environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            ),
            dependencies: dependencies
        )

        let history = foundation.conversationHistory
        await history.recordCodeModeTransportCallIDs(["private-code-mode-wrapper"])
        try await history.commit(
            sessionID: sessionID,
            items: [
                .user("VISIBLE_SAFE_USER_PROMPT"),
                .assistant(AssistantItem(content: "", toolCalls: [
                    ToolCall(
                        id: "private-code-mode-wrapper",
                        name: "exec",
                        arguments: #"{"source":"NEVER_UPLOAD_CODE_MODE_SOURCE"}"#
                    ),
                    ToolCall(
                        id: "visible-plugin-exec",
                        name: "exec",
                        arguments: #"{"command":"VISIBLE_PLUGIN_COMMAND"}"#
                    ),
                ])),
                .toolResult(ToolResultItem(
                    toolCallId: "private-code-mode-wrapper",
                    content: "NEVER_UPLOAD_CODE_MODE_RESULT"
                )),
                .toolResult(ToolResultItem(
                    toolCallId: "visible-plugin-exec",
                    content: "VISIBLE_PLUGIN_RESULT"
                )),
                .assistant(AssistantItem(content: "VISIBLE_SAFE_ASSISTANT")),
            ]
        )
        await history.endEventTurn(outcome: .completed)
        await history.shutdownWriteback()
        await foundation.toolExecutor.shutdown()

        let uploads = backend.recordedRequests.filter { $0.method == .post }
        #expect(!uploads.isEmpty)
        let encoded = uploads.compactMap { request in
            request.body.map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n")
        #expect(encoded.contains("VISIBLE_SAFE_USER_PROMPT"))
        #expect(encoded.contains("VISIBLE_SAFE_ASSISTANT"))
        #expect(encoded.contains("VISIBLE_PLUGIN_COMMAND"))
        #expect(encoded.contains("VISIBLE_PLUGIN_RESULT"))
        #expect(!encoded.contains("NEVER_UPLOAD_CODE_MODE_SOURCE"))
        #expect(!encoded.contains("NEVER_UPLOAD_CODE_MODE_RESULT"))
        #expect(!encoded.contains("private-code-mode-wrapper"))

        let persisted = try #require(try await LiveConversationStore(
            openGrokHome: fixture.home
        ).loadIfPresent(sessionID: sessionID))
        #expect(persisted.codeModeTransportCallIDs == ["private-code-mode-wrapper"])
        #expect(persisted.items.count == 5)
    }

    @Test("unsafe backend origins fail before bearer or transcript transmission")
    func remoteHTTPAndForeignHTTPSOriginsAreRejected() async throws {
        let fixture = try LiveWritebackIntegrationFixture()
        defer { fixture.dispose() }
        try fixture.persist(LiveWritebackIntegrationFixture.account())

        for (index, endpoint) in [
            "http://attacker.example",
            "https://attacker.example",
            "http://127.0.0.1@attacker.example",
            "http://localhost:45123",
        ].enumerated() {
            let backend = fixture.backend()
            let outcome = await fixture.run(
                sessionID: "writeback-unsafe-origin-\(index)",
                arguments: ["--storage-mode", "writeback"],
                environment: ["GROK_CODE_BACKEND_URL": endpoint],
                transport: backend
            )
            #expect(outcome.status != CLIRunner.ExitCode.success.rawValue)
            #expect(backend.recordedRequests.isEmpty)
        }
    }

    @Test("same-account credential rotation is picked up between durable POST and metadata PUT")
    func sameAccountTokenRotationUsesFreshBearer() async throws {
        let fixture = try LiveWritebackIntegrationFixture()
        defer { fixture.dispose() }
        try fixture.persist(LiveWritebackIntegrationFixture.account(
            token: "PRIVATE_INITIAL_FIRST_PARTY_BEARER"
        ))
        let backend = fixture.backend()
        let home = fixture.home
        let environment = fixture.environment
        let rotating = LiveWritebackRotatingTransport(wrapped: backend) {
            let configuration = try LiveAuthComposition.effectiveGrokComConfig(
                environment: environment
            )
            try writeAuthJSON(
                at: home.appendingPathComponent("auth.json"),
                store: [configuration.authScope: LiveWritebackIntegrationFixture.account(
                    token: "PRIVATE_ROTATED_FIRST_PARTY_BEARER"
                )]
            )
        }

        let outcome = await fixture.run(
            sessionID: "writeback-same-account-rotation",
            arguments: ["--storage-mode", "writeback"],
            transport: rotating
        )

        #expect(outcome.status == CLIRunner.ExitCode.success.rawValue)
        let requests = backend.recordedRequests
        let first = try #require(requests.first)
        #expect(first.method == .post)
        #expect(first.headers["Authorization"]
            == "Bearer PRIVATE_INITIAL_FIRST_PARTY_BEARER")
        let metadata = try #require(requests.first { $0.method == .put })
        #expect(metadata.headers["Authorization"]
            == "Bearer PRIVATE_ROTATED_FIRST_PARTY_BEARER")
    }

    @Test("switching xAI account between requests prevents metadata or transcript leakage")
    func accountSwitchPermanentlyStopsFurtherRequests() async throws {
        let fixture = try LiveWritebackIntegrationFixture()
        defer { fixture.dispose() }
        try fixture.persist(LiveWritebackIntegrationFixture.account(
            token: "PRIVATE_ORIGINAL_ACCOUNT_BEARER",
            userID: "original-account"
        ))
        let backend = fixture.backend()
        let home = fixture.home
        let environment = fixture.environment
        let rotating = LiveWritebackRotatingTransport(wrapped: backend) {
            let configuration = try LiveAuthComposition.effectiveGrokComConfig(
                environment: environment
            )
            try writeAuthJSON(
                at: home.appendingPathComponent("auth.json"),
                store: [configuration.authScope: LiveWritebackIntegrationFixture.account(
                    token: "PRIVATE_DIFFERENT_ACCOUNT_BEARER",
                    userID: "different-account"
                )]
            )
        }

        let outcome = await fixture.run(
            sessionID: "writeback-account-switch-denied",
            arguments: ["--storage-mode", "writeback"],
            transport: rotating
        )

        #expect(outcome.status == CLIRunner.ExitCode.success.rawValue)
        let requests = backend.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.method == .post)
        #expect(requests.first?.headers["Authorization"]
            == "Bearer PRIVATE_ORIGINAL_ACCOUNT_BEARER")
        #expect(!requests.contains {
            $0.headers["Authorization"] == "Bearer PRIVATE_DIFFERENT_ACCOUNT_BEARER"
        })
    }
}
