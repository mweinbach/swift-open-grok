// RhaiRun.swift
//
// Port of crates/codegen/xai-workflow/src/run.rs — how a run ends.

import Foundation
import OpenGrokShared

/// run.rs:5 — why a run stopped short of completing. The wire spellings are
/// snake_case because they are persisted in run state and matched by the shell.
public enum RhaiPauseKind: String, Codable, Sendable, Hashable {
    case user
    case backOff = "back_off"
    case noProgress = "no_progress"
    case verification
    case infra

    /// run.rs:28 — `backoff` and `blocked` are accepted aliases a script may pass.
    public static func parse(_ text: String) -> RhaiPauseKind? {
        switch text {
        case "user": return .user
        case "back_off", "backoff": return .backOff
        case "no_progress": return .noProgress
        case "verification", "blocked": return .verification
        case "infra": return .infra
        default: return nil
        }
    }
}

/// run.rs:42 — the five terminal states of a run.
public enum RhaiWorkflowOutcome: Sendable, Hashable {
    case completed(result: JSONValue)
    case paused(kind: RhaiPauseKind, message: String)
    case budgetExceeded(message: String)
    case cancelled
    case failed(error: String)

    public var status: String {
        switch self {
        case .completed: return "completed"
        case .paused: return "paused"
        case .budgetExceeded: return "budget_exceeded"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    /// A paused or budget-exceeded run can be resumed from its journal; a
    /// failed one cannot, because the journal may not describe a consistent
    /// prefix of a run that would take the same path again.
    public var isResumable: Bool {
        switch self {
        case .paused, .budgetExceeded: return true
        default: return false
        }
    }

    public var json: JSONValue {
        switch self {
        case .completed(let result):
            return .object(["outcome": .string("completed"), "result": result])
        case .paused(let kind, let message):
            return .object([
                "outcome": .string("paused"),
                "kind": .string(kind.rawValue),
                "message": .string(message),
            ])
        case .budgetExceeded(let message):
            return .object(["outcome": .string("budget_exceeded"), "message": .string(message)])
        case .cancelled:
            return .object(["outcome": .string("cancelled")])
        case .failed(let error):
            return .object(["outcome": .string("failed"), "error": .string(error)])
        }
    }
}

/// A cooperative cancellation flag, standing in for the Rust
/// `tokio_util::sync::CancellationToken` the engine polls between operations.
public final class RhaiCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// lib.rs:19 — upstream appends an authoring hint to a handful of Rhai error
/// messages whose raw text is famously unhelpful. Ported so the same script
/// mistake produces the same guidance.
public func rhaiWithHint(_ message: String) -> String {
    let hint: String
    if message.contains("Expression exceeds maximum complexity") {
        hint = "a single expression nests too deep — usually one long chained `+` string "
            + "concatenation. Split it into multiple `+=` statements."
    } else if message.contains("reserved keyword") {
        hint = "Rhai reserves identifiers it doesn't use — `shared`, `sync`, `async`, `await`, "
            + "`spawn`, `go`, `thread`, `new`, `match`, `case`, `default`, `void`, `null`, "
            + "`nil`, `exit`, `static`, `var` — rename the variable (`shared` → `has_shared`)."
    } else if message.contains("getter is not registered for type 'char'") {
        hint = "indexing a string yields a `char`, so field access on it fails — you likely "
            + "indexed a string you expected to be an array (e.g. unparsed JSON in an agent "
            + "output). Check with `type_of(x)`; slice strings with `s.sub_string(start, len)`."
    } else {
        return message
    }
    return "\(message)\nhint: \(hint)"
}
