// OpenCodeGoModels.swift
//
// Provider-isolated OpenCode Go model discovery.
// Port of `crates/codegen/xai-grok-shell/src/opencode_go_models.rs`.
//
// OpenCode Go's `/models` endpoint is authoritative for availability but
// returns model ids only. Canonical models.dev metadata supplies the per-model
// wire protocol and limits. The intersection fails closed when metadata is
// missing or names an unsupported SDK.

import Foundation
import OpenGrokSamplingTypes

/// One OpenCode Go model that survived the availability × metadata
/// intersection, with the wire protocol its metadata selected.
public struct OpenCodeGoModelDescriptor: Sendable, Equatable, Codable {
    public var key: String
    public var id: String
    public var name: String
    public var apiBackend: ApiBackend

    public init(key: String, id: String, name: String, apiBackend: ApiBackend) {
        self.key = key
        self.id = id
        self.name = name
        self.apiBackend = apiBackend
    }

    public enum CodingKeys: String, CodingKey {
        case key, id, name
        case apiBackend = "api_backend"
    }
}

public enum OpenCodeGoModels {
    public static let apiBaseURLDefault = "https://opencode.ai/zen/go/v1"
    public static let apiBaseURLEnv = "OPENGROK_OPENCODE_GO_API_BASE_URL"
    public static let modelsDevURLDefault = "https://models.dev/api.json"
    public static let modelsDevURLEnv = "OPENGROK_OPENCODE_GO_MODELS_DEV_URL"
    public static let apiKeyEnv = "OPENCODE_API_KEY"
    /// Provider key under which models.dev publishes OpenCode Go's catalog.
    public static let modelsDevProviderKey = "opencode-go"
    /// Applied when models.dev omits a context limit for an available model.
    public static let fallbackContextWindow: UInt64 = 200_000

    public static func isTrustedAPIBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return url.host?.lowercased() == "opencode.ai"
    }

    public static func apiBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        trimmedBaseURL(environment[apiBaseURLEnv]) ?? apiBaseURLDefault
    }

    public static func modelsDevURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        nonEmpty(environment[modelsDevURLEnv]) ?? modelsDevURLDefault
    }

    public static func environmentAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        nonEmpty(environment[apiKeyEnv])
    }

    /// A stored OpenCode Go key may only travel to OpenCode-owned hosts.
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
        "opencode-go:\(modelID)"
    }

    /// Map a models.dev SDK identifier to the wire protocol and auth scheme it
    /// implies. An unrecognized SDK yields nil so the model fails closed.
    public static func protocolForSDK(_ sdk: String) -> (ApiBackend, AuthScheme)? {
        switch sdk {
        case "@ai-sdk/anthropic":
            return (.messages, .xApiKey)
        case "@ai-sdk/openai-compatible", "@ai-sdk/openai":
            return (.chatCompletions, .bearer)
        default:
            return nil
        }
    }

    /// Intersect the provider's availability list with models.dev metadata.
    ///
    /// `availableIDs` comes from OpenCode Go's `/models`; `metadata` is the
    /// `opencode-go` entry of the models.dev document. Models without metadata,
    /// or whose metadata names an SDK with no known wire protocol, are dropped
    /// with a warning rather than guessed at.
    public static func catalog(
        availableIDs: [String],
        metadata: ModelsDevProvider,
        baseURL: String
    ) -> (entries: OrderedModelMap, descriptors: [OpenCodeGoModelDescriptor], warnings: [String]) {
        var entries = OrderedModelMap()
        var descriptors: [OpenCodeGoModelDescriptor] = []
        var warnings: [String] = []

        for raw in availableIDs {
            guard let id = nonEmpty(raw) else { continue }
            guard let model = metadata.models[id] else {
                warnings.append("OpenCode Go model `\(id)` has no models.dev metadata")
                continue
            }
            let sdk = model.provider?.npm ?? metadata.npm
            guard let (apiBackend, authScheme) = protocolForSDK(sdk) else {
                warnings.append(
                    "OpenCode Go model `\(id)` uses unsupported SDK metadata `\(sdk)`"
                )
                continue
            }

            let key = catalogKey(modelID: id)
            var info = ModelInfo.fallback(slug: key)
            info.id = key
            info.model = id
            info.baseURL = trimTrailingSlashes(baseURL)
            let name = model.name ?? id
            info.name = name
            info.description = model.description
            // `limit.output` deliberately does NOT map to `maxCompletionTokens`
            // (the `.58` delta removed the mapping; opencode_go_models.rs:243-259
            // assigns none): models.dev advertises 1M-scale output caps that
            // became oversized default request limits on the wire.
            info.apiBackend = apiBackend
            info.authScheme = authScheme
            info.provider = .openCodeGo
            info.toolMode = .direct
            info.contextWindow = model.limit?.context.flatMap { $0 > 0 ? $0 : nil }
                ?? fallbackContextWindow
            info.supportedInApi = true
            info.supportsReasoningEffort = false
            info.reasoningEfforts = []
            info.reasoningEffort = nil

            entries[key] = ModelEntry(info: info, envKey: .single(apiKeyEnv))
            descriptors.append(
                OpenCodeGoModelDescriptor(key: key, id: id, name: name, apiBackend: apiBackend)
            )
        }

        descriptors.sort { left, right in
            left.name == right.name ? left.id < right.id : left.name < right.name
        }
        return (entries, descriptors, warnings)
    }

    /// Parse the id list from an OpenCode Go `/models` response.
    public static func parseAvailableIDs(_ data: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelsError.remoteMalformed("opencode-go /models response was not an object")
        }
        let arr = root["data"] as? [[String: Any]] ?? []
        return arr.compactMap { nonEmpty($0["id"] as? String) }
    }

    /// Extract the `opencode-go` provider entry from a models.dev document.
    public static func parseModelsDev(_ data: Data) throws -> ModelsDevProvider {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelsError.remoteMalformed("models.dev response was not an object")
        }
        guard let provider = root[modelsDevProviderKey] as? [String: Any] else {
            throw ModelsError.remoteMalformed(
                "models.dev did not contain the opencode-go provider"
            )
        }
        return ModelsDevProvider(json: provider)
    }

    public static func safeErrorExcerpt(_ body: String, apiKey: String) -> String {
        WaferModels.safeErrorExcerpt(body, apiKey: apiKey)
    }
}

