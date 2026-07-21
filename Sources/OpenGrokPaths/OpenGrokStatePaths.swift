// OpenGrokStatePaths.swift
//
// Open Grok state-directory resolution and path policy. This is the canonical
// implementation of the W0-S3 acceptance:
//
//   * `$OPENGROK_HOME` wins when set and non-empty.
//   * Otherwise the fallback is exactly `~/.opengrok` (joined with the user
//     home directory resolved from `HOME`, then `USERPROFILE`, then the
//     Foundation default).
//   * The legacy `~/.grok` path is NEVER read or written by any Open Grok
//     component; `isLegacyGrokPath` lets callers and tests assert rejection.
//   * Project-local state resolves to `.opengrok` under a project root.
//   * Managed binaries resolve under `$OPENGROK_HOME/bin/open-grok`.
//
// The bootstrap `OpenGrokCLI/OpenGrokHome` shim remains in place until the W0-S1
// integration owner switches it to import this target; the Package.swift edge
// is already predeclared so no manifest edit is required.

import Foundation

/// Canonical Open Grok path-policy constants.
///
/// These mirror `OpenGrokBranding` in `OpenGrokBuildSupport` (W0-S1). Both
/// targets agree on the same string values; this target cannot import
/// `OpenGrokBuildSupport` because the W0-S3 slice has no dependency edges, so
/// the constants are re-declared here as the runtime path-resolution authority.
public enum OpenGrokPathPolicy {
    /// The environment variable that overrides the state directory.
    public static let homeEnvironmentVariable = "OPENGROK_HOME"

    /// The fallback state directory name (relative to the user home directory).
    public static let fallbackStateDirectoryName = ".opengrok"

    /// The project-local state directory name.
    public static let projectStateDirectoryName = ".opengrok"

    /// The managed binary install location relative to `OPENGROK_HOME`.
    public static let managedBinarySubpath = "bin/open-grok"

    /// The legacy state directory name that must never be read or written.
    public static let legacyForbiddenStateDirectoryName = ".grok"
}

/// Open Grok state-directory and managed-binary resolution.
public enum OpenGrokStatePaths {

    /// Resolve the user home directory from `HOME`, then `USERPROFILE`, then
    /// the Foundation default. Pure with respect to `environment` so tests are
    /// deterministic.
    public static func userHomeDirectory(environment: [String: String]) -> URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        if let profile = environment["USERPROFILE"], !profile.isEmpty {
            return URL(fileURLWithPath: profile)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Resolve the Open Grok state-directory URL from `environment`.
    ///
    /// `OPENGROK_HOME` wins when set and non-empty; otherwise the user home
    /// directory is joined with `.opengrok`. The result is never `.grok`.
    public static func stateDirectory(environment: [String: String]) -> URL {
        if let override = environment[OpenGrokPathPolicy.homeEnvironmentVariable],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = userHomeDirectory(environment: environment)
        return home.appendingPathComponent(OpenGrokPathPolicy.fallbackStateDirectoryName)
    }

    /// The managed binary URL under a resolved `OPENGROK_HOME`.
    public static func managedBinaryURL(environment: [String: String]) -> URL {
        stateDirectory(environment: environment)
            .appendingPathComponent(OpenGrokPathPolicy.managedBinarySubpath)
    }

    /// The project-local state directory URL under `projectRoot`.
    public static func projectStateDirectory(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(OpenGrokPathPolicy.projectStateDirectoryName)
    }

    /// Returns `true` if `candidate` resolves to the forbidden legacy
    /// `~/.grok` path. Used by tests and guards to assert non-legacy behavior.
    public static func isLegacyGrokPath(_ candidate: URL, environment: [String: String]) -> Bool {
        let home = userHomeDirectory(environment: environment)
        let grok = home.appendingPathComponent(OpenGrokPathPolicy.legacyForbiddenStateDirectoryName)
            .standardizedFileURL.path
        return candidate.standardizedFileURL.path == grok
    }

    /// Returns `true` if `candidate` resolves to the canonical `~/.opengrok`
    /// fallback path for the given environment.
    public static func isFallbackOpenGrokPath(_ candidate: URL, environment: [String: String]) -> Bool {
        let home = userHomeDirectory(environment: environment)
        let fallback = home.appendingPathComponent(OpenGrokPathPolicy.fallbackStateDirectoryName)
            .standardizedFileURL.path
        return candidate.standardizedFileURL.path == fallback
    }
}
