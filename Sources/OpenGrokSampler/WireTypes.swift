// WireTypes.swift
//
// Chat Completions wire request/response shapes owned by the sampler.
// These live here because OpenGrokSamplingTypes currently exports stream
// chunks and conversation types but not the full ChatCompletionRequest
// projection surface. Keep them private to the sampler module except where
// provider adapters need to mutate them.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Chat Completions request wire

public struct ChatRequestWireMessage: Codable, Sendable, Equatable {
    public var role: Role
    public var content: MessageContent
    public var name: String?
    public var toolCalls: [ToolCallRequestWire]
    public var toolCallId: String?
    public var modelId: String?
    public var reasoningContent: String?

    public init(
        role: Role,
        content: MessageContent,
        name: String? = nil,
        toolCalls: [ToolCallRequestWire] = [],
        toolCallId: String? = nil,
        modelId: String? = nil,
        reasoningContent: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.modelId = modelId
        self.reasoningContent = reasoningContent
    }

    public enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case modelId = "model_id"
        case reasoningContent = "reasoning_content"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decode(Role.self, forKey: .role)
        self.content = try c.decode(MessageContent.self, forKey: .content)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.toolCalls = try c.decodeIfPresent([ToolCallRequestWire].self, forKey: .toolCalls) ?? []
        self.toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        self.modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        self.reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(name, forKey: .name)
        if !toolCalls.isEmpty {
            try c.encode(toolCalls, forKey: .toolCalls)
        }
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try c.encodeIfPresent(modelId, forKey: .modelId)
        try c.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
    }

    public static func system(_ content: String) -> Self {
        Self(role: .system, content: .text(content))
    }

    public static func user(_ content: String) -> Self {
        Self(role: .user, content: .text(content))
    }

    public static func tool(toolCallId: String, content: String) -> Self {
        Self(role: .tool, content: .text(content), toolCallId: toolCallId)
    }
}

public struct ToolCallRequestWire: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var function: ToolCallFunctionWire

    public init(id: String, type: String = "function", function: ToolCallFunctionWire) {
        self.id = id
        self.type = type
        self.function = function
    }

    public static func function(id: String, name: String, arguments: String) -> Self {
        Self(id: id, function: ToolCallFunctionWire(name: name, arguments: arguments))
    }
}

public struct ToolCallFunctionWire: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolDefinitionWire: Codable, Sendable, Equatable {
    public var type: String
    public var function: ToolFunctionDefinitionWire

    public init(type: String = "function", function: ToolFunctionDefinitionWire) {
        self.type = type
        self.function = function
    }

    public static func function(name: String, description: String?, parameters: JSONValue) -> Self {
        Self(function: ToolFunctionDefinitionWire(name: name, description: description, parameters: parameters))
    }
}

public struct ToolFunctionDefinitionWire: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue

    public init(name: String, description: String?, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum ToolChoiceWire: Codable, Sendable, Equatable {
    case auto
    case none
    case required
    case function(name: String)

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            switch s {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default:
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unknown tool_choice \(s)")
                )
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "function":
            let fn = try c.decode(NameBox.self, forKey: .function)
            self = .function(name: fn.name)
        case "auto": self = .auto
        case "none": self = .none
        case "required": self = .required
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown tool_choice")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .auto:
            var c = encoder.singleValueContainer()
            try c.encode("auto")
        case .none:
            var c = encoder.singleValueContainer()
            try c.encode("none")
        case .required:
            var c = encoder.singleValueContainer()
            try c.encode("required")
        case .function(let name):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("function", forKey: .type)
            try c.encode(NameBox(name: name), forKey: .function)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, function }
    private struct NameBox: Codable { var name: String }
}

