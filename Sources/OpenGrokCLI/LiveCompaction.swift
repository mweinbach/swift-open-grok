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
import OpenGrokCompaction
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes

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
            return .notNeeded(engine.usage(items: items, compactionCount: compactionCount))
        }
        await willCompact?()
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
            return .compacted(items: replacement, report: report)
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
