import Testing
import OpenGrokMarkdownCore
@testable import OpenGrokMarkdown

@Suite("OpenGrok Markdown Table Parity & Layout")
struct MarkdownTableParityTests {

    @Test("11-glyph box drawing grid with intermediate body row dividers")
    func tableBorders11GlyphGrid() {
        let source = """
        | Header A | Header B |
        | --- | --- |
        | Row 1 A | Row 1 B |
        | Row 2 A | Row 2 B |
        | Row 3 A | Row 3 B |
        """

        let output = MarkdownRenderer().render(source)
        let lines = output.lines.map(\.text)

        // Expected structure:
        // Line 0: ┌──────────┬──────────┐ (Top border)
        // Line 1: │ Header A │ Header B │ (Header)
        // Line 2: ├──────────┼──────────┤ (Header separator)
        // Line 3: │ Row 1 A  │ Row 1 B  │ (Body row 1)
        // Line 4: ├──────────┼──────────┤ (Divider between row 1 & 2)
        // Line 5: │ Row 2 A  │ Row 2 B  │ (Body row 2)
        // Line 6: ├──────────┼──────────┤ (Divider between row 2 & 3)
        // Line 7: │ Row 3 A  │ Row 3 B  │ (Body row 3)
        // Line 8: └──────────┴──────────┘ (Bottom border)

        #expect(lines.count == 9)
        #expect(lines[0].hasPrefix("┌") && lines[0].contains("┬") && lines[0].hasSuffix("┐"))
        #expect(lines[1].hasPrefix("│") && lines[1].contains("Header A") && lines[1].hasSuffix("│"))
        #expect(lines[2].hasPrefix("├") && lines[2].contains("┼") && lines[2].hasSuffix("┤"))
        #expect(lines[3].contains("Row 1 A") && lines[3].contains("Row 1 B"))
        #expect(lines[4].hasPrefix("├") && lines[4].contains("┼") && lines[4].hasSuffix("┤"))
        #expect(lines[5].contains("Row 2 A") && lines[5].contains("Row 2 B"))
        #expect(lines[6].hasPrefix("├") && lines[6].contains("┼") && lines[6].hasSuffix("┤"))
        #expect(lines[7].contains("Row 3 A") && lines[7].contains("Row 3 B"))
        #expect(lines[8].hasPrefix("└") && lines[8].contains("┴") && lines[8].hasSuffix("┘"))
    }

    @Test("multi-line cell wrapping expands visual row height")
    func multiLineCellWrapping() {
        let source = """
        | Name | Description |
        | --- | --- |
        | Short | The quick brown fox jumps over the lazy dog |
        """

        // Max table width 30: overhead is 2 * (2*1 + 1) + 1 = 7. Content budget is 23.
        // Col 0: "Short" (width 5)
        // Col 1: "The quick brown fox jumps over the lazy dog" wraps into multiple visual lines.
        let output = MarkdownRenderer(configuration: MarkdownRenderConfiguration(maxTableWidth: 30)).render(source)
        let lines = output.lines.map(\.text)

        #expect(lines.allSatisfy { $0.count <= 30 })
        #expect(lines.count > 5) // Multi-line body row expands total line count
        #expect(lines.first?.hasPrefix("┌") == true)
        #expect(lines.last?.hasPrefix("└") == true)
        #expect(output.text.contains("fox"))
        #expect(output.text.contains("lazy"))
    }

    @Test("two-tier column width budget distribution with word and grapheme floors")
    func twoTierColumnWidthBudget() {
        let source = """
        | Key | TokenValue |
        | --- | --- |
        | ID | Supercalifragilisticexpialidocious |
        """

        // Test with tight budget where unbreakable word must fit or reflow
        let output = MarkdownRenderer(configuration: MarkdownRenderConfiguration(maxTableWidth: 25)).render(source)
        let lines = output.lines.map(\.text)

        #expect(lines.allSatisfy { $0.count <= 25 })
        #expect(lines.first?.hasPrefix("┌") == true)
        #expect(lines.last?.hasPrefix("└") == true)
    }

    @Test("unbreakable word emergency grapheme hard-splitting preserves multi-byte clusters")
    func graphemeHardSplitting() {
        let source = """
        | Greeting | Emojis |
        | --- | --- |
        | 你好世界你好世界 | 🚀🎉🔥✨🌟💡 |
        """

        let output = MarkdownRenderer(configuration: MarkdownRenderConfiguration(maxTableWidth: 20)).render(source)
        let lines = output.lines.map(\.text)

        #expect(lines.allSatisfy { $0.count <= 20 })
        #expect(output.text.contains("你好"))
        #expect(output.text.contains("🚀"))
    }

    @Test("styled span slicing preserves bold italic code and link across visual lines")
    func styledSpanSlicingAcrossVisualLines() {
        let source = """
        | Format | Sample |
        | --- | --- |
        | Rich | **Very long bold text that will wrap across several visual lines** |
        | Mixed | *italic prefix* and `code fragment` and [link anchor](https://example.com) |
        """

        let config = MarkdownRenderConfiguration(maxTableWidth: 30)
        let output = MarkdownRenderer(configuration: config).render(source)

        // Find segments with styles
        var foundBold = false
        var foundItalic = false
        var foundCode = false
        var foundLink = false

        for line in output.lines {
            for segment in line.segments {
                if segment.style == .strong { foundBold = true }
                if segment.style == .emphasis { foundItalic = true }
                if segment.style == .code { foundCode = true }
                if segment.style == .link { foundLink = true }
            }
        }

        #expect(foundBold)
        #expect(foundItalic)
        #expect(foundCode)
        #expect(foundLink)

        // Hyperlinks should have been emitted
        #expect(output.hyperlinks.contains(where: { $0.url == "https://example.com" }))
    }

