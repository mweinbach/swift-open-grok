// PagerDashboardPeekTests.swift
//
// Wave 18 B1-p: the dashboard peek's render-side contract — the ported
// tail-selection family from `views/dashboard/peek_tail.rs:195-463` and the
// two paint pins from `views/dashboard/peek.rs:1240-1343` at pin 650c1db7,
// plus the list-first sizing rules the named constants stand for
// (`views/dashboard/layout.rs`).
//
// RECORDED ABSENCE: upstream's `dense_tail_does_not_mutate_scrollback_viewport`
// (`peek_tail.rs:408-418`) has no port analog. It exists because upstream
// paints from a LEASED, mutable `ScrollbackState` and a stray
// `prepare_layout`/`enable_follow` there would dirty the attach path. This
// port paints from an immutable `[PagerConversationItem]` snapshot, so the
// mutation it guards against is unrepresentable — a simplification, not a
// gap.

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

private func user(_ text: String) -> PagerConversationItem {
    .message(PagerMessage(role: .user, text: text))
}

private func assistant(_ text: String) -> PagerConversationItem {
    .message(PagerMessage(role: .assistant, text: text))
}

private func bash(_ command: String) -> PagerConversationItem {
    .tool(PagerToolCard(name: "bash", input: command, state: .succeeded))
}

private func numberedLines(_ count: Int) -> [PaintLine] {
    (0..<count).map { PaintLine("L\($0)", foreground: .reset) }
}

private func tailText(
    _ items: [PagerConversationItem],
    width: Int,
    height: Int
) -> [String] {
    PagerDashboardPeekTail.lines(items: items, width: width, height: height).map(\.text)
}

private func bandRows(_ buffer: CellBuffer, area: TerminalRect) -> [String] {
    (area.y..<area.bottom).map { y in
        var row = ""
        for x in area.x..<area.right {
            guard let cell = buffer.cell(x: x, y: y), !cell.skip else { continue }
            row += cell.grapheme
        }
        return row
    }
}

@Suite("Dashboard peek tail")
struct PagerDashboardPeekTailTests {
    // peek_tail.rs:222-228
    @Test("a tail that fits paints no marker")
    func pureTailFitsWithoutMarker() {
        let (ellipsis, body) = PagerDashboardPeekTail.pureTailWithEllipsis(
            numberedLines(3), budget: 5
        )
        #expect(!ellipsis)
        #expect(body.count == 3)
    }

    // peek_tail.rs:230-238
    @Test("an overlong tail keeps the NEWEST rows and marks the omission")
    func pureTailTakesTailAndMarks() {
        let (ellipsis, body) = PagerDashboardPeekTail.pureTailWithEllipsis(
            numberedLines(10), budget: 4
        )
        #expect(ellipsis)
        #expect(body.count == 3, "one of the four rows goes to the marker")
        #expect(body.first?.text == "L7")
        #expect(body.last?.text == "L9")
    }

    // The budget==1 arm (`peek_tail.rs:123-126`): one row of `…` tells the
    // user nothing; one row of the newest line is the point of a live tail.
    @Test("a one-row budget drops the marker, not the content")
    func pureTailSingleRowKeepsContent() {
        let (ellipsis, body) = PagerDashboardPeekTail.pureTailWithEllipsis(
            numberedLines(10), budget: 1
        )
        #expect(!ellipsis)
        #expect(body.map(\.text) == ["L9"])
    }

