import Foundation
import OpenGrokToolTypes
import Testing
@testable import OpenGrokAgentCoordinator

@Suite("OpenGrokAgentCoordinator")
struct OpenGrokAgentCoordinatorTests {
    private func runningChild(_ id: String) async -> OpenGrokChildResult {
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return OpenGrokChildResult(id: id, success: true)
        } catch {
            return OpenGrokChildResult(id: id, success: false, cancelled: true)
        }
    }

    @Test("completion is buffered once and cancellation blocks late task spawns")
    func completionAndCancellation() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(id: "child", parentSessionID: "session", owner: .task)
        try await coordinator.spawn(request) {
            OpenGrokChildResult(id: "child", success: true, output: "done", tokensUsed: 3)
        }
        _ = try await coordinator.awaitResult("child", timeoutMS: 1_000)
        let completions = await coordinator.pollCompletions(parentSessionID: "session")
        #expect(completions.count == 1)
        #expect(await coordinator.pollCompletions(parentSessionID: "session").isEmpty)
        _ = await coordinator.cancel(.parentSession("session"))
        let late = OpenGrokChildRequest(id: "late", parentSessionID: "session", owner: .task)
        do {
            try await coordinator.spawn(late) { OpenGrokChildResult(id: "late", success: true) }
            Issue.record("expected late spawn rejection")
        } catch is OpenGrokCoordinatorError {
        }
    }

    @Test("completed child usage folds only the requested prompt and child IDs")
    func completedChildUsageIsPromptAndChildScoped() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        for (id, promptID, tokens) in [
            ("first", "turn-one", UInt64(7)),
            ("second", "turn-one", UInt64(11)),
            ("foreign-prompt", "turn-two", UInt64(13)),
        ] {
            let request = OpenGrokChildRequest(
                id: id,
                parentSessionID: "session",
                parentPromptID: promptID,
                owner: .task
            )
            let spawnedID = try await coordinator.spawn(request) {
                OpenGrokChildResult(id: id, success: true, tokensUsed: tokens)
            }
            #expect(spawnedID == id)
            let result = try await coordinator.awaitResult(id, timeoutMS: 5_000)
            #expect(result.tokensUsed == tokens)
        }

        let combined = await coordinator.foldUsage(
            parentSessionID: "session",
            promptID: "turn-one",
            childIDs: ["second", "first", "first"]
        )
        #expect(combined.tokensUsed == 18)
        #expect(combined.childIDs == ["first", "second"])

        let firstOnly = await coordinator.foldUsage(
            parentSessionID: "session",
            promptID: "turn-one",
            childIDs: ["first"]
        )
        #expect(firstOnly.tokensUsed == 7)

        let otherPrompt = await coordinator.foldUsage(
            parentSessionID: "session",
            promptID: "turn-two",
            childIDs: ["foreign-prompt"]
        )
        #expect(otherPrompt.tokensUsed == 13)

        let otherSession = await coordinator.foldUsage(
            parentSessionID: "different-session",
            promptID: "turn-one",
            childIDs: ["first", "second"]
        )
        #expect(otherSession.tokensUsed == 0)
    }

    @Test("per-child and aggregate usage saturate without overflowing")
    func childUsageSaturates() async {
        let coordinator = OpenGrokAgentCoordinator()
        await coordinator.recordUsage(
            parentSessionID: "session",
            promptID: "turn",
            childID: "first",
            tokens: UInt64.max
        )
        await coordinator.recordUsage(
            parentSessionID: "session",
            promptID: "turn",
            childID: "first",
            tokens: 1
        )
        await coordinator.recordUsage(
            parentSessionID: "session",
            promptID: "turn",
            childID: "second",
            tokens: 8
        )

        let folded = await coordinator.foldUsage(
            parentSessionID: "session",
            promptID: "turn",
            childIDs: ["first", "second"]
        )
        #expect(folded.tokensUsed == UInt64.max)
    }

    @Test("prompt cancellation cannot cancel another turn or session")
    func cancellationIsPromptScoped() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let requests = [
            OpenGrokChildRequest(
                id: "cancelled",
                parentSessionID: "session",
                parentPromptID: "turn-one",
                owner: .task
            ),
            OpenGrokChildRequest(
                id: "next-turn",
                parentSessionID: "session",
                parentPromptID: "turn-two",
                owner: .task
            ),
            OpenGrokChildRequest(
                id: "other-session",
                parentSessionID: "elsewhere",
                parentPromptID: "turn-one",
                owner: .task
            ),
        ]
        for request in requests {
            let id = request.id
            let spawnedID = try await coordinator.spawn(request) {
                await runningChild(id)
            }
            #expect(spawnedID == id)
        }

        let cancelled = await coordinator.cancel(
            .parentPrompt(sessionID: "session", promptID: "turn-one")
        )
        #expect(cancelled == 1)
        let result = try await coordinator.awaitResult("cancelled", timeoutMS: 5_000)
        #expect(result.cancelled)

        let active = await coordinator.listActive().map(\.request.id)
        #expect(active == ["next-turn", "other-session"])

        let sessionCancelled = await coordinator.cancel(.parentSession("session"))
        let otherCancelled = await coordinator.cancel(.parentSession("elsewhere"))
        #expect(sessionCancelled == 1)
        #expect(otherCancelled == 1)
    }

    @Test("session stop preserves workflow-owned children until workflow cancellation")
    func sessionStopDoesNotCancelWorkflowChildren() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let task = OpenGrokChildRequest(
            id: "task",
            parentSessionID: "session",
            owner: .task
        )
        let workflow = OpenGrokChildRequest(
            id: "workflow",
            parentSessionID: "session",
            workflowRunID: "run-one",
            owner: .workflow
        )
        for request in [task, workflow] {
            let id = request.id
            let spawnedID = try await coordinator.spawn(request) {
                await runningChild(id)
            }
            #expect(spawnedID == id)
        }

        let stopped = await coordinator.cancel(.parentSession("session"))
        #expect(stopped == 1)
        let taskResult = try await coordinator.awaitResult("task", timeoutMS: 5_000)
        #expect(taskResult.cancelled)
        #expect(await coordinator.listActive(parentSessionID: "session").map(\.request.id)
            == ["workflow"])

        let cancelledWorkflow = await coordinator.cancel(.workflowRun("run-one"))
        #expect(cancelledWorkflow == 1)
        let workflowResult = try await coordinator.awaitResult("workflow", timeoutMS: 5_000)
        #expect(workflowResult.cancelled)
    }

    @Test("session teardown cannot resurrect completion or usage after cancellation")
    func teardownSuppressesLateCompletionAndUsage() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(
            id: "late",
            parentSessionID: "session",
            parentPromptID: "turn",
            owner: .task
        )
        let spawnedID = try await coordinator.spawn(request) {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {}
            return OpenGrokChildResult(id: "late", success: true, tokensUsed: 9)
        }
        #expect(spawnedID == "late")
        await coordinator.markUsageNotApplied(parentSessionID: "session", promptID: "turn")
        await coordinator.teardown(sessionID: "session")

        let finished = try await coordinator.awaitResult("late", timeoutMS: 5_000)
        #expect(finished.cancelled)
        #expect(await coordinator.pollCompletions(parentSessionID: "session").isEmpty)
        let usage = await coordinator.foldUsage(
            parentSessionID: "session",
            promptID: "turn",
            childIDs: ["late"]
        )
        #expect(usage.tokensUsed == 0)
        let outstanding = await coordinator.outstanding(
            parentSessionID: "session",
            promptID: "turn"
        )
        #expect(outstanding.usageNotApplied == false)
    }

    @Test("suppressed completions are consumed instead of resurfacing later")
    func suppressedCompletionsDoNotResurface() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(
            id: "suppressed",
            parentSessionID: "session",
            owner: .task
        )
        let spawnedID = try await coordinator.spawn(request) {
            OpenGrokChildResult(id: "suppressed", success: true)
        }
        #expect(spawnedID == "suppressed")
        let result = try await coordinator.awaitResult("suppressed", timeoutMS: 5_000)
        #expect(result.success)

        let suppressed = await coordinator.pollCompletions(
            parentSessionID: "session",
            suppressIDs: ["suppressed"]
        )
        #expect(suppressed.isEmpty)
        #expect(await coordinator.pollCompletions(parentSessionID: "session").isEmpty)
    }

    @Test("running and completed collaboration rosters preserve child metadata")
    func agentRosterPreservesChildMetadata() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(
            id: "labeled-child",
            parentSessionID: "session",
            subagentType: "explore",
            description: "Inspect the provider boundary",
            childCWD: "/workspace",
            worktreePath: "/worktrees/child",
            owner: .task
        )
        let spawnedID = try await coordinator.spawn(request) {
            await runningChild("labeled-child")
        }
        #expect(spawnedID == "labeled-child")

        let identity = AgentMailboxIdentity(teamScopeID: "session", agentID: "session")
        let running = await coordinator.listAgents(identity: identity)
        let runningEntry = try #require(running.agents.first { $0.agentID == "labeled-child" })
        #expect(runningEntry.subagentType == "explore")
        #expect(runningEntry.description == "Inspect the provider boundary")
        #expect(runningEntry.worktreePath == "/worktrees/child")

        let cancelled = await coordinator.cancel(.childID("labeled-child"))
        #expect(cancelled == 1)
        let result = try await coordinator.awaitResult("labeled-child", timeoutMS: 5_000)
        #expect(result.cancelled)

        let finished = await coordinator.listAgents(identity: identity)
        let finishedEntry = try #require(finished.agents.first { $0.agentID == "labeled-child" })
        #expect(finishedEntry.status == "cancelled")
        #expect(finishedEntry.subagentType == "explore")
        #expect(finishedEntry.description == "Inspect the provider boundary")
        #expect(finishedEntry.worktreePath == "/worktrees/child")
    }
}
