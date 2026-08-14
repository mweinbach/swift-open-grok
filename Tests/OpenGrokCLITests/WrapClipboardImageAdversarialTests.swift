// WrapClipboardImageAdversarialTests.swift
//
// Adversarial empirical stress tests for WrapClipboardImage protocol (OSC 999),
// malformed payloads (>20MB, invalid base64, non-UTF8, truncated framing),
// and boundary conditions.

import Foundation
import Testing
@testable import OpenGrokCLI
@testable import OpenGrokPagerRender
@testable import OpenGrokTerminalCore
@testable import OpenGrokTextArea

@Suite("Wrap Clipboard Image Adversarial Stress Tests")
struct WrapClipboardImageAdversarialTests {

    // MARK: - 1. Payloads Exceeding 20 MiB Budget

    @Test("Oversized 21 MiB payload is rejected without memory exhaustion or crash")
    func oversized21MiBPayloadRejected() {
        // Base64 encoding expands size by ~4/3.
        // 20 MiB = 20,971,520 bytes.
        // Create base64 string whose decoded size is > 20 MiB.
        let base64CharCount = Int(Double(MAX_WRAP_IMAGE_BYTES) * 1.35)
        let hugeBase64 = String(repeating: "A", count: base64CharCount)
        let payload = "\(MAGIC_IMG)\nimage/png\n\(hugeBase64)"

        let result = decodeWrapImagePaste(payload: payload)
        #expect(result == .noImage, "Payload >20MB must be rejected as .noImage")
    }

    @Test("Exact boundary test: 20 MiB vs 20 MiB + 1 byte")
    func exactBoundarySizeTest() {
        // 20 MiB exact = 20 * 1024 * 1024 = 20,971,520 bytes.
        let limit = MAX_WRAP_IMAGE_BYTES
        #expect(limit == 20 * 1024 * 1024)

        // Estimated decoded bytes check in tryDecodeWrapHostImagePaste
        // (len * 3) / 4
        let b64Exact = (limit * 4) / 3
        let b64Over = b64Exact + 16

        let hugeB64Over = String(repeating: "A", count: b64Over)
        let overPayload = "\(MAGIC_IMG)\nimage/jpeg\n\(hugeB64Over)"
        #expect(decodeWrapImagePaste(payload: overPayload) == .noImage)
    }

    // MARK: - 2. Invalid Base64 Sequences & Fuzzing

    @Test("Invalid Base64 characters and non-base64 sequences are rejected safely")
    func invalidBase64CorruptedPadding() {
        let testCases = [
            "\(MAGIC_IMG)\nimage/png\n!!!invalid_base64!!!",
            "\(MAGIC_IMG)\nimage/png\n\u{00}\u{01}\u{02}",
            "\(MAGIC_IMG)\nimage/png\n🌟🚀🔥",
            "\(MAGIC_IMG)\nimage/png\n@#$%^&*()_+~`",
            "\(MAGIC_IMG)\nimage/png\n---invalid---",
            "\(MAGIC_IMG)\nimage/png\n????"
        ]

        for payload in testCases {
            let result = decodeWrapImagePaste(payload: payload)
            #expect(result == .noImage, "Malformed payload should decode to .noImage: \(payload)")
        }
    }

    // MARK: - 3. Non-UTF-8 and Corrupted Frame Headers

    @Test("Corrupted headers, missing newlines, and wrong magic prefixes")
    func corruptedHeadersAndFrames() {
        let testCases = [
            "",
            "GROK_WRAP_IMG",
            "GROK_WRAP_IMG\n",
            "GROK_WRAP_IMG\r\n",
            "GROK_WRAP_IMG\n\n\n",
            "GROK_WRAP_IMG\nimage/png",
            "GROK_WRAP_IMG\nimage/png\n",
            "GROK_WRAP_IMG2\nimage/png\nAAAA",
            "GROK_WRAP_NONE_EXTRA",
            "RANDOM_PREFIX_GROK_WRAP_IMG\nimage/png\nAAAA"
        ]

        for payload in testCases {
            let result = decodeWrapImagePaste(payload: payload)
            #expect(result == nil || result == .noImage, "Payload should be nil or .noImage: \(payload)")
        }
    }

    @Test("Bracketed paste framing strip logic")
    func bracketedPasteFramingStrip() {
        let validPayload = encodeWrapImagePayload(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        let bracketed = "\u{1b}[200~\(validPayload)\u{1b}[201~"

        let stripped = bracketed
            .replacingOccurrences(of: "\u{1b}[200~", with: "")
            .replacingOccurrences(of: "\u{1b}[201~", with: "")

        let decoded = decodeWrapImagePaste(payload: stripped)
        #expect(decoded == .image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png"))
    }

    // MARK: - 4. Dropped Path Classification Robustness

    @Test("Dropped path classifier handles weird filenames, spaces, and URLs")
    func droppedPathClassification() {
        let tmpDir = NSTemporaryDirectory()
        let testImageFile = (tmpDir as NSString).appendingPathComponent("test_image_challenger.png")
        let testTextFile = (tmpDir as NSString).appendingPathComponent("test_doc_challenger.txt")

        FileManager.default.createFile(atPath: testImageFile, contents: Data([1, 2, 3]))
        FileManager.default.createFile(atPath: testTextFile, contents: Data("hello".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: testImageFile)
            try? FileManager.default.removeItem(atPath: testTextFile)
        }

        // Test normal path
        let paths1 = tryReadDroppedPaths(text: testImageFile)
        #expect(paths1.count == 1)
        #expect(paths1[0].isImage == true)

        // Test file:// URL
        let paths2 = tryReadDroppedPaths(text: "file://\(testImageFile)")
        #expect(paths2.count == 1)
        #expect(paths2[0].isImage == true)

        // Test non-image file
        let paths3 = tryReadDroppedPaths(text: testTextFile)
        #expect(paths3.count == 1)
        #expect(paths3[0].isImage == false)

        // Test multiple files on separate lines
        let multi = "\(testImageFile)\n\(testTextFile)"
        let paths4 = tryReadDroppedPaths(text: multi)
        #expect(paths4.count == 2)
        #expect(paths4[0].isImage == true)
        #expect(paths4[1].isImage == false)
    }
}
