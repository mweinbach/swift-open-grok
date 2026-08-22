// Session.swift
//
// Session protocol surface for the code-mode runtime. Ported from
// `crates/codegen/xai-grok-code-mode-protocol/src/session.rs`.
//
// The Rust crate is pure protocol: it defines the traits and the
// `StartedCell` oneshot wrapper, not an in-process JS runtime. The
// runtime crate (`OpenGrokCodeMode`) implements these protocols with
// actors.
//
// This file ports:
//   * `CodeModeError` — `String`-backed error mirroring every
//     `Result<T, String>` returned by the session APIs.
//   * `CellId` — transparent string newtype.
//   * `StartedCell` — cell id plus a **one-shot** initial-response
//     future (matches Rust `initial_response(self)` consuming the cell).
//   * `CodeModeCancellationToken` — Sendable per-cell cancellation
//     handle mirroring `tokio_util::sync::CancellationToken`.
//   * `CodeModeSessionDelegate` / `CodeModeSession` /
//     `CodeModeSessionProvider` — Sendable async protocols. Delegate
//     callbacks carry the per-cell cancellation token exactly as in
//     Rust (`invoke_tool` / `notify`).
//
// Runtime disposal is the `shutdown` method on `CodeModeSession`.

import Foundation
import OpenGrokShared

// MARK: - CodeModeError

/// A `String`-backed error mirroring the Rust `Result<_, String>` shape
/// used throughout the code-mode protocol.
public struct CodeModeError: Error, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }

    /// The canonical "the runtime ended before responding" error.
    public static let runtimeEnded = CodeModeError("exec runtime ended unexpectedly")

    /// Returned when `StartedCell.initialResponse()` is awaited more than
    /// once (Swift cannot move-consume the value the way Rust does).
    public static let initialResponseAlreadyConsumed = CodeModeError(
        "started cell initial response already consumed"
    )
}

// MARK: - CellId

/// Stable identifier for a running code-mode cell.
///
/// Wraps a `String` so callers can pick whatever id scheme they like
/// (UUIDs, slugs, ...). Serializes as a bare JSON string (matches the
/// Rust `#[serde(transparent)]` / newtype string form).
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
/// Carries the cell id plus an `async` initial-response future that the
/// caller awaits to receive the first `RuntimeResponse`. Matches Rust's
/// oneshot semantics: `initialResponse()` is **one-shot** — a second
/// await returns `CodeModeError.initialResponseAlreadyConsumed`.
public struct StartedCell: Sendable {
    public let cellId: CellId
    private let box: InitialResponseBox

    /// Internal one-shot box. Uses a lock rather than an actor so
    /// `initialResponse()` can take ownership without re-entrancy into
    /// the same actor that may be delivering the response.
    private final class InitialResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable () async -> Result<RuntimeResponse, CodeModeError>)?

        init(_ pending: @escaping @Sendable () async -> Result<RuntimeResponse, CodeModeError>) {
            self.pending = pending
        }

        func take() -> (@Sendable () async -> Result<RuntimeResponse, CodeModeError>)? {
            lock.lock()
            defer { lock.unlock() }
            let value = pending
            pending = nil
            return value
        }
    }

    public init(
        cellId: CellId,
        initialResponse: @Sendable @escaping () async -> Result<RuntimeResponse, CodeModeError>
    ) {
        self.cellId = cellId
        self.box = InitialResponseBox(initialResponse)
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

    /// Await the initial response. One-shot: consumes the underlying
    /// future. A second call returns
    /// `CodeModeError.initialResponseAlreadyConsumed` (deterministic
    /// duplicate rejection; matches Rust move semantics).
    public func initialResponse() async -> Result<RuntimeResponse, CodeModeError> {
        guard let pending = box.take() else {
            return .failure(.initialResponseAlreadyConsumed)
        }
        return await pending()
    }
}

// MARK: - CodeModeCancellationToken

