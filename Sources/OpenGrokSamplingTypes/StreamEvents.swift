// StreamEvents.swift
//
// Open Grok — Swift port of the Chat Completions streaming chunk types and
// the Anthropic Messages API streaming event types in
// `crates/codegen/xai-grok-sampling-types/src/{types.rs,messages.rs}`.
//
// These are the provider-neutral stream-event shapes the sampler (W3-S3)
// decodes from the SSE wire and the session runtime (W7-S1) consumes. Both
// shapes retain forward-compat catch-alls so a new server-side value can
// never fail the terminal parse and discard an already-streamed response.

import Foundation
import OpenGrokShared

// MARK: - Chat Completions streaming

/// Streaming delta for a tool call. In OpenAI-compatible streaming, tool
/// calls arrive across multiple chunks: the first carries `id`, `type`,
/// `index`, and the `function.name` + start of `arguments`; subsequent
/// chunks only carry `index` and a `function.arguments` fragment. All fields
/// except `index` are therefore optional so every chunk decodes.
public struct ToolCallDelta: Codable, Sendable, Equatable, Hashable {
    public var index: UInt32
    public var id: String?
    public var kind: String?
    public var function: ToolCallFunctionDelta?

    public init(index: UInt32 = 0, id: String? = nil, kind: String? = nil, function: ToolCallFunctionDelta? = nil) {
        self.index = index
        self.id = id
        self.kind = kind
        self.function = function
    }

    public enum CodingKeys: String, CodingKey {
        case index, id
        case kind = "type"
        case function
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try c.decodeIfPresent(UInt32.self, forKey: .index) ?? 0
        self.id = try c.decodeIfPresent(String.self, forKey: .id)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        self.function = try c.decodeIfPresent(ToolCallFunctionDelta.self, forKey: .function)
    }
}

/// Streaming delta for function name/arguments within a tool call.
public struct ToolCallFunctionDelta: Codable, Sendable, Equatable, Hashable {
    public var name: String?
    public var arguments: String?

    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }

    public enum CodingKeys: String, CodingKey { case name, arguments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.arguments = try c.decodeIfPresent(String.self, forKey: .arguments)
    }
}

/// Streaming delta for a Chat Completions chunk.
public struct ChatChunkDelta: Codable, Sendable, Equatable, Hashable {
    public var role: Role?
    public var content: String?
    public var reasoningContent: String?
    public var reasoning: String?
    public var reasoningDetails: [OpenRouterReasoningDetail]
    public var toolCalls: [ToolCallDelta]
    public var toolCallId: String?

