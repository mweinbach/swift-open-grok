// DoctorFix.swift
//
// Exact planning and application for diagnostic fixes.
//
// Ports `xai-grok-pager/src/diagnostics/fix.rs` (1607 lines) at reference
// 650c1db7: the fix registry (ssh-wrap, tmux-clipboard, dcs-passthrough,
// tmux-extended-keys, tmux-truecolor), `resolve_fix_id`, plan/preview/
// success text, and `apply_fix` — the managed-block write into the home
// shell/tmux config.
//
// Security posture (AGENTS.md §5): `applyFix` is a fail-closed home-config
// write. `SafeAbsoluteDirectory` (fix.rs:47-61) refuses any HOME or
// BYOBU_CONFIG_DIR that is relative, root-only, contains `.`/`..`
// components, control characters, or `~`; ssh-wrap planning refuses
// SSH/remote sessions outright (fix.rs:707-709). No pipeline of guards is
// skipped for tests — tests inject an isolated absolute temp HOME.

import Foundation

// MARK: - Registry IDs and constants (fix.rs:16-27)

public let sshWrapID = DiagnosticId("terminal", "ssh-wrap")
public let tmuxClipboardID = DiagnosticId("terminal", "tmux-clipboard")
public let dcsPassthroughID = DiagnosticId("terminal", "dcs-passthrough")
public let tmuxExtendedKeysID = DiagnosticId("terminal", "tmux-extended-keys")
public let tmuxTruecolorID = DiagnosticId("terminal", "tmux-truecolor")
public let sshWrapFixCommand = "grok doctor fix terminal.ssh-wrap"
public let sshWrapOneOff = "open-grok wrap ssh <host>"

let managedNamespace = "grok doctor"
private let sshWrapAliasPOSIX = "alias ssh='open-grok wrap ssh'"
private let sshWrapAliasFish = "alias ssh 'open-grok wrap ssh'"
private let tmuxScannerCaveat = "Grok checks this file for direct global assignments of this option. Review sourced files, conditionals, plugins, and generated tmux setup yourself."

/// `AutomaticRemediation` (fix.rs:29-33).
public struct AutomaticRemediation: Sendable, Equatable {
    public let fixID: DiagnosticId
    public let command: String

    public init(fixID: DiagnosticId, command: String) {
        self.fixID = fixID
        self.command = command
    }
}

// MARK: - SafeAbsoluteDirectory (fix.rs:44-67)

/// Fail-closed directory guard for HOME / BYOBU_CONFIG_DIR. Refuses:
/// relative paths, the filesystem root, `.`/`..` components, control
/// characters, and any `~` anywhere in the rendered path.
struct SafeAbsoluteDirectory: Sendable, Equatable {
    let path: String

    /// `SafeAbsoluteDirectory::parse` (fix.rs:48-62).
    static func parse(_ path: String, label: String) throws -> SafeAbsoluteDirectory {
        let isAbsolute = path.hasPrefix("/")
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        let isRootOnly = components.isEmpty
        let hasUnsafeComponent = components.contains { $0 == "." || $0 == ".." }
        // Rust `char::is_control` covers C0, DEL, and C1 (fix.rs:55-57).
        let isRenderable = !path.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
        } && !path.contains("~")
        if !isAbsolute || isRootOnly || hasUnsafeComponent || !isRenderable {
            throw FixError.unsafeDirectory(label: label, path: path)
        }
        return SafeAbsoluteDirectory(path: path)
    }

    func join(_ relative: String) -> String {
        path.hasSuffix("/") ? path + relative : path + "/" + relative
    }
}

// MARK: - FixRequest (fix.rs:35-101)

public struct FixRequest: Sendable {
    let id: DiagnosticId
    let home: SafeAbsoluteDirectory
    let shell: String?
    let validator: String?
    let byobuConfigDir: String?

    /// `FixRequest::new_for_test` (fix.rs:71-85) — public because callers
    /// (and tests) may resolve HOME/SHELL themselves; every path still goes
    /// through `SafeAbsoluteDirectory`.
    public init(
        id: DiagnosticId,
        home: String,
        shell: String?,
        validator: String?,
        byobuConfigDir: String?
    ) throws {
        self.id = id
        self.home = try SafeAbsoluteDirectory.parse(home, label: "HOME")
        self.shell = shell
        self.validator = validator
        self.byobuConfigDir = byobuConfigDir
    }

    /// `FixRequest::from_environment` (fix.rs:87-100).
    public static func fromEnvironment(
        id: DiagnosticId,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> FixRequest {
        guard let home = environment["HOME"], !home.isEmpty else {
            throw FixError.homeUnavailable
        }
        let shell = environment["SHELL"]
        let validator = shell.flatMap { resolveValidatorProgram($0, environment: environment) }
        return try FixRequest(
            id: id,
            home: home,
            shell: shell,
            validator: validator,
            byobuConfigDir: environment["BYOBU_CONFIG_DIR"]
        )
    }
}

// MARK: - ShellKind (fix.rs:103-142)

public enum ShellKind: String, Sendable, Equatable, CaseIterable {
    case bash
    case zsh
    case fish

    /// `from_shell_path` (fix.rs:111-118).
    public static func fromShellPath(_ shell: String) -> ShellKind? {
        let name = (shell as NSString).lastPathComponent
        return ShellKind(rawValue: name)
    }

    public var name: String { rawValue }

    /// `config_path` (fix.rs:128-134).
    public func configPath(home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        switch self {
        case .bash: return base + "/.bashrc"
        case .zsh: return base + "/.zshrc"
        case .fish: return base + "/.config/fish/config.fish"
        }
    }

