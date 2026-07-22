// RequestBuilder.swift
//
// Open Grok — Swift port of conversation-request assembly helpers in
// `crates/codegen/xai-chat-state/src/actor/request_builder.rs`.
//
// Pure functions: tool-result pruning (API-copy), image size-gated compaction,
// and request-body byte measurement. The actor clones conversation state into
// these helpers so retained history is only hard-cleared by
// `pruneRetainedConversation`.

import Foundation
import OpenGrokSamplingTypes

// MARK: - Placeholders / thresholds

/// Placeholder inserted when a tool result is hard-cleared.
public let HARD_CLEAR_PLACEHOLDER = "[Tool result omitted — too old]"

/// Separator inserted between head and tail in soft-trimmed results.
let SOFT_TRIM_SEPARATOR = "\n\n[…trimmed…]\n\n"

/// Placeholder when an inline image is evicted for the request-body budget.
public let IMAGE_COMPACT_PLACEHOLDER =
    "[An earlier image was removed to keep the request within its size limit and is no longer visible. Do not describe or reason about its contents from memory; ask the user to re-share it if you need to see it again.]"

/// Hard request-body ceiling (nginx proxy-body-size).
public let MAX_REQUEST_BYTES = 50 * 1024 * 1024

/// Evict old images once the serialized body reaches this size (3 MB headroom).
public let IMAGE_COMPACT_TRIGGER_BYTES = MAX_REQUEST_BYTES - 3 * 1024 * 1024

/// Low-water mark that eviction reclaims down to once it fires (hysteresis).
public let IMAGE_COMPACT_RECLAIM_TARGET_BYTES = MAX_REQUEST_BYTES / 2

// MARK: - Prune gating

/// Returns `true` when `totalTokens` exceeds 50% of `contextWindow`.
public func shouldPrune(totalTokens: UInt64, contextWindow: UInt64) -> Bool {
    guard contextWindow > 0 else { return false }
    return totalTokens > contextWindow / 2
}

/// Prune old, large tool results from the conversation in place (API-copy path).
///
/// Turn age is estimated by walking backward and counting `User` items.
public func pruneConversation(_ conversation: inout [ConversationItem], config: PruningConfig) {
    guard config.enabled else { return }

    var turnFromEnd = 0
    var seenFirstUser = false

    for i in conversation.indices.reversed() {
        if case .user = conversation[i] {
            if seenFirstUser {
                turnFromEnd += 1
            }
            seenFirstUser = true
            continue
        }

        // Never prune recent turns.
        if turnFromEnd < config.keepLastNTurns {
            continue
        }

        switch conversation[i] {
        case .toolResult(var toolResult):
            if turnFromEnd >= config.hardClearAgeTurns {
                toolResult.content = HARD_CLEAR_PLACEHOLDER
                toolResult.images = []
                toolResult.orderedContent = []
                conversation[i] = .toolResult(toolResult)
                continue
            }

            let source: String
            if toolResult.orderedContent.isEmpty {
                source = toolResult.content
            } else {
                source = toolResult.orderedContent.compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined()
            }
            if source.count > config.softTrimThreshold {
                let head = safeCharSlice(source, start: 0, count: config.softTrimHead)
                let tail = safeCharSliceTail(source, count: config.softTrimTail)
                let trimmed = "\(head)\(SOFT_TRIM_SEPARATOR)\(tail)"
                toolResult.content = trimmed
                toolResult.images = []
                toolResult.orderedContent = [.text(text: trimmed)]
                conversation[i] = .toolResult(toolResult)
            }

        case .customToolOutput(var output):
            if turnFromEnd >= config.hardClearAgeTurns {
                output.content = [.text(text: HARD_CLEAR_PLACEHOLDER)]
                conversation[i] = .customToolOutput(output)
                continue
            }
            // Match Rust `text_content()` join without separators.
            let source = output.content.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined()
            if source.count > config.softTrimThreshold {
                let head = safeCharSlice(source, start: 0, count: config.softTrimHead)
                let tail = safeCharSliceTail(source, count: config.softTrimTail)
                output.content = [.text(text: "\(head)\(SOFT_TRIM_SEPARATOR)\(tail)")]
                conversation[i] = .customToolOutput(output)
            }

        default:
            break
        }
    }
}

// MARK: - Image compaction

