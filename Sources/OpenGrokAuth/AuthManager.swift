// AuthManager.swift
//
// Single source of truth for auth.json + in-memory bearer cache.
// Actor-isolated; cancellation-safe; durable commits only on success.

import Foundation
import OpenGrokFileUtils
import OpenGrokPaths
import OpenGrokSecrets

public enum AuthUnauthorizedRecoveryResult: Sendable, Equatable {
    case recovered(GrokAuth)
    case retryableFailure
    case terminalFailure(RefreshTokenFailedReason)
}

/// Single source of truth for xAI credentials.
public actor AuthManager {
    private var cached: GrokAuth?
    private let path: URL
    public let scope: String
    public let grokComConfig: GrokComConfig
    private var refresher: (any TokenRefresher)?
    private var permanentFailure: (key: String, reason: RefreshTokenFailedReason, recordedAt: Date)?
    private let permanentFailureTTL: TimeInterval = 300
    private let refreshFlight = RefreshSingleFlight()
    private let environment: [String: String]

    /// Lock-protected snapshot published after every mutation for sync readers.
    nonisolated public let snapshotBox = SnapshotBox()

    /// Create manager loading from `grokHome/auth.json` (or overrides).
    public init(
        grokHome: URL,
        config: GrokComConfig = .default(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pathOverride: URL? = nil
    ) {
        self.grokComConfig = config
        self.scope = config.authScope
        self.environment = environment

        if let pathOverride {
            self.path = pathOverride
        } else if let p = environment["OPENGROK_AUTH_PATH"], !p.isEmpty {
            self.path = URL(fileURLWithPath: p)
        } else {
            self.path = grokHome.appendingPathComponent(OpenGrokAuthPaths.authFileName)
        }

        if let inline = environment["OPENGROK_AUTH"],
           let data = inline.data(using: .utf8),
           let auth = try? AuthJSON.decoder.decode(GrokAuth.self, from: data) {
            self.cached = auth
            snapshotBox.write(credentialSnapshot(from: auth))
            return
        }

        let initial = Self.loadInitial(
            path: path,
            scope: scope,
            config: config,
            environment: environment
        )
        self.cached = initial
        snapshotBox.write(credentialSnapshot(from: initial))
    }

    private static func loadInitial(
        path: URL,
        scope: String,
        config: GrokComConfig,
        environment: [String: String]
    ) -> GrokAuth? {
        if !config.apiKeyAuthDisabled(environment: environment),
           let envKey = xaiAPIKeyFromEnvironment(environment) {
            return GrokAuth(key: envKey, authMode: .apiKey, userID: "")
        }
        guard let store = try? readAuthJSON(at: path) else {
            // Missing file is fine.
            return nil
        }
        if let auth = lookupAuth(store, scope: scope) {
            if auth.authMode == .apiKey && config.apiKeyAuthDisabled(environment: environment) {
                return nil
            }
            return auth
        }
        if !config.apiKeyAuthDisabled(environment: environment),
           let api = store[apiKeyScope] {
            return api
        }
        return nil
    }

    // MARK: - Synchronous snapshot

    nonisolated public func syncSnapshot(deploymentKey: String?) -> CredentialSnapshot {
        if let dk = deploymentKey {
            return CredentialSnapshot(token: dk, deploymentID: deploymentIDFromKey(dk))
        }
        return snapshotBox.read()
    }

    private func publishSnapshot() {
        snapshotBox.write(credentialSnapshot(from: cached))
    }

    // MARK: - Reads

    public func current() -> GrokAuth? {
        guard let auth = cached else { return nil }
        if isExpired(auth, environment: environment) { return nil }
        return auth
    }

    public func currentOrExpired() -> GrokAuth? {
        cached
    }

    public func tokenType() -> TokenType {
        TokenType.from(auth: cached)
    }

    public func isLoggedIn() -> Bool {
        currentOrExpired() != nil || hasXAIAPIKeyEnv(environment)
    }

    public var authFilePath: URL { path }

    // MARK: - Mutations

    /// Hot-swap in-memory credential without disk write.
    public func hotSwap(_ auth: GrokAuth) {
        cached = auth
        permanentFailure = nil
        publishSnapshot()
    }

    /// Persist + swap. Cancellation before write leaves prior credentials intact.
    public func update(_ auth: GrokAuth) throws {
        try Task.checkCancellation()
        let lock = try tryLockAuthFile(at: path)
        defer { lock.release() }
        try Task.checkCancellation()
        var store = try readAuthJSONOrEmptyRecoveringCorrupt(at: path)
        store[scope] = auth
        try writeAuthJSON(at: path, store: store)
        cached = auth
        permanentFailure = nil
        publishSnapshot()
    }

    /// Commit API key as the active credential (disk + memory).
    public func loginWithAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuthError.protocolError("empty API key")
        }
        if grokComConfig.apiKeyAuthDisabled(environment: environment) {
            throw AuthError.apiKeyAuthDisabled
        }
        let home = path.deletingLastPathComponent()
        try storeAPIKey(grokHome: home, apiKey: trimmed)
        let auth = GrokAuth(key: trimmed, authMode: .apiKey)
        cached = auth
        permanentFailure = nil
        publishSnapshot()
    }

    /// Commit an OIDC/session credential (disk + memory).
    public func loginWithSession(_ auth: GrokAuth) throws {
        try update(auth)
    }

    /// Clear current scope from disk and memory.
    @discardableResult
    public func clear() throws -> LogoutResult {
        let previous = cached
        let email = previous?.email
        let wasLoggedIn = previous != nil
        if wasLoggedIn {
            let lock = try tryLockAuthFile(at: path)
            defer { lock.release() }
            var store = (try? readAuthJSON(at: path)) ?? [:]
            store.removeValue(forKey: scope)
            if previous?.authMode == .apiKey {
                store.removeValue(forKey: apiKeyScope)
            }
            if store.isEmpty {
                try? FileManager.default.removeItem(at: path)
            } else {
                try writeAuthJSON(at: path, store: store)
            }
        }
        cached = nil
        permanentFailure = nil
        publishSnapshot()
        return LogoutResult(
            wasLoggedIn: wasLoggedIn,
            email: email,
            apiKeyStillSet: hasXAIAPIKeyEnv(environment)
        )
    }

    public func removeScope(_ scopeName: String) throws {
        let lock = try tryLockAuthFile(at: path)
        defer { lock.release() }
        var store = (try? readAuthJSON(at: path)) ?? [:]
        store.removeValue(forKey: scopeName)
        if store.isEmpty {
            try? FileManager.default.removeItem(at: path)
        } else {
            try writeAuthJSON(at: path, store: store)
        }
        if scopeName == scope {
            cached = nil
            permanentFailure = nil
            publishSnapshot()
        }
    }

    public func configureRefresher(_ refresher: (any TokenRefresher)?) {
        self.refresher = refresher
    }

    // MARK: - Auth dispatch

    public func auth() async throws -> GrokAuth {
        try Task.checkCancellation()
        if let cached, let policyError = cachedTokenPolicyError(cached) {
            _ = try? clear()
            throw policyError
        }
        if let auth = cached, !isExpired(auth, environment: environment) {
            return auth
        }
        if let failure = permanentFailureIfActive() {
            if let auth = cached, !isHardExpired(auth) {
                return auth
            }
            if let adopted = tryAdoptDisk() {
                return adopted
            }
            throw AuthError.permanent(failure)
        }

        let type = TokenType.from(auth: cached)
        switch type {
        case .none:
            if let envKey = xaiAPIKeyFromEnvironment(environment),
               !grokComConfig.apiKeyAuthDisabled(environment: environment) {
                let auth = GrokAuth(key: envKey, authMode: .apiKey)
                cached = auth
                publishSnapshot()
                return auth
            }
            throw AuthError.notLoggedIn
        case .apiKey:
            if cached != nil {
                throw AuthError.tokenExpiredNoRefresh
            }
            throw AuthError.notLoggedIn
        case .legacySession:
            if let adopted = tryAdoptDisk() { return adopted }
            throw AuthError.tokenExpiredNoRefresh
        case .oidcSession, .externalBinary:
            return try await refreshChain(reason: .preRequest)
        }
    }

    public func getValidToken() async throws -> String {
        try await auth().key
    }

    /// Preserve whether an unauthorized refresh changed the credential or
    /// reached a terminal refresh-token failure so relay callers can choose
    /// between immediate reconnect, backoff, and cancellation.
    public func recoverUnauthorized() async -> AuthUnauthorizedRecoveryResult {
        let before = cached?.key
        let type = TokenType.from(auth: cached)
        guard type.isRefreshable else { return .retryableFailure }
        do {
            let auth = try await refreshChain(reason: .serverRejected)
            guard auth.key != before else { return .retryableFailure }
            return .recovered(auth)
        } catch let error as AuthError {
            if case .refresh(.permanent(let failure)) = error {
                return .terminalFailure(failure.reason)
            }
            return .retryableFailure
        } catch {
            return .retryableFailure
        }
    }

    /// Compatibility wrapper for HTTP callers that only need a changed-token
    /// boolean.
    public func tryRecoverUnauthorized() async -> Bool {
        if case .recovered = await recoverUnauthorized() {
            return true
        }
        return false
    }

    private func refreshChain(reason: RefreshReason) async throws -> GrokAuth {
        try Task.checkCancellation()
        let ok = await refreshFlight.run {
            await self.performRefresh(reason: reason)
        }
        if ok, let auth = cached {
            if reason == .serverRejected || !isExpired(auth, environment: environment) {
                return auth
            }
        }
        if reason == .preRequest, let auth = cached, !isHardExpired(auth) {
            return auth
        }
        if let failure = permanentFailureIfActive() {
            throw AuthError.permanent(failure)
        }
        throw AuthError.tokenExpiredNoRefresh
    }

    private func performRefresh(reason: RefreshReason) async -> Bool {
        let diskAuth: GrokAuth? = {
            guard let store = try? readAuthJSON(at: path) else { return nil }
            return lookupAuth(store, scope: scope)
        }()

        // Sibling adoption: disk has different valid token.
        if let diskAuth,
           !isExpired(diskAuth, environment: environment),
           diskAuth.key != cached?.key {
            cached = diskAuth
            permanentFailure = nil
            publishSnapshot()
            return true
        }

        let credential = resolveRefreshCredential(
            disk: diskAuth,
            expired: cached,
            current: {
                guard let c = cached, !isExpired(c, environment: environment) else { return nil }
                return c
            }(),
            reason: reason
        )

        guard let refresher else { return false }

        let outcome = await refresher.refresh(reason: reason, current: credential)
        switch outcome {
        case .success(let auth):
            do {
                try update(auth)
                return true
            } catch is CancellationError {
                return false
            } catch {
                cached = auth
                permanentFailure = nil
                publishSnapshot()
                return true
            }
        case .permanentFailure(let failReason, let triedKey):
            permanentFailure = (
                key: triedKey ?? credential?.key ?? "",
                reason: failReason,
                recordedAt: Date()
            )
            return false
        case .transientFailure:
            return false
        }
    }

    private func tryAdoptDisk() -> GrokAuth? {
        guard let store = try? readAuthJSON(at: path),
              let auth = lookupAuth(store, scope: scope),
              !isExpired(auth, environment: environment)
        else { return nil }
        cached = auth
        permanentFailure = nil
        publishSnapshot()
        return auth
    }

    private func permanentFailureIfActive() -> RefreshTokenFailedReason? {
        guard let failure = permanentFailure else { return nil }
        let sameCredential = failure.key == cached?.key
            || failure.key == (cached?.refreshToken ?? "")
        if failure.reason.isSticky {
            if sameCredential { return failure.reason }
            permanentFailure = nil
            return nil
        }
        if Date().timeIntervalSince(failure.recordedAt) > permanentFailureTTL {
            permanentFailure = nil
            return nil
        }
        if !sameCredential {
            permanentFailure = nil
            return nil
        }
        return failure.reason
    }

    private func cachedTokenPolicyError(_ auth: GrokAuth) -> AuthError? {
        if auth.authMode == .apiKey && grokComConfig.apiKeyAuthDisabled(environment: environment) {
            return .apiKeyAuthDisabled
        }
        if let policy = grokComConfig.forceLoginTeamUUID {
            let actual = auth.teamID ?? auth.principalID
            do {
                try enforceLoginPrincipal(policy: policy, actual: actual)
            } catch let err as AuthError {
                return err
            } catch {
                return nil
            }
        }
        return nil
    }
}

/// Lock-protected snapshot published by AuthManager for sync readers.
public final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CredentialSnapshot()

    public init() {}

    public func read() -> CredentialSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func write(_ snapshot: CredentialSnapshot) {
        lock.lock(); value = snapshot; lock.unlock()
    }
}

/// Result of a logout operation.
public struct LogoutResult: Sendable, Equatable {
    public var wasLoggedIn: Bool
    public var email: String?
    public var apiKeyStillSet: Bool

    public init(wasLoggedIn: Bool, email: String?, apiKeyStillSet: Bool) {
        self.wasLoggedIn = wasLoggedIn
        self.email = email
        self.apiKeyStillSet = apiKeyStillSet
    }
}

/// Core logout shared by CLI and ACP.
public func performLogout(manager: AuthManager) async throws -> LogoutResult {
    try await manager.clear()
}
