import Foundation
import Testing
@testable import OpenGrokTerminalCore

@Suite("Terminal mouse and wrapped clipboard protocol strict parity")
struct TerminalProtocolStrictParityTests {
    @Test("SGR coordinates remain inside upstream's unsigned 16-bit domain")
    func sgrCoordinatesRespectUpstreamBounds() {
        let valid = Array("\u{1B}[<0;65535;65535M".utf8)
        guard case .event(let event) = MouseReportDecoder.decode(valid) else {
            Issue.record("Maximum upstream mouse coordinates should decode")
            return
        }
        #expect(event.x == 65_534)
        #expect(event.y == 65_534)

        for (column, row) in [
            (65_536, 1),
            (1, 65_536),
            (999_999, 1),
            (1, 999_999),
            (1_000_000, 1),
            (1, 1_000_000),
            (9_999_999, 9_999_999),
        ] {
            let report = Array("\u{1B}[<0;\(column);\(row)M".utf8)
            #expect(MouseReportDecoder.decode(report) == .malformed)
        }
    }

    @Test("X10's single-byte coordinates cannot smuggle oversized values")
    func x10CoordinatesRemainByteBounded() {
        let largestReport: [UInt8] = [0x1B, 0x5B, 0x4D, 0x20, 0xFF, 0xFF]
        guard case .event(let event) = MouseReportDecoder.decode(largestReport) else {
            Issue.record("Maximum X10 byte coordinates should decode")
            return
        }
        #expect(event.x == 222)
        #expect(event.y == 222)

        let oversizedReport = [UInt8(0x1B), 0x5B, 0x4D, 0x20]
            + Array("1000000;1000000".utf8)
        #expect(MouseReportDecoder.decodeX10(oversizedReport) == .malformed)
    }

    @Test("Whitespace around GROK_WRAP_NONE remains ordinary literal text")
    func noneMagicRequiresExactPayload() {
        #expect(decodeWrapImagePaste(payload: MAGIC_NONE) == .noImage)

        for payload in [
            " \(MAGIC_NONE)",
            "\(MAGIC_NONE) ",
            "\t\(MAGIC_NONE)\t",
            "\(MAGIC_NONE)\n",
            "\(MAGIC_NONE)\r\n",
            "\(MAGIC_NONE)\nordinary text",
        ] {
            #expect(decodeWrapImagePaste(payload: payload) == nil)
        }
    }

    @Test("Exact wrapped images preserve MIME bytes and decode their sole base64 line")
    func exactImageFramePreservesMimeVerbatim() {
        let mime = " image/png; profile=original "
        let payload = "\(MAGIC_IMG)\n\(mime)\nAQID"

        #expect(
            decodeWrapImagePaste(payload: payload)
                == .image(data: Data([0x01, 0x02, 0x03]), mimeType: mime)
        )

        let carriageReturnMime = "image/png\r"
        let carriageReturnPayload = "\(MAGIC_IMG)\n\(carriageReturnMime)\nAQID"
        #expect(
            decodeWrapImagePaste(payload: carriageReturnPayload)
                == .image(data: Data([0x01, 0x02, 0x03]), mimeType: carriageReturnMime)
        )
    }

    @Test("Wrapped image base64 accepts only the upstream trailing whitespace allowance")
    func imageFrameTrimsTrailingWhitespaceOnly() {
        for suffix in [" ", "\t", "\n", "\r\n", " \t\r\n"] {
            let payload = "\(MAGIC_IMG)\nimage/png\nAQID\(suffix)"
            #expect(
                decodeWrapImagePaste(payload: payload)
                    == .image(data: Data([0x01, 0x02, 0x03]), mimeType: "image/png")
            )
        }
    }

    @Test("Malformed wrapped images reject blank, multiline, CRLF, and internally padded fields")
    func malformedImageFrameDoesNotNormalizeFields() {
        for payload in [
            "\(MAGIC_IMG)",
            "\(MAGIC_IMG)\r\nimage/png\r\nAQID",
            "\(MAGIC_IMG)\n\nAQID",
            "\(MAGIC_IMG)\nimage/png\n",
            "\(MAGIC_IMG)\nimage/png\n\nAQID",
            "\(MAGIC_IMG)\nimage/png\nAQ\nID",
            "\(MAGIC_IMG)\nimage/png\nAQ\r\nID",
            "\(MAGIC_IMG)\nimage/png\nAQ\nID\n",
            "\(MAGIC_IMG)\nimage/png\n AQID",
            "\(MAGIC_IMG)\nimage/png\nAQ ID",
            "\(MAGIC_IMG)\nimage/png\nAQ\tID",
            "\(MAGIC_IMG)\nimage/png\n \t\n",
            "\(MAGIC_IMG)\nimage/png\n!!!!",
        ] {
            #expect(decodeWrapImagePaste(payload: payload) == .noImage)
        }
    }
}
