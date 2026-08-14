// SessionTitleSanitizeTests.swift
//
// Tests for session title sanitization and limits.

import Foundation
import Testing
@testable import OpenGrokSessionPersistence

@Suite("Session title sanitization")
struct SessionTitleSanitizeTests {
    @Test("sanitizeRenameTitle removes C0 and C1 control characters")
    func stripControlCharacters() {
        let input = "Hello\u{0000}\u{0007}\u{001B}[31mWorld\u{007F}\u{009F}!"
        #expect(sanitizeRenameTitle(input) == "Hello[31mWorld!")
    }

    @Test("sanitizeRenameTitle removes bidi override characters")
    func stripBidiOverrides() {
        let input = "Title\u{202E}Override\u{202C}"
        #expect(sanitizeRenameTitle(input) == "TitleOverride")
    }

    @Test("sanitizeRenameTitle trims whitespace")
    func trimWhitespace() {
        #expect(sanitizeRenameTitle("   Clean Title   ") == "Clean Title")
        #expect(sanitizeRenameTitle("\t\n  \n\t") == "")
    }

    @Test("sanitizeAndCapTitle truncates overlong titles to maxTitleScalars")
    func capOverlongTitles() {
        let longTitle = String(repeating: "a", count: 150)
        let capped = sanitizeAndCapTitle(longTitle)
        #expect(capped?.count == maxTitleScalars)
        #expect(capped == String(repeating: "a", count: 100))

        #expect(sanitizeAndCapTitle("   ") == nil)
    }
}
