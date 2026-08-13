// MouseInput.swift
//
// Mouse reporting: DECSET enable/disable sequences, SGR (1006) and legacy X10
// report decoding, and a streaming parser that extracts mouse reports from a
// raw terminal byte stream without desyncing on malformed input.

import Foundation

// MARK: - Buttons

/// A physical mouse button, using the SGR/X10 low-order button encoding.
public enum MouseButton: Sendable, Equatable, Hashable {
    case left
    case middle
    case right
    /// Extended button (SGR bit 7 set): buttons 8-11 report as `.other(8...11)`.
    case other(Int)
    /// Motion or release with no button attribution (encoded button 3).
    case none

    /// Wire code for the button, or `nil` for `.none`.
    public var code: Int? {
        switch self {
        case .left: return 0
        case .middle: return 1
        case .right: return 2
        case .other(let n): return n
        case .none: return nil
        }
    }

    /// Decode a button from a wire code. Code 3 is "no button".
    public init(code: Int) {
        switch code {
        case 0: self = .left
        case 1: self = .middle
        case 2: self = .right
        case 3: self = .none
        default: self = .other(code)
        }
    }
}

extension MouseEvent {
    /// Sentinel stored in `button` when no button is attributed (motion,
    /// wheel, X10 release). Chosen so existing `button == 0` (left) tests
    /// stay correct.
    public static let noButton: Int = -1

    /// The stored `button` code as a typed value.
    public var resolvedButton: MouseButton {
        button == MouseEvent.noButton ? .none : MouseButton(code: button)
    }

    public init(
        kind: Kind,
        x: Int,
        y: Int,
        button: MouseButton,
        modifiers: KeyModifiers = []
    ) {
        self.init(
            kind: kind,
            x: x,
            y: y,
            button: button.code ?? MouseEvent.noButton,
            modifiers: modifiers
        )
    }

    /// True when the event carries a wheel/trackpad scroll direction.
    public var isScroll: Bool {
        switch kind {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight: return true
        case .down, .up, .drag, .move: return false
        }
    }
}

// MARK: - Enable / disable sequences

/// DECSET/DECRST sequences for mouse and focus reporting.
///
/// The enable/disable pairs mirror crossterm's `EnableMouseCapture` /
/// `DisableMouseCapture`, which the Rust pager drives on alt-screen entry and
/// teardown (`xai-grok-pager/src/app/mod.rs:1312`, `:1501`). Disable order is
/// the reverse of enable order, matching crossterm.
public enum ANSIMouse {
    /// `?1000` normal tracking (press/release).
    public static let enableNormalTracking = "\u{1B}[?1000h"
    /// `?1002` button-event tracking (motion while a button is held).
    public static let enableButtonEventTracking = "\u{1B}[?1002h"
    /// `?1003` any-event tracking (motion with no button held).
    public static let enableAnyEventTracking = "\u{1B}[?1003h"
    /// `?1015` rxvt extended coordinates (legacy fallback).
    public static let enableRXVTExtended = "\u{1B}[?1015h"
    /// `?1006` SGR extended reporting — the format this module decodes.
    public static let enableSGRExtended = "\u{1B}[?1006h"

    /// Full mouse capture enable, in crossterm's order.
    public static let enableReporting =
        enableNormalTracking
        + enableButtonEventTracking
        + enableAnyEventTracking
        + enableRXVTExtended
        + enableSGRExtended

    /// Full mouse capture disable, reverse of `enableReporting`.
    public static let disableReporting =
        "\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l"

    /// Unconditional mouse-tracking reset for crash / restore paths.
    ///
    /// Byte-identical to the Rust `MOUSE_TRACKING_RESET`
    /// (`xai-crash-handler/src/terminal.rs:35`) and to the mouse portion of
    /// the reset string already emitted by `OpenGrokCrashHandler`. Safe to
    /// write even when reporting was never enabled.
    public static let trackingReset =
        "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1015l\u{1B}[?1006l"

    /// `?1004` focus reporting.
    public static let enableFocusReporting = "\u{1B}[?1004h"
    public static let disableFocusReporting = "\u{1B}[?1004l"
}

