// OpenGrokHome.swift
//
// Bootstrap `OPENGROK_HOME` resolution. Behavior preserved from the Rust
// reference and `PORT_PLAN.md`:
//
//   * `$OPENGROK_HOME` wins when set and non-empty.
//   * Otherwise the fallback is exactly `~/.opengrok`.
//   * The legacy `~/.grok` path is NEVER read or written by any component.
//
// This is bootstrapped locally in OpenGrokCLI until W0-S3 (`OpenGrokPaths`)
// lands; the Package.swift edge to `OpenGrokPaths`/`OpenGrokEnvironment` is
// already predeclared so the switch requires no manifest edit.

import Foundation

public enum OpenGrokHomeResolver {
    /// Resolve the Open Grok state-directory URL from `environment`.
    ///
    /// `OPENGROK_HOME` wins; otherwise the user home directory (from `HOME`,
    /// then `USERPROFILE`, then the Foundation default) is joined with
    /// `.opengrok`. The result is never `.grok`.
    public static func resolve(environment: [String: String]) -> URL {
        if let override = environment["OPENGROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = userHomeDirectory(environment: environment)
        return home.appendingPathComponent(".opengrok")
    }

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

    /// The managed binary URL under a resolved `OPENGROK_HOME`.
    public static func managedBinaryURL(environment: [String: String]) -> URL {
        resolve(environment: environment).appendingPathComponent("bin/open-grok")
    }

    /// Returns `true` if `candidate` resolves to the forbidden legacy
    /// `~/.grok` path. Used by tests and guards to assert non-legacy behavior.
    public static func isLegacyGrokPath(_ candidate: URL, environment: [String: String]) -> Bool {
        let home = userHomeDirectory(environment: environment)
        let grok = home.appendingPathComponent(".grok").standardizedFileURL.path
        return candidate.standardizedFileURL.path == grok
    }
}
