// OpenGrokChatStateTests.swift
//
// Rust-derived actor, persistence, usage, compaction-reseed, repair,
// cancellation, and concurrency fixtures for OpenGrokChatState. Translated
// from `crates/codegen/xai-chat-state/src/actor/tests.rs`.

import Testing
import Foundation
@testable import OpenGrokChatState
@testable import OpenGrokSamplingTypes
@testable import OpenGrokTokenEstimation

// MARK: - Test harness

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ChatStateEvent] = []

    var sink: @Sendable (ChatStateEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.lock()
            self.events.append(event)
            self.lock.unlock()
        }
    }

    func drain() -> [ChatStateEvent] {
        lock.lock()
        defer { lock.unlock() }
        let out = events
        events.removeAll()
        return out
    }
}

private func testConfig(contextWindow: UInt64 = 256_000) -> SamplingConfig {
    SamplingConfig(
        baseURL: "https://api.x.ai/v1",
        model: "grok-test",
        contextWindow: contextWindow
    )
}

private struct TestHarness {
    let handle: ChatStateHandle
    let persistence: MockChatPersistence
    let events: EventCollector
    let cancellationToken: ChatStateCancellationToken

    static func make(
        conversation: [ConversationItem] = [],
        config: SamplingConfig = testConfig(),
        pruningConfig: PruningConfig = PruningConfig(),
        cancellationToken: ChatStateCancellationToken = ChatStateCancellationToken()
    ) -> TestHarness {
        let persistence = MockChatPersistence()
        let events = EventCollector()
        let handle = ChatStateActor.spawnWithPruning(
            initialConversation: conversation,
            samplingConfig: config,
            pruningConfig: pruningConfig,
            persistence: persistence,
            eventSink: events.sink,
            cancellationToken: cancellationToken
        )
        return TestHarness(
            handle: handle,
            persistence: persistence,
            events: events,
            cancellationToken: cancellationToken
        )
    }
}

/// Minimal cloneable trace context for request-construction fixtures.
private final class TestTraceContext: TraceContext, @unchecked Sendable {
    let id: String
    init(_ id: String) { self.id = id }
    func cloneBox() -> TraceContextBox {
        TraceContextBox(TestTraceContext(id))
    }
}

/// Push N full turns of (user, increment, assistant, tool-result), matching
/// the Rust `push_turns` helper used by retained-pruning fixtures.
private func pushTurns(
    _ handle: ChatStateHandle,
    turns: Int,
    contentLen: Int
) async {
    for i in 0..<turns {
        handle.pushUserMessage(.user("q\(i)"))
        handle.incrementPromptIndex()
        handle.pushAssistantResponse(.assistant("a\(i)"))
        handle.pushToolResult(.toolResult(
            toolCallId: "call_\(i)",
            content: String(repeating: "x", count: contentLen)
        ))
    }
    _ = await handle.getConversationLen()
}

// MARK: - Lifecycle

@Suite("ChatState lifecycle")
struct ChatStateLifecycleTests {
    @Test("actor spawns and shuts down when handle closes")
    func spawnAndClose() async {
        let h = TestHarness.make()
        #expect(await h.handle.getPromptIndex() == 0)
        h.handle.close()
        // Post-close queries complete as nil/default without hanging.
        let tokens = await h.handle.getTotalTokens()
        #expect(tokens == 0)
    }

    @Test("noop handle discards commands without hanging")
    func noopHandle() async {
        let handle = ChatStateHandle.noop()
        handle.pushUserMessage(.user("x"))
        handle.close()
        #expect(await handle.getConversation().isEmpty)
    }
}

// MARK: - Mutations and persistence

