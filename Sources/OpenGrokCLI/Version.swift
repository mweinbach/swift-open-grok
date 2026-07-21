// Version.swift
//
// Bootstrap Open Grok version constant. This mirrors the Rust reference
// `OPEN_GROK_VERSION` (`0.1.220-open-grok.21`) and the
// `xai-grok-version::installed()` behavior: the `GROK_TEST_VERSION` environment
// override takes precedence, then the compiled version. Once W0-S3
// (`OpenGrokVersion`) is integrated, this target imports it instead of
// maintaining a local copy.

import Foundation

public enum OpenGrokCLIVersion {
    /// Compiled-in Open Grok version (matches the reference `OPEN_GROK_VERSION`).
    public static let compiled = "0.1.220-open-grok.21"

    /// Environment variable that overrides the version for tests, matching the
    /// Rust reference `TEST_VERSION_ENV`.
    public static let testVersionEnvironmentVariable = "GROK_TEST_VERSION"

    /// Resolve the installed version string: `GROK_TEST_VERSION` override first
    /// (trimmed), then the compiled version.
    public static func installed(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[testVersionEnvironmentVariable], !override.isEmpty {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return compiled
    }
}
