// AcpClientSchema.swift
//
// Typed client-side ACP reverse requests and notifications (session updates,
// permission, filesystem, terminals).

import Foundation
import OpenGrokShared

// MARK: - Session updates

/// Notification containing a session update from the agent.
public struct SessionNotification: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var update: SessionUpdate
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, update: SessionUpdate, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.update = update
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, update
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        update = try container.decode(SessionUpdate.self, forKey: .update)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(update, forKey: .update)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension SessionNotification: AcpRequest {
    public typealias Response = EmptyAcpResponse
    public var methodName: String { ClientMethodNames.sessionUpdate }
}

/// Different types of updates that can be sent during session processing.
///
/// Wire form: tagged on `"sessionUpdate"` with snake_case variants.
public enum SessionUpdate: Hashable, Sendable, Codable {
    case userMessageChunk(ContentChunk)
    case agentMessageChunk(ContentChunk)
    case agentThoughtChunk(ContentChunk)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan(Plan)
    case availableCommandsUpdate(AvailableCommandsUpdate)
    case currentModeUpdate(CurrentModeUpdate)
    case configOptionUpdate(ConfigOptionUpdate)
    case sessionInfoUpdate(SessionInfoUpdate)
    /// Forward-compatible unknown session update variant.
    case unknown(type: String, payload: [String: JSONValue])

    private enum CodingKeys: String, CodingKey {
        case sessionUpdate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .sessionUpdate)
        switch type {
        case "user_message_chunk":
            self = .userMessageChunk(try ContentChunk(from: decoder))
        case "agent_message_chunk":
            self = .agentMessageChunk(try ContentChunk(from: decoder))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try ContentChunk(from: decoder))
        case "tool_call":
            self = .toolCall(try ToolCall(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ToolCallUpdate(from: decoder))
        case "plan":
            self = .plan(try Plan(from: decoder))
        case "available_commands_update":
            self = .availableCommandsUpdate(try AvailableCommandsUpdate(from: decoder))
        case "current_mode_update":
            self = .currentModeUpdate(try CurrentModeUpdate(from: decoder))
        case "config_option_update":
            self = .configOptionUpdate(try ConfigOptionUpdate(from: decoder))
        case "session_info_update":
            self = .sessionInfoUpdate(try SessionInfoUpdate(from: decoder))
        default:
            let payload = try JSONValue(from: decoder).objectValue ?? [:]
            self = .unknown(type: type, payload: payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .userMessageChunk(let value):
            try encodeSessionUpdate(type: "user_message_chunk", value, to: encoder)
        case .agentMessageChunk(let value):
            try encodeSessionUpdate(type: "agent_message_chunk", value, to: encoder)
        case .agentThoughtChunk(let value):
            try encodeSessionUpdate(type: "agent_thought_chunk", value, to: encoder)
        case .toolCall(let value):
            try encodeSessionUpdate(type: "tool_call", value, to: encoder)
        case .toolCallUpdate(let value):
            try encodeSessionUpdate(type: "tool_call_update", value, to: encoder)
        case .plan(let value):
            try encodeSessionUpdate(type: "plan", value, to: encoder)
        case .availableCommandsUpdate(let value):
            try encodeSessionUpdate(type: "available_commands_update", value, to: encoder)
        case .currentModeUpdate(let value):
            try encodeSessionUpdate(type: "current_mode_update", value, to: encoder)
        case .configOptionUpdate(let value):
            try encodeSessionUpdate(type: "config_option_update", value, to: encoder)
        case .sessionInfoUpdate(let value):
            try encodeSessionUpdate(type: "session_info_update", value, to: encoder)
        case .unknown(let type, var payload):
            payload["sessionUpdate"] = .string(type)
            try JSONValue.object(payload).encode(to: encoder)
        }
    }
}

private func encodeSessionUpdate<T: Encodable>(type: String, _ value: T, to encoder: Encoder) throws {
    let encoded = try JSONValue.encode(value)
    guard case .object(var object) = encoded else {
        throw EncodingError.invalidValue(
            value,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "SessionUpdate payload must encode as an object"
            )
        )
    }
    object["sessionUpdate"] = .string(type)
    try JSONValue.object(object).encode(to: encoder)
}

public struct ContentChunk: Hashable, Sendable, Codable {
    public var content: ContentBlock
    public var meta: AcpMeta?

