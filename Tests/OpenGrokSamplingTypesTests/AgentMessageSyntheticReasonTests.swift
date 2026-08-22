// AgentMessageSyntheticReasonTests.swift
//
// Peer mailbox traffic gets its own conversation shape rather than borrowing
// `subagentCompleted`.
//
// Rust provenance (pin `9ed09e2a`, commit aa39b8cf):
//   * crates/codegen/xai-grok-sampling-types/src/conversation.rs:126-128 —
//     `SyntheticReason::AgentMessage`.
//   * .../conversation.rs:155-162 — it joins the wake set that starts a
//     prompt turn.
//   * .../conversation.rs:2497-2510 — `ConversationItem::agent_message`.
//   * crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn.rs:843-845
//     — `PromptOrigin::AgentMessage` maps to this item, not to
//     `subagent_completed`.

import Foundation
import Testing

@testable import OpenGrokSamplingTypes

@Suite("AgentMessageSyntheticReason")
struct AgentMessageSyntheticReasonTests {
    @Test("a delivered peer message is tagged distinctly from lifecycle wakes")
    func agentMessageIsItsOwnReason() {
        let item = ConversationItem.agentMessage("peer says hi")
        guard case .user(let user) = item else {
            Issue.record("expected a user item")
            return
        }
        #expect(user.syntheticReason == .agentMessage)
        #expect(user.syntheticReason != .subagentCompleted)
        #expect(user.syntheticReason != .interjection)
    }

    @Test("a peer message wakes the agent and consumes a prompt slot")
    func agentMessageStartsPromptTurn() {
        #expect(SyntheticReason.agentMessage.startsPromptTurn)
        // Contrast with the reasons that do not start a turn.
        #expect(!SyntheticReason.systemReminder.startsPromptTurn)
        #expect(!SyntheticReason.interjection.startsPromptTurn)
    }

    @Test("peer provenance persists in Rust's canonical snake-case wire form")
    func canonicalAgentMessageWireForm() throws {
        let encoded = try JSONEncoder().encode(SyntheticReason.agentMessage)
        #expect(String(decoding: encoded, as: UTF8.self) == #""agent_message""#)
        let decoded = try JSONDecoder().decode(
            SyntheticReason.self, from: Data(#""agent_message""#.utf8)
        )
        #expect(decoded == .agentMessage)
    }

    @Test("legacy Swift peer provenance migrates without becoming real user input")
    func legacyAgentMessageMigration() throws {
        let legacy = try JSONDecoder().decode(
            SyntheticReason.self, from: Data(#""agentMessage""#.utf8)
        )
        #expect(legacy == .agentMessage)
        #expect(legacy.startsPromptTurn)

        let migrated = try JSONEncoder().encode(legacy)
        #expect(String(decoding: migrated, as: UTF8.self) == #""agent_message""#)
    }

    @Test("unknown reasons still collapse to .unknown")
    func forwardCompatibility() throws {
        let unknown = try JSONDecoder().decode(
            SyntheticReason.self, from: Data(#""not_a_reason""#.utf8)
        )
        #expect(unknown == .unknown)
    }
}
