// ProviderDriftTests.swift
//
// Provider-drift port coverage: DeepSeek direct + V4 Flash Responses dialect
// (Rust fb929feb, 3f83f287, 053409a8), OpenCode Go (1e2af500), Wafer AI
// (9b2742fd), the xAI client-version gate (631cee8c), and Codex Fast /
// priority service-tier routing (1b1e52df).

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokVersion

// MARK: - Provider identity and profiles

@Suite("Provider registry")
struct ProviderRegistryDriftTests {
    /// Provenance: Rust `provider.rs::tests::registry_covers_every_provider`.
    @Test("registry covers every built-in provider exactly once")
    func registryCoverage() {
        let expected: [ModelProvider] = [
            .xai, .codex, .kimi, .fireworks, .deepseek, .openCodeGo, .wafer,
        ]
        #expect(PROVIDER_REGISTRY.count == expected.count)
        for provider in expected {
            let entries = PROVIDER_REGISTRY.filter { $0.provider == provider }
            #expect(entries.count == 1, "\(provider.asString) must appear once")
            #expect(providerAdapter(provider).provider == provider)
        }
    }

    @Test("new provider identities carry their upstream wire names and aliases")
    func identityWireNames() throws {
        #expect(ModelProvider.deepseek.asString == "deepseek")
        #expect(ModelProvider.openCodeGo.asString == "opencode_go")
        #expect(ModelProvider.wafer.asString == "wafer")
        #expect(ModelProvider.deepseek.name == "DeepSeek")
        #expect(ModelProvider.openCodeGo.name == "OpenCode Go")
        #expect(ModelProvider.wafer.name == "Wafer AI")

        func decode(_ raw: String) throws -> ModelProvider {
            try JSONDecoder().decode(ModelProvider.self, from: Data("\"\(raw)\"".utf8))
        }
        #expect(try decode("deepseek") == .deepseek)
        #expect(try decode("deep_seek") == .deepseek)
        #expect(try decode("deepseek_api") == .deepseek)
        #expect(try decode("opencode_go") == .openCodeGo)
        #expect(try decode("opencode-go") == .openCodeGo)
        #expect(try decode("wafer") == .wafer)
        #expect(try decode("wafer_ai") == .wafer)
    }

    @Test("provider identities round-trip through their wire form")
    func identityRoundTrip() throws {
        for provider in [ModelProvider.deepseek, .openCodeGo, .wafer] {
            let data = try JSONEncoder().encode(provider)
            let back = try JSONDecoder().decode(ModelProvider.self, from: data)
            #expect(back == provider)
        }
    }

    /// The backend matrix is what makes DeepSeek V4 Flash routable to Responses
    /// while keeping OpenCode Go on Chat Completions / Messages.
    @Test("profiles declare the upstream backend matrix")
    func backendMatrix() {
        let deepseek = ProviderProfile.deepseek
        #expect(deepseek.supportsBackend(.chatCompletions))
        #expect(deepseek.supportsBackend(.responses))
        #expect(!deepseek.supportsBackend(.messages))
        #expect(deepseek.responsesDialect == .deepSeek)
        #expect(deepseek.hostedToolDialect == .openAi)
        #expect(deepseek.hasNativeWebSearch)
        #expect(deepseek.codeModeTransport == .functionEnvelope)

        let openCodeGo = ProviderProfile.openCodeGo
        #expect(openCodeGo.supportsBackend(.chatCompletions))
        #expect(!openCodeGo.supportsBackend(.responses))
        #expect(openCodeGo.supportsBackend(.messages))
        #expect(openCodeGo.hostedToolDialect == nil)
        #expect(!openCodeGo.hasNativeWebSearch)

        let wafer = ProviderProfile.wafer
        #expect(wafer.supportsBackend(.chatCompletions))
        #expect(!wafer.supportsBackend(.responses))
        #expect(!wafer.supportsBackend(.messages))
        #expect(wafer.hostedToolDialect == nil)
        #expect(!wafer.hasNativeWebSearch)
        #expect(wafer.codeModeTransport == .unsupported)
    }

