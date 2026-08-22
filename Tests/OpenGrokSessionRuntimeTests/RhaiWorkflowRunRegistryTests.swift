// RhaiWorkflowRunRegistryTests.swift
//
// The background run registry: lifecycle, journal contents, fan-out order,
// cancellation mid-run, and budget exhaustion.
//
// Every host here is a fake that answers structurally — no provider, no
// process. The point is the registry's and engine's behaviour, not a model's.

import Foundation
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokWorkflow
import Testing

@testable import OpenGrokSessionRuntime

// MARK: - Fakes

/// Records the order agents were asked for and lets a test hold them open.
private actor ScriptedWorkflowHost: RhaiWorkflowHost {
    struct Spawn: Sendable, Equatable {
        let label: String?
        let prompt: String
    }

    private let budget: UInt64
    private var used: UInt64 = 0
    private var reserved: UInt64 = 0
    private(set) var spawns: [Spawn] = []
    private(set) var peakConcurrency = 0
    private var inFlight = 0
    private let delayNanos: UInt64
    private let failLabels: Set<String>
    /// Flipped by the test to make every later spawn report cancellation, the
    /// way a real host does once its run's token is set.
    private var cancelling = false

    nonisolated let maxConcurrentAgents: Int

    init(
        budget: UInt64 = 64,
        maxConcurrentAgents: Int = 4,
        delayNanos: UInt64 = 0,
        failLabels: Set<String> = []
    ) {
        self.budget = budget
        self.maxConcurrentAgents = maxConcurrentAgents
        self.delayNanos = delayNanos
        self.failLabels = failLabels
    }

    func beginCancelling() { cancelling = true }

    func reserveAgentCalls(_ count: UInt64) throws {
        let requested = used + reserved + count
        guard requested <= budget else {
            throw RhaiHostError.agentCallQuotaExceeded(requested: requested, maximum: budget)
        }
        reserved += count
    }

    func releaseAgentCalls(_ count: UInt64) {
        reserved = reserved >= count ? reserved - count : 0
    }

    func spawnAgent(_ options: RhaiAgentOptions) async throws -> RhaiAgentResult {
        spawns.append(Spawn(label: options.label, prompt: options.prompt))
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        defer { inFlight -= 1 }
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        if cancelling { throw RhaiHostError.cancelled }
        reserved = reserved > 0 ? reserved - 1 : 0
        used += 1
        if let label = options.label, failLabels.contains(label) {
            throw RhaiHostError.failed("scripted failure for \(label)")
        }
        return RhaiAgentResult(
            agentID: options.label ?? "agent-\(used)",
            success: true,
            output: .object(["label": .string(options.label ?? ""), "ok": .bool(true)]),
            tokensUsed: 7
        )
    }

    func phase(title: String, replayed: Bool) {}
    func log(message: String, replayed: Bool) {}
    func telemetry(name: String, fields: JSONValue, replayed: Bool) {}
    func budgetState() -> RhaiBudgetState {
        RhaiBudgetState(total: budget, spent: used, reserved: reserved, remaining: budget - used - reserved)
    }
    func renderTemplate(name: String, variables: JSONValue) -> String { "template" }
    func writeScratchFile(name: String, content: String) -> String { "scratch/\(name)" }
    func readScratchFile(name: String) -> String { "" }
    func gitDiffSince(commit: String) -> String { "" }
}

