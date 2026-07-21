// ChatStateTokenEstimation.swift
//
// Open Grok — Swift port of the token-estimation helpers in
// `crates/codegen/xai-chat-state/src/actor/state.rs`.
//
// These are the bytes/4 estimates the `ChatStateActor` uses to drive its
// auto-compact gates and preflight overflow checks. They share one
// per-variant arithmetic with `OpenGrokTokenEstimation` so the budget math
// gets the same trusted count everywhere.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokTokenEstimation

/// Bytes/4 estimate of the system-prompt portion of a `ConversationItem`.
/// Returns 0 for non-system items so callers can pipe through whatever they
/// have without unwrapping.
public func estimateSystemMessageTokens(_ item: ConversationItem) -> UInt64 {
    if case .system(let s) = item {
        return estimateTokens(s.content)
    }
    return 0
}

/// Bytes/4 estimate for a single `ConversationItem`.
///
/// Images are counted at `OpenGrokTokenEstimation.IMAGE_TOKEN_ESTIMATE` each.
/// Shared by `estimateConversationTokens` and `estimateMessagesTokens` so the
/// per-variant arithmetic stays in one place.
public func estimateItemTokens(_ item: ConversationItem) -> UInt64 {
    switch item {
    case .system(let s):
        return estimateTokens(s.content)
    case .user(let u):
        var bytes = 0
        var images: UInt64 = 0
        for p in u.content {
            switch p {
            case .text(let text): bytes += text.utf8.count
            case .image: images += 1
            }
        }
        return UInt64(bytes) / BYTES_PER_TOKEN + estimateImageTokens(imageCount: images)
    case .assistant(let a):
        let bytes = a.content.utf8.count + a.toolCalls.reduce(0) { $0 + $1.arguments.utf8.count }
        return UInt64(bytes) / BYTES_PER_TOKEN
    case .toolResult(let tr):
        if tr.orderedContent.isEmpty {
            return estimateTokens(tr.content)
        }
        var bytes = 0
        var images: UInt64 = 0
        for part in tr.orderedContent {
            switch part {
            case .text(let text): bytes += text.utf8.count
            case .image: images += 1
            }
        }
        return UInt64(bytes) / BYTES_PER_TOKEN + estimateImageTokens(imageCount: images)
    case .customToolOutput(let output):
        var bytes = 0
        var images: UInt64 = 0
        for part in output.content {
            switch part {
            case .text(let text): bytes += text.utf8.count
            case .image: images += 1
            }
        }
        return UInt64(bytes) / BYTES_PER_TOKEN + estimateImageTokens(imageCount: images)
    case .backendToolCall(let b):
        return UInt64(b.estimatedContentLen()) / BYTES_PER_TOKEN
    case .reasoning(let r):
        // Summary + content text follow the standard bytes-per-token
        // estimate; encrypted blobs are base64 and don't survive tokenization
        // 1:1, so estimate at len/4 as well.
        let textBytes = reasoningItemText(r).utf8.count
        let encBytes = r.encryptedContent?.utf8.count ?? 0
        return UInt64(textBytes + encBytes) / BYTES_PER_TOKEN
    }
}

/// Estimate token footprint across a conversation.
public func estimateConversationTokens(_ items: [ConversationItem]) -> UInt64 {
    items.reduce(0) { $0 + estimateItemTokens($1) }
}

/// Bytes/4 estimate of every non-system item in `items`.
public func estimateMessagesTokens(_ items: [ConversationItem]) -> UInt64 {
    items.filter { item in
        if case .system = item { return false }
        return true
    }.reduce(0) { $0 + estimateItemTokens($1) }
}
