// ConversationRequest.swift
//
// Open Grok — Swift port of `ConversationRequest`, `ConversationResponse`,
// `TokenUsage`, `StopReason`, and the hosted-tool / tool-choice types in
// `crates/codegen/xai-grok-sampling-types/src/conversation.rs` and `types.rs`.
//
// `ConversationRequest` is the provider-neutral request that downstream
// consumers (the sampler, session runtime) build and send to whichever
// backend the active `SamplingConfig` selects. `ConversationResponse` is the
// provider-neutral normalized result. `TokenUsage` is the normalized usage
// shape that preserves input, cached input, output, and reasoning across all
// three backends — the W1-S3 acceptance criterion.

import Foundation
import OpenGrokShared

// MARK: - Usage / TokenUsage

/// Per-response token usage from the Chat Completions API. Mirrors Rust
/// `Usage` in `types.rs`. The `TokenUsage` normalized shape below folds
/// `cached_tokens` and `reasoning_tokens` out of the `*_details` sub-objects.
public struct Usage: Codable, Sendable, Equatable, Hashable {
    public var promptTokens: UInt32
    public var completionTokens: UInt32
    public var totalTokens: UInt32
    public var promptTokensDetails: PromptTokensDetails?
    public var completionTokensDetails: CompletionTokensDetails?
    /// xAI extension: request price in USD ticks (1 USD = 1e10 ticks).
    public var costInUsdTicks: Int64?

    public init(
        promptTokens: UInt32,
        completionTokens: UInt32,
        totalTokens: UInt32,
        promptTokensDetails: PromptTokensDetails? = nil,
        completionTokensDetails: CompletionTokensDetails? = nil,
        costInUsdTicks: Int64? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptTokensDetails = promptTokensDetails
        self.completionTokensDetails = completionTokensDetails
        self.costInUsdTicks = costInUsdTicks
    }

    public enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case costInUsdTicks = "cost_in_usd_ticks"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.promptTokens = try c.decode(UInt32.self, forKey: .promptTokens)
        self.completionTokens = try c.decode(UInt32.self, forKey: .completionTokens)
        self.totalTokens = try c.decode(UInt32.self, forKey: .totalTokens)
        self.promptTokensDetails = try c.decodeIfPresent(PromptTokensDetails.self, forKey: .promptTokensDetails)
        self.completionTokensDetails = try c.decodeIfPresent(CompletionTokensDetails.self, forKey: .completionTokensDetails)
        self.costInUsdTicks = try c.decodeIfPresent(Int64.self, forKey: .costInUsdTicks)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(completionTokens, forKey: .completionTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
        try c.encodeIfPresent(promptTokensDetails, forKey: .promptTokensDetails)
        try c.encodeIfPresent(completionTokensDetails, forKey: .completionTokensDetails)
        try c.encodeIfPresent(costInUsdTicks, forKey: .costInUsdTicks)
    }
}

public struct PromptTokensDetails: Codable, Sendable, Equatable, Hashable {
    public var cachedTokens: UInt32
    public var audioTokens: UInt32

    public init(cachedTokens: UInt32 = 0, audioTokens: UInt32 = 0) {
        self.cachedTokens = cachedTokens
        self.audioTokens = audioTokens
    }

    public enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
        case audioTokens = "audio_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cachedTokens = try c.decodeIfPresent(UInt32.self, forKey: .cachedTokens) ?? 0
        self.audioTokens = try c.decodeIfPresent(UInt32.self, forKey: .audioTokens) ?? 0
    }
}

public struct CompletionTokensDetails: Codable, Sendable, Equatable, Hashable {
    public var reasoningTokens: UInt32
    public var audioTokens: UInt32
    public var acceptedPredictionTokens: UInt32
    public var rejectedPredictionTokens: UInt32

