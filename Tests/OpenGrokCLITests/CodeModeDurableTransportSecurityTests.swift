import Foundation
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokCLI

private struct CodeModeTransportDiskFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "code-mode-transport-security-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func record(id: String = "transport-session") -> LiveConversationRecord {
        var record = LiveConversationRecord.new(sessionID: id, workingDirectory: workspace)
        record.everUsedNonXAI = false
        return record
    }

    func conversationItems() -> [ConversationItem] {
        [
            .user("inspect the workspace"),
            .assistant(AssistantItem(content: "", toolCalls: [
                ToolCall(id: "transport-exec", name: "exec", arguments: #"{"source":"SECRET_JAVASCRIPT"}"#),
                ToolCall(id: "nested-read", name: "read_file", arguments: #"{"path":"visible.swift"}"#),
                ToolCall(id: "plugin-exec", name: "exec", arguments: #"{"command":"visible plugin command"}"#),
                ToolCall(id: "transport-wait", name: "wait", arguments: #"{"cell_id":"SECRET_CELL"}"#),
                ToolCall(id: "plugin-wait", name: "wait", arguments: #"{"job":"visible plugin job"}"#),
            ])),
            .toolResult(ToolResultItem(toolCallId: "transport-exec", content: "SECRET_EXEC_RESULT")),
            .toolResult(ToolResultItem(toolCallId: "nested-read", content: "visible nested result")),
            .toolResult(ToolResultItem(toolCallId: "plugin-exec", content: "visible plugin exec result")),
            .toolResult(ToolResultItem(toolCallId: "transport-wait", content: "SECRET_WAIT_RESULT")),
            .toolResult(ToolResultItem(toolCallId: "plugin-wait", content: "visible plugin wait result")),
            .customToolOutput(CustomToolOutputItem.text(callId: "transport-exec", "SECRET_CUSTOM_RESULT")),
        ]
    }
}

@Suite("Code Mode durable exact-call transport isolation")
struct CodeModeDurableTransportSecurityTests {
    @Test("first secret-bearing save stamps exact ACP notification metadata and survives restart")
    func firstSaveMarksExactTransportCalls() async throws {
        let fixture = try CodeModeTransportDiskFixture()
        defer { fixture.cleanup() }
        let store = LiveConversationStore(openGrokHome: fixture.home)
        let history = LiveConversationHistory(record: fixture.record(), store: store)

        await history.recordCodeModeTransportCallIDs([
            "transport-wait", "transport-exec", "transport-exec",
        ])
        try await history.commit(
            sessionID: "transport-session",
            items: fixture.conversationItems()
        )

        let documents = SessionDocumentStore(grokHome: fixture.home)
        let persisted = try #require(try documents.load(sessionID: "transport-session"))
        #expect(persisted.summary.extra["code_mode_transport_call_ids"] == .array([
            .string("transport-exec"),
            .string("transport-wait"),
        ]))

        let markedIDs = persisted.updates.compactMap { envelope -> String? in
            guard let params = envelope.params.objectValue,
                  params["_meta"]?.objectValue?["open-grok/codeModeTransport"]?.boolValue == true
            else { return nil }
            #expect(params["update"]?.objectValue?["_meta"] == nil)
            return params["update"]?.objectValue?["toolCallId"]?.stringValue
        }
        #expect(markedIDs == [
            "transport-exec", "transport-wait", "transport-exec", "transport-wait",
        ])

        let restarted = try await LiveConversationStore(openGrokHome: fixture.home)
            .load(sessionID: "transport-session")
        #expect(restarted.codeModeTransportCallIDs == ["transport-exec", "transport-wait"])
        let resumed = LiveConversationHistory(
            record: restarted,
            store: LiveConversationStore(openGrokHome: fixture.home)
        )
        #expect(await resumed.codeModeTransportCallIDs == ["transport-exec", "transport-wait"])
    }

    @Test("dashboard hides persisted transport secrets while keeping nested and same-name plugins")
    func dormantDashboardNeverLeaksTransport() async throws {
        let fixture = try CodeModeTransportDiskFixture()
        defer { fixture.cleanup() }
        var record = fixture.record()
        record.items = fixture.conversationItems()
        record.codeModeTransportCallIDs = ["transport-exec", "transport-wait"]
        let store = LiveConversationStore(openGrokHome: fixture.home)
        try await store.save(record)

        let restored = try await LiveConversationStore(openGrokHome: fixture.home)
            .load(sessionID: record.sessionID)
        let cache = LiveDashboardPeekCache.build(from: [restored])
        let cards = (cache.items[record.sessionID] ?? []).compactMap { item -> PagerToolCard? in
            guard case .tool(let card) = item else { return nil }
            return card
        }

        #expect(cards.map(\.name) == ["read_file", "exec", "wait"])
        #expect(cards.map { $0.output ?? "" } == [
            "visible nested result",
            "visible plugin exec result",
            "visible plugin wait result",
        ])
        #expect(cards.allSatisfy { !$0.input.contains("SECRET") && !($0.output ?? "").contains("SECRET") })
    }

    @Test("transport provenance is session-local even when plugin call IDs collide")
    func dashboardNeverCrossContaminatesSessions() throws {
        let fixture = try CodeModeTransportDiskFixture()
        defer { fixture.cleanup() }

        let sharedCall = ConversationItem.assistant(AssistantItem(content: "", toolCalls: [
            ToolCall(id: "shared-call-id", name: "exec", arguments: "VISIBLE_ONLY_IN_PLUGIN_SESSION"),
        ]))
        var transport = fixture.record(id: "transport-owner")
        transport.items = [sharedCall]
        transport.codeModeTransportCallIDs = ["shared-call-id"]
        var plugin = fixture.record(id: "plugin-owner")
        plugin.items = [sharedCall]

        let cache = LiveDashboardPeekCache.build(from: [transport, plugin])
        #expect(cache.items["transport-owner"]?.isEmpty == true)
        let pluginItems = try #require(cache.items["plugin-owner"])
        #expect(pluginItems.count == 1)
        guard case .tool(let card) = pluginItems[0] else {
            Issue.record("same-name plugin must remain visible in its own session")
            return
        }
        #expect(card.name == "exec")
    }

    @Test("notification metadata recovers exact IDs when an imported summary lacks the sidecar")
    func rustCompatibleMarkerRehydratesMissingSummarySidecar() async throws {
        let fixture = try CodeModeTransportDiskFixture()
        defer { fixture.cleanup() }
        var record = fixture.record()
        record.items = fixture.conversationItems()
        record.codeModeTransportCallIDs = ["transport-exec", "transport-wait"]
        let store = LiveConversationStore(openGrokHome: fixture.home)
        try await store.save(record)

        var persisted = try #require(try SessionDocumentStore(grokHome: fixture.home)
            .load(sessionID: record.sessionID))
        persisted.summary.extra.removeValue(forKey: "code_mode_transport_call_ids")
        let recovered = try LiveConversationStore.record(
            from: persisted,
            requestedSessionID: record.sessionID
        )

        #expect(recovered.codeModeTransportCallIDs == ["transport-exec", "transport-wait"])

        // Updates publish before summary.json, so an interrupted save can also
        // leave a nonempty but incomplete older sidecar.
        persisted.summary.extra["code_mode_transport_call_ids"] = .array([
            .string("transport-exec"),
        ])
        let staleSummary = try LiveConversationStore.record(
            from: persisted,
            requestedSessionID: record.sessionID
        )
        #expect(staleSummary.codeModeTransportCallIDs == ["transport-exec", "transport-wait"])
    }

    @Test("forked transcripts inherit exact transport provenance and remain secret-free")
    func forkPreservesTransportProvenance() async throws {
        let fixture = try CodeModeTransportDiskFixture()
        defer { fixture.cleanup() }
        var record = fixture.record(id: "transport-parent")
        record.items = fixture.conversationItems()
        record.codeModeTransportCallIDs = ["transport-exec", "transport-wait"]
        let store = LiveConversationStore(openGrokHome: fixture.home)
        try await store.save(record)

        let child = try await store.fork(
            sourceSessionID: "transport-parent",
            destinationSessionID: "transport-child",
            workingDirectory: fixture.workspace
        )
        #expect(child.codeModeTransportCallIDs == ["transport-exec", "transport-wait"])
        let restored = try await LiveConversationStore(openGrokHome: fixture.home)
            .load(sessionID: child.sessionID)
        #expect(restored.codeModeTransportCallIDs == ["transport-exec", "transport-wait"])
        let names = LiveDashboardPeekCache.peekItems(from: restored).compactMap { item -> String? in
            guard case .tool(let card) = item else { return nil }
            return card.name
        }
        #expect(names == ["read_file", "exec", "wait"])
    }

    @Test("legacy records without transport markers preserve ordinary exec and wait tools")
    func legacyRecordCompatibilityPreservesPlugins() throws {
        let fixture = try CodeModeTransportDiskFixture()
        defer { fixture.cleanup() }
        let record = fixture.record()
        let encoded = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["code_mode_transport_call_ids"] == nil)
        let restored = try JSONDecoder().decode(LiveConversationRecord.self, from: encoded)
        #expect(restored.codeModeTransportCallIDs == nil)
    }
}
