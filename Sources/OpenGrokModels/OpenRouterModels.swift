// OpenRouterModels.swift
//
// Provider-isolated, explicitly opted-in OpenRouter model discovery.
// Port of `crates/codegen/xai-grok-shell/src/openrouter_models.rs`.

import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes

/// Optional provider-reported, per-unit pricing. Missing or malformed pricing
/// never hides an otherwise usable model: upstream does not require pricing.
public struct OpenRouterModelPricing: Codable, Equatable, Sendable {
    public var prompt: Decimal?
    public var completion: Decimal?
    public var request: Decimal?
    public var image: Decimal?
    public var webSearch: Decimal?
    public var internalReasoning: Decimal?
    public var inputCacheRead: Decimal?
    public var inputCacheWrite: Decimal?

    public init(
        prompt: Decimal? = nil,
        completion: Decimal? = nil,
        request: Decimal? = nil,
        image: Decimal? = nil,
        webSearch: Decimal? = nil,
        internalReasoning: Decimal? = nil,
        inputCacheRead: Decimal? = nil,
        inputCacheWrite: Decimal? = nil
    ) {
        self.prompt = prompt
        self.completion = completion
        self.request = request
        self.image = image
        self.webSearch = webSearch
        self.internalReasoning = internalReasoning
        self.inputCacheRead = inputCacheRead
        self.inputCacheWrite = inputCacheWrite
    }

    public enum CodingKeys: String, CodingKey {
        case prompt, completion, request, image
        case webSearch = "web_search"
        case internalReasoning = "internal_reasoning"
        case inputCacheRead = "input_cache_read"
        case inputCacheWrite = "input_cache_write"
    }

    fileprivate var containsAnyAmount: Bool {
        prompt != nil || completion != nil || request != nil || image != nil
            || webSearch != nil || internalReasoning != nil
            || inputCacheRead != nil || inputCacheWrite != nil
    }
}

public struct OpenRouterModelDescriptor: Codable, Equatable, Sendable {
    public var key: String
    public var id: String
    public var name: String
    public var apiBackend: ApiBackend
    public var pricing: OpenRouterModelPricing?

    public init(
        key: String,
        id: String,
        name: String,
        apiBackend: ApiBackend,
        pricing: OpenRouterModelPricing? = nil
    ) {
        self.key = key
        self.id = id
        self.name = name
        self.apiBackend = apiBackend
        self.pricing = pricing
    }

    public enum CodingKeys: String, CodingKey {
        case key, id, name, pricing
        case apiBackend = "api_backend"
    }
}

/// A successful OpenRouter response is authoritative even when it is empty.
/// Credentials are never embedded; the digest binds publication to one key.
public struct OpenRouterModelsCatalog: Equatable, Sendable {
    public var entries: OrderedModelMap
    public var descriptors: [OpenRouterModelDescriptor]
    public var credentialFingerprint: String
    public var warnings: [String]

    public init(
        entries: OrderedModelMap,
        descriptors: [OpenRouterModelDescriptor],
        credentialFingerprint: String,
        warnings: [String] = []
    ) {
        self.entries = entries
        self.descriptors = descriptors
        self.credentialFingerprint = credentialFingerprint
        self.warnings = warnings
    }

    public var isAuthoritative: Bool { true }

    public func matchesCredential(fingerprint: String) -> Bool {
        !fingerprint.isEmpty
            && !credentialFingerprint.isEmpty
            && credentialFingerprint == fingerprint
    }

    /// Discovery alone never grants model access: either the exact catalog key
    /// or the exact provider model identifier must have been explicitly opted in.
    public func selectableEntries(enabledModels: [String] = []) -> OrderedModelMap {
        guard !enabledModels.isEmpty else { return OrderedModelMap() }

        let enabled = Set(enabledModels)
        var selectable = OrderedModelMap()
        for (key, entry) in entries {
            guard entry.info.provider == .openRouter,
                  enabled.contains(key) || enabled.contains(entry.info.model) else {
                continue
            }
            selectable[key] = entry
        }
        return selectable
    }
}

public enum OpenRouterModels {
    public static let apiBaseURLDefault = "https://openrouter.ai/api/v1"
    public static let apiBaseURLEnv = "OPENGROK_OPENROUTER_API_BASE_URL"
    public static let apiKeyEnv = "OPENROUTER_API_KEY"
    public static let httpReferer = "https://github.com/mweinbach/open-grok"
    public static let appTitle = "Open Grok"
    public static let requestTimeout: TimeInterval = 15
    public static let fallbackContextWindow: UInt64 = 200_000

