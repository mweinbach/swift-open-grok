// OpenGrokTestUtilities.swift
//
// Open Grok — Swift port of `xai-test-utils` (Rust crate
// `crates/common/xai-test-utils`). Provides dependency-light test helpers
// shared by every later slice's test suite:
//
//   * `HermeticEnv` — the central acceptance primitive for W0-S2: creates an
//     isolated `HOME`, `USERPROFILE`, and `OPENGROK_HOME` and refuses any path
//     that resolves to the developer's real `~/.opengrok`.
//   * `EnvKnobs.envUsize` — perf-repro sizing knob (e.g. `GROK_PERF_GIT_FILES`).
//   * `HermeticGit` — git repo helpers that mask the developer's global/system
//     git config and disable credential prompts, so tests are deterministic
//     across machines.
//   * `ImageFixtures.icoWithPngFrame` — synthetic single-frame ICO fixture.
//   * `Runfiles.tryResolve` — Bazel runfiles resolution (returns nil under
//     SwiftPM, where `Bundle.module` / `#filePath` locate test data).
//   * `LogCapture.MessagePrefixCounter` — counts log lines by message prefix,
//     the Swift analog of `tracing_capture::MessagePrefixCounter` (the Rust
//     tracing layer lands in Wave 2; this counter works against the
//     dependency-free `TestLogger` it ships with).
//
// No slice other than W0-S2 may edit this directory.

import Foundation

/// Public surface for `OpenGrokTestUtilities`.
///
/// The individual types are declared in their own files in this directory;
/// this file documents the module-level contract only.
public enum OpenGrokTestUtilities {
    /// The Open Grok module name, for diagnostic use by downstream tests.
    public static let moduleName = "OpenGrokTestUtilities"
}
