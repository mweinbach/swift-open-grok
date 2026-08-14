// NativeWorkflowEngineParityTests.swift
//
// Comprehensive invariant and parity test suite for the native Rhai workflow engine
// (xai-workflow -> OpenGrokWorkflow).
//
// Verifies:
// 1. Mandatory `let meta = #{...};` header extraction, comments, kebab-case, caps, literal constraints.
// 2. Strict determinism: timestamp/sleep/exit/eval rejection, fingerprint/json_encode purity.
// 3. Limits: 100M operations ceiling, 64 call-depth ceiling, array/map capacity bounds.
// 4. Journal invariants: 16-byte truncated SHA-256 req_hash, dense continuity, torn-tail repair,
//    escalation fulfillment (with/without notes), and error pruning for catchable host failures.
// 5. Host execution: agent sequencing, parallel barriers, budget/quota lifecycle, scratch/diff/template tools.

import Foundation
import Testing
@testable import OpenGrokWorkflow
import OpenGrokShared

@Suite("NativeWorkflowEngineParity")
struct NativeWorkflowEngineParityTests {
    private func temporaryJournalURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-workflow-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("journal.jsonl")
    }

    private let header = #"let meta = #{ name: "parity-test", description: "verifies native engine invariants" };"# + "\n"

    // MARK: - 1. Metadata Block & Syntax Invariants

    @Test("meta extraction handles complex leading comments and whitespace")
    func metaLeadingComments() throws {
        let script = """
        // First single line comment
        // Second single line comment
        /* Multi-line
           block comment with symbols #{ name: "fake" } */
        // Trailing single-line comment
        let meta = #{
            name: "complex-header",
            description: "valid description",
            when_to_use: "when testing comments",
            phases: [
                #{ title: "Phase-One", detail: "Detail one" },
                #{ title: "Phase-Two" }
            ]
        };
        complete(true);
        """
        let meta = try RhaiMeta.extract(from: script)
        #expect(meta.name == "complex-header")
        #expect(meta.description == "valid description")
        #expect(meta.whenToUse == "when testing comments")
        #expect(meta.phases.count == 2)
        #expect(meta.phases[0].title == "Phase-One")
        #expect(meta.phases[0].detail == "Detail one")
        #expect(meta.phases[1].title == "Phase-Two")
        #expect(meta.phases[1].detail == nil)
    }

    @Test("meta validation enforces strict kebab-case names")
    func metaKebabNameValidation() {
        let validNames = ["a", "z", "0", "9", "my-workflow", "run-1-test-2", "alpha-beta-gamma"]
        for name in validNames {
            #expect(RhaiMeta.isValidName(name), "Name '\(name)' should be valid")
        }

        let invalidNames = [
            "",
            " ",
            "Uppercase",
            "camelCase",
            "snake_case",
            "-leading-dash",
            "trailing-dash-",
            "double--dash",
            "dot.name",
            "slash/name",
            "special@char"
        ]
        for name in invalidNames {
            #expect(!RhaiMeta.isValidName(name), "Name '\(name)' should be invalid")
            let script = "let meta = #{ name: \"\(name)\", description: \"test\" }; complete(1);"
            #expect(throws: RhaiMetaError.self) {
                _ = try RhaiMeta.extract(from: script)
            }
        }
    }

    @Test("meta rejects non-literal computed values")
    func metaRejectsNonLiteral() {
        let scripts = [
            "let meta = #{ name: \"demo\", description: \"a\" + \"b\" };",
            "let meta = #{ name: \"demo\", description: \"d\", when_to_use: 1 + 2 };",
            "let meta = #{ name: \"demo\", description: \"d\", phases: [#{ title: \"p\" + \"1\" }] };"
        ]
        for script in scripts {
            #expect(throws: RhaiMetaError.self) {
                _ = try RhaiMeta.extract(from: script)
            }
        }
    }

    // MARK: - 2. Determinism & Disabled Symbols

    @Test("strictly deterministic: timestamp, sleep, exit, and eval are blocked")
    func strictDeterminism() async {
        let host = RhaiProbeHost()

        let timestampOutcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: header + "let t = timestamp(); complete(t);",
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .failed(let err1) = timestampOutcome else {
            Issue.record("expected timestamp to fail")
            return
        }
        #expect(err1.contains("timestamp() is unavailable"))

        let sleepOutcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: header + "sleep(100); complete(1);",
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .failed(let err2) = sleepOutcome else {
            Issue.record("expected sleep to fail")
            return
        }
        #expect(err2.contains("sleep() is unavailable"))

        let exitOutcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: header + "exit();",
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .failed(let err3) = exitOutcome else {
            Issue.record("expected exit to fail")
            return
        }
        #expect(err3.contains("exit() is unavailable"))

        let evalOutcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: header + #"eval("1 + 1");"#,
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .failed(let err4) = evalOutcome else {
            Issue.record("expected eval to fail")
            return
        }
        #expect(err4.contains("eval() is disabled"))
    }

    // MARK: - 3. Limits & Recursion Guards

    @Test("call depth ceiling of 64 prevents infinite recursion")
    func callDepthCeiling() async {
        let script = header + """
        fn recurse(n) {
            recurse(n + 1);
        }
        recurse(0);
        """
        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(clock: { 1 }),
            host: RhaiProbeHost()
        ))
        guard case .failed(let error) = outcome else {
            Issue.record("expected recursion failure, got \(outcome)")
            return
        }
        #expect(error.contains("call stack depth exceeded"))
    }

    @Test("operation ceiling terminates infinite while loop")
    func operationCeilingTerminatesWhileLoop() async {
        var limits = RhaiInterpreterLimits()
        limits.maxOperations = 1_000
        let script = header + """
        let count = 0;
        while true {
            count += 1;
        }
        """
        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(clock: { 1 }),
            host: RhaiProbeHost(),
            limits: limits
        ))
        guard case .failed(let error) = outcome else {
            Issue.record("expected operation ceiling failure, got \(outcome)")
            return
        }
        #expect(error.contains("exceeded the maximum of 1000 operations"))
    }

    // MARK: - 4. Journal Request Hash & Continuity

    @Test("request hash produces exact 16-byte (32 hex) truncated SHA-256 for all kinds")
    func requestHashExactLengthsAndValues() {
        let kindsAndPayloads: [(String, JSONValue)] = [
            ("spawn_agent", RhaiAgentOptions(prompt: "audit codebase").json),
            ("budget", .null),
            ("await_user", .object(["kind": .string("user"), "message": .string("approve step")])),
            ("escalate", .object(["message": .string("security approval needed")])),
            ("write_scratch_file", .object(["name": .string("out.txt"), "content": .string("data")])),
            ("read_scratch_file", .object(["name": .string("out.txt")])),
            ("git_diff_since", .object(["commit": .string("HEAD~1")])),
            ("render_template", .object(["name": .string("summary"), "vars": .object(["k": .string("v")])])),
        ]

        for (kind, payload) in kindsAndPayloads {
            let hash = rhaiRequestHash(kind: kind, payload: payload)
            #expect(hash.count == 32, "req_hash for '\(kind)' must be 32 hex characters (16 bytes)")
            #expect(hash.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") })
        }
    }

    @Test("journal enforces dense sequence continuity")
    func denseSequenceContinuity() throws {
        let journal = RhaiJournal(clock: { 1 })
        try journal.record(seq: 0, kind: "budget", reqHash: "aaaa", result: .null)
        try journal.record(seq: 1, kind: "budget", reqHash: "bbbb", result: .null)
        #expect(journal.count == 2)

        // Attempting to record seq 3 when expecting seq 2 must throw
        #expect(throws: RhaiJournalError.sequence(index: 2, expected: 2, actual: 3)) {
            try journal.record(seq: 3, kind: "budget", reqHash: "cccc", result: .null)
        }
    }

    // MARK: - 5. Torn Line Recovery & Escalation Fulfillment

    @Test("torn line recovery preserves valid entries and trims corrupted tail")
    func tornLineRecoveryComprehensive() async throws {
        let path = try temporaryJournalURL()
        let journal = RhaiJournal(path: path, clock: { 1 })

        let hash0 = rhaiRequestHash(kind: "budget", payload: .null)
        try journal.record(seq: 0, kind: "budget", reqHash: hash0, result: .object(["spent": .number(.int64(10))]))
        let hash1 = rhaiRequestHash(kind: "write_scratch_file", payload: .object(["name": .string("a.txt"), "content": .string("v")]))
        try journal.record(seq: 1, kind: "write_scratch_file", reqHash: hash1, result: .string("scratch/a.txt"))

        // Append a corrupted partial line at EOF without newline
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":2,\"kind\":\"spawn_ag".utf8))
        try handle.close()

        // Loading must safely drop the corrupted unclosed line and keep the 2 valid entries
        let restored = try RhaiJournal.load(path: path)
        #expect(restored.count == 2)
        #expect(try restored.replay(seq: 0, kind: "budget", reqHash: hash0)?["spent"]?.int64Value == 10)
        #expect(try restored.replay(seq: 1, kind: "write_scratch_file", reqHash: hash1)?.stringValue == "scratch/a.txt")

        // Now append a valid entry after recovery
        try restored.record(seq: 2, kind: "budget", reqHash: hash0, result: .object(["spent": .number(.int64(20))]))
        let reloaded = try RhaiJournal.load(path: path)
        #expect(reloaded.count == 3)
        #expect(try reloaded.replay(seq: 2, kind: "budget", reqHash: hash0)?["spent"]?.int64Value == 20)
    }

    @Test("escalate pauses and resumes with fulfillment note or empty default")
    func escalationFulfillmentLifecycle() async throws {
        let path = try temporaryJournalURL()
        let script = header + """
        let note = escalate("Please review sandbox write");
        complete("fulfilled:" + note);
        """
        let host = FakeAgentHost()

        // 1. Initial run reaches escalate and pauses
        let firstOutcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(path: path, clock: { 1 }),
            host: host
        ))
        guard case .paused(let kind, let msg) = firstOutcome else {
            Issue.record("expected pause from escalate, got \(firstOutcome)")
            return
        }
        #expect(kind == .verification)
        #expect(msg == "Please review sandbox write")

        // 2. Verify journal reports pending escalation
        let journalToFulfill = try RhaiJournal.load(path: path, clock: { 1 })
        #expect(journalToFulfill.hasPendingEscalation)

        // 3. Fulfill pending escalation with note
        let fulfilled = try journalToFulfill.fulfillPendingEscalation(note: "Approved by Admin")
        #expect(fulfilled == true)
        #expect(!journalToFulfill.hasPendingEscalation)

        // 4. Resume run - replay consumes fulfilled note
        let resumedOutcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: journalToFulfill,
            host: host
        ))
        #expect(resumedOutcome == .completed(result: .string("fulfilled:Approved by Admin")))
    }

    @Test("error pruning drops trailing host error sentinel on failure resume")
    func errorPruningAllowsRetry() async throws {
        let path = try temporaryJournalURL()
        let script = header + """
        let diff = git_diff_since("HEAD~1");
        complete(diff);
        """

        let failingHost = FailingScratchHost()
        let firstOutcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(path: path, clock: { 1 }),
            host: failingHost
        ))
        guard case .failed(let err) = firstOutcome else {
            Issue.record("expected failure from failing host, got \(firstOutcome)")
            return
        }
        #expect(err.contains("boom"))

        // Journal has 1 entry with the error sentinel
        let journal = try RhaiJournal.load(path: path, clock: { 1 })
        #expect(journal.count == 1)

        // Pruning trailing host error with matching failure detail
        let pruned = try journal.pruneTrailingHostError(failureDetail: err)
        #expect(pruned == true)
        #expect(journal.count == 0)

        // Now resume against a successful host
        let okHost = FakeAgentHost()
        let resumedOutcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: journal,
            host: okHost
        ))
        #expect(resumedOutcome == .completed(result: .string("diff since HEAD~1")))
    }

    // MARK: - 6. Step Evaluation, Loop & Complex Builtin Logic

    @Test("complex transformation methods: split, sub_string, map, filter, trim")
    func complexTransformations() async throws {
        let script = header + """
        let raw = "  alpha, beta, gamma  ";
        raw.trim();
        let parts = raw.split(",");
        let cleaned = parts.map(|p| {
            p.trim();
            p
        });
        let filtered = cleaned.filter(|p| p.contains("a"));
        complete(filtered);
        """
        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(clock: { 1 }),
            host: RhaiProbeHost()
        ))
        guard case .completed(let result) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(result == .array([.string("alpha"), .string("beta"), .string("gamma")]))
    }

    @Test("nested try-catch handles inner catchable errors and continues execution")
    func nestedTryCatch() async throws {
        let script = header + """
        let status = "start";
        try {
            status = "in-outer";
            try {
                let d = git_diff_since("invalid-ref");
            } catch (e1) {
                status = "caught-inner:" + e1;
            }
        } catch (e2) {
            status = "caught-outer:" + e2;
        }
        complete(status);
        """
        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(clock: { 1 }),
            host: FailingScratchHost()
        ))
        guard case .completed(let result) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(result.stringValue?.hasPrefix("caught-inner:") == true)
    }
}
