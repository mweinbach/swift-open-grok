// DiagnosticsTerminal.swift
//
// Environment-only terminal facts for the standalone doctor.
//
// Ports, at reference 650c1db7, from `xai-grok-pager-render/src/terminal/`:
//   * `TerminalName` (mod.rs:52-157) with the Display strings and capability
//     predicates the diagnostics engine consumes.
//   * `MultiplexerKind` (mod.rs:166-201), `ByobuBackend` (mod.rs:204-215),
//     `TmuxClientMeta` (mod.rs:222-228).
//   * `TerminalContext` (mod.rs:233-279) restricted to env-derived fields.
//     `embedded_editor` and `env_term_version` are NOT ported here: no
//     diagnostics path reads them (they feed pager repaint policy and
//     version telemetry, both out of scope for this slice).
//   * The pure `detect_*_from_env` helpers (mod.rs:701-998) and
//     `standalone_terminal_context` (mod.rs:639-650) — env only, no live
//     tmux subprocesses, so an unhealthy tmux server cannot block doctor.
//   * `keyboard.rs` (ModifierFate/ModifierDelivery/KeyboardCapabilities and
//     the macOS classification table, keyboard.rs:14-142).

import Foundation

// MARK: - TerminalName

/// `TerminalName` (terminal/mod.rs:52-112). `displayName` carries the strum
/// `to_string` overrides byte-for-byte (they appear in doctor output).
public enum TerminalName: Sendable, Equatable, Hashable, CaseIterable {
    case appleTerminal
    case ghostty
    case iterm2
    case warpTerminal
    case vsCode
    case cursor
    case windsurf
    case zed
    case wezTerm
    case kitty
    case alacritty
    case rio
    case foot
    case jetBrains
    case grokDesktop
    case vte
    case terminator
    case windowsTerminal
    case otty
    case unknown

    /// strum Display strings (terminal/mod.rs:52-112).
    public var displayName: String {
        switch self {
        case .appleTerminal: return "Apple Terminal"
        case .ghostty: return "Ghostty"
        case .iterm2: return "iTerm2"
        case .warpTerminal: return "Warp"
        case .vsCode: return "VS Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .wezTerm: return "WezTerm"
        case .kitty: return "Kitty"
        case .alacritty: return "Alacritty"
        case .rio: return "Rio"
        case .foot: return "foot"
        case .jetBrains: return "JetBrains"
        case .grokDesktop: return "Grok Desktop"
        case .vte: return "VTE"
        case .terminator: return "Terminator"
        case .windowsTerminal: return "Windows Terminal"
        case .otty: return "Otty"
        case .unknown: return "Unknown"
        }
    }

    /// `is_vte_based` (terminal/mod.rs:115-117).
    public var isVTEBased: Bool { self == .vte || self == .terminator }

    /// `is_vscode_family` (terminal/mod.rs:120-125).
    public var isVSCodeFamily: Bool {
        switch self {
        case .vsCode, .cursor, .windsurf, .zed: return true
        default: return false
        }
    }

    /// `is_capability_unclassified` (terminal/mod.rs:130-132).
    public var isCapabilityUnclassified: Bool { self == .unknown || self == .otty }

    /// `supports_osc52_clipboard` (terminal/mod.rs:135-151) — fail closed.
    public var supportsOSC52Clipboard: Bool {
        switch self {
        case .ghostty, .kitty, .wezTerm, .alacritty, .foot, .rio, .windowsTerminal,
             .iterm2, .vsCode, .cursor, .windsurf, .zed:
            return true
        default:
            return false
        }
    }
}

extension TerminalName: CustomStringConvertible {
    public var description: String { displayName }
}

// MARK: - Multiplexer / Byobu

/// `MultiplexerKind` (terminal/mod.rs:166-192).
public enum MultiplexerKind: Sendable, Equatable, Hashable {
    case tmux
    case screen
    case zellij
    case cmux
    case herdr
    case undetected

    /// strum Display strings (terminal/mod.rs:166-192).
    public var displayName: String {
        switch self {
        case .tmux: return "tmux"
        case .screen: return "GNU screen"
        case .zellij: return "Zellij"
        case .cmux: return "cmux"
        case .herdr: return "herdr"
        case .undetected: return "None detected"
        }
    }
}

extension MultiplexerKind: CustomStringConvertible {
    public var description: String { displayName }
}

/// `ByobuBackend` (terminal/mod.rs:204-215).
public enum ByobuBackend: Sendable, Equatable, Hashable {
    case unknown
    case tmux
    case screen

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .tmux: return "tmux"
        case .screen: return "GNU screen"
        }
    }
}

extension ByobuBackend: CustomStringConvertible {
    public var description: String { displayName }
}

/// `TmuxClientMeta` (terminal/mod.rs:222-228).
public struct TmuxClientMeta: Sendable, Equatable {
    public var tmuxEnv: String?
    public var tmuxPane: String?

