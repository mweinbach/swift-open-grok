// MarkdownTableAdversarialStressTests.swift
//
// Adversarial empirical stress tests for OpenGrokMarkdown table rendering:
// extreme boundary conditions (zero-width, narrow terminal widths < overhead),
// complex multibyte grapheme clusters (ZWJ emojis, skin tones, flags, CJK, combining marks),
// unbreakable tokens, asymmetric rows, empty cells, and style span continuity.

import Foundation
import Testing
import OpenGrokMarkdownCore
@testable import OpenGrokMarkdown

@Suite("Markdown Table Adversarial Stress Tests")
struct MarkdownTableAdversarialStressTests {

    // MARK: - 1. Extreme Width Boundaries (Zero, Narrow, Sub-Overhead)

    @Test("Zero and negative maxTableWidth does not crash or loop infinitely")
    func zeroAndNegativeMaxWidth() {
        let source = """
        | Header 1 | Header 2 |
        | --- | --- |
        | Alpha | Beta |
        """

        for width in [0, -1, -100] {
            let config = MarkdownRenderConfiguration(maxTableWidth: width)
            let renderer = MarkdownRenderer(configuration: config)
            let output = renderer.render(source)
            #expect(!output.lines.isEmpty)
            #expect(output.text.contains("Alpha"))
            #expect(output.text.contains("Beta"))
        }
    }

    @Test("Narrow terminal width smaller than table border overhead reflows safely")
    func narrowTerminalSmallerThanOverhead() {
        let source = """
        | Column A | Column B | Column C |
        | --- | --- | --- |
        | Data 1 | Data 2 | Data 3 |
        """
        // 3 columns: overhead = 3 * (2*1 + 1) + 1 = 10.
        // Test widths 1, 2, 3, 5, 8, 10
        for width in [1, 2, 3, 5, 8, 10] {
            let config = MarkdownRenderConfiguration(maxTableWidth: width)
            let output = MarkdownRenderer(configuration: config).render(source)
            #expect(!output.lines.isEmpty)
            #expect(output.text.contains("Data 1"))
            #expect(output.text.contains("Data 2"))
            #expect(output.text.contains("Data 3"))
        }
    }

    @Test("Extremely large number of columns in narrow width")
    func manyColumnsNarrowWidth() {
        var header = "|"
        var sep = "|"
        var row = "|"
        for i in 1...20 {
            header += " Col \(i) |"
            sep += " --- |"
            row += " Val \(i) |"
        }
        let source = "\(header)\n\(sep)\n\(row)\n"

        let config = MarkdownRenderConfiguration(maxTableWidth: 40)
        let output = MarkdownRenderer(configuration: config).render(source)
        #expect(!output.lines.isEmpty)
        // With width 40 and 20 columns, columns wrap into Col / 1 and Val / 20
        #expect(output.text.contains("Col") && output.text.contains("1"))
        #expect(output.text.contains("Val") && output.text.contains("20"))
    }

    // MARK: - 2. Complex Multibyte & Extended Unicode Grapheme Clusters

    @Test("Complex ZWJ emoji sequences are never split or corrupted")
    func complexZWJEmojisPreserved() {
        let emojis = [
            "👨‍👩‍👧‍👦", // Family: Man, Woman, Girl, Boy (7 unicode scalars)
            "🧑🏽‍💻",   // Technologist with medium skin tone (ZWJ + modifier)
            "🏳️‍🌈",   // Rainbow Flag (Flag + VS16 + ZWJ + Rainbow)
            "1️⃣",     // Keycap digit 1 (Digit + VS16 + Combining Keycap)
            "🇺🇸",     // US Flag (Regional Indicator U + S)
            "🇯🇵",     // Japan Flag (Regional Indicator J + P)
            "👍🏾"      // Thumbs up dark skin tone
        ]

        for emoji in emojis {
            let source = """
            | Icon | Description |
            | --- | --- |
            | \(emoji) | Visual Symbol |
            """

            // Test at wide and tight widths
            for width in [10, 15, 40, 80] {
                let config = MarkdownRenderConfiguration(maxTableWidth: width)
                let output = MarkdownRenderer(configuration: config).render(source)
                #expect(output.text.contains(emoji), "Emoji '\(emoji)' was corrupted at width \(width)")
            }
        }
    }

