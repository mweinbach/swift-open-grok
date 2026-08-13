// MouseScrollStream.swift
//
// Pure mouse wheel/trackpad scroll stream normalizer, ported from pinned
// Rust `xai-grok-pager/src/input/mouse.rs` at 650c1db7.
//
// Terminal scroll reports carry direction only. This state machine groups
// them into streams (80ms gap / direction flip), prices them with a
// per-terminal events-per-tick factor, promotes wheel↔trackpad by timing,
// coalesces flushes to a 16ms cadence, and returns signed line deltas.
// Every public clock entry point takes an injected monotonic `now` in
// nanoseconds — no wall clock and no Task.sleep.

import Foundation

// MARK: - Timing constants (mouse.rs:63-98)

/// Gap that ends a scroll stream (`STREAM_GAP_MS`).
public let mouseScrollStreamGapNanos: Int64 = 80_000_000
/// Default flush cadence (`REDRAW_CADENCE_MS`, ~60fps).
public let mouseScrollRedrawCadenceNanos: Int64 = 16_000_000

private let defaultEventsPerTick: UInt16 = 3
private let defaultWheelLinesPerTick: UInt16 = 3
private let defaultTrackpadLinesPerTick: UInt16 = 3
private let defaultWheelTickDetectMaxMs: UInt64 = 12
private let defaultWheelLikeMaxDurationMs: UInt64 = 200
private let defaultTrackpadAccelMax: UInt16 = 3
private let defaultTrackpadDetectMaxIntervalMs: Float = 30.0
private let minDeltaPerFlush: Int = 6
private let defaultAccelIntervalFastMs: Float = 8.0
private let defaultAccelIntervalMediumMs: Float = 20.0
private let accelMinIntervalMs: Float = 6.0
private let accelMultiplierBase: Float = 1.0
private let accelMultiplierMedium: Float = 1.6
private let accelMultiplierFast: Float = 2.5
private let accelHistorySize: Int = 6
private let minLinesPerWheelStream: Int = 1

/// Default accel fast-band threshold (ms); exposed for profile assertions.
public let mouseScrollDefaultAccelIntervalFastMs: Float = 8.0
/// Default accel medium-band threshold (ms).
public let mouseScrollDefaultAccelIntervalMediumMs: Float = 20.0
/// Default trackpad lines-per-tick.
public let mouseScrollDefaultTrackpadLinesPerTick: UInt16 = 3
/// Floor for the per-flush delta cap.
public let mouseScrollMinDeltaPerFlush: Int = 6

// MARK: - Profile enums (no Diagnostics dependency)

/// Terminal brand inputs for scroll profiling (`TerminalName` subset used by
/// `ScrollConfig::from_terminal_context`).
public enum MouseScrollTerminalBrand: Sendable, Equatable, Hashable, CaseIterable {
    case appleTerminal
    case warpTerminal
    case wezTerm
    case alacritty
    case rio
    case foot
    case ghostty
    case iterm2
    case vsCode
    case cursor
    case windsurf
    case zed
    case kitty
    case grokDesktop
    case vte
    case terminator
    case windowsTerminal
    case jetBrains
    case otty
    case unknown

    /// Map a `TERM_PROGRAM` value (or nil) onto the brand table used by
    /// `MouseWheelTuning.forTerminalProgram`.
    public static func from(termProgram program: String?) -> MouseScrollTerminalBrand {
        switch program?.lowercased() {
        case "iterm.app", "iterm2", "iterm": return .iterm2
        case "wezterm": return .wezTerm
        case "vscode": return .vsCode
        case "cursor": return .cursor
        case "windsurf": return .windsurf
        case "zed": return .zed
        case "apple_terminal": return .appleTerminal
        case "warpterminal", "warp": return .warpTerminal
        case "ghostty": return .ghostty
        case "kitty": return .kitty
        case "alacritty": return .alacritty
        case "rio": return .rio
        case "foot": return .foot
        default: return .unknown
        }
    }

    fileprivate var isVSCodeEmbed: Bool {
        switch self {
        case .vsCode, .cursor, .windsurf: return true
        default: return false
        }
    }
}

/// Multiplexer that may re-encode mouse SGR (`MultiplexerKind`).
public enum MouseScrollMultiplexer: Sendable, Equatable, Hashable {
    case tmux
    case screen
    case zellij
    case cmux
    case herdr
    case undetected

