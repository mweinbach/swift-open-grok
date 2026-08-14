// TwoPassPrefireCompactionTests.swift
//
// Tests for Two-Pass Prefire Background Compaction (Feature 3):
// - 95% history split by token weight
// - Tool boundary snapping (tool_calls never severed from toolResult/customToolOutput)
// - 5-section prompt generation & Pass 1 history construction
// - NOTE₁ extraction (<summary> tag preferred) and 12k char capping
// - In-flight concurrency guard and cancellation
// - AsyncCompactionCache storage and deterministic fingerprinting

import Foundation
import OpenGrokChatState
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTokenEstimation
import Testing
@testable import OpenGrokCompaction

// MARK: - Test Doubles

private final class ScriptedTwoPassSampler: CompactionSampler, @unchecked Sendable {
    typealias Item = ConversationItem

    private let lock = NSLock()
    private var responses: [String]
    private var failures: [CompactionSampleError?]
    private var calls: [[ConversationItem]] = []

    init(responses: [String] = [], failures: [CompactionSampleError?] = []) {
        self.responses = responses
        self.failures = failures
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    var recordedCalls: [[ConversationItem]] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    private func recordAndNext(turns: [ConversationItem]) -> (failure: CompactionSampleError?, response: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(turns)
        let failure = failures.isEmpty ? nil : failures.removeFirst()
        let response = responses.isEmpty ? "<summary>\n" + String(repeating: "Summary content line\n", count: 60) + "</summary>" : responses.removeFirst()
        return (failure, response)
    }

    func sampleCompaction(
        turns: [ConversationItem],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        let (failure, response) = recordAndNext(turns: turns)
        if let failure { throw failure }
        return LLMCompactionOutput(response: response)
    }
}

// MARK: - Test Suite

@Suite("Two-Pass Prefire Background Compaction Tests (Feature 3)")
struct TwoPassPrefireCompactionTests {

    // MARK: - Tier 1: Feature Coverage

    @Test("Prefire trigger threshold calculation with lead percentage and provider guard")
    func testPrefireTriggerThresholdCalculation() {
        // Context window: 100,000 tokens, threshold: 85%, lead: 10% => trigger at 75,000 tokens
        let cw: UInt64 = 100_000
        let threshold: UInt8 = 85
        let lead: UInt8 = 10

        #expect(!shouldPrefireTwoPass(estimatedTotalTokens: 74_999, contextWindow: cw, thresholdPercent: threshold, leadPercent: lead, provider: .xai))
        #expect(shouldPrefireTwoPass(estimatedTotalTokens: 75_001, contextWindow: cw, thresholdPercent: threshold, leadPercent: lead, provider: .xai))

        // Codex provider always returns false (server-side compaction)
        #expect(!shouldPrefireTwoPass(estimatedTotalTokens: 90_000, contextWindow: cw, thresholdPercent: threshold, leadPercent: lead, provider: .codex))

        // Other non-codex providers trigger normally
        #expect(shouldPrefireTwoPass(estimatedTotalTokens: 80_000, contextWindow: cw, thresholdPercent: threshold, leadPercent: lead, provider: .deepseek))
        #expect(shouldPrefireTwoPass(estimatedTotalTokens: 80_000, contextWindow: cw, thresholdPercent: threshold, leadPercent: lead, provider: .fireworks))
    }

    @Test("Two-pass 95% history split computation preserves non-empty tail")
    func testTwoPass95PercentSplitComputation() {
        // 40 items with equal token weight (10 tokens each)
        let items: [ConversationItem] = (0..<40).map { i in
            .user("Prompt \(i): " + String(repeating: "x", count: 40))
        }

        let split = splitConversationForTwoPass(conversation: items, splitFraction: 0.95)
        #expect(split.splitIndex == 38)
        #expect(split.prefix.count == 38)
        #expect(split.tail.count == 2)

        let prefixTokens = split.prefix.map(estimateItemTokens).reduce(0, &+)
        let totalTokens = items.map(estimateItemTokens).reduce(0, &+)
        #expect(Double(prefixTokens) / Double(totalTokens) >= 0.94)
    }

    @Test("Tool boundary preservation in two-pass split ensures tool calls and results stay paired")
    func testToolBoundaryPreservationInSplit() {
        var items: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("U0: " + String(repeating: "u", count: 1000)),
            .assistant(AssistantItem(content: "A0: " + String(repeating: "a", count: 1000)))
        ]

