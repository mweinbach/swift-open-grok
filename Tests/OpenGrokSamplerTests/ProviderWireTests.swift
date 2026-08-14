// ProviderWireTests.swift
//
// Comprehensive wire policy and dialect tests for all 9 model providers in Open Grok:
// xAI, OpenAI Codex, Kimi, Fireworks AI, DeepSeek, Meta, OpenCode Go, Wafer AI, and Z AI.
// Mirrors Rust `xai-grok-sampling-types/src/types.rs` and `xai-grok-sampler/src/provider.rs`.

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokVersion

// MARK: - 1. ProviderProfile Configurations for all 9 providers

@Suite("ProviderProfile 9-Provider Matrix Tests")
struct ProviderProfileMatrixTests {
    struct ExpectedProfile {
        let provider: ModelProvider
        let id: String
        let name: String
        let backends: ProviderBackends
        let codeModeTransport: CodeModeTransport
        let hostedTools: HostedToolDialect?
        let nativeWebSearch: Bool
        let requestMetadata: RequestMetadataPolicy
        let sessionAuth: BuiltInSessionAuthKind
        let xaiServices: XaiServicePolicy
    }

    let allCases: [ExpectedProfile] = [
        ExpectedProfile(
            provider: .xai,
            id: "xai",
            name: "xAI",
            backends: ProviderBackends(chatCompletions: true, responses: .xai, messages: true),
            codeModeTransport: .functionEnvelope,
            hostedTools: .xai,
            nativeWebSearch: true,
            requestMetadata: .xGrokHeaders,
            sessionAuth: .xaiSession,
            xaiServices: .allowed
        ),
        ExpectedProfile(
            provider: .codex,
            id: "codex",
            name: "OpenAI Codex",
            backends: ProviderBackends(chatCompletions: false, responses: .codex, messages: false),
            codeModeTransport: .nativeCustomGrammar,
            hostedTools: .openAi,
            nativeWebSearch: true,
            requestMetadata: .standardHeadersOnly,
            sessionAuth: .codexOAuth,
            xaiServices: .denied
        ),
        ExpectedProfile(
            provider: .kimi,
            id: "kimi",
            name: "Kimi",
            backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
            codeModeTransport: .unsupported,
            hostedTools: nil,
            nativeWebSearch: false,
            requestMetadata: .standardHeadersOnly,
            sessionAuth: .apiKeyOnly,
            xaiServices: .denied
        ),
        ExpectedProfile(
            provider: .fireworks,
            id: "fireworks",
            name: "Fireworks AI",
            backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
            codeModeTransport: .unsupported,
            hostedTools: nil,
            nativeWebSearch: false,
            requestMetadata: .standardHeadersOnly,
            sessionAuth: .apiKeyOnly,
            xaiServices: .denied
        ),
        ExpectedProfile(
            provider: .deepseek,
            id: "deepseek",
            name: "DeepSeek",
            backends: ProviderBackends(chatCompletions: true, responses: .deepSeek, messages: false),
            codeModeTransport: .functionEnvelope,
            hostedTools: .openAi,
            nativeWebSearch: true,
            requestMetadata: .standardHeadersOnly,
            sessionAuth: .apiKeyOnly,
            xaiServices: .denied
        ),
        ExpectedProfile(
            provider: .meta,
            id: "meta",
            name: "Meta API",
            backends: ProviderBackends(chatCompletions: false, responses: .meta, messages: false),
            codeModeTransport: .functionEnvelope,
            hostedTools: .openAi,
            nativeWebSearch: true,
            requestMetadata: .standardHeadersOnly,
            sessionAuth: .apiKeyOnly,
            xaiServices: .denied
        ),
        ExpectedProfile(
            provider: .openCodeGo,
            id: "opencode_go",
            name: "OpenCode Go",
            backends: ProviderBackends(chatCompletions: true, responses: nil, messages: true),
            codeModeTransport: .unsupported,
            hostedTools: nil,
            nativeWebSearch: false,
            requestMetadata: .standardHeadersOnly,
            sessionAuth: .apiKeyOnly,
            xaiServices: .denied
        ),
        ExpectedProfile(
            provider: .wafer,
            id: "wafer",
            name: "Wafer AI",
            backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
            codeModeTransport: .unsupported,
            hostedTools: nil,
            nativeWebSearch: false,
            requestMetadata: .standardHeadersOnly,
            sessionAuth: .apiKeyOnly,
            xaiServices: .denied
        ),
        ExpectedProfile(
            provider: .zai,
            id: "zai",
            name: "Z AI",
            backends: ProviderBackends(chatCompletions: true, responses: nil, messages: false),
            codeModeTransport: .unsupported,
            hostedTools: nil,
            nativeWebSearch: false,
            requestMetadata: .standardHeadersOnly,
            sessionAuth: .apiKeyOnly,
            xaiServices: .denied
        ),
    ]

