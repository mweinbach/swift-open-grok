// PagerTimelineRailTests.swift
//
// `[ui] show_timeline` at the geometry and paint seams. The pure-geometry
// pins are ports of upstream's own suite (`views/timeline.rs:359-549`) with
// the same fixture numbers, so a divergence in windowing, centering, or
// hit-testing shows up against the reference's expected values, not this
// port's. The paint pins run `renderPagerFrame` — what the live
// composition's every repaint calls (AGENTS.md §3) — and assert on the
// cells and the published `layout.timelineRail`, the same geometry the
// mouse router consumes. The live pass-through (config → user value →
// frame flag), the toggle persist, and click-to-jump are pinned in
// `Tests/OpenGrokCLITests/LiveTimelineTests.swift`.

import Foundation
import Testing
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

// MARK: - Pure geometry (port of views/timeline.rs tests)

/// Upstream's fixture area (`views/timeline.rs:364-371`).
private func upstreamArea() -> TerminalRect {
    TerminalRect(x: 0, y: 2, width: 80, height: 20)
}

/// `compute_rail` with adjacent targets for an off-bottom prompt row
/// (`views/timeline.rs:374-382`).
private func makeRail(turnCount: Int, active: Int?) -> PagerTimelineRail? {
    let viewport = PagerTimelineViewport(
        active: active,
        upTarget: active.flatMap { $0 > 0 ? $0 - 1 : nil },
        downTarget: active.flatMap { $0 + 1 < turnCount ? $0 + 1 : nil },
        atBottom: false
    )
    return pagerComputeTimelineRail(
        scrollbackArea: upstreamArea(),
        railX: 76,
        turnCount: turnCount,
        viewport: viewport
    )
}

