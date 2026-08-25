import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("Server follow-up suggestion terminal rendering")
struct PagerFollowUpSuggestionsParityTests {
    @Test("chips render directly above the composer with their exact clickable screen cells")
    func rendersUnderResponseAndPublishesHitRects() {
        let state = makeState(labels: ["Tell me more", "Summarize"])
        let result = PagerRenderEngine().render(state)
        let chips = result.layout.followUpSuggestionChips

        #expect(chips.count == 2)
        #expect(chips[0].label == "Tell me more")
        #expect(chips[1].label == "Summarize")
        #expect(chips.allSatisfy { $0.frame.y == result.layout.followUpSuggestions?.y })
        #expect(chips.allSatisfy { $0.frame.y < result.layout.input.y })
        #expect(chips[0].frame.right < chips[1].frame.x)
        #expect(result.snapshot().contains("[ Tell me more ]"))
        #expect(result.snapshot().contains("[ Summarize ]"))
    }

    @Test("CJK and emoji hit rectangles use Unicode terminal display width")
    func unicodeHitRectsUseDisplayColumns() {
        let area = TerminalRect(x: 4, y: 2, width: 40, height: 1)
        var buffer = CellBuffer(area: TerminalRect(x: 0, y: 0, width: 50, height: 5))
        let labels = ["漢字🙂", "e\u{0301}"]
        let chips = pagerRenderFollowUpSuggestions(
            makeModel(labels: labels),
            in: area,
            buffer: &buffer,
            theme: .default
        )

        #expect(chips.count == 2)
        #expect(chips[0].frame.width == UnicodeDisplayWidth.width(of: "[ 漢字🙂 ]"))
        #expect(chips[1].frame.width == UnicodeDisplayWidth.width(of: "[ e\u{0301} ]"))
        #expect(chips[0].contains(x: chips[0].frame.right - 1, y: area.y))
        #expect(!chips[0].contains(x: chips[0].frame.right, y: area.y))
        #expect(chips[1].frame.x == chips[0].frame.right + 1)
    }

    @Test("rendering stops at the first chip that does not fit instead of exposing later ones")
    func publishesOnlyContiguousFittingPrefix() {
        let area = TerminalRect(x: 0, y: 0, width: 13, height: 1)
        var buffer = CellBuffer(area: area)
        let chips = pagerRenderFollowUpSuggestions(
            makeModel(labels: ["A", "much too wide", "B"]),
            in: area,
            buffer: &buffer,
            theme: .default
        )

        #expect(chips.map(\.label) == ["A"])
        #expect(chips.first?.frame.right == 5)
    }

    @Test("labels truncate at 48 display columns without splitting wide graphemes")
    func truncatesByDisplayWidth() {
        let label = String(repeating: "漢", count: 40)
        let area = TerminalRect(x: 0, y: 0, width: 80, height: 1)
        var buffer = CellBuffer(area: area)
        let chips = pagerRenderFollowUpSuggestions(
            makeModel(labels: [label]),
            in: area,
            buffer: &buffer,
            theme: .default
        )

        #expect(chips.count == 1)
        #expect(chips[0].frame.width <= pagerMaximumFollowUpChipLabelWidth + 4)
        #expect(chips[0].label == label)
        let visible = row(buffer: buffer, y: 0)
        #expect(visible.contains("… ]"))
        #expect(!visible.contains(String(repeating: "漢", count: 25)))
    }

    @Test("hover colors apply only to the matching chip")
    func hoveredChipUsesHoverTheme() throws {
        let area = TerminalRect(x: 0, y: 0, width: 30, height: 1)
        var buffer = CellBuffer(area: area)
        var model = makeModel(labels: ["Yes", "No"])
        model.hoveredIndex = 1
        let theme = PagerRenderTheme.default

        let chips = pagerRenderFollowUpSuggestions(model, in: area, buffer: &buffer, theme: theme)
        let first = try #require(buffer.cell(x: chips[0].frame.x + 1, y: 0))
        let second = try #require(buffer.cell(x: chips[1].frame.x + 1, y: 0))

        #expect(first.foreground == theme.linkForeground)
        #expect(first.background == theme.bgBase)
        #expect(second.foreground == theme.textPrimary)
        #expect(second.background == theme.bgHover)
    }

