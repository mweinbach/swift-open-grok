import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import Testing

@testable import OpenGrokCLI

private typealias ACPRemoteDeleteJSONValue = OpenGrokShared.JSONValue

private struct ACPRemoteDeleteFixture: Sendable {
    static let defaultSessionID = "acp-remote-delete-session"

    let root: URL
    let home: URL
    let workspace: URL
    let endpoint = "http://127.0.0.1:46392"

    init() throws {
        #if os(Windows)
        let rootName = "oad-\(UUID().uuidString.prefix(8))"
        #else
        let rootName = "opengrok-acp-remote-delete-\(UUID().uuidString)"
        #endif
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            rootName,
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

    var authFile: URL { home.appendingPathComponent("auth.json") }

    func account(
        token: String = "PRIVATE_ACP_REMOTE_DELETE_TOKEN",
        userID: String = "acp-delete-owner",
        principalID: String? = "acp-delete-principal",
        teamID: String? = "acp-delete-team",
        organizationID: String? = "acp-delete-organization",
        mode: AuthMode = .oidc,
        issuer: String? = xaiOAuth2Issuer,
        refreshToken: String? = "PRIVATE_ACP_REMOTE_DELETE_REFRESH",
        zeroDataRetention: Bool = false,
        optedOut: Bool = false,
        expiresAt: Date = Date().addingTimeInterval(3_600)
    ) -> GrokAuth {
        GrokAuth(
            key: token,
            authMode: mode,
            userID: userID,
            email: "acp-delete-owner@example.invalid",
            principalID: principalID,
            teamID: teamID,
            organizationID: organizationID,
            teamBlockedReasons: zeroDataRetention ? ["BLOCKED_REASON_NO_LOGS"] : [],
            codingDataRetentionOptOut: optedOut,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            oidcIssuer: issuer,
            oidcClientID: defaultOAuth2ClientID
        )
    }

    func persist(_ account: GrokAuth) throws {
        let configuration = liveManagedAuthenticationConfiguration(environment: environment)
        try writeAuthJSON(at: authFile, store: [configuration.authScope: account])
    }

    @discardableResult
    func seed(
        sessionID: String = ACPRemoteDeleteFixture.defaultSessionID,
        provider: ModelProvider = .xai,
        everUsedNonXAI: Bool? = false
    ) async throws -> URL {
        var record = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: workspace
        )
        record.currentModelID = "grok-4.5"
        record.currentProvider = provider
        record.everUsedNonXAI = everUsedNonXAI
        record.items = [.user("PRIVATE_ACP_REMOTE_DELETE_TRANSCRIPT")]
        try await LiveConversationStore(openGrokHome: home).save(record)

        let rewind = LiveRewindStore.rewindFileURL(
            openGrokHome: home,
            sessionID: sessionID
        )
        try Data("PRIVATE_ACP_REMOTE_DELETE_REWIND".utf8).write(to: rewind)
        let index = home.appendingPathComponent("sessions/session_search.sqlite")
        try Data("PRIVATE_ACP_REMOTE_DELETE_FTS".utf8).write(to: index)

        return try SessionDocumentStore(grokHome: home).sessionDirectory(
            sessionID: sessionID,
            cwd: workspace.path
        )
    }

    func snapshots(
        sessionID: String = ACPRemoteDeleteFixture.defaultSessionID
    ) throws -> [String: Data] {
        let directory = try SessionDocumentStore(grokHome: home).sessionDirectory(
            sessionID: sessionID,
            cwd: workspace.path
        )
        var files: [String: Data] = [:]
        for name in ["summary.json", "chat_history.jsonl", "updates.jsonl", "state.json"] {
            files[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        files["rewind"] = try Data(contentsOf: LiveRewindStore.rewindFileURL(
            openGrokHome: home,
            sessionID: sessionID
        ))
        files["fts"] = try Data(contentsOf: home.appendingPathComponent(
            "sessions/session_search.sqlite"
        ))
        return files
    }

    func response(
        status: Int = 200,
        url: URL? = nil,
        body: String = "{}",
        error: HTTPError? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, url: url),
            body: Data(body.utf8),
            error: error
        )
    }

