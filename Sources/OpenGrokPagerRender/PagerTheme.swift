import Foundation
import OpenGrokTerminalCore

/// The palette roles the Rust pager's `Theme` struct exposes, ported so frame
/// code can name colors the same way the reference does.
///
/// The reference's `Theme` carries 60 fields; the markdown heading and code
/// slots are owned by the markdown renderer and stay out of this struct. Every
/// other role the frame chrome paints with is here, under the reference's own
/// name, so a theme table ports across as a field-for-field transcription.
public struct PagerRenderTheme: Sendable, Equatable, Hashable {
    public var bgBase: TerminalColor
    public var bgLight: TerminalColor
    public var bgDark: TerminalColor
    public var bgHighlight: TerminalColor
    public var bgHover: TerminalColor
    public var bgVisual: TerminalColor
    public var bgTerminal: TerminalColor

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
    public var accentVerify: TerminalColor
    public var accentFeedback: TerminalColor
    public var accentRemember: TerminalColor
    /// The role the reference paints the active model's chrome with
    /// (`accent_model`).
    public var accentModel: TerminalColor
    public var fuzzyAccent: TerminalColor

    public var command: TerminalColor
    public var path: TerminalColor
    public var running: TerminalColor
    public var warning: TerminalColor

    public var promptBorder: TerminalColor
    public var promptBorderActive: TerminalColor
    public var selectionBorder: TerminalColor
    public var hoverBorder: TerminalColor
    public var scrollbarBackground: TerminalColor
    public var scrollbarForeground: TerminalColor
    public var linkForeground: TerminalColor

    public var diffDeleteBackground: TerminalColor
    public var diffDeleteForeground: TerminalColor
    public var diffInsertBackground: TerminalColor
    public var diffInsertForeground: TerminalColor
    public var diffEqualForeground: TerminalColor
    public var diffGutterForeground: TerminalColor

    public var pasteBackground: TerminalColor
    public var pasteForeground: TerminalColor
    public var pasteDim: TerminalColor

    public init(
        bgBase: TerminalColor = .rgb(20, 20, 20),
        bgLight: TerminalColor = .rgb(36, 36, 36),
        bgDark: TerminalColor = .rgb(28, 28, 28),
        bgHighlight: TerminalColor = .rgb(36, 36, 36),
        bgHover: TerminalColor = .rgb(44, 44, 44),
        bgVisual: TerminalColor = .rgb(54, 54, 54),
        bgTerminal: TerminalColor = .rgb(10, 10, 10),
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
        accentVerify: TerminalColor = .rgb(187, 154, 247),
        accentFeedback: TerminalColor = .rgb(115, 218, 202),
        accentRemember: TerminalColor = .rgb(139, 195, 74),
        accentModel: TerminalColor = .rgb(26, 188, 156),
        fuzzyAccent: TerminalColor = .rgb(122, 162, 247),
        command: TerminalColor = .rgb(224, 175, 104),
        path: TerminalColor = .rgb(255, 158, 100),
        running: TerminalColor = .rgb(125, 207, 255),
        warning: TerminalColor = .rgb(224, 175, 104),
        promptBorder: TerminalColor = .rgb(50, 50, 55),
        promptBorderActive: TerminalColor = .rgb(80, 80, 88),
        selectionBorder: TerminalColor = .rgb(60, 60, 65),
        hoverBorder: TerminalColor = .rgb(30, 30, 34),
        scrollbarBackground: TerminalColor = .rgb(17, 17, 17),
        scrollbarForeground: TerminalColor = .rgb(36, 36, 36),
        linkForeground: TerminalColor = .rgb(122, 166, 218),
        diffDeleteBackground: TerminalColor = .rgb(66, 14, 20),
        diffDeleteForeground: TerminalColor = .rgb(247, 118, 142),
        diffInsertBackground: TerminalColor = .rgb(6, 56, 6),
        diffInsertForeground: TerminalColor = .rgb(158, 206, 106),
        diffEqualForeground: TerminalColor = .rgb(108, 108, 108),
        diffGutterForeground: TerminalColor = .rgb(108, 108, 108),
        pasteBackground: TerminalColor = .rgb(17, 17, 17),
        pasteForeground: TerminalColor = .rgb(200, 200, 200),
        pasteDim: TerminalColor = .rgb(65, 65, 65)
    ) {
        self.bgBase = bgBase
        self.bgLight = bgLight
        self.bgDark = bgDark
        self.bgHighlight = bgHighlight
        self.bgHover = bgHover
        self.bgVisual = bgVisual
        self.bgTerminal = bgTerminal
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
        self.accentVerify = accentVerify
        self.accentFeedback = accentFeedback
        self.accentRemember = accentRemember
        self.accentModel = accentModel
        self.fuzzyAccent = fuzzyAccent
        self.command = command
        self.path = path
        self.running = running
        self.warning = warning
        self.promptBorder = promptBorder
        self.promptBorderActive = promptBorderActive
        self.selectionBorder = selectionBorder
        self.hoverBorder = hoverBorder
        self.scrollbarBackground = scrollbarBackground
        self.scrollbarForeground = scrollbarForeground
        self.linkForeground = linkForeground
        self.diffDeleteBackground = diffDeleteBackground
        self.diffDeleteForeground = diffDeleteForeground
        self.diffInsertBackground = diffInsertBackground
        self.diffInsertForeground = diffInsertForeground
        self.diffEqualForeground = diffEqualForeground
        self.diffGutterForeground = diffGutterForeground
        self.pasteBackground = pasteBackground
        self.pasteForeground = pasteForeground
        self.pasteDim = pasteDim
    }

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