// MARK: - Driver-level enable/disable

/// Paired enable/disable of mouse reporting on a terminal writer.
///
/// Enabling and disabling are idempotent, so an unbalanced teardown (panic
/// handler running after a normal `disable()`) cannot double-write. Mirrors
/// the Rust `MOUSE_CAPTURE_ENABLED` atomic-swap guard
/// (`xai-grok-pager/src/app/mod.rs:1497`).
///
/// Ordering relative to the alternate screen matters: enable *after*
/// `?1049h` and disable *before* `?1049l`, so a terminal that scopes DEC
/// private modes per screen buffer still sees the disable land on the
/// buffer that saw the enable.
public final class MouseReportingController {
    private let writer: TerminalWriter
    public private(set) var isEnabled: Bool = false

    public init(writer: TerminalWriter) {
        self.writer = writer
    }

    /// Enable reporting. Returns true when a sequence was actually written.
    @discardableResult
    public func enable() throws -> Bool {
        guard !isEnabled else { return false }
        try writer.write(string: ANSIMouse.enableReporting)
        try writer.flush()
        isEnabled = true
        return true
    }

    /// Disable reporting. Returns true when a sequence was actually written.
    @discardableResult
    public func disable() throws -> Bool {
        guard isEnabled else { return false }
        try writer.write(string: ANSIMouse.disableReporting)
        try writer.flush()
        isEnabled = false
        return true
    }

    /// Best-effort unconditional reset for crash / signal / restore paths.
    ///
    /// Writes `trackingReset` whether or not this controller believes
    /// reporting is on, and swallows write errors — the terminal must never
    /// be left with tracking stuck on because stderr was already broken.
    public func forceReset() {
        try? writer.write(string: ANSIMouse.trackingReset)
        try? writer.flush()
        isEnabled = false
    }
}

// MARK: - Report decoding

/// Result of decoding one candidate mouse report.
public enum MouseReportDecodeResult: Sendable, Equatable {
    case event(MouseEvent)
    /// Well-formed but carries no event we model (currently unused; reserved
    /// for report kinds we deliberately drop).
    case ignored
    /// The bytes are not a mouse report at all.
    case notMouse
    /// The bytes look like a mouse report but are structurally invalid.
    case malformed
}

/// Decoder for a single complete mouse report.
public enum MouseReportDecoder {
    /// Bit flags in the SGR/X10 button byte.
    private enum Flag {
        static let shift = 4
        static let alt = 8
        static let control = 16
        static let motion = 32
        static let wheel = 64
        static let extended = 128
    }

    /// Decode a complete escape sequence.
    ///
    /// Accepts SGR (`ESC [ < b ; x ; y M|m`) and legacy X10
    /// (`ESC [ M Cb Cx Cy`). Coordinates are converted from the wire's
    /// 1-based values to 0-based cells and clamped at 0.
    public static func decode(_ bytes: [UInt8]) -> MouseReportDecodeResult {
        guard bytes.count >= 3, bytes[0] == 0x1B, bytes[1] == 0x5B else {
            return .notMouse
        }
        if bytes[2] == 0x3C {  // '<'
            return decodeSGR(bytes)
        }
        if bytes[2] == 0x4D {  // 'M'
            return decodeX10(bytes)
        }
        return .notMouse
    }

