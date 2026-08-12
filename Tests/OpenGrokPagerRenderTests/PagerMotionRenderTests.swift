// PagerMotionRenderTests.swift
//
// The motion styles asserted through the frame they actually paint, and the
// paint-side clock asserted through the renderer that actually throttles.
// Per AGENTS.md §3 these deliberately avoid the pure PagerMotion functions
// (already covered by PagerMotionTests): a wave function that is never called
// from `renderPagerFrame` passes a function test and still ships a frozen UI.

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

// MARK: - Buffer probes

private func firstCell(
    withGrapheme grapheme: String,
    in result: PagerRenderResult
) -> Cell? {
    for y in result.buffer.area.top..<result.buffer.area.bottom {
        for x in result.buffer.area.left..<result.buffer.area.right {
            if let cell = result.buffer.cell(x: x, y: y), cell.grapheme == grapheme {
                return cell
            }
        }
    }
    return nil
}

@Suite("Motion styles reach the painted frame")
struct PagerMotionRenderSiteTests {
    private func runningToolState(
        tick: Int,
        enabled: Bool
    ) -> PagerRenderState {
        PagerRenderState(
            size: TerminalSize(width: 44, height: 12),
            conversation: [
                .tool(PagerToolCard(
                    name: "bash",
                    input: "swift build",
                    output: "compiling",
                    state: .running,
                    isExpanded: true
                ))
            ],
            motion: PagerMotionSnapshot(tick: tick, seconds: 0, enabled: enabled)
        )
    }

