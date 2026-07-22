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

/// Upsert a memory reminder into the conversation's system message.
///
/// If the first item is a `System` message, any previously injected
/// `<memory-context>` section is replaced in-place; otherwise the reminder is
/// appended. If no system message exists, a new `System` item is prepended.
///
/// Returns `true` when the conversation was changed.
@discardableResult
public func injectMemoryReminder(
    _ items: inout [ConversationItem],
    reminder: String
) -> Bool {
    let reminder = reminder.trimmingCharacters(in: .whitespacesAndNewlines)
    if reminder.isEmpty { return false }

    if let first = items.first, case .system(var sys) = first {
        let changed = upsertMemoryReminderText(&sys.content, reminder: reminder)
        if changed {
            items[0] = .system(sys)
        }
        return changed
    } else {
        items.insert(.system(reminder), at: 0)
        return true
    }
}

/// Replace or append a memory-context block in a system prompt string.
@discardableResult
public func upsertMemoryReminderText(_ systemPrompt: inout String, reminder: String) -> Bool {
    let updated: String
    if let range = systemPrompt.range(of: MEMORY_CONTEXT_OPEN_TAG) {
        let prefix = String(systemPrompt[..<range.lowerBound]).trimmingTrailingNewlines
        if prefix.isEmpty {
            updated = reminder
        } else {
            updated = "\(prefix)\n\n\(reminder)"
        }
    } else if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == reminder {
        updated = systemPrompt
    } else if systemPrompt.isEmpty {
        updated = reminder
    } else {
        updated = "\(systemPrompt.trimmingTrailingNewlines)\n\n\(reminder)"
    }

    if systemPrompt == updated {
        return false
    }
    systemPrompt = updated
    return true
}

// MARK: - String helper

fileprivate extension String {
    /// Trim trailing `\n` and `\r` characters only (interior and leading
    /// whitespace preserved), mirroring Rust `trim_end_matches(['\n', '\r'])`.
    ///
    /// Operates on Unicode scalars (not `Character` grapheme clusters) so a
    /// trailing CRLF (`\r\n`, one Swift `Character`) is fully stripped.
    var trimmingTrailingNewlines: String {
        var scalars = Array(unicodeScalars)
        while let last = scalars.last, last == "\n" || last == "\r" {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
