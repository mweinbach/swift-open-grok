// PagerThemeCatalog.swift
//
// The reference's six palettes, transcribed field-for-field from
// `xai-grok-pager-render/src/theme/` at upstream 9ed09e2a.
//
// The reference splits its palettes into per-theme modules that each build a
// `Theme` from a small named palette. That indirection buys nothing in Swift —
// the palette constants are used once — so each theme here is a flat literal
// and the reference's palette names live in comments beside the values they
// produced.

import Foundation
import OpenGrokTerminalCore

// MARK: - Theme identity

/// The selectable themes, mirroring `ThemeKind` (`theme/mod.rs:30-44`).
///
/// `terminalDefault` is not a `ThemeKind` upstream — it is a session-wide lock
/// engaged by minimal mode (`theme/cache.rs:114-125`). It is a case here so a
/// single enum can name every palette the renderer can be handed, but it is
/// deliberately excluded from `selectable`, which is what `/theme` offers.
public enum PagerThemeKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case grokNight = "groknight"
    case grokDay = "grokday"
    case tokyoNight = "tokyonight"
    case rosePineMoon = "rosepine-moon"
    case oscuraMidnight = "oscura-midnight"
    case terminalDefault = "terminal-default"

    /// `ThemeKind::ALL` (`theme/mod.rs:48-54`) — the concrete themes, in the
    /// reference's own order, which is the order `/theme` lists them in.
    public static let selectable: [PagerThemeKind] = [
        .grokNight, .grokDay, .tokyoNight, .rosePineMoon, .oscuraMidnight
    ]

    /// `display_name_for_canonical` (`theme/mod.rs:143-152`). The reference
    /// omits `oscura-midnight` from that table and lets it fall through
    /// verbatim; this port names it, because a picker row reading
    /// `oscura-midnight` next to `Rose Pine Moon` is just a bug the user sees.
    public var displayName: String {
        switch self {
        case .grokNight: return "Grok Night"
        case .grokDay: return "Grok Day"
        case .tokyoNight: return "Tokyo Night"
        case .rosePineMoon: return "Rose Pine Moon"
        case .oscuraMidnight: return "Oscura Midnight"
        case .terminalDefault: return "Terminal Default"
        }
    }

    /// `requires_truecolor` (`theme/mod.rs:90-100`). The three ported themes
    /// are all truecolor-only; quantizing them to 16 colors collapses palettes
    /// built entirely out of near-neighbour shades.
    public var requiresTrueColor: Bool {
        switch self {
        case .grokNight, .grokDay, .terminalDefault: return false
        case .tokyoNight, .rosePineMoon, .oscuraMidnight: return true
        }
    }

    /// `from_name` (`theme/mod.rs:104-117`), case-insensitive, including every
    /// alias the reference accepts. `auto` is not a palette and resolves to
    /// `nil` here — `PagerThemePreference` is what carries it.
    public static func named(_ name: String) -> PagerThemeKind? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "groknight", "grok-night", "dark": return .grokNight
        case "grokday", "grok-day", "light", "day": return .grokDay
        case "tokyonight", "tokyo-night", "tokyo": return .tokyoNight
        case "rosepine", "rose-pine", "rosepine-moon", "rose-pine-moon": return .rosePineMoon
        case "oscura", "oscura-midnight": return .oscuraMidnight
        case "terminal", "terminal-default", "terminal_default", "none": return .terminalDefault
        default: return nil
        }
    }

    public var theme: PagerRenderTheme {
        switch self {
        case .grokNight: return .grokNight
        case .grokDay: return .grokDay
        case .tokyoNight: return .tokyoNight
        case .rosePineMoon: return .rosePineMoon
        case .oscuraMidnight: return .oscuraMidnight
        case .terminalDefault: return .terminalDefault
        }
    }

    /// `available()` (`theme/mod.rs:60-71`): without truecolor the reference
    /// offers only the two themes that survive quantization.
    public static func available(colorLevel: PagerColorLevel) -> [PagerThemeKind] {
        colorLevel == .trueColor ? selectable : [.grokNight, .grokDay]
    }

    /// `clamp_to_terminal` (`theme/mod.rs:332-340`): a truecolor-only theme
    /// selected on a terminal that cannot render it falls back to GrokNight
    /// rather than rendering as mush.
    public func clamped(to colorLevel: PagerColorLevel) -> PagerThemeKind {
        guard requiresTrueColor, colorLevel != .trueColor else { return self }
        return .grokNight
    }
}

