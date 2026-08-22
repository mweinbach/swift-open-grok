// Runtime.swift
//
// Runtime wire types for the code-mode cell lifecycle. Ported from
// `crates/codegen/xai-grok-code-mode-protocol/src/runtime.rs`.
//
// Wire format
// -----------
// All enums use **externally tagged** Serde shape (Rust default) with
// **PascalCase** variant names and **snake_case** field names inside the
// payload object:
//
//   {"Yielded":{"cell_id":"...","content_items":[...]}}
//   {"LiveCell":{"Yielded":{...}}}
//   {"Pending":{"cell_id":"...","content_items":[],"pending_tool_call_ids":[]}}
//
// Adjacent / internal tagging would be a wire-format regression against
// the Rust source of truth.

import Foundation
import OpenGrokShared

// MARK: - Defaults

/// Default yield budget (ms) for an `exec` call when the pragma does not
/// override it. Mirrors `DEFAULT_EXEC_YIELD_TIME_MS` in the Rust crate.
public let DEFAULT_EXEC_YIELD_TIME_MS: UInt64 = 30_000

/// Default yield budget (ms) for a `wait` call.
public let DEFAULT_WAIT_YIELD_TIME_MS: UInt64 = 10_000

/// Default max output tokens budget per `exec` call.
public let DEFAULT_MAX_OUTPUT_TOKENS_PER_EXEC_CALL: Int = 10_000

// MARK: - Requests

/// Request body for starting a new code-mode cell (`exec`).
public struct ExecuteRequest: Hashable, Sendable, Codable, Equatable {
    public var toolCallId: String
    public var enabledTools: [ToolDefinition]
    public var source: String
    public var yieldTimeMs: UInt64?
    public var maxOutputTokens: Int?

    public init(
        toolCallId: String,
        enabledTools: [ToolDefinition] = [],
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

/// Request body for resuming (or checking on) a running cell (`wait`).
public struct WaitRequest: Hashable, Sendable, Codable, Equatable {
    public var cellId: CellId
    public var yieldTimeMs: UInt64

    public init(cellId: CellId, yieldTimeMs: UInt64 = DEFAULT_WAIT_YIELD_TIME_MS) {
        self.cellId = cellId
        self.yieldTimeMs = yieldTimeMs
    }

    enum CodingKeys: String, CodingKey {
        case cellId = "cell_id"
        case yieldTimeMs = "yield_time_ms"
    }
}

/// Request body for the pending-mode wait path.
public struct WaitToPendingRequest: Hashable, Sendable, Codable, Equatable {
    public var cellId: CellId

    public init(cellId: CellId) {
        self.cellId = cellId
    }

    enum CodingKeys: String, CodingKey {
        case cellId = "cell_id"
    }
}

// MARK: - External-tag Codable helpers

/// Encode/decode helper for Rust-style externally tagged enums:
/// `{"VariantName": <payload>}` where payload is a keyed object (struct
/// variant) or a nested externally-tagged value (newtype variant).
private enum ExternalTagCoding {
    /// Decode a single-key object and return `(variantName, nestedDecoder)`.
    static func decodeVariant(from decoder: Decoder) throws -> (String, KeyedDecodingContainer<DynamicCodingKey>) {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected externally tagged single-key object"
                )
            )
        }
        return (key.stringValue, c)
    }

    static func encodeVariant<T: Encodable>(
        _ name: String,
        payload: T,
        to encoder: Encoder
    ) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode(payload, forKey: DynamicCodingKey(name))
    }

    static func encodeVariantObject(
        _ name: String,
        to encoder: Encoder,
        _ body: (inout KeyedEncodingContainer<DynamicCodingKey>) throws -> Void
    ) throws {
        var outer = encoder.container(keyedBy: DynamicCodingKey.self)
        var inner = outer.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: DynamicCodingKey(name))
        try body(&inner)
    }
}

// MARK: - WaitOutcome

