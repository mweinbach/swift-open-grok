// PagerMotion.swift
//
// Everything the TUI animates, and the pacing that decides when it repaints.
//
// Ports `xai-grok-pager/src/views/turn_status.rs` (spinner and pulse cadence),
// `xai-grok-pager-render/src/theme/tokyonight.rs:300-333` (pulse and wave),
// `src/views/welcome/logo.rs` (shimmer), `src/app/event_loop.rs:422-517` and
// `:3170-3188` (the presenter and the tick scheduler) at upstream 9ed09e2a.
//
// Two clocks, deliberately separate — the reference's design and the reason its
// idle CPU is zero:
//
//   1. An *animation tick* that only exists while something on screen is
//      actually moving. Nothing moving means no tick is armed at all.
//   2. A *paint cadence* that coalesces however many redraw requests arrive
//      inside one frame window into a single frame.
//
// Every function here is pure in its inputs. There is no ambient clock, so a
// test pins a frame sequence by passing ticks and timestamps.

import Foundation
import OpenGrokTerminalCore

// MARK: - Cadence constants

public enum PagerMotion {
    /// `SPINNER_DIVISOR` (`turn_status.rs:32`) — the braille spinner advances
    /// every fourth tick, so at 30 fps a frame lasts ~133 ms and the eight-frame
    /// loop takes ~1.07 s.
    public static let spinnerDivisor = 4

    /// `MONITOR_PULSE_DIVISOR` (`turn_status.rs:33`) — the idle monitor glyph
    /// runs at half the spinner's rate.
    public static let monitorPulseDivisor = 8

    /// `USER_WAITING_PULSE_SPEED` (`turn_status.rs:48`). At 30 fps this is a
    /// ~1.31 s bright→dim→bright cycle.
    public static let userWaitingPulseSpeed = 0.08

    /// `WAVE_SPEED` (`entry_renderer.rs:23`) — the running-block accent wave
    /// crosses a block in about 40 ticks.
    public static let waveSpeed = 0.15

    /// Default `wave_rows` (`appearance/config.rs:377`): the row count one full
    /// wavelength spans.
    public static let defaultWaveRows = 32

    /// `FINISH_FLASH_DURATION_MS` (`scrollback/state/types.rs:84`) — a finished
    /// block keeps its bright accent this long, then goes static.
    public static let finishFlashDuration: TimeInterval = 0.400

    /// `SHIMMER_FPS` (`welcome/logo.rs:70`). The welcome logo is driven by wall
    /// time rather than the tick counter so it looks identical at any fps.
    public static let shimmerFPS = 12.0

    /// The animation tick's default rate and the range the reference clamps a
    /// configured `[animation].fps` into (`appearance/config.rs:371-397`).
    public static let defaultFPS = 30
    public static let minimumFPS = 1
    public static let maximumFPS = 60

    /// `SLOW_TICK_INTERVAL` (`app_view.rs:259`) ≈ 12 fps, chosen to match
    /// `shimmerFPS` so a slow tick still samples every shimmer frame.
    public static let slowTickInterval: TimeInterval = 0.083

    /// `DISPLAY_REFRESH_DEFAULT_CADENCE_MS` (`display_refresh.rs:12`) — a ~60 fps
    /// ceiling on painting, independent of how fast the tick runs.
    public static let defaultPaintCadence: TimeInterval = 0.016
    /// The band `GROK_MIN_DRAW_MS` is clamped into
    /// (`display_refresh_startup.rs:28-39`).
    public static let minimumPaintCadence: TimeInterval = 0.001
    public static let maximumPaintCadence: TimeInterval = 0.100

    /// `tick_interval` — the gap between animation ticks at a given fps.
    public static func tickInterval(fps: Int) -> TimeInterval {
        let clamped = min(max(fps, minimumFPS), maximumFPS)
        return 1.0 / Double(clamped)
    }
}

// MARK: - Spinners

extension PagerMotion {
    /// The braille spinner's current glyph. Negative ticks are folded rather
    /// than trapping, so a caller that resets a counter cannot crash a frame.
    public static func brailleFrame(tick: Int) -> String {
        frame(from: PagerGlyphs.brailleSpinner, tick: tick, divisor: spinnerDivisor)
    }

