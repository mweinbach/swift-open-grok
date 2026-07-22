// CapabilityQuery.swift
//
// Capability truth comes only from validated catalog data. Callers must not
// infer unsupported capabilities from model names or URLs.

import Foundation
import OpenGrokSamplingTypes

/// Normalized, provider-neutral capability snapshot for one catalog entry.
public struct ModelCapabilities: Sendable, Equatable {
    public var catalogKey: String
    public var model: String
    public var provider: ModelProvider
    public var apiBackend: ApiBackend
    public var displayName: String?
    public var contextWindow: UInt64
    public var maxCompletionTokens: UInt32?
    public var toolMode: ToolMode?
    public var supportsReasoningEffort: Bool
    public var reasoningEfforts: [ReasoningEffortOption]
    public var defaultReasoningEffort: ReasoningEffort?
    public var supportsReasoningSummaryParameter: Bool
    public var defaultReasoningSummary: ReasoningSummary
    public var supportsBackendSearch: Bool
    public var supportedInApi: Bool
    public var hidden: Bool
    public var userSelectable: Bool
    public var codexMultiAgentV2: Bool
    public var agentType: String
    public var showModelFingerprint: Bool
    public var nativeWebSearch: Bool
    public var hostedToolDialect: HostedToolDialect?
    public var allowsXaiServices: Bool
    public var sessionAuth: BuiltInSessionAuthKind

    public init(catalogKey: String, entry: ModelEntry) {
        let info = entry.info
        let profile = info.provider.profile
        self.catalogKey = catalogKey
        self.model = info.model
        self.provider = info.provider
        self.apiBackend = info.apiBackend
        self.displayName = info.name
        self.contextWindow = info.contextWindow
        self.maxCompletionTokens = info.maxCompletionTokens
        self.toolMode = info.toolMode
        self.supportsReasoningEffort = info.supportsReasoningEffort
        self.reasoningEfforts = info.reasoningEfforts
        self.defaultReasoningEffort = info.reasoningEffort
        self.supportsReasoningSummaryParameter = info.supportsReasoningSummaryParameter
        self.defaultReasoningSummary = info.defaultReasoningSummary
        self.supportsBackendSearch = info.supportsBackendSearch
        self.supportedInApi = info.supportedInApi
        self.hidden = info.hidden
        self.userSelectable = info.userSelectable
        self.codexMultiAgentV2 = info.codexMultiAgentV2
        self.agentType = info.agentType
        self.showModelFingerprint = info.showModelFingerprint
        self.nativeWebSearch = profile.nativeWebSearch
        self.hostedToolDialect = profile.hostedToolDialect
        self.allowsXaiServices = profile.allowsXaiServices
        self.sessionAuth = profile.sessionAuth
    }
}

/// Look up capabilities by catalog key or routing slug. Returns `nil` when
/// the model is not in the catalog — never fabricates capabilities from the name.
public func capabilitySnapshot(
    for modelID: String,
    in catalog: OrderedModelMap
) -> ModelCapabilities? {
    if let entry = catalog[modelID] {
        return ModelCapabilities(catalogKey: modelID, entry: entry)
    }
    if let key = resolveCatalogKey(catalog, modelID: modelID), let entry = catalog[key] {
        return ModelCapabilities(catalogKey: key, entry: entry)
    }
    return nil
}

/// Alias matching the colloquial "capabilities for model" call site.
public func capabilities(
    for modelID: String,
    in catalog: OrderedModelMap
) -> ModelCapabilities? {
    capabilitySnapshot(for: modelID, in: catalog)
}

/// Whether the model supports a given capability flag from catalog data only.
public enum ModelCapabilityFlag: String, Sendable, Equatable, Hashable {
    case reasoningEffort
    case reasoningSummary
    case backendSearch
    case imageSupport  // not yet a first-class catalog field; always false unless extended
    case toolUse       // all catalog models that are not hidden for tools; use toolMode
    case multiAgentV2
    case codeMode
    case codeModeOnly
    case nativeWebSearch
}

/// Query a boolean capability. Unknown models return `false` (fail closed).
public func modelSupports(
    _ flag: ModelCapabilityFlag,
    modelID: String,
    catalog: OrderedModelMap
) -> Bool {
    guard let caps = capabilitySnapshot(for: modelID, in: catalog) else { return false }
    switch flag {
    case .reasoningEffort: return caps.supportsReasoningEffort
    case .reasoningSummary: return caps.supportsReasoningSummaryParameter
    case .backendSearch: return caps.supportsBackendSearch
    case .imageSupport: return false  // no catalog field; never infer from name
    case .toolUse: return true
    case .multiAgentV2: return caps.codexMultiAgentV2
    case .codeMode: return caps.toolMode == .codeMode || caps.toolMode == .codeModeOnly
    case .codeModeOnly: return caps.toolMode == .codeModeOnly
    case .nativeWebSearch: return caps.nativeWebSearch
    }
}

/// Display gate for the model fingerprint: catalog opt-in. Does **not**
/// invent a coding-slug heuristic here; shell may layer its own presentation
/// gate on top, but capability truth remains catalog-owned.
public func shouldShowModelFingerprint(catalogFlag: Bool) -> Bool {
    catalogFlag
}