/// Outcome of a `wait` / `terminate` call.
///
/// - `liveCell`: the cell still exists (running or just finished).
/// - `missingCell`: the cell id is unknown / already disposed ("stale
///   cells" criterion). The wrapped `RuntimeResponse` carries whatever
///   terminal output the runtime observed before the cell closed.
///
/// Wire: externally tagged PascalCase (`LiveCell` / `MissingCell`).
public enum WaitOutcome: Hashable, Sendable, Codable, Equatable {
    case liveCell(RuntimeResponse)
    case missingCell(RuntimeResponse)

    public init(from decoder: Decoder) throws {
        let (name, c) = try ExternalTagCoding.decodeVariant(from: decoder)
        let key = DynamicCodingKey(name)
        switch name {
        case "LiveCell":
            self = .liveCell(try c.decode(RuntimeResponse.self, forKey: key))
        case "MissingCell":
            self = .missingCell(try c.decode(RuntimeResponse.self, forKey: key))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: c,
                debugDescription: "unknown WaitOutcome variant: \(name)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .liveCell(let r):
            try ExternalTagCoding.encodeVariant("LiveCell", payload: r, to: encoder)
        case .missingCell(let r):
            try ExternalTagCoding.encodeVariant("MissingCell", payload: r, to: encoder)
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

// MARK: - ExecuteToPendingOutcome

/// Outcome of an `exec` call when the runtime is in pending mode
/// (chained `exec` → `wait`).
///
/// Wire: externally tagged PascalCase (`Pending` / `Completed`).
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

    public init(from decoder: Decoder) throws {
        let (name, c) = try ExternalTagCoding.decodeVariant(from: decoder)
        let key = DynamicCodingKey(name)
        switch name {
        case "Pending":
            let inner = try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key)
            self = .pending(
                cellId: try inner.decode(CellId.self, forKey: DynamicCodingKey("cell_id")),
                contentItems: try inner.decode(
                    [FunctionCallOutputContentItem].self,
                    forKey: DynamicCodingKey("content_items")
                ),
                pendingToolCallIds: try inner.decode(
                    [String].self,
                    forKey: DynamicCodingKey("pending_tool_call_ids")
                )
            )
        case "Completed":
            self = .completed(try c.decode(RuntimeResponse.self, forKey: key))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: c,
                debugDescription: "unknown ExecuteToPendingOutcome variant: \(name)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .pending(let cellId, let contentItems, let pendingToolCallIds):
            try ExternalTagCoding.encodeVariantObject("Pending", to: encoder) { inner in
                try inner.encode(cellId, forKey: DynamicCodingKey("cell_id"))
                try inner.encode(contentItems, forKey: DynamicCodingKey("content_items"))
                try inner.encode(pendingToolCallIds, forKey: DynamicCodingKey("pending_tool_call_ids"))
            }
        case .completed(let r):
            try ExternalTagCoding.encodeVariant("Completed", payload: r, to: encoder)
        }
    }
}

// MARK: - WaitToPendingOutcome

/// Outcome of a `waitToPending` call. Like `WaitOutcome` but for the
/// pending-mode runtime.
///
/// Wire: externally tagged PascalCase (`LiveCell` / `MissingCell`).
public enum WaitToPendingOutcome: Hashable, Sendable, Codable, Equatable {
    case liveCell(ExecuteToPendingOutcome)
    case missingCell(RuntimeResponse)

