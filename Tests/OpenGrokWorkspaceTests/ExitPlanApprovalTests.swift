// ExitPlanApprovalTests.swift
//
// The widened exit-plan approval seam: with a dedicated plan-approval
// prompter installed the pipeline returns its three decisions untouched and
// never consults the generic prompter; with none installed (or one that
// cannot present) it falls back to the generic permission sheet with today's
// exact mapping. The fallback pins are the fail-closed contract: absence of
// the dedicated view can only reproduce pre-view behavior, never approve.

import Foundation
import Testing
@testable import OpenGrokWorkspace

// MARK: - Fixtures

/// Dedicated prompter returning a fixed decision; records what it was shown.
private final class FixedPlanPrompter: PlanApprovalPrompting, @unchecked Sendable {
    let decision: PlanApprovalDecision
    let presentable: Bool
    private(set) var seenToolCallId: String?
    private(set) var seenPlanContent: String??

    init(_ decision: PlanApprovalDecision, presentable: Bool = true) {
        self.decision = decision
        self.presentable = presentable
    }

    var canPresent: Bool {
        get async { presentable }
    }

    func decision(toolCallId: String, planContent: String?) async -> PlanApprovalDecision {
        seenToolCallId = toolCallId
        seenPlanContent = planContent
        return decision
    }
}

/// Generic prompter returning a fixed decision; records whether it was asked.
private final class RecordingPermissionPrompter: PermissionPrompter, @unchecked Sendable {
    let decision: PermissionDecision
    private(set) var promptCount = 0
    private(set) var seenToolName: String?
    private(set) var seenToolCallId: String?

    init(_ decision: PermissionDecision) {
        self.decision = decision
    }

    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        promptCount += 1
        seenToolName = toolName
        seenToolCallId = toolCallId
        return decision
    }
}

private func makePipeline(
    generic: RecordingPermissionPrompter
) -> PermissionPipeline {
    PermissionPipeline(permissions: PermissionHandle(prompter: generic))
}

// MARK: - Tests

@Suite("Exit-plan approval seam")
struct ExitPlanApprovalTests {
    @Test(
        "an installed prompter's decision passes through untouched",
        arguments: [
            PlanApprovalDecision.approved,
            .revise(feedback: "tighten step 2"),
            .abandoned,
        ]
    )
    func installedPrompterDecidesAllThree(decision: PlanApprovalDecision) async {
        let generic = RecordingPermissionPrompter(.allow)
        let pipeline = makePipeline(generic: generic)
        let dedicated = FixedPlanPrompter(decision)
        await pipeline.installPlanApprovalPrompter(dedicated)

        let result = await pipeline.requestExitPlanApproval(
            toolCallId: "call-77",
            planContent: "# plan\nstep 1"
        )

        #expect(result == .plan(decision))
        // The dedicated view saw exactly the call and content it must paint.
        #expect(dedicated.seenToolCallId == "call-77")
        #expect(dedicated.seenPlanContent == "# plan\nstep 1")
        // The generic sheet was never consulted while the dedicated view is up.
        #expect(generic.promptCount == 0)
    }

    @Test("no installed prompter falls back to the generic sheet with today's shape")
    func noPrompterFallsBackToGeneric() async {
        let generic = RecordingPermissionPrompter(.reject("nope"))
        let pipeline = makePipeline(generic: generic)

        let result = await pipeline.requestExitPlanApproval(
            toolCallId: "call-88",
            planContent: "# plan"
        )

        // Today's mapping, pinned: the generic decision arrives as `.generic`,
        // never re-labeled into a dedicated-view outcome — a generic deny must
        // not read as an upstream "abandoned", which disarms the gate.
        #expect(result == .generic(.reject("nope")))
        #expect(generic.promptCount == 1)
        #expect(generic.seenToolName == "exit_plan_mode")
        #expect(generic.seenToolCallId == "call-88")
    }

    @Test("a generic-sheet allow still arrives as generic, not as a plan approval")
    func genericAllowStaysGeneric() async {
        let generic = RecordingPermissionPrompter(.allow)
        let pipeline = makePipeline(generic: generic)

        let result = await pipeline.requestExitPlanApproval(
            toolCallId: "call-99",
            planContent: nil
        )
        #expect(result == .generic(.allow))
    }

    @Test("an installed but unpresentable prompter falls back — never auto-approves")
    func unpresentablePrompterFallsBack() async {
        let generic = RecordingPermissionPrompter(.reject("headless deny"))
        let pipeline = makePipeline(generic: generic)
        let dedicated = FixedPlanPrompter(.approved, presentable: false)
        await pipeline.installPlanApprovalPrompter(dedicated)

        let result = await pipeline.requestExitPlanApproval(
            toolCallId: "call-11",
            planContent: "# plan"
        )

        // The unpresentable dedicated prompter is skipped entirely; its
        // would-be approval never surfaces.
        #expect(result == .generic(.reject("headless deny")))
        #expect(dedicated.seenToolCallId == nil)
        #expect(generic.promptCount == 1)
    }
}
