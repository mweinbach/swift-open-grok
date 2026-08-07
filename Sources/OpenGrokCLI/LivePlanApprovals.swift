// LivePlanApprovals.swift
//
// Bridges the `exit_plan_mode` approval (which speaks the workspace
// pipeline's `PlanApprovalPrompting` seam) to the pager's
// `PagerPlanApprovalCoordinator` (which speaks render-model types) — the
// same layering crossing `LiveUserQuestionBroker` does for questions and
// the permission prompter does for mutations, so neither layer imports the
// other.

import Foundation
import OpenGrokPagerRender
import OpenGrokWorkspace

struct LivePlanApprovalBroker: PlanApprovalPrompting {
    let coordinator: PagerPlanApprovalCoordinator

    /// Fail-closed signal: a coordinator with no presenter is a session where
    /// no one can decide (interactive launch whose renderer never came up),
    /// so the pipeline must fall back to the generic sheet rather than
    /// suspend on a sheet nobody will paint.
    var canPresent: Bool {
        get async { await coordinator.hasPresenter }
    }

    func decision(toolCallId: String, planContent: String?) async -> PlanApprovalDecision {
        let request = PagerPlanApprovalRequest(
            toolCallID: toolCallId,
            planContent: planContent
        )
        switch await coordinator.decision(for: request) {
        case .approved: return .approved
        case .revise(let feedback): return .revise(feedback: feedback)
        case .abandoned: return .abandoned
        }
    }
}
