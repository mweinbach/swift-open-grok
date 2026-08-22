// ExpandedProviderWireParityTests.swift
//
// Ports RunInfra, Gemini, and OpenRouter contracts from upstream
// `xai-grok-sampler/src/provider.rs:513-608` and OpenRouter attribution from
// `xai-grok-shell/src/openrouter_models.rs:19-25,84-94`.

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared

@Suite("Expanded provider wire parity")
struct ExpandedProviderWireParityTests {
    private let expandedProviders: [ModelProvider] = [.runinfra, .gemini, .openRouter]

    private func wireRequest(
        model: String,
        effort: ReasoningEffort?,
        thinking: ChatThinkingMode? = .enabled
    ) -> ChatCompletionWireRequest {
        ChatCompletionWireRequest(
            model: model,
            messages: [
                ChatRequestWireMessage(
                    role: .assistant,
                    content: .text("previous turn"),
                    modelId: "private-model-attribution"
                ),
            ],
            temperature: 0.7,
            topP: 0.9,
            tools: [
                .function(
                    name: "read_file",
                    description: "Read a file",
                    parameters: .object(["type": .string("object")])
                ),
            ],
            reasoningEffort: effort,
            thinking: thinking,
            serviceTier: "priority"
        )
    }

    private func response() -> MockHTTPTransport.ScriptedResponse {
        let chunk = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"test","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
        return .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            ),
            body: Data("data: \(chunk)\n\ndata: [DONE]\n\n".utf8)
        )
    }

    @Test("canonical provider names and aliases round-trip case-insensitively")
    func canonicalNamesAndAliases() throws {
        let cases: [(String, ModelProvider)] = [
            ("runinfra", .runinfra),
            ("RUN_INFRA", .runinfra),
            ("Run-Infra", .runinfra),
            ("gemini", .gemini),
            ("GOOGLE", .gemini),
            ("google_gemini", .gemini),
            ("AI_STUDIO", .gemini),
            ("aistudio", .gemini),
            ("gemini_api", .gemini),
            ("openrouter", .openRouter),
            ("OPEN_ROUTER", .openRouter),
            ("Open-Router", .openRouter),
        ]

        for (raw, expected) in cases {
            let decoded = try JSONDecoder().decode(
                ModelProvider.self,
                from: Data("\"\(raw)\"".utf8)
            )
            #expect(decoded == expected)
            let encoded = try JSONEncoder().encode(decoded)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(expected.asString)\"")
        }
    }

    @Test("expanded providers remain API-key-only Chat Completions adapters")
    func backendAndServiceIsolation() throws {
        for provider in expandedProviders {
            let adapter = providerAdapter(provider)
            let profile = adapter.profile

            try adapter.validateBackend(.chatCompletions)
            #expect(throws: SamplingError.self) { try adapter.validateBackend(.responses) }
            #expect(throws: SamplingError.self) { try adapter.validateBackend(.messages) }
            #expect(profile.sessionAuth == .apiKeyOnly)
            #expect(profile.requestMetadata == .standardHeadersOnly)
            #expect(profile.codeModeTransport == .unsupported)
            #expect(profile.hostedToolDialect == nil)
            #expect(!profile.hasNativeWebSearch)
            #expect(!profile.allowsXaiServices)
            #expect(!adapter.sendsDoomLoopOptIn)
            #expect(!adapter.normalizesResponseEvents)
            #expect(!adapter.supportsTurnState(backend: .responses))
            #expect(adapter.promptCacheKey(sessionId: "session") == nil)
        }
    }

    @Test("provider sanitizers remove private routing while retaining client tools")
    func sanitizeRoutingAndPreserveFunctionTools() {
        for provider in expandedProviders {
            var request = wireRequest(model: "some-model", effort: .medium)
            let originalTools = request.tools

            providerAdapter(provider).sanitizeChatRequest(&request)

            #expect(request.serviceTier == nil)
            #expect(request.messages.first?.modelId == nil)
            #expect(request.temperature == 0.7)
            #expect(request.topP == 0.9)
            #expect(request.tools == originalTools)
            #expect(request.reasoningEffort == .medium)
            if provider == .runinfra {
                #expect(request.thinking == ChatThinkingMode.enabled)
            } else {
                #expect(request.thinking == nil)
            }
        }
    }

    @Test("RunInfra DeepSeek V4 Flash maps only high-family efforts to max")
    func runinfraDeepSeekEffortNormalization() {
        let cases: [(ReasoningEffort, ReasoningEffort)] = [
            (.none, .none),
            (.minimal, .minimal),
            (.low, .low),
            (.medium, .medium),
            (.high, .max),
            (.xhigh, .max),
            (.max, .max),
            (.ultra, .max),
        ]

        for (effort, expected) in cases {
            var request = wireRequest(model: "deepseek-v4-flash", effort: effort)
            providerAdapter(.runinfra).sanitizeChatRequest(&request)
            #expect(request.reasoningEffort == expected, "\(effort) must map to \(expected)")
        }
    }

    @Test("RunInfra preserves reasoning levels on every other model")
    func runinfraOtherModelsKeepTheirEffort() {
        for model in ["qwen3-8-27b", "deepseek-v4-flash-preview", "DEEPSEEK-V4-FLASH"] {
            var request = wireRequest(model: model, effort: .high)
            providerAdapter(.runinfra).sanitizeChatRequest(&request)
            #expect(request.reasoningEffort == .high)
        }

        var requestWithoutEffort = wireRequest(model: "deepseek-v4-flash", effort: nil)
        providerAdapter(.runinfra).sanitizeChatRequest(&requestWithoutEffort)
        #expect(requestWithoutEffort.reasoningEffort == nil)
    }

    @Test("Gemini converts unsupported reasoning efforts without losing valid levels")
    func geminiEffortNormalization() {
        let cases: [(ReasoningEffort, ReasoningEffort?)] = [
            (.none, nil),
            (.minimal, .minimal),
            (.low, .low),
            (.medium, .medium),
            (.high, .high),
            (.xhigh, .high),
            (.max, .high),
            (.ultra, .high),
        ]

        for (effort, expected) in cases {
            var request = wireRequest(model: "gemini-3.6-flash-lite", effort: effort)
            providerAdapter(.gemini).sanitizeChatRequest(&request)
            #expect(request.reasoningEffort == expected)
            #expect(request.thinking == nil)
        }
    }

    @Test("only Gemini 3.7 Flash and Gemini 3.1 Pro reject minimal reasoning")
    func geminiMinimalIsModelSpecific() {
        let cases: [(String, ReasoningEffort)] = [
            ("gemini-3.7-flash", .low),
            ("gemini-3.1-pro-preview", .low),
            ("gemini-3.6-flash-lite", .minimal),
            ("gemini-3.1-flash-lite-preview", .minimal),
            ("gemini-3.7-flash-preview", .minimal),
        ]

        for (model, expected) in cases {
            var request = wireRequest(model: model, effort: .minimal)
            providerAdapter(.gemini).sanitizeChatRequest(&request)
            #expect(request.reasoningEffort == expected, "\(model) must keep its own menu")
        }
    }

    @Test("OpenRouter keeps reasoning effort but removes foreign thinking and routing")
    func openRouterReasoningAndThinkingIsolation() {
        for effort in [ReasoningEffort.none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra] {
            var request = wireRequest(model: "anthropic/claude-sonnet", effort: effort)
            providerAdapter(.openRouter).sanitizeChatRequest(&request)

            #expect(request.reasoningEffort == effort)
            #expect(request.thinking == nil)
            #expect(request.serviceTier == nil)
            #expect(request.messages.first?.modelId == nil)
            #expect(request.tools?.first?.function.name == "read_file")
        }
    }

    @Test("OpenRouter inference adds attribution while stripping forged x-grok headers")
    func openRouterAttributionDefaults() {
        var headers = [
            "Authorization": "Bearer openrouter-key",
            "X-GROK-SESSION-ID": "must-not-leak",
        ]
        providerAdapter(.openRouter).applyDefaultHeaders(
            &headers,
            config: SamplerConfig(provider: .openRouter)
        )

        #expect(headers["Authorization"] == "Bearer openrouter-key")
        #expect(headers["HTTP-Referer"] == "https://github.com/mweinbach/open-grok")
        #expect(headers["X-Title"] == "Open Grok")
        #expect(headers["X-GROK-SESSION-ID"] == nil)
    }

    @Test("OpenRouter attribution never overwrites case-insensitive caller overrides")
    func openRouterAttributionPreservesOverrides() {
        var headers = [
            "http-referer": "https://caller.example.test",
            "x-TITLE": "Caller Application",
        ]
        providerAdapter(.openRouter).applyDefaultHeaders(
            &headers,
            config: SamplerConfig(provider: .openRouter)
        )

        #expect(headers["http-referer"] == "https://caller.example.test")
        #expect(headers["x-TITLE"] == "Caller Application")
        #expect(headers["HTTP-Referer"] == nil)
        #expect(headers["X-Title"] == nil)
        #expect(headers.count == 2)
    }

    @Test("RunInfra and Gemini do not inherit OpenRouter attribution")
    func attributionRemainsProviderLocal() {
        for provider in [ModelProvider.runinfra, .gemini] {
            var headers: [String: String] = ["Authorization": "Bearer test"]
            providerAdapter(provider).applyDefaultHeaders(
                &headers,
                config: SamplerConfig(provider: provider)
            )

            #expect(headers["HTTP-Referer"] == nil)
            #expect(headers["X-Title"] == nil)
            #expect(headers["Authorization"] == "Bearer test")
        }
    }

    @Test("live sampler applies provider-specific contracts to actual HTTP requests")
    func liveSamplerProviderWire() async throws {
        let cases: [(ModelProvider, String, ReasoningEffort, String)] = [
            (.runinfra, "deepseek-v4-flash", .high, "max"),
            (.gemini, "gemini-3.7-flash", .minimal, "low"),
            (.openRouter, "anthropic/claude-sonnet", .ultra, "ultra"),
        ]

        for (provider, model, effort, expectedEffort) in cases {
            let transport = MockHTTPTransport(responses: [response()])
            let client = try SamplingClient(
                config: SamplerConfig(
                    apiKey: "provider-key",
                    baseURL: "https://\(provider.asString).example.test/custom/v1",
                    model: model,
                    apiBackend: .chatCompletions,
                    provider: provider,
                    extraHeaders: [
                        (name: "X-GROK-USER-ID", value: "forged-user"),
                        (name: "X-CODEX-TURN-STATE", value: "forged-turn"),
                    ],
                    serviceTier: "priority"
                ),
                transport: transport
            )

            let result = try await client.conversationCollect(
                ConversationRequest(
                    items: [
                        .assistant(AssistantItem(content: "previous", modelId: "private-model")),
                        .user("hello"),
                    ],
                    tools: [
                        ToolSpec(
                            name: "read_file",
                            description: "Read a file",
                            parameters: .object(["type": .string("object")])
                        ),
                    ],
                    temperature: 0.7,
                    topP: 0.9,
                    xGrokSessionId: "private-session",
                    reasoningEffort: effort,
                    serviceTier: "priority"
                ),
                idleTimeout: .seconds(30)
            )

            #expect(result.assistantText() == "ok")
            let recorded = try #require(transport.recordedRequests.first)
            #expect(
                recorded.url.absoluteString
                    == "https://\(provider.asString).example.test/custom/v1/chat/completions"
            )
            #expect(recorded.headers["Authorization"] == "Bearer provider-key")
            #expect(recorded.headers.keys.allSatisfy { !$0.lowercased().hasPrefix("x-grok-") })
            #expect(recorded.headers["X-CODEX-TURN-STATE"] == nil)
            #expect(recorded.headers[CODEX_SESSION_ID_HEADER] == nil)

            let body = try JSONDecoder().decode(
                JSONValue.self,
                from: try #require(recorded.body)
            )
            #expect(body["model"]?.stringValue == model)
            #expect(body["reasoning_effort"]?.stringValue == expectedEffort)
            #expect(body["service_tier"] == nil)
            #expect(body["thinking"] == nil)
            #expect(body["messages"]?.arrayValue?.first?["model_id"] == nil)
            #expect(body["tools"]?.arrayValue?.first?["function"]?["name"]?.stringValue == "read_file")

            if provider == .openRouter {
                #expect(recorded.headers["HTTP-Referer"] == OpenRouterProvider.httpReferer)
                #expect(recorded.headers["X-Title"] == OpenRouterProvider.appTitle)
            } else {
                #expect(recorded.headers["HTTP-Referer"] == nil)
                #expect(recorded.headers["X-Title"] == nil)
            }
        }
    }

    @Test("live Gemini omits disabled thinking instead of sending rejected none")
    func liveGeminiOmitsNoneEffort() async throws {
        let transport = MockHTTPTransport(responses: [response()])
        let client = try SamplingClient(
            config: SamplerConfig(
                apiKey: "gemini-key",
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                model: "gemini-3.7-flash",
                apiBackend: .chatCompletions,
                provider: .gemini
            ),
            transport: transport
        )

        let result = try await client.conversationCollect(
            ConversationRequest(items: [.user("hello")], reasoningEffort: ReasoningEffort.none),
            idleTimeout: .seconds(30)
        )

        #expect(result.assistantText() == "ok")
        let recorded = try #require(transport.recordedRequests.first)
        #expect(
            recorded.url.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(recorded.body))
        #expect(body["reasoning_effort"] == nil)
        #expect(body["thinking"] == nil)
    }
}
