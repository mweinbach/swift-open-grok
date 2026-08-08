// PagerTimestampsRenderTests.swift
//
// `[ui] show_timestamps` at the paint seam: `renderPagerFrame` /
// `makeConversationLines` are what the live composition's every repaint
// calls, so assertions here are assertions about the running TUI's frames
// (AGENTS.md §3). Every instant is injected — no test here reads the wall
// clock; `pagerFormatTimestamp` output is pinned against dates built from
// local-calendar components, which formats identically in every timezone.
// The live pass-through — config → user value → frame flag — plus the
// resume-path instants are pinned in
// `Tests/OpenGrokCLITests/LiveTimestampsTests.swift`.

import Foundation
import Testing
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

/// A wall-clock instant built from local-calendar components, so the
/// local-time formatter reproduces exactly these digits on any machine.
private func fixedDate(hour: Int, minute: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 8
    components.hour = hour
    components.minute = minute
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    guard let date = calendar.date(from: components) else {
        Issue.record("calendar could not resolve \(hour):\(minute)")
        return Date(timeIntervalSince1970: 0)
    }
    return date
}

@Suite("Timestamp format")
struct PagerTimestampFormatTests {
    @Test("the short format is upstream's '  %-I:%M %p' byte for byte")
    func shortFormat() {
        // `entry_renderer.rs:952`: two leading spaces, 12-hour clock with no
        // leading zero, AM/PM. "  12:30 PM" is also the 10-column maximum the
        // reserve is sized to (entry_renderer.rs:388-391).
        #expect(pagerFormatTimestamp(fixedDate(hour: 12, minute: 30)) == "  12:30 PM")
        #expect(pagerFormatTimestamp(fixedDate(hour: 15, minute: 7)) == "  3:07 PM")
        #expect(pagerFormatTimestamp(fixedDate(hour: 1, minute: 5)) == "  1:05 AM")
        #expect(pagerFormatTimestamp(fixedDate(hour: 0, minute: 0)) == "  12:00 AM")
    }
}

@Suite("Timestamps paint")
struct PagerTimestampsRenderTests {
    private let stamp = fixedDate(hour: 12, minute: 30)

    @Test("the stamp lands right-aligned on the user prompt's first content row")
    func userPromptStamp() {
        let lines = makeConversationLines(
            [.message(PagerMessage(role: .user, text: "hello", createdAt: stamp))],
            width: 40,
            theme: .grokNight,
            showTimestamps: true
        )
        // Block shape unchanged: pad row, body, pad row (`blocks/user.rs`).
        #expect(lines.count == 3)
        #expect(lines[0].text.isEmpty)
        // First CONTENT row (the row after the top pad,
        // `entry_renderer.rs:941-942`), right-aligned to the content edge
        // (`ts_x = content_area.x + content_area.width - ts_width`,
        // entry_renderer.rs:957): prefix+body (7) + pad (23) + stamp (10).
        #expect(lines[1].text == "\u{276F} hello" + String(repeating: " ", count: 23) + "  12:30 PM")
        // Stamp color is `theme.gray` (entry_renderer.rs:958), and the
        // prompt's `bg_light` band survives under it (the gutter fill,
        // entry_renderer.rs:923-926).
        #expect(lines[1].spans.last?.foreground == PagerRenderTheme.grokNight.gray)
        #expect(lines[1].background == PagerRenderTheme.grokNight.bgLight)
        #expect(lines[2].text.isEmpty)
    }

    @Test("the stamp lands on the assistant's first line only")
    func assistantStamp() {
        let lines = makeConversationLines(
            [.message(PagerMessage(
                role: .assistant,
                text: "Hi there.\nSecond line.",
                createdAt: stamp
            ))],
            width: 40,
            theme: .grokNight,
            showTimestamps: true
        )
        #expect(lines.count == 2)
        #expect(lines[0].text == "Hi there." + String(repeating: " ", count: 21) + "  12:30 PM")
        #expect(lines[0].spans.last?.foreground == PagerRenderTheme.grokNight.gray)
        #expect(lines[1].text == "Second line.")
    }

