// GeminiModels.swift
//
// Provider-isolated Google Gemini / AI Studio model discovery. The remote
// catalog enriches the reviewed model allowlist but never controls membership.

import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes

public struct CuratedGeminiModel: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let description: String

    public init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public enum GeminiModels {
    public static let apiBaseURLDefault =
        "https://generativelanguage.googleapis.com/v1beta/openai"
    public static let apiBaseURLEnv = "OPENGROK_GEMINI_API_BASE_URL"
    public static let apiKeyEnv = "GEMINI_API_KEY"
    public static let googleAPIKeyEnv = "GOOGLE_API_KEY"
    public static let defaultContextWindow: UInt64 = 1_048_576
    public static let defaultMaxOutputTokens: UInt32 = 65_536

    public static let curated: [CuratedGeminiModel] = [
        CuratedGeminiModel(
            id: "gemini-3.7-flash",
            name: "Gemini 3.7 Flash",
            description: "Gemini 3.7 Flash on Google AI Studio (low/medium/high thinking)"
        ),
        CuratedGeminiModel(
            id: "gemini-3.6-flash",
            name: "Gemini 3.6 Flash",
            description: "Gemini 3.6 Flash on Google AI Studio"
        ),
        CuratedGeminiModel(
            id: "gemini-3.5-flash-lite",
            name: "Gemini 3.5 Flash-Lite",
            description: "Gemini 3.5 Flash-Lite on Google AI Studio (minimal thinking default)"
        ),
        CuratedGeminiModel(
            id: "gemini-3.1-pro-preview",
            name: "Gemini 3.1 Pro Preview",
            description: "Gemini 3.1 Pro Preview on Google AI Studio (low/medium/high thinking)"
        ),
    ]

    public static func apiBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        trimmedBaseURL(environment[apiBaseURLEnv]) ?? apiBaseURLDefault
    }

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "generativelanguage.googleapis.com"
    }

    public static func environmentAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        nonEmpty(environment[apiKeyEnv]) ?? nonEmpty(environment[googleAPIKeyEnv])
    }

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        environmentAPIKey(environment: environment)
    }

    public static func environmentAPIKeyIsConfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environmentAPIKey(environment: environment) != nil
    }

    public static func envKeys() -> EnvKeys {
        .new([apiKeyEnv, googleAPIKeyEnv])
    }

    /// An explicit environment key may target a user-selected proxy; a stored
    /// credential must never follow that override outside Google's owned host.
    public static func selectAPIKey(
        baseURL: String,
        environmentKey: String?,
        storedKey: String?
    ) -> String? {
        if let environmentKey = nonEmpty(environmentKey) {
            return environmentKey
        }
        guard isTrustedAPIBaseURL(baseURL) else {
            return nil
        }
        return nonEmpty(storedKey)
    }

    public static func credentialFingerprint(apiKey: String) -> String {
        Blake3.hexDigest(Array(apiKey.utf8))
    }

    public static func catalogKey(modelID: String) -> String {
        "gemini:\(modelID)"
    }

    public static func supportsMinimalReasoning(modelID: String) -> Bool {
        modelID != "gemini-3.7-flash" && modelID != "gemini-3.1-pro-preview"
    }

    public static func defaultReasoningEffort(modelID: String) -> ReasoningEffort {
        switch modelID {
        case "gemini-3.5-flash-lite": .minimal
        case "gemini-3.1-pro-preview": .high
        default: .medium
        }
    }

    /// Gemini 3 cannot disable thinking. Unsupported model-specific minimal
    /// and higher-than-high requests are normalized before Chat Completions.
    public static func normalizedReasoningEffort(
        modelID: String?,
        effort: ReasoningEffort
    ) -> ReasoningEffort? {
        switch effort {
        case .none:
            nil
        case .minimal where modelID.map({ !supportsMinimalReasoning(modelID: $0) }) == true:
            .low
        case .xhigh, .max, .ultra:
            .high
        default:
            effort
        }
    }

    public static func reasoningEfforts(modelID: String) -> [ReasoningEffortOption] {
        let defaultEffort = defaultReasoningEffort(modelID: modelID)
        var options: [ReasoningEffortOption] = []
        if supportsMinimalReasoning(modelID: modelID) {
            options.append(reasoningOption(
                .minimal,
                description: "Use as few thinking tokens as possible; Gemini 3 cannot fully disable thinking",
                defaultEffort: defaultEffort
            ))
        }
        options.append(contentsOf: [
            reasoningOption(.low, description: "Minimize latency and cost", defaultEffort: defaultEffort),
            reasoningOption(.medium, description: "Balanced thinking for most tasks", defaultEffort: defaultEffort),
            reasoningOption(.high, description: "Maximum thinking depth", defaultEffort: defaultEffort),
        ])
        return options
    }

    public static func curatedEntry(
        _ curated: CuratedGeminiModel,
        baseURL: String,
        contextWindow: UInt64? = nil,
        maxOutputTokens: UInt32? = nil
    ) -> ModelEntry {
        let key = catalogKey(modelID: curated.id)
        var info = ModelInfo.fallback(slug: key)
        info.id = key
        info.model = curated.id
        info.baseURL = trimTrailingSlashes(baseURL)
        info.name = curated.name
        info.description = curated.description
        info.apiBackend = .chatCompletions
        info.provider = .gemini
        info.toolMode = .direct
        info.contextWindow = contextWindow.flatMap { $0 > 0 ? $0 : nil }
            ?? defaultContextWindow
        info.maxCompletionTokens = maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
            ?? defaultMaxOutputTokens
        info.reasoningEfforts = reasoningEfforts(modelID: curated.id)
        info.reasoningEffort = defaultReasoningEffort(modelID: curated.id)
        info.supportsReasoningEffort = true
        info.supportsBackendSearch = false
        info.supportedInApi = true
        return ModelEntry(info: info, envKey: envKeys())
    }

    public static func curatedCatalog(
        baseURL: String = apiBaseURLDefault,
        contextBySlug: [String: UInt64] = [:]
    ) -> OrderedModelMap {
        var entries = OrderedModelMap()
        entries.reserveCapacity(curated.count)
        for model in curated {
            entries[catalogKey(modelID: model.id)] = curatedEntry(
                model,
                baseURL: baseURL,
                contextWindow: contextBySlug[model.id]
            )
        }
        return entries
    }

    public static func parseContextEnrichment(_ data: Data) throws -> [String: UInt64] {
        let limits = try parseWireLimits(data)
        return limits.reduce(into: [:]) { contexts, item in
            if let context = item.value.contextWindow {
                contexts[item.key] = context
            }
        }
    }

    public static func parseCatalog(_ data: Data, baseURL: String) throws -> OrderedModelMap {
        catalog(baseURL: baseURL, limits: try parseWireLimits(data))
    }

    public static func enrichedCatalog(
        _ data: Data,
        baseURL: String,
        credentialFingerprint: String?
    ) throws -> GeminiModelsCatalog {
        let limits = try parseWireLimits(data)
        return GeminiModelsCatalog(
            entries: catalog(baseURL: baseURL, limits: limits),
            credentialFingerprint: credentialFingerprint,
            enriched: !limits.isEmpty
        )
    }

    public static func safeErrorExcerpt(_ body: String, apiKey: String) -> String {
        safeCatalogErrorExcerpt(body, apiKey: apiKey)
    }

    private static func reasoningOption(
        _ effort: ReasoningEffort,
        description: String,
        defaultEffort: ReasoningEffort
    ) -> ReasoningEffortOption {
        ReasoningEffortOption(
            id: effort.rawValue,
            value: effort,
            label: effort.rawValue.capitalized,
            description: description,
            isDefault: effort == defaultEffort
        )
    }

    private static func catalog(
        baseURL: String,
        limits: [String: GeminiWireLimits]
    ) -> OrderedModelMap {
        var entries = OrderedModelMap()
        entries.reserveCapacity(curated.count)
        for model in curated {
            let modelLimits = limits[model.id]
            entries[catalogKey(modelID: model.id)] = curatedEntry(
                model,
                baseURL: baseURL,
                contextWindow: modelLimits?.contextWindow,
                maxOutputTokens: modelLimits?.maxOutputTokens
            )
        }
        return entries
    }

    private static func parseWireLimits(_ data: Data) throws -> [String: GeminiWireLimits] {
        let response: GeminiWireResponse
        do {
            response = try JSONDecoder().decode(GeminiWireResponse.self, from: data)
        } catch {
            throw ModelsError.remoteMalformed("Gemini /models response was invalid: \(error)")
        }

        let allowedIDs = Set(curated.map(\.id))
        var limits: [String: GeminiWireLimits] = [:]
        for model in response.data {
            var id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.hasPrefix("models/") {
                id.removeFirst("models/".count)
            }
            guard !id.isEmpty, allowedIDs.contains(id) else {
                continue
            }
            let candidateContext = model.contextWindow ?? model.contextLength ?? model.inputTokenLimit
            let context = candidateContext.flatMap { $0 > 0 ? $0 : nil }
            let candidateOutput = model.maxOutputTokens ?? model.outputTokenLimit
            let output = candidateOutput.flatMap { $0 > 0 ? $0 : nil }
            if context != nil || output != nil {
                limits[id] = GeminiWireLimits(contextWindow: context, maxOutputTokens: output)
            }
        }
        return limits
    }
}

