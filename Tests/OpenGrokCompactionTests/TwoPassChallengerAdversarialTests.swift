// TwoPassChallengerAdversarialTests.swift
//
// Open Grok — Challenger 2 Adversarial Stress Suite for Milestone 2 (Two-Pass Prefire Compaction)
// Empirically tests:
// 1. Concurrent prefire execution & in-flight Pass 1 task handling during threshold races
// 2. Cache invalidation under rapid mutations: prompt rewinds, provider switches (xAI/Codex/Kimi/Fireworks/DeepSeek), prefix edits
// 3. Robust fallback to single-pass compaction on Pass 2 timeouts, sampler errors, and degenerate summaries
// 4. Concurrency safety, memory isolation, and tool-call boundary invariants

import Foundation
import OpenGrokChatState
import OpenGrokCompaction
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTokenEstimation
import Testing

// MARK: - Test Doubles

private final class AdversarialScriptedSampler: CompactionSampler, @unchecked Sendable {
    typealias Item = ConversationItem

    private let lock = NSLock()
    private var responses: [String]
    private var failures: [Error?]
    private var delayNanoseconds: UInt64
    private var recordedCalls: [[ConversationItem]] = []

    init(
        responses: [String] = [],
        failures: [Error?] = [],
        delayNanoseconds: UInt64 = 0
    ) {
        self.responses = responses
        self.failures = failures
        self.delayNanoseconds = delayNanoseconds
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls.count
    }

    var calls: [[ConversationItem]] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    func sampleCompaction(
        turns: [ConversationItem],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let (failure, response) = lock.withLock { () -> (Error?, String) in
            recordedCalls.append(turns)
            let fail = failures.isEmpty ? nil : failures.removeFirst()
            let resp = responses.isEmpty
                ? "<summary>\n" + String(repeating: "Valid substantive adversarial summary turn line.\n", count: 40) + "</summary>"
                : responses.removeFirst()
            return (fail, resp)
        }

        if let failure {
            throw failure
        }
        return LLMCompactionOutput(response: response)
    }
}

// MARK: - Test Suite

@Suite("Two-Pass Challenger Concurrency & Invalidation Adversarial Tests", .serialized)
struct TwoPassChallengerAdversarialTests {

    // MARK: - 1. Concurrent Prefire Execution & In-Flight Pass 1 Races

    @Test("In-flight Pass 1 task is cleanly awaited and applied when compaction threshold is reached before Pass 1 finishes")
    func testInFlightPass1AwaitedAndAppliedWhenCompactionThresholdReached() async {
        let prefireState = PrefireState()
        let conv: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("U0: Initialize system"),
            .assistant(AssistantItem(content: "A0: System initialized")),
            .user("U1: Run migration"),
            .assistant(AssistantItem(content: "A1: Migration completed")),
            .user("U2_tail: Status query"),
            .assistant(AssistantItem(content: "A2_tail: Status OK"))
        ]
        let prefixLen = 5
        let fp = fingerprintPrefix(Array(conv[..<prefixLen]))

        #expect(prefireState.tryBegin())

