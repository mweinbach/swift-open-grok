// CompactionEngine.swift
//
// The call site the rest of this module was missing.
//
// `OpenGrokCompaction.swift` and `CodexCompaction.swift` port the upstream
// primitives — thresholds, turn selection, retrying sampler, history assembly,
// the Codex Remote Compaction V2 protocol — but each of them is one step of a
// sequence, and nothing in the tree ran the sequence. This file is that
// sequence: given a conversation, a budget and a way to sample, it decides
// whether to compact, compacts, and hands back a replacement history plus a
// report the UI can show.
//
// Three rules shape the design:
//
//  1. **A session must not die at the context wall.** Every failure path here
//     ends in a shorter history, never in a thrown error the turn loop cannot
//     answer. When sampling a summary fails, `boundedTruncationHistory` drops
//     the oldest turns and the report says so; the caller shows a notice.
//  2. **Codex compaction is a server protocol, not a local summary.** The
//     encrypted `compaction` item the server returns is opaque and must be
//     replayed byte-identically, so the Codex path never reformats it — it
//     goes through `CodexRemoteCompactionResult.replacementHistory`, which
//     keeps a bounded tail of real user turns and appends the item verbatim.
//  3. **Compaction is advisory until it is committed.** Selection and sampling
//     run against a snapshot; `commitCompactionReplacement` refuses to apply a
//     replacement if the live history moved underneath it. The caller is
//     expected to re-read and retry rather than clobber.

import Foundation
import OpenGrokChatState
import OpenGrokSamplingTypes
import OpenGrokTokenEstimation

// MARK: - Strategy selection

/// Which compaction protocol a session uses.
///
/// Codex is the odd one out: the server owns the summary and returns an
/// encrypted item, so "compacting" is a request, not a local sampling loop.
/// Every other provider summarizes locally.
public enum CompactionStrategy: String, Codable, Sendable, Equatable, Hashable {
    case local
    case codexRemoteV2 = "codex_remote_v2"
    case codexLegacyUnary = "codex_legacy_unary"

    /// The default strategy for a provider.
    ///
    /// `remoteV2Enabled` is the documented compatibility switch: turning it off
    /// selects the legacy unary `/responses/compact` protocol, which upstream
    /// keeps as an explicit escape hatch rather than a fallback (README.md:35-40).
    public static func forProvider(
        _ provider: ModelProvider,
        remoteV2Enabled: Bool = true
    ) -> CompactionStrategy {
        guard provider == .codex else { return .local }
        return CodexCompactionSelection(remoteV2Enabled: remoteV2Enabled).selectedProtocol == .remoteV2
            ? .codexRemoteV2
            : .codexLegacyUnary
    }

    public var codexProtocol: CodexCompactionProtocol? {
        switch self {
        case .local: return nil
        case .codexRemoteV2: return .remoteV2
        case .codexLegacyUnary: return .legacyUnary
        }
    }
}

// MARK: - Context usage

/// What a `/usage`-style readout needs to render, computed from the same
/// numbers the trigger check uses so the display can never disagree with the
/// decision.
public struct ContextUsage: Codable, Sendable, Equatable, Hashable {
    public var modelID: String
    public var usedTokens: UInt64
    public var contextWindow: UInt64
    /// The token count at which auto-compaction fires.
    public var triggerTokenLimit: UInt64
    /// The token count compaction aims to land under.
    public var targetTokenLimit: UInt64
    /// Where `triggerTokenLimit` came from: `operator`, `model` or `default`.
    public var budgetSource: String
    /// How many times this session has compacted.
    public var compactionCount: UInt64
    public var strategy: CompactionStrategy
    /// Remaining server-side compactions, when the catalog publishes a limit.
    public var compactionsRemaining: UInt64?

    public init(
        modelID: String,
        usedTokens: UInt64,
        contextWindow: UInt64,
        triggerTokenLimit: UInt64,
        targetTokenLimit: UInt64,
        budgetSource: String,
        compactionCount: UInt64 = 0,
        strategy: CompactionStrategy = .local,
        compactionsRemaining: UInt64? = nil
    ) {
        self.modelID = modelID
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
        self.triggerTokenLimit = triggerTokenLimit
        self.targetTokenLimit = targetTokenLimit
        self.budgetSource = budgetSource
        self.compactionCount = compactionCount
        self.strategy = strategy
        self.compactionsRemaining = compactionsRemaining
    }

