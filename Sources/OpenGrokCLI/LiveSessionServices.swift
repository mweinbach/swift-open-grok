// LiveSessionServices.swift
//
// One seam for the three session-recovery subsystems that need to reach into
// the turn loop: rewind snapshots, memory, and goals.
//
// They are bundled rather than plumbed separately because they all attach to
// the same two places — `LiveToolExecutor` (they add tools and observe tool
// calls) and the turn driver (they observe prompt boundaries) — and threading
// three optionals through both would triple the surface `LiveComposition.swift`
// has to carry for no gain. One optional field, one dispatch branch.
//
// Every member is optional and the whole aggregate is optional, so a session
// that opts into none of this behaves exactly as it did before: no tools are
// advertised, no snapshots are taken, and nothing is written to disk.

import Foundation
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokProviderSession
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTokenEstimation

/// Rewind, memory and goals for one live session.
struct LiveSessionServices: Sendable {
    var rewind: LiveRewindCoordinator?
    var memory: LiveMemoryBackend?
    var goal: LiveGoalCoordinator?
    /// Cached because `LiveToolExecutor.tools` is a `let` computed once at
    /// construction: the advertised list cannot change mid-session, so it is
    /// resolved once with the goal state as it stood at launch.
    var toolSpecs: [ToolSpec]

    init(
        rewind: LiveRewindCoordinator?,
        memory: LiveMemoryBackend?,
        goal: LiveGoalCoordinator?,
        goalIsActive: Bool
    ) {
        self.rewind = rewind
        self.memory = memory
        self.goal = goal
        var specs: [ToolSpec] = []
        if let memory {
            specs += LiveMemoryTools.toolSpecs(configuration: memory.configuration)
        }
        if goal != nil {
            specs += LiveGoalTools.toolSpecs(goalIsActive: goalIsActive)
        }
        self.toolSpecs = specs
    }

    /// Names this aggregate answers for. Checked before the registry so a
    /// session tool cannot be shadowed by a same-named MCP tool.
    var toolNames: Set<String> {
        Set(toolSpecs.map(\.name))
    }

    /// Whether this aggregate owns `name`.
    ///
    /// **Invariant: these names must not collide with any `BuiltinToolCatalog`
    /// id, MCP tool name, `run_terminal_cmd`, or a background-task tool name.**
    /// `LiveToolExecutor.invoke` consults this branch first, so a collision
    /// would route the call here and skip whatever gating the real owner had:
    /// the capability filter, PreToolUse hooks and permission pipeline for
    /// registry tools, or `gateTerminalCommand` / the `kill_task` gate for the
    /// shell and background-task branch. The second case is the worse one — it
    /// bypasses a security check someone wrote on purpose, not just a filter.
    /// `LiveToolExecutor`'s initializer asserts disjointness against all three
    /// sets; this is the note explaining why it is there.
    ///
    /// Precedence-first is correct for what lives here — session-state RPCs
    /// that touch no file and spawn no process, where being shadowed by a
    /// same-named MCP tool would be the real hazard. A tool with a filesystem
    /// or process surface belongs in the registry instead, so that its gating
    /// is structural rather than by convention.
    func handles(_ name: String) -> Bool {
        toolNames.contains(name)
    }

    /// Dispatch one session-service tool call.
    func invoke(name: String, arguments: JSONValue) async -> String {
        if let memory, LiveMemoryTools.advertisedToolNames(configuration: memory.configuration).contains(name) {
            return await LiveMemoryTools.invoke(
                name: name,
                arguments: arguments,
                backend: memory
            )
        }
        if name == LiveGoalTools.toolName {
            return await LiveGoalTools.invoke(arguments: arguments, coordinator: goal)
        }
        return "unknown session tool '\(name)'"
    }

    /// Record the pre-turn state of whatever a tool call is about to touch.
    ///
    /// Called from the tool dispatcher for every call, and cheap for the ones
    /// that are not file tools: `trackedTools` is checked first, so a shell
    /// command or a web fetch costs one set lookup.
    func noteToolCall(name: String, arguments: JSONValue) async {
        guard let rewind, LiveRewindPathExtraction.trackedTools.contains(name) else { return }
        let paths = LiveRewindPathExtraction.paths(fromArguments: arguments)
        guard !paths.isEmpty else { return }
        await rewind.capture(paths: paths)
    }

    /// Open a rewind point for the prompt about to run.
    func beginPrompt(text: String) async {
        await rewind?.beginPrompt(text: text)
    }

    /// Close the rewind point, recording what the turn left behind.
    func endPrompt() async {
        await rewind?.endPrompt()
    }

