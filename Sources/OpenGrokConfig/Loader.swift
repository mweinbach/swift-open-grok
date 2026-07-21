// Loader.swift
//
// Port of `xai-grok-config/src/loader.rs`.
//
// TOML loading, layered merging, `$VAR` expansion, `[[version_overrides]]`,
// `[[campaigns]]` overlay, and the effective-config disk-only path.
//
// The merge order (lowest → highest priority) mirrors the Rust reference:
//   1. `/etc/opengrok/managed_config.toml`
//   2. `$OPENGROK_HOME/managed_config.toml`
//   3. `$OPENGROK_HOME/config.toml`
//   4. `$OPENGROK_HOME/requirements.toml` (cloud cache; Ed25519-signed at rest
//      once a key is embedded — see SignedPolicy.swift — below the
//      OS-protected layers)
//   5. `/etc/opengrok/requirements.toml`
//   6. macOS MDM managed preferences (`ai.x.opengrok`, admin-forced) — macOS only
//
// Each layer applies its own `[[version_overrides]]` before merge.
// Requirements layers (#4–#6) may opt into fail-closed startup; see
// Validation.swift.

import Foundation
import OpenGrokConfigTypes
import OpenGrokVersion

// MARK: - Layered file loading

/// Managed config filename, shared by the loaders in this module.
public let MANAGED_CONFIG_FILENAME = "managed_config.toml"

/// Requirements (cloud-cache) filename — the sibling server-synced artifact.
public let REQUIREMENTS_FILENAME = "requirements.toml"

/// Load and parse a TOML file, expanding `$VAR` references. Returns an empty
/// table if the file is absent; throws `TOMLError` (wrapped) on a parse
/// failure, with a snippet-free message (the source line may carry a secret).
public func loadTomlFile(at path: URL) throws -> TOMLValue {
    do {
        let contents = try String(contentsOf: path, encoding: .utf8)
        do {
            var v = try parseTOML(contents)
            expandEnvVarsInTOML(&v)
            return v
        } catch let e as TOMLError {
            // The message is span-only and never echoes the source line.
            throw OpenGrokConfigIOError.tomlParse(path: path, detail: e.description)
        }
    } catch let error as OpenGrokConfigIOError {
        throw error
    } catch let error as NSError {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
            return .table(TOMLTable())
        }
        throw OpenGrokConfigIOError.io(path: path, underlying: error)
    }
}

/// I/O errors from config loading. `.tomlParse` carries a snippet-free
/// detail string; `.io` wraps the underlying NSError.
public enum OpenGrokConfigIOError: Error, Equatable, Sendable, CustomStringConvertible {
    case tomlParse(path: URL, detail: String)
    case io(path: URL, underlying: NSError)

    public var description: String {
        switch self {
        case let .tomlParse(path, detail):
            return "config toml at \(path.path) has syntax errors: \(detail)"
        case let .io(path, underlying):
            return "config file at \(path.path) unreadable: \(underlying.localizedDescription)"
        }
    }

    public static func == (lhs: OpenGrokConfigIOError, rhs: OpenGrokConfigIOError) -> Bool {
        switch (lhs, rhs) {
        case let (.tomlParse(la, ld), .tomlParse(ra, rd)):
            return la == ra && ld == rd
        case let (.io(la, lb), .io(ra, rb)):
            return la == ra && lb == rb
        default: return false
        }
    }
}

/// `loadTomlFile` plus that layer's `[[version_overrides]]`. Use for grok
/// config files; use `loadTomlFile` directly for unrelated TOML.
public func loadConfigFile(at path: URL) throws -> TOMLValue {
    var v = try loadTomlFile(at: path)
    try applyVersionOverridesWithRegistered(&v)
    return v
}

