import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokHTTP
import Testing

@testable import OpenGrokCLI

private struct LiveRemoteSessionListFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-remote-list-\(UUID().uuidString)",
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
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
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
            "GROK_CLI_CHAT_PROXY_BASE_URL": "http://127.0.0.1:46287/v1",
        ]
    }

    func authenticate(zeroDataRetention: Bool = false) throws {
        let configuration = liveManagedAuthenticationConfiguration(environment: environment)
        let account = GrokAuth(
            key: "PRIVATE_REGISTRY_USER_BEARER",
            authMode: .oidc,
            userID: "remote-list-owner",
            email: "remote-list@example.invalid",
            principalID: "remote-list-principal",
            teamID: "remote-list-team",
            organizationID: "remote-list-organization",
            teamBlockedReasons: zeroDataRetention ? ["BLOCKED_REASON_NO_LOGS"] : [],
            refreshToken: "PRIVATE_REGISTRY_REFRESH_TOKEN",
            expiresAt: Date().addingTimeInterval(3_600),
            oidcIssuer: xaiOAuth2Issuer,
            oidcClientID: defaultOAuth2ClientID
        )
        try writeAuthJSON(
            at: home.appendingPathComponent("auth.json"),
            store: [configuration.authScope: account]
        )
    }

    func remote(
        id: String,
        title: String = "Remote session summary",
        firstPrompt: String? = "remote first prompt",
        updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        repoRemoteURL: String? = nil,
        messages: Int32 = 3
    ) -> SessionReplicaResponse {
        SessionReplicaResponse(
            sessionId: id,
            summary: title,
            firstPrompt: firstPrompt,
            modelId: "grok-code-fast-1",
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt,
            lastTurnNumber: messages,
            cwd: "/remote/workspace",
            repoRemoteURL: repoRemoteURL,
            gcsTracePrefix: "",
            gcsBucket: "",
            status: "active",
            lastActiveAt: updatedAt
        )
    }

    func seedLocal(
        id: String,
        prompt: String = "Local searchable session",
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async throws {
        var record = LiveConversationRecord.new(sessionID: id, workingDirectory: workspace)
        record.createdAt = updatedAt.addingTimeInterval(-60)
        record.updatedAt = updatedAt
        record.items = [.user(prompt)]
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func response(
        sessions: [SessionReplicaResponse],
        status: Int = 200,
        finalURL: URL? = nil
    ) throws -> MockHTTPTransport.ScriptedResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, url: finalURL),
            body: try encoder.encode(SearchSessionsResponse(sessions: sessions))
        )
    }

    func run(
        _ arguments: [String],
        transport: any HTTPTransport,
        overrides: [String: String] = [:]
    ) async -> (status: Int32, output: String, errors: String) {
        var selectedEnvironment = environment
        selectedEnvironment.merge(overrides) { _, value in value }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "unused session-registry sampler")
                }
            },
            makeImageTransport: { transport }
        )
        let (streams, output, errors) = CLIStreams.buffered()
        let status = await CLIRunner.run(
            ["--cwd", workspace.path] + arguments,
            environment: selectedEnvironment,
            streams: streams,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )
        return (status, output.contents, errors.contents)
    }

    func decodedRows(_ output: String) throws -> [[String: Any]] {
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func configureRepository(remote: String) throws {
        let git = workspace.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
        try Data("[remote \"origin\"]\n\turl = \(remote)\n".utf8)
            .write(to: git.appendingPathComponent("config"))
        try Data("ref: refs/heads/main\n".utf8)
            .write(to: git.appendingPathComponent("HEAD"))
    }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live first-party remote session registry", .serialized)
struct LiveRemoteSessionListIntegrationParityTests {
    @Test("real sessions list fetches the distinct registry and marks remote rows")
    func listIncludesRemoteRegistrySession() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        let backend = MockHTTPTransport(responses: [try fixture.response(sessions: [
            fixture.remote(id: "remote-registry-only"),
        ])])

        let result = await fixture.run(["sessions", "list", "--json"], transport: backend)
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        let rows = try fixture.decodedRows(result.output)
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == "remote-registry-only")
        #expect(rows.first?["source"] as? String == "remote")

        let request = try #require(backend.recordedRequests.first)
        #expect(request.method == .get)
        #expect(request.url.path == "/v1/sessions/search")
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(URLQueryItem(name: "limit", value: "100")) == true)
        #expect(request.headers["Authorization"] == "Bearer PRIVATE_REGISTRY_USER_BEARER")
        #expect(request.headers[xaiTokenAuthHeader] == xaiTokenAuthValue)
    }

    @Test("remote metadata merges into the same local session instead of duplicating it")
    func remoteAndLocalSessionMergeOnce() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        try await fixture.seedLocal(id: "shared-session", prompt: "Old local session")
        let backend = MockHTTPTransport(responses: [try fixture.response(sessions: [
            fixture.remote(id: "shared-session", title: "New remote summary", messages: 8),
        ])])

        let result = await fixture.run(["sessions", "list", "--json"], transport: backend)
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let rows = try fixture.decodedRows(result.output)
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == "shared-session")
        #expect(rows.first?["source"] as? String == "both")
        #expect(rows.first?["title"] as? String == "New remote summary")
    }

    @Test("deployment credentials override user tokens and ZDR does not hide registry reads")
    func deploymentAuthorizationAndZDRParity() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate(zeroDataRetention: true)
        let backend = MockHTTPTransport(responses: [try fixture.response(sessions: [
            fixture.remote(id: "deployment-session"),
        ])])

        let result = await fixture.run(
            ["sessions", "list", "--json"],
            transport: backend,
            overrides: ["GROK_DEPLOYMENT_KEY": "PRIVATE_REGISTRY_DEPLOYMENT_KEY"]
        )
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("deployment-session"))
        let request = try #require(backend.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer PRIVATE_REGISTRY_DEPLOYMENT_KEY")
        #expect(request.headers[xaiTokenAuthHeader] == nil)
    }

    @Test("unauthenticated list remains local without any outbound registry request")
    func unauthenticatedListStaysLocal() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try await fixture.seedLocal(id: "anonymous-local")
        let backend = MockHTTPTransport()

        let result = await fixture.run(["sessions", "list", "--json"], transport: backend)
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        #expect(result.output.contains("anonymous-local"))
        #expect(backend.recordedRequests.isEmpty)
    }

    @Test("registry failures retain complete local results and warn without leaking credentials")
    func failedRegistryFallsBackLocally() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        try await fixture.seedLocal(id: "preserved-local")
        let backend = MockHTTPTransport(responses: [try fixture.response(sessions: [], status: 503)])

        let result = await fixture.run(["sessions", "list", "--json"], transport: backend)
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("preserved-local"))
        #expect(result.errors.contains("remote session search failed"))
        #expect(!result.errors.contains("PRIVATE_REGISTRY_USER_BEARER"))
    }

    @Test("a redirected registry response preserves local results without exposing credentials")
    func redirectedRegistryFallsBackLocally() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        try await fixture.seedLocal(id: "redirect-preserved-local")
        let backend = MockHTTPTransport(responses: [try fixture.response(
            sessions: [fixture.remote(id: "redirect-must-not-render")],
            finalURL: URL(string: "https://attacker.example/v1/sessions/search?limit=100")
        )])

        let result = await fixture.run(["sessions", "list", "--json"], transport: backend)
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("redirect-preserved-local"))
        #expect(!result.output.contains("redirect-must-not-render"))
        #expect(result.errors.contains("remote session search failed"))
        #expect(!result.errors.contains("PRIVATE_REGISTRY_USER_BEARER"))
    }

    @Test("remote search labels results, deduplicates local ids, and caps prompt snippets")
    func searchMergesRemoteWithoutDuplicates() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        try await fixture.seedLocal(id: "local-search-hit", prompt: "exact-registry-needle local")
        let backend = MockHTTPTransport(responses: [try fixture.response(sessions: [
            fixture.remote(id: "local-search-hit", title: "Duplicate remote"),
            fixture.remote(
                id: "unique-remote-hit",
                title: "Remote exact-registry-needle",
                firstPrompt: String(repeating: "r", count: 120)
            ),
        ])])

        let result = await fixture.run(
            ["sessions", "search", "exact-registry-needle"],
            transport: backend
        )
        #expect(result.errors.isEmpty)
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("local-search-hit (score:"))
        #expect(result.output.contains("unique-remote-hit (remote)"))
        #expect(!result.output.contains("local-search-hit (remote)"))
        #expect(result.output.contains(String(repeating: "r", count: 80)))
        #expect(!result.output.contains(String(repeating: "r", count: 81)))
        #expect(result.output.contains("Total: 2"))
    }

    @Test("identical repository paths on another Git host never enter the local session list")
    func repositoryHostIsolationFiltersRemoteSessions() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        try fixture.configureRepository(remote: "git@github.com:example/project.git")
        let backend = MockHTTPTransport(responses: [try fixture.response(sessions: [
            fixture.remote(
                id: "github-safe-session",
                repoRemoteURL: "https://github.com/example/project"
            ),
            fixture.remote(
                id: "gitlab-host-collision",
                repoRemoteURL: "https://gitlab.com/example/project"
            ),
        ])])

        let result = await fixture.run(["sessions", "list", "--json"], transport: backend)
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("github-safe-session"))
        #expect(!result.output.contains("gitlab-host-collision"))
    }

    @Test("zero list limits never contact the remote registry")
    func zeroLimitDoesNotSendCredentials() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        let backend = MockHTTPTransport()

        let result = await fixture.run(
            ["sessions", "list", "-n", "0", "--json"],
            transport: backend
        )
        #expect(result.status == CLIRunner.ExitCode.usage.rawValue)
        #expect(result.errors.contains("a positive integer"))
        #expect(backend.recordedRequests.isEmpty)
    }

    @Test("blank search queries fail before disclosing authentication to the remote registry")
    func blankSearchDoesNotSendCredentials() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        let backend = MockHTTPTransport()

        let result = await fixture.run(["sessions", "search", "   "], transport: backend)
        #expect(result.status != CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.contains("sessions search requires a query"))
        #expect(backend.recordedRequests.isEmpty)
    }

    @Test("ZDR user credentials can read remote metadata without enabling transcript writeback")
    func zeroDataRetentionUserMayReadMetadata() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate(zeroDataRetention: true)
        let backend = MockHTTPTransport(responses: [try fixture.response(sessions: [
            fixture.remote(id: "zdr-registry-metadata"),
        ])])

        let result = await fixture.run(["sessions", "list", "--json"], transport: backend)
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("zdr-registry-metadata"))
        let request = try #require(backend.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer PRIVATE_REGISTRY_USER_BEARER")
        #expect(request.headers[xaiTokenAuthHeader] == xaiTokenAuthValue)
    }

    @Test("the registry proxy is never replaced by the writeback backend")
    func registryAuthorityIsNotWritebackAuthority() async throws {
        let fixture = try LiveRemoteSessionListFixture()
        defer { fixture.cleanup() }
        try fixture.authenticate()
        let backend = MockHTTPTransport(responses: [try fixture.response(sessions: [
            fixture.remote(id: "independent-registry-session"),
        ])])

        let result = await fixture.run(
            ["sessions", "list", "--json"],
            transport: backend,
            overrides: ["GROK_CODE_BACKEND_URL": "https://code.grok.com"]
        )
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(backend.recordedRequests.first)
        #expect(request.url.host == "127.0.0.1")
        #expect(request.url.path == "/v1/sessions/search")
    }
}
