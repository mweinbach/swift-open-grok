// XAIBrowserLogin.swift
//
// The interactive xAI browser OAuth login: discovery → PKCE → loopback
// callback server → browser handoff → token exchange → persist into the REAL
// xAI store (`AuthManager`, auth.json, under its file lock).
//
// Ports the loopback arm of upstream's `run_login_flow_with_config`
// (xai-grok-shell/src/auth/oidc/login.rs:372-543) plus the pieces of
// `run_auth_flow_inner` (auth/flow.rs:516-739) a TUI `/login` reaches with
// the default xAI config: no external auth provider, no devbox, device flow
// not opted in. Error copy is upstream's `OidcError` display text
// (auth/oidc/protocol.rs:17-76) byte for byte, because the transcript shows
// these strings to the user.

import Foundation
import OpenGrokHTTP
import OpenGrokVersion

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Flow-level failure whose `description` is exactly the user-facing copy —
/// `LiveAuthComposition.describe` (String(describing:)) must reproduce
/// upstream's error strings without an "Auth protocol error:" prefix.
public struct XAILoginFlowError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }

    /// Keep "10 minutes" in sync with the 600 s default of
    /// `loginXAIBrowser(timeoutSeconds:)` — upstream hardcodes the copy next
    /// to `AUTH_CALLBACK_TIMEOUT` the same way (protocol.rs:27-29).
    public static let callbackTimeout = XAILoginFlowError(
        "Login timed out after 10 minutes. Please try again.")
    public static let stateMismatch = XAILoginFlowError(
        "OIDC authentication failed: state mismatch")
    public static let missingIDToken = XAILoginFlowError(
        "OIDC token response missing id_token")
    /// Upstream wraps inner validation errors in `IdTokenValidationFailed`
    /// (protocol.rs:764), so the nonce arm carries both layers of copy.
    public static let nonceMismatch = XAILoginFlowError(
        "OIDC id_token validation failed: OIDC id_token nonce mismatch")
    /// `run_auth_flow_inner`'s no-provider bail (flow.rs:736-738).
    public static let noOAuthConfiguration = XAILoginFlowError(
        "No OAuth2 configuration available. Run `open-grok login` to authenticate, "
        + "or contact your administrator if you use enterprise SSO.")

    public static func bindLoopback(_ detail: String) -> XAILoginFlowError {
        XAILoginFlowError("failed to bind OIDC loopback server: \(detail)")
    }

    public static func callbackAuthFailed(_ detail: String) -> XAILoginFlowError {
        XAILoginFlowError("OIDC authentication failed: \(detail)")
    }
}

// MARK: - Authorize URL

/// Percent-encode exactly like Rust `urlencoding::encode`: every byte outside
/// RFC 3986 unreserved (`A-Z a-z 0-9 - _ . ~`) is `%XX`-escaped, space as
/// `%20`. `URLComponents` is NOT equivalent (it leaves `:` `/` `+` alone in
/// query position) — the D1 codex lesson was that a merely-equivalent
/// authorize URL gets rejected live, so this builder is byte-identical.
private let rfc3986Unreserved: CharacterSet = {
    var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
    allowed.formUnion(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    allowed.formUnion(CharacterSet(charactersIn: "0123456789"))
    allowed.formUnion(CharacterSet(charactersIn: "-_.~"))
    return allowed
}()

private func rfc3986Encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? value
}

