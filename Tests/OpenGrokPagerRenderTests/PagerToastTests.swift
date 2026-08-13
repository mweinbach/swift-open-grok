// PagerToastTests.swift
//
// Sticky/transient toast slot goldens against pin 650c1db7
// (`fit_toast_text` / `active_toast_message` / `render.rs:2007-2028`).

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("Pager toast fit")
struct PagerToastFitTests {
    @Test("short message is padded untouched")
    func shortMessagePadded() {
        #expect(pagerFitToastText("Copied!", availableWidth: 40) == " Copied! ")
    }

    @Test("long message truncates with ellipsis instead of vanishing")
    func longMessageTruncates() throws {
        let msg =
            "Copied via OSC 52 — also saved to /tmp/grok-0/last-copy.txt. If paste fails, hold Shift (or Fn) and drag to select & copy natively."
        let fitted = try #require(pagerFitToastText(msg, availableWidth: 60))
        #expect(fitted.count <= 58)
        #expect(fitted.hasSuffix("… "))
        #expect(fitted.contains("also saved to"))
    }

    @Test("width under 5 yields none")
    func narrowSlotYieldsNone() {
        #expect(pagerFitToastText("Copied!", availableWidth: 4) == nil)
        #expect(pagerFitToastText("Copied!", availableWidth: 0) == nil)
        #expect(pagerFitToastText("Copied!", availableWidth: 5) != nil)
    }
}

@Suite("Pager toast precedence")
struct PagerToastPrecedenceTests {
    @Test("transient wins; sticky restores when transient is cleared")
    func transientWinsAndStickyRestores() {
        #expect(
            pagerActiveToastMessage(transient: "Copied!", sticky: "Mouse off") == "Copied!"
        )
        #expect(
            pagerActiveToastMessage(transient: nil, sticky: "Mouse off") == "Mouse off"
        )
        #expect(pagerActiveToastMessage(transient: nil, sticky: nil) == nil)

        let withTransient = PagerRenderState(
            size: TerminalSize(width: 40, height: 12),
            toast: "Copied!",
            stickyToast: "Mouse off"
        )
        #expect(withTransient.activeToastMessage == "Copied!")

        let stickyOnly = PagerRenderState(
            size: TerminalSize(width: 40, height: 12),
            stickyToast: "Mouse off"
        )
        #expect(stickyOnly.activeToastMessage == "Mouse off")
    }
}

@Suite("Pager toast paint")
struct PagerToastPaintTests {
    private func frame(
        toast: String? = nil,
        stickyToast: String? = nil,
        width: Int = 48,
        height: Int = 16,
        overlays: PagerOverlayStack = PagerOverlayStack(),
        theme: PagerRenderTheme = .default
    ) -> PagerRenderResult {
        renderPagerFrame(
            PagerRenderState(
                size: TerminalSize(width: width, height: height),
                statusBar: PagerStatusBar(gitBranch: "main", workingDirectory: "~/work"),
                conversation: [.message(PagerMessage(role: .assistant, text: "hello from the transcript"))],
                input: PagerComposerState(text: "next"),
                shortcuts: PagerShortcutsBar(hints: [PagerShortcutHint(key: "Enter", label: "send")]),
                theme: theme,
                showScrollbar: false,
                overlays: overlays,
                toast: toast,
                stickyToast: stickyToast
            )
        )
    }

    @Test("placement, style, and occluder sit bottom-right of the conversation rect")
    func placementStyleAndOccluder() throws {
        let theme = PagerRenderTheme(bgBase: .blue, accentUser: .red)
        let result = frame(toast: "Copied!", theme: theme)
        let conversation = result.layout.conversation
        let expected = try #require(
            pagerToastPaintPlan(message: "Copied!", conversation: conversation)
        )
        #expect(expected.text == " Copied! ")
        #expect(result.layout.toastOccluder == expected.rect)
        #expect(result.layout.conversationHit?.toastOccluder == expected.rect)

        let rect = expected.rect
        #expect(rect.height == 1)
        #expect(rect.y == conversation.bottom - 1)
        #expect(rect.right == conversation.right - 1)

        var painted = ""
        for x in rect.x..<rect.right {
            let cell = try #require(result.buffer.cell(x: x, y: rect.y))
            painted += cell.grapheme
            #expect(cell.foreground == theme.accentUser)
            #expect(cell.background == theme.bgBase)
            #expect(cell.style.contains(.bold))
        }
        #expect(painted == " Copied! ")

        let hit = try #require(result.layout.conversationHit)
        #expect(hit.containsToastOccluder(x: rect.x, y: rect.y))
        #expect(!hit.containsSelectablePoint(x: rect.x, y: rect.y))
        #expect(hit.containsSelectablePoint(x: conversation.x + 2, y: conversation.y))
    }

    @Test("sticky paints when transient is absent; transient replaces it")
    func stickyThenTransientViaState() {
        let sticky = frame(stickyToast: "Reconnecting")
        #expect(sticky.layout.toastOccluder != nil)
        #expect(text(at: sticky.layout.toastOccluder, in: sticky).contains("Reconnecting"))

        let both = frame(toast: "Copied!", stickyToast: "Reconnecting")
        #expect(text(at: both.layout.toastOccluder, in: both).contains("Copied!"))
        #expect(!text(at: both.layout.toastOccluder, in: both).contains("Reconnecting"))
    }

    @Test("toast does not overwrite the status bar")
    func toastDoesNotCoverStatus() {
        let result = frame(toast: "Copied!")
        let status = result.layout.statusBar
        #expect(status.height == 1)
        var row = ""
        for x in status.x..<status.right {
            row += result.buffer.cell(x: x, y: status.y)?.grapheme ?? ""
        }
        #expect(row.contains("main"))
        #expect(!row.contains("Copied!"))
        #expect(result.layout.toastOccluder?.y != status.y)
    }

    @Test("a modal still paints when a toast is present")
    func overlayStillPaintsWithToast() {
        let overlay = PagerOverlay.list(
            id: "model",
            title: "Select model",
            rows: [PagerListRow(id: "grok-4", label: "grok-4", detail: "xai")]
        )
        let result = frame(
            toast: "Copied!",
            overlays: PagerOverlayStack([overlay])
        )
        #expect(result.overlays.first != nil)
        #expect(result.snapshot().contains("Select model"))
        #expect(result.layout.toastOccluder != nil)
    }

    @Test("narrow conversation yields no toast and no occluder")
    func narrowConversationYieldsNone() {
        let tiny = TerminalRect(x: 0, y: 2, width: 4, height: 3)
        #expect(pagerToastPaintPlan(message: "Copied!", conversation: tiny) == nil)
        let empty = TerminalRect(x: 0, y: 2, width: 40, height: 0)
        #expect(pagerToastPaintPlan(message: "Copied!", conversation: empty) == nil)
    }

    private func text(at rect: TerminalRect?, in result: PagerRenderResult) -> String {
        guard let rect else { return "" }
        var painted = ""
        for x in rect.x..<rect.right {
            painted += result.buffer.cell(x: x, y: rect.y)?.grapheme ?? ""
        }
        return painted
    }
}
