// RunInfraModels.swift
//
// Provider-isolated RunInfra model discovery.
// Port of `crates/codegen/xai-grok-shell/src/runinfra_models.rs`.

import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes

public enum RunInfraModels {
    public static let apiBaseURLDefault = "https://api.runinfra.ai/v1"
    public static let apiBaseURLEnv = "OPENGROK_RUNINFRA_API_BASE_URL"
    public static let gatewayKeyEnv = "RUNINFRA_GATEWAY_KEY"
    public static let apiKeyEnv = "RUNINFRA_API_KEY"

    public static let defaultContextWindow: UInt64 = 262_144
    public static let defaultMaxOutputTokens: UInt32 = 32_768

    public static let fallbackModelIDs: [String] = [
        "deepseek-v4-flash",
        "nemotron-3-5-lightning-30b",
        "qwen3-8-2-4t-a95b",
        "qwen3-8-27b",
    ]

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "api.runinfra.ai"
    }

    public static func apiBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        trimmedBaseURL(environment[apiBaseURLEnv]) ?? apiBaseURLDefault
    }

    public static func environmentAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        nonEmpty(environment[gatewayKeyEnv]) ?? nonEmpty(environment[apiKeyEnv])
    }

    public static func environmentAPIKeyIsConfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environmentAPIKey(environment: environment) != nil
    }

    public static func envKeys() -> EnvKeys {
        EnvKeys.new([gatewayKeyEnv, apiKeyEnv])
    }

    public static func credentialFingerprint(apiKey: String) -> String {
        Blake3.hexDigest(Array(apiKey.utf8))
    }

    /// Explicit environment credentials may target a user-selected gateway;
    /// stored provider credentials must never leave RunInfra's owned host.
    public static func selectAPIKey(
        baseURL: String,
        environmentKey: String?,
        storedKey: String?
    ) -> String? {
        if let environmentKey = nonEmpty(environmentKey) { return environmentKey }
        guard isTrustedAPIBaseURL(baseURL) else { return nil }
        return nonEmpty(storedKey)
    }

    public static func catalogKey(modelID: String) -> String {
        "runinfra:\(modelID)"
    }

    public static func isKnownReasoningModel(modelID: String) -> Bool {
        fallbackModelIDs.contains(modelID.lowercased())
    }

    public static func runinfraReasoningEfforts(modelID: String) -> [ReasoningEffortOption] {
        guard isKnownReasoningModel(modelID: modelID) else { return [] }

        let normalizedID = modelID.lowercased()
        let defaultEffort: ReasoningEffort = normalizedID == "deepseek-v4-flash" ? .max : .high
        var options: [ReasoningEffortOption] = []

        if normalizedID != "qwen3-8-2-4t-a95b" {
            options.append(reasoningOption(
                .none,
                label: "None",
                description: "Answer only; skip the billed reasoning stream",
                isDefault: false
            ))
        }

        options.append(contentsOf: [
            reasoningOption(
                .low,
                label: "Low",
                description: "Accepted by the gateway; no measured change vs default reasoning",
                isDefault: false
            ),
            reasoningOption(
                .medium,
                label: "Medium",
                description: "Accepted by the gateway; no measured change vs default reasoning",
                isDefault: false
            ),
            reasoningOption(
                .high,
                label: "High",
                description: "Default reasoning for models that do not inject max",
                isDefault: defaultEffort == .high
            ),
            reasoningOption(
                .max,
                label: "Max",
                description: "DeepSeek V4 Flash gateway default; maximum thinking depth",
                isDefault: defaultEffort == .max
            ),
        ])
        return options
    }

    public static func modelEntry(
        modelID: String,
        baseURL: String,
        contextWindow: UInt64? = nil,
        maxOutputTokens: UInt32? = nil
    ) -> ModelEntry {
        let key = catalogKey(modelID: modelID)
        let curatedContext = modelID.lowercased() == "deepseek-v4-flash"
            ? UInt64(1_048_576)
            : defaultContextWindow

        var info = ModelInfo.fallback(slug: key)
        info.id = key
        info.model = modelID
        info.baseURL = trimTrailingSlashes(baseURL)
        info.name = displayName(modelID: modelID)
        info.apiBackend = .chatCompletions
        info.provider = .runinfra
        info.toolMode = .direct
        info.contextWindow = contextWindow.flatMap { $0 > 0 ? $0 : nil } ?? curatedContext
        info.maxCompletionTokens = maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
            ?? defaultMaxOutputTokens

        let reasoningEfforts = runinfraReasoningEfforts(modelID: modelID)
        info.reasoningEfforts = reasoningEfforts
        info.reasoningEffort = reasoningEfforts.first(where: \.isDefault)?.value
        info.supportsReasoningEffort = !reasoningEfforts.isEmpty
        info.supportsBackendSearch = false
        info.supportedInApi = true

        return ModelEntry(info: info, envKey: envKeys())
    }

    public static func curatedCatalog(
        baseURL: String = RunInfraModels.apiBaseURLDefault
    ) -> OrderedModelMap {
        var catalog = OrderedModelMap()
        for modelID in fallbackModelIDs {
            catalog[catalogKey(modelID: modelID)] = modelEntry(
                modelID: modelID,
                baseURL: baseURL
            )
        }
        return catalog
    }

    public static func fallbackCatalog(
        baseURL: String = RunInfraModels.apiBaseURLDefault
    ) -> OrderedModelMap {
        curatedCatalog(baseURL: baseURL)
    }

    /// Successful nonempty responses are authoritative, including verified
    /// workspace deployments; an empty response retains the hosted fallback.
    public static func parseCatalog(
        _ data: Data,
        baseURL: String
    ) throws -> OrderedModelMap {
        let decoded = try decodeCatalog(data, baseURL: baseURL)
        return decoded.entries.isEmpty ? curatedCatalog(baseURL: baseURL) : decoded.entries
    }

    /// Preserve the distinction between an authenticated authoritative
    /// response and a curated fallback that cannot safely match a principal.
    public static func parseCatalogSnapshot(
        _ data: Data,
        baseURL: String,
        credentialFingerprint: String
    ) throws -> RunInfraModelsCatalog {
        let decoded = try decodeCatalog(data, baseURL: baseURL)
        guard !decoded.entries.isEmpty else {
            return RunInfraModelsCatalog(
                entries: curatedCatalog(baseURL: baseURL),
                credentialFingerprint: nil
            )
        }

        return RunInfraModelsCatalog(
            entries: decoded.entries,
            credentialFingerprint: credentialFingerprint,
            wireContextPresent: decoded.wireContextPresent
        )
    }

    public static func safeErrorExcerpt(_ body: String, apiKey: String) -> String {
        safeCatalogErrorExcerpt(body, apiKey: apiKey)
    }

    private static func reasoningOption(
        _ effort: ReasoningEffort,
        label: String,
        description: String,
        isDefault: Bool
    ) -> ReasoningEffortOption {
        ReasoningEffortOption(
            id: effort.asString,
            value: effort,
            label: label,
            description: description,
            isDefault: isDefault
        )
    }

    private static func displayName(modelID: String) -> String {
        switch modelID {
        case "deepseek-v4-flash": return "DeepSeek V4 Flash"
        case "nemotron-3-5-lightning-30b": return "Nemotron 3.5 Lightning 30B"
        case "qwen3-8-2-4t-a95b": return "Qwen3.8 2.4T A95B"
        case "qwen3-8-27b": return "Qwen3.8 27B"
        default: return modelID
        }
    }

    private static func decodeCatalog(
        _ data: Data,
        baseURL: String
    ) throws -> (entries: OrderedModelMap, wireContextPresent: Bool) {
        let response: RunInfraWireResponse
        do {
            response = try JSONDecoder().decode(RunInfraWireResponse.self, from: data)
        } catch {
            throw ModelsError.remoteMalformed(
                "RunInfra /models response was invalid: \(error.localizedDescription)"
            )
        }

        var entries = OrderedModelMap()
        var wireContextPresent = false
        for wireModel in response.data {
            guard let modelID = nonEmpty(wireModel.id) else { continue }
            if let contextWindow = wireModel.contextWindow, contextWindow > 0 {
                wireContextPresent = true
            }
            entries[catalogKey(modelID: modelID)] = modelEntry(
                modelID: modelID,
                baseURL: baseURL,
                contextWindow: wireModel.contextWindow,
                maxOutputTokens: wireModel.maxOutputTokens
            )
        }

        return (entries, wireContextPresent)
    }
}

public struct RunInfraModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var credentialFingerprint: String?
    public var wireContextPresent: Bool

    public init(
        entries: OrderedModelMap,
        credentialFingerprint: String?,
        wireContextPresent: Bool = false
    ) {
        self.entries = entries
        self.credentialFingerprint = credentialFingerprint
        self.wireContextPresent = wireContextPresent
    }

    public var isAuthoritative: Bool { credentialFingerprint != nil }

    public func matchesCredential(fingerprint: String) -> Bool {
        credentialFingerprint == fingerprint
    }
}

private struct RunInfraWireResponse: Decodable {
    var data: [RunInfraWireModel]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.data) {
            data = try container.decode([RunInfraWireModel].self, forKey: .data)
        } else {
            data = []
        }
    }
}

private struct RunInfraWireModel: Decodable {
    var id: String
    var contextWindow: UInt64?
    var maxOutputTokens: UInt32?

    private enum CodingKeys: String, CodingKey {
        case id
        case contextWindow = "context_window"
        case maxOutputTokens = "max_output_tokens"
    }
}