    @Test("all 9 provider profiles match exact requirements")
    func verifyAllNineProfiles() {
        #expect(allCases.count == 9)

        for item in allCases {
            let profile = item.provider.profile
            #expect(profile.provider == item.provider)
            #expect(profile.id == item.id)
            #expect(profile.name == item.name)
            #expect(profile.backends == item.backends)
            #expect(profile.codeModeTransport == item.codeModeTransport)
            #expect(profile.hostedToolDialect == item.hostedTools)
            #expect(profile.nativeWebSearch == item.nativeWebSearch)
            #expect(profile.hasNativeWebSearch == item.nativeWebSearch)
            #expect(profile.requestMetadata == item.requestMetadata)
            #expect(profile.sessionAuth == item.sessionAuth)
            #expect(profile.xaiServices == item.xaiServices)
            #expect(profile.allowsXaiServices == (item.xaiServices == .allowed))
            #expect(profile.responsesDialect == item.backends.responses)

            // Verify boolean identity flags
            #expect(profile.isXai == (item.provider == .xai))
            #expect(profile.isCodex == (item.provider == .codex))
            #expect(profile.isKimi == (item.provider == .kimi))
            #expect(profile.isFireworks == (item.provider == .fireworks))
            #expect(profile.isDeepSeek == (item.provider == .deepseek))
            #expect(profile.isMeta == (item.provider == .meta))
            #expect(profile.isOpenCodeGo == (item.provider == .openCodeGo))
            #expect(profile.isWafer == (item.provider == .wafer))
            #expect(profile.isZai == (item.provider == .zai))

            // Verify backend support matrix matches
            #expect(profile.supportsBackend(.chatCompletions) == item.backends.chatCompletions)
            #expect(profile.supportsBackend(.responses) == (item.backends.responses != nil))
            #expect(profile.supportsBackend(.messages) == item.backends.messages)
        }
    }

    @Test("all 9 provider profiles round-trip through JSON encoding/decoding")
    func verifyProfileSerialization() throws {
        for item in allCases {
            let profile = item.provider.profile
            let data = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(ProviderProfile.self, from: data)
            #expect(decoded == profile)
        }
    }

    @Test("registry is exhaustive and contains all 9 providers")
    func verifyProviderRegistry() {
        #expect(PROVIDER_REGISTRY.count == 9)
        for item in allCases {
            let matching = PROVIDER_REGISTRY.filter { $0.provider == item.provider }
            #expect(matching.count == 1)
            let adapter = providerAdapter(item.provider)
            #expect(adapter.provider == item.provider)
            #expect(adapter.profile == item.provider.profile)
        }
    }
}

// MARK: - 2. Header Sanitization & Default Header Tests

@Suite("Header Sanitization & Application Tests")
struct HeaderSanitizationTests {
    private func makeConfig(
        clientVersion: String? = nil,
        clientIdentifier: String? = nil,
        deploymentId: String? = nil,
        userId: String? = nil
    ) -> SamplerConfig {
        SamplerConfig(
            apiKey: "test-key",
            baseURL: "https://example.com",
            model: "test-model",
            clientIdentifier: clientIdentifier,
            deploymentId: deploymentId,
            userId: userId,
            clientVersion: clientVersion
        )
    }

