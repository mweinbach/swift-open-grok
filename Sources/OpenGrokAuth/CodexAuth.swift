// CodexAuth.swift
//
// Isolated OpenAI Codex (ChatGPT) OAuth account support.
//
// Intentionally does NOT reuse AuthManager / auth.json. Codex login, refresh,
// logout, and quota failures must never mutate xAI credentials or ACP
// primary-auth state.

import Foundation
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokPaths
import OpenGrokSecrets

public let codexAuthFileName = OpenGrokAuthPaths.codexAuthFileName
public let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
public let codexOriginator = "codex_cli_rs"
public let codexIssuer = "https://auth.openai.com"
public let codexBackendBaseURL = "https://chatgpt.com/backend-api"
public let codexInferenceBaseURL = "https://chatgpt.com/backend-api/codex"
public let codexInferenceBaseURLEnv = "GROK_CODEX_INFERENCE_BASE_URL"
public let codexAuthRequiredErrorKind = "open_grok_codex_auth_required"
public let codexAuthRequiredMessage =
    "Codex authentication required; run `open-grok login --codex` or configure an API key for this model"
public let codexScope =
    "openid profile email offline_access api.connectors.read api.connectors.invoke"

public let chatgptAccountIDHeader = "chatgpt-account-id"
public let openaiFedrampHeader = "x-openai-fedramp"
public let codexAuthAnchorHeader = "x-grok-build-codex-auth-anchor"
public let codexAccountAnchorHeader = "x-grok-build-codex-account-anchor"
public let codexUserAnchorHeader = "x-grok-build-codex-user-anchor"
public let codexWorkspaceAnchorHeader = "x-grok-build-codex-workspace-anchor"

public let codexReservedAuthHeaders: [String] = [
    chatgptAccountIDHeader,
    openaiFedrampHeader,
    codexAuthAnchorHeader,
    codexAccountAnchorHeader,
    codexUserAnchorHeader,
    codexWorkspaceAnchorHeader,
]

private let codexRefreshWindowSecs: TimeInterval = 5 * 60
private let codexUnknownExpiryRefreshDays: TimeInterval = 8 * 24 * 60 * 60

// MARK: - Store models

public struct CodexTokenData: Codable, Sendable, Equatable, CustomStringConvertible {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String?

    public init(
        idToken: String,
        accessToken: String,
        refreshToken: String,
        accountID: String? = nil
    ) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
    }

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }

    public var description: String {
        "CodexTokenData(access: \(tokenSuffix(accessToken)), refresh: \(tokenSuffix(refreshToken)), accountID: \(accountID ?? "nil"))"
    }
}

public struct CodexAuthStore: Codable, Sendable, Equatable {
    public var authMode: String?
    public var openaiAPIKey: String?
    public var tokens: CodexTokenData?
    public var lastRefresh: Date?

    public init(
        authMode: String? = nil,
        openaiAPIKey: String? = nil,
        tokens: CodexTokenData? = nil,
        lastRefresh: Date? = nil
    ) {
        self.authMode = authMode
        self.openaiAPIKey = openaiAPIKey
        self.tokens = tokens
        self.lastRefresh = lastRefresh
    }

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openaiAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

public struct CodexCredentials: Sendable, Equatable, CustomStringConvertible {
    public var accessToken: String
    public var accountID: String?
    public var chatgptUserID: String?
    public var email: String?
    public var planType: String?
    public var isWorkspaceAccount: Bool
    public var accountIsFedramp: Bool

    public init(
        accessToken: String,
        accountID: String? = nil,
        chatgptUserID: String? = nil,
        email: String? = nil,
        planType: String? = nil,
        isWorkspaceAccount: Bool = false,
        accountIsFedramp: Bool = false
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.chatgptUserID = chatgptUserID
        self.email = email
        self.planType = planType
        self.isWorkspaceAccount = isWorkspaceAccount
        self.accountIsFedramp = accountIsFedramp
    }

    public var description: String {
        "CodexCredentials(access: \(tokenSuffix(accessToken)), accountID: \(accountID ?? "nil"), email: \(email ?? "nil"))"
    }

    public var identity: CodexAuthIdentity {
        CodexAuthIdentity(
            accountID: accountID,
            chatgptUserID: chatgptUserID,
            isWorkspaceAccount: isWorkspaceAccount
        )
    }
}

public struct CodexAuthIdentity: Sendable, Equatable {
    public var accountID: String?
    public var chatgptUserID: String?
    public var isWorkspaceAccount: Bool

