import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokSampler

@Suite("Native Messages producer lifecycle parity")
struct NativeMessagesLifecycleParityTests {
    private func start(
        id: String = "msg_provider_123",
        model: String = "claude-native",
        inputTokens: UInt32 = 10,
        cacheReadTokens: UInt32 = 0,
        cacheCreationTokens: UInt32 = 0
    ) -> MessageStreamEvent {
        .messageStart(message: MessagesResponse(
            id: id,
            type: "message",
            role: "assistant",
            content: [],
            model: model,
            usage: MessagesUsage(
                inputTokens: inputTokens,
                cacheCreationInputTokens: cacheCreationTokens,
                cacheReadInputTokens: cacheReadTokens
            )
        ))
    }

    private func collect(_ events: [MessageStreamEvent]) async -> [SamplingEvent] {
        var collected: [SamplingEvent] = []
        for await event in streamMessages(
            rawStream: makeResultStream(events.map { .success($0) }),
            modelMetadata: nil,
            requestId: RequestId("native-messages-lifecycle"),
            idleTimeout: .seconds(60)
        ) {
            collected.append(event)
        }
        return collected
    }

    private func completed(_ events: [SamplingEvent]) throws -> ConversationResponse {
        let terminal = try #require(events.last)
        guard case .completed(_, let response, _) = terminal else {
            Issue.record("expected a terminal completed event")
            throw LifecycleTestError.missingCompletion
        }
        return response
    }

