// PlatformStore.swift
//
// Platform factory for SecretStore backends. Plaintext / owner-only
// fallback is never silent: the returned store's `backend` is explicit,
// and `makeDefault` can throw `ownerOnlyFallbackActive` when the caller
// opts into fail-closed discovery.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Options for constructing the platform secret store.
public struct SecretStoreOptions: Sendable, Equatable {
    /// Keychain / credential service name.
    public var service: String
    /// When true and only the owner-only file backend is available, throw
    /// `ownerOnlyFallbackActive` so callers must acknowledge the downgrade.
    public var failClosedOnFallback: Bool
    /// Directory for owner-only file fallback (typically under OPENGROK_HOME).
    public var ownerOnlyRoot: URL?

    public init(
        service: String = OpenGrokKeychain.defaultService,
        failClosedOnFallback: Bool = false,
        ownerOnlyRoot: URL? = nil
    ) {
        self.service = service
        self.failClosedOnFallback = failClosedOnFallback
        self.ownerOnlyRoot = ownerOnlyRoot
    }
}

/// Construct the best available platform secret store.
public enum PlatformSecretStore: Sendable {
    /// Preferred backend for the current OS.
    public static var preferredBackend: SecretStoreBackend {
        #if os(macOS)
        return .keychain
        #elseif os(Windows)
        return .unsupported
        #elseif os(Linux)
        return .unsupported
        #else
        return .unsupported
        #endif
    }

    /// Create the platform store.
    ///
    /// - macOS: Keychain
    /// - Linux: unsupported by default; an explicit `ownerOnlyRoot` selects
    ///   the documented owner-only file fallback until a Secret Service
    ///   adapter is linked.
    /// - Windows: unsupported until Credential Manager or an equivalent
    ///   owner-only adapter is linked.
    public static func makeDefault(options: SecretStoreOptions = SecretStoreOptions()) async throws -> any SecretStore {
        #if os(macOS)
        return KeychainSecretStore(service: options.service)
        #elseif os(Linux)
        // Secret Service (libsecret) is not linked by default in SwiftPM.
        // Documented owner-only fallback under OPENGROK_HOME.
        guard let root = options.ownerOnlyRoot else {
            throw SecretStoreError.unsupported(
                "Linux Secret Service not linked; provide ownerOnlyRoot for explicit owner-only fallback"
            )
        }
        if options.failClosedOnFallback {
            throw SecretStoreError.ownerOnlyFallbackActive(
                "Linux using owner-only file store at \(root.path); Secret Service adapter not linked"
            )
        }
        return try OwnerOnlyFileSecretStore(rootDirectory: root)
        #elseif os(Windows)
        // Credential Manager (CredWrite/CredRead) and owner-only DACL are
        // not yet wired. Fail closed rather than report success without
        // a real secure backend.
        _ = options
        throw SecretStoreError.unsupported(
            "Windows Credential Manager adapter not yet wired; refuse silent plaintext fallback"
        )
        #else
        throw SecretStoreError.unsupported("no secret store backend for this platform")
        #endif
    }

    /// Always construct the owner-only file store (tests / explicit fallback).
    /// Throws on Windows where DACL enforcement is unavailable.
    public static func makeOwnerOnly(root: URL) throws -> OwnerOnlyFileSecretStore {
        try OwnerOnlyFileSecretStore(rootDirectory: root)
    }
}
