// PagerSettingsStore.swift
//
// Reading settings out of `config.toml` and writing them back.
//
// Ports the shape of `xai-grok-shell/src/util/config/settings_writes.rs` at
// upstream 9ed09e2a: parse the file into a plain value tree, mutate the tree,
// re-serialize, write atomically. The reference has one hand-written helper per
// key; because `PagerSettingMeta` already carries the row's dotted path, this
// needs one generic write instead of ninety, and a key cannot acquire a
// destination that disagrees with the one the modal renders.
//
// What is deliberately not here: secrets, which belong in an owner-protected
// credential store and never touch `config.toml`, and session-local rows, which
// have no on-disk home by design.

import Foundation
import OpenGrokConfig

public enum PagerSettingsStoreError: Error, CustomStringConvertible, Equatable {
    /// The row has no `config.toml` destination — a secret or a session-local.
    case notPersistable(key: String)
    case unknownKey(String)
    /// The value's type does not match the row's kind.
    case typeMismatch(key: String)
    /// A path segment exists but holds a scalar where a table is needed.
    case pathBlocked(path: String)
    case emptyCustomModelKey
    case emptyCustomModelSlug
    case customModelKeyContainsNewlines
    case customModelSlugContainsNewlines
    case invalidCustomModelKeyCharacters(String)

    public var description: String {
        switch self {
        case .notPersistable(let key): return "\(key) is not written to config.toml"
        case .unknownKey(let key): return "unknown setting: \(key)"
        case .typeMismatch(let key): return "wrong value type for \(key)"
        case .pathBlocked(let path): return "\(path) is not a table"
        case .emptyCustomModelKey, .emptyCustomModelSlug: return "Enter a catalog key and model id before saving"
        case .customModelKeyContainsNewlines, .invalidCustomModelKeyCharacters:
            return "✗ Catalog key must be a TOML table suffix (letters, digits, :, ., -, _)"
        case .customModelSlugContainsNewlines:
            return "✗ Model id cannot be empty or contain newlines"
        }
    }
}

/// Draft state for the Custom Models settings sub-sheet.
public struct CustomModelDraft: Sendable, Equatable, Codable {
    public var id: String
    public var slug: String
    public var name: String
    public var provider: String
    public var baseUrl: String
    public var contextWindow: Int
    public var backend: String
    public var envKey: String
    public var save: Bool

    public init(
        id: String = "",
        slug: String = "",
        name: String = "",
        provider: String = "",
        baseUrl: String = "",
        contextWindow: Int = 200_000,
        backend: String = "chat_completions",
        envKey: String = "",
        save: Bool = false
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.provider = provider
        self.baseUrl = baseUrl
        self.contextWindow = contextWindow
        self.backend = backend
        self.envKey = envKey
        self.save = save
    }

    public mutating func clear() {
        self.id = ""
        self.slug = ""
        self.name = ""
        self.provider = ""
        self.baseUrl = ""
        self.contextWindow = 200_000
        self.backend = "chat_completions"
        self.envKey = ""
        self.save = false
    }
}

/// A custom model record stored in `$OPENGROK_HOME/custom_models.json`.
public struct PagerCustomModelRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var modelId: String
    public var provider: String
    public var baseUrl: String?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var reasoningEfforts: [String]?

    public enum CodingKeys: String, CodingKey {
        case key
        case modelId = "model_id"
        case provider
        case baseUrl = "base_url"
        case contextWindow = "context_window"
        case maxOutputTokens = "max_output_tokens"
        case reasoningEfforts = "reasoning_efforts"

        case modelIdCamel = "modelId"
        case modelAlias = "model"
        case baseUrlCamel = "baseUrl"
        case contextWindowCamel = "contextWindow"
        case maxOutputTokensCamel = "maxOutputTokens"
        case maxCompletionTokens = "max_completion_tokens"
        case reasoningEffortsCamel = "reasoningEfforts"
    }

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
}

