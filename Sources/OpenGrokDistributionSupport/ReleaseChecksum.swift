// ReleaseChecksum.swift
//
// SHA-256 sidecar generation and verification.
//
// Generation — `scripts/build-macos-release.sh`:
//     checksum="$(shasum -a 256 "$staged_artifact" | awk '{ print $1 }')"
//     printf '%s  %s\n' "$checksum" "$artifact_name" > "$staged_checksum"
//
// The Windows builder reproduces the same line deliberately
// (`scripts/build-windows-release.ps1:144-145`):
//     # Two-space separator matches the macOS artifact's `shasum` format.
//     $checksumLine = "$checksum  $artifactName"
//
// Verification — `install.sh:107-131`:
//     expected_sha="$(awk 'NR == 1 { print $1 }' "$checksum_tmp")"
//     [[ ${#expected_sha} -ne 64 || "$expected_sha" == *[!0-9A-Fa-f]* ]]  -> reject
//     ...then both sides are lower-cased before comparison.
//
// The digest itself comes from OpenGrokBuildSupport.SHA256 so the package has
// exactly one SHA-256 implementation.

import Foundation
import OpenGrokBuildSupport

/// A parsed `<artifact>.sha256` sidecar.
public struct ReleaseChecksum: Sendable, Hashable {
    /// Lowercase 64-character hex digest.
    public let digest: String
    /// The artifact basename named on the checksum line.
    public let artifactName: String

    public init?(digest: String, artifactName: String) {
        guard let normalized = ReleaseChecksum.normalizedDigest(digest) else { return nil }
        guard !artifactName.isEmpty else { return nil }
        self.digest = normalized
        self.artifactName = artifactName
    }

    /// Render the sidecar file contents.
    ///
    /// Exactly `"<digest>  <name>\n"` — two spaces, trailing newline — matching
    /// `printf '%s  %s\n'` in the macOS builder and the explicitly
    /// format-matched Windows line.
    public var fileContents: String { "\(digest)  \(artifactName)\n" }

    // MARK: - Generation

    /// Compute the sidecar for `data` published under `artifactName`.
    public static func generate(for data: [UInt8], artifactName: String) -> ReleaseChecksum? {
        ReleaseChecksum(digest: SHA256.hexDigest(data), artifactName: artifactName)
    }

    /// Compute the sidecar for `data` published under `artifactName`.
    public static func generate(for data: Data, artifactName: String) -> ReleaseChecksum? {
        generate(for: Array(data), artifactName: artifactName)
    }

    // MARK: - Parsing

    /// Why a `.sha256` sidecar could not be used.
    public enum ParseFailure: Error, Sendable, Hashable, CustomStringConvertible {
        /// The file was empty or contained only blank lines.
        case empty
        /// The first line's first field was not a 64-character hex digest.
        case malformedDigest(String)

        public var description: String {
            switch self {
            case .empty:
                return "release checksum file is empty"
            case .malformedDigest(let field):
                return "release checksum is not a valid SHA-256 digest: \(field)"
            }
        }
    }

    /// Parse a `.sha256` sidecar.
    ///
    /// Follows `install.sh` exactly: only the **first** line is considered, the
    /// digest is its first whitespace-separated field, and the digest must be
    /// 64 hex characters. The artifact name is the remainder of the line when
    /// present — `install.sh` ignores it, but a validating pipeline should not,
    /// so it is surfaced rather than dropped. When the line carries no name,
    /// `fallbackArtifactName` is used.
    public static func parse(
        fileContents: String,
        fallbackArtifactName: String
    ) -> Result<ReleaseChecksum, ParseFailure> {
        // Split on any newline character: Swift models CRLF as one Character,
        // so splitting on the literal "\n" would not terminate a `\r\n` line.
        guard let firstLine = fileContents.split(whereSeparator: \.isNewline).first else {
            return .failure(.empty)
        }

        let fields = firstLine.split(whereSeparator: { $0.isWhitespace })
        guard let digestField = fields.first else { return .failure(.empty) }
        guard let digest = normalizedDigest(String(digestField)) else {
            return .failure(.malformedDigest(String(digestField)))
        }

        let name = fields.count > 1 ? String(fields[1]) : fallbackArtifactName
        guard let checksum = ReleaseChecksum(digest: digest, artifactName: name) else {
            return .failure(.malformedDigest(String(digestField)))
        }
        return .success(checksum)
    }

    // MARK: - Verification

    /// The outcome of comparing a sidecar against real bytes.
    public enum Verification: Sendable, Hashable {
        case matched
        case mismatched(expected: String, actual: String)

        public var isMatch: Bool { self == .matched }
    }

    /// Verify `data` against this sidecar.
    ///
    /// Comparison is case-insensitive because `install.sh:126-128` lower-cases
    /// both sides before comparing.
    public func verify(_ data: [UInt8]) -> Verification {
        let actual = SHA256.hexDigest(data)
        return actual == digest ? .matched : .mismatched(expected: digest, actual: actual)
    }

    /// Verify `data` against this sidecar.
    public func verify(_ data: Data) -> Verification { verify(Array(data)) }

    // MARK: - Helpers

    /// Lower-case and validate a candidate digest: exactly 64 hex characters.
    ///
    /// Mirrors `install.sh:108-112` (length check plus a hex character-class
    /// rejection) followed by the lower-casing at `:126-127`.
    public static func normalizedDigest(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64 else { return nil }
        guard trimmed.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return trimmed.lowercased()
    }
}
