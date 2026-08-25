import Testing
@testable import OpenGrokMarkdownCore

@Suite("Rust-compatible Markdown entity security")
struct MarkdownEntitySecurityParityTests {
    @Test(
        "every C0 and C1 numeric control entity remains literal",
        arguments: (0...0x1F).map { UInt32($0) } + (0x7F...0x9F).map { UInt32($0) }
    )
    func numericControlEntitiesRemainLiteral(scalar: UInt32) {
        let entities = [
            "&#\(scalar);",
            "&#x\(String(scalar, radix: 16));",
            "&#X\(String(scalar, radix: 16).uppercased());"
        ]

        for entity in entities {
            let source = "before \(entity) after"
            let document = MarkdownParser().parse(source)

            guard case let .paragraph(inlines)? = document.blocks.first?.kind,
                  case let .text(text)? = inlines.first else {
                Issue.record("Expected literal paragraph text for \(entity)")
                return
            }

            #expect(inlines.count == 1)
            #expect(text == source)
            #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .control })
        }
    }

    @Test("ESC entities cannot manufacture terminal escape sequences")
    func terminalEscapeInjectionRemainsLiteral() {
        for entity in ["&#27;", "&#x1b;", "&#X1B;"] {
            let source = "prefix \(entity)[31mcompromised\(entity)[0m suffix"
            let document = MarkdownParser().parse(source)

            #expect(document.blocks == [
                MarkdownBlock(kind: .paragraph([.text(source)]), sourceLine: 0)
            ])
        }
    }

    @Test("control entities stay literal through headings, emphasis, links, and tables")
    func nestedMarkdownContainersPreserveControlEntities() {
        let document = MarkdownParser().parse("""
        # Title &#27;

        Paragraph **strong &#x1b;** and *emphasis &#7;*.

        [link &#0;](https://example.com)

        | Header &#13; | Value |
        | --- | --- |
        | &#128; | &#x9b; |
        """)

        #expect(document.blocks.count == 4)

        guard case let .heading(level, heading)? = document.blocks.first?.kind else {
            Issue.record("Expected a heading with a literal ESC entity")
            return
        }
        #expect(level == 1)
        #expect(heading == [.text("Title &#27;")])

        guard case let .paragraph(paragraph) = document.blocks[1].kind else {
            Issue.record("Expected a paragraph with nested literal control entities")
            return
        }
        #expect(paragraph == [
            .text("Paragraph "),
            .strong([.text("strong &#x1b;")]),
            .text(" and "),
            .emphasis([.text("emphasis &#7;")]),
            .text(".")
        ])

        guard case let .paragraph(link) = document.blocks[2].kind else {
            Issue.record("Expected a link with a literal NUL entity")
            return
        }
        #expect(link == [
            .link(text: [.text("link &#0;")], destination: "https://example.com", title: nil)
        ])

        guard case let .table(table) = document.blocks[3].kind else {
            Issue.record("Expected a table with literal CR and C1 entities")
            return
        }
        #expect(table.header == [[.text("Header &#13;")], [.text("Value")]])
        #expect(table.rows == [[[.text("&#128;")], [.text("&#x9b;")]]])
    }

    @Test("valid numeric and named HTML entities still decode")
    func validEntitiesStillDecode() {
        let document = MarkdownParser().parse(
            "&#32;&#126;&#160;&#x41;&#X1F680;&amp;&nbsp;&#39;"
        )

        #expect(document.blocks == [
            MarkdownBlock(
                kind: .paragraph([.text(" ~\u{00A0}A🚀&\u{00A0}'")]),
                sourceLine: 0
            )
        ])
    }

    @Test("invalid and out-of-range numeric entities remain literal")
    func invalidNumericEntitiesRemainLiteral() {
        for entity in ["&#;", "&#x;", "&#xD800;", "&#x110000;", "&#1114112;"] {
            let document = MarkdownParser().parse(entity)

            #expect(document.blocks == [
                MarkdownBlock(kind: .paragraph([.text(entity)]), sourceLine: 0)
            ])
        }
    }
}
