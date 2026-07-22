// Config.swift
//
// Auth configuration: GrokComConfig, OIDC/OAuth2 scopes, preferred method.

import Foundation
import OpenGrokEnvironment

/// Pin automatic auth to one method (`[auth] preferred_method`).
public enum PreferredAuthMethod: String, Codable, Sendable, Equatable, Hashable {
    case apiKey = "api_key"
    case oidc
}

/// Team login restriction.
public enum ForceLoginTeam: Sendable, Equatable, Hashable {
    case single(String)
    case anyOf([String])

    public var allowedIDs: [String] {
        switch self {
        case .single(let id): return [id]
        case .anyOf(let ids): return ids
        }
    }
}

/// Customer OIDC IdP configuration.
public struct OidcAuthConfig: Sendable, Equatable, Codable {
    public var issuer: String
    public var clientID: String
    public var scopes: [String]
    public var audience: String?

    public init(
        issuer: String,
        clientID: String,
        scopes: [String] = defaultOIDCScopes,
        audience: String? = nil
    ) {
        self.issuer = issuer
        self.clientID = clientID
        self.scopes = scopes
        self.audience = audience
    }

    enum CodingKeys: String, CodingKey {
        case issuer
        case clientID = "client_id"
        case scopes
        case audience
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OidcAuthConfig? {
        guard let issuer = environment["GROK_OIDC_ISSUER"],
              let clientID = environment["GROK_OIDC_CLIENT_ID"] else {
            return nil
        }
        let scopes = environment["GROK_OIDC_SCOPES"]
            .map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            ?? defaultOIDCScopes
        return OidcAuthConfig(
            issuer: issuer,
            clientID: clientID,
            scopes: scopes,
            audience: environment["GROK_OIDC_AUDIENCE"]
        )
    }
}

/// OAuth2 provider configuration.
public struct OAuth2ProviderConfig: Sendable, Equatable, Codable {
    public var issuer: String
    public var clientID: String
    public var scopes: [String]
    public var principalType: String?
    public var principalID: String?
    public var referrer: String?

    public init(
        issuer: String,
        clientID: String,
        scopes: [String] = defaultOAuth2Scopes,
        principalType: String? = nil,
        principalID: String? = nil,
        referrer: String? = "grok-build"
    ) {
        self.issuer = issuer
        self.clientID = clientID
        self.scopes = scopes
        self.principalType = principalType
        self.principalID = principalID
        self.referrer = referrer
    }

    enum CodingKeys: String, CodingKey {
        case issuer
        case clientID = "client_id"
        case scopes
        case principalType = "principal_type"
        case principalID = "principal_id"
        case referrer
    }

    public var isTeamPrincipal: Bool {
        principalType == teamPrincipalType
    }

    public var baseAuthScope: String {
        "\(issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")))::\(clientID)"
    }

    public var authScope: String { baseAuthScope }

    public func asOIDC() -> OidcAuthConfig {
        OidcAuthConfig(issuer: issuer, clientID: clientID, scopes: scopes, audience: nil)
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OAuth2ProviderConfig? {
        guard let issuer = environment["GROK_OAUTH2_ISSUER"],
              let clientID = environment["GROK_OAUTH2_CLIENT_ID"] else {
            return nil
        }
        let principalType = environment["GROK_OAUTH2_PRINCIPAL_TYPE"]
        let defaultScopes = principalType == teamPrincipalType
            ? defaultTeamOAuth2Scopes
            : defaultOAuth2Scopes
        let scopes = environment["GROK_OAUTH2_SCOPES"]
            .map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            ?? defaultScopes
        return OAuth2ProviderConfig(
            issuer: issuer,
            clientID: clientID,
            scopes: scopes,
            principalType: principalType,
            principalID: environment["GROK_OAUTH2_PRINCIPAL_ID"],
            referrer: environment["GROK_OAUTH2_REFERRER"] ?? "grok-build"
        )
    }
}

/// Production xAI OAuth2 issuer.
public let xaiOAuth2Issuer = "https://auth.x.ai"
/// Local-dev OAuth2 issuer.
public let xaiOAuth2LocalIssuer = "http://localhost:22255"
/// Default public OAuth2 client id (matches Rust `obfstr` constant).
public let defaultOAuth2ClientID = "b1a00492-073a-47ea-816f-4c329264a828"

public let defaultOIDCScopes: [String] = [
    "openid", "profile", "email", "offline_access", "api:access",
]

public let defaultOAuth2Scopes: [String] = [
    "openid", "profile", "email", "offline_access",
    "grok-cli:access", "api:access",
    "conversations:read", "conversations:write",
    "workspaces:read", "workspaces:write",
]

public let defaultTeamOAuth2Scopes: [String] = [
    "profile", "offline_access",
    "grok-cli:access", "api:access", "team:read",
    "conversations:read", "conversations:write",
    "workspaces:read", "workspaces:write",
]

public let prodAccountsAppOrigins: [String] = ["https://accounts.x.ai"]

public func useLocalAuth(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard let v = environment["GROK_LOCAL_AUTH"], !v.isEmpty, v != "0" else {
        return false
    }
    return true
}

public func xaiOAuth2Issuer(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    useLocalAuth(environment: environment) ? xaiOAuth2LocalIssuer : xaiOAuth2Issuer
}

