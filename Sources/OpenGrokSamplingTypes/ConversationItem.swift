// ConversationItem.swift
//
// Open Grok — Swift port of the API-agnostic conversation representation in
// `crates/codegen/xai-grok-sampling-types/src/conversation.rs`.
//
// `ConversationItem` is the unified internal representation that can be
// converted to either the Chat Completions API, the Responses API, or the
// Anthropic Messages API. It is provider-neutral: opaque backend items are
// retained typed and tagged by backend/dialect so replay round-trips
// byte-stably.
//
// The Rust source wraps `async_openai::types::responses` (`rs::ReasoningItem`,
// `rs::WebSearchToolCall`, etc.) for the native Responses items. Swift has no
// async-openai equivalent, so the port defines equivalent Codable types here
// that preserve the opaque wire structure — the "typed opaque history tagged
// by backend/dialect" the W1-S3 acceptance criteria require.

import Foundation
import OpenGrokShared

// MARK: - Role

/// Conversation role, mirroring Rust `Role`. Wire form: lowercase.
public enum Role: String, Codable, Sendable, Equatable, Hashable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - ContentPart / CustomToolOutputContent

/// A part of message content - text, image, etc.
///
/// Wire form: internally tagged by `type`, snake_case, mirroring Rust
/// `#[serde(tag = "type", rename_all = "snake_case")]`.
public enum ContentPart: Codable, Sendable, Equatable, Hashable {
    case text(text: String)
    case image(url: String)

    public enum CodingKeys: String, CodingKey { case type, text, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try c.decode(String.self, forKey: .text)
            self = .text(text: text)
        case "image":
            let url = try c.decode(String.self, forKey: .url)
            self = .image(url: url)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown ContentPart type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let url):
            try c.encode("image", forKey: .type)
            try c.encode(url, forKey: .url)
        }
    }
}

/// Image fidelity for a custom-tool output. Wire form: lowercase. `auto` is
/// the default, matching the API.
public enum CustomToolOutputImageDetail: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    case auto
    case low
    case high
    case original

    public static let defaultValue: CustomToolOutputImageDetail = .auto
}

/// Ordered content carried by a native custom-tool output.
public enum CustomToolOutputContent: Codable, Sendable, Equatable, Hashable {
    case text(text: String)
    case image(url: String, detail: CustomToolOutputImageDetail)

    public enum CodingKeys: String, CodingKey { case type, text, url, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(text: try c.decode(String.self, forKey: .text))
        case "image":
            let url = try c.decode(String.self, forKey: .url)
            let detail = try c.decodeIfPresent(CustomToolOutputImageDetail.self, forKey: .detail) ?? .auto
            self = .image(url: url, detail: detail)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown CustomToolOutputContent type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let url, let detail):
            try c.encode("image", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(detail, forKey: .detail)
        }
    }

    public static func text(_ text: String) -> Self { .text(text: text) }
    public static func image(_ url: String, _ detail: CustomToolOutputImageDetail) -> Self {
        .image(url: url, detail: detail)
    }
}

// MARK: - SyntheticReason / PriorTurnInterrupt

/// Why a `UserItem` was synthesized by the runtime rather than typed by a
/// real user. Wire form: `snake_case`. Unknown variants deserialize as
/// `.unknown` so old clients can still read sessions written by newer
/// versions.
public enum SyntheticReason: String, Codable, Sendable, Equatable, Hashable {
    case compactionMeta
    case systemReminder
    case projectInstructions
    case autoContinue
    case autoRecovery
    case interjection
    case taskCompleted
    case subagentCompleted
    case notificationDrain
    case goalSummary
    case goalClassifierNudge
    case schedulerFired
    /// Mailbox message routed from another agent in the same collaboration
    /// team. Wakes the agent. Model-authored input, never user consent.
    /// Rust `SyntheticReason::AgentMessage`
    /// (`xai-grok-sampling-types/src/conversation.rs:126-128`, commit
    /// aa39b8cf) — tagged distinctly from `subagentCompleted` so trace
    /// tooling and compaction can tell peer traffic from lifecycle auto-wakes.
    case agentMessage
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Mirror Rust `#[serde(other)]`: unknown variants collapse to .unknown.
        self = SyntheticReason(rawValue: raw) ?? .unknown
    }

    /// Whether a user item with this reason **starts a prompt turn** — i.e.
    /// the turn pipeline pushed it while consuming a `prompt_index` slot.
    public var startsPromptTurn: Bool {
        switch self {
        case .taskCompleted, .subagentCompleted, .notificationDrain,
             .goalClassifierNudge, .schedulerFired, .agentMessage:
            return true
        case .compactionMeta, .systemReminder, .projectInstructions,
             .autoContinue, .autoRecovery, .interjection,
             .goalSummary, .unknown:
            return false
        }
    }
}