    /// Every new provider is API-key-only, sends no `x-grok-*` metadata, and is
    /// denied xAI-only service paths.
    @Test("new providers are isolated from xAI session auth and services")
    func credentialAndServiceIsolation() {
        for profile in [ProviderProfile.deepseek, .openCodeGo, .wafer] {
            #expect(profile.sessionAuth == .apiKeyOnly)
            #expect(profile.requestMetadata == .standardHeadersOnly)
            #expect(!profile.allowsXaiServices)
            #expect(!providerAdapter(profile.provider).sendsDoomLoopOptIn)
        }
    }

    /// Provenance: Rust `deepseek_strips_internal_message_model_ids`.
    @Test("OpenAI-compatible providers strip internal per-message model_id")
    func stripInternalModelIDs() {
        for provider in [ModelProvider.deepseek, .openCodeGo, .wafer, .fireworks] {
            var request = ChatCompletionWireRequest(
                model: "some-model",
                messages: [
                    ChatRequestWireMessage(
                        role: .assistant,
                        content: .text("previous turn"),
                        modelId: "some-model"
                    ),
                ]
            )
            #expect(request.messages[0].modelId != nil)
            providerAdapter(provider).sanitizeChatRequest(&request)
            #expect(
                request.messages[0].modelId == nil,
                "\(provider.asString) must not replay internal model_id attribution"
            )
        }
    }

    /// Providers with `standardHeadersOnly` must have every `x-grok-*` header
    /// removed, including ones injected after client construction.
    @Test("x-grok headers never reach standard-headers-only providers")
    func xGrokHeaderSanitization() {
        for provider in [ModelProvider.deepseek, .openCodeGo, .wafer] {
            var headers = [
                "x-grok-conv-id": "c",
                "x-grok-client-version": "1.2.3",
                "authorization": "Bearer k",
            ]
            providerAdapter(provider).sanitizeHeaders(&headers)
            #expect(headers["x-grok-conv-id"] == nil)
            #expect(headers["x-grok-client-version"] == nil)
            #expect(headers["authorization"] == "Bearer k")
        }
    }
}

// MARK: - DeepSeek Responses dialect

@Suite("DeepSeek Responses dialect")
struct DeepSeekResponsesDialectTests {
    private func baseBody() -> JSONValue {
        .object([
            "model": .string("deepseek-v4-flash"),
            "input": .array([]),
            "stream": .bool(true),
            "store": .bool(true),
            "previous_response_id": .string("resp_1"),
            "prompt_cache_key": .string("session-1"),
            "service_tier": .string("priority"),
            "truncation": .string("auto"),
            "metadata": .object(["k": .string("v")]),
            "include": .array([.string("reasoning.encrypted_content")]),
        ])
    }

    /// DeepSeek's Responses endpoint is stateless: the OpenAI continuity and
    /// cache-control fields are silently ignored, so they must be omitted
    /// rather than implying a contract that does not exist.
    @Test("stateless fields are stripped from the DeepSeek Responses body")
    func stripsStatelessFields() {
        var body = baseBody()
        providerAdapter(.deepseek).patchResponsesRequest(
            &body,
            policy: ResponsesRequestPolicy()
        )
        for field in DEEPSEEK_UNSUPPORTED_RESPONSES_FIELDS {
            #expect(body[field] == nil, "\(field) must not reach DeepSeek")
        }
        // The payload itself survives.
        #expect(body["model"]?.stringValue == "deepseek-v4-flash")
        #expect(body["stream"]?.boolValue == true)
    }

