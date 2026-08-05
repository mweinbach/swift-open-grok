import OpenGrokTerminalCore

/// The palette roles the Rust pager's `Theme` struct exposes, ported so frame
/// code can name colors the same way the reference does.
///
/// The reference ships five concrete themes; this port carries the two that do
/// not require truecolor — GrokNight (the default) and GrokDay — since those
/// are the pair the reference itself falls back to on a non-truecolor terminal.
public struct PagerRenderTheme: Sendable, Equatable, Hashable {
    public var bgBase: TerminalColor
    public var bgLight: TerminalColor
    public var bgDark: TerminalColor
    public var bgHighlight: TerminalColor
    public var bgVisual: TerminalColor

    public var textPrimary: TerminalColor
    public var textSecondary: TerminalColor
    public var grayDim: TerminalColor
    public var gray: TerminalColor
    public var grayBright: TerminalColor

    public var accentUser: TerminalColor
    public var accentAssistant: TerminalColor
    public var accentThinking: TerminalColor
    public var accentTool: TerminalColor
    public var accentSystem: TerminalColor
    public var accentError: TerminalColor
    public var accentSuccess: TerminalColor
    public var accentRunning: TerminalColor
    public var accentSkill: TerminalColor
    public var accentPlan: TerminalColor

    public var command: TerminalColor
    public var path: TerminalColor
    public var warning: TerminalColor

    public var promptBorder: TerminalColor
    public var promptBorderActive: TerminalColor
    public var selectionBorder: TerminalColor
    public var scrollbarForeground: TerminalColor
    public var linkForeground: TerminalColor

    public init(
        bgBase: TerminalColor = .rgb(20, 20, 20),
        bgLight: TerminalColor = .rgb(36, 36, 36),
        bgDark: TerminalColor = .rgb(28, 28, 28),
        bgHighlight: TerminalColor = .rgb(36, 36, 36),
        bgVisual: TerminalColor = .rgb(54, 54, 54),
        textPrimary: TerminalColor = .rgb(225, 225, 225),
        textSecondary: TerminalColor = .rgb(200, 200, 200),
        grayDim: TerminalColor = .rgb(88, 88, 88),
        gray: TerminalColor = .rgb(108, 108, 108),
        grayBright: TerminalColor = .rgb(120, 120, 120),
        accentUser: TerminalColor = .rgb(200, 200, 200),
        accentAssistant: TerminalColor = .rgb(187, 154, 247),
        accentThinking: TerminalColor = .rgb(187, 154, 247),
        accentTool: TerminalColor = .rgb(120, 120, 120),
        accentSystem: TerminalColor = .rgb(122, 162, 247),
        accentError: TerminalColor = .rgb(247, 118, 142),
        accentSuccess: TerminalColor = .rgb(158, 206, 106),
        accentRunning: TerminalColor = .rgb(187, 154, 247),
        accentSkill: TerminalColor = .rgb(122, 162, 247),
        accentPlan: TerminalColor = .rgb(255, 219, 141),
        command: TerminalColor = .rgb(224, 175, 104),
        path: TerminalColor = .rgb(255, 158, 100),
        warning: TerminalColor = .rgb(224, 175, 104),
        promptBorder: TerminalColor = .rgb(50, 50, 55),
        promptBorderActive: TerminalColor = .rgb(80, 80, 88),
        selectionBorder: TerminalColor = .rgb(60, 60, 65),
        scrollbarForeground: TerminalColor = .rgb(36, 36, 36),
        linkForeground: TerminalColor = .rgb(122, 166, 218)
    ) {
        self.bgBase = bgBase
        self.bgLight = bgLight
        self.bgDark = bgDark
        self.bgHighlight = bgHighlight
        self.bgVisual = bgVisual
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.grayDim = grayDim
        self.gray = gray
        self.grayBright = grayBright
        self.accentUser = accentUser
        self.accentAssistant = accentAssistant
        self.accentThinking = accentThinking
        self.accentTool = accentTool
        self.accentSystem = accentSystem
        self.accentError = accentError
        self.accentSuccess = accentSuccess
        self.accentRunning = accentRunning
        self.accentSkill = accentSkill
        self.accentPlan = accentPlan
        self.command = command
        self.path = path
        self.warning = warning
        self.promptBorder = promptBorder
        self.promptBorderActive = promptBorderActive
        self.selectionBorder = selectionBorder
        self.scrollbarForeground = scrollbarForeground
        self.linkForeground = linkForeground
    }

