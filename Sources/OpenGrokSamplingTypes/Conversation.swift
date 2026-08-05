// Conversation.swift
//
// Open Grok — Swift port of the `ConversationItem` enum and its constructors
// in `crates/codegen/xai-grok-sampling-types/src/conversation.rs`.
//
// `ConversationItem` is the unified internal representation that can be
// converted to either the Chat Completions API, the Responses API, or the
// Anthropic Messages API. It is provider-neutral: opaque backend items are
// retained typed and tagged by backend/dialect so replay round-trips
// byte-stably.

import Foundation
import OpenGrokShared

/// A single item in a conversation - the unified internal representation.
///
/// Wire form: internally tagged by `type`, snake_case, mirroring Rust
/// `#[serde(tag = "type", rename_all = "snake_case")]`.
public enum ConversationItem: Codable, Sendable, Equatable, Hashable {
    /// System instructions/prompt.
    case system(SystemItem)
    /// User input message.
    case user(UserItem)
    /// Assistant response.
    case assistant(AssistantItem)
    /// Tool/function result.
    case toolResult(ToolResultItem)
    /// Output from a native Responses custom-tool call.
    case customToolOutput(CustomToolOutputItem)
    /// A tool call executed server-side by the backend agentic sampler
    /// (e.g. web search, X search, code interpreter). These are NOT executed
    /// by the client.
    case backendToolCall(BackendToolCallItem)
    /// A reasoning item from the Responses API, stored as a sibling of the
    /// assistant message so N parallel reasoning items round-trip losslessly.
    case reasoning(ReasoningItem)

