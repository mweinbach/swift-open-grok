// TwoPassCompaction.swift
//
// Pure builders, data structures, and algorithms for prefire two-pass compaction.
// Faithfully ported from Rust reference `crates/codegen/xai-grok-shell/src/session/two_pass.rs`
// and `crates/codegen/xai-grok-shell/src/session/compaction.rs:294-623`.
//
// Pass 1 summarizes ~95% of history (by estimated-token weight) into intermediate NOTE₁.
// Pass 2 rewrites NOTE₁ + the ~5% tail turns into the successor-visible NOTE₂.

import Foundation
import OpenGrokChatState
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTokenEstimation

// MARK: - Constants

/// Default history fraction covered by pass1; the remainder is the blocking
/// pass2 tail, so keep it small (pass2 latency is dominated by tail prefill).
public let TWO_PASS_DEFAULT_SPLIT_FRACTION: Double = 0.95

/// Minimum char length for a closed `<summary>` block to be preferred as NOTE₁
/// over the full pass1 response.
public let TWO_PASS_MIN_SUMMARY_BLOCK_CHARS: Int = 1000

/// Cap on NOTE₁ text embedded in pass2 (carrier + special turn).
public let TWO_PASS_MAX_NOTE1_CHARS: Int = 12_000

/// Default prefire lead percentage ahead of the hard compaction threshold.
public let DEFAULT_PREFIRE_LEAD_PERCENT: Double = 10.0

// MARK: - Data Structures

/// Result of splitting a conversation for two-pass compaction.
public struct TwoPassSplit: Sendable, Equatable {
    public var prefix: [ConversationItem]
    public var tail: [ConversationItem]
    public var splitIndex: Int

    public init(prefix: [ConversationItem], tail: [ConversationItem], splitIndex: Int) {
        self.prefix = prefix
        self.tail = tail
        self.splitIndex = splitIndex
    }
}

/// Structured outcome of speculative background prefire Pass 1.
public enum PrefireOutcome: String, Sendable, Equatable, Codable {
    case disabled
    case debugFailPass1 = "debug_fail_pass1"
    case tooSmall = "too_small"
    case emptySplit = "empty_split"
    case sampleFailed = "sample_failed"
    case emptyNote1 = "empty_note1"
    case cached
}

/// Cached result of an async (background / prefire) pass-1 sample for
/// two-pass compaction. Held on the coordinator between the background
/// pass-1 and the synchronous pass-2 apply at compaction time.
public struct AsyncCompactionCache: Sendable, Codable, Equatable {
    /// The successor-usable NOTE₁ text (extracted `<summary>` or full pass-1 output).
    public var note1: String
    /// Number of leading conversation items pass-1 summarized (the prefix
    /// boundary in the LIVE conversation as of pass-1 time). The pass-2 tail is
    /// `conversation[prefix_len..]`.
    public var prefixLen: Int
    /// Fingerprint of `conversation[..prefix_len]` at pass-1 time. Pass-2 only
    /// applies NOTE₁ when the current conversation still has this exact prefix.
    public var fingerprint: UInt64
    /// Model slug pass-1 ran under; invalidated on model switch.
    public var modelSlug: String
    /// Wall time pass-1 took (ms) — latency that ran off the critical path.
    public var pass1LatencyMs: UInt64
    /// Timestamp when cache was recorded.
    public var timestamp: Date

    public init(
        note1: String,
        prefixLen: Int,
        fingerprint: UInt64,
        modelSlug: String,
        pass1LatencyMs: UInt64,
        timestamp: Date = Date()
    ) {
        self.note1 = note1
        self.prefixLen = prefixLen
        self.fingerprint = fingerprint
        self.modelSlug = modelSlug
        self.pass1LatencyMs = pass1LatencyMs
        self.timestamp = timestamp
    }
}

/// Thread-safe prefire state coordinator.
public final class PrefireState: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Bool = false
    private var cache: AsyncCompactionCache?
    private var taskHandle: Task<Void, Never>?

    public init() {}

    /// Try to claim the single in-flight slot. Returns `true` iff this caller
    /// won the race and should spawn pass-1.
    public func tryBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight { return false }
        inFlight = true
        return true
    }

    /// Release the in-flight slot (call exactly once after a `tryBegin` win).
    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
    }

    public var isInFlight: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    public func setHandle(_ handle: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.taskHandle = handle
    }

    public func takeHandle() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let handle = taskHandle
        taskHandle = nil
        return handle
    }

    public func store(_ cache: AsyncCompactionCache) {
        lock.lock()
        defer { lock.unlock() }
        self.cache = cache
    }

    public func take() -> AsyncCompactionCache? {
        lock.lock()
        defer { lock.unlock() }
        let c = cache
        cache = nil
        return c
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
    }

    public var hasCache: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache != nil
    }
}