/// Reads and writes the settings rows that live in `config.toml` and `$OPENGROK_HOME/custom_models.json`.
///
/// Writes are read-modify-write against the file on every call rather than
/// against a cached tree: another process — a second pager, `open-grok config` —
/// may have edited the file since this one loaded it, and re-reading is what
/// keeps a settings toggle from reverting someone else's change.
public struct PagerSettingsStore: Sendable {
    public static let customModelContextWindowMin = 1_000
    public static let customModelContextWindowMax = 4_000_000
    public static let customModelContextWindowDefault = 200_000

    public static let customModelDraftKeys: Set<String> = [
        "custom_model_id",
        "custom_model_slug",
        "custom_model_name",
        "custom_model_provider",
        "custom_model_base_url",
        "custom_model_context_window",
        "custom_model_backend",
        "custom_model_env_key",
        "custom_model_save",
    ]

    public var configPath: URL
    public var registry: PagerSettingsRegistry
    public var customModelsPath: URL

    private static let draftLock = NSLock()
    nonisolated(unsafe) private static var _draftsByPath: [URL: CustomModelDraft] = [:]

    public var draft: CustomModelDraft {
        get {
            Self.draftLock.lock()
            defer { Self.draftLock.unlock() }
            return Self._draftsByPath[customModelsPath] ?? CustomModelDraft()
        }
        set {
            Self.draftLock.lock()
            defer { Self.draftLock.unlock() }
            Self._draftsByPath[customModelsPath] = newValue
        }
    }

    public init(
        configPath: URL,
        registry: PagerSettingsRegistry = .default,
        customModelsPath: URL? = nil
    ) {
        self.configPath = configPath
        self.registry = registry
        self.customModelsPath = customModelsPath ?? configPath.deletingLastPathComponent().appendingPathComponent("custom_models.json")
    }

    // MARK: Draft Management

    public func getDraft() -> CustomModelDraft {
        Self.draftLock.lock()
        defer { Self.draftLock.unlock() }
        return Self._draftsByPath[customModelsPath] ?? CustomModelDraft()
    }

    public mutating func updateDraft(key: String, value: PagerSettingValue) {
        Self.draftLock.lock()
        defer { Self.draftLock.unlock() }
        var current = Self._draftsByPath[customModelsPath] ?? CustomModelDraft()
        switch key {
        case "custom_model_id":
            if case .string(let s) = value { current.id = s }
        case "custom_model_slug":
            if case .string(let s) = value { current.slug = s }
        case "custom_model_name":
            if case .string(let s) = value { current.name = s }
        case "custom_model_provider":
            if case .string(let s) = value { current.provider = s }
        case "custom_model_base_url":
            if case .string(let s) = value { current.baseUrl = s }
        case "custom_model_context_window":
            if case .integer(let n) = value {
                current.contextWindow = min(max(n, Self.customModelContextWindowMin), Self.customModelContextWindowMax)
            }
        case "custom_model_backend":
            if case .string(let s) = value { current.backend = s }
        case "custom_model_env_key":
            if case .string(let s) = value { current.envKey = s }
        case "custom_model_save":
            if case .bool(let b) = value { current.save = b }
        default:
            break
        }
        Self._draftsByPath[customModelsPath] = current
    }

    public mutating func clearDraft() {
        Self.draftLock.lock()
        defer { Self.draftLock.unlock() }
        Self._draftsByPath.removeValue(forKey: customModelsPath)
    }

    public static func validateCustomModelKey(_ key: String) throws {
        if key.isEmpty {
            throw PagerSettingsStoreError.emptyCustomModelKey
        }
        if key.contains(where: { $0.isNewline }) {
            throw PagerSettingsStoreError.customModelKeyContainsNewlines
        }
        for ch in key {
            guard ch.isASCII && (ch.isLetter || ch.isNumber || ch == ":" || ch == "." || ch == "-" || ch == "_") else {
                throw PagerSettingsStoreError.invalidCustomModelKeyCharacters(key)
            }
        }
    }

    public static func validateCustomModelSlug(_ slug: String) throws {
        if slug.isEmpty {
            throw PagerSettingsStoreError.emptyCustomModelSlug
        }
        if slug.contains(where: { $0.isNewline }) {
            throw PagerSettingsStoreError.customModelSlugContainsNewlines
        }
    }

