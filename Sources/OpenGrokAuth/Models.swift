// Models.swift
//
// Auth models: AuthMode, GrokAuth, CredentialSnapshot, TokenType, UserInfo.
// Wire form matches Rust `xai-grok-shell::auth::model` (snake_case JSON).

import Foundation
import OpenGrokSecrets

/// auth.json scope key for plain API key auth.
public let apiKeyScope = "xai::api_key"

/// Legacy auth.json scope key (pre-OIDC).
public let legacyAuthScope = "https://accounts.x.ai/sign-in"

/// Default token TTL when `expires_at` is absent (30 days).
public let defaultTokenTTLSeconds: TimeInterval = 30 * 24 * 60 * 60

/// Early-invalidation buffer (5 minutes) unless overridden by
/// `GROK_AUTH_EARLY_INVALIDATION_SECS`.
public let defaultEarlyInvalidationSeconds: TimeInterval = 300

/// Token provenance (debugging / auth.json only — wire-compatible).
public enum AuthMode: String, Codable, Sendable, Equatable, Hashable {
    case webLogin = "web_login"
    case oidc
    case external
    case apiKey = "api_key"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "web_login", "grok": self = .webLogin
        case "oidc": self = .oidc
        case "external": self = .external
        case "api_key": self = .apiKey
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown auth_mode"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether this mode can access `supported_in_api: false` models.
    public var isSessionAuthMode: Bool {
        switch self {
        case .webLogin, .oidc: return true
        case .external, .apiKey: return false
        }
    }
}

/// Wire value of `principal_type` for team OAuth principals.
public let teamPrincipalType = "Team"

/// Snapshot of currently effective credentials for outbound HTTP / OTLP.
///
/// All fields are taken atomically so a refresh cannot mix a new bearer with
/// stale identity headers.
public struct CredentialSnapshot: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Bearer token. `nil` when no auth is configured.
    public var token: String?
    /// User identifier matching the bearer owner.
    public var userID: String?
    /// Team identifier from OAuth.
    public var teamID: String?
    /// `uuidv5(NAMESPACE_OID, deployment_key)` for deployment-key auth only.
    public var deploymentID: String?
    /// `uuidv5(NAMESPACE_OID, api_key)` for `AuthMode.apiKey` only.
    public var apiKeyID: String?
    /// Org id from OIDC `organizationId` claim.
    public var organizationID: String?

    public init(
        token: String? = nil,
        userID: String? = nil,
        teamID: String? = nil,
        deploymentID: String? = nil,
        apiKeyID: String? = nil,
        organizationID: String? = nil
    ) {
        self.token = token
        self.userID = userID
        self.teamID = teamID
        self.deploymentID = deploymentID
        self.apiKeyID = apiKeyID
        self.organizationID = organizationID
    }

    public var description: String {
        "CredentialSnapshot(token: \(token.map { _ in SecretRedaction.secret } ?? "nil"), userID: \(userID ?? "nil"), teamID: \(teamID ?? "nil"), deploymentID: \(deploymentID ?? "nil"), apiKeyID: \(apiKeyID ?? "nil"), organizationID: \(organizationID ?? "nil"))"
    }

    public var debugDescription: String { description }
}

