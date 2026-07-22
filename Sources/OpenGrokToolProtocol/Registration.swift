// Registration.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/registration.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolTypes

/// Whether a registered tool runs in-process or behind a remote connection.
public enum TransportKind: String, Codable, Sendable, Hashable {
    case local
    case remote
}

/// A single tool's wire description plus optional schema and capability
/// metadata. The `tool_id` is **not** stored explicitly — it is derived
/// from `description.{namespace, name}` via `deriveToolId()`.
public struct ToolDescriptionWithSchema: Codable, Sendable, Hashable {
    public var description: ToolDescription
    public var inputSchema: JSONValue?
    public var capabilities: ToolCapabilities?
    public var notificationSchemas: NotificationSchemas?

    private enum CodingKeys: String, CodingKey {
        case description
        case inputSchema = "input_schema"
        case capabilities
        case notificationSchemas = "notification_schemas"
    }

    public init(
        description: ToolDescription,
        inputSchema: JSONValue? = nil,
        capabilities: ToolCapabilities? = nil,
        notificationSchemas: NotificationSchemas? = nil
    ) {
        self.description = description
        self.inputSchema = inputSchema
        self.capabilities = capabilities
        self.notificationSchemas = notificationSchemas
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(inputSchema, forKey: .inputSchema)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
        try c.encodeIfPresent(notificationSchemas, forKey: .notificationSchemas)
    }

    /// Derive the canonical `ToolId`.
    ///
    /// Namespaced descriptions render as `"{namespace}:{name}"`; otherwise
    /// the bare `name`.
    public func deriveToolId() throws -> ToolId {
        if let ns = description.namespace {
            return try ToolId("\(ns):\(description.name)")
        }
        return try ToolId(description.name)
    }
}

/// Single-tool registration. Wire-level sugar for a one-tool `register_server`.
///
/// `sessions` carries three-state semantics:
/// - `nil` (field omitted) — "no change"
/// - `Some([])` (explicit empty array) — "unbind every session"
/// - `Some([s1, ...])` — replace with exactly the listed ids
public struct ToolRegistration: Codable, Sendable, Hashable {
    public var toolId: ToolId
    public var sessions: [SessionId]?
    public var userId: UserId
    public var serverId: ServerId?
    public var description: ToolDescription
    public var inputSchema: JSONValue?
    public var capabilities: ToolCapabilities?
    public var notificationSchemas: NotificationSchemas?
    public var transportKind: TransportKind
    public var ifMatchGeneration: UInt64?
    public var metadata: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case toolId = "tool_id"
        case sessions
        case userId = "user_id"
        case serverId = "server_id"
        case description
        case inputSchema = "input_schema"
        case capabilities
        case notificationSchemas = "notification_schemas"
        case transportKind = "transport_kind"
        case ifMatchGeneration = "if_match_generation"
        case metadata
    }

    public init(
        toolId: ToolId,
        sessions: [SessionId]? = nil,
        userId: UserId,
        serverId: ServerId? = nil,
        description: ToolDescription,
        inputSchema: JSONValue? = nil,
        capabilities: ToolCapabilities? = nil,
        notificationSchemas: NotificationSchemas? = nil,
        transportKind: TransportKind,
        ifMatchGeneration: UInt64? = nil,
        metadata: JSONValue? = nil
    ) {
        self.toolId = toolId
        self.sessions = sessions
        self.userId = userId
        self.serverId = serverId
        self.description = description
        self.inputSchema = inputSchema
        self.capabilities = capabilities
        self.notificationSchemas = notificationSchemas
        self.transportKind = transportKind
        self.ifMatchGeneration = ifMatchGeneration
        self.metadata = metadata
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolId, forKey: .toolId)
        try c.encodeIfPresent(sessions, forKey: .sessions)
        try c.encode(userId, forKey: .userId)
        try c.encodeIfPresent(serverId, forKey: .serverId)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(inputSchema, forKey: .inputSchema)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
        try c.encodeIfPresent(notificationSchemas, forKey: .notificationSchemas)
        try c.encode(transportKind, forKey: .transportKind)
        try c.encodeIfPresent(ifMatchGeneration, forKey: .ifMatchGeneration)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }

    /// Derive the canonical `ToolId` from `description.{namespace, name}`.
    public func deriveToolId() throws -> ToolId {
        if let ns = description.namespace {
            return try ToolId("\(ns):\(description.name)")
        }
        return try ToolId(description.name)
    }
}

