import Foundation
import OpenGrokGoalState
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing

@testable import OpenGrokCLI

private enum LiveGoalOrchestrationScriptError: Error, Sendable {
    case transient
    case exhausted
}

private actor LiveGoalEvaluatorScript: GoalIndependentEvaluator {
    private let verdicts: [GoalEvaluationVerdict]
    private var remainingFailures: Int
    private(set) var requests: [GoalEvaluationRequest] = []

    init(_ verdicts: [GoalEvaluationVerdict], failures: Int = 0) {
        self.verdicts = verdicts
        remainingFailures = failures
    }

    func evaluateGoal(_ request: GoalEvaluationRequest) async throws -> GoalEvaluationVerdict {
        requests.append(request)
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw LiveGoalOrchestrationScriptError.transient
        }
        guard !verdicts.isEmpty else {
            throw LiveGoalOrchestrationScriptError.exhausted
        }
        return verdicts[min(requests.count - 1, verdicts.count - 1)]
    }
}

private actor LiveGoalVerifierScript: GoalIndependentVerifier {
    private let verdicts: [GoalVerificationVerdict]
    private(set) var requests: [GoalVerificationRequest] = []

    init(_ verdicts: [GoalVerificationVerdict]) {
        self.verdicts = verdicts
    }

    func verifyGoal(_ request: GoalVerificationRequest) async throws -> GoalVerificationVerdict {
        requests.append(request)
        guard !verdicts.isEmpty else {
            throw LiveGoalOrchestrationScriptError.exhausted
        }
        return verdicts[min(requests.count - 1, verdicts.count - 1)]
    }
}

private actor LiveGoalRoleScript: GoalRoleRunner {
    let output: String
    private(set) var requests: [GoalRoleRequest] = []

    init(output: String) {
        self.output = output
    }

    func runGoalRole(_ request: GoalRoleRequest) async throws -> String {
        requests.append(request)
        return output
    }
}

private actor LiveGoalRoleSamplingCapture {
    private(set) var requests: [OpenGrokLiveSamplingRequest] = []
    private var skepticCalls = 0

    func sample(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        let output: String
        if request.turnID.hasPrefix("goal-evaluator-") {
            output = #"{"decision":"candidate_complete","evidence":"required checks are green","next_step":"verify independently","blocker_key":""}"#
        } else if request.turnID.hasPrefix("goal-skeptic-") {
            skepticCalls += 1
            if skepticCalls == 1 {
                output = #"{"decision":"not_achieved","evidence":"first skeptic remains cautious","next_step":"inspect artifact","gaps":["artifact not inspected"]}"#
            } else {
                output = #"{"decision":"achieved","evidence":"independent artifact and test evidence verified","next_step":"report completion","gaps":[]}"#
            }
        } else {
            output = "# Independent plan\n1. Implement the objective.\n2. Verify every acceptance check."
        }
        return OpenGrokLiveSamplingResponse(
            output: output,
            usage: TokenUsage(promptTokens: 2, completionTokens: 1, totalTokens: 3)
        )
    }
}

private actor LiveGoalTurnSamplingCapture {
    enum Mode: Sendable {
        case goal
        case todoGate
    }

    private let mode: Mode
    private var evaluatorCalls = 0
    private var workerCalls = 0
    private(set) var requests: [OpenGrokLiveSamplingRequest] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func sample(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        if request.turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compact transcript summary")
        }
        requests.append(request)
        let usage = TokenUsage(promptTokens: 2, completionTokens: 1, totalTokens: 3)
        switch mode {
        case .todoGate:
            workerCalls += 1
            if workerCalls == 1 {
                return OpenGrokLiveSamplingResponse(
                    output: "Recording unfinished work.",
                    toolCalls: [ToolCall(
                        id: "todo-gate-task",
                        name: "todo_write",
                        arguments: #"{"todos":[{"id":"pending","content":"Finish the actual work","status":"pending"}]}"#
                    )],
                    usage: usage
                )
            }
            return OpenGrokLiveSamplingResponse(output: "Still stopped without a tool call.", usage: usage)

        case .goal:
            if request.turnID.hasPrefix("goal-evaluator-") {
                evaluatorCalls += 1
                let output = evaluatorCalls == 1
                    ? #"{"decision":"continue","evidence":"one acceptance check remains","next_step":"finish the acceptance check","blocker_key":""}"#
                    : #"{"decision":"candidate_complete","evidence":"all acceptance checks are green","next_step":"run independent verification","blocker_key":""}"#
                return OpenGrokLiveSamplingResponse(output: output, usage: usage)
            }
            if request.turnID.hasPrefix("goal-skeptic-") {
                return OpenGrokLiveSamplingResponse(
                    output: #"{"decision":"achieved","evidence":"independently verified acceptance checks","next_step":"report completion","gaps":[]}"#,
                    usage: usage
                )
            }
            if request.tools.isEmpty {
                return OpenGrokLiveSamplingResponse(
                    output: "# Goal plan\n1. Finish the acceptance check.\n2. Verify it independently.",
                    usage: usage
                )
            }
            workerCalls += 1
            let output = workerCalls == 1
                ? "One acceptance check remains."
                : "The acceptance check completed successfully."
            return OpenGrokLiveSamplingResponse(output: output, usage: usage)
        }
    }
}

private struct LiveGoalOrchestrationFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let sessionDirectory: URL
    let coordinator: LiveGoalCoordinator
    let history: LiveConversationHistory
    let todoStore: LiveTodoStore
    let sessionID = "goal-orchestration-session"

    init() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-goal-orchestration-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [home, workspace] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(
            sessionID: "goal-orchestration-session",
            workingDirectory: workspace
        )
        record.currentModelID = "worker-model"
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)
        let directory = try SessionDocumentStore(grokHome: home).sessionDirectory(
            sessionID: "goal-orchestration-session",
            cwd: workspace.standardizedFileURL.path
        )

        self.root = root
        self.home = home
        self.workspace = workspace
        sessionDirectory = directory
        coordinator = LiveGoalCoordinator(sessionDirectory: directory, stateRoot: home)
        self.history = history
        todoStore = LiveTodoStore()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live goal orchestration and TodoGate parity", .serialized)
struct LiveGoalOrchestrationParityTests {
    @Test("the live shell resumes a content-only goal round and independently verifies completion")
    func productionShellContinuesGoalInsideSameTurn() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        let capture = LiveGoalTurnSamplingCapture(mode: .goal)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    await capture.sample(request)
                }
            }
        )
        let environment = [
            "HOME": fixture.home.path,
            "OPENGROK_HOME": fixture.home.path,
            "GROK_SANDBOX": "off",
            "XDG_STATE_HOME": fixture.home.appendingPathComponent("state").path,
            "XAI_API_KEY": "goal-orchestration-test-key",
        ]
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "finish the goal", "--cwd", fixture.workspace.path,
            "--model", "grok-4.5",
        ])
        guard case .launch(let options) = command else {
            Issue.record("goal turn fixture failed to create a live launch")
            return
        }
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context,
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: context,
            dependencies: dependencies
        )
        let goal = try #require(foundation.toolExecutor.sessionServices?.goal)
        try (await goal.createGoal(objective: "finish and independently verify the acceptance check")).get()

        let shell = stack.shell
        let started = try await shell.start()
        #expect(started.state == .running)
        let sessionID = SessionID(foundation.sessionID)
        let created = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))
        #expect(created.sessionID == sessionID)
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: "live-goal-prompt",
                text: "finish the acceptance check",
                turnID: "live-goal-turn"
            )
        )
        let result = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 30))

        #expect(result.output.contains("acceptance check completed"))
        #expect(await goal.status == .complete)
        let requests = await capture.requests
        let workerRequests = requests.filter { !$0.tools.isEmpty }
        #expect(workerRequests.count == 2)
        #expect(requests.filter { $0.turnID.hasPrefix("goal-evaluator-") }.count == 2)
        #expect(requests.filter { $0.turnID.hasPrefix("goal-skeptic-") }.count == 3)
        #expect(workerRequests[1].items.contains { item in
            guard case .user(let user) = item else { return false }
            return user.syntheticReason == .autoContinue
                && item.textContent().contains("finish the acceptance check")
        })
    }

    @Test("--todo-gate injects exactly two synthetic reminders through the real live turn")
    func productionTodoGateResamplesTwiceAndStops() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        let capture = LiveGoalTurnSamplingCapture(mode: .todoGate)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    await capture.sample(request)
                }
            }
        )
        let streams = CLIStreams.buffered()
        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "finish the pending task", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--todo-gate",
            ],
            environment: [
                "HOME": fixture.home.path,
                "OPENGROK_HOME": fixture.home.path,
                "GROK_SANDBOX": "off",
                "XDG_STATE_HOME": fixture.home.appendingPathComponent("state").path,
                "XAI_API_KEY": "todo-gate-test-key",
            ],
            streams: streams.0,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )

        #expect(code == 0, "live TodoGate launch failed: \(streams.2.contents)")
        let requests = await capture.requests
        #expect(requests.count == 4)
        let reminderCounts = requests.map { request in
            request.items.filter { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == .autoContinue
                    && item.textContent().contains("You have outstanding todos")
            }.count
        }
        #expect(reminderCounts == [0, 0, 1, 2])
    }

    @Test("a candidate without an independent verifier pauses with the pinned infra message")
    func evaluatorCannotCompleteWithoutVerifier() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        let candidate = try GoalEvaluationVerdict(
            decision: .candidateComplete,
            evidence: "worker claims completion",
            nextStep: "verify independently"
        )
        let evaluator = LiveGoalEvaluatorScript([candidate])
        await fixture.coordinator.configureOrchestration(
            evaluator: evaluator,
            model: "worker-model",
            todoStore: fixture.todoStore
        )
        try (await fixture.coordinator.createGoal(objective: "finish safely")).get()

        let outcome = await fixture.coordinator.runGoalRoundEnd(
            assistantText: "Everything is complete.",
            promptID: "candidate-prompt",
            currentTokens: 0
        )

        guard case .paused(let status, let message) = outcome else {
            Issue.record("an independently unverified candidate did not pause: \(outcome)")
            return
        }
        #expect(status == .infraPaused)
        #expect(message == LiveGoalCoordinator.verificationUnavailableMessage)
        #expect(await fixture.coordinator.status == .infraPaused)
        #expect(await evaluator.requests.count == 1)
    }

    @Test("the real update_goal tool rejects worker self-attestation until the evaluator agrees")
    func updateGoalSelfClaimCannotBypassEvaluator() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        let evaluator = LiveGoalEvaluatorScript([try GoalEvaluationVerdict(
            decision: .continueWork,
            evidence: "the requested test has not run",
            nextStep: "run the requested test"
        )])
        let verifier = LiveGoalVerifierScript([try GoalVerificationVerdict(
            decision: .achieved,
            evidence: "a verifier response must remain unreachable",
            nextStep: "report completion"
        )])
        await fixture.coordinator.configureOrchestration(
            evaluator: evaluator,
            verifier: verifier,
            model: "worker-model",
            todoStore: fixture.todoStore
        )
        try (await fixture.coordinator.createGoal(objective: "run the requested test")).get()

        let output = await LiveGoalTools.invoke(
            arguments: .object([
                "completed": .bool(true),
                "message": .string("I promise the test passed"),
            ]),
            coordinator: fixture.coordinator
        )

        #expect(output.contains("run the requested test"))
        #expect(await fixture.coordinator.status == .active)
        #expect(await evaluator.requests.count == 1)
        #expect(await verifier.requests.isEmpty)
    }

    @Test("update_goal samples planner, evaluator, and an independent three-skeptic majority")
    func updateGoalUsesSeparateAuthenticatedRoleRequests() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        let capture = LiveGoalRoleSamplingCapture()
        let sampler = OpenGrokLiveSampler { request, _ in
            await capture.sample(request)
        }
        let models = GoalRoleModels(
            planner: GoalRoleModel(model: "planner-model", agentType: "planner"),
            evaluator: GoalRoleModel(model: "evaluator-model", agentType: "evaluator"),
            skepticPool: [
                GoalRoleModel(model: "skeptic-a", agentType: "skeptic"),
                GoalRoleModel(model: "skeptic-b", agentType: "skeptic"),
            ]
        )
        await fixture.coordinator.configureLiveRuntime(
            sampler: sampler,
            sessionID: fixture.sessionID,
            model: "worker-model",
            history: fixture.history,
            todoStore: fixture.todoStore,
            roleModels: models
        )
        try (await fixture.coordinator.createGoal(objective: "verify the complete delivery")).get()

        let output = await LiveGoalTools.invoke(
            arguments: .object([
                "completed": .bool(true),
                "message": .string("the worker claims the delivery is complete"),
            ]),
            coordinator: fixture.coordinator
        )

        #expect(output.contains("independently verified complete"))
        #expect(await fixture.coordinator.status == .complete)
        let calls = await capture.requests
        #expect(calls.count == 5)
        #expect(Set(calls.map(\.sessionID)) == [fixture.sessionID])
        #expect(Set(calls.map(\.turnID)).count == calls.count)
        #expect(calls.allSatisfy { $0.tools.isEmpty && $0.hostedTools.isEmpty })
        #expect(calls.map(\.model) == [
            "planner-model", "evaluator-model", "skeptic-a", "skeptic-b", "skeptic-a",
        ])
        #expect(calls[0].jsonSchema == nil)
        #expect(calls.dropFirst().allSatisfy { $0.jsonSchema != nil })
        #expect(calls.allSatisfy { $0.maxOutputTokens != nil && $0.retryOnlyBeforeOutput })
        let usage = await fixture.history.usageSnapshot
        #expect(usage?.totals.totalTokens == 15)

        let snapshot = try #require(await fixture.coordinator.snapshot)
        #expect(snapshot.lastClassifierVerdict == .achieved)
        #expect(snapshot.roleSnapshots.map(\.role) == [
            .planner, .evaluator, .skeptic, .skeptic, .skeptic,
        ])
        #expect(snapshot.roleSnapshots.allSatisfy { $0.state == .succeeded })
        let planURL = URL(fileURLWithPath: try #require(snapshot.planFile))
        #expect(snapshot.planBaselineFile == nil)
        let baselineURL = planURL.deletingLastPathComponent()
            .appendingPathComponent("plan.baseline.md")
        let planData = try Data(contentsOf: planURL)
        let baselineData = try Data(contentsOf: baselineURL)
        #expect(planData == baselineData)
        #if !os(Windows)
        for file in [planURL, baselineURL] {
            let permissions = try #require(
                FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                    as? NSNumber
            )
            #expect((permissions.intValue & 0o777) == 0o600)
        }
        #endif
    }

    @Test("a verifier rejection carries concrete gaps and invokes the bounded strategist")
    func verifierGapsTriggerDurableStrategyWithoutCompleting() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        let evaluator = LiveGoalEvaluatorScript([try GoalEvaluationVerdict(
            decision: .candidateComplete,
            evidence: "implementation appears complete",
            nextStep: "independently verify"
        )])
        let verifier = LiveGoalVerifierScript([try GoalVerificationVerdict(
            decision: .notAchieved,
            evidence: "the release proof is absent",
            nextStep: "capture the exact-head release proof",
            gaps: ["exact-head release verification did not run"]
        )])
        let strategist = LiveGoalRoleScript(output: "Run exact-head checks before claiming success.")
        await fixture.coordinator.configureOrchestration(
            evaluator: evaluator,
            verifier: verifier,
            strategist: strategist,
            model: "worker-model",
            policy: GoalRuntimePolicy(strategistEvery: 1),
            todoStore: fixture.todoStore
        )
        try (await fixture.coordinator.createGoal(objective: "publish a verified release")).get()

        let outcome = await fixture.coordinator.runGoalRoundEnd(
            assistantText: "The release is done.",
            promptID: "strategy-prompt",
            currentTokens: 0
        )

        guard case .continuePursuit(let directive) = outcome else {
            Issue.record("unverified release did not remain active: \(outcome)")
            return
        }
        #expect(directive.contains("exact-head release verification did not run"))
        #expect(directive.contains("Run exact-head checks"))
        #expect(await fixture.coordinator.status == .active)
        #expect(await strategist.requests.count == 1)
        let snapshot = try #require(await fixture.coordinator.snapshot)
        let strategyURL = URL(fileURLWithPath: try #require(snapshot.lastStrategyPath))
        #expect(try String(contentsOf: strategyURL, encoding: .utf8).contains("exact-head"))
        #if !os(Windows)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: strategyURL.path)[.posixPermissions]
                as? NSNumber
        )
        #expect((permissions.intValue & 0o777) == 0o600)
        #endif
    }

    @Test("even an independent achieved verdict cannot conceal outstanding durable todos")
    func achievedVerifierCannotOverrideUnfinishedTodos() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        await fixture.todoStore.upsert(LiveTodoItem(
            id: "missing-test",
            content: "Run the acceptance suite",
            status: .pending
        ))
        let evaluator = LiveGoalEvaluatorScript([try GoalEvaluationVerdict(
            decision: .candidateComplete,
            evidence: "worker claims its pending task is already finished",
            nextStep: "independently verify"
        )])
        let verifier = LiveGoalVerifierScript([try GoalVerificationVerdict(
            decision: .achieved,
            evidence: "an adversarial verifier wrongly ignored the task list",
            nextStep: "report completion"
        )])
        await fixture.coordinator.configureOrchestration(
            evaluator: evaluator,
            verifier: verifier,
            model: "worker-model",
            todoStore: fixture.todoStore
        )
        try (await fixture.coordinator.createGoal(objective: "run every requested test")).get()

        let outcome = await fixture.coordinator.runGoalRoundEnd(
            assistantText: "Everything is finished.",
            promptID: "pending-todo-prompt",
            currentTokens: 0
        )

        guard case .continuePursuit(let directive) = outcome else {
            Issue.record("outstanding todos were incorrectly treated as verified: \(outcome)")
            return
        }
        #expect(directive.contains("Run the acceptance suite"))
        #expect(await fixture.coordinator.status == .active)
        #expect(await fixture.coordinator.snapshot?.lastClassifierVerdict == .notAchieved)
    }

    @Test("goal budgets stop pursuit before an independent evaluator can spend more")
    func exhaustedBudgetPreventsAnotherRoleCall() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        let evaluator = LiveGoalEvaluatorScript([try GoalEvaluationVerdict(
            decision: .continueWork,
            evidence: "more work remains",
            nextStep: "continue implementation"
        )])
        await fixture.coordinator.configureOrchestration(
            evaluator: evaluator,
            model: "worker-model",
            todoStore: fixture.todoStore
        )
        try (await fixture.coordinator.createGoal(objective: "respect budget", tokenBudget: 5)).get()

        let outcome = await fixture.coordinator.runGoalRoundEnd(
            assistantText: "Continue without limits.",
            promptID: "budget-prompt",
            currentTokens: 5
        )

        guard case .budgetLimited(let message) = outcome else {
            Issue.record("an exhausted token budget failed open: \(outcome)")
            return
        }
        #expect(message.contains("5 of 5"))
        #expect(await fixture.coordinator.status == .budgetLimited)
        #expect(await evaluator.requests.isEmpty)
    }

    @Test("same external blocker requires three independent rounds before pausing")
    func stableExternalBlockerRequiresThreeRounds() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        let evaluator = LiveGoalEvaluatorScript([try GoalEvaluationVerdict(
            decision: .blocked,
            evidence: "repository credentials are missing",
            nextStep: "grant repository access",
            blockerKey: "repository_access_missing"
        )])
        await fixture.coordinator.configureOrchestration(
            evaluator: evaluator,
            model: "worker-model",
            todoStore: fixture.todoStore
        )
        try (await fixture.coordinator.createGoal(objective: "push the audited change")).get()

        for round in 1...2 {
            let outcome = await fixture.coordinator.runGoalRoundEnd(
                assistantText: "credentials are unavailable",
                promptID: "blocker-\(round)",
                currentTokens: 0
            )
            guard case .continuePursuit(let directive) = outcome else {
                Issue.record("round \(round) paused before the three-strike threshold")
                return
            }
            #expect(directive.contains("\(round)/3"))
        }

        let third = await fixture.coordinator.runGoalRoundEnd(
            assistantText: "credentials are still unavailable",
            promptID: "blocker-3",
            currentTokens: 0
        )
        guard case .paused(let status, let message) = third else {
            Issue.record("the third stable blocker did not pause: \(third)")
            return
        }
        #expect(status == .blocked)
        #expect(message.contains("Next user action: grant repository access"))
    }

    @Test("unfinished todos and premature stopping survive restart and bounded resume")
    func prematureStopAndTodosCarryAcrossRestart() async throws {
        let fixture = try await LiveGoalOrchestrationFixture()
        defer { fixture.cleanup() }
        await fixture.todoStore.upsert(LiveTodoItem(
            id: "run-tests",
            content: "Run the actual test suite",
            status: .pending
        ))
        let evaluator = LiveGoalEvaluatorScript([try GoalEvaluationVerdict(
            decision: .continueWork,
            evidence: "test suite is still pending",
            nextStep: "run the actual test suite"
        )])
        await fixture.coordinator.configureOrchestration(
            evaluator: evaluator,
            model: "worker-model",
            policy: GoalRuntimePolicy(maximumWorkerRounds: 1),
            todoStore: fixture.todoStore
        )
        try (await fixture.coordinator.createGoal(objective: "finish verified work")).get()
        let first = await fixture.coordinator.runGoalRoundEnd(
            assistantText: "Giving up.",
            promptID: "resume-prompt",
            currentTokens: 0
        )
        guard case .continuePursuit(let directive) = first else {
            Issue.record("premature stop was not corrected: \(first)")
            return
        }
        #expect(directive.contains("giving_up"))
        #expect(directive.contains("Run the actual test suite"))

        let capped = await fixture.coordinator.runGoalRoundEnd(
            assistantText: "Still incomplete.",
            promptID: "resume-prompt",
            currentTokens: 0
        )
        guard case .paused(let cappedStatus, _) = capped else {
            Issue.record("worker-round ceiling was not enforced")
            return
        }
        #expect(cappedStatus == .noProgressPaused)

        let restoredTodos = LiveTodoStore()
        let restored = LiveGoalCoordinator(
            sessionDirectory: fixture.sessionDirectory,
            stateRoot: fixture.home
        )
        await restored.configureOrchestration(
            evaluator: evaluator,
            model: "worker-model",
            policy: GoalRuntimePolicy(maximumWorkerRounds: 1),
            todoStore: restoredTodos
        )
        #expect(await restoredTodos.todos.map(\.id) == ["run-tests"])
        try (await restored.resume()).get()
        let resumed = await restored.runGoalRoundEnd(
            assistantText: "Continuing the verification.",
            promptID: "resumed-prompt",
            currentTokens: 0
        )
        guard case .continuePursuit = resumed else {
            Issue.record("restart did not receive a fresh bounded round: \(resumed)")
            return
        }
        let snapshot = try #require(await restored.snapshot)
        #expect(snapshot.totalWorkerRounds == 2)
        #expect(snapshot.roundResumeAnchor == 1)
        #expect(snapshot.history.contains { $0.event == .prematureStopDetected })
    }

    @Test("TodoGate is opt-in, excludes backed tasks, and caps reminders per prompt")
    func todoGateRespectsEnablementBackingAndPromptCaps() async {
        let todos = LiveTodoStore()
        await todos.upsert(LiveTodoItem(id: "backed", content: "Background task", status: .inProgress))
        let enabled = GoalRuntimePolicy(todoGateEnabled: true, maximumTodoGateFiresPerPrompt: 2)
        let backed = await todos.evaluateTurnEndGate(
            promptID: "p1",
            assistantMadeToolCall: false,
            backingTaskCount: 1,
            goalHarnessActive: false,
            policy: enabled
        )
        #expect(backed == .continueTurn)
        await todos.upsert(LiveTodoItem(id: "pending", content: "Pending work", status: .pending))

        for _ in 0..<2 {
            let decision = await todos.evaluateTurnEndGate(
                promptID: "p1",
                assistantMadeToolCall: false,
                backingTaskCount: 1,
                goalHarnessActive: false,
                policy: enabled
            )
            guard case .nudge(let reminder, _) = decision else {
                Issue.record("enabled TodoGate did not inject its bounded reminder")
                return
            }
            #expect(reminder.contains("Pending work"))
            #expect(!reminder.contains("Background task"))
        }
        #expect(await todos.currentGateFireCount == 2)
        let exhausted = await todos.evaluateTurnEndGate(
            promptID: "p1",
            assistantMadeToolCall: false,
            backingTaskCount: 1,
            goalHarnessActive: false,
            policy: enabled
        )
        #expect(exhausted == .continueTurn)
        let disabled = await todos.evaluateTurnEndGate(
            promptID: "p2",
            assistantMadeToolCall: false,
            backingTaskCount: 0,
            goalHarnessActive: false,
            policy: GoalRuntimePolicy()
        )
        #expect(disabled == .continueTurn)
        let suppressed = await todos.evaluateTurnEndGate(
            promptID: "p3",
            assistantMadeToolCall: false,
            backingTaskCount: 0,
            goalHarnessActive: true,
            policy: enabled
        )
        #expect(suppressed == .continueTurn)
        let renewed = await todos.evaluateTurnEndGate(
            promptID: "p4",
            assistantMadeToolCall: false,
            backingTaskCount: 1,
            goalHarnessActive: false,
            policy: enabled
        )
        guard case .nudge = renewed else {
            Issue.record("a genuine new prompt did not reset the TodoGate cap")
            return
        }
    }
}
