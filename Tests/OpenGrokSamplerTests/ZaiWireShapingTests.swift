// ZaiWireShapingTests.swift
//
// Z AI Chat Completions wire shaping tests, matching upstream provider tests
// in `crates/codegen/xai-grok-sampler/src/provider.rs`.

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokSamplingTypes

@Suite("Z AI wire shaping")
struct ZaiWireShapingTests {
    @Test("ZaiProvider strips serviceTier and message modelId")
    func zaiStripsInternalMetadata() {
        var msg = ChatRequestWireMessage.user("Hello")
        msg.modelId = "some-internal-id"
        var request = ChatCompletionWireRequest(
            model: "glm-5",
            messages: [msg],
            serviceTier: "priority"
        )

        let adapter = providerAdapter(.zai)
        adapter.sanitizeChatRequest(&request)

        #expect(request.serviceTier == nil)
        #expect(request.messages[0].modelId == nil)
        #expect(request.thinking == nil)
    }

    @Test("ZaiProvider enables thinking mode when reasoningEffort is present")
    func zaiEnablesThinkingWhenEffortPresent() throws {
        var request = ChatCompletionWireRequest(
            model: "glm-5",
            messages: [.user("Solve this")],
            reasoningEffort: .high
        )

        let adapter = providerAdapter(.zai)
        adapter.sanitizeChatRequest(&request)

        #expect(request.thinking == .enabled)
        #expect(request.reasoningEffort == .high)

        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let thinkingObj = try #require(json["thinking"] as? [String: Any])
        #expect(thinkingObj["type"] as? String == "enabled")
        #expect(thinkingObj["clear_thinking"] as? Bool == false)
        #expect(json["reasoning_effort"] as? String == "high")
    }

    @Test("ZaiProvider omits thinking when reasoningEffort is absent")
    func zaiOmitsThinkingWhenEffortAbsent() throws {
        var request = ChatCompletionWireRequest(
            model: "glm-4.7",
            messages: [.user("Hello")],
            reasoningEffort: nil
        )

        let adapter = providerAdapter(.zai)
        adapter.sanitizeChatRequest(&request)

        #expect(request.thinking == nil)
        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["thinking"] == nil)
    }
}
