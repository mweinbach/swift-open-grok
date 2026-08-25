import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokSampler

@Suite("Provider retry only before output parity")
struct RetryOnlyBeforeOutputParityTests {
    private let chatPartial = #"{"id":"chunk-1","object":"chat.completion.chunk","created":0,"model":"test-model","choices":[{"index":0,"delta":{"content":"already visible"}}]}"#
    private let chatRecovered = #"{"id":"chunk-2","object":"chat.completion.chunk","created":0,"model":"test-model","choices":[{"index":0,"delta":{"content":"recovered"},"finish_reason":"stop"}]}"#
    private let streamFailure = #"{"error":{"type":"server_error","message":"stream interrupted"}}"#
    private let responsesFailure = #"{"type":"response.failed","response":{"id":"resp_failed","status":"failed","model":"test-model","output":[],"usage":{"output_tokens":0},"error":{"message":"provider interrupted"}}}"#
    private let responsesRecovered = #"{"type":"response.completed","response":{"id":"resp_ok","status":"completed","model":"test-model","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"recovered"}]}]}}"#

    private func sseResponse(_ events: [String]) -> MockHTTPTransport.ScriptedResponse {
        let body = events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        return .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            ),
            body: Data(body.utf8)
        )
    }

    private func actor(
        transport: MockHTTPTransport,
        backend: ApiBackend = .chatCompletions,
        retryOnlyBeforeOutput: Bool
    ) -> SamplerSpawn {
        SamplerActor.spawn(
            config: SamplerConfig(
                apiKey: "test-key",
                baseURL: "https://provider.example.test",
                model: "test-model",
                apiBackend: backend,
                provider: .xai,
                maxRetries: 2
            ),
            retryPolicy: RetryPolicy(
                maxRetries: 2,
                retryOnlyBeforeOutput: retryOnlyBeforeOutput
            ),
            transport: transport
        )
    }

    private func submit(_ actor: SamplerSpawn) async -> Result<
        (ConversationResponse, InferenceLatencyStats),
        SamplingError
    > {
        await actor.handle.submitAndCollect(
            requestId: RequestId.random(),
            request: ConversationRequest(items: [.user("hello")])
        )
    }

    @Test("Rust retry policy wire fields round-trip while older Swift payloads remain readable")
    func retryPolicyWireCompatibility() throws {
        let canonical = Data(
            #"{"max_retries":4,"rate_limit_retry_threshold":2,"retry_only_before_output":true}"#.utf8
        )
        let policy = try JSONDecoder().decode(RetryPolicy.self, from: canonical)
        #expect(policy.maxRetries == 4)
        #expect(policy.rateLimitRetryThreshold == 2)
        #expect(policy.retryOnlyBeforeOutput)

        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(policy))
        #expect(encoded["max_retries"] == .number(.int64(4)))
        #expect(encoded["rate_limit_retry_threshold"] == .number(.int64(2)))
        #expect(encoded["retry_only_before_output"] == .bool(true))
        #expect(encoded["maxRetries"] == nil)

        let legacySwift = Data(#"{"maxRetries":3,"rateLimitRetryThreshold":1}"#.utf8)
        let legacyPolicy = try JSONDecoder().decode(RetryPolicy.self, from: legacySwift)
        #expect(legacyPolicy.maxRetries == 3)
        #expect(legacyPolicy.rateLimitRetryThreshold == 1)
        #expect(!legacyPolicy.retryOnlyBeforeOutput)

        let legacyRust = Data(#"{"max_retries":6,"rate_limit_retry_threshold":2}"#.utf8)
        let legacyRustPolicy = try JSONDecoder().decode(RetryPolicy.self, from: legacyRust)
        #expect(!legacyRustPolicy.retryOnlyBeforeOutput)
        #expect(!RetryPolicy.default.retryOnlyBeforeOutput)
    }

    @Test("response lifecycle and errors do not count as output; refusal and hosted progress do")
    func responsesOutputClassification() {
        let queued = ResponsesStreamEvent.other(type: "response.queued", raw: .object([:]))
        #expect(!responsesEventMayHaveOutput(queued))

        let refusal = ResponsesStreamEvent.other(
            type: "response.refusal.delta",
            raw: .object(["delta": .string("no")])
        )
        #expect(responsesEventMayHaveOutput(refusal))

        let emptyRefusal = ResponsesStreamEvent.other(
            type: "response.refusal.delta",
            raw: .object(["delta": .string("")])
        )
        #expect(!responsesEventMayHaveOutput(emptyRefusal))

        let hostedSearch = ResponsesStreamEvent.other(
            type: "response.web_search_call.searching",
            raw: .object(["item_id": .string("search_1")])
        )
        #expect(responsesEventMayHaveOutput(hostedSearch))

        let xSearch = ResponsesStreamEvent.other(
            type: "response.x_search_call.in_progress",
            raw: .object(["item_id": .string("search_2")])
        )
        #expect(responsesEventMayHaveOutput(xSearch))

        #expect(!responsesEventMayHaveOutput(.error(message: "not started", code: "server_error")))
        #expect(!responsesEventMayHaveOutput(.failed(response: .object([
            "output": .array([]),
            "usage": .object(["output_tokens": .number(.uint64(0))]),
        ]))))
        #expect(responsesEventMayHaveOutput(.failed(response: .object([
            "output": .array([]),
            "usage": .object(["output_tokens": .number(.uint64(1))]),
        ]))))
        #expect(responsesEventMayHaveOutput(.failed(response: .object([
            "output": .array([.object(["type": .string("message")])]),
        ]))))
    }

    @Test("request-scoped observation is monotonic and ignores metadata-only events")
    func outputObservationIsMonotonic() {
        let observation = SamplingOutputObservation()
        let requestID = RequestId("observation")

        observation.observe(.streamStarted(requestId: requestID, timestampMs: 0))
        observation.observe(.responseStarted(
            requestId: requestID,
            messageID: "message",
            model: "test-model",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0
        ))
        #expect(!observation.hasOutput)

        observation.observe(.toolCallDelta(
            requestId: requestID,
            toolIndex: 0,
            id: "call_1",
            name: "write",
            argumentsDelta: nil
        ))
        #expect(observation.hasOutput)

        observation.observe(.streamStarted(requestId: requestID, timestampMs: 1))
        #expect(observation.hasOutput)
    }

    @Test("tracked Responses transformer observes refusals even though they are never forwarded")
    func trackedResponsesObserveHiddenRefusals() async throws {
        let refusal = try ResponsesStreamEvent.decode(data: #"{"type":"response.refusal.delta","delta":"no","item_id":"refusal_1"}"#)
        let failed = try ResponsesStreamEvent.decode(data: responsesFailure)
        let raw = AsyncStream<Result<ResponsesStreamEvent, SamplingError>> { continuation in
            continuation.yield(.success(refusal))
            continuation.yield(.success(failed))
            continuation.finish()
        }
        let observation = SamplingOutputObservation()
        var emitted: [SamplingEvent] = []

        for await event in streamResponsesWithClientCustomTools(
            rawStream: raw,
            modelMetadata: nil,
            requestId: RequestId("hidden-refusal"),
            idleTimeout: .seconds(10),
            doomLoop: nil,
            clientCustomToolNames: [],
            outputObservation: observation
        ) {
            emitted.append(event)
        }

        #expect(observation.hasOutput)
        #expect(emitted.count == 2)
        guard case .streamStarted = emitted[0], case .failed = emitted[1] else {
            Issue.record("hidden refusal must not create a synthetic display event")
            return
        }
    }

    @Test("guarded Chat requests never replay after the first visible token")
    func chatOutputPreventsRetry() async {
        let transport = MockHTTPTransport(responses: [
            sseResponse([chatPartial, streamFailure]),
            sseResponse([chatRecovered]),
        ])
        let result = await submit(actor(transport: transport, retryOnlyBeforeOutput: true))

        guard case .failure(let error) = result else {
            Issue.record("a partially streamed request must not be replayed")
            return
        }
        #expect(error.isRetryable)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("default retry behavior remains unchanged after visible Chat output")
    func ordinaryChatRequestsStillRetry() async {
        let transport = MockHTTPTransport(responses: [
            sseResponse([chatPartial, streamFailure]),
            sseResponse([chatRecovered]),
        ])
        let result = await submit(actor(transport: transport, retryOnlyBeforeOutput: false))

        guard case .success(let (response, metrics)) = result else {
            Issue.record("legacy requests should retain their existing retry policy")
            return
        }
        #expect(response.assistantText() == "recovered")
        #expect(metrics.attempts == 2)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test("guarded requests still retry transport failures before generation starts")
    func failuresBeforeOutputStillRetry() async {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 500,
                    headers: ["Retry-After": "0"]
                ),
                body: Data(#"{"error":{"message":"transient"}}"#.utf8)
            ),
            sseResponse([chatRecovered]),
        ])
        let result = await submit(actor(transport: transport, retryOnlyBeforeOutput: true))

        guard case .success(let (response, metrics)) = result else {
            Issue.record("a request that never produced output should remain retryable")
            return
        }
        #expect(response.assistantText() == "recovered")
        #expect(metrics.attempts == 2)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test(
        "hidden Responses refusal and hosted search both close the retry window",
        arguments: [
            #"{"type":"response.refusal.delta","delta":"no","item_id":"item_1"}"#,
            #"{"type":"response.web_search_call.searching","item_id":"search_1","output_index":0}"#,
            #"{"type":"response.x_search_call.in_progress","item_id":"search_2","output_index":0}"#,
        ]
    )
    func hiddenResponsesOutputPreventsRetry(_ hiddenOutput: String) async {
        let transport = MockHTTPTransport(responses: [
            sseResponse([hiddenOutput, responsesFailure]),
            sseResponse([responsesRecovered]),
        ])
        let result = await submit(actor(
            transport: transport,
            backend: .responses,
            retryOnlyBeforeOutput: true
        ))

        guard case .failure = result else {
            Issue.record("provider execution occurred before the error and must not be replayed")
            return
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("an empty Responses failure still permits one retry before any output")
    func outputlessResponsesFailureStillRetries() async {
        let transport = MockHTTPTransport(responses: [
            sseResponse([responsesFailure]),
            sseResponse([responsesRecovered]),
        ])
        let result = await submit(actor(
            transport: transport,
            backend: .responses,
            retryOnlyBeforeOutput: true
        ))

        guard case .success(let (response, metrics)) = result else {
            Issue.record("an empty provider failure is not proof of output")
            return
        }
        #expect(response.assistantText() == "recovered")
        #expect(metrics.attempts == 2)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test("guarded Messages requests never retry after streamed text")
    func messagesOutputPreventsRetry() async throws {
        let events: [MessageStreamEvent] = [
            .messageStart(message: MessagesResponse(
                id: "msg_1",
                type: "message",
                role: "assistant",
                content: [],
                model: "test-model",
                usage: MessagesUsage(inputTokens: 3)
            )),
            .contentBlockStart(index: 0, contentBlock: .text(text: "", cacheControl: nil)),
            .contentBlockDelta(index: 0, delta: .textDelta(text: "already visible")),
            .error(error: StreamError(type: "overloaded", message: "provider interrupted")),
        ]
        let encoded = try events.map { event in
            try #require(String(data: JSONEncoder().encode(event), encoding: .utf8))
        }
        let transport = MockHTTPTransport(responses: [
            sseResponse(encoded),
            sseResponse(encoded),
        ])
        let result = await submit(actor(
            transport: transport,
            backend: .messages,
            retryOnlyBeforeOutput: true
        ))

        guard case .failure = result else {
            Issue.record("Messages output must close the same retry window")
            return
        }
        #expect(transport.recordedRequests.count == 1)
    }
}
