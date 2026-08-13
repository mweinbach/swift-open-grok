import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

// MARK: - Pure layout goldens (sticky.rs tests at pin 650c1db7)

@Suite("PagerStickyHeader layout")
struct PagerStickyHeaderLayoutTests {
    private func makePrompts(_ specs: [(Int, Int)], minHeight: Int = 4) -> [PagerPromptDescriptor] {
        specs.enumerated().map { index, spec in
            PagerPromptDescriptor(
                entryIdx: index,
                yVirtual: spec.0,
                fullHeight: spec.1,
                minHeight: minHeight,
                sticky: true
            )
        }
    }

    @Test("scroll 0 and empty prompts yield no header")
    func scrollZeroEmpty() {
        #expect(computePagerStickyLayout(scrollOffset: 10, viewportHeight: 24, prompts: []) == .empty)
        let prompts = makePrompts([(0, 6), (20, 6)])
        let layout = computePagerStickyLayout(scrollOffset: 0, viewportHeight: 24, prompts: prompts)
        #expect(!layout.hasHeader)
        #expect(layout.headerScreenRows == 0)
    }

    @Test("gradual collapse full → min")
    func gradualCollapseFullToMin() {
        let prompts = makePrompts([(0, 8)])
        let justPast = computePagerStickyLayout(scrollOffset: 1, viewportHeight: 24, prompts: prompts)
        #expect(justPast.pinned?.renderHeight == 7)
        #expect(justPast.headerScreenRows == 8)

        let more = computePagerStickyLayout(scrollOffset: 3, viewportHeight: 24, prompts: prompts)
        #expect(more.pinned?.renderHeight == 5)
        #expect(more.headerScreenRows == 6)

        let atMin = computePagerStickyLayout(scrollOffset: 6, viewportHeight: 24, prompts: prompts)
        #expect(atMin.pinned?.renderHeight == 4)
        #expect(atMin.headerScreenRows == 5)

        let stays = computePagerStickyLayout(scrollOffset: 10, viewportHeight: 24, prompts: prompts)
        #expect(stays.pinned?.renderHeight == 4)
        #expect(stays.headerScreenRows == 5)
    }

    @Test("min height bounds: custom, clamp to full, zero floor")
    func minHeightBounds() {
        let small = makePrompts([(0, 8)], minHeight: 2)
        #expect(
            computePagerStickyLayout(scrollOffset: 10, viewportHeight: 24, prompts: small)
                .pinned?.renderHeight == 2
        )

        let seed = [
            PagerPromptDescriptor(
                entryIdx: 0, yVirtual: 0, fullHeight: 1, minHeight: 6, sticky: true
            )
        ]
        let clamped = computePagerStickyLayout(scrollOffset: 10, viewportHeight: 24, prompts: seed)
        #expect(clamped.pinned?.renderHeight == 1)
        #expect(clamped.headerScreenRows == 2)