    private enum Tag: String, CodingKey {
        case type
        case system, user, assistant
        case toolResult = "tool_result"
        case customToolOutput = "custom_tool_output"
        case backendToolCall = "backend_tool_call"
        case reasoning
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Tag.self)
        let type = try c.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()
        switch type {
        case "system": self = .system(try single.decode(SystemItem.self))
        case "user": self = .user(try single.decode(UserItem.self))
        case "assistant": self = .assistant(try single.decode(AssistantItem.self))
        case "tool_result": self = .toolResult(try single.decode(ToolResultItem.self))
        case "custom_tool_output": self = .customToolOutput(try single.decode(CustomToolOutputItem.self))
        case "backend_tool_call": self = .backendToolCall(try single.decode(BackendToolCallItem.self))
        case "reasoning": self = .reasoning(try single.decode(ReasoningItem.self))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown ConversationItem type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Tag.self)
        var single = encoder.singleValueContainer()
        switch self {
        case .system(let s):
            try c.encode("system", forKey: .type)
            try single.encode(s)
        case .user(let u):
            try c.encode("user", forKey: .type)
            try single.encode(u)
        case .assistant(let a):
            try c.encode("assistant", forKey: .type)
            try single.encode(a)
        case .toolResult(let t):
            try c.encode("tool_result", forKey: .type)
            try single.encode(t)
        case .customToolOutput(let o):
            try c.encode("custom_tool_output", forKey: .type)
            try single.encode(o)
        case .backendToolCall(let b):
            try c.encode("backend_tool_call", forKey: .type)
            try single.encode(b)
        case .reasoning(let r):
            try c.encode("reasoning", forKey: .type)
            try single.encode(r)
        }
    }

    // MARK: - Constructors

    /// Create a system message.
    public static func system(_ content: String) -> Self {
        .system(SystemItem(content: content))
    }

    /// Create a user message with text content. `syntheticReason` is `nil` —
    /// this represents real user input.
    public static func user(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)]))
    }

    /// Create a user message with multiple content parts.
    public static func userWithParts(_ parts: [ContentPart]) -> Self {
        .user(UserItem(content: parts))
    }

    /// Create a synthetic user message for metadata injection (compaction
    /// pipeline re-read file contents).
    public static func userMeta(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .compactionMeta))
    }

    /// Create a synthetic user message for a runtime system reminder.
    public static func systemReminder(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .systemReminder))
    }

    /// User message containing project instructions (AGENTS.md / CLAUDE.md).
    public static func projectInstructions(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .projectInstructions))
    }

    /// Create a synthetic user message for an auto-continue prompt.
    public static func autoContinue(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .autoContinue))
    }

    /// Create a synthetic user message for an auto-recovery retry prompt.
    public static func autoRecovery(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .autoRecovery))
    }

    /// Create a synthetic user message for a mid-turn interjection.
    public static func interjection(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .interjection))
    }

    /// Auto-wake synthetic prompt for a completed background bash task.
    public static func taskCompleted(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .taskCompleted))
    }

    /// Auto-wake synthetic prompt for a completed background subagent.
    public static func subagentCompleted(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .subagentCompleted))
    }

    /// Idle-gated notification drain (batched completions / monitor events).
    public static func notificationDrain(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .notificationDrain))
    }

    /// Goal orchestrator summary turn.
    public static func goalSummary(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .goalSummary))
    }

    /// Goal-achievement classifier nudge.
    public static func goalClassifierNudge(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .goalClassifierNudge))
    }

    /// Scheduled task (`/loop`) prompt fired by the scheduler.
    public static func schedulerFired(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .schedulerFired))
    }

    /// Mailbox message delivered from a peer agent in the same collaboration
    /// team. Tagged distinctly from the completion auto-wakes so trace tooling
    /// and compaction can tell peer traffic apart from lifecycle events.
    ///
    /// Mirrors Rust `ConversationItem::agent_message`
    /// (`xai-grok-sampling-types/src/conversation.rs:2497-2510`, commit
    /// aa39b8cf).
    public static func agentMessage(_ content: String) -> Self {
        .user(UserItem(content: [.text(text: content)], syntheticReason: .agentMessage))
    }

    /// Create an assistant message.
    public static func assistant(_ content: String) -> Self {
        .assistant(AssistantItem(content: content))
    }

    /// Create an assistant message with a model ID.
    public static func assistantWithModel(_ content: String, modelId: String) -> Self {
        .assistant(AssistantItem(content: content, modelId: modelId))
    }

    /// Create an assistant message that makes tool calls.
    public static func assistantToolCalls(_ toolCalls: [ToolCall]) -> Self {
        .assistant(AssistantItem(content: "", toolCalls: toolCalls))
    }

    /// Create a tool result message.
    public static func toolResult(toolCallId: String, content: String) -> Self {
        .toolResult(ToolResultItem(toolCallId: toolCallId, content: content))
    }

    /// Create a result for a native Responses custom-tool call when the
    /// caller has provider IDs rather than the opaque `ToolCall.id` envelope.
    public static func customToolResult(callId: String, itemId: String, content: String) -> Self {
        .customToolOutput(CustomToolOutputItem.text(callId: callId, content).withItemId(itemId))
    }

    /// Create a native custom-tool output with ordered content blocks.
    public static func makeCustomToolOutput(_ output: CustomToolOutputItem) -> Self {
        .customToolOutput(output)
    }

    /// Create a tool result message with inline images.
    public static func toolResultWithImages(
        toolCallId: String, content: String, images: [ContentPart]
    ) -> Self {
        .toolResult(ToolResultItem(toolCallId: toolCallId, content: content, images: images))
    }

    /// Create a function-tool result whose mixed content order and image
    /// fidelity must survive Responses replay (for example Code Mode `wait`).
    public static func toolResultWithOrderedContent(
        toolCallId: String, orderedContent: [CustomToolOutputContent]
    ) -> Self {
        let text = orderedContent.compactMap { part in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
        return .toolResult(ToolResultItem(
            toolCallId: toolCallId, content: text, images: [], orderedContent: orderedContent
        ))
    }

    // MARK: - Accessors

    /// Get the role of this item.
    public var role: Role {
        switch self {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .toolResult, .customToolOutput: return .tool
        case .backendToolCall(let b):
            if case .codexRawInput(let raw) = b.kind {
                return raw.placeholderRole()
            }
            return .assistant
        case .reasoning: return .assistant
        }
    }

    /// Add an image to a user message. No-op for other message types.
    public mutating func addImage(_ url: String) {
        switch self {
        case .user(var u):
            u.addImage(url)
            self = .user(u)
        default:
            break
        }
    }

    /// Extract text content from this item.
    public func textContent() -> String {
        switch self {
        case .system(let s): return s.content
        case .user(let u):
            return u.content.compactMap { part in
                switch part {
                case .text(let text): return text
                case .image: return nil
                }
            }.joined(separator: "\n")
        case .assistant(let a): return a.content
        case .toolResult(let t): return t.content
        case .customToolOutput(let output): return output.textContent()
        case .backendToolCall(let b): return b.textSummary()
        case .reasoning(let r): return reasoningItemText(r)
        }
    }

    /// Set the model ID if this is an assistant message. No-op for other
    /// types.
    public func withModelId(_ modelId: String) -> Self {
        switch self {
        case .assistant(var a):
            a.modelId = modelId
            return .assistant(a)
        default:
            return self
        }
    }

    /// Mark this message as the genuine user turn that directly followed a
    /// user-interrupted turn. No-op for any non-`User` variant.
    public mutating func setPriorTurnInterrupt(_ interrupt: PriorTurnInterrupt) {
        if case .user(var u) = self {
            u.priorTurnInterrupt = interrupt
            self = .user(u)
        }
    }

    /// Record the prompt-turn index this user item starts. No-op for any
    /// non-`User` variant.
    public mutating func setPromptIndex(_ promptIndex: Int) {
        if case .user(var u) = self {
            u.promptIndex = promptIndex
            self = .user(u)
        }
    }
}