    /// First-turn memory injection.
    ///
    /// Returns `items` unchanged when memory is off, when the conversation
    /// already carries an injected block (a resumed session, or a second turn),
    /// or when the search found nothing — so the caller can assign the result
    /// unconditionally and never has to know which case it hit.
    func injectMemoryContext(
        into items: [ConversationItem],
        prompt: String
    ) async -> [ConversationItem] {
        guard let memory, memory.configuration.initialInjection.enabled else { return items }
        guard !LiveMemoryInjection.alreadyInjected(items) else { return items }
        let results = await memory.search(
            query: LiveMemoryInjection.query(forPrompt: prompt),
            maxResults: LiveMemoryInjection.injectionResultCount,
            minScore: memory.configuration.initialInjection.minScore
        )
        guard let block = LiveMemoryFormatting.memoryContext(results) else { return items }
        return LiveMemoryInjection.inject(block, into: items)
    }
}

// MARK: - Construction

extension OpenGrokLiveApplicationLauncher {
    /// Build the session services for one launch.
    ///
    /// Lives here rather than in `LiveComposition.swift` so the composition
    /// file carries only the call, not the policy.
    static func makeSessionServices(
        sessionID: String,
        workingDirectory: URL,
        openGrokHome: URL,
        conversationRecord: LiveConversationRecord,
        environment: [String: String],
        // `--experimental-memory`, upstream's opt-in switch. Passed explicitly
        // rather than read off the environment so the flag, the env var and the
        // config key are all visible in one place below.
        experimentalMemory: Bool = false,
        // Upstream applies this opt-out after every other memory source, so it
        // must remain effective even when config or the environment enables it.
        noMemory: Bool = false
    ) async -> LiveSessionServices {
        // Rewind is on by default. It is the only recovery path for a bad
        // agent edit outside git, and its cost when unused is one empty
        // dictionary per turn — there is no reason to make a user opt into
        // being able to undo.
        let rewindEnabled = environment["OPENGROK_REWIND"].map {
            $0 == "1" || $0.lowercased() == "true"
        } ?? true
        let rewind: LiveRewindCoordinator? = rewindEnabled
            ? await LiveRewindCoordinator(
                openGrokHome: openGrokHome,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                conversationItems: conversationRecord.items
            )
            : nil

        // Memory reads `[memory]` out of the same authority chain everything
        // else does, so a repo-local config in an untrusted folder cannot
        // switch it on.
        let document = (try? ConfigLayers.load(environment: environment))?
            .effectiveConfigBase() ?? .table(TOMLTable())
        var memoryConfiguration = LiveMemoryConfiguration.resolve(
            document: document,
            environment: environment
        )
        // The positive flag can only turn memory ON. The negative flag is
        // applied afterward so it wins over config, environment, and the
        // positive override just as it does upstream.
        if experimentalMemory { memoryConfiguration.enabled = true }
        if noMemory { memoryConfiguration.enabled = false }
        let memory = LiveMemoryBackend(
            configuration: memoryConfiguration,
            workingDirectory: workingDirectory,
            environment: environment
        )

        // The goal tracker is constructed unconditionally: it costs a file read
        // that usually misses, and it has to exist for `/goal` to have anything
        // to talk to. `update_goal` is still only *advertised* while a goal is
        // active, so a session without a goal sees no extra tool.
        let goalDirectory = openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let goal = LiveGoalCoordinator(sessionDirectory: goalDirectory)

        return LiveSessionServices(
            rewind: rewind,
            memory: memory,
            goal: goal,
            goalIsActive: await goal.isActive
        )
    }
}

// MARK: - Usage reporting

/// The data a `/usage` readout renders.
///
/// Context-window numbers come from `LiveCompactionCoordinator.usage()`
/// (`ContextUsage`), which is where compaction already computes them — this
/// type does not recompute them, it carries them alongside the two things
/// compaction does not know about: provider billing windows and the session's
/// own token ledger.
struct LiveUsageReport: Sendable, Equatable {
    var context: ContextUsage?
    var quotaWindows: [ProviderQuotaWindow]
    var quotaFailures: [ProviderUsageFailure]
    var antigravityQuota: LiveAntigravityQuotaSummary? = nil
    /// Transcript fallback for older fixtures and providers that have not
    /// supplied a usage event. Never prefer it over a real session ledger.
    var estimatedSessionTokens: UInt64
    var turnCount: Int
    var promptCacheHitRatePct: Double? = nil
    var sessionUsage: LiveSessionUsageSnapshot? = nil

    var sessionUsageIsAuthoritative: Bool {
        guard let sessionUsage else { return false }
        return !sessionUsage.incomplete && !sessionUsage.totals.costIsPartial
    }

