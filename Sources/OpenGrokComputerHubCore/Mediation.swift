// Mediation.swift
//
// Host permission/sandbox mediation seam for hub tool calls.
//
// `admitCall` (Transport.swift) is a *transport* gate: scopes the wire
// handshake proved, plus a payload bound. It knows nothing about the
// workspace permission policy, plan mode, PreToolUse hooks, or the
// sandbox — so a hub tool that passes `admitCall` has passed no part of
// the gate order in PORT_PLAN.md.
//
// This file is the seam that closes that. It is deliberately declared in
// Core rather than in OpenGrokWorkspace so the hub targets stay free of a
// dependency on the permission implementation: hosts conform to
// `HubCallMediator` and hand the conformance in. The `PermissionPipeline`
// conformance lives in OpenGrokCLI, where the pipeline is already
// constructed for the agent's own tools.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime

// MARK: - Request

/// Where a mediated call entered the hub. Carried into the verdict so a
/// host can apply a different policy to a tool it registered locally than
/// to one proxied from a remote workspace or bridged from an MCP server.
public enum HubCallOrigin: Sendable, Equatable, Hashable {
    /// A tool registered in this process's local registry.
    case local
    /// A tool proxied over the hub connection to a remote workspace.
    case remote
    /// A tool bridged from an MCP server through the hub adapter.
    /// `server` is the MCP server name from its `initialize` response.
    case mcpBridge(server: String)

    /// Stable label for logs and denial text.
    public var label: String {
        switch self {
        case .local: return "local"
        case .remote: return "remote"
        case .mcpBridge(let server): return "mcp:\(server)"
        }
    }
}

/// One hub tool call, described in terms a host permission system can
/// evaluate without importing any hub type.
public struct HubCallRequest: Sendable {
    public var toolId: ToolId
    public var toolCallId: ToolCallId
    public var sessionId: SessionId?
    public var origin: HubCallOrigin
    public var arguments: JSONValue
    /// The tool's own `is_read_only` claim. Advisory: it is asserted by
    /// the tool (and for `.remote`/`.mcpBridge` by a peer we do not
    /// control), so a host may consult it to pick an `AccessKind` but
    /// must never treat it as authorization on its own.
    public var isReadOnly: Bool

    public init(
        toolId: ToolId,
        toolCallId: ToolCallId,
        sessionId: SessionId? = nil,
        origin: HubCallOrigin,
        arguments: JSONValue,
        isReadOnly: Bool = false
    ) {
        self.toolId = toolId
        self.toolCallId = toolCallId
        self.sessionId = sessionId
        self.origin = origin
        self.arguments = arguments
        self.isReadOnly = isReadOnly
    }
}

// MARK: - Verdict

/// Outcome of host mediation. There is no third "unknown" case on
/// purpose: a host that cannot decide must return `.deny`, because a
/// mediator that can express "I don't know" is a mediator whose callers
/// will eventually treat "don't know" as "yes".
public enum HubMediationVerdict: Sendable, Equatable {
    case allow
    case deny(reason: String)

    public var isAllow: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// Host gate consulted before a hub tool call is dispatched.
public protocol HubCallMediator: Sendable {
    func mediate(_ request: HubCallRequest) async -> HubMediationVerdict
}

// MARK: - Posture

/// A harness or bridge's declared mediation posture.
///
/// There is no default. Every construction site must say which of these
/// it is, so that an unmediated hub surface is a written, greppable
/// claim rather than an omission — AGENTS.md §5: the next author copies
/// whichever gate they find open first.
public enum HubMediation: Sendable {
    /// Every call is evaluated by the host's permission system before
    /// dispatch.
    case mediated(any HubCallMediator)

    /// No host gate on this surface. Legitimate only where no agent can
    /// reach it (fixtures, wire-codec tests, protocol conformance
    /// exercises). `reason` is recorded so an audit can read the claim
    /// and check it.
    case unmediated(reason: String)

    /// The gate, or `nil` when this surface declared itself unmediated.
    public var mediator: (any HubCallMediator)? {
        switch self {
        case .mediated(let m): return m
        case .unmediated: return nil
        }
    }

    /// Evaluate `request` under this posture.
    ///
    /// Returns `nil` when the call may proceed, or the terminal
    /// `ToolError` that must be returned to the caller. Never weaken a
    /// non-nil result: it is the gate's answer, not a hint.
    public func admit(_ request: HubCallRequest) async -> ToolError? {
        guard let mediator else { return nil }
        switch await mediator.mediate(request) {
        case .allow:
            return nil
        case .deny(let reason):
            return hubMediationDeniedError(request: request, reason: reason)
        }
    }
}

/// The terminal error a denied hub call returns.
///
/// `permissionDenied` (not `custom`) so it maps to the wire's
/// `permission_denied` / JSON-RPC -32003 exactly as a denial from the
/// agent's own tool path does — a model must not be able to tell a
/// hub-mediated denial from a local one and retry around it.
public func hubMediationDeniedError(
    request: HubCallRequest,
    reason: String
) -> ToolError {
    .permissionDenied(
        "\(request.toolId.rawValue) (\(request.origin.label)): \(reason)"
    )
}

// MARK: - Built-in mediators

/// Denies every call. The value a host installs when it knows a gate is
/// required but has not got one — "no pipeline means *cannot authorize*,
/// so deny" (AGENTS.md §5).
public struct DenyAllHubMediator: HubCallMediator {
    public let reason: String

    public init(reason: String = "no permission pipeline is installed for this hub surface") {
        self.reason = reason
    }

    public func mediate(_ request: HubCallRequest) async -> HubMediationVerdict {
        _ = request
        return .deny(reason: reason)
    }
}

/// Allows every call. Test-only: it exists so a test that means "the gate
/// said yes" states that, instead of reaching for `.unmediated` and
/// accidentally testing the ungated path.
public struct AllowAllHubMediator: HubCallMediator {
    public init() {}

    public func mediate(_ request: HubCallRequest) async -> HubMediationVerdict {
        _ = request
        return .allow
    }
}