/// What the user asked for, which is not always a palette: `auto` follows the
/// system appearance and only becomes a `PagerThemeKind` once resolved
/// (`theme/cache.rs:178-204`).
public enum PagerThemePreference: Sendable, Equatable, Hashable {
    case auto
    case fixed(PagerThemeKind)

    public var canonicalName: String {
        switch self {
        case .auto: return "auto"
        case .fixed(let kind): return kind.rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .fixed(let kind): return kind.displayName
        }
    }

    public static func named(_ name: String) -> PagerThemePreference? {
        let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized == "auto" || normalized == "system" { return .auto }
        return PagerThemeKind.named(normalized).map(PagerThemePreference.fixed)
    }
}

// MARK: - GrokNight

extension PagerRenderTheme {
    /// GrokNight — the reference default (`theme/groknight.rs:74-186`). Its
    /// values are this struct's own defaults, so the literal is empty.
    public static let grokNight = PagerRenderTheme()

    /// GrokDay (`theme/grokday.rs:66-176`).
    public static let grokDay = PagerRenderTheme(
        bgBase: .rgb(238, 238, 238),
        bgLight: .rgb(222, 222, 222),
        bgDark: .rgb(228, 228, 228),
        bgHighlight: .rgb(222, 222, 222),
        bgHover: .rgb(208, 208, 208),
        bgVisual: .rgb(198, 198, 198),
        bgTerminal: .rgb(245, 245, 245),
        textPrimary: .rgb(38, 38, 38),
        textSecondary: .rgb(68, 68, 68),
        grayDim: .rgb(165, 165, 165),
        gray: .rgb(118, 118, 118),
        grayBright: .rgb(98, 98, 98),
        accentUser: .rgb(68, 68, 68),
        accentAssistant: .rgb(125, 75, 198),
        accentThinking: .rgb(125, 75, 198),
        accentTool: .rgb(98, 98, 98),
        accentSystem: .rgb(47, 100, 210),
        accentError: .rgb(205, 48, 72),
        accentSuccess: .rgb(55, 142, 35),
        accentRunning: .rgb(125, 75, 198),
        accentSkill: .rgb(47, 100, 210),
        accentPlan: .rgb(168, 120, 10),
        accentVerify: .rgb(120, 80, 160),
        accentFeedback: .rgb(12, 148, 124),
        accentRemember: .rgb(76, 175, 80),
        accentModel: .rgb(10, 142, 112),
        fuzzyAccent: .rgb(47, 100, 210),
        command: .rgb(162, 118, 18),
        path: .rgb(195, 105, 30),
        running: .rgb(0, 130, 170),
        warning: .rgb(162, 118, 18),
        promptBorder: .rgb(200, 200, 205),
        promptBorderActive: .rgb(165, 165, 175),
        selectionBorder: .rgb(185, 185, 190),
        hoverBorder: .rgb(212, 212, 216),
        scrollbarBackground: .rgb(234, 234, 234),
        scrollbarForeground: .rgb(222, 222, 222),
        linkForeground: .rgb(47, 100, 210),
        diffDeleteBackground: .rgb(245, 218, 222),
        diffDeleteForeground: .rgb(205, 48, 72),
        diffInsertBackground: .rgb(218, 242, 220),
        diffInsertForeground: .rgb(55, 142, 35),
        diffEqualForeground: .rgb(118, 118, 118),
        diffGutterForeground: .rgb(118, 118, 118),
        pasteBackground: .rgb(222, 222, 222),
        pasteForeground: .rgb(68, 68, 68),
        pasteDim: .rgb(178, 178, 178)
    )

