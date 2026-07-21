// EnvKnobs.swift
//
// Port of `xai-test-utils/src/env.rs`. The single `envUsize` knob parses a
// `usize` env variable with a fallback default, matching the Rust
// perf-repro convention for sizing `#[ignore]` benches (e.g.
// `GROK_PERF_GIT_FILES`).

import Foundation

/// Environment-variable test knobs.
public enum EnvKnobs {
    /// Parse a `usize`/`Int` env knob, falling back to `default` when unset or
    /// unparseable. Reads from `environment` (or `ProcessInfo.processInfo` when
    /// `environment` is nil) so tests are deterministic with respect to an
    /// injected environment.
    public static func envUsize(_ key: String, default: Int, environment: [String: String]? = nil) -> Int {
        let source: [String: String]
        if let environment {
            source = environment
        } else {
            source = ProcessInfo.processInfo.environment
        }
        guard let raw = source[key], let parsed = Int(raw) else {
            return `default`
        }
        return parsed
    }

    /// Parse a `String` env knob, falling back to `default` when unset.
    public static func envString(_ key: String, default: String, environment: [String: String]? = nil) -> String {
        let source: [String: String]
        if let environment {
            source = environment
        } else {
            source = ProcessInfo.processInfo.environment
        }
        return source[key] ?? `default`
    }

    /// Parse a `Bool` env knob: `1` / `true` / `TRUE` / `yes` → true;
    /// `0` / `false` / `FALSE` / `no` / unset → false.
    public static func envBool(_ key: String, default: Bool = false, environment: [String: String]? = nil) -> Bool {
        let source: [String: String]
        if let environment {
            source = environment
        } else {
            source = ProcessInfo.processInfo.environment
        }
        guard let raw = source[key]?.lowercased() else { return `default` }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off", "": return false
        default: return `default`
        }
    }
}
