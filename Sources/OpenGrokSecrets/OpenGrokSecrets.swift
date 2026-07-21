// OpenGrokSecrets.swift
//
// Secure credential storage contract (W2-S2 bootstrap scaffold). macOS uses
// Keychain, Linux uses Secret Service (or an explicit owner-only documented
// fallback), Windows uses Credential Manager. A plaintext fallback is NEVER
// silent: callers receive `SecretStoreError.unsupported` or an explicit
/// owner-only-fallback marker so secure persistence is never silently weakened.
//
// The owning slice (W2-S2) replaces `BootstrapSecretStore` with the real
// platform-backed store. Reference: xai-grok-secrets.

import Foundation

/// Secret-store errors.
public enum SecretStoreError: Error, Equatable, Sendable {
    case notFound(String)
    case accessDenied(String)
    case unsupported(String)
    /// An explicit, owner-only documented fallback is in use (never silent).
    case ownerOnlyFallbackActive(String)
}

/// A stored credential. The `secret` is held in memory only transiently; stores
/// must redact it in logs/traces.
public struct Credential: Sendable, Equatable {
    public var account: String
    public var secret: String
    public var metadata: [String: String]
    public init(account: String, secret: String, metadata: [String: String] = [:]) {
        self.account = account
        self.secret = secret
        self.metadata = metadata
    }
}

/// The backend a concrete store uses, for diagnostics and audit.
public enum SecretStoreBackend: Sendable, Equatable, Codable {
    case keychain
    case secretService
    case credentialManager
    case ownerOnlyFallback
    case unsupported
}

/// Secure, isolated credential storage. Implementations are actor-isolated and
/// never share state across providers.
public protocol SecretStore: Sendable {
    var backend: SecretStoreBackend { get }
    func read(account: String) async throws -> Credential
    func write(_ credential: Credential) async throws
    func delete(account: String) async throws
}

/// Bootstrap store that reports `unsupported`. The owning slice (W2-S2)
/// provides the Keychain / Secret Service / Credential Manager implementation.
public struct BootstrapSecretStore: SecretStore {
    public init() {}
    public var backend: SecretStoreBackend { .unsupported }
    public func read(account: String) async throws -> Credential {
        throw SecretStoreError.unsupported("BootstrapSecretStore cannot read; W2-S2 provides the platform store.")
    }
    public func write(_ credential: Credential) async throws {
        throw SecretStoreError.unsupported("BootstrapSecretStore cannot write; W2-S2 provides the platform store.")
    }
    public func delete(account: String) async throws {
        throw SecretStoreError.unsupported("BootstrapSecretStore cannot delete; W2-S2 provides the platform store.")
    }
}
