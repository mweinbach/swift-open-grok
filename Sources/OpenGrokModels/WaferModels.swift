// WaferModels.swift
//
// Provider-isolated Wafer AI model discovery.
// Port of `crates/codegen/xai-grok-shell/src/wafer_models.rs`.
//
// Wafer exposes an OpenAI-compatible Chat Completions API. Its `/models`
// response is authoritative, so the catalog contains only model ids returned
// by Wafer and never invents a static model list.

import Foundation
import OpenGrokSamplingTypes

public enum WaferModels {
    public static let apiBaseURLDefault = "https://pass.wafer.ai/v1"
    public static let apiBaseURLEnv = "OPENGROK_WAFER_API_BASE_URL"
    public static let apiKeyEnv = "WAFER_API_KEY"

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "pass.wafer.ai"
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

    /// A stored Wafer key may only travel to Wafer-owned hosts.
    public static func selectAPIKey(
        baseURL: String,
        environmentKey: String?,
        storedKey: String?
    ) -> String? {
        if let environmentKey = nonEmpty(environmentKey) { return environmentKey }
        guard isTrustedAPIBaseURL(baseURL) else { return nil }
        return nonEmpty(storedKey)
    }

    /// Catalog key for a Wafer model id. The `wafer:` prefix keeps the
    /// partition disjoint from every other provider's key space.
    public static func catalogKey(modelID: String) -> String {
        "wafer:\(modelID)"
    }

    public static func modelEntry(modelID: String, baseURL: String) -> ModelEntry {
        let key = catalogKey(modelID: modelID)
        var info = ModelInfo.fallback(slug: key)
        info.id = key
        info.model = modelID
        info.baseURL = trimTrailingSlashes(baseURL)
        info.name = modelID
        info.apiBackend = .chatCompletions
        info.provider = .wafer
        info.toolMode = .direct
        info.supportsReasoningEffort = false
        info.reasoningEfforts = []
        info.reasoningEffort = nil
        // Upstream also sets `supports_standalone_web_search = Some(false)`.
        // `ModelInfo` has no such field in this port yet; `supportsBackendSearch`
        // already denies Wafer hosted search, which is the load-bearing half.
        info.supportsBackendSearch = false
        info.supportedInApi = true
        return ModelEntry(
            info: info,
            envKey: .single(apiKeyEnv)
        )
    }

    /// Parse a Wafer `/models` response into an ordered catalog. Wafer returns
    /// ids only, and the response is authoritative: no curated list backfills
    /// models the provider did not name.
    public static func parseCatalog(_ data: Data, baseURL: String) throws -> OrderedModelMap {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelsError.remoteMalformed("wafer /models response was not an object")
        }
        // `data` defaults to empty upstream rather than failing the request.
        let arr = root["data"] as? [[String: Any]] ?? []
        var map = OrderedModelMap()
        for obj in arr {
            guard let id = nonEmpty(obj["id"] as? String) else { continue }
            map[catalogKey(modelID: id)] = modelEntry(modelID: id, baseURL: baseURL)
        }
        return map
    }

    /// Redact the provider key and collapse newlines before an error body is
    /// surfaced or logged.
    public static func safeErrorExcerpt(_ body: String, apiKey: String) -> String {
        let sanitized = body
            .replacingOccurrences(of: apiKey, with: "[REDACTED]")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(sanitized.prefix(512))
    }
}

/// Provider-isolated Wafer catalog snapshot.
///
/// Wafer's remote response is always authoritative for its own partition, so
/// an empty snapshot means "Wafer serves no models", not "fall back".
public struct WaferModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var credentialFingerprint: String

    public init(entries: OrderedModelMap, credentialFingerprint: String) {
        self.entries = entries
        self.credentialFingerprint = credentialFingerprint
    }

    public var isAuthoritative: Bool { true }

    /// A cached catalog is reusable only under the credential that produced it.
    public func matchesCredential(fingerprint: String) -> Bool {
        credentialFingerprint == fingerprint
    }
}
