// MouseScrollStreamTests.swift
//
// Representative shapes from pinned Rust `input/mouse/tests.rs` at 650c1db7.
// Every status-returning call is asserted. Clocks are injected; no sleeps.

import Foundation
import Testing
@testable import OpenGrokTerminalCore

private func ms(_ value: Int64) -> Int64 { value * 1_000_000 }

private func makeConfig(
    eventsPerTick: UInt16,
    mode: ScrollInputMode
) -> ScrollConfig {
    ScrollConfig.from(
        brand: .unknown,
        overrides: ScrollConfigOverrides(
            eventsPerTick: eventsPerTick,
            mode: mode
        )
    )
}

/// Drive the state machine by its own suggested deadlines until finalize.
private func driveSuggestedTicks(
    _ state: inout MouseScrollState,
    now start: Int64
) -> [(Int64, Int)] {
    var now = start
    var ticks: [(Int64, Int)] = []
    for _ in 0..<64 {
        guard let delay = state.deadline(nowNanos: now) else {
            return ticks
        }
        now += max(delay, ms(1))
        let update = state.onTick(nowNanos: now)
        ticks.append((now, update.lines))
        // Status-returning: nextTickIn is nil only after finalize (or when
        // the post-gap coast has nothing left — then the next deadline call
        // returns nil and we exit above).
        if state.hasActiveStream {
            #expect(update.nextTickInNanos != nil || state.deadline(nowNanos: now) != nil)
        } else {
            #expect(update.nextTickInNanos == nil)
            #expect(state.deadline(nowNanos: now) == nil)
        }
    }
    Issue.record("stream did not finalize within 64 suggested ticks")
    return ticks
}

@Suite("Mouse scroll stream — wheel pricing")
struct MouseScrollWheelPricingTests {
    @Test("3 reports → 3 lines on default ept=3 Auto (wheel tick promote)")
    func threeReportsThreeLines() {
        let config = makeConfig(eventsPerTick: 3, mode: .auto)
        var state = MouseScrollState(nowNanos: 0)

        let u1 = state.onScrollEvent(nowNanos: ms(1), direction: .down, config: config)
        #expect(u1.lines == 0)
        let u2 = state.onScrollEvent(nowNanos: ms(2), direction: .down, config: config)
        #expect(u2.lines == 0)
        let u3 = state.onScrollEvent(nowNanos: ms(3), direction: .down, config: config)
        #expect(u3.lines == 3)
        #expect(state.hasActiveStream)
    }

    @Test("9 events at ept=9 still price one 3-line notch")
    func nineEventsThreeLines() {
        let config = makeConfig(eventsPerTick: 9, mode: .auto)
        var state = MouseScrollState(nowNanos: 0)
        var update = ScrollUpdate()
        for idx in 0..<9 {
            update = state.onScrollEvent(
                nowNanos: ms(Int64(idx) + 1),
                direction: .down,
                config: config
            )
        }
        #expect(update.lines == 3)
    }

    @Test("Discrete wheel tick flushes promptly on promotion")
    func discreteWheelFlushPrompt() {
        let config = makeConfig(eventsPerTick: 3, mode: .auto)
        var state = MouseScrollState(nowNanos: 0)
        let u1 = state.onScrollEvent(nowNanos: ms(1), direction: .down, config: config)
        let u2 = state.onScrollEvent(nowNanos: ms(2), direction: .down, config: config)
        let u3 = state.onScrollEvent(nowNanos: ms(3), direction: .down, config: config)
        #expect(u1.lines + u2.lines + u3.lines == 3)
    }
}

