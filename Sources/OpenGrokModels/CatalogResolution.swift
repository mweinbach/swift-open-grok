// CatalogResolution.swift
//
// Assemble the final model map. Priority (highest wins):
//   config `[model.*]` > provider remote partitions > hardcoded defaults
//
// Each remote catalog may replace only entries from its own provider.
// Codex / Kimi / Fireworks catalogs must never contaminate the xAI partition.

import Foundation
import OpenGrokConfigTypes
import OpenGrokSamplingTypes

// MARK: - Lookup

/// Resolve a model against the available model map.
/// Checks the map key (id) first, then falls back to a slug scan.
public func findModelByID(_ models: OrderedModelMap, modelID: String) -> ModelEntry? {
    if let entry = models[modelID] { return entry }
    return models.values().first { $0.model == modelID }
}

/// Map a persisted model id/slug to a catalog key.
/// Exact key match wins; otherwise the last slug match wins.
public func resolveCatalogKey(_ models: OrderedModelMap, modelID: String) -> String? {
    if models.contains(modelID) { return modelID }
    var last: String?
    for (key, entry) in models.pairs() where entry.model == modelID {
        last = key
    }
    return last
}

// MARK: - List assembly

/// Assemble the final model map without provider remotes.
public func resolveModelList(
    input: CatalogResolutionInput,
    prefetched: OrderedModelMap? = nil
) -> OrderedModelMap {
    resolveModelListWithProviderCatalogs(
        input: input,
        prefetched: prefetched,
        codexRemote: nil,
        codexAuthoritative: false,
        kimiRemote: nil,
        kimiAuthoritative: false,
        fireworksRemote: nil,
        fireworksAuthoritative: false
    )
}

/// Assemble independently queried provider partitions before applying shared
/// user overrides and filters.
public func resolveModelListWithProviderCatalogs(
    input: CatalogResolutionInput,
    prefetched: OrderedModelMap?,
    codexRemote: OrderedModelMap?,
    codexAuthoritative: Bool,
    kimiRemote: OrderedModelMap?,
    kimiAuthoritative: Bool,
    fireworksRemote: OrderedModelMap?,
    fireworksAuthoritative: Bool
) -> OrderedModelMap {
    var resolved = OrderedModelMap()
    let defaults = defaultModelEntries(
        endpoints: input.endpoints,
        kimiEndpoint: input.models.kimiEndpoint
    )

    if input.endpoints.hasCustomEndpoint() {
        // Skip built-in xAI defaults when a custom models endpoint is active.
        for (key, entry) in defaults.pairs() where entry.info.provider != .xai {
            resolved[key] = entry
        }
    } else {
        for (key, entry) in defaults.pairs() {
            resolved[key] = entry
        }
    }

    // xAI prefetched remote catalog.
    if var prefetched {
        prefetched.retain { _, entry in entry.info.provider == .xai }
        for (key, var entry) in prefetched.pairs() {
            if let donor = resolved[key], donor.info.provider == entry.info.provider {
                inheritDonorMetadata(into: &entry, from: donor)
            }
            prefetched[key] = entry
        }
        // Remote xAI is authoritative only for xAI entries.
        var merged = OrderedModelMap()
        for (key, entry) in resolved.pairs() where entry.info.provider != .xai {
            merged[key] = entry
        }
        for (key, entry) in prefetched.pairs() {
            if let existing = merged[key], existing.info.provider != .xai {
                var qualified = "xai:\(key)"
                var suffix = 2
                while merged.contains(qualified) {
                    qualified = "xai:\(key):\(suffix)"
                    suffix += 1
                }
                merged[qualified] = entry
            } else {
                merged[key] = entry
            }
        }
        resolved = merged
    }

    mergeRemoteProviderPartition(
        resolved: &resolved,
        defaults: defaults,
        remote: codexRemote,
        provider: .codex,
        authoritative: codexAuthoritative
    )

    let kimiLive = KimiModels.liveDiscoveryEnabled(input.models.kimiEndpoint)
    mergeRemoteProviderPartition(
        resolved: &resolved,
        defaults: defaults,
        remote: kimiLive ? kimiRemote : nil,
        provider: .kimi,
        authoritative: kimiLive && kimiAuthoritative
    )

    mergeRemoteProviderPartition(
        resolved: &resolved,
        defaults: defaults,
        remote: fireworksRemote,
        provider: .fireworks,
        authoritative: fireworksAuthoritative
    )

    // Config `[model.*]` overrides win over remotes and defaults.
    for (key, modelOverride) in input.configModels {
        let base = resolved.shiftRemove(key)
        let entry = modelOverride.apply(key: key, base: base, endpoints: input.endpoints)
        resolved[key] = entry
    }

    // Slug-match sibling inheritance for context_window / backend / tool_mode.
    inheritSiblingMetadata(&resolved)

    if let globalAgentType = input.models.agentType {
        for (key, var entry) in resolved.pairs() {
            if entry.info.agentType == DEFAULT_AGENT_TYPE {
                entry.info.agentType = globalAgentType
                resolved[key] = entry
            }
        }
    }

    applyGlobalExtraHeaders(&resolved, models: input.models)
    applyGlobalScalarDefaults(&resolved, models: input.models)

    for (key, var entry) in resolved.pairs() {
        entry.info.deriveReasoningEffortFields()
        resolved[key] = entry
    }

    return resolved
}

