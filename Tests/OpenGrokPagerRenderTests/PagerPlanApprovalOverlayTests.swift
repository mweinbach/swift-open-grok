// PagerPlanApprovalOverlayTests.swift
//
// The plan-approval bottom sheet's key grammar and the coordinator that
// joins it to the blocking `exit_plan_mode` approval. Key semantics under
// test are upstream's plan-review grammar (`agent_view/viewer.rs:151-166`:
// `a` approves, `s` focuses the feedback prompt, `q` abandons) reduced to
// the port's sheet — see the divergence note on `PagerPlanApprovalPrompt`.

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

// MARK: - Fixtures

private func key(_ code: KeyCode, _ modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(key: code, modifiers: modifiers)
}

private func character(_ value: Character) -> KeyEvent {
    KeyEvent(key: .char(value), character: value)
}

private let ctrlC = KeyEvent(key: .char("c"), modifiers: [.control], character: "c")

private func planRequest(
    content: String? = "# Plan\n\n## Step 1\nDo something"
) -> PagerPlanApprovalRequest {
    PagerPlanApprovalRequest(id: "req-1", toolCallID: "call-1", planContent: content)
}

private func planStack(_ request: PagerPlanApprovalRequest) -> PagerOverlayStack {
    PagerOverlayStack([.planApproval(request)])
}

private func prompt(in stack: PagerOverlayStack) -> PagerPlanApprovalPrompt? {
    guard case .planApproval(let prompt)? = stack.topmost?.content else { return nil }
    return prompt
}

private func type(_ text: String, into stack: inout PagerOverlayStack) {
    for value in text {
        #expect(stack.handle(character(value)) == .redraw)
    }
}

// MARK: - Keyboard grammar

@Suite("Plan approval overlay keys")
struct PagerPlanApprovalOverlayKeyTests {
    @Test("a approves")
    func approve() {
        var stack = planStack(planRequest())
        let outcome = stack.handle(character("a"))
        #expect(outcome == .planApproval(
            id: "plan-approval:req-1",
            requestID: "req-1",
            outcome: .approved
        ))
    }

    @Test("q abandons")
    func abandon() {
        var stack = planStack(planRequest())
        let outcome = stack.handle(character("q"))
        #expect(outcome == .planApproval(
            id: "plan-approval:req-1",
            requestID: "req-1",
            outcome: .abandoned
        ))
    }

    @Test("Esc abandons — the sheet owns Escape, it is never a plain dismissal")
    func escapeAbandons() {
        var stack = planStack(planRequest())
        let outcome = stack.handle(key(.escape))
        #expect(outcome == .planApproval(
            id: "plan-approval:req-1",
            requestID: "req-1",
            outcome: .abandoned
        ))
    }

    @Test("Ctrl+C abandons from viewing")
    func ctrlCAbandons() {
        var stack = planStack(planRequest())
        let outcome = stack.handle(ctrlC)
        #expect(outcome == .planApproval(
            id: "plan-approval:req-1",
            requestID: "req-1",
            outcome: .abandoned
        ))
    }

    @Test("s + typed feedback + Enter revises with the typed text")
    func reviseWithFeedback() {
        var stack = planStack(planRequest())
        #expect(stack.handle(character("s")) == .redraw)
        #expect(prompt(in: stack)?.focus == .feedbackInput)
        type("add tests", into: &stack)
        #expect(prompt(in: stack)?.feedbackText == "add tests")
        let outcome = stack.handle(key(.enter))
        #expect(outcome == .planApproval(
            id: "plan-approval:req-1",
            requestID: "req-1",
            outcome: .revise(feedback: "add tests")
        ))
    }

    @Test("typing a/q in the feedback editor appends — it never approves or abandons")
    func editorSwallowsGrammarKeys() {
        var stack = planStack(planRequest())
        #expect(stack.handle(character("s")) == .redraw)
        type("aqua", into: &stack)
        #expect(prompt(in: stack)?.feedbackText == "aqua")
        #expect(stack.handle(key(.backspace)) == .redraw)
        #expect(prompt(in: stack)?.feedbackText == "aqu")
    }

    @Test("Esc in the editor stashes the draft back to viewing; s resumes it")
    func escapeLeavesEditorKeepingDraft() {
        var stack = planStack(planRequest())
        #expect(stack.handle(character("s")) == .redraw)
        type("half a thought", into: &stack)
        #expect(stack.handle(key(.escape)) == .redraw)
        #expect(prompt(in: stack)?.focus == .viewing)
        #expect(prompt(in: stack)?.feedbackText == "half a thought")
        // Ctrl+C in the editor backs out the same way.
        #expect(stack.handle(character("s")) == .redraw)
        #expect(stack.handle(ctrlC) == .redraw)
        #expect(prompt(in: stack)?.focus == .viewing)
    }

    @Test("Enter on an empty editor is a no-feedback revise, upstream's cancelled(None)")
    func emptyFeedbackRevises() {
        var stack = planStack(planRequest())
        #expect(stack.handle(character("s")) == .redraw)
        let outcome = stack.handle(key(.enter))
        #expect(outcome == .planApproval(
            id: "plan-approval:req-1",
            requestID: "req-1",
            outcome: .revise(feedback: "")
        ))
    }

    @Test("arrows and j/k scroll the plan body")
    func scrolling() {
        let longPlan = (1...40).map { "line \($0)" }.joined(separator: "\n")
        var stack = planStack(planRequest(content: longPlan))
        #expect(stack.handle(key(.down), viewportHeight: 10) == .redraw)
        #expect(prompt(in: stack)?.scrollOffset == 1)
        #expect(stack.handle(character("j"), viewportHeight: 10) == .redraw)
        #expect(prompt(in: stack)?.scrollOffset == 2)
        #expect(stack.handle(character("k"), viewportHeight: 10) == .redraw)
        #expect(stack.handle(key(.up), viewportHeight: 10) == .redraw)
        #expect(prompt(in: stack)?.scrollOffset == 0)
        // Clamped at the top: no state change means the key is swallowed.
        #expect(stack.handle(key(.up), viewportHeight: 10) == .consumed)
        #expect(stack.handle(key(.pageDown), viewportHeight: 10) == .redraw)
        #expect(prompt(in: stack)?.scrollOffset == 10)
    }
}