@Suite("Mouse scroll stream — deadlines and cadence")
struct MouseScrollDeadlineTests {
    @Test("Idle wheel stream finalizes just past the 80ms gap without 16ms spin")
    func finalizeAtEightyMsGap() {
        let config = makeConfig(eventsPerTick: 3, mode: .auto)
        var state = MouseScrollState(nowNanos: 0)
        var last = Int64(0)
        var promotedLines = 0
        for i in 0..<3 {
            last = ms(1 + Int64(i))
            let update = state.onScrollEvent(nowNanos: last, direction: .down, config: config)
            promotedLines += update.lines
            #expect(update.nextTickInNanos != nil)
        }
        #expect(promotedLines == 3)
        #expect(state.hasActiveStream)

        let delay = state.deadline(nowNanos: last)
        #expect(delay == mouseScrollStreamGapNanos)

        let ticks = driveSuggestedTicks(&state, now: last)
        #expect(!state.hasActiveStream)
        let finalizeAt = ticks.last?.0
        #expect(finalizeAt != nil)
        if let finalizeAt {
            let gap = finalizeAt - last
            #expect(gap > mouseScrollStreamGapNanos)
            #expect(gap <= mouseScrollStreamGapNanos + ms(2))
        }
        #expect(ticks.count <= 2)
    }

    @Test("Residual backlog drains on exact 16ms cadence slots")
    func residualSixteenMsDrain() {
        let config = makeConfig(eventsPerTick: 3, mode: .trackpad)
        var state = MouseScrollState(nowNanos: 0)
        var last = Int64(0)
        for i in 0..<8 {
            last = ms(1 + Int64(i) * 2)
            let update = state.onScrollEvent(nowNanos: last, direction: .down, config: config)
            _ = update.lines
        }
        #expect(state.hasActiveStream)

        let ticks = driveSuggestedTicks(&state, now: last)
        let flushes = ticks.filter { $0.1 != 0 }
        #expect(flushes.count >= 2)
        for pair in zip(flushes, flushes.dropFirst()) {
            #expect(pair.1.0 - pair.0.0 == mouseScrollRedrawCadenceNanos)
        }
        #expect(!state.hasActiveStream)
    }

    @Test("No flush starvation when events stop mid-cadence")
    func noStarvationMidCadence() {
        let config = makeConfig(eventsPerTick: 3, mode: .trackpad)
        var state = MouseScrollState(nowNanos: 0)
        let u1 = state.onScrollEvent(nowNanos: ms(1), direction: .down, config: config)
        #expect(u1.lines == 0)
        let last = ms(5)
        let u2 = state.onScrollEvent(nowNanos: last, direction: .down, config: config)
        #expect(u2.lines == 0)

        let ticks = driveSuggestedTicks(&state, now: last)
        let firstFlush = ticks.first(where: { $0.1 != 0 })
        #expect(firstFlush != nil)
        if let firstFlush {
            #expect(firstFlush.0 - last <= mouseScrollRedrawCadenceNanos)
        }
    }
}

@Suite("Mouse scroll stream — direction and invert")
struct MouseScrollDirectionTests {
    @Test("Direction flip closes previous stream without opposite backlog")
    func directionFlip() {
        let config = makeConfig(eventsPerTick: 3, mode: .auto)
        var state = MouseScrollState(nowNanos: 0)
        let a = state.onScrollEvent(nowNanos: ms(1), direction: .up, config: config)
        let b = state.onScrollEvent(nowNanos: ms(2), direction: .up, config: config)
        let c = state.onScrollEvent(nowNanos: ms(3), direction: .up, config: config)
        #expect(a.lines + b.lines + c.lines == -3)

        let flip = state.onScrollEvent(nowNanos: ms(4), direction: .down, config: config)
        // Cancelled backlog → only new-direction contribution (may be 0 until
        // cadence; wheel-like min can mint ≥0).
        #expect(flip.lines >= 0)
        #expect(state.hasActiveStream)
    }

    @Test("invert_direction flips sign end-to-end")
    func invertDirection() {
        func run(invert: Bool) -> Int {
            let config = ScrollConfig.from(
                brand: .unknown,
                overrides: ScrollConfigOverrides(invertDirection: invert)
            )
            var state = MouseScrollState(nowNanos: 0)
            var total = 0
            var at: Int64 = 0
            for i in 0..<6 {
                at = ms(1 + Int64(i) * 8)
                let update = state.onScrollEvent(nowNanos: at, direction: .down, config: config)
                total += update.lines
            }
            for (_, lines) in driveSuggestedTicks(&state, now: at) {
                total += lines
            }
            return total
        }
        let normal = run(invert: false)
        let inverted = run(invert: true)
        #expect(normal > 0)
        #expect(inverted == -normal)
    }
}

