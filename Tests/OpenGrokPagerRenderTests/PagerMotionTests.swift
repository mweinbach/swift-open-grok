import Testing
import Foundation
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

/// A frame at an explicit tick. Every motion test drives this rather than a
/// wall clock, so a sequence is a fixed list of strings and not a flake.
private func turnFrame(tick: Int, label: String = "Thinking…") -> PagerRenderResult {
    renderPagerFrame(
        PagerRenderState(
            size: TerminalSize(width: 50, height: 12),
            conversation: [.message(PagerMessage(role: .assistant, text: "working"))],
            turnStatus: PagerTurnStatus(label: label, tick: tick),
            input: PagerComposerState(text: ""),
            showScrollbar: false
        )
    )
}

private func statusRow(_ result: PagerRenderResult) -> String {
    let rows = result.snapshot().split(separator: "\n", omittingEmptySubsequences: false)
    return rows.first { $0.contains("Thinking") }.map(String.init) ?? ""
}

// MARK: - Spinner cadence

@Suite("Spinner cadence")
struct PagerSpinnerTests {
    @Test("the braille spinner is the reference's eight frames in order")
    func brailleFrames() {
        #expect(PagerGlyphs.brailleSpinner == ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"])
    }

    @Test("the spinner advances every fourth tick and loops in 32")
    func spinnerDivisor() {
        #expect(PagerMotion.spinnerDivisor == 4)
        // Four ticks per frame, eight frames — one loop is 32 ticks.
        let sequence = (0..<36).map { PagerMotion.brailleFrame(tick: $0) }
        #expect(Array(sequence[0..<4]) == ["⠋", "⠋", "⠋", "⠋"])
        #expect(sequence[4] == "⠙")
        #expect(sequence[31] == "⠧")
        #expect(sequence[32] == "⠋")
        #expect(Array(sequence[0..<4]) == Array(sequence[32..<36]))
    }

    @Test("a negative tick folds instead of trapping")
    func negativeTicks() {
        #expect(PagerMotion.brailleFrame(tick: -1) == "⠧")
        #expect(PagerMotion.brailleFrame(tick: -4) == "⠧")
        #expect(PagerMotion.brailleFrame(tick: -5) == "⠦")
    }

    @Test("the rendered turn-status row pins the whole spinner sequence")
    func spinnerFrameSequence() {
        let painted = stride(from: 0, to: 32, by: 4).map { statusRow(turnFrame(tick: $0)) }
        let glyphs = painted.map { String($0.trimmingCharacters(in: .whitespaces).first ?? " ") }
        #expect(glyphs == ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"])
    }

    @Test("frames inside one divisor window are byte-identical")
    func framesCoalesceWithinAWindow() {
        // This is why the reference only repaints on `tick % 4 == 0`: the other
        // three frames would be identical work.
        let base = turnFrame(tick: 8).snapshot()
        for tick in 9..<12 {
            #expect(turnFrame(tick: tick).snapshot() == base)
        }
        #expect(turnFrame(tick: 12).snapshot() != base)
    }

    @Test("the monitor pulse runs at half the spinner's rate")
    func monitorPulse() {
        #expect(PagerMotion.monitorPulseDivisor == 8)
        let sequence = (0..<32).map { PagerMotion.monitorPulseFrame(tick: $0) }
        #expect(sequence[0] == "○")
        #expect(sequence[8] == "◎")
        #expect(sequence[16] == "◉")
        #expect(sequence[24] == "◎")
        #expect(sequence[31] == "◎")
    }

    @Test("the dot spinner shares the braille spinner's period")
    func dotSpinnerPeriod() {
        #expect(PagerGlyphs.dotSpinner.count == PagerGlyphs.brailleSpinner.count)
        #expect(PagerMotion.dotFrame(tick: 0) == PagerMotion.dotFrame(tick: 32))
    }
}

// MARK: - Pulse and wave

@Suite("Pulse and wave")
struct PagerPulseTests {
    @Test("pulse is sin² — always in range, and starts dark")
    func pulseRange() {
        for tick in 0..<200 {
            let value = PagerMotion.pulseBrightness(tick: tick, speed: PagerMotion.userWaitingPulseSpeed)
            #expect(value >= 0 && value <= 1)
        }
        #expect(PagerMotion.pulseBrightness(tick: 0, speed: 0.08) == 0)
    }