    @Test("xAI retains x-grok headers and applies default headers")
    func xaiRetainsAndAppliesHeaders() {
        let adapter = providerAdapter(.xai)
        var headers: [String: String] = [
            "Authorization": "Bearer token",
            "x-grok-session-id": "existing-session",
            "X-Grok-Conv-Id": "existing-conv",
            "custom-header": "value",
        ]

        adapter.sanitizeHeaders(&headers)
        #expect(headers["Authorization"] == "Bearer token")
        #expect(headers["x-grok-session-id"] == "existing-session")
        #expect(headers["X-Grok-Conv-Id"] == "existing-conv")
        #expect(headers["custom-header"] == "value")

        let config = makeConfig(
            clientVersion: "0.1.220-open-grok.23",
            clientIdentifier: "my-shell",
            deploymentId: "dep-123",
            userId: "user-456"
        )
        adapter.applyDefaultHeaders(&headers, config: config)

        #expect(headers["x-grok-client-version"] == "0.1.220")
        #expect(headers["x-grok-client-identifier"] == "my-shell")
        #expect(headers["x-grok-deployment-id"] == "dep-123")
        #expect(headers["x-grok-user-id"] == "user-456")
    }

    @Test("all 8 non-xAI providers strip x-grok headers on sanitize")
    func nonXaiProvidersStripXGrokHeaders() {
        let nonXaiProviders: [ModelProvider] = [
            .codex, .kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer, .zai,
        ]

        for provider in nonXaiProviders {
            let adapter = providerAdapter(provider)
            var headers: [String: String] = [
                "Authorization": "Bearer token",
                "x-grok-session-id": "must-strip-session",
                "X-GROK-CONV-ID": "must-strip-conv",
                "x-grok-custom": "must-strip-custom",
                "Content-Type": "application/json",
            ]

            adapter.sanitizeHeaders(&headers)

            #expect(headers["Authorization"] == "Bearer token", "\(provider) must preserve Authorization")
            #expect(headers["Content-Type"] == "application/json", "\(provider) must preserve Content-Type")
            #expect(headers["x-grok-session-id"] == nil, "\(provider) must strip x-grok-session-id")
            #expect(headers["X-GROK-CONV-ID"] == nil, "\(provider) must strip case-insensitive x-grok header")
            #expect(headers["x-grok-custom"] == nil, "\(provider) must strip x-grok-custom")
            #expect(headers.keys.allSatisfy { !$0.lowercased().hasPrefix("x-grok-") }, "\(provider) must have zero x-grok headers")

            // Also test applyDefaultHeaders strips and does NOT add x-grok-*
            var headersForDefault = [
                "x-grok-old": "stale",
                "Accept": "application/json",
            ]
            let config = makeConfig(
                clientVersion: "1.0.0",
                clientIdentifier: "my-shell",
                deploymentId: "dep-123",
                userId: "user-456"
            )
            adapter.applyDefaultHeaders(&headersForDefault, config: config)

            #expect(headersForDefault["Accept"] == "application/json")
            #expect(headersForDefault["x-grok-old"] == nil)
            #expect(headersForDefault["x-grok-client-version"] == nil)
            #expect(headersForDefault["x-grok-client-identifier"] == nil)
            #expect(headersForDefault["x-grok-deployment-id"] == nil)
            #expect(headersForDefault["x-grok-user-id"] == nil)
        }
    }

