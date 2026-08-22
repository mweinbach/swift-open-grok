// Validation.swift
//
// Port of `xai-grok-config/src/validation.rs`.
//
// Requirements layers and fail-closed enforcement. The user `requirements.toml`
// (cloud-cache, signed at rest once a key is embedded) and the system
// `/etc/opengrok/requirements.toml` are merged on top of the managed/user
// config. The macOS MDM layer is the highest requirements tier. Each layer
// may opt into `fail_closed = true`, which makes a broken `[[version_overrides]]`
// a hard startup error (otherwise the loader soft-fails the bad layer).

import Foundation
import OpenGrokConfigTypes
import OpenGrokCLIChatProxyTypes
import OpenGrokVersion

/// Compatibility helper used by the fork's managed-config response path.
/// Mirrors Rust `fail_closed_flag_from_str`.
public func failClosedFlagFromStr(_ requirements: String) -> Bool {
    failClosedFlagStatus(requirements).isEnabled
}

/// Where a requirements layer came from: a file on disk, or the macOS MDM
/// managed-preferences layer (admin-forced, no file). The typed split keeps a
/// caller from `exists()`/reading a layer that has no path.
public enum RequirementsSource: Sendable, Equatable, Hashable {
    case file(URL)
    case mdm

    /// Display/provenance label — a file path string, or the synthetic MDM
    /// source id (`ai.x.opengrok:…`). For diagnostics and matching only; the
    /// MDM layer has no file, so this is a label, never a `URL` to open.
    public var label: String {
        switch self {
        case let .file(p): return p.path
        case .mdm: return MDM_REQUIREMENTS_SOURCE
        }
    }
}

/// One requirements layer: the parsed TOML and where it came from.
public struct RequirementsLayer: Sendable, Equatable {
    public var value: TOMLValue
    public var source: RequirementsSource
    /// `true` = root-owned system layer. Security decisions must trust this
    /// flag, not re-derive from the source (`OPENGROK_HOME`-influenced, could
    /// carry `..`).
    public var isSystem: Bool

    public init(value: TOMLValue, source: RequirementsSource, isSystem: Bool) {
        self.value = value
        self.source = source
        self.isSystem = isSystem
    }
}

/// Errors from validating requirements layers at startup. Mirrors Rust
/// `RequirementsError` (one variant: `InvalidVersionOverrides`).
public enum RequirementsError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidVersionOverrides(path: String, source: VersionOverrideError)

    public var description: String {
        switch self {
        case let .invalidVersionOverrides(path, source):
            return "requirements at \(path) has invalid version_overrides under fail_closed: \(source)"
        }
    }
}

/// Env override for `fail_closed`. Named for prefix-alignment with
/// `GROK_MANAGED_CONFIG_URL`; only applies to `requirements.toml`.
public let FAIL_CLOSED_ENV = "GROK_MANAGED_CONFIG_FAIL_CLOSED"

