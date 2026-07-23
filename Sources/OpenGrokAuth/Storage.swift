// Storage.swift
//
// auth.json read/write, scoped API-key helpers, corrupt recovery.
// Uses owner-only SecureFile + AtomicFile and advisory locks.

import Foundation
import OpenGrokFileUtils
import OpenGrokPaths
import OpenGrokSecrets

/// JSON codec for auth.json (RFC3339 dates, fractional-second tolerant).
enum AuthJSON {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(AuthJSON.fractional.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let date = AuthJSON.fractional.date(from: s) ?? AuthJSON.plain.date(from: s) {
                    return date
                }
            }
            if let num = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: num)
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid date")
        }
        return d
    }()
}

/// Read auth.json into a scope map.
public func readAuthJSON(at path: URL) throws -> AuthStore {
    if !FileManager.default.fileExists(atPath: path.path) {
        throw AuthError.storage("auth.json not found at path")
    }
    let data: Data
    do {
        data = try Data(contentsOf: path)
    } catch {
        throw mapIOError(error, path: path)
    }
    try? SecureFile.ensureOwnerOnlyPermissions(at: path)
    let trimmed = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
        return [:]
    }
    do {
        return try AuthJSON.decoder.decode(AuthStore.self, from: Data(trimmed.utf8))
    } catch {
        throw AuthError.storage("invalid auth.json data")
    }
}

/// Read auth.json or empty if missing. InvalidData surfaces as error.
public func readAuthJSONOrEmpty(at path: URL) throws -> AuthStore {
    if !FileManager.default.fileExists(atPath: path.path) {
        return [:]
    }
    return try readAuthJSON(at: path)
}

/// Read for write: missing/empty → empty; corrupt → backup + empty.
public func readAuthJSONOrEmptyRecoveringCorrupt(at path: URL) throws -> AuthStore {
    if !FileManager.default.fileExists(atPath: path.path) {
        return [:]
    }
    do {
        return try readAuthJSON(at: path)
    } catch let err as AuthError {
        if case .storage(let msg) = err, msg.contains("invalid") {
            _ = backupCorruptAuthFile(at: path)
            return [:]
        }
        throw err
    } catch {
        _ = backupCorruptAuthFile(at: path)
        return [:]
    }
}

/// Best-effort rename of corrupt auth.json.
@discardableResult
public func backupCorruptAuthFile(at path: URL) -> URL? {
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    if (try? readAuthJSON(at: path)) != nil { return nil }
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let name = path.lastPathComponent
    let backup = path.deletingLastPathComponent()
        .appendingPathComponent("\(name).corrupt.\(ts)")
    do {
        try FileManager.default.moveItem(at: path, to: backup)
        try? SecureFile.ensureOwnerOnlyPermissions(at: backup)
        return backup
    } catch {
        return nil
    }
}

/// Persist auth store with owner-only atomic write.
public func writeAuthJSON(at path: URL, store: AuthStore) throws {
    let parent = path.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let data = try AuthJSON.encoder.encode(store)
    var payload = data
    if !payload.isEmpty, payload.last != UInt8(ascii: "\n") {
        payload.append(UInt8(ascii: "\n"))
    }
    do {
        try SecureFile.write(at: path, contents: payload)
    } catch {
        // Fallback: AtomicFile owner-only
        try AtomicFile.write(path, data: payload, options: .ownerOnly)
        try? SecureFile.ensureOwnerOnlyPermissions(at: path)
    }
}

/// Acquire non-blocking advisory lock for auth.json.
public func tryLockAuthFile(at authJSONPath: URL) throws -> AdvisoryLock {
    let lockPath = authJSONPath.deletingLastPathComponent()
        .appendingPathComponent(OpenGrokAuthPaths.authLockFileName)
    let parent = lockPath.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return try AdvisoryFileLock.acquire(
        at: lockPath,
        options: AdvisoryLockOptions(nonBlocking: true, create: true, mode: 0o600)
    )
}

/// Acquire blocking advisory lock for codex-auth.json.
public func tryLockCodexAuthFile(at codexAuthPath: URL) throws -> AdvisoryLock {
    let lockPath = codexAuthPath.deletingLastPathComponent()
        .appendingPathComponent(OpenGrokAuthPaths.codexAuthLockFileName)
    let parent = lockPath.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return try AdvisoryFileLock.acquire(
        at: lockPath,
        options: AdvisoryLockOptions(nonBlocking: false, create: true, mode: 0o600)
    )
}


