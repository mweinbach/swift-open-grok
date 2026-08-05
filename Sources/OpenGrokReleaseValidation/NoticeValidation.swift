// NoticeValidation.swift
//
// Legal-text presence in a release.
//
// Both reference builders copy the same two files into `dist/` and fail the
// build if they are absent:
//
//     cp "${repo_root}/LICENSE"              "$staged_license"
//     cp "${repo_root}/THIRD-PARTY-NOTICES"  "$staged_notices"
//        — scripts/build-macos-release.sh
//     Copy-Item (Join-Path $repoRoot 'LICENSE')              $releaseLicense -Force
//     Copy-Item (Join-Path $repoRoot 'THIRD-PARTY-NOTICES')  $releaseNotices -Force
//        — scripts/build-windows-release.ps1:150-151
//
// `.github/workflows/release.yml` then uploads them with
// `if-no-files-found: error`, so a missing file is a release failure upstream
// too.
//
// `NOTICE` does NOT exist in the Rust reference tree at `80dff0a9`. It exists
// in the Swift port and PORT_PLAN.md's release gate requires it, so it is
// checked separately and labelled as port-added rather than being presented as
// upstream behaviour.

import Foundation

/// A legal-text asset presented for validation.
public struct LegalAsset: Sendable, Hashable {
    public let name: String
    /// The asset's contents, or `nil` when the file is absent.
    public let contents: String?

    public init(name: String, contents: String?) {
        self.name = name
        self.contents = contents
    }
}

/// LICENSE / NOTICE / THIRD-PARTY-NOTICES checks.
public enum NoticeValidation {
    /// Legal assets the Rust reference itself stages into `dist/`.
    public static let referenceRequiredNames = ["LICENSE", "THIRD-PARTY-NOTICES"]

    /// Legal assets PORT_PLAN.md's release gate requires that upstream does not
    /// ship in `dist/`.
    public static let portAddedRequiredNames = ["NOTICE"]

    /// Every legal asset a Swift-port release must carry.
    public static let requiredNames = referenceRequiredNames + portAddedRequiredNames

    /// Validate the legal assets of a release.
    ///
    /// A required file that is absent, empty, or whitespace-only is a failure:
    /// upstream's `if-no-files-found: error` covers absence, and an empty
    /// notices file would satisfy a presence-only check while shipping no
    /// attribution at all.
    public static func validate(assets: [LegalAsset]) -> ReleaseValidationReport {
        var report = ReleaseValidationReport()
        let byName = Dictionary(assets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for name in requiredNames {
            let isPortAdded = portAddedRequiredNames.contains(name)
            guard let asset = byName[name], let contents = asset.contents else {
                report.record(ReleaseValidationFinding(
                    id: "notices.missing",
                    severity: .failure,
                    subject: name,
                    message: isPortAdded
                        ? "required by the PORT_PLAN release gate (not shipped by the Rust reference) but absent"
                        : "staged by the reference release builders but absent"
                ))
                continue
            }

            if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.record(ReleaseValidationFinding(
                    id: "notices.empty",
                    severity: .failure,
                    subject: name,
                    message: "present but empty; a release must not ship blank legal text"
                ))
                continue
            }

            report.record(ReleaseValidationFinding(
                id: "notices.present",
                severity: .info,
                subject: name,
                message: isPortAdded ? "present (port-added)" : "present"
            ))
        }

        return report
    }
}
