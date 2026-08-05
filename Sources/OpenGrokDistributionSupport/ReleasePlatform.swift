// ReleasePlatform.swift
//
// The platforms the reference actually publishes artifacts for, and the exact
// artifact names it publishes.
//
//   scripts/build-macos-release.sh:9-11
//     artifact_name="open-grok-macos-aarch64"
//     target_triple="aarch64-apple-darwin"
//   scripts/build-windows-release.ps1:18
//     $artifactName = 'open-grok-windows-x86_64.exe'
//
// `install.sh:36-40` refuses to install on anything but Apple Silicon macOS,
// so a Linux release artifact does not exist at this pin. Modelling it here
// would invent a name no upstream job produces.

import Foundation

/// A platform the reference publishes a release artifact for.
public enum ReleasePlatform: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    /// Apple Silicon macOS (`aarch64-apple-darwin`).
    case macOSAppleSilicon = "macos-aarch64"
    /// 64-bit Windows (`x86_64-pc-windows-msvc`).
    case windowsX86_64 = "windows-x86_64"

    public var description: String { rawValue }

    /// The published binary asset name.
    ///
    /// - macOS: `open-grok-macos-aarch64` (`scripts/build-macos-release.sh:9`)
    /// - Windows: `open-grok-windows-x86_64.exe` (`scripts/build-windows-release.ps1:18`)
    public var artifactName: String {
        switch self {
        case .macOSAppleSilicon: return "open-grok-macos-aarch64"
        case .windowsX86_64: return "open-grok-windows-x86_64.exe"
        }
    }

    /// The `.sha256` sidecar asset name. Both builders append the suffix to the
    /// artifact name verbatim (`"$artifact_path.sha256"`).
    public var checksumAssetName: String { artifactName + ".sha256" }

    /// The Rust target triple the release profile is built for.
    public var targetTriple: String {
        switch self {
        case .macOSAppleSilicon: return "aarch64-apple-darwin"
        case .windowsX86_64: return "x86_64-pc-windows-msvc"
        }
    }

    /// The installer script published alongside the binary.
    ///
    /// macOS copies the repo-root `install.sh`
    /// (`scripts/build-macos-release.sh`); Windows copies
    /// `crates/codegen/xai-grok-pager/scripts/install.ps1`
    /// (`scripts/build-windows-release.ps1:149`).
    public var installerAssetName: String {
        switch self {
        case .macOSAppleSilicon: return "install.sh"
        case .windowsX86_64: return "install.ps1"
        }
    }

    /// Whether the reference's `install.sh` will install onto this platform.
    ///
    /// `install.sh:36-40` hard-fails on anything that is not Apple Silicon
    /// macOS. Windows installs go through `install.ps1` instead.
    public var isSupportedByPosixInstaller: Bool {
        self == .macOSAppleSilicon
    }

    /// Resolve the platform for a host OS/arch pair as reported by `uname`.
    ///
    /// Mirrors `install.sh:35-40`, which accepts `Darwin` with either `arm64`
    /// or `aarch64` and rejects everything else.
    public static func forPosixHost(unameS: String, unameM: String) -> ReleasePlatform? {
        guard unameS == "Darwin", unameM == "arm64" || unameM == "aarch64" else { return nil }
        return .macOSAppleSilicon
    }
}
