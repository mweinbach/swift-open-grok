// CodexModels.swift
//
// Live ChatGPT Codex model discovery types and wire parsing.
// Codex credentials and cache are isolated from xAI (`codex_models_cache.json`).

import Foundation
import OpenGrokSamplingTypes
import OpenGrokVersion

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

    public static func cacheEndpointIdentity(_ baseURL: String) -> (origin: String, baseURL: String)? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }

        let portString: String
        if let port = url.port {
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                portString = ""
            } else {
                portString = ":\(port)"
            }
        } else {
            portString = ""
        }
        let origin = "\(scheme)://\(host)\(portString)"
        return (origin, normalized)
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
    var models = arr.compactMap { parseCodexWireModel($0, baseURL: baseURL) }
    models.sort { $0.priority < $1.priority }
    return models
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

    let toolMode: ToolMode?
    if let rawToolMode = obj["tool_mode"] as? String {
        guard let mode = WireCodec.toolMode(rawToolMode) else {
            return nil
        }
        toolMode = mode
    } else {
        toolMode = nil
    }

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
    // The Codex transport is OAuth-only in Open Grok; supportedInApi describes
    // upstream API-key availability, which is forced false locally to require a Codex session.
    info.supportedInApi = false
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
    public var openGrokVersion: String
    public var clientVersion: String
    public var baseOrigin: String
    public var baseURL: String
    public var accountFingerprint: String
    public var etag: String?
    public var models: [CodexCachedModel]

    public init(
        fetchedAt: Date,
        openGrokVersion: String,
        clientVersion: String,
        baseOrigin: String,
        baseURL: String,
        accountFingerprint: String,
        etag: String? = nil,
        models: [CodexCachedModel]
    ) {
        self.fetchedAt = fetchedAt
        self.openGrokVersion = openGrokVersion
        self.clientVersion = clientVersion
        self.baseOrigin = baseOrigin
        self.baseURL = baseURL
        self.accountFingerprint = accountFingerprint
        self.etag = etag
        self.models = models
    }

    public enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case openGrokVersion = "open_grok_version"
        case clientVersion = "client_version"
        case baseOrigin = "base_origin"
        case baseURL = "base_url"
        case accountFingerprint = "account_fingerprint"
        case etag
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
    public let versionProvider: @Sendable () -> String
    public let clientVersionProvider: @Sendable () -> String
    public let baseURLProvider: @Sendable () -> String

    public init(
        grokHome: URL,
        ttl: TimeInterval = CodexModels.cacheTTLSeconds,
        versionProvider: @escaping @Sendable () -> String = { OpenGrokVersion.installed() },
        clientVersionProvider: @escaping @Sendable () -> String = { CodexModels.clientVersion() },
        baseURLProvider: @escaping @Sendable () -> String = { CodexModels.defaultInferenceBaseURL }
    ) {
        self.path = grokHome.appendingPathComponent(CodexModels.cacheFileName)
        self.ttl = ttl
        self.versionProvider = versionProvider
        self.clientVersionProvider = clientVersionProvider
        self.baseURLProvider = baseURLProvider
    }

    public func isFresh(_ doc: CodexModelsCacheDocument, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(doc.fetchedAt)
        return age >= 0 && age < ttl
    }

    public func loadFresh(
        expectedAccountFingerprint: String,
        openGrokVersion: String? = nil,
        clientVersion: String? = nil,
        baseURL: String? = nil,
        now: Date = Date()
    ) -> CodexModelsCatalog? {
        let targetOpenGrokVersion = openGrokVersion ?? versionProvider()
        let targetClientVersion = clientVersion ?? clientVersionProvider()
        let targetBaseURL = baseURL ?? baseURLProvider()

        guard let (expectedOrigin, expectedNormalizedBaseURL) = CodexModels.cacheEndpointIdentity(targetBaseURL),
              let data = try? Data(contentsOf: path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let doc = try? decoder.decode(CodexModelsCacheDocument.self, from: data) else {
            return nil
        }

        if doc.openGrokVersion != targetOpenGrokVersion { return nil }
        if doc.clientVersion != targetClientVersion { return nil }
        if doc.baseOrigin != expectedOrigin || doc.baseURL != expectedNormalizedBaseURL { return nil }
        if doc.accountFingerprint != expectedAccountFingerprint { return nil }
        if !isFresh(doc, now: now) { return nil }

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

    public func persist(
        _ catalog: CodexModelsCatalog,
        openGrokVersion: String? = nil,
        clientVersion: String? = nil,
        baseURL: String? = nil,
        now: Date = Date()
    ) throws {
        let targetOpenGrokVersion = openGrokVersion ?? versionProvider()
        let targetClientVersion = clientVersion ?? clientVersionProvider()
        let targetBaseURL = baseURL ?? baseURLProvider()

        guard let (origin, normalizedBaseURL) = CodexModels.cacheEndpointIdentity(targetBaseURL) else {
            throw ModelsError.remoteMalformed("Invalid base URL for cache identity: \(targetBaseURL)")
        }

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
            openGrokVersion: targetOpenGrokVersion,
            clientVersion: targetClientVersion,
            baseOrigin: origin,
            baseURL: normalizedBaseURL,
            accountFingerprint: catalog.accountFingerprint,
            etag: catalog.etag,
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