    public init(accountID: String?, chatgptUserID: String?, isWorkspaceAccount: Bool) {
        self.accountID = accountID
        self.chatgptUserID = chatgptUserID
        self.isWorkspaceAccount = isWorkspaceAccount
    }
}

public struct CodexAccountSummary: Sendable, Equatable {
    public var email: String?
    public var accountID: String?
    public var planType: String?

    public init(email: String? = nil, accountID: String? = nil, planType: String? = nil) {
        self.email = email
        self.accountID = accountID
        self.planType = planType
    }

    public init(from credentials: CodexCredentials) {
        self.email = credentials.email
        self.accountID = credentials.accountID
        self.planType = credentials.planType
    }
}

public struct CodexResolvedBearer: Sendable, Equatable {
    public var bearer: String
    public var extraHeaders: [String: String]

    public init(bearer: String, extraHeaders: [String: String] = [:]) {
        self.bearer = bearer
        self.extraHeaders = extraHeaders
    }
}

// MARK: - Usage / Quota Models

public struct CodexRateLimitWindow: Codable, Sendable, Equatable {
    public var usedPercent: Double
    public var limitWindowSeconds: Int64
    public var resetAfterSeconds: Int64
    public var resetAt: Int64

    public init(usedPercent: Double, limitWindowSeconds: Int64, resetAfterSeconds: Int64, resetAt: Int64) {
        self.usedPercent = usedPercent
        self.limitWindowSeconds = limitWindowSeconds
        self.resetAfterSeconds = resetAfterSeconds
        self.resetAt = resetAt
    }

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

public struct CodexRateLimit: Codable, Sendable, Equatable {
    public var allowed: Bool
    public var limitReached: Bool
    public var primaryWindow: CodexRateLimitWindow?
    public var secondaryWindow: CodexRateLimitWindow?

    public init(
        allowed: Bool = false,
        limitReached: Bool = false,
        primaryWindow: CodexRateLimitWindow? = nil,
        secondaryWindow: CodexRateLimitWindow? = nil
    ) {
        self.allowed = allowed
        self.limitReached = limitReached
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
    }

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

public struct CodexCredits: Codable, Sendable, Equatable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?

    public init(hasCredits: Bool = false, unlimited: Bool = false, balance: String? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits) ?? false
        self.unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        if let str = try? container.decodeIfPresent(String.self, forKey: .balance) {
            self.balance = str
        } else if let num = try? container.decodeIfPresent(Double.self, forKey: .balance) {
            self.balance = String(num)
        } else {
            self.balance = nil
        }
    }
}

public struct CodexAdditionalRateLimit: Codable, Sendable, Equatable {
    public var limitName: String?
    public var meteredFeature: String?
    public var rateLimit: CodexRateLimit?

    public init(limitName: String? = nil, meteredFeature: String? = nil, rateLimit: CodexRateLimit? = nil) {
        self.limitName = limitName
        self.meteredFeature = meteredFeature
        self.rateLimit = rateLimit
    }

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

public struct CodexUsageSnapshot: Codable, Sendable, Equatable {
    public var planType: String?
    public var rateLimit: CodexRateLimit?
    public var credits: CodexCredits?
    public var additionalRateLimits: [CodexAdditionalRateLimit]

    public init(
        planType: String? = nil,
        rateLimit: CodexRateLimit? = nil,
        credits: CodexCredits? = nil,
        additionalRateLimits: [CodexAdditionalRateLimit] = []
    ) {
        self.planType = planType
        self.rateLimit = rateLimit
        self.credits = credits
        self.additionalRateLimits = additionalRateLimits
    }

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case additionalRateLimits = "additional_rate_limits"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
        self.credits = try container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        self.additionalRateLimits = try container.decodeIfPresent(
            [CodexAdditionalRateLimit].self,
            forKey: .additionalRateLimits
        ) ?? []
    }
}

public struct CodexTokenUsageDailyBucket: Codable, Sendable, Equatable {
    public var startDate: String
    public var tokens: Int64

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = tokens
    }

    enum CodingKeys: String, CodingKey {
        case startDate = "start_date"
        case tokens
    }
}

