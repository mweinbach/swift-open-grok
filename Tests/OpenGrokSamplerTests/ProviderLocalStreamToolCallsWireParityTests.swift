import Foundation
import OpenGrokHTTP
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

@Suite("Provider-local streamed tool-call live wire policy")
struct ProviderLocalStreamToolCallsWireParityTests {
    private func requestBody(
        provider: ModelProvider,
        backend: ApiBackend,
        requested: Bool
    ) async throws -> JSONValue {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            )),
        ])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://provider.example.test",
                model: "test-model",
                apiBackend: backend,
                provider: provider,
                streamToolCalls: requested
            ),
            transport: transport
        )
        let request = ConversationRequest(items: [.user("hello")])
        switch backend {
        case .responses:
            let result = try await client.conversationStreamResponses(request)
            _ = result.1
        case .chatCompletions:
            let result = try await client.conversationStream(request)
            _ = result.1
        case .messages:
            let result = try await client.conversationStreamMessages(request)
            _ = result.1
        }
        let recorded = try #require(transport.recordedRequests.first)
        return try JSONDecoder().decode(JSONValue.self, from: try #require(recorded.body))
    }

    @Test("xAI Responses enables the flag and omits it when disabled")
    func xAIResponsesRespectsPreference() async throws {
        let enabled = try await requestBody(provider: .xai, backend: .responses, requested: true)
        let disabled = try await requestBody(provider: .xai, backend: .responses, requested: false)

        #expect(enabled["stream_tool_calls"] == .bool(true))
        #expect(disabled["stream_tool_calls"] == nil)
    }

    @Test("Codex, DeepSeek and Meta never receive xAI-private Responses fields")
    func foreignResponsesProvidersNeverReceivePrivateField() async throws {
        for provider: ModelProvider in [.codex, .deepseek, .meta] {
            let body = try await requestBody(provider: provider, backend: .responses, requested: true)
            #expect(body["stream_tool_calls"] == nil)
        }
    }

    @Test("xAI Chat Completions and Messages keep their native streaming protocols")
    func nonResponsesBackendsNeverReceivePrivateField() async throws {
        for backend: ApiBackend in [.chatCompletions, .messages] {
            let body = try await requestBody(provider: .xai, backend: backend, requested: true)
            #expect(body["stream_tool_calls"] == nil)
        }
    }
}
