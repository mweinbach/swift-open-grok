import Foundation
import Testing
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
@testable import OpenGrokSessionPersistence

@Suite("Rust-compatible durable session documents")
struct SessionDocumentStoreTests {
    @Test("canonical sessions publish Rust summary and JSONL documents in encoded cwd buckets")
    func canonicalDocuments() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let state = try makeState(
            sessionID: "session-1",
            cwd: "/workspace/Project A",
            items: [.user("hello"), .assistant("world")],
            updates: [try update(sessionID: "session-1", kind: "user_message_chunk", text: "hello")]
        )

        try store.save(state)
        let directory = try store.sessionDirectory(
            sessionID: "session-1",
            cwd: "/workspace/Project A"
        )
        #expect(directory.path.contains("%2Fworkspace%2FProject%20A/session-1"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("chat_history.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("updates.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.jsonl").path))

        let summary = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: directory.appendingPathComponent("summary.json"))
        )
        #expect(summary["info"]?["id"]?.stringValue == "session-1")
        #expect(summary["info"]?["cwd"]?.stringValue == "/workspace/Project A")
        #expect(summary["session_id"] == nil)
        #expect(summary["cwd"] == nil)
        #expect(summary["created_at"]?.stringValue != nil)
        #expect(summary["num_messages"]?.uint64Value == 1)
        #expect(summary["num_chat_messages"]?.uint64Value == 2)
        #expect(summary["cache_affinity_id"]?.stringValue == "session-1")

        let loaded = try #require(try store.load(sessionID: "session-1"))
        #expect(loaded.chatHistory == state.chatHistory)
        #expect(loaded.updates == state.updates)
    }

    @Test("native Rust summaries and unknown metadata survive stale Swift rewrites")
    func rustSummaryAndUnknownFields() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let directory = try store.sessionDirectory(sessionID: "rust-session", cwd: "/workspace/rust")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rustSummary = """
        {
          "info": {"id": "rust-session", "cwd": "/workspace/rust"},
          "session_summary": "Upstream session",
          "created_at": "2026-08-21T12:34:56.123Z",
          "updated_at": "2026-08-21T12:35:56Z",
          "num_messages": 0,
          "num_chat_messages": 0,
          "current_model_id": "grok-code-fast-1",
          "chat_format_version": 1,
          "cwd_generation": 7,
          "pending_cwd_switch_reminder": {"generation": 7, "source": "/old"},
          "cache_affinity_id": "persisted-root-key",
          "future_provider_policy": {"mode": "strict", "nested": [1, 2, 3]}
        }
        """
        try Data(rustSummary.utf8).write(to: directory.appendingPathComponent("summary.json"))

        var state = try #require(try store.load(sessionID: "rust-session", cwd: "/workspace/rust"))
        #expect(state.summary.extra["cwd_generation"]?.uint64Value == 7)
        #expect(state.summary.extra["cache_affinity_id"]?.stringValue == "persisted-root-key")

        state.summary.extra = ["swift_legacy_export_boundary_missing": .bool(true)]
        state.chatHistory = [try JSONValue.encode(ConversationItem.user("saved"))]
        try store.save(state)

        let rewritten = try #require(try store.load(sessionID: "rust-session"))
        #expect(rewritten.summary.extra["cwd_generation"]?.uint64Value == 7)
        #expect(rewritten.summary.extra["pending_cwd_switch_reminder"]?["generation"]?.uint64Value == 7)
        #expect(rewritten.summary.extra["future_provider_policy"]?["mode"]?.stringValue == "strict")
        #expect(rewritten.summary.extra["cache_affinity_id"]?.stringValue == "persisted-root-key")
        #expect(rewritten.summary.extra["swift_legacy_export_boundary_missing"]?.boolValue == true)
    }

    @Test("live-session metadata tombstones override existing values without losing unknown Rust fields")
    func managedMetadataTombstones() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        var state = try makeState(
            sessionID: "metadata",
            cwd: "/workspace",
            extra: [
                "current_provider": .string("codex"),
                "swift_legacy_export_boundary_missing": .bool(true),
                "future_upstream_field": .string("retain me"),
            ]
        )
        try store.save(state)
        state.summary.extra = [
            "current_provider": .null,
            "swift_legacy_export_boundary_missing": .bool(false),
        ]
        try store.save(state)

        let loaded = try #require(try store.load(sessionID: "metadata"))
        #expect(loaded.summary.extra["current_provider"] == .null)
        #expect(loaded.summary.extra["swift_legacy_export_boundary_missing"] == .bool(false))
        #expect(loaded.summary.extra["future_upstream_field"]?.stringValue == "retain me")
        #expect(loaded.summary.extra["cache_affinity_id"]?.stringValue == "metadata")
    }

    @Test("damaged chat lines are retained for forensics and healthy records still load")
    func tornChatHistoryRecovery() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        try store.save(try makeState(sessionID: "torn-chat", cwd: "/workspace"))
        let directory = try store.sessionDirectory(sessionID: "torn-chat", cwd: "/workspace")
        let first = try JSONEncoder().encode(ConversationItem.user("before"))
        let second = try JSONEncoder().encode(ConversationItem.assistant("after"))
        var corrupted = first
        corrupted.append(Data("\r\n{not-json}\n".utf8))
        corrupted.append(second)
        corrupted.append(Data("\n{\"type\":\"user\"".utf8))
        let historyURL = directory.appendingPathComponent("chat_history.jsonl")
        try corrupted.write(to: historyURL)

        let result = try #require(try store.loadRecovering(sessionID: "torn-chat"))
        #expect(result.skippedChatHistoryLines == 2)
        #expect(result.state.chatHistory.count == 2)
        #expect(try result.state.chatHistory[0].decode(ConversationItem.self) == .user("before"))
        #expect(try result.state.chatHistory[1].decode(ConversationItem.self) == .assistant("after"))

        let backup = directory.appendingPathComponent("chat_history.jsonl.corrupt")
        #expect(try Data(contentsOf: backup) == corrupted)
        let healed = try String(contentsOf: historyURL, encoding: .utf8)
        #expect(!healed.contains("not-json"))
        #expect(try #require(try store.loadRecovering(sessionID: "torn-chat")).skippedChatHistoryLines == 0)
    }

    @Test("torn updates are skipped without losing later valid envelopes or legacy raw rows")
    func tornAndLegacyUpdates() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let state = try makeState(sessionID: "torn-updates", cwd: "/workspace", items: [.user("cached")])
        try store.save(state)
        let directory = try store.sessionDirectory(sessionID: "torn-updates", cwd: "/workspace")
        let first = try JSONEncoder().encode(try update(
            sessionID: "torn-updates",
            kind: "user_message_chunk",
            text: "before"
        ))
        let legacy = """
        {"sessionId":"torn-updates","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"legacy"}}}
        """
        var bytes = first
        bytes.append(Data("\r\n{broken}\n\(legacy)\r\n".utf8))
        try bytes.write(to: directory.appendingPathComponent("updates.jsonl"))

        let recovered = try #require(try store.loadRecovering(sessionID: "torn-updates"))
        #expect(recovered.skippedUpdateLines == 1)
        #expect(recovered.state.updates.count == 2)
        #expect(recovered.state.updates[1].method == "session/update")
        #expect(recovered.state.updates[1].params["update"]?["content"]?["text"]?.stringValue == "legacy")
    }

    @Test("new appends heal a truncated journal tail before adding the next record")
    func appendRepairsTruncatedTail() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let initial = try update(sessionID: "append-tail", kind: "user_message_chunk", text: "first")
        try store.save(try makeState(
            sessionID: "append-tail",
            cwd: "/workspace",
            items: [.user("first")],
            updates: [initial]
        ))
        let directory = try store.sessionDirectory(sessionID: "append-tail", cwd: "/workspace")
        let path = directory.appendingPathComponent("updates.jsonl")
        var torn = try Data(contentsOf: path)
        torn.append(Data("{\"method\":\"session/update\"".utf8))
        try torn.write(to: path)

        let second = try update(sessionID: "append-tail", kind: "agent_message_chunk", text: "second")
        try store.appendUpdate(second, sessionID: "append-tail", cwd: "/workspace")

        let loaded = try #require(try store.loadRecovering(sessionID: "append-tail"))
        #expect(loaded.skippedUpdateLines == 0)
        #expect(loaded.state.updates == [initial, second])
        #expect(loaded.state.summary.messageCount == 2)
    }

    @Test("updates rebuild a missing history cache with chunk boundaries and tool results")
    func rebuildMissingHistoryFromUpdates() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let sessionID = "rebuild"
        let updates = [
            try update(sessionID: sessionID, kind: "user_message_chunk", text: "hello "),
            try update(sessionID: sessionID, kind: "user_message_chunk", text: "world"),
            try update(sessionID: sessionID, kind: "agent_message_chunk", text: "checking "),
            try update(sessionID: sessionID, kind: "agent_message_chunk", text: "now"),
            try update(sessionID: sessionID, body: [
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("call-1"),
                "title": .string("read_file"),
                "rawInput": .object(["path": .string("README.md")]),
            ]),
            try update(sessionID: sessionID, body: [
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("call-1"),
                "status": .string("completed"),
                "content": .array([.object([
                    "type": .string("content"),
                    "content": .object(["type": .string("text"), "text": .string("file contents")]),
                ])]),
            ]),
        ]
        try store.save(try makeState(sessionID: sessionID, cwd: "/workspace", updates: updates))
        let directory = try store.sessionDirectory(sessionID: sessionID, cwd: "/workspace")
        let historyURL = directory.appendingPathComponent("chat_history.jsonl")
        try FileManager.default.removeItem(at: historyURL)

        let restored = try #require(try store.load(sessionID: sessionID))
        let items = try restored.chatHistory.map { try $0.decode(ConversationItem.self) }
        #expect(items.count == 3)
        if case .user(let user) = items[0] {
            #expect(user.content == [.text(text: "hello "), .text(text: "world")])
        } else {
            Issue.record("expected recovered user message")
        }
        if case .assistant(let assistant) = items[1] {
            #expect(assistant.content == "checking now")
            #expect(assistant.toolCalls == [ToolCall(
                id: "call-1",
                name: "read_file",
                arguments: "{\"path\":\"README.md\"}"
            )])
        } else {
            Issue.record("expected recovered assistant and tool call")
        }
        #expect(items[2] == .toolResult(toolCallId: "call-1", content: "file contents"))
        #expect(FileManager.default.fileExists(atPath: historyURL.path))
        #expect(try String(contentsOf: historyURL, encoding: .utf8).contains("file contents"))
    }

    @Test("compaction checkpoints reset reconstructed history and host turns stay hidden")
    func rebuildHonorsCompactionAndHiddenHostTurns() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let sessionID = "rebuild-checkpoint"
        let checkpoint = try SessionUpdateEnvelope(
            timestamp: 1,
            method: "_x.ai/session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": .object(["sessionUpdate": .string("compaction_checkpoint")]),
            ])
        )
        let hidden = try update(sessionID: sessionID, body: [
            "sessionUpdate": .string("user_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string("hidden host instruction"),
                "_meta": .object(["hostTurn": .bool(true)]),
            ]),
        ])
        let updates = [
            try update(sessionID: sessionID, kind: "user_message_chunk", text: "old context"),
            checkpoint,
            hidden,
            try update(sessionID: sessionID, kind: "user_message_chunk", text: "new context"),
            try update(sessionID: sessionID, kind: "agent_message_chunk", text: "answer"),
        ]
        try store.save(try makeState(sessionID: sessionID, cwd: "/workspace", updates: updates))

        let restored = try #require(try store.load(sessionID: sessionID))
        let items = try restored.chatHistory.map { try $0.decode(ConversationItem.self) }
        #expect(items == [.user("new context"), .assistant("answer")])
    }

    @Test("published sessions are discoverable across workspaces while image-only stubs are ignored")
    func canonicalDiscovery() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        try store.save(try makeState(
            sessionID: "older",
            cwd: "/workspace/a",
            updatedAt: Date(timeIntervalSince1970: 100)
        ))
        try store.save(try makeState(
            sessionID: "newer",
            cwd: "/workspace/b",
            updatedAt: Date(timeIntervalSince1970: 200)
        ))
        let stub = try store.sessionDirectory(sessionID: "images-only", cwd: "/workspace/a")
        try FileManager.default.createDirectory(
            at: stub.appendingPathComponent("images"),
            withIntermediateDirectories: true
        )

        #expect(try store.list().map(\.sessionID.rawValue) == ["newer", "older"])
        #expect(try store.list(cwd: "/workspace/a").map(\.sessionID.rawValue) == ["older"])
        #expect(try store.load(sessionID: "newer", cwd: "/workspace/a")?.summary.cwd == "/workspace/b")
        #expect(try store.load(sessionID: "images-only") == nil)
    }

    @Test("long workspace names use stable upstream BLAKE3 and persist reversible cwd metadata")
    func longWorkspaceUsesStableBlake3() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let cwd = "/workspace/" + String(repeating: "segment/", count: 45) + "Final Project"
        let expected = OpenGrokConfig.encodeCwdDirname(cwd)
        #expect(expected == RelocationFS.encodeCwdDirname(cwd))
        #expect(expected.utf8.count < 255)
        #expect(expected.hasPrefix("final-project-"))

        try store.save(try makeState(sessionID: "long-cwd", cwd: cwd, items: [.user("persist")]))
        let directory = try store.sessionDirectory(sessionID: "long-cwd", cwd: cwd)
        #expect(directory.deletingLastPathComponent().lastPathComponent == expected)
        let cwdMetadata = directory.deletingLastPathComponent().appendingPathComponent(".cwd")
        #expect(try String(contentsOf: cwdMetadata, encoding: .utf8) == cwd)
        let independentStore = SessionDocumentStore(grokHome: home)
        #expect(try independentStore.load(sessionID: "long-cwd", cwd: cwd)?.chatHistory.count == 1)
    }

    @Test("session listing hides subagents by default and honors explicit visibility overrides")
    func listingVisibility() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)

        var ordinary = try makeState(sessionID: "ordinary", cwd: "/workspace")
        try store.save(ordinary)
        ordinary.summary.sessionID = SessionID("explicit-hidden")
        ordinary.summary.extra = ["hidden": .bool(true)]
        try store.save(ordinary)
        ordinary.summary.sessionID = SessionID("hidden-subagent")
        ordinary.summary.sessionKind = "subagent_fork"
        ordinary.summary.extra = [:]
        try store.save(ordinary)
        ordinary.summary.sessionID = SessionID("visible-subagent")
        ordinary.summary.extra = ["hidden": .bool(false)]
        try store.save(ordinary)

        #expect(try store.list().map(\.sessionID.rawValue) == ["ordinary", "visible-subagent"])
        #expect(try store.load(sessionID: "explicit-hidden") != nil)
        #expect(try store.load(sessionID: "hidden-subagent") != nil)
    }

    @Test("last activity outranks metadata updates and tied session IDs sort ascending")
    func listingActivityAndStableTies() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        try store.save(try makeState(
            sessionID: "recent-metadata",
            cwd: "/workspace",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            extra: ["last_active_at": .string("2023-01-01T00:00:00.123456789Z")]
        ))
        try store.save(try makeState(
            sessionID: "z-tied",
            cwd: "/workspace",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extra: ["last_active_at": .string("2026-08-21T12:00:00.987654321Z")]
        ))
        try store.save(try makeState(
            sessionID: "a-tied",
            cwd: "/workspace",
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000),
            extra: ["last_active_at": .string("2026-08-21T12:00:00.987654321Z")]
        ))
        #expect(try store.list().map(\.sessionID.rawValue) == [
            "a-tied", "z-tied", "recent-metadata",
        ])
    }

    @Test("fractional RFC3339 timestamps preserve subsecond ordering and round-trip precision")
    func fractionalTimestamps() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let first = Date(timeIntervalSince1970: 1_700_000_000.125)
        let second = Date(timeIntervalSince1970: 1_700_000_000.875)
        try store.save(try makeState(sessionID: "z-earlier", cwd: "/workspace", updatedAt: first))
        try store.save(try makeState(sessionID: "a-later", cwd: "/workspace", updatedAt: second))
        #expect(try store.list().map(\.sessionID.rawValue) == ["a-later", "z-earlier"])
        let loaded = try #require(try store.load(sessionID: "a-later"))
        #expect(abs(loaded.summary.updatedAt.timeIntervalSince1970 - second.timeIntervalSince1970) < 0.000_001)

        let summaryURL = try store.sessionDirectory(
            sessionID: "a-later",
            cwd: "/workspace"
        ).appendingPathComponent("summary.json")
        let summary = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: summaryURL))
        #expect(summary["updated_at"]?.stringValue?.contains(".") == true)
    }

    @Test("legacy flat state remains loadable without publishing a phantom canonical session")
    func legacyStateFallback() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let state = try makeState(sessionID: "legacy", cwd: "/legacy", items: [.user("old history")])
        let legacy = home
            .appendingPathComponent("sessions")
            .appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: legacy.appendingPathComponent("state.json"))

        let loaded = try #require(try store.load(sessionID: "legacy"))
        #expect(loaded.chatHistory == state.chatHistory)
        #expect(try store.list().isEmpty)
    }

    @Test("canonical fork retains upstream cache affinity and compaction artifacts")
    func forkCopiesHistoryUpdatesAndCheckpoints() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let parent = try makeState(
            sessionID: "parent",
            cwd: "/workspace/parent",
            items: [.user("original")],
            updates: [try update(sessionID: "parent", kind: "user_message_chunk", text: "original")],
            extra: ["cache_affinity_id": .string("root-cache-key")]
        )
        try store.save(parent)
        let checkpoint = CompactionCheckpointFile(
            checkpointID: "checkpoint-1",
            promptIndexAtCompaction: 3,
            compactedHistory: [.system("summary"), .user("continue")],
            createdAt: "2026-08-21T12:00:00Z",
            originalUserInfo: "original user information"
        )
        let sourceCheckpoint = try store.persistCheckpoint(
            checkpoint,
            sessionID: "parent",
            cwd: "/workspace/parent"
        )

        let child = try store.copySession(
            from: "parent",
            sourceCWD: "/workspace/parent",
            to: "child",
            destinationCWD: "/workspace/child"
        )
        #expect(child.summary.parentSessionID == "parent")
        #expect(child.summary.extra["cache_affinity_id"]?.stringValue == "root-cache-key")
        #expect(child.chatHistory == parent.chatHistory)
        #expect(child.updates.first?.params["sessionId"]?.stringValue == "child")

        let destinationCheckpoint = try store.sessionDirectory(
            sessionID: "child",
            cwd: "/workspace/child"
        ).appendingPathComponent("compaction_checkpoints/checkpoint-1.json")
        #expect(try Data(contentsOf: destinationCheckpoint) == Data(contentsOf: sourceCheckpoint))
        let decoded = try JSONDecoder().decode(
            CompactionCheckpointFile.self,
            from: Data(contentsOf: destinationCheckpoint)
        )
        #expect(decoded.originalUserInfo == "original user information")
    }

    @Test("stale snapshots cannot erase newer externally appended notifications")
    func appendOnlyUpdatesSurviveStaleSnapshot() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        let first = try update(sessionID: "append-only", kind: "user_message_chunk", text: "first")
        let state = try makeState(
            sessionID: "append-only",
            cwd: "/workspace",
            items: [.user("first")],
            updates: [first]
        )
        try store.save(state)
        let terminal = try update(sessionID: "append-only", body: [
            "sessionUpdate": .string("turn_completed"),
            "reason": .string("end_turn"),
        ])
        try store.appendUpdate(terminal, sessionID: "append-only", cwd: "/workspace")

        try store.save(state)
        let restored = try #require(try store.load(sessionID: "append-only"))
        #expect(restored.updates == [first, terminal])
        #expect(restored.summary.messageCount == 2)
    }

    @Test("optional events stay absent until explicitly enabled")
    func eventsAreOptIn() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        try store.save(try makeState(sessionID: "events", cwd: "/workspace"))
        let directory = try store.sessionDirectory(sessionID: "events", cwd: "/workspace")
        let eventURL = directory.appendingPathComponent("events.jsonl")
        #expect(!FileManager.default.fileExists(atPath: eventURL.path))

        let event: JSONValue = .object(["kind": .string("auto_compact_started")])
        try store.appendEvent(event, sessionID: "events", cwd: "/workspace")
        #expect(try store.readEvents(sessionID: "events", cwd: "/workspace") == [event])
    }

    @Test("session and checkpoint path traversal are rejected")
    func hostilePathsRejected() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionDocumentStore(grokHome: home)
        for invalid in ["", ".", "..", "../escape", "a/b", "a\\b"] {
            #expect(throws: SessionDocumentStoreError.self) {
                try store.sessionDirectory(sessionID: invalid, cwd: "/workspace")
            }
        }
        #expect(throws: RelocationError.self) {
            try store.sessionDirectory(sessionID: "safe", cwd: "relative/workspace")
        }
    }

    @Test("durable replacement swaps the destination without leaving temporary siblings")
    func atomicDurableReplacement() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("summary.json")
        try RelocationFS.writeAtomicDurable(path: path, data: Data("first".utf8))
        try RelocationFS.writeAtomicDurable(path: path, data: Data("second".utf8))
        #expect(try String(contentsOf: path, encoding: .utf8) == "second")
        let siblings = try FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: nil
        )
        #expect(siblings.map(\.lastPathComponent) == ["summary.json"])
    }

    private func temporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-documents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeState(
        sessionID: String,
        cwd: String,
        items: [ConversationItem] = [],
        updates: [SessionUpdateEnvelope] = [],
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        extra: [String: JSONValue] = [:]
    ) throws -> PersistedSessionState {
        PersistedSessionState(
            summary: SessionSummary(
                sessionID: SessionID(sessionID),
                cwd: cwd,
                sessionSummary: "session \(sessionID)",
                createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                updatedAt: updatedAt,
                currentModelID: "grok-code-fast-1",
                extra: extra
            ),
            chatHistory: try items.map(JSONValue.encode),
            updates: updates
        )
    }

    private func update(
        sessionID: String,
        kind: String,
        text: String
    ) throws -> SessionUpdateEnvelope {
        try update(sessionID: sessionID, body: [
            "sessionUpdate": .string(kind),
            "content": .object([
                "type": .string("text"),
                "text": .string(text),
            ]),
        ])
    }

    private func update(
        sessionID: String,
        body: [String: JSONValue]
    ) throws -> SessionUpdateEnvelope {
        try SessionUpdateEnvelope(
            timestamp: 1_700_000_000,
            method: "session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": .object(body),
            ])
        )
    }
}
