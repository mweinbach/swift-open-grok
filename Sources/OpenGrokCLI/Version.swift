// Version.swift
//
// CLI version surface delegates to the canonical `OpenGrokVersion` semantics
// (including empty `GROK_TEST_VERSION` override parity with Rust
// `xai-grok-version::installed()`).

import Foundation
import OpenGrokVersion

public enum OpenGrokCLIVersion {
    /// Compiled-in Open Grok version (matches `OpenGrokVersion.compiledVersion`).
    public static var compiled: String { OpenGrokVersion.compiledVersion }

    /// Environment variable that overrides the version for tests, matching the
    /// Rust reference `TEST_VERSION_ENV`.
    public static let testVersionEnvironmentVariable =
        OpenGrokVersion.testVersionEnvironmentVariable

    /// Resolve the installed version string using canonical OpenGrokVersion
    /// semantics: presence of `GROK_TEST_VERSION` (even empty) is the override
    /// condition; its trimmed value is returned. When unset, the compiled
    /// version is used.
    public static func installed(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        OpenGrokVersion.installed(environment: environment)
    }
}