/// How the user *fatally* interrupted (cancelled) the turn immediately
/// preceding this *real* user message. Wire form: `snake_case`. Unknown
/// variants deserialize as `.unknown` for forward compatibility.
public enum PriorTurnInterrupt: String, Codable, Sendable, Equatable, Hashable {
    case midTurnAbort
    case permissionRejected
    case permissionCancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = PriorTurnInterrupt(rawValue: raw) ?? .unknown
    }
}

// MARK: - Item structs

/// System message content.
public struct SystemItem: Codable, Sendable, Equatable, Hashable {
    public var content: String

    public init(content: String) { self.content = content }
}

/// User message with text and optional images.
public struct UserItem: Codable, Sendable, Equatable, Hashable {
    public var content: [ContentPart]
    public var syntheticReason: SyntheticReason?
    public var priorTurnInterrupt: PriorTurnInterrupt?
    public var promptIndex: Int?

    public init(
        content: [ContentPart],
        syntheticReason: SyntheticReason? = nil,
        priorTurnInterrupt: PriorTurnInterrupt? = nil,
        promptIndex: Int? = nil
    ) {
        self.content = content
        self.syntheticReason = syntheticReason
        self.priorTurnInterrupt = priorTurnInterrupt
        self.promptIndex = promptIndex
    }

    public enum CodingKeys: String, CodingKey {
        case content
        case syntheticReason = "synthetic_reason"
        case priorTurnInterrupt = "prior_turn_interrupt"
        case promptIndex = "prompt_index"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try c.decode([ContentPart].self, forKey: .content)
        self.syntheticReason = try c.decodeIfPresent(SyntheticReason.self, forKey: .syntheticReason)
        self.priorTurnInterrupt = try c.decodeIfPresent(PriorTurnInterrupt.self, forKey: .priorTurnInterrupt)
        self.promptIndex = try c.decodeIfPresent(Int.self, forKey: .promptIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(syntheticReason, forKey: .syntheticReason)
        try c.encodeIfPresent(priorTurnInterrupt, forKey: .priorTurnInterrupt)
        try c.encodeIfPresent(promptIndex, forKey: .promptIndex)
    }

    /// Add an image to this user message.
    public mutating func addImage(_ url: String) {
        content.append(.image(url: url))
    }
}

/// Assistant response with tool calls. Reasoning items, when present, sit
/// beside this item as `.reasoning(_)` siblings preceding the assistant
/// turn — not bundled here.
public struct AssistantItem: Codable, Sendable, Equatable, Hashable {
    public var content: String
    public var toolCalls: [ToolCall]
    public var modelId: String?
    public var modelFingerprint: String?
    public var reasoningEffort: ReasoningEffort?

    public init(
        content: String,
        toolCalls: [ToolCall] = [],
        modelId: String? = nil,
        modelFingerprint: String? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.modelId = modelId
        self.modelFingerprint = modelFingerprint
        self.reasoningEffort = reasoningEffort
    }

    public enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
        case modelId = "model_id"
        case modelFingerprint = "model_fingerprint"
        case reasoningEffort = "reasoning_effort"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try c.decode(String.self, forKey: .content)
        self.toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        self.modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        // `system_fingerprint` alias for legacy compatibility, plus
        // empty-string-as-none normalization.
        if let fp = try c.decodeIfPresent(String.self, forKey: .modelFingerprint) {
            self.modelFingerprint = fp.isEmpty ? nil : fp
        } else {
            // Try the legacy `system_fingerprint` alias.
            var legacyFp: String? = nil
            if let legacyContainer = try? decoder.container(keyedBy: LegacyCodingKeys.self) {
                legacyFp = try? legacyContainer.decodeIfPresent(String.self, forKey: .systemFingerprint)
            }
            if let fp = legacyFp, !fp.isEmpty {
                self.modelFingerprint = fp
            } else {
                self.modelFingerprint = nil
            }
        }
        self.reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(toolCalls.isEmpty ? nil : toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(modelId, forKey: .modelId)
        try c.encodeIfPresent(modelFingerprint, forKey: .modelFingerprint)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case systemFingerprint = "system_fingerprint"
    }

