import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import Testing

@testable import OpenGrokCLI

private struct LiveRemoteSessionDeleteFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL
    let endpoint = "http://127.0.0.1:46231"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-remote-session-delete-\(UUID().uuidString)",
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
            "GROK_CODE_BACKEND_URL": endpoint,
        ]
    }

    var authFile: URL { home.appendingPathComponent("auth.json") }

    func account(
        token: String = "PRIVATE_DELETE_FIRST_PARTY_TOKEN",
        userID: String = "session-delete-owner",
        principalID: String = "session-delete-principal",
        teamID: String = "session-delete-team",
        organizationID: String = "session-delete-organization",
        mode: AuthMode = .oidc,
        issuer: String? = xaiOAuth2Issuer,
        refreshToken: String? = "PRIVATE_DELETE_REFRESH_TOKEN",
        zeroDataRetention: Bool = false,
        optedOut: Bool = false,
        expiresAt: Date = Date().addingTimeInterval(3_600)
    ) -> GrokAuth {
        GrokAuth(
            key: token,
            authMode: mode,
            userID: userID,
            email: "delete-owner@example.invalid",
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
        sessionID: String = "remote-delete-session",
        provider: ModelProvider = .xai,
        everUsedNonXAI: Bool? = false
    ) async throws -> URL {
        var record = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: workspace
        )
        record.currentModelID = "grok-code-fast-1"
        record.currentProvider = provider
        record.everUsedNonXAI = everUsedNonXAI
        record.items = [.user("PRIVATE_DELETE_TRANSCRIPT")]
        try await LiveConversationStore(openGrokHome: home).save(record)

        let rewind = LiveRewindStore.rewindFileURL(
            openGrokHome: home,
            sessionID: sessionID
        )
        try Data("PRIVATE_REWIND_SNAPSHOT".utf8).write(to: rewind)
        let index = home.appendingPathComponent("sessions/session_search.sqlite")
        try Data("PRIVATE_FTS_INDEX".utf8).write(to: index)

        return try SessionDocumentStore(grokHome: home).sessionDirectory(
            sessionID: sessionID,
            cwd: workspace.path
        )
    }

    func snapshots(sessionID: String = "remote-delete-session") throws -> [String: Data] {
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
        error: HTTPError? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, url: url),
            body: Data("{}".utf8),
            error: error
        )
    }

    func run(
        _ sessionID: String = "remote-delete-session",
        transport: any HTTPTransport,
        overrides: [String: String] = [:],
        json: Bool = false
    ) async -> (status: Int32, output: String, errors: String) {
        var selectedEnvironment = environment
        selectedEnvironment.merge(overrides) { _, override in override }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "unused session-delete sampler")
                }
            },
            makeImageTransport: { transport }
        )
        let (streams, output, errors) = CLIStreams.buffered()
        var arguments = ["sessions", "delete", sessionID]
        if json { arguments.append("--json") }
        let status = await CLIRunner.run(
            arguments,
            environment: selectedEnvironment,
            streams: streams,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )
        return (status, output.contents, errors.contents)
    }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class LiveRemoteDeleteMutatingTransport: HTTPTransport, @unchecked Sendable {
    private let wrapped: MockHTTPTransport
    private let lock = NSLock()
    private var mutated = false
    private let mutate: @Sendable () throws -> Void

    init(
        wrapped: MockHTTPTransport,
        mutate: @escaping @Sendable () throws -> Void
    ) {
        self.wrapped = wrapped
        self.mutate = mutate
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await wrapped.send(request)
        if claimMutation() {
            try mutate()
        }
        return response
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        wrapped.stream(request)
    }

    private func claimMutation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !mutated else { return false }
        mutated = true
        return true
    }
}

