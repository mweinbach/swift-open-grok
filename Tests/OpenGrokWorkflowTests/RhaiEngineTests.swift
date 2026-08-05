import Foundation
import Testing
@testable import OpenGrokWorkflow
import OpenGrokShared

/// A recording stand-in for the agent-execution seam. It never spawns anything
/// real: it answers from a script supplied by the test and records what the
/// engine asked for, including peak concurrency, so `parallel()`'s barrier and
/// `agent()`'s sequencing can be told apart.
actor FakeAgentHost: RhaiWorkflowHost {
    enum Reply: Sendable {
        case success(output: JSONValue)
        case failure(RhaiHostError)
    }

    private var replies: [String: Reply] = [:]
    private var defaultReply: Reply = .success(output: .string("ok"))
    private var reserveFailure: RhaiHostError?

    private(set) var prompts: [String] = []
    private(set) var reserved: UInt64 = 0
    private(set) var released: UInt64 = 0
    private(set) var outstanding: Int = 0
    private(set) var peakConcurrency = 0
    private(set) var phases: [(title: String, replayed: Bool)] = []
    private(set) var logs: [String] = []
    private(set) var budgetQueries = 0
    private(set) var scratchWrites: [String] = []

    private let concurrencyLimit: Int

    init(concurrencyLimit: Int = 8) {
        self.concurrencyLimit = concurrencyLimit
    }

    nonisolated var maxConcurrentAgents: Int { concurrencyLimit }

    /// Keyed on the exact prompt: substring matching would let a short marker
    /// shadow a longer prompt that happens to contain it.
    func reply(toPrompt prompt: String, with reply: Reply) {
        replies[prompt] = reply
    }

    func setDefaultReply(_ reply: Reply) { defaultReply = reply }

    func failReservations(with error: RhaiHostError) { reserveFailure = error }

    func reserveAgentCalls(_ count: UInt64) throws {
        if let reserveFailure { throw reserveFailure }
        reserved += count
    }

    func releaseAgentCalls(_ count: UInt64) { released += count }

    func spawnAgent(_ options: RhaiAgentOptions) async throws -> RhaiAgentResult {
        prompts.append(options.prompt)
        outstanding += 1
        peakConcurrency = max(peakConcurrency, outstanding)
        // Give sibling tasks a chance to start, so a real barrier shows up as
        // overlap and a sequential chain does not.
        for _ in 0..<10 { await Task.yield() }
        outstanding -= 1

        let reply = replies[options.prompt] ?? defaultReply
        switch reply {
        case .failure(let error):
            throw error
        case .success(let output):
            return RhaiAgentResult(
                agentID: "agent-\(prompts.count)",
                success: true,
                output: output,
                tokensUsed: 10,
                durationMS: 5
            )
        }
    }

    func phase(title: String, replayed: Bool) { phases.append((title, replayed)) }
    func log(message: String, replayed: Bool) { logs.append(message) }
    func telemetry(name: String, fields: JSONValue, replayed: Bool) {}

    func budgetState() -> RhaiBudgetState {
        budgetQueries += 1
        return RhaiBudgetState(total: 1_000, spent: 123, reserved: 100, remaining: 777)
    }

    func renderTemplate(name: String, variables: JSONValue) -> String { "rendered:\(name)" }

    func writeScratchFile(name: String, content: String) -> String {
        scratchWrites.append(name)
        return "scratch/\(name)"
    }

    func readScratchFile(name: String) -> String { "content of \(name)" }
    func gitDiffSince(commit: String) -> String { "diff since \(commit)" }
}

/// A host that fails every call of one kind, to exercise the catchable path.
actor FailingScratchHost: RhaiWorkflowHost {
    private(set) var diffAttempts = 0

    func reserveAgentCalls(_ count: UInt64) {}
    func releaseAgentCalls(_ count: UInt64) {}
    func spawnAgent(_ options: RhaiAgentOptions) -> RhaiAgentResult {
        RhaiAgentResult(agentID: "a", success: true, output: .string("one"))
    }
    func phase(title: String, replayed: Bool) {}
    func log(message: String, replayed: Bool) {}
    func telemetry(name: String, fields: JSONValue, replayed: Bool) {}
    func budgetState() -> RhaiBudgetState { RhaiBudgetState() }
    func renderTemplate(name: String, variables: JSONValue) -> String { "" }
    func writeScratchFile(name: String, content: String) -> String { "scratch/\(name)" }
    func readScratchFile(name: String) -> String { "" }
    func gitDiffSince(commit: String) throws -> String {
        diffAttempts += 1
        throw RhaiHostError.failed("boom")
    }
}

