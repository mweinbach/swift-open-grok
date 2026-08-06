// ModelTypes.swift
//
// Port of `ModelInfo`, `ModelEntry`, `ModelEntryConfig`, and
// `ConfigModelOverride` from `xai-grok-shell/src/agent/config.rs`.
//
// These are pure data + merge/apply helpers. Network I/O, auth storage, and
// the sampler actor live outside this module.

import Foundation
import OpenGrokConfigTypes
import OpenGrokSamplingTypes

// MARK: - Constants

/// Default agent type when the server/user config omits one.
public let DEFAULT_AGENT_TYPE = "grok-build-plan"

/// Context window used when a remote entry omits one (256k).
public let DEFAULT_CONTEXT_WINDOW: UInt64 = 256_000

/// Fallback context window for a brand-new config-only model (200k).
public let NEW_MODEL_DEFAULT_CONTEXT_WINDOW: UInt64 = 200_000

// MARK: - ModelInfo

/// Shared model metadata — the common fields across all model sources.
public struct ModelInfo: Sendable, Equatable, Codable {
    /// Stable unique identifier for this catalog entry. Falls back to `model`.
    public var id: String?
    /// Routing slug sent in API requests.
    public var model: String
    /// Session endpoint base URL.
    public var baseURL: String
    public var name: String?
    public var description: String?
    public var maxCompletionTokens: UInt32?
    public var temperature: Float?
    public var topP: Float?
    public var apiBackend: ApiBackend
    public var provider: ModelProvider
    public var toolMode: ToolMode?
    public var codexMultiAgentV2: Bool
    public var authScheme: AuthScheme
    /// Insertion-ordered extra headers.
    public var extraHeaders: [(String, String)]
    public var contextWindow: UInt64
    public var autoCompactThresholdPercent: UInt8?
    public var systemPromptLabel: String?
    public var useConcise: Bool
    public var agentType: String
    public var inferenceIdleTimeoutSecs: UInt64?
    public var maxRetries: UInt32?
    public var hidden: Bool
    /// Derived from `allowed_models`; never persisted.
    public var userSelectable: Bool
    public var supportedInApi: Bool
    public var reasoningEffort: ReasoningEffort?
    public var supportsReasoningEffort: Bool
    public var reasoningEfforts: [ReasoningEffortOption]
    public var supportsReasoningSummaryParameter: Bool
    public var defaultReasoningSummary: ReasoningSummary
    public var supportsBackendSearch: Bool
    public var compactionsRemaining: CompactionsRemaining?
    public var compactionAtTokens: CompactionAtTokens?
    public var showModelFingerprint: Bool
    public var streamToolCalls: Bool?
    public var lazinessDetector: LazinessDetectorPerModelConfig

    public init(
        id: String? = nil,
        model: String,
        baseURL: String = "",
        name: String? = nil,
        description: String? = nil,
        maxCompletionTokens: UInt32? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        apiBackend: ApiBackend = .defaultValue,
        provider: ModelProvider = .defaultValue,
        toolMode: ToolMode? = nil,
        codexMultiAgentV2: Bool = false,
        authScheme: AuthScheme = .defaultValue,
        extraHeaders: [(String, String)] = [],
        contextWindow: UInt64 = NEW_MODEL_DEFAULT_CONTEXT_WINDOW,
        autoCompactThresholdPercent: UInt8? = nil,
        systemPromptLabel: String? = nil,
        useConcise: Bool = false,
        agentType: String = DEFAULT_AGENT_TYPE,
        inferenceIdleTimeoutSecs: UInt64? = nil,
        maxRetries: UInt32? = nil,
        hidden: Bool = false,
        userSelectable: Bool = true,
        supportedInApi: Bool = true,
        reasoningEffort: ReasoningEffort? = nil,
        supportsReasoningEffort: Bool = false,
        reasoningEfforts: [ReasoningEffortOption] = [],
        supportsReasoningSummaryParameter: Bool = true,
        defaultReasoningSummary: ReasoningSummary = .none,
        supportsBackendSearch: Bool = false,
        compactionsRemaining: CompactionsRemaining? = nil,
        compactionAtTokens: CompactionAtTokens? = nil,
        showModelFingerprint: Bool = false,
        streamToolCalls: Bool? = nil,
        lazinessDetector: LazinessDetectorPerModelConfig = LazinessDetectorPerModelConfig()
    ) {
        self.id = id
        self.model = model
        self.baseURL = baseURL
        self.name = name
        self.description = description
        self.maxCompletionTokens = maxCompletionTokens
        self.temperature = temperature
        self.topP = topP
        self.apiBackend = apiBackend
        self.provider = provider
        self.toolMode = toolMode
        self.codexMultiAgentV2 = codexMultiAgentV2
        self.authScheme = authScheme
        self.extraHeaders = extraHeaders
        self.contextWindow = max(1, contextWindow)
        self.autoCompactThresholdPercent = autoCompactThresholdPercent
        self.systemPromptLabel = systemPromptLabel
        self.useConcise = useConcise
        self.agentType = agentType
        self.inferenceIdleTimeoutSecs = inferenceIdleTimeoutSecs
        self.maxRetries = maxRetries
        self.hidden = hidden
        self.userSelectable = userSelectable
        self.supportedInApi = supportedInApi
        self.reasoningEffort = reasoningEffort
        self.supportsReasoningEffort = supportsReasoningEffort
        self.reasoningEfforts = reasoningEfforts
        self.supportsReasoningSummaryParameter = supportsReasoningSummaryParameter
        self.defaultReasoningSummary = defaultReasoningSummary
        self.supportsBackendSearch = supportsBackendSearch
        self.compactionsRemaining = compactionsRemaining
        self.compactionAtTokens = compactionAtTokens
        self.showModelFingerprint = showModelFingerprint
        self.streamToolCalls = streamToolCalls
        self.lazinessDetector = lazinessDetector
    }