@Suite("Timeline rail geometry")
struct PagerTimelineRailGeometryTests {
    @Test("the rail hides below MIN_TURNS and in a tiny area")
    func railHiddenBelowMinTurnsOrTinyArea() {
        // views/timeline.rs:385-397.
        #expect(makeRail(turnCount: 1, active: 0) == nil)
        let tiny = TerminalRect(x: 0, y: 2, width: 80, height: 2)
        let viewport = PagerTimelineViewport(active: 0, downTarget: 1)
        #expect(pagerComputeTimelineRail(
            scrollbackArea: tiny,
            railX: 76,
            turnCount: 5,
            viewport: viewport
        ) == nil)
    }

    @Test("a small conversation shows all ticks, centered")
    func smallConversationShowsAllTicksCentered() {
        // views/timeline.rs:400-407: 4 ticks + 2 chevrons = 6 rows centered
        // in 20: top = 2 + 7 = 9.
        guard let rail = makeRail(turnCount: 4, active: 1) else {
            Issue.record("rail should be eligible")
            return
        }
        #expect(rail.window == 0..<4)
        #expect(rail.upY == 9)
        #expect(rail.ticksY == 10)
        #expect(rail.downY == 14)
    }

    @Test("overflow windows slide around the active turn")
    func overflowWindowsAroundActive() {
        // views/timeline.rs:410-463: 50 turns, 18 tick rows (20 - 2 chevrons).
        guard let mid = makeRail(turnCount: 50, active: 25) else {
            Issue.record("rail should be eligible")
            return
        }
        #expect(mid.window.count == 18)
        #expect(mid.window.contains(25))
        #expect(mid.window.lowerBound == 25 - 9)
        #expect(mid.hit(x: 76, y: mid.ticksY) == .tick(mid.window.lowerBound))

        // Active at the end clamps the window to the tail.
        #expect(makeRail(turnCount: 50, active: 49)?.window == 32..<50)
        // No active turn anchors to the newest.
        #expect(makeRail(turnCount: 50, active: nil)?.window == 32..<50)

        // At the bottom the window prefers the tail, but still includes the
        // viewport-top (active) turn so a tick stays highlighted.
        let bottomMid = pagerComputeTimelineRail(
            scrollbackArea: upstreamArea(),
            railX: 76,
            turnCount: 50,
            viewport: PagerTimelineViewport(
                active: 25, upTarget: 24, downTarget: 26, atBottom: true
            )
        )
        #expect(bottomMid?.window == 25..<43)
        // Active already in the tail → pin to the newest ticks.
        let bottomTail = pagerComputeTimelineRail(
            scrollbackArea: upstreamArea(),
            railX: 76,
            turnCount: 50,
            viewport: PagerTimelineViewport(
                active: 40, upTarget: 39, downTarget: 41, atBottom: true
            )
        )
        #expect(bottomTail?.window == 32..<50)
    }

    @Test("hit-testing maps chevrons and ticks, and misses off-rail cells")
    func hitMapsChevronsAndTicks() {
        // views/timeline.rs:466-479. Rail width 2: cols 76-77.
        guard let rail = makeRail(turnCount: 4, active: 1) else {
            Issue.record("rail should be eligible")
            return
        }
        #expect(rail.hit(x: 75, y: rail.ticksY) == nil)
        #expect(rail.hit(x: 78, y: rail.ticksY) == nil)
        #expect(rail.hit(x: 77, y: rail.upY) == .up)
        #expect(rail.hit(x: 77, y: rail.downY) == .down)
        #expect(rail.hit(x: 76, y: rail.ticksY) == .tick(0))
        #expect(rail.hit(x: 77, y: rail.ticksY + 3) == .tick(3))
        #expect(rail.hit(x: 76, y: rail.upY - 1) == nil)
    }

    @Test("chevron targets follow the rail state — end stops are no-ops")
    func chevronTargetsFollowTheRailState() {
        // views/timeline.rs:482-538.
        guard let mid = makeRail(turnCount: 10, active: 3),
              let first = makeRail(turnCount: 10, active: 0),
              let lastActive = makeRail(turnCount: 10, active: 9),
              let pre = pagerComputeTimelineRail(
                  scrollbackArea: upstreamArea(),
                  railX: 76,
                  turnCount: 10,
                  viewport: PagerTimelineViewport(active: 0, downTarget: 0)
              ),
              let bottom = pagerComputeTimelineRail(
                  scrollbackArea: upstreamArea(),
                  railX: 76,
                  turnCount: 10,
                  viewport: PagerTimelineViewport(
                      active: 4, upTarget: 3, downTarget: 5, atBottom: true
                  )
              ),
              let lastOwnsTop = pagerComputeTimelineRail(
                  scrollbackArea: upstreamArea(),
                  railX: 76,
                  turnCount: 10,
                  viewport: PagerTimelineViewport(
                      active: 9, upTarget: 8, downTarget: nil, atBottom: true
                  )
              )
        else {
            Issue.record("all rails should be eligible")
            return
        }
        #expect(pagerTimelineChevronTarget(mid, .tick(7)) == 7)
        #expect(pagerTimelineChevronTarget(mid, .up) == 2)
        #expect(pagerTimelineChevronTarget(mid, .down) == 4)
        // End stops are no-ops (the dim chevrons).
        #expect(pagerTimelineChevronTarget(first, .up) == nil)
        #expect(pagerTimelineChevronTarget(lastActive, .down) == nil)
        // Pre-turn content focuses the first tick, but ▼ still enters that
        // first turn rather than skipping to the second.
        #expect(pagerTimelineChevronTarget(pre, .down) == 0)
        #expect(pagerTimelineChevronTarget(pre, .up) == nil)
        // At the bottom ▼ still steps to the next turn; ▲ steps up.
        #expect(pagerTimelineChevronTarget(bottom, .up) == 3)
        #expect(pagerTimelineChevronTarget(bottom, .down) == 5)
        // ▼ dims only when the last turn already owns the top.
        #expect(pagerTimelineChevronTarget(lastOwnsTop, .down) == nil)
    }

    @Test("rail_width gates eligibility on setting, width, and turn count")
    func railWidthGatesEligibility() {
        // views/timeline.rs:541-549 minus the subagent-view arm (this port
        // has no subagent scrollback view; the gate is vacuously false).
        #expect(pagerTimelineRailWidth(
            showTimeline: true, terminalWidth: 80, turnCount: 5
        ) == PagerTimelineMetrics.railWidth)
        #expect(pagerTimelineRailWidth(
            showTimeline: false, terminalWidth: 80, turnCount: 5
        ) == 0)
        #expect(pagerTimelineRailWidth(
            showTimeline: true,
            terminalWidth: PagerTimelineMetrics.minTerminalWidth - 1,
            turnCount: 5
        ) == 0)
        #expect(pagerTimelineRailWidth(
            showTimeline: true, terminalWidth: 80, turnCount: 1
        ) == 0)
    }
}

// MARK: - Viewport derivation (port of scrollback/state/timeline.rs reads)

@Suite("Timeline viewport derivation")
struct PagerTimelineViewportTests {
    // Two turns whose prompts paint at lines 5 and 20.
    private let prompts = [5, 20]