    public init(content: ContentBlock, meta: AcpMeta? = nil) {
        self.content = content
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(ContentBlock.self, forKey: .content)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct CurrentModeUpdate: Hashable, Sendable, Codable {
    public var currentModeId: SessionModeId
    public var meta: AcpMeta?

    public init(currentModeId: SessionModeId, meta: AcpMeta? = nil) {
        self.currentModeId = currentModeId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case currentModeId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentModeId = try container.decode(SessionModeId.self, forKey: .currentModeId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentModeId, forKey: .currentModeId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct ConfigOptionUpdate: Hashable, Sendable, Codable {
    public var configOptions: [SessionConfigOption]
    public var meta: AcpMeta?

    public init(configOptions: [SessionConfigOption], meta: AcpMeta? = nil) {
        self.configOptions = configOptions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case configOptions
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configOptions = try container.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configOptions, forKey: .configOptions)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct SessionInfoUpdate: Hashable, Sendable, Codable {
    public var title: String?
    public var updatedAt: String?
    public var meta: AcpMeta?

    public init(title: String? = nil, updatedAt: String? = nil, meta: AcpMeta? = nil) {
        self.title = title
        self.updatedAt = updatedAt
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case title, updatedAt
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct AvailableCommandsUpdate: Hashable, Sendable, Codable {
    public var availableCommands: [AvailableCommand]
    public var meta: AcpMeta?

    public init(availableCommands: [AvailableCommand] = [], meta: AcpMeta? = nil) {
        self.availableCommands = availableCommands
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case availableCommands
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCommands = try container.decodeIfPresent([AvailableCommand].self, forKey: .availableCommands) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(availableCommands, forKey: .availableCommands)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct AvailableCommand: Hashable, Sendable, Codable {
    public var name: String
    public var description: String
    public var input: AvailableCommandInput?
    public var meta: AcpMeta?

    public init(
        name: String,
        description: String,
        input: AvailableCommandInput? = nil,
        meta: AcpMeta? = nil
    ) {
        self.name = name
        self.description = description
        self.input = input
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, input
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        input = try container.decodeIfPresent(AvailableCommandInput.self, forKey: .input)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(input, forKey: .input)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public enum AvailableCommandInput: Hashable, Sendable, Codable {
    case unstructured(hint: String)

    private enum CodingKeys: String, CodingKey {
        case hint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hint = try container.decodeIfPresent(String.self, forKey: .hint) ?? ""
        self = .unstructured(hint: hint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unstructured(let hint):
            try container.encode(hint, forKey: .hint)
        }
    }
}

/// Agent execution plan for complex tasks.
public struct Plan: Hashable, Sendable, Codable {
    public var entries: [PlanEntry]
    public var meta: AcpMeta?

    public init(entries: [PlanEntry] = [], meta: AcpMeta? = nil) {
        self.entries = entries
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([PlanEntry].self, forKey: .entries) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct PlanEntry: Hashable, Sendable, Codable {
    public var content: String
    public var priority: PlanEntryPriority
    public var status: PlanEntryStatus
    public var meta: AcpMeta?

    public init(
        content: String,
        priority: PlanEntryPriority = .medium,
        status: PlanEntryStatus = .pending,
        meta: AcpMeta? = nil
    ) {
        self.content = content
        self.priority = priority
        self.status = status
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case content, priority, status
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        priority = try container.decodeIfPresent(PlanEntryPriority.self, forKey: .priority) ?? .medium
        status = try container.decodeIfPresent(PlanEntryStatus.self, forKey: .status) ?? .pending
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encode(priority, forKey: .priority)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public enum PlanEntryPriority: String, Hashable, Sendable, Codable {
    case high
    case medium
    case low
}

public enum PlanEntryStatus: String, Hashable, Sendable, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
}

// MARK: - Permission

public struct RequestPermissionRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var toolCall: ToolCallUpdate
    public var options: [PermissionOption]
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        toolCall: ToolCallUpdate,
        options: [PermissionOption],
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, toolCall, options
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        toolCall = try container.decode(ToolCallUpdate.self, forKey: .toolCall)
        options = try container.decodeIfPresent([PermissionOption].self, forKey: .options) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(toolCall, forKey: .toolCall)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension RequestPermissionRequest: AcpRequest {
    public typealias Response = RequestPermissionResponse
    public var methodName: String { ClientMethodNames.sessionRequestPermission }
}

public struct PermissionOption: Hashable, Sendable, Codable {
    public var optionId: PermissionOptionId
    public var name: String
    public var kind: PermissionOptionKind
    public var meta: AcpMeta?

    public init(
        optionId: PermissionOptionId,
        name: String,
        kind: PermissionOptionKind,
        meta: AcpMeta? = nil
    ) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case optionId, name, kind
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try container.decode(PermissionOptionId.self, forKey: .optionId)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(PermissionOptionKind.self, forKey: .kind)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(optionId, forKey: .optionId)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public enum PermissionOptionKind: String, Hashable, Sendable, Codable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"
}

public struct RequestPermissionResponse: Hashable, Sendable, Codable {
    public var outcome: RequestPermissionOutcome
    public var meta: AcpMeta?

    public init(outcome: RequestPermissionOutcome, meta: AcpMeta? = nil) {
        self.outcome = outcome
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try container.decode(RequestPermissionOutcome.self, forKey: .outcome)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public enum RequestPermissionOutcome: Hashable, Sendable, Codable {
    case cancelled
    case selected(SelectedPermissionOutcome)

    private enum CodingKeys: String, CodingKey {
        case outcome
        case optionId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        switch outcome {
        case "cancelled":
            self = .cancelled
        case "selected":
            self = .selected(try SelectedPermissionOutcome(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Unknown RequestPermissionOutcome: \(outcome)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .cancelled:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("cancelled", forKey: .outcome)
        case .selected(let selected):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("selected", forKey: .outcome)
            try container.encode(selected.optionId, forKey: .optionId)
            try container.encodeIfPresent(selected.meta, forKey: .meta)
        }
    }
}

public struct SelectedPermissionOutcome: Hashable, Sendable, Codable {
    public var optionId: PermissionOptionId
    public var meta: AcpMeta?

    public init(optionId: PermissionOptionId, meta: AcpMeta? = nil) {
        self.optionId = optionId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case optionId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try container.decode(PermissionOptionId.self, forKey: .optionId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(optionId, forKey: .optionId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Filesystem

public struct WriteTextFileRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var path: String
    public var content: String
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, path: String, content: String, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.path = path
        self.content = content
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, path, content
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        path = try container.decode(String.self, forKey: .path)
        content = try container.decode(String.self, forKey: .content)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(path, forKey: .path)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension WriteTextFileRequest: AcpRequest {
    public typealias Response = WriteTextFileResponse
    public var methodName: String { ClientMethodNames.fsWriteTextFile }
}

public struct WriteTextFileResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct ReadTextFileRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var path: String
    public var line: UInt32?
    public var limit: UInt32?
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        path: String,
        line: UInt32? = nil,
        limit: UInt32? = nil,
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.path = path
        self.line = line
        self.limit = limit
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, path, line, limit
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        path = try container.decode(String.self, forKey: .path)
        line = try container.decodeIfPresent(UInt32.self, forKey: .line)
        limit = try container.decodeIfPresent(UInt32.self, forKey: .limit)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(line, forKey: .line)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension ReadTextFileRequest: AcpRequest {
    public typealias Response = ReadTextFileResponse
    public var methodName: String { ClientMethodNames.fsReadTextFile }
}

public struct ReadTextFileResponse: Hashable, Sendable, Codable {
    public var content: String
    public var meta: AcpMeta?

    public init(content: String, meta: AcpMeta? = nil) {
        self.content = content
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Terminals

public struct CreateTerminalRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var command: String
    public var args: [String]
    public var env: [EnvVariable]
    public var cwd: String?
    public var outputByteLimit: UInt64?
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        command: String,
        args: [String] = [],
        env: [EnvVariable] = [],
        cwd: String? = nil,
        outputByteLimit: UInt64? = nil,
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.outputByteLimit = outputByteLimit
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, command, args, env, cwd, outputByteLimit
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([EnvVariable].self, forKey: .env) ?? []
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        outputByteLimit = try container.decodeIfPresent(UInt64.self, forKey: .outputByteLimit)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(command, forKey: .command)
        if !args.isEmpty {
            try container.encode(args, forKey: .args)
        }
        if !env.isEmpty {
            try container.encode(env, forKey: .env)
        }
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(outputByteLimit, forKey: .outputByteLimit)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension CreateTerminalRequest: AcpRequest {
    public typealias Response = CreateTerminalResponse
    public var methodName: String { ClientMethodNames.terminalCreate }
}

public struct CreateTerminalResponse: Hashable, Sendable, Codable {
    public var terminalId: TerminalId
    public var meta: AcpMeta?

    public init(terminalId: TerminalId, meta: AcpMeta? = nil) {
        self.terminalId = terminalId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case terminalId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalId = try container.decode(TerminalId.self, forKey: .terminalId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(terminalId, forKey: .terminalId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct TerminalOutputRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var terminalId: TerminalId
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, terminalId: TerminalId, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.terminalId = terminalId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, terminalId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        terminalId = try container.decode(TerminalId.self, forKey: .terminalId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(terminalId, forKey: .terminalId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension TerminalOutputRequest: AcpRequest {
    public typealias Response = TerminalOutputResponse
    public var methodName: String { ClientMethodNames.terminalOutput }
}

public struct TerminalOutputResponse: Hashable, Sendable, Codable {
    public var output: String
    public var truncated: Bool
    public var exitStatus: TerminalExitStatus?
    public var meta: AcpMeta?

    public init(
        output: String,
        truncated: Bool = false,
        exitStatus: TerminalExitStatus? = nil,
        meta: AcpMeta? = nil
    ) {
        self.output = output
        self.truncated = truncated
        self.exitStatus = exitStatus
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case output, truncated, exitStatus
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        output = try container.decodeIfPresent(String.self, forKey: .output) ?? ""
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        exitStatus = try container.decodeIfPresent(TerminalExitStatus.self, forKey: .exitStatus)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(output, forKey: .output)
        try container.encode(truncated, forKey: .truncated)
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct ReleaseTerminalRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var terminalId: TerminalId
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, terminalId: TerminalId, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.terminalId = terminalId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, terminalId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        terminalId = try container.decode(TerminalId.self, forKey: .terminalId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(terminalId, forKey: .terminalId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension ReleaseTerminalRequest: AcpRequest {
    public typealias Response = ReleaseTerminalResponse
    public var methodName: String { ClientMethodNames.terminalRelease }
}

public struct ReleaseTerminalResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct WaitForTerminalExitRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var terminalId: TerminalId
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, terminalId: TerminalId, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.terminalId = terminalId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, terminalId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        terminalId = try container.decode(TerminalId.self, forKey: .terminalId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(terminalId, forKey: .terminalId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension WaitForTerminalExitRequest: AcpRequest {
    public typealias Response = WaitForTerminalExitResponse
    public var methodName: String { ClientMethodNames.terminalWaitForExit }
}

public struct WaitForTerminalExitResponse: Hashable, Sendable, Codable {
    public var exitStatus: TerminalExitStatus
    public var meta: AcpMeta?

    public init(exitStatus: TerminalExitStatus, meta: AcpMeta? = nil) {
        self.exitStatus = exitStatus
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case exitStatus
        case meta = "_meta"
        // Some schema versions flatten exitCode / signal.
        case exitCode, signal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let status = try container.decodeIfPresent(TerminalExitStatus.self, forKey: .exitStatus) {
            exitStatus = status
        } else {
            exitStatus = TerminalExitStatus(
                exitCode: try container.decodeIfPresent(Int32.self, forKey: .exitCode),
                signal: try container.decodeIfPresent(String.self, forKey: .signal)
            )
        }
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct KillTerminalRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var terminalId: TerminalId
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, terminalId: TerminalId, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.terminalId = terminalId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, terminalId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        terminalId = try container.decode(TerminalId.self, forKey: .terminalId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(terminalId, forKey: .terminalId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension KillTerminalRequest: AcpRequest {
    public typealias Response = KillTerminalResponse
    public var methodName: String { ClientMethodNames.terminalKill }
}

public struct KillTerminalResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct TerminalExitStatus: Hashable, Sendable, Codable {
    public var exitCode: Int32?
    public var signal: String?
    public var meta: AcpMeta?

    public init(exitCode: Int32? = nil, signal: String? = nil, meta: AcpMeta? = nil) {
        self.exitCode = exitCode
        self.signal = signal
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case exitCode, signal
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        signal = try container.decodeIfPresent(String.self, forKey: .signal)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(signal, forKey: .signal)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}