    @Test("applyRequestHeaders applies x-grok for xai and session headers for codex")
    func applyRequestHeadersBehavior() {
        let requestHeaders = ProviderRequestHeaders(
            convId: "conv-1",
            reqId: "req-1",
            modelId: "model-1",
            sessionId: "session-abc",
            turnIdx: "3",
            agentId: "agent-main",
            deploymentId: "deploy-1",
            userId: "user-1"
        )

        // xAI adds x-grok-*
        let xaiAdapter = providerAdapter(.xai)
        var xaiHeaders: [String: String] = [:]
        xaiAdapter.applyRequestHeaders(&xaiHeaders, request: requestHeaders)
        #expect(xaiHeaders["x-grok-conv-id"] == "conv-1")
        #expect(xaiHeaders["x-grok-req-id"] == "req-1")
        #expect(xaiHeaders["x-grok-model-override"] == "model-1")
        #expect(xaiHeaders["x-grok-session-id"] == "session-abc")
        #expect(xaiHeaders["x-grok-turn-idx"] == "3")
        #expect(xaiHeaders["x-grok-agent-id"] == "agent-main")
        #expect(xaiHeaders["x-grok-deployment-id"] == "deploy-1")
        #expect(xaiHeaders["x-grok-user-id"] == "user-1")

        // Codex applies session affinity headers (session-id, thread-id, x-client-request-id) but no x-grok
        let codexAdapter = providerAdapter(.codex)
        var codexHeaders: [String: String] = [:]
        codexAdapter.applyRequestHeaders(&codexHeaders, request: requestHeaders)
        #expect(codexHeaders[CODEX_SESSION_ID_HEADER] == "session-abc")
        #expect(codexHeaders[CODEX_THREAD_ID_HEADER] == "session-abc")
        #expect(codexHeaders[CODEX_CLIENT_REQUEST_ID_HEADER] == "session-abc")
        #expect(codexHeaders.keys.allSatisfy { !$0.hasPrefix("x-grok-") })

        // Other providers do not apply x-grok
        for provider in [ModelProvider.kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer, .zai] {
            let adapter = providerAdapter(provider)
            var otherHeaders: [String: String] = [:]
            adapter.applyRequestHeaders(&otherHeaders, request: requestHeaders)
            #expect(otherHeaders.keys.allSatisfy { !$0.hasPrefix("x-grok-") }, "\(provider) must not apply x-grok headers")
        }
    }
}

// MARK: - 3. Responses Dialect Patching Tests