    /// `alias` (fix.rs:136-141) — bodies byte-exact.
    var alias: String {
        switch self {
        case .bash, .zsh: return sshWrapAliasPOSIX
        case .fish: return sshWrapAliasFish
        }
    }
}

// MARK: - Plan / outcome types (fix.rs:144-289)

/// `PlannedChange` (fix.rs:144-151).
public struct PlannedChange: Sendable, Equatable {
    public var requestedPath: String
    public var targetPath: String
    public var block: String
    public var backupPathHint: String?
    public var willWrite: Bool
}

/// `FixActivation` (fix.rs:153-157).
public enum FixActivation: Sendable, Equatable {
    case satisfiedNow
    case requiresReload
}

/// `FixPlan` (fix.rs:159-179).
public struct FixPlan: Sendable {
    public let id: DiagnosticId
    public let change: PlannedChange
    public let caveats: [String]
    let payload: FixPayload
}

enum FixPayload: Sendable {
    case sshWrap(SshWrapPlan)
    case tmuxOption(TmuxOptionPlan)
}

struct SshWrapPlan: Sendable {
    var shell: ShellKind
    var managed: ManagedConfigPlan
}

struct TmuxOptionPlan: Sendable {
    var spec: TmuxOptionSpec
    var managed: ManagedConfigPlan
    var directState: DirectOptionState
}

/// `FixStatus` (fix.rs:200-204).
public enum FixStatus: Sendable, Equatable {
    case applied
    case alreadyConfigured
}

/// `FixOutcome` (fix.rs:212-289).
public struct FixOutcome: Sendable {
    public let id: DiagnosticId
    public let status: FixStatus
    public let changedPath: String
    public let backupPath: String?
    public let activation: FixActivation
    /// Shell used to plan/apply SSH-wrap. Post-apply verification must use
    /// this rather than re-reading `$SHELL` (fix.rs:218-220).
    public let shell: ShellKind?

    /// `managed_alias_is_configured` (fix.rs:283-289): uses the planned
    /// shell, never the current `$SHELL`.
    public var managedAliasIsConfigured: Bool {
        guard let shell else { return false }
        return managedAliasConfigured(path: changedPath, shell: shell)
    }
}

// MARK: - FixError (fix.rs:291-377)

public enum FixError: Error, CustomStringConvertible {
    case unknownID(String)
    case platformUnsupported
    case homeUnavailable
    case notApplicable
    case tmuxNotApplicable
    case remoteSession
    case unsupportedShell
    case byobuConfigUnavailable
    case unsafeDirectory(label: String, path: String)
    case existingCustomization(path: String, detail: String)
    case managed(ManagedConfigError)
    case tmuxManaged(ManagedConfigError)
    case postconditionFailed
    case tmuxPostconditionFailed

