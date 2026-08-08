// XAIBrowserLoginTests.swift
//
// The xAI browser OAuth flow against the REAL loopback listener and the REAL
// store file (AGENTS.md §3): only the HTTP transport and the browser are
// fakes, and the fake browser drives the listener over an actual socket. The
// authorize URL is pinned byte-for-byte against upstream
// `build_authorize_url` (auth/oidc/protocol.rs:349-393); error copy against
// `OidcError` display text (protocol.rs:17-76).

import Foundation
import OpenGrokHTTP
import Testing
@testable import OpenGrokAuth

// MARK: - Fixture

/// Every endpoint env var the flow can read is pinned (the Wave 14.1
/// hermeticity rule): the issuer points at a dead loopback port so a pin
/// failure dials nothing real, `GROK_OIDC_*` / `GROK_LOCAL_AUTH` /
/// `XAI_API_KEY` / `OPENGROK_AUTH*` are absent because the dictionary is
/// constructed from scratch.
private func xaiTestEnvironment(home: URL) -> [String: String] {
    [
        "HOME": home.path,
        "OPENGROK_HOME": home.path,
        "GROK_OAUTH2_ISSUER": "http://127.0.0.1:9",
        "GROK_OAUTH2_CLIENT_ID": "client-under-test",
    ]
}

private func makeXAIHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-xai-login-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

/// Scripted IdP for the flow's two HTTP legs. The exchange's id_token must
/// carry the nonce the flow minted, which only exists once the authorize URL
/// is built — the fake browser stashes it here before the token leg runs.
private final class XAIFlowTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var nonce: String?
    private var recordedRequests: [HTTPRequest] = []

    /// The access token the token endpoint returns (a JWT for principal arms).
    var accessToken = "xai-access-token"
    /// `false` omits id_token from the exchange (the team arm / missing arm).
    var includeIDToken = true
    /// Overrides the id_token's nonce claim (the mismatch arm).
    var idTokenNonceOverride: String?

    func setNonce(_ value: String?) {
        lock.lock(); nonce = value; lock.unlock()
    }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let currentNonce = lock.withLock {
            recordedRequests.append(request)
            return nonce
        }

        let path = request.url.path
        if path.hasSuffix("/.well-known/openid-configuration") {
            let body = """
            {"issuer":"http://127.0.0.1:9",\
            "authorization_endpoint":"http://127.0.0.1:9/authorize",\
            "token_endpoint":"http://127.0.0.1:9/token"}
            """
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(body.utf8)
            )
        }
        if path.hasSuffix("/token") {
            var fields: [String: Any] = [
                "access_token": accessToken,
                "refresh_token": "xai-refresh-token",
                "expires_in": 3600,
            ]
            if includeIDToken {
                fields["id_token"] = buildTestJWT(payload: [
                    "sub": "user-42",
                    "email": "browser@x.ai",
                    "nonce": idTokenNonceOverride ?? currentNonce ?? "",
                ])
            }
            let body = try JSONSerialization.data(withJSONObject: fields)
            return HTTPResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: body
            )
        }
        return HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 404),
            body: Data()
        )
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await send(request)
                    continuation.yield(.metadata(response.metadata))
                    continuation.yield(.body(response.body))
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ value: URL) { lock.lock(); url = value; lock.unlock() }
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return url }
}

private func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == name })?.value
}

/// The standard fake browser: parse the authorize URL, stash the nonce for
/// the token leg, and deliver `code`+`state` to the REAL listener over a
/// real socket.
private func drivingBrowser(
    transport: XAIFlowTransport,
    authURLBox: URLBox? = nil,
    stateOverride: String? = nil
) -> @Sendable (URL) -> Void {
    { authURL in
        authURLBox?.set(authURL)
        transport.setNonce(queryValue(authURL, "nonce"))
        guard let redirect = queryValue(authURL, "redirect_uri"),
              let redirectURL = URL(string: redirect),
              let port = redirectURL.port,
              let state = stateOverride ?? queryValue(authURL, "state"),
              let cbURL = URL(
                string: "http://127.0.0.1:\(port)/callback?code=mock-code&state=\(state)"
              )
        else { return }
        URLSession.shared.dataTask(with: cbURL).resume()
    }
}

