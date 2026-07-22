// DefaultModels.swift
//
// Port of `xai-grok-models` + the shell's `default_models` loader.
//
// At runtime each specialty model is resolved via:
//   CLI flag > ENV var > config.toml > remote settings > these defaults

import Foundation
import OpenGrokSamplingTypes

/// Specialty model role used for auxiliary tasks.
public enum SpecialtyModelRole: String, Sendable, Equatable, Hashable {
    case webSearch
    case imageDescription
    case sessionSummary
}

/// Parsed embedded default-models corpus.
public struct EmbeddedDefaultModels: Sendable, Equatable {
    public let `default`: String
    public let webSearch: String?
    public let imageDescription: String?
    public let sessionSummary: String?
    public let models: [DefaultModelJSON]
}

/// JSON-only subset of a default catalog entry.
public struct DefaultModelJSON: Sendable, Equatable {
    public var id: String?
    public var model: String
    public var baseURL: String?
    public var apiBaseURL: String?
    public var name: String?
    public var description: String?
    public var contextWindow: UInt64?
    public var temperature: Float?
    public var topP: Float?
    public var maxCompletionTokens: UInt32?
    public var apiBackend: ApiBackend
    public var provider: ModelProvider
    public var envKey: EnvKeys?
    public var toolMode: ToolMode?
    public var multiAgentVersion: String?
    public var agentType: String
    public var inferenceIdleTimeoutSecs: UInt64?
    public var hidden: Bool
    public var reasoningEffort: ReasoningEffort?
    public var supportsReasoningEffort: Bool
    public var reasoningEfforts: [ReasoningEffortOption]
    public var supportedInApi: Bool
    public var supportsBackendSearch: Bool
    public var compactionsRemaining: CompactionsRemaining?
    public var compactionAtTokens: CompactionAtTokens?
    public var showModelFingerprint: Bool
    public var autoCompactThresholdPercent: UInt8?
    public var systemPromptLabel: String?
}

// MARK: - Public accessors (mirror `xai_grok_models`)

/// Primary model for coding tasks and general fallback.
public func defaultModel() -> String {
    EmbeddedDefaults.shared.default
}

/// Model for web search tool synthesis. Falls back to default model.
public func defaultWebSearchModel() -> String {
    EmbeddedDefaults.shared.webSearch ?? EmbeddedDefaults.shared.default
}

/// Model for image describe. Falls back to default model.
public func defaultImageDescriptionModel() -> String {
    EmbeddedDefaults.shared.imageDescription ?? EmbeddedDefaults.shared.default
}

/// Model for session title generation. Falls back to default model.
public func defaultSessionSummaryModel() -> String {
    EmbeddedDefaults.shared.sessionSummary ?? EmbeddedDefaults.shared.default
}

/// Specialty model for a role, falling back to the primary default.
public func defaultModel(for role: SpecialtyModelRole) -> String {
    switch role {
    case .webSearch: return defaultWebSearchModel()
    case .imageDescription: return defaultImageDescriptionModel()
    case .sessionSummary: return defaultSessionSummaryModel()
    }
}

/// The full parsed embedded corpus.
public func embeddedDefaultModels() -> EmbeddedDefaultModels {
    EmbeddedDefaults.shared
}

// MARK: - Loader

enum EmbeddedDefaults {
    static let shared: EmbeddedDefaultModels = {
        do {
            return try parseEmbeddedDefaultModels(DEFAULT_MODELS_JSON)
        } catch {
            fatalError("default_models.json: invalid JSON: \(error)")
        }
    }()
}

/// Parse the embedded (or fixture) default-models JSON body.
public func parseEmbeddedDefaultModels(_ json: String) throws -> EmbeddedDefaultModels {
    guard let data = json.data(using: .utf8) else {
        throw ModelsError.invalidDefaultModels("not UTF-8")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ModelsError.invalidDefaultModels("root is not an object")
    }
    guard let defaultID = root["default"] as? String, !defaultID.isEmpty else {
        throw ModelsError.invalidDefaultModels("missing 'default' field")
    }
    let webSearch = root["web_search"] as? String
    let imageDescription = root["image_description"] as? String
    let sessionSummary = root["session_summary"] as? String
    guard let modelsArr = root["models"] as? [[String: Any]] else {
        throw ModelsError.invalidDefaultModels("missing 'models' array")
    }
    let models = try modelsArr.map { try parseDefaultModelJSON($0) }
    let modelIDs = Set(models.map(\.model))
    // Baked-in JSON — a mismatch is a developer error.
    precondition(
        modelIDs.contains(defaultID),
        "default_models.json: 'default' is '\(defaultID)' but models array has \(modelIDs)"
    )
    return EmbeddedDefaultModels(
        default: defaultID,
        webSearch: webSearch,
        imageDescription: imageDescription,
        sessionSummary: sessionSummary,
        models: models
    )
}

