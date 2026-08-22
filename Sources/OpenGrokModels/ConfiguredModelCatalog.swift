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

    public init(
        modelOverrides: [(String, ConfigModelOverride)] = [],
        providerDefinitions: ParsedProviderDefinitions = ParsedProviderDefinitions()
    ) {
        self.modelOverrides = modelOverrides
        self.providerDefinitions = providerDefinitions
    }

    public var authProviders: [(String, AuthProviderConfig)] {
        providerDefinitions.authProviders
    }
}

extension ConfiguredModelCatalog {
    public static func == (lhs: ConfiguredModelCatalog, rhs: ConfiguredModelCatalog) -> Bool {
        lhs.modelOverrides.count == rhs.modelOverrides.count &&
        zip(lhs.modelOverrides, rhs.modelOverrides).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } &&
        lhs.providerDefinitions == rhs.providerDefinitions
    }
}

public func parseConfiguredModelCatalog(
    from document: TOMLValue,
    trustedProviderDefinitions: ParsedProviderDefinitions? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> ConfiguredModelCatalog {
    var definitions = trustedProviderDefinitions ?? parseProviderDefinitions(from: document)
    guard let modelSection = document["model"], case let .table(models) = modelSection else {
        return ConfiguredModelCatalog(providerDefinitions: definitions)
    }

    var overrides: [(String, ConfigModelOverride)] = []
    for (name, value) in models.pairs {
        guard case let .table(table) = value else { continue }
        var override = parseModelOverride(table)
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
        if !override.envHTTPHeaders.isEmpty {
            for (header, variable) in override.envHTTPHeaders {
                if let value = environment[variable], !value.isEmpty,
                   !override.extraHeaders.contains(where: { $0.0.caseInsensitiveCompare(header) == .orderedSame }) {
                    override.extraHeaders.append((header, value))
                }
            }
        }
        overrides.append((name, override))
    }
    return ConfiguredModelCatalog(
        modelOverrides: overrides,
        providerDefinitions: definitions
    )
}

private func parseModelOverride(_ table: TOMLTable) -> ConfigModelOverride {
    ConfigModelOverride(
        model: table["model"]?.stringValue,
        baseURL: table["base_url"]?.stringValue,
        name: table["name"]?.stringValue,
        description: table["description"]?.stringValue,
        apiKey: table["api_key"]?.stringValue,
        envKey: parseEnvKeys(table["env_key"]),
        apiBaseURL: table["api_base_url"]?.stringValue,
        modelProvider: table["model_provider"]?.stringValue,
        authProvider: table["auth_provider"]?.stringValue,
        queryParams: parsePairs(table["query_params"]),
        envHTTPHeaders: parsePairs(table["env_http_headers"]),
        maxCompletionTokens: table["max_completion_tokens"]?.int64Value.flatMap(UInt32.init),
        temperature: table["temperature"]?.doubleValue.map(Float.init),
        topP: table["top_p"]?.doubleValue.map(Float.init),
        apiBackend: parseBackend(table["api_backend"]?.stringValue),
        provider: parseProvider(table["provider"]?.stringValue),
        authScheme: parseAuthScheme(table["auth_scheme"]?.stringValue),
        extraHeaders: parsePairs(table["extra_headers"]),
        contextWindow: table["context_window"]?.int64Value.flatMap(UInt64.init),
        agentType: table["agent_type"]?.stringValue,
        hidden: table["hidden"]?.boolValue,
        supportedInApi: table["supported_in_api"]?.boolValue,
        streamToolCalls: table["stream_tool_calls"]?.boolValue
    )
}

private func parseEnvKeys(_ value: TOMLValue?) -> EnvKeys? {
    guard let value else { return nil }
    if let string = value.stringValue { return .single(string) }
    guard let values = value.arrayValue else { return nil }
    return .new(values.compactMap(\.stringValue))
}

private func parsePairs(_ value: TOMLValue?) -> [(String, String)] {
    guard case let .table(table) = value else { return [] }
    return table.pairs.compactMap { key, value in value.stringValue.map { (key, $0) } }
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