        let zero = makePrompts([(0, 8)], minHeight: 0)
        #expect(
            computePagerStickyLayout(scrollOffset: 10, viewportHeight: 24, prompts: zero)
                .pinned?.renderHeight == 1
        )
    }

    @Test("push-only has no trailing gap; next nonsticky pushes")
    func pushOnlyAndNonSticky() {
        let prompts = makePrompts([(0, 8), (9, 8)])
        let onlyGap = computePagerStickyLayout(scrollOffset: 8, viewportHeight: 24, prompts: prompts)
        #expect(!onlyGap.hasHeader)

        let push = computePagerStickyLayout(scrollOffset: 7, viewportHeight: 24, prompts: prompts)
        #expect(push.pushed != nil)
        #expect(push.pinned == nil)
        #expect(push.pushed?.visibleHeight == 1)
        #expect(push.headerScreenRows == 1) // no trailing gap

        let nonSticky = [
            PagerPromptDescriptor(
                entryIdx: 0, yVirtual: 0, fullHeight: 4, minHeight: 4, sticky: true
            ),
            PagerPromptDescriptor(
                entryIdx: 1, yVirtual: 12, fullHeight: 8, minHeight: 4, sticky: false
            ),
        ]
        let pinned = computePagerStickyLayout(scrollOffset: 3, viewportHeight: 24, prompts: nonSticky)
        #expect(pinned.pinned?.entryIdx == 0)
        let pushing = computePagerStickyLayout(scrollOffset: 10, viewportHeight: 24, prompts: nonSticky)
        #expect(pushing.pushed?.entryIdx == 0)
        #expect(pushing.pinned == nil)
        let pastB = computePagerStickyLayout(scrollOffset: 13, viewportHeight: 24, prompts: nonSticky)
        #expect(!pastB.hasHeader)
    }

    @Test("bottom line continuity and scrollForContent during collapse")
    func bottomContinuityAndScrollForContent() {
        let viewport = 20
        let prompts = makePrompts([(0, 8)])
        for scroll in 1...10 {
            let layout = computePagerStickyLayout(
                scrollOffset: scroll, viewportHeight: viewport, prompts: prompts
            )
            let contentH = layout.contentHeight(viewportHeight: viewport)
            let sfc = layout.scrollForContent(scroll)
            #expect(sfc + contentH - 1 == scroll + viewport - 1)
        }

        let layout1 = computePagerStickyLayout(scrollOffset: 1, viewportHeight: 24, prompts: prompts)
        #expect(layout1.scrollForContent(1) == 9)
        let layout4 = computePagerStickyLayout(scrollOffset: 4, viewportHeight: 24, prompts: prompts)
        #expect(layout4.scrollForContent(4) == 9)
        let layout5 = computePagerStickyLayout(scrollOffset: 5, viewportHeight: 24, prompts: prompts)
        #expect(layout5.headerScreenRows == 5)
        #expect(layout5.scrollForContent(5) == 10)
    }

    @Test("entry_at_header_row: pinned content, gap nil, past nil")
    func entryAtHeaderRow() {
        let prompts = [
            PagerPromptDescriptor(
                entryIdx: 0, yVirtual: 0, fullHeight: 4, minHeight: 4, sticky: true
            )
        ]
        let layout = computePagerStickyLayout(scrollOffset: 10, viewportHeight: 20, prompts: prompts)
        #expect(layout.pinned != nil)
        guard let pinned = layout.pinned else { return }
        for row in 0..<pinned.visibleHeight {
            #expect(layout.entryAtHeaderRow(row) == 0)
        }
        #expect(layout.entryAtHeaderRow(pinned.visibleHeight) == nil) // gap
        #expect(layout.entryAtHeaderRow(layout.headerScreenRows) == nil)
        #expect(layout.headerEntryArea(entryIdx: 0)?.isPushed == false)
        #expect(layout.headerEntryArea(entryIdx: 99) == nil)
    }

    @Test("pushed header uses min(full, render); small prompt not inflated")
    func pushedRenderHeightInvariant() {
        let small = [
            PagerPromptDescriptor(
                entryIdx: 0, yVirtual: 0, fullHeight: 3, minHeight: 4, sticky: true
            ),
            PagerPromptDescriptor(
                entryIdx: 1, yVirtual: 4, fullHeight: 6, minHeight: 4, sticky: true
            ),
        ]
        let layout = computePagerStickyLayout(scrollOffset: 2, viewportHeight: 20, prompts: small)
        #expect(layout.pushed != nil)
        guard let pushed = layout.pushed else { return }
        #expect(pushed.renderHeight == 3)
        #expect(pushed.visibleHeight == 1)
        #expect(pushed.clipTop == 2)
    }

    @Test("rendered prompt helpers")
    func renderedPromptHelpers() {
        let rp = PagerRenderedPrompt(entryIdx: 5, renderHeight: 5, clipTop: 1)
        #expect(rp.visibleHeight == 4)
        #expect(rp.needsScratchBuffer)
        let rp2 = PagerRenderedPrompt(entryIdx: 0, renderHeight: 4, clipTop: 0)
        #expect(!rp2.needsScratchBuffer)
    }

    @Test("pagerPageScrollRows subtracts header and overlaps by 2")
    func pageScrollRows() {
        #expect(pagerPageScrollRows(viewportHeight: 24, headerScreenRows: 0) == 22)
        #expect(pagerPageScrollRows(viewportHeight: 24, headerScreenRows: 5) == 17)
        #expect(pagerPageScrollRows(viewportHeight: 3, headerScreenRows: 2) == 1)
        #expect(pagerPageScrollRows(viewportHeight: 0, headerScreenRows: 0) == 1)
    }

    @Test("minHeight estimate capped at 6 with user-prompt vpad/body")
    func minHeightEstimate() {
        // Low estimate vs Rust's budgeted `max_lines` re-render is deliberate
        // until a fold seam lands — do not raise the cap to "match" tall bodies.
        #expect(pagerStickyMinHeightEstimate(fullHeight: 3, compact: false) == 3)
        #expect(pagerStickyMinHeightEstimate(fullHeight: 20, compact: false) == 6)
        #expect(pagerStickyMinHeightEstimate(fullHeight: 5, compact: true) == 5)
        #expect(pagerStickyMinHeightEstimate(fullHeight: 0, compact: false) == 1)
    }

    @Test("pinned+gap can report headerScreenRows == viewport+1; content height saturates")
    func headerRowsMayExceedViewport() {
        // Body clamped to viewport=1, then trailing gap → headerScreenRows = 2.
        let prompts = [
            PagerPromptDescriptor(
                entryIdx: 0, yVirtual: 0, fullHeight: 4, minHeight: 4, sticky: true
            )
        ]
        let layout = computePagerStickyLayout(scrollOffset: 10, viewportHeight: 1, prompts: prompts)
        #expect(layout.pinned?.renderHeight == 1)
        #expect(layout.headerScreenRows == 2) // viewport + gap, Rust parity
        #expect(layout.contentHeight(viewportHeight: 1) == 0)
        #expect(layout.scrollForContent(10) == 12)
    }

    @Test("visible content range clamp is always valid")
    func visibleRangeAlwaysValid() {
        // Pathological: scrollForContent past EOF with zero paint height.
        let empty = pagerStickyVisibleContentRange(
            scrollForContent: 12, contentPaintHeight: 0, lineCount: 5
        )
        #expect(empty == 5..<5)

        // Past EOF with leftover paint budget still clamps to empty-at-end.
        let past = pagerStickyVisibleContentRange(
            scrollForContent: 100, contentPaintHeight: 10, lineCount: 20
        )
        #expect(past == 20..<20)

        // Normal window.
        let ok = pagerStickyVisibleContentRange(
            scrollForContent: 3, contentPaintHeight: 5, lineCount: 10
        )
        #expect(ok == 3..<8)

        // Property: arbitrary scroll/viewport/descriptors → valid range.
        let descriptors: [[PagerPromptDescriptor]] = [
            [],
            [PagerPromptDescriptor(
                entryIdx: 0, yVirtual: 0, fullHeight: 4, minHeight: 4, sticky: true
            )],
            [
                PagerPromptDescriptor(
                    entryIdx: 0, yVirtual: 0, fullHeight: 6, minHeight: 4, sticky: true
                ),
                PagerPromptDescriptor(
                    entryIdx: 1, yVirtual: 7, fullHeight: 8, minHeight: 4, sticky: true
                ),
            ],
            [
                PagerPromptDescriptor(
                    entryIdx: 0, yVirtual: 0, fullHeight: 3, minHeight: 4, sticky: true
                ),
                PagerPromptDescriptor(
                    entryIdx: 1, yVirtual: 12, fullHeight: 8, minHeight: 4, sticky: false
                ),
            ],
        ]
        for prompts in descriptors {
            for viewport in [0, 1, 2, 3, 5, 24] {
                for scroll in [0, 1, 2, 5, 10, 50, 100] {
                    for lineCount in [0, 1, 3, 10, 40] {
                        let sticky = computePagerStickyLayout(
                            scrollOffset: scroll,
                            viewportHeight: viewport,
                            prompts: prompts
                        )
                        let range = pagerStickyVisibleContentRange(
                            scrollForContent: sticky.scrollForContent(scroll),
                            contentPaintHeight: sticky.contentHeight(viewportHeight: viewport),
                            lineCount: lineCount
                        )
                        #expect(range.lowerBound >= 0)
                        #expect(range.upperBound <= lineCount)
                        #expect(range.lowerBound <= range.upperBound)
                    }
                }
            }
        }
    }
}