    fileprivate var reencodesMouse: Bool {
        switch self {
        case .tmux, .screen, .zellij, .herdr: return true
        case .cmux, .undetected: return false
        }
    }
}

// MARK: - Mode / direction

/// Wheel/trackpad detection mode (`ScrollInputMode`).
public enum ScrollInputMode: Sendable, Equatable, Hashable {
    case auto
    case wheel
    case trackpad

    public var label: String {
        switch self {
        case .auto: return "auto"
        case .wheel: return "wheel"
        case .trackpad: return "trackpad"
        }
    }
}

/// High-level vertical scroll direction (`ScrollDirection`).
public enum ScrollDirection: Sendable, Equatable, Hashable {
    case up
    case down

    /// Sign used in accumulated event counts: up = −1, down = +1.
    public var sign: Int {
        switch self {
        case .up: return -1
        case .down: return 1
        }
    }

    public var inverted: ScrollDirection {
        switch self {
        case .up: return .down
        case .down: return .up
        }
    }

    /// Map a decoded mouse event kind onto a scroll direction.
    public static func from(mouseKind kind: MouseEvent.Kind) -> ScrollDirection? {
        switch kind {
        case .scrollUp: return .up
        case .scrollDown: return .down
        default: return nil
        }
    }
}

// MARK: - Speed

/// Convert a scroll-speed setting (1…100) to a multiplier.
/// 50 = 1.0×, 1 = 0.1×, 100 = 6.0× (`speed_to_multiplier`).
public func mouseScrollSpeedToMultiplier(_ speed: Int) -> Float {
    let s = Float(min(100, max(1, speed)))
    if s <= 50.0 {
        return 0.1 + (s - 1.0) * (0.9 / 49.0)
    }
    return 1.0 + (s - 50.0) * (5.0 / 50.0)
}

// MARK: - Config

/// Optional user overrides for scroll configuration.
public struct ScrollConfigOverrides: Sendable, Equatable {
    public var eventsPerTick: UInt16?
    public var wheelLinesPerTick: UInt16?
    public var trackpadLinesPerTick: UInt16?
    public var trackpadAccelMax: UInt16?
    public var mode: ScrollInputMode?
    public var wheelTickDetectMaxMs: UInt64?
    public var wheelLikeMaxDurationMs: UInt64?
    public var invertDirection: Bool
    public var accelIntervalFastMs: Float?
    public var accelIntervalMediumMs: Float?
    public var trackpadDetectMaxIntervalMs: Float?
    public var speedMultiplier: Float?

    public init(
        eventsPerTick: UInt16? = nil,
        wheelLinesPerTick: UInt16? = nil,
        trackpadLinesPerTick: UInt16? = nil,
        trackpadAccelMax: UInt16? = nil,
        mode: ScrollInputMode? = nil,
        wheelTickDetectMaxMs: UInt64? = nil,
        wheelLikeMaxDurationMs: UInt64? = nil,
        invertDirection: Bool = false,
        accelIntervalFastMs: Float? = nil,
        accelIntervalMediumMs: Float? = nil,
        trackpadDetectMaxIntervalMs: Float? = nil,
        speedMultiplier: Float? = nil
    ) {
        self.eventsPerTick = eventsPerTick
        self.wheelLinesPerTick = wheelLinesPerTick
        self.trackpadLinesPerTick = trackpadLinesPerTick
        self.trackpadAccelMax = trackpadAccelMax
        self.mode = mode
        self.wheelTickDetectMaxMs = wheelTickDetectMaxMs
        self.wheelLikeMaxDurationMs = wheelLikeMaxDurationMs
        self.invertDirection = invertDirection
        self.accelIntervalFastMs = accelIntervalFastMs
        self.accelIntervalMediumMs = accelIntervalMediumMs
        self.trackpadDetectMaxIntervalMs = trackpadDetectMaxIntervalMs
        self.speedMultiplier = speedMultiplier
    }
}