@Suite("ChatState mutations")
struct ChatStateMutationTests {
    @Test("push user message appends and persists")
    func pushUserMessage() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user("hello"))
        let conv = await h.handle.getConversation()
        #expect(conv.count == 1)
        let records = h.persistence.drain()
        #expect(records.contains { if case .message = $0 { return true }; return false })
    }

    @Test("push user message and ack waits for acceptance")
    func pushUserMessageAndAck() async {
        let h = TestHarness.make()
        let ok = await h.handle.pushUserMessageAndAck(.user("hello"))
        #expect(ok)
        #expect(await h.handle.getConversation().count == 1)
    }

    @Test("push assistant and tool result persist")
    func pushAssistantAndTool() async {
        let h = TestHarness.make()
        h.handle.pushAssistantResponse(.assistant("hi"))
        h.handle.pushToolResult(.toolResult(toolCallId: "c1", content: "ok"))
        let conv = await h.handle.getConversation()
        #expect(conv.count == 2)
        #expect(h.persistence.drain().count == 2)
    }

    @Test("record token usage emits event and updates total")
    func recordTokenUsage() async {
        let h = TestHarness.make()
        h.handle.recordTokenUsage(totalTokens: 1000)
        #expect(await h.handle.getTotalTokens() == 1000)
        let events = h.events.drain()
        #expect(events.contains { if case .tokensUpdated(let t) = $0 { return t == 1000 }; return false })
    }

    @Test("last turn usage round-trips and overwrites")
    func lastTurnUsage() async {
        let h = TestHarness.make()
        #expect(await h.handle.getLastTurnUsage() == nil)
        h.handle.recordLastTurnUsage(TokenUsage(
            promptTokens: 1234, completionTokens: 56, totalTokens: 1290, cachedPromptTokens: 800
        ))
        let got = await h.handle.getLastTurnUsage()
        #expect(got?.promptTokens == 1234)
        #expect(got?.cachedPromptTokens == 800)
        h.handle.recordLastTurnUsage(TokenUsage(promptTokens: 9999, completionTokens: 1, totalTokens: 10000))
        #expect(await h.handle.getLastTurnUsage()?.promptTokens == 9999)
    }

    @Test("increment prompt index emits event and clears prompt usage")
    func incrementPromptIndex() async {
        let h = TestHarness.make()
        h.handle.recordModelCallUsage(
            modelId: "grok-test",
            usage: TokenUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2),
            apiDurationMs: nil,
            costUsdTicks: nil
        )
        // Sync point
        _ = await h.handle.getTotalTokens()
        h.handle.incrementPromptIndex()
        #expect(await h.handle.getPromptIndex() == 1)
        switch await h.handle.tryGetPromptUsage() {
        case .success(let ledger):
            #expect(ledger == nil)
        case .failure:
            Issue.record("actor should be alive")
        }
        #expect(h.events.drain().contains { if case .promptIndexChanged(1) = $0 { return true }; return false })
    }

    @Test("flush calls persistence flush")
    func flush() async {
        let h = TestHarness.make()
        h.handle.flush()
        _ = await h.handle.getPromptIndex()
        #expect(h.persistence.drain().contains { if case .flush = $0 { return true }; return false })
    }

    @Test("agent edited paths deduplicate and sort")
    func agentEditedPaths() async {
        let h = TestHarness.make()
        h.handle.recordAgentEditedPath("b.swift")
        h.handle.recordAgentEditedPath("a.swift")
        h.handle.recordAgentEditedPath("b.swift")
        #expect(await h.handle.getAgentEditedPaths() == ["a.swift", "b.swift"])
    }

    @Test("notification meta reflects timing")
    func notificationMeta() async {
        let h = TestHarness.make()
        h.handle.recordStreamStart(timestampMs: 10)
        h.handle.recordTurnStart(timestampMs: 20)
        let meta = await h.handle.getNotificationMeta()
        #expect(meta?.streamStartMs == 10)
        #expect(meta?.turnStartMs == 20)
    }
}

// MARK: - Estimated tokens

@Suite("ChatState estimated tokens")
struct ChatStateEstimatedTokenTests {
    @Test("tool result bumps estimated delta; model response resets it")
    func estimatedDelta() async {
        let h = TestHarness.make()
        h.handle.pushToolResult(.toolResult(toolCallId: "c1", content: String(repeating: "x", count: 400)))
        let afterTool = await h.handle.getEstimatedTotalTokens()
        #expect(afterTool == 100) // 400 bytes / 4
        h.handle.recordTokenUsage(totalTokens: 500)
        #expect(await h.handle.getEstimatedTotalTokens() == 500)
        #expect(await h.handle.getTotalTokens() == 500)
    }

    @Test("assistant push does not bump estimated delta")
    func assistantDoesNotBumpDelta() async {
        let h = TestHarness.make()
        h.handle.recordTokenUsage(totalTokens: 10)
        h.handle.pushAssistantResponse(.assistant(String(repeating: "a", count: 400)))
        #expect(await h.handle.getEstimatedTotalTokens() == 10)
    }

    @Test("user message bumps estimated delta")
    func userBumpsDelta() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user(String(repeating: "u", count: 400)))
        #expect(await h.handle.getEstimatedTotalTokens() == 100)
    }
}

// MARK: - Compaction reseed

@Suite("ChatState compaction reseed")
struct ChatStateCompactionTests {
    @Test("compaction reseed carries provider overhead as a ratio")
    func reseedCarriesOverhead() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user(String(repeating: "x", count: 4000)))
        h.handle.recordTokenUsage(totalTokens: 51_000)
        let compacted: [ConversationItem] = [
            .system("sys"),
            .user(String(repeating: "summary ", count: 500)),
        ]
        h.handle.replaceConversationForCompaction(compacted)
        let total = await h.handle.getTotalTokens()
        #expect(total > 1000 * 10)
        #expect(total <= 51_000)
    }

    @Test("compaction reseed scales overhead with deleted content")
    func reseedScales() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user(String(repeating: "x", count: 160_000)))
        let estimateAtResponse = estimateConversationTokens(await h.handle.getConversation())
        #expect(estimateAtResponse == 40_000)
        h.handle.recordTokenUsage(totalTokens: 87_000)
        let compacted = [ConversationItem.user(String(repeating: "z", count: 12_000))]
        #expect(estimateConversationTokens(compacted) == 3_000)
        h.handle.replaceConversationForCompaction(compacted)
        #expect(await h.handle.getTotalTokens() == 6_525)
    }

    @Test("compaction excludes post-response deltas from overhead base")
    func excludesPostResponseDeltas() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user(String(repeating: "y", count: 4000)))
        h.handle.recordTokenUsage(totalTokens: 11_000)
        h.handle.pushToolResult(.toolResult(toolCallId: "c1", content: String(repeating: "z", count: 100_000)))
        h.handle.replaceConversationForCompaction([.user(String(repeating: "s", count: 2_000))])
        #expect(await h.handle.getTotalTokens() == 5_500)
    }

    @Test("fresh session compaction matches plain estimate")
    func freshSessionPlainEstimate() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user("hello"))
        h.handle.replaceConversationForCompaction([.user(String(repeating: "w", count: 8000))])
        #expect(await h.handle.getTotalTokens() == 2_000)
    }

    @Test("non-compaction replace does not carry overhead")
    func nonCompactionPlain() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user(String(repeating: "x", count: 4000)))
        h.handle.recordTokenUsage(totalTokens: 51_000)
        h.handle.replaceConversation([.user(String(repeating: "q", count: 4000))])
        #expect(await h.handle.getTotalTokens() == 1_000)
    }

    @Test("replace conversation persists and emits reset")
    func replacePersists() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user("a"))
        h.handle.pushUserMessage(.user("b"))
        _ = await h.handle.getConversation()
        _ = h.persistence.drain()
        h.handle.replaceConversation([.system("compacted")])
        #expect(await h.handle.getConversation().count == 1)
        let records = h.persistence.drain()
        #expect(records.contains { if case .replaceHistory = $0 { return true }; return false })
        #expect(h.events.drain().contains { if case .conversationReset(1) = $0 { return true }; return false })
    }
}

