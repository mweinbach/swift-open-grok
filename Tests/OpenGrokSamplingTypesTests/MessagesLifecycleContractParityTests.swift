import Foundation
import Testing
@testable import OpenGrokSamplingTypes

@Suite("Messages lifecycle wire-contract parity")
struct MessagesLifecycleContractParityTests {
    @Test("terminal message delta preserves the matched provider stop sequence")
    func terminalMessageDeltaPreservesMatchedSequence() throws {
        let payload = Data(
            #"{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":"END"},"usage":{"output_tokens":7}}"#.utf8
        )
        let event = try JSONDecoder().decode(MessageStreamEvent.self, from: payload)

        guard case .messageDelta(let delta, let usage) = event else {
            Issue.record("expected a terminal Messages delta")
            return
        }
        #expect(delta.stopReason == .stopSequence)
        #expect(delta.stopSequence == "END")
        #expect(usage.outputTokens == 7)
    }

    @Test("legacy terminal message deltas decode without a matched stop sequence")
    func legacyTerminalMessageDeltaRemainsCompatible() throws {
        let payload = Data(
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#.utf8
        )
        let event = try JSONDecoder().decode(MessageStreamEvent.self, from: payload)

        guard case .messageDelta(let delta, _) = event else {
            Issue.record("expected a terminal Messages delta")
            return
        }
        #expect(delta.stopReason == .endTurn)
        #expect(delta.stopSequence == nil)
    }

    @Test("nullable stop sequence does not discard refusal diagnostics")
    func nullableSequencePreservesRefusalDetails() throws {
        let payload = Data(
            #"{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","explanation":"Blocked"}}"#.utf8
        )
        let delta = try JSONDecoder().decode(MessageDeltaBody.self, from: payload)

        #expect(delta.stopReason == .refusal)
        #expect(delta.stopSequence == nil)
        #expect(delta.stopDetails?.explanation == "Blocked")
    }

    @Test("matched stop sequences encode with the Rust-compatible snake-case key")
    func matchedStopSequenceWireKey() throws {
        let delta = MessageDeltaBody(stopReason: .stopSequence, stopSequence: "</answer>")
        let encoded = try JSONEncoder().encode(delta)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["stop_sequence"] as? String == "</answer>")
        #expect(object["stop_reason"] as? String == "stop_sequence")
        #expect(try JSONDecoder().decode(MessageDeltaBody.self, from: encoded) == delta)
    }

    @Test("absent matched sequences stay omitted from the existing terminal-delta wire shape")
    func absentStopSequenceRemainsOmitted() throws {
        let delta = MessageDeltaBody(stopReason: .endTurn)
        let encoded = try JSONEncoder().encode(delta)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["stop_sequence"] == nil)
    }

    @Test("conversation responses keep existing defaults while preserving provider-native completion metadata")
    func conversationResponsePreservesNativeMetadata() {
        let legacy = ConversationResponse(items: [.assistant("answer")], stopReason: .stop)
        #expect(legacy.messageID == nil)
        #expect(legacy.rawStopReason == nil)
        #expect(legacy.stopSequence == nil)

        let response = ConversationResponse(
            items: [.assistant("answer")],
            stopReason: .stop,
            stopMessage: "matched delimiter",
            messageID: "msg_provider_123",
            rawStopReason: "stop_sequence",
            stopSequence: "END"
        )

        #expect(response.stopReason == .stop)
        #expect(response.stopMessage == "matched delimiter")
        #expect(response.messageID == "msg_provider_123")
        #expect(response.rawStopReason == "stop_sequence")
        #expect(response.stopSequence == "END")
        #expect(response.assistantText() == "answer")
    }

    @Test("unknown future stop reasons and empty matched sequences survive decoding verbatim")
    func futureStopReasonAndEmptySequenceRemainLossless() throws {
        let payload = Data(#"{"stop_reason":"future_provider_stop","stop_sequence":""}"#.utf8)
        let delta = try JSONDecoder().decode(MessageDeltaBody.self, from: payload)

        #expect(delta.stopReason == .unknown("future_provider_stop"))
        #expect(delta.stopSequence == "")
    }
}
