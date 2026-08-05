import Foundation
import Testing
@testable import OpenGrokWorkflow
import OpenGrokShared

/// Journal-format tests for the Rhai workflow engine port.
///
/// The golden hashes below were derived independently of this code, by hashing
/// the exact bytes the Rust engine hashes (`kind || 0x00 || canonical_json`)
/// with a third-party SHA-256, so they check the port rather than confirming
/// whatever it happens to produce. Provenance for each rule is cited by
/// file:line into crates/codegen/xai-workflow.
@Suite("RhaiJournal")
struct RhaiJournalTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhai-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Canonical JSON

    @Test("canonical JSON sorts keys recursively and compacts whitespace (journal.rs:377)")
    func canonicalJSONSortsKeys() {
        let value = JSONValue.object([
            "b": .number(.int64(2)),
            "a": .object(["z": .bool(true), "y": .null]),
            "c": .array([.string("x"), .number(.int64(1))]),
        ])
        #expect(RhaiCanonicalJSON.string(value) == #"{"a":{"y":null,"z":true},"b":2,"c":["x",1]}"#)
    }

    @Test("canonical JSON escapes the way serde_json does")
    func canonicalJSONEscapes() {
        #expect(RhaiCanonicalJSON.string(.string("</tag>\nquoted \"x\"\t\\"))
            == #""</tag>\nquoted \"x\"\t\\""#)
        // serde escapes other control characters as \u00XX and leaves
        // non-ASCII alone.
        #expect(RhaiCanonicalJSON.string(.string("\u{01}é")) == "\"\\u0001é\"")
    }

    @Test("f64 whole numbers keep serde's trailing .0")
    func canonicalJSONFloats() {
        #expect(RhaiCanonicalJSON.string(.number(.double(1))) == "1.0")
        #expect(RhaiCanonicalJSON.string(.number(.double(0.5))) == "0.5")
        #expect(RhaiCanonicalJSON.string(.number(.int64(1))) == "1")
    }

    // MARK: Request hash

    @Test("request hash is the first 16 bytes of sha256(kind || 0x00 || canonical json)")
    func requestHashMatchesGoldens() {
        // journal.rs:396-407. Truncation to 16 bytes is load-bearing: a full
        // 64-character digest would never match a Rust-written req_hash.
        let options = RhaiAgentOptions(prompt: "hi")
        #expect(rhaiRequestHash(kind: "spawn_agent", payload: options.json)
            == "c07f51ad0e4c7f689ae9d5c8b38ff213")

        var withPhase = options
        withPhase.phase = "Understand"
        #expect(rhaiRequestHash(kind: "spawn_agent", payload: withPhase.json)
            == "cb087f225c6ef62ecc76aee6c2ba25aa")

        #expect(rhaiRequestHash(kind: "budget", payload: .null)
            == "5e0b67f46b94cfb8d2209372790b8d8e")
        #expect(rhaiRequestHash(kind: "fingerprint", payload: .string("abc"))
            == "ec7fe10b83b9c6454d1166fe7ea063f5")
        #expect(rhaiRequestHash(kind: rhaiEscalateKind, payload: .object(["message": .string("stuck")]))
            == "c0ecd3abf5f4b9c8a6019dc0f5751e89")
        #expect(rhaiRequestHash(kind: "git_diff_since", payload: .object(["commit": .string("abc")]))
            == "bafca59f70e32b4148fa8b07d690bac2")
        #expect(rhaiRequestHash(kind: "await_user", payload: .object([
            "kind": .string("back_off"),
            "message": .string("needs a human"),
        ])) == "c525b50cde031fc74efbfd640de4afb7")
        #expect(rhaiRequestHash(kind: "spawn_agent", payload: options.json).count == 32)
    }

    @Test("map key order does not affect the hash (journal.rs:770)")
    func requestHashIsOrderStable() {
        let first = rhaiRequestHash(kind: "k", payload: .object(["b": .number(.int64(2)), "a": .number(.int64(1))]))
        let second = rhaiRequestHash(kind: "k", payload: .object(["a": .number(.int64(1)), "b": .number(.int64(2))]))
        #expect(first == second)
        #expect(first == "64f0ec9bb6b91723db6c2162cd6e5989")
    }

    @Test("agent options serialize every field, nulls included (host.rs:5)")
    func agentOptionsSerializeNulls() {
        let json = RhaiAgentOptions(prompt: "hi").json
        #expect(RhaiCanonicalJSON.string(json) == #"{"agent_type":null,"capability_mode":null,"fork_context":false,"isolation_worktree":false,"label":null,"max_output_tokens":null,"model":null,"output_schema":null,"phase":null,"prompt":"hi","reasoning_effort":null,"resume_from":null}"#)
    }

    // MARK: Round-trip against a Rust-shaped journal

    @Test("a Rust-written journal line loads and replays losslessly")
    func rustWrittenLineRoundTrips() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("journal.jsonl")
        // The exact line shape Rust's serde emits for JournalEntry
        // (journal.rs:14): field order seq, kind, req_hash, result, at_ms.
        let hash = rhaiRequestHash(kind: "spawn_agent", payload: RhaiAgentOptions(prompt: "hi").json)
        let line = #"{"seq":0,"kind":"spawn_agent","req_hash":"\#(hash)","result":{"agent_id":"child-1","success":true,"output":"hello","cancelled":false,"tokens_used":10,"duration_ms":5},"at_ms":1730000000000}"# + "\n"
        try line.write(to: path, atomically: true, encoding: .utf8)

        let journal = try RhaiJournal.load(path: path)
        #expect(journal.count == 1)
        let replayed = try journal.replay(seq: 0, kind: "spawn_agent", reqHash: hash)
        #expect(replayed?["output"]?.stringValue == "hello")
        #expect(replayed?["tokens_used"]?.uint64Value == 10)
        #expect(journal.agentReservationCount == 1)

        // Appending after a Rust-written prefix keeps the file dense.
        try journal.record(seq: 1, kind: "budget", reqHash: "aaaa", result: .object(["spent": .number(.int64(3))]))
        let reloaded = try RhaiJournal.load(path: path)
        #expect(reloaded.count == 2)
        #expect(try reloaded.replay(seq: 1, kind: "budget", reqHash: "aaaa")?["spent"]?.int64Value == 3)
    }

    @Test("a Swift-written line is byte-identical to the Rust field order")
    func writtenLineMatchesRustShape() {
        let entry = RhaiJournalEntry(
            seq: 2,
            kind: "log",
            reqHash: "abcd",
            result: .string("hi"),
            atMS: 7
        )
        #expect(entry.lineText == #"{"seq":2,"kind":"log","req_hash":"abcd","result":"hi","at_ms":7}"# + "\n")
    }

    // MARK: Replay and divergence

    @Test("record then replay round-trips; a later sequence is a miss (journal.rs:414)")
    func recordAndReplayRoundTrip() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("journal.jsonl")
        let journal = RhaiJournal(path: path, clock: { 1 })
        let hash = rhaiRequestHash(kind: "spawn_agent", payload: .object(["prompt": .string("hi")]))
        try journal.record(seq: 0, kind: "spawn_agent", reqHash: hash, result: .object(["ok": .bool(true)]))

        let loaded = try RhaiJournal.load(path: path)
        #expect(loaded.count == 1)
        #expect(try loaded.replay(seq: 0, kind: "spawn_agent", reqHash: hash)?["ok"]?.boolValue == true)
        #expect(try loaded.replay(seq: 1, kind: "spawn_agent", reqHash: hash) == nil)
    }

    @Test("a different kind or hash at a recorded sequence is divergence (journal.rs:436)")
    func divergenceOnMismatch() throws {
        let journal = RhaiJournal(clock: { 1 })
        try journal.record(seq: 0, kind: "spawn_agent", reqHash: "aaaa", result: .number(.int64(1)))
        #expect(throws: RhaiJournalError.divergence(seq: 0, kind: "spawn_agent")) {
            _ = try journal.replay(seq: 0, kind: "spawn_agent", reqHash: "bbbb")
        }
        #expect(throws: RhaiJournalError.divergence(seq: 0, kind: "budget")) {
            _ = try journal.replay(seq: 0, kind: "budget", reqHash: "aaaa")
        }
    }

    @Test("load and record both require dense sequences (journal.rs:584)")
    func densityIsEnforced() throws {
        let journal = RhaiJournal(clock: { 1 })
        #expect(throws: RhaiJournalError.sequence(index: 0, expected: 0, actual: 1)) {
            try journal.record(seq: 1, kind: "log", reqHash: "x", result: .null)
        }

        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("journal.jsonl")
        try #"{"seq":1,"kind":"log","req_hash":"x","result":null,"at_ms":1}"# .appending("\n")
            .write(to: path, atomically: true, encoding: .utf8)
        #expect(throws: RhaiJournalError.sequence(index: 0, expected: 0, actual: 1)) {
            _ = try RhaiJournal.load(path: path)
        }
    }

    // MARK: Torn tails and restore safety

    @Test("a torn tail is truncated before the next append (journal.rs:452)")
    func tornTailIsTruncated() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("journal.jsonl")
        let first = #"{"seq":0,"kind":"log","req_hash":"x","result":null,"at_ms":1}"# + "\n"
        try (first + #"{"seq":1,"kind"#).write(to: path, atomically: true, encoding: .utf8)

        let journal = try RhaiJournal.load(path: path, clock: { 1 })
        #expect(journal.count == 1)
        #expect(try String(contentsOf: path, encoding: .utf8) == first)

        try journal.record(seq: 1, kind: "log", reqHash: "y", result: .null)
        #expect(try RhaiJournal.load(path: path).count == 2)
    }

    @Test("a valid but unterminated tail is kept and newline-terminated (journal.rs:469)")
    func unterminatedTailIsKept() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("journal.jsonl")
        let line = #"{"seq":0,"kind":"log","req_hash":"x","result":null,"at_ms":1}"#
        try line.write(to: path, atomically: true, encoding: .utf8)

        #expect(try RhaiJournal.load(path: path).count == 1)
        #expect(try String(contentsOf: path, encoding: .utf8) == line + "\n")
    }

    @Test("a complete malformed line is a hard parse error, not a torn tail (journal.rs:573)")
    func malformedLineIsFatal() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("journal.jsonl")
        try "not-json\n".write(to: path, atomically: true, encoding: .utf8)
        #expect(throws: RhaiJournalError.self) {
            _ = try RhaiJournal.load(path: path)
        }
    }

    @Test("load refuses a symlinked journal (journal.rs:481)")
    func loadRefusesSymlink() throws {
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("target.jsonl")
        let linked = directory.appendingPathComponent("journal.jsonl")
        try "".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        #expect(throws: RhaiJournalError.self) {
            _ = try RhaiJournal.load(path: linked)
        }
    }

    @Test("a missing journal loads as empty rather than failing")
    func missingJournalIsEmpty() throws {
        let directory = try temporaryDirectory()
        let journal = try RhaiJournal.load(path: directory.appendingPathComponent("absent.jsonl"))
        #expect(journal.isEmpty)
    }

    @Test("record refuses to grow past the restore cap (journal.rs:508)")
    func recordRefusesToExceedCap() throws {
        let journal = RhaiJournal(clock: { 1 })
        let oversized = String(repeating: "x", count: Int(rhaiMaxJournalBytes) + 1)
        #expect(throws: RhaiJournalError.full(seq: 0, limit: rhaiMaxJournalBytes)) {
            try journal.record(seq: 0, kind: "spawn_agent", reqHash: "a", result: .string(oversized))
        }
        // The refusal left nothing behind, so the same sequence is still free.
        try journal.record(seq: 0, kind: "spawn_agent", reqHash: "a", result: .object(["ok": .bool(true)]))
        #expect(journal.count == 1)
    }

    // MARK: Escalation gates

    @Test("only a trailing null escalate is fulfillable (journal.rs:523)")
    func fulfillPendingEscalation() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("journal.jsonl")
        let journal = RhaiJournal(path: path, clock: { 1 })

        #expect(try journal.fulfillPendingEscalation(note: "note") == false)

        let agentHash = rhaiRequestHash(kind: "spawn_agent", payload: .object(["prompt": .string("hi")]))
        try journal.record(seq: 0, kind: "spawn_agent", reqHash: agentHash, result: .object(["ok": .bool(true)]))
        #expect(try journal.fulfillPendingEscalation(note: "note") == false)

        let escalateHash = rhaiRequestHash(kind: rhaiEscalateKind, payload: .object(["message": .string("stuck")]))
        try journal.record(seq: 1, kind: rhaiEscalateKind, reqHash: escalateHash, result: .null)
        #expect(journal.hasPendingEscalation)
        #expect(try journal.fulfillPendingEscalation(note: "fixed it") == true)
        #expect(try journal.replay(seq: 1, kind: rhaiEscalateKind, reqHash: escalateHash)?.stringValue == "fixed it")
        #expect(try journal.fulfillPendingEscalation(note: "again") == false)

        let reloaded = try RhaiJournal.load(path: path)
        #expect(reloaded.count == 2)
        #expect(try reloaded.replay(seq: 1, kind: rhaiEscalateKind, reqHash: escalateHash)?.stringValue == "fixed it")
    }

    // MARK: Pruning a trailing host error

    @Test("prune removes a trailing host-error sentinel and truncates the file (journal.rs:625)")
    func pruneRemovesTrailingSentinel() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("journal.jsonl")
        let journal = RhaiJournal(path: path, clock: { 1 })
        try journal.record(seq: 0, kind: "spawn_agent", reqHash: "aaaa", result: .object(["ok": .bool(true)]))
        try journal.record(
            seq: 1,
            kind: "write_scratch_file",
            reqHash: "bbbb",
            result: rhaiHostErrorSentinel("scratch byte quota exceeded")
        )
        let before = try String(contentsOf: path, encoding: .utf8)

        let loaded = try RhaiJournal.load(path: path, clock: { 1 })
        #expect(try loaded.pruneTrailingHostError(
            failureDetail: "Runtime error: scratch byte quota exceeded"
        ) == true)
        #expect(loaded.count == 1)

        let after = try String(contentsOf: path, encoding: .utf8)
        #expect(after.split(separator: "\n").count == 1)
        #expect(!after.contains(rhaiHostErrorKey))
        #expect(before.hasPrefix(after))

        try loaded.record(seq: 1, kind: "write_scratch_file", reqHash: "bbbb", result: .string("ok"))
        #expect(try RhaiJournal.load(path: path).count == 2)
    }

    @Test("prune is a no-op when the sentinel was caught and the run died elsewhere (journal.rs:736)")
    func pruneIsNoOpForCaughtSentinel() throws {
        let journal = RhaiJournal(clock: { 1 })
        try journal.record(
            seq: 0,
            kind: "read_scratch_file",
            reqHash: "aaaa",
            result: rhaiHostErrorSentinel("scratch file not found: data.txt")
        )
        #expect(try journal.pruneTrailingHostError(
            failureDetail: "Runtime error: array index out of bounds (line 9)"
        ) == false)
        #expect(journal.count == 1)
    }

    @Test("prune is a no-op when the last entry is a success (journal.rs:705)")
    func pruneIsNoOpForTrailingSuccess() throws {
        let journal = RhaiJournal(clock: { 1 })
        try journal.record(
            seq: 0,
            kind: "spawn_agent",
            reqHash: "aaaa",
            result: rhaiHostErrorSentinel("caught mid-journal error")
        )
        try journal.record(seq: 1, kind: "spawn_agent", reqHash: "bbbb", result: .object(["ok": .bool(true)]))
        #expect(try journal.pruneTrailingHostError(failureDetail: "caught mid-journal error") == false)
        #expect(journal.count == 2)
    }

    @Test("prune is a no-op on an empty journal (journal.rs:760)")
    func pruneIsNoOpWhenEmpty() throws {
        #expect(try RhaiJournal().pruneTrailingHostError(failureDetail: "boom") == false)
    }

    // MARK: SHA-256 vectors

    @Test("the bundled SHA-256 matches published NIST vectors")
    func sha256MatchesKnownVectors() {
        #expect(RhaiSHA256.hexDigest([])
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(RhaiSHA256.hexDigest(Array("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(RhaiSHA256.hexDigest(Array(String(repeating: "a", count: 1_000_000).utf8))
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}
