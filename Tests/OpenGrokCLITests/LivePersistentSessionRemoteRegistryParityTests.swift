import Foundation
import OpenGrokACP
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias RemoteRegistryJSON = OpenGrokShared.JSONValue

private struct PersistentRemoteRegistryFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL
    let alternate: URL

    init() throws {
        #if os(Windows)
        let rootName = "oar-\(UUID().uuidString.prefix(8))"
        #else
        let rootName = "opengrok-acp-remote-registry-\(UUID().uuidString)"
        #endif
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            rootName,
            isDirectory: true
        )
        home = root.appendingPathComponent("owner", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        alternate = root.appendingPathComponent("alternate", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(root, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        try OpenGrokConfig.createDirAllOwnerOnly(workspace, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(alternate, stateRoot: root)
        #else
        for directory in [root, home, workspace, alternate] {
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
            "GROK_SESSION_REGISTRY": "true",
        ]
    }

    func account(
        token: String = "PRIVATE_ACP_REGISTRY_TOKEN",
        userID: String = "acp-registry-owner",
        mode: AuthMode = .oidc,
        issuer: String? = "https://auth.x.ai",
        zeroDataRetention: Bool = false
    ) -> GrokAuth {
        GrokAuth(
            key: token,
            authMode: mode,
            userID: userID,
            principalID: "acp-registry-principal",
            teamID: "acp-registry-team",
            organizationID: "acp-registry-organization",
            teamBlockedReasons: zeroDataRetention ? ["BLOCKED_REASON_NO_LOGS"] : [],
            codingDataRetentionOptOut: true,
            refreshToken: mode == .oidc ? "PRIVATE_ACP_REGISTRY_REFRESH" : nil,
            expiresAt: Date().addingTimeInterval(3_600),
            oidcIssuer: issuer
        )
    }

    func persist(_ account: GrokAuth) throws {
        let configuration = liveManagedAuthenticationConfiguration(environment: environment)
        try writeAuthJSON(
            at: home.appendingPathComponent("auth.json"),
            store: [configuration.authScope: account]
        )
    }

    func repository(_ remote: String, at directory: URL? = nil) throws {
        let git = (directory ?? workspace).appendingPathComponent(".git", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(git, stateRoot: root)
        #else
        try FileManager.default.createDirectory(
            at: git,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #endif
        try Data("[remote \"origin\"]\n\turl = \(remote)\n".utf8).write(
            to: git.appendingPathComponent("config")
        )
        try Data("ref: refs/heads/main\n".utf8).write(
            to: git.appendingPathComponent("HEAD")
        )
    }

    func record(
        id: String = "remote-session",
        cwd: URL? = nil,
        summary: String = "Remote ACP session",
        repository: String? = nil,
        firstPrompt: String = "First private prompt",
        age: Int = 0
    ) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let timestamp = Date(timeIntervalSince1970: 1_782_000_000 + Double(age))
        var result: [String: Any] = [
            "sessionId": id,
            "summary": summary,
            "firstPrompt": firstPrompt,
            "modelId": "grok-code-fast-1",
            "createdAt": formatter.string(from: timestamp.addingTimeInterval(-60)),
            "updatedAt": formatter.string(from: timestamp),
            "lastTurnNumber": 3,
            "cwd": (cwd ?? workspace).path,
            "hostname": "trusted-remote-host",
            "status": "active",
            "gcsTracePrefix": "PRIVATE_GCS_TRACE_PREFIX",
            "gcsBucket": "PRIVATE_GCS_BUCKET",
        ]
        if let repository {
            result["repoRemoteUrl"] = repository
        }
        return result
    }

    func response(
        _ records: [[String: Any]] = [],
        status: Int = 200,
        url: URL? = nil
    ) throws -> MockHTTPTransport.ScriptedResponse {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, url: url),
            body: try JSONSerialization.data(withJSONObject: ["sessions": records])
        )
    }

    func runtime(
        transport: any HTTPTransport,
        overrides: [String: String] = [:],
        reviewed: Bool? = nil,
        removeExplicitGate: Bool = false
    ) async throws -> ACPAgentRuntime {
        var selected = environment
        if removeExplicitGate { selected.removeValue(forKey: "GROK_SESSION_REGISTRY") }
        selected.merge(overrides) { _, new in new }
        let handler = LivePersistentSessionACPHandler(
            openGrokHome: home,
            environment: selected,
            workingDirectory: workspace,
            transport: transport,
            remoteRegistryEnabled: reviewed
        )
        let router = LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(
                catalogStore: LiveModelCatalogStore(
                    input: .default,
                    environment: selected,
                    openGrokHome: home,
                    transport: MockHTTPTransport()
                ),
                modelSwitch: nil
            ),
            persistentSessions: handler
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        let initialized = await runtime.handle(.request(
            id: .string("initialize"),
            method: AgentMethodNames.initialize,
            params: try RemoteRegistryJSON.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = try #require(initialized.first) else {
            throw ACPTransportError.invalidMessage("remote-registry ACP runtime failed to initialize")
        }
        return runtime
    }

    func call(
        _ runtime: ACPAgentRuntime,
        method: String = "x.ai/session/list",
        params: RemoteRegistryJSON = .object([:])
    ) async throws -> RemoteRegistryJSON {
        let messages = await runtime.handle(.request(
            id: .string(UUID().uuidString),
            method: method,
            params: params
        ))
        guard case .response(_, let response?, nil) = try #require(messages.first) else {
            throw ACPTransportError.invalidMessage("remote-registry ACP request failed")
        }
        return response
    }

    func seed(
        _ id: String = "local-session",
        cwd: URL? = nil,
        title: String = "Local ACP session",
        age: Int = 0
    ) async throws {
        var record = LiveConversationRecord.new(
            sessionID: id,
            workingDirectory: cwd ?? workspace
        )
        record.createdAt = Date(timeIntervalSince1970: 1_781_000_000 + Double(age))
        record.updatedAt = Date(timeIntervalSince1970: 1_781_000_060 + Double(age))
        record.title = title
        record.currentModelID = "grok-local"
        record.items = [.user("PRIVATE_LOCAL_TRANSCRIPT")]
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ACPRegistryMutatingTransport: HTTPTransport, @unchecked Sendable {
    private let wrapped: MockHTTPTransport
    private let mutate: @Sendable () throws -> Void

    init(_ wrapped: MockHTTPTransport, mutate: @escaping @Sendable () throws -> Void) {
        self.wrapped = wrapped
        self.mutate = mutate
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await wrapped.send(request)
        try mutate()
        return response
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        wrapped.stream(request)
    }
}

@Suite("ACP authenticated remote registry list parity", .serialized)
struct LivePersistentSessionRemoteRegistryParityTests {
    @Test("the actual extension router returns authenticated metadata with Rust's double overfetch")
    func extensionListsAuthenticatedRemoteMetadata() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport(responses: [try fixture.response([fixture.record()])])

        let payload = try await fixture.call(fixture.runtime(transport: transport))
        let row = try #require(payload["result"]?["sessions"]?.arrayValue?.first)
        let request = try #require(transport.recordedRequests.first)

        #expect(row["sessionId"]?.stringValue == "remote-session")
        #expect(row["source"]?.stringValue == "remote")
        #expect(row["firstPrompt"]?.stringValue == "First private prompt")
        #expect(row["hostname"]?.stringValue == "trusted-remote-host")
        #expect(row["gcsTracePrefix"] == nil)
        #expect(row["gcsBucket"] == nil)
        #expect(request.url.absoluteString
            == "https://cli-chat-proxy.grok.com/v1/sessions/search?limit=300")
        #expect(request.headers["Authorization"] == "Bearer PRIVATE_ACP_REGISTRY_TOKEN")
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("sessions").path))
    }

    @Test("the actual core session/list route shares the authenticated durable extension lane")
    func coreListsAuthenticatedRemoteSessions() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport(responses: [try fixture.response([fixture.record()])])

        let response = try await fixture.call(
            fixture.runtime(transport: transport),
            method: AgentMethodNames.sessionList
        )

        #expect(response["sessions"]?[0]?["sessionId"]?.stringValue == "remote-session")
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("the registry defaults dark without explicit local or reviewed consent")
    func registryDisabledByDefault() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport()

        let result = try await fixture.call(
            fixture.runtime(transport: transport, removeExplicitGate: true)
        )

        #expect(result["result"]?["sessions"]?.arrayValue?.isEmpty == true)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("explicit environment false outranks reviewed remote registry enablement")
    func explicitFalseBeatsReviewedEnablement() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport()

        let result = try await fixture.call(fixture.runtime(
            transport: transport,
            overrides: ["GROK_SESSION_REGISTRY": "false"],
            reviewed: true
        ))

        #expect(result["result"]?["sessions"]?.arrayValue?.isEmpty == true)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("reviewed remote registry enablement works only in the absence of local overrides")
    func reviewedSettingEnablesRegistry() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport(responses: [try fixture.response([fixture.record()])])

        let result = try await fixture.call(fixture.runtime(
            transport: transport,
            reviewed: true,
            removeExplicitGate: true
        ))

        #expect(result["result"]?["sessions"]?[0]?["source"]?.stringValue == "remote")
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("owner-global registry configuration enables the trusted metadata lane")
    func trustedOwnerConfigurationEnablesRegistry() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try Data("[cli]\nsession_registry = true\n".utf8).write(
            to: fixture.home.appendingPathComponent("config.toml")
        )
        let transport = MockHTTPTransport(responses: [try fixture.response([fixture.record()])])

        let result = try await fixture.call(fixture.runtime(
            transport: transport,
            reviewed: false,
            removeExplicitGate: true
        ))

        #expect(result["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "remote-session")
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("deployment credentials alone cannot bypass the first-party xAI account prerequisite")
    func deploymentOnlyIsRefused() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        let transport = MockHTTPTransport()

        let result = try await fixture.call(fixture.runtime(
            transport: transport,
            overrides: ["GROK_DEPLOYMENT_KEY": "PRIVATE_DEPLOYMENT_SECRET"]
        ))

        #expect(result["result"]?["sessions"]?.arrayValue?.isEmpty == true)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("API-key and non-xAI OAuth accounts cannot authorize ACP registry disclosure",
          arguments: [false, true])
    func foreignAccountsAreRefused(foreignIssuer: Bool) async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(
            mode: foreignIssuer ? .oidc : .apiKey,
            issuer: foreignIssuer ? "https://login.example.invalid" : "https://auth.x.ai"
        ))
        let transport = MockHTTPTransport()

        let result = try await fixture.call(fixture.runtime(transport: transport))

        #expect(result["result"]?["sessions"]?.arrayValue?.isEmpty == true)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("a deployment bearer outranks OAuth only while its real first-party owner exists")
    func deploymentBearerRequiresRealOwner() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport(responses: [try fixture.response([fixture.record()])])

        let result = try await fixture.call(fixture.runtime(
            transport: transport,
            overrides: ["GROK_DEPLOYMENT_KEY": "PRIVATE_DEPLOYMENT_SECRET"]
        ))

        #expect(result["result"]?["sessions"]?[0]?["source"]?.stringValue == "remote")
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer PRIVATE_DEPLOYMENT_SECRET")
        #expect(request.headers[xaiTokenAuthHeader] == nil)
    }

    @Test("zero-data-retention accounts may list metadata without exporting transcripts")
    func zeroDataRetentionStillListsMetadata() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(zeroDataRetention: true))
        let transport = MockHTTPTransport(responses: [try fixture.response([fixture.record()])])

        let result = try await fixture.call(fixture.runtime(transport: transport))

        #expect(result["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "remote-session")
        #expect(transport.recordedRequests.first?.method == .get)
    }

    @Test("changing the durable owner during a deployment response discards every remote row")
    func accountChangeDuringDeploymentResponseIsRejected() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let wrapped = MockHTTPTransport(responses: [try fixture.response([fixture.record()])])
        let transport = ACPRegistryMutatingTransport(wrapped) {
            try fixture.persist(fixture.account(userID: "different-owner"))
        }

        let result = try await fixture.call(fixture.runtime(
            transport: transport,
            overrides: ["GROK_DEPLOYMENT_KEY": "PRIVATE_DEPLOYMENT_SECRET"]
        ))

        let rows = try #require(result["result"]?["sessions"]?.arrayValue)
        #expect(rows.map { $0["sessionId"]?.stringValue } == ["local-session"])
        #expect(wrapped.recordedRequests.count == 1)
    }

    @Test("same-account token rotation remains valid across independently authorized requests")
    func sameOwnerTokenRotationRemainsValid() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport(responses: [
            try fixture.response([fixture.record(id: "first")]),
            try fixture.response([fixture.record(id: "second")]),
        ])
        let runtime = try await fixture.runtime(transport: transport)

        let first = try await fixture.call(runtime)
        try fixture.persist(fixture.account(token: "PRIVATE_ROTATED_ACP_TOKEN"))
        let second = try await fixture.call(runtime)

        #expect(first["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "first")
        #expect(second["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "second")
        #expect(transport.recordedRequests.last?.headers["Authorization"]
            == "Bearer PRIVATE_ROTATED_ACP_TOKEN")
    }

    @Test("same-repository sessions can have another cwd but different Git hosts never merge")
    func repositoryHostIsolation() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try fixture.repository("https://github.com/owner/repository.git")
        let accepted = fixture.record(
            id: "trusted-repo",
            cwd: fixture.alternate,
            repository: "git@github.com:owner/repository.git"
        )
        let rejected = fixture.record(
            id: "foreign-repo",
            cwd: fixture.alternate,
            repository: "git@gitlab.com:owner/repository.git"
        )
        let transport = MockHTTPTransport(responses: [try fixture.response([accepted, rejected])])

        let result = try await fixture.call(
            fixture.runtime(transport: transport),
            params: .object(["cwd": .string(fixture.workspace.path)])
        )

        let rows = try #require(result["result"]?["sessions"]?.arrayValue)
        #expect(rows.map { $0["sessionId"]?.stringValue } == ["trusted-repo"])
        #expect(rows.first?["cwd"]?.stringValue == fixture.alternate.path)
    }

    @Test("without a trusted repository identity an explicit cwd requires an exact remote match")
    func nonRepositoryScopesRemoteCWDExactly() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport(responses: [try fixture.response([
            fixture.record(id: "same-workspace"),
            fixture.record(id: "foreign-workspace", cwd: fixture.alternate),
        ])])

        let result = try await fixture.call(
            fixture.runtime(transport: transport),
            params: .object(["cwd": .string(fixture.workspace.path)])
        )

        #expect(result["result"]?["sessions"]?.arrayValue?
            .compactMap { $0["sessionId"]?.stringValue } == ["same-workspace"])
    }

    @Test("matching local and registry IDs become both and preserve durable local git facets")
    func mergesLocalAndRemoteMetadata() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try fixture.repository("https://github.com/owner/repository.git")
        try await fixture.seed("same-session", title: "Older local title")
        let transport = MockHTTPTransport(responses: [try fixture.response([
            fixture.record(
                id: "same-session",
                summary: "New registry title",
                repository: "git@github.com:owner/repository.git"
            ),
        ])])

        let result = try await fixture.call(
            fixture.runtime(transport: transport),
            params: .object(["cwd": .string(fixture.workspace.path)])
        )

        let row = try #require(result["result"]?["sessions"]?.arrayValue?.first)
        #expect(row["source"]?.stringValue == "both")
        #expect(row["title"]?.stringValue == "New registry title")
        #expect(row["numMessages"]?.uint64Value == 3)
        #expect(row["gitRemotes"]?.arrayValue?.isEmpty == false)
        #expect(row["firstPrompt"]?.stringValue == "First private prompt")
    }

    @Test("backend-filtered first prompts survive local title filtering and query injection is encoded")
    func remoteFirstPromptQueryAndEncoding() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let needle = "private+needle &limit=999"
        let transport = MockHTTPTransport(responses: [try fixture.response([
            fixture.record(summary: "Unrelated summary", firstPrompt: needle),
        ])])

        let result = try await fixture.call(
            fixture.runtime(transport: transport),
            params: .object(["query": .string(needle)])
        )

        #expect(result["result"]?["sessions"]?[0]?["firstPrompt"]?.stringValue == needle)
        let requestURL = try #require(transport.recordedRequests.first?.url)
        let components = try #require(URLComponents(
            url: requestURL,
            resolvingAgainstBaseURL: false
        ))
        #expect(components.queryItems?.count == 2)
        #expect(components.queryItems?.last?.value == needle)
    }

    @Test("zero-page and chat-only requests never authenticate or open a registry connection",
          arguments: [false, true])
    func nonBuildRequestsNeverFetch(chatOnly: Bool) async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport()
        let params: RemoteRegistryJSON = chatOnly
            ? .object(["_meta": .object([
                "x.ai/facetFilters": .object(["kind": .array([.string("chat")])]),
            ])])
            : .object(["limit": .number(.uint64(0))])

        let result = try await fixture.call(fixture.runtime(transport: transport), params: params)

        #expect(result["result"]?["sessions"]?.arrayValue?.isEmpty == true)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("merged pagination is stable and facets count only the emitted page")
    func mergedPaginationAndPageScopedFacets() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let rows = [
            fixture.record(id: "newest", cwd: fixture.workspace, age: 2),
            fixture.record(id: "oldest", cwd: fixture.alternate, age: 1),
        ]
        let transport = MockHTTPTransport(responses: [
            try fixture.response(rows),
            try fixture.response(rows),
        ])
        let runtime = try await fixture.runtime(transport: transport)

        let first = try await fixture.call(
            runtime,
            params: .object(["limit": .number(.uint64(1))])
        )
        let cursor = try #require(first["result"]?["nextCursor"]?.stringValue)
        let facets = try #require(first["result"]?["_meta"]?["x.ai/facets"]?["keys"]?.arrayValue)
        let cwd = try #require(facets.first { $0["key"]?.stringValue == "cwd" })
        #expect(cwd["values"]?.arrayValue?.count == 1)
        #expect(cwd["values"]?[0]?["count"]?.uint64Value == 1)

        let second = try await fixture.call(
            runtime,
            params: .object([
                "limit": .number(.uint64(1)),
                "cursor": .string(cursor),
            ])
        )

        #expect(first["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "newest")
        #expect(second["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "oldest")
        #expect(second["result"]?["nextCursor"] == nil)
    }

    @Test("backend failures and redirects fall back to local sessions without conversation partials",
          arguments: [false, true])
    func backendFailureFallsBackLocally(redirect: Bool) async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [try fixture.response(
            [],
            status: redirect ? 302 : 503,
            url: redirect ? URL(string: "https://attacker.invalid/stolen") : nil
        )])

        let result = try await fixture.call(fixture.runtime(transport: transport))

        #expect(result["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "local-session")
        #expect(result["result"]?["_meta"]?["x.ai/partial"]?["conversations"]?.boolValue == false)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("relative and control-character remote workspaces are discarded without durable writes",
          arguments: ["relative/workspace", "bad\nworkspace"])
    func maliciousRemoteWorkspacesAreDiscarded(path: String) async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        var malicious = fixture.record()
        malicious["cwd"] = path
        let transport = MockHTTPTransport(responses: [try fixture.response([malicious])])

        let result = try await fixture.call(fixture.runtime(transport: transport))

        #expect(result["result"]?["sessions"]?.arrayValue?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("sessions").path))
    }

    @Test("oversized user limits remain bounded by the registry client's 10,000-row ceiling")
    func largeLimitsRemainBounded() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let transport = MockHTTPTransport(responses: [try fixture.response([])])

        let result = try await fixture.call(
            fixture.runtime(transport: transport),
            params: .object(["limit": .number(.uint64(10_000))])
        )

        #expect(result["result"]?["sessions"]?.arrayValue?.isEmpty == true)
        #expect(transport.recordedRequests.first?.url.query == "limit=9999")
    }

    @Test("attacker-selected ACP cwd cannot replace the immutable trusted launch proxy")
    func callerCwdCannotSelectCredentialAuthority() async throws {
        let fixture = try PersistentRemoteRegistryFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let project = fixture.alternate.appendingPathComponent(".opengrok", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(project, stateRoot: fixture.root)
        #else
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #endif
        try Data("[endpoints]\ncli_chat_proxy_base_url = \"https://attacker.invalid/v1\"\n".utf8)
            .write(to: project.appendingPathComponent("config.toml"))
        let transport = MockHTTPTransport(responses: [try fixture.response([
            fixture.record(cwd: fixture.alternate),
        ])])

        let result = try await fixture.call(
            fixture.runtime(transport: transport),
            params: .object(["cwd": .string(fixture.alternate.path)])
        )

        #expect(result["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "remote-session")
        #expect(transport.recordedRequests.first?.url.host == "cli-chat-proxy.grok.com")
    }
}
