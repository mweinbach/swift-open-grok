import OpenGrokSamplingTypes
import Testing

@Suite("Provider-local streamed tool-call request policy")
struct ProviderLocalStreamToolCallsParityTests {
    @Test("Only xAI Responses accepts the private streaming field across all providers")
    func exhaustiveProviderBackendMatrix() {
        let providers: [ModelProvider] = [
            .xai, .codex, .kimi, .fireworks, .deepseek, .meta,
            .openCodeGo, .wafer, .zai, .runinfra, .gemini, .openRouter,
        ]
        let backends: [ApiBackend] = [.chatCompletions, .responses, .messages]

        for provider in providers {
            for backend in backends {
                let supported = provider == .xai && backend == .responses
                #expect(provider.supportsStreamToolCallsRequest(backend) == supported)
                #expect(shouldInjectStreamToolCalls(true, provider: provider, backend: backend) == supported)
                #expect(!shouldInjectStreamToolCalls(false, provider: provider, backend: backend))
            }
        }
    }
}
