// ChatStateEvents.swift
//
// Open Grok — Swift port of the events emitted by the `ChatStateActor` in
// `crates/codegen/xai-chat-state/src/events.rs`.
//
// Persistence is handled internally by the actor — these events are for
// session-level coordination only.

import Foundation

/// Events emitted by the `ChatStateActor` to the session main loop.
public enum ChatStateEvent: Sendable, Equatable {
    /// Prompt index changed (session uses this to update hunk tracker
    /// attribution).
    case promptIndexChanged(newIndex: Int)
    /// Token count updated (session uses this for notification meta,
    /// auto-compact threshold checks).
    case tokensUpdated(totalTokens: UInt64)
    /// Conversation was replaced (compaction/rewind) — session may need to
    /// reset idle-flush counters, memory injection flags, etc.
    case conversationReset(newLen: Int)
    /// Image byte-budget record for a built request (observability only,
    /// emitted on image-bearing turns).
    case imageBudget(
        bodyBytes: Int,
        triggerBytes: Int,
        reclaimTargetBytes: Int,
        inlineImages: Int,
        needsImageCompaction: Bool,
        evicted: Int,
        bodyBytesAfter: Int
    )
}
