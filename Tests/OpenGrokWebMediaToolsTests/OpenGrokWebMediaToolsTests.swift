// OpenGrokWebMediaToolsTests.swift
import Foundation
import Testing
@testable import OpenGrokWebMediaTools

@Suite("OpenGrokWebMediaTools clipboard scaffold")
struct OpenGrokWebMediaToolsTests {
    @Test("ClipboardContent value types")
    func contentTypes() {
        #expect(ClipboardContent.text("hi") == .text("hi"))
        #expect(ClipboardContent.image(Data([0x00])) == .image(Data([0x00])))
        #expect(ClipboardContent.text("a") != .text("b"))
    }

    @Test("BootstrapClipboardProvider read/write report unsupported")
    func bootstrapClipboard() async {
        let clipboard = BootstrapClipboardProvider()
        do {
            _ = try await clipboard.read()
            Issue.record("Expected unsupported")
        } catch ClipboardError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            try await clipboard.write(.text("hi"))
            Issue.record("Expected unsupported")
        } catch ClipboardError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