public func isXAIOAuth2Issuer(_ issuer: String) -> Bool {
    issuer == xaiOAuth2Issuer || issuer == xaiOAuth2LocalIssuer
}

public func allowedAccountsAppOrigins() -> [String] {
    prodAccountsAppOrigins
}

/// Grok.com / auth provider configuration.
public struct GrokComConfig: Sendable, Equatable {
    public var grokWSOrigin: String
    public var grokWSURL: String
    public var tokenHeader: String
    public var oidc: OidcAuthConfig?
    public var oauth2: OAuth2ProviderConfig?
    public var authProviderCommand: String?
    public var authProviderLabel: String?
    public var authTokenTTL: UInt64?
    public var disableAPIKeyAuth: Bool?
    public var forceLoginTeamUUID: ForceLoginTeam?
    public var preferredMethod: PreferredAuthMethod?

    public init(
        grokWSOrigin: String = PROD_WS_ORIGIN,
        grokWSURL: String = PROD_RELAY_WS_URL,
        tokenHeader: String = "xai-grok-cli",
        oidc: OidcAuthConfig? = nil,
        oauth2: OAuth2ProviderConfig? = nil,
        authProviderCommand: String? = nil,
        authProviderLabel: String? = nil,
        authTokenTTL: UInt64? = nil,
        disableAPIKeyAuth: Bool? = nil,
        forceLoginTeamUUID: ForceLoginTeam? = nil,
        preferredMethod: PreferredAuthMethod? = nil
    ) {
        self.grokWSOrigin = grokWSOrigin
        self.grokWSURL = grokWSURL
        self.tokenHeader = tokenHeader
        self.oidc = oidc
        self.oauth2 = oauth2
        self.authProviderCommand = authProviderCommand
        self.authProviderLabel = authProviderLabel
        self.authTokenTTL = authTokenTTL
        self.disableAPIKeyAuth = disableAPIKeyAuth
        self.forceLoginTeamUUID = forceLoginTeamUUID
        self.preferredMethod = preferredMethod
    }

    /// Production defaults with injectable environment.
    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GrokComConfig {
        let oidc = OidcAuthConfig.fromEnvironment(environment)
        let oauth2: OAuth2ProviderConfig?
        if oidc != nil {
            oauth2 = nil
        } else {
            oauth2 = OAuth2ProviderConfig.fromEnvironment(environment)
                ?? OAuth2ProviderConfig(
                    issuer: xaiOAuth2Issuer(environment: environment),
                    clientID: defaultOAuth2ClientID,
                    scopes: defaultOAuth2Scopes
                )
        }
        let disable: Bool? = environment["GROK_DISABLE_API_KEY_AUTH"].map { envFlagEnabled($0) }
        let ttl = environment["GROK_AUTH_TOKEN_TTL"].flatMap { UInt64($0) }
        return GrokComConfig(
            grokWSOrigin: environment["GROK_WS_ORIGIN"] ?? PROD_WS_ORIGIN,
            grokWSURL: environment["GROK_WS_URL"] ?? PROD_RELAY_WS_URL,
            tokenHeader: "xai-grok-cli",
            oidc: oidc,
            oauth2: oauth2,
            authProviderCommand: environment["GROK_AUTH_PROVIDER_COMMAND"],
            authProviderLabel: environment["GROK_AUTH_PROVIDER_LABEL"],
            authTokenTTL: ttl,
            disableAPIKeyAuth: disable,
            forceLoginTeamUUID: nil,
            preferredMethod: nil
        )
    }

    public func apiKeyAuthDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        disableAPIKeyAuth == true
            || forceLoginTeamUUID != nil
            || envLockdownForced(environment: environment)
    }

    public var blocksAutomaticOIDC: Bool {
        preferredMethod == .apiKey
    }

    public var authScope: String {
        if let oidc {
            let issuer = oidc.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "\(issuer)::\(oidc.clientID)"
        }
        if let oauth2 {
            return oauth2.authScope
        }
        // Unreachable in production defaults; keep a stable fallback for tests.
        return "\(xaiOAuth2Issuer)::\(defaultOAuth2ClientID)"
    }

    public var effectiveOIDC: OidcAuthConfig? {
        oidc ?? oauth2?.asOIDC()
    }
}

/// Parse a boolean env-var value for grok on/off flags.
public func envFlagEnabled(_ value: String) -> Bool {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "", "0", "false", "off", "no": return false
    default: return true
    }
}

func envLockdownForced(
    environment: [String: String]
) -> Bool {
    environment["GROK_DISABLE_API_KEY_AUTH"].map { envFlagEnabled($0) } ?? false
}

/// Enforce force_login_team_uuid policy against an access-token principal id.
public func enforceLoginPrincipal(
    policy: ForceLoginTeam?,
    actual: String?
) throws {
    guard let policy else { return }
    let allowed = policy.allowedIDs
    if allowed.isEmpty {
        throw AuthError.pinnedTeamMismatch(
            message: "Login is blocked by your administrator: force_login_team_uuid is an empty list"
        )
    }
    if let actual, allowed.contains(actual) {
        return
    }
    let expected: String
    if allowed.count == 1 {
        expected = "team \(allowed[0])"
    } else {
        expected = "one of teams: \(allowed.joined(separator: ", "))"
    }
    throw AuthError.pinnedTeamMismatch(
        message: "This deployment requires logging into \(expected); your login returned \(actual ?? "no team principal")"
    )
}
