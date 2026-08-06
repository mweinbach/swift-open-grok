// CompactionEngineTests.swift
//
// Tests for the layer that turns the compaction primitives into something a
// session can call: threshold triggering, the local summarize-and-replace path,
// Codex Remote Compaction V2 replay fidelity, the truncation fallback, and a
// long-session simulation that asserts the session never reaches the context
// wall.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenGrokHTTP
// `@testable` reaches the SSE reassembler and the transport's frame decoding,
// which are internal on purpose: they are implementation detail of the HTTP
// leg, not part of the module's contract, but they are exactly where a
// malformed stream would silently drop the compaction item.
@testable import OpenGrokCompaction
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

// MARK: - Doubles

/// A sampler that returns a fixed summary, or fails a scripted number of times
/// before succeeding.
private struct ScriptedCompactionSampler: CompactionSampler, @unchecked Sendable {
    typealias Item = ConversationItem

    let summary: String
    var failure: CompactionSampleError?
    let calls = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() { lock.lock(); value += 1; lock.unlock() }
        /// Every turn the sampler saw, for replay-fidelity assertions.
        private var seen: [[ConversationItem]] = []
        func record(_ turns: [ConversationItem]) { lock.lock(); seen.append(turns); lock.unlock() }
        var recorded: [[ConversationItem]] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    func sampleCompaction(
        turns: [ConversationItem],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        calls.increment()
        calls.record(turns)
        if let failure { throw failure }
        return LLMCompactionOutput(response: summary)
    }
}

/// Replays a scripted Codex event stream, recording the request it was given so
/// a test can assert what went on the wire.
private final class ScriptedCodexTransport: CodexCompactionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[CodexCompactionStreamEvent]]
    private var failures: [CodexCompactionTransportError?]
    private var requests: [CodexCompactionRequest] = []

    init(
        scripts: [[CodexCompactionStreamEvent]],
        failures: [CodexCompactionTransportError?] = []
    ) {
        self.scripts = scripts
        self.failures = failures
    }

    var recordedRequests: [CodexCompactionRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    /// Non-async so the lock is never held across a suspension point, which
    /// Swift 6 rejects outright.
    private func nextScript(
        for request: CodexCompactionRequest
    ) -> (failure: CodexCompactionTransportError?, events: [CodexCompactionStreamEvent]) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return (
            failures.isEmpty ? nil : failures.removeFirst(),
            scripts.isEmpty ? [] : scripts.removeFirst()
        )
    }

    func send(
        _ request: CodexCompactionRequest,
        onEvent: @Sendable (CodexCompactionStreamEvent) async throws -> Void
    ) async throws {
        let (failure, script) = nextScript(for: request)
        if let failure { throw failure }
        for event in script {
            try await onEvent(event)
        }
    }
}

// MARK: - Fixtures

/// A conversation big enough to trip a 100k-token window at 85%.
private func longConversation(
    turns: Int,
    charactersPerTurn: Int = 20_000
) -> [ConversationItem] {
    var items: [ConversationItem] = [.system("You are Open Grok.")]
    for index in 0..<turns {
        items.append(.user("Question \(index): " + String(repeating: "q", count: charactersPerTurn)))
        items.append(.assistant(AssistantItem(
            content: "Answer \(index): " + String(repeating: "a", count: charactersPerTurn)
        )))
    }
    return items
}

/// Long enough to clear `MIN_SUMMARY_SEED_CHARS`, so it is not rejected as
/// degenerate before the assertions get a chance to run.
private let acceptableSummary = """
<summary>
1. Primary Request and Intent
The user asked for the compaction engine to be wired into the live turn loop so a long session survives the context window.
\(String(repeating: "Detail line preserved from the earlier conversation. ", count: 40))
</summary>
"""

private func makeBudget(window: UInt64 = 100_000, threshold: UInt8 = 85) -> CompactionBudget {
    resolveCompactionBudget(contextWindow: window, defaultThresholdPercent: threshold)
}

private func totalTokens(_ items: [ConversationItem]) -> UInt64 {
    UInt64(items.reduce(0) { $0 + $1.textContent().utf8.count / 4 })
}

// MARK: - Tests

