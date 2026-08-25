// CustomModelStore.swift
//
// Open Grok — Custom model record persistence and catalog integration.
// Swift port of `xai-grok-shell/src/custom_models.rs` and the custom-model
// store methods in `xai-grok-shell/src/agent/models.rs`.
//
// Manages upstream's `[model.<key>]` tables in `$OPENGROK_HOME/config.toml`
// atomically and migrates the Swift port's former `custom_models.json` store.

import Foundation
import OpenGrokConfig
import OpenGrokPaths
import OpenGrokSamplingTypes

// MARK: - CustomModelStoreError

/// Errors emitted during custom model validation or storage operations.
public enum CustomModelStoreError: Error, CustomStringConvertible, Equatable, Sendable {
    case emptyKey
    case emptyModelId
    case keyContainsNewlines
    case modelIdContainsNewlines
    case invalidKeyCharacters(String)
    case invalidProvider(String)
    case invalidBackend(String)
    case invalidContextWindow(Int)
    case invalidMaxOutputTokens(Int)
    case persistenceFailure(String)

    public var description: String {
        switch self {
        case .emptyKey:
            return "Custom model key must be non-empty"
        case .emptyModelId:
            return "Custom model id must be non-empty"
        case .keyContainsNewlines:
            return "Custom model key must not contain newlines"
        case .modelIdContainsNewlines:
            return "Custom model id must not contain newlines"
        case .invalidKeyCharacters(let key):
            return "Custom model key `\(key)` contains invalid characters (expected letters, digits, ':', '.', '-', '_')"
        case .invalidProvider(let provider):
            return "Custom model provider `\(provider)` is unsupported"
        case .invalidBackend(let backend):
            return "Custom model API backend `\(backend)` is unsupported"
        case .invalidContextWindow(let window):
            return "Context window must be greater than 0, got \(window)"
        case .invalidMaxOutputTokens(let tokens):
            return "Max output tokens must be greater than 0, got \(tokens)"
        case .persistenceFailure(let message):
            return "Failed to persist custom models: \(message)"
        }
    }
}

// MARK: - CustomModelEntry

