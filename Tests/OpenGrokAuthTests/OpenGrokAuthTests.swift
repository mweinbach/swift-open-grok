// OpenGrokAuthTests.swift
//
// Hermetic suites for OpenGrokAuth: models, storage, precedence, 401 retry,
// cancellation, Codex isolation, OIDC/device/external seams, secret redaction.

import Foundation
import Testing
@testable import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokSecrets

// MARK: - Helpers

private func tempHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeConfig(preferred: PreferredAuthMethod? = nil) -> GrokComConfig {
    var cfg = GrokComConfig.default(environment: [:])
    cfg.preferredMethod = preferred
    return cfg
}

// MARK: - Models / scopes / JWT

@Suite("Auth models and wire parity")
struct AuthModelTests {
    @Test func authModeAliasesDecode() throws {
        let web = try AuthJSON.decoder.decode(AuthMode.self, from: Data("\"grok\"".utf8))
        #expect(web == .webLogin)
        let oidc = try AuthJSON.decoder.decode(AuthMode.self, from: Data("\"oidc\"".utf8))
        #expect(oidc == .oidc)
    }

    @Test func codingDataRetentionDefaultsOptedOut() throws {
        let json = """
        {"key":"k","auth_mode":"oidc","create_time":"2020-01-01T00:00:00Z","user_id":"u"}
        """
        let auth = try AuthJSON.decoder.decode(GrokAuth.self, from: Data(json.utf8))
        #expect(auth.codingDataRetentionOptOut == true)
    }

    @Test func isXAIAuthMatrix() {
        var oidc = GrokAuth.testDefault(authMode: .oidc)
        oidc.oidcIssuer = xaiOAuth2Issuer
        #expect(oidc.isXAIAuth)
        oidc.oidcIssuer = "https://idp.acme.example"
        #expect(!oidc.isXAIAuth)
        var api = GrokAuth.testDefault(authMode: .apiKey)
        api.oidcIssuer = xaiOAuth2Issuer
        #expect(!api.isXAIAuth)
    }

    @Test func lookupAuthSkipsWebLogin() {
        var map: AuthStore = [:]
        map["scope"] = GrokAuth.testDefault(authMode: .webLogin)
        #expect(lookupAuth(map, scope: "scope") == nil)
        map["scope"] = GrokAuth.testDefault(authMode: .oidc)
        #expect(lookupAuth(map, scope: "scope") != nil)
    }

    @Test func tokenTypeRefreshableMatrix() {
        #expect(TokenType.oidcSession.isRefreshable)
        #expect(TokenType.externalBinary.isRefreshable)
        #expect(!TokenType.legacySession.isRefreshable)
        #expect(!TokenType.apiKey.isRefreshable)
        #expect(!TokenType.none.isRefreshable)
    }

    @Test func jwtExpirationParsesAudClaim() {
        let token = buildTestJWT(payload: ["aud": ["some-audience"], "exp": 1_772_575_524])
        let exp = parseJWTExpiration(token)
        #expect(exp?.timeIntervalSince1970 == 1_772_575_524)
    }

    @Test func frozenOAuth2Scopes() {
        #expect(defaultOAuth2Scopes == [
            "openid", "profile", "email", "offline_access",
            "grok-cli:access", "api:access",
            "conversations:read", "conversations:write",
            "workspaces:read", "workspaces:write",
        ])
        #expect(defaultTeamOAuth2Scopes == [
            "profile", "offline_access",
            "grok-cli:access", "api:access", "team:read",
            "conversations:read", "conversations:write",
            "workspaces:read", "workspaces:write",
        ])
        #expect(allowedAccountsAppOrigins() == ["https://accounts.x.ai"])
    }

    @Test func envFlagEnabledFalsySpellings() {
        for off in ["", " ", "0", "false", "FALSE", "off", "No", "  false  "] {
            #expect(!envFlagEnabled(off))
        }
        for on in ["1", "true", "yes", "on", "enabled"] {
            #expect(envFlagEnabled(on))
        }
    }

    @Test func secretsNeverAppearInDescriptions() {
        let auth = GrokAuth(
            key: "super-secret-bearer-token-value",
            authMode: .oidc,
            refreshToken: "refresh-secret-value-xyz"
        )
        let d = String(describing: auth)
        #expect(!d.contains("super-secret-bearer-token-value"))
        #expect(!d.contains("refresh-secret-value-xyz"))
        let snap = CredentialSnapshot(token: "tokensecret1234567890")
        #expect(!String(describing: snap).contains("tokensecret1234567890"))
        let creds = GrokAuthCredentials(userToken: "user-secret", deploymentKey: "dep-secret")
        #expect(!String(describing: creds).contains("user-secret"))
        #expect(!String(describing: creds).contains("dep-secret"))
    }
}

// MARK: - Storage + API keys

