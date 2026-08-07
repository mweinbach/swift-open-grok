// ResponsesStoreIncludeTests.swift
//
// Pins the sampling client's Responses-body defaults against upstream's
// `apply_response_defaults` (xai-grok-sampler client.rs:2453-2462): every
// streamed Responses request carries `store: false` and
// `include: ["reasoning.encrypted_content"]`, inserted BEFORE the dialect
// patchers so DeepSeek/Meta can strip them (upstream order client.rs:2649 →
// :2703). The missing `store: false` is the offline-provable divergence
// behind a live Codex 400 after a mid-session `/model` switch — the OpenAI
// default of `store: true` is exactly what upstream's comment calls out as
// unacceptable.

import Foundation
import Testing
import OpenGrokShared
import OpenGrokSamplingTypes
@testable import OpenGrokSampler

private let encryptedContentInclude = "reasoning.encrypted_content"

private func responsesBody(
    provider: ModelProvider,
    applyResponseDefaults: Bool,
    hostedTools: [HostedTool] = []
) -> JSONValue {
    projectResponsesRequestBody(
        ConversationRequest(items: [.user("hello")], hostedTools: hostedTools),
        model: "test-model",
        policy: ResponsesRequestPolicy(),
        adapter: providerAdapter(provider),
        applyResponseDefaults: applyResponseDefaults
    )
}

@Suite("Responses store/include defaults")
struct ResponsesStoreIncludeTests {
    @Test("the Codex sampling body carries store:false and the encrypted-reasoning include")
    func codexBodyCarriesDefaults() {
        let body = responsesBody(provider: .codex, applyResponseDefaults: true)
        #expect(body["store"]?.boolValue == false)
        #expect(body["include"] == .array([.string(encryptedContentInclude)]))
    }

    @Test("the xAI Responses body carries the same defaults")
    func xaiBodyCarriesDefaults() {
        // Upstream applies the defaults for every Responses-backend provider
        // and the xAI patcher does not strip them (client.rs:2453-2462).
        let body = responsesBody(provider: .xai, applyResponseDefaults: true)
        #expect(body["store"]?.boolValue == false)
        #expect(body["include"] == .array([.string(encryptedContentInclude)]))
    }

    @Test("DeepSeek and Meta strip the defaults after they are applied")
    func statelessDialectsStripDefaults() {
        // The insertion has to run before the adapter patch — flipping the
        // order re-sends `store`/`include` to the stateless providers whose
        // patchers exist to remove them (provider.rs:661-686, :717-726).
        for provider in [ModelProvider.deepseek, .meta] {
            let body = responsesBody(provider: provider, applyResponseDefaults: true)
            #expect(body["store"] == nil, "\(provider.asString) must not carry store")
            #expect(body["include"] == nil, "\(provider.asString) must not carry include")
        }
    }

    @Test("without the opt-in the projection stays untouched for compaction bodies")
    func compactionShapeUnchangedWithoutOptIn() {
        // The Codex compaction transports own their contract fields
        // themselves (client.rs:2133-2140 for remote v2; the legacy compact
        // endpoint forbids both, client.rs test at :3816-3824).
        let body = responsesBody(provider: .codex, applyResponseDefaults: false)
        #expect(body["store"] == nil)
        #expect(body["include"] == nil)
    }

    @Test("the Codex dialect grants web_search live access")
    func codexWebSearchGetsExternalWebAccess() {
        let body = responsesBody(
            provider: .codex,
            applyResponseDefaults: true,
            hostedTools: [.webSearch(
                mode: nil,
                allowedDomains: nil,
                userLocation: nil,
                searchContextSize: nil,
                searchContentTypes: nil
            )]
        )
        let webSearch = body["tools"]?.arrayValue?.first {
            $0["type"]?.stringValue == "web_search"
        }
        // provider.rs:594-607: Codex sandboxes `web_search` unless the
        // request opts into live sources.
        #expect(webSearch?["external_web_access"]?.boolValue == true)
    }

    @Test("an explicit external_web_access override is left untouched")
    func codexWebSearchKeepsExplicitOverride() {
        var body = JSONValue.object([
            "model": .string("gpt-5.6-sol"),
            "input": .array([]),
            "tools": .array([
                .object([
                    "type": .string("web_search"),
                    "external_web_access": .bool(false),
                ]),
            ]),
        ])
        patchCodexResponsesRequest(&body, policy: ResponsesRequestPolicy())
        let webSearch = body["tools"]?.arrayValue?.first {
            $0["type"]?.stringValue == "web_search"
        }
        #expect(webSearch?["external_web_access"]?.boolValue == false)
    }
}