    /// Tokyo Night (Storm) — `theme/tokyonight.rs:158-241`.
    public static let tokyoNight = PagerRenderTheme(
        bgBase: .rgb(36, 40, 59),
        bgLight: .rgb(41, 46, 66),
        bgDark: .rgb(41, 46, 66),
        bgHighlight: .rgb(41, 46, 66),
        bgHover: .rgb(40, 49, 76),
        bgVisual: .rgb(40, 52, 87),
        bgTerminal: .rgb(26, 27, 38),
        textPrimary: .rgb(192, 202, 245),
        textSecondary: .rgb(169, 177, 214),
        grayDim: .rgb(59, 66, 97),
        gray: .rgb(86, 95, 137),
        grayBright: .rgb(115, 122, 162),
        accentUser: .rgb(122, 162, 247),
        accentAssistant: .rgb(187, 154, 247),
        accentThinking: .rgb(59, 66, 97),
        accentTool: .rgb(115, 122, 162),
        accentSystem: .rgb(122, 162, 247),
        accentError: .rgb(247, 118, 142),
        accentSuccess: .rgb(158, 206, 106),
        accentRunning: .rgb(187, 154, 247),
        accentSkill: .rgb(100, 180, 170),
        accentPlan: .rgb(230, 180, 50),
        accentVerify: .rgb(187, 154, 247),
        accentFeedback: .rgb(115, 218, 202),
        accentRemember: .rgb(139, 195, 74),
        accentModel: .rgb(26, 188, 156),
        fuzzyAccent: .rgb(122, 162, 247),
        command: .rgb(224, 175, 104),
        path: .rgb(255, 158, 100),
        running: .rgb(125, 207, 255),
        warning: .rgb(224, 175, 104),
        promptBorder: .rgb(60, 75, 120),
        promptBorderActive: .rgb(75, 92, 140),
        selectionBorder: .rgb(58, 72, 115),
        hoverBorder: .rgb(55, 58, 80),
        scrollbarBackground: .rgb(31, 35, 53),
        scrollbarForeground: .rgb(41, 46, 66),
        linkForeground: .rgb(122, 162, 247),
        diffDeleteBackground: .rgb(85, 15, 20),
        diffDeleteForeground: .rgb(247, 118, 142),
        diffInsertBackground: .rgb(15, 65, 20),
        diffInsertForeground: .rgb(158, 206, 106),
        diffEqualForeground: .rgb(86, 95, 137),
        diffGutterForeground: .rgb(86, 95, 137),
        pasteBackground: .rgb(31, 35, 53),
        pasteForeground: .rgb(169, 177, 214),
        pasteDim: .rgb(59, 66, 97)
    )

    /// Rose Pine Moon — `theme/rosepine.rs:29-117`. Palette names from
    /// `rosepine.rs:10-27` are noted where a value is reused.
    public static let rosePineMoon = PagerRenderTheme(
        bgBase: .rgb(35, 33, 54),             // BASE
        bgLight: .rgb(57, 53, 82),            // OVERLAY
        bgDark: .rgb(42, 39, 63),             // SURFACE
        bgHighlight: .rgb(57, 53, 82),        // OVERLAY
        bgHover: .rgb(68, 65, 90),            // HIGHLIGHT_MED
        bgVisual: .rgb(68, 65, 90),           // HIGHLIGHT_MED
        bgTerminal: .rgb(35, 33, 54),         // BASE
        textPrimary: .rgb(224, 222, 244),     // TEXT
        textSecondary: .rgb(144, 140, 170),   // SUBTLE
        grayDim: .rgb(68, 65, 90),            // HIGHLIGHT_MED
        gray: .rgb(110, 106, 134),            // MUTED
        grayBright: .rgb(144, 140, 170),      // SUBTLE
        accentUser: .rgb(224, 222, 244),      // TEXT
        accentAssistant: .rgb(196, 167, 231), // IRIS
        accentThinking: .rgb(110, 106, 134),  // MUTED
        accentTool: .rgb(144, 140, 170),      // SUBTLE
        accentSystem: .rgb(62, 143, 176),     // PINE
        accentError: .rgb(235, 111, 150),     // LOVE
        accentSuccess: .rgb(156, 207, 216),   // FOAM
        accentRunning: .rgb(110, 106, 134),   // MUTED
        accentSkill: .rgb(144, 140, 170),     // SUBTLE
        accentPlan: .rgb(246, 193, 119),      // GOLD
        accentVerify: .rgb(62, 143, 176),     // PINE
        accentFeedback: .rgb(156, 207, 216),  // FOAM
        accentRemember: .rgb(62, 143, 176),   // PINE
        accentModel: .rgb(62, 143, 176),      // PINE
        fuzzyAccent: .rgb(62, 143, 176),      // PINE
        command: .rgb(246, 193, 119),         // GOLD
        path: .rgb(234, 154, 151),            // ROSE
        running: .rgb(156, 207, 216),         // FOAM
        warning: .rgb(246, 193, 119),         // GOLD
        promptBorder: .rgb(68, 65, 90),       // HIGHLIGHT_MED
        promptBorderActive: .rgb(86, 82, 110), // HIGHLIGHT_HIGH
        selectionBorder: .rgb(86, 82, 110),   // HIGHLIGHT_HIGH
        hoverBorder: .rgb(68, 65, 90),        // HIGHLIGHT_MED
        scrollbarBackground: .rgb(42, 40, 62), // HIGHLIGHT_LOW
        scrollbarForeground: .rgb(57, 53, 82), // OVERLAY
        linkForeground: .rgb(156, 207, 216),  // FOAM
        diffDeleteBackground: .rgb(55, 30, 40),
        diffDeleteForeground: .rgb(235, 111, 150),
        diffInsertBackground: .rgb(25, 45, 55),
        diffInsertForeground: .rgb(156, 207, 216),
        diffEqualForeground: .rgb(110, 106, 134),
        diffGutterForeground: .rgb(110, 106, 134),
        pasteBackground: .rgb(42, 39, 63),    // SURFACE
        pasteForeground: .rgb(144, 140, 170), // SUBTLE
        pasteDim: .rgb(110, 106, 134)         // MUTED
    )