@Suite("Mouse scroll stream — speed and overrides")
struct MouseScrollSpeedOverrideTests {
    @Test("speed_to_multiplier: 1 → 0.1, 50 → 1.0, 100 → 6.0; clamps malformed")
    func speedMultiplierTable() {
        #expect(abs(mouseScrollSpeedToMultiplier(50) - 1.0) < 0.0001)
        #expect(abs(mouseScrollSpeedToMultiplier(1) - 0.1) < 0.0001)
        #expect(abs(mouseScrollSpeedToMultiplier(100) - 6.0) < 0.0001)
        #expect(abs(mouseScrollSpeedToMultiplier(0) - 0.1) < 0.0001)
        #expect(abs(mouseScrollSpeedToMultiplier(999) - 6.0) < 0.0001)
        #expect(abs(mouseScrollSpeedToMultiplier(-3) - 0.1) < 0.0001)
    }

    @Test("Speed 1/50/100 scales forced-wheel delivery")
    func speedScalesWheelDelivery() {
        func total(speed: Int) -> Int {
            let config = ScrollConfig.from(
                brand: .unknown,
                overrides: ScrollConfigOverrides(
                    mode: .wheel,
                    speedMultiplier: mouseScrollSpeedToMultiplier(speed)
                )
            )
            var state = MouseScrollState(nowNanos: 0)
            var sum = 0
            var at: Int64 = 0
            for i in 0..<30 {
                at = ms(1 + Int64(i) * 8)
                let update = state.onScrollEvent(nowNanos: at, direction: .down, config: config)
                sum += update.lines
            }
            for (_, lines) in driveSuggestedTicks(&state, now: at) {
                sum += lines
            }
            #expect(!state.hasActiveStream)
            return sum
        }
        let at50 = total(speed: 50)
        let at1 = total(speed: 1)
        let at100 = total(speed: 100)
        #expect(at50 == 30) // 30 events / 3 ept × 3 lpt × 1.0
        #expect(at1 < at50)
        #expect(at100 > at50)
    }

    @Test("scroll_lines override beats VS Code profile; unset keeps it")
    func scrollLinesOverride() {
        let unset = ScrollConfig.from(brand: .vsCode)
        #expect(unset.wheelLinesPerTick == 3)
        #expect(unset.trackpadLinesPerTick == 15)

        let set = ScrollConfig.from(
            brand: .vsCode,
            overrides: ScrollConfigOverrides(
                wheelLinesPerTick: 4,
                trackpadLinesPerTick: 4
            )
        )
        #expect(set.wheelLinesPerTick == 4)
        #expect(set.trackpadLinesPerTick == 4)

        let zeroClamped = ScrollConfig.from(
            brand: .vsCode,
            overrides: ScrollConfigOverrides(
                eventsPerTick: 0,
                wheelLinesPerTick: 0,
                trackpadLinesPerTick: 0,
                trackpadAccelMax: 0,
                speedMultiplier: -1
            )
        )
        #expect(zeroClamped.eventsPerTick == 1)
        #expect(zeroClamped.wheelLinesPerTick == 1)
        #expect(zeroClamped.trackpadLinesPerTick == 1)
        #expect(zeroClamped.trackpadAccelMax == 1)
        #expect(zeroClamped.speedMultiplier == 1.0)
    }
}

@Suite("Mouse scroll stream — terminal and remux profiles")
struct MouseScrollProfileTests {
    @Test("iTerm2 and WezTerm are 1/1 wheel profiles")
    func itermAndWezTerm() {
        for brand in [MouseScrollTerminalBrand.iterm2, .wezTerm] {
            let config = ScrollConfig.from(brand: brand)
            #expect(config.eventsPerTick == 1, "\(brand)")
            #expect(config.wheelLinesPerTick == 1, "\(brand)")
            #expect(config.trackpadLinesPerTick == 3, "\(brand)")
        }
    }

