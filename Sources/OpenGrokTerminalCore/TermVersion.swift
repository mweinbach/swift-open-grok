// TermVersion.swift
//
// Terminal version record from env plus optional DA2 packed / XTVERSION
// payloads. Ports pin `term_version.rs` and the consumer gates it feeds:
// Alacritty DA2 packed compare (`kitty_keyboard.rs:37-72`) and WezTerm
// XTVERSION prefix (`diagnostics/mod.rs:364-373`).
//
// Reuses `Da2Version` / `unpackDa2Version` from `Da2.swift`. No Xtversion
// type exists here, so the XTVERSION payload stays `String?`. Missing or
// rejected probes stay unknown (`nil` / empty + `.none`) — never zero.

import Foundation

// MARK: - Source (term_version.rs:18-32)

/// Which source produced a `TermVersion`. Labels are stable telemetry values.
public enum TermVersionSource: String, Sendable, Equatable, Hashable, CustomStringConvertible {
    case none
    case da2
    case termProgram = "term_program"
    case wezTerm = "wezterm"
    case vte

    public var description: String { rawValue }
}

// MARK: - Record (term_version.rs:34-50)

/// A terminal version together with the source that reported it, plus the
/// optional probe payloads consumers compare against.
public struct TermVersion: Sendable, Equatable {
    /// Raw, exactly as the winning source reported it (trimmed). Empty when
    /// no source produced a version (`TermVersionSource.none`).
    public var version: String
    public var source: TermVersionSource
    /// Accepted DA2 packed `Pv` (`major * 10000 + minor * 100 + patch`).
    /// `nil` is unknown — a rejected `0` is not stored as zero.
    public var da2Packed: UInt32?
    /// Sanitized XTVERSION payload. `nil` is unknown, not `""`.
    public var xtversion: String?

    public init(
        version: String,
        source: TermVersionSource,
        da2Packed: UInt32? = nil,
        xtversion: String? = nil
    ) {
        self.version = version
        self.source = source
        self.da2Packed = da2Packed
        self.xtversion = xtversion
    }

    /// Assemble a comparable record. DA2 outranks env (`best_term_version`);
    /// XTVERSION has no version arm and rides the payload field only.
    public static func assemble(
        env: [String: String] = [:],
        da2Packed: UInt32? = nil,
        xtversion: String? = nil
    ) -> TermVersion {
        let da2 = da2Packed.flatMap(unpackDa2Version)
        let envVersion = detectEnv(in: env)
        let (version, source) = best(da2: da2?.text, envVersion: envVersion)
        return TermVersion(
            version: version,
            source: source,
            da2Packed: da2?.packed,
            xtversion: sanitizeXtversion(xtversion)
        )
    }

    /// `detect_env_term_version` (term_version.rs:95-133). Brand is the
    /// pre-refinement env brand; Windows `Unknown → WindowsTerminal` is not
    /// applied here and so cannot license a version attribution.
    public static func detectEnv(in env: [String: String]) -> TermVersion? {
        let envBrand = detectEnvBrand(env)
        if let version = envTrimmed(env, "TERM_PROGRAM_VERSION"),
           let named = envTrimmed(env, "TERM_PROGRAM").flatMap(terminalNameFromTermProgram),
           corroborates(named: named, envBrand: envBrand) {
            return TermVersion(version: version, source: .termProgram)
        }
        if let version = envTrimmed(env, "LC_TERMINAL_VERSION"),
           let lc = envTrimmed(env, "LC_TERMINAL"),
           lc.compare("iterm2", options: .caseInsensitive) == .orderedSame,
           envBrand == .iterm2 {
            return TermVersion(version: version, source: .termProgram)
        }
        if let version = envTrimmed(env, "WEZTERM_VERSION"), envBrand == .wezTerm {
            return TermVersion(version: version, source: .wezTerm)
        }
        // Brand-only: routing the gate through a present `vte_version` would
        // make it vacuous (term_version.rs:123-126).
        if let version = envTrimmed(env, "VTE_VERSION"), envBrand.isVteBased {
            return TermVersion(version: version, source: .vte)
        }
        return nil
    }

    /// `best_term_version` (term_version.rs:73-80). A live DA2 self-report
    /// outranks inherited env. Absent both → empty + `.none`, not `"0"`.
    public static func best(
        da2: String?,
        envVersion: TermVersion?
    ) -> (String, TermVersionSource) {
        if let da2 {
            return (da2, .da2)
        }
        if let envVersion {
            return (envVersion.version, envVersion.source)
        }
        return ("", .none)
    }

    /// Alacritty packed gate (`kitty_keyboard.rs:66-72`). Only a positively
    /// identified packed `<= 2401` downgrades. Unknown does not.
    public var alacrittyMisEncodesEventTypes: Bool {
        guard let da2Packed else { return false }
        return da2Packed <= ALACRITTY_BROKEN_EVENT_TYPES_MAX_PACKED
    }

