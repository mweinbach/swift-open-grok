// CodeModeSessionRuntime.swift
//
// Owns every cell and the shared stored-value map for one transport-neutral
// code-mode session. Ported from
// `crates/codegen/xai-grok-code-mode/src/session_runtime/mod.rs`
// (`SessionRuntime`, `RuntimeCellHost`).
//
// The Rust type keeps cells in a `Mutex<HashMap>` guarded by a
// `CancellationToken` and a `TaskTracker`; this port is an actor holding the
// same three things, with the tracker replaced by awaiting each cell's
// termination during `shutdown`.

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokJavaScriptRuntime
import OpenGrokShared

/// Host callbacks a session runtime forwards to. Mirrors
/// `SessionRuntimeDelegate` (session_runtime/types.rs:119).
protocol CodeModeSessionRuntimeDelegate: Sendable {
    func invokeTool(
        cellId: CellId,
        invocation: CodeModeCellToolCall,
        cancellationToken: CodeModeCancellationToken,
        progress: NestedToolProgressSink
    ) async -> Result<JSONValue, CodeModeError>

    func notify(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError>

    func cellClosed(_ cellId: CellId)
}

/// A cell admitted by `execute`. Mirrors `StartedCell`
/// (session_runtime/mod.rs:213).
struct CodeModeStartedCell: Sendable {
    let cellId: CellId
    private let cell: CodeModeCell

    init(cellId: CellId, cell: CodeModeCell) {
        self.cellId = cellId
        self.cell = cell
    }