    /// Decode `ESC [ < button ; column ; row M|m`.
    public static func decodeSGR(_ bytes: [UInt8]) -> MouseReportDecodeResult {
        guard bytes.count >= 4, bytes[0] == 0x1B, bytes[1] == 0x5B, bytes[2] == 0x3C else {
            return .notMouse
        }
        let final = bytes[bytes.count - 1]
        guard final == 0x4D || final == 0x6D else { return .malformed }  // 'M' / 'm'
        let pressed = final == 0x4D

        var fields: [Int] = []
        var current: Int? = nil
        for byte in bytes[3..<(bytes.count - 1)] {
            switch byte {
            case 0x30...0x39:  // '0'...'9'
                let digit = Int(byte - 0x30)
                // Cap growth so a long digit run cannot overflow.
                let next = (current ?? 0)
                if next > 9_999_999 { return .malformed }
                current = next * 10 + digit
            case 0x3B:  // ';'
                fields.append(current ?? -1)
                current = nil
            default:
                return .malformed
            }
        }
        fields.append(current ?? -1)

        guard fields.count == 3 else { return .malformed }
        let buttonByte = fields[0]
        let column = fields[1]
        let row = fields[2]
        guard buttonByte >= 0, column >= 0, row >= 0 else { return .malformed }

        return .event(
            makeEvent(
                buttonByte: buttonByte,
                column1Based: column,
                row1Based: row,
                pressed: pressed,
                sgr: true
            )
        )
    }

    /// Decode `ESC [ M Cb Cx Cy`, where each payload byte is `value + 32`.
    ///
    /// X10 has no release-button information: a release reports button code
    /// 3, so `.up` events carry `MouseButton.none`.
    public static func decodeX10(_ bytes: [UInt8]) -> MouseReportDecodeResult {
        guard bytes.count >= 3, bytes[0] == 0x1B, bytes[1] == 0x5B, bytes[2] == 0x4D else {
            return .notMouse
        }
        guard bytes.count == 6 else { return .malformed }
        let raw = bytes[3...]
        for byte in raw where byte < 32 { return .malformed }
        let buttonByte = Int(bytes[3]) - 32
        let column = Int(bytes[4]) - 32
        let row = Int(bytes[5]) - 32

        // X10 release is button code 3 on a press-form report.
        let isRelease = !hasFlag(buttonByte, Flag.wheel)
            && !hasFlag(buttonByte, Flag.motion)
            && (buttonByte & 0b11) == 3
        return .event(
            makeEvent(
                buttonByte: buttonByte,
                column1Based: column,
                row1Based: row,
                pressed: !isRelease,
                sgr: false
            )
        )
    }

    private static func hasFlag(_ value: Int, _ flag: Int) -> Bool {
        value & flag == flag
    }

    private static func makeEvent(
        buttonByte: Int,
        column1Based: Int,
        row1Based: Int,
        pressed: Bool,
        sgr: Bool
    ) -> MouseEvent {
        var modifiers: KeyModifiers = []
        if hasFlag(buttonByte, Flag.shift) { modifiers.insert(.shift) }
        if hasFlag(buttonByte, Flag.alt) { modifiers.insert(.alt) }
        if hasFlag(buttonByte, Flag.control) { modifiers.insert(.control) }

        let low = buttonByte & 0b11
        let isWheel = hasFlag(buttonByte, Flag.wheel)
        let isMotion = hasFlag(buttonByte, Flag.motion)
        let isExtended = hasFlag(buttonByte, Flag.extended)

        let kind: MouseEvent.Kind
        let button: MouseButton
        if isWheel {
            switch low {
            case 0: kind = .scrollUp
            case 1: kind = .scrollDown
            case 2: kind = .scrollLeft
            default: kind = .scrollRight
            }
            button = .none
        } else if isMotion {
            kind = low == 3 ? .move : .drag
            button = low == 3 ? .none : resolveButton(low: low, extended: isExtended)
        } else if pressed {
            kind = .down
            button = resolveButton(low: low, extended: isExtended)
        } else {
            kind = .up
            // SGR reports the button on release; X10 does not.
            button = sgr ? resolveButton(low: low, extended: isExtended) : .none
        }

        return MouseEvent(
            kind: kind,
            x: max(0, column1Based - 1),
            y: max(0, row1Based - 1),
            button: button,
            modifiers: modifiers
        )
    }

    private static func resolveButton(low: Int, extended: Bool) -> MouseButton {
        if extended { return .other(8 + low) }
        return MouseButton(code: low)
    }
}

// MARK: - Streaming parser

/// One output of the streaming parser.
public enum MouseParserOutput: Sendable, Equatable {
    case mouse(MouseEvent)
    /// Bytes that are not part of a recognized mouse report, in order.
    /// Includes malformed reports so the host still sees them.
    case passthrough([UInt8])
}