    /// Percent of the window consumed, truncated so a readout never rounds
    /// 99.6% up to a reassuring 100 — or 0.4% up to a worrying 1.
    public var percentUsed: UInt8 {
        usagePercentageTruncatedU8(used: usedTokens, total: contextWindow)
    }

    public var remainingTokens: UInt64 {
        freeTokens(total: contextWindow, used: usedTokens)
    }

    public var willCompactOnNextTurn: Bool {
        triggerTokenLimit > 0 && usedTokens > triggerTokenLimit
    }

    /// One line, the way `/usage` prints it.
    public var summaryLine: String {
        var line = "Context: \(formatTokenCount(usedTokens))/\(formatTokenCount(contextWindow))"
            + " tokens (\(percentUsed)%)"
        line += "; auto-compact at \(formatTokenCount(triggerTokenLimit))"
        if compactionCount > 0 {
            line += "; compacted \(compactionCount)×"
        }
        if let compactionsRemaining {
            line += "; \(compactionsRemaining) server compactions left"
        }
        return line
    }

    private enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case usedTokens = "used_tokens"
        case contextWindow = "context_window"
        case triggerTokenLimit = "trigger_token_limit"
        case targetTokenLimit = "target_token_limit"
        case budgetSource = "budget_source"
        case compactionCount = "compaction_count"
        case strategy
        case compactionsRemaining = "compactions_remaining"
    }
}