    @Test("the pulse completes a cycle in the reference's ~39 ticks")
    func pulsePeriod() {
        // Period is π / speed ticks; at 0.08 that is ~39, or ~1.31 s at 30 fps.
        let period = Double.pi / PagerMotion.userWaitingPulseSpeed
        #expect(abs(period - 39.27) < 0.1)
        let start = PagerMotion.pulseBrightness(tick: 0, speed: 0.08)
        let full = PagerMotion.pulseBrightness(tick: Int(period.rounded()), speed: 0.08)
        #expect(abs(full - start) < 0.01)
    }

    @Test("the pending diamond never fades out entirely")
    func pendingDiamondFloor() {
        let theme = PagerRenderTheme.grokNight
        // At tick 0 the pulse is at its darkest; the 0.3 floor is what keeps the
        // glyph from vanishing and reading as a glitch.
        let darkest = PagerMotion.pendingDiamondColor(theme: theme, accent: theme.accentUser, tick: 0)
        #expect(darkest != theme.bgBase)
        #expect(darkest == blendPagerColors(theme.bgBase, theme.accentUser, 0.3))
    }

    @Test("the wave offsets by row, so a block reads as motion travelling down it")
    func waveIsSpatial() {
        let top = PagerMotion.waveBrightness(tick: 10, row: 0)
        let middle = PagerMotion.waveBrightness(tick: 10, row: 8)
        #expect(top != middle)
        // One wavelength apart is the same phase.
        #expect(abs(PagerMotion.waveBrightness(tick: 10, row: 0)
            - PagerMotion.waveBrightness(tick: 10, row: 32)) < 0.0001)
    }

    @Test("a turn blocked on the user freezes the wave at full accent")
    func pendingUserInputFreezesTheWave() {
        let theme = PagerRenderTheme.grokNight
        let moving = PagerMotion.runningAccentColor(
            theme: theme, accent: theme.accentRunning, tick: 7, row: 3
        )
        let frozen = PagerMotion.runningAccentColor(
            theme: theme, accent: theme.accentRunning, tick: 7, row: 3, isPendingUserInput: true
        )
        #expect(frozen == theme.accentRunning)
        #expect(moving != frozen)
    }

    @Test("motion off pins every animated color to its resting value")
    func motionOffIsStill() {
        let theme = PagerRenderTheme.grokNight
        let a = PagerMotion.runningAccentColor(
            theme: theme, accent: theme.accentRunning, tick: 3, row: 1, motionEnabled: false
        )
        let b = PagerMotion.runningAccentColor(
            theme: theme, accent: theme.accentRunning, tick: 91, row: 17, motionEnabled: false
        )
        #expect(a == b)
    }
}

// MARK: - Shimmer

@Suite("Welcome logo shimmer")
struct PagerShimmerTests {
    @Test("the shimmer is wall-clock driven at 12 fps")
    func shimmerRate() {
        #expect(PagerMotion.shimmerFPS == 12.0)
        #expect(PagerMotion.shimmerFrame(atSeconds: 0) == 0)
        #expect(PagerMotion.shimmerFrame(atSeconds: 0.5) == 6)
        #expect(PagerMotion.shimmerFrame(atSeconds: 1.0) == 12)
        // The welcome screen only repaints when this integer advances, so two
        // times inside one frame must not produce a redraw.
        #expect(PagerMotion.shimmerFrame(atSeconds: 0.50)
            == PagerMotion.shimmerFrame(atSeconds: 0.58))
    }

    @Test("the band sweeps, then parks off-screen for most of the cycle")
    func shimmerRests() {
        // Sweep is 32% of a 4 s cycle: about 1.3 s of glint, 2.7 s of rest.
        let duringSweep = (0...12).map {
            PagerMotion.shimmerOpacity(diagonal: 0.5, seconds: Double($0) * 0.1)
        }
        #expect(duringSweep.contains { $0 > PagerMotion.Shimmer.pulse })

        // Deep in the rest window only the slow breath remains.
        let atRest = PagerMotion.shimmerOpacity(diagonal: 0.5, seconds: 2.5)
        #expect(atRest <= PagerMotion.Shimmer.pulse + 0.0001)
    }

    @Test("opacity stays in range across a whole cycle at every position")
    func shimmerBounded() {
        for step in 0..<400 {
            let seconds = Double(step) * 0.01
            for diagonal in stride(from: 0.0, through: 1.0, by: 0.1) {
                let value = PagerMotion.shimmerOpacity(diagonal: diagonal, seconds: seconds)
                #expect(value >= 0 && value <= 1)
            }
        }
    }

    @Test("the shimmer repeats exactly on its cycle")
    func shimmerIsPeriodic() {
        // The sweep is 4 s and the breath is 5 s, so the compound period is 20 s.
        let first = PagerMotion.shimmerOpacity(diagonal: 0.3, seconds: 1.1)
        let later = PagerMotion.shimmerOpacity(diagonal: 0.3, seconds: 21.1)
        #expect(abs(first - later) < 0.0001)
    }

    @Test("motion off paints the logo at full brightness rather than mid-shimmer")
    func shimmerOffIsFullBrightness() {
        let theme = PagerRenderTheme.grokNight
        #expect(PagerMotion.shimmerColor(
            theme: theme, diagonal: 0.4, seconds: 1.2, motionEnabled: false
        ) == theme.textPrimary)
    }
}

