import OpenGrokMarkdown
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPager

@Suite("Pager Markdown hyperlink display-width parity")
struct PagerMarkdownHyperlinkWidthParityTests {
    private let renderer = PagerMarkdownRenderer(
        configuration: MarkdownRenderConfiguration(showLinkDestinations: false),
        mermaidWorker: nil
    )

    @Test("ASCII links split one segment without assigning the URL to surrounding text")
    func asciiHyperlinkBoundaries() {
        let url = "https://example.com/ascii"
        let spans = mappedSpans(
            "read docs here",
            hyperlinks: [hyperlink(columns: 5..<9, url: url)]
        )

        #expect(spans.map(\.text) == ["read ", "docs", " here"])
        #expect(spans.map(\.url) == [nil, url, nil])
    }

    @Test("CJK prefixes and CJK link text use two terminal cells per grapheme")
    func wideCJKPrefixAndLink() {
        let url = "https://example.com/cjk"
        let spans = renderer.render("前置 [漢字](\(url)) 後続").flatMap(\.spans)

        #expect(spans.filter { $0.url == url }.map(\.text) == ["漢字"])
        #expect(spans.filter { $0.url == nil }.map(\.text).joined().contains("後続"))
    }

    @Test("ZWJ emoji and skin-tone emoji retain their complete grapheme and destination")
    func emojiZWJHyperlinkBoundaries() {
        let url = "https://example.com/emoji"
        let linkedEmoji = "👨‍👩‍👧‍👦"
        let spans = renderer.render("🧑🏽‍💻 [\(linkedEmoji)](\(url)) done").flatMap(\.spans)

        #expect(spans.filter { $0.url == url }.map(\.text) == [linkedEmoji])
        #expect(spans.filter { $0.url == nil }.map(\.text).joined().hasSuffix(" done"))
    }

    @Test("combining marks remain attached across segment styles without consuming cells")
    func combiningMarksAcrossSegments() {
        let url = "https://example.com/combining"
        let output = MarkdownRenderOutput(
            lines: [MarkdownRenderLine(
                segments: [
                    MarkdownRenderSegment(text: "漢 "),
                    MarkdownRenderSegment(text: "e", style: .link),
                    MarkdownRenderSegment(text: "\u{0301}", style: .strong),
                    MarkdownRenderSegment(text: "cole", style: .link),
                    MarkdownRenderSegment(text: " fini"),
                ],
                sourceLine: 0
            )],
            lineSourceMap: [0],
            hyperlinks: [hyperlink(columns: 3..<8, url: url)]
        )

        let spans = PagerMarkdownRenderer.map(output).flatMap(\.spans)

        #expect(spans.filter { $0.url == url }.map(\.text).joined() == "e\u{0301}cole")
        #expect(spans.last?.text == " fini")
        #expect(spans.last?.url == nil)
    }

    @Test("tab prefixes use the Markdown renderer's shared display-width calculation")
    func tabPrefixUsesSharedUnicodeWidth() {
        let prefix = "漢\t"
        let url = "https://example.com/tab"
        let start = UnicodeDisplayWidth.width(of: prefix)
        let spans = mappedSpans(
            prefix + "target end",
            hyperlinks: [hyperlink(columns: start..<(start + 6), url: url)]
        )

        #expect(spans.map(\.text) == [prefix, "target", " end"])
        #expect(spans.map(\.url) == [nil, url, nil])
    }

    @Test("multiple links after mixed-width prefixes keep their distinct URL associations")
    func multipleHyperlinksPreserveDestinations() {
        let firstURL = "https://example.com/first"
        let secondURL = "https://example.com/second"
        let spans = renderer.render(
            "界 [first](\(firstURL)) 🧑🏽‍💻 [二番](\(secondURL)) tail"
        ).flatMap(\.spans)
        let links = spans.filter { $0.url != nil }

        #expect(links.map(\.text) == ["first", "二番"])
        #expect(links.map(\.url) == [firstURL, secondURL])
        #expect(spans.last?.text.hasSuffix(" tail") == true)
        #expect(spans.last?.url == nil)
    }

