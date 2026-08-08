// DiagnosticsView.swift
//
// Interpretation of terminal probe snapshots.
//
// Ports `xai-grok-pager/src/diagnostics/view.rs` (681 lines) at reference
// 650c1db7. The snapshot is fully injected; standalone mode marks every
// runtime-only probe Unavailable (view.rs:70-86).

import Foundation

/// `DiagnosticSnapshot` (view.rs:15-23).
public struct DiagnosticSnapshot: Sendable, Equatable {
    public var common: CommonProbeSnapshot
    public var clipboard: ClipboardProbeFacts
    public var hostOs: HostOs
    public var displayServer: DisplayServer
    public var containerNoDisplay: Bool
    public var colorLevel: RuntimeEvidence<ColorLevel>
    public var runtime: DiagnosticRuntimeEvidence

    public init(
        common: CommonProbeSnapshot,
        clipboard: ClipboardProbeFacts,
        hostOs: HostOs,
        displayServer: DisplayServer,
        containerNoDisplay: Bool,
        colorLevel: RuntimeEvidence<ColorLevel>,
        runtime: DiagnosticRuntimeEvidence
    ) {
        self.common = common
        self.clipboard = clipboard
        self.hostOs = hostOs
        self.displayServer = displayServer
        self.containerNoDisplay = containerNoDisplay
        self.colorLevel = colorLevel
        self.runtime = runtime
    }

    /// `From<StandaloneDiagnosticSnapshot>` (view.rs:70-86): runtime-only
    /// probes are honestly Unavailable in standalone mode.
    public init(standalone snapshot: StandaloneDiagnosticSnapshot) {
        self.init(
            common: snapshot.common,
            clipboard: snapshot.clipboard,
            hostOs: snapshot.hostOs,
            displayServer: snapshot.displayServer,
            containerNoDisplay: snapshot.containerNoDisplay,
            colorLevel: snapshot.colorLevel,
            runtime: .unavailable
        )
    }
}

/// The engine facade the wiring slice calls.
public enum DiagnosticsEngine {
    /// `view` (view.rs:88-135): snapshot → facts + findings + probe notes.
    public static func report(snapshot: DiagnosticSnapshot) -> DiagnosticReport {
        diagnosticsView(snapshot)
    }
}

/// `view` (view.rs:88-135).
public func diagnosticsView(_ snapshot: DiagnosticSnapshot) -> DiagnosticReport {
    let ctx = snapshot.common.terminal
    let weztermWarning = weztermWarningFor(snapshot)
    // view.rs:91-99 — Rust `a || b && c` groups as `a || (b && c)`.
    let suppressNewline = weztermWarning != nil
        || (snapshot.runtime.kittyFlagsPushed == .unavailable
            && weztermShape(ctx, xtversionPayload: runtimeXtversion(snapshot.runtime.xtversion)) != nil)

    var warnings = startupWarnings(snapshot)
    if let wayland = diagnoseWaylandDataControlFromCommon(snapshot.common) {
        warnings.append(wayland)
    }
    if let wezterm = weztermWarning {
        warnings.append(wezterm)
    }
    if let color = colorSupportWarning(
        level: snapshot.colorLevel,
        brand: ctx.brand,
        colorPassthrough: tmuxColorPassthroughFact(snapshot.common.tmux.clientFeatures),
        isTmuxBacked: ctx.isTmuxBacked,
        tmuxConfigPath: ctx.tmuxConfigPath
    ) {
        warnings.append(color)
    }

    let (facts, clipboardRecovery) = diagnosticFacts(snapshot, suppressNewline: suppressNewline)
    var findings = warnings.compactMap(findingFromWarning)
    findings.append(contentsOf: clipboardFindings(facts: facts, ctx: ctx, recovery: clipboardRecovery))
    if let newline = newlineFinding(facts: facts) {
        findings.append(newline)
    }
    if let hint = sshWrapHint(
        isSSH: ctx.isSSH,
        osc52SinkActive: snapshot.clipboard.osc52SinkActive,
        isOfficialVSCodeRemote: ctx.isOfficialVSCodeRemote
    ), let recommendation = finding(from: hint, disposition: .recommendation) {
        findings.append(recommendation)
    }

    return DiagnosticReport(
        facts: facts,
        findings: findings,
        probeNotes: probeNotes(snapshot)
    )
}

