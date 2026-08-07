// PermissionPipeline.swift
//
// Ordered prepare path before tool dispatch:
//   1. plan-mode edit gate
//   2. fail-open PreToolUse hooks
//   3. plan-file auto-approval
//   4. PermissionHandle.request (deny > ask > allow)
//
// Nested Code Mode tools re-enter this same path. Hooks never alone
// authorize past a later policy deny.

import Foundation

// MARK: - PreToolUse hooks (fail-open seam)

/// Decision from a PreToolUse hook dispatcher.
public enum PreToolUseHookDecision: Sendable, Equatable {
    /// No opinion / allow — does **not** skip later checks.
    case allow
    /// Hook deny stops the call (failure to model; turn continues).
    case deny(reason: String, hookName: String)
}

/// Hook registry seam. Missing registry / errors fail open (do not authorize).
public protocol PreToolUseHookRunner: Sendable {
    func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision
}

/// No-op runner: fail-open (allow) so policy remains the security boundary.
public struct NoopPreToolUseHookRunner: PreToolUseHookRunner {
    public init() {}
    public func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision {
        _ = (toolName, toolCallId, access, permissionMode)
        return .allow
    }
}

/// Hook runner that always fails open even when the underlying runner throws.
public struct FailOpenPreToolUseHookRunner: PreToolUseHookRunner {
    public var inner: (any PreToolUseHookRunner)?
    public init(inner: (any PreToolUseHookRunner)? = nil) {
        self.inner = inner
    }
    public func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision {
        guard let inner else { return .allow }
        return await inner.runPreToolUse(
            toolName: toolName,
            toolCallId: toolCallId,
            access: access,
            permissionMode: permissionMode
        )
    }
}

// MARK: - Prepare result

/// Why a prepare step produced its decision (auditable).
public enum PermissionDecisionSource: String, Sendable, Equatable, Codable {
    case planModeGate = "plan_mode_gate"
    case preToolUseHook = "pre_tool_use_hook"
    case planFileAutoApprove = "plan_file_auto_approve"
    case permissionEngine = "permission_engine"
    case remotePolicy = "remote_policy"
    case sandboxRequired = "sandbox_required"
}

public struct PreparedToolAccess: Sendable, Equatable {
    public var decision: PermissionDecision
    public var source: PermissionDecisionSource
    public var ruleSource: PermissionRuleSource?
    public var reason: String?
    /// True when prepare completed with allow and dispatch may proceed.
    public var mayDispatch: Bool { decision.isAllow }

    public init(
        decision: PermissionDecision,
        source: PermissionDecisionSource,
        ruleSource: PermissionRuleSource? = nil,
        reason: String? = nil
    ) {
        self.decision = decision
        self.source = source
        self.ruleSource = ruleSource
        self.reason = reason
    }
}

public struct PrepareToolAccessRequest: Sendable {
    public var access: AccessKind
    public var toolName: String
    public var toolCallId: String
    public var applyPatchLabel: Bool
    public var permissionModeLabel: String?

    public init(
        access: AccessKind,
        toolName: String,
        toolCallId: String,
        applyPatchLabel: Bool = false,
        permissionModeLabel: String? = nil
    ) {
        self.access = access
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.applyPatchLabel = applyPatchLabel
        self.permissionModeLabel = permissionModeLabel
    }
}

// MARK: - Pipeline

