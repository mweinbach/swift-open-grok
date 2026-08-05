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

    public var description: String {
        switch self {
        case .notPersistable(let key): return "\(key) is not written to config.toml"
        case .unknownKey(let key): return "unknown setting: \(key)"
        case .typeMismatch(let key): return "wrong value type for \(key)"
        case .pathBlocked(let path): return "\(path) is not a table"
        }
    }
}

/// Reads and writes the settings rows that live in `config.toml`.
///
/// Writes are read-modify-write against the file on every call rather than
/// against a cached tree: another process — a second pager, `open-grok config` —
/// may have edited the file since this one loaded it, and re-reading is what
/// keeps a settings toggle from reverting someone else's change.
public struct PagerSettingsStore: Sendable {
    public var configPath: URL
    public var registry: PagerSettingsRegistry

    public init(configPath: URL, registry: PagerSettingsRegistry = .default) {
        self.configPath = configPath
        self.registry = registry
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
        guard let meta = registry.find(key), let path = persistedPath(for: meta) else { return [] }
        let root = (try? readRoot()) ?? .table(TOMLTable())
        guard let array = root[path: path.split(separator: ".").map(String.init)]?.arrayValue
        else { return [] }
        return Set(array.compactMap(\.stringValue))
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
        guard let meta = registry.find(key) else { throw PagerSettingsStoreError.unknownKey(key) }
        guard let path = persistedPath(for: meta) else {
            throw PagerSettingsStoreError.notPersistable(key: key)
        }
        var root = (try? readRoot()) ?? .table(TOMLTable())
        // Sorted so the file is stable across runs — an unordered set would
        // produce a spurious diff every time anything else in the file changed.
        let array = TOMLValue.array(enabled.sorted().map(TOMLValue.string))
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
        guard let meta = registry.find(key) else { throw PagerSettingsStoreError.unknownKey(key) }
        guard let path = persistedPath(for: meta) else {
            throw PagerSettingsStoreError.notPersistable(key: key)
        }
        var root = (try? readRoot()) ?? .table(TOMLTable())
        removeValue(at: path.split(separator: ".").map(String.init), in: &root)
        try writeConfigFile(root, to: configPath)
        return path
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