    /// Minimal fallback descriptor for an unknown model slug.
    public static func fallback(slug: String) -> ModelInfo {
        ModelInfo(
            model: slug,
            baseURL: "",
            supportsReasoningSummaryParameter: false,
            defaultReasoningSummary: .none
        )
    }

    /// Derive legacy effort gate/default from `reasoningEfforts`.
    public mutating func deriveReasoningEffortFields() {
        guard !reasoningEfforts.isEmpty else { return }
        supportsReasoningEffort = true
        if reasoningEffort == nil {
            reasoningEffort = reasoningEfforts.first(where: { $0.isDefault })?.value
                ?? reasoningEfforts.first?.value
        }
    }

    /// Picker visibility for a single-auth-mode catalog (xAI-only legacy path).
    public func visibleForAuth(isSessionAuth: Bool) -> Bool {
        !hidden && (isSessionAuth || supportedInApi)
    }

    /// Provider-aware picker visibility. One provider's OAuth must never unlock
    /// or hide another provider's models.
    public func visibleForProviderAuth(hasXaiSession: Bool, hasCodexSession: Bool) -> Bool {
        let hasProviderSession: Bool
        switch provider.profile.sessionAuth {
        case .apiKeyOnly: hasProviderSession = false
        case .xaiSession: hasProviderSession = hasXaiSession
        case .codexOAuth: hasProviderSession = hasCodexSession
        }
        return !hidden && (hasProviderSession || supportedInApi)
    }

    // MARK: Codable