    /// The idle monitor pulse (`○ ◎ ◉ ◎`, `glyphs.rs:148-156`).
    public static let monitorPulseFrames = ["\u{25CB}", "\u{25CE}", "\u{25C9}", "\u{25CE}"]

    public static func monitorPulseFrame(tick: Int) -> String {
        frame(from: monitorPulseFrames, tick: tick, divisor: monitorPulseDivisor)
    }

    /// The dot spinner (`glyphs.rs:246-256`). Its four glyphs are listed twice
    /// upstream so it shares the braille spinner's eight-frame period and the
    /// two stay in phase.
    public static func dotFrame(tick: Int) -> String {
        frame(from: PagerGlyphs.dotSpinner, tick: tick, divisor: spinnerDivisor)
    }

    static func frame(from frames: [String], tick: Int, divisor: Int) -> String {
        guard !frames.isEmpty else { return "" }
        let step = divisor > 0 ? divisor : 1
        // Swift's `/` truncates toward zero, so a negative tick would step
        // backwards through the loop asymmetrically; flooring keeps the cadence
        // even on both sides of zero.
        let index = Int((Double(tick) / Double(step)).rounded(.down)) % frames.count
        return frames[index < 0 ? index + frames.count : index]
    }
}

// MARK: - Pulse and wave

extension PagerMotion {
    /// `pulse_brightness` (`tokyonight.rs:329-333`) — `sin²(tick · speed)`, so
    /// the result is always in `0...1` and the cycle is `π / speed` ticks.
    public static func pulseBrightness(tick: Int, speed: Double) -> Double {
        let value = sin(Double(tick) * speed)
        return value * value
    }

    /// `wave_brightness` (`tokyonight.rs:300-312`) — the same pulse with a
    /// per-row phase offset, which is what makes the accent rail read as a wave
    /// travelling down a running block rather than the whole rail blinking.
    public static func waveBrightness(
        tick: Int,
        row: Int,
        waveRows: Int = defaultWaveRows,
        speed: Double = waveSpeed
    ) -> Double {
        let rows = max(1, waveRows)
        let phase = Double(tick) * speed + 2 * Double.pi * Double(row) / Double(rows)
        let value = sin(phase)
        return value * value
    }

    /// The pulsing diamond shown while a turn waits on the user
    /// (`pending_diamond_color`, `turn_status.rs:59-63`).
    ///
    /// The 0.3 floor is load-bearing: without it the glyph disappears entirely
    /// at the bottom of each cycle and reads as a rendering glitch.
    public static func pendingDiamondColor(
        theme: PagerRenderTheme,
        accent: TerminalColor,
        tick: Int,
        speed: Double = userWaitingPulseSpeed
    ) -> TerminalColor {
        let brightness = pulseBrightness(tick: tick, speed: speed)
        return blendPagerColors(theme.bgBase, accent, 0.3 + brightness * 0.7)
    }

    /// The accent color for one row of a running block.
    ///
    /// While the turn is blocked on the user the wave freezes at full accent
    /// (`entry_renderer.rs:820-829`) — motion there would say "still working"
    /// when the truth is "waiting on you".
    public static func runningAccentColor(
        theme: PagerRenderTheme,
        accent: TerminalColor,
        tick: Int,
        row: Int,
        waveRows: Int = defaultWaveRows,
        isPendingUserInput: Bool = false,
        motionEnabled: Bool = true
    ) -> TerminalColor {
        guard motionEnabled, !isPendingUserInput else { return accent }
        let brightness = waveBrightness(tick: tick, row: row, waveRows: waveRows)
        return blendPagerColors(theme.bgBase, accent, 0.35 + brightness * 0.65)
    }
}

// MARK: - Welcome logo shimmer