// MARK: - Authorize URL bytes

@Suite("xAI authorize URL")
struct XAIAuthorizeURLTests {
    @Test func matchesUpstreamBytesForDefaultConfig() {
        // Byte-for-byte against `build_authorize_url` with the production
        // xAI OAuth2 defaults: upstream's parameter ORDER and Rust
        // `urlencoding::encode` escaping (`%20` spaces, `%3A` colons,
        // unreserved `-_.~` untouched). A merely-equivalent URL is not
        // parity — the codex D1 lesson was a live rejection.
        let config = GrokComConfig.default(environment: [:])
        let url = buildXAIAuthorizeURL(
            authorizationEndpoint: "https://auth.x.ai/authorize",
            oidc: config.effectiveOIDC!,
            oauth2: config.oauth2,
            redirectURI: "http://127.0.0.1:9999/callback",
            pkce: PKCE(codeVerifier: "v", codeChallenge: "challenge"),
            state: "state123",
            nonce: "nonce123"
        )
        #expect(url?.absoluteString == "https://auth.x.ai/authorize"
            + "?response_type=code"
            + "&client_id=b1a00492-073a-47ea-816f-4c329264a828"
            + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcallback"
            + "&scope=openid%20profile%20email%20offline_access%20grok-cli%3Aaccess"
            + "%20api%3Aaccess%20conversations%3Aread%20conversations%3Awrite"
            + "%20workspaces%3Aread%20workspaces%3Awrite"
            + "&code_challenge=challenge"
            + "&code_challenge_method=S256"
            + "&state=state123"
            + "&nonce=nonce123"
            + "&referrer=grok-build")
    }

    @Test func includesTeamPrincipalParamsInUpstreamOrder() {
        // `authorize_url_includes_team_principal_params`
        // (protocol.rs:824-866): principal_type before principal_id, referrer
        // last and exactly once.
        let oauth2 = OAuth2ProviderConfig(
            issuer: "https://auth.x.ai",
            clientID: "client-1",
            scopes: ["offline_access", "grok-cli:access"],
            principalType: "Team",
            principalID: "team-123",
            referrer: "grok-build"
        )
        let url = buildXAIAuthorizeURL(
            authorizationEndpoint: "https://auth.x.ai/authorize",
            oidc: oauth2.asOIDC(),
            oauth2: oauth2,
            redirectURI: "http://127.0.0.1:9999/callback",
            pkce: PKCE(codeVerifier: "v", codeChallenge: "c"),
            state: "state123",
            nonce: "nonce123"
        )!
        let s = url.absoluteString
        #expect(s.contains("&principal_type=Team&principal_id=team-123&referrer=grok-build"))
        #expect(s.components(separatedBy: "referrer=").count == 2)
    }

    @Test func referrerOverrideWinsOnce() {
        // `authorize_url_uses_oauth2_referrer_override_once`
        // (protocol.rs:868-909).
        let oauth2 = OAuth2ProviderConfig(
            issuer: "https://auth.x.ai",
            clientID: "client-1",
            scopes: ["offline_access"],
            referrer: "grok-desktop"
        )
        let url = buildXAIAuthorizeURL(
            authorizationEndpoint: "https://auth.x.ai/authorize",
            oidc: oauth2.asOIDC(),
            oauth2: oauth2,
            redirectURI: "http://127.0.0.1:9999/callback",
            pkce: PKCE(codeVerifier: "v", codeChallenge: "c"),
            state: "s",
            nonce: "n"
        )!
        #expect(url.absoluteString.hasSuffix("&referrer=grok-desktop"))
        #expect(!url.absoluteString.contains("referrer=grok-build"))
    }
}

// MARK: - Flow against the real listener and store

