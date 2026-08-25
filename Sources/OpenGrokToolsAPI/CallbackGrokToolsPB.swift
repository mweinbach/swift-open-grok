// CallbackGrokToolsPB.swift
//
// Client callback wire contract from pinned Rust revision 00e176c8:
// crates/codegen/xai-grok-tools-api/proto/grok-tools.proto:178-195,325-415.

import Foundation

extension GrokToolsV1 {
    /// Finalize-time callback connectivity and the surfaces actually activated.
    public struct CallbackStatus: ProtobufMessage, Codable, Sendable, Hashable {
        public var connected: Bool
        public var activeSurfaces: [String]
        public var message: String?

        public init(
            connected: Bool = false,
            activeSurfaces: [String] = [],
            message: String? = nil
        ) {
            self.connected = connected
            self.activeSurfaces = activeSurfaces
            self.message = message
        }

        public func protobufData() -> Data {
            var writer = ProtoWriter()
            writer.writeBool(1, connected)
            for surface in activeSurfaces {
                writer.writeStringPresence(2, surface, has: true)
            }
            if let message {
                writer.writeStringPresence(3, message, has: true)
            }
            return writer.data
        }

        public mutating func merge(from wire: Data) throws {
            var reader = ProtoReader(wire)
            while let (field, wireType) = try reader.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    connected = try reader.readBool()
                case 2:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    activeSurfaces.append(try reader.readString())
                case 3:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    message = try reader.readString()
                default:
                    try reader.skip(wireType: wireType)
                }
            }
        }

        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }

        public enum FieldNumber {
            public static let connected: UInt32 = 1
            public static let activeSurfaces: UInt32 = 2
            public static let message: UInt32 = 3
        }

        private enum CodingKeys: String, CodingKey {
            case connected
            case activeSurfaces = "active_surfaces"
            case message
        }
    }

    /// A serde-tagged tool notification correlated to its originating session.
    public struct ToolNotificationMsg: ProtobufMessage, Codable, Sendable, Hashable {
        public var sessionId: String
        public var notificationJson: String
        public var sequence: UInt64

        public init(
            sessionId: String = "",
            notificationJson: String = "",
            sequence: UInt64 = 0
        ) {
            self.sessionId = sessionId
            self.notificationJson = notificationJson
            self.sequence = sequence
        }

        public func protobufData() -> Data {
            var writer = ProtoWriter()
            writer.writeString(1, sessionId)
            writer.writeString(2, notificationJson)
            writer.writeUInt64(3, sequence)
            return writer.data
        }

        public mutating func merge(from wire: Data) throws {
            var reader = ProtoReader(wire)
            while let (field, wireType) = try reader.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    sessionId = try reader.readString()
                case 2:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    notificationJson = try reader.readString()
                case 3:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    sequence = try reader.readUInt64()
                default:
                    try reader.skip(wireType: wireType)
                }
            }
        }

        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }

        public enum FieldNumber {
            public static let sessionId: UInt32 = 1
            public static let notificationJson: UInt32 = 2
            public static let sequence: UInt32 = 3
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case notificationJson = "notification_json"
            case sequence
        }
    }

    /// Empty unary acknowledgment; unknown future fields remain forward-compatible.
    public struct NotificationAck: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}

        public func protobufData() -> Data {
            Data()
        }

        public mutating func merge(from wire: Data) throws {
            var reader = ProtoReader(wire)
            while let (_, wireType) = try reader.readTag() {
                try reader.skip(wireType: wireType)
            }
        }

        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }

        public enum FieldNumber {}
    }

    /// A fully resolved child execution; lifecycle ownership remains server-side.
    public struct SpawnSubagentRequest: ProtobufMessage, Codable, Sendable, Hashable {
        public var id: String
        public var prompt: String
        public var description: String
        public var subagentType: String
        public var parentSessionId: String
        public var parentPromptId: String?
        public var resumeFrom: String?
        public var cwd: String?
        public var systemPrompt: String?
        public var toolNames: [String]
        public var initialUserMessage: String?

        public init(
            id: String = "",
            prompt: String = "",
            description: String = "",
            subagentType: String = "",
            parentSessionId: String = "",
            parentPromptId: String? = nil,
            resumeFrom: String? = nil,
            cwd: String? = nil,
            systemPrompt: String? = nil,
            toolNames: [String] = [],
            initialUserMessage: String? = nil
        ) {
            self.id = id
            self.prompt = prompt
            self.description = description
            self.subagentType = subagentType
            self.parentSessionId = parentSessionId
            self.parentPromptId = parentPromptId
            self.resumeFrom = resumeFrom
            self.cwd = cwd
            self.systemPrompt = systemPrompt
            self.toolNames = toolNames
            self.initialUserMessage = initialUserMessage
        }

        public func protobufData() -> Data {
            var writer = ProtoWriter()
            writer.writeString(1, id)
            writer.writeString(2, prompt)
            writer.writeString(3, description)
            writer.writeString(4, subagentType)
            writer.writeString(5, parentSessionId)
            if let parentPromptId {
                writer.writeStringPresence(6, parentPromptId, has: true)
            }
            if let resumeFrom {
                writer.writeStringPresence(7, resumeFrom, has: true)
            }
            if let cwd {
                writer.writeStringPresence(8, cwd, has: true)
            }
            if let systemPrompt {
                writer.writeStringPresence(14, systemPrompt, has: true)
            }
            for name in toolNames {
                writer.writeStringPresence(15, name, has: true)
            }
            if let initialUserMessage {
                writer.writeStringPresence(16, initialUserMessage, has: true)
            }
            return writer.data
        }

        public mutating func merge(from wire: Data) throws {
            var reader = ProtoReader(wire)
            while let (field, wireType) = try reader.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    id = try reader.readString()
                case 2:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    prompt = try reader.readString()
                case 3:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    description = try reader.readString()
                case 4:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    subagentType = try reader.readString()
                case 5:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    parentSessionId = try reader.readString()
                case 6:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    parentPromptId = try reader.readString()
                case 7:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    resumeFrom = try reader.readString()
                case 8:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    cwd = try reader.readString()
                case 14:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    systemPrompt = try reader.readString()
                case 15:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    toolNames.append(try reader.readString())
                case 16:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    initialUserMessage = try reader.readString()
                default:
                    try reader.skip(wireType: wireType)
                }
            }
        }

        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }

        public enum FieldNumber {
            public static let id: UInt32 = 1
            public static let prompt: UInt32 = 2
            public static let description: UInt32 = 3
            public static let subagentType: UInt32 = 4
            public static let parentSessionId: UInt32 = 5
            public static let parentPromptId: UInt32 = 6
            public static let resumeFrom: UInt32 = 7
            public static let cwd: UInt32 = 8
            public static let systemPrompt: UInt32 = 14
            public static let toolNames: UInt32 = 15
            public static let initialUserMessage: UInt32 = 16
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case prompt
            case description
            case subagentType = "subagent_type"
            case parentSessionId = "parent_session_id"
            case parentPromptId = "parent_prompt_id"
            case resumeFrom = "resume_from"
            case cwd
            case systemPrompt = "system_prompt"
            case toolNames = "tool_names"
            case initialUserMessage = "initial_user_message"
        }
    }

    /// Completed child output and its optional, presence-sensitive token counts.
    public struct SubagentResultMsg: ProtobufMessage, Codable, Sendable, Hashable {
        public var success: Bool
        public var output: String
        public var error: String?
        public var cancelled: Bool
        public var subagentId: String
        public var childSessionId: String
        public var toolCalls: UInt32
        public var turns: UInt32
        public var durationMs: UInt64
        public var tokensUsed: UInt64
        public var worktreePath: String?
        public var backgrounded: Bool
        public var outputTokensUsed: UInt64?
        public var totalTokensUsed: UInt64?

        public init(
            success: Bool = false,
            output: String = "",
            error: String? = nil,
            cancelled: Bool = false,
            subagentId: String = "",
            childSessionId: String = "",
            toolCalls: UInt32 = 0,
            turns: UInt32 = 0,
            durationMs: UInt64 = 0,
            tokensUsed: UInt64 = 0,
            worktreePath: String? = nil,
            backgrounded: Bool = false,
            outputTokensUsed: UInt64? = nil,
            totalTokensUsed: UInt64? = nil
        ) {
            self.success = success
            self.output = output
            self.error = error
            self.cancelled = cancelled
            self.subagentId = subagentId
            self.childSessionId = childSessionId
            self.toolCalls = toolCalls
            self.turns = turns
            self.durationMs = durationMs
            self.tokensUsed = tokensUsed
            self.worktreePath = worktreePath
            self.backgrounded = backgrounded
            self.outputTokensUsed = outputTokensUsed
            self.totalTokensUsed = totalTokensUsed
        }

        public func protobufData() -> Data {
            var writer = ProtoWriter()
            writer.writeBool(1, success)
            writer.writeString(2, output)
            if let error {
                writer.writeStringPresence(3, error, has: true)
            }
            writer.writeBool(4, cancelled)
            writer.writeString(5, subagentId)
            writer.writeString(6, childSessionId)
            writer.writeUInt32(7, toolCalls)
            writer.writeUInt32(8, turns)
            writer.writeUInt64(9, durationMs)
            writer.writeUInt64(10, tokensUsed)
            if let worktreePath {
                writer.writeStringPresence(11, worktreePath, has: true)
            }
            writer.writeBool(12, backgrounded)
            if let outputTokensUsed {
                writer.writeUInt64Presence(13, outputTokensUsed, has: true)
            }
            if let totalTokensUsed {
                writer.writeUInt64Presence(14, totalTokensUsed, has: true)
            }
            return writer.data
        }

        public mutating func merge(from wire: Data) throws {
            var reader = ProtoReader(wire)
            while let (field, wireType) = try reader.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    success = try reader.readBool()
                case 2:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    output = try reader.readString()
                case 3:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    error = try reader.readString()
                case 4:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    cancelled = try reader.readBool()
                case 5:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    subagentId = try reader.readString()
                case 6:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    childSessionId = try reader.readString()
                case 7:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    toolCalls = try reader.readUInt32()
                case 8:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    turns = try reader.readUInt32()
                case 9:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    durationMs = try reader.readUInt64()
                case 10:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    tokensUsed = try reader.readUInt64()
                case 11:
                    guard wireType == 2 else { try reader.skip(wireType: wireType); continue }
                    worktreePath = try reader.readString()
                case 12:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    backgrounded = try reader.readBool()
                case 13:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    outputTokensUsed = try reader.readUInt64()
                case 14:
                    guard wireType == 0 else { try reader.skip(wireType: wireType); continue }
                    totalTokensUsed = try reader.readUInt64()
                default:
                    try reader.skip(wireType: wireType)
                }
            }
        }

        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }

        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let output: UInt32 = 2
            public static let error: UInt32 = 3
            public static let cancelled: UInt32 = 4
            public static let subagentId: UInt32 = 5
            public static let childSessionId: UInt32 = 6
            public static let toolCalls: UInt32 = 7
            public static let turns: UInt32 = 8
            public static let durationMs: UInt32 = 9
            public static let tokensUsed: UInt32 = 10
            public static let worktreePath: UInt32 = 11
            public static let backgrounded: UInt32 = 12
            public static let outputTokensUsed: UInt32 = 13
            public static let totalTokensUsed: UInt32 = 14
        }

        private enum CodingKeys: String, CodingKey {
            case success
            case output
            case error
            case cancelled
            case subagentId = "subagent_id"
            case childSessionId = "child_session_id"
            case toolCalls = "tool_calls"
            case turns
            case durationMs = "duration_ms"
            case tokensUsed = "tokens_used"
            case worktreePath = "worktree_path"
            case backgrounded
            case outputTokensUsed = "output_tokens_used"
            case totalTokensUsed = "total_tokens_used"
        }
    }

    /// Unary callback contract only; this target does not host a gRPC server.
    public protocol GrokToolsCallbackService: Sendable {
        func sendNotification(_ request: ToolNotificationMsg) async throws -> NotificationAck
        func spawnSubagent(_ request: SpawnSubagentRequest) async throws -> SubagentResultMsg
    }

    public static var callbackServiceRPCNames: [String] {
        ["SendNotification", "SpawnSubagent"]
    }

    public static var callbackStreamingRPCNames: Set<String> {
        []
    }
}
