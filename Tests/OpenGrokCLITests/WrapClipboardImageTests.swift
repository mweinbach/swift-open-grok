// WrapClipboardImageTests.swift
//
// Tests for WrapClipboardImage protocol, Kitty graphics chunked framing,
// image chip formatting, and Alacritty KKP DA2 workaround.
//
// Reference: crates/codegen/xai-grok-pager/src/wrap_clipboard_image.rs

import Foundation
import Testing
@testable import OpenGrokCLI
@testable import OpenGrokPagerRender
@testable import OpenGrokDiagnostics
@testable import OpenGrokShared
@testable import OpenGrokTerminalCore
@testable import OpenGrokTextArea

@Suite("Wrap Clipboard Image & Terminal Capabilities Tests")
struct WrapClipboardImageTests {

    private func tinyPngData() -> Data {
        Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89, 0, 0, 0, 10, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0, 1, 0, 0, 5, 0, 1, 0x0d, 0x0a, 0x2d, 0xb4, 0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
    }

    @Test("OSC byte formatting matches ESC ] 999;GrokWrapClipboardImage? BEL")
    func requestOscBytesFormatting() {
        let osc = requestOscBytes()
        #expect(osc.first == 0x1b)
        #expect(osc.count == 30)
        #expect(osc[1] == 0x5d) // ASCII ']'
        #expect(osc.last == 0x07) // BEL

        let bodyBytes = Array(osc[2..<(osc.count - 1)])
        let bodyString = String(decoding: bodyBytes, as: UTF8.self)
        #expect(bodyString == "999;GrokWrapClipboardImage?")
    }

    @Test("Encode and decode roundtrip for valid image payload")
    func encodeDecodeRoundtrip() {
        let rawData = tinyPngData()
        let mime = "image/png"
        let encoded = encodeWrapImagePayload(data: rawData, mimeType: mime)

        #expect(encoded.hasPrefix(MAGIC_IMG))
        let decoded = decodeWrapImagePaste(payload: encoded)
        #expect(decoded == .image(data: rawData, mimeType: mime))
    }

    @Test("Encode wrap image response with bracketed paste wrapper")
    func encodeWrapResponseBracketed() {
        let img = ClipboardImageData(data: tinyPngData(), mimeType: "image/png")
        let responseData = encodeWrapImageResponse(image: img)
        let responseStr = String(decoding: responseData, as: UTF8.self)

        #expect(responseStr.hasPrefix("\u{1b}[200~"))
        #expect(responseStr.hasSuffix("\u{1b}[201~"))
        #expect(responseStr.contains(MAGIC_IMG))
        #expect(responseStr.contains("image/png"))

        let noneData = encodeWrapImageResponse(image: nil)
        let noneStr = String(decoding: noneData, as: UTF8.self)
        #expect(noneStr == "\u{1b}[200~\(MAGIC_NONE)\u{1b}[201~")
    }

    @Test("Decode GROK_WRAP_NONE returns .noImage")
    func decodeWrapNone() {
        #expect(decodeWrapImagePaste(payload: MAGIC_NONE) == .noImage)
        #expect(decodeWrapImagePaste(payload: "\(MAGIC_NONE)\n") == .noImage)
        #expect(decodeWrapImagePaste(payload: "\(MAGIC_NONE)\r\n") == .noImage)
    }

    @Test("Non-wrap plain text returns nil")
    func decodePlainTextReturnsNil() {
        #expect(decodeWrapImagePaste(payload: "hello world") == nil)
        #expect(decodeWrapImagePaste(payload: "") == nil)
        #expect(decodeWrapImagePaste(payload: "/path/to/image.png") == nil)
    }