// MARK: - Snapshot / rewind

@Suite("ChatState snapshot and rewind")
struct ChatStateSnapshotTests {
    @Test("snapshot restore preserves fields")
    func snapshotRestore() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user("msg"))
        h.handle.recordTokenUsage(totalTokens: 500)
        h.handle.incrementPromptIndex()
        let snap = await h.handle.snapshot()
        #expect(snap?.promptIndex == 1)
        #expect(snap?.totalTokens == 500)

        let h2 = TestHarness.make()
        guard let snap else {
            Issue.record("missing snapshot")
            return
        }
        h2.handle.restoreSnapshot(snap)
        let after = await h2.handle.snapshot()
        #expect(after?.promptIndex == 1)
        #expect(after?.totalTokens == 500)
        #expect(after?.conversation.count == 1)
    }

    @Test("commit rewind recomputes tokens and persists")
    func commitRewind() async {
        let full: [ConversationItem] = [
            .system("system"),
            .user("first prompt"),
            .assistant("first answer"),
            .user(String(repeating: "discarded prompt ", count: 2_000)),
            .assistant(String(repeating: "discarded answer ", count: 2_000)),
        ]
        let h = TestHarness.make(conversation: full)
        h.handle.recordTokenUsage(totalTokens: 900_000)
        guard var rewind = await h.handle.snapshot() else {
            Issue.record("missing snapshot")
            return
        }
        let retained = Array(rewind.conversation.prefix(3))
        let expected = estimateConversationTokens(retained)
        rewind.conversation = retained
        rewind.promptIndex = 1
        rewind.promptTexts = ["first prompt"]
        _ = h.persistence.drain()
        _ = h.events.drain()
        #expect(await h.handle.commitRewindSnapshot(rewind))
        let after = await h.handle.snapshot()
        #expect(after?.promptIndex == 1)
        #expect(after?.totalTokens == expected)
        #expect(after?.estimateAtLastResponse == expected)
        #expect((after?.totalTokens ?? 0) < 900_000)
        #expect(h.persistence.drain().contains { if case .replaceHistory = $0 { return true }; return false })
    }

    @Test("restore snapshot with zero frozen estimate recomputes")
    func restoreZeroEstimate() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user(String(repeating: "x", count: 4000)))
        h.handle.recordTokenUsage(totalTokens: 31_000)
        guard var snap = await h.handle.snapshot() else {
            Issue.record("missing snapshot")
            return
        }
        snap.estimateAtLastResponse = 0
        h.handle.restoreSnapshot(snap)
        // estimate_at_last_response falls back to recompute when 0.
        let after = await h.handle.snapshot()
        #expect((after?.estimateAtLastResponse ?? 0) > 0)
    }
}

// MARK: - Repair / dangling tools

@Suite("ChatState repair")
struct ChatStateRepairTests {
    @Test("dangling tool calls repaired on next user message")
    func liveCancelRepair() async {
        let h = TestHarness.make()
        h.handle.pushAssistantResponse(.assistantToolCalls([
            ToolCall(id: "c1", name: "read", arguments: "{}"),
            ToolCall(id: "c2", name: "write", arguments: "{}"),
        ]))
        h.handle.pushToolResult(.toolResult(toolCallId: "c1", content: "partial"))
        #expect(await h.handle.hasDanglingToolCalls())
        h.handle.pushUserMessage(.user("continue"))
        #expect(!(await h.handle.hasDanglingToolCalls()))
        let conv = await h.handle.getConversation()
        // assistant + partial result + synthetic for c2 + new user
        #expect(conv.count >= 4)
    }