    // MARK: Reading

    /// Load the current value of every row that has one on disk. Rows absent
    /// from the file are left out, so `PagerSettingsOverlay.value(for:)` falls
    /// back to the registered default — which is what "unset" means.
    public func load() throws -> [String: PagerSettingValue] {
        let root = (try? readRoot()) ?? .table(TOMLTable())
        var values: [String: PagerSettingValue] = [:]
        for meta in registry.entries {
            guard let path = persistedPath(for: meta) else { continue }
            guard let stored = root[path: path.split(separator: ".").map(String.init)] else { continue }
            guard let value = decode(stored, as: meta) else { continue }
            values[meta.key] = value
        }
        return values
    }

    /// The enabled entries of a multi-select row, which are stored as an array
    /// rather than a scalar and so do not round-trip through `PagerSettingValue`.
    public func loadMultiSelect(key: String) throws -> Set<String> {
        if key == "custom_models.list" {
            let models = (try? loadCustomModels()) ?? []
            return Set(models.map(\.key))
        }
        guard let meta = registry.find(key), let path = persistedPath(for: meta) else { return [] }
        let root = (try? readRoot()) ?? .table(TOMLTable())
        guard let array = root[path: path.split(separator: ".").map(String.init)]?.arrayValue
        else { return [] }
        return Set(array.compactMap(\.stringValue))
    }

    /// Load all custom model records from `$OPENGROK_HOME/custom_models.json`.
    public func loadCustomModels() throws -> [PagerCustomModelRecord] {
        guard FileManager.default.fileExists(atPath: customModelsPath.path) else { return [] }
        let data = try Data(contentsOf: customModelsPath)
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([PagerCustomModelRecord].self, from: data) {
            return array
        }
        if let dict = try? decoder.decode([String: PagerCustomModelRecord].self, from: data) {
            return Array(dict.values).sorted { $0.key < $1.key }
        }
        return []
    }