/// Upstream `build_authorize_url` (auth/oidc/protocol.rs:349-393): fixed
/// parameter order — response_type, client_id, redirect_uri, scope,
/// code_challenge, code_challenge_method, state, nonce, then optional
/// audience / principal_type / principal_id, then referrer (default
/// "grok-build").
public func buildXAIAuthorizeURL(
    authorizationEndpoint: String,
    oidc: OidcAuthConfig,
    oauth2: OAuth2ProviderConfig?,
    redirectURI: String,
    pkce: PKCE,
    state: String,
    nonce: String
) -> URL? {
    var url = authorizationEndpoint
        + "?response_type=code"
        + "&client_id=\(rfc3986Encode(oidc.clientID))"
        + "&redirect_uri=\(rfc3986Encode(redirectURI))"
        + "&scope=\(rfc3986Encode(oidc.scopes.joined(separator: " ")))"
        + "&code_challenge=\(rfc3986Encode(pkce.codeChallenge))"
        + "&code_challenge_method=S256"
        + "&state=\(rfc3986Encode(state))"
        + "&nonce=\(rfc3986Encode(nonce))"
    if let audience = oidc.audience {
        url += "&audience=\(rfc3986Encode(audience))"
    }
    if let oauth2 {
        if let principalType = oauth2.principalType {
            url += "&principal_type=\(rfc3986Encode(principalType))"
        }
        if let principalID = oauth2.principalID {
            url += "&principal_id=\(rfc3986Encode(principalID))"
        }
    }
    let referrer: String = {
        if let r = oauth2?.referrer, !r.isEmpty { return r }
        return "grok-build"
    }()
    url += "&referrer=\(rfc3986Encode(referrer))"
    return URL(string: url)
}

// MARK: - Callback page