/// Extracts mouse reports from a raw byte stream.
///
/// Every byte fed in comes back out — either folded into a `.mouse` event or
/// verbatim in a `.passthrough` — so a malformed or partial sequence cannot
/// silently swallow following input. Reports may be split across any number
/// of `feed` calls.
public struct MouseStreamParser: Sendable {
    private enum State: Sendable {
        case idle
        /// Saw ESC.
        case escape
        /// Saw ESC [.
        case csi
        /// Saw ESC [ <, accumulating SGR parameters.
        case sgr(params: [UInt8])
        /// Saw ESC [ M, waiting for `remaining` payload bytes.
        case x10(payload: [UInt8], remaining: Int)
    }

    /// Cap on an in-progress SGR parameter run before we give up and pass the
    /// bytes through. Real reports are well under 20 bytes.
    private static let maxParameterBytes = 32

    private var state: State = .idle
    private var pending: [UInt8] = []

    public init() {}

    /// True when a partial sequence is buffered.
    public var hasPendingBytes: Bool { !pending.isEmpty }

    public mutating func feed(_ bytes: [UInt8]) -> [MouseParserOutput] {
        var out: [MouseParserOutput] = []
        for byte in bytes {
            out.append(contentsOf: feed(byte))
        }
        return coalesce(out)
    }

    public mutating func feed(_ byte: UInt8) -> [MouseParserOutput] {
        switch state {
        case .idle:
            if byte == 0x1B {
                pending = [byte]
                state = .escape
                return []
            }
            return [.passthrough([byte])]

        case .escape:
            if byte == 0x5B {  // '['
                pending.append(byte)
                state = .csi
                return []
            }
            return abandon(reprocessing: byte)

        case .csi:
            if byte == 0x3C {  // '<'
                pending.append(byte)
                state = .sgr(params: [])
                return []
            }
            if byte == 0x4D {  // 'M' — legacy X10
                pending.append(byte)
                state = .x10(payload: [], remaining: 3)
                return []
            }
            return abandon(reprocessing: byte)

        case .sgr(let params):
            if byte == 0x4D || byte == 0x6D {  // 'M' / 'm'
                pending.append(byte)
                let sequence = pending
                pending = []
                state = .idle
                switch MouseReportDecoder.decodeSGR(sequence) {
                case .event(let event):
                    return [.mouse(event)]
                case .ignored:
                    return []
                case .notMouse, .malformed:
                    return [.passthrough(sequence)]
                }
            }
            let isParameterByte = (byte >= 0x30 && byte <= 0x39) || byte == 0x3B
            if isParameterByte, params.count < Self.maxParameterBytes {
                pending.append(byte)
                state = .sgr(params: params + [byte])
                return []
            }
            return abandon(reprocessing: byte)

        case .x10(let payload, let remaining):
            // X10 payload bytes are raw and may hold any value, including
            // ESC, so they are consumed unconditionally.
            let nextPayload = payload + [byte]
            pending.append(byte)
            if remaining > 1 {
                state = .x10(payload: nextPayload, remaining: remaining - 1)
                return []
            }
            let sequence = pending
            pending = []
            state = .idle
            switch MouseReportDecoder.decodeX10(sequence) {
            case .event(let event):
                return [.mouse(event)]
            case .ignored:
                return []
            case .notMouse, .malformed:
                return [.passthrough(sequence)]
            }
        }
    }

    /// Flush any partial sequence, e.g. on an escape-timeout or EOF.
    public mutating func finish() -> [MouseParserOutput] {
        guard !pending.isEmpty else {
            state = .idle
            return []
        }
        let bytes = pending
        pending = []
        state = .idle
        return [.passthrough(bytes)]
    }

    /// Give up on the buffered prefix, then re-run `byte` from `.idle` so a
    /// new sequence starting mid-abandon (e.g. `ESC ESC [ < …`) still parses.
    private mutating func abandon(reprocessing byte: UInt8) -> [MouseParserOutput] {
        let buffered = pending
        pending = []
        state = .idle
        var out: [MouseParserOutput] = buffered.isEmpty ? [] : [.passthrough(buffered)]
        out.append(contentsOf: feed(byte))
        return out
    }

