// ModelsConfig.swift
//
// Catalog-facing subset of shell `ModelsConfig` + the resolution input bag
// used by `resolveModelList` / `resolveModelCatalog`. Full TOML config loading
// remains in OpenGrokConfig / the shell; this module accepts already-resolved
// knobs so it stays free of auth and session ownership.

import Foundation
import OpenGrokConfigTypes
import OpenGrokSamplingTypes

/// Selected Kimi service. Platform is the migration-compatible default;
/// Code has an independent endpoint, credential, and embedded catalog.
public enum KimiApiEndpoint: String, Codable, Sendable, Equatable, Hashable {
    case platform
    case code

    public static let defaultValue: KimiApiEndpoint = .platform

    public var baseURL: String {
        switch self {
        case .platform: return KimiModels.platformAPIBaseURL
        case .code: return KimiModels.codeAPIBaseURL
        }
    }

    public var apiKeyEnv: String {
        switch self {
        case .platform: return KimiModels.platformAPIKeyEnv
        case .code: return KimiModels.codeAPIKeyEnv
        }
    }
}

/// `[models]` section knobs that affect catalog assembly and selection.
public struct ModelsSectionConfig: Sendable, Equatable {
    public var `default`: String?
    public var kimiEndpoint: KimiApiEndpoint
    public var preCampaignDefault: String?
    public var defaultIsCampaignDriven: Bool
    public var defaultReasoningEffort: ReasoningEffort?
    public var webSearch: String?
    public var sessionSummary: String?
    public var recap: String?
    public var memory: String?
    public var imageDescription: String?
    public var promptSuggestion: String?
    public var allowedModels: [String]?
    public var hiddenModels: [String]?
    public var disabledModels: [String]?
    public var agentType: String?
    public var extraHeaders: [(String, String)]
    public var temperature: Float?
    public var topP: Float?
    public var maxCompletionTokens: UInt32?
    public var maxRetries: UInt32?
    public var inferenceIdleTimeoutSecs: UInt64?
    public var streamToolCalls: Bool?

    public init(
        default: String? = nil,
        kimiEndpoint: KimiApiEndpoint = .platform,
        preCampaignDefault: String? = nil,
        defaultIsCampaignDriven: Bool = false,
        defaultReasoningEffort: ReasoningEffort? = nil,
        webSearch: String? = nil,
        sessionSummary: String? = nil,
        recap: String? = nil,
        memory: String? = nil,
        imageDescription: String? = nil,
        promptSuggestion: String? = nil,
        allowedModels: [String]? = nil,
        hiddenModels: [String]? = nil,
        disabledModels: [String]? = nil,
        agentType: String? = nil,
        extraHeaders: [(String, String)] = [],
        temperature: Float? = nil,
        topP: Float? = nil,
        maxCompletionTokens: UInt32? = nil,
        maxRetries: UInt32? = nil,
        inferenceIdleTimeoutSecs: UInt64? = nil,
        streamToolCalls: Bool? = nil
    ) {
        self.default = `default`
        self.kimiEndpoint = kimiEndpoint
        self.preCampaignDefault = preCampaignDefault
        self.defaultIsCampaignDriven = defaultIsCampaignDriven
        self.defaultReasoningEffort = defaultReasoningEffort
        self.webSearch = webSearch
        self.sessionSummary = sessionSummary
        self.recap = recap
        self.memory = memory
        self.imageDescription = imageDescription
        self.promptSuggestion = promptSuggestion
        self.allowedModels = allowedModels
        self.hiddenModels = hiddenModels
        self.disabledModels = disabledModels
        self.agentType = agentType
        self.extraHeaders = extraHeaders
        self.temperature = temperature
        self.topP = topP
        self.maxCompletionTokens = maxCompletionTokens
        self.maxRetries = maxRetries
        self.inferenceIdleTimeoutSecs = inferenceIdleTimeoutSecs
        self.streamToolCalls = streamToolCalls
    }

    public static let `default` = ModelsSectionConfig()
}

/// Full catalog-resolution input: endpoints, models section, config overrides,
/// CLI/env defaults, and optional remote default model.
public struct CatalogResolutionInput: Sendable, Equatable {
    public var endpoints: EndpointsConfig
    public var models: ModelsSectionConfig
    /// `[model.<id>]` overrides, ordered for deterministic application.
    public var configModels: [(String, ConfigModelOverride)]
    /// Explicit CLI `-m` override.
    public var defaultModelOverride: String?
    /// Remote settings `default_model` hint.
    public var remoteDefaultModel: String?
    /// Global CLI `--effort` override applied when the model offers it.
    public var reasoningEffortOverride: ReasoningEffort?

    public init(
        endpoints: EndpointsConfig = .default,
        models: ModelsSectionConfig = .default,
        configModels: [(String, ConfigModelOverride)] = [],
        defaultModelOverride: String? = nil,
        remoteDefaultModel: String? = nil,
        reasoningEffortOverride: ReasoningEffort? = nil
    ) {
        self.endpoints = endpoints
        self.models = models
        self.configModels = configModels
        self.defaultModelOverride = defaultModelOverride
        self.remoteDefaultModel = remoteDefaultModel
        self.reasoningEffortOverride = reasoningEffortOverride
    }

    public static let `default` = CatalogResolutionInput()
}
