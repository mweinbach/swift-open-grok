import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing

@testable import OpenGrokCLI

private struct RemoteSessionHydrationFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL
    let foreignWorkspace: URL
    let endpoint = "http://127.0.0.1:46391"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-remote-hydration-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("owner", isDirectory: true)
        workspace = root.appendingPathComponent("trusted workspace", isDirectory: true)
        foreignWorkspace = root.appendingPathComponent("foreign workspace", isDirectory: true)

        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(root, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        try OpenGrokConfig.createDirAllOwnerOnly(workspace, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(foreignWorkspace, stateRoot: root)
        #else
        for directory in [root, home, workspace, foreignWorkspace] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        #endif
    }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
            "GROK_MANAGED_CONFIG": "false",
            "GROK_SANDBOX": "off",
            "GROK_CODE_BACKEND_URL": endpoint,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
        ]
    }

    var enabledEnvironment: [String: String] {
        var configured = environment
        configured["GROK_SESSION_REGISTRY"] = "true"
        return configured
    }

    func account(
        token: String = "HYDRATION_PRIVATE_FIRST_PARTY_BEARER",
        userID: String = "hydration-owner",
        principalID: String? = "hydration-principal",
        teamID: String? = "hydration-team",
        organizationID: String? = "hydration-organization",
        mode: AuthMode = .oidc,
        issuer: String? = xaiOAuth2Issuer,
        zeroDataRetention: Bool = false,
        optedOut: Bool = true,
        refreshable: Bool = true,
        expiresAt: Date = Date().addingTimeInterval(3_600)
    ) -> GrokAuth {
        GrokAuth(
            key: token,
            authMode: mode,
            userID: userID,
            email: "hydration@example.invalid",
            principalID: principalID,
            teamID: teamID,
            organizationID: organizationID,
            teamBlockedReasons: zeroDataRetention ? ["BLOCKED_REASON_NO_LOGS"] : [],
            codingDataRetentionOptOut: optedOut,
            refreshToken: mode == .oidc && refreshable ? "HYDRATION_PRIVATE_REFRESH_BEARER" : nil,
            expiresAt: expiresAt,
            oidcIssuer: issuer,
            oidcClientID: defaultOAuth2ClientID
        )
    }

    func persist(_ account: GrokAuth) throws {
        let configuration = liveManagedAuthenticationConfiguration(environment: environment)
        try writeAuthJSON(
            at: home.appendingPathComponent("auth.json"),
            store: [configuration.authScope: account]
        )
    }

    func removeAuthentication() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent("auth.json"))
    }

    func session(
        id: String,
        cwd: String? = nil,
        title: String? = "Backend row title",
        createdAt: String? = "2026-08-25T12:00:00.125Z",
        updatedAt: String? = "2026-08-25T12:05:00Z",
        metadata: [String: JSONValue] = [:]
    ) -> LiveSessionWritebackLoadedSession {
        LiveSessionWritebackLoadedSession(
            sessionID: id,
            title: title,
            cwd: cwd ?? workspace.path,
            status: "active",
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata.isEmpty ? nil : .object(metadata)
        )
    }

    func message(
        sessionID: String,
        id: String = UUID().uuidString,
        method: String = "session/update",
        kind: String = "user_message_chunk",
        text: String = "Recovered private user text",
        owner: String? = nil,
        update: [String: JSONValue]? = nil,
        metadata: [String: JSONValue]? = nil
    ) throws -> LiveSessionWritebackLoadedMessage {
        var parameters: [String: JSONValue] = [
            "sessionId": .string(owner ?? sessionID),
            "update": .object(update ?? [
                "sessionUpdate": .string(kind),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]),
        ]
        if let metadata { parameters["_meta"] = .object(metadata) }
        let envelope: JSONValue = .object([
            "method": .string(method),
            "params": .object(parameters),
        ])
        return LiveSessionWritebackLoadedMessage(
            id: id,
            content: String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self),
            timestamp: "2026-08-25T12:01:00Z"
        )
    }

    func response(
        session: LiveSessionWritebackLoadedSession?,
        messages: [LiveSessionWritebackLoadedMessage]? = nil,
        status: Int = 200
    ) throws -> MockHTTPTransport.ScriptedResponse {
        let value = LiveSessionWritebackLoadResponse(messages: messages, session: session)
        return MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status),
            body: try JSONEncoder().encode(value)
        )
    }

    func rawResponse(_ body: String, status: Int = 200) -> MockHTTPTransport.ScriptedResponse {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status),
            body: Data(body.utf8)
        )
    }

    func options(
        sessionID: String,
        selector: String = "--resume",
        arguments: [String] = []
    ) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "hydration probe",
            "--cwd", workspace.path,
            "--model", "grok-4.5",
            selector, sessionID,
        ] + arguments)
        guard case .launch(let resolved) = command else {
            throw CLIApplicationError.failed("hydration fixture did not parse a launch")
        }
        return resolved
    }

    func hydrate(
        sessionID: String,
        transport: any HTTPTransport,
        overrides: [String: String] = [:],
        registryEnabled: Bool = true,
        options: CLIExecutionOptions? = nil,
        remoteRegistryEnabled: Bool? = nil
    ) async throws -> Bool {
        var configured = registryEnabled ? enabledEnvironment : environment
        configured.merge(overrides) { _, value in value }
        return try await LiveRemoteSessionHydration.hydrateIfMissing(
            options: options ?? self.options(sessionID: sessionID),
            invocationWorkingDirectory: workspace,
            openGrokHome: home,
            environment: configured,
            transport: transport,
            remoteRegistryEnabled: remoteRegistryEnabled
        )
    }

    func state(_ sessionID: String) throws -> PersistedSessionState? {
        try SessionDocumentStore(grokHome: home).load(
            sessionID: sessionID,
            cwd: workspace.path
        )
    }

    func assertUnpublished(_ sessionID: String) throws {
        let directory = try SessionDocumentStore(grokHome: home).sessionDirectory(
            sessionID: sessionID,
            cwd: workspace.path
        )
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(SessionDocumentStore.summaryFileName).path
        ))
    }

    @discardableResult
    func seed(
        id: String,
        provider: ModelProvider? = .xai,
        everUsedNonXAI: Bool? = false,
        text: String = "Original protected local session"
    ) async throws -> LiveConversationRecord {
        var record = LiveConversationRecord.new(sessionID: id, workingDirectory: workspace)
        record.currentModelID = "grok-4.5"
        record.currentProvider = provider
        record.everUsedNonXAI = everUsedNonXAI
        record.items = [.user(text)]
        try await LiveConversationStore(openGrokHome: home).save(record)
        return record
    }

    func launch(
        sessionID: String,
        transport: any HTTPTransport,
        overrides: [String: String] = [:],
        arguments: [String] = [],
        selector: String = "--resume",
        registryEnabled: Bool = true,
        remoteSettings: RemoteSettings? = nil
    ) async -> (status: Int32, output: String, errors: String) {
        var configured = registryEnabled ? enabledEnvironment : environment
        configured.merge(overrides) { _, value in value }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    let answer = "HYDRATION_LIVE_ASSISTANT_RESPONSE"
                    await emit(.output(answer))
                    return OpenGrokLiveSamplingResponse(output: answer)
                }
            },
            makeImageTransport: { transport },
            remoteSettingsSnapshot: remoteSettings
        )
        let (streams, output, errors) = CLIStreams.buffered()
        let status = await CLIRunner.run(
            [
                "headless",
                "--prompt", "HYDRATION_LIVE_NEW_USER_PROMPT",
                "--cwd", workspace.path,
                "--model", "grok-4.5",
                selector, sessionID,
            ] + arguments,
            environment: configured,
            streams: streams,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )
        return (status, output.contents, errors.contents)
    }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        LiveManagedPolicyLifecycle.stop(environment: enabledEnvironment)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RemoteHydrationMutatingTransport: HTTPTransport, @unchecked Sendable {
    let wrapped: MockHTTPTransport
    private let lock = NSLock()
    private var changed = false
    private let mutate: @Sendable () throws -> Void

    init(wrapped: MockHTTPTransport, mutate: @escaping @Sendable () throws -> Void) {
        self.wrapped = wrapped
        self.mutate = mutate
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await wrapped.send(request)
        let shouldChange = lock.withLock {
            guard !changed else { return false }
            changed = true
            return true
        }
        if shouldChange { try mutate() }
        return response
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        wrapped.stream(request)
    }
}

