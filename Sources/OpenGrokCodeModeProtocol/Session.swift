// Session.swift
//
// Session protocol and lifecycle types for the code-mode runtime. Ported
// from `crates/codegen/xai-grok-code-mode-protocol/src/session.rs`.
//
// The Rust source uses `tokio::sync::oneshot` channels and boxed
// `Pin<Box<dyn Future + Send>>` trait objects to model the
// `StartedCell.initialResponse` future and the `CodeModeSession` /
// `CodeModeSessionDelegate` / `CodeModeSessionProvider` traits. The Swift
// port translates that to:
//   * `CellId` — a `String` newtype (Sendable, Codable, Hashable).
//   * `CodeModeError` — a `String`-backed `Error` mirroring the Rust
//     `Result<_, String>` shape. Used as the `Failure` of every
//     `Result<T, CodeModeError>` returned by the session APIs.
//   * `StartedCell` — a struct carrying the `cellId` plus an
//     `async` initial-response closure. The closure is `@Sendable` and
//     returns `Result<RuntimeResponse, CodeModeError>` (the error
//     mirrors the Rust `Result<_, String>` shape — the runtime reports
//     "exec runtime ended unexpectedly" when the underlying oneshot
//     sender is dropped).
//   * `CodeModeSessionDelegate` — a `Sendable` protocol with `async`
//     `invokeTool` / `notify` methods and a synchronous `cellClosed`
//     callback. Cancellation is expressed via Swift's
//     `Task.isCancelled` / `Task.checkCancellation()` rather than a
//     `CancellationToken` parameter — the runtime crate wraps the
//     delegate's body in a `Task` and cancels it when the cell is
//     terminated or the session shuts down.
//   * `CodeModeSession` — a `Sendable` protocol with `async` `execute`,
//     `wait`, `terminate`, and `shutdown` methods. Each returns
//     `Result<T, CodeModeError>` to mirror the Rust `Result<_, String>`
//     shape; the runtime crate typically wraps these in its own typed
//     errors at the boundary.
//   * `CodeModeSessionProvider` — a `Sendable` protocol that creates a
//     `CodeModeSession` for a given delegate. Implementations may share a
//     remote host process across all sessions created by one provider.
//
// Runtime disposal (the "runtime disposal" criterion in the W1-S4
// acceptance) is the `shutdown` method on `CodeModeSession`: it
// terminates every still-running cell, closes the delegate's per-cell
// state via `CodeModeSessionDelegate.cellClosed`, and frees any
// resources the session holds (JS isolate, pending tool-call slots,
// notify queue). The session is unusable after `shutdown` returns.

import Foundation
import OpenGrokShared

// MARK: - CodeModeError

/// A `String`-backed error mirroring the Rust `Result<_, String>` shape
/// used throughout the code-mode protocol.
///
/// The Rust source surfaces human-readable error strings (e.g. "exec
/// runtime ended unexpectedly") as the `Failure` of every
/// `Result<T, String>` returned by the session APIs. `CodeModeError`
/// preserves that shape in Swift: `CodeModeError.message` carries the
/// original string, and `CodeModeError` conforms to `Error` so it can
/// be thrown from `async` functions or used as the `Failure` of a
/// `Result<T, CodeModeError>`.
public struct CodeModeError: Error, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }

    /// The canonical "the runtime ended before responding" error.
    public static let runtimeEnded = CodeModeError("exec runtime ended unexpectedly")
}

// MARK: - CellId

/// Stable identifier for a running code-mode cell.
///
/// Wraps a `String` so callers can pick whatever id scheme they like
/// (UUIDs, slugs, ...). Serializes as a bare JSON string (matches the
/// Rust `#[serde(transparent)]`).
public struct CellId: Hashable, Sendable, Codable, Equatable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        rawValue = try c.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - StartedCell

/// A cell that has been started by `CodeModeSession.execute`.
///
/// Carries the cell id plus an `async` initial-response closure that the
/// caller awaits to receive the first `RuntimeResponse` (typically a
/// `.yielded` with the cell's first output, or a `.result` if the script
/// finished synchronously).
///
/// The closure is `@Sendable` so it can be awaited from any actor. The
/// `Result<RuntimeResponse, CodeModeError>` shape mirrors the Rust
/// `Result<RuntimeResponse, String>` produced by the underlying
/// `oneshot::Receiver` — the error is `CodeModeError.runtimeEnded` when
/// the runtime drops the sender before responding.
public struct StartedCell: Sendable {
    public let cellId: CellId
    private let initialResponseClosure: @Sendable () async -> Result<RuntimeResponse, CodeModeError>

    public init(
        cellId: CellId,
        initialResponse: @Sendable @escaping () async -> Result<RuntimeResponse, CodeModeError>
    ) {
        self.cellId = cellId
        self.initialResponseClosure = initialResponse
    }

