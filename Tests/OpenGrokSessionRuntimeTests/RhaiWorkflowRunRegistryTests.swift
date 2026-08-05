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
