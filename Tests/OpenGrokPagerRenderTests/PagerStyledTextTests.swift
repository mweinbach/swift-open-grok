import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("PagerStyledText")
struct PagerStyledTextTests {
    @Test("styled message spans reach the cell buffer with their own attributes")
    func styledSpansPaintAttributes() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 8),
            conversation: [
                .message(PagerMessage(
                    role: .assistant,
                    text: "plain bold",
                    styledLines: [PagerStyledLine(spans: [
                        PagerStyledSpan(text: "plain "),
                        PagerStyledSpan(
                            text: "bold",
                            foreground: .brightYellow,
                            style: [.bold]
                        )
                    ])]
                ))
            ],
            input: PagerComposerState(text: "", isFocused: false),
            showScrollbar: false
        ))

        #expect(result.snapshot().contains("plain bold"))

        // Assistant content starts at column 3 (1 accent + 2 padding), so
        // "plain " runs to column 9 and the styled span starts there.
        let inherited = result.buffer.cell(x: 3, y: 0)
        let styled = result.buffer.cell(x: 9, y: 0)
        #expect(inherited?.grapheme == "p")
        #expect(inherited?.style.contains(.bold) == false)
        #expect(styled?.grapheme == "b")
        #expect(styled?.style.contains(.bold) == true)
        #expect(styled?.foreground == .brightYellow)
    }

    @Test("a message without styled lines still paints its plain text")
    func plainFallback() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 8),
            conversation: [.message(PagerMessage(role: .assistant, text: "unstyled"))],
            input: PagerComposerState(text: "", isFocused: false),
            showScrollbar: false
        ))

        #expect(result.snapshot().contains("unstyled"))
        #expect(result.links.isEmpty)
    }

    @Test("styled hyperlink spans are reported as link regions")
    func hyperlinkSpans() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 8),
            conversation: [
                .message(PagerMessage(
                    role: .assistant,
                    text: "see Example",
                    styledLines: [PagerStyledLine(spans: [
                        PagerStyledSpan(text: "see "),
                        PagerStyledSpan(
                            text: "Example",
                            style: [.underline],
                            url: "https://example.com"
                        )
                    ])]
                ))
            ],
            input: PagerComposerState(text: "", isFocused: false),
            showScrollbar: false
        ))

        #expect(result.links.count == 1)
        let link = result.links.first
        #expect(link?.url == "https://example.com")
        // Content starts at column 3, and "see " occupies four columns.
        #expect(link?.colStart == 7)
        #expect(link?.colEnd == 14)
        #expect(link?.row == 0)
    }

    @Test("the streaming cursor trails the last styled line")
    func streamingCursor() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 8),
            conversation: [
                .message(PagerMessage(
                    role: .assistant,
                    text: "working",
                    isStreaming: true,
                    styledLines: [PagerStyledLine(text: "working")]
                ))
            ],
            input: PagerComposerState(text: "", isFocused: false),
            showScrollbar: false
        ))

        #expect(result.snapshot().contains("working▌"))
    }

    @Test("wrapping splits spans at the width boundary and preserves attributes")
    func wrappingSplitsSpans() {
        let rows = wrapStyledSpans(
            [
                PagerStyledSpan(text: "abcd", foreground: .brightRed),
                PagerStyledSpan(text: "efgh", style: [.bold])
            ],
            width: 3
        )

        #expect(rows.map { $0.map(\.text).joined() } == ["abc", "def", "gh"])
        #expect(rows[0].allSatisfy { $0.foreground == .brightRed })
        // The span that straddles the boundary keeps its attributes on both
        // sides of the split.
        #expect(rows[1].first?.foreground == .brightRed)
        #expect(rows[1].first?.text == "d")
        #expect(rows[1].last?.style.contains(.bold) == true)
        #expect(rows[2].allSatisfy { $0.style.contains(.bold) })
    }

    @Test("styled lines wrap under the role label indentation")
    func wrappedStyledMessageIndents() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 14, height: 8),
            conversation: [
                .message(PagerMessage(
                    role: .assistant,
                    text: "abcdefghijkl",
                    styledLines: [PagerStyledLine(text: "abcdefghijkl")]
                ))
            ],
            input: PagerComposerState(text: "", isFocused: false),
            showScrollbar: false
        ))

        let rows = result.snapshot().split(separator: "\n", omittingEmptySubsequences: false)
        // Width 14 less the 5 columns of transcript chrome leaves 9 for body.
        #expect(rows.first == "   abcdefghi")
        #expect(rows.dropFirst().first == "   jkl")
    }
}
