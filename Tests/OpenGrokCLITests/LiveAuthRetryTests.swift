import Foundation
import Testing
@testable import OpenGrokAuth
@testable import OpenGrokCLI
import OpenGrokHTTP
import OpenGrokSamplingTypes

private final class RefreshableLiveCredential: AuthCredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String = "stale-token"
    private(set) var refreshCount = 0

    func apply(to headers: inout [String: String], baseURL: String) {
        _ = baseURL
        headers["Authorization"] = "Bearer \(currentToken())"
        headers[xaiTokenAuthHeader] = xaiTokenAuthValue
    }

    func snapshot() -> CredentialSnapshot {
        CredentialSnapshot(token: currentToken())
    }

    func refreshAfterUnauthorized() async -> Bool {
        refreshSynchronously()
    }

    private func refreshSynchronously() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard token == "stale-token" else { return false }
        token = "fresh-token"
        refreshCount += 1
        return true
    }

    func needsTokenAuthHeader() -> Bool { true }
    func hasUsableCredential() -> Bool { true }

    private func currentToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        return token
    }
}

@Suite("Live auth retry")
struct LiveAuthRetryTests {
    @Test("production sampler refreshes once before replaying an SSE turn")
    func productionSamplerRefreshesBeforeReplay() async throws {
        let chunk = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]}"#
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 401), body: Data()),
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data("data: \(chunk)\n\ndata: [DONE]\n\n".utf8)
            ),
        ])
        let credential = RefreshableLiveCredential()
        let sampler = try OpenGrokLiveSampler.production(
            configuration: OpenGrokLiveSamplingConfiguration(
                model: "test-model",
                baseURL: "https://example.test",
                apiKey: "stale-token",
                credentialProvider: credential,
                transport: transport
            )
        )

        let response = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "session",
                turnID: "turn",
                model: "test-model",
                prompt: "hello"
            ),
            emit: { _ in }
        )

        #expect(response.output == "Hi")
        #expect(credential.refreshCount == 1)
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].headers["Authorization"] == "Bearer stale-token")
        #expect(transport.recordedRequests[1].headers["Authorization"] == "Bearer fresh-token")
    }
}
