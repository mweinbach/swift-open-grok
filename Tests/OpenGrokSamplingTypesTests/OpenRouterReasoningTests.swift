import Foundation
import OpenGrokShared
import Testing
@testable import OpenGrokSamplingTypes

@Suite("OpenRouter Chat Completions reasoning wire parity")
struct OpenRouterReasoningTests {
    private func decode(_ json: String) throws -> ChatChunkDelta {
        try JSONDecoder().decode(ChatChunkDelta.self, from: Data(json.utf8))
    }

    @Test("OpenRouter reasoning field decodes without dropping whitespace")
    func reasoningField() throws {
        let delta = try decode(#"{"reasoning":"  think this through "}"#)

        #expect(delta.reasoning == "  think this through ")
        #expect(delta.reasoningText == "  think this through ")
        #expect(delta.reasoningContent == nil)
    }

    @Test("DeepSeek reasoning content takes precedence over OpenRouter alternatives")
    func precedence() throws {
        let delta = try decode(#"""
        {
          "reasoning_content": "canonical",
          "reasoning": "fallback",
          "reasoning_details": [{"type":"reasoning.text","text":"details"}]
        }
        """#)

        #expect(delta.reasoningText == "canonical")
    }

    @Test("empty direct fields fall through to joined text and summary details")
    func structuredFallback() throws {
        let delta = try decode(#"""
        {
          "reasoning_content": "",
          "reasoning": "",
          "reasoning_details": [
            {"type":"reasoning.encrypted","data":"opaque"},
            {"type":"reasoning.text","text":"first"},
            {"type":"reasoning.summary","summary":" second"},
            {"type":"reasoning.summary","text":" third"},
            {"type":"future.reasoning","text":"ignored"}
          ]
        }
        """#)

        #expect(delta.reasoningText == "first second third")
        #expect(delta.reasoningDetails[0].extra["data"] == .string("opaque"))
    }

    @Test("unknown detail fields survive a decode and encode round trip")
    func unknownFieldsRoundTrip() throws {
        let delta = try decode(#"""
        {"reasoning_details":[{"type":"reasoning.text","text":"hello","id":"r1","nested":{"future":true}}]}
        """#)

        let encoded = try JSONEncoder().encode(delta)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let detail = decoded["reasoning_details"]?.arrayValue?.first

        #expect(detail?["id"] == .string("r1"))
        #expect(detail?["nested"]?["future"] == .bool(true))
        #expect(delta.reasoningDetails.first?.displayText == "hello")
    }

    @Test("null reasoning details behave like an absent empty array")
    func nullDetails() throws {
        let delta = try decode(#"{"reasoning_details":null,"tool_calls":null}"#)

        #expect(delta.reasoningDetails.isEmpty)
        #expect(delta.toolCalls.isEmpty)
        #expect(delta.reasoningText.isEmpty)
    }

    @Test("empty detail arrays do not change existing serialized chunks")
    func omitEmptyDetails() throws {
        let encoded = try JSONEncoder().encode(ChatChunkDelta(content: "hello"))
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)

        #expect(value["reasoning"] == nil)
        #expect(value["reasoning_details"] == nil)
    }
}
