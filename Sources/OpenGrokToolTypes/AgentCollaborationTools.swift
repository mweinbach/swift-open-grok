// AgentCollaborationTools.swift
//
// Open Grok — Swift port of the team-scoped subagent mailbox surface.
//
// Rust provenance (pin `9ed09e2a`):
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/agent_collaboration/mod.rs
//     — the four tools (`list_agents`, `send_message`, `followup_task`,
//       `wait_agent`), their inputs, limits, and description templates.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/types.rs:186-278
//     — `AgentMailboxIdentity`, `AgentMailboxMessageKind`,
//       `AgentMailboxMessage`, `AgentRosterEntry`, `ListAgentsOutput`,
//       `AgentMessageDeliveryStatus`, `AgentMessageSendOutput`,
//       `WaitAgentMessagesOutput`.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/types.rs:1206-1246
//     — `ForegroundWaitKind` and the typed foreground-wait factory.
//
// Wire shape mirrors serde: snake_case keys, `Option` fields omitted when
// `nil` (`skip_serializing_if = "Option::is_none"`), and `deny_unknown_fields`
// on the two model-facing inputs that carry it.

import Foundation
import OpenGrokShared

// MARK: - Identity

/// Team identity injected into every model-facing session.
///
/// `agentID` is the current session ID; `teamScopeID` is the root session that
/// owns the flat subagent cohort. Keeping these separate lets children address
/// siblings without weakening the parent-session scoping used by task polling
/// and cancellation.
///
/// Mirrors Rust `AgentMailboxIdentity` (task/types.rs:186-194). Rust registers
/// it as a shared tool resource rather than a wire type, so it is deliberately
/// not `Codable` here either.
public struct AgentMailboxIdentity: Sendable, Hashable {
    public var teamScopeID: String
    public var agentID: String

    public init(teamScopeID: String, agentID: String) {
        self.teamScopeID = teamScopeID
        self.agentID = agentID
    }

    /// `true` when this identity is the team root (the root session addresses
    /// itself by the scope id).
    public var isRoot: Bool { teamScopeID == agentID }
}

// MARK: - Message

/// Whether a mailbox message merely queues or also wakes the recipient.
///
/// Mirrors Rust `AgentMailboxMessageKind` (task/types.rs:196-212).
public enum AgentMailboxMessageKind: String, Codable, Sendable, Hashable, CaseIterable {
    case message
    case followupTask = "followup_task"

    /// Mirrors Rust `AgentMailboxMessageKind::wakes_recipient`
    /// (task/types.rs:207-211): only `followup_task` wakes.
    public var wakesRecipient: Bool { self == .followupTask }
}

/// One immutable peer message. Runtime-owned fields are never accepted from
/// the model; the send tools stamp them before dispatch.
///
/// Mirrors Rust `AgentMailboxMessage` (task/types.rs:214-227).
public struct AgentMailboxMessage: Codable, Sendable, Hashable {
    public var messageID: String
    public var teamScopeID: String
    public var fromAgentID: String
    public var toAgentID: String
    public var kind: AgentMailboxMessageKind
    public var body: String
    public var createdAtMS: UInt64

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case teamScopeID = "team_scope_id"
        case fromAgentID = "from_agent_id"
        case toAgentID = "to_agent_id"
        case kind
        case body
        case createdAtMS = "created_at_ms"
    }

    public init(
        messageID: String,
        teamScopeID: String,
        fromAgentID: String,
        toAgentID: String,
        kind: AgentMailboxMessageKind,
        body: String,
        createdAtMS: UInt64
    ) {
        self.messageID = messageID
        self.teamScopeID = teamScopeID
        self.fromAgentID = fromAgentID
        self.toAgentID = toAgentID
        self.kind = kind
        self.body = body
        self.createdAtMS = createdAtMS
    }
}

// MARK: - Roster

/// One row of the `list_agents` roster.
///
/// Mirrors Rust `AgentRosterEntry` (task/types.rs:229-245). The four optional
/// fields are omitted from the wire when `nil`.
public struct AgentRosterEntry: Codable, Sendable, Hashable {
    public var agentID: String
    public var isRoot: Bool
    public var status: String
    public var subagentType: String?
    public var description: String?
    public var resumedFrom: String?
    public var worktreePath: String?