/// Orchestrates the ordered permission prepare path.
public actor PermissionPipeline {
    public var planMode: PlanModeTracker
    public let permissions: PermissionHandle
    public var hooks: any PreToolUseHookRunner
    /// When remote policy is authoritative and denied/unavailable.
    public var remotePolicyDenied: Bool
    public var remotePolicyAvailable: Bool
    public var requireSandbox: Bool
    public var isolation: IsolationMode
    /// YOLO pin reason — never disables sandbox requirements.
    public private(set) var yoloPinReason: String?

    public init(
        permissions: PermissionHandle,
        planMode: PlanModeTracker = PlanModeTracker(),
        hooks: any PreToolUseHookRunner = FailOpenPreToolUseHookRunner(),
        remotePolicyDenied: Bool = false,
        remotePolicyAvailable: Bool = false,
        requireSandbox: Bool = false,
        isolation: IsolationMode = .none,
        yoloPinReason: String? = nil
    ) {
        self.permissions = permissions
        self.planMode = planMode
        self.hooks = hooks
        self.remotePolicyDenied = remotePolicyDenied
        self.remotePolicyAvailable = remotePolicyAvailable
        self.requireSandbox = requireSandbox
        self.isolation = isolation
        self.yoloPinReason = yoloPinReason
    }

    public func setPlanMode(_ tracker: PlanModeTracker) {
        planMode = tracker
    }

    /// Arm plan mode for this session (the live `enter_plan_mode` tool calls this).
    /// Mirrors `PlanModeTracker.enter` but mutates the pipeline-owned tracker so
    /// the very next `prepare` sees the active gate without a replace race.
    public func enterPlanMode(planFilePath: String? = nil, sessionDirectory: String? = nil) {
        planMode.enter(planFilePath: planFilePath, sessionDirectory: sessionDirectory)
    }

    /// Disarm plan mode for this session (the live `exit_plan_mode` tool calls
    /// this once the user approves the exit). After this, non-plan edits flow
    /// through the ordinary permission engine again.
    public func exitPlanMode() {
        planMode.exit()
    }

    /// The absolute plan-file path the live plan-mode tools seed and read.
    /// The enter/exit handlers route through this so the file they touch is
    /// exactly the file the plan-file auto-approval gate compares against.
    public func planFileResolvedPath() -> String {
        planMode.resolvedPlanFilePath()
    }

    /// Whether plan mode is currently armed. The live tool surface and tests
    /// assert through this rather than reaching into the tracker directly.
    public var planModeActive: Bool {
        planMode.isActive
    }

    /// Route exit-plan approval through the existing permission ask sheet.
    ///
    /// Divergence from upstream, recorded: upstream's `exit_plan_mode` raises
    /// a dedicated plan-approval reverse-request and the pager renders a
    /// plan-approval view (`xai-grok-pager/src/views/plan_approval_view.rs`).
    /// The Swift pager lacks that view (backing B4), so we reuse the prompter
    /// the file tools already paint. Cost: the ask copy is generic permission
    /// copy, not plan-approval-specific, and a denied exit returns a
    /// "permission denied" shape rather than a "plan not approved" shape —
    /// so the model may retry the exit where upstream would not. That is the
    /// trade for not shipping a half-built approval surface; do not loosen it
    /// by auto-approving here, and do not widen the prompter to special-case
    /// plan approval without also adding the dedicated view.
    public func requestExitPlanApproval(toolCallId: String) async -> PermissionDecision {
        let prompter = await permissions.prompter
        return await prompter.prompt(
            access: .read(nil),
            toolName: "exit_plan_mode",
            toolCallId: toolCallId
        )
    }

    public func setRemotePolicy(available: Bool, denied: Bool = false) {
        remotePolicyAvailable = available
        remotePolicyDenied = denied
    }

    /// Full prepare order. Nested tools re-enter this method.
    public func prepare(_ request: PrepareToolAccessRequest) async -> PreparedToolAccess {
        // 0. Remote policy / sandbox fail-closed (never local bypass).
        if remotePolicyDenied {
            return PreparedToolAccess(
                decision: .policyDeny("remote policy denied this operation"),
                source: .remotePolicy,
                reason: "remote_policy_denied"
            )
        }
        if requireSandbox && !remotePolicyAvailable && isolation == .sandbox {
            return PreparedToolAccess(
                decision: .policyDeny("sandbox policy unavailable; refusing local fallback"),
                source: .sandboxRequired,
                reason: "sandbox_unavailable"
            )
        }
        // YOLO pin / yolo mode must never clear sandbox requirements.
        // (requireSandbox remains enforced above regardless of permission mode.)

        // 1. Plan-mode edit gate (hard reject; not bypassed by YOLO).
        let gate = planModeEditGate(
            tracker: planMode,
            access: request.access,
            applyPatchLabel: request.applyPatchLabel
        )
        if gate == .rejectNonPlanFile {
            return PreparedToolAccess(
                decision: .reject(
                    "plan mode is active; only the session plan file may be edited"
                ),
                source: .planModeGate,
                reason: "plan_mode_non_plan_edit"
            )
        }

        // 2. PreToolUse hooks — fail open; deny stops; allow does not skip later checks.
        let hookDecision = await hooks.runPreToolUse(
            toolName: request.toolName,
            toolCallId: request.toolCallId,
            access: request.access,
            permissionMode: request.permissionModeLabel
        )
        if case .deny(let reason, let hookName) = hookDecision {
            return PreparedToolAccess(
                decision: .reject("hook \(hookName) denied: \(reason)"),
                source: .preToolUseHook,
                reason: "hook_deny:\(hookName)"
            )
        }

        // 3. Plan-file auto-approval (skip permission manager for plan.md only).
        if case .edit(let path) = request.access, planMode.shouldAutoApproveEdit(path) {
            return PreparedToolAccess(
                decision: .allow,
                source: .planFileAutoApprove,
                reason: "plan_file"
            )
        }

        // 4. Permission engine (deny > ask > allow, auditable events).
        let decision = await permissions.request(
            access: request.access,
            toolName: request.toolName,
            toolCallId: request.toolCallId
        )
        return PreparedToolAccess(
            decision: decision,
            source: .permissionEngine,
            reason: "permission_handle"
        )
    }
}