@Suite("Responses Dialect Patching Tests")
struct ResponsesDialectPatchingTests {
    private func baseResponsesRequest() -> JSONValue {
        .object([
            "input": .array([
                .object([
                    "type": .string("message"),
                    "role": .string("system"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string("System base prompt")]),
                    ]),
                ]),
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string("User question")]),
                    ]),
                ]),
            ]),
            "reasoning": .object([
                "effort": .string("xhigh"),
                "summary": .string("concise"),
            ]),
            "tools": .array([
                .object([
                    "type": .string("web_search"),
                ]),
            ]),
        ])
    }

    @Test("xAI responses dialect leaves request body untouched")
    func xaiResponsesUnmodified() {
        let adapter = providerAdapter(.xai)
        var body = baseResponsesRequest()
        let original = body
        adapter.patchResponsesRequest(&body, policy: ResponsesRequestPolicy(multiAgentV2: false, localEffort: .high, reasoningSummary: .detailed))
        #expect(body == original)
    }

    @Test("codex responses dialect extracts instructions, patches tools, reasoning, and multiAgentV2")
    func codexResponsesPatching() {
        let adapter = providerAdapter(.codex)
        var body = baseResponsesRequest()

        let policy = ResponsesRequestPolicy(
            multiAgentV2: true,
            localEffort: .ultra,
            reasoningSummary: .detailed
        )
        adapter.patchResponsesRequest(&body, policy: policy)

        guard case .object(let obj) = body else {
            Issue.record("Expected object body")
            return
        }

        // Instructions extracted from leading system message
        #expect(obj["instructions"]?.stringValue == "System base prompt")

        // Input no longer has leading system message, only user message + developer multi-agent prompt
        guard case .array(let input) = obj["input"] else {
            Issue.record("Expected input array")
            return
        }
        #expect(input.count == 2)
        #expect(input[0]["role"]?.stringValue == "developer")
        #expect(input[0]["content"]?.arrayValue?.first?["text"]?.stringValue?.contains(MULTI_AGENT_MODE_OPEN_TAG) == true)
        #expect(input[0]["content"]?.arrayValue?.first?["text"]?.stringValue?.contains(PROACTIVE_MULTI_AGENT_MODE_TEXT) == true)
        #expect(input[1]["role"]?.stringValue == "user")

        // web_search tool has external_web_access: true
        guard case .array(let tools) = obj["tools"] else {
            Issue.record("Expected tools array")
            return
        }
        #expect(tools[0]["external_web_access"]?.boolValue == true)

        // Reasoning summary set to detailed, effort mapped to max (for ultra)
        guard case .object(let reasoning) = obj["reasoning"] else {
            Issue.record("Expected reasoning object")
            return
        }
        #expect(reasoning["summary"]?.stringValue == "detailed")
        #expect(reasoning["effort"]?.stringValue == "max")
    }

    @Test("codex multiAgentV2 uses explicit-request text when effort is not ultra")
    func codexMultiAgentV2NonUltra() {
        let adapter = providerAdapter(.codex)
        var body = baseResponsesRequest()

        let policy = ResponsesRequestPolicy(
            multiAgentV2: true,
            localEffort: .high,
            reasoningSummary: nil
        )
        adapter.patchResponsesRequest(&body, policy: policy)

        guard case .object(let obj) = body,
              case .array(let input) = obj["input"]
        else {
            Issue.record("Expected input array")
            return
        }

        let devItem = input.first { $0["role"]?.stringValue == "developer" }
        #expect(devItem != nil)
        let text = devItem?["content"]?.arrayValue?.first?["text"]?.stringValue
        #expect(text?.contains(EXPLICIT_REQUEST_ONLY_MULTI_AGENT_MODE_TEXT) == true)
    }

    @Test("deepSeek responses dialect strips unsupported fields and normalizes effort")
    func deepSeekResponsesPatching() {
        let adapter = providerAdapter(.deepseek)

        for (effort, expectedEffort) in [
            (ReasoningEffort.none, "none"),
            (ReasoningEffort.minimal, "low"),
            (ReasoningEffort.low, "low"),
            (ReasoningEffort.medium, "high"),
            (ReasoningEffort.high, "high"),
            (ReasoningEffort.xhigh, "high"),
            (ReasoningEffort.max, "max"),
            (ReasoningEffort.ultra, "max"),
        ] {
            var body: JSONValue = .object([
                "input": .array([]),
                "background": .bool(true),
                "conversation": .string("conv"),
                "context_management": .string("auto"),
                "include": .array([.string("reasoning.encrypted_content")]),
                "metadata": .object([:]),
                "previous_response_id": .string("prev-1"),
                "prompt": .string("p"),
                "prompt_cache_key": .string("must-not-send"),
                "prompt_cache_retention": .string("24h"),
                "safety_identifier": .string("id"),
                "service_tier": .string("priority"),
                "store": .bool(true),
                "stream_options": .object([:]),
                "truncation": .string("auto"),
                "reasoning": .object([
                    "effort": .string("xhigh"),
                    "summary": .string("concise"),
                ]),
            ])

            adapter.patchResponsesRequest(&body, policy: ResponsesRequestPolicy(multiAgentV2: false, localEffort: effort, reasoningSummary: .concise))

            guard case .object(let obj) = body else {
                Issue.record("Expected object")
                continue
            }

            for field in DEEPSEEK_UNSUPPORTED_RESPONSES_FIELDS {
                #expect(obj[field] == nil, "DeepSeek must omit unsupported field: \(field)")
            }

            guard case .object(let reasoning) = obj["reasoning"] else {
                Issue.record("Expected reasoning object")
                continue
            }
            #expect(reasoning["summary"] == nil, "DeepSeek must strip reasoning.summary")
            #expect(reasoning["effort"]?.stringValue == expectedEffort, "Effort \(effort) must map to \(expectedEffort)")
        }
    }

    @Test("meta responses dialect strips unsupported fields, reasoning input items, and summary")
    func metaResponsesPatching() {
        let adapter = providerAdapter(.meta)

        for effortStr in ["low", "medium", "high", "xhigh"] {
            var body: JSONValue = .object([
                "input": .array([
                    .object(["type": .string("message"), "role": .string("user"), "content": .string("question")]),
                    .object(["type": .string("reasoning"), "id": .string("r1"), "summary": .string("transient")]),
                    .object(["type": .string("function_call"), "call_id": .string("c1"), "name": .string("tool_lookup")]),
                    .object(["type": .string("function_call_output"), "call_id": .string("c1"), "output": .string("data")]),
                    .object(["type": .string("message"), "role": .string("user"), "content": .string("follow-up")]),
                ]),
                "include": .array([.string("reasoning.encrypted_content")]),
                "prompt_cache_key": .string("must-not-send"),
                "prompt_cache_retention": .string("24h"),
                "store": .bool(true),
                "reasoning": .object([
                    "effort": .string(effortStr),
                    "summary": .string("concise"),
                ]),
            ])

            adapter.patchResponsesRequest(&body, policy: ResponsesRequestPolicy())

            guard case .object(let obj) = body else {
                Issue.record("Expected object")
                continue
            }

            #expect(obj["include"] == nil)
            #expect(obj["prompt_cache_key"] == nil)
            #expect(obj["prompt_cache_retention"] == nil)
            #expect(obj["store"] == nil)

            guard case .array(let input) = obj["input"] else {
                Issue.record("Expected input array")
                continue
            }
            #expect(input.count == 4, "Must filter out type=reasoning item")
            #expect(input.allSatisfy { $0["type"]?.stringValue != "reasoning" })
            #expect(input[0]["type"]?.stringValue == "message")
            #expect(input[1]["type"]?.stringValue == "function_call")
            #expect(input[2]["type"]?.stringValue == "function_call_output")
            #expect(input[3]["type"]?.stringValue == "message")

            guard case .object(let reasoning) = obj["reasoning"] else {
                Issue.record("Expected reasoning")
                continue
            }
            #expect(reasoning["summary"] == nil, "Meta must strip reasoning.summary")
            #expect(reasoning["effort"]?.stringValue == effortStr, "Meta preserves valid effort unchanged")
        }
    }
}

