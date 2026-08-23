// OpenGrokDistributionSupport.swift
//
// Open Grok — Swift port of the release-artifact side of the Rust reference's
// distribution machinery (W11-S1).
//
// Every rule in this target is transcribed from a concrete artifact in the
// read-only Rust reference at `448a2afebcff7878465e8f67cd9c995c3ba00b9b`:
//
//   * `scripts/build-macos-release.sh`    — macOS artifact name, target triple,
//                                           version regex, `.sha256` line format,
//                                           the exact dist asset set, and the
//                                           version/commit smoke assertions.
//   * `scripts/build-linux-release.sh`    — x86_64/aarch64 artifact names, GNU
//                                           target triples, aliases, and the
//                                           shared POSIX installer and assets.
//   * `scripts/build-windows-release.ps1` — Windows artifact name and the
//                                           deliberately identical two-space
//                                           checksum line format.
//   * `install.sh`                        — release base-URL resolution, digest
//                                           parsing/validation, `$OPENGROK_HOME`
//                                           layout, bin-directory constraints,
//                                           and the versioned download name.
//   * `.github/workflows/release.yml`     — tag/version anchoring (`vX.Y.Z`) and
//                                           the published asset set.
//   * `crates/codegen/xai-grok-update/src/version.rs`
//                                         — release-channel semantics.
//   * `crates/codegen/xai-grok-version/src/lib.rs`
//                                         — channel-labelled version display.
//
// This target is a library: it computes and validates, it never shells out,
// downloads, or writes release artifacts. The release pipeline that will call
// it is a later slice.

import Foundation

/// Namespace marker for the distribution-support surface.
///
/// The real API lives in the sibling files of this target:
/// ``ReleasePlatform``, ``ReleaseVersion``, ``ReleaseChannel``,
/// ``ReleaseChecksum``, ``ReleaseArtifactLayout``, ``InstallLayout``, and
/// ``ShellCompletion``.
public enum OpenGrokDistributionSupport {
    /// The Rust reference revision every rule in this target was transcribed
    /// from. Kept in lockstep with `ProtocolFixtures/PROVENANCE.json`.
    public static let referenceRevision = "448a2afebcff7878465e8f67cd9c995c3ba00b9b"

    /// The upstream release pinned at ``referenceRevision`` (`OPEN_GROK_VERSION`).
    public static let referencePinnedRelease = "1.0.0-open-grok.81"
}