    /// Merge adjacent passthrough runs so callers see contiguous byte spans.
    private func coalesce(_ outputs: [MouseParserOutput]) -> [MouseParserOutput] {
        var merged: [MouseParserOutput] = []
        for output in outputs {
            if case .passthrough(let bytes) = output,
               case .passthrough(let previous)? = merged.last {
                merged[merged.count - 1] = .passthrough(previous + bytes)
            } else {
                merged.append(output)
            }
        }
        return merged
    }
}

// MARK: - Wheel tuning

/// Wheel-to-line conversion constants ported from the Rust pager
/// (`xai-grok-pager/src/input/mouse.rs`).
///
/// Terminal wheel reports carry direction only, never magnitude, so the number
/// of lines a notch scrolls is a policy decision. Terminals differ in how many
/// SGR reports they emit per physical notch (`eventsPerTick`); dividing by it
/// keeps one notch worth the same distance everywhere. `linesPerTick` is the
/// notch distance itself and is *not* independent of `eventsPerTick` for every
/// brand: iTerm2/WezTerm set both to 1 so one report scrolls one line
/// (`input/mouse.rs:363-369`). Changing only `eventsPerTick` leaves a 3-line
/// notch on those terminals.
public struct MouseWheelTuning: Sendable, Equatable {
    /// Lines scrolled per physical wheel notch (`DEFAULT_WHEEL_LINES_PER_TICK`,
    /// `input/mouse.rs:70`).
    public static let defaultLinesPerTick = 3
    /// Reports emitted per notch by a typical terminal (`DEFAULT_EVENTS_PER_TICK`,
    /// `input/mouse.rs:69`).
    public static let defaultEventsPerTick = 3

    public var linesPerTick: Int
    public var eventsPerTick: Int

    public init(
        linesPerTick: Int = MouseWheelTuning.defaultLinesPerTick,
        eventsPerTick: Int = MouseWheelTuning.defaultEventsPerTick
    ) {
        self.linesPerTick = max(1, linesPerTick)
        self.eventsPerTick = max(1, eventsPerTick)
    }

    /// Lines a single wheel report is worth, rounded so one report always
    /// moves at least one line (`MIN_LINES_PER_WHEEL_STREAM`,
    /// `input/mouse.rs:98`).
    public var linesPerEvent: Int {
        max(1, Int((Double(linesPerTick) / Double(eventsPerTick)).rounded()))
    }

    /// Authoritative per-terminal wheel profile from
    /// `ScrollConfig::from_terminal_context` (`input/mouse.rs:324-373`).
    ///
    /// Delegates to `ScrollConfig.from(brand:multiplexer:overrides:)` so the
    /// brand table cannot drift from the scroll-stream normalizer. `program`
    /// is a `TERM_PROGRAM` value (or nil). Only iTerm2 and WezTerm lower
    /// `linesPerTick` with `eventsPerTick`; VS Code-family / Zed keep the
    /// default 3-line notch with `eventsPerTick == 1`. Unknown / unlisted
    /// programs use the 3/3 defaults.
    public static func forTerminalProgram(_ program: String?) -> MouseWheelTuning {
        let brand = MouseScrollTerminalBrand.from(termProgram: program)
        let config = ScrollConfig.from(brand: brand, multiplexer: .undetected)
        return MouseWheelTuning(
            linesPerTick: Int(config.wheelLinesPerTick),
            eventsPerTick: Int(config.eventsPerTick)
        )
    }

    /// Per-terminal reports-per-notch. Prefer `forTerminalProgram(_:)` when
    /// constructing tuning — this helper only exposes one field and cannot
    /// express the iTerm/WezTerm 1/1 pair.
    public static func eventsPerTick(forTerminalProgram program: String?) -> Int {
        forTerminalProgram(program).eventsPerTick
    }
}