public struct CodexTokenUsageStats: Codable, Sendable, Equatable {
    public var lifetimeTokens: Int64?
    public var peakDailyTokens: Int64?
    public var longestRunningTurnSec: Int64?
    public var currentStreakDays: Int64?
    public var longestStreakDays: Int64?
    public var dailyUsageBuckets: [CodexTokenUsageDailyBucket]?

    public init(
        lifetimeTokens: Int64? = nil,
        peakDailyTokens: Int64? = nil,
        longestRunningTurnSec: Int64? = nil,
        currentStreakDays: Int64? = nil,
        longestStreakDays: Int64? = nil,
        dailyUsageBuckets: [CodexTokenUsageDailyBucket]? = nil
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSec = longestRunningTurnSec
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.dailyUsageBuckets = dailyUsageBuckets
    }

    enum CodingKeys: String, CodingKey {
        case lifetimeTokens = "lifetime_tokens"
        case peakDailyTokens = "peak_daily_tokens"
        case longestRunningTurnSec = "longest_running_turn_sec"
        case currentStreakDays = "current_streak_days"
        case longestStreakDays = "longest_streak_days"
        case dailyUsageBuckets = "daily_usage_buckets"
    }
}

// MARK: - Endpoints

public struct CodexEndpoints: Sendable, Equatable {
    public var issuer: String
    public var backendBaseURL: String
    public var clientID: String

    public init(
        issuer: String = codexIssuer,
        backendBaseURL: String = codexBackendBaseURL,
        clientID: String = codexClientID
    ) {
        self.issuer = issuer
        self.backendBaseURL = backendBaseURL
        self.clientID = clientID
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CodexEndpoints {
        CodexEndpoints(
            issuer: nonEmpty(environment["GROK_CODEX_AUTH_BASE_URL"]) ?? codexIssuer,
            backendBaseURL: nonEmpty(environment["GROK_CODEX_BACKEND_BASE_URL"]) ?? codexBackendBaseURL,
            clientID: nonEmpty(environment["CODEX_APP_SERVER_LOGIN_CLIENT_ID"]) ?? codexClientID
        )
    }
}

public func codexInferenceBaseURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    nonEmpty(environment[codexInferenceBaseURLEnv]) ?? codexInferenceBaseURL
}

public func isTrustedCodexInferenceBaseURL(
    _ baseURL: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    let candidate = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if candidate.isEmpty { return true }
    let trusted = codexInferenceBaseURL(environment: environment)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return candidate == trusted
}

// MARK: - Path / load / save (isolated from auth.json)

public func codexAuthFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
}

/// Acquire advisory lock for codex-auth.json (codex-auth.json.lock).
public func lockCodexAuthFile(at codexAuthPath: URL) throws -> AdvisoryLock {
    try tryLockCodexAuthFile(at: codexAuthPath)
}

/// Load Codex store. Never reads or writes xAI auth.json.
public func loadCodexStore(at path: URL) throws -> CodexAuthStore? {
    try SecureFile.ensureOwnerOnlyPermissions(at: path)
    let data: Data
    do {
        data = try Data(contentsOf: path)
    } catch {
        if !FileManager.default.fileExists(atPath: path.path) { return nil }
        throw AuthError.storage("failed to read codex-auth.json")
    }
    let trimmed = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty { return nil }
    do {
        return try AuthJSON.decoder.decode(CodexAuthStore.self, from: Data(trimmed.utf8))
    } catch {
        throw AuthError.storage("invalid codex-auth.json")
    }
}

public func saveCodexStore(_ store: CodexAuthStore, at path: URL) throws {
    let parent = path.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var data = try AuthJSON.encoder.encode(store)
    if data.last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
    try SecureFile.write(at: path, contents: data)
    clearPermanentCodexRefreshFailure(path: path)
}

public func loadCodexCredentials(at path: URL) throws -> CodexCredentials? {
    guard let store = try loadCodexStore(at: path),
          let tokens = store.tokens,
          !tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return credentialsFromTokens(tokens)
}

public func isCodexLoggedIn(at path: URL) -> Bool {
    (try? loadCodexCredentials(at: path)) != nil
}

