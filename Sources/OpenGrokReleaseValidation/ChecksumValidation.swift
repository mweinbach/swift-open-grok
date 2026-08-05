// ChecksumValidation.swift
//
// The reference verifies a release artifact before it will install it
// (`install.sh:107-131`):
//
//     expected_sha="$(awk 'NR == 1 { print $1 }' "$checksum_tmp")"
//     if [[ ${#expected_sha} -ne 64 || "$expected_sha" == *[!0-9A-Fa-f]* ]]; then
//         echo "Error: release checksum is not a valid SHA-256 digest." >&2
//     ...
//     expected_sha="$(printf '%s' "$expected_sha" | tr '[:upper:]' '[:lower:]')"
//     actual_sha="$(printf '%s' "$actual_sha"   | tr '[:upper:]' '[:lower:]')"
//     if [[ "$actual_sha" != "$expected_sha" ]]; then
//         echo "Error: SHA-256 verification failed; Open Grok was not installed."
//
// Two properties matter and are both reproduced here: the sidecar must be
// rejected as malformed *before* any comparison, and a mismatch must be a hard
// failure that leaves nothing installed.

import Foundation
import OpenGrokDistributionSupport

/// One artifact and the sidecar that claims to describe it.
public struct ChecksumClaim: Sendable, Hashable {
    /// The published asset name, e.g. `open-grok-macos-aarch64`.
    public let artifactName: String
    /// Raw contents of the `.sha256` sidecar.
    public let sidecarContents: String
    /// The digest actually computed over the artifact bytes, lowercase hex.
    public let actualDigest: String

    public init(artifactName: String, sidecarContents: String, actualDigest: String) {
        self.artifactName = artifactName
        self.sidecarContents = sidecarContents
        self.actualDigest = actualDigest
    }
}

/// Checksum verification for release artifacts.
public enum ChecksumValidation {
    /// Extract the expected digest from a sidecar.
    ///
    /// Only the first line is read and only its first whitespace-separated
    /// field is taken, exactly like `awk 'NR == 1 { print $1 }'`. The result is
    /// lower-cased and must be 64 hex characters.
    public static func expectedDigest(fromSidecar contents: String) -> String? {
        // Split on any newline character: Swift models CRLF as one Character,
        // so splitting on the literal "\n" would not terminate a `\r\n` line.
        guard let firstLine = contents.split(whereSeparator: \.isNewline).first else { return nil }

        guard let field = firstLine.split(whereSeparator: { $0.isWhitespace }).first
        else { return nil }

        return normalizedDigest(String(field))
    }

    /// Lower-case and validate a 64-character hex digest.
    public static func normalizedDigest(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64 else { return nil }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return trimmed.lowercased()
    }

    /// Validate one artifact against its sidecar.
    public static func validate(_ claim: ChecksumClaim) -> ReleaseValidationReport {
        var report = ReleaseValidationReport()

        guard let expected = expectedDigest(fromSidecar: claim.sidecarContents) else {
            report.record(ReleaseValidationFinding(
                id: "checksum.malformed",
                severity: .failure,
                subject: claim.artifactName,
                message: "release checksum is not a valid SHA-256 digest"
            ))
            return report
        }

        guard let actual = normalizedDigest(claim.actualDigest) else {
            report.record(ReleaseValidationFinding(
                id: "checksum.actualMalformed",
                severity: .failure,
                subject: claim.artifactName,
                message: "computed digest is not a valid SHA-256 digest: \(claim.actualDigest)"
            ))
            return report
        }

        if expected == actual {
            report.record(ReleaseValidationFinding(
                id: "checksum.verified",
                severity: .info,
                subject: claim.artifactName,
                message: "SHA-256 matches the published sidecar"
            ))
        } else {
            report.record(ReleaseValidationFinding(
                id: "checksum.mismatch",
                severity: .failure,
                subject: claim.artifactName,
                message: "SHA-256 verification failed; expected \(expected), got \(actual)"
            ))
        }
        return report
    }

    /// Validate every artifact in a release.
    ///
    /// An empty set is itself a failure: a release job that published no
    /// verifiable artifact has not been validated, and silently passing here
    /// would let an empty upload through the gate.
    public static func validate(all claims: [ChecksumClaim]) -> ReleaseValidationReport {
        var report = ReleaseValidationReport()
        guard !claims.isEmpty else {
            report.record(ReleaseValidationFinding(
                id: "checksum.noArtifacts",
                severity: .failure,
                subject: "release",
                message: "no artifacts were presented for checksum verification"
            ))
            return report
        }
        for claim in claims {
            report.merge(validate(claim))
        }
        return report
    }

    // MARK: - Hashing artifacts directly

    /// Build a claim by hashing `data` here rather than trusting a digest the
    /// caller computed.
    ///
    /// The digest comes from `ReleaseChecksum.generate`, which wraps the
    /// package's single SHA-256 (`OpenGrokBuildSupport.SHA256`), so validation
    /// and sidecar generation can never diverge on the hash. Before the
    /// `OpenGrokDistributionSupport` dependency edge existed this target could
    /// only accept `actualDigest` as an input.
    public static func claim(
        artifactName: String,
        contents data: Data,
        sidecarContents: String
    ) -> ChecksumClaim {
        ChecksumClaim(
            artifactName: artifactName,
            sidecarContents: sidecarContents,
            actualDigest: ReleaseChecksum.generate(
                for: data, artifactName: artifactName
            )?.digest ?? ""
        )
    }

    /// Verify an artifact on disk against the sidecar beside it.
    ///
    /// A file that cannot be read is a failure, not a skip: the gate must not
    /// pass because an artifact was missing.
    public static func validate(
        artifactName: String,
        at artifact: URL,
        sidecar: URL
    ) -> ReleaseValidationReport {
        var report = ReleaseValidationReport()
        guard let data = try? Data(contentsOf: artifact) else {
            report.record(ReleaseValidationFinding(
                id: "checksum.unreadableArtifact",
                severity: .failure,
                subject: artifactName,
                message: "could not read artifact at \(artifact.path)"
            ))
            return report
        }
        guard let sidecarContents = try? String(contentsOf: sidecar, encoding: .utf8) else {
            report.record(ReleaseValidationFinding(
                id: "checksum.unreadableSidecar",
                severity: .failure,
                subject: artifactName,
                message: "could not read checksum sidecar at \(sidecar.path)"
            ))
            return report
        }
        return validate(
            claim(
                artifactName: artifactName,
                contents: data,
                sidecarContents: sidecarContents
            )
        )
    }
}
