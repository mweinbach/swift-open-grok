import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokHTTP
import Testing

@testable import OpenGrokCLI

private struct SessionRegistryClientFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-session-registry-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(root, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        #else
        for directory in [root, home] {
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
        ]
    }

    func account(
        key: String = "registry-first-party-token",
        userID: String = "registry-user",
        principalID: String? = "registry-principal",
        teamID: String? = "registry-team",
        organizationID: String? = "registry-organization",
        mode: AuthMode = .oidc,
        issuer: String? = "https://auth.x.ai",
        blockedReasons: [String] = [],
        optedOut: Bool = false,
        expiresAt: Date? = Date().addingTimeInterval(3_600)
    ) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: mode,
            userID: userID,
            email: "registry@example.test",
            principalID: principalID,
            teamID: teamID,
            organizationID: organizationID,
            teamBlockedReasons: blockedReasons,
            codingDataRetentionOptOut: optedOut,
            refreshToken: mode == .oidc ? "registry-refresh-token" : nil,
            expiresAt: expiresAt,
            oidcIssuer: issuer,
            oidcClientID: "registry-client"
        )
    }

    @discardableResult
    func install(_ account: GrokAuth) async throws -> AuthManager {
        let manager = AuthManager(
            grokHome: home,
            config: liveManagedAuthenticationConfiguration(environment: environment),
            environment: environment
        )
        try await manager.loginWithSession(account)
        return manager
    }

    func client(
        transport: MockHTTPTransport,
        overrides: [String: String] = [:],
        authManager: AuthManager? = nil
    ) throws -> LiveSessionRegistryClient {
        var resolved = environment
        resolved.merge(overrides) { _, override in override }
        if let authManager {
            return try LiveSessionRegistryClient(
                home: home,
                environment: resolved,
                transport: transport,
                authManager: authManager
            )
        }
        return try LiveSessionRegistryClient(
            home: home,
            environment: resolved,
            transport: transport
        )
    }

    func record(
        id: String = "registry-session",
        summary: String = "Remote session",
        createdAt: String = "2026-08-25T12:00:00.123Z",
        updatedAt: String = "2026-08-25T12:05:00Z"
    ) -> [String: Any] {
        [
            "sessionId": id,
            "summary": summary,
            "firstPrompt": "first remote prompt",
            "modelId": "grok-code-fast-1",
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "lastTurnNumber": 3,
            "restorableTurnNumber": 2,
            "cwd": "/remote/workspace",
            "repoRemoteUrl": "git@github.com:org/repo.git",
            "hostname": "remote-machine",
            "status": "active",
            "gcsTracePrefix": "sessions/registry-session",
            "gcsBucket": "grok-traces",
            "lastActiveAt": "2026-08-25T12:06:00.456Z",
        ]
    }

    func response(
        status: Int = 200,
        body: Data = Data(#"{"sessions":[]}"#.utf8),
        url: URL? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, url: url),
            body: body
        )
    }

    func response(records: [[String: Any]]) throws -> MockHTTPTransport.ScriptedResponse {
        response(body: try JSONSerialization.data(withJSONObject: ["sessions": records]))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("first-party session registry HTTP parity", .serialized)
struct LiveSessionRegistryClientParityTests {
    @Test("default proxy issues the exact registry path with Rust overfetch and OAuth headers")
    func searchesDefaultProxy() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [
            try fixture.response(records: [fixture.record()]),
        ])
        let client = try fixture.client(transport: transport)

        let sessions = try await client.search(query: nil, limit: 20)

        let request = try #require(transport.recordedRequests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://cli-chat-proxy.grok.com/v1/sessions/search?limit=100")
        #expect(request.headers["Authorization"] == "Bearer registry-first-party-token")
        #expect(request.headers[xaiTokenAuthHeader] == xaiTokenAuthValue)
        #expect(request.timeout == 5)
        #expect(request.idempotency == .idempotent)
        let session = try #require(sessions.first)
        #expect(session.sessionId == "registry-session")
        #expect(session.repoRemoteURL == "git@github.com:org/repo.git")
        #expect(session.restorableTurnNumber == 2)
        #expect(session.lastActiveAt != nil)
    }

    @Test("query bytes are encoded without allowing plus, ampersand, or parameter injection")
    func percentEncodesQuery() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport)
        let query = "branch+fix &limit=999/# 🚀"

        let sessions = try await client.search(query: query, limit: 50)

        #expect(sessions.isEmpty)
        let request = try #require(transport.recordedRequests.first)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.count == 2)
        #expect(components.queryItems?.first?.value == "150")
        #expect(components.queryItems?.last?.value == query)
        #expect(request.url.absoluteString.contains("branch%2Bfix%20%26limit%3D999%2F%23"))
    }

    @Test("nil search query omits the query parameter entirely")
    func omitsAbsentQuery() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response()])

        let sessions = try await fixture.client(transport: transport).search(query: nil, limit: 34)

        #expect(sessions.isEmpty)
        #expect(transport.recordedRequests.first?.url.query == "limit=102")
    }

    @Test("deployment credentials work without user auth and never receive token-auth headers")
    func authorizesDeploymentOnly() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(
            transport: transport,
            overrides: [
                "GROK_DEPLOYMENT_KEY": "enterprise-deployment-secret",
                "GROK_CLI_CHAT_PROXY_BASE_URL": "https://managed.example.test/custom/v1",
            ]
        )

        let sessions = try await client.search(query: nil, limit: 10)

        #expect(sessions.isEmpty)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.url.absoluteString == "https://managed.example.test/custom/v1/sessions/search?limit=100")
        #expect(request.headers["Authorization"] == "Bearer enterprise-deployment-secret")
        #expect(request.headers[xaiTokenAuthHeader] == nil)
    }

    @Test("deployment credentials always outrank a simultaneously available xAI account")
    func deploymentWinsOverAccount() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(
            transport: transport,
            overrides: ["GROK_DEPLOYMENT_KEY": "winning-deployment-secret"]
        )

        let sessions = try await client.search(query: nil, limit: 1)

        #expect(sessions.isEmpty)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer winning-deployment-secret")
        #expect(request.headers[xaiTokenAuthHeader] == nil)
    }

    @Test("explicit managed HTTPS proxies are honored without using inference endpoints")
    func honorsManagedProxy() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(
            transport: transport,
            overrides: [
                "GROK_CLI_CHAT_PROXY_BASE_URL": "https://enterprise.example.test:9443/team/v1/",
                "GROK_XAI_API_BASE_URL": "https://inference.example.test/v1",
            ]
        )

        let sessions = try await client.search(query: nil, limit: 20)

        #expect(sessions.isEmpty)
        #expect(
            transport.recordedRequests.first?.url.absoluteString
                == "https://enterprise.example.test:9443/team/v1/sessions/search?limit=100"
        )
    }

    @Test("the inference base URL can never silently replace the registry proxy")
    func ignoresInferenceBaseURL() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(
            transport: transport,
            overrides: ["GROK_XAI_API_BASE_URL": "https://attacker.example.test/v1"]
        )

        let sessions = try await client.search(query: nil, limit: 5)

        #expect(sessions.isEmpty)
        #expect(transport.recordedRequests.first?.url.host == "cli-chat-proxy.grok.com")
    }

    @Test("unsafe proxy schemes, userinfo, DNS loopback, suffixes, and traversal fail before auth")
    func rejectsUnsafeEndpoints() throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        let endpoints = [
            "http://enterprise.example.test/v1",
            "http://localhost:8080/v1",
            "https://localhost/v1",
            "https://user:password@managed.example.test/v1",
            "https://managed.example.test/v1?leak=1",
            "https://managed.example.test/v1#redirect",
            "ftp://managed.example.test/v1",
            "https://managed.example.test/v1%2fprivate",
            "https://managed.example.test/v1%5cprivate",
            "https://managed.example.test/v1/../private",
        ]

        for endpoint in endpoints {
            let transport = MockHTTPTransport()
            #expect(throws: LiveSessionRegistryClientError.invalidEndpoint) {
                try fixture.client(
                    transport: transport,
                    overrides: ["GROK_CLI_CHAT_PROXY_BASE_URL": endpoint]
                )
            }
            #expect(transport.recordedRequests.isEmpty)
        }
    }

    @Test("explicit literal IPv4 loopback is the only cleartext integration seam")
    func acceptsExplicitLiteralLoopback() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(
            transport: transport,
            overrides: ["GROK_CLI_CHAT_PROXY_BASE_URL": "http://127.0.0.1:18765/v1"]
        )

        let sessions = try await client.search(query: nil, limit: 20)

        #expect(sessions.isEmpty)
        #expect(transport.recordedRequests.first?.url.host == "127.0.0.1")
    }

    @Test("explicit literal IPv6 loopback is accepted without trusting DNS localhost")
    func acceptsExplicitIPv6Loopback() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(
            transport: transport,
            overrides: ["GROK_CLI_CHAT_PROXY_BASE_URL": "http://[::1]:18765/v1"]
        )

        let sessions = try await client.search(query: nil, limit: 20)

        #expect(sessions.isEmpty)
        #expect(transport.recordedRequests.first?.url.absoluteString.hasPrefix("http://[::1]:18765/") == true)
    }

    @Test("missing credentials produce explicit unavailable and never touch transport")
    func rejectsMissingCredentialsWithoutNetworking() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        let transport = MockHTTPTransport()
        let client = try fixture.client(transport: transport)

        await #expect(throws: LiveSessionRegistryClientError.unavailable) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("API-key credentials never become registry session bearers")
    func rejectsAPIKeysWithoutNetworking() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        let transport = MockHTTPTransport()
        let client = try fixture.client(
            transport: transport,
            overrides: ["XAI_API_KEY": "private-inference-api-key"]
        )

        await #expect(throws: LiveSessionRegistryClientError.unavailable) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("control characters in deployment or OAuth bearers never become HTTP headers")
    func rejectsHeaderInjectionBearers() async throws {
        let deploymentFixture = try SessionRegistryClientFixture()
        defer { deploymentFixture.cleanup() }
        let deploymentTransport = MockHTTPTransport()
        let deploymentClient = try deploymentFixture.client(
            transport: deploymentTransport,
            overrides: ["GROK_DEPLOYMENT_KEY": "secret\r\nInjected: unsafe"]
        )
        await #expect(throws: LiveSessionRegistryClientError.unavailable) {
            try await deploymentClient.search(query: nil, limit: 20)
        }
        #expect(deploymentTransport.recordedRequests.isEmpty)

        let accountFixture = try SessionRegistryClientFixture()
        defer { accountFixture.cleanup() }
        try await accountFixture.install(accountFixture.account(key: "secret\r\nInjected: unsafe"))
        let accountTransport = MockHTTPTransport()
        let accountClient = try accountFixture.client(transport: accountTransport)
        await #expect(throws: LiveSessionRegistryClientError.unavailable) {
            try await accountClient.search(query: nil, limit: 20)
        }
        #expect(accountTransport.recordedRequests.isEmpty)
    }

    @Test("foreign OAuth issuers never cross the first-party registry boundary")
    func rejectsForeignOAuthIssuer() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account(issuer: "https://issuer.attacker.example"))
        let transport = MockHTTPTransport()
        let client = try fixture.client(transport: transport)

        await #expect(throws: LiveSessionRegistryClientError.unavailable) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("valid xAI external credentials are accepted without a refresh token")
    func acceptsFirstPartyExternalAccount() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account(mode: .external))
        let transport = MockHTTPTransport(responses: [fixture.response()])

        let sessions = try await fixture.client(transport: transport).search(query: nil, limit: 20)

        #expect(sessions.isEmpty)
        #expect(transport.recordedRequests.first?.headers[xaiTokenAuthHeader] == xaiTokenAuthValue)
    }

    @Test("ZDR teams and coding-data opt-out remain eligible for metadata-only registry reads")
    func permitsZDRAndOptOut() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(
            fixture.account(blockedReasons: ["BLOCKED_REASON_NO_LOGS"], optedOut: true)
        )
        let transport = MockHTTPTransport(responses: [fixture.response()])

        let sessions = try await fixture.client(transport: transport).search(query: nil, limit: 20)

        #expect(sessions.isEmpty)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("expired xAI access tokens never leave the process")
    func rejectsExpiredAccount() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account(expiresAt: Date().addingTimeInterval(-60)))
        let transport = MockHTTPTransport()
        let client = try fixture.client(transport: transport)

        await #expect(throws: LiveSessionRegistryClientError.unavailable) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("same-account durable token rotation is adopted before the next registry request")
    func adoptsSameAccountRotation() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response(), fixture.response()])
        let client = try fixture.client(transport: transport)

        let first = try await client.search(query: nil, limit: 20)
        #expect(first.isEmpty)
        try await fixture.install(fixture.account(key: "rotated-registry-token"))
        let second = try await client.search(query: nil, limit: 20)
        #expect(second.isEmpty)

        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].headers["Authorization"] == "Bearer registry-first-party-token")
        #expect(transport.recordedRequests[1].headers["Authorization"] == "Bearer rotated-registry-token")
    }

    @Test("changing account identity permanently closes the registry client")
    func rejectsAccountSwitch() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response(), fixture.response()])
        let client = try fixture.client(transport: transport)

        let first = try await client.search(query: nil, limit: 20)
        #expect(first.isEmpty)
        try await fixture.install(fixture.account(userID: "different-registry-user"))

        await #expect(throws: LiveSessionRegistryClientError.accountChanged) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.count == 1)

        try await fixture.install(fixture.account())
        await #expect(throws: LiveSessionRegistryClientError.accountChanged) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("principal, team, and organization changes are account changes even with the same user")
    func rejectsTenantSwitch() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response(), fixture.response()])
        let client = try fixture.client(transport: transport)

        let first = try await client.search(query: nil, limit: 20)
        #expect(first.isEmpty)
        try await fixture.install(fixture.account(teamID: "other-registry-team"))

        await #expect(throws: LiveSessionRegistryClientError.accountChanged) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("logout between registry requests never reuses a stale cached bearer")
    func rejectsLogout() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response(), fixture.response()])
        let client = try fixture.client(transport: transport)

        let first = try await client.search(query: nil, limit: 20)
        #expect(first.isEmpty)
        let sibling = AuthManager(
            grokHome: fixture.home,
            config: liveManagedAuthenticationConfiguration(environment: fixture.environment),
            environment: fixture.environment
        )
        let outcome = try await sibling.clear()
        #expect(outcome.wasLoggedIn)

        await #expect(throws: LiveSessionRegistryClientError.unavailable) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("an OAuth 401 performs exactly one changed-token refresh and idempotent replay")
    func retriesUnauthorizedOnce() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        let original = fixture.account()
        let manager = try await fixture.install(original)
        var refreshed = original
        refreshed.key = "refreshed-registry-token"
        let refresher = MockTokenRefresher(outcome: .success(refreshed))
        await manager.configureRefresher(refresher)
        let transport = MockHTTPTransport(responses: [
            fixture.response(status: 401),
            fixture.response(),
        ])
        let client = try fixture.client(transport: transport, authManager: manager)

        let sessions = try await client.search(query: nil, limit: 20)

        #expect(sessions.isEmpty)
        #expect(refresher.callCountBox.count == 1)
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[1].headers["Authorization"] == "Bearer refreshed-registry-token")
    }

    @Test("unchanged or rejected OAuth refresh never replays the same bearer")
    func refusesUnchangedUnauthorizedReplay() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        let original = fixture.account()
        let manager = try await fixture.install(original)
        let refresher = MockTokenRefresher(outcome: .success(original))
        await manager.configureRefresher(refresher)
        let transport = MockHTTPTransport(responses: [fixture.response(status: 401)])
        let client = try fixture.client(transport: transport, authManager: manager)

        await #expect(throws: LiveSessionRegistryClientError.requestFailed(status: 401)) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(refresher.callCountBox.count == 1)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("a deployment-key 401 is never replayed or refreshed")
    func neverRetriesDeploymentUnauthorized() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        let transport = MockHTTPTransport(responses: [fixture.response(status: 401)])
        let client = try fixture.client(
            transport: transport,
            overrides: ["GROK_DEPLOYMENT_KEY": "rejected-deployment-secret"]
        )

        await #expect(throws: LiveSessionRegistryClientError.requestFailed(status: 401)) {
            try await client.search(query: nil, limit: 20)
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("redirect responses and altered final URLs are rejected")
    func rejectsRedirectsAndFinalURLMismatch() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let redirects = [
            fixture.response(status: 302),
            fixture.response(url: URL(string: "https://attacker.example.test/v1/sessions/search?limit=100")),
        ]

        for scripted in redirects {
            let transport = MockHTTPTransport(responses: [scripted])
            let client = try fixture.client(transport: transport)
            await #expect(throws: LiveSessionRegistryClientError.redirectRejected) {
                try await client.search(query: nil, limit: 20)
            }
            #expect(transport.recordedRequests.count == 1)
        }
    }

    @Test("malformed response bodies and invalid RFC3339 timestamps are refused")
    func rejectsMalformedResponses() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let malformed = [
            fixture.response(body: Data("not-json".utf8)),
            try fixture.response(records: [fixture.record(createdAt: "yesterday")]),
            try fixture.response(records: [fixture.record(updatedAt: "2026-08-25")]),
        ]

        for scripted in malformed {
            let transport = MockHTTPTransport(responses: [scripted])
            let client = try fixture.client(transport: transport)
            await #expect(throws: LiveSessionRegistryClientError.invalidResponse) {
                try await client.search(query: nil, limit: 20)
            }
        }
    }

    @Test("unsafe session identities and terminal-control metadata are refused")
    func rejectsHostileSessionMetadata() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        var hostileTitle = fixture.record()
        hostileTitle["summary"] = "forged\nsecond row"
        var hostileHostname = fixture.record()
        hostileHostname["hostname"] = "\u{001b}[31mattacker"
        var hostileParent = fixture.record()
        hostileParent["parentSessionId"] = "../cross-account"
        let records = [
            fixture.record(id: "../escape"),
            fixture.record(id: "unsafe\nidentity"),
            hostileTitle,
            hostileHostname,
            hostileParent,
        ]

        for record in records {
            let transport = MockHTTPTransport(responses: [try fixture.response(records: [record])])
            let client = try fixture.client(transport: transport)
            await #expect(throws: LiveSessionRegistryClientError.invalidResponse) {
                try await client.search(query: nil, limit: 20)
            }
        }
    }

    @Test("oversized response bodies and over-returned registry rows fail closed")
    func rejectsOversizedResponses() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let oversized = MockHTTPTransport(responses: [
            fixture.response(body: Data(repeating: 0x20, count: LiveSessionRegistryClient.maximumResponseBytes + 1)),
        ])
        let oversizedClient = try fixture.client(transport: oversized)
        await #expect(throws: LiveSessionRegistryClientError.responseTooLarge) {
            try await oversizedClient.search(query: nil, limit: 20)
        }

        let rows = (0..<101).map { fixture.record(id: "registry-session-\($0)") }
        let excessiveRows = MockHTTPTransport(responses: [try fixture.response(records: rows)])
        let excessiveRowsClient = try fixture.client(transport: excessiveRows)
        await #expect(throws: LiveSessionRegistryClientError.responseTooLarge) {
            try await excessiveRowsClient.search(query: nil, limit: 20)
        }
    }

    @Test("oversized remote metadata fields are rejected before any renderer sees them")
    func rejectsOversizedFields() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let record = fixture.record(
            summary: String(repeating: "r", count: LiveSessionRegistryClient.maximumFieldBytes + 1)
        )
        let transport = MockHTTPTransport(responses: [try fixture.response(records: [record])])
        let client = try fixture.client(transport: transport)

        await #expect(throws: LiveSessionRegistryClientError.invalidResponse) {
            try await client.search(query: nil, limit: 20)
        }
    }

    @Test("invalid limits and oversized queries fail before credential resolution or networking")
    func boundsRequests() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        let transport = MockHTTPTransport()
        let client = try fixture.client(transport: transport)

        for limit in [-1, Int.max, LiveSessionRegistryClient.maximumSessionCount] {
            await #expect(throws: LiveSessionRegistryClientError.invalidLimit) {
                try await client.search(query: nil, limit: limit)
            }
        }
        let oversized = String(repeating: "x", count: LiveSessionRegistryClient.maximumQueryBytes + 1)
        await #expect(throws: LiveSessionRegistryClientError.invalidQuery) {
            try await client.search(query: oversized, limit: 20)
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("HTTP failures reveal only their status, never bearer tokens or server bodies")
    func sanitizesHTTPFailure() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [
            fixture.response(status: 503, body: Data("private-registry-response".utf8)),
        ])
        let client = try fixture.client(transport: transport)

        do {
            let sessions = try await client.search(query: nil, limit: 20)
            Issue.record("unexpected registry success with \(sessions.count) sessions")
        } catch let error as LiveSessionRegistryClientError {
            #expect(error == .requestFailed(status: 503))
            #expect(!error.description.contains("private-registry-response"))
            #expect(!error.description.contains("registry-first-party-token"))
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("underlying transport diagnostics cannot leak tokens or search contents")
    func sanitizesTransportFailure() async throws {
        let fixture = try SessionRegistryClientFixture()
        defer { fixture.cleanup() }
        try await fixture.install(fixture.account())
        let transport = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                error: .transport(
                    TransportFailure(
                        kind: .permanent,
                        detail: "Bearer registry-first-party-token private-user-query"
                    )
                )
            ),
        ])
        let client = try fixture.client(transport: transport)

        do {
            let sessions = try await client.search(query: "private-user-query", limit: 20)
            Issue.record("unexpected registry success with \(sessions.count) sessions")
        } catch let error as LiveSessionRegistryClientError {
            #expect(error == .transportFailed)
            #expect(!error.description.contains("registry-first-party-token"))
            #expect(!error.description.contains("private-user-query"))
        }
        #expect(transport.recordedRequests.count == 1)
    }
}
