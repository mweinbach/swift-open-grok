// ErrorCodes.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/error_codes.rs`.
//
// Numeric ↔ string error-code mapping. Receivers SHOULD switch on
// `data.code` (the snake_case string) rather than the numeric JSON-RPC
// `error.code`.

import Foundation
import OpenGrokShared

/// `(numeric_code, string_code)` pairs. Both columns are unique.
///
/// Mirrors Rust `ERROR_CODES`.
public let errorCodes: [(Int32, String)] = [
    (-32700, "parse_error"),
    (-32600, "invalid_request"),
    (-32601, "method_not_found"),
    (-32602, "invalid_params"),
    (-32603, "internal_error"),
    (-32605, "unsupported_protocol_version"),
    (-32001, "timeout"),
    (-32002, "unauthorized"),
    (-32003, "forbidden"),
    (-32004, "connection_lost"),
    (-32005, "tool_server_gone"),
    (-32006, "session_not_found"),
    (-32008, "session_draining"),
    (-32011, "tool_not_found"),
    (-32012, "tool_already_registered"),
    (-32013, "tool_unavailable"),
    (-32014, "stale_generation"),
    (-32015, "duplicate_client_name"),
    (-32016, "tool_busy"),
    (-32017, "notification_schema_violation"),
    (-32018, "frame_too_large"),
    (-32019, "schema_unknown_kind"),
    (-32020, "behavior_version_unsupported"),
    (-32021, "server_id_in_use"),
    (-32022, "invalid_description"),
    (-32023, "render_limited"),
    (-32024, "terminal_error"),
    (-32099, "rate_limited"),
]

/// Returns `nil` for strings not in the table. Receivers should fall
/// back to `-32603 internal_error` for unknown strings.
public func numericCode(for codeStr: String) -> Int32? {
    errorCodes.first { $0.1 == codeStr }?.0
}

/// Returns `nil` for codes not in the table.
public func stringCode(for code: Int32) -> String? {
    errorCodes.first { $0.0 == code }?.1
}

/// Numeric code most-appropriate for a `ToolErrorWire` variant.
/// `Custom` always maps to `-32603 internal_error` since its `code`
/// string is not in the table by definition.
public func numericCode(from wire: ToolErrorWire) -> Int32 {
    switch wire {
    case .toolNotFound: return -32011
    case .sessionMismatch: return -32600
    case .permissionDenied: return -32003
    case .transportClosed: return -32004
    case .timeout: return -32001
    case .cancelled: return -32603
    case .invalidArguments: return -32602
    case .execution: return -32603
    case .unsupportedProtocolVersion: return -32605
    case .payloadTooLarge: return -32018
    case .behaviorVersionUnsupported: return -32020
    case .internalError: return -32603
    case .renderLimited: return -32023
    case .terminalError: return -32024
    case .custom: return -32603
    }
}

/// Stable identifier for "this session's workspace (tool) server is gone;
/// re-provision and retry".
public let workspaceUnavailableSubcode = "workspace_unavailable"

/// Generic, tenant-data-free message paired with the workspace-gone error.
public let workspaceUnavailableMessage = "workspace server gone; re-provision and retry"

/// JSON-RPC envelope code paired with the workspace-unavailable error.
public let workspaceUnavailableJsonrpcCode: Int32 = -32005

/// Why the workspace (tool) server went away. `unknown` absorbs values a
/// newer peer may add.
public enum WorkspaceGoneReason: String, Codable, Sendable, Hashable {
    case idleTimeout = "idle_timeout"
    case disconnect
    case shutdown
    case notBound = "not_bound"
    case instanceGone = "instance_gone"
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = WorkspaceGoneReason(rawValue: raw) ?? .unknown
    }
}

/// When, relative to the failing tool call, the loss was observed.
public enum WorkspaceGonePhase: String, Codable, Sendable, Hashable {
    case inFlightCancelled = "in_flight_cancelled"
    case routeMissing = "route_missing"
    case attach
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = WorkspaceGonePhase(rawValue: raw) ?? .unknown
    }
}

/// Structured payload placed in the wire `details` object.
public struct WorkspaceUnavailableDetails: Codable, Sendable, Hashable {
    public var code: String
    public var reason: WorkspaceGoneReason
    public var phase: WorkspaceGonePhase
    public var retryable: Bool

    public init(
        code: String = workspaceUnavailableSubcode,
        reason: WorkspaceGoneReason,
        phase: WorkspaceGonePhase,
        retryable: Bool = true
    ) {
        self.code = code
        self.reason = reason
        self.phase = phase
        self.retryable = retryable
    }
}

/// Build the recognizable "workspace gone" error as a `ToolErrorWire.custom`.
public func workspaceUnavailableWire(
    reason: WorkspaceGoneReason,
    phase: WorkspaceGonePhase
) -> ToolErrorWire {
    let details = WorkspaceUnavailableDetails(reason: reason, phase: phase)
    let detailsValue = (try? JSONValue.encode(details)) ?? .object([
        "code": .string(workspaceUnavailableSubcode),
        "reason": .string(reason.rawValue),
        "phase": .string(phase.rawValue),
        "retryable": .bool(true),
    ])
    return .custom(
        subcode: workspaceUnavailableSubcode,
        message: workspaceUnavailableMessage,
        details: detailsValue
    )
}
