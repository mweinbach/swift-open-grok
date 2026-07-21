// CompiledVersion.generated.swift
//
// REFERENCE FALLBACK — do not edit by hand. This file is EXCLUDED from
// target compilation (see Package.swift). The canonical version source is
// generated at build time by the `OpenGrokVersionBuildPlugin` build-tool
// plugin from the `GROK_VERSION` environment variable.
//
// This file is retained as a reference for the expected format and as a
// fallback for tools that do not run the build-tool plugin. The plugin
// generates a structurally identical file into the build output directory.
//
// This file is the SwiftPM equivalent of the Rust crate's
// `option_env!("GROK_VERSION")` compile-time injection in
// `xai-grok-version/src/lib.rs`. The Rust build.rs emits
// `cargo:rerun-if-env-changed=GROK_VERSION` so cargo rebuilds when the env var
// changes; the `OpenGrokVersionBuildPlugin` regenerates the version source on
// every clean build, achieving the same parity.
//
// The regeneration script (`regenerate-compiled-version.sh`) is retained as a
// manual fallback and is also excluded from target compilation. The
// build-tool plugin is the canonical generation path.

import Foundation

@usableFromInline
internal enum OpenGrokCompiledVersion {
    /// The compile-time Open Grok version, injected from `GROK_VERSION` at
    /// generation time. Mirrors the Rust `VERSION` constant.
    @usableFromInline
    internal static let version: String = "0.1.220-open-grok.21"
}
