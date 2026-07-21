// VersionOverrides.swift
//
// Port of `xai-grok-config/src/version_overrides.rs`.
//
// Version-aware config layering. A `[[version_overrides]]` array carries
// semver-gated patches deep-merged in ascending `minimum_version` order.
//
// ```toml
// [[version_overrides]]
// minimum_version = "1.7.0"
// [version_overrides.features]
// logging = true
//
// [[version_overrides]]
// minimum_version = "1.8.0"
// maximum_version = "1.9.999"
// [version_overrides.features.telemetry]
// enabled = true
// ```

import Foundation
import OpenGrokConfigTypes
import OpenGrokVersion

public let VERSION_OVERRIDES_KEY = "version_overrides"

/// Metadata header for a `[[version_overrides]]` entry. Both bounds are
/// optional; missing `minimumVersion` means no lower bound (0.0.0); missing
/// `maximumVersion` means no upper bound.
public struct VersionOverrideMeta: ConfigOverrideMeta, Equatable, Sendable {
    public var minimumVersion: String?
    public var maximumVersion: String?

    public init(minimumVersion: String? = nil, maximumVersion: String? = nil) {
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
    }

    public static var metaKeys: Set<String> { ["minimum_version", "maximum_version"] }

    public static func decode(from table: TOMLTable) throws -> VersionOverrideMeta {
        var min: String? = nil
        var max: String? = nil
        if case let .string(s) = table["minimum_version"] { min = s }
        if case let .string(s) = table["maximum_version"] { max = s }
        return VersionOverrideMeta(minimumVersion: min, maximumVersion: max)
    }
}

/// Errors from parsing or applying `[[version_overrides]]`.
public enum VersionOverrideError: Error, Equatable, Sendable, CustomStringConvertible {
    case deserialize(String)
    case invalidMinimumVersion(index: Int, value: String, reason: String)
    case invalidMaximumVersion(index: Int, value: String, reason: String)

    public var description: String {
        switch self {
        case let .deserialize(s):
            return "version_overrides: failed to deserialize: \(s)"
        case let .invalidMinimumVersion(index, value, reason):
            return "version_overrides[\(index)].minimum_version = \"\(value)\" is not valid semver: \(reason)"
        case let .invalidMaximumVersion(index, value, reason):
            return "version_overrides[\(index)].maximum_version = \"\(value)\" is not valid semver: \(reason)"
        }
    }
}

/// Strips `version_overrides` (always) and deep-merges each matching patch in
/// ascending `minimum_version` order. Throws `VersionOverrideError` for an
/// invalid semver bound or a malformed entry.
public func applyVersionOverrides(
    _ config: inout TOMLValue,
    version: SemVerVersion
) throws {
    let entries: [ConfigOverrideEntry<VersionOverrideMeta>]
    do {
        entries = try takePatchArray(&config, key: VERSION_OVERRIDES_KEY)
    } catch let e as TOMLError {
        throw VersionOverrideError.deserialize(e.description)
    }

    // Parse all bounds upfront so an invalid entry fails before any merge.
    // Missing minimum_version => SemVerVersion(0, 0, 0) (no lower bound).
    var parsed: [(SemVerVersion, SemVerVersion?, TOMLTable)] = []
    parsed.reserveCapacity(entries.count)
    for (index, entry) in entries.enumerated() {
        let minV: SemVerVersion
        if let s = entry.meta.minimumVersion {
            do {
                minV = try SemVerVersion.parse(s.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch let e as OpenGrokVersionError {
                throw VersionOverrideError.invalidMinimumVersion(
                    index: index, value: s, reason: e.description)
            } catch {
                throw VersionOverrideError.invalidMinimumVersion(
                    index: index, value: s, reason: String(describing: error))
            }
        } else {
            minV = SemVerVersion(major: 0, minor: 0, patch: 0)
        }
        var maxV: SemVerVersion? = nil
        if let s = entry.meta.maximumVersion {
            do {
                maxV = try SemVerVersion.parse(s.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch let e as OpenGrokVersionError {
                throw VersionOverrideError.invalidMaximumVersion(
                    index: index, value: s, reason: e.description)
            } catch {
                throw VersionOverrideError.invalidMaximumVersion(
                    index: index, value: s, reason: String(describing: error))
            }
        }
        parsed.append((minV, maxV, entry.patch))
    }

    // Stable sort — ties on minimum_version keep declared order so later
    // entries win.
    parsed.sort { $0.0 < $1.0 }

    let patches = parsed.compactMap { (minV, maxV, patch) -> TOMLTable? in
        if version < minV { return nil }
        if let maxV = maxV, version > maxV { return nil }
        return patch
    }
    applyPatches(into: &config, patches: patches, stripKeys: PATCH_STRIP_KEYS)
}
