// DeepSeekModels.swift
//
// Provider-isolated DeepSeek direct model discovery.
// Port of `crates/codegen/xai-grok-shell/src/deepseek_models.rs`.
//
// DeepSeek serves an OpenAI-compatible Chat Completions API. The provider's
// `/models` endpoint is authoritative for the curated direct-model partition;
// unknown future model ids fail closed until their limits and capabilities are
// reviewed here.

import Foundation
import OpenGrokSamplingTypes

public struct CuratedDeepSeekModel: Sendable, Equatable {
    public let key: String
    public let slug: String
    public let name: String
    public let description: String
    public let contextWindow: UInt64
    public let maxOutputTokens: UInt32
    public let apiBackend: ApiBackend
    public let supportsBackendSearch: Bool

    public init(
        key: String,
        slug: String,
        name: String,
        description: String,
        contextWindow: UInt64,
        maxOutputTokens: UInt32,
        apiBackend: ApiBackend,
        supportsBackendSearch: Bool
    ) {
        self.key = key
        self.slug = slug
        self.name = name
        self.description = description
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.apiBackend = apiBackend
        self.supportsBackendSearch = supportsBackendSearch
    }
}

public enum DeepSeekModels {
    public static let apiBaseURLDefault = "https://api.deepseek.com"
    public static let apiBaseURLEnv = "OPENGROK_DEEPSEEK_API_BASE_URL"
    public static let apiKeyEnv = "DEEPSEEK_API_KEY"

    /// V4 Pro stays on Chat Completions; V4 Flash 0731 routes to DeepSeek's
    /// native stateless Responses API and carries hosted web search.
    public static let curated: [CuratedDeepSeekModel] = [
        CuratedDeepSeekModel(
            key: "deepseek:deepseek-v4-pro",
            slug: "deepseek-v4-pro",
            name: "DeepSeek V4 Pro",
            description: "DeepSeek V4 Pro through the direct DeepSeek API",
            contextWindow: 1_000_000,
            maxOutputTokens: 384_000,
            apiBackend: .chatCompletions,
            supportsBackendSearch: false
        ),
        CuratedDeepSeekModel(
            key: "deepseek:deepseek-v4-flash",
            slug: "deepseek-v4-flash",
            name: "DeepSeek V4 Flash 0731",
            description: "DeepSeek-V4-Flash-0731 through the direct DeepSeek Responses API",
            contextWindow: 1_000_000,
            maxOutputTokens: 384_000,
            apiBackend: .responses,
            supportsBackendSearch: true
        ),
    ]

    /// DeepSeek's documented Responses effort menu is low/high/max.
    public static let reasoningEfforts: [ReasoningEffortOption] = [
        ReasoningEffortOption(
            id: ReasoningEffort.low.rawValue,
            value: .low,
            label: "Low",
            description: "Faster responses with lighter reasoning",
            isDefault: false
        ),
        ReasoningEffortOption(
            id: ReasoningEffort.high.rawValue,
            value: .high,
            label: "High",
            description: "DeepSeek's default reasoning level",
            isDefault: true
        ),
        ReasoningEffortOption(
            id: ReasoningEffort.max.rawValue,
            value: .max,
            label: "Max",
            description: "Maximum reasoning depth for difficult tasks",
            isDefault: false
        ),
    ]

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "api.deepseek.com"
    }

    public static func apiBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = trimmedBaseURL(environment[apiBaseURLEnv]) {
            return override
        }
        return apiBaseURLDefault
    }

    public static func environmentAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        nonEmpty(environment[apiKeyEnv])
    }

    /// A stored provider key may only travel to DeepSeek-owned hosts. An
    /// environment key is the user's explicit per-invocation choice and always
    /// wins, including against an untrusted base URL override.
    public static func selectAPIKey(
        baseURL: String,
        environmentKey: String?,
        storedKey: String?
    ) -> String? {
        if let environmentKey = nonEmpty(environmentKey) { return environmentKey }
        guard isTrustedAPIBaseURL(baseURL) else { return nil }
        return nonEmpty(storedKey)
    }

    public static func curatedEntry(
        _ curated: CuratedDeepSeekModel,
        baseURL: String
    ) -> ModelEntry {
        var info = ModelInfo.fallback(slug: curated.key)
        info.id = curated.key
        info.model = curated.slug
        info.baseURL = trimTrailingSlashes(baseURL)
        info.name = curated.name
        info.description = curated.description
        info.maxCompletionTokens = curated.maxOutputTokens
        info.apiBackend = curated.apiBackend
        info.provider = .deepseek
        info.toolMode = .direct
        info.contextWindow = max(1, curated.contextWindow)
        info.supportsReasoningEffort = true
        info.reasoningEfforts = reasoningEfforts
        info.reasoningEffort = .high
        info.supportsBackendSearch = curated.supportsBackendSearch
        info.supportedInApi = true
        return ModelEntry(
            info: info,
            envKey: .single(apiKeyEnv)
        )
    }

    public static func curatedCatalog(baseURL: String? = nil) -> OrderedModelMap {
        let base = baseURL ?? apiBaseURL()
        var map = OrderedModelMap()
        for curated in Self.curated {
            map[curated.key] = curatedEntry(curated, baseURL: base)
        }
        return map
    }

    /// Restrict a DeepSeek `/models` response to the curated partition. Ids the
    /// provider no longer serves drop out; ids not curated here never enter.
    public static func parseAvailableSlugs(_ data: Data) throws -> Set<String> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else {
            throw ModelsError.remoteMalformed("deepseek /models missing data array")
        }
        let curatedSlugs = Set(Self.curated.map(\.slug))
        var out: Set<String> = []
        for obj in arr {
            guard let id = (obj["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                curatedSlugs.contains(id)
            else { continue }
            out.insert(id)
        }
        return out
    }
}

/// Provider-isolated DeepSeek catalog snapshot.
public struct DeepSeekModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var credentialFingerprint: String

    public init(entries: OrderedModelMap, credentialFingerprint: String) {
        self.entries = entries
        self.credentialFingerprint = credentialFingerprint
    }

    public var isAuthoritative: Bool { !entries.isEmpty }
}

// MARK: - Shared helpers

func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return value
}

func trimTrailingSlashes(_ value: String) -> String {
    var out = Substring(value)
    while out.hasSuffix("/") { out = out.dropLast() }
    return String(out)
}

func trimmedBaseURL(_ value: String?) -> String? {
    guard let value = nonEmpty(value) else { return nil }
    return nonEmpty(trimTrailingSlashes(value))
}