    // peek_tail.rs:240-284
    @Test("the LATEST user prompt pins; the prior turn must not fill under it")
    func pinsLastUserAtTop() {
        let rows = tailText([
            user("first prompt"),
            assistant("old answer"),
            user("latest prompt"),
            bash("tool-a"),
            assistant("new answer"),
        ], width: 48, height: 8)

        #expect(rows.first?.contains("latest prompt") == true, "\(rows)")
        #expect(rows.first?.contains("first prompt") != true, "an older user must not pin")
        let joined = rows.joined(separator: "\n")
        #expect(
            joined.contains("new answer") || joined.contains("tool-a"),
            "current-turn body under the pin: \(joined)"
        )
        #expect(!joined.contains("old answer"), "prior-turn body must not fill under the pin")
        #expect(!joined.contains("first prompt"), "prior user must not appear under the pin")
    }

    // peek_tail.rs:286-318 — the rule that keeps a fresh send honest.
    @Test("after a fresh send the body is empty until the agent streams")
    func freshUserSendLeavesBodyEmpty() {
        let items = [
            user("old ask"),
            assistant("long prior answer with a table and status"),
            user("say hi to me and nothing else"),
        ]
        for height in [3, 8] {
            let rows = tailText(items, width: 48, height: height)
            #expect(rows.first?.contains("say hi to me") == true, "h=\(height): \(rows)")
            let body = rows.dropFirst().joined(separator: "\n")
            #expect(
                !body.contains("prior answer") && !body.contains("old ask")
                    && !body.contains("table"),
                "h=\(height): a fresh send must not re-show the prior turn: \(body)"
            )
            let bodyIsBlank = body.allSatisfy(\.isWhitespace)
            #expect(bodyIsBlank, "h=\(height): body under the pin stays empty: \(body)")
        }
    }

    // peek_tail.rs:320-350
    @Test("a truncated body wears a top ellipsis and keeps the newest rows")
    func showsTopEllipsisWhenTruncated() {
        var items: [PagerConversationItem] = [user("ask")]
        for index in 0..<20 { items.append(bash("cmd-\(index)")) }

        let rows = tailText(items, width: 40, height: 6)
        #expect(rows.first?.contains("ask") == true, "the user pin comes first: \(rows)")
        #expect(
            rows.count > 1 && rows[1].contains(PagerGlyphs.ellipsis),
            "the omission marker sits under the pin: \(rows)"
        )
        let joined = rows.joined(separator: "\n")
        #expect(joined.contains("cmd-19"), "a pure tail keeps the latest: \(joined)")
        #expect(!joined.contains("cmd-0"), "the oldest is dropped under the ellipsis: \(joined)")
    }

    // peek_tail.rs:352-383 — the list-first min box leaves ~3 middle rows.
    @Test("a 3-row middle still shows the current turn under the pin")
    func minBoxMiddleIsCurrentTurnWithPin() {
        var items: [PagerConversationItem] = [
            user("old"),
            assistant("prior turn bulk answer"),
            user("ask"),
        ]
        for index in 0..<12 { items.append(bash("cmd-\(index)")) }

        let rows = tailText(items, width: 40, height: 3)
        let joined = rows.joined(separator: "\n")
        #expect(rows.first?.contains("ask") == true, "pin on the min-box middle: \(rows)")
        #expect(
            !joined.contains("prior turn") && !joined.contains("old"),
            "the prior turn must not fill a min-box middle: \(joined)"
        )
        #expect(joined.contains("cmd-11"), "current-turn pure tail on a min-box middle: \(joined)")
    }

    // peek_tail.rs:385-406
    @Test("one long message tails to its END, not its head")
    func pureTailKeepsMessageEnd() {
        let body = (0..<20)
            .map { String(format: "LINE%02d-", $0) + String(repeating: "x", count: 36) }
            .joined(separator: "\n\n")
        let joined = tailText([assistant(body)], width: 40, height: 4).joined(separator: "\n")
        #expect(
            joined.contains("LINE19") || joined.contains("LINE18"),
            "a pure tail keeps the end: \(joined)"
        )
        #expect(
            joined.contains(PagerGlyphs.ellipsis) || !joined.contains("LINE00"),
            "the head is omitted, marked or absent: \(joined)"
        )
    }

    // peek_tail.rs:420-427
    @Test("an empty transcript paints nothing")
    func emptyTranscriptIsNoop() {
        #expect(PagerDashboardPeekTail.lines(items: [], width: 40, height: 4).isEmpty)

        let area = TerminalRect(x: 0, y: 0, width: 40, height: 5)
        var buffer = CellBuffer(area: area)
        drawDashboardPeekBand(
            PagerDashboardPeek(statusLabel: "Idle"),
            in: area,
            buffer: &buffer,
            theme: .default
        )
        let rows = bandRows(buffer, area: area)
        // Row 0 is the band rule, row 1 the status; the middle carries the
        // hint instead of a tail (`peek.rs:812-821`).
        #expect(rows[2].contains(PagerDashboardPeekTail.defaultEmptyHint))
    }

    // peek_tail.rs:429-463
    @Test("the densified body count is current-turn only")
    func densifiedBodyCountIsCurrentTurnOnly() {
        let current = [user("ask"), bash("one"), bash("two")]
        let currentCount = PagerDashboardPeekTail.densifiedBodyLineCount(
            items: current, width: 40
        )
        #expect(currentCount >= 2, "current-turn tools contribute: \(currentCount)")

        let withPrior = [
            user("old"),
            assistant("prior turn bulk that is many lines of text"),
            user("ask"),
            bash("one"),
            bash("two"),
        ]
        #expect(
            PagerDashboardPeekTail.densifiedBodyLineCount(items: withPrior, width: 40)
                == currentCount,
            "a prior turn must not inflate the densified body count"
        )
        #expect(
            PagerDashboardPeekTail.densifiedBodyLineCount(items: [user("only")], width: 40) == 0,
            "a user-only transcript has no body"
        )
        #expect(PagerDashboardPeekTail.hasLastUser(items: current))
        #expect(!PagerDashboardPeekTail.hasLastUser(items: [assistant("no user yet")]))
    }
}