    @Test("VS Code embed trackpad profile: ept=1, trackpad LPT=15, wide bands")
    func vscodeTrackpadProfile() {
        let vscode = ScrollConfig.from(brand: .vsCode)
        #expect(vscode.eventsPerTick == 1)
        #expect(vscode.wheelLinesPerTick == 3)
        #expect(vscode.trackpadLinesPerTick == 15)
        #expect(vscode.accelIntervalFastMs == 25.0)
        #expect(vscode.accelIntervalMediumMs == 50.0)
        #expect(vscode.trackpadDetectMaxIntervalMs == 60.0)

        for brand in [MouseScrollTerminalBrand.cursor, .windsurf] {
            let cfg = ScrollConfig.from(brand: brand)
            #expect(cfg.trackpadLinesPerTick == vscode.trackpadLinesPerTick)
            #expect(cfg.accelIntervalFastMs == vscode.accelIntervalFastMs)
            #expect(cfg.accelIntervalMediumMs == vscode.accelIntervalMediumMs)
            #expect(cfg.trackpadDetectMaxIntervalMs == vscode.trackpadDetectMaxIntervalMs)
            #expect(cfg.eventsPerTick == vscode.eventsPerTick)
        }

        let zed = ScrollConfig.from(brand: .zed)
        #expect(zed.eventsPerTick == 1)
        #expect(zed.trackpadLinesPerTick == mouseScrollDefaultTrackpadLinesPerTick)
        #expect(zed.accelIntervalFastMs == mouseScrollDefaultAccelIntervalFastMs)
    }

    @Test("Remux (tmux/screen/zellij/herdr) forces conservative 1/1 regardless of brand")
    func remuxConservative() {
        let brands: [MouseScrollTerminalBrand] = [
            .ghostty, .iterm2, .appleTerminal, .wezTerm, .kitty, .vsCode, .cursor, .zed, .unknown,
        ]
        let reference = ScrollConfig.from(brand: .unknown, multiplexer: .tmux)
        for mux in [MouseScrollMultiplexer.tmux, .screen, .zellij, .herdr] {
            for brand in brands {
                let cfg = ScrollConfig.from(brand: brand, multiplexer: mux)
                #expect(cfg.eventsPerTick == 1, "\(brand) under \(mux)")
                #expect(cfg.wheelLinesPerTick == 1, "\(brand) under \(mux)")
                #expect(cfg == reference, "\(brand) under \(mux) brand-independent")
            }
        }
        for mux in [MouseScrollMultiplexer.undetected, .cmux] {
            for brand in brands {
                let cfg = ScrollConfig.from(brand: brand, multiplexer: mux)
                let plain = ScrollConfig.from(brand: brand)
                #expect(cfg == plain, "\(brand) under \(mux) keeps brand profile")
            }
        }
        let overridden = ScrollConfig.from(
            brand: .ghostty,
            multiplexer: .tmux,
            overrides: ScrollConfigOverrides(eventsPerTick: 5)
        )
        #expect(overridden.eventsPerTick == 5)
    }

    @Test("MouseWheelTuning.forTerminalProgram delegates to ScrollConfig brand table")
    func wheelTuningDelegates() {
        let iterm = MouseWheelTuning.forTerminalProgram("iTerm.app")
        #expect(iterm.linesPerTick == 1)
        #expect(iterm.eventsPerTick == 1)
        let vscode = MouseWheelTuning.forTerminalProgram("vscode")
        #expect(vscode.linesPerTick == 3)
        #expect(vscode.eventsPerTick == 1)
        let unknown = MouseWheelTuning.forTerminalProgram(nil)
        #expect(unknown.linesPerTick == 3)
        #expect(unknown.eventsPerTick == 3)
    }
}

@Suite("Mouse scroll stream — viewport cap")
struct MouseScrollViewportCapTests {
    @Test("flush_cap floors at 6 and scales with viewport/2")
    func flushCap() {
        let base = makeConfig(eventsPerTick: 3, mode: .trackpad)
        #expect(base.withViewportHeight(4).flushCap == 6)
        #expect(base.withViewportHeight(0).flushCap == 6)
        #expect(base.withViewportHeight(60).flushCap == 30)
        #expect(mouseScrollMinDeltaPerFlush == 6)
    }