@Suite("authenticated remote session hydration parity and security", .serialized)
struct LiveRemoteSessionHydrationParityTests {
    @Test("registry pull is disabled by default and explicit local settings honor environment precedence")
    func registryGatePrecedence() throws {
        let unspecified = try parseTOML("")
        let enabled = try parseTOML("[cli]\nsession_registry = true\n")
        let disabled = try parseTOML("[cli]\nsession_registry = false\n")

        #expect(!LiveRemoteSessionHydration.registryEnabled(
            environment: [:],
            document: unspecified
        ))
        #expect(LiveRemoteSessionHydration.registryEnabled(environment: [:], document: enabled))
        #expect(!LiveRemoteSessionHydration.registryEnabled(environment: [:], document: disabled))
        #expect(!LiveRemoteSessionHydration.registryEnabled(
            environment: ["GROK_SESSION_REGISTRY": "false"],
            document: enabled
        ))
        #expect(LiveRemoteSessionHydration.registryEnabled(
            environment: ["GROK_SESSION_REGISTRY": "true"],
            document: disabled
        ))
        #expect(LiveRemoteSessionHydration.registryEnabled(
            environment: [:],
            document: unspecified,
            remoteRegistryEnabled: true
        ))
        #expect(!LiveRemoteSessionHydration.registryEnabled(
            environment: [:],
            document: unspecified,
            remoteRegistryEnabled: false
        ))
        #expect(!LiveRemoteSessionHydration.registryEnabled(
            environment: [:],
            document: disabled,
            remoteRegistryEnabled: true
        ))
        #expect(LiveRemoteSessionHydration.registryEnabled(
            environment: [:],
            document: enabled,
            remoteRegistryEnabled: false
        ))
        #expect(!LiveRemoteSessionHydration.registryEnabled(
            environment: ["GROK_SESSION_REGISTRY": "false"],
            document: enabled,
            remoteRegistryEnabled: true
        ))
    }

    @Test("disabled or absent registry gates never query the authenticated backend")
    func disabledGateNeverContactsBackend() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString

        for overrides in [[:], ["GROK_SESSION_REGISTRY": "false"]] {
            let transport = MockHTTPTransport()
            let hydrated = try await fixture.hydrate(
                sessionID: id,
                transport: transport,
                overrides: overrides,
                registryEnabled: false
            )
            #expect(!hydrated)
            #expect(transport.recordedRequests.isEmpty)
            try fixture.assertUnpublished(id)
        }
    }

    @Test("writeback storage mode alone never enables remote hydration")
    func writebackAloneCannotEnableRegistry() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport()

        let hydrated = try await fixture.hydrate(
            sessionID: id,
            transport: transport,
            overrides: ["GROK_STORAGE_MODE": "writeback"],
            registryEnabled: false
        )

        #expect(!hydrated)
        #expect(transport.recordedRequests.isEmpty)
        try fixture.assertUnpublished(id)
    }

    @Test("an explicit registry opt-in hydrates even when storage mode remains local")
    func localStorageDoesNotBlockOptInPull() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [
            try fixture.response(
                session: fixture.session(id: id),
                messages: [try fixture.message(sessionID: id)]
            ),
        ])

        let hydrated = try await fixture.hydrate(
            sessionID: id,
            transport: transport,
            overrides: ["GROK_STORAGE_MODE": "local"],
            options: fixture.options(sessionID: id, arguments: ["--storage-mode", "local"])
        )

        #expect(hydrated)
        #expect(transport.recordedRequests.count == 1)
        #expect(try fixture.state(id)?.summary.sessionID.rawValue == id)
    }

    @Test("trusted owner-global registry configuration enables an authenticated remote pull")
    func trustedGlobalConfigurationEnablesHydration() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try Data("[cli]\nsession_registry = true\n".utf8).write(
            to: fixture.home.appendingPathComponent("config.toml")
        )
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [try fixture.message(sessionID: id)]
        )])

        #expect(try await fixture.hydrate(
            sessionID: id,
            transport: transport,
            registryEnabled: false
        ))
        #expect(transport.recordedRequests.count == 1)
        #expect(try fixture.state(id) != nil)
    }

    @Test("untrusted project configuration cannot enable a pre-sandbox transcript download")
    func untrustedProjectCannotEnableHydration() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let project = fixture.workspace.appendingPathComponent(".opengrok", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(project, stateRoot: fixture.root)
        #else
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #endif
        try Data("[cli]\nsession_registry = true\n".utf8).write(
            to: project.appendingPathComponent("config.toml")
        )
        let id = UUID().uuidString
        let transport = MockHTTPTransport()

        let hydrated = try await fixture.hydrate(
            sessionID: id,
            transport: transport,
            registryEnabled: false
        )

        #expect(!hydrated)
        #expect(transport.recordedRequests.isEmpty)
        try fixture.assertUnpublished(id)
    }

    @Test("the authenticated real GET recovers canonical user, assistant, and tool history")
    func hydratesRealConversationAndTools() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        let expectedWorkspace = try PathSecurity.canonicalize(fixture.workspace).path
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let messages = [
            try fixture.message(sessionID: id, kind: "user_message_chunk", text: "Recovered user "),
            try fixture.message(sessionID: id, kind: "user_message_chunk", text: "question"),
            try fixture.message(sessionID: id, kind: "agent_message_chunk", text: "Recovered assistant answer"),
            try fixture.message(sessionID: id, update: [
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("read-1"),
                "title": .string("read_file"),
                "rawInput": .object(["path": .string("README.md")]),
            ]),
            try fixture.message(sessionID: id, update: [
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("read-1"),
                "status": .string("completed"),
                "content": .array([.object([
                    "type": .string("content"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("Recovered private file contents"),
                    ]),
                ])]),
            ]),
        ]
        let transport = MockHTTPTransport(responses: [
            try fixture.response(
                session: fixture.session(id: id, metadata: ["model_id": .string("grok-4.5")]),
                messages: messages
            ),
        ])

        let hydrated = try await fixture.hydrate(sessionID: id, transport: transport)

        #expect(hydrated)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "\(fixture.endpoint)/sessions/\(id)/data")
        #expect(request.headers["Authorization"] == "Bearer HYDRATION_PRIVATE_FIRST_PARTY_BEARER")
        #expect(request.headers["X-XAI-Token-Auth"] == "xai-grok-cli")
        #expect(request.headers["x-userid"] == "hydration-owner")

        let state = try #require(try fixture.state(id))
        #expect(state.summary.sessionID.rawValue == id)
        #expect(state.summary.cwd == expectedWorkspace)
        #expect(state.summary.currentModelID == "grok-4.5")
        #expect(state.summary.everUsedCodex == false)
        #expect(state.summary.extra["current_provider"] == .string("xai"))
        #expect(state.summary.extra["swift_legacy_export_boundary_missing"] == .bool(false))
        #expect(state.summary.extra["cache_affinity_id"] == .string(id))
        #expect(state.updates.count == messages.count)
        let recovered = try state.chatHistory.map { try $0.decode(ConversationItem.self) }
        #expect(recovered.contains { $0.textContent().contains("Recovered user") })
        #expect(recovered.contains { $0.textContent().contains("Recovered assistant answer") })
        #expect(recovered.contains { $0.textContent().contains("Recovered private file contents") })
        #expect(state.summary.chatMessageCount == UInt64(recovered.count))
    }

    @Test("a real existing canonical session always wins without a backend request")
    func localHitNeverContactsBackend() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        try await fixture.seed(id: id)
        let transport = MockHTTPTransport()

        let hydrated = try await fixture.hydrate(sessionID: id, transport: transport)

        #expect(!hydrated)
        #expect(transport.recordedRequests.isEmpty)
        let persisted = try #require(try fixture.state(id))
        #expect(persisted.chatHistory.contains {
            (try? $0.decode(ConversationItem.self).textContent())?
                .contains("Original protected local session") == true
        })
    }

    @Test("a corrupt existing local summary fails without querying or replacing local history")
    func corruptLocalSessionNeverFallsBack() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        try await fixture.seed(id: id)
        let directory = try SessionDocumentStore(grokHome: fixture.home).sessionDirectory(
            sessionID: id,
            cwd: fixture.workspace.path
        )
        let summary = directory.appendingPathComponent(SessionDocumentStore.summaryFileName)
        let corrupt = Data("corrupt private local summary".utf8)
        try corrupt.write(to: summary)
        let transport = MockHTTPTransport()

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        #expect(transport.recordedRequests.isEmpty)
        #expect(try Data(contentsOf: summary) == corrupt)
    }

    @Test("ambiguous resume titles are never used as remote backend session identifiers")
    func titlesAreNeverRemotelyProbed() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport()

        let hydrated = try await fixture.hydrate(sessionID: "meaningful-session-title", transport: transport)

        #expect(!hydrated)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("fork, continuation, worktree, and code-restore launches never download remote state")
    func unsupportedStartupModesNeverContactBackend() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())

        for arguments in [["--fork-session"], ["--restore-code"], ["--worktree"]] {
            let id = UUID().uuidString
            let transport = MockHTTPTransport()
            let options = try fixture.options(sessionID: id, arguments: arguments)

            let hydrated = try await fixture.hydrate(
                sessionID: id,
                transport: transport,
                options: options
            )
            #expect(!hydrated)
            #expect(transport.recordedRequests.isEmpty)
            try fixture.assertUnpublished(id)
        }

        let continued = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "hydration probe",
            "--cwd", fixture.workspace.path,
            "--model", "grok-4.5",
            "--continue",
        ])
        guard case .launch(let options) = continued else {
            Issue.record("continuation fixture did not resolve to a launch")
            return
        }
        let id = UUID().uuidString
        let transport = MockHTTPTransport()
        let hydrated = try await fixture.hydrate(
            sessionID: id,
            transport: transport,
            options: options
        )
        #expect(!hydrated)
        #expect(transport.recordedRequests.isEmpty)
        try fixture.assertUnpublished(id)
    }

    @Test("backend 404, null session, and missing remote cwd stay genuine misses")
    func remoteMissShapesDoNotPublish() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())

        for variant in 0..<4 {
            let id = UUID().uuidString
            let scripted: MockHTTPTransport.ScriptedResponse
            switch variant {
            case 0:
                scripted = fixture.rawResponse("{}", status: 404)
            case 1:
                scripted = try fixture.response(session: nil, messages: nil)
            case 2:
                var remote = fixture.session(id: id)
                remote.cwd = nil
                scripted = try fixture.response(session: remote)
            default:
                var remote = fixture.session(id: id)
                remote.cwd = ""
                scripted = try fixture.response(session: remote)
            }
            let transport = MockHTTPTransport(responses: [scripted])
            let hydrated = try await fixture.hydrate(sessionID: id, transport: transport)
            #expect(!hydrated)
            #expect(transport.recordedRequests.count == 1)
            try fixture.assertUnpublished(id)
        }
    }

    @Test("snake-case metadata hydrates title, manual state, model, parent, and RFC3339 dates")
    func hydratesSnakeCaseMetadata() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let parent = UUID().uuidString
        let remote = fixture.session(
            id: id,
            title: "Stale asynchronous row title",
            metadata: [
                "title": .string("Fresh pinned title"),
                "title_is_manual": .bool(true),
                "model_id": .string("grok-4.5"),
                "parent_session_id": .string(parent),
            ]
        )
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: remote,
            messages: [try fixture.message(sessionID: id)]
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))

        let summary = try #require(try fixture.state(id)?.summary)
        #expect(summary.sessionSummary == "Fresh pinned title")
        #expect(summary.extra["generated_title"] == .string("Fresh pinned title"))
        #expect(summary.extra["title_is_manual"] == .bool(true))
        #expect(summary.currentModelID == "grok-4.5")
        #expect(summary.parentSessionID == parent)
        #expect(summary.createdAt < summary.updatedAt)
    }

    @Test("camel-case metadata remains compatible with Rust's remote hydrator")
    func hydratesCamelCaseMetadata() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let parent = UUID().uuidString
        let remote = fixture.session(
            id: id,
            metadata: [
                "title": .string("Camel-case title"),
                "titleIsManual": .bool(true),
                "modelId": .string("grok-4.5"),
                "parentSessionId": .string(parent),
            ]
        )
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: remote,
            messages: [try fixture.message(sessionID: id)]
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))

        let summary = try #require(try fixture.state(id)?.summary)
        #expect(summary.currentModelID == "grok-4.5")
        #expect(summary.parentSessionID == parent)
        #expect(summary.extra["title_is_manual"] == .bool(true))
    }

    @Test("an explicit empty metadata title clears the stale nonempty registry row title")
    func emptyMetadataTitleOverridesRegistryRow() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(
                id: id,
                title: "Stale registry title must disappear",
                metadata: [
                    "title": .string(""),
                    "title_is_manual": .bool(true),
                ]
            ),
            messages: [try fixture.message(sessionID: id)]
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))

        let summary = try #require(try fixture.state(id)?.summary)
        #expect(summary.sessionSummary.isEmpty)
        #expect(summary.extra["title"] == nil)
        #expect(summary.extra["generated_title"] == nil)
        #expect(summary.extra["title_is_manual"] == nil)
    }

    @Test("remote titles are sanitized and capped before publication")
    func sanitizesRemoteTitle() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let hostile = "\u{001b}unsafe\n" + String(repeating: "x", count: 180)
        let remote = fixture.session(id: id, metadata: ["title": .string(hostile)])
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: remote,
            messages: [try fixture.message(sessionID: id)]
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))

        let title = try #require(try fixture.state(id)?.summary.sessionSummary)
        #expect(title.count <= maxTitleScalars)
        #expect(!title.contains("\u{001b}"))
        #expect(!title.contains("\n"))
    }

    @Test("both replayable ACP methods survive hydration and compaction checkpoints rebuild correctly")
    func preservesBothReplayMethods() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let messages = [
            try fixture.message(sessionID: id, text: "obsolete private context"),
            try fixture.message(
                sessionID: id,
                method: "_x.ai/session/update",
                update: ["sessionUpdate": .string("compaction_checkpoint")]
            ),
            try fixture.message(sessionID: id, text: "current visible context"),
            try fixture.message(sessionID: id, kind: "agent_message_chunk", text: "current answer"),
        ]
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: messages
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))

        let state = try #require(try fixture.state(id))
        #expect(state.updates.map(\.method).contains("_x.ai/session/update"))
        let recovered = try state.chatHistory.map { try $0.decode(ConversationItem.self).textContent() }
        #expect(recovered.contains { $0.contains("current visible context") })
        #expect(recovered.contains { $0.contains("current answer") })
        #expect(!recovered.contains { $0.contains("obsolete private context") })
    }

    @Test("well-formed unrelated backend events are skipped without becoming replay history")
    func skipsNonReplayEvents() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let messages = [
            try fixture.message(sessionID: id, method: "prompt_complete", text: "never replay me"),
            try fixture.message(sessionID: id, text: "keep this genuine user message"),
        ]
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: messages
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))

        let state = try #require(try fixture.state(id))
        #expect(state.updates.count == 1)
        #expect(state.updates.first?.method == "session/update")
        #expect(!state.chatHistory.contains {
            (try? $0.decode(ConversationItem.self).textContent())?
                .contains("never replay me") == true
        })
    }

    @Test("outer remote session identity mismatches never publish another account's session")
    func rejectsOuterCrossSessionIdentity() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let requested = UUID().uuidString
        let returned = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: returned),
            messages: [try fixture.message(sessionID: returned)]
        )])

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: requested, transport: transport)
        }
        #expect(transport.recordedRequests.count == 1)
        try fixture.assertUnpublished(requested)
        try fixture.assertUnpublished(returned)
    }

    @Test("nested cross-session replay updates fail closed before any summary is published")
    func rejectsNestedCrossSessionIdentity() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let messages = [
            try fixture.message(sessionID: id, text: "valid prefix"),
            try fixture.message(sessionID: id, owner: UUID().uuidString),
        ]
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: messages
        )])

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        try fixture.assertUnpublished(id)
    }

    @Test("malformed backend envelopes never create a partially hydrated session")
    func rejectsMalformedEnvelopes() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())

        let malformed = [
            "not json at all",
            #"{"method":"session/update","params":"unsafe"}"#,
            #"{"method":"session/update","params":{"update":{}}}"#,
            #"{"method":"session/update"}"#,
        ]
        for raw in malformed {
            let id = UUID().uuidString
            let message = LiveSessionWritebackLoadedMessage(id: "unsafe", content: raw, timestamp: nil)
            let transport = MockHTTPTransport(responses: [try fixture.response(
                session: fixture.session(id: id),
                messages: [message]
            )])
            await #expect(throws: (any Error).self) {
                try await fixture.hydrate(sessionID: id, transport: transport)
            }
            try fixture.assertUnpublished(id)
        }
    }

    @Test("redirects, mismatched final authorities, and malformed backend bodies never publish")
    func rejectsRedirectsAndInvalidBackendResponses() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())

        for variant in 0..<3 {
            let id = UUID().uuidString
            var response = try fixture.response(
                session: fixture.session(id: id),
                messages: [try fixture.message(sessionID: id)]
            )
            switch variant {
            case 0:
                response.metadata.statusCode = 302
                response.metadata.headers["Location"] = "https://attacker.example.invalid/private"
            case 1:
                response.metadata.url = try #require(URL(
                    string: "https://attacker.example.invalid/sessions/\(id)/data"
                ))
            default:
                response = fixture.rawResponse("{malformed backend response")
            }
            let transport = MockHTTPTransport(responses: [response])

            await #expect(throws: (any Error).self) {
                try await fixture.hydrate(sessionID: id, transport: transport)
            }
            #expect(transport.recordedRequests.count == 1)
            try fixture.assertUnpublished(id)
        }
    }

    @Test("foreign and traversal-selected workspaces cannot claim the trusted invocation root")
    func rejectsForeignWorkspaces() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let candidates = [
            fixture.foreignWorkspace.path,
            fixture.workspace.appendingPathComponent("..").appendingPathComponent(
                "foreign workspace"
            ).path,
            "relative/untrusted/workspace",
        ]

        for candidate in candidates {
            let id = UUID().uuidString
            let transport = MockHTTPTransport(responses: [try fixture.response(
                session: fixture.session(id: id, cwd: candidate),
                messages: [try fixture.message(sessionID: id)]
            )])
            await #expect(throws: (any Error).self) {
                try await fixture.hydrate(sessionID: id, transport: transport)
            }
            try fixture.assertUnpublished(id)
        }
    }

    #if !os(Windows)
    @Test("symlinks to a different workspace cannot bypass canonical root matching")
    func rejectsWorkspaceSymlinkEscape() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let alias = fixture.root.appendingPathComponent("hostile-symlink")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.foreignWorkspace)
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id, cwd: alias.path),
            messages: [try fixture.message(sessionID: id)]
        )])

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        try fixture.assertUnpublished(id)
    }
    #endif

    @Test("oversized message counts are rejected before canonical state exists")
    func rejectsExcessiveMessages() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let one = try fixture.message(sessionID: id)
        let messages = Array(repeating: one, count: LiveRemoteSessionHydration.maximumMessages + 1)
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: messages
        )])

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        try fixture.assertUnpublished(id)
    }

    @Test("an oversized individual ACP message is never published")
    func rejectsOversizedMessage() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let message = try fixture.message(
            sessionID: id,
            text: String(repeating: "s", count: LiveRemoteSessionHydration.maximumMessageBytes + 1)
        )
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [message]
        )])

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        try fixture.assertUnpublished(id)
    }

    @Test("missing OAuth credentials never query the first-party backend")
    func rejectsMissingAuthentication() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        let id = UUID().uuidString
        let transport = MockHTTPTransport()

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        #expect(transport.recordedRequests.isEmpty)
        try fixture.assertUnpublished(id)
    }

    @Test("an explicit non-xAI provider never queries the backend, while local history still wins")
    func explicitForeignProviderNeverDownloads() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())

        let missing = UUID().uuidString
        let missingTransport = MockHTTPTransport()
        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(
                sessionID: missing,
                transport: missingTransport,
                options: fixture.options(
                    sessionID: missing,
                    arguments: ["--provider", "codex"]
                )
            )
        }
        #expect(missingTransport.recordedRequests.isEmpty)
        try fixture.assertUnpublished(missing)

        let existing = UUID().uuidString
        try await fixture.seed(id: existing, provider: .codex, everUsedNonXAI: true)
        let localTransport = MockHTTPTransport()
        let hydrated = try await fixture.hydrate(
            sessionID: existing,
            transport: localTransport,
            options: fixture.options(
                sessionID: existing,
                arguments: ["--provider", "codex"]
            )
        )
        #expect(!hydrated)
        #expect(localTransport.recordedRequests.isEmpty)
        let persisted = try #require(try fixture.state(existing)?.summary)
        #expect(persisted.everUsedCodex == true)
        #expect(persisted.extra["current_provider"] == .string("codex"))
    }

    @Test("API and deployment credentials cannot authenticate session transcript downloads")
    func rejectsAPIAndDeploymentKeys() async throws {
        for overrides in [
            ["XAI_API_KEY": "PRIVATE_INFERENCE_API_KEY"],
            ["GROK_DEPLOYMENT_KEY": "PRIVATE_DEPLOYMENT_KEY"],
        ] {
            let fixture = try RemoteSessionHydrationFixture()
            defer { fixture.cleanup() }
            let id = UUID().uuidString
            let transport = MockHTTPTransport()

            await #expect(throws: (any Error).self) {
                try await fixture.hydrate(
                    sessionID: id,
                    transport: transport,
                    overrides: overrides
                )
            }
            #expect(transport.recordedRequests.isEmpty)
            try fixture.assertUnpublished(id)
        }
    }

    @Test("zero-data-retention accounts cannot download durable coding transcripts")
    func rejectsZeroDataRetentionAccount() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(zeroDataRetention: true))
        let id = UUID().uuidString
        let transport = MockHTTPTransport()

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        #expect(transport.recordedRequests.isEmpty)
        try fixture.assertUnpublished(id)
    }

    @Test("coding-data retention opt-out does not block non-ZDR first-party hydration")
    func allowsCodingDataOptOut() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(optedOut: true))
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [try fixture.message(sessionID: id)]
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))
        #expect(transport.recordedRequests.count == 1)
        #expect(try fixture.state(id) != nil)
    }

    @Test("valid first-party external session credentials can hydrate without refresh tokens")
    func allowsFirstPartyExternalAuthentication() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(mode: .external, refreshable: false))
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [try fixture.message(sessionID: id)]
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))
        #expect(transport.recordedRequests.first?.headers["Authorization"]
            == "Bearer HYDRATION_PRIVATE_FIRST_PARTY_BEARER")
    }

    @Test("expired, foreign-issuer, and unrefreshable OIDC credentials never leave the process")
    func rejectsInvalidSessionAuthentication() async throws {
        let variants: [(RemoteSessionHydrationFixture) -> GrokAuth] = [
            { $0.account(expiresAt: Date().addingTimeInterval(-60)) },
            { $0.account(issuer: "https://foreign.example.invalid") },
            { $0.account(refreshable: false) },
        ]
        for makeAccount in variants {
            let fixture = try RemoteSessionHydrationFixture()
            defer { fixture.cleanup() }
            try fixture.persist(makeAccount(fixture))
            let id = UUID().uuidString
            let transport = MockHTTPTransport()

            await #expect(throws: (any Error).self) {
                try await fixture.hydrate(sessionID: id, transport: transport)
            }
            #expect(transport.recordedRequests.isEmpty)
            try fixture.assertUnpublished(id)
        }
    }

    @Test("switching accounts during the GET prevents any durable transcript publication")
    func rejectsAccountSwitchDuringResponse() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let backend = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [try fixture.message(sessionID: id)]
        )])
        let transport = RemoteHydrationMutatingTransport(wrapped: backend) {
            try fixture.persist(fixture.account(userID: "different-hydration-owner"))
        }

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        #expect(backend.recordedRequests.count == 1)
        try fixture.assertUnpublished(id)
    }

    @Test("same-account bearer rotation during the GET fails closed before persistence")
    func rejectsBearerRotationDuringResponse() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let backend = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [try fixture.message(sessionID: id)]
        )])
        let transport = RemoteHydrationMutatingTransport(wrapped: backend) {
            try fixture.persist(fixture.account(token: "ROTATED_HYDRATION_PRIVATE_BEARER"))
        }

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        #expect(backend.recordedRequests.count == 1)
        try fixture.assertUnpublished(id)
    }

    @Test("logout during the GET prevents stale-account transcript publication")
    func rejectsLogoutDuringResponse() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let backend = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [try fixture.message(sessionID: id)]
        )])
        let transport = RemoteHydrationMutatingTransport(wrapped: backend) {
            try fixture.removeAuthentication()
        }

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        #expect(backend.recordedRequests.count == 1)
        try fixture.assertUnpublished(id)
    }

    @Test("a team entering zero-data-retention during the GET cannot publish recovered history")
    func rejectsZDRTransitionDuringResponse() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let backend = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [try fixture.message(sessionID: id)]
        )])
        let transport = RemoteHydrationMutatingTransport(wrapped: backend) {
            try fixture.persist(fixture.account(zeroDataRetention: true))
        }

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        #expect(backend.recordedRequests.count == 1)
        try fixture.assertUnpublished(id)
    }

    @Test("remote metadata cannot resurrect foreign-provider or previously exported sessions")
    func rejectsForeignProviderAndClosedBoundary() async throws {
        let metadata: [[String: JSONValue]] = [
            ["current_provider": .string("codex")],
            ["provider": .string("codex")],
            ["ever_used_codex": .bool(true)],
            ["everUsedCodex": .bool(true)],
        ]
        for fields in metadata {
            let fixture = try RemoteSessionHydrationFixture()
            defer { fixture.cleanup() }
            try fixture.persist(fixture.account())
            let id = UUID().uuidString
            let transport = MockHTTPTransport(responses: [try fixture.response(
                session: fixture.session(id: id, metadata: fields),
                messages: [try fixture.message(sessionID: id)]
            )])

            await #expect(throws: (any Error).self) {
                try await fixture.hydrate(sessionID: id, transport: transport)
            }
            try fixture.assertUnpublished(id)
        }
    }

    @Test("remote parent session path traversal cannot become durable session ancestry")
    func rejectsUnsafeRemoteParent() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id, metadata: ["parent_session_id": .string("../victim")]),
            messages: [try fixture.message(sessionID: id)]
        )])

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(sessionID: id, transport: transport)
        }
        try fixture.assertUnpublished(id)
    }

    @Test("marked Code Mode transport wrappers never land in recovered updates or chat")
    func filtersCodeModeTransportSecrets() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let marker: [String: JSONValue] = ["open-grok/codeModeTransport": .bool(true)]
        let messages = [
            try fixture.message(sessionID: id, text: "visible genuine user message"),
            try fixture.message(
                sessionID: id,
                update: [
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("private-code-cell"),
                    "title": .string("exec"),
                    "rawInput": .object(["token": .string("CODE_MODE_PRIVATE_SECRET")]),
                ],
                metadata: marker
            ),
            try fixture.message(
                sessionID: id,
                update: [
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("private-code-cell"),
                    "status": .string("completed"),
                    "rawOutput": .string("CODE_MODE_PRIVATE_SECRET"),
                ],
                metadata: marker
            ),
        ]
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: messages
        )])

        #expect(try await fixture.hydrate(sessionID: id, transport: transport))

        let state = try #require(try fixture.state(id))
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(encoded.contains("visible genuine user message"))
        #expect(!encoded.contains("CODE_MODE_PRIVATE_SECRET"))
        #expect(!encoded.contains("private-code-cell"))
        #expect(state.updates.count == 1)
    }

    @Test("unsafe backend origins are rejected before transmitting the OAuth bearer")
    func rejectsUntrustedBackendOrigin() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport()

        await #expect(throws: (any Error).self) {
            try await fixture.hydrate(
                sessionID: id,
                transport: transport,
                overrides: ["GROK_CODE_BACKEND_URL": "https://attacker.example.invalid"]
            )
        }
        #expect(transport.recordedRequests.isEmpty)
        try fixture.assertUnpublished(id)
    }

    @Test("an authenticated reviewed remote setting enables hydration when no local override exists")
    func reviewedRemoteGateCanEnableHydration() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id),
            messages: [try fixture.message(sessionID: id)]
        )])

        #expect(try await fixture.hydrate(
            sessionID: id,
            transport: transport,
            registryEnabled: false,
            remoteRegistryEnabled: true
        ))
        #expect(transport.recordedRequests.count == 1)
        #expect(try fixture.state(id) != nil)
    }

    @Test("explicit local false wins over an authenticated remote registry enable")
    func localFalseOverridesReviewedRemoteEnable() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport()

        let hydrated = try await fixture.hydrate(
            sessionID: id,
            transport: transport,
            overrides: ["GROK_SESSION_REGISTRY": "false"],
            registryEnabled: false,
            remoteRegistryEnabled: true
        )

        #expect(!hydrated)
        #expect(transport.recordedRequests.isEmpty)
        try fixture.assertUnpublished(id)
    }

    @Test("a real headless resume hydrates a missing remote session before launching the sampler")
    func realLauncherResumesHydratedSession() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id, metadata: ["model_id": .string("grok-4.5")]),
            messages: [try fixture.message(sessionID: id, text: "Original remote launch history")]
        )])

        let result = await fixture.launch(sessionID: id, transport: transport)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("HYDRATION_LIVE_ASSISTANT_RESPONSE"))
        #expect(transport.recordedRequests.first?.url.path == "/sessions/\(id)/data")
        let state = try #require(try fixture.state(id))
        let text = try state.chatHistory.map { try $0.decode(ConversationItem.self).textContent() }
        #expect(text.contains { $0.contains("Original remote launch history") })
        #expect(text.contains { $0.contains("HYDRATION_LIVE_ASSISTANT_RESPONSE") })
    }

    @Test("the real headless --load alias hydrates the identical authenticated resume path")
    func realLauncherLoadAliasHydratesSession() async throws {
        let fixture = try RemoteSessionHydrationFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let id = UUID().uuidString
        let transport = MockHTTPTransport(responses: [try fixture.response(
            session: fixture.session(id: id, metadata: ["model_id": .string("grok-4.5")]),
            messages: [try fixture.message(sessionID: id, text: "Original --load remote history")]
        )])

        let result = await fixture.launch(
            sessionID: id,
            transport: transport,
            selector: "--load"
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("HYDRATION_LIVE_ASSISTANT_RESPONSE"))
        #expect(transport.recordedRequests.first?.url.path == "/sessions/\(id)/data")
        let state = try #require(try fixture.state(id))
        let text = try state.chatHistory.map { try $0.decode(ConversationItem.self).textContent() }
        #expect(text.contains { $0.contains("Original --load remote history") })
    }

    @Test("the launcher consumes only reviewed remote registry settings and respects local false")
    func launcherUsesReviewedRemoteRegistryAuthority() async throws {
        let enabledFixture = try RemoteSessionHydrationFixture()
        defer { enabledFixture.cleanup() }
        try enabledFixture.persist(enabledFixture.account())
        let enabledID = UUID().uuidString
        let enabledTransport = MockHTTPTransport(responses: [try enabledFixture.response(
            session: enabledFixture.session(id: enabledID, metadata: ["model_id": .string("grok-4.5")]),
            messages: [try enabledFixture.message(sessionID: enabledID)]
        )])
        var reviewed = RemoteSettings()
        reviewed.sessionRegistryEnabled = true

        let allowed = await enabledFixture.launch(
            sessionID: enabledID,
            transport: enabledTransport,
            registryEnabled: false,
            remoteSettings: reviewed
        )
        #expect(allowed.status == CLIRunner.ExitCode.success.rawValue)
        #expect(enabledTransport.recordedRequests.contains { $0.url.path == "/sessions/\(enabledID)/data" })

        let deniedFixture = try RemoteSessionHydrationFixture()
        defer { deniedFixture.cleanup() }
        try deniedFixture.persist(deniedFixture.account())
        let deniedID = UUID().uuidString
        let deniedTransport = MockHTTPTransport()
        let denied = await deniedFixture.launch(
            sessionID: deniedID,
            transport: deniedTransport,
            overrides: ["GROK_SESSION_REGISTRY": "false"],
            registryEnabled: false,
            remoteSettings: reviewed
        )
        #expect(denied.status != CLIRunner.ExitCode.success.rawValue)
        #expect(deniedTransport.recordedRequests.isEmpty)
        try deniedFixture.assertUnpublished(deniedID)
    }
}
