// NotificationWire.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/notification_wire.rs`.
//
// Adjacent-tagged notification wire wrapper with a forward-compat Custom shape.

import Foundation
import OpenGrokShared

/// Adjacent-tagged notification wire wrapper.
///
/// Wire shape:
/// ```jsonc
/// { "shape": "known",  "value": { "type": "BashOutputChunk", ... } }
/// { "shape": "custom", "value": { "kind": "my_tool.progress", "payload": ... } }
/// ```
public enum WireToolNotification: Codable, Sendable, Hashable {
    case known(JSONValue)
    case custom(WireCustomNotification)

    private enum CodingKeys: String, CodingKey {
        case shape
        case value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let shape = try c.decode(String.self, forKey: .shape)
        switch shape {
        case "known":
            self = .known(try c.decode(JSONValue.self, forKey: .value))
        case "custom":
            self = .custom(try c.decode(WireCustomNotification.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .shape, in: c,
                debugDescription: "unknown WireToolNotification shape: \(shape)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .known(let value):
            try c.encode("known", forKey: .shape)
            try c.encode(value, forKey: .value)
        case .custom(let custom):
            try c.encode("custom", forKey: .shape)
            try c.encode(custom, forKey: .value)
        }
    }
}

/// Free-form notification payload for kinds the computer hub does not
/// recognise. The `kind` MUST NOT collide with a known PascalCase variant.
public struct WireCustomNotification: Codable, Sendable, Hashable {
    public var kind: String
    public var payload: JSONValue

    public init(kind: String, payload: JSONValue) {
        self.kind = kind
        self.payload = payload
    }
}

/// Error when a custom notification kind collides with a known variant.
public struct KnownVariantCollision: Error, Sendable, Hashable, CustomStringConvertible {
    public var kind: String

    public init(kind: String) {
        self.kind = kind
    }

    public var description: String {
        "custom notification kind \(kind.debugDescription) collides with a known variant"
    }
}

/// PascalCase variant names of known notification types.
///
/// Source of truth lives upstream; keep this list in sync with
/// `xai-tool-runtime` notification variants.
public let knownNotificationKinds: [String] = [
    "BashOutputChunk",
    "BashExecutionComplete",
    "BashExecutionTimeout",
    "BashExecutionBackgrounded",
    "BashExecutionFailed",
    "FileWritten",
    "TaskCompleted",
    "PlanModeEntered",
    "PlanModeExited",
    "UserQuestionAsked",
    "LspServerStarting",
    "LspServerReady",
    "LspServerCrashed",
    "LspServerRetrying",
    "LspServerFailed",
    "ScheduledTaskFired",
    "ScheduledTaskRemoved",
    "ScheduledTaskCreated",
    "MonitorEvent",
]

/// Reject custom notification kinds whose name shadows a known PascalCase
/// variant. Runs at notification-emit time.
public func checkCustomKind(_ kind: String) -> Result<Void, KnownVariantCollision> {
    if knownNotificationKinds.contains(kind) {
        return .failure(KnownVariantCollision(kind: kind))
    }
    return .success(())
}
