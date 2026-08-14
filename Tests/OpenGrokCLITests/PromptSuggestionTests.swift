// PromptSuggestionTests.swift
//
// Tests for predictive prompt suggestion controller, ghost text derivation,
// generation counter invalidation, acceptance, dismissal, and telemetry latching.
//
// Reference: crates/codegen/xai-grok-pager/src/views/prompt_suggestion.rs

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("Prompt Suggestion Controller Tests")
struct PromptSuggestionTests {

    @Test("Ghost text derivation on prefix match and divergence")
    func ghostTextDerivation() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "git status --short", generation: gen)

        // Empty input returns full suggestion
        #expect(controller.ghostFor(text: "") == "git status --short")

        // Matching prefix returns suffix remainder
        #expect(controller.ghostFor(text: "git ") == "status --short")
        #expect(controller.ghostFor(text: "git stat") == "us --short")
        #expect(controller.ghostFor(text: "git status --short") == "")

        // Divergence hides ghost text
        #expect(controller.ghostFor(text: "cargo test") == nil)
        #expect(controller.ghostFor(text: "git diff") == nil)
    }

    @Test("Acceptance returns remainder and clears state")
    func acceptanceBehavior() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "write unit tests for composer", generation: gen)

        let remainder = controller.accept(text: "write unit ")
        #expect(remainder == "tests for composer")

        // Controller is cleared after accept
        #expect(controller.hasSuggestion() == false)
        #expect(controller.ghostFor(text: "write unit ") == nil)
    }

    @Test("Dismissal hides ghost text until cleared")
    func dismissalBehavior() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "refactor live composition", generation: gen)

        #expect(controller.ghostFor(text: "refactor") == " live composition")

        controller.dismiss()
        #expect(controller.ghostFor(text: "refactor") == nil)
        #expect(controller.hasSuggestion() == false)

        // Clear resets dismissal for next generation
        controller.clear()
        let nextGen = controller.beginFetch()
        controller.onLoaded(suggestion: "new suggestion", generation: nextGen)
        #expect(controller.ghostFor(text: "") == "new suggestion")
    }

    @Test("Stale generation responses are discarded")
    func staleGenerationDiscarded() {
        var controller = PromptSuggestionController(enabled: true)

        let gen1 = controller.beginFetch()
        let gen2 = controller.beginFetch() // User typed more, bump generation

        #expect(gen2 > gen1)

        // Stale reply from gen1 is rejected
        let accepted1 = controller.onLoaded(suggestion: "stale suggestion", generation: gen1)
        #expect(accepted1 == false)
        #expect(controller.hasSuggestion() == false)

        // Current reply from gen2 is accepted
        let accepted2 = controller.onLoaded(suggestion: "fresh suggestion", generation: gen2)
        #expect(accepted2 == true)
        #expect(controller.ghostFor(text: "") == "fresh suggestion")
    }

    @Test("Multiline suggestions and empty strings are rejected")
    func invalidSuggestionsRejected() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()

        #expect(controller.onLoaded(suggestion: "", generation: gen) == false)
        #expect(controller.onLoaded(suggestion: nil, generation: gen) == false)
        #expect(controller.onLoaded(suggestion: "line1\nline2", generation: gen) == false)
        #expect(controller.onLoaded(suggestion: "line1\r\nline2", generation: gen) == false)
    }

    @Test("Telemetry impression latch fires only once per loaded suggestion")
    func shownLoggedImpressionLatch() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "inspect memory usage", generation: gen)

        // First query marks as shown
        #expect(controller.markShownLogged() == true)

        // Second query returns false (already logged)
        #expect(controller.markShownLogged() == false)
        #expect(controller.markShownLogged() == false)

        // New suggestion resets the latch
        let nextGen = controller.beginFetch()
        controller.onLoaded(suggestion: "new suggestion", generation: nextGen)
        #expect(controller.markShownLogged() == true)
        #expect(controller.markShownLogged() == false)
    }

    @Test("Disabled controller never yields ghost text")
    func disabledController() {
        var controller = PromptSuggestionController(enabled: false)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "git status", generation: gen)

        #expect(controller.ghostFor(text: "") == nil)
        #expect(controller.ghostFor(text: "git") == nil)
        #expect(controller.accept(text: "git") == nil)
    }

    @Test("Suggestion size calculations")
    func suggestionSizeMetric() {
        var controller = PromptSuggestionController(enabled: true)
        let gen = controller.beginFetch()
        controller.onLoaded(suggestion: "check status of background jobs", generation: gen)

        let (chars, words) = controller.suggestionSize(text: "check status ")
        #expect(chars == "of background jobs".count)
        #expect(words == 3)
    }

    @Test("Configuration and environment variable resolution")
    func configResolution() {
        #expect(PromptSuggestionController.resolveEnabled(environment: [:], configEnabled: nil) == true)
        #expect(PromptSuggestionController.resolveEnabled(environment: ["GROK_PROMPT_SUGGESTIONS": "0"]) == false)
        #expect(PromptSuggestionController.resolveEnabled(environment: ["GROK_PROMPT_SUGGESTIONS": "false"]) == false)
        #expect(PromptSuggestionController.resolveEnabled(environment: ["GROK_PROMPT_SUGGESTIONS": "off"]) == false)
        #expect(PromptSuggestionController.resolveEnabled(environment: ["GROK_PROMPT_SUGGESTIONS": "1"]) == true)
        #expect(PromptSuggestionController.resolveEnabled(environment: ["GROK_PROMPT_SUGGESTIONS": "true"]) == true)

        #expect(PromptSuggestionController.resolveModel(environment: [:], configModel: nil) == "grok-build-0.1")
        #expect(PromptSuggestionController.resolveModel(environment: [:], configModel: "custom-model") == "custom-model")
        #expect(PromptSuggestionController.resolveModel(environment: ["GROK_PROMPT_SUGGESTIONS_MODEL": "env-model"], configModel: "custom-model") == "env-model")
    }
}
