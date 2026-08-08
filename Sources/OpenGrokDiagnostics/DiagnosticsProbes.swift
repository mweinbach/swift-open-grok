// DiagnosticsProbes.swift
//
// Shared terminal observations for diagnostics consumers.
//
// Ports `xai-grok-pager/src/diagnostics/probes/mod.rs` (575 lines) and
// `probes/tmux.rs` (the `TmuxOptionQuery` seam) at reference 650c1db7.
//
// The standalone collector never runs live tmux subprocesses
// (`collect_standalone`, probes/mod.rs:158-162): skipped tmux evidence is
// reported Unavailable so a stuck server cannot block doctor. The bounded
// live probe lives in TmuxProbeLive.swift behind `TmuxOptionQuery`; tests
// inject fakes.
//
// The TUI-side collectors (`collect_startup_tui`, `collect_doctor_tui`,
// probes/mod.rs:108-156) are NOT ported: they need live pager runtime
// evidence, which this slice leaves injectable via
// `DiagnosticRuntimeEvidence` (all Unavailable in standalone mode).

import Foundation
import OpenGrokShared

/// `TmuxProbeResult<T>` = `TmuxQueryResult<T>` (tmux_probe.rs:158-173).
public enum TmuxProbeResult<T: Equatable & Sendable>: Equatable, Sendable {
    case available(T)
    case unsupported
    case unavailable
    case error(String)
}

/// `TmuxOptionQuery` (probes/tmux.rs:5-15). Tests inject fakes; the live
/// implementation shells bounded `tmux` subprocesses.
public protocol TmuxOptionQuery: Sendable {
    func showOption(_ option: String) -> TmuxProbeResult<String>
    func optionSupport(_ option: String) -> TmuxProbeResult<Bool>
    func controlMode() -> TmuxProbeResult<Bool>
    /// The attached client's resolved terminal features, which decide whether
    /// tmux forwards 24-bit color or reduces it to the client terminfo palette.
    func clientFeatures() -> TmuxProbeResult<String>
}

/// `RuntimeEvidence<T>` (probes/mod.rs:16-20).
public enum RuntimeEvidence<T: Equatable & Sendable>: Equatable, Sendable {
    case available(T)
    case unavailable
}

/// `TuiProbeEvidence` (probes/mod.rs:9-14).
public struct TuiProbeEvidence: Sendable, Equatable {
    public var fullscreenActive: Bool
    public var kittyFlagsPushed: Bool
    public var xtversion: String?

    public init(fullscreenActive: Bool, kittyFlagsPushed: Bool, xtversion: String?) {
        self.fullscreenActive = fullscreenActive
        self.kittyFlagsPushed = kittyFlagsPushed
        self.xtversion = xtversion
    }
}

/// `DiagnosticRuntimeEvidence` (probes/mod.rs:22-37).
public struct DiagnosticRuntimeEvidence: Sendable, Equatable {
    public var fullscreenActive: RuntimeEvidence<Bool>
    public var kittyFlagsPushed: RuntimeEvidence<Bool>
    public var xtversion: RuntimeEvidence<String?>

    public init(
        fullscreenActive: RuntimeEvidence<Bool>,
        kittyFlagsPushed: RuntimeEvidence<Bool>,
        xtversion: RuntimeEvidence<String?>
    ) {
        self.fullscreenActive = fullscreenActive
        self.kittyFlagsPushed = kittyFlagsPushed
        self.xtversion = xtversion
    }

    /// `From<TuiProbeEvidence>` (probes/mod.rs:29-37).
    public init(_ evidence: TuiProbeEvidence) {
        self.fullscreenActive = .available(evidence.fullscreenActive)
        self.kittyFlagsPushed = .available(evidence.kittyFlagsPushed)
        self.xtversion = .available(evidence.xtversion)
    }

    /// Standalone mode: every runtime-only probe honestly Unavailable
    /// (`From<StandaloneDiagnosticSnapshot>`, view.rs:70-86).
    public static let unavailable = DiagnosticRuntimeEvidence(
        fullscreenActive: .unavailable,
        kittyFlagsPushed: .unavailable,
        xtversion: .unavailable
    )
}

/// `TmuxProbeFacts` (probes/mod.rs:79-88). `allowPassthroughSupport` carries
/// `Bool` payload-free semantics via `available(true)` — upstream uses `()`.
public struct TmuxProbeFacts: Sendable, Equatable {
    public var version: TmuxProbeResult<String>
    public var extendedKeys: TmuxProbeResult<String>
    public var setClipboard: TmuxProbeResult<String>
    public var allowPassthroughSupport: TmuxProbeResult<Bool>
    public var allowPassthrough: TmuxProbeResult<String>
    public var controlMode: TmuxProbeResult<Bool>
    /// Comma-separated `client_termfeatures` for the attached client.
    public var clientFeatures: TmuxProbeResult<String>