@Suite("Compaction engine")
struct CompactionEngineTests {
    private func engine(
        sampler: ScriptedCompactionSampler,
        strategy: CompactionStrategy = .local,
        transport: (any CodexCompactionTransport)? = nil,
        window: UInt64 = 100_000,
        truncationFallbackEnabled: Bool = true,
        compactionsRemaining: UInt64? = nil
    ) -> CompactionEngine<ScriptedCompactionSampler> {
        var policy = CompactionPolicy()
        policy.enabled = true
        policy.mode = .fullReplace
        policy.maxAttempts = 1
        policy.retryDelayMilliseconds = 0
        return CompactionEngine(
            configuration: CompactionEngineConfiguration(
                policy: policy,
                budget: makeBudget(window: window),
                strategy: strategy,
                modelID: "test-model",
                compactionHash: "hash-abc",
                compactionsRemaining: compactionsRemaining,
                truncationFallbackEnabled: truncationFallbackEnabled
            ),
            sampler: sampler,
            codexTransport: transport
        )
    }

    // MARK: Threshold

    @Test("stays out of the way below the threshold and fires above it")
    func thresholdTrigger() async {
        let sampler = ScriptedCompactionSampler(summary: acceptableSummary)
        let small = longConversation(turns: 1, charactersPerTurn: 1_000)
        let large = longConversation(turns: 12, charactersPerTurn: 20_000)

        let under = await engine(sampler: sampler).compactIfNeeded(items: small, step: 10)
        guard case .notNeeded(let usage) = under else {
            Issue.record("a small conversation must not compact: \(under)")
            return
        }
        #expect(usage.percentUsed < 85)
        #expect(!usage.willCompactOnNextTurn)
        #expect(sampler.calls.count == 0)

        let over = await engine(sampler: sampler).compactIfNeeded(items: large, step: 10)
        guard case .compacted(let items, let report) = over else {
            Issue.record("a conversation past the threshold must compact: \(over)")
            return
        }
        #expect(report.kind == .local)
        #expect(!report.degraded)
        #expect(report.tokensAfter < report.tokensBefore)
        #expect(items.count < large.count)
        #expect(sampler.calls.count == 1)
    }

