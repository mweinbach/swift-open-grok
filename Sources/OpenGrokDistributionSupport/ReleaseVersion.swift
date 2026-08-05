// ReleaseVersion.swift
//
// Release version and tag rules.
//
// The reference validates the release version string in three independent
// places with a single regex, and anchors the git tag to it:
//
//   scripts/build-macos-release.sh:25
//     [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]
//   scripts/build-windows-release.ps1:28   (same pattern)
//   install.sh:30                          (same pattern, applied to the CLI argument)
//   .github/workflows/release.yml          `version="${tag#v}"` then
//                                          `test "$version" = "$target_version"`
//                                          against `OPEN_GROK_VERSION`.
//
// Note the pattern is deliberately narrower than full SemVer: it accepts a
// dotted-or-dashed alphanumeric prerelease (`-open-grok.53`, `-alpha.4`) and
// rejects build metadata (`+sha`) entirely.

import Foundation

/// A validated Open Grok release version string.
public struct ReleaseVersion: Sendable, Hashable, CustomStringConvertible {
    /// The version without any leading `v`, e.g. `0.1.220-open-grok.53`.
    public let value: String

    public var description: String { value }

    /// The release tag form, e.g. `v0.1.220-open-grok.53`.
    ///
    /// `.github/workflows/release.yml` derives the version from the tag with
    /// `version="${tag#v}"`, so the tag is exactly `v` + the version.
    public var tag: String { "v" + value }

    /// The prerelease component (everything after the first `-`), or `nil`.
    public var prerelease: String? {
        guard let dash = value.firstIndex(of: "-") else { return nil }
        return String(value[value.index(after: dash)...])
    }

    /// Whether this is a prerelease (any version carrying a `-suffix`).
    public var isPrerelease: Bool { prerelease != nil }

    /// Create a version from a string that may optionally carry a leading `v`.
    ///
    /// Returns `nil` when the string does not match the reference's release
    /// version pattern.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        guard ReleaseVersion.isValid(stripped) else { return nil }
        self.value = stripped
    }

    /// The reference's release version pattern, anchored.
    ///
    /// Transcribed from `scripts/build-macos-release.sh:25`. Kept as a literal
    /// so the two implementations can be diffed by eye.
    public static let pattern = "^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$"

    /// Whether `candidate` (already `v`-stripped) matches ``pattern``.
    public static func isValid(_ candidate: String) -> Bool {
        // Hand-rolled rather than NSRegularExpression so the rule reads the
        // same on every platform and never depends on ICU availability.
        var rest = Substring(candidate)

        for index in 0..<3 {
            guard let digits = takeDigits(&rest), !digits.isEmpty else { return false }
            if index < 2 {
                guard rest.first == "." else { return false }
                rest = rest.dropFirst()
            }
        }

        if rest.isEmpty { return true }
        guard rest.first == "-" else { return false }
        rest = rest.dropFirst()

        // One or more alphanumeric groups separated by `.` or `-`.
        while true {
            let group = rest.prefix { $0.isASCIIAlphanumeric }
            if group.isEmpty { return false }
            rest = rest.dropFirst(group.count)
            if rest.isEmpty { return true }
            guard rest.first == "." || rest.first == "-" else { return false }
            rest = rest.dropFirst()
        }
    }

    private static func takeDigits(_ rest: inout Substring) -> Substring? {
        let digits = rest.prefix { $0.isASCIIDigit }
        guard !digits.isEmpty else { return nil }
        rest = rest.dropFirst(digits.count)
        return digits
    }

    /// Validate that a git tag and an `OPEN_GROK_VERSION` file agree.
    ///
    /// Mirrors the `resolve` job in `.github/workflows/release.yml`, which
    /// fails the release when `${tag#v}` differs from the version committed at
    /// the target sha.
    public static func tagMatchesVersionFile(tag: String, versionFileContents: String) -> Bool {
        // Split on any newline character. Swift models CRLF as a single
        // Character, so splitting on the literal "\n" would leave a
        // `\r\n`-terminated first line glued to the second — which is exactly
        // what `sed -n '1p' | tr -d '\r'` in the reference builder avoids.
        let fileVersion = versionFileContents
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard let tagged = ReleaseVersion(tag), let declared = ReleaseVersion(fileVersion) else {
            return false
        }
        return tagged == declared && tag == tagged.tag
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIIAlphanumeric: Bool { isASCII && (isNumber || isLetter) }
}
