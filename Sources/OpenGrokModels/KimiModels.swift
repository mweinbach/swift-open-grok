// KimiModels.swift
//
// Provider-isolated Kimi model discovery helpers.
// Platform vs Code credentials and catalogs are non-interchangeable.

import Foundation
import OpenGrokSamplingTypes

public enum KimiModels {
    public static let platformAPIBaseURL = "https://api.moonshot.ai/v1"
    public static let codeAPIBaseURL = "https://api.kimi.com/coding/v1"
    public static let apiBaseURLEnv = "OPENGROK_KIMI_API_BASE_URL"
    public static let platformAPIKeyEnv = "MOONSHOT_API_KEY"
    public static let codeAPIKeyEnv = "KIMI_CODE_API_KEY"

    /// Only provider-owned hosts may receive the application-stored Kimi key.
    public static func endpoint(forBaseURL baseURL: String) -> KimiApiEndpoint? {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return nil
        }
        switch url.host?.lowercased() {
        case "api.moonshot.ai", "api.moonshot.cn":
            return .platform
        case "api.kimi.com", "api.kimi.ai":
            let path = url.path
            if path == "/coding/v1" || path.hasPrefix("/coding/v1/") {
                return .code
            }
            return nil
        default:
            return nil
        }
    }

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        endpoint(forBaseURL: baseURL) != nil
    }

    /// Whether `modelID` is a Kimi **Code** membership API slug (not Platform).
    ///
    /// `is_code_model_slug`
    /// (`crates/codegen/xai-grok-shell/src/kimi_models.rs:130`, new at pin
    /// 80dff0a9). Platform serves `kimi-k3` on Moonshot; Code serves `k3` /
    /// `k3-256k` plus the K2.7 `kimi-for-coding*` family. Deliberately
    /// slug-based rather than catalog-based, for rebind paths that see only a
    /// model id after the service partition has already been chosen — note
    /// `kimi-k3` is Platform and must not match.
    public static func isCodeModelSlug(_ modelID: String) -> Bool {
        modelID == "k3" || modelID == "k3-256k" || modelID.hasPrefix("kimi-for-coding")
    }

    public static func apiBaseURL(
        _ endpoint: KimiApiEndpoint,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment[apiBaseURLEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           !override.isEmpty {
            return override
        }
        return endpoint.baseURL
    }

    public static func effectiveEndpoint(
        _ configured: KimiApiEndpoint,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> KimiApiEndpoint {
        let base = apiBaseURL(configured, environment: environment)
        return endpoint(forBaseURL: base) ?? configured
    }

    /// Live discovery is enabled only for Platform; Code uses the embedded catalog.
    public static func liveDiscoveryEnabled(_ configured: KimiApiEndpoint) -> Bool {
        effectiveEndpoint(configured) == .platform
    }
}

/// Provider-isolated Kimi catalog snapshot. Must never be stored in the xAI
/// `models_cache.json`.
public struct KimiModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var endpoint: KimiApiEndpoint
    /// Non-secret credential fingerprint for publish races.
    public var credentialFingerprint: String

    public init(
        entries: OrderedModelMap,
        endpoint: KimiApiEndpoint,
        credentialFingerprint: String
    ) {
        self.entries = entries
        self.endpoint = endpoint
        self.credentialFingerprint = credentialFingerprint
    }

    public var isAuthoritative: Bool { !entries.isEmpty }
}

/// Parse an OpenAI-compatible `/models` list for Kimi Platform into entries.
/// Unknown or non-Kimi providers are rejected.
public func parseKimiModelsResponse(
    _ data: Data,
    baseURL: String,
    endpoint: KimiApiEndpoint
) throws -> OrderedModelMap {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = root["data"] as? [[String: Any]] else {
        throw ModelsError.remoteMalformed("kimi /models missing data array")
    }
    var map = OrderedModelMap()
    for obj in arr {
        let id = (obj["id"] as? String) ?? (obj["model"] as? String)
        guard let slug = id, !slug.isEmpty else { continue }
        var info = ModelInfo.fallback(slug: slug)
        info.id = slug
        info.model = slug
        info.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        info.name = (obj["name"] as? String) ?? slug
        info.apiBackend = .chatCompletions
        info.provider = .kimi
        info.toolMode = .direct
        info.supportedInApi = true
        if let cw = (obj["context_window"] as? NSNumber)?.uint64Value, cw > 0 {
            info.contextWindow = cw
        } else if let cw = (obj["context_length"] as? NSNumber)?.uint64Value, cw > 0 {
            info.contextWindow = cw
        }
        map[slug] = ModelEntry(
            info: info,
            envKey: .single(endpoint.apiKeyEnv)
        )
    }
    return map
}
