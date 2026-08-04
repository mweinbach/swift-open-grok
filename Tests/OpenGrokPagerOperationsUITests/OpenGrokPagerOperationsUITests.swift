import Testing
@testable import OpenGrokPagerOperationsUI

struct PagerProgressTests {
    @Test("determinate progress renders a bounded bar")
    func rendersDeterminateProgress() {
        let description = PagerProgress.determinate(completed: 2, total: 4, label: "Files").render(width: 8)

        #expect(description.bar == "████░░░░")
        #expect(description.fraction == 0.5)
        #expect(description.accessibilityLabel == "Files 50 percent")
    }

    @Test("indeterminate progress moves without changing its label")
    func rendersIndeterminateProgress() {
        let first = PagerProgress.indeterminate(label: "Waiting").render(width: 4, tick: 0)
        let second = PagerProgress.indeterminate(label: "Waiting").render(width: 4, tick: 1)

        #expect(first.isIndeterminate)
        #expect(first.label == "Waiting")
        #expect(first.bar != second.bar)
    }
}

struct PagerOperationStateTests {
    @Test("operation transitions preserve running, result, and output state")
    func transitionsPreserveState() throws {
        var operation = PagerToolOperationViewModel(id: "op-1", kind: .execute, title: "git status")
        try operation.apply(.start)
        try operation.apply(.updateProgress(.determinate(completed: 1, total: 2)))
        try operation.apply(.succeed(PagerOperationResult(
            kind: .success,
            summary: "Clean",
            output: ["On branch main", "nothing to commit"],
            exitCode: 0
        )))

        #expect(operation.status == .succeeded)
        #expect(operation.renderDescription(outputLineLimit: 1).lines.map(\.text).contains("… 1 more lines"))
        operation.toggleExpanded()
        #expect(operation.renderDescription().lines.map(\.text).contains("nothing to commit"))
    }

    @Test("invalid terminal transitions are rejected")
    func rejectsInvalidTerminalTransitions() {
        var operation = PagerToolOperationViewModel(id: "op-1", kind: .read, title: "file.swift")
        do {
            try operation.apply(.succeed(PagerOperationResult(kind: .success)))
            Issue.record("expected invalid transition")
        } catch let error as PagerOperationTransitionError {
            #expect(error == .invalidTransition(
                from: .queued,
                event: .succeed(PagerOperationResult(kind: .success))
            ))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(operation.status == .queued)
    }
}

struct PagerPermissionPromptTests {
    @Test("destructive permission prompts require an explicit denial reason")
    func denialRequiresReason() throws {
        let request = PagerPermissionRequest(
            id: "perm-1",
            toolName: "Bash",
            summary: "Remove generated files",
            destructive: true
        )
        var prompt = PagerPermissionPromptViewModel(request: request)
        prompt.moveSelection(by: -1)
        #expect(prompt.selectedOption?.action == .deny)
        let beganFollowup = prompt.beginFollowup()
        #expect(beganFollowup)
        do {
            _ = try prompt.resolve()
            Issue.record("expected denial resolution to require a reason")
        } catch let error as PagerPermissionResolutionError {
            #expect(error == .missingDenialReason)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        prompt.updateFollowup("not now")
        #expect(try prompt.resolve() == .deny(reason: "not now"))
        #expect(prompt.renderDescription().warning != nil)
    }
}
