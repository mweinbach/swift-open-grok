// WorktreeAutoGc.swift
//
// Automatic worktree GC policy and the image-generation provider selector.
//
// Port of the types added to `crates/codegen/xai-grok-config-types/src/lib.rs`
// between pins 9739c4a2 and 80dff0a9:
//   * `ImageGenerationProvider` — lib.rs:26-48
//   * `WorktreeKindMaxAge`      — lib.rs:58-107
//   * `WorktreeAutoGcSettings`  — lib.rs:109-176

import Foundation
import OpenGrokShared

// MARK: - ImageGenerationProvider

/// User-selected image generation service.
///
/// A routing decision only: each provider keeps its own endpoint,
/// credentials, headers, and retry path. lib.rs:26.
public enum ImageGenerationProvider: String, Hashable, Sendable, Codable, CaseIterable {
    case grok
    case openAI = "openai"

    public static let `default`: ImageGenerationProvider = .grok

    /// `as_canonical`, lib.rs:40.
    public var canonical: String { rawValue }

    /// `from_canonical`, lib.rs:46 — trims and lowercases before matching.
    public static func fromCanonical(_ value: String) -> ImageGenerationProvider? {
        ImageGenerationProvider(
            rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}

// MARK: - WorktreeKindMaxAge

/// Per-kind age policy for auto-GC: seconds or never. lib.rs:58.
///
/// Wire form is asymmetric on purpose (lib.rs:64-105): it *serializes* as a
/// bare integer or the string `"never"`, but *deserializes* from an integer,
/// the case-insensitive string `"never"`, a numeric string, or `null`
/// (`null` means never).
public enum WorktreeKindMaxAge: Hashable, Sendable, Codable {
    case secs(UInt64)
    case never

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .never
            return
        }
        if let n = try? c.decode(UInt64.self) {
            self = .secs(n)
            return
        }
        if let i = try? c.decode(Int64.self) {
            guard i >= 0 else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "expected \"never\" or integer seconds")
            }
            self = .secs(UInt64(i))
            return
        }
        if let s = try? c.decode(String.self) {
            if s.lowercased() == "never" {
                self = .never
            } else if let n = UInt64(s) {
                self = .secs(n)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "expected \"never\" or integer seconds")
            }
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "u64 seconds or \"never\"")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .secs(let n): try c.encode(n)
        case .never: try c.encode("never")
        }
    }
}

// MARK: - WorktreeAutoGcSettings

/// Local `[worktree.auto_gc]` / remote `worktree_auto_gc` policy. lib.rs:109.
///
/// Deserialization is tolerant field-wise: a wrong-typed value drops to `nil`
/// rather than failing the object, so one bad key cannot take a sibling
/// kill-switch down with it.
public struct WorktreeAutoGcSettings: Hashable, Sendable, Codable, Equatable {
    /// `false` is a kill-switch; absent ⇒ default on (env kill still applies).
    public var enabled: Bool?
    /// Age cutoff seconds when platform age-expiry is allowed; resolver clamps.
    public var maxAgeSecs: UInt64?
    /// Min seconds between successful auto-GC stamps; resolver clamps.
    public var minIntervalSecs: UInt64?
    /// Count age candidates without deleting.
    public var dryRun: Bool?
    /// Linux only.
    public var includeOrphanSnapshots: Bool?
    /// Per-kind max ages (`session`/`ab`/`pool`/`fork`/`manual`/`subagent`).
    /// Absent keys use defaults (client default: `manual` = never). Remote may
    /// set `manual` to a finite TTL — it is not client-pinned, and local TOML
    /// can restore `"never"`. Unknown kind keys are ignored at resolve.
    public var maxAgeByKind: [String: WorktreeKindMaxAge]?
    /// Optional discovery rebuild + stale `.git/worktrees/` prune (default off).
    public var includeRebuild: Bool?
    /// Independent rebuild throttle seconds; absent ⇒ 24h.
    public var rebuildMinIntervalSecs: UInt64?

