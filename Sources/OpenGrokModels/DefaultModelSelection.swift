// DefaultModelSelection.swift
//
// Deterministic default-model precedence:
//   CLI (`-m`) > ENV (`GROK_DEFAULT_MODEL`) > config `models.default`
//   > remote settings `default_model` > bundled default / first selectable
//
// Provider identity is never rewritten by slug matching alone.

import Foundation
import OpenGrokConfigTypes
import OpenGrokSamplingTypes

public let GROK_DEFAULT_MODEL_ENV = "GROK_DEFAULT_MODEL"

/// Result of resolving the startup default model.
public struct ResolvedDefaultModel: Sendable, Equatable {
    public var catalogKey: String
    public var entry: ModelEntry
    public var source: ConfigSource

    public init(catalogKey: String, entry: ModelEntry, source: ConfigSource) {
        self.catalogKey = catalogKey
        self.entry = entry
        self.source = source
    }
}

/// Resolve only the configured startup preference (no catalog filtering).
public func resolvedDefaultModelPreference(
    input: CatalogResolutionInput,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Resolved<String>? {
    if let cli = input.defaultModelOverride?
        .trimmingCharacters(in: .whitespacesAndNewlines), !cli.isEmpty {
        return Resolved(value: cli, source: .cli)
    }
    if let env = environment[GROK_DEFAULT_MODEL_ENV]?
        .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
        return Resolved(value: env, source: .env)
    }
    if let cfg = input.models.default?
        .trimmingCharacters(in: .whitespacesAndNewlines), !cfg.isEmpty {
        return Resolved(value: cfg, source: .config)
    }
    if let remote = input.remoteDefaultModel?
        .trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty {
        return Resolved(value: remote, source: .remote)
    }
    return nil
}

/// Pick the default model with provider-auth filtering.
public func resolveDefaultModel(
    input: CatalogResolutionInput,
    catalog: OrderedModelMap,
    hasXaiSession: Bool,
    hasCodexSession: Bool,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> ResolvedDefaultModel {
    var visible = OrderedModelMap()
    for (key, entry) in catalog.pairs() {
        if entry.info.visibleForProviderAuth(
            hasXaiSession: hasXaiSession,
            hasCodexSession: hasCodexSession
        ), entry.info.userSelectable {
            visible[key] = entry
        }
    }

    let pref = resolvedDefaultModelPreference(input: input, environment: environment)

    func firstOrFallback() -> (String, ModelEntry) {
        let bundled = defaultModel()
        if let key = resolveCatalogKey(visible, modelID: bundled), let entry = visible[key] {
            return (key, entry)
        }
        if let first = visible.first {
            return (first.key, first.value)
        }
        if let (key, entry) = catalog.pairs().first(where: { $0.1.info.userSelectable }) {
            return (key, entry)
        }
        // Pre-catalog/degenerate only.
        var entry = ModelEntry.fallback(slug: bundled, endpoints: input.endpoints)
        switch ModelGlobSet.compile(input.models.allowedModels) {
        case .success(nil):
            entry.info.userSelectable = true
        case .success(let Some(set)):
            entry.info.userSelectable = set.matches(key: bundled, model: bundled)
        case .failure:
            entry.info.userSelectable = false
        }
        return (bundled, entry)
    }

    guard let pref else {
        let (key, entry) = firstOrFallback()
        return ResolvedDefaultModel(catalogKey: key, entry: entry, source: .default)
    }

    // Prefer exact key match over first slug match.
    if let found = visible.getKeyValue(pref.value) {
        return ResolvedDefaultModel(catalogKey: found.key, entry: found.value, source: pref.source)
    }
    if let (key, entry) = visible.pairs().first(where: { $0.1.model == pref.value }) {
        return ResolvedDefaultModel(catalogKey: key, entry: entry, source: pref.source)
    }

    // Campaign recovery.
    let campaignPrefMissing = input.models.defaultIsCampaignDriven && pref.source == .config
    if campaignPrefMissing,
       let prev = input.models.preCampaignDefault?
            .trimmingCharacters(in: .whitespacesAndNewlines),
       !prev.isEmpty {
        if let found = visible.getKeyValue(prev) {
            return ResolvedDefaultModel(catalogKey: found.key, entry: found.value, source: .config)
        }
        if let (key, entry) = visible.pairs().first(where: { $0.1.model == prev }) {
            return ResolvedDefaultModel(catalogKey: key, entry: entry, source: .config)
        }
    }

    let (key, entry) = firstOrFallback()
    return ResolvedDefaultModel(catalogKey: key, entry: entry, source: .default)
}

/// Convenience for single-auth-mode callers (both session flags equal).
public func resolveDefaultModel(
    input: CatalogResolutionInput,
    catalog: OrderedModelMap,
    isSessionAuth: Bool,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> ResolvedDefaultModel {
    resolveDefaultModel(
        input: input,
        catalog: catalog,
        hasXaiSession: isSessionAuth,
        hasCodexSession: isSessionAuth,
        environment: environment
    )
}

/// Filter to picker-visible models for provider auth state.
public func availableModels(
    catalog: OrderedModelMap,
    hasXaiSession: Bool,
    hasCodexSession: Bool
) -> OrderedModelMap {
    var out = OrderedModelMap()
    for (key, entry) in catalog.pairs() {
        if entry.info.visibleForProviderAuth(
            hasXaiSession: hasXaiSession,
            hasCodexSession: hasCodexSession
        ) {
            out[key] = entry
        }
    }
    return out
}
