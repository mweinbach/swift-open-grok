// DiagnosticsColor.swift
//
// Color level and theme catalog facts for the doctor engine.
//
// Ports, at reference 650c1db7, from `xai-grok-pager-render/src/theme/`:
//   * `ColorLevel` names (color_support.rs:19-55). The port's full color
//     stack already lives in `OpenGrokPagerRender` (`PagerColorLevel`,
//     `Sources/OpenGrokPagerRender/PagerThemeDetection.swift:25-97`); this
//     target re-declares the tiny enum instead of importing that module so
//     the diagnostics library carries no pager dependency (the slice's
//     disjointness guarantee). Cost: two declarations of the same 4-case
//     enum; the wiring slice maps between them at the boundary.
//   * `StandaloneColorEvidence` + `standalone_from_env`
//     (color_support.rs:124-201) — the doctor-specific detector that never
//     consults stdout (`grok doctor --json` is commonly piped) and reports
//     honest Unavailable when fully headless.
//   * `ThemeKind::ALL`, `display_name`, `requires_truecolor`
//     (theme/mod.rs:30-100) — only what the facts/formatters read.

import Foundation

/// `ColorLevel` (color_support.rs:19-55), ordered weakest to strongest.
public enum ColorLevel: Int, Sendable, Equatable, Hashable, Comparable {
    case none = 0
    case basic = 1
    case ansi256 = 2
    case trueColor = 3

    public static func < (lhs: ColorLevel, rhs: ColorLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// `as_str` (color_support.rs:44-55).
    public var canonicalName: String {
        switch self {
        case .none: return "none"
        case .basic: return "basic"
        case .ansi256: return "256"
        case .trueColor: return "truecolor"
        }
    }

    public var hasTruecolor: Bool { self == .trueColor }
}

/// `StandaloneColorEvidence` (color_support.rs:130-134).
public enum StandaloneColorEvidence: Sendable, Equatable {
    case available(ColorLevel)
    case unavailable
}

/// `terminal_supports_truecolor_brand` (color_support.rs:260-280).
func terminalSupportsTruecolorBrand(_ terminal: TerminalName) -> Bool {
    switch terminal {
    case .iterm2, .ghostty, .kitty, .wezTerm, .alacritty, .rio, .warpTerminal,
         .vsCode, .windowsTerminal, .foot:
        return true
    default:
        return false
    }
}

/// `standalone_from_env` (color_support.rs:170-201). All evidence injected;
/// `standaloneColorEvidence()` below supplies the live values.
public func standaloneColorEvidence(
    environment: [String: String],
    stderrIsTerminal: Bool,
    controllingTerminal: Bool,
    terminal: TerminalName
) -> StandaloneColorEvidence {
    if environment["NO_COLOR"] != nil { return .available(.none) }
    if !stderrIsTerminal && !controllingTerminal { return .unavailable }
    let colorterm = environment["COLORTERM"]?.lowercased()
    if colorterm == "truecolor" || colorterm == "24bit" || terminalSupportsTruecolorBrand(terminal) {
        return .available(.trueColor)
    }
    let term = environment["TERM"]?.lowercased() ?? ""
    if term.contains("256color") { return .available(.ansi256) }
    if term.isEmpty || term == "dumb" { return .unavailable }
    return .available(.basic)
}

/// `standalone` (color_support.rs:136-145): live stderr-TTY plus
/// controlling-terminal evidence. Never consults stdout.
public func standaloneColorEvidence(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    terminal: TerminalName
) -> StandaloneColorEvidence {
    #if os(Windows)
    let stderrIsTerminal = _isatty(STDERR_FILENO) == 1
    #else
    let stderrIsTerminal = isatty(STDERR_FILENO) == 1
    #endif
    return standaloneColorEvidence(
        environment: environment,
        stderrIsTerminal: stderrIsTerminal,
        controllingTerminal: controllingTerminalAvailable(),
        terminal: terminal
    )
}

/// `controlling_terminal_available` (color_support.rs:147-168).
private func controllingTerminalAvailable() -> Bool {
    #if os(Windows)
    return false
    #else
    let fd = open("/dev/tty", O_RDWR)
    if fd >= 0 {
        close(fd)
        return true
    }
    return false
    #endif
}

/// `ThemeKind` (theme/mod.rs:30-100), catalog facts only. The `Auto`
/// meta-variant is excluded here exactly as it is excluded from `ALL`.
public enum ThemeKind: Sendable, Equatable, Hashable, CaseIterable {
    case grokNight
    case grokDay
    case tokyoNight
    case rosePineMoon
    case oscuraMidnight

    /// `ThemeKind::ALL` (theme/mod.rs:48-54) — order is part of the output.
    public static let all: [ThemeKind] = [.grokNight, .grokDay, .tokyoNight, .rosePineMoon, .oscuraMidnight]

    /// `display_name` (theme/mod.rs:74-83).
    public var displayName: String {
        switch self {
        case .grokNight: return "groknight"
        case .grokDay: return "grokday"
        case .tokyoNight: return "tokyonight"
        case .rosePineMoon: return "rosepine-moon"
        case .oscuraMidnight: return "oscura-midnight"
        }
    }

    /// `requires_truecolor` (theme/mod.rs:90-100).
    public var requiresTruecolor: Bool {
        switch self {
        case .grokNight, .grokDay: return false
        case .tokyoNight, .rosePineMoon, .oscuraMidnight: return true
        }
    }
}