    public init(
        version: TmuxProbeResult<String>,
        extendedKeys: TmuxProbeResult<String>,
        setClipboard: TmuxProbeResult<String>,
        allowPassthroughSupport: TmuxProbeResult<Bool>,
        allowPassthrough: TmuxProbeResult<String>,
        controlMode: TmuxProbeResult<Bool>,
        clientFeatures: TmuxProbeResult<String>
    ) {
        self.version = version
        self.extendedKeys = extendedKeys
        self.setClipboard = setClipboard
        self.allowPassthroughSupport = allowPassthroughSupport
        self.allowPassthrough = allowPassthrough
        self.controlMode = controlMode
        self.clientFeatures = clientFeatures
    }

    /// `unavailable_tmux` (probes/mod.rs:288-298).
    public static let unavailable = TmuxProbeFacts(
        version: .unavailable,
        extendedKeys: .unavailable,
        setClipboard: .unavailable,
        allowPassthroughSupport: .unavailable,
        allowPassthrough: .unavailable,
        controlMode: .unavailable,
        clientFeatures: .unavailable
    )
}

/// `ClipboardProbeFacts` (probes/mod.rs:90-95).
public struct ClipboardProbeFacts: Sendable, Equatable {
    public var route: ClipboardRoute
    public var nativeTool: String
    public var osc52SinkActive: Bool

    public init(route: ClipboardRoute, nativeTool: String, osc52SinkActive: Bool) {
        self.route = route
        self.nativeTool = nativeTool
        self.osc52SinkActive = osc52SinkActive
    }
}

/// `WaylandProbeFacts` (probes/mod.rs:97-102).
public struct WaylandProbeFacts: Sendable, Equatable {
    public var isWayland: Bool
    public var dataControl: TmuxProbeResult<Bool>
    public var wlCopyAvailable: Bool

    public init(isWayland: Bool, dataControl: TmuxProbeResult<Bool>, wlCopyAvailable: Bool) {
        self.isWayland = isWayland
        self.dataControl = dataControl
        self.wlCopyAvailable = wlCopyAvailable
    }
}

/// `CommonProbeSnapshot` (probes/mod.rs:46-50).
public struct CommonProbeSnapshot: Sendable, Equatable {
    public var terminal: TerminalContext
    public var tmux: TmuxProbeFacts
    public var wayland: WaylandProbeFacts

    public init(terminal: TerminalContext, tmux: TmuxProbeFacts, wayland: WaylandProbeFacts) {
        self.terminal = terminal
        self.tmux = tmux
        self.wayland = wayland
    }
}

/// `StandaloneDiagnosticSnapshot` (probes/mod.rs:52-59).
public struct StandaloneDiagnosticSnapshot: Sendable, Equatable {
    public var common: CommonProbeSnapshot
    public var clipboard: ClipboardProbeFacts
    public var hostOs: HostOs
    public var displayServer: DisplayServer
    public var containerNoDisplay: Bool
    public var colorLevel: RuntimeEvidence<ColorLevel>

    public init(
        common: CommonProbeSnapshot,
        clipboard: ClipboardProbeFacts,
        hostOs: HostOs,
        displayServer: DisplayServer,
        containerNoDisplay: Bool,
        colorLevel: RuntimeEvidence<ColorLevel>
    ) {
        self.common = common
        self.clipboard = clipboard
        self.hostOs = hostOs
        self.displayServer = displayServer
        self.containerNoDisplay = containerNoDisplay
        self.colorLevel = colorLevel
    }
}

/// `collect_standalone_from` (probes/mod.rs:258-286) — the pure assembler.
public func collectStandaloneFrom(
    terminal: TerminalContext,
    tmux: TmuxProbeFacts,
    wayland: WaylandProbeFacts,
    nativeTool: String,
    route: ClipboardRoute,
    osc52SinkActive: Bool,
    hostOs: HostOs,
    displayServer: DisplayServer,
    containerNoDisplay: Bool,
    colorLevel: RuntimeEvidence<ColorLevel>
) -> StandaloneDiagnosticSnapshot {
    StandaloneDiagnosticSnapshot(
        common: CommonProbeSnapshot(terminal: terminal, tmux: tmux, wayland: wayland),
        clipboard: ClipboardProbeFacts(route: route, nativeTool: nativeTool, osc52SinkActive: osc52SinkActive),
        hostOs: hostOs,
        displayServer: displayServer,
        containerNoDisplay: containerNoDisplay,
        colorLevel: colorLevel
    )
}

