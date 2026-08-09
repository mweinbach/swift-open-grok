// FireworksModels.swift
//
// Provider-isolated Fireworks AI model discovery.
// The `/models` endpoint may enrich curated entries (context window) but can
// neither add nor remove models.

import Foundation
import OpenGrokSamplingTypes

public struct CuratedFireworksModel: Sendable, Equatable {
    public let key: String
    public let slug: String
    public let name: String
    public let description: String
    public let fallbackContextWindow: UInt64

    public init(
        key: String,
        slug: String,
        name: String,
        description: String,
        fallbackContextWindow: UInt64
    ) {
        self.key = key
        self.slug = slug
        self.name = name
        self.description = description
        self.fallbackContextWindow = fallbackContextWindow
    }
}

public enum FireworksModels {
    public static let apiBaseURLDefault = "https://api.fireworks.ai/inference/v1"
    public static let apiBaseURLEnv = "OPENGROK_FIREWORKS_API_BASE_URL"
    public static let apiKeyEnv = "FIREWORKS_API_KEY"

    public static let curated: [CuratedFireworksModel] = [
        CuratedFireworksModel(
            key: "glm-5.2",
            slug: "accounts/fireworks/models/glm-5p2",
            name: "GLM 5.2",
            description: "Zhipu's GLM 5.2 frontier model on Fireworks AI",
            fallbackContextWindow: 1_040_000
        ),
        CuratedFireworksModel(
            key: "glm-5.2-fast",
            slug: "accounts/fireworks/routers/glm-5p2-fast",
            name: "GLM 5.2 Fast",
            description: "GLM 5.2 on Fireworks AI's low-latency router",
            fallbackContextWindow: 1_040_000
        ),
        CuratedFireworksModel(
            key: "deepseek-v4-pro",
            slug: "accounts/fireworks/models/deepseek-v4-pro",
            name: "DeepSeek V4 Pro",
            description: "DeepSeek V4 Pro on Fireworks AI",
            fallbackContextWindow: 1_040_000
        ),
        CuratedFireworksModel(
            key: "kimi-k2.7-code",
            slug: "accounts/fireworks/models/kimi-k2p7-code",
            name: "Kimi K2.7 Code",
            description: "Moonshot's Kimi K2.7 coding model on Fireworks AI",
            fallbackContextWindow: 262_144
        ),
        CuratedFireworksModel(
            key: "fireworks:kimi-k3",
            slug: "accounts/fireworks/models/kimi-k3",
            name: "Kimi K3",
            description: "Moonshot's Kimi K3 flagship model on Fireworks AI",
            fallbackContextWindow: 1_040_000
        ),
        CuratedFireworksModel(
            key: "fireworks:kimi-k3-fast",
            slug: "accounts/fireworks/routers/kimi-k3-fast",
            name: "Kimi K3 Fast",
            description: "Kimi K3 on Fireworks AI's low-latency router",
            fallbackContextWindow: 1_040_000
        ),
    ]

    /// The effort menu every curated Fireworks entry offers: Low/Medium/High
    /// defaulting Medium, descriptions deliberately absent
    /// (`fireworks_reasoning_efforts()`, fireworks_models.rs:182-197).
    public static let reasoningEfforts: [ReasoningEffortOption] = [
        ReasoningEffortOption(
            id: ReasoningEffort.low.rawValue,
            value: .low,
            label: "Low",
            description: nil,
            isDefault: false
        ),
        ReasoningEffortOption(
            id: ReasoningEffort.medium.rawValue,
            value: .medium,
            label: "Medium",
            description: nil,
            isDefault: true
        ),
        ReasoningEffortOption(
            id: ReasoningEffort.high.rawValue,
            value: .high,
            label: "High",
            description: nil,
            isDefault: false
        ),
    ]

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "api.fireworks.ai"
    }

    public static func apiBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment[apiBaseURLEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           !override.isEmpty {
            return override
        }
        return apiBaseURLDefault
    }

    public static func curatedEntry(
        _ curated: CuratedFireworksModel,
        baseURL: String,
        contextWindow: UInt64?
    ) -> ModelEntry {
        var info = ModelInfo.fallback(slug: curated.key)
        info.id = curated.key
        info.model = curated.slug
        info.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        info.name = curated.name
        info.description = curated.description
        info.apiBackend = .chatCompletions
        info.provider = .fireworks
        info.toolMode = .direct
        info.contextWindow = max(1, contextWindow ?? curated.fallbackContextWindow)
        // Every curated entry carries the Low/Medium/High menu with Medium as
        // the default (fireworks_models.rs:164-166). The non-nil catalog
        // effort is ALSO what arms the sampler's Fireworks effort-restore
        // gate — set these to nil again and every curated Fireworks request
        // silently loses its `reasoning_effort` while the suite stays green
        // (the gate itself fails closed, EffortShapingTests pins it).
        info.supportsReasoningEffort = true
        info.reasoningEfforts = reasoningEfforts
        info.reasoningEffort = .medium
        // Every curated Fireworks model advertises the Fast / priority tier
        // (fireworks_models.rs:167-171); Fireworks chat requests forward
        // `service_tier` unchanged (provider.rs:1090-1102 pins this).
        info.serviceTiers = [ModelServiceTier(
            id: SERVICE_TIER_FAST_REQUEST_VALUE,
            name: "Fast",
            description: "Fireworks priority processing"
        )]
        info.supportedInApi = true
        return ModelEntry(
            info: info,
            envKey: .single(apiKeyEnv)
        )
    }

    /// Build curated catalog, optionally enriched by a `/models` slug → context map.
    public static func curatedCatalog(
        baseURL: String? = nil,
        contextBySlug: [String: UInt64] = [:]
    ) -> OrderedModelMap {
        let base = baseURL ?? apiBaseURL()
        var map = OrderedModelMap()
        for curated in Self.curated {
            let cw = contextBySlug[curated.slug]
            map[curated.key] = curatedEntry(curated, baseURL: base, contextWindow: cw)
        }
        return map
    }

    /// Parse a Fireworks `/models` response into a slug → context_window map.
    /// Entries that are not in the curated list are ignored (cannot add models).
    public static func parseContextEnrichment(_ data: Data) throws -> [String: UInt64] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else {
            throw ModelsError.remoteMalformed("fireworks /models missing data array")
        }
        let curatedSlugs = Set(Self.curated.map(\.slug))
        var out: [String: UInt64] = [:]
        for obj in arr {
            guard let id = obj["id"] as? String, curatedSlugs.contains(id) else { continue }
            if let cw = (obj["context_window"] as? NSNumber)?.uint64Value, cw > 0 {
                out[id] = cw
            } else if let cw = (obj["context_length"] as? NSNumber)?.uint64Value, cw > 0 {
                out[id] = cw
            }
        }
        return out
    }
}

/// Provider-isolated Fireworks catalog snapshot.
public struct FireworksModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var credentialFingerprint: String

    public init(entries: OrderedModelMap, credentialFingerprint: String) {
        self.entries = entries
        self.credentialFingerprint = credentialFingerprint
    }

    public var isAuthoritative: Bool { !entries.isEmpty }
}
