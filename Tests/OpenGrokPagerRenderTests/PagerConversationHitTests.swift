import Testing
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

@Suite("PagerConversationHit")
struct PagerConversationHitTests {
    /// User + assistant + user: starts `[0, 4, 6]`, heights `[3, 1, 3]` —
    /// user vertical pad counts as content; one gap row between each pair.
    private func threeBlockLayout() -> ConversationLayout {
        makeConversationLayout(
            [
                .message(PagerMessage(role: .user, text: "alpha question")),
                .message(PagerMessage(role: .assistant, text: "one line")),
                .message(PagerMessage(role: .user, text: "beta question")),
            ],
            width: 40,
            theme: .grokNight
        )
    }

    private func hit(
        screenY: Int,
        conversation: TerminalRect,
        scrollOffset: Int,
        starts: [Int],
        heights: [Int]
    ) -> Int? {
        pagerConversationBlockIndex(
            screenY: screenY,
            conversation: conversation,
            scrollOffset: scrollOffset,
            blockStartLines: starts,
            blockHeights: heights
        )
    }

    @Test("blockHeights are content-only, recorded before each inter-block gap")
    func blockHeightsBeforeGap() {
        let layout = threeBlockLayout()
        #expect(layout.blockStartLines == [0, 4, 6])
        #expect(layout.blockHeights == [3, 1, 3])
        #expect(layout.blockStartLines.count == layout.blockHeights.count)
        // Gap rows sit at content Y 3 and 5 — outside every content range.
        #expect(layout.lines.count == 9)
    }

    @Test("content rows map to the correct block; gap rows return nil")
    func contentHitsAndGaps() {
        let layout = threeBlockLayout()
        let area = TerminalRect(x: 0, y: 2, width: 40, height: 20)
        // Block 0: content Y 0..<3 → screen Y 2..<5
        #expect(hit(screenY: 2, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 0)
        #expect(hit(screenY: 4, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 0)
        // Gap at content Y 3 → screen Y 5
        #expect(hit(screenY: 5, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == nil)
        // Block 1: content Y 4..<5 → screen Y 6
        #expect(hit(screenY: 6, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 1)
        // Gap at content Y 5 → screen Y 7
        #expect(hit(screenY: 7, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == nil)
        // Block 2: content Y 6..<9 → screen Y 8..<11
        #expect(hit(screenY: 8, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 2)
        #expect(hit(screenY: 10, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 2)
    }

    @Test("scroll offset shifts the content Y mapping")
    func scrollOffsetShiftsHit() {
        let layout = threeBlockLayout()
        let area = TerminalRect(x: 0, y: 0, width: 40, height: 4)
        // Without scroll, screen Y 0 is block 0.
        #expect(hit(screenY: 0, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 0)
        // scrollOffset 4 puts viewport top on assistant body (content Y 4).
        #expect(hit(screenY: 0, conversation: area, scrollOffset: 4,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 1)
        // screen Y 1 → content Y 5 = gap
        #expect(hit(screenY: 1, conversation: area, scrollOffset: 4,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == nil)
        // screen Y 2 → content Y 6 = second user block
        #expect(hit(screenY: 2, conversation: area, scrollOffset: 4,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 2)
    }

    @Test("packed collapsed tools abut with no gap row between them")
    func packedToolsAbut() {
        let layout = makeConversationLayout(
            [
                .tool(PagerToolCard(name: "read_file", input: "a.swift", isExpanded: false)),
                .tool(PagerToolCard(name: "read_file", input: "b.swift", isExpanded: false)),
                .message(PagerMessage(role: .assistant, text: "done")),
            ],
            width: 40,
            theme: .grokNight
        )
        // Collapsed tools are one header row each and pack tight; assistant
        // follows after a gap.
        #expect(layout.blockHeights[0] == 1)
        #expect(layout.blockHeights[1] == 1)
        #expect(layout.blockStartLines[1] == layout.blockStartLines[0] + layout.blockHeights[0])
        #expect(layout.blockStartLines[2] == layout.blockStartLines[1] + layout.blockHeights[1] + 1)

        let area = TerminalRect(x: 0, y: 0, width: 40, height: 10)
        #expect(hit(screenY: 0, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 0)
        #expect(hit(screenY: 1, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 1)
        // Gap between tool1 and assistant
        let gapY = layout.blockStartLines[1] + layout.blockHeights[1]
        #expect(hit(screenY: gapY, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == nil)
        #expect(hit(screenY: layout.blockStartLines[2], conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 2)
    }