    /// DeepSeek's documented Responses effort set is none/low/high/max, so Open
    /// Grok's wider menu is collapsed explicitly rather than passed through.
    @Test("reasoning effort collapses onto DeepSeek's documented menu")
    func effortMapping() {
        let cases: [(ReasoningEffort, String)] = [
            (.none, "none"),
            (.minimal, "low"),
            (.low, "low"),
            (.medium, "high"),
            (.high, "high"),
            (.xhigh, "high"),
            (.max, "max"),
            (.ultra, "max"),
        ]
        for (effort, expected) in cases {
            var body = JSONValue.object(["model": .string("deepseek-v4-flash")])
            providerAdapter(.deepseek).patchResponsesRequest(
                &body,
                policy: ResponsesRequestPolicy(localEffort: effort)
            )
            #expect(
                body["reasoning"]?["effort"]?.stringValue == expected,
                "\(effort.rawValue) must map to \(expected)"
            )
        }
    }

    /// DeepSeek accepts `reasoning.summary` for compatibility but never
    /// generates one, so sending it would advertise output that never arrives.
    @Test("reasoning summary is dropped and an emptied reasoning object removed")
    func dropsSummary() {
        var body = JSONValue.object([
            "model": .string("deepseek-v4-flash"),
            "reasoning": .object(["summary": .string("detailed")]),
        ])
        providerAdapter(.deepseek).patchResponsesRequest(
            &body,
            policy: ResponsesRequestPolicy(reasoningSummary: .detailed)
        )
        #expect(body["reasoning"] == nil, "an empty reasoning object is removed entirely")
    }

    @Test("summary is dropped but an effort still lands in the same object")
    func dropsSummaryKeepsEffort() {
        var body = JSONValue.object([
            "model": .string("deepseek-v4-flash"),
            "reasoning": .object(["summary": .string("detailed")]),
        ])
        providerAdapter(.deepseek).patchResponsesRequest(
            &body,
            policy: ResponsesRequestPolicy(localEffort: .high, reasoningSummary: .detailed)
        )
        #expect(body["reasoning"]?["summary"] == nil)
        #expect(body["reasoning"]?["effort"]?.stringValue == "high")
    }

    /// Codex's dialect owns prompt caching and sticky turn-state routing;
    /// DeepSeek's stateless dialect must claim neither.
    @Test("DeepSeek claims no prompt cache key and no turn state")
    func noCacheOrTurnState() {
        let adapter = providerAdapter(.deepseek)
        #expect(adapter.promptCacheKey(sessionId: "session-1") == nil)
        #expect(!adapter.supportsTurnState(backend: .responses))
        #expect(adapter.normalizesResponseEvents)
        // Unknown-event tolerance is a Codex-only allowance.
        #expect(
            !adapter.ignoresUnknownResponseEvent(
                error: .serialization("unknown"),
                data: #"{"type":"response.made_up"}"#
            )
        )
    }

    /// The Codex multi-agent developer message must not be injected into a
    /// DeepSeek request: it belongs to the Codex dialect's patch path.
    @Test("Codex multi-agent patching does not apply to DeepSeek")
    func noCodexMultiAgentInjection() {
        var body = JSONValue.object([
            "model": .string("deepseek-v4-flash"),
            "input": .array([
                .object(["role": .string("user"), "content": .string("hi")]),
            ]),
        ])
        providerAdapter(.deepseek).patchResponsesRequest(
            &body,
            policy: ResponsesRequestPolicy(multiAgentV2: true, localEffort: .ultra)
        )
        let input = try? #require(body["input"]?.arrayValue)
        #expect(input?.count == 1)
    }
}

// MARK: - xAI client version gate

@Suite("xAI client version gate")
struct XaiClientVersionTests {
    private func header(clientVersion: String?) -> String? {
        var headers: [String: String] = [:]
        let config = SamplerConfig(
            baseURL: "https://api.x.ai",
            model: "grok-4.5",
            provider: .xai,
            clientVersion: clientVersion
        )
        providerAdapter(.xai).applyDefaultHeaders(&headers, config: config)
        return headers["x-grok-client-version"]
    }