/// `startup_warnings` (view.rs:137-147).
private func startupWarnings(_ snapshot: DiagnosticSnapshot) -> [TerminalWarning] {
    let fullscreenActive: Bool?
    switch snapshot.runtime.fullscreenActive {
    case .available(let value): fullscreenActive = value
    case .unavailable: fullscreenActive = nil
    }
    return collectStartupWarnings(
        terminal: snapshot.common.terminal,
        tmux: snapshot.common.tmux,
        fullscreenActive: fullscreenActive
    )
}

/// `wezterm_warning` (view.rs:149-158).
private func weztermWarningFor(_ snapshot: DiagnosticSnapshot) -> TerminalWarning? {
    guard case .available(let kittyFlagsPushed) = snapshot.runtime.kittyFlagsPushed else { return nil }
    return weztermKittyKeyboardWarning(
        snapshot.common.terminal,
        kittyFlagsPushed: kittyFlagsPushed,
        xtversionPayload: runtimeXtversion(snapshot.runtime.xtversion)
    )
}

/// `runtime_xtversion` (view.rs:160-165).
private func runtimeXtversion(_ evidence: RuntimeEvidence<String?>) -> String? {
    switch evidence {
    case .available(let xtversion): return xtversion
    case .unavailable: return nil
    }
}

/// `facts` (view.rs:167-254).
private func diagnosticFacts(
    _ snapshot: DiagnosticSnapshot,
    suppressNewline: Bool
) -> (DiagnosticFacts, ClipboardRecovery) {
    let ctx = snapshot.common.terminal
    let availableThemes: [ThemeKind]
    switch snapshot.colorLevel {
    case .available(let colorLevel):
        availableThemes = ThemeKind.all.filter { colorLevel.hasTruecolor || !$0.requiresTruecolor }
    case .unavailable:
        availableThemes = []
    }
    let keyboardCapabilities = keyboardCapabilitiesForHost(ctx.brand, host: snapshot.hostOs)
    let keyboard: KeyboardFact? =
        (keyboardCapabilities.modifierDelivery.benefitsFromRescue || keyboardCapabilities.enterNeedsRescue)
        ? KeyboardFact(modifierDelivery: keyboardCapabilities.modifierDelivery, os: snapshot.hostOs)
        : nil
    let newline: NewlineFact?
    if ctx.shiftEnterUnavailable && !suppressNewline {
        if ctx.vteVersion != nil || ctx.brand == .vte {
            newline = .vte(version: ctx.vteVersion)
        } else if ctx.brand.isVSCodeFamily {
            newline = .xtermJs(terminal: ctx.brand)
        } else {
            newline = .noKittyKeyboardProtocol
        }
    } else {
        newline = nil
    }
    let dataControl: DataControlFact
    if !snapshot.common.wayland.isWayland {
        dataControl = .notApplicable
    } else {
        switch snapshot.common.wayland.dataControl {
        case .available(true): dataControl = .available
        case .available(false): dataControl = .missing
        case .unavailable, .unsupported: dataControl = .unavailable
        case .error: dataControl = .error
        }
    }
    let (clipboard, clipboardRecovery) = clipboardFactsFor(snapshot, dataControl: dataControl)

    let xtversion: RuntimeFact<String>
    switch snapshot.runtime.xtversion {
    case .available(.some(let value)): xtversion = .available(value)
    case .available(.none): xtversion = .noReply
    case .unavailable: xtversion = .unavailable
    }
    let colorLevel: RuntimeFact<ColorLevel>
    switch snapshot.colorLevel {
    case .available(let level): colorLevel = .available(level)
    case .unavailable: colorLevel = .unavailable
    }

    return (
        DiagnosticFacts(
            terminal: ctx.brand,
            xtversion: xtversion,
            multiplexer: ctx.multiplexer,
            byobu: ctx.byobu,
            ssh: ctx.isSSH,
            tmux: TmuxFacts(
                extendedKeys: tmuxOptionFact(snapshot.common.tmux.extendedKeys),
                setClipboard: tmuxOptionFact(snapshot.common.tmux.setClipboard),
                allowPassthroughSupport: tmuxSupportFact(snapshot.common.tmux.allowPassthroughSupport),
                allowPassthrough: tmuxOptionFact(snapshot.common.tmux.allowPassthrough),
                colorPassthrough: tmuxColorPassthroughFact(snapshot.common.tmux.clientFeatures)
            ),
            color: ColorFacts(
                level: colorLevel,
                availableThemes: availableThemes,
                totalThemes: ThemeKind.all.count
            ),
            keyboard: keyboard,
            newline: newline,
            clipboard: clipboard,
            voice: nil
        ),
        clipboardRecovery
    )
}