    public enum CodingKeys: String, CodingKey {
        case id, model, name, description, provider, hidden
        case baseURL = "base_url"
        case maxCompletionTokens = "max_completion_tokens"
        case temperature
        case topP = "top_p"
        case apiBackend = "api_backend"
        case toolMode = "tool_mode"
        case codexMultiAgentV2 = "codex_multi_agent_v2"
        case authScheme = "auth_scheme"
        case extraHeaders = "extra_headers"
        case contextWindow = "context_window"
        case autoCompactThresholdPercent = "auto_compact_threshold_percent"
        case systemPromptLabel = "system_prompt_label"
        case useConcise = "use_concise"
        case agentType = "agent_type"
        case inferenceIdleTimeoutSecs = "inference_idle_timeout_secs"
        case maxRetries = "max_retries"
        case supportedInApi = "supported_in_api"
        case reasoningEffort = "reasoning_effort"
        case supportsReasoningEffort = "supports_reasoning_effort"
        case reasoningEfforts = "reasoning_efforts"
        case supportsReasoningSummaryParameter = "supports_reasoning_summary_parameter"
        case defaultReasoningSummary = "default_reasoning_summary"
        case supportsBackendSearch = "supports_backend_search"
        case compactionsRemaining = "compactions_remaining"
        case compactionAtTokens = "compaction_at_tokens"
        case showModelFingerprint = "show_model_fingerprint"
        case streamToolCalls = "stream_tool_calls"
        case lazinessDetector = "laziness_detector"
        // user_selectable is skip_serializing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        model = try c.decode(String.self, forKey: .model)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        maxCompletionTokens = try c.decodeIfPresent(UInt32.self, forKey: .maxCompletionTokens)
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature)
        topP = try c.decodeIfPresent(Float.self, forKey: .topP)
        if let raw = try c.decodeIfPresent(String.self, forKey: .apiBackend) {
            apiBackend = WireCodec.apiBackend(raw) ?? .defaultValue
        } else {
            apiBackend = .defaultValue
        }
        provider = try c.decodeIfPresent(ModelProvider.self, forKey: .provider) ?? .defaultValue
        if let raw = try c.decodeIfPresent(String.self, forKey: .toolMode) {
            toolMode = WireCodec.toolMode(raw)
        } else {
            toolMode = nil
        }
        codexMultiAgentV2 = try c.decodeIfPresent(Bool.self, forKey: .codexMultiAgentV2) ?? false
        if let raw = try c.decodeIfPresent(String.self, forKey: .authScheme) {
            authScheme = WireCodec.authScheme(raw) ?? .defaultValue
        } else {
            authScheme = .defaultValue
        }
        if let headers = try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) {
            extraHeaders = headers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else {
            extraHeaders = []
        }
        let cw = try c.decodeIfPresent(UInt64.self, forKey: .contextWindow) ?? NEW_MODEL_DEFAULT_CONTEXT_WINDOW
        contextWindow = max(1, cw)
        autoCompactThresholdPercent = try c.decodeIfPresent(UInt8.self, forKey: .autoCompactThresholdPercent)
        systemPromptLabel = try c.decodeIfPresent(String.self, forKey: .systemPromptLabel)
        useConcise = try c.decodeIfPresent(Bool.self, forKey: .useConcise) ?? false
        agentType = try c.decodeIfPresent(String.self, forKey: .agentType) ?? DEFAULT_AGENT_TYPE
        inferenceIdleTimeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .inferenceIdleTimeoutSecs)
        maxRetries = try c.decodeIfPresent(UInt32.self, forKey: .maxRetries)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        userSelectable = true
        supportedInApi = try c.decodeIfPresent(Bool.self, forKey: .supportedInApi) ?? true
        if let raw = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) {
            reasoningEffort = WireCodec.reasoningEffort(raw)
        } else {
            reasoningEffort = nil
        }
        supportsReasoningEffort = try c.decodeIfPresent(Bool.self, forKey: .supportsReasoningEffort) ?? false
        reasoningEfforts = try c.decodeIfPresent([ReasoningEffortOption].self, forKey: .reasoningEfforts) ?? []
        supportsReasoningSummaryParameter =
            try c.decodeIfPresent(Bool.self, forKey: .supportsReasoningSummaryParameter) ?? true
        if let raw = try c.decodeIfPresent(String.self, forKey: .defaultReasoningSummary) {
            defaultReasoningSummary = WireCodec.reasoningSummary(raw) ?? .none
        } else {
            defaultReasoningSummary = .none
        }
        supportsBackendSearch = try c.decodeIfPresent(Bool.self, forKey: .supportsBackendSearch) ?? false
        compactionsRemaining = try c.decodeIfPresent(CompactionsRemaining.self, forKey: .compactionsRemaining)
        compactionAtTokens = try c.decodeIfPresent(CompactionAtTokens.self, forKey: .compactionAtTokens)
        showModelFingerprint = try c.decodeIfPresent(Bool.self, forKey: .showModelFingerprint) ?? false
        streamToolCalls = try c.decodeIfPresent(Bool.self, forKey: .streamToolCalls)
        lazinessDetector =
            try c.decodeIfPresent(LazinessDetectorPerModelConfig.self, forKey: .lazinessDetector)
            ?? LazinessDetectorPerModelConfig()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(model, forKey: .model)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(maxCompletionTokens, forKey: .maxCompletionTokens)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encode(WireCodec.apiBackendWire(apiBackend), forKey: .apiBackend)
        try c.encode(provider, forKey: .provider)
        if let toolMode {
            try c.encode(WireCodec.toolModeWire(toolMode), forKey: .toolMode)
        }
        if codexMultiAgentV2 { try c.encode(true, forKey: .codexMultiAgentV2) }
        try c.encode(authScheme, forKey: .authScheme)
        if !extraHeaders.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: extraHeaders), forKey: .extraHeaders)
        }
        try c.encode(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(autoCompactThresholdPercent, forKey: .autoCompactThresholdPercent)
        try c.encodeIfPresent(systemPromptLabel, forKey: .systemPromptLabel)
        if useConcise { try c.encode(true, forKey: .useConcise) }
        try c.encode(agentType, forKey: .agentType)
        try c.encodeIfPresent(inferenceIdleTimeoutSecs, forKey: .inferenceIdleTimeoutSecs)
        try c.encodeIfPresent(maxRetries, forKey: .maxRetries)
        if hidden { try c.encode(true, forKey: .hidden) }
        try c.encode(supportedInApi, forKey: .supportedInApi)
        if let reasoningEffort {
            try c.encode(reasoningEffort.asString, forKey: .reasoningEffort)
        }
        try c.encode(supportsReasoningEffort, forKey: .supportsReasoningEffort)
        if !reasoningEfforts.isEmpty {
            try c.encode(reasoningEfforts, forKey: .reasoningEfforts)
        }
        try c.encode(supportsReasoningSummaryParameter, forKey: .supportsReasoningSummaryParameter)
        try c.encode(defaultReasoningSummary.rawValue, forKey: .defaultReasoningSummary)
        try c.encode(supportsBackendSearch, forKey: .supportsBackendSearch)
        try c.encodeIfPresent(compactionsRemaining, forKey: .compactionsRemaining)
        try c.encodeIfPresent(compactionAtTokens, forKey: .compactionAtTokens)
        if showModelFingerprint { try c.encode(true, forKey: .showModelFingerprint) }
        try c.encodeIfPresent(streamToolCalls, forKey: .streamToolCalls)
        try c.encode(lazinessDetector, forKey: .lazinessDetector)
    }

    public static func == (lhs: ModelInfo, rhs: ModelInfo) -> Bool {
        lhs.id == rhs.id
            && lhs.model == rhs.model
            && lhs.baseURL == rhs.baseURL
            && lhs.name == rhs.name
            && lhs.description == rhs.description
            && lhs.maxCompletionTokens == rhs.maxCompletionTokens
            && lhs.temperature == rhs.temperature
            && lhs.topP == rhs.topP
            && lhs.apiBackend == rhs.apiBackend
            && lhs.provider == rhs.provider
            && lhs.toolMode == rhs.toolMode
            && lhs.codexMultiAgentV2 == rhs.codexMultiAgentV2
            && lhs.authScheme == rhs.authScheme
            && lhs.extraHeaders.map(\.0) == rhs.extraHeaders.map(\.0)
            && lhs.extraHeaders.map(\.1) == rhs.extraHeaders.map(\.1)
            && lhs.contextWindow == rhs.contextWindow
            && lhs.autoCompactThresholdPercent == rhs.autoCompactThresholdPercent
            && lhs.systemPromptLabel == rhs.systemPromptLabel
            && lhs.useConcise == rhs.useConcise
            && lhs.agentType == rhs.agentType
            && lhs.inferenceIdleTimeoutSecs == rhs.inferenceIdleTimeoutSecs
            && lhs.maxRetries == rhs.maxRetries
            && lhs.hidden == rhs.hidden
            && lhs.userSelectable == rhs.userSelectable
            && lhs.supportedInApi == rhs.supportedInApi
            && lhs.reasoningEffort == rhs.reasoningEffort
            && lhs.supportsReasoningEffort == rhs.supportsReasoningEffort
            && lhs.reasoningEfforts == rhs.reasoningEfforts
            && lhs.supportsReasoningSummaryParameter == rhs.supportsReasoningSummaryParameter
            && lhs.defaultReasoningSummary == rhs.defaultReasoningSummary
            && lhs.supportsBackendSearch == rhs.supportsBackendSearch
            && lhs.compactionsRemaining == rhs.compactionsRemaining
            && lhs.compactionAtTokens == rhs.compactionAtTokens
            && lhs.showModelFingerprint == rhs.showModelFingerprint
            && lhs.streamToolCalls == rhs.streamToolCalls
            && lhs.lazinessDetector == rhs.lazinessDetector
    }
}

