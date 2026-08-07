// EffortShapingTests.swift
//
// Reasoning-effort request shaping, ported against upstream HEAD 70002584:
// the base Responses `reasoning` object (conversation.rs:3892-3895 and the
// projection tests at conversation.rs:8196-8346), Codex empty-`reasoning`
// retention (provider.rs:613-620), Messages `output_config`/`thinking`/
// `tool_choice` (conversation.rs:5313-5352, types.rs:737-745), the Fireworks
// effort gate (client.rs:1806-1813, test at client.rs:4226-4255), and the
// Codex unknown-event filter (provider.rs:834-847, test at
// client.rs:5780-5815).

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Responses backend

@Suite("Responses effort shaping")
struct ResponsesEffortShapingTests {
    private func projectedBody(effort: ReasoningEffort?, provider: ModelProvider = .xai) -> JSONValue {
        var req = ConversationRequest(items: [.user("hi")])
        req.reasoningEffort = effort
        return projectResponsesRequestBody(
            req,
            model: "test",
            policy: ResponsesRequestPolicy(localEffort: effort),
            adapter: providerAdapter(provider)
        )
    }

    /// Provenance: Rust `test_responses_request_carries_reasoning_effort_nested`
    /// (conversation.rs:8257-8286).
    @Test("effort lands nested at reasoning.effort with the max/ultra clamp")
    func carriesEffortNested() {
        let cases: [(ReasoningEffort, String)] = [
            (.none, "none"),
            (.minimal, "minimal"),
            (.low, "low"),
            (.medium, "medium"),
            (.high, "high"),
            (.xhigh, "xhigh"),
            // The Responses typed layer models no Ultra variant; max/ultra
            // clamp to xhigh here and the Codex patcher restores the true
            // effort immediately before transport.
            (.max, "xhigh"),
            (.ultra, "xhigh"),
        ]
        for (variant, expected) in cases {
            let body = projectedBody(effort: variant)
            #expect(
                body["reasoning"]?["effort"]?.stringValue == expected,
                "\(variant) should serialize as reasoning.effort=\(expected)"
            )
            #expect(body["reasoning"]?["summary"]?.stringValue == "concise")
        }
    }

    /// Provenance: Rust `test_responses_request_omits_effort_when_unset`
    /// (conversation.rs:8288-8298). The reasoning object itself is still
    /// emitted — only `effort` is absent.
    @Test("no effort: reasoning object present with summary only")
    func omitsEffortWhenUnset() {
        let body = projectedBody(effort: nil)
        #expect(body["reasoning"] != nil)
        #expect(body["reasoning"]?["effort"] == nil)
        #expect(body["reasoning"]?["summary"]?.stringValue == "concise")
    }

    /// Provenance: upstream leaves the emptied `reasoning` object in place
    /// after the Codex summary strip (provider.rs:613-620); with the base
    /// object now carrying effort, deleting it would drop effort too.
    @Test("codex summary strip keeps the reasoning object and its effort")
    func codexKeepsEmptiedReasoningObject() {
        // Summary policy nil → the Codex patcher strips the base "concise".
        let withEffort = projectedBody(effort: .high, provider: .codex)
        #expect(withEffort["reasoning"]?["summary"] == nil)
        #expect(withEffort["reasoning"]?["effort"]?.stringValue == "high")

        // Even fully emptied, the object stays on the wire like upstream.
        let empty = projectedBody(effort: nil, provider: .codex)
        #expect(empty["reasoning"] == .object([:]))
    }

    /// Provenance: the Codex transport-boundary override (provider.rs:623-629)
    /// layered over the base clamp: the wire ends at "max", not "xhigh".
    @Test("codex re-raises the clamped max/ultra effort to max")
    func codexMaxOverride() {
        for variant in [ReasoningEffort.max, .ultra] {
            let body = projectedBody(effort: variant, provider: .codex)
            #expect(body["reasoning"]?["effort"]?.stringValue == "max")
        }
    }
}

// MARK: - Chat Completions backend

@Suite("Chat effort shaping")
struct ChatEffortShapingTests {
    /// Provenance: Rust `test_chat_completion_request_carries_reasoning_effort_top_level`
    /// (conversation.rs:8216-8242). Chat carries the effort verbatim — no clamp.
    @Test("effort lands top-level as reasoning_effort, unclamped")
    func carriesEffortTopLevel() throws {
        for variant in [
            ReasoningEffort.none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra,
        ] {
            var req = ConversationRequest(items: [.user("hi")])
            req.reasoningEffort = variant
            let wire = projectChatCompletionRequest(req)
            let json = try JSONValue.encode(wire)
            #expect(
                json["reasoning_effort"]?.stringValue == variant.rawValue,
                "\(variant) should serialize as top-level reasoning_effort"
            )
        }
    }

    /// Provenance: Rust `test_chat_completion_request_omits_reasoning_effort_when_unset`
    /// (conversation.rs:8245-8255). OpenAI rejects `null` here on some models.
    @Test("reasoning_effort is absent when unset")
    func omitsEffortWhenUnset() throws {
        let wire = projectChatCompletionRequest(ConversationRequest(items: [.user("hi")]))
        let json = try JSONValue.encode(wire)
        #expect(json["reasoning_effort"] == nil)
    }
}