    @Test("pre-turn content focuses the first turn; ▲ dims, ▼ enters it")
    func preTurnContentFocusesFirstTurn() {
        // `active_turn_for_viewport` returns the FIRST turn while pre-turn
        // content owns the top (timeline.rs:83-91,396-419).
        let viewport = pagerTimelineViewport(
            promptLineIndices: prompts, scrollOffset: 0, maximumOffset: 40
        )
        #expect(viewport.active == 0)
        #expect(viewport.upTarget == nil)
        #expect(viewport.downTarget == 0)
        #expect(!viewport.atBottom)
    }

    @Test("a prompt row at the top owns its turn; ▲ dims on the first")
    func promptRowAtTopOwnsItsTurn() {
        let viewport = pagerTimelineViewport(
            promptLineIndices: prompts, scrollOffset: 5, maximumOffset: 40
        )
        #expect(viewport.active == 0)
        // Strictly-above is empty on the prompt's own row (timeline.rs:99-104).
        #expect(viewport.upTarget == nil)
        #expect(viewport.downTarget == 1)
    }

    @Test("mid-turn, ▲ first aligns the current turn's own prompt")
    func midTurnUpSnapsToOwnPrompt() {
        // The h-key rule (timeline.rs:95-98,344-368): from inside turn 0's
        // response the ▲ target is turn 0 itself, not `active - 1`.
        let viewport = pagerTimelineViewport(
            promptLineIndices: prompts, scrollOffset: 6, maximumOffset: 40
        )
        #expect(viewport.active == 0)
        #expect(viewport.upTarget == 0)
        #expect(viewport.downTarget == 1)
    }

    @Test("the last turn at the top dims ▼ and steps ▲ to its own prompt")
    func lastTurnAtTop() {
        let atPrompt = pagerTimelineViewport(
            promptLineIndices: prompts, scrollOffset: 20, maximumOffset: 40
        )
        #expect(atPrompt.active == 1)
        #expect(atPrompt.upTarget == 0)
        #expect(atPrompt.downTarget == nil)

        let midTurn = pagerTimelineViewport(
            promptLineIndices: prompts, scrollOffset: 21, maximumOffset: 40
        )
        #expect(midTurn.active == 1)
        #expect(midTurn.upTarget == 1)
        #expect(midTurn.downTarget == nil)
    }

    @Test("atBottom is the has_content_below complement")
    func atBottomTracksMaximumOffset() {
        #expect(pagerTimelineViewport(
            promptLineIndices: prompts, scrollOffset: 40, maximumOffset: 40
        ).atBottom)
        #expect(!pagerTimelineViewport(
            promptLineIndices: prompts, scrollOffset: 39, maximumOffset: 40
        ).atBottom)
    }

    @Test("no prompts yields no targets")
    func noPromptsYieldsNoTargets() {
        let viewport = pagerTimelineViewport(
            promptLineIndices: [], scrollOffset: 0, maximumOffset: 0
        )
        #expect(viewport.active == nil)
        #expect(viewport.upTarget == nil)
        #expect(viewport.downTarget == nil)
    }
}

// MARK: - Paint (renderPagerFrame)

/// A two-turn transcript: short prompt, tall reply, short prompt, short
/// reply. Tall enough at 80 columns to overflow a 24-row frame, so the
/// scrollbar-vs-rail arbitration is observable.
private func twoTurnConversation(replyLines: Int = 30) -> [PagerConversationItem] {
    [
        .message(PagerMessage(role: .user, text: "alpha question")),
        .message(PagerMessage(
            role: .assistant,
            text: (0..<replyLines).map { "reply line \($0)" }.joined(separator: "\n")
        )),
        .message(PagerMessage(role: .user, text: "beta question")),
        .message(PagerMessage(role: .assistant, text: "short reply")),
    ]
}

private func makeFrame(
    width: Int = 80,
    height: Int = 24,
    conversation: [PagerConversationItem],
    showTimeline: Bool,
    showScrollbar: Bool = true,
    scrollPosition: PagerScrollPosition = .followTail
) -> PagerRenderResult {
    renderPagerFrame(PagerRenderState(
        size: TerminalSize(width: width, height: height),
        conversation: conversation,
        input: PagerComposerState(text: ""),
        scrollPosition: scrollPosition,
        theme: .grokNight,
        showScrollbar: showScrollbar,
        showTimeline: showTimeline
    ))
}

