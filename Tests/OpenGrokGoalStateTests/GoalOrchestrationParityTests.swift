import Foundation
import Testing

@testable import OpenGrokGoalState

@Suite("Pinned goal orchestration engine parity")
struct GoalOrchestrationParityTests {
    @Test("evaluator accepts only strict upstream decisions and stable blocker identities")
    func evaluatorVerdictsAreStrictAndActionable() throws {
        let valid: [(String, GoalEvaluationDecision)] = [
            (#"{"decision":"continue","evidence":"tests fail","next_step":"repair tests","blocker_key":""}"#, .continueWork),
            (#"{"decision":"candidate_complete","evidence":"all required tests passed","next_step":"independently verify","blocker_key":""}"#, .candidateComplete),
            (#"{"decision":"blocked","evidence":"credential absent","next_step":"grant repository access","blocker_key":"missing_github_access"}"#, .blocked),
        ]
        for (raw, decision) in valid {
            #expect(try GoalEvaluationVerdict.parse(raw).decision == decision)
        }

        for raw in [
            #"{"decision":"achieved","evidence":"x","next_step":"y","blocker_key":""}"#,
            #"{"decision":"continue","evidence":"x","next_step":"y","blocker_key":"","extra":true}"#,
            #"{"decision":"continue","evidence":" ","next_step":"y","blocker_key":""}"#,
            #"{"decision":"blocked","evidence":"x","next_step":"y","blocker_key":""}"#,
            #"{"decision":"blocked","evidence":"x","next_step":"y","blocker_key":"Missing Access"}"#,
            #"{"decision":"continue","evidence":"x","next_step":"y","blocker_key":"missing_access"}"#,
            #"{"decision":"continue","evidence":"x","next_step":"y"}"#,
        ] {
            #expect(throws: (any Error).self) {
                try GoalEvaluationVerdict.parse(raw)
            }
        }
    }

    @Test("an adversarial verifier must supply evidence and cannot approve remaining gaps")
    func verifierVerdictsRejectContradictoryCompletion() throws {
        let achieved = try GoalVerificationVerdict.parse(
            #"{"decision":"achieved","evidence":"independent checks passed","next_step":"report completion","gaps":[]}"#
        )
        #expect(achieved.decision == .achieved)

        #expect(throws: (any Error).self) {
            try GoalVerificationVerdict.parse(
                #"{"decision":"achieved","evidence":"looks done","next_step":"ship","gaps":["tests never ran"]}"#
            )
        }
        #expect(throws: (any Error).self) {
            try GoalVerificationVerdict.parse(
                #"{"decision":"not_achieved","evidence":"not proven","next_step":"test","gaps":[]}"#
            )
        }
        #expect(throws: (any Error).self) {
            try GoalVerificationVerdict.parse(
                #"{"decision":"achieved","evidence":"x","next_step":"y","gaps":[],"claimed_by_worker":true}"#
            )
        }
    }

    @Test("role lifecycles, pending work, and evaluator verdict survive durable snapshot coding")
    func roleAndCarryForwardSnapshotsRoundTrip() throws {
        let directory = temporaryDirectory("roles")
        defer { try? FileManager.default.removeItem(at: directory) }
        var tracker = GoalTracker(sessionDirectory: directory)
        tracker.createGoal(goalID: "goal-roles", objective: "prove every role")
        let assignment = GoalRoleModel(model: "planner-model", agentType: "planner-harness")

        let plannerBegan = tracker.beginRole(
            .planner,
            model: assignment,
            runID: "planner-1",
            round: 1
        )
        #expect(plannerBegan)
        #expect(tracker.phase == .planning)
        #expect(tracker.snapshot()?.planningInFlight == true)
        let plannerFinished = tracker.finishRole(
            runID: "planner-1",
            state: .succeeded,
            evidence: "wrote plan"
        )
        #expect(plannerFinished)
        #expect(tracker.phase == .executing)

        let verdict = try GoalEvaluationVerdict(
            decision: .continueWork,
            evidence: "one test remains red",
            nextStep: "repair that test"
        )
        tracker.modifySnapshot { snapshot in
            snapshot.carryForwardTodos = [
                GoalTodoSnapshot(id: "test", content: "repair that test", status: "pending"),
            ]
            snapshot.lastEvaluatorVerdict = verdict
            snapshot.plannerAttempts = 1
            snapshot.lastPrematureStopPattern = "giving_up"
        }

        let encoded = try JSONEncoder().encode(try #require(tracker.snapshot()))
        let restored = try JSONDecoder().decode(GoalOrchestration.self, from: encoded)
        #expect(restored.roleSnapshots.map(\.role) == [.planner])
        #expect(restored.roleSnapshots.first?.model == "planner-model")
        #expect(restored.roleSnapshots.first?.agentType == "planner-harness")
        #expect(restored.roleSnapshots.first?.state == .succeeded)
        #expect(restored.carryForwardTodos.first?.id == "test")
        #expect(restored.lastEvaluatorVerdict == verdict)
        #expect(restored.plannerAttempts == 1)
        #expect(restored.lastPrematureStopPattern == "giving_up")
    }

    @Test("restart cancels persisted in-flight role snapshots without claiming completion")
    func restorationCancelsStaleRoles() throws {
        let directory = temporaryDirectory("role-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        var tracker = GoalTracker(sessionDirectory: directory)
        tracker.createGoal(goalID: "goal-restart", objective: "restart safely")
        let skepticBegan = tracker.beginRole(
            .skeptic,
            model: GoalRoleModel(model: "skeptic-model", agentType: "general-purpose"),
            runID: "skeptic-in-flight",
            round: 1
        )
        #expect(skepticBegan)

        let restored = GoalTracker.fromSnapshot(
            sessionDirectory: directory,
            snapshot: try #require(tracker.snapshot())
        )
        #expect(restored.status == .userPaused)
        #expect(restored.snapshot()?.roleSnapshots.first?.state == .cancelled)
        #expect(restored.snapshot()?.verifyingInFlight == false)
    }

    @Test("TodoGate partitions in-progress tasks by insertion order and backing count")
    func todoGatePartitionsOnlyUnbackedWork() {
        let todos = [
            GoalTodoSnapshot(id: "first", content: "first running", status: "in_progress"),
            GoalTodoSnapshot(id: "pending", content: "still pending", status: "pending"),
            GoalTodoSnapshot(id: "second", content: "second running", status: "in_progress"),
            GoalTodoSnapshot(id: "done", content: "already done", status: "completed"),
        ]
        let input = GoalTodoGateInput(todos: todos, backingTaskCount: 1)
        #expect(input.inProgressBacked.map(\.id) == ["first"])
        #expect(input.inProgressUnbacked.map(\.id) == ["second"])
        #expect(input.pending.map(\.id) == ["pending"])

        guard case .nudge(let reminder, let reason) = GoalTodoGate.evaluate(input) else {
            Issue.record("unfinished and unbacked tasks did not trigger TodoGate")
            return
        }
        #expect(reason == "in_flight")
        #expect(reminder.contains("In-progress (no backing background task):\n- second running"))
        #expect(reminder.contains("Pending:\n- still pending"))
        #expect(!reminder.contains("first running"))
        #expect(reminder.contains("via todo_write"))

        let fullyBacked = GoalTodoGateInput(todos: [todos[0]], backingTaskCount: 1)
        #expect(GoalTodoGate.evaluate(fullyBacked) == .continueTurn)
    }

    @Test("nine upstream stop families match only anchored lines in the final paragraph")
    func prematureStopDetectorMatchesPinnedPatterns() {
        let cases = [
            ("I can't continue without the logs", "unable_to_proceed"),
            ("Giving up.", "giving_up"),
            ("Stopping here for now.", "stopping_here"),
            ("3 agents in flight", "agents_in_flight"),
            ("I'll check back when CI finishes", "check_back_later"),
            ("VERDICT: PASS", "verdict_line"),
            ("Committed as abcdef123", "commit_push_pr"),
            ("Ready for review", "ready_for_review"),
            ("Please run the tests", "please_deflection"),
        ]
        for (text, expected) in cases {
            #expect(GoalPrematureStopDetector.matchedPattern(in: text) == expected)
        }
        #expect(GoalPrematureStopDetector.matchedPattern(
            in: "Earlier work\r\n\r\nGiving up.\r\n"
        ) == "giving_up")
        #expect(GoalPrematureStopDetector.matchedPattern(
            in: "Giving up.\n\nContinuing to inspect the failure."
        ) == nil)
        #expect(GoalPrematureStopDetector.matchedPattern(
            in: "I will check back when your access is ready"
        ) == nil)
        #expect(GoalPrematureStopDetector.matchedPattern(
            in: "The model said Giving up while I continued."
        ) == nil)
        #expect(GoalPrematureStopDetector.matchedPattern(in: "Stopping hereafter is unrelated") == nil)
    }

    @Test("strategist triggers are skip robust and never fire with a disabled interval")
    func strategistTriggerUsesUpstreamThreshold() {
        #expect(GoalOrchestrationEngine.strategistShouldFire(
            consecutive: 6,
            lastFired: 0,
            every: 5
        ))
        #expect(!GoalOrchestrationEngine.strategistShouldFire(
            consecutive: 9,
            lastFired: 5,
            every: 5
        ))
        #expect(!GoalOrchestrationEngine.strategistShouldFire(
            consecutive: .max,
            lastFired: .max,
            every: 1
        ))
        #expect(!GoalOrchestrationEngine.strategistShouldFire(
            consecutive: 10,
            lastFired: 0,
            every: 0
        ))
    }

    @Test("role pools round-robin predictably and policy ceilings stay bounded")
    func rolePoolAndPolicyBounds() {
        let models = GoalRoleModels(skepticPool: [
            GoalRoleModel(model: "skeptic-a", agentType: "harness-a"),
            GoalRoleModel(model: "skeptic-b", agentType: "harness-b"),
        ])
        #expect(models.assignment(for: .skeptic, fallbackModel: "main", skepticIndex: 0).model == "skeptic-a")
        #expect(models.assignment(for: .skeptic, fallbackModel: "main", skepticIndex: 2).model == "skeptic-a")
        #expect(models.assignment(for: .evaluator, fallbackModel: "main").model == "main")

        let policy = GoalRuntimePolicy(
            maximumWorkerRounds: 0,
            maximumEvaluatorAttempts: 0,
            maximumVerifierAttempts: 0,
            skepticCount: 100,
            strategistEvery: 0
        )
        #expect(policy.maximumWorkerRounds == 1)
        #expect(policy.maximumEvaluatorAttempts == 1)
        #expect(policy.maximumVerifierAttempts == 1)
        #expect(policy.skepticCount == goalVerifierMaximumSkepticCount)
        #expect(policy.strategistEvery == 1)

        let untrusted = GoalRuntimePolicy(
            maximumWorkerRounds: .max,
            maximumEvaluatorAttempts: .max,
            maximumPlannerAttempts: .max,
            maximumVerifierAttempts: .max,
            maximumTodoGateFiresPerPrompt: .max
        )
        #expect(untrusted.maximumWorkerRounds == goalMaximumWorkerRoundsCeiling)
        #expect(untrusted.maximumEvaluatorAttempts == goalEvaluatorMaximumAttempts)
        #expect(untrusted.maximumPlannerAttempts == goalPlannerMaximumAttempts)
        #expect(untrusted.maximumVerifierAttempts == goalVerifierMaximumAttemptsDefault)
        #expect(untrusted.maximumTodoGateFiresPerPrompt == goalTodoGateMaximumFiresCeiling)
    }

    @Test("byte caps never split Unicode characters")
    func transcriptCapsRespectUnicodeBoundaries() {
        #expect(GoalOrchestrationEngine.cappedText("🙂🙂x", maximumBytes: 5) == "🙂")
        #expect(GoalOrchestrationEngine.cappedText("🙂", maximumBytes: 3).isEmpty)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-goal-orchestration-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