// MARK: - Messages backend

@Suite("Messages effort shaping")
struct MessagesEffortShapingTests {
    private func wire(_ req: ConversationRequest) throws -> JSONValue {
        try JSONValue.encode(projectMessagesRequest(req, model: "test", maxTokens: 1024))
    }

    /// Provenance: Rust `test_messages_request_thinking_carries_summarized_display`
    /// (conversation.rs:8303-8322) — newer Messages models omit thinking
    /// content unless `display: "summarized"` is sent.
    @Test("effort produces output_config.effort and adaptive summarized thinking")
    func effortProducesOutputConfigAndThinking() throws {
        var req = ConversationRequest(items: [.user("hi")])
        req.reasoningEffort = .high
        let json = try wire(req)
        #expect(json["output_config"]?["effort"]?.stringValue == "high")
        #expect(json["thinking"]?["type"]?.stringValue == "adaptive")
        #expect(json["thinking"]?["display"]?.stringValue == "summarized")
    }

    /// Provenance: Rust `to_messages_api` (types.rs:737-745): low/medium/high
    /// verbatim, xhigh/max/ultra clamp to "max".
    @Test("effort clamps to the Messages menu")
    func effortClamp() throws {
        let cases: [(ReasoningEffort, String)] = [
            (.low, "low"), (.medium, "medium"), (.high, "high"),
            (.xhigh, "max"), (.max, "max"), (.ultra, "max"),
        ]
        for (variant, expected) in cases {
            var req = ConversationRequest(items: [.user("hi")])
            req.reasoningEffort = variant
            let json = try wire(req)
            #expect(
                json["output_config"]?["effort"]?.stringValue == expected,
                "\(variant) should map to output_config.effort=\(expected)"
            )
        }
    }

    /// Provenance: Rust `test_messages_request_omits_output_config_when_no_supported_effort`
    /// (conversation.rs:8195-8214) and
    /// `test_messages_request_omits_thinking_when_effort_unset`
    /// (conversation.rs:8326-8346).
    @Test("unset/none/minimal effort omits output_config and thinking")
    func unsupportedEffortOmitsBoth() throws {
        for effort in [ReasoningEffort?.none, .some(.none), .some(.minimal)] {
            var req = ConversationRequest(items: [.user("hi")])
            req.reasoningEffort = effort
            let json = try wire(req)
            #expect(json["output_config"] == nil, "\(String(describing: effort)) must not produce output_config")
            #expect(json["thinking"] == nil, "\(String(describing: effort)) must not auto-pair thinking")
        }
    }

    /// Provenance: Rust `json_schema_and_reasoning_effort_are_orthogonal_in_output_config`
    /// (conversation.rs:6792-6811).
    @Test("json_schema and effort are orthogonal in output_config")
    func schemaAndEffortOrthogonal() throws {
        var req = ConversationRequest(items: [.user("go")])
        req.reasoningEffort = .high
        req.jsonSchema = .object([
            "type": .string("object"),
            "properties": .object(["x": .object(["type": .string("string")])]),
            "required": .array([.string("x")]),
        ])
        let json = try wire(req)
        #expect(json["output_config"]?["effort"]?.stringValue == "high")
        #expect(json["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(json["output_config"]?["format"]?["schema"]?["type"]?.stringValue == "object")
        #expect(json["thinking"] != nil, "thinking set when effort is present")
    }

    /// Provenance: the Anthropic tool_choice mapping (conversation.rs:5313-5322):
    /// `required` is Messages `any`, `none` maps to `auto`, and `custom` has no
    /// native Messages shape so it is omitted.
    @Test("tool_choice maps to the Anthropic shapes")
    func toolChoiceMapping() throws {
        let cases: [(ConversationToolChoice?, JSONValue?)] = [
            (nil, nil),
            (.auto, .object(["type": .string("auto")])),
            (.required, .object(["type": .string("any")])),
            (.function("lookup"), .object(["type": .string("tool"), "name": .string("lookup")])),
            (ConversationToolChoice.none, .object(["type": .string("auto")])),
            (.custom("freeform"), nil),
        ]
        for (choice, expected) in cases {
            var req = ConversationRequest(items: [.user("hi")])
            req.toolChoice = choice
            let json = try wire(req)
            #expect(
                json["tool_choice"] == expected,
                "\(String(describing: choice)) should map to \(String(describing: expected))"
            )
        }
    }
}

// MARK: - Fireworks effort gate

@Suite("Fireworks effort gate")
struct FireworksEffortGateTests {
    private func makeClient(configEffort: ReasoningEffort?) throws -> SamplingClient {
        try SamplingClient(config: SamplerConfig(
            baseURL: "https://api.fireworks.ai/inference/v1",
            model: "accounts/fireworks/routers/kimi-k3-fast",
            provider: .fireworks,
            reasoningEffort: configEffort
        ))
    }