@Suite("Dashboard peek sizing")
struct PagerDashboardPeekSizingTests {
    // peek.rs:1240-1249
    @Test("the breathing blank is given back when only one middle row remains")
    func liveTailMiddleBottomTable() {
        // status@0, middle from 1, content ending at 3 → span 2. A blank
        // would leave a pin-only middle, so it is skipped.
        #expect(PagerDashboardPeekTail.liveTailMiddleBottom(middleTop: 1, replyTopY: 3) == 3)
        // A generous middle (span 4) keeps the blank.
        #expect(PagerDashboardPeekTail.liveTailMiddleBottom(middleTop: 1, replyTopY: 5) == 4)
        // A zero middle span stays empty.
        #expect(PagerDashboardPeekTail.liveTailMiddleBottom(middleTop: 3, replyTopY: 3) == 2)
    }

    // layout.rs:120-167 — the refusal is the list-first policy's teeth.
    @Test("a band below the min box is refused outright, not painted as a sliver")
    func allocateRefusesBelowMinBox() {
        // 12 list-floor rows + a remainder under PEEK_MIN_BOX_LIVE_TAIL.
        let cramped = PagerDashboardPeekTail.allocate(
            areaHeight: 18, fixedOverhead: 0, desiredContentRows: 20
        )
        #expect(!cramped.showPeek)
        #expect(cramped.peekBoxHeight == 0)

        let roomy = PagerDashboardPeekTail.allocate(
            areaHeight: 40, fixedOverhead: 0, desiredContentRows: 20
        )
        #expect(roomy.showPeek)
        #expect(
            roomy.peekBoxHeight <= PagerDashboardPeekTail.peekMaxBoxRows(40),
            "the band never exceeds the 3/8 cap"
        )
        #expect(
            40 - roomy.peekBoxHeight >= PagerDashboardPeekTail.listFloorRows,
            "the list floor is reserved FIRST"
        )
    }

    // layout.rs:57-108 — the measure the paint has to agree with.
    @Test("desired content shrinks to fit, and an empty body still reserves a hint row")
    func desiredContentRows() {
        // layout.rs:1005-1011 minus the deferred reply row: status + blank +
        // hint. The hint row is why an idle peek never collapses to a bare
        // status line that reads as a rendering failure.
        let empty = PagerDashboardPeekTail.desiredContentRows(
            maxContent: 20, replyRows: 0, bodyMeasured: 0, pinUser: false
        )
        #expect(empty.liveTail == 1, "an empty body still budgets the hint row")
        #expect(empty.blankRow)
        #expect(empty.contentRows == 3, "status + blank + hint")

        // layout.rs:1021-1033 minus the reply row.
        let pinned = PagerDashboardPeekTail.desiredContentRows(
            maxContent: 20, replyRows: 0, bodyMeasured: 2, pinUser: true
        )
        #expect(pinned.liveTail == 2)
        #expect(pinned.blankRow)
        #expect(pinned.contentRows == 5, "status + pin + blank + 2 body")

        // Never past MAX_LIVE_TAIL_ROWS (layout.rs:27, test :1035-1041).
        let flooded = PagerDashboardPeekTail.desiredContentRows(
            maxContent: 80, replyRows: 0, bodyMeasured: 200, pinUser: false
        )
        #expect(flooded.liveTail == PagerDashboardPeekTail.maxLiveTailRows)
        #expect(flooded.contentRows == 1 + 1 + PagerDashboardPeekTail.maxLiveTailRows)

        // Tight: no room for a blank, and the body keeps its row.
        let tight = PagerDashboardPeekTail.desiredContentRows(
            maxContent: 3, replyRows: 0, bodyMeasured: 4, pinUser: true
        )
        #expect(!tight.blankRow)
        #expect(tight.liveTail == 1)
        #expect(tight.contentRows == 3, "status + pin + body")
    }

    /// The reply row is DEFERRED, not deleted (B1 ruling §5.1): `replyRows`
    /// survives as a parameter so wiring it back is a call-site change. This
    /// reproduces upstream's `peek_live_tail_desired_tight_pin_skips_blank`
    /// (layout.rs:1013-1020) verbatim, proving the arm still works.
    @Test("a non-zero reply budget still measures the way upstream does")
    func desiredContentRowsWithReplyBudget() {
        let tight = PagerDashboardPeekTail.desiredContentRows(
            maxContent: 6, replyRows: 3, bodyMeasured: 1, pinUser: true
        )
        #expect(!tight.blankRow)
        #expect(tight.liveTail == 1)
        #expect(tight.contentRows == 1 + 3 + 1 + 1, "status + reply + pin + body")
    }

    // layout.rs:1058-1073 — the invariant that keeps the band inside its
    // allocation no matter what the tail measured.
    @Test("desired content never exceeds the max, and never over-taps the tail cap")
    func desiredContentNeverExceedsMax() {
        for maxContent in 0...40 {
            for replyRows in 0...6 {
                for bodyMeasured in [0, 1, 3, 10, 50, 200] {
                    for pinUser in [false, true] {
                        let budget = PagerDashboardPeekTail.desiredContentRows(
                            maxContent: maxContent,
                            replyRows: replyRows,
                            bodyMeasured: bodyMeasured,
                            pinUser: pinUser
                        )
                        #expect(
                            budget.contentRows <= maxContent,
                            "\(budget.contentRows) > \(maxContent) reply=\(replyRows) body=\(bodyMeasured) pin=\(pinUser)"
                        )
                        #expect(budget.liveTail <= PagerDashboardPeekTail.maxLiveTailRows)
                    }
                }
            }
        }
    }
}

