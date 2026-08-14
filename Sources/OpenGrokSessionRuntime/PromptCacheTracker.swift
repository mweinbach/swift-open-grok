// PromptCacheTracker.swift
//
// Open Grok — Prompt cache tracking, break diagnostics, and session cache telemetry.
//
// Prompt caching in LLMs (xAI Grok, OpenAI Codex/Responses, Anthropic Messages, DeepSeek)
// requires the prompt prefix to remain byte-for-byte stable across consecutive turns.
// Any modification to the system prompt, tool definitions, earlier conversation items,
// or model configuration invalidates the KV cache at that position.
//
// Reference in Rust: `crates/codegen/xai-grok-shell/src/session/cache_tracker.rs`.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Constants

/// Placeholder inserted when a tool result is hard-cleared from context.
public let hardClearPlaceholder: String = "[Tool result omitted — too old]"
/// Separator inserted between head and tail in soft-trimmed results.
public let softTrimSeparator: String = "[…trimmed…]"
/// Maximum number of recent turn records kept in memory for interactive inspection.
public let maxRecentTurnRecords: Int = 50

// MARK: - CacheBreakReason

/// Specific reason why prompt caching broke or diverged from the previous turn.
public enum CacheBreakReason: String, Codable, Sendable, Hashable, CaseIterable {
    case systemPromptChanged
    case toolsChanged
    case messageSequenceChanged
    case compaction
    case modelChanged
    case historyRelocated
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = CacheBreakReason(rawValue: raw) ?? .unknown
    }

    public var displayLabel: String {
        switch self {
        case .systemPromptChanged: return "System prompt modified"
        case .toolsChanged: return "Tool definitions changed"
        case .messageSequenceChanged: return "Message sequence diverged"
        case .compaction: return "History compaction or pruning"
        case .modelChanged: return "Model configuration changed"
        case .historyRelocated: return "Conversation history relocated"
        case .unknown: return "Unknown cache break"
        }
    }
}

// MARK: - CacheBreakEvent

/// A recorded cache break event capturing the turn, reason, timestamp, and details.
public struct CacheBreakEvent: Codable, Sendable, Equatable, Hashable {
    public var turnIndex: Int
    public var reason: CacheBreakReason
    public var timestamp: Date
    public var details: String?

    public init(
        turnIndex: Int,
        reason: CacheBreakReason,
        timestamp: Date = Date(),
        details: String? = nil
    ) {
        self.turnIndex = turnIndex
        self.reason = reason
        self.timestamp = timestamp
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case turnIndex = "turn_index"
        case turnIndexCamel = "turnIndex"
        case reason
        case timestamp
        case details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let idx = try container.decodeIfPresent(Int.self, forKey: .turnIndex) {
            self.turnIndex = idx
        } else if let idx = try container.decodeIfPresent(Int.self, forKey: .turnIndexCamel) {
            self.turnIndex = idx
        } else {
            self.turnIndex = 0
        }
        self.reason = (try? container.decode(CacheBreakReason.self, forKey: .reason)) ?? .unknown
        if let date = try? container.decode(Date.self, forKey: .timestamp) {
            self.timestamp = date
        } else if let str = try? container.decode(String.self, forKey: .timestamp),
                  let date = ISO8601DateFormatter().date(from: str) {
            self.timestamp = date
        } else {
            self.timestamp = Date()
        }
        self.details = try container.decodeIfPresent(String.self, forKey: .details)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turnIndex, forKey: .turnIndex)
        try container.encode(reason, forKey: .reason)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(details, forKey: .details)
    }
}

// MARK: - CacheStatus

/// Category of cache status for a single turn.
public enum CacheStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case firstTurn = "first_turn"
    case hit = "hit"
    case partialHit = "partial_hit"
    case `break` = "break"
    case noCacheSupport = "no_cache_support"

    public var displayLabel: String {
        switch self {
        case .firstTurn: return "First turn (cold cache)"
        case .hit: return "Cache hit"
        case .partialHit: return "Partial cache hit"
        case .break: return "Cache break"
        case .noCacheSupport: return "No cache reported"
        }
    }
}

// MARK: - ItemDivergenceReason

/// Detailed divergence reason for an individual item.
public enum ItemDivergenceReason: String, Codable, Sendable, Hashable {
    case pruned
    case imageEvicted
    case contentModified
    case variantChanged
}

// MARK: - PrefixDivergence

