// SemVerVersion.swift
//
// A minimal Semantic Versioning parser that preserves the Open Grok
// prerelease/channel strings (e.g. `0.1.220-open-grok.58`). The Rust reference
// uses the `semver` crate; this Swift port implements the subset of semver
// required by `xai-grok-version::installed_semver` and the Open Grok release
// channel format.
//
// Spec: https://semver.org
//   version      := major "." minor "." patch ( "-" prerelease )? ( "+" build )?
//   prerelease   := identifier ( "." identifier )*
//   build        := identifier ( "." identifier )*
//   identifier   := numeric-identifier | alphanumeric-identifier
//   numeric      := "0" | positive-digit *DIGIT
//   alphanumeric := *( ALPHA / DIGIT / "-" )  (must contain at least one
//                    non-digit character to distinguish from numeric)
//
// `Comparable` follows semver precedence: numeric prerelease identifiers are
// lower than alphanumeric ones, and a version with prerelease is lower than
// the same version without prerelease. Build metadata is ignored for ordering.

import Foundation

/// A parsed Semantic Version.
public struct SemVerVersion: Sendable, Equatable, Hashable, CustomStringConvertible {

    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64
    public let prerelease: [String]
    public let build: [String]

    public init(
        major: UInt64,
        minor: UInt64,
        patch: UInt64,
        prerelease: [String] = [],
        build: [String] = []
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    /// Parse a semver string. Throws `OpenGrokVersionError.invalidSemVer` on
    /// any deviation from the spec.
    public static func parse(_ input: String) throws -> SemVerVersion {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenGrokVersionError.invalidSemVer(input: input, reason: "empty input")
        }
        // Split off build metadata first (`+`), then prerelease (`-`).
        // The first `+` separates the version-core+prerelease from build.
        // The first `-` after the core (or after the start if no prerelease)
        // separates core from prerelease. Per semver, the build metadata comes
        // last and `+` may not appear in the core or prerelease.
        guard let plusIndex = trimmed.firstIndex(of: "+") else {
            return try parseWithoutBuild(trimmed, input: input)
        }
        let beforePlus = String(trimmed[..<plusIndex])
        let buildString = String(trimmed[trimmed.index(after: plusIndex)...])
        let buildIds = try parseDotIdentifiers(buildString, allowEmptyAlphanumeric: true,
                                               input: input, section: "build")
        var version = try parseWithoutBuild(beforePlus, input: input)
        version = SemVerVersion(
            major: version.major,
            minor: version.minor,
            patch: version.patch,
            prerelease: version.prerelease,
            build: buildIds
        )
        return version
    }

    private static func parseWithoutBuild(_ s: String, input: String) throws -> SemVerVersion {
        // Find the first `-` that separates core from prerelease. The core is
        // `MAJOR.MINOR.PATCH` with no `-`; the prerelease begins at the first
        // `-` after the patch.
        guard let dashIndex = s.firstIndex(of: "-") else {
            return try parseCore(s, input: input, prerelease: [])
        }
        let core = String(s[..<dashIndex])
        let prereleaseString = String(s[s.index(after: dashIndex)...])
        let prereleaseIds = try parsePrereleaseIdentifiers(prereleaseString, input: input)
        return try parseCore(core, input: input, prerelease: prereleaseIds)
    }