/// A persisted custom model entry.
/// Conforms to `Codable`, `Sendable`, `Identifiable`, and `Equatable`.
public struct CustomModelEntry: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier matching `key`.
    public var id: String { key }

    /// Unique key used in configuration and selection (e.g. "my-ollama", "zai:glm-4").
    public var key: String

    /// Underlying routing slug sent to provider endpoints (e.g. "llama3:latest", "glm-4").
    public var modelId: String

    /// Provider identifier (e.g. "xai", "codex", "zai", "wafer", "deepseek", "kimi", "fireworks", "meta", "opencode_go").
    public var provider: String

    /// Optional custom base URL for the provider endpoint.
    public var baseUrl: String?

    /// Optional context window size in tokens.
    public var contextWindow: Int?

    /// Optional maximum completion / output tokens.
    public var maxOutputTokens: Int?

    /// Optional supported reasoning effort levels (e.g. `["low", "medium", "high"]`).
    public var reasoningEfforts: [String]?

    /// Optional friendly name displayed in the live model picker.
    public var name: String?

    /// Optional canonical wire backend (`chat_completions`, `responses`, or `messages`).
    public var apiBackend: String?

    /// Optional environment-variable name for this model's own credential.
    public var envKey: String?

    public init(
        key: String,
        modelId: String,
        provider: String = "xai",
        baseUrl: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEfforts: [String]? = nil,
        name: String? = nil,
        apiBackend: String? = nil,
        envKey: String? = nil
    ) {
        self.key = key
        self.modelId = modelId
        self.provider = provider
        self.baseUrl = baseUrl
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEfforts = reasoningEfforts
        self.name = name
        self.apiBackend = apiBackend
        self.envKey = envKey
    }

    // MARK: Codable

    public enum CodingKeys: String, CodingKey {
        case key
        case modelId = "model_id"
        case provider
        case baseUrl = "base_url"
        case contextWindow = "context_window"
        case maxOutputTokens = "max_output_tokens"
        case reasoningEfforts = "reasoning_efforts"
        case name
        case apiBackend = "api_backend"
        case envKey = "env_key"

        // Alternate / camelCase decoding aliases
        case modelIdCamel = "modelId"
        case modelAlias = "model"
        case baseUrlCamel = "baseUrl"
        case contextWindowCamel = "contextWindow"
        case maxOutputTokensCamel = "maxOutputTokens"
        case maxCompletionTokens = "max_completion_tokens"
        case reasoningEffortsCamel = "reasoningEfforts"
        case displayName = "display_name"
        case apiBackendCamel = "apiBackend"
        case backend
        case envKeyCamel = "envKey"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)

        if let m = try c.decodeIfPresent(String.self, forKey: .modelId) {
            self.modelId = m
        } else if let m = try c.decodeIfPresent(String.self, forKey: .modelIdCamel) {
            self.modelId = m
        } else if let m = try c.decodeIfPresent(String.self, forKey: .modelAlias) {
            self.modelId = m
        } else {
            self.modelId = try c.decode(String.self, forKey: .modelId)
        }

        self.provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "xai"

        if let b = try c.decodeIfPresent(String.self, forKey: .baseUrl) {
            self.baseUrl = b
        } else {
            self.baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrlCamel)
        }

        if let cw = try c.decodeIfPresent(Int.self, forKey: .contextWindow) {
            self.contextWindow = cw
        } else {
            self.contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindowCamel)
        }

        if let mot = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) {
            self.maxOutputTokens = mot
        } else if let mot = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokensCamel) {
            self.maxOutputTokens = mot
        } else {
            self.maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxCompletionTokens)
        }

        if let re = try c.decodeIfPresent([String].self, forKey: .reasoningEfforts) {
            self.reasoningEfforts = re
        } else {
            self.reasoningEfforts = try c.decodeIfPresent([String].self, forKey: .reasoningEffortsCamel)
        }

        if let name = try c.decodeIfPresent(String.self, forKey: .name) {
            self.name = name
        } else {
            self.name = try c.decodeIfPresent(String.self, forKey: .displayName)
        }
        if let backend = try c.decodeIfPresent(String.self, forKey: .apiBackend) {
            self.apiBackend = backend
        } else if let backend = try c.decodeIfPresent(String.self, forKey: .apiBackendCamel) {
            self.apiBackend = backend
        } else {
            self.apiBackend = try c.decodeIfPresent(String.self, forKey: .backend)
        }
        if let key = try c.decodeIfPresent(String.self, forKey: .envKey) {
            self.envKey = key
        } else {
            self.envKey = try c.decodeIfPresent(String.self, forKey: .envKeyCamel)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(baseUrl, forKey: .baseUrl)
        try c.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try c.encodeIfPresent(reasoningEfforts, forKey: .reasoningEfforts)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(apiBackend, forKey: .apiBackend)
        try c.encodeIfPresent(envKey, forKey: .envKey)
    }

    // MARK: Conversion Helpers

    /// Convert this custom model entry into a runtime `ModelInfo`.
    public func toModelInfo() -> ModelInfo {
        let parsedProvider = parseCustomModelProvider(provider) ?? .xai
        let defaultBackend: ApiBackend
        switch parsedProvider {
        case .codex, .meta:
            defaultBackend = .responses
        case .xai, .kimi, .fireworks, .deepseek, .openCodeGo, .wafer, .zai,
             .runinfra, .gemini, .openRouter:
            defaultBackend = .chatCompletions
        }

        let effortOptions: [ReasoningEffortOption] = (reasoningEfforts ?? []).compactMap { str in
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let effort = ReasoningEffort(rawValue: trimmed) else { return nil }
            return ReasoningEffortOption(
                id: effort.asString,
                value: effort,
                label: humanizeReasoningEffort(effort.asString),
                description: nil,
                isDefault: false
            )
        }

        var info = ModelInfo(
            id: key,
            model: modelId,
            baseURL: baseUrl ?? customModelDefaultBaseURL(for: parsedProvider) ?? "",
            name: name ?? key,
            maxCompletionTokens: maxOutputTokens.map(UInt32.init),
            apiBackend: apiBackend.flatMap(parseCustomModelBackend) ?? defaultBackend,
            provider: parsedProvider,
            contextWindow: contextWindow.map(UInt64.init) ?? NEW_MODEL_DEFAULT_CONTEXT_WINDOW,
            userSelectable: true,
            supportedInApi: true,
            supportsReasoningEffort: !effortOptions.isEmpty,
            reasoningEfforts: effortOptions
        )
        info.deriveReasoningEffortFields()
        return info
    }

    /// Convert this custom model entry into a runtime `ModelEntry`.
    public func toModelEntry() -> ModelEntry {
        let parsedProvider = parseCustomModelProvider(provider) ?? .xai
        return ModelEntry(
            info: toModelInfo(),
            envKey: envKey.map(EnvKeys.single) ?? customModelDefaultEnvKey(for: parsedProvider)
        )
    }

    /// Convert this custom model entry into a `ConfigModelOverride`.
    public func toConfigModelOverride() -> ConfigModelOverride {
        let parsedProvider = parseCustomModelProvider(provider) ?? .xai
        let effortOptions: [ReasoningEffortOption] = (reasoningEfforts ?? []).compactMap { str in
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let effort = ReasoningEffort(rawValue: trimmed) else { return nil }
            return ReasoningEffortOption(
                id: effort.asString,
                value: effort,
                label: humanizeReasoningEffort(effort.asString),
                description: nil,
                isDefault: false
            )
        }

        return ConfigModelOverride(
            model: modelId,
            baseURL: baseUrl ?? customModelDefaultBaseURL(for: parsedProvider),
            name: name ?? key,
            envKey: envKey.map(EnvKeys.single) ?? customModelDefaultEnvKey(for: parsedProvider),
            maxCompletionTokens: maxOutputTokens.map(UInt32.init),
            apiBackend: apiBackend.flatMap(parseCustomModelBackend),
            provider: parsedProvider,
            contextWindow: contextWindow.map(UInt64.init),
            supportsReasoningEffort: !effortOptions.isEmpty,
            reasoningEfforts: effortOptions
        )
    }
}

