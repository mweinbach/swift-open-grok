// DiagnosticsWarnings.swift
//
// Route-aware terminal warnings — data only, no side effects.
//
// Ports the pure warning constructors of
// `xai-grok-pager/src/diagnostics/mod.rs` at reference 650c1db7:
//   * `WarningCategory` / `TerminalWarning` (mod.rs:97-176)
//   * `collect_startup_warnings_from` (mod.rs:238-328)
//   * `wezterm_shape` / `wezterm_kitty_keyboard_warning_from` (mod.rs:363-422)
//   * `ssh_wrap_hint` (mod.rs:477-497)
//   * `tmux_reload_note` (mod.rs:708-710)
//   * `diagnose_clipboard_from_values` (mod.rs:751-797)
//   * `diagnose_wayland_data_control` (+`_from_common`) (mod.rs:809-856)
//   * `color_support_warning` (mod.rs:957-1046)
//
// NOT ported here (deferred with the TUI-probe wave, injectable upstream of
// this engine): notification warnings (mod.rs:574-660), sandbox profile
// conflicts (mod.rs:424-451), `merge_tui_runtime_findings` (mod.rs:685-706),
// voice probing (mod.rs:54-95), and the welcome-banner summarizers.

import Foundation

/// `WarningCategory` (mod.rs:98-142).
public enum WarningCategory: Sendable, Equatable, Hashable {
    case clipboard
    case dcsPassthrough
    case controlMode
    case byobuScreen
    case unsupportedTerminal
    case tmuxExtendedKeysOff
    case notificationProtocolFallback
    case focusTrackingUnavailable
    case wezTermKittyKeyboardOff
    case waylandNoDataControl
    case limitedColorSupport
    case tmuxColorReduced
    case sandboxProfileConflict
    case sshWithoutWrap
}

/// `TerminalWarning` (mod.rs:146-176).
public struct TerminalWarning: Sendable, Equatable {
    public var category: WarningCategory
    public var message: String
    public var fix: String?
    public var configPath: String?
    public var note: String?

    public init(
        category: WarningCategory,
        message: String,
        fix: String? = nil,
        configPath: String? = nil,
        note: String? = nil
    ) {
        self.category = category
        self.message = message
        self.fix = fix
        self.configPath = configPath
        self.note = note
    }
}

/// `tmux_reload_note` (mod.rs:708-710).
func tmuxReloadNote(configPath: String) -> String {
    "Reload tmux with `tmux source-file \(configPath)`, or restart the tmux server."
}

/// `collect_startup_warnings_from` (mod.rs:238-328).
func collectStartupWarnings(
    terminal ctx: TerminalContext,
    tmux: TmuxProbeFacts,
    fullscreenActive: Bool?
) -> [TerminalWarning] {
    var warnings: [TerminalWarning] = []

    // Apple Terminal does not support OSC 52; over SSH clipboard writes can
    // never reach the user's local machine (mod.rs:245-261).
    if ctx.brand == .appleTerminal && ctx.isSSH {
        warnings.append(TerminalWarning(
            category: .unsupportedTerminal,
            message: "Apple Terminal doesn't support OSC 52, so clipboard copy over SSH is unavailable",
            note: "Grok also saves each copy to the backup file shown in the copy message. To copy directly, run `open-grok wrap ssh <host>` on your local computer or use a terminal that supports OSC 52. You can also use `/copy <file>` or `/minimal`."
        ))
    }

    // Byobu-on-screen: best-effort warning, no further tmux checks (mod.rs:263-278).
    if ctx.byobu == .screen {
        warnings.append(TerminalWarning(
            category: .byobuScreen,
            message: "Byobu is using GNU screen, which has limited clipboard and display support",
            note: "Switch Byobu to its tmux backend, then restart or reattach the session. tmux-specific fixes apply only after you switch backends."
        ))
        return warnings
    }

    // tmux control-mode (mod.rs:280-298).
    if ctx.isTmuxBacked, case .available(true) = tmux.controlMode {
        let message: String
        switch fullscreenActive {
        case .some(true): message = "Fullscreen may be unreliable in tmux control mode"
        case .some(false): message = "Grok is using inline mode because tmux control mode limits fullscreen"
        case .none: message = "Display may be limited in tmux control mode"
        }
        warnings.append(TerminalWarning(
            category: .controlMode,
            message: message,
            note: "If display problems continue, connect with a regular tmux client instead of control mode."
        ))
    }

    let configPath = ctx.tmuxConfigPath

    if ctx.isTmuxBacked {
        warnings.append(contentsOf: diagnoseClipboardFromFacts(tmux: tmux, configPath: configPath))
    }

    if ctx.isTmuxBacked, case .available(let value) = tmux.extendedKeys, value == "off" {
        warnings.append(TerminalWarning(
            category: .tmuxExtendedKeysOff,
            message: "`extended-keys` is off in tmux, so some shortcuts may not work",
            fix: "set -g extended-keys on",
            configPath: configPath,
            // Existing tmux sessions cache the option; without an explicit
            // reload the user concludes the fix is broken (mod.rs:320-323).
            note: tmuxReloadNote(configPath: configPath)
        ))
    }

    return warnings
}