    @Test("usage readout agrees with the trigger decision")
    func usageReadout() {
        let sampler = ScriptedCompactionSampler(summary: acceptableSummary)
        let subject = engine(sampler: sampler)
        let items = longConversation(turns: 12, charactersPerTurn: 20_000)
        let usage = subject.usage(items: items, compactionCount: 2)

        #expect(usage.contextWindow == 100_000)
        #expect(usage.triggerTokenLimit == 85_000)
        #expect(usage.budgetSource == "default")
        #expect(usage.compactionCount == 2)
        #expect(usage.willCompactOnNextTurn)
        #expect(usage.usedTokens > usage.triggerTokenLimit)
        #expect(usage.remainingTokens == (usage.contextWindow > usage.usedTokens
            ? usage.contextWindow - usage.usedTokens
            : 0))
        #expect(usage.summaryLine.contains("compacted 2×"))
        // The trigger the engine actually consults must agree with the readout.
        #expect(subject.trigger(items: items, step: 10) != nil)
    }

    @Test("an operator token limit is enforced exactly, not as a rounded percentage")
    func operatorLimitIsExact() {
        // 37_777 of a 100_000 window is 37.777%, which truncates to 37% — a
        // percentage-only check would fire ~800 tokens early. The budget's token
        // limit is the authority.
        var policy = CompactionPolicy()
        policy.enabled = true
        policy.mode = .fullReplace
        let subject = CompactionEngine(
            configuration: CompactionEngineConfiguration(
                policy: policy,
                budget: resolveCompactionBudget(
                    contextWindow: 100_000,
                    explicitTokenLimit: 37_777
                ),
                modelID: "test-model"
            ),
            sampler: ScriptedCompactionSampler(summary: acceptableSummary)
        )
        // ~37.4k tokens: past the truncated 37% line, short of the real limit.
        let justUnder = [ConversationItem.user(String(repeating: "x", count: 149_800))]
        #expect(subject.usage(items: justUnder).usedTokens > 37_000)
        #expect(subject.usage(items: justUnder).usedTokens < 37_777)
        #expect(subject.trigger(items: justUnder, step: 10) == nil)

        let justOver = [ConversationItem.user(String(repeating: "x", count: 200_000))]
        #expect(subject.trigger(items: justOver, step: 10) != nil)
    }

    // MARK: Local path

    @Test("the local path keeps the system prompt, the newest turns and the user's questions")
    func localCompaction() async {
        let sampler = ScriptedCompactionSampler(summary: acceptableSummary)
        let items = longConversation(turns: 12, charactersPerTurn: 20_000)
        let outcome = await engine(sampler: sampler).compact(items: items)

        guard case .compacted(let replacement, let report) = outcome else {
            Issue.record("expected a local compaction: \(outcome)")
            return
        }
        #expect(report.kind == .local)

        // The system prompt survives — losing it would silently change the
        // agent's behavior mid-session.
        guard case .system = replacement.first else {
            Issue.record("compacted history must open with the system message")
            return
        }
        #expect(replacement[0].textContent().contains("You are Open Grok."))

        // The summary is present and carries the model's text.
        let joined = replacement.map { $0.textContent() }.joined(separator: "\n")
        #expect(joined.contains("This session is being continued"))
        #expect(joined.contains("compaction engine to be wired"))
        // Every user question from the compacted span is preserved in the
        // preamble, so nothing the user asked is lost even though the turns are.
        #expect(joined.contains("<grok_user_queries>"))
        #expect(joined.contains("Question 0"))
        // The newest turns are replayed verbatim rather than summarized.
        #expect(joined.contains("Question 11"))
        // And the summarizer never saw the system prompt.
        let summarized = sampler.calls.recorded.first ?? []
        #expect(!summarized.contains { if case .system = $0 { return true } else { return false } })
    }

    @Test("a summary that barely shrinks anything is refused rather than committed")
    func reductionGuard() async {
        // A summary as long as the conversation is not a compaction; upstream
        // rejects it so the next turn does not immediately trip again.
        // Long enough that the replacement lands above 80% of the original —
        // `maxReductionRatio` defaults to 0.8, so a merely large summary still
        // counts as a real compaction.
        let bloated = String(repeating: "Everything that happened, verbatim. ", count: 8_000)
        let sampler = ScriptedCompactionSampler(summary: bloated)
        let items = longConversation(turns: 12, charactersPerTurn: 20_000)
        let outcome = await engine(sampler: sampler).compact(items: items)

        guard case .compacted(_, let report) = outcome else {
            Issue.record("expected the truncation fallback: \(outcome)")
            return
        }
        #expect(report.kind == .truncation)
        #expect(report.degraded)
        #expect(report.detail?.contains("reduce") == true)
    }

    // MARK: Codex

    @Test("Codex V2 replays the encrypted item exactly and sends the contract hash")
    func codexReplayFidelity() async {
        let encrypted = "gAAAAABm-opaque-ciphertext-that-must-not-be-rewritten"
        let raw = JSONValue.object([
            "id": .string("comp_1"),
            "type": .string("compaction"),
            "encrypted_content": .string(encrypted),
        ])
        let item = CodexCompactionOutputItem(
            id: "comp_1",
            type: "compaction",
            raw: raw,
            encryptedContent: encrypted
        )
        let transport = ScriptedCodexTransport(scripts: [[
            .unrelated(type: "response.created"),
            .outputItemDone(item),
            .responseCompleted,
        ]])
        let sampler = ScriptedCompactionSampler(summary: acceptableSummary)
        let items = longConversation(turns: 12, charactersPerTurn: 20_000)

        let outcome = await engine(
            sampler: sampler,
            strategy: .codexRemoteV2,
            transport: transport
        ).compact(items: items)

        guard case .compacted(let replacement, let report) = outcome else {
            Issue.record("expected a Codex compaction: \(outcome)")
            return
        }
        #expect(report.kind == .codexRemoteV2)
        // The local summarizer must not have run: the server owns the summary.
        #expect(sampler.calls.count == 0)

        // The request carried the protocol's required fields.
        let request = transport.recordedRequests.first
        #expect(request?.protocolVersion == .remoteV2)
        #expect(request?.compactionTrigger == true)
        #expect(request?.compactionHash == "hash-abc")
        #expect(request?.endpointPath == "/responses")
        #expect(request?.headers.first?.name == "x-codex-beta-features")
        #expect(request?.headers.first?.value == "remote_compaction_v2")

        // The opaque item is replayed byte-identically as the final history
        // entry. Reformatting it in any way makes the server reject the next
        // turn, so this assertion is the whole point of the path.
        guard case .backendToolCall(let carrier) = replacement.last else {
            Issue.record("the compaction item must be the last history entry")
            return
        }
        guard case .codexRawInput(let rawInput) = carrier.kind else {
            Issue.record("the compaction item must be replayed as a raw Codex input")
            return
        }
        #expect(rawInput.id == "comp_1")
        #expect(rawInput.raw == raw)
        // A bounded tail of real user turns rides in front of it.
        #expect(replacement.count > 1)
        #expect(replacement.dropLast().allSatisfy {
            if case .user = $0 { return true } else { return false }
        })
    }

    @Test("legacy unary is an explicit option, not a fallback")
    func codexLegacyProtocol() async {
        let raw = JSONValue.object(["id": .string("comp_legacy"), "type": .string("compaction")])
        let transport = ScriptedCodexTransport(scripts: [[
            .outputItemDone(CodexCompactionOutputItem(id: "comp_legacy", raw: raw)),
            .responseCompleted,
        ]])
        let outcome = await engine(
            sampler: ScriptedCompactionSampler(summary: acceptableSummary),
            strategy: .codexLegacyUnary,
            transport: transport
        ).compact(items: longConversation(turns: 12, charactersPerTurn: 20_000))

        guard case .compacted(_, let report) = outcome else {
            Issue.record("expected a legacy Codex compaction: \(outcome)")
            return
        }
        #expect(report.kind == .codexLegacyUnary)
        #expect(transport.recordedRequests.first?.endpointPath == "/responses/compact")
        // The beta header belongs to V2 only.
        #expect(transport.recordedRequests.first?.headers.isEmpty == true)
        // Never sets the trigger flag: the legacy endpoint infers it from the path.
        #expect(transport.recordedRequests.first?.compactionTrigger == false)
    }

    @Test("provider selection routes Codex to the server and everything else locally")
    func strategySelection() {
        #expect(CompactionStrategy.forProvider(.codex) == .codexRemoteV2)
        #expect(CompactionStrategy.forProvider(.codex, remoteV2Enabled: false) == .codexLegacyUnary)
        #expect(CompactionStrategy.forProvider(.xai) == .local)
        #expect(CompactionStrategy.forProvider(.kimi) == .local)
        #expect(CompactionStrategy.forProvider(.fireworks) == .local)
        // A non-Codex provider never asks for the beta protocol, even if the
        // remote flag is on.
        #expect(CompactionStrategy.forProvider(.xai, remoteV2Enabled: true) == .local)
    }

    @Test("an exhausted server compaction budget skips the remote call")
    func codexCompactionLimit() async {
        let transport = ScriptedCodexTransport(scripts: [])
        let outcome = await engine(
            sampler: ScriptedCompactionSampler(summary: acceptableSummary),
            strategy: .codexRemoteV2,
            transport: transport,
            compactionsRemaining: 0
        ).compact(items: longConversation(turns: 12, charactersPerTurn: 20_000))

        guard case .compacted(_, let report) = outcome else {
            Issue.record("expected the truncation fallback: \(outcome)")
            return
        }
        #expect(report.degraded)
        #expect(report.detail?.contains("no server compactions left") == true)
        // The point of the check: no call was spent on a request that would be
        // rejected.
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("Codex retries a transient failure and stops on a deterministic one")
    func codexRetries() async {
        let raw = JSONValue.object(["id": .string("comp_r"), "type": .string("compaction")])
        let success: [CodexCompactionStreamEvent] = [
            .outputItemDone(CodexCompactionOutputItem(id: "comp_r", raw: raw)),
            .responseCompleted,
        ]
        let retrying = ScriptedCodexTransport(
            scripts: [[], success],
            failures: [.http(status: 503, message: "upstream unavailable"), nil]
        )
        let result = try? await runCodexRemoteCompaction(
            transport: retrying,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [])
        )
        #expect(result?.attempts == 2)

        let refusing = ScriptedCodexTransport(
            scripts: [[]],
            failures: [.http(status: 400, message: "invalid comp_hash")]
        )
        await #expect(throws: CodexCompactionTransportError.self) {
            try await runCodexRemoteCompaction(
                transport: refusing,
                request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [])
            )
        }
        #expect(refusing.recordedRequests.count == 1)
    }

    // MARK: Fallback

    @Test("a failed summary degrades to bounded truncation with an explicit notice")
    func failureFallback() async {
        var sampler = ScriptedCompactionSampler(summary: acceptableSummary)
        sampler.failure = .api(status: 500, message: "summarizer exploded")
        let items = longConversation(turns: 12, charactersPerTurn: 20_000)

        let outcome = await engine(sampler: sampler).compact(items: items)
        guard case .compacted(let replacement, let report) = outcome else {
            Issue.record("a failed summary must still shrink the history: \(outcome)")
            return
        }
        #expect(report.kind == .truncation)
        #expect(report.degraded)
        #expect(report.tokensAfter < report.tokensBefore)
        // The notice has to say information was dropped rather than summarized;
        // a user who is told "compacted" would not know to re-supply context.
        #expect(report.notice.contains("oldest turns were dropped"))
        #expect(report.notice.contains("summarizer exploded") || report.detail != nil)
        // Truncation still keeps the system prompt and the newest turn.
        #expect(replacement.first.map { if case .system = $0 { return true } else { return false } } == true)
        #expect(replacement.last?.textContent().contains("Answer 11") == true)
    }

    @Test("with the fallback disabled the failure is reported instead of hidden")
    func fallbackCanBeDisabled() async {
        var sampler = ScriptedCompactionSampler(summary: acceptableSummary)
        sampler.failure = .api(status: 500, message: "summarizer exploded")
        let outcome = await engine(
            sampler: sampler,
            truncationFallbackEnabled: false
        ).compact(items: longConversation(turns: 12, charactersPerTurn: 20_000))

        guard case .unableToCompact(let reason) = outcome else {
            Issue.record("expected an explicit failure: \(outcome)")
            return
        }
        #expect(reason.contains("summarizer exploded"))
    }

    @Test("bounded truncation never orphans a tool result and never drops the newest turn")
    func truncationShape() {
        var items: [ConversationItem] = [.system("system")]
        for index in 0..<40 {
            items.append(.user("user \(index) " + String(repeating: "u", count: 4_000)))
            items.append(.assistant(AssistantItem(
                content: "assistant \(index)",
                toolCalls: [ToolCall(id: "call-\(index)", name: "read", arguments: "{}")]
            )))
            items.append(.toolResult(ToolResultItem(
                toolCallId: "call-\(index)",
                content: "result \(index) " + String(repeating: "r", count: 4_000)
            )))
        }
        guard let truncated = boundedTruncationHistory(items: items, targetTokens: 5_000) else {
            Issue.record("truncation must produce a shorter history")
            return
        }
        #expect(truncated.count < items.count)
        #expect(validateCompactedHistory(truncated).isValid)
        #expect(truncated.first.map { if case .system = $0 { return true } else { return false } } == true)
        #expect(truncated.last?.textContent().contains("result 39") == true)

        // Nothing left to drop: a single-item history cannot be truncated, and
        // saying so beats returning an unchanged array that looks like progress.
        #expect(boundedTruncationHistory(items: [.system("only")], targetTokens: 1) == nil)
    }

    // MARK: Long session

    @Test("a long session compacts repeatedly and never reaches the context wall")
    func longSessionNeverHitsTheWall() async {
        let sampler = ScriptedCompactionSampler(summary: acceptableSummary)
        let subject = engine(sampler: sampler)
        let window: UInt64 = 100_000

        var items: [ConversationItem] = [.system("You are Open Grok.")]
        var compactions = 0
        var peakTokens: UInt64 = 0

        // 60 turns of ~10k tokens each against a 100k window: without
        // compaction this exceeds the window roughly six times over.
        for turn in 0..<60 {
            items.append(.user("Question \(turn): " + String(repeating: "q", count: 20_000)))
            items.append(.assistant(AssistantItem(
                content: "Answer \(turn): " + String(repeating: "a", count: 20_000)
            )))

            switch await subject.compactIfNeeded(
                items: items,
                step: UInt32(turn),
                compactionCount: UInt64(compactions)
            ) {
            case .compacted(let replacement, let report):
                #expect(!report.degraded, "turn \(turn) should compact, not truncate")
                items = replacement
                compactions += 1
            case .notNeeded:
                break
            case .unableToCompact(let reason):
                Issue.record("turn \(turn) could not compact: \(reason)")
            }

            let used = totalTokens(items)
            peakTokens = max(peakTokens, used)
            // The invariant this whole feature exists for.
            #expect(used < window, "turn \(turn) exceeded the context window at \(used) tokens")
        }

        #expect(compactions > 1, "a 60-turn session should compact more than once")
        #expect(peakTokens < window)
    }

    @Test("a long session survives even when every summary attempt fails")
    func longSessionSurvivesTotalSummarizerFailure() async {
        var sampler = ScriptedCompactionSampler(summary: acceptableSummary)
        sampler.failure = .api(status: 500, message: "summarizer is down")
        let subject = engine(sampler: sampler)
        let window: UInt64 = 100_000

        var items: [ConversationItem] = [.system("You are Open Grok.")]
        var degradations = 0

        for turn in 0..<40 {
            items.append(.user("Question \(turn): " + String(repeating: "q", count: 20_000)))
            items.append(.assistant(AssistantItem(
                content: "Answer \(turn): " + String(repeating: "a", count: 20_000)
            )))
            if case .compacted(let replacement, let report) = await subject.compactIfNeeded(
                items: items,
                step: UInt32(turn)
            ) {
                items = replacement
                if report.degraded { degradations += 1 }
            }
            #expect(totalTokens(items) < window, "turn \(turn) exceeded the window")
        }

        #expect(degradations > 0, "a dead summarizer must exercise the truncation fallback")
    }
}

