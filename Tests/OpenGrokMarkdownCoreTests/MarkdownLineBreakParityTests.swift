import Testing
@testable import OpenGrokMarkdownCore

@Suite("Rust-compatible Markdown line breaks")
struct MarkdownLineBreakParityTests {
    @Test("two or more trailing spaces produce real hard-break nodes", arguments: ["  ", "   ", "    "])
    func trailingSpacesCreateHardBreak(spaces: String) {
        #expect(paragraphInlines("  Foo bar\(spaces)\nbaz qux.") == [
            .text("  Foo bar"),
            .hardBreak,
            .text("baz qux.")
        ])
    }

    @Test("zero or one trailing space remains a soft break", arguments: ["", " "])
    func fewerThanTwoTrailingSpacesRemainSoft(spaces: String) {
        #expect(paragraphInlines("Foo bar\(spaces)\nbaz qux.") == [
            .text("Foo bar\(spaces)"),
            .softBreak,
            .text("baz qux.")
        ])
    }

    @Test("hard-break whitespace following inline formatting leaves no empty text node")
    func inlineFormattingBeforeHardBreak() {
        #expect(paragraphInlines("**bold**  \nnext") == [
            .strong([.text("bold")]),
            .hardBreak,
            .text("next")
        ])
    }

    @Test("backslash hard breaks preserve escaped backslashes and ordinary slashes")
    func backslashAndEscapedBackslashes() {
        let examples: [(backslashes: Int, prefix: String, lineBreak: MarkdownInline)] = [
            (1, "before", .hardBreak),
            (2, "before\\", .softBreak),
            (3, "before\\", .hardBreak)
        ]

        for example in examples {
            let source = "before" + String(repeating: "\\", count: example.backslashes) + "\nafter"
            #expect(paragraphInlines(source) == [
                .text(example.prefix),
                example.lineBreak,
                .text("after")
            ])
        }

        #expect(paragraphInlines("before/\nafter") == [
            .text("before/"),
            .softBreak,
            .text("after")
        ])
    }

    @Test(
        "only exact case-insensitive HTML br variants become hard breaks",
        arguments: ["<br>", "<BR>", "<Br>", "<bR>", "<br/>", "<br />", "<BR />", "<br  />", "<br\t/>"]
    )
    func htmlLineBreakVariants(tag: String) {
        #expect(paragraphInlines("first\(tag)second") == [
            .text("first"),
            .hardBreak,
            .text("second")
        ])
    }

    @Test(
        "arbitrary, attributed, malformed, and closing HTML tags remain literal",
        arguments: [
            "<break>",
            "<bravo>",
            "</br>",
            "<br//>",
            "<br/extra>",
            "<br class=unsafe>",
            "<br onclick=alert(1)>",
            "<br / onclick=alert(1)>",
            "<script>",
            "<img src=x onerror=alert(1)>",
            "< br >",
            "<b r>"
        ]
    )
    func unsafeOrMalformedHTMLRemainsLiteral(tag: String) {
        let source = "left\(tag)right"
        #expect(paragraphInlines(source) == [.text(source)])
    }

    @Test("escaped, entity-encoded, and code-span br tags remain literal")
    func escapedTagsAndCodeRemainLiteral() {
        let source = #"literal \<br> and `<BR />` and &lt;br&gt; and <https://example.com>"#

        #expect(paragraphInlines(source) == [
            .text("literal <br> and "),
            .code("<BR />"),
            .text(" and <br> and "),
            .link(text: [.text("https://example.com")], destination: "https://example.com", title: nil)
        ])

        let fenced = MarkdownParser().parse("```\n<br>\n```")
        guard case let .code(code)? = fenced.blocks.first?.kind else {
            Issue.record("Expected a fenced code block containing a literal HTML tag")
            return
        }
        #expect(code.body == "<br>\n")
    }

    @Test("headings, quotes, multiline lists, and table cells retain hard-break nodes")
    func nestedMarkdownContainersPreserveHardBreaks() {
        let source = [
            "# Heading<BR />continued",
            "",
            "> Quoted<br/>continued",
            "",
            "- Item<br>continued",
            "  next line  ",
            "  final",
            "",
            "| Header<Br>continued | Value |",
            "| --- | --- |",
            "| first<br>second | a<BR>b<br/>c<br />d |"
        ].joined(separator: "\n")
        let document = MarkdownParser().parse(source)

        guard document.blocks.count == 4 else {
            Issue.record("Expected heading, quote, list, and table blocks")
            return
        }

        guard case let .heading(level, heading) = document.blocks[0].kind else {
            Issue.record("Expected a heading containing an HTML hard break")
            return
        }
        #expect(level == 1)
        #expect(heading == [.text("Heading"), .hardBreak, .text("continued")])

        guard case let .quote(quoteBlocks) = document.blocks[1].kind,
              case let .paragraph(quoted)? = quoteBlocks.first?.kind else {
            Issue.record("Expected a quote containing an HTML hard break")
            return
        }
        #expect(quoted == [.text("Quoted"), .hardBreak, .text("continued")])

        guard case let .list(ordered: false, start: 1, items) = document.blocks[2].kind,
              case let .paragraph(item)? = items.first?.blocks.first?.kind else {
            Issue.record("Expected a multiline list item containing hard breaks")
            return
        }
        #expect(item == [
            .text("Item"),
            .hardBreak,
            .text("continued"),
            .softBreak,
            .text("next line"),
            .hardBreak,
            .text("final")
        ])

        guard case let .table(table) = document.blocks[3].kind else {
            Issue.record("Expected a table containing header and body hard breaks")
            return
        }
        #expect(table.header == [
            [.text("Header"), .hardBreak, .text("continued")],
            [.text("Value")]
        ])
        #expect(table.rows == [[
            [.text("first"), .hardBreak, .text("second")],
            [.text("a"), .hardBreak, .text("b"), .hardBreak, .text("c"), .hardBreak, .text("d")]
        ]])
    }

    @Test("unordered and ordered list markers preserve first-line hard-break spaces", arguments: ["-", "1."])
    func listMarkerPreservesTrailingHardBreakSpaces(marker: String) {
        let indentation = String(repeating: " ", count: marker.count + 1)
        let source = "\(marker) first  \n\(indentation)second\\\n\(indentation)third"
        let document = MarkdownParser().parse(source)

        guard case let .list(_, _, items)? = document.blocks.first?.kind,
              case let .paragraph(inlines)? = items.first?.blocks.first?.kind else {
            Issue.record("Expected a multiline list paragraph for marker \(marker)")
            return
        }

        #expect(inlines == [
            .text("first"),
            .hardBreak,
            .text("second"),
            .hardBreak,
            .text("third")
        ])
    }

    @Test("CRLF normalization preserves space, backslash, HTML, and soft breaks")
    func normalizedCRLFLineBreaks() {
        let source = "first  \r\nsecond\\\r\nthird<br/>fourth\r\nfifth"
        let document = MarkdownParser().parse(source)

        #expect(document.source == "first  \nsecond\\\nthird<br/>fourth\nfifth")
        guard case let .paragraph(inlines)? = document.blocks.first?.kind else {
            Issue.record("Expected a normalized multiline paragraph")
            return
        }

        #expect(inlines == [
            .text("first"),
            .hardBreak,
            .text("second"),
            .hardBreak,
            .text("third"),
            .hardBreak,
            .text("fourth"),
            .softBreak,
            .text("fifth")
        ])
    }

    private func paragraphInlines(_ source: String) -> [MarkdownInline] {
        let document = MarkdownParser().parse(source)
        guard document.blocks.count == 1,
              case let .paragraph(inlines) = document.blocks[0].kind else {
            Issue.record("Expected exactly one paragraph for \(source)")
            return []
        }
        return inlines
    }
}