    public var description: String {
        switch self {
        case .unknownID(let id):
            return "`\(id)` is not an available Doctor fix. Run `grok doctor fix` to list available fixes."
        case .platformUnsupported:
            return "Automatic SSH setup is not available on Windows. Run `\(sshWrapOneOff)` when needed."
        case .homeUnavailable:
            return "Grok could not find your home directory."
        case .notApplicable:
            return "This fix does not apply to VS Code Remote sessions."
        case .tmuxNotApplicable:
            return "This fix is not applicable to the current report."
        case .remoteSession:
            return "Run this fix on your local computer, not in the SSH session."
        case .unsupportedShell:
            return "Automatic setup supports Bash, zsh, and fish. For another shell, run `\(sshWrapOneOff)` when needed."
        case .byobuConfigUnavailable:
            return "Grok could not determine Byobu's effective config directory. Keep `BYOBU_CONFIG_DIR` set in this session, then run the fix again."
        case .unsafeDirectory(let label, let path):
            return "Grok refused unsafe \(label) `\(path)`. Use a non-root absolute directory without control characters, `~`, `.` or `..` components."
        case .existingCustomization(let path, let detail)
            where detail.hasPrefix("existing `alias ssh") || detail.contains("`ssh` fish function"):
            return "Grok found an existing SSH alias or function in \(path) and did not change it: \(detail)"
        case .existingCustomization(let path, let detail):
            return "Grok found an existing customization in \(path) and did not change it: \(detail)"
        case .managed(let error):
            return "Could not update your shell configuration: \(error)"
        case .tmuxManaged(let error):
            return "Could not update your tmux configuration: \(error)"
        case .postconditionFailed:
            return "The configuration changed, but Grok could not verify the SSH alias."
        case .tmuxPostconditionFailed:
            return "The configuration changed, but Grok could not verify the managed tmux option."
        }
    }
}

// MARK: - Registry (fix.rs:385-519)

public enum AutomaticFixAvailability: Sendable, Equatable {
    case here
    case runLocally
}

enum FixKind: Sendable {
    case sshWrap
    case tmuxOption(TmuxOptionSpec)
}

struct FixSpec: Sendable {
    var id: DiagnosticId
    var handle: String
    var label: String
    var command: String
    var kind: FixKind
}

enum TmuxEvidence: Sendable, Equatable {
    case clipboard
    case dcsPassthrough
    case extendedKeys
    case colorPassthrough
}

/// `TmuxRemedy` (fix.rs:416-425): assignment remedies must classify a
/// direct assignment elsewhere in the config before writing; accumulating
/// remedies append and earlier lines can never defeat them.
enum TmuxRemedy: Sendable, Equatable {
    case assignment
    case accumulating
}

struct TmuxOptionSpec: Sendable, Equatable {
    var id: DiagnosticId
    var option: String
    var line: String
    /// Values that already satisfy the fix; empty for accumulating remedies.
    var healthyValues: [String]
    var remedy: TmuxRemedy
    var evidence: TmuxEvidence
    var scope: TmuxOptionScope
    var label: String
}

let tmuxClipboardSpec = TmuxOptionSpec(
    id: tmuxClipboardID,
    option: "set-clipboard",
    line: "set -g set-clipboard on",
    healthyValues: ["on", "external"],
    remedy: .assignment,
    evidence: .clipboard,
    scope: .server,
    label: "Enable tmux clipboard forwarding"
)
let dcsPassthroughSpec = TmuxOptionSpec(
    id: dcsPassthroughID,
    option: "allow-passthrough",
    line: "set -wg allow-passthrough on",
    healthyValues: ["on", "all"],
    remedy: .assignment,
    evidence: .dcsPassthrough,
    scope: .window,
    label: "Enable tmux DCS passthrough"
)
let tmuxExtendedKeysSpec = TmuxOptionSpec(
    id: tmuxExtendedKeysID,
    option: "extended-keys",
    line: "set -g extended-keys on",
    healthyValues: ["on"],
    remedy: .assignment,
    evidence: .extendedKeys,
    scope: .server,
    label: "Enable tmux extended keys"
)
let tmuxTruecolorSpec = TmuxOptionSpec(
    id: tmuxTruecolorID,
    option: "terminal-features",
    line: "set -as terminal-features \",*:RGB\"",
    healthyValues: [],
    remedy: .accumulating,
    evidence: .colorPassthrough,
    scope: .server,
    label: "Enable tmux truecolor passthrough"
)

/// `FIX_REGISTRY` (fix.rs:483-519).
let fixRegistry: [FixSpec] = [
    FixSpec(id: sshWrapID, handle: "ssh-wrap", label: "Set up local SSH wrapping", command: sshWrapFixCommand, kind: .sshWrap),
    FixSpec(id: tmuxClipboardID, handle: "tmux-clipboard", label: tmuxClipboardSpec.label, command: "grok doctor fix terminal.tmux-clipboard", kind: .tmuxOption(tmuxClipboardSpec)),
    FixSpec(id: dcsPassthroughID, handle: "dcs-passthrough", label: dcsPassthroughSpec.label, command: "grok doctor fix terminal.dcs-passthrough", kind: .tmuxOption(dcsPassthroughSpec)),
    FixSpec(id: tmuxExtendedKeysID, handle: "tmux-extended-keys", label: tmuxExtendedKeysSpec.label, command: "grok doctor fix terminal.tmux-extended-keys", kind: .tmuxOption(tmuxExtendedKeysSpec)),
    FixSpec(id: tmuxTruecolorID, handle: "tmux-truecolor", label: tmuxTruecolorSpec.label, command: "grok doctor fix terminal.tmux-truecolor", kind: .tmuxOption(tmuxTruecolorSpec)),
]

func fixSpec(_ id: DiagnosticId) -> FixSpec? {
    fixRegistry.first { $0.id == id }
}

/// `resolve_fix_id` (fix.rs:525-531).
public func resolveFixID(_ value: String) throws -> DiagnosticId {
    guard let spec = fixRegistry.first(where: { value == $0.handle || value == $0.id.description }) else {
        throw FixError.unknownID(value)
    }
    return spec.id
}

/// `human_fix_command` (fix.rs:533-535).
public func humanFixCommand(_ id: DiagnosticId) -> String? {
    fixSpec(id).map { "grok doctor fix \($0.handle)" }
}

/// `automatic_fix_choices` (fix.rs:537-542).
public func automaticFixChoices() -> [(DiagnosticId, String, String)] {
    fixRegistry.map { ($0.id, $0.handle, $0.label) }
}

/// `automatic_remediation_for` (fix.rs:544-549).
public func automaticRemediationFor(_ id: DiagnosticId) -> AutomaticRemediation? {
    fixSpec(id).map { AutomaticRemediation(fixID: id, command: $0.command) }
}

/// `ssh_wrap_automatic_remediation` (fix.rs:551-553).
public func sshWrapAutomaticRemediation() -> AutomaticRemediation {
    // The registry always contains ssh-wrap; a missing entry is programmer error.
    automaticRemediationFor(sshWrapID)!
}

// MARK: - Selection / listing (fix.rs:555-623)

/// `select_fix_plan` (fix.rs:555-567).
public func selectFixPlan(
    id: DiagnosticId,
    report: DiagnosticReport,
    terminal: TerminalContext,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> FixPlan? {
    guard let spec = fixSpec(id) else { throw FixError.unknownID(id.description) }
    if case .sshWrap = spec.kind,
       terminal.isSSH || terminal.isOfficialVSCodeRemote || report.facts.ssh {
        return nil
    }
    return try planFix(
        try FixRequest.fromEnvironment(id: id, environment: environment),
        report: report,
        terminal: terminal
    )
}

/// `applicable_automatic_fixes_with` (fix.rs:576-598).
func applicableAutomaticFixes(
    report: DiagnosticReport,
    terminal: TerminalContext,
    requestFor: (DiagnosticId) throws -> FixRequest
) -> [(DiagnosticId, String, AutomaticFixAvailability)] {
    report.findings.compactMap { finding -> (DiagnosticId, String, AutomaticFixAvailability)? in
        guard let automatic = finding.automaticRemediation,
              let spec = fixSpec(automatic.fixID) else { return nil }
        let availability: AutomaticFixAvailability
        if case .sshWrap = spec.kind,
           terminal.isSSH || terminal.isOfficialVSCodeRemote || report.facts.ssh {
            availability = .runLocally
        } else {
            guard let request = try? requestFor(automatic.fixID),
                  (try? planFix(request, report: report, terminal: terminal)) != nil else {
                return nil
            }
            availability = .here
        }
        return (automatic.fixID, spec.handle, availability)
    }
}

/// `applicable_automatic_fixes` (fix.rs:569-574).
public func applicableAutomaticFixes(
    report: DiagnosticReport,
    terminal: TerminalContext,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [(DiagnosticId, String, AutomaticFixAvailability)] {
    applicableAutomaticFixes(report: report, terminal: terminal) { id in
        try FixRequest.fromEnvironment(id: id, environment: environment)
    }
}

/// `format_applicable_automatic_fixes` (fix.rs:600-623).
public func formatApplicableAutomaticFixes(
    report: DiagnosticReport,
    terminal: TerminalContext,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    let fixes = applicableAutomaticFixes(report: report, terminal: terminal, environment: environment)
    if fixes.isEmpty {
        return "No automatic fixes are available here.\n"
    }
    var output = "Automatic fixes:\n"
    for (id, handle, availability) in fixes {
        let label = fixSpec(id)?.label ?? "Apply automatic fix"
        let paddedHandle = handle.count < 20
            ? handle + String(repeating: " ", count: 20 - handle.count)
            : handle
        output += "  \(paddedHandle) \(label)\n"
        switch availability {
        case .here:
            output += "    Run: grok doctor fix \(handle)\n    In Grok: /doctor fix \(handle)\n"
        case .runLocally:
            output += "    On your local computer, run: grok doctor fix \(handle)\n"
        }
    }
    return output
}

// MARK: - Preview (fix.rs:625-682)

/// `format_fix_preview` (fix.rs:625-682).
public func formatFixPreview(_ plan: FixPlan) -> String {
    var output = "Doctor Fix\n\n"
    output += "Fix: \(plan.id)\n"
    if case .sshWrap(let payload) = plan.payload {
        output += "Shell: \(payload.shell.name)\n"
    }
    let change = plan.change
    output += "File: \(previewPath(change.requestedPath))\n"
    if change.targetPath != change.requestedPath {
        output += "Actual file: \(previewPath(change.targetPath)) (symlink target)\n"
    }
    if change.willWrite {
        output += "\nText to add:\n\(change.block)\n"
    } else {
        output += "\nText to add: None. The requested setting is already configured.\n"
    }
    if let backup = change.backupPathHint {
        output += "\nBackup will be saved to: \(previewPath(backup))\nIf that file exists, Grok will choose a unique name.\n"
    } else {
        output += "\nBackup: None. The file is new or no changes are needed.\n"
    }
    switch plan.payload {
    case .sshWrap:
        output += "\nWhat this changes:\n  In new interactive shells, `ssh ...` runs as `open-grok wrap ssh ...`.\n"
        output += "  To use once without changing config: `\(sshWrapOneOff)`.\n"
    case .tmuxOption(let payload):
        let instruction = tmuxActivationInstruction(payload.spec, path: plan.change.requestedPath)
        output += "\nWhat this changes:\n  Persists `\(payload.spec.line)`.\n  Grok does not reload or modify the live tmux server.\n  After applying, \(instruction)\n  Run /doctor again to verify the live setting.\n"
    }
    output += "Caveats:\n"
    for caveat in plan.caveats {
        output += "  - \(caveat)\n"
    }
    return output
}

// MARK: - Planning (fix.rs:684-859)

/// `plan_fix` (fix.rs:684-694).
public func planFix(
    _ request: FixRequest,
    report: DiagnosticReport,
    terminal: TerminalContext
) throws -> FixPlan {
    guard let spec = fixSpec(request.id) else { throw FixError.unknownID(request.id.description) }
    switch spec.kind {
    case .sshWrap:
        return try planSshWrap(request, report: report, terminal: terminal)
    case .tmuxOption(let tmux):
        return try planTmuxOption(request, report: report, terminal: terminal, spec: tmux)
    }
}

/// `plan_ssh_wrap` (fix.rs:696-743). SSH-wrap is refused on SSH/remote
/// sessions (fix.rs:707-709): the alias must land on the LOCAL machine.
private func planSshWrap(
    _ request: FixRequest,
    report: DiagnosticReport,
    terminal: TerminalContext
) throws -> FixPlan {
    #if os(Windows)
    throw FixError.platformUnsupported
    #else
    if terminal.isOfficialVSCodeRemote {
        throw FixError.notApplicable
    }
    if terminal.isSSH || report.facts.ssh {
        throw FixError.remoteSession
    }

    guard let shellPath = request.shell, let shell = ShellKind.fromShellPath(shellPath) else {
        throw FixError.unsupportedShell
    }
    let managed: ManagedConfigPlan
    do {
        managed = try ManagedConfig.plan(ManagedConfigRequest(
            path: shell.configPath(home: request.home.path),
            namespace: managedNamespace,
            ownedItemPrefix: "terminal.",
            items: [ManagedItem(name: request.id.description, body: shell.alias)],
            comments: .hash,
            validator: validatorFor(shell, overridePath: request.validator)
        ))
    } catch let error as ManagedConfigError {
        throw FixError.managed(error)
    }
    if let detail = detectSSHCustomization(managed.inspection.unmanagedText, shell: shell) {
        throw FixError.existingCustomization(path: managed.targetPath, detail: detail)
    }
    let change = try plannedChange(managed, missingBlock: FixError.postconditionFailed)
    return FixPlan(
        id: request.id,
        change: change,
        caveats: [
            "The alias loads only in new interactive shells.",
            "Use `command ssh ...` to bypass the alias.",
            "For manually entered `ssh -f`, ControlPersist workflows, or OpenSSH `~^Z` local suspend, use `command ssh ...`. Wrapping does not fully preserve those behaviors.",
            "`grok wrap` starts the SSH process directly, so the alias does not loop.",
            "Grok checks this file for direct SSH aliases and functions. Review sourced files, plugins, and generated shell setup yourself.",
        ],
        payload: .sshWrap(SshWrapPlan(shell: shell, managed: managed))
    )
    #endif
}

/// `plan_tmux_option` (fix.rs:745-804).
private func planTmuxOption(
    _ request: FixRequest,
    report: DiagnosticReport,
    terminal: TerminalContext,
    spec: TmuxOptionSpec
) throws -> FixPlan {
    if !terminal.isTmuxBacked
        || terminal.byobu == .screen
        || report.facts.multiplexer != .tmux
        || !report.findings.contains(where: { $0.id == spec.id })
        || !tmuxEvidenceIsApplicable(report: report, spec: spec) {
        throw FixError.tmuxNotApplicable
    }
    let managed: ManagedConfigPlan
    do {
        managed = try ManagedConfig.plan(ManagedConfigRequest(
            path: try tmuxConfigPath(request: request, terminal: terminal),
            namespace: managedNamespace,
            ownedItemPrefix: "terminal.",
            items: [ManagedItem(name: spec.id.description, body: spec.line)],
            comments: .hash,
            validator: nil
        ))
    } catch let error as ManagedConfigError {
        throw FixError.tmuxManaged(error)
    }
    let direct: DirectOptionState
    switch spec.remedy {
    case .assignment:
        direct = try scanDirectTmuxOption(
            text: managed.inspection.unmanagedText,
            path: managed.targetPath,
            spec: spec
        )
    case .accumulating:
        direct = .absent
    }
    guard let itemState = managed.inspection.requestedItemState(0) else {
        throw FixError.tmuxPostconditionFailed
    }
    let directNoop = direct == .healthy && (itemState == .absent || itemState == .exact)
    var change = try plannedChange(managed, missingBlock: FixError.tmuxPostconditionFailed)
    if directNoop {
        change.willWrite = false
        change.backupPathHint = nil
    }
    return FixPlan(
        id: request.id,
        change: change,
        caveats: tmuxCaveats(spec.remedy),
        payload: .tmuxOption(TmuxOptionPlan(
            spec: spec,
            managed: managed,
            directState: directNoop ? .healthy : .absent
        ))
    )
}

/// `tmux_caveats` (fix.rs:806-819).
private func tmuxCaveats(_ remedy: TmuxRemedy) -> [String] {
    switch remedy {
    case .assignment:
        return [
            "The live tmux server is unchanged until you reload this config or restart it.",
            tmuxScannerCaveat,
        ]
    case .accumulating:
        // Reloading is not enough on its own: tmux fixes a client's feature
        // set when that client attaches.
        return [
            "Reloading alone is not enough: the attached client keeps its current color depth until it reattaches.",
            "Terminals that cannot render 24-bit color ignore the extra escape sequence.",
        ]
    }
}

/// `tmux_evidence_is_applicable` (fix.rs:821-844).
func tmuxEvidenceIsApplicable(report: DiagnosticReport, spec: TmuxOptionSpec) -> Bool {
    switch spec.evidence {
    case .colorPassthrough:
        return report.facts.tmux.colorPassthrough == .reduced
    case .clipboard:
        if case .available(let value) = report.facts.tmux.setClipboard {
            return !spec.healthyValues.contains(value)
        }
        return false
    case .dcsPassthrough:
        guard report.facts.tmux.allowPassthroughSupport == .supported,
              case .available(let value) = report.facts.tmux.allowPassthrough else {
            return false
        }
        return !spec.healthyValues.contains(value)
    case .extendedKeys:
        if case .available(let value) = report.facts.tmux.extendedKeys {
            return value == "off"
        }
        return false
    }
}

/// `tmux_config_path` (fix.rs:846-859): Byobu's config dir goes through the
/// same fail-closed directory guard as HOME.
private func tmuxConfigPath(request: FixRequest, terminal: TerminalContext) throws -> String {
    if terminal.byobu != .tmux {
        return request.home.join(".tmux.conf")
    }
    guard let byobuDir = request.byobuConfigDir else {
        throw FixError.byobuConfigUnavailable
    }
    return try SafeAbsoluteDirectory.parse(byobuDir, label: "BYOBU_CONFIG_DIR").join(".tmux.conf")
}

/// `planned_change_with_error` (fix.rs:869-880).
private func plannedChange(_ managed: ManagedConfigPlan, missingBlock: FixError) throws -> PlannedChange {
    guard let block = managed.managedBlock else { throw missingBlock }
    return PlannedChange(
        requestedPath: managed.requestedPath,
        targetPath: managed.targetPath,
        block: block,
        backupPathHint: managed.backupPathHint,
        willWrite: managed.changesFile
    )
}

// MARK: - Apply (fix.rs:882-948)

/// `apply_fix` (fix.rs:882-928). Both arms verify the postcondition ON THE
/// REAL FILE after the write; a discarded verification here is exactly the
/// silent-success failure mode this port exists to avoid (AGENTS.md §3).
public func applyFix(_ plan: FixPlan) throws -> FixOutcome {
    let id = plan.id
    switch plan.payload {
    case .sshWrap(let payload):
        let shell = payload.shell
        let outcome: ManagedConfigOutcome
        do {
            outcome = try ManagedConfig.apply(payload.managed)
        } catch let error as ManagedConfigError {
            throw FixError.managed(error)
        }
        if !managedAliasConfigured(path: outcome.targetPath, shell: shell) {
            throw FixError.postconditionFailed
        }
        return fixOutcome(id, outcome: outcome, activation: .satisfiedNow, shell: shell)
    case .tmuxOption(let payload):
        if payload.directState == .healthy {
            do {
                try ManagedConfig.verifyUnchanged(payload.managed)
            } catch let error as ManagedConfigError {
                throw FixError.tmuxManaged(error)
            }
            let path = payload.managed.requestedPath
            if !tmuxOptionConfigured(path: path, spec: payload.spec) {
                throw FixError.tmuxPostconditionFailed
            }
            return FixOutcome(
                id: id,
                status: .alreadyConfigured,
                changedPath: path,
                backupPath: nil,
                activation: .requiresReload,
                shell: nil
            )
        }
        let outcome: ManagedConfigOutcome
        do {
            outcome = try ManagedConfig.apply(payload.managed)
        } catch let error as ManagedConfigError {
            throw FixError.tmuxManaged(error)
        }
        if !tmuxOptionConfigured(path: outcome.targetPath, spec: payload.spec) {
            throw FixError.tmuxPostconditionFailed
        }
        return fixOutcome(id, outcome: outcome, activation: .requiresReload, shell: nil)
    }
}

/// `fix_outcome` (fix.rs:930-949).
private func fixOutcome(
    _ id: DiagnosticId,
    outcome: ManagedConfigOutcome,
    activation: FixActivation,
    shell: ShellKind?
) -> FixOutcome {
    FixOutcome(
        id: id,
        status: outcome.status == .applied ? .applied : .alreadyConfigured,
        changedPath: outcome.requestedPath,
        backupPath: outcome.backupPath,
        activation: activation,
        shell: shell
    )
}

/// `format_fix_success` (fix.rs:951-983).
public func formatFixSuccess(_ outcome: FixOutcome) -> String {
    let path = markdownCodePath(outcome.changedPath)
    guard let kind = fixSpec(outcome.id)?.kind else {
        return "Applied the Doctor fix."
    }
    let status: String
    switch (kind, outcome.status) {
    case (.sshWrap, .applied):
        status = "Set up SSH wrapping in \(path)."
    case (.sshWrap, .alreadyConfigured):
        status = "SSH wrapping is already set up in \(path)."
    case (.tmuxOption(let tmux), .applied):
        status = "Added `\(tmux.line)` to \(path)."
    case (.tmuxOption(let tmux), .alreadyConfigured):
        status = "`\(tmux.line)` is already configured in \(path)."
    }
    let backup = outcome.backupPath.map { "\nBackup: \($0)" } ?? ""
    let activation: String
    switch (kind, outcome.activation) {
    case (.sshWrap, .satisfiedNow):
        activation = "\nStart a new shell to use the alias."
    case (.tmuxOption(let tmux), .requiresReload):
        activation = "\n\(tmuxActivationInstruction(tmux, path: outcome.changedPath))\nRun /doctor again to verify the live setting."
    default:
        activation = ""
    }
    return "\(status)\(backup)\(activation)"
}

/// `verify_persistent_fix` (fix.rs:985-993).
public func verifyPersistentFix(_ outcome: FixOutcome) -> Bool {
    guard let spec = fixSpec(outcome.id) else { return false }
    switch spec.kind {
    case .sshWrap:
        return false
    case .tmuxOption(let tmux):
        return tmuxOptionConfigured(path: outcome.changedPath, spec: tmux)
    }
}

// MARK: - Path rendering (fix.rs:995-1058)

/// `preview_path` (fix.rs:995-1000).
func previewPath(_ path: String) -> String {
    let hasControl = path.unicodeScalars.contains {
        $0.value < 0x20 || ($0.value >= 0x7F && $0.value <= 0x9F)
    }
    if hasControl {
        return "[path cannot be rendered safely]"
    }
    return commonmarkCodeSpan(path)
}

/// `markdown_code_path` (fix.rs:1002-1006).
func markdownCodePath(_ path: String) -> String {
    commonmarkCodeSpan(path)
}

/// `commonmark_code_span` (fix.rs:1008-1017): the fence is one longer than
/// the longest run of CONSECUTIVE BACKTICKS inside the value — not the
/// longest backtick-free segment. Splitting on "`" and measuring the pieces
/// (the prior bug) sized the fence to the surrounding text, so a single
/// backtick in a path produced a 7-backtick fence instead of 2.
func commonmarkCodeSpan(_ value: String) -> String {
    var longestBacktickRun = 0
    var current = 0
    for character in value {
        if character == "`" {
            current += 1
            longestBacktickRun = max(longestBacktickRun, current)
        } else {
            current = 0
        }
    }
    let delimiter = String(repeating: "`", count: longestBacktickRun + 1)
    return "\(delimiter)\(value)\(delimiter)"
}

/// `shell_quote_path` (fix.rs:1019-1028).
func shellQuotePath(_ path: String) -> String? {
    if path.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0.value == 0 }) {
        return nil
    }
    return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
}

/// `tmux_activation_instruction` (fix.rs:1033-1047).
func tmuxActivationInstruction(_ spec: TmuxOptionSpec, path: String) -> String {
    switch spec.remedy {
    case .assignment:
        return reloadInstruction(path)
    case .accumulating:
        guard let shellPath = shellQuotePath(path) else {
            return "Reload your tmux config, then detach and reattach: only clients that attach after the reload get 24-bit color."
        }
        return "Run \(commonmarkCodeSpan("tmux source-file \(shellPath)")), then detach and reattach: only clients that attach after the reload get 24-bit color."
    }
}

/// `reload_instruction` (fix.rs:1049-1058).
func reloadInstruction(_ path: String) -> String {
    guard let shellPath = shellQuotePath(path) else {
        return "Reload your tmux config, or restart the tmux server, to activate the persistent setting."
    }
    return "Reload tmux with \(commonmarkCodeSpan("tmux source-file \(shellPath)")), or restart the tmux server."
}

// MARK: - Configured checks (fix.rs:1060-1096)

/// `managed_alias_configured` (fix.rs:1060-1073).
public func managedAliasConfigured(path: String, shell: ShellKind) -> Bool {
    let request = ManagedConfigRequest(
        path: path,
        namespace: managedNamespace,
        ownedItemPrefix: "terminal.",
        items: [ManagedItem(name: sshWrapID.description, body: shell.alias)],
        comments: .hash,
        validator: nil
    )
    guard let plan = try? ManagedConfig.plan(request) else { return false }
    return !plan.changesFile && detectSSHCustomization(plan.inspection.unmanagedText, shell: shell) == nil
}

/// `tmux_option_configured` (fix.rs:1075-1096).
func tmuxOptionConfigured(path: String, spec: TmuxOptionSpec) -> Bool {
    let request = ManagedConfigRequest(
        path: path,
        namespace: managedNamespace,
        ownedItemPrefix: "terminal.",
        items: [ManagedItem(name: spec.id.description, body: spec.line)],
        comments: .hash,
        validator: nil
    )
    guard let plan = try? ManagedConfig.plan(request) else { return false }
    switch spec.remedy {
    case .accumulating:
        return !plan.changesFile
    case .assignment:
        let direct = try? scanDirectTmuxOption(
            text: plan.inspection.unmanagedText,
            path: plan.targetPath,
            spec: spec
        )
        if direct == .healthy { return true }
        return !plan.changesFile && direct == .absent
    }
}

// MARK: - tmux config scanner (fix.rs:1098-1448)

enum DirectOptionState: Sendable, Equatable {
    case absent
    case healthy
}

enum TmuxOptionScope: Sendable, Equatable {
    case server
    case window
}

private struct TmuxCommandToken {
    var value: String
    var quoted: Bool
}

/// `scan_direct_tmux_option` (fix.rs:1116-1141).
func scanDirectTmuxOption(
    text: String,
    path: String,
    spec: TmuxOptionSpec
) throws -> DirectOptionState {
    let commands = try tmuxTopLevelCommands(text: text, path: path, spec: spec)
    var sawHealthy = false
    for command in commands {
        let tokens = try tokenizeTmuxCommand(command, path: path, spec: spec)
        if tokens.isEmpty { continue }
        switch classifyTmuxAssignment(tokens: tokens, spec: spec) {
        case .notTarget:
            break
        case .healthy:
            sawHealthy = true
        case .conflict(let detail), .ambiguous(let detail):
            throw tmuxCustomizationError(path: path, spec: spec, detail: detail)
        }
    }
    return sawHealthy ? .healthy : .absent
}

/// `tmux_top_level_commands` (fix.rs:1143-1247). Iterates unicode scalars
/// (Rust `chars()`): a CRLF config yields `\r` inside command text, and
/// `\r` counts as token whitespace downstream — Swift `Character` would
/// fuse `\r\n` into one grapheme and change the parse (AGENTS.md §2).
private func tmuxTopLevelCommands(
    text: String,
    path: String,
    spec: TmuxOptionSpec
) throws -> [String] {
    var commands: [String] = []
    var current = ""
    var quote: Unicode.Scalar?
    var escaped = false
    var conditionalDepth = 0
    var braceDepth = 0
    var lineStart = true
    let scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if escaped {
            if scalar == "\n" {
                // tmux removes escaped newlines exactly; no space inserted.
            } else {
                current.unicodeScalars.append(scalar)
            }
            escaped = false
            lineStart = scalar == "\n"
            index += 1
            continue
        }
        if scalar == "\\" && quote != "'" {
            escaped = true
            index += 1
            continue
        }
        if let activeQuote = quote {
            current.unicodeScalars.append(scalar)
            if scalar == activeQuote {
                quote = nil
            }
            lineStart = scalar == "\n"
            index += 1
            continue
        }
        if scalar == "'" || scalar == "\"" {
            quote = scalar
            current.unicodeScalars.append(scalar)
            lineStart = false
            index += 1
            continue
        }
        if scalar == "#" {
            let lastIsWhitespace = current.unicodeScalars.last
                .map { Character($0).isWhitespace } ?? false
            if lineStart || lastIsWhitespace {
                while index < scalars.count && scalars[index] != "\n" {
                    index += 1
                }
                continue
            }
        }
        if lineStart && scalar == "%" {
            var directive = ""
            var probe = index
            while probe < scalars.count && scalars[probe] != "\n" {
                directive.unicodeScalars.append(scalars[probe])
                probe += 1
            }
            let trimmed = directive.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%if") {
                conditionalDepth += 1
            } else if trimmed.hasPrefix("%endif") {
                conditionalDepth = conditionalDepth > 0 ? conditionalDepth - 1 : 0
            }
            index = probe
            lineStart = true
            continue
        }
        if scalar == "{" {
            braceDepth += 1
        } else if scalar == "}" {
            braceDepth = braceDepth > 0 ? braceDepth - 1 : 0
        }
        if scalar == ";" || scalar == "\n" {
            if conditionalDepth == 0 && braceDepth == 0
                && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commands.append(current)
            }
            current = ""
            lineStart = true
        } else {
            current.unicodeScalars.append(scalar)
            lineStart = false
        }
        index += 1
    }
    if (escaped || quote != nil || conditionalDepth != 0 || braceDepth != 0)
        && text.contains(spec.option) {
        throw tmuxCustomizationError(path: path, spec: spec, detail: "unterminated or ambiguous tmux syntax")
    }
    if conditionalDepth == 0 && braceDepth == 0
        && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        commands.append(current)
    }
    return commands
}