    public init(
        role: Role? = nil,
        content: String? = nil,
        reasoningContent: String? = nil,
        reasoning: String? = nil,
        reasoningDetails: [OpenRouterReasoningDetail] = [],
        toolCalls: [ToolCallDelta] = [],
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.reasoning = reasoning
        self.reasoningDetails = reasoningDetails
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    public enum CodingKeys: String, CodingKey {
        case role, content, reasoning
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decodeIfPresent(Role.self, forKey: .role)
        self.content = try c.decodeIfPresent(String.self, forKey: .content)
        self.reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
        self.reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        self.reasoningDetails = try c.decodeIfPresent(
            [OpenRouterReasoningDetail].self,
            forKey: .reasoningDetails
        ) ?? []
        // Handle null as empty vec, mirroring `deserialize_null_default`.
        if c.contains(.toolCalls) {
            self.toolCalls = try c.decodeIfPresent([ToolCallDelta].self, forKey: .toolCalls) ?? []
        } else {
            self.toolCalls = []
        }
        self.toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encodeIfPresent(
            reasoningDetails.isEmpty ? nil : reasoningDetails,
            forKey: .reasoningDetails
        )
        try c.encodeIfPresent(toolCalls.isEmpty ? nil : toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
    }

    /// Preserve provider precedence without trimming incremental fragments.
    public var reasoningText: String {
        if let reasoningContent, !reasoningContent.isEmpty {
            return reasoningContent
        }
        if let reasoning, !reasoning.isEmpty {
            return reasoning
        }
        return reasoningDetails.compactMap(\.displayText).joined()
    }
}

/// Forward-compatible OpenRouter structured reasoning fragment.
public struct OpenRouterReasoningDetail: Codable, Sendable, Equatable, Hashable {
    public var type: String
    public var text: String?
    public var summary: String?
    public var extra: [String: JSONValue]

    public init(
        type: String = "",
        text: String? = nil,
        summary: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.text = text
        self.summary = summary
        self.extra = extra
    }

    public var displayText: String? {
        switch type {
        case "reasoning.text":
            return text
        case "reasoning.summary":
            return summary ?? text
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.type = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("type")) ?? ""
        self.text = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("text"))
        self.summary = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("summary"))
        var extra: [String: JSONValue] = [:]
        for key in container.allKeys where key.stringValue != "type"
            && key.stringValue != "text" && key.stringValue != "summary"
        {
            extra[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(type, forKey: DynamicCodingKey("type"))
        try container.encodeIfPresent(text, forKey: DynamicCodingKey("text"))
        try container.encodeIfPresent(summary, forKey: DynamicCodingKey("summary"))
        for (key, value) in extra where key != "type" && key != "text" && key != "summary" {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}

/// One choice within a Chat Completions streaming chunk.
public struct ChatChunkChoice: Codable, Sendable, Equatable, Hashable {
    public var index: UInt32
    public var delta: ChatChunkDelta
    public var finishReason: FinishReason?

    public init(index: UInt32, delta: ChatChunkDelta, finishReason: FinishReason? = nil) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
    }

    public enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try c.decode(UInt32.self, forKey: .index)
        self.delta = try c.decode(ChatChunkDelta.self, forKey: .delta)
        self.finishReason = try c.decodeIfPresent(FinishReason.self, forKey: .finishReason)
    }
}

/// A Chat Completions streaming chunk.
public struct ChatCompletionChunk: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var object: String
    public var created: UInt64
    public var model: String
    public var choices: [ChatChunkChoice]
    public var usage: Usage?
    public var systemFingerprint: String?

    public init(
        id: String, object: String, created: UInt64, model: String,
        choices: [ChatChunkChoice], usage: Usage? = nil, systemFingerprint: String? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
        self.systemFingerprint = systemFingerprint
    }

    public enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case systemFingerprint = "system_fingerprint"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id`, `object`, `created`, and `model` are unused envelope metadata.
        // OpenCode Go omits them on ordinary and terminal chunks alike, so
        // requiring them would abort stream assembly on an otherwise complete
        // response. `choices` stays required: it carries the payload.
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.object = try c.decodeIfPresent(String.self, forKey: .object) ?? ""
        self.created = try c.decodeIfPresent(UInt64.self, forKey: .created) ?? 0
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.choices = try c.decode([ChatChunkChoice].self, forKey: .choices)
        self.usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        // empty-string-as-none normalization for `system_fingerprint`.
        if let fp = try c.decodeIfPresent(String.self, forKey: .systemFingerprint) {
            self.systemFingerprint = fp.isEmpty ? nil : fp
        } else {
            self.systemFingerprint = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(object, forKey: .object)
        try c.encode(created, forKey: .created)
        try c.encode(model, forKey: .model)
        try c.encode(choices, forKey: .choices)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encodeIfPresent(systemFingerprint, forKey: .systemFingerprint)
    }
}

// MARK: - Anthropic Messages streaming

/// Stop reason reported by the Anthropic Messages API. Wire form: snake_case.
/// Unknown variants deserialize as `.unknown(String)` so a new server-side
/// value can never fail the terminal `message_delta` parse.
///
/// Named `MessagesStopReason` to avoid colliding with the provider-neutral
/// `StopReason` in `ConversationRequest.swift`. The Rust source keeps them
/// separate via module paths (`crate::messages::StopReason` vs
/// `crate::StopReason`); Swift flattens modules so the rename preserves the
/// distinction.
public enum MessagesStopReason: Codable, Sendable, Equatable, Hashable {
    case endTurn
    case maxTokens
    case toolUse
    case stopSequence
    case refusal
    case pauseTurn
    case modelContextWindowExceeded
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "tool_use": self = .toolUse
        case "stop_sequence": self = .stopSequence
        case "refusal": self = .refusal
        case "pause_turn": self = .pauseTurn
        case "model_context_window_exceeded": self = .modelContextWindowExceeded
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .endTurn: try container.encode("end_turn")
        case .maxTokens: try container.encode("max_tokens")
        case .toolUse: try container.encode("tool_use")
        case .stopSequence: try container.encode("stop_sequence")
        case .refusal: try container.encode("refusal")
        case .pauseTurn: try container.encode("pause_turn")
        case .modelContextWindowExceeded: try container.encode("model_context_window_exceeded")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

/// Detail for a terminal `message_delta`, e.g.
/// `{"type":"refusal","category":"frontier_llm","explanation":"..."}`.
public struct StopDetails: Codable, Sendable, Equatable, Hashable {
    public var type: String?
    public var category: String?
    public var explanation: String?

    public init(type: String? = nil, category: String? = nil, explanation: String? = nil) {
        self.type = type
        self.category = category
        self.explanation = explanation
    }

    public enum CodingKeys: String, CodingKey { case type, category, explanation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.category = try c.decodeIfPresent(String.self, forKey: .category)
        self.explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
    }
}

/// Body of a `message_delta` streaming event.
public struct MessageDeltaBody: Codable, Sendable, Equatable, Hashable {
    public var stopReason: MessagesStopReason?
    public var stopDetails: StopDetails?

    public init(stopReason: MessagesStopReason? = nil, stopDetails: StopDetails? = nil) {
        self.stopReason = stopReason
        self.stopDetails = stopDetails
    }

    public enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.stopReason = try c.decodeIfPresent(MessagesStopReason.self, forKey: .stopReason)
        self.stopDetails = try c.decodeIfPresent(StopDetails.self, forKey: .stopDetails)
    }
}

public struct MessageDeltaUsage: Codable, Sendable, Equatable, Hashable {
    public var outputTokens: UInt32
    public var inputTokens: UInt32?
    public var cacheReadInputTokens: UInt32?
    public var cacheCreationInputTokens: UInt32?

    public init(
        outputTokens: UInt32,
        inputTokens: UInt32? = nil,
        cacheReadInputTokens: UInt32? = nil,
        cacheCreationInputTokens: UInt32? = nil
    ) {
        self.outputTokens = outputTokens
        self.inputTokens = inputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    public enum CodingKeys: String, CodingKey {
        case outputTokens = "output_tokens"
        case inputTokens = "input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.outputTokens = try c.decode(UInt32.self, forKey: .outputTokens)
        self.inputTokens = try c.decodeIfPresent(UInt32.self, forKey: .inputTokens)
        self.cacheReadInputTokens = try c.decodeIfPresent(UInt32.self, forKey: .cacheReadInputTokens)
        self.cacheCreationInputTokens = try c.decodeIfPresent(UInt32.self, forKey: .cacheCreationInputTokens)
    }
}

/// Content delta within a `content_block_delta` event.
public enum StreamDelta: Codable, Sendable, Equatable, Hashable {
    case textDelta(text: String)
    case inputJsonDelta(partialJson: String)
    case thinkingDelta(thinking: String)
    case signatureDelta(signature: String)

    public enum CodingKeys: String, CodingKey { case type, text, partialJson, thinking, signature }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text_delta":
            self = .textDelta(text: try c.decode(String.self, forKey: .text))
        case "input_json_delta":
            self = .inputJsonDelta(partialJson: try c.decode(String.self, forKey: .partialJson))
        case "thinking_delta":
            self = .thinkingDelta(thinking: try c.decode(String.self, forKey: .thinking))
        case "signature_delta":
            self = .signatureDelta(signature: try c.decode(String.self, forKey: .signature))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown StreamDelta: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .textDelta(let text):
            try c.encode("text_delta", forKey: .type)
            try c.encode(text, forKey: .text)
        case .inputJsonDelta(let partialJson):
            try c.encode("input_json_delta", forKey: .type)
            try c.encode(partialJson, forKey: .partialJson)
        case .thinkingDelta(let thinking):
            try c.encode("thinking_delta", forKey: .type)
            try c.encode(thinking, forKey: .thinking)
        case .signatureDelta(let signature):
            try c.encode("signature_delta", forKey: .type)
            try c.encode(signature, forKey: .signature)
        }
    }
}

/// Top-level Anthropic Messages streaming event (SSE `type` field selects
/// the variant).
public enum MessageStreamEvent: Codable, Sendable, Equatable, Hashable {
    case messageStart(message: MessagesResponse)
    case messageDelta(delta: MessageDeltaBody, usage: MessageDeltaUsage)
    case messageStop
    case contentBlockStart(index: UInt32, contentBlock: ContentBlock)
    case contentBlockDelta(index: UInt32, delta: StreamDelta)
    case contentBlockStop(index: UInt32)
    case ping
    case error(error: StreamError)

    public enum CodingKeys: String, CodingKey {
        case type, message, delta, usage, index
        case contentBlock = "content_block"
        case error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "message_start":
            self = .messageStart(message: try c.decode(MessagesResponse.self, forKey: .message))
        case "message_delta":
            self = .messageDelta(
                delta: try c.decode(MessageDeltaBody.self, forKey: .delta),
                usage: try c.decode(MessageDeltaUsage.self, forKey: .usage)
            )
        case "message_stop":
            self = .messageStop
        case "content_block_start":
            self = .contentBlockStart(
                index: try c.decode(UInt32.self, forKey: .index),
                contentBlock: try c.decode(ContentBlock.self, forKey: .contentBlock)
            )
        case "content_block_delta":
            self = .contentBlockDelta(
                index: try c.decode(UInt32.self, forKey: .index),
                delta: try c.decode(StreamDelta.self, forKey: .delta)
            )
        case "content_block_stop":
            self = .contentBlockStop(index: try c.decode(UInt32.self, forKey: .index))
        case "ping":
            self = .ping
        case "error":
            self = .error(error: try c.decode(StreamError.self, forKey: .error))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown MessageStreamEvent: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .messageStart(let message):
            try c.encode("message_start", forKey: .type)
            try c.encode(message, forKey: .message)
        case .messageDelta(let delta, let usage):
            try c.encode("message_delta", forKey: .type)
            try c.encode(delta, forKey: .delta)
            try c.encode(usage, forKey: .usage)
        case .messageStop:
            try c.encode("message_stop", forKey: .type)
        case .contentBlockStart(let index, let contentBlock):
            try c.encode("content_block_start", forKey: .type)
            try c.encode(index, forKey: .index)
            try c.encode(contentBlock, forKey: .contentBlock)
        case .contentBlockDelta(let index, let delta):
            try c.encode("content_block_delta", forKey: .type)
            try c.encode(index, forKey: .index)
            try c.encode(delta, forKey: .delta)
        case .contentBlockStop(let index):
            try c.encode("content_block_stop", forKey: .type)
            try c.encode(index, forKey: .index)
        case .ping:
            try c.encode("ping", forKey: .type)
        case .error(let error):
            try c.encode("error", forKey: .type)
            try c.encode(error, forKey: .error)
        }
    }
}

// MARK: - Anthropic Messages API request/response shapes (referenced by stream events)

/// Anthropic Messages API `StreamError` shape.
public struct StreamError: Codable, Sendable, Equatable, Hashable {
    public var type: String
    public var message: String

    public init(type: String, message: String) {
        self.type = type
        self.message = message
    }

    public enum CodingKeys: String, CodingKey {
        case type
        case message
    }
}

/// Anthropic Messages API usage.
public struct MessagesUsage: Codable, Sendable, Equatable, Hashable {
    public var inputTokens: UInt32
    public var outputTokens: UInt32
    public var cacheCreationInputTokens: UInt32
    public var cacheReadInputTokens: UInt32

    public init(
        inputTokens: UInt32 = 0,
        outputTokens: UInt32 = 0,
        cacheCreationInputTokens: UInt32 = 0,
        cacheReadInputTokens: UInt32 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try c.decode(UInt32.self, forKey: .inputTokens)
        self.outputTokens = try c.decode(UInt32.self, forKey: .outputTokens)
        self.cacheCreationInputTokens = try c.decodeIfPresent(UInt32.self, forKey: .cacheCreationInputTokens) ?? 0
        self.cacheReadInputTokens = try c.decodeIfPresent(UInt32.self, forKey: .cacheReadInputTokens) ?? 0
    }
}

/// Non-streaming response from POST /v1/messages.
public struct MessagesResponse: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var type: String
    public var role: String
    public var content: [ContentBlock]
    public var model: String
    public var stopReason: MessagesStopReason?
    public var usage: MessagesUsage

    public init(
        id: String, type: String, role: String, content: [ContentBlock],
        model: String, stopReason: MessagesStopReason? = nil, usage: MessagesUsage
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.content = content
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
    }

    public enum CodingKeys: String, CodingKey {
        case id, type, role, content, model
        case stopReason = "stop_reason"
        case usage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.type = try c.decode(String.self, forKey: .type)
        self.role = try c.decode(String.self, forKey: .role)
        self.content = try c.decode([ContentBlock].self, forKey: .content)
        self.model = try c.decode(String.self, forKey: .model)
        self.stopReason = try c.decodeIfPresent(MessagesStopReason.self, forKey: .stopReason)
        self.usage = try c.decode(MessagesUsage.self, forKey: .usage)
    }
}

/// Anthropic Messages API content block (referenced by stream events).
public enum ContentBlock: Codable, Sendable, Equatable, Hashable {
    case text(text: String, cacheControl: CacheControl?)
    case image(source: ImageSource)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: ToolResultContent, cacheControl: CacheControl?)
    case thinking(thinking: String, signature: String)

    public enum CodingKeys: String, CodingKey {
        case type, text, cacheControl, source
        case id, name, input
        case toolUseId = "tool_use_id"
        case content
        case thinking, signature
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(
                text: try c.decode(String.self, forKey: .text),
                cacheControl: try c.decodeIfPresent(CacheControl.self, forKey: .cacheControl)
            )
        case "image":
            self = .image(source: try c.decode(ImageSource.self, forKey: .source))
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode(JSONValue.self, forKey: .input)
            )
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try c.decode(ToolResultContent.self, forKey: .content),
                cacheControl: try c.decodeIfPresent(CacheControl.self, forKey: .cacheControl)
            )
        case "thinking":
            self = .thinking(
                thinking: try c.decode(String.self, forKey: .thinking),
                signature: try c.decode(String.self, forKey: .signature)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown ContentBlock: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let cacheControl):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case .image(let source):
            try c.encode("image", forKey: .type)
            try c.encode(source, forKey: .source)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let cacheControl):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case .thinking(let thinking, let signature):
            try c.encode("thinking", forKey: .type)
            try c.encode(thinking, forKey: .thinking)
            try c.encode(signature, forKey: .signature)
        }
    }
}

public struct CacheControl: Codable, Sendable, Equatable, Hashable {
    public var type: String

    public init(type: String = "ephemeral") { self.type = type }

    public enum CodingKeys: String, CodingKey { case type }
}

public enum ImageSource: Codable, Sendable, Equatable, Hashable {
    case base64(mediaType: String, data: String)
    case url(url: String)

    public enum CodingKeys: String, CodingKey { case type, mediaType, data, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "base64":
            self = .base64(
                mediaType: try c.decode(String.self, forKey: .mediaType),
                data: try c.decode(String.self, forKey: .data)
            )
        case "url":
            self = .url(url: try c.decode(String.self, forKey: .url))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown ImageSource: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .base64(let mediaType, let data):
            try c.encode("base64", forKey: .type)
            try c.encode(mediaType, forKey: .mediaType)
            try c.encode(data, forKey: .data)
        case .url(let url):
            try c.encode("url", forKey: .type)
            try c.encode(url, forKey: .url)
        }
    }
}

public enum ToolResultContent: Codable, Sendable, Equatable, Hashable {
    case text(String)
    case blocks([ContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else if let blocks = try? container.decode([ContentBlock].self) {
            self = .blocks(blocks)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "ToolResultContent: expected string or array")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }
}
