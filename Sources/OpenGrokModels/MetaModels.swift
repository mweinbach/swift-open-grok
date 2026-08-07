// MetaModels.swift
//
// Provider-isolated Meta Model API discovery.
// Port of `crates/codegen/xai-grok-shell/src/meta_models.rs`.
//
// Meta serves an OpenAI-compatible, stateless Responses API. The provider's
// `/models` endpoint is authoritative for the curated Muse Spark partition;
// unknown future model ids fail closed until their limits and capabilities
// are reviewed here.

import Foundation
import OpenGrokSamplingTypes

public struct CuratedMetaModel: Sendable, Equatable {
    public let key: String
    public let slug: String
    public let name: String
    public let description: String

    public init(key: String, slug: String, name: String, description: String) {
        self.key = key
        self.slug = slug
        self.name = name
        self.description = description
    }
}

public enum MetaModels {
    public static let apiBaseURLDefault = "https://api.meta.ai/v1"
    public static let apiBaseURLEnv = "OPENGROK_META_API_BASE_URL"
    public static let apiKeyEnv = "META_API_KEY"

    /// Every Muse Spark model shares the Responses backend, a 1M-token
    /// context window, hosted web search, and the same effort menu
    /// (`meta_models.rs:98-121`), so unlike DeepSeek the curated rows carry
    /// identity only.
    public static let curated: [CuratedMetaModel] = [
        CuratedMetaModel(
            key: "meta:muse-spark-1.2",
            slug: "muse-spark-1.2",
            name: "Muse Spark 1.2",
            description: "Meta's Muse Spark 1.2 agentic reasoning model"
        ),
        CuratedMetaModel(
            key: "meta:muse-spark-1.1",
            slug: "muse-spark-1.1",
            name: "Muse Spark 1.1",
            description: "Meta's Muse Spark 1.1 multimodal reasoning model"
        ),
        CuratedMetaModel(
            key: "meta:muse-spark-1.2-contributor",
            slug: "muse-spark-1.2-contributor",
            name: "Muse Spark 1.2 Contributor",
            description: "Meta's contributor-tuned Muse Spark 1.2 model"
        ),
    ]

    /// Meta's documented Responses effort menu is low/medium/high/xhigh with
    /// medium as the default (`meta_models.rs:227-266`).
    public static let reasoningEfforts: [ReasoningEffortOption] = [
        ReasoningEffortOption(
            id: ReasoningEffort.low.rawValue,
            value: .low,
            label: "Low",
            description: "Faster responses with lighter reasoning",
            isDefault: false
        ),
        ReasoningEffortOption(
            id: ReasoningEffort.medium.rawValue,
            value: .medium,
            label: "Medium",
            description: "Balanced reasoning depth for everyday tasks",
            isDefault: true
        ),
        ReasoningEffortOption(
            id: ReasoningEffort.high.rawValue,
            value: .high,
            label: "High",
            description: "Greater reasoning depth for complex problems",
            isDefault: false
        ),
        ReasoningEffortOption(
            id: ReasoningEffort.xhigh.rawValue,
            value: .xhigh,
            label: "XHigh",
            description: "Extra-high reasoning depth for difficult tasks",
            isDefault: false
        ),
    ]

    /// `is_trusted_api_base_url` (`meta_models.rs:48-53`): https and the
    /// exact host `api.meta.ai`, nothing broader.
    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "api.meta.ai"
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

    /// A stored provider key may only travel to Meta-owned hosts. An
    /// environment key is the user's explicit per-invocation choice and always
    /// wins, including against an untrusted base URL override
    /// (`select_api_key`, `meta_models.rs:78-88`).
    public static func selectAPIKey(
        baseURL: String,
        environmentKey: String?,
        storedKey: String?
    ) -> String? {
        if let environmentKey = nonEmpty(environmentKey) { return environmentKey }
        guard isTrustedAPIBaseURL(baseURL) else { return nil }
        return nonEmpty(storedKey)
    }

    /// `curated_model_entry` (`meta_models.rs:98-121`).
    public static func curatedEntry(
        _ curated: CuratedMetaModel,
        baseURL: String
    ) -> ModelEntry {
        var info = ModelInfo.fallback(slug: curated.key)
        info.id = curated.key
        info.model = curated.slug
        info.baseURL = trimTrailingSlashes(baseURL)
        info.name = curated.name
        info.description = curated.description
        info.apiBackend = .responses
        info.provider = .meta
        info.toolMode = .direct
        info.contextWindow = 1_000_000
        info.supportsReasoningEffort = true
        info.reasoningEfforts = reasoningEfforts
        info.reasoningEffort = .medium
        info.supportsBackendSearch = true
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

    /// Restrict a Meta `/models` response to the curated partition. Ids the
    /// provider no longer serves drop out; ids not curated here never enter
    /// (`catalog_from_wire`, `meta_models.rs:203-224`).
    public static func parseAvailableSlugs(_ data: Data) throws -> Set<String> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelsError.remoteMalformed("meta /models response was not an object")
        }
        // A missing `data` array is an empty catalog, not a hard failure
        // (`#[serde(default)]`, `meta_models.rs:275-279`); a present but
        // malformed element fails the whole decode exactly as serde does.
        guard let rawData = root["data"] else { return [] }
        guard let arr = rawData as? [[String: Any]] else {
            throw ModelsError.remoteMalformed("meta /models `data` was not an array of objects")
        }
        let curatedSlugs = Set(Self.curated.map(\.slug))
        var out: Set<String> = []
        for obj in arr {
            guard let id = obj["id"] as? String else {
                throw ModelsError.remoteMalformed("meta /models entry missing `id`")
            }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard curatedSlugs.contains(trimmed) else { continue }
            out.insert(trimmed)
        }
        return out
    }
}

/// Provider-isolated Meta catalog snapshot.
///
/// Unlike Wafer, an empty snapshot is *not* authoritative
/// (`meta_models.rs:134-136`): a key whose `/models` names no curated slug
/// leaves the embedded Meta entries in place rather than wiping them.
public struct MetaModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var credentialFingerprint: String

    public init(entries: OrderedModelMap, credentialFingerprint: String) {
        self.entries = entries
        self.credentialFingerprint = credentialFingerprint
    }

    public var isAuthoritative: Bool { !entries.isEmpty }
}
