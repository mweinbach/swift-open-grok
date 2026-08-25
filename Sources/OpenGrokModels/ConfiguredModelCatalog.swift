// ConfiguredModelCatalog.swift
//
// Converts the trusted TOML provider tables into the catalog's existing
// `ConfigModelOverride` seam. This keeps OpenGrokModels independent of auth
// execution while preserving provider-default precedence.

import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes

private let unresolvedModelProviderPrefix = "__opengrok_unresolved_model_provider__:"

public struct ConfiguredModelCatalog: Sendable, Equatable {
    public var modelOverrides: [(String, ConfigModelOverride)]
    public var providerDefinitions: ParsedProviderDefinitions
    /// Invalid or unknown fields are reported without dropping valid siblings.
    public var warnings: [ConfigProviderWarning]

    public init(
        modelOverrides: [(String, ConfigModelOverride)] = [],
        providerDefinitions: ParsedProviderDefinitions = ParsedProviderDefinitions(),
        warnings: [ConfigProviderWarning] = []
    ) {
        self.modelOverrides = modelOverrides
        self.providerDefinitions = providerDefinitions
        self.warnings = warnings
    }

    public var authProviders: [(String, AuthProviderConfig)] {
        providerDefinitions.authProviders
    }
}

extension ConfiguredModelCatalog {
    public static func == (lhs: ConfiguredModelCatalog, rhs: ConfiguredModelCatalog) -> Bool {
        lhs.modelOverrides.count == rhs.modelOverrides.count &&
        zip(lhs.modelOverrides, rhs.modelOverrides).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } &&
        lhs.providerDefinitions == rhs.providerDefinitions &&
        lhs.warnings == rhs.warnings
    }
}