/// Multi-tool registration. The whole batch shares one `server_id` and one
/// `sessions` value.
public struct ToolServerRegistration: Codable, Sendable, Hashable {
    public var serverId: ServerId
    public var sessions: [SessionId]?
    public var userId: UserId
    public var title: String?
    public var description: String
    public var tools: [ToolDescriptionWithSchema]
    public var hooks: [HookKind]
    public var ifMatchGeneration: UInt64?
    public var metadata: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case sessions
        case userId = "user_id"
        case title
        case description
        case tools
        case hooks
        case ifMatchGeneration = "if_match_generation"
        case metadata
    }

    public init(
        serverId: ServerId,
        sessions: [SessionId]? = nil,
        userId: UserId,
        title: String? = nil,
        description: String = "",
        tools: [ToolDescriptionWithSchema],
        hooks: [HookKind] = [],
        ifMatchGeneration: UInt64? = nil,
        metadata: JSONValue? = nil
    ) {
        self.serverId = serverId
        self.sessions = sessions
        self.userId = userId
        self.title = title
        self.description = description
        self.tools = tools
        self.hooks = hooks
        self.ifMatchGeneration = ifMatchGeneration
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.serverId = try c.decode(ServerId.self, forKey: .serverId)
        self.sessions = try c.decodeIfPresent([SessionId].self, forKey: .sessions)
        self.userId = try c.decode(UserId.self, forKey: .userId)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.tools = try c.decode([ToolDescriptionWithSchema].self, forKey: .tools)
        self.hooks = try c.decodeIfPresent([HookKind].self, forKey: .hooks) ?? []
        self.ifMatchGeneration = try c.decodeIfPresent(UInt64.self, forKey: .ifMatchGeneration)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(serverId, forKey: .serverId)
        try c.encodeIfPresent(sessions, forKey: .sessions)
        try c.encode(userId, forKey: .userId)
        try c.encodeIfPresent(title, forKey: .title)
        if !description.isEmpty {
            try c.encode(description, forKey: .description)
        }
        try c.encode(tools, forKey: .tools)
        if !hooks.isEmpty {
            try c.encode(hooks, forKey: .hooks)
        }
        try c.encodeIfPresent(ifMatchGeneration, forKey: .ifMatchGeneration)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// Per-tool result from a `register_tool` or `register_server` call.
public enum RegistrationOutcome: Codable, Sendable, Hashable {
    case registered(toolId: ToolId, generation: UInt64)
    case updated(toolId: ToolId, generation: UInt64)
    case shadowed(toolId: ToolId, reason: String)
    case rejected(toolId: ToolId, code: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case outcome
        case toolId = "tool_id"
        case generation
        case reason
        case code
        case message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try c.decode(String.self, forKey: .outcome)
        switch outcome {
        case "registered":
            self = .registered(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                generation: try c.decode(UInt64.self, forKey: .generation)
            )
        case "updated":
            self = .updated(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                generation: try c.decode(UInt64.self, forKey: .generation)
            )
        case "shadowed":
            self = .shadowed(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                reason: try c.decode(String.self, forKey: .reason)
            )
        case "rejected":
            self = .rejected(
                toolId: try c.decode(ToolId.self, forKey: .toolId),
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .outcome, in: c,
                debugDescription: "unknown RegistrationOutcome: \(outcome)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .registered(let toolId, let generation):
            try c.encode("registered", forKey: .outcome)
            try c.encode(toolId, forKey: .toolId)
            try c.encode(generation, forKey: .generation)
        case .updated(let toolId, let generation):
            try c.encode("updated", forKey: .outcome)
            try c.encode(toolId, forKey: .toolId)
            try c.encode(generation, forKey: .generation)
        case .shadowed(let toolId, let reason):
            try c.encode("shadowed", forKey: .outcome)
            try c.encode(toolId, forKey: .toolId)
            try c.encode(reason, forKey: .reason)
        case .rejected(let toolId, let code, let message):
            try c.encode("rejected", forKey: .outcome)
            try c.encode(toolId, forKey: .toolId)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }
}
