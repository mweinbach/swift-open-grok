// UsageTests.swift
//
// Open Grok — Tests for token usage prompt cache hit rate helpers in OpenGrokSamplingTypes.
// Mirrors Rust unit tests in `crates/codegen/xai-grok-sampling-types/src/conversation.rs`.

import Foundation
import Testing
@testable import OpenGrokSamplingTypes

@Suite("TokenUsage and Usage Prompt Cache Hit Rate Tests")
struct UsageCacheHitRateTests {
    @Test("TokenUsage cache hit rate calculations")
    func tokenUsageCacheHitRate() {
        let empty = TokenUsage()
        #expect(empty.cacheHitRate == nil)
        #expect(empty.cacheHitRatePct == 0.0)

        let zeroCached = TokenUsage(
            promptTokens: 100,
            completionTokens: 20,
            totalTokens: 120,
            reasoningTokens: 0,
            cachedPromptTokens: 0
        )
        #expect(zeroCached.cacheHitRate == 0.0)
        #expect(zeroCached.cacheHitRatePct == 0.0)

        let partial = TokenUsage(
            promptTokens: 100,
            completionTokens: 20,
            totalTokens: 120,
            reasoningTokens: 0,
            cachedPromptTokens: 75
        )
        #expect(partial.cacheHitRate == 75.0)
        #expect(partial.cacheHitRatePct == 75.0)

        let full = TokenUsage(
            promptTokens: 100,
            completionTokens: 20,
            totalTokens: 120,
            reasoningTokens: 0,
            cachedPromptTokens: 100
        )
        #expect(full.cacheHitRate == 100.0)
        #expect(full.cacheHitRatePct == 100.0)
    }

    @Test("PromptUsageModel cache hit rate calculations")
    func promptUsageModelCacheHitRate() {
        let empty = PromptUsageModel()
        #expect(empty.cacheHitRate == nil)
        #expect(empty.cacheHitRatePct == 0.0)

        let zeroCached = PromptUsageModel(
            inputTokens: 100,
            outputTokens: 20,
            totalTokens: 120,
            cachedReadTokens: 0
        )
        #expect(zeroCached.cacheHitRate == 0.0)
        #expect(zeroCached.cacheHitRatePct == 0.0)

        let partial = PromptUsageModel(
            inputTokens: 100,
            outputTokens: 20,
            totalTokens: 120,
            cachedReadTokens: 75
        )
        #expect(partial.cacheHitRate == 75.0)
        #expect(partial.cacheHitRatePct == 75.0)

        let full = PromptUsageModel(
            inputTokens: 100,
            outputTokens: 20,
            totalTokens: 120,
            cachedReadTokens: 100
        )
        #expect(full.cacheHitRate == 100.0)
        #expect(full.cacheHitRatePct == 100.0)
    }
}