// MARK: - Finish flash

@Suite("Finish flash")
struct PagerFinishFlashTests {
    @Test("a finished block flashes for 400 ms and then goes static")
    func flashWindow() {
        #expect(PagerMotion.finishFlashDuration == 0.400)
        #expect(PagerMotion.isFlashing(finishedAt: 10.0, now: 10.1))
        #expect(PagerMotion.isFlashing(finishedAt: 10.0, now: 10.399))
        #expect(!PagerMotion.isFlashing(finishedAt: 10.0, now: 10.400))
        #expect(!PagerMotion.isFlashing(finishedAt: 10.0, now: 12.0))
    }

    @Test("the flash color is the full accent, then a dimmed rest")
    func flashColor() {
        let theme = PagerRenderTheme.grokNight
        let flashing = PagerMotion.finishFlashColor(
            theme: theme, accent: theme.accentSuccess, finishedAt: 0, now: 0.2
        )
        let resting = PagerMotion.finishFlashColor(
            theme: theme, accent: theme.accentSuccess, finishedAt: 0, now: 1.0
        )
        #expect(flashing == theme.accentSuccess)
        #expect(resting != theme.accentSuccess)
    }
}

// MARK: - Tick demand

@Suite("Tick demand")
struct PagerTickDemandTests {
    @Test("a still screen arms no tick at all")
    func idleDemandsNothing() {
        #expect(PagerMotionState().demand == .none)
    }

    @Test("a running turn or a spinning background task demands the fast tick")
    func fastDemand() {
        #expect(PagerMotionState(hasRunningTurn: true).demand == .fast)
        #expect(PagerMotionState(hasVisibleRunningBlock: true).demand == .fast)
        #expect(PagerMotionState(hasBackgroundTasks: true).demand == .fast)
    }

    @Test("the welcome logo alone only demands the slow tick")
    func welcomeIsSlow() {
        #expect(PagerMotionState(showsWelcomeLogo: true).demand == .slow)
        #expect(PagerMotion.slowTickInterval == 0.083)
        // The slow tick is chosen to sample every shimmer frame.
        #expect(abs(1.0 / PagerMotion.slowTickInterval - PagerMotion.shimmerFPS) < 0.1)
    }

    @Test("a pending flash rides along and never raises the demand on its own")
    func flashDoesNotDemandTicks() {
        #expect(PagerMotionState(hasPendingFlash: true).demand == .none)
    }

    @Test("motion off collapses every demand to none")
    func motionOffStopsTheClock() {
        let state = PagerMotionState(
            hasRunningTurn: true, hasVisibleRunningBlock: true,
            hasBackgroundTasks: true, showsWelcomeLogo: true, motionEnabled: false
        )
        #expect(state.demand == .none)
    }

    @Test("an off-screen running block does not force redraws of a still screen")
    func offscreenWorkIsNotAnimated() {
        // The distinction the reference is careful about: work is running, but
        // nothing the user can see is moving.
        let offscreen = PagerMotionState(hasRunningTurn: false, hasVisibleRunningBlock: false)
        #expect(offscreen.demand == .none)
    }

    @Test("the tick interval follows fps and clamps to the reference's range")
    func tickInterval() {
        #expect(abs(PagerMotion.tickInterval(fps: 30) - 1.0 / 30) < 0.0001)
        #expect(abs(PagerMotion.tickInterval(fps: 60) - 1.0 / 60) < 0.0001)
        #expect(PagerMotion.tickInterval(fps: 0) == 1.0)
        #expect(abs(PagerMotion.tickInterval(fps: 1000) - 1.0 / 60) < 0.0001)
    }
}

