import Foundation
import OpenGrokPagerRender
import Testing
@testable import OpenGrokPagerConversationUI

@Suite("Server follow-up suggestion ingestion and lifecycle")
struct FollowUpSuggestionsParityTests {
    @Test("wire payload preserves snake-case response ID and camel-case prompt ID")
    func decodesPinnedWireShape() throws {
        let data = Data(#"{"response_id":"response-1","promptId":"prompt-1","suggestions":[{"label":"Tell me more"},{"label":"Summarize"}]}"#.utf8)
        let payload = try #require(FollowUpSuggestionPayload(
            data: data,
            authenticatedSessionID: "session-1"
        ))

        #expect(payload.sessionID == "session-1")
        #expect(payload.responseID == "response-1")
        #expect(payload.promptID == "prompt-1")
        #expect(payload.labels == ["Tell me more", "Summarize"])
    }

    @Test("only the first six wire suggestions are considered and labels cap at 256 scalars")
    func boundsServerControlledPayload() throws {
        let longLabel = String(repeating: "漢", count: 300)
        let payload = try #require(FollowUpSuggestionPayload(
            sessionID: "session-1",
            responseID: "response-1",
            labels: ["", longLabel, "two", "three", "four", "five", "must-not-appear"]
        ))

        #expect(payload.labels.count == 5)
        #expect(payload.labels.first?.unicodeScalars.count == 256)
        #expect(!payload.labels.contains("must-not-appear"))
    }

    @Test("C0, C1, bidi overrides, zero-width formatting and surrounding whitespace are removed")
    func sanitizesTerminalAndBidiInjection() throws {
        let hostile = " \u{001B}[31mHi\u{009B}\u{202E}\u{2066}\u{200D} there \u{0007} "
        let payload = try #require(FollowUpSuggestionPayload(
            sessionID: "session-1",
            responseID: "response-1",
            labels: [hostile, "\u{001B}\u{202E}"]
        ))

        #expect(payload.labels == ["[31mHi there"])
        #expect(!payload.labels.joined().unicodeScalars.contains(where: pagerIsUnsafeDisplayScalar))
    }

    @Test("unsafe scalars are filtered before the 256-scalar display bound")
    func filtersControlsBeforeBoundingTheLabel() throws {
        let hostilePrefix = String(repeating: "\u{001B}", count: 256)
        let payload = try #require(FollowUpSuggestionPayload(
            sessionID: "session-1",
            responseID: "response-1",
            labels: [hostilePrefix + "visible"]
        ))

        #expect(payload.labels == ["visible"])
    }

    @Test("replay, malformed payloads and byte-oversized identifiers fail closed")
    func rejectsReplayAndOversizedIdentifiers() {
        let replay = Data(#"{"response_id":"r","_meta":{"x.ai/replayed":true},"suggestions":[{"label":"stale"}]}"#.utf8)
        #expect(FollowUpSuggestionPayload(data: replay, authenticatedSessionID: "session-1") == nil)
        #expect(FollowUpSuggestionPayload(data: Data("{}".utf8), authenticatedSessionID: "session-1") == nil)
        #expect(FollowUpSuggestionPayload(
            sessionID: "session-1",
            responseID: String(repeating: "漢", count: 43),
            labels: ["too long"]
        ) == nil)
        #expect(FollowUpSuggestionPayload(
            sessionID: "session-1",
            responseID: "ok",
            promptID: String(repeating: "x", count: 129),
            labels: ["too long"]
        ) == nil)
        #expect(FollowUpSuggestionPayload(
            data: Data(repeating: UInt8(ascii: " "), count: 65_537),
            authenticatedSessionID: "session-1"
        ) == nil)
    }

    @Test("newest response wins and an old delivery never revives prior chips")
    func newestResponseWinsWithoutReplayRevival() throws {
        var state = FollowUpSuggestionsState(sessionID: "session-1")
        let older = try payload(response: "response-1", labels: ["older"])
        let newer = try payload(response: "response-2", labels: ["newer"])

        let acceptedOlder = state.apply(older)
        #expect(acceptedOlder)
        #expect(state.currentGeneration == 0)
        let acceptedNewer = state.apply(newer)
        #expect(acceptedNewer)
        #expect(state.currentGeneration == 1)
        let replayedOlder = state.apply(older)
        #expect(!replayedOlder)
        #expect(state.current?.labels == ["newer"])
    }

    @Test("current response refreshes in place, retracts, and can be delivered again")
    func refreshRetractionAndRedelivery() throws {
        var state = FollowUpSuggestionsState(sessionID: "session-1")
        let initial = try payload(response: "response-1", labels: ["first"])
        let refreshed = try payload(response: "response-1", labels: ["updated"])
        let retraction = try payload(response: "response-1", labels: [])

        let acceptedInitial = state.apply(initial)
        #expect(acceptedInitial)
        let repeatedInitial = state.apply(initial)
        #expect(!repeatedInitial)
        let acceptedRefresh = state.apply(refreshed)
        #expect(acceptedRefresh)
        #expect(state.current?.labels == ["updated"])
        let acceptedRetraction = state.apply(retraction)
        #expect(acceptedRetraction)
        #expect(state.current == nil)
        let redeliveredInitial = state.apply(initial)
        #expect(redeliveredInitial)
        #expect(state.current?.labels == ["first"])
    }

    @Test("future-turn deliveries buffer until that exact prompt becomes active")
    func buffersFutureTurnAndPreservesSessionBinding() throws {
        var state = FollowUpSuggestionsState(sessionID: "session-1", currentPromptID: "prompt-1")
        let future = try payload(response: "response-2", prompt: "prompt-2", labels: ["future"])
        let foreign = try #require(FollowUpSuggestionPayload(
            sessionID: "other-session",
            responseID: "foreign",
            labels: ["foreign"]
        ))

        let displayedFutureImmediately = state.apply(future)
        #expect(!displayedFutureImmediately)
        #expect(state.pendingCount == 1)
        #expect(state.current == nil)
        let acceptedForeign = state.apply(foreign)
        #expect(!acceptedForeign)
        let activatedFutureTurn = state.beginTurn(promptID: "prompt-2")
        #expect(activatedFutureTurn)
        #expect(state.current?.labels == ["future"])
        #expect(state.pendingCount == 0)
    }

    @Test("cleared current-turn chips can reappear while prior-turn replay cannot")
    func currentTurnRedeliveryDoesNotRevivePreviousTurn() throws {
        var state = FollowUpSuggestionsState(sessionID: "session-1", currentPromptID: "prompt-1")
        let current = try payload(response: "response-1", prompt: "prompt-1", labels: ["current"])

        let acceptedCurrent = state.apply(current)
        #expect(acceptedCurrent)
        state.clearDisplayed()
        let redeliveredCurrent = state.apply(current)
        #expect(redeliveredCurrent)
        let activatedNextTurn = state.beginTurn(promptID: "prompt-2")
        #expect(activatedNextTurn)
        let replayedPreviousTurn = state.apply(current)
        #expect(!replayedPreviousTurn)
        #expect(state.current == nil)
    }

    @Test("pending future-turn entries are FIFO bounded at sixteen")
    func boundsPendingFutureTurns() throws {
        var state = FollowUpSuggestionsState(sessionID: "session-1", currentPromptID: "active")

        for index in 0...FollowUpSuggestionsState.maximumPendingTurns {
            let pending = try payload(
                response: "response-\(index)",
                prompt: "prompt-\(index)",
                labels: ["suggestion-\(index)"]
            )
            let displayedPendingImmediately = state.apply(pending)
            #expect(!displayedPendingImmediately)
        }

        #expect(state.pendingCount == FollowUpSuggestionsState.maximumPendingTurns)
        let activatedEvictedTurn = state.beginTurn(promptID: "prompt-0")
        #expect(!activatedEvictedTurn)
        let activatedRetainedTurn = state.beginTurn(promptID: "prompt-16")
        #expect(activatedRetainedTurn)
        #expect(state.current?.labels == ["suggestion-16"])
    }

    @Test("session reload clears old response generations and can preserve the adopted turn")
    func resetsForSessionReload() throws {
        var state = FollowUpSuggestionsState(sessionID: "session-1", currentPromptID: "prompt-1")
        let current = try payload(response: "response-1", prompt: "prompt-1", labels: ["keep"])

        let acceptedCurrent = state.apply(current)
        #expect(acceptedCurrent)
        state.reset(sessionID: "session-1", preservingPromptID: "prompt-1")

        #expect(state.current == nil)
        #expect(state.nextGeneration == 0)
        #expect(state.seenResponseCount == 0)
        #expect(state.pendingCount == 1)
        let restoredPreservedTurn = state.beginTurn(promptID: "prompt-1")
        #expect(restoredPreservedTurn)
        #expect(state.current?.labels == ["keep"])

        state.reset(sessionID: "session-2")
        #expect(state.current == nil)
        #expect(state.pendingCount == 0)
        let acceptedPreviousSession = state.apply(current)
        #expect(!acceptedPreviousSession)
    }

    private func payload(
        response: String,
        prompt: String? = nil,
        labels: [String]
    ) throws -> FollowUpSuggestionPayload {
        try #require(FollowUpSuggestionPayload(
            sessionID: "session-1",
            responseID: response,
            promptID: prompt,
            labels: labels
        ))
    }
}