// MARK: - API key scopes

/// Read `xai::api_key` from auth.json.
public func readAPIKey(grokHome: URL) -> String? {
    let path = grokHome.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    guard let store = try? readAuthJSON(at: path) else { return nil }
    return store[apiKeyScope]?.key
}

/// Store plain API key under `xai::api_key`.
public func storeAPIKey(grokHome: URL, apiKey: String) throws {
    try storeScopedAPIKey(grokHome: grokHome, scope: apiKeyScope, apiKey: apiKey)
}

/// Clear `xai::api_key`.
public func clearAPIKey(grokHome: URL) throws {
    try clearScopedAPIKey(grokHome: grokHome, scope: apiKeyScope)
}

/// Provider-scoped key: `"\(provider)::api_key"`.
public func providerAPIKeyScope(_ provider: String) -> String {
    "\(provider)::api_key"
}

public func readProviderAPIKey(grokHome: URL, provider: String) -> String? {
    let path = grokHome.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    guard let store = try? readAuthJSON(at: path),
          let key = store[providerAPIKeyScope(provider)]?.key,
          !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return key
}

public func providerAPIKeyIsConfigured(grokHome: URL, provider: String) -> Bool {
    readProviderAPIKey(grokHome: grokHome, provider: provider) != nil
}

public func storeProviderAPIKey(grokHome: URL, provider: String, apiKey: String) throws {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        try clearProviderAPIKey(grokHome: grokHome, provider: provider)
        return
    }
    try storeScopedAPIKey(grokHome: grokHome, scope: providerAPIKeyScope(provider), apiKey: trimmed)
}

public func clearProviderAPIKey(grokHome: URL, provider: String) throws {
    try clearScopedAPIKey(grokHome: grokHome, scope: providerAPIKeyScope(provider))
}

public func storeScopedAPIKey(grokHome: URL, scope: String, apiKey: String) throws {
    let path = grokHome.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    let lock = try tryLockAuthFile(at: path)
    defer { lock.release() }
    var map = try readAuthJSONOrEmptyRecoveringCorrupt(at: path)
    map[scope] = GrokAuth(key: apiKey, authMode: .apiKey)
    try writeAuthJSON(at: path, store: map)
}

public func clearScopedAPIKey(grokHome: URL, scope: String) throws {
    let path = grokHome.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    let lock = try tryLockAuthFile(at: path)
    defer { lock.release() }
    var map: AuthStore
    do {
        map = try readAuthJSON(at: path)
    } catch {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
            return
        }
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return }
        // Missing file from our mapIOError
        if case AuthError.storage(let m) = error as? AuthError, m.contains("not found") {
            return
        }
        throw error
    }
    map.removeValue(forKey: scope)
    if map.isEmpty {
        try? FileManager.default.removeItem(at: path)
    } else {
        try writeAuthJSON(at: path, store: map)
    }
}

/// Read token by scope (throws AuthError.notLoggedIn style storage errors).
public func readTokenByScope(grokHome: URL, scope: String) throws -> String {
    let path = grokHome.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    let store: AuthStore
    do {
        store = try readAuthJSON(at: path)
    } catch {
        throw AuthError.notLoggedIn
    }
    guard let auth = lookupAuth(store, scope: scope) else {
        throw AuthError.notLoggedIn
    }
    return auth.key
}

private func mapIOError(_ error: Error, path: URL) -> Error {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
        return AuthError.storage("auth.json not found at path")
    }
    if (error as? CocoaError)?.code == .fileReadNoSuchFile {
        return AuthError.storage("auth.json not found at path")
    }
    if !FileManager.default.fileExists(atPath: path.path) {
        return AuthError.storage("auth.json not found at path")
    }
    return AuthError.storage("failed to read auth.json")
}

// MARK: - Env key resolution

/// Resolve XAI API key from environment (precedence: XAI_API_KEY, GROK_CODE_XAI_API_KEY).
public func xaiAPIKeyFromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    for key in ["XAI_API_KEY", "GROK_CODE_XAI_API_KEY"] {
        if let v = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return v
        }
    }
    return nil
}

public func hasXAIAPIKeyEnv(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    xaiAPIKeyFromEnvironment(environment) != nil
}

/// Deployment key from GROK_DEPLOYMENT_KEY.
public func deploymentKeyFromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    guard let raw = environment["GROK_DEPLOYMENT_KEY"] else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