    private static func parseCore(_ s: String, input: String, prerelease: [String]) throws -> SemVerVersion {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw OpenGrokVersionError.invalidSemVer(
                input: input, reason: "core must have exactly 3 dot-separated numeric parts, got \(parts.count)"
            )
        }
        guard let major = UInt64(parts[0]), !parts[0].isEmpty, parts[0].allSatisfy(\.isWholeNumber) else {
            throw OpenGrokVersionError.invalidSemVer(input: input, reason: "major must be a non-negative integer")
        }
        guard let minor = UInt64(parts[1]), !parts[1].isEmpty, parts[1].allSatisfy(\.isWholeNumber) else {
            throw OpenGrokVersionError.invalidSemVer(input: input, reason: "minor must be a non-negative integer")
        }
        guard let patch = UInt64(parts[2]), !parts[2].isEmpty, parts[2].allSatisfy(\.isWholeNumber) else {
            throw OpenGrokVersionError.invalidSemVer(input: input, reason: "patch must be a non-negative integer")
        }
        // Reject leading zeros for numeric parts (per semver strict mode).
        if hasLeadingZero(parts[0]) || hasLeadingZero(parts[1]) || hasLeadingZero(parts[2]) {
            throw OpenGrokVersionError.invalidSemVer(input: input, reason: "numeric core parts must not have leading zeros")
        }
        return SemVerVersion(major: major, minor: minor, patch: patch,
                             prerelease: prerelease, build: [])
    }

    private static func hasLeadingZero(_ s: Substring) -> Bool {
        return s.count > 1 && s.first == "0"
    }

    private static func parsePrereleaseIdentifiers(_ s: String, input: String) throws -> [String] {
        if s.isEmpty {
            throw OpenGrokVersionError.invalidSemVer(input: input, reason: "prerelease must not be empty after '-'")
        }
        return try parseDotIdentifiers(s, allowEmptyAlphanumeric: false,
                                       input: input, section: "prerelease")
    }

    private static func parseDotIdentifiers(
        _ s: String,
        allowEmptyAlphanumeric: Bool,
        input: String,
        section: String
    ) throws -> [String] {
        if s.isEmpty {
            if allowEmptyAlphanumeric {
                throw OpenGrokVersionError.invalidSemVer(input: input, reason: "\(section) must not be empty after '+'")
            }
            throw OpenGrokVersionError.invalidSemVer(input: input, reason: "\(section) must not be empty")
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var ids: [String] = []
        ids.reserveCapacity(parts.count)
        for part in parts {
            let id = String(part)
            if id.isEmpty {
                throw OpenGrokVersionError.invalidSemVer(input: input, reason: "\(section) identifier must not be empty")
            }
            // Per semver, identifiers are alphanumeric [0-9A-Za-z-] or numeric.
            // Reject any other character.
            for scalar in id.unicodeScalars {
                let v = scalar.value
                let isDigit = (v >= Unicode.Scalar("0").value && v <= Unicode.Scalar("9").value)
                let isUpper = (v >= Unicode.Scalar("A").value && v <= Unicode.Scalar("Z").value)
                let isLower = (v >= Unicode.Scalar("a").value && v <= Unicode.Scalar("z").value)
                let isDash = scalar == "-"
                if !(isDigit || isUpper || isLower || isDash) {
                    throw OpenGrokVersionError.invalidSemVer(
                        input: input, reason: "\(section) identifier '\(id)' contains invalid character '\(scalar)'"
                    )
                }
            }
            // Numeric identifiers must not have leading zeros (unless the
            // identifier is exactly "0"). `UInt64(id)` recognizes the full
            // `u64` numeric range supported by the Rust `semver` crate.
            if let _ = UInt64(id), id.count > 1, id.first == "0" {
                throw OpenGrokVersionError.invalidSemVer(
                    input: input, reason: "\(section) numeric identifier '\(id)' must not have leading zeros"
                )
            }
            ids.append(id)
        }
        return ids
    }

    /// Render the version back to its canonical string form.
    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            s += "-" + prerelease.joined(separator: ".")
        }
        if !build.isEmpty {
            s += "+" + build.joined(separator: ".")
        }
        return s
    }
}

// MARK: - Comparable (semver precedence)

extension SemVerVersion: Comparable {
    public static func < (lhs: SemVerVersion, rhs: SemVerVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A version with prerelease is lower than the same version without.
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty && !rhs.prerelease.isEmpty { return false }
        if !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return true }

        // Compare prerelease identifiers per semver rules.
        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for i in 0..<count {
            let l = lhs.prerelease[i]
            let r = rhs.prerelease[i]
            let lNum = UInt64(l)
            let rNum = UInt64(r)
            switch (lNum, rNum) {
            case (let ln?, let rn?):
                if ln != rn { return ln < rn }
            case (_?, nil):
                // numeric < non-numeric
                return true
            case (nil, _?):
                return false
            default:
                // both non-numeric: compare lexically.
                if l != r { return l < r }
            }
        }
        // All shared identifiers equal; the shorter prerelease is lower.
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

// MARK: - Identifier helpers

extension SemVerVersion {
    /// `true` when the version has a prerelease tag (e.g. `-open-grok.57`).
    public var hasPrerelease: Bool { !prerelease.isEmpty }

    /// `true` when the version has build metadata (e.g. `+abc1234`).
    public var hasBuild: Bool { !build.isEmpty }

    /// The prerelease tag as a dot-joined string (e.g. `open-grok.57`), or
    /// empty when absent.
    public var prereleaseString: String {
        prerelease.joined(separator: ".")
    }

    /// The build metadata as a dot-joined string, or empty when absent.
    public var buildString: String {
        build.joined(separator: ".")
    }
}