private func parseDefaultModelJSON(_ obj: [String: Any]) throws -> DefaultModelJSON {
    guard let model = obj["model"] as? String, !model.isEmpty else {
        throw ModelsError.invalidDefaultModels("entry missing non-empty 'model'")
    }
    let apiBackend = WireCodec.apiBackend(obj["api_backend"] as? String) ?? .defaultValue
    let provider: ModelProvider
    if let raw = obj["provider"] as? String {
        provider = (try? JSONDecoder().decode(
            ModelProvider.self,
            from: Data("\"\(raw)\"".utf8)
        )) ?? .defaultValue
    } else {
        provider = .defaultValue
    }
    let toolMode = WireCodec.toolMode(obj["tool_mode"] as? String)
    let envKey: EnvKeys?
    if let s = obj["env_key"] as? String {
        envKey = .one(s)
    } else if let arr = obj["env_key"] as? [String] {
        envKey = .many(arr)
    } else {
        envKey = nil
    }
    var reasoningEfforts: [ReasoningEffortOption] = []
    if let arr = obj["reasoning_efforts"] as? [[String: Any]] {
        for el in arr {
            guard let valueRaw = el["value"] as? String,
                  let value = WireCodec.reasoningEffort(valueRaw) else { continue }
            let id = (el["id"] as? String) ?? value.asString
            let label = (el["label"] as? String) ?? id
            let description = el["description"] as? String
            let isDefault = el["default"] as? Bool ?? false
            reasoningEfforts.append(
                ReasoningEffortOption(
                    id: id,
                    value: value,
                    label: label,
                    description: description,
                    isDefault: isDefault
                )
            )
        }
    }
    let reasoningEffort = WireCodec.reasoningEffort(obj["reasoning_effort"] as? String)
    let contextWindow: UInt64?
    if let n = obj["context_window"] as? NSNumber {
        contextWindow = n.uint64Value
    } else {
        contextWindow = nil
    }
    let maxCompletionTokens: UInt32?
    if let n = obj["max_completion_tokens"] as? NSNumber {
        maxCompletionTokens = n.uint32Value
    } else {
        maxCompletionTokens = nil
    }
    let temperature: Float?
    if let n = obj["temperature"] as? NSNumber {
        temperature = n.floatValue
    } else {
        temperature = nil
    }
    let topP: Float?
    if let n = obj["top_p"] as? NSNumber {
        topP = n.floatValue
    } else {
        topP = nil
    }
    let autoCompact: UInt8?
    if let n = obj["auto_compact_threshold_percent"] as? NSNumber {
        autoCompact = n.uint8Value
    } else {
        autoCompact = nil
    }
    let idleTimeout: UInt64?
    if let n = obj["inference_idle_timeout_secs"] as? NSNumber {
        idleTimeout = n.uint64Value
    } else {
        idleTimeout = nil
    }

    let compactionsRemaining: CompactionsRemaining?
    if let b = obj["compactions_remaining"] as? Bool {
        compactionsRemaining = .dynamic(b)
    } else if let n = obj["compactions_remaining"] as? NSNumber {
        compactionsRemaining = .fixed(n.uint8Value)
    } else {
        compactionsRemaining = nil
    }
    let compactionAtTokens: CompactionAtTokens?
    if let b = obj["compaction_at_tokens"] as? Bool {
        compactionAtTokens = .enabled(b)
    } else if let n = obj["compaction_at_tokens"] as? NSNumber {
        compactionAtTokens = .fixed(n.uint64Value)
    } else {
        compactionAtTokens = nil
    }

    return DefaultModelJSON(
        id: obj["id"] as? String,
        model: model,
        baseURL: obj["base_url"] as? String,
        apiBaseURL: obj["api_base_url"] as? String,
        name: obj["name"] as? String,
        description: obj["description"] as? String,
        contextWindow: contextWindow,
        temperature: temperature,
        topP: topP,
        maxCompletionTokens: maxCompletionTokens,
        apiBackend: apiBackend,
        provider: provider,
        envKey: envKey,
        toolMode: toolMode,
        multiAgentVersion: obj["multi_agent_version"] as? String,
        agentType: (obj["agent_type"] as? String) ?? DEFAULT_AGENT_TYPE,
        inferenceIdleTimeoutSecs: idleTimeout,
        hidden: obj["hidden"] as? Bool ?? false,
        reasoningEffort: reasoningEffort,
        supportsReasoningEffort: obj["supports_reasoning_effort"] as? Bool ?? false,
        reasoningEfforts: reasoningEfforts,
        supportedInApi: obj["supported_in_api"] as? Bool ?? true,
        supportsBackendSearch: obj["supports_backend_search"] as? Bool ?? false,
        compactionsRemaining: compactionsRemaining,
        compactionAtTokens: compactionAtTokens,
        showModelFingerprint: obj["show_model_fingerprint"] as? Bool ?? false,
        autoCompactThresholdPercent: autoCompact,
        systemPromptLabel: obj["system_prompt_label"] as? String
    )
}