/// A host that refuses every spawn, for terminal-state tests.
actor RefusingHost: RhaiWorkflowHost {
    private let error: RhaiHostError
    private(set) var reserved: UInt64 = 0
    private(set) var released: UInt64 = 0

    init(error: RhaiHostError) { self.error = error }

    func reserveAgentCalls(_ count: UInt64) { reserved += count }
    func releaseAgentCalls(_ count: UInt64) { released += count }
    func spawnAgent(_ options: RhaiAgentOptions) throws -> RhaiAgentResult { throw error }
    func phase(title: String, replayed: Bool) {}
    func log(message: String, replayed: Bool) {}
    func telemetry(name: String, fields: JSONValue, replayed: Bool) {}
    func budgetState() -> RhaiBudgetState { RhaiBudgetState() }
    func renderTemplate(name: String, variables: JSONValue) -> String { "" }
    func writeScratchFile(name: String, content: String) -> String { "" }
    func readScratchFile(name: String) -> String { "" }
    func gitDiffSince(commit: String) -> String { "" }
}

@Suite("RhaiEngine")
struct RhaiEngineTests {
    private func temporaryJournalPath() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhai-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("journal.jsonl")
    }

    private func run(
        _ script: String,
        host: any RhaiWorkflowHost,
        journal: RhaiJournal,
        arguments: JSONValue = .object(["objective": .string("test")])
    ) async -> RhaiWorkflowOutcome {
        await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            arguments: arguments,
            journal: journal,
            host: host
        ))
    }

    private let header = #"let meta = #{ name: "t", description: "d" };"# + "\n"

    // MARK: Happy path

    @Test("a run completes with the agent's output (engine.rs:955)")
    func happyPath() async {
        let host = FakeAgentHost()
        await host.setDefaultReply(.success(output: .string("agent says hi")))
        let outcome = await run(
            header + """
            phase("Work");
            let r = agent("do it", #{ label: "worker" });
            complete(r.output);
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome == .completed(result: .string("agent says hi")))
        #expect(await host.phases.map(\.title) == ["Work"])
        #expect(await host.reserved == 1)
    }

    @Test("agent options reach the host (engine.rs:1281)")
    func agentOptionsForward() async {
        let seen = OptionsRecorder()
        let host = RecordingOptionsHost(recorder: seen)
        let outcome = await run(
            header + """
            agent("review", #{ reasoning_effort: "high", capability_mode: "read-only", phase: "Verify" });
            complete("done");
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome == .completed(result: .string("done")))
        let options = await seen.last
        #expect(options?.reasoningEffort == "high")
        #expect(options?.capabilityMode == "read-only")
        #expect(options?.phase == "Verify")
        #expect(options?.prompt == "review")
    }

    @Test("an empty agent prompt is refused before any host call")
    func emptyPromptRefused() async {
        let host = FakeAgentHost()
        let outcome = await run(
            header + #"agent("   ");"#,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        guard case .failed(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error.contains("agent prompt must not be empty"))
        #expect(await host.prompts.isEmpty)
    }

    // MARK: Sequencing vs the parallel barrier

    @Test("sequential agent() calls never overlap")
    func sequentialAgentsDoNotOverlap() async {
        let host = FakeAgentHost()
        let outcome = await run(
            header + """
            let a = agent("first");
            let b = agent("second");
            let c = agent("third");
            complete([a.output, b.output, c.output]);
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome.status == "completed")
        #expect(await host.prompts == ["first", "second", "third"])
        #expect(await host.peakConcurrency == 1)
    }

    @Test("parallel() is a barrier: siblings overlap, and the call returns only when all are done")
    func parallelIsABarrier() async {
        let host = FakeAgentHost(concurrencyLimit: 8)
        let outcome = await run(
            header + """
            let results = parallel([
                #{ prompt: "a" },
                #{ prompt: "b" },
                #{ prompt: "c" },
            ]);
            complete(results.len());
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome == .completed(result: .number(.int64(3))))
        #expect(await host.peakConcurrency == 3)
        #expect(await host.reserved == 3)
    }

    @Test("the host's concurrency cap bounds one parallel batch")
    func concurrencyCapIsHonored() async {
        let host = FakeAgentHost(concurrencyLimit: 2)
        let outcome = await run(
            header + """
            let jobs = [];
            for i in 0..6 { jobs.push(#{ prompt: "job" + i.to_string() }); }
            complete(parallel(jobs).len());
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome == .completed(result: .number(.int64(6))))
        #expect(await host.peakConcurrency <= 2)
        #expect(await host.prompts.count == 6)
    }

    @Test("parallel preserves input order and nulls soft failures (engine.rs:1706)")
    func parallelOrderAndNulls() async {
        let host = FakeAgentHost()
        await host.reply(toPrompt: "fail-b", with: .failure(.failed("boom")))
        await host.reply(toPrompt: "a", with: .success(output: .string("ok:a")))
        await host.reply(toPrompt: "c", with: .success(output: .string("ok:c")))
        let outcome = await run(
            header + """
            let results = parallel([
                #{ prompt: "a" },
                #{ prompt: "fail-b" },
                #{ prompt: "c" },
            ]);
            let summary = results.map(|r| if r == () { "null" } else { r.output });
            complete(summary);
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome == .completed(result: .array([
            .string("ok:a"), .string("null"), .string("ok:c"),
        ])))
    }

    @Test("parallel refuses an oversized fan-out before spawning anything (engine.rs:1250)")
    func parallelRejectsOversizedFanout() async {
        let host = FakeAgentHost()
        let outcome = await run(
            header + """
            let jobs = [];
            for i in 0..\(rhaiMaxParallel + 1) { jobs.push(#{ prompt: "job" + i.to_string() }); }
            parallel(jobs);
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        guard case .failed(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error.contains("parallel() accepts at most \(rhaiMaxParallel) items per call"))
        #expect(await host.prompts.isEmpty)
        #expect(await host.reserved == 0)
    }

    // MARK: Budget and caps

    @Test("a quota refusal at reservation ends the run resumably, not catchably (engine.rs:350)")
    func reservationQuotaIsTerminal() async {
        let host = FakeAgentHost()
        await host.failReservations(with: .agentCallQuotaExceeded(requested: 129, maximum: 128))
        let outcome = await run(
            header + """
            try { agent("expensive"); } catch (e) { complete("caught"); }
            complete("unreachable");
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome == .budgetExceeded(
            message: "workflow agent budget exceeded: requested 129, maximum 128"
        ))
    }

    @Test("a budget-exceeded spawn ends the run and leaves the slot released (engine.rs:1570)")
    func budgetExceededReleasesTheSlot() async throws {
        let path = try temporaryJournalPath()
        let host = RefusingHost(error: .budgetExceeded)
        let outcome = await run(
            header + """
            let r = agent("work");
            complete(r.output);
            """,
            host: host,
            journal: RhaiJournal(path: path, clock: { 1 })
        )
        #expect(outcome == .budgetExceeded(message: "workflow agent budget exceeded"))
        #expect(await host.reserved == 1)
        #expect(await host.released == 1)
        // Nothing journaled: a resume against a raised cap re-runs the spawn.
        #expect(try RhaiJournal.load(path: path).isEmpty)
    }

    @Test("a cancelled spawn releases its slot and journals nothing (engine.rs:1450)")
    func cancelledSpawnReleasesTheSlot() async throws {
        let path = try temporaryJournalPath()
        let host = RefusingHost(error: .cancelled)
        let outcome = await run(
            header + "let r = agent(\"work\"); complete(r.output);",
            host: host,
            journal: RhaiJournal(path: path, clock: { 1 })
        )
        #expect(outcome == .cancelled)
        #expect(await host.released == 1)
        #expect(try RhaiJournal.load(path: path).isEmpty)
    }

    @Test("a cancelled parallel panel releases every reserved slot (engine.rs:1515)")
    func cancelledParallelReleasesAllSlots() async throws {
        let path = try temporaryJournalPath()
        let host = RefusingHost(error: .cancelled)
        let outcome = await run(
            header + #"parallel([#{ prompt: "first" }, #{ prompt: "second" }]);"#,
            host: host,
            journal: RhaiJournal(path: path, clock: { 1 })
        )
        #expect(outcome == .cancelled)
        #expect(await host.reserved == 2)
        #expect(await host.released == 2)
        #expect(try RhaiJournal.load(path: path).isEmpty)
    }

    @Test("budget() reports the host's arithmetic to the script")
    func budgetQuery() async {
        let host = FakeAgentHost()
        let outcome = await run(
            header + """
            let b = budget();
            complete(#{ total: b.total, spent: b.spent, reserved: b.reserved, remaining: b.remaining });
            """,
            host: host,
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome == .completed(result: .object([
            // Journaling round-trips the host's UInt64s through JSON, so they
            // come back to the script as plain integers.
            "total": .number(.int64(1_000)),
            "spent": .number(.int64(123)),
            "reserved": .number(.int64(100)),
            "remaining": .number(.int64(777)),
        ])))
    }

    @Test("the result-bearing host-call ceiling is fatal and blocks the send (engine.rs:1306)")
    func hostCallCeilingIsFatal() async throws {
        let journal = RhaiJournal(clock: { 1 })
        let hash = rhaiRequestHash(kind: "budget", payload: .null)
        let recorded = JSONValue.object([
            "total": .null, "spent": .number(.int64(0)),
            "reserved": .number(.int64(0)), "remaining": .null,
        ])
        for seq in 0..<rhaiMaxHostCalls {
            try journal.record(seq: seq, kind: "budget", reqHash: hash, result: recorded)
        }
        let host = FakeAgentHost()
        let outcome = await run(
            header + """
            for i in 0..\(rhaiMaxHostCalls) { budget(); }
            try { budget(); } catch (e) { complete("caught"); }
            complete("unreachable");
            """,
            host: host,
            journal: journal
        )
        guard case .failed(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error.contains("maximum of \(rhaiMaxHostCalls) result-bearing host calls"))
        #expect(await host.budgetQueries == 0)
    }

    // MARK: Journal replay

    @Test("replay skips host calls and reproduces the first run (engine.rs:1729)")
    func replaySkipsHostCalls() async throws {
        let path = try temporaryJournalPath()
        let script = header + """
        let a = agent("first");
        let b = budget();
        complete(#{ out: a.output, spent: b.spent });
        """

        let first = await run(script, host: FakeAgentHost(), journal: RhaiJournal(path: path, clock: { 1 }))
        guard case .completed(let firstResult) = first else {
            Issue.record("expected completion, got \(first)")
            return
        }

        let replayHost = FakeAgentHost()
        let second = await run(script, host: replayHost, journal: try RhaiJournal.load(path: path))
        guard case .completed(let secondResult) = second else {
            Issue.record("expected completion, got \(second)")
            return
        }
        #expect(firstResult == secondResult)
        #expect(secondResult["spent"]?.uint64Value == 123)
        #expect(await replayHost.prompts.isEmpty)
        #expect(await replayHost.budgetQueries == 0)
    }

    @Test("an edited script diverges loudly rather than replaying the wrong entry (engine.rs:1846)")
    func divergenceFailsLoudly() async throws {
        let path = try temporaryJournalPath()
        let first = await run(
            header + #"agent("original prompt"); complete("ok");"#,
            host: FakeAgentHost(),
            journal: RhaiJournal(path: path, clock: { 1 })
        )
        #expect(first.status == "completed")

        let second = await run(
            header + #"agent("EDITED prompt"); complete("ok");"#,
            host: FakeAgentHost(),
            journal: try RhaiJournal.load(path: path)
        )
        guard case .failed(let error) = second else {
            Issue.record("expected failure, got \(second)")
            return
        }
        #expect(error.contains("replay divergence at seq 0"))
    }

    @Test("phase carries the replay flag so a resumed run can redraw history (engine.rs:1874)")
    func phaseCarriesReplayFlag() async throws {
        let path = try temporaryJournalPath()
        let script = header + """
        phase("One");
        agent("x");
        phase("Two");
        complete("ok");
        """
        _ = await run(script, host: FakeAgentHost(), journal: RhaiJournal(path: path, clock: { 1 }))

        let replayHost = FakeAgentHost()
        _ = await run(script, host: replayHost, journal: try RhaiJournal.load(path: path))
        let phases = await replayHost.phases
        #expect(phases.map(\.title) == ["One", "Two"])
        #expect(phases.map(\.replayed) == [true, false])
    }

    @Test("a catchable host failure journals a sentinel and replays the same branch (engine.rs:986)")
    func catchableFailureJournalsAndReplays() async throws {
        let path = try temporaryJournalPath()
        let script = header + """
        let d = "";
        try { d = git_diff_since("abc"); } catch (e) { d = "fallback"; }
        let r = agent("work");
        complete(r.output + ":" + d);
        """

        let host = FailingScratchHost()
        let first = await run(script, host: host, journal: RhaiJournal(path: path, clock: { 1 }))
        #expect(first == .completed(result: .string("one:fallback")))
        #expect(await host.diffAttempts == 1)

        let replayHost = FailingScratchHost()
        let second = await run(script, host: replayHost, journal: try RhaiJournal.load(path: path))
        #expect(second == .completed(result: .string("one:fallback")))
        #expect(await replayHost.diffAttempts == 0)
    }

    // MARK: Pause gates

    @Test("pause maps its kind and its aliases (engine.rs:1191)")
    func pauseMapsKind() async {
        let outcome = await run(
            header + #"pause("back_off", "too many rejections");"#,
            host: FakeAgentHost(),
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(outcome == .paused(kind: .backOff, message: "too many rejections"))

        let alias = await run(
            header + #"pause("blocked", "needs input");"#,
            host: FakeAgentHost(),
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(alias == .paused(kind: .verification, message: "needs input"))

        let unknown = await run(
            header + #"pause("sideways", "?");"#,
            host: FakeAgentHost(),
            journal: RhaiJournal(clock: { 1 })
        )
        #expect(unknown.status == "failed")
    }

    @Test("await_user pauses once, then passes on resume (engine.rs:1033)")
    func awaitUserPausesOnce() async throws {
        let path = try temporaryJournalPath()
        let script = header + """
        await_user("back_off", "needs a human");
        complete("resumed");
        """
        let first = await run(script, host: FakeAgentHost(), journal: RhaiJournal(path: path, clock: { 1 }))
        #expect(first == .paused(kind: .backOff, message: "needs a human"))

        let second = await run(script, host: FakeAgentHost(), journal: try RhaiJournal.load(path: path))
        #expect(second == .completed(result: .string("resumed")))
    }

    @Test("escalate pauses, then returns the fulfilled note on resume (engine.rs:1063)")
    func escalateReturnsFulfilledNote() async throws {
        let path = try temporaryJournalPath()
        let script = header + """
        let fix = escalate("tests fail: sandbox denies network");
        complete("note:" + fix);
        """
        let first = await run(script, host: FakeAgentHost(), journal: RhaiJournal(path: path, clock: { 1 }))
        #expect(first == .paused(kind: .verification, message: "tests fail: sandbox denies network"))

        let journal = try RhaiJournal.load(path: path, clock: { 1 })
        #expect(journal.hasPendingEscalation)
        #expect(try journal.fulfillPendingEscalation(note: "network allowed; rerun"))

        let second = await run(script, host: FakeAgentHost(), journal: journal)
        #expect(second == .completed(result: .string("note:network allowed; rerun")))

        // The note is durable: a fresh load replays it too.
        let third = await run(script, host: FakeAgentHost(), journal: try RhaiJournal.load(path: path))
        #expect(third == .completed(result: .string("note:network allowed; rerun")))
    }

    @Test("a noteless resume yields \"\" and consumes the gate (engine.rs:1110)")
    func escalateNotelessResume() async throws {
        let path = try temporaryJournalPath()
        let script = header + """
        let fix = escalate("blocked");
        if fix == "" { complete("resumed-without-note"); }
        complete("unexpected:" + fix);
        """
        let first = await run(script, host: FakeAgentHost(), journal: RhaiJournal(path: path, clock: { 1 }))
        #expect(first.status == "paused")
        #expect(try RhaiJournal.load(path: path).hasPendingEscalation)

        let second = await run(script, host: FakeAgentHost(), journal: try RhaiJournal.load(path: path, clock: { 1 }))
        #expect(second == .completed(result: .string("resumed-without-note")))

        // Nothing is pending any more, so a late note cannot answer a question
        // the script already moved past.
        let reloaded = try RhaiJournal.load(path: path, clock: { 1 })
        #expect(!reloaded.hasPendingEscalation)
        #expect(try reloaded.fulfillPendingEscalation(note: "too late") == false)
    }

    // MARK: Scratch files and templates

    @Test("scratch, template, and diff calls journal their results")
    func auxiliaryHostCalls() async throws {
        let path = try temporaryJournalPath()
        let host = FakeAgentHost()
        let outcome = await run(
            header + """
            let p = write_scratch_file("report.md", "# hi");
            let t = render_template("summary", #{ a: 1 });
            let c = read_scratch_file("report.md");
            complete(#{ path: p, template: t, content: c });
            """,
            host: host,
            journal: RhaiJournal(path: path, clock: { 1 })
        )
        #expect(outcome == .completed(result: .object([
            "path": .string("scratch/report.md"),
            "template": .string("rendered:summary"),
            "content": .string("content of report.md"),
        ])))
        #expect(await host.scratchWrites == ["report.md"])
        #expect(try RhaiJournal.load(path: path).count == 3)
    }

    // MARK: Validation

    @Test("a valid script passes dry-run validation (validate.rs:164)")
    func validationPasses() async {
        let result = await RhaiWorkflowValidator.validate(script: """
        let meta = #{ name: "t", description: "d" };
        let r = agent("work");
        complete(r.output);
        """)
        guard case .success(let report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.name == "t")
        #expect(report.outcomeOK)
        #expect(report.outcomeSummary.hasPrefix("completed:"))
    }

    @Test("a missing meta block fails validation as a meta error (validate.rs:175)")
    func validationRejectsMissingMeta() async {
        let result = await RhaiWorkflowValidator.validate(script: "let x = 1;")
        guard case .failure(.meta) = result else {
            Issue.record("expected a meta failure, got \(result)")
            return
        }
    }

    @Test("runtime misuse fails validation as a dry-run error (validate.rs:214)")
    func validationRejectsRuntimeMisuse() async {
        let result = await RhaiWorkflowValidator.validate(script: """
        let meta = #{ name: "t", description: "d" };
        not_a_host_fn();
        """)
        guard case .failure(.run(let summary)) = result else {
            Issue.record("expected a run failure, got \(result)")
            return
        }
        #expect(summary.contains("not_a_host_fn"))
    }

    @Test("a paused dry run still counts as valid (validate.rs:224)")
    func validationAcceptsPause() async {
        let result = await RhaiWorkflowValidator.validate(script: """
        let meta = #{ name: "t", description: "d" };
        pause("verification", "needs input");
        """)
        guard case .success(let report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.outcomeOK)
        #expect(report.outcomeSummary.contains("paused (verification)"))
    }

    @Test("engine limits surface as dry-run failures (validate.rs:234)")
    func validationReportsEngineLimits() async {
        let result = await RhaiWorkflowValidator.validate(script: """
        let meta = #{ name: "t", description: "d" };
        let jobs = [];
        for i in 0..\(rhaiMaxParallel + 1) { jobs.push(#{ prompt: "job" + i.to_string() }); }
        parallel(jobs);
        """)
        guard case .failure(let error) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(error.description.contains("parallel() accepts at most"))
    }

    @Test("the probe budget stops a script that outruns its agent allowance (validate.rs:247)")
    func validationReportsAgentBudget() async {
        let result = await RhaiWorkflowValidator.validate(script: """
        let meta = #{ name: "t", description: "d" };
        let jobs = [];
        for i in 0..\(rhaiDefaultAgentBudget) { jobs.push(#{ prompt: "job" + i.to_string() }); }
        parallel(jobs);
        agent("synthesize");
        """)
        guard case .failure(let error) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(error.description.contains(
            "agent budget exceeded: requested \(rhaiDefaultAgentBudget + 1), maximum \(rhaiDefaultAgentBudget)"
        ))
    }
}

// MARK: - Support

actor OptionsRecorder {
    private(set) var last: RhaiAgentOptions?
    func record(_ options: RhaiAgentOptions) { last = options }
}

actor RecordingOptionsHost: RhaiWorkflowHost {
    private let recorder: OptionsRecorder

    init(recorder: OptionsRecorder) { self.recorder = recorder }

    func reserveAgentCalls(_ count: UInt64) {}
    func releaseAgentCalls(_ count: UInt64) {}
    func spawnAgent(_ options: RhaiAgentOptions) async -> RhaiAgentResult {
        await recorder.record(options)
        return RhaiAgentResult(agentID: "a", success: true, output: .string("ok"))
    }
    func phase(title: String, replayed: Bool) {}
    func log(message: String, replayed: Bool) {}
    func telemetry(name: String, fields: JSONValue, replayed: Bool) {}
    func budgetState() -> RhaiBudgetState { RhaiBudgetState() }
    func renderTemplate(name: String, variables: JSONValue) -> String { "" }
    func writeScratchFile(name: String, content: String) -> String { "" }
    func readScratchFile(name: String) -> String { "" }
    func gitDiffSince(commit: String) -> String { "" }
}