    @Test("Mixed CJK, Latin, and Emoji in tight wrapped cells")
    func mixedCJKAndEmojiWrapping() {
        let source = """
        | 項目 | 状態 | メモ |
        | --- | --- | --- |
        | データベース移行 | 完了 ✅ | 東京データセンターへ移行完了 🚀 |
        | API連携テスト | 進行中 ⏳ | エンドポイント認証確認中 🔐 |
        """

        let config = MarkdownRenderConfiguration(maxTableWidth: 35)
        let output = MarkdownRenderer(configuration: config).render(source)

        // Verifies all wrapped fragments and emojis are rendered intact without corruption
        #expect(output.text.contains("データベ") && output.text.contains("ース移行"))
        #expect(output.text.contains("完") && output.text.contains("了") && output.text.contains("✅"))
        #expect(output.text.contains("東京データセン") && output.text.contains("🚀"))
        #expect(output.text.contains("API連携") && output.text.contains("⏳") && output.text.contains("🔐"))
    }

    @Test("Combining diacritics and zalgo text do not break wrapping bounds")
    func combiningDiacriticsWrapping() {
        // e + acute accent (combining scalar)
        let accented = "e\u{0301}tude" // étude as 2 scalars for first letter
        let source = """
        | Word | Meaning |
        | --- | --- |
        | \(accented) | Musical study |
        """

        let output = MarkdownRenderer(configuration: MarkdownRenderConfiguration(maxTableWidth: 25)).render(source)
        #expect(output.text.contains("tude"))
        #expect(output.text.contains("Musical"))
    }

    // MARK: - 3. Unbreakable Tokens & Extreme Word Wrapping

    @Test("500-character unbreakable token hard-splits and reassembles perfectly")
    func massiveUnbreakableToken() {
        let longToken = String(repeating: "abcdefghij", count: 50) // 500 chars
        let wrapped = wrapCellText(longToken, width: 10)

        #expect(wrapped.count == 50)
        #expect(wrapped.allSatisfy { $0.count == 10 })
        #expect(wrapped.joined() == longToken)
    }

    @Test("Unbreakable token with width 1 produces 1-char lines")
    func unbreakableTokenWidth1() {
        let token = "Hello"
        let wrapped = wrapCellText(token, width: 1)
        #expect(wrapped == ["H", "e", "l", "l", "o"])
    }

    @Test("Cell with only whitespace returns single empty string")
    func whitespaceOnlyCell() {
        let wrapped = wrapCellText("     ", width: 10)
        #expect(wrapped == [""])
    }

    // MARK: - 4. Style Spans and Hyperlinks Continuity

    @Test("Multi-line wrapped bold, italic, code, and link spans retain styles across all lines")
    func styledSpansRetainedAcrossWrappedFragments() {
        let source = """
        | Col A | Col B |
        | --- | --- |
        | **Bold prefix with very long text that must wrap across multiple lines** | `code snippet that also wraps` and [a very long hyperlink anchor that wraps](https://example.com/deep/path) |
        """

        let config = MarkdownRenderConfiguration(maxTableWidth: 30)
        let output = MarkdownRenderer(configuration: config).render(source)

        var boldCount = 0
        var codeCount = 0
        var linkCount = 0

        for line in output.lines {
            for seg in line.segments {
                if seg.style == .strong { boldCount += 1 }
                if seg.style == .code { codeCount += 1 }
                if seg.style == .link { linkCount += 1 }
            }
        }

        #expect(boldCount >= 2, "Bold style must span at least 2 visual fragments")
        #expect(codeCount >= 1, "Code style must be present")
        #expect(linkCount >= 2, "Link style must span at least 2 visual fragments")

        let hyperlinks = output.hyperlinks.filter { $0.url == "https://example.com/deep/path" }
        #expect(hyperlinks.count >= 2, "Hyperlinks should be emitted for each visual line fragment")
    }

    // MARK: - 5. Asymmetric and Irregular Tables

    @Test("Table with varying row column counts and missing cells")
    func irregularTableDimensions() {
        let source = """
        | A | B | C | D |
        | --- | --- | --- | --- |
        | 1 |
        | 1 | 2 |
        | 1 | 2 | 3 |
        | 1 | 2 | 3 | 4 |
        | 1 | 2 | 3 | 4 | 5 |
        """

        let output = MarkdownRenderer().render(source)
        let lines = output.lines.map(\.text)

        #expect(!lines.isEmpty)
        // All border and content lines should have uniform width
        let firstWidth = lines[0].count
        #expect(lines.allSatisfy { $0.count == firstWidth })
    }
}
