// Usage.swift
//
// Open Grok — Swift port of the per-prompt and per-session billing ledgers
// in `crates/codegen/xai-chat-state/src/usage.rs`.
//
// `UsageTotals` is the per-model aggregate; `UsageLedger` is the per-prompt
// and per-session bill. The folding semantics preserve the W1-S3 acceptance
// criterion: "Usage values preserve input, cached input, output, reasoning,
// provider quota windows, and aggregate child-agent folding."
//
// Completeness ownership (mirrors the Rust doc comment):
// - `UsageLedger.incomplete` — durable on the bill snapshot. Set by nested
//   subagent incomplete fold, drain timeout, true apply-miss, and
//   `markUsageIncomplete`. Monotonic for a ledger instance.
// - `mainLoopModelCalls` — main-agent loop rounds for `num_turns`
//   (subagents excluded); only `recordMainLoopCall` writes it.
// - Cost ticks: `0` / negative / absent normalize to `nil` ("unreported",
//   never "free") via `OpenGrokSamplingTypes.reportedCostTicks`.

import Foundation
import OpenGrokSamplingTypes

/// Per-model aggregate usage totals. Not serialized (the Rust source marks
/// these `#[derive(Default, PartialEq, Eq)]` and never `Serialize`).
public struct UsageTotals: Sendable, Equatable, Hashable {
    public var inputTokens: UInt64
    public var outputTokens: UInt64
    public var cachedReadTokens: UInt64
    public var cachedCreationTokens: UInt64
    public var reasoningTokens: UInt64
    public var modelCalls: UInt64
    public var apiDurationMs: UInt64
    /// USD ticks (1e10 per USD). `nil` when no call reported cost.
    public var costUsdTicks: Int64?
    public var costMissingCalls: UInt64

    public init(
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        cachedReadTokens: UInt64 = 0,
        reasoningTokens: UInt64 = 0,
        modelCalls: UInt64 = 0,
        apiDurationMs: UInt64 = 0,
        costUsdTicks: Int64? = nil,
        costMissingCalls: UInt64 = 0,
        cachedCreationTokens: UInt64 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedCreationTokens = cachedCreationTokens
        self.reasoningTokens = reasoningTokens
        self.modelCalls = modelCalls
        self.apiDurationMs = apiDurationMs
        self.costUsdTicks = costUsdTicks
        self.costMissingCalls = costMissingCalls
    }

    /// `input + output`: Responses wire `total` is live context length.
    public func totalTokens() -> UInt64 {
        inputTokens.addingWithSaturate(outputTokens)
    }

    /// Cache hit rate as a percentage (0.0 to 100.0), or `nil` if `inputTokens == 0`.
    public var cacheHitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return (Double(cachedReadTokens) / Double(inputTokens)) * 100.0
    }

    /// Cache hit rate percentage, defaulting to `0.0` if `inputTokens == 0`.
    public var cacheHitRatePct: Double {
        cacheHitRate ?? 0.0
    }

    /// `true` when some calls reported cost but at least one did not.
    public func costIsPartial() -> Bool {
        costUsdTicks != nil && costMissingCalls > 0
    }

    /// Build a one-call `UsageTotals` from a wire `TokenUsage`.
    static func fromCall(
        usage: TokenUsage,
        apiDurationMs: UInt64?,
        costUsdTicks: Int64?
    ) -> UsageTotals {
        let normalizedCost = OpenGrokSamplingTypes.reportedCostTicks(costUsdTicks)
        return UsageTotals(
            inputTokens: UInt64(usage.promptTokens),
            outputTokens: UInt64(usage.completionTokens),
            cachedReadTokens: UInt64(usage.cachedPromptTokens),
            reasoningTokens: UInt64(usage.reasoningTokens),
            modelCalls: 1,
            apiDurationMs: apiDurationMs ?? 0,
            costUsdTicks: normalizedCost,
            costMissingCalls: normalizedCost == nil ? 1 : 0,
            cachedCreationTokens: UInt64(usage.cacheCreationPromptTokens)
        )
    }

    /// Fold another totals into `self`, saturating on overflow.
    mutating func foldTotals(_ other: UsageTotals) {
        inputTokens = inputTokens.addingWithSaturate(other.inputTokens)
        outputTokens = outputTokens.addingWithSaturate(other.outputTokens)
        cachedReadTokens = cachedReadTokens.addingWithSaturate(other.cachedReadTokens)
        cachedCreationTokens = cachedCreationTokens.addingWithSaturate(other.cachedCreationTokens)
        reasoningTokens = reasoningTokens.addingWithSaturate(other.reasoningTokens)
        modelCalls = modelCalls.addingWithSaturate(other.modelCalls)
        apiDurationMs = apiDurationMs.addingWithSaturate(other.apiDurationMs)
        costMissingCalls = costMissingCalls.addingWithSaturate(other.costMissingCalls)
        costUsdTicks = Self.mergeCostTicks(costUsdTicks, other.costUsdTicks)
    }
}