    public init(
        enabled: Bool? = nil,
        maxAgeSecs: UInt64? = nil,
        minIntervalSecs: UInt64? = nil,
        dryRun: Bool? = nil,
        includeOrphanSnapshots: Bool? = nil,
        maxAgeByKind: [String: WorktreeKindMaxAge]? = nil,
        includeRebuild: Bool? = nil,
        rebuildMinIntervalSecs: UInt64? = nil
    ) {
        self.enabled = enabled
        self.maxAgeSecs = maxAgeSecs
        self.minIntervalSecs = minIntervalSecs
        self.dryRun = dryRun
        self.includeOrphanSnapshots = includeOrphanSnapshots
        self.maxAgeByKind = maxAgeByKind
        self.includeRebuild = includeRebuild
        self.rebuildMinIntervalSecs = rebuildMinIntervalSecs
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxAgeSecs = "max_age_secs"
        case minIntervalSecs = "min_interval_secs"
        case dryRun = "dry_run"
        case includeOrphanSnapshots = "include_orphan_snapshots"
        case maxAgeByKind = "max_age_by_kind"
        case includeRebuild = "include_rebuild"
        case rebuildMinIntervalSecs = "rebuild_min_interval_secs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = Self.tolerantBool(c, .enabled)
        maxAgeSecs = Self.tolerantU64(c, .maxAgeSecs)
        minIntervalSecs = Self.tolerantU64(c, .minIntervalSecs)
        dryRun = Self.tolerantBool(c, .dryRun)
        includeOrphanSnapshots = Self.tolerantBool(c, .includeOrphanSnapshots)
        maxAgeByKind = Self.tolerantMaxAgeByKind(c, .maxAgeByKind)
        includeRebuild = Self.tolerantBool(c, .includeRebuild)
        rebuildMinIntervalSecs = Self.tolerantU64(c, .rebuildMinIntervalSecs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(maxAgeSecs, forKey: .maxAgeSecs)
        try c.encodeIfPresent(minIntervalSecs, forKey: .minIntervalSecs)
        try c.encodeIfPresent(dryRun, forKey: .dryRun)
        try c.encodeIfPresent(includeOrphanSnapshots, forKey: .includeOrphanSnapshots)
        try c.encodeIfPresent(maxAgeByKind, forKey: .maxAgeByKind)
        try c.encodeIfPresent(includeRebuild, forKey: .includeRebuild)
        try c.encodeIfPresent(rebuildMinIntervalSecs, forKey: .rebuildMinIntervalSecs)
    }

    /// `de_opt_bool_tolerant`: anything that is not a bool yields `nil`.
    private static func tolerantBool(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> Bool? {
        try? c.decodeIfPresent(Bool.self, forKey: key)
    }

    /// `de_opt_u64_tolerant` (lib.rs:357): strings, bools, floats and
    /// negatives all yield `nil` rather than failing the object.
    private static func tolerantU64(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> UInt64? {
        guard c.contains(key) else { return nil }
        if let n = try? c.decode(UInt64.self, forKey: key) { return n }
        if let i = try? c.decode(Int64.self, forKey: key), i >= 0 { return UInt64(i) }
        return nil
    }

    /// `de_opt_max_age_by_kind_tolerant` (lib.rs:405): a non-object whole
    /// value yields `nil`; within an object each unparseable entry is
    /// skipped so its siblings survive.
    private static func tolerantMaxAgeByKind(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> [String: WorktreeKindMaxAge]? {
        guard c.contains(key),
              let raw = try? c.decode(JSONValue.self, forKey: key),
              case .object(let map) = raw
        else { return nil }
        var out: [String: WorktreeKindMaxAge] = [:]
        for (k, v) in map {
            if let age = try? v.decode(WorktreeKindMaxAge.self) { out[k] = age }
        }
        return out
    }
}