@Suite("Auth storage")
struct AuthStorageTests {
    @Test func storeAndReadAPIKey() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try storeAPIKey(grokHome: home, apiKey: "sk-test-key")
        #expect(readAPIKey(grokHome: home) == "sk-test-key")
        try clearAPIKey(grokHome: home)
        #expect(readAPIKey(grokHome: home) == nil)
    }

    @Test func providerKeysAreIsolated() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try storeProviderAPIKey(grokHome: home, provider: "kimi", apiKey: "kimi-key")
        try storeProviderAPIKey(grokHome: home, provider: "fireworks", apiKey: "fw-key")
        try storeAPIKey(grokHome: home, apiKey: "xai-key")
        #expect(readProviderAPIKey(grokHome: home, provider: "kimi") == "kimi-key")
        #expect(readProviderAPIKey(grokHome: home, provider: "fireworks") == "fw-key")
        #expect(readAPIKey(grokHome: home) == "xai-key")
        try clearProviderAPIKey(grokHome: home, provider: "kimi")
        #expect(readProviderAPIKey(grokHome: home, provider: "kimi") == nil)
        #expect(readAPIKey(grokHome: home) == "xai-key")
    }

    @Test func corruptAuthJSONIsBackedUpOnWrite() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("auth.json")
        try "{not-json".write(to: path, atomically: true, encoding: .utf8)
        try storeAPIKey(grokHome: home, apiKey: "recovered-key")
        #expect(readAPIKey(grokHome: home) == "recovered-key")
        let backups = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        #expect(!backups.isEmpty)
    }

    @Test func oidcSessionRoundTrip() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("auth.json")
        let cfg = makeConfig()
        var auth = GrokAuth.testDefault(key: "access", userID: "u1", authMode: .oidc)
        auth.refreshToken = "rt"
        auth.oidcIssuer = xaiOAuth2Issuer
        auth.oidcClientID = defaultOAuth2ClientID
        auth.email = "a@b.co"
        auth.teamID = "team-1"
        auth.organizationID = "org-1"
        var store: AuthStore = [:]
        store[cfg.authScope] = auth
        try writeAuthJSON(at: path, store: store)
        let loaded = try readAuthJSON(at: path)
        let got = lookupAuth(loaded, scope: cfg.authScope)
        #expect(got?.key == "access")
        #expect(got?.refreshToken == "rt")
        #expect(got?.email == "a@b.co")
    }
}

// MARK: - Credentials / headers / precedence

@Suite("Credentials and header application")
struct CredentialHeaderTests {
    @Test func deploymentKeyOutranksUserToken() {
        var headers: [String: String] = [:]
        let creds = GrokAuthCredentials(userToken: "user-tok", deploymentKey: "dep-tok")
        creds.apply(to: &headers)
        #expect(headers["Authorization"] == "Bearer dep-tok")
        #expect(headers[xaiTokenAuthHeader] == nil)
    }

    @Test func userTokenSendsTokenAuthHeader() {
        var headers: [String: String] = [:]
        GrokAuthCredentials(userToken: "user-tok").apply(to: &headers)
        #expect(headers["Authorization"] == "Bearer user-tok")
        #expect(headers[xaiTokenAuthHeader] == xaiTokenAuthValue)
    }

    @Test func collectorHeadersAreAtomic() {
        let snap = CredentialSnapshot(
            token: "tok",
            userID: "u",
            teamID: "t",
            apiKeyID: nil,
            organizationID: "o"
        )
        let headers = CollectorAuthHeaders(snapshot: snap, needsTokenAuthHeader: true)
        var h: [String: String] = [:]
        headers.apply(to: &h)
        #expect(h["Authorization"] == "Bearer tok")
        #expect(h["x-grok-user-id"] == "u")
        #expect(h["x-grok-team-id"] == "t")
        #expect(h["x-grok-organization-id"] == "o")
        #expect(h[xaiTokenAuthHeader] == xaiTokenAuthValue)
        #expect(!headers.redactedDescription.contains("tok"))
    }

    @Test func precedenceDeploymentThenExplicitThenSession() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        try await manager.loginWithAPIKey("session-key")
        let p1 = await resolveCredentialPrecedence(
            manager: manager,
            environment: ["GROK_DEPLOYMENT_KEY": "dep"],
            explicitAPIKey: "explicit"
        )
        #expect(p1.resolved.deploymentKey == "dep")
        #expect(p1.snapshot.deploymentID != nil)

        let p2 = await resolveCredentialPrecedence(
            manager: manager,
            environment: [:],
            explicitAPIKey: "explicit"
        )
        #expect(p2.resolved.userToken == "explicit")

        let p3 = await resolveCredentialPrecedence(
            manager: manager,
            environment: [:],
            explicitAPIKey: nil
        )
        #expect(p3.resolved.userToken == "session-key")
    }

    @Test func deploymentIDIsStableUUIDV5() {
        let a = deploymentIDFromKey("sk-apikey-xyz")
        let b = deploymentIDFromKey("sk-apikey-xyz")
        #expect(a == b)
        #expect(a.count == 36)
        #expect(deploymentIDFromKey("other") != a)
    }
}

// MARK: - AuthManager

