// MouseInputStressTests.swift
//
// Empirical stress tests for SGR coordinate parsing, MouseStreamParser byte-level
// passthrough invariants, coordinate overflow protection, and high throughput decoding.

import Foundation
import Testing
@testable import OpenGrokTerminalCore

private func bytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

private func sgrBytes(_ button: Int, _ col: Int, _ row: Int, press: Bool) -> [UInt8] {
    bytes("\u{1B}[<\(button);\(col);\(row)\(press ? "M" : "m")")
}

@Suite("Mouse Input & SGR Parsing Stress Tests")
struct MouseInputStressTests {

    @Test("High throughput: 10,000 SGR reports decoded directly")
    func highThroughputSGRDecoder() {
        for i in 0..<10_000 {
            let button = i % 4
            let col = (i * 17) % 5000 + 1
            let row = (i * 31) % 3000 + 1
            let press = (i % 2) == 0

            let raw = sgrBytes(button, col, row, press: press)
            let result = MouseReportDecoder.decodeSGR(raw)

            guard case .event(let event) = result else {
                Issue.record("Failed to decode SGR report at index \(i)")
                return
            }

            #expect(event.x == col - 1)
            #expect(event.y == row - 1)
            #expect(event.kind == (press ? .down : .up))
        }
    }

    @Test("High throughput: MouseStreamParser under arbitrary chunk sizes")
    func highThroughputMouseStreamParser() {
        var rawStream: [UInt8] = []
        for i in 0..<2_000 {
            let button = (i % 3)
            let col = (i * 13) % 1000 + 1
            let row = (i * 29) % 1000 + 1
            rawStream.append(contentsOf: sgrBytes(button, col, row, press: true))
        }

        for chunkSize in [1, 7, 13, 64, 256] {
            var parser = MouseStreamParser()
            var eventCount = 0
            var index = 0

            while index < rawStream.count {
                let end = min(index + chunkSize, rawStream.count)
                let chunk = Array(rawStream[index..<end])
                let outputs = parser.feed(chunk)
                for output in outputs {
                    if case .mouse = output {
                        eventCount += 1
                    }
                }
                index = end
            }

            let finalOutputs = parser.finish()
            for output in finalOutputs {
                if case .mouse = output {
                    eventCount += 1
                }
            }

            #expect(eventCount == 2_000, "Chunk size \(chunkSize) decoded \(eventCount) events, expected 2,000")
        }
    }

    @Test("Byte Lossless Invariant: Every input byte must be returned as passthrough or event")
    func byteLosslessPassthroughInvariant() {
        var rawInput: [UInt8] = []

        rawInput.append(contentsOf: bytes("Hello World!"))
        rawInput.append(contentsOf: sgrBytes(0, 10, 20, press: true))
        rawInput.append(contentsOf: bytes("\u{1B}[<;1;1M")) // malformed SGR (missing button)
        rawInput.append(contentsOf: bytes("\u{1B}[<0;10"))   // partial SGR (unterminated)
        rawInput.append(contentsOf: Array("😀🎉".utf8))       // UTF-8
        rawInput.append(contentsOf: sgrBytes(2, 500, 300, press: false))

        var parser = MouseStreamParser()
        let outputs = parser.feed(rawInput) + parser.finish()

        var reconstitutedBytes: [UInt8] = []
        for output in outputs {
            switch output {
            case .passthrough(let b):
                reconstitutedBytes.append(contentsOf: b)
            case .mouse(let event):
                let pressStr = event.kind == .up ? "m" : "M"
                let wireStr = "\u{1B}[<\(event.button == MouseEvent.noButton ? 3 : (event.resolvedButton.code ?? 0));\(event.x + 1);\(event.y + 1)\(pressStr)"
                reconstitutedBytes.append(contentsOf: bytes(wireStr))
            }
        }

        #expect(reconstitutedBytes.count == rawInput.count, "Byte length mismatch! Input: \(rawInput.count), Output: \(reconstitutedBytes.count)")
        #expect(reconstitutedBytes == rawInput, "Byte content mismatch!")
    }

    @Test("SGR Coordinate Boundary Limits & Overflow Protection")
    func sgrCoordinateLimitsAndOverflow() {
        if case .event(let e) = MouseReportDecoder.decodeSGR(sgrBytes(0, 1, 1, press: true)) {
            #expect(e.x == 0 && e.y == 0)
        } else { Issue.record("Min coordinate failed") }

        if case .event(let e) = MouseReportDecoder.decodeSGR(sgrBytes(0, 3840, 2160, press: true)) {
            #expect(e.x == 3839 && e.y == 2159)
        } else { Issue.record("4K coordinate failed") }

        if case .event(let e) = MouseReportDecoder.decodeSGR(sgrBytes(0, 9_999_999, 9_999_999, press: true)) {
            #expect(e.x == 9_999_998 && e.y == 9_999_998)
        } else { Issue.record("Max supported coordinate failed") }

        // Overflow attempt (9 digits >= 100_000_000) must return .malformed
        #expect(MouseReportDecoder.decodeSGR(sgrBytes(0, 100_000_000, 5, press: true)) == .malformed)
        #expect(MouseReportDecoder.decodeSGR(bytes("\u{1B}[<0;999999999999;5M")) == .malformed)

        #expect(MouseReportDecoder.decodeSGR(bytes("\u{1B}[<;1;1M")) == .malformed)
        #expect(MouseReportDecoder.decodeSGR(bytes("\u{1B}[<0;;1M")) == .malformed)
        #expect(MouseReportDecoder.decodeSGR(bytes("\u{1B}[<0;1;M")) == .malformed)
        #expect(MouseReportDecoder.decodeSGR(bytes("\u{1B}[<0;abc;1M")) == .malformed)
    }
}
