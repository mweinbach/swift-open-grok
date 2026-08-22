// LoginLogout.swift
//
// High-level login/logout orchestration for xAI and Codex scopes.

import Foundation
import COpenGrokSockets
import OpenGrokHTTP
import OpenGrokPaths

/// Which account store a login/logout command targets.
public enum AuthAccountTarget: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Bare `open-grok login` / `logout` — xAI only.
    case xai
    /// `open-grok login --codex` / `logout --codex`.
    case codex
    /// `open-grok login --kimi` / `logout --kimi`.
    case kimi
    /// `open-grok login --fireworks` / `logout --fireworks`.
    case fireworks
    /// `open-grok login --deepseek` / `logout --deepseek`.
    case deepseek
    /// `open-grok login --meta` / `logout --meta`.
    case meta
    /// `open-grok login --opencode-go` / `logout --opencode-go`.
    case openCodeGo = "opencode_go"
    /// `open-grok login --wafer` / `logout --wafer`.
    case wafer
    /// `open-grok login --zai` / `logout --zai`.
    case zai
    /// `open-grok login --runinfra` / `logout --runinfra`.
    case runinfra
    /// `open-grok login --gemini` / `logout --gemini`.
    case gemini
    /// `open-grok login --openrouter` / `logout --openrouter`.
    case openRouter = "openrouter"
    /// `logout --all` — both stores and all provider scopes independently.
    case all

    public init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "xai": self = .xai
        case "codex": self = .codex
        case "kimi": self = .kimi
        case "fireworks": self = .fireworks
        case "deepseek": self = .deepseek
        case "meta": self = .meta
        case "opencode_go", "opencode-go", "opencodego": self = .openCodeGo
        case "wafer": self = .wafer
        case "zai": self = .zai
        case "runinfra", "run_infra", "run-infra": self = .runinfra
        case "gemini", "google", "google_gemini", "google-gemini", "ai_studio", "ai-studio",
             "aistudio", "gemini_api", "gemini-api": self = .gemini
        case "openrouter", "open_router", "open-router": self = .openRouter
        case "all": self = .all
        default: return nil
        }
    }
}

/// Outcome of a multi-target logout.
public struct MultiLogoutResult: Sendable, Equatable {
    public var xai: LogoutResult?
    public var codexRemoved: Bool?
    public var removedScopes: [String]
    public var provider: String?

    public init(
        xai: LogoutResult? = nil,
        codexRemoved: Bool? = nil,
        removedScopes: [String] = [],
        provider: String? = nil
    ) {
        self.xai = xai
        self.codexRemoved = codexRemoved
        self.removedScopes = removedScopes
        self.provider = provider
    }
}

/// Login with an API key into the xAI store.
public func loginXAIWithAPIKey(
    manager: AuthManager,
    apiKey: String
) async throws {
    try await manager.loginWithAPIKey(apiKey)
}

/// Login with a pre-built OIDC session (after browser/device/external flow).
public func loginXAIWithSession(
    manager: AuthManager,
    auth: GrokAuth,
    policy: ForceLoginTeam? = nil
) async throws {
    if let policy {
        let actual = auth.teamID ?? auth.principalID
            ?? peekAccessTokenPrincipalID(auth.key)
        try enforceLoginPrincipal(policy: policy, actual: actual)
    }
    try await manager.loginWithSession(auth)
}

import Foundation
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokPaths

/// Persist Codex OAuth tokens without touching xAI auth.json.
public func loginCodex(
    authFile: URL,
    idToken: String,
    accessToken: String,
    refreshToken: String,
    accountID: String? = nil
) throws {
    try persistCodexTokens(
        at: authFile,
        idToken: idToken,
        accessToken: accessToken,
        refreshToken: refreshToken,
        accountID: accountID
    )
}