    @Test("user vertical padding counts as block content")
    func userVerticalPaddingIsContent() {
        let layout = makeConversationLayout(
            [.message(PagerMessage(role: .user, text: "hi"))],
            width: 40,
            theme: .grokNight
        )
        // pad + body + pad
        #expect(layout.blockHeights == [3])
        #expect(layout.blockStartLines == [0])
        let area = TerminalRect(x: 0, y: 5, width: 40, height: 3)
        #expect(hit(screenY: 5, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 0)
        #expect(hit(screenY: 6, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 0)
        #expect(hit(screenY: 7, conversation: area, scrollOffset: 0,
                    starts: layout.blockStartLines, heights: layout.blockHeights) == 0)
    }

    @Test("outside the conversation area, empty, and malformed arrays are safe nils")
    func outsideEmptyMalformedSafe() {
        let area = TerminalRect(x: 2, y: 4, width: 30, height: 6)
        let starts = [0, 4, 6]
        let heights = [3, 1, 3]

        // Above / below the area
        #expect(hit(screenY: 3, conversation: area, scrollOffset: 0,
                    starts: starts, heights: heights) == nil)
        #expect(hit(screenY: 10, conversation: area, scrollOffset: 0,
                    starts: starts, heights: heights) == nil)
        // Zero-height area
        #expect(hit(
            screenY: 0,
            conversation: TerminalRect(x: 0, y: 0, width: 10, height: 0),
            scrollOffset: 0,
            starts: starts,
            heights: heights
        ) == nil)
        // Empty
        #expect(hit(screenY: 4, conversation: area, scrollOffset: 0,
                    starts: [], heights: []) == nil)
        // Length mismatch — uses the shared prefix only
        #expect(hit(screenY: 4, conversation: area, scrollOffset: 0,
                    starts: [0, 4], heights: [3]) == 0)
        #expect(hit(screenY: 4, conversation: area, scrollOffset: 0,
                    starts: [0], heights: [3, 1]) == 0)
        // Zero / negative height never contains
        #expect(hit(screenY: 4, conversation: area, scrollOffset: 0,
                    starts: [0], heights: [0]) == nil)
        #expect(hit(screenY: 4, conversation: area, scrollOffset: 0,
                    starts: [0], heights: [-2]) == nil)
        // Negative scroll clamps to 0
        #expect(hit(screenY: 4, conversation: area, scrollOffset: -100,
                    starts: starts, heights: heights) == 0)
        // Content Y before the first start
        #expect(hit(screenY: 4, conversation: area, scrollOffset: 0,
                    starts: [2], heights: [3]) == nil)
    }

    @Test("renderPagerFrame publishes hit geometry matching the painted layout")
    func framePublishesHitModel() {
        let state = PagerRenderState(
            size: TerminalSize(width: 40, height: 16),
            conversation: [
                .message(PagerMessage(role: .user, text: "alpha question")),
                .message(PagerMessage(role: .assistant, text: "one line")),
                .message(PagerMessage(role: .user, text: "beta question")),
            ],
            input: PagerComposerState(isFocused: false),
            scrollPosition: .offset(0),
            showScrollbar: false
        )
        let result = renderPagerFrame(state)
        let hitModel = result.layout.conversationHit
        #expect(hitModel != nil)
        guard let hitModel else { return }

        let expected = threeBlockLayout()
        #expect(hitModel.conversation == result.layout.conversation)
        #expect(hitModel.scrollOffset == result.layout.scrollOffset)
        #expect(hitModel.contentWidth == result.layout.contentWidth)
        #expect(hitModel.blockStartLines == expected.blockStartLines)
        #expect(hitModel.blockHeights == expected.blockHeights)

        // Method form agrees with the free function on a content row and a gap.
        let contentScreenY = hitModel.conversation.y
        #expect(hitModel.blockIndex(atScreenY: contentScreenY) == 0)
        let gapScreenY = hitModel.conversation.y + 3
        #expect(hitModel.blockIndex(atScreenY: gapScreenY) == nil)
    }

    @Test("scrollbar gutter X is excluded from the selectable content band")
    func scrollbarGutterExcludedFromSelectableBand() throws {
        // Tall transcript forces the default scrollbar (timeline off).
        let filler = (0..<40).map { "line \($0) pad pad pad" }.joined(separator: "\n")
        let state = PagerRenderState(
            size: TerminalSize(width: 40, height: 16),
            conversation: [
                .message(PagerMessage(role: .user, text: "prompt")),
                .message(PagerMessage(role: .assistant, text: filler)),
            ],
            input: PagerComposerState(isFocused: false),
            scrollPosition: .offset(0),
            showScrollbar: true,
            showTimeline: false
        )
        let result = renderPagerFrame(state)
        #expect(result.layout.hasScrollbar)
        let hitModel = try #require(result.layout.conversationHit)
        #expect(hitModel.contentWidth == result.layout.contentWidth)

        let y = hitModel.conversation.y
        let bandX = hitModel.conversation.x + PagerLayoutMetrics.chromeWidth + 1
        #expect(hitModel.containsSelectablePoint(x: bandX, y: y))

        let gutterX = hitModel.selectableEndX
        #expect(gutterX == hitModel.conversation.x
            + PagerLayoutMetrics.chromeWidth + hitModel.contentWidth)
        #expect(hitModel.conversation.contains(x: gutterX, y: y))
        #expect(!hitModel.containsSelectablePoint(x: gutterX, y: y))
        #expect(!hitModel.containsSelectablePoint(x: gutterX + 1, y: y))
    }

    @Test("timeline rail gutter X is also past selectableEndX")
    func railGutterExcludedFromSelectableBand() throws {
        let filler = (0..<20).map { "rail fill \($0)" }.joined(separator: "\n\n")
        let state = PagerRenderState(
            size: TerminalSize(width: 100, height: 30),
            conversation: [
                .message(PagerMessage(role: .user, text: "first")),
                .message(PagerMessage(role: .assistant, text: filler)),
                .message(PagerMessage(role: .user, text: "second")),
                .message(PagerMessage(role: .assistant, text: filler)),
            ],
            input: PagerComposerState(isFocused: false),
            scrollPosition: .followTail,
            showScrollbar: true,
            showTimeline: true
        )
        let result = renderPagerFrame(state)
        let rail = try #require(result.layout.timelineRail)
        let hitModel = try #require(result.layout.conversationHit)
        #expect(hitModel.selectableEndX == rail.rect.x)
        #expect(!hitModel.containsSelectablePoint(x: rail.rect.x, y: rail.rect.y))
        #expect(hitModel.containsSelectablePoint(
            x: rail.rect.x - 1,
            y: hitModel.conversation.y
        ))
    }

    @Test("system messages and separators are not mouse-selectable")
    func systemAndSeparatorNotSelectable() {
        #expect(!PagerConversationItem.message(
            PagerMessage(role: .system, text: "note")
        ).isMouseSelectable)
        #expect(!PagerConversationItem.separator("—").isMouseSelectable)
        #expect(PagerConversationItem.message(
            PagerMessage(role: .user, text: "hi")
        ).isMouseSelectable)
        #expect(PagerConversationItem.message(
            PagerMessage(role: .assistant, text: "hi")
        ).isMouseSelectable)
        #expect(PagerConversationItem.tool(
            PagerToolCard(name: "read_file", input: "a.swift")
        ).isMouseSelectable)
    }
}
