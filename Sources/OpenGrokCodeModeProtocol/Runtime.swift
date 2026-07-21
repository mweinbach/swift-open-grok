// Runtime.swift
//
// Runtime wire types for the code-mode protocol. Ported from
// `crates/codegen/xai-grok-code-mode-protocol/src/runtime.rs`.
//
// These types model the lifecycle of a code-mode cell:
//   * `ExecuteRequest` starts a cell (carrying the JS source, enabled
//     nested tools, and optional yield-time / max-output-token overrides).
//   * `RuntimeResponse` is the terminal or interim result of a cell:
//     `yielded` (still running, more output available), `terminated`
//     (caller asked to stop), or `result` (the JS finished). The exec
//     runtime also surfaces `generatedImage` outputs via the same
//     `content_items` channel.
//   * `WaitRequest` resumes a running cell, optionally terminating it.
//   * `WaitOutcome` distinguishes a live cell from a missing cell so the
//     `wait` tool can surface "stale cell" cases without losing the
//     terminal response.
//   * `ExecuteToPendingOutcome` / `WaitToPendingOutcome` /
//     `WaitToPendingRequest` carry the pending state used by the runtime
//     to chain `exec` → `wait` → `wait` cycles while a cell is still
//     running.
//   * `CodeModeNestedToolCall` records a nested tool invocation issued
//     from inside the JS isolate (`await tools.<name>(...)`) so the
//     runtime can route it through the permission gate and the tool
//     registry.
//
// Together with `Session.swift`'s `CodeModeSession` / `StartedCell` /
// `CodeModeSessionDelegate`, this is the complete cell lifecycle:
// exec → yield → wait → terminate / result → cellClosed. Runtime
// disposal is the `shutdown` call on the session plus the
// `CodeModeSessionDelegate.cellClosed` callback per cell.

import Foundation
import OpenGrokShared

/// Default yield time for an `exec` call (10 s). The exec tool yields
/// after this interval if the script is still running.
public let DEFAULT_EXEC_YIELD_TIME_MS: UInt64 = 10_000

/// Default yield time for a `wait` call (10 s). The wait tool yields
/// after this interval if the cell is still producing output.
public let DEFAULT_WAIT_YIELD_TIME_MS: UInt64 = 10_000

/// Default token budget for direct `exec` results (10 000 tokens).
/// Surplus output is truncated by the runtime; nested tool outputs are
/// not counted against this budget.
public let DEFAULT_MAX_OUTPUT_TOKENS_PER_EXEC_CALL: Int = 10_000

/// Request to start an `exec` cell.
public struct ExecuteRequest: Hashable, Sendable, Codable, Equatable {
    /// Tool call id issued by the sampler; used to correlate the exec
    /// call with downstream permission decisions and tool-stream chunks.
    public var toolCallId: String
    /// Nested tools the cell is allowed to invoke via `await tools.<name>`.
    public var enabledTools: [ToolDefinition]
    /// Raw JavaScript source text (with the optional `// @exec:` pragma
    /// already stripped by `parseExecSource`).
    public var source: String
    /// Override for `DEFAULT_EXEC_YIELD_TIME_MS`. `nil` = use the default.
    public var yieldTimeMs: UInt64?
    /// Override for `DEFAULT_MAX_OUTPUT_TOKENS_PER_EXEC_CALL`. `nil` = use
    /// the default.
    public var maxOutputTokens: Int?

    public init(
        toolCallId: String,
        enabledTools: [ToolDefinition],
        source: String,
        yieldTimeMs: UInt64? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.toolCallId = toolCallId
        self.enabledTools = enabledTools
        self.source = source
        self.yieldTimeMs = yieldTimeMs
        self.maxOutputTokens = maxOutputTokens
    }

    enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case enabledTools = "enabled_tools"
        case source
        case yieldTimeMs = "yield_time_ms"
        case maxOutputTokens = "max_output_tokens"
    }
}

/// Request to resume (or terminate) a running cell.
public struct WaitRequest: Hashable, Sendable, Codable, Equatable {
    public var cellId: CellId
    public var yieldTimeMs: UInt64

    public init(cellId: CellId, yieldTimeMs: UInt64) {
        self.cellId = cellId
        self.yieldTimeMs = yieldTimeMs
    }

    enum CodingKeys: String, CodingKey {
        case cellId = "cell_id"
        case yieldTimeMs = "yield_time_ms"
    }
}