@Suite("Dashboard peek band paint")
struct PagerDashboardPeekBandTests {
    // peek.rs:1253-1298 — the paint must not steal the body row for a blank.
    @Test("a tight band still shows the current-turn body under the pin")
    func tightPinShowsCurrentTurnBody() {
        // 2 chrome rows + 3 content rows (status + pin + body).
        let area = TerminalRect(x: 0, y: 0, width: 80, height: 5)
        var buffer = CellBuffer(area: area)
        drawDashboardPeekBand(
            PagerDashboardPeek(
                statusLabel: "Response",
                items: [user("user pin"), assistant("current turn line")]
            ),
            in: area,
            buffer: &buffer,
            theme: .default
        )
        let content = bandRows(buffer, area: area).joined(separator: "\n")
        #expect(content.contains("user pin"), "the pin must paint: \(content)")
        #expect(
            content.contains("current turn line"),
            "the body must not be eaten by a breathing blank: \(content)"
        )
    }

    // peek.rs:1302-1343 — `Working` is the one label that means "still
    // going", so it alone gets the secondary colour; the rest stay dim
    // chrome so the tail below reads brightest.
    @Test("Working paints secondary, other statuses stay dim chrome")
    func workingStatusUsesSecondaryColour() {
        let theme = PagerRenderTheme.default
        func render(_ label: String) -> CellBuffer {
            let area = TerminalRect(x: 0, y: 0, width: 80, height: 5)
            var buffer = CellBuffer(area: area)
            drawDashboardPeekBand(
                PagerDashboardPeek(statusLabel: label),
                in: area,
                buffer: &buffer,
                theme: theme
            )
            return buffer
        }

        let working = render("Working")
        #expect(working.cell(x: 0, y: 1)?.grapheme == "W", "the status label is `Working`")
        #expect(working.cell(x: 0, y: 1)?.foreground == theme.textSecondary)

        let response = render("Response")
        #expect(response.cell(x: 0, y: 1)?.grapheme == "R", "the status label is `Response`")
        #expect(response.cell(x: 0, y: 1)?.foreground == theme.grayDim)
    }

    // peek.rs:762-795 — the label wins when the band is too narrow for both.
    @Test("time-ago paints right, and is dropped before the label truncates away")
    func timeAgoRightAlignedThenDropped() {
        let wide = TerminalRect(x: 0, y: 0, width: 40, height: 5)
        var buffer = CellBuffer(area: wide)
        drawDashboardPeekBand(
            PagerDashboardPeek(statusLabel: "Thinking", timeAgo: "2m10s"),
            in: wide,
            buffer: &buffer,
            theme: .default
        )
        let status = bandRows(buffer, area: wide)[1]
        #expect(status.hasPrefix("Thinking"))
        #expect(status.hasSuffix("2m10s"), "the time column is right-aligned: \(status)")

        // 20 columns is the narrowest band that paints at all
        // (`peek.rs:577-579`); a time wider than the label's share is
        // dropped so the status word survives.
        let narrow = TerminalRect(x: 0, y: 0, width: 20, height: 5)
        var narrowBuffer = CellBuffer(area: narrow)
        drawDashboardPeekBand(
            PagerDashboardPeek(
                statusLabel: "Thinking",
                timeAgo: String(repeating: "9", count: 20)
            ),
            in: narrow,
            buffer: &narrowBuffer,
            theme: .default
        )
        let narrowStatus = bandRows(narrowBuffer, area: narrow)[1]
        #expect(narrowStatus.hasPrefix("Thinking"), "the label wins: \(narrowStatus)")
        #expect(!narrowStatus.contains("9"), "the time is dropped whole: \(narrowStatus)")
    }

    // peek.rs:577-579 — a band too small for a status AND a line of content
    // is worse than none.
    @Test("a degenerate band paints nothing at all")
    func degenerateBandPaintsNothing() {
        for area in [
            TerminalRect(x: 0, y: 0, width: 40, height: 2),
            TerminalRect(x: 0, y: 0, width: 19, height: 6),
        ] {
            var buffer = CellBuffer(area: area)
            let before = buffer
            drawDashboardPeekBand(
                PagerDashboardPeek(statusLabel: "Working", items: [user("hi")]),
                in: area,
                buffer: &buffer,
                theme: .default
            )
            #expect(buffer == before, "nothing painted for \(area)")
        }
    }
}
