// ToolCallDisplayOutcomeTests.swift
//
// Open Grok — UI/session tool-outcome sidecar tests for OpenGrokSamplingTypes.
// Proves the resume map round-trips, never invents success for missing keys,
// merges with overwrite, and encodes empty maps compactly.

import Foundation
import Testing
import OpenGrokSamplingTypes

@Suite("ToolCallDisplayOutcome sidecar")
struct ToolCallDisplayOutcomeTests {

    @Test("enum raw values are stable session tokens")
    func rawValues() {
        #expect(ToolCallDisplayOutcome.succeeded.rawValue == "succeeded")
        #expect(ToolCallDisplayOutcome.failed.rawValue == "failed")
        #expect(ToolCallDisplayOutcome.cancelled.rawValue == "cancelled")
        #expect(ToolCallDisplayOutcome.denied.rawValue == "denied")
        #expect(ToolCallDisplayOutcome.pending.rawValue == "pending")
    }

    @Test("JSON round-trip preserves call id, outcome, and detail")
    func recordRoundTrip() throws {
        let record = ToolCallOutcomeRecord(
            callID: "call_abc",
            outcome: .failed,
            detail: "exit code 7"
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ToolCallOutcomeRecord.self, from: data)
        #expect(decoded.callID == "call_abc")
        #expect(decoded.outcome == .failed)
        #expect(decoded.detail == "exit code 7")

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["call_id"] as? String == "call_abc")
        #expect(object?["outcome"] as? String == "failed")
        #expect(object?["detail"] as? String == "exit code 7")
        #expect(object?["tool_call_id"] == nil)
    }

    @Test("record encode omits nil and empty detail")
    func recordOmitsEmptyDetail() throws {
        let nilDetail = ToolCallOutcomeRecord(callID: "c1", outcome: .succeeded, detail: nil)
        let emptyDetail = ToolCallOutcomeRecord(callID: "c2", outcome: .succeeded, detail: "")
        let nilData = try JSONEncoder().encode(nilDetail)
        let emptyData = try JSONEncoder().encode(emptyDetail)
        let nilObject = try JSONSerialization.jsonObject(with: nilData) as? [String: Any]
        let emptyObject = try JSONSerialization.jsonObject(with: emptyData) as? [String: Any]
        #expect(nilObject?["detail"] == nil)
        #expect(emptyObject?["detail"] == nil)
        #expect(emptyDetail.detail == nil)
    }

    @Test("map missing key returns nil, never succeeded")
    func missingKeyIsNilNotSucceeded() {
        var map = ToolCallOutcomeMap()
        map.upsert(callID: "known", outcome: .failed)

        #expect(map.outcome(for: "known") == .failed)
        #expect(map.outcome(for: "unknown") == nil)
        #expect(map.record(for: "unknown") == nil)
        // Explicit: do not treat absence as success (the /resume bug).
        #expect(map.outcome(for: "unknown") != .succeeded)
    }

    @Test("merge overwrites matching call ids and keeps distinct keys")
    func mergeOverwrite() {
        var base = ToolCallOutcomeMap()
        base.upsert(callID: "a", outcome: .pending)
        base.upsert(callID: "b", outcome: .succeeded, detail: "ok")

        var patch = ToolCallOutcomeMap()
        patch.upsert(callID: "a", outcome: .denied, detail: "permission")
        patch.upsert(callID: "c", outcome: .cancelled)

        base.merge(patch)

        #expect(base.outcome(for: "a") == .denied)
        #expect(base.record(for: "a")?.detail == "permission")
        #expect(base.outcome(for: "b") == .succeeded)
        #expect(base.outcome(for: "c") == .cancelled)
        #expect(base.count == 3)

        let merged = ToolCallOutcomeMap(records: [
            ToolCallOutcomeRecord(callID: "a", outcome: .failed)
        ]).merging(ToolCallOutcomeMap(records: [
            ToolCallOutcomeRecord(callID: "a", outcome: .cancelled)
        ]))
        #expect(merged.outcome(for: "a") == .cancelled)
    }

    @Test("empty map encodes compactly as {}")
    func emptyMapEncodesCompactly() throws {
        let map = ToolCallOutcomeMap()
        let data = try JSONEncoder().encode(map)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == "{}")
        #expect(map.isEmpty)

        let decoded = try JSONDecoder().decode(ToolCallOutcomeMap.self, from: data)
        #expect(decoded.isEmpty)
        #expect(decoded.outcome(for: "anything") == nil)
    }

    @Test("map JSON round-trip keyed by call id")
    func mapRoundTrip() throws {
        var map = ToolCallOutcomeMap()
        map.upsert(callID: "call_1", outcome: .succeeded)
        map.upsert(callID: "call_2", outcome: .failed, detail: "boom")
        map.upsert(callID: "call_3", outcome: .cancelled)
        map.upsert(callID: "call_4", outcome: .denied, detail: "sandbox")
        map.upsert(callID: "call_5", outcome: .pending)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(map)
        let decoded = try JSONDecoder().decode(ToolCallOutcomeMap.self, from: data)

        #expect(decoded.count == 5)
        #expect(decoded.outcome(for: "call_1") == .succeeded)
        #expect(decoded.outcome(for: "call_2") == .failed)
        #expect(decoded.record(for: "call_2")?.detail == "boom")
        #expect(decoded.outcome(for: "call_3") == .cancelled)
        #expect(decoded.outcome(for: "call_4") == .denied)
        #expect(decoded.outcome(for: "call_5") == .pending)
        #expect(decoded.outcome(for: "missing") == nil)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let call2 = object?["call_2"] as? [String: Any]
        #expect(call2?["outcome"] as? String == "failed")
        #expect(call2?["detail"] as? String == "boom")
        // call id is the key; value must not re-require a nested call_id.
        #expect(call2?["call_id"] == nil)
    }

    @Test("map decodes array-of-records fixtures")
    func mapDecodesRecordArray() throws {
        let json = """
        [
          {"call_id":"x","outcome":"failed","detail":"nope"},
          {"call_id":"y","outcome":"succeeded"}
        ]
        """.data(using: .utf8)!
        let map = try JSONDecoder().decode(ToolCallOutcomeMap.self, from: json)
        #expect(map.outcome(for: "x") == .failed)
        #expect(map.record(for: "x")?.detail == "nope")
        #expect(map.outcome(for: "y") == .succeeded)
        #expect(map.outcome(for: "z") == nil)
    }

    @Test("shell and pager state strings map without module imports")
    func stateStringHelpers() {
        #expect(ToolCallDisplayOutcome.outcome(fromShellState: "succeeded") == .succeeded)
        #expect(ToolCallDisplayOutcome.outcome(fromShellState: "failed") == .failed)
        #expect(ToolCallDisplayOutcome.outcome(fromShellState: "cancelled") == .cancelled)
        #expect(ToolCallDisplayOutcome.outcome(fromShellState: "denied") == .denied)
        #expect(ToolCallDisplayOutcome.outcome(fromShellState: "running") == .pending)
        #expect(ToolCallDisplayOutcome.outcome(fromShellState: "pending") == .pending)
        #expect(ToolCallDisplayOutcome.outcome(fromShellState: "nope") == nil)

        #expect(ToolCallDisplayOutcome.outcome(fromPagerState: "succeeded") == .succeeded)
        #expect(ToolCallDisplayOutcome.outcome(fromPagerState: "failed") == .failed)
        #expect(ToolCallDisplayOutcome.outcome(fromPagerState: "cancelled") == .cancelled)
        #expect(ToolCallDisplayOutcome.outcome(fromPagerState: "running") == .pending)
        #expect(ToolCallDisplayOutcome.outcome(fromPagerState: "pending") == .pending)
        #expect(ToolCallDisplayOutcome.outcome(fromPagerState: "mystery") == nil)
    }
}
