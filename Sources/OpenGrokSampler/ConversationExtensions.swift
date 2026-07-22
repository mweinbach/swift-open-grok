// ConversationExtensions.swift
//
// Sampler-owned helpers on ConversationRequest / ConversationResponse that
// are required by the retry loop and L2 transforms but not yet exported from
// OpenGrokSamplingTypes (strip_images, etc.).

import Foundation
import OpenGrokSamplingTypes

extension ConversationRequest {
    /// Replace inline images with a text placeholder. Used as a recovery
    /// strategy when the downstream API returns 413 "Request Entity Too Large".
    @discardableResult
    public mutating func stripImages() -> Int {
        var stripped = 0
        for i in items.indices {
            switch items[i] {
            case .user(var user):
                for j in user.content.indices {
                    if case .image = user.content[j] {
                        user.content[j] = .text(text: "[image removed — conversation too large]")
                        stripped += 1
                    }
                }
                items[i] = .user(user)
            case .toolResult(var t):
                stripped += t.images.count
                t.images = []
                for j in t.orderedContent.indices {
                    if case .image = t.orderedContent[j] {
                        t.orderedContent[j] = .text(text: "[image removed — conversation too large]")
                        stripped += 1
                    }
                }
                items[i] = .toolResult(t)
            case .customToolOutput(var output):
                for j in output.content.indices {
                    if case .image = output.content[j] {
                        output.content[j] = .text(text: "[image removed — conversation too large]")
                        stripped += 1
                    }
                }
                items[i] = .customToolOutput(output)
            default:
                break
            }
        }
        return stripped
    }
}

// MARK: - Projection: ConversationRequest → Chat Completions wire

/// Project conversation items into Chat Completions messages, folding
/// preceding Reasoning siblings into `reasoning_content` on the following
/// assistant message.
public func conversationToChatMessages(_ items: [ConversationItem]) -> [ChatRequestWireMessage] {
    var out: [ChatRequestWireMessage] = []
    var pendingReasoning: String?

    for item in items {
        switch item {
        case .reasoning(let r):
            let text = reasoningItemText(r)
            if !text.isEmpty {
                if let existing = pendingReasoning, !existing.isEmpty {
                    pendingReasoning = existing + "\n\n" + text
                } else {
                    pendingReasoning = text
                }
            }
        case .assistant(let a):
            var msg = chatMessageFromAssistant(a)
            if let reasoning = pendingReasoning, !reasoning.isEmpty {
                msg.reasoningContent = reasoning
            }
            pendingReasoning = nil
            out.append(msg)
        default:
            // Flush orphan reasoning as an empty assistant with reasoning only
            // is not required for Chat Completions; drop pending and emit item.
            pendingReasoning = nil
            out.append(conversationItemToChatMessage(item))
        }
    }
    return out
}

public func conversationItemToChatMessage(_ item: ConversationItem) -> ChatRequestWireMessage {
    switch item {
    case .system(let s):
        return .system(s.content)
    case .user(let u):
        let hasImages = u.content.contains { if case .image = $0 { return true }; return false }
        let content: MessageContent
        if !hasImages {
            let text = u.content.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            content = .text(text)
        } else {
            let blocks: [ChatContentBlock] = u.content.map { part in
                switch part {
                case .text(let t): return .text(text: t)
                case .image(let url): return .imageUrl(url: ImageUrl(url: url))
                }
            }
            content = .blocks(blocks)
        }
        return ChatRequestWireMessage(role: .user, content: content)
    case .assistant(let a):
        return chatMessageFromAssistant(a)
    case .toolResult(let t):
        if !t.orderedContent.isEmpty {
            let blocks: [ChatContentBlock] = t.orderedContent.map { part in
                switch part {
                case .text(let text): return .text(text: text)
                case .image(let url, _): return .imageUrl(url: ImageUrl(url: url))
                }
            }
            return ChatRequestWireMessage(
                role: .tool,
                content: .blocks(blocks),
                toolCallId: t.toolCallId
            )
        } else if t.images.isEmpty {
            return .tool(toolCallId: t.toolCallId, content: t.content)
        } else {
            var blocks: [ChatContentBlock] = [.text(text: t.content)]
            for img in t.images {
                if case .image(let url) = img {
                    blocks.append(.imageUrl(url: ImageUrl(url: url)))
                }
            }
            return ChatRequestWireMessage(
                role: .tool,
                content: .blocks(blocks),
                toolCallId: t.toolCallId
            )
        }
    case .customToolOutput(let output):
        let hasNonText = output.content.contains { if case .image = $0 { return true }; return false }
        let content: MessageContent
        if output.content.count == 1, !hasNonText, case .text(let text) = output.content[0] {
            content = .text(text)
        } else {
            let blocks: [ChatContentBlock] = output.content.map { part in
                switch part {
                case .text(let text): return .text(text: text)
                case .image(let url, _): return .imageUrl(url: ImageUrl(url: url))
                }
            }
            content = .blocks(blocks)
        }
        return ChatRequestWireMessage(
            role: .tool,
            content: content,
            toolCallId: output.callId
        )
    case .reasoning(let r):
        // Per-item path: fold into an empty assistant with reasoning_content.
        return ChatRequestWireMessage(
            role: .assistant,
            content: .text(""),
            reasoningContent: reasoningItemText(r)
        )
    case .backendToolCall:
        // Opaque backend history is not representable on Chat Completions.
        return ChatRequestWireMessage(role: .assistant, content: .text(""))
    }
}

