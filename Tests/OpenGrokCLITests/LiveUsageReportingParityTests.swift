import Foundation
import OpenGrokChatState
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private final class LiveUsageReportingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}

    func flush() throws {}
}

private struct LiveUsageReportingFixture {
    let home: URL
    let store: LiveConversationStore
    let history: LiveConversationHistory
    let renderer: LiveInteractiveControllerRenderer

    init(sessionID: String = "usage-report-session") throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-live-usage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: home)
        record.currentModelID = "grok-metered"
        record.currentProvider = .xai
        record.items = [.user("show the actual provider bill")]

        store = LiveConversationStore(openGrokHome: home)
        history = LiveConversationHistory(record: record, store: store)
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: LiveUsageReportingSink(),
            workingDirectory: home.path,
            modelName: "grok-metered",
            modelCatalog: [
                LiveModelPickerEntry(
                    id: "grok-metered", providerID: "xai", name: "grok-metered"
                ),
                LiveModelPickerEntry(
                    id: "codex-child", providerID: "codex", name: "codex-child"
                ),
            ],
            sessionID: sessionID,
            conversationHistory: history,
            openGrokHome: home,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}

private func liveUsageSnapshot(
    totals: UsageTotals,
    models: [(model: String, totals: UsageTotals)] = [],
    mainLoopCalls: UInt64 = 1,
    incomplete: Bool = false,
    latePromptIDs: [String] = []
) -> LiveSessionUsageSnapshot {
    LiveSessionUsageSnapshot(
        ledger: UsageLedger(
            totals: totals,
            byModel: models,
            mainLoopModelCalls: mainLoopCalls,
            incomplete: incomplete
        ),
        unattributedPromptIDs: latePromptIDs
    )
}

@Suite("Live provider usage reporting parity", .serialized)
struct LiveUsageReportingParityTests {
    @Test("provider-ledger totals replace transcript estimates across both text surfaces")
    func providerTotalsReplaceTranscriptEstimates() async {
        let parent = UsageTotals(
            inputTokens: 1_000,
            outputTokens: 200,
            cachedReadTokens: 400,
            reasoningTokens: 35,
            modelCalls: 2,
            costUsdTicks: 2_500_000_000,
            cachedCreationTokens: 80
        )
        let child = UsageTotals(
            inputTokens: 350,
            outputTokens: 100,
            cachedReadTokens: 100,
            reasoningTokens: 15,
            modelCalls: 1,
            costUsdTicks: 750_000_000,
            cachedCreationTokens: 15
        )
        let usage = liveUsageSnapshot(
            totals: UsageTotals(
                inputTokens: 1_350,
                outputTokens: 300,
                cachedReadTokens: 500,
                reasoningTokens: 50,
                modelCalls: 3,
                costUsdTicks: 3_250_000_000,
                cachedCreationTokens: 95
            ),
            models: [("grok-metered", parent), ("codex-child", child)],
            mainLoopCalls: 2
        )

        let report = await LiveUsageComposition.report(
            context: nil,
            items: [.user("tiny")],
            cacheHitRatePct: 99,
            sessionUsage: usage
        )

        #expect(report.sessionUsageIsAuthoritative)
        #expect(report.estimatedSessionTokens != 1_650)
        #expect(abs((report.promptCacheHitRatePct ?? 0) - 37.037037) < 0.001)

        for text in [
            LiveUsageComposition.render(report),
            LiveInteractiveControllerRenderer.sessionUsageBlockText(report: report),
        ] {
            #expect(text.contains("Tokens:   1650 provider-reported this session"))
            #expect(text.contains("Input:    1350 tokens"))
            #expect(text.contains("Output:   300 tokens"))
            #expect(text.contains("Cache read:     500 input tokens"))
            #expect(text.contains("Cache creation: 95 input tokens"))
            #expect(text.contains("Reasoning: 50 output tokens"))
            #expect(text.contains("Model calls: 3 (2 main-loop)"))
            #expect(text.contains("$0.3250000000 (3250000000 USD ticks)"))
            #expect(text.contains("grok-metered: 1200 tokens"))
            #expect(text.contains("codex-child: 450 tokens"))
            #expect(!text.contains("estimated this session"))
        }
    }