/// Scroll normalization settings (`ScrollConfig`).
public struct ScrollConfig: Sendable, Equatable {
    public var eventsPerTick: UInt16
    public var wheelLinesPerTick: UInt16
    public var trackpadLinesPerTick: UInt16
    public var trackpadAccelMax: UInt16
    public var mode: ScrollInputMode
    /// Max duration (ns) for the first wheel-tick promotion window.
    public var wheelTickDetectMaxNanos: Int64
    /// Auto-mode fallback max stream duration still considered wheel-like.
    public var wheelLikeMaxDurationNanos: Int64
    public var invertDirection: Bool
    public var accelIntervalFastMs: Float
    public var accelIntervalMediumMs: Float
    public var trackpadDetectMaxIntervalMs: Float
    public var speedMultiplier: Float
    /// Viewport height in rows; 0 = unknown. Sizes the per-flush cap.
    public var viewportHeight: UInt16

    // Default args are type-checked at the call site — no file-private names.
    public init(
        eventsPerTick: UInt16 = 3,
        wheelLinesPerTick: UInt16 = 3,
        trackpadLinesPerTick: UInt16 = 3,
        trackpadAccelMax: UInt16 = 3,
        mode: ScrollInputMode = .auto,
        wheelTickDetectMaxNanos: Int64 = 12_000_000,
        wheelLikeMaxDurationNanos: Int64 = 200_000_000,
        invertDirection: Bool = false,
        accelIntervalFastMs: Float = 8.0,
        accelIntervalMediumMs: Float = 20.0,
        trackpadDetectMaxIntervalMs: Float = 30.0,
        speedMultiplier: Float = 1.0,
        viewportHeight: UInt16 = 0
    ) {
        self.eventsPerTick = max(1, eventsPerTick)
        self.wheelLinesPerTick = max(1, wheelLinesPerTick)
        self.trackpadLinesPerTick = max(1, trackpadLinesPerTick)
        self.trackpadAccelMax = max(1, trackpadAccelMax)
        self.mode = mode
        self.wheelTickDetectMaxNanos = max(0, wheelTickDetectMaxNanos)
        self.wheelLikeMaxDurationNanos = max(0, wheelLikeMaxDurationNanos)
        self.invertDirection = invertDirection
        self.accelIntervalFastMs = Self.sanitizeIntervalMs(
            accelIntervalFastMs,
            fallback: defaultAccelIntervalFastMs
        )
        self.accelIntervalMediumMs = Self.sanitizeIntervalMs(
            accelIntervalMediumMs,
            fallback: defaultAccelIntervalMediumMs
        )
        self.trackpadDetectMaxIntervalMs = Self.sanitizeIntervalMs(
            trackpadDetectMaxIntervalMs,
            fallback: defaultTrackpadDetectMaxIntervalMs
        )
        self.speedMultiplier = Self.sanitizeSpeedMultiplier(speedMultiplier)
        self.viewportHeight = viewportHeight
    }