/// `tokenize_tmux_command` (fix.rs:1249-1302), byte-level like upstream.
private func tokenizeTmuxCommand(
    _ command: String,
    path: String,
    spec: TmuxOptionSpec
) throws -> [TmuxCommandToken] {
    let bytes = Array(command.utf8)
    var tokens: [TmuxCommandToken] = []
    var index = 0
    func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x0B
    }
    while index < bytes.count {
        while index < bytes.count && isASCIIWhitespace(bytes[index]) {
            index += 1
        }
        if index == bytes.count { return tokens }
        let start = index
        var quote: UInt8?
        var quoted = false
        while index < bytes.count {
            let byte = bytes[index]
            if let active = quote {
                if byte == active {
                    quote = nil
                }
                index += 1
                continue
            }
            if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") {
                quote = byte
                quoted = true
                index += 1
                continue
            }
            if isASCIIWhitespace(byte) {
                break
            }
            index += 1
        }
        if quote != nil {
            throw tmuxCustomizationError(path: path, spec: spec, detail: "unterminated quoted tmux token")
        }
        let raw = String(decoding: bytes[start..<index], as: UTF8.self)
        var value = raw
        if let first = value.first, first == "'" || first == "\"" {
            let stripped = String(value.dropFirst())
            if let last = stripped.last, last == "'" || last == "\"" {
                value = String(stripped.dropLast())
            }
        }
        tokens.append(TmuxCommandToken(value: value, quoted: quoted))
    }
    return tokens
}