/// Load `$OPENGROK_HOME/config.toml` (the user config layer).
public func loadFromDisk(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> TOMLValue {
    try loadUserConfigLayer(home: userGrokHome(environment: environment), filename: "config.toml")
}

/// Load `$OPENGROK_HOME/managed_config.toml` (the user managed-config layer).
public func loadManagedConfig(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> TOMLValue {
    try loadUserConfigLayer(home: userGrokHome(environment: environment), filename: MANAGED_CONFIG_FILENAME)
}

/// Load a user-tier config layer from `<home>/<filename>`. With no resolvable
/// user home, returns an empty table rather than reading a cwd-relative
/// `.opengrok/<filename>` (the cwd-fallback would silently promote an
/// untrusted project `.opengrok` to the user tier).
public func loadUserConfigLayer(
    home: URL?,
    filename: String
) throws -> TOMLValue {
    guard let home = home else { return .table(TOMLTable()) }
    return try loadConfigFile(at: home.appendingPathComponent(filename))
}

/// Load `/etc/opengrok/managed_config.toml` (the system managed-config layer).
/// Returns an empty table when no system config dir resolves (e.g. on Windows
/// or when `/etc/opengrok` doesn't exist).
public func loadSystemManagedConfig() throws -> TOMLValue {
    guard let dir = systemConfigDir() else { return .table(TOMLTable()) }
    var v = try loadTomlFile(at: dir.appendingPathComponent(MANAGED_CONFIG_FILENAME))
    try applyVersionOverridesWithRegistered(&v)
    return v
}

// MARK: - ManagedConfigLayer

/// One managed-config layer: the parsed TOML and the file it came from.
public struct ManagedConfigLayer: Equatable, Sendable {
    public var value: TOMLValue
    public var path: URL
    /// `true` for the root-owned system layer (`/etc/opengrok`), derived from
    /// the load directory.
    public var isSystem: Bool

    public init(value: TOMLValue, path: URL, isSystem: Bool) {
        self.value = value
        self.path = path
        self.isSystem = isSystem
    }
}

/// All `managed_config.toml` layers in apply order (system first, user last).
/// Absent layers are skipped; unparsable layers are skipped with a warning.
/// One bad layer never drops the others.
public func managedConfigLayers(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [ManagedConfigLayer] {
    managedConfigLayersAt(
        systemDir: systemConfigDir(),
        userHome: userGrokHome(environment: environment)
    )
}

/// `managedConfigLayers` with explicit directories.
public func managedConfigLayersAt(
    systemDir: URL?,
    userHome: URL?
) -> [ManagedConfigLayer] {
    var layers: [ManagedConfigLayer] = []
    let candidates: [(URL?, Bool)] = [(systemDir, true), (userHome, false)]
    for (dir, isSystem) in candidates {
        guard let dir = dir else { continue }
        let path = dir.appendingPathComponent(MANAGED_CONFIG_FILENAME)
        if !FileManager.default.fileExists(atPath: path.path) { continue }
        do {
            let value = try loadConfigFile(at: path)
            layers.append(ManagedConfigLayer(value: value, path: path, isSystem: isSystem))
        } catch {
            // Mirrors Rust `tracing::warn!(path = ..., error = ..., "skipping managed_config.toml layer that failed to load or parse")`.
            continue
        }
    }
    return layers
}

// MARK: - ConfigLayers

/// Layers lowest→highest priority. `[[campaigns]]` taken off each layer at
/// load. Mirrors Rust `ConfigLayers`.
public struct ConfigLayers: Sendable {
    public var systemManaged: TOMLValue
    public var managed: TOMLValue
    public var user: TOMLValue
    public var userRequirements: TOMLValue?
    public var systemRequirements: TOMLValue?
    /// macOS MDM requirements; highest requirements tier when present.
    public var mdmRequirements: TOMLValue?
    public var campaigns: CampaignOverrides

    public init() {
        self.systemManaged = .table(TOMLTable())
        self.managed = .table(TOMLTable())
        self.user = .table(TOMLTable())
        self.userRequirements = nil
        self.systemRequirements = nil
        self.mdmRequirements = nil
        self.campaigns = CampaignOverrides()
    }

    public init(
        systemManaged: TOMLValue,
        managed: TOMLValue,
        user: TOMLValue,
        userRequirements: TOMLValue? = nil,
        systemRequirements: TOMLValue? = nil,
        mdmRequirements: TOMLValue? = nil,
        campaigns: CampaignOverrides = CampaignOverrides()
    ) {
        self.systemManaged = systemManaged
        self.managed = managed
        self.user = user
        self.userRequirements = userRequirements
        self.systemRequirements = systemRequirements
        self.mdmRequirements = mdmRequirements
        self.campaigns = campaigns
    }

    /// Load all layers from disk, taking `[[campaigns]]` off each.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ConfigLayers {
        var systemManaged = try loadSystemManagedConfig()
        let systemManagedCampaigns = takeCampaignEntries(from: &systemManaged, layer: "system_managed")

        var managed = try loadManagedConfig(environment: environment)
        let managedCampaigns = takeCampaignEntries(from: &managed, layer: "managed")

        var user = try loadFromDisk(environment: environment)
        let userCampaigns = takeCampaignEntries(from: &user, layer: "user")

        var userRequirements = loadRequirements(environment: environment)
        var systemRequirements = loadSystemRequirements()
        var mdmRequirements = mdmRequirementsValue()

        // Highest-authority requirements tier first: `mergeCampaignEntries`
        // is first-id-wins, so a duplicate campaign id must resolve mdm >
        // system > user — matching the layer precedence in
        // `effectiveConfigBase` (where mdm is merged last/highest).
        var requirementsCampaigns: [CampaignEntry] = []
        if let req = mdmRequirements {
            var copy = req
            requirementsCampaigns.append(contentsOf: takeCampaignEntries(from: &copy, layer: "requirements"))
            // Re-assign the stripped copy back.
            mdmRequirements = copy
        }
        if let req = systemRequirements {
            var copy = req
            requirementsCampaigns.append(contentsOf: takeCampaignEntries(from: &copy, layer: "requirements"))
            systemRequirements = copy
        }
        if let req = userRequirements {
            var copy = req
            requirementsCampaigns.append(contentsOf: takeCampaignEntries(from: &copy, layer: "requirements"))
            userRequirements = copy
        }

        return ConfigLayers(
            systemManaged: systemManaged,
            managed: managed,
            user: user,
            userRequirements: userRequirements,
            systemRequirements: systemRequirements,
            mdmRequirements: mdmRequirements,
            campaigns: CampaignOverrides(
                requirements: requirementsCampaigns,
                user: userCampaigns,
                managed: managedCampaigns,
                systemManaged: systemManagedCampaigns
            )
        )
    }

    /// Layer merge only (no campaign overlay).
    public func effectiveConfigBase() -> TOMLValue {
        var merged = systemManaged
        deepMergeTOML(&merged, overrides: managed)
        deepMergeTOML(&merged, overrides: user)
        if let req = userRequirements { deepMergeTOML(&merged, overrides: req) }
        if let sysReq = systemRequirements { deepMergeTOML(&merged, overrides: sysReq) }
        if let mdmReq = mdmRequirements { deepMergeTOML(&merged, overrides: mdmReq) }
        return merged
    }

    /// Campaign source slices in priority order (first id wins):
    /// requirements > remote > user > managed > system_managed.
    public func campaignSourceSlices(
        remoteCampaigns: [CampaignEntry]
    ) -> [[CampaignEntry]] {
        [
            campaigns.requirements,
            remoteCampaigns,
            campaigns.user,
            campaigns.managed,
            campaigns.systemManaged,
        ]
    }

    /// Active campaigns against `base`: kill switch → priority merge
    /// (first-id-wins) → drop dismissed. The single place disk campaign
    /// resolution lives; the shell wraps this with the
    /// `GROK_CAMPAIGNS_OVERRIDE` env layer.
    public func resolveCampaigns(
        base: TOMLValue,
        remoteCampaigns: [CampaignEntry],
        dismissedIds: Set<String>
    ) -> [CampaignEntry] {
        if campaignsApplicationDisabled(base: base) { return [] }
        let merged = mergeCampaignEntries(campaignSourceSlices(remoteCampaigns: remoteCampaigns))
        return filterActiveCampaigns(merged: merged, dismissedIds: dismissedIds)
    }

    /// Re-merge the requirements layers so an admin's `requirements.toml`
    /// always wins over a campaign overlay, regardless of the campaign's
    /// source layer. Campaigns are full-power (any field), so this is the
    /// structural guarantee that a lower-trust layer's campaign can't
    /// override an admin-set field.
    fileprivate func reapplyRequirements(into merged: inout TOMLValue) {
        for req in [userRequirements, systemRequirements, mdmRequirements].compactMap({ $0 }) {
            deepMergeTOML(&merged, overrides: req)
        }
    }

    /// Apply active campaign patches onto `merged`, then restore requirements
    /// precedence. The single overlay step shared by this crate and the shell.
    public func applyCampaignOverrides(
        into merged: inout TOMLValue,
        active: [CampaignEntry]
    ) {
        applyActiveCampaignPatches(into: &merged, active: active)
        reapplyRequirements(into: &merged)
    }

    /// Layer merge + disk/remote campaign overlay, honoring the kill switch.
    public func effectiveConfigWithCampaigns(
        remoteCampaigns: [CampaignEntry],
        dismissedIds: Set<String>
    ) -> TOMLValue {
        var merged = effectiveConfigBase()
        let active = resolveCampaigns(base: merged, remoteCampaigns: remoteCampaigns, dismissedIds: dismissedIds)
        applyCampaignOverrides(into: &merged, active: active)
        return merged
    }

    /// Disk campaigns + on-disk dismiss (`campaigns_state.json`); **no remote,
    /// no env override**. Named to make the divergence from the shell's
    /// remote-aware `load_effective_config` explicit at every call site.
    public func effectiveConfigDiskOnly(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TOMLValue {
        effectiveConfigWithCampaigns(
            remoteCampaigns: [],
            dismissedIds: loadDismissedIdsFromHome(environment: environment)
        )
    }

    public func hasManaged() -> Bool {
        if case let .table(t) = managed, !t.isEmpty { return true }
        if case let .table(t) = systemManaged, !t.isEmpty { return true }
        return false
    }

    public func hasSystemManaged() -> Bool {
        if case let .table(t) = systemManaged, !t.isEmpty { return true }
        return false
    }
}

/// `GROK_CAMPAIGNS=0` or `[features] campaigns = false` on pre-campaign base.
public func campaignsApplicationDisabled(
    base baseEffectiveness: TOMLValue,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    if envBool("GROK_CAMPAIGNS", environment: environment) == false { return true }
    if case let .boolean(v) = baseEffectiveness[path: ["features", "campaigns"]] {
        return v == false
    }
    return false
}

/// Disk layers only (no remote, no env override). Prefer the shell loader
/// when remote campaigns or `GROK_CAMPAIGNS_OVERRIDE` must be honored. The
/// name mirrors `ConfigLayers.effectiveConfigDiskOnly` so the divergence from
/// the remote-aware loader is un-ignorable at every call site.
public func loadEffectiveConfigDiskOnly(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> TOMLValue {
    try ConfigLayers.load(environment: environment).effectiveConfigDiskOnly(environment: environment)
}

// MARK: - CampaignsState (on-disk dismiss list)

/// On-disk campaign dismiss state. Single source of truth for the file's
/// name, location, and JSON shape — the shell's writer reuses these so the
/// read and write sides can't drift.
public let CAMPAIGNS_STATE_FILE = "campaigns_state.json"

public struct CampaignsState: Hashable, Sendable, Codable, Equatable {
    public var dismissedIds: [String]

    public init(dismissedIds: [String] = []) {
        self.dismissedIds = dismissedIds
    }

    private enum CodingKeys: String, CodingKey {
        case dismissedIds = "dismissed_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dismissedIds = try c.decodeIfPresent([String].self, forKey: .dismissedIds) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dismissedIds, forKey: .dismissedIds)
    }
}

/// Path to `$OPENGROK_HOME/campaigns_state.json` under `home`.
public func campaignsStatePath(_ home: URL) -> URL {
    home.appendingPathComponent(CAMPAIGNS_STATE_FILE)
}

/// Fail-open dismissed ids from `$OPENGROK_HOME/campaigns_state.json`.
/// Returns `[]` when the file is absent or unreadable.
public func loadDismissedIdsFromHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Set<String> {
    guard let home = userGrokHome(environment: environment) else { return [] }
    let path = campaignsStatePath(home)
    guard let contents = try? String(contentsOf: path, encoding: .utf8) else { return [] }
    guard let data = contents.data(using: .utf8) else { return [] }
    guard let state = try? JSONDecoder().decode(CampaignsState.self, from: data) else { return [] }
    return Set(state.dismissedIds)
}

// MARK: - applyVersionOverridesWithRegistered

/// Applies matching `[[version_overrides]]` patches against the running CLI
/// version; strips the section either way. If the installed version can't be
/// parsed (broken `GROK_TEST_VERSION` in dev), silently strips without
/// applying — keeps the CLI usable on a bad dev override.
public func applyVersionOverridesWithRegistered(
    _ value: inout TOMLValue,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    do {
        let version = try OpenGrokVersion.installedSemVer(environment: environment)
        try applyVersionOverrides(&value, version: version)
    } catch {
        // Broken GROK_TEST_VERSION in dev: strip the section without applying.
        if case var .table(t) = value {
            t.removeValue(forKey: VERSION_OVERRIDES_KEY)
            value = .table(t)
        }
    }
}

// MARK: - deep_merge_toml

/// Recursively merge `overrides` into `base`. Values in `overrides` win.
/// Mirrors Rust `deep_merge_toml`. Arrays replace (not concatenate); nested
/// tables merge; missing keys insert.
public func deepMergeTOML(_ base: inout TOMLValue, overrides: TOMLValue) {
    switch (base, overrides) {
    case (var .table(baseTable), let .table(overridesTable)):
        for (key, value) in overridesTable.pairs {
            if let existing = baseTable[key] {
                var existingCopy = existing
                deepMergeTOML(&existingCopy, overrides: value)
                baseTable[key] = existingCopy
            } else {
                baseTable[key] = value
            }
        }
        base = .table(baseTable)
    default:
        base = overrides
    }
}

// MARK: - $VAR expansion

/// Expand `$VAR` / `${VAR}` in all string values.
public func expandEnvVarsInTOML(_ value: inout TOMLValue) {
    switch value {
    case var .string(s):
        let expanded = expandEnvVarsInString(s)
        if expanded != s { s = expanded }
        value = .string(s)
    case var .array(items):
        for i in items.indices { expandEnvVarsInTOML(&items[i]) }
        value = .array(items)
    case var .table(t):
        for (k, v) in t.pairs {
            var copy = v
            expandEnvVarsInTOML(&copy)
            t[k] = copy
        }
        value = .table(t)
    default:
        break
    }
}

/// Expand `$VAR` / `${VAR}` in a single string. Unknown vars are left as-is
/// (mirrors `shellexpand::env_with_context_no_errors`).
public func expandEnvVarsInString(
    _ input: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    var out = ""
    var i = input.startIndex
    while i < input.endIndex {
        let c = input[i]
        if c != "$" {
            out.append(c)
            i = input.index(after: i)
            continue
        }
        // `$` at end of string → literal `$`.
        let next = input.index(after: i)
        if next == input.endIndex {
            out.append("$")
            i = next
            continue
        }
        let nextCh = input[next]
        if nextCh == "{" {
            // `${VAR}` form.
            guard let close = input[next...].firstIndex(of: "}") else {
                // No closing brace: leave literal `$` and continue.
                out.append("$")
                i = next
                continue
            }
            let nameRange = input.index(after: next)..<close
            let name = String(input[nameRange])
            if let v = environment[name] {
                out += v
            } else {
                // Unknown var: leave the literal `${VAR}` (shellexpand
                // `env_with_context_no_errors` returns the original on
                // unknown; we mimic that by emitting the literal).
                out += String(input[i...close])
            }
            i = input.index(after: close)
        } else if nextCh.isLetter || nextCh == "_" {
            // `$VAR` bare-name form: read [A-Za-z_][A-Za-z0-9_]*.
            var end = next
            while end < input.endIndex {
                let ch = input[end]
                if ch.isLetter || ch.isNumber || ch == "_" {
                    end = input.index(after: end)
                } else { break }
            }
            let name = String(input[next..<end])
            if let v = environment[name] {
                out += v
            } else {
                out += String(input[i..<end])
            }
            i = end
        } else {
            // `$` followed by a non-name char: literal `$`.
            out.append("$")
            i = next
        }
    }
    return out
}
