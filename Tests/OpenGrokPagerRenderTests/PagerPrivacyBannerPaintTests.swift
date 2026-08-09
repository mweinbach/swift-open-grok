// PagerPrivacyBannerPaintTests.swift
//
// The privacy banner's paint invariants (Wave 18 B9-c3), ported from the
// in-file suite of `views/privacy_banner.rs:297-435` at pin 650c1db7 —
// title never clipped, legal line whole from the widest-fitting variant,
// buttons whole or not at all, the 4-row body cap with `…`, and the
// exported height-for-width the slot owner sizes from. Then the frame
// builder's slot ownership, the render-layer half of the
// critical-outranks-privacy split: `agent_view/links.rs:573-658` pins that
// the render layer honors a `true` flag even over a live critical
// announcement, because the ranking lives with the PRODUCER
// (`app_view.rs:4859-4863` — the live composition's pass-through, pinned
// in `LivePrivacyBannerSurfaceTests`).

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

// MARK: - Draw helpers (upstream's `draw`, privacy_banner.rs:301-318)

/// Render at `width` into a buffer sized by the exported height, returning
/// the rows (trailing blanks trimmed) and the hit rects.
private func draw(width: Int) -> (rows: [String], rects: PagerPrivacyBannerHitRects) {
    let height = pagerPrivacyBannerHeight(width: width)
    let area = TerminalRect(x: 0, y: 0, width: width, height: height)
    var buffer = CellBuffer(area: area)
    let rects = renderPagerPrivacyBanner(in: area, buffer: &buffer, theme: .default)
    return (bufferRows(buffer, area: area), rects)
}

private func bufferRows(_ buffer: CellBuffer, area: TerminalRect) -> [String] {
    (area.top..<area.bottom).map { y in
        var row = ""
        for x in area.left..<area.right {
            guard let cell = buffer.cell(x: x, y: y), !cell.skip else { continue }
            row += cell.grapheme
        }
        while row.hasSuffix(" ") { row.removeLast() }
        return row
    }
}

/// The text a legal variant reassembles to (privacy_banner.rs:324-327).
private func legalText(_ variant: [PagerPrivacyBannerLegalSegment]) -> String {
    variant.map(\.text).joined()
}

/// The buffer text under `rect` on its row (privacy_banner.rs:329-336).
private func text(at rect: TerminalRect, in rows: [String]) -> String {
    let row = Array(rows[rect.y])
    return String(row[min(rect.x, row.count)..<min(rect.x + rect.width, row.count)])
}