private enum TmuxAssignment {
    case notTarget
    case healthy
    case conflict(String)
    case ambiguous(String)
}

/// `classify_tmux_assignment` (fix.rs:1311-1433).
private func classifyTmuxAssignment(
    tokens: [TmuxCommandToken],
    spec: TmuxOptionSpec
) -> TmuxAssignment {
    var index = 0
    while index < tokens.count,
          !tokens[index].quoted,
          tokens[index].value.contains("="),
          !tokens[index].value.hasPrefix("-") {
        index += 1
    }
    guard index < tokens.count else { return .notTarget }
    let command = tokens[index]
    if command.quoted { return .notTarget }
    let commandScope: TmuxOptionScope?
    switch command.value {
    case "set", "set-option", "seto":
        commandScope = nil
    case "setw", "set-window-option":
        commandScope = .window
    case let value where "set-option".hasPrefix(value) || "set".hasPrefix(value) || "set-window-option".hasPrefix(value):
        if commandMayTarget(tokens: tokens, spec: spec) {
            return .ambiguous("ambiguous tmux command prefix `\(value)` may target `\(spec.option)`")
        }
        return .notTarget
    default:
        return .notTarget
    }
    index += 1
    var explicitScope = commandScope
    var isGlobal = false
    var hasTarget = false
    while index < tokens.count {
        let token = tokens[index]
        if token.quoted || !token.value.hasPrefix("-") || token.value == "-" {
            break
        }
        if token.value == "--" {
            index += 1
            break
        }
        let flags = String(token.value.dropFirst())
        if flags.contains("g") { isGlobal = true }
        if flags.contains("s") { explicitScope = .server }
        if flags.contains("w") || flags.contains("p") { explicitScope = .window }
        if flags.contains("t") {
            hasTarget = true
            index += 1
            if index >= tokens.count {
                return .ambiguous("missing tmux target argument")
            }
        }
        // -F, -f, -t and similar flags take one following argument. Unknown
        // flags on a possible target fail closed instead of shifting tokens.
        if flags.contains("F") || flags.contains("f") {
            index += 1
            if index >= tokens.count {
                return .ambiguous("missing tmux flag argument")
            }
        }
        index += 1
    }
    guard index < tokens.count else { return .notTarget }
    let option = tokens[index]
    if option.quoted || option.value.hasPrefix("@") { return .notTarget }
    if option.value != spec.option {
        if spec.option.hasPrefix(option.value) {
            return .ambiguous("option prefix `\(option.value)` may target `\(spec.option)`")
        }
        return .notTarget
    }

    let effectiveScope = explicitScope ?? spec.scope
    switch spec.scope {
    case .server:
        // tmux resolves known server options by option scope even when a
        // window flag is supplied. A target is nonsensical/ambiguous here.
        if hasTarget {
            return .ambiguous("targeted server assignment may affect `\(spec.option)`")
        }
    case .window:
        // Only the global window value is persistent for future windows.
        if effectiveScope != .window || !isGlobal || hasTarget {
            return .notTarget
        }
    }
    if tokens.count != index + 2 || tokens[index + 1].quoted {
        return .ambiguous("ambiguous direct assignment of `\(spec.option)`")
    }
    let value = tokens[index + 1].value
    if spec.healthyValues.contains(value) {
        return .healthy
    }
    return .conflict("direct `\(spec.option) \(value)` conflicts with `\(spec.line)`")
}

