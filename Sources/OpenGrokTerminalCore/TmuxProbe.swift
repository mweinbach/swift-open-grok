// TmuxProbe.swift
//
// Pure tmux environment detection and query/result parsing from pin
// `xai-grok-pager-render/src/terminal/tmux_probe.rs` and the env/version
// helpers in `terminal/mod.rs`. No subprocess, no live PTY: callers inject
// env maps and already-captured stdout/stderr.
//
// HEAD-only `terminal/tmux.rs` (DCS passthrough wrapping) is not in the pin
// and is not ported here.

import Foundation

// MARK: - Query result (tmux_probe.rs:158-173)

/// `TmuxQueryResult<T>` — fail-open facts, not a thrown error.
public enum TmuxQueryResult<T: Equatable & Sendable>: Equatable, Sendable {
    case available(T)
    case unsupported
    case unavailable
    case error(String)

    /// `into_option` (tmux_probe.rs:166-172).
    public func intoOption() -> T? {
        if case .available(let value) = self { return value }
        return nil
    }
}

// MARK: - Command protocol (tmux_probe.rs:16-23, 239-267)

/// `TmuxCommand` argv only. The pin's `LiveTmuxCommandRunner` is not ported
/// (it owns a process group and a 2s deadline).
public enum TmuxQueryCommand: Equatable, Sendable {
    case version
    case optionValue(String)
    case optionSupport(String)
    case controlMode
    case clientFeatures

    /// Program name (`Command::new("tmux")`).
    public static let program = "tmux"

    /// Exact argv the pin builds (`build_tmux_command`).
    public var arguments: [String] {
        switch self {
        case .version:
            return ["-V"]
        case .optionValue(let option):
            return ["show-option", "-gqv", option]
        case .optionSupport(let option):
            return ["show-option", "-gv", option]
        case .controlMode:
            return ["display-message", "-p", "#{client_flags}"]
        case .clientFeatures:
            return ["display-message", "-p", "#{client_termfeatures}"]
        }
    }
}

// MARK: - Env detection (mod.rs:947-952, env_get:677-679)

/// Presence of tmux as the immediate multiplexer, from env only.
///
/// `isPresent` is the `TMUX` marker `env_get` accepts (non-empty). Empty
/// `TMUX=""` is not tmux — same filter as `detect_multiplexer_from_env`.
public struct TmuxProbe: Sendable, Equatable {
    public var isPresent: Bool
    public var tmuxEnv: String?
    public var tmuxPane: String?

    public init(isPresent: Bool, tmuxEnv: String? = nil, tmuxPane: String? = nil) {
        self.isPresent = isPresent
        self.tmuxEnv = tmuxEnv
        self.tmuxPane = tmuxPane
    }

    /// `detect_tmux_meta_from_env` plus the `TMUX` presence predicate.
    public static func detect(env: [String: String]) -> TmuxProbe {
        let tmuxEnv = envGet(env, "TMUX")
        return TmuxProbe(
            isPresent: tmuxEnv != nil,
            tmuxEnv: tmuxEnv,
            tmuxPane: envGet(env, "TMUX_PANE")
        )
    }

    // MARK: Parse (tmux_probe.rs:271-292, 229-237)

    /// `parse_value`. `error` is the runner `Err(String)` arm.
    public static func parseValue(
        statusSuccess: Bool,
        stdout: String,
        error: String? = nil
    ) -> TmuxQueryResult<String> {
        if let error {
            return .error(error)
        }
        guard statusSuccess else { return .unavailable }
        let value = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .unavailable : .available(value)
    }

    /// `query_option_support` classification of a captured run.
    ///
    /// Pin uses `TmuxQueryResult<()>` (tmux_probe.rs:195-204). Swift `Void`
    /// is not `Equatable`, so success is `available(true)` — the same
    /// payload-free encoding Diagnostics already uses.
    public static func parseOptionSupport(
        statusSuccess: Bool,
        stderr: String,
        option: String,
        error: String? = nil
    ) -> TmuxQueryResult<Bool> {
        if let error {
            return .error(error)
        }
        if statusSuccess { return .available(true) }
        if stderrIdentifiesUnknownOption(stderr, option: option) {
            return .unsupported
        }
        return .unavailable
    }

    /// `query_control_mode` classification. Success reports whether
    /// `control-mode` appears in the raw stdout (not trimmed).
    public static func parseControlMode(
        statusSuccess: Bool,
        stdout: String,
        error: String? = nil
    ) -> TmuxQueryResult<Bool> {
        if let error {
            return .error(error)
        }
        guard statusSuccess else { return .unavailable }
        return .available(stdout.contains("control-mode"))
    }

    /// `stderr_identifies_unknown_option` (tmux_probe.rs:286-292).
    ///
    /// Exact trimmed line match, not a substring search. Split on
    /// `Character.isNewline` so a CRLF line is one line.
    public static func stderrIdentifiesUnknownOption(_ stderr: String, option: String) -> Bool {
        let invalid = "invalid option: \(option)"
        let unknown = "unknown option: \(option)"
        return stderr.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == invalid || trimmed == unknown
        }
    }

    // MARK: Version compare (mod.rs:528-538, 1077-1087)

    /// `parse_tmux_major_minor` — `"tmux 3.4"` / `"tmux 3.3a"`.
    public static func parseMajorMinor(_ version: String) -> (UInt32, UInt32)? {
        guard version.hasPrefix("tmux ") else { return nil }
        let rest = version.dropFirst("tmux ".count)
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = UInt32(parts[0]) else { return nil }
        let digits = parts[1].prefix { $0.isASCII && $0.isNumber }
        guard let minor = UInt32(digits) else { return nil }
        return (major, minor)
    }

    /// `is_tmux_version_or_later`. Unknown / unparseable is conservative-old
    /// (`false`), never coerced to 0.0.
    public static func isVersion(_ version: String?, orLater major: UInt32, _ minor: UInt32) -> Bool {
        guard let version, let parsed = parseMajorMinor(version) else { return false }
        return parsed >= (major, minor)
    }
}

/// `env_get` (terminal/mod.rs:677-679): missing and empty are both absent.
private func envGet(_ env: [String: String], _ key: String) -> String? {
    guard let value = env[key], !value.isEmpty else { return nil }
    return value
}