private actor WorkflowRunAdmissionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor WorkflowRunContextCapture {
    private(set) var value: RhaiWorkflowRunContext?

    func record(_ context: RhaiWorkflowRunContext) {
        value = context
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("workflow-registry-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Tests

@Suite("Rhai workflow background run registry")
struct RhaiWorkflowRunRegistryTests {

    @Test("a run is registered before it starts and reaches a terminal record")
    func lifecycle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let host = ScriptedWorkflowHost()

        let record = try await registry.start(
            script: """
                let meta = #{ name: "lifecycle", description: "d", when_to_use: "w" };
                let r = agent("do the thing", #{ label: "worker" });
                complete(#{ done: r.success })
                """,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in host })
        )

        // Visible in the manifest immediately, before it can possibly be done.
        #expect(try await registry.list().map(\.runID).contains(record.runID))
        #expect(record.status == .active)

        let final = try await registry.awaitCompletion(runID: record.runID)
        #expect(final.status == .completed)
        #expect(final.result?["done"]?.boolValue == true)
        #expect(final.agentsUsed == 1)
        #expect(await registry.isRunning(record.runID) == false)
    }

    @Test("the journal on disk records every agent call in order")
    func journalContents() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let host = ScriptedWorkflowHost()

        let record = try await registry.start(
            script: """
                let meta = #{ name: "journal", description: "d", when_to_use: "w" };
                agent("first", #{ label: "one" });
                agent("second", #{ label: "two" });
                complete(#{ ok: true })
                """,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in host })
        )
        _ = try await registry.awaitCompletion(runID: record.runID)

        // Read the file back rather than the in-memory journal: the durable
        // artifact is what a resume and another process will see.
        let path = try #require(try await registry.record(runID: record.runID).journalPath)
        let reloaded = try RhaiJournal.load(path: URL(fileURLWithPath: path))
        let spawns = reloaded.snapshot.filter { $0.kind == "spawn_agent" }
        #expect(spawns.count == 2)
        #expect(spawns.map(\.seq) == [0, 1])
        #expect(spawns[0].result["agent_id"]?.stringValue == "one")
        #expect(spawns[1].result["agent_id"]?.stringValue == "two")
        // `phase`/`log` are fire-and-forget and consume no sequence number.
        #expect(reloaded.snapshot.allSatisfy { $0.kind == "spawn_agent" })
    }

    @Test("parallel() fans out under the cap and journals siblings in input order")
    func fanOutOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        // A delay makes the group actually overlap, so peak concurrency is
        // measured rather than accidentally 1.
        let host = ScriptedWorkflowHost(maxConcurrentAgents: 2, delayNanos: 2_000_000)

        let record = try await registry.start(
            script: """
                let meta = #{ name: "fanout", description: "d", when_to_use: "w" };
                let results = parallel([
                    #{ prompt: "a", label: "alpha" },
                    #{ prompt: "b", label: "bravo" },
                    #{ prompt: "c", label: "charlie" },
                    #{ prompt: "d", label: "delta" },
                ]);
                complete(#{ count: results.len() })
                """,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in host })
        )
        let final = try await registry.awaitCompletion(runID: record.runID)
        #expect(final.status == .completed)

        let entries = try await registry.journalEntries(runID: record.runID)
        let ids = entries.filter { $0.kind == "spawn_agent" }.map { $0.result["agent_id"]?.stringValue }
        // Journaled by position, regardless of which finished first.
        #expect(ids == ["alpha", "bravo", "charlie", "delta"])
        #expect(await host.peakConcurrency <= 2)
        #expect(await host.peakConcurrency >= 2)
    }

    @Test("cancelling mid-run stops the engine and lands a cancelled record")
    func cancellationMidRun() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let host = ScriptedWorkflowHost(delayNanos: 5_000_000)

        let record = try await registry.start(
            script: """
                let meta = #{ name: "cancel", description: "d", when_to_use: "w" };
                let i = 0;
                while i < 50 {
                    agent("work " + i, #{ label: "w" });
                    i += 1;
                }
                complete(#{ ok: true })
                """,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in host })
        )
        // Let it get going, then pull the token the way `/workflows` `x` does.
        try await Task.sleep(nanoseconds: 20_000_000)
        await host.beginCancelling()
        try await registry.cancel(runID: record.runID)

        let final = try await registry.awaitCompletion(runID: record.runID)
        #expect(final.status == .cancelled)
        // It stopped early rather than running all fifty.
        #expect(await host.spawns.count < 50)
        #expect(await registry.isRunning(record.runID) == false)
    }

    @Test("a fan-out larger than the budget ends the run resumably, spawning nothing")
    func budgetExhaustion() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let host = ScriptedWorkflowHost(budget: 2)

        let record = try await registry.start(
            script: """
                let meta = #{ name: "budget", description: "d", when_to_use: "w" };
                let results = parallel([
                    #{ prompt: "a", label: "alpha" },
                    #{ prompt: "b", label: "bravo" },
                    #{ prompt: "c", label: "charlie" },
                ]);
                complete(#{ count: results.len() })
                """,
            agentBudget: 2,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in host })
        )
        let final = try await registry.awaitCompletion(runID: record.runID)

        // A reservation refusal is terminal and non-catchable, so the run ends
        // `budget_exceeded` — resumable against a raised cap — rather than the
        // script catching it and carrying on.
        #expect(final.status == .budgetExceeded)
        #expect(final.status.isResumable)
        // Nothing ran: the whole panel is refused before any agent starts, so a
        // resume re-runs it rather than half-replaying it.
        #expect(await host.spawns.isEmpty)
        #expect(try await registry.journalEntries(runID: record.runID).isEmpty)
    }

    @Test("concurrent launches reserve their slots before actor suspension")
    func concurrentLaunchesRespectActiveRunLimit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let gate = WorkflowRunAdmissionGate()
        let hostFactory = RhaiWorkflowHostFactory(make: { _ in
            await gate.wait()
            return ScriptedWorkflowHost()
        })
        let script = "complete(#{ ok: true })"

        let outcomes = await withTaskGroup(
            of: Result<WorkflowRunRecord, RhaiWorkflowRegistryError>.self,
            returning: [Result<WorkflowRunRecord, RhaiWorkflowRegistryError>].self
        ) { group in
            for _ in 0..<(rhaiMaxActiveWorkflowRunsPerSession + 6) {
                group.addTask {
                    do {
                        return .success(try await registry.start(
                            script: script,
                            hostFactory: hostFactory
                        ))
                    } catch let error as RhaiWorkflowRegistryError {
                        return .failure(error)
                    } catch {
                        return .failure(.persistence(String(describing: error)))
                    }
                }
            }

            var outcomes: [Result<WorkflowRunRecord, RhaiWorkflowRegistryError>] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        var accepted: [WorkflowRunRecord] = []
        var rejected: [RhaiWorkflowRegistryError] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let record): accepted.append(record)
            case .failure(let error): rejected.append(error)
            }
        }
        #expect(accepted.count == rhaiMaxActiveWorkflowRunsPerSession)
        #expect(rejected.count == 6)
        #expect(rejected.allSatisfy {
            $0 == .tooManyActiveRuns(limit: rhaiMaxActiveWorkflowRunsPerSession)
        })
        #expect(try await registry.list().count == rhaiMaxActiveWorkflowRunsPerSession)

        await gate.open()
        for record in accepted {
            let completed = try await registry.awaitCompletion(runID: record.runID)
            #expect(completed.status == .completed)
        }

        let replacement = try await registry.start(script: script, hostFactory: hostFactory)
        #expect(try await registry.awaitCompletion(runID: replacement.runID).status == .completed)
    }

    @Test("a paused run cannot resume while all four workflow slots are occupied")
    func activeRunLimitAlsoAppliesToResume() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let pausedScript = "pause(\"user\", \"waiting\")"
        let pausedRun = try await registry.start(
            script: pausedScript,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in ScriptedWorkflowHost() })
        )
        let pausedRecord = try await registry.awaitCompletion(runID: pausedRun.runID)
        #expect(pausedRecord.status == .paused)

        let gate = WorkflowRunAdmissionGate()
        let hostFactory = RhaiWorkflowHostFactory(make: { _ in
            await gate.wait()
            return ScriptedWorkflowHost()
        })
        var activeRuns: [WorkflowRunRecord] = []
        for _ in 0..<rhaiMaxActiveWorkflowRunsPerSession {
            let active = try await registry.start(
                script: "complete(#{ ok: true })",
                hostFactory: hostFactory
            )
            activeRuns.append(active)
        }

        await #expect(throws: RhaiWorkflowRegistryError.tooManyActiveRuns(
            limit: rhaiMaxActiveWorkflowRunsPerSession
        )) {
            try await registry.resume(
                runID: pausedRun.runID,
                script: pausedScript,
                hostFactory: hostFactory
            )
        }
        #expect(try await registry.record(runID: pausedRun.runID) == pausedRecord)

        await gate.open()
        for active in activeRuns {
            #expect(try await registry.awaitCompletion(runID: active.runID).status == .completed)
        }
    }

    @Test("invalid initial or resumed agent budgets are rejected before persistence")
    func invalidAgentBudgetsAreRejected() async throws {
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore())
        let hostFactory = RhaiWorkflowHostFactory(make: { _ in ScriptedWorkflowHost() })

        for invalid in [UInt64.zero, rhaiMaxAgentBudget + 1] {
            await #expect(throws: RhaiWorkflowRegistryError.invalidAgentBudget(
                requested: invalid,
                maximum: rhaiMaxAgentBudget
            )) {
                try await registry.start(
                    script: "complete(#{ ok: true })",
                    agentBudget: invalid,
                    hostFactory: hostFactory
                )
            }
        }
        #expect(try await registry.list().isEmpty)

        let script = "pause(\"user\", \"waiting\")"
        let run = try await registry.start(script: script, hostFactory: hostFactory)
        let paused = try await registry.awaitCompletion(runID: run.runID)
        await #expect(throws: RhaiWorkflowRegistryError.invalidAgentBudget(
            requested: rhaiMaxAgentBudget + 1,
            maximum: rhaiMaxAgentBudget
        )) {
            try await registry.resume(
                runID: run.runID,
                script: script,
                agentBudget: rhaiMaxAgentBudget + 1,
                hostFactory: hostFactory
            )
        }
        #expect(try await registry.record(runID: run.runID) == paused)
    }

    @Test("a budget-limited run only resumes with a higher cumulative budget")
    func budgetLimitedResumeRequiresRaisedBudget() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let script = """
            agent("first", #{ label: "one" });
            agent("second", #{ label: "two" });
            agent("third", #{ label: "three" });
            complete(#{ ok: true })
            """
        let originalHost = ScriptedWorkflowHost(budget: 2)
        let run = try await registry.start(
            script: script,
            agentBudget: 2,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in originalHost })
        )
        let limited = try await registry.awaitCompletion(runID: run.runID)
        #expect(limited.status == .budgetExceeded)
        #expect(limited.agentsUsed == 2)
        #expect(await originalHost.spawns.count == 2)

        let unusedHostFactory = RhaiWorkflowHostFactory(make: { _ in ScriptedWorkflowHost() })
        await #expect(throws: RhaiWorkflowRegistryError.budgetNotRaised(used: 2, limit: 2)) {
            try await registry.resume(
                runID: run.runID,
                script: script,
                hostFactory: unusedHostFactory
            )
        }
        await #expect(throws: RhaiWorkflowRegistryError.budgetNotRaised(used: 2, limit: 2)) {
            try await registry.resume(
                runID: run.runID,
                script: script,
                agentBudget: 2,
                hostFactory: unusedHostFactory
            )
        }
        #expect(try await registry.record(runID: run.runID) == limited)

        // The journal may have made it to disk after the manifest's previous
        // accounting snapshot. Resume must trust the larger durable count.
        var staleManifest = limited
        staleManifest.agentsUsed = 0
        try await registry.store.update(staleManifest)

        let capturedContext = WorkflowRunContextCapture()
        let resumedHost = ScriptedWorkflowHost(budget: 1)
        let resumed = try await registry.resume(
            runID: run.runID,
            script: script,
            agentBudget: 3,
            hostFactory: RhaiWorkflowHostFactory(make: { context in
                await capturedContext.record(context)
                return resumedHost
            })
        )
        #expect(resumed.status == .active)
        #expect(resumed.agentBudget == 3)
        #expect(resumed.agentsUsed == 2)

        let completed = try await registry.awaitCompletion(runID: run.runID)
        #expect(completed.status == .completed)
        #expect(completed.agentBudget == 3)
        #expect(completed.agentsUsed == 3)
        #expect(await resumedHost.spawns.map(\.label) == ["three"])
        let context = try #require(await capturedContext.value)
        #expect(context.agentBudget == 3)
        #expect(context.priorAgentsUsed == 2)
    }

    @Test("a run that spent the global maximum cannot be resumed")
    func budgetAtGlobalMaximumIsNotResumable() async throws {
        let store = WorkflowSessionStore()
        let script = "pause(\"user\", \"waiting\")"
        let arguments = JSONValue.object([:])
        try await store.insert(WorkflowRunRecord(
            runID: "wf_maxed",
            workflowName: "maxed",
            scriptHash: rhaiRequestHash(kind: "script", payload: .string(script)),
            argumentsHash: rhaiRequestHash(kind: "arguments", payload: arguments),
            status: .budgetExceeded,
            agentBudget: rhaiMaxAgentBudget,
            agentsUsed: rhaiMaxAgentBudget
        ))
        let registry = RhaiWorkflowRunRegistry(store: store)

        await #expect(throws: RhaiWorkflowRegistryError.notResumable(
            "maximum agent budget reached; start a new run"
        )) {
            try await registry.resume(
                runID: "wf_maxed",
                script: script,
                agentBudget: rhaiMaxAgentBudget,
                hostFactory: RhaiWorkflowHostFactory(make: { _ in ScriptedWorkflowHost() })
            )
        }
        #expect(try await registry.record(runID: "wf_maxed").status == .budgetExceeded)
    }

    @Test("a resumed run replays its journal instead of re-spawning")
    func resumeReplaysCachedPrefix() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))

        // First run: two agents, then a pause the script chooses.
        let script = """
            let meta = #{ name: "resume", description: "d", when_to_use: "w" };
            agent("first", #{ label: "one" });
            agent("second", #{ label: "two" });
            if args.stop == true { pause("user", "waiting") }
            complete(#{ ok: true })
            """
        let first = ScriptedWorkflowHost()
        let record = try await registry.start(
            script: script,
            arguments: .object(["stop": .bool(true)]),
            hostFactory: RhaiWorkflowHostFactory(make: { _ in first })
        )
        let paused = try await registry.awaitCompletion(runID: record.runID)
        #expect(paused.status == .paused)
        #expect(await first.spawns.count == 2)

        // Resume over the same journal with a fresh host. The two agents must
        // come from the journal, not from the host.
        let second = ScriptedWorkflowHost()
        _ = try await registry.resume(
            runID: record.runID,
            script: script,
            arguments: .object(["stop": .bool(true)]),
            hostFactory: RhaiWorkflowHostFactory(make: { _ in second })
        )
        let again = try await registry.awaitCompletion(runID: record.runID)
        #expect(again.status == .paused)
        #expect(await second.spawns.isEmpty)
        #expect(try await registry.journalEntries(runID: record.runID).count == 2)
    }

    @Test("resume refuses a different script rather than diverging")
    func resumeRejectsEditedScript() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let script = """
            let meta = #{ name: "immutable", description: "d", when_to_use: "w" };
            pause("user", "waiting")
            """
        let record = try await registry.start(
            script: script,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in ScriptedWorkflowHost() })
        )
        _ = try await registry.awaitCompletion(runID: record.runID)

        await #expect(throws: RhaiWorkflowRegistryError.scriptMismatch(record.runID)) {
            _ = try await registry.resume(
                runID: record.runID,
                script: script + "\n// edited\n",
                hostFactory: RhaiWorkflowHostFactory(make: { _ in ScriptedWorkflowHost() })
            )
        }
    }

    @Test("resume refuses changed launch arguments before touching the journal")
    func resumeRejectsChangedArguments() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let script = """
            agent(args.objective, #{ label: "worker" });
            pause("user", "waiting")
            """
        let originalArguments = JSONValue.object(["objective": .string("audit only")])
        let run = try await registry.start(
            script: script,
            arguments: originalArguments,
            hostFactory: RhaiWorkflowHostFactory(make: { _ in ScriptedWorkflowHost() })
        )
        let paused = try await registry.awaitCompletion(runID: run.runID)
        #expect(paused.status == .paused)
        let originalJournal = try await registry.journalEntries(runID: run.runID)

        await #expect(throws: RhaiWorkflowRegistryError.argumentsMismatch(run.runID)) {
            try await registry.resume(
                runID: run.runID,
                script: script,
                arguments: .object(["objective": .string("modify production")]),
                hostFactory: RhaiWorkflowHostFactory(make: { _ in ScriptedWorkflowHost() })
            )
        }

        #expect(try await registry.record(runID: run.runID) == paused)
        #expect(try await registry.journalEntries(runID: run.runID) == originalJournal)
    }

    @Test("the run view combines the journal with live phase and agent progress")
    func viewMergesJournalAndProgress() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))

        // A host that publishes to the board the way `LiveWorkflowHost` does.
        let record = try await registry.start(
            script: """
                let meta = #{ name: "view", description: "d", when_to_use: "w" };
                phase("scout");
                agent("look around", #{ label: "scout" });
                phase("report");
                complete(#{ ok: true })
                """,
            hostFactory: RhaiWorkflowHostFactory(make: { context in
                BoardWritingHost(board: context.progress)
            })
        )
        _ = try await registry.awaitCompletion(runID: record.runID)

        let view = try await registry.view(runID: record.runID)
        // Phases exist only on the board; agents exist in the journal.
        #expect(view.phases == ["scout", "report"])
        #expect(view.currentPhase == "report")
        #expect(view.agents.count == 1)
        #expect(view.agents[0].label == "scout")
        #expect(view.agents[0].state == .succeeded)
        #expect(view.progress.tokensUsed == 11)
    }

    @Test("restore marks a run left active by a dead process as interrupted")
    func restoreInterruptsOrphans() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowSessionStore(directory: directory)
        try await store.insert(WorkflowRunRecord(
            runID: "wf_orphan",
            workflowName: "orphan",
            scriptHash: "h",
            argumentsHash: "h",
            status: .active,
            agentBudget: 8
        ))

        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: directory))
        let restored = try await registry.restore()
        #expect(restored.first(where: { $0.runID == "wf_orphan" })?.status == .interrupted)
    }
}