/// `command_may_target` (fix.rs:1435-1441).
private func commandMayTarget(tokens: [TmuxCommandToken], spec: TmuxOptionSpec) -> Bool {
    tokens.dropFirst().contains { token in
        !token.quoted
            && !token.value.hasPrefix("@")
            && (token.value == spec.option || spec.option.hasPrefix(token.value))
    }
}

/// `tmux_customization_error` (fix.rs:1443-1448).
private func tmuxCustomizationError(path: String, spec: TmuxOptionSpec, detail: String) -> FixError {
    .existingCustomization(path: path, detail: "\(detail) for `\(spec.option)`")
}

// MARK: - Validator resolution (fix.rs:1450-1491)

/// `validator_for` (fix.rs:1450-1457).
private func validatorFor(_ shell: ShellKind, overridePath: String?) -> SyntaxValidator? {
    guard let program = overridePath else { return nil }
    return SyntaxValidator(program: program, args: ["-n"], timeout: 2)
}

/// `resolve_validator_program` (fix.rs:1459-1465).
func resolveValidatorProgram(_ shell: String, environment: [String: String]) -> String? {
    guard let kind = ShellKind.fromShellPath(shell) else { return nil }
    if shell.contains("/") {
        return executableFile(shell) ? shell : nil
    }
    return findOnPath(kind.name, environment: environment)
}

