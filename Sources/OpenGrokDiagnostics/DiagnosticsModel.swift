// DiagnosticsModel.swift
//
// Shared terminal diagnostic report types.
//
// Ports `xai-grok-pager/src/diagnostics/model.rs` (242 lines) at reference
// 650c1db7 one-to-one: `RuntimeFact`, `DiagnosticId`, `DiagnosticReport`,
// the facts tree, findings, probe notes, and the named finding IDs.

import Foundation

/// `RuntimeFact<T>` (model.rs:9-14).
public enum RuntimeFact<T: Equatable & Sendable>: Equatable, Sendable {
    case available(T)
    case noReply
    case unavailable
}

/// `DiagnosticId` (model.rs:16-32). Displays as `domain.item`.
public struct DiagnosticId: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let domain: String
    public let item: String

    public init(_ domain: String, _ item: String) {
        self.domain = domain
        self.item = item
    }

    public var description: String { "\(domain).\(item)" }
}

// Named finding IDs (model.rs:41-58).
public let notificationProtocolFallbackID = DiagnosticId("notifications", "protocol-fallback")
public let focusTrackingUnavailableID = DiagnosticId("notifications", "focus-tracking-unavailable")
public let sandboxProfileConflictID = DiagnosticId("sandbox", "profile-conflict")
public let clipboardDeliveryUnverifiedID = DiagnosticId("clipboard", "delivery-unverified")
public let clipboardDeliveryUnavailableID = DiagnosticId("clipboard", "delivery-unavailable")
public let newlineFallbackID = DiagnosticId("terminal", "newline-fallback")
public let iterm2ClipboardPermissionID = DiagnosticId("terminal", "iterm2-clipboard-permission")
public let vscodeSSHNonASCIIID = DiagnosticId("clipboard", "vscode-ssh-non-ascii")
public let voiceNoInputDeviceID = DiagnosticId("voice", "no-input-device")

/// `DiagnosticReport` (model.rs:34-83).
public struct DiagnosticReport: Sendable, Equatable {
    public var facts: DiagnosticFacts
    public var findings: [DiagnosticFinding]
    public var probeNotes: [ProbeNote]

    public init(facts: DiagnosticFacts, findings: [DiagnosticFinding], probeNotes: [ProbeNote]) {
        self.facts = facts
        self.findings = findings
        self.probeNotes = probeNotes
    }

    /// `issue_count` (model.rs:61-75): named findings plus one legacy count
    /// when the clipboard fact is unconfirmed and no named clipboard
    /// delivery finding already covers it.
    public var issueCount: Int {
        let named = findings.filter { $0.disposition == .issue }.count
        let legacyClipboard = !facts.clipboard.delivery.isConfirmed
            && !findings.contains { finding in
                finding.id == clipboardDeliveryUnverifiedID || finding.id == clipboardDeliveryUnavailableID
            }
        return named + (legacyClipboard ? 1 : 0)
    }

    /// `recommendation_count` (model.rs:77-82).
    public var recommendationCount: Int {
        findings.filter { $0.disposition == .recommendation }.count
    }
}

/// `DiagnosticFacts` (model.rs:85-100).
public struct DiagnosticFacts: Sendable, Equatable {
    public var terminal: TerminalName
    public var xtversion: RuntimeFact<String>
    public var multiplexer: MultiplexerKind
    public var byobu: ByobuBackend?
    public var ssh: Bool
    public var tmux: TmuxFacts
    public var color: ColorFacts
    public var keyboard: KeyboardFact?
    public var newline: NewlineFact?
    public var clipboard: ClipboardFacts
    /// Passive mic enumeration; `nil` omits the Voice section. Standalone
    /// mode leaves this injectable (voice probing is deferred, see PORT note
    /// in the target README comment block of DiagnosticsEngine.swift).
    public var voice: VoiceFacts?

    public init(
        terminal: TerminalName,
        xtversion: RuntimeFact<String>,
        multiplexer: MultiplexerKind,
        byobu: ByobuBackend?,
        ssh: Bool,
        tmux: TmuxFacts,
        color: ColorFacts,
        keyboard: KeyboardFact?,
        newline: NewlineFact?,
        clipboard: ClipboardFacts,
        voice: VoiceFacts?
    ) {
        self.terminal = terminal
        self.xtversion = xtversion
        self.multiplexer = multiplexer
        self.byobu = byobu
        self.ssh = ssh
        self.tmux = tmux
        self.color = color
        self.keyboard = keyboard
        self.newline = newline
        self.clipboard = clipboard
        self.voice = voice
    }
}

/// `VoiceFacts` (model.rs:103-109).
public enum VoiceFacts: Sendable, Equatable {
    case device(name: String, detail: String)
    case missing(error: String)
}

/// `TmuxFacts` (model.rs:111-118).
public struct TmuxFacts: Sendable, Equatable {
    public var extendedKeys: TmuxOptionFact
    public var setClipboard: TmuxOptionFact
    public var allowPassthroughSupport: TmuxSupportFact
    public var allowPassthrough: TmuxOptionFact
    public var colorPassthrough: TmuxColorPassthrough

    public init(
        extendedKeys: TmuxOptionFact,
        setClipboard: TmuxOptionFact,
        allowPassthroughSupport: TmuxSupportFact,
        allowPassthrough: TmuxOptionFact,
        colorPassthrough: TmuxColorPassthrough
    ) {
        self.extendedKeys = extendedKeys
        self.setClipboard = setClipboard
        self.allowPassthroughSupport = allowPassthroughSupport
        self.allowPassthrough = allowPassthrough
        self.colorPassthrough = colorPassthrough
    }
}