    /// Derive profile defaults from brand + multiplexer + overrides
    /// (`ScrollConfig::from_terminal_context`).
    public static func from(
        brand: MouseScrollTerminalBrand,
        multiplexer: MouseScrollMultiplexer = .undetected,
        overrides: ScrollConfigOverrides = ScrollConfigOverrides()
    ) -> ScrollConfig {
        let remuxed = multiplexer.reencodesMouse

        var eventsPerTick: UInt16
        if remuxed {
            eventsPerTick = 1
        } else {
            switch brand {
            case .appleTerminal, .warpTerminal:
                eventsPerTick = 3
            case .wezTerm, .iterm2:
                eventsPerTick = 1
            case .alacritty, .rio, .foot, .ghostty, .kitty:
                eventsPerTick = 3
            case .vsCode, .cursor, .windsurf, .zed:
                eventsPerTick = 1
            case .grokDesktop, .vte, .terminator, .windowsTerminal, .jetBrains, .otty, .unknown:
                eventsPerTick = defaultEventsPerTick
            }
        }
        if let override = overrides.eventsPerTick {
            eventsPerTick = max(1, override)
        }

        var wheelLinesPerTick: UInt16
        if remuxed {
            wheelLinesPerTick = 1
        } else {
            switch brand {
            case .iterm2, .wezTerm:
                wheelLinesPerTick = 1
            default:
                wheelLinesPerTick = defaultWheelLinesPerTick
            }
        }
        if let override = overrides.wheelLinesPerTick {
            wheelLinesPerTick = max(1, override)
        }

        var trackpadLinesPerTick: UInt16
        if brand.isVSCodeEmbed && !remuxed {
            trackpadLinesPerTick = 15
        } else {
            trackpadLinesPerTick = defaultTrackpadLinesPerTick
        }
        if let override = overrides.trackpadLinesPerTick {
            trackpadLinesPerTick = max(1, override)
        }

        var trackpadAccelMax = defaultTrackpadAccelMax
        if let override = overrides.trackpadAccelMax {
            trackpadAccelMax = max(1, override)
        }

        let wheelTickDetectMaxMs = overrides.wheelTickDetectMaxMs ?? defaultWheelTickDetectMaxMs
        let wheelLikeMaxDurationMs =
            overrides.wheelLikeMaxDurationMs ?? defaultWheelLikeMaxDurationMs

        let accelFast: Float
        if let override = overrides.accelIntervalFastMs {
            accelFast = override
        } else if remuxed {
            accelFast = defaultAccelIntervalFastMs
        } else {
            accelFast = brand.isVSCodeEmbed ? 25.0 : defaultAccelIntervalFastMs
        }

        let accelMedium: Float
        if let override = overrides.accelIntervalMediumMs {
            accelMedium = override
        } else if remuxed {
            accelMedium = defaultAccelIntervalMediumMs
        } else {
            accelMedium = brand.isVSCodeEmbed ? 50.0 : defaultAccelIntervalMediumMs
        }

        let trackpadDetect: Float
        if let override = overrides.trackpadDetectMaxIntervalMs {
            trackpadDetect = override
        } else if remuxed {
            trackpadDetect = defaultTrackpadDetectMaxIntervalMs
        } else {
            trackpadDetect = brand.isVSCodeEmbed ? 60.0 : defaultTrackpadDetectMaxIntervalMs
        }

        return ScrollConfig(
            eventsPerTick: eventsPerTick,
            wheelLinesPerTick: wheelLinesPerTick,
            trackpadLinesPerTick: trackpadLinesPerTick,
            trackpadAccelMax: trackpadAccelMax,
            mode: overrides.mode ?? .auto,
            wheelTickDetectMaxNanos: Int64(wheelTickDetectMaxMs) * 1_000_000,
            wheelLikeMaxDurationNanos: Int64(wheelLikeMaxDurationMs) * 1_000_000,
            invertDirection: overrides.invertDirection,
            accelIntervalFastMs: accelFast,
            accelIntervalMediumMs: accelMedium,
            trackpadDetectMaxIntervalMs: trackpadDetect,
            speedMultiplier: overrides.speedMultiplier ?? 1.0,
            viewportHeight: 0
        )
    }

    /// Stamp the scroll target's viewport height (rows).
    public func withViewportHeight(_ rows: UInt16) -> ScrollConfig {
        var copy = self
        copy.viewportHeight = rows
        return copy
    }

    /// Per-flush delta cap: `max(6, viewport/2)` (`flush_cap`).
    public var flushCap: Int {
        max(Int(viewportHeight) / 2, minDeltaPerFlush)
    }

    fileprivate func applyDirection(_ direction: ScrollDirection) -> ScrollDirection {
        invertDirection ? direction.inverted : direction
    }

    fileprivate var eventsPerTickF: Float { Float(max(1, eventsPerTick)) }
    fileprivate var wheelLinesPerTickF: Float { Float(max(1, wheelLinesPerTick)) }
    fileprivate var trackpadLinesPerTickF: Float { Float(max(1, trackpadLinesPerTick)) }
    /// Trackpad always uses the standard tick size (`DEFAULT_EVENTS_PER_TICK`).
    fileprivate var trackpadEventsPerTickF: Float { Float(defaultEventsPerTick) }
    fileprivate var trackpadAccelMaxF: Float { Float(max(1, trackpadAccelMax)) }

    private static func sanitizeIntervalMs(_ value: Float, fallback: Float) -> Float {
        guard value.isFinite, value > 0 else { return fallback }
        return value
    }

    private static func sanitizeSpeedMultiplier(_ value: Float) -> Float {
        guard value.isFinite, value > 0 else { return 1.0 }
        return value
    }
}

// MARK: - Update