    func runtime(
        storageMode: LiveSessionWritebackSync.Mode = .writeback,
        transport: any HTTPTransport,
        overrides: [String: String] = [:],
        liveSessionID: String? = nil,
        installRemoteCallback: Bool = true
    ) async throws -> ACPAgentRuntime {
        var selectedEnvironment = environment
        selectedEnvironment.merge(overrides) { _, override in override }
        let administration = LiveACPSessionRemoteAdministration(
            home: home,
            environment: selectedEnvironment,
            storageMode: storageMode,
            transport: transport
        )
        let remoteDelete: (@Sendable (String) async throws -> Void)?
        if installRemoteCallback {
            remoteDelete = { sessionID in
                try await administration.deleteIfEligible(sessionID: sessionID)
            }
        } else {
            remoteDelete = nil
        }
        let gateway = ACPNotificationGateway()
        let handler = LiveSessionAdminACPHandler(
            openGrokHome: home,
            gateway: gateway,
            liveSessionID: liveSessionID,
            remoteDelete: remoteDelete
        )
        let router = ACPExtensionMethodRouter().register(
            exact: "x.ai/session/delete",
            handler: handler
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        await gateway.attach(runtime)
        let messages = await runtime.handle(.request(
            id: .string("initialize-acp-remote-delete"),
            method: AgentMethodNames.initialize,
            params: try ACPRemoteDeleteJSONValue.encode(
                InitializeRequest(protocolVersion: .v1)
            )
        ))
        guard case .response(_, _, nil) = try #require(messages.first) else {
            throw ACPTransportError.invalidMessage("ACP remote-delete runtime failed to initialize")
        }
        return runtime
    }

    func call(
        _ runtime: ACPAgentRuntime,
        sessionID: String = ACPRemoteDeleteFixture.defaultSessionID,
        kind: String? = nil,
        cwd: String? = nil
    ) async -> (result: ACPRemoteDeleteJSONValue?, error: AcpError?) {
        var params: [String: ACPRemoteDeleteJSONValue] = [
            "sessionId": .string(sessionID),
        ]
        if let kind { params["kind"] = .string(kind) }
        if let cwd { params["cwd"] = .string(cwd) }
        return await call(runtime, params: .object(params))
    }

