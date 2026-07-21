// Runfiles.swift
//
// Port of `xai-test-utils/src/runfiles_util.rs`. Under Bazel, source files
// and test data are accessed via the runfiles tree; under SwiftPM,
// `Bundle.module` (for resources declared in `Package.swift`) and
// `#filePath` (for source-adjacent test data) provide the equivalent. The
// `tryResolve` helper returns nil under SwiftPM so callers fall back to
// `#filePath` — mirroring the Rust macro `crate_root!` fallback to
// `CARGO_MANIFEST_DIR`.

import Foundation

/// Bazel runfiles helpers for locating test data.
public enum Runfiles {
    /// Try to resolve a runfiles path to an absolute URL.
    ///
    /// Returns `nil` under SwiftPM (no Bazel runfiles tree is available).
    /// When a future Bazel build is wired up, it can populate
    /// `RUNFILES_DIR` / `TEST_SRCDIR` and this will resolve against them.
    public static func tryResolve(_ path: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["RUNFILES_DIR"] ?? env["TEST_SRCDIR"] {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Resolve the crate/module root directory. Under Bazel, look up
    /// runfiles; under SwiftPM, fall back to `Bundle.module`'s bundle URL
    /// (when this target has resources) or the `#filePath` of the caller.
    public static func crateRoot(fallback: String = #filePath) -> URL {
        if let resolved = tryResolve("_main/Sources/OpenGrokTestUtilities") {
            return resolved
        }
        // Under SwiftPM, the source file's directory IS the crate root.
        return URL(fileURLWithPath: fallback).deletingLastPathComponent()
    }
}