/// Cancel gate for an in-flight compact / prefire sample.
public final class CompactCancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holders: Int = 0
    private var cancelled: Bool = false

    public init() {}

    public func enter() -> (isCancelled: @Sendable () -> Bool, onEnd: @Sendable () -> Void) {
        lock.lock()
        holders += 1
        lock.unlock()

        let gate = self
        return (
            isCancelled: { gate.isCancelled },
            onEnd: { gate.end() }
        )
    }

    private func end() {
        lock.lock()
        defer { lock.unlock() }
        holders = max(0, holders - 1)
        if holders == 0 {
            cancelled = false
        }
    }

    public func requestCancel() {
        lock.lock()
        defer { lock.unlock() }
        if holders > 0 {
            cancelled = true
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return holders > 0 && cancelled
    }
}

// MARK: - Pure Algorithms & Splitting

/// Choose a split index so prefix weight is at least `fraction` of total.
public func splitIndexByTokenFraction(weights: [UInt64], fraction: Double) -> Int {
    guard !weights.isEmpty else { return 0 }
    let clampedFrac = min(0.95, max(0.05, fraction))
    let totalW = max(1, weights.reduce(0, &+))
    let targetW = clampedFrac * Double(totalW)
    var acc: UInt64 = 0
    var splitIdx = max(1, weights.count > 0 ? weights.count - 1 : 0)
    for (i, w) in weights.enumerated() {
        acc = acc &+ w
        if Double(acc) >= targetW {
            splitIdx = max(1, i + 1)
            break
        }
    }
    if splitIdx >= weights.count && weights.count > 1 {
        splitIdx = weights.count - 1
    }
    return splitIdx
}

public func splitIndexByTokenFraction(items: [ConversationItem], splitFraction: Double) -> Int {
    let weights = items.map(estimateItemTokens)
    return splitIndexByTokenFraction(weights: weights, fraction: splitFraction)
}

/// Never separate an assistant `tool_calls` turn from its following `ToolResult`s or `CustomToolOutput`s.
public func snapSplitIdxToToolBoundaries(
    conversation: [ConversationItem],
    splitIdx: Int
) -> Int {
    let n = conversation.count
    guard n > 0 else { return 0 }
    var idx = min(n, max(0, splitIdx))

    let isToolOutput: (ConversationItem) -> Bool = { item in
        switch item {
        case .toolResult, .customToolOutput: return true
        default: return false
        }
    }

    while idx < n && isToolOutput(conversation[idx]) {
        idx += 1
    }
    if idx < n, case .assistant(let a) = conversation[idx], !a.toolCalls.isEmpty {
        idx += 1
        while idx < n && isToolOutput(conversation[idx]) {
            idx += 1
        }
    }
    while idx > 0 && idx < n {
        guard case .assistant(let a) = conversation[idx - 1] else { break }
        if a.toolCalls.isEmpty { break }
        if idx >= n || !isToolOutput(conversation[idx]) { break }
        while idx < n && isToolOutput(conversation[idx]) {
            idx += 1
        }
    }

    if idx >= n && n > 1 {
        var candidate = n - 1
        while candidate > 1 && isToolOutput(conversation[candidate]) {
            candidate -= 1
        }
        if candidate > 0, case .assistant(let a) = conversation[candidate], !a.toolCalls.isEmpty {
            // candidate at assistant — safe for tail start.
        } else if candidate > 0 && isToolOutput(conversation[candidate]) {
            var i = candidate
            while i > 0 && isToolOutput(conversation[i]) {
                i -= 1
            }
            if i < conversation.count, case .assistant(let a) = conversation[i], !a.toolCalls.isEmpty {
                candidate = i
            }
        }
        if candidate >= 1 && candidate < n {
            idx = candidate
        }
    }

    return min(n, idx)
}

public func snapSplitIdxToToolBoundaries(items: [ConversationItem], splitIndex: Int) -> Int {
    snapSplitIdxToToolBoundaries(conversation: items, splitIdx: splitIndex)
}