// MARK: - ModelEntry

/// Flat catalog entry: shared metadata plus credential/endpoint fields.
public struct ModelEntry: Sendable, Equatable, Codable {
    public var info: ModelInfo
    public var apiKey: String?
    public var envKey: EnvKeys?
    /// When set, `baseURL` is used for session auth, `apiBaseURL` for API-key auth.
    public var apiBaseURL: String?
    public var authProvider: String?
    public var queryParams: [String: String]
    public var envHTTPHeaders: [String: String]

    public init(
        info: ModelInfo,
        apiKey: String? = nil,
        envKey: EnvKeys? = nil,
        apiBaseURL: String? = nil,
        authProvider: String? = nil,
        queryParams: [String: String] = [:],
        envHTTPHeaders: [String: String] = [:]
    ) {
        self.info = info
        self.apiKey = apiKey
        self.envKey = envKey
        self.apiBaseURL = apiBaseURL
        self.authProvider = authProvider
        self.queryParams = queryParams
        self.envHTTPHeaders = envHTTPHeaders
    }

    /// Convenience: routing slug.
    public var model: String { info.model }

    /// Minimal fallback entry for an unknown model slug.
    public static func fallback(slug: String, endpoints: EndpointsConfig) -> ModelEntry {
        var info = ModelInfo.fallback(slug: slug)
        info.baseURL = endpoints.resolveInferenceBaseURL()
        return ModelEntry(info: info)
    }

    public static func fromConfigEntry(_ entry: ModelEntryConfig) -> ModelEntry {
        ModelEntry(
            info: ModelInfo.fromConfig(entry),
            apiKey: entry.apiKey,
            envKey: entry.envKey,
            apiBaseURL: entry.apiBaseURL,
            authProvider: nil,
            queryParams: [:],
            envHTTPHeaders: [:]
        )
    }

    /// Non-empty `apiKey`, else first set non-empty `envKey` value.
    public func ownCredential(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        firstOwnCredential(apiKey: apiKey, envKey: envKey, environment: environment)
    }

    public func hasOwnCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        ownCredential(environment: environment) != nil
    }

    public enum CodingKeys: String, CodingKey {
        case info
        case apiKey = "api_key"
        case envKey = "env_key"
        case apiBaseURL = "api_base_url"
        case authProvider = "auth_provider"
        case queryParams = "query_params"
        case envHTTPHeaders = "env_http_headers"
        // Flattened encode path for disk cache: the Rust cache stores ModelEntry
        // as a flat struct via serde flatten-like layout of info + credential
        // fields. Our cache uses nested `info` for clarity and round-trips it.
    }
}

/// First usable BYOK credential: non-empty trimmed api_key, else first env_key.
public func firstOwnCredential(
    apiKey: String?,
    envKey: EnvKeys?,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
        return apiKey
    }
    return envKey?.resolveValue(environment: environment)
}

// MARK: - ModelEntryConfig

/// Flat config/catalog entry used when loading defaults and remote models.
public struct ModelEntryConfig: Sendable, Equatable {
    public var id: String?
    public var model: String
    public var baseURL: String
    public var apiBaseURL: String?
    public var name: String?
    public var description: String?
    public var contextWindow: UInt64
    public var temperature: Float?
    public var topP: Float?
    public var maxCompletionTokens: UInt32?
    public var apiBackend: ApiBackend
    public var provider: ModelProvider
    public var envKey: EnvKeys?
    public var apiKey: String?
    public var toolMode: ToolMode?
    public var multiAgentVersion: String?
    public var codexMultiAgentV2: Bool
    public var authScheme: AuthScheme?
    public var agentType: String
    public var inferenceIdleTimeoutSecs: UInt64?
    public var maxRetries: UInt32?
    public var hidden: Bool
    public var supportedInApi: Bool
    public var reasoningEffort: ReasoningEffort?
    public var supportsReasoningEffort: Bool
    public var reasoningEfforts: [ReasoningEffortOption]
    public var supportsReasoningSummaryParameter: Bool
    public var defaultReasoningSummary: ReasoningSummary
    public var supportsBackendSearch: Bool
    public var compactionsRemaining: CompactionsRemaining?
    public var compactionAtTokens: CompactionAtTokens?
    public var showModelFingerprint: Bool
    public var autoCompactThresholdPercent: UInt8?
    public var systemPromptLabel: String?
    public var streamToolCalls: Bool?
    public var useConcise: Bool
    public var extraHeaders: [(String, String)]
    public var lazinessDetector: LazinessDetectorPerModelConfig