    public init(
        reasoningTokens: UInt32 = 0,
        audioTokens: UInt32 = 0,
        acceptedPredictionTokens: UInt32 = 0,
        rejectedPredictionTokens: UInt32 = 0
    ) {
        self.reasoningTokens = reasoningTokens
        self.audioTokens = audioTokens
        self.acceptedPredictionTokens = acceptedPredictionTokens
        self.rejectedPredictionTokens = rejectedPredictionTokens
    }

    public enum CodingKeys: String, CodingKey {
        case reasoningTokens = "reasoning_tokens"
        case audioTokens = "audio_tokens"
        case acceptedPredictionTokens = "accepted_prediction_tokens"
        case rejectedPredictionTokens = "rejected_prediction_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.reasoningTokens = try c.decodeIfPresent(UInt32.self, forKey: .reasoningTokens) ?? 0
        self.audioTokens = try c.decodeIfPresent(UInt32.self, forKey: .audioTokens) ?? 0
        self.acceptedPredictionTokens = try c.decodeIfPresent(UInt32.self, forKey: .acceptedPredictionTokens) ?? 0
        self.rejectedPredictionTokens = try c.decodeIfPresent(UInt32.self, forKey: .rejectedPredictionTokens) ?? 0
    }
}

/// Normalized token usage statistics, unified across OpenAI Chat Completions,
/// OpenAI Responses, and Anthropic Messages backends.
///
/// `promptTokens` is always the FULL prompt size (uncached + cache reads +
/// cache writes) and `cachedPromptTokens` is only the cache-hit subset; do
/// not subtract. Cache writes (`cache_creation_input_tokens`, billed at
/// ~1.25x) are folded into `promptTokens`, not into `cachedPromptTokens`.
public struct TokenUsage: Codable, Sendable, Equatable, Hashable {
    public var promptTokens: UInt32
    public var completionTokens: UInt32
    public var totalTokens: UInt32
    public var reasoningTokens: UInt32
    /// Prompt tokens served from cache (the cache-hit subset).
    public var cachedPromptTokens: UInt32

    public init(
        promptTokens: UInt32 = 0,
        completionTokens: UInt32 = 0,
        totalTokens: UInt32 = 0,
        reasoningTokens: UInt32 = 0,
        cachedPromptTokens: UInt32 = 0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.reasoningTokens = reasoningTokens
        self.cachedPromptTokens = cachedPromptTokens
    }

    public enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case reasoningTokens = "reasoning_tokens"
        case cachedPromptTokens = "cached_prompt_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.promptTokens = try c.decode(UInt32.self, forKey: .promptTokens)
        self.completionTokens = try c.decode(UInt32.self, forKey: .completionTokens)
        self.totalTokens = try c.decode(UInt32.self, forKey: .totalTokens)
        self.reasoningTokens = try c.decodeIfPresent(UInt32.self, forKey: .reasoningTokens) ?? 0
        self.cachedPromptTokens = try c.decodeIfPresent(UInt32.self, forKey: .cachedPromptTokens) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(completionTokens, forKey: .completionTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
        try c.encodeIfPresent(reasoningTokens == 0 ? nil : reasoningTokens, forKey: .reasoningTokens)
        try c.encodeIfPresent(cachedPromptTokens == 0 ? nil : cachedPromptTokens, forKey: .cachedPromptTokens)
    }

    /// Construct from a Chat Completions `Usage` value.
    public init(from usage: Usage) {
        let cached = usage.promptTokensDetails?.cachedTokens ?? 0
        let reasoning = usage.completionTokensDetails?.reasoningTokens ?? 0
        self.init(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            totalTokens: usage.totalTokens,
            reasoningTokens: reasoning,
            cachedPromptTokens: cached
        )
    }
}

// MARK: - StopReason / FinishReason