    public static func apiBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        trimmedBaseURL(environment[apiBaseURLEnv]) ?? apiBaseURLDefault
    }

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "openrouter.ai"
    }

    public static func environmentAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        nonEmpty(environment[apiKeyEnv])
    }

    public static func environmentAPIKeyIsConfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environmentAPIKey(environment: environment) != nil
    }

    /// Explicit environment credentials may target a user-selected endpoint;
    /// persisted OpenRouter credentials may only travel to OpenRouter itself.
    public static func selectAPIKey(
        baseURL: String,
        environmentKey: String?,
        storedKey: String?
    ) -> String? {
        if let environmentKey = nonEmpty(environmentKey) { return environmentKey }
        guard isTrustedAPIBaseURL(baseURL) else { return nil }
        return nonEmpty(storedKey)
    }

    /// Exact Rust BLAKE3 digest; never include this principal's raw bearer key.
    public static func credentialFingerprint(_ apiKey: String) -> String {
        Blake3.hexDigest(Array(apiKey.utf8))
    }

    public static func catalogKey(modelID: String) -> String {
        "openrouter:\(modelID)"
    }

    public static func modelsRequest(
        apiKey: String,
        baseURL: String = apiBaseURLDefault
    ) -> ModelCatalogRequest {
        ModelCatalogRequest(
            url: ModelCatalogRequests.modelsURL(baseURL: baseURL),
            headers: [
                ModelCatalogHeader("Authorization", "Bearer \(apiKey)"),
                ModelCatalogHeader("HTTP-Referer", httpReferer),
                ModelCatalogHeader("X-Title", appTitle),
            ],
            timeout: requestTimeout
        )
    }

    public static func parseCatalog(
        _ data: Data,
        baseURL: String
    ) throws -> OrderedModelMap {
        try decodeCatalog(data, baseURL: baseURL).entries
    }

    public static func parseCatalogSnapshot(
        _ data: Data,
        baseURL: String,
        apiKey: String
    ) throws -> OpenRouterModelsCatalog {
        guard let apiKey = nonEmpty(apiKey) else {
            throw ModelsError.remoteMalformed("OpenRouter model catalog requires an API key")
        }

        let decoded = try decodeCatalog(data, baseURL: baseURL)
        return OpenRouterModelsCatalog(
            entries: decoded.entries,
            descriptors: decoded.descriptors,
            credentialFingerprint: credentialFingerprint(apiKey),
            warnings: decoded.warnings
        )
    }

    public static func safeErrorExcerpt(_ body: String, apiKey: String) -> String {
        safeCatalogErrorExcerpt(body, apiKey: apiKey)
    }

    private static func decodeCatalog(
        _ data: Data,
        baseURL: String
    ) throws -> (
        entries: OrderedModelMap,
        descriptors: [OpenRouterModelDescriptor],
        warnings: [String]
    ) {
        let response: OpenRouterWireResponse
        do {
            response = try JSONDecoder().decode(OpenRouterWireResponse.self, from: data)
        } catch {
            throw ModelsError.remoteMalformed("OpenRouter models response was invalid")
        }

        var entries = OrderedModelMap()
        var descriptors: [OpenRouterModelDescriptor] = []
        var warnings: [String] = []

        for wire in response.data {
            guard let id = nonEmpty(wire.id) else { continue }

            if !hasTextOutput(wire) {
                warnings.append("OpenRouter model `\(id)` omitted: no text output")
                continue
            }
            if !supportsTools(wire) {
                warnings.append(
                    "OpenRouter model `\(id)` omitted: does not advertise tool calling"
                )
                continue
            }

            let key = catalogKey(modelID: id)
            let name = wire.name ?? id
            let reasoningEfforts = supportsReasoning(wire) ? openRouterReasoningEfforts() : []

            var info = ModelInfo.fallback(slug: key)
            info.id = key
            info.model = id
            info.baseURL = trimTrailingSlashes(baseURL)
            info.name = name
            info.description = wire.description
            info.apiBackend = .chatCompletions
            info.authScheme = .bearer
            info.provider = .openRouter
            info.toolMode = .direct
            info.extraHeaders = [("HTTP-Referer", httpReferer), ("X-Title", appTitle)]
            info.contextWindow = contextWindow(wire)
            info.maxCompletionTokens = maxCompletionTokens(wire)
            info.supportedInApi = true
            info.supportsReasoningEffort = !reasoningEfforts.isEmpty
            info.reasoningEfforts = reasoningEfforts
            info.reasoningEffort = reasoningEfforts.first(where: \.isDefault)?.value

            entries[key] = ModelEntry(info: info, envKey: .single(apiKeyEnv))
            descriptors.append(
                OpenRouterModelDescriptor(
                    key: key,
                    id: id,
                    name: name,
                    apiBackend: .chatCompletions,
                    pricing: wire.pricing?.value
                )
            )
        }

        descriptors.sort { left, right in
            left.name == right.name ? left.id < right.id : left.name < right.name
        }
        return (entries, descriptors, warnings)
    }

    private static func hasTextOutput(_ wire: OpenRouterWireModel) -> Bool {
        guard let architecture = wire.architecture else { return true }
        if !architecture.outputModalities.isEmpty {
            return architecture.outputModalities.contains { $0.lowercased() == "text" }
        }
        guard let modality = architecture.modality?.lowercased() else { return true }
        return !modality.contains("embedding")
            && !modality.contains("->image")
            && !modality.contains("->audio")
            && !modality.contains("->video")
    }

    private static func supportsTools(_ wire: OpenRouterWireModel) -> Bool {
        wire.supportedParameters.isEmpty
            || wire.supportedParameters.contains { $0.lowercased() == "tools" }
    }

    private static func supportsReasoning(_ wire: OpenRouterWireModel) -> Bool {
        wire.supportedParameters.contains {
            let parameter = $0.lowercased()
            return parameter == "reasoning" || parameter == "reasoning_effort"
        }
    }

    private static func contextWindow(_ wire: OpenRouterWireModel) -> UInt64 {
        let available = wire.contextLength ?? wire.topProvider?.contextLength
        guard let available, available > 0 else { return fallbackContextWindow }
        return available
    }

    private static func maxCompletionTokens(_ wire: OpenRouterWireModel) -> UInt32? {
        guard let available = wire.topProvider?.maxCompletionTokens,
              available > 0,
              available <= UInt64(UInt32.max) else {
            return nil
        }
        return UInt32(available)
    }

    private static func openRouterReasoningEfforts() -> [ReasoningEffortOption] {
        let options: [(ReasoningEffort, String, Bool)] = [
            (.none, "None", false),
            (.low, "Low", false),
            (.medium, "Medium", true),
            (.high, "High", false),
            (.xhigh, "Xhigh", false),
        ]
        return options.map { effort, label, isDefault in
            ReasoningEffortOption(
                id: effort.asString,
                value: effort,
                label: label,
                description: nil,
                isDefault: isDefault
            )
        }
    }
}