public func credentialsFromTokens(_ tokens: CodexTokenData) -> CodexCredentials {
    let claims = decodeJWTPayload(tokens.idToken)
    let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
    let profile = claims?["https://api.openai.com/profile"] as? [String: Any]
    let accountID = tokens.accountID
        ?? (auth?["chatgpt_account_id"] as? String)
    let email = (claims?["email"] as? String)
        ?? (profile?["email"] as? String)
    let planType = auth?["chatgpt_plan_type"] as? String
    let chatgptUserID = (auth?["chatgpt_user_id"] as? String)
        ?? (auth?["user_id"] as? String)
    let isWorkspace = planType.map { plan in
        switch plan.lowercased() {
        case "team", "self_serve_business_usage_based", "business",
             "enterprise_cbp_usage_based", "enterprise", "hc", "education", "edu":
            return true
        default:
            return false
        }
    } ?? false
    let fedramp = auth?["chatgpt_account_is_fedramp"] as? Bool ?? false
    return CodexCredentials(
        accessToken: tokens.accessToken,
        accountID: accountID,
        chatgptUserID: chatgptUserID,
        email: email,
        planType: planType,
        isWorkspaceAccount: isWorkspace,
        accountIsFedramp: fedramp
    )
}

// MARK: - Headers from atomic snapshot

/// Apply Codex bearer + identity headers from one credential snapshot.
/// Reserved headers are replaced atomically so refresh cannot mix identity.
public func applyCodexAuthHeaders(
    from credentials: CodexCredentials,
    to headers: inout [String: String]
) {
    let reservedSet = Set(codexReservedAuthHeaders.map { $0.lowercased() })
    let keysToRemove = headers.keys.filter { key in
        let lower = key.lowercased()
        return lower == "authorization" || reservedSet.contains(lower)
    }
    for key in keysToRemove {
        headers.removeValue(forKey: key)
    }
    headers["Authorization"] = "Bearer \(credentials.accessToken)"
    if let accountID = credentials.accountID {
        headers["ChatGPT-Account-ID"] = accountID
    }
    if credentials.accountIsFedramp {
        headers["X-OpenAI-Fedramp"] = "true"
    }
}

public func resolveCodexBearer(
    credentials: CodexCredentials,
    expectedIdentity: CodexAuthIdentity?
) -> CodexResolvedBearer? {
    if let expectedIdentity, credentials.identity != expectedIdentity {
        return nil
    }
    var extra: [String: String] = [:]
    if let accountID = credentials.accountID {
        extra["ChatGPT-Account-ID"] = accountID
    }
    if credentials.accountIsFedramp {
        extra["X-OpenAI-Fedramp"] = "true"
    }
    return CodexResolvedBearer(bearer: credentials.accessToken, extraHeaders: extra)
}

// MARK: - Token Validation

/// Validate ID token JWT and required token fields before persistence.
public func validateCodexTokens(
    idToken: String,
    accessToken: String,
    refreshToken: String
) throws {
    guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AuthError.protocolError("Codex access token is empty")
    }
    guard !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AuthError.protocolError("Codex refresh token is empty")
    }
    guard !idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          decodeJWTPayload(idToken) != nil
    else {
        throw AuthError.protocolError("invalid or malformed Codex ID token")
    }
}

// MARK: - Login / logout / refresh

/// Persist a successful Codex OAuth token set. Does not touch auth.json.
public func persistCodexTokens(
    at path: URL,
    idToken: String,
    accessToken: String,
    refreshToken: String,
    accountID: String? = nil,
    now: Date = Date()
) throws {
    try validateCodexTokens(
        idToken: idToken,
        accessToken: accessToken,
        refreshToken: refreshToken
    )
    let lock = try lockCodexAuthFile(at: path)
    defer { lock.release() }

    let resolvedAccount = accountID ?? accountIDFromIDToken(idToken)
    let store = CodexAuthStore(
        authMode: "chatgpt",
        openaiAPIKey: nil,
        tokens: CodexTokenData(
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: resolvedAccount
        ),
        lastRefresh: now
    )
    try saveCodexStore(store, at: path)
}