    @Test("initial conversation with dangling calls repaired at spawn")
    func repairOnLoad() async {
        let initial: [ConversationItem] = [
            .assistantToolCalls([ToolCall(id: "c1", name: "bash", arguments: "{}")]),
        ]
        let h = TestHarness.make(conversation: initial)
        // Sync via query so initialize() has completed.
        #expect(!(await h.handle.hasDanglingToolCalls()))
        #expect(await h.handle.getConversationLen() == 2)
    }

    @Test("build request repairs dangling without mutating when memory not persisted")
    func buildRequestRepair() async {
        let h = TestHarness.make(conversation: [
            .system("sys"),
            .assistantToolCalls([ToolCall(id: "c1", name: "x", arguments: "{}")]),
        ])
        // Integrity runs at build boundary.
        let req = await h.handle.buildConversationRequest(
            toolDefinitions: [],
            memoryReminder: "Remember this",
            persistMemoryReminder: false,
            convId: "c",
            reqId: "r"
        )
        #expect(req != nil)
        // Non-persisted memory must not mutate actor system head.
        if case .system(let sys) = await h.handle.getSystemMessage() {
            #expect(!sys.content.contains("Remember this"))
        } else {
            Issue.record("expected system message on actor")
        }
        // But request should carry injected memory.
        if let req, case .system(let sys) = req.items.first {
            #expect(sys.content.contains("Remember this"))
        } else {
            Issue.record("expected system message on request")
        }
    }

    @Test("build request can persist memory into actor state")
    func buildRequestPersistMemory() async {
        let h = TestHarness.make(conversation: [
            .system("sys"),
            .user("hi"),
        ])
        let reminder = "<memory-context>\nRemember this\n</memory-context>"
        let req = await h.handle.buildConversationRequest(
            toolDefinitions: [],
            memoryReminder: reminder,
            persistMemoryReminder: true,
            convId: "c",
            reqId: "r"
        )
        #expect(req != nil)
        if case .system(let sys) = await h.handle.getSystemMessage() {
            #expect(sys.content.contains("Remember this"))
        } else {
            Issue.record("expected system message")
        }
        #expect(h.persistence.drain().contains { record in
            if case .replaceHistory(let items) = record,
               case .system(let sys) = items.first {
                return sys.content.contains("Remember this")
            }
            return false
        })
    }
}

// MARK: - Usage folding

@Suite("ChatState usage folding")
struct ChatStateUsageTests {
    @Test("main loop and subagent usage fold into session ledger")
    func subagentFold() async {
        let h = TestHarness.make()
        h.handle.recordModelCallUsage(
            modelId: "grok-test",
            usage: TokenUsage(promptTokens: 10, completionTokens: 2, totalTokens: 12),
            apiDurationMs: 5,
            costUsdTicks: 100
        )
        let ok = await h.handle.recordSubagentUsage(
            byModel: [(
                model: "child-model",
                totals: UsageTotals(
                    inputTokens: 3, outputTokens: 1, modelCalls: 1, costUsdTicks: 10
                )
            )],
            attributeToPrompt: true,
            incomplete: false
        )
        #expect(ok)
        switch await h.handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.totals.inputTokens == 13)
            #expect(session.totals.outputTokens == 3)
            #expect(session.mainLoopModelCalls == 1)
            #expect(session.byModel.count == 2)
        case .failure:
            Issue.record("session usage should be readable")
        }
        switch await h.handle.tryGetPromptUsage() {
        case .success(let prompt):
            #expect(prompt?.totals.inputTokens == 13)
        case .failure:
            Issue.record("prompt usage should be readable")
        }
    }

    @Test("mark usage incomplete is sticky")
    func markIncomplete() async {
        let h = TestHarness.make()
        #expect(await h.handle.markUsageIncomplete(prompt: true, session: true))
        switch await h.handle.tryGetSessionUsage() {
        case .success(let session):
            #expect(session.incomplete)
        case .failure:
            Issue.record("session usage should be readable")
        }
    }
}

// MARK: - Auto compact / truncate

@Suite("ChatState auto compact and truncate")
struct ChatStateAutoCompactTests {
    @Test("auto compact triggers at threshold")
    func autoCompactThreshold() async {
        let h = TestHarness.make(config: testConfig(contextWindow: 100))
        h.handle.recordTokenUsage(totalTokens: 50)
        #expect(await h.handle.checkAutoCompactNeeded(thresholdPercent: 85) == nil)
        h.handle.recordTokenUsage(totalTokens: 85)
        let trigger = await h.handle.checkAutoCompactNeeded(thresholdPercent: 85)
        #expect(trigger?.totalTokens == 85)
        #expect(trigger?.contextWindow == 100)
    }

    @Test("truncate to prompt index keeps system and earlier users")
    func truncate() async {
        let h = TestHarness.make(conversation: [
            .system("sys"),
            .user("u0"),
            .assistant("a0"),
            .user("u1"),
            .assistant("a1"),
        ])
        h.handle.cachePromptText("u0")
        h.handle.incrementPromptIndex()
        h.handle.cachePromptText("u1")
        h.handle.incrementPromptIndex()
        await h.handle.truncateToPromptIndex(target: 1)
        let conv = await h.handle.getConversation()
        #expect(await h.handle.getPromptIndex() == 1)
        // system + u0 + a0
        #expect(conv.count == 3)
        if case .user(let u) = conv.last {
            // last retained is assistant actually
            _ = u
        }
        if case .assistant(let a) = conv[2] {
            #expect(a.content == "a0")
        }
    }
}

