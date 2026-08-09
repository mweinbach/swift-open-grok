// Interval.swift
//
// Open Grok — Swift port of
// `xai-grok-tools/src/implementations/grok_build/scheduler/interval.rs` and the
// pure error cases of `scheduler/types.rs` (`SchedulerError`).
//
// Grok schedules are INTERVALS, not cron: a task fires every N seconds, where
// N comes from a compact `<number><unit>` string. The 60-second floor is a
// clamp, not an error — upstream raises short intervals silently and the /loop
// instruction tells the model to disclose when that happened.

import Foundation

/// Scheduler errors, ported from `scheduler/types.rs:158-186`.
///
/// `persistence` and `removalPending` are the durable-barrier cases the
/// runtime host raises (`SchedulerError::Persistence` / `RemovalPending`,
/// `types.rs:169-170,178-179`). Still deliberately unported:
/// `Notification`, `NoDurableNotificationConsumer`, `Cancelled`, and
/// `Timeout` — they describe the acknowledged-notification consumer and the
/// background persistence writer's timeout/cancel arms, and this port has
/// neither surface (the state write is a direct call, so its outcome is
/// never "unknown").
public enum SchedulerError: Error, Equatable, Sendable {
    case invalidInterval(String)
    case taskLimitReached(Int)
    case taskNotFound(String)
    case persistence(String)
    case removalPending(String)
}

extension SchedulerError: CustomStringConvertible {
    /// Byte parity with upstream's `thiserror` display strings
    /// (`types.rs:160-167`). The tool layer surfaces these verbatim via
    /// `scheduler_tool_error` (`types.rs:188-201`), so rewording here would
    /// change what the model reads back from a failed scheduler call.
    public var description: String {
        switch self {
        case .invalidInterval(let detail):
            return "invalid interval: \(detail)"
        case .taskLimitReached(let limit):
            return "maximum of \(limit) scheduled tasks reached"
        case .taskNotFound(let id):
            return "no scheduled task with id \(id); call scheduler_list to see active task ids"
        case .persistence(let detail):
            return "failed to persist scheduler resources: \(detail)"
        case .removalPending(let id):
            return "scheduler removal for \(id) is pending"
        }
    }
}

extension SchedulerError: LocalizedError {
    public var errorDescription: String? { description }
}

/// `interval.rs:3`.
private let minimumIntervalSecs: UInt64 = 60

/// Parse an interval string like "5m", "2h", "30s", "1d" into seconds.
/// Minimum interval is 60 seconds; values below are clamped.
///
/// Port of `parse_interval` (`interval.rs:7-45`), including the error message
/// wording and the check order: trim → empty → digits parse → zero → suffix →
/// overflow → clamp. Errors are thrown as `SchedulerError.invalidInterval`
/// so the runtime slice can map them to `invalid_arguments` with upstream's
/// exact text (`create.rs:171-176`).
public func parseInterval(_ input: String) throws -> UInt64 {
    let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty {
        throw SchedulerError.invalidInterval("interval cannot be empty")
    }

    // Upstream splits at the last BYTE (`interval.rs:15`) and would panic on a
    // multi-byte final character; splitting on the last Character instead
    // reports the suffix error for such input. Recorded divergence: error
    // instead of trap, strictly safer for the same accepted grammar.
    let suffix = String(s.last!)
    let digits = String(s.dropLast())

    guard let value = UInt64(digits) else {
        throw SchedulerError.invalidInterval(
            "invalid interval format: \(rustDebugQuoted(s)) (expected e.g. 5m, 2h, 1d)"
        )
    }

    if value == 0 {
        throw SchedulerError.invalidInterval("interval value must be greater than 0")
    }

    let unitSecs: UInt64
    switch suffix {
    case "s": unitSecs = 1
    case "m": unitSecs = 60
    case "h": unitSecs = 3600
    case "d": unitSecs = 86400
    default:
        throw SchedulerError.invalidInterval(
            "invalid interval suffix: \(rustDebugQuoted(suffix)) (expected s, m, h, or d)"
        )
    }

    let (secs, overflow) = value.multipliedReportingOverflow(by: unitSecs)
    if overflow {
        throw SchedulerError.invalidInterval("interval too large: \(rustDebugQuoted(s))")
    }

    return max(secs, minimumIntervalSecs)
}

/// Convert seconds to a human-readable interval string.
/// e.g. 300 -> "every 5 minutes", 3600 -> "every 1 hour"
///
/// Port of `interval_to_human` (`interval.rs:49-76`). The exact strings are
/// goldens: `/tasks` rows and `scheduler_create` output echo them, so
/// singular/plural and unit words must not drift.
public func intervalToHuman(_ secs: UInt64) -> String {
    if secs % 86400 == 0 {
        let n = secs / 86400
        return n == 1 ? "every 1 day" : "every \(n) days"
    } else if secs % 3600 == 0 {
        let n = secs / 3600
        return n == 1 ? "every 1 hour" : "every \(n) hours"
    } else if secs % 60 == 0 {
        let n = secs / 60
        return n == 1 ? "every 1 minute" : "every \(n) minutes"
    } else if secs == 1 {
        return "every 1 second"
    } else {
        return "every \(secs) seconds"
    }
}

/// Approximate Rust's `{:?}` string formatting used in upstream's interval
/// error messages: double quotes around the value with `\` and `"` escaped
/// and common control characters rendered as escapes. Exotic characters that
/// Rust would render as `\u{..}` pass through unescaped; interval strings are
/// short user-typed tokens, so that corner does not arise in practice.
private func rustDebugQuoted(_ s: String) -> String {
    var out = "\""
    for ch in s {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(ch)
        }
    }
    out += "\""
    return out
}