    private func writeCustomModelsFile(_ models: [PagerCustomModelRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(models)
        let dir = customModelsPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tempURL = dir.appendingPathComponent(".custom_models.\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        _ = try? FileManager.default.removeItem(at: customModelsPath)
        try FileManager.default.moveItem(at: tempURL, to: customModelsPath)
    }

    /// Save the current custom model draft into `$OPENGROK_HOME/custom_models.json`.
    @discardableResult
    public func saveCustomModelDraft(_ draftToSave: CustomModelDraft? = nil) throws -> PagerCustomModelRecord {
        let draft = draftToSave ?? getDraft()
        let trimmedKey = draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSlug = draft.slug.trimmingCharacters(in: .whitespacesAndNewlines)

        try Self.validateCustomModelKey(trimmedKey)
        try Self.validateCustomModelSlug(trimmedSlug)

        let trimmedProvider = draft.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseUrl = draft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = PagerCustomModelRecord(
            key: trimmedKey,
            modelId: trimmedSlug,
            provider: trimmedProvider.isEmpty ? "xai" : trimmedProvider,
            baseUrl: trimmedBaseUrl.isEmpty ? nil : trimmedBaseUrl,
            contextWindow: draft.contextWindow > 0 ? draft.contextWindow : Self.customModelContextWindowDefault
        )

        var models = (try? loadCustomModels()) ?? []
        if let idx = models.firstIndex(where: { $0.key == trimmedKey }) {
            models[idx] = record
        } else {
            models.append(record)
        }

        try writeCustomModelsFile(models)
        var mutableSelf = self
        mutableSelf.clearDraft()
        return record
    }

    /// Delete a custom model by its key from `$OPENGROK_HOME/custom_models.json`.
    @discardableResult
    public func deleteCustomModel(key: String) throws -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var models = (try? loadCustomModels()) ?? []
        guard let idx = models.firstIndex(where: { $0.key == trimmed }) else {
            return false
        }
        models.remove(at: idx)
        try writeCustomModelsFile(models)
        return true
    }

    private func decode(_ stored: TOMLValue, as meta: PagerSettingMeta) -> PagerSettingValue? {
        switch meta.kind {
        case .bool:
            return stored.boolValue.map(PagerSettingValue.bool)
        case .integer(_, let minimum, let maximum):
            // A hand-edited config can hold anything; clamping here means an
            // out-of-range value shows as the nearest legal one instead of
            // making the stepper start outside its own bounds.
            return stored.int64Value.map { .integer(min(max(Int($0), minimum), maximum)) }
        case .enumeration, .dynamicEnum, .string:
            return stored.stringValue.map(PagerSettingValue.string)
        case .secret, .group, .dynamicMultiSelect:
            return nil
        }
    }

    /// The dotted path a row is written to, or `nil` when it has no file home.
    func persistedPath(for meta: PagerSettingMeta) -> String? {
        switch meta.storage {
        case .config(let path), .featureFlag(let path): return path
        case .sessionLocal, .secretStore, .authMetadata: return nil
        }
    }

    // MARK: Writing

    /// Persist one row. Returns the path written, so a caller can log or test
    /// what actually changed.
    @discardableResult
    public func write(key: String, value: PagerSettingValue) throws -> String {
        if Self.customModelDraftKeys.contains(key) {
            var mutableSelf = self
            mutableSelf.updateDraft(key: key, value: value)
            if key == "custom_model_save", case .bool(let save) = value, save {
                _ = try saveCustomModelDraft()
            }
            return key
        }

        guard let meta = registry.find(key) else { throw PagerSettingsStoreError.unknownKey(key) }
        guard let path = persistedPath(for: meta) else {
            throw PagerSettingsStoreError.notPersistable(key: key)
        }
        let encoded = try encode(value, for: meta)
        var root = (try? readRoot()) ?? .table(TOMLTable())
        try setValue(encoded, at: path.split(separator: ".").map(String.init), in: &root)
        try writeConfigFile(root, to: configPath)
        return path
    }

    /// Persist a multi-select row's whole enabled set.
    @discardableResult
    public func writeMultiSelect(key: String, enabled: Set<String>) throws -> String {
        if key == "custom_models.list" {
            var models = (try? loadCustomModels()) ?? []
            models.removeAll { !enabled.contains($0.key) }
            try writeCustomModelsFile(models)
            return "custom_models.list"
        }

        guard let meta = registry.find(key) else { throw PagerSettingsStoreError.unknownKey(key) }
        guard let path = persistedPath(for: meta) else {
            throw PagerSettingsStoreError.notPersistable(key: key)
        }
        var root = (try? readRoot()) ?? .table(TOMLTable())
        // Sorted so the file is stable across runs — an unordered set would
        // produce a spurious diff every time anything else in the file changed.
        let normalized: [String]
        if key == "openrouter_models" {
            normalized = Array(Set(enabled.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })).sorted()
        } else {
            normalized = enabled.sorted()
        }
        let array = TOMLValue.array(normalized.map(TOMLValue.string))
        try setValue(array, at: path.split(separator: ".").map(String.init), in: &root)
        try writeConfigFile(root, to: configPath)
        return path
    }

    /// Restore a row to its registered default by removing its key from the
    /// file, rather than by writing the default value.
    ///
    /// This is the difference between "unset" and "explicitly set to what the
    /// default happens to be today": if the default changes in a later release,
    /// a removed key follows it and a written one does not.
    @discardableResult
    public func reset(key: String) throws -> String {
        if key == "custom_models" || Self.customModelDraftKeys.contains(key) {
            var mutableSelf = self
            mutableSelf.clearDraft()
            return key
        }

        guard let meta = registry.find(key) else { throw PagerSettingsStoreError.unknownKey(key) }
        guard let path = persistedPath(for: meta) else {
            throw PagerSettingsStoreError.notPersistable(key: key)
        }
        var root = (try? readRoot()) ?? .table(TOMLTable())
        removeValue(at: path.split(separator: ".").map(String.init), in: &root)
        try writeConfigFile(root, to: configPath)
        return path
    }

    // MARK: keep_text_selection (atomic + legacy clear)

