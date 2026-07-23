// CodexModels.swift
//
// Live ChatGPT Codex model discovery types and wire parsing.
// Codex credentials and cache are isolated from xAI (`codex_models_cache.json`).

import Foundation
import OpenGrokSamplingTypes

public enum CodexModels {
    public static let cacheFileName = "codex_models_cache.json"
    public static let clientVersionEnv = "OPENGROK_CODEX_CLIENT_VERSION"
    public static let defaultClientVersion = "0.144.5"
    public static let defaultInferenceBaseURL = "https://chatgpt.com/backend-api/codex"
    public static let cacheTTLSeconds: TimeInterval = 300
    public static let defaultEffectiveContextWindowPercent: Int64 = 95

    public static func isTrustedInferenceBaseURL(_ baseURL: String) -> Bool {
        let candidate = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let defaultTrimmed = defaultInferenceBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if candidate.isEmpty || candidate == defaultTrimmed {
            return true
        }
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "chatgpt.com" || host == "chat.openai.com" || host == "api.openai.com"
    }

    public static func clientVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard let value = environment[clientVersionEnv]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return defaultClientVersion
        }
        return normalizeWholeSemver(value) ?? defaultClientVersion
    }

    /// Strip prerelease/build suffixes: `1.2.3-rc.1` → `1.2.3`.
    public static func normalizeWholeSemver(_ value: String) -> String? {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") {
            v = String(v.dropFirst())
        }
        let core = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? v
        let parts = core.split(separator: ".")
        guard parts.count >= 3,
              parts[0].allSatisfy(\.isNumber),
              parts[1].allSatisfy(\.isNumber),
              parts[2].allSatisfy(\.isNumber) else {
            return nil
        }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }
}

/// Codex backend visibility (list / hide / none).
public enum CodexModelVisibility: String, Codable, Sendable, Equatable, Hashable {
    case list
    case hide
    case none

    public var isListVisible: Bool { self == .list }
}

/// One converted remote Codex model plus merge metadata.
public struct CodexCatalogModel: Sendable, Equatable {
    public var priority: Int32
    public var visibility: CodexModelVisibility
    public var autoCompactTokenLimit: Int64?
    public var compHash: String?
    public var resolvedContextWindow: Int64?
    public var entry: ModelEntry

    public init(
        priority: Int32,
        visibility: CodexModelVisibility,
        autoCompactTokenLimit: Int64? = nil,
        compHash: String? = nil,
        resolvedContextWindow: Int64? = nil,
        entry: ModelEntry
    ) {
        self.priority = priority
        self.visibility = visibility
        self.autoCompactTokenLimit = autoCompactTokenLimit
        self.compHash = compHash
        self.resolvedContextWindow = resolvedContextWindow
        self.entry = entry
    }

    public var slug: String { entry.info.model }

    public func resolvedAutoCompactTokenLimit() -> UInt64? {
        let contextLimit = resolvedContextWindow.map { ($0 * 9) / 10 }
        let resolved: Int64?
        switch (contextLimit, autoCompactTokenLimit) {
        case let (Some(cl), Some(cfg)): resolved = min(cfg, cl)
        case let (Some(cl), nil): resolved = cl
        case let (nil, cfg): resolved = cfg
        }
        guard let resolved else { return nil }
        return UInt64(max(0, resolved))
    }
}

/// Provider-scoped Codex catalog snapshot.
public struct CodexModelsCatalog: Sendable, Equatable {
    public var models: [CodexCatalogModel]
    public var etag: String?
    /// Non-secret digest of the ChatGPT principal that produced this snapshot.
    public var accountFingerprint: String

    public init(
        models: [CodexCatalogModel],
        etag: String? = nil,
        accountFingerprint: String
    ) {
        self.models = models
        self.etag = etag
        self.accountFingerprint = accountFingerprint
    }

    /// ChatGPT treats a non-empty remote catalog containing at least one listed
    /// model as authoritative for the Codex partition.
    public var isAuthoritative: Bool {
        models.contains { $0.visibility.isListVisible }
    }