    public init(
        id: String? = nil,
        model: String,
        baseURL: String,
        apiBaseURL: String? = nil,
        name: String? = nil,
        description: String? = nil,
        contextWindow: UInt64 = NEW_MODEL_DEFAULT_CONTEXT_WINDOW,
        temperature: Float? = nil,
        topP: Float? = nil,
        maxCompletionTokens: UInt32? = nil,
        apiBackend: ApiBackend = .defaultValue,
        provider: ModelProvider = .defaultValue,
        envKey: EnvKeys? = nil,
        apiKey: String? = nil,
        toolMode: ToolMode? = nil,
        multiAgentVersion: String? = nil,
        codexMultiAgentV2: Bool = false,
        authScheme: AuthScheme? = nil,
        agentType: String = DEFAULT_AGENT_TYPE,
        inferenceIdleTimeoutSecs: UInt64? = nil,
        maxRetries: UInt32? = nil,
        hidden: Bool = false,
        supportedInApi: Bool = true,
        reasoningEffort: ReasoningEffort? = nil,
        supportsReasoningEffort: Bool = false,
        reasoningEfforts: [ReasoningEffortOption] = [],
        supportsReasoningSummaryParameter: Bool = true,
        defaultReasoningSummary: ReasoningSummary = .none,
        supportsBackendSearch: Bool = false,
        compactionsRemaining: CompactionsRemaining? = nil,
        compactionAtTokens: CompactionAtTokens? = nil,
        showModelFingerprint: Bool = false,
        autoCompactThresholdPercent: UInt8? = nil,
        systemPromptLabel: String? = nil,
        streamToolCalls: Bool? = nil,
        useConcise: Bool = false,
        extraHeaders: [(String, String)] = [],
        lazinessDetector: LazinessDetectorPerModelConfig = LazinessDetectorPerModelConfig()
    ) {
        self.id = id
        self.model = model
        self.baseURL = baseURL
        self.apiBaseURL = apiBaseURL
        self.name = name
        self.description = description
        self.contextWindow = max(1, contextWindow)
        self.temperature = temperature
        self.topP = topP
        self.maxCompletionTokens = maxCompletionTokens
        self.apiBackend = apiBackend
        self.provider = provider
        self.envKey = envKey
        self.apiKey = apiKey
        self.toolMode = toolMode
        self.multiAgentVersion = multiAgentVersion
        self.codexMultiAgentV2 = codexMultiAgentV2
        self.authScheme = authScheme
        self.agentType = agentType
        self.inferenceIdleTimeoutSecs = inferenceIdleTimeoutSecs
        self.maxRetries = maxRetries
        self.hidden = hidden
        self.supportedInApi = supportedInApi
        self.reasoningEffort = reasoningEffort
        self.supportsReasoningEffort = supportsReasoningEffort
        self.reasoningEfforts = reasoningEfforts
        self.supportsReasoningSummaryParameter = supportsReasoningSummaryParameter
        self.defaultReasoningSummary = defaultReasoningSummary
        self.supportsBackendSearch = supportsBackendSearch
        self.compactionsRemaining = compactionsRemaining
        self.compactionAtTokens = compactionAtTokens
        self.showModelFingerprint = showModelFingerprint
        self.autoCompactThresholdPercent = autoCompactThresholdPercent
        self.systemPromptLabel = systemPromptLabel
        self.streamToolCalls = streamToolCalls
        self.useConcise = useConcise
        self.extraHeaders = extraHeaders
        self.lazinessDetector = lazinessDetector
    }
}

extension ModelInfo {
    public static func fromConfig(_ entry: ModelEntryConfig) -> ModelInfo {
        ModelInfo(
            id: entry.id,
            model: entry.model,
            baseURL: entry.baseURL,
            name: entry.name,
            description: entry.description,
            maxCompletionTokens: entry.maxCompletionTokens,
            temperature: entry.temperature,
            topP: entry.topP,
            apiBackend: entry.apiBackend,
            provider: entry.provider,
            toolMode: entry.toolMode,
            codexMultiAgentV2: entry.codexMultiAgentV2,
            authScheme: entry.authScheme ?? .defaultValue,
            extraHeaders: entry.extraHeaders,
            contextWindow: entry.contextWindow,
            autoCompactThresholdPercent: entry.autoCompactThresholdPercent,
            systemPromptLabel: entry.systemPromptLabel,
            useConcise: entry.useConcise,
            agentType: entry.agentType,
            inferenceIdleTimeoutSecs: entry.inferenceIdleTimeoutSecs,
            maxRetries: entry.maxRetries,
            hidden: entry.hidden,
            userSelectable: true,
            supportedInApi: entry.supportedInApi,
            reasoningEffort: entry.reasoningEffort,
            supportsReasoningEffort: entry.supportsReasoningEffort,
            reasoningEfforts: entry.reasoningEfforts,
            supportsReasoningSummaryParameter: entry.supportsReasoningSummaryParameter,
            defaultReasoningSummary: entry.defaultReasoningSummary,
            supportsBackendSearch: entry.supportsBackendSearch,
            compactionsRemaining: entry.compactionsRemaining,
            compactionAtTokens: entry.compactionAtTokens,
            showModelFingerprint: entry.showModelFingerprint,
            streamToolCalls: entry.streamToolCalls,
            lazinessDetector: entry.lazinessDetector
        )
    }
}

