// PagerWelcomeAnnouncementPaintTests.swift
//
// B2-W3 render-level pins: the welcome hero info slot's announcement arm,
// the announcement-over-changelog arbitration, the shared CTA button
// painter's whole-or-not rules, and the chrome-banner suppression while the
// welcome takeover owns the screen.
//
// Upstream reference at pin 650c1db7: the slot arbitration ("the
// announcement takes priority over the changelog",
// `views/welcome/hero_box.rs:349-378`; sizing `:96-129`), the shared CTA
// painter (`render_cta_button`, `views/announcements.rs:71-118` — "the ONE
// painter every surface shares"), and the welcome/agent draw-arm
// exclusivity that means only the agent view paints the session banner
// (`app/app_view.rs:4914` vs `:5158`, banner sizing `:5221-5241`).

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

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

private func promoBanner(
    message: String = "A promo announcement for the hero slot",
    ctaLabel: String? = "Upgrade now",
    ctaURL: String? = "https://x.ai/upgrade"
) -> PagerAnnouncementBanner {
    PagerAnnouncementBanner(
        severity: .promo,
        title: nil,
        message: message,
        dismissible: true,
        ctaLabel: ctaLabel,
        ctaURL: ctaURL,
        ctaCaption: nil
    )
}

private func frameState(
    size: TerminalSize = TerminalSize(width: 110, height: 34),
    banner: PagerAnnouncementBanner?,
    welcome: PagerWelcomeOverlay?
) -> PagerRenderState {
    var overlays = PagerOverlayStack()
    if let welcome {
        overlays.push(.welcome(welcome, capturesInput: false))
    }
    var state = PagerRenderState(
        size: size,
        conversation: [],
        theme: .default,
        overlays: overlays
    )
    state.announcementBanner = banner
    return state
}

@Suite("welcome announcement paint")
struct PagerWelcomeAnnouncementPaintTests {
    // MARK: Chrome-banner suppression (the load-bearing W3 gate)

    @Test("the chrome banner neither paints nor arms links while the welcome owns the screen")
    func chromeBannerSuppressedUnderWelcome() {
        let banner = promoBanner()

        // Without the welcome: the chrome banner paints its promo row and
        // arms the CTA's OSC 8 link span.
        let bare = renderPagerFrame(frameState(banner: banner, welcome: nil))
        #expect(bare.links.contains { $0.url == "https://x.ai/upgrade" })
        let bareText = bufferRows(bare.buffer, area: TerminalRect(
            x: 0, y: 0, width: 110, height: 34
        )).joined()
        #expect(bareText.contains("[Upgrade now]"))

        // With the welcome up: the same slot selection shows in the HERO
        // instead (app_view.rs:4937-4964); the chrome arm must not leave an
        // armed link span over cells the full-screen welcome overpaints —
        // a click target for a banner that is not on screen.
        let covered = renderPagerFrame(frameState(
            banner: banner,
            welcome: PagerWelcomeOverlay(announcement: banner)
        ))
        // The hero paints its own [Upgrade now]; the CHROME link span is the
        // thing that must be gone. The hero's CTA rides the overlay rows
        // channel, never `links`, so any armed link here is the chrome's.
        #expect(!covered.links.contains { $0.url == "https://x.ai/upgrade" })
    }

    // MARK: Arbitration

    @Test("an announcement suppresses the changelog arm entirely — never both")
    func announcementSuppressesChangelog() {
        let welcome = PagerWelcomeOverlay(
            menu: [PagerWelcomeMenuItem(id: "quit", key: "ctrl+q", label: "Quit")],
            changelogBullets: ["Arbitration bullet must not paint"],
            changelogHasFullNotes: true,
            announcement: promoBanner(message: "Arbitration announcement paints")
        )
        let result = renderPagerFrame(frameState(banner: nil, welcome: welcome))
        let text = bufferRows(result.buffer, area: TerminalRect(
            x: 0, y: 0, width: 110, height: 34
        )).joined()
        #expect(text.contains("Arbitration announcement paints"))
        #expect(!text.contains("Arbitration bullet must not paint"))
        #expect(!text.contains("Changelog"), "the changelog header never paints beside an announcement")

        // The announcement owns the published rects too: no changelog CTA.
        let rows = result.overlays.last?.rows.map(\.id) ?? []
        #expect(!rows.contains(PagerWelcomeOverlay.changelogCTARowID))
        #expect(rows.contains(PagerWelcomeOverlay.announcementCTARowID))
    }

    @Test("no announcement leaves the W2 changelog arm untouched")
    func absentAnnouncementFallsToChangelog() {
        let welcome = PagerWelcomeOverlay(
            menu: [PagerWelcomeMenuItem(id: "quit", key: "ctrl+q", label: "Quit")],
            changelogBullets: ["Fallback bullet paints"],
            changelogHasFullNotes: true
        )
        let result = renderPagerFrame(frameState(banner: nil, welcome: welcome))
        let text = bufferRows(result.buffer, area: TerminalRect(
            x: 0, y: 0, width: 110, height: 34
        )).joined()
        #expect(text.contains("Changelog"))
        #expect(text.contains("Fallback bullet paints"))
        let rows = result.overlays.last?.rows.map(\.id) ?? []
        #expect(rows.contains(PagerWelcomeOverlay.changelogCTARowID))
        #expect(!rows.contains(PagerWelcomeOverlay.announcementRowID))
    }

    // MARK: The shared CTA button painter (`render_cta_button`)

    @Test("the CTA button truncates with an ellipsis and the caption drops whole")
    func ctaButtonWholeOrNotRules() {
        let area = TerminalRect(x: 0, y: 0, width: 40, height: 1)

        // Full width: button + one space + dim caption.
        var buffer = CellBuffer(area: area)
        let rect = drawAnnouncementCTAButton(
            &buffer, x: 0, y: 0, maxWidth: 40,
            label: "Upgrade", caption: "ctrl+o", hovered: false, theme: .default
        )
        #expect(rect == TerminalRect(x: 0, y: 0, width: 9, height: 1))
        let full = bufferRows(buffer, area: area)[0]
        #expect(full.hasPrefix("[Upgrade] ctrl+o"))

        // Too narrow for the caption: the caption drops WHOLE — never a
        // partial (`announcements.rs:99-116`).
        buffer = CellBuffer(area: area)
        _ = drawAnnouncementCTAButton(
            &buffer, x: 0, y: 0, maxWidth: 12,
            label: "Upgrade", caption: "ctrl+o", hovered: false, theme: .default
        )
        let noCaption = bufferRows(buffer, area: area)[0]
        #expect(noCaption == "[Upgrade]")

        // Narrower than the button: the label truncates WITH the ellipsis
        // (`truncate_str`, line_utils.rs:83-104) and the rect matches the
        // painted cells, so a click can never land in a blank margin.
        buffer = CellBuffer(area: area)
        let clipped = drawAnnouncementCTAButton(
            &buffer, x: 0, y: 0, maxWidth: 6,
            label: "Upgrade", caption: nil, hovered: false, theme: .default
        )
        #expect(clipped?.width == 6)
        let clippedRow = bufferRows(buffer, area: area)[0]
        #expect(clippedRow.count == 6)
        #expect(clippedRow.hasSuffix("…"))

        // Zero budget: nothing painted, no rect — no phantom click target.
        buffer = CellBuffer(area: area)
        let none = drawAnnouncementCTAButton(
            &buffer, x: 0, y: 0, maxWidth: 0,
            label: "Upgrade", caption: nil, hovered: false, theme: .default
        )
        #expect(none == nil)
    }
}
