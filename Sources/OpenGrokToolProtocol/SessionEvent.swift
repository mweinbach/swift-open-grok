// SessionEvent.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/session_event.rs`.
//
// Session lifecycle events designed to ride inside `ToolNotificationFrame`
// as Custom notifications with `kind = "session_event"`.
//
// Unknown future event types are preserved losslessly (original
// `event_type` + full JSON payload) so re-encoding does not drop fields
// from a newer peer. This is stronger than Rust's `#[serde(other)]
// Unknown` unit variant, and matches the R01 acceptance criterion for
// forward-compatible content preservation.

import Foundation
import OpenGrokShared

/// Session lifecycle event.
///
/// Internally tagged on `event_type` (snake_case). The `unknown` variant
/// absorbs future event types so older consumers never fail deserialization,
/// retaining the original discriminator and payload for lossless re-encode.
public enum SessionEvent: Codable, Sendable, Hashable {
    case turnStarted(turnNumber: UInt64, modelId: String, yoloMode: Bool)
    case turnEnded(
        turnNumber: UInt64,
        outcome: TurnHookOutcome,
        durationMs: UInt64,
        toolCallCount: UInt32,
        modelId: String
    )
    case toolCallStarted(toolCallId: String, toolName: String, turnNumber: UInt64)
    case toolCallCompleted(
        toolCallId: String,
        toolName: String,
        durationMs: UInt64,
        outcome: ToolCallOutcome
    )
    case phaseChanged(phase: SessionPhase)
    /// Forward-compatibility catch-all. Consumers MUST silently ignore.
    ///
    /// - `eventType`: original `event_type` discriminator from the wire
    /// - `payload`: full original object (including `event_type` and all
    ///   unknown fields), re-encoded unchanged
    case unknown(eventType: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case turnNumber = "turn_number"
        case modelId = "model_id"
        case yoloMode = "yolo_mode"
        case outcome
        case durationMs = "duration_ms"
        case toolCallCount = "tool_call_count"
        case toolCallId = "tool_call_id"
        case toolName = "tool_name"
        case phase
    }