// MARK: - ConfigModelOverride

/// A `[model.foo]` entry from config: Option fields mean "inherit".
public struct ConfigModelOverride: Sendable, Equatable {
    public var model: String?
    public var baseURL: String?
    public var name: String?
    public var description: String?
    public var apiKey: String?
    public var envKey: EnvKeys?
    public var apiBaseURL: String?
    public var modelProvider: String?
    public var authProvider: String?
    public var queryParams: [(String, String)]
    public var envHTTPHeaders: [(String, String)]
    public var maxCompletionTokens: UInt32?
    public var temperature: Float?
    public var topP: Float?
    public var apiBackend: ApiBackend?
    public var provider: ModelProvider?
    public var authScheme: AuthScheme?
    public var toolMode: ToolMode?
    public var extraHeaders: [(String, String)]
    public var contextWindow: UInt64?
    public var autoCompactThresholdPercent: UInt8?
    public var systemPromptLabel: String?
    public var useConcise: Bool?
    public var agentType: String?
    public var inferenceIdleTimeoutSecs: UInt64?
    public var maxRetries: UInt32?
    public var hidden: Bool?
    public var supportedInApi: Bool?
    public var reasoningEffort: ReasoningEffort?
    public var supportsReasoningEffort: Bool?
    public var reasoningEfforts: [ReasoningEffortOption]
    public var supportsReasoningSummaryParameter: Bool?
    public var defaultReasoningSummary: ReasoningSummary?
    public var supportsBackendSearch: Bool?
    public var compactionsRemaining: CompactionsRemaining?
    public var compactionAtTokens: CompactionAtTokens?
    public var showModelFingerprint: Bool?
    public var streamToolCalls: Bool?

    public init(
        model: String? = nil,
        baseURL: String? = nil,
        name: String? = nil,
        description: String? = nil,
        apiKey: String? = nil,
        envKey: EnvKeys? = nil,
        apiBaseURL: String? = nil,
        modelProvider: String? = nil,
        authProvider: String? = nil,
        queryParams: [(String, String)] = [],
        envHTTPHeaders: [(String, String)] = [],
        maxCompletionTokens: UInt32? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        apiBackend: ApiBackend? = nil,
        provider: ModelProvider? = nil,
        authScheme: AuthScheme? = nil,
        toolMode: ToolMode? = nil,
        extraHeaders: [(String, String)] = [],
        contextWindow: UInt64? = nil,
        autoCompactThresholdPercent: UInt8? = nil,
        systemPromptLabel: String? = nil,
        useConcise: Bool? = nil,
        agentType: String? = nil,
        inferenceIdleTimeoutSecs: UInt64? = nil,
        maxRetries: UInt32? = nil,
        hidden: Bool? = nil,
        supportedInApi: Bool? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        supportsReasoningEffort: Bool? = nil,
        reasoningEfforts: [ReasoningEffortOption] = [],
        supportsReasoningSummaryParameter: Bool? = nil,
        defaultReasoningSummary: ReasoningSummary? = nil,
        supportsBackendSearch: Bool? = nil,
        compactionsRemaining: CompactionsRemaining? = nil,
        compactionAtTokens: CompactionAtTokens? = nil,
        showModelFingerprint: Bool? = nil,
        streamToolCalls: Bool? = nil
    ) {
        self.model = model
        self.baseURL = baseURL
        self.name = name
        self.description = description
        self.apiKey = apiKey
        self.envKey = envKey
        self.apiBaseURL = apiBaseURL
        self.modelProvider = modelProvider
        self.authProvider = authProvider
        self.queryParams = queryParams
        self.envHTTPHeaders = envHTTPHeaders
        self.maxCompletionTokens = maxCompletionTokens
        self.temperature = temperature
        self.topP = topP
        self.apiBackend = apiBackend
        self.provider = provider
        self.authScheme = authScheme
        self.toolMode = toolMode
        self.extraHeaders = extraHeaders
        self.contextWindow = contextWindow
        self.autoCompactThresholdPercent = autoCompactThresholdPercent
        self.systemPromptLabel = systemPromptLabel
        self.useConcise = useConcise
        self.agentType = agentType
        self.inferenceIdleTimeoutSecs = inferenceIdleTimeoutSecs
        self.maxRetries = maxRetries
        self.hidden = hidden
        self.supportedInApi = supportedInApi
        self.reasoningEffort = reasoningEffort
        self.supportsReasoningEffort = supportsReasoningEffort
        self.reasoningEfforts = reasoningEfforts
        self.supportsReasoningSummaryParameter = supportsReasoningSummaryParameter
        self.defaultReasoningSummary = defaultReasoningSummary
        self.supportsBackendSearch = supportsBackendSearch
        self.compactionsRemaining = compactionsRemaining
        self.compactionAtTokens = compactionAtTokens
        self.showModelFingerprint = showModelFingerprint
        self.streamToolCalls = streamToolCalls
    }