    func initialEvent() async -> Result<CodeModeCellEvent, CodeModeRuntimeError> {
        await cell.initialEvent().mapError { CodeModeRuntimeError.from($0, cellId: cellId) }
    }
}

actor CodeModeSessionRuntime {
    private let delegate: CodeModeSessionRuntimeDelegate
    private let executionCeilingMs: UInt64
    private let shutdownToken = CodeModeCancellationToken()

    private var storedValues: [String: JSONValue] = [:]
    private var cells: [CellId: CodeModeCell] = [:]
    private var closureWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextCellId: UInt64 = 1
    private var shuttingDown = false

    init(
        delegate: CodeModeSessionRuntimeDelegate,
        executionCeilingMs: UInt64 = CODE_MODE_DEFAULT_EXECUTION_CEILING_MS
    ) {
        self.delegate = delegate
        self.executionCeilingMs = executionCeilingMs
    }

    // MARK: - Lifecycle

    /// Mirrors `SessionRuntime::execute` (session_runtime/mod.rs:76).
    func execute(
        _ request: ExecuteRequest,
        initialObserveMode: CodeModeObserveMode
    ) async -> Result<CodeModeStartedCell, CodeModeRuntimeError> {
        guard !shuttingDown else { return .failure(.shuttingDown) }
        guard nextCellId != UInt64.max else { return .failure(.cellIdSpaceExhausted) }
        let cellId = CellId(String(nextCellId))
        nextCellId += 1
        guard cells[cellId] == nil else { return .failure(.duplicateCell(cellId)) }

        let configuration = JavaScriptCellConfiguration(
            toolCallId: request.toolCallId,
            enabledTools: request.enabledTools.map(enabledToolMetadata),
            source: request.source,
            storedValues: storedValues,
            maxOutputTokens: request.maxOutputTokens,
            executionCeilingMs: executionCeilingMs
        )
        let started: (runtime: JavaScriptCellRuntime, events: AsyncStream<JavaScriptRuntimeEvent>)
        do {
            started = try JavaScriptCellRuntime.start(configuration: configuration)
        } catch let error as JavaScriptRuntimeError {
            return .failure(.runtime(error.message))
        } catch {
            return .failure(.runtime("\(error)"))
        }

        let cell = CodeModeCell(
            cellId: cellId,
            host: CellHostBridge(cellId: cellId, runtime: self),
            runtime: started.runtime,
            cancellationToken: shutdownToken.childToken(),
            initialObserveMode: initialObserveMode
        )
        cells[cellId] = cell
        await cell.start(events: started.events)
        return .success(CodeModeStartedCell(cellId: cellId, cell: cell))
    }

    /// Mirrors `SessionRuntime::observe` (session_runtime/mod.rs:94).
    func observe(
        cellId: CellId,
        mode: CodeModeObserveMode
    ) async -> Result<CodeModeCellEvent, CodeModeRuntimeError> {
        guard let cell = cells[cellId] else { return .failure(.missingCell(cellId)) }
        return await cell.observe(mode).mapError { CodeModeRuntimeError.from($0, cellId: cellId) }
    }

    /// Mirrors `SessionRuntime::terminate` (session_runtime/mod.rs:120).
    func terminate(cellId: CellId) async -> Result<CodeModeCellEvent, CodeModeRuntimeError> {
        guard let cell = cells[cellId] else { return .failure(.missingCell(cellId)) }
        return await cell.terminate().mapError { CodeModeRuntimeError.from($0, cellId: cellId) }
    }

    /// Mirrors `SessionRuntime::shutdown` (session_runtime/mod.rs:135):
    /// refuse new cells, cancel every live one, and wait for each to finish
    /// releasing its runtime before returning.
    func shutdown() async {
        shuttingDown = true
        shutdownToken.cancel()
        while !cells.isEmpty {
            await withCheckedContinuation { continuation in
                closureWaiters.append(continuation)
            }
        }
    }

    // MARK: - Cell host

    fileprivate func invokeTool(
        cellId: CellId,
        invocation: CodeModeCellToolCall,
        cancellationToken: CodeModeCancellationToken,
        progress: NestedToolProgressSink
    ) async -> Result<JSONValue, CodeModeError> {
        await delegate.invokeTool(
            cellId: cellId,
            invocation: invocation,
            cancellationToken: cancellationToken,
            progress: progress
        )
    }

    fileprivate func notify(
        cellId: CellId,
        callId: String,
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

    /// Mirrors `RuntimeCellHost::commit_completion` (session_runtime/mod.rs:273):
    /// a cell cancelled before its writes land does not publish them.
    fileprivate func commitStoredValues(
        _ writes: [String: JSONValue],
        cancellationToken: CodeModeCancellationToken
    ) -> Bool {
        guard !cancellationToken.isCancelled else { return false }
        storedValues.merge(writes) { _, new in new }
        return true
    }

    /// Mirrors `RuntimeCellHost::closed` (session_runtime/mod.rs:293).
    fileprivate func cellClosed(_ cellId: CellId) {
        cells[cellId] = nil
        delegate.cellClosed(cellId)
        if cells.isEmpty {
            let waiters = closureWaiters
            closureWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Test seam: the stored values shared by every cell in this session.
    func storedValuesSnapshot() -> [String: JSONValue] { storedValues }
}

/// Binds one cell to its session. Mirrors `RuntimeCellHost`
/// (session_runtime/mod.rs:235).
private struct CellHostBridge: CodeModeCellHost {
    let cellId: CellId
    let runtime: CodeModeSessionRuntime

    func invokeTool(
        _ invocation: CodeModeCellToolCall,
        cancellationToken: CodeModeCancellationToken,
        progress: NestedToolProgressSink
    ) async -> Result<JSONValue, CodeModeError> {
        await runtime.invokeTool(
            cellId: cellId,
            invocation: invocation,
            cancellationToken: cancellationToken,
            progress: progress
        )
    }

    func notify(
        callId: String,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        await runtime.notify(
            cellId: cellId,
            callId: callId,
            text: text,
            cancellationToken: cancellationToken
        )
    }

    func commitStoredValues(
        _ writes: [String: JSONValue],
        cancellationToken: CodeModeCancellationToken
    ) async -> Bool {
        await runtime.commitStoredValues(writes, cancellationToken: cancellationToken)
    }

    func cellClosed() async {
        await runtime.cellClosed(cellId)
    }
}