public struct ChatCompletionWireRequest: Encodable, Sendable, Equatable {
    public var model: String?
    public var messages: [ChatRequestWireMessage]
    public var temperature: Float?
    public var maxTokens: UInt32?
    public var topP: Float?
    public var frequencyPenalty: Float?
    public var presencePenalty: Float?
    public var user: String?
    public var tools: [ToolDefinitionWire]?
    public var toolChoice: ToolChoiceWire?
    public var stream: Bool?
    public var streamOptions: StreamOptionsWire?
    public var reasoningEffort: ReasoningEffort?
    public var thinking: ChatThinkingMode?
    /// Chat Completions `service_tier` routing id (`"priority"` for Fast
    /// mode). `nil` omits the field — standard routing is the absence of the
    /// field, never `"default"`. Port of `ChatCompletionRequest.service_tier`
    /// (`xai-grok-sampling-types/src/types.rs:89-90`).
    public var serviceTier: String?
    public var responseFormat: JSONValue?

    // Non-serialized tracking headers (carried alongside for client use).
    public var xGrokConvId: String?
    public var xGrokReqId: String?
    public var xGrokSessionId: String?
    public var xGrokTurnIdx: String?
    public var xGrokAgentId: String?
    public var xGrokDeploymentId: String?
    public var xGrokUserId: String?

    public init(
        model: String? = nil,
        messages: [ChatRequestWireMessage] = [],
        temperature: Float? = nil,
        maxTokens: UInt32? = nil,
        topP: Float? = nil,
        frequencyPenalty: Float? = nil,
        presencePenalty: Float? = nil,
        user: String? = nil,
        tools: [ToolDefinitionWire]? = nil,
        toolChoice: ToolChoiceWire? = nil,
        stream: Bool? = nil,
        streamOptions: StreamOptionsWire? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        thinking: ChatThinkingMode? = nil,
        serviceTier: String? = nil,
        responseFormat: JSONValue? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.user = user
        self.tools = tools
        self.toolChoice = toolChoice
        self.stream = stream
        self.streamOptions = streamOptions
        self.reasoningEffort = reasoningEffort
        self.thinking = thinking
        self.serviceTier = serviceTier
        self.responseFormat = responseFormat
    }

    public enum CodingKeys: String, CodingKey {
        case model, messages, temperature, user, tools, stream
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case toolChoice = "tool_choice"
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
        case thinking
        case serviceTier = "service_tier"
        case responseFormat = "response_format"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encodeIfPresent(frequencyPenalty, forKey: .frequencyPenalty)
        try c.encodeIfPresent(presencePenalty, forKey: .presencePenalty)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try c.encodeIfPresent(stream, forKey: .stream)
        try c.encodeIfPresent(streamOptions, forKey: .streamOptions)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encodeIfPresent(serviceTier, forKey: .serviceTier)
        try c.encodeIfPresent(responseFormat, forKey: .responseFormat)
    }
}

public struct StreamOptionsWire: Codable, Sendable, Equatable {
    public var includeUsage: Bool

    public init(includeUsage: Bool = true) {
        self.includeUsage = includeUsage
    }

    public enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

// MARK: - Messages API wire (minimal)

public struct MessagesWireRequest: Encodable, Sendable, Equatable {
    public var model: String
    public var messages: [JSONValue]
    public var maxTokens: UInt32
    public var system: JSONValue?
    public var tools: [JSONValue]?
    public var toolChoice: JSONValue?
    public var temperature: Float?
    public var topP: Float?
    public var stream: Bool?
    public var thinking: JSONValue?
    public var outputConfig: JSONValue?

    public enum CodingKeys: String, CodingKey {
        case model, messages, system, tools, temperature, stream, thinking
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case topP = "top_p"
        case outputConfig = "output_config"
    }

    public init(
        model: String,
        messages: [JSONValue],
        maxTokens: UInt32,
        system: JSONValue? = nil,
        tools: [JSONValue]? = nil,
        toolChoice: JSONValue? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        stream: Bool? = nil,
        thinking: JSONValue? = nil,
        outputConfig: JSONValue? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.system = system
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.topP = topP
        self.stream = stream
        self.thinking = thinking
        self.outputConfig = outputConfig
    }
}