    @Test("wrapped link fragments restart display columns on every visual line")
    func wrappedHyperlinkFragmentsStayClippedToTheirOwnLines() {
        let url = "https://example.com/wrapped"
        let firstText = "漢字リンク"
        let secondText = "👨‍👩‍👧‍👦続き"
        let prefix = "│ "
        let start = UnicodeDisplayWidth.width(of: prefix)
        let output = MarkdownRenderOutput(
            lines: [
                MarkdownRenderLine(
                    segments: [MarkdownRenderSegment(text: prefix + firstText + " │")],
                    sourceLine: 0
                ),
                MarkdownRenderLine(
                    segments: [MarkdownRenderSegment(text: prefix + secondText + " │")],
                    sourceLine: 0
                ),
            ],
            lineSourceMap: [0, 0],
            hyperlinks: [
                hyperlink(
                    columns: start..<(start + UnicodeDisplayWidth.width(of: firstText)),
                    url: url,
                    id: 9
                ),
                hyperlink(
                    line: 1,
                    columns: start..<(start + UnicodeDisplayWidth.width(of: secondText)),
                    url: url,
                    id: 9
                ),
            ]
        )

        let lines = PagerMarkdownRenderer.map(output)

        #expect(lines.count == 2)
        #expect(lines[0].spans.map(\.text) == [prefix, firstText, " │"])
        #expect(lines[1].spans.map(\.text) == [prefix, secondText, " │"])
        #expect(lines.allSatisfy { $0.spans.first?.url == nil && $0.spans.last?.url == nil })
        #expect(lines.map { $0.spans.first { $0.url == url }?.url } == [url, url])
    }

    @Test("real wrapped Markdown table fragments link only their visible text")
    func wrappedMarkdownTableHyperlinks() {
        let url = "https://example.com/table"
        let configuration = MarkdownRenderConfiguration(
            showLinkDestinations: false,
            maxTableWidth: 18
        )
        let output = MarkdownRenderer(configuration: configuration).render("""
        | Destination |
        | --- |
        | [漢字リンク資料 very long 🧑🏽‍💻 destination](\(url)) |
        """)
        let fragments = output.hyperlinks.filter { $0.url == url }
        let mapped = PagerMarkdownRenderer.map(output)

        #expect(fragments.count > 1)
        for fragment in fragments {
            let spans = mapped[fragment.lineIndex].spans
            let linkedText = spans.filter { $0.url == url }.map(\.text).joined()

            #expect(!linkedText.isEmpty)
            #expect(UnicodeDisplayWidth.width(of: linkedText) == fragment.columnRange.count)
            #expect(spans.first?.url == nil)
            #expect(spans.last?.url == nil)
        }
    }

    @Test("rendered Mermaid diagrams expose no unsupported action buttons")
    func mermaidRowsDoNotAdvertiseUnbackedActions() {
        let worker = PagerMermaidWorker { _, _ in
            PagerMermaidRender(lines: ["diagram"])
        }
        let lines = PagerMarkdownRenderer(mermaidWorker: worker).render("""
        ```mermaid
        flowchart TD
        A --> B
        ```
        """)
        let text = lines.map(\.text).joined(separator: "\n")
        let marker = lines.first { $0.text.contains("◇ mermaid") }

        #expect(marker?.text == "◇ mermaid")
        #expect(!text.contains("[Open Image]"))
        #expect(!text.contains("[Copy Image Path]"))
        #expect(!text.contains("[Copy Source]"))
    }

    private func mappedSpans(
        _ text: String,
        hyperlinks: [MarkdownHyperlink]
    ) -> [PagerStyledSpan] {
        PagerMarkdownRenderer.map(MarkdownRenderOutput(
            lines: [MarkdownRenderLine(
                segments: [MarkdownRenderSegment(text: text)],
                sourceLine: 0
            )],
            lineSourceMap: [0],
            hyperlinks: hyperlinks
        )).flatMap(\.spans)
    }

    private func hyperlink(
        line: Int = 0,
        columns: Range<Int>,
        url: String,
        id: Int = 0
    ) -> MarkdownHyperlink {
        MarkdownHyperlink(lineIndex: line, columnRange: columns, url: url, id: id)
    }
}
