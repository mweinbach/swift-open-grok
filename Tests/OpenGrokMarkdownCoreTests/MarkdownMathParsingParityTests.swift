import Testing
@testable import OpenGrokMarkdownCore

@Suite("Rust-compatible Markdown math parsing")
struct MarkdownMathParsingParityTests {
    @Test("all four upstream math delimiter forms produce real math nodes")
    func delimiterForms() {
        let document = MarkdownParser().parse(#"A $x^2$ B \( \alpha + \beta \) C $$z_1$$ D \[w^3\]."#)

        #expect(math(in: document.blocks) == [
            .math("x^2", display: false),
            .math(#"\alpha + \beta"#, display: false),
            .math("z_1", display: true),
            .math("w^3", display: true)
        ])
    }

    @Test("multiline display math preserves lines that resemble Markdown syntax")
    func multilineDisplay() {
        let source = "$$\nx\n=\ny\n$$"
        let document = MarkdownParser().parse(source)

        #expect(document.blocks.count == 1)
        #expect(math(in: document.blocks) == [.math("\nx\n=\ny\n", display: true)])
    }

    @Test("equation and starred equation environments become display math")
    func equationEnvironments() {
        let document = MarkdownParser().parse(#"\begin{equation}E=mc^2\end{equation} and \begin{equation*}x_1\end{equation*}"#)

        #expect(math(in: document.blocks) == [
            .math("E=mc^2", display: true),
            .math("x_1", display: true)
        ])
    }

    @Test("heading, quote, list, link, and table cells retain math nodes")
    func nestedMarkdownContainers() {
        let source = #"""
        # Heading $x^2$

        > Quote \(y_1\)

        - List $z^3$

        [Label $w_2$](https://example.com)

        | Name | Value |
        | --- | --- |
        | a | \(\alpha\) |
        """#

        #expect(math(in: MarkdownParser().parse(source).blocks) == [
            .math("x^2", display: false),
            .math("y_1", display: false),
            .math("z^3", display: false),
            .math("w_2", display: false),
            .math(#"\alpha"#, display: false)
        ])
    }

    @Test("inline code and fenced code keep math delimiters verbatim")
    func codeIsVerbatim() {
        let source = #"""
        `$x^2$` and `\(y_1\)`.

        ```latex
        \[z^3\]
        $$\alpha$$
        ```
        """#

        #expect(math(in: MarkdownParser().parse(source).blocks).isEmpty)
    }

    @Test("escaped delimiters and currency cannot open accidental math")
    func escapedAndCurrency() {
        let examples = [
            #"The cost is $5 and $10, or $2.50."#,
            #"Escaped \$x^2$ is literal."#,
            #"Escaped \\(x^2\\) is literal."#,
            #"Opening $ whitespace$ does not match."#,
            #"Closing $whitespace $ does not match."#,
            #"A closing dollar before a digit $x$2 is not math."#,
            #"Empty $$ and $$$ are not math."#
        ]

        for source in examples {
            #expect(math(in: MarkdownParser().parse(source).blocks).isEmpty, "Unexpected math in \(source)")
        }
    }

    @Test("escaped internal dollars do not terminate a real inline span")
    func escapedInternalDollar() {
        let document = MarkdownParser().parse(#"Value $x + \$y + z$ end."#)

        #expect(math(in: document.blocks) == [.math(#"x + \$y + z"#, display: false)])
    }

    @Test("malformed and unterminated delimiters retain safe literal output")
    func malformedDelimiters() {
        for source in ["open $x", "open $$x", #"open \(x"#, #"open \[x"#,
                       #"\begin{equation}x"#, #"\end{equation}"#] {
            let document = MarkdownParser().parse(source)
            #expect(math(in: document.blocks).isEmpty, "Unexpected math in \(source)")
            #expect(!document.blocks.isEmpty)
        }
    }

    @Test("analysis counts inline and display math only after parser reachability")
    func mathStatistics() {
        let analysis = analyzeMarkdown(#"$a$ \(b\) $$c$$ \[d\]"#)

        #expect(analysis.stats.inlineMath == 2)
        #expect(analysis.stats.displayMath == 2)
    }

    private func math(in blocks: [MarkdownBlock]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for block in blocks {
            switch block.kind {
            case let .paragraph(inlines), let .heading(_, inlines):
                result.append(contentsOf: math(in: inlines))
            case let .quote(children):
                result.append(contentsOf: math(in: children))
            case let .list(_, _, items):
                for item in items {
                    result.append(contentsOf: math(in: item.blocks))
                }
            case let .table(table):
                for cell in table.header {
                    result.append(contentsOf: math(in: cell))
                }
                for row in table.rows {
                    for cell in row {
                        result.append(contentsOf: math(in: cell))
                    }
                }
            case .code, .thematicBreak:
                break
            }
        }
        return result
    }

    private func math(in inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for inline in inlines {
            switch inline {
            case .math:
                result.append(inline)
            case let .strong(children), let .emphasis(children), let .strikethrough(children):
                result.append(contentsOf: math(in: children))
            case let .link(children, _, _), let .image(children, _, _):
                result.append(contentsOf: math(in: children))
            case .text, .code, .softBreak, .hardBreak:
                break
            }
        }
        return result
    }
}
