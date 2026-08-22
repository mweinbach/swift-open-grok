// CustomModelStore.swift
//
// Open Grok — Custom model record persistence and catalog integration.
// Swift port of `xai-grok-shell/src/custom_models.rs` and the custom-model
// store methods in `xai-grok-shell/src/agent/models.rs`.
//
// Manages `$OPENGROK_HOME/custom_models.json` atomically and merges custom
// model definitions into active and refreshed catalogs.

import Foundation
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

    public init(
        key: String,
        modelId: String,
        provider: String = "xai",
        baseUrl: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEfforts: [String]? = nil
    ) {
        self.key = key
        self.modelId = modelId
        self.provider = provider
        self.baseUrl = baseUrl
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEfforts = reasoningEfforts
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

        // Alternate / camelCase decoding aliases
        case modelIdCamel = "modelId"
        case modelAlias = "model"
        case baseUrlCamel = "baseUrl"
        case contextWindowCamel = "contextWindow"
        case maxOutputTokensCamel = "maxOutputTokens"
        case maxCompletionTokens = "max_completion_tokens"
        case reasoningEffortsCamel = "reasoningEfforts"
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
    }

    // MARK: Conversion Helpers

    /// Convert this custom model entry into a runtime `ModelInfo`.
    public func toModelInfo() -> ModelInfo {
        let parsedProvider = parseCustomModelProvider(provider) ?? .xai
        let defaultBackend: ApiBackend
        switch parsedProvider {
        case .codex, .meta:
            defaultBackend = .responses
        case .xai, .kimi, .fireworks, .deepseek, .openCodeGo, .wafer, .zai:
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
            name: key,
            maxCompletionTokens: maxOutputTokens.map(UInt32.init),
            apiBackend: defaultBackend,
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
            envKey: customModelDefaultEnvKey(for: parsedProvider)
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
            name: key,
            envKey: customModelDefaultEnvKey(for: parsedProvider),
            maxCompletionTokens: maxOutputTokens.map(UInt32.init),
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
    case "kimi", "moonshot", "moonshot_ai": return .kimi
    case "fireworks", "fireworks_ai": return .fireworks
    case "deepseek", "deep_seek", "deepseek_api": return .deepseek
    case "meta", "meta_ai", "meta_api": return .meta
    case "opencode_go", "opencode-go", "open_code_go": return .openCodeGo
    case "wafer", "wafer_ai": return .wafer
    case "zai", "z_ai", "z-ai", "zai_api", "glm": return .zai
    default: return nil
    }
}

private func customModelDefaultBaseURL(for provider: ModelProvider) -> String? {
    switch provider {
    case .wafer:
        return WaferModels.apiBaseURL()
    case .zai:
        return ZaiModels.apiBaseURL()
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
    let fileURL = grokHome.appendingPathComponent("custom_models.json")
    return try loadValidatedCustomModels(at: fileURL).map { entry in
        (entry.key, entry.toConfigModelOverride())
    }
}

private func loadValidatedCustomModels(at fileURL: URL) throws -> [CustomModelEntry] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return [] }

    let decoder = JSONDecoder()
    let decoded: [CustomModelEntry]
    if let array = try? decoder.decode([CustomModelEntry].self, from: data) {
        decoded = array
    } else if let dict = try? decoder.decode([String: CustomModelEntry].self, from: data) {
        decoded = Array(dict.values).sorted { $0.key < $1.key }
    } else {
        throw CustomModelStoreError.persistenceFailure("custom_models.json contains invalid JSON")
    }

    for entry in decoded {
        try validateCustomModelKey(entry.key)
        try validateCustomModelId(entry.modelId)
        guard parseCustomModelProvider(entry.provider) != nil else {
            throw CustomModelStoreError.invalidProvider(entry.provider)
        }
    }
    return decoded
}

// MARK: - CustomModelStore

/// Thread-safe actor managing persistent custom model records stored in
/// `$OPENGROK_HOME/custom_models.json`.
public actor CustomModelStore {
    /// File URL where custom models are stored on disk.
    public let fileURL: URL

    private var entries: [CustomModelEntry] = []
    private var isLoaded = false

    /// Initialize with a custom file URL or standard Grok home directory.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Initialize with an optional grokHome URL or environment-resolved OPENGROK_HOME.
    public init(grokHome: URL? = nil) {
        if let grokHome {
            self.fileURL = grokHome.appendingPathComponent("custom_models.json")
        } else {
            let home = OpenGrokStatePaths.stateDirectory(environment: ProcessInfo.processInfo.environment)
            self.fileURL = home.appendingPathComponent("custom_models.json")
        }
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

        try validateCustomModelKey(trimmedKey)
        try validateCustomModelId(trimmedModelId)

        let providerName = trimmedProvider.isEmpty ? "xai" : trimmedProvider
        guard let normalizedProvider = parseCustomModelProvider(providerName) else {
            throw CustomModelStoreError.invalidProvider(providerName)
        }

        if let cw = entry.contextWindow, cw <= 0 {
            throw CustomModelStoreError.invalidContextWindow(cw)
        }
        if let mot = entry.maxOutputTokens, mot <= 0 {
            throw CustomModelStoreError.invalidMaxOutputTokens(mot)
        }

        let normalizedEntry = CustomModelEntry(
            key: trimmedKey,
            modelId: trimmedModelId,
            provider: normalizedProvider.asString,
            baseUrl: normalizedBaseUrl ?? customModelDefaultBaseURL(for: normalizedProvider),
            contextWindow: entry.contextWindow,
            maxOutputTokens: entry.maxOutputTokens,
            reasoningEfforts: entry.reasoningEfforts
        )

        let originalEntries = entries
        if let idx = entries.firstIndex(where: { $0.key == trimmedKey }) {
            entries[idx] = normalizedEntry
        } else {
            entries.append(normalizedEntry)
        }

        do {
            try persistToDisk()
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
            try persistToDisk()
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
            try persistToDisk()
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
        let decoded = try loadValidatedCustomModels(at: fileURL)
        entries = decoded
        isLoaded = true
        return decoded
    }

    private func persistToDisk() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(entries)
            try writeAtomicallyData(fileURL, contents: data)
        } catch {
            throw CustomModelStoreError.persistenceFailure(error.localizedDescription)
        }
    }
}