/// Logout Codex only. Best-effort revoke; always removes local file under lock.
@discardableResult
public func logoutCodex(
    at path: URL,
    endpoints: CodexEndpoints = .fromEnvironment(),
    transport: (any HTTPTransport)? = nil
) async throws -> Bool {
    let store = try? loadCodexStore(at: path)
    if let tokens = store?.tokens, let transport {
        let token: String
        let hint: String
        var body: [String: Any]
        if !tokens.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            token = tokens.refreshToken
            hint = "refresh_token"
            body = [
                "token": token,
                "token_type_hint": hint,
                "client_id": endpoints.clientID,
            ]
        } else {
            token = tokens.accessToken
            hint = "access_token"
            body = ["token": token, "token_type_hint": hint]
        }
        if let url = URL(string: "\(endpoints.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/oauth/revoke"),
           let data = try? JSONSerialization.data(withJSONObject: body) {
            let request = HTTPRequest(
                method: .post,
                url: url,
                headers: ["Content-Type": "application/json"],
                body: data,
                timeout: 10,
                idempotency: .idempotent
            )
            _ = try? await transport.send(request)
        }
    }

    let lock = try lockCodexAuthFile(at: path)
    defer { lock.release() }

    do {
        try FileManager.default.removeItem(at: path)
        clearPermanentCodexRefreshFailure(path: path)
        return true
    } catch {
        let nsErr = error as NSError
        let isNotFound = (nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError)
            || (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(ENOENT))
            || !FileManager.default.fileExists(atPath: path.path)
        if isNotFound {
            clearPermanentCodexRefreshFailure(path: path)
            return false
        }
        throw error
    }
}

/// Refresh Codex tokens. Force=false respects freshness window.
public func refreshCodexCredentials(
    at path: URL,
    endpoints: CodexEndpoints = .fromEnvironment(),
    transport: any HTTPTransport,
    force: Bool = false
) async throws -> CodexCredentials? {
    try Task.checkCancellation()
    guard let initial = try loadCodexStore(at: path) else { return nil }
    if !force && accessTokenIsFresh(initial) {
        return try loadCodexCredentials(at: path)
    }

    let lock = try lockCodexAuthFile(at: path)
    defer { lock.release() }

    // Re-read store state after acquiring lock
    guard var store = try loadCodexStore(at: path) else { return nil }
    if !force && accessTokenIsFresh(store) {
        return try loadCodexCredentials(at: path)
    }
    guard var tokens = store.tokens else { return nil }
    if tokens.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw AuthError.protocolError("Codex OAuth refresh token is missing; run `open-grok login --codex`")
    }
    let priorAccount = tokens.accountID ?? accountIDFromIDToken(tokens.idToken)
    let failureKey = codexRefreshFailureKey(path: path, refreshToken: tokens.refreshToken, accountID: priorAccount)
    if let message = cachedPermanentCodexRefreshFailure(failureKey) {
        throw AuthError.protocolError(message)
    }

    try Task.checkCancellation()
    let base = endpoints.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(base)/oauth/token") else {
        throw AuthError.protocolError("invalid Codex issuer")
    }
    let bodyObj: [String: Any] = [
        "client_id": endpoints.clientID,
        "grant_type": "refresh_token",
        "refresh_token": tokens.refreshToken,
    ]
    let body = try JSONSerialization.data(withJSONObject: bodyObj)
    let request = HTTPRequest(
        method: .post,
        url: url,
        headers: ["Content-Type": "application/json"],
        body: body,
        timeout: 30,
        idempotency: .nonIdempotent
    )
    let response = try await transport.send(request)

    // Check cancellation immediately after transport returns
    try Task.checkCancellation()

    if !(200..<300).contains(response.metadata.statusCode) {
        let code = oauthErrorCode(from: response.body)
        let permanent = response.metadata.statusCode == 401
            || ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"]
            .contains(code ?? "")
        let message = "Codex OAuth refresh returned \(response.metadata.statusCode)"
            + (code.map { " (\($0))" } ?? "")
            + (permanent ? ". Run `open-grok login --codex` to reconnect." : "")
        if permanent {
            cachePermanentCodexRefreshFailure(failureKey, message: message)
        }
        throw AuthError.protocolError(message)
    }
    guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
        throw AuthError.protocolError("Codex OAuth refresh response was invalid")
    }
    if let idToken = json["id_token"] as? String {
        guard decodeJWTPayload(idToken) != nil else {
            throw AuthError.protocolError("refreshed Codex ID token was invalid")
        }
        let newAccount = accountIDFromIDToken(idToken)
        if priorAccount != nil, newAccount != nil, priorAccount != newAccount {
            throw AuthError.protocolError("Codex OAuth refresh returned credentials for a different account")
        }
        tokens.idToken = idToken
        tokens.accountID = newAccount ?? priorAccount
    }
    if let access = json["access_token"] as? String {
        tokens.accessToken = access
    }
    if let refresh = json["refresh_token"] as? String {
        tokens.refreshToken = refresh
    }

    try validateCodexTokens(
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken
    )

    store.tokens = tokens
    store.lastRefresh = Date()

    try Task.checkCancellation()
    try saveCodexStore(store, at: path)
    return try loadCodexCredentials(at: path)
}

