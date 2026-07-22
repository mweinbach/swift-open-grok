// TurnHook.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/turn_hook.rs`.
//
// Turn lifecycle hook payload types for `HookEvent.custom`.

import Foundation
import OpenGrokShared

/// Well-known `HookEvent.custom` kind string for before-turn hooks.
public let beforeTurnKind = "before_turn"

/// Well-known `HookEvent.custom` kind string for after-turn hooks.
public let afterTurnKind = "after_turn"

/// Default `session_relationship` wire value.
public let defaultSessionRelationship = "primary"

/// Default `schema_version` wire value.
public let defaultSchemaVersion = "1.0"

/// `HookEvent.custom` kind for the request/response turn hook.
public let turnHookKind = "turn_hook"

/// Payload for `before_turn` custom hooks.
public struct BeforeTurnPayload: Codable, Sendable, Hashable {
    public var turnNumber: UInt64
    public var modelId: String
    public var yoloMode: Bool
    public var conversationMessageCount: Int
    public var sessionRelationship: String
    public var schemaVersion: String

    private enum CodingKeys: String, CodingKey {
        case turnNumber = "turn_number"
        case modelId = "model_id"
        case yoloMode = "yolo_mode"
        case conversationMessageCount = "conversation_message_count"
        case sessionRelationship = "session_relationship"
        case schemaVersion = "schema_version"
    }

    public init(
        turnNumber: UInt64 = 0,
        modelId: String = "",
        yoloMode: Bool = false,
        conversationMessageCount: Int = 0,
        sessionRelationship: String = defaultSessionRelationship,
        schemaVersion: String = defaultSchemaVersion
    ) {
        self.turnNumber = turnNumber
        self.modelId = modelId
        self.yoloMode = yoloMode
        self.conversationMessageCount = conversationMessageCount
        self.sessionRelationship = sessionRelationship
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.turnNumber = try c.decode(UInt64.self, forKey: .turnNumber)
        self.modelId = try c.decode(String.self, forKey: .modelId)
        self.yoloMode = try c.decodeIfPresent(Bool.self, forKey: .yoloMode) ?? false
        self.conversationMessageCount = try c.decodeIfPresent(Int.self, forKey: .conversationMessageCount) ?? 0
        self.sessionRelationship = try c.decodeIfPresent(String.self, forKey: .sessionRelationship)
            ?? defaultSessionRelationship
        self.schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion)
            ?? defaultSchemaVersion
    }
}

/// Payload for `after_turn` custom hooks.
public struct AfterTurnPayload: Codable, Sendable, Hashable {
    public var turnNumber: UInt64
    public var outcome: TurnHookOutcome
    public var durationMs: UInt64
    public var toolCallCount: UInt32
    public var modelId: String
    public var writtenRepoPaths: [String]
    public var cancellationCategory: String?
    public var cancellationContext: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case turnNumber = "turn_number"
        case outcome
        case durationMs = "duration_ms"
        case toolCallCount = "tool_call_count"
        case modelId = "model_id"
        case writtenRepoPaths = "written_repo_paths"
        case cancellationCategory = "cancellation_category"
        case cancellationContext = "cancellation_context"
    }

    public init(
        turnNumber: UInt64,
        outcome: TurnHookOutcome,
        durationMs: UInt64,
        toolCallCount: UInt32,
        modelId: String,
        writtenRepoPaths: [String] = [],
        cancellationCategory: String? = nil,
        cancellationContext: JSONValue? = nil
    ) {
        self.turnNumber = turnNumber
        self.outcome = outcome
        self.durationMs = durationMs
        self.toolCallCount = toolCallCount
        self.modelId = modelId
        self.writtenRepoPaths = writtenRepoPaths
        self.cancellationCategory = cancellationCategory
        self.cancellationContext = cancellationContext
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.turnNumber = try c.decode(UInt64.self, forKey: .turnNumber)
        self.outcome = try c.decode(TurnHookOutcome.self, forKey: .outcome)
        self.durationMs = try c.decode(UInt64.self, forKey: .durationMs)
        self.toolCallCount = try c.decode(UInt32.self, forKey: .toolCallCount)
        self.modelId = try c.decode(String.self, forKey: .modelId)
        self.writtenRepoPaths = try c.decodeIfPresent([String].self, forKey: .writtenRepoPaths) ?? []
        self.cancellationCategory = try c.decodeIfPresent(String.self, forKey: .cancellationCategory)
        self.cancellationContext = try c.decodeIfPresent(JSONValue.self, forKey: .cancellationContext)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(turnNumber, forKey: .turnNumber)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(toolCallCount, forKey: .toolCallCount)
        try c.encode(modelId, forKey: .modelId)
        if !writtenRepoPaths.isEmpty {
            try c.encode(writtenRepoPaths, forKey: .writtenRepoPaths)
        }
        try c.encodeIfPresent(cancellationCategory, forKey: .cancellationCategory)
        try c.encodeIfPresent(cancellationContext, forKey: .cancellationContext)
    }
}