/// Why the model stopped generating (provider-neutral).
public enum StopReason: String, Codable, Sendable, Equatable, Hashable {
    case stop
    case length
    case toolCalls
    case contentFilter

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // snake_case mapping for `tool_calls` / `content_filter`.
        switch raw {
        case "stop": self = .stop
        case "length": self = .length
        case "tool_calls": self = .toolCalls
        case "content_filter": self = .contentFilter
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown StopReason: \(raw)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .stop: try container.encode("stop")
        case .length: try container.encode("length")
        case .toolCalls: try container.encode("tool_calls")
        case .contentFilter: try container.encode("content_filter")
        }
    }
}

/// Finish reason from the Chat Completions API.
public enum FinishReason: String, Codable, Sendable, Equatable, Hashable {
    case stop
    case length
    case toolCalls
    case contentFilter
    case functionCall

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "stop": self = .stop
        case "length": self = .length
        case "tool_calls": self = .toolCalls
        case "content_filter": self = .contentFilter
        case "function_call": self = .functionCall
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown FinishReason: \(raw)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .stop: try container.encode("stop")
        case .length: try container.encode("length")
        case .toolCalls: try container.encode("tool_calls")
        case .contentFilter: try container.encode("content_filter")
        case .functionCall: try container.encode("function_call")
        }
    }
}

extension StopReason {
    public init(from finishReason: FinishReason) {
        switch finishReason {
        case .stop: self = .stop
        case .length: self = .length
        case .toolCalls, .functionCall: self = .toolCalls
        case .contentFilter: self = .contentFilter
        }
    }
}

// MARK: - ConversationToolChoice

/// Tool choice options for a `ConversationRequest`.
public enum ConversationToolChoice: Codable, Sendable, Equatable, Hashable {
    case auto
    case none
    case required
    case function(String)
    case custom(String)

    public enum CodingKeys: String, CodingKey { case type, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "auto": self = .auto
        case "none": self = .none
        case "required": self = .required
        case "function": self = .function(try c.decode(String.self, forKey: .name))
        case "custom": self = .custom(try c.decode(String.self, forKey: .name))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown ConversationToolChoice: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto: try c.encode("auto", forKey: .type)
        case .none: try c.encode("none", forKey: .type)
        case .required: try c.encode("required", forKey: .type)
        case .function(let name):
            try c.encode("function", forKey: .type)
            try c.encode(name, forKey: .name)
        case .custom(let name):
            try c.encode("custom", forKey: .type)
            try c.encode(name, forKey: .name)
        }
    }
}

// MARK: - HostedTool

/// How the backend exposes web search.
public enum WebSearchMode: Sendable, Equatable, Hashable {
    case disabled
    case cached
    case indexed
    case live
}

public enum WebSearchContextSize: Sendable, Equatable, Hashable {
    case low, medium, high
}

/// Approximate location hints accepted by OpenAI's hosted web search tool.
public struct WebSearchUserLocation: Sendable, Equatable, Hashable {
    public var country: String?
    public var region: String?
    public var city: String?
    public var timezone: String?

    public init(country: String? = nil, region: String? = nil, city: String? = nil, timezone: String? = nil) {
        self.country = country
        self.region = region
        self.city = city
        self.timezone = timezone
    }
}

/// A tool that the backend executes server-side during inference. The client
/// sends these as native Responses API tool types (not Function).
public enum HostedTool: Sendable, Equatable, Hashable {
    /// Web search executed server-side by the backend's agentic sampler.
    case webSearch(
        mode: WebSearchMode?,
        allowedDomains: [String]?,
        userLocation: WebSearchUserLocation?,
        searchContextSize: WebSearchContextSize?,
        searchContentTypes: [String]?
    )
    /// xAI server-side X/Twitter search.
    case xSearch
    /// Compatibility storage for a client-executed native Responses custom
    /// tool.
    case clientCustom(CustomToolSpec)

    /// The name the backend registers this tool under server-side.
    public var wireName: String {
        switch self {
        case .webSearch: return "web_search"
        case .xSearch: return "x_search"
        case .clientCustom(let tool): return tool.name
        }
    }
}