    private enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case isRoot = "is_root"
        case status
        case subagentType = "subagent_type"
        case description
        case resumedFrom = "resumed_from"
        case worktreePath = "worktree_path"
    }

    public init(
        agentID: String,
        isRoot: Bool,
        status: String,
        subagentType: String? = nil,
        description: String? = nil,
        resumedFrom: String? = nil,
        worktreePath: String? = nil
    ) {
        self.agentID = agentID
        self.isRoot = isRoot
        self.status = status
        self.subagentType = subagentType
        self.description = description
        self.resumedFrom = resumedFrom
        self.worktreePath = worktreePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.agentID = try c.decode(String.self, forKey: .agentID)
        self.isRoot = try c.decode(Bool.self, forKey: .isRoot)
        self.status = try c.decode(String.self, forKey: .status)
        self.subagentType = try c.decodeIfPresent(String.self, forKey: .subagentType)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.resumedFrom = try c.decodeIfPresent(String.self, forKey: .resumedFrom)
        self.worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentID, forKey: .agentID)
        try c.encode(isRoot, forKey: .isRoot)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(subagentType, forKey: .subagentType)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(resumedFrom, forKey: .resumedFrom)
        try c.encodeIfPresent(worktreePath, forKey: .worktreePath)
    }
}

/// Output of `list_agents`.
///
/// Mirrors Rust `ListAgentsOutput` (task/types.rs:247-251).
public struct ListAgentsOutput: Codable, Sendable, Hashable {
    public var teamScopeID: String
    public var agents: [AgentRosterEntry]

    private enum CodingKeys: String, CodingKey {
        case teamScopeID = "team_scope_id"
        case agents
    }

    public init(teamScopeID: String, agents: [AgentRosterEntry]) {
        self.teamScopeID = teamScopeID
        self.agents = agents
    }
}

// MARK: - Send / wait outputs

/// Whether a send landed in a mailbox or was handed straight to a live
/// recipient.
///
/// Mirrors Rust `AgentMessageDeliveryStatus` (task/types.rs:253-261).
public enum AgentMessageDeliveryStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case queued
    case delivered
}

/// Output of `send_message` / `followup_task`.
///
/// Mirrors Rust `AgentMessageSendOutput` (task/types.rs:263-270).
public struct AgentMessageSendOutput: Codable, Sendable, Hashable {
    public var messageID: String
    public var targetAgentID: String
    public var status: AgentMessageDeliveryStatus

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case targetAgentID = "target_agent_id"
        case status
    }

    public init(messageID: String, targetAgentID: String, status: AgentMessageDeliveryStatus) {
        self.messageID = messageID
        self.targetAgentID = targetAgentID
        self.status = status
    }
}

/// Output of `wait_agent`.
///
/// Mirrors Rust `WaitAgentMessagesOutput` (task/types.rs:272-278).
public struct WaitAgentMessagesOutput: Codable, Sendable, Hashable {
    public var messages: [AgentMailboxMessage]
    public var timedOut: Bool

    private enum CodingKeys: String, CodingKey {
        case messages
        case timedOut = "timed_out"
    }

    public init(messages: [AgentMailboxMessage], timedOut: Bool) {
        self.messages = messages
        self.timedOut = timedOut
    }

    /// Model-facing rendering, mirroring Rust
    /// `ToolOutput::WaitAgentMessages` in types/output.rs:1057-1067.
    public func modelText() -> String {
        if messages.isEmpty {
            return timedOut
                ? "No agent messages arrived before the wait expired."
                : "No agent messages are queued."
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(messages),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}

// MARK: - Tool inputs

/// Input for `list_agents` — no arguments.
///
/// Mirrors Rust `ListAgentsInput` (agent_collaboration/mod.rs:32-33).
public struct ListAgentsInput: Codable, Sendable, Hashable {
    public init() {}

    public init(from decoder: Decoder) throws {
        // Rust's `ListAgentsInput` has no `deny_unknown_fields`, so extra keys
        // are tolerated. Accept any object shape.
        _ = decoder
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        _ = c
    }
}

/// Input shared by `send_message` and `followup_task`; the wire tool name
/// distinguishes the two and the wake semantics live in the message kind.
///
/// Mirrors Rust `SendAgentMessageInput` (agent_collaboration/mod.rs:35-42),
/// including `#[serde(deny_unknown_fields)]`.
public struct SendAgentMessageInput: Codable, Sendable, Hashable {
    /// Agent ID from `list_agents`, or `"root"` for the team root.
    public var target: String
    /// Message text to queue for the target agent.
    public var message: String

    private enum CodingKeys: String, CodingKey {
        case target
        case message
    }

    public init(target: String, message: String) {
        self.target = target
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        // deny_unknown_fields: decode the raw map first so unknown keys are
        // visible, matching serde's rejection rather than silently dropping.
        let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
        let known: Set<String> = ["target", "message"]
        if let unknown = raw.keys.first(where: { !known.contains($0) }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown field \(unknown) in SendAgentMessageInput"
                )
            )
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.target = try c.decode(String.self, forKey: .target)
        self.message = try c.decode(String.self, forKey: .message)
    }
}

/// Input for `wait_agent`.
///
/// Mirrors Rust `WaitAgentInput` (agent_collaboration/mod.rs:44-52),
/// including `#[serde(deny_unknown_fields)]` and `#[serde(default)]` on
/// `timeout_ms`.
public struct WaitAgentInput: Codable, Sendable, Hashable {
    /// Maximum wait in milliseconds. Omit for 30 seconds; pass `0` for a
    /// non-blocking inbox poll.
    public var timeoutMS: UInt64?