    /// All remote entries including hidden (so live can hide a same-slug fallback).
    public func entries() -> OrderedModelMap {
        var map = OrderedModelMap()
        for model in models {
            map[model.slug] = model.entry
        }
        return map
    }

    public func listVisibleEntries() -> OrderedModelMap {
        var map = OrderedModelMap()
        for model in models where model.visibility.isListVisible {
            map[model.slug] = model.entry
        }
        return map
    }
}

/// Parse a Codex `/models` JSON body into catalog models.
/// Unknown fields are ignored (forward-compatible).
public func parseCodexModelsResponse(
    _ data: Data,
    baseURL: String = CodexModels.defaultInferenceBaseURL
) throws -> [CodexCatalogModel] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = root["models"] as? [[String: Any]] else {
        throw ModelsError.remoteMalformed("codex models response missing models array")
    }
    return arr.compactMap { parseCodexWireModel($0, baseURL: baseURL) }
}

private func parseCodexWireModel(_ obj: [String: Any], baseURL: String) -> CodexCatalogModel? {
    guard let slug = obj["slug"] as? String, !slug.isEmpty else { return nil }
    let displayName = (obj["display_name"] as? String) ?? slug
    let description = obj["description"] as? String

    var efforts: [ReasoningEffortOption] = []
    if let levels = obj["supported_reasoning_levels"] as? [[String: Any]] {
        let defaultLevel = obj["default_reasoning_level"] as? String
        for level in levels {
            guard let effortRaw = level["effort"] as? String,
                  let value = WireCodec.reasoningEffort(effortRaw) else { continue }
            let desc = level["description"] as? String ?? ""
            let isDefault = effortRaw == defaultLevel
            efforts.append(
                ReasoningEffortOption(
                    id: value.asString,
                    value: value,
                    label: value.asString,
                    description: desc.isEmpty ? nil : desc,
                    isDefault: isDefault
                )
            )
        }
    }

    let visibilityRaw = (obj["visibility"] as? String)?.lowercased() ?? "none"
    let visibility = CodexModelVisibility(rawValue: visibilityRaw) ?? .none
    let supportedInApi = obj["supported_in_api"] as? Bool ?? false
    let priority = (obj["priority"] as? NSNumber)?.int32Value ?? 0
    let contextWindow = (obj["context_window"] as? NSNumber)?.int64Value
    let maxContextWindow = (obj["max_context_window"] as? NSNumber)?.int64Value
    let resolvedContext = contextWindow ?? maxContextWindow
    let percent = (obj["effective_context_window_percent"] as? NSNumber)?.int64Value
        ?? CodexModels.defaultEffectiveContextWindowPercent
    let effectiveContext: UInt64
    if let resolved = resolvedContext, resolved > 0 {
        let projected = (resolved * percent) / 100
        effectiveContext = UInt64(max(1, projected))
    } else {
        effectiveContext = NEW_MODEL_DEFAULT_CONTEXT_WINDOW
    }

    let toolMode = WireCodec.toolMode(obj["tool_mode"] as? String)
    let multiAgent = obj["multi_agent_version"] as? String
    let supportsSummary = obj["supports_reasoning_summary_parameter"] as? Bool ?? true
    let defaultSummary = WireCodec.reasoningSummary(obj["default_reasoning_summary"] as? String)
        ?? .detailed
    let supportsSearch = obj["supports_search_tool"] as? Bool ?? false

    var info = ModelInfo.fallback(slug: slug)
    info.model = slug
    info.baseURL = baseURL
    info.name = displayName
    info.description = description
    info.apiBackend = .responses
    info.provider = .codex
    info.toolMode = toolMode
    info.codexMultiAgentV2 = multiAgent == "v2"
    info.agentType = "codex"
    info.contextWindow = effectiveContext
    info.supportedInApi = supportedInApi
    info.hidden = !visibility.isListVisible
    info.reasoningEfforts = efforts
    info.supportsReasoningEffort = !efforts.isEmpty
    if !efforts.isEmpty {
        info.reasoningEffort = efforts.first(where: \.isDefault)?.value ?? efforts.first?.value
    }
    info.supportsReasoningSummaryParameter = supportsSummary
    info.defaultReasoningSummary = supportsSummary ? defaultSummary : .none
    info.supportsBackendSearch = supportsSearch

    let entry = ModelEntry(info: info)
    return CodexCatalogModel(
        priority: priority,
        visibility: visibility,
        autoCompactTokenLimit: (obj["auto_compact_token_limit"] as? NSNumber)?.int64Value,
        compHash: obj["comp_hash"] as? String,
        resolvedContextWindow: resolvedContext,
        entry: entry
    )
}