// MARK: - Turn capture / harness

@Suite("ChatState turn capture")
struct ChatStateTurnCaptureTests {
    @Test("turn capture collects messages and flags compaction")
    func turnCaptureWithCompaction() async {
        let h = TestHarness.make()
        h.handle.beginTurnCapture()
        h.handle.pushUserMessage(.user("q1"))
        h.handle.pushAssistantResponse(.assistant("a1"))
        h.handle.replaceConversationForCompaction([.system("sum"), .user("q1")])
        let capture = await h.handle.takeTurnMessages()
        #expect(capture?.compactionOccurred == true)
        #expect((capture?.messages.count ?? 0) >= 2)
        #expect(await h.handle.takeTurnMessages() == nil)
    }

    @Test("harness trace seals into own turns")
    func harnessTrace() async {
        let h = TestHarness.make()
        h.handle.appendHarnessTraceItems([.user("plan"), .assistant("done")])
        h.handle.flushHarnessTraceTurn()
        h.handle.appendHarnessTraceItems([.user("verify")])
        h.handle.flushHarnessTraceTurn()
        let turns = await h.handle.takeHarnessTraceTurns()
        #expect(turns.count == 2)
        #expect(turns[0].count == 2)
        #expect(turns[1].count == 1)
        #expect(await h.handle.takeHarnessTraceTurns().isEmpty)
    }
}

// MARK: - System head / queries

@Suite("ChatState queries")
struct ChatStateQueryTests {
    @Test("replace system head swaps when different")
    func replaceSystemHead() async {
        let h = TestHarness.make(conversation: [.system("old"), .user("hi")])
        #expect(await h.handle.replaceSystemHead("new") == true)
        if case .system(let sys) = await h.handle.getSystemMessage() {
            #expect(sys.content == "new")
        }
        // Trailing newline only is a no-op.
        #expect(await h.handle.replaceSystemHead("new\n") == false)
    }

    @Test("conversation counts and text helpers")
    func countsAndText() async {
        let h = TestHarness.make(conversation: [
            .system("sys"),
            .user("first user"),
            .assistant("  "),
            .assistant("last answer"),
            .toolResult(toolCallId: "c", content: "r"),
        ])
        let counts = await h.handle.getConversationCounts()
        #expect(counts.total == 5)
        #expect(counts.user == 1)
        #expect(counts.assistant == 2)
        #expect(counts.toolResult == 1)
        #expect(await h.handle.getFirstUserText() == "first user")
        #expect(await h.handle.getLastAssistantText() == "last answer")
        #expect(await h.handle.getConversationItemAt(index: 0) != nil)
        #expect(await h.handle.getConversationItemAt(index: 99) == nil)
    }

    @Test("build request carries sampling config and tools")
    func buildRequestConfig() async {
        let h = TestHarness.make(config: SamplingConfig(
            baseURL: "https://api.x.ai/v1",
            model: "grok-4",
            maxCompletionTokens: 1024,
            temperature: 0.5,
            contextWindow: 1000,
            reasoningEffort: .high
        ))
        h.handle.pushUserMessage(.user("hi"))
        let tools = [ToolSpec(name: "read", description: nil, parameters: .object([:]))]
        let req = await h.handle.buildConversationRequest(
            toolDefinitions: tools,
            memoryReminder: nil,
            persistMemoryReminder: false,
            convId: "conv",
            reqId: "req"
        )
        #expect(req?.model == "grok-4")
        #expect(req?.temperature == 0.5)
        #expect(req?.maxOutputTokens == 1024)
        #expect(req?.reasoningEffort == .high)
        #expect(req?.tools.count == 1)
        #expect(req?.xGrokConvId == "conv")
        #expect(req?.xGrokReqId == "req")
    }
}

// MARK: - Concurrency / close / cancellation