    @Test("Malformed wrap image frames return .noImage without leaking bytes")
    func decodeMalformedFrames() {
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG\n") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG\nimage/png") == .noImage)
        #expect(decodeWrapImagePaste(payload: "GROK_WRAP_IMG\nimage/png\n!!!notbase64!!!") == .noImage)
    }

    @Test("Oversized base64 payload rejected")
    func oversizedPayloadRejected() {
        let hugeCount = (MAX_WRAP_IMAGE_BYTES / 3 + 10) * 4
        let hugeB64 = String(repeating: "A", count: hugeCount)
        let payload = "\(MAGIC_IMG)\nimage/png\n\(hugeB64)"
        #expect(decodeWrapImagePaste(payload: payload) == .noImage)
    }

    @Test("maybeRequestWrapHostImage triggers only on active OSC 52 sink with no local items")
    func maybeRequestWrapHostImageGating() {
        var emitted: [[UInt8]] = []
        let emit: ([UInt8]) -> Void = { bytes in
            emitted.append(bytes)
        }

        // Active sink, no local items -> emits
        let res1 = maybeRequestWrapHostImage(sinkActive: true, localImage: false, localText: false, localFileURLs: false, emit: emit)
        #expect(res1 == true)
        #expect(emitted.count == 1)
        #expect(emitted[0] == requestOscBytes())

        // Inactive sink -> no emit
        let res2 = maybeRequestWrapHostImage(sinkActive: false, localImage: false, localText: false, localFileURLs: false, emit: emit)
        #expect(res2 == false)
        #expect(emitted.count == 1)

        // Local image present -> no emit
        let res3 = maybeRequestWrapHostImage(sinkActive: true, localImage: true, localText: false, localFileURLs: false, emit: emit)
        #expect(res3 == false)
        #expect(emitted.count == 1)

        // Local text present -> no emit
        let res4 = maybeRequestWrapHostImage(sinkActive: true, localImage: false, localText: true, localFileURLs: false, emit: emit)
        #expect(res4 == false)
        #expect(emitted.count == 1)
    }

    @Test("Image chip display text formatting")
    func imageChipFormatting() {
        #expect(displayText(displayNumber: 1) == "[Image #1]")
        #expect(displayText(displayNumber: 42) == "[Image #42]")
    }

    @Test("PastedImage reconciliation and lifecycle")
    func pastedImageReconciliation() {
        let id1 = ElementId(raw: 1)
        let id2 = ElementId(raw: 2)
        let id3 = ElementId(raw: 3)

        var images: [PastedImage] = [
            PastedImage(elementId: id1, displayNumber: 1, mimeType: "image/png", byteLen: 100),
            PastedImage(elementId: id2, displayNumber: 2, mimeType: "image/jpeg", byteLen: 200),
            PastedImage(elementId: id3, displayNumber: 3, mimeType: "image/png", byteLen: 300)
        ]

        // Keep id1 and id3, drop id2
        reconcile(images: &images, liveIds: [id1, id3])
        #expect(images.count == 2)
        #expect(images[0].elementId == id1)
        #expect(images[1].elementId == id3)

        var counter = 3
        clear(images: &images, imageCounter: &counter)
        #expect(images.isEmpty)
        #expect(counter == 0)
    }

    @Test("Cmd+A select-all supported only for Ghostty")
    func cmdASelectAllGating() {
        #expect(cmdASelectAllSupported(brand: .ghostty) == true)
        #expect(cmdASelectAllSupported(brand: .appleTerminal) == false)
        #expect(cmdASelectAllSupported(brand: .iterm2) == false)
        #expect(cmdASelectAllSupported(brand: .kitty) == false)
        #expect(cmdASelectAllSupported(brand: .wezTerm) == false)
        #expect(cmdASelectAllSupported(brand: .alacritty) == false)
        #expect(cmdASelectAllSupported(brand: .vsCode) == false)
        #expect(cmdASelectAllSupported(brand: .cursor) == false)
    }

    @Test("Kitty graphics chunked rendering at 4096-byte boundaries")
    func kittyGraphicsChunking() {
        // Create 5000 bytes of image data so base64 exceeds 4096 bytes
        let testData = Data(repeating: 0x42, count: 5000)
        let rendered = renderKittyImageZ(imageData: testData, format: .png, cols: 80, rows: 24, z: 1)

        #expect(rendered.contains("\u{1b}_Ga=T,f=100,t=d,q=2,C=1,z=1,i=1,p=1,c=80,r=24,m=1;"))
        #expect(rendered.contains("\u{1b}_Gq=2,m=0;"))
        #expect(!rendered.contains("\u{1b}_Gm="))
        #expect(rendered.hasSuffix("\u{1b}\\"))
    }

    @Test("Alacritty KKP DA2 <= 2401 event types withholding")
    func alacrittyKKPWorkaround() {
        // DA2 <= 2401: disambiguateEscapeCodes = true, reportEventTypes = false
        let flagsOld = negotiatedKittyFlags(skipReason: nil, da2Packed: 2401)
        #expect(flagsOld.contains(.disambiguateEscapeCodes))
        #expect(!flagsOld.contains(.reportEventTypes))

        let flagsOlder = negotiatedKittyFlags(skipReason: nil, da2Packed: 2300)
        #expect(flagsOlder.contains(.disambiguateEscapeCodes))
        #expect(!flagsOlder.contains(.reportEventTypes))

        // DA2 > 2401: both flags true
        let flagsNew = negotiatedKittyFlags(skipReason: nil, da2Packed: 2402)
        #expect(flagsNew.contains(.disambiguateEscapeCodes))
        #expect(flagsNew.contains(.reportEventTypes))

        // Skip reason present: both flags false
        let flagsSkipped = negotiatedKittyFlags(skipReason: "apple_terminal", da2Packed: 2500)
        #expect(!flagsSkipped.contains(.disambiguateEscapeCodes))
        #expect(!flagsSkipped.contains(.reportEventTypes))
    }
}