/// `TmuxColorPassthrough` (model.rs:125-135).
public enum TmuxColorPassthrough: Sendable, Equatable {
    case forwarded
    case reduced
    case unknown
}

/// `TmuxOptionFact` (model.rs:137-143).
public enum TmuxOptionFact: Sendable, Equatable {
    case available(String)
    case unsupported
    case unavailable
    case error
}

/// `TmuxSupportFact` (model.rs:145-151).
public enum TmuxSupportFact: Sendable, Equatable {
    case supported
    case unsupported
    case unavailable
    case error
}

/// `ColorFacts` (model.rs:153-158).
public struct ColorFacts: Sendable, Equatable {
    public var level: RuntimeFact<ColorLevel>
    public var availableThemes: [ThemeKind]
    public var totalThemes: Int

    public init(level: RuntimeFact<ColorLevel>, availableThemes: [ThemeKind], totalThemes: Int) {
        self.level = level
        self.availableThemes = availableThemes
        self.totalThemes = totalThemes
    }
}

/// `KeyboardFact` (model.rs:160-164).
public struct KeyboardFact: Sendable, Equatable {
    public var modifierDelivery: ModifierDelivery
    public var os: HostOs

    public init(modifierDelivery: ModifierDelivery, os: HostOs) {
        self.modifierDelivery = modifierDelivery
        self.os = os
    }
}

/// `NewlineFact` (model.rs:166-171).
public enum NewlineFact: Sendable, Equatable {
    case vte(version: String?)
    case xtermJs(terminal: TerminalName)
    case noKittyKeyboardProtocol
}

/// `ClipboardFacts` (model.rs:173-189).
public struct ClipboardFacts: Sendable, Equatable {
    public var nativeRoute: Bool
    public var nativeTool: String
    public var nativePreflight: NativeClipboardPreflight
    public var tmuxRoute: Bool
    public var osc52Route: Bool
    public var osc52Capability: Osc52Capability
    public var wrapSink: Bool
    public var displayServer: DisplayServer
    public var containerNoDisplay: Bool
    public var dataControl: DataControlFact
    public var delivery: ClipboardDelivery
    /// Compatibility projection for compact status/JSON consumers.
    public var fix: String?

    public init(
        nativeRoute: Bool,
        nativeTool: String,
        nativePreflight: NativeClipboardPreflight,
        tmuxRoute: Bool,
        osc52Route: Bool,
        osc52Capability: Osc52Capability,
        wrapSink: Bool,
        displayServer: DisplayServer,
        containerNoDisplay: Bool,
        dataControl: DataControlFact,
        delivery: ClipboardDelivery,
        fix: String?
    ) {
        self.nativeRoute = nativeRoute
        self.nativeTool = nativeTool
        self.nativePreflight = nativePreflight
        self.tmuxRoute = tmuxRoute
        self.osc52Route = osc52Route
        self.osc52Capability = osc52Capability
        self.wrapSink = wrapSink
        self.displayServer = displayServer
        self.containerNoDisplay = containerNoDisplay
        self.dataControl = dataControl
        self.delivery = delivery
        self.fix = fix
    }
}

/// `DataControlFact` (model.rs:191-198).
public enum DataControlFact: Sendable, Equatable {
    case available
    case missing
    case unavailable
    case error
    case notApplicable
}

/// `DiagnosticFinding` (model.rs:200-208).
public struct DiagnosticFinding: Sendable, Equatable {
    public var id: DiagnosticId
    public var disposition: FindingDisposition
    public var message: String
    public var remediation: ManualRemediation?
    public var automaticRemediation: AutomaticRemediation?
    public var note: String?

    public init(
        id: DiagnosticId,
        disposition: FindingDisposition,
        message: String,
        remediation: ManualRemediation?,
        automaticRemediation: AutomaticRemediation?,
        note: String?
    ) {
        self.id = id
        self.disposition = disposition
        self.message = message
        self.remediation = remediation
        self.automaticRemediation = automaticRemediation
        self.note = note
    }
}

/// `FindingDisposition` (model.rs:210-214).
public enum FindingDisposition: Sendable, Equatable {
    case issue
    case recommendation
}

/// `ManualRemediation` (model.rs:216-220).
public struct ManualRemediation: Sendable, Equatable {
    public var fix: String
    public var configPath: String?

    public init(fix: String, configPath: String?) {
        self.fix = fix
        self.configPath = configPath
    }
}

/// `ProbeNote` (model.rs:222-227).
public struct ProbeNote: Sendable, Equatable {
    public var probe: String
    public var status: ProbeStatus
    public var message: String?

    public init(probe: String, status: ProbeStatus, message: String?) {
        self.probe = probe
        self.status = status
        self.message = message
    }
}

/// `probe_requires_live_tui` (model.rs:229-235).
public func probeRequiresLiveTUI(_ note: ProbeNote) -> Bool {
    note.status == .unavailable
        && ["runtime.fullscreen-active", "runtime.kitty-flags-pushed", "runtime.xtversion"].contains(note.probe)
}

/// `ProbeStatus` (model.rs:237-242).
public enum ProbeStatus: Sendable, Equatable {
    case unsupported
    case unavailable
    case error
}
