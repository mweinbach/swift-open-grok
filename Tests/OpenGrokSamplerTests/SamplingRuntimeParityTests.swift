import Foundation
import OpenGrokHTTP
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing

@Suite("Sampler runtime actor and credential attribution parity")
struct SamplingRuntimeParityTests {
    private func codexResponse(
        text: String,
        turnState: String? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        let completed = #"{"type":"response.completed","response":{"id":"response-1","status":"completed","model":"gpt-test","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(text)"}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#
        var headers = ["Content-Type": "text/event-stream"]
        if let turnState {
            headers[X_CODEX_TURN_STATE_HEADER] = turnState
        }
        return .init(
            metadata: HTTPResponseMetadata(statusCode: 200, headers: headers),
            body: Data("data: \(completed)\n\n".utf8)
        )
    }

    @Test("attribution records never retain full credentials and classify stale tails")
    func attributionRecordScrubsCredentials() {
        let sent = "shared-provider-prefix-rejected-tail"
        let current = "shared-provider-prefix-accepted-tail"
        let stale = Auth401AttributionRecord(
            consumer: .responsesStream,
            sentBearer: sent,
            currentBearer: current
        )

        #expect(stale.sentBearerSuffix == scrubbedBearerSuffix(sent))
        #expect(stale.currentBearerSuffix == scrubbedBearerSuffix(current))
        #expect(stale.sentBearerSuffix?.count == BEARER_SUFFIX_LEN)
        #expect(stale.currentBearerSuffix?.count == BEARER_SUFFIX_LEN)
        #expect(stale.isStaleSnapshot)
        #expect(stale.sentBearerSuffix != sent)
        #expect(stale.currentBearerSuffix != current)

        let matching = Auth401AttributionRecord(
            consumer: .standaloneWebSearch,
            sentBearer: "🔑🔑🔑🔑🔑🔑🔑🔑🔑🔑🔑🔑🔑",
            currentBearer: "🔑🔑🔑🔑🔑🔑🔑🔑🔑🔑🔑🔑🔑"
        )
        #expect(matching.sentBearerSuffix?.count == BEARER_SUFFIX_LEN)
        #expect(!matching.isStaleSnapshot)
    }

    @Test("missing or empty credentials never claim a stale snapshot")
    func missingCredentialsAreNotStale() {
        let noSent = Auth401AttributionRecord(
            consumer: .chatCompletionsStream,
            sentBearer: nil,
            currentBearer: "a-current-bearer"
        )
        let noCurrent = Auth401AttributionRecord(
            consumer: .messagesStream,
            sentBearer: "a-rejected-bearer",
            currentBearer: nil
        )
        let emptySent = Auth401AttributionRecord(
            consumer: .responsesStream,
            sentBearer: "",
            currentBearer: "current"
        )

        #expect(!noSent.isStaleSnapshot)
        #expect(!noCurrent.isStaleSnapshot)
        #expect(!emptySent.isStaleSnapshot)
    }

    @Test("completed replaced requests cannot unregister their newer generation")
    func actorRequestOwnershipIsGenerationSafe() {
        let state = ActorStateBox(
            config: SamplerConfig(model: "test"),
            retryPolicy: OpenGrokSampler.RetryPolicy(maxRetries: 0)
        )
        let requestID = RequestId("shared-request")
        let stale = CancellationToken()
        let current = CancellationToken()

        #expect(state.register(requestId: requestID, token: stale) == nil)
        let replaced = state.register(requestId: requestID, token: current)
        #expect(replaced === stale)
        state.remove(requestId: requestID, token: stale)
        #expect(state.isActive(requestId: requestID))
        state.remove(requestId: requestID, token: current)
        #expect(!state.isActive(requestId: requestID))
    }

    @Test("explicit Codex turn cells survive actor retries and preserve attempt metrics")
    func explicitCodexTurnStateSurvivesRetries() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 500,
                    headers: ["Retry-After": "0"]
                ),
                body: Data(#"{"error":{"message":"transient"}}"#.utf8)
            ),
            codexResponse(text: "recovered", turnState: "must-not-replace-existing"),
        ])
        let configuration = SamplerConfig(
            apiKey: "test-token",
            baseURL: "https://codex.example.test/v1",
            model: "gpt-test",
            apiBackend: .responses,
            provider: .codex,
            maxRetries: 2
        )
        let actor = SamplerActor.spawn(config: configuration, transport: transport)
        defer { actor.handle.shutdown() }
        let sharedCell = CodexTurnStateCell()
        #expect(sharedCell.setIfEmpty("session-owned-turn"))

        let result = await actor.handle.submitAndCollect(
            requestId: RequestId("codex-retry"),
            request: ConversationRequest(items: [.user("hello")]),
            codexTurnState: sharedCell
        )

        guard case .success(let (response, metrics)) = result else {
            Issue.record("expected successful actor retry")
            return
        }
        #expect(response.assistantText() == "recovered")
        #expect(metrics.attempts == 2)
        #expect(sharedCell.get() == "session-owned-turn")
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests.allSatisfy {
            $0.headers[X_CODEX_TURN_STATE_HEADER] == "session-owned-turn"
        })
    }

    @Test("explicit actor shutdown closes its event stream without orphaned requests")
    func actorShutdownFinishesEventStream() async {
        let actor = SamplerActor.spawn(
            config: SamplerConfig(
                apiKey: "token",
                baseURL: "https://provider.example.test",
                model: "test"
            ),
            transport: MockHTTPTransport()
        )
        actor.handle.shutdown()
        var iterator = actor.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == nil)
    }
}