/// Turn outcome as observed by the sampler.
public enum TurnHookOutcome: String, Codable, Sendable, Hashable {
    case completed
    case cancelled
    case error
}

/// Request/response turn hook (sampler → bound workspace), internally
/// tagged on `phase`.
public enum TurnHookRequest: Codable, Sendable, Hashable {
    case before(BeforeTurnPayload)
    case after(AfterTurnPayload)

    private enum PhaseKey: String, CodingKey { case phase }

    public init(from decoder: Decoder) throws {
        let phaseC = try decoder.container(keyedBy: PhaseKey.self)
        let phase = try phaseC.decode(String.self, forKey: .phase)
        switch phase {
        case "before":
            self = .before(try BeforeTurnPayload(from: decoder))
        case "after":
            self = .after(try AfterTurnPayload(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .phase, in: phaseC,
                debugDescription: "unknown TurnHookRequest phase: \(phase)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Encode payload first, then overlay `phase` into the same object
        // via a single JSONValue merge (adjacent-tag style).
        let payloadValue: JSONValue
        let phase: String
        switch self {
        case .before(let payload):
            payloadValue = try JSONValue.encode(payload)
            phase = "before"
        case .after(let payload):
            payloadValue = try JSONValue.encode(payload)
            phase = "after"
        }
        guard case .object(var obj) = payloadValue else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "turn hook payload must be object")
            )
        }
        obj["phase"] = .string(phase)
        try JSONValue.object(obj).encode(to: encoder)
    }
}

/// Conversation role for a turn the workspace asks the sampler to append.
public enum InjectionRole: String, Codable, Sendable, Hashable {
    case system
    case developer
    case user
}

/// A single turn the workspace asks the sampler to append.
public struct HookInjection: Codable, Sendable, Hashable {
    public var role: InjectionRole
    public var content: String

    public init(role: InjectionRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// Override of the sampler's loop decision at a turn boundary.
public enum TurnControl: String, Codable, Sendable, Hashable, Defaultable {
    case auto
    case forceContinue = "force_continue"
    case forceStop = "force_stop"

    public static var defaultValue: TurnControl { .auto }
}

/// Reply to a `TurnHookRequest`.
public struct HookReply: Codable, Sendable, Hashable {
    public var injections: [HookInjection]
    public var control: TurnControl
    public var afterTurnAck: AfterTurnAckPayload?

    private enum CodingKeys: String, CodingKey {
        case injections
        case control
        case afterTurnAck = "after_turn_ack"
    }

    public init(
        injections: [HookInjection] = [],
        control: TurnControl = .auto,
        afterTurnAck: AfterTurnAckPayload? = nil
    ) {
        self.injections = injections
        self.control = control
        self.afterTurnAck = afterTurnAck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.injections = try c.decodeIfPresent([HookInjection].self, forKey: .injections) ?? []
        self.control = try c.decodeIfPresent(TurnControl.self, forKey: .control) ?? .auto
        self.afterTurnAck = try c.decodeIfPresent(AfterTurnAckPayload.self, forKey: .afterTurnAck)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !injections.isEmpty {
            try c.encode(injections, forKey: .injections)
        }
        if control != .auto {
            try c.encode(control, forKey: .control)
        }
        try c.encodeIfPresent(afterTurnAck, forKey: .afterTurnAck)
    }
}

/// Terminal status of the workspace's per-turn artifact handling.
public enum AfterTurnAckStatus: String, Codable, Sendable, Hashable {
    case enqueued
    case failed
    case skipped
}

/// Artifact-handling ack the workspace returns for a `TurnHookRequest.after`.
public struct AfterTurnAckPayload: Codable, Sendable, Hashable {
    public var turnNumber: UInt64
    public var status: AfterTurnAckStatus
    public var errorMessage: String?
    public var artifactCount: UInt32

    private enum CodingKeys: String, CodingKey {
        case turnNumber = "turn_number"
        case status
        case errorMessage = "error_message"
        case artifactCount = "artifact_count"
    }

    public init(
        turnNumber: UInt64,
        status: AfterTurnAckStatus,
        errorMessage: String? = nil,
        artifactCount: UInt32 = 0
    ) {
        self.turnNumber = turnNumber
        self.status = status
        self.errorMessage = errorMessage
        self.artifactCount = artifactCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.turnNumber = try c.decode(UInt64.self, forKey: .turnNumber)
        self.status = try c.decode(AfterTurnAckStatus.self, forKey: .status)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        self.artifactCount = try c.decodeIfPresent(UInt32.self, forKey: .artifactCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(turnNumber, forKey: .turnNumber)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        if artifactCount != 0 {
            try c.encode(artifactCount, forKey: .artifactCount)
        }
    }
}