@Suite("Remote-first sessions delete parity", .serialized)
struct LiveRemoteSessionDeleteParityTests {
    @Test("the real sessions command deletes its authenticated remote copy before local files")
    func deletesRemoteBeforeLocal() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let transport = LiveRemoteDeleteMutatingTransport(wrapped: backend) {
            guard FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("summary.json").path
            ) else {
                throw LiveSessionWritebackClientError.invalidResponse
            }
        }

        let result = await fixture.run(transport: transport)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output == "Deleted session remote-delete-session\n")
        #expect(result.errors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: LiveRewindStore.rewindFileURL(
            openGrokHome: fixture.home,
            sessionID: "remote-delete-session"
        ).path))
        let request = try #require(backend.recordedRequests.first)
        #expect(request.method == .delete)
        #expect(request.url.absoluteString
            == "\(fixture.endpoint)/sessions/remote-delete-session/data")
        #expect(request.headers["Authorization"] == "Bearer PRIVATE_DELETE_FIRST_PARTY_TOKEN")
        #expect(request.headers["x-userid"] == "session-delete-owner")
    }

    @Test("a remote-only successful delete is reported as a real deletion")
    func deletesRemoteOnlySession() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let backend = MockHTTPTransport(responses: [fixture.response()])

        let result = await fixture.run("remote-only-session", transport: backend)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output == "Deleted session remote-only-session\n")
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("a backend 404 still removes the local session and reports success")
    func remoteNotFoundStillDeletesLocal() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response(status: 404)])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output == "Deleted session remote-delete-session\n")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("a remote 404 and absent local files report an idempotent miss")
    func bothCopiesMissing() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let backend = MockHTTPTransport(responses: [fixture.response(status: 404)])

        let result = await fixture.run("already-deleted", transport: backend)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output == "No session found with id already-deleted.\n")
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("remote HTTP failure preserves the complete local journal, rewind, and FTS files")
    func backendFailurePreservesEveryLocalFile() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response(status: 503)])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("failed to delete remote session data"))
        #expect(result.errors.contains("503"))
        #expect(try fixture.snapshots() == before)
    }

    @Test("transport failure cannot partially delete canonical history")
    func transportFailurePreservesLocalFiles() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let failure = HTTPError.transport(TransportFailure(
            kind: .unreachable,
            detail: "isolated test backend unavailable"
        ))
        let backend = MockHTTPTransport(responses: [fixture.response(error: failure)])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(try fixture.snapshots() == before)
    }

    @Test("an unauthorized backend response never removes local history")
    func unauthorizedResponsePreservesLocalFiles() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response(status: 401)])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(try fixture.snapshots() == before)
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("a redirect response never authorizes deleting the local copy")
    func redirectPreservesLocalFiles() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response(status: 307)])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.errors.contains("redirect"))
        #expect(try fixture.snapshots() == before)
    }

    @Test("a changed final URL fails closed before local deletion")
    func finalURLMismatchPreservesLocalFiles() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response(
            url: URL(string: "https://foreign.example/sessions/private/data")
        )])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(try fixture.snapshots() == before)
    }

    @Test("foreign, localhost-DNS, and cleartext first-party endpoints receive no bearer")
    func unsafeEndpointsPreserveLocalFiles() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        for endpoint in [
            "https://foreign.example",
            "http://code.grok.com",
            "http://localhost:49876",
            "https://code.grok.com@foreign.example",
        ] {
            let backend = MockHTTPTransport()
            let result = await fixture.run(
                transport: backend,
                overrides: ["GROK_CODE_BACKEND_URL": endpoint]
            )
            #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
            #expect(result.output.isEmpty)
            #expect(backend.recordedRequests.isEmpty)
            #expect(try fixture.snapshots() == before)
        }
    }

    @Test("an unauthenticated invocation retains the existing local-only delete")
    func unauthenticatedDeletionStaysLocal() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport()

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output == "Deleted session remote-delete-session\n")
        #expect(backend.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("an API key is not a first-party session-delete credential")
    func apiKeyDeletionStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(mode: .apiKey, issuer: nil)
        }
    }

    @Test("another provider's OIDC issuer cannot authorize a backend delete")
    func foreignIssuerDeletionStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(issuer: "https://auth.openai.com")
        }
    }

    @Test("legacy web login never sends a backend bearer")
    func webLoginDeletionStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(mode: .webLogin, issuer: nil)
        }
    }

    @Test("OIDC without its refresh capability does not attempt writeback deletion")
    func nonRefreshableOIDCDeletionStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(refreshToken: nil)
        }
    }

    @Test("expired OAuth credentials cannot send a stale bearer")
    func expiredOAuthDeletionStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(expiresAt: Date().addingTimeInterval(-60))
        }
    }

    @Test("zero-data-retention teams never have remote writeback history to erase")
    func zeroDataRetentionDeletionStaysLocal() async throws {
        try await assertUnsuitableAccountStaysLocal { fixture in
            fixture.account(zeroDataRetention: true)
        }
    }

    @Test("coding-data retention opt-out alone does not disable remote deletion")
    func codingDataOptOutStillDeletesRemotely() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(optedOut: true))
        try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("a valid first-party external account may erase its cloud session")
    func firstPartyExternalAccountDeletesRemotely() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account(mode: .external, refreshToken: nil))
        try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("remote deletion remains allowed after the local provider export boundary closes")
    func crossedProviderBoundaryDoesNotPreventErasure() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed(provider: .codex, everUsedNonXAI: true)
        let backend = MockHTTPTransport(responses: [fixture.response()])

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(backend.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("CLI session deletion is independent of the current storage-mode environment")
    func currentLocalStorageModeStillDeletesRemotely() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])

        let result = await fixture.run(
            transport: backend,
            overrides: ["GROK_STORAGE_MODE": "local"]
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("JSON output reports an authenticated remote-only removal")
    func jsonRemoteOnlyDeletion() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let backend = MockHTTPTransport(responses: [fixture.response()])

        let result = await fixture.run("remote-json-session", transport: backend, json: true)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let value = try #require(
            try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        #expect(value["id"] as? String == "remote-json-session")
        #expect(value["deleted"] as? Bool == true)
    }

    @Test("changing the authenticated account during remote deletion preserves local history")
    func accountChangeDuringRequestPreservesLocalFiles() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let transport = LiveRemoteDeleteMutatingTransport(wrapped: backend) {
            try fixture.persist(fixture.account(userID: "different-delete-owner"))
        }

        let result = await fixture.run(transport: transport)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("account changed"))
        #expect(try fixture.snapshots() == before)
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("principal, team, or organization switches cannot delete another owner's local history")
    func accountScopeChangesPreserveLocalFiles() async throws {
        for changedField in ["principal", "team", "organization"] {
            let fixture = try LiveRemoteSessionDeleteFixture()
            defer { fixture.cleanup() }
            try fixture.persist(fixture.account())
            try await fixture.seed()
            let before = try fixture.snapshots()
            let backend = MockHTTPTransport(responses: [fixture.response()])
            let transport = LiveRemoteDeleteMutatingTransport(wrapped: backend) {
                switch changedField {
                case "principal":
                    try fixture.persist(fixture.account(principalID: "different-principal"))
                case "team":
                    try fixture.persist(fixture.account(teamID: "different-team"))
                default:
                    try fixture.persist(fixture.account(organizationID: "different-org"))
                }
            }

            let result = await fixture.run(transport: transport)

            #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
            #expect(try fixture.snapshots() == before)
        }
    }

    @Test("logout during the remote request does not authorize deleting local files")
    func logoutDuringRequestPreservesLocalFiles() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let transport = LiveRemoteDeleteMutatingTransport(wrapped: backend) {
            try FileManager.default.removeItem(at: fixture.authFile)
        }

        let result = await fixture.run(transport: transport)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(try fixture.snapshots() == before)
    }

    @Test("rotation to a fresh bearer for the same account remains safe")
    func sameOwnerTokenRotationStillDeletesLocalFiles() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport(responses: [fixture.response()])
        let transport = LiveRemoteDeleteMutatingTransport(wrapped: backend) {
            try fixture.persist(fixture.account(token: "PRIVATE_ROTATED_DELETE_TOKEN"))
        }

        let result = await fixture.run(transport: transport)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(backend.recordedRequests.count == 1)
    }

    @Test("the legacy synchronous runner remains a local-only, non-networking capability")
    func synchronousRunnerStaysLocalOnly() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        let directory = try await fixture.seed()
        let (streams, output, errors) = CLIStreams.buffered()

        let status = CLIRunner.main(
            ["sessions", "delete", "remote-delete-session"],
            environment: fixture.environment,
            streams: streams
        )

        #expect(status == CLIRunner.ExitCode.success.rawValue)
        #expect(output.contents == "Deleted session remote-delete-session\n")
        #expect(errors.contents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("invalid session identities are refused before authentication and backend I/O")
    func invalidSessionIdentityNeverReachesNetwork() async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(fixture.account())
        try await fixture.seed()
        let before = try fixture.snapshots()
        let backend = MockHTTPTransport()

        let result = await fixture.run("../private", transport: backend)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(backend.recordedRequests.isEmpty)
        #expect(try fixture.snapshots() == before)
    }

    private func assertUnsuitableAccountStaysLocal(
        _ buildAccount: (LiveRemoteSessionDeleteFixture) -> GrokAuth
    ) async throws {
        let fixture = try LiveRemoteSessionDeleteFixture()
        defer { fixture.cleanup() }
        try fixture.persist(buildAccount(fixture))
        let directory = try await fixture.seed()
        let backend = MockHTTPTransport()

        let result = await fixture.run(transport: backend)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output == "Deleted session remote-delete-session\n")
        #expect(backend.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
