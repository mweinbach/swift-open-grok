// SmokeValidation.swift
//
// Executable smoke assertions, and the isolated-home behaviour the release
// workflow proves before publishing.
//
// Version-output shape — `scripts/build-macos-release.sh`:
//     version_output="$($staged_artifact --version)"
//     [[ "$version_output" != *"$version"* ]] -> fail
//     [[ "$version_output" != *"$commit"*  ]] -> fail
// and the same pair of assertions after installation in
// `.github/workflows/release.yml`:
//     "$smoke_root/bin/open-grok" --version | grep -F "$(cat OPEN_GROK_VERSION)"
//     "$smoke_root/bin/open-grok" --version | grep -F "$(git rev-parse --short HEAD)"
//
// Reported-version extraction — `install.sh:139-151` pulls the first
// whitespace-separated token that matches the release version pattern out of
// `--version` output, requires it to be well-formed, and requires it to equal
// the requested version when one was requested.
//
// Isolated home — the same workflow step runs the installer against a mktemp
// root:
//     export OPENGROK_HOME="$smoke_root/home"
//     export OPEN_GROK_BIN_DIR="$smoke_root/bin"
// and then executes `"$smoke_root/bin/open-grok"`, proving the install wrote
// only inside the isolated root.

import Foundation
import OpenGrokDistributionSupport

/// Smoke assertions over a release binary's `--version` output and the paths an
/// isolated install touched.
public enum SmokeValidation {
    // MARK: - Version output

    /// Extract the first token of `output` that looks like a release version.
    ///
    /// Mirrors the `awk` scan in `install.sh:139`: split on whitespace, return
    /// the first field matching the release version pattern.
    public static func reportedVersion(in output: String) -> String? {
        for field in output.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = String(field)
            if isWellFormedVersion(candidate) { return candidate }
        }
        return nil
    }

    /// Whether `candidate` matches the reference's release version pattern:
    /// `^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$`.
    ///
    /// Forwards to `ReleaseVersion.isValid`, which owns that pattern. This
    /// target used to carry a second copy because it had no dependency edge to
    /// `OpenGrokDistributionSupport`; the edge now exists, so the rule has one
    /// implementation. Unlike `ReleaseVersion.init(_:)` this does not strip a
    /// leading `v` — `--version` output is scanned for a bare version token.
    public static func isWellFormedVersion(_ candidate: String) -> Bool {
        ReleaseVersion.isValid(candidate)
    }

    /// Validate `--version` output against the release being built.
    ///
    /// - Parameters:
    ///   - output: everything the binary printed for `--version`.
    ///   - expectedVersion: the contents of `OPEN_GROK_VERSION`.
    ///   - expectedShortCommit: `git rev-parse --short HEAD`, or `nil` to skip
    ///     the commit assertion (the installer smoke has the commit available;
    ///     a consumer verifying a downloaded artifact may not).
    public static func validateVersionOutput(
        _ output: String,
        expectedVersion: String,
        expectedShortCommit: String?
    ) -> ReleaseValidationReport {
        var report = ReleaseValidationReport()

        guard let reported = reportedVersion(in: output) else {
            report.record(ReleaseValidationFinding(
                id: "smoke.versionMalformed",
                severity: .failure,
                subject: "--version",
                message: "output contains no well-formed version token: \(output)"
            ))
            return report
        }

        if reported == expectedVersion {
            report.record(ReleaseValidationFinding(
                id: "smoke.versionMatches",
                severity: .info,
                subject: "--version",
                message: "reports \(reported)"
            ))
        } else {
            report.record(ReleaseValidationFinding(
                id: "smoke.versionMismatch",
                severity: .failure,
                subject: "--version",
                message: "expected \(expectedVersion), binary reports \(reported)"
            ))
        }

        if let commit = expectedShortCommit {
            if output.contains(commit) {
                report.record(ReleaseValidationFinding(
                    id: "smoke.commitPresent",
                    severity: .info,
                    subject: "--version",
                    message: "output carries the build commit \(commit)"
                ))
            } else {
                report.record(ReleaseValidationFinding(
                    id: "smoke.commitMissing",
                    severity: .failure,
                    subject: "--version",
                    message: "output does not carry the build commit \(commit)"
                ))
            }
        }

        return report
    }

    // MARK: - Isolated home

    /// The environment variables the release workflow isolates before smoking
    /// the installer.
    public static let isolationEnvironmentVariables = ["OPENGROK_HOME", "OPEN_GROK_BIN_DIR"]

    /// The legacy home directory Open Grok must never read or write.
    public static let legacyForbiddenHomeSuffix = "/.grok"

    /// Validate that an install confined itself to its isolated root.
    ///
    /// - Parameters:
    ///   - isolatedRoot: the temporary root `OPENGROK_HOME` and
    ///     `OPEN_GROK_BIN_DIR` were pointed at.
    ///   - touchedPaths: every path the install created or wrote.
    public static func validateIsolatedHome(
        isolatedRoot: String,
        touchedPaths: [String]
    ) -> ReleaseValidationReport {
        var report = ReleaseValidationReport()

        guard isolatedRoot.hasPrefix("/") else {
            report.record(ReleaseValidationFinding(
                id: "isolation.rootNotAbsolute",
                severity: .failure,
                subject: isolatedRoot,
                message: "the isolated home root must be an absolute path"
            ))
            return report
        }

        // Compare on a slash-terminated prefix so `/tmp/x` does not appear to
        // contain `/tmp/xyz`.
        let rootPrefix = isolatedRoot.hasSuffix("/") ? isolatedRoot : isolatedRoot + "/"

        guard !touchedPaths.isEmpty else {
            report.record(ReleaseValidationFinding(
                id: "isolation.noPathsObserved",
                severity: .failure,
                subject: isolatedRoot,
                message: "no installed paths were observed; the smoke proved nothing"
            ))
            return report
        }

        for path in touchedPaths {
            if isLegacyHomePath(path) {
                report.record(ReleaseValidationFinding(
                    id: "isolation.legacyHome",
                    severity: .failure,
                    subject: path,
                    message: "Open Grok must never read or write the legacy ~/.grok tree"
                ))
                continue
            }
            if path != isolatedRoot && !path.hasPrefix(rootPrefix) {
                report.record(ReleaseValidationFinding(
                    id: "isolation.escaped",
                    severity: .failure,
                    subject: path,
                    message: "install wrote outside the isolated home \(isolatedRoot)"
                ))
                continue
            }
            report.record(ReleaseValidationFinding(
                id: "isolation.contained",
                severity: .info,
                subject: path,
                message: "inside the isolated home"
            ))
        }

        return report
    }

    /// Whether `path` names the forbidden legacy `~/.grok` tree.
    ///
    /// `.opengrok` must not trip this, so the match is on a whole path
    /// component rather than a substring.
    public static func isLegacyHomePath(_ path: String) -> Bool {
        path.split(separator: "/").contains(".grok")
    }
}
