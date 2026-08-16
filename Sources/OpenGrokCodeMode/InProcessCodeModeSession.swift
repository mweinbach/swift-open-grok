// InProcessCodeModeSession.swift
//
// The protocol-facing session. Ported from
// `crates/codegen/xai-grok-code-mode/src/service.rs`
// (`InProcessCodeModeSession`, `InProcessCodeModeSessionProvider`,
// `NoopCodeModeSessionDelegate`, and the `CellEvent → RuntimeResponse`
// projection).
//
// Open Grok, like the Rust crate, carries only the in-process runtime;
// Codex's optional remote host-process transport is not ported.

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokJavaScriptRuntime
import OpenGrokShared

public typealias CodeModeRuntimeCapability = JavaScriptRuntimeCapability

/// Grace added to an observation window of at least ten seconds so a nested
/// tool that lands just after the advertised deadline still returns without
/// another model turn. Mirrors `YIELD_GRACE_PERIOD` / `MIN_YIELD_TIME_FOR_GRACE`
/// (service.rs:33) and the behavior recorded in docs/code-mode-port.md.
let CODE_MODE_YIELD_GRACE_PERIOD_MS: UInt64 = 1_000
let CODE_MODE_MIN_YIELD_TIME_FOR_GRACE_MS: UInt64 = 10_000

/// Mirrors `yield_timeout` (service.rs:36).
func codeModeYieldTimeout(yieldTimeMs: UInt64) -> UInt64 {
    guard yieldTimeMs >= CODE_MODE_MIN_YIELD_TIME_FOR_GRACE_MS else { return yieldTimeMs }
    return yieldTimeMs.addingReportingOverflow(CODE_MODE_YIELD_GRACE_PERIOD_MS).partialValue
}

/// A delegate that refuses every nested tool call, used when Code Mode runs
/// without a host dispatcher. Mirrors `NoopCodeModeSessionDelegate`
/// (service.rs:45): the refusal waits for cancellation first, so a cell that
/// calls a tool parks instead of erroring immediately.
public struct NoopCodeModeSessionDelegate: CodeModeSessionDelegate {
    public init() {}

    public func invokeTool(
        _ invocation: CodeModeNestedToolCall,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<JSONValue, CodeModeError> {
        await cancellationToken.waitUntilCancelled()
        return .failure(CodeModeError("code mode nested tools are unavailable"))
    }

    public func notify(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        .success(())
    }

    public func cellClosed(_ cellId: CellId) {}
}

/// Creates in-process code-mode sessions. Mirrors
/// `InProcessCodeModeSessionProvider` (service.rs:73).
public struct InProcessCodeModeSessionProvider: CodeModeSessionProvider {
    public init() {}

    public func createSession(
        delegate: CodeModeSessionDelegate
    ) async -> Result<CodeModeSession, CodeModeError> {
        .success(InProcessCodeModeSession(delegate: delegate))
    }
}

/// One durable code-mode session: cells share stored values, nested tool
/// calls re-enter the host through the delegate, and `shutdown` disposes
/// every runtime. Mirrors `InProcessCodeModeSession` (service.rs:88).
public final class InProcessCodeModeSession: CodeModeSession {
    /// The engine capability used by live composition before it advertises
    /// `exec` and `wait`.
    public static var runtimeCapability: CodeModeRuntimeCapability {
        .current
    }

    private let runtime: CodeModeSessionRuntime

    /// - Parameter executionCeilingMs: fallback ceiling used when the runtime
    ///   cannot launch the isolated `open-grok` worker (primarily tests).
    ///   Production cells run in that worker and terminate by process kill.
    public init(
        delegate: CodeModeSessionDelegate = NoopCodeModeSessionDelegate(),
        executionCeilingMs: UInt64 = CODE_MODE_DEFAULT_EXECUTION_CEILING_MS
    ) {
        runtime = CodeModeSessionRuntime(
            delegate: ProtocolDelegateBridge(delegate: delegate),
            executionCeilingMs: executionCeilingMs
        )
    }

    // MARK: - CodeModeSession

    public func execute(_ request: ExecuteRequest) async -> Result<StartedCell, CodeModeError> {
        let yieldTimeMs = request.yieldTimeMs ?? DEFAULT_EXEC_YIELD_TIME_MS
        let started = await runtime.execute(
            request,
            initialObserveMode: .yieldAfter(milliseconds: codeModeYieldTimeout(yieldTimeMs: yieldTimeMs))
        )
        switch started {
        case .failure(let error):
            return .failure(CodeModeError(error.description))
        case .success(let cell):
            let cellId = cell.cellId
            return .success(
                StartedCell.fromResultContinuation(cellId: cellId) {
                    switch await cell.initialEvent() {
                    case .failure(let error):
                        return .failure(CodeModeError(error.description))
                    case .success(let event):
                        return runtimeResponse(cellId: cellId, event: event)
                    }
                }
            )
        }
    }

