import Testing
@testable import OpenGrokMarkdownCore

@Suite("OpenGrok Markdown core")
struct OpenGrokMarkdownCoreTests {
    @Test("parses blocks, inline constructs, lists, quotes, and tables")
    func parsesDocumentStructure() {
        let fence = String(repeating: Character(UnicodeScalar(96)!), count: 3)
        let inlineCode = String(Character(UnicodeScalar(96)!))
        let source = """
        # Heading

        > quoted **text**

        - [x] completed
        - pending

        | Name | Value |
        | :--- | ---: |
        | \(inlineCode)one\(inlineCode) | [two](https://example.com) |

        \(fence)swift
        let answer = 42
        \(fence)

        Inline **strong**, *emphasis*, ~~strike~~, and \(inlineCode)code\(inlineCode).
        """

        let document = MarkdownParser().parse(source)
        #expect(document.blocks.count == 6)
        guard case let .heading(level, _) = document.blocks[0].kind else {
            Issue.record("Expected a heading")
            return
        }
        #expect(level == 1)
        guard case let .quote(quoteBlocks) = document.blocks[1].kind else {
            Issue.record("Expected a block quote")
            return
        }
        #expect(quoteBlocks.count == 1)
        guard case let .list(ordered: false, start: 1, items) = document.blocks[2].kind else {
            Issue.record("Expected an unordered list")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].task == .checked)
        #expect(items[1].task == .none)
        guard case let .table(table) = document.blocks[3].kind else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.header.count == 2)
        #expect(table.rows.count == 1)
        #expect(table.alignments == [.left, .right])
        guard case let .code(code) = document.blocks[4].kind else {
            Issue.record("Expected a fenced code block")
            return
        }
        #expect(code.info == "swift")
        #expect(code.body == "let answer = 42\n")
        #expect(code.closed)
    }

    @Test("analysis mirrors the parsed event categories")
    func analysisCountsConstructs() {
        let fence = String(repeating: Character(UnicodeScalar(96)!), count: 3)
        let inlineCode = String(Character(UnicodeScalar(96)!))
        let source = """
        # One
        ## Two

        **bold** *italic* ~~deleted~~ \(inlineCode)inline\(inlineCode)
        [link](https://example.com) ![image](https://example.com/image.png)

        > quote

        - [ ] task
        - item

        \(fence)
        code
        \(fence)

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ---
        """

        let analysis = analyzeMarkdown(source)
        #expect(analysis.stats.h1 == 1)
        #expect(analysis.stats.h2 == 1)
        #expect(analysis.stats.strong == 1)
        #expect(analysis.stats.emphasis == 1)
        #expect(analysis.stats.strikethrough == 1)
        #expect(analysis.stats.inlineCode == 1)
        #expect(analysis.stats.links == 1)
        #expect(analysis.stats.images == 1)
        #expect(analysis.stats.blockquotes == 1)
        #expect(analysis.stats.listItems == 2)
        #expect(analysis.stats.taskListItems == 1)
        #expect(analysis.stats.fencedCode == 1)
        #expect(analysis.stats.tables == 1)
        #expect(analysis.stats.thematicBreaks == 1)
        #expect(analysis.issues.isEmpty)
    }

    @Test("single tilde remains literal while double tilde is strike")
    func tildePolicy() {
        let document = MarkdownParser().parse("~literal~ and ~~strike~~")
        guard case let .paragraph(inlines) = document.blocks[0].kind else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(inlines.contains(.strikethrough([.text("strike")])))
        #expect(inlines.contains(.text("~literal~ and ")))
    }

    @Test("detects malformed tables and unterminated fences")
    func structuralIssues() {
        let malformed = analyzeMarkdown("| a | b |\n|---|---|---|\n| c | d | e |\n")
        #expect(malformed.stats.tables == 0)
        #expect(malformed.issues.contains(.malformedTable))

        let fence = String(repeating: Character(UnicodeScalar(96)!), count: 3)
        let unterminated = analyzeMarkdown("\(fence)\nbody\n")
        #expect(unterminated.issues.contains(.unterminatedCodeBlock))
    }

    @Test("normalizes CRLF without changing block structure")
    func lineEndingNormalization() {
        let document = MarkdownParser().parse("# Title\r\n\r\nBody\r\n")
        #expect(document.source == "# Title\n\nBody\n")
        #expect(document.blocks.count == 2)
        #expect(document.blocks.map(\.sourceLine) == [0, 2])
    }
}
