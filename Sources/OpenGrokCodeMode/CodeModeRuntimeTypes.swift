// CodeModeRuntimeTypes.swift
//
// Transport-neutral cell vocabulary. Ported from
// `crates/codegen/xai-grok-code-mode/src/session_runtime/types.rs`
// (`ObserveMode`, `CellEvent`, `Error`) and
// `src/cell_actor/types.rs` (`CellError`).
//
// These types stay internal to the engine: the protocol layer's
// `RuntimeResponse` / `WaitOutcome` are what callers see, exactly as in the
// Rust crate where `session_runtime` is `pub(crate)` and `service.rs`
// performs the projection.

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared

/// Which frontier an observation waits for. Mirrors `ObserveMode`
/// (session_runtime/types.rs:30).
public enum CodeModeObserveMode: Sendable, Equatable {
    /// Hand back whatever the cell produced within this budget, in
    /// milliseconds (the unit `WaitRequest.yieldTimeMs` already uses).
    case yieldAfter(milliseconds: UInt64)
    /// Hand back as soon as the cell has no runnable work left.
    case pendingFrontier
}

/// An observable cell lifecycle event. Mirrors `CellEvent`
/// (session_runtime/types.rs:37).
public enum CodeModeCellEvent: Sendable, Equatable {
    case yielded(contentItems: [FunctionCallOutputContentItem])
    case pending(contentItems: [FunctionCallOutputContentItem], pendingToolCallIds: [String])
    case completed(contentItems: [FunctionCallOutputContentItem], errorText: String?)
    case terminated(contentItems: [FunctionCallOutputContentItem])

    public var contentItems: [FunctionCallOutputContentItem] {
        switch self {
        case .yielded(let items), .terminated(let items): return items
        case .pending(let items, _): return items
        case .completed(let items, _): return items
        }
    }
}

/// Why an observation could not be served. Mirrors `CellError`
/// (cell_actor/types.rs:22).
public enum CodeModeCellError: Error, Sendable, Equatable {
    case busy
    case alreadyTerminating
    case closed
}

/// A failure reported by a session-runtime operation. Mirrors
/// `session_runtime::Error` (session_runtime/types.rs:139), including its
/// `Display` strings, which the protocol layer surfaces verbatim.
public enum CodeModeRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case shuttingDown
    case cellIdSpaceExhausted
    case duplicateCell(CellId)
    case missingCell(CellId)
    case busyObserver(CellId)
    case alreadyTerminating(CellId)
    case closedCell(CellId)
    case runtime(String)

    public var description: String {
        switch self {
        case .shuttingDown:
            return "code mode session is shutting down"
        case .cellIdSpaceExhausted:
            return "code mode session exhausted its cell ID space"
        case .duplicateCell(let cellId):
            return "exec cell \(cellId) already exists"
        case .missingCell(let cellId):
            return "exec cell \(cellId) not found"
        case .busyObserver(let cellId):
            return "exec cell \(cellId) already has an active observer"
        case .alreadyTerminating(let cellId):
            return "exec cell \(cellId) is already terminating"
        case .closedCell(let cellId):
            return "exec cell \(cellId) closed unexpectedly"
        case .runtime(let errorText):
            return errorText
        }
    }

    /// True for the two errors the protocol layer folds into a
    /// `MissingCell` outcome rather than a hard failure (service.rs:183).
    public var isMissingCell: Bool {
        switch self {
        case .missingCell, .closedCell: return true
        default: return false
        }
    }

    static func from(_ error: CodeModeCellError, cellId: CellId) -> CodeModeRuntimeError {
        switch error {
        case .busy: return .busyObserver(cellId)
        case .alreadyTerminating: return .alreadyTerminating(cellId)
        case .closed: return .closedCell(cellId)
        }
    }
}

/// A nested tool request emitted by a running cell, before the session
/// stamps its cell id on. Mirrors `CellToolCall` (cell_actor/types.rs:28).
struct CodeModeCellToolCall: Sendable {
    var id: String
    var name: ToolName
    var kind: CodeModeToolKind
    var input: JSONValue?
}
