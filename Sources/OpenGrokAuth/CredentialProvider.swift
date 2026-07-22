// CredentialProvider.swift
//
// AuthCredentialProvider DI seam + Static / Manager-backed providers.

import Foundation
import OpenGrokSecrets

/// Source of truth for outbound auth on data-collector / HTTP requests.
public protocol AuthCredentialProvider: HttpAuth, Sendable {
    /// Current credential snapshot. `token` must match the wire bearer.
    func snapshot() -> CredentialSnapshot

    /// Attempt to obtain a fresh token after 401. Returns true if a different
    /// token was obtained (caller should retry once).
    func refreshAfterUnauthorized() async -> Bool

    /// Whether `X-XAI-Token-Auth` should be sent (false for deployment keys).
    func needsTokenAuthHeader() -> Bool

    /// Whether a real outbound attempt is warranted.
    func hasUsableCredential() -> Bool
}

extension AuthCredentialProvider {
    public func needsTokenAuthHeader() -> Bool { true }
    public func hasUsableCredential() -> Bool { true }
}

/// Static credential provider. Refresh always returns false.
public final class StaticAuthCredentialProvider: AuthCredentialProvider, @unchecked Sendable {
    private let inner: any HttpAuth
    private let bearer: String?
    private let snapshotValue: CredentialSnapshot
    private let tokenAuth: Bool

    public init(
        inner: any HttpAuth,
        bearer: String?,
        snapshot: CredentialSnapshot? = nil,
        needsTokenAuthHeader: Bool = true
    ) {
        self.inner = inner
        self.bearer = bearer
        self.snapshotValue = snapshot ?? CredentialSnapshot(token: bearer)
        self.tokenAuth = needsTokenAuthHeader
    }

    /// Convenience for a plain bearer (user token + X-XAI-Token-Auth).
    public convenience init(bearer: String?) {
        let creds = GrokAuthCredentials(userToken: bearer)
        self.init(
            inner: creds,
            bearer: bearer,
            snapshot: CredentialSnapshot(token: bearer),
            needsTokenAuthHeader: true
        )
    }

    /// Deployment-key static provider (bare Bearer, no token-auth header).
    public static func deploymentKey(_ key: String) -> StaticAuthCredentialProvider {
        let creds = GrokAuthCredentials(deploymentKey: key)
        return StaticAuthCredentialProvider(
            inner: creds,
            bearer: key,
            snapshot: CredentialSnapshot(
                token: key,
                deploymentID: deploymentIDFromKey(key)
            ),
            needsTokenAuthHeader: false
        )
    }

    public func apply(to headers: inout [String: String], baseURL: String) {
        inner.apply(to: &headers, baseURL: baseURL)
    }

    public func snapshot() -> CredentialSnapshot { snapshotValue }

    public func refreshAfterUnauthorized() async -> Bool { false }

    public func needsTokenAuthHeader() -> Bool { tokenAuth }

    public func hasUsableCredential() -> Bool { bearer != nil }
}

extension StaticAuthCredentialProvider: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "StaticAuthCredentialProvider(hasBearer: \(bearer != nil))"
    }
    public var debugDescription: String { description }
}

/// Live provider wrapping `AuthManager` + optional deployment key.
///
/// Deployment key outranks OIDC in snapshot and apply; 401 refresh is a no-op
/// for deployment keys.
public final class LiveAuthCredentialProvider: AuthCredentialProvider, @unchecked Sendable {
    private let manager: AuthManager
    private let lock = NSLock()
    private var _deploymentKey: String?
    private var _alphaTestKey: String?

    public init(
        manager: AuthManager,
        deploymentKey: String? = nil,
        alphaTestKey: String? = nil
    ) {
        self.manager = manager
        self._deploymentKey = deploymentKey
        self._alphaTestKey = alphaTestKey
    }

    public var deploymentKey: String? {
        get { lock.lock(); defer { lock.unlock() }; return _deploymentKey }
        set { lock.lock(); _deploymentKey = newValue; lock.unlock() }
    }

    public func apply(to headers: inout [String: String], baseURL: String) {
        let snap = snapshot()
        var creds = GrokAuthCredentials()
        if snap.deploymentID != nil, let token = snap.token {
            creds.deploymentKey = token
        } else {
            creds.userToken = snap.token
        }
        creds.apply(to: &headers, baseURL: baseURL)
    }

    public func snapshot() -> CredentialSnapshot {
        manager.syncSnapshot(deploymentKey: deploymentKey)
    }

    public func refreshAfterUnauthorized() async -> Bool {
        if deploymentKey != nil { return false }
        return await manager.tryRecoverUnauthorized()
    }

    public func needsTokenAuthHeader() -> Bool {
        deploymentKey == nil
    }

    public func hasUsableCredential() -> Bool {
        snapshot().token != nil
    }
}

/// Build CredentialSnapshot from a GrokAuth (+ optional deployment override).
public func credentialSnapshot(
    from auth: GrokAuth?,
    deploymentKey: String? = nil
) -> CredentialSnapshot {
    if let dk = deploymentKey {
        return CredentialSnapshot(
            token: dk,
            deploymentID: deploymentIDFromKey(dk)
        )
    }
    guard let auth else {
        return CredentialSnapshot()
    }
    let apiKeyID: String? = auth.authMode == .apiKey
        ? deploymentIDFromKey(auth.key)
        : nil
    return CredentialSnapshot(
        token: auth.key,
        userID: auth.userID.isEmpty ? nil : auth.userID,
        teamID: auth.teamID,
        deploymentID: nil,
        apiKeyID: apiKeyID,
        organizationID: auth.organizationID
    )
}