    func call(
        _ runtime: ACPAgentRuntime,
        params: ACPRemoteDeleteJSONValue
    ) async -> (result: ACPRemoteDeleteJSONValue?, error: AcpError?) {
        let messages = await runtime.handle(.request(
            id: .string("delete-\(UUID().uuidString)"),
            method: "x.ai/session/delete",
            params: params
        ))
        guard case .response(_, let result, let error)? = messages.first else {
            return (nil, AcpError.internalError("ACP remote-delete runtime sent no response"))
        }
        return (result, error)
    }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ACPRemoteDeleteMutatingTransport: HTTPTransport, @unchecked Sendable {
    private let wrapped: MockHTTPTransport
    private let lock = NSLock()
    private var changed = false
    private let mutate: @Sendable () throws -> Void

    init(wrapped: MockHTTPTransport, mutate: @escaping @Sendable () throws -> Void) {
        self.wrapped = wrapped
        self.mutate = mutate
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await wrapped.send(request)
        let shouldMutate = lock.withLock {
            guard !changed else { return false }
            changed = true
            return true
        }
        if shouldMutate { try mutate() }
        return response
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        wrapped.stream(request)
    }
}

@Suite("ACP remote-first session deletion parity", .serialized)
struct LiveACPSessionRemoteDeleteParityTests {
    @Test("authenticated writeback ACP deletes the cloud copy before any local mutation")
    func writebackDeletesRemoteBeforeLocal() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let transport = ACPRemoteDeleteMutatingTransport(wrapped: backend) {
            guard FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("summary.json").path
            ) else {
                throw LiveSessionWritebackClientError.invalidResponse
            }
        }
        let runtime = try await fixture.runtime(transport: transport)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: LiveRewindStore.rewindFileURL(
            openGrokHome: fixture.home,
            sessionID: ACPRemoteDeleteFixture.defaultSessionID
        ).path))
        let request = try #require(backend.recordedRequests.first)
        #expect(request.method == .delete)
        #expect(request.url.absoluteString
            == "\(fixture.endpoint)/sessions/\(ACPRemoteDeleteFixture.defaultSessionID)/data")
        #expect(request.headers["Authorization"] == "Bearer PRIVATE_ACP_REMOTE_DELETE_TOKEN")
        #expect(request.headers["x-userid"] == "acp-delete-owner")
        #expect(request.headers["x-grok-client-mode"] == "acp")
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("local ACP storage mode never attempts backend deletion even with first-party OAuth")
    func localStorageModeNeverContactsBackend() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport()
        let runtime = try await fixture.runtime(storageMode: .local, transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("unauthenticated writeback ACP retains its existing local-only deletion")
    func unauthenticatedWritebackStaysLocal() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport()
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("deployment and API environment keys never authenticate ACP cloud deletion")
    func deploymentAndAPIKeysStayLocal() async throws {
        for key in ["GROK_DEPLOYMENT_KEY", "XAI_API_KEY"] {
            let fixture = try ACPRemoteDeleteFixture()
            defer { fixture.cleanup() }
            let directory = try await fixture.seed()
            let backend = MockHTTPTransport()
            let runtime = try await fixture.runtime(
                transport: backend,
                overrides: [key: "PRIVATE_UNSUITABLE_ACP_DELETE_KEY"]
            )

            let (result, error) = await fixture.call(runtime)

            #expect(error == nil)
            #expect(result == .object(["success": .bool(true)]))
            #expect(backend.recordedRequests.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("API-key auth cannot grant authenticated ACP remote erasure")
    func apiKeyAccountStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(mode: .apiKey, issuer: nil)
        }
    }

    @Test("legacy web login cannot grant authenticated ACP remote erasure")
    func legacyWebAccountStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(mode: .webLogin, issuer: nil)
        }
    }

    @Test("another provider's OIDC issuer cannot authorize first-party ACP deletion")
    func foreignIssuerStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(issuer: "https://auth.openai.com")
        }
    }

    @Test("OIDC without its refresh token never sends a stale bearer")
    func nonrefreshableOAuthStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(refreshToken: nil)
        }
    }

    @Test("expired first-party OAuth never authorizes backend ACP deletion")
    func expiredOAuthStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(expiresAt: Date().addingTimeInterval(-60))
        }
    }

    @Test("ZDR teams do not have writeback session data to erase")
    func zeroDataRetentionStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(zeroDataRetention: true)
        }
    }

    @Test("coding-data retention opt-out alone does not prohibit ACP remote erasure")
    func codingDataOptOutStillDeletesRemotely() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(optedOut: true))
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("valid first-party external credentials can erase writeback ACP sessions")
    func externalAccountDeletesRemotely() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(mode: .external, refreshToken: nil))
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("remote-only ACP session identifiers still perform the real backend DELETE")
    func remoteOnlySessionStillCallsBackend() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime, sessionID: "remote-only-acp-session")

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        let request = try #require(backend.recordedRequests.first)
        #expect(request.url.path == "/sessions/remote-only-acp-session/data")
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("backend 404 is idempotent and still permits deleting the complete local copy")
    func backendNotFoundDeletesLocalCopy() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response(status: 404)])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("missing remote and local copies return ACP's idempotent raw success")
    func bothCopiesMissingAreIdempotent() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let backend = MockHTTPTransport(responses: [fixture.response(status: 404)])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime, sessionID: "already-erased-acp")

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("workspace mismatch does not suppress account-scoped remote deletion")
    func workspaceMismatchStillDeletesRemoteButPreservesLocalCopy() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(
            runtime,
            cwd: fixture.root.appendingPathComponent("another-workspace").path
        )

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.count == 1)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try fixture.snapshots() == before)
    }

    @Test("erasure is allowed after the target session crosses the Codex export boundary")
    func codexTargetCanStillBeErased() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed(provider: .codex, everUsedNonXAI: true)
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("non-404 HTTP failures preserve every journal, rewind snapshot, and FTS entry")
    func backendFailuresPreserveAllLocalArtifacts() async throws {
        for status in [401, 403, 500, 503] {
            let fixture = try ACPRemoteDeleteFixture()
            defer { fixture.cleanup() }
            try fixture.persist(fixture.account())
            try await fixture.seed()
            let before = try fixture.snapshots()
            let backend = MockHTTPTransport(responses: [fixture.response(
                status: status,
                body: "PRIVATE_ACP_REMOTE_DELETE_TOKEN PRIVATE_ACP_REMOTE_DELETE_TRANSCRIPT"
            )])
            let runtime = try await fixture.runtime(transport: backend)

            let (result, error) = await fixture.call(runtime)

            #expect(result == nil)
            #expect(error?.code == .internalError)
            #expect(error?.data?.stringValue?.contains("failed to delete remote session data") == true)
            #expect(error?.data?.stringValue?.contains("\(status)") == true)
            #expect(error?.data?.stringValue?.contains("PRIVATE_ACP_REMOTE_DELETE_TOKEN") == false)
            #expect(error?.data?.stringValue?.contains("PRIVATE_ACP_REMOTE_DELETE_TRANSCRIPT") == false)
            #expect(try fixture.snapshots() == before)
            #expect(backend.recordedRequests.count == 1)
        }
    }

    @Test("transport failures cannot partially erase the local ACP session")
    func transportFailurePreservesLocalArtifacts() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let failure = HTTPError.transport(TransportFailure(
            kind: .unreachable,
            detail: "ACP deletion test backend is unavailable"
        ))
        let backend = MockHTTPTransport(responses: [fixture.response(error: failure)])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(result == nil)
        #expect(error?.code == .internalError)
        #expect(try fixture.snapshots() == before)
    }

    @Test("backend redirects are refused before local history is erased")
    func redirectsPreserveLocalArtifacts() async throws {
        for status in [301, 302, 307, 308] {
            let fixture = try ACPRemoteDeleteFixture()
            defer { fixture.cleanup() }
            try fixture.persist(fixture.account())
            try await fixture.seed()
            let before = try fixture.snapshots()
            let backend = MockHTTPTransport(responses: [fixture.response(status: status)])
            let runtime = try await fixture.runtime(transport: backend)

            let (result, error) = await fixture.call(runtime)

            #expect(result == nil)
            #expect(error?.code == .internalError)
            #expect(error?.data?.stringValue?.contains("redirect") == true)
            #expect(try fixture.snapshots() == before)
        }
    }

    @Test("a final URL mismatch cannot authorize local deletion")
    func finalURLMismatchPreservesLocalArtifacts() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response(
            url: URL(string: "https://foreign.example/sessions/acp-private/data")
        )])
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(result == nil)
        #expect(error?.code == .internalError)
        #expect(try fixture.snapshots() == before)
    }

    @Test("unsafe remote origins never receive credentials or mutate local ACP history")
    func unsafeOriginsFailBeforeNetworking() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()

        for endpoint in [
            "https://foreign.example",
            "http://code.grok.com",
            "http://localhost:46392",
            "https://code.grok.com@foreign.example",
            "http://127.0.0.1:46392?secret=1",
            "http://127.0.0.1:46392#fragment",
        ] {
            let backend = MockHTTPTransport()
            let runtime = try await fixture.runtime(
                transport: backend,
                overrides: ["GROK_CODE_BACKEND_URL": endpoint]
            )

            let (result, error) = await fixture.call(runtime)

            #expect(result == nil)
            #expect(error?.code == .internalError)
            #expect(backend.recordedRequests.isEmpty)
            #expect(try fixture.snapshots() == before)
        }
    }

    @Test("a changed authenticated user after remote success preserves local ownership")
    func accountUserSwitchPreservesLocalArtifacts() async throws {
        try await assertMutationPreservesLocalArtifacts { fixture in
            try fixture.persist(fixture.account(userID: "different-acp-owner"))
        }
    }

    @Test("principal, team, and organization switches cannot erase another account's files")
    func accountScopeSwitchesPreserveLocalArtifacts() async throws {
        for changedField in ["principal", "team", "organization"] {
            try await assertMutationPreservesLocalArtifacts { fixture in
                switch changedField {
                case "principal":
                    try fixture.persist(fixture.account(principalID: "different-principal"))
                case "team":
                    try fixture.persist(fixture.account(teamID: "different-team"))
                default:
                    try fixture.persist(fixture.account(organizationID: "different-organization"))
                }
            }
        }
    }

    @Test("logout during the authenticated backend request preserves all local files")
    func logoutDuringRequestPreservesLocalArtifacts() async throws {
        try await assertMutationPreservesLocalArtifacts { fixture in
            try FileManager.default.removeItem(at: fixture.authFile)
        }
    }

    @Test("a team becoming ZDR after backend success cannot authorize local deletion")
    func zeroDataRetentionTransitionPreservesLocalArtifacts() async throws {
        try await assertMutationPreservesLocalArtifacts { fixture in
            try fixture.persist(fixture.account(zeroDataRetention: true))
        }
    }

    @Test("foreign-provider account rotation after remote success fails closed")
    func foreignProviderTransitionPreservesLocalArtifacts() async throws {
        try await assertMutationPreservesLocalArtifacts { fixture in
            try fixture.persist(fixture.account(issuer: "https://auth.openai.com"))
        }
    }

    @Test("switching to API-key credentials after backend success cannot erase local history")
    func apiKeyTransitionPreservesLocalArtifacts() async throws {
        try await assertMutationPreservesLocalArtifacts { fixture in
            try fixture.persist(fixture.account(mode: .apiKey, issuer: nil))
        }
    }

    @Test("a same-owner bearer refresh remains safe because DELETE exports no transcript")
    func sameOwnerBearerRotationStillDeletesLocalCopy() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let transport = ACPRemoteDeleteMutatingTransport(wrapped: backend) {
            try fixture.persist(fixture.account(token: "PRIVATE_ACP_ROTATED_DELETE_TOKEN"))
        }
        let runtime = try await fixture.runtime(transport: transport)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("the post-request account gate also protects idempotent backend 404 responses")
    func backendNotFoundThenLogoutPreservesLocalArtifacts() async throws {
        try await assertMutationPreservesLocalArtifacts(status: 404) { fixture in
            try FileManager.default.removeItem(at: fixture.authFile)
        }
    }

    @Test("the resident-session refusal happens before any authenticated backend operation")
    func residentSessionRefusalPrecedesNetworking() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport()
        let runtime = try await fixture.runtime(
            transport: backend,
            liveSessionID: ACPRemoteDeleteFixture.defaultSessionID
        )

        let (result, error) = await fixture.call(runtime)

        #expect(result == nil)
        #expect(error?.code == .internalError)
        #expect(error?.data?.stringValue?.contains("currently serving") == true)
        #expect(backend.recordedRequests.isEmpty)
        #expect(try fixture.snapshots() == before)
    }

    @Test("chat-kind and unknown-kind ACP refusals precede backend authentication")
    func unsupportedKindsNeverReachBackend() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport()
        let runtime = try await fixture.runtime(transport: backend)

        let (chatResult, chatError) = await fixture.call(runtime, kind: "chat")
        let (unknownResult, unknownError) = await fixture.call(runtime, kind: "foreign")

        #expect(chatResult == nil)
        #expect(chatError?.code == .invalidRequest)
        #expect(unknownResult == nil)
        #expect(unknownError?.code == .invalidParams)
        #expect(backend.recordedRequests.isEmpty)
        #expect(try fixture.snapshots() == before)
    }

    @Test("malformed session identifiers retain local-miss success without exposing a bearer")
    func invalidSessionIdentifiersNeverReachBackend() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport()
        let runtime = try await fixture.runtime(transport: backend)

        for sessionID in ["../private", "", ".", "..", "nested/private", "has space"] {
            let (result, error) = await fixture.call(runtime, sessionID: sessionID)

            #expect(error == nil)
            #expect(result == .object(["success": .bool(true)]))
        }
        #expect(backend.recordedRequests.isEmpty)
        #expect(try fixture.snapshots() == before)
    }

    @Test("missing ACP session identity is rejected before any account or network access")
    func missingSessionIdentifierNeverReachesBackend() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport()
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime, params: .object([:]))

        #expect(result == nil)
        #expect(error?.code == .invalidParams)
        #expect(backend.recordedRequests.isEmpty)
        #expect(try fixture.snapshots() == before)
    }

    @Test("older ACP handlers without a remote callback retain their local-only behavior")
    func absentRemoteCallbackPreservesLegacyBehavior() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport()
        let runtime = try await fixture.runtime(
            transport: backend,
            installRemoteCallback: false
        )

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    #if os(Windows)
    @Test("Windows canonical deletion ignores the real flat scheduler sidecar")
    func windowsFlatSchedulerSidecarDoesNotHideCanonicalSession() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let schedulerDirectory = fixture.home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("production-acp-root-\(UUID().uuidString)", isDirectory: true)
        let scheduler = try #require(LiveSchedulerPersistence.forSessionDirectory(schedulerDirectory))
        #expect(scheduler.stateFileURL.deletingLastPathComponent() == schedulerDirectory)
        #expect(try SessionDocumentStore(grokHome: fixture.home).list().map(\.sessionID.rawValue)
            == [ACPRemoteDeleteFixture.defaultSessionID])

        let backend = MockHTTPTransport(responses: [fixture.response()])
        let runtime = try await fixture.runtime(transport: backend)
        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: schedulerDirectory.path))
    }

    @Test("Windows still refuses an encoded workspace reparse point beside flat scheduler state")
    func windowsEncodedWorkspaceReparseStillFailsClosed() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        let directory = try await fixture.seed()
        let sessions = fixture.home.appendingPathComponent("sessions", isDirectory: true)
        let schedulerDirectory = sessions.appendingPathComponent(
            "production-acp-root-\(UUID().uuidString)", isDirectory: true
        )
        _ = try #require(LiveSchedulerPersistence.forSessionDirectory(schedulerDirectory))

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try OpenGrokConfig.createDirAllOwnerOnly(outside, stateRoot: fixture.root)
        let hostileCWD = fixture.root.appendingPathComponent("hostile-workspace").path
        let redirect = sessions.appendingPathComponent(
            OpenGrokConfig.encodeCwdDirname(hostileCWD), isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: outside)

        #expect(throws: SessionDocumentStoreError.self) {
            try SessionDocumentStore(grokHome: fixture.home).list()
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
    #endif

    @Test("the real live ACP application composes and routes authenticated writeback deletion")
    func realLiveACPCompositionRoutesRemoteDeletion() async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let targetSessionID = "production-acp-delete-\(UUID().uuidString)"
        let rootSessionID = "production-acp-root-\(UUID().uuidString)"
        let directory = try await fixture.seed(sessionID: targetSessionID)
        let backend = MockHTTPTransport(responses: [
            fixture.response(), fixture.response(), fixture.response(), fixture.response(),
        ])
        let parsed = try CLICommandParser.parseOrThrow([
            "acp",
            "--cwd", fixture.workspace.path,
            "--session-id", rootSessionID,
            "--model", "grok-4.5",
            "--storage-mode", "writeback",
        ])
        guard case .launch(let options) = parsed else {
            throw CLIApplicationError.failed("production ACP remote-delete fixture did not parse")
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "unused ACP remote-delete sampler")
                }
            },
            makeImageTransport: { backend }
        )
        let components = try await OpenGrokLiveApplicationLauncher
            .liveACPServices(dependencies: dependencies)
            .makeComponents(LiveACPLaunch(
                workingDirectory: fixture.workspace,
                openGrokHome: fixture.home,
                environment: fixture.environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                options: options
            ))
        let runtime = ACPAgentRuntime(
            promptDriver: components.promptDriver,
            extensionHandler: components.extensionHandler,
            onSessionOpened: components.onSessionOpened,
            onSessionClosed: components.onSessionClosed
        )
        do {
            guard let gateway = components.notificationGateway else {
                throw CLIApplicationError.failed("production ACP remote-delete gateway is absent")
            }
            await gateway.attach(runtime)
            let initialized = await runtime.handle(.request(
                id: .string("initialize-production-acp-remote-delete"),
                method: AgentMethodNames.initialize,
                params: try ACPRemoteDeleteJSONValue.encode(
                    InitializeRequest(protocolVersion: .v1)
                )
            ))
            guard case .response(_, _?, nil)? = initialized.last else {
                throw CLIApplicationError.failed("production ACP remote-delete failed to initialize")
            }

            #if os(Windows)
            let schedulerDirectory = fixture.home
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(rootSessionID, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: schedulerDirectory.path))
            let visible = try #require(try SessionDocumentStore(grokHome: fixture.home).load(
                sessionID: targetSessionID
            ))
            #expect(visible.summary.sessionID.rawValue == targetSessionID)
            #endif

            let (result, error) = await fixture.call(runtime, sessionID: targetSessionID)

            #expect(error == nil)
            #expect(result == .object(["success": .bool(true)]))
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            let deletion = try #require(backend.recordedRequests.first {
                $0.method == .delete && $0.url.path == "/sessions/\(targetSessionID)/data"
            })
            #expect(deletion.headers["Authorization"] == "Bearer PRIVATE_ACP_REMOTE_DELETE_TOKEN")
            #expect(deletion.headers["x-userid"] == "acp-delete-owner")
            await runtime.close()
            await components.promptDriver.shutdown()
        } catch {
            await runtime.close()
            await components.promptDriver.shutdown()
            throw error
        }
    }

    private func assertUnsuitableAccountStaysLocal(
        _ buildAccount: (ACPRemoteDeleteFixture) -> GrokAuth
    ) async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(buildAccount(fixture))
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport()
        let runtime = try await fixture.runtime(transport: backend)

        let (result, error) = await fixture.call(runtime)

        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        #expect(backend.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func assertMutationPreservesLocalArtifacts(
        status: Int = 200,
        mutation: @escaping @Sendable (ACPRemoteDeleteFixture) throws -> Void
    ) async throws {
        let fixture = try ACPRemoteDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response(status: status)])
        let transport = ACPRemoteDeleteMutatingTransport(wrapped: backend) {
            try mutation(fixture)
        }
        let runtime = try await fixture.runtime(transport: transport)

        let (result, error) = await fixture.call(runtime)

        #expect(result == nil)
        #expect(error?.code == .internalError)
        #expect(backend.recordedRequests.count == 1)
        #expect(try fixture.snapshots() == before)
    }
}