extension PagerMotion {
    /// `shine_opacity` constants (`welcome/logo.rs:86-107`).
    public enum Shimmer {
        /// Half-width of the travelling shine band, in diagonal units.
        public static let band = 0.38
        /// Seconds for one sweep-plus-rest cycle.
        public static let cycle = 4.0
        /// Fraction of the cycle the band spends on screen — about 1.3 s of
        /// glint followed by 2.7 s of rest.
        public static let sweepFraction = 0.32
        /// Peak added brightness at the centre of the band.
        public static let shine = 0.33
        /// Amplitude of the slow global breath under the sweep.
        public static let pulse = 0.06
        /// Period of that breath, in seconds.
        public static let pulseSeconds = 5.0
    }

    /// The integer shimmer frame for a wall-clock time. The welcome screen only
    /// repaints when this advances (`app_view.rs:5760-5766`), which is what
    /// keeps a logo animation from costing 30 fps of redraws.
    public static func shimmerFrame(atSeconds seconds: Double) -> Int {
        Int((max(0, seconds) * shimmerFPS).rounded(.down))
    }

    /// Brightness for a glyph at diagonal position `diagonal` (0...1 across the
    /// logo, bottom-left to top-right) at wall time `seconds`.
    ///
    /// Exact port of `shine_opacity` in
    /// `crates/codegen/xai-grok-pager/src/views/welcome/logo.rs` at pin
    /// `650c1db7`. A raised-cosine band sweeps the diagonal, plus a slow global
    /// breath. The band parks off-screen for most of the cycle, so the logo is
    /// still most of the time and glints briefly.
    ///
    /// The breath uses `PULSE * (0.5 - 0.5 * cos(...))` — minimum at t=0 — not
    /// the phase-inverted `0.5 * (1 + cos(...))` form.
    public static func shimmerOpacity(diagonal: Double, seconds: Double) -> Double {
        let phase = seconds.truncatingRemainder(dividingBy: Shimmer.cycle) / Shimmer.cycle
        // Sweep from just off one edge to just off the other, then clamp so the
        // band stays parked past the end for the rest of the cycle
        // (`q = (p / SWEEP_FRAC).min(1.0)` in the reference).
        let sweep = min(phase / Shimmer.sweepFraction, 1.0)
        let center = -Shimmer.band + sweep * (1 + 2 * Shimmer.band)
        let distance = abs(diagonal - center)
        let shine: Double
        if distance < Shimmer.band {
            // Raised cosine: 1 at the centre, 0 at the edges, smooth at both.
            shine = Shimmer.shine * 0.5 * (1 + cos(Double.pi * distance / Shimmer.band))
        } else {
            shine = 0
        }
        // `PULSE * (0.5 - 0.5 * cos(TAU * secs / PULSE_SECS))` — logo.rs.
        let breath = Shimmer.pulse
            * (0.5 - 0.5 * cos(2 * Double.pi * seconds / Shimmer.pulseSeconds))
        return min(1, max(0, shine + breath))
    }

    /// Normalized diagonal for one logo glyph — `render_into` in
    /// `welcome/logo.rs` at pin `650c1db7`:
    /// `(col + (rows - 1 - row)) / (cols + rows)`.
    ///
    /// Bottom-left is 0; the coordinate grows as column increases and row
    /// decreases (toward the top-right). The denominator is `cols + rows`, not
    /// the max span `(cols - 1) + (rows - 1)`. Zero-size inputs clamp to 1×1 so
    /// a single cell / empty logo never divides by zero (same `.max(1)` the
    /// reference applies before the division).
    public static func shimmerDiagonal(
        column: Int,
        row: Int,
        columns: Int,
        rows: Int
    ) -> Double {
        let cols = Double(max(1, columns))
        let rowCount = Double(max(1, rows))
        return (Double(column) + (rowCount - 1 - Double(row))) / (cols + rowCount)
    }

    /// The shimmer color for one logo glyph — `gray` at rest, blended toward
    /// `text_primary` as the band passes (`welcome/logo.rs:126-152`).
    public static func shimmerColor(
        theme: PagerRenderTheme,
        diagonal: Double,
        seconds: Double,
        motionEnabled: Bool = true
    ) -> TerminalColor {
        guard motionEnabled else { return theme.textPrimary }
        return blendPagerColors(
            theme.gray, theme.textPrimary, shimmerOpacity(diagonal: diagonal, seconds: seconds)
        )
    }
}

// MARK: - Finish flash