/// Built-in default model entries, keyed by stable catalog id.
///
/// Prefer `resolveModelList` / `resolveModelCatalog` for the assembled catalog.
public func defaultModelEntries(
    endpoints: EndpointsConfig = .default,
    kimiEndpoint: KimiApiEndpoint = .platform
) -> OrderedModelMap {
    let configs = defaultModelConfigs(endpoints: endpoints, kimiEndpoint: kimiEndpoint)
    var map = OrderedModelMap()
    for (key, config) in configs {
        map[key] = ModelEntry.fromConfigEntry(config)
    }
    return map
}

/// Build `ModelEntryConfig` map from the embedded corpus.
public func defaultModelConfigs(
    endpoints: EndpointsConfig,
    kimiEndpoint: KimiApiEndpoint
) -> [(String, ModelEntryConfig)] {
    let embedded = EmbeddedDefaults.shared
    let effectiveKimi = KimiModels.effectiveEndpoint(kimiEndpoint)
    let kimiBaseURL = KimiModels.apiBaseURL(effectiveKimi)
    var out: [(String, ModelEntryConfig)] = []

    for var m in embedded.models {
        if m.provider == .kimi {
            let embeddedEndpoint = m.baseURL.flatMap { KimiModels.endpoint(forBaseURL: $0) }
            if embeddedEndpoint != effectiveKimi {
                continue
            }
            m.baseURL = kimiBaseURL
            m.envKey = .single(effectiveKimi.apiKeyEnv)
        }
        if m.provider == .fireworks {
            m.baseURL = FireworksModels.apiBaseURL()
            m.envKey = .single(FireworksModels.apiKeyEnv)
        }

        let key = m.id ?? m.model
        let contextWindow = m.contextWindow.map { max(1, $0) } ?? NEW_MODEL_DEFAULT_CONTEXT_WINDOW

        let (baseURL, apiBaseURL): (String, String?)
        switch m.provider.profile.sessionAuth {
        case .apiKeyOnly:
            guard let b = m.baseURL, !b.isEmpty else {
                fatalError("default_models.json: API-key-only model `\(m.model)` requires base_url")
            }
            baseURL = b
            apiBaseURL = m.apiBaseURL
        case .xaiSession:
            baseURL = m.baseURL ?? endpoints.resolveInferenceBaseURL()
            apiBaseURL = m.apiBaseURL ?? endpoints.xaiApiBaseURL
        case .codexOAuth:
            baseURL = m.baseURL ?? CodexModels.defaultInferenceBaseURL
            apiBaseURL = m.apiBaseURL
        }

        let config = ModelEntryConfig(
            id: m.id,
            model: m.model,
            baseURL: baseURL,
            apiBaseURL: apiBaseURL,
            name: m.name,
            description: m.description,
            contextWindow: contextWindow,
            temperature: m.temperature,
            topP: m.topP,
            maxCompletionTokens: m.maxCompletionTokens,
            apiBackend: m.apiBackend,
            provider: m.provider,
            envKey: m.envKey,
            toolMode: m.toolMode,
            multiAgentVersion: m.multiAgentVersion,
            codexMultiAgentV2: m.provider == .codex && m.multiAgentVersion == "v2",
            agentType: m.agentType,
            inferenceIdleTimeoutSecs: m.inferenceIdleTimeoutSecs,
            hidden: m.hidden,
            supportedInApi: m.supportedInApi,
            reasoningEffort: m.reasoningEffort,
            supportsReasoningEffort: m.supportsReasoningEffort,
            reasoningEfforts: m.reasoningEfforts,
            supportsReasoningSummaryParameter: m.provider == .codex,
            defaultReasoningSummary: m.provider == .codex ? .detailed : .none,
            supportsBackendSearch: m.supportsBackendSearch,
            compactionsRemaining: m.compactionsRemaining,
            compactionAtTokens: m.compactionAtTokens,
            showModelFingerprint: m.showModelFingerprint,
            autoCompactThresholdPercent: m.autoCompactThresholdPercent,
            systemPromptLabel: m.systemPromptLabel
        )
        out.append((key, config))
    }
    return out
}