/// `ClipboardRecovery` (view.rs:256-294).
enum ClipboardRecovery: Equatable {
    case confirmed
    case unverifiedSsh
    case unverifiedContainer
    case unverifiedOther
    case unavailableSsh
    case unavailableContainer
    case unavailableLocal

    static func classify(delivery: ClipboardDelivery, ssh: Bool, container: Bool) -> ClipboardRecovery {
        switch (delivery, ssh, container) {
        case (.confirmed, _, _): return .confirmed
        case (.unverified, true, _): return .unverifiedSsh
        case (.unverified, false, true): return .unverifiedContainer
        case (.unverified, false, false): return .unverifiedOther
        case (.failed, true, _): return .unavailableSsh
        case (.failed, false, true): return .unavailableContainer
        case (.failed, false, false): return .unavailableLocal
        }
    }

    /// `legacy_fix` (view.rs:281-293).
    var legacyFix: String? {
        switch self {
        case .confirmed: return nil
        case .unverifiedSsh, .unavailableSsh: return "grok wrap <ssh command> or /minimal"
        case .unverifiedContainer, .unavailableContainer: return "grok wrap <command> or /minimal"
        case .unverifiedOther: return "grok wrap or /minimal"
        case .unavailableLocal: return "/minimal"
        }
    }
}

/// `clipboard_facts` (view.rs:296-346).
private func clipboardFactsFor(
    _ snapshot: DiagnosticSnapshot,
    dataControl: DataControlFact
) -> (ClipboardFacts, ClipboardRecovery) {
    let route = snapshot.clipboard.route
    let waylandDataControl: Bool
    if case .available(true) = snapshot.common.wayland.dataControl {
        waylandDataControl = true
    } else {
        waylandDataControl = false
    }
    let environment = ClipboardEnvironment(
        brand: snapshot.common.terminal.brand,
        hostOs: snapshot.hostOs,
        displayServer: snapshot.displayServer,
        remote: snapshot.common.terminal.isSSH,
        container: snapshot.containerNoDisplay,
        osc52Sink: snapshot.clipboard.osc52SinkActive,
        waylandDataControl: waylandDataControl,
        wlCopyAvailable: snapshot.common.wayland.wlCopyAvailable
    )
    let nativePreflight = nativeClipboardPreflight(routeNative: route.native, environment: environment)
    let delivery = expectedDelivery(
        native: nativePreflight,
        routeTmux: route.tmuxBuffer,
        routeOsc52: route.osc52,
        environment: environment
    )
    let recovery = ClipboardRecovery.classify(
        delivery: delivery,
        ssh: snapshot.common.terminal.isSSH,
        container: snapshot.containerNoDisplay
    )

    return (
        ClipboardFacts(
            nativeRoute: route.native,
            nativeTool: snapshot.clipboard.nativeTool,
            nativePreflight: nativePreflight,
            tmuxRoute: route.tmuxBuffer,
            osc52Route: route.osc52,
            osc52Capability: environment.osc52Capability,
            wrapSink: snapshot.clipboard.osc52SinkActive,
            displayServer: snapshot.displayServer,
            containerNoDisplay: snapshot.containerNoDisplay,
            dataControl: dataControl,
            delivery: delivery,
            fix: recovery.legacyFix
        ),
        recovery
    )
}

