// ConversationRepair.swift
//
// Open Grok — Swift port of the conversation repair and dedup helpers and
// the rewind-truncation logic in
// `crates/codegen/xai-grok-sampling-types/src/conversation.rs`.
//
// These functions are pure: they mutate `inout [ConversationItem]` arrays
// without I/O. The chat-state actor (W1-S3 OpenGrokChatState) calls them at
// write boundaries to keep the in-memory and on-disk conversation
// consistent after a cancelled turn or a crash.

import Foundation

/// Why a tool call ended up dangling — controls the synthetic-result wording
/// produced by `repairDanglingToolCalls`.
public enum DanglingToolCallReason: Sendable, Equatable {
    /// User pressed Ctrl+C / aborted, or the cause cannot be determined.
    case userCancelled
    /// Harness halted the turn (internal error, policy guard, etc.).
    case harnessHalted(class: String)
}

/// Insert synthetic `ToolResult` items for any tool calls that lack a result.
///
/// When a turn is cancelled mid-tool-execution, the conversation can have an
/// assistant message with `tool_calls` but no matching `ToolResult`. The API
/// rejects this with "No tool output found for function call …".
///
/// Scans the entire conversation front-to-back. For every assistant message
/// that has `tool_calls`, checks which calls are answered by the immediately
/// following run of generic results and native custom outputs, and inserts
/// synthetic results for any calls that are missing, preserving the original
/// call order.
///
/// Returns the number of synthetic tool results inserted.
@discardableResult
public func repairDanglingToolCalls(
    _ conversation: inout [ConversationItem],
    reason: DanglingToolCallReason
) -> Int {
    // Phase 1: forward scan to find every assistant with unanswered tool
    // calls. Record (insertPosition, syntheticItems) for each repair site.
    var repairs: [(position: Int, items: [ConversationItem])] = []
    var i = 0
    while i < conversation.count {
        if case .assistant(let a) = conversation[i], !a.toolCalls.isEmpty {
            // Snapshot the call metadata we need.
            let toolCalls: [(id: String, name: String, isCustom: Bool, callId: String)] = a.toolCalls.map { tc in
                (tc.id, tc.name, tc.isCustom, tc.callId)
            }
            // Collect answered IDs from the immediately following tool-output items.
            var answered: Set<String> = []
            var j = i + 1
            while j < conversation.count {
                if let callId = toolOutputCallId(conversation[j]) {
                    answered.insert(callId)
                    j += 1
                } else {
                    break
                }
            }
            // Build synthetic results for unanswered calls, preserving call order.
            let synthetic: [ConversationItem] = toolCalls.compactMap { tc in
                if answered.contains(tc.callId) { return nil }
                let text = syntheticDanglingResultText(name: tc.name, reason: reason)
                if tc.isCustom {
                    return ConversationItem.makeCustomToolOutput(
                        CustomToolOutputItem.text(callId: tc.callId, text).withName(tc.name)
                    )
                } else {
                    return ConversationItem.toolResult(toolCallId: tc.id, content: text)
                }
            }
            if !synthetic.isEmpty {
                repairs.append((j, synthetic))
            }
            i = j
            continue
        }
        i += 1
    }
    // Phase 2: apply repairs in reverse index order so earlier indices stay valid.
    let total = repairs.reduce(0) { $0 + $1.items.count }
    for (insertAt, synthetic) in repairs.reversed() {
        conversation.insert(contentsOf: synthetic, at: insertAt)
    }
    return total
}

/// Read-only counterpart to `repairDanglingToolCalls`: returns `true` if any
/// assistant message has a tool call that is not answered by a generic result
/// or native custom output in the immediately-following output run.
public func hasDanglingToolCalls(_ conversation: [ConversationItem]) -> Bool {
    var i = 0
    while i < conversation.count {
        if case .assistant(let a) = conversation[i], !a.toolCalls.isEmpty {
            var answered: Set<String> = []
            var j = i + 1
            while j < conversation.count {
                if let callId = toolOutputCallId(conversation[j]) {
                    answered.insert(callId)
                    j += 1
                } else {
                    break
                }
            }
            if a.toolCalls.contains(where: { !answered.contains($0.callId) }) {
                return true
            }
            i = j
            continue
        }
        i += 1
    }
    return false
}

/// Remove duplicate `ToolResult` entries for the same `toolCallId`.
///
/// When a tool call is cancelled and then later the real result also
/// arrives, the conversation can end up with two `ToolResult` entries
/// sharing the same `toolCallId`. The LLM API rejects this with "each
/// tool_use must have a single result". Only the **last** occurrence is kept
/// (the real result). Native `CustomToolOutput` entries are deliberately
/// never deduplicated because one custom call may emit multiple ordered
/// progress/final output items.
///
/// Returns the number of duplicate entries removed.
@discardableResult
public func dedupDuplicateToolResults(_ conversation: inout [ConversationItem]) -> Int {
    var totalRemoved = 0
    var i = 0
    while i < conversation.count {
        if case .assistant(let a) = conversation[i], !a.toolCalls.isEmpty {
            let start = i + 1
            var end = start
            while end < conversation.count {
                if isToolOutput(conversation[end]) {
                    end += 1
                } else {
                    break
                }
            }
            if end > start {
                var seen: [String: Int] = [:]
                var toRemove: [Int] = []
                for idx in start..<end {
                    if case .toolResult(let tr) = conversation[idx] {
                        if let prev = seen[tr.toolCallId] {
                            // Mark the *previous* occurrence for removal.
                            toRemove.append(prev)
                            seen[tr.toolCallId] = idx
                        } else {
                            seen[tr.toolCallId] = idx
                        }
                    }
                }
                if !toRemove.isEmpty {
                    // Remove in reverse order so indices stay valid.
                    toRemove.sort()
                    for idx in toRemove.reversed() {
                        conversation.remove(at: idx)
                    }
                    totalRemoved += toRemove.count
                    // Don't advance i — the window shifted, re-scan from same spot.
                    continue
                }
            }
            i = end
            continue
        }
        i += 1
    }
    return totalRemoved
}