// MARK: - Catalog filters

/// Single source of truth for the catalog after shared filters.
/// Applies, in order: `disabled_models` (remove), `allowed_models`
/// (mark `userSelectable`), `hidden_models` (mark `hidden`).
public func resolveModelCatalog(
    input: CatalogResolutionInput,
    prefetched: OrderedModelMap? = nil,
    codexCatalog: CodexModelsCatalog? = nil,
    kimiCatalog: KimiModelsCatalog? = nil,
    fireworksCatalog: FireworksModelsCatalog? = nil
) -> OrderedModelMap {
    var catalog = resolveModelListWithProviderCatalogs(
        input: input,
        prefetched: prefetched,
        codexRemote: codexCatalog?.entries(),
        codexAuthoritative: codexCatalog?.isAuthoritative ?? false,
        kimiRemote: kimiCatalog?.entries,
        kimiAuthoritative: kimiCatalog?.isAuthoritative ?? false,
        fireworksRemote: fireworksCatalog?.entries,
        fireworksAuthoritative: fireworksCatalog?.isAuthoritative ?? false
    )

    switch ModelGlobSet.compile(input.models.disabledModels) {
    case .success(.some(let disabled)):
        catalog.retain { key, entry in !disabled.matches(key: key, model: entry.model) }
    case .failure:
        // Invalid deny patterns fail closed by leaving the catalog empty.
        catalog = OrderedModelMap()
    case .success(nil):
        break
    }

    switch ModelGlobSet.compile(input.models.allowedModels) {
    case .success(nil):
        for (key, var entry) in catalog.pairs() {
            entry.info.userSelectable = true
            catalog[key] = entry
        }
    case .success(let allowed):
        if let allowed {
            for (key, var entry) in catalog.pairs() {
                entry.info.userSelectable = allowed.matches(key: key, model: entry.model)
                catalog[key] = entry
            }
        }
    case .failure:
        // Fail closed: nothing selectable.
        for (key, var entry) in catalog.pairs() {
            entry.info.userSelectable = false
            catalog[key] = entry
        }
    }

    switch ModelGlobSet.compile(input.models.hiddenModels) {
    case .success(.some(let hidden)):
        for (key, var entry) in catalog.pairs() {
            if hidden.matches(key: key, model: entry.model) {
                entry.info.hidden = true
                catalog[key] = entry
            }
        }
    default:
        break
    }

    // Persisted default effort.
    if let effort = input.models.defaultReasoningEffort,
       let defaultID = input.models.default,
       var entry = catalog[defaultID],
       entry.info.supportsReasoningEffort {
        entry.info.reasoningEffort = effort
        catalog[defaultID] = entry
    }

    // CLI effort override — only models that offer the value.
    if let effort = input.reasoningEffortOverride {
        for (key, var entry) in catalog.pairs() {
            if modelOffersReasoningEffort(entry.info, effort: effort) {
                entry.info.reasoningEffort = effort
                catalog[key] = entry
            }
        }
    }

    return catalog
}