// MARK: - Helper Functions

private func parseCustomModelProvider(_ raw: String) -> ModelProvider? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "xai": return .xai
    case "codex", "openai", "openai_codex": return .codex
    case "kimi", "kimi_code", "moonshot", "moonshot_ai": return .kimi
    case "fireworks", "fireworks_ai": return .fireworks
    case "deepseek", "deep_seek", "deepseek_api": return .deepseek
    case "meta", "meta_ai", "meta_api": return .meta
    case "opencode_go", "opencode-go", "open_code_go": return .openCodeGo
    case "wafer", "wafer_ai": return .wafer
    case "zai", "z_ai", "z-ai", "zai_api", "glm": return .zai
    case "runinfra", "run_infra", "run-infra": return .runinfra
    case "gemini", "google", "google_gemini", "ai_studio", "aistudio", "gemini_api":
        return .gemini
    case "openrouter", "open_router", "open-router": return .openRouter
    default: return nil
    }
}

private func parseCustomModelBackend(_ raw: String) -> ApiBackend? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "chat_completions", "chat-completions": return .chatCompletions
    case "responses": return .responses
    case "messages": return .messages
    default: return nil
    }
}

private func canonicalCustomModelBackend(_ backend: ApiBackend) -> String {
    switch backend {
    case .chatCompletions: return "chat_completions"
    case .responses: return "responses"
    case .messages: return "messages"
    }
}