    var hasMeasuredSessionUsage: Bool {
        guard let sessionUsage else { return false }
        let totals = sessionUsage.totals
        return totals.inputTokens > 0
            || totals.outputTokens > 0
            || totals.cachedReadTokens > 0
            || totals.cacheCreationTokens > 0
            || !sessionUsage.models.isEmpty
    }
}

enum LiveUsageComposition {
    /// Assemble a usage report.
    ///
    /// Provider-reported session totals take precedence over transcript
    /// estimates. The fallback remains for legacy sessions and test fixtures
    /// that have not received a metered provider response.
    ///
    /// **On the quota windows**: `fetchCombinedProviderUsage` is real and
    /// wired, but nothing in the tree implements `ProviderUsageSource` yet — no
    /// provider has a billing endpoint ported. With an empty source map it
    /// returns empty, so a `/usage` readout shows context and token figures and
    /// simply omits the billing section rather than inventing one.
    static func report(
        context: ContextUsage?,
        items: [ConversationItem],
        usageSources: [ModelProvider: any ProviderUsageSource] = [:],
        cacheHitRatePct: Double? = nil,
        sessionUsage: LiveSessionUsageSnapshot? = nil
    ) async -> LiveUsageReport {
        let combined = usageSources.isEmpty
            ? CombinedProviderUsage(windows: [], failures: [])
            : await fetchCombinedProviderUsage(sources: usageSources)
        return LiveUsageReport(
            context: context,
            quotaWindows: combined.windows,
            quotaFailures: combined.failures,
            antigravityQuota: LiveAntigravityCache.shared.quotaSummary(),
            estimatedSessionTokens: estimateTokens(items),
            turnCount: turnCount(items),
            promptCacheHitRatePct: sessionUsage?.cacheHitRatePct ?? cacheHitRatePct,
            sessionUsage: sessionUsage
        )
    }

    static func estimateTokens(_ items: [ConversationItem]) -> UInt64 {
        var total: UInt64 = 0
        for item in items {
            switch item {
            case .system(let system):
                total &+= OpenGrokTokenEstimation.estimateTokens(system.content)
            case .user(let user):
                for part in user.content {
                    switch part {
                    case .text(let text):
                        total &+= OpenGrokTokenEstimation.estimateTokens(text)
                    case .image:
                        total &+= OpenGrokTokenEstimation.estimateImageTokens(imageCount: 1)
                    }
                }
            case .assistant(let assistant):
                total &+= OpenGrokTokenEstimation.estimateTokens(assistant.content)
                for call in assistant.toolCalls {
                    total &+= OpenGrokTokenEstimation.estimateTokens(call.arguments)
                }
            case .toolResult(let result):
                total &+= OpenGrokTokenEstimation.estimateTokens(result.content)
            default:
                continue
            }
        }
        return total
    }

    static func turnCount(_ items: [ConversationItem]) -> Int {
        var count = 0
        for item in items {
            guard case .user(let user) = item else { continue }
            if user.syntheticReason == nil { count += 1 }
        }
        return count
    }

