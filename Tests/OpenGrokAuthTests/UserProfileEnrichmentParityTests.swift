import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenGrokHTTP
import OpenGrokVersion
import Testing
@testable import OpenGrokAuth

private enum UserProfileParityTransportOutcome: Sendable {
    case response(status: Int, body: Data)
    case unreachable
    case cancelled
}

private struct UserProfileParityTransportSnapshot: Sendable {
    var requests: [HTTPRequest]
    var authFileExistedDuringProfileFetch: Bool?
}

private final class UserProfileParityTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: UserProfileParityTransportOutcome
    private let browserAccessToken: String?
    private let authFile: URL?
    private var requests: [HTTPRequest] = []
    private var authFileExistedDuringProfileFetch: Bool?

    init(
        outcome: UserProfileParityTransportOutcome,
        browserAccessToken: String? = nil,
        authFile: URL? = nil
    ) {
        self.outcome = outcome
        self.browserAccessToken = browserAccessToken
        self.authFile = authFile
    }

    var snapshot: UserProfileParityTransportSnapshot {
        lock.withLock {
            UserProfileParityTransportSnapshot(
                requests: requests,
                authFileExistedDuringProfileFetch: authFileExistedDuringProfileFetch
            )
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock {
            requests.append(request)
            if request.url.path.hasSuffix("/user"), let authFile {
                authFileExistedDuringProfileFetch =
                    FileManager.default.fileExists(atPath: authFile.path)
            }
        }

        if browserAccessToken != nil,
           request.url.path.hasSuffix("/.well-known/openid-configuration") {
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(#"{"issuer":"https://auth.x.ai","authorization_endpoint":"https://auth.x.ai/authorize","token_endpoint":"https://auth.x.ai/oauth2/token"}"#.utf8)
            )
        }
        if let browserAccessToken, request.url.path.hasSuffix("/oauth2/token") {
            let body = try JSONSerialization.data(withJSONObject: [
                "access_token": browserAccessToken,
                "refresh_token": "browser-rotated-refresh-token",
                "expires_in": 3600,
            ])
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: body
            )
        }

        switch outcome {
        case .response(let status, let body):
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: status),
                body: body
            )
        case .unreachable:
            throw HTTPError.transport(
                TransportFailure(kind: .unreachable, detail: "hermetic proxy unavailable")
            )
        case .cancelled:
            throw HTTPError.cancelled
        }
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: HTTPError.invalidURL(request.url.absoluteString))
        }
    }
}

private func userProfileParityAuth(
    principal: String = "team-allowed",
    issuer: String = xaiOAuth2Issuer,
    clientID: String = defaultOAuth2ClientID
) -> GrokAuth {
    GrokAuth(
        key: buildTestJWT(payload: [
            "sub": "oauth-subject",
            "principal_type": "Team",
            "principal_id": principal,
            "exp": 9_999_999_999,
        ]),
        authMode: .oidc,
        userID: "original-user",
        email: "original@x.ai",
        firstName: "Original",
        lastName: "Name",
        profileImageAssetID: "original-image",
        principalType: "Team",
        principalID: principal,
        teamID: principal,
        teamName: "Original Team",
        teamRole: "member",
        organizationID: "original-org",
        organizationName: "Original Org",
        organizationRole: "reader",
        userBlockedReason: "original-block",
        teamBlockedReasons: ["ORIGINAL_REASON"],
        codingDataRetentionOptOut: true,
        refreshToken: "original-refresh-token",
        expiresAt: Date().addingTimeInterval(3600),
        oidcIssuer: issuer,
        oidcClientID: clientID
    )
}

