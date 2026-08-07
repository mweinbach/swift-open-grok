// PlanApproval.swift
//
// The exit-plan approval domain: what the dedicated plan-approval view can
// decide, the seam a UI installs to present it, and the result type that
// keeps the dedicated-view outcomes apart from the generic-sheet fallback.
//
// Upstream reference: the pager's plan-approval view produces exactly three
// wire outcomes — "approved" / "cancelled" (with optional feedback) /
// "abandoned" (`xai-grok-pager/src/views/plan_approval_view.rs:177-191`) —
// and the shell maps anything unrecognized to cancelled so the session fails
// CLOSED, staying in plan mode rather than auto-approving
// (`xai-grok-shell/src/session/acp_session_impl/tool_calls.rs:347-368`).

import Foundation

/// What the user decided on the dedicated plan-approval view.
///
/// `revise` is upstream's "cancelled"-with-feedback outcome: the session stays
/// in plan mode and the feedback goes back to the model
/// (`tool_calls.rs:1856-1879`). `abandoned` is upstream's abandon: plan mode
/// is *disabled* and the model is told not to retry (`tool_calls.rs:1833-1854`).
public enum PlanApprovalDecision: Sendable, Equatable {
    case approved
    case revise(feedback: String)
    case abandoned
}

/// A surface that can present the dedicated plan-approval view and block
/// until the user decides — the plan-approval analog of `PermissionPrompter`.
public protocol PlanApprovalPrompting: Sendable {
    /// Whether a live presenter is attached. A prompter whose renderer never
    /// came up must not be consulted — the pipeline falls back to the generic
    /// permission sheet instead of suspending on a sheet nobody will paint.
    var canPresent: Bool { get async }

    /// Present the plan (nil when the plan file is missing/empty) and suspend
    /// until the user decides.
    func decision(toolCallId: String, planContent: String?) async -> PlanApprovalDecision
}

/// Which surface answered an exit-plan approval request.
///
/// The two cases are deliberately not collapsed into one decision enum: a
/// generic-sheet deny means "not approved, stay in plan mode" (today's
/// pre-dedicated-view behavior), while the dedicated view's `abandoned` means
/// "turn plan mode off" (`tool_calls.rs:1833-1854`). Folding a generic deny
/// into `.abandoned` would disarm the plan gate on a click that has always
/// kept it armed — a fail-open the type makes unrepresentable.
public enum ExitPlanApprovalResult: Sendable, Equatable {
    /// The dedicated plan-approval view decided.
    case plan(PlanApprovalDecision)
    /// No dedicated view was installed (or presentable); the generic
    /// permission ask sheet decided, with today's exact semantics.
    case generic(PermissionDecision)
}
