// TwoPassCompactionChallengerTests.swift
//
// Challenger 1 Adversarial & Empirical Stress Test Suite for Milestone 2:
// - Extreme conversation split shapes (0, 1, all tool results, unbalanced tool calls, large custom outputs, 1000 items)
// - FNV-1a fingerprint collision resistance, stability, Unicode handling, mutation sensitivity, order sensitivity
// - <summary> extraction, case insensitivity, multi-block selection, malformed tags, 12k capping with Unicode
// - Carrier formatting, special user prompt assembly, 5-section prompt generation
// - Prefire trigger calculation with edge cases and provider gates

import Foundation
import OpenGrokChatState
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTokenEstimation
import Testing
@testable import OpenGrokCompaction

@Suite("Challenger 1: Two-Pass Compaction Adversarial Stress Suite", .serialized)
struct TwoPassCompactionChallengerTests {

    // MARK: - 1. Adversarial Conversation Splitting Stress Tests

    @Test("Split empty conversation produces empty prefix and tail with splitIndex 0")
    func testSplitEmptyConversation() {
        let items: [ConversationItem] = []
        let split = splitConversationForTwoPass(items, splitFraction: 0.95)
        #expect(split.splitIndex == 0)
        #expect(split.prefix.isEmpty)
        #expect(split.tail.isEmpty)
    }

    @Test("Split single-item conversation produces non-crashing split")
    func testSplitSingleItemConversation() {
        let items: [ConversationItem] = [.user("Single message in entire conversation")]
        let split = splitConversationForTwoPass(items, splitFraction: 0.95)
        #expect(split.prefix.count + split.tail.count == 1)
        #expect(split.splitIndex >= 0 && split.splitIndex <= 1)
    }

    @Test("Split two-item conversation leaves 1 in prefix and 1 in tail")
    func testSplitTwoItemsConversation() {
        let items: [ConversationItem] = [
            .user("User initial prompt"),
            .assistant(AssistantItem(content: "Assistant initial response"))
        ]
        let split = splitConversationForTwoPass(items, splitFraction: 0.95)
        #expect(split.prefix.count == 1)
        #expect(split.tail.count == 1)
        #expect(split.splitIndex == 1)
    }

    @Test("Split conversation with only ToolResult and CustomToolOutput items handles boundaries safely")
    func testSplitAllToolResultsConversation() {
        var items: [ConversationItem] = []
        for i in 0..<100 {
            if i % 2 == 0 {
                items.append(.toolResult(ToolResultItem(toolCallId: "call-\(i)", content: "Tool output \(i)")))
            } else {
                items.append(.customToolOutput(CustomToolOutputItem.text(callId: "exec-\(i)", "Chunk \(i)")))
            }
        }

        let split = splitConversationForTwoPass(items, splitFraction: 0.90)
        #expect(split.prefix.count + split.tail.count == 100)
        #expect(split.splitIndex >= 1 && split.splitIndex < 100)
    }

    @Test("Split preserves unbalanced tool calls and multiple tool outputs without separation")
    func testSplitUnbalancedToolCallsAndOutputs() {
        let toolCall1 = ToolCall(id: "call-multi-1", name: "bash", arguments: "{}")
        let toolCall2 = ToolCall(id: "call-multi-2", name: "read_file", arguments: "{}")
        let toolCall3 = ToolCall(id: "call-multi-3", name: "grep", arguments: "{}")

        var items: [ConversationItem] = [
            .system("System prompt"),
            .user("U0: Initial setup task"),
            .assistant(AssistantItem(content: "Calling 3 tools in parallel", toolCalls: [toolCall1, toolCall2, toolCall3])),
            .toolResult(ToolResultItem(toolCallId: "call-multi-1", content: "bash ok")),
            .toolResult(ToolResultItem(toolCallId: "call-multi-2", content: "file content")),
            .toolResult(ToolResultItem(toolCallId: "call-multi-3", content: "matches found")),
            .user("U1: Intermediate feedback")
        ]

        let execCall = ToolCall(id: "exec-cell-1", name: "exec", arguments: "tools.write()")
        items.append(.assistant(AssistantItem(content: "Executing script", toolCalls: [execCall])))
        for chunk in 0..<5 {
            items.append(.customToolOutput(CustomToolOutputItem.text(callId: "exec-cell-1", "Output chunk \(chunk)")))
        }
        items.append(.user("U2: Final prompt"))

        // Test multiple split fractions to ensure no tool call is ever severed from its results
        for fraction in [0.1, 0.3, 0.5, 0.7, 0.85, 0.95] {
            let split = splitConversationForTwoPass(items, splitFraction: fraction)

            // Check multi-tool batch 1
            let prefixHasMulti1 = split.prefix.contains { item in
                if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "call-multi-1" } }
                return false
            }
            let prefixHasRes1 = split.prefix.contains { item in
                if case .toolResult(let r) = item { return r.toolCallId == "call-multi-1" }
                return false
            }
            #expect(prefixHasMulti1 == prefixHasRes1)

