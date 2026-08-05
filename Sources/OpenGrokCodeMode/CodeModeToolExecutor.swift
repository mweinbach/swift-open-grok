// CodeModeToolExecutor.swift
//
// The seam between a code-mode session and the host's ordinary tool
// dispatch pipeline.
//
// Nested calls are *not* dispatched here. The Rust engine calls back into
// the shell through `CodeModeSessionDelegate::invoke_tool`
// (xai-grok-code-mode-protocol/src/session.rs, wired in service.rs:264), and
// the shell re-enters its normal dispatcher — permission gate, telemetry,
// structured results and all. This file defines the Swift shape of that
// callback so the live composition can supply one object instead of
// implementing the whole delegate protocol:
//
//   * `CodeModeToolRegistrySnapshot` — the tool set a session was built
//     with, used to generate the `tools.*` namespace and to fail closed on
//     a name that is not in it.
//   * `CodeModeToolExecutor` — "run this nested call and give me its
//     structured result", honoring the supplied cancellation token.
//   * `CodeModeExecutorDelegate` — adapts the two into a
//     `CodeModeSessionDelegate` an `InProcessCodeModeSession` accepts.

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokJavaScriptRuntime
import OpenGrokShared

/// The tools a code-mode session may expose, captured when the session is
/// created. Cells built from one snapshot always see the same namespace,
/// which is what makes a nested call's name resolvable after a `wait`.
public struct CodeModeToolRegistrySnapshot: Sendable, Equatable {
    public let tools: [ToolDefinition]

    public init(tools: [ToolDefinition]) {
        self.tools = tools
    }

    /// Definitions in the form `ExecuteRequest.enabledTools` expects: the
    /// typed JS declaration is appended to each description, matching
    /// `augment_tool_definition` in the protocol crate.
    public var executeRequestTools: [ToolDefinition] {
        tools.map(augmentToolDefinition)
    }

    /// The generated global identifier for each tool, in namespace order.
    public var globalNames: [String] {
        tools.map { enabledToolMetadata($0).globalName }
    }

    public func definition(for toolName: ToolName) -> ToolDefinition? {
        tools.first { $0.toolName == toolName }
    }
}

/// Runs one nested tool call by re-entering the host's dispatch pipeline.
///
/// Implementations must honor `cancellationToken`: it is cancelled exactly
/// once when the cell is terminated, completes, or the session shuts down,
/// and in-flight work is expected to stop promptly and return a terminal
/// error rather than hang.
public protocol CodeModeToolExecutor: Sendable {
    func executeNestedTool(
        _ invocation: CodeModeNestedToolCall,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<JSONValue, CodeModeError>

    /// Surface an interim `notify(...)` message from a running cell as an
    /// extra output for the outer `exec` call. Defaults to dropping it.
    func deliverNotification(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError>

    /// A cell reached a terminal state and can no longer be waited on.
    /// Defaults to doing nothing.
    func cellDidClose(_ cellId: CellId)
}

extension CodeModeToolExecutor {
    public func deliverNotification(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        .success(())
    }

    public func cellDidClose(_ cellId: CellId) {}
}

/// Adapts a `CodeModeToolExecutor` plus a registry snapshot into the
/// delegate an `InProcessCodeModeSession` takes.
///
/// Fails closed on an unknown tool name, matching the compatibility
/// contract's "stale callbacks and yielded cell IDs fail closed"
/// (docs/code-mode-port.md).
public struct CodeModeExecutorDelegate: CodeModeSessionDelegate {
    private let executor: CodeModeToolExecutor
    private let snapshot: CodeModeToolRegistrySnapshot

    public init(executor: CodeModeToolExecutor, snapshot: CodeModeToolRegistrySnapshot) {
        self.executor = executor
        self.snapshot = snapshot
    }

    public func invokeTool(
        _ invocation: CodeModeNestedToolCall,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<JSONValue, CodeModeError> {
        guard snapshot.definition(for: invocation.toolName) != nil else {
            return .failure(
                CodeModeError("unknown code mode tool `\(invocation.toolName)`")
            )
        }
        return await executor.executeNestedTool(
            invocation,
            cancellationToken: cancellationToken
        )
    }

    public func notify(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        await executor.deliverNotification(
            callId: callId,
            cellId: cellId,
            text: text,
            cancellationToken: cancellationToken
        )
    }

    public func cellClosed(_ cellId: CellId) {
        executor.cellDidClose(cellId)
    }
}

extension InProcessCodeModeSession {
    /// Build a session that routes nested calls back through the host.
    public convenience init(
        executor: CodeModeToolExecutor,
        snapshot: CodeModeToolRegistrySnapshot,
        executionCeilingMs: UInt64 = CODE_MODE_DEFAULT_EXECUTION_CEILING_MS
    ) {
        self.init(
            delegate: CodeModeExecutorDelegate(executor: executor, snapshot: snapshot),
            executionCeilingMs: executionCeilingMs
        )
    }
}