// MARK: - Free helpers

/// Bounded provider-neutral context used until the selected transport restores
/// a provider-native search item, if that provider supports one.
public let PROVIDER_NATIVE_SEARCH_REPLAY_SUMMARY =
    "[A provider-native search was completed earlier in the conversation.]"

/// Reconstruct xAI's current provider-native hosted X-search item for replay.
/// The typed dependency only knows the older `CustomToolCall` carrier, so the
/// sampler splices this value back into the serialized input at the same
/// index.
public func xSearchCallWireValue(_ call: CustomToolCall) -> JSONValue {
    var value: [String: JSONValue] = [
        "type": .string("x_search_call"),
        "id": .string(call.id),
        "status": .string("completed"),
    ]
    if !call.callId.isEmpty {
        value["call_id"] = .string(call.callId)
    }
    if !call.name.isEmpty {
        value["name"] = .string(call.name)
    }
    if !call.input.isEmpty {
        value["arguments"] = .string(call.input)
        if let action = try? JSONDecoder().decode(JSONValue.self, from: Data(call.input.utf8)) {
            value["action"] = action
        }
    }
    return .object(value)
}

/// Build a bounded plaintext tail for a later provider switch.
///
/// OpenAI's compact item is encrypted provider state and cannot be consumed
/// by xAI. Keep a recent, role-labelled transcript alongside it locally so a
/// switch does not silently reduce the entire prior conversation to a marker.
/// Hidden reasoning and provider tool plumbing are omitted.
public func codexCrossProviderFallback(items: [ConversationItem], maxChars: Int) -> String {
    let header = "[Provider-neutral context from before OpenAI compaction. Older details may have been condensed; recent transcript follows.]"
    if maxChars == 0 { return "" }

    let headerPrefix = String(header.prefix(maxChars))
    var remaining = maxChars.subtractingWithSaturate(headerPrefix.count)
    var recentBlocks: [String] = []
    for item in items.reversed() {
        let label: String?
        switch item {
        case .system, .reasoning:
            continue
        case .user: label = "User"
        case .assistant: label = "Assistant"
        case .toolResult, .customToolOutput: label = "Tool"
        case .backendToolCall(let b):
            if case .codexRawInput(let raw) = b.kind, raw.crossProviderFallback != nil {
                label = "Prior compacted context"
            } else {
                continue
            }
        }
        guard let label else { continue }
        let text = item.textContent()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        let block = "\(label):\n\(text)"
        let separatorCost = 2
        if remaining <= separatorCost { break }
        remaining = remaining.subtractingWithSaturate(separatorCost)
        let blockChars = block.count
        if blockChars <= remaining {
            recentBlocks.append(block)
            remaining = remaining.subtractingWithSaturate(blockChars)
        } else {
            let suffix = String(block.suffix(remaining.subtractingWithSaturate(25)))
            recentBlocks.append("[Earlier text truncated]\n\(suffix)")
            break
        }
    }
    recentBlocks.reverse()
    if recentBlocks.isEmpty {
        return headerPrefix
    }
    let joined = recentBlocks.joined(separator: "\n\n")
    let combined = "\(headerPrefix)\n\n\(joined)"
    return String(combined.prefix(maxChars))
}

// MARK: - Saturating subtraction helper

fileprivate extension Int {
    func subtractingWithSaturate(_ other: Int) -> Int {
        let (diff, overflow) = self.subtractingReportingOverflow(other)
        return overflow ? 0 : diff
    }
}