/// `finding_from_warning` (view.rs:348-351).
func findingFromWarning(_ warning: TerminalWarning) -> DiagnosticFinding? {
    finding(from: warning, disposition: dispositionFor(warning.category))
}

/// `disposition_for` (view.rs:353-358).
func dispositionFor(_ category: WarningCategory) -> FindingDisposition {
    category == .sshWithoutWrap ? .recommendation : .issue
}

/// `manual_finding` (view.rs:364-378).
private func manualFinding(
    id: DiagnosticId,
    disposition: FindingDisposition,
    message: String,
    note: String
) -> DiagnosticFinding {
    DiagnosticFinding(
        id: id,
        disposition: disposition,
        message: message,
        remediation: nil,
        automaticRemediation: nil,
        note: note
    )
}

/// `clipboard_findings` (view.rs:380-471).
private func clipboardFindings(
    facts: DiagnosticFacts,
    ctx: TerminalContext,
    recovery: ClipboardRecovery
) -> [DiagnosticFinding] {
    var findings: [DiagnosticFinding] = []
    switch recovery {
    case .confirmed:
        break
    case .unverifiedSsh:
        findings.append(manualFinding(
            id: clipboardDeliveryUnverifiedID,
            disposition: .issue,
            message: "Grok can't verify this clipboard route across the remote boundary",
            note: "When you copy, Grok sends OSC 52 but can't confirm that the outer terminal accepted it. Each copy is also saved to a backup file; the copy message shows the path. If paste fails, run `open-grok wrap ssh <host>` on your local computer or use `/minimal`. For repeated SSH sessions, run `grok doctor fix ssh-wrap` on your local computer."
        ))
    case .unverifiedContainer:
        findings.append(manualFinding(
            id: clipboardDeliveryUnverifiedID,
            disposition: .issue,
            message: "Grok can't verify this clipboard route across the container boundary",
            note: "When you copy, Grok sends OSC 52 but can't confirm that the outer terminal accepted it. Each copy is also saved to a backup file; the copy message shows the path. If paste fails, start the container command with local `grok wrap <command>`, or use `/minimal`."
        ))
    case .unverifiedOther:
        findings.append(manualFinding(
            id: clipboardDeliveryUnverifiedID,
            disposition: .issue,
            message: "Grok can't verify this clipboard route",
            note: "Each copy is also saved to a backup file; the copy message shows the path. For a remote or container command, use local `grok wrap <command>`. You can also use `/minimal` to select text in the terminal."
        ))
    case .unavailableSsh:
        findings.append(manualFinding(
            id: clipboardDeliveryUnavailableID,
            disposition: .issue,
            message: "This clipboard route can't reach the target clipboard",
            note: "When you copy, Grok saves the text to the backup file shown in the copy message. To copy directly, run `open-grok wrap ssh <host>` on your local computer. For repeated SSH sessions, run `grok doctor fix ssh-wrap` there. You can also use `/copy <file>` or `/minimal`."
        ))
    case .unavailableContainer:
        findings.append(manualFinding(
            id: clipboardDeliveryUnavailableID,
            disposition: .issue,
            message: "This clipboard route can't reach the target clipboard",
            note: "When you copy, Grok saves the text to the backup file shown in the copy message. Start the container command with local `grok wrap <command>`, use `/copy <file>`, or use `/minimal`."
        ))
    case .unavailableLocal:
        findings.append(manualFinding(
            id: clipboardDeliveryUnavailableID,
            disposition: .issue,
            message: "This clipboard route can't reach the target clipboard",
            note: "When you copy, Grok saves the text to the backup file shown in the copy message. Use `/copy <file>` or `/minimal`, then check the native clipboard tool listed above."
        ))
    }

    if ctx.brand.isVSCodeFamily
        && ctx.isSSH
        && facts.clipboard.osc52Route
        && !facts.clipboard.wrapSink {
        findings.append(manualFinding(
            id: vscodeSSHNonASCIIID,
            disposition: .recommendation,
            message: "This remote editor may change non-ASCII text copied with OSC 52",
            note: "If pasted non-ASCII text is incorrect, use `/minimal` and select text in the terminal. ASCII copy and the backup file shown after the copy remain available."
        ))
    }

    if ctx.brand == .iterm2
        && (ctx.isSSH || facts.clipboard.nativePreflight != .localAvailable)
        && facts.clipboard.osc52Route
        && !facts.clipboard.wrapSink {
        findings.append(manualFinding(
            id: iterm2ClipboardPermissionID,
            disposition: .recommendation,
            message: "iTerm2 may block OSC 52 clipboard access",
            note: "In iTerm2, open Settings → General → Selection and turn on “Applications in terminal may access clipboard.” Grok can't read this setting, so check it there if copies don't paste."
        ))
    }
    return findings
}