@Suite("xAI browser login flow", .serialized)
struct XAIBrowserLoginFlowTests {
    @Test func personalLoginLandsInRealStoreUnderTheOAuthScope() async throws {
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        let authURLBox = URLBox()

        let auth = try await loginXAIBrowser(
            manager: manager,
            environment: env,
            transport: transport,
            openBrowser: drivingBrowser(transport: transport, authURLBox: authURLBox)
        )

        #expect(auth.key == "xai-access-token")
        #expect(auth.refreshToken == "xai-refresh-token")
        #expect(auth.authMode == .oidc)
        #expect(auth.email == "browser@x.ai")
        #expect(auth.userID == "user-42")
        #expect(auth.oidcIssuer == "http://127.0.0.1:9")

        // The credential landed in the REAL auth.json under the OAuth scope
        // (`issuer::client_id`) — the same entry `/logout` clears.
        let authFile = home.appendingPathComponent("auth.json")
        #expect(FileManager.default.fileExists(atPath: authFile.path))
        let content = try String(contentsOf: authFile, encoding: .utf8)
        #expect(content.contains("xai-access-token"))
        // Parse, don't substring: the auth encoder escapes forward slashes
        // (JSON "http:\/\/…"), so a raw contains() on the scope key can
        // never match the file bytes.
        let storeKeys = (try JSONSerialization.jsonObject(
            with: Data(contentsOf: authFile)
        ) as? [String: Any])?.keys.sorted() ?? []
        #expect(storeKeys.contains("http://127.0.0.1:9::client-under-test"))
        #expect(await manager.current()?.key == "xai-access-token")

        // The authorize URL the browser received, parameter by parameter
        // against upstream's construction — live redirect port included.
        let authURL = try #require(authURLBox.get())
        let s = authURL.absoluteString
        #expect(s.hasPrefix(
            "http://127.0.0.1:9/authorize?response_type=code&client_id=client-under-test&redirect_uri=http%3A%2F%2F127.0.0.1%3A"))
        #expect(s.contains("&scope=openid%20profile%20email%20offline_access%20grok-cli%3Aaccess"))
        #expect(s.contains("&code_challenge_method=S256"))
        #expect(s.hasSuffix("&referrer=grok-build"))

        // The token leg carried the PKCE grant, parameter by parameter
        // (`exchange_code`, protocol.rs:404-437).
        let tokenRequest = try #require(
            transport.requests.first { $0.url.path.hasSuffix("/token") })
        let body = String(data: tokenRequest.body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=mock-code"))
        #expect(body.contains("client_id=client-under-test"))
        #expect(body.contains("code_verifier="))
        let challenge = try #require(queryValue(authURL, "code_challenge"))
        let verifier = try #require(
            body.components(separatedBy: "&")
                .first { $0.hasPrefix("code_verifier=") }?
                .components(separatedBy: "=").last)
        #expect(PKCE.from(verifier: verifier).codeChallenge == challenge)
        // Upstream stamps the client version on the exchange
        // (protocol.rs:415).
        #expect(tokenRequest.headers["x-grok-client-version"]?.isEmpty == false)
    }

    @Test func preflightAndStrayRequestsDoNotConsumeTheListener() async throws {
        // The accounts app delivers the code via cross-origin fetch, so a
        // private-network CORS preflight precedes the GET — and browsers
        // probe /favicon.ico. Neither may consume the callback accept
        // (upstream serves an axum router; the port serves an accept loop).
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        let preflightHeaders = HeaderBox()

        let openBrowser: @Sendable (URL) -> Void = { authURL in
            transport.setNonce(queryValue(authURL, "nonce"))
            guard let redirect = queryValue(authURL, "redirect_uri"),
                  let redirectURL = URL(string: redirect),
                  let port = redirectURL.port,
                  let state = queryValue(authURL, "state")
            else { return }
            Task {
                let base = "http://127.0.0.1:\(port)"
                var preflight = URLRequest(url: URL(string: "\(base)/callback")!)
                preflight.httpMethod = "OPTIONS"
                preflight.setValue("https://accounts.x.ai", forHTTPHeaderField: "Origin")
                preflight.setValue(
                    "true", forHTTPHeaderField: "Access-Control-Request-Private-Network")
                if let (_, response) = try? await URLSession.shared.data(for: preflight),
                   let http = response as? HTTPURLResponse {
                    preflightHeaders.set(http)
                }
                _ = try? await URLSession.shared.data(
                    from: URL(string: "\(base)/favicon.ico")!)
                _ = try? await URLSession.shared.data(
                    from: URL(string: "\(base)/callback?code=mock-code&state=\(state)")!)
            }
        }

        let auth = try await loginXAIBrowser(
            manager: manager,
            environment: env,
            transport: transport,
            openBrowser: openBrowser
        )
        #expect(auth.key == "xai-access-token")

        // The preflight answered with the accounts-app CORS grant, mirroring
        // upstream's `accounts_app_cors_layer` + `allow_private_network`.
        let headers = try #require(preflightHeaders.get())
        #expect(headers.value(
            forHTTPHeaderField: "Access-Control-Allow-Origin") == "https://accounts.x.ai")
        #expect(headers.value(
            forHTTPHeaderField: "Access-Control-Allow-Private-Network") == "true")
    }

    @Test func stateMismatchFailsAndPersistsNothing() async throws {
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        await #expect(throws: XAILoginFlowError.stateMismatch) {
            _ = try await loginXAIBrowser(
                manager: manager,
                environment: env,
                transport: transport,
                openBrowser: drivingBrowser(
                    transport: transport, stateOverride: "forged-state")
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test func idpErrorCallbackCarriesUpstreamCopy() async throws {
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        let openBrowser: @Sendable (URL) -> Void = { authURL in
            guard let redirect = queryValue(authURL, "redirect_uri"),
                  let redirectURL = URL(string: redirect),
                  let port = redirectURL.port,
                  let cbURL = URL(string: "http://127.0.0.1:\(port)/callback"
                    + "?error=access_denied&error_description=User%20denied")
            else { return }
            URLSession.shared.dataTask(with: cbURL).resume()
        }
        // `parse_callback_params` error formatting (login.rs:148-155) inside
        // `CallbackAuthFailed` (protocol.rs:32-33).
        await #expect(throws: XAILoginFlowError.callbackAuthFailed(
            "access_denied: User denied")) {
            _ = try await loginXAIBrowser(
                manager: manager,
                environment: env,
                transport: transport,
                openBrowser: openBrowser
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test func timeoutArmCarriesUpstreamCopyWhenBrowserNeverDelivers() async throws {
        // The browser-cannot-open behavior: upstream logs the open failure
        // and keeps waiting for the callback (login.rs:423-425) — no device
        // fallback. The flow therefore ends in the timeout arm with
        // `OidcError::CallbackTimeout`'s copy.
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        await #expect(throws: XAILoginFlowError.callbackTimeout) {
            _ = try await loginXAIBrowser(
                manager: manager,
                environment: env,
                transport: transport,
                openBrowser: { _ in },
                timeoutSeconds: 0.3
            )
        }
        #expect(XAILoginFlowError.callbackTimeout.description
            == "Login timed out after 10 minutes. Please try again.")
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test func wrongTeamUnderPinIsRejectedBeforePersist() async throws {
        // The team pin runs BEFORE the store write (login.rs:495-501): a
        // wrong-team token fails the login and writes nothing — the OIDC-arm
        // analog of upstream's
        // `external_provider_rejects_wrong_team_and_persists_nothing`.
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        transport.accessToken = buildTestJWT(payload: [
            "sub": "user-1",
            "principal_id": "team-wrong",
        ])
        var config = GrokComConfig.default(environment: env)
        config.forceLoginTeamUUID = .single("team-good")
        let manager = AuthManager(grokHome: home, config: config, environment: env)

        await #expect(throws: AuthError.self) {
            _ = try await loginXAIBrowser(
                manager: manager,
                environment: env,
                transport: transport,
                openBrowser: drivingBrowser(transport: transport)
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("auth.json").path))
        #expect(await manager.currentOrExpired() == nil)
    }

    @Test func teamPrincipalLoginNeedsNoIDToken() async throws {
        // `extract_user_info`'s team arm (protocol.rs:726-746): a
        // Team-principal token carries no id_token and the principal id
        // becomes the user id.
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        transport.accessToken = buildTestJWT(payload: [
            "sub": "user-1",
            "principal_type": "Team",
            "principal_id": "team-abc",
        ])
        transport.includeIDToken = false
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        let auth = try await loginXAIBrowser(
            manager: manager,
            environment: env,
            transport: transport,
            openBrowser: drivingBrowser(transport: transport)
        )
        #expect(auth.userID == "team-abc")
        #expect(auth.principalType == "Team")
        #expect(auth.principalID == "team-abc")
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test func personalLoginWithoutIDTokenIsRejected() async throws {
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        transport.includeIDToken = false
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        await #expect(throws: XAILoginFlowError.missingIDToken) {
            _ = try await loginXAIBrowser(
                manager: manager,
                environment: env,
                transport: transport,
                openBrowser: drivingBrowser(transport: transport)
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test func nonceMismatchIsRejectedBeforePersist() async throws {
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let transport = XAIFlowTransport()
        transport.idTokenNonceOverride = "replayed-nonce"
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: env),
            environment: env
        )
        await #expect(throws: XAILoginFlowError.nonceMismatch) {
            _ = try await loginXAIBrowser(
                manager: manager,
                environment: env,
                transport: transport,
                openBrowser: drivingBrowser(transport: transport)
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test func midSessionSamplerSeamHealsOnFirstUnauthorized() async throws {
        // The measured mid-session answer. The live sampling stack binds
        // `LiveAuthCredentialProvider(manager:)` at route-resolve time
        // (LiveCredentialResolver.resolveXAI) and reads `snapshot()` per
        // request; `AuthRetryTransport` calls `refreshAfterUnauthorized()` on
        // a 401. A mid-session browser login writes through a DIFFERENT
        // manager instance to the same auth.json, so:
        //   1. the running route keeps serving the old bearer,
        //   2. the first 401 adopts the new disk credential (sibling
        //      adoption) and the retry succeeds.
        let home = try makeXAIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = xaiTestEnvironment(home: home)
        let config = GrokComConfig.default(environment: env)

        // The session's manager, resolved before the login.
        let sessionManager = AuthManager(grokHome: home, config: config, environment: env)
        try await sessionManager.update(GrokAuth(
            key: "pre-login-session-token",
            authMode: .oidc,
            refreshToken: "pre-login-rt",
            expiresAt: Date().addingTimeInterval(3600),
            oidcIssuer: "http://127.0.0.1:9",
            oidcClientID: "client-under-test"
        ))
        let samplerSeam = LiveAuthCredentialProvider(manager: sessionManager)
        #expect(samplerSeam.snapshot().token == "pre-login-session-token")

        // `/login xai` mid-session: the flow's own fresh manager, same file.
        let transport = XAIFlowTransport()
        let flowManager = AuthManager(grokHome: home, config: config, environment: env)
        _ = try await loginXAIBrowser(
            manager: flowManager,
            environment: env,
            transport: transport,
            openBrowser: drivingBrowser(transport: transport)
        )

        // Measured: the live route still serves the pre-login bearer...
        #expect(samplerSeam.snapshot().token == "pre-login-session-token")
        // ...and the first 401 recovery adopts the fresh credential.
        #expect(await samplerSeam.refreshAfterUnauthorized())
        #expect(samplerSeam.snapshot().token == "xai-access-token")
    }
}

private final class HeaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    func set(_ value: HTTPURLResponse) { lock.lock(); response = value; lock.unlock() }
    func get() -> HTTPURLResponse? { lock.lock(); defer { lock.unlock() }; return response }
}
