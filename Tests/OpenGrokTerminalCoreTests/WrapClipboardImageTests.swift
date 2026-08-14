// WrapClipboardImageTests.swift
//
// Unit tests for host clipboard image paste framing protocol.
//
// Reference: crates/codegen/xai-grok-pager/src/wrap_clipboard_image.rs

import Foundation
import Testing
@testable import OpenGrokTerminalCore

@Suite("Wrap Clipboard Image Protocol Tests")
struct WrapClipboardImageTests {

    private func tinyPngData() -> Data {
        Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
    }

    @Test("Encode and decode roundtrip for valid image")
    func encodeDecodeRoundtrip() {
        let rawData = tinyPngData()
        let mime = "image/png"
        let encoded = encodeWrapImagePayload(data: rawData, mimeType: mime)

        #expect(encoded.hasPrefix(MAGIC_IMG))
        let decoded = decodeWrapImagePaste(payload: encoded)
        #expect(decoded == .image(data: rawData, mimeType: mime))
    }

    @Test("Encode empty or oversized image produces MAGIC_NONE")
    func encodeEmptyOrOversized() {
        #expect(encodeWrapImagePayload(data: Data(), mimeType: "image/png") == MAGIC_NONE)

        let oversized = Data(repeating: 0x41, count: MAX_WRAP_IMAGE_BYTES + 1)
        #expect(encodeWrapImagePayload(data: oversized, mimeType: "image/png") == MAGIC_NONE)
    }

    @Test("Decode GROK_WRAP_NONE returns .noImage")
    func decodeNoneMagic() {
        #expect(decodeWrapImagePaste(payload: MAGIC_NONE) == .noImage)
        #expect(decodeWrapImagePaste(payload: "\(MAGIC_NONE)\n") == .noImage)
        #expect(decodeWrapImagePaste(payload: "\(MAGIC_NONE)\r\n") == .noImage)
    }

    @Test("Non-wrap text returns nil (caller treats as plain text)")
    func garbageIsNotWrapPaste() {
        #expect(decodeWrapImagePaste(payload: "hello world") == nil)
        #expect(decodeWrapImagePaste(payload: "") == nil)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IM") == nil)
        #expect(decodeWrapImagePaste(payload: "some random pasteboard content") == nil)
    }

    @Test("Malformed wrap image frames return .noImage (never leaked as text)")
    func malformedFramesReturnNoImage() {
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG\nbad") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG\nimage/png\n!!!") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG\nimage/png\n") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG\n\nAAAA") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMGbad") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG\nimage/png\ninvalidbase64===") == .noImage)
    }

    @Test("Oversized base64 payload is rejected before decoding")
    func oversizedBase64Rejected() {
        let hugeCount = (MAX_WRAP_IMAGE_BYTES / 3 + 10) * 4
        let hugeB64 = String(repeating: "A", count: hugeCount)
        let payload = "\(MAGIC_IMG)\nimage/png\n\(hugeB64)"
        #expect(decodeWrapImagePaste(payload: payload) == .noImage)
    }

    @Test("CRLF line breaks are supported in payload decoding")
    func crlfSupport() {
        let rawData = tinyPngData()
        let mime = "image/png"
        let b64 = rawData.base64EncodedString()
        let payload = "\(MAGIC_IMG)\r\n\(mime)\r\n\(b64)"

        #expect(decodeWrapImagePaste(payload: payload) == .image(data: rawData, mimeType: mime))
    }

    @Test("OSC byte formatting matches ESC ] REQUEST_BODY BEL")
    func requestOscByteFormatting() {
        let osc = requestOscBytes()
        #expect(osc.first == 0x1b)
        #expect(osc.count >= 3)
        #expect(osc[1] == 0x5d) // ASCII ']'
        #expect(osc.last == 0x07) // BEL

        let bodyBytes = Array(osc[2..<(osc.count - 1)])
        let bodyString = String(decoding: bodyBytes, as: UTF8.self)
        #expect(bodyString == REQUEST_BODY)
        #expect(REQUEST_BODY == "999;GrokWrapClipboardImage?")
    }
}