/// Per-cell cooperative cancellation handle passed into host callbacks.
///
/// Mirrors Rust `tokio_util::sync::CancellationToken` as used by
/// `CodeModeSessionDelegate::invoke_tool` / `notify` in
/// `xai-grok-code-mode-protocol`:
///
/// * The session/runtime owns one token (or child token) per live cell.
/// * Nested `invokeTool` / `notify` work receives that token so host
///   work can observe termination **without** relying only on ambient
///   `Task.isCancelled`.
/// * `terminate(cellId)` and `shutdown()` cancel the cell's token
///   **exactly once**. After cancel, in-flight callbacks observe
///   `isCancelled == true` / return from `waitUntilCancelled()`.
/// * `childToken()` creates a linked child that cancels when the parent
///   cancels; cancelling a child does **not** cancel its parent.
/// * `cellClosed` is invoked after the cell reaches a terminal state and
///   callback cleanup has been signalled via this token. The token is
///   then terminal — further `cancel()` calls are no-ops.
public final class CodeModeCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var onCancelHandlers: [(@Sendable () -> Void)] = []
    private var children: [CodeModeCancellationToken] = []

    public init() {}

    /// Whether `cancel()` has been observed.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Create a child token that cancels when this token cancels.
    /// Cancelling the child does not cancel the parent.
    public func childToken() -> CodeModeCancellationToken {
        let child = CodeModeCancellationToken()
        lock.lock()
        if cancelled {
            lock.unlock()
            child.cancel()
            return child
        }
        children.append(child)
        lock.unlock()
        return child
    }

    /// Register a handler invoked exactly once when cancellation fires.
    /// If the token is already cancelled, the handler runs immediately.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        onCancelHandlers.append(handler)
        lock.unlock()
    }

    /// Signal cancellation. Idempotent; wakes every waiter, runs handlers,
    /// and cancels every child **exactly once**.
    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        let handlers = onCancelHandlers
        onCancelHandlers.removeAll()
        let kids = children
        children.removeAll()
        lock.unlock()
        for waiter in pending.values {
            waiter.resume()
        }
        for handler in handlers {
            handler()
        }
        for kid in kids {
            kid.cancel()
        }
    }

    /// Suspend until `cancel()` is called. Returns immediately if already
    /// cancelled. Also returns when the awaiting Swift `Task` is cancelled
    /// so host dispatch races do not hang.
    public func waitUntilCancelled() async {
        if isCancelled || Task.isCancelled { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                // Re-check under the lock so a cancel that races registration
                // cannot leave this continuation stranded.
                if cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: { [self] in
            lock.lock()
            let cont = waiters.removeValue(forKey: id)
            lock.unlock()
            cont?.resume()
        }
    }
}

// MARK: - CodeModeSessionDelegate

/// Host callbacks used by a code-mode session while cells are executing.
///
/// All methods are `Sendable`-constrained so the session can call them
/// from any actor.
///
/// ## Cancellation
///
/// Both `invokeTool` and `notify` receive an explicit
/// `CodeModeCancellationToken` for the cell that issued the callback
/// (mirrors Rust `CancellationToken`). Session implementations **must**
/// propagate the per-cell token into every nested invocation and
/// notification so host work can observe `terminate` / `shutdown`
/// without relying solely on ambient `Task.isCancelled`.
///
/// Lifetime:
/// * Token is live for the duration of the cell.
/// * `terminate` / natural completion / `shutdown` cancel it exactly once.
/// * After cancel, callbacks should exit promptly (return
///   `CodeModeError("cancelled")` or an equivalent terminal error).
/// * `cellClosed` fires after terminal delivery and token cancel.
public protocol CodeModeSessionDelegate: Sendable {
    /// Invoke a nested tool call from inside a code-mode cell.
    ///
    /// - Parameter cancellationToken: Per-cell cancellation handle. Cancelled
    ///   exactly once when the cell is terminated, completes, or the session
    ///   shuts down.
    /// - Parameter progress: Bounded, observation-only channel for chunks
    ///   produced before this invocation reaches its terminal result.
    func invokeTool(
        _ invocation: CodeModeNestedToolCall,
        cancellationToken: CodeModeCancellationToken,
        progress: NestedToolProgressSink
    ) async -> Result<JSONValue, CodeModeError>

    /// Inject an extra `custom_tool_call_output` for the current `exec`
    /// call.
    ///
    /// - Parameter cancellationToken: Same per-cell handle as `invokeTool`.
    func notify(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError>

    /// Release delegate state associated with a cell after it reaches a
    /// terminal state. Synchronous — the session calls this once per
    /// cell, after the cell's terminal `RuntimeResponse` has been
    /// delivered to the caller (and after the cell's cancellation token
    /// has been signalled).
    func cellClosed(_ cellId: CellId)
}

// MARK: - CodeModeSession

/// A durable code-mode session owned by one Codex thread.
///
/// Cells executed in the same session share stored values (the JS
/// isolate's `store`/`load` global helpers). Separate sessions must keep
/// those values isolated.
public protocol CodeModeSession: Sendable {
    /// Start a new cell. Returns a `StartedCell` whose
    /// `initialResponse()` future yields the first `RuntimeResponse`.
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
    /// resources. The session is unusable after this returns.
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