/// Interactive or headless Codex browser OAuth login flow.
public func loginCodexBrowser(
    authFile: URL,
    endpoints: CodexEndpoints = .fromEnvironment(),
    transport: any HTTPTransport,
    callbackPort: UInt16? = nil,
    announce: Bool = false,
    openBrowser: (@Sendable (URL) -> Void)? = nil,
    timeoutSeconds: TimeInterval = 600
) async throws -> CodexCredentials {
    try Task.checkCancellation()
    let pkce = PKCE.generate()
    let state = generateOAuthState()
    let listener = try CodexCallbackListener(
        preferredPort: callbackPort ?? 1455,
        fallbackPort: callbackPort ?? 1457
    )
    defer { listener.closeListener() }
    let redirectURI = codexRedirectURI(port: listener.port)
    guard let authURL = buildCodexAuthorizeURL(
        endpoints: endpoints,
        redirectURI: redirectURI,
        pkce: pkce,
        state: state
    ) else {
        throw AuthError.protocolError("failed to construct Codex authorize URL")
    }

    if announce {
        print("\nSigning in to OpenAI Codex with ChatGPT...")
        print("Open this URL if your browser does not open automatically:")
        print("  \(authURL.absoluteString)\n")
    }

    if let openBrowser {
        openBrowser(authURL)
    }

    let callback = try await listener.acceptOneCallback(timeoutSeconds: timeoutSeconds)
    try Task.checkCancellation()
    guard callback.state == state else {
        throw AuthError.protocolError("Codex OAuth callback state mismatch")
    }
    guard !callback.code.isEmpty else {
        throw AuthError.protocolError("Codex OAuth callback code is missing")
    }

    let tokens = try await exchangeCodexAuthCode(
        endpoints: endpoints,
        code: callback.code,
        redirectURI: redirectURI,
        codeVerifier: pkce.codeVerifier,
        transport: transport
    )

    try persistCodexTokens(
        at: authFile,
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        accountID: tokens.accountID
    )

    guard let creds = try loadCodexCredentials(at: authFile) else {
        throw AuthError.storage("failed to load credentials after Codex browser login")
    }
    return creds
}

public struct CodexDeviceUserCodeResponse: Codable, Sendable {
    public var deviceAuthID: String
    public var userCode: String
    public var interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case interval
    }

    public init(deviceAuthID: String, userCode: String, interval: Int? = nil) {
        self.deviceAuthID = deviceAuthID
        self.userCode = userCode
        self.interval = interval
    }
}

public struct CodexDeviceTokenResponse: Codable, Sendable {
    public var authorizationCode: String
    public var codeVerifier: String
    public var codeChallenge: String

    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeVerifier = "code_verifier"
        case codeChallenge = "code_challenge"
    }

    public init(authorizationCode: String, codeVerifier: String, codeChallenge: String) {
        self.authorizationCode = authorizationCode
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
    }
}

/// Interactive Codex device-code login flow.
public func loginCodexDevice(
    authFile: URL,
    endpoints: CodexEndpoints = .fromEnvironment(),
    transport: any HTTPTransport,
    openBrowser: (@Sendable (URL) -> Void)? = nil,
    timeoutSeconds: TimeInterval = 900
) async throws -> CodexCredentials {
    try Task.checkCancellation()
    let issuer = endpoints.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let userCodeURL = URL(string: "\(issuer)/api/accounts/deviceauth/usercode") else {
        throw AuthError.protocolError("invalid Codex issuer URL")
    }
    let reqBody = try JSONSerialization.data(withJSONObject: ["client_id": endpoints.clientID])
    let req = HTTPRequest(
        method: .post,
        url: userCodeURL,
        headers: ["Content-Type": "application/json"],
        body: reqBody,
        timeout: 30,
        idempotency: .nonIdempotent
    )
    let resp = try await transport.send(req)
    try Task.checkCancellation()
    guard (200..<300).contains(resp.metadata.statusCode),
          let device = try? JSONDecoder().decode(CodexDeviceUserCodeResponse.self, from: resp.body)
    else {
        throw AuthError.protocolError("Codex device-code request failed: HTTP \(resp.metadata.statusCode)")
    }

    let verificationURLStr = "\(issuer)/codex/device"
    if let openBrowser, let u = URL(string: verificationURLStr) {
        openBrowser(u)
    }

    let pollInterval = TimeInterval(max(device.interval ?? 5, 1))
    guard let tokenURL = URL(string: "\(issuer)/api/accounts/deviceauth/token") else {
        throw AuthError.protocolError("invalid Codex device token URL")
    }

    let pollStart = Date()
    var codeResp: CodexDeviceTokenResponse?
    while Date().timeIntervalSince(pollStart) < timeoutSeconds {
        try Task.checkCancellation()
        let pollBody = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": device.deviceAuthID,
            "user_code": device.userCode,
        ])
        let pollReq = HTTPRequest(
            method: .post,
            url: tokenURL,
            headers: ["Content-Type": "application/json"],
            body: pollBody,
            timeout: 30,
            idempotency: .nonIdempotent
        )
        let pollRes = try await transport.send(pollReq)
        try Task.checkCancellation()
        if (200..<300).contains(pollRes.metadata.statusCode) {
            if let decoded = try? JSONDecoder().decode(CodexDeviceTokenResponse.self, from: pollRes.body) {
                codeResp = decoded
                break
            }
        } else if pollRes.metadata.statusCode != 403 && pollRes.metadata.statusCode != 404 {
            throw AuthError.protocolError("Codex device-code login returned \(pollRes.metadata.statusCode)")
        }
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }

    guard let tokenInfo = codeResp else {
        throw AuthError.protocolError("Codex device-code login timed out")
    }
    guard !tokenInfo.codeChallenge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AuthError.protocolError("Codex device-code response omitted its PKCE challenge")
    }

    let redirectURI = "\(issuer)/deviceauth/callback"
    let tokens = try await exchangeCodexAuthCode(
        endpoints: endpoints,
        code: tokenInfo.authorizationCode,
        redirectURI: redirectURI,
        codeVerifier: tokenInfo.codeVerifier,
        transport: transport
    )

    try persistCodexTokens(
        at: authFile,
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        accountID: tokens.accountID
    )

    guard let creds = try loadCodexCredentials(at: authFile) else {
        throw AuthError.storage("failed to load credentials after Codex device login")
    }
    return creds
}