    public init(tmuxEnv: String? = nil, tmuxPane: String? = nil) {
        self.tmuxEnv = tmuxEnv
        self.tmuxPane = tmuxPane
    }
}

// MARK: - TerminalContext

/// `TerminalContext` (terminal/mod.rs:233-279), env-derived fields only.
public struct TerminalContext: Sendable, Equatable {
    public var brand: TerminalName
    public var envBrand: TerminalName
    public var multiplexer: MultiplexerKind
    public var byobu: ByobuBackend?
    public var tmuxMeta: TmuxClientMeta
    public var isSSH: Bool
    public var isOfficialVSCodeRemote: Bool
    public var termVar: String?
    public var tmuxVersion: String?
    public var vteVersion: String?
    public var tmuxExtendedKeys: String?
    public var termProgramVersion: String?

    public init(
        brand: TerminalName = .unknown,
        envBrand: TerminalName = .unknown,
        multiplexer: MultiplexerKind = .undetected,
        byobu: ByobuBackend? = nil,
        tmuxMeta: TmuxClientMeta = TmuxClientMeta(),
        isSSH: Bool = false,
        isOfficialVSCodeRemote: Bool = false,
        termVar: String? = nil,
        tmuxVersion: String? = nil,
        vteVersion: String? = nil,
        tmuxExtendedKeys: String? = nil,
        termProgramVersion: String? = nil
    ) {
        self.brand = brand
        self.envBrand = envBrand
        self.multiplexer = multiplexer
        self.byobu = byobu
        self.tmuxMeta = tmuxMeta
        self.isSSH = isSSH
        self.isOfficialVSCodeRemote = isOfficialVSCodeRemote
        self.termVar = termVar
        self.tmuxVersion = tmuxVersion
        self.vteVersion = vteVersion
        self.tmuxExtendedKeys = tmuxExtendedKeys
        self.termProgramVersion = termProgramVersion
    }

    /// `is_tmux_backed` (terminal/mod.rs:284-286).
    public var isTmuxBacked: Bool { multiplexer == .tmux }

    /// `is_vte_based` on the context (terminal/mod.rs:160-163).
    public var isVTEBased: Bool { brand.isVTEBased || vteVersion != nil }

    /// `tmux_config_path` (terminal/mod.rs:316-322).
    public var tmuxConfigPath: String {
        byobu == .tmux ? "~/.byobu/.tmux.conf" : "~/.tmux.conf"
    }

    /// `is_tmux_version_or_later` (terminal/mod.rs:528-538). Unknown = old.
    public func isTmuxVersionOrLater(_ major: UInt32, _ minor: UInt32) -> Bool {
        guard let version = tmuxVersion, let (maj, min) = parseTmuxMajorMinor(version) else {
            return false
        }
        return (maj, min) >= (major, minor)
    }

    /// `kitty_skip_reason` (terminal/mod.rs:341-386).
    public var kittySkipReason: String? {
        let isTmux33Later = isTmuxVersionOrLater(3, 3)
        if brand.isVSCodeFamily { return "vscode" }
        if brand == .appleTerminal { return "apple_terminal" }
        if isVTEBased { return "vte" }
        if brand == .windowsTerminal { return "windows_terminal" }
        if brand == .jetBrains { return "jetbrains" }
        if multiplexer == .screen { return "screen" }
        if multiplexer == .tmux && !isTmux33Later { return "tmux_old" }
        if multiplexer == .tmux && isTmux33Later && tmuxExtendedKeys == "off" {
            return "tmux_extended_keys_off"
        }
        if brand.isCapabilityUnclassified && multiplexer == .undetected {
            return "unknown_no_multiplexer"
        }
        return nil
    }

    /// `shift_enter_unavailable` (terminal/mod.rs:437-477).
    public var shiftEnterUnavailable: Bool {
        if isVTEBased {
            guard let version = vteVersion, let value = UInt32(version) else {
                // Brand=VTE with no parseable version — conservative: assume old.
                return true
            }
            return value < 8200
        }
        if brand.isVSCodeFamily { return true }
        // Consult `env_brand` (not `brand`) per the upstream Windows note.
        if envBrand.isCapabilityUnclassified && multiplexer == .undetected { return true }
        return false
    }
}

// MARK: - Env detection (pure helpers)

private func envGet(_ env: [String: String], _ key: String) -> String? {
    guard let value = env[key], !value.isEmpty else { return nil }
    return value
}

/// `is_official_vscode_remote_askpass` (terminal/mod.rs:681-689).
func isOfficialVSCodeRemoteAskpass(_ path: String) -> Bool {
    path.split(separator: "/").contains { component in
        component == ".vscode-server" || component == ".vscode-server-insiders"
    }
}