// MARK: - 4. Backend Validation Tests

@Suite("Backend Validation Matrix Tests")
struct BackendValidationTests {
    @Test("validateBackend enforces profile capability across all 9 providers")
    func validateBackendAcrossAllProviders() {
        struct TestCase {
            let provider: ModelProvider
            let chatCompletionsOk: Bool
            let responsesOk: Bool
            let messagesOk: Bool
        }

        let cases: [TestCase] = [
            TestCase(provider: .xai, chatCompletionsOk: true, responsesOk: true, messagesOk: true),
            TestCase(provider: .codex, chatCompletionsOk: false, responsesOk: true, messagesOk: false),
            TestCase(provider: .kimi, chatCompletionsOk: true, responsesOk: false, messagesOk: false),
            TestCase(provider: .fireworks, chatCompletionsOk: true, responsesOk: false, messagesOk: false),
            TestCase(provider: .deepseek, chatCompletionsOk: true, responsesOk: true, messagesOk: false),
            TestCase(provider: .meta, chatCompletionsOk: false, responsesOk: true, messagesOk: false),
            TestCase(provider: .openCodeGo, chatCompletionsOk: true, responsesOk: false, messagesOk: true),
            TestCase(provider: .wafer, chatCompletionsOk: true, responsesOk: false, messagesOk: false),
            TestCase(provider: .zai, chatCompletionsOk: true, responsesOk: false, messagesOk: false),
        ]

        for tc in cases {
            let adapter = providerAdapter(tc.provider)

            // Chat Completions
            if tc.chatCompletionsOk {
                #expect(doesNotThrow { try adapter.validateBackend(.chatCompletions) }, "\(tc.provider) must accept chatCompletions")
            } else {
                #expect(throws: SamplingError.self) { try adapter.validateBackend(.chatCompletions) }
            }

            // Responses
            if tc.responsesOk {
                #expect(doesNotThrow { try adapter.validateBackend(.responses) }, "\(tc.provider) must accept responses")
            } else {
                #expect(throws: SamplingError.self) { try adapter.validateBackend(.responses) }
            }

            // Messages
            if tc.messagesOk {
                #expect(doesNotThrow { try adapter.validateBackend(.messages) }, "\(tc.provider) must accept messages")
            } else {
                #expect(throws: SamplingError.self) { try adapter.validateBackend(.messages) }
            }
        }
    }