public func parseConfiguredModelCatalog(
    from document: TOMLValue,
    trustedProviderDefinitions: ParsedProviderDefinitions? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> ConfiguredModelCatalog {
    var definitions = trustedProviderDefinitions ?? parseProviderDefinitions(from: document)
    var warnings = definitions.warnings
    guard let modelSection = document["model"] else {
        return ConfiguredModelCatalog(providerDefinitions: definitions, warnings: warnings)
    }
    guard case let .table(models) = modelSection else {
        warnings.append(ConfigProviderWarning(
            section: "model",
            kind: .notATable,
            message: "model must be a table; all model overrides ignored"
        ))
        return ConfiguredModelCatalog(providerDefinitions: definitions, warnings: warnings)
    }

    var overrides: [(String, ConfigModelOverride)] = []
    for (name, value) in models.pairs {
        guard case let .table(table) = value else {
            warnings.append(ConfigProviderWarning(
                section: "model",
                name: name,
                kind: .notATable,
                message: "model entry must be a table; entry ignored"
            ))
            continue
        }
        var parser = ModelOverrideParser(name: name, table: table)
        var override = parser.parse()
        warnings.append(contentsOf: parser.warnings)
        if let providerName = override.modelProvider,
           let provider = definitions.modelProvider(named: providerName) {
            if override.baseURL == nil { override.baseURL = provider.baseURL }
            if override.apiBaseURL == nil { override.apiBaseURL = provider.apiBaseURL }
            if override.apiBackend == nil { override.apiBackend = parseBackend(provider.apiBackend) }
            if override.contextWindow == nil { override.contextWindow = provider.contextWindow }
            if override.extraHeaders.isEmpty { override.extraHeaders = provider.extraHeaders }
            if override.queryParams.isEmpty { override.queryParams = provider.queryParams }
            if override.envHTTPHeaders.isEmpty { override.envHTTPHeaders = provider.envHTTPHeaders }
            if override.apiKey == nil { override.apiKey = provider.apiKey }
            if override.envKey == nil, !provider.envKey.isEmpty {
                override.envKey = EnvKeys.new(provider.envKey)
            }
            if override.authProvider == nil {
                override.authProvider = provider.authProvider
                    ?? provider.auth.map { _ in "model_provider:\(providerName)" }
            }
            if let inlineAuth = provider.auth,
               definitions.authProvider(named: "model_provider:\(providerName)") == nil {
                definitions.authProviders.append(("model_provider:\(providerName)", inlineAuth))
            }
        } else if override.modelProvider != nil {
            override.baseURL = nil
            override.apiBaseURL = nil
            override.apiKey = nil
            override.envKey = nil
            override.authProvider = unresolvedModelProviderPrefix + (override.modelProvider ?? "unknown")
        }
        override.modelProvider = nil
        overrides.append((name, override))
    }
    return ConfiguredModelCatalog(
        modelOverrides: overrides,
        providerDefinitions: definitions,
        warnings: warnings
    )
}

private struct ModelOverrideParser {
    let name: String
    let table: TOMLTable
    var warnings: [ConfigProviderWarning] = []

    private static let knownFields: Set<String> = [
        "model", "base_url", "name", "description", "api_key", "env_key",
        "auth_provider", "model_provider", "api_base_url", "max_completion_tokens",
        "temperature", "top_p", "api_backend", "provider", "auth_scheme", "tool_mode",
        "subagent_context_default", "extra_headers", "query_params", "env_http_headers",
        "context_window", "auto_compact_threshold_percent", "system_prompt_label",
        "use_concise", "agent_type", "inference_idle_timeout_secs", "max_retries",
        "hidden", "supported_in_api", "reasoning_effort", "supports_reasoning_effort",
        "reasoning_efforts", "supports_reasoning_summary_parameter",
        "default_reasoning_summary", "supports_backend_search",
        "supports_standalone_web_search", "compactions_remaining",
        "send_compactions_remaining", "compaction_at_tokens", "show_model_fingerprint",
        "stream_tool_calls",
    ]

    mutating func parse() -> ConfigModelOverride {
        var override = ConfigModelOverride()
        override.model = string("model")
        override.baseURL = string("base_url")
        override.name = string("name")
        override.description = string("description")
        override.apiKey = string("api_key")
        override.envKey = envKeys("env_key")
        override.apiBaseURL = string("api_base_url")
        override.modelProvider = string("model_provider")
        override.authProvider = string("auth_provider")
        override.queryParams = pairs("query_params")
        override.envHTTPHeaders = pairs("env_http_headers")
        override.maxCompletionTokens = unsignedInteger("max_completion_tokens", as: UInt32.self)
        override.temperature = floatingPoint("temperature")
        override.topP = floatingPoint("top_p")
        override.apiBackend = enumeration("api_backend", expected: "API backend", parse: parseBackend)
        override.provider = enumeration("provider", expected: "model provider", parse: parseProvider)
        override.authScheme = enumeration("auth_scheme", expected: "authentication scheme", parse: parseAuthScheme)
        override.toolMode = enumeration("tool_mode", expected: "tool mode", parse: WireCodec.toolMode)
        override.subagentContextDefault = enumeration(
            "subagent_context_default",
            expected: "subagent context mode",
            parse: { $0.flatMap(ModelSubagentContextMode.init(wireValue:)) }
        )
        override.extraHeaders = pairs("extra_headers")
        override.contextWindow = unsignedInteger("context_window", as: UInt64.self)
        override.autoCompactThresholdPercent = unsignedInteger(
            "auto_compact_threshold_percent",
            as: UInt8.self
        )
        override.systemPromptLabel = string("system_prompt_label")
        override.useConcise = boolean("use_concise")
        override.agentType = string("agent_type")
        override.inferenceIdleTimeoutSecs = unsignedInteger(
            "inference_idle_timeout_secs",
            as: UInt64.self
        )
        override.maxRetries = unsignedInteger("max_retries", as: UInt32.self)
        override.hidden = boolean("hidden")
        override.supportedInApi = boolean("supported_in_api")
        override.reasoningEffort = enumeration(
            "reasoning_effort",
            expected: "reasoning effort",
            parse: WireCodec.reasoningEffort
        )
        override.supportsReasoningEffort = boolean("supports_reasoning_effort")
        override.reasoningEfforts = reasoningEfforts("reasoning_efforts")
        override.supportsReasoningSummaryParameter = boolean("supports_reasoning_summary_parameter")
        override.defaultReasoningSummary = enumeration(
            "default_reasoning_summary",
            expected: "reasoning summary",
            parse: WireCodec.reasoningSummary
        )
        override.supportsBackendSearch = boolean("supports_backend_search")
        override.supportsStandaloneWebSearch = boolean("supports_standalone_web_search")
        override.compactionsRemaining = compactionsRemaining()
        override.compactionAtTokens = compactionAtTokens("compaction_at_tokens")
        override.showModelFingerprint = boolean("show_model_fingerprint")
        override.streamToolCalls = boolean("stream_tool_calls")

        for field in table.allKeys where !Self.knownFields.contains(field) {
            warn(field: field, kind: .unknownField, message: "unrecognized field; value ignored")
        }

        if override.authProvider != nil,
           override.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            warn(
                field: "auth_provider",
                kind: .conflictingFields,
                message: "auth_provider is shadowed by api_key; the static key takes precedence"
            )
        } else if override.authProvider != nil, override.envKey?.primary != nil {
            warn(
                field: "auth_provider",
                kind: .conflictingFields,
                message: "auth_provider may be shadowed when env_key resolves to a value"
            )
        }
        return override
    }

    private mutating func string(_ field: String) -> String? {
        guard let value = table[field] else { return nil }
        guard let result = value.stringValue else {
            invalid(field, expected: "a string")
            return nil
        }
        return result
    }

    private mutating func boolean(_ field: String) -> Bool? {
        guard let value = table[field] else { return nil }
        guard let result = value.boolValue else {
            invalid(field, expected: "a boolean")
            return nil
        }
        return result
    }

    private mutating func floatingPoint(_ field: String) -> Float? {
        guard let value = table[field] else { return nil }
        guard let result = value.doubleValue else {
            invalid(field, expected: "a number")
            return nil
        }
        return Float(result)
    }

    private mutating func unsignedInteger<Value: FixedWidthInteger & UnsignedInteger>(
        _ field: String,
        as type: Value.Type
    ) -> Value? {
        guard let value = table[field] else { return nil }
        guard let raw = value.int64Value, let result = Value(exactly: raw) else {
            invalid(field, expected: "an in-range unsigned integer")
            return nil
        }
        return result
    }

    private mutating func enumeration<Value>(
        _ field: String,
        expected: String,
        parse: (String?) -> Value?
    ) -> Value? {
        guard let value = table[field] else { return nil }
        guard let raw = value.stringValue, let result = parse(raw) else {
            invalid(field, expected: "a recognized \(expected)")
            return nil
        }
        return result
    }

    private mutating func envKeys(_ field: String) -> EnvKeys? {
        guard let value = table[field] else { return nil }
        if let result = value.stringValue { return .single(result) }
        guard let values = value.arrayValue else {
            invalid(field, expected: "a string or an array of strings")
            return nil
        }
        let names = values.compactMap(\.stringValue)
        guard names.count == values.count else {
            invalid(field, expected: "a string or an array containing only strings")
            return nil
        }
        return .new(names)
    }

    private mutating func pairs(_ field: String) -> [(String, String)] {
        guard let value = table[field] else { return [] }
        guard case let .table(entries) = value else {
            invalid(field, expected: "a table of strings")
            return []
        }
        var result: [(String, String)] = []
        for (key, item) in entries.pairs {
            guard let string = item.stringValue else {
                invalid(field, expected: "a table containing only string values")
                return []
            }
            result.append((key, string))
        }
        return result
    }

    private mutating func reasoningEfforts(_ field: String) -> [ReasoningEffortOption] {
        guard let value = table[field] else { return [] }
        guard let entries = value.arrayValue else {
            invalid(field, expected: "an array of reasoning-effort strings or tables")
            return []
        }
        var result: [ReasoningEffortOption] = []
        for entry in entries {
            guard let option = parseReasoningEffortOption(entry) else {
                invalid(field, expected: "an array containing only valid reasoning-effort options")
                return []
            }
            result.append(option)
        }
        return result
    }

    private func parseReasoningEffortOption(_ value: TOMLValue) -> ReasoningEffortOption? {
        if let raw = value.stringValue {
            guard let effort = WireCodec.reasoningEffort(raw) else { return nil }
            return reasoningEffortOption(value: effort, id: nil, label: nil, description: nil, isDefault: false)
        }
        guard case let .table(table) = value,
              let raw = table["value"]?.stringValue,
              let effort = WireCodec.reasoningEffort(raw)
        else { return nil }
        if let id = table["id"], id.stringValue == nil { return nil }
        if let label = table["label"], label.stringValue == nil { return nil }
        if let description = table["description"], description.stringValue == nil { return nil }
        if let isDefault = table["default"], isDefault.boolValue == nil { return nil }
        return reasoningEffortOption(
            value: effort,
            id: table["id"]?.stringValue,
            label: table["label"]?.stringValue,
            description: table["description"]?.stringValue,
            isDefault: table["default"]?.boolValue ?? false
        )
    }

    private func reasoningEffortOption(
        value: ReasoningEffort,
        id: String?,
        label: String?,
        description: String?,
        isDefault: Bool
    ) -> ReasoningEffortOption {
        let resolvedID = id ?? value.asString
        let defaultLabel = resolvedID.prefix(1).uppercased() + resolvedID.dropFirst()
        return ReasoningEffortOption(
            id: resolvedID,
            value: value,
            label: label ?? defaultLabel,
            description: description,
            isDefault: isDefault
        )
    }

    private mutating func compactionsRemaining() -> CompactionsRemaining? {
        let canonical = table["compactions_remaining"]
        let legacy = table["send_compactions_remaining"]
        if let canonical {
            if let decoded = parseCompactionsRemaining(canonical) {
                if legacy != nil {
                    warn(
                        field: "send_compactions_remaining",
                        kind: .conflictingFields,
                        message: "legacy alias ignored because compactions_remaining is present"
                    )
                }
                return decoded
            }
            invalid("compactions_remaining", expected: "a boolean or an unsigned 8-bit integer")
        }
        guard let legacy else { return nil }
        guard let decoded = parseCompactionsRemaining(legacy) else {
            invalid("send_compactions_remaining", expected: "a boolean or an unsigned 8-bit integer")
            return nil
        }
        return decoded
    }

    private func parseCompactionsRemaining(_ value: TOMLValue) -> CompactionsRemaining? {
        if let enabled = value.boolValue { return .dynamic(enabled) }
        guard let raw = value.int64Value, let count = UInt8(exactly: raw) else { return nil }
        return .fixed(count)
    }

    private mutating func compactionAtTokens(_ field: String) -> CompactionAtTokens? {
        guard let value = table[field] else { return nil }
        if let enabled = value.boolValue { return .enabled(enabled) }
        guard let raw = value.int64Value, let count = UInt64(exactly: raw) else {
            invalid(field, expected: "a boolean or an unsigned integer")
            return nil
        }
        return .fixed(count)
    }

    private mutating func invalid(_ field: String, expected: String) {
        warn(field: field, kind: .invalidValue, message: "field must be \(expected); value ignored")
    }

    private mutating func warn(field: String?, kind: ConfigProviderWarning.Kind, message: String) {
        warnings.append(ConfigProviderWarning(
            section: "model",
            name: name,
            field: field,
            kind: kind,
            message: message
        ))
    }
}