    public init(from decoder: Decoder) throws {
        // Decode the full object first so unknown variants keep every field.
        let full = try JSONValue(from: decoder)
        guard case .object(let obj) = full else {
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SessionEvent must be a JSON object"
                )
            )
        }
        guard case .string(let eventType) = obj["event_type"] else {
            throw DecodingError.keyNotFound(
                CodingKeys.eventType,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "missing event_type"
                )
            )
        }

        switch eventType {
        case "turn_started":
            let turnNumber = try Self.requireUInt64(obj, "turn_number", codingPath: decoder.codingPath)
            let modelId = try Self.requireString(obj, "model_id", codingPath: decoder.codingPath)
            let yoloMode = obj["yolo_mode"]?.boolValue ?? false
            self = .turnStarted(turnNumber: turnNumber, modelId: modelId, yoloMode: yoloMode)
        case "turn_ended":
            let turnNumber = try Self.requireUInt64(obj, "turn_number", codingPath: decoder.codingPath)
            let durationMs = try Self.requireUInt64(obj, "duration_ms", codingPath: decoder.codingPath)
            let toolCallCount = try Self.requireUInt32(obj, "tool_call_count", codingPath: decoder.codingPath)
            let modelId = try Self.requireString(obj, "model_id", codingPath: decoder.codingPath)
            guard let outcomeVal = obj["outcome"] else {
                throw DecodingError.keyNotFound(
                    CodingKeys.outcome,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "missing outcome"
                    )
                )
            }
            let outcome = try outcomeVal.decode(TurnHookOutcome.self)
            self = .turnEnded(
                turnNumber: turnNumber,
                outcome: outcome,
                durationMs: durationMs,
                toolCallCount: toolCallCount,
                modelId: modelId
            )
        case "tool_call_started":
            self = .toolCallStarted(
                toolCallId: try Self.requireString(obj, "tool_call_id", codingPath: decoder.codingPath),
                toolName: try Self.requireString(obj, "tool_name", codingPath: decoder.codingPath),
                turnNumber: try Self.requireUInt64(obj, "turn_number", codingPath: decoder.codingPath)
            )
        case "tool_call_completed":
            guard let outcomeVal = obj["outcome"] else {
                throw DecodingError.keyNotFound(
                    CodingKeys.outcome,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "missing outcome"
                    )
                )
            }
            let outcome = try outcomeVal.decode(ToolCallOutcome.self)
            self = .toolCallCompleted(
                toolCallId: try Self.requireString(obj, "tool_call_id", codingPath: decoder.codingPath),
                toolName: try Self.requireString(obj, "tool_name", codingPath: decoder.codingPath),
                durationMs: try Self.requireUInt64(obj, "duration_ms", codingPath: decoder.codingPath),
                outcome: outcome
            )
        case "phase_changed":
            guard let phaseVal = obj["phase"] else {
                throw DecodingError.keyNotFound(
                    CodingKeys.phase,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "missing phase"
                    )
                )
            }
            let phase = try phaseVal.decode(SessionPhase.self)
            self = .phaseChanged(phase: phase)
        default:
            // Lossless: keep original event_type and the full object payload.
            self = .unknown(eventType: eventType, payload: full)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .turnStarted(let turnNumber, let modelId, let yoloMode):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("turn_started", forKey: .eventType)
            try c.encode(turnNumber, forKey: .turnNumber)
            try c.encode(modelId, forKey: .modelId)
            try c.encode(yoloMode, forKey: .yoloMode)
        case .turnEnded(let turnNumber, let outcome, let durationMs, let toolCallCount, let modelId):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("turn_ended", forKey: .eventType)
            try c.encode(turnNumber, forKey: .turnNumber)
            try c.encode(outcome, forKey: .outcome)
            try c.encode(durationMs, forKey: .durationMs)
            try c.encode(toolCallCount, forKey: .toolCallCount)
            try c.encode(modelId, forKey: .modelId)
        case .toolCallStarted(let toolCallId, let toolName, let turnNumber):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool_call_started", forKey: .eventType)
            try c.encode(toolCallId, forKey: .toolCallId)
            try c.encode(toolName, forKey: .toolName)
            try c.encode(turnNumber, forKey: .turnNumber)
        case .toolCallCompleted(let toolCallId, let toolName, let durationMs, let outcome):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool_call_completed", forKey: .eventType)
            try c.encode(toolCallId, forKey: .toolCallId)
            try c.encode(toolName, forKey: .toolName)
            try c.encode(durationMs, forKey: .durationMs)
            try c.encode(outcome, forKey: .outcome)
        case .phaseChanged(let phase):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("phase_changed", forKey: .eventType)
            try c.encode(phase, forKey: .phase)
        case .unknown(_, let payload):
            // Re-encode the original payload unchanged (lossless).
            try payload.encode(to: encoder)
        }
    }

    // MARK: - Decode helpers

    private static func requireString(
        _ obj: [String: JSONValue],
        _ key: String,
        codingPath: [CodingKey]
    ) throws -> String {
        guard case .string(let s) = obj[key] else {
            throw DecodingError.keyNotFound(
                AnyCodingKey(key),
                DecodingError.Context(codingPath: codingPath, debugDescription: "missing or invalid \(key)")
            )
        }
        return s
    }

    private static func requireUInt64(
        _ obj: [String: JSONValue],
        _ key: String,
        codingPath: [CodingKey]
    ) throws -> UInt64 {
        guard let v = obj[key], let n = v.uint64Value else {
            throw DecodingError.keyNotFound(
                AnyCodingKey(key),
                DecodingError.Context(codingPath: codingPath, debugDescription: "missing or invalid \(key)")
            )
        }
        return n
    }

    private static func requireUInt32(
        _ obj: [String: JSONValue],
        _ key: String,
        codingPath: [CodingKey]
    ) throws -> UInt32 {
        let n = try requireUInt64(obj, key, codingPath: codingPath)
        guard n <= UInt64(UInt32.max) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: "\(key) out of UInt32 range")
            )
        }
        return UInt32(n)
    }
}

/// Outcome of a completed tool call within a session event.
///
/// Unknown future values preserve their original raw string so re-encoding
/// is lossless for forward-compatible peers.
public enum ToolCallOutcome: Codable, Sendable, Hashable {
    case success
    case error
    case cancelled
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "success": self = .success
        case "error": self = .error
        case "cancelled": self = .cancelled
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .success: try c.encode("success")
        case .error: try c.encode("error")
        case .cancelled: try c.encode("cancelled")
        case .unknown(let raw): try c.encode(raw)
        }
    }
}

/// Current phase of the session lifecycle.
///
/// Unknown future values preserve their original raw string so re-encoding
/// is lossless for forward-compatible peers.
public enum SessionPhase: Codable, Sendable, Hashable {
    case idle
    case sampling
    case toolExecution
    case permissionPrompt
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "idle": self = .idle
        case "sampling": self = .sampling
        case "tool_execution": self = .toolExecution
        case "permission_prompt": self = .permissionPrompt
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .idle: try c.encode("idle")
        case .sampling: try c.encode("sampling")
        case .toolExecution: try c.encode("tool_execution")
        case .permissionPrompt: try c.encode("permission_prompt")
        case .unknown(let raw): try c.encode(raw)
        }
    }
}

// MARK: - Private helpers

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension JSONValue {
    var uint64Value: UInt64? {
        switch self {
        case .number(let n):
            return n.uint64Value
        case .string(let s):
            return UInt64(s)
        default:
            return nil
        }
    }
}