    /// Legacy `[ui]` keys superseded by `keep_text_selection`
    /// (`settings_writes.rs` `set_keep_text_selection` at pin `650c1db7`).
    private static let keepTextSelectionLegacyPaths: [[String]] = [
        ["ui", "double_click_action"],
        ["ui", "selection_highlight_duration_ms"],
    ]

    /// Persist `keep_text_selection` and clear superseded legacy keys in **one**
    /// read-modify-write — no partial writes if the file write fails.
    @discardableResult
    public func writeKeepTextSelection(_ canonical: String) throws -> String {
        guard registry.find("keep_text_selection") != nil else {
            throw PagerSettingsStoreError.unknownKey("keep_text_selection")
        }
        var root = (try? readRoot()) ?? .table(TOMLTable())
        try setValue(
            .string(canonical),
            at: ["ui", "keep_text_selection"],
            in: &root
        )
        for path in Self.keepTextSelectionLegacyPaths {
            removeValue(at: path, in: &root)
        }
        try writeConfigFile(root, to: configPath)
        return "ui.keep_text_selection"
    }

    /// Unset `keep_text_selection` and clear legacy keys in one write so a
    /// reset cannot resurrect `word_select` / hold via
    /// `double_click_action` or `selection_highlight_duration_ms == 0`.
    @discardableResult
    public func resetKeepTextSelection() throws -> String {
        guard registry.find("keep_text_selection") != nil else {
            throw PagerSettingsStoreError.unknownKey("keep_text_selection")
        }
        var root = (try? readRoot()) ?? .table(TOMLTable())
        removeValue(at: ["ui", "keep_text_selection"], in: &root)
        for path in Self.keepTextSelectionLegacyPaths {
            removeValue(at: path, in: &root)
        }
        try writeConfigFile(root, to: configPath)
        return "ui.keep_text_selection"
    }

    private func encode(
        _ value: PagerSettingValue,
        for meta: PagerSettingMeta
    ) throws -> TOMLValue {
        switch (value, meta.kind) {
        case (.bool(let flag), .bool):
            return .boolean(flag)
        case (.integer(let number), .integer(_, let minimum, let maximum)):
            return .integer(Int64(min(max(number, minimum), maximum)))
        case (.string(let text), .enumeration),
             (.string(let text), .dynamicEnum),
             (.string(let text), .string):
            return .string(text)
        default:
            throw PagerSettingsStoreError.typeMismatch(key: meta.key)
        }
    }

    private func readRoot() throws -> TOMLValue {
        let data = try Data(contentsOf: configPath)
        return try parseTOML(data)
    }
}

// MARK: - Dotted-path surgery

/// Insert `value` at a dotted path, creating intermediate tables.
///
/// Refuses rather than clobbers when a path segment already holds a scalar: a
/// user who wrote `ui = "dark"` by hand has a broken config, and silently
/// replacing it with a table would delete their line without telling them.
func setValue(_ value: TOMLValue, at path: [String], in root: inout TOMLValue) throws {
    guard let head = path.first else { return }
    guard var table = root.table else {
        throw PagerSettingsStoreError.pathBlocked(path: head)
    }
    if path.count == 1 {
        table.insert(value, forKey: head)
        root = .table(table)
        return
    }
    var child: TOMLValue
    switch table[head] {
    case .none:
        child = .table(TOMLTable())
    case .some(let existing) where existing.isTable:
        child = existing
    case .some:
        throw PagerSettingsStoreError.pathBlocked(path: head)
    }
    try setValue(value, at: Array(path.dropFirst()), in: &child)
    table.insert(child, forKey: head)
    root = .table(table)
}

/// Remove a dotted path, pruning any table it leaves empty so a reset does not
/// leave a bare `[ui.display_refresh]` header behind.
func removeValue(at path: [String], in root: inout TOMLValue) {
    guard let head = path.first, var table = root.table else { return }
    if path.count == 1 {
        _ = table.removeValue(forKey: head)
        root = .table(table)
        return
    }
    guard var child = table[head], child.isTable else { return }
    removeValue(at: Array(path.dropFirst()), in: &child)
    if child.isTableEmpty {
        _ = table.removeValue(forKey: head)
    } else {
        table.insert(child, forKey: head)
    }
    root = .table(table)
}
