// PromptCacheTrackerTests.swift
//
// Tests for PromptCacheTracker, CacheBreakReason, CacheBreakEvent,
// SessionCacheSnapshot, and prefix divergence diagnostics.

import Foundation
import Testing
@testable import OpenGrokSessionRuntime
import OpenGrokSamplingTypes
import OpenGrokShared

@Suite("PromptCacheTrackerTests")
struct PromptCacheTrackerTests {

    @Test("CacheBreakReason enum serialization and cases")
    func cacheBreakReasonSerialization() throws {
        let cases: [CacheBreakReason] = [
            .systemPromptChanged,
            .toolsChanged,
            .messageSequenceChanged,
            .compaction,
            .modelChanged,
            .historyRelocated,
            .unknown
        ]

        for reason in cases {
            let data = try JSONEncoder().encode(reason)
            let decoded = try JSONDecoder().decode(CacheBreakReason.self, from: data)
            #expect(decoded == reason)
        }

        // Test unknown fallback
        let rawJson = "\"non_existent_reason\"".data(using: .utf8)!
        let decodedUnknown = try JSONDecoder().decode(CacheBreakReason.self, from: rawJson)
        #expect(decodedUnknown == .unknown)
    }

    @Test("CacheBreakEvent serialization with snake_case and camelCase")
    func cacheBreakEventSerialization() throws {
        let event = CacheBreakEvent(
            turnIndex: 3,
            reason: .systemPromptChanged,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            details: "System prompt changed at offset 12"
        )

        let encoder = WireJSONEncoder.make()
        let data = try encoder.encode(event)
        let decoded = try WireJSONDecoder.make().decode(CacheBreakEvent.self, from: data)

        #expect(decoded.turnIndex == 3)
        #expect(decoded.reason == .systemPromptChanged)
        #expect(decoded.details == "System prompt changed at offset 12")

        // Test decoding from camelCase
        let camelJson = """
        {
            "turnIndex": 5,
            "reason": "toolsChanged",
            "timestamp": "2026-08-14T00:00:00Z",
            "details": "Tools modified"
        }
        """.data(using: .utf8)!
        let camelDecoded = try JSONDecoder().decode(CacheBreakEvent.self, from: camelJson)
        #expect(camelDecoded.turnIndex == 5)
        #expect(camelDecoded.reason == .toolsChanged)
        #expect(camelDecoded.details == "Tools modified")
    }

    @Test("SessionCacheSnapshot calculations and serialization")
    func sessionCacheSnapshotSerialization() throws {
        let breakEvent = CacheBreakEvent(
            turnIndex: 2,
            reason: .compaction,
            timestamp: Date(),
            details: "History compacted"
        )

        let snapshot = SessionCacheSnapshot(
            cacheHitRate: 80.0,
            totalPromptTokens: 2500,
            cachedTokens: 2000,
            breakEvents: [breakEvent],
            totalTurns: 3,
            hits: 2,
            partialHits: 0,
            breaks: 1,
            steadyPromptTokens: 1500,
            steadyCachedTokens: 1200,
            lastBreakDiagnostic: "History compacted"
        )

        let encoder = WireJSONEncoder.make()
        let data = try encoder.encode(snapshot)
        let decoded = try WireJSONDecoder.make().decode(SessionCacheSnapshot.self, from: data)

        #expect(decoded.cacheHitRate == 80.0)
        #expect(decoded.totalPromptTokens == 2500)
        #expect(decoded.cachedTokens == 2000)
        #expect(decoded.breakEvents.count == 1)
        #expect(decoded.breakEvents[0].reason == .compaction)
        #expect(decoded.totalTurns == 3)
        #expect(decoded.hits == 2)
        #expect(decoded.breaks == 1)
    }