/// Structural prefix difference between two consecutive turns.
public enum PrefixDivergence: Codable, Sendable, Equatable, Hashable {
    case firstTurn
    case prefixIntact(preservedItems: Int, newItems: Int)
    case systemPromptChanged(diffOffset: Int, prevLen: Int, currLen: Int)
    case toolsChanged(diff: String)
    case itemDiverged(index: Int, kind: String, identifier: String?, reason: ItemDivergenceReason, diagnostic: String)
    case historyTruncated(prevCount: Int, currCount: Int)
    case modelChanged(prevModel: String, currModel: String)

    public var isIntact: Bool {
        switch self {
        case .firstTurn, .prefixIntact:
            return true
        default:
            return false
        }
    }

    public var summaryDiagnostic: String {
        switch self {
        case .firstTurn:
            return "First turn in session (initial prompt submission)."
        case .prefixIntact(let preservedItems, let newItems):
            let s = newItems == 1 ? "" : "s"
            return "Prefix 100% intact (\(preservedItems) items preserved, \(newItems) new item\(s) appended)."
        case .systemPromptChanged(let diffOffset, let prevLen, let currLen):
            return "System prompt diverged at character offset \(diffOffset) (length changed from \(prevLen) to \(currLen))."
        case .toolsChanged(let diff):
            return "Tool definitions changed: \(diff)"
        case .itemDiverged(let index, let kind, let identifier, let reason, let diagnostic):
            let idStr = identifier.map { " '\($0)'" } ?? ""
            let reasonStr: String
            switch reason {
            case .pruned: reasonStr = "was pruned/trimmed to save context tokens"
            case .imageEvicted: reasonStr = "had inline images evicted"
            case .contentModified: reasonStr = "was modified/edited"
            case .variantChanged: reasonStr = "changed item type variant"
            }
            return "Item #\(index) (\(kind)\(idStr)) \(reasonStr): \(diagnostic)"
        case .historyTruncated(let prevCount, let currCount):
            return "Conversation history truncated from \(prevCount) to \(currCount) items."
        case .modelChanged(let prevModel, let currModel):
            return "Model changed from '\(prevModel)' to '\(currModel)'."
        }
    }
}

// MARK: - CacheTurnRecord

/// Recorded outcome of a single turn for cache telemetry and diagnostics.
public struct CacheTurnRecord: Codable, Sendable, Equatable {
    public var turnIdx: String
    public var loopIndex: UInt32
    public var promptTokens: UInt32
    public var cachedPromptTokens: UInt32
    public var completionTokens: UInt32
    public var cacheHitRatePct: Double
    public var status: CacheStatus
    public var divergence: PrefixDivergence
    public var diagnostic: String
    public var timestampRfc3339: String

    public init(
        turnIdx: String,
        loopIndex: UInt32,
        promptTokens: UInt32,
        cachedPromptTokens: UInt32,
        completionTokens: UInt32,
        cacheHitRatePct: Double,
        status: CacheStatus,
        divergence: PrefixDivergence,
        diagnostic: String,
        timestampRfc3339: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.turnIdx = turnIdx
        self.loopIndex = loopIndex
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.completionTokens = completionTokens
        self.cacheHitRatePct = cacheHitRatePct
        self.status = status
        self.divergence = divergence
        self.diagnostic = diagnostic
        self.timestampRfc3339 = timestampRfc3339
    }
}

// MARK: - SessionCacheSnapshot

/// Comprehensive snapshot of a session's cache hit rate and break history.
public struct SessionCacheSnapshot: Codable, Sendable, Equatable {
    public var cacheHitRate: Double
    public var totalPromptTokens: Int
    public var cachedTokens: Int
    public var breakEvents: [CacheBreakEvent]

    public var totalTurns: Int
    public var hits: Int
    public var partialHits: Int
    public var breaks: Int
    public var steadyPromptTokens: Int
    public var steadyCachedTokens: Int
    public var lastBreakDiagnostic: String?

    public init(
        cacheHitRate: Double = 0.0,
        totalPromptTokens: Int = 0,
        cachedTokens: Int = 0,
        breakEvents: [CacheBreakEvent] = [],
        totalTurns: Int = 0,
        hits: Int = 0,
        partialHits: Int = 0,
        breaks: Int = 0,
        steadyPromptTokens: Int = 0,
        steadyCachedTokens: Int = 0,
        lastBreakDiagnostic: String? = nil
    ) {
        self.cacheHitRate = cacheHitRate
        self.totalPromptTokens = totalPromptTokens
        self.cachedTokens = cachedTokens
        self.breakEvents = breakEvents
        self.totalTurns = totalTurns
        self.hits = hits
        self.partialHits = partialHits
        self.breaks = breaks
        self.steadyPromptTokens = steadyPromptTokens
        self.steadyCachedTokens = steadyCachedTokens
        self.lastBreakDiagnostic = lastBreakDiagnostic
    }

