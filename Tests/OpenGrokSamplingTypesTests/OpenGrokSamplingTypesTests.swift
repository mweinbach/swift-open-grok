// OpenGrokSamplingTypesTests.swift
//
// Rust-derived wire, repair, reasoning, and stream fixtures for
// OpenGrokSamplingTypes. Translated from the unit tests in
// `crates/codegen/xai-grok-sampling-types/src/{conversation,error,messages}.rs`.

import Testing
import Foundation
@testable import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Helpers

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - Conversation item wire

@Suite("ConversationItem wire")
struct ConversationItemWireTests {
    @Test("user/assistant/tool_result round-trip")
    func basicRoundTrip() throws {
        let items: [ConversationItem] = [
            .system("You are helpful."),
            .user("hello"),
            .assistant("hi there"),
            .toolResult(toolCallId: "call-1", content: #"{"ok":true}"#),
        ]
        let decoded = try roundTrip(items)
        #expect(decoded == items)
    }

    @Test("user with image content parts")
    func userWithImage() throws {
        let item = ConversationItem.userWithParts([
            .text(text: "what is this?"),
            .image(url: "data:image/png;base64,abc"),
        ])
        let decoded = try roundTrip(item)
        #expect(decoded == item)
        if case .user(let u) = decoded {
            #expect(u.content.count == 2)
        } else {
            Issue.record("expected user item")
        }
    }

    @Test("assistant with tool calls round-trips arguments")
    func toolCallsRoundTrip() throws {
        let tc = ToolCall(id: "call-1", name: "read_file", arguments: #"{"path":"/tmp/a"}"#)
        let item = ConversationItem.assistantToolCalls([tc])
        let decoded = try roundTrip(item)
        #expect(decoded == item)
        if case .assistant(let a) = decoded {
            #expect(a.toolCalls.count == 1)
            #expect(a.toolCalls[0].name == "read_file")
            #expect(a.toolCalls[0].arguments.contains("/tmp/a"))
        } else {
            Issue.record("expected assistant")
        }
    }

    @Test("multiple tool calls preserve order")
    func multipleToolCalls() throws {
        let calls = [
            ToolCall(id: "c1", name: "a", arguments: "{}"),
            ToolCall(id: "c2", name: "b", arguments: "{}"),
            ToolCall(id: "c3", name: "c", arguments: "{}"),
        ]
        let item = ConversationItem.assistantToolCalls(calls)
        let decoded = try roundTrip(item)
        if case .assistant(let a) = decoded {
            #expect(a.toolCalls.map(\.id) == ["c1", "c2", "c3"])
        } else {
            Issue.record("expected assistant")
        }
    }

    @Test("synthetic user reasons preserve known variants and unknown fallback")
    func syntheticReasonUnknownFallback() throws {
        let known = ConversationItem.systemReminder("ping")
        let decodedKnown = try roundTrip(known)
        if case .user(let u) = decodedKnown {
            #expect(u.syntheticReason == .systemReminder)
        } else {
            Issue.record("expected user")
        }

        // Unknown wire value collapses to .unknown (Rust `#[serde(other)]`).
        let json = Data(#"{"type":"user","content":[{"type":"text","text":"x"}],"synthetic_reason":"brand_new_reason"}"#.utf8)
        let item = try JSONDecoder().decode(ConversationItem.self, from: json)
        if case .user(let u) = item {
            #expect(u.syntheticReason == .unknown)
        } else {
            Issue.record("expected user")
        }
    }

    @Test("custom tool call id envelope encodes and decodes")
    func customToolCallIdEnvelope() {
        let tc = ToolCall.custom(callId: "call_abc", itemId: "item_xyz", name: "shell", input: "ls")
        #expect(tc.isCustom)
        #expect(tc.callId == "call_abc")
        #expect(tc.customItemId == "item_xyz")
        #expect(tc.customInput == "ls")
        let decoded = ToolCall.decodeCustomToolCallId(tc.id)
        #expect(decoded?.callId == "call_abc")
        #expect(decoded?.itemId == "item_xyz")
    }
}

// MARK: - Repair

@Suite("Conversation repair")
struct ConversationRepairTests {
    @Test("repair inserts synthetic results for dangling tool calls")
    func repairDangling() {
        var conv: [ConversationItem] = [
            .assistantToolCalls([
                ToolCall(id: "c1", name: "read", arguments: "{}"),
                ToolCall(id: "c2", name: "write", arguments: "{}"),
            ]),
            .toolResult(toolCallId: "c1", content: "ok"),
        ]
        #expect(hasDanglingToolCalls(conv))
        let inserted = repairDanglingToolCalls(&conv, reason: .userCancelled)
        #expect(inserted == 1)
        #expect(!hasDanglingToolCalls(conv))
        #expect(conv.count == 3)
        if case .toolResult(let tr) = conv[2] {
            #expect(tr.toolCallId == "c2")
            #expect(tr.content.contains("write") || tr.content.contains("cancel") || !tr.content.isEmpty)
        } else {
            Issue.record("expected synthetic tool result")
        }
    }

    @Test("repair is idempotent on clean conversation")
    func repairIdempotent() {
        var conv: [ConversationItem] = [
            .assistantToolCalls([ToolCall(id: "c1", name: "read", arguments: "{}")]),
            .toolResult(toolCallId: "c1", content: "ok"),
        ]
        #expect(repairDanglingToolCalls(&conv, reason: .userCancelled) == 0)
        #expect(conv.count == 2)
    }

    @Test("dedup keeps last tool result for a call id")
    func dedupToolResults() {
        var conv: [ConversationItem] = [
            .assistantToolCalls([ToolCall(id: "c1", name: "read", arguments: "{}")]),
            .toolResult(toolCallId: "c1", content: "stale"),
            .toolResult(toolCallId: "c1", content: "fresh"),
        ]
        let removed = dedupDuplicateToolResults(&conv)
        #expect(removed == 1)
        #expect(conv.count == 2)
        if case .toolResult(let tr) = conv[1] {
            #expect(tr.content == "fresh")
        } else {
            Issue.record("expected remaining tool result")
        }
    }

    @Test("harness halt reason produces synthetic result")
    func harnessHaltReason() {
        var conv: [ConversationItem] = [
            .assistantToolCalls([ToolCall(id: "c1", name: "bash", arguments: "{}")]),
        ]
        _ = repairDanglingToolCalls(&conv, reason: .harnessHalted(class: "timeout"))
        #expect(conv.count == 2)
    }
}

// MARK: - Token usage / request types

@Suite("TokenUsage and request types")
struct TokenUsageAndRequestTests {
    @Test("TokenUsage snake_case wire form")
    func tokenUsageWire() throws {
        let usage = TokenUsage(
            promptTokens: 10,
            completionTokens: 4,
            totalTokens: 14,
            reasoningTokens: 2,
            cachedPromptTokens: 3
        )
        let data = try JSONEncoder().encode(usage)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["prompt_tokens"] as? Int == 10)
        #expect(obj?["completion_tokens"] as? Int == 4)
        #expect(obj?["cached_prompt_tokens"] as? Int == 3)
        #expect(obj?["reasoning_tokens"] as? Int == 2)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        #expect(decoded == usage)
    }

    @Test("reportedCostTicks normalizes zero and negative to nil")
    func reportedCostTicks() {
        #expect(OpenGrokSamplingTypes.reportedCostTicks(nil) == nil)
        #expect(OpenGrokSamplingTypes.reportedCostTicks(0) == nil)
        #expect(OpenGrokSamplingTypes.reportedCostTicks(-1) == nil)
        #expect(OpenGrokSamplingTypes.reportedCostTicks(42) == 42)
    }

    @Test("ConversationRequest carries tools and reasoning effort")
    func conversationRequestFields() {
        let tools = [
            ToolSpec(name: "read_file", description: "Read a file", parameters: .object([:]))
        ]
        let req = ConversationRequest(
            items: [.user("hi")],
            tools: tools,
            model: "grok-4",
            xGrokConvId: "conv",
            xGrokReqId: "req",
            reasoningEffort: .high
        )
        #expect(req.tools.count == 1)
        #expect(req.model == "grok-4")
        #expect(req.reasoningEffort == .high)
        #expect(req.xGrokConvId == "conv")
    }

    @Test("SamplingConfig round-trips without secrets")
    func samplingConfigRoundTrip() throws {
        let cfg = SamplingConfig(
            baseURL: "https://api.x.ai/v1",
            model: "grok-4",
            maxCompletionTokens: 4096,
            temperature: 0.7,
            contextWindow: 256_000,
            reasoningEffort: .medium
        )
        let decoded = try roundTrip(cfg)
        #expect(decoded == cfg)
    }
}

// MARK: - Stream events

@Suite("Stream events")
struct StreamEventTests {
    @Test("ToolCallDelta encodes type as kind wire key")
    func toolCallDeltaWire() throws {
        let delta = ToolCallDelta(
            index: 0,
            id: "call-1",
            kind: "function",
            function: ToolCallFunctionDelta(name: "read", arguments: "{\"p\":")
        )
        let data = try JSONEncoder().encode(delta)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["type"] as? String == "function")
        #expect(obj?["id"] as? String == "call-1")
        let decoded = try JSONDecoder().decode(ToolCallDelta.self, from: data)
        #expect(decoded == delta)
    }

    @Test("ChatChunkDelta carries tool call deltas")
    func chatChunkDeltaToolCalls() throws {
        let chunk = ChatChunkDelta(
            role: .assistant,
            content: nil,
            toolCalls: [
                ToolCallDelta(index: 0, id: "c1", function: ToolCallFunctionDelta(name: "x", arguments: "{"))
            ]
        )
        let decoded = try roundTrip(chunk)
        #expect(decoded.toolCalls.count == 1)
        #expect(decoded.toolCalls[0].id == "c1")
    }
}

// MARK: - Reasoning effort helpers

@Suite("Reasoning effort")
struct ReasoningEffortTests {
    @Test("messagesAPI maps unsupported variants to nil")
    func messagesAPIMapping() {
        #expect(ReasoningEffort.none.messagesAPI == nil)
        #expect(ReasoningEffort.minimal.messagesAPI == nil)
        #expect(ReasoningEffort.low.messagesAPI == "low")
        #expect(ReasoningEffort.xhigh.messagesAPI == "max")
        #expect(ReasoningEffort.ultra.messagesAPI == "max")
    }

    @Test("ReasoningSummary.none has no wire value")
    func reasoningSummaryNone() {
        #expect(ReasoningSummary.none.wireValue == nil)
        #expect(ReasoningSummary.detailed.wireValue == "detailed")
    }
}

// MARK: - Doom loop

@Suite("DoomLoop")
struct DoomLoopTests {
    @Test("clamp thresholds and retries")
    func clamps() {
        #expect(DoomLoopRecoveryPolicy.clampMaxThreshold(0) == 2)
        #expect(DoomLoopRecoveryPolicy.clampMaxThreshold(100) == 64)
        #expect(DoomLoopRecoveryPolicy.clampMaxRetries(0) == 0)
        #expect(DoomLoopRecoveryPolicy.clampMaxRetries(100) == 5)
    }
}
