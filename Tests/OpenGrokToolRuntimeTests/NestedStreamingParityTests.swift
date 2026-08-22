import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
@testable import OpenGrokToolRuntime
import Testing

@Suite("Upstream nested tool streaming invariants")
struct NestedStreamingParityTests {
    private func payload(_ progress: ToolProgress?) throws -> PartialResultPayload {
        let progress = try #require(progress)
        guard case .custom(_, let value) = progress else {
            throw ToolError.invalidArguments("expected custom progress")
        }
        return try value.decode(PartialResultPayload.self)
    }

    @Test("capped deltas retain producer total while draining without loss")
    func cappedDeltasRetainProducerTotal() throws {
        let bytes = Array("abcdefghi".utf8)
        let spec = StreamingSpec(subkind: "chunk", maxDeltaBytes: 4)
        var cursor: UInt64 = 0
        var chunks: [PartialResultPayload] = []

        while cursor < UInt64(bytes.count) {
            let progress = streamChunk(
                spec: spec,
                tail: bytes,
                total: UInt64(bytes.count),
                lastTotal: &cursor,
                truncated: false
            )
            chunks.append(try payload(progress))
        }

        #expect(chunks.map(\.delta) == ["abcd", "efgh", "i"])
        #expect(chunks.map(\.totalBytes) == [9, 9, 9])
        #expect(cursor == 9)
    }

    @Test("overflowed tails advance past upstream gaps without replay")
    func overflowedTailAdvancesPastGap() throws {
        let bytes = Array("tail".utf8)
        let spec = StreamingSpec(subkind: "chunk", maxDeltaBytes: 2)
        var cursor: UInt64 = 0

        let first = try payload(streamChunk(
            spec: spec,
            tail: bytes,
            total: 100,
            lastTotal: &cursor,
            truncated: false
        ))
        #expect(first.delta == "ta")
        #expect(first.totalBytes == 100)
        #expect(first.gap)
        #expect(cursor == 98)

        let second = try payload(streamChunk(
            spec: spec,
            tail: bytes,
            total: 100,
            lastTotal: &cursor,
            truncated: false
        ))
        #expect(second.delta == "il")
        #expect(!second.gap)
        #expect(cursor == 100)
    }

    @Test("UTF-8 tails and caps neither corrupt text nor stall")
    func utf8BoundariesRemainLossless() throws {
        let spec = StreamingSpec(subkind: "chunk", maxDeltaBytes: 1)
        let bytes = Array("🙂".utf8)
        var cursor: UInt64 = 0
        let wholeCharacter = try payload(streamChunk(
            spec: spec,
            tail: bytes,
            total: UInt64(bytes.count),
            lastTotal: &cursor,
            truncated: false
        ))
        #expect(wholeCharacter.delta == "🙂")
        #expect(cursor == 4)

        var splitCursor: UInt64 = 0
        let incomplete = try payload(streamChunk(
            spec: StreamingSpec(subkind: "chunk"),
            tail: [0x61, 0xC3],
            total: 2,
            lastTotal: &splitCursor,
            truncated: false
        ))
        #expect(incomplete.delta == "a")
        #expect(splitCursor == 1)
        let completed = try payload(streamChunk(
            spec: StreamingSpec(subkind: "chunk"),
            tail: Array("aé".utf8),
            total: 3,
            lastTotal: &splitCursor,
            truncated: false
        ))
        #expect(completed.delta == "é")
        #expect(splitCursor == 3)
    }

    @Test("partial-result wire decoding preserves UInt64 and rejects invalid fields")
    func partialPayloadDecodesStrictlyAndLosslessly() throws {
        let maximum = try JSONDecoder().decode(
            PartialResultPayload.self,
            from: Data(#"{"delta":"x","total_bytes":18446744073709551615}"#.utf8)
        )
        #expect(maximum.totalBytes == UInt64.max)

        for invalid in [
            #"{"delta":"x","total_bytes":-1}"#,
            #"{"delta":"x","total_bytes":1.5}"#,
            #"{"delta":"x","total_bytes":1,"truncated":"false"}"#,
            #"{"delta":"x","total_bytes":1,"gap":1}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(PartialResultPayload.self, from: Data(invalid.utf8))
            }
        }
    }
}