extension PagerMotion {
    /// Whether a block that finished at `finishedAt` is still flashing at `now`.
    ///
    /// Flashes deliberately do not demand a tick (`scrollback/state/mod.rs:507-518`):
    /// they animate opportunistically on frames that were happening anyway, and
    /// expire on their own.
    public static func isFlashing(finishedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - finishedAt < finishFlashDuration
    }

    /// The accent for a just-finished block: full brightness while flashing,
    /// then the resting color.
    public static func finishFlashColor(
        theme: PagerRenderTheme,
        accent: TerminalColor,
        finishedAt: TimeInterval,
        now: TimeInterval,
        motionEnabled: Bool = true
    ) -> TerminalColor {
        guard motionEnabled, isFlashing(finishedAt: finishedAt, now: now) else {
            return blendPagerColors(theme.bgBase, accent, 0.55)
        }
        return accent
    }
}

// MARK: - Motion snapshot

/// The animation inputs one painted frame samples: the wall-clock tick, the
/// wall-clock seconds, and whether motion is on at all.
///
/// `tick` and `seconds` are two views of the same clock — the reference keeps
/// both because the spinner/wave family counts *ticks* (`scrollback/state/
/// mod.rs:449-451`) while the shimmer and the finish flash read *wall time*
/// (`welcome/logo.rs:70`, `scrollback/state/types.rs:84`), so a frame at a
/// non-default fps animates the tick family slower without stretching the
/// 400 ms flash.
///
/// The default is *disabled at tick zero*: a caller that does not supply a
/// snapshot renders exactly the still frame this port always rendered. That
/// keeps every existing snapshot test byte-identical, at the cost that the
/// live composition must construct the snapshot explicitly before anything
/// moves — which is the CLI slice's half of this seam.
public struct PagerMotionSnapshot: Sendable, Equatable, Hashable {
    /// Animation tick derived from wall time (`elapsed / tickInterval`), not
    /// from an event counter — a silent turn must not freeze the spinner.
    public var tick: Int
    /// Seconds since the UI's motion epoch, on the same clock as
    /// `PagerToolCard.finishedAt`.
    public var seconds: TimeInterval
    public var enabled: Bool

    public init(tick: Int = 0, seconds: TimeInterval = 0, enabled: Bool = false) {
        self.tick = tick
        self.seconds = seconds
        self.enabled = enabled
    }
}

// MARK: - Display-refresh cadence policy

/// The `[ui.display_refresh]` policy the paint cadence is resolved from —
/// `DisplayRefreshPolicy` (`display_refresh.rs`), defaults per
/// `defaults_probe_on_auto_off` (`display_refresh.rs:367-378`): probe on,
/// auto **off**, floor 8 ms, ceiling 16 ms, Hz band 55...165.
public struct PagerDisplayRefreshPolicy: Sendable, Equatable, Hashable {
    public var probeEnabled: Bool
    /// The "Match display refresh rate" settings row
    /// (`ui.display_refresh.auto_cadence_enabled`). This type is that row's
    /// reader: `PagerFrameClock.cadence(environment:policy:probedRefreshHz:)`
    /// only lets a probed Hz shorten the paint cadence when this is true.
    public var autoCadenceEnabled: Bool
    public var floorMs: Int
    public var ceilingMs: Int
    public var minHz: Int
    public var maxHz: Int

    public init(
        probeEnabled: Bool = true,
        autoCadenceEnabled: Bool = false,
        floorMs: Int = 8,
        ceilingMs: Int = 16,
        minHz: Int = 55,
        maxHz: Int = 165
    ) {
        self.probeEnabled = probeEnabled
        self.autoCadenceEnabled = autoCadenceEnabled
        // `order_bounds` upstream repairs an inverted pair rather than
        // trusting it; a floor above the ceiling would invert the clamp.
        self.floorMs = min(floorMs, ceilingMs)
        self.ceilingMs = max(floorMs, ceilingMs)
        self.minHz = min(minHz, maxHz)
        self.maxHz = max(minHz, maxHz)
    }
}