    /// Hit rate expressed as a percentage (0.0% to 100.0%).
    public var cacheHitRatePct: Double {
        if cacheHitRate > 1.0 { return cacheHitRate }
        return (cacheHitRate * 1000.0).rounded() / 10.0
    }

    private enum CodingKeys: String, CodingKey {
        case cacheHitRate = "cache_hit_rate"
        case cacheHitRateCamel = "cacheHitRate"
        case hitRatePct = "hit_rate_pct"
        case overallHitRatePct = "overallHitRatePct"
        case totalPromptTokens = "total_prompt_tokens"
        case totalPromptTokensCamel = "totalPromptTokens"
        case totalInputTokens = "totalInputTokens"
        case cachedTokens = "cached_tokens"
        case cachedTokensCamel = "cachedTokens"
        case totalCachedTokens = "totalCachedTokens"
        case breakEvents = "break_events"
        case breakEventsCamel = "breakEvents"
        case totalTurns = "total_turns"
        case totalTurnsCamel = "totalTurns"
        case hits
        case partialHits = "partial_hits"
        case partialHitsCamel = "partialHits"
        case breaks
        case steadyPromptTokens = "steady_prompt_tokens"
        case steadyPromptTokensCamel = "steadyPromptTokens"
        case steadyInputTokens = "steadyInputTokens"
        case steadyCachedTokens = "steady_cached_tokens"
        case steadyCachedTokensCamel = "steadyCachedTokens"
        case lastBreakDiagnostic = "last_break_diagnostic"
        case lastBreakDiagnosticCamel = "lastBreakDiagnostic"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cacheHitRate = (try? c.decode(Double.self, forKey: .cacheHitRate))
            ?? (try? c.decode(Double.self, forKey: .cacheHitRateCamel))
            ?? (try? c.decode(Double.self, forKey: .hitRatePct))
            ?? (try? c.decode(Double.self, forKey: .overallHitRatePct))
            ?? 0.0
        self.totalPromptTokens = (try? c.decode(Int.self, forKey: .totalPromptTokens))
            ?? (try? c.decode(Int.self, forKey: .totalPromptTokensCamel))
            ?? (try? c.decode(Int.self, forKey: .totalInputTokens))
            ?? 0
        self.cachedTokens = (try? c.decode(Int.self, forKey: .cachedTokens))
            ?? (try? c.decode(Int.self, forKey: .cachedTokensCamel))
            ?? (try? c.decode(Int.self, forKey: .totalCachedTokens))
            ?? 0
        self.breakEvents = (try? c.decode([CacheBreakEvent].self, forKey: .breakEvents))
            ?? (try? c.decode([CacheBreakEvent].self, forKey: .breakEventsCamel))
            ?? []
        self.totalTurns = (try? c.decode(Int.self, forKey: .totalTurns))
            ?? (try? c.decode(Int.self, forKey: .totalTurnsCamel))
            ?? 0
        self.hits = (try? c.decode(Int.self, forKey: .hits)) ?? 0
        self.partialHits = (try? c.decode(Int.self, forKey: .partialHits))
            ?? (try? c.decode(Int.self, forKey: .partialHitsCamel))
            ?? 0
        self.breaks = (try? c.decode(Int.self, forKey: .breaks)) ?? 0
        self.steadyPromptTokens = (try? c.decode(Int.self, forKey: .steadyPromptTokens))
            ?? (try? c.decode(Int.self, forKey: .steadyPromptTokensCamel))
            ?? (try? c.decode(Int.self, forKey: .steadyInputTokens))
            ?? 0
        self.steadyCachedTokens = (try? c.decode(Int.self, forKey: .steadyCachedTokens))
            ?? (try? c.decode(Int.self, forKey: .steadyCachedTokensCamel))
            ?? 0
        self.lastBreakDiagnostic = (try? c.decodeIfPresent(String.self, forKey: .lastBreakDiagnostic))
            ?? (try? c.decodeIfPresent(String.self, forKey: .lastBreakDiagnosticCamel))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cacheHitRate, forKey: .cacheHitRate)
        try c.encode(totalPromptTokens, forKey: .totalPromptTokens)
        try c.encode(cachedTokens, forKey: .cachedTokens)
        try c.encode(breakEvents, forKey: .breakEvents)
        try c.encode(totalTurns, forKey: .totalTurns)
        try c.encode(hits, forKey: .hits)
        try c.encode(partialHits, forKey: .partialHits)
        try c.encode(breaks, forKey: .breaks)
        try c.encode(steadyPromptTokens, forKey: .steadyPromptTokens)
        try c.encode(steadyCachedTokens, forKey: .steadyCachedTokens)
        try c.encodeIfPresent(lastBreakDiagnostic, forKey: .lastBreakDiagnostic)
    }
}