    /// GrokNight — the reference default.
    public static let grokNight = PagerRenderTheme()

    /// GrokDay, the reference's light counterpart.
    public static let grokDay = PagerRenderTheme(
        bgBase: .rgb(250, 250, 250),
        bgLight: .rgb(238, 238, 238),
        bgDark: .rgb(240, 240, 240),
        bgHighlight: .rgb(230, 230, 230),
        bgVisual: .rgb(214, 214, 214),
        textPrimary: .rgb(30, 30, 30),
        textSecondary: .rgb(60, 60, 60),
        grayDim: .rgb(150, 150, 150),
        gray: .rgb(120, 120, 120),
        grayBright: .rgb(100, 100, 100),
        accentUser: .rgb(60, 60, 60),
        accentAssistant: .rgb(126, 87, 194),
        accentThinking: .rgb(126, 87, 194),
        accentTool: .rgb(100, 100, 100),
        accentSystem: .rgb(45, 106, 200),
        accentError: .rgb(197, 40, 70),
        accentSuccess: .rgb(70, 140, 40),
        accentRunning: .rgb(126, 87, 194),
        accentSkill: .rgb(45, 106, 200),
        accentPlan: .rgb(168, 120, 10),
        command: .rgb(160, 110, 20),
        path: .rgb(190, 95, 30),
        warning: .rgb(160, 110, 20),
        promptBorder: .rgb(205, 205, 205),
        promptBorderActive: .rgb(170, 170, 172),
        selectionBorder: .rgb(190, 190, 195),
        scrollbarForeground: .rgb(214, 214, 214),
        linkForeground: .rgb(40, 100, 170)
    )

    /// A `Reset`-everything palette for `NO_COLOR` and minimal mode, matching
    /// the reference's `Theme::terminal_default()`. Roles that carry meaning
    /// through color alone fall back to the terminal's own 16 colors.
    public static let terminalDefault = PagerRenderTheme(
        bgBase: .reset,
        bgLight: .reset,
        bgDark: .reset,
        bgHighlight: .reset,
        bgVisual: .reset,
        textPrimary: .reset,
        textSecondary: .reset,
        grayDim: .brightBlack,
        gray: .brightBlack,
        grayBright: .brightBlack,
        accentUser: .cyan,
        accentAssistant: .magenta,
        accentThinking: .magenta,
        accentTool: .brightBlack,
        accentSystem: .blue,
        accentError: .red,
        accentSuccess: .green,
        accentRunning: .magenta,
        accentSkill: .blue,
        accentPlan: .yellow,
        command: .yellow,
        path: .yellow,
        warning: .yellow,
        promptBorder: .brightBlack,
        promptBorderActive: .white,
        selectionBorder: .brightBlack,
        scrollbarForeground: .brightBlack,
        linkForeground: .blue
    )

    public static let `default` = PagerRenderTheme.grokNight
}

/// Glyph vocabulary, mirroring `xai-grok-pager-render/src/glyphs.rs`.
///
/// The reference picks a legacy-console fallback per glyph at runtime; this
/// port targets terminals that render the "fancy" branch, so only the widths
/// carry over as a contract — every glyph here is one column except
/// `promptArrow`, which is two.
public enum PagerGlyphs {
    public static let accentBar = "\u{2503}"        // ┃
    public static let collapsedAccent = "\u{2759}"  // ❙
    public static let promptArrow = "\u{276F} "     // "❯ "
    public static let promptArrowWidth = 2
    public static let toolBullet = "\u{25C6}"       // ◆
    public static let groupBullet = "\u{25C8}"      // ◈
    public static let filledDot = "\u{25CF}"        // ●
    public static let chevronRight = "\u{203A}"     // ›
    public static let chevronDown = "\u{2304}"      // ⌄
    public static let tokenArrow = "\u{21E3}"       // ⇣
    public static let ellipsis = "\u{2026}"         // …
    public static let statusSeparator = "\u{2502}"  // │

    public static let emptyDot = "\u{25CB}"         // ○
    public static let ballotX = "\u{2717}"          // ✗

    /// Modal windows use a square border (`Borders::ALL` with the default
    /// border type), unlike the composer's rounded box.
    public static let modalTopLeft: Character = "\u{250C}"      // ┌
    public static let modalTopRight: Character = "\u{2510}"     // ┐
    public static let modalBottomLeft: Character = "\u{2514}"   // └
    public static let modalBottomRight: Character = "\u{2518}"  // ┘