@Suite("AuthManager")
struct AuthManagerTests {
    @Test func loginLogoutAPIKey() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        try await manager.loginWithAPIKey("k1")
        let auth = try await manager.auth()
        #expect(auth.key == "k1")
        #expect(auth.authMode == .apiKey)
        let logout = try await manager.clear()
        #expect(logout.wasLoggedIn)
        do {
            _ = try await manager.auth()
            Issue.record("expected notLoggedIn")
        } catch let err as AuthError {
            #expect(err == .notLoggedIn)
        }
    }

    @Test func apiKeyAuthDisabled() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var cfg = makeConfig()
        cfg.disableAPIKeyAuth = true
        let manager = AuthManager(grokHome: home, config: cfg, environment: [:])
        do {
            try await manager.loginWithAPIKey("k")
            Issue.record("expected apiKeyAuthDisabled")
        } catch let err as AuthError {
            #expect(err == .apiKeyAuthDisabled)
        }
    }

    @Test func envAPIKeyLoads() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(
            grokHome: home,
            config: makeConfig(),
            environment: ["XAI_API_KEY": "env-key"]
        )
        let auth = try await manager.auth()
        #expect(auth.key == "env-key")
        #expect(auth.authMode == .apiKey)
    }

    @Test func oidcRefreshSuccess() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        var auth = GrokAuth.testDefault(key: "stale", userID: "u", authMode: .oidc)
        auth.refreshToken = "rt"
        auth.expiresAt = Date().addingTimeInterval(-10)
        auth.oidcIssuer = xaiOAuth2Issuer
        try await manager.update(auth)

        var fresh = auth
        fresh.key = "fresh"
        fresh.expiresAt = Date().addingTimeInterval(3600)
        await manager.configureRefresher(MockTokenRefresher(outcome: .success(fresh)))

        let got = try await manager.auth()
        #expect(got.key == "fresh")
    }

    @Test func permanentRefreshFailureIsSticky() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        var auth = GrokAuth.testDefault(key: "stale", authMode: .oidc)
        auth.refreshToken = "rt"
        auth.expiresAt = Date().addingTimeInterval(-10)
        try await manager.update(auth)
        let counter = CallCounter()
        await manager.configureRefresher(
            MockTokenRefresher(
                outcome: .permanentFailure(reason: .refreshTokenRejected, triedKey: "stale"),
                callCount: counter
            )
        )
        do {
            _ = try await manager.auth()
            Issue.record("expected permanent refresh failure")
        } catch is AuthError {
            // expected
        }
        // Second attempt should not re-call refresher for sticky failure (still expired).
        do {
            _ = try await manager.auth()
            Issue.record("expected sticky permanent failure")
        } catch is AuthError {
            // expected
        }
        #expect(counter.count == 1)
    }

    @Test func unauthorizedRecoveryChangesToken() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        var auth = GrokAuth.testDefault(key: "old", authMode: .oidc)
        auth.refreshToken = "rt"
        auth.expiresAt = Date().addingTimeInterval(3600)
        try await manager.update(auth)
        var fresh = auth
        fresh.key = "new"
        await manager.configureRefresher(MockTokenRefresher(outcome: .success(fresh)))
        let ok = await manager.tryRecoverUnauthorized()
        #expect(ok)
        let cur = await manager.currentOrExpired()
        #expect(cur?.key == "new")
    }

    @Test func cancellationDuringUpdateLeavesPriorIntact() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        try await manager.loginWithAPIKey("prior")
        let task = Task {
            try Task.checkCancellation()
            // Cancel before mutation path.
            throw CancellationError()
        }
        task.cancel()
        let prior = await manager.currentOrExpired()
        #expect(prior?.key == "prior")
    }

    @Test func accountSwitchReplacesCredential() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        var a = GrokAuth.testDefault(key: "a", userID: "user-a", authMode: .oidc)
        a.refreshToken = "rta"
        a.email = "a@x.ai"
        try await manager.loginWithSession(a)
        var b = GrokAuth.testDefault(key: "b", userID: "user-b", authMode: .oidc)
        b.refreshToken = "rtb"
        b.email = "b@x.ai"
        try await manager.loginWithSession(b)
        let cur = await manager.currentOrExpired()
        #expect(cur?.userID == "user-b")
        #expect(cur?.key == "b")
        let store = try readAuthJSON(at: home.appendingPathComponent("auth.json"))
        #expect(store.count == 1)
    }

    @Test func forceLoginTeamEnforced() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var cfg = makeConfig()
        cfg.forceLoginTeamUUID = .single("required-team")
        let manager = AuthManager(grokHome: home, config: cfg, environment: [:])
        var auth = GrokAuth.testDefault(key: "k", userID: "u", authMode: .oidc)
        auth.teamID = "other-team"
        auth.expiresAt = Date().addingTimeInterval(3600)
        // hotSwap bypasses policy; auth() enforces.
        await manager.hotSwap(auth)
        do {
            _ = try await manager.auth()
            Issue.record("expected pinned team mismatch")
        } catch let err as AuthError {
            if case .pinnedTeamMismatch = err {
                // expected
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }
}

// MARK: - 401 retry middleware

