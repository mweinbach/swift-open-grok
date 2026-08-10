// PagerContextBarTests.swift
//
// B6: the context-bar hover widget — the last chrome reader. Upstream
// reference at pin 650c1db7: `views/context_bar.rs` (`fmt_pct5` :25-33
// with its test tables :265-295, the width-invariant hover swap
// :182-260) and `views/progress_bar.rs` (the eighth-cell block bar).

import Foundation
import Testing
import OpenGrokTerminalCore
@testable import OpenGrokPagerRender

@Suite("Context bar formatting")
struct PagerContextBarFormatTests {
    @Test("fmt_pct5 is always five characters")
    func fmtPct5IsAlwaysFiveCharacters() {
        // context_bar.rs:265-280, plus the ≥100 arm (:26-27).
        #expect(pagerFormatPct5(0.0) == "0.00%")
        #expect(pagerFormatPct5(5.123) == "5.12%")
        #expect(pagerFormatPct5(9.99) == "9.99%")
        #expect(pagerFormatPct5(10.0) == "10.0%")
        #expect(pagerFormatPct5(20.16) == "20.2%")
        #expect(pagerFormatPct5(99.9) == "99.9%")
        #expect(pagerFormatPct5(100.0) == "MAX %")
        #expect(pagerFormatPct5(240.0) == "MAX %")
        // The hardening past upstream: 99.95-99.99 round-formats to
        // "100.0%" (six chars) through upstream's own arms — a latent
        // width-invariant break there; the port clamps to the MAX form.
        #expect(pagerFormatPct5(99.99) == "MAX %")
        for pct in [0.0, 5.123, 9.99, 10.0, 55.5, 99.9, 100.0, 240.0] {
            #expect(pagerFormatPct5(pct).count == 5, "\(pct)")
        }
    }

    @Test("the hovered line is exactly the default's width — no layout shift")
    func hoveredLineMatchesDefaultWidth() {
        // context_bar.rs:186-192: the default drives the width; its ≥6-col
        // pad is what makes the invariant hold for degenerate inputs.
        let cases: [(Int, Int)] = [
            (8_500, 1_000_000),
            (0, 9),              // "0 / 9" — five chars, pad to six
            (276_000, 2_000_000),
            (999_999_999, 1_000_000_000),
        ]
        for (used, total) in cases {
            var status = PagerStatusBar(contextUsedTokens: used, contextTotalTokens: total)
            let normal = renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 80, height: 24),
                statusBar: status,
                input: PagerComposerState()
            ))
            status.contextBarHovered = true
            let hovered = renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 80, height: 24),
                statusBar: status,
                input: PagerComposerState()
            ))
            #expect(
                normal.layout.contextBar == hovered.layout.contextBar,
                "\(used)/\(total): the segment rect must not move on hover"
            )
            #expect(normal.layout.contextBar != nil)
        }
    }

    @Test("hover swaps tokens for the bar and percentage in place")
    func hoverSwapsTokensForTheBar() {
        var status = PagerStatusBar(contextUsedTokens: 500_000, contextTotalTokens: 1_000_000)
        let normal = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 80, height: 24),
            statusBar: status,
            input: PagerComposerState()
        ))
        let rect = normal.layout.contextBar!
        let rowText = { (frame: PagerRenderResult) -> String in
            (rect.x..<rect.right)
                .compactMap { frame.buffer.cell(x: $0, y: rect.y)?.grapheme }
                .joined()
        }
        #expect(rowText(normal).contains("/"), "default shows used / total")

        status.contextBarHovered = true
        let hovered = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 80, height: 24),
            statusBar: status,
            input: PagerComposerState()
        ))
        let hoveredText = rowText(hovered)
        #expect(hoveredText.contains("50.0%"), "hover shows the percentage: \(hoveredText)")
        #expect(!hoveredText.contains("/"), "the token form is fully replaced")
    }

    @Test("no context data publishes no rect")
    func noContextDataPublishesNoRect() {
        let frame = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 80, height: 24),
            statusBar: PagerStatusBar(workingDirectory: "/tmp"),
            input: PagerComposerState()
        ))
        #expect(frame.layout.contextBar == nil)
    }
}