/// Whether `effort` is a value this model will accept on the wire.
public func modelOffersReasoningEffort(_ info: ModelInfo, effort: ReasoningEffort) -> Bool {
    guard info.supportsReasoningEffort else { return false }
    if info.reasoningEfforts.isEmpty {
        switch effort {
        case .low, .medium, .high, .xhigh: return true
        default: return false
        }
    }
    return info.reasoningEfforts.contains { $0.value == effort }
}

/// True when an active `allowed_models` allowlist leaves no selectable model.
public func allowlistMatchesNothing(
    input: CatalogResolutionInput,
    catalog: OrderedModelMap
) -> Bool {
    guard let allowed = input.models.allowedModels, !allowed.isEmpty else { return false }
    return !catalog.values().contains { $0.info.userSelectable }
}

/// Reject an allowlist that matches nothing or excludes an explicit default/`-m`.
public func validateSelectable(
    input: CatalogResolutionInput,
    catalog: OrderedModelMap
) throws {
    guard let allowed = input.models.allowedModels, !allowed.isEmpty else { return }
    let patterns = allowed.joined(separator: ", ")
    if !catalog.values().contains(where: { $0.info.userSelectable }) {
        throw ModelsError.allowlistMatchesNothing(patterns: patterns)
    }
    for (src, id) in [
        ("default", input.models.default),
        ("-m flag", input.defaultModelOverride),
    ] {
        guard let id else { continue }
        if let entry = catalog[id] ?? catalog.values().first(where: { $0.model == id }),
           !entry.info.userSelectable {
            throw ModelsError.allowlistExcludesDefault(id: id, source: src, patterns: patterns)
        }
    }
}

// MARK: - Provider partition merge

func mergeRemoteProviderPartition(
    resolved: inout OrderedModelMap,
    defaults: OrderedModelMap,
    remote: OrderedModelMap?,
    provider: ModelProvider,
    authoritative: Bool
) {
    guard var remote else { return }

    // Preserve local execution metadata from same-provider same-key donors.
    for (key, var entry) in remote.pairs() {
        guard entry.info.provider == provider else { continue }
        if let donor = defaults[key], donor.info.provider == provider {
            inheritDonorMetadata(into: &entry, from: donor)
            // Also inherit reasoning menu when remote omits it.
            if entry.info.reasoningEfforts.isEmpty, !donor.info.reasoningEfforts.isEmpty {
                entry.info.reasoningEfforts = donor.info.reasoningEfforts
                entry.info.supportsReasoningEffort = donor.info.supportsReasoningEffort
                entry.info.reasoningEffort = donor.info.reasoningEffort
            }
        }
        remote[key] = entry
    }
    remote.retain { _, entry in entry.info.provider == provider }

    if authoritative && !remote.isEmpty {
        resolved.retain { _, entry in entry.info.provider != provider }
    }

    for (key, entry) in remote.pairs() {
        if let existing = resolved[key], existing.info.provider != provider {
            let existingProvider = existing.info.provider.asString
            var qualified = "\(existingProvider):\(key)"
            var suffix = 2
            while resolved.contains(qualified) {
                qualified = "\(existingProvider):\(key):\(suffix)"
                suffix += 1
            }
            _ = resolved.shiftRemove(key)
            resolved[qualified] = existing
        }
        resolved[key] = entry
    }
}

