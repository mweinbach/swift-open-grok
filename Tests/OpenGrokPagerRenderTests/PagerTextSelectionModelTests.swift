import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

// Linear + table-shaped transcript text-selection goldens against pin 650c1db7
// (`scrollback/text_selection.rs`, `appearance/text_selection.rs`).
// Sticky-header drag-start is deferred — sticky band exclusion only.

@Suite("PagerTextSelectionModel")
struct PagerTextSelectionModelTests {

    // MARK: - Fixtures

    private func line(
        rangeID: UInt16 = 0,
        blockLineIndex: Int,
        screenY: Int?,
        screenX: Int = 4,
        cols: Range<Int>,
        text: String,
        joiner: String? = nil,
        entryIndex: Int = 0
    ) -> PagerSelectableLine {
        PagerSelectableLine(
            entryIndex: entryIndex,
            rangeID: rangeID,
            blockLineIndex: blockLineIndex,
            screenY: screenY,
            screenX: screenX,
            selectableCols: cols,
            text: text,
            joinerToPrevious: joiner
        )
    }

    private func model(_ lines: [PagerSelectableLine], contentY: Int = 0) -> PagerTextSelectionModel {
        var model = PagerTextSelectionModel(
            contentArea: TerminalRect(x: 0, y: contentY, width: 80, height: 40),
            conversationArea: TerminalRect(x: 0, y: 0, width: 80, height: 40 + contentY)
        )
        for line in lines {
            model.pushLine(line)
        }
        return model
    }

    // MARK: - Exact / nearest / tie

    @Test("exact hit returns matching RangeHit")
    func exactHit() {
        let m = model([
            line(
                rangeID: 7,
                blockLineIndex: 0,
                screenY: 3,
                screenX: 10,
                cols: 2..<6,
                text: "body",
                entryIndex: 1
            )
        ])
        let hit = m.hitTestTextExact(col: 13, row: 3)
        #expect(hit == PagerTextRangeHit(entryIndex: 1, rangeID: 7, blockLineIndex: 0, colWithinRange: 1))
    }

    @Test("same-row nearest clamps to selectable edges")
    func nearestOnRowClamps() {
        let m = model([
            line(rangeID: 7, blockLineIndex: 0, screenY: 3, screenX: 10, cols: 2..<6, text: "body", entryIndex: 1)
        ])
        let left = m.hitTestSelectableRange(col: 11, row: 3)
        #expect(left?.colWithinRange == 0)
        let right = m.hitTestSelectableRange(col: 16, row: 3)
        #expect(right?.colWithinRange == 3)
        #expect(m.hitTestTextExact(col: 11, row: 3) == nil)
    }