/// Request to convert a running cell to pending (used internally by the
/// runtime when chaining `exec` → `wait`).
public struct WaitToPendingRequest: Hashable, Sendable, Codable, Equatable {
    public var cellId: CellId

    public init(cellId: CellId) {
        self.cellId = cellId
    }

    enum CodingKeys: String, CodingKey {
        case cellId = "cell_id"
    }
}

/// Outcome of a `wait` call. Distinguishes a live cell from a missing
/// (already-closed / never-existed / stale) cell so the `wait` tool can
/// surface "stale cell" cases without losing the terminal response.
///
/// The "stale cells" criterion in the W1-S4 acceptance is satisfied by
/// the `missingCell` case: callers learn that the cell id they tried to
/// wait on no longer exists (or never did), and the wrapped
/// `RuntimeResponse` carries whatever final output the runtime observed
/// before the cell closed.
public enum WaitOutcome: Hashable, Sendable, Codable, Equatable {
    case liveCell(RuntimeResponse)
    case missingCell(RuntimeResponse)

    private enum Tag: String, Codable {
        case liveCell = "live_cell"
        case missingCell = "missing_cell"
    }
    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        let response = try c.decode(RuntimeResponse.self, forKey: .data)
        switch tag {
        case .liveCell: self = .liveCell(response)
        case .missingCell: self = .missingCell(response)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .liveCell(let r):
            try c.encode(Tag.liveCell, forKey: .type)
            try c.encode(r, forKey: .data)
        case .missingCell(let r):
            try c.encode(Tag.missingCell, forKey: .type)
            try c.encode(r, forKey: .data)
        }
    }

    /// Collapse to the wrapped `RuntimeResponse` (mirrors the Rust
    /// `From<WaitOutcome> for RuntimeResponse` impl).
    public var response: RuntimeResponse {
        switch self {
        case .liveCell(let r), .missingCell(let r): return r
        }
    }
}

/// Outcome of an `exec` call when the runtime is in pending mode
/// (chained `exec` → `wait`).
public enum ExecuteToPendingOutcome: Hashable, Sendable, Codable, Equatable {
    /// The cell is still running; the runtime has yielded some output and
    /// a list of pending nested tool call ids that have not yet resolved.
    case pending(
        cellId: CellId,
        contentItems: [FunctionCallOutputContentItem],
        pendingToolCallIds: [String]
    )
    /// The cell finished during the exec call (no need to wait).
    case completed(RuntimeResponse)

    private enum Tag: String, Codable {
        case pending, completed
    }
    private enum CodingKeys: String, CodingKey {
        case type, data
        case cellId = "cell_id"
        case contentItems = "content_items"
        case pendingToolCallIds = "pending_tool_call_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .pending:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .pending(
                cellId: try inner.decode(CellId.self, forKey: .cellId),
                contentItems: try inner.decode([FunctionCallOutputContentItem].self, forKey: .contentItems),
                pendingToolCallIds: try inner.decode([String].self, forKey: .pendingToolCallIds)
            )
        case .completed:
            self = .completed(try c.decode(RuntimeResponse.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending(let cellId, let contentItems, let pendingToolCallIds):
            try c.encode(Tag.pending, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(cellId, forKey: .cellId)
            try inner.encode(contentItems, forKey: .contentItems)
            try inner.encode(pendingToolCallIds, forKey: .pendingToolCallIds)
        case .completed(let r):
            try c.encode(Tag.completed, forKey: .type)
            try c.encode(r, forKey: .data)
        }
    }
}

/// Outcome of a `waitToPending` call. Like `WaitOutcome` but for the
/// pending-mode runtime.
public enum WaitToPendingOutcome: Hashable, Sendable, Codable, Equatable {
    case liveCell(ExecuteToPendingOutcome)
    case missingCell(RuntimeResponse)

