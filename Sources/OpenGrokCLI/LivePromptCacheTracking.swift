import Foundation
import OpenGrokSamplingTypes
import OpenGrokSessionRuntime

/// Keeps diagnostics on the exact resident history actor that sampled them.
/// Session ids alone are insufficient: tests, isolated homes, forks, and ACP
/// reconnects can reuse the same spelling without sharing a conversation.
actor LivePromptCacheTracking {
    static let shared = LivePromptCacheTracking()

    struct Observation: Sendable {
        let response: SessionCacheResponse
        let unmeteredResponses: Int
    }

    enum DurableLookup: Sendable {
        case unavailable
        case ambiguous
        case response(SessionCacheResponse)
    }

    private struct SessionKey: Hashable {
        let historyID: ObjectIdentifier
        let sessionID: String

        init(history: LiveConversationHistory, sessionID: String) {
            self.historyID = ObjectIdentifier(history)
            self.sessionID = sessionID
        }
    }

    private final class WeakHistory: @unchecked Sendable {
        weak var value: LiveConversationHistory?

        init(_ value: LiveConversationHistory) {
            self.value = value
        }
    }

    private struct SessionState {
        let owner: WeakHistory
        let tracker: PromptCacheTracker
        var currentPromptID: String?
        var promptIndex = 0
        var unmeteredResponses = 0
    }

    private var sessions: [SessionKey: SessionState] = [:]

    func record(
        history: LiveConversationHistory,
        sessionID: String,
        promptID: String,
        loopIndex: UInt32,
        request: ConversationRequest,
        usage: TokenUsage?,
        provider: ModelProvider,
        modelID: String,
        requestStartedAt: DispatchTime? = nil
    ) async {
        guard await history.sessionID == sessionID else { return }
        removeExpiredOwners()

        let key = SessionKey(history: history, sessionID: sessionID)
        var state = sessions[key] ?? SessionState(
            owner: WeakHistory(history),
            tracker: PromptCacheTracker()
        )
        if state.currentPromptID != promptID {
            state.currentPromptID = promptID
            state.promptIndex += 1
        }

        guard let usage else {
            state.unmeteredResponses += 1
            sessions[key] = state
            return
        }

        let turnIndex = state.promptIndex
        let tracker = state.tracker
        sessions[key] = state

        await tracker.recordTurnOutcome(
            turnIndex: turnIndex,
            loopIndex: loopIndex,
            promptTokens: Int(usage.promptTokens),
            cachedTokens: Int(usage.cachedPromptTokens),
            completionTokens: Int(usage.completionTokens),
            currentRequestSummary: PromptCacheTracker.summarizeRequest(request),
            sessionId: sessionID,
            provider: provider,
            modelID: modelID,
            requestStartedAt: requestStartedAt
        )
    }

    func observation(
        history: LiveConversationHistory,
        sessionID: String
    ) async -> Observation? {
        guard await history.sessionID == sessionID else { return nil }
        removeExpiredOwners()
        let key = SessionKey(history: history, sessionID: sessionID)
        guard let state = sessions[key], state.owner.value === history else {
            return nil
        }
        return Observation(
            response: await state.tracker.sessionCacheResponse(),
            unmeteredResponses: state.unmeteredResponses
        )
    }

    /// ACP has already established wire-session ownership before consulting
    /// this lookup. Ambiguous durable identities fail closed instead of
    /// allowing one isolated home to inspect another session's diagnostics.
    func lookup(sessionID: String) async -> DurableLookup {
        removeExpiredOwners()
        let matching = sessions.filter { key, state in
            key.sessionID == sessionID && state.owner.value != nil
        }
        guard !matching.isEmpty else { return .unavailable }
        guard matching.count == 1, let state = matching.first?.value else {
            return .ambiguous
        }
        return .response(await state.tracker.sessionCacheResponse())
    }

    private func removeExpiredOwners() {
        sessions = sessions.filter { $0.value.owner.value != nil }
    }
}
