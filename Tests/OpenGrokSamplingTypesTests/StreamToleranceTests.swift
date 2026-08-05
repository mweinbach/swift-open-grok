// StreamToleranceTests.swift
//
// OpenCode Go emits Chat Completions chunks that omit envelope metadata other
// OpenAI-compatible providers always send. Each field below was tolerated by a
// separate upstream fix after a live stream aborted on it:
//
//   6674bca5 — id-less chunks
//   5d5c880e — minimal metadata (object, created)
//   df4374c2 — metadata-light terminal chunks (model)
//
// `choices` stays required: it carries the payload, so a chunk without it is
// genuinely malformed rather than merely terse.

import Foundation
import Testing
@testable import OpenGrokSamplingTypes

@Suite("Chat Completions chunk tolerance")
struct StreamToleranceTests {
    private func decode(_ json: String) throws -> ChatCompletionChunk {
        try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(json.utf8))
    }

    /// Provenance: Rust `test_chat_completion_chunk_deserializes_without_id`.
    @Test("a chunk without an id still assembles")
    func withoutID() throws {
        let chunk = try decode(#"""
        {
          "object": "chat.completion.chunk",
          "created": 1,
          "model": "deepseek-v4-pro",
          "choices": [{
            "index": 0,
            "delta": {"role": "assistant", "content": "hello"},
            "finish_reason": null
          }]
        }
        """#)
        #expect(chunk.id.isEmpty)
        #expect(chunk.model == "deepseek-v4-pro")
        #expect(chunk.choices.count == 1)
        #expect(chunk.choices[0].delta.content == "hello")
    }

    /// Provenance: Rust
    /// `test_chat_completion_chunk_deserializes_without_unused_metadata`
    /// at 5d5c880e (object and created dropped).
    @Test("a chunk without object or created still assembles")
    func withoutObjectOrCreated() throws {
        let chunk = try decode(#"""
        {
          "model": "deepseek-v4-pro",
          "choices": [{
            "index": 0,
            "delta": {"role": "assistant", "content": "hello"},
            "finish_reason": null
          }]
        }
        """#)
        #expect(chunk.id.isEmpty)
        #expect(chunk.object.isEmpty)
        #expect(chunk.created == 0)
        #expect(chunk.model == "deepseek-v4-pro")
        #expect(chunk.choices.count == 1)
    }

    /// Provenance: the same test at df4374c2, after `model` was also dropped.
    /// This is the terminal-chunk shape: metadata-light but carrying the stop.
    @Test("a metadata-light terminal chunk still assembles")
    func metadataLightTerminal() throws {
        let chunk = try decode(#"""
        {
          "choices": [{
            "index": 0,
            "delta": {"role": "assistant", "content": "hello"},
            "finish_reason": null
          }]
        }
        """#)
        #expect(chunk.id.isEmpty)
        #expect(chunk.object.isEmpty)
        #expect(chunk.created == 0)
        #expect(chunk.model.isEmpty)
        #expect(chunk.choices.count == 1)
    }

    @Test("a terminal chunk carrying only a finish reason still assembles")
    func terminalFinishReasonOnly() throws {
        let chunk = try decode(#"""
        {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """#)
        #expect(chunk.choices[0].finishReason == .stop)
        #expect(chunk.model.isEmpty)
    }

    /// The tolerance is deliberately bounded: a chunk with no `choices` has no
    /// payload to assemble, so it must still be rejected.
    @Test("choices remains required")
    func choicesRequired() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"1","object":"chat.completion.chunk","model":"m"}"#)
        }
    }

    /// Tolerating absent fields must not change how present fields decode.
    @Test("a fully populated chunk is unaffected")
    func fullyPopulated() throws {
        let chunk = try decode(#"""
        {
          "id": "chatcmpl-1",
          "object": "chat.completion.chunk",
          "created": 1234567890,
          "model": "grok-4.5",
          "system_fingerprint": "fp_1",
          "choices": [{
            "index": 0,
            "delta": {"role": "assistant", "content": "hi"},
            "finish_reason": "stop"
          }]
        }
        """#)
        #expect(chunk.id == "chatcmpl-1")
        #expect(chunk.object == "chat.completion.chunk")
        #expect(chunk.created == 1_234_567_890)
        #expect(chunk.model == "grok-4.5")
        #expect(chunk.systemFingerprint == "fp_1")
        #expect(chunk.choices[0].finishReason == .stop)
    }

    /// An empty `system_fingerprint` normalizes to nil; that behavior predates
    /// this tolerance work and must survive it.
    @Test("an empty system fingerprint still normalizes to nil")
    func emptyFingerprint() throws {
        let chunk = try decode(#"""
        {"model":"m","system_fingerprint":"","choices":[{"index":0,"delta":{}}]}
        """#)
        #expect(chunk.systemFingerprint == nil)
    }
}