// MARK: - Frame integration

@Suite("PagerStickyHeader frame")
struct PagerStickyHeaderFrameTests {
    private func tallTranscriptState(
        scroll: PagerScrollPosition,
        compact: Bool = false,
        stickyHeadersEnabled: Bool = true,
        height: Int = 20
    ) -> PagerRenderState {
        let filler = (0..<12).map { "assist line \($0)" }.joined(separator: "\n")
        return PagerRenderState(
            size: TerminalSize(width: 48, height: height),
            conversation: [
                .message(PagerMessage(role: .user, text: "alpha question")),
                .message(PagerMessage(role: .assistant, text: filler)),
                .message(PagerMessage(role: .user, text: "beta question")),
                .message(PagerMessage(role: .assistant, text: filler)),
            ],
            input: PagerComposerState(isFocused: false),
            scrollPosition: scroll,
            showScrollbar: true,
            compactMode: compact,
            stickyHeadersEnabled: stickyHeadersEnabled
        )
    }

    @Test("compact mode keeps old non-sticky behavior")
    func compactOldBehavior() {
        let state = tallTranscriptState(scroll: .offset(8), compact: true)
        let result = renderPagerFrame(state)
        #expect(!result.layout.sticky.hasHeader)
        #expect(result.layout.headerScreenRows == 0)
        #expect(result.layout.conversationHit?.sticky.hasHeader == false)
        // Content paints from logical scroll (no scrollForContent bump).
        #expect(result.layout.visibleContentLines.lowerBound == result.layout.scrollOffset)
    }