private func customModelDefaultBaseURL(for provider: ModelProvider) -> String? {
    switch provider {
    case .wafer:
        return WaferModels.apiBaseURL()
    case .zai:
        return ZaiModels.apiBaseURL()
    case .runinfra:
        return RunInfraModels.apiBaseURL()
    case .gemini:
        return GeminiModels.apiBaseURL()
    case .openRouter:
        return OpenRouterModels.apiBaseURL()
    case .xai, .codex, .kimi, .fireworks, .deepseek, .meta, .openCodeGo:
        return nil
    }
}

private func customModelDefaultEnvKey(for provider: ModelProvider) -> EnvKeys? {
    switch provider {
    case .wafer:
        return .single(WaferModels.apiKeyEnv)
    case .zai:
        return .single(ZaiModels.apiKeyEnv)
    case .runinfra:
        return .new([RunInfraModels.gatewayKeyEnv, RunInfraModels.apiKeyEnv])
    case .gemini:
        return .new([GeminiModels.apiKeyEnv, GeminiModels.googleAPIKeyEnv])
    case .openRouter:
        return .single(OpenRouterModels.apiKeyEnv)
    case .xai, .codex, .kimi, .fireworks, .deepseek, .meta, .openCodeGo:
        return nil
    }
}

private func humanizeReasoningEffort(_ id: String) -> String {
    switch id.lowercased() {
    case "none": return "None"
    case "minimal": return "Minimal"
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "Extra High"
    case "max": return "Maximum"
    case "ultra": return "Ultra"
    default: return id.capitalized
    }
}

private func validateCustomModelKey(_ key: String) throws {
    if key.isEmpty {
        throw CustomModelStoreError.emptyKey
    }
    if key.contains(where: { $0.isNewline }) {
        throw CustomModelStoreError.keyContainsNewlines
    }
    for ch in key {
        guard ch.isASCII && (ch.isLetter || ch.isNumber || ch == ":" || ch == "." || ch == "-" || ch == "_") else {
            throw CustomModelStoreError.invalidKeyCharacters(key)
        }
    }
}

private func validateCustomModelId(_ modelId: String) throws {
    if modelId.isEmpty {
        throw CustomModelStoreError.emptyModelId
    }
    if modelId.contains(where: { $0.isNewline }) {
        throw CustomModelStoreError.modelIdContainsNewlines
    }
}

/// Synchronously project persisted custom records onto the normal `[model.*]`
/// catalog input. Session startup and settings reload are synchronous seams;
/// leaving this read actor-only made a successfully saved model unreachable.
public func loadCustomModelOverrides(
    grokHome: URL
) throws -> [(String, ConfigModelOverride)] {
    let configURL = grokHome.appendingPathComponent("config.toml")
    let legacyURL = grokHome.appendingPathComponent("custom_models.json")
    let entries = try loadValidatedCustomModels(at: configURL, legacyFileURL: legacyURL)
    guard !entries.isEmpty else { return [] }
    let document = try parseTOML(Data(contentsOf: configURL))
    let keys = Set(entries.map(\.key))
    return parseConfiguredModelCatalog(from: document).modelOverrides.filter { keys.contains($0.0) }
}

private func decodeLegacyCustomModels(_ data: Data, path: URL) throws -> [CustomModelEntry] {
    let decoder = JSONDecoder()
    let decoded: [CustomModelEntry]
    if let array = try? decoder.decode([CustomModelEntry].self, from: data) {
        decoded = array
    } else if let dict = try? decoder.decode([String: CustomModelEntry].self, from: data) {
        decoded = Array(dict.values).sorted { $0.key < $1.key }
    } else {
        throw CustomModelStoreError.persistenceFailure(
            "\(path.lastPathComponent) contains invalid custom-model JSON"
        )
    }

    return decoded
}