    /// Provenance: Rust `fireworks_reasoning_requires_explicit_model_support`
    /// (client.rs:4226-4255). A config-level effort is the "model declares
    /// effort support" signal: the request effort survives the sanitize strip.
    @Test("request effort survives when the model config declares support")
    func supportedModelKeepsRequestEffort() throws {
        let client = try makeClient(configEffort: .high)
        var wire = ChatCompletionWireRequest(model: "accounts/fireworks/routers/kimi-k3-fast")
        wire.reasoningEffort = .low
        client.sanitizeChatWireRequest(&wire)
        #expect(wire.reasoningEffort == .low)
        let json = try JSONValue.encode(wire)
        #expect(json["reasoning_effort"]?.stringValue == "low")
    }

    /// The configured default backfills a request that chose no effort.
    @Test("config effort backfills a request without one")
    func configEffortBackfills() throws {
        let client = try makeClient(configEffort: .high)
        var wire = ChatCompletionWireRequest(model: "accounts/fireworks/routers/kimi-k3-fast")
        client.sanitizeChatWireRequest(&wire)
        #expect(wire.reasoningEffort == .high)
    }

    /// Without config-declared support the sanitize strip stands: the request
    /// effort is deliberately lost (client.rs:4246-4254).
    @Test("request effort is stripped when the model config declares none")
    func unsupportedModelStripsEffort() throws {
        let client = try makeClient(configEffort: nil)
        var wire = ChatCompletionWireRequest(model: "test-model")
        wire.reasoningEffort = .high
        client.sanitizeChatWireRequest(&wire)
        #expect(wire.reasoningEffort == nil)
    }

    /// Provenance: the strips themselves — Fireworks (provider.rs:353) and
    /// Wafer (provider.rs:422) drop effort in sanitize; Wafer has no restore
    /// gate. A non-stripping provider (xAI) forwards effort untouched.
    @Test("fireworks and wafer sanitize strip effort; xai does not")
    func sanitizeStrips() {
        for provider in [ModelProvider.fireworks, .wafer] {
            var wire = ChatCompletionWireRequest(model: "m")
            wire.reasoningEffort = .high
            providerAdapter(provider).sanitizeChatRequest(&wire)
            #expect(wire.reasoningEffort == nil, "\(provider.asString) sanitize must strip effort")
        }
        var wire = ChatCompletionWireRequest(model: "m")
        wire.reasoningEffort = .high
        providerAdapter(.xai).sanitizeChatRequest(&wire)
        #expect(wire.reasoningEffort == .high)
    }
}

// MARK: - Codex unknown-event filter

/// Provenance: Rust `codex_unknown_event_filter_only_accepts_unknown_top_level_kinds`
/// (client.rs:5780-5815) over `is_unknown_top_level_response_event`
/// (provider.rs:834-847). Only a serialization error that literally names
/// ``unknown variant `<type>` `` may be swallowed — a malformed *known* event
/// must fail loudly instead of becoming silently missing tokens.
@Suite("Codex unknown-event filter")
struct CodexUnknownEventFilterTests {
    private let codex = providerAdapter(.codex)

    @Test("unknown top-level kind with a matching unknown-variant error is ignored")
    func unknownTopLevelKindIgnored() {
        let data = #"{"type":"response.future_control","sequence_number":1,"payload":{"forward_compatible":true}}"#
        let error = SamplingError.serialization(
            "unknown variant `response.future_control`, expected one of `response.created`, `response.completed`"
        )
        #expect(codex.ignoresUnknownResponseEvent(error: error, data: data))
        // The allowance is Codex-dialect-only.
        #expect(!providerAdapter(.xai).ignoresUnknownResponseEvent(error: error, data: data))
    }

    @Test("a known event with a malformed nested payload must still fail")
    func malformedKnownEventFails() {
        let data = #"{"type":"response.completed","sequence_number":2,"response":{"output":[{"type":"future_output"}]}}"#
        let error = SamplingError.serialization(
            "unknown variant `future_output`, expected one of `message`, `reasoning`"
        )
        // The error names a nested kind, not the top-level event type.
        #expect(!codex.ignoresUnknownResponseEvent(error: error, data: data))
    }

    @Test("a truncated known event must still fail")
    func truncatedKnownEventFails() {
        let data = #"{"type":"response.output_text.delta","sequence_number":3}"#
        let error = SamplingError.serialization("missing field `delta`")
        #expect(!codex.ignoresUnknownResponseEvent(error: error, data: data))
    }

    @Test("malformed JSON is never swallowed")
    func malformedJSONFails() {
        let data = #"{"type":"response.future_control""#
        let error = SamplingError.serialization("invalid responses event JSON")
        #expect(!codex.ignoresUnknownResponseEvent(error: error, data: data))
    }

    @Test("non-serialization errors are never swallowed")
    func nonSerializationErrorFails() {
        let data = #"{"type":"response.future_control"}"#
        let error = SamplingError.eventStreamError("unknown variant `response.future_control`")
        #expect(!codex.ignoresUnknownResponseEvent(error: error, data: data))
    }
}