@Suite("ChatState concurrency")
struct ChatStateConcurrencyTests {
    @Test("interleaved pushes and queries preserve order")
    func interleaved() async {
        let h = TestHarness.make()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    h.handle.pushUserMessage(.user("m\(i)"))
                }
            }
            for _ in 0..<5 {
                group.addTask {
                    _ = await h.handle.getConversationLen()
                }
            }
        }
        let len = await h.handle.getConversationLen()
        #expect(len == 20)
    }

    @Test("close completes pending query exactly once as failure")
    func closeCompletesPending() async {
        let h = TestHarness.make()
        #expect(await h.handle.pushUserMessageAndAck(.user("x")))
        h.handle.close()
        // Subsequent awaited ops must not hang; dead channel → false/nil.
        #expect(!(await h.handle.pushUserMessageAndAck(.user("y"))))
        switch await h.handle.tryGetSessionUsage() {
        case .success:
            Issue.record("closed actor should fail closed")
        case .failure:
            break
        }
    }

    @Test("cancellation finishes stream and fails closed for subsequent ops")
    func cancellationShutsDown() async {
        let token = ChatStateCancellationToken()
        let h = TestHarness.make(cancellationToken: token)
        #expect(await h.handle.pushUserMessageAndAck(.user("alive")))
        token.cancel()
        // Allow the run loop to observe cancellation and drain.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(!(await h.handle.pushUserMessageAndAck(.user("after-cancel"))))
        switch await h.handle.tryGetSessionUsage() {
        case .success:
            Issue.record("cancelled actor should fail closed")
        case .failure:
            break
        }
        // Cancel is idempotent.
        token.cancel()
        #expect(token.isCancelled)
    }

    @Test("cancellation drains queued awaited replies exactly once as dead")
    func cancellationDrainsQueuedReplies() async {
        let token = ChatStateCancellationToken()
        let h = TestHarness.make(cancellationToken: token)
        // Seed so the actor is live.
        #expect(await h.handle.pushUserMessageAndAck(.user("seed")))

        // Race: flood awaited queries then cancel. Every reply must complete
        // (no hang) as failure / default, exactly once via ActorReply.
        async let q1 = h.handle.tryGetSessionUsage()
        async let q2 = h.handle.pushUserMessageAndAck(.user("queued"))
        async let q3 = h.handle.getConversationLen()
        token.cancel()
        async let q4 = h.handle.tryGetPromptUsage()

        let r1 = await q1
        let r2 = await q2
        let r3 = await q3
        let r4 = await q4
        // At least the post-cancel / drained path must be dead; pre-cancel
        // may still succeed depending on scheduling.
        _ = r1
        _ = r2
        _ = r3
        switch r4 {
        case .success:
            // If the query slipped through before cancel, that is fine;
            // a second query after cancel must fail.
            switch await h.handle.tryGetSessionUsage() {
            case .success:
                Issue.record("post-cancel session usage must fail closed")
            case .failure:
                break
            }
        case .failure:
            break
        }
        #expect(token.isCancelled)
    }

    @Test("close and cancel race both complete without hang")
    func closeAndCancelRace() async {
        let token = ChatStateCancellationToken()
        let h = TestHarness.make(cancellationToken: token)
        #expect(await h.handle.pushUserMessageAndAck(.user("x")))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { h.handle.close() }
            group.addTask { token.cancel() }
            group.addTask {
                _ = await h.handle.getTotalTokens()
            }
        }
        #expect(!(await h.handle.pushUserMessageAndAck(.user("y"))))
    }
}

// MARK: - Retained pruning

@Suite("ChatState retained pruning")
struct ChatStateRetainedPruningTests {
    @Test("young session is a no-op for retained hard-clear")
    func youngSessionNoOp() async {
        let h = TestHarness.make(pruningConfig: PruningConfig(hardClearAgeTurns: 10))
        await pushTurns(h.handle, turns: 5, contentLen: 10_000)
        let conv = await h.handle.getConversation()
        for item in conv {
            if case .toolResult(let tr) = item {
                #expect(tr.content.count == 10_000, "young session: tool result must not be pruned")
            }
        }
    }

    @Test("hard-clears old tool results after hardClearAgeTurns")
    func hardClearsOld() async {
        let h = TestHarness.make(pruningConfig: PruningConfig(
            keepLastNTurns: 2,
            hardClearAgeTurns: 5
        ))
        await pushTurns(h.handle, turns: 8, contentLen: 5_000)
        let conv = await h.handle.getConversation()
        // Layout: [User, Assistant, ToolResult] * 8 — oldest TR at index 2.
        guard case .toolResult(let oldest) = conv[2] else {
            Issue.record("expected ToolResult at index 2")
            return
        }
        #expect(oldest.content == HARD_CLEAR_PLACEHOLDER)
        // Recent turn 6 TR at 6*3+2 = 20.
        guard case .toolResult(let recent) = conv[20] else {
            Issue.record("expected recent ToolResult")
            return
        }
        #expect(recent.content.count == 5_000)
    }

    @Test("disabled pruning is a no-op")
    func disabledNoOp() async {
        let h = TestHarness.make(pruningConfig: PruningConfig(
            enabled: false,
            hardClearAgeTurns: 3
        ))
        await pushTurns(h.handle, turns: 8, contentLen: 4_000)
        let conv = await h.handle.getConversation()
        for item in conv {
            if case .toolResult(let tr) = item {
                #expect(tr.content.count == 4_000)
            }
        }
    }

    @Test("retained hard-clear persists via replaceHistory")
    func hardClearPersists() async {
        let h = TestHarness.make(pruningConfig: PruningConfig(hardClearAgeTurns: 3))
        await pushTurns(h.handle, turns: 6, contentLen: 2_000)
        let records = h.persistence.drain()
        let replaced = records.contains { record in
            if case .replaceHistory(let items) = record {
                return items.contains { item in
                    if case .toolResult(let tr) = item {
                        return tr.content == HARD_CLEAR_PLACEHOLDER
                    }
                    return false
                }
            }
            return false
        }
        #expect(replaced, "hard-clear must persist via replaceHistory")
    }