    /// Apply this override onto an optional base entry (mirrors Rust `apply`).
    public func apply(
        key: String,
        base: ModelEntry?,
        endpoints: EndpointsConfig
    ) -> ModelEntry {
        let hadBase = base != nil
        let inheritedProvider = base?.info.provider
        var entry = base ?? ModelEntry.fallback(slug: key, endpoints: endpoints)

        if let v = model { entry.info.model = v }
        if let v = baseURL {
            entry.info.baseURL = v
            if apiBaseURL == nil { entry.apiBaseURL = nil }
        }
        if name != nil { entry.info.name = name }
        if description != nil { entry.info.description = description }
        if maxCompletionTokens != nil { entry.info.maxCompletionTokens = maxCompletionTokens }
        if temperature != nil { entry.info.temperature = temperature }
        if topP != nil { entry.info.topP = topP }

        let providerChanged = provider.map { $0 != entry.info.provider } ?? false
        if let v = provider { entry.info.provider = v }

        if providerChanged {
            // Catalog capabilities are provider-local.
            switch entry.info.provider {
            case .codex:
                entry.info.apiBackend = .responses
            case .xai, .kimi, .fireworks, .deepseek, .openCodeGo, .wafer:
                entry.info.apiBackend = .chatCompletions
            }
            if baseURL == nil { entry.info.baseURL = "" }
            entry.info.toolMode = nil
            entry.info.codexMultiAgentV2 = false
            entry.info.authScheme = .defaultValue
            entry.info.extraHeaders = []
            entry.info.agentType = entry.info.provider == .codex ? "codex" : DEFAULT_AGENT_TYPE
            entry.info.supportsBackendSearch = false
            entry.info.reasoningEffort = nil
            entry.info.supportsReasoningEffort = false
            entry.info.reasoningEfforts = []
            let supportsSummary = entry.info.provider == .codex
            entry.info.supportsReasoningSummaryParameter = supportsSummary
            entry.info.defaultReasoningSummary = supportsSummary ? .detailed : .none
            entry.info.compactionsRemaining = nil
            entry.info.compactionAtTokens = nil
            entry.info.showModelFingerprint = false
            entry.info.streamToolCalls = nil
            entry.apiKey = nil
            entry.envKey = nil
            entry.apiBaseURL = nil
        }

        if let v = apiBackend { entry.info.apiBackend = v }
        if let v = authScheme { entry.info.authScheme = v }

        if baseURL == nil,
           entry.info.provider.profile.sessionAuth.isApiKeyOnly,
           !hadBase || inheritedProvider != entry.info.provider {
            entry.info.baseURL = ""
        }

        if let v = toolMode { entry.info.toolMode = v }
        if !extraHeaders.isEmpty { entry.info.extraHeaders = extraHeaders }
        if let cw = contextWindow, cw > 0 { entry.info.contextWindow = cw }
        if let v = useConcise { entry.info.useConcise = v }
        if let v = agentType { entry.info.agentType = v }
        if inferenceIdleTimeoutSecs != nil {
            entry.info.inferenceIdleTimeoutSecs = inferenceIdleTimeoutSecs
        }
        if maxRetries != nil { entry.info.maxRetries = maxRetries }
        if let v = hidden { entry.info.hidden = v }
        if let v = supportedInApi { entry.info.supportedInApi = v }
        if reasoningEffort != nil { entry.info.reasoningEffort = reasoningEffort }
        if let v = supportsReasoningEffort {
            entry.info.supportsReasoningEffort = v
        } else if !entry.info.supportsReasoningEffort, entry.info.apiBackend == .messages {
            entry.info.supportsReasoningEffort = true
        }
        if !reasoningEfforts.isEmpty { entry.info.reasoningEfforts = reasoningEfforts }
        if let v = supportsReasoningSummaryParameter {
            entry.info.supportsReasoningSummaryParameter = v
        }
        if let v = defaultReasoningSummary {
            entry.info.defaultReasoningSummary = v
        }
        if let v = supportsBackendSearch { entry.info.supportsBackendSearch = v }
        if compactionsRemaining != nil {
            entry.info.compactionsRemaining = compactionsRemaining
        }
        if compactionAtTokens != nil {
            entry.info.compactionAtTokens = compactionAtTokens
        }
        if let v = showModelFingerprint { entry.info.showModelFingerprint = v }
        if streamToolCalls != nil { entry.info.streamToolCalls = streamToolCalls }
        if apiKey != nil { entry.apiKey = apiKey }
        if envKey != nil { entry.envKey = envKey }
        if apiBaseURL != nil { entry.apiBaseURL = apiBaseURL }
        if authProvider != nil { entry.authProvider = authProvider }
        if !queryParams.isEmpty { entry.queryParams = Dictionary(uniqueKeysWithValues: queryParams) }
        if !envHTTPHeaders.isEmpty { entry.envHTTPHeaders = Dictionary(uniqueKeysWithValues: envHTTPHeaders) }
        if supportedInApi == nil, apiKey != nil || envKey != nil {
            entry.info.supportedInApi = true
        }
        return entry
    }
}

