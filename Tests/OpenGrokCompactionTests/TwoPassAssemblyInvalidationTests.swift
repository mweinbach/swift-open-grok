// TwoPassAssemblyInvalidationTests.swift
//
// Tests for Two-Pass Assembly & Invalidation (Feature 4):
// - Pass 2 4-part history assembly (System + NOTE₁ Carrier + Tail + Special Instruction Turn)
// - Validation of valid cache application and consumption
// - FNV-1a prefix fingerprint matching
// - In-flight Pass 1 task await before Pass 2
// - Multi-dimensional cache invalidation (content edits, model switch, rewinds)
// - Degenerate summary and sampler failure fallback

import Foundation
import OpenGrokChatState
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTokenEstimation
import Testing
@testable import OpenGrokCompaction

// MARK: - Test Doubles

private final class ScriptedAssemblySampler: CompactionSampler, @unchecked Sendable {
    typealias Item = ConversationItem

    private let lock = NSLock()
    private var responses: [String]
    private var failures: [CompactionSampleError?]
    private var sampledTurns: [[ConversationItem]] = []

    init(responses: [String] = [], failures: [CompactionSampleError?] = []) {
        self.responses = responses
        self.failures = failures
    }

    var recordedSampledTurns: [[ConversationItem]] {
        lock.lock(); defer { lock.unlock() }
        return sampledTurns
    }

    private func recordAndNext(turns: [ConversationItem]) -> (failure: CompactionSampleError?, response: String) {
        lock.lock()
        defer { lock.unlock() }
        sampledTurns.append(turns)
        let failure = failures.isEmpty ? nil : failures.removeFirst()
        let response = responses.isEmpty
            ? "<summary>\n" + String(repeating: "Substantive pass2 final summary text line.\n", count: 40) + "</summary>"
            : responses.removeFirst()
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

@Suite("Two-Pass Assembly & Invalidation Tests (Feature 4)")
struct TwoPassAssemblyInvalidationTests {

    // MARK: - Tier 1: Feature Coverage

    @Test("Pass 2 history assembly layout contains System, NOTE₁ Carrier, Tail, and Special Instruction Turn")
    func testPass2HistoryAssemblyLayout() {
        let prefix: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0: Setup"),
            .assistant(AssistantItem(content: "R0: Setup done")),
            .user("P1: Test"),
            .assistant(AssistantItem(content: "R1: Test done"))
        ]
        let tail: [ConversationItem] = [
            .user("P2: Recent user query"),
            .assistant(AssistantItem(content: "R2: Recent assistant answer"))
        ]
        let note1 = "NOTE1 summary covering P0 and P1."
        let prompt = "Summarize the turns."

        let history = buildTwoPassPass2History(
            prefix: prefix,
            tail: tail,
            note1: note1,
            compactionPrompt: prompt
        )

        // Expected count: 1 system + 1 carrier + 2 tail items + 1 special instruction turn = 5 items
        #expect(history.count == 5)
        #expect(history[0].textContent() == "You are Open Grok.")

        // Carrier turn
        #expect(history[1].textContent().contains("Your conversation was summarized due to context constraints."))
        #expect(history[1].textContent().contains("<summary_content>\nNOTE1 summary covering P0 and P1.\n</summary_content>"))

        // Verbatim tail
        #expect(history[2].textContent() == "P2: Recent user query")
        #expect(history[3].textContent() == "R2: Recent assistant answer")

        // Special instruction turn
        #expect(history[4].textContent().contains("This is a special compaction case (two-pass / hierarchical summarization)."))
        #expect(history[4].textContent().contains("Incorporate the **entire** prior summary below into your final note"))
    }

    @Test("Successful two-pass apply with valid cache produces NOTE₂ and consumes cache")
    func testSuccessfulTwoPassApplyWithValidCache() async {
        let prefireState = PrefireState()
        let conversation: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0"),
            .assistant(AssistantItem(content: "R0")),
            .user("P1"),
            .assistant(AssistantItem(content: "R1")),
            .user("P2_tail"),
            .assistant(AssistantItem(content: "R2_tail"))
        ]
        let prefixLen = 5
        let fp = fingerprintPrefix(Array(conversation[..<prefixLen]))

        let cache = AsyncCompactionCache(
            note1: "Valid NOTE1 text",
            prefixLen: prefixLen,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 150
        )
        prefireState.store(cache)
        #expect(prefireState.hasCache)

        let validSummary = "<summary>\n" + String(repeating: "Final pass 2 summary text line.\n", count: 40) + "</summary>"
        let sampler = ScriptedAssemblySampler(responses: [validSummary])

        let result = await tryTwoPassPass2Apply(
            prefireState: prefireState,
            liveConversation: conversation,
            currentModelSlug: "grok-4.20",
            sampler: sampler,
            userContext: "Focus on memory."
        )

        #expect(result != nil)
        #expect(result?.contains("Final pass 2 summary text line.") == true)
        #expect(!prefireState.hasCache) // Single-use consumption
        #expect(sampler.recordedSampledTurns.count == 1)
    }