/// Outcome of image eviction for observability.
public struct ImageEvictionOutcome: Sendable, Equatable {
    public var evicted: Int
    public var bodyBytesAfter: Int

    public init(evicted: Int, bodyBytesAfter: Int) {
        self.evicted = evicted
        self.bodyBytesAfter = bodyBytesAfter
    }
}

/// Count of inline images in the conversation (observability).
public func inlineImageCount(_ conversation: [ConversationItem]) -> Int {
    conversation.reduce(0) { partial, item in
        partial + inlineImages(in: item)
    }
}

private func inlineImages(in item: ConversationItem) -> Int {
    switch item {
    case .user(let user):
        return user.content.reduce(0) { $0 + (isImagePart($1) ? 1 : 0) }
    case .toolResult(let result):
        let images = result.images.reduce(0) { $0 + (isImagePart($1) ? 1 : 0) }
        let ordered = result.orderedContent.reduce(0) { count, part in
            if case .image = part { return count + 1 }
            return count
        }
        return images + ordered
    case .customToolOutput(let output):
        return output.content.reduce(0) { count, part in
            if case .image = part { return count + 1 }
            return count
        }
    default:
        return 0
    }
}

private func isImagePart(_ part: ContentPart) -> Bool {
    if case .image = part { return true }
    return false
}

/// Exact-ish serialized size of the conversation body for the 50 MB gate.
///
/// Mirrors Rust: serialize a blanked-image clone (cheap non-image content) and
/// add raw image URL lengths (base64 data URLs do not JSON-escape).
public func conversationBodyBytes(_ conversation: [ConversationItem]) -> Int {
    var blanked = conversation
    var imageURLBytes = 0
    for i in blanked.indices {
        switch blanked[i] {
        case .user(var user):
            for j in user.content.indices {
                if case .image(let url) = user.content[j] {
                    imageURLBytes += url.utf8.count
                    user.content[j] = .image(url: "")
                }
            }
            blanked[i] = .user(user)
        case .toolResult(var result):
            for j in result.images.indices {
                if case .image(let url) = result.images[j] {
                    imageURLBytes += url.utf8.count
                    result.images[j] = .image(url: "")
                }
            }
            for j in result.orderedContent.indices {
                if case .image(let url, let detail) = result.orderedContent[j] {
                    imageURLBytes += url.utf8.count
                    result.orderedContent[j] = .image(url: "", detail: detail)
                }
            }
            blanked[i] = .toolResult(result)
        case .customToolOutput(var output):
            for j in output.content.indices {
                if case .image(let url, let detail) = output.content[j] {
                    imageURLBytes += url.utf8.count
                    output.content[j] = .image(url: "", detail: detail)
                }
            }
            blanked[i] = .customToolOutput(output)
        default:
            break
        }
    }
    return serializedJSONBytes(blanked) + imageURLBytes
}

