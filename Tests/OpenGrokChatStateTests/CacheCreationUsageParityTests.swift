import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokChatState

@Suite("Chat-state cache-creation usage parity")
struct CacheCreationUsageParityTests {
    private func makeHandle(initialSessionUsage: UsageLedger? = nil) -> ChatStateHandle {
        ChatStateActor.spawn(
            initialConversation: [],
            samplingConfig: SamplingConfig(
                baseURL: "https://api.example.invalid/v1",
                model: "claude-parent",
                contextWindow: 256_000
            ),
            initialSessionUsage: initialSessionUsage,
            persistence: MockChatPersistence()
        )
    }

    @Test("live actor preserves distinct read and creation buckets in prompt, session, and model ledgers")
    func liveActorPreservesCacheCreation() async throws {
        let handle = makeHandle()
        defer { handle.close() }

        handle.recordModelCallUsage(
            modelId: "claude-parent",
            usage: TokenUsage(
                promptTokens: 165,
                completionTokens: 11,
                totalTokens: 176,
                reasoningTokens: 4,
                cachedPromptTokens: 40,
                cacheCreationPromptTokens: 25
            ),
            apiDurationMs: 7,
            costUsdTicks: 100
        )

        let session = try await handle.tryGetSessionUsage().get()
        let prompt = try #require(try await handle.tryGetPromptUsage().get())
        let model = try #require(session.byModel.first)

        #expect(session.totals.inputTokens == 165)
        #expect(session.totals.outputTokens == 11)
        #expect(session.totals.totalTokens() == 176)
        #expect(session.totals.cachedReadTokens == 40)
        #expect(session.totals.cachedCreationTokens == 25)
        #expect(session.totals.reasoningTokens == 4)
        #expect(prompt.totals.cachedCreationTokens == 25)
        #expect(model.model == "claude-parent")
        #expect(model.totals.cachedReadTokens == 40)
        #expect(model.totals.cachedCreationTokens == 25)
    }

    @Test("subagent folds preserve cache creation per model without increasing main-agent turns")
    func subagentCacheCreationFoldsIntoSession() async throws {
        let handle = makeHandle()
        defer { handle.close() }

        handle.recordModelCallUsage(
            modelId: "claude-parent",
            usage: TokenUsage(
                promptTokens: 100,
                completionTokens: 10,
                totalTokens: 110,
                cachedPromptTokens: 20,
                cacheCreationPromptTokens: 12
            ),
            apiDurationMs: nil,
            costUsdTicks: nil
        )
        let applied = await handle.recordSubagentUsage(
            byModel: [(
                model: "claude-child",
                totals: UsageTotals(
                    inputTokens: 80,
                    outputTokens: 6,
                    cachedReadTokens: 30,
                    reasoningTokens: 3,
                    modelCalls: 2,
                    cachedCreationTokens: 18
                )
            )],
            attributeToPrompt: true,
            incomplete: false
        )
        #expect(applied)

        let session = try await handle.tryGetSessionUsage().get()
        let prompt = try #require(try await handle.tryGetPromptUsage().get())
        let parent = try #require(session.byModel.first { $0.model == "claude-parent" })
        let child = try #require(session.byModel.first { $0.model == "claude-child" })

        #expect(session.totals.inputTokens == 180)
        #expect(session.totals.outputTokens == 16)
        #expect(session.totals.totalTokens() == 196)
        #expect(session.totals.cachedReadTokens == 50)
        #expect(session.totals.cachedCreationTokens == 30)
        #expect(session.mainLoopModelCalls == 1)
        #expect(parent.totals.cachedCreationTokens == 12)
        #expect(child.totals.cachedCreationTokens == 18)
        #expect(prompt.totals.cachedCreationTokens == 30)
    }

    @Test("cache-creation ledger folding saturates independently of cache reads")
    func cacheCreationFoldingSaturates() async throws {
        let existing = UsageLedger(
            totals: UsageTotals(cachedCreationTokens: UInt64.max - 2),
            byModel: [(
                model: "claude-parent",
                totals: UsageTotals(cachedCreationTokens: UInt64.max - 2)
            )]
        )
        let handle = makeHandle(initialSessionUsage: existing)
        defer { handle.close() }

        handle.recordModelCallUsage(
            modelId: "claude-parent",
            usage: TokenUsage(
                promptTokens: 20,
                completionTokens: 1,
                totalTokens: 21,
                cachedPromptTokens: 4,
                cacheCreationPromptTokens: 8
            ),
            apiDurationMs: nil,
            costUsdTicks: nil
        )

        let session = try await handle.tryGetSessionUsage().get()
        let model = try #require(session.byModel.first)

        #expect(session.totals.cachedCreationTokens == UInt64.max)
        #expect(model.totals.cachedCreationTokens == UInt64.max)
        #expect(session.totals.cachedReadTokens == 4)
    }
}
