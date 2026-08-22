// ReleasePlatform.swift
//
// The platforms the reference actually publishes artifacts for, and the exact
// artifact names it publishes.
//
//   scripts/build-macos-release.sh:9-11
//     artifact_name="open-grok-macos-aarch64"
//     target_triple="aarch64-apple-darwin"
//   scripts/build-linux-release.sh:10-25
//     artifact_name="open-grok-linux-${arch}"
//     target_triple="${arch}-unknown-linux-gnu"
//   scripts/build-windows-release.ps1:18
//     $artifactName = 'open-grok-windows-x86_64.exe'

import Foundation

/// A platform the reference publishes a release artifact for.
public enum ReleasePlatform: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    /// Apple Silicon macOS (`aarch64-apple-darwin`).
    case macOSAppleSilicon = "macos-aarch64"
    /// 64-bit x86 Linux (`x86_64-unknown-linux-gnu`).
    case linuxX86_64 = "linux-x86_64"
    /// 64-bit ARM Linux (`aarch64-unknown-linux-gnu`).
    case linuxAarch64 = "linux-aarch64"
    /// 64-bit Windows (`x86_64-pc-windows-msvc`).
    case windowsX86_64 = "windows-x86_64"

    public var description: String { rawValue }

    /// The published binary asset name.
    ///
    /// - macOS: `open-grok-macos-aarch64` (`scripts/build-macos-release.sh:9`)
    /// - Linux: `open-grok-linux-${arch}` (`scripts/build-linux-release.sh:25`)
    /// - Windows: `open-grok-windows-x86_64.exe` (`scripts/build-windows-release.ps1:18`)
    public var artifactName: String {
        switch self {
        case .macOSAppleSilicon: return "open-grok-macos-aarch64"
        case .linuxX86_64: return "open-grok-linux-x86_64"
        case .linuxAarch64: return "open-grok-linux-aarch64"
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
        case .linuxX86_64: return "x86_64-unknown-linux-gnu"
        case .linuxAarch64: return "aarch64-unknown-linux-gnu"
        case .windowsX86_64: return "x86_64-pc-windows-msvc"
        }
    }

    /// The installer script published alongside the binary.
    ///
    /// The macOS and Linux builders copy the repo-root `install.sh`; Windows copies
    /// `crates/codegen/xai-grok-pager/scripts/install.ps1`
    /// (`scripts/build-windows-release.ps1:149`).
    public var installerAssetName: String {
        switch self {
        case .macOSAppleSilicon, .linuxX86_64, .linuxAarch64: return "install.sh"
        case .windowsX86_64: return "install.ps1"
        }
    }

    /// Whether the reference's `install.sh` will install onto this platform.
    ///
    /// `install.sh:35-53` accepts Apple Silicon macOS and x86_64/aarch64 Linux.
    /// Windows installs go through `install.ps1` instead.
    public var isSupportedByPosixInstaller: Bool {
        switch self {
        case .macOSAppleSilicon, .linuxX86_64, .linuxAarch64:
            return true
        case .windowsX86_64:
            return false
        }
    }

    /// Resolve the platform for a host OS/arch pair as reported by `uname`.
    ///
    /// Mirrors the exact host aliases in `install.sh:35-53`.
    public static func forPosixHost(unameS: String, unameM: String) -> ReleasePlatform? {
        switch (unameS, unameM) {
        case ("Darwin", "arm64"), ("Darwin", "aarch64"):
            return .macOSAppleSilicon
        case ("Linux", "x86_64"), ("Linux", "amd64"):
            return .linuxX86_64
        case ("Linux", "aarch64"), ("Linux", "arm64"):
            return .linuxAarch64
        default:
            return nil
        }
    }
}
