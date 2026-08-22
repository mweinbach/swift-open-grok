// PromptCacheAffinityParityTests.swift
//
// Ports `xai-grok-sampler/src/client.rs:2508-2518,2538-2555` and
// `provider.rs:55-73,160-175`: cache routing follows inherited affinity,
// while session telemetry and execution-policy metadata retain real identity.

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared

@Suite("Durable prompt-cache affinity parity")
struct PromptCacheAffinityParityTests {
    private func recordedRequest(
        provider: ModelProvider,
        request: ConversationRequest,
        permissions: CodexPermissions? = nil
    ) async throws -> (HTTPRequest, JSONValue) {
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
                codexPermissions: permissions
            ),
            transport: transport
        )

        let (_, _, _, _) = try await client.conversationStreamResponses(request)
        let recorded = try #require(transport.recordedRequests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(recorded.body))
        return (recorded, body)
    }

    @Test("Codex Responses projection prefers inherited cache affinity")
    func projectionUsesInheritedAffinity() {
        let body = projectResponsesRequestBody(
            ConversationRequest(
                items: [.user("hello")],
                xGrokSessionId: "child-session",
                xGrokCacheAffinityId: "root-session"
            ),
            model: "test-model",
            policy: ResponsesRequestPolicy(),
            adapter: providerAdapter(.codex)
        )

        #expect(body["prompt_cache_key"]?.stringValue == "root-session")
    }

    @Test("Codex Responses projection falls back to the actual session")
    func projectionFallsBackToSession() {
        let body = projectResponsesRequestBody(
            ConversationRequest(items: [.user("hello")], xGrokSessionId: "root-session"),
            model: "test-model",
            policy: ResponsesRequestPolicy(),
            adapter: providerAdapter(.codex)
        )

        #expect(body["prompt_cache_key"]?.stringValue == "root-session")
    }

    @Test("an explicitly empty affinity fails closed instead of changing cache partitions")
    func emptyAffinitySuppressesCacheRouting() async throws {
        let (request, body) = try await recordedRequest(
            provider: .codex,
            request: ConversationRequest(
                items: [.user("hello")],
                xGrokSessionId: "child-session",
                xGrokCacheAffinityId: ""
            )
        )

        #expect(body["prompt_cache_key"] == nil)
        #expect(request.headers[CODEX_SESSION_ID_HEADER] == nil)
        #expect(request.headers[CODEX_THREAD_ID_HEADER] == nil)
        #expect(request.headers[CODEX_CLIENT_REQUEST_ID_HEADER] == nil)
    }

    @Test("live Codex requests keep cache routing separate from session metadata")
    func liveCodexForkPreservesBothIdentities() async throws {
        let permissions = CodexPermissions(
            sandbox: "seatbelt",
            sandboxMode: "workspace-write",
            networkAccess: true,
            writableRoots: ["/tmp/project"],
            approvalPolicy: .onRequest,
            autoReviewEnabled: true
        )
        let (request, body) = try await recordedRequest(
            provider: .codex,
            request: ConversationRequest(
                items: [.user("hello")],
                xGrokSessionId: "child-session",
                xGrokCacheAffinityId: "ancestor-session",
                xGrokTurnIdx: "child-turn"
            ),
            permissions: permissions
        )

        #expect(body["prompt_cache_key"]?.stringValue == "ancestor-session")
        #expect(request.headers[CODEX_SESSION_ID_HEADER] == "ancestor-session")
        #expect(request.headers[CODEX_THREAD_ID_HEADER] == "ancestor-session")
        #expect(request.headers[CODEX_CLIENT_REQUEST_ID_HEADER] == "ancestor-session")
        #expect(request.headers["x-grok-session-id"] == nil)

        let metadataString = try #require(
            body["client_metadata"]?[X_CODEX_TURN_METADATA_HEADER]?.stringValue
        )
        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(metadataString.utf8))
        #expect(metadata["session_id"]?.stringValue == "child-session")
        #expect(metadata["thread_id"]?.stringValue == "child-session")
        #expect(metadata["turn_id"]?.stringValue == "child-turn")
        #expect(request.headers[X_CODEX_TURN_METADATA_HEADER] == metadataString)
    }

    @Test("live Codex root requests emit all required cache-affinity headers")
    func liveCodexRootEmitsSessionHeaders() async throws {
        let (request, body) = try await recordedRequest(
            provider: .codex,
            request: ConversationRequest(
                items: [.user("hello")],
                xGrokSessionId: "root-session"
            )
        )

        #expect(body["prompt_cache_key"]?.stringValue == "root-session")
        #expect(request.headers[CODEX_SESSION_ID_HEADER] == "root-session")
        #expect(request.headers[CODEX_THREAD_ID_HEADER] == "root-session")
        #expect(request.headers[CODEX_CLIENT_REQUEST_ID_HEADER] == "root-session")
    }

    @Test("missing session and affinity omit every Codex cache-routing value")
    func missingIdentityOmitsCacheRouting() async throws {
        let (request, body) = try await recordedRequest(
            provider: .codex,
            request: ConversationRequest(items: [.user("hello")])
        )

        #expect(body["prompt_cache_key"] == nil)
        #expect(request.headers[CODEX_SESSION_ID_HEADER] == nil)
        #expect(request.headers[CODEX_THREAD_ID_HEADER] == nil)
        #expect(request.headers[CODEX_CLIENT_REQUEST_ID_HEADER] == nil)
    }

    @Test("xAI session telemetry never adopts a fork's cache-affinity identity")
    func xaiTelemetryRetainsActualSession() async throws {
        let (request, body) = try await recordedRequest(
            provider: .xai,
            request: ConversationRequest(
                items: [.user("hello")],
                xGrokSessionId: "actual-child-session",
                xGrokCacheAffinityId: "ancestor-session"
            )
        )

        #expect(request.headers["x-grok-session-id"] == "actual-child-session")
        #expect(request.headers[CODEX_SESSION_ID_HEADER] == nil)
        #expect(request.headers[CODEX_THREAD_ID_HEADER] == nil)
        #expect(request.headers[CODEX_CLIENT_REQUEST_ID_HEADER] == nil)
        #expect(body["prompt_cache_key"] == nil)
    }

    @Test("other Responses providers never inherit Codex cache-routing controls")
    func deepSeekOmitsCodexCacheRouting() async throws {
        let (request, body) = try await recordedRequest(
            provider: .deepseek,
            request: ConversationRequest(
                items: [.user("hello")],
                xGrokSessionId: "actual-child-session",
                xGrokCacheAffinityId: "ancestor-session"
            )
        )

        #expect(body["prompt_cache_key"] == nil)
        #expect(request.headers[CODEX_SESSION_ID_HEADER] == nil)
        #expect(request.headers[CODEX_THREAD_ID_HEADER] == nil)
        #expect(request.headers[CODEX_CLIENT_REQUEST_ID_HEADER] == nil)
        #expect(request.headers["x-grok-session-id"] == nil)
    }
}