// MARK: - Codex disk cache (isolated path)

public struct CodexModelsCacheDocument: Sendable, Equatable, Codable {
    public var fetchedAt: Date
    public var etag: String?
    public var accountFingerprint: String
    public var models: [CodexCachedModel]

    public init(
        fetchedAt: Date,
        etag: String?,
        accountFingerprint: String,
        models: [CodexCachedModel]
    ) {
        self.fetchedAt = fetchedAt
        self.etag = etag
        self.accountFingerprint = accountFingerprint
        self.models = models
    }

    public enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case etag
        case accountFingerprint = "account_fingerprint"
        case models
    }
}

public struct CodexCachedModel: Sendable, Equatable, Codable {
    public var priority: Int32
    public var visibility: String
    public var autoCompactTokenLimit: Int64?
    public var compHash: String?
    public var resolvedContextWindow: Int64?
    public var entry: ModelEntry

    public enum CodingKeys: String, CodingKey {
        case priority, visibility, entry
        case autoCompactTokenLimit = "auto_compact_token_limit"
        case compHash = "comp_hash"
        case resolvedContextWindow = "resolved_context_window"
    }
}

/// Codex-only disk cache under `$OPENGROK_HOME/codex_models_cache.json`.
public struct CodexModelsCacheManager: Sendable {
    public let path: URL
    public let ttl: TimeInterval

    public init(grokHome: URL, ttl: TimeInterval = CodexModels.cacheTTLSeconds) {
        self.path = grokHome.appendingPathComponent(CodexModels.cacheFileName)
        self.ttl = ttl
    }

    public func isFresh(_ doc: CodexModelsCacheDocument, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(doc.fetchedAt)
        return age >= 0 && age < ttl
    }

    public func loadFresh(
        expectedAccountFingerprint: String,
        now: Date = Date()
    ) -> CodexModelsCatalog? {
        guard let data = try? Data(contentsOf: path),
              let doc = try? JSONDecoder().decode(CodexModelsCacheDocument.self, from: data),
              doc.accountFingerprint == expectedAccountFingerprint,
              isFresh(doc, now: now) else {
            return nil
        }
        let models: [CodexCatalogModel] = doc.models.compactMap { cached in
            let visibility = CodexModelVisibility(rawValue: cached.visibility) ?? .none
            return CodexCatalogModel(
                priority: cached.priority,
                visibility: visibility,
                autoCompactTokenLimit: cached.autoCompactTokenLimit,
                compHash: cached.compHash,
                resolvedContextWindow: cached.resolvedContextWindow,
                entry: cached.entry
            )
        }
        return CodexModelsCatalog(
            models: models,
            etag: doc.etag,
            accountFingerprint: doc.accountFingerprint
        )
    }

    public func persist(_ catalog: CodexModelsCatalog, now: Date = Date()) throws {
        let models = catalog.models.map { m in
            CodexCachedModel(
                priority: m.priority,
                visibility: m.visibility.rawValue,
                autoCompactTokenLimit: m.autoCompactTokenLimit,
                compHash: m.compHash,
                resolvedContextWindow: m.resolvedContextWindow,
                entry: m.entry
            )
        }
        let doc = CodexModelsCacheDocument(
            fetchedAt: now,
            etag: catalog.etag,
            accountFingerprint: catalog.accountFingerprint,
            models: models
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        try writeAtomicallyData(path, contents: data)
    }

    public func invalidate() {
        try? FileManager.default.removeItem(at: path)
    }
}