/// Exchange an authorization code for Codex OAuth tokens.
public func exchangeCodexAuthCode(
    endpoints: CodexEndpoints = .fromEnvironment(),
    code: String,
    redirectURI: String,
    codeVerifier: String,
    transport: any HTTPTransport
) async throws -> (idToken: String, accessToken: String, refreshToken: String, accountID: String?) {
    try Task.checkCancellation()
    let base = endpoints.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(base)/oauth/token") else {
        throw AuthError.protocolError("invalid Codex issuer URL")
    }
    let body = formURLEncoded([
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirectURI,
        "client_id": endpoints.clientID,
        "code_verifier": codeVerifier,
    ])
    let request = HTTPRequest(
        method: .post,
        url: url,
        headers: ["Content-Type": "application/x-www-form-urlencoded"],
        body: Data(body.utf8),
        timeout: 30,
        idempotency: .nonIdempotent
    )
    let response = try await transport.send(request)
    try Task.checkCancellation()
    guard (200..<300).contains(response.metadata.statusCode) else {
        let codeErr = oauthErrorCode(from: response.body)
        throw AuthError.protocolError(
            "Codex OAuth token exchange returned \(response.metadata.statusCode)"
                + (codeErr.map { " (\($0))" } ?? "")
        )
    }
    guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let idToken = json["id_token"] as? String,
          let accessToken = json["access_token"] as? String,
          let refreshToken = json["refresh_token"] as? String
    else {
        throw AuthError.protocolError("Codex OAuth token response was invalid")
    }
    try validateCodexTokens(idToken: idToken, accessToken: accessToken, refreshToken: refreshToken)
    let accountID = (json["account_id"] as? String) ?? accountIDFromIDToken(idToken)
    return (idToken, accessToken, refreshToken, accountID)
}

internal struct CodexCallbackResponse: Sendable {
    let code: String
    let state: String
}

internal final class CodexCallbackListener: @unchecked Sendable {
    private var serverFd: OGSocketHandle = -1
    let port: UInt16

    init(preferredPort: UInt16 = 1455, fallbackPort: UInt16 = 1457) throws {
        if let bound = CodexCallbackListener.bindListener(port: preferredPort) {
            self.serverFd = bound.fd
            self.port = bound.port
        } else if let bound = CodexCallbackListener.bindListener(port: fallbackPort) {
            self.serverFd = bound.fd
            self.port = bound.port
        } else if let bound = CodexCallbackListener.bindListener(port: 0) {
            self.serverFd = bound.fd
            self.port = bound.port
        } else {
            throw AuthError.protocolError("Could not bind local Codex OAuth callback listener")
        }
    }