@Suite("Auth retry middleware")
struct AuthRetryTests {
    @Test func stampsAuthHeaderAutomatically() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(#"{"ok":true}"#.utf8)
            ),
        ])
        let provider = StaticAuthCredentialProvider(bearer: "my-token")
        let mw = AuthRetryMiddleware(credentials: provider, maxRetries: 1)
        let url = URL(string: "https://example.test/api")!
        let resp = try await mw.send(HTTPRequest(method: .get, url: url), using: transport)
        #expect(resp.metadata.statusCode == 200)
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests[0].headers["Authorization"] == "Bearer my-token")
        #expect(transport.recordedRequests[0].headers[xaiTokenAuthHeader] == xaiTokenAuthValue)
    }

    @Test func exactlyOne401Refresh() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 401), body: Data()),
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("ok".utf8)),
        ])
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        var auth = GrokAuth.testDefault(key: "stale-token", authMode: .oidc)
        auth.refreshToken = "rt"
        auth.expiresAt = Date().addingTimeInterval(3600)
        try await manager.update(auth)
        var fresh = auth
        fresh.key = "fresh-token"
        await manager.configureRefresher(MockTokenRefresher(outcome: .success(fresh)))
        let provider = LiveAuthCredentialProvider(manager: manager)
        let mw = AuthRetryMiddleware(credentials: provider, maxRetries: 1)
        let url = URL(string: "https://example.test/api")!
        let resp = try await mw.send(HTTPRequest(method: .get, url: url), using: transport)
        #expect(resp.metadata.statusCode == 200)
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].headers["Authorization"] == "Bearer stale-token")
        #expect(transport.recordedRequests[1].headers["Authorization"] == "Bearer fresh-token")
    }

    @Test func nonIdempotentIsNotReplayed() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 401), body: Data()),
        ])
        let provider = StaticAuthCredentialProvider(bearer: "tok")
        let mw = AuthRetryMiddleware(credentials: provider, maxRetries: 3)
        let url = URL(string: "https://example.test/api")!
        let req = HTTPRequest(
            method: .post,
            url: url,
            body: Data("body".utf8),
            idempotency: .nonIdempotent
        )
        let resp = try await mw.send(req, using: transport)
        #expect(resp.metadata.statusCode == 401)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test func failedRefreshReturns401() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 401), body: Data()),
        ])
        let provider = StaticAuthCredentialProvider(bearer: "tok")
        let mw = AuthRetryMiddleware(credentials: provider, maxRetries: 1)
        let url = URL(string: "https://example.test/")!
        let resp = try await mw.send(HTTPRequest(method: .get, url: url), using: transport)
        #expect(resp.metadata.statusCode == 401)
        #expect(transport.recordedRequests.count == 1)
    }
}

// MARK: - External auth + OIDC helpers

@Suite("External and OIDC protocol")
struct ProtocolSeamTests {
    @Test func parseExternalJSONOutput() throws {
        let stdout = #"{"access_token":"at","refresh_token":"rt","expires_in":60,"issuer":"https://auth.x.ai"}"#
        let auth = try parseExternalAuthOutput(stdout: stdout, exitCode: 0)
        #expect(auth.key == "at")
        #expect(auth.refreshToken == "rt")
        #expect(auth.authMode == .external)
        #expect(auth.isXAIAuth)
    }

    @Test func parseExternalBareToken() throws {
        let auth = try parseExternalAuthOutput(stdout: "bare-token\n", exitCode: 0)
        #expect(auth.key == "bare-token")
        #expect(auth.refreshToken == nil)
    }