    @Test("nearest-in-range same-row parity with selectable-range hit")
    func nearestSameRowParity() {
        let m = model([line(rangeID: 7, blockLineIndex: 0, screenY: 3, cols: 2..<6, text: "text")])
        let anchor = PagerTextRangeHit(entryIndex: 0, rangeID: 7, blockLineIndex: 0, colWithinRange: 0)
        for col in 0..<14 {
            #expect(
                m.hitTestNearestInRange(anchor: anchor, col: col, row: 3)
                    == m.hitTestSelectableRange(col: col, row: 3)
            )
        }
    }

    @Test("nearest-in-range snaps across gap rows")
    func nearestSnapsAcrossGaps() {
        let m = model([
            line(blockLineIndex: 0, screenY: 2, cols: 0..<10, text: "aaaaaaaaaa"),
            line(blockLineIndex: 2, screenY: 5, cols: 0..<10, text: "bbbbbbbbbb"),
        ])
        let anchor = PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 0)
        #expect(m.hitTestNearestInRange(anchor: anchor, col: 6, row: 3)?.blockLineIndex == 0)
        #expect(m.hitTestNearestInRange(anchor: anchor, col: 6, row: 4)?.blockLineIndex == 2)
    }

    @Test("nearest-in-range tie prefers line farther from anchor")
    func nearestTieAwayFromAnchor() {
        let m = model([
            line(blockLineIndex: 0, screenY: 2, cols: 0..<10, text: "aaaaaaaaaa"),
            line(blockLineIndex: 2, screenY: 4, cols: 0..<10, text: "bbbbbbbbbb"),
        ])
        let down = m.hitTestNearestInRange(
            anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 0),
            col: 5,
            row: 3
        )
        #expect(down?.blockLineIndex == 2)
        let up = m.hitTestNearestInRange(
            anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 2, colWithinRange: 0),
            col: 5,
            row: 3
        )
        #expect(up?.blockLineIndex == 0)
    }

    @Test("nearest-in-range ignores other ranges on nearer rows")
    func nearestIgnoresOtherRanges() {
        let m = model([
            line(rangeID: 0, blockLineIndex: 0, screenY: 2, cols: 0..<10, text: "aaaaaaaaaa"),
            line(rangeID: 1, blockLineIndex: 0, screenY: 6, cols: 0..<10, text: "bbbbbbbbbb"),
        ])
        let hit = m.hitTestNearestInRange(
            anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 0),
            col: 3,
            row: 6
        )
        #expect(hit?.rangeID == 0)
        #expect(hit?.blockLineIndex == 0)
    }

    @Test("nearest-in-range misses when range absent")
    func nearestMissesAbsentRange() {
        let m = model([line(rangeID: 1, blockLineIndex: 0, screenY: 2, cols: 0..<10, text: "aaaaaaaaaa")])
        #expect(
            m.hitTestNearestInRange(
                anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 0),
                col: 5,
                row: 2
            ) == nil
        )
    }

    @Test("sticky content band excludes header rows from exact/nearest-on-row")
    func stickyContentBandExclusion() {
        // contentArea starts at y=3 — rows above are sticky header.
        let m = model(
            [line(blockLineIndex: 0, screenY: 5, cols: 0..<5, text: "hello")],
            contentY: 3
        )
        #expect(m.hitTestTextExact(col: 4, row: 1) == nil)
        #expect(m.hitTestSelectableRange(col: 4, row: 1) == nil)
        #expect(m.hitTestTextExact(col: 4, row: 5) != nil)
    }

    // MARK: - Threshold / autoscroll

    @Test("drag threshold dx>=1 || dy>=1")
    func dragThreshold() {
        let pending = PagerPendingTextDrag(
            anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 0),
            startCol: 5,
            startRow: 5
        )
        #expect(!pagerTextDragThresholdExceeded(pending: pending, col: 5, row: 5))
        #expect(pagerTextDragThresholdExceeded(pending: pending, col: 6, row: 5))
        #expect(pagerTextDragThresholdExceeded(pending: pending, col: 5, row: 6))
    }

    @Test("autoscroll EDGE=2 speed ladder 1/2/3/5")
    func autoscrollEdgeAndSpeed() throws {
        let area = TerminalRect(x: 0, y: 10, width: 80, height: 20)
        #expect(pagerComputeTextSelectionAutoscroll(mouseRow: 20, contentArea: area) == nil)

        let above = try #require(pagerComputeTextSelectionAutoscroll(mouseRow: 5, contentArea: area))
        #expect(above.direction == .up)
        #expect(above.speed >= 1)

        let nearTop = try #require(pagerComputeTextSelectionAutoscroll(mouseRow: 11, contentArea: area))
        #expect(nearTop.direction == .up)

        let nearBottom = try #require(pagerComputeTextSelectionAutoscroll(mouseRow: 28, contentArea: area))
        #expect(nearBottom.direction == .down)

        #expect(pagerTextSelectionAutoscrollSpeed(distance: 1) == 1)
        #expect(pagerTextSelectionAutoscrollSpeed(distance: 2) == 1)
        #expect(pagerTextSelectionAutoscrollSpeed(distance: 3) == 2)
        #expect(pagerTextSelectionAutoscrollSpeed(distance: 5) == 2)
        #expect(pagerTextSelectionAutoscrollSpeed(distance: 6) == 3)
        #expect(pagerTextSelectionAutoscrollSpeed(distance: 10) == 3)
        #expect(pagerTextSelectionAutoscrollSpeed(distance: 11) == 5)
        #expect(pagerTextSelectionAutoscrollEdge == 2)
    }

    // MARK: - Unicode / CJK / emoji

    @Test("word boundaries CJK wide chars and combining marks")
    func wordBoundariesUnicode() {
        #expect(pagerWordBoundariesAtCol("a\u{754c}b", col: 0) == 0..<4)
        #expect(pagerWordBoundariesAtCol("a\u{754c}b", col: 1) == 0..<4)
        #expect(pagerWordBoundariesAtCol("a\u{754c}b", col: 2) == 0..<4)
        #expect(pagerWordBoundariesAtCol("e\u{0301}f", col: 0) == 0..<2)
        #expect(pagerWordBoundariesAtCol("a_b", col: 1) == 0..<3)
        #expect(pagerWordBoundariesAtCol("hello.world", col: 5) == 5..<6)
    }

    @Test("sliceDisplayCols wide/zero-width safe; mid-glyph start skips")
    func sliceWideAndZeroWidth() {
        // CJK width 2: mid-glyph start skips the grapheme.
        #expect(pagerSliceDisplayCols("\u{754c}x", start: 1, end: 3) == "x")
        #expect(pagerSliceDisplayCols("\u{754c}x", start: 0, end: 2) == "\u{754c}")
        // Combining mark is zero-width attached — width of "e\u{0301}" is 1,
        // and the slice returns the whole grapheme (mark stays attached).
        // Do not use hasPrefix("e"): Swift Character equality is cluster-based,
        // so the composed grapheme is one Character and hasPrefix("e") is false.
        let combining = pagerSliceDisplayCols("e\u{0301}f", start: 0, end: 1)
        #expect(combining == "e\u{0301}")
        #expect(Array(combining).count == 1)
        #expect(pagerSelectionDisplayWidth(combining) == 1)
        #expect(pagerSnapDisplayColumn("\u{754c}x", col: 1) == 0)
        #expect(pagerSnapDisplayColumn("\u{754c}x", col: 2) == 2)
    }

    @Test("emoji display width is wide-safe in selection metrics")
    func emojiWidth() {
        let text = "hi👋z"
        let width = pagerSelectionDisplayWidth(text)
        #expect(width >= 4) // 👋 is typically 2
        let bounds = pagerWordBoundariesAtCol(text, col: 2)
        #expect(bounds.lowerBound <= 2)
        #expect(bounds.upperBound >= 2)
    }

    // MARK: - Reconstruct / joiners / off-screen

    @Test("multiline reconstruct uses joiners across off-screen lines")
    func reconstructOffscreenJoiners() {
        let m = model([
            line(blockLineIndex: 0, screenY: nil, cols: 0..<5, text: "hello", joiner: nil),
            line(blockLineIndex: 1, screenY: 2, cols: 0..<5, text: "world", joiner: " "),
            line(blockLineIndex: 2, screenY: 3, cols: 0..<4, text: "next", joiner: "\n"),
        ])
        let drag = PagerActiveTextDrag(
            anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 0),
            head: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 2, colWithinRange: 3)
        )
        #expect(pagerReconstructSelectionText(model: m, drag: drag) == "hello world\nnext")
    }

    @Test("empty selection is nil; normalized order")
    func emptyAndNormalized() {
        let m = model([])
        let drag = PagerActiveTextDrag(
            anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 0),
            head: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 0)
        )
        #expect(pagerReconstructSelectionText(model: m, drag: drag) == nil)

        let a = PagerTextSelectionEndpoint(blockLineIndex: 2, colWithinRange: 5)
        let b = PagerTextSelectionEndpoint(blockLineIndex: 0, colWithinRange: 1)
        let ordered = pagerNormalizedSelectionOrder(anchor: a, head: b)
        #expect(ordered.start.blockLineIndex == 0)
        #expect(ordered.end.blockLineIndex == 2)
    }

    // MARK: - Word / URL / line

    @Test("URL range preferred over word; trailing punct stripped")
    func urlPreferred() throws {
        let text = "see https://example.com. more"
        #expect(pagerURLRangeAtCol(text, col: 4) == 4..<23)
        #expect(pagerURLRangeAtCol(text, col: 23) == nil)

        let m = model([line(blockLineIndex: 0, screenY: 0, cols: 0..<text.count, text: text)])
        let hit = PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 10)
        let semantic = try #require(pagerSemanticSelectionAt(model: m, hit: hit))
        #expect(semantic.cols == 4..<23)
        #expect(semantic.text == "https://example.com")
    }

    @Test("line bounds cover full selectable width")
    func lineBounds() {
        let l = line(blockLineIndex: 0, screenY: 0, cols: 2..<8, text: "abcdef")
        #expect(pagerLineBounds(for: l) == 0..<6)
        let empty = line(blockLineIndex: 0, screenY: 0, cols: 0..<0, text: "")
        #expect(pagerLineBounds(for: empty) == nil)
    }

    // MARK: - Mode / click / TTL

    @Test("keep_text_selection mode holds/selectsWord + TTL constants")
    func modeAndTTL() {
        #expect(PagerKeepTextSelectionMode.flash.holds == false)
        #expect(PagerKeepTextSelectionMode.flash.selectsWord == false)
        #expect(PagerKeepTextSelectionMode.hold.holds == true)
        #expect(PagerKeepTextSelectionMode.hold.selectsWord == false)
        #expect(PagerKeepTextSelectionMode.wordSelect.holds == true)
        #expect(PagerKeepTextSelectionMode.wordSelect.selectsWord == true)
        #expect(PagerKeepTextSelectionMode.fromCanonical("word_select") == .wordSelect)
        #expect(pagerTextSelectionFlashTTLMs == 150)
        #expect(pagerTextSelectionMultiClickTimeoutMs == 300)
    }

    @Test("absolute UTF-8 offsets map hits across reflowed line breaks")
    func absoluteOffsetAcrossReflow() throws {
        // Wide: one line. Narrow: soft-wrapped with space joiners.
        let wide = model([
            line(blockLineIndex: 0, screenY: 0, cols: 0..<11, text: "hello world"),
        ])
        let narrow = model([
            line(blockLineIndex: 0, screenY: 0, cols: 0..<5, text: "hello", joiner: nil),
            line(blockLineIndex: 1, screenY: 1, cols: 0..<5, text: "world", joiner: " "),
        ])
        let hit = PagerTextRangeHit(
            entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 6
        )
        let offset = try #require(pagerAbsoluteTextUTF8Offset(in: wide, hit: hit))
        #expect(String(decoding: Array(pagerJoinedRangeText(
            model: wide, entryIndex: 0, rangeID: 0
        )!.utf8.prefix(offset)), as: UTF8.self) == "hello ")
        let mapped = try #require(pagerMapTextHit(hit, from: wide, to: narrow))
        #expect(mapped.blockLineIndex == 1)
        #expect(mapped.colWithinRange == 0)
        #expect(pagerJoinedRangeText(model: wide, entryIndex: 0, rangeID: 0)
            == pagerJoinedRangeText(model: narrow, entryIndex: 0, rangeID: 0))
    }

    @Test("multi-click identity helper within 300ms")
    func multiClickIdentity() {
        let hit = PagerTextRangeHit(entryIndex: 1, rangeID: 2, blockLineIndex: 3, colWithinRange: 0)
        #expect(pagerCountTextClick(previous: nil, hit: hit, nowMs: 1000) == 1)
        let prev = pagerMakeTextClickIdentity(hit: hit, nowMs: 1000, clickCount: 1)
        #expect(pagerCountTextClick(previous: prev, hit: hit, nowMs: 1200) == 2)
        #expect(pagerCountTextClick(previous: prev, hit: hit, nowMs: 1400) == 1) // past 300ms
        let other = PagerTextRangeHit(entryIndex: 1, rangeID: 2, blockLineIndex: 4, colWithinRange: 0)
        #expect(pagerCountTextClick(previous: prev, hit: other, nowMs: 1100) == 1)
    }

    // MARK: - Highlight cells / clipping

    @Test("highlight paints selected cells with inverted band; clips to content")
    func highlightCellsAndClip() {
        var buffer = CellBuffer(area: TerminalRect(x: 0, y: 0, width: 20, height: 6))
        for y in 0..<6 {
            _ = buffer.setString(x: 0, y: y, text: String(repeating: "x", count: 20))
        }
        let m = model([
            line(blockLineIndex: 0, screenY: 2, screenX: 2, cols: 0..<5, text: "hello"),
            line(blockLineIndex: 1, screenY: 3, screenX: 2, cols: 0..<5, text: "world", joiner: "\n"),
        ])
        let drag = PagerActiveTextDrag(
            anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 1),
            head: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 0, colWithinRange: 3)
        )
        let theme = PagerRenderTheme.default
        pagerPaintTextSelectionHighlight(
            model: m,
            highlight: .active(drag),
            theme: theme,
            clipArea: TerminalRect(x: 0, y: 2, width: 20, height: 2),
            buffer: &buffer
        )
        // Selected cols 1..<4 at screen_x=2 → cells 3,4,5
        let selected = buffer.cell(x: 3, y: 2)
        #expect(selected?.background == theme.textPrimary)
        #expect(selected?.foreground == theme.bgBase)
        // Outside selection unchanged.
        #expect(buffer.cell(x: 2, y: 2)?.background != theme.textPrimary
            || buffer.cell(x: 2, y: 2)?.foreground != theme.bgBase)
        // Clipped row (y=1) never highlighted even if we had geometry there.
        #expect(buffer.cell(x: 3, y: 1)?.background != theme.textPrimary
            || buffer.cell(x: 3, y: 1)?.style.contains(.reverse) != true)
    }

    // MARK: - Frame publish: sticky / system / separator

    @Test("frame publishes selection model; sticky content excludes header; system/separator skipped")
    func framePublishStickyAndRoles() throws {
        // Tall enough for sticky: user prompt then lots of assistant so scroll > 0.
        let conversation: [PagerConversationItem] = [
            .message(PagerMessage(role: .user, text: "sticky prompt line one\nsticky prompt line two\nsticky prompt line three\nsticky prompt line four")),
            .message(PagerMessage(role: .system, text: "system note")),
            .separator("───"),
            .message(PagerMessage(role: .assistant, text: String(repeating: "assistant body line\n", count: 40))),
        ]
        let state = PagerRenderState(
            size: TerminalSize(width: 80, height: 24),
            conversation: conversation,
            scrollPosition: .offset(12),
            showScrollbar: false,
            compactMode: false
        )
        let result = renderPagerFrame(state)
        let selection = try #require(result.layout.textSelection)
        #expect(selection.contentArea.y >= result.layout.conversation.y)
        if result.layout.headerScreenRows > 0 {
            #expect(selection.contentArea.y == result.layout.conversation.y + result.layout.headerScreenRows)
            // Sticky band rows are not text-hittable.
            #expect(selection.hitTestTextExact(col: selection.contentArea.x + 4, row: result.layout.conversation.y) == nil)
        }

        // System / separator never contribute selectable lines.
        for range in selection.ranges {
            #expect(range.entryIndex != 1) // system
            #expect(range.entryIndex != 2) // separator
        }

        // Assistant is eligible.
        #expect(selection.ranges.contains { $0.entryIndex == 3 })

        // Autoscroll may use the full conversation pane.
        #expect(selection.conversationArea == result.layout.conversation)
    }

    @Test("user/assistant/tool text eligible; links remain text; highlight coexistence")
    func rolesAndHighlightCoexistence() throws {
        let conversation: [PagerConversationItem] = [
            .message(PagerMessage(role: .user, text: "see https://example.com")),
            .message(PagerMessage(
                role: .assistant,
                text: "hello",
                styledLines: [
                    PagerStyledLine(spans: [
                        PagerStyledSpan(text: "hello ", foreground: nil),
                        PagerStyledSpan(text: "link", url: "https://x.test"),
                    ])
                ]
            )),
            .tool(PagerToolCard(name: "bash", input: "echo hi", output: "hi", state: .succeeded, isExpanded: true)),
        ]
        let drag = PagerActiveTextDrag(
            anchor: PagerTextRangeHit(entryIndex: 1, rangeID: 0, blockLineIndex: 0, colWithinRange: 0),
            head: PagerTextRangeHit(entryIndex: 1, rangeID: 0, blockLineIndex: 0, colWithinRange: 4)
        )
        let state = PagerRenderState(
            size: TerminalSize(width: 80, height: 30),
            conversation: conversation,
            scrollPosition: .offset(0),
            showScrollbar: false,
            selectedBlockIndex: 1,
            compactMode: true, // no sticky for a simpler content band
            textSelectionHighlight: .active(drag)
        )
        let result = renderPagerFrame(state)
        let selection = try #require(result.layout.textSelection)
        #expect(selection.ranges.contains { $0.entryIndex == 0 })
        #expect(selection.ranges.contains { $0.entryIndex == 1 })
        #expect(selection.ranges.contains { $0.entryIndex == 2 })

        // Links remain plain selectable text (url on span does not remove text).
        let assistant = try #require(selection.range(entryIndex: 1, rangeID: 0))
        #expect(assistant.lines.contains { $0.text.contains("link") })

        // Selection highlight painted; block band may still be present on other cells.
        #expect(result.layout.conversationHit != nil)
        if let line = assistant.lines.first(where: { $0.screenY != nil }),
           let y = line.screenY
        {
            let x = line.screenX + line.selectableCols.lowerBound
            let cell = result.buffer.cell(x: x, y: y)
            #expect(cell?.background == state.theme.textPrimary
                || cell?.style.contains(.reverse) == true
                || cell?.foreground == state.theme.bgBase)
        }
    }

    // MARK: - Table-aware selection (text_selection.rs table tests)

    private let tableLines = [
        "┌─────────┬────────┐",
        "│ Name    │ Role   │",
        "├─────────┼────────┤",
        "│ Alice   │ Eng    │",
        "│ Smith   │        │",
        "├─────────┼────────┤",
        "│ Bob     │ Design │",
        "└─────────┴────────┘",
    ]

    private func tableModel() -> PagerTextSelectionModel {
        var m = PagerTextSelectionModel(
            contentArea: TerminalRect(x: 0, y: 0, width: 25, height: 8),
            conversationArea: TerminalRect(x: 0, y: 0, width: 25, height: 8)
        )
        for (index, text) in tableLines.enumerated() {
            m.pushLine(line(
                blockLineIndex: index,
                screenY: index,
                screenX: 0,
                cols: 0..<text.count,
                text: text
            ))
        }
        return m
    }

    private func tableGeometry() throws -> PagerTableGeometry {
        try #require(PagerTableGeometry.detect(lines: tableLines, atLine: 3))
    }

    private func tableHit(_ blockLine: Int, _ col: Int) -> PagerTextRangeHit {
        PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: blockLine, colWithinRange: col)
    }

    private func tableDrag(
        _ anchor: (Int, Int),
        _ head: (Int, Int),
        kind: PagerTextSelectionKind
    ) -> PagerActiveTextDrag {
        PagerActiveTextDrag(
            anchor: tableHit(anchor.0, anchor.1),
            head: tableHit(head.0, head.1),
            kind: kind
        )
    }

    private func tableTextAt(_ i: Int) -> String? {
        tableLines.indices.contains(i) ? tableLines[i] : nil
    }

    private func cellModified(
        _ buffer: CellBuffer,
        baseline: CellBuffer,
        x: Int,
        y: Int,
        theme: PagerRenderTheme
    ) -> Bool {
        guard let cell = buffer.cell(x: x, y: y),
              let before = baseline.cell(x: x, y: y)
        else { return false }
        if cell == before { return false }
        return cell.background == theme.textPrimary
            || cell.foreground == theme.bgBase
            || cell.style.contains(.reverse)
    }

    @Test("resolve kind same cell vs grid vs border")
    func resolveKindSameCellVsGridVsBorder() throws {
        let geom = try tableGeometry()
        let linear = PagerTextSelectionKind.linear
        #expect(
            pagerResolveTableDragKind(geom, anchor: tableHit(3, 3), head: tableHit(4, 6), prev: linear)
                == .tableCell
        )
        #expect(
            pagerResolveTableDragKind(geom, anchor: tableHit(3, 3), head: tableHit(3, 14), prev: linear)
                == .tableGrid(
                    anchor: PagerTableCellRef(row: 1, col: 0),
                    head: PagerTableCellRef(row: 1, col: 1)
                )
        )
        #expect(
            pagerResolveTableDragKind(geom, anchor: tableHit(6, 3), head: tableHit(7, 3), prev: linear)
                == .tableCell
        )
        for anchorLine in [0, 2, 5, 7] {
            #expect(
                pagerResolveTableDragKind(
                    geom,
                    anchor: tableHit(anchorLine, 3),
                    head: tableHit(3, 3),
                    prev: linear
                ) == .linear
            )
        }
        #expect(
            pagerResolveTableDragKind(nil, anchor: tableHit(3, 3), head: tableHit(4, 3), prev: linear)
                == .linear
        )
    }

    @Test("resolve kind dead zone and hysteresis")
    func resolveKindDeadZoneAndHysteresis() throws {
        let geom = try tableGeometry()
        let anchor = tableHit(3, 3)
        let cell = PagerTextSelectionKind.tableCell
        for col in [9, 10, 11] {
            #expect(
                pagerResolveTableDragKind(geom, anchor: anchor, head: tableHit(3, col), prev: cell)
                    == .tableCell
            )
        }
        #expect(
            pagerResolveTableDragKind(geom, anchor: anchor, head: tableHit(5, 3), prev: cell)
                == .tableCell
        )
        let grid = pagerResolveTableDragKind(geom, anchor: anchor, head: tableHit(3, 14), prev: cell)
        let anchorCell = PagerTableCellRef(row: 1, col: 0)
        let head = PagerTableCellRef(row: 1, col: 1)
        #expect(grid == .tableGrid(anchor: anchorCell, head: head))
        #expect(
            pagerResolveTableDragKind(geom, anchor: anchor, head: tableHit(3, 10), prev: grid)
                == .tableGrid(anchor: anchorCell, head: head)
        )
        #expect(
            pagerResolveTableDragKind(geom, anchor: anchor, head: tableHit(3, 5), prev: grid)
                == .tableCell
        )
    }

    @Test("reconstruct cell selection joins wrapped fragments")
    func reconstructCellSelectionJoinsWrappedFragments() throws {
        let geom = try tableGeometry()
        let whole = tableDrag((3, 1), (4, 9), kind: .tableCell)
        #expect(pagerReconstructTableSelectionText(geom, drag: whole, textAt: tableTextAt) == "Alice Smith")
        let reversed = tableDrag((4, 9), (3, 1), kind: .tableCell)
        #expect(pagerReconstructTableSelectionText(geom, drag: reversed, textAt: tableTextAt) == "Alice Smith")
        let partial = tableDrag((3, 2), (3, 4), kind: .tableCell)
        #expect(pagerReconstructTableSelectionText(geom, drag: partial, textAt: tableTextAt) == "Ali")
        let padding = tableDrag((3, 7), (3, 9), kind: .tableCell)
        #expect(pagerReconstructTableSelectionText(geom, drag: padding, textAt: tableTextAt) == "")
        #expect(pagerReconstructSelectionText(model: tableModel(), drag: padding, table: geom) == "")
    }

    @Test("reconstruct grid selection as TSV")
    func reconstructGridSelectionAsTSV() throws {
        let geom = try tableGeometry()
        let column = tableDrag(
            (1, 3),
            (6, 3),
            kind: .tableGrid(
                anchor: PagerTableCellRef(row: 0, col: 0),
                head: PagerTableCellRef(row: 2, col: 0)
            )
        )
        #expect(
            pagerReconstructTableSelectionText(geom, drag: column, textAt: tableTextAt)
                == "Name\nAlice Smith\nBob"
        )
        let rect = tableDrag(
            (6, 14),
            (3, 3),
            kind: .tableGrid(
                anchor: PagerTableCellRef(row: 2, col: 1),
                head: PagerTableCellRef(row: 1, col: 0)
            )
        )
        #expect(
            pagerReconstructTableSelectionText(geom, drag: rect, textAt: tableTextAt)
                == "Alice Smith\tEng\nBob\tDesign"
        )
        let whole = tableDrag(
            (2, 3),
            (3, 3),
            kind: .tableGrid(
                anchor: PagerTableCellRef(row: 0, col: 0),
                head: PagerTableCellRef(row: 2, col: 1)
            )
        )
        #expect(
            pagerReconstructTableSelectionText(geom, drag: whole, textAt: tableTextAt)
                == "Name\tRole\nAlice Smith\tEng\nBob\tDesign"
        )
        let emptyish = tableDrag(
            (3, 12),
            (4, 12),
            kind: .tableGrid(
                anchor: PagerTableCellRef(row: 1, col: 1),
                head: PagerTableCellRef(row: 1, col: 1)
            )
        )
        #expect(
            pagerReconstructTableSelectionText(geom, drag: emptyish, textAt: tableTextAt) == "Eng"
        )
    }

    @Test("table cell copy snaps wide graphemes")
    func tableCellCopySnapsWideGraphemes() throws {
        let cjk = ["┌────────┬───────┐", "│ 需要我 │ 帮你  │", "└────────┴───────┘"]
        let geom = try #require(PagerTableGeometry.detect(lines: cjk, atLine: 1))
        let drag = PagerActiveTextDrag(
            anchor: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 1, colWithinRange: 3),
            head: PagerTextRangeHit(entryIndex: 0, rangeID: 0, blockLineIndex: 1, colWithinRange: 6),
            kind: .tableCell
        )
        let textAt: (Int) -> String? = { cjk.indices.contains($0) ? cjk[$0] : nil }
        #expect(pagerReconstructTableSelectionText(geom, drag: drag, textAt: textAt) == "需要我")
    }

    @Test("linear drag ignores table reconstruction")
    func linearDragIgnoresTableReconstruction() throws {
        let geom = try tableGeometry()
        let drag = tableDrag((3, 3), (4, 3), kind: .linear)
        #expect(pagerReconstructTableSelectionText(geom, drag: drag, textAt: tableTextAt) == nil)
        let m = tableModel()
        #expect(pagerReconstructSelectionText(model: m, drag: drag, table: geom) != nil)
    }

    @Test("table overlay paints interiors not borders; no sidecar paints nothing")
    func tableOverlayPaintsBandsNotBorders() throws {
        let geom = try tableGeometry()
        let m = tableModel()
        var buffer = CellBuffer(area: TerminalRect(x: 0, y: 0, width: 25, height: 8))
        for y in 0..<8 {
            _ = buffer.setString(x: 0, y: y, text: String(repeating: "x", count: 25))
        }
        let baseline = buffer
        let theme = PagerRenderTheme.default
        let drag = tableDrag(
            (3, 3),
            (6, 14),
            kind: .tableGrid(
                anchor: PagerTableCellRef(row: 1, col: 0),
                head: PagerTableCellRef(row: 2, col: 1)
            )
        )
        pagerPaintTextSelectionHighlight(
            model: m,
            highlight: .active(drag),
            theme: theme,
            clipArea: TerminalRect(x: 0, y: 0, width: 25, height: 8),
            buffer: &buffer,
            table: geom
        )
        #expect(cellModified(buffer, baseline: baseline, x: 2, y: 3, theme: theme))
        #expect(cellModified(buffer, baseline: baseline, x: 12, y: 6, theme: theme))
        #expect(cellModified(buffer, baseline: baseline, x: 2, y: 4, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 1, y: 3, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 8, y: 3, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 12, y: 4, theme: theme))
        for y in 0..<8 {
            #expect(!cellModified(buffer, baseline: baseline, x: 0, y: y, theme: theme))
            #expect(!cellModified(buffer, baseline: baseline, x: 10, y: y, theme: theme))
            #expect(!cellModified(buffer, baseline: baseline, x: 19, y: y, theme: theme))
        }
        for x in 0..<20 {
            #expect(!cellModified(buffer, baseline: baseline, x: x, y: 0, theme: theme))
            #expect(!cellModified(buffer, baseline: baseline, x: x, y: 1, theme: theme))
            #expect(!cellModified(buffer, baseline: baseline, x: x, y: 2, theme: theme))
            #expect(!cellModified(buffer, baseline: baseline, x: x, y: 5, theme: theme))
            #expect(!cellModified(buffer, baseline: baseline, x: x, y: 7, theme: theme))
        }

        var noGeom = baseline
        pagerPaintTextSelectionHighlight(
            model: m,
            highlight: .active(drag),
            theme: theme,
            clipArea: TerminalRect(x: 0, y: 0, width: 25, height: 8),
            buffer: &noGeom,
            table: nil
        )
        for y in 0..<8 {
            for x in 0..<25 {
                #expect(!cellModified(noGeom, baseline: baseline, x: x, y: y, theme: theme))
            }
        }
    }

    @Test("table cell overlay clamps to band and skips padding")
    func tableCellOverlayClampsToBand() throws {
        let geom = try tableGeometry()
        let m = tableModel()
        var buffer = CellBuffer(area: TerminalRect(x: 0, y: 0, width: 25, height: 8))
        for y in 0..<8 {
            _ = buffer.setString(x: 0, y: y, text: String(repeating: "x", count: 25))
        }
        let baseline = buffer
        let theme = PagerRenderTheme.default
        let drag = tableDrag((3, 1), (4, 9), kind: .tableCell)
        pagerPaintTextSelectionHighlight(
            model: m,
            highlight: .active(drag),
            theme: theme,
            clipArea: TerminalRect(x: 0, y: 0, width: 25, height: 8),
            buffer: &buffer,
            table: geom
        )
        #expect(cellModified(buffer, baseline: baseline, x: 2, y: 3, theme: theme))
        #expect(cellModified(buffer, baseline: baseline, x: 2, y: 4, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 0, y: 3, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 10, y: 3, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 12, y: 3, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 2, y: 6, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 1, y: 3, theme: theme))
        #expect(!cellModified(buffer, baseline: baseline, x: 7, y: 4, theme: theme))
    }

    @Test("clip cols to content trims padding and blanks")
    func clipColsToContentTrimsPadding() {
        let text = "│ Quick Fox │"
        #expect(pagerClipSelectionColsToContent(text, cols: 1..<12) == 2..<11)
        #expect(pagerClipSelectionColsToContent(text, cols: 1..<7) == 2..<7)
        #expect(pagerClipSelectionColsToContent("│        │", cols: 1..<9) == 1..<1)
        #expect(pagerClipSelectionColsToContent("", cols: 0..<5) == 0..<0)
        #expect(pagerClipSelectionColsToContent("│ 名前 │", cols: 1..<6) == 2..<6)
    }

    @Test("stale sidecar does not paint; matching sidecar does")
    func sidecarMatchGatesPaint() throws {
        let geom = try tableGeometry()
        let m = tableModel()
        let theme = PagerRenderTheme.default
        let drag = tableDrag((3, 1), (4, 9), kind: .tableCell)
        let stale = PagerTableSelectionGeometry(entryIndex: 9, rangeID: 9, geometry: geom)
        var buffer = CellBuffer(area: TerminalRect(x: 0, y: 0, width: 25, height: 8))
        for y in 0..<8 {
            _ = buffer.setString(x: 0, y: y, text: String(repeating: "x", count: 25))
        }
        let baseline = buffer
        pagerPaintTextSelectionHighlight(
            model: m,
            highlight: .active(drag),
            theme: theme,
            clipArea: TerminalRect(x: 0, y: 0, width: 25, height: 8),
            buffer: &buffer,
            tableSidecar: stale
        )
        #expect(!cellModified(buffer, baseline: baseline, x: 2, y: 3, theme: theme))

        let live = PagerTableSelectionGeometry(entryIndex: 0, rangeID: 0, geometry: geom)
        pagerPaintTextSelectionHighlight(
            model: m,
            highlight: .active(drag),
            theme: theme,
            clipArea: TerminalRect(x: 0, y: 0, width: 25, height: 8),
            buffer: &buffer,
            tableSidecar: live
        )
        #expect(cellModified(buffer, baseline: baseline, x: 2, y: 3, theme: theme))
    }

    @Test("live detect mismatch does not paint a replacement grid")
    func liveMismatchSidecarPaintsNothing() throws {
        let m = tableModel()
        let theme = PagerRenderTheme.default
        let drag = tableDrag((3, 1), (4, 9), kind: .tableCell)
        let other = try #require(PagerTableGeometry.detect(
            lines: ["┌──┬──┐", "│ a│ b│", "└──┴──┘"],
            atLine: 1
        ))
        let mismatched = PagerTableSelectionGeometry(
            entryIndex: 0, rangeID: 0, geometry: other
        )
        var buffer = CellBuffer(area: TerminalRect(x: 0, y: 0, width: 25, height: 8))
        for y in 0..<8 {
            _ = buffer.setString(x: 0, y: y, text: String(repeating: "x", count: 25))
        }
        let baseline = buffer
        pagerPaintTextSelectionHighlight(
            model: m,
            highlight: .active(drag),
            theme: theme,
            clipArea: TerminalRect(x: 0, y: 0, width: 25, height: 8),
            buffer: &buffer,
            tableSidecar: mismatched
        )
        for y in 0..<8 {
            for x in 0..<25 {
                #expect(!cellModified(buffer, baseline: baseline, x: x, y: y, theme: theme))
            }
        }
        let highlight = PagerTextSelectionHighlight.active(drag)
        #expect(
            pagerTableGeometry(for: highlight, in: m, sidecar: mismatched) == nil
        )
        let matching = PagerTableSelectionGeometry(
            entryIndex: 0, rangeID: 0, geometry: try tableGeometry()
        )
        #expect(
            pagerTableGeometry(for: highlight, in: m, sidecar: matching)
                == matching.geometry
        )
        #expect(pagerTableGeometry(for: highlight, in: m) == nil)
    }

    @Test("frame paints table highlight only from matching keyed sidecar")
    func frameUsesKeyedSidecarNotRedetect() throws {
        let conversation: [PagerConversationItem] = [
            .message(PagerMessage(
                role: .assistant,
                text: tableLines.joined(separator: "\n"),
                styledLines: tableLines.map { PagerStyledLine(text: $0) }
            )),
        ]
        let geom = try tableGeometry()
        let drag = tableDrag((3, 1), (4, 9), kind: .tableCell)
        let theme = PagerRenderTheme.default
        let probe = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 80, height: 24),
            conversation: conversation,
            showScrollbar: false,
            compactMode: true
        ))
        let range = try #require(probe.layout.textSelection?.ranges.first)
        let keyedDrag = PagerActiveTextDrag(
            anchor: PagerTextRangeHit(
                entryIndex: range.entryIndex,
                rangeID: range.rangeID,
                blockLineIndex: drag.anchor.blockLineIndex,
                colWithinRange: drag.anchor.colWithinRange
            ),
            head: PagerTextRangeHit(
                entryIndex: range.entryIndex,
                rangeID: range.rangeID,
                blockLineIndex: drag.head.blockLineIndex,
                colWithinRange: drag.head.colWithinRange
            ),
            kind: .tableCell
        )
        let sidecar = PagerTableSelectionGeometry(
            entryIndex: range.entryIndex,
            rangeID: range.rangeID,
            geometry: geom
        )
        func frame(sidecar: PagerTableSelectionGeometry?) -> PagerRenderResult {
            renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 80, height: 24),
                conversation: conversation,
                showScrollbar: false,
                compactMode: true,
                textSelectionHighlight: .active(keyedDrag),
                tableSelectionGeometry: sidecar
            ))
        }
        let painted = frame(sidecar: sidecar)
        let selection = try #require(painted.layout.textSelection)
        let alice = try #require(selection.ranges.first?.lines.first {
            $0.screenY != nil && $0.text.contains("Alice")
        })
        let y = try #require(alice.screenY)
        let x = alice.screenX + alice.selectableCols.lowerBound + 2
        let cell = painted.buffer.cell(x: x, y: y)
        #expect(
            cell?.background == theme.textPrimary
                || cell?.foreground == theme.bgBase
                || cell?.style.contains(.reverse) == true
        )

        let unpainted = frame(sidecar: nil)
        let unpaintedCell = unpainted.buffer.cell(x: x, y: y)
        #expect(unpaintedCell?.background != theme.textPrimary)
        #expect(unpaintedCell?.style.contains(.reverse) != true)
    }

    @Test("combined reconstruct uses table path; no geometry yields nil")
    func combinedReconstructTablePath() throws {
        let geom = try tableGeometry()
        let m = tableModel()
        let drag = tableDrag((3, 1), (4, 9), kind: .tableCell)
        #expect(pagerReconstructSelectionText(model: m, drag: drag, table: geom) == "Alice Smith")
        let empty = PagerTextSelectionModel()
        #expect(pagerReconstructSelectionText(model: empty, drag: drag, table: nil) == nil)
    }
}