@Suite("privacy banner paint invariants")
struct PagerPrivacyBannerPaintTests {
    /// Slot owners reserve `pagerPrivacyBannerHeight` rows, so the last one
    /// it promises must be the legal line — not a body row pushed off the
    /// end (privacy_banner.rs:338-362).
    @Test("height reserves every row the banner paints")
    func heightReservesEveryRowTheBannerPaints() {
        for width in [200, 117, 110, 100, 80, 72, 60, 45, 40, 36, 30, 24, 18] {
            let (rows, _) = draw(width: width)
            #expect(rows.count == pagerPrivacyBannerHeight(width: width))
            #expect(
                rows[0].hasPrefix(pagerPrivacyBannerTitleText(width: width)),
                "width \(width): title must never be clipped, got \(rows[0])"
            )
            let legal = rows.last ?? ""
            #expect(
                pagerPrivacyBannerLegalVariants.contains { legalText($0) == legal },
                "width \(width): legal line must survive whole, got \(legal)"
            )
            #expect(
                rows[1..<rows.count - 1].allSatisfy { !$0.isEmpty },
                "width \(width): body rows must not be blank: \(rows)"
            )
        }
    }

    /// The row cap's elision is a narrow-terminal fallback, not the norm
    /// (privacy_banner.rs:364-375).
    @Test("body copy is complete at common widths")
    func bodyCopyIsCompleteAtCommonWidths() {
        for width in [200, 117, 100, 80, 60] {
            let body = draw(width: width).rows.dropFirst().joined(separator: " ")
            let flattened = body.split(separator: " ").joined(separator: " ")
            #expect(
                flattened.contains(pagerPrivacyBannerDescription),
                "width \(width): body copy was truncated: \(flattened)"
            )
        }
    }

    /// The whole-or-not-at-all guard: a clipped `[Opt in]` must not leave
    /// a click target in the blank margin where a stray click would
    /// silently opt the user in (privacy_banner.rs:377-396 over :91-96).
    @Test("buttons drop whole when the row is too narrow")
    func buttonsDropWholeWhenTheRowIsTooNarrow() {
        // One column short of title + gap + both buttons.
        let width = pagerPrivacyBannerTitle.count
            + pagerPrivacyBannerOptOutLabel.count + 1 + pagerPrivacyBannerOptInLabel.count
        let (_, narrow) = draw(width: width)
        #expect(narrow.optIn == nil)
        #expect(narrow.optOut == nil)
        #expect(narrow.terms != nil, "terms link still clickable")
        #expect(narrow.policy != nil, "policy link still clickable")

        let (_, fits) = draw(width: width + 1)
        #expect(fits.optOut?.width == pagerPrivacyBannerOptOutLabel.count)
        #expect(fits.optIn?.width == pagerPrivacyBannerOptInLabel.count)
    }

    /// Below the minimum height nothing paints and nothing is clickable
    /// (privacy_banner.rs:398-411).
    @Test("slot below min height arms no hit rects")
    func slotBelowMinHeightArmsNoHitRects() {
        let area = TerminalRect(
            x: 0, y: 0, width: 100, height: pagerPrivacyBannerMinHeight - 1
        )
        var buffer = CellBuffer(
            area: TerminalRect(x: 0, y: 0, width: 100, height: pagerPrivacyBannerMinHeight)
        )
        let rects = renderPagerPrivacyBanner(in: area, buffer: &buffer, theme: .default)
        #expect(rects.optIn == nil)
        #expect(rects.optOut == nil)
        #expect(rects.terms == nil)
        #expect(rects.policy == nil)
    }

    /// The two links open different documents, so an off-by-one rect sends
    /// the user to the wrong page (privacy_banner.rs:413-434).
    @Test("each legal link hits its own words")
    func eachLegalLinkHitsItsOwnWords() throws {
        for width in [200, 117, 80, 60, 40, 30, 24, 18] {
            let (rows, rects) = draw(width: width)
            let terms = try #require(rects.terms, "width \(width): terms rect armed")
            let policy = try #require(rects.policy, "width \(width): policy rect armed")
            #expect(
                text(at: terms, in: rows) == "Terms",
                "width \(width): terms rect is off its word: \(rows)"
            )
            let policyText = text(at: policy, in: rows)
            #expect(
                policyText == "Privacy Policy" || policyText == "Privacy",
                "width \(width): policy rect is off its word, got \(policyText)"
            )
            #expect(
                terms.right <= policy.x,
                "width \(width): link rects must not overlap"
            )
        }
    }
}

// MARK: - Frame-builder slot ownership (agent_view/render.rs:888-892,
// :2128-2148; agent_view/links.rs:573-658)

private func frameState(
    privacyBanner: Bool,
    announcement: PagerAnnouncementBanner? = nil,
    size: TerminalSize = TerminalSize(width: 80, height: 30)
) -> PagerRenderState {
    PagerRenderState(
        size: size,
        statusBar: PagerStatusBar(workingDirectory: "/x"),
        announcementBanner: announcement,
        conversation: [],
        privacyBanner: privacyBanner
    )
}