/// Calculate how many conversation items to keep so that everything from
/// prompt-turn `targetPromptIndex` onward is dropped (the cut lands on the
/// user item that **started** that turn).
public func conversationTruncateForPrompt(
    _ conversation: [ConversationItem],
    targetPromptIndex: Int
) -> Int {
    // Find the first marked user item.
    var firstMarkerIdx: Int? = nil
    for (idx, item) in conversation.enumerated() {
        if case .user(let u) = item, u.promptIndex != nil {
            firstMarkerIdx = u.promptIndex
            // The Rust code finds the first marker's `prompt_index` value, not
            // its position. Capture it and break.
            _ = idx
            break
        }
    }
    guard let firstMarkerIdx else {
        return conversationTruncateLegacy(conversation, targetPromptIndex: targetPromptIndex)
    }
    let unmarkedPrefixTurns = countLegacyTurnsUntilMarker(conversation)
    if unmarkedPrefixTurns != firstMarkerIdx {
        return conversationTruncateMarkersOnly(conversation, targetPromptIndex: targetPromptIndex)
    }
    return conversationTruncateProgressive(conversation, targetPromptIndex: targetPromptIndex)
}

// MARK: - Internal helpers

/// The provider call ID for a tool-output item (generic result or native
/// custom output), decoding the opaque custom-call envelope when present.
func toolOutputCallId(_ item: ConversationItem) -> String? {
    switch item {
    case .toolResult(let result):
        if let (callId, _) = ToolCall.decodeCustomToolCallId(result.toolCallId) {
            return callId
        }
        return result.toolCallId
    case .customToolOutput(let output):
        return output.callId
    default:
        return nil
    }
}

func isToolOutput(_ item: ConversationItem) -> Bool {
    toolOutputCallId(item) != nil
}

func syntheticDanglingResultText(name: String, reason: DanglingToolCallReason) -> String {
    switch reason {
    case .userCancelled:
        return "Tool execution was cancelled by the user (tool `\(name)` was not executed)."
    case .harnessHalted(let cls):
        return "Tool execution was halted by the harness (\(cls)); the tool `\(name)` was not executed."
    }
}

// MARK: - Truncation strategy helpers

private func conversationTruncateMarkersOnly(
    _ conversation: [ConversationItem], targetPromptIndex: Int
) -> Int {
    for (i, item) in conversation.enumerated() {
        guard case .user(let user) = item else { continue }
        if let idx = user.promptIndex, idx >= targetPromptIndex {
            return i
        }
    }
    return conversation.count
}

private func conversationTruncateLegacy(
    _ conversation: [ConversationItem], targetPromptIndex: Int
) -> Int {
    var nextUnmarkedIndex = 0
    var seenUnmarkedPreamble = false
    for (i, item) in conversation.enumerated() {
        guard case .user(let user) = item else { continue }
        let effectiveIndex: Int?
        switch user.syntheticReason {
        case nil where !seenUnmarkedPreamble:
            seenUnmarkedPreamble = true
            effectiveIndex = nil
        case nil:
            effectiveIndex = nextUnmarkedIndex
        case .some(let reason) where reason.startsPromptTurn:
            effectiveIndex = nextUnmarkedIndex
        default:
            effectiveIndex = nil
        }
        if let idx = effectiveIndex {
            if idx >= targetPromptIndex {
                return i
            }
            nextUnmarkedIndex = idx + 1
        }
    }
    return conversation.count
}

private func countLegacyTurnsUntilMarker(_ conversation: [ConversationItem]) -> Int {
    var turns = 0
    var seenUnmarkedPreamble = false
    for item in conversation {
        guard case .user(let user) = item else { continue }
        if user.promptIndex != nil { break }
        switch user.syntheticReason {
        case nil where !seenUnmarkedPreamble:
            seenUnmarkedPreamble = true
        case nil:
            turns += 1
        case .some(let reason) where reason.startsPromptTurn:
            turns += 1
        default:
            break
        }
    }
    return turns
}

private func conversationTruncateProgressive(
    _ conversation: [ConversationItem], targetPromptIndex: Int
) -> Int {
    var nextUnmarkedIndex = 0
    var seenUnmarkedPreamble = false
    var seenMarker = false
    for (i, item) in conversation.enumerated() {
        guard case .user(let user) = item else { continue }
        let effectiveIndex: Int?
        if let idx = user.promptIndex {
            seenMarker = true
            effectiveIndex = idx
        } else if seenMarker {
            effectiveIndex = nil
        } else {
            switch user.syntheticReason {
            case nil where !seenUnmarkedPreamble:
                seenUnmarkedPreamble = true
                effectiveIndex = nil
            case nil:
                effectiveIndex = nextUnmarkedIndex
            case .some(let reason) where reason.startsPromptTurn:
                effectiveIndex = nextUnmarkedIndex
            default:
                effectiveIndex = nil
            }
        }
        if let idx = effectiveIndex {
            if idx >= targetPromptIndex {
                return i
            }
            if user.promptIndex == nil {
                nextUnmarkedIndex = idx + 1
            }
        }
    }
    return conversation.count
}