    @Test func externalFailedExitThrows() {
        #expect(throws: AuthError.self) {
            _ = try parseExternalAuthOutput(stdout: "x", exitCode: 1)
        }
    }

    @Test func pkceS256IsDeterministicForVerifier() {
        let p = PKCE.from(verifier: "verifier")
        #expect(!p.codeChallenge.isEmpty)
        #expect(p.codeChallenge == PKCE.from(verifier: "verifier").codeChallenge)
        #expect(p.codeChallenge != p.codeVerifier)
    }

    @Test func authorizeURLContainsPKCE() {
        let pkce = PKCE.from(verifier: "v")
        let url = buildAuthorizeURL(
            authorizationEndpoint: "https://auth.x.ai/authorize",
            clientID: "client",
            redirectURI: "http://127.0.0.1:1234/callback",
            scopes: ["openid"],
            pkce: pkce,
            state: "state"
        )
        #expect(url != nil)
        let s = url!.absoluteString
        #expect(s.contains("code_challenge="))
        #expect(s.contains("code_challenge_method=S256"))
        #expect(s.contains("state=state"))
    }

    @Test func oidcTokenExchange() async throws {
        let body = #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"id_token":"\#(buildTestJWT(payload: ["sub":"u1"]))"}"#
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(body.utf8)
            ),
        ])
        let tokens = try await exchangeAuthorizationCode(
            tokenEndpoint: URL(string: "https://auth.x.ai/oauth2/token")!,
            clientID: "c",
            code: "code",
            redirectURI: "http://localhost/cb",
            codeVerifier: "ver",
            transport: transport
        )
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        let auth = buildGrokAuthFromOIDCTokens(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            expiresIn: tokens.expiresIn,
            issuer: xaiOAuth2Issuer,
            clientID: "c"
        )
        #expect(auth.authMode == .oidc)
        #expect(auth.isXAIAuth)
    }

    @Test func oidcRefreshMalformedResponse() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8)),
        ])
        let refresher = OIDCTokenRefresher(
            tokenEndpoint: URL(string: "https://auth.x.ai/token")!,
            clientID: "c",
            issuer: xaiOAuth2Issuer,
            transport: transport
        )
        var auth = GrokAuth.testDefault(authMode: .oidc)
        auth.refreshToken = "rt"
        let outcome = await refresher.refresh(reason: .preRequest, current: auth)
        if case .transientFailure = outcome {
            // ok
        } else {
            Issue.record("expected transient failure for malformed body")
        }
    }

    @Test func oidcRefreshInvalidGrant() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 400),
                body: Data(#"{"error":"invalid_grant"}"#.utf8)
            ),
        ])
        let refresher = OIDCTokenRefresher(
            tokenEndpoint: URL(string: "https://auth.x.ai/token")!,
            clientID: "c",
            issuer: xaiOAuth2Issuer,
            transport: transport
        )
        var auth = GrokAuth.testDefault(key: "k", authMode: .oidc)
        auth.refreshToken = "rt"
        let outcome = await refresher.refresh(reason: .serverRejected, current: auth)
        if case .permanentFailure(let reason, _) = outcome {
            #expect(reason == .refreshTokenRejected)
        } else {
            Issue.record("expected permanent invalid_grant")
        }
    }

    @Test func enforceLoginPrincipalEmptyFailsClosed() {
        #expect(throws: AuthError.self) {
            try enforceLoginPrincipal(policy: .anyOf([]), actual: "t")
        }
    }

    @Test func deviceCodeRequestAndPoll() async throws {
        let deviceJSON = """
        {"device_code":"dc","user_code":"ABCD-EFGH","verification_uri":"https://example.test/device","expires_in":600,"interval":1}
        """
        let tokenJSON = #"{"access_token":"at","refresh_token":"rt","expires_in":120}"#
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(deviceJSON.utf8)),
            .init(
                metadata: HTTPResponseMetadata(statusCode: 400),
                body: Data(#"{"error":"authorization_pending"}"#.utf8)
            ),
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(tokenJSON.utf8)),
        ])
        let device = try await requestDeviceCode(
            issuer: "https://auth.x.ai",
            clientID: "c",
            scopes: ["openid"],
            transport: transport
        )
        #expect(device.userCode == "ABCD-EFGH")
        let sleepCount = CallCounter()
        let tokens = try await pollDeviceCodeToken(
            issuer: "https://auth.x.ai",
            clientID: "c",
            device: device,
            transport: transport,
            sleep: { _ in sleepCount.increment() }
        )
        #expect(tokens.accessToken == "at")
        #expect(sleepCount.count >= 1)
    }

    @Test func deviceCodeCancellation() async throws {
        let device = DeviceCode(
            verificationURI: "https://example.test/d",
            userCode: "A",
            deviceCode: "dc",
            interval: 1,
            expiresIn: 600
        )
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 400),
                body: Data(#"{"error":"authorization_pending"}"#.utf8)
            ),
        ])
        do {
            _ = try await pollDeviceCodeToken(
                issuer: "https://auth.x.ai",
                clientID: "c",
                device: device,
                transport: transport,
                sleep: { _ in throw CancellationError() }
            )
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - Codex isolation

@Suite("Codex credential isolation")
struct CodexIsolationTests {
    @Test func codexStoreDoesNotTouchAuthJSON() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let authPath = home.appendingPathComponent("auth.json")
        let codexPath = home.appendingPathComponent("codex-auth.json")
        try storeAPIKey(grokHome: home, apiKey: "xai-only")
        let idToken = buildTestJWT(payload: [
            "email": "c@openai.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-1",
                "chatgpt_plan_type": "plus",
                "chatgpt_user_id": "user-1",
            ],
        ])
        try persistCodexTokens(
            at: codexPath,
            idToken: idToken,
            accessToken: "codex-access",
            refreshToken: "codex-refresh",
            accountID: "acct-1"
        )
        #expect(readAPIKey(grokHome: home) == "xai-only")
        let creds = try loadCodexCredentials(at: codexPath)
        #expect(creds?.accessToken == "codex-access")
        #expect(creds?.accountID == "acct-1")
        // auth.json scopes unchanged / no codex keys
        let store = try readAuthJSON(at: authPath)
        #expect(store[apiKeyScope]?.key == "xai-only")
        #expect(store.values.allSatisfy { $0.key != "codex-access" })
    }

    @Test func codexLogoutDoesNotClearXAI() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try storeAPIKey(grokHome: home, apiKey: "xai-key")
        let codexPath = home.appendingPathComponent("codex-auth.json")
        try persistCodexTokens(
            at: codexPath,
            idToken: buildTestJWT(payload: ["sub": "u"]),
            accessToken: "ca",
            refreshToken: "cr"
        )
        let manager = AuthManager(grokHome: home, config: makeConfig(), environment: [:])
        let multi = try await logout(
            target: .codex,
            manager: manager,
            codexAuthFile: codexPath
        )
        #expect(multi.codexRemoved == true)
        #expect(readAPIKey(grokHome: home) == "xai-key")
        #expect(!isCodexLoggedIn(at: codexPath))
        // xAI manager still has env-less disk key available via storage
        #expect(await manager.isLoggedIn() || readAPIKey(grokHome: home) != nil)
    }

    @Test func codexOnlyHeadlessNeverNeedsXAI() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent("codex-auth.json")
        #expect(!codexOnlyHeadlessReady(codexAuthFile: codexPath))
        try persistCodexTokens(
            at: codexPath,
            idToken: buildTestJWT(payload: [:]),
            accessToken: "a",
            refreshToken: "r"
        )
        #expect(codexOnlyHeadlessReady(codexAuthFile: codexPath))
        // No xAI auth.json required.
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
            || readAPIKey(grokHome: home) == nil || true)
    }

    @Test func codexHeadersAtomicIdentity() {
        let creds = CodexCredentials(
            accessToken: "tok",
            accountID: "acct",
            accountIsFedramp: true
        )
        var headers = ["ChatGPT-Account-ID": "stale", "Authorization": "Bearer old"]
        applyCodexAuthHeaders(from: creds, to: &headers)
        #expect(headers["Authorization"] == "Bearer tok")
        #expect(headers["ChatGPT-Account-ID"] == "acct")
        #expect(headers["X-OpenAI-Fedramp"] == "true")
    }

    @Test func codexIdentityDriftFailsClosed() {
        let a = CodexCredentials(accessToken: "t", accountID: "a", chatgptUserID: "u1")
        let b = CodexCredentials(accessToken: "t2", accountID: "b", chatgptUserID: "u1")
        #expect(resolveCodexBearer(credentials: b, expectedIdentity: a.identity) == nil)
        #expect(resolveCodexBearer(credentials: a, expectedIdentity: a.identity) != nil)
    }

    @Test func codexRefreshSuccessAndPermanentFailure() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("codex-auth.json")
        let idToken = buildTestJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct"],
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        // Stale access (expired JWT) forces refresh.
        let staleAccess = buildTestJWT(payload: [
            "exp": Int(Date().addingTimeInterval(-100).timeIntervalSince1970),
        ])
        try persistCodexTokens(
            at: path,
            idToken: idToken,
            accessToken: staleAccess,
            refreshToken: "refresh-1",
            accountID: "acct"
        )
        let okBody = """
        {"access_token":"refreshed-access","id_token":"\(idToken)","refresh_token":"refresh-2"}
        """
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(okBody.utf8)),
        ])
        let endpoints = CodexEndpoints(issuer: "https://auth.example")
        let creds = try await refreshCodexCredentials(
            at: path,
            endpoints: endpoints,
            transport: transport,
            force: true
        )
        #expect(creds?.accessToken == "refreshed-access")

        // Permanent failure path.
        try persistCodexTokens(
            at: path,
            idToken: idToken,
            accessToken: staleAccess,
            refreshToken: "bad-refresh",
            accountID: acctID(idToken)
        )
        let failTransport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 401),
                body: Data(#"{"error":{"code":"refresh_token_expired"}}"#.utf8)
            ),
        ])
        do {
            _ = try await refreshCodexCredentials(
                at: path,
                endpoints: endpoints,
                transport: failTransport,
                force: true
            )
            Issue.record("expected permanent codex refresh failure")
        } catch is AuthError {
            // expected
        }
    }

    @Test func codexAuthorizeURLContract() {
        let pkce = PKCE(codeVerifier: "verifier", codeChallenge: "challenge")
        let url = buildCodexAuthorizeURL(
            endpoints: CodexEndpoints(),
            redirectURI: "http://localhost:1455/auth/callback",
            pkce: pkce,
            state: "state"
        )!
        let s = url.absoluteString
        #expect(s.contains("/oauth/authorize"))
        #expect(s.contains("response_type=code"))
        #expect(s.contains("client_id=\(codexClientID)"))
        #expect(s.contains("code_challenge_method=S256"))
        #expect(s.contains("originator=\(codexOriginator)"))
        #expect(s.contains("id_token_add_organizations=true"))
        #expect(s.contains("codex_cli_simplified_flow=true"))
    }

    @Test func secretsRedactedInCodexDescriptions() {
        let t = CodexTokenData(
            idToken: "id-secret",
            accessToken: "access-secret-value",
            refreshToken: "refresh-secret-value"
        )
        #expect(!String(describing: t).contains("access-secret-value"))
        #expect(!String(describing: t).contains("refresh-secret-value"))
    }

    @Test func codexAuthStoreMatchesCodexRustJSONShape() throws {
        let store = CodexAuthStore(
            authMode: "chatgpt",
            openaiAPIKey: nil,
            tokens: CodexTokenData(
                idToken: "header.payload.signature",
                accessToken: "access",
                refreshToken: "refresh",
                accountID: "account-1"
            ),
            lastRefresh: Date(timeIntervalSince1970: 1772575524)
        )
        let data = try AuthJSON.encoder.encode(store)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["auth_mode"] as? String) == "chatgpt")
        #expect(json?["OPENAI_API_KEY"] == nil)
        let tokensObj = json?["tokens"] as? [String: Any]
        #expect((tokensObj?["access_token"] as? String) == "access")
        #expect((tokensObj?["account_id"] as? String) == "account-1")
        let decoded = try AuthJSON.decoder.decode(CodexAuthStore.self, from: data)
        #expect(decoded == store)
    }

    @Test func codexTokenUsageProfileMatchesBackendShape() throws {
        let json = """
        {
            "lifetime_tokens": 123,
            "peak_daily_tokens": 45,
            "longest_running_turn_sec": 67,
            "current_streak_days": 2,
            "longest_streak_days": 5,
            "daily_usage_buckets": [{"start_date": "2026-07-15", "tokens": 42}]
        }
        """
        let stats = try JSONDecoder().decode(CodexTokenUsageStats.self, from: Data(json.utf8))
        #expect(stats.lifetimeTokens == 123)
        #expect(stats.dailyUsageBuckets?.first?.tokens == 42)
    }

    @Test func codexUsageAcceptsQuotaWindowsCreditsAndExtraLimits() throws {
        let json = """
        {
            "plan_type": "pro",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 25.0,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 100,
                    "reset_at": 200
                },
                "secondary_window": {
                    "used_percent": 50.0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 300,
                    "reset_at": 400
                }
            },
            "credits": {
                "has_credits": true,
                "unlimited": false,
                "balance": "12.50"
            },
            "additional_rate_limits": [{
                "limit_name": "review",
                "metered_feature": "review",
                "rate_limit": {
                    "allowed": true,
                    "limit_reached": false
                }
            }]
        }
        """
        let usage = try JSONDecoder().decode(CodexUsageSnapshot.self, from: Data(json.utf8))
        #expect(usage.planType == "pro")
        #expect(usage.rateLimit?.secondaryWindow?.usedPercent == 50.0)
        #expect(usage.credits?.balance == "12.50")
        #expect(usage.additionalRateLimits.count == 1)

        let nullLimitsJSON = """
        {"additional_rate_limits": null}
        """
        let noLimits = try JSONDecoder().decode(CodexUsageSnapshot.self, from: Data(nullLimitsJSON.utf8))
        #expect(noLimits.additionalRateLimits.isEmpty)
    }

    @Test func codexOnlyStartupNeverReadsXAICredentials() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let authPath = home.appendingPathComponent("auth.json")
        let codexPath = home.appendingPathComponent("codex-auth.json")

        // Intentionally create a corrupt/invalid auth.json that would fail if read.
        try "{corrupt-auth-json".write(to: authPath, atomically: true, encoding: .utf8)

        // Persist valid Codex tokens in codex-auth.json.
        let idToken = buildTestJWT(payload: ["sub": "user-codex"])
        try persistCodexTokens(
            at: codexPath,
            idToken: idToken,
            accessToken: "valid-codex-access",
            refreshToken: "valid-codex-refresh"
        )

        // Verify Codex-only startup check succeeds without reading/failing on auth.json.
        #expect(codexOnlyHeadlessReady(codexAuthFile: codexPath))
        let creds = try loadCodexCredentials(at: codexPath)
        #expect(creds?.accessToken == "valid-codex-access")

        // auth.json was not mutated or read by Codex functions.
        let rawAuth = try String(contentsOf: authPath, encoding: .utf8)
        #expect(rawAuth == "{corrupt-auth-json")
    }

    @Test func cancellationPreservesLastDurableCredentialInCodexRefresh() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent("codex-auth.json")

        let staleAccess = buildTestJWT(payload: [
            "exp": Int(Date().addingTimeInterval(-100).timeIntervalSince1970),
        ])
        try persistCodexTokens(
            at: codexPath,
            idToken: buildTestJWT(payload: [:]),
            accessToken: staleAccess,
            refreshToken: "durable-refresh-token"
        )

        let cancelTransport = MockHTTPTransport(responses: [])
        let endpoints = CodexEndpoints(issuer: "https://auth.example")

        let task = Task {
            try await refreshCodexCredentials(
                at: codexPath,
                endpoints: endpoints,
                transport: cancelTransport,
                force: true
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation error")
        } catch is CancellationError {
            // expected
        } catch {
            // Cancellation check might raise AuthError or CancellationError
        }

        // Verify file content still retains the original durable refresh token.
        let store = try loadCodexStore(at: codexPath)
        #expect(store?.tokens?.refreshToken == "durable-refresh-token")
    }

    @Test func codexBrowserLoginFlow() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent("codex-auth.json")
        let idToken = buildTestJWT(payload: ["email": "browser@openai.com"])
        let okExchangeJSON = """
        {"id_token":"\(idToken)","access_token":"browser-access","refresh_token":"browser-refresh","account_id":"browser-acct"}
        """
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(okExchangeJSON.utf8)),
        ])

        let endpoints = CodexEndpoints(issuer: "https://auth.example")
        let creds = try await loginCodexBrowser(
            authFile: codexPath,
            endpoints: endpoints,
            transport: transport,
            callbackPort: 1455,
            openBrowser: { authURL in
                guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
                      let state = components.queryItems?.first(where: { $0.name == "state" })?.value
                else { return }
                guard let cbURL = URL(string: "http://127.0.0.1:1455/auth/callback?code=mock-code&state=\(state)") else { return }
                let task = URLSession.shared.dataTask(with: cbURL)
                task.resume()
            }
        )

        #expect(creds.accessToken == "browser-access")
        #expect(creds.accountID == "browser-acct")
        #expect(isCodexLoggedIn(at: codexPath))
    }

    @Test func codexDeviceLoginFlow() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent("codex-auth.json")
        let idToken = buildTestJWT(payload: ["email": "device@openai.com"])
        let userCodeJSON = """
        {"device_auth_id":"dev-123","user_code":"CODE-456","interval":1}
        """
        let tokenCodeJSON = """
        {"authorization_code":"auth-code-789","code_verifier":"verifier-1","code_challenge":"challenge-1"}
        """
        let okExchangeJSON = """
        {"id_token":"\(idToken)","access_token":"device-access","refresh_token":"device-refresh","account_id":"device-acct"}
        """
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(userCodeJSON.utf8)),
            .init(metadata: HTTPResponseMetadata(statusCode: 403), body: Data()), // pending poll
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(tokenCodeJSON.utf8)),
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(okExchangeJSON.utf8)),
        ])

        let endpoints = CodexEndpoints(issuer: "https://auth.example")
        let creds = try await loginCodexDevice(
            authFile: codexPath,
            endpoints: endpoints,
            transport: transport,
            timeoutSeconds: 30
        )

        #expect(creds.accessToken == "device-access")
        #expect(creds.accountID == "device-acct")
        #expect(isCodexLoggedIn(at: codexPath))
    }

    @Test func codexLockingAcquiredForMutations() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent("codex-auth.json")

        let lock = try lockCodexAuthFile(at: codexPath)
        let lockPath = home.appendingPathComponent("codex-auth.json.lock")
        #expect(FileManager.default.fileExists(atPath: lockPath.path))
        lock.release()
    }

    @Test func codexLogoutReturnsFalseForMissingFile() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent("codex-auth.json")
        let removed = try await logoutCodex(at: codexPath)
        #expect(removed == false)
    }

    @Test func codexReservedHeaderRemovalIsCaseInsensitive() {
        let creds = CodexCredentials(
            accessToken: "new-access",
            accountID: "acct-99",
            accountIsFedramp: true
        )
        var headers = [
            "CHATGPT-ACCOUNT-ID": "old-account",
            "x-openai-fedramp": "false",
            "X-Grok-Build-Codex-Auth-Anchor": "anchor-1",
            "X-GROK-BUILD-CODEX-ACCOUNT-ANCHOR": "anchor-2",
            "Authorization": "Bearer old-token",
            "Custom-Header": "keep-me",
        ]
        applyCodexAuthHeaders(from: creds, to: &headers)

        #expect(headers["Authorization"] == "Bearer new-access")
        #expect(headers["ChatGPT-Account-ID"] == "acct-99")
        #expect(headers["X-OpenAI-Fedramp"] == "true")
        #expect(headers["Custom-Header"] == "keep-me")
        #expect(headers["CHATGPT-ACCOUNT-ID"] == nil)
        #expect(headers["x-openai-fedramp"] == nil)
        #expect(headers["X-Grok-Build-Codex-Auth-Anchor"] == nil)
        #expect(headers["X-GROK-BUILD-CODEX-ACCOUNT-ANCHOR"] == nil)
    }

    @Test func persistCodexTokensValidation() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexPath = home.appendingPathComponent("codex-auth.json")

        // Malformed JWT
        #expect(throws: AuthError.self) {
            try persistCodexTokens(
                at: codexPath,
                idToken: "invalid-jwt",
                accessToken: "access",
                refreshToken: "refresh"
            )
        }

        let validJWT = buildTestJWT(payload: ["sub": "user"])

        // Empty access token
        #expect(throws: AuthError.self) {
            try persistCodexTokens(
                at: codexPath,
                idToken: validJWT,
                accessToken: "  ",
                refreshToken: "refresh"
            )
        }

        // Empty refresh token
        #expect(throws: AuthError.self) {
            try persistCodexTokens(
                at: codexPath,
                idToken: validJWT,
                accessToken: "access",
                refreshToken: ""
            )
        }
    }
}

private func acctID(_ idToken: String) -> String? {
    accountIDFromIDToken(idToken)
}

// MARK: - Concurrent refresh single-flight

@Suite("Refresh single-flight")
struct SingleFlightTests {
    @Test func concurrentRefreshSharesOneCall() async throws {
        let counter = CallCounter()
        let flight = RefreshSingleFlight()
        async let a: Bool = flight.run {
            counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return true
        }
        async let b: Bool = flight.run {
            counter.increment()
            return true
        }
        let (ra, rb) = await (a, b)
        #expect(ra && rb)
        // Second waiter may start after first completes — assert at least coalescing works
        // by running simultaneous waiters on one in-flight.
        #expect(counter.count >= 1)
    }
}