    @Test("a running block's rail wears the accent wave, phase-shifted per row")
    func runningRailWaves() {
        let theme = PagerRenderTheme.default
        let early = renderPagerFrame(runningToolState(tick: 0, enabled: true))
        let late = renderPagerFrame(runningToolState(tick: 3, enabled: true))

        // The rail column is x = 0; the header row is the first painted line.
        let earlyRail = early.buffer.cell(x: 0, y: 0)
        let lateRail = late.buffer.cell(x: 0, y: 0)
        #expect(earlyRail?.grapheme == PagerGlyphs.accentBar)
        #expect(earlyRail?.foreground == PagerMotion.runningAccentColor(
            theme: theme, accent: theme.accentRunning, tick: 0, row: 0
        ))
        #expect(lateRail?.foreground == PagerMotion.runningAccentColor(
            theme: theme, accent: theme.accentRunning, tick: 3, row: 0
        ))
        // The wave moves: the same cell changes color as the tick advances.
        #expect(earlyRail?.foreground != lateRail?.foreground)
        // ... and travels: two rows of the same frame differ in phase.
        let secondRow = early.buffer.cell(x: 0, y: 1)
        #expect(secondRow?.foreground != earlyRail?.foreground)
    }

    @Test("motion disabled renders the rail at the flat accent — the old still frame")
    func disabledRailIsStill() {
        let theme = PagerRenderTheme.default
        let frame = renderPagerFrame(runningToolState(tick: 7, enabled: false))
        #expect(frame.buffer.cell(x: 0, y: 0)?.foreground == theme.accentRunning)
    }

    private func finishedToolState(now: TimeInterval) -> PagerRenderState {
        PagerRenderState(
            size: TerminalSize(width: 44, height: 12),
            conversation: [
                .tool(PagerToolCard(
                    name: "bash",
                    input: "swift build",
                    state: .succeeded,
                    isExpanded: false,
                    finishedAt: 0
                ))
            ],
            motion: PagerMotionSnapshot(tick: 0, seconds: now, enabled: true)
        )
    }

    @Test("a just-finished block keeps its bright rail for 400ms, then goes static")
    func finishFlashExpires() {
        // Inside the flash window a collapsed block is un-muted: the rail
        // shows at full accent.
        let flashing = renderPagerFrame(finishedToolState(now: 0.2))
        #expect(flashing.buffer.cell(x: 0, y: 0)?.grapheme == PagerGlyphs.accentBar)

        // Past the window the collapsed row returns to the muted, rail-less
        // presentation this port always drew.
        let settled = renderPagerFrame(finishedToolState(now: 0.6))
        #expect(settled.buffer.cell(x: 0, y: 0)?.grapheme == " ")
    }

    private func turnStatusState(
        indicator: PagerTurnIndicator,
        tick: Int
    ) -> PagerRenderState {
        PagerRenderState(
            size: TerminalSize(width: 60, height: 12),
            turnStatus: PagerTurnStatus(
                label: "Waiting",
                tick: tick,
                indicator: indicator
            ),
            motion: PagerMotionSnapshot(tick: tick, seconds: 0, enabled: true)
        )
    }

    @Test("the pending-user diamond pulses between dim and bright")
    func pendingDiamondPulses() {
        let theme = PagerRenderTheme.default
        let dim = renderPagerFrame(turnStatusState(indicator: .pendingUserDiamond, tick: 0))
        let bright = renderPagerFrame(turnStatusState(indicator: .pendingUserDiamond, tick: 10))

        let dimCell = firstCell(withGrapheme: PagerGlyphs.toolBullet, in: dim)
        let brightCell = firstCell(withGrapheme: PagerGlyphs.toolBullet, in: bright)
        #expect(dimCell != nil)
        #expect(dimCell?.foreground == PagerMotion.pendingDiamondColor(
            theme: theme, accent: theme.accentUser, tick: 0
        ))
        #expect(dimCell?.foreground != brightCell?.foreground)
    }

    @Test("the idle monitor cue breathes through ○ ◎ ◉ at the slow divisor")
    func monitorPulseAdvances() {
        let first = renderPagerFrame(turnStatusState(indicator: .idleMonitor, tick: 0))
        let second = renderPagerFrame(turnStatusState(indicator: .idleMonitor, tick: 8))
        #expect(firstCell(withGrapheme: "\u{25CB}", in: first) != nil)
        #expect(firstCell(withGrapheme: "\u{25CE}", in: second) != nil)
    }

    @Test("the background-task chip spins with the wall tick")
    func backgroundChipSpins() {
        func state(tick: Int) -> PagerRenderState {
            PagerRenderState(
                size: TerminalSize(width: 44, height: 10),
                statusBar: PagerStatusBar(backgroundTaskCount: 2),
                motion: PagerMotionSnapshot(tick: tick, seconds: 0, enabled: true)
            )
        }
        #expect(renderPagerFrame(state(tick: 0)).snapshot().contains("\(PagerGlyphs.dotSpinner[0]) 2"))
        #expect(renderPagerFrame(state(tick: 4)).snapshot().contains("\(PagerGlyphs.dotSpinner[1]) 2"))
    }

    private func welcomeState(
        seconds: TimeInterval,
        enabled: Bool
    ) -> PagerRenderState {
        // Tall enough that the overlay frame (terminal minus composer) clears
        // `PagerWelcomeLogo.fullMinimumHeight`; at 24 rows the frame is ~21,
        // the height tier yields no logo at all, and this test would be
        // asserting shimmer colors on zero cells.
        PagerRenderState(
            size: TerminalSize(width: 60, height: 32),
            overlays: PagerOverlayStack([
                .welcome(id: "test", PagerWelcomeOverlay(version: "0.0.0"))
            ]),
            motion: PagerMotionSnapshot(tick: 0, seconds: seconds, enabled: enabled)
        )
    }

    /// Every logo cell's foreground, in paint order.
    private func logoColors(_ result: PagerRenderResult) -> [TerminalColor] {
        var colors: [TerminalColor] = []
        for y in result.buffer.area.top..<result.buffer.area.bottom {
            for x in result.buffer.area.left..<result.buffer.area.right {
                guard let cell = result.buffer.cell(x: x, y: y) else { continue }
                // Braille glyphs only appear in the logo on this screen.
                if let scalar = cell.grapheme.unicodeScalars.first,
                   (0x2800...0x28FF).contains(scalar.value) {
                    colors.append(cell.foreground)
                }
            }
        }
        return colors
    }

    @Test("the welcome logo shimmers with wall time and rests gray, not bright")
    func welcomeLogoShimmers() {
        let theme = PagerRenderTheme.default
        let still = renderPagerFrame(welcomeState(seconds: 0, enabled: false))
        let early = renderPagerFrame(welcomeState(seconds: 0.1, enabled: true))
        let late = renderPagerFrame(welcomeState(seconds: 0.7, enabled: true))

        // Disabled keeps the old bright still frame.
        #expect(Set(logoColors(still)) == [theme.textPrimary])
        // Enabled, the logo rests near gray and the sweeping band recolors
        // cells as the clock advances.
        let earlyColors = logoColors(early)
        #expect(!earlyColors.isEmpty)
        #expect(!earlyColors.contains(theme.textPrimary))
        #expect(earlyColors != logoColors(late))
    }

    /// Logo braille cells with their buffer coordinates, in paint order.
    private func logoCells(
        _ result: PagerRenderResult
    ) -> [(x: Int, y: Int, color: TerminalColor)] {
        var cells: [(x: Int, y: Int, color: TerminalColor)] = []
        for y in result.buffer.area.top..<result.buffer.area.bottom {
            for x in result.buffer.area.left..<result.buffer.area.right {
                guard let cell = result.buffer.cell(x: x, y: y) else { continue }
                if let scalar = cell.grapheme.unicodeScalars.first,
                   (0x2800...0x28FF).contains(scalar.value) {
                    cells.append((x, y, cell.foreground))
                }
            }
        }
        return cells
    }

    @Test("welcome logo corner colors come from shimmerDiagonal, not the old max-span")
    func welcomeLogoCornersUseShimmerDiagonal() {
        // The pure-function suite already pins `shimmerDiagonal`'s formula;
        // this asserts the paint path calls it. Bottom-left and top-right are
        // the extremes of the diagonal field — if the renderer still divides
        // by `(cols-1)+(rows-1)`, the top-right color diverges from the helper.
        let theme = PagerRenderTheme.default
        let seconds: TimeInterval = 1.0
        let painted = renderPagerFrame(welcomeState(seconds: seconds, enabled: true))
        let cells = logoCells(painted)
        #expect(!cells.isEmpty)

        let minX = cells.map(\.x).min()!
        let maxX = cells.map(\.x).max()!
        let minY = cells.map(\.y).min()!
        let maxY = cells.map(\.y).max()!
        let columns = maxX - minX + 1
        let rows = maxY - minY + 1
        // Full logo art (height tier clears `fullMinimumHeight` at size 32).
        #expect(columns == (PagerWelcomeLogo.full.map {
            UnicodeDisplayWidth.width(of: $0)
        }.max() ?? 0))
        #expect(rows == PagerWelcomeLogo.full.count)

        func color(atX x: Int, y: Int) -> TerminalColor? {
            cells.first { $0.x == x && $0.y == y }?.color
        }
        let bottomLeft = color(atX: minX, y: maxY)
        let topRight = color(atX: maxX, y: minY)
        #expect(bottomLeft != nil)
        #expect(topRight != nil)

        let expectedBottomLeft = PagerMotion.shimmerColor(
            theme: theme,
            diagonal: PagerMotion.shimmerDiagonal(
                column: 0, row: rows - 1, columns: columns, rows: rows
            ),
            seconds: seconds
        )
        let expectedTopRight = PagerMotion.shimmerColor(
            theme: theme,
            diagonal: PagerMotion.shimmerDiagonal(
                column: columns - 1, row: 0, columns: columns, rows: rows
            ),
            seconds: seconds
        )
        #expect(bottomLeft == expectedBottomLeft)
        #expect(topRight == expectedTopRight)

        // Discriminator: the retired max-span formula puts the top-right at
        // diagonal 1.0; `shimmerDiagonal` does not. If these ever coincide at
        // this timestamp the assertion above would stop catching an unwired
        // helper — fail loud rather than silently lose coverage.
        let oldMaxSpan = Double(max(1, (columns - 1) + (rows - 1)))
        let oldTopRight = PagerMotion.shimmerColor(
            theme: theme,
            diagonal: Double((columns - 1) + (rows - 1)) / oldMaxSpan,
            seconds: seconds
        )
        #expect(expectedTopRight != oldTopRight)

        // Reduced motion still paints every logo cell in one still color.
        let still = renderPagerFrame(welcomeState(seconds: seconds, enabled: false))
        #expect(Set(logoColors(still)) == [theme.textPrimary])
    }

    @Test("the dropdown window follows the selection so every row is reachable")
    func completionMenuAutoScrolls() {
        let rows = (0..<10).map {
            PagerCompletionRow(label: "/cmd\($0)", summary: "row \($0)")
        }
        let state = PagerRenderState(
            size: TerminalSize(width: 44, height: 16),
            completions: PagerCompletionMenu(rows: rows, selectedIndex: 9, scrollOffset: 0)
        )
        let snapshot = renderPagerFrame(state).snapshot()
        // Six visible rows ending at the selection: 4...9 on screen, 0 off.
        #expect(snapshot.contains("\(PagerGlyphs.promptArrow)/cmd9"))
        #expect(snapshot.contains("/cmd4"))
        #expect(!snapshot.contains("/cmd0 "))
        #expect(!snapshot.contains("/cmd3"))
    }
}

