import Foundation
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokSampler

@Suite("Messages cache-creation accounting parity")
struct CacheCreationAccountingParityTests {
    private func completedUsage(
        start: MessagesUsage,
        delta: MessageDeltaUsage
    ) async -> TokenUsage? {
        let events: [Result<MessageStreamEvent, SamplingError>] = [
            .success(.messageStart(message: MessagesResponse(
                id: "message_cache",
                type: "message",
                role: "assistant",
                content: [],
                model: "claude-cache",
                usage: start
            ))),
            .success(.messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: delta
            )),
            .success(.messageStop),
        ]

        var completed: TokenUsage?
        for await event in streamMessages(
            rawStream: makeResultStream(events),
            modelMetadata: nil,
            requestId: RequestId("cache-creation"),
            idleTimeout: .seconds(60)
        ) {
            if case .completed(_, let response, _) = event {
                completed = response.usage
            }
        }
        return completed
    }

    @Test("legacy normalized usage decodes without a cache-creation field")
    func legacyUsageDecodesWithoutCreation() throws {
        let legacy = Data(#"{"prompt_tokens":42,"completion_tokens":7,"total_tokens":49,"cached_prompt_tokens":11}"#.utf8)
        let usage = try JSONDecoder().decode(TokenUsage.self, from: legacy)

        #expect(usage.promptTokens == 42)
        #expect(usage.cachedPromptTokens == 11)
        #expect(usage.cacheCreationPromptTokens == 0)
    }

    @Test("normalized usage round-trips the Rust-compatible cache-creation key")
    func cacheCreationCodingKeyRoundTrips() throws {
        let usage = TokenUsage(
            promptTokens: 165,
            completionTokens: 11,
            totalTokens: 176,
            cachedPromptTokens: 40,
            cacheCreationPromptTokens: 25
        )
        let encoded = try JSONEncoder().encode(usage)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["cache_creation_prompt_tokens"] as? Int == 25)
        #expect(object["cached_prompt_tokens"] as? Int == 40)
        #expect(try JSONDecoder().decode(TokenUsage.self, from: encoded) == usage)
    }

    @Test("zero cache creation stays absent from existing normalized usage JSON")
    func zeroCacheCreationPreservesLegacyJSON() throws {
        let usage = TokenUsage(promptTokens: 5, completionTokens: 2, totalTokens: 7)
        let encoded = try JSONEncoder().encode(usage)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["cache_creation_prompt_tokens"] == nil)
    }

    @Test("message-start cache writes survive separately while prompt totals include every bucket once")
    func messageStartPreservesDistinctBuckets() async throws {
        let usage = try #require(await completedUsage(
            start: MessagesUsage(
                inputTokens: 100,
                cacheCreationInputTokens: 25,
                cacheReadInputTokens: 40
            ),
            delta: MessageDeltaUsage(outputTokens: 11)
        ))

        #expect(usage.promptTokens == 165)
        #expect(usage.completionTokens == 11)
        #expect(usage.totalTokens == 176)
        #expect(usage.cachedPromptTokens == 40)
        #expect(usage.cacheCreationPromptTokens == 25)
        #expect(usage.reasoningTokens == 0)
    }

    @Test("message-delta cache buckets replace initial counts without double counting")
    func messageDeltaReplacesInitialBuckets() async throws {
        let usage = try #require(await completedUsage(
            start: MessagesUsage(
                inputTokens: 100,
                cacheCreationInputTokens: 25,
                cacheReadInputTokens: 40
            ),
            delta: MessageDeltaUsage(
                outputTokens: 9,
                inputTokens: 120,
                cacheReadInputTokens: 35,
                cacheCreationInputTokens: 30
            )
        ))

        #expect(usage.promptTokens == 185)
        #expect(usage.totalTokens == 194)
        #expect(usage.cachedPromptTokens == 35)
        #expect(usage.cacheCreationPromptTokens == 30)
    }

    @Test("message token accounting saturates instead of wrapping on malformed provider counts")
    func messageUsageSaturatesOnOverflow() async throws {
        let usage = try #require(await completedUsage(
            start: MessagesUsage(
                inputTokens: UInt32.max - 1,
                cacheCreationInputTokens: 5,
                cacheReadInputTokens: 10
            ),
            delta: MessageDeltaUsage(outputTokens: 8)
        ))

        #expect(usage.promptTokens == UInt32.max)
        #expect(usage.totalTokens == UInt32.max)
        #expect(usage.cachedPromptTokens == 10)
        #expect(usage.cacheCreationPromptTokens == 5)
    }
}
