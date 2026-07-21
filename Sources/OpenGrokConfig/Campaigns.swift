// Campaigns.swift
//
// Port of `xai-grok-config/src/campaigns.rs`.
//
// `[[campaigns]]` overlays. Priority (first id wins): requirements > remote >
// user > managed > system_managed. Applied after layer merge.

import Foundation
import OpenGrokConfigTypes

public let CAMPAIGNS_KEY = "campaigns"

// MARK: - CampaignMeta

/// Metadata header for a `[[campaigns]]` entry. Accepts `id` or `campaign_id`
/// (Rust `alias`).
public struct CampaignMeta: ConfigOverrideMeta, Equatable, Sendable {
    public var id: String?

    public init(id: String? = nil) {
        self.id = id
    }

    public static var metaKeys: Set<String> { ["id", "campaign_id"] }

    public static func decode(from table: TOMLTable) throws -> CampaignMeta {
        var id: String? = nil
        if case let .string(s) = table["id"] { id = s }
        else if case let .string(s) = table["campaign_id"] { id = s }
        return CampaignMeta(id: id)
    }
}

// MARK: - CampaignEntry

/// One `[[campaigns]]` entry, split into its `id` and the deep-merge patch.
public struct CampaignEntry: Equatable, Sendable, Hashable {
    public var id: String
    public var patch: TOMLTable

    public init(id: String, patch: TOMLTable) {
        self.id = id
        self.patch = patch
    }
}

// MARK: - CampaignOverrides

/// Disk campaigns grouped by source layer. Merged with the remote layer (by
/// priority, first id wins) in `ConfigLayers.resolveCampaigns`.
public struct CampaignOverrides: Equatable, Sendable {
    public var requirements: [CampaignEntry]
    public var user: [CampaignEntry]
    public var managed: [CampaignEntry]
    public var systemManaged: [CampaignEntry]

    public init(
        requirements: [CampaignEntry] = [],
        user: [CampaignEntry] = [],
        managed: [CampaignEntry] = [],
        systemManaged: [CampaignEntry] = []
    ) {
        self.requirements = requirements
        self.user = user
        self.managed = managed
        self.systemManaged = systemManaged
    }
}

// MARK: - Take / build / merge / filter / apply

/// Strip and parse `[[campaigns]]` from `config`. Malformed entries are
/// dropped with a warning (Rust `tracing::warn!`); never throws.
public func takeCampaigns(from config: inout TOMLValue) -> [ConfigOverrideEntry<CampaignMeta>] {
    do {
        return try takePatchArray(&config, key: CAMPAIGNS_KEY)
    } catch {
        // Mirrors Rust `tracing::warn!(error = %e, "campaigns: failed to deserialize; ignoring entries")`.
        return []
    }
}

/// Build typed `CampaignEntry`s from raw taken entries. Skips entries with a
/// missing/blank id and no-op entries (id only, no patch). Mirrors Rust
/// `build_campaign_entries`.
public func buildCampaignEntries(
    taken: [ConfigOverrideEntry<CampaignMeta>],
    layer: String
) -> [CampaignEntry] {
    var out: [CampaignEntry] = []
    out.reserveCapacity(taken.count)
    for entry in taken {
        let id = entry.meta.id?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }
        guard let id = id, !id.isEmpty else { continue }
        if entry.patch.isEmpty { continue }
        out.append(CampaignEntry(id: id, patch: entry.patch))
    }
    return out
}

/// Convenience: take + build in one step. Mirrors Rust `take_campaign_entries`.
public func takeCampaignEntries(from config: inout TOMLValue, layer: String) -> [CampaignEntry] {
    buildCampaignEntries(taken: takeCampaigns(from: &config), layer: layer)
}

/// `sources` in priority order; first `id` wins. Mirrors Rust
/// `merge_campaign_entries`.
public func mergeCampaignEntries(_ sources: [[CampaignEntry]]) -> [CampaignEntry] {
    var seen = Set<String>()
    var out: [CampaignEntry] = []
    for source in sources {
        for entry in source {
            if seen.insert(entry.id).inserted {
                out.append(entry)
            }
        }
    }
    return out
}

/// Drop dismissed ids from a priority-merged list, preserving order. Mirrors
/// Rust `filter_active_campaigns`.
public func filterActiveCampaigns(
    merged: [CampaignEntry],
    dismissedIds: Set<String>
) -> [CampaignEntry] {
    merged.filter { !dismissedIds.contains($0.id) }
}

/// Ids of `active` campaigns whose patch touches any of `paths` — used to
/// dismiss campaigns when the user persists a value at one of those paths.
public func idsTouchingPaths(active: [CampaignEntry], paths: [PatchPath]) -> [String] {
    active.filter { patchTouchesAny($0.patch, paths: paths) }.map { $0.id }
}

/// `active` is highest-priority-first; patches apply lowest-first (reversed)
/// so the highest-priority source wins a leaf conflict. Mirrors Rust
/// `apply_active_campaign_patches`.
public func applyActiveCampaignPatches(into effective: inout TOMLValue, active: [CampaignEntry]) {
    let patches = active.reversed().map { $0.patch }
    applyPatches(into: &effective, patches: patches, stripKeys: PATCH_STRIP_KEYS)
}