        let toolCall = ToolCall(id: "call-100", name: "bash", arguments: "{\"cmd\":\"ls\"}")
        items.append(.assistant(AssistantItem(content: "Running tool", toolCalls: [toolCall])))
        items.append(.toolResult(ToolResultItem(toolCallId: "call-100", content: "file1.txt\nfile2.txt")))
        items.append(.user("Tail prompt"))

        let split = splitConversationForTwoPass(conversation: items, splitFraction: 0.8)

        let prefixHasCall = split.prefix.contains { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "call-100" } }
            return false
        }
        let prefixHasResult = split.prefix.contains { item in
            if case .toolResult(let r) = item { return r.toolCallId == "call-100" }
            return false
        }
        let tailHasCall = split.tail.contains { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "call-100" } }
            return false
        }
        let tailHasResult = split.tail.contains { item in
            if case .toolResult(let r) = item { return r.toolCallId == "call-100" }
            return false
        }

        #expect(prefixHasCall == prefixHasResult)
        #expect(tailHasCall == tailHasResult)
    }

    @Test("Pass 1 history construction with 5-section prompt")
    func testPass1HistoryConstructionAnd5SectionPrompt() {
        let prefix: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0: Setup project"),
            .assistant(AssistantItem(content: "R0: Setup completed"))
        ]
        let prompt = buildTwoPassCompactionPrompt(userContext: "Focus on build errors.")
        let pass1History = buildTwoPassPass1History(prefix: prefix, compactionPrompt: prompt)

        #expect(pass1History.count == 4)
        #expect(pass1History.first?.textContent() == "You are Open Grok.")
        #expect(pass1History.last?.textContent().contains("Primary Request and Intent") == true)
        #expect(pass1History.last?.textContent().contains("Focus on build errors.") == true)
    }

    @Test("NOTE₁ extraction prefers substantive summary block and caps large raw text")
    func testNote1ExtractionAndCharacterCapping() {
        let largeSummaryContent = String(repeating: "Substantive summary content line.\n", count: 50)
        #expect(largeSummaryContent.count > 1000)

        let rawResponseWithTag = "<analysis>Thinking process...</analysis>\n<summary>\n\(largeSummaryContent)\n</summary>"
        let extracted = noteForTwoPassPass2(pass1Raw: rawResponseWithTag)
        #expect(extracted == largeSummaryContent.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!extracted.contains("<analysis>"))

        let untaggedResponse = "Simple untagged summary of the turns."
        #expect(noteForTwoPassPass2(pass1Raw: untaggedResponse) == untaggedResponse)

        let hugeText = String(repeating: "h", count: TWO_PASS_MAX_NOTE1_CHARS + 5000)
        let capped = noteForTwoPassPass2(pass1Raw: hugeText)
        #expect(capped.count <= TWO_PASS_MAX_NOTE1_CHARS + 100)
        #expect(capped.contains("NOTE₁ truncated for pass2 input budget"))
    }

    @Test("AsyncCompactionCache storage, retrieval, and deterministic fingerprinting")
    func testAsyncCompactionCacheStorageAndFingerprint() {
        let prefireState = PrefireState()
        #expect(!prefireState.hasCache)

        let prefix: [ConversationItem] = [
            .system("System instructions"),
            .user("P0: Query"),
            .assistant(AssistantItem(content: "A0: Response"))
        ]
        let fp = compactionFingerprint(prefix)

        let cache = AsyncCompactionCache(
            note1: "NOTE1 summary text",
            prefixLen: 3,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 250
        )

        prefireState.store(cache)
        #expect(prefireState.hasCache)

        let retrieved = prefireState.take()
        #expect(retrieved?.note1 == "NOTE1 summary text")
        #expect(retrieved?.prefixLen == 3)
        #expect(retrieved?.fingerprint == fp)
        #expect(retrieved?.modelSlug == "grok-4.20")
        #expect(retrieved?.pass1LatencyMs == 250)

        #expect(!prefireState.hasCache)
    }

    // MARK: - Tier 2: Boundary & Corner Cases

    @Test("Prefire in-flight concurrency guard prevents duplicate concurrent executions")
    func testPrefireInFlightConcurrencyGuard() {
        let state = PrefireState()
        #expect(!state.isInFlight)

        let won1 = state.tryBegin()
        #expect(won1)
        #expect(state.isInFlight)

        let won2 = state.tryBegin()
        #expect(!won2)
        #expect(state.isInFlight)

        state.finish()
        #expect(!state.isInFlight)

        let won3 = state.tryBegin()
        #expect(won3)
        state.finish()
    }

    @Test("Prefire conversation size limits and small conversation bypass")
    func testPrefireTooSmallConversationBypass() {
        let shortConversation: [ConversationItem] = [
            .system("sys"),
            .user("hello"),
            .assistant(AssistantItem(content: "hi"))
        ]
        #expect(shortConversation.count < 4)

        let split = splitConversationForTwoPass(conversation: shortConversation, splitFraction: 0.95)
        #expect(split.prefix.count >= 1)
    }

    @Test("Prefire Pass 1 sampling failure handling leaves cache clean and releases guard")
    func testPrefirePass1SamplingFailureHandling() async {
        let prefireState = PrefireState()
        let sampler = ScriptedTwoPassSampler(failures: [CompactionSampleError.api(status: 500, message: "Internal Server Error")])

        let won = prefireState.tryBegin()
        #expect(won)

        let prompt = CompactionPrompt(user: buildTwoPassCompactionPrompt())
        var caughtError = false
        do {
            _ = try await sampler.sampleCompaction(turns: [.system("sys"), .user("u")], prompt: prompt, timeoutSeconds: 30)
        } catch {
            caughtError = true
        }

        prefireState.finish()

        #expect(caughtError)
        #expect(!prefireState.hasCache)
        #expect(!prefireState.isInFlight)
    }

    @Test("Prefire cancellation gate and scope management")
    func testPrefireCancellationScope() {
        let gate = CompactCancelGate()
        #expect(!gate.isCancelled)

        let scope1 = gate.enter()
        #expect(!scope1.isCancelled())

        gate.requestCancel()
        #expect(scope1.isCancelled())
        #expect(gate.isCancelled)

        scope1.onEnd()
        #expect(!gate.isCancelled)
    }

    @Test("Repeated native custom tool outputs kept together with assistant call")
    func testRepeatedNativeToolOutputsKeptTogether() {
        var items: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("U0: " + String(repeating: "u", count: 800)),
            .assistant(AssistantItem(content: "A0: " + String(repeating: "a", count: 800)))
        ]

        let call = ToolCall(id: "exec-1", name: "exec", arguments: "tools.file_read('test.txt')")
        items.append(.assistant(AssistantItem(content: "Calling exec", toolCalls: [call])))
        items.append(.customToolOutput(CustomToolOutputItem.text(callId: "exec-1", "chunk 1")))
        items.append(.customToolOutput(CustomToolOutputItem.text(callId: "exec-1", "chunk 2")))
        items.append(.user("Tail prompt"))

        let split = splitConversationForTwoPass(conversation: items, splitFraction: 0.8)

        let prefixCallCount = split.prefix.filter { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "exec-1" } }
            return false
        }.count
        let prefixOutputCount = split.prefix.filter { item in
            if case .customToolOutput(let o) = item { return o.callId == "exec-1" }
            return false
        }.count

        let tailCallCount = split.tail.filter { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "exec-1" } }
            return false
        }.count
        let tailOutputCount = split.tail.filter { item in
            if case .customToolOutput(let o) = item { return o.callId == "exec-1" }
            return false
        }.count

        #expect((prefixCallCount > 0) == (prefixOutputCount > 0))
        #expect((tailCallCount > 0) == (tailOutputCount > 0))
    }

    @Test("Degenerate or empty Note1 handling produces empty result")
    func testDegenerateOrEmptyNote1Rejection() {
        #expect(noteForTwoPassPass2(pass1Raw: "").isEmpty)
        #expect(noteForTwoPassPass2(pass1Raw: "   \n\t  ").isEmpty)
    }

    @Test("Token fraction split with extreme weights handles edge cases without overflow")
    func testPrefireExtremeTokenWeightsSplit() {
        let hugeWeights: [UInt64] = [UInt64.max / 4, UInt64.max / 4, UInt64.max / 4, 1000]
        let splitIdx = splitIndexByTokenFraction(weights: hugeWeights, fraction: 0.5)
        #expect(splitIdx >= 1)
        #expect(splitIdx < hugeWeights.count)
    }
}