/// `collect_standalone` (probes/mod.rs:158-162): standalone evidence with
/// **no** live tmux subprocess; tmux facts are all Unavailable so a stuck
/// server cannot block doctor.
public func collectStandalone(
    terminal: TerminalContext,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> StandaloneDiagnosticSnapshot {
    collectStandaloneWithTmux(terminal: terminal, tmux: .unavailable, environment: environment)
}

/// `collect_standalone_fix` (probes/mod.rs:164-170): bounded live tmux facts
/// for explicit fix planning, scoped to the requested fix ID.
public func collectStandaloneFix(
    terminal: TerminalContext,
    id: DiagnosticId?,
    tmux query: any TmuxOptionQuery = LiveTmuxProbe(),
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> StandaloneDiagnosticSnapshot {
    collectStandaloneWithTmux(
        terminal: terminal,
        tmux: collectTmuxFix(terminal: terminal, id: id, tmux: query),
        environment: environment
    )
}

/// `collect_tmux_fix` (probes/mod.rs:172-218).
func collectTmuxFix(
    terminal: TerminalContext,
    id: DiagnosticId?,
    tmux: any TmuxOptionQuery
) -> TmuxProbeFacts {
    if !terminal.isTmuxBacked { return .unavailable }
    func wants(_ candidate: DiagnosticId) -> Bool { id == nil || id == candidate }

    let setClipboard = wants(tmuxClipboardID) ? tmux.showOption("set-clipboard") : .unavailable
    let extendedKeys = wants(tmuxExtendedKeysID) ? tmux.showOption("extended-keys") : .unavailable
    let allowPassthroughSupport: TmuxProbeResult<Bool>
    let allowPassthrough: TmuxProbeResult<String>
    if wants(dcsPassthroughID) {
        let support = tmux.optionSupport("allow-passthrough")
        allowPassthroughSupport = support
        switch support {
        case .available: allowPassthrough = tmux.showOption("allow-passthrough")
        case .unsupported: allowPassthrough = .unsupported
        case .unavailable: allowPassthrough = .unavailable
        case .error(let error): allowPassthrough = .error(error)
        }
    } else {
        allowPassthroughSupport = .unavailable
        allowPassthrough = .unavailable
    }
    let clientFeatures = wants(tmuxTruecolorID) ? tmux.clientFeatures() : .unavailable

    return TmuxProbeFacts(
        version: .unavailable,
        extendedKeys: extendedKeys,
        setClipboard: setClipboard,
        allowPassthroughSupport: allowPassthroughSupport,
        allowPassthrough: allowPassthrough,
        controlMode: .unavailable,
        clientFeatures: clientFeatures
    )
}

/// `collect_standalone_with_tmux` (probes/mod.rs:220-253). Environment facts
/// come from the injected env map plus `OpenGrokShared` helpers:
/// `nativeClipboardToolName` / `isContainerizedWithoutDisplay`
/// (Sources/OpenGrokShared/Clipboard.swift:185-221).
private func collectStandaloneWithTmux(
    terminal: TerminalContext,
    tmux: TmuxProbeFacts,
    environment: [String: String]
) -> StandaloneDiagnosticSnapshot {
    let hostOs = HostOs.current()
    let displayServer = DisplayServer.detect(environment: environment)
    let isWayland = displayServer == .wayland
    let nativeTool = nativeClipboardToolName()
    let containerNoDisplay = isContainerizedWithoutDisplay(environment: environment)
    let colorLevel: RuntimeEvidence<ColorLevel>
    switch standaloneColorEvidence(environment: environment, terminal: terminal.brand) {
    case .available(let level): colorLevel = .available(level)
    case .unavailable: colorLevel = .unavailable
    }
    return collectStandaloneFrom(
        terminal: terminal,
        tmux: tmux,
        wayland: WaylandProbeFacts(
            isWayland: isWayland,
            // The Wayland data-control probe is a live compositor query the
            // port's shell layer does not expose yet; Unavailable is honest
            // and never treated as a problem (see standalone_data_control,
            // probes/mod.rs:300-315 — recorded divergence).
            dataControl: .unavailable,
            wlCopyAvailable: isWayland && nativeTool == "wl-copy"
        ),
        nativeTool: nativeTool,
        route: resolveStandaloneClipboardRoute(terminal: terminal, environment: environment),
        // `osc52_sink_active` (pager-render clipboard/mod.rs:50-56): the wrap
        // sink advertises through GROK_OSC52_SINK / LC_GROK_OSC52_SINK.
        osc52SinkActive: environment["GROK_OSC52_SINK"] != nil || environment["LC_GROK_OSC52_SINK"] != nil,
        hostOs: hostOs,
        displayServer: displayServer,
        containerNoDisplay: containerNoDisplay,
        colorLevel: colorLevel
    )
}

/// Standalone clipboard route: native always attempted, tmux buffer when
/// tmux-backed, OSC 52 when remote/containerized (the shape
/// `resolve_clipboard_route` produces for a non-TUI process; the full
/// config-driven resolver stays with the pager wiring slice).
func resolveStandaloneClipboardRoute(
    terminal: TerminalContext,
    environment: [String: String]
) -> ClipboardRoute {
    let remote = isRemoteSession(environment: environment)
        || isContainerizedWithoutDisplay(environment: environment)
    return ClipboardRoute(
        native: true,
        tmuxBuffer: terminal.isTmuxBacked,
        osc52: remote || terminal.brand.supportsOSC52Clipboard,
        osc52TmuxPassthrough: terminal.isTmuxBacked
    )
}