    public static let borderTopLeft: Character = "\u{256D}"      // ╭
    public static let borderTopRight: Character = "\u{256E}"     // ╮
    public static let borderBottomLeft: Character = "\u{2570}"   // ╰
    public static let borderBottomRight: Character = "\u{256F}"  // ╯
    public static let borderHorizontal: Character = "\u{2500}"   // ─
    public static let borderVertical: Character = "\u{2502}"     // │

    public static let brailleSpinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"]
    public static let dotSpinner = ["⋅", ":", "⸬", "⁙", "⋅", ":", "⸬", "⁙"]
    public static let progressBlocks = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]

    public static func brailleSpinnerFrame(_ tick: Int) -> String {
        let index = (tick / spinnerDivisor) % brailleSpinner.count
        return brailleSpinner[index < 0 ? index + brailleSpinner.count : index]
    }

    /// `SPINNER_DIVISOR` from `views/turn_status.rs:32` — at the reference's
    /// 30 fps this advances the spinner roughly every 133 ms.
    public static let spinnerDivisor = 4
}

/// Layout constants from `scrollback/layout.rs` and `appearance/config.rs`.
public enum PagerLayoutMetrics {
    public static let accentWidth = 1
    public static let blockPadLeft = 2
    public static let blockPadRight = 2
    /// Columns consumed by chrome on every transcript row.
    public static var chromeWidth: Int { accentWidth + blockPadLeft + blockPadRight }

    /// `SHORT_TERMINAL_ROWS` (`views/agent.rs:83`): at or below this the
    /// optional bottom padding rows collapse.
    public static let shortTerminalRows = 16

    /// `MAX_DROPDOWN_ROWS` (`views/slash_dropdown.rs:24`).
    public static let maxDropdownRows = 6

    /// Execute-tool output preview budget (`appearance/config.rs:692-693`).
    public static let executePreviewFirstLines = 2
    public static let executePreviewLastLines = 3

    /// Thinking truncation budget (`appearance/config.rs:570`).
    public static let thinkingTruncatedLines = 3
}

/// `context_bar.rs::fmt_tokens` — always four characters or fewer.
public func pagerFormatTokens(_ value: Int) -> String {
    let tokens = max(0, value)
    switch tokens {
    case ..<1000:
        return String(tokens)
    case ..<10_000:
        return String(format: "%.1fK", Double(tokens) / 1000)
    case ..<1_000_000:
        return "\(tokens / 1000)K"
    case ..<10_000_000:
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    default:
        return "\(tokens / 1_000_000)M"
    }
}

/// `thinking.rs::format_time`.
public func pagerFormatDuration(_ seconds: Double) -> String {
    guard seconds >= 60 else { return String(format: "%.1fs", max(0, seconds)) }
    let minutes = Int(seconds) / 60
    let remainder = seconds - Double(minutes * 60)
    return "\(minutes)m\(Int(remainder.rounded()))s"
}

/// The context indicator's color ramp (`context_bar.rs:86-113`), linearly
/// interpolated between breakpoints.
public func pagerContextColor(fraction: Double, theme: PagerRenderTheme) -> TerminalColor {
    let breakpoints: [(Double, TerminalColor)] = [
        (0.00, theme.textPrimary),
        (0.50, theme.accentUser),
        (0.65, theme.accentUser),
        (0.75, theme.warning),
        (0.85, theme.warning),
        (0.95, theme.accentError)
    ]
    let clamped = min(max(fraction, 0), 1)
    var lower = breakpoints[0]
    for breakpoint in breakpoints {
        if breakpoint.0 <= clamped { lower = breakpoint } else {
            let span = breakpoint.0 - lower.0
            guard span > 0 else { return lower.1 }
            return blendPagerColors(lower.1, breakpoint.1, (clamped - lower.0) / span)
        }
    }
    return lower.1
}

/// Linear RGB interpolation. Non-RGB colors have no channels to mix, so the
/// endpoint nearer the requested position wins.
public func blendPagerColors(
    _ from: TerminalColor,
    _ to: TerminalColor,
    _ amount: Double
) -> TerminalColor {
    let ratio = min(max(amount, 0), 1)
    guard case .rgb(let r0, let g0, let b0) = from, case .rgb(let r1, let g1, let b1) = to else {
        return ratio < 0.5 ? from : to
    }
    func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
        UInt8(min(255, max(0, (Double(a) + (Double(b) - Double(a)) * ratio).rounded())))
    }
    return .rgb(mix(r0, r1), mix(g0, g1), mix(b0, b1))
}
