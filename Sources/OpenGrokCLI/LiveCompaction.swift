// LiveCompaction.swift
//
// Compaction, wired into the live session.
//
// `OpenGrokCompaction` was a complete, tested library with no call sites: a
// long session ran until the provider rejected the prompt for length and then
// died, with no warning beforehand and no recovery afterwards. This file is the
// bridge — it resolves the active model's context budget, decides which
// protocol that model's provider uses, runs the engine, and hands back a report
// the turn loop can show the user.
//
// Two seams matter here:
//
//  * **Auto-compaction operates on the in-flight turn's items**, not on the
//    persisted record. The turn loop builds `items` (stored history + this
//    prompt + system message) before its first sample, and that array is what
//    has to fit — compacting the store instead would leave the very prompt that
//    tipped the session over the wall still outside the compaction.
//  * **Manual `/compact` operates on the persisted record**, because it runs
//    between turns when no in-flight array exists.
//
// Both go through the same engine, so a manual compaction and an automatic one
// cannot produce differently shaped histories.

import Foundation
import OpenGrokChatState
import OpenGrokCompaction
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokTokenEstimation

/// Adapts the live sampler to the compaction module's sampler protocol.
///
/// A compaction sample is a plain completion: no tools, no streaming to the
/// pane, one prompt over the turns being summarized. Errors are mapped into
/// `CompactionSampleError` so the retry loop can tell a 400 (stop) from a 503
/// (retry) rather than treating everything as transient.
struct LiveCompactionSampler: CompactionSampler, Sendable {
    typealias Item = ConversationItem

    let sampler: OpenGrokLiveSampler
    let model: String
    let sessionID: String

    func sampleCompaction(
        turns: [ConversationItem],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        // Assembled into a `var` and then frozen: the sampling closure below is
        // sendable and cannot capture a mutable local.
        let items: [ConversationItem] = {
            var assembled: [ConversationItem] = []
            if !prompt.system.isEmpty {
                assembled.append(.system(prompt.system))
            }
            assembled.append(contentsOf: turns)
            assembled.append(.user(prompt.user))
            return assembled
        }()

        do {
            let response = try await withCompactionTimeout(seconds: timeoutSeconds) {
                try await sampler.sample(OpenGrokLiveSamplingRequest(
                    sessionID: sessionID,
                    turnID: "compaction-\(UUID().uuidString)",
                    model: model,
                    prompt: prompt.user,
                    items: items,
                    tools: []
                )) { _ in
                    // Compaction output is not the user's answer; it must not
                    // reach the transcript as assistant text.
                }
            }
            return LLMCompactionOutput(response: response.output)
        } catch is CancellationError {
            throw CompactionSampleError.cancelled
        } catch let error as CompactionSampleError {
            throw error
        } catch {
            throw CompactionSampleError.other(String(describing: error))
        }
    }
}

/// Run `body`, failing with a compaction timeout rather than hanging the turn.
///
/// A compaction that never returns is worse than one that fails: the user is
/// already at the context wall and blocked on this call, so an unbounded wait
/// reads as a hang with no explanation.
private func withCompactionTimeout<T: Sendable>(
    seconds: UInt64,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard seconds > 0 else { return try await body() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds &* 1_000_000_000)
            throw CompactionSampleError.timeout(timeoutSeconds: seconds, collectedBytes: 0)
        }
        guard let first = try await group.next() else {
            throw CompactionSampleError.emptyResponse
        }
        group.cancelAll()
        return first
    }
}

/// Everything about the active model that compaction depends on, resolved from
/// the embedded catalog plus, for Codex, the on-disk catalog cache.
struct LiveCompactionContract: Sendable, Equatable {
    var contextWindow: UInt64
    var thresholdPercent: UInt8
    var explicitTokenLimit: UInt64?
    /// `comp_hash` — the contract token the Codex server validates a compaction
    /// request against.
    var compactionHash: String?
    /// Server-side compactions left, when the catalog publishes a limit. Zero
    /// means the remote path will be refused, so the engine skips straight to
    /// the local fallback rather than spending a rejected call.
    var compactionsRemaining: UInt64?

