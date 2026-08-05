// AgentCollaborationTools.swift
//
// Open Grok — the model-facing half of the team-scoped subagent mailbox.
//
// Rust provenance (pin `9ed09e2a`):
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/agent_collaboration/mod.rs
//     — tool ids, capabilities, argument validation, message stamping, and the
//       `run` bodies that dispatch into the subagent backend.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/backend.rs:56-83
//     — the `SubagentBackend` mailbox defaults used by hosts that expose no
//       mailbox (empty roster, "unavailable" send error, timed-out wait).
//   * crates/codegen/xai-grok-tools/src/types/tool_io.rs:81-85 — `send_message`
//     and `followup_task` share one input shape; the wire tool name and the
//     message kind carry the wake semantics.
//
// The wire types themselves live in `OpenGrokToolTypes`; this file owns the
// tool surface (schemas, dispatch, stamping) and the host-facing backend seam.

import Foundation
import OpenGrokShared
import OpenGrokToolTypes

// MARK: - Backend seam

/// Host seam for the mailbox half of the subagent backend.
///
/// Mirrors the three default methods Rust added to `SubagentBackend`
/// (backend.rs:56-83). Every method has a default that matches Rust's, so a
/// host with no mailbox degrades exactly the way the Rust default does rather
/// than trapping.
public protocol AgentMailboxBackend: Sendable {
    func listAgents(identity: AgentMailboxIdentity) async -> ListAgentsOutput

    func sendAgentMessage(
        identity: AgentMailboxIdentity,
        target: String,
        message: AgentMailboxMessage
    ) async throws -> AgentMessageSendOutput

    func waitAgentMessages(
        identity: AgentMailboxIdentity,
        timeoutMS: UInt64
    ) async -> WaitAgentMessagesOutput
}

extension AgentMailboxBackend {
    /// Rust `SubagentBackend::list_agents` default (backend.rs:56-61).
    public func listAgents(identity: AgentMailboxIdentity) async -> ListAgentsOutput {
        ListAgentsOutput(teamScopeID: identity.teamScopeID, agents: [])
    }

    /// Rust `SubagentBackend::send_agent_message` default (backend.rs:63-72).
    public func sendAgentMessage(
        identity: AgentMailboxIdentity,
        target: String,
        message: AgentMailboxMessage
    ) async throws -> AgentMessageSendOutput {
        throw AgentMailboxError.backendUnavailable
    }

    /// Rust `SubagentBackend::wait_agent_messages` default (backend.rs:74-83).
    public func waitAgentMessages(
        identity: AgentMailboxIdentity,
        timeoutMS: UInt64
    ) async -> WaitAgentMessagesOutput {
        WaitAgentMessagesOutput(messages: [], timedOut: true)
    }
}

// MARK: - Tool surface

/// Executes the four collaboration tools against a mailbox backend.
///
/// `messageID` and `createdAtMS` are injected rather than read from the
/// ambient clock so goldens stay reproducible; Rust stamps them with
/// `Uuid::now_v7()` and `SystemTime::now()` in `stamped_message`
/// (agent_collaboration/mod.rs:104-124).
public struct AgentCollaborationToolSurface: Sendable {
    public var makeMessageID: @Sendable () -> String
    public var now: @Sendable () -> UInt64

    public init(
        makeMessageID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.makeMessageID = makeMessageID
        self.now = now
    }

    // MARK: Schemas

    /// `list_agents` takes no arguments.
    public static let listAgentsSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    /// Shared by `send_message` and `followup_task`. `additionalProperties:
    /// false` is the schema form of Rust's `deny_unknown_fields`.
    public static let sendMessageSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "target": .object([
                "type": .string("string"),
                "description": .string(
                    "Agent ID from list_agents, or \"root\" for the team root."
                ),
            ]),
            "message": .object([
                "type": .string("string"),
                "description": .string("Message text to queue for the target agent."),
            ]),
        ]),
        "required": .array([.string("target"), .string("message")]),
        "additionalProperties": .bool(false),
    ])

    public static let waitAgentSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "timeout_ms": .object([
                "type": .string("integer"),
                "minimum": .number(.int64(0)),
                "description": .string(
                    "Maximum wait in milliseconds. Omit for 30 seconds; pass 0 for a "
                        + "non-blocking inbox poll."
                ),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    /// Input schema for a collaboration tool.
    public static func inputSchema(for tool: AgentCollaborationTool) -> JSONValue {
        switch tool {
        case .listAgents: return listAgentsSchema
        case .sendMessage, .followupTask: return sendMessageSchema
        case .waitAgent: return waitAgentSchema
        }
    }

    // MARK: Runs

    /// Rust `ListAgentsTool::run` (agent_collaboration/mod.rs:186-193).
    public func listAgents(
        identity: AgentMailboxIdentity,
        backend: some AgentMailboxBackend
    ) async -> ListAgentsOutput {
        await backend.listAgents(identity: identity)
    }

    /// Rust `message_tool!` `run` body (agent_collaboration/mod.rs:232-244):
    /// validate, stamp, dispatch. `tool` selects the stamped message kind, so
    /// `send_message` queues and `followup_task` wakes.
    public func sendMessage(
        _ tool: AgentCollaborationTool,
        input: SendAgentMessageInput,
        identity: AgentMailboxIdentity,
        backend: some AgentMailboxBackend
    ) async throws -> AgentMessageSendOutput {
        guard let kind = tool.messageKind else {
            throw AgentMailboxError.emptyTarget
        }
        let (target, body) = try validateAgentMessage(input)
        let message = stampedMessage(
            identity: identity,
            target: target,
            body: body,
            kind: kind
        )
        return try await backend.sendAgentMessage(
            identity: identity,
            target: target,
            message: message
        )
    }

    /// Rust `WaitAgentTool::run` (agent_collaboration/mod.rs:286-297).
    public func waitAgent(
        input: WaitAgentInput,
        identity: AgentMailboxIdentity,
        backend: some AgentMailboxBackend
    ) async -> WaitAgentMessagesOutput {
        await backend.waitAgentMessages(
            identity: identity,
            timeoutMS: input.effectiveTimeoutMS()
        )
    }

    /// Stamp the runtime-owned fields the model never supplies.
    ///
    /// Mirrors Rust `stamped_message` (agent_collaboration/mod.rs:104-124).
    public func stampedMessage(
        identity: AgentMailboxIdentity,
        target: String,
        body: String,
        kind: AgentMailboxMessageKind
    ) -> AgentMailboxMessage {
        AgentMailboxMessage(
            messageID: makeMessageID(),
            teamScopeID: identity.teamScopeID,
            fromAgentID: identity.agentID,
            toAgentID: target,
            kind: kind,
            body: body,
            createdAtMS: now()
        )
    }
}