private func parseBackend(_ value: String?) -> ApiBackend? {
    switch value?.lowercased() {
    case "chat_completions", "chat-completions": return .chatCompletions
    case "responses": return .responses
    case "messages": return .messages
    default: return nil
    }
}

private func parseProvider(_ value: String?) -> ModelProvider? {
    guard let value else { return nil }
    switch value.lowercased() {
    case "xai": return .xai
    case "codex", "openai", "openai_codex": return .codex
    case "kimi", "moonshot", "moonshot_ai": return .kimi
    case "fireworks", "fireworks_ai": return .fireworks
    case "deepseek", "deep_seek", "deepseek_api": return .deepseek
    case "meta", "meta_ai", "meta_api": return .meta
    case "opencode_go", "opencode-go": return .openCodeGo
    case "wafer", "wafer_ai": return .wafer
    case "zai", "z_ai", "z-ai", "zai_api", "glm": return .zai
    case "runinfra", "run_infra", "run-infra": return .runinfra
    case "gemini", "google", "google_gemini", "ai_studio", "aistudio", "gemini_api":
        return .gemini
    case "openrouter", "open_router", "open-router": return .openRouter
    default: return nil
    }
}

private func parseAuthScheme(_ value: String?) -> AuthScheme? {
    switch value?.lowercased() {
    case "bearer": return .bearer
    case "x_api_key", "x-api-key": return .xApiKey
    default: return nil
    }
}