// MARK: - Paint cadence

@Suite("Frame clock in the terminal render path")
struct PagerFrameCoalescingTests {
    private final class CountingSink: PagerTerminalSink, @unchecked Sendable {
        let capabilities = PagerTerminalCapabilities.standard
        private(set) var bytes: [UInt8] = []
        func write(bytes: [UInt8]) throws { self.bytes.append(contentsOf: bytes) }
        func flush() throws {}
    }

    private func makeState(text: String) -> PagerRenderState {
        PagerRenderState(
            size: TerminalSize(width: 30, height: 8),
            input: PagerComposerState(text: text)
        )
    }

    @Test("repaint requests inside the min-draw window fold into one deferred frame")
    func coalescesAtCadence() throws {
        let renderer = PagerTerminalRenderer(
            sink: CountingSink(),
            configuration: PagerTerminalRendererConfiguration(paintCadence: 0.016)
        )

        // First request paints immediately.
        let first = try renderer.requestFrame(makeState(text: "a"), at: 0)
        #expect(first != nil)

        // A burst inside the window is folded: none of these paint.
        var foldedCount = 0
        for step in 1...15 {
            let report = try renderer.requestFrame(
                makeState(text: "a\(step)"),
                at: Double(step) / 1000
            )
            if report == nil { foldedCount += 1 }
        }
        #expect(foldedCount == 15)
        // The fold is not a drop: a deferred frame is scheduled at the
        // cadence boundary.
        #expect(renderer.scheduledFrameAt != nil)

        // ...and paints once when the caller services it.
        let flushed = try renderer.flushPendingFrame(makeState(text: "final"), at: 0.017)
        #expect(flushed != nil)
        #expect(renderer.scheduledFrameAt == nil)

        // With nothing dirty, a flush is a no-op rather than a repaint.
        #expect(try renderer.flushPendingFrame(makeState(text: "final"), at: 0.05) == nil)
    }

