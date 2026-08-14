// WrapClipboardImage.swift
//
// CLI-facing exports for WrapClipboardImage protocol and
// PromptSuggestionController predictive ghost-text engine.
//
// Reference:
//   * crates/codegen/xai-grok-pager/src/wrap_clipboard_image.rs
//   * crates/codegen/xai-grok-pager/src/views/prompt_suggestion.rs

import Foundation
import OpenGrokDiagnostics
@_exported import OpenGrokPagerRender
@_exported import OpenGrokShared
@_exported import OpenGrokTerminalCore
@_exported import OpenGrokTextArea

// MARK: - Prompt Suggestion Controller

/// Controls ghost-text prompt suggestions from auxiliary language models.
public struct PromptSuggestionController: Sendable, Equatable {
    public static let PROMPT_SUGGESTIONS_ENV = "GROK_PROMPT_SUGGESTIONS"
    public static let PROMPT_SUGGESTIONS_MODEL_ENV = "GROK_PROMPT_SUGGESTIONS_MODEL"
    public static let PREFERRED_SUGGESTION_MODEL = "grok-build-0.1"

    /// Full predictive suggestion text.
    public private(set) var fullText: String

    /// Generation counter for invalidating stale background requests.
    public private(set) var generation: UInt64

    /// Whether the active suggestion was explicitly dismissed by user.
    public private(set) var dismissed: Bool

    /// Latch ensuring impression telemetry is logged only once per loaded suggestion.
    public private(set) var shownLogged: Bool

    /// Whether suggestion generation and ghost-text display are enabled.
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.fullText = ""
        self.generation = 0
        self.dismissed = false
        self.shownLogged = false
        self.enabled = enabled
    }

    /// Begin a new suggestion fetch, invalidating any previous generation.
    public mutating func beginFetch() -> UInt64 {
        generation += 1
        return generation
    }

    /// Handle model response from background fetch. Discards stale or multiline suggestions.
    @discardableResult
    public mutating func onLoaded(suggestion: String?, generation: UInt64) -> Bool {
        guard generation == self.generation else {
            return false
        }
        guard let s = suggestion, !s.isEmpty, !s.contains(where: \.isNewline) else {
            return false
        }
        self.fullText = s
        self.dismissed = false
        self.shownLogged = false
        return true
    }

    /// Compute ghost text remainder for current composer input.
    public func ghostFor(text: String) -> String? {
        guard enabled, !dismissed, !fullText.isEmpty else {
            return nil
        }
        if text.isEmpty {
            return fullText
        }
        if fullText.hasPrefix(text) {
            return String(fullText.dropFirst(text.count))
        }
        // Divergence: composer text no longer matches suggestion prefix
        return nil
    }

    /// Accept suggestion for current composer text, returning remainder and clearing state.
    public mutating func accept(text: String) -> String? {
        guard let ghost = ghostFor(text: text) else {
            return nil
        }
        let remainder = ghost
        clear()
        return remainder
    }

    /// Explicitly dismiss the current suggestion (e.g. Esc press).
    public mutating func dismiss() {
        dismissed = true
    }

    /// Clear current suggestion and bump generation counter.
    public mutating func clear() {
        fullText = ""
        dismissed = false
        shownLogged = false
        generation += 1
    }

    /// Whether an active suggestion is available.
    public func hasSuggestion() -> Bool {
        !dismissed && !fullText.isEmpty
    }

    /// Mark suggestion impression as logged; returns true on first query for a loaded suggestion.
    public mutating func markShownLogged() -> Bool {
        if hasSuggestion() && !shownLogged {
            shownLogged = true
            return true
        }
        return false
    }

    /// Character and word count of ghost text remainder.
    public func suggestionSize(text: String) -> (chars: Int, words: Int) {
        guard let ghost = ghostFor(text: text) else {
            return (0, 0)
        }
        let chars = ghost.count
        let words = ghost.split(whereSeparator: \.isWhitespace).count
        return (chars, words)
    }

    /// Resolve effective enabled state from environment and configuration.
    public static func resolveEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configEnabled: Bool? = nil
    ) -> Bool {
        if let envVal = environment[PROMPT_SUGGESTIONS_ENV] {
            let lower = envVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(lower) { return true }
            if ["0", "false", "no", "off"].contains(lower) { return false }
        }
        return configEnabled ?? true
    }

    /// Resolve preferred model from environment and configuration.
    public static func resolveModel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configModel: String? = nil
    ) -> String {
        if let envVal = environment[PROMPT_SUGGESTIONS_MODEL_ENV],
           !envVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envVal.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let cfg = configModel, !cfg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cfg.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return PREFERRED_SUGGESTION_MODEL
    }
}
