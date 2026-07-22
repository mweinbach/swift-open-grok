// KeychainStore.swift
//
// macOS Keychain-backed SecretStore. Credential values never appear in
// error descriptions or CustomStringConvertible output.
//
// Write is non-destructive: SecItemUpdate first, SecItemAdd only when absent.
// Metadata is preserved in a versioned encoded payload.

import Foundation

#if canImport(Security)
import Security
#endif

/// Keychain service namespace for Open Grok credentials.
public enum OpenGrokKeychain {
    /// Bundle-style service name. Isolated from other apps.
    public static let defaultService = "ai.xai.open-grok.secrets"
}

/// Versioned Keychain value envelope (secret + metadata).
private struct KeychainEnvelope: Codable, Sendable {
    var v: Int
    var secret: String
    var metadata: [String: String]

    init(secret: String, metadata: [String: String]) {
        self.v = 1
        self.secret = secret
        self.metadata = metadata
    }
}

#if os(macOS)
/// macOS Keychain credential store.
public actor KeychainSecretStore: SecretStore {
    public nonisolated let backend: SecretStoreBackend = .keychain
    private let service: String

    public init(service: String = OpenGrokKeychain.defaultService) {
        self.service = service
    }

    public func read(account: String) async throws -> Credential {
        try Task.checkCancellation()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw SecretStoreError.notFound(account)
        }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            throw SecretStoreError.accessDenied(account)
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecretStoreError.accessDenied("keychain read status \(status)")
        }
        return try decodeCredential(account: account, data: data)
    }

    public func write(_ credential: Credential) async throws {
        try Task.checkCancellation()
        let data = try encodeCredential(credential)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.account,
        ]

        // Non-destructive: update first so a failed add cannot drop the prior secret.
        let update: [String: Any] = [kSecValueData as String: data]
        let uStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if uStatus == errSecSuccess {
            return
        }
        if uStatus != errSecItemNotFound {
            throw SecretStoreError.accessDenied("keychain update status \(uStatus)")
        }

        // Absent — add.
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let aStatus = SecItemAdd(add as CFDictionary, nil)
        if aStatus == errSecDuplicateItem {
            // Race with another writer: retry update.
            let retry = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard retry == errSecSuccess else {
                throw SecretStoreError.accessDenied("keychain update status \(retry)")
            }
            return
        }
        guard aStatus == errSecSuccess else {
            throw SecretStoreError.accessDenied("keychain add status \(aStatus)")
        }
    }

    public func delete(account: String) async throws {
        try Task.checkCancellation()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw SecretStoreError.notFound(account)
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.accessDenied("keychain delete status \(status)")
        }
    }

    /// List account names (never secrets) for this service.
    public func listAccounts() async throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let rows = item as? [[String: Any]] else {
            throw SecretStoreError.accessDenied("keychain list status \(status)")
        }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - Envelope encode/decode

    private func encodeCredential(_ credential: Credential) throws -> Data {
        let env = KeychainEnvelope(secret: credential.secret, metadata: credential.metadata)
        do {
            return try JSONEncoder().encode(env)
        } catch {
            throw SecretStoreError.accessDenied("encode failed")
        }
    }

    private func decodeCredential(account: String, data: Data) throws -> Credential {
        // Prefer versioned envelope; fall back to raw UTF-8 secret for older items.
        if let env = try? JSONDecoder().decode(KeychainEnvelope.self, from: data),
           env.v >= 1,
           !env.secret.isEmpty || data.count > 0 {
            return Credential(account: account, secret: env.secret, metadata: env.metadata)
        }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.accessDenied("keychain value not utf-8")
        }
        // If it looks like our JSON but failed decode, refuse rather than leak JSON as secret.
        if data.first == UInt8(ascii: "{") {
            throw SecretStoreError.accessDenied("corrupt keychain envelope")
        }
        return Credential(account: account, secret: secret, metadata: [:])
    }
}
#endif