extension HostedTool {
    /// Construct the legacy hosted web-search tool.
    public static func webSearch(allowedDomains: [String]?) -> HostedTool {
        .webSearch(mode: nil, allowedDomains: allowedDomains, userLocation: nil,
                   searchContextSize: nil, searchContentTypes: nil)
    }
}

// MARK: - ConversationRequest

/// A complete conversation request that can be sent to either API.
///
/// This is provider-neutral: the `items` carry opaque backend history
/// tagged by dialect, and the `hostedTools` / `tools` / `toolChoice` are
/// normalized across backends. The sampler layer (W3-S3) is responsible for
/// projecting this request onto the selected backend's wire shape.
public struct ConversationRequest: Sendable, Equatable {
    /// The conversation items (messages).
    public var items: [ConversationItem]
    /// Available tools (client-side, sent as Function definitions).
    public var tools: [ToolSpec]
    /// Backend-hosted tools (sent as native Responses API tool types).
    public var hostedTools: [HostedTool]
    /// Tool choice behavior.
    public var toolChoice: ConversationToolChoice?
    /// Model to use (if not using client default).
    public var model: String?
    /// Sampling temperature.
    public var temperature: Float?
    /// Maximum output tokens.
    public var maxOutputTokens: UInt32?
    /// Top-p sampling.
    public var topP: Float?
    /// Custom headers for xAI tracking.
    public var xGrokConvId: String?
    public var xGrokReqId: String?
    public var xGrokSessionId: String?
    /// Durable prompt-cache identity inherited by verbatim forks. Provider
    /// affinity headers use this override; telemetry keeps `xGrokSessionId`.
    public var xGrokCacheAffinityId: String?
    public var xGrokTurnIdx: String?
    public var xGrokAgentId: String?
    public var xGrokDeploymentId: String?
    public var xGrokUserId: String?
    /// Optional opaque tracing context. Not serialized; carried alongside
    /// the request for the sampler to use at the transport boundary.
    public var trace: TraceContextBox?
    /// Reasoning effort level for reasoning models.
    public var reasoningEffort: ReasoningEffort?
    /// Responses `service_tier` routing id (`"priority"` for Codex Fast mode).
    /// `nil` means standard routing and omits the field from the wire body.
    public var serviceTier: String?
    /// JSON Schema for structured output (strict mode).
    public var jsonSchema: JSONValue?

    public init(
        items: [ConversationItem] = [],
        tools: [ToolSpec] = [],
        hostedTools: [HostedTool] = [],
        toolChoice: ConversationToolChoice? = nil,
        model: String? = nil,
        temperature: Float? = nil,
        maxOutputTokens: UInt32? = nil,
        topP: Float? = nil,
        xGrokConvId: String? = nil,
        xGrokReqId: String? = nil,
        xGrokSessionId: String? = nil,
        xGrokCacheAffinityId: String? = nil,
        xGrokTurnIdx: String? = nil,
        xGrokAgentId: String? = nil,
        xGrokDeploymentId: String? = nil,
        xGrokUserId: String? = nil,
        trace: TraceContextBox? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        serviceTier: String? = nil,
        jsonSchema: JSONValue? = nil
    ) {
        self.items = items
        self.tools = tools
        self.hostedTools = hostedTools
        self.toolChoice = toolChoice
        self.model = model
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.topP = topP
        self.xGrokConvId = xGrokConvId
        self.xGrokReqId = xGrokReqId
        self.xGrokSessionId = xGrokSessionId
        self.xGrokCacheAffinityId = xGrokCacheAffinityId
        self.xGrokTurnIdx = xGrokTurnIdx
        self.xGrokAgentId = xGrokAgentId
        self.xGrokDeploymentId = xGrokDeploymentId
        self.xGrokUserId = xGrokUserId
        self.trace = trace
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.jsonSchema = jsonSchema
    }