// MARK: - Summaries & Fingerprinting

public struct ItemSummary: Codable, Sendable, Equatable, Hashable {
    public var index: Int
    public var kind: String
    public var identifier: String?
    public var byteLen: Int
    public var contentHash: UInt64
    public var isPruned: Bool
    public var hasImages: Bool
    public var preview: String

    public init(
        index: Int,
        kind: String,
        identifier: String?,
        byteLen: Int,
        contentHash: UInt64,
        isPruned: Bool,
        hasImages: Bool,
        preview: String
    ) {
        self.index = index
        self.kind = kind
        self.identifier = identifier
        self.byteLen = byteLen
        self.contentHash = contentHash
        self.isPruned = isPruned
        self.hasImages = hasImages
        self.preview = preview
    }
}

public struct ToolSummary: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var descriptionHash: UInt64
    public var paramsHash: UInt64

    public init(name: String, descriptionHash: UInt64, paramsHash: UInt64) {
        self.name = name
        self.descriptionHash = descriptionHash
        self.paramsHash = paramsHash
    }
}

public struct RequestSummary: Codable, Sendable, Equatable {
    public var model: String?
    public var systemPrompt: String?
    public var systemPromptHash: UInt64
    public var tools: [ToolSummary]
    public var items: [ItemSummary]
    public var totalBodyBytes: Int

    public init(
        model: String? = nil,
        systemPrompt: String? = nil,
        systemPromptHash: UInt64 = 0,
        tools: [ToolSummary] = [],
        items: [ItemSummary] = [],
        totalBodyBytes: Int = 0
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.systemPromptHash = systemPromptHash
        self.tools = tools
        self.items = items
        self.totalBodyBytes = totalBodyBytes
    }
}

// MARK: - Hash Helpers

private func fnv1a64(_ string: String) -> UInt64 {
    var hash: UInt64 = 14695981039346656037
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    return hash
}

private func truncatePreview(_ text: String, maxChars: Int = 40) -> String {
    let singleLine = text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    if singleLine.count <= maxChars {
        return singleLine
    }
    let truncated = String(singleLine.prefix(max(0, maxChars - 1)))
    return "\(truncated)…"
}

private func describeToolsDiff(prev: [ToolSummary], curr: [ToolSummary]) -> String {
    let prevNames = prev.map(\.name)
    let currNames = curr.map(\.name)

    let added = currNames.filter { !prevNames.contains($0) }
    let removed = prevNames.filter { !currNames.contains($0) }

    var parts: [String] = []
    if !added.isEmpty {
        parts.append("added [\(added.joined(separator: ", "))]")
    }
    if !removed.isEmpty {
        parts.append("removed [\(removed.joined(separator: ", "))]")
    }
    if prevNames.count == currNames.count && added.isEmpty && removed.isEmpty {
        parts.append("parameters or descriptions modified")
    }
    if parts.isEmpty {
        return "tools reordered"
    }
    return parts.joined(separator: "; ")
}

private func findFirstCharDiff(_ a: String, _ b: String) -> Int {
    var count = 0
    for (ca, cb) in zip(a, b) {
        if ca == cb {
            count += 1
        } else {
            break
        }
    }
    return count
}

// MARK: - PromptCacheTracker