/// `diagnose_clipboard_from_facts` (mod.rs:712-734).
private func diagnoseClipboardFromFacts(tmux: TmuxProbeFacts, configPath: String) -> [TerminalWarning] {
    let setClipboard: String?
    if case .available(let value) = tmux.setClipboard { setClipboard = value } else { setClipboard = nil }
    let passthroughExists: Bool
    if case .unsupported = tmux.allowPassthroughSupport { passthroughExists = false } else { passthroughExists = true }
    let allowPassthrough: String?
    if case .available(let value) = tmux.allowPassthrough { allowPassthrough = value } else { allowPassthrough = nil }
    return diagnoseClipboardFromValues(
        setClipboard: setClipboard,
        passthroughExists: passthroughExists,
        allowPassthrough: allowPassthrough,
        configPath: configPath
    )
}

/// `diagnose_clipboard_from_values` (mod.rs:751-797). `nil` means the query
/// could not obtain a value — never treated as proof of misconfiguration.
public func diagnoseClipboardFromValues(
    setClipboard: String?,
    passthroughExists: Bool,
    allowPassthrough: String?,
    configPath: String
) -> [TerminalWarning] {
    var warnings: [TerminalWarning] = []

    if let value = setClipboard, value != "on" && value != "external" {
        warnings.append(TerminalWarning(
            category: .clipboard,
            message: "`set-clipboard` is off in tmux, so OSC 52 clipboard copies are blocked",
            fix: "set -g set-clipboard on",
            configPath: configPath,
            note: tmuxReloadNote(configPath: configPath)
        ))
    }

    if passthroughExists, let value = allowPassthrough, value != "on" && value != "all" {
        warnings.append(TerminalWarning(
            category: .dcsPassthrough,
            message: "`allow-passthrough` is off in tmux, which can block clipboard copies in nested sessions",
            fix: "set -wg allow-passthrough on",
            configPath: configPath,
            note: tmuxReloadNote(configPath: configPath)
        ))
    }

    return warnings
}

/// `WezTermShape` (mod.rs:377-381).
enum WezTermShape: Equatable {
    case environment
    case sshXtversion
}

/// `wezterm_shape` (mod.rs:363-375).
func weztermShape(_ ctx: TerminalContext, xtversionPayload: String?) -> WezTermShape? {
    if ctx.brand == .wezTerm { return .environment }
    let sshShape = ctx.brand == .unknown
        && ctx.multiplexer == .undetected
        && ctx.isSSH
        && (xtversionPayload?.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("WezTerm") ?? false)
    return sshShape ? .sshXtversion : nil
}

/// `wezterm_kitty_keyboard_warning_from` (mod.rs:383-422).
func weztermKittyKeyboardWarning(
    _ ctx: TerminalContext,
    kittyFlagsPushed: Bool,
    xtversionPayload: String?
) -> TerminalWarning? {
    guard let shape = weztermShape(ctx, xtversionPayload: xtversionPayload) else { return nil }
    if kittyFlagsPushed { return nil }
    if shape == .environment && ctx.kittySkipReason != nil { return nil }
    if shape == .sshXtversion {
        return TerminalWarning(
            category: .wezTermKittyKeyboardOff,
            message: "Shift+Enter can't insert a newline in WezTerm over SSH",
            note: "For this session, type `\\` and then press Enter. Grok can't negotiate the Kitty keyboard protocol over SSH yet. `enable_kitty_keyboard = true` applies only to local WezTerm sessions."
        )
    }
    return TerminalWarning(
        category: .wezTermKittyKeyboardOff,
        message: "Shift+Enter can't insert a newline because WezTerm's Kitty keyboard protocol is off",
        fix: "config.enable_kitty_keyboard = true",
        configPath: "~/.config/wezterm/wezterm.lua",
        note: "Restart WezTerm after changing this setting. Until then, type `\\` and then press Enter to insert a newline."
    )
}