// MARK: - SSE transport

@Suite("Codex compaction SSE transport")
struct CodexCompactionSSETests {
    @Test("a frame split across chunks decodes once, whole")
    func reassemblesSplitFrames() {
        var parser = ServerSentEventParser()
        #expect(parser.consume(Data("data: {\"type\":\"resp".utf8)).isEmpty)
        let frames = parser.consume(Data("onse.completed\"}\n\n".utf8))
        #expect(frames == ["{\"type\":\"response.completed\"}"])
        #expect(HTTPCodexCompactionTransport.decode(frames[0]) == .responseCompleted)
    }

    @Test("multi-line data fields join with newlines rather than decoding separately")
    func joinsMultiLineData() {
        var parser = ServerSentEventParser()
        // Field lines carry no leading whitespace, per the SSE grammar — the
        // optional space belongs after the colon, not before the field name.
        let frames = parser.consume(Data("data: {\"type\":\ndata: \"response.completed\"}\n\n".utf8))
        #expect(frames == ["{\"type\":\n\"response.completed\"}"])
        #expect(HTTPCodexCompactionTransport.decode(frames[0]) == .responseCompleted)
    }

    @Test("a CRLF stream is framed correctly, not buffered until the connection closes")
    func handlesCRLFFraming() {
        // Real servers and proxies terminate SSE events with CRLF. Scanning only
        // for "\n\n" finds no boundary in "\r\n\r\n" at all, so every event
        // accumulates and the response emerges from finish() as one malformed
        // payload — silent, and only against production.
        var parser = ServerSentEventParser()
        let frames = parser.consume(Data(
            "data: {\"type\":\"response.completed\"}\r\n\r\ndata: [DONE]\r\n\r\n".utf8
        ))
        #expect(frames == ["{\"type\":\"response.completed\"}", "[DONE]"])
        #expect(HTTPCodexCompactionTransport.decode(frames[0]) == .responseCompleted)
        // Nothing should be left waiting for a terminator.
        #expect(parser.finish().isEmpty)
    }