@Suite("Timeline rail paint")
struct PagerTimelineRailPaintTests {
    @Test("the rail replaces the scrollbar in its gutter and publishes its geometry")
    func railReplacesScrollbar() {
        // Chrome for this fixture: no status bar or shortcuts, composer 3
        // rows + 1 gap → conversation y=0, height 20, width 80. chromeWidth
        // 5 → baseContentWidth 75, rail reserve 2 → contentWidth 73, rail
        // at cols 78-79 — the two columns upstream's
        // `timeline_x = scrollbar_x + 1 - RAIL_WIDTH` yields
        // (`views/agent.rs:369`; the rail's right edge lands on the
        // scrollbar column, which it replaces).
        let frame = makeFrame(conversation: twoTurnConversation(), showTimeline: true)
        guard let rail = frame.layout.timelineRail else {
            Issue.record("rail should paint")
            return
        }
        #expect(rail.rect == TerminalRect(x: 78, y: 0, width: 2, height: 20))
        #expect(!frame.layout.hasScrollbar)
        // 2 turns → 2 ticks + 2 chevrons = 4 rows centered in 20: top 8.
        #expect(rail.upY == 8)
        #expect(rail.ticksY == 9)
        #expect(rail.downY == 11)
        #expect(rail.window == 0..<2)
        // Follow-tail on an overflowing transcript whose short second turn
        // sits inside the last screenful: the active turn is the one owning
        // the TOP row — upstream's web-timeline rule, never a newest-turn
        // clamp (`active_turn_stays_top_anchored_at_the_bottom`,
        // scrollback/state/timeline.rs:202-228) — and ▼ still targets the
        // trailing turn below the top.
        #expect(rail.active == 0)
        #expect(rail.downTarget == 1)
        // The scrollbar's glyphs are gone from the gutter; the chevrons and
        // ticks are painted in the rail cells (chevron in the rightmost
        // cell, views/timeline.rs:238).
        #expect(frame.buffer.cell(x: 79, y: rail.upY)?.grapheme == PagerGlyphs.timelineChevronUp)
        #expect(frame.buffer.cell(x: 79, y: rail.downY)?.grapheme == PagerGlyphs.timelineChevronDown)
        let snapshot = frame.snapshot()
        #expect(!snapshot.contains("█"))
    }