    @Test("missing provider snapshots retain the explicitly estimated legacy fallback")
    func missingProviderSnapshotRetainsEstimatedFallback() async {
        let report = await LiveUsageComposition.report(
            context: nil,
            items: [.user("a transcript without provider usage")]
        )

        #expect(report.sessionUsage == nil)
        #expect(!report.sessionUsageIsAuthoritative)
        #expect(report.estimatedSessionTokens > 0)
        #expect(LiveUsageComposition.render(report).contains("estimated this session"))
        #expect(
            LiveInteractiveControllerRenderer.sessionUsageBlockText(report: report)
                .contains("estimated this session")
        )
    }

    @Test("partial costs hide both aggregate and per-model ticks and lose authority")
    func partialCostsAreNeverPresentedAsComplete() async throws {
        let fixture = try LiveUsageReportingFixture()
        defer { fixture.cleanup() }

        let model = UsageTotals(
            inputTokens: 100,
            outputTokens: 25,
            cachedReadTokens: 35,
            modelCalls: 1,
            costUsdTicks: 2_100_000_001,
            cachedCreationTokens: 10
        )
        let usage = liveUsageSnapshot(
            totals: UsageTotals(
                inputTokens: 150,
                outputTokens: 40,
                cachedReadTokens: 35,
                modelCalls: 2,
                costUsdTicks: 4_200_000_001,
                costMissingCalls: 1,
                cachedCreationTokens: 10
            ),
            models: [("grok-metered", model)],
            mainLoopCalls: 2
        )
        let report = await LiveUsageComposition.report(
            context: nil,
            items: [],
            sessionUsage: usage
        )

        #expect(!report.sessionUsageIsAuthoritative)
        for text in [
            LiveUsageComposition.render(report),
            LiveInteractiveControllerRenderer.sessionUsageBlockText(report: report),
        ] {
            #expect(text.contains("Tokens:   190 provider-reported this session"))
            #expect(text.contains("cost reporting is incomplete"))
            #expect(!text.contains("4200000001"))
            #expect(!text.contains("2100000001"))
        }

        let block = await fixture.renderer.waveEUsageBlock(report)
        #expect(!block.sections.isEmpty)
        #expect(block.sections.allSatisfy { !$0.isAuthoritative })
        #expect(block.sections.allSatisfy { $0.unit != "USD" })
    }

    @Test("successful unmetered calls are incomplete rather than falsely free")
    func unmeteredCallsNeverPretendToUseZeroTokens() async throws {
        let fixture = try LiveUsageReportingFixture()
        defer { fixture.cleanup() }

        await fixture.history.beginUsagePrompt("unmetered-prompt")
        try await fixture.history.recordMainUsage(
            modelID: "grok-metered",
            usage: nil,
            costUsdTicks: nil
        )
        let report = await fixture.renderer.refreshUsageReport(
            context: nil,
            items: await fixture.history.items
        )

        #expect(report.sessionUsage?.incomplete == true)
        #expect(report.sessionUsage?.totals.modelCalls == 1)
        #expect(!report.hasMeasuredSessionUsage)
        #expect(!report.sessionUsageIsAuthoritative)
        let text = LiveUsageComposition.render(report)
        #expect(text.contains("Tokens:   unavailable (provider usage is incomplete)"))
        #expect(text.contains("Model calls: 1 (1 main-loop)"))
        #expect(!text.contains("0 provider-reported this session"))

        let block = await fixture.renderer.waveEUsageBlock(report)
        #expect(block.sections.count == 1)
        #expect(block.sections[0].used == 1)
        #expect(block.sections[0].unit == "model calls; token usage unavailable")
        #expect(!block.sections[0].isAuthoritative)
        await fixture.history.endUsagePrompt("unmetered-prompt")
    }

    @Test("real root and late child ledgers reach the provider-qualified pager block")
    func rootHistoryAndLateChildrenReachPager() async throws {
        let fixture = try LiveUsageReportingFixture()
        defer { fixture.cleanup() }

        await fixture.history.beginUsagePrompt("root-prompt")
        try await fixture.history.recordMainUsage(
            modelID: "grok-metered",
            usage: TokenUsage(
                promptTokens: 120,
                completionTokens: 30,
                totalTokens: 150,
                reasoningTokens: 5,
                cachedPromptTokens: 50,
                cacheCreationPromptTokens: 12
            ),
            costUsdTicks: 2_500_000_000
        )
        await fixture.history.endUsagePrompt("root-prompt")

        let folded = await fixture.history.foldSubagentUsage(
            byModel: [("codex-child", UsageTotals(
                inputTokens: 80,
                outputTokens: 20,
                cachedReadTokens: 25,
                reasoningTokens: 2,
                modelCalls: 1,
                costUsdTicks: 500_000_000,
                cachedCreationTokens: 8
            ))],
            parentPromptID: "root-prompt",
            incomplete: false
        )
        #expect(folded)

        let report = await fixture.renderer.refreshUsageReport(
            context: nil,
            items: await fixture.history.items
        )
        #expect(report.sessionUsageIsAuthoritative)
        #expect(report.sessionUsage?.totals.inputTokens == 200)
        #expect(report.sessionUsage?.totals.outputTokens == 50)
        #expect(report.sessionUsage?.totals.cachedReadTokens == 75)
        #expect(report.sessionUsage?.totals.cacheCreationTokens == 20)
        #expect(report.sessionUsage?.trustedCostUsdTicks == 3_000_000_000)
        #expect(report.sessionUsage?.unattributedPromptIDs == ["root-prompt"])
        #expect(report.sessionUsage?.incomplete == false)

        let text = LiveUsageComposition.render(report)
        #expect(text.contains("Late child usage: included in session totals"))
        #expect(!text.contains("Accounting: incomplete"))

        let block = await fixture.renderer.waveEUsageBlock(report)
        #expect(block.sections.contains {
            $0.unit == "session tokens" && $0.used == 250 && $0.isAuthoritative
        })
        #expect(block.sections.contains {
            $0.unit == "cache-read input tokens" && $0.used == 75
        })
        #expect(block.sections.contains {
            $0.unit == "cache-creation input tokens" && $0.used == 20
        })
        #expect(block.sections.contains {
            $0.unit == "USD" && $0.resetDescription == "3000000000 exact USD ticks"
        })
        #expect(block.sections.contains {
            $0.provider == .codex && $0.unit == "codex-child tokens" && $0.used == 100
        })
    }

    @Test("resumed histories retain provider totals instead of returning to estimates")
    func resumedHistoriesKeepProviderLedger() async throws {
        let fixture = try LiveUsageReportingFixture(sessionID: "resumed-provider-usage")
        defer { fixture.cleanup() }

        await fixture.history.beginUsagePrompt("persisted-prompt")
        try await fixture.history.recordMainUsage(
            modelID: "grok-metered",
            usage: TokenUsage(
                promptTokens: 75,
                completionTokens: 15,
                totalTokens: 90,
                cachedPromptTokens: 20,
                cacheCreationPromptTokens: 7
            ),
            costUsdTicks: 900_000_000
        )
        await fixture.history.endUsagePrompt("persisted-prompt")

        let saved = try await fixture.store.load(sessionID: "resumed-provider-usage")
        let resumed = LiveConversationHistory(record: saved, store: fixture.store)
        let snapshot = await resumed.usageSnapshot
        let report = await LiveUsageComposition.report(
            context: nil,
            items: await resumed.items,
            sessionUsage: snapshot
        )

        #expect(report.sessionUsageIsAuthoritative)
        #expect(report.sessionUsage?.totals.totalTokens == 90)
        #expect(report.sessionUsage?.totals.cachedReadTokens == 20)
        #expect(report.sessionUsage?.totals.cacheCreationTokens == 7)
        #expect(report.sessionUsage?.trustedCostUsdTicks == 900_000_000)
        #expect(!LiveUsageComposition.render(report).contains("estimated this session"))
    }
}
