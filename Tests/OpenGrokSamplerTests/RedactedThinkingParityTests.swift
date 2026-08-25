import Foundation
import OpenGrokHTTP
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

@Suite("Native Messages redacted-thinking stream parity")
struct RedactedThinkingParityTests {
    private func messageStart() -> MessageStreamEvent {
        .messageStart(message: MessagesResponse(
            id: "msg_redacted",
            type: "message",
            role: "assistant",
            content: [],
            model: "claude-native",
            usage: MessagesUsage(inputTokens: 12)
        ))
    }

    private func transport(for events: [MessageStreamEvent]) throws -> MockHTTPTransport {
        let encoded = try events.map { event in
            try #require(String(data: JSONEncoder().encode(event), encoding: .utf8))
        }
        let body = encoded.map { "data: \($0)\r\n\r\n" }.joined()
            + "data: [DONE]\r\n\r\n"
        return MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data(body.utf8)
            ),
        ])
    }

    @Test("opaque redacted-thinking provider events decode and round-trip without exposing plaintext")
    func redactedThinkingEventRoundTrips() throws {
        let fixture = Data(
            #"{"type":"content_block_start","index":7,"content_block":{"type":"redacted_thinking","data":"EvwBCkgY...opaque"}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(MessageStreamEvent.self, from: fixture)
        guard case .contentBlockStart(let index, .redactedThinking(let data)) = decoded else {
            Issue.record("redacted provider reasoning must decode as its own opaque variant")
            return
        }
        #expect(index == 7)
        #expect(data == "EvwBCkgY...opaque")

        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
        #expect(encoded["content_block"]?["type"] == .string("redacted_thinking"))
        #expect(encoded["content_block"]?["data"] == .string("EvwBCkgY...opaque"))
        #expect(encoded["content_block"]?["thinking"] == nil)
        #expect(encoded["content_block"]?["signature"] == nil)
    }

    @Test("real CRLF Messages streams survive opaque reasoning and retain adjacent text and signed thinking")
    func actualProviderStreamSurvivesRedactedThinking() async throws {
        let opaquePayload = "opaque-provider-ciphertext-must-never-appear"
        let mock = try transport(for: [
            messageStart(),
            .contentBlockStart(index: 0, contentBlock: .text(text: "", cacheControl: nil)),
            .contentBlockDelta(index: 0, delta: .textDelta(text: "before")),
            .contentBlockStop(index: 0),
            .contentBlockStart(index: 1, contentBlock: .redactedThinking(data: opaquePayload)),
            .contentBlockStop(index: 1),
            .contentBlockStart(index: 2, contentBlock: .thinking(thinking: "", signature: "")),
            .contentBlockDelta(index: 2, delta: .thinkingDelta(thinking: "visible reasoning")),
            .contentBlockDelta(index: 2, delta: .signatureDelta(signature: "signed-reasoning")),
            .contentBlockStop(index: 2),
            .contentBlockStart(index: 3, contentBlock: .text(text: "", cacheControl: nil)),
            .contentBlockDelta(index: 3, delta: .textDelta(text: "after")),
            .contentBlockStop(index: 3),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 5)
            ),
            .messageStop,
        ])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://messages.example.test",
                model: "claude-native",
                apiBackend: .messages,
                provider: .xai
            ),
            transport: mock
        )

        let response = try await client.conversationCollect(
            ConversationRequest(items: [.user("hello")]),
            idleTimeout: .seconds(5)
        )

        #expect(mock.recordedRequests.count == 1)
        #expect(mock.recordedRequests.first?.url.path == "/v1/messages")
        #expect(response.assistantText() == "before\nafter")
        #expect(response.messageID == "msg_redacted")
        #expect(response.usage?.completionTokens == 5)
        #expect(response.reasoningItems().count == 1)
        #expect(response.reasoningItems().first?.encryptedContent == "signed-reasoning")
        #expect(response.reasoningItems().first?.summary.first?.text == "visible reasoning")
        #expect(!response.assistantText().contains(opaquePayload))
    }

    @Test("a response containing only opaque reasoning completes without invented tokens or history")
    func opaqueOnlyResponseCompletesWithoutLeakingPayload() async throws {
        let opaquePayload = "redacted-only-secret"
        let mock = try transport(for: [
            messageStart(),
            .contentBlockStart(index: 0, contentBlock: .redactedThinking(data: opaquePayload)),
            .contentBlockStop(index: 0),
            .messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 0)
            ),
            .messageStop,
        ])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://messages.example.test",
                model: "claude-native",
                apiBackend: .messages,
                provider: .xai
            ),
            transport: mock
        )

        let response = try await client.conversationCollect(
            ConversationRequest(items: [.user("hello")]),
            idleTimeout: .seconds(5)
        )

        #expect(response.assistantText().isEmpty)
        #expect(response.reasoningItems().isEmpty)
        #expect(response.messageID == "msg_redacted")
        #expect(response.usage?.completionTokens == 0)
        #expect(mock.recordedRequests.count == 1)
    }

    @Test("redacted blocks do not emit first-token, reasoning-completed, or opaque text events")
    func opaqueBlockNeverBecomesModelOutput() async {
        let opaquePayload = "do-not-emit-this-opaque-payload"
        let raw = makeResultStream([
            Result<MessageStreamEvent, SamplingError>.success(messageStart()),
            .success(.contentBlockStart(index: 0, contentBlock: .redactedThinking(data: opaquePayload))),
            .success(.contentBlockStop(index: 0)),
            .success(.messageStop),
        ])
        var events: [SamplingEvent] = []
        for await event in streamMessages(
            rawStream: raw,
            modelMetadata: nil,
            requestId: RequestId("redacted-reasoning"),
            idleTimeout: .seconds(5)
        ) {
            events.append(event)
        }

        #expect(events.count == 3)
        guard events.count == 3,
              case .streamStarted = events[0],
              case .responseStarted = events[1],
              case .completed(_, let response, _) = events[2]
        else {
            Issue.record("opaque reasoning must produce only the ordinary response lifecycle")
            return
        }
        #expect(response.assistantText().isEmpty)
        #expect(response.reasoningItems().isEmpty)
        #expect(!events.contains { event in
            switch event {
            case .firstToken, .channelToken, .reasoningCompleted:
                true
            default:
                false
            }
        })
    }

    @Test("unknown content-block types remain fail-closed")
    func unrelatedUnknownContentBlocksRemainRejected() {
        let fixture = Data(
            #"{"type":"content_block_start","index":0,"content_block":{"type":"unrecognized_future_block","data":"opaque"}}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MessageStreamEvent.self, from: fixture)
        }
    }
}
