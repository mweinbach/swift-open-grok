// AgentCollaborationToolTypesTests.swift
//
// Wire goldens and contract locks for the team-scoped subagent mailbox.
//
// Rust provenance (pin `9ed09e2a`, commits 7957721e / aa39b8cf / 4cea76d2 /
// 12359ba6):
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/types.rs:186-278
//     — the seven wire types and their serde attributes.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/agent_collaboration/mod.rs:16-18,
//     80-102, 291 — the message/wait limits and `validate_message`.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/types.rs:1436-1496
//     — `task_agent_swarm_and_workflow_stay_three_distinct_surfaces`.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/types.rs:1209-1246
//     — `ForegroundWaitKind` and its `Interruptible` default.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/agent_collaboration/mod.rs:305-351
//     — the Rust unit tests these mirror.
//
// The goldens are encoded with `.sortedKeys` so key order is deterministic;
// serde emits the declaration order, which differs only in ordering and not in
// content, so the assertions compare parsed-and-re-encoded canonical forms.

import Foundation
import Testing

@testable import OpenGrokToolTypes

@Suite("AgentCollaborationToolTypes")
struct AgentCollaborationToolTypesTests {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try Self.encoder.encode(value), as: UTF8.self)
    }

    // MARK: Goldens

    @Test("AgentMailboxMessage round-trips the stamped wire shape")
    func mailboxMessageGolden() throws {
        let message = AgentMailboxMessage(
            messageID: "m1",
            teamScopeID: "parent",
            fromAgentID: "parent",
            toAgentID: "mail-child",
            kind: .message,
            body: "first",
            createdAtMS: 1
        )
        let golden = #"{"body":"first","created_at_ms":1,"from_agent_id":"parent","kind":"message","message_id":"m1","team_scope_id":"parent","to_agent_id":"mail-child"}"#
        #expect(try encoded(message) == golden)

        let decoded = try JSONDecoder().decode(
            AgentMailboxMessage.self,
            from: Data(golden.utf8)
        )
        #expect(decoded == message)
    }

    @Test("followup_task is the only kind that wakes its recipient")
    func messageKindWakeSemantics() throws {
        #expect(AgentMailboxMessageKind.message.wakesRecipient == false)
        #expect(AgentMailboxMessageKind.followupTask.wakesRecipient == true)
        #expect(try encoded(AgentMailboxMessageKind.followupTask) == #""followup_task""#)
        #expect(try encoded(AgentMailboxMessageKind.message) == #""message""#)
    }

    @Test("AgentRosterEntry omits nil optionals, matching skip_serializing_if")
    func rosterEntryGolden() throws {
        let root = AgentRosterEntry(
            agentID: "parent",
            isRoot: true,
            status: "running",
            description: "Root agent"
        )
        #expect(
            try encoded(root)
                == #"{"agent_id":"parent","description":"Root agent","is_root":true,"status":"running"}"#
        )

        let child = AgentRosterEntry(
            agentID: "mail-child",
            isRoot: false,
            status: "pending",
            subagentType: "explore",
            description: "Find the leak",
            resumedFrom: "earlier-child",
            worktreePath: "/tmp/wt"
        )
        let golden = #"{"agent_id":"mail-child","description":"Find the leak","is_root":false,"resumed_from":"earlier-child","status":"pending","subagent_type":"explore","worktree_path":"/tmp/wt"}"#
        #expect(try encoded(child) == golden)
        #expect(
            try JSONDecoder().decode(AgentRosterEntry.self, from: Data(golden.utf8)) == child
        )
    }

    @Test("ListAgentsOutput carries the team scope alongside the roster")
    func listAgentsOutputGolden() throws {
        let output = ListAgentsOutput(
            teamScopeID: "parent",
            agents: [
                AgentRosterEntry(
                    agentID: "parent", isRoot: true, status: "running",
                    description: "Root agent"
                )
            ]
        )
        #expect(
            try encoded(output)
                == #"{"agents":[{"agent_id":"parent","description":"Root agent","is_root":true,"status":"running"}],"team_scope_id":"parent"}"#
        )
    }

    @Test("send and wait outputs match their Rust wire shapes")
    func sendAndWaitOutputGoldens() throws {
        let send = AgentMessageSendOutput(
            messageID: "m1",
            targetAgentID: "mail-child",
            status: .queued
        )
        #expect(
            try encoded(send)
                == #"{"message_id":"m1","status":"queued","target_agent_id":"mail-child"}"#
        )
        #expect(try encoded(AgentMessageDeliveryStatus.delivered) == #""delivered""#)

        let empty = WaitAgentMessagesOutput(messages: [], timedOut: true)
        #expect(try encoded(empty) == #"{"messages":[],"timed_out":true}"#)
    }

    @Test("wait_agent renders empty inboxes as prose and messages as JSON")
    func waitAgentModelText() {
        // Rust `ToolOutput::WaitAgentMessages` (types/output.rs:1057-1067).
        #expect(
            WaitAgentMessagesOutput(messages: [], timedOut: true).modelText()
                == "No agent messages arrived before the wait expired."
        )
        #expect(
            WaitAgentMessagesOutput(messages: [], timedOut: false).modelText()
                == "No agent messages are queued."
        )
        let one = WaitAgentMessagesOutput(
            messages: [
                AgentMailboxMessage(
                    messageID: "m1", teamScopeID: "t", fromAgentID: "a",
                    toAgentID: "b", kind: .message, body: "hi", createdAtMS: 7
                )
            ],
            timedOut: false
        )
        #expect(one.modelText().contains("\"body\" : \"hi\""))
    }

    // MARK: Inputs

    @Test("send input rejects unknown fields, matching deny_unknown_fields")
    func sendInputDenyUnknownFields() throws {
        let ok = try JSONDecoder().decode(
            SendAgentMessageInput.self,
            from: Data(#"{"target":"child","message":"hello"}"#.utf8)
        )
        #expect(ok == SendAgentMessageInput(target: "child", message: "hello"))

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                SendAgentMessageInput.self,
                from: Data(#"{"target":"child","message":"hello","kind":"followup_task"}"#.utf8)
            )
        }
    }

    @Test("wait input defaults to 30s and caps at 10 minutes")
    func waitInputTimeoutContract() throws {
        // agent_collaboration/mod.rs:17-18, 291.
        #expect(agentMailboxDefaultWaitMS == 30_000)
        #expect(agentMailboxMaxWaitMS == 600_000)
        #expect(WaitAgentInput().effectiveTimeoutMS() == 30_000)
        #expect(WaitAgentInput(timeoutMS: 0).effectiveTimeoutMS() == 0)
        #expect(WaitAgentInput(timeoutMS: 5_000).effectiveTimeoutMS() == 5_000)
        #expect(WaitAgentInput(timeoutMS: 10_000_000).effectiveTimeoutMS() == 600_000)

        let decoded = try JSONDecoder().decode(
            WaitAgentInput.self, from: Data("{}".utf8)
        )
        #expect(decoded.timeoutMS == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                WaitAgentInput.self, from: Data(#"{"timeout":5}"#.utf8)
            )
        }
    }

    @Test("message validation rejects empty and oversized text")
    func messageValidation() throws {
        // Mirrors `message_validation_rejects_empty_and_oversized_text`
        // (agent_collaboration/mod.rs:319-345).
        #expect(throws: AgentMailboxError.self) {
            try validateAgentMessage(SendAgentMessageInput(target: "child", message: " "))
        }
        #expect(throws: AgentMailboxError.self) {
            try validateAgentMessage(SendAgentMessageInput(target: " ", message: "hi"))
        }
        #expect(throws: AgentMailboxError.self) {
            try validateAgentMessage(
                SendAgentMessageInput(
                    target: "child",
                    message: String(repeating: "x", count: agentMailboxMaxMessageBytes + 1)
                )
            )
        }
        let trimmed = try validateAgentMessage(
            SendAgentMessageInput(target: " child ", message: " hello ")
        )
        #expect(trimmed.target == "child")
        #expect(trimmed.body == "hello")
    }

    // MARK: Tool surface

    @Test("collaboration tool ids, kind, and read-only flags are stable")
    func collaborationToolIdentity() {
        // Mirrors `collaboration_tool_ids_and_kind_are_stable`
        // (agent_collaboration/mod.rs:305-321).
        #expect(
            AgentCollaborationTool.allCases.map(\.toolID)
                == ["list_agents", "send_message", "followup_task", "wait_agent"]
        )
        for tool in AgentCollaborationTool.allCases {
            #expect(tool.kindWireName == "agent_collaboration")
            #expect(!tool.descriptionTemplate.isEmpty)
        }
        #expect(AgentCollaborationTool.listAgents.isReadOnly)
        #expect(AgentCollaborationTool.waitAgent.isReadOnly)
        #expect(!AgentCollaborationTool.sendMessage.isReadOnly)
        #expect(!AgentCollaborationTool.followupTask.isReadOnly)
        #expect(AgentCollaborationTool.sendMessage.messageKind == .message)
        #expect(AgentCollaborationTool.followupTask.messageKind == .followupTask)
        #expect(AgentCollaborationTool.listAgents.messageKind == nil)
        #expect(AgentCollaborationTool.waitAgent.messageKind == nil)
    }

    @Test("task, agent_swarm, and workflow stay three distinct surfaces")
    func threeSurfaceLock() {
        // Mirrors `task_agent_swarm_and_workflow_stay_three_distinct_surfaces`
        // (task/types.rs:1436-1496).
        #expect(
            AgentOrchestrationSurface.allCases.map(\.toolID)
                == ["task", "agent_swarm", "workflow"]
        )
        let kinds = AgentOrchestrationSurface.allCases.map(\.kindWireName)
        #expect(kinds == ["task", "agent_swarm", "workflow"])
        #expect(Set(kinds).count == 3, "each surface keeps its own ToolKind")

        // A lone subagent stands alone: `task` plus the background lifecycle
        // tools it needs, with neither orchestrator present.
        #expect(loneSubagentSurfaceToolIDs == ["task", "get_task_output", "kill_task"])
        #expect(!loneSubagentSurfaceToolIDs.contains(AgentOrchestrationSurface.agentSwarm.toolID))
        #expect(!loneSubagentSurfaceToolIDs.contains(AgentOrchestrationSurface.workflow.toolID))
        #expect(AgentOrchestrationSurface.task.isOrchestrator == false)
        #expect(AgentOrchestrationSurface.agentSwarm.isOrchestrator)
        #expect(AgentOrchestrationSurface.workflow.isOrchestrator)

        // The mailbox is a fourth, separate surface — never one of the three.
        for tool in AgentCollaborationTool.allCases {
            #expect(!AgentOrchestrationSurface.allCases.map(\.toolID).contains(tool.toolID))
        }
    }

    @Test("a swarm-time foreground wait must not cancel its cohort")
    func foregroundWaitTyping() {
        // Mirrors `ForegroundWaitKind` (task/types.rs:1209-1224) and the
        // `enter_kind(Orchestration)` call in agent_swarm/mod.rs:377-378.
        #expect(ForegroundWaitKind.default == .interruptible)
        #expect(ForegroundWaitKind.interruptible.allowsTurnCancellation)
        #expect(ForegroundWaitKind.orchestration.allowsTurnCancellation == false)
    }
}