public func accessTokenIsFresh(_ store: CodexAuthStore, now: Date = Date()) -> Bool {
    guard let tokens = store.tokens else { return false }
    if let exp = parseJWTExpiration(tokens.accessToken) {
        return exp.timeIntervalSince(now) > codexRefreshWindowSecs
    }
    if let last = store.lastRefresh {
        return now.timeIntervalSince(last) < codexUnknownExpiryRefreshDays
    }
    return false
}

public func buildCodexAuthorizeURL(
    endpoints: CodexEndpoints,
    redirectURI: String,
    pkce: PKCE,
    state: String
) -> URL? {
    buildAuthorizeURL(
        authorizationEndpoint: "\(endpoints.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/oauth/authorize",
        clientID: endpoints.clientID,
        redirectURI: redirectURI,
        scopes: codexScope.split(separator: " ").map(String.init),
        pkce: pkce,
        state: state,
        nonce: nil,
        extraQuery: [
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow": "true",
            "originator": codexOriginator,
        ]
    )
}

/// Codex bearer resolver that fails closed on identity drift.
public struct CodexBearerResolver: Sendable {
    public var expectedIdentity: CodexAuthIdentity?
    public var authFile: URL

    public init(expectedIdentity: CodexAuthIdentity? = nil, authFile: URL) {
        self.expectedIdentity = expectedIdentity
        self.authFile = authFile
    }

    public static func fromCredentials(_ credentials: CodexCredentials?, authFile: URL) -> CodexBearerResolver {
        CodexBearerResolver(expectedIdentity: credentials?.identity, authFile: authFile)
    }

    public func currentAuth() -> CodexResolvedBearer? {
        guard let creds = try? loadCodexCredentials(at: authFile) else { return nil }
        return resolveCodexBearer(credentials: creds, expectedIdentity: expectedIdentity)
    }

    public var reservedHeaders: [String] { codexReservedAuthHeaders }
    public var failClosedOnMissing: Bool { true }
}

// MARK: - Permanent refresh failure cache (digest-keyed, no plaintext tokens)

private struct CodexRefreshFailureKey: Hashable {
    var path: String
    var refreshTokenDigest: String
    var accountID: String?
}

private final class CodexFailureCache: @unchecked Sendable {
    static let shared = CodexFailureCache()
    private let lock = NSLock()
    private var map: [CodexRefreshFailureKey: String] = [:]

    func get(_ key: CodexRefreshFailureKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        map = map.filter { $0.key.path != key.path || $0.key == key }
        return map[key]
    }

    func set(_ key: CodexRefreshFailureKey, message: String) {
        lock.lock()
        map = map.filter { $0.key.path != key.path }
        map[key] = message
        lock.unlock()
    }

    func clear(path: URL) {
        let p = path.path
        lock.lock()
        map = map.filter { $0.key.path != p }
        lock.unlock()
    }
}

private func codexRefreshFailureKey(
    path: URL,
    refreshToken: String,
    accountID: String?
) -> CodexRefreshFailureKey {
    let digest = AuthCrypto.sha256(refreshToken)
        .map { String(format: "%02x", $0) }.joined()
    return CodexRefreshFailureKey(
        path: path.path,
        refreshTokenDigest: digest,
        accountID: accountID
    )
}

private func cachedPermanentCodexRefreshFailure(_ key: CodexRefreshFailureKey) -> String? {
    CodexFailureCache.shared.get(key)
}

private func cachePermanentCodexRefreshFailure(_ key: CodexRefreshFailureKey, message: String) {
    CodexFailureCache.shared.set(key, message: message)
}

private func clearPermanentCodexRefreshFailure(path: URL) {
    CodexFailureCache.shared.clear(path: path)
}

func accountIDFromIDToken(_ token: String) -> String? {
    guard let claims = decodeJWTPayload(token),
          let auth = claims["https://api.openai.com/auth"] as? [String: Any],
          let id = auth["chatgpt_account_id"] as? String
    else { return nil }
    return id
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}