    /// Add a client-executed tool while preserving the existing function-tool
    /// storage and backend behavior.
    public mutating func addClientTool(_ tool: ClientTool) {
        switch tool {
        case .function(let name, let description, let parameters):
            tools.append(ToolSpec(name: name, description: description, parameters: parameters))
        case .custom(let name, let description, let format):
            hostedTools.append(.clientCustom(CustomToolSpec(name: name, description: description, format: format)))
        }
    }

    public func withClientTools(_ tools: [ClientTool]) -> Self {
        var copy = self
        for tool in tools { copy.addClientTool(tool) }
        return copy
    }

    /// Names of native custom tools declared on this request.
    public func clientCustomToolNames() -> [String] {
        hostedTools.compactMap { tool in
            if case .clientCustom(let spec) = tool { return spec.name }
            return nil
        }
    }
}

// MARK: - TraceContext (type-erased, cloneable)

/// Object-safe protocol for opaque tracing context attached to requests,
/// mirroring Rust `TraceContext`.
public protocol TraceContext: AnyObject, Sendable {
    /// Clone this trace context into a new `TraceContextBox`.
    func cloneBox() -> TraceContextBox
}

/// A type-erased, cloneable, `Sendable` box around a `TraceContext`.
public final class TraceContextBox: @unchecked Sendable {
    public let value: any TraceContext

    public init(_ value: any TraceContext) {
        self.value = value
    }

    public func clone() -> TraceContextBox {
        value.cloneBox()
    }
}

extension TraceContextBox: Equatable {
    public static func == (lhs: TraceContextBox, rhs: TraceContextBox) -> Bool {
        lhs === rhs
    }
}

extension TraceContextBox: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(value))
    }
}

// MARK: - ConversationResponse

/// Response from a conversation turn.
///
/// `items` is a flat ordered list mirroring the Responses API's
/// `output: Vec<OutputItem>`: interleaved `Reasoning`, `BackendToolCall`,
/// and a single trailing `Assistant` item (which carries the assistant text
/// and any client-executable `FunctionCall`s as `tool_calls`).
public struct ConversationResponse: Sendable, Equatable {
    /// The flat ordered list of items produced by this turn. The trailing
    /// item is always an `Assistant` item (possibly with empty content).
    public var items: [ConversationItem]
    /// Why the model stopped generating.
    public var stopReason: StopReason?
    /// Token usage statistics.
    public var usage: TokenUsage?
    /// Server cost in USD ticks (1 USD = 1e10). `nil` when unreported.
    public var costUsdTicks: Int64?
    /// Number of `AgentMessageChunk` (text-only) streaming events emitted
    /// during this response. Reasoning/thought chunks are NOT counted.
    public var messageChunksEmitted: UInt64
    /// Server-reported doom-loop triggers for this response (Responses API
    /// only, opt-in via the `x-grok-doom-loop-check` header).
    public var doomLoopSignals: [DoomLoopSignal]
    /// Provider-supplied human-readable stop detail, when reported.
    public var stopMessage: String?

    public init(
        items: [ConversationItem],
        stopReason: StopReason? = nil,
        usage: TokenUsage? = nil,
        costUsdTicks: Int64? = nil,
        messageChunksEmitted: UInt64 = 0,
        doomLoopSignals: [DoomLoopSignal] = [],
        stopMessage: String? = nil
    ) {
        self.items = items
        self.stopReason = stopReason
        self.usage = usage
        self.costUsdTicks = costUsdTicks
        self.messageChunksEmitted = messageChunksEmitted
        self.doomLoopSignals = doomLoopSignals
        self.stopMessage = stopMessage
    }

    /// The trailing `Assistant` item, if any.
    public func assistant() -> AssistantItem? {
        items.reversed().first { item in
            if case .assistant = item { return true }
            return false
        }.flatMap { item in
            if case .assistant(let a) = item { return a }
            return nil
        }
    }

