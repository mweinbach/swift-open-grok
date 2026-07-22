// OpenGrokPromptQueueTests.swift
//
// Deterministic tests for OpenGrokPromptQueue, translated from the Rust
// `xai-prompt-queue/src/types.rs` test suite. These pin the exact wire
// JSON shape (camelCase keys, omitted-when-nil, defaults, unknown-field
// tolerance) that the shell (W6-S4) and pager (W8/W9) agree on.

import Testing
import Foundation
@testable import OpenGrokPromptQueue

@Suite("PromptQueue wire types")
struct PromptQueueTests {
    // MARK: - QueueChanged full round-trip

    @Test("QueueChanged full round-trip preserves all fields and wire shape")
    func queueChangedFullRoundTrip() throws {
        let original = QueueChanged(
            sessionId: "sess-42",
            entries: [
                QueueEntryWire(
                    id: "p1",
                    version: 3,
                    owner: "alice",
                    lastEditor: "bob",
                    kind: "prompt",
                    text: "fix the bug",
                    position: 0
                ),
                QueueEntryWire(
                    id: "p2",
                    version: 0,
                    owner: nil,
                    lastEditor: nil,
                    kind: "bash",
                    text: "ls -la",
                    position: 1
                ),
            ],
            runningPromptId: "p0"
        )

        // Encode through a plain JSONEncoder to inspect the wire shape
        // (mirrors `serde_json::to_value`).
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let object = try JSONSerialization.jsonObject(with: data)

        guard let dict = object as? [String: Any] else {
            Issue.record("expected top-level object")
            return
        }
        #expect(dict["sessionId"] as? String == "sess-42")

        guard let entries = dict["entries"] as? [[String: Any]] else {
            Issue.record("expected entries array")
            return
        }
        #expect(entries[0]["lastEditor"] as? String == "bob")
        #expect(dict["runningPromptId"] as? String == "p0")

        // owner/lastEditor must be OMITTED on the wire when nil (Rust
        // `skip_serializing_if = "Option::is_none"`).
        #expect(entries[1]["owner"] == nil)
        #expect(entries[1]["lastEditor"] == nil)

        // Round-trip back through the decoder.
        let decoder = JSONDecoder()
        let round = try decoder.decode(QueueChanged.self, from: data)
        #expect(round == original)
    }

    // MARK: - Golden wire JSON

    @Test("QueueChanged pins the exact golden wire JSON")
    func queueChangedGoldenWireJSON() throws {
        let payload = QueueChanged(
            sessionId: "s1",
            entries: [
                QueueEntryWire(
                    id: "p1",
                    version: 2,
                    owner: "alice",
                    lastEditor: "bob",
                    kind: "prompt",
                    text: "hi",
                    position: 0
                ),
            ],
            runningPromptId: "p0"
        )

        let expected: [String: Any] = [
            "sessionId": "s1",
            "entries": [[
                "id": "p1",
                "version": 2,
                "owner": "alice",
                "lastEditor": "bob",
                "kind": "prompt",
                "text": "hi",
                "position": 0,
            ]],
            "runningPromptId": "p0",
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let actual = try JSONSerialization.jsonObject(with: data)
        let expectedJSON = try JSONSerialization.data(
            withJSONObject: expected,
            options: [.sortedKeys]
        )
        let actualJSON = try JSONSerialization.data(
            withJSONObject: actual,
            options: [.sortedKeys]
        )
        #expect(String(data: actualJSON, encoding: .utf8) == String(data: expectedJSON, encoding: .utf8))
    }

    // MARK: - sessionId required

    @Test("QueueChanged requires sessionId on decode")
    func queueChangedRequiresSessionId() throws {
        let missing = #"{"entries":[]}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(QueueChanged.self, from: missing)
        }
    }

    // MARK: - Sparse payload with defaults

    @Test("Sparse payload deserializes with defaults")
    func sparsePayloadDefaults() throws {
        let sparse = #"{"sessionId":"s1","entries":[{"id":"p1"}]}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        let parsed = try decoder.decode(QueueChanged.self, from: sparse)

        guard let entry = parsed.entries.first else {
            Issue.record("expected one entry")
            return
        }
        #expect(entry.version == 0)
        #expect(entry.kind == "")
        #expect(entry.text == "")
        #expect(entry.position == 0)
        #expect(entry.owner == nil)
        #expect(entry.lastEditor == nil)
        #expect(parsed.runningPromptId == nil)
    }