/// Output from scroll handling (`ScrollUpdate`).
public struct ScrollUpdate: Sendable, Equatable {
    /// Signed lines to apply (negative = up, positive = down).
    public var lines: Int
    /// Nanoseconds until the next `onTick` is due; `nil` if no tick needed.
    public var nextTickInNanos: Int64?

    public init(lines: Int = 0, nextTickInNanos: Int64? = nil) {
        self.lines = lines
        self.nextTickInNanos = nextTickInNanos
    }

    /// Convenience: next tick delay as seconds (`TimeInterval`).
    public var nextTickIn: TimeInterval? {
        guard let nanos = nextTickInNanos else { return nil }
        return TimeInterval(nanos) / 1_000_000_000
    }
}

// MARK: - Stream kind

private enum ScrollStreamKind: Sendable, Equatable {
    case unknown
    case wheel
    case trackpad

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .wheel: return "wheel"
        case .trackpad: return "trackpad"
        }
    }
}

// MARK: - State machine

/// Tracks mouse scroll streams and coalesces redraws (`MouseScrollState`).
///
/// All public clock APIs take injected monotonic nanoseconds. Callers (or
/// tests) own the clock; the library never sleeps.
public struct MouseScrollState: Sendable {
    private var stream: ScrollStream?
    private var lastRedrawAtNanos: Int64
    /// Sub-line remainder carried across same-direction stream boundaries
    /// (final line units, post accel/speed).
    private var carryLines: Float
    private var carryDirection: ScrollDirection?
    /// Effective flush cadence (default 16ms); injectable for tests.
    private var redrawCadenceNanos: Int64

    /// Create state with a deterministic time origin (nanoseconds).
    public init(nowNanos: Int64 = 0) {
        self.stream = nil
        self.lastRedrawAtNanos = nowNanos
        self.carryLines = 0
        self.carryDirection = nil
        self.redrawCadenceNanos = mouseScrollRedrawCadenceNanos
    }

    /// Create state with a deterministic time origin (`TimeInterval` seconds).
    public init(now: TimeInterval) {
        self.init(nowNanos: Self.nanos(from: now))
    }

    /// Override flush cadence (tests / `GROK_SCROLL_CADENCE_MS` injection).
    public mutating func setRedrawCadenceNanos(_ cadence: Int64) {
        redrawCadenceNanos = max(1, cadence)
    }

    /// Whether a stream is still accumulating events.
    public var hasActiveStream: Bool { stream != nil }

    /// Drop the active stream and fractional carry (`cancel_stream`).
    public mutating func cancelStream() {
        stream = nil
        carryLines = 0
        carryDirection = nil
    }

    /// Deadline until the next flush/finalize check (`scroll_clock_deadline`).
    /// `nil` = disarmed. `0` = overdue (tick immediately).
    public func deadline(nowNanos: Int64) -> Int64? {
        guard stream != nil else { return nil }
        return nextTickInNanos(now: nowNanos) ?? 0
    }

    /// `TimeInterval` seconds form of `deadline(nowNanos:)`.
    public func deadline(now: TimeInterval) -> TimeInterval? {
        guard let nanos = deadline(nowNanos: Self.nanos(from: now)) else { return nil }
        return TimeInterval(nanos) / 1_000_000_000
    }

    /// Handle a scroll event at an injected time (`on_scroll_event_at`).
    public mutating func onScrollEvent(
        nowNanos: Int64,
        direction: ScrollDirection,
        config: ScrollConfig
    ) -> ScrollUpdate {
        let direction = config.applyDirection(direction)
        var lines = 0

        if var existing = stream {
            let gap = saturatingDuration(from: existing.lastNanos, to: nowNanos)
            if gap > mouseScrollStreamGapNanos || existing.direction != direction {
                let cancelBacklog = existing.direction != direction
                stream = nil
                lines += finalizeStream(
                    nowNanos: nowNanos,
                    stream: &existing,
                    cancelBacklog: cancelBacklog
                )
            } else {
                stream = existing
            }
        }

        if stream == nil {
            if carryDirection != direction {
                carryLines = 0
                carryDirection = direction
            }
            stream = ScrollStream(nowNanos: nowNanos, direction: direction, config: config)
        }

        let carry = carryLines
        guard var active = stream else {
            return ScrollUpdate(lines: lines, nextTickInNanos: nextTickInNanos(now: nowNanos))
        }
        active.pushEvent(nowNanos: nowNanos, direction: direction)
        active.maybePromoteKind(nowNanos: nowNanos)

        let sinceRedraw = saturatingDuration(from: lastRedrawAtNanos, to: nowNanos)
        if sinceRedraw >= redrawCadenceNanos || active.justPromoted {
            let flushed = Self.flushLines(
                lastRedrawAtNanos: &lastRedrawAtNanos,
                carryLines: carry,
                nowNanos: nowNanos,
                stream: &active
            )
            lines += flushed
            active.justPromoted = false
        }
        stream = active

        return ScrollUpdate(lines: lines, nextTickInNanos: nextTickInNanos(now: nowNanos))
    }