/// `128000` reads as `128k`. Kept here rather than in the renderer so the CLI
/// readout and the TUI status line cannot drift.
public func formatTokenCount(_ tokens: UInt64) -> String {
    if tokens >= 1_000_000 {
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
    if tokens >= 1_000 {
        return "\(tokens / 1_000)k"
    }
    return "\(tokens)"
}

// MARK: - Reports

public enum CompactionKind: String, Codable, Sendable, Equatable, Hashable {
    case local
    case codexRemoteV2 = "codex_remote_v2"
    case codexLegacyUnary = "codex_legacy_unary"
    /// The fallback: oldest turns dropped because summarization failed.
    case truncation
}

/// What one compaction did, in the terms a user cares about.
public struct CompactionReport: Codable, Sendable, Equatable, Hashable {
    public var kind: CompactionKind
    public var itemsBefore: Int
    public var itemsAfter: Int
    public var tokensBefore: UInt64
    public var tokensAfter: UInt64
    public var attempts: UInt32
    public var summaryCharacters: UInt64
    /// True when the summary could not be produced and history was truncated
    /// instead. The session survives, but earlier context is gone rather than
    /// summarized, and the notice has to say so.
    public var degraded: Bool
    /// Why it degraded, or any other detail worth surfacing.
    public var detail: String?

    public init(
        kind: CompactionKind,
        itemsBefore: Int,
        itemsAfter: Int,
        tokensBefore: UInt64,
        tokensAfter: UInt64,
        attempts: UInt32 = 1,
        summaryCharacters: UInt64 = 0,
        degraded: Bool = false,
        detail: String? = nil
    ) {
        self.kind = kind
        self.itemsBefore = itemsBefore
        self.itemsAfter = itemsAfter
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.attempts = attempts
        self.summaryCharacters = summaryCharacters
        self.degraded = degraded
        self.detail = detail
    }

    /// The line the user sees. Deliberately reports numbers rather than an
    /// adjective — "compacted" alone leaves people unsure whether anything was
    /// lost.
    public var notice: String {
        let sizes = "\(formatTokenCount(tokensBefore)) → \(formatTokenCount(tokensAfter)) tokens"
        if degraded {
            var text = "Context trimmed to fit (\(sizes)); "
                + "the summary could not be generated, so the oldest turns were dropped."
            if let detail { text += " (\(detail))" }
            return text
        }
        switch kind {
        case .local:
            return "Compacted the conversation: \(sizes), "
                + "\(itemsBefore - itemsAfter) earlier messages replaced by a summary."
        case .codexRemoteV2:
            return "Compacted the conversation server-side (Remote Compaction V2): \(sizes)."
        case .codexLegacyUnary:
            return "Compacted the conversation server-side (legacy protocol): \(sizes)."
        case .truncation:
            return "Context trimmed to fit: \(sizes)."
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case itemsBefore = "items_before"
        case itemsAfter = "items_after"
        case tokensBefore = "tokens_before"
        case tokensAfter = "tokens_after"
        case attempts
        case summaryCharacters = "summary_chars"
        case degraded
        case detail
    }
}

public enum CompactionRunOutcome: Sendable, Equatable {
    /// Under threshold, or nothing large enough to be worth compacting.
    case notNeeded(ContextUsage)
    case compacted(items: [ConversationItem], report: CompactionReport)
    /// Neither summarization nor truncation could shrink the history. The turn
    /// should proceed and let the provider's own error surface — there is
    /// nothing left to drop.
    case unableToCompact(reason: String)
}

// MARK: - Codex transport

/// Errors a Codex compaction transport reports, classified the way the retry
/// policy needs them.
public enum CodexCompactionTransportError: Error, Sendable, Equatable, Hashable {
    case authentication(status: Int)
    case http(status: Int, message: String)
    case transport(String)
    case cancelled

    public var retryCause: CodexCompactionRetryCause {
        switch self {
        case .authentication(let status):
            return .authentication(status: status)
        case .cancelled:
            return .cancelled
        case .transport:
            return .transient
        case .http(let status, let message):
            return classifyCompactionHTTPStatus(status, message: message) == .deterministic
                ? .deterministic
                : .transient
        }
    }

    public var message: String {
        switch self {
        case .authentication(let status): return "Codex compaction rejected the credential (HTTP \(status))"
        case .http(let status, let message): return "Codex compaction failed (HTTP \(status)): \(message)"
        case .transport(let detail): return "Codex compaction transport failed: \(detail)"
        case .cancelled: return "Codex compaction was cancelled"
        }
    }
}

/// Posts a compaction request and replays the decoded stream events in order.
///
/// Kept as a protocol so the protocol logic above is testable without HTTP, and
/// so the live composition can supply a transport built from its own
/// already-authenticated client rather than this module reaching for
/// credentials.
public protocol CodexCompactionTransport: Sendable {
    func send(
        _ request: CodexCompactionRequest,
        onEvent: @Sendable (CodexCompactionStreamEvent) async throws -> Void
    ) async throws
}

/// A reference wrapper so `CodexCompactionV2Collector` — a value type by
/// design, because its state machine is worth testing without a class — can be
/// fed from a `@Sendable` event callback.
final class CodexCompactionCollectorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collector = CodexCompactionV2Collector()

    func consume(_ event: CodexCompactionStreamEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        try collector.consume(event)
    }

    func finish(attempts: UInt32, refreshedAuth: Bool) throws -> CodexRemoteCompactionResult {
        lock.lock()
        defer { lock.unlock() }
        return try collector.finish(attempts: attempts, refreshedAuth: refreshedAuth)
    }
}

/// Drive one Codex compaction to a durable item, retrying per policy.
///
/// `refreshAuth` is called at most `policy.maxAuthRefreshes` times and returns
/// whether it obtained a fresh credential; the transport is expected to pick
/// the new one up. Returning `false` ends the retry loop rather than spinning
/// on a credential that cannot be renewed.
public func runCodexRemoteCompaction(
    transport: any CodexCompactionTransport,
    request: CodexCompactionRequest,
    policy: CodexCompactionRetryPolicy = CodexCompactionRetryPolicy(),
    refreshAuth: (@Sendable () async -> Bool)? = nil
) async throws -> CodexRemoteCompactionResult {
    var attempts: UInt32 = 0
    var authRefreshes: UInt32 = 0
    var lastError: Error = CodexCompactionProtocolError.incompleteResponse

    while true {
        attempts += 1
        // The collector is a value type but the transport hands events to a
        // `@Sendable` callback, so it lives in a box rather than a captured
        // `var`. Access is serialized by the transport, which delivers events
        // one at a time and awaits each callback.
        let collector = CodexCompactionCollectorBox()
        do {
            try await transport.send(request) { event in
                try collector.consume(event)
            }
            return try collector.finish(attempts: attempts, refreshedAuth: authRefreshes > 0)
        } catch let error as CodexCompactionTransportError {
            lastError = error
            let cause = error.retryCause
            guard policy.canRetry(
                cause: cause,
                attemptsMade: attempts,
                authRefreshesUsed: authRefreshes
            ) else { throw error }
            if case .authentication = cause {
                authRefreshes += 1
                guard let refreshAuth, await refreshAuth() else { throw error }
            }
        } catch let error as CodexCompactionProtocolError {
            lastError = error
            // A stream that ended without the terminal event is a partial
            // response: retrying would re-run a server-side compaction that may
            // already have consumed one of the account's limited compactions.
            let cause: CodexCompactionRetryCause
            switch error {
            case .incompleteResponse: cause = .partialResponse
            default: cause = .deterministic
            }
            guard policy.canRetry(
                cause: cause,
                attemptsMade: attempts,
                authRefreshesUsed: authRefreshes
            ) else { throw error }
        } catch is CancellationError {
            throw CodexCompactionTransportError.cancelled
        } catch {
            lastError = error
            guard policy.canRetry(
                cause: .transient,
                attemptsMade: attempts,
                authRefreshesUsed: authRefreshes
            ) else { throw error }
        }
        if Task.isCancelled { throw CodexCompactionTransportError.cancelled }
        _ = lastError
    }
}

// MARK: - Fallback truncation

/// Drop the oldest turns until the history fits `targetTokens`, keeping the
/// system prompt and never splitting a tool call from its result.
///
/// This is the floor under every other path. It loses information that a
/// summary would have kept, which is exactly why the caller must tell the user
/// it happened — but a session that keeps running with less context beats a
/// session that cannot take another turn.
public func boundedTruncationHistory(
    items: [ConversationItem],
    targetTokens: UInt64
) -> [ConversationItem]? {
    guard !items.isEmpty else { return nil }
    let leading = Array(items.prefix { item in
        if case .system = item { return true }
        return false
    })
    let body = Array(items.dropFirst(leading.count))
    guard !body.isEmpty else { return nil }

    let leadingTokens = leading.reduce(UInt64(0)) { $0 &+ estimateItemTokens($1) }
    let budget = targetTokens > leadingTokens ? targetTokens - leadingTokens : 0
    let counts = body.map(estimateItemTokens)

    var kept: UInt64 = 0
    var split = body.count
    for index in stride(from: body.count - 1, through: 0, by: -1) {
        let next = kept &+ counts[index]
        if next > budget {
            split = index + 1
            break
        }
        kept = next
        split = index
    }
    // Always keep the newest turn even if it alone busts the budget: dropping
    // it would discard the prompt this turn is answering.
    if split >= body.count { split = body.count - 1 }
    // Never begin the retained window with an orphaned tool result.
    while split < body.count - 1, isOrphanableToolOutput(body[split]) {
        split += 1
    }
    guard split > 0 else { return nil }

    let truncated = leading + body[split...]
    let sanitized = sanitizeCompactedHistory(truncated).items
    guard sanitized.count < items.count else { return nil }
    return sanitized
}

private func isOrphanableToolOutput(_ item: ConversationItem) -> Bool {
    switch item {
    case .toolResult, .customToolOutput: return true
    default: return false
    }
}

// MARK: - Engine

public struct CompactionEngineConfiguration: Sendable {
    public var policy: CompactionPolicy
    public var budget: CompactionBudget
    public var strategy: CompactionStrategy
    public var modelID: String
    /// Retained real-user tail for the Codex V2 replacement history.
    public var codexRetainedUserTokenBudget: UInt64
    /// The catalog's `comp_hash`, replayed on the Codex request so the server
    /// can reject a compaction built against a stale contract.
    public var compactionHash: String?
    /// Remaining server-side compactions, when the catalog publishes a limit.
    /// Zero refuses the remote path and falls through to truncation rather than
    /// spending a call that will be rejected.
    public var compactionsRemaining: UInt64?
    /// The session's service tier, replayed on the Codex compaction request.
    /// Upstream deliberately KEEPS `service_tier` in the compact body — the
    /// retain lists allow it (client.rs:668-692, :694-728) and
    /// `codex_remote_compaction_v2_body_keeps_stream_contract_fields`
    /// (client.rs:3827-3858) pins `"service_tier": "priority"` surviving — so
    /// a Fast session's server-side compaction rides the same priority lane
    /// as its sampling. `nil` omits the field (standard routing).
    public var serviceTier: String?
    /// Disable to make a failed summary fatal instead of degrading. Off only in
    /// tests that assert the failure classification itself.
    public var truncationFallbackEnabled: Bool

    public init(
        policy: CompactionPolicy = CompactionPolicy(),
        budget: CompactionBudget,
        strategy: CompactionStrategy = .local,
        modelID: String = "",
        codexRetainedUserTokenBudget: UInt64 = CODEX_REMOTE_COMPACTION_V2_RETAINED_USER_TOKENS,
        compactionHash: String? = nil,
        compactionsRemaining: UInt64? = nil,
        serviceTier: String? = nil,
        truncationFallbackEnabled: Bool = true
    ) {
        self.policy = policy
        self.budget = budget
        self.strategy = strategy
        self.modelID = modelID
        self.codexRetainedUserTokenBudget = codexRetainedUserTokenBudget
        self.compactionHash = compactionHash
        self.compactionsRemaining = compactionsRemaining
        self.serviceTier = serviceTier
        self.truncationFallbackEnabled = truncationFallbackEnabled
    }
}

/// Runs one compaction end to end.
///
/// Stateless: the caller owns the history and the compaction counter, so the
/// same engine serves the auto path in the turn loop and the manual `/compact`
/// command without either needing to know about the other.
public struct CompactionEngine<Sampler: CompactionSampler>: Sendable
where Sampler.Item == ConversationItem {
    public let configuration: CompactionEngineConfiguration
    public let sampler: Sampler
    public let codexTransport: (any CodexCompactionTransport)?
    /// Called after a Codex auth rejection; returns whether a fresh credential
    /// was obtained.
    public let refreshCodexAuth: (@Sendable () async -> Bool)?

    public init(
        configuration: CompactionEngineConfiguration,
        sampler: Sampler,
        codexTransport: (any CodexCompactionTransport)? = nil,
        refreshCodexAuth: (@Sendable () async -> Bool)? = nil
    ) {
        self.configuration = configuration
        self.sampler = sampler
        self.codexTransport = codexTransport
        self.refreshCodexAuth = refreshCodexAuth
    }

    public func usage(
        items: [ConversationItem],
        compactionCount: UInt64 = 0
    ) -> ContextUsage {
        ContextUsage(
            modelID: configuration.modelID,
            usedTokens: estimateTotalTokens(items),
            contextWindow: configuration.budget.contextWindow,
            triggerTokenLimit: configuration.budget.triggerTokenLimit,
            targetTokenLimit: configuration.budget.targetTokenLimit,
            budgetSource: configuration.budget.source,
            compactionCount: compactionCount,
            strategy: configuration.strategy,
            compactionsRemaining: configuration.compactionsRemaining
        )
    }

    /// Would the next turn trip the threshold?
    public func trigger(items: [ConversationItem], step: UInt32) -> CompactionTrigger? {
        let used = estimateTotalTokens(items)
        let window = configuration.budget.contextWindow
        // `shouldCompact` takes a percentage, but the budget may have been
        // pinned to an operator or model token limit that is not a clean
        // percentage of the window. Deriving the percentage back out truncates,
        // so the percentage check is kept for its policy gates (enabled, mode,
        // minimum step) and the token limit is enforced exactly alongside it.
        var policy = configuration.policy
        if window > 0 {
            let percent = (configuration.budget.triggerTokenLimit &* 100) / window
            policy.triggerThresholdPercent = UInt8(min(UInt64(100), max(1, percent)))
        }
        guard let trigger = shouldCompact(
            policy: policy,
            lastPromptTokens: used,
            contextWindow: window,
            currentStep: step
        ) else { return nil }
        guard used > configuration.budget.triggerTokenLimit else { return nil }
        return trigger
    }

    /// Compact `items` if the threshold says so.
    public func compactIfNeeded(
        items: [ConversationItem],
        step: UInt32,
        compactionCount: UInt64 = 0
    ) async -> CompactionRunOutcome {
        guard trigger(items: items, step: step) != nil else {
            return .notNeeded(usage(items: items, compactionCount: compactionCount))
        }
        return await compact(items: items, compactionCount: compactionCount)
    }

    /// Compact unconditionally. This is what `/compact` calls.
    public func compact(
        items: [ConversationItem],
        userContext: String? = nil,
        compactionCount: UInt64 = 0
    ) async -> CompactionRunOutcome {
        let tokensBefore = estimateTotalTokens(items)
        switch configuration.strategy {
        case .local:
            return await compactLocally(
                items: items,
                userContext: userContext,
                tokensBefore: tokensBefore
            )
        case .codexRemoteV2, .codexLegacyUnary:
            return await compactViaCodex(items: items, tokensBefore: tokensBefore)
        }
    }

    // MARK: Local

    private func compactLocally(
        items: [ConversationItem],
        userContext: String?,
        tokensBefore: UInt64
    ) async -> CompactionRunOutcome {
        guard let selection = selectTurnsToCompact(
            items: items,
            targetTokens: configuration.budget.targetTokenLimit,
            minCompactableTokens: configuration.policy.minCompactableTokens
        ) else {
            // Nothing old enough or large enough to summarize. If we are over
            // the wall anyway, truncation is the only move left.
            return degrade(
                items: items,
                tokensBefore: tokensBefore,
                detail: "no compactable prefix"
            )
        }

        let older = Array(items[..<selection.splitIndex])
        let retained = Array(items[selection.splitIndex...])
        let turnsForSummary = filterTurnsForBasic(older)
        guard !turnsForSummary.isEmpty else {
            return degrade(items: items, tokensBefore: tokensBefore, detail: "no summarizable turns")
        }

        let summary: CompactionRetrySuccess
        do {
            summary = try await sampleCompactionWithRetries(
                sampler: sampler,
                turns: turnsForSummary,
                prompt: CompactionPrompt(user: buildSummaryPrompt(userContext: userContext)),
                maxAttempts: configuration.policy.maxAttempts,
                retryDelayMilliseconds: configuration.policy.retryDelayMilliseconds,
                timeoutSeconds: configuration.policy.samplingTimeoutSeconds
            )
        } catch let failure as CompactionRetryFailure {
            return degrade(
                items: items,
                tokensBefore: tokensBefore,
                detail: compactionFailureDetail(failure)
            )
        } catch {
            return degrade(
                items: items,
                tokensBefore: tokensBefore,
                detail: String(describing: error)
            )
        }

        // The preamble carries every real user query from the compacted span —
        // including ones a *previous* compaction already folded in — so the
        // model keeps the full record of what was asked even though the turns
        // themselves are gone.
        let preamble = buildUserQueriesPreamble(
            turns: older,
            currentUserQueries: extractUserQueriesFromTurns(older)
        )
        let replacement = assembleCompactedHistory(CompactedHistoryParts(
            systemMessage: systemMessage(in: items),
            userMessagePrefix: preamble,
            lastUserQuery: extractLastRealUserQuery(older),
            recentMessages: retained,
            compactionSummary: summary.summary
        ))
        let sanitized = sanitizeCompactedHistory(replacement).items
        let tokensAfter = estimateTotalTokens(sanitized)

        // Upstream refuses a "compaction" that barely shrank anything — it
        // spent a sample and a wall-clock stall for nothing, and the next turn
        // would trip the threshold again immediately.
        guard compactionMeetsReductionGuard(
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            maxReductionRatio: configuration.policy.maxReductionRatio
        ) else {
            return degrade(
                items: items,
                tokensBefore: tokensBefore,
                detail: "summary did not reduce the context enough"
            )
        }

        return .compacted(
            items: sanitized,
            report: CompactionReport(
                kind: .local,
                itemsBefore: items.count,
                itemsAfter: sanitized.count,
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter,
                attempts: summary.attempts,
                summaryCharacters: UInt64(summary.summary.count)
            )
        )
    }

    // MARK: Codex

    private func compactViaCodex(
        items: [ConversationItem],
        tokensBefore: UInt64
    ) async -> CompactionRunOutcome {
        guard let codexProtocol = configuration.strategy.codexProtocol else {
            return degrade(items: items, tokensBefore: tokensBefore, detail: "no Codex protocol")
        }
        guard let codexTransport else {
            return degrade(items: items, tokensBefore: tokensBefore, detail: "no Codex transport configured")
        }
        if let remaining = configuration.compactionsRemaining, remaining == 0 {
            return degrade(
                items: items,
                tokensBefore: tokensBefore,
                detail: "this account has no server compactions left"
            )
        }

        let request = CodexCompactionRequest(
            protocolVersion: codexProtocol,
            input: items,
            compactionHash: configuration.compactionHash,
            serviceTier: configuration.serviceTier
        )
        let result: CodexRemoteCompactionResult
        do {
            result = try await runCodexRemoteCompaction(
                transport: codexTransport,
                request: request,
                refreshAuth: refreshCodexAuth
            )
        } catch let error as CodexCompactionTransportError {
            return degrade(items: items, tokensBefore: tokensBefore, detail: error.message)
        } catch {
            return degrade(items: items, tokensBefore: tokensBefore, detail: String(describing: error))
        }

        // The encrypted item is replayed exactly as received; only the retained
        // user tail around it is ours to choose.
        let replacement = result.replacementHistory(
            promptInput: items,
            retainedUserTokenBudget: configuration.codexRetainedUserTokenBudget
        )
        guard !replacement.isEmpty else {
            return degrade(
                items: items,
                tokensBefore: tokensBefore,
                detail: "Codex returned an empty replacement history"
            )
        }
        let tokensAfter = estimateTotalTokens(replacement)
        return .compacted(
            items: replacement,
            report: CompactionReport(
                kind: codexProtocol == .remoteV2 ? .codexRemoteV2 : .codexLegacyUnary,
                itemsBefore: items.count,
                itemsAfter: replacement.count,
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter,
                attempts: result.attempts
            )
        )
    }

    // MARK: Fallback

    private func degrade(
        items: [ConversationItem],
        tokensBefore: UInt64,
        detail: String
    ) -> CompactionRunOutcome {
        guard configuration.truncationFallbackEnabled else {
            return .unableToCompact(reason: detail)
        }
        guard let truncated = boundedTruncationHistory(
            items: items,
            targetTokens: configuration.budget.targetTokenLimit
        ) else {
            return .unableToCompact(reason: detail)
        }
        return .compacted(
            items: truncated,
            report: CompactionReport(
                kind: .truncation,
                itemsBefore: items.count,
                itemsAfter: truncated.count,
                tokensBefore: tokensBefore,
                tokensAfter: estimateTotalTokens(truncated),
                degraded: true,
                detail: detail
            )
        )
    }

    private func systemMessage(in items: [ConversationItem]) -> ConversationItem {
        for item in items {
            if case .system = item { return item }
        }
        return .system("")
    }
}

private func compactionFailureDetail(_ failure: CompactionRetryFailure) -> String {
    switch failure {
    case .empty(let attempts):
        return "the summary model returned nothing usable after \(attempts) attempt(s)"
    case .failure(let message, _, let contextOverflow, _):
        return contextOverflow
            ? "the conversation is too large to summarize in one request"
            : message
    }
}

private func estimateTotalTokens(_ items: [ConversationItem]) -> UInt64 {
    items.reduce(UInt64(0)) { $0 &+ estimateItemTokens($1) }
}