@Suite("privacy banner slot ownership")
struct PagerPrivacyBannerSlotTests {
    /// The render-layer half of upstream's slot-ownership pin
    /// (links.rs:573-658): when the caller passes `privacy_banner: true`,
    /// the render layer gives it the slot (even over an announcement — the
    /// critical-outranks-privacy ranking lives with the producer, which
    /// never passes `true` while a critical announcement is live), arms
    /// its rects, and clearing the flag clears them.
    @Test("privacy banner owns the slot and publishes its rects")
    func privacyBannerOwnsSlotAndPublishesRects() throws {
        let critical = PagerAnnouncementBanner(
            severity: .critical, title: "ZZCRIT", message: "outage"
        )
        let owned = renderPagerFrame(frameState(privacyBanner: true, announcement: critical))
        let frame = owned.snapshot()
        #expect(frame.contains("Help improve Open Grok"), "banner copy painted")
        #expect(
            !frame.contains("ZZCRIT"),
            "the announcement yields the slot to the privacy banner"
        )
        let rects = try #require(owned.layout.privacyBanner)
        #expect(rects.optIn != nil)
        #expect(rects.optOut != nil)
        #expect(rects.terms != nil)
        #expect(rects.policy != nil)
        // The slot was sized from the exported height-for-width, not a
        // banner constant (render.rs:888-892).
        #expect(
            owned.layout.announcementBanner.height == pagerPrivacyBannerHeight(width: 80)
        )

        // Flag off: the announcement paints and no rect survives.
        let yielded = renderPagerFrame(frameState(privacyBanner: false, announcement: critical))
        #expect(yielded.snapshot().contains("ZZCRIT"))
        #expect(!yielded.snapshot().contains("Help improve Open Grok"))
        #expect(yielded.layout.privacyBanner == nil)
    }

    /// A terminal too short to grant the banner its minimum rows fails
    /// ownership: the announcement keeps the slot and no rect publishes
    /// (upstream's `privacy_banner_owns_slot` height arm,
    /// render.rs:2128-2132).
    @Test("a squeezed slot below minimum height publishes no rects")
    func squeezedSlotPublishesNoRects() {
        // 4 rows: status bar + composer floor consume the height budget
        // before the banner slot can reach its 3-row minimum.
        let result = renderPagerFrame(frameState(
            privacyBanner: true,
            size: TerminalSize(width: 80, height: 4)
        ))
        #expect(result.layout.privacyBanner == nil)
    }

    /// The gate's re-show window drives the flag through a fixed clock:
    /// the same acked state hides inside the window and paints past it
    /// (`privacy_banner_reshow_elapsed`, app_view.rs:1394-1407, consumed
    /// through the c1 gate the producer's pass-through reads).
    @Test("reshow window re-shows with a fixed clock")
    func reshowWindowReShowsWithAFixedClock() {
        var gate = PagerPrivacyBannerState(
            privacyNoticeRollout: true,
            privacyBannerReshowDays: 30,
            privacyBannerAcked: "2026-01-01T00:00:00Z",
            codingDataRetentionOptOut: true,
            authDone: true,
            trustDone: true
        )
        let inside = ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")!
        let past = ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z")!
        #expect(!gate.shouldShow(now: inside))
        #expect(gate.shouldShow(now: past))

        // And the flag lands on the frame: hidden inside the window,
        // painted past it — the composition passes exactly this decision.
        let hidden = renderPagerFrame(frameState(privacyBanner: gate.shouldShow(now: inside)))
        #expect(!hidden.snapshot().contains("Help improve Open Grok"))
        #expect(hidden.layout.privacyBanner == nil)
        let shown = renderPagerFrame(frameState(privacyBanner: gate.shouldShow(now: past)))
        #expect(shown.snapshot().contains("Help improve Open Grok"))
        #expect(shown.layout.privacyBanner != nil)

        // A cleared reshow window never re-shows an acked banner, however
        // stale the ack (app_view.rs:1395: `reshow_days` nil/0 = never).
        gate.privacyBannerReshowDays = nil
        #expect(!gate.shouldShow(now: past))
    }
}