/// `ssh_wrap_hint` (mod.rs:477-497). All inputs injected.
public func sshWrapHint(
    isSSH: Bool,
    osc52SinkActive: Bool,
    isOfficialVSCodeRemote: Bool
) -> TerminalWarning? {
    if !isSSH || osc52SinkActive || isOfficialVSCodeRemote { return nil }
    return TerminalWarning(
        category: .sshWithoutWrap,
        message: "Use local SSH wrapping for more reliable clipboard copy and terminal recovery",
        fix: "open-grok wrap ssh <host>",
        note: "Run this on your local computer instead of plain `ssh`. It forwards copies to your local clipboard and restores terminal modes if the connection drops."
    )
}

/// `diagnose_wayland_data_control` (mod.rs:809-830).
public func diagnoseWaylandDataControl(
    isWayland: Bool,
    dataControl: Bool,
    wlCopyAvailable: Bool
) -> TerminalWarning? {
    if !isWayland || dataControl { return nil }
    return TerminalWarning(
        category: .waylandNoDataControl,
        message: "Clipboard copies may fail if you switch away from this Wayland terminal",
        fix: wlCopyAvailable ? nil : "sudo apt install wl-clipboard",
        note: "Keep this terminal focused until the copy message appears. If your distribution does not use apt, install the `wl-clipboard` package with its package manager."
    )
}

/// `diagnose_wayland_data_control_from_common` (mod.rs:845-856): only an
/// `Available` probe result is evidence; Unavailable/Error never warn.
func diagnoseWaylandDataControlFromCommon(_ snapshot: CommonProbeSnapshot) -> TerminalWarning? {
    guard case .available(let dataControl) = snapshot.wayland.dataControl else { return nil }
    return diagnoseWaylandDataControl(
        isWayland: snapshot.wayland.isWayland,
        dataControl: dataControl,
        wlCopyAvailable: snapshot.wayland.wlCopyAvailable
    )
}

/// `color_support_warning` (mod.rs:957-1046). Explicit `/doctor` only.
public func colorSupportWarning(
    level: RuntimeEvidence<ColorLevel>,
    brand: TerminalName,
    colorPassthrough: TmuxColorPassthrough,
    isTmuxBacked: Bool,
    tmuxConfigPath: String
) -> TerminalWarning? {
    if level == .available(.none) {
        return TerminalWarning(
            category: .limitedColorSupport,
            message: "Colors are off because `NO_COLOR` is set",
            note: "Unset `NO_COLOR`, then restart Grok."
        )
    }

    // Checked before the detected level: what Grok emits is a different
    // question from what survives tmux (mod.rs:975-995).
    if colorPassthrough == .reduced {
        return TerminalWarning(
            category: .tmuxColorReduced,
            message: "tmux is reducing 24-bit color to this client's palette, so themes look washed out",
            fix: "set -as terminal-features \",*:RGB\"",
            configPath: tmuxConfigPath,
            note: "Run `tmux source-file \(tmuxConfigPath)`, then detach and reattach: the server reads the option only on reload, and a client fixes its color depth only at attach. If Grok still reports less than truecolor afterwards, also add `set -g default-terminal \"tmux-256color\"` and `export COLORTERM=truecolor` to your shell startup file."
        )
    }

    guard case .available(let level) = level else { return nil }
    if level.hasTruecolor { return nil }

    let levelLabel = level.canonicalName

    if brand == .appleTerminal {
        return TerminalWarning(
            category: .limitedColorSupport,
            message: "Apple Terminal supports 256 colors, so truecolor themes are unavailable",
            note: "Use a terminal that supports truecolor, such as Ghostty."
        )
    }

    if isTmuxBacked {
        return TerminalWarning(
            category: .limitedColorSupport,
            message: "This terminal reports \(levelLabel) color, so truecolor themes are unavailable",
            fix: "set -as terminal-features \",*:RGB\"",
            configPath: tmuxConfigPath,
            note: "In the same tmux config, also add `set -g default-terminal \"tmux-256color\"`. Add `export COLORTERM=truecolor` to your shell startup file. Then reload tmux with `tmux source-file \(tmuxConfigPath)`, then detach and reattach, and restart Grok."
        )
    }

    return TerminalWarning(
        category: .limitedColorSupport,
        message: "This terminal reports \(levelLabel) color, so truecolor themes are unavailable",
        fix: "export COLORTERM=truecolor",
        note: "Add this export to your shell startup file, such as `~/.zshrc` or `~/.bashrc`, then restart Grok."
    )
}