/// `find_on_path` (fix.rs:1467-1469).
func findOnPath(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard let path = environment["PATH"] else { return nil }
    return findOnPathIn(name, directories: path.split(separator: ":").map(String.init))
}

/// `find_on_path_in` (fix.rs:1471-1479).
func findOnPathIn(_ name: String, directories: [String]) -> String? {
    for directory in directories {
        let candidate = directory.hasSuffix("/") ? directory + name : directory + "/" + name
        if executableFile(candidate) {
            return candidate
        }
    }
    return nil
}

/// `executable_file` (fix.rs:1481-1486): regular file with any execute bit.
func executableFile(_ path: String) -> Bool {
    var status = stat()
    guard stat(path, &status) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFREG && (status.st_mode & 0o111) != 0
}

// MARK: - Existing-customization scanners (fix.rs:1493-1581)

/// `detect_ssh_customization` (fix.rs:1493-1498).
func detectSSHCustomization(_ text: String, shell: ShellKind) -> String? {
    switch shell {
    case .bash, .zsh: return detectPOSIXSSHCustomization(text)
    case .fish: return detectFishSSHCustomization(text)
    }
}

/// Line iteration matching Rust `str::lines()`: split on `\n`, drop one
/// trailing `\r` (CRLF-aware — AGENTS.md §2).
private func rustLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if text.hasSuffix("\n") { lines.removeLast() }
    return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
}

