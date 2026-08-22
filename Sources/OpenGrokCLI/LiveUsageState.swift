import Foundation
import OpenGrokChatState

/// Lossless, durable representation of the otherwise in-memory billing totals.
/// Cost availability must survive a restart: a missing call is not a free call.
struct LiveUsageTotalsSnapshot: Codable, Sendable, Equatable {
    var inputTokens: UInt64
    var outputTokens: UInt64
    var cachedReadTokens: UInt64
    var cacheCreationTokens: UInt64
    var reasoningTokens: UInt64
    var modelCalls: UInt64
    var apiDurationMs: UInt64
    var costUsdTicks: Int64?
    var costMissingCalls: UInt64

    init(_ totals: UsageTotals) {
        inputTokens = totals.inputTokens
        outputTokens = totals.outputTokens
        cachedReadTokens = totals.cachedReadTokens
        cacheCreationTokens = totals.cachedCreationTokens
        reasoningTokens = totals.reasoningTokens
        modelCalls = totals.modelCalls
        apiDurationMs = totals.apiDurationMs
        costUsdTicks = totals.costUsdTicks
        costMissingCalls = totals.costMissingCalls
    }

    var usageTotals: UsageTotals {
        UsageTotals(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedReadTokens: cachedReadTokens,
            reasoningTokens: reasoningTokens,
            modelCalls: modelCalls,
            apiDurationMs: apiDurationMs,
            costUsdTicks: costUsdTicks,
            costMissingCalls: costMissingCalls,
            cachedCreationTokens: cacheCreationTokens
        )
    }

    var totalTokens: UInt64 {
        let (sum, overflow) = inputTokens.addingReportingOverflow(outputTokens)
        return overflow ? .max : sum
    }

    var costIsPartial: Bool {
        costUsdTicks != nil && costMissingCalls > 0
    }
}

struct LiveUsageModelSnapshot: Codable, Sendable, Equatable {
    var modelID: String
    var totals: LiveUsageTotalsSnapshot
}

/// Session spend, including children that finished after their parent turn.
/// Late-prompt markers are reporting metadata, not an incomplete session bill.
struct LiveSessionUsageSnapshot: Codable, Sendable, Equatable {
    var totals: LiveUsageTotalsSnapshot
    var models: [LiveUsageModelSnapshot]
    var mainLoopModelCalls: UInt64
    var incomplete: Bool
    var unattributedPromptIDs: [String]

    init(ledger: UsageLedger, unattributedPromptIDs: [String] = []) {
        totals = LiveUsageTotalsSnapshot(ledger.totals)
        models = ledger.byModel.map { entry in
            LiveUsageModelSnapshot(
                modelID: entry.model,
                totals: LiveUsageTotalsSnapshot(entry.totals)
            )
        }
        mainLoopModelCalls = ledger.mainLoopModelCalls
        incomplete = ledger.incomplete
        self.unattributedPromptIDs = Array(Set(unattributedPromptIDs)).sorted()
    }

    var usageLedger: UsageLedger {
        UsageLedger(
            totals: totals.usageTotals,
            byModel: models.map { (model: $0.modelID, totals: $0.totals.usageTotals) },
            mainLoopModelCalls: mainLoopModelCalls,
            incomplete: incomplete
        )
    }

    var trustedCostUsdTicks: Int64? {
        guard !incomplete,
              !totals.costIsPartial,
              let cost = totals.costUsdTicks,
              cost > 0
        else { return nil }
        return cost
    }

    var cacheHitRatePct: Double? {
        guard totals.inputTokens > 0 else { return nil }
        return Double(totals.cachedReadTokens) / Double(totals.inputTokens) * 100
    }
}