    /// Oscura Midnight — `theme/oscura.rs:71-149`.
    ///
    /// `scrollbarForeground` is HIGHLIGHT_HIGH rather than ELEVATED: the
    /// reference notes at `oscura.rs:122-129` that ELEVATED is darker than the
    /// track, which made the thumb invisible.
    public static let oscuraMidnight = PagerRenderTheme(
        bgBase: .rgb(3, 3, 4),                 // BASE
        bgLight: .rgb(15, 18, 22),             // ELEVATED
        bgDark: .rgb(4, 5, 7),                 // SURFACE
        bgHighlight: .rgb(15, 18, 22),         // ELEVATED
        bgHover: .rgb(36, 32, 52),             // HIGHLIGHT_MED
        bgVisual: .rgb(36, 32, 52),            // HIGHLIGHT_MED
        bgTerminal: .rgb(3, 3, 4),             // BASE
        textPrimary: .rgb(228, 228, 228),      // TEXT
        textSecondary: .rgb(190, 190, 190),    // TEXT_DIM
        grayDim: .rgb(94, 100, 108),           // SUBTLE
        gray: .rgb(129, 134, 143),             // MUTED
        grayBright: .rgb(190, 190, 190),       // TEXT_DIM
        accentUser: .rgb(196, 167, 231),       // PURPLE_BRIGHT
        accentAssistant: .rgb(155, 126, 206),  // PURPLE
        accentThinking: .rgb(129, 134, 143),   // MUTED
        accentTool: .rgb(94, 100, 108),        // SUBTLE
        accentSystem: .rgb(125, 207, 223),     // CYAN
        accentError: .rgb(220, 90, 100),       // RED
        accentSuccess: .rgb(80, 180, 140),     // TEAL
        accentRunning: .rgb(110, 90, 154),     // PURPLE_DIM
        accentSkill: .rgb(155, 126, 206),      // PURPLE
        accentPlan: .rgb(235, 217, 110),       // GOLD
        accentVerify: .rgb(155, 126, 206),     // PURPLE
        accentFeedback: .rgb(80, 180, 140),    // TEAL
        accentRemember: .rgb(139, 195, 74),
        accentModel: .rgb(125, 207, 223),      // CYAN
        fuzzyAccent: .rgb(196, 167, 231),      // PURPLE_BRIGHT
        command: .rgb(235, 217, 110),          // GOLD
        path: .rgb(241, 189, 0),               // AMBER
        running: .rgb(125, 207, 223),          // CYAN
        warning: .rgb(235, 217, 110),          // GOLD
        promptBorder: .rgb(36, 32, 52),        // HIGHLIGHT_MED
        promptBorderActive: .rgb(52, 48, 72),  // HIGHLIGHT_HIGH
        selectionBorder: .rgb(52, 48, 72),     // HIGHLIGHT_HIGH
        hoverBorder: .rgb(36, 32, 52),         // HIGHLIGHT_MED
        scrollbarBackground: .rgb(18, 16, 28), // HIGHLIGHT_LOW
        scrollbarForeground: .rgb(52, 48, 72), // HIGHLIGHT_HIGH
        linkForeground: .rgb(125, 207, 223),   // CYAN
        diffDeleteBackground: .rgb(45, 15, 25),
        diffDeleteForeground: .rgb(220, 90, 100),
        diffInsertBackground: .rgb(10, 35, 30),
        diffInsertForeground: .rgb(80, 180, 140),
        diffEqualForeground: .rgb(129, 134, 143),
        diffGutterForeground: .rgb(129, 134, 143),
        pasteBackground: .rgb(4, 5, 7),        // SURFACE
        pasteForeground: .rgb(190, 190, 190),  // TEXT_DIM
        pasteDim: .rgb(129, 134, 143)          // MUTED
    )

