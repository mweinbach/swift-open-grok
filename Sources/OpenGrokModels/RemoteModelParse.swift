// RemoteModelParse.swift
//
// Parse OpenAI-compatible / cli-chat-proxy `/v1/models` entries into
// `ModelEntryConfig`. Unknown fields are ignored; required fields fail the
// single entry without failing the whole list.

import Foundation
import OpenGrokSamplingTypes

/// Credential for `/v1/models` fetching.
public enum ModelFetchAuth: String, Sendable, Equatable, Hashable {
    case session
    case apiKey
    case deployment
    case customEndpoint

    /// custom_endpoint > session > deployment > API key.
    public static func resolve(
        endpoints: EndpointsConfig,
        hasCachedSession: Bool,
        hasXaiApiKeyEnv: Bool
    ) -> ModelFetchAuth {
        if endpoints.hasCustomEndpoint() { return .customEndpoint }
        if hasCachedSession { return .session }
        if endpoints.deploymentKey != nil { return .deployment }
        if hasXaiApiKeyEnv { return .apiKey }
        return .session
    }

    public func cacheAuthMethod() -> CacheAuthMethod {
        switch self {
        case .customEndpoint, .apiKey: return .apiKey
        case .session: return .session
        case .deployment: return .deployment
        }
    }
}

/// Fetch result: model entries + optional etag.
public struct FetchModelsResult: Sendable, Equatable {
    public var models: [ModelEntryConfig]
    public var etag: String?

    public init(models: [ModelEntryConfig], etag: String?) {
        self.models = models
        self.etag = etag
    }
}

/// The `/v1/models` URL for this endpoints/auth shape (also the cache origin).
public func modelsListURL(
    endpoints: EndpointsConfig,
    fetchAuth: ModelFetchAuth
) -> String {
    if endpoints.hasCustomEndpoint() {
        return endpoints.resolveModelsListURL()
    }
    if fetchAuth == .apiKey {
        return endpoints.xaiApiBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models"
    }
    return endpoints.resolveModelsListURL()
}

/// Parse a models list JSON body (`{ "data": [ ... ] }`).
public func parseModelsListResponse(
    _ data: Data,
    defaultBaseURL: String
) throws -> [ModelEntryConfig] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = root["data"] as? [[String: Any]] else {
        throw ModelsError.remoteMalformed("models response missing data array")
    }
    return arr.compactMap { parseRemoteModelValue($0, defaultBaseURL: defaultBaseURL) }
}

