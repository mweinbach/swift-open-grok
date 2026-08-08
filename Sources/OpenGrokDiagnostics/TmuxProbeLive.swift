// TmuxProbeLive.swift
//
// Live tmux option queries behind the `TmuxOptionQuery` seam.
//
// Ports `xai-grok-pager-render/src/terminal/tmux_probe.rs` (queries and
// parsing, tmux_probe.rs:175-292) and `diagnostics/probes/tmux.rs`
// (`LiveTmuxProbe`) at reference 650c1db7. Every query is a bounded
// subprocess (`TMUX_QUERY_TIMEOUT = 2s`, tmux_probe.rs:6); the standalone
// snapshot never calls this — tests inject fakes, and the library builds
// and tests without a live tmux.

import Foundation

/// `LiveTmuxProbe` (probes/tmux.rs:17-35).
public struct LiveTmuxProbe: TmuxOptionQuery {
    /// `TMUX_QUERY_TIMEOUT` (tmux_probe.rs:6).
    static let queryTimeout: TimeInterval = 2

    public init() {}

    /// `query_option` → `tmux show-option -gqv <option>` (tmux_probe.rs:245-248).
    public func showOption(_ option: String) -> TmuxProbeResult<String> {
        parseValue(run(["show-option", "-gqv", option]))
    }

    /// `query_option_support` → `tmux show-option -gv <option>`
    /// (tmux_probe.rs:195-204, 250-254).
    public func optionSupport(_ option: String) -> TmuxProbeResult<Bool> {
        switch run(["show-option", "-gv", option]) {
        case .exited(let status, _, _) where status == 0:
            return .available(true)
        case .exited(_, _, let stderr) where stderrIdentifiesUnknownOption(stderr, option: option):
            return .unsupported
        case .exited:
            return .unavailable
        case .timedOut:
            return .error("tmux query timed out after \(Self.queryTimeout)s")
        case .failedToStart(let detail):
            return .error(detail)
        }
    }

    /// `query_control_mode` → `tmux display-message -p '#{client_flags}'`
    /// (tmux_probe.rs:229-237, 255-259).
    public func controlMode() -> TmuxProbeResult<Bool> {
        switch run(["display-message", "-p", "#{client_flags}"]) {
        case .exited(let status, let stdout, _) where status == 0:
            return .available(String(decoding: stdout, as: UTF8.self).contains("control-mode"))
        case .exited:
            return .unavailable
        case .timedOut:
            return .error("tmux query timed out after \(Self.queryTimeout)s")
        case .failedToStart(let detail):
            return .error(detail)
        }
    }

    /// `query_client_features` → `tmux display-message -p
    /// '#{client_termfeatures}'` (tmux_probe.rs:217-223, 260-264).
    public func clientFeatures() -> TmuxProbeResult<String> {
        parseValue(run(["display-message", "-p", "#{client_termfeatures}"]))
    }

    private func run(_ arguments: [String]) -> BoundedProcessOutcome {
        runBoundedProcess(executable: "tmux", arguments: arguments, timeout: Self.queryTimeout)
    }

    /// `parse_value` (tmux_probe.rs:271-284).
    private func parseValue(_ outcome: BoundedProcessOutcome) -> TmuxProbeResult<String> {
        switch outcome {
        case .exited(let status, let stdout, _) where status == 0:
            let value = String(decoding: stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .unavailable : .available(value)
        case .exited:
            return .unavailable
        case .timedOut:
            return .error("tmux query timed out after \(Self.queryTimeout)s")
        case .failedToStart(let detail):
            return .error(detail)
        }
    }

    /// `stderr_identifies_unknown_option` (tmux_probe.rs:286-292).
    private func stderrIdentifiesUnknownOption(_ stderr: Data, option: String) -> Bool {
        let text = String(decoding: stderr, as: UTF8.self)
        return text.contains("invalid option: \(option)") || text.contains("unknown option: \(option)")
    }
}
