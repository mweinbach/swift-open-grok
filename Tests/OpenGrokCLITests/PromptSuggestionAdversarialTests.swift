// PromptSuggestionAdversarialTests.swift
//
// Adversarial empirical stress tests for PromptSuggestionController:
// CRLF / newline rejection across all Unicode line terminators,
// rapid typing divergence and convergence, ghost text remainder accuracy,
// race condition simulation with out-of-order responses, and telemetry invariants.

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("Prompt Suggestion Adversarial Stress Tests")
struct PromptSuggestionAdversarialTests {

    // MARK: - 1. Strict Newline Rejection Across All Unicode Line Breaks

    @Test("Strict newline rejection across all Unicode line break characters")
    func strictNewlineRejection() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()

        let forbiddenStrings = [
            "line1\r\nline2",           // CRLF
            "line1\nline2",             // LF
            "line1\rline2",             // CR
            "line1\u{0085}line2",       // Next Line (NEL)
            "line1\u{2028}line2",       // Line Separator (LS)
            "line1\u{2029}line2",       // Paragraph Separator (PS)
            "line1\u{000B}line2",       // Vertical Tab (VT)
            "line1\u{000C}line2",       // Form Feed (FF)
            "\r\n",
            "\n",
            "\r"
        ]

        for forbidden in forbiddenStrings {
            let loaded = controller.onLoaded(suggestion: forbidden, generation: gen)
            #expect(!loaded, "Suggestion with newline should be rejected: \(forbidden.debugDescription)")
            #expect(!controller.hasSuggestion())
            #expect(controller.ghostFor(text: "") == nil)
        }
    }

    // MARK: - 2. Rapid Typing Divergence, Backspace Recovery, and Convergence

    @Test("Rapid typing divergence, backspace recovery, and exact match lifecycle")
    func rapidTypingDivergenceAndBackspaceRecovery() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "git rebase -i HEAD~3", generation: gen)

        // 1. Initial empty input gives full ghost text
        #expect(controller.ghostFor(text: "") == "git rebase -i HEAD~3")

        // 2. Typing matching prefix progressively shrinks ghost text
        #expect(controller.ghostFor(text: "g") == "it rebase -i HEAD~3")
        #expect(controller.ghostFor(text: "git ") == "rebase -i HEAD~3")
        #expect(controller.ghostFor(text: "git reb") == "ase -i HEAD~3")

        // 3. User makes a typo / diverges: "git commit" -> ghost text immediately hides (nil)
        #expect(controller.ghostFor(text: "git c") == nil)
        #expect(controller.ghostFor(text: "git commit") == nil)

        // 4. User backspaces back to "git " -> ghost text reappears!
        #expect(controller.ghostFor(text: "git ") == "rebase -i HEAD~3")

        // 5. User types exact match -> ghost text becomes empty string "" (not nil, meaning full match)
        #expect(controller.ghostFor(text: "git rebase -i HEAD~3") == "")

        // 6. User types beyond suggestion -> diverges to nil
        #expect(controller.ghostFor(text: "git rebase -i HEAD~3 --autosquash") == nil)
    }

    // MARK: - 3. Out-of-Order Asynchronous Generation Races

    @Test("Simulate high-frequency asynchronous model responses arriving out-of-order")
    func outOfOrderGenerationRaces() {
        var controller = PromptSuggestionController(enabled: true)

        let g1 = controller.beginFetch()
        let g2 = controller.beginFetch()
        let g3 = controller.beginFetch()
        let g4 = controller.beginFetch()

        #expect(g4 > g3 && g3 > g2 && g2 > g1)

        // g2 arrives first -> rejected (current is g4)
        let r2 = controller.onLoaded(suggestion: "from g2", generation: g2)
        #expect(!r2)
        #expect(controller.ghostFor(text: "") == nil)

        // g1 arrives next -> rejected
        let r1 = controller.onLoaded(suggestion: "from g1", generation: g1)
        #expect(!r1)

        // g3 arrives -> rejected
        let r3 = controller.onLoaded(suggestion: "from g3", generation: g3)
        #expect(!r3)

        // g4 arrives -> accepted
        let r4 = controller.onLoaded(suggestion: "from g4", generation: g4)
        #expect(r4)
        #expect(controller.ghostFor(text: "") == "from g4")

        // Another stale message with g2 arrives after g4 -> rejected, g4 retained
        let r2Retry = controller.onLoaded(suggestion: "stale g2 retry", generation: g2)
        #expect(!r2Retry)
        #expect(controller.ghostFor(text: "") == "from g4")
    }

    // MARK: - 4. Accept / Dismiss Edge Cases

    @Test("Accepting on non-matching text returns nil and does not corrupt state")
    func acceptNonMatchingText() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "open-grok run", generation: gen)

        let accepted = controller.accept(text: "diff --cached")
        #expect(accepted == nil)
        #expect(controller.hasSuggestion() == true) // Suggestion is preserved if accept was invalid
    }

    @Test("Dismissal latches until clear and telemetry impression is logged once")
    func dismissalAndTelemetryLatch() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "cargo test --all", generation: gen)

        #expect(controller.markShownLogged() == true)
        #expect(controller.markShownLogged() == false)

        controller.dismiss()
        #expect(controller.ghostFor(text: "cargo ") == nil)
        #expect(controller.markShownLogged() == false) // Dismissed hasSuggestion is false
    }
}