    /// Trailing assistant text content, or empty string when the response has
    /// no assistant item (or the assistant carries no text).
    public func assistantText() -> String {
        assistant()?.content ?? ""
    }

    /// Reasoning siblings that precede the trailing `Assistant`, in order.
    public func reasoningItems() -> [ReasoningItem] {
        items.compactMap { item in
            if case .reasoning(let r) = item { return r }
            return nil
        }
    }

    /// Backend-executed tool calls produced by this turn, in emission order.
    public func backendToolItems() -> [ConversationItem] {
        items.filter { item in
            if case .backendToolCall = item { return true }
            return false
        }
    }

    /// Classify why the response is empty, if it is.
    public func emptyReason() -> EmptyReason? {
        guard let a = assistant() else { return .noVisibleContent }
        if !a.content.isEmpty || !a.toolCalls.isEmpty { return nil }
        let hasReasoning = reasoningItems().contains { r in
            !r.summary.isEmpty || r.content != nil || r.encryptedContent != nil
        }
        return hasReasoning ? .reasoningOnly : .noVisibleContent
    }

    /// Check if the response is effectively empty (no content, no tool calls).
    public var isEmpty: Bool { emptyReason() != nil }

    /// Get tool calls from the assistant message, if any.
    public func toolCalls() -> [ToolCall] {
        assistant()?.toolCalls ?? []
    }

    /// Returns the assistant text if `AgentMessageChunk` events were lost
    /// during streaming and a fallback emission is needed.
    public func fallbackText() -> String? {
        if messageChunksEmitted > 0 { return nil }
        let text = assistantText()
        return text.isEmpty ? nil : text
    }
}

/// Normalize a wire cost-ticks value at capture.
///
/// The REST layer backfills `0` for unreported cost, and negative ticks are
/// never valid, so both become `nil` ("unreported", never "free"). Every
/// ingestion path must route through this before storing
/// `ConversationResponse.costUsdTicks`.
public func reportedCostTicks(_ raw: Int64?) -> Int64? {
    raw.flatMap { $0 > 0 ? $0 : nil }
}

// MARK: - Code Mode projection errors

/// Why a provider-aware Code Mode request projection could not produce a
/// valid Responses request.
public enum CodeModeProjectionError: Error, Sendable, Equatable {
    case unsupportedTransport(provider: ModelProvider)
    case unsupportedCustomTool(provider: ModelProvider, name: String)
    case unsupportedCustomToolChoice(provider: ModelProvider, name: String)
    case unsupportedCustomCall(provider: ModelProvider, name: String)
    case orphanCustomOutput(callId: String)
}

// MARK: - Splice helpers for reasoning items

/// Splice a streaming-fallback reasoning text into a `Vec<ConversationItem>`.
///
/// - If any existing `Reasoning` sibling already carries text, leave `items`
///   untouched (the deltas are redundant).
/// - Otherwise, if there is a `Reasoning` sibling with no text, append a
///   `summaryText` part to it.
/// - Otherwise, insert a new `.reasoning(synthesizedReasoningItem(text))`
///   immediately before the trailing `Assistant`.
public func injectStreamingReasoningFallback(items: inout [ConversationItem], text: String) {
    if text.isEmpty { return }
    let anyWithText = items.contains { item in
        if case .reasoning(let r) = item {
            return r.summary.contains { sp in !sp.text.isEmpty }
        }
        return false
    }
    if anyWithText { return }
    if let idx = items.firstIndex(where: { if case .reasoning = $0 { return true }; return false }) {
        if case .reasoning(var r) = items[idx] {
            r.summary.append(.summaryText(text: text))
            items[idx] = .reasoning(r)
        }
        return
    }
    let pos = items.lastIndex(where: { if case .assistant = $0 { return true }; return false }) ?? items.count
    items.insert(.reasoning(synthesizedReasoningItem(text)), at: pos)
}