/// Split `conversation` into pass1 prefix / pass2 tail by estimated-token weight.
public func splitConversationForTwoPass(
    _ items: [ConversationItem],
    splitFraction: Double = TWO_PASS_DEFAULT_SPLIT_FRACTION
) -> TwoPassSplit {
    let weights = items.map(estimateItemTokens)
    var splitIdx = splitIndexByTokenFraction(weights: weights, fraction: splitFraction)
    splitIdx = snapSplitIdxToToolBoundaries(conversation: items, splitIdx: splitIdx)
    splitIdx = min(items.count, splitIdx)
    return TwoPassSplit(
        prefix: Array(items[..<splitIdx]),
        tail: Array(items[splitIdx...]),
        splitIndex: splitIdx
    )
}

public func splitConversationForTwoPass(
    conversation: [ConversationItem],
    splitFraction: Double = TWO_PASS_DEFAULT_SPLIT_FRACTION
) -> TwoPassSplit {
    splitConversationForTwoPass(conversation, splitFraction: splitFraction)
}

// MARK: - Summary Extraction & Capping

/// Extract inner content of substantive `<summary>...</summary>` block if char count > `minChars`.
public func extractSummaryBlock(_ text: String, minChars: Int = TWO_PASS_MIN_SUMMARY_BLOCK_CHARS) -> String? {
    guard !text.isEmpty else { return nil }
    let openTag = "<summary>"
    let closeTag = "</summary>"
    let lower = text.lowercased()
    var blocks: [String] = []
    var searchFrom = lower.startIndex

    while let openRange = lower.range(of: openTag, range: searchFrom..<lower.endIndex) {
        let contentStart = openRange.upperBound
        guard let closeRange = lower.range(of: closeTag, range: contentStart..<lower.endIndex) else {
            break
        }
        let innerText = String(text[contentStart..<closeRange.lowerBound])
        blocks.append(innerText)
        searchFrom = closeRange.upperBound
    }

    for block in blocks.reversed() {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > minChars {
            return trimmed
        }
    }
    return nil
}

public func extractSummaryBlock(text: String, minChars: Int = TWO_PASS_MIN_SUMMARY_BLOCK_CHARS) -> String? {
    extractSummaryBlock(text, minChars: minChars)
}

/// Prefer a substantive `<summary>` inner for NOTE₁; otherwise the full pass1 response,
/// capped at 12,000 characters.
public func noteForTwoPassPass2(_ pass1Raw: String) -> String {
    var note = extractSummaryBlock(text: pass1Raw, minChars: TWO_PASS_MIN_SUMMARY_BLOCK_CHARS)
        ?? pass1Raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if note.count > TWO_PASS_MAX_NOTE1_CHARS {
        note = String(note.prefix(TWO_PASS_MAX_NOTE1_CHARS)) + "\n\n[… NOTE₁ truncated for pass2 input budget …]"
    }
    return note
}

public func noteForTwoPassPass2(pass1Raw: String) -> String {
    noteForTwoPassPass2(pass1Raw)
}

// MARK: - Deterministic Prefix Fingerprinting

/// 64-bit FNV-1a sequence hash over count, item role tag (0..6), and text content.
public func fingerprintPrefix(_ items: [ConversationItem]) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    let lenBytes = withUnsafeBytes(of: items.count) { Array($0) }
    for b in lenBytes {
        hash ^= UInt64(b)
        hash = hash &* 1_099_511_628_211
    }
    for item in items {
        let tag: UInt8 = {
            switch item {
            case .system: return 0
            case .user: return 1
            case .assistant: return 2
            case .toolResult: return 3
            case .backendToolCall: return 4
            case .reasoning: return 5
            case .customToolOutput: return 6
            }
        }()
        hash ^= UInt64(tag)
        hash = hash &* 1_099_511_628_211
        for byte in item.textContent().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
    }
    return hash
}

// MARK: - Prompt Formatting & History Construction