    /// `AUTO_COMPACT_MAX_ROWS` (`views/agent.rs:87`): at or below this height
    /// the render-value compact flag is forced on. Deliberately above
    /// `shortTerminalRows`, which stays the hard-degradation gate.
    public static let autoCompactMaxRows = 20

    /// `MAX_DROPDOWN_ROWS` (`views/slash_dropdown.rs:24`).
    public static let maxDropdownRows = 6

    /// Execute-tool output preview budget (`appearance/config.rs:692-693`).
    public static let executePreviewFirstLines = 2
    public static let executePreviewLastLines = 3

    /// Thinking truncation budget (`appearance/config.rs:570`).
    public static let thinkingTruncatedLines = 3

    /// Columns reserved on the right of user/assistant message blocks while
    /// `[ui] show_timestamps` is on, so wrapped text never collides with the
    /// overlaid stamp — `EntryRenderer::timestamp_reserved`
    /// (`entry_renderer.rs:384-393`: `10 // max short format: "  12:30 PM"`).
    /// Reserved whenever the setting is on for a stamped role, even when the
    /// block carries no instant — upstream's reserve ignores `created_at`
    /// (`entry_renderer.rs:1548-1550`), so toggling never re-wraps text just
    /// because one block lacks a stamp.
    public static let timestampReservedColumns = 10
}

/// Render-value derivation for compact mode: the user setting, force-enabled
/// while the terminal is `PagerLayoutMetrics.autoCompactMaxRows` or shorter
/// (`effective_compact`, `views/agent.rs:96-98`).
///
/// Derived only — never persisted and never written back to the user setting,
/// so growing the window restores the user's choice. `terminalRows == 0` means
/// "not yet measured" and never forces compact.
public func pagerEffectiveCompact(userCompact: Bool, terminalRows: Int) -> Bool {
    userCompact || (terminalRows > 0 && terminalRows <= PagerLayoutMetrics.autoCompactMaxRows)
}

/// The short timestamp format, `ts.format("  %-I:%M %p")`
/// (`entry_renderer.rs:952`): two leading spaces, 12-hour clock without a
/// leading zero, minutes, `AM`/`PM` — e.g. `"  12:30 PM"`, `"  1:05 AM"`.
/// Local time, as upstream's `DateTime<Local>` is; the POSIX locale pins the
/// `AM`/`PM` symbols chrono's `%p` always emits.
///
/// The hover-expanded long format (`"  %H:%M:%S | %b %d"`,
/// `entry_renderer.rs:950`) is NOT ported: it needs the mouse position at
/// paint time, a seam `PagerRenderState` does not carry. Upstream itself
/// always paints the short form for pushed sticky headers for the same
/// reason (`scrollback_pane.rs:818-819`).
public func pagerFormatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "  h:mm a"
    return formatter.string(from: date)
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

/// `context_bar.rs::fmt_pct5` — always exactly five columns, so the context
/// readout does not shift the status bar as the percentage grows.
public func pagerFormatPercent(_ percent: Double) -> String {
    guard percent < 100 else { return "MAX %" }
    let clamped = max(0, percent)
    return clamped < 10
        ? String(format: "%.2f%%", clamped)
        : String(format: "%.1f%%", clamped)
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