/// All loaded requirements layers in apply order (user first, system last).
/// Use when you need per-layer source attribution; otherwise use
/// `loadMergedRequirements`.
public func requirementsLayers(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [RequirementsLayer] {
    var out: [RequirementsLayer] = []
    if let userPath = userGrokHome(environment: environment)?
        .appendingPathComponent("requirements.toml"),
       let value = loadRequirementsLayer(at: userPath, environment: environment)
    {
        out.append(RequirementsLayer(value: value, source: .file(userPath), isSystem: false))
    }
    if let dir = systemConfigDir() {
        let sysPath = dir.appendingPathComponent("requirements.toml")
        if let value = loadRequirementsLayer(at: sysPath, environment: environment) {
            out.append(RequirementsLayer(value: value, source: .file(sysPath), isSystem: true))
        }
    }
    // macOS MDM: OS-protected admin layer (forced values only). Pushed last so
    // it wins the deep-merge over the system file and cloud cache; `isSystem`
    // so security decisions trust it like the root-owned layer.
    if let value = mdmRequirementsValue(environment: environment) {
        out.append(RequirementsLayer(value: value, source: .mdm, isSystem: true))
    }
    return out
}

/// User + system requirements deep-merged, system wins on conflict. Use for
/// read-only consumers so user pins can't bypass system policy.
public func loadMergedRequirements(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> TOMLValue? {
    var iter = requirementsLayers(environment: environment).makeIterator()
    guard let first = iter.next() else { return nil }
    var merged = first.value
    while let layer = iter.next() {
        deepMergeTOML(&merged, overrides: layer.value)
    }
    return merged
}

/// The user requirements layer (`<home>/requirements.toml`), or `nil` with no
/// resolvable user home (rather than reading a cwd-relative `.opengrok`).
public func loadRequirements(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> TOMLValue? {
    guard let home = userGrokHome(environment: environment) else { return nil }
    return loadRequirementsLayer(
        at: home.appendingPathComponent("requirements.toml"),
        environment: environment
    )
}

/// The system `/etc/opengrok/requirements.toml` layer, or `nil` on platforms
/// without a system config dir.
public func loadSystemRequirements(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> TOMLValue? {
    guard let dir = systemConfigDir() else { return nil }
    return loadRequirementsLayer(
        at: dir.appendingPathComponent("requirements.toml"),
        environment: environment
    )
}

/// Soft-fails on errors; fail-closed enforcement lives in `validateRequirements`.
public func loadRequirementsLayer(
    at path: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> TOMLValue? {
    guard let v = try? loadTomlFile(at: path, environment: environment) else { return nil }
    guard case let .table(t) = v, !t.isEmpty else { return nil }
    return normalizeRequirementsValue(v, source: path.path, environment: environment)
}

/// Strip `fail_closed` and apply `[[version_overrides]]` for a parsed
/// requirements layer (file or MDM), so every source is normalized
/// identically. Returns `nil` (skip the layer) when version_overrides are
/// invalid for this build.
public func normalizeRequirementsValue(
    _ v: TOMLValue,
    source: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> TOMLValue? {
    var copy = v
    if case var .table(t) = copy {
        t.removeValue(forKey: failClosedKey)
        copy = .table(t)
    }
    do {
        try applyVersionOverridesWithRegistered(&copy, environment: environment)
    } catch {
        // Mirrors Rust `tracing::error!(source = ..., error = ..., "requirements rejected: invalid version_overrides; admin policy NOT applied")`.
        return nil
    }
    return copy
}

/// The MDM requirements layer (read + normalized), or `nil`. Shared so the
/// enforced view and the effective-config view agree.
public func mdmRequirementsValue(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> TOMLValue? {
    guard let raw = managedPreferencesRequirements() else { return nil }
    return normalizeRequirementsValue(raw, source: MDM_REQUIREMENTS_SOURCE, environment: environment)
}

/// Validates all requirements layers (user + system files, and macOS MDM).
/// Call once at startup from the binary's `main()`; exit on error.
public func validateRequirements(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    try validateUserRequirements(home: userGrokHome(environment: environment), environment: environment)
    if let dir = systemConfigDir() {
        try validateRequirementsLayer(at: dir.appendingPathComponent("requirements.toml"), environment: environment)
    }
    // MDM uses the raw value (fail_closed intact) so it's enforced like the files.
    if let mdm = managedPreferencesRequirements() {
        try validateRequirementsValue(mdm, source: .mdm, environment: environment)
    }
}

/// Validate the user requirements layer if a user home resolves; otherwise a
/// no-op (no cwd-relative `.opengrok/requirements.toml` is read or enforced).
public func validateUserRequirements(
    home: URL?,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    guard let home = home else { return }
    try validateRequirementsLayer(at: home.appendingPathComponent("requirements.toml"), environment: environment)
}

public func validateRequirementsLayer(
    at path: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    guard let v = try? loadTomlFile(at: path, environment: environment) else { return }
    try validateRequirementsValue(v, source: .file(path), environment: environment)
}

/// Fail-closed `[[version_overrides]]` validation for a parsed requirements
/// layer (file or MDM). Reads `fail_closed` before applying overrides so a
/// broken patch can't disable enforcement mid-load. `source` is the
/// provenance label in the error.
public func validateRequirementsValue(
    _ v: TOMLValue,
    source: RequirementsSource,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    if case let .table(t) = v, t.isEmpty { return }
    let failClosed = resolveFailClosedMode(v, environment: environment)
    let version: SemVerVersion
    do {
        version = try OpenGrokVersion.installedSemVer(environment: environment)
    } catch {
        return
    }
    var copy = v
    do {
        try applyVersionOverrides(&copy, version: version)
    } catch let e as VersionOverrideError {
        if failClosed {
            throw RequirementsError.invalidVersionOverrides(path: source.label, source: e)
        }
    }
}

/// `fail_closed` for `validateRequirements`'s version check: the admin file
/// flag is authoritative; the env can only TIGHTEN it (force-on), never loosen.
public func resolveFailClosedMode(
    _ requirements: TOMLValue,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    failClosedFlag(requirements) || envBool(FAIL_CLOSED_ENV, environment: environment) == true
}

/// `fail_closed` from a requirements table; non-bool → false (Rust `warn!`s
/// once and treats as false). Mirrors Rust `fail_closed_flag`.
public func failClosedFlag(_ requirements: TOMLValue) -> Bool {
    // Reuse the focused TOML parser from OpenGrokCLIChatProxyTypes: it
    // operates on the raw source string. Here we already have a `TOMLValue`,
    // so we read the root-level `fail_closed` key directly. A non-bool value
    // returns `false` (matching `.invalid` not being enabled).
    if case let .boolean(v) = requirements["fail_closed"] {
        return v
    }
    return false
}