private func chatMessageFromAssistant(_ a: AssistantItem) -> ChatRequestWireMessage {
    let toolCalls: [ToolCallRequestWire] = a.toolCalls.map { tc in
        .function(id: tc.id, name: tc.name, arguments: tc.arguments)
    }
    return ChatRequestWireMessage(
        role: .assistant,
        content: .text(a.content),
        toolCalls: toolCalls,
        modelId: a.modelId,
        reasoningContent: nil
    )
}

private func reasoningItemText(_ r: ReasoningItem) -> String {
    var parts: [String] = []
    for s in r.summary {
        let t = s.text
        if !t.isEmpty { parts.append(t) }
    }
    if let content = r.content {
        for c in content {
            if !c.text.isEmpty { parts.append(c.text) }
        }
    }
    return parts.joined(separator: "\n\n")
}

/// Project a conversation request onto the Chat Completions wire shape.
public func projectChatCompletionRequest(
    _ req: ConversationRequest,
    defaults: SamplingClientDefaults? = nil
) -> ChatCompletionWireRequest {
    let messages = conversationToChatMessages(req.items)
    let toolsIsEmpty = req.tools.isEmpty
    let tools: [ToolDefinitionWire]? = toolsIsEmpty
        ? nil
        : req.tools.map { ToolDefinitionWire.function(name: $0.name, description: $0.description, parameters: $0.parameters) }

    let toolChoice: ToolChoiceWire? = {
        guard !toolsIsEmpty, let tc = req.toolChoice else { return nil }
        switch tc {
        case .auto: return .auto
        case .none: return .none
        case .required: return .required
        case .function(let name): return .function(name: name)
        case .custom: return nil
        }
    }()

    var responseFormat: JSONValue?
    if let schema = req.jsonSchema {
        responseFormat = .object([
            "type": .string("json_schema"),
            "json_schema": .object([
                "name": .string("structured_output"),
                "schema": schema,
                "strict": .bool(true),
            ]),
        ])
    }

    var wire = ChatCompletionWireRequest(
        model: req.model ?? defaults?.model,
        messages: messages,
        temperature: req.temperature ?? defaults?.temperature,
        maxTokens: req.maxOutputTokens ?? defaults?.maxCompletionTokens,
        topP: req.topP ?? defaults?.topP,
        tools: tools,
        toolChoice: toolChoice,
        reasoningEffort: req.reasoningEffort ?? defaults?.reasoningEffort,
        responseFormat: responseFormat
    )
    wire.xGrokConvId = req.xGrokConvId
    wire.xGrokReqId = req.xGrokReqId
    wire.xGrokSessionId = req.xGrokSessionId
    wire.xGrokTurnIdx = req.xGrokTurnIdx
    wire.xGrokAgentId = req.xGrokAgentId
    wire.xGrokDeploymentId = req.xGrokDeploymentId
    wire.xGrokUserId = req.xGrokUserId
    return wire
}

// MARK: - Projection: ConversationRequest → Messages wire (simplified)

