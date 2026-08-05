// ProviderAvailability.swift
//
// Provider-availability filtering and current-model repair, ported from the
// `agent/models/{resolution,cache,endpoint,fetch}.rs` split that replaced the
// flat `cli_models.rs` / `codex_models.rs` / `fireworks_models.rs` /
// `kimi_models.rs` layout between pins 9739c4a2 and 80dff0a9.
//
// Cited against `crates/codegen/xai-grok-shell/src/agent/models/resolution.rs`
// at pin 80dff0a9.

import Foundation
import OpenGrokSamplingTypes

/// Whether a model's provider is usable with the credentials available now.
///
/// `model_available_for_provider_auth`, resolution.rs:228.
///
/// This is strictly stronger than ``ModelInfo/visibleForProviderAuth(hasXaiSession:hasCodexSession:)``:
/// picker visibility answers "does this provider's session unlock the model",
/// while availability additionally requires that an **API-key-only** provider
/// resolve a non-empty credential. Without the second half, a catalog lists
/// models for a provider the user has never configured a key for, and picking
/// one fails at request time instead of at listing time.
///
/// OAuth-backed providers (xAI session, Codex OAuth) are governed by their
/// isolated login state alone and need no key check here.
public func modelAvailableForProviderAuth(
    _ entry: ModelEntry,
    hasXaiSession: Bool,
    hasCodexSession: Bool,
    resolvedAPIKey: (ModelEntry) -> String?
) -> Bool {
    guard entry.info.visibleForProviderAuth(
        hasXaiSession: hasXaiSession,
        hasCodexSession: hasCodexSession
    ) else { return false }

    switch entry.info.provider.profile.sessionAuth {
    case .apiKeyOnly:
        guard let key = resolvedAPIKey(entry) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .xaiSession, .codexOAuth:
        return true
    }
}

/// Default credential resolution for ``modelAvailableForProviderAuth(_:hasXaiSession:hasCodexSession:resolvedAPIKey:)``:
/// the model-owned key, else the first non-blank value among the entry's
/// declared environment variable names.
///
/// The provider-scoped auth.json fallback (`wafer::api_key`,
/// `kimi_code::api_key`, …) lives in `OpenGrokAuth`, which sits *below* this
/// target in the package layering, so callers that have an auth store pass
/// their own closure instead.
public func modelEntryAPIKeyFromEnvironment(
    _ entry: ModelEntry,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    if let key = entry.apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return key
    }
    guard let envKey = entry.envKey else { return nil }
    for name in envKey.names {
        if let v = environment[name], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
    }
    return nil
}

/// Catalog filtered to entries whose provider is actually usable right now.
///
/// `available_models` (resolution.rs:216-223) applies
/// ``modelAvailableForProviderAuth(_:hasXaiSession:hasCodexSession:resolvedAPIKey:)``,
/// not bare picker visibility.
public func availableModelsForProviderAuth(
    catalog: OrderedModelMap,
    hasXaiSession: Bool,
    hasCodexSession: Bool,
    resolvedAPIKey: (ModelEntry) -> String? = { modelEntryAPIKeyFromEnvironment($0) }
) -> OrderedModelMap {
    var out = OrderedModelMap()
    for (key, entry) in catalog.pairs()
    where modelAvailableForProviderAuth(
        entry,
        hasXaiSession: hasXaiSession,
        hasCodexSession: hasCodexSession,
        resolvedAPIKey: resolvedAPIKey
    ) {
        out[key] = entry
    }
    return out
}

/// Catalog key for a persisted session model id, restricted to **selectable**
/// entries.
///
/// `selectable_catalog_key_for_persisted`, resolution.rs:36. The ordering is
/// load-bearing: a selectable exact-key match wins; otherwise the **last**
/// selectable entry whose routing slug matches, so a non-selectable exact-key
/// entry never shadows a selectable slug match; only then the plain
/// catalog-key resolution, still filtered to available entries.
public func selectableCatalogKeyForPersisted(
    models: OrderedModelMap,
    available: OrderedModelMap,
    modelID: String
) -> String? {
    if available[modelID] != nil { return modelID }
    if let match = models.pairs().last(where: { key, entry in
        available[key] != nil && entry.info.model == modelID
    }) {
        return match.0
    }
    guard let key = resolveCatalogKey(models, modelID: modelID),
          available[key] != nil
    else { return nil }
    return key
}

/// What repairing a session's persisted current model did.
public enum CurrentModelRepair: Sendable, Hashable {
    /// The persisted id still resolves to an available entry; `key` is its
    /// catalog key, which may differ from the persisted id when the id was a
    /// routing slug rather than a catalog key.
    case resolved(key: String)
    /// The persisted model is gone or no longer available (provider
    /// deconfigured, `disabled_models` edit, catalog refresh dropping it);
    /// the session is repointed at `key`.
    case repaired(from: String, key: String)
    /// Nothing selectable is available at all — the caller must fall back to
    /// the bundled default rather than persist a dangling id.
    case unavailable(from: String)
}

/// Repair a session's persisted current model against the live catalog.
///
/// A persisted id can go stale between runs: the catalog refreshed and
/// dropped the entry, a `disabled_models` pattern now removes it, or the
/// provider's credential was cleared so the model is no longer available. The
/// session must not keep a dangling id — resolution.rs pairs
/// `selectable_catalog_key_for_persisted` with the default-model fallback for
/// exactly this case.
///
/// `fallbackKey` should be the resolved default model key.
public func repairCurrentModel(
    persistedID: String,
    models: OrderedModelMap,
    available: OrderedModelMap,
    fallbackKey: String?
) -> CurrentModelRepair {
    if let key = selectableCatalogKeyForPersisted(
        models: models, available: available, modelID: persistedID
    ) {
        return .resolved(key: key)
    }
    guard let fallbackKey, available[fallbackKey] != nil else {
        return .unavailable(from: persistedID)
    }
    return .repaired(from: persistedID, key: fallbackKey)
}
