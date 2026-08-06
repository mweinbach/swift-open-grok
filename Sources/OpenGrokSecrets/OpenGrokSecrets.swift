// OpenGrokSecrets.swift
//
// Open Grok — secure credential storage + secret redaction.
//
// Reference crates:
//   * `xai-grok-secrets` — outbound log/telemetry redaction
//   * Platform stores — Keychain on macOS, explicit owner-only fallback on
//     Linux, and typed unsupported results where native adapters are absent
//
// Invariants:
//   * Plaintext fallback is NEVER silent (`backend` + optional throw).
//   * Credential secrets never appear in `description` / errors / logs.
//   * Concurrent access is actor-isolated.

import Foundation

/// Secret-store errors. Messages must never include secret material.
public enum SecretStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case accessDenied(String)
    case unsupported(String)
    /// An explicit, owner-only documented fallback is in use (never silent).
    case ownerOnlyFallbackActive(String)

    public var description: String {
        switch self {
        case .notFound(let account):
            return "secret not found for account '\(account)'"
        case .accessDenied(let detail):
            return "secret access denied: \(detail)"
        case .unsupported(let detail):
            return "secret store unsupported: \(detail)"
        case .ownerOnlyFallbackActive(let detail):
            return "owner-only secret fallback active: \(detail)"
        }
    }
}

/// A stored credential. The `secret` is held in memory only transiently;
/// `description` and `debugDescription` always redact it.
public struct Credential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var account: String
    public var secret: String
    public var metadata: [String: String]

    public init(account: String, secret: String, metadata: [String: String] = [:]) {
        self.account = account
        self.secret = secret
        self.metadata = metadata
    }

    public var description: String {
        "Credential(account: \(account), secret: \(SecretRedaction.secret), metadataKeys: \(metadata.keys.sorted()))"
    }

    public var debugDescription: String { description }
}

/// The backend a concrete store uses, for diagnostics and audit.
public enum SecretStoreBackend: String, Sendable, Equatable, Codable {
    case keychain
    /// Reserved until a native Secret Service adapter is linked.
    case secretService
    /// Reserved until a native Credential Manager adapter is linked.
    case credentialManager
    case ownerOnlyFallback
    case unsupported
}

/// Secure, isolated credential storage. Implementations are actor-isolated
/// and never share state across providers.
public protocol SecretStore: Sendable {
    /// Backend identity; must be synchronously readable (no secret I/O).
    nonisolated var backend: SecretStoreBackend { get }
    func read(account: String) async throws -> Credential
    func write(_ credential: Credential) async throws
    func delete(account: String) async throws
}

/// Bootstrap / explicit unsupported store — never silent plaintext.
public struct UnsupportedSecretStore: SecretStore {
    public init() {}
    public nonisolated var backend: SecretStoreBackend { .unsupported }
    public func read(account: String) async throws -> Credential {
        throw SecretStoreError.unsupported(
            "UnsupportedSecretStore cannot read account '\(account)'"
        )
    }
    public func write(_ credential: Credential) async throws {
        throw SecretStoreError.unsupported(
            "UnsupportedSecretStore cannot write account '\(credential.account)'"
        )
    }
    public func delete(account: String) async throws {
        throw SecretStoreError.unsupported(
            "UnsupportedSecretStore cannot delete account '\(account)'"
        )
    }
}

/// Back-compat alias for the W0-S1 bootstrap name.
public typealias BootstrapSecretStore = UnsupportedSecretStore
