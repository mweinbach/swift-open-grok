// ConversationUtil.swift
//
// Open Grok — Swift port of the pure conversation-shape helpers in
// `crates/codegen/xai-chat-state/src/conversation_util.rs`.
//
// These are crate-neutral helpers shared by the session layer and the
// `ChatStateActor`. The single source of truth for the "align the leading
// System message with the client override" operation.

import Foundation
import OpenGrokSamplingTypes

/// Equal after trimming trailing `\n`/`\r` from both sides. Used for attach
/// idempotency so a stored head that differs from a client override only by
/// a trailing newline is treated as already matching (cache-friendly no-op).
/// Interior and leading whitespace are significant.
public func canonicalSystemPromptEq(_ a: String, _ b: String) -> Bool {
    a.trimmingTrailingNewlines == b.trimmingTrailingNewlines
}

/// Replace the leading `System` message with `prompt`, or insert one at the
/// head if the conversation has no leading `System`. Returns whether the
/// conversation changed; a head already equal to `prompt` (modulo trailing
/// newlines) is left untouched for KV-cache-friendly idempotency.
@discardableResult
public func replaceOrInsertSystemHead(
    _ conversation: inout [ConversationItem],
    prompt: String
) -> Bool {
    guard let first = conversation.first else {
        conversation.insert(.system(prompt), at: 0)
        return true
    }
    if case .system(var sys) = first {
        if canonicalSystemPromptEq(sys.content, prompt) {
            return false
        }
        sys.content = prompt
        conversation[0] = .system(sys)
        return true
    } else {
        conversation.insert(.system(prompt), at: 0)
        return true
    }
}

// MARK: - String helper

fileprivate extension String {
    /// Trim trailing `\n` and `\r` characters only (interior and leading
    /// whitespace preserved), mirroring Rust `trim_end_matches(['\n', '\r'])`.
    var trimmingTrailingNewlines: String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            let ch = self[prev]
            if ch == "\n" || ch == "\r" {
                end = prev
            } else {
                break
            }
        }
        return String(self[startIndex..<end])
    }
}
