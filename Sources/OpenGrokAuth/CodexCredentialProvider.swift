// CodexCredentialProvider.swift
//
// Codex OAuth adapters for the `AuthCredentialProvider` DI seam.
//
// The provider reads the isolated `codex-auth.json` store on every access so a
// concurrent `open-grok logout --codex` is observed immediately, and it fails
// closed: when the store is missing, unreadable, or carries a different
// account identity than the one this session pinned, no bearer is produced and
// every reserved Codex header is stripped from the outbound request.
//
// Invariants:
//   * Never reads or writes xAI `auth.json`.
//   * A refresh that returns a different account is rejected, not adopted.
//   * No stale-token fallback: a failed refresh surfaces as an error.

import Foundation
import OpenGrokHTTP

/// Injectable Codex token-refresh seam.
///
/// `refresh(authFile, force)` mirrors `refreshCodexCredentials(at:force:)`:
/// `force == false` honours the freshness window and may return the stored
/// credentials untouched. Returns `nil` when the store holds no tokens.
public struct CodexTokenRefreshService: Sendable {
    public var refresh: @Sendable (_ authFile: URL, _ force: Bool) async throws -> CodexCredentials?

    public init(
        refresh: @escaping @Sendable (_ authFile: URL, _ force: Bool) async throws -> CodexCredentials?
    ) {
        self.refresh = refresh
    }

    /// Live service that performs the OAuth refresh over `transport`.
    public static func live(
        endpoints: CodexEndpoints = .fromEnvironment(),
        transport: any HTTPTransport
    ) -> CodexTokenRefreshService {
        CodexTokenRefreshService { authFile, force in
            try await refreshCodexCredentials(
                at: authFile,
                endpoints: endpoints,
                transport: transport,
                force: force
            )
        }
    }

    /// Store-only service that never performs network I/O. Intended for tests
    /// and for read-only status paths; it cannot renew an expired token.
    public static let storeOnly = CodexTokenRefreshService { authFile, _ in
        try loadCodexCredentials(at: authFile)
    }
}

/// `AuthCredentialProvider` backed by the isolated Codex OAuth store.
public final class CodexAuthCredentialProvider: AuthCredentialProvider, @unchecked Sendable {
    private let file: URL
    private let refreshService: CodexTokenRefreshService
    private let lock = NSLock()
    private var pinnedIdentity: CodexAuthIdentity?

    public init(
        authFile: URL,
        expectedIdentity: CodexAuthIdentity? = nil,
        refreshService: CodexTokenRefreshService = .storeOnly
    ) {
        self.file = authFile
        self.pinnedIdentity = expectedIdentity
        self.refreshService = refreshService
    }

    /// The isolated store this provider reads. Never `auth.json`.
    public var authFile: URL { file }

    /// The account identity this session is pinned to, if one was observed.
    public var expectedIdentity: CodexAuthIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return pinnedIdentity
    }

    // MARK: - HttpAuth / AuthCredentialProvider

    public func apply(to headers: inout [String: String], baseURL: String) {
        _ = baseURL
        guard let credentials = currentCredentials() else {
            stripReservedHeaders(&headers)
            return
        }
        applyCodexAuthHeaders(from: credentials, to: &headers)
    }

    public func snapshot() -> CredentialSnapshot {
        guard let credentials = currentCredentials() else {
            return CredentialSnapshot()
        }
        return CredentialSnapshot(
            token: credentials.accessToken,
            userID: credentials.chatgptUserID ?? credentials.accountID,
            organizationID: credentials.accountID
        )
    }

    public func refreshAfterUnauthorized() async -> Bool {
        let previous = (try? loadCodexCredentials(at: file))?.accessToken
        guard let refreshed = try? await refreshService.refresh(file, true) else {
            return false
        }
        guard acceptIdentity(refreshed.identity) else { return false }
        return refreshed.accessToken != previous
    }

    public func needsTokenAuthHeader() -> Bool { false }

    public func hasUsableCredential() -> Bool { currentCredentials() != nil }

    // MARK: - Proactive refresh

    /// Credentials guaranteed to be within the freshness window, renewing them
    /// when required. Throws rather than returning a stale token.
    @discardableResult
    public func ensureFreshCredentials() async throws -> CodexCredentials {
        guard let store = try loadCodexStore(at: file), store.tokens != nil else {
            throw AuthError.protocolError(codexAuthRequiredMessage)
        }
        guard let credentials = try await refreshService.refresh(file, false) else {
            throw AuthError.protocolError(codexAuthRequiredMessage)
        }
        guard acceptIdentity(credentials.identity) else {
            throw AuthError.protocolError(
                "Codex credentials changed account mid-session; run `open-grok login --codex`"
            )
        }
        return credentials
    }

    /// Bearer + identity headers for one atomic credential read, or `nil` when
    /// the store is empty or has drifted to another account.
    public func resolvedBearer() -> CodexResolvedBearer? {
        guard let credentials = currentCredentials() else { return nil }
        return resolveCodexBearer(credentials: credentials, expectedIdentity: expectedIdentity)
    }

    // MARK: - Internals

    private func currentCredentials() -> CodexCredentials? {
        guard let credentials = try? loadCodexCredentials(at: file) else { return nil }
        guard let expected = expectedIdentity else { return credentials }
        return credentials.identity == expected ? credentials : nil
    }

    /// Pin the identity on first observation; reject any later drift.
    private func acceptIdentity(_ identity: CodexAuthIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pinned = pinnedIdentity else {
            pinnedIdentity = identity
            return true
        }
        return pinned == identity
    }

    private func stripReservedHeaders(_ headers: inout [String: String]) {
        let reserved = Set(codexReservedAuthHeaders.map { $0.lowercased() })
        let doomed = headers.keys.filter { key in
            let lower = key.lowercased()
            return lower == "authorization" || reserved.contains(lower)
        }
        for key in doomed {
            headers.removeValue(forKey: key)
        }
    }
}

extension CodexAuthCredentialProvider: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "CodexAuthCredentialProvider(hasCredential: \(hasUsableCredential()))"
    }

    public var debugDescription: String { description }
}