    /// `Theme::terminal_default()` (`theme/terminal_default.rs:36-119`) — every
    /// slot is `Reset` or a named ANSI-16 color, which is what makes it safe
    /// under `NO_COLOR` and in minimal mode. The reference de-emphasizes the
    /// secondary roles with `Modifier::DIM` at paint time rather than by
    /// picking a dimmer color, so they are `Reset` here too.
    public static let terminalDefault = PagerRenderTheme(
        bgBase: .reset,
        bgLight: .reset,
        bgDark: .reset,
        bgHighlight: .reset,
        bgHover: .reset,
        bgVisual: .reset,
        bgTerminal: .reset,
        textPrimary: .reset,
        textSecondary: .reset,
        grayDim: .brightBlack,
        gray: .brightBlack,
        grayBright: .reset,
        accentUser: .reset,
        accentAssistant: .magenta,
        accentThinking: .brightBlack,
        accentTool: .brightBlack,
        accentSystem: .blue,
        accentError: .red,
        accentSuccess: .green,
        accentRunning: .magenta,
        accentSkill: .blue,
        accentPlan: .yellow,
        accentVerify: .magenta,
        accentFeedback: .cyan,
        accentRemember: .green,
        accentModel: .cyan,
        fuzzyAccent: .cyan,
        command: .yellow,
        path: .cyan,
        running: .cyan,
        warning: .yellow,
        promptBorder: .brightBlack,
        promptBorderActive: .reset,
        selectionBorder: .brightBlack,
        hoverBorder: .brightBlack,
        scrollbarBackground: .reset,
        scrollbarForeground: .brightBlack,
        linkForeground: .blue,
        diffDeleteBackground: .reset,
        diffDeleteForeground: .red,
        diffInsertBackground: .reset,
        diffInsertForeground: .green,
        diffEqualForeground: .brightBlack,
        diffGutterForeground: .brightBlack,
        pasteBackground: .reset,
        pasteForeground: .brightBlack,
        pasteDim: .brightBlack
    )
}

// MARK: - Polarity

extension PagerRenderTheme {
    /// Whether the palette reads as dark, by the same BT.709 relative-luminance
    /// test the reference applies to `bg_base` (`theme/mod.rs:412-421`,
    /// `osc11.rs:59-68`). A non-RGB background has no measurable luminance, so
    /// it inherits the terminal's own polarity and is reported as dark — the
    /// side that degrades more gracefully if the guess is wrong.
    public var isDark: Bool {
        guard case .rgb(let r, let g, let b) = bgBase else { return true }
        return pagerRelativeLuminance(red: r, green: g, blue: b) < 0.5
    }
}

/// BT.709 relative luminance over linearized sRGB (`osc11.rs:59-116`).
public func pagerRelativeLuminance(red: UInt8, green: UInt8, blue: UInt8) -> Double {
    func linear(_ channel: UInt8) -> Double {
        let value = Double(channel) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
}
