// WireCodec.swift
//
// Decode tool_call_result bodies, ToolErrorWire, and structured
// text/image/binary outputs. Ported from
// `xai-computer-hub-core/src/remote.rs` (decode_call_result /
// output_to_value / tool_error_from_wire / error_from_envelope).

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime

// MARK: - Output projection

/// Project a wire `ToolOutputWire` into a runtime JSON value.
///
/// - `text` → JSON string
/// - `json` → forwarded verbatim
/// - `mcp { blocks }` → `{ "blocks": [ContentBlock, ...] }`
public func outputToValue(_ output: ToolOutputWire) -> JSONValue {
    switch output {
    case .text(let s):
        return .string(s)
    case .json(let v):
        return v
    case .mcp(let blocks):
        let runtimeBlocks = blocks.map(mapMcpBlock)
        let encoded = (try? JSONValue.encode(runtimeBlocks)) ?? .null
        return .object(["blocks": encoded])
    }
}

/// Map a protocol `McpBlock` into a runtime `ContentBlock`.
public func mapMcpBlock(_ block: McpBlock) -> ContentBlock {
    switch block {
    case .text(let text):
        return .text(text: text)
    case .image(let mimeType, let data):
        return .image(
            mimeType: mimeType,
            data: data,
            mediaId: nil,
            filename: nil,
            path: nil,
            metadata: [:]
        )
    case .resource(let uri, let mimeType, let text):
        return .resource(uri: uri, mimeType: mimeType, text: text)
    }
}

/// Decode a `tool_call_result` success body into `TypedToolOutput`.
///
/// A body with a `tool_call_id` is decoded strictly (`response_decoding`
/// on failure). A bare body (hub-local raw output) passes through
/// unchanged via `TypedToolOutput.fromValue`.
public func decodeCallResult(
    toolId: ToolId,
    value: JSONValue
) -> Result<TypedToolOutput, ToolError> {
    // Bare body path: no tool_call_id key.
    if case .object(let map) = value, map["tool_call_id"] == nil {
        return .success(.fromValue(toolId: toolId, value: value))
    }
    if case .object = value {
        // continue
    } else {
        return .success(.fromValue(toolId: toolId, value: value))
    }

    let result: ToolCallResult
    do {
        result = try value.decode(ToolCallResult.self)
    } catch {
        return .failure(.custom(code: "response_decoding", detail: "\(error)"))
    }

    var chat: ToolChatCompletionResponse?
    if let cco = result.chatCompletionOutput {
        chat = try? cco.decode(ToolChatCompletionResponse.self)
    }

    let projected = outputToValue(result.output)
    let typed = TypedToolOutput.fromValue(toolId: toolId, value: projected)
        .withChatCompletionOutput(chat)
    return .success(typed)
}

// MARK: - Progress

/// Map a wire-side `ToolCallProgressFrame` into a runtime `ToolProgress`.
public func progressFromFrame(_ frame: ToolCallProgressFrame) -> ToolProgress {
    .custom(subkind: frame.kind, payload: frame.body)
}

// MARK: - Error wire bridge

