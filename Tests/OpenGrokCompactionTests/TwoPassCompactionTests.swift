// TwoPassCompactionTests.swift
//
// Pure algorithm unit test suite for Two-Pass Prefire Compaction:
// - Token fraction split calculations & boundary clamping
// - Tool boundary snapping (Assistant toolCalls bonded with ToolResults/CustomToolOutputs)
// - Substantive <summary> extraction & 12k char capping
// - Deterministic 64-bit FNV-1a prefix fingerprinting
// - 5-section prompt formatting, carrier generation, and Pass 1/Pass 2 history construction

import Foundation
import OpenGrokChatState
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTokenEstimation
import Testing
@testable import OpenGrokCompaction

@Suite("Two-Pass Compaction Pure Algorithm Tests")
struct TwoPassCompactionTests {

    // MARK: - Tier 1: Feature Coverage (Pure Algorithms & Happy Paths)

    @Test("Split index by token fraction calculates accurate 95% boundary across uniform distributions")
    func testSplitIndexByTokenFractionStandardRange() {
        // 40 items with 10 tokens each = 400 total tokens. 95% = 380 tokens -> index 38
        let weights: [UInt64] = Array(repeating: 10, count: 40)
        let splitIdx = splitIndexByTokenFraction(weights: weights, fraction: 0.95)
        #expect(splitIdx == 38)

        // 50% fraction -> index 20
        let halfIdx = splitIndexByTokenFraction(weights: weights, fraction: 0.50)
        #expect(halfIdx == 20)

        // Fraction clamped between 0.05 and 0.95
        let lowFracIdx = splitIndexByTokenFraction(weights: weights, fraction: 0.01)
        #expect(lowFracIdx == 2) // 5% of 40 = 2

        let highFracIdx = splitIndexByTokenFraction(weights: weights, fraction: 0.99)
        #expect(highFracIdx == 38) // 95% of 40 = 38
    }

    @Test("Split conversation preserves non-empty prefix and non-empty tail for histories with >= 2 items")
    func testSplitConversationLeavesNonEmptyTail() {
        let items: [ConversationItem] = (0..<10).map { i in
            .user("User message \(i): " + String(repeating: "hello ", count: 20))
        }

        let split = splitConversationForTwoPass(items, splitFraction: 0.95)
        #expect(split.prefix.count > 0)
        #expect(split.tail.count > 0)
        #expect(split.prefix.count + split.tail.count == items.count)
        #expect(split.splitIndex == split.prefix.count)
    }

