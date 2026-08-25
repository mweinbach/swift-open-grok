import Foundation
import Testing
@testable import OpenGrokFileTools

@Suite("Document inflater cross-platform raw DEFLATE parity")
struct DocumentInflaterCrossPlatformParityTests {
    private static let plain = Data(
        "PowerPoint raw DEFLATE parity: repeated slide text repeated slide text repeated slide text".utf8
    )

    private static let rawDeflate = Data([
        0x0b, 0xc8, 0x2f, 0x4f, 0x2d, 0x0a, 0xc8, 0xcf, 0xcc, 0x2b, 0x51, 0x28,
        0x4a, 0x2c, 0x57, 0x70, 0x71, 0x75, 0xf3, 0x71, 0x0c, 0x71, 0x55, 0x28,
        0x48, 0x2c, 0xca, 0x2c, 0xa9, 0xb4, 0x52, 0x28, 0x4a, 0x2d, 0x48, 0x4d,
        0x2c, 0x49, 0x4d, 0x51, 0x28, 0xce, 0xc9, 0x4c, 0x49, 0x55, 0x28, 0x49,
        0xad, 0x28, 0x21, 0x56, 0x0c, 0x00,
    ])

    private static let wrappedDeflate = Data([0x78, 0xda])
        + rawDeflate + Data([0xc8, 0x82, 0x21, 0x0a])

    private static let inflationBomb = Data([
        0xed, 0xc1, 0x31, 0x01, 0x00, 0x00, 0x00, 0xc2, 0xa0,
        0x6c, 0xeb, 0x5f, 0xca, 0xc3, 0x1a, 0x40, 0x01,
    ]) + Data(repeating: 0, count: 126) + Data([0xdc, 0x00])

    @Test("PowerPoint raw DEFLATE streams decode with exact declared lengths")
    func rawDeflateFixture() throws {
        let output = try DocumentInflater.inflate(
            Self.rawDeflate,
            raw: true,
            expectedSize: Self.plain.count,
            maximumOutput: 4096,
            deadline: DocumentExtractionDeadline()
        )
        #expect(output == Self.plain)
    }

    @Test("PDF zlib-wrapped streams retain the existing decompression path")
    func wrappedDeflateFixture() throws {
        let output = try DocumentInflater.inflate(
            Self.wrappedDeflate,
            raw: false,
            expectedSize: Self.plain.count,
            maximumOutput: 4096,
            deadline: DocumentExtractionDeadline()
        )
        #expect(output == Self.plain)
    }

    @Test("empty raw DEFLATE streams decode without fabricating output")
    func emptyRawDeflateFixture() throws {
        let output = try DocumentInflater.inflate(
            Data([0x03, 0x00]),
            raw: true,
            expectedSize: 0,
            maximumOutput: 4096,
            deadline: DocumentExtractionDeadline()
        )
        #expect(output.isEmpty)
    }

    @Test("truncated, malformed, and trailing raw DEFLATE bytes fail closed")
    func rejectsMalformedStreams() {
        let malformed = [
            Data(Self.rawDeflate.dropLast()),
            Self.rawDeflate + Data([0x00]),
            Data([0x07]),
            Data(),
        ]
        for stream in malformed {
            #expect(throws: DocumentExtractionError.self) {
                try DocumentInflater.inflate(
                    stream,
                    raw: true,
                    expectedSize: nil,
                    maximumOutput: 4096,
                    deadline: DocumentExtractionDeadline()
                )
            }
        }
    }

    @Test("zlib-wrapped streams reject undeclared trailing bytes")
    func rejectsWrappedTrailingBytes() {
        #expect(throws: DocumentExtractionError.self) {
            try DocumentInflater.inflate(
                Self.wrappedDeflate + Data([0x00]),
                raw: false,
                expectedSize: Self.plain.count,
                maximumOutput: 4096,
                deadline: DocumentExtractionDeadline()
            )
        }
    }

    @Test("declared output sizes must match the decompressed stream")
    func rejectsIncorrectDeclaredSize() {
        #expect(throws: DocumentExtractionError.self) {
            try DocumentInflater.inflate(
                Self.rawDeflate,
                raw: true,
                expectedSize: Self.plain.count + 1,
                maximumOutput: 4096,
                deadline: DocumentExtractionDeadline()
            )
        }
    }

    @Test("high-ratio raw DEFLATE streams cannot exceed the output ceiling")
    func rejectsInflationBomb() {
        do {
            let output = try DocumentInflater.inflate(
                Self.inflationBomb,
                raw: true,
                expectedSize: nil,
                maximumOutput: 4096,
                deadline: DocumentExtractionDeadline()
            )
            Issue.record("inflation bomb unexpectedly produced \(output.count) bytes")
        } catch DocumentExtractionError.limit(let message) {
            #expect(message.contains("output limit"))
        } catch {
            Issue.record("inflation bomb raised the wrong error: \(error)")
        }
    }
}