/// Project a conversation request onto a minimal Anthropic Messages body.
public func projectMessagesRequest(
    _ req: ConversationRequest,
    model: String,
    maxTokens: UInt32
) -> MessagesWireRequest {
    var systemParts: [String] = []
    var messages: [JSONValue] = []

    for item in req.items {
        switch item {
        case .system(let s):
            systemParts.append(s.content)
        case .user(let u):
            let content: JSONValue
            if u.content.count == 1, case .text(let t) = u.content[0] {
                content = .string(t)
            } else {
                let blocks: [JSONValue] = u.content.map { part in
                    switch part {
                    case .text(let t):
                        return .object(["type": .string("text"), "text": .string(t)])
                    case .image(let url):
                        return .object([
                            "type": .string("image"),
                            "source": .object([
                                "type": .string("url"),
                                "url": .string(url),
                            ]),
                        ])
                    }
                }
                content = .array(blocks)
            }
            messages.append(.object([
                "role": .string("user"),
                "content": content,
            ]))
        case .assistant(let a):
            var contentBlocks: [JSONValue] = []
            if !a.content.isEmpty {
                contentBlocks.append(.object([
                    "type": .string("text"),
                    "text": .string(a.content),
                ]))
            }
            for tc in a.toolCalls {
                let input: JSONValue
                if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(tc.arguments.utf8)) {
                    input = parsed
                } else {
                    input = .object([:])
                }
                contentBlocks.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(tc.id),
                    "name": .string(tc.name),
                    "input": input,
                ]))
            }
            messages.append(.object([
                "role": .string("assistant"),
                "content": .array(contentBlocks),
            ]))
        case .toolResult(let t):
            messages.append(.object([
                "role": .string("user"),
                "content": .array([
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(t.toolCallId),
                        "content": .string(t.content),
                    ]),
                ]),
            ]))
        case .reasoning, .backendToolCall, .customToolOutput:
            break
        }
    }

    var tools: [JSONValue]?
    if !req.tools.isEmpty {
        tools = req.tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": tool.description.map { .string($0) } ?? .null,
                "input_schema": tool.parameters,
            ])
        }
    }

    return MessagesWireRequest(
        model: model,
        messages: messages,
        maxTokens: maxTokens,
        system: systemParts.isEmpty ? nil : .string(systemParts.joined(separator: "\n\n")),
        tools: tools,
        temperature: req.temperature,
        topP: req.topP
    )
}

// MARK: - Projection: ConversationRequest → Responses wire (JSON body)

