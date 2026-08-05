// AgentCollaborationToolsTests.swift
//
// The model-facing collaboration tool surface: schemas, stamping, dispatch,
// and the backend defaults a host without a mailbox falls back to.
//
// Rust provenance (pin `9ed09e2a`, commit 7957721e):
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/agent_collaboration/mod.rs:104-124
//     — `stamped_message`.
//   * .../agent_collaboration/mod.rs:186-297 — the four `Tool::run` bodies.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/backend.rs:56-83
//     — the `SubagentBackend` mailbox defaults.

import Foundation
import OpenGrokShared
import OpenGrokToolTypes
import Testing

@testable import OpenGrokAgentControlTools

/// A host with no mailbox: takes every `AgentMailboxBackend` default.
private struct DefaultOnlyBackend: AgentMailboxBackend {}

/// Records what the surface handed the backend.
private actor RecordingBackend: AgentMailboxBackend {
    private(set) var sent: [AgentMailboxMessage] = []
    private(set) var waitedTimeouts: [UInt64] = []
    private(set) var rosterCalls = 0

    func listAgents(identity: AgentMailboxIdentity) async -> ListAgentsOutput {
        rosterCalls += 1
        return ListAgentsOutput(
            teamScopeID: identity.teamScopeID,
            agents: [
                AgentRosterEntry(
                    agentID: identity.teamScopeID, isRoot: true, status: "running",
                    description: "Root agent"
                )
            ]
        )
    }

    func sendAgentMessage(
        identity: AgentMailboxIdentity,
        target: String,
        message: AgentMailboxMessage
    ) async throws -> AgentMessageSendOutput {
        sent.append(message)
        return AgentMessageSendOutput(
            messageID: message.messageID,
            targetAgentID: target,
            status: message.kind.wakesRecipient ? .delivered : .queued
        )
    }

    func waitAgentMessages(
        identity: AgentMailboxIdentity,
        timeoutMS: UInt64
    ) async -> WaitAgentMessagesOutput {
        waitedTimeouts.append(timeoutMS)
        return WaitAgentMessagesOutput(messages: [], timedOut: true)
    }
}

@Suite("AgentCollaborationTools")
struct AgentCollaborationToolsTests {
    private let identity = AgentMailboxIdentity(teamScopeID: "parent", agentID: "parent")

    private var surface: AgentCollaborationToolSurface {
        AgentCollaborationToolSurface(makeMessageID: { "m-fixed" }, now: { 1_700_000_000_000 })
    }

    @Test("send_message and followup_task share an input shape but stamp different kinds")
    func sharedInputDistinctKinds() async throws {
        let backend = RecordingBackend()
        let input = SendAgentMessageInput(target: " mail-child ", message: " hello ")

        let queued = try await surface.sendMessage(
            .sendMessage, input: input, identity: identity, backend: backend
        )
        #expect(queued.status == .queued)
        #expect(queued.targetAgentID == "mail-child")

        let woken = try await surface.sendMessage(
            .followupTask, input: input, identity: identity, backend: backend
        )
        #expect(woken.status == .delivered)

        let sent = await backend.sent
        #expect(sent.map(\.kind) == [.message, .followupTask])
        // Validation trimmed both fields before stamping.
        #expect(sent.allSatisfy { $0.body == "hello" && $0.toAgentID == "mail-child" })
        // Runtime-owned fields come from the surface, never the model.
        #expect(sent.allSatisfy {
            $0.messageID == "m-fixed"
                && $0.createdAtMS == 1_700_000_000_000
                && $0.teamScopeID == "parent"
                && $0.fromAgentID == "parent"
        })
    }

    @Test("an invalid send never reaches the backend")
    func validationRunsBeforeDispatch() async throws {
        let backend = RecordingBackend()
        await #expect(throws: AgentMailboxError.self) {
            try await surface.sendMessage(
                .sendMessage,
                input: SendAgentMessageInput(target: "child", message: "   "),
                identity: identity,
                backend: backend
            )
        }
        #expect(await backend.sent.isEmpty)
    }

    @Test("wait_agent applies the default and the cap before dispatching")
    func waitTimeoutIsResolvedBySurface() async {
        let backend = RecordingBackend()
        _ = await surface.waitAgent(input: WaitAgentInput(), identity: identity, backend: backend)
        _ = await surface.waitAgent(
            input: WaitAgentInput(timeoutMS: 0), identity: identity, backend: backend
        )
        _ = await surface.waitAgent(
            input: WaitAgentInput(timeoutMS: 10_000_000), identity: identity, backend: backend
        )
        #expect(await backend.waitedTimeouts == [30_000, 0, 600_000])
    }

    @Test("list_agents forwards the caller's identity unchanged")
    func listAgentsDispatch() async {
        let backend = RecordingBackend()
        let roster = await surface.listAgents(identity: identity, backend: backend)
        #expect(roster.teamScopeID == "parent")
        #expect(roster.agents.count == 1)
        #expect(roster.agents[0].isRoot)
        #expect(await backend.rosterCalls == 1)
    }

    @Test("a host with no mailbox degrades exactly like the Rust defaults")
    func backendDefaults() async throws {
        let backend = DefaultOnlyBackend()
        let roster = await backend.listAgents(identity: identity)
        #expect(roster == ListAgentsOutput(teamScopeID: "parent", agents: []))

        let waited = await backend.waitAgentMessages(identity: identity, timeoutMS: 5_000)
        #expect(waited == WaitAgentMessagesOutput(messages: [], timedOut: true))

        await #expect(throws: AgentMailboxError.backendUnavailable) {
            try await backend.sendAgentMessage(
                identity: identity,
                target: "child",
                message: surface.stampedMessage(
                    identity: identity, target: "child", body: "x", kind: .message
                )
            )
        }
    }

    @Test("input schemas mirror deny_unknown_fields and the shared send shape")
    func inputSchemas() {
        let send = AgentCollaborationToolSurface.inputSchema(for: .sendMessage)
        #expect(send == AgentCollaborationToolSurface.inputSchema(for: .followupTask))
        #expect(send["additionalProperties"] == .bool(false))
        #expect(send["required"] == .array([.string("target"), .string("message")]))

        let wait = AgentCollaborationToolSurface.inputSchema(for: .waitAgent)
        #expect(wait["additionalProperties"] == .bool(false))
        #expect(wait["properties"]?["timeout_ms"] != nil)

        let list = AgentCollaborationToolSurface.inputSchema(for: .listAgents)
        #expect(list["properties"] == .object([:]))
    }
}
