// OpenGrokBuildSupport.swift
//
// Open Grok — Swift port. Bootstrap target W0-S1.
//
// This target is the Swift equivalent of the Rust `xai-proto-build` crate plus
// the root build/integration support surface. It owns:
//   * Open Grok branding constants (product name, state directory, env var).
//   * A dependency-free SHA-256 implementation used for fixture and release
//     checksums (no CryptoKit/swift-crypto dependency, so it is platform-neutral
//     and builds on macOS, Linux, and Windows).
//   * A deterministic generated-protocol fixture manifest and validator so the
//     `OpenGrokProtoBuildPlugin` command plugin and Wave 11 compatibility tests
//     can prove checked-in protocol fixtures are fresh without network access.
//   * The `ProtoCompiler` discovery contract ported from `xai-proto-build`.
//
// No slice other than W0-S1 may edit this directory.

import Foundation

// The public surface is declared across Branding.swift, SHA256.swift,
// GeneratedManifest.swift, FixtureValidator.swift, and ProtoBuildSupport.swift.