    @Test("PromptCacheTracker first turn is cold start")
    func firstTurnColdStart() async {
        let tracker = PromptCacheTracker()

        let req = ConversationRequest(
            items: [
                ConversationItem.system("You are a helpful assistant."),
                ConversationItem.user("Hello world")
            ],
            tools: [],
            model: "grok-beta"
        )

        let breakEvent = await tracker.recordTurn(
            request: req,
            promptTokens: 1000,
            cachedTokens: 0,
            turnIndex: 1
        )

        #expect(breakEvent == nil)
        let snapshot = await tracker.currentSnapshot()
        #expect(snapshot.totalTurns == 1)
        #expect(snapshot.totalPromptTokens == 1000)
        #expect(snapshot.cachedTokens == 0)
        #expect(snapshot.steadyPromptTokens == 0)
        #expect(snapshot.steadyCachedTokens == 0)
        #expect(snapshot.cacheHitRate == 0.0)

        let recent = await tracker.recentTurns()
        #expect(recent.count == 1)
        #expect(recent[0].status == .firstTurn)
    }

    @Test("PromptCacheTracker turn 2 cache hit")
    func secondTurnCacheHit() async {
        let tracker = PromptCacheTracker()

        let user1 = ConversationItem.user("Hello")
        let assistant1 = ConversationItem.assistant(AssistantItem(content: "Hi there!"))
        let user2 = ConversationItem.user("Can you help me?")

        let req1 = ConversationRequest(items: [user1, assistant1], model: "grok-beta")
        await tracker.recordTurn(request: req1, promptTokens: 1000, cachedTokens: 0, turnIndex: 1)

        let req2 = ConversationRequest(items: [user1, assistant1, user2], model: "grok-beta")
        let breakEvent = await tracker.recordTurn(request: req2, promptTokens: 1500, cachedTokens: 1000, turnIndex: 2)

        #expect(breakEvent == nil)
        let snapshot = await tracker.currentSnapshot()
        #expect(snapshot.totalTurns == 2)
        #expect(snapshot.totalPromptTokens == 2500)
        #expect(snapshot.cachedTokens == 1000)
        #expect(snapshot.steadyPromptTokens == 1500)
        #expect(snapshot.steadyCachedTokens == 1000)
        #expect(snapshot.hits == 1)
        #expect(snapshot.breaks == 0)
        #expect(abs(snapshot.cacheHitRate - 66.66) < 0.1)

        let recent = await tracker.recentTurns()
        #expect(recent.count == 2)
        #expect(recent[1].status == .hit)
    }

    @Test("PromptCacheTracker detects systemPromptChanged")
    func systemPromptChangedDivergence() async {
        let tracker = PromptCacheTracker()

        let req1 = ConversationRequest(
            items: [
                ConversationItem.system("You are a helpful assistant."),
                ConversationItem.user("Hi")
            ],
            model: "grok-beta"
        )
        await tracker.recordTurn(request: req1, promptTokens: 1000, cachedTokens: 0, turnIndex: 1)

        let req2 = ConversationRequest(
            items: [
                ConversationItem.system("You are an expert coder."),
                ConversationItem.user("Hi")
            ],
            model: "grok-beta"
        )
        let breakEvent = await tracker.recordTurn(request: req2, promptTokens: 1000, cachedTokens: 0, turnIndex: 2)

        #expect(breakEvent != nil)
        #expect(breakEvent?.reason == .systemPromptChanged)
        let snapshot = await tracker.currentSnapshot()
        #expect(snapshot.breaks == 1)
        #expect(snapshot.breakEvents.count == 1)
        #expect(snapshot.breakEvents[0].reason == .systemPromptChanged)
    }

    @Test("PromptCacheTracker detects toolsChanged")
    func toolsChangedDivergence() async {
        let tracker = PromptCacheTracker()

        let tool1 = ToolSpec(name: "bash", description: "Run bash", parameters: .object([:]))
        let tool2 = ToolSpec(name: "edit", description: "Edit files", parameters: .object([:]))

        let req1 = ConversationRequest(
            items: [ConversationItem.user("Hello")],
            tools: [tool1],
            model: "grok-beta"
        )
        await tracker.recordTurn(request: req1, promptTokens: 1000, cachedTokens: 0, turnIndex: 1)

        let req2 = ConversationRequest(
            items: [ConversationItem.user("Hello")],
            tools: [tool1, tool2],
            model: "grok-beta"
        )
        let breakEvent = await tracker.recordTurn(request: req2, promptTokens: 1200, cachedTokens: 0, turnIndex: 2)

        #expect(breakEvent != nil)
        #expect(breakEvent?.reason == .toolsChanged)
        let snapshot = await tracker.currentSnapshot()
        #expect(snapshot.breaks == 1)
        #expect(snapshot.breakEvents[0].reason == .toolsChanged)
    }

