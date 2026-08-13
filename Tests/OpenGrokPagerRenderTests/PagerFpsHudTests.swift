// PagerFpsHudTests.swift
//
// FPS HUD goldens against pin 650c1db7 (`views/fps_hud.rs`).

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("PagerFpsHud")
struct PagerFpsHudTests {
    @Test("disabled by default and toggle round-trips")
    func disabledByDefaultAndToggleRoundTrips() {
        var hud = PagerFpsHud(environmentValue: nil)
        #expect(!hud.isEnabled)
        #expect(hud.overlayHeight == 0)
        #expect(hud.overlay(topOffset: 0, now: 0) == nil)

        hud.toggle()
        #expect(hud.isEnabled)
        #expect(hud.overlayHeight == 2)
        #expect(hud.overlay(topOffset: 0, now: 0) != nil)

        hud.toggle()
        #expect(!hud.isEnabled)
        #expect(hud.overlay(topOffset: 0, now: 0) == nil)
    }

    @Test("GROK_FPS env enables HUD where the dev overlay is absent")
    func grokFpsEnvEnablesHud() {
        for truthy in ["1", "full", " "] {
            #expect(
                PagerFpsHud(environmentValue: truthy).isEnabled == pagerFpsHudHonorsGrokFpsEnvironment,
                "GROK_FPS=\(truthy) must track the env-gate owner"
            )
            #expect(pagerFpsHudEnvironmentIsTruthy(truthy))
        }
        for falsy: String? in [nil, "", "0"] {
            #expect(!PagerFpsHud(environmentValue: falsy).isEnabled)
            #expect(!pagerFpsHudEnvironmentIsTruthy(falsy))
        }
    }

    @Test("record caps the ring buffer and toggle clears stale samples")
    func recordCapsAndToggleClears() {
        var hud = PagerFpsHud(environmentValue: nil)
        hud.toggle()
        for _ in 0..<(pagerFpsHudSampleCapacity + 30) {
            hud.record(0.010)
        }
        #expect(hud.samplesMilliseconds.count == pagerFpsHudSampleCapacity)
        hud.toggle()
        hud.toggle()
        #expect(hud.samplesMilliseconds.isEmpty)
        let body = hud.overlay(topOffset: 0, now: 0)?.body ?? ""
        #expect(body.contains("fps:-"), "fresh enablement must show placeholders")
        #expect(body == pagerFpsHudEmptyBody)
    }

    @Test("stats line reports mean FPS and percentiles")
    func statsLineReportsMeanAndPercentiles() {
        var hud = PagerFpsHud(environmentValue: nil)
        hud.toggle()
        for _ in 0..<100 {
            hud.record(0.010)
        }
        let overlay = hud.overlay(topOffset: 0, now: 0)
        #expect(overlay?.body == "fps:100 p50:10.0ms p95:10.0ms")
    }

    @Test("record is a no-op while disabled")
    func recordIsNoopWhileDisabled() {
        var hud = PagerFpsHud(environmentValue: nil)
        hud.record(0.010)
        #expect(hud.samplesMilliseconds.isEmpty)
    }

    @Test("mean at or below 1e-6 reports fps 0")
    func meanFloorReportsZeroFps() {
        #expect(pagerFormatFpsStats(samplesMilliseconds: [0]) == "fps:0 p50:0.0ms p95:0.0ms")
        #expect(pagerFormatFpsStats(samplesMilliseconds: [1e-6]) == "fps:0 p50:0.0ms p95:0.0ms")
        #expect(pagerFormatFpsStats(samplesMilliseconds: [1e-5]).hasPrefix("fps:"))
        #expect(!pagerFormatFpsStats(samplesMilliseconds: [1e-5]).hasPrefix("fps:0 "))
    }

    @Test("p50/p95 linear interpolation on mixed samples")
    func percentileLinearInterpolation() {
        // mean 25ms → fps 40; p50 rank 1.5 → 25.0; p95 rank 2.85 → 38.5
        #expect(
            pagerFormatFpsStats(samplesMilliseconds: [10, 20, 30, 40])
                == "fps:40 p50:25.0ms p95:38.5ms"
        )
    }

    @Test("cached stats refresh at 250ms")
    func cachedStatsRefreshCadence() {
        var hud = PagerFpsHud(environmentValue: nil)
        hud.toggle()
        hud.record(0.010)
        let first = hud.overlay(topOffset: 0, now: 1.0)
        #expect(first?.body == "fps:100 p50:10.0ms p95:10.0ms")
        hud.record(0.020)
        let cached = hud.overlay(topOffset: 0, now: 1.249)
        #expect(cached?.body == first?.body)
        let refreshed = hud.overlay(topOffset: 0, now: 1.250)
        #expect(refreshed?.body == "fps:67 p50:15.0ms p95:19.5ms")
    }

    @Test("currentOverlay is a nonmutating snapshot and does not consume refresh")
    func currentOverlayDoesNotConsumeRefresh() {
        var hud = PagerFpsHud(environmentValue: nil)
        hud.toggle()
        hud.record(0.010)
        let beforeRefresh = hud.currentOverlay(topOffset: 0)
        #expect(beforeRefresh?.body == pagerFpsHudEmptyBody)
        hud.refreshOverlayCache(now: 1.0)
        #expect(hud.currentOverlay(topOffset: 0)?.body == "fps:100 p50:10.0ms p95:10.0ms")
        hud.record(0.020)
        #expect(hud.currentOverlay(topOffset: 0)?.body == "fps:100 p50:10.0ms p95:10.0ms")
        hud.refreshOverlayCache(now: 1.249)
        #expect(hud.currentOverlay(topOffset: 0)?.body == "fps:100 p50:10.0ms p95:10.0ms")
        hud.refreshOverlayCache(now: 1.250)
        #expect(hud.currentOverlay(topOffset: 0)?.body == "fps:67 p50:15.0ms p95:19.5ms")
    }

    @Test("render paints theme-agnostic style over every panel cell")
    func renderPaintsThemeAgnosticStyle() throws {
        let area = TerminalRect(x: 0, y: 0, width: 60, height: 6)
        var buffer = CellBuffer(area: area)
        let themed = Cell(
            grapheme: "x",
            style: .italic,
            foreground: .rgb(228, 228, 228),
            background: .rgb(3, 3, 4)
        )
        for y in area.top..<area.bottom {
            for x in area.left..<area.right {
                buffer.setCell(themed, x: x, y: y)
            }
        }
        let overlay = PagerFpsHudOverlay(
            body: "fps:100 p50:10.0ms p95:10.0ms",
            topOffset: 1
        )
        renderPagerFpsHudOverlay(overlay, area: area, buffer: &buffer)
        let x0 = area.width - pagerFpsHudPanelWidth
        for y in 1..<3 {
            for x in x0..<area.width {
                let cell = try #require(buffer.cell(x: x, y: y))
                #expect(cell.background == .black, "cell (\(x),\(y)) bg")
                #expect(
                    cell.foreground == .white || cell.foreground == .yellow,
                    "cell (\(x),\(y)) fg must be debug chrome, got \(cell.foreground)"
                )
                #expect(cell.style.isEmpty, "cell (\(x),\(y)) must shed themed modifiers")
            }
        }
        #expect(buffer.cell(x: 0, y: 1)?.background == .rgb(3, 3, 4))
        #expect(buffer.cell(x: area.width - 1, y: 0)?.background == .rgb(3, 3, 4))

        let title = (x0..<(x0 + pagerFpsHudTitle.count)).map {
            buffer.cell(x: $0, y: 1)?.grapheme ?? ""
        }.joined()
        #expect(title == pagerFpsHudTitle)
        #expect(buffer.cell(x: x0, y: 1)?.foreground == .yellow)
        #expect(buffer.cell(x: x0, y: 2)?.foreground == .white)
    }

    @Test("frame paints FPS last over status chrome")
    func framePaintsFpsLast() {
        let result = renderPagerFrame(
            PagerRenderState(
                size: TerminalSize(width: 48, height: 12),
                statusBar: PagerStatusBar(
                    gitBranch: "main",
                    workingDirectory: "~/work",
                    contextUsedTokens: 8500,
                    contextTotalTokens: 1_000_000
                ),
                conversation: [.message(PagerMessage(role: .assistant, text: "hello"))],
                input: PagerComposerState(text: "next"),
                showScrollbar: false,
                fpsHud: PagerFpsHudOverlay(body: "fps:100 p50:10.0ms p95:10.0ms")
            )
        )
        let x0 = 48 - pagerFpsHudPanelWidth
        let title = (x0..<(x0 + pagerFpsHudTitle.count)).map {
            result.buffer.cell(x: $0, y: 0)?.grapheme ?? ""
        }.joined()
        #expect(title == pagerFpsHudTitle)
        #expect(result.buffer.cell(x: x0, y: 0)?.foreground == .yellow)
        #expect(result.buffer.cell(x: x0, y: 0)?.background == .black)
        #expect(result.buffer.cell(x: x0, y: 1)?.foreground == .white)
        // Status chrome to the left of the panel is intact.
        #expect(result.snapshot().contains("main"))
    }

    @Test("frame still paints a modal when the FPS HUD is on")
    func frameKeepsOverlayWithFpsHud() {
        let overlay = PagerOverlay.list(
            id: "model",
            title: "Select model",
            rows: [PagerListRow(id: "grok-4", label: "grok-4", detail: "xai")]
        )
        let result = renderPagerFrame(
            PagerRenderState(
                size: TerminalSize(width: 60, height: 24),
                conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
                input: PagerComposerState(text: "draft"),
                showScrollbar: false,
                overlays: PagerOverlayStack([overlay]),
                fpsHud: PagerFpsHudOverlay(body: pagerFpsHudEmptyBody)
            )
        )
        #expect(result.overlays.first != nil)
        #expect(result.snapshot().contains("Select model"))
        #expect(result.snapshot().contains(pagerFpsHudTitle))
    }
}
