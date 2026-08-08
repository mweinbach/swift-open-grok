// ServiceTierChatWireTests.swift
//
// The Chat Completions half of the service tier (the Responses half is in
// ProviderDriftTests). Upstream carries `service_tier` on the chat request
// (types.rs:89-90), backfills it from the client defaults in `apply_defaults`
// (client.rs:1806-1808), forwards it unchanged for Fireworks
// (provider.rs:1090-1102 pins this), and strips it for Kimi, DeepSeek,
// OpenCode Go, and Wafer (provider.rs:338, :386, :411, :426). Before this
// coverage the port's chat wire type had NO `service_tier` field at all, so
// `/fast` on a chat-backend model would have "worked" while sending nothing.

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokSamplingTypes

@Suite("Service tier on the Chat Completions wire")
struct ServiceTierChatWireTests {
    @Test("the chat projection carries the config tier onto the wire body")
    func chatProjectionCarriesTier() throws {
        let config = SamplerConfig(
            baseURL: "https://api.fireworks.ai/inference/v1",
            model: "accounts/fireworks/models/glm-5p2",
            apiBackend: .chatCompletions,
            provider: .fireworks,
            serviceTier: "priority"
        )
        let request = ConversationRequest(items: [.user("hello")])
        let wire = projectChatCompletionRequest(
            request,
            defaults: SamplingClientDefaults(from: config)
        )
        #expect(wire.serviceTier == "priority")

        // The exact JSON field name upstream serializes (types.rs:89-90).
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
        )
        #expect(object["service_tier"] as? String == "priority")
    }

    @Test("standard routing omits the field and the fast alias normalizes")
    func chatProjectionNormalizes() throws {
        // "default" is not a wire value — standard routing is the absence of
        // the field (SERVICE_TIER_DEFAULT_REQUEST_VALUE normalization).
        let standard = projectChatCompletionRequest(
            ConversationRequest(items: [.user("hello")], serviceTier: "default")
        )
        #expect(standard.serviceTier == nil)
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(standard)
            ) as? [String: Any]
        )
        #expect(object["service_tier"] == nil)

        // "fast" is the display alias; the wire spelling is "priority".
        let aliased = projectChatCompletionRequest(
            ConversationRequest(items: [.user("hello")], serviceTier: "fast")
        )
        #expect(aliased.serviceTier == "priority")
    }

    /// Provenance: Rust `fireworks_forwards_standard_sampling_parameters_unchanged`
    /// (provider.rs:1089-1102) — Fireworks keeps the tier; that is what makes
    /// `/fast` honest on the curated Fireworks models.
    @Test("Fireworks sanitize forwards the tier unchanged")
    func fireworksForwardsTier() {
        var request = ChatCompletionWireRequest(
            model: "accounts/fireworks/models/glm-5p2",
            serviceTier: "priority"
        )
        providerAdapter(.fireworks).sanitizeChatRequest(&request)
        #expect(request.serviceTier == "priority")
    }

    /// Provenance: Rust Kimi/DeepSeek/OpenCodeGo/Wafer sanitize arms
    /// (provider.rs:338, :386, :411, :426) — a Fast selection inherited from
    /// another provider must not leak onto these wires.
    @Test("Kimi, DeepSeek, OpenCode Go, and Wafer strip the tier")
    func providerOwnedRoutingStripsTier() {
        for provider in [ModelProvider.kimi, .deepseek, .openCodeGo, .wafer] {
            var request = ChatCompletionWireRequest(
                model: "some-model",
                serviceTier: "priority"
            )
            providerAdapter(provider).sanitizeChatRequest(&request)
            #expect(
                request.serviceTier == nil,
                "\(provider.asString) must not forward service_tier"
            )
        }
    }
}
