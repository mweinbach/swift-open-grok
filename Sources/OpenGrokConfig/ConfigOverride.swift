// ConfigOverride.swift
//
// Port of `xai-grok-config/src/config_override.rs`.
//
// Shared take/apply for `[[version_overrides]]` / `[[campaigns]]` arrays.
// Each entry is a typed metadata header plus the remaining keys as a
// deep-merge patch (a `TOMLTable`).

import Foundation
import OpenGrokConfigTypes

/// A path into a TOML table for patch-touches-path checks. Each segment is
/// a key. Mirrors Rust `PatchPath = &'static [&'static str]`.
public typealias PatchPath = [String]

/// One entry of a `[[version_overrides]]` / `[[campaigns]]` array, split into
/// its typed metadata header (`meta`) and the remaining keys as a deep-merge
/// patch (`patch`). Mirrors Rust `ConfigOverrideEntry<M>`.
public struct ConfigOverrideEntry<M> where M: ConfigOverrideMeta {
    public var meta: M
    public var patch: TOMLTable

    public init(meta: M, patch: TOMLTable) {
        self.meta = meta
        self.patch = patch
    }
}

/// Metadata marker protocol for `ConfigOverrideEntry`. The metadata is
/// decoded from the same TOML table as the patch, so conforming types must
/// declare their own key set (used by `takePatchArray` to extract the
/// metadata fields and leave the rest as the patch).
public protocol ConfigOverrideMeta {
    /// The set of keys that belong to the metadata header (consumed from the
    /// entry table before the patch is captured).
    static var metaKeys: Set<String> { get }
    /// Decode the metadata from the subset of `table` keyed by `metaKeys`.
    static func decode(from table: TOMLTable) throws -> Self
}

/// Strip `key` from the root table; each element is `M` + remaining keys as
/// patch. Mirrors Rust `take_patch_array<M>`.
public func takePatchArray<M: ConfigOverrideMeta>(
    _ config: inout TOMLValue,
    key: String
) throws -> [ConfigOverrideEntry<M>] {
    guard case var .table(root) = config else { return [] }
    guard let arrayValue = root.removeValue(forKey: key) else { return [] }
    config = .table(root)
    guard case let .array(entries) = arrayValue else {
        throw TOMLError(line: 0, column: 0, message: "'\(key)' is not an array of tables")
    }
    var out: [ConfigOverrideEntry<M>] = []
    out.reserveCapacity(entries.count)
    for entry in entries {
        guard case let .table(t) = entry else {
            throw TOMLError(line: 0, column: 0, message: "'\(key)' entry is not a table")
        }
        // Extract the metadata keys.
        var patchTable = TOMLTable()
        var metaTable = TOMLTable()
        for (k, v) in t.pairs {
            if M.metaKeys.contains(k) {
                metaTable[k] = v
            } else {
                patchTable[k] = v
            }
        }
        let meta = try M.decode(from: metaTable)
        out.append(ConfigOverrideEntry(meta: meta, patch: patchTable))
    }
    return out
}

/// Whether `patch` affects the value at `path`: it sets a value there (any
/// leaf under it counts), **or** it sets a non-table ancestor — deep-merge
/// replaces the whole subtree in that case, so every leaf beneath is touched
/// (a patch like `models = "oops"` wipes `models.default` and must still be
/// dismissable / flagged as driving it).
public func patchTouchesPath(_ patch: TOMLTable, path: PatchPath) -> Bool {
    guard let first = path.first else { return false }
    guard var cur = patch[first] else { return false }
    for seg in path.dropFirst() {
        switch cur {
        case let .table(t):
            if let next = t[seg] { cur = next }
            else { return false }
        default:
            // Non-table ancestor: the merge replaces this subtree wholesale.
            return true
        }
    }
    return true
}

/// Whether `patch` touches any of `paths`.
public func patchTouchesAny(_ patch: TOMLTable, paths: [PatchPath]) -> Bool {
    paths.contains { patchTouchesPath(patch, path: $0) }
}

/// Keys stripped from every applied patch so an override can't re-introduce a
/// nested `version_overrides`/`campaigns` array or define the
/// `auth_provider`/`model_providers` command tables.
/// This const owns the protected top-level keys for every override kind;
/// `applyPatches` takes the strip list as a parameter so the strip step
/// itself stays key-agnostic.
public let PATCH_STRIP_KEYS: [String] = [
    "version_overrides",
    "campaigns",
    "auth_provider",
    "model_providers",
]

/// Deep-merge each patch in iteration order (later wins on a leaf), stripping
/// `stripKeys` from every patch first. Mirrors Rust `apply_patches`.
public func applyPatches(
    into config: inout TOMLValue,
    patches: [TOMLTable],
    stripKeys: [String] = PATCH_STRIP_KEYS
) {
    for var patch in patches {
        for key in stripKeys {
            patch.removeValue(forKey: key)
        }
        deepMergeTOML(&config, overrides: .table(patch))
    }
}
