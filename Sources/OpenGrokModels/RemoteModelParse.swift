// RemoteModelParse.swift
//
// Parse OpenAI-compatible / cli-chat-proxy `/v1/models` entries into
// `ModelEntryConfig`. Unknown fields are ignored; required fields fail the
// single entry without failing the whole list.

import Foundation
import OpenGrokConfigTypes
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

    let subagentContextValue = firstNonNull(
        value["subagentContextDefault"],
        value["subagent_context_default"],
        meta?["subagentContextDefault"],
        meta?["subagent_context_default"]
    )
    let subagentContextDefault = (subagentContextValue as? String)
        .flatMap(ModelSubagentContextMode.init(wireValue:))

    let envKey = envKeysField(value, "envKey") ?? envKeysField(value, "env_key")
    let hidden = boolField(value, "hidden")
        ?? meta.flatMap({ boolField($0, "hidden") })
        ?? false
    let supportedInApi = boolField(value, "supportedInApi")
        ?? boolField(value, "supported_in_api")
        ?? meta.flatMap({ boolField($0, "supportedInApi") })
        ?? true
    let reasoningEffort = WireCodec.reasoningEffort(
        stringField(value, "reasoningEffort")
            ?? stringField(value, "reasoning_effort")
            ?? meta.flatMap({ stringField($0, "reasoningEffort") })
    )
    let reasoningEfforts = reasoningEffortOptionsField(firstPresent(
        value["reasoningEfforts"],
        value["reasoning_efforts"],
        meta?["reasoningEfforts"]
    ))
    let compactionsRemaining = compactionsRemainingField(firstPresent(
        value["compactionsRemaining"],
        value["compactions_remaining"],
        meta?["compactionsRemaining"]
    )) ?? jsonBoolean(firstPresent(
        value["sendCompactionsRemaining"],
        value["send_compactions_remaining"],
        meta?["sendCompactionsRemaining"]
    )).map(CompactionsRemaining.dynamic)
    let compactionAtTokens = compactionAtTokensField(firstPresent(
        value["compactionAtTokens"],
        value["compaction_at_tokens"],
        meta?["compactionAtTokens"]
    ))
    let lazinessDetector = lazinessDetectorField(
        objectField(value, "lazinessDetector")
            ?? objectField(value, "laziness_detector")
            ?? meta.flatMap({ objectField($0, "lazinessDetector") })
    )

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
        subagentContextDefault: subagentContextDefault,
        agentType: agentType,
        inferenceIdleTimeoutSecs: u64Field(value, "inferenceIdleTimeoutSecs")
            ?? u64Field(value, "inference_idle_timeout_secs"),
        maxRetries: u32Field(value, "maxRetries") ?? u32Field(value, "max_retries"),
        hidden: hidden,
        supportedInApi: supportedInApi,
        reasoningEffort: reasoningEffort,
        supportsReasoningEffort: jsonBoolean(firstPresent(
            value["supportsReasoningEffort"],
            value["supports_reasoning_effort"],
            meta?["supportsReasoningEffort"]
        )) ?? false,
        reasoningEfforts: reasoningEfforts,
        supportsReasoningSummaryParameter: false,
        defaultReasoningSummary: .none,
        supportsBackendSearch: jsonBoolean(firstPresent(
            value["supportsBackendSearch"],
            value["supports_backend_search"],
            meta?["supportsBackendSearch"]
        )) ?? false,
        supportsStandaloneWebSearch: jsonBoolean(firstPresent(
            value["supportsStandaloneWebSearch"],
            value["supports_standalone_web_search"],
            meta?["supportsStandaloneWebSearch"],
            meta?["supports_standalone_web_search"]
        )),
        compactionsRemaining: compactionsRemaining,
        compactionAtTokens: compactionAtTokens,
        showModelFingerprint: jsonBoolean(firstPresent(
            value["showModelFingerprint"],
            value["show_model_fingerprint"],
            meta?["showModelFingerprint"]
        )) ?? false,
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
            ?? [],
        lazinessDetector: lazinessDetector
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

private func objectField(_ obj: [String: Any], _ key: String) -> [String: Any]? {
    obj[key] as? [String: Any]
}

private func reasoningEffortOptionsField(_ value: Any?) -> [ReasoningEffortOption] {
    guard let values = value as? [Any] else { return [] }
    return values.compactMap { value in
        if let raw = value as? String, let effort = WireCodec.reasoningEffort(raw) {
            let id = effort.asString
            return ReasoningEffortOption(
                id: id,
                value: effort,
                label: id.prefix(1).uppercased() + id.dropFirst(),
                description: nil,
                isDefault: false
            )
        }
        guard let object = value as? [String: Any],
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(ReasoningEffortOption.self, from: data)
    }
}

private func compactionsRemainingField(_ value: Any?) -> CompactionsRemaining? {
    guard let value else { return nil }
    if let enabled = jsonBoolean(value) { return .dynamic(enabled) }
    guard let count = unsignedJSONInteger(value), let bounded = UInt8(exactly: count) else {
        return nil
    }
    return .fixed(bounded)
}

private func compactionAtTokensField(_ value: Any?) -> CompactionAtTokens? {
    guard let value else { return nil }
    if let enabled = jsonBoolean(value) { return .enabled(enabled) }
    guard let count = unsignedJSONInteger(value) else { return nil }
    return .fixed(count)
}

private func jsonBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber else { return nil }
    let typeEncoding = String(cString: number.objCType)
    guard typeEncoding == "B" || typeEncoding == "c" else { return nil }
    return number.boolValue
}

private func unsignedJSONInteger(_ value: Any) -> UInt64? {
    guard let number = value as? NSNumber, jsonBoolean(number) == nil else { return nil }
    return UInt64(number.stringValue)
}

private func lazinessDetectorField(_ object: [String: Any]?) -> LazinessDetectorPerModelConfig {
    guard let object,
          JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let config = try? JSONDecoder().decode(LazinessDetectorPerModelConfig.self, from: data)
    else { return LazinessDetectorPerModelConfig() }
    return config
}

private func firstPresent(_ values: Any?...) -> Any? {
    for value in values {
        if let value { return value }
    }
    return nil
}

private func firstNonNull(_ values: Any?...) -> Any? {
    for v in values {
        if let v, !(v is NSNull) { return v }
    }
    return nil
}
