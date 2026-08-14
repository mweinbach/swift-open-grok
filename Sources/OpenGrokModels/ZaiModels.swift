// ZaiModels.swift
//
// Provider-isolated Z AI model discovery.
// Port of `crates/codegen/xai-grok-shell/src/zai_models.rs`.
//
// Z AI exposes an OpenAI-compatible Chat Completions API (GLM models). The
// default base URL targets the GLM Coding Plan endpoint; a standard API
// endpoint and any other host may be selected via the
// `OPENGROK_ZAI_API_BASE_URL` environment variable.
//
// The `/models` response is authoritative when available, so a successful
// query replaces the catalog with only the ids Z AI returned. When `/models`
// is unreachable or returns nothing, a curated static fallback list keeps
// the model picker populated.

import Foundation
import OpenGrokSamplingTypes

public enum ZaiModels {
    /// Default base URL: the GLM Coding Plan OpenAI-compatible endpoint.
    public static let apiBaseURLDefault = "https://api.z.ai/api/coding/paas/v4"
    public static let apiBaseURLEnv = "OPENGROK_ZAI_API_BASE_URL"
    public static let apiKeyEnv = "ZAI_API_KEY"

    /// Models known to support Z AI's "thinking mode" / reasoning.
    public static let knownReasoningModelPrefixes: [String] = [
        "glm-4.5", "glm-4.6", "glm-4.7", "glm-4-32b", "glm-5"
    ]

    /// Curated fallback model ids used when `/models` fails or returns nothing.
    public static let fallbackModelIDs: [String] = [
        "glm-5.2",
        "glm-5-turbo",
        "glm-5.1",
        "glm-5",
        "glm-4.7",
        "glm-4.6",
        "glm-4.5",
        "glm-4-32b-0414-128k",
    ]

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "api.z.ai"
    }

    public static func apiBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        trimmedBaseURL(environment[apiBaseURLEnv]) ?? apiBaseURLDefault
    }

    public static func environmentAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        nonEmpty(environment[apiKeyEnv])
    }

    /// A stored Z AI key may only travel to Z AI-owned hosts.
    public static func selectAPIKey(
        baseURL: String,
        environmentKey: String?,
        storedKey: String?
    ) -> String? {
        if let environmentKey = nonEmpty(environmentKey) { return environmentKey }
        guard isTrustedAPIBaseURL(baseURL) else { return nil }
        return nonEmpty(storedKey)
    }

    public static func isKnownReasoningModel(modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return knownReasoningModelPrefixes.contains { lower.hasPrefix($0) }
    }

    /// Effort menu for GLM reasoning models.
    public static func zaiReasoningEfforts() -> [ReasoningEffortOption] {
        [
            ReasoningEffortOption(
                id: ReasoningEffort.low.asString,
                value: .low,
                label: "Low",
                description: "Faster responses with lighter reasoning",
                isDefault: false
            ),
            ReasoningEffortOption(
                id: ReasoningEffort.medium.asString,
                value: .medium,
                label: "Medium",
                description: "Balanced reasoning for everyday coding",
                isDefault: false
            ),
            ReasoningEffortOption(
                id: ReasoningEffort.high.asString,
                value: .high,
                label: "High",
                description: "Z AI's recommended reasoning level for coding",
                isDefault: true
            ),
            ReasoningEffortOption(
                id: ReasoningEffort.max.asString,
                value: .max,
                label: "Max",
                description: "Maximum thinking depth for difficult tasks",
                isDefault: false
            ),
        ]
    }

    /// Catalog key for a Z AI model id.
    public static func catalogKey(modelID: String) -> String {
        "zai:\(modelID)"
    }

    public static func modelEntry(modelID: String, baseURL: String) -> ModelEntry {
        let key = catalogKey(modelID: modelID)
        var info = ModelInfo.fallback(slug: key)
        info.id = key
        info.model = modelID
        info.baseURL = trimTrailingSlashes(baseURL)
        info.name = modelID
        info.apiBackend = .chatCompletions
        info.provider = .zai
        info.toolMode = .direct
        if isKnownReasoningModel(modelID: modelID) {
            info.reasoningEfforts = zaiReasoningEfforts()
            info.supportsReasoningEffort = true
            info.reasoningEffort = .high
        } else {
            info.supportsReasoningEffort = false
            info.reasoningEffort = nil
            info.reasoningEfforts.removeAll()
        }
        info.supportsBackendSearch = false
        info.supportedInApi = true
        return ModelEntry(
            info: info,
            envKey: .single(apiKeyEnv)
        )
    }

    /// Curated fallback catalog used when `/models` is unavailable.
    public static func fallbackCatalog(baseURL: String) -> OrderedModelMap {
        var map = OrderedModelMap()
        for id in fallbackModelIDs {
            map[catalogKey(modelID: id)] = modelEntry(modelID: id, baseURL: baseURL)
        }
        return map
    }

    /// Parse a Z AI `/models` response into an ordered catalog.
    public static func parseCatalog(_ data: Data, baseURL: String) throws -> OrderedModelMap {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelsError.remoteMalformed("Z AI /models response was not an object")
        }
        let arr = root["data"] as? [[String: Any]] ?? []
        var map = OrderedModelMap()
        for obj in arr {
            guard let id = nonEmpty(obj["id"] as? String) else { continue }
            map[catalogKey(modelID: id)] = modelEntry(modelID: id, baseURL: baseURL)
        }
        return map.isEmpty ? fallbackCatalog(baseURL: baseURL) : map
    }

    /// Redact the provider key and collapse newlines before an error body is surfaced.
    public static func safeErrorExcerpt(_ body: String, apiKey: String) -> String {
        let sanitized = body
            .replacingOccurrences(of: apiKey, with: "[REDACTED]")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(sanitized.prefix(512))
    }
}

/// Provider-isolated Z AI catalog snapshot.
public struct ZaiModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var credentialFingerprint: String

    public init(entries: OrderedModelMap, credentialFingerprint: String) {
        self.entries = entries
        self.credentialFingerprint = credentialFingerprint
    }

    public var isAuthoritative: Bool { !entries.isEmpty }
}