extension PagerFrameClock {
    /// Resolve the paint cadence from policy, probe, and environment —
    /// `resolve_motion_cadence` (`display_refresh.rs:326-339`) plus the
    /// `GROK_MIN_DRAW_MS` override rule (`display_refresh_startup.rs:41-48`).
    ///
    /// Order of authority, highest first:
    ///   1. `GROK_MIN_DRAW_MS` — *presence* wins, even unparsable (upstream
    ///      counts a set-but-invalid var as "set", clamped default).
    ///   2. Auto cadence: probe on + flag on + Hz inside `[minHz, maxHz]` →
    ///      `clamp(round(1000/hz), floor, ceiling)` (`decide_auto_cadence`,
    ///      `display_refresh.rs:255-291`).
    ///   3. The 16 ms default.
    ///
    /// `probedRefreshHz` is a parameter because this port has no display
    /// probe FFI yet; until the CLI supplies one the auto branch resolves to
    /// upstream's `probe_skip` (default cadence), which is exactly what the
    /// row's "Restart required" caption already promises.
    public static func cadence(
        environment: [String: String],
        policy: PagerDisplayRefreshPolicy,
        probedRefreshHz: Int?
    ) -> TimeInterval {
        if environment["GROK_MIN_DRAW_MS"] != nil {
            return cadence(environment: environment)
        }
        guard policy.probeEnabled,
              policy.autoCadenceEnabled,
              let hz = probedRefreshHz,
              hz >= policy.minHz, hz <= policy.maxHz
        else { return PagerMotion.defaultPaintCadence }
        let raw = max(1, Int((1000.0 / Double(hz)).rounded()))
        let clamped = min(max(raw, policy.floorMs), policy.ceilingMs)
        return Double(clamped) / 1000
    }
}

// MARK: - Tick demand

/// How urgently the frame loop needs to tick (`TickDemand`,
/// `event_loop.rs:3170-3188`).
public enum PagerTickDemand: Sendable, Equatable, Hashable, Comparable {
    /// Nothing is moving. No tick is armed at all — this is the idle case, and
    /// the reason a still screen costs no CPU.
    case none
    /// Only slow motion (the welcome shimmer) needs sampling.
    case slow
    /// Something is animating at full rate.
    case fast

    public static func < (lhs: PagerTickDemand, rhs: PagerTickDemand) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        switch self {
        case .none: return 0
        case .slow: return 1
        case .fast: return 2
        }
    }
}

/// What is currently in motion, as the frame loop sees it.
public struct PagerMotionState: Sendable, Equatable, Hashable {
    /// A turn is running, so the turn-status spinner is live.
    public var hasRunningTurn: Bool
    /// A running block is inside the viewport. The reference is careful that an
    /// *off-screen* running block does not force redraws
    /// (`scrollback/state/mod.rs:445-452`); an animation nobody can see is
    /// worth exactly zero frames.
    public var hasVisibleRunningBlock: Bool
    /// A background task chip is spinning.
    public var hasBackgroundTasks: Bool
    /// The welcome logo is on screen, which is slow motion only.
    public var showsWelcomeLogo: Bool
    /// A finished block is still inside its flash window.
    public var hasPendingFlash: Bool
    /// The terminal cannot render motion — not a TTY, `TERM=dumb`, or the user
    /// asked for a still UI.
    public var motionEnabled: Bool

    public init(
        hasRunningTurn: Bool = false,
        hasVisibleRunningBlock: Bool = false,
        hasBackgroundTasks: Bool = false,
        showsWelcomeLogo: Bool = false,
        hasPendingFlash: Bool = false,
        motionEnabled: Bool = true
    ) {
        self.hasRunningTurn = hasRunningTurn
        self.hasVisibleRunningBlock = hasVisibleRunningBlock
        self.hasBackgroundTasks = hasBackgroundTasks
        self.showsWelcomeLogo = showsWelcomeLogo
        self.hasPendingFlash = hasPendingFlash
        self.motionEnabled = motionEnabled
    }

    /// `tick_demand` (`app_view.rs:6078-6120`).
    ///
    /// A pending flash does not raise the demand on its own — it rides along on
    /// frames that were already happening.
    public var demand: PagerTickDemand {
        guard motionEnabled else { return .none }
        if hasRunningTurn || hasVisibleRunningBlock || hasBackgroundTasks { return .fast }
        if showsWelcomeLogo { return .slow }
        return .none
    }
}