    public func wait(_ request: WaitRequest) async -> Result<WaitOutcome, CodeModeError> {
        let cellId = request.cellId
        let observed = await runtime.observe(
            cellId: cellId,
            mode: .yieldAfter(milliseconds: codeModeYieldTimeout(yieldTimeMs: request.yieldTimeMs))
        )
        switch observed {
        case .success(let event):
            return runtimeResponse(cellId: cellId, event: event).map { .liveCell($0) }
        case .failure(let error) where error.isMissingCell:
            return .success(.missingCell(missingCellResponse(cellId: cellId)))
        case .failure(let error):
            return .failure(CodeModeError(error.description))
        }
    }

    public func terminate(_ cellId: CellId) async -> Result<WaitOutcome, CodeModeError> {
        switch await runtime.terminate(cellId: cellId) {
        case .success(let event):
            return runtimeResponse(cellId: cellId, event: event).map { .liveCell($0) }
        case .failure(let error) where error.isMissingCell:
            return .success(.missingCell(missingCellResponse(cellId: cellId)))
        case .failure(let error):
            return .failure(CodeModeError(error.description))
        }
    }

    public func shutdown() async -> Result<Void, CodeModeError> {
        await runtime.shutdown()
        return .success(())
    }

    // MARK: - Pending-frontier surface

    /// Chained `exec` → `wait` entry point. Mirrors
    /// `InProcessCodeModeSession::execute_to_pending` (service.rs:139).
    public func executeToPending(
        _ request: ExecuteRequest
    ) async -> Result<ExecuteToPendingOutcome, CodeModeError> {
        let started = await runtime.execute(request, initialObserveMode: .pendingFrontier)
        switch started {
        case .failure(let error):
            return .failure(CodeModeError(error.description))
        case .success(let cell):
            switch await cell.initialEvent() {
            case .failure(let error):
                return .failure(CodeModeError(error.description))
            case .success(let event):
                return pendingOutcome(cellId: cell.cellId, event: event)
            }
        }
    }

    /// Mirrors `InProcessCodeModeSession::wait_to_pending` (service.rs:206).
    public func waitToPending(
        _ request: WaitToPendingRequest
    ) async -> Result<WaitToPendingOutcome, CodeModeError> {
        let cellId = request.cellId
        switch await runtime.observe(cellId: cellId, mode: .pendingFrontier) {
        case .success(let event):
            return pendingOutcome(cellId: cellId, event: event).map { .liveCell($0) }
        case .failure(let error) where error.isMissingCell:
            return .success(.missingCell(missingCellResponse(cellId: cellId)))
        case .failure(let error):
            return .failure(CodeModeError(error.description))
        }
    }

    /// Test seam: the values `store()` has published for this session.
    public func storedValues() async -> [String: JSONValue] {
        await runtime.storedValuesSnapshot()
    }
}

// MARK: - Projection (service.rs:347)

/// Mirrors `runtime_response` (service.rs:366).
func runtimeResponse(
    cellId: CellId,
    event: CodeModeCellEvent
) -> Result<RuntimeResponse, CodeModeError> {
    switch event {
    case .yielded(let contentItems):
        return .success(.yielded(cellId: cellId, contentItems: contentItems))
    case .completed(let contentItems, let errorText):
        return .success(
            .result(cellId: cellId, contentItems: contentItems, errorText: errorText)
        )
    case .terminated(let contentItems):
        return .success(.terminated(cellId: cellId, contentItems: contentItems))
    case .pending:
        return .failure(CodeModeError("cell returned a pending frontier unexpectedly"))
    }
}

/// Mirrors `pending_outcome` (service.rs:347).
func pendingOutcome(
    cellId: CellId,
    event: CodeModeCellEvent
) -> Result<ExecuteToPendingOutcome, CodeModeError> {
    switch event {
    case .pending(let contentItems, let pendingToolCallIds):
        return .success(
            .pending(
                cellId: cellId,
                contentItems: contentItems,
                pendingToolCallIds: pendingToolCallIds
            )
        )
    default:
        return runtimeResponse(cellId: cellId, event: event).map { .completed($0) }
    }
}

/// Mirrors `missing_cell_response` (service.rs:410) — the stale-cell
/// outcome a `wait` on a disposed cell id receives.
func missingCellResponse(cellId: CellId) -> RuntimeResponse {
    .result(
        cellId: cellId,
        contentItems: [],
        errorText: "exec cell \(cellId) not found"
    )
}

// MARK: - Delegate bridge (service.rs:264)

private struct ProtocolDelegateBridge: CodeModeSessionRuntimeDelegate {
    let delegate: CodeModeSessionDelegate

    func invokeTool(
        cellId: CellId,
        invocation: CodeModeCellToolCall,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<JSONValue, CodeModeError> {
        await delegate.invokeTool(
            CodeModeNestedToolCall(
                cellId: cellId,
                runtimeToolCallId: invocation.id,
                toolName: invocation.name,
                toolKind: invocation.kind,
                input: invocation.input
            ),
            cancellationToken: cancellationToken
        )
    }

    func notify(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        await delegate.notify(
            callId: callId,
            cellId: cellId,
            text: text,
            cancellationToken: cancellationToken
        )
    }

    func cellClosed(_ cellId: CellId) {
        delegate.cellClosed(cellId)
    }
}