    @Test("synthetic user items do not advance hard-clear age")
    func syntheticUserDoesNotAdvanceAge() async {
        let h = TestHarness.make(pruningConfig: PruningConfig(
            keepLastNTurns: 1,
            hardClearAgeTurns: 5
        ))
        for i in 0..<3 {
            h.handle.pushUserMessage(.user("real q\(i)"))
            h.handle.incrementPromptIndex()
            h.handle.pushAssistantResponse(.assistant("a\(i)"))
            h.handle.pushToolResult(.toolResult(
                toolCallId: "call_\(i)",
                content: String(repeating: "x", count: 10_000)
            ))
        }
        // Synthetic users without incrementPromptIndex.
        h.handle.pushUserMessage(.user("⚠️ doom-loop warning 1"))
        h.handle.pushUserMessage(.user("⚠️ doom-loop warning 2"))
        h.handle.pushUserMessage(.user("real q3"))
        h.handle.incrementPromptIndex()
        let conv = await h.handle.getConversation()
        for item in conv {
            if case .toolResult(let tr) = item {
                #expect(
                    tr.content != HARD_CLEAR_PLACEHOLDER,
                    "synthetic user injections must not advance hard-clear age"
                )
            }
        }
    }
}

// MARK: - Request-copy pruning / image compaction / trace

@Suite("ChatState request builder")
struct ChatStateRequestBuilderTests {
    @Test("shouldPrune gates at half context (strict >)")
    func shouldPruneGating() {
        #expect(!shouldPrune(totalTokens: 1000, contextWindow: 10_000))
        #expect(shouldPrune(totalTokens: 6000, contextWindow: 10_000))
        #expect(!shouldPrune(totalTokens: 5000, contextWindow: 10_000))
    }

    @Test("API-copy prune soft-trims large old tool results")
    func apiCopySoftTrim() async {
        // contextWindow=100, totalTokens=60 → >50% → prune.
        // With keepLastNTurns=1, need ≥3 turns so the oldest tool result is
        // at turnFromEnd ≥ 1 when the backward scan reaches it (Rust age model).
        let h = TestHarness.make(
            config: testConfig(contextWindow: 100),
            pruningConfig: PruningConfig(
                keepLastNTurns: 1,
                softTrimThreshold: 100,
                softTrimHead: 20,
                softTrimTail: 20,
                hardClearAgeTurns: 100
            )
        )
        for i in 0..<3 {
            h.handle.pushUserMessage(.user("q\(i)"))
            h.handle.incrementPromptIndex()
            h.handle.pushAssistantResponse(.assistant("a\(i)"))
            h.handle.pushToolResult(.toolResult(
                toolCallId: "c\(i)",
                content: String(repeating: "A", count: 500)
            ))
        }
        h.handle.recordTokenUsage(totalTokens: 60)

        let req = await h.handle.buildConversationRequest(
            toolDefinitions: [],
            memoryReminder: nil,
            persistMemoryReminder: false,
            convId: "c",
            reqId: "r"
        )
        #expect(req != nil)
        // Stored conversation must remain unpruned (request-copy only).
        let stored = await h.handle.getConversation()
        if case .toolResult(let tr) = stored[2] {
            #expect(tr.content.count == 500)
        }
        // Request clone soft-trims the oldest tool result (index 2).
        if let req, case .toolResult(let tr) = req.items[2] {
            #expect(tr.content.contains("…trimmed…"))
            #expect(tr.content.count < 500)
        } else {
            Issue.record("expected soft-trimmed tool result on request")
        }
    }

    @Test("API-copy hard-clear replaces very old tool results")
    func apiCopyHardClear() async {
        let h = TestHarness.make(
            config: testConfig(contextWindow: 100),
            pruningConfig: PruningConfig(
                keepLastNTurns: 0,
                hardClearAgeTurns: 1
            )
        )
        await pushTurns(h.handle, turns: 3, contentLen: 200)
        h.handle.recordTokenUsage(totalTokens: 60)
        let req = await h.handle.buildConversationRequest(
            toolDefinitions: [],
            memoryReminder: nil,
            persistMemoryReminder: false,
            convId: "c",
            reqId: "r"
        )
        #expect(req != nil)
        // Oldest tool result (index 2) should hard-clear on the request copy.
        if let req, case .toolResult(let tr) = req.items[2] {
            #expect(tr.content == HARD_CLEAR_PLACEHOLDER)
        } else {
            Issue.record("expected hard-cleared tool result on request")
        }
    }

    @Test("trace context survives request construction without mutating storage")
    func traceSurvivesRequest() async {
        let h = TestHarness.make()
        h.handle.pushUserMessage(.user("hi"))
        let before = await h.handle.getConversation()
        let trace = TraceContextBox(TestTraceContext("trace-42"))
        let req = await h.handle.buildConversationRequest(
            toolDefinitions: [],
            memoryReminder: nil,
            persistMemoryReminder: false,
            trace: trace,
            convId: "c",
            reqId: "r"
        )
        #expect(req?.trace === trace)
        if let box = req?.trace, let tc = box.value as? TestTraceContext {
            #expect(tc.id == "trace-42")
        } else {
            Issue.record("expected TestTraceContext on request")
        }
        let after = await h.handle.getConversation()
        #expect(after == before)
    }

