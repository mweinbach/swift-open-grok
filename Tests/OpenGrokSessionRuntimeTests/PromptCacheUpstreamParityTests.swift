import Foundation
import OpenGrokSamplingTypes
@testable import OpenGrokSessionRuntime
import Testing

@Suite("Upstream prompt cache accounting parity")
struct PromptCacheUpstreamParityTests {
    @Test("cache-reporting rates exclude providers that report no cache hits")
    func supportedRateExcludesNoCacheProviders() async {
        let tracker = PromptCacheTracker()

        await tracker.recordTurnOutcome(
            turnIndex: 1,
            promptTokens: 1_000,
            cachedTokens: 0,
            completionTokens: 100,
            currentRequestSummary: PromptCacheTracker.summarize(items: [.user("one")]),
            provider: .wafer,
            modelID: "wafer-flash"
        )
        await tracker.recordTurnOutcome(
            turnIndex: 2,
            promptTokens: 1_500,
            cachedTokens: 0,
            completionTokens: 100,
            currentRequestSummary: PromptCacheTracker.summarize(
                items: [.user("one"), .user("two")]
            ),
            provider: .wafer,
            modelID: "wafer-flash"
        )
        await tracker.recordTurnOutcome(
            turnIndex: 3,
            promptTokens: 2_000,
            cachedTokens: 1_500,
            completionTokens: 100,
            currentRequestSummary: PromptCacheTracker.summarize(
                items: [.user("one"), .user("two"), .user("three")]
            ),
            provider: .xai,
            modelID: "grok-4.6"
        )

        let summary = await tracker.summary()
        #expect(summary.totalTurns == 3)
        #expect(summary.steadyInputTokens == 3_500)
        #expect(summary.steadyCachedTokens == 1_500)
        #expect(summary.supportedInputTokens == 2_000)
        #expect(summary.supportedCachedTokens == 1_500)
        #expect(summary.noCacheSupportTurns == 1)
        #expect(abs(summary.overallHitRatePct - 42.857142857) < 0.001)
        #expect(summary.supportedHitRatePct == 75)

        let turns = await tracker.recentTurns()
        #expect(turns[1].status == .noCacheSupport)
        #expect(turns[1].provider == .wafer)
        #expect(turns[1].modelID == "wafer-flash")
        #expect(turns[1].diagnostic.contains("wafer/wafer-flash"))
        #expect(turns[2].provider == .xai)
    }

    @Test("provider, model, gap, and supported counters use upstream camel-case wire keys")
    func upstreamWireMetadataRoundTrips() async throws {
        let tracker = PromptCacheTracker()
        await tracker.recordTurnOutcome(
            turnIndex: 1,
            promptTokens: 100,
            cachedTokens: 0,
            currentRequestSummary: PromptCacheTracker.summarize(items: [.user("one")]),
            provider: .xai,
            modelID: "grok-4.6"
        )
        await tracker.recordTurnOutcome(
            turnIndex: 2,
            loopIndex: 3,
            promptTokens: 200,
            cachedTokens: 160,
            currentRequestSummary: PromptCacheTracker.summarize(
                items: [.user("one"), .user("two")]
            ),
            provider: .xai,
            modelID: "grok-4.6"
        )

        let response = await tracker.sessionCacheResponse()
        let data = try JSONEncoder().encode(response)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let summary = try #require(json["summary"] as? [String: Any])
        #expect(summary["supportedInputTokens"] as? Int == 200)
        #expect(summary["supportedCachedTokens"] as? Int == 160)
        #expect(summary["supportedHitRatePct"] as? Double == 80)
        #expect(summary["noCacheSupportTurns"] as? Int == 0)

        let turns = try #require(json["recentTurns"] as? [[String: Any]])
        #expect(turns[1]["provider"] as? String == "xai")
        #expect(turns[1]["modelId"] as? String == "grok-4.6")
        #expect(turns[1]["modelID"] == nil)
        #expect(turns[1]["requestGapMs"] as? Int != nil)
        #expect(turns[1]["loopIndex"] as? Int == 3)

        let decoded = try JSONDecoder().decode(SessionCacheResponse.self, from: data)
        #expect(decoded == response)
    }

    @Test("long intact-prefix gaps identify the actual provider and likely expiry")
    func longRequestGapProducesProviderQualifiedDiagnostic() async {
        let tracker = PromptCacheTracker()
        await tracker.recordTurnOutcome(
            turnIndex: 1,
            promptTokens: 1_000,
            cachedTokens: 0,
            currentRequestSummary: PromptCacheTracker.summarize(items: [.user("one")]),
            provider: .xai,
            modelID: "grok-4.6"
        )
        await tracker.recordTurnOutcome(
            turnIndex: 2,
            promptTokens: 2_000,
            cachedTokens: 128,
            currentRequestSummary: PromptCacheTracker.summarize(
                items: [.user("one"), .user("two")]
            ),
            provider: .xai,
            modelID: "grok-4.6",
            requestStartedAt: DispatchTime.now() + .seconds(360)
        )

        let turn = await tracker.recentTurns()[1]
        #expect(turn.status == .partialHit)
        #expect((turn.requestGapMs ?? 0) >= 359_000)
        #expect(turn.diagnostic.contains("xai/grok-4.6"))
        #expect(turn.diagnostic.contains("provider cache expiry or eviction"))
        #expect(turn.diagnostic.contains("minutes"))
    }

    @Test("legacy summaries decode safely without newly introduced upstream fields")
    func legacySummaryDefaultsNewCounters() throws {
        let legacy = Data(#"{"totalInputTokens":125,"totalCachedTokens":25,"totalTurns":1}"#.utf8)
        let snapshot = try JSONDecoder().decode(SessionCacheSnapshot.self, from: legacy)

        #expect(snapshot.totalPromptTokens == 125)
        #expect(snapshot.cachedTokens == 25)
        #expect(snapshot.supportedInputTokens == 0)
        #expect(snapshot.supportedCachedTokens == 0)
        #expect(snapshot.supportedHitRatePct == 0)
        #expect(snapshot.noCacheSupportTurns == 0)
    }
}
