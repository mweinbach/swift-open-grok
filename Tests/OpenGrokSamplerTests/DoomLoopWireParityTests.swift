import Foundation
import OpenGrokHTTP
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing

@Suite("Provider-safe doom-loop recovery wire parity")
struct DoomLoopWireParityTests {
    private func recordedResponsesRequest(
        provider: ModelProvider,
        policy: DoomLoopRecoveryPolicy?
    ) async throws -> HTTPRequest {
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
                apiBackend: .responses,
                provider: provider,
                doomLoopRecovery: policy
            ),
            transport: transport
        )
        let result = try await client.conversationStreamResponses(
            ConversationRequest(items: [.user("hello")])
        )
        _ = result.1
        return try #require(transport.recordedRequests.first)
    }

    @Test("xAI sends the resolved detector window instead of a boolean placeholder")
    func xAIDetectorWindowHeader() async throws {
        let baseline = try await recordedResponsesRequest(
            provider: .xai,
            policy: DoomLoopRecoveryPolicy()
        )
        let configured = try await recordedResponsesRequest(
            provider: .xai,
            policy: DoomLoopRecoveryPolicy(
                maxThreshold: 32,
                maxRetries: 2,
                windowTokens: 2048
            )
        )

        #expect(baseline.headers[DOOM_LOOP_CHECK_HEADER] == "1024")
        #expect(configured.headers[DOOM_LOOP_CHECK_HEADER] == "2048")
    }

    @Test("A disabled xAI policy sends no inference-private detector header")
    func disabledRecoveryOmitsHeader() async throws {
        let request = try await recordedResponsesRequest(provider: .xai, policy: nil)
        #expect(request.headers[DOOM_LOOP_CHECK_HEADER] == nil)
    }

    @Test("Codex, DeepSeek, and Meta never receive xAI-private detector settings")
    func foreignProvidersNeverReceiveDetectorHeader() async throws {
        for provider: ModelProvider in [.codex, .deepseek, .meta] {
            let request = try await recordedResponsesRequest(
                provider: provider,
                policy: DoomLoopRecoveryPolicy()
            )
            #expect(request.headers[DOOM_LOOP_CHECK_HEADER] == nil)
        }
    }

    @Test("xAI Chat Completions never receives the Responses-only detector header")
    func xAIChatBackendDoesNotReceiveResponsesHeader() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://provider.example.test",
                model: "test-model",
                apiBackend: .chatCompletions,
                provider: .xai,
                doomLoopRecovery: DoomLoopRecoveryPolicy()
            ),
            transport: transport
        )

        let result = try await client.conversationStream(
            ConversationRequest(items: [.user("hello")])
        )
        _ = result.1
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers[DOOM_LOOP_CHECK_HEADER] == nil)
    }
}