public struct GeminiModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var credentialFingerprint: String?
    public var enriched: Bool

    public init(
        entries: OrderedModelMap,
        credentialFingerprint: String? = nil,
        enriched: Bool = false
    ) {
        self.entries = entries
        self.credentialFingerprint = credentialFingerprint
        self.enriched = enriched
    }

    public var isAuthoritative: Bool {
        !entries.isEmpty
    }

    public func matchesCredential(fingerprint: String?) -> Bool {
        guard let credentialFingerprint, let fingerprint else {
            return false
        }
        return credentialFingerprint == fingerprint
    }
}

private struct GeminiWireLimits {
    let contextWindow: UInt64?
    let maxOutputTokens: UInt32?
}

private struct GeminiWireResponse: Decodable {
    let data: [GeminiWireModel]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = container.contains(.data)
            ? try container.decode([GeminiWireModel].self, forKey: .data)
            : []
    }
}

private struct GeminiWireModel: Decodable {
    let id: String
    let contextWindow: UInt64?
    let contextLength: UInt64?
    let inputTokenLimit: UInt64?
    let maxOutputTokens: UInt32?
    let outputTokenLimit: UInt32?

    private enum CodingKeys: String, CodingKey {
        case id
        case contextWindow = "context_window"
        case contextLength = "context_length"
        case inputTokenLimit = "input_token_limit"
        case maxOutputTokens = "max_output_tokens"
        case outputTokenLimit = "output_token_limit"
    }
}
