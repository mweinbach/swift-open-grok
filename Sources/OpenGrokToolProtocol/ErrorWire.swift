// ErrorWire.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/error_wire.rs`.
//
// Wire-friendly error type carried inside the JSON-RPC `error.data` field.
// Internally tagged on `"code"` with snake_case discriminators.

import Foundation
import OpenGrokShared

/// Stable wire representation of a tool-call failure.
///
/// Receivers SHOULD switch on the `code` discriminator (e.g.
/// `tool_not_found`) rather than the numeric JSON-RPC `error.code`.
///
/// Mirrors Rust `ToolErrorWire`.
public enum ToolErrorWire: Codable, Sendable, Hashable {
    case toolNotFound(toolId: ToolId)
    case sessionMismatch
    case permissionDenied(reason: String)
    case transportClosed(toolId: ToolId)
    case timeout(toolId: ToolId, elapsedMs: UInt64)
    case cancelled(toolId: ToolId)
    case invalidArguments(message: String, details: JSONValue?)
    case execution(toolId: ToolId, message: String)
    case unsupportedProtocolVersion(supported: [String])
    case payloadTooLarge(bytes: UInt64, limit: UInt64)
    case behaviorVersionUnsupported(toolId: ToolId, requested: String)
    case renderLimited(toolId: ToolId, cardId: String?, reason: String)
    case terminalError(toolId: ToolId, message: String)
    case internalError(requestId: RequestId?, detail: String?)
    /// Free-form forward-compat error. Outer `code` is always `"custom"`.
    case custom(subcode: String, message: String, details: JSONValue?)

    private enum CodingKeys: String, CodingKey {
        case code
        case toolId = "tool_id"
        case reason
        case elapsedMs = "elapsed_ms"
        case message
        case details
        case supported
        case bytes
        case limit
        case requested
        case cardId = "card_id"
        case requestId = "request_id"
        case detail
        case subcode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        switch code {
        case "tool_not_found":
            self = .toolNotFound(toolId: try c.decode(ToolId.self, forKey: .toolId))
        case "session_mismatch":
            self = .sessionMismatch
        case "forbidden":
            self = .permissionDenied(reason: try c.decode(String.self, forKey: .reason))
        case "connection_lost":
            self = .transportClosed(toolId: try c.decode(ToolId.self, forKey: .toolId))
        case "timeout":
            self = .timeout(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                elapsedMs: try c.decode(UInt64.self, forKey: .elapsedMs)
            )
        case "cancelled":
            self = .cancelled(toolId: try c.decode(ToolId.self, forKey: .toolId))
        case "invalid_params":
            self = .invalidArguments(
                message: try c.decode(String.self, forKey: .message),
                details: try c.decodeIfPresent(JSONValue.self, forKey: .details)
            )
        case "execution":
            self = .execution(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                message: try c.decode(String.self, forKey: .message)
            )
        case "unsupported_protocol_version":
            self = .unsupportedProtocolVersion(
                supported: try c.decode([String].self, forKey: .supported)
            )
        case "frame_too_large":
            self = .payloadTooLarge(
                bytes: try c.decode(UInt64.self, forKey: .bytes),
                limit: try c.decode(UInt64.self, forKey: .limit)
            )
        case "behavior_version_unsupported":
            self = .behaviorVersionUnsupported(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                requested: try c.decode(String.self, forKey: .requested)
            )
        case "render_limited":
            self = .renderLimited(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                cardId: try c.decodeIfPresent(String.self, forKey: .cardId),
                reason: try c.decode(String.self, forKey: .reason)
            )
        case "terminal_error":
            self = .terminalError(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                message: try c.decode(String.self, forKey: .message)
            )
        case "internal_error":
            self = .internalError(
                requestId: try c.decodeIfPresent(RequestId.self, forKey: .requestId),
                detail: try c.decodeIfPresent(String.self, forKey: .detail)
            )
        case "custom":
            self = .custom(
                subcode: try c.decode(String.self, forKey: .subcode),
                message: try c.decode(String.self, forKey: .message),
                details: try c.decodeIfPresent(JSONValue.self, forKey: .details)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .code, in: c,
                debugDescription: "unknown ToolErrorWire code: \(code)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toolNotFound(let toolId):
            try c.encode("tool_not_found", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
        case .sessionMismatch:
            try c.encode("session_mismatch", forKey: .code)
        case .permissionDenied(let reason):
            try c.encode("forbidden", forKey: .code)
            try c.encode(reason, forKey: .reason)
        case .transportClosed(let toolId):
            try c.encode("connection_lost", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
        case .timeout(let toolId, let elapsedMs):
            try c.encode("timeout", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
            try c.encode(elapsedMs, forKey: .elapsedMs)
        case .cancelled(let toolId):
            try c.encode("cancelled", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
        case .invalidArguments(let message, let details):
            try c.encode("invalid_params", forKey: .code)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(details, forKey: .details)
        case .execution(let toolId, let message):
            try c.encode("execution", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
            try c.encode(message, forKey: .message)
        case .unsupportedProtocolVersion(let supported):
            try c.encode("unsupported_protocol_version", forKey: .code)
            try c.encode(supported, forKey: .supported)
        case .payloadTooLarge(let bytes, let limit):
            try c.encode("frame_too_large", forKey: .code)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(limit, forKey: .limit)
        case .behaviorVersionUnsupported(let toolId, let requested):
            try c.encode("behavior_version_unsupported", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
            try c.encode(requested, forKey: .requested)
        case .renderLimited(let toolId, let cardId, let reason):
            try c.encode("render_limited", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
            try c.encodeIfPresent(cardId, forKey: .cardId)
            try c.encode(reason, forKey: .reason)
        case .terminalError(let toolId, let message):
            try c.encode("terminal_error", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
            try c.encode(message, forKey: .message)
        case .internalError(let requestId, let detail):
            try c.encode("internal_error", forKey: .code)
            try c.encodeIfPresent(requestId, forKey: .requestId)
            try c.encodeIfPresent(detail, forKey: .detail)
        case .custom(let subcode, let message, let details):
            try c.encode("custom", forKey: .code)
            try c.encode(subcode, forKey: .subcode)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(details, forKey: .details)
        }
    }

    public var description: String {
        switch self {
        case .toolNotFound(let id): return "tool not found: \(id)"
        case .sessionMismatch: return "session mismatch"
        case .permissionDenied(let reason): return "permission denied: \(reason)"
        case .transportClosed(let id): return "transport closed for \(id)"
        case .timeout(let id, let ms): return "timeout after \(ms)ms for \(id)"
        case .cancelled: return "cancelled"
        case .invalidArguments(let message, _): return "invalid arguments: \(message)"
        case .execution(let id, let message): return "execution error in \(id): \(message)"
        case .unsupportedProtocolVersion: return "unsupported protocol version"
        case .payloadTooLarge(let bytes, let limit): return "payload too large: \(bytes) bytes (limit \(limit))"
        case .behaviorVersionUnsupported: return "behavior_version unsupported"
        case .renderLimited(let id, _, let reason): return "render limited for \(id): \(reason)"
        case .terminalError(let id, let message): return "terminal subprocess error in \(id): \(message)"
        case .internalError(_, let detail):
            if let detail { return "internal error: \(detail)" }
            return "internal error"
        case .custom(let subcode, let message, _): return "custom: \(subcode) — \(message)"
        }
    }
}
