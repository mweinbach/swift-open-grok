// LoginLogout.swift
//
// High-level login/logout orchestration for xAI and Codex scopes.

import Foundation
import OpenGrokHTTP
import OpenGrokPaths

/// Which account store a login/logout command targets.
public enum AuthAccountTarget: String, Sendable, Equatable {
    /// Bare `open-grok login` / `logout` — xAI only.
    case xai
    /// `open-grok login --codex` / `logout --codex`.
    case codex
    /// `logout --all` — both stores, independently.
    case all
}

/// Outcome of a multi-target logout.
public struct MultiLogoutResult: Sendable, Equatable {
    public var xai: LogoutResult?
    public var codexRemoved: Bool?

    public init(xai: LogoutResult? = nil, codexRemoved: Bool? = nil) {
        self.xai = xai
        self.codexRemoved = codexRemoved
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

/// Logout by target. Codex-only never requires xAI auth.
public func logout(
    target: AuthAccountTarget,
    manager: AuthManager?,
    codexAuthFile: URL?,
    codexTransport: (any HTTPTransport)? = nil,
    codexEndpoints: CodexEndpoints = .fromEnvironment()
) async throws -> MultiLogoutResult {
    var result = MultiLogoutResult()
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
        result.codexRemoved = await logoutCodex(
            at: codexAuthFile,
            endpoints: codexEndpoints,
            transport: codexTransport
        )
    case .all:
        if let manager {
            result.xai = try await manager.clear()
        }
        if let codexAuthFile {
            result.codexRemoved = await logoutCodex(
                at: codexAuthFile,
                endpoints: codexEndpoints,
                transport: codexTransport
            )
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
