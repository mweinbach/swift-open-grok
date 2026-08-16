import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("Wave D render")
struct WaveDRenderTests {
    @Test("assistant and thinking preserve fenced-code line backgrounds")
    func codeBackgroundsReachPaintLines() {
        let styled = [PagerStyledLine(
            spans: [
                PagerStyledSpan(text: "let", foreground: .brightMagenta, style: [.bold]),
                PagerStyledSpan(text: " value = "),
                PagerStyledSpan(text: "1", foreground: .brightCyan),
            ],
            background: .code
        )]
        let assistant = makeConversationLines(
            [.message(PagerMessage(
                role: .assistant,
                text: "let value = 1",
                styledLines: styled
            ))],
            width: 30,
            theme: .grokNight
        )
        #expect(assistant.first?.background == PagerRenderTheme.grokNight.bgDark)
        #expect(assistant.first?.spans.first?.foreground == .brightMagenta)

        let thinking = makeConversationLines(
            [.message(PagerMessage(
                role: .reasoning,
                text: "let value = 1",
                isStreaming: true,
                styledLines: styled
            ))],
            width: 30,
            theme: .grokNight
        )
        let codeLine = thinking.first { $0.text.contains("let value = 1") }
        #expect(codeLine?.background == PagerRenderTheme.grokNight.bgDark)
        #expect(codeLine?.accentGlyph == PagerGlyphs.accentBar)
    }
}