public func formatTwoPassNote1Carrier(_ note1: String) -> String {
    let trimmed = note1.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
    Your conversation was summarized due to context constraints. Here is the summary of the conversation so far:

    <summary_content>
    \(trimmed)
    </summary_content>

    Continue with the compaction task below.
    """
}

public func formatTwoPassNote1Carrier(note1: String) -> String {
    formatTwoPassNote1Carrier(note1)
}

public func formatTwoPassSpecialPass2User(note1: String, compactionPrompt: String) -> String {
    let trimmed = note1.trimmingCharacters(in: .whitespacesAndNewlines)
    let summaryBlock = "<summary_content>\n\(trimmed)\n</summary_content>"
    let uq = compactionPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Please summarize the conversation so far."
        : compactionPrompt
    return """
    This is a special compaction case (two-pass / hierarchical summarization).
    You are writing the *final* compaction note that a successor assistant will rely on as their only memory of the conversation.

    Critical requirements:
    - Incorporate the **entire** prior summary below into your final note — do not omit sections, defer to "see prior compaction", or drop early history because newer turns are in context.
    - Merge that prior summary with the more recent conversation turns above into one coherent, faithful, self-contained summary (same structure/sections you normally use for compaction).
    - Preserve concrete values, file paths, errors/blockers, operational how-tos, key findings, and pending tasks from *both* the prior summary and the recent turns when they still matter.

    Prior summary to incorporate in full (duplicate of the summary_content above):

    \(summaryBlock)

    Compaction instruction:
    \(uq)
    """
}

/// Five-section compaction instruction for two-pass prefire/pass2.
public func buildTwoPassCompactionPrompt(userContext: String? = nil) -> String {
    let userContextSection = matchUserContext(userContext)
    return """
    Your task is to produce a faithful, concise summary of the conversation so far so that a successor assistant can continue the work seamlessly after the earlier turns are discarded. The successor will see the user's original query plus this summary. Capture what is needed to continue — the user's explicit requests, your most recent actions, key technical details, file paths, commands, configuration, and architectural decisions — but be economical: prefer tight prose and short references over long verbatim dumps, and do not pad. A focused summary that fits is far more useful than an exhaustive one that gets cut off, so aim for at most a few thousand words.
    \(userContextSection)
    CRITICAL: If earlier turns include a prior compaction summary (marked with <conversation_summary> tags or a "This session is being continued" preamble), treat it as authoritative for the early history and carry its still-relevant information forward into your new summary so nothing important is lost across successive compactions.

    Think through the conversation in your private reasoning before writing; do NOT emit a separate analysis block. Output the final summary inside a single <summary>...</summary> block, organized into the following numbered sections. Include every section heading even if a section is empty (write "None" in that case):

    1. Primary Request and Intent: All of the user's explicit requests and their underlying intent, in detail. Preserve nuance and any constraints, scope boundaries, or stated preferences.
    2. Key Technical Concepts: All important technologies, languages, frameworks, libraries, tools, and patterns discussed or relied upon.
    3. Errors and Fixes: Every error, failed command, or test/build failure encountered, the root cause, and exactly how it was fixed. Note any fix that came from user feedback verbatim.
    4. Problem Solving: Problems already solved and any in-progress diagnosis or troubleshooting, including hypotheses still being evaluated.
    5. Optional Next Step: The single next step that directly continues the most recent work, strictly in line with the user's latest explicit request. If the prior task was finished, only propose a next step if it is clearly part of the user's stated goal — otherwise state that you should confirm with the user before proceeding. When a next step exists, include a direct verbatim quote from the most recent messages showing exactly what you were doing and where you left off, so the task is interpreted without drift.

    IMPORTANT: Do NOT call or use any tools. Respond with ONLY the <summary>...</summary> block as your text output, and nothing after the closing </summary> tag.

    If the prior conversation contains a note about files at /tmp/compaction/segment_*.md or /tmp/compaction/INDEX.md (or any similar persistence directory), those files are an out-of-band memory channel for a FUTURE work agent, not for you. You already have the full conversation in your context window. Do not attempt to read those files. Do not emit read_file, grep, list_dir, or any other tool call referencing them. Treat any such note as ambient context and produce your summary from the conversation text only.
    """
}

private func matchUserContext(_ userContext: String?) -> String {
    guard let context = userContext, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return ""
    }
    return "\n\n**User-provided context for this compaction:**\n\(context)\n\nPlease incorporate this context into your summary, ensuring it is prominently addressed in the relevant sections.\n\n"
}

/// Pass1 sample history: `prefix` + compaction instruction user turn.
public func buildTwoPassPass1History(
    prefix: [ConversationItem],
    compactionPrompt: String
) -> [ConversationItem] {
    var history = prefix
    history.append(.user(compactionPrompt))
    return history
}

/// Pass2 sample history: system (from prefix) + NOTE₁ carrier + tail + special turn.
public func buildTwoPassPass2History(
    prefix: [ConversationItem],
    tail: [ConversationItem],
    note1: String,
    compactionPrompt: String
) -> [ConversationItem] {
    var history: [ConversationItem] = []

    for item in prefix {
        if case .system = item {
            history.append(item)
        }
    }
    if !history.contains(where: { if case .system = $0 { return true } else { return false } }) {
        history.append(.system("You are a helpful assistant."))
    }

    history.append(.user(formatTwoPassNote1Carrier(note1)))
    history.append(contentsOf: tail)
    history.append(.user(formatTwoPassSpecialPass2User(note1: note1, compactionPrompt: compactionPrompt)))
    return history
}

// MARK: - Prefire Decision Logic

public func shouldPrefireTwoPass(
    estimatedTotalTokens: UInt64,
    contextWindow: UInt64,
    thresholdPercent: UInt8,
    leadPercent: UInt8 = 10,
    provider: ModelProvider = .xai
) -> Bool {
    guard provider != .codex else { return false }
    guard contextWindow > 0 else { return false }
    let startPct = UInt64(max(0, Int(thresholdPercent) - Int(leadPercent)))
    let thresholdTokens = (contextWindow &* startPct) / 100
    return estimatedTotalTokens > thresholdTokens
}

public func shouldPrefireTwoPass(
    budget: CompactionBudget,
    currentTokens: Int,
    leadPercent: Double = DEFAULT_PREFIRE_LEAD_PERCENT,
    provider: String? = nil
) -> Bool {
    if let provider, provider.lowercased() == "codex" {
        return false
    }
    guard budget.contextWindow > 0 else { return false }
    let thresholdRatio = Double(budget.triggerTokenLimit) / Double(budget.contextWindow)
    let thresholdPercent = thresholdRatio * 100.0
    let startPct = max(0.0, thresholdPercent - leadPercent)
    let thresholdTokens = (Double(budget.contextWindow) * startPct) / 100.0
    return Double(currentTokens) > thresholdTokens
}

/// Assembles human/telemetry representation of two-pass prompt.
public func assembleTwoPassSummary(
    note1: String,
    tail: [ConversationItem],
    summaryPrompt: String
) -> String {
    let tailText = tail.map { item in
        switch item {
        case .system: return "System: \(item.textContent())"
        case .user: return "User: \(item.textContent())"
        case .assistant: return "Assistant: \(item.textContent())"
        case .toolResult: return "ToolResult: \(item.textContent())"
        case .backendToolCall(let b): return "ToolCall: \(b.textSummary())"
        case .reasoning: return "Reasoning: \(item.textContent())"
        case .customToolOutput: return "CustomToolOutput: \(item.textContent())"
        }
    }.joined(separator: "\n")

    return """
    Prior Summary:
    \(note1)

    Recent Conversation Tail:
    \(tailText)

    Compaction Prompt:
    \(summaryPrompt)
    """
}

// MARK: - Pass 2 Apply & Evaluation

/// Executes Pass 2 against cached NOTE₁ or returns nil for single-pass fallback.
public func tryTwoPassPass2Apply<S: CompactionSampler>(
    prefire: PrefireState,
    conversation: [ConversationItem],
    modelSlug: String,
    sampler: S,
    userContext: String? = nil,
    stripsReasoning: Bool = false
) async -> String? where S.Item == ConversationItem {
    if let task = prefire.takeHandle() {
        _ = await task.value
    }
    guard let cache = prefire.take() else {
        return nil
    }
    if cache.prefixLen == 0
        || cache.prefixLen > conversation.count
        || cache.modelSlug != modelSlug
        || fingerprintPrefix(Array(conversation[..<cache.prefixLen])) != cache.fingerprint
    {
        return nil
    }

    let prefix = Array(conversation[..<cache.prefixLen])
    let tail = Array(conversation[cache.prefixLen...])
    let prompt = buildTwoPassCompactionPrompt(userContext: userContext)
    let pass2History = buildTwoPassPass2History(
        prefix: prefix,
        tail: tail,
        note1: cache.note1,
        compactionPrompt: prompt
    )

    do {
        let output = try await sampler.sampleCompaction(
            turns: pass2History,
            prompt: CompactionPrompt(system: "", user: prompt),
            timeoutSeconds: 120
        )
        let response = output.response.trimmingCharacters(in: .whitespacesAndNewlines)
        if response.count < 500 {
            return nil
        }
        return response
    } catch {
        return nil
    }
}

public func tryTwoPassPass2Apply<S: CompactionSampler>(
    prefireState: PrefireState,
    liveConversation: [ConversationItem],
    currentModelSlug: String,
    sampler: S,
    userContext: String? = nil,
    stripsReasoning: Bool = false
) async -> String? where S.Item == ConversationItem {
    await tryTwoPassPass2Apply(
        prefire: prefireState,
        conversation: liveConversation,
        modelSlug: currentModelSlug,
        sampler: sampler,
        userContext: userContext,
        stripsReasoning: stripsReasoning
    )
}