private func validatedCustomModelEntries(_ decoded: [CustomModelEntry]) throws -> [CustomModelEntry] {
    for entry in decoded {
        try validateCustomModelKey(entry.key)
        try validateCustomModelId(entry.modelId)
        guard parseCustomModelProvider(entry.provider) != nil else {
            throw CustomModelStoreError.invalidProvider(entry.provider)
        }
        if let backend = entry.apiBackend, parseCustomModelBackend(backend) == nil {
            throw CustomModelStoreError.invalidBackend(backend)
        }
    }
    return decoded
}

private func customModelEntry(key: String, table: TOMLTable) -> CustomModelEntry? {
    let modelID = table["model"]?.stringValue
        ?? table["model_id"]?.stringValue
        ?? key
    let provider = table["provider"]?.stringValue
        ?? key.split(separator: ":", maxSplits: 1).first
            .map(String.init)
            .flatMap(parseCustomModelProvider)
            .map(\.asString)
        ?? "xai"
    let outputTokens = table["max_completion_tokens"]?.int64Value
        ?? table["max_output_tokens"]?.int64Value
    let efforts = table["reasoning_efforts"]?.arrayValue?.compactMap(\.stringValue)
    let envKey = table["env_key"]?.stringValue
        ?? table["env_key"]?.arrayValue?.compactMap(\.stringValue).first
    return CustomModelEntry(
        key: key,
        modelId: modelID,
        provider: provider,
        baseUrl: table["base_url"]?.stringValue,
        contextWindow: table["context_window"]?.int64Value.flatMap(Int.init(exactly:)),
        maxOutputTokens: outputTokens.flatMap(Int.init(exactly:)),
        reasoningEfforts: efforts,
        name: table["name"]?.stringValue,
        apiBackend: table["api_backend"]?.stringValue,
        envKey: envKey
    )
}

private func customModelEntries(from root: TOMLValue) throws -> [CustomModelEntry] {
    guard let section = root["model"] else { return [] }
    guard let models = section.table else {
        throw CustomModelStoreError.persistenceFailure("[model] is not a TOML table")
    }
    let entries = models.pairs.compactMap { key, value in
        value.table.flatMap { customModelEntry(key: key, table: $0) }
    }
    return try validatedCustomModelEntries(entries)
}

private func readCustomModelRoot(at fileURL: URL) throws -> (TOMLValue, [CustomModelEntry]?) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return (.table(TOMLTable()), nil)
    }
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return (.table(TOMLTable()), nil) }
    do {
        let root = try parseTOML(data)
        guard root.isTable else {
            throw CustomModelStoreError.persistenceFailure("config root is not a TOML table")
        }
        return (root, nil)
    } catch {
        if let legacy = try? decodeLegacyCustomModels(data, path: fileURL) {
            return (.table(TOMLTable()), try validatedCustomModelEntries(legacy))
        }
        throw CustomModelStoreError.persistenceFailure(
            "refusing to overwrite unparseable \(fileURL.lastPathComponent): \(error)"
        )
    }
}

private func upsertCustomModelTable(_ entry: CustomModelEntry, in root: inout TOMLValue) throws {
    guard var rootTable = root.table else {
        throw CustomModelStoreError.persistenceFailure("config root is not a TOML table")
    }
    var modelTable: TOMLTable
    switch rootTable["model"] {
    case .none:
        modelTable = TOMLTable()
    case .some(let section):
        guard let table = section.table else {
            throw CustomModelStoreError.persistenceFailure("[model] is not a TOML table")
        }
        modelTable = table
    }

    var entryTable = modelTable[entry.key]?.table ?? TOMLTable()
    entryTable.insert(.string(entry.modelId), forKey: "model")
    entryTable.insert(.string(entry.provider), forKey: "provider")
    if let name = entry.name { entryTable.insert(.string(name), forKey: "name") }
    if let baseURL = entry.baseUrl { entryTable.insert(.string(baseURL), forKey: "base_url") }
    if let contextWindow = entry.contextWindow {
        entryTable.insert(.integer(Int64(contextWindow)), forKey: "context_window")
    }
    if let outputTokens = entry.maxOutputTokens {
        entryTable.insert(.integer(Int64(outputTokens)), forKey: "max_completion_tokens")
    }
    if let reasoningEfforts = entry.reasoningEfforts {
        entryTable.insert(.array(reasoningEfforts.map(TOMLValue.string)), forKey: "reasoning_efforts")
    }
    if let backend = entry.apiBackend {
        entryTable.insert(.string(backend), forKey: "api_backend")
    }
    if let envKey = entry.envKey {
        entryTable.insert(.string(envKey), forKey: "env_key")
        entryTable.removeValue(forKey: "api_key")
    }
    modelTable.insert(.table(entryTable), forKey: entry.key)
    rootTable.insert(.table(modelTable), forKey: "model")
    root = .table(rootTable)
}