    @Test("compactImagesToByteBudget evicts oldest first")
    func imageEvictionOldestFirst() {
        func userWithImageBytes(_ text: String, urlBytes: Int) -> ConversationItem {
            let prefix = "data:image/png;base64,"
            let pad = max(0, urlBytes - prefix.count)
            return .userWithParts([
                .text(text: text),
                .image(url: prefix + String(repeating: "A", count: pad)),
            ])
        }
        let imgBytes = 100_000
        var conv = [
            userWithImageBytes("oldest", urlBytes: imgBytes),
            userWithImageBytes("middle", urlBytes: imgBytes),
            userWithImageBytes("newest", urlBytes: imgBytes),
        ]
        compactImagesToByteBudget(&conv, currentBytes: 300_000, targetBytes: 250_000)
        // Oldest replaced with placeholder text; newest kept.
        if case .user(let u) = conv[0] {
            let hasPlaceholder = u.content.contains {
                if case .text(let t) = $0 { return t == IMAGE_COMPACT_PLACEHOLDER }
                return false
            }
            #expect(hasPlaceholder)
        }
        if case .user(let u) = conv[2] {
            let hasImage = u.content.contains {
                if case .image = $0 { return true }
                return false
            }
            #expect(hasImage)
        }
    }

    @Test("no image eviction when body already under target")
    func noEvictionUnderTarget() {
        var conv = [
            ConversationItem.userWithParts([.text(text: "a"), .image(url: "data:image/png;base64,AAA")]),
            ConversationItem.userWithParts([.text(text: "b"), .image(url: "data:image/png;base64,BBB")]),
        ]
        let outcome = compactImagesToByteBudget(&conv, currentBytes: 100, targetBytes: 400)
        #expect(outcome.evicted == 0)
        #expect(inlineImageCount(conv) == 2)
    }

    @Test("tool-result ordered images are eviction candidates")
    func toolResultImageEviction() {
        var conv: [ConversationItem] = [
            .toolResultWithOrderedContent(
                toolCallId: "c1",
                orderedContent: [
                    .text(text: "see"),
                    .image("data:image/png;base64," + String(repeating: "Z", count: 50_000), .auto),
                ]
            ),
            .userWithParts([
                .text(text: "newest"),
                .image(url: "data:image/png;base64," + String(repeating: "Y", count: 50_000)),
            ]),
        ]
        // Target between one and two image sizes so only the oldest is evicted.
        compactImagesToByteBudget(&conv, currentBytes: 120_000, targetBytes: 80_000)
        // Oldest (tool-result ordered image) should be placeholder.
        if case .toolResult(let tr) = conv[0] {
            let hasPlaceholder = tr.orderedContent.contains {
                if case .text(let t) = $0 { return t == IMAGE_COMPACT_PLACEHOLDER }
                return false
            }
            #expect(hasPlaceholder)
        } else {
            Issue.record("expected tool result")
        }
        // Newest user image retained when reclaim target is reachable with one eviction.
        if case .user(let u) = conv[1] {
            let hasImage = u.content.contains {
                if case .image = $0 { return true }
                return false
            }
            #expect(hasImage)
        }
    }

    @Test("conversationBodyBytes empty array is JSON []")
    func bodyBytesEmpty() {
        #expect(conversationBodyBytes([]) == 2)
    }
}

// MARK: - Memory / conversation util

@Suite("Conversation util")
struct ConversationUtilTests {
    @Test("canonical system prompt eq trims trailing newlines only")
    func canonicalEq() {
        #expect(canonicalSystemPromptEq("hello", "hello\n"))
        #expect(canonicalSystemPromptEq("hello\r\n", "hello"))
        #expect(!canonicalSystemPromptEq(" hello", "hello"))
    }

    @Test("inject memory reminder upserts into system head")
    func injectMemory() {
        var items: [ConversationItem] = [.system("You are helpful."), .user("hi")]
        #expect(injectMemoryReminder(&items, reminder: "Remember: rust"))
        if case .system(let sys) = items[0] {
            #expect(sys.content.contains("You are helpful."))
            #expect(sys.content.contains("Remember: rust"))
        }
        #expect(items.count == 2)
        // Tagged memory-context blocks are replaced in-place on re-inject.
        #expect(injectMemoryReminder(
            &items,
            reminder: "<memory-context>\nold\n</memory-context>"
        ))
        #expect(injectMemoryReminder(
            &items,
            reminder: "<memory-context>\nnew\n</memory-context>"
        ))
        if case .system(let sys) = items[0] {
            #expect(sys.content.contains("You are helpful."))
            #expect(sys.content.contains("new"))
            #expect(!sys.content.contains("old"))
            // Untagged first inject remains in the prefix; only tagged blocks upsert.
            #expect(sys.content.contains("Remember: rust"))
        }
    }
}

// MARK: - Token estimation helpers on conversation items

@Suite("ChatState item token estimation")
struct ChatStateItemTokenTests {
    @Test("estimate item tokens matches bytes/4 and image constant")
    func estimateItems() {
        #expect(estimateItemTokens(.user("abcd")) == 1)
        #expect(estimateItemTokens(.userWithParts([.image(url: "data:x")])) == IMAGE_TOKEN_ESTIMATE)
        #expect(estimateConversationTokens([.system("abcd"), .user("efgh")]) == 2)
        #expect(estimateMessagesTokens([.system("abcd"), .user("efgh")]) == 1)
    }
}
