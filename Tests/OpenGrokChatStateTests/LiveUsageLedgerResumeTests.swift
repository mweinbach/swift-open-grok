import Foundation
import Testing
@testable import OpenGrokChatState
@testable import OpenGrokSamplingTypes

@Suite("Resumed live-session usage billing")
struct LiveUsageLedgerResumeTests {
    @Test("resume restores exact cumulative totals and starts without prior prompt usage")
    func restoresCumulativeUsageWithoutPromptLeak() async {
        let parentTotals = UsageTotals(
            inputTokens: 1_250,
            outputTokens: 320,
            cachedReadTokens: 900,
            reasoningTokens: 140,
            modelCalls: 4,
            apiDurationMs: 2_700,
            costUsdTicks: 91_000,
            costMissingCalls: 1
        )
        let childTotals = UsageTotals(
            inputTokens: 400,
            outputTokens: 80,
            cachedReadTokens: 120,
            reasoningTokens: 15,
            modelCalls: 2,
            apiDurationMs: 650,
            costUsdTicks: 13_000
        )
        let cumulative = UsageTotals(
            inputTokens: 1_650,
            outputTokens: 400,
            cachedReadTokens: 1_020,
            reasoningTokens: 155,
            modelCalls: 6,
            apiDurationMs: 3_350,
            costUsdTicks: 104_000,
            costMissingCalls: 1
        )
        let prior = UsageLedger(
            totals: cumulative,
            byModel: [
                (model: "grok-code", totals: parentTotals),
                (model: "child-model", totals: childTotals),
            ],
            mainLoopModelCalls: 4,
            incomplete: true
        )
        let handle = makeHandle(initialSessionUsage: prior)
        defer { handle.close() }

        switch await handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.totals == cumulative)
            #expect(session.byModel.map(\.model) == ["grok-code", "child-model"])
            #expect(session.byModel[0].totals == parentTotals)
            #expect(session.byModel[1].totals == childTotals)
            #expect(session.mainLoopModelCalls == 4)
            #expect(session.incomplete)
        case .failure:
            Issue.record("resumed session usage should be readable")
        }

        switch await handle.tryGetPromptUsage() {
        case .success(let prompt):
            #expect(prompt == nil)
        case .failure:
            Issue.record("new prompt usage should be queryable")
        }
    }

    @Test("new model calls extend the restored bill exactly once")
    func resumedModelCallsAccumulateOnce() async {
        let priorTotals = UsageTotals(
            inputTokens: 100,
            outputTokens: 20,
            cachedReadTokens: 40,
            reasoningTokens: 5,
            modelCalls: 2,
            apiDurationMs: 300,
            costUsdTicks: 1_000
        )
        let prior = UsageLedger(
            totals: priorTotals,
            byModel: [(model: "grok-code", totals: priorTotals)],
            mainLoopModelCalls: 2
        )
        let handle = makeHandle(initialSessionUsage: prior)
        defer { handle.close() }

        handle.recordModelCallUsage(
            modelId: "grok-code",
            usage: TokenUsage(
                promptTokens: 30,
                completionTokens: 10,
                totalTokens: 40,
                reasoningTokens: 3,
                cachedPromptTokens: 12
            ),
            apiDurationMs: 80,
            costUsdTicks: 250
        )

        switch await handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.totals.inputTokens == 130)
            #expect(session.totals.outputTokens == 30)
            #expect(session.totals.cachedReadTokens == 52)
            #expect(session.totals.reasoningTokens == 8)
            #expect(session.totals.modelCalls == 3)
            #expect(session.totals.apiDurationMs == 380)
            #expect(session.totals.costUsdTicks == 1_250)
            #expect(session.mainLoopModelCalls == 3)
            #expect(session.byModel.count == 1)
            #expect(session.byModel[0].totals == session.totals)
        case .failure:
            Issue.record("updated cumulative session usage should be readable")
        }

        switch await handle.tryGetPromptUsage() {
        case .success(let prompt):
            #expect(prompt?.totals.inputTokens == 30)
            #expect(prompt?.totals.outputTokens == 10)
            #expect(prompt?.mainLoopModelCalls == 1)
        case .failure:
            Issue.record("new prompt should contain only post-resume calls")
        }
    }

    @Test("unmetered successful calls increment known counts without inventing usage")
    func resumedUnmeteredModelCallsPreserveKnownMetrics() async {
        let priorTotals = UsageTotals(
            inputTokens: 100,
            outputTokens: 20,
            cachedReadTokens: 40,
            reasoningTokens: 5,
            modelCalls: 2,
            apiDurationMs: 300,
            costUsdTicks: 1_000,
            costMissingCalls: 1
        )
        let prior = UsageLedger(
            totals: priorTotals,
            byModel: [(model: "known-model", totals: priorTotals)],
            mainLoopModelCalls: 2
        )
        let handle = makeHandle(initialSessionUsage: prior)
        defer { handle.close() }

        #expect(await handle.recordUnmeteredModelCall())

        switch await handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.totals.inputTokens == priorTotals.inputTokens)
            #expect(session.totals.outputTokens == priorTotals.outputTokens)
            #expect(session.totals.cachedReadTokens == priorTotals.cachedReadTokens)
            #expect(session.totals.reasoningTokens == priorTotals.reasoningTokens)
            #expect(session.totals.apiDurationMs == priorTotals.apiDurationMs)
            #expect(session.totals.costUsdTicks == priorTotals.costUsdTicks)
            #expect(session.totals.costMissingCalls == priorTotals.costMissingCalls)
            #expect(session.totals.modelCalls == 3)
            #expect(session.mainLoopModelCalls == 3)
            #expect(session.incomplete)
            #expect(session.byModel.count == 1)
            #expect(session.byModel[0].model == "known-model")
            #expect(session.byModel[0].totals == priorTotals)
        case .failure:
            Issue.record("unmetered call must extend known cumulative counts")
        }

        switch await handle.tryGetPromptUsage() {
        case .success(let prompt):
            #expect(prompt?.totals.modelCalls == 1)
            #expect(prompt?.mainLoopModelCalls == 1)
            #expect(prompt?.incomplete == true)
            #expect(prompt?.byModel.isEmpty == true)
        case .failure:
            Issue.record("unmetered call must create incomplete prompt accounting")
        }
    }

    @Test("unmetered calls saturate resumed counters and preserve prompt boundaries")
    func unmeteredCallsSaturateAndResetPromptAccounting() async {
        let prior = UsageLedger(
            totals: UsageTotals(inputTokens: 90, modelCalls: UInt64.max),
            mainLoopModelCalls: UInt64.max
        )
        let handle = makeHandle(initialSessionUsage: prior)
        defer { handle.close() }

        #expect(await handle.recordUnmeteredModelCall())
        handle.incrementPromptIndex()
        #expect(await handle.recordUnmeteredModelCall())

        switch await handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.totals.modelCalls == UInt64.max)
            #expect(session.mainLoopModelCalls == UInt64.max)
            #expect(session.totals.inputTokens == 90)
            #expect(session.incomplete)
        case .failure:
            Issue.record("resumed cumulative model-call counters should saturate")
        }

        switch await handle.tryGetPromptUsage() {
        case .success(let prompt):
            #expect(prompt?.totals.modelCalls == 1)
            #expect(prompt?.mainLoopModelCalls == 1)
            #expect(prompt?.incomplete == true)
        case .failure:
            Issue.record("new prompt must not inherit the previous prompt's bill")
        }
    }

    @Test("unmetered accounting fails closed after its chat actor terminates")
    func unmeteredCallsFailClosedAfterTermination() async {
        let handle = makeHandle(initialSessionUsage: UsageLedger())
        handle.close()

        #expect(await handle.recordUnmeteredModelCall() == false)
    }

    @Test("late child usage folds into restored session without contaminating the new prompt")
    func resumedSubagentUsageAndIncompleteAccounting() async {
        let priorTotals = UsageTotals(
            inputTokens: 200,
            outputTokens: 25,
            modelCalls: 1,
            costUsdTicks: 500
        )
        let prior = UsageLedger(
            totals: priorTotals,
            byModel: [(model: "parent", totals: priorTotals)],
            mainLoopModelCalls: 1
        )
        let handle = makeHandle(initialSessionUsage: prior)
        defer { handle.close() }
        let childTotals = UsageTotals(
            inputTokens: 70,
            outputTokens: 12,
            cachedReadTokens: 30,
            reasoningTokens: 4,
            modelCalls: 2,
            apiDurationMs: 90,
            costUsdTicks: 125
        )

        let applied = await handle.recordSubagentUsage(
            byModel: [(model: "child", totals: childTotals)],
            attributeToPrompt: false,
            incomplete: true
        )
        #expect(applied)

        switch await handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.totals.inputTokens == 270)
            #expect(session.totals.outputTokens == 37)
            #expect(session.totals.modelCalls == 3)
            #expect(session.totals.costUsdTicks == 625)
            #expect(session.mainLoopModelCalls == 1)
            #expect(session.incomplete)
            #expect(session.byModel.map(\.model) == ["parent", "child"])
        case .failure:
            Issue.record("child usage must fold into the restored session")
        }

        switch await handle.tryGetPromptUsage() {
        case .success(let prompt):
            #expect(prompt == nil)
        case .failure:
            Issue.record("late child usage must not create prompt usage")
        }
    }

    @Test("actor deep-copies persisted bills instead of aliasing caller-owned snapshots")
    func resumedBillIsIndependentFromSnapshot() async {
        let totals = UsageTotals(inputTokens: 90, outputTokens: 10, modelCalls: 1)
        let original = UsageLedger(
            totals: totals,
            byModel: [(model: "original", totals: totals)],
            mainLoopModelCalls: 1
        )
        let handle = makeHandle(initialSessionUsage: original)
        defer { handle.close() }
        original.totals.inputTokens = 99_999
        original.byModel[0].totals.outputTokens = 88_888
        original.mainLoopModelCalls = 77_777
        original.incomplete = true

        switch await handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.totals.inputTokens == 90)
            #expect(session.byModel[0].totals.outputTokens == 10)
            #expect(session.mainLoopModelCalls == 1)
            #expect(!session.incomplete)
        case .failure:
            Issue.record("actor should own an independent usage snapshot")
        }
    }

    @Test("custom-pruning spawn accepts the same resumed usage baseline")
    func pruningSpawnRestoresBaseline() async {
        let totals = UsageTotals(inputTokens: 444, outputTokens: 55, modelCalls: 3)
        let previous = UsageLedger(
            totals: totals,
            byModel: [(model: "prior", totals: totals)],
            mainLoopModelCalls: 3,
            incomplete: true
        )
        let handle = ChatStateActor.spawnWithPruning(
            initialConversation: [.user("existing")],
            samplingConfig: config(),
            pruningConfig: PruningConfig(),
            initialSessionUsage: previous,
            persistence: NullChatPersistence()
        )
        defer { handle.close() }

        switch await handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.totals == totals)
            #expect(session.mainLoopModelCalls == 3)
            #expect(session.incomplete)
        case .failure:
            Issue.record("custom-pruning spawn must preserve restored usage")
        }
    }

    private func makeHandle(initialSessionUsage: UsageLedger) -> ChatStateHandle {
        ChatStateActor.spawn(
            initialConversation: [.system("existing session")],
            samplingConfig: config(),
            initialSessionUsage: initialSessionUsage,
            persistence: NullChatPersistence()
        )
    }

    private func config() -> SamplingConfig {
        SamplingConfig(
            baseURL: "https://api.x.ai/v1",
            model: "grok-code",
            contextWindow: 256_000
        )
    }
}