private func removeCustomModelTable(_ key: String, from root: inout TOMLValue) -> Bool {
    guard var rootTable = root.table,
          var modelTable = rootTable["model"]?.table,
          modelTable.removeValue(forKey: key) != nil
    else { return false }
    if modelTable.isEmpty {
        rootTable.removeValue(forKey: "model")
    } else {
        rootTable.insert(.table(modelTable), forKey: "model")
    }
    root = .table(rootTable)
    return true
}

private func writeCustomModelRoot(_ root: TOMLValue, to fileURL: URL) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try writeAtomically(fileURL, contents: TOMLEncoder.encode(root), mode: 0o600)
}

private func loadValidatedCustomModels(
    at fileURL: URL,
    legacyFileURL: URL? = nil
) throws -> [CustomModelEntry] {
    let (initialRoot, inlineLegacy) = try readCustomModelRoot(at: fileURL)
    var root = initialRoot
    var legacyEntries = inlineLegacy ?? []
    var shouldMigrate = inlineLegacy != nil

    if let legacyFileURL,
       legacyFileURL != fileURL,
       FileManager.default.fileExists(atPath: legacyFileURL.path) {
        let data = try Data(contentsOf: legacyFileURL)
        let decoded = try decodeLegacyCustomModels(data, path: legacyFileURL)
        legacyEntries.append(contentsOf: try validatedCustomModelEntries(decoded))
        shouldMigrate = true
    }

    if shouldMigrate {
        let canonicalKeys = Set(try customModelEntries(from: root).map(\.key))
        var migratedKeys = canonicalKeys
        for entry in legacyEntries where migratedKeys.insert(entry.key).inserted {
            try upsertCustomModelTable(entry, in: &root)
        }
        try writeCustomModelRoot(root, to: fileURL)
        if let legacyFileURL,
           legacyFileURL != fileURL,
           FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try FileManager.default.removeItem(at: legacyFileURL)
        }
    }

    return try customModelEntries(from: root)
}

// MARK: - CustomModelStore