/// The styled browser page after the OAuth redirect — upstream `callback_page`
/// (auth/oidc/login.rs:72-114) with byte-identical title/message copy.
func xaiCallbackPage(title: String, message: String, isSuccess: Bool) -> String {
    let icon = isSuccess
        // Grok logo
        ? #"<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" fill="none" viewBox="0 0 33 33"><path fill="currentColor" d="m13.237 21.04 11.082-8.19c.543-.4 1.32-.244 1.578.38 1.363 3.288.754 7.241-1.957 9.955-2.71 2.714-6.482 3.31-9.93 1.954l-3.765 1.745c5.401 3.697 11.96 2.782 16.059-1.324 3.251-3.255 4.258-7.692 3.317-11.693l.008.009c-1.365-5.878.336-8.227 3.82-13.031q.123-.17.247-.345l-4.585 4.59v-.014L13.234 21.044M10.95 23.031c-3.877-3.707-3.208-9.446.1-12.755 2.446-2.449 6.454-3.448 9.952-1.979L24.76 6.56c-.677-.49-1.545-1.017-2.54-1.387A12.465 12.465 0 0 0 8.675 7.901c-3.519 3.523-4.625 8.94-2.725 13.561 1.42 3.454-.907 5.898-3.251 8.364-.83.874-1.664 1.749-2.335 2.674l10.583-9.466"/></svg>"#
        // X circle
        : #"<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" style="color:#ef4444"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>"#
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1"/>
    <meta name="color-scheme" content="light dark"/>
    <title>\(title)</title>
    <style>
      *{margin:0;padding:0;box-sizing:border-box}
      body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
        display:flex;align-items:center;justify-content:center;min-height:100vh;
        background:#0a0a0a;color:#e5e5e5}
      .card{text-align:center;display:flex;flex-direction:column;align-items:center;gap:16px;padding:48px}
      h1{font-size:18px;font-weight:600}
      p{font-size:14px;color:#a3a3a3}
      @media(prefers-color-scheme:light){
        body{background:#fafafa;color:#171717}
        p{color:#525252}
      }
    </style>
    </head>
    <body>
      <div class="card">
        \(icon)
        <h1>\(title)</h1>
        <p>\(message)</p>
      </div>
    </body>
    </html>
    """
}

// MARK: - Loopback listener

struct XAILoginCallback: Sendable {
    let code: String
    let state: String
}

/// Cross-platform `SOCK_STREAM` (Darwin: bare Int32; glibc: enum).
private var xaiSockStreamType: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

/// Loopback callback server for the xAI OAuth redirect.
///
/// Unlike the codex listener this one serves an accept LOOP: the accounts app
/// delivers the code to `/callback` via a cross-origin `fetch`, so a
/// private-network CORS preflight (`OPTIONS`) — or a stray `/favicon.ico`
/// probe — arrives before the decisive `GET /callback` and must not consume a
/// one-shot accept. CORS mirrors upstream's tower layer
/// (`accounts_app_cors_layer` + `allow_private_network(true)`,
/// auth/oidc/login.rs:117-125): only the production accounts-app origin is
/// echoed.
final class XAILoopbackListener: @unchecked Sendable {
    private var serverFd: Int32 = -1
    let port: UInt16

    /// Bind 127.0.0.1 on `port` (0 = OS-assigned). Upstream binds a random
    /// port in production and a fixed 56121 in `GROK_LOCAL_AUTH` local-dev
    /// mode (login.rs:390-401); the caller picks.
    init(port: UInt16) throws {
        guard let bound = Self.bindListener(port: port) else {
            throw XAILoginFlowError.bindLoopback("could not bind 127.0.0.1:\(port)")
        }
        self.serverFd = bound.fd
        self.port = bound.port
    }

    private static func bindListener(port: UInt16) -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, xaiSockStreamType, 0)
        guard fd >= 0 else { return nil }
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard res == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        // An ephemeral bind whose port cannot be read back would advertise
        // ":0" in the redirect_uri; fail the bind instead.
        guard nameResult == 0 else {
            close(fd)
            return nil
        }
        return (fd, UInt16(bigEndian: boundAddr.sin_port))
    }

    func closeListener() {
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
    }

    /// Serve until a decisive `/callback` request arrives or the deadline
    /// passes. Same blocking-thread + continuation shape as the codex
    /// listener; the thread is reclaimed at the timeout ceiling (an abandoned
    /// flow has no earlier cancellation, the recorded D1 limitation).
    func awaitCallback(timeoutSeconds: TimeInterval) async throws -> XAILoginCallback {
        let sFd = serverFd
        guard sFd >= 0 else {
            throw XAILoginFlowError.bindLoopback("listener is closed")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.serveUntilCallback(fd: sFd, timeoutSeconds: timeoutSeconds)
                })
            }
        }
    }

    private static func serveUntilCallback(
        fd: Int32,
        timeoutSeconds: TimeInterval
    ) throws -> XAILoginCallback {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let remainingMs = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.down))
            guard remainingMs > 0 else {
                throw XAILoginFlowError.callbackTimeout
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollRes = poll(&pfd, 1, remainingMs)
            if pollRes == 0 {
                throw XAILoginFlowError.callbackTimeout
            }
            guard pollRes > 0 else {
                if errno == EINTR { continue }
                throw XAILoginFlowError.bindLoopback("poll failed: errno \(errno)")
            }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLen)
                }
            }
            guard clientFd >= 0 else { continue }
            defer { close(clientFd) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = recv(clientFd, &buffer, buffer.count - 1, 0)
            guard bytesRead > 0,
                  let request = String(bytes: buffer[..<bytesRead], encoding: .utf8)
            else { continue }

            if let outcome = handle(request: request, clientFd: clientFd) {
                switch outcome {
                case .success(let callback): return callback
                case .failure(let error): throw error
                }
            }
            // Preflight / 404 served; keep waiting for the real callback.
        }
    }

    /// `nil` means "answered, not decisive" (preflight, unknown path).
    private static func handle(
        request: String,
        clientFd: Int32
    ) -> Result<XAILoginCallback, XAILoginFlowError>? {
        // AGENTS.md §2: `\r\n` is ONE Character, so splitting on the "\n"
        // Character never finds a CRLF boundary — `isNewline` matches both
        // CRLF (as its single grapheme) and bare LF.
        let lines = request.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        guard let rawFirst = lines.first else { return nil }
        let firstLine = String(rawFirst)
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        // Origin echo only for the production accounts app, like upstream's
        // `AllowOrigin::list` over `allowed_accounts_app_origins()`.
        let origin = headerValue("Origin", in: lines)
        let allowedOrigin = origin.flatMap { value in
            allowedAccountsAppOrigins().contains(value) ? value : nil
        }

        if method == "OPTIONS" {
            var headers = ["Allow: GET"]
            if let allowedOrigin {
                headers.append("Access-Control-Allow-Origin: \(allowedOrigin)")
                headers.append("Access-Control-Allow-Methods: GET")
                headers.append("Vary: Origin")
                if headerValue("Access-Control-Request-Private-Network", in: lines) != nil {
                    headers.append("Access-Control-Allow-Private-Network: true")
                }
            }
            respond(clientFd, status: "200 OK", extraHeaders: headers, body: "")
            return nil
        }

        let path = target.split(separator: "?", maxSplits: 1)[0]
        guard method == "GET", path == "/callback" else {
            respond(clientFd, status: "404 Not Found", extraHeaders: [], body: "")
            return nil
        }

        var params: [String: String] = [:]
        if let components = URLComponents(string: target), let items = components.queryItems {
            for item in items where params[item.name] == nil {
                params[item.name] = item.value ?? ""
            }
        }
        var corsHeaders: [String] = []
        if let allowedOrigin {
            corsHeaders = ["Access-Control-Allow-Origin: \(allowedOrigin)", "Vary: Origin"]
        }

        // `parse_callback_params` + `callback_response` (login.rs:139-170):
        // 200 for BOTH arms; only the page copy differs.
        if let code = params["code"] {
            respond(
                clientFd,
                status: "200 OK",
                extraHeaders: corsHeaders,
                body: xaiCallbackPage(
                    title: "Signed in",
                    message: "You can close this window and return to Open Grok.",
                    isSuccess: true
                )
            )
            return .success(XAILoginCallback(code: code, state: params["state"] ?? ""))
        }
        let error = params["error"] ?? ""
        let desc = params["error_description"] ?? ""
        respond(
            clientFd,
            status: "200 OK",
            extraHeaders: corsHeaders,
            body: xaiCallbackPage(
                title: "Access denied",
                message: "Close this window and try again.",
                isSuccess: false
            )
        )
        return .failure(.callbackAuthFailed(desc.isEmpty ? error : "\(error): \(desc)"))
    }

    private static func headerValue(
        _ name: String,
        in lines: [Substring]
    ) -> String? {
        let prefix = name.lowercased() + ":"
        for line in lines.dropFirst() {
            if line.isEmpty { break } // end of headers
            if line.lowercased().hasPrefix(prefix) {
                return line.dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func respond(
        _ clientFd: Int32,
        status: String,
        extraHeaders: [String],
        body: String
    ) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(body.utf8.count)\r\n"
        response += "Connection: close\r\n"
        for header in extraHeaders {
            response += header + "\r\n"
        }
        response += "\r\n"
        response += body
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBufferPointer { ptr in
            send(clientFd, ptr.baseAddress, ptr.count, 0)
        }
    }
}

// MARK: - Flow

/// The loopback redirect the flow registers — numeric `127.0.0.1`, unlike the
/// codex flow's `localhost` (upstream login.rs:402 vs codex_auth.rs:801).
public func xaiLoginRedirectURI(port: UInt16) -> String {
    "http://127.0.0.1:\(port)/callback"
}

/// Interactive xAI browser OAuth login into the REAL store.
///
/// Force-interactive like upstream's TUI `/login` (`run_auth_flow_interactive`,
/// flow.rs:495-514): never reuses a cached credential, never pre-clears the
/// store, persists only on success — abandoning the browser does not log the
/// user out.
///
/// `environment` is required, not process-defaulted: the issuer choice
/// (`GROK_LOCAL_AUTH`) must come from the session's environment, the same
/// silent-divergence footgun AGENTS.md §2 records for process-cwd defaults.
///
/// Not ported here, recorded divergences: the external-auth-provider and
/// devbox pre-flight arms (flow.rs:640-686), the opt-in device-flow transport
/// (flow.rs:699-724), the manual paste channel (upstream's TUI paste box,
/// login.rs:246-298), and post-exchange `/user` profile enrichment
/// (`enrich_auth_inline`, login.rs:535). Personal id_tokens ARE validated
/// via JWKS (`validateOIDCIdToken`, protocol.rs:639-715); external/devbox/
/// device arms remain deferred. The server still re-validates the signed
/// access token on every API call (upstream's stated security boundary,
/// protocol.rs:164-172).
public func loginXAIBrowser(
    manager: AuthManager,
    environment: [String: String],
    transport: any HTTPTransport,
    callbackPort: UInt16? = nil,
    openBrowser: (@Sendable (URL) -> Void)? = nil,
    timeoutSeconds: TimeInterval = 600
) async throws -> GrokAuth {
    try Task.checkCancellation()
    let config = manager.grokComConfig
    guard let oidc = config.effectiveOIDC else {
        throw XAILoginFlowError.noOAuthConfiguration
    }

    let discovery = try await fetchOIDCDiscovery(issuer: oidc.issuer, transport: transport)
    let pkce = PKCE.generate()
    // Upstream mints UUIDv7 strings (login.rs:387-388); lowercase UUID here —
    // same charset, no percent-encoding difference on the wire.
    let state = UUID().uuidString.lowercased()
    let nonce = UUID().uuidString.lowercased()

    // Fixed callback port only in local-dev mode so the redirect_uri can be
    // pre-registered with the local accounts app (login.rs:390-397).
    let port = callbackPort ?? (useLocalAuth(environment: environment) ? 56121 : 0)
    let listener = try XAILoopbackListener(port: port)
    defer { listener.closeListener() }
    let redirectURI = xaiLoginRedirectURI(port: listener.port)

    guard let authURL = buildXAIAuthorizeURL(
        authorizationEndpoint: discovery.authorizationEndpoint,
        oidc: oidc,
        oauth2: config.oauth2,
        redirectURI: redirectURI,
        pkce: pkce,
        state: state,
        nonce: nonce
    ) else {
        throw XAILoginFlowError(
            "OIDC authentication failed: could not construct authorize URL")
    }

    // Browser-open failure is non-fatal upstream (login.rs:423-425 logs and
    // keeps waiting); the caller has already surfaced the URL for manual
    // opening.
    if let openBrowser {
        openBrowser(authURL)
    }

    let callback = try await listener.awaitCallback(timeoutSeconds: timeoutSeconds)
    try Task.checkCancellation()

    // Empty state only happens on upstream's bare-code paste path; the
    // loopback redirect always carries it (login.rs:468-471).
    if !callback.state.isEmpty, callback.state != state {
        throw XAILoginFlowError.stateMismatch
    }

    guard let tokenEndpoint = URL(string: discovery.tokenEndpoint) else {
        throw XAILoginFlowError("OIDC discovery returned an invalid token endpoint")
    }
    let tokens = try await exchangeAuthorizationCode(
        tokenEndpoint: tokenEndpoint,
        clientID: oidc.clientID,
        code: callback.code,
        redirectURI: redirectURI,
        codeVerifier: pkce.codeVerifier,
        transport: transport
    )
    try Task.checkCancellation()

    // Team pin BEFORE persist (login.rs:495-501): a mismatch fails the login
    // and writes nothing. Enforced on the access token's principal_id claim,
    // upstream's exact input.
    try enforceLoginPrincipal(
        policy: config.forceLoginTeamUUID,
        actual: peekAccessTokenPrincipalID(tokens.accessToken)
    )

    // Personal logins require a JWKS-validated id_token; team-principal tokens
    // don't carry one (`extract_user_info`, protocol.rs:716-747).
    let principal = peekAccessTokenPrincipal(tokens.accessToken)
    var validatedSubject: String?
    if principal?.principalType != teamPrincipalType {
        guard let idToken = tokens.idToken else {
            throw XAILoginFlowError.missingIDToken
        }
        // Prefer the JWKS-validated subject over an unverified payload decode
        // inside `buildGrokAuthFromOIDCTokens` (protocol.rs:695-715).
        let validatedClaims = try await validateOIDCIdToken(
            token: idToken,
            discovery: discovery,
            expectedIssuer: oidc.issuer,
            expectedClientID: oidc.clientID,
            expectedNonce: nonce,
            transport: transport
        )
        validatedSubject = validatedClaims.sub
    }

    var auth = buildGrokAuthFromOIDCTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        idToken: tokens.idToken,
        expiresIn: tokens.expiresIn,
        issuer: oidc.issuer,
        clientID: oidc.clientID
    )
    if let principal, principal.principalType == teamPrincipalType {
        // Team arm: the principal id IS the user id (protocol.rs:726-729).
        auth.userID = principal.principalID
    } else if auth.userID.isEmpty,
              let validatedSubject {
        auth.userID = validatedSubject
    }

    // The one store write: AuthManager.update under the auth.json file lock.
    try await manager.loginWithSession(auth)
    return auth
}