    /// `TimeInterval` convenience for `onScrollEvent(nowNanos:direction:config:)`.
    public mutating func onScrollEvent(
        now: TimeInterval,
        direction: ScrollDirection,
        config: ScrollConfig
    ) -> ScrollUpdate {
        onScrollEvent(nowNanos: Self.nanos(from: now), direction: direction, config: config)
    }

    /// Check whether an active stream has ended (`on_tick_at`).
    public mutating func onTick(nowNanos: Int64) -> ScrollUpdate {
        var lines = 0
        if var active = stream {
            let gap = saturatingDuration(from: active.lastNanos, to: nowNanos)
            if gap > mouseScrollStreamGapNanos && active.flushableNow(carryLines: carryLines) == 0 {
                stream = nil
                lines = finalizeStream(nowNanos: nowNanos, stream: &active, cancelBacklog: false)
            } else {
                let sinceRedraw = saturatingDuration(from: lastRedrawAtNanos, to: nowNanos)
                if sinceRedraw >= redrawCadenceNanos {
                    lines = Self.flushLines(
                        lastRedrawAtNanos: &lastRedrawAtNanos,
                        carryLines: carryLines,
                        nowNanos: nowNanos,
                        stream: &active
                    )
                }
                stream = active
            }
        }
        return ScrollUpdate(lines: lines, nextTickInNanos: nextTickInNanos(now: nowNanos))
    }

    /// `TimeInterval` convenience for `onTick(nowNanos:)`.
    public mutating func onTick(now: TimeInterval) -> ScrollUpdate {
        onTick(nowNanos: Self.nanos(from: now))
    }

    // MARK: Private state transitions

    private mutating func finalizeStream(
        nowNanos: Int64,
        stream: inout ScrollStream,
        cancelBacklog: Bool
    ) -> Int {
        let carryAtFlush = carryLines
        let desiredBefore = stream.desiredLinesF32(carryLines: carryAtFlush)
        stream.finalizeKind()
        stream.limitFinalizeReprice(desiredBefore: desiredBefore, carryLines: carryAtFlush)

        let lines: Int
        if cancelBacklog {
            lines = 0
        } else {
            lines = Self.flushLines(
                lastRedrawAtNanos: &lastRedrawAtNanos,
                carryLines: carryAtFlush,
                nowNanos: nowNanos,
                stream: &stream
            )
        }

        if stream.kind != .wheel && stream.config.mode != .wheel {
            let remainder =
                stream.desiredLinesF32(carryLines: carryAtFlush) - Float(stream.appliedLines)
            carryLines = fract(remainder)
        } else {
            carryLines = 0
        }
        return lines
    }

    private static func flushLines(
        lastRedrawAtNanos: inout Int64,
        carryLines: Float,
        nowNanos: Int64,
        stream: inout ScrollStream
    ) -> Int {
        let delta = stream.flushableNow(carryLines: carryLines)
        if delta == 0 { return 0 }
        if stream.coasting {
            stream.coastSpent += abs(delta)
        }
        stream.appliedLines = saturatingAdd(stream.appliedLines, delta)
        stream.eventsAtFlush = stream.eventCount
        lastRedrawAtNanos = nowNanos
        return delta
    }

    private func nextTickInNanos(now: Int64) -> Int64? {
        guard let stream else { return nil }
        let gap = saturatingDuration(from: stream.lastNanos, to: now)
        let flushable = stream.flushableNow(carryLines: carryLines) != 0
        let sinceRedraw = saturatingDuration(from: lastRedrawAtNanos, to: now)
        let untilRedraw = max(Int64(0), redrawCadenceNanos - sinceRedraw)

        if gap > mouseScrollStreamGapNanos {
            return flushable ? untilRedraw : nil
        }

        var next = max(Int64(0), mouseScrollStreamGapNanos - gap)
        if flushable {
            next = min(next, untilRedraw)
        }
        return next
    }