// MARK: - Frame pacing

@Suite("Frame pacing")
struct PagerFrameClockTests {
    @Test("the first paint is immediate")
    func firstPaintIsImmediate() {
        // `#expect` expands its argument into a closure whose `$0` is
        // immutable, so a mutating call has to be hoisted out of the macro.
        var clock = PagerFrameClock()
        let requested = clock.requestPaint(at: 0)
        #expect(requested)
        let began = clock.beginFrame(at: 0)
        #expect(began)
        clock.endFrame()
    }

    @Test("requests inside one cadence window coalesce into a single frame")
    func coalescing() {
        var clock = PagerFrameClock(cadence: 0.016)
        _ = clock.requestPaint(at: 0)
        _ = clock.beginFrame(at: 0)
        clock.endFrame()

        // Five requests arrive over the next 10 ms; none may paint.
        for step in 1...5 {
            let painted = clock.requestPaint(at: Double(step) * 0.002)
            #expect(!painted)
        }
        let earlyFrame = clock.beginFrame(at: 0.010)
        #expect(!earlyFrame)
        // At the window boundary exactly one frame comes due.
        #expect(clock.isPaintDue(at: 0.016))
        let boundaryFrame = clock.beginFrame(at: 0.016)
        #expect(boundaryFrame)
        clock.endFrame()
        // And the backlog is gone — five requests produced one frame.
        let afterBacklog = clock.beginFrame(at: 0.100)
        #expect(!afterBacklog)
    }

    @Test("a frame in flight blocks the next one — the back-pressure rule")
    func backPressure() {
        var clock = PagerFrameClock(cadence: 0.001)
        _ = clock.requestPaint(at: 0)
        let firstFrame = clock.beginFrame(at: 0)
        #expect(firstFrame)
        // The terminal has not caught up yet.
        let blockedRequest = clock.requestPaint(at: 1.0)
        #expect(!blockedRequest)
        let blockedFrame = clock.beginFrame(at: 1.0)
        #expect(!blockedFrame)
        clock.endFrame()
        let releasedFrame = clock.beginFrame(at: 1.0)
        #expect(releasedFrame)
    }

    @Test("a clean frame is not repainted")
    func nothingDirtyNothingPainted() {
        var clock = PagerFrameClock()
        #expect(!clock.isPaintDue(at: 0))
        let began = clock.beginFrame(at: 0)
        #expect(!began)
    }

    @Test("the cadence defaults to ~60 fps and honours GROK_MIN_DRAW_MS")
    func cadenceFromEnvironment() {
        #expect(PagerFrameClock.cadence(environment: [:]) == 0.016)
        #expect(PagerFrameClock.cadence(environment: ["GROK_MIN_DRAW_MS": "100"]) == 0.100)
        // Clamped into 1...100 ms, so a hostile value cannot stall or busy-loop
        // the paint thread.
        #expect(PagerFrameClock.cadence(environment: ["GROK_MIN_DRAW_MS": "5000"]) == 0.100)
        #expect(PagerFrameClock.cadence(environment: ["GROK_MIN_DRAW_MS": "0"]) == 0.001)
        #expect(PagerFrameClock.cadence(environment: ["GROK_MIN_DRAW_MS": "nonsense"]) == 0.016)
    }
}

// MARK: - Degradation

@Suite("Motion degradation")
struct PagerMotionDegradationTests {
    @Test("a dumb terminal or a pipe gets a still UI, not a broken one")
    func degradesCleanly() {
        #expect(!PagerMotionState.motionEnabled(environment: ["TERM": "xterm"], isTTY: false))
        #expect(!PagerMotionState.motionEnabled(environment: ["TERM": "dumb"], isTTY: true))
        #expect(!PagerMotionState.motionEnabled(environment: [:], isTTY: true))
        #expect(PagerMotionState.motionEnabled(environment: ["TERM": "xterm-256color"], isTTY: true))
    }

    @Test("GROK_NO_MOTION is an explicit off switch")
    func explicitOptOut() {
        let env = ["TERM": "xterm-256color", "GROK_NO_MOTION": "1"]
        #expect(!PagerMotionState.motionEnabled(environment: env, isTTY: true))
        // `0` and empty mean "not set", so the variable can be exported blank.
        #expect(PagerMotionState.motionEnabled(
            environment: ["TERM": "xterm-256color", "GROK_NO_MOTION": "0"], isTTY: true
        ))
    }
}