/// `detect_posix_ssh_customization` (fix.rs:1500-1514).
func detectPOSIXSSHCustomization(_ text: String) -> String? {
    for line in rustLines(text) {
        let trimmed = String(line.drop(while: { $0.isWhitespace }))
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        if isPOSIXSSHAliasDeclaration(trimmed) {
            return "existing `alias ssh=...`"
        }
        if isPOSIXSSHFunctionDeclaration(trimmed) {
            return "existing `ssh` shell function"
        }
    }
    return nil
}

/// `is_posix_ssh_alias_declaration` (fix.rs:1516-1525).
private func isPOSIXSSHAliasDeclaration(_ line: String) -> Bool {
    guard let rest = afterShellKeyword(line, keyword: "alias"),
          rest.hasPrefix("ssh") else {
        return false
    }
    let afterName = String(rest.dropFirst("ssh".count))
    if afterName.hasPrefix("=") { return true }
    guard let first = afterName.first, first.isWhitespace else { return false }
    return afterName.drop(while: { $0.isWhitespace }).hasPrefix("=")
}

/// `is_posix_ssh_function_declaration` (fix.rs:1527-1539).
private func isPOSIXSSHFunctionDeclaration(_ line: String) -> Bool {
    if let rest = afterShellKeyword(line, keyword: "function"), tokenIsExactName(rest, name: "ssh") {
        return true
    }
    guard line.hasPrefix("ssh") else { return false }
    let afterName = String(line.dropFirst("ssh".count).drop(while: { $0.isWhitespace }))
    if afterName.hasPrefix("()") { return true }
    if afterName.hasPrefix("(") {
        return afterName.dropFirst().drop(while: { $0.isWhitespace }).hasPrefix(")")
    }
    return false
}

/// `token_is_exact_name` (fix.rs:1541-1550).
private func tokenIsExactName(_ text: String, name: String) -> Bool {
    guard text.hasPrefix(name) else { return false }
    let rest = text.dropFirst(name.count)
    if rest.isEmpty { return true }
    guard let first = rest.first else { return true }
    return first.isWhitespace || first == "(" || first == "{"
}

/// `after_shell_keyword` (fix.rs:1552-1558).
private func afterShellKeyword(_ line: String, keyword: String) -> String? {
    guard line.hasPrefix(keyword) else { return nil }
    let rest = line.dropFirst(keyword.count)
    guard let first = rest.first, first.isWhitespace else { return nil }
    return String(rest.drop(while: { $0.isWhitespace }))
}

/// `detect_fish_ssh_customization` (fix.rs:1560-1581).
func detectFishSSHCustomization(_ text: String) -> String? {
    for line in rustLines(text) {
        let trimmed = String(line.drop(while: { $0.isWhitespace }))
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        if let rest = afterShellKeyword(trimmed, keyword: "alias") {
            if tokenIsExactName(rest, name: "ssh") { return "existing `alias ssh ...`" }
            if rest.hasPrefix("ssh"), rest.dropFirst("ssh".count).hasPrefix("=") {
                return "existing `alias ssh ...`"
            }
        }
        if let rest = afterShellKeyword(trimmed, keyword: "function"), tokenIsExactName(rest, name: "ssh") {
            return "existing `ssh` fish function"
        }
    }
    return nil
}

// MARK: - Report projection (fix.rs:1588-1593)

/// `configured_report` (fix.rs:1588-1593): once the managed alias is
/// verified configured, drop the ssh-wrap recommendation.
public func configuredReport(_ report: DiagnosticReport, configured: Bool) -> DiagnosticReport {
    var report = report
    if configured {
        report.findings.removeAll { $0.id == sshWrapID }
    }
    return report
}