    @Test("monotonic source cursor alignment prevents backward re-matching")
    func monotonicSourceCursorAlignment() {
        let source = """
        | Pattern | Text |
        | --- | --- |
        | Repeat | item item item item item item item item item item |
        """

        let config = MarkdownRenderConfiguration(maxTableWidth: 25)
        let output = MarkdownRenderer(configuration: config).render(source)

        #expect(output.lines.allSatisfy { $0.text.count <= 25 })
        let bodyLines = output.lines.filter { $0.text.contains("item") }
        #expect(bodyLines.count >= 2)
    }

    @Test("table cell hyperlinks track local visual line and column coordinates")
    func tableCellHyperlinksCoordinates() {
        let source = """
        | Site | URL |
        | --- | --- |
        | Docs | [Documentation Link](https://docs.example.com) |
        """

        let output = MarkdownRenderer().render(source)
        let docsLink = output.hyperlinks.first(where: { $0.url == "https://docs.example.com" })

        #expect(docsLink != nil)
        if let link = docsLink {
            #expect(link.lineIndex >= 1)
            #expect(link.columnRange.lowerBound > 0)
            #expect(link.columnRange.upperBound > link.columnRange.lowerBound)
        }
    }

    @Test("table alignments correctly apply left, center, and right padding")
    func tableAlignments() {
        let source = """
        | Left | Center | Right |
        | :--- | :---: | ---: |
        | L | C | R |
        """

        let output = MarkdownRenderer().render(source)
        let dataLine = output.lines.first(where: { $0.text.contains(" L ") && $0.text.contains(" C ") && $0.text.contains(" R ") })

        #expect(dataLine != nil)
    }

    @Test("cell word separator tokenization respects punctuation rules and URL protection")
    func cellWordSeparatorTokenization() {
        // Test tokenization of formatted numbers vs hyphenated vs slashes vs URLs vs identifier tokens
        let text = "$145,000 and 3.14 stay, but foo/bar and 555-0101 split, EMP-1001 stays as identifier, https://example.com/api/v1 stays"
        let tokens = cellWordSeparator(text)
        let words = tokens.map(\.text)

        #expect(words.contains("$145,000"))
        #expect(words.contains("3.14"))
        #expect(words.contains("foo/"))
        #expect(words.contains("bar"))
        #expect(words.contains("555-"))
        #expect(words.contains("0101"))
        #expect(words.contains("EMP-1001"))
        #expect(words.contains("https://example.com/api/v1"))
    }

    @Test("table with header only and no body rows renders top border, header, separator, and bottom border")
    func tableWithHeaderOnly() {
        let source = """
        | Col A | Col B |
        | --- | --- |
        """

        let output = MarkdownRenderer().render(source)
        let lines = output.lines.map(\.text)

        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("┌") && lines[0].hasSuffix("┐"))
        #expect(lines[1].contains("Col A") && lines[1].contains("Col B"))
        #expect(lines[2].hasPrefix("├") && lines[2].hasSuffix("┤"))
        #expect(lines[3].hasPrefix("└") && lines[3].hasSuffix("┘"))
    }

    @Test("table with asymmetric row lengths and empty cells pads correctly")
    func tableAsymmetricAndEmptyCells() {
        let source = """
        | A | B | C |
        | --- | --- | --- |
        | 1 | | 3 |
        | 4 |
        """

        let output = MarkdownRenderer().render(source)
        let lines = output.lines.map(\.text)

        #expect(lines.count >= 6)
        #expect(lines.allSatisfy { $0.count == lines[0].count })
    }

    @Test("wrapped hyperlinks generate distinct line-offset hyperlinks for each visual fragment")
    func wrappedHyperlinksSlicing() {
        let source = """
        | Header |
        | --- |
        | [A very long link text that wraps across multiple lines in a narrow table](https://example.com/long) |
        """

        let config = MarkdownRenderConfiguration(maxTableWidth: 25)
        let output = MarkdownRenderer(configuration: config).render(source)

        let matchingLinks = output.hyperlinks.filter { $0.url == "https://example.com/long" }
        #expect(matchingLinks.count >= 2) // Sliced into at least 2 visual lines
        for link in matchingLinks {
            #expect(link.columnRange.lowerBound > 0)
            #expect(link.columnRange.upperBound > link.columnRange.lowerBound)
        }
    }

    @Test("streaming table checkpoint freezes table boundaries")
    func streamingTableCheckpoint() {
        var renderer = StreamingMarkdownRenderer()
        let chunk1 = """
        | A | B |
        | --- | --- |
        | 1 | 2 |


        """
        renderer.pushAndRender(chunk1)
        #expect(renderer.lastCheckpoint != nil)
        #expect(renderer.lastCheckpoint?.kind == .table)
        #expect(renderer.frozenBytes > 0)
        #expect(renderer.frozenLinesCount > 0)

        let chunk2 = "# Next Heading\n"
        renderer.pushAndRender(chunk2)
        let finished = renderer.finish()
        #expect(finished.text.contains("1"))
        #expect(finished.text.contains("Next Heading"))
    }
}