/// Parse a single model entry from the /models response.
public func parseRemoteModelValue(
    _ value: [String: Any],
    defaultBaseURL: String
) -> ModelEntryConfig? {
    let meta = value["_meta"] as? [String: Any]
    let id = stringField(value, "id")
    guard let model = stringField(value, "model")
            ?? stringField(value, "modelId")
            ?? id
            ?? meta.flatMap({ stringField($0, "model") })
            ?? meta.flatMap({ stringField($0, "modelId") }) else {
        return nil
    }
    let baseURL = stringField(value, "baseUrl")
        ?? stringField(value, "base_url")
        ?? defaultBaseURL
    let name = stringField(value, "name") ?? model
    let contextWindow = u64Field(value, "contextWindow")
        ?? u64Field(value, "context_window")
        ?? meta.flatMap({ u64Field($0, "contextWindow") })
        ?? meta.flatMap({ u64Field($0, "totalContextTokens") })
        ?? DEFAULT_CONTEXT_WINDOW
    guard contextWindow > 0 else { return nil }

    let agentType = stringField(value, "systemPromptType")
        ?? stringField(value, "system_prompt_type")
        ?? stringField(value, "agent_type")
        ?? stringField(value, "agentType")
        ?? meta.flatMap({ stringField($0, "agentType") })
        ?? meta.flatMap({ stringField($0, "agent_type") })
        ?? DEFAULT_AGENT_TYPE

    let apiBackend: ApiBackend
    if let raw = stringField(value, "apiBackend") ?? stringField(value, "api_backend") {
        guard let decoded = WireCodec.apiBackend(raw) else { return nil }
        apiBackend = decoded
    } else {
        apiBackend = .defaultValue
    }

    let providerRaw = stringField(value, "provider")
        ?? stringField(value, "modelProvider")
        ?? stringField(value, "model_provider")
        ?? meta.flatMap({ stringField($0, "provider") })
    let provider: ModelProvider
    if let providerRaw {
        guard let encoded = try? JSONEncoder().encode(providerRaw),
              let decoded = try? JSONDecoder().decode(ModelProvider.self, from: encoded)
        else { return nil }
        provider = decoded
    } else {
        provider = .defaultValue
    }

    // Null-as-absent at every precedence level for tool_mode.
    let toolModeValue = firstNonNull(
        value["toolMode"],
        value["tool_mode"],
        meta?["toolMode"],
        meta?["tool_mode"]
    )
    let toolMode: ToolMode?
    if let toolModeValue {
        guard let raw = toolModeValue as? String,
              let decoded = WireCodec.toolMode(raw)
        else { return nil }
        toolMode = decoded
    } else {
        toolMode = nil
    }

    let envKey = envKeysField(value, "envKey") ?? envKeysField(value, "env_key")
    let hidden = boolField(value, "hidden")
        ?? meta.flatMap({ boolField($0, "hidden") })
        ?? false
    let supportedInApi = boolField(value, "supportedInApi")
        ?? boolField(value, "supported_in_api")
        ?? meta.flatMap({ boolField($0, "supportedInApi") })
        ?? true

    return ModelEntryConfig(
        id: id,
        model: model,
        baseURL: baseURL,
        apiBaseURL: stringField(value, "apiBaseUrl") ?? stringField(value, "api_base_url"),
        name: name,
        description: stringField(value, "description"),
        contextWindow: contextWindow,
        temperature: floatField(value, "temperature"),
        topP: floatField(value, "topP") ?? floatField(value, "top_p"),
        maxCompletionTokens: u32Field(value, "maxCompletionTokens")
            ?? u32Field(value, "max_completion_tokens"),
        apiBackend: apiBackend,
        provider: provider,
        envKey: envKey,
        apiKey: stringField(value, "apiKey") ?? stringField(value, "api_key"),
        toolMode: toolMode,
        agentType: agentType,
        inferenceIdleTimeoutSecs: u64Field(value, "inferenceIdleTimeoutSecs")
            ?? u64Field(value, "inference_idle_timeout_secs"),
        maxRetries: u32Field(value, "maxRetries") ?? u32Field(value, "max_retries"),
        hidden: hidden,
        supportedInApi: supportedInApi,
        reasoningEffort: WireCodec.reasoningEffort(
            stringField(value, "reasoningEffort") ?? stringField(value, "reasoning_effort")
        ),
        supportsReasoningEffort: boolField(value, "supportsReasoningEffort")
            ?? boolField(value, "supports_reasoning_effort")
            ?? false,
        supportsBackendSearch: boolField(value, "supportsBackendSearch")
            ?? boolField(value, "supports_backend_search")
            ?? false,
        showModelFingerprint: boolField(value, "showModelFingerprint")
            ?? boolField(value, "show_model_fingerprint")
            ?? false,
        autoCompactThresholdPercent: u8Field(value, "autoCompactThresholdPercent")
            ?? u8Field(value, "auto_compact_threshold_percent"),
        systemPromptLabel: stringField(value, "systemPromptLabel")
            ?? stringField(value, "system_prompt_label"),
        streamToolCalls: boolField(value, "streamToolCalls")
            ?? boolField(value, "stream_tool_calls"),
        useConcise: boolField(value, "useConcise")
            ?? boolField(value, "use_concise")
            ?? false,
        extraHeaders: stringMapField(value, "extraHeaders")
            ?? stringMapField(value, "extra_headers")
            ?? []
    )
}

// MARK: - Field helpers

private func stringField(_ obj: [String: Any], _ key: String) -> String? {
    obj[key] as? String
}

private func boolField(_ obj: [String: Any], _ key: String) -> Bool? {
    obj[key] as? Bool
}

private func u64Field(_ obj: [String: Any], _ key: String) -> UInt64? {
    (obj[key] as? NSNumber)?.uint64Value
}

private func u32Field(_ obj: [String: Any], _ key: String) -> UInt32? {
    guard let n = (obj[key] as? NSNumber)?.uint64Value, n <= UInt64(UInt32.max) else {
        return nil
    }
    return UInt32(n)
}

private func u8Field(_ obj: [String: Any], _ key: String) -> UInt8? {
    guard let n = (obj[key] as? NSNumber)?.uint64Value, n <= UInt64(UInt8.max) else {
        return nil
    }
    return UInt8(n)
}

private func floatField(_ obj: [String: Any], _ key: String) -> Float? {
    (obj[key] as? NSNumber)?.floatValue
}

private func envKeysField(_ obj: [String: Any], _ key: String) -> EnvKeys? {
    if let s = obj[key] as? String { return .one(s) }
    if let arr = obj[key] as? [String] { return .many(arr) }
    return nil
}

private func stringMapField(_ obj: [String: Any], _ key: String) -> [(String, String)]? {
    guard let map = obj[key] as? [String: String] else { return nil }
    return map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
}

private func firstNonNull(_ values: Any?...) -> Any? {
    for v in values {
        if let v, !(v is NSNull) { return v }
    }
    return nil
}