    private static func nanos(from seconds: TimeInterval) -> Int64 {
        Int64((seconds * 1_000_000_000).rounded())
    }
}

// MARK: - Stream

private struct ScrollStream: Sendable {
    var startNanos: Int64
    var lastNanos: Int64
    var direction: ScrollDirection
    var eventCount: Int
    var accumulatedEvents: Int
    var appliedLines: Int
    var config: ScrollConfig
    var kind: ScrollStreamKind
    var firstTickCompletedAtNanos: Int64?
    var justPromoted: Bool
    var intervalHistory: [Float]
    var intervalSum: Float
    var accelWeightedEvents: Float
    var eventsAtFlush: Int
    var coastSpent: Int

    init(nowNanos: Int64, direction: ScrollDirection, config: ScrollConfig) {
        self.startNanos = nowNanos
        self.lastNanos = nowNanos
        self.direction = direction
        self.eventCount = 0
        self.accumulatedEvents = 0
        self.appliedLines = 0
        self.config = config
        self.kind = .unknown
        self.firstTickCompletedAtNanos = nil
        self.justPromoted = false
        self.intervalHistory = []
        self.intervalSum = 0
        self.accelWeightedEvents = 0
        self.eventsAtFlush = 0
        self.coastSpent = 0
    }

    mutating func pushEvent(nowNanos: Int64, direction: ScrollDirection) {
        let intervalMs =
            Float(saturatingDuration(from: lastNanos, to: nowNanos)) / 1_000_000
        if eventCount > 0 && intervalMs >= accelMinIntervalMs {
            intervalHistory.append(intervalMs)
            intervalSum += intervalMs
            if intervalHistory.count > accelHistorySize {
                let old = intervalHistory.removeFirst()
                intervalSum -= old
            }
        }

        lastNanos = nowNanos
        self.direction = direction
        eventCount = saturatingAdd(eventCount, 1)
        accumulatedEvents = saturatingAdd(accumulatedEvents, direction.sign)
        accelWeightedEvents += Float(direction.sign) * intervalAccel()
        if isConfirmedTrackpad {
            clampTrackpadDemand()
        }
    }

    func trackpadLineRate() -> Float {
        (effectiveLinesPerTickF() / config.trackpadEventsPerTickF) * config.speedMultiplier
    }

    mutating func clampTrackpadDemand() {
        let rate = trackpadLineRate()
        if rate <= Float.leastNonzeroMagnitude { return }
        let rawLines = Float(abs(accumulatedEvents)) * rate
        let honorable = Float(abs(appliedLines) + config.flushCap)
        let ceiling = max(rawLines, honorable)
        if abs(accelWeightedEvents) * rate > ceiling {
            let sign: Float = accelWeightedEvents >= 0 ? 1 : -1
            accelWeightedEvents = sign * ceiling / rate
        }
    }

    func avgIntervalMs() -> Float? {
        guard !intervalHistory.isEmpty else { return nil }
        return intervalSum / Float(intervalHistory.count)
    }

    func intervalAccel() -> Float {
        guard let avg = avgIntervalMs() else { return accelMultiplierBase }
        let fast = config.accelIntervalFastMs
        let medium = config.accelIntervalMediumMs
        let raw: Float
        if avg <= fast {
            raw = accelMultiplierFast
        } else if avg <= medium {
            let span = medium - fast
            let t = span > 0 ? (avg - fast) / span : 0
            raw = accelMultiplierFast + t * (accelMultiplierMedium - accelMultiplierFast)
        } else {
            raw = accelMultiplierBase
        }
        return min(max(raw, accelMultiplierBase), config.trackpadAccelMaxF)
    }