    @Test("message_start exposes actual provider identity and all three prompt buckets before content")
    func startMetadataPrecedesContent() async throws {
        let events = await collect([
            start(
                id: "msg_real_wire_id",
                model: "claude-opus-native",
                inputTokens: 100,
                cacheReadTokens: 40,
                cacheCreationTokens: 25
            ),
            .contentBlockStart(index: 0, contentBlock: .text(text: "", cacheControl: nil)),
            .contentBlockDelta(index: 0, delta: .textDelta(text: "answer")),
            .contentBlockStop(index: 0),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 6)
            ),
            .messageStop,
        ])

        guard case .streamStarted = events[0],
              case .responseStarted(
                let requestID,
                let messageID,
                let model,
                let input,
                let cachedRead,
                let cachedCreation
              ) = events[1]
        else {
            Issue.record("response start must immediately follow stream start")
            return
        }
        #expect(requestID == RequestId("native-messages-lifecycle"))
        #expect(messageID == "msg_real_wire_id")
        #expect(model == "claude-opus-native")
        #expect(input == 100)
        #expect(cachedRead == 40)
        #expect(cachedCreation == 25)

        let response = try completed(events)
        #expect(response.messageID == "msg_real_wire_id")
        #expect(response.rawStopReason == "end_turn")
        #expect(response.usage?.promptTokens == 165)
        #expect(response.usage?.cachedPromptTokens == 40)
        #expect(response.usage?.cacheCreationPromptTokens == 25)
    }

    @Test("an opened contentless zero-usage response retains its identity without inventing usage")
    func emptyResponseStillHasLifecycle() async throws {
        let events = await collect([
            start(id: "msg_empty", inputTokens: 0),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 0)
            ),
            .messageStop,
        ])

        #expect(events.count == 3)
        guard case .responseStarted(_, let messageID, _, _, _, _) = events[1] else {
            Issue.record("expected response-start event for a contentless response")
            return
        }
        #expect(messageID == "msg_empty")
        let response = try completed(events)
        #expect(response.messageID == "msg_empty")
        #expect(response.rawStopReason == "end_turn")
        #expect(response.usage == nil)
    }

    @Test("terminal cache buckets replace their initial values while response-start stays truthful")
    func deltaOverridesWithoutDoubleCounting() async throws {
        let events = await collect([
            start(inputTokens: 100, cacheReadTokens: 40, cacheCreationTokens: 25),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(
                    outputTokens: 9,
                    inputTokens: 120,
                    cacheReadInputTokens: 35,
                    cacheCreationInputTokens: 30
                )
            ),
            .messageStop,
        ])

        guard case .responseStarted(_, _, _, let initial, let initialRead, let initialWrite) = events[1]
        else {
            Issue.record("expected original message-start accounting")
            return
        }
        #expect(initial == 100)
        #expect(initialRead == 40)
        #expect(initialWrite == 25)

        let usage = try #require(completed(events).usage)
        #expect(usage.promptTokens == 185)
        #expect(usage.completionTokens == 9)
        #expect(usage.totalTokens == 194)
        #expect(usage.cachedPromptTokens == 35)
        #expect(usage.cacheCreationPromptTokens == 30)
    }

    @Test("each thinking block emits its own final signature in exact content order")
    func thinkingSignaturesRemainOrderedPerBlock() async throws {
        let events = await collect([
            start(),
            .contentBlockStart(index: 0, contentBlock: .thinking(thinking: "", signature: "initial")),
            .contentBlockDelta(index: 0, delta: .thinkingDelta(thinking: "first")),
            .contentBlockDelta(index: 0, delta: .signatureDelta(signature: "stale")),
            .contentBlockDelta(index: 0, delta: .signatureDelta(signature: "signature-one")),
            .contentBlockStop(index: 0),
            .contentBlockStop(index: 0),
            .contentBlockStart(index: 1, contentBlock: .text(text: "", cacheControl: nil)),
            .contentBlockDelta(index: 1, delta: .textDelta(text: "between")),
            .contentBlockStop(index: 1),
            .contentBlockStart(index: 2, contentBlock: .thinking(thinking: "", signature: "")),
            .contentBlockDelta(index: 2, delta: .thinkingDelta(thinking: "second")),
            .contentBlockDelta(index: 2, delta: .signatureDelta(signature: "signature-two")),
            .contentBlockStop(index: 2),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 7)
            ),
            .messageStop,
        ])

        let lifecycle = events.compactMap { event -> String? in
            switch event {
            case .responseStarted(_, let messageID, _, _, _, _):
                "start:\(messageID)"
            case .channelToken(_, .reasoning, let text, _):
                "thinking:\(text)"
            case .channelToken(_, .text, let text, _):
                "text:\(text)"
            case .reasoningCompleted(_, let signature):
                "signature:\(signature)"
            default:
                nil
            }
        }
        #expect(lifecycle == [
            "start:msg_provider_123",
            "thinking:first",
            "signature:signature-one",
            "text:between",
            "thinking:second",
            "signature:signature-two",
        ])
        #expect(try completed(events).reasoningItems().first?.encryptedContent == "signature-two")
    }

    @Test("unsigned thinking blocks never invent reasoning completion metadata")
    func unsignedThinkingDoesNotEmitCompletion() async throws {
        let events = await collect([
            start(),
            .contentBlockStart(index: 0, contentBlock: .thinking(thinking: "reasoning", signature: "")),
            .contentBlockStop(index: 0),
            .messageStop,
        ])

        #expect(!events.contains {
            if case .reasoningCompleted = $0 { return true }
            return false
        })
        #expect(try completed(events).reasoningItems().first?.summary.first?.text == "reasoning")
    }

    @Test("matched stop sequences and their exact provider stop reason survive normalization")
    func matchedStopSequenceSurvives() async throws {
        let response = try completed(await collect([
            start(id: "msg_stop_sequence"),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .stopSequence, stopSequence: "\nEND\n"),
                usage: MessageDeltaUsage(outputTokens: 3)
            ),
            .messageStop,
        ]))

        #expect(response.messageID == "msg_stop_sequence")
        #expect(response.stopReason == .stop)
        #expect(response.rawStopReason == "stop_sequence")
        #expect(response.stopSequence == "\nEND\n")
    }

    @Test("every normalized Messages stop reason retains its exact forward-compatible wire spelling")
    func rawStopReasonsAreLossless() async throws {
        let cases: [(MessagesStopReason, String, StopReason)] = [
            (.endTurn, "end_turn", .stop),
            (.toolUse, "tool_use", .toolCalls),
            (.pauseTurn, "pause_turn", .stop),
            (.refusal, "refusal", .contentFilter),
            (.unknown("future_provider_stop"), "future_provider_stop", .stop),
        ]

        for (wireReason, exact, normalized) in cases {
            let response = try completed(await collect([
                start(),
                .messageDelta(
                    delta: MessageDeltaBody(stopReason: wireReason),
                    usage: MessageDeltaUsage(outputTokens: 1)
                ),
                .messageStop,
            ]))
            #expect(response.rawStopReason == exact)
            #expect(response.stopReason == normalized)
            #expect(response.stopSequence == nil)
        }
    }

    @Test("provider refusal detail and raw refusal reason survive together")
    func refusalRetainsExplanation() async throws {
        let response = try completed(await collect([
            start(),
            .messageDelta(
                delta: MessageDeltaBody(
                    stopReason: .refusal,
                    stopDetails: StopDetails(
                        type: "refusal",
                        category: "policy",
                        explanation: "Provider refused this request"
                    )
                ),
                usage: MessageDeltaUsage(outputTokens: 0)
            ),
            .messageStop,
        ]))

        #expect(response.stopReason == .contentFilter)
        #expect(response.rawStopReason == "refusal")
        #expect(response.stopMessage == "Provider refused this request")
    }

    @Test("response start remains ordered before streamed tools and exactly one argument completion")
    func toolLifecycleRetainsStartAndCompletion() async throws {
        let events = await collect([
            start(),
            .contentBlockStart(
                index: 0,
                contentBlock: .toolUse(id: "call_native", name: "read_file", input: .object([:]))
            ),
            .contentBlockDelta(index: 0, delta: .inputJsonDelta(partialJson: #"{"path":"#)),
            .contentBlockDelta(index: 0, delta: .inputJsonDelta(partialJson: #""file.swift"}"#)),
            .contentBlockStop(index: 0),
            .contentBlockStop(index: 0),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .toolUse),
                usage: MessageDeltaUsage(outputTokens: 4)
            ),
            .messageStop,
        ])

        let lifecycle = events.compactMap { event -> String? in
            switch event {
            case .responseStarted:
                "start"
            case .toolCallDelta(_, _, _, _, let delta):
                delta == nil ? "tool-open" : "tool-delta"
            case .toolCallArgumentsComplete:
                "tool-complete"
            case .completed:
                "completed"
            default:
                nil
            }
        }
        #expect(lifecycle == [
            "start", "tool-open", "tool-delta", "tool-delta", "tool-complete", "completed",
        ])
        let response = try completed(events)
        #expect(response.rawStopReason == "tool_use")
        #expect(response.toolCalls().first?.arguments == #"{"path":"file.swift"}"#)
    }

    @Test("a server error after response start emits exactly one failure and no completion")
    func startedResponseCanFailCleanly() async {
        let events = await collect([
            start(),
            .error(error: StreamError(type: "overloaded", message: "provider unavailable")),
        ])

        #expect(events.count == 3)
        guard case .responseStarted = events[1],
              case .failed(_, let error) = events[2]
        else {
            Issue.record("expected response-start followed by terminal failure")
            return
        }
        #expect(error.statusCode == 500)
        #expect(error.message.contains("provider unavailable"))
    }

    @Test("the real sampler actor preserves response identity and signature event ordering")
    func samplerActorForwardsLifecycleEvents() async throws {
        let providerEvents: [MessageStreamEvent] = [
            start(id: "msg_actor", inputTokens: 17, cacheReadTokens: 9, cacheCreationTokens: 4),
            .contentBlockStart(index: 0, contentBlock: .thinking(thinking: "", signature: "")),
            .contentBlockDelta(index: 0, delta: .thinkingDelta(thinking: "plan")),
            .contentBlockDelta(index: 0, delta: .signatureDelta(signature: "actor-signature")),
            .contentBlockStop(index: 0),
            .contentBlockStart(index: 1, contentBlock: .text(text: "", cacheControl: nil)),
            .contentBlockDelta(index: 1, delta: .textDelta(text: "result")),
            .contentBlockStop(index: 1),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .stopSequence, stopSequence: "DONE"),
                usage: MessageDeltaUsage(outputTokens: 6)
            ),
            .messageStop,
        ]
        let encoded = try providerEvents.map { event in
            try #require(String(data: JSONEncoder().encode(event), encoding: .utf8))
        }
        let body = encoded.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data(body.utf8)
            ),
        ])
        let actor = SamplerActor.spawn(
            config: SamplerConfig(
                apiKey: "test-key",
                baseURL: "https://messages.example.test",
                model: "claude-native",
                apiBackend: .messages,
                provider: .xai,
                maxRetries: 0
            ),
            retryPolicy: RetryPolicy(maxRetries: 0),
            transport: transport
        )
        actor.handle.submit(
            requestId: RequestId("actor-messages"),
            request: ConversationRequest(items: [.user("hello")])
        )

        var actual: [SamplingEvent] = []
        for await event in actor.events {
            actual.append(event)
            switch event {
            case .completed, .failed:
                break
            default:
                continue
            }
            break
        }

        guard case .responseStarted(_, let id, _, let input, let cachedRead, let cachedWrite) = actual[1]
        else {
            Issue.record("sampler actor dropped provider response-start metadata")
            return
        }
        #expect(id == "msg_actor")
        #expect(input == 17)
        #expect(cachedRead == 9)
        #expect(cachedWrite == 4)

        let signatureIndex = try #require(actual.firstIndex {
            if case .reasoningCompleted(_, "actor-signature") = $0 { return true }
            return false
        })
        let textIndex = try #require(actual.firstIndex {
            if case .channelToken(_, .text, "result", _) = $0 { return true }
            return false
        })
        #expect(signatureIndex < textIndex)

        let response = try completed(actual)
        #expect(response.messageID == "msg_actor")
        #expect(response.rawStopReason == "stop_sequence")
        #expect(response.stopSequence == "DONE")
        #expect(response.usage?.promptTokens == 30)
    }

    private enum LifecycleTestError: Error {
        case missingCompletion
    }
}
