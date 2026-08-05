// PagerThemeDetection.swift
//
// Deciding which palette to paint with: terminal color support, the OSC-11
// background probe, and system dark/light appearance.
//
// Ports `xai-grok-pager-render/src/theme/color_support.rs`, `theme/osc11.rs`,
// and `theme/system_appearance.rs` at upstream 9ed09e2a.
//
// Everything here is written against injected inputs — an environment
// dictionary, a probe transport, an appearance reader — because the whole point
// of this file is behavior that depends on the machine it runs on, and a test
// that cannot vary the machine cannot test it.

import Foundation
import OpenGrokTerminalCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Color support

/// `ColorLevel` (`color_support.rs:19-28`), ordered weakest to strongest.
public enum PagerColorLevel: Int, Sendable, Equatable, Hashable, Comparable {
    case none = 0
    case basic = 1
    case ansi256 = 2
    case trueColor = 3

    public static func < (lhs: PagerColorLevel, rhs: PagerColorLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var hasColor: Bool { self != .none }

    /// `as_str` (`color_support.rs:44-55`).
    public var canonicalName: String {
        switch self {
        case .none: return "none"
        case .basic: return "basic"
        case .ansi256: return "256"
        case .trueColor: return "truecolor"
        }
    }
}

/// Terminal emulators the reference treats as truecolor-capable regardless of
/// what `TERM` claims (`color_support.rs:259-278`).
private let pagerTrueColorTerminalPrograms: Set<String> = [
    "iterm.app", "ghostty", "kitty", "wezterm", "alacritty", "rio",
    "warpterminal", "warp", "vscode", "windowsterminal", "foot"
]

/// Detect the terminal's color support from the environment.
///
/// This is the reference's `standalone_from_env` (`color_support.rs:130-193`)
/// rather than its `detect_raw`: `detect_raw` delegates to the `supports-color`
/// crate and then falls back to TrueColor on a non-TTY, which is a decision
/// about *this process's* stdout that the caller is better placed to make. The
/// env rules are the part that ports.
///
/// `isTTY` is threaded in rather than read here so a golden test can pin both
/// sides of the non-interactive branch.
public func pagerDetectColorLevel(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    isTTY: Bool = true
) -> PagerColorLevel {
    // `NO_COLOR` wins over everything, at any value including empty
    // (`color_support.rs:96-98`).
    if environment["NO_COLOR"] != nil { return .none }

    if let forced = environment["GROK_FORCE_COLOR_LEVEL"]?.lowercased() {
        switch forced {
        case "none", "0": return .none
        case "basic", "16": return .basic
        case "256", "ansi256": return .ansi256
        case "truecolor", "24bit", "16m": return .trueColor
        default: break
        }
    }

    let term = environment["TERM"]?.lowercased() ?? ""
    // A dumb or absent terminal cannot be assumed to do anything at all.
    if term.isEmpty || term == "dumb" { return isTTY ? .none : .trueColor }

    let colorTerm = environment["COLORTERM"]?.lowercased() ?? ""
    if colorTerm == "truecolor" || colorTerm == "24bit" { return .trueColor }

    let program = (environment["TERM_PROGRAM"] ?? "")
        .lowercased()
        .replacingOccurrences(of: " ", with: "")
    if pagerTrueColorTerminalPrograms.contains(program) { return .trueColor }

    if term.contains("256color") { return .ansi256 }
    return .basic
}

// MARK: - Quantization

/// The xterm ANSI-16 palette the reference matches against
/// (`color_support.rs:317-350`).
private let pagerAnsi16Palette: [(UInt8, UInt8, UInt8)] = [
    (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
    (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
    (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)
]

private let pagerAnsi16Colors: [TerminalColor] = [
    .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white,
    .brightBlack, .brightRed, .brightGreen, .brightYellow,
    .brightBlue, .brightMagenta, .brightCyan, .brightWhite
]

/// Nearest xterm-256 index for an RGB triple, using the 6×6×6 cube and the
/// 24-step grayscale ramp, whichever is closer.
func pagerNearestIndexed(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
    func cubeStep(_ value: UInt8) -> Int {
        // xterm cube levels: 0, 95, 135, 175, 215, 255.
        let levels = [0, 95, 135, 175, 215, 255]
        var best = 0
        var bestDistance = Int.max
        for (index, level) in levels.enumerated() {
            let distance = abs(level - Int(value))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
    func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return dr * dr + dg * dg + db * db
    }

    let target = (Int(red), Int(green), Int(blue))
    let levels = [0, 95, 135, 175, 215, 255]
    let r = cubeStep(red), g = cubeStep(green), b = cubeStep(blue)
    let cubeIndex = 16 + 36 * r + 6 * g + b
    let cubeDistance = distance(target, (levels[r], levels[g], levels[b]))

    // Grayscale ramp: indices 232...255 at 8 + 10n.
    let average = (Int(red) + Int(green) + Int(blue)) / 3
    let step = min(23, max(0, (average - 8 + 5) / 10))
    let grayValue = 8 + 10 * step
    let grayDistance = distance(target, (grayValue, grayValue, grayValue))

    return grayDistance < cubeDistance ? UInt8(232 + step) : UInt8(cubeIndex)
}

/// Nearest ANSI-16 color for an RGB triple (`rgb_to_ansi16`,
/// `color_support.rs:317-350`) — squared-Euclidean over the standard palette.
func pagerNearestAnsi16(red: UInt8, green: UInt8, blue: UInt8) -> TerminalColor {
    var best = 0
    var bestDistance = Int.max
    for (index, entry) in pagerAnsi16Palette.enumerated() {
        let dr = Int(entry.0) - Int(red)
        let dg = Int(entry.1) - Int(green)
        let db = Int(entry.2) - Int(blue)
        let distance = dr * dr + dg * dg + db * db
        if distance < bestDistance {
            bestDistance = distance
            best = index
        }
    }
    return pagerAnsi16Colors[best]
}

/// `quantize_color` (`color_support.rs:216-231`) — the downgrade path a
/// truecolor palette takes on a terminal that cannot render it.
public func pagerQuantize(_ color: TerminalColor, to level: PagerColorLevel) -> TerminalColor {
    switch level {
    case .trueColor:
        return color
    case .none:
        return .reset
    case .ansi256:
        guard case .rgb(let r, let g, let b) = color else { return color }
        return .indexed(pagerNearestIndexed(red: r, green: g, blue: b))
    case .basic:
        switch color {
        case .rgb(let r, let g, let b):
            return pagerNearestAnsi16(red: r, green: g, blue: b)
        case .indexed(let index):
            // 0–15 map straight through (`indexed_to_ansi16`, `:284-311`).
            if index < 16 { return pagerAnsi16Colors[Int(index)] }
            let (r, g, b) = pagerIndexedToRGB(index)
            return pagerNearestAnsi16(red: r, green: g, blue: b)
        default:
            return color
        }
    }
}

/// The RGB an xterm-256 index stands for, needed to fold 256 down to 16.
func pagerIndexedToRGB(_ index: UInt8) -> (UInt8, UInt8, UInt8) {
    if index < 16 { return pagerAnsi16Palette[Int(index)] }
    if index >= 232 {
        let value = UInt8(min(255, 8 + 10 * (Int(index) - 232)))
        return (value, value, value)
    }
    let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
    let offset = Int(index) - 16
    return (levels[offset / 36], levels[(offset / 6) % 6], levels[offset % 6])
}

extension PagerRenderTheme {
    /// Every slot pushed through `pagerQuantize`, so a truecolor palette can be
    /// painted on a 256- or 16-color terminal without the renderer knowing.
    public func quantized(to level: PagerColorLevel) -> PagerRenderTheme {
        guard level != .trueColor else { return self }
        var copy = self
        func fold(_ keyPath: WritableKeyPath<PagerRenderTheme, TerminalColor>) {
            copy[keyPath: keyPath] = pagerQuantize(copy[keyPath: keyPath], to: level)
        }
        for keyPath in PagerRenderTheme.colorSlots { fold(keyPath) }
        return copy
    }

    /// Every color slot, so quantization and any future whole-palette transform
    /// cannot silently miss a field added later.
    // `WritableKeyPath` is not `Sendable`, but this is an immutable `let` of
    // compile-time key paths with no shared mutable state behind it.
    nonisolated(unsafe) static let colorSlots: [WritableKeyPath<PagerRenderTheme, TerminalColor>] = [
        \.bgBase, \.bgLight, \.bgDark, \.bgHighlight, \.bgHover, \.bgVisual, \.bgTerminal,
        \.textPrimary, \.textSecondary, \.grayDim, \.gray, \.grayBright,
        \.accentUser, \.accentAssistant, \.accentThinking, \.accentTool, \.accentSystem,
        \.accentError, \.accentSuccess, \.accentRunning, \.accentSkill, \.accentPlan,
        \.accentVerify, \.accentFeedback, \.accentRemember, \.accentModel, \.fuzzyAccent,
        \.command, \.path, \.running, \.warning,
        \.promptBorder, \.promptBorderActive, \.selectionBorder, \.hoverBorder,
        \.scrollbarBackground, \.scrollbarForeground, \.linkForeground,
        \.diffDeleteBackground, \.diffDeleteForeground,
        \.diffInsertBackground, \.diffInsertForeground,
        \.diffEqualForeground, \.diffGutterForeground,
        \.pasteBackground, \.pasteForeground, \.pasteDim
    ]
}

// MARK: - Appearance

public enum PagerAppearance: Sendable, Equatable, Hashable {
    case dark
    case light
}

// MARK: - OSC-11 background probe

/// The terminal-side half of the OSC-11 probe, factored out so the parse and
/// classification logic can be tested without a tty.
public protocol PagerOSC11Transport: Sendable {
    /// Write the query and return the terminal's raw reply, or `nil` if the
    /// terminal did not answer within the deadline.
    func exchange(query: String, timeout: TimeInterval) throws -> String?
}

public enum PagerOSC11 {
    /// The query the reference writes (`osc11.rs:45`).
    public static let query = "\u{1B}]11;?\u{07}"

    /// `OSC11_TIMEOUT` (`osc11.rs:27`).
    public static let timeout: TimeInterval = 0.5

    /// Parse `rgb:RRRR/GGGG/BBBB` (or the 8-bit-per-channel spelling) out of a
    /// terminal reply (`osc11.rs:74-104`).
    ///
    /// Channels wider than two hex digits are shifted down by 8 rather than
    /// scaled, which is what the reference does and what makes `ffff` and `ff`
    /// both land on 255.
    public static func parse(reply: String) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let range = reply.range(of: "rgb:") else { return nil }
        let body = reply[range.upperBound...]
        let fields = body.split(whereSeparator: { $0 == "/" || $0 == "\u{07}" || $0 == "\u{1B}" })
        guard fields.count >= 3 else { return nil }
        var channels: [UInt8] = []
        for field in fields.prefix(3) {
            let digits = field.prefix { $0.isHexDigit }
            guard !digits.isEmpty, let value = UInt32(digits, radix: 16) else { return nil }
            channels.append(digits.count > 2 ? UInt8(truncatingIfNeeded: value >> 8) : UInt8(truncatingIfNeeded: value))
        }
        return (channels[0], channels[1], channels[2])
    }

    /// Classify a probed background as dark or light
    /// (`LUMINANCE_THRESHOLD = 0.5`, `osc11.rs:24`, `:59-68`).
    public static func classify(red: UInt8, green: UInt8, blue: UInt8) -> PagerAppearance {
        pagerRelativeLuminance(red: red, green: green, blue: blue) < 0.5 ? .dark : .light
    }

    /// Run the probe. Any failure — not a tty, no reply, an unparseable reply —
    /// yields `nil`, and the caller falls through to its next source.
    ///
    /// The reference is emphatic that this is startup-only (`osc11.rs:12-15`):
    /// once the event loop owns the tty, a probe reply lands in the input
    /// stream as garbage keystrokes instead of here.
    public static func detect(transport: PagerOSC11Transport) -> PagerAppearance? {
        // `exchange` both throws and returns an optional, so `try?` already
        // flattens the two failure modes into one `String?`.
        guard let reply = try? transport.exchange(query: query, timeout: timeout),
              // Reject a reply that was cut short: without a BEL or ST
              // terminator we may be holding half a color.
              reply.hasSuffix("\u{07}") || reply.hasSuffix("\u{1B}\\"),
              let color = parse(reply: reply)
        else { return nil }
        return classify(red: color.red, green: color.green, blue: color.blue)
    }
}

// MARK: - System appearance

/// How the OS reports dark/light. The reference uses the `dark-light` crate;
/// on macOS that reads `AppleInterfaceStyle` from the global domain
/// (`system_appearance.rs:3-9`), which is what this reads directly.
public enum PagerSystemAppearance {
    /// The desktop-API answer, with no OSC-11 fallback — safe to call at any
    /// time, including from the running event loop (`detect`, `:38-45`).
    public static func detect() -> PagerAppearance? {
        #if canImport(Darwin)
        guard let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") else {
            // No key at all means Light on macOS; it is only ever set to
            // "Dark". Absent *and* not a GUI session is indistinguishable here,
            // so the caller treats `nil` and `.light` differently on purpose.
            return isGraphicalSession() ? .light : nil
        }
        return style.lowercased().hasPrefix("dark") ? .dark : .light
        #else
        // No portal client in this build; the OSC-11 fallback carries Linux.
        return nil
        #endif
    }

    /// Startup-only detection: the desktop API first, then the OSC-11 probe
    /// (`detect_with_osc11_fallback`, `:58-65`).
    public static func detect(withProbe transport: PagerOSC11Transport?) -> PagerAppearance? {
        if let appearance = detect() { return appearance }
        guard let transport else { return nil }
        return PagerOSC11.detect(transport: transport)
    }

    #if canImport(Darwin)
    /// `AppleInterfaceStyle` is only meaningful inside a window session. Over
    /// SSH there is no such session and the absent key means "unknown", not
    /// "light" — reading it as light would flip a remote user's theme.
    private static func isGraphicalSession() -> Bool {
        ProcessInfo.processInfo.environment["SSH_CONNECTION"] == nil
            && ProcessInfo.processInfo.environment["SSH_TTY"] == nil
    }
    #endif

    /// `to_theme_kind` (`system_appearance.rs:95-104`).
    public static func themeKind(
        for appearance: PagerAppearance,
        darkTheme: PagerThemeKind? = nil,
        lightTheme: PagerThemeKind? = nil
    ) -> PagerThemeKind {
        switch appearance {
        case .dark: return darkTheme ?? .grokNight
        case .light: return lightTheme ?? .grokDay
        }
    }
}

// MARK: - Resolution

/// Everything the renderer needs to turn a stored preference into a palette.
public struct PagerThemeResolution: Sendable, Equatable {
    public var kind: PagerThemeKind
    public var theme: PagerRenderTheme
    public var colorLevel: PagerColorLevel
    /// True when the resolution followed the system appearance, which is what
    /// tells a caller whether it needs to re-resolve when the system flips.
    public var followsSystemAppearance: Bool

    public init(
        kind: PagerThemeKind,
        theme: PagerRenderTheme,
        colorLevel: PagerColorLevel,
        followsSystemAppearance: Bool
    ) {
        self.kind = kind
        self.theme = theme
        self.colorLevel = colorLevel
        self.followsSystemAppearance = followsSystemAppearance
    }
}

/// Resolve a stored preference to a painted palette
/// (`theme/cache.rs:178-204` plus `Theme::current`, `theme/mod.rs:267-312`).
///
/// Order of operations matters and mirrors the reference: resolve `auto` first,
/// then clamp a truecolor-only theme against what the terminal can do, then
/// quantize. Quantizing before clamping would leave a Rose Pine palette folded
/// into 16 muddy colors instead of falling back to GrokNight.
public func pagerResolveTheme(
    preference: PagerThemePreference,
    colorLevel: PagerColorLevel,
    appearance: PagerAppearance? = nil,
    darkTheme: PagerThemeKind? = nil,
    lightTheme: PagerThemeKind? = nil,
    terminalNativeLock: Bool = false
) -> PagerThemeResolution {
    // Minimal mode locks the terminal's own palette and caps color at 16
    // (`theme/cache.rs:114-125`).
    if terminalNativeLock {
        let level = min(colorLevel, .basic)
        return PagerThemeResolution(
            kind: .terminalDefault,
            theme: PagerRenderTheme.terminalDefault.quantized(to: level),
            colorLevel: level,
            followsSystemAppearance: false
        )
    }

    var followsSystem = false
    var kind: PagerThemeKind
    switch preference {
    case .fixed(let selected):
        kind = selected
    case .auto:
        followsSystem = true
        // Detection failure falls back to GrokNight rather than guessing light:
        // a dark theme on a light terminal is legible, the reverse washes out.
        kind = appearance.map {
            PagerSystemAppearance.themeKind(for: $0, darkTheme: darkTheme, lightTheme: lightTheme)
        } ?? .grokNight
    }

    kind = kind.clamped(to: colorLevel)
    return PagerThemeResolution(
        kind: kind,
        theme: kind.theme.quantized(to: colorLevel),
        colorLevel: colorLevel,
        followsSystemAppearance: followsSystem
    )
}