private func userProfileParityHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("open-grok-user-profile-parity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func userProfileParityData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

enum UserProfileMalformedResponse: String, CaseIterable, Sendable {
    case invalidJSON
    case missingUser
    case emptyUser
    case rejected

    fileprivate var outcome: UserProfileParityTransportOutcome {
        switch self {
        case .invalidJSON:
            return .response(status: 200, body: Data("not-json".utf8))
        case .missingUser:
            return .response(status: 200, body: Data(#"{"teamId":"different"}"#.utf8))
        case .emptyUser:
            return .response(status: 200, body: Data(#"{"userId":"","codingDataRetentionOptOut":false}"#.utf8))
        case .rejected:
            return .response(status: 503, body: Data(#"{"userId":"must-not-merge"}"#.utf8))
        }
    }
}

@Suite("xAI post-login user-profile and privacy parity", .serialized)
struct UserProfileEnrichmentParityTests {
    @Test("trusted proxy request carries the authenticated xAI wire contract")
    func requestAndCompleteProfileMatchPinnedRust() async throws {
        var config = GrokComConfig.default(environment: [:])
        config.tokenHeader = "managed-token-header"
        let auth = userProfileParityAuth()
        let body = try userProfileParityData([
            "userId": "resolved-user",
            "email": "resolved@x.ai",
            "firstName": "Resolved",
            "lastName": "Person",
            "profileImageAssetId": "resolved-image",
            "principalType": "Team",
            "principalId": "team-allowed",
            "teamId": "team-allowed",
            "teamName": "Resolved Team",
            "teamRole": "owner",
            "organizationId": "resolved-org",
            "organizationName": "Resolved Org",
            "organizationRole": "admin",
            "userBlockedReason": "resolved-block",
            "teamBlockedReasons": ["BLOCKED_REASON_NO_LOGS"],
            "codingDataRetentionOptOut": true,
        ])
        let transport = UserProfileParityTransport(outcome: .response(status: 200, body: body))
        let environment = [
            "GROK_CLI_CHAT_PROXY_BASE_URL": "https://enterprise-proxy.example/v1/"
        ]

        let enriched = try await enrichXAIUserProfile(
            auth: auth,
            configuration: config,
            environment: environment,
            transport: transport
        )

        let snapshot = transport.snapshot
        #expect(snapshot.requests.count == 1)
        let request = try #require(snapshot.requests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://enterprise-proxy.example/v1/user")
        #expect(request.headers["Authorization"] == "Bearer \(auth.key)")
        #expect(request.headers[xaiTokenAuthHeader] == "managed-token-header")
        #expect(request.headers["x-grok-client-version"] == OpenGrokVersion.compiledVersion)
        #expect(request.headers[clientModeHeader] == "interactive")
        #expect(request.timeout == 10)
        #expect(request.idempotency == .idempotent)

        #expect(enriched.userID == "resolved-user")
        #expect(enriched.email == "resolved@x.ai")
        #expect(enriched.firstName == "Resolved")
        #expect(enriched.lastName == "Person")
        #expect(enriched.profileImageAssetID == "resolved-image")
        #expect(enriched.principalType == "Team")
        #expect(enriched.principalID == "team-allowed")
        #expect(enriched.teamID == "team-allowed")
        #expect(enriched.teamName == "Resolved Team")
        #expect(enriched.teamRole == "owner")
        #expect(enriched.organizationID == "resolved-org")
        #expect(enriched.organizationName == "Resolved Org")
        #expect(enriched.organizationRole == "admin")
        #expect(enriched.userBlockedReason == "resolved-block")
        #expect(enriched.teamBlockedReasons == ["BLOCKED_REASON_NO_LOGS"])
        #expect(enriched.isZDRTeam)
        #expect(enriched.isDataCollectionDisabled)
        #expect(enriched.key == auth.key)
        #expect(enriched.refreshToken == auth.refreshToken)
        #expect(enriched.expiresAt == auth.expiresAt)
        #expect(enriched.oidcIssuer == auth.oidcIssuer)
        #expect(enriched.oidcClientID == auth.oidcClientID)
    }

    @Test("absent profile values and empty email never erase existing identity or consent")
    func partialProfilePreservesExistingFields() async throws {
        let auth = userProfileParityAuth()
        let transport = UserProfileParityTransport(
            outcome: .response(
                status: 200,
                body: Data(#"{"userId":"resolved-user","email":"","teamBlockedReasons":[]}"#.utf8)
            )
        )

        let enriched = try await enrichXAIUserProfile(
            auth: auth,
            configuration: .default(environment: [:]),
            environment: [:],
            transport: transport
        )

        #expect(enriched.userID == "resolved-user")
        #expect(enriched.email == "original@x.ai")
        #expect(enriched.firstName == "Original")
        #expect(enriched.lastName == "Name")
        #expect(enriched.profileImageAssetID == "original-image")
        #expect(enriched.principalID == "team-allowed")
        #expect(enriched.teamID == "team-allowed")
        #expect(enriched.teamName == "Original Team")
        #expect(enriched.organizationID == "original-org")
        #expect(enriched.organizationName == "Original Org")
        #expect(enriched.userBlockedReason == "original-block")
        #expect(enriched.teamBlockedReasons.isEmpty)
        #expect(enriched.codingDataRetentionOptOut)
        #expect(enriched.isDataCollectionDisabled)
    }

    @Test(
        "both upstream ZDR reasons override explicit coding-data opt-in",
        arguments: ["BLOCKED_REASON_NO_LOGS", "BLOCKED_REASON_NO_LOGS_MODERATED"]
    )
    func discoveredZDRAlwaysDisablesDataCollection(_ reason: String) async throws {
        let body = try userProfileParityData([
            "userId": "resolved-user",
            "teamBlockedReasons": [reason],
            "codingDataRetentionOptOut": false,
        ])
        let enriched = try await enrichXAIUserProfile(
            auth: userProfileParityAuth(),
            configuration: .default(environment: [:]),
            environment: [:],
            transport: UserProfileParityTransport(outcome: .response(status: 200, body: body))
        )

        #expect(enriched.isZDRTeam)
        #expect(!enriched.codingDataRetentionOptOut)
        #expect(enriched.isDataCollectionDisabled)
    }

    @Test("an explicit server-confirmed non-ZDR opt-in is retained")
    func confirmedPrivacyOptInIsApplied() async throws {
        let body = Data(#"{"userId":"resolved-user","teamBlockedReasons":[],"codingDataRetentionOptOut":false}"#.utf8)
        let enriched = try await enrichXAIUserProfile(
            auth: userProfileParityAuth(),
            configuration: .default(environment: [:]),
            environment: [:],
            transport: UserProfileParityTransport(outcome: .response(status: 200, body: body))
        )

        #expect(!enriched.isZDRTeam)
        #expect(!enriched.codingDataRetentionOptOut)
        #expect(!enriched.isDataCollectionDisabled)
    }

    @Test(
        "malformed, empty, and rejected profiles never replace fail-closed privacy state",
        arguments: UserProfileMalformedResponse.allCases
    )
    func invalidProfilesPreserveOriginalCredential(
        _ response: UserProfileMalformedResponse
    ) async throws {
        let auth = userProfileParityAuth()
        let transport = UserProfileParityTransport(outcome: response.outcome)

        let enriched = try await enrichXAIUserProfile(
            auth: auth,
            configuration: .default(environment: [:]),
            environment: [:],
            transport: transport
        )

        #expect(enriched == auth)
        #expect(enriched.codingDataRetentionOptOut)
        #expect(transport.snapshot.requests.count == 1)
    }

    @Test("an unreachable trusted proxy leaves login credentials and privacy unchanged")
    func unreachableProxyDoesNotBreakLogin() async throws {
        let auth = userProfileParityAuth()
        let transport = UserProfileParityTransport(outcome: .unreachable)

        let enriched = try await enrichXAIUserProfile(
            auth: auth,
            configuration: .default(environment: [:]),
            environment: [:],
            transport: transport
        )

        #expect(enriched == auth)
        #expect(enriched.codingDataRetentionOptOut)
        #expect(transport.snapshot.requests.count == 1)
    }

    @Test("a foreign issuer or OAuth client never sends its credential to the xAI proxy")
    func foreignProviderCredentialIsNeverExported() async throws {
        for auth in [
            userProfileParityAuth(issuer: "https://auth.openai.com"),
            userProfileParityAuth(clientID: "other-provider-client"),
            GrokAuth(key: "provider-api-key", authMode: .apiKey),
        ] {
            let transport = UserProfileParityTransport(
                outcome: .response(status: 200, body: Data(#"{"userId":"foreign"}"#.utf8))
            )
            let enriched = try await enrichXAIUserProfile(
                auth: auth,
                configuration: .default(environment: [:]),
                environment: [:],
                transport: transport
            )

            #expect(enriched == auth)
            #expect(transport.snapshot.requests.isEmpty)
        }
    }

    @Test(
        "insecure or ambiguous explicit proxy authorities fail closed without sending bearer",
        arguments: [
            "http://external.example/v1",
            "https://user:secret@proxy.example/v1",
            "https://proxy.example/v1?forward=https://attacker.example",
            "https://proxy.example/v1#fragment",
            "file:///tmp/proxy",
        ]
    )
    func unsafeProxyAuthorityNeverReceivesCredentials(_ baseURL: String) async throws {
        let auth = userProfileParityAuth()
        let transport = UserProfileParityTransport(
            outcome: .response(status: 200, body: Data(#"{"userId":"unsafe"}"#.utf8))
        )
        let environment = ["GROK_CLI_CHAT_PROXY_BASE_URL": baseURL]

        #expect(xaiUserProfileURL(environment: environment) == nil)
        let enriched = try await enrichXAIUserProfile(
            auth: auth,
            configuration: .default(environment: [:]),
            environment: environment,
            transport: transport
        )

        #expect(enriched == auth)
        #expect(transport.snapshot.requests.isEmpty)
    }

    @Test("unrelated model endpoint overrides cannot redirect the profile bearer")
    func modelEndpointCannotRedirectProfileRequest() async throws {
        let auth = userProfileParityAuth()
        let transport = UserProfileParityTransport(
            outcome: .response(status: 200, body: Data(#"{"userId":"resolved"}"#.utf8))
        )

        let enriched = try await enrichXAIUserProfile(
            auth: auth,
            configuration: .default(environment: [:]),
            environment: ["GROK_XAI_API_BASE_URL": "https://attacker.example/v1"],
            transport: transport
        )

        #expect(enriched.userID == "resolved")
        let request = try #require(transport.snapshot.requests.first)
        #expect(request.url.absoluteString == "https://cli-chat-proxy.grok.com/v1/user")
    }

    @Test("device-session login enriches before its sole xAI write and leaves Codex untouched")
    func deviceSessionPersistsEnrichedIdentityExactlyOnce() async throws {
        let home = try userProfileParityHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let authFile = home.appendingPathComponent("auth.json")
        let codexFile = home.appendingPathComponent("codex-auth.json")
        let originalCodexBytes = Data("isolated-codex-credential".utf8)
        try originalCodexBytes.write(to: codexFile)

        var config = GrokComConfig.default(environment: [:])
        config.forceLoginTeamUUID = .single("team-allowed")
        let environment = [
            "OPENGROK_HOME": home.path,
            "GROK_CLI_CHAT_PROXY_BASE_URL": "http://127.0.0.1:49152/v1",
        ]
        let manager = AuthManager(grokHome: home, config: config, environment: environment)
        let body = Data(#"{"userId":"resolved-user","email":"device@x.ai","teamBlockedReasons":["BLOCKED_REASON_NO_LOGS"],"codingDataRetentionOptOut":true}"#.utf8)
        let transport = UserProfileParityTransport(
            outcome: .response(status: 200, body: body),
            authFile: authFile
        )

        let enriched = try await loginXAIWithSession(
            manager: manager,
            auth: userProfileParityAuth(),
            policy: config.forceLoginTeamUUID,
            environment: environment,
            transport: transport
        )

        let snapshot = transport.snapshot
        #expect(snapshot.requests.count == 1)
        #expect(snapshot.authFileExistedDuringProfileFetch == false)
        #expect(enriched.userID == "resolved-user")
        #expect(enriched.email == "device@x.ai")
        #expect(enriched.isZDRTeam)
        #expect(enriched.isDataCollectionDisabled)
        let store = try readAuthJSON(at: authFile)
        #expect(store.count == 1)
        let persisted = try #require(store[config.authScope])
        #expect(persisted.key == enriched.key)
        #expect(persisted.refreshToken == enriched.refreshToken)
        #expect(persisted.userID == enriched.userID)
        #expect(persisted.email == enriched.email)
        #expect(persisted.teamBlockedReasons == enriched.teamBlockedReasons)
        #expect(persisted.codingDataRetentionOptOut == enriched.codingDataRetentionOptOut)
        #expect(persisted.isDataCollectionDisabled)
        #expect(await manager.currentOrExpired() == enriched)
        #expect(try Data(contentsOf: codexFile) == originalCodexBytes)
    }

    @Test("managed team pin checks signed JWT principal before profile transport or persistence")
    func wrongManagedTeamNeverReachesProfileProxy() async throws {
        let home = try userProfileParityHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var config = GrokComConfig.default(environment: [:])
        config.forceLoginTeamUUID = .single("team-required")
        let manager = AuthManager(grokHome: home, config: config, environment: [:])
        let transport = UserProfileParityTransport(
            outcome: .response(status: 200, body: Data(#"{"userId":"unsafe"}"#.utf8))
        )

        do {
            _ = try await loginXAIWithSession(
                manager: manager,
                auth: userProfileParityAuth(principal: "team-other"),
                policy: config.forceLoginTeamUUID,
                environment: [:],
                transport: transport
            )
            Issue.record("expected the signed access-token team pin to reject login")
        } catch let error as AuthError {
            guard case .pinnedTeamMismatch = error else {
                Issue.record("unexpected authentication failure: \(error)")
                return
            }
        }

        #expect(transport.snapshot.requests.isEmpty)
        #expect(await manager.currentOrExpired() == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test("a cancelled profile request never publishes or persists a device session")
    func cancelledProfileCannotPersistCredentials() async throws {
        let home = try userProfileParityHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, environment: [:])
        let transport = UserProfileParityTransport(outcome: .cancelled)

        do {
            _ = try await loginXAIWithSession(
                manager: manager,
                auth: userProfileParityAuth(),
                environment: [:],
                transport: transport
            )
            Issue.record("expected cancellation before any credential write")
        } catch is CancellationError {
            // Cancellation remains observable instead of becoming a successful login.
        }

        #expect(transport.snapshot.requests.count == 1)
        #expect(await manager.currentOrExpired() == nil)
        #expect(manager.snapshotBox.read().token == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test("browser OAuth fetches the trusted profile before its one real credential write")
    func browserFlowPersistsDiscoveredZDRProfile() async throws {
        let home = try userProfileParityHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = [
            "OPENGROK_HOME": home.path,
            "GROK_CLI_CHAT_PROXY_BASE_URL": "http://127.0.0.1:49153/v1",
        ]
        let config = GrokComConfig.default(environment: environment)
        let manager = AuthManager(grokHome: home, config: config, environment: environment)
        let authFile = home.appendingPathComponent("auth.json")
        let token = userProfileParityAuth().key
        let body = Data(#"{"userId":"browser-resolved-user","email":"browser-profile@x.ai","teamBlockedReasons":["BLOCKED_REASON_NO_LOGS_MODERATED"],"codingDataRetentionOptOut":false}"#.utf8)
        let transport = UserProfileParityTransport(
            outcome: .response(status: 200, body: body),
            browserAccessToken: token,
            authFile: authFile
        )

        let enriched = try await loginXAIBrowser(
            manager: manager,
            environment: environment,
            transport: transport,
            openBrowser: { authorizeURL in
                let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?
                    .queryItems ?? []
                guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
                      let state = items.first(where: { $0.name == "state" })?.value,
                      let callback = URL(string: "\(redirect)?code=hermetic-code&state=\(state)")
                else {
                    return
                }
                URLSession.shared.dataTask(with: callback).resume()
            }
        )

        let snapshot = transport.snapshot
        #expect(snapshot.requests.count == 3)
        #expect(snapshot.requests.last?.url.absoluteString == "http://127.0.0.1:49153/v1/user")
        #expect(snapshot.authFileExistedDuringProfileFetch == false)
        #expect(enriched.userID == "browser-resolved-user")
        #expect(enriched.email == "browser-profile@x.ai")
        #expect(enriched.isZDRTeam)
        #expect(!enriched.codingDataRetentionOptOut)
        #expect(enriched.isDataCollectionDisabled)
        let store = try readAuthJSON(at: authFile)
        #expect(store.count == 1)
        let persisted = try #require(store[config.authScope])
        #expect(persisted.key == enriched.key)
        #expect(persisted.refreshToken == enriched.refreshToken)
        #expect(persisted.userID == enriched.userID)
        #expect(persisted.email == enriched.email)
        #expect(persisted.teamBlockedReasons == enriched.teamBlockedReasons)
        #expect(persisted.codingDataRetentionOptOut == enriched.codingDataRetentionOptOut)
        #expect(persisted.isDataCollectionDisabled)
        #expect(await manager.currentOrExpired() == enriched)
    }
}