/// Stored credential entry (auth.json value).
public struct GrokAuth: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var key: String
    public var authMode: AuthMode
    public var createTime: Date
    public var userID: String
    public var email: String?
    public var firstName: String?
    public var lastName: String?
    public var profileImageAssetID: String?
    public var principalType: String?
    public var principalID: String?
    public var teamID: String?
    public var teamName: String?
    public var teamRole: String?
    public var organizationID: String?
    public var organizationName: String?
    public var organizationRole: String?
    public var userBlockedReason: String?
    public var teamBlockedReasons: [String]
    /// Defaults to `true` (opted out) when missing from legacy files.
    public var codingDataRetentionOptOut: Bool
    public var hasGrokCodeAccess: Bool?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var oidcIssuer: String?
    public var oidcClientID: String?

    public init(
        key: String = "",
        authMode: AuthMode = .oidc,
        createTime: Date = Date(),
        userID: String = "",
        email: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        profileImageAssetID: String? = nil,
        principalType: String? = nil,
        principalID: String? = nil,
        teamID: String? = nil,
        teamName: String? = nil,
        teamRole: String? = nil,
        organizationID: String? = nil,
        organizationName: String? = nil,
        organizationRole: String? = nil,
        userBlockedReason: String? = nil,
        teamBlockedReasons: [String] = [],
        codingDataRetentionOptOut: Bool = true,
        hasGrokCodeAccess: Bool? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        oidcIssuer: String? = nil,
        oidcClientID: String? = nil
    ) {
        self.key = key
        self.authMode = authMode
        self.createTime = createTime
        self.userID = userID
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.profileImageAssetID = profileImageAssetID
        self.principalType = principalType
        self.principalID = principalID
        self.teamID = teamID
        self.teamName = teamName
        self.teamRole = teamRole
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.organizationRole = organizationRole
        self.userBlockedReason = userBlockedReason
        self.teamBlockedReasons = teamBlockedReasons
        self.codingDataRetentionOptOut = codingDataRetentionOptOut
        self.hasGrokCodeAccess = hasGrokCodeAccess
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.oidcIssuer = oidcIssuer
        self.oidcClientID = oidcClientID
    }

    /// Test helper with sharing enabled by default.
    public static func testDefault(
        key: String = "test-key",
        userID: String = "test-user",
        authMode: AuthMode = .oidc
    ) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: authMode,
            userID: userID,
            codingDataRetentionOptOut: false
        )
    }

    public var description: String {
        "GrokAuth(key: \(tokenSuffix(key)), authMode: \(authMode), userID: \(userID), expiresAt: \(String(describing: expiresAt)), refreshToken: \(refreshToken.map { tokenSuffix($0) } ?? "nil"))"
    }

    public var debugDescription: String { description }

    public var isXAIAuth: Bool {
        switch authMode {
        case .oidc, .external:
            return oidcIssuer.map { isXAIOAuth2Issuer($0) } ?? false
        case .apiKey, .webLogin:
            return false
        }
    }

    public var isManagedMCPEligible: Bool {
        isXAIAuth || authMode == .webLogin
    }

    public var isSessionAuth: Bool {
        switch authMode {
        case .webLogin, .oidc: return true
        case .external: return isXAIAuth
        case .apiKey: return false
        }
    }

    public var isTeamPrincipal: Bool {
        principalType == teamPrincipalType && teamID != nil
    }

    public var isZDRTeam: Bool {
        teamBlockedReasons.contains("BLOCKED_REASON_NO_LOGS")
            || teamBlockedReasons.contains("BLOCKED_REASON_NO_LOGS_MODERATED")
    }

    public var isDataCollectionDisabled: Bool {
        isZDRTeam || codingDataRetentionOptOut
    }

    /// Carry `/user`-derived fields from a previous auth across refresh.
    public mutating func carryUserProfile(from prev: GrokAuth) {
        userID = prev.userID
        email = prev.email
        principalType = prev.principalType
        principalID = prev.principalID
        teamID = prev.teamID
        teamName = prev.teamName
        teamRole = prev.teamRole
        organizationID = prev.organizationID
        organizationName = prev.organizationName
        organizationRole = prev.organizationRole
        userBlockedReason = prev.userBlockedReason
        teamBlockedReasons = prev.teamBlockedReasons
        codingDataRetentionOptOut = prev.codingDataRetentionOptOut
    }

    enum CodingKeys: String, CodingKey {
        case key
        case authMode = "auth_mode"
        case createTime = "create_time"
        case userID = "user_id"
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case profileImageAssetID = "profile_image_asset_id"
        case principalType = "principal_type"
        case principalID = "principal_id"
        case teamID = "team_id"
        case teamName = "team_name"
        case teamRole = "team_role"
        case organizationID = "organization_id"
        case organizationName = "organization_name"
        case organizationRole = "organization_role"
        case userBlockedReason = "user_blocked_reason"
        case teamBlockedReasons = "team_blocked_reasons"
        case codingDataRetentionOptOut = "coding_data_retention_opt_out"
        case hasGrokCodeAccess = "has_grok_code_access"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case oidcIssuer = "oidc_issuer"
        case oidcClientID = "oidc_client_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        authMode = try c.decode(AuthMode.self, forKey: .authMode)
        createTime = try c.decode(Date.self, forKey: .createTime)
        userID = try c.decode(String.self, forKey: .userID)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        profileImageAssetID = try c.decodeIfPresent(String.self, forKey: .profileImageAssetID)
        principalType = try c.decodeIfPresent(String.self, forKey: .principalType)
        principalID = try c.decodeIfPresent(String.self, forKey: .principalID)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName)
        teamRole = try c.decodeIfPresent(String.self, forKey: .teamRole)
        organizationID = try c.decodeIfPresent(String.self, forKey: .organizationID)
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName)
        organizationRole = try c.decodeIfPresent(String.self, forKey: .organizationRole)
        userBlockedReason = try c.decodeIfPresent(String.self, forKey: .userBlockedReason)
        teamBlockedReasons = try c.decodeIfPresent([String].self, forKey: .teamBlockedReasons) ?? []
        codingDataRetentionOptOut = try c.decodeIfPresent(Bool.self, forKey: .codingDataRetentionOptOut) ?? true
        hasGrokCodeAccess = try c.decodeIfPresent(Bool.self, forKey: .hasGrokCodeAccess)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        oidcIssuer = try c.decodeIfPresent(String.self, forKey: .oidcIssuer)
        oidcClientID = try c.decodeIfPresent(String.self, forKey: .oidcClientID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(authMode, forKey: .authMode)
        try c.encode(createTime, forKey: .createTime)
        try c.encode(userID, forKey: .userID)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(firstName, forKey: .firstName)
        try c.encodeIfPresent(lastName, forKey: .lastName)
        try c.encodeIfPresent(profileImageAssetID, forKey: .profileImageAssetID)
        try c.encodeIfPresent(principalType, forKey: .principalType)
        try c.encodeIfPresent(principalID, forKey: .principalID)
        try c.encodeIfPresent(teamID, forKey: .teamID)
        try c.encodeIfPresent(teamName, forKey: .teamName)
        try c.encodeIfPresent(teamRole, forKey: .teamRole)
        try c.encodeIfPresent(organizationID, forKey: .organizationID)
        try c.encodeIfPresent(organizationName, forKey: .organizationName)
        try c.encodeIfPresent(organizationRole, forKey: .organizationRole)
        try c.encodeIfPresent(userBlockedReason, forKey: .userBlockedReason)
        if !teamBlockedReasons.isEmpty {
            try c.encode(teamBlockedReasons, forKey: .teamBlockedReasons)
        }
        try c.encode(codingDataRetentionOptOut, forKey: .codingDataRetentionOptOut)
        try c.encodeIfPresent(hasGrokCodeAccess, forKey: .hasGrokCodeAccess)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(oidcIssuer, forKey: .oidcIssuer)
        try c.encodeIfPresent(oidcClientID, forKey: .oidcClientID)
    }
}

