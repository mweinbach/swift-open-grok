// Hook.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/hook.rs`.

import Foundation
import OpenGrokShared

/// Internally-tagged hook payload. New variants land alongside `Custom`,
/// which keeps unknown future kinds round-trippable.
///
/// Wire form uses `"type"` as the discriminator (PascalCase variants).
public enum HookEvent: Codable, Sendable, Hashable {
    /// Cancel an in-flight call. The owning `tool_call_id` travels in the
    /// enclosing `hook` frame.
    case cancel
    case pause
    case resume
    /// Broadcast to every tool server bound to the session.
    case sessionEnded
    /// Forward-compatible escape hatch.
    case custom(kind: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type
        case kind
        case payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "Cancel":
            self = .cancel
        case "Pause":
            self = .pause
        case "Resume":
            self = .resume
        case "SessionEnded":
            self = .sessionEnded
        case "Custom":
            self = .custom(
                kind: try c.decode(String.self, forKey: .kind),
                payload: try c.decode(JSONValue.self, forKey: .payload)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown HookEvent type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cancel:
            try c.encode("Cancel", forKey: .type)
        case .pause:
            try c.encode("Pause", forKey: .type)
        case .resume:
            try c.encode("Resume", forKey: .type)
        case .sessionEnded:
            try c.encode("SessionEnded", forKey: .type)
        case .custom(let kind, let payload):
            try c.encode("Custom", forKey: .type)
            try c.encode(kind, forKey: .kind)
            try c.encode(payload, forKey: .payload)
        }
    }
}