    // Named `bindListener` rather than `bind` so the libc `bind(2)` below
    // resolves without module-qualifying it — the qualifier would have to name
    // Darwin on Apple and Glibc on Linux.
    private static func bindListener(port: UInt16) -> (fd: OGSocketHandle, port: UInt16)? {
        var fd: OGSocketHandle = -1
        var boundPort: UInt16 = 0
        guard og_socket_tcp_listen("127.0.0.1", port, &fd, &boundPort) == 0 else {
            return nil
        }
        return (fd, boundPort)
    }

    func closeListener() {
        if serverFd >= 0 {
            _ = og_socket_close(serverFd)
            serverFd = -1
        }
    }

    func acceptOneCallback(timeoutSeconds: TimeInterval) async throws -> CodexCallbackResponse {
        let sFd = serverFd
        guard sFd >= 0 else {
            throw AuthError.protocolError("Callback listener is closed")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var clientFd: OGSocketHandle = -1
                let acceptResult = og_socket_accept_with_timeout(
                    sFd, timeoutSeconds, &clientFd)
                if acceptResult != 0 {
                    continuation.resume(throwing: AuthError.protocolError("timed out waiting for the Codex OAuth callback"))
                    return
                }
                defer { _ = og_socket_close(clientFd) }

                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                    og_socket_read(clientFd, rawBuffer.baseAddress, rawBuffer.count - 1)
                }
                guard bytesRead > 0,
                      let reqStr = String(bytes: buffer[..<Int(bytesRead)], encoding: .utf8)
                else {
                    continuation.resume(throwing: AuthError.protocolError("Codex OAuth callback payload was empty"))
                    return
                }

                let html = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Connection: close\r
                \r
                <html><body><h1>Sign in successful</h1><p>You can close this tab and return to Open Grok.</p></body></html>
                """
                let responseBytes = Array(html.utf8)
                _ = responseBytes.withUnsafeBufferPointer {
                    og_socket_write_all(clientFd, $0.baseAddress, $0.count)
                }

                guard let firstLine = reqStr.components(separatedBy: "\r\n").first,
                      firstLine.hasPrefix("GET ")
                else {
                    continuation.resume(throwing: AuthError.protocolError("invalid HTTP request in callback"))
                    return
                }

                let target = firstLine.split(separator: " ")[1]
                guard let components = URLComponents(string: String(target)),
                      let queryItems = components.queryItems
                else {
                    continuation.resume(throwing: AuthError.protocolError("invalid URI in callback"))
                    return
                }

                let code = queryItems.first(where: { $0.name == "code" })?.value ?? ""
                let state = queryItems.first(where: { $0.name == "state" })?.value ?? ""
                continuation.resume(returning: CodexCallbackResponse(code: code, state: state))
            }
        }
    }
}

/// Logout by target. Codex-only never requires xAI auth.
public func logout(
    target: AuthAccountTarget,
    manager: AuthManager? = nil,
    codexAuthFile: URL? = nil,
    codexTransport: (any HTTPTransport)? = nil,
    codexEndpoints: CodexEndpoints = .fromEnvironment(),
    grokHome: URL? = nil
) async throws -> MultiLogoutResult {
    var result = MultiLogoutResult()
    result.provider = target.rawValue

    let resolvedGrokHome: URL
    if let grokHome {
        resolvedGrokHome = grokHome
    } else if let manager {
        resolvedGrokHome = await manager.authFilePath.deletingLastPathComponent()
    } else if let codexAuthFile {
        resolvedGrokHome = codexAuthFile.deletingLastPathComponent()
    } else {
        resolvedGrokHome = OpenGrokStatePaths.stateDirectory(environment: ProcessInfo.processInfo.environment)
    }

    switch target {
    case .xai:
        guard let manager else {
            throw AuthError.protocolError("xAI AuthManager required for xAI logout")
        }
        result.xai = try await manager.clear()

    case .codex:
        guard let codexAuthFile else {
            throw AuthError.protocolError("codex auth path required")
        }
        result.codexRemoved = try await logoutCodex(
            at: codexAuthFile,
            endpoints: codexEndpoints,
            transport: codexTransport
        )

    case .kimi:
        let platformScope = kimiAPIKeyScope(.platform)
        let codeScope = kimiCodeAPIKeyScope
        try clearKimiAPIKey(grokHome: resolvedGrokHome, endpoint: .platform)
        try clearKimiAPIKey(grokHome: resolvedGrokHome, endpoint: .code)
        result.removedScopes = [platformScope, codeScope]

    case .fireworks:
        try clearFireworksAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [fireworksAPIKeyScope]

    case .deepseek:
        try clearDeepSeekAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [deepseekAPIKeyScope]

    case .meta:
        try clearMetaAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [metaAPIKeyScope]

    case .openCodeGo:
        try clearOpenCodeGoAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [openCodeGoAPIKeyScope]

    case .wafer:
        try clearWaferAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [waferAPIKeyScope]

    case .zai:
        try clearZaiAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [zaiAPIKeyScope]

    case .runinfra:
        try clearRunInfraAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [runInfraAPIKeyScope]

    case .gemini:
        try clearGeminiAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [geminiAPIKeyScope]

    case .openRouter:
        try clearOpenRouterAPIKey(grokHome: resolvedGrokHome)
        result.removedScopes = [openRouterAPIKeyScope]

    case .all:
        if let manager {
            result.xai = try await manager.clear()
        }
        if let codexAuthFile {
            result.codexRemoved = try await logoutCodex(
                at: codexAuthFile,
                endpoints: codexEndpoints,
                transport: codexTransport
            )
        }
        for scope in allProviderAPIKeyScopes {
            try clearScopedAPIKey(grokHome: resolvedGrokHome, scope: scope)
            result.removedScopes.append(scope)
        }
    }
    return result
}


/// Resolve effective credential precedence for outbound xAI requests:
/// 1. Deployment key (env)
/// 2. Explicit model/BYOK API key (caller-supplied)
/// 3. AuthManager session / stored API key
/// 4. XAI_API_KEY env
public struct CredentialPrecedence: Sendable, Equatable {
    public var deploymentKey: String?
    public var explicitAPIKey: String?
    public var session: GrokAuth?
    public var envAPIKey: String?

    public init(
        deploymentKey: String? = nil,
        explicitAPIKey: String? = nil,
        session: GrokAuth? = nil,
        envAPIKey: String? = nil
    ) {
        self.deploymentKey = deploymentKey
        self.explicitAPIKey = explicitAPIKey
        self.session = session
        self.envAPIKey = envAPIKey
    }

    /// Atomic credentials for HTTP apply.
    public var resolved: GrokAuthCredentials {
        if let dk = deploymentKey, !dk.isEmpty {
            return GrokAuthCredentials(deploymentKey: dk)
        }
        if let key = explicitAPIKey, !key.isEmpty {
            return GrokAuthCredentials(userToken: key)
        }
        if let session {
            return GrokAuthCredentials(userToken: session.key)
        }
        if let env = envAPIKey, !env.isEmpty {
            return GrokAuthCredentials(userToken: env)
        }
        return GrokAuthCredentials()
    }

    public var snapshot: CredentialSnapshot {
        let creds = resolved
        if let dk = creds.deploymentKey {
            return CredentialSnapshot(token: dk, deploymentID: deploymentIDFromKey(dk))
        }
        if let session, creds.userToken == session.key {
            return credentialSnapshot(from: session)
        }
        if let token = creds.userToken {
            // Explicit / env API key — emit api_key_id only.
            return CredentialSnapshot(
                token: token,
                apiKeyID: deploymentIDFromKey(token)
            )
        }
        return CredentialSnapshot()
    }
}

public func resolveCredentialPrecedence(
    manager: AuthManager,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    explicitAPIKey: String? = nil
) async -> CredentialPrecedence {
    let session = await manager.currentOrExpired()
    return CredentialPrecedence(
        deploymentKey: deploymentKeyFromEnvironment(environment),
        explicitAPIKey: explicitAPIKey,
        session: session,
        envAPIKey: xaiAPIKeyFromEnvironment(environment)
    )
}

/// Whether Codex-only headless startup can proceed without xAI auth.
public func codexOnlyHeadlessReady(codexAuthFile: URL) -> Bool {
    isCodexLoggedIn(at: codexAuthFile)
}