/// Scope-keyed map of credentials (auth.json root object).
public typealias AuthStore = [String: GrokAuth]

/// Kind of bearer currently loaded (dispatch key for refresh).
public enum TokenType: String, Sendable, Equatable, Hashable {
    case oidcSession
    case legacySession
    case externalBinary
    case apiKey
    case none

    public static func from(auth: GrokAuth?) -> TokenType {
        guard let auth else { return .none }
        switch auth.authMode {
        case .oidc where auth.refreshToken != nil:
            return .oidcSession
        case .oidc, .webLogin:
            return .legacySession
        case .external:
            return .externalBinary
        case .apiKey:
            return .apiKey
        }
    }

    public var isRefreshable: Bool {
        switch self {
        case .oidcSession, .externalBinary: return true
        case .legacySession, .apiKey, .none: return false
        }
    }
}

/// Last 12 chars of a token, safe for diagnostics (JWT headers share a prefix).
public func tokenSuffix(_ t: String) -> String {
    if t.count > 12 {
        return String(t.suffix(12))
    }
    return t
}

/// Early-invalidation buffer from env or default.
public func earlyInvalidation(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> TimeInterval {
    if let raw = environment["GROK_AUTH_EARLY_INVALIDATION_SECS"],
       let secs = TimeInterval(raw) {
        return secs
    }
    return defaultEarlyInvalidationSeconds
}

/// Soft-expired when within early-invalidation buffer of hard expiry.
public func isExpired(
    _ auth: GrokAuth,
    now: Date = Date(),
    buffer: TimeInterval? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    let effectiveBuffer = buffer ?? earlyInvalidation(environment: environment)
    if let expiresAt = auth.expiresAt {
        return now >= expiresAt.addingTimeInterval(-effectiveBuffer)
    }
    let age = now.timeIntervalSince(auth.createTime)
    return age >= (defaultTokenTTLSeconds - effectiveBuffer)
}

/// Hard expiry with zero buffer.
public func isHardExpired(_ auth: GrokAuth, now: Date = Date()) -> Bool {
    isExpired(auth, now: now, buffer: 0)
}

/// Look up auth by scope; skip legacy WebLogin; fall back to legacy scope.
public func lookupAuth(_ map: AuthStore, scope: String) -> GrokAuth? {
    let auth = map[scope] ?? (scope == legacyAuthScope ? nil : map[legacyAuthScope])
    guard let auth else { return nil }
    if auth.authMode == .webLogin {
        return nil
    }
    return auth
}

/// User information from cli-chat-proxy `GET /v1/user` (camelCase wire).
public struct UserInfo: Codable, Sendable, Equatable {
    public var userID: String
    public var email: String?
    public var firstName: String?
    public var lastName: String?
    public var profileImageAssetID: String?
    public var principalType: String?
    public var principalID: String?
    public var teamID: String?
    public var teamName: String?
    public var teamRole: String?
    public var organizationID: String?
    public var organizationName: String?
    public var organizationRole: String?
    public var userBlockedReason: String?
    public var teamBlockedReasons: [String]?
    public var codingDataRetentionOptOut: Bool?
    public var subscriptionTier: String?

    enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case email
        case firstName
        case lastName
        case profileImageAssetID = "profileImageAssetId"
        case principalType
        case principalID = "principalId"
        case teamID = "teamId"
        case teamName
        case teamRole
        case organizationID = "organizationId"
        case organizationName
        case organizationRole
        case userBlockedReason
        case teamBlockedReasons
        case codingDataRetentionOptOut
        case subscriptionTier
    }
}