    @Test("Tool boundary snapping never separates an assistant tool call from its tool result")
    func testToolBoundarySnappingAssistantCallWithToolResult() {
        let toolCall = ToolCall(id: "call-xyz", name: "bash", arguments: "{\"command\":\"ls\"}")
        let conv: [ConversationItem] = [
            .user("U0: " + String(repeating: "a", count: 500)),
            .assistant(AssistantItem(content: "A0: " + String(repeating: "b", count: 500))),
            .assistant(AssistantItem(content: "Calling tool", toolCalls: [toolCall])),
            .toolResult(ToolResultItem(toolCallId: "call-xyz", content: "file1.txt\nfile2.txt")),
            .user("U1: Next prompt")
        ]

        // Splitting around index 3 should snap past the toolResult
        let split = splitConversationForTwoPass(conv, splitFraction: 0.70)

        let prefixHasCall = split.prefix.contains { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "call-xyz" } }
            return false
        }
        let prefixHasResult = split.prefix.contains { item in
            if case .toolResult(let r) = item { return r.toolCallId == "call-xyz" }
            return false
        }
        let tailHasCall = split.tail.contains { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "call-xyz" } }
            return false
        }
        let tailHasResult = split.tail.contains { item in
            if case .toolResult(let r) = item { return r.toolCallId == "call-xyz" }
            return false
        }

        #expect(prefixHasCall == prefixHasResult)
        #expect(tailHasCall == tailHasResult)
    }

    @Test("Tool boundary snapping preserves multiple custom tool outputs with assistant call")
    func testToolBoundarySnappingMultipleCustomToolOutputs() {
        let toolCall = ToolCall(id: "exec-v8", name: "exec", arguments: "tools.file_read('x.swift')")
        let conv: [ConversationItem] = [
            .system("System prompt"),
            .user("U0: " + String(repeating: "u", count: 600)),
            .assistant(AssistantItem(content: "Executing JS", toolCalls: [toolCall])),
            .customToolOutput(CustomToolOutputItem.text(callId: "exec-v8", "chunk 1")),
            .customToolOutput(CustomToolOutputItem.text(callId: "exec-v8", "chunk 2")),
            .customToolOutput(CustomToolOutputItem.text(callId: "exec-v8", "chunk 3")),
            .user("Tail prompt")
        ]

        let split = splitConversationForTwoPass(conv, splitFraction: 0.60)

        let prefixCallCount = split.prefix.filter { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "exec-v8" } }
            return false
        }.count
        let prefixOutputs = split.prefix.filter { item in
            if case .customToolOutput(let o) = item { return o.callId == "exec-v8" }
            return false
        }.count

        let tailCallCount = split.tail.filter { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "exec-v8" } }
            return false
        }.count
        let tailOutputs = split.tail.filter { item in
            if case .customToolOutput(let o) = item { return o.callId == "exec-v8" }
            return false
        }.count

        #expect((prefixCallCount > 0) == (prefixOutputs > 0))
        #expect((tailCallCount > 0) == (tailOutputs > 0))
    }

    @Test("Summary block extraction prefers substantive closed summary tag over raw text")
    func testExtractSummaryBlockPrefersClosedSummaryTag() {
        let substantiveSummary = String(repeating: "Detailed line of summary content.\n", count: 40)
        #expect(substantiveSummary.count > TWO_PASS_MIN_SUMMARY_BLOCK_CHARS)

        let fullRaw = "<scratchpad>Preliminary analysis...</scratchpad>\n<summary>\n\(substantiveSummary)\n</summary>\nTrailing text"
        let extracted = extractSummaryBlock(fullRaw, minChars: TWO_PASS_MIN_SUMMARY_BLOCK_CHARS)
        #expect(extracted == substantiveSummary.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(extracted?.contains("<scratchpad>") == false)
    }

    @Test("NOTE₁ capping at 12k chars truncates and appends budget notice")
    func testNote1CappingAt12kCharsWithNotice() {
        let hugeText = String(repeating: "h", count: TWO_PASS_MAX_NOTE1_CHARS + 4000)
        let note = noteForTwoPassPass2(hugeText)

        #expect(note.count <= TWO_PASS_MAX_NOTE1_CHARS + 100)
        #expect(note.contains("[… NOTE₁ truncated for pass2 input budget …]"))
    }

    @Test("Build two-pass compaction prompt includes 5 sections and incorporates user context")
    func testBuildTwoPassCompactionPromptWithUserContext() {
        let prompt = buildTwoPassCompactionPrompt(userContext: "Focus specifically on Swift 6 strict concurrency errors.")

        #expect(prompt.contains("1. Primary Request and Intent"))
        #expect(prompt.contains("2. Key Technical Concepts"))
        #expect(prompt.contains("3. Errors and Fixes"))
        #expect(prompt.contains("4. Problem Solving"))
        #expect(prompt.contains("5. Optional Next Step"))
        #expect(prompt.contains("Focus specifically on Swift 6 strict concurrency errors."))
        #expect(prompt.contains("<summary>...</summary>"))
    }

    @Test("Build two-pass Pass 1 history appends compaction instruction user turn")
    func testBuildTwoPassPass1HistoryFormat() {
        let prefix: [ConversationItem] = [
            .system("System prompt"),
            .user("User request"),
            .assistant(AssistantItem(content: "Assistant response"))
        ]
        let prompt = buildTwoPassCompactionPrompt()
        let pass1History = buildTwoPassPass1History(prefix: prefix, compactionPrompt: prompt)

        #expect(pass1History.count == 4)
        #expect(pass1History[0].textContent() == "System prompt")
        #expect(pass1History[3].textContent().contains("Primary Request and Intent"))
    }

    @Test("Deterministic 64-bit FNV-1a sequence fingerprint stability")
    func testDeterministic64BitFingerprintStability() {
        let items: [ConversationItem] = [
            .system("System prompt"),
            .user("User message 1"),
            .assistant(AssistantItem(content: "Assistant message 1")),
            .toolResult(ToolResultItem(toolCallId: "c1", content: "Result text"))
        ]

        let fp1 = fingerprintPrefix(items)
        let fp2 = fingerprintPrefix(items)
        #expect(fp1 == fp2)
        #expect(fp1 != 0)
    }

    // MARK: - Tier 2: Boundary & Corner Cases

    @Test("Split empty and single-item conversations gracefully without crash")
    func testSplitEmptyAndSingleItemConversation() {
        let empty: [ConversationItem] = []
        let splitEmpty = splitConversationForTwoPass(empty)
        #expect(splitEmpty.splitIndex == 0)
        #expect(splitEmpty.prefix.isEmpty)
        #expect(splitEmpty.tail.isEmpty)

        let single: [ConversationItem] = [.user("Only one message")]
        let splitSingle = splitConversationForTwoPass(single)
        #expect(splitSingle.prefix.count + splitSingle.tail.count == 1)
    }

    @Test("Split handles extreme token weights near UInt64 max with saturating arithmetic")
    func testSplitExtremeTokenWeightsOverflowSafety() {
        let hugeWeights: [UInt64] = [
            UInt64.max / 2,
            UInt64.max / 2,
            1000
        ]
        let splitIdx = splitIndexByTokenFraction(weights: hugeWeights, fraction: 0.5)
        #expect(splitIdx >= 1)
        #expect(splitIdx < hugeWeights.count)
    }

    @Test("Snap split index when boundary lands in sequence of tool results")
    func testSnapSplitIndexWhenAllItemsAreToolOutputs() {
        let toolCall = ToolCall(id: "call-batch", name: "batch", arguments: "{}")
        let items: [ConversationItem] = [
            .system("sys"),
            .assistant(AssistantItem(content: "Calling batch", toolCalls: [toolCall])),
            .toolResult(ToolResultItem(toolCallId: "call-batch", content: "out 1")),
            .toolResult(ToolResultItem(toolCallId: "call-batch", content: "out 2")),
            .toolResult(ToolResultItem(toolCallId: "call-batch", content: "out 3"))
        ]

        let snapped = snapSplitIdxToToolBoundaries(conversation: items, splitIdx: 2)
        #expect(snapped == 5 || snapped == 1)
    }

    @Test("Extract summary block with nested or malformed tags falls back safely")
    func testExtractSummaryBlockWithNestedOrMalformedTags() {
        // Unclosed summary tag
        let unclosed = "<summary>This tag is never closed..."
        #expect(extractSummaryBlock(unclosed, minChars: 100) == nil)

        // Summary block too short (< minChars)
        let shortBlock = "<summary>Very short note</summary>"
        #expect(extractSummaryBlock(shortBlock, minChars: 1000) == nil)
    }

    @Test("Fingerprint prefix distinguishes item variants with identical text")
    func testFingerprintPrefixDistinguishesAllItemVariants() {
        let text = "Identical message payload"
        let sys: [ConversationItem] = [.system(text)]
        let usr: [ConversationItem] = [.user(text)]
        let ast: [ConversationItem] = [.assistant(AssistantItem(content: text))]
        let res: [ConversationItem] = [.toolResult(ToolResultItem(toolCallId: "c", content: text))]
        let rsn: [ConversationItem] = [.reasoning(ReasoningItem(id: "r1", content: [ReasoningTextContent(text: text)]))]
        let cst: [ConversationItem] = [.customToolOutput(CustomToolOutputItem.text(callId: "c", text))]

        let hashes = Set([
            fingerprintPrefix(sys),
            fingerprintPrefix(usr),
            fingerprintPrefix(ast),
            fingerprintPrefix(res),
            fingerprintPrefix(rsn),
            fingerprintPrefix(cst)
        ])

        // All hashes must be pairwise distinct
        #expect(hashes.count == 6)
    }

    // MARK: - Tier 3: Assembly & Prompt Formatting

    @Test("Assemble two-pass summary combines NOTE1, tail, and prompt into telemetry representation")
    func testAssembleTwoPassSummaryFormatting() {
        let note1 = "Intermediate summary of turns 1-20."
        let tail: [ConversationItem] = [
            .user("Tail query: check status"),
            .assistant(AssistantItem(content: "All systems green."))
        ]
        let prompt = "Final summary instructions"

        let assembled = assembleTwoPassSummary(note1: note1, tail: tail, summaryPrompt: prompt)
        #expect(assembled.contains("Prior Summary:\nIntermediate summary of turns 1-20."))
        #expect(assembled.contains("Tail query: check status"))
        #expect(assembled.contains("All systems green."))
        #expect(assembled.contains("Final summary instructions"))
    }

    @Test("Format NOTE1 carrier and special user turn for Pass 2 hierarchical prompt")
    func testFormatTwoPassNote1CarrierAndSpecialUser() {
        let note1 = "Note1 content body"
        let carrier = formatTwoPassNote1Carrier(note1)
        #expect(carrier.contains("<summary_content>\nNote1 content body\n</summary_content>"))
        #expect(carrier.contains("Your conversation was summarized due to context constraints."))

        let special = formatTwoPassSpecialPass2User(note1: note1, compactionPrompt: "Custom user instruction")
        #expect(special.contains("This is a special compaction case (two-pass / hierarchical summarization)."))
        #expect(special.contains("Incorporate the **entire** prior summary below"))
        #expect(special.contains("<summary_content>\nNote1 content body\n</summary_content>"))
        #expect(special.contains("Custom user instruction"))
    }

    @Test("Build two-pass Pass 2 history injects default assistant preamble when prefix lacks system prompt")
    func testBuildTwoPassPass2HistoryWithFallbackSystem() {
        let prefixWithoutSystem: [ConversationItem] = [
            .user("P0"),
            .assistant(AssistantItem(content: "R0"))
        ]
        let tail: [ConversationItem] = [.user("P1")]
        let pass2History = buildTwoPassPass2History(
            prefix: prefixWithoutSystem,
            tail: tail,
            note1: "NOTE1",
            compactionPrompt: "Prompt"
        )

        #expect(pass2History.first?.textContent() == "You are a helpful assistant.")
        #expect(pass2History.count == 4) // system + carrier + tail + special
    }
}
