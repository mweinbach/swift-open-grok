// AgentCollaborationKindTests.swift
//
// `ToolKind::AgentCollaboration` joined the taxonomy in commit 7957721e and the
// checked-in `tool_meta` schema in 7c029c7b.
//
// Rust provenance (pin `9ed09e2a`):
//   * crates/codegen/xai-grok-tools/src/types/tool.rs:92 — the enum variant.
//   * crates/codegen/xai-grok-tools/src/tool_taxonomy.rs:60, 107 — the
//     "Agent Collaboration" display label and `is_read_only == false`.
//   * crates/codegen/xai-grok-tools/schema/tool_meta.schema.json:39 — the
//     regenerated `Known values:` list, which now carries
//     `agent_collaboration` between `agent_swarm` and `enter_plan`.
//   * crates/codegen/xai-grok-workspace/src/capability.rs:130-133 — the kind
//     is a meta tool, allowed under every capability mode.

import Foundation
import Testing

@testable import OpenGrokToolRegistry

@Suite("AgentCollaborationKind")
struct AgentCollaborationKindTests {
    @Test("the kind's wire name and position match the regenerated schema")
    func kindWireName() {
        #expect(ProductToolKind.agentCollaboration.rawValue == "agent_collaboration")

        // The schema enumerates the known values in declaration order; the new
        // kind sits between `agent_swarm` and `enter_plan`.
        let order = ProductToolKind.allCases.map(\.rawValue)
        let swarm = order.firstIndex(of: "agent_swarm")
        let collab = order.firstIndex(of: "agent_collaboration")
        let enterPlan = order.firstIndex(of: "enter_plan")
        #expect(swarm != nil && collab != nil && enterPlan != nil)
        #expect(swarm! < collab!)
        #expect(collab! < enterPlan!)
    }

    @Test("unknown kinds still sink to other, and this one no longer does")
    func decoding() throws {
        let decoded = try JSONDecoder().decode(
            ProductToolKind.self, from: Data(#""agent_collaboration""#.utf8)
        )
        #expect(decoded == .agentCollaboration)
        let unknown = try JSONDecoder().decode(
            ProductToolKind.self, from: Data(#""not_a_kind""#.utf8)
        )
        #expect(unknown == .other)
    }

    @Test("the kind renders as Agent Collaboration and is not read-only")
    func labelAndReadOnly() {
        #expect(
            CanonicalToolMeta.defaultLabel(for: .agentCollaboration) == "Agent Collaboration"
        )
        #expect(ProductToolKind.agentCollaboration.isReadOnly == false)
    }

    @Test("every capability mode allows the collaboration kind")
    func allowedUnderEveryMode() {
        for mode in ToolCapabilityMode.allCases {
            #expect(
                mode.kindAllowed(.agentCollaboration),
                "\(mode.rawValue) must allow agent_collaboration"
            )
        }
        // Contrast: the orchestration surfaces stay execute-only, so the three
        // surfaces and the mailbox are gated apart.
        #expect(!ToolCapabilityMode.readOnly.kindAllowed(.task))
        #expect(!ToolCapabilityMode.readOnly.kindAllowed(.agentSwarm))
        #expect(!ToolCapabilityMode.readOnly.kindAllowed(.workflow))
    }

    @Test("a read-only toolset keeps its mailbox tools")
    func capabilityFilterKeepsMailbox() {
        let config = ToolServerConfig(
            tools: [
                ToolConfig(id: "GrokBuild:read_file", kind: .read),
                ToolConfig(id: "GrokBuild:task", kind: .task),
                ToolConfig(id: "GrokBuild:send_message", kind: .agentCollaboration),
                ToolConfig(id: "GrokBuild:wait_agent", kind: .agentCollaboration),
            ],
            behaviorPreset: nil
        )
        let filtered = ToolCapabilityMode.readOnly.filter(config)
        #expect(
            filtered.tools.map(\.id)
                == ["GrokBuild:read_file", "GrokBuild:send_message", "GrokBuild:wait_agent"]
        )
    }
}
