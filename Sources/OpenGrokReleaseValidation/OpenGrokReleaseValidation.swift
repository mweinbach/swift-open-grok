// OpenGrokReleaseValidation.swift
//
// Open Grok — the release gate (W11-S5).
//
// This target implements the checks PORT_PLAN.md's release gate names, in the
// shape the Rust reference actually performs them:
//
//   * checksum verification            — install.sh:107-131
//   * LICENSE / THIRD-PARTY-NOTICES    — scripts/build-macos-release.sh,
//     (and the port-added NOTICE)        scripts/build-windows-release.ps1:150-151
//   * executable smoke assertions      — scripts/build-macos-release.sh (version
//                                        AND short commit must appear in
//                                        `--version` output), install.sh:135-151
//                                        (the installed binary must report a
//                                        well-formed version, and it must equal
//                                        the requested one), and the same two
//                                        greps in .github/workflows/release.yml
//   * isolated-home behaviour          — .github/workflows/release.yml's macOS
//                                        installer smoke, which points
//                                        OPENGROK_HOME and OPEN_GROK_BIN_DIR at a
//                                        mktemp root and asserts the install lands
//                                        there
//   * a validation report type         — this file
//
// Design note: this target deliberately takes digests as inputs rather than
// hashing bytes itself. `OpenGrokBuildSupport` owns the package's single
// SHA-256 implementation, while `OpenGrokDistributionSupport` owns the
// release baseline forwarded below.

import Foundation
import OpenGrokDistributionSupport

/// Namespace for the release gate.
public enum OpenGrokReleaseValidation {
    /// The Rust reference revision these checks were transcribed from.
    public static let referenceRevision = OpenGrokDistributionSupport.referenceRevision

    /// The upstream release pinned at ``referenceRevision``.
    public static let referencePinnedRelease = OpenGrokDistributionSupport.referencePinnedRelease
}

/// How badly a finding blocks a release.
public enum ReleaseValidationSeverity: String, Sendable, Hashable, Comparable, CaseIterable {
    /// Informational; never blocks.
    case info
    /// Something to fix, but the release may proceed.
    case warning
    /// Blocks the release.
    case failure

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .failure: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A single check result.
public struct ReleaseValidationFinding: Sendable, Hashable, CustomStringConvertible {
    /// Stable machine identifier, e.g. `checksum.mismatch`.
    public let id: String
    public let severity: ReleaseValidationSeverity
    /// What was checked, e.g. an asset name or path.
    public let subject: String
    /// Human-readable detail.
    public let message: String

    public init(
        id: String,
        severity: ReleaseValidationSeverity,
        subject: String,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.subject = subject
        self.message = message
    }

    public var description: String {
        "[\(severity.rawValue)] \(id) (\(subject)): \(message)"
    }
}

/// The accumulated result of a release audit.
public struct ReleaseValidationReport: Sendable, Hashable {
    public private(set) var findings: [ReleaseValidationFinding]

    public init(findings: [ReleaseValidationFinding] = []) {
        self.findings = findings
    }

    public mutating func record(_ finding: ReleaseValidationFinding) {
        findings.append(finding)
    }

    public mutating func merge(_ other: ReleaseValidationReport) {
        findings.append(contentsOf: other.findings)
    }

    /// Findings at or above `severity`.
    public func findings(atLeast severity: ReleaseValidationSeverity) -> [ReleaseValidationFinding] {
        findings.filter { $0.severity >= severity }
    }

    /// The highest severity recorded, or `nil` when nothing was recorded.
    public var highestSeverity: ReleaseValidationSeverity? {
        findings.map(\.severity).max()
    }

    /// Whether the release may ship: no `.failure` findings.
    ///
    /// A report with only warnings passes; an empty report passes trivially, so
    /// callers must assert on the checks they ran rather than on emptiness.
    public var passed: Bool {
        !findings.contains { $0.severity == .failure }
    }

    /// A stable multi-line rendering, ordered as recorded.
    public func render() -> String {
        if findings.isEmpty { return "release validation: no findings" }
        return findings.map(\.description).joined(separator: "\n")
    }
}