    @Test("tick styling: the active turn is heavy and bright, the rest dim")
    func tickStyling() {
        let frame = makeFrame(
            conversation: twoTurnConversation(),
            showTimeline: true,
            scrollPosition: .offset(0)
        )
        guard let rail = frame.layout.timelineRail else {
            Issue.record("rail should paint")
            return
        }
        // At the top, pre-turn-free: turn 0's prompt owns row 0 → active 0.
        #expect(rail.active == 0)
        // Active tick "━━" in text_primary (views/timeline.rs:255-258).
        #expect(frame.buffer.cell(x: 78, y: rail.ticksY)?.grapheme == "\u{2501}")
        #expect(frame.buffer.cell(x: 79, y: rail.ticksY)?.grapheme == "\u{2501}")
        #expect(
            frame.buffer.cell(x: 79, y: rail.ticksY)?.foreground
                == PagerRenderTheme.grokNight.textPrimary
        )
        // Idle tick: light stroke in the rightmost cell only, gray_dim
        // (views/timeline.rs:262-264).
        #expect(frame.buffer.cell(x: 78, y: rail.ticksY + 1)?.grapheme == " ")
        #expect(frame.buffer.cell(x: 79, y: rail.ticksY + 1)?.grapheme == "\u{2500}")
        #expect(
            frame.buffer.cell(x: 79, y: rail.ticksY + 1)?.foreground
                == PagerRenderTheme.grokNight.grayDim
        )
        // At the top ▲ has nothing above → dim; ▼ has turn 1 below → gray
        // (chevron state derives from the same chevron_target the click
        // resolution uses, views/timeline.rs:220-223).
        #expect(
            frame.buffer.cell(x: 79, y: rail.upY)?.foreground
                == PagerRenderTheme.grokNight.grayDim
        )
        #expect(
            frame.buffer.cell(x: 79, y: rail.downY)?.foreground
                == PagerRenderTheme.grokNight.gray
        )
    }

    @Test("the flag off keeps the scrollbar and publishes no rail")
    func flagOffKeepsScrollbar() {
        let frame = makeFrame(conversation: twoTurnConversation(), showTimeline: false)
        #expect(frame.layout.timelineRail == nil)
        #expect(frame.layout.hasScrollbar)
        #expect(frame.snapshot().contains("█"))
        #expect(!frame.snapshot().contains(PagerGlyphs.timelineChevronUp))
    }

    @Test("the rail takes two columns out of the wrap width")
    func railNarrowsTheWrapWidth() {
        // The same transcript wraps to MORE lines with the rail reserved:
        // upstream re-lays-out the scrollback at
        // `layout.scrollback_content.width` after the rail carve-out
        // (`views/agent.rs:370-383`, content ends at `timeline_x - gap_left`).
        // 150 columns: 3 rows at the rail's 73-column wrap (73+73+4), 2 rows
        // at the rail-less 75 (75+75) — the reserve is observable as a line
        // count, not only as `contentWidth`.
        let long = [PagerConversationItem.message(PagerMessage(
            role: .assistant,
            text: String(repeating: "x", count: 150)
        ))] + twoTurnConversation(replyLines: 1)
        let withRail = makeFrame(conversation: long, showTimeline: true)
        let without = makeFrame(conversation: long, showTimeline: false, showScrollbar: false)
        #expect(withRail.layout.contentWidth == without.layout.contentWidth - 2)
        #expect(withRail.layout.totalContentLines > without.layout.totalContentLines)
    }

    @Test("eligibility gates: narrow terminal, one turn, scrollbar config off")
    func eligibilityGates() {
        // Narrower than MIN_TERMINAL_WIDTH (60) hides the rail
        // (views/timeline.rs:20-22).
        let narrow = makeFrame(width: 59, conversation: twoTurnConversation(), showTimeline: true)
        #expect(narrow.layout.timelineRail == nil)
        // One turn is noise (MIN_TURNS, views/timeline.rs:24-25) — the
        // scrollbar stays.
        let oneTurn = makeFrame(
            conversation: [
                .message(PagerMessage(role: .user, text: "only question")),
                .message(PagerMessage(
                    role: .assistant,
                    text: (0..<30).map { "reply \($0)" }.joined(separator: "\n")
                )),
            ],
            showTimeline: true
        )
        #expect(oneTurn.layout.timelineRail == nil)
        #expect(oneTurn.layout.hasScrollbar)
        // A disabled scrollbar config forces the rail off — it needs the
        // gutter's geometry (views/agent.rs:364-368).
        let noScrollbar = makeFrame(
            conversation: twoTurnConversation(),
            showTimeline: true,
            showScrollbar: false
        )
        #expect(noScrollbar.layout.timelineRail == nil)
    }

    @Test("a viewport too short for chevrons + one tick falls back to the scrollbar")
    func shortViewportFallsBack() {
        // Height 6: composer 3 + gap 1 → conversation height 2, below the
        // 2-chevrons-plus-one-tick floor (`compute_rail`'s None arm,
        // views/timeline.rs:119-123) — upstream recomputes the layout with
        // `timeline_width: 0` (agent_view/render.rs:1236-1268), so the
        // scrollbar and its 1-column carve-out come back.
        let frame = makeFrame(height: 6, conversation: twoTurnConversation(), showTimeline: true)
        #expect(frame.layout.timelineRail == nil)
        #expect(frame.layout.hasScrollbar)
    }

    @Test("the frame flag is deterministic and observable")
    func frameLevelFlag() {
        let on = makeFrame(conversation: twoTurnConversation(), showTimeline: true)
        let onAgain = makeFrame(conversation: twoTurnConversation(), showTimeline: true)
        let off = makeFrame(conversation: twoTurnConversation(), showTimeline: false)
        #expect(on == onAgain)
        #expect(on != off)
    }

    @Test("block start lines are recorded as painted — the rail's row source")
    func blockStartLinesMatchPaint() {
        // A user block paints pad, body, pad (3 rows) + 1 gap row → the
        // next block starts at line 4. The recorded starts are what
        // `pagerTimelineViewport` partitions, so they must be the painted
        // truth, not an estimate.
        let layout = makeConversationLayout(
            [
                .message(PagerMessage(role: .user, text: "alpha question")),
                .message(PagerMessage(role: .assistant, text: "one line")),
                .message(PagerMessage(role: .user, text: "beta question")),
            ],
            width: 40,
            theme: .grokNight
        )
        #expect(layout.blockStartLines == [0, 4, 6])
        #expect(layout.blockStartLines.count == 3)
        // The shared turn enumeration picks exactly the user blocks.
        #expect(pagerTimelineTurnBlockIndices([
            .message(PagerMessage(role: .user, text: "alpha question")),
            .message(PagerMessage(role: .assistant, text: "one line")),
            .message(PagerMessage(role: .user, text: "beta question")),
        ]) == [0, 2])
    }
}