// MARK: - Explicit equality for insertion-ordered tuple fields

func equalStringPairs(_ lhs: [(String, String)], _ rhs: [(String, String)]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

extension ModelEntryConfig {
    public static func == (lhs: ModelEntryConfig, rhs: ModelEntryConfig) -> Bool {
        lhs.id == rhs.id && lhs.model == rhs.model && lhs.baseURL == rhs.baseURL &&
        lhs.apiBaseURL == rhs.apiBaseURL && lhs.name == rhs.name &&
        lhs.description == rhs.description && lhs.contextWindow == rhs.contextWindow &&
        lhs.temperature == rhs.temperature && lhs.topP == rhs.topP &&
        lhs.maxCompletionTokens == rhs.maxCompletionTokens && lhs.apiBackend == rhs.apiBackend &&
        lhs.provider == rhs.provider && lhs.envKey == rhs.envKey && lhs.apiKey == rhs.apiKey &&
        lhs.toolMode == rhs.toolMode && lhs.multiAgentVersion == rhs.multiAgentVersion &&
        lhs.codexMultiAgentV2 == rhs.codexMultiAgentV2 && lhs.authScheme == rhs.authScheme &&
        lhs.agentType == rhs.agentType && lhs.inferenceIdleTimeoutSecs == rhs.inferenceIdleTimeoutSecs &&
        lhs.maxRetries == rhs.maxRetries && lhs.hidden == rhs.hidden &&
        lhs.supportedInApi == rhs.supportedInApi && lhs.reasoningEffort == rhs.reasoningEffort &&
        lhs.supportsReasoningEffort == rhs.supportsReasoningEffort &&
        lhs.reasoningEfforts == rhs.reasoningEfforts &&
        lhs.supportsReasoningSummaryParameter == rhs.supportsReasoningSummaryParameter &&
        lhs.defaultReasoningSummary == rhs.defaultReasoningSummary &&
        lhs.supportsBackendSearch == rhs.supportsBackendSearch &&
        lhs.compactionsRemaining == rhs.compactionsRemaining &&
        lhs.compactionAtTokens == rhs.compactionAtTokens &&
        lhs.showModelFingerprint == rhs.showModelFingerprint &&
        lhs.autoCompactThresholdPercent == rhs.autoCompactThresholdPercent &&
        lhs.systemPromptLabel == rhs.systemPromptLabel &&
        lhs.streamToolCalls == rhs.streamToolCalls && lhs.useConcise == rhs.useConcise &&
        equalStringPairs(lhs.extraHeaders, rhs.extraHeaders) &&
        lhs.lazinessDetector == rhs.lazinessDetector
    }
}

extension ConfigModelOverride {
    public static func == (lhs: ConfigModelOverride, rhs: ConfigModelOverride) -> Bool {
        lhs.model == rhs.model && lhs.baseURL == rhs.baseURL && lhs.name == rhs.name &&
        lhs.description == rhs.description && lhs.apiKey == rhs.apiKey && lhs.envKey == rhs.envKey &&
        lhs.apiBaseURL == rhs.apiBaseURL && lhs.maxCompletionTokens == rhs.maxCompletionTokens &&
        lhs.modelProvider == rhs.modelProvider && lhs.authProvider == rhs.authProvider &&
        equalStringPairs(lhs.queryParams, rhs.queryParams) &&
        equalStringPairs(lhs.envHTTPHeaders, rhs.envHTTPHeaders) &&
        lhs.temperature == rhs.temperature && lhs.topP == rhs.topP && lhs.apiBackend == rhs.apiBackend &&
        lhs.provider == rhs.provider && lhs.authScheme == rhs.authScheme && lhs.toolMode == rhs.toolMode &&
        equalStringPairs(lhs.extraHeaders, rhs.extraHeaders) && lhs.contextWindow == rhs.contextWindow &&
        lhs.autoCompactThresholdPercent == rhs.autoCompactThresholdPercent &&
        lhs.systemPromptLabel == rhs.systemPromptLabel && lhs.useConcise == rhs.useConcise &&
        lhs.agentType == rhs.agentType && lhs.inferenceIdleTimeoutSecs == rhs.inferenceIdleTimeoutSecs &&
        lhs.maxRetries == rhs.maxRetries && lhs.hidden == rhs.hidden &&
        lhs.supportedInApi == rhs.supportedInApi && lhs.reasoningEffort == rhs.reasoningEffort &&
        lhs.supportsReasoningEffort == rhs.supportsReasoningEffort &&
        lhs.reasoningEfforts == rhs.reasoningEfforts &&
        lhs.supportsReasoningSummaryParameter == rhs.supportsReasoningSummaryParameter &&
        lhs.defaultReasoningSummary == rhs.defaultReasoningSummary &&
        lhs.supportsBackendSearch == rhs.supportsBackendSearch &&
        lhs.compactionsRemaining == rhs.compactionsRemaining &&
        lhs.compactionAtTokens == rhs.compactionAtTokens &&
        lhs.showModelFingerprint == rhs.showModelFingerprint &&
        lhs.streamToolCalls == rhs.streamToolCalls
    }
}