private func inheritDonorMetadata(into entry: inout ModelEntry, from donor: ModelEntry) {
    if entry.info.contextWindow == DEFAULT_CONTEXT_WINDOW,
       donor.info.contextWindow != DEFAULT_CONTEXT_WINDOW {
        entry.info.contextWindow = donor.info.contextWindow
    }
    if entry.info.agentType == DEFAULT_AGENT_TYPE {
        entry.info.agentType = donor.info.agentType
    }
    if entry.info.apiBackend == .defaultValue {
        entry.info.apiBackend = donor.info.apiBackend
    }
    if entry.info.toolMode == nil {
        entry.info.toolMode = donor.info.toolMode
    }
}

private func inheritSiblingMetadata(_ resolved: inout OrderedModelMap) {
    typealias DonorMeta = (UInt64, ApiBackend, ToolMode?)
    var donors: [ModelProvider: [String: DonorMeta]] = [:]
    for entry in resolved.values() where entry.info.contextWindow != DEFAULT_CONTEXT_WINDOW {
        donors[entry.info.provider, default: [:]][entry.info.model] = (
            entry.info.contextWindow,
            entry.info.apiBackend,
            entry.info.toolMode
        )
    }
    for (key, var entry) in resolved.pairs() {
        guard let providerDonors = donors[entry.info.provider],
              let (donorCW, donorBackend, donorToolMode) = providerDonors[entry.info.model] else {
            continue
        }
        if entry.info.contextWindow == DEFAULT_CONTEXT_WINDOW {
            entry.info.contextWindow = donorCW
        }
        if entry.info.apiBackend == .defaultValue, donorBackend != .defaultValue {
            entry.info.apiBackend = donorBackend
        }
        if entry.info.toolMode == nil {
            entry.info.toolMode = donorToolMode
        }
        resolved[key] = entry
    }
}

private func applyGlobalExtraHeaders(
    _ resolved: inout OrderedModelMap,
    models: ModelsSectionConfig
) {
    guard !models.extraHeaders.isEmpty else { return }
    for (key, var entry) in resolved.pairs() {
        for (hk, hv) in models.extraHeaders {
            let present = entry.info.extraHeaders.contains {
                $0.0.compare(hk, options: .caseInsensitive) == .orderedSame
            }
            if !present {
                entry.info.extraHeaders.append((hk, hv))
            }
        }
        resolved[key] = entry
    }
}

private func applyGlobalScalarDefaults(
    _ resolved: inout OrderedModelMap,
    models: ModelsSectionConfig
) {
    for (key, var entry) in resolved.pairs() {
        if entry.info.temperature == nil, let v = models.temperature {
            entry.info.temperature = v
        }
        if entry.info.topP == nil, let v = models.topP {
            entry.info.topP = v
        }
        if entry.info.maxCompletionTokens == nil, let v = models.maxCompletionTokens {
            entry.info.maxCompletionTokens = v
        }
        if entry.info.maxRetries == nil, let v = models.maxRetries {
            entry.info.maxRetries = v
        }
        if entry.info.inferenceIdleTimeoutSecs == nil, let v = models.inferenceIdleTimeoutSecs {
            entry.info.inferenceIdleTimeoutSecs = v
        }
        if entry.info.streamToolCalls == nil, let v = models.streamToolCalls {
            entry.info.streamToolCalls = v
        }
        resolved[key] = entry
    }
}

// MARK: - Trusted endpoint & Auxiliary model policy

