// AgentSwarmInputTests.swift
//
// `AgentSwarmToolInput` wire shape and the reasoning-effort normalizer
// against the Rust contracts (xai-tool-types task.rs:138-293, pin
// 650c1db7): `reasoning_effort` decodes and round-trips, the ordered
// resume map preserves source order, and the normalizer's accept list and
// error copy are byte-identical.

import Foundation
import Testing
import OpenGrokToolTypes

@Suite("AgentSwarmToolInput")
struct AgentSwarmInputTests {
    private func decode(_ json: String) throws -> AgentSwarmToolInput {
        try JSONDecoder().decode(
            AgentSwarmToolInput.self,
            from: Data(json.utf8)
        )
    }

    @Test("reasoning_effort decodes and defaults nil")
    func reasoningEffortDecodes() throws {
        let bare = try decode(#"{"description":"work"}"#)
        #expect(bare.reasoningEffort == nil)
        #expect(bare.subagentType == "general-purpose")

        let set = try decode(#"{"description":"work","reasoning_effort":"xhigh"}"#)
        #expect(set.reasoningEffort == "xhigh")
    }

    @Test("nil optionals are omitted on the wire")
    func nilOptionalsOmitted() throws {
        let json = String(
            decoding: try JSONEncoder().encode(AgentSwarmToolInput(description: "work")),
            as: UTF8.self
        )
        #expect(!json.contains("reasoning_effort"))
        #expect(!json.contains("\"model\""))
        #expect(!json.contains("prompt_template"))
    }

    // Upstream `ordered_resume_object_deserializes_in_source_order`
    // (agent_swarm/mod.rs:977-990) at the input layer. Foundation's decoder
    // hands object keys back in dictionary order, so source order is
    // recovered from the RAW argument text — the same reorder the swarm
    // dispatch performs with `call.arguments`.
    @Test("ordered resume map preserves source order")
    func orderedResumeMapPreservesSourceOrder() throws {
        let raw = #"{"description":"work","resume_agent_ids":{"second":"p2","first":"p1"}}"#
        let input = try decode(raw)
        let entries = input.resumeAgentIds?
            .reordered(bySourceOrderIn: raw).entries ?? []
        #expect(entries.map(\.key) == ["second", "first"])
        #expect(entries.map(\.value) == ["p2", "p1"])
    }

    @Test("the source-order scanner survives strings, nesting, and absence")
    func sourceOrderScannerEdgeCases() {
        // A decoy string containing the field name, then the real object.
        let tricky = #"{"description":"mentions \"resume_agent_ids\": {} in prose","prompt_template":{"nested":"{\"resume_agent_ids\":1}"},"resume_agent_ids":{"z":"1","a":"2","m":"3"}}"#
        #expect(OrderedResumeAgentMap.sourceOrderedKeys(inRawJSON: tricky) == ["z", "a", "m"])
        // Absent field → nil → callers keep decode order.
        #expect(OrderedResumeAgentMap.sourceOrderedKeys(
            inRawJSON: #"{"description":"work"}"#
        ) == nil)
        // Escaped characters inside keys round-trip.
        #expect(OrderedResumeAgentMap.sourceOrderedKeys(
            inRawJSON: #"{"resume_agent_ids":{"a\"b":"1","c\\d":"2"}}"#
        ) == [#"a"b"#, #"c\d"#])
    }

    /// `.success` payload, or `.failure` surfaced as a recorded issue.
    private func accepted(_ value: String?) -> String? {
        switch normalizeSubagentReasoningEffort(value) {
        case .success(let normalized):
            return normalized
        case .failure(let error):
            Issue.record("\(String(describing: value)) must normalize: \(error.message)")
            return nil
        }
    }

    // The Rust accept list (task.rs:262-264) and normalizer arms
    // (task.rs:271-293).
    @Test("effort normalizer accepts the eight levels case-insensitively")
    func effortNormalizerAccepts() {
        #expect(subagentReasoningEffortValues
            == ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
        for level in subagentReasoningEffortValues {
            #expect(accepted(level) == level)
        }
        #expect(accepted(" XHigh ") == "xhigh")
    }

    @Test("effort normalizer collapses sentinels to nil")
    func effortNormalizerSentinels() {
        #expect(accepted(nil) == nil)
        #expect(accepted("  ") == nil)
        #expect(accepted("null") == nil)
        #expect(accepted("UNDEFINED") == nil)
    }

    @Test("effort normalizer error copy is byte-identical")
    func effortNormalizerErrorCopy() {
        guard case .failure(let error) = normalizeSubagentReasoningEffort("turbo") else {
            Issue.record("an unknown effort level must be rejected")
            return
        }
        #expect(error.message ==
            "invalid reasoning_effort \"turbo\" (expected one of: "
            + "none, minimal, low, medium, high, xhigh, max, ultra)")
    }
}
