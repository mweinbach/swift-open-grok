import Foundation
@testable import OpenGrokCLI
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShellBase
import Testing

/// Wave A live-seam holes: `tool_outcomes` must survive `save`/`loadIfPresent`,
/// and `LocalShellProcessBackend.run(_:onChunk:)` must deliver stdout before
/// the final result. In-memory seed alone cannot catch either.
@Suite("Wave A persist and stream")
struct WaveAPersistAndStreamTests {
    @Test("save/load keeps mixed tool outcomes and seed matches the map")
    func persistRestoresToolOutcomes() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        var outcomes = ToolCallOutcomeMap()
        outcomes.upsert(callID: "ok", outcome: .succeeded)
        outcomes.upsert(callID: "boom", outcome: .failed, detail: "exit code 7")
        outcomes.upsert(callID: "stop", outcome: .cancelled)
        outcomes.upsert(callID: "deny", outcome: .denied, detail: "Tool bash was not executed: denied")
        outcomes.upsert(callID: "wait", outcome: .pending)

        let items = persistConversationItems()
        var record = LiveConversationRecord.new(
            sessionID: "wave-a-persist",
            workingDirectory: home
        )
        record.items = items
        record.toolOutcomes = outcomes
        record.everUsedNonXAI = false

        let store = LiveConversationStore(openGrokHome: home)
        try await store.save(record)

        let diskURL = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("wave-a-persist.json")
        let raw = try String(contentsOf: diskURL, encoding: .utf8)
        #expect(raw.contains("\"tool_outcomes\""))
        #expect(raw.contains("\"denied\""))
        #expect(raw.contains("exit code 7"))

        let loaded = try await store.loadIfPresent(sessionID: "wave-a-persist")
        #expect(loaded != nil)
        guard let loaded else { return }

        #expect(loaded.toolOutcomes?.outcome(for: "ok") == .succeeded)
        #expect(loaded.toolOutcomes?.outcome(for: "boom") == .failed)
        #expect(loaded.toolOutcomes?.record(for: "boom")?.detail == "exit code 7")
        #expect(loaded.toolOutcomes?.outcome(for: "stop") == .cancelled)
        #expect(loaded.toolOutcomes?.outcome(for: "deny") == .denied)
        #expect(loaded.toolOutcomes?.outcome(for: "wait") == .pending)
        #expect(loaded.toolOutcomes?.outcome(for: "orphan") == nil)

        var conversation = LivePagerConversationState()
        conversation.seed(
            from: loaded.items,
            toolOutcomes: loaded.toolOutcomes ?? ToolCallOutcomeMap()
        )
        let tools = conversation.items.compactMap { item -> PagerToolCard? in
            if case .tool(let card) = item { return card }
            return nil
        }
        #expect(tools.count == 5)