// MARK: - Frame clock

/// The paint-side clock: coalesces redraw requests into at most one frame per
/// cadence window, and refuses to start a frame while one is still in flight.
///
/// This is `Presenter` (`event_loop.rs:422-517`) minus the writer-thread
/// sequence numbers, which have no analogue in this port's synchronous sink.
/// The back-pressure idea survives: `beginFrame` is the only way to start a
/// paint, and it will not hand out a second one until `endFrame`.
public struct PagerFrameClock: Sendable, Equatable {
    /// Minimum gap between painted frames.
    public var cadence: TimeInterval
    public private(set) var isDirty: Bool
    public private(set) var lastPaintedAt: TimeInterval?
    public private(set) var isFrameInFlight: Bool
    /// When a request arrived inside the cadence window, the earliest time the
    /// coalesced frame may paint.
    public private(set) var scheduledPaintAt: TimeInterval?

    public init(cadence: TimeInterval = PagerMotion.defaultPaintCadence) {
        self.cadence = min(
            max(cadence, PagerMotion.minimumPaintCadence), PagerMotion.maximumPaintCadence
        )
        self.isDirty = false
        self.lastPaintedAt = nil
        self.isFrameInFlight = false
        self.scheduledPaintAt = nil
    }

    /// Read the cadence out of the environment
    /// (`GROK_MIN_DRAW_MS`, `display_refresh_startup.rs:17-18`).
    public static func cadence(environment: [String: String]) -> TimeInterval {
        guard let raw = environment["GROK_MIN_DRAW_MS"], let milliseconds = Double(raw) else {
            return PagerMotion.defaultPaintCadence
        }
        return min(
            max(milliseconds / 1000, PagerMotion.minimumPaintCadence),
            PagerMotion.maximumPaintCadence
        )
    }

    /// Something changed and wants the screen redrawn.
    ///
    /// Returns whether a frame may start *now*. `false` means the request was
    /// folded into a frame that will happen at `scheduledPaintAt` — the caller
    /// does not need to remember anything.
    @discardableResult
    public mutating func requestPaint(at now: TimeInterval) -> Bool {
        isDirty = true
        guard !isFrameInFlight else { return false }
        guard let last = lastPaintedAt else { return true }
        let earliest = last + cadence
        guard now >= earliest else {
            scheduledPaintAt = earliest
            return false
        }
        return true
    }

    /// Whether a coalesced frame has come due.
    public func isPaintDue(at now: TimeInterval) -> Bool {
        guard isDirty, !isFrameInFlight else { return false }
        guard let scheduled = scheduledPaintAt else { return true }
        return now >= scheduled
    }

    /// Take the frame. Returns `false` when there is nothing to paint or a
    /// frame is already out, which is the whole of the back-pressure rule.
    public mutating func beginFrame(at now: TimeInterval) -> Bool {
        guard isPaintDue(at: now) else { return false }
        isFrameInFlight = true
        isDirty = false
        scheduledPaintAt = nil
        lastPaintedAt = now
        return true
    }

    public mutating func endFrame() {
        isFrameInFlight = false
    }
}

// MARK: - Degradation

extension PagerMotionState {
    /// Whether this terminal should animate at all.
    ///
    /// A non-TTY has no one watching, and `TERM=dumb` cannot reposition the
    /// cursor, so every "animation" would append another copy of the frame.
    /// Both cases degrade to a still UI rather than to a broken one.
    public static func motionEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTTY: Bool
    ) -> Bool {
        guard isTTY else { return false }
        let term = environment["TERM"]?.lowercased() ?? ""
        if term.isEmpty || term == "dumb" { return false }
        // The reference has no reduced-motion flag; it exposes `[animation].fps`
        // and the paint cadence instead. `GROK_NO_MOTION` is this port's
        // explicit off switch, which the accessibility case needs and neither
        // of those two knobs actually provides.
        if let flag = environment["GROK_NO_MOTION"], flag != "0", !flag.isEmpty { return false }
        return true
    }
}