    @Test("sticky_headers false matches compact: no pin, plain page geometry")
    func stickyHeadersDisabledOldBehavior() {
        // `use_sticky = sticky_headers && !compact` (`scrollback_pane.rs:395-401`).
        let state = tallTranscriptState(
            scroll: .offset(8),
            compact: false,
            stickyHeadersEnabled: false
        )
        let result = renderPagerFrame(state)
        #expect(!result.layout.sticky.hasHeader)
        #expect(result.layout.sticky.pinned == nil)
        #expect(result.layout.sticky.pushed == nil)
        #expect(result.layout.headerScreenRows == 0)
        #expect(result.layout.conversationHit?.sticky.hasHeader == false)
        #expect(result.layout.visibleContentLines.lowerBound == result.layout.scrollOffset)
        let viewport = result.layout.conversation.height
        #expect(pagerPageScrollRows(viewportHeight: viewport, headerScreenRows: 0)
            == max(1, max(0, viewport - 2)))
    }

    @Test("compact overrides sticky_headers true")
    func compactOverridesStickyOn() {
        let state = tallTranscriptState(
            scroll: .offset(8),
            compact: true,
            stickyHeadersEnabled: true
        )
        let result = renderPagerFrame(state)
        #expect(!result.layout.sticky.hasHeader)
        #expect(result.layout.headerScreenRows == 0)
        #expect(result.layout.visibleContentLines.lowerBound == result.layout.scrollOffset)
    }

    @Test("non-compact scroll past prompt pins sticky header")
    func paintsPinnedHeader() throws {
        let state = tallTranscriptState(scroll: .offset(4), compact: false)
        let result = renderPagerFrame(state)
        #expect(result.layout.sticky.hasHeader)
        #expect(result.layout.headerScreenRows == result.layout.sticky.headerScreenRows)
        #expect(result.layout.sticky.pinned?.entryIdx == 0)
        let expectedRange = pagerStickyVisibleContentRange(
            scrollForContent: result.layout.sticky.scrollForContent(result.layout.scrollOffset),
            contentPaintHeight: result.layout.sticky.contentHeight(
                viewportHeight: result.layout.conversation.height
            ),
            lineCount: result.layout.totalContentLines
        )
        #expect(result.layout.visibleContentLines == expectedRange)

        let hit = try #require(result.layout.conversationHit)
        let headerY = hit.conversation.y
        #expect(hit.blockIndex(atScreenY: headerY) == 0)
        if let gap = result.layout.sticky.gapRow {
            #expect(hit.blockIndex(atScreenY: hit.conversation.y + gap) == nil)
        }
    }

    @Test("hit header / gap / content identity")
    func hitHeaderGapContent() throws {
        let state = tallTranscriptState(scroll: .offset(5), compact: false)
        let result = renderPagerFrame(state)
        let hit = try #require(result.layout.conversationHit)
        let sticky = hit.sticky
        #expect(sticky.hasHeader)

        let areaY = hit.conversation.y
        if let pinned = sticky.pinned {
            for row in 0..<pinned.visibleHeight {
                #expect(hit.blockIndex(atScreenY: areaY + row) == pinned.entryIdx)
            }
            if let gap = sticky.gapRow {
                #expect(hit.blockIndex(atScreenY: areaY + gap) == nil)
            }
        }

        // First content row: Rust content_y = viewportY + scrollOffset.
        let contentRow = sticky.headerScreenRows
        let contentScreenY = areaY + contentRow
        let expected = pagerConversationBlockIndex(
            screenY: contentScreenY,
            conversation: hit.conversation,
            scrollOffset: hit.scrollOffset,
            blockStartLines: hit.blockStartLines,
            blockHeights: hit.blockHeights
        )
        #expect(hit.blockIndex(atScreenY: contentScreenY) == expected)
    }

    @Test("scrollbar and timeline virtual offsets unchanged with sticky")
    func scrollbarTimelineOffsetsUnchanged() throws {
        let state = tallTranscriptState(scroll: .offset(6), compact: false, height: 28)
        var withTimeline = state
        withTimeline.showTimeline = true
        withTimeline.showScrollbar = true

        let stickyFrame = renderPagerFrame(state)
        #expect(stickyFrame.layout.sticky.hasHeader)
        let thumb = try #require(stickyFrame.layout.scrollbarHit)
        #expect(thumb.viewportHeight == stickyFrame.layout.conversation.height)
        #expect(thumb.rect.height == stickyFrame.layout.conversation.height)
        let expectedStart = pagerScrollbarThumbStart(
            scrollOffset: stickyFrame.layout.scrollOffset,
            total: stickyFrame.layout.totalContentLines,
            viewport: stickyFrame.layout.conversation.height,
            trackHeight: stickyFrame.layout.conversation.height
        )
        #expect(thumb.thumbStart == expectedStart)
        #expect(stickyFrame.layout.scrollOffset == 6)

        let railFrame = renderPagerFrame(withTimeline)
        #expect(railFrame.layout.scrollOffset == 6)
        // Rail geometry (when present) is still derived from logical scrollOffset.
        if railFrame.layout.timelineRail != nil {
            #expect(railFrame.layout.sticky.scrollForContent(6) >= 6)
        }
    }

    @Test("resize and stream recompute sticky from new layout heights")
    func resizeAndStreamRecompute() throws {
        var state = tallTranscriptState(scroll: .offset(4), compact: false, height: 22)
        let a = renderPagerFrame(state)
        #expect(a.layout.sticky.hasHeader)

        state.size = TerminalSize(width: 48, height: 14)
        let b = renderPagerFrame(state)
        // Shorter viewport re-clamps render height; layout still recomputes.
        #expect(b.layout.headerScreenRows == b.layout.sticky.headerScreenRows)

        // Streaming: append body to the first user prompt → taller fullHeight.
        state.conversation[0] = .message(PagerMessage(
            role: .user,
            text: "alpha question\nmore\nlines\nhere"
        ))
        state.size = TerminalSize(width: 48, height: 22)
        let c = renderPagerFrame(state)
        let hit = try #require(c.layout.conversationHit)
        let prompts = pagerPromptDescriptors(
            conversation: state.conversation,
            blockStartLines: hit.blockStartLines,
            blockHeights: hit.blockHeights,
            compact: false
        )
        #expect(prompts.first?.fullHeight == hit.blockHeights[0])
        #expect((prompts.first?.minHeight ?? 99) <= pagerMaxTruncatedHeaderHeight)
    }

    @Test("descriptors only for user messages; sticky true")
    func descriptorsUserOnly() {
        let layout = makeConversationLayout(
            [
                .message(PagerMessage(role: .user, text: "q")),
                .message(PagerMessage(role: .assistant, text: "a")),
                .tool(PagerToolCard(name: "bash", input: "ls")),
                .message(PagerMessage(role: .user, text: "q2")),
            ],
            width: 40,
            theme: .default
        )
        let prompts = pagerPromptDescriptors(
            conversation: [
                .message(PagerMessage(role: .user, text: "q")),
                .message(PagerMessage(role: .assistant, text: "a")),
                .tool(PagerToolCard(name: "bash", input: "ls")),
                .message(PagerMessage(role: .user, text: "q2")),
            ],
            blockStartLines: layout.blockStartLines,
            blockHeights: layout.blockHeights,
            compact: false
        )
        let entryIndices = prompts.map { $0.entryIdx }
        let allSticky = prompts.allSatisfy { $0.sticky }
        #expect(entryIndices == [0, 3])
        #expect(allSticky)
        #expect(prompts[0].yVirtual == layout.blockStartLines[0])
        #expect(prompts[0].fullHeight == layout.blockHeights[0])
    }

    @Test("pinned header paints user band; content starts below header")
    func paintHeaderAndContentRows() {
        let theme = PagerRenderTheme.default
        var state = tallTranscriptState(scroll: .offset(4), compact: false)
        state.theme = theme
        let result = renderPagerFrame(state)
        let sticky = result.layout.sticky
        #expect(sticky.pinned != nil)
        let y0 = result.layout.conversation.y
        // User prompts wear bgLight on every row — sticky header should too.
        let headerCell = result.buffer.cell(x: result.layout.conversation.x + 3, y: y0)
        #expect(headerCell?.background == theme.bgLight)

        let contentY = y0 + sticky.headerScreenRows
        #expect(contentY < result.layout.conversation.y + result.layout.conversation.height)
        #expect(sticky.headerScreenRows > 0)
    }

    @Test("pinned entry body overlapping content window still paints (not blanked)")
    func pinnedEntryContentOverlapStillPaints() throws {
        // Rust `pinned_entry_idx` suppresses a duplicate *selection box* only
        // (`scrollback_pane.rs:1013`, `:1187-1194`) — content rows that fall
        // in the content window must still paint. A misported `continue`
        // left the blank pre-fill (bgBase) instead of user bgLight.
        //
        // Bottom-line continuity usually places content past the pin's
        // virtual span; search sizes/offsets for a real intersection (e.g.
        // when layout heights and sticky collapse leave body rows in range).
        let theme = PagerRenderTheme.default
        let tallPrompt = (0..<36).map { "pin-body-\($0)-UNIQUE" }.joined(separator: "\n")
        let filler = (0..<16).map { "asst-fill-\($0)" }.joined(separator: "\n")

        var foundOverlap = false
        for height in [14, 18, 22, 26, 30] {
            for offset in 1...80 {
                var state = PagerRenderState(
                    size: TerminalSize(width: 48, height: height),
                    conversation: [
                        .message(PagerMessage(role: .user, text: tallPrompt)),
                        .message(PagerMessage(role: .assistant, text: filler)),
                        .message(PagerMessage(role: .user, text: "second-prompt")),
                        .message(PagerMessage(role: .assistant, text: filler)),
                    ],
                    input: PagerComposerState(isFocused: false),
                    scrollPosition: .offset(offset),
                    showScrollbar: true,
                    compactMode: false
                )
                state.theme = theme
                // Select the pin so a future selection-box port cannot blank
                // content as a side effect of "skip duplicate selection".
                state.selectedBlockIndex = 0
                let result = renderPagerFrame(state)
                guard let pinned = result.layout.sticky.pinned,
                      pinned.entryIdx == 0,
                      let hit = result.layout.conversationHit,
                      result.layout.headerScreenRows > 0,
                      result.layout.headerScreenRows < result.layout.conversation.height
                else { continue }

                let start = hit.blockStartLines[pinned.entryIdx]
                let end = start + hit.blockHeights[pinned.entryIdx]
                let visible = result.layout.visibleContentLines
                let lo = max(visible.lowerBound, start)
                let hi = min(visible.upperBound, end)
                guard lo < hi else { continue }

                foundOverlap = true
                let contentOrigin =
                    result.layout.conversation.y + result.layout.headerScreenRows
                for lineIndex in lo..<hi {
                    let row = lineIndex - visible.lowerBound
                    let y = contentOrigin + row
                    let cell = result.buffer.cell(
                        x: result.layout.conversation.x + 3,
                        y: y
                    )
                    #expect(
                        cell?.background == theme.bgLight,
                        "pinned body line \(lineIndex) at y=\(y) must paint user band, not blank pre-fill"
                    )
                }
                break
            }
            if foundOverlap { break }
        }

        if !foundOverlap {
            // Continuity can keep content past the pin for this layout. Still
            // prove the content window paints under a selected pin (assistant
            // body), and that selection screenY is retained for mapped lines.
            var state = tallTranscriptState(scroll: .offset(5), compact: false)
            state.theme = theme
            state.selectedBlockIndex = 0
            let result = renderPagerFrame(state)
            #expect(result.layout.sticky.pinned?.entryIdx == 0)
            let contentY =
                result.layout.conversation.y + result.layout.headerScreenRows
            #expect(contentY < result.layout.conversation.y + result.layout.conversation.height)
            let cell = result.buffer.cell(
                x: result.layout.conversation.x + 3,
                y: contentY
            )
            #expect(cell != nil)
            // Content row was paintConversationLine'd (accent and/or spans),
            // not left as an untouched hole in the sticky band.
            #expect(result.layout.visibleContentLines.count > 0)
        }
    }

    @Test("text selection keeps screenY for pinned lines mapped into content")
    func textSelectionKeepsScreenYForPinnedContentLines() {
        // Sticky header band lines are absent from screenYByLineIndex; body
        // rows that do appear in the content window must keep their screenY
        // (not forced nil just because the entry is pinned).
        let items: [PagerConversationItem] = [
            .message(PagerMessage(role: .user, text: "alpha\nbeta\ngamma\ndelta")),
            .message(PagerMessage(role: .assistant, text: "reply")),
        ]
        let layout = makeConversationLayout(items, width: 40, theme: .default)
        #expect(layout.blockHeights[0] >= 3)
        // Pretend mid-block lines of the user entry (0) landed in content.
        let lineA = layout.blockStartLines[0] + 1
        let lineB = layout.blockStartLines[0] + 2
        let screenYByLineIndex = [lineA: 10, lineB: 11]
        let model = makePagerTextSelectionModel(
            items: items,
            lines: layout.lines,
            conversationLayout: layout,
            contentArea: TerminalRect(x: 0, y: 8, width: 40, height: 10),
            conversationArea: TerminalRect(x: 0, y: 0, width: 40, height: 20),
            contentWidth: 32,
            contentX: 5,
            screenYByLineIndex: screenYByLineIndex
        )
        let allLines = model.ranges.flatMap { range in range.lines }
        let pinnedLines = allLines.filter { line in
            line.entryIndex == 0 && line.screenY != nil
        }
        #expect(pinnedLines.contains { line in line.screenY == 10 })
        #expect(pinnedLines.contains { line in line.screenY == 11 })
    }

    @Test("tiny viewport + bottom scroll does not trap on visibleRange")
    func tinyViewportBottomScrollNoTrap() {
        // Short terminal + followTail: sticky header can claim viewport+1 rows
        // (body clamped to viewport, then trailing gap) while scrollForContent
        // overshoots line count — must yield a valid empty/clamped range.
        let filler = (0..<8).map { "line \($0)" }.joined(separator: "\n")
        let state = PagerRenderState(
            size: TerminalSize(width: 40, height: 6),
            conversation: [
                .message(PagerMessage(role: .user, text: "alpha")),
                .message(PagerMessage(role: .assistant, text: filler)),
                .message(PagerMessage(role: .user, text: "beta")),
                .message(PagerMessage(role: .assistant, text: filler)),
            ],
            input: PagerComposerState(isFocused: false, showBorders: false, maximumHeight: 1),
            scrollPosition: .followTail,
            showScrollbar: false,
            compactMode: false
        )
        let result = renderPagerFrame(state)
        let range = result.layout.visibleContentLines
        #expect(range.lowerBound >= 0)
        #expect(range.upperBound <= result.layout.totalContentLines)
        #expect(range.lowerBound <= range.upperBound)

        // Explicit bottom-ish offset with a 1-row conversation slot after chrome.
        var offsetState = state
        offsetState.scrollPosition = .offset(10_000)
        offsetState.size = TerminalSize(width: 40, height: 5)
        let offsetResult = renderPagerFrame(offsetState)
        let offsetRange = offsetResult.layout.visibleContentLines
        #expect(offsetRange.lowerBound <= offsetRange.upperBound)
        #expect(offsetRange.upperBound <= offsetResult.layout.totalContentLines)
    }
}