// MARK: - Empty plan

@Suite("Plan approval empty-plan placeholder")
struct PagerPlanApprovalPlaceholderTests {
    @Test("an empty plan shows upstream's placeholder body and status label")
    func emptyPlanPlaceholder() {
        let prompt = PagerPlanApprovalPrompt(request: planRequest(content: nil))
        #expect(!prompt.hasPlan)
        #expect(prompt.statusLabel == "No plan written — approve or request changes")
        #expect(prompt.bodyLines.first == "# No plan written yet")
        #expect(prompt.bodyLines.contains("The agent exited plan mode without writing a plan."))
    }

    @Test("a whitespace-only plan is normalized to no-plan on construction")
    func whitespaceOnlyPlanIsNoPlan() {
        let request = planRequest(content: "   \n\n  ")
        #expect(request.planContent == nil)
        let prompt = PagerPlanApprovalPrompt(request: request)
        #expect(!prompt.hasPlan)
    }

    @Test("a real plan keeps its body and the waiting label")
    func realPlanKeepsBody() {
        let prompt = PagerPlanApprovalPrompt(request: planRequest())
        #expect(prompt.hasPlan)
        #expect(prompt.statusLabel == "Waiting on plan approval")
        #expect(prompt.bodyLines.first == "# Plan")
    }

    @Test("CRLF plan bodies split into the same lines as LF ones")
    func crlfBodySplits() {
        let prompt = PagerPlanApprovalPrompt(
            request: planRequest(content: "alpha\r\nbravo\r\ncharlie")
        )
        #expect(prompt.bodyLines == ["alpha", "bravo", "charlie"])
    }
}

// MARK: - Coordinator

@Suite("Plan approval coordinator")
struct PagerPlanApprovalCoordinatorTests {
    @Test("resolve resumes the blocked decision with the user's outcome")
    func resolveResumesDecision() async {
        let coordinator = PagerPlanApprovalCoordinator()
        await coordinator.setPresenter { _ in }
        let request = planRequest()
        async let decision = coordinator.decision(for: request)
        // Let the waiter enqueue before resolving.
        while await coordinator.pendingCount == 0 {
            await Task.yield()
        }
        await coordinator.resolve(requestID: "req-1", outcome: .revise(feedback: "shorter"))
        #expect(await decision == .revise(feedback: "shorter"))
        #expect(await coordinator.pendingCount == 0)
    }

    @Test("a stale request id resolves nothing")
    func staleIDIgnored() async {
        let coordinator = PagerPlanApprovalCoordinator()
        await coordinator.setPresenter { _ in }
        async let decision = coordinator.decision(for: planRequest())
        while await coordinator.pendingCount == 0 {
            await Task.yield()
        }
        await coordinator.resolve(requestID: "someone-else", outcome: .approved)
        #expect(await coordinator.pendingCount == 1)
        await coordinator.resolve(requestID: "req-1", outcome: .abandoned)
        #expect(await decision == .abandoned)
    }

    @Test("resolveAll resumes as a no-feedback revise — the gate stays armed")
    func resolveAllIsStaleCancel() async {
        let coordinator = PagerPlanApprovalCoordinator()
        await coordinator.setPresenter { _ in }
        async let decision = coordinator.decision(for: planRequest())
        while await coordinator.pendingCount == 0 {
            await Task.yield()
        }
        // Upstream's stale-cancel (`plan_approval_view.rs:189-191`) maps to
        // stay-in-plan-mode (`tool_calls.rs:347-368`); never approve or
        // abandon on a teardown the user did not choose.
        await coordinator.resolveAll()
        #expect(await decision == .revise(feedback: ""))
    }
}