    @Test("Tiny viewport still scrolls under the floor cap")
    func tinyViewportStillScrolls() {
        let config = makeConfig(eventsPerTick: 3, mode: .trackpad).withViewportHeight(4)
        var state = MouseScrollState(nowNanos: 0)
        var total = 0
        var at: Int64 = 0
        for i in 0..<12 {
            at = ms(1 + Int64(i) * 4)
            let update = state.onScrollEvent(nowNanos: at, direction: .down, config: config)
            #expect(update.lines <= 6)
            total += update.lines
        }
        for (_, lines) in driveSuggestedTicks(&state, now: at) {
            #expect(lines <= 6)
            total += lines
        }
        #expect(total > 0)
    }

    @Test("Legit ept=1 wheel notches never hit the cap and deliver 1 line each")
    func ept1WheelUnderCap() {
        let config = ScrollConfig.from(brand: .iterm2).withViewportHeight(20)
        #expect(config.eventsPerTick == 1)
        #expect(config.wheelLinesPerTick == 1)
        var state = MouseScrollState(nowNanos: 0)
        var total = 0
        var at: Int64 = 0
        for i in 0..<10 {
            at = ms(1 + Int64(i) * 40)
            let update = state.onScrollEvent(nowNanos: at, direction: .down, config: config)
            #expect(update.lines < mouseScrollMinDeltaPerFlush)
            total += update.lines
        }
        for (_, lines) in driveSuggestedTicks(&state, now: at) {
            #expect(lines < mouseScrollMinDeltaPerFlush)
            total += lines
        }
        #expect(total == 10)
    }
}

@Suite("Mouse scroll stream — gap finalize")
struct MouseScrollGapFinalizeTests {
    @Test("Stream gap leaves nextTick nil after catch-up; next tick finalizes")
    func streamGapCloses() {
        let config = makeConfig(eventsPerTick: 3, mode: .wheel)
        var state = MouseScrollState(nowNanos: 0)
        let start = state.onScrollEvent(nowNanos: ms(1), direction: .down, config: config)
        #expect(start.nextTickInNanos != nil)
        #expect(state.hasActiveStream)

        // Pin shape: first overdue tick may coast-flush and report no further
        // tick; finalize is deferred to the following wakeup when flushable
        // is already zero (mouse/tests.rs:356-370 + finalize-decel).
        let update = state.onTick(nowNanos: ms(100))
        #expect(update.nextTickInNanos == nil)
        if state.hasActiveStream {
            #expect(state.deadline(nowNanos: ms(100)) == 0)
            let finalize = state.onTick(nowNanos: ms(101))
            #expect(finalize.nextTickInNanos == nil)
        }
        #expect(!state.hasActiveStream)
        #expect(state.deadline(nowNanos: ms(101)) == nil)
    }

    @Test("cancelStream drops pending momentum")
    func cancelDropsMomentum() {
        let config = makeConfig(eventsPerTick: 3, mode: .trackpad)
        var state = MouseScrollState(nowNanos: 0)
        let update = state.onScrollEvent(nowNanos: 0, direction: .up, config: config)
        #expect(update.lines == 0)
        #expect(state.hasActiveStream)
        state.cancelStream()
        #expect(!state.hasActiveStream)
        let tick = state.onTick(nowNanos: ms(1000))
        #expect(tick.lines == 0)
        #expect(tick.nextTickInNanos == nil)
    }
}

@Suite("Mouse scroll stream — TimeInterval API")
struct MouseScrollTimeIntervalAPITests {
    @Test("TimeInterval overloads match nanos clock")
    func timeIntervalParity() {
        let config = makeConfig(eventsPerTick: 3, mode: .auto)
        var a = MouseScrollState(nowNanos: 0)
        var b = MouseScrollState(now: 0)
        for i in 1...3 {
            let ua = a.onScrollEvent(nowNanos: ms(Int64(i)), direction: .down, config: config)
            let ub = b.onScrollEvent(now: TimeInterval(i) / 1000.0, direction: .down, config: config)
            #expect(ua.lines == ub.lines)
        }
        let da = a.deadline(nowNanos: ms(3))
        let db = b.deadline(now: 0.003)
        #expect(da != nil && db != nil)
        if let da, let db {
            #expect(abs(TimeInterval(da) / 1_000_000_000 - db) < 0.000_001)
        }
    }
}