/// Single source of truth for whether an endpoint URL is trusted to receive built-in session bearer material.
public func trustedBuiltInSessionEndpoint(provider: ModelProvider, baseURL: String) -> Bool {
    switch provider.profile.sessionAuth {
    case .apiKeyOnly:
        if provider == .kimi {
            return KimiModels.isTrustedAPIBaseURL(baseURL)
        }
        if provider == .fireworks {
            return FireworksModels.isTrustedAPIBaseURL(baseURL)
        }
        if provider == .deepseek {
            return DeepSeekModels.isTrustedAPIBaseURL(baseURL)
        }
        if provider == .openCodeGo {
            return OpenCodeGoModels.isTrustedAPIBaseURL(baseURL)
        }
        if provider == .wafer {
            return WaferModels.isTrustedAPIBaseURL(baseURL)
        }
        return false
    case .xaiSession:
        return isXaiApiBearerURL(baseURL)
    case .codexOAuth:
        return CodexModels.isTrustedInferenceBaseURL(baseURL)
    }
}

/// Standalone sampling configuration resolved for an auxiliary model (web search, image description, session summary).
public struct AuxiliaryModelSamplingConfig: Sendable, Equatable {
    public var modelID: String
    public var routingModel: String
    public var baseURL: String
    public var apiKey: String?
    public var provider: ModelProvider
    public var apiBackend: ApiBackend
    public var toolMode: ToolMode?

    public init(
        modelID: String,
        routingModel: String,
        baseURL: String,
        apiKey: String?,
        provider: ModelProvider,
        apiBackend: ApiBackend,
        toolMode: ToolMode? = nil
    ) {
        self.modelID = modelID
        self.routingModel = routingModel
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.provider = provider
        self.apiBackend = apiBackend
        self.toolMode = toolMode
    }
}

/// Resolve a standalone sampling configuration for an auxiliary model slug (image description,
/// session summary, web search), resolved through the catalog so a `[model.*]` override
/// redirects it to its own endpoint, credentials, and routing model.
///
/// Enforces provider isolation: session bearer tokens are sent only to trusted first-party endpoints.
/// Custom/third-party auxiliary endpoints require endpoint-owned credentials (`apiKey` or `envKey`).
public func resolveAuxiliaryModelSamplingConfig(
    modelID: String,
    catalog: OrderedModelMap,
    endpoints: EndpointsConfig = .default,
    sessionKey: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> AuxiliaryModelSamplingConfig? {
    let catalogEntry = findModelByID(catalog, modelID: modelID)
    if let entry = catalogEntry {
        let isTrusted = trustedBuiltInSessionEndpoint(
            provider: entry.info.provider,
            baseURL: entry.info.baseURL
        )
        let hasOwn = entry.hasOwnCredentials(environment: environment)

        if !isTrusted && !hasOwn {
            return nil
        }

        let resolvedKey: String?
        if hasOwn {
            resolvedKey = entry.ownCredential(environment: environment)
        } else if isTrusted && entry.info.provider == .xai {
            resolvedKey = sessionKey
                ?? environment["XAI_API_KEY"]
                ?? endpoints.deploymentKey
        } else if isTrusted && entry.info.provider == .codex {
            resolvedKey = sessionKey
        } else {
            resolvedKey = nil
        }

        guard let apiKey = resolvedKey, !apiKey.isEmpty else {
            return nil
        }

        return AuxiliaryModelSamplingConfig(
            modelID: modelID,
            routingModel: entry.info.model,
            baseURL: entry.info.baseURL,
            apiKey: apiKey,
            provider: entry.info.provider,
            apiBackend: entry.info.apiBackend,
            toolMode: entry.info.toolMode
        )
    }

    let defaultBase = endpoints.resolveInferenceBaseURL()
    if isXaiApiBearerURL(defaultBase) {
        if let bearer = sessionKey
            ?? environment["XAI_API_KEY"]
            ?? endpoints.deploymentKey,
           !bearer.isEmpty {
            return AuxiliaryModelSamplingConfig(
                modelID: modelID,
                routingModel: modelID,
                baseURL: defaultBase,
                apiKey: bearer,
                provider: .xai,
                apiBackend: .responses
            )
        }
    }

    return nil
}