    @Test("requests spaced beyond the cadence paint one frame each")
    func spacedRequestsAllPaint() throws {
        let renderer = PagerTerminalRenderer(
            sink: CountingSink(),
            configuration: PagerTerminalRendererConfiguration(paintCadence: 0.016)
        )
        var painted = 0
        for step in 0..<4 {
            if try renderer.requestFrame(
                makeState(text: "t\(step)"),
                at: Double(step) * 0.020
            ) != nil {
                painted += 1
            }
        }
        #expect(painted == 4)
    }
}

// MARK: - Cadence resolution (the auto-cadence setting's reader)

@Suite("Display-refresh cadence resolution")
struct PagerDisplayRefreshCadenceTests {
    @Test("auto cadence off keeps the 16ms default even with a probed Hz")
    func flagOffKeepsDefault() {
        let cadence = PagerFrameClock.cadence(
            environment: [:],
            policy: PagerDisplayRefreshPolicy(),
            probedRefreshHz: 120
        )
        #expect(cadence == PagerMotion.defaultPaintCadence)
    }

    @Test("auto cadence on maps 120Hz to 8ms — round(1000/hz) clamped to floor")
    func autoAppliesFromProbe() {
        // Mirrors `resolve_motion_cadence_folds_decide_and_merge`
        // (`display_refresh.rs:632-638`).
        let cadence = PagerFrameClock.cadence(
            environment: [:],
            policy: PagerDisplayRefreshPolicy(autoCadenceEnabled: true),
            probedRefreshHz: 120
        )
        #expect(cadence == 0.008)
    }

    @Test("a probed Hz outside the accepted band falls back to the default")
    func outOfRangeHzIsIgnored() {
        let policy = PagerDisplayRefreshPolicy(autoCadenceEnabled: true)
        #expect(PagerFrameClock.cadence(
            environment: [:], policy: policy, probedRefreshHz: 30
        ) == PagerMotion.defaultPaintCadence)
        #expect(PagerFrameClock.cadence(
            environment: [:], policy: policy, probedRefreshHz: 480
        ) == PagerMotion.defaultPaintCadence)
    }

    @Test("no probe means no auto cadence — upstream's probe_skip")
    func missingProbeKeepsDefault() {
        #expect(PagerFrameClock.cadence(
            environment: [:],
            policy: PagerDisplayRefreshPolicy(autoCadenceEnabled: true),
            probedRefreshHz: nil
        ) == PagerMotion.defaultPaintCadence)
    }

    @Test("GROK_MIN_DRAW_MS overrides auto cadence, even when unparsable")
    func environmentWins() {
        let policy = PagerDisplayRefreshPolicy(autoCadenceEnabled: true)
        // A parsable value pins the cadence (`display_refresh.rs:640-643`).
        #expect(PagerFrameClock.cadence(
            environment: ["GROK_MIN_DRAW_MS": "10"], policy: policy, probedRefreshHz: 120
        ) == 0.010)
        // Presence counts as "set" even when invalid — clamped default, not
        // the auto value (`display_refresh_startup.rs:41-48`).
        #expect(PagerFrameClock.cadence(
            environment: ["GROK_MIN_DRAW_MS": "banana"], policy: policy, probedRefreshHz: 120
        ) == PagerMotion.defaultPaintCadence)
    }
}