    /// Provenance: Rust `xai_client_version_header_always_present_and_base_semver`.
    /// xAI rejects an absent/unparseable version with 426; a Codex-parented
    /// subagent overriding to a Grok model resolves no session version, so the
    /// build's own version must be sent instead of nothing.
    @Test("a client version is always present and normalized to base semver")
    func alwaysPresentBaseSemVer() throws {
        let fallback = try #require(header(clientVersion: nil))
        #expect(!fallback.isEmpty)
        #expect(
            !fallback.contains("-"),
            "the fork pre-release suffix must be stripped for the gate parser: \(fallback)"
        )
        #expect(header(clientVersion: "0.1.220-open-grok.23") == "0.1.220")
        #expect(header(clientVersion: "0.1.230") == "0.1.230")
        #expect(header(clientVersion: "1.2.3+build.7") == "1.2.3")
    }

    @Test("an empty configured version still falls back to the build version")
    func emptyFallsBack() throws {
        let value = try #require(header(clientVersion: ""))
        #expect(!value.isEmpty)
        #expect(value == baseSemVerClientVersion(nil))
    }

    /// The gate is xAI's. Providers on `standardHeadersOnly` must not receive
    /// this header at all.
    @Test("the client version header stays off non-xAI providers")
    func notSentToOtherProviders() {
        for provider in [ModelProvider.codex, .deepseek, .openCodeGo, .wafer] {
            var headers: [String: String] = [:]
            let config = SamplerConfig(
                baseURL: "https://example.invalid",
                model: "m",
                provider: provider,
                clientVersion: "0.1.220-open-grok.23"
            )
            providerAdapter(provider).applyDefaultHeaders(&headers, config: config)
            #expect(headers["x-grok-client-version"] == nil)
        }
    }
}

// MARK: - Service tier / Fast routing

@Suite("Codex Fast service-tier routing")
struct ServiceTierRoutingTests {
    /// Standard routing is the absence of the field, not `"default"`.
    @Test("service tier normalizes to its wire value")
    func normalization() {
        #expect(normalizedServiceTier(nil) == nil)
        #expect(normalizedServiceTier("") == nil)
        #expect(normalizedServiceTier("   ") == nil)
        #expect(normalizedServiceTier("default") == nil)
        #expect(normalizedServiceTier("Default") == nil)
        #expect(normalizedServiceTier("fast") == "priority")
        #expect(normalizedServiceTier("FAST") == "priority")
        #expect(normalizedServiceTier("priority") == "priority")
        #expect(normalizedServiceTier("flex") == "flex")
    }

    /// Provenance: Rust `service_tier_to_responses_api`.
    @Test("catalog ids map to the Responses service-tier enum")
    func responsesAPIMapping() {
        #expect(serviceTierToResponsesAPI("auto") == .auto)
        #expect(serviceTierToResponsesAPI("default") == .default)
        #expect(serviceTierToResponsesAPI("flex") == .flex)
        #expect(serviceTierToResponsesAPI("scale") == .scale)
        #expect(serviceTierToResponsesAPI("priority") == .priority)
        #expect(serviceTierToResponsesAPI("fast") == .priority)
        #expect(serviceTierToResponsesAPI("nonsense") == nil)
    }

    @Test("a model advertising a Fast tier is detected from its meta")
    func fastTierDetection() {
        let meta: [String: JSONValue] = [
            SERVICE_TIERS_META_KEY: .array([
                .object(["id": .string("default"), "name": .string("Standard")]),
                .object(["id": .string("priority"), "name": .string("Fast")]),
            ]),
        ]
        #expect(supportsFastServiceTierMeta(meta))
        #expect(parseServiceTiersMeta(meta)?.count == 2)

        let withoutFast: [String: JSONValue] = [
            SERVICE_TIERS_META_KEY: .array([
                .object(["id": .string("flex"), "name": .string("Flex")]),
            ]),
        ]
        #expect(!supportsFastServiceTierMeta(withoutFast))
        #expect(!supportsFastServiceTierMeta(nil))
    }

