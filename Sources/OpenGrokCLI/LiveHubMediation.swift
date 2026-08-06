// LiveHubMediation.swift
//
// The conformance that makes `HubCallMediator` real: it routes a Computer Hub
// tool call into the same `PermissionPipeline` the agent's own tools go
// through, so a hub tool cannot be the one path that skips plan mode,
// PreToolUse hooks, the permission policy, and the sandbox requirement.
//
// It lives here rather than in the hub targets on purpose. `OpenGrokWorkspace`
// owns the pipeline and `OpenGrokComputerHub*` must not depend on it — the
// seam is the protocol in `OpenGrokComputerHubCore/Mediation.swift`, and this
// is the only place the two halves meet.
//
// Gate order is PORT_PLAN.md's and is enforced by `PermissionPipeline.prepare`
// itself; this type's whole job is to pick the right `AccessKind` and to
// refuse to guess.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokWorkspace

/// Routes hub tool calls through the workspace `PermissionPipeline`.
public struct LivePermissionHubMediator: HubCallMediator {
    private let pipeline: PermissionPipeline
    /// Permission-mode label surfaced in the prompt, matching what the
    /// agent's own tool path passes.
    private let permissionModeLabel: String?

    public init(pipeline: PermissionPipeline, permissionModeLabel: String? = nil) {
        self.pipeline = pipeline
        self.permissionModeLabel = permissionModeLabel
    }

    public func mediate(_ request: HubCallRequest) async -> HubMediationVerdict {
        let prepared = await pipeline.prepare(
            PrepareToolAccessRequest(
                access: Self.accessKind(for: request),
                toolName: request.toolId.rawValue,
                toolCallId: request.toolCallId.rawValue,
                permissionModeLabel: permissionModeLabel
            )
        )
        guard prepared.mayDispatch else {
            return .deny(reason: Self.reason(for: prepared))
        }
        return .allow
    }

    /// Classify a hub call for the permission policy.
    ///
    /// Everything reaching the hub is classified as `.mcpTool`, including
    /// tools this process registered locally. That is deliberate: the hub is
    /// an out-of-process tool plane, its tool names are chosen by the peer,
    /// and the arguments are the peer's schema — so the `mcp` rule family is
    /// the one a user's `permissions` config can actually express a rule
    /// about. Mapping a hub call onto `.read`/`.edit`/`.bash` would require
    /// trusting the peer's own description of what it is about to do.
    static func accessKind(for request: HubCallRequest) -> AccessKind {
        .mcpTool(name: request.toolId.rawValue, input: request.arguments)
    }

    /// Text the model sees. Carries the deciding gate, because "denied" with
    /// no source is the report that sends someone reading the wrong config
    /// file.
    static func reason(for prepared: PreparedToolAccess) -> String {
        let detail: String
        switch prepared.decision {
        case .allow:
            // Unreachable: `mayDispatch` is exactly `decision.isAllow`.
            detail = "allowed"
        case .ask:
            // An unanswered `ask` is a denial here. The hub call has no
            // interactive prompt attached to it, and treating "needs asking"
            // as "yes" is precisely the fail-open this seam exists to stop.
            detail = "requires approval, and this hub call has no prompt attached"
        case .followupMessage(let message):
            detail = message
        case .reject(let message):
            detail = message
        case .policyDeny(let message):
            detail = message
        case .cancelled:
            detail = "cancelled"
        }
        if let reason = prepared.reason, reason != detail {
            return "\(detail) [\(prepared.source.rawValue): \(reason)]"
        }
        return "\(detail) [\(prepared.source.rawValue)]"
    }
}
