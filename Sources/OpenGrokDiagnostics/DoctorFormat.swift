// DoctorFormat.swift
//
// In-TUI `/doctor` report formatting.
//
// Byte-faithful port of `xai-grok-pager/src/diagnostics/doctor_format.rs`
// (208 lines) at reference 650c1db7. Golden tests pin whole outputs; do not
// reword any literal here without updating the goldens and upstream parity.

import Foundation

/// `format_doctor` (doctor_format.rs:9-140).
public func formatDoctor(_ report: DiagnosticReport) -> String {
    let facts = report.facts
    var out = ""
    out += "Environment\n"
    out += "  terminal     \(facts.terminal)\n"
    if case .available(let xtversion) = facts.xtversion {
        out += "  xtversion    \(xtversion)\n"
    }
    out += "  multiplexer  \(facts.multiplexer)\n"
    if let byobu = facts.byobu {
        out += "  byobu        \(byobu)\n"
    }
    out += "  ssh          \(facts.ssh ? "yes" : "no")\n"
    let colorLevel: ColorLevel?
    switch facts.color.level {
    case .available(let level): colorLevel = level
    case .noReply, .unavailable: colorLevel = nil
    }
    if let colorLevel {
        out += "  color        \(colorLevel.canonicalName)\n"
    }
    if colorLevel != nil && facts.color.availableThemes.count == facts.color.totalThemes {
        out += "  themes       all\n"
    } else if colorLevel != nil {
        let themes = facts.color.availableThemes.map(\.displayName).joined(separator: ", ")
        out += "  themes       \(facts.color.availableThemes.count)/\(facts.color.totalThemes): \(themes)\n"
    }
    if let keyboard = facts.keyboard {
        let rescue = keyboard.os == .macos
            ? "OS rescue active"
            : "OS rescue unavailable on this platform"
        out += "  keyboard     \(keyboard.modifierDelivery.label) (\(rescue))\n"
    }
    if let newline = facts.newline {
        let detail: String
        switch newline {
        case .vte(.some(let version)):
            detail = "VTE \(version); need >= 8200 for Shift+Enter"
        case .vte(.none):
            detail = "legacy VTE; need VTE >= 0.82 for Shift+Enter"
        case .xtermJs(let terminal):
            detail = "\(terminal): xterm.js can't distinguish Shift+Enter"
        case .noKittyKeyboardProtocol:
            detail = "no Kitty keyboard protocol; Shift+Enter == Enter"
        }
        out += "  newline      Alt+Enter (\(detail))\n"
    }

    let clipboard = facts.clipboard
    let native: String
    switch clipboard.nativePreflight {
    case .localAvailable:
        native = "local (\(clipboard.nativeTool))"
    case .remoteOnly where clipboard.containerNoDisplay:
        native = "container (\(clipboard.nativeTool))"
    case .remoteOnly:
        native = "remote (\(clipboard.nativeTool))"
    case .unavailable:
        native = "unavailable"
    case .disabled:
        native = "off"
    }
    out += "\nClipboard\n"
    out += "  native       \(native)\n"
    out += "  tmux         \(clipboard.tmuxRoute ? "on" : "off")\n"
    out += "  osc 52       \(clipboard.osc52Route ? clipboard.osc52Capability.label : "off")\n"
    out += "  wrap         \(clipboard.wrapSink ? "on" : "off")\n"
    if clipboard.displayServer == .wayland {
        out += "  data-control \(clipboard.dataControl == .available ? "on" : "off")\n"
    }
    let status: String
    switch clipboard.delivery {
    case .confirmed: status = "confirmed"
    case .unverified: status = "unverified"
    case .failed: status = "unavailable"
    }
    out += "  status       \(status)\n"

    if let voice = facts.voice {
        out += "\nVoice\n"
        switch voice {
        case .device(let name, let detail):
            out += "  microphone   \(name) (\(detail))\n"
        case .missing:
            out += "  microphone   none detected\n"
        }
    }

    formatFindings(report, into: &out)
    return out
}

/// `format_findings` (doctor_format.rs:142-172).
private func formatFindings(_ report: DiagnosticReport, into out: inout String) {
    let issues = report.findings.filter { $0.disposition == .issue }
    if issues.isEmpty {
        if report.issueCount == 0 {
            out += "\nNo issues found.\n"
        } else {
            out += "\nAn issue is shown in the Clipboard status above.\n"
        }
    } else {
        out += "\nIssues (\(issues.count))\n"
        for finding in issues {
            formatFinding(&out, finding)
        }
    }

    let recommendations = report.findings.filter { $0.disposition == .recommendation }
    if !recommendations.isEmpty {
        out += "\nRecommendations\n"
        for finding in recommendations {
            formatFinding(&out, finding)
        }
    }
}

/// `format_finding` (doctor_format.rs:174-204).
private func formatFinding(_ out: inout String, _ finding: DiagnosticFinding) {
    let marker = finding.disposition == .issue ? "!" : "i"
    out += "\n  \(marker) \(finding.id)  \(finding.message)\n"
    if let automatic = finding.automaticRemediation {
        let command = humanFixCommand(automatic.fixID) ?? automatic.command
        out += "      Automatic setup: `\(command)`\n"
    }
    if let remediation = finding.remediation {
        switch (remediation.configPath, finding.automaticRemediation) {
        case (.some(let path), _):
            out += "      Add `\(remediation.fix)` to \(path)\n"
        case (.none, .some):
            out += "      One-off: `\(remediation.fix)`\n"
        case (.none, .none):
            out += "      Run: `\(remediation.fix)`\n"
        }
    }
    if let note = finding.note {
        out += "      Note: \(note)\n"
    }
}