    @Test("a blank tier name falls back to its id and blank ids are dropped")
    func tierParsingEdges() {
        let meta: [String: JSONValue] = [
            SERVICE_TIERS_META_KEY: .array([
                .object(["id": .string("priority"), "name": .string("  ")]),
                .object(["id": .string("  "), "name": .string("Ignored")]),
            ]),
        ]
        let tiers = parseServiceTiersMeta(meta)
        #expect(tiers?.count == 1)
        #expect(tiers?.first?.id == "priority")
        #expect(tiers?.first?.name == "priority")
        #expect(tiers?.first?.isFast == true)
    }

    /// `nil` preserves a prior selection; `.some(nil)` is explicit standard
    /// routing. Collapsing the two would make `/fast` untoggleable.
    @Test("selection meta distinguishes absent from explicit standard routing")
    func selectionMeta() {
        #expect(parseServiceTierMeta(nil) == nil)
        #expect(parseServiceTierMeta([:]) == nil)

        let explicitDefault = parseServiceTierMeta([SERVICE_TIER_META_KEY: .string("default")])
        #expect(explicitDefault != nil)
        #expect(explicitDefault! == nil)

        let empty = parseServiceTierMeta([SERVICE_TIER_META_KEY: .string("  ")])
        #expect(empty != nil)
        #expect(empty! == nil)

        let priority = parseServiceTierMeta([SERVICE_TIER_META_KEY: .string("priority")])
        #expect(priority ?? nil == "priority")

        // A non-string value is malformed meta, not a selection.
        #expect(parseServiceTierMeta([SERVICE_TIER_META_KEY: .bool(true)]) == nil)
    }

    /// The wire effect of the `/fast` toggle: `service_tier: "priority"` on the
    /// Codex Responses body.
    @Test("a selected tier reaches the Responses wire body")
    func tierReachesWireBody() {
        var request = ConversationRequest(
            items: [],
            model: "gpt-5-codex",
            serviceTier: "priority"
        )
        let body = projectResponsesRequestBody(
            request,
            model: "gpt-5-codex",
            policy: ResponsesRequestPolicy(),
            adapter: providerAdapter(.codex)
        )
        #expect(body["service_tier"]?.stringValue == "priority")

        request.serviceTier = "default"
        let standard = projectResponsesRequestBody(
            request,
            model: "gpt-5-codex",
            policy: ResponsesRequestPolicy(),
            adapter: providerAdapter(.codex)
        )
        #expect(standard["service_tier"] == nil, "standard routing omits the field")
    }

    /// DeepSeek's stateless dialect strips `service_tier`, so a Fast selection
    /// inherited from another provider cannot leak onto a DeepSeek request.
    @Test("a service tier never survives onto a DeepSeek request")
    func tierStrippedForDeepSeek() {
        let request = ConversationRequest(
            items: [],
            model: "deepseek-v4-flash",
            serviceTier: "priority"
        )
        let body = projectResponsesRequestBody(
            request,
            model: "deepseek-v4-flash",
            policy: ResponsesRequestPolicy(),
            adapter: providerAdapter(.deepseek)
        )
        #expect(body["service_tier"] == nil)
    }

    @Test("the sampler config default fills an unset request tier")
    func configDefault() throws {
        let config = SamplerConfig(
            baseURL: "https://chatgpt.com/backend-api/codex",
            model: "gpt-5-codex",
            apiBackend: .responses,
            provider: .codex,
            serviceTier: "priority"
        )
        let defaults = SamplingClientDefaults(from: config)
        #expect(defaults.serviceTier == "priority")

        // The field also round-trips through the config's wire form.
        let data = try JSONEncoder().encode(config)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["service_tier"] as? String == "priority")
        let back = try JSONDecoder().decode(SamplerConfig.self, from: data)
        #expect(back.serviceTier == "priority")
    }
}