extension UsageTotals {
    /// Merge two optional cost-tick totals: `nil + nil = nil`; otherwise sum,
    /// treating `nil` as `0`.
    static func mergeCostTicks(_ a: Int64?, _ b: Int64?) -> Int64? {
        switch (a, b) {
        case (nil, nil): return nil
        default:
            let lhs = a ?? 0
            let rhs = b ?? 0
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int64.max : sum
        }
    }
}

/// Per-prompt or per-session billing ledger. Not serialized (the Rust source
/// keeps these in-memory only).
public final class UsageLedger: @unchecked Sendable, Equatable, Hashable {
    public var totals: UsageTotals
    /// Per-model breakdown, preserved in insertion order (mirrors Rust
    /// `indexmap::IndexMap<String, UsageTotals>`).
    public var byModel: [(model: String, totals: UsageTotals)]
    /// Main-agent loop rounds for `numTurns` (subagents excluded).
    public var mainLoopModelCalls: UInt64
    /// Bill may under-count (drain timeout, nested subagent incomplete, apply failure).
    public var incomplete: Bool

    public init(
        totals: UsageTotals = UsageTotals(),
        byModel: [(model: String, totals: UsageTotals)] = [],
        mainLoopModelCalls: UInt64 = 0,
        incomplete: Bool = false
    ) {
        self.totals = totals
        self.byModel = byModel
        self.mainLoopModelCalls = mainLoopModelCalls
        self.incomplete = incomplete
    }

    /// Fold one main-agent-loop model call. This is the only writer of
    /// `mainLoopModelCalls` (the wire `numTurns`); side calls such as
    /// compaction must not use it.
    public func recordMainLoopCall(
        modelId: String,
        usage: TokenUsage,
        apiDurationMs: UInt64?,
        costUsdTicks: Int64?
    ) {
        let call = UsageTotals.fromCall(usage: usage, apiDurationMs: apiDurationMs, costUsdTicks: costUsdTicks)
        mainLoopModelCalls = mainLoopModelCalls.addingWithSaturate(1)
        foldEntry(modelId: modelId, totals: call)
    }

    /// Fold subagent usage without incrementing `mainLoopModelCalls`.
    public func recordSubagent(byModel: [(model: String, totals: UsageTotals)], incomplete: Bool) {
        for (modelId, totals) in byModel {
            foldEntry(modelId: modelId, totals: totals)
        }
        if incomplete {
            self.incomplete = true
        }
    }

    public func markIncomplete() {
        self.incomplete = true
    }

    /// Fold `totals` into both the aggregate `totals` and the per-model entry,
    /// creating the per-model entry if absent.
    private func foldEntry(modelId: String, totals: UsageTotals) {
        self.totals.foldTotals(totals)
        if let idx = byModel.firstIndex(where: { $0.model == modelId }) {
            byModel[idx].totals.foldTotals(totals)
        } else {
            byModel.append((model: modelId, totals: totals))
        }
    }

    // MARK: Equatable/Hashable (reference semantics — compare contents)

    public static func == (lhs: UsageLedger, rhs: UsageLedger) -> Bool {
        lhs.totals == rhs.totals
            && lhs.mainLoopModelCalls == rhs.mainLoopModelCalls
            && lhs.incomplete == rhs.incomplete
            && lhs.byModel.count == rhs.byModel.count
            && zip(lhs.byModel, rhs.byModel).allSatisfy { a, b in
                a.model == b.model && a.totals == b.totals
            }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(totals)
        hasher.combine(mainLoopModelCalls)
        hasher.combine(incomplete)
        for (model, totals) in byModel {
            hasher.combine(model)
            hasher.combine(totals)
        }
    }
}

// MARK: - Saturating arithmetic helpers

fileprivate extension UInt64 {
    func addingWithSaturate(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = self.addingReportingOverflow(other)
        return overflow ? UInt64.max : sum
    }
}