    @Test("Prefix fingerprint matching validation detects exact matches")
    func testPrefixFingerprintMatchingValidation() {
        let prefix: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("How do fingerprints work?"),
            .assistant(AssistantItem(content: "They use 64-bit FNV-1a hashing."))
        ]
        let fp1 = fingerprintPrefix(prefix)
        let fp2 = fingerprintPrefix(prefix)
        #expect(fp1 == fp2)
        #expect(fp1 != 0)

        var alteredPrefix = prefix
        alteredPrefix[1] = .user("How do fingerprints work?!")
        let fp3 = fingerprintPrefix(alteredPrefix)
        #expect(fp1 != fp3)
    }

    @Test("In-flight Pass 1 task await before Pass 2 completes before cache evaluation")
    func testInFlightPass1AwaitBeforePass2() async {
        let prefireState = PrefireState()
        let conversation: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0"),
            .assistant(AssistantItem(content: "R0")),
            .user("P1_tail")
        ]
        let fp = fingerprintPrefix(Array(conversation[..<3]))

        let won = prefireState.tryBegin()
        #expect(won)

        let bgTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            prefireState.store(AsyncCompactionCache(
                note1: "Background cached NOTE1",
                prefixLen: 3,
                fingerprint: fp,
                modelSlug: "grok-4.20",
                pass1LatencyMs: 20
            ))
            prefireState.finish()
        }
        prefireState.setHandle(bgTask)

        let sampler = ScriptedAssemblySampler()
        let result = await tryTwoPassPass2Apply(
            prefireState: prefireState,
            liveConversation: conversation,
            currentModelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result != nil)
        #expect(!prefireState.hasCache)
        #expect(!prefireState.isInFlight)
    }

    @Test("Special Pass 2 prompt injection includes duplicate summary and explicit non-omission rules")
    func testSpecialPass2PromptInjection() {
        let note1 = "Detailed historical decisions on SQLite vs JSON."
        let promptText = "Preserve database schema changes."
        let specialUser = formatTwoPassSpecialPass2User(note1: note1, compactionPrompt: promptText)

        #expect(specialUser.contains("Critical requirements:"))
        #expect(specialUser.contains("do not omit sections, defer to \"see prior compaction\", or drop early history"))
        #expect(specialUser.contains("<summary_content>\nDetailed historical decisions on SQLite vs JSON.\n</summary_content>"))
        #expect(specialUser.contains("Preserve database schema changes."))
    }

    @Test("Cache consumption is strictly single-use")
    func testCacheConsumptionIsSingleUse() {
        let prefireState = PrefireState()
        let cache = AsyncCompactionCache(
            note1: "NOTE1",
            prefixLen: 2,
            fingerprint: 12345,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 50
        )
        prefireState.store(cache)
        #expect(prefireState.hasCache)

        let firstTake = prefireState.take()
        #expect(firstTake != nil)
        #expect(firstTake?.note1 == "NOTE1")
        #expect(!prefireState.hasCache)

        let secondTake = prefireState.take()
        #expect(secondTake == nil)
    }

    // MARK: - Tier 2: Boundary & Corner Cases

    @Test("Cache invalidation on prefix content edit falls back to single-pass")
    func testCacheInvalidationOnPrefixContentEdit() async {
        let prefireState = PrefireState()
        let originalHistory: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0: Original prompt"),
            .assistant(AssistantItem(content: "R0: Response")),
            .user("P1_tail")
        ]
        let fp = fingerprintPrefix(Array(originalHistory[..<3]))
        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1",
            prefixLen: 3,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 10
        ))

        // History was edited in place (e.g. user edited prompt 0)
        var editedHistory = originalHistory
        editedHistory[1] = .user("P0: Edited user prompt")

        let sampler = ScriptedAssemblySampler()
        let result = await tryTwoPassPass2Apply(
            prefireState: prefireState,
            liveConversation: editedHistory,
            currentModelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result == nil) // Rejected as stale
        #expect(sampler.recordedSampledTurns.isEmpty)
    }

    @Test("Cache invalidation on model switch falls back to single-pass")
    func testCacheInvalidationOnModelSwitch() async {
        let prefireState = PrefireState()
        let history: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0"),
            .assistant(AssistantItem(content: "R0")),
            .user("P1_tail")
        ]
        let fp = fingerprintPrefix(Array(history[..<3]))
        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1",
            prefixLen: 3,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 10
        ))

        // Model changed to grok-4-fast
        let sampler = ScriptedAssemblySampler()
        let result = await tryTwoPassPass2Apply(
            prefireState: prefireState,
            liveConversation: history,
            currentModelSlug: "grok-4-fast",
            sampler: sampler
        )

        #expect(result == nil) // Rejected due to model slug mismatch
        #expect(sampler.recordedSampledTurns.isEmpty)
    }

    @Test("Cache invalidation on rewind truncation falls back to single-pass")
    func testCacheInvalidationOnRewindTruncation() async {
        let prefireState = PrefireState()
        let fp: UInt64 = 98765
        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1",
            prefixLen: 10, // expects 10 prefix items
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 10
        ))

        // Session was rewound, so live conversation only has 4 items
        let shortConversation: [ConversationItem] = [
            .system("sys"),
            .user("P0"),
            .assistant(AssistantItem(content: "R0")),
            .user("P1")
        ]

        let sampler = ScriptedAssemblySampler()
        let result = await tryTwoPassPass2Apply(
            prefireState: prefireState,
            liveConversation: shortConversation,
            currentModelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result == nil) // Rejected: prefixLen > liveConversation.count
    }

    @Test("Degenerate Pass 2 summary triggers fallback")
    func testDegeneratePass2SummaryFallback() async {
        let prefireState = PrefireState()
        let conversation: [ConversationItem] = [
            .system("sys"),
            .user("P0"),
            .assistant(AssistantItem(content: "R0")),
            .user("P1_tail")
        ]
        let fp = fingerprintPrefix(Array(conversation[..<3]))
        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1",
            prefixLen: 3,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 10
        ))

        // Sampler returns a degenerate summary (< 500 chars)
        let sampler = ScriptedAssemblySampler(responses: ["<summary>Too short.</summary>"])
        let result = await tryTwoPassPass2Apply(
            prefireState: prefireState,
            liveConversation: conversation,
            currentModelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result == nil) // Rejected as degenerate
    }

    @Test("Pass 2 sampler failure triggers safe fallback without throwing")
    func testPass2SamplerFailureFallback() async {
        let prefireState = PrefireState()
        let conversation: [ConversationItem] = [
            .system("sys"),
            .user("P0"),
            .assistant(AssistantItem(content: "R0")),
            .user("P1_tail")
        ]
        let fp = fingerprintPrefix(Array(conversation[..<3]))
        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1",
            prefixLen: 3,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 10
        ))

        let sampler = ScriptedAssemblySampler(failures: [CompactionSampleError.api(status: 503, message: "Service Unavailable")])
        let result = await tryTwoPassPass2Apply(
            prefireState: prefireState,
            liveConversation: conversation,
            currentModelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result == nil)
    }

    @Test("Interleaved tool calls in tail are preserved in exact sequence")
    func testInterleavedToolCallsInTailPreservation() {
        let prefix: [ConversationItem] = [.system("sys"), .user("P0"), .assistant(AssistantItem(content: "R0"))]
        let toolCall = ToolCall(id: "call-tail-1", name: "edit_file", arguments: "{\"path\":\"a.swift\"}")
        let tail: [ConversationItem] = [
            .user("P1: Tail prompt"),
            .assistant(AssistantItem(content: "Calling tool", toolCalls: [toolCall])),
            .toolResult(ToolResultItem(toolCallId: "call-tail-1", content: "saved")),
            .assistant(AssistantItem(content: "Done edit"))
        ]

        let history = buildTwoPassPass2History(
            prefix: prefix,
            tail: tail,
            note1: "NOTE1",
            compactionPrompt: "Prompt"
        )

        #expect(history.count == 7) // 1 sys + 1 carrier + 4 tail + 1 special
        #expect(history[2].textContent() == "P1: Tail prompt")
        #expect(history[3].textContent() == "Calling tool")
        #expect(history[4].textContent() == "saved")
        #expect(history[5].textContent() == "Done edit")
    }

    @Test("Prefix without system prompt injects default assistant preamble")
    func testPrefixWithoutSystemPromptInjectsDefaultAssistantPreamble() {
        let prefixWithoutSystem: [ConversationItem] = [
            .user("P0"),
            .assistant(AssistantItem(content: "R0"))
        ]
        let history = buildTwoPassPass2History(
            prefix: prefixWithoutSystem,
            tail: [.user("P1")],
            note1: "NOTE1",
            compactionPrompt: "Prompt"
        )

        #expect(history.first?.textContent() == "You are a helpful assistant.")
    }
}