            // Check exec batch 2
            let prefixHasExec = split.prefix.contains { item in
                if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "exec-cell-1" } }
                return false
            }
            let prefixHasExecOutputs = split.prefix.contains { item in
                if case .customToolOutput(let o) = item { return o.callId == "exec-cell-1" }
                return false
            }
            #expect(prefixHasExec == prefixHasExecOutputs)
        }
    }

    @Test("Split handles massive custom tool outputs (50,000+ chars) correctly")
    func testSplitLargeCustomToolOutputs() {
        let massiveOutput = String(repeating: "Large payload line 1234567890\n", count: 2000)
        let toolCall = ToolCall(id: "exec-huge", name: "exec", arguments: "tools.fetch()")

        let items: [ConversationItem] = [
            .system("System prompt"),
            .user("U0: Fetch large dataset"),
            .assistant(AssistantItem(content: "Fetching...", toolCalls: [toolCall])),
            .customToolOutput(CustomToolOutputItem.text(callId: "exec-huge", massiveOutput)),
            .user("U1: Summarize data")
        ]

        let split = splitConversationForTwoPass(items, splitFraction: 0.50)
        #expect(split.prefix.count + split.tail.count == items.count)

        let prefixHasCall = split.prefix.contains { item in
            if case .assistant(let a) = item { return a.toolCalls.contains { $0.callId == "exec-huge" } }
            return false
        }
        let prefixHasOutput = split.prefix.contains { item in
            if case .customToolOutput(let o) = item { return o.callId == "exec-huge" }
            return false
        }
        #expect(prefixHasCall == prefixHasOutput)
    }

    @Test("Split massive 1,000-item conversation with complex mixed turn patterns")
    func testSplitMassive1000ItemsConversation() {
        var items: [ConversationItem] = []
        items.reserveCapacity(1000)
        items.append(.system("You are Open Grok."))

        for i in 1...330 {
            items.append(.user("Prompt \(i): " + String(repeating: "word ", count: 10)))
            let call = ToolCall(id: "call-\(i)", name: "tool_\(i)", arguments: "{}")
            items.append(.assistant(AssistantItem(content: "Response \(i)", toolCalls: [call])))
            items.append(.toolResult(ToolResultItem(toolCallId: "call-\(i)", content: "Result \(i)")))
        }
        items.append(.user("Final tail user query"))

        #expect(items.count >= 990)

        let split = splitConversationForTwoPass(items, splitFraction: 0.95)
        #expect(split.prefix.count > 0)
        #expect(split.tail.count > 0)
        #expect(split.prefix.count + split.tail.count == items.count)
        #expect(split.splitIndex == split.prefix.count)

        // Verify that every single tool call in prefix has all its results in prefix
        for (idx, item) in split.prefix.enumerated() {
            if case .assistant(let a) = item, !a.toolCalls.isEmpty {
                for call in a.toolCalls {
                    let subsequentPrefixHasResult = split.prefix[(idx + 1)...].contains { r in
                        if case .toolResult(let tr) = r { return tr.toolCallId == call.callId }
                        if case .customToolOutput(let ct) = r { return ct.callId == call.callId }
                        return false
                    }
                    #expect(subsequentPrefixHasResult, "Tool call \(call.callId) in prefix must have its output in prefix")
                    let tailHasResult = split.tail.contains { r in
                        if case .toolResult(let tr) = r { return tr.toolCallId == call.callId }
                        if case .customToolOutput(let ct) = r { return ct.callId == call.callId }
                        return false
                    }
                    #expect(!tailHasResult, "Tool result for call \(call.callId) leaked into tail while call was in prefix")
                }
            }
        }
    }

    @Test("Split fraction boundary clamping and out-of-range safety")
    func testSplitBoundaryClamping() {
        let weights: [UInt64] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]

        let splitNegative = splitIndexByTokenFraction(weights: weights, fraction: -1.0)
        let splitZero = splitIndexByTokenFraction(weights: weights, fraction: 0.0)
        let splitMin = splitIndexByTokenFraction(weights: weights, fraction: 0.05)
        #expect(splitNegative == splitMin)
        #expect(splitZero == splitMin)

        let splitMax = splitIndexByTokenFraction(weights: weights, fraction: 0.95)
        let splitOne = splitIndexByTokenFraction(weights: weights, fraction: 1.0)
        let splitTwo = splitIndexByTokenFraction(weights: weights, fraction: 2.0)
        #expect(splitOne == splitMax)
        #expect(splitTwo == splitMax)
    }

    @Test("Split with single dominant item (99.9% of tokens) leaves valid split")
    func testSplitSingleDominantItem() {
        var items: [ConversationItem] = []
        items.append(.user("Dominant message: " + String(repeating: "huge ", count: 10_000)))
        for i in 0..<10 {
            items.append(.user("Small message \(i)"))
        }

        let split = splitConversationForTwoPass(items, splitFraction: 0.95)
        #expect(split.prefix.count >= 1)
        #expect(split.tail.count >= 1)
        #expect(split.prefix.count + split.tail.count == items.count)
    }

    @Test("Split with all zero token weights does not crash and leaves non-empty tail")
    func testSplitAllZeroTokenWeights() {
        let weights: [UInt64] = [0, 0, 0, 0, 0]
        let splitIdx = splitIndexByTokenFraction(weights: weights, fraction: 0.95)
        #expect(splitIdx >= 1)
        #expect(splitIdx < weights.count)
    }

    // MARK: - 2. Adversarial Prefix Fingerprinting Stress Tests

    @Test("Fingerprint prefix is collision resistant across 1,000 distinct message mutations")
    func testFingerprintPrefixCollisionResistance() {
        var fingerprints = Set<UInt64>()
        fingerprints.reserveCapacity(1000)

        for i in 0..<1000 {
            let items: [ConversationItem] = [
                .system("System prompt version \(i)"),
                .user("User query \(i * 7 + 3)"),
                .assistant(AssistantItem(content: "Assistant reply \(i * 13 + 5)"))
            ]
            let fp = fingerprintPrefix(items)
            let inserted = fingerprints.insert(fp).inserted
            #expect(inserted, "Collision detected at iteration \(i) with hash \(fp)")
        }

        #expect(fingerprints.count == 1000)
    }

    @Test("Fingerprint prefix is strictly sensitive to item order")
    func testFingerprintPrefixItemOrderSensitivity() {
        let itemA: ConversationItem = .user("Message Alpha")
        let itemB: ConversationItem = .assistant(AssistantItem(content: "Message Beta"))

        let list1: [ConversationItem] = [itemA, itemB]
        let list2: [ConversationItem] = [itemB, itemA]

        let fp1 = fingerprintPrefix(list1)
        let fp2 = fingerprintPrefix(list2)

        #expect(fp1 != fp2)
    }

    @Test("Fingerprint prefix is sensitive to item role tag for identical string payloads")
    func testFingerprintPrefixRoleTagSensitivity() {
        let payload = "Exact identical string payload across all roles."

        let sys = fingerprintPrefix([.system(payload)])
        let usr = fingerprintPrefix([.user(payload)])
        let ast = fingerprintPrefix([.assistant(AssistantItem(content: payload))])
        let tr  = fingerprintPrefix([.toolResult(ToolResultItem(toolCallId: "c", content: payload))])
        let rsn = fingerprintPrefix([.reasoning(ReasoningItem(id: "r", content: [ReasoningTextContent(text: payload)]))])
        let cst = fingerprintPrefix([.customToolOutput(CustomToolOutputItem.text(callId: "c", payload))])

        let allHashes: Set<UInt64> = [sys, usr, ast, tr, rsn, cst]
        #expect(allHashes.count == 6)
    }

    @Test("Fingerprint prefix detects subtle 1-character, whitespace, and null-byte mutations")
    func testFingerprintPrefixContentMutationSensitivity() {
        let baseItems: [ConversationItem] = [
            .system("System instructions"),
            .user("Perform calculation: 2 + 2 = 4"),
            .assistant(AssistantItem(content: "Result is 4."))
        ]
        let baseFp = fingerprintPrefix(baseItems)

        // 1-character mutation
        var mutatedChar = baseItems
        mutatedChar[1] = .user("Perform calculation: 2 + 2 = 5")
        #expect(fingerprintPrefix(mutatedChar) != baseFp)

        // Case mutation
        var mutatedCase = baseItems
        mutatedCase[0] = .system("SYSTEM INSTRUCTIONS")
        #expect(fingerprintPrefix(mutatedCase) != baseFp)

        // Trailing whitespace mutation
        var mutatedSpace = baseItems
        mutatedSpace[2] = .assistant(AssistantItem(content: "Result is 4. "))
        #expect(fingerprintPrefix(mutatedSpace) != baseFp)

        // Embedded null byte mutation
        var mutatedNull = baseItems
        mutatedNull[1] = .user("Perform calculation:\0 2 + 2 = 4")
        #expect(fingerprintPrefix(mutatedNull) != baseFp)
    }

    @Test("Fingerprint prefix handles complex Unicode, emojis, RTL, and multi-byte scripts safely")
    func testFingerprintPrefixUnicodeHandling() {
        let unicodeItems: [ConversationItem] = [
            .system("系统提示: 这是一个复杂测试 🚀"),
            .user("مرحبا بك في العالم! 🌍 Привет мир! 🌟"),
            .assistant(AssistantItem(content: "Family emoji: 👨‍👩‍👧‍👦 combining character: e\u{301} (é) vs é")),
            .toolResult(ToolResultItem(toolCallId: "c-uni", content: "日本語のテキストと記号：【】『』〜¥"))
        ]

        let fp1 = fingerprintPrefix(unicodeItems)
        let fp2 = fingerprintPrefix(unicodeItems)
        #expect(fp1 == fp2)
        #expect(fp1 != 0)

        // Ensure distinct from empty or basic ASCII
        let asciiItems: [ConversationItem] = [
            .system("System"),
            .user("User"),
            .assistant(AssistantItem(content: "Assistant")),
            .toolResult(ToolResultItem(toolCallId: "c-uni", content: "Result"))
        ]
        #expect(fp1 != fingerprintPrefix(asciiItems))
    }

    @Test("Fingerprint prefix empty list is deterministic non-zero")
    func testFingerprintPrefixEmptyList() {
        let empty: [ConversationItem] = []
        let fp = fingerprintPrefix(empty)
        #expect(fp != 0)
        #expect(fingerprintPrefix(empty) == fp)
    }

    // MARK: - 3. Adversarial Summary Extraction & Carrier Assembly Stress Tests

    @Test("Summary block extraction is case-insensitive across uppercase, lowercase, and mixed-case tags")
    func testExtractSummaryBlockCaseInsensitivity() {
        let content = String(repeating: "Substantive summary content for uppercase test.\n", count: 40)
        #expect(content.count > TWO_PASS_MIN_SUMMARY_BLOCK_CHARS)

        let upper = "<SUMMARY>\n\(content)\n</SUMMARY>"
        let extractedUpper = extractSummaryBlock(upper, minChars: TWO_PASS_MIN_SUMMARY_BLOCK_CHARS)
        #expect(extractedUpper == content.trimmingCharacters(in: .whitespacesAndNewlines))

        let mixed = "<SuMmArY>\n\(content)\n</sUmMaRy>"
        let extractedMixed = extractSummaryBlock(mixed, minChars: TWO_PASS_MIN_SUMMARY_BLOCK_CHARS)
        #expect(extractedMixed == content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Summary block extraction with multiple blocks selects the last substantive block")
    func testExtractSummaryBlockMultipleBlocksSelectsLastSubstantive() {
        let block1 = String(repeating: "Block 1 content line.\n", count: 50)
        let block2 = "Block 2 too short."
        let block3 = String(repeating: "Block 3 final substantive content line.\n", count: 60)

        let text = """
        <summary>
        \(block1)
        </summary>
        Intermediate text...
        <summary>
        \(block2)
        </summary>
        More intermediate text...
        <summary>
        \(block3)
        </summary>
        Trailing text.
        """

        let extracted = extractSummaryBlock(text, minChars: TWO_PASS_MIN_SUMMARY_BLOCK_CHARS)
        #expect(extracted == block3.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Summary block extraction with nested, unclosed, and malformed tags")
    func testExtractSummaryBlockMalformedAndEdgeTags() {
        // Tag without closing
        let unclosed = "<summary>Content without closing tag"
        #expect(extractSummaryBlock(unclosed, minChars: 10) == nil)

        // Empty tags
        let emptyTags = "<summary></summary>"
        #expect(extractSummaryBlock(emptyTags, minChars: 0) == nil || extractSummaryBlock(emptyTags, minChars: 0) == "")

        // Non-matching closing tag
        let mismatched = "<summary>Content</other>"
        #expect(extractSummaryBlock(mismatched, minChars: 5) == nil)
    }

    @Test("NOTE₁ capping at exact 12,000 char boundary and Unicode truncation")
    func testNote1CappingExactBoundaryAndUnicode() {
        // Exactly 12,000 ASCII chars -> no truncation message
        let exact12k = String(repeating: "a", count: TWO_PASS_MAX_NOTE1_CHARS)
        let noteExact = noteForTwoPassPass2(exact12k)
        #expect(noteExact == exact12k)
        #expect(!noteExact.contains("truncated"))

        // 12,001 chars -> truncated with notice
        let over12k = String(repeating: "a", count: TWO_PASS_MAX_NOTE1_CHARS + 1)
        let noteOver = noteForTwoPassPass2(over12k)
        #expect(noteOver.contains("[… NOTE₁ truncated for pass2 input budget …]"))
        #expect(noteOver.hasPrefix(String(repeating: "a", count: TWO_PASS_MAX_NOTE1_CHARS)))

        // 15,000 multi-byte Unicode characters (CJK & emoji, count = 15,000 > 12,000)
        let unicodeHuge = String(repeating: "🚀数据", count: 5000)
        let noteUnicode = noteForTwoPassPass2(unicodeHuge)
        #expect(noteUnicode.contains("[… NOTE₁ truncated for pass2 input budget …]"))
        #expect(noteUnicode.count <= TWO_PASS_MAX_NOTE1_CHARS + 100)
    }

    @Test("formatTwoPassNote1Carrier trims whitespace and wraps in summary_content XML tags")
    func testFormatTwoPassNote1Carrier() {
        let note = "   \n\t  Intermediate NOTE1 text with details. \t\n  "
        let carrier = formatTwoPassNote1Carrier(note)

        #expect(carrier.contains("<summary_content>\nIntermediate NOTE1 text with details.\n</summary_content>"))
        #expect(carrier.contains("Your conversation was summarized due to context constraints."))
        #expect(carrier.contains("Continue with the compaction task below."))
    }

    @Test("formatTwoPassSpecialPass2User handles empty, whitespace, and custom user compaction prompts")
    func testFormatTwoPassSpecialPass2UserPrompts() {
        let note1 = "Prior note summary"

        // Empty prompt fallback to standard instruction
        let specialEmpty = formatTwoPassSpecialPass2User(note1: note1, compactionPrompt: "   ")
        #expect(specialEmpty.contains("Please summarize the conversation so far."))
        #expect(specialEmpty.contains("<summary_content>\nPrior note summary\n</summary_content>"))

        // Custom prompt inclusion
        let specialCustom = formatTwoPassSpecialPass2User(note1: note1, compactionPrompt: "Focus strictly on security invariants.")
        #expect(specialCustom.contains("Focus strictly on security invariants."))
    }

    @Test("buildTwoPassCompactionPrompt adheres to exact 5-section specification and tool restrictions")
    func testBuildTwoPassCompactionPromptSpecification() {
        let prompt = buildTwoPassCompactionPrompt()

        #expect(prompt.contains("1. Primary Request and Intent:"))
        #expect(prompt.contains("2. Key Technical Concepts:"))
        #expect(prompt.contains("3. Errors and Fixes:"))
        #expect(prompt.contains("4. Problem Solving:"))
        #expect(prompt.contains("5. Optional Next Step:"))
        #expect(prompt.contains("<summary>...</summary>"))
        #expect(prompt.contains("IMPORTANT: Do NOT call or use any tools."))
        #expect(prompt.contains("/tmp/compaction/segment_*.md"))
    }

    @Test("assembleTwoPassSummary serializes all conversation item types into human/telemetry view")
    func testAssembleTwoPassSummaryAllItemTypes() {
        let note1 = "Historical NOTE1"
        let tail: [ConversationItem] = [
            .system("System notice"),
            .user("User question"),
            .assistant(AssistantItem(content: "Assistant reply")),
            .toolResult(ToolResultItem(toolCallId: "c1", content: "Result content")),
            .customToolOutput(CustomToolOutputItem.text(callId: "c2", "Custom output")),
            .reasoning(ReasoningItem(id: "r1", content: [ReasoningTextContent(text: "Reasoning thought")]))
        ]
        let prompt = "Compaction prompt text"

        let assembled = assembleTwoPassSummary(note1: note1, tail: tail, summaryPrompt: prompt)
        #expect(assembled.contains("Prior Summary:\nHistorical NOTE1"))
        #expect(assembled.contains("System: System notice"))
        #expect(assembled.contains("User: User question"))
        #expect(assembled.contains("Assistant: Assistant reply"))
        #expect(assembled.contains("ToolResult: Result content"))
        #expect(assembled.contains("CustomToolOutput: Custom output"))
        #expect(assembled.contains("Reasoning: Reasoning thought"))
        #expect(assembled.contains("Compaction Prompt:\nCompaction prompt text"))
    }

    // MARK: - 4. Adversarial Prefire Decision & State Tests

    @Test("shouldPrefireTwoPass provider gating and boundary conditions")
    func testShouldPrefireTwoPassGating() {
        // Codex provider must NEVER prefire (handled server-side)
        #expect(!shouldPrefireTwoPass(estimatedTotalTokens: 99_000, contextWindow: 100_000, thresholdPercent: 85, leadPercent: 10, provider: .codex))

        // Non-codex providers trigger when tokens > (contextWindow * (threshold - lead) / 100)
        // 100,000 * (85 - 10) / 100 = 75,000
        #expect(!shouldPrefireTwoPass(estimatedTotalTokens: 75_000, contextWindow: 100_000, thresholdPercent: 85, leadPercent: 10, provider: .xai))
        #expect(shouldPrefireTwoPass(estimatedTotalTokens: 75_001, contextWindow: 100_000, thresholdPercent: 85, leadPercent: 10, provider: .xai))

        // 0 context window returns false safely without division by zero
        #expect(!shouldPrefireTwoPass(estimatedTotalTokens: 50_000, contextWindow: 0, thresholdPercent: 85, leadPercent: 10, provider: .xai))

        // Large lead percent that exceeds threshold clamps to 0
        #expect(shouldPrefireTwoPass(estimatedTotalTokens: 1, contextWindow: 100_000, thresholdPercent: 10, leadPercent: 20, provider: .xai))
    }

    @Test("CompactionBudget overload for shouldPrefireTwoPass")
    func testShouldPrefireTwoPassBudgetOverload() {
        let budget = CompactionBudget(
            contextWindow: 100_000,
            triggerTokenLimit: 85_000,
            targetTokenLimit: 50_000,
            source: "automatic"
        )

        // String provider "codex" returns false
        #expect(!shouldPrefireTwoPass(budget: budget, currentTokens: 90_000, leadPercent: 10.0, provider: "codex"))
        #expect(!shouldPrefireTwoPass(budget: budget, currentTokens: 90_000, leadPercent: 10.0, provider: "CODEX"))

        // Standard provider
        #expect(!shouldPrefireTwoPass(budget: budget, currentTokens: 74_000, leadPercent: 10.0, provider: "xai"))
        #expect(shouldPrefireTwoPass(budget: budget, currentTokens: 76_000, leadPercent: 10.0, provider: "xai"))
    }
}
