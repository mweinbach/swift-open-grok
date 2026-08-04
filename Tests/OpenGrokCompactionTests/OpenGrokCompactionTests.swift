import Foundation
import OpenGrokCompaction
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

@Suite("Open Grok compaction")
struct OpenGrokCompactionTests {
    @Test("trigger threshold is strict and full replace ignores minimum step gate")
    func triggerPolicy() {
        let fullReplace = CompactionPolicy(enabled: true, mode: .fullReplace, minStepsBeforeCompact: 3)
        #expect(shouldCompact(policy: fullReplace, lastPromptTokens: 85_000, contextWindow: 100_000, currentStep: 0) == nil)
        #expect(shouldCompact(policy: fullReplace, lastPromptTokens: 85_001, contextWindow: 100_000, currentStep: 0)?.utilizationPercent == 85)

        let partial = CompactionPolicy(enabled: true, mode: .history, minStepsBeforeCompact: 3)
        #expect(shouldCompact(policy: partial, lastPromptTokens: 90_000, contextWindow: 100_000, currentStep: 2) == nil)
        #expect(shouldCompact(policy: partial, lastPromptTokens: 90_000, contextWindow: 100_000, currentStep: 3)?.step == 3)
        #expect(shouldCompact(policy: partial, lastPromptTokens: 1, contextWindow: 0, currentStep: 3) == nil)
    }

    @Test("budget precedence clamps model limits and records hash compatibility")
    func budgetResolution() {
        let modelBudget = resolveCompactionBudget(
            contextWindow: 100_000,
            modelTokenLimit: 99_000,
            previousCompactionHash: "old",
            currentCompactionHash: "new"
        )
        #expect(modelBudget.triggerTokenLimit == 90_000)
        #expect(modelBudget.source == "model")
        #expect(modelBudget.compatibilityRequired)

        let operatorBudget = resolveCompactionBudget(
            contextWindow: 100_000,
            explicitTokenLimit: 75_000,
            previousCompactionHash: "same",
            currentCompactionHash: "same"
        )
        #expect(operatorBudget.triggerTokenLimit == 75_000)
        #expect(!operatorBudget.compatibilityRequired)
    }

    @Test("reduction and step guards reject unsafe compaction plans")
    func reductionGuards() {
        #expect(compactionMeetsReductionGuard(tokensBefore: 1_000, tokensAfter: 800, maxReductionRatio: 0.8))
        #expect(!compactionMeetsReductionGuard(tokensBefore: 1_000, tokensAfter: 801, maxReductionRatio: 0.8))
        #expect(!compactionMeetsReductionGuard(tokensBefore: 0, tokensAfter: 0, maxReductionRatio: 0.8))

        let policy = CompactionPolicy(enabled: true, mode: .historyThenSteps, stepsTriggerRatio: 0.3)
        #expect(shouldCompactStepsAfterHistory(stepsTokens: 31, historyTokens: 100, policy: policy))
        #expect(!shouldCompactStepsAfterHistory(stepsTokens: 30, historyTokens: 100, policy: policy))
    }

    @Test("selection keeps assistant tool results together")
    func toolSafeSelection() {
        let items: [ConversationItem] = [
            .user("old"),
            .assistantToolCalls([ToolCall(id: "call-1", name: "read_file", arguments: "{}")]),
            .toolResult(toolCallId: "call-1", content: String(repeating: "r", count: 40)),
            .toolResult(toolCallId: "call-2", content: String(repeating: "s", count: 40)),
            .assistant("new")
        ]
        let plan = selectTurnsToCompact(
            itemTokenCounts: [10, 10, 10, 10, 10],
            items: items,
            targetTokens: 20,
            minCompactableTokens: 10
        )
        #expect(plan?.splitIndex == 4)
        #expect(plan?.tokensToCompact == 40)
        #expect(plan?.tokensToKeep == 10)
    }

    @Test("summary cleaning removes scratchpad and neutralizes control tags")
    func summaryCleaning() {
        let raw = "<analysis>private reasoning</analysis>\n<summary>\n1. Request: fix auth\n9. Next: test\n</summary>"
        let cleaned = formatCompactSummary(raw)
        #expect(cleaned.contains("Summary:"))
        #expect(!cleaned.contains("private reasoning"))
        #expect(!cleaned.contains("<summary>"))
        #expect(isDegenerateSummary("short"))
        #expect(!isDegenerateSummary(String(repeating: "x", count: MIN_SUMMARY_SEED_CHARS)))
    }