    @Test("PromptCacheTracker detects messageSequenceChanged")
    func messageSequenceChangedDivergence() async {
        let tracker = PromptCacheTracker()

        let user1 = ConversationItem.user("Original prompt")
        let user1Modified = ConversationItem.user("Edited prompt")

        let req1 = ConversationRequest(items: [user1], model: "grok-beta")
        await tracker.recordTurn(request: req1, promptTokens: 500, cachedTokens: 0, turnIndex: 1)

        let req2 = ConversationRequest(items: [user1Modified], model: "grok-beta")
        let breakEvent = await tracker.recordTurn(request: req2, promptTokens: 500, cachedTokens: 0, turnIndex: 2)

        #expect(breakEvent != nil)
        #expect(breakEvent?.reason == .messageSequenceChanged)
    }

    @Test("PromptCacheTracker detects compaction via pruning and truncation")
    func compactionPrunedAndTruncationDivergence() async {
        let tracker = PromptCacheTracker()

        let user = ConversationItem.user("Run tool")
        let toolOutputFull = ConversationItem.toolResult(ToolResultItem(
            toolCallId: "call_1",
            content: "Full output data that is very long"
        ))
        let toolOutputPruned = ConversationItem.toolResult(ToolResultItem(
            toolCallId: "call_1",
            content: hardClearPlaceholder
        ))

        let req1 = ConversationRequest(items: [user, toolOutputFull], model: "grok-beta")
        await tracker.recordTurn(request: req1, promptTokens: 2000, cachedTokens: 0, turnIndex: 1)

        let req2 = ConversationRequest(items: [user, toolOutputPruned], model: "grok-beta")
        let breakEvent = await tracker.recordTurn(request: req2, promptTokens: 500, cachedTokens: 0, turnIndex: 2)

        #expect(breakEvent != nil)
        #expect(breakEvent?.reason == .compaction)

        // Test history count truncation
        let tracker2 = PromptCacheTracker()
        let item1 = ConversationItem.user("1")
        let item2 = ConversationItem.user("2")
        let item3 = ConversationItem.user("3")

        let tReq1 = ConversationRequest(items: [item1, item2, item3], model: "grok-beta")
        await tracker2.recordTurn(request: tReq1, promptTokens: 1500, cachedTokens: 0, turnIndex: 1)

        let tReq2 = ConversationRequest(items: [item1], model: "grok-beta")
        let truncBreak = await tracker2.recordTurn(request: tReq2, promptTokens: 500, cachedTokens: 0, turnIndex: 2)

        #expect(truncBreak != nil)
        #expect(truncBreak?.reason == .compaction)
    }

    @Test("PromptCacheTracker detects modelChanged")
    func modelChangedDivergence() async {
        let tracker = PromptCacheTracker()

        let user = ConversationItem.user("Hello")
        let req1 = ConversationRequest(items: [user], model: "grok-beta")
        await tracker.recordTurn(request: req1, promptTokens: 500, cachedTokens: 0, turnIndex: 1)

        let req2 = ConversationRequest(items: [user], model: "grok-code-fast")
        let breakEvent = await tracker.recordTurn(request: req2, promptTokens: 500, cachedTokens: 0, turnIndex: 2)

        #expect(breakEvent != nil)
        #expect(breakEvent?.reason == .modelChanged)
    }

    @Test("PromptCacheTracker manual break recording and reset")
    func manualBreakAndReset() async {
        let tracker = PromptCacheTracker()

        let event = await tracker.recordBreak(
            reason: .historyRelocated,
            details: "Rewound to previous branch",
            turnIndex: 4
        )

        #expect(event.reason == .historyRelocated)
        #expect(event.turnIndex == 4)
        var snapshot = await tracker.currentSnapshot()
        #expect(snapshot.breaks == 1)
        #expect(snapshot.breakEvents.count == 1)

        await tracker.reset()
        snapshot = await tracker.currentSnapshot()
        #expect(snapshot.breaks == 0)
        #expect(snapshot.breakEvents.isEmpty)
        #expect(snapshot.totalTurns == 0)
    }
}
