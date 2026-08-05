// InstallLayout.swift
//
// Where an install lands, and which destinations the installer refuses.
//
// From `install.sh`:
//
//   :71-77   open_grok_home="${OPENGROK_HOME:-$HOME/.opengrok}"
//            managed_bin_dir="${open_grok_home}/bin"
//            bin_dir="${OPEN_GROK_BIN_DIR:-$managed_bin_dir}"
//            (HOME or OPENGROK_HOME must be set, else hard failure)
//   :79-90   both directories must be absolute, and must not contain `:`,
//            newline, or carriage return
//   :92      download_dir="${open_grok_home}/downloads"
//   :157     versioned_name="open-grok-${installed_version}-macos-aarch64"
//            (a `-reinstall-$$` suffix is appended when that path is taken)
//
// The `~/.grok` legacy directory is never read or written; that invariant is
// already encoded in `OpenGrokBuildSupport.OpenGrokBranding` and is asserted
// here rather than restated.

import Foundation
import OpenGrokBuildSupport

/// The on-disk layout an Open Grok install writes into.
public struct InstallLayout: Sendable, Hashable {
    /// `$OPENGROK_HOME`, or `$HOME/.opengrok`.
    public let home: String
    /// `$OPENGROK_HOME/bin` — the directory the managed binary always lands in.
    public var managedBinDirectory: String { home + "/bin" }
    /// `$OPENGROK_HOME/downloads` — staging for versioned downloads.
    public var downloadDirectory: String { home + "/downloads" }
    /// The PATH-facing directory, `$OPEN_GROK_BIN_DIR` when set.
    public let binDirectory: String

    /// The managed binary path, `$OPENGROK_HOME/bin/open-grok`.
    public var managedBinaryPath: String {
        home + "/" + OpenGrokBranding.managedBinarySubpath
    }

    /// Why a layout could not be resolved.
    public enum ResolutionFailure: Error, Sendable, Hashable, CustomStringConvertible {
        /// Neither `HOME` nor `OPENGROK_HOME` was set (`install.sh:69-72`).
        case noHomeAvailable
        /// A bin directory was not an absolute path (`install.sh:80-86`).
        case binDirectoryNotAbsolute(String)
        /// A bin directory contained `:`, newline, or carriage return
        /// (`install.sh:87-90`).
        case binDirectoryHasUnsupportedCharacters(String)
        /// The resolved home was the forbidden legacy `~/.grok` directory.
        case legacyHomeForbidden(String)

        public var description: String {
            switch self {
            case .noHomeAvailable:
                return "HOME or OPENGROK_HOME must be set"
            case .binDirectoryNotAbsolute(let path):
                return "the Open Grok bin directory must be an absolute path: \(path)"
            case .binDirectoryHasUnsupportedCharacters(let path):
                return "the Open Grok bin directory contains unsupported characters: \(path)"
            case .legacyHomeForbidden(let path):
                return "Open Grok never reads or writes the legacy home directory: \(path)"
            }
        }
    }

    /// Resolve the layout from the environment the installer sees.
    ///
    /// - Parameters:
    ///   - openGrokHome: `$OPENGROK_HOME`.
    ///   - userHome: `$HOME`.
    ///   - binDirectoryOverride: `$OPEN_GROK_BIN_DIR`.
    public static func resolve(
        openGrokHome: String?,
        userHome: String?,
        binDirectoryOverride: String? = nil
    ) -> Result<InstallLayout, ResolutionFailure> {
        let home: String
        if let explicit = openGrokHome, !explicit.isEmpty {
            home = explicit
        } else if let user = userHome, !user.isEmpty {
            home = user + "/" + OpenGrokBranding.fallbackStateDirectoryName
        } else {
            return .failure(.noHomeAvailable)
        }

        if home.hasSuffix("/" + OpenGrokBranding.legacyForbiddenStateDirectoryName) {
            return .failure(.legacyHomeForbidden(home))
        }

        let managedBin = home + "/bin"
        let binDirectory: String
        if let override = binDirectoryOverride, !override.isEmpty {
            binDirectory = override
        } else {
            binDirectory = managedBin
        }

        for candidate in [managedBin, binDirectory] {
            if !candidate.hasPrefix("/") {
                return .failure(.binDirectoryNotAbsolute(candidate))
            }
            if candidate.contains(":") || candidate.contains("\n") || candidate.contains("\r") {
                return .failure(.binDirectoryHasUnsupportedCharacters(candidate))
            }
        }

        return .success(InstallLayout(home: home, binDirectory: binDirectory))
    }

    private init(home: String, binDirectory: String) {
        self.home = home
        self.binDirectory = binDirectory
    }

    /// The staged, versioned download name for an installed binary.
    ///
    /// `install.sh:157` builds `open-grok-${installed_version}-macos-aarch64`
    /// — the version is spliced into the middle of the platform artifact name,
    /// not appended.
    ///
    /// The reference defines this only for macOS (its POSIX installer refuses
    /// every other platform). The Windows form keeps the `.exe` extension last
    /// so the staged file stays executable on that OS.
    public static func versionedDownloadName(
        version: ReleaseVersion,
        platform: ReleasePlatform
    ) -> String {
        let stem = "\(OpenGrokBranding.executableName)-\(version.value)-\(platform.rawValue)"
        return platform == .windowsX86_64 ? stem + ".exe" : stem
    }

    /// The full staged path for a versioned download.
    public func versionedDownloadPath(
        version: ReleaseVersion,
        platform: ReleasePlatform
    ) -> String {
        downloadDirectory + "/" + InstallLayout.versionedDownloadName(
            version: version,
            platform: platform
        )
    }
}
