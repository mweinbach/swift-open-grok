// ProviderScopes.swift
//
// Per-provider scoped credential keys in auth.json.
//
// Port of the scope constants and accessors in
// `crates/codegen/xai-grok-shell/src/auth/storage.rs` at pin 80dff0a9
// (`KIMI_CODE_API_KEY_SCOPE` / `PERPLEXITY_API_KEY_SCOPE` /
// `WAFER_API_KEY_SCOPE`, storage.rs:441-443, and `kimi_api_key_scope`,
// storage.rs:445-452). Each provider owns an isolated scope so one
// provider's credential can never satisfy another's authentication, and
// clearing one scope preserves every sibling login.

import Foundation

/// `kimi_code::api_key` — Kimi's Code endpoint, isolated from Platform.
/// storage.rs:441.
public let kimiCodeAPIKeyScope = "kimi_code::api_key"

/// `perplexity::api_key` — Perplexity Search. storage.rs:442.
public let perplexityAPIKeyScope = "perplexity::api_key"

/// `wafer::api_key` — Wafer AI. storage.rs:443 (new at pin 80dff0a9).
public let waferAPIKeyScope = "wafer::api_key"

/// Which Kimi API endpoint a credential belongs to.
///
/// Port of `KimiApiEndpoint` (`crates/codegen/xai-grok-shell/src/kimi_models.rs:30`).
public enum KimiAPIEndpoint: String, Sendable, Hashable, CaseIterable {
    case platform
    case code

    /// `KimiApiEndpoint::as_canonical` (kimi_models.rs:37).
    public var canonical: String { rawValue }

    /// `KimiApiEndpoint::from_canonical` (kimi_models.rs:44) — trims, exact match.
    public static func fromCanonical(_ value: String) -> KimiAPIEndpoint? {
        KimiAPIEndpoint(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Scope key for a Kimi credential.
///
/// `Platform` deliberately reuses the historical provider scope
/// (`kimi::api_key`) so existing Kimi users migrate without re-login;
/// `Code` gets its own scope. `kimi_api_key_scope`, storage.rs:445.
public func kimiAPIKeyScope(_ endpoint: KimiAPIEndpoint) -> String {
    switch endpoint {
    case .platform: return providerAPIKeyScope("kimi")
    case .code: return kimiCodeAPIKeyScope
    }
}

// MARK: - Scope-generic accessors

/// Read a non-empty key from `scope`, or nil.
///
/// Mirrors the `.filter(|key| !key.trim().is_empty())` guard every scoped
/// reader in storage.rs applies (e.g. `read_wafer_api_key`, storage.rs:634).
public func readScopedAPIKey(grokHome: URL, scope: String) -> String? {
    let path = grokHome.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    guard let store = try? readAuthJSON(at: path),
          let key = store[scope]?.key,
          !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return key
}

/// Whether a non-empty credential exists at `scope`.
public func scopedAPIKeyIsConfigured(grokHome: URL, scope: String) -> Bool {
    readScopedAPIKey(grokHome: grokHome, scope: scope) != nil
}

/// Store `apiKey` at `scope`; an all-whitespace key clears the scope instead.
///
/// The trim-clears-instead-of-storing rule is the shared shape of every
/// `store_*_api_key` in storage.rs (e.g. storage.rs:653-659).
public func storeScopedAPIKeyTrimming(grokHome: URL, scope: String, apiKey: String) throws {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        try clearScopedAPIKey(grokHome: grokHome, scope: scope)
        return
    }
    try storeScopedAPIKey(grokHome: grokHome, scope: scope, apiKey: trimmed)
}

// MARK: - Kimi

public func readKimiAPIKey(grokHome: URL, endpoint: KimiAPIEndpoint) -> String? {
    readScopedAPIKey(grokHome: grokHome, scope: kimiAPIKeyScope(endpoint))
}

public func kimiAPIKeyIsConfigured(grokHome: URL, endpoint: KimiAPIEndpoint) -> Bool {
    readKimiAPIKey(grokHome: grokHome, endpoint: endpoint) != nil
}

public func storeKimiAPIKey(grokHome: URL, endpoint: KimiAPIEndpoint, apiKey: String) throws {
    try storeScopedAPIKeyTrimming(grokHome: grokHome, scope: kimiAPIKeyScope(endpoint), apiKey: apiKey)
}

public func clearKimiAPIKey(grokHome: URL, endpoint: KimiAPIEndpoint) throws {
    try clearScopedAPIKey(grokHome: grokHome, scope: kimiAPIKeyScope(endpoint))
}

// MARK: - Perplexity

public func readPerplexityAPIKey(grokHome: URL) -> String? {
    readScopedAPIKey(grokHome: grokHome, scope: perplexityAPIKeyScope)
}

public func perplexityAPIKeyIsConfigured(grokHome: URL) -> Bool {
    readPerplexityAPIKey(grokHome: grokHome) != nil
}

public func storePerplexityAPIKey(grokHome: URL, apiKey: String) throws {
    try storeScopedAPIKeyTrimming(grokHome: grokHome, scope: perplexityAPIKeyScope, apiKey: apiKey)
}

public func clearPerplexityAPIKey(grokHome: URL) throws {
    try clearScopedAPIKey(grokHome: grokHome, scope: perplexityAPIKeyScope)
}

// MARK: - Wafer AI

public func readWaferAPIKey(grokHome: URL) -> String? {
    readScopedAPIKey(grokHome: grokHome, scope: waferAPIKeyScope)
}

public func waferAPIKeyIsConfigured(grokHome: URL) -> Bool {
    readWaferAPIKey(grokHome: grokHome) != nil
}

public func storeWaferAPIKey(grokHome: URL, apiKey: String) throws {
    try storeScopedAPIKeyTrimming(grokHome: grokHome, scope: waferAPIKeyScope, apiKey: apiKey)
}

public func clearWaferAPIKey(grokHome: URL) throws {
    try clearScopedAPIKey(grokHome: grokHome, scope: waferAPIKeyScope)
}