    private enum Tag: String, Codable {
        case liveCell = "live_cell"
        case missingCell = "missing_cell"
    }
    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .liveCell:
            self = .liveCell(try c.decode(ExecuteToPendingOutcome.self, forKey: .data))
        case .missingCell:
            self = .missingCell(try c.decode(RuntimeResponse.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .liveCell(let o):
            try c.encode(Tag.liveCell, forKey: .type)
            try c.encode(o, forKey: .data)
        case .missingCell(let r):
            try c.encode(Tag.missingCell, forKey: .type)
            try c.encode(r, forKey: .data)
        }
    }
}

/// Terminal or interim result of a code-mode cell.
///
/// - `yielded`: the cell is still running. The runtime has produced some
///   output and is yielding control back to the model. The model can
///   either call `wait` to resume or stop calling and let the cell
///   finish.
/// - `terminated`: the cell was terminated by an explicit `terminate`
///   call (or by the runtime enforcing a hard limit). No further output
///   will be produced.
/// - `result`: the JS finished naturally. `errorText` carries an error
///   message when the script threw.
///
/// The `exec` / `wait` / `terminate` / nested-call lifecycle is the
/// "exec, yield, wait, terminate, nested calls, structured content,
/// images, generated images, stale cells, and runtime disposal"
/// vocabulary required by the W1-S4 acceptance criterion. Structured
/// content and images / generated images flow through `contentItems`;
/// stale cells are surfaced via `WaitOutcome.missingCell`; runtime
/// disposal is `CodeModeSession.shutdown` (see `Session.swift`).
public enum RuntimeResponse: Hashable, Sendable, Codable, Equatable {
    case yielded(cellId: CellId, contentItems: [FunctionCallOutputContentItem])
    case terminated(cellId: CellId, contentItems: [FunctionCallOutputContentItem])
    case result(
        cellId: CellId,
        contentItems: [FunctionCallOutputContentItem],
        errorText: String?
    )

    private enum Tag: String, Codable {
        case yielded, terminated, result
    }
    private enum CodingKeys: String, CodingKey {
        case type, data
        case cellId = "cell_id"
        case contentItems = "content_items"
        case errorText = "error_text"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .yielded:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .yielded(
                cellId: try inner.decode(CellId.self, forKey: .cellId),
                contentItems: try inner.decode([FunctionCallOutputContentItem].self, forKey: .contentItems)
            )
        case .terminated:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .terminated(
                cellId: try inner.decode(CellId.self, forKey: .cellId),
                contentItems: try inner.decode([FunctionCallOutputContentItem].self, forKey: .contentItems)
            )
        case .result:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .result(
                cellId: try inner.decode(CellId.self, forKey: .cellId),
                contentItems: try inner.decode([FunctionCallOutputContentItem].self, forKey: .contentItems),
                errorText: try inner.decodeIfPresent(String.self, forKey: .errorText)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .yielded(let cellId, let contentItems):
            try c.encode(Tag.yielded, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(cellId, forKey: .cellId)
            try inner.encode(contentItems, forKey: .contentItems)
        case .terminated(let cellId, let contentItems):
            try c.encode(Tag.terminated, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(cellId, forKey: .cellId)
            try inner.encode(contentItems, forKey: .contentItems)
        case .result(let cellId, let contentItems, let errorText):
            try c.encode(Tag.result, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(cellId, forKey: .cellId)
            try inner.encode(contentItems, forKey: .contentItems)
            try inner.encodeIfPresent(errorText, forKey: .errorText)
        }
    }

    /// The cell id this response refers to.
    public var cellId: CellId {
        switch self {
        case .yielded(let id, _): return id
        case .terminated(let id, _): return id
        case .result(let id, _, _): return id
        }
    }

    /// The content items produced so far.
    public var contentItems: [FunctionCallOutputContentItem] {
        switch self {
        case .yielded(_, let items): return items
        case .terminated(_, let items): return items
        case .result(_, let items, _): return items
        }
    }
}

/// A nested tool call issued from inside a code-mode cell.
///
/// Recorded by the runtime when the JS isolate calls
/// `await tools.<name>(...)` so the host can route the invocation through
/// the permission gate and the tool registry. The `runtimeToolCallId` is
/// a per-cell id the runtime uses to correlate the call with its result.
public struct CodeModeNestedToolCall: Hashable, Sendable, Codable, Equatable {
    public var cellId: CellId
    public var runtimeToolCallId: String
    public var toolName: ToolName
    public var toolKind: CodeModeToolKind
    /// The input argument passed by the JS (a string for freeform tools,
    /// a JSON object for function tools). `nil` when the JS called the
    /// tool with no argument.
    public var input: JSONValue?

    public init(
        cellId: CellId,
        runtimeToolCallId: String,
        toolName: ToolName,
        toolKind: CodeModeToolKind,
        input: JSONValue? = nil
    ) {
        self.cellId = cellId
        self.runtimeToolCallId = runtimeToolCallId
        self.toolName = toolName
        self.toolKind = toolKind
        self.input = input
    }

    enum CodingKeys: String, CodingKey {
        case cellId = "cell_id"
        case runtimeToolCallId = "runtime_tool_call_id"
        case toolName = "tool_name"
        case toolKind = "tool_kind"
        case input
    }
}