        let byInput = Dictionary(uniqueKeysWithValues: tools.map { ($0.input, $0) })
        #expect(byInput["a.swift"]?.state == .succeeded)
        #expect(byInput["exit 7"]?.state == .failed)
        #expect(byInput["exit 7"]?.detail == "exit code 7")
        #expect(byInput["sleep 9"]?.state == .cancelled)
        // Pager has no denied accent; seed maps denied → failed while the
        // sidecar keeps `.denied` (LivePagerOutputs.pagerState).
        #expect(byInput["rm -rf /"]?.state == .failed)
        #expect(byInput["rm -rf /"]?.detail == "Tool bash was not executed: denied")
        #expect(byInput["sleep 99"]?.state == .pending)
        #expect(byInput["sleep 99"]?.output == nil)
    }

    @Test("recordToolOutcome denied survives commit as denied, not failed")
    func persistDeniedViaHistory() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let items = persistConversationItems()
        var record = LiveConversationRecord.new(
            sessionID: "wave-a-denied",
            workingDirectory: home
        )
        record.items = items
        record.everUsedNonXAI = false

        let store = LiveConversationStore(openGrokHome: home)
        try await store.save(record)

        let history = LiveConversationHistory(record: record, store: store)
        await history.recordToolOutcome(callID: "ok", outcome: .succeeded)
        await history.recordToolOutcome(callID: "boom", outcome: .failed, detail: "exit code 7")
        await history.recordToolOutcome(callID: "stop", outcome: .cancelled)
        await history.recordToolOutcome(
            callID: "deny",
            outcome: .denied,
            detail: "Tool bash was not executed: denied"
        )
        await history.recordToolOutcome(callID: "wait", outcome: .pending)
        try await history.commit(sessionID: "wave-a-denied", items: items)

        let loaded = try await store.loadIfPresent(sessionID: "wave-a-denied")
        #expect(loaded != nil)
        guard let loaded else { return }
        #expect(loaded.toolOutcomes?.outcome(for: "deny") == .denied)
        #expect(loaded.toolOutcomes?.outcome(for: "boom") == .failed)
        #expect(loaded.toolOutcomes?.outcome(for: "ok") == .succeeded)
        #expect(loaded.toolOutcomes?.outcome(for: "stop") == .cancelled)
        #expect(loaded.toolOutcomes?.outcome(for: "wait") == .pending)
    }

    @Test("run onChunk delivers incremental stdout before the final result")
    func runOnChunkDeliversIncrementalStdout() async throws {
        #if os(Windows)
        return
        #else
        let directory = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }

        let backend = LocalShellProcessBackend(
            launchTransform: { executable, arguments in
                (executable, arguments)
            }
        )

        // libc stdio block-buffers a pipe, so a raw
        // `printf one; sleep 0.05; printf two` can coalesce into one write
        // at exit. `syswrite` is the same two-burst shape without that
        // library hole (Rust pin terminal.rs:4031 uses a sleep loop too).
        let command = #"/usr/bin/perl -e 'syswrite STDOUT, "one"; select(undef,undef,undef,0.05); syswrite STDOUT, "two"'"#

        let chunks = ChunkCollector()
        let result = try await backend.run(
            ShellCommandRequest(
                command: command,
                workingDirectory: directory,
                timeout: .seconds(10),
                shell: .sh
            ),
            onChunk: { data in
                await chunks.append(data)
            }
        )

        #expect(result.exitCode == 0)
        #expect(result.combinedOutput.contains("one"))
        #expect(result.combinedOutput.contains("two"))

        let delivered = await chunks.snapshot()
        let nonempty = delivered.filter { !$0.isEmpty }
        let joined = nonempty.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!nonempty.isEmpty)
        #expect(joined.contains("one"))
        #expect(joined.contains("two"))
        // Prefer two bursts. If the platform still coalesces, the joined
        // bytes above still prove the pump fired before `run` returned.
        if nonempty.count >= 2 {
            let first = String(decoding: nonempty[0], as: UTF8.self)
            #expect(first.contains("one"))
        }
        #endif
    }

    private func persistConversationItems() -> [ConversationItem] {
        [
            .user("run tools"),
            .assistant(AssistantItem(
                content: "working",
                toolCalls: [
                    ToolCall(id: "ok", name: "read", arguments: #"{"path":"a.swift"}"#),
                    ToolCall(id: "boom", name: "bash", arguments: #"{"command":"exit 7"}"#),
                    ToolCall(id: "stop", name: "bash", arguments: #"{"command":"sleep 9"}"#),
                    ToolCall(id: "deny", name: "bash", arguments: #"{"command":"rm -rf /"}"#),
                    ToolCall(id: "wait", name: "bash", arguments: #"{"command":"sleep 99"}"#),
                ]
            )),
            .toolResult(ToolResultItem(toolCallId: "ok", content: "file body")),
            .toolResult(ToolResultItem(toolCallId: "boom", content: "exit code 7")),
            .toolResult(ToolResultItem(toolCallId: "stop", content: "Cancelled")),
            .toolResult(ToolResultItem(
                toolCallId: "deny",
                content: "Tool bash was not executed: denied"
            )),
        ]
    }

    private func makeTemporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveAPersistAndStream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor ChunkCollector {
    private var chunks: [Data] = []

    func append(_ data: Data) {
        chunks.append(data)
    }

    func snapshot() -> [Data] {
        chunks
    }
}