    var budget: CompactionBudget {
        resolveCompactionBudget(
            contextWindow: contextWindow,
            defaultThresholdPercent: thresholdPercent,
            explicitTokenLimit: explicitTokenLimit
        )
    }

    /// Resolve from the embedded model catalog, matching the wire model name
    /// the sampler is actually sending.
    static func resolve(
        model: String,
        provider: ModelProvider,
        openGrokHome: URL,
        hasCompactionSummary: Bool = false
    ) -> LiveCompactionContract {
        let profile = embeddedDefaultModels().models.first {
            $0.model == model || ($0.id ?? $0.model) == model
        }
        let contextWindow = profile?.contextWindow ?? NEW_MODEL_DEFAULT_CONTEXT_WINDOW
        let threshold = profile?.autoCompactThresholdPercent ?? DEFAULT_AUTO_COMPACT_THRESHOLD_PERCENT
        let explicit = profile?.compactionAtTokens?.resolve(
            contextWindow: contextWindow,
            thresholdPercent: threshold
        )
        let remaining = profile?.compactionsRemaining?
            .resolve(hasCompactionSummary: hasCompactionSummary)
            .map(UInt64.init)

        var compactionHash: String?
        if provider == .codex {
            // The cached Codex catalog is the only place `comp_hash` lives. It
            // is read without verifying the account fingerprint on purpose: a
            // hash from another account is rejected server-side, which degrades
            // this compaction to the local fallback — strictly better than
            // sending no hash at all and having the server reject the request
            // for a missing contract.
            compactionHash = CodexModelsCacheManager(grokHome: openGrokHome)
                .loadAny()?
                .models
                .first { $0.entry.info.model == model || $0.entry.info.id == model }?
                .compHash
        }

        return LiveCompactionContract(
            contextWindow: contextWindow,
            thresholdPercent: threshold,
            explicitTokenLimit: explicit,
            compactionHash: compactionHash,
            compactionsRemaining: remaining
        )
    }
}

/// What a compaction attempt produced, in the terms the turn loop needs.
enum LiveCompactionResult: Sendable, Equatable {
    case notNeeded(ContextUsage)
    case compacted(items: [ConversationItem], report: CompactionReport)
    /// Nothing could be dropped. The turn proceeds; the provider's own error is
    /// the honest thing to surface at that point.
    case unableToCompact(reason: String)
}