/// `newline_finding` (view.rs:473-508).
private func newlineFinding(facts: DiagnosticFacts) -> DiagnosticFinding? {
    guard let newline = facts.newline else { return nil }
    let message: String
    let note: String
    switch newline {
    case .vte(let version):
        message = "Shift+Enter can't insert a newline in this VTE terminal"
        if let version {
            note = "Use Alt+Enter to insert a newline. This terminal reports VTE \(version). Upgrade to VTE 0.82 or later to use Shift+Enter."
        } else {
            note = "Use Alt+Enter to insert a newline. Upgrade to VTE 0.82 or later to use Shift+Enter."
        }
    case .xtermJs(let terminal):
        message = "Shift+Enter can't insert a newline in this xterm.js terminal"
        note = "Use Alt+Enter to insert a newline in \(terminal). xterm.js sends Shift+Enter as Enter in this setup."
    case .noKittyKeyboardProtocol:
        message = "Shift+Enter can't insert a newline because the keyboard protocol is unavailable"
        note = "Use Alt+Enter to insert a newline. If your terminal supports the Kitty keyboard protocol, enable it and restart Grok."
    }
    return manualFinding(id: newlineFallbackID, disposition: .recommendation, message: message, note: note)
}

/// `finding` (view.rs:510-523).
private func finding(from warning: TerminalWarning, disposition: FindingDisposition) -> DiagnosticFinding? {
    guard let id = idFor(warning.category) else { return nil }
    return DiagnosticFinding(
        id: id,
        disposition: disposition,
        message: warning.message,
        remediation: warning.fix.map { ManualRemediation(fix: $0, configPath: warning.configPath) },
        automaticRemediation: automaticRemediationFor(id),
        note: warning.note
    )
}

/// `id_for` (view.rs:525-549).
public func idFor(_ category: WarningCategory) -> DiagnosticId? {
    let item: String
    switch category {
    case .clipboard: item = "tmux-clipboard"
    case .dcsPassthrough: item = "dcs-passthrough"
    case .controlMode: item = "control-mode"
    case .byobuScreen: item = "byobu-screen"
    case .unsupportedTerminal: item = "unsupported-emulator"
    case .tmuxExtendedKeysOff: item = "tmux-extended-keys"
    case .waylandNoDataControl: item = "wayland-data-control"
    case .wezTermKittyKeyboardOff: item = "wezterm-kitty"
    case .limitedColorSupport: item = "limited-color"
    case .tmuxColorReduced: item = "tmux-truecolor"
    case .sshWithoutWrap: item = "ssh-wrap"
    case .notificationProtocolFallback: return notificationProtocolFallbackID
    case .focusTrackingUnavailable: return focusTrackingUnavailableID
    case .sandboxProfileConflict: return sandboxProfileConflictID
    }
    return DiagnosticId("terminal", item)
}