    private enum CodingKeys: String, CodingKey {
        case timeoutMS = "timeout_ms"
    }

    public init(timeoutMS: UInt64? = nil) {
        self.timeoutMS = timeoutMS
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
        if let unknown = raw.keys.first(where: { $0 != "timeout_ms" }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown field \(unknown) in WaitAgentInput"
                )
            )
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.timeoutMS = try c.decodeIfPresent(UInt64.self, forKey: .timeoutMS)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(timeoutMS, forKey: .timeoutMS)
    }

    /// The effective wait, defaulted and capped by the tool contract.
    ///
    /// Mirrors `agent_collaboration/mod.rs:291`:
    /// `input.timeout_ms.unwrap_or(DEFAULT_WAIT_MS).min(MAX_WAIT_MS)`.
    public func effectiveTimeoutMS() -> UInt64 {
        min(timeoutMS ?? agentMailboxDefaultWaitMS, agentMailboxMaxWaitMS)
    }
}

// MARK: - Contract limits

/// Maximum accepted `message` body size, in bytes.
/// Rust `MAX_AGENT_MESSAGE_BYTES` (agent_collaboration/mod.rs:16).
public let agentMailboxMaxMessageBytes: Int = 32 * 1024

/// Default `wait_agent` timeout. Rust `DEFAULT_WAIT_MS`
/// (agent_collaboration/mod.rs:17).
public let agentMailboxDefaultWaitMS: UInt64 = 30_000

/// Ceiling on `wait_agent` timeout. Rust `MAX_WAIT_MS`
/// (agent_collaboration/mod.rs:18).
public let agentMailboxMaxWaitMS: UInt64 = 600_000

/// Per-recipient mailbox depth before sends are rejected.
/// Rust `MAX_MAILBOX_MESSAGES` (task/coordinator.rs:707).
public let agentMailboxMaxQueuedMessages: Int = 128

/// Messages drained by a single `wait_agent` call.
/// Rust `MAX_DRAIN_MESSAGES` (task/coordinator.rs:724).
public let agentMailboxMaxDrainMessages: Int = 20

// MARK: - Validation

public enum AgentMailboxError: Error, Sendable, Hashable, CustomStringConvertible {
    case emptyTarget
    case emptyMessage
    case messageTooLarge(Int)
    case selfSend
    case unknownTarget(target: String, teamScopeID: String)
    case identityMismatch
    case targetFinished(String)
    case mailboxFull
    case targetUnavailable(String)
    case backendUnavailable

    public var description: String {
        switch self {
        case .emptyTarget:
            return "target must not be empty"
        case .emptyMessage:
            return "message must not be empty"
        case .messageTooLarge:
            return "message exceeds the \(agentMailboxMaxMessageBytes)-byte limit"
        case .selfSend:
            return "Cannot send an agent message to the calling agent itself"
        case .unknownTarget(let target, let scope):
            return "Agent '\(target)' was not found in team '\(scope)'"
        case .identityMismatch:
            return "Agent message identity did not match the calling session"
        case .targetFinished(let target):
            return "Agent '\(target)' has finished. Continue it with "
                + "task(resume_from=\"\(target)\") before sending more work."
        case .mailboxFull:
            return "Recipient mailbox is full (maximum \(agentMailboxMaxQueuedMessages) messages)"
        case .targetUnavailable(let target):
            return "Agent '\(target)' is not available for a follow-up"
        case .backendUnavailable:
            return "Agent mailbox is unavailable in this host"
        }
    }
}

/// Trim and bound-check a send input, returning the canonical
/// `(target, body)` pair.
///
/// Mirrors Rust `validate_message` (agent_collaboration/mod.rs:80-102).
public func validateAgentMessage(_ input: SendAgentMessageInput) throws -> (target: String, body: String) {
    let target = input.target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { throw AgentMailboxError.emptyTarget }
    let message = input.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { throw AgentMailboxError.emptyMessage }
    let byteCount = message.utf8.count
    guard byteCount <= agentMailboxMaxMessageBytes else {
        throw AgentMailboxError.messageTooLarge(byteCount)
    }
    return (target, message)
}

// MARK: - Tool surface

/// The four collaboration tools, in registration order.
///
/// Mirrors the Rust registrations in
/// `xai-grok-tools/src/registry/types.rs:704-707` and the metadata blocks in
/// `agent_collaboration/mod.rs:146-165`.
public enum AgentCollaborationTool: String, Sendable, Hashable, CaseIterable {
    case listAgents = "list_agents"
    case sendMessage = "send_message"
    case followupTask = "followup_task"
    case waitAgent = "wait_agent"