/// Actor managing turn-by-turn prompt cache tracking, divergence detection, and telemetry.
public actor PromptCacheTracker {
    public private(set) var previousRequestSummary: RequestSummary?
    public private(set) var turnRecords: [CacheTurnRecord] = []
    public private(set) var breakEvents: [CacheBreakEvent] = []
    public private(set) var snapshot: SessionCacheSnapshot = SessionCacheSnapshot()

    public init(initialSnapshot: SessionCacheSnapshot? = nil) {
        if let initial = initialSnapshot {
            self.snapshot = initial
            self.breakEvents = initial.breakEvents
        }
    }

    /// Access the current session cache snapshot.
    public func currentSnapshot() -> SessionCacheSnapshot {
        snapshot
    }

    /// Access recent turn cache records.
    public func recentTurns() -> [CacheTurnRecord] {
        turnRecords
    }

    /// Access recorded break events.
    public func recordedBreaks() -> [CacheBreakEvent] {
        breakEvents
    }

    /// Reset tracking state for a new session.
    public func reset() {
        previousRequestSummary = nil
        turnRecords.removeAll()
        breakEvents.removeAll()
        snapshot = SessionCacheSnapshot()
    }

    /// Summarize a `ConversationRequest` into a lightweight structural fingerprint.
    public nonisolated static func summarizeRequest(_ request: ConversationRequest) -> RequestSummary {
        var totalBodyBytes = 0

        var systemPrompt: String? = nil
        for item in request.items {
            if case .system(let s) = item {
                systemPrompt = s.content
                break
            }
        }
        let systemPromptHash: UInt64
        if let sys = systemPrompt {
            totalBodyBytes += sys.utf8.count
            systemPromptHash = fnv1a64(sys)
        } else {
            systemPromptHash = 0
        }

        var tools: [ToolSummary] = []
        tools.reserveCapacity(request.tools.count)
        for tool in request.tools {
            let descHash = tool.description.map(fnv1a64) ?? 0
            let paramsStr = (try? WireJSONEncoder.makeSorted().encode(tool.parameters))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let paramsHash = fnv1a64(paramsStr)
            totalBodyBytes += tool.name.utf8.count
            if let d = tool.description {
                totalBodyBytes += d.utf8.count
            }
            tools.push(ToolSummary(name: tool.name, descriptionHash: descHash, paramsHash: paramsHash))
        }

        var items: [ItemSummary] = []
        items.reserveCapacity(request.items.count)
        for (index, item) in request.items.enumerated() {
            let (kind, id, len, pruned, hasImages, preview, contentHash) = summarizeItem(item, at: index)
            totalBodyBytes += len
            items.push(ItemSummary(
                index: index,
                kind: kind,
                identifier: id,
                byteLen: len,
                contentHash: contentHash,
                isPruned: pruned,
                hasImages: hasImages,
                preview: preview
            ))
        }

        return RequestSummary(
            model: request.model,
            systemPrompt: systemPrompt,
            systemPromptHash: systemPromptHash,
            tools: tools,
            items: items,
            totalBodyBytes: totalBodyBytes
        )
    }

    /// Summarize prompt components directly.
    public nonisolated static func summarize(
        systemPrompt: String? = nil,
        tools: [ToolSpec] = [],
        items: [ConversationItem] = [],
        model: String? = nil
    ) -> RequestSummary {
        let req = ConversationRequest(
            items: (systemPrompt.map { [ConversationItem.system($0)] } ?? []) + items,
            tools: tools,
            model: model
        )
        return summarizeRequest(req)
    }

    /// Summarize an individual `ConversationItem`.
    private nonisolated static func summarizeItem(
        _ item: ConversationItem,
        at index: Int
    ) -> (kind: String, id: String?, byteLen: Int, isPruned: Bool, hasImages: Bool, preview: String, contentHash: UInt64) {
        switch item {
        case .system(let s):
            let len = s.content.utf8.count
            let preview = truncatePreview(s.content, maxChars: 40)
            let hash = fnv1a64("system:\(s.content)")
            return ("system", nil, len, false, false, preview, hash)

        case .user(let u):
            var len = 0
            var hasImages = false
            var textBuf = ""
            for part in u.content {
                switch part {
                case .text(let text):
                    len += text.utf8.count
                    if textBuf.count < 40 {
                        textBuf.append(text)
                    }
                case .image(let url):
                    len += url.utf8.count
                    hasImages = true
                }
            }
            let preview = truncatePreview(textBuf, maxChars: 40)
            let hash = fnv1a64("user:\(u.content)")
            return ("user", nil, len, false, hasImages, preview, hash)

        case .assistant(let a):
            let textLen = a.content.utf8.count
            let toolsLen = a.toolCalls.reduce(0) { $0 + $1.name.utf8.count + $1.arguments.utf8.count }
            let len = textLen + toolsLen
            let id = a.toolCalls.first?.name
            let preview: String
            if let first = a.toolCalls.first {
                preview = "calls '\(first.name)' (\(first.arguments.count) args)"
            } else {
                preview = truncatePreview(a.content, maxChars: 40)
            }
            let callsStr = a.toolCalls.map { "\($0.id):\($0.name):\($0.arguments)" }.joined(separator: "|")
            let hash = fnv1a64("assistant:\(a.content):\(callsStr)")
            return ("assistant", id, len, false, false, preview, hash)

        case .toolResult(let tr):
            var len = tr.content.utf8.count
            var hasImages = !tr.images.isEmpty
            let isPruned = tr.content.contains(hardClearPlaceholder) || tr.content.contains(softTrimSeparator)
            for img in tr.images {
                switch img {
                case .text(let t): len += t.utf8.count
                case .image(let u): len += u.utf8.count
                }
            }
            for block in tr.orderedContent {
                switch block {
                case .text(let t): len += t.utf8.count
                case .image(let u, _):
                    len += u.utf8.count
                    hasImages = true
                }
            }
            let preview = truncatePreview(tr.content, maxChars: 40)
            let hash = fnv1a64("toolResult:\(tr.toolCallId):\(tr.content)")
            return ("tool_result", tr.toolCallId, len, isPruned, hasImages, preview, hash)

        case .customToolOutput(let co):
            var len = 0
            var hasImages = false
            var textBuf = ""
            for block in co.content {
                switch block {
                case .text(let text):
                    len += text.utf8.count
                    if textBuf.count < 40 {
                        textBuf.append(text)
                    }
                case .image(let url, _):
                    len += url.utf8.count
                    hasImages = true
                }
            }
            let preview = truncatePreview(textBuf, maxChars: 40)
            let hash = fnv1a64("customToolOutput:\(co.callId):\(textBuf)")
            return ("custom_tool_output", co.callId, len, false, hasImages, preview, hash)

        case .backendToolCall(let btc):
            let json = (try? WireJSONEncoder.makeSorted().encode(btc)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let preview = truncatePreview(json, maxChars: 40)
            let hash = fnv1a64("backendToolCall:\(json)")
            return ("backend_tool_call", nil, json.utf8.count, false, false, preview, hash)

        case .reasoning(let r):
            let json = (try? WireJSONEncoder.makeSorted().encode(r)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let preview = truncatePreview(json, maxChars: 40)
            let hash = fnv1a64("reasoning:\(json)")
            return ("reasoning", nil, json.utf8.count, false, false, preview, hash)
        }
    }

    /// Compare previous request summary against current request summary to analyze prefix divergence.
    public nonisolated static func analyzePrefixDivergence(
        previous: RequestSummary?,
        current: RequestSummary
    ) -> PrefixDivergence {
        guard let prev = previous else {
            return .firstTurn
        }

        // 1. Check model
        if let pm = prev.model, let cm = current.model, pm != cm {
            return .modelChanged(prevModel: pm, currModel: cm)
        }

        // 2. Check system prompt
        if prev.systemPromptHash != current.systemPromptHash {
            let prevStr = prev.systemPrompt ?? ""
            let currStr = current.systemPrompt ?? ""
            let diffOffset = findFirstCharDiff(prevStr, currStr)
            return .systemPromptChanged(
                diffOffset: diffOffset,
                prevLen: prevStr.count,
                currLen: currStr.count
            )
        }

        // 3. Check tools
        if prev.tools != current.tools {
            let diff = describeToolsDiff(prev: prev.tools, curr: current.tools)
            return .toolsChanged(diff: diff)
        }

        // 4. Check items prefix
        let minItems = min(prev.items.count, current.items.count)
        for i in 0..<minItems {
            let prevItem = prev.items[i]
            let currItem = current.items[i]

            if prevItem.contentHash != currItem.contentHash {
                let reason: ItemDivergenceReason
                let diagnostic: String

                if prevItem.kind != currItem.kind {
                    reason = .variantChanged
                    diagnostic = "Changed from '\(prevItem.kind)' to '\(currItem.kind)'"
                } else if !prevItem.isPruned && currItem.isPruned {
                    reason = .pruned
                    diagnostic = "Tool output pruned from \(prevItem.byteLen) bytes to \(currItem.byteLen) bytes ('\(currItem.preview)')"
                } else if prevItem.hasImages && !currItem.hasImages {
                    reason = .imageEvicted
                    diagnostic = "Inline images were evicted from this message"
                } else {
                    reason = .contentModified
                    diagnostic = "Length changed from \(prevItem.byteLen) to \(currItem.byteLen) bytes (preview: '\(currItem.preview)')"
                }

                return .itemDiverged(
                    index: i,
                    kind: currItem.kind,
                    identifier: currItem.identifier,
                    reason: reason,
                    diagnostic: diagnostic
                )
            }
        }

        // 5. Check if history was truncated
        if current.items.count < prev.items.count {
            return .historyTruncated(
                prevCount: prev.items.count,
                currCount: current.items.count
            )
        }

        // 6. Prefix is completely intact
        return .prefixIntact(
            preservedItems: prev.items.count,
            newItems: current.items.count - prev.items.count
        )
    }

    /// Evaluate divergence between turns and categorize the break reason.
    public nonisolated static func evaluateDivergence(
        previous: RequestSummary?,
        current: RequestSummary,
        cachedTokens: Int = 0,
        promptTokens: Int = 0,
        turnIndex: Int = 0
    ) -> (reason: CacheBreakReason?, isIntact: Bool, diagnostic: String) {
        let divergence = analyzePrefixDivergence(previous: previous, current: current)

        switch divergence {
        case .firstTurn:
            return (nil, true, "First turn in session (cold cache).")

        case .modelChanged(let prev, let curr):
            return (.modelChanged, false, "Model changed from '\(prev)' to '\(curr)'.")

        case .systemPromptChanged(_, let prevLen, let currLen):
            return (.systemPromptChanged, false, "System prompt diverged (length changed from \(prevLen) to \(currLen)).")

        case .toolsChanged(let diff):
            return (.toolsChanged, false, "Tool definitions changed: \(diff)")

        case .itemDiverged(_, _, _, let itemReason, let diag):
            switch itemReason {
            case .pruned:
                return (.compaction, false, "Pruned history item: \(diag)")
            case .imageEvicted, .contentModified, .variantChanged:
                return (.messageSequenceChanged, false, "Message sequence modified: \(diag)")
            }

        case .historyTruncated(let prevCount, let currCount):
            return (.compaction, false, "Conversation history truncated from \(prevCount) to \(currCount) items.")

        case .prefixIntact(let preserved, let newItems):
            if promptTokens > 0 && cachedTokens == 0 && turnIndex > 0 {
                return (.unknown, true, "0 cached tokens reported despite intact prefix (provider may not support caching or cache expired).")
            }
            return (nil, true, "Prefix intact (\(preserved) preserved, \(newItems) new).")
        }
    }

    // MARK: - Turn Recording

    /// Record a turn outcome from a full `ConversationRequest`.
    @discardableResult
    public func recordTurn(
        request: ConversationRequest,
        promptTokens: Int,
        cachedTokens: Int,
        completionTokens: Int = 0,
        turnIndex: Int? = nil,
        sessionId: String? = nil
    ) -> CacheBreakEvent? {
        let summary = Self.summarizeRequest(request)
        let resolvedTurnIdx = turnIndex ?? (snapshot.totalTurns + 1)
        return recordTurnOutcome(
            turnIndex: resolvedTurnIdx,
            loopIndex: 0,
            promptTokens: promptTokens,
            cachedTokens: cachedTokens,
            completionTokens: completionTokens,
            currentRequestSummary: summary,
            sessionId: sessionId
        )
    }

    /// Record a turn outcome from individual components.
    @discardableResult
    public func recordTurn(
        systemPrompt: String? = nil,
        tools: [ToolSpec] = [],
        items: [ConversationItem] = [],
        model: String? = nil,
        promptTokens: Int,
        cachedTokens: Int,
        completionTokens: Int = 0,
        turnIndex: Int? = nil,
        sessionId: String? = nil
    ) -> CacheBreakEvent? {
        let summary = Self.summarize(systemPrompt: systemPrompt, tools: tools, items: items, model: model)
        let resolvedTurnIdx = turnIndex ?? (snapshot.totalTurns + 1)
        return recordTurnOutcome(
            turnIndex: resolvedTurnIdx,
            loopIndex: 0,
            promptTokens: promptTokens,
            cachedTokens: cachedTokens,
            completionTokens: completionTokens,
            currentRequestSummary: summary,
            sessionId: sessionId
        )
    }

    /// Record turn outcome and update running totals, diagnostics, and break events.
    @discardableResult
    public func recordTurnOutcome(
        turnIndex: Int,
        loopIndex: UInt32 = 0,
        promptTokens: Int,
        cachedTokens: Int,
        completionTokens: Int = 0,
        currentRequestSummary: RequestSummary,
        sessionId: String? = nil
    ) -> CacheBreakEvent? {
        let divergence = Self.analyzePrefixDivergence(
            previous: previousRequestSummary,
            current: currentRequestSummary
        )

        let hitRatePct: Double
        if promptTokens > 0 {
            hitRatePct = (Double(cachedTokens) / Double(promptTokens)) * 100.0
        } else {
            hitRatePct = 0.0
        }

        // Determine CacheStatus
        let status: CacheStatus
        if previousRequestSummary == nil {
            status = .firstTurn
        } else if cachedTokens > 0 {
            if hitRatePct >= 50.0 {
                status = .hit
            } else {
                status = .partialHit
            }
        } else if promptTokens > 0 && divergence.isIntact {
            status = .noCacheSupport
        } else {
            status = .break
        }

        // Determine break reason & diagnostic
        let breakReason: CacheBreakReason?
        let diagnostic: String

        switch status {
        case .firstTurn:
            breakReason = nil
            diagnostic = "First turn in session (cold cache)."
        case .hit:
            breakReason = nil
            var d = String(format: "Cache hit: %.1f%% (%d/%d tokens cached).", hitRatePct, cachedTokens, promptTokens)
            if hitRatePct < 90.0 && divergence.isIntact {
                d += " Remaining tokens are new content appended since the previous request."
            }
            diagnostic = d
        case .partialHit:
            let (reason, _, _) = Self.evaluateDivergence(
                previous: previousRequestSummary,
                current: currentRequestSummary,
                cachedTokens: cachedTokens,
                promptTokens: promptTokens,
                turnIndex: turnIndex
            )
            breakReason = reason
            diagnostic = String(format: "Partial cache hit: %.1f%% (%d/%d tokens cached). %@", hitRatePct, cachedTokens, promptTokens, divergence.summaryDiagnostic)
        case .break:
            let (reason, _, _) = Self.evaluateDivergence(
                previous: previousRequestSummary,
                current: currentRequestSummary,
                cachedTokens: cachedTokens,
                promptTokens: promptTokens,
                turnIndex: turnIndex
            )
            breakReason = reason ?? .unknown
            diagnostic = "Cache break: 0% hit rate. \(divergence.summaryDiagnostic)"
        case .noCacheSupport:
            breakReason = nil
            diagnostic = "0 cached tokens reported (provider may not support prompt caching or cache expired)."
        }

        // Update running snapshot totals
        snapshot.totalTurns += 1
        snapshot.totalPromptTokens += promptTokens
        snapshot.cachedTokens += cachedTokens

        if status != .firstTurn {
            snapshot.steadyPromptTokens += promptTokens
            snapshot.steadyCachedTokens += cachedTokens
        }

        if snapshot.steadyPromptTokens > 0 {
            snapshot.cacheHitRate = (Double(snapshot.steadyCachedTokens) / Double(snapshot.steadyPromptTokens)) * 100.0
        } else if snapshot.totalPromptTokens > 0 {
            snapshot.cacheHitRate = (Double(snapshot.cachedTokens) / Double(snapshot.totalPromptTokens)) * 100.0
        } else {
            snapshot.cacheHitRate = 0.0
        }

        switch status {
        case .hit:
            snapshot.hits += 1
        case .partialHit:
            snapshot.partialHits += 1
        case .break:
            snapshot.breaks += 1
            snapshot.lastBreakDiagnostic = diagnostic
        default:
            break
        }

        // Record break event if applicable
        var breakEvent: CacheBreakEvent? = nil
        if let reason = breakReason {
            let event = CacheBreakEvent(
                turnIndex: turnIndex,
                reason: reason,
                timestamp: Date(),
                details: diagnostic
            )
            breakEvents.append(event)
            snapshot.breakEvents = breakEvents
            breakEvent = event
        }

        // Record turn record
        let record = CacheTurnRecord(
            turnIdx: String(turnIndex),
            loopIndex: loopIndex,
            promptTokens: UInt32(max(0, promptTokens)),
            cachedPromptTokens: UInt32(max(0, cachedTokens)),
            completionTokens: UInt32(max(0, completionTokens)),
            cacheHitRatePct: (hitRatePct * 10.0).rounded() / 10.0,
            status: status,
            divergence: divergence,
            diagnostic: diagnostic
        )

        if turnRecords.count >= maxRecentTurnRecords {
            turnRecords.removeFirst()
        }
        turnRecords.append(record)

        // Store previous request summary
        previousRequestSummary = currentRequestSummary

        return breakEvent
    }

    /// Record a manual or externally detected cache break event.
    @discardableResult
    public func recordBreak(
        reason: CacheBreakReason,
        details: String? = nil,
        turnIndex: Int? = nil
    ) -> CacheBreakEvent {
        let resolvedTurnIdx = turnIndex ?? snapshot.totalTurns
        let event = CacheBreakEvent(
            turnIndex: resolvedTurnIdx,
            reason: reason,
            timestamp: Date(),
            details: details
        )
        breakEvents.append(event)
        snapshot.breaks += 1
        snapshot.breakEvents = breakEvents
        if let d = details {
            snapshot.lastBreakDiagnostic = d
        }
        return event
    }
}

// MARK: - Extension Helper

private extension Array {
    mutating func push(_ element: Element) {
        append(element)
    }
}
