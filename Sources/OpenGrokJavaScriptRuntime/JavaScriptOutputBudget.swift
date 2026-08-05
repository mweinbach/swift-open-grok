// JavaScriptOutputBudget.swift
//
// Bounded output capture for a cell's text content items.
//
// Divergence from the Rust source, recorded deliberately: the Rust runtime
// accepts `max_output_tokens` on `ExecuteRequest`
// (xai-grok-code-mode-protocol/src/runtime.rs) but never enforces it — the
// cell-actor conversion hard-codes `max_output_tokens: None`
// (crates/codegen/xai-grok-code-mode/src/cell_actor/conversions.rs:36) and
// `spawn_runtime` ignores the field entirely. Unbounded output is therefore
// the parity default here too: the budget only engages when a caller sets
// `maxOutputTokens` explicitly, so a request built the way the Rust engine
// builds it behaves identically.
//
// The Rust runtime also deletes `console` from the global object outright
// (runtime/globals.rs:16), so there is no console stream to bound; `text()`
// is the only text sink and is what this budget guards.

import Foundation

/// Approximate characters per token used to turn a token budget into a
/// character budget. Matches the 4-characters-per-token rule of thumb the
/// repository uses elsewhere for pre-tokenizer estimates.
private let charactersPerToken = 4

/// Appended once when output is cut off, so the model can tell truncation
/// from a cell that simply stopped printing.
public let CODE_MODE_OUTPUT_TRUNCATION_NOTICE = "[output truncated: exec output budget exhausted]"

/// Tracks how much text a cell has emitted and truncates past the budget.
struct JavaScriptOutputBudget {
    private let characterBudget: Int?
    private var charactersUsed = 0
    private var truncated = false

    init(maxOutputTokens: Int?) {
        if let maxOutputTokens, maxOutputTokens > 0 {
            characterBudget = maxOutputTokens * charactersPerToken
        } else {
            characterBudget = nil
        }
    }

    /// What to emit for a `text()` call.
    enum Admission: Equatable {
        /// Emit this text (possibly shortened).
        case emit(String)
        /// Emit this text, then the truncation notice; suppress the rest.
        case emitTruncated(String)
        /// The budget is already exhausted; emit nothing.
        case suppress
    }

    mutating func admit(_ text: String) -> Admission {
        guard let characterBudget else { return .emit(text) }
        if truncated { return .suppress }
        let remaining = characterBudget - charactersUsed
        if text.count <= remaining {
            charactersUsed += text.count
            return .emit(text)
        }
        truncated = true
        charactersUsed = characterBudget
        return .emitTruncated(String(text.prefix(max(remaining, 0))))
    }
}