    private func doesNotThrow(_ block: () throws -> Void) -> Bool {
        do {
            try block()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 5. Chat Request Sanitization Tests

@Suite("Chat Request Sanitization Tests")
struct ChatRequestSanitizationTests {
    private func makeWireRequest(
        model: String = "test-model",
        temperature: Float? = 0.7,
        topP: Float? = 0.95,
        frequencyPenalty: Float? = 0.2,
        presencePenalty: Float? = 0.3,
        serviceTier: String? = "priority",
        reasoningEffort: ReasoningEffort? = .high,
        messages: [ChatRequestWireMessage] = [
            ChatRequestWireMessage(role: .assistant, content: .text("prev"), modelId: "internal-id-123"),
        ]
    ) -> ChatCompletionWireRequest {
        ChatCompletionWireRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: 1000,
            topP: topP,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            tools: nil,
            toolChoice: nil,
            stream: nil,
            streamOptions: nil,
            reasoningEffort: reasoningEffort,
            thinking: nil,
            serviceTier: serviceTier,
            responseFormat: nil
        )
    }

    @Test("kimi sanitizes sampling parameters and serviceTier")
    func kimiSanitizesSamplingParams() {
        let adapter = providerAdapter(.kimi)
        var req = makeWireRequest(model: "kimi-k3")
        adapter.sanitizeChatRequest(&req)

        #expect(req.temperature == nil)
        #expect(req.topP == nil)
        #expect(req.frequencyPenalty == nil)
        #expect(req.presencePenalty == nil)
        #expect(req.serviceTier == nil)
    }

    @Test("fireworks sanitizes reasoningEffort and message modelIds")
    func fireworksSanitizesEffortAndMessageModelId() {
        let adapter = providerAdapter(.fireworks)
        var req = makeWireRequest(model: "accounts/fireworks/models/glm-5p2")
        adapter.sanitizeChatRequest(&req)

        #expect(req.reasoningEffort == nil)
        #expect(req.messages[0].modelId == nil)
        #expect(req.temperature == 0.7)
        #expect(req.topP == 0.95)
        #expect(req.serviceTier == "priority")
    }

    @Test("deepSeek sanitizes message modelIds and serviceTier")
    func deepSeekSanitizesMessageModelIdsAndServiceTier() {
        let adapter = providerAdapter(.deepseek)
        var req = makeWireRequest(model: "deepseek-chat")
        adapter.sanitizeChatRequest(&req)

        #expect(req.messages[0].modelId == nil)
        #expect(req.serviceTier == nil)
        #expect(req.temperature == 0.7)
    }

    @Test("openCodeGo sanitizes message modelIds and serviceTier")
    func openCodeGoSanitizesMessageModelIdsAndServiceTier() {
        let adapter = providerAdapter(.openCodeGo)
        var req = makeWireRequest(model: "opencode-model")
        adapter.sanitizeChatRequest(&req)

        #expect(req.messages[0].modelId == nil)
        #expect(req.serviceTier == nil)
    }

    @Test("wafer sanitizes reasoningEffort, serviceTier, and message modelIds")
    func waferSanitizesMetadata() {
        let adapter = providerAdapter(.wafer)
        var req = makeWireRequest(model: "wafer-model")
        adapter.sanitizeChatRequest(&req)

        #expect(req.reasoningEffort == nil)
        #expect(req.serviceTier == nil)
        #expect(req.messages[0].modelId == nil)
        #expect(req.temperature == 0.7)
        #expect(req.topP == 0.95)
    }

    @Test("zai sets thinking mode based on reasoningEffort and strips serviceTier/modelId")
    func zaiThinkingModeShaping() {
        let adapter = providerAdapter(.zai)

        // Case 1: with reasoningEffort -> thinking = .enabled
        var reqWithEffort = makeWireRequest(model: "glm-5.2", reasoningEffort: ReasoningEffort.high)
        adapter.sanitizeChatRequest(&reqWithEffort)
        #expect(reqWithEffort.serviceTier == nil)
        #expect(reqWithEffort.messages[0].modelId == nil)
        #expect(reqWithEffort.reasoningEffort == .high)
        #expect(reqWithEffort.thinking == ChatThinkingMode.enabled)

        // Case 2: without reasoningEffort -> thinking = nil
        var reqWithoutEffort = makeWireRequest(model: "glm-5.2", reasoningEffort: nil as ReasoningEffort?)
        adapter.sanitizeChatRequest(&reqWithoutEffort)
        #expect(reqWithoutEffort.serviceTier == nil)
        #expect(reqWithoutEffort.messages[0].modelId == nil)
        #expect(reqWithoutEffort.reasoningEffort == nil)
        #expect(reqWithoutEffort.thinking == nil)
    }
}

// MARK: - 6. Prompt Caching, Turn State, and Capability Flags Tests

@Suite("Prompt Caching, Turn State & Capability Flags Tests")
struct PromptCachingAndTurnStateTests {
    @Test("promptCacheKey returns sessionId only for Codex")
    func promptCacheKeyBehavior() {
        #expect(providerAdapter(.codex).promptCacheKey(sessionId: "session-123") == "session-123")
        #expect(providerAdapter(.codex).promptCacheKey(sessionId: "") == nil)
        #expect(providerAdapter(.codex).promptCacheKey(sessionId: nil) == nil)

        for provider in [ModelProvider.xai, .kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer, .zai] {
            #expect(providerAdapter(provider).promptCacheKey(sessionId: "session-123") == nil, "\(provider) promptCacheKey must be nil")
        }
    }

    @Test("supportsTurnState is true only for Codex under Responses backend")
    func supportsTurnStateBehavior() {
        #expect(providerAdapter(.codex).supportsTurnState(backend: .responses) == true)
        #expect(providerAdapter(.codex).supportsTurnState(backend: .chatCompletions) == false)
        #expect(providerAdapter(.codex).supportsTurnState(backend: .messages) == false)

        for provider in [ModelProvider.xai, .kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer, .zai] {
            #expect(providerAdapter(provider).supportsTurnState(backend: .responses) == false, "\(provider) must not support turn state")
        }
    }

    @Test("sendsDoomLoopOptIn is true only for xAI (.xGrokHeaders)")
    func sendsDoomLoopOptInBehavior() {
        #expect(providerAdapter(.xai).sendsDoomLoopOptIn == true)
        for provider in [ModelProvider.codex, .kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer, .zai] {
            #expect(providerAdapter(provider).sendsDoomLoopOptIn == false, "\(provider) sendsDoomLoopOptIn must be false")
        }
    }

    @Test("normalizesResponseEvents is true for responses-capable dialects")
    func normalizesResponseEventsBehavior() {
        #expect(providerAdapter(.xai).normalizesResponseEvents == true)
        #expect(providerAdapter(.codex).normalizesResponseEvents == true)
        #expect(providerAdapter(.deepseek).normalizesResponseEvents == true)
        #expect(providerAdapter(.meta).normalizesResponseEvents == true)

        #expect(providerAdapter(.kimi).normalizesResponseEvents == false)
        #expect(providerAdapter(.fireworks).normalizesResponseEvents == false)
        #expect(providerAdapter(.openCodeGo).normalizesResponseEvents == false)
        #expect(providerAdapter(.wafer).normalizesResponseEvents == false)
        #expect(providerAdapter(.zai).normalizesResponseEvents == false)
    }
}