    mutating func maybePromoteKind(nowNanos: Int64) {
        guard config.mode == .auto else { return }
        guard kind == .unknown else { return }

        let eventsPerTick = max(1, Int(config.eventsPerTick))

        if eventsPerTick <= 1,
           eventCount > 2,
           let avg = avgIntervalMs(),
           avg < config.trackpadDetectMaxIntervalMs
        {
            kind = .trackpad
            return
        }

        if eventsPerTick >= 2, eventCount >= eventsPerTick {
            if firstTickCompletedAtNanos == nil {
                firstTickCompletedAtNanos = nowNanos
            }
            let elapsed = saturatingDuration(from: startNanos, to: nowNanos)
            if elapsed <= config.wheelTickDetectMaxNanos {
                kind = .wheel
                justPromoted = true
            }
        }
    }

    mutating func finalizeKind() {
        switch config.mode {
        case .wheel:
            kind = .wheel
        case .trackpad:
            kind = .trackpad
        case .auto:
            guard kind == .unknown else { return }
            let duration = saturatingDuration(from: startNanos, to: lastNanos)
            if config.eventsPerTick <= 1,
               eventCount <= 2,
               duration <= config.wheelLikeMaxDurationNanos
            {
                kind = .wheel
            } else {
                kind = .trackpad
            }
        }
    }

    mutating func limitFinalizeReprice(desiredBefore: Float, carryLines: Float) {
        guard isConfirmedTrackpad else { return }
        let rate = trackpadLineRate()
        if rate <= Float.leastNonzeroMagnitude { return }
        if abs(desiredLinesF32(carryLines: carryLines)) > abs(desiredBefore) {
            accelWeightedEvents = (desiredBefore - carryLines) / rate
        }
    }

    func isWheelLike() -> Bool {
        switch config.mode {
        case .wheel: return true
        case .trackpad: return false
        case .auto:
            return kind == .wheel
                || (kind == .unknown && config.eventsPerTick <= 1)
        }
    }

    func effectiveLinesPerTickF() -> Float {
        switch config.mode {
        case .wheel: return config.wheelLinesPerTickF
        case .trackpad: return config.trackpadLinesPerTickF
        case .auto:
            switch kind {
            case .wheel: return config.wheelLinesPerTickF
            case .trackpad: return config.trackpadLinesPerTickF
            case .unknown:
                if config.eventsPerTick <= 1 {
                    return config.wheelLinesPerTickF
                }
                return config.trackpadLinesPerTickF
            }
        }
    }

    var isConfirmedTrackpad: Bool {
        switch config.mode {
        case .trackpad: return true
        case .wheel: return false
        case .auto: return kind == .trackpad
        }
    }

    func desiredLinesF32(carryLines: Float) -> Float {
        let eventsPerTick =
            isConfirmedTrackpad ? config.trackpadEventsPerTickF : config.eventsPerTickF
        let linesPerTick = effectiveLinesPerTickF()
        if isConfirmedTrackpad {
            return accelWeightedEvents
                * (linesPerTick / eventsPerTick)
                * config.speedMultiplier
                + carryLines
        }
        return Float(accumulatedEvents)
            * (linesPerTick / eventsPerTick)
            * config.speedMultiplier
    }

    var coasting: Bool { eventCount == eventsAtFlush }

    func flushableNow(carryLines: Float) -> Int {
        let pending = effectivePending(carryLines: carryLines)
        let cap = config.flushCap
        let magnitude: Int
        if coasting {
            let taper = max(abs(pending) / 2, Int(effectiveLinesPerTickF()))
            magnitude = min(abs(pending), taper, max(0, cap - coastSpent))
        } else {
            magnitude = min(abs(pending), cap)
        }
        return pending.signum() * magnitude
    }

    func effectivePending(carryLines: Float) -> Int {
        var desiredLines = Int(desiredLinesF32(carryLines: carryLines).rounded(.towardZero))

        if isWheelLike(), desiredLines == 0, accumulatedEvents != 0 {
            desiredLines = accumulatedEvents.signum() * minLinesPerWheelStream
        }

        var delta = desiredLines - appliedLines
        if accumulatedEvents > 0 {
            delta = max(delta, 0)
        } else if accumulatedEvents < 0 {
            delta = min(delta, 0)
        }
        return delta
    }
}

// MARK: - Helpers

private func saturatingDuration(from start: Int64, to end: Int64) -> Int64 {
    max(0, end &- start)
}

private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    if overflow {
        return rhs >= 0 ? Int.max : Int.min
    }
    return result
}

private func fract(_ value: Float) -> Float {
    value - value.rounded(.towardZero)
}