/// Map `ToolErrorWire` into the runtime `ToolError`.
public func toolErrorFromWire(_ wire: ToolErrorWire) -> ToolError {
    switch wire {
    case .invalidArguments(let message, let details):
        var e = ToolError.invalidArguments(message)
        if let details { e = e.withDetails(details) }
        return e
    case .toolNotFound(let toolId):
        return .notFound(toolId: toolId, detail: "tool not found: \(toolId.rawValue)")
    case .permissionDenied(let reason):
        return .permissionDenied(reason)
    case .timeout(let toolId, let elapsedMs):
        return ToolError(
            kind: .timeout,
            detail: "timed out after \(elapsedMs)ms",
            details: .object([
                "tool_id": .string(toolId.rawValue),
                "elapsed_ms": .number(.uint64(elapsedMs)),
            ])
        )
    case .cancelled(let toolId):
        return .cancelled(toolId: toolId, detail: "cancelled")
    case .execution(let toolId, let message):
        return .execution(toolId: toolId, detail: message)
    case .behaviorVersionUnsupported(let toolId, let requested):
        return ToolError(
            kind: .behaviorVersionUnsupported,
            detail: "behavior version \(requested) not supported",
            details: .object([
                "tool_id": .string(toolId.rawValue),
                "requested": .string(requested),
            ])
        )
    case .renderLimited(let toolId, let cardId, let reason):
        var details: [String: JSONValue] = ["tool_id": .string(toolId.rawValue)]
        if let cardId { details["card_id"] = .string(cardId) }
        return ToolError(kind: .renderLimited, detail: reason, details: .object(details))
    case .terminalError(let toolId, let message):
        return .terminalError(toolId: toolId, detail: message)
    case .custom(let subcode, let message, let details):
        let e = ToolError.custom(code: subcode, detail: message)
        if let details { return e.withDetails(details) }
        return e
    case .sessionMismatch:
        return .custom(code: "session_mismatch", detail: "session mismatch")
    case .transportClosed(let toolId):
        return .networkError("transport closed for \(toolId.rawValue)")
    case .unsupportedProtocolVersion(let supported):
        let joined = supported.joined(separator: ",")
        return .custom(
            code: "unsupported_protocol_version",
            detail: "supported versions: [\(joined)]"
        )
    case .payloadTooLarge(let bytes, let limit):
        return .custom(
            code: "payload_too_large",
            detail: "payload \(bytes) bytes exceeds limit \(limit)"
        )
    case .internalError(let requestId, let detail):
        let message = detail ?? "internal router error"
        let e = ToolError.custom(code: "internal_error", detail: message)
        if let requestId {
            return e.withDetails(.object([
                "code": .string("internal_error"),
                "request_id": .string(requestId.asStr),
            ]))
        }
        return e
    }
}

/// Decode a JSON-RPC error envelope into a runtime `ToolError`.
///
/// Prefers a serialised `ToolErrorWire` in `data`; falls back to a custom
/// error keyed by the numeric envelope code.
public func errorFromEnvelope(_ err: JsonRpcError) -> ToolError {
    if let data = err.data, let wire = try? data.decode(ToolErrorWire.self) {
        return toolErrorFromWire(wire)
    }
    // Also accept the flat workspace_unavailable shape
    // `{ "subcode"|"code": "workspace_unavailable", ... }` used by some hubs.
    if let data = err.data,
       case .object(let map) = data,
       case .string(let sub) = map["subcode"] ?? map["code"],
       sub == workspaceUnavailableSubcode
    {
        // Preserve structured details when present; otherwise install the
        // canonical code so recognition still works.
        let details: JSONValue
        if map["code"] != nil {
            details = data
        } else {
            var m = map
            m["code"] = .string(workspaceUnavailableSubcode)
            details = .object(m)
        }
        return ToolError(
            kind: .custom,
            detail: err.message.isEmpty ? workspaceUnavailableMessage : err.message,
            details: details
        )
    }
    var e = ToolError.custom(code: "jsonrpc_\(err.code)", detail: err.message)
    if let data = err.data {
        e = e.withDetails(data)
    }
    return e
}

/// Whether a `ToolError` is the recognizable workspace-gone signal.
///
/// Keys on `details["code"]` only — never the numeric JSON-RPC code or
/// a bare outer custom subcode without `details.code`.
public func isWorkspaceUnavailable(_ err: ToolError) -> Bool {
    guard err.kind == .custom else { return false }
    guard case .object(let map) = err.details,
          case .string(let code) = map["code"]
    else { return false }
    return code == workspaceUnavailableSubcode
}

/// Build a workspace-unavailable tool error with structured details.
public func workspaceUnavailableError(
    reason: WorkspaceGoneReason,
    phase: WorkspaceGonePhase
) -> ToolError {
    let details = WorkspaceUnavailableDetails(reason: reason, phase: phase)
    let encoded = (try? JSONValue.encode(details)) ?? .object([
        "code": .string(workspaceUnavailableSubcode),
        "reason": .string(reason.rawValue),
        "phase": .string(phase.rawValue),
        "retryable": .bool(true),
    ])
    return ToolError(
        kind: .custom,
        detail: workspaceUnavailableMessage,
        details: encoded
    )
}
