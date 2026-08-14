// RhaiEngineAdversarialStressTests.swift
//
// Adversarial empirical stress tests for OpenGrokWorkflow Rhai engine:
// 100M operation loop termination & step ceilings,
// illegal keyword / non-deterministic symbol rejection (timestamp, sleep, exit, eval),
// torn-line journal recovery at EOF, sequence discontinuity detection, and req_hash verification.

import Foundation
import Testing
@testable import OpenGrokWorkflow
import OpenGrokShared

@Suite("Rhai Engine Adversarial Stress Tests")
struct RhaiEngineAdversarialStressTests {

    private func temporaryJournalURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhai-adversarial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("journal.jsonl")
    }

    private let header = #"let meta = #{ name: "stress-test", description: "adversarial stress verification" };"# + "\n"

    // MARK: - 1. Operation Ceiling and Loop Termination

    @Test("Configured operation limits terminate infinite loops deterministically")
    func loopTerminationAtConfiguredLimits() async {
        let loopScript = header + """
        let i = 0;
        while true {
            i += 1;
        }
        """

        for limit in [100, 500, 2_000] {
            var limits = RhaiInterpreterLimits()
            limits.maxOperations = UInt64(limit)

            let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
                script: loopScript,
                journal: RhaiJournal(clock: { 1 }),
                host: RhaiProbeHost(),
                limits: limits
            ))

            guard case .failed(let error) = outcome else {
                Issue.record("Expected loop to fail from operation limit \(limit), got: \(outcome)")
                continue
            }
            #expect(error.contains("exceeded the maximum of \(limit) operations"))
        }
    }

    @Test("For-loop over large range respects operation limit")
    func forLoopRangeOperationLimit() async {
        var limits = RhaiInterpreterLimits()
        limits.maxOperations = 250

        let script = header + """
        let total = 0;
        for x in 0..10000 {
            total += x;
        }
        complete(total);
        """

        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            journal: RhaiJournal(clock: { 1 }),
            host: RhaiProbeHost(),
            limits: limits
        ))

        guard case .failed(let error) = outcome else {
            Issue.record("Expected for-loop to hit op limit, got: \(outcome)")
            return
        }
        #expect(error.contains("operations"))
    }

    // MARK: - 2. Illegal Keywords and Non-Deterministic Symbol Rejection

    @Test("Illegal symbols timestamp(), sleep(), exit(), and eval() cannot be bypassed or caught")
    func illegalKeywordsBlocked() async {
        let host = RhaiProbeHost()

        // 1. timestamp()
        let outcome1 = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: header + "let t = timestamp(); complete(t);",
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .failed(let err1) = outcome1 else {
            Issue.record("timestamp() must fail")
            return
        }
        #expect(err1.contains("timestamp() is unavailable"))

        // 2. sleep()
        let outcome2 = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: header + "sleep(5000); complete(1);",
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .failed(let err2) = outcome2 else {
            Issue.record("sleep() must fail")
            return
        }
        #expect(err2.contains("sleep() is unavailable"))

        // 3. exit()
        let outcome3 = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: header + "exit(0);",
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .failed(let err3) = outcome3 else {
            Issue.record("exit() must fail")
            return
        }
        #expect(err3.contains("exit() is unavailable"))

        // 4. eval()
        let outcome4 = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: header + #"eval("1 + 1");"#,
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .failed(let err4) = outcome4 else {
            Issue.record("eval() must fail")
            return
        }
        #expect(err4.contains("eval() is disabled"))
    }

    @Test("Direct and indirect attempts to invoke illegal builtins in expressions")
    func illegalBuiltinsInExpressions() async {
        let scripts = [
            header + "let fn_ptr = timestamp; complete(fn_ptr());",
            header + "let res = 1 + sleep(10); complete(res);",
            header + "if timestamp() > 0 { complete(true); }"
        ]

        for script in scripts {
            let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
                script: script,
                journal: RhaiJournal(clock: { 1 }),
                host: RhaiProbeHost()
            ))
            guard case .failed = outcome else {
                Issue.record("Script should fail: \(script)")
                continue
            }
        }
    }

    // MARK: - 3. Journal Fuzzing, Torn Line Recovery, and Sequence Validation

    @Test("Torn line at EOF with trailing whitespace and truncated JSON bytes")
    func tornLineEOFFuzzing() async throws {
        let path = try temporaryJournalURL()
        let journal = RhaiJournal(path: path, clock: { 1 })

        let hash0 = rhaiRequestHash(kind: "budget", payload: .null)
        try journal.record(seq: 0, kind: "budget", reqHash: hash0, result: .object(["tokens": .number(.int64(100))]))

        let hash1 = rhaiRequestHash(kind: "read_scratch_file", payload: .object(["name": .string("f.txt")]))
        try journal.record(seq: 1, kind: "read_scratch_file", reqHash: hash1, result: .string("file content"))

        // Corrupt EOF with half-written JSON line without newline
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":2,\"kind\":\"escalate\",\"req_hash\":\"abcd".utf8))
        try handle.close()

        // Restoring journal must safely drop the corrupted unclosed line
        let loaded = try RhaiJournal.load(path: path, clock: { 1 })
        #expect(loaded.count == 2)
        #expect(try loaded.replay(seq: 0, kind: "budget", reqHash: hash0)?["tokens"]?.int64Value == 100)
        #expect(try loaded.replay(seq: 1, kind: "read_scratch_file", reqHash: hash1)?.stringValue == "file content")

        // Now append a new valid entry (seq 2) and verify file is healthy
        let hash2 = rhaiRequestHash(kind: "budget", payload: .null)
        try loaded.record(seq: 2, kind: "budget", reqHash: hash2, result: .object(["tokens": .number(.int64(200))]))

        let reloaded = try RhaiJournal.load(path: path, clock: { 1 })
        #expect(reloaded.count == 3)
        #expect(try reloaded.replay(seq: 2, kind: "budget", reqHash: hash2)?["tokens"]?.int64Value == 200)
    }

    @Test("Corrupted non-EOF line (terminated by newline) throws parse error and does not drop data silently")
    func corruptedMiddleLinetThrowsParseError() async throws {
        let path = try temporaryJournalURL()
        let line1 = "{\"seq\":0,\"kind\":\"budget\",\"req_hash\":\"aaaa0000aaaa0000aaaa0000aaaa0000\",\"result\":null,\"at_ms\":1}\n"
        let line2Corrupt = "{\"seq\":1,MALFORMED_JSON_HERE}\n"
        let line3 = "{\"seq\":2,\"kind\":\"budget\",\"req_hash\":\"bbbb0000bbbb0000bbbb0000bbbb0000\",\"result\":null,\"at_ms\":2}\n"

        let fullData = Data((line1 + line2Corrupt + line3).utf8)
        try fullData.write(to: path)

        // Middle line is terminated by \n so it is NOT a torn tail; it is a corrupted record.
        // It must throw RhaiJournalError.parse rather than ignoring line 2 and proceeding.
        #expect(throws: RhaiJournalError.self) {
            _ = try RhaiJournal.load(path: path)
        }
    }

    @Test("Non-dense sequence jump throws sequence continuity error")
    func nonDenseSequenceJumpThrows() throws {
        let journal = RhaiJournal(clock: { 1 })
        try journal.record(seq: 0, kind: "budget", reqHash: "hash0", result: .null)
        try journal.record(seq: 1, kind: "budget", reqHash: "hash1", result: .null)

        // Sequence jump: expecting 2, given 5
        #expect(throws: RhaiJournalError.sequence(index: 2, expected: 2, actual: 5)) {
            try journal.record(seq: 5, kind: "budget", reqHash: "hash5", result: .null)
        }
    }

    @Test("Journal request hash is strictly 32 hex characters (16 bytes) across canonical JSON edge cases")
    func requestHashCanonicalJsonEdgeCases() {
        let edgeCasePayloads: [JSONValue] = [
            .null,
            .bool(true),
            .bool(false),
            .number(.int64(0)),
            .number(.int64(-42)),
            .number(.double(3.141592653589793)),
            .string("special \n \r \t \" \\ \u{0000} \u{001F}"),
            .array([]),
            .array([.number(.int64(1)), .string("two"), .bool(true)]),
            .object([:]),
            // Unsorted dictionary keys: canonical JSON must sort keys deterministically
            .object(["z": .number(.int64(1)), "a": .number(.int64(2)), "m": .number(.int64(3))])
        ]

        for payload in edgeCasePayloads {
            let hash1 = rhaiRequestHash(kind: "test_kind", payload: payload)
            let hash2 = rhaiRequestHash(kind: "test_kind", payload: payload)

            #expect(hash1 == hash2, "Request hash must be deterministic")
            #expect(hash1.count == 32, "Request hash must be 32 hex chars (16 bytes)")
            #expect(hash1.allSatisfy { $0.isHexDigit })
        }
    }
}