/// `detect_terminal_brand_from_env` (terminal/mod.rs:701-821).
public func detectTerminalBrandFromEnv(_ env: [String: String]) -> TerminalName {
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
        || envGet(env, "LC_TERMINAL")?.lowercased() == "iterm2" {
        return .iterm2
    }
    if envGet(env, "TERM_SESSION_ID") != nil { return .appleTerminal }
    if envGet(env, "KITTY_WINDOW_ID") != nil { return .kitty }
    if let term = envGet(env, "TERM"), term.contains("kitty") { return .kitty }
    if envGet(env, "ALACRITTY_SOCKET") != nil { return .alacritty }
    if let term = envGet(env, "TERM"), term == "alacritty" { return .alacritty }
    if let term = envGet(env, "TERM"), term == "rio" { return .rio }
    if let term = envGet(env, "TERM"), term == "foot" || term == "foot-extra" || term == "foot-direct" {
        return .foot
    }
    if envGet(env, "TERMINATOR_UUID") != nil { return .terminator }
    if envGet(env, "VTE_VERSION") != nil { return .vte }
    if envGet(env, "WT_SESSION") != nil { return .windowsTerminal }
    return .unknown
}

/// `terminal_name_from_term_program` (terminal/mod.rs:1001-1026).
func terminalNameFromTermProgram(_ value: String) -> TerminalName? {
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

/// `refine_unknown_brand_for_host` (terminal/mod.rs:831-837).
func refineUnknownBrandForHost(_ brand: TerminalName, host: HostOs) -> TerminalName {
    (brand == .unknown && host == .windows) ? .windowsTerminal : brand
}

/// `detect_byobu_from_env` (terminal/mod.rs:852-873).
public func detectByobuFromEnv(_ env: [String: String]) -> ByobuBackend? {
    let hasBackend = envGet(env, "BYOBU_BACKEND") != nil
    let hasConfig = envGet(env, "BYOBU_CONFIG_DIR") != nil
    let hasDistro = envGet(env, "BYOBU_DISTRO") != nil
    if !hasBackend && !hasConfig && !hasDistro { return nil }
    if let backend = envGet(env, "BYOBU_BACKEND") {
        switch backend.lowercased() {
        case "tmux": return .tmux
        case "screen": return .screen
        default: return inferByobuBackendFromMuxMarkers(env)
        }
    }
    return inferByobuBackendFromMuxMarkers(env)
}

/// `infer_byobu_backend_from_mux_markers` (terminal/mod.rs:877-887).
private func inferByobuBackendFromMuxMarkers(_ env: [String: String]) -> ByobuBackend? {
    let hasTmux = envGet(env, "TMUX") != nil
    let hasSty = envGet(env, "STY") != nil
    if hasTmux { return .tmux }
    if hasSty { return .screen }
    return nil
}

/// `detect_multiplexer_from_env` (terminal/mod.rs:903-944).
public func detectMultiplexerFromEnv(_ env: [String: String]) -> MultiplexerKind {
    if let backend = detectByobuFromEnv(env) {
        switch backend {
        case .tmux: return .tmux
        case .screen: return .screen
        case .unknown: break
        }
    }
    if envGet(env, "TMUX") != nil { return .tmux }
    if envGet(env, "ZELLIJ") != nil || envGet(env, "ZELLIJ_SESSION_NAME") != nil { return .zellij }
    if envGet(env, "STY") != nil { return .screen }
    if envGet(env, "HERDR_ENV") != nil { return .herdr }
    if envGet(env, "CMUX_SOCKET_PATH") != nil
        || envGet(env, "CMUX_PANEL_ID") != nil
        || envGet(env, "CMUX_BUNDLE_ID") != nil {
        return .cmux
    }
    return .undetected
}

/// `detect_tmux_meta_from_env` (terminal/mod.rs:947-952).
public func detectTmuxMetaFromEnv(_ env: [String: String]) -> TmuxClientMeta {
    TmuxClientMeta(tmuxEnv: envGet(env, "TMUX"), tmuxPane: envGet(env, "TMUX_PANE"))
}

/// `build_terminal_context_from_env` (terminal/mod.rs:958-998).
public func buildTerminalContextFromEnv(_ env: [String: String]) -> TerminalContext {
    let brand = detectTerminalBrandFromEnv(env)
    let multiplexer = detectMultiplexerFromEnv(env)
    let byobu = detectByobuFromEnv(env)
    let tmuxMeta = multiplexer == .tmux ? detectTmuxMetaFromEnv(env) : TmuxClientMeta()
    let isSSH = envGet(env, "SSH_CONNECTION") != nil
        || envGet(env, "SSH_TTY") != nil
        || envGet(env, "SSH_CLIENT") != nil
    let isOfficialVSCodeRemote = isSSH
        && envGet(env, "VSCODE_GIT_ASKPASS_MAIN").map(isOfficialVSCodeRemoteAskpass) == true
    return TerminalContext(
        brand: brand,
        envBrand: brand,
        multiplexer: multiplexer,
        byobu: byobu,
        tmuxMeta: tmuxMeta,
        isSSH: isSSH,
        isOfficialVSCodeRemote: isOfficialVSCodeRemote,
        termVar: envGet(env, "TERM"),
        tmuxVersion: nil,
        vteVersion: envGet(env, "VTE_VERSION"),
        tmuxExtendedKeys: nil,
        termProgramVersion: envGet(env, "TERM_PROGRAM_VERSION") ?? envGet(env, "LC_TERMINAL_VERSION")
    )
}

/// `standalone_terminal_context` (terminal/mod.rs:639-650): env only, no
/// live tmux subprocess, so an unhealthy tmux server cannot block doctor.
public func standaloneTerminalContext(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    host: HostOs = HostOs.current()
) -> TerminalContext {
    var ctx = buildTerminalContextFromEnv(environment)
    ctx.brand = refineUnknownBrandForHost(ctx.brand, host: host)
    return ctx
}

/// `parse_tmux_major_minor` (terminal/mod.rs:1077-1087) — `"tmux 3.3a"` etc.
func parseTmuxMajorMinor(_ version: String) -> (UInt32, UInt32)? {
    guard version.hasPrefix("tmux ") else { return nil }
    let rest = version.dropFirst("tmux ".count)
    let parts = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let major = UInt32(parts[0]) else { return nil }
    let minorDigits = parts[1].prefix { $0.isASCII && $0.isNumber }
    guard let minor = UInt32(minorDigits) else { return nil }
    return (major, minor)
}

// MARK: - Keyboard capabilities (keyboard.rs)

/// `ModifierFate` (keyboard.rs:14-38).
public enum ModifierFate: String, Sendable, Equatable, Hashable {
    case native
    case dropped
    case unrecoverable
    case unknown

    /// `benefits_from_rescue` (keyboard.rs:35-37).
    public var benefitsFromRescue: Bool { self == .dropped }
}

/// `ModifierDelivery` (keyboard.rs:41-64).
public struct ModifierDelivery: Sendable, Equatable {
    public var cmd: ModifierFate
    public var opt: ModifierFate

    public init(cmd: ModifierFate = .unknown, opt: ModifierFate = .unknown) {
        self.cmd = cmd
        self.opt = opt
    }

    public var benefitsFromRescue: Bool { cmd.benefitsFromRescue || opt.benefitsFromRescue }

    /// `label()` (keyboard.rs:61-63).
    public var label: String { "cmd=\(cmd.rawValue), opt=\(opt.rawValue)" }
}

/// `KeyboardCapabilities` (keyboard.rs:68-82).
public struct KeyboardCapabilities: Sendable, Equatable {
    public var modifierDelivery: ModifierDelivery
    public var enterModifier: ModifierFate

    public init(modifierDelivery: ModifierDelivery = ModifierDelivery(), enterModifier: ModifierFate = .unknown) {
        self.modifierDelivery = modifierDelivery
        self.enterModifier = enterModifier
    }

    public var enterNeedsRescue: Bool { enterModifier == .dropped }
}

/// `keyboard_capabilities_for_host` (keyboard.rs:94-99).
public func keyboardCapabilitiesForHost(_ brand: TerminalName, host: HostOs) -> KeyboardCapabilities {
    switch host {
    case .macos: return macosKeyboardCapabilities(brand)
    case .linux, .windows, .other: return KeyboardCapabilities()
    }
}

/// `macos_capabilities` (keyboard.rs:101-142).
private func macosKeyboardCapabilities(_ brand: TerminalName) -> KeyboardCapabilities {
    let cmd: ModifierFate
    let opt: ModifierFate
    let enter: ModifierFate
    switch brand {
    case .ghostty, .kitty, .foot:
        (cmd, opt, enter) = (.native, .native, .native)
    case .iterm2, .vsCode, .cursor, .windsurf, .zed:
        (cmd, opt, enter) = (.native, .native, .native)
    case .wezTerm:
        (cmd, opt, enter) = (.dropped, .native, .native)
    case .alacritty, .rio:
        (cmd, opt, enter) = (.native, .dropped, .native)
    case .warpTerminal:
        (cmd, opt, enter) = (.dropped, .dropped, .native)
    case .appleTerminal:
        (cmd, opt, enter) = (.unrecoverable, .dropped, .dropped)
    case .grokDesktop, .vte, .terminator, .jetBrains, .windowsTerminal, .otty, .unknown:
        (cmd, opt, enter) = (.unknown, .unknown, .unknown)
    }
    return KeyboardCapabilities(
        modifierDelivery: ModifierDelivery(cmd: cmd, opt: opt),
        enterModifier: enter
    )
}