    @Test("flag off paints no stamp and reserves nothing")
    func offPaintsNothing() {
        let lines = makeConversationLines(
            [
                .message(PagerMessage(role: .user, text: "hello", createdAt: stamp)),
                .message(PagerMessage(role: .assistant, text: "Hi.", createdAt: stamp)),
            ],
            width: 40,
            theme: .grokNight
        )
        #expect(!lines.contains { $0.text.contains("12:30") })
    }

    @Test("a nil instant paints nothing but the reserve still narrows the wrap")
    func nilInstantReservesWithoutStamp() {
        // `timestamp_reserved()` ignores `created_at`
        // (entry_renderer.rs:1548-1550): the column is reserved by the flag
        // and the role alone, so one stampless block does not re-wrap
        // differently from its stamped neighbors. The overlay's own gate is
        // `let Some(ts)` (entry_renderer.rs:939) — no instant, no paint.
        let text = String(repeating: "x", count: 60)
        let reserved = makeConversationLines(
            [.message(PagerMessage(role: .user, text: text))],
            width: 40,
            theme: .grokNight,
            showTimestamps: true
        )
        let full = makeConversationLines(
            [.message(PagerMessage(role: .user, text: text))],
            width: 40,
            theme: .grokNight
        )
        // On: body wraps at 40 − 2 (prefix) − 10 (reserve) = 28 → 3 rows.
        // Off: wraps at 38 → 2 rows. Both keep the two padding rows.
        #expect(reserved.count == 5)
        #expect(full.count == 4)
        #expect(!reserved.contains { $0.text.contains("12:30") })
    }

    @Test("system, error, and reasoning blocks are never stamped")
    func roleGate() {
        // `should_show_timestamp` (entry_renderer.rs:376-382): user and agent
        // messages only. An instant on an unstamped role paints nothing.
        for role in [PagerMessageRole.system, .error, .reasoning] {
            let lines = makeConversationLines(
                [.message(PagerMessage(role: role, text: "note text", createdAt: stamp))],
                width: 40,
                theme: .grokNight,
                showTimestamps: true
            )
            #expect(!lines.contains { $0.text.contains("12:30") })
        }
    }

    @Test("too-narrow content skips the stamp — upstream's width > ts_width + 1 gate")
    func narrowWidthSkips() {
        func firstLine(width: Int) -> String {
            makeConversationLines(
                [.message(PagerMessage(role: .assistant, text: "", createdAt: stamp))],
                width: width,
                theme: .grokNight,
                showTimestamps: true
            ).first?.text ?? ""
        }
        // "  12:30 PM" is 10 wide; `content_area.width > ts_width + 1`
        // (entry_renderer.rs:956) admits 12 and refuses 11.
        #expect(!firstLine(width: 11).contains("12:30"))
        #expect(firstLine(width: 12).contains("12:30"))
    }

    @Test("compact mode keeps the stamp on the unpadded, unprefixed first row")
    func compactInteraction() {
        // Compact removes the prompt's padding and prefix, not its stamp —
        // upstream's reserve and overlay read only `show_timestamps` and the
        // block kind, never `prompt.compact`.
        let lines = makeConversationLines(
            [.message(PagerMessage(role: .user, text: "hello", createdAt: stamp))],
            width: 40,
            theme: .grokNight,
            compact: true,
            showTimestamps: true
        )
        #expect(lines.count == 1)
        #expect(lines[0].text == "hello" + String(repeating: " ", count: 25) + "  12:30 PM")
        #expect(lines[0].background == PagerRenderTheme.grokNight.bgLight)
    }

    @Test("the flag reaches the full frame through PagerRenderState")
    func frameLevelFlag() {
        func frame(showTimestamps: Bool) -> PagerRenderResult {
            renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 40, height: 24),
                conversation: [
                    .message(PagerMessage(role: .user, text: "hello", createdAt: stamp))
                ],
                input: PagerComposerState(text: ""),
                showScrollbar: false,
                showTimestamps: showTimestamps
            ))
        }
        #expect(frame(showTimestamps: true) == frame(showTimestamps: true))
        #expect(frame(showTimestamps: true) != frame(showTimestamps: false))
    }
}