/// Publishes to the progress board so the view test exercises the real merge.
private actor BoardWritingHost: RhaiWorkflowHost {
    private let board: RhaiWorkflowProgressBoard
    private var count: UInt64 = 0

    init(board: RhaiWorkflowProgressBoard) { self.board = board }

    nonisolated var maxConcurrentAgents: Int { 4 }

    func reserveAgentCalls(_ count: UInt64) throws {}
    func releaseAgentCalls(_ count: UInt64) {}

    func spawnAgent(_ options: RhaiAgentOptions) async throws -> RhaiAgentResult {
        count += 1
        let id = options.label ?? "agent-\(count)"
        await board.agentStarted(agentID: id, label: options.label, phase: options.phase)
        await board.agentFinished(agentID: id, state: .succeeded, tokensUsed: 11)
        return RhaiAgentResult(agentID: id, success: true, output: .object([:]), tokensUsed: 11)
    }

    func phase(title: String, replayed: Bool) async {
        await board.enterPhase(title, replayed: replayed)
    }
    func log(message: String, replayed: Bool) async { await board.log(message) }
    func telemetry(name: String, fields: JSONValue, replayed: Bool) {}
    func budgetState() -> RhaiBudgetState { RhaiBudgetState() }
    func renderTemplate(name: String, variables: JSONValue) -> String { "" }
    func writeScratchFile(name: String, content: String) -> String { name }
    func readScratchFile(name: String) -> String { "" }
    func gitDiffSince(commit: String) -> String { "" }
}