    /// Construct from a continuation that already produces a
    /// `Result<RuntimeResponse, CodeModeError>`. Mirrors Rust's
    /// `StartedCell::from_result_receiver`.
    public static func fromResultContinuation(
        cellId: CellId,
        continuation: @Sendable @escaping () async -> Result<RuntimeResponse, CodeModeError>
    ) -> StartedCell {
        StartedCell(cellId: cellId, initialResponse: continuation)
    }

    /// Construct from a continuation that produces a `RuntimeResponse`
    /// directly (success path). Mirrors Rust's `StartedCell::new` with a
    /// plain `oneshot::Receiver<RuntimeResponse>`.
    public static func fromResponseContinuation(
        cellId: CellId,
        continuation: @Sendable @escaping () async -> RuntimeResponse?
    ) -> StartedCell {
        StartedCell(cellId: cellId) {
            if let response = await continuation() {
                return .success(response)
            }
            return .failure(CodeModeError.runtimeEnded)
        }
    }

    /// Await the initial response. Consumes the cell's initial-response
    /// future (matches the `pub async fn initial_response(self)` Rust
    /// signature — the cell is no longer usable for the initial-response
    /// path after this returns).
    public func initialResponse() async -> Result<RuntimeResponse, CodeModeError> {
        await initialResponseClosure()
    }
}

// MARK: - CodeModeSessionDelegate

/// Host callbacks used by a code-mode session while cells are executing.
///
/// The runtime crate implements this protocol to surface nested tool
/// calls (issued from inside the JS isolate) and `notify(...)` messages
/// back to the host. The session calls `cellClosed` once per cell after
/// it reaches a terminal state so the delegate can release any per-cell
/// state (notify queues, pending tool-call maps, ...).
///
/// All methods are `Sendable`-constrained so the session can call them
/// from any actor. Cancellation is expressed via Swift's
/// `Task.isCancelled` / `Task.checkCancellation()` rather than a
/// `CancellationToken` parameter — the runtime crate wraps each
/// `invokeTool` / `notify` body in a `Task` and cancels it when the cell
/// is terminated or the session shuts down, completing the
/// continuation exactly once.
public protocol CodeModeSessionDelegate: Sendable {
    /// Invoke a nested tool call from inside a code-mode cell.
    ///
    /// Returns the tool result as a `JSONValue` (mirrors Rust's
    /// `serde_json::Value`), or an error when the tool fails or the call
    /// is cancelled.
    func invokeTool(
        _ invocation: CodeModeNestedToolCall
    ) async -> Result<JSONValue, CodeModeError>

    /// Inject an extra `custom_tool_call_output` for the current `exec`
    /// call. Returns the empty result on success, or an error when the
    /// runtime is unable to accept the notification (cell already
    /// closed, session shutting down, ...).
    func notify(
        callId: String,
        cellId: CellId,
        text: String
    ) async -> Result<Void, CodeModeError>

    /// Release delegate state associated with a cell after it reaches a
    /// terminal state. Synchronous — the session calls this once per
    /// cell, after the cell's terminal `RuntimeResponse` has been
    /// delivered to the caller.
    func cellClosed(_ cellId: CellId)
}

// MARK: - CodeModeSession

/// A durable code-mode session owned by one Codex thread.
///
/// Cells executed in the same session share stored values (the JS
/// isolate's `store`/`load` global helpers). Separate sessions must keep
/// those values isolated. Implementations may execute cells in-process
/// or remotely.
///
/// All methods are `Sendable`-constrained and return
/// `Result<T, CodeModeError>` to mirror the Rust `Result<_, String>`
/// shape.
public protocol CodeModeSession: Sendable {
    /// Start a new cell. Returns a `StartedCell` whose
    /// `initialResponse()` closure yields the first `RuntimeResponse`.
    func execute(_ request: ExecuteRequest) async -> Result<StartedCell, CodeModeError>

    /// Resume (or check on) a running cell. Returns a `WaitOutcome` that
    /// distinguishes a live cell from a missing cell.
    func wait(_ request: WaitRequest) async -> Result<WaitOutcome, CodeModeError>

    /// Terminate a running cell. Returns the cell's terminal
    /// `RuntimeResponse` (`.terminated` with the output produced so
    /// far).
    func terminate(_ cellId: CellId) async -> Result<WaitOutcome, CodeModeError>

    /// Shut the session down. Terminates every still-running cell,
    /// releases all per-cell state, and frees the underlying runtime
    /// resources (JS isolate, pending tool-call slots, notify queue).
    /// The session is unusable after this returns.
    func shutdown() async -> Result<Void, CodeModeError>
}

// MARK: - CodeModeSessionProvider

/// Creates code-mode sessions for Codex threads.
///
/// Implementations may share a remote host process across all sessions
/// created by one provider. The delegate is owned by the session for
/// the lifetime of the cells it runs.
public protocol CodeModeSessionProvider: Sendable {
    func createSession(
        delegate: CodeModeSessionDelegate
    ) async -> Result<CodeModeSession, CodeModeError>
}