        // Pass 1 is running asynchronously with a 30ms sleep
        let pass1Task = Task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            prefireState.store(AsyncCompactionCache(
                note1: "NOTE1: Generated during background pass 1",
                prefixLen: prefixLen,
                fingerprint: fp,
                modelSlug: "grok-4.20",
                pass1LatencyMs: 30
            ))
            prefireState.finish()
        }
        prefireState.setHandle(pass1Task)

        #expect(prefireState.isInFlight)

        let validPass2Summary = "<summary>\n" + String(repeating: "Pass 2 consolidated final note content.\n", count: 35) + "</summary>"
        let sampler = AdversarialScriptedSampler(responses: [validPass2Summary])

        // Pass 2 arrives while Pass 1 is in-flight; must await handle and succeed
        let result = await tryTwoPassPass2Apply(
            prefire: prefireState,
            conversation: conv,
            modelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result != nil)
        #expect(result?.contains("Pass 2 consolidated final note content.") == true)
        #expect(!prefireState.isInFlight)
        #expect(!prefireState.hasCache) // Cache consumed
        #expect(sampler.callCount == 1)
    }

    @Test("In-flight Pass 1 failure or timeout leaves prefire state clean and returns nil for single-pass fallback")
    func testInFlightPass1FailsGracefullyAndAllowsFallback() async {
        let prefireState = PrefireState()
        let conv: [ConversationItem] = [
            .system("sys"),
            .user("U0"),
            .assistant(AssistantItem(content: "A0")),
            .user("U1_tail")
        ]

        #expect(prefireState.tryBegin())

        // Pass 1 fails and finishes without caching
        let failingTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000)
            // Error encountered; cache not stored
            prefireState.finish()
        }
        prefireState.setHandle(failingTask)

        let sampler = AdversarialScriptedSampler()
        let result = await tryTwoPassPass2Apply(
            prefire: prefireState,
            conversation: conv,
            modelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result == nil)
        #expect(!prefireState.isInFlight)
        #expect(!prefireState.hasCache)
        #expect(sampler.callCount == 0) // Pass 2 was never sampled
    }

    @Test("Concurrent prefire trigger races strictly grant exactly one winner")
    func testConcurrentPrefireTriggerRaceOnlyOneWins() async {
        let state = PrefireState()

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    state.tryBegin()
                }
            }

            var winCount = 0
            for await won in group {
                if won { winCount += 1 }
            }

            #expect(winCount == 1)
            #expect(state.isInFlight)
        }

        state.finish()
        #expect(!state.isInFlight)
        #expect(state.tryBegin())
        state.finish()
    }

    @Test("In-flight Pass 1 incorporates newly appended tail turns seamlessly into Pass 2")
    func testInFlightPass1IncorporatesAppendedTailTurns() async {
        let prefireState = PrefireState()
        let initialConv: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("U0"),
            .assistant(AssistantItem(content: "A0")),
            .user("U1"),
            .assistant(AssistantItem(content: "A1"))
        ]
        let prefixLen = initialConv.count
        let fp = fingerprintPrefix(initialConv)

        #expect(prefireState.tryBegin())

        let pass1Task = Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            prefireState.store(AsyncCompactionCache(
                note1: "NOTE1: Summarized first 5 turns",
                prefixLen: prefixLen,
                fingerprint: fp,
                modelSlug: "grok-4.20",
                pass1LatencyMs: 20
            ))
            prefireState.finish()
        }
        prefireState.setHandle(pass1Task)

        // While Pass 1 is running, turn loop appends 2 new turns
        var updatedConv = initialConv
        updatedConv.append(.user("U2_new: What is the CPU load?"))
        updatedConv.append(.assistant(AssistantItem(content: "A2_new: CPU load is 12%")))

        let sampler = AdversarialScriptedSampler()
        let result = await tryTwoPassPass2Apply(
            prefire: prefireState,
            conversation: updatedConv,
            modelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result != nil)
        #expect(sampler.callCount == 1)

        // Verify that the sampled Pass 2 history received the 2 new tail turns verbatim
        if let pass2Turns = sampler.calls.first {
            let pass2Text = pass2Turns.map { $0.textContent() }.joined(separator: " ")
            #expect(pass2Text.contains("U2_new: What is the CPU load?"))
            #expect(pass2Text.contains("A2_new: CPU load is 12%"))
            #expect(pass2Text.contains("NOTE1: Summarized first 5 turns"))
        }
    }

    // MARK: - 2. Cache Invalidation Under Rapid Mutations & Provider Switches

    @Test("Prompt rewind across compaction bounds immediately invalidates cache safely")
    func testPromptRewindAcrossCompactionBoundsInvalidatesCache() async {
        let prefireState = PrefireState()
        let fp: UInt64 = 888_999_111
        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1 covering 12 turns",
            prefixLen: 12,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 15
        ))

        // Live conversation was rewound to 3 items
        let rewoundConv: [ConversationItem] = [
            .system("System prompt"),
            .user("U0: First prompt"),
            .assistant(AssistantItem(content: "A0: First answer"))
        ]

        let sampler = AdversarialScriptedSampler()
        let result = await tryTwoPassPass2Apply(
            prefire: prefireState,
            conversation: rewoundConv,
            modelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result == nil)
        #expect(!prefireState.hasCache)
        #expect(sampler.callCount == 0)
    }

    @Test("Multi-provider switch matrix invalidates cache and enforces provider isolation")
    func testMultiProviderSwitchMatrixCacheInvalidation() async {
        let models = [
            ("grok-4.20", ModelProvider.xai),
            ("gpt-4o", ModelProvider.codex),
            ("moonshot-v1", ModelProvider.kimi),
            ("accounts/fireworks/models/deepseek-v3", ModelProvider.fireworks),
            ("deepseek-chat", ModelProvider.deepseek),
            ("wafer-default", ModelProvider.wafer),
            ("glm-4", ModelProvider.zai)
        ]

        let conv: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("U0"),
            .assistant(AssistantItem(content: "A0")),
            .user("U1_tail")
        ]
        let fp = fingerprintPrefix(Array(conv[..<3]))

        // Test every pair of model switches (fromModel -> toModel)
        for (fromSlug, _) in models {
            for (toSlug, toProvider) in models {
                let state = PrefireState()
                state.store(AsyncCompactionCache(
                    note1: "NOTE1 cached under \(fromSlug)",
                    prefixLen: 3,
                    fingerprint: fp,
                    modelSlug: fromSlug,
                    pass1LatencyMs: 10
                ))

                let sampler = AdversarialScriptedSampler()
                let result = await tryTwoPassPass2Apply(
                    prefire: state,
                    conversation: conv,
                    modelSlug: toSlug,
                    sampler: sampler
                )

                if fromSlug == toSlug {
                    #expect(result != nil, "Expected cache hit for same model \(fromSlug)")
                } else {
                    #expect(result == nil, "Expected cache invalidation when switching from \(fromSlug) to \(toSlug)")
                }

                // Verify Codex provider guard
                if toProvider == .codex {
                    #expect(!shouldPrefireTwoPass(
                        estimatedTotalTokens: 90_000,
                        contextWindow: 100_000,
                        thresholdPercent: 85,
                        leadPercent: 10,
                        provider: toProvider
                    ))
                }
            }
        }
    }

    @Test("Prefix turn content mutation invalidates cache via 64-bit FNV-1a fingerprint mismatch")
    func testPrefixTurnContentMutationInvalidatesCache() async {
        let prefireState = PrefireState()
        let conv: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("U0: Original user prompt text"),
            .assistant(AssistantItem(content: "A0: Original assistant answer")),
            .user("U1_tail")
        ]
        let fp = fingerprintPrefix(Array(conv[..<3]))

        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1",
            prefixLen: 3,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 5
        ))

        // User edits prompt in-place
        var editedConv = conv
        editedConv[1] = .user("U0: Edited user prompt text")

        let sampler = AdversarialScriptedSampler()
        let result = await tryTwoPassPass2Apply(
            prefire: prefireState,
            conversation: editedConv,
            modelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result == nil)
        #expect(!prefireState.hasCache)
        #expect(sampler.callCount == 0)
    }

    @Test("System prompt alteration invalidates cached NOTE₁")
    func testSystemPromptAlterationInvalidatesCache() async {
        let prefireState = PrefireState()
        let conv: [ConversationItem] = [
            .system("System prompt version 1"),
            .user("U0"),
            .assistant(AssistantItem(content: "A0")),
            .user("U1_tail")
        ]
        let fp = fingerprintPrefix(Array(conv[..<3]))

        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1",
            prefixLen: 3,
            fingerprint: fp,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 5
        ))

        var alteredConv = conv
        alteredConv[0] = .system("System prompt version 2 (with new instructions)")

        let sampler = AdversarialScriptedSampler()
        let result = await tryTwoPassPass2Apply(
            prefire: prefireState,
            conversation: alteredConv,
            modelSlug: "grok-4.20",
            sampler: sampler
        )

        #expect(result == nil)
        #expect(sampler.callCount == 0)
    }

    // MARK: - 3. Fallback to Single-Pass Compaction

    @Test("Pass 2 fallback on degenerate and short summaries")
    func testPass2FallbackOnDegenerateSummaries() async {
        let degenerateResponses = [
            "",
            "   \n\t  ",
            "Short summary of only twenty words.",
            String(repeating: "A", count: 499) // Exactly 499 chars (< 500 threshold)
        ]

        for resp in degenerateResponses {
            let state = PrefireState()
            let conv: [ConversationItem] = [
                .system("sys"),
                .user("U0"),
                .assistant(AssistantItem(content: "A0")),
                .user("U1_tail")
            ]
            let fp = fingerprintPrefix(Array(conv[..<3]))

            state.store(AsyncCompactionCache(
                note1: "Valid NOTE1",
                prefixLen: 3,
                fingerprint: fp,
                modelSlug: "grok-4.20",
                pass1LatencyMs: 5
            ))

            let sampler = AdversarialScriptedSampler(responses: [resp])
            let result = await tryTwoPassPass2Apply(
                prefire: state,
                conversation: conv,
                modelSlug: "grok-4.20",
                sampler: sampler
            )

            #expect(result == nil, "Expected rejection for degenerate response of length \(resp.count)")
        }
    }

    @Test("Pass 2 fallback on sampler errors, timeouts, and HTTP status failures without throwing")
    func testPass2FallbackOnSamplerErrors() async {
        let errors: [Error] = [
            CompactionSampleError.timeout(timeoutSeconds: 30, collectedBytes: 0),
            CompactionSampleError.api(status: 500, message: "Internal server error"),
            CompactionSampleError.api(status: 503, message: "Model overloaded"),
            CompactionSampleError.emptyResponse,
            CompactionSampleError.cancelled,
            NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        ]

        for err in errors {
            let state = PrefireState()
            let conv: [ConversationItem] = [
                .system("sys"),
                .user("U0"),
                .assistant(AssistantItem(content: "A0")),
                .user("U1_tail")
            ]
            let fp = fingerprintPrefix(Array(conv[..<3]))

            state.store(AsyncCompactionCache(
                note1: "Valid NOTE1",
                prefixLen: 3,
                fingerprint: fp,
                modelSlug: "grok-4.20",
                pass1LatencyMs: 5
            ))

            let sampler = AdversarialScriptedSampler(failures: [err])
            let result = await tryTwoPassPass2Apply(
                prefire: state,
                conversation: conv,
                modelSlug: "grok-4.20",
                sampler: sampler
            )

            #expect(result == nil, "Expected safe fallback for error: \(err)")
        }
    }

    @Test("Tool boundary snapping with interleaved reasoning, tool calls, and multiple custom outputs")
    func testToolBoundarySnappingInterleavedReasoningAndCustomOutputs() {
        let call1 = ToolCall(id: "call-1", name: "exec", arguments: "tools.file_read('a.swift')")
        let call2 = ToolCall(id: "call-2", name: "bash", arguments: "{\"command\":\"swift test\"}")

        let complexHistory: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0: Setup"),
            .assistant(AssistantItem(content: "A0: Done")),
            .user("P1: Complex action"),
            .reasoning(ReasoningItem(id: "r1", summary: [.summaryText(text: "Reasoning about tool call 1")])),
            .assistant(AssistantItem(content: "Executing JS", toolCalls: [call1])),
            .customToolOutput(CustomToolOutputItem.text(callId: "call-1", "chunk 1")),
            .customToolOutput(CustomToolOutputItem.text(callId: "call-1", "chunk 2")),
            .assistant(AssistantItem(content: "Executing bash", toolCalls: [call2])),
            .toolResult(ToolResultItem(toolCallId: "call-2", content: "Test passed")),
            .user("P2_tail: Verify result"),
            .assistant(AssistantItem(content: "A2_tail: Verified"))
        ]

        // Split across various fractions
        for frac in [0.3, 0.5, 0.7, 0.85, 0.95] {
            let split = splitConversationForTwoPass(complexHistory, splitFraction: frac)
            #expect(split.prefix.count > 0)
            #expect(split.tail.count > 0)
            #expect(split.prefix.count + split.tail.count == complexHistory.count)

            // Verify call1 and its custom outputs are in the same segment
            let pHasCall1 = split.prefix.contains { if case .assistant(let a) = $0 { return a.toolCalls.contains { $0.callId == "call-1" } } else { return false } }
            let pHasOutput1 = split.prefix.contains { if case .customToolOutput(let o) = $0 { return o.callId == "call-1" } else { return false } }
            #expect(pHasCall1 == pHasOutput1)

            // Verify call2 and its tool result are in the same segment
            let pHasCall2 = split.prefix.contains { if case .assistant(let a) = $0 { return a.toolCalls.contains { $0.callId == "call-2" } } else { return false } }
            let pHasResult2 = split.prefix.contains { if case .toolResult(let r) = $0 { return r.toolCallId == "call-2" } else { return false } }
            #expect(pHasCall2 == pHasResult2)
        }
    }
}