    @Test("compacted history preserves ChatState synthetic markers and ordering")
    func historyAssembly() {
        let history = assembleCompactedHistory(CompactedHistoryParts(
            systemMessage: .system("system"),
            userMessagePrefix: "<user_info>Open Grok</user_info>",
            agentsMDReminder: "follow project rules",
            lastUserQuery: "fix the bug",
            recentMessages: [.assistant("recent")],
            compactionSummary: "1. Summary: fixed the bug",
            systemReminder: "state reminder"
        ))
        #expect(history.count == 7)
        #expect(history[0] == .system("system"))
        #expect(history[1] == .userMeta("<user_info>Open Grok</user_info>"))
        if case .user(let project) = history[2] {
            #expect(project.syntheticReason == .projectInstructions)
        } else {
            Issue.record("project instructions must remain a tagged synthetic user item")
        }
        #expect(history[3].textContent() == "<user_query>\nfix the bug\n</user_query>")
        #expect(history[4] == .assistant("recent"))
        if case .user(let summary) = history[5] {
            #expect(summary.syntheticReason == .compactionMeta)
            #expect(summary.content.first.map { part in
                if case .text(let text) = part { return text.contains("This session is being continued") }
                return false
            } == true)
        } else {
            Issue.record("summary must remain a compaction metadata carrier")
        }
        if case .user(let reminder) = history[6] {
            #expect(reminder.syntheticReason == .systemReminder)
        } else {
            Issue.record("system reminder must remain a tagged synthetic user item")
        }
    }

    @Test("sanitization strips orphaned tool outputs without dropping unanswered calls")
    func sanitizeHistory() {
        let items: [ConversationItem] = [
            .toolResult(toolCallId: "orphan", content: "bad"),
            .assistantToolCalls([ToolCall(id: "pending", name: "edit", arguments: "{}")]),
            .assistantToolCalls([ToolCall(id: "valid", name: "read", arguments: "{}")]),
            .toolResult(toolCallId: "valid", content: "ok")
        ]
        let result = sanitizeCompactedHistory(items)
        #expect(result.strippedToolCallIDs == ["orphan"])
        #expect(result.items.count == 3)
        #expect(validateCompactedHistory(result.items).isValid)
    }

    @Test("persistence state is deterministic across turn, failure, and commit")
    func persistenceState() {
        let snapshot: [ConversationItem] = [.system("sys"), .user("request")]
        var state = CompactionPersistenceState()
        let beganFirst = state.begin(operationID: "op-1", target: .fullReplace, snapshot: snapshot, promptIndex: 4)
        #expect(beganFirst)
        let beganSecond = state.begin(operationID: "op-2", target: .fullReplace, snapshot: snapshot, promptIndex: 4)
        #expect(!beganSecond)
        state.recordAttempt()
        state.recordFailure(
            CompactionFailureState(kind: .deterministic, message: "context_length_exceeded", attempts: 1, contextOverflow: true),
            suppression: .sticky
        )
        #expect(state.operation == nil)
        #expect(state.suppression == .sticky)
        state.clearForContextChange()
        #expect(state.suppression == .none)
        let beganAfterContextChange = state.begin(operationID: "op-3", target: .fullReplace, snapshot: snapshot, promptIndex: 4)
        #expect(beganAfterContextChange)
        state.commitSuccess(promptIndex: 4)
        #expect(state.compactionCount == 1)
        #expect(state.lastCompactionPromptIndex == 4)
        #expect(state.lastFailure == nil)

        #expect(commitCompactionReplacement(snapshot: snapshot, current: snapshot, replacement: [.userMeta("summary")]) == .applied)
        #expect(commitCompactionReplacement(snapshot: snapshot, current: [.system("changed")], replacement: [.userMeta("summary")]) == .staleSnapshot)
        #expect(commitCompactionReplacement(snapshot: snapshot, current: snapshot, replacement: []) == .emptyReplacement)
    }

    @Test("Codex V2 collector installs exactly one item only after response completion")
    func codexCollector() throws {
        let raw: JSONValue = .object(["type": .string("compaction"), "encrypted_content": .string("opaque")])
        let item = CodexCompactionOutputItem(id: "cmp-1", raw: raw, encryptedContent: "opaque")
        var collector = CodexCompactionV2Collector()
        try collector.consume(.unrelated(type: "response.output_text.delta"))
        try collector.consume(.outputItemDone(item))
        do {
            _ = try collector.finish(attempts: 1)
            Issue.record("partial V2 response must not install before response.completed")
        } catch CodexCompactionProtocolError.incompleteResponse {
        }
        try collector.consume(.responseCompleted)
        let result = try collector.finish(attempts: 1)
        #expect(result.item == item)
        #expect(result.replacementHistory(promptInput: [.system("sys"), .user("task"), .assistant("ignored")]).count == 2)
    }

    @Test("Codex retry policy allows one auth refresh and three total attempts")
    func codexRetryPolicy() {
        let policy = CodexCompactionRetryPolicy()
        #expect(policy.canRetry(cause: .authentication(status: 401), attemptsMade: 1, authRefreshesUsed: 0))
        #expect(!policy.canRetry(cause: .authentication(status: 401), attemptsMade: 2, authRefreshesUsed: 1))
        #expect(policy.canRetry(cause: .transient, attemptsMade: 2, authRefreshesUsed: 1))
        #expect(!policy.canRetry(cause: .partialResponse, attemptsMade: 1, authRefreshesUsed: 0))
    }

    @Test("Codex interjection retention rejects edited prefixes")
    func codexInterjections() {
        let snapshot: [ConversationItem] = [.system("sys"), .user("task")]
        let current = snapshot + [.systemReminder("internal"), .interjection("steer")]
        #expect(codexRemoteCompactionV2Interjections(snapshot: snapshot, current: current)?.map { $0.textContent() } == ["steer"])
        #expect(codexRemoteCompactionV2Interjections(snapshot: snapshot, current: [.system("sys"), .user("edited")]) == nil)
    }

    @Test("retry loop retries transient errors and stops on deterministic errors")
    func retryBehavior() async {
        let transientSampler = ScriptedSampler(responses: [
            .failure(.timeout(timeoutSeconds: 1, collectedBytes: 0)),
            .success(LLMCompactionOutput(response: String(repeating: "x", count: MIN_SUMMARY_SEED_CHARS)))
        ])
        do {
            let result = try await sampleCompactionWithRetries(
                sampler: transientSampler,
                turns: ["turn"],
                prompt: CompactionPrompt(user: "summarize"),
                maxAttempts: 2,
                retryDelayMilliseconds: 0,
                timeoutSeconds: 1
            )
            #expect(result.attempts == 2)
        } catch {
            Issue.record("transient compaction failure should retry: \(error)")
        }

        let deterministicSampler = ScriptedSampler(responses: [
            .failure(.build("unknown model")),
            .success(LLMCompactionOutput(response: String(repeating: "x", count: MIN_SUMMARY_SEED_CHARS)))
        ])
        do {
            _ = try await sampleCompactionWithRetries(
                sampler: deterministicSampler,
                turns: ["turn"],
                prompt: CompactionPrompt(user: "summarize"),
                maxAttempts: 3,
                retryDelayMilliseconds: 0,
                timeoutSeconds: 1
            )
            Issue.record("deterministic compaction failure must not retry")
        } catch let error as CompactionRetryFailure {
            if case .failure(_, let deterministic, _, let attempts) = error {
                #expect(deterministic)
                #expect(attempts == 1)
            } else {
                Issue.record("unexpected retry failure shape: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

private final class ScriptedSampler: CompactionSampler, @unchecked Sendable {
    typealias Item = String

    private let lock = NSLock()
    private var responses: [Result<LLMCompactionOutput, CompactionSampleError>]

    init(responses: [Result<LLMCompactionOutput, CompactionSampleError>]) {
        self.responses = responses
    }

    func sampleCompaction(
        turns: [String],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        switch try dequeueResponse() {
        case .success(let output): return output
        case .failure(let error): throw error
        }
    }

    private func dequeueResponse() throws -> Result<LLMCompactionOutput, CompactionSampleError> {
        lock.lock()
        defer { lock.unlock() }
        guard !responses.isEmpty else { throw CompactionSampleError.other("script exhausted") }
        return responses.removeFirst()
    }
}