    /// WezTerm XTVERSION prefix (`diagnostics/mod.rs:373`):
    /// `trim_start().starts_with("WezTerm")`. Missing payload is unknown.
    public var xtversionIdentifiesWezTerm: Bool {
        guard let xtversion else { return false }
        return xtversion.drop(while: { $0.isWhitespace }).hasPrefix("WezTerm")
    }
}

// MARK: - XTVERSION sanitize (xtversion.rs:128-135)

/// Strip controls and trim; empty becomes `nil` (unknown, not `""`).
private func sanitizeXtversion(_ payload: String?) -> String? {
    guard let payload else { return nil }
    let cleaned = String(payload.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
}

// MARK: - Env brand corroboration (term_version.rs:52-66, 83-87, 95-133)

private enum TermEnvBrand: Equatable {
    case appleTerminal, ghostty, iterm2, warpTerminal
    case vsCode, cursor, windsurf, zed
    case wezTerm, kitty, alacritty, rio, foot
    case jetBrains, grokDesktop, vte, terminator
    case windowsTerminal, otty, unknown

    var isVteBased: Bool { self == .vte || self == .terminator }
}

/// Identity, widened one-way for VS Code forks (term_version.rs:59-66).
private func corroborates(named: TermEnvBrand, envBrand: TermEnvBrand) -> Bool {
    if named == envBrand { return true }
    return named == .vsCode && (envBrand == .vsCode || envBrand == .cursor || envBrand == .windsurf)
}

private func envGet(_ env: [String: String], _ key: String) -> String? {
    guard let value = env[key], !value.isEmpty else { return nil }
    return value
}

private func envTrimmed(_ env: [String: String], _ key: String) -> String? {
    guard let value = envGet(env, key) else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// `terminal_name_from_term_program` (mod.rs:1001-1026).
private func terminalNameFromTermProgram(_ value: String) -> TermEnvBrand? {
    let normalized = value
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
        .filter { !" -_.".contains($0) }
    switch normalized {
    case "appleterminal": return .appleTerminal
    case "ghostty": return .ghostty
    case "iterm", "iterm2", "itermapp": return .iterm2
    case "warp", "warpterminal": return .warpTerminal
    case "vscode": return .vsCode
    case "wezterm": return .wezTerm
    case "kitty": return .kitty
    case "alacritty": return .alacritty
    case "rio": return .rio
    case "terminator": return .terminator
    case "zed": return .zed
    case "grokdesktop": return .grokDesktop
    case "windowsterminal": return .windowsTerminal
    case "otty": return .otty
    default: return nil
    }
}

/// Compact port of `detect_terminal_brand_from_env` (mod.rs:701-821) so
/// version corroboration uses the same pre-refinement brand the pin does.
private func detectEnvBrand(_ env: [String: String]) -> TermEnvBrand {
    if envGet(env, "CURSOR_TRACE_ID") != nil { return .cursor }
    if let askpass = envGet(env, "VSCODE_GIT_ASKPASS_MAIN") {
        let lower = askpass.lowercased()
        if lower.contains("cursor") { return .cursor }
        if lower.contains("windsurf") { return .windsurf }
        return .vsCode
    }
    if let termProgram = envGet(env, "TERM_PROGRAM"),
       let name = terminalNameFromTermProgram(termProgram) {
        return name
    }
    if let te = envGet(env, "TERMINAL_EMULATOR") {
        let lower = te.lowercased()
        if lower.contains("jetbrains") || lower.contains("jediterm") { return .jetBrains }
    }
    if envGet(env, "WEZTERM_VERSION") != nil { return .wezTerm }
    if envGet(env, "ITERM_SESSION_ID") != nil
        || envGet(env, "ITERM_PROFILE") != nil
        || envGet(env, "LC_TERMINAL")?.compare("iterm2", options: .caseInsensitive) == .orderedSame {
        return .iterm2
    }
    if envGet(env, "TERM_SESSION_ID") != nil { return .appleTerminal }
    if envGet(env, "KITTY_WINDOW_ID") != nil { return .kitty }
    if let term = envGet(env, "TERM"), term.contains("kitty") { return .kitty }
    if envGet(env, "ALACRITTY_SOCKET") != nil { return .alacritty }
    if envGet(env, "TERM") == "alacritty" { return .alacritty }
    if envGet(env, "TERM") == "rio" { return .rio }
    if let term = envGet(env, "TERM"), term == "foot" || term == "foot-extra" || term == "foot-direct" {
        return .foot
    }
    if envGet(env, "TERMINATOR_UUID") != nil { return .terminator }
    if envGet(env, "VTE_VERSION") != nil { return .vte }
    if envGet(env, "WT_SESSION") != nil { return .windowsTerminal }
    return .unknown
}