    public init(from decoder: Decoder) throws {
        let (name, c) = try ExternalTagCoding.decodeVariant(from: decoder)
        let key = DynamicCodingKey(name)
        switch name {
        case "LiveCell":
            self = .liveCell(try c.decode(ExecuteToPendingOutcome.self, forKey: key))
        case "MissingCell":
            self = .missingCell(try c.decode(RuntimeResponse.self, forKey: key))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: c,
                debugDescription: "unknown WaitToPendingOutcome variant: \(name)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .liveCell(let o):
            try ExternalTagCoding.encodeVariant("LiveCell", payload: o, to: encoder)
        case .missingCell(let r):
            try ExternalTagCoding.encodeVariant("MissingCell", payload: r, to: encoder)
        }
    }
}

// MARK: - RuntimeResponse

/// Terminal or interim result of a code-mode cell.
///
/// - `yielded`: the cell is still running. The runtime has produced some
///   output and is yielding control back to the model.
/// - `terminated`: the cell was terminated by an explicit `terminate`
///   call (or by the runtime enforcing a hard limit).
/// - `result`: the JS finished naturally. `errorText` carries an error
///   message when the script threw.
///
/// Wire: externally tagged PascalCase (`Yielded` / `Terminated` /
/// `Result`) with snake_case field names.
public enum RuntimeResponse: Hashable, Sendable, Codable, Equatable {
    case yielded(cellId: CellId, contentItems: [FunctionCallOutputContentItem])
    case terminated(cellId: CellId, contentItems: [FunctionCallOutputContentItem])
    case result(
        cellId: CellId,
        contentItems: [FunctionCallOutputContentItem],
        errorText: String?
    )

    public init(from decoder: Decoder) throws {
        let (name, c) = try ExternalTagCoding.decodeVariant(from: decoder)
        let key = DynamicCodingKey(name)
        let inner = try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key)
        switch name {
        case "Yielded":
            self = .yielded(
                cellId: try inner.decode(CellId.self, forKey: DynamicCodingKey("cell_id")),
                contentItems: try inner.decode(
                    [FunctionCallOutputContentItem].self,
                    forKey: DynamicCodingKey("content_items")
                )
            )
        case "Terminated":
            self = .terminated(
                cellId: try inner.decode(CellId.self, forKey: DynamicCodingKey("cell_id")),
                contentItems: try inner.decode(
                    [FunctionCallOutputContentItem].self,
                    forKey: DynamicCodingKey("content_items")
                )
            )
        case "Result":
            self = .result(
                cellId: try inner.decode(CellId.self, forKey: DynamicCodingKey("cell_id")),
                contentItems: try inner.decode(
                    [FunctionCallOutputContentItem].self,
                    forKey: DynamicCodingKey("content_items")
                ),
                // Rust Option without skip_serializing_if emits null;
                // decodeIfPresent also accepts missing for resilience.
                errorText: try inner.decodeIfPresent(String.self, forKey: DynamicCodingKey("error_text"))
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: c,
                debugDescription: "unknown RuntimeResponse variant: \(name)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .yielded(let cellId, let contentItems):
            try ExternalTagCoding.encodeVariantObject("Yielded", to: encoder) { inner in
                try inner.encode(cellId, forKey: DynamicCodingKey("cell_id"))
                try inner.encode(contentItems, forKey: DynamicCodingKey("content_items"))
            }
        case .terminated(let cellId, let contentItems):
            try ExternalTagCoding.encodeVariantObject("Terminated", to: encoder) { inner in
                try inner.encode(cellId, forKey: DynamicCodingKey("cell_id"))
                try inner.encode(contentItems, forKey: DynamicCodingKey("content_items"))
            }
        case .result(let cellId, let contentItems, let errorText):
            try ExternalTagCoding.encodeVariantObject("Result", to: encoder) { inner in
                try inner.encode(cellId, forKey: DynamicCodingKey("cell_id"))
                try inner.encode(contentItems, forKey: DynamicCodingKey("content_items"))
                // Match Rust: always emit error_text (null when nil).
                try inner.encode(errorText, forKey: DynamicCodingKey("error_text"))
            }
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

// MARK: - CodeModeNestedToolCall

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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cellId = try c.decode(CellId.self, forKey: .cellId)
        runtimeToolCallId = try c.decode(String.self, forKey: .runtimeToolCallId)
        toolName = try c.decode(ToolName.self, forKey: .toolName)
        toolKind = try c.decode(CodeModeToolKind.self, forKey: .toolKind)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cellId, forKey: .cellId)
        try c.encode(runtimeToolCallId, forKey: .runtimeToolCallId)
        try c.encode(toolName, forKey: .toolName)
        try c.encode(toolKind, forKey: .toolKind)
        // Match Rust Option default: emit null when absent.
        try c.encode(input, forKey: .input)
    }
}