/// Thread-safe actor managing upstream's `[model.<key>]` config tables.
public actor CustomModelStore {
    /// Canonical TOML document holding the custom-model tables.
    public let fileURL: URL
    private let legacyFileURL: URL?

    private var entries: [CustomModelEntry] = []
    private var isLoaded = false

    /// Initialize with a custom file URL or standard Grok home directory.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.legacyFileURL = fileURL.lastPathComponent == "config.toml"
            ? fileURL.deletingLastPathComponent().appendingPathComponent("custom_models.json")
            : nil
    }

    /// Initialize with an optional grokHome URL or environment-resolved OPENGROK_HOME.
    public init(grokHome: URL? = nil) {
        let home: URL
        if let grokHome {
            home = grokHome
        } else {
            home = OpenGrokStatePaths.stateDirectory(environment: ProcessInfo.processInfo.environment)
        }
        self.fileURL = home.appendingPathComponent("config.toml")
        self.legacyFileURL = home.appendingPathComponent("custom_models.json")
    }

    // MARK: - CRUD Methods

    /// List all custom model entries currently known.
    public func listCustomModels() async -> [CustomModelEntry] {
        if !isLoaded {
            _ = try? loadFromDisk()
        }
        return entries
    }

    /// Get a specific custom model entry by its key.
    public func getCustomModel(key: String) async -> CustomModelEntry? {
        if !isLoaded {
            _ = try? loadFromDisk()
        }
        return entries.first(where: { $0.key == key })
    }

    /// Upsert a custom model entry into storage.
    ///
    /// Validates the entry, updates in-memory cache, and atomically persists to disk.
    public func upsertCustomModel(_ entry: CustomModelEntry) async throws {
        if !isLoaded {
            try loadFromDisk()
        }

        let trimmedKey = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelId = entry.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = entry.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseUrl = entry.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseUrl = (trimmedBaseUrl?.isEmpty == true) ? nil : trimmedBaseUrl
        let trimmedName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = trimmedName?.isEmpty == true ? nil : trimmedName
        let trimmedBackend = entry.apiBackend?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnvKey = entry.envKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        try validateCustomModelKey(trimmedKey)
        try validateCustomModelId(trimmedModelId)

        let providerName = trimmedProvider.isEmpty ? "xai" : trimmedProvider
        guard let normalizedProvider = parseCustomModelProvider(providerName) else {
            throw CustomModelStoreError.invalidProvider(providerName)
        }
        let normalizedBackend: String?
        if let trimmedBackend, !trimmedBackend.isEmpty {
            guard let backend = parseCustomModelBackend(trimmedBackend) else {
                throw CustomModelStoreError.invalidBackend(trimmedBackend)
            }
            normalizedBackend = canonicalCustomModelBackend(backend)
        } else {
            normalizedBackend = nil
        }

        if let cw = entry.contextWindow, cw <= 0 {
            throw CustomModelStoreError.invalidContextWindow(cw)
        }
        if let mot = entry.maxOutputTokens, mot <= 0 {
            throw CustomModelStoreError.invalidMaxOutputTokens(mot)
        }

        let defaultBaseURL = customModelDefaultBaseURL(for: normalizedProvider)
        let normalizedEnvKey: String?
        if let trimmedEnvKey, !trimmedEnvKey.isEmpty {
            normalizedEnvKey = trimmedEnvKey
        } else if normalizedBaseUrl == nil, defaultBaseURL != nil {
            normalizedEnvKey = customModelDefaultEnvKey(for: normalizedProvider)?.primary
        } else {
            normalizedEnvKey = nil
        }
        let normalizedEntry = CustomModelEntry(
            key: trimmedKey,
            modelId: trimmedModelId,
            provider: normalizedProvider.asString,
            baseUrl: normalizedBaseUrl ?? defaultBaseURL,
            contextWindow: entry.contextWindow,
            maxOutputTokens: entry.maxOutputTokens,
            reasoningEfforts: entry.reasoningEfforts,
            name: normalizedName,
            apiBackend: normalizedBackend,
            envKey: normalizedEnvKey
        )

        let originalEntries = entries
        if let idx = entries.firstIndex(where: { $0.key == trimmedKey }) {
            entries[idx] = normalizedEntry
        } else {
            entries.append(normalizedEntry)
        }

        do {
            try persistToDisk(upserting: normalizedEntry)
        } catch {
            entries = originalEntries
            throw error
        }
    }

    /// Delete a custom model entry by its key.
    ///
    /// Returns `true` if an entry was found and deleted, `false` if not found.
    @discardableResult
    public func deleteCustomModel(key: String) async throws -> Bool {
        if !isLoaded {
            try loadFromDisk()
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = entries.firstIndex(where: { $0.key == trimmedKey }) else {
            return false
        }

        let originalEntries = entries
        entries.remove(at: idx)
        do {
            try persistToDisk(removing: trimmedKey)
        } catch {
            entries = originalEntries
            throw error
        }
        return true
    }

    /// Clear all custom models from memory and disk.
    public func clearAll() async throws {
        if !isLoaded {
            try loadFromDisk()
        }
        let originalEntries = entries
        entries.removeAll()
        isLoaded = true
        do {
            try persistToDisk(clearingAll: true)
        } catch {
            entries = originalEntries
            throw error
        }
    }

    /// Reload models from disk, replacing any in-memory state.
    @discardableResult
    public func reloadFromDisk() async throws -> [CustomModelEntry] {
        try loadFromDisk()
    }

    // MARK: - Merging into Catalogs

    /// Merge custom models into an active `[ModelInfo]` catalog.
    public func mergeCustomModels(into catalog: inout [ModelInfo]) async {
        let models = await listCustomModels()
        Self.mergeCustomModels(models, into: &catalog)
    }

    /// Merge custom models into an `OrderedModelMap`.
    public func mergeCustomModels(into map: inout OrderedModelMap) async {
        let models = await listCustomModels()
        Self.mergeCustomModels(models, into: &map)
    }

    /// Merge an array of `CustomModelEntry` into a `[ModelInfo]` catalog.
    ///
    /// Existing entries matching the custom model key are updated/replaced;
    /// new custom entries are appended.
    public static func mergeCustomModels(_ customModels: [CustomModelEntry], into catalog: inout [ModelInfo]) {
        for custom in customModels {
            guard parseCustomModelProvider(custom.provider) != nil else { continue }
            let customInfo = custom.toModelInfo()
            if let idx = catalog.firstIndex(where: { ($0.id ?? $0.model) == custom.key }) {
                catalog[idx] = customInfo
            } else {
                catalog.append(customInfo)
            }
        }
    }

    /// Merge an array of `CustomModelEntry` into an `OrderedModelMap`.
    public static func mergeCustomModels(_ customModels: [CustomModelEntry], into map: inout OrderedModelMap) {
        for custom in customModels {
            guard parseCustomModelProvider(custom.provider) != nil else { continue }
            let entry = custom.toModelEntry()
            map[custom.key] = entry
        }
    }

    /// Merge an array of `CustomModelEntry` into an array of `ModelEntry`.
    public static func mergeCustomModels(_ customModels: [CustomModelEntry], into entries: inout [ModelEntry]) {
        for custom in customModels {
            guard parseCustomModelProvider(custom.provider) != nil else { continue }
            let customEntry = custom.toModelEntry()
            if let idx = entries.firstIndex(where: { ($0.info.id ?? $0.info.model) == custom.key }) {
                entries[idx] = customEntry
            } else {
                entries.append(customEntry)
            }
        }
    }

    // MARK: - Private Disk I/O

    @discardableResult
    private func loadFromDisk() throws -> [CustomModelEntry] {
        let decoded = try loadValidatedCustomModels(at: fileURL, legacyFileURL: legacyFileURL)
        entries = decoded
        isLoaded = true
        return decoded
    }

    private func persistToDisk(
        upserting entry: CustomModelEntry? = nil,
        removing key: String? = nil,
        clearingAll: Bool = false
    ) throws {
        do {
            let (existingRoot, inlineLegacy) = try readCustomModelRoot(at: fileURL)
            guard inlineLegacy == nil else {
                throw CustomModelStoreError.persistenceFailure(
                    "legacy custom-model JSON must be migrated before writing"
                )
            }
            var root = existingRoot
            if clearingAll {
                if var table = root.table {
                    table.removeValue(forKey: "model")
                    root = .table(table)
                }
            } else if let key {
                let removed = removeCustomModelTable(key, from: &root)
                guard removed else {
                    throw CustomModelStoreError.persistenceFailure(
                        "custom model `\(key)` disappeared before deletion"
                    )
                }
            } else if let entry {
                try upsertCustomModelTable(entry, in: &root)
            }
            try writeCustomModelRoot(root, to: fileURL)
        } catch {
            if let error = error as? CustomModelStoreError { throw error }
            throw CustomModelStoreError.persistenceFailure(error.localizedDescription)
        }
    }
}
