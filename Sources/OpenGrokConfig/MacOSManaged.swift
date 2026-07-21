// MacOSManaged.swift
//
// Port of `xai-grok-config/src/macos_managed.rs`.
//
// macOS MDM managed-preferences layer. Admins push a device profile with
// standard-base64 (padded) TOML under preference domain `ai.x.opengrok`
// (`requirements_toml_base64`). Only admin-*forced* values are read, so a
// local user can't forge it via their own preference domain; trusted on every
// launch, independent of network/cache. Returns `nil` off macOS.
//
// The Swift port uses CoreFoundation's `CFPreferencesCopyAppValue` and
// `CFPreferencesAppValueIsForced` (via the C CoreFoundation bridge) on macOS.
// On other platforms the layer is always `nil`. The base64 decode and TOML
// parse are pure-Swift and unit-tested on every platform.

import Foundation

#if canImport(Darwin)
import Darwin
import CoreFoundation
#endif

/// Synthetic source label for the MDM layer (no file on disk); diagnostics only.
public let MDM_REQUIREMENTS_SOURCE = "ai.x.opengrok:requirements_toml_base64"

#if canImport(Darwin)
private let MANAGED_PREFERENCES_DOMAIN = "ai.x.opengrok"
private let REQUIREMENTS_KEY = "requirements_toml_base64"

/// Process-wide cache for the MDM requirements value. The forced policy is
/// fixed per launch, so a mid-session profile change isn't picked up until
/// restart — fine for a short-lived CLI, and it avoids re-crossing the
/// CoreFoundation boundary.
private let mdmCache: MDMCache = MDMCache()

private final class MDMCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: TOMLValue?
    private var initialized = false
    func get() -> TOMLValue? {
        lock.lock(); defer { lock.unlock() }
        if !initialized {
            cached = managedRequirementsFrom(readForcedRequirements)
            initialized = true
        }
        return cached
    }
    /// Test seam: reset the cache.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        initialized = false
    }
}
#endif

/// The MDM-forced requirements TOML, or `nil` when none is forced (or not
/// macOS).
public func managedPreferencesRequirements() -> TOMLValue? {
    #if canImport(Darwin)
    return mdmCache.get()
    #else
    return nil
    #endif
}

/// Decode the forced requirements from a raw-string reader. Split from the
/// FFI read (`readForcedRequirements`) so the forced → decode path is
/// unit-testable without CoreFoundation (the CFPreferences read/downcast
/// itself stays FFI).
///
/// Public for tests; not part of the stable API.
public func managedRequirementsFrom(_ read: () -> String?) -> TOMLValue? {
    guard let encoded = read() else { return nil }
    return decodeManagedTOML(encoded)
}

/// Decode a base64 TOML payload into a non-empty table. The forced payload is
/// used **verbatim** — `$VAR`/`${VAR}` are deliberately NOT expanded: this is
/// the trusted, non-forgeable admin layer, and expanding from the local
/// process environment would let the very user the forced check excludes
/// influence the policy (which feeds yolo / permission / minimum-version
/// enforcement). Invalid base64/UTF-8/TOML or an empty table yields `nil`.
public func decodeManagedTOML(_ encoded: String) -> TOMLValue? {
    // Strip all whitespace: profile tooling line-wraps payloads and the
    // STANDARD engine rejects interior whitespace.
    let compact = String(encoded.unicodeScalars.filter { !$0.properties.isWhitespace })
    guard let data = Data(base64Encoded: compact) else { return nil }
    guard let tomlStr = String(data: data, encoding: .utf8) else { return nil }
    guard let parsed = try? parseTOML(tomlStr) else { return nil }
    guard case let .table(t) = parsed, !t.isEmpty else { return nil }
    return parsed
}

#if canImport(Darwin)
/// The raw forced `requirements_toml_base64` MDM string via CoreFoundation,
/// or `nil`. macOS only. Reads only admin-forced values so a local user can't
/// forge an `is_system`-trusted layer via their own preference domain.
///
/// In Swift, CoreFoundation objects returned by `CFPreferencesCopyAppValue`
/// are automatically memory-managed (ARC); we do NOT call `CFRelease`
/// (it's marked unavailable under Swift ARC bridging).
private func readForcedRequirements() -> String? {
    let cfKey = REQUIREMENTS_KEY as CFString
    let cfApp = MANAGED_PREFERENCES_DOMAIN as CFString
    let forced = CFPreferencesAppValueIsForced(cfKey, cfApp)
    if !forced { return nil }
    guard let valueRef = CFPreferencesCopyAppValue(cfKey, cfApp) else { return nil }
    // Type-check before reading: reading a non-CFString as CFString would be
    // undefined behavior. `CFGetTypeID` compares against `CFStringGetTypeID`.
    if CFGetTypeID(valueRef) != CFStringGetTypeID() { return nil }
    let cfStr = valueRef as! CFString
    return cfStr as String
}

/// Test seam: reset the MDM cache so tests can re-inject.
public func _resetManagedPreferencesCache() {
    mdmCache.reset()
}
#endif