    /// Add a tool call to this assistant message.
    public mutating func addToolCall(_ call: ToolCall) {
        toolCalls.append(call)
    }

    /// Set the model ID, builder-style.
    public func withModelId(_ modelId: String) -> Self {
        var copy = self
        copy.modelId = modelId
        return copy
    }
}

/// Tool result message.
public struct ToolResultItem: Codable, Sendable, Equatable, Hashable {
    public var toolCallId: String
    public var content: String
    public var images: [ContentPart]
    public var orderedContent: [CustomToolOutputContent]

    public init(
        toolCallId: String,
        content: String,
        images: [ContentPart] = [],
        orderedContent: [CustomToolOutputContent] = []
    ) {
        self.toolCallId = toolCallId
        self.content = content
        self.images = images
        self.orderedContent = orderedContent
    }

    public enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case content, images
        case orderedContent = "ordered_content"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.toolCallId = try c.decode(String.self, forKey: .toolCallId)
        self.content = try c.decode(String.self, forKey: .content)
        self.images = try c.decodeIfPresent([ContentPart].self, forKey: .images) ?? []
        self.orderedContent = try c.decodeIfPresent([CustomToolOutputContent].self, forKey: .orderedContent) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolCallId, forKey: .toolCallId)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(images.isEmpty ? nil : images, forKey: .images)
        try c.encodeIfPresent(orderedContent.isEmpty ? nil : orderedContent, forKey: .orderedContent)
    }
}

/// One native Responses custom-tool-call output.
public struct CustomToolOutputItem: Codable, Sendable, Equatable, Hashable {
    public var callId: String
    public var itemId: String?
    public var name: String?
    public var content: [CustomToolOutputContent]

    public init(callId: String, itemId: String? = nil, name: String? = nil, content: [CustomToolOutputContent]) {
        self.callId = callId
        self.itemId = itemId
        self.name = name
        self.content = content
    }

    public enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case itemId = "item_id"
        case name, content
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.callId = try c.decode(String.self, forKey: .callId)
        self.itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.content = try c.decode([CustomToolOutputContent].self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(callId, forKey: .callId)
        try c.encodeIfPresent(itemId, forKey: .itemId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(content, forKey: .content)
    }

    /// Construct an output with no provider item ID or tool-name metadata.
    public init(callId: String, content: [CustomToolOutputContent]) {
        self.callId = callId
        self.itemId = nil
        self.name = nil
        self.content = content
    }

    /// Construct a text-only output.
    public static func text(callId: String, _ text: String) -> Self {
        Self(callId: callId, content: [.text(text: text)])
    }

    public func withItemId(_ itemId: String) -> Self {
        var copy = self
        copy.itemId = itemId
        return copy
    }

    public func withName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }

    /// Flatten text blocks for display/token-estimation without disturbing
    /// the stored block order.
    public func textContent() -> String {
        content.compactMap { part in
            switch part {
            case .text(let text): return text
            case .image: return nil
            }
        }.joined(separator: "\n")
    }
}

// MARK: - ToolCall / ToolCallKind

/// The transport shape of a client-executed tool call. Function calls carry
/// JSON-encoded arguments; custom calls carry the raw free-form input
/// produced by the Responses API.
public enum ToolCallKind: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    case function
    case custom

    public static let defaultValue: ToolCallKind = .function
}