    /// Render `/usage` as plain text.
    static func render(_ report: LiveUsageReport) -> String {
        var lines: [String] = []
        if let context = report.context {
            let percent = OpenGrokTokenEstimation.usagePercentage(
                used: context.usedTokens,
                total: context.contextWindow
            )
            lines.append("Model:    \(context.modelID)")
            lines.append(
                "Context:  \(context.usedTokens) / \(context.contextWindow) tokens "
                    + "(\(String(format: "%.1f", percent))%)"
            )
            lines.append(
                "Compacts: \(context.compactionCount)"
                    + (context.compactionsRemaining.map { ", \($0) remaining" } ?? "")
            )
        }
        lines.append("Turns:    \(report.turnCount)")
        appendSessionAccounting(report, to: &lines)
        if let hitRate = report.promptCacheHitRatePct {
            lines.append("Cache:    \(String(format: "%.1f", hitRate))% prompt cache hit rate")
        }

        if !report.quotaWindows.isEmpty {
            lines.append("")
            for window in report.quotaWindows {
                let limit = window.limit.map { "\(window.used) / \($0)" } ?? "\(window.used)"
                var line = "\(window.provider.asString): \(limit)"
                if let resetAt = window.resetAt {
                    line += " (resets \(LiveSessionsComposition.timestamp(resetAt)))"
                }
                lines.append(line)
            }
        }
        for failure in report.quotaFailures {
            lines.append("\(failure.provider.asString): usage unavailable — \(failure.message)")
        }
        if let antigravityQuota = report.antigravityQuota {
            lines.append("")
            lines.append(
                "Antigravity quota (captured \(Int(antigravityQuota.age()))s ago):"
            )
            for bucket in antigravityQuota.buckets {
                let remaining = max(0, min(1, bucket.remainingFraction)) * 100
                var line = "\(bucket.label): \(String(format: "%.0f", remaining))% remaining"
                if let reset = bucket.resetTime, !reset.isEmpty {
                    line += " (resets \(reset))"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func appendSessionAccounting(
        _ report: LiveUsageReport,
        to lines: inout [String]
    ) {
        guard let usage = report.sessionUsage else {
            lines.append("Tokens:   ~\(report.estimatedSessionTokens) estimated this session")
            return
        }

        let totals = usage.totals
        if report.hasMeasuredSessionUsage || !usage.incomplete {
            lines.append("Tokens:   \(totals.totalTokens) provider-reported this session")
            lines.append("Input:    \(totals.inputTokens) tokens")
            lines.append("Output:   \(totals.outputTokens) tokens")
            lines.append("Cache read:     \(totals.cachedReadTokens) input tokens")
            lines.append("Cache creation: \(totals.cacheCreationTokens) input tokens")
            if totals.reasoningTokens > 0 {
                lines.append("Reasoning: \(totals.reasoningTokens) output tokens")
            }
        } else {
            lines.append("Tokens:   unavailable (provider usage is incomplete)")
        }
        lines.append(
            "Model calls: \(totals.modelCalls) "
                + "(\(usage.mainLoopModelCalls) main-loop)"
        )

        if usage.incomplete {
            lines.append("Accounting: incomplete; some model usage may be missing")
        } else if totals.costIsPartial {
            lines.append("Accounting: provider-reported tokens; cost reporting is incomplete")
        }

        if let ticks = usage.trustedCostUsdTicks {
            lines.append("Cost:     \(formatUSDCost(ticks))")
        } else if usage.incomplete {
            lines.append("Cost:     unavailable (session usage is incomplete)")
        } else if totals.costMissingCalls > 0 {
            lines.append("Cost:     unavailable (provider cost reporting is incomplete)")
        } else {
            lines.append("Cost:     unavailable (provider did not report cost)")
        }

        if !usage.models.isEmpty {
            lines.append("By model:")
            for model in usage.models {
                let modelTotals = model.totals
                var line = "  \(model.modelID): \(modelTotals.totalTokens) tokens"
                    + " (\(modelTotals.inputTokens) input, \(modelTotals.outputTokens) output,"
                    + " \(modelTotals.cachedReadTokens) cache read,"
                    + " \(modelTotals.cacheCreationTokens) cache creation,"
                    + " \(modelTotals.modelCalls) calls)"
                if usage.trustedCostUsdTicks != nil,
                   !modelTotals.costIsPartial,
                   let ticks = modelTotals.costUsdTicks,
                   ticks > 0
                {
                    line += " · \(formatUSDCost(ticks))"
                }
                lines.append(line)
            }
        }

        if !usage.unattributedPromptIDs.isEmpty {
            lines.append(
                "Late child usage: included in session totals; parent turns "
                    + usage.unattributedPromptIDs.joined(separator: ", ")
                    + " had already completed"
            )
        }
    }

    static func formatUSDCost(_ ticks: Int64) -> String {
        let dollars = Double(ticks) / 10_000_000_000
        return "$\(String(format: "%.10f", dollars)) (\(ticks) USD ticks)"
    }
}

enum LiveCacheComposition {
    /// Render `/cache` prompt cache report as plain text.
    static func render(
        cacheHitRate: Double?,
        totalPromptTokens: UInt64,
        cachedTokens: UInt64,
        breakEvents: [(reason: String, details: String)] = []
    ) -> String {
        var lines: [String] = []
        lines.append("Prompt Cache Diagnostics")
        lines.append("────────────────────────")
        if let rate = cacheHitRate {
            lines.append("Hit Rate:      \(String(format: "%.1f", rate))%")
        } else {
            lines.append("Hit Rate:      None (cold start / no prompt tokens)")
        }
        lines.append("Prompt Tokens: \(totalPromptTokens)")
        lines.append("Cached Tokens: \(cachedTokens)")

        if !breakEvents.isEmpty {
            lines.append("")
            lines.append("Cache Break Events:")
            for event in breakEvents.suffix(10) {
                lines.append("  • [\(event.reason)] \(event.details)")
            }
        } else {
            lines.append("")
            lines.append("No cache break events recorded.")
        }
        return lines.joined(separator: "\n")
    }
}