    @Test("painting strips controls and bidi formatting even if a caller bypassed ingestion")
    func rendererDefensivelySanitizesTerminalInjection() {
        let area = TerminalRect(x: 0, y: 0, width: 40, height: 1)
        var buffer = CellBuffer(area: area)
        let chips = pagerRenderFollowUpSuggestions(
            makeModel(labels: ["safe\u{001B}[31m\u{009B}\u{202E}\u{2066}label"]),
            in: area,
            buffer: &buffer,
            theme: .default
        )

        #expect(chips.first?.label == "safe[31mlabel")
        #expect(!row(buffer: buffer, y: 0).unicodeScalars.contains(where: pagerIsUnsafeDisplayScalar))
    }

    @Test("compact frames allocate the same dedicated upstream follow-up row")
    func compactFramesRetainDedicatedFollowUpRow() {
        var state = makeState(labels: ["hidden"])
        state.compactMode = true
        let result = PagerRenderEngine().render(state)

        #expect(result.layout.followUpSuggestions?.height == 1)
        #expect(result.layout.followUpSuggestionChips.map(\.label) == ["hidden"])
        #expect(result.snapshot().contains("[ hidden ]"))
    }

    @Test("short terminals suppress follow-up rows and never publish phantom hits")
    func shortTerminalsHideFollowUpRows() {
        var state = makeState(labels: ["hidden"])
        state.size = TerminalSize(
            width: 80,
            height: PagerLayoutMetrics.shortTerminalRows
        )
        let result = PagerRenderEngine().render(state)

        #expect(result.layout.followUpSuggestions == nil)
        #expect(result.layout.followUpSuggestionChips.isEmpty)
        #expect(!result.snapshot().contains("[ hidden ]"))
    }

    @Test("terminal hit geometry tracks only successful current paints and clears on restore")
    func terminalPublishesOnlyCurrentPaintedChips() throws {
        let sink = FollowUpRecordingSink()
        let terminal = PagerTerminalRenderer(sink: sink)
        let shown = makeState(labels: ["submit"])

        try terminal.render(shown)
        #expect(terminal.lastFollowUpSuggestionChips.map(\.label) == ["submit"])

        var hidden = shown
        hidden.followUpSuggestions = nil
        try terminal.render(hidden)
        #expect(terminal.lastFollowUpSuggestionChips.isEmpty)

        try terminal.render(shown)
        #expect(!terminal.lastFollowUpSuggestionChips.isEmpty)
        try terminal.restore()
        #expect(terminal.lastFollowUpSuggestionChips.isEmpty)
    }

    @Test("TTY suspension removes chip targets until the pager repaints after resume")
    func terminalSuspensionClearsStaleChipTargets() throws {
        let terminal = PagerTerminalRenderer(sink: FollowUpRecordingSink())
        let state = makeState(labels: ["submit"])

        try terminal.render(state)
        #expect(!terminal.lastFollowUpSuggestionChips.isEmpty)
        try terminal.suspendToChild()
        #expect(terminal.lastFollowUpSuggestionChips.isEmpty)
        try terminal.resumeFromChild()
        #expect(terminal.lastFollowUpSuggestionChips.isEmpty)
        try terminal.render(state)
        #expect(terminal.lastFollowUpSuggestionChips.map(\.label) == ["submit"])
    }

    @Test("inline projection never publishes chips outside the actually visible viewport")
    func inlineProjectionDropsOffscreenChipTargets() throws {
        let terminal = PagerTerminalRenderer(
            sink: FollowUpRecordingSink(),
            configuration: PagerTerminalRendererConfiguration(mode: .inline(height: 2))
        )

        try terminal.render(makeState(labels: ["offscreen"]))
        #expect(terminal.lastFollowUpSuggestionChips.isEmpty)
    }

    private func makeState(labels: [String]) -> PagerRenderState {
        PagerRenderState(
            size: TerminalSize(width: 80, height: 20),
            conversation: [.message(PagerMessage(role: .assistant, text: "active response"))],
            followUpSuggestions: makeModel(labels: labels),
            input: PagerComposerState()
        )
    }

    private func makeModel(labels: [String]) -> PagerFollowUpSuggestions {
        PagerFollowUpSuggestions(
            sessionID: "session-1",
            responseID: "response-1",
            generation: 3,
            connectionID: "connection-1",
            connectionGeneration: 4,
            labels: labels
        )
    }

    private func row(buffer: CellBuffer, y: Int) -> String {
        (buffer.area.x..<buffer.area.right).compactMap { x in
            guard let cell = buffer.cell(x: x, y: y), !cell.skip else { return nil }
            return cell.grapheme
        }.joined()
    }
}

private final class FollowUpRecordingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}
    func flush() throws {}
}