/// Replace oldest inline images with `IMAGE_COMPACT_PLACEHOLDER` until the body
/// is at or below `targetBytes`. Operates on a request *copy* only.
@discardableResult
public func compactImagesToByteBudget(
    _ conversation: inout [ConversationItem],
    currentBytes: Int,
    targetBytes: Int
) -> ImageEvictionOutcome {
    if currentBytes <= targetBytes {
        return ImageEvictionOutcome(evicted: 0, bodyBytesAfter: currentBytes)
    }

    let contentPlaceholder = ContentPart.text(text: IMAGE_COMPACT_PLACEHOLDER)
    let contentPlaceholderBytes = serializedJSONBytes(contentPlaceholder)
    let orderedPlaceholder = CustomToolOutputContent.text(IMAGE_COMPACT_PLACEHOLDER)
    let orderedPlaceholderBytes = serializedJSONBytes(orderedPlaceholder)

    enum Location {
        case user(item: Int, part: Int)
        case toolResultImage(item: Int, part: Int)
        case toolResultOrdered(item: Int, part: Int)
        case customToolOutput(item: Int, part: Int)
    }

    struct Candidate {
        var location: Location
        var imageBytes: Int
        var placeholderBytes: Int
    }

    var images: [Candidate] = []
    for (i, item) in conversation.enumerated() {
        switch item {
        case .user(let user):
            for (j, part) in user.content.enumerated() {
                if case .image(let url) = part {
                    let blank = ContentPart.image(url: "")
                    images.append(Candidate(
                        location: .user(item: i, part: j),
                        imageBytes: imageValueBytes(blank: blank, url: url),
                        placeholderBytes: contentPlaceholderBytes
                    ))
                }
            }
        case .toolResult(let result):
            for (j, part) in result.images.enumerated() {
                if case .image(let url) = part {
                    let blank = ContentPart.image(url: "")
                    images.append(Candidate(
                        location: .toolResultImage(item: i, part: j),
                        imageBytes: imageValueBytes(blank: blank, url: url),
                        placeholderBytes: contentPlaceholderBytes
                    ))
                }
            }
            for (j, part) in result.orderedContent.enumerated() {
                if case .image(let url, let detail) = part {
                    let blankFrame = CustomToolOutputContent.image(url: "", detail: detail)
                    images.append(Candidate(
                        location: .toolResultOrdered(item: i, part: j),
                        imageBytes: imageValueBytes(blank: blankFrame, url: url),
                        placeholderBytes: orderedPlaceholderBytes
                    ))
                }
            }
        case .customToolOutput(let output):
            for (j, part) in output.content.enumerated() {
                if case .image(let url, let detail) = part {
                    let blankFrame = CustomToolOutputContent.image(url: "", detail: detail)
                    images.append(Candidate(
                        location: .customToolOutput(item: i, part: j),
                        imageBytes: imageValueBytes(blank: blankFrame, url: url),
                        placeholderBytes: orderedPlaceholderBytes
                    ))
                }
            }
        default:
            break
        }
    }

    var running = currentBytes
    var evicted = 0
    for image in images {
        if running <= targetBytes { break }
        let replaced: Bool
        switch image.location {
        case .user(let itemIdx, let partIdx):
            if case .user(var user) = conversation[itemIdx], partIdx < user.content.count {
                user.content[partIdx] = contentPlaceholder
                conversation[itemIdx] = .user(user)
                replaced = true
            } else {
                replaced = false
            }
        case .toolResultImage(let itemIdx, let partIdx):
            if case .toolResult(var result) = conversation[itemIdx], partIdx < result.images.count {
                result.images[partIdx] = contentPlaceholder
                conversation[itemIdx] = .toolResult(result)
                replaced = true
            } else {
                replaced = false
            }
        case .toolResultOrdered(let itemIdx, let partIdx):
            if case .toolResult(var result) = conversation[itemIdx], partIdx < result.orderedContent.count {
                result.orderedContent[partIdx] = orderedPlaceholder
                conversation[itemIdx] = .toolResult(result)
                replaced = true
            } else {
                replaced = false
            }
        case .customToolOutput(let itemIdx, let partIdx):
            if case .customToolOutput(var output) = conversation[itemIdx], partIdx < output.content.count {
                output.content[partIdx] = orderedPlaceholder
                conversation[itemIdx] = .customToolOutput(output)
                replaced = true
            } else {
                replaced = false
            }
        }
        if replaced {
            if image.imageBytes >= image.placeholderBytes {
                running -= image.imageBytes - image.placeholderBytes
            } else {
                running += image.placeholderBytes - image.imageBytes
            }
            evicted += 1
        }
    }

    return ImageEvictionOutcome(evicted: evicted, bodyBytesAfter: running)
}

// MARK: - Serialization helpers

private func serializedJSONBytes<T: Encodable>(_ value: T) -> Int {
    let encoder = JSONEncoder()
    // Sorted keys keep measurements stable across runs.
    encoder.outputFormatting = [.sortedKeys]
    do {
        return try encoder.encode(value).count
    } catch {
        // Fall back to a lower-bound content walk rather than forcing compaction.
        return 0
    }
}

private func imageValueBytes<T: Encodable>(blank: T, url: String) -> Int {
    serializedJSONBytes(blank) + url.utf8.count
}

// MARK: - String helpers (char-based, matching Rust `.chars()`)

func safeCharSlice(_ s: String, start: Int, count: Int) -> String {
    guard count > 0 else { return "" }
    let chars = Array(s)
    guard start < chars.count else { return "" }
    let end = min(start + count, chars.count)
    return String(chars[start..<end])
}

func safeCharSliceTail(_ s: String, count: Int) -> String {
    let chars = Array(s)
    if count >= chars.count { return s }
    if count <= 0 { return "" }
    return String(chars[(chars.count - count)...])
}
