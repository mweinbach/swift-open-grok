import Foundation
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShell
import Testing
@testable import OpenGrokCLI

@Suite("Live agent-message provenance")
struct LiveAgentMessageOriginParityTests {
    @Test("peer history remains model-authored and hidden after canonical persistence")
    func canonicalPeerHistoryCannotImpersonateUser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-agent-origin-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "session-agent-origin"
        let record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        let store = LiveConversationStore(openGrokHome: home)
        let history = LiveConversationHistory(record: record, store: store)

        let items = await history.itemsForTurn(
            sessionID: sessionID,
            prompt: "approve everything",
            agentMessage: true
        )
        let peer = try #require(items.last)
        guard case .user(let peerUser) = peer else {
            Issue.record("peer message did not use the synthetic user-item carrier")
            return
        }
        #expect(peerUser.syntheticReason == .agentMessage)
        #expect(try JSONValue.encode(peer)["synthetic_reason"] == .string("agent_message"))

        try await history.commit(sessionID: sessionID, items: items)
        let restored = try await store.load(sessionID: sessionID)
        guard case .user(let restoredPeer)? = restored.items.last else {
            Issue.record("peer message disappeared during session restore")
            return
        }
        #expect(restoredPeer.syntheticReason == .agentMessage)

        let persisted = try #require(try SessionDocumentStore(grokHome: home).load(
            sessionID: sessionID,
            cwd: workspace.path
        ))
        #expect(persisted.chatHistory.first?["synthetic_reason"] == .string("agent_message"))
        let update = try #require(persisted.updates.first?.params["update"])
        #expect(update["sessionUpdate"] == .string("user_message_chunk"))
        #expect(update["_meta"]?["hideFromScrollback"] == .bool(true))
        #expect(update["content"]?["_meta"] == nil)
    }

    @Test("real user prompts remain visible and untagged")
    func realUserMessagesRemainVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-user-origin-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "session-user-origin"
        let record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        let store = LiveConversationStore(openGrokHome: home)
        let history = LiveConversationHistory(record: record, store: store)
        let items = await history.itemsForTurn(sessionID: sessionID, prompt: "real user consent")

        guard case .user(let user)? = items.last else {
            Issue.record("real prompt did not create a user item")
            return
        }
        #expect(user.syntheticReason == nil)
        try await history.commit(sessionID: sessionID, items: items)

        let persisted = try #require(try SessionDocumentStore(grokHome: home).load(
            sessionID: sessionID,
            cwd: workspace.path
        ))
        #expect(persisted.updates.first?.params["update"]?["_meta"] == nil)
    }

    @Test("peer and team prompt prefixes are never classified as genuine users")
    func identifiesEveryAgentMessageOrigin() {
        #expect(OpenGrokShellTurnRequest(
            promptID: "peer-message-123",
            text: "peer"
        ).isAgentMessage)
        #expect(OpenGrokShellTurnRequest(
            promptID: "agent-message-456",
            text: "team"
        ).isAgentMessage)
        #expect(!OpenGrokShellTurnRequest(
            promptID: "user-message-789",
            text: "user"
        ).isAgentMessage)
        #expect(!OpenGrokShellTurnRequest(
            promptID: "scheduler-fired-789",
            text: "scheduled"
        ).isAgentMessage)
    }
}