/// `probe_notes` (view.rs:551-611).
private func probeNotes(_ snapshot: DiagnosticSnapshot) -> [ProbeNote] {
    var notes: [ProbeNote] = []
    if snapshot.common.terminal.isTmuxBacked {
        appendProbeNote(&notes, "tmux.version", snapshot.common.tmux.version)
        appendProbeNote(&notes, "tmux.extended-keys", snapshot.common.tmux.extendedKeys)
        appendProbeNote(&notes, "tmux.set-clipboard", snapshot.common.tmux.setClipboard)
        appendProbeNote(&notes, "tmux.allow-passthrough-support", snapshot.common.tmux.allowPassthroughSupport)
        if case .available = snapshot.common.tmux.allowPassthroughSupport {
            appendProbeNote(&notes, "tmux.allow-passthrough", snapshot.common.tmux.allowPassthrough)
        }
        appendProbeNote(&notes, "tmux.control-mode", snapshot.common.tmux.controlMode)
        appendProbeNote(&notes, "tmux.client-features", snapshot.common.tmux.clientFeatures)
    }
    appendRuntimeProbeNote(&notes, "runtime.fullscreen-active", snapshot.runtime.fullscreenActive)
    appendRuntimeProbeNote(&notes, "runtime.kitty-flags-pushed", snapshot.runtime.kittyFlagsPushed)
    appendRuntimeProbeNote(&notes, "runtime.xtversion", snapshot.runtime.xtversion)
    appendRuntimeProbeNote(&notes, "terminal.color", snapshot.colorLevel)
    if snapshot.common.wayland.isWayland {
        appendProbeNote(&notes, "wayland.data-control", snapshot.common.wayland.dataControl)
    }
    return notes
}

/// `tmux_option_fact` (view.rs:613-620).
func tmuxOptionFact(_ result: TmuxProbeResult<String>) -> TmuxOptionFact {
    switch result {
    case .available(let value): return .available(value)
    case .unsupported: return .unsupported
    case .unavailable: return .unavailable
    case .error: return .error
    }
}

/// `tmux_color_passthrough` (view.rs:622-640). `RGB` in the resolved
/// feature list is the only signal that 24-bit color survives tmux; a
/// missing answer is not evidence of clamping.
public func tmuxColorPassthroughFact(_ result: TmuxProbeResult<String>) -> TmuxColorPassthrough {
    guard case .available(let features) = result else { return .unknown }
    if features.trimmingCharacters(in: .whitespaces).isEmpty { return .unknown }
    let forwarded = features.split(separator: ",").contains { feature in
        feature.trimmingCharacters(in: .whitespaces).lowercased() == "rgb"
    }
    return forwarded ? .forwarded : .reduced
}

/// `tmux_support_fact` (view.rs:642-649).
func tmuxSupportFact(_ result: TmuxProbeResult<Bool>) -> TmuxSupportFact {
    switch result {
    case .available: return .supported
    case .unsupported: return .unsupported
    case .unavailable: return .unavailable
    case .error: return .error
    }
}

/// `probe_note` (view.rs:651-663).
private func appendProbeNote<T>(_ notes: inout [ProbeNote], _ probe: String, _ result: TmuxProbeResult<T>) {
    let status: ProbeStatus
    let message: String?
    switch result {
    case .available: return
    case .unsupported: (status, message) = (.unsupported, nil)
    case .unavailable: (status, message) = (.unavailable, nil)
    case .error(let error): (status, message) = (.error, error)
    }
    notes.append(ProbeNote(probe: probe, status: status, message: message))
}

/// `runtime_probe_note` (view.rs:665-677).
private func appendRuntimeProbeNote<T>(_ notes: inout [ProbeNote], _ probe: String, _ evidence: RuntimeEvidence<T>) {
    if case .unavailable = evidence {
        notes.append(ProbeNote(probe: probe, status: .unavailable, message: nil))
    }
}