// MARK: - models.dev metadata

/// One provider entry of the models.dev document, narrowed to the fields the
/// OpenCode Go intersection reads.
public struct ModelsDevProvider: Sendable, Equatable {
    /// SDK package that applies to every model this provider serves, unless a
    /// model overrides it.
    public var npm: String
    public var models: [String: ModelsDevModel]

    public init(npm: String, models: [String: ModelsDevModel]) {
        self.npm = npm
        self.models = models
    }

    public init(json: [String: Any]) {
        self.npm = (json["npm"] as? String) ?? ""
        var models: [String: ModelsDevModel] = [:]
        for (id, value) in (json["models"] as? [String: Any]) ?? [:] {
            guard let obj = value as? [String: Any] else { continue }
            models[id] = ModelsDevModel(json: obj)
        }
        self.models = models
    }
}

public struct ModelsDevModel: Sendable, Equatable {
    public var name: String?
    public var description: String?
    /// Per-model SDK override; when absent the provider-level `npm` applies.
    public var provider: ModelsDevModelProvider?
    public var limit: ModelsDevLimit?

    public init(
        name: String? = nil,
        description: String? = nil,
        provider: ModelsDevModelProvider? = nil,
        limit: ModelsDevLimit? = nil
    ) {
        self.name = name
        self.description = description
        self.provider = provider
        self.limit = limit
    }

    public init(json: [String: Any]) {
        self.name = json["name"] as? String
        self.description = json["description"] as? String
        if let providerObj = json["provider"] as? [String: Any] {
            self.provider = ModelsDevModelProvider(npm: providerObj["npm"] as? String)
        } else {
            self.provider = nil
        }
        if let limitObj = json["limit"] as? [String: Any] {
            self.limit = ModelsDevLimit(
                context: (limitObj["context"] as? NSNumber)?.uint64Value,
                output: (limitObj["output"] as? NSNumber)?.uint64Value
            )
        } else {
            self.limit = nil
        }
    }
}

public struct ModelsDevModelProvider: Sendable, Equatable {
    public var npm: String?

    public init(npm: String?) {
        self.npm = npm
    }
}

public struct ModelsDevLimit: Sendable, Equatable {
    public var context: UInt64?
    /// Parsed but deliberately unused — upstream renamed the field `_output`
    /// while keeping the JSON key (opencode_go_models.rs:344-350) so the
    /// document still round-trips without the value ever reaching
    /// `maxCompletionTokens`. Wiring it back up re-creates the oversized
    /// request-limit bug the `.58` delta removed.
    public var output: UInt64?

    public init(context: UInt64?, output: UInt64?) {
        self.context = context
        self.output = output
    }
}

/// Provider-isolated OpenCode Go catalog snapshot.
public struct OpenCodeGoModelsCatalog: Sendable, Equatable {
    public var entries: OrderedModelMap
    public var descriptors: [OpenCodeGoModelDescriptor]
    public var warnings: [String]
    public var credentialFingerprint: String

    public init(
        entries: OrderedModelMap,
        descriptors: [OpenCodeGoModelDescriptor],
        warnings: [String],
        credentialFingerprint: String
    ) {
        self.entries = entries
        self.descriptors = descriptors
        self.warnings = warnings
        self.credentialFingerprint = credentialFingerprint
    }

    public var isAuthoritative: Bool { true }

    public func matchesCredential(fingerprint: String) -> Bool {
        credentialFingerprint == fingerprint
    }
}