    @Test("CRLF multi-line data fields join the same way LF ones do")
    func joinsCRLFMultiLineData() {
        var parser = ServerSentEventParser()
        let frames = parser.consume(Data(
            "data: {\"type\":\r\ndata: \"response.completed\"}\r\n\r\n".utf8
        ))
        #expect(frames == ["{\"type\":\n\"response.completed\"}"])
        #expect(HTTPCodexCompactionTransport.decode(frames[0]) == .responseCompleted)
    }

    @Test("a comment keepalive does not terminate or corrupt the frame around it")
    func ignoresCommentLines() {
        // `:` comment lines are how servers keep an idle SSE connection warm.
        // They are not `data:` fields and must not contribute to the payload.
        var parser = ServerSentEventParser()
        let frames = parser.consume(Data(
            ": keepalive\ndata: {\"type\":\"response.completed\"}\nevent: message\n\n".utf8
        ))
        #expect(frames == ["{\"type\":\"response.completed\"}"])
    }

    @Test("a trailing frame with no blank-line terminator is still delivered")
    func flushesTrailingFrame() {
        var parser = ServerSentEventParser()
        #expect(parser.consume(Data("data: {\"type\":\"response.completed\"}".utf8)).isEmpty)
        #expect(parser.finish() == ["{\"type\":\"response.completed\"}"])
    }

