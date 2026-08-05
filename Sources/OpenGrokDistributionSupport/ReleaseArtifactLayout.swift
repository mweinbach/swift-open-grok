// ReleaseArtifactLayout.swift
//
// What a release publishes, and where an installer fetches it from.
//
// Asset set — the two builders stage exactly these files into `dist/`:
//
//   scripts/build-macos-release.sh
//     dist/open-grok-macos-aarch64
//     dist/open-grok-macos-aarch64.sha256
//     dist/install.sh
//     dist/LICENSE
//     dist/THIRD-PARTY-NOTICES
//
//   scripts/build-windows-release.ps1:106-110
//     dist/open-grok-windows-x86_64.exe
//     dist/open-grok-windows-x86_64.exe.sha256
//     dist/install.ps1
//     dist/LICENSE
//     dist/THIRD-PARTY-NOTICES
//
// `.github/workflows/release.yml` uploads those per-platform sets and then
// re-downloads the published release and `cmp`s every asset byte-for-byte
// against the local one, so the asset set is exact rather than a minimum.
//
// Base URL — `install.sh:63-70`:
//     $OPEN_GROK_RELEASE_BASE_URL (trailing slash stripped)
//   else, with an explicit version:
//     https://github.com/$REPOSITORY/releases/download/v$version
//   else:
//     https://github.com/$REPOSITORY/releases/latest/download

import Foundation

/// The complete set of assets one platform's release job publishes.
public struct ReleaseArtifactLayout: Sendable, Hashable {
    public let platform: ReleasePlatform
    public let version: ReleaseVersion

    public init(platform: ReleasePlatform, version: ReleaseVersion) {
        self.platform = platform
        self.version = version
    }

    /// Legal text shipped with every platform's release.
    ///
    /// `LICENSE` and `THIRD-PARTY-NOTICES` are copied by both builders. `NOTICE`
    /// is not present in the Rust reference tree at this pin; it exists in the
    /// Swift port and is required by the PORT_PLAN.md release gate, so it is
    /// listed separately rather than being passed off as upstream behaviour.
    public static let referenceLegalAssetNames = ["LICENSE", "THIRD-PARTY-NOTICES"]

    /// Legal text the PORT_PLAN release gate requires but the Rust reference
    /// does not ship in `dist/`.
    public static let portAddedLegalAssetNames = ["NOTICE"]

    /// Every legal asset the Swift release gate requires.
    public static let legalAssetNames = referenceLegalAssetNames + portAddedLegalAssetNames

    /// Asset names published for this platform, in staging order.
    public var assetNames: [String] {
        [platform.artifactName, platform.checksumAssetName, platform.installerAssetName]
            + ReleaseArtifactLayout.legalAssetNames
    }

    /// Asset names the Rust reference itself publishes for this platform.
    ///
    /// Use this when asserting parity with an upstream release; use
    /// ``assetNames`` when validating a Swift-port release.
    public var referenceAssetNames: [String] {
        [platform.artifactName, platform.checksumAssetName, platform.installerAssetName]
            + ReleaseArtifactLayout.referenceLegalAssetNames
    }

    /// The `dist/`-relative path for an asset.
    public func distPath(for assetName: String) -> String { "dist/" + assetName }

    // MARK: - Download URLs

    /// The GitHub repository the reference's installer downloads from
    /// (`install.sh:5`).
    public static let defaultRepository = "mweinbach/open-grok"

    /// The environment variable that overrides the release base URL
    /// (`install.sh:63`).
    public static let baseURLEnvironmentVariable = "OPEN_GROK_RELEASE_BASE_URL"

    /// Resolve the base URL an installer downloads assets from.
    ///
    /// - Parameters:
    ///   - overrideBaseURL: `$OPEN_GROK_RELEASE_BASE_URL`, if set. Any trailing
    ///     slash is stripped, matching `"${OPEN_GROK_RELEASE_BASE_URL%/}"`.
    ///   - version: the requested version, or `nil` for "latest".
    ///   - repository: the GitHub `owner/name` slug.
    public static func releaseBaseURL(
        overrideBaseURL: String?,
        version: ReleaseVersion?,
        repository: String = defaultRepository
    ) -> String {
        if let override = overrideBaseURL, !override.isEmpty {
            var trimmed = override
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            return trimmed
        }
        if let version {
            return "https://github.com/\(repository)/releases/download/\(version.tag)"
        }
        return "https://github.com/\(repository)/releases/latest/download"
    }

    /// The download URL for a single asset under `baseURL`.
    public static func assetURL(baseURL: String, assetName: String) -> String {
        "\(baseURL)/\(assetName)"
    }
}