/// A tool call made by the assistant that the client must execute locally.
public struct ToolCall: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// The opaque legacy custom-call identity prefix used to encode both the
    /// provider call ID and the Responses output-item ID into `id`.
    private static let customToolCallIdPrefix = "__xai_custom_tool_call__"

    /// Construct a native Responses custom-tool call while preserving both the
    /// API `call_id` and output-item `id` for byte-stable replay.
    public static func custom(
        callId: String,
        itemId: String,
        name: String,
        input: String
    ) -> Self {
        Self(
            id: encodeCustomToolCallId(callId: callId, itemId: itemId),
            name: name,
            arguments: input
        )
    }

    /// Encode the opaque legacy custom-call identity.
    private static func encodeCustomToolCallId(callId: String, itemId: String) -> String {
        "\(customToolCallIdPrefix)\(callId.count):\(callId)\(itemId)"
    }

    /// Decode the opaque legacy custom-call identity used in generic
    /// tool-result rows. Returns `(callId, itemId)` or `nil`.
    public static func decodeCustomToolCallId(_ value: String) -> (callId: String, itemId: String)? {
        guard value.hasPrefix(customToolCallIdPrefix) else { return nil }
        let encoded = String(value.dropFirst(customToolCallIdPrefix.count))
        guard let colonIdx = encoded.firstIndex(of: ":") else { return nil }
        let lenStr = String(encoded[encoded.startIndex..<colonIdx])
        guard let callIdLen = Int(lenStr) else { return nil }
        let payload = String(encoded[encoded.index(after: colonIdx)...])
        // UTF-8 boundary-safe split (Rust uses `is_char_boundary`).
        guard payload.utf8.count >= callIdLen else { return nil }
        let splitIdx = payload.utf8.index(payload.utf8.startIndex, offsetBy: callIdLen)
        let callId = String(decoding: payload.utf8[..<splitIdx], as: UTF8.self)
        let itemId = String(decoding: payload.utf8[splitIdx...], as: UTF8.self)
        return (callId, itemId)
    }

    public var kind: ToolCallKind {
        ToolCall.decodeCustomToolCallId(id) != nil ? .custom : .function
    }

    public var isCustom: Bool { kind == .custom }

    /// The provider call ID. For ordinary function calls this is the stored
    /// ID; for custom calls it is decoded from the compatibility envelope.
    public var callId: String {
        ToolCall.decodeCustomToolCallId(id)?.callId ?? id
    }

    /// The Responses output-item ID for a custom call.
    public var customItemId: String? {
        ToolCall.decodeCustomToolCallId(id)?.itemId
    }

    /// Raw custom-tool input. Function calls return `nil` because their
    /// `arguments` field is JSON rather than free-form text.
    public var customInput: String? {
        isCustom ? arguments : nil
    }
}

// MARK: - ToolSpec / CustomToolSpec / ClientTool

/// Tool/function definition for the model.
public struct ToolSpec: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue

    public init(name: String, description: String?, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A native Responses custom tool. Unlike `ToolSpec`, its input is free-form
/// text optionally constrained by a grammar.
public struct CustomToolSpec: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var description: String?
    public var format: CustomToolParamFormat

    public init(name: String, description: String?, format: CustomToolParamFormat = .string) {
        self.name = name
        self.description = description
        self.format = format
    }
}

/// Wire format for a native custom-tool parameter. Mirrors the Responses API
/// `CustomToolParamFormat` enum. Default is `.string`.
public enum CustomToolParamFormat: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    case string
    case grammar

    public static let defaultValue: CustomToolParamFormat = .string
}

/// A client-executed tool declaration. Existing callers can continue using
/// `ToolSpec` and `ConversationRequest.tools`; code-mode callers use this
/// enum to add native Responses custom tools without changing function-tool
/// behavior on Chat Completions or Messages backends.
public enum ClientTool: Codable, Sendable, Equatable, Hashable {
    case function(name: String, description: String?, parameters: JSONValue)
    case custom(name: String, description: String?, format: CustomToolParamFormat)

    public enum CodingKeys: String, CodingKey { case type, name, description, parameters, format }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "function":
            self = .function(
                name: try c.decode(String.self, forKey: .name),
                description: try c.decodeIfPresent(String.self, forKey: .description),
                parameters: try c.decode(JSONValue.self, forKey: .parameters)
            )
        case "custom":
            self = .custom(
                name: try c.decode(String.self, forKey: .name),
                description: try c.decodeIfPresent(String.self, forKey: .description),
                format: try c.decodeIfPresent(CustomToolParamFormat.self, forKey: .format) ?? .string
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown ClientTool type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .function(let name, let description, let parameters):
            try c.encode("function", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encode(parameters, forKey: .parameters)
        case .custom(let name, let description, let format):
            try c.encode("custom", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encode(format, forKey: .format)
        }
    }

    public var name: String {
        switch self {
        case .function(let name, _, _): return name
        case .custom(let name, _, _): return name
        }
    }
}

extension ToolSpec {
    /// Convenience to convert a `ToolSpec` to a `ClientTool.function`.
    public func asClientTool() -> ClientTool {
        .function(name: name, description: description, parameters: parameters)
    }
}

extension CustomToolSpec {
    /// Convenience to convert a `CustomToolSpec` to a `ClientTool.custom`.
    public func asClientTool() -> ClientTool {
        .custom(name: name, description: description, format: format)
    }
}