    /// Stable tool id on the wire.
    public var toolID: String { rawValue }

    /// Every collaboration tool carries `ToolKind::AgentCollaboration`.
    public var kindWireName: String { agentCollaborationToolKindWireName }

    /// Rust `ToolMetadata::is_read_only` per tool
    /// (agent_collaboration/mod.rs:146-165).
    public var isReadOnly: Bool {
        switch self {
        case .listAgents, .waitAgent: return true
        case .sendMessage, .followupTask: return false
        }
    }

    /// The message kind a send through this tool stamps, or `nil` for the
    /// non-sending tools. Rust `message_tool!` invocations
    /// (agent_collaboration/mod.rs:249-258).
    public var messageKind: AgentMailboxMessageKind? {
        switch self {
        case .sendMessage: return .message
        case .followupTask: return .followupTask
        case .listAgents, .waitAgent: return nil
        }
    }

    /// Verbatim model-facing description from
    /// `agent_collaboration/mod.rs:146-165`.
    public var descriptionTemplate: String {
        switch self {
        case .listAgents:
            return "List the root and subagents in this session's collaboration team. "
                + "Returns stable agent IDs, lifecycle status, task labels, resume provenance, "
                + "and worktree paths. It does not expose agent transcripts."
        case .sendMessage:
            return "Queue a message in another live agent's mailbox without starting a new turn. "
                + "Use list_agents to discover exact target IDs. The recipient reads queued "
                + "messages with wait_agent."
        case .followupTask:
            return "Send a follow-up task to another live agent and wake it promptly. "
                + "Running recipients receive the message at a safe model boundary; idle root "
                + "sessions start a synthetic follow-up turn."
        case .waitAgent:
            return "Read this agent's queued mailbox messages, waiting for activity when "
                + "requested. Only messages addressed to the calling agent are returned."
        }
    }
}

/// Wire spelling of `ToolKind::AgentCollaboration`
/// (`xai-grok-tools/src/types/tool.rs:92`).
public let agentCollaborationToolKindWireName = "agent_collaboration"

/// Tool ids of the four collaboration tools, in registration order.
public let agentCollaborationToolIDs: [String] = AgentCollaborationTool.allCases.map(\.toolID)

// MARK: - Three-surface lock

/// `task`, `agent_swarm`, and `workflow` are three separate model surfaces
/// built on the same subagent machinery. They must stay separately
/// addressable so packs and Code Mode can gate them apart, and a lone
/// subagent must stand alone without either orchestrator present.
///
/// Mirrors Rust `task_agent_swarm_and_workflow_stay_three_distinct_surfaces`
/// (task/types.rs:1436-1496).
public enum AgentOrchestrationSurface: String, Sendable, Hashable, CaseIterable {
    case task
    case agentSwarm = "agent_swarm"
    case workflow

    /// Stable tool id.
    public var toolID: String { rawValue }

    /// Wire spelling of the surface's own `ToolKind` — one per surface, never
    /// shared.
    public var kindWireName: String { rawValue }

    /// Whether this surface is an orchestrator layered on top of `task`.
    /// `task` alone is a complete surface; the other two orchestrate cohorts.
    public var isOrchestrator: Bool { self != .task }
}

/// The background lifecycle tools a lone `task` surface still needs to manage
/// what it spawns — no swarm, no workflow.
/// Rust `lone_subagent` (task/types.rs:1467).
public let loneSubagentSurfaceToolIDs: [String] = ["task", "get_task_output", "kill_task"]

// MARK: - Foreground wait typing

/// What the running turn is parked on, so the host can decide whether an
/// arriving user prompt may abort the turn.
///
/// A single foreground child (`task`) is cheap to restart, so the host aborts
/// the turn and runs the new prompt immediately. A swarm is a live cohort whose
/// members all die with the turn, so aborting would throw away in-flight work
/// the user did not ask to discard.
///
/// Mirrors Rust `ForegroundWaitKind` (task/types.rs:1209-1224).
public enum ForegroundWaitKind: String, Sendable, Hashable, CaseIterable {
    /// One foreground child; a user prompt may abort the turn.
    case interruptible
    /// A multi-member cohort; a user prompt must reach the orchestrator
    /// without aborting the turn.
    case orchestration

    /// Rust `#[default] Interruptible` (task/types.rs:1218-1219).
    public static let `default`: ForegroundWaitKind = .interruptible

    /// Whether an arriving prompt may cancel the turn this wait belongs to.
    ///
    /// `agent_swarm` enters with `.orchestration` so `queue_input` promotes the
    /// prompt to run next instead of aborting and cancelling every live member
    /// (`agent_swarm/mod.rs:377-378`, commit `12359ba6`).
    public var allowsTurnCancellation: Bool { self == .interruptible }
}