/// Project a conversation request onto a Responses API JSON body.
public func projectResponsesRequestBody(
    _ req: ConversationRequest,
    model: String,
    policy: ResponsesRequestPolicy,
    adapter: any ProviderAdapter
) -> JSONValue {
    var input: [JSONValue] = []
    for item in req.items {
        switch item {
        case .system(let s):
            input.append(.object([
                "type": .string("message"),
                "role": .string("system"),
                "content": .string(s.content),
            ]))
        case .user(let u):
            let content: JSONValue
            if u.content.count == 1, case .text(let t) = u.content[0] {
                content = .string(t)
            } else {
                let parts: [JSONValue] = u.content.map { part in
                    switch part {
                    case .text(let t):
                        return .object(["type": .string("input_text"), "text": .string(t)])
                    case .image(let url):
                        return .object([
                            "type": .string("input_image"),
                            "image_url": .string(url),
                        ])
                    }
                }
                content = .array(parts)
            }
            input.append(.object([
                "type": .string("message"),
                "role": .string("user"),
                "content": content,
            ]))
        case .assistant(let a):
            if !a.content.isEmpty || a.toolCalls.isEmpty {
                input.append(.object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .string(a.content),
                ]))
            }
            for tc in a.toolCalls {
                if tc.isCustom {
                    input.append(.object([
                        "type": .string("custom_tool_call"),
                        "call_id": .string(tc.callId),
                        "id": .string(tc.customItemId ?? tc.callId),
                        "name": .string(tc.name),
                        "input": .string(tc.arguments),
                    ]))
                } else {
                    input.append(.object([
                        "type": .string("function_call"),
                        "call_id": .string(tc.id),
                        "name": .string(tc.name),
                        "arguments": .string(tc.arguments),
                    ]))
                }
            }
        case .toolResult(let t):
            input.append(.object([
                "type": .string("function_call_output"),
                "call_id": .string(t.toolCallId),
                "output": .string(t.content),
            ]))
        case .reasoning(let r):
            var obj: [String: JSONValue] = [
                "type": .string("reasoning"),
                "id": .string(r.id),
                "summary": .array(r.summary.map { .object(["type": .string("summary_text"), "text": .string($0.text)]) }),
            ]
            if let enc = r.encryptedContent {
                obj["encrypted_content"] = .string(enc)
            }
            input.append(.object(obj))
        case .customToolOutput(let o):
            let text = o.content.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined()
            input.append(.object([
                "type": .string("custom_tool_call_output"),
                "call_id": .string(o.callId),
                "output": .string(text),
            ]))
        case .backendToolCall(let b):
            // Preserve opaque backend history when we have a raw JSON form.
            if case .codexRawInput(let raw) = b.kind {
                input.append(raw.raw)
            }
        }
    }

    var tools: [JSONValue] = req.tools.map { tool in
        .object([
            "type": .string("function"),
            "name": .string(tool.name),
            "description": tool.description.map { .string($0) } ?? .null,
            "parameters": tool.parameters,
        ])
    }
    for hosted in hostedToolsForProvider(hostedTools: req.hostedTools, provider: adapter.provider) {
        switch hosted {
        case .webSearch:
            tools.append(.object(["type": .string("web_search")]))
        case .xSearch:
            tools.append(.object(["type": .string("x_search")]))
        case .clientCustom(let spec):
            tools.append(.object([
                "type": .string("custom"),
                "name": .string(spec.name),
                "description": spec.description.map { .string($0) } ?? .null,
            ]))
        }
    }

    var body: [String: JSONValue] = [
        "model": .string(model),
        "input": .array(input),
        "stream": .bool(true),
    ]
    if !tools.isEmpty {
        body["tools"] = .array(tools)
    }
    if let tc = req.toolChoice {
        switch tc {
        case .auto: body["tool_choice"] = .string("auto")
        case .none: body["tool_choice"] = .string("none")
        case .required: body["tool_choice"] = .string("required")
        case .function(let name):
            body["tool_choice"] = .object([
                "type": .string("function"),
                "name": .string(name),
            ])
        case .custom(let name):
            body["tool_choice"] = .object([
                "type": .string("custom"),
                "name": .string(name),
            ])
        }
    }
    if let max = req.maxOutputTokens {
        body["max_output_tokens"] = .number(.int64(Int64(max)))
    }
    if let temp = req.temperature {
        body["temperature"] = .number(.double(Double(temp)))
    }
    if let topP = req.topP {
        body["top_p"] = .number(.double(Double(topP)))
    }
    if let key = adapter.promptCacheKey(sessionId: req.xGrokSessionId) {
        body["prompt_cache_key"] = .string(key)
    }

    var value = JSONValue.object(body)
    adapter.patchResponsesRequest(&value, policy: policy)
    return value
}

/// Defaults snapshot used when projecting conversation requests.
public struct SamplingClientDefaults: Sendable {
    public var model: String
    public var maxCompletionTokens: UInt32?
    public var temperature: Float?
    public var topP: Float?
    public var apiBackend: ApiBackend
    public var provider: ModelProvider
    public var authScheme: AuthScheme
    public var streamToolCalls: Bool
    public var idleTimeoutSecs: UInt64?
    public var codexMultiAgentV2: Bool
    public var reasoningEffort: ReasoningEffort?
    public var reasoningSummary: ReasoningSummary?
    public var doomLoopRecovery: DoomLoopRecoveryPolicy?

    public init(from config: SamplerConfig) {
        self.model = config.model
        self.maxCompletionTokens = config.maxCompletionTokens
        self.temperature = config.temperature
        self.topP = config.topP
        self.apiBackend = config.apiBackend
        self.provider = config.provider
        self.authScheme = config.authScheme
        self.streamToolCalls = config.streamToolCalls
        self.idleTimeoutSecs = config.idleTimeoutSecs
        self.codexMultiAgentV2 = config.codexMultiAgentV2
        self.reasoningEffort = config.reasoningEffort
        self.reasoningSummary = config.reasoningSummary
        self.doomLoopRecovery = config.doomLoopRecovery
    }
}