    @Test("keepalives and the DONE sentinel are dropped, unknown events are not")
    func ignoresNonProtocolFrames() {
        #expect(HTTPCodexCompactionTransport.decode("[DONE]") == nil)
        #expect(HTTPCodexCompactionTransport.decode("   ") == nil)
        #expect(HTTPCodexCompactionTransport.decode("not json") == nil)
        #expect(
            HTTPCodexCompactionTransport.decode("{\"type\":\"response.output_text.delta\"}")
                == .unrelated(type: "response.output_text.delta")
        )
    }

    @Test("the request body carries Responses-shaped input, not the on-disk item encoding")
    func wireBodyShape() throws {
        let transport = HTTPCodexCompactionTransport(
            transport: URLSessionHTTPTransport(),
            baseURL: "https://chatgpt.com/backend-api/codex",
            model: "gpt-5-codex",
            headers: [:]
        )
        let request = CodexCompactionRequest(
            protocolVersion: .remoteV2,
            input: [.system("sys"), .user("hello")],
            compactionHash: "hash-abc"
        )
        let body = try transport.encodeBody(request)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("the body must be a JSON object")
            return
        }

        #expect(object["model"] as? String == "gpt-5-codex")
        #expect(object["stream"] as? Bool == true)
        #expect(object["compaction_trigger"] as? Bool == true)
        #expect(object["comp_hash"] as? String == "hash-abc")

        // The history must be the Responses `input` array of typed messages —
        // `ConversationItem`'s own Codable form is the session-file encoding and
        // would be rejected. This is the assertion that keeps the two apart.
        guard let input = object["input"] as? [[String: Any]] else {
            Issue.record("input must be an array of Responses messages")
            return
        }
        // The Codex adapter hoists leading system messages into `instructions`
        // (`OpenGrokSampler/Provider.swift:696`, "extract leading system
        // instructions to `instructions`"), exactly as it does for a normal
        // turn — which is the point of reusing the projection rather than
        // hand-rolling a body here. So one input message, not two, and the
        // system text is not lost but relocated.
        #expect(object["instructions"] as? String == "sys")
        // `#require` rather than `#expect`: a shape mismatch must fail this
        // test, never trap on an out-of-range index and abort the whole run.
        try #require(input.count == 1)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "user")
        #expect(input[0]["content"] as? String == "hello")
    }

    @Test("an error body is reported with the server's message, not the raw JSON")
    func extractsErrorMessage() {
        let body = Data("{\"error\":{\"message\":\"comp_hash is stale\"}}".utf8)
        #expect(HTTPCodexCompactionTransport.errorMessage(from: body) == "comp_hash is stale")
        #expect(HTTPCodexCompactionTransport.errorMessage(from: Data()) == "empty error body")
    }

    @Test("transport errors classify so the retry policy can act on them")
    func errorClassification() {
        #expect(CodexCompactionTransportError.authentication(status: 401).retryCause
            == .authentication(status: 401))
        #expect(CodexCompactionTransportError.http(status: 503, message: "busy").retryCause == .transient)
        #expect(CodexCompactionTransportError.http(status: 400, message: "bad").retryCause == .deterministic)
        #expect(CodexCompactionTransportError.http(status: 429, message: "slow down").retryCause == .transient)
        #expect(CodexCompactionTransportError.cancelled.retryCause == .cancelled)
    }
}

@Suite("Context usage formatting")
struct ContextUsageFormattingTests {
    @Test("token counts render at the scale a status line has room for")
    func tokenFormatting() {
        #expect(formatTokenCount(999) == "999")
        #expect(formatTokenCount(128_000) == "128k")
        #expect(formatTokenCount(2_000_000) == "2.0M")
    }

    @Test("the readout truncates rather than rounds")
    func percentTruncates() {
        let usage = ContextUsage(
            modelID: "m",
            usedTokens: 99_999,
            contextWindow: 100_000,
            triggerTokenLimit: 85_000,
            targetTokenLimit: 50_000,
            budgetSource: "default"
        )
        // 99.999% must not read as 100% — a full window and a nearly full one
        // call for different user action.
        #expect(usage.percentUsed == 99)
        #expect(usage.willCompactOnNextTurn)
        #expect(usage.summaryLine.contains("auto-compact at 85k"))
    }
}