private struct OpenRouterWireResponse: Decodable {
    var data: [OpenRouterWireModel]

    enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = container.contains(.data)
            ? try container.decode([OpenRouterWireModel].self, forKey: .data)
            : []
    }
}

private struct OpenRouterWireModel: Decodable {
    var id: String
    var name: String?
    var description: String?
    var contextLength: UInt64?
    var architecture: OpenRouterWireArchitecture?
    var topProvider: OpenRouterWireTopProvider?
    var supportedParameters: [String]
    var pricing: OpenRouterWirePricing?

    enum CodingKeys: String, CodingKey {
        case id, name, description, architecture, pricing
        case contextLength = "context_length"
        case topProvider = "top_provider"
        case supportedParameters = "supported_parameters"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        contextLength = try container.decodeIfPresent(UInt64.self, forKey: .contextLength)
        architecture = try container.decodeIfPresent(
            OpenRouterWireArchitecture.self,
            forKey: .architecture
        )
        topProvider = try container.decodeIfPresent(
            OpenRouterWireTopProvider.self,
            forKey: .topProvider
        )
        supportedParameters = container.contains(.supportedParameters)
            ? try container.decode([String].self, forKey: .supportedParameters)
            : []

        // Pricing is additive metadata, not a Rust catalog eligibility condition.
        // Preserve the model when a provider introduces a new price representation.
        do {
            pricing = try container.decodeIfPresent(OpenRouterWirePricing.self, forKey: .pricing)
        } catch {
            pricing = nil
        }
    }
}

private struct OpenRouterWireArchitecture: Decodable {
    var modality: String?
    var outputModalities: [String]

    enum CodingKeys: String, CodingKey {
        case modality
        case outputModalities = "output_modalities"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modality = try container.decodeIfPresent(String.self, forKey: .modality)
        outputModalities = container.contains(.outputModalities)
            ? try container.decode([String].self, forKey: .outputModalities)
            : []
    }
}

private struct OpenRouterWireTopProvider: Decodable {
    var contextLength: UInt64?
    var maxCompletionTokens: UInt64?

    enum CodingKeys: String, CodingKey {
        case contextLength = "context_length"
        case maxCompletionTokens = "max_completion_tokens"
    }
}

private struct OpenRouterWirePricing: Decodable {
    var value: OpenRouterModelPricing?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OpenRouterModelPricing.CodingKeys.self)
        let pricing = OpenRouterModelPricing(
            prompt: Self.amount(container, key: .prompt),
            completion: Self.amount(container, key: .completion),
            request: Self.amount(container, key: .request),
            image: Self.amount(container, key: .image),
            webSearch: Self.amount(container, key: .webSearch),
            internalReasoning: Self.amount(container, key: .internalReasoning),
            inputCacheRead: Self.amount(container, key: .inputCacheRead),
            inputCacheWrite: Self.amount(container, key: .inputCacheWrite)
        )
        value = pricing.containsAnyAmount ? pricing : nil
    }

    private static func amount(
        _ container: KeyedDecodingContainer<OpenRouterModelPricing.CodingKeys>,
        key: OpenRouterModelPricing.CodingKeys
    ) -> Decimal? {
        if let text = try? container.decode(String.self, forKey: key),
           let value = Decimal(
               string: text.trimmingCharacters(in: .whitespacesAndNewlines),
               locale: Locale(identifier: "en_US_POSIX")
           ),
           value >= Decimal(0) {
            return value
        }
        if let value = try? container.decode(Decimal.self, forKey: key),
           value >= Decimal(0) {
            return value
        }
        return nil
    }
}
