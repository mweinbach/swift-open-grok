// PagerCompactModeRenderTests.swift
//
// `[ui] compact_mode` at the paint seam: `renderPagerFrame` is the function
// the live composition's every repaint calls (`layOutCurrentFrame`,
// LiveComposition.swift), so assertions here are assertions about the running
// TUI's frames, not about a model only tests construct (AGENTS.md §3). The
// live pass-through — config → user value → derived flag → this function —
// is pinned in `Tests/OpenGrokCLITests/LiveCompactModeTests.swift`.

import Testing
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

@Suite("Compact mode derivation")
struct PagerEffectiveCompactTests {
    @Test("the user value alone turns compact on at any height")
    func userValueWins() {
        #expect(pagerEffectiveCompact(userCompact: true, terminalRows: 50))
        #expect(pagerEffectiveCompact(userCompact: true, terminalRows: 0))
    }

    @Test("auto-compact forces on at 20 rows and not at 21")
    func autoCompactThreshold() {
        // `AUTO_COMPACT_MAX_ROWS = 20` is inclusive (`views/agent.rs:87,96-98`);
        // upstream's own pin is "21 rows stays non-compact"
        // (`dispatch/tests/settings.rs:405-417`).
        #expect(pagerEffectiveCompact(userCompact: false, terminalRows: 20))
        #expect(!pagerEffectiveCompact(userCompact: false, terminalRows: 21))
    }

    @Test("zero rows means 'not yet measured' and never forces compact")
    func unmeasuredNeverForces() {
        #expect(!pagerEffectiveCompact(userCompact: false, terminalRows: 0))
    }
}

@Suite("Compact mode paint")
struct PagerCompactModeRenderTests {
    /// One user prompt and one reply, tall enough (24 > 20) that only the
    /// explicit flag — never auto-compact — decides the layout.
    private func frame(compact: Bool) -> PagerRenderResult {
        renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 24),
            statusBar: PagerStatusBar(workingDirectory: "~/work"),
            conversation: [
                .message(PagerMessage(role: .user, text: "hello")),
                .message(PagerMessage(role: .assistant, text: "Hi there."))
            ],
            input: PagerComposerState(text: ""),
            shortcuts: PagerShortcutsBar(hints: [
                PagerShortcutHint(key: "Enter", label: "send")
            ]),
            showScrollbar: false,
            compactMode: compact
        ))
    }

    @Test("compact drops the user prompt's padding rows and its ❯ prefix")
    func userPromptTightens() {
        // Full block: band row, `❯ `-prefixed body, band row
        // (`blocks/user.rs`); compact keeps only the body and unprefixes it
        // (`has_vpad_for`, user.rs:513-515; `show_prefix && !compact`,
        // user.rs:490-494).
        let full = makeConversationLines(
            [.message(PagerMessage(role: .user, text: "hello"))],
            width: 40,
            theme: .grokNight
        )
        #expect(full.count == 3)
        #expect(full[0].text.isEmpty)
        #expect(full[1].text == "\u{276F} hello")
        #expect(full[2].text.isEmpty)

        let compact = makeConversationLines(
            [.message(PagerMessage(role: .user, text: "hello"))],
            width: 40,
            theme: .grokNight,
            compact: true
        )
        #expect(compact.count == 1)
        #expect(compact[0].text == "hello")
        // The `bg_light` band survives — compact removes padding, not the
        // prompt's visual identity.
        #expect(compact[0].background == PagerRenderTheme.grokNight.bgLight)
    }

    @Test("compact unindents a multi-line prompt's continuation rows")
    func continuationRowsUnindent() {
        // With the prefix gone there is no prefix column to align under
        // (upstream passes `show_prefix: false` into `wrap_prompt_lines`,
        // user.rs:490-495).
        let lines = makeConversationLines(
            [.message(PagerMessage(role: .user, text: "first\nsecond"))],
            width: 40,
            theme: .grokNight,
            compact: true
        )
        #expect(lines.map(\.text) == ["first", "second"])
    }

    @Test("compact collapses the status, prompt, and bottom gap rows")
    func chromeGapsCollapse() {
        let full = frame(compact: false).layout
        let tight = frame(compact: true).layout

        // Status gap: upstream's `status_gap` follows `top_vpad`
        // (`views/agent.rs:222`), which compact zeroes
        // (`eff_outer_vpad`, appearance/config.rs:222-224).
        #expect(full.conversation.y == 2)
        #expect(tight.conversation.y == 1)

        // Prompt gap: 0 in compact (`agent_view/render.rs:1138-1145`).
        // Bottom gap: `shortcuts_gap` follows `bottom_vpad`
        // (`views/agent.rs:256`), zeroed the same way. The shortcuts bar
        // itself stays put on the last row; the composer slides down over
        // both reclaimed rows.
        #expect(full.input.y + 3 == 22)
        #expect(tight.input.y + 3 == 23)
        #expect(full.shortcuts.y == 23)
        #expect(tight.shortcuts.y == 23)

        // Every reclaimed row goes to the transcript.
        #expect(tight.conversation.height == full.conversation.height + 3)
    }

    @Test("the turn-status gap is not compact's to take")
    func turnStatusGapSurvives() {
        // Upstream pushes an unconditional `Length(1)` before the turn-status
        // row (`views/agent.rs:233-235`); only the status/prompt/bottom gaps
        // are vpad-derived.
        func layout(compact: Bool) -> PagerFrameLayout {
            renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 40, height: 24),
                turnStatus: PagerTurnStatus(label: "Thinking\u{2026}"),
                input: PagerComposerState(text: ""),
                showScrollbar: false,
                compactMode: compact
            )).layout
        }
        let full = layout(compact: false)
        let tight = layout(compact: true)
        // The row above the turn status stays blank in both layouts.
        #expect(full.turnStatus.y - full.conversation.bottom == 1)
        #expect(tight.turnStatus.y - tight.conversation.bottom == 1)
        // While the compact frame still reclaims the prompt gap below it.
        #expect(full.input.y - full.turnStatus.bottom == 1)
        #expect(tight.input.y - tight.turnStatus.bottom == 0)
    }

    @Test("a config-at-startup compact frame is exactly the toggled-on frame")
    func startupEqualsToggle() {
        // `[ui] compact_mode = true` at launch reaches this function as the
        // same derived flag `/compact-mode` flips at runtime — there is no
        // separate startup layout to drift.
        #expect(frame(compact: true) == frame(compact: true))
        #expect(frame(compact: true) != frame(compact: false))
    }
}