/// Owns compaction for one live session.
///
/// An actor because the compaction counter and the step counter are read by the
/// turn loop and by `/compact` from different tasks, and a manual compaction
/// racing an automatic one must not double-apply.
actor LiveCompactionCoordinator {
    private let history: LiveConversationHistory
    private let modelSwitch: LiveModelSwitchCoordinator
    private var sessionID: String
    private let openGrokHome: URL
    /// Injection seam: production builds an HTTP transport from the live
    /// credential; tests supply a scripted one.
    private let makeCodexTransport: @Sendable (OpenGrokLiveSamplingConfiguration) -> (any CodexCompactionTransport)?
    /// Off switches Codex sessions to the legacy unary `/responses/compact`
    /// protocol, which upstream documents as the compatibility option.
    private let codexRemoteV2Enabled: Bool

    private let prefire = PrefireState()
    private var compactionCount: UInt64 = 0
    private var step: UInt32 = 0
    private var lastReport: CompactionReport?
    /// Set when a compaction attempt gets nowhere, so the remaining samples in
    /// a turn do not each pay for another failed summary.
    ///
    /// Without this, a session that is over the wall with nothing left to drop
    /// re-runs the whole compaction — including its LLM call — before every
    /// tool round, turning one failure into a stall that costs money. Cleared
    /// by the next successful compaction or a manual `/compact`, both of which
    /// are evidence the situation changed.
    private var autoCompactSuppressed = false

    init(
        history: LiveConversationHistory,
        modelSwitch: LiveModelSwitchCoordinator,
        sessionID: String,
        openGrokHome: URL,
        codexRemoteV2Enabled: Bool = true,
        makeCodexTransport: @escaping @Sendable (OpenGrokLiveSamplingConfiguration) -> (any CodexCompactionTransport)? = {
            configuration in
            guard configuration.provider == .codex else { return nil }
            var headers = configuration.extraHeaders
            headers["Authorization"] = "Bearer \(configuration.apiKey)"
            return HTTPCodexCompactionTransport(
                transport: URLSessionHTTPTransport(),
                baseURL: configuration.baseURL,
                model: configuration.model,
                headers: headers
            )
        }
    ) {
        self.history = history
        self.modelSwitch = modelSwitch
        self.sessionID = sessionID
        self.openGrokHome = openGrokHome
        self.codexRemoteV2Enabled = codexRemoteV2Enabled
        self.makeCodexTransport = makeCodexTransport
    }

    func replaceSessionID(_ sessionID: String) {
        self.sessionID = sessionID
        compactionCount = 0
        step = 0
        lastReport = nil
        autoCompactSuppressed = false
        prefire.clear()
    }

    /// Accessor for prefire state (testing and inspection).
    var prefireState: PrefireState { prefire }

    /// Speculatively prefire Pass 1 in background if token usage is within lead percentage.
    func maybePrefire(items: [ConversationItem]) async {
        guard !autoCompactSuppressed else { return }
        guard !prefire.hasCache && !prefire.isInFlight else { return }
        guard items.count >= 4 else { return }
        let snapshot = await modelSwitch.snapshot()
        guard snapshot.provider != .codex else { return }

        let contract = LiveCompactionContract.resolve(
            model: snapshot.modelID,
            provider: snapshot.provider,
            openGrokHome: openGrokHome,
            hasCompactionSummary: compactionCount > 0
        )
        let totalTokens = items.map(estimateItemTokens).reduce(0, &+)
        guard shouldPrefireTwoPass(
            estimatedTotalTokens: totalTokens,
            contextWindow: contract.budget.contextWindow,
            thresholdPercent: contract.thresholdPercent,
            leadPercent: 10,
            provider: snapshot.provider
        ) else { return }

        guard prefire.tryBegin() else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPrefirePass1(items: items, snapshot: snapshot)
        }
        prefire.setHandle(task)
    }

    func runPrefirePass1(
        items: [ConversationItem],
        snapshot: LiveModelSwitchCoordinator.Snapshot
    ) async {
        defer { prefire.finish() }
        guard items.count >= 4 else { return }
        let split = splitConversationForTwoPass(items, splitFraction: TWO_PASS_DEFAULT_SPLIT_FRACTION)
        guard !split.prefix.isEmpty && !split.tail.isEmpty else { return }

        let prompt = buildTwoPassCompactionPrompt(userContext: nil)
        let pass1History = buildTwoPassPass1History(prefix: split.prefix, compactionPrompt: prompt)
        let sampler = LiveCompactionSampler(
            sampler: snapshot.sampler,
            model: snapshot.modelID,
            sessionID: sessionID
        )
        let startTime = Date()
        do {
            let output = try await sampler.sampleCompaction(
                turns: pass1History,
                prompt: CompactionPrompt(system: "", user: prompt),
                timeoutSeconds: 60
            )
            let note1 = noteForTwoPassPass2(output.response)
            guard !note1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let latencyMs = UInt64(Date().timeIntervalSince(startTime) * 1000)
            let cache = AsyncCompactionCache(
                note1: note1,
                prefixLen: split.splitIndex,
                fingerprint: fingerprintPrefix(split.prefix),
                modelSlug: snapshot.modelID,
                pass1LatencyMs: latencyMs,
                timestamp: Date()
            )
            prefire.store(cache)
        } catch {
            // Speculative background task failed — no-op
        }
    }

    /// The data a `/usage` or `/context` readout renders.
    func usage(items: [ConversationItem]? = nil) async -> ContextUsage {
        let snapshot = await modelSwitch.snapshot()
        let engine = makeEngine(snapshot: snapshot, items: items ?? [])
        // `??` takes its right side as an autoclosure, which cannot be async.
        let subject: [ConversationItem]
        if let items {
            subject = items
        } else {
            subject = await history.items
        }
        return engine.usage(items: subject, compactionCount: compactionCount)
    }

    /// The most recent compaction, for a readout that wants to say what
    /// happened rather than only where the session stands.
    func mostRecentReport() -> CompactionReport? { lastReport }

    /// The automatic path, called by the turn loop before each sample.
    ///
    /// `willCompact` fires only once the threshold check has already said yes,
    /// which is why the decision is taken here rather than left inside
    /// `engine.compactIfNeeded`. The check runs before *every* sample and almost
    /// always comes back under the threshold, so a callback fired on entry would
    /// put "Compacting…" on the status bar for work that is not happening — and
    /// a status line that lies about what the session is doing is worse than no
    /// status line at all.
    func compactIfNeeded(
        items: [ConversationItem],
        willCompact: (@Sendable () async -> Void)? = nil
    ) async -> LiveCompactionResult {
        step &+= 1
        if autoCompactSuppressed {
            return .unableToCompact(reason: "compaction is suppressed after an earlier failure")
        }
        let snapshot = await modelSwitch.snapshot()
        let engine = makeEngine(snapshot: snapshot, items: items)
        guard engine.trigger(items: items, step: step) != nil else {
            await maybePrefire(items: items)
            return .notNeeded(engine.usage(items: items, compactionCount: compactionCount))
        }
        await willCompact?()

        // 1. Try Two-Pass Prefire Pass 2 Apply
        if prefire.hasCache || prefire.isInFlight {
            let sampler = LiveCompactionSampler(
                sampler: snapshot.sampler,
                model: snapshot.modelID,
                sessionID: sessionID
            )
            if let summaryText = await tryTwoPassPass2Apply(
                prefire: prefire,
                conversation: items,
                modelSlug: snapshot.modelID,
                sampler: sampler,
                userContext: nil
            ) {
                let tokensBefore = items.map(estimateItemTokens).reduce(0, &+)
                let split = splitConversationForTwoPass(items, splitFraction: TWO_PASS_DEFAULT_SPLIT_FRACTION)
                let older = split.prefix
                let retained = split.tail
                let preamble = buildUserQueriesPreamble(
                    turns: older,
                    currentUserQueries: extractUserQueriesFromTurns(older)
                )
                let replacement = assembleCompactedHistory(CompactedHistoryParts(
                    systemMessage: systemMessage(in: items),
                    userMessagePrefix: preamble,
                    lastUserQuery: extractLastRealUserQuery(older),
                    recentMessages: retained,
                    compactionSummary: summaryText
                ))
                let sanitized = sanitizeCompactedHistory(replacement).items
                let tokensAfter = sanitized.map(estimateItemTokens).reduce(0, &+)
                let report = CompactionReport(
                    kind: .local,
                    itemsBefore: items.count,
                    itemsAfter: sanitized.count,
                    tokensBefore: tokensBefore,
                    tokensAfter: tokensAfter,
                    attempts: 1,
                    summaryCharacters: UInt64(summaryText.count),
                    degraded: false,
                    detail: nil
                )

                guard commitCompactionReplacement(
                    snapshot: items,
                    current: items,
                    replacement: sanitized
                ) == .applied else {
                    autoCompactSuppressed = true
                    return .unableToCompact(reason: "history changed during compaction")
                }
                compactionCount &+= 1
                lastReport = report
                recordCompactionCheckpoint(preCompactionItems: items, replacement: sanitized)
                return .compacted(items: sanitized, report: report)
            }
        }

        // 2. Fallback to standard single-pass compaction
        switch await engine.compact(items: items, compactionCount: compactionCount) {
        case .notNeeded(let usage):
            return .notNeeded(usage)
        case .unableToCompact(let reason):
            autoCompactSuppressed = true
            return .unableToCompact(reason: reason)
        case .compacted(let replacement, let report):
            // Refuse a replacement built against a history that moved. The
            // in-flight array is owned by one turn, so this only fires if a
            // future caller shares it — but the guard costs nothing and the
            // failure it prevents is silent history loss.
            guard commitCompactionReplacement(
                snapshot: items,
                current: items,
                replacement: replacement
            ) == .applied else {
                autoCompactSuppressed = true
                return .unableToCompact(reason: "history changed during compaction")
            }
            compactionCount &+= 1
            lastReport = report
            recordCompactionCheckpoint(preCompactionItems: items, replacement: replacement)
            return .compacted(items: replacement, report: report)
        }
    }

    /// The manual path — what `/compact` calls. Operates on the persisted
    /// conversation and writes the replacement back.
    func compactNow(userContext: String? = nil) async -> LiveCompactionResult {
        // An explicit request clears the suppression: the user asking again is
        // evidence they think the situation changed, and refusing them because
        // an earlier automatic attempt failed would be unexplainable.
        autoCompactSuppressed = false
        let items = await history.items
        guard !items.isEmpty else {
            return .unableToCompact(reason: "there is nothing to compact yet")
        }
        let snapshot = await modelSwitch.snapshot()

        // 1. Try Two-Pass Prefire Pass 2 Apply if available
        if prefire.hasCache || prefire.isInFlight {
            let sampler = LiveCompactionSampler(
                sampler: snapshot.sampler,
                model: snapshot.modelID,
                sessionID: sessionID
            )
            if let summaryText = await tryTwoPassPass2Apply(
                prefire: prefire,
                conversation: items,
                modelSlug: snapshot.modelID,
                sampler: sampler,
                userContext: userContext
            ) {
                let tokensBefore = items.map(estimateItemTokens).reduce(0, &+)
                let split = splitConversationForTwoPass(items, splitFraction: TWO_PASS_DEFAULT_SPLIT_FRACTION)
                let older = split.prefix
                let retained = split.tail
                let preamble = buildUserQueriesPreamble(
                    turns: older,
                    currentUserQueries: extractUserQueriesFromTurns(older)
                )
                let replacement = assembleCompactedHistory(CompactedHistoryParts(
                    systemMessage: systemMessage(in: items),
                    userMessagePrefix: preamble,
                    lastUserQuery: extractLastRealUserQuery(older),
                    recentMessages: retained,
                    compactionSummary: summaryText
                ))
                let sanitized = sanitizeCompactedHistory(replacement).items
                let tokensAfter = sanitized.map(estimateItemTokens).reduce(0, &+)
                let report = CompactionReport(
                    kind: .local,
                    itemsBefore: items.count,
                    itemsAfter: sanitized.count,
                    tokensBefore: tokensBefore,
                    tokensAfter: tokensAfter,
                    attempts: 1,
                    summaryCharacters: UInt64(summaryText.count),
                    degraded: false,
                    detail: nil
                )

                let current = await history.items
                guard commitCompactionReplacement(
                    snapshot: items,
                    current: current,
                    replacement: sanitized
                ) == .applied else {
                    return .unableToCompact(reason: "the conversation changed during compaction")
                }
                do {
                    try await history.commit(sessionID: sessionID, items: sanitized)
                } catch {
                    return .unableToCompact(reason: String(describing: error))
                }
                compactionCount &+= 1
                lastReport = report
                recordCompactionCheckpoint(preCompactionItems: items, replacement: sanitized)
                return .compacted(items: sanitized, report: report)
            }
        }

        // 2. Fallback to standard single-pass compaction
        let engine = makeEngine(snapshot: snapshot, items: items)
        switch await engine.compact(
            items: items,
            userContext: userContext,
            compactionCount: compactionCount
        ) {
        case .notNeeded(let usage):
            return .notNeeded(usage)
        case .unableToCompact(let reason):
            return .unableToCompact(reason: reason)
        case .compacted(let replacement, let report):
            let current = await history.items
            guard commitCompactionReplacement(
                snapshot: items,
                current: current,
                replacement: replacement
            ) == .applied else {
                return .unableToCompact(reason: "the conversation changed during compaction")
            }
            do {
                try await history.commit(sessionID: sessionID, items: replacement)
            } catch {
                return .unableToCompact(reason: String(describing: error))
            }
            compactionCount &+= 1
            lastReport = report
            recordCompactionCheckpoint(preCompactionItems: items, replacement: replacement)
            return .compacted(items: replacement, report: report)
        }
    }

    private func systemMessage(in items: [ConversationItem]) -> ConversationItem {
        items.first(where: { if case .system = $0 { return true } else { return false } }) ?? .system("You are Open Grok.")
    }

    private func recordCompactionCheckpoint(
        preCompactionItems: [ConversationItem],
        replacement: [ConversationItem]
    ) {
        let originalUserInfo: String? = {
            if preCompactionItems.count > 1, case .user = preCompactionItems[1] {
                return preCompactionItems[1].textContent()
            }
            if let firstUser = preCompactionItems.first(where: { if case .user = $0 { return true } else { return false } }) {
                return firstUser.textContent()
            }
            return nil
        }()

        var promptIndexAtCompaction = 0
        for item in preCompactionItems {
            if case .user(let u) = item {
                let startsTurn = u.syntheticReason.map(\.startsPromptTurn) ?? true
                if startsTurn { promptIndexAtCompaction += 1 }
            }
        }

        let sessionDir = openGrokHome.appendingPathComponent("sessions").appendingPathComponent(sessionID)
        guard let info = try? persistCompactionCheckpoint(
            sessionDir: sessionDir,
            promptIndex: promptIndexAtCompaction,
            compactedHistory: replacement,
            autoContinue: nil,
            originalUserInfo: originalUserInfo
        ) else { return }

        let updateRecord = SessionUpdateRecord.checkpoint(
            id: info.checkpointID,
            promptIndex: info.promptIndexAtCompaction,
            autoContinueText: nil
        )
        if let data = try? JSONEncoder().encode(updateRecord),
           let line = String(data: data, encoding: .utf8) {
            let updatesURL = sessionDir.appendingPathComponent("updates.jsonl")
            if let handle = try? FileHandle(forWritingTo: updatesURL) {
                handle.seekToEndOfFile()
                if let lineData = (line + "\n").data(using: .utf8) {
                    handle.write(lineData)
                }
                try? handle.close()
            } else {
                try? (line + "\n").write(to: updatesURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private func makeEngine(
        snapshot: LiveModelSwitchCoordinator.Snapshot,
        items: [ConversationItem]
    ) -> CompactionEngine<LiveCompactionSampler> {
        let contract = LiveCompactionContract.resolve(
            model: snapshot.modelID,
            provider: snapshot.provider,
            openGrokHome: openGrokHome,
            hasCompactionSummary: compactionCount > 0
        )
        var policy = CompactionPolicy()
        policy.enabled = true
        policy.mode = .fullReplace
        policy.triggerThresholdPercent = contract.thresholdPercent
        let configuration = CompactionEngineConfiguration(
            policy: policy,
            budget: contract.budget,
            strategy: CompactionStrategy.forProvider(
                snapshot.provider,
                remoteV2Enabled: codexRemoteV2Enabled
            ),
            modelID: snapshot.modelID,
            compactionHash: contract.compactionHash,
            compactionsRemaining: contract.compactionsRemaining,
            // The session tier rides compaction too — upstream keeps
            // `service_tier` in the Codex compact body (client.rs:668-692;
            // its test at :3827-3858 pins `"priority"` surviving), and the
            // local summarize path inherits it through the same sampler
            // defaults as inference (client.rs:1806-1808). A Fast session's
            // compaction is deliberately NOT excluded from priority routing.
            serviceTier: snapshot.configuration.serviceTier
        )
        return CompactionEngine(
            configuration: configuration,
            sampler: LiveCompactionSampler(
                sampler: snapshot.sampler,
                model: snapshot.modelID,
                sessionID: sessionID
            ),
            codexTransport: makeCodexTransport(snapshot.configuration)
        )
    }
}
