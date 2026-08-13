// PagerScrollbarHitTests.swift
//
// Pure inverse of transcript scrollbar paint math
// (`pagerScrollbarOffset` ↔ `renderConversation` thumb placement) and
// last-painted geometry publication when the scrollbar paints vs when the
// timeline rail owns the gutter.

import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("Pager scrollbar hit math")
struct PagerScrollbarHitTests {
    @Test("top / mid / bottom cells map to 0, proportional, and max offset")
    func topMidBottom() {
        let total = 100
        let viewport = 10
        let track = 10
        let maxOffset = total - viewport

        #expect(pagerScrollbarOffset(
            cellIndex: 0, trackHeight: track, total: total, viewport: viewport
        ) == 0)
        #expect(pagerScrollbarOffset(
            cellIndex: track - 1, trackHeight: track, total: total, viewport: viewport
        ) == maxOffset)

        let mid = pagerScrollbarOffset(
            cellIndex: 5, trackHeight: track, total: total, viewport: viewport
        )
        #expect(mid > 0)
        #expect(mid < maxOffset)

        // Inverse of paint: an offset's thumb start cell, when clicked at
        // its thumb center, recovers a nearby offset (integer division).
        let thumbHeight = pagerScrollbarThumbHeight(total: total, viewport: viewport)
        let thumbStart = pagerScrollbarThumbStart(
            scrollOffset: mid,
            total: total,
            viewport: viewport,
            trackHeight: track
        )
        let center = thumbStart + thumbHeight / 2
        let recovered = pagerScrollbarOffset(
            cellIndex: center, trackHeight: track, total: total, viewport: viewport
        )
        #expect(abs(recovered - mid) <= max(1, maxOffset / track))
    }

    @Test("thumb travel edges: total <= viewport and one-row track")
    func thumbTravelEdgeCases() {
        #expect(pagerScrollbarOffset(
            cellIndex: 0, trackHeight: 10, total: 10, viewport: 10
        ) == 0)
        #expect(pagerScrollbarOffset(
            cellIndex: 5, trackHeight: 10, total: 5, viewport: 10
        ) == 0)
        #expect(pagerScrollbarOffset(
            cellIndex: 9, trackHeight: 10, total: 10, viewport: 10
        ) == 0)

        // One-row track: Rust's `cell_index == 0` Top arm wins over Bottom.
        #expect(pagerScrollbarOffset(
            cellIndex: 0, trackHeight: 1, total: 50, viewport: 10
        ) == 0)
        #expect(pagerScrollbarOffset(
            cellIndex: 1, trackHeight: 1, total: 50, viewport: 10
        ) == 40)

        let thumb = pagerScrollbarThumbHeight(total: 10, viewport: 10)
        #expect(thumb == 10)
        #expect(pagerScrollbarThumbStart(
            scrollOffset: 99, total: 10, viewport: 10, trackHeight: 10
        ) == 0)
    }

    @Test("malformed inputs stay clamped and trap-free")
    func malformedInputs() {
        #expect(pagerScrollbarOffset(
            cellIndex: -5, trackHeight: 10, total: 100, viewport: 10
        ) == 0)
        #expect(pagerScrollbarOffset(
            cellIndex: 50, trackHeight: 10, total: 100, viewport: 10
        ) == 90)
        #expect(pagerScrollbarOffset(
            cellIndex: 3, trackHeight: 0, total: 100, viewport: 10
        ) == 0)
        #expect(pagerScrollbarOffset(
            cellIndex: 3, trackHeight: -1, total: 100, viewport: 10
        ) == 0)
        #expect(pagerScrollbarOffset(
            cellIndex: 3, trackHeight: 10, total: -20, viewport: 10
        ) == 0)
        #expect(pagerScrollbarThumbHeight(total: 0, viewport: 0) == 1)
        #expect(pagerScrollbarThumbStart(
            scrollOffset: -10, total: 100, viewport: 10, trackHeight: 10
        ) == 0)
    }

    @Test("frame publishes scrollbarHit only when the gutter paints")
    func publishesWhenScrollbarPaints() throws {
        let filler = (0..<40).map { "sb-line-\($0)" }.joined(separator: "\n")
        let withScrollbar = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 16),
            conversation: [
                .message(PagerMessage(role: .user, text: "prompt")),
                .message(PagerMessage(role: .assistant, text: filler)),
            ],
            input: PagerComposerState(isFocused: false),
            scrollPosition: .offset(0),
            showScrollbar: true,
            showTimeline: false
        ))
        #expect(withScrollbar.layout.hasScrollbar)
        let hit = try #require(withScrollbar.layout.scrollbarHit)
        #expect(hit.rect.width == 1)
        #expect(hit.rect.height == withScrollbar.layout.conversation.height)
        #expect(hit.rect.x == withScrollbar.layout.conversationHit?.selectableEndX)
        #expect(hit.totalContentLines == withScrollbar.layout.totalContentLines)
        #expect(hit.viewportHeight == withScrollbar.layout.conversation.height)
        #expect(hit.thumbHeight == pagerScrollbarThumbHeight(
            total: hit.totalContentLines,
            viewport: hit.viewportHeight
        ))
        #expect(hit.offset(atScreenY: hit.rect.y) == 0)
        #expect(hit.isBottomCell(atScreenY: hit.rect.y + hit.rect.height - 1))
        #expect(!hit.isBottomCell(atScreenY: hit.rect.y))

        let fits = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 40),
            conversation: [
                .message(PagerMessage(role: .user, text: "short")),
            ],
            input: PagerComposerState(isFocused: false),
            scrollPosition: .followTail,
            showScrollbar: true,
            showTimeline: false
        ))
        #expect(!fits.layout.hasScrollbar)
        #expect(fits.layout.scrollbarHit == nil)
    }

    @Test("timeline rail publishes no scrollbarHit")
    func railClearsScrollbarHit() {
        let filler = (0..<20).map { "rail fill \($0)" }.joined(separator: "\n\n")
        let result = renderPagerFrame(PagerRenderState(
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
        ))
        #expect(result.layout.timelineRail != nil)
        #expect(!result.layout.hasScrollbar)
        #expect(result.layout.scrollbarHit == nil)
    }
}
