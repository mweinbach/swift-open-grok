// Usage.swift
//
// Open Grok — Swift port of token usage statistics and aggregations in
// `crates/codegen/xai-grok-sampling-types/src/conversation.rs`,
// `crates/codegen/xai-chat-state/src/usage.rs`, and
// `crates/codegen/xai-grok-shell/src/extensions/notification.rs`.

import Foundation

extension TokenUsage {
    /// Cache hit rate as a percentage (0.0 to 100.0), or `nil` if `promptTokens == 0`.
    public var cacheHitRate: Double? {
        guard promptTokens > 0 else { return nil }
        return (Double(cachedPromptTokens) / Double(promptTokens)) * 100.0
    }

    /// Cache hit rate percentage, defaulting to `0.0` if `promptTokens == 0`.
    public var cacheHitRatePct: Double {
        cacheHitRate ?? 0.0
    }
}

/// Projected prompt usage model reported via ACP and notification envelopes.
public struct PromptUsageModel: Codable, Sendable, Equatable, Hashable {
    public var inputTokens: UInt64
    public var outputTokens: UInt64
    public var totalTokens: UInt64
    public var cachedReadTokens: UInt64
    public var cacheCreationTokens: UInt64
    public var reasoningTokens: UInt64
    public var modelCalls: UInt64
    public var apiDurationMs: UInt64
    /// USD ticks (1e10 per USD). `nil` when no call reported cost.
    public var costUsdTicks: Int64?
    public var costIsPartial: Bool
    public var costMissingCalls: UInt64

    public init(
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        totalTokens: UInt64 = 0,
        cachedReadTokens: UInt64 = 0,
        cacheCreationTokens: UInt64 = 0,
        reasoningTokens: UInt64 = 0,
        modelCalls: UInt64 = 0,
        apiDurationMs: UInt64 = 0,
        costUsdTicks: Int64? = nil,
        costIsPartial: Bool = false,
        costMissingCalls: UInt64 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedReadTokens = cachedReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.modelCalls = modelCalls
        self.apiDurationMs = apiDurationMs
        self.costUsdTicks = costUsdTicks
        self.costIsPartial = costIsPartial
        self.costMissingCalls = costMissingCalls
    }

    /// Cache hit rate as a percentage (0.0 to 100.0), or `nil` if `inputTokens == 0`.
    public var cacheHitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return (Double(cachedReadTokens) / Double(inputTokens)) * 100.0
    }

    /// Cache hit rate percentage, defaulting to `0.0` if `inputTokens == 0`.
    public var cacheHitRatePct: Double {
        cacheHitRate ?? 0.0
    }
}