    // MARK: - Unknown-field tolerance

    @Test("Extra unknown fields are ignored on decode")
    func extraUnknownFieldsIgnored() throws {
        let json = """
        {
            "sessionId": "s1",
            "entries": [],
            "runningPromptId": null,
            "futureField": "should be ignored"
        }
        """.data(using: .utf8)!

        let parsed = try JSONDecoder().decode(QueueChanged.self, from: json)
        #expect(parsed.sessionId == "s1")
        // `runningPromptId: null` decodes as nil (Rust parity: explicit
        // null and missing key both surface as `None`).
        #expect(parsed.runningPromptId == nil)
    }

    // MARK: - Default derivation

    @Test("QueueChanged default derivation matches Rust Default")
    func queueChangedDefault() {
        let d = QueueChanged.defaultValue
        #expect(d.sessionId == "")
        #expect(d.entries.isEmpty)
        #expect(d.runningPromptId == nil)

        // The no-arg initializer must produce the same defaults.
        let initDefault = QueueChanged()
        #expect(initDefault == d)
    }

    // MARK: - QueueEntryMeta (in-process only, no Codable)

    @Test("QueueEntryMeta round-trips its fields and is Sendable/Hashable")
    func queueEntryMetaShape() {
        let meta = QueueEntryMeta(
            id: "p1",
            version: 2,
            owner: "alice",
            lastEditor: "bob",
            kind: "prompt",
            text: "fix it"
        )
        #expect(meta.id == "p1")
        #expect(meta.version == 2)
        #expect(meta.owner == "alice")
        #expect(meta.lastEditor == "bob")
        #expect(meta.kind == "prompt")
        #expect(meta.text == "fix it")

        // Equality / Hashable.
        let same = meta
        #expect(meta == same)
        let set: Set<QueueEntryMeta> = [meta, meta]
        #expect(set.count == 1)
    }

    @Test("QueueEntryMeta default version is zero")
    func queueEntryMetaDefaultVersion() {
        let meta = QueueEntryMeta(id: "x", kind: "prompt", text: "hi")
        #expect(meta.version == 0)
        #expect(meta.owner == nil)
        #expect(meta.lastEditor == nil)
    }
}

// MARK: - FIFO prompt queue state machine

@Suite("PromptQueue FIFO state machine")
struct PromptQueueStateMachineTests {
    @Test("enqueue preserves FIFO order and wire positions")
    func enqueueFIFO() async {
        let queue = PromptQueue(sessionId: "sess")
        _ = await queue.enqueue(QueueEntryMeta(id: "p1", kind: "prompt", text: "one"))
        _ = await queue.enqueue(QueueEntryMeta(id: "p2", kind: "prompt", text: "two"))
        let ids = await queue.orderedIds
        #expect(ids == ["p1", "p2"])
        let snap = await queue.wireSnapshot()
        #expect(snap.entries.map(\.position) == [0, 1])
        #expect(snap.sessionId == "sess")
    }

    @Test("beginNext marks running and completeRunning clears it")
    func beginAndComplete() async throws {
        let queue = PromptQueue(sessionId: "s")
        _ = await queue.enqueue(QueueEntryMeta(id: "a", kind: "prompt", text: "a"))
        _ = await queue.enqueue(QueueEntryMeta(id: "b", kind: "prompt", text: "b"))
        let first = try await queue.beginNext()
        #expect(first.id == "a")
        #expect(await queue.runningPromptId == "a")
        #expect(await queue.orderedIds == ["b"])
        await queue.completeRunning()
        #expect(await queue.runningPromptId == nil)
        let second = try await queue.beginNext()
        #expect(second.id == "b")
    }

    @Test("stale version edit is a no-op")
    func staleEdit() async {
        let queue = PromptQueue(sessionId: "s")
        _ = await queue.enqueue(QueueEntryMeta(id: "p1", version: 1, kind: "prompt", text: "old"))
        let updated = await queue.edit(id: "p1", expectedVersion: 0, text: "new")
        #expect(updated == nil)
        let ok = await queue.edit(id: "p1", expectedVersion: 1, text: "new", editor: "bob")
        #expect(ok?.version == 2)
        #expect(ok?.text == "new")
        #expect(ok?.lastEditor == "bob")
    }
}
