// DoctorCommandFormat.swift
//
// Standalone `grok doctor` human and `--json` formatters.
//
// Ports `xai-grok-pager/src/doctor_cmd/human.rs` (257 lines) and
// `xai-grok-pager/src/doctor_cmd/json.rs` (467 lines) at reference 650c1db7.
//
// The JSON emitter preserves upstream field order and serde_json's pretty
// layout (2-space indent) so `grok doctor --json` output is comparable
// byte-for-byte across the two implementations. Golden tests assert both
// structure and ordering.

import Foundation

/// `SCHEMA_VERSION` (doctor_cmd/mod.rs:11).
public let doctorJSONSchemaVersion = "1"

/// `LIVE_TUI_PROBE_CTA` (doctor_cmd/human.rs:8).
let liveTUIProbeCTA = "Some checks only run in Grok. Start Grok and run /doctor."

public enum DoctorCommandFormat {
    /// `human::format` (doctor_cmd/human.rs:10-184).
    public static func human(_ report: DiagnosticReport) -> String {
        let facts = report.facts
        var out = "Grok Doctor\n\nEnvironment\n"

        fact(&out, "terminal", facts.terminal.displayName)
        switch facts.xtversion {
        case .available(let value): fact(&out, "terminal version", value)
        case .noReply: unavailable(&out, "terminal version", "no reply")
        case .unavailable: unavailable(&out, "terminal version", "unavailable")
        }
        fact(&out, "multiplexer", facts.multiplexer.displayName)
        if let byobu = facts.byobu {
            fact(&out, "byobu", byobu.displayName)
        }
        fact(&out, "ssh", facts.ssh ? "yes" : "no")
        switch facts.color.level {
        case .available(let level):
            fact(&out, "color", level.canonicalName)
            let themes: String
            if facts.color.availableThemes.count == facts.color.totalThemes {
                themes = "all"
            } else {
                themes = "\(facts.color.availableThemes.count)/\(facts.color.totalThemes): "
                    + facts.color.availableThemes.map(\.displayName).joined(separator: ", ")
            }
            fact(&out, "themes", themes)
        case .noReply, .unavailable:
            unavailable(&out, "color", "unavailable")
            unavailable(&out, "themes", "unavailable")
        }

        if let keyboard = facts.keyboard {
            let rescue = keyboard.os == .macos
                ? "OS rescue active"
                : "OS rescue unavailable on this platform"
            fact(&out, "keyboard", "\(keyboard.modifierDelivery.label) (\(rescue))")
        }
        if let newline = facts.newline {
            fact(&out, "newline", formatNewline(newline))
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
        fact(&out, "native", native)
        fact(&out, "tmux", clipboard.tmuxRoute ? "on" : "off")
        fact(&out, "osc 52", clipboard.osc52Route ? clipboard.osc52Capability.label : "off")
        fact(&out, "SSH wrap", clipboard.wrapSink ? "on" : "off")
        if clipboard.displayServer == .wayland {
            switch clipboard.dataControl {
            case .available: fact(&out, "data-control", "on")
            case .missing: fact(&out, "data-control", "off")
            case .unavailable: unavailable(&out, "data-control", "unavailable")
            case .error:
                let detail = report.probeNotes
                    .first { $0.probe == "wayland.data-control" }?
                    .message
                if let message = detail {
                    unavailable(&out, "data-control", "error: \(message)")
                } else {
                    unavailable(&out, "data-control", "error")
                }
            case .notApplicable:
                break
            }
        }
        let status: String
        switch clipboard.delivery {
        case .confirmed: status = "confirmed"
        case .unverified: status = "unverified"
        case .failed: status = "unavailable"
        }
        fact(&out, "status", status)

        if let voice = facts.voice {
            out += "\nVoice\n"
            switch voice {
            case .device(let name, let detail):
                fact(&out, "microphone", "\(name) (\(detail))")
            case .missing(let error):
                fact(&out, "microphone", "none detected (\(error))")
            }
        }

        if !report.findings.isEmpty {
            out += "\nFindings\n"
            for finding in report.findings {
                formatFinding(&out, finding)
            }
        }

        let visibleNotes = report.probeNotes.filter { !factAlreadyShowsProbe($0.probe) }
        if !visibleNotes.isEmpty {
            out += "\nChecks not completed\n"
            for note in visibleNotes {
                let message: String
                if let detail = note.message {
                    message = "\(probeStatusLabel(note.status)): \(detail)"
                } else {
                    message = probeStatusLabel(note.status)
                }
                row(&out, "?", note.probe, message)
            }
        }

        if report.probeNotes.contains(where: probeRequiresLiveTUI) {
            out += "\nNeeds a running session\n"
            out += "  \(liveTUIProbeCTA)\n"
        }

        let issues = report.issueCount
        let recommendations = report.recommendationCount
        out += "\n"
        out += "\(issues) \(plural(issues, "issue", "issues")), "
        out += "\(recommendations) \(plural(recommendations, "recommendation", "recommendations"))\n"
        return out
    }

    /// `json::write` (doctor_cmd/json.rs:14-21): pretty JSON + trailing newline.
    public static func json(_ report: DiagnosticReport) -> String {
        jsonValue(report).renderedPretty() + "\n"
    }

    /// The full ordered JSON tree (`JsonReport`, doctor_cmd/json.rs:23-47).
    static func jsonValue(_ report: DiagnosticReport) -> OrderedJSON {
        .object([
            ("schemaVersion", .string(doctorJSONSchemaVersion)),
            ("facts", jsonFacts(report)),
            ("findings", .array(report.findings.map(jsonFinding))),
            ("probeNotes", .array(report.probeNotes.map(jsonProbeNote))),
            ("counts", .object([
                ("issues", .number(report.issueCount)),
                ("recommendations", .number(report.recommendationCount)),
                ("probeNotes", .number(report.probeNotes.count)),
            ])),
        ])
    }
}

// MARK: - Human helpers (doctor_cmd/human.rs:186-257)

/// `fact_already_shows_probe` (human.rs:186-191).
private func factAlreadyShowsProbe(_ probe: String) -> Bool {
    probe == "runtime.xtversion" || probe == "terminal.color" || probe == "wayland.data-control"
}

private func fact(_ out: inout String, _ label: String, _ value: String) {
    row(&out, "·", label, value)
}

private func unavailable(_ out: inout String, _ label: String, _ value: String) {
    row(&out, "?", label, value)
}

/// `row` (human.rs:201-203): `"  {marker} {label:<28} {value}\n"`.
private func row(_ out: inout String, _ marker: String, _ label: String, _ value: String) {
    let padded = label.count < 28 ? label + String(repeating: " ", count: 28 - label.count) : label
    out += "  \(marker) \(padded) \(value)\n"
}

/// `format_finding` (human.rs:205-227).
private func formatFinding(_ out: inout String, _ finding: DiagnosticFinding) {
    let marker = finding.disposition == .issue ? "!" : "i"
    row(&out, marker, finding.id.description, finding.message)
    if let automatic = finding.automaticRemediation {
        let command = humanFixCommand(automatic.fixID) ?? automatic.command
        out += "    → Automatic setup: `\(command)`\n"
    }
    if let remediation = finding.remediation {
        let instruction: String
        switch (remediation.configPath, finding.automaticRemediation) {
        case (.some(let path), _):
            instruction = "Add `\(remediation.fix)` to \(path)"
        case (.none, .some):
            instruction = "One-off: `\(remediation.fix)`"
        case (.none, .none):
            instruction = "Run: `\(remediation.fix)`"
        }
        out += "    → \(instruction)\n"
    }
    if let note = finding.note {
        out += "      \(note)\n"
    }
}

/// `format_newline` (human.rs:229-245). Wording deliberately differs from
/// the in-TUI formatter (`cannot` vs `can't`) — upstream does the same.
private func formatNewline(_ newline: NewlineFact) -> String {
    let detail: String
    switch newline {
    case .vte(.some(let version)):
        detail = "VTE \(version); need >= 8200 for Shift+Enter"
    case .vte(.none):
        detail = "legacy VTE; need VTE >= 0.82 for Shift+Enter"
    case .xtermJs(let terminal):
        detail = "\(terminal): xterm.js cannot distinguish Shift+Enter"
    case .noKittyKeyboardProtocol:
        detail = "no Kitty keyboard protocol; Shift+Enter equals Enter"
    }
    return "Alt+Enter (\(detail))"
}

private func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
    count == 1 ? singular : plural
}

private func probeStatusLabel(_ status: ProbeStatus) -> String {
    switch status {
    case .unsupported: return "unsupported"
    case .unavailable: return "unavailable"
    case .error: return "error"
    }
}

// MARK: - JSON tree (doctor_cmd/json.rs:49-349)

private func jsonFacts(_ report: DiagnosticReport) -> OrderedJSON {
    let facts = report.facts
    var fields: [(String, OrderedJSON)] = [
        ("terminal", .object([
            ("name", .string(jsonTerminalName(facts.terminal))),
            ("xtversion", jsonRuntimeStringFact(facts.xtversion)),
        ])),
        ("multiplexer", .object([
            ("kind", .string(jsonMultiplexer(facts.multiplexer))),
            ("byobu", facts.byobu.map { .string(jsonByobuBackend($0)) } ?? .null),
        ])),
        ("ssh", .bool(facts.ssh)),
        ("color", .object([
            ("level", jsonColorLevel(facts.color.level)),
            ("availableThemes", .array(facts.color.availableThemes.map { .string($0.displayName) })),
            ("totalThemes", .number(facts.color.totalThemes)),
        ])),
        ("keyboard", facts.keyboard.map { keyboard in
            .object([
                ("cmd", .string(jsonModifierFate(keyboard.modifierDelivery.cmd))),
                ("opt", .string(jsonModifierFate(keyboard.modifierDelivery.opt))),
                ("os", .string(jsonHostOs(keyboard.os))),
            ])
        } ?? .null),
        ("newline", facts.newline.map(jsonNewline) ?? .null),
        ("clipboard", jsonClipboard(facts.clipboard)),
    ]
    // `#[serde(skip_serializing_if = "Option::is_none")]` (json.rs:59-60).
    if let voice = facts.voice {
        fields.append(("voice", jsonVoice(voice)))
    }
    return .object(fields)
}

private func jsonVoice(_ voice: VoiceFacts) -> OrderedJSON {
    switch voice {
    case .device(let name, let detail):
        return .object([
            ("status", .string("available")),
            ("name", .string(name)),
            ("detail", .string(detail)),
        ])
    case .missing(let error):
        return .object([
            ("status", .string("missing")),
            ("error", .string(error)),
        ])
    }
}

private func jsonRuntimeStringFact(_ fact: RuntimeFact<String>) -> OrderedJSON {
    switch fact {
    case .available(let value):
        return .object([("status", .string("available")), ("value", .string(value))])
    case .noReply:
        return .object([("status", .string("no_reply")), ("value", .null)])
    case .unavailable:
        return .object([("status", .string("unavailable")), ("value", .null)])
    }
}

private func jsonColorLevel(_ fact: RuntimeFact<ColorLevel>) -> OrderedJSON {
    switch fact {
    case .available(let level):
        return .object([("status", .string("available")), ("value", .string(level.canonicalName))])
    case .noReply:
        return .object([("status", .string("no_reply")), ("value", .null)])
    case .unavailable:
        return .object([("status", .string("unavailable")), ("value", .null)])
    }
}

/// `JsonNewlineFact` (json.rs:211-235): internally tagged with `kind`.
private func jsonNewline(_ newline: NewlineFact) -> OrderedJSON {
    switch newline {
    case .vte(let version):
        return .object([("kind", .string("vte")), ("version", version.map(OrderedJSON.string) ?? .null)])
    case .xtermJs(let terminal):
        return .object([("kind", .string("xterm_js")), ("terminalName", .string(jsonTerminalName(terminal)))])
    case .noKittyKeyboardProtocol:
        return .object([("kind", .string("no_kitty_keyboard_protocol"))])
    }
}

private func jsonClipboard(_ facts: ClipboardFacts) -> OrderedJSON {
    .object([
        ("nativeRoute", .bool(facts.nativeRoute)),
        ("nativeTool", .string(facts.nativeTool)),
        ("nativePreflight", .string(jsonNativePreflight(facts.nativePreflight))),
        ("tmuxRoute", .bool(facts.tmuxRoute)),
        ("osc52Route", .bool(facts.osc52Route)),
        ("osc52Capability", .string(jsonOsc52Capability(facts.osc52Capability))),
        ("wrapSink", .bool(facts.wrapSink)),
        ("displayServer", .string(jsonDisplayServer(facts.displayServer))),
        ("containerNoDisplay", .bool(facts.containerNoDisplay)),
        ("dataControl", .string(jsonDataControl(facts.dataControl))),
        ("delivery", .string(jsonClipboardDelivery(facts.delivery))),
        ("fix", facts.fix.map(OrderedJSON.string) ?? .null),
    ])
}

private func jsonFinding(_ finding: DiagnosticFinding) -> OrderedJSON {
    .object([
        ("id", .string(finding.id.description)),
        ("disposition", .string(finding.disposition == .issue ? "issue" : "recommendation")),
        ("message", .string(finding.message)),
        ("remediation", finding.remediation.map { remediation in
            .object([
                ("fix", .string(remediation.fix)),
                ("configPath", remediation.configPath.map(OrderedJSON.string) ?? .null),
            ])
        } ?? .null),
        ("automaticRemediation", finding.automaticRemediation.map { automatic in
            .object([
                ("fixId", .string(automatic.fixID.description)),
                ("command", .string(automatic.command)),
            ])
        } ?? .null),
        ("note", finding.note.map(OrderedJSON.string) ?? .null),
    ])
}

private func jsonProbeNote(_ note: ProbeNote) -> OrderedJSON {
    .object([
        ("probe", .string(note.probe)),
        ("status", .string(probeStatusLabel(note.status))),
        ("message", note.message.map(OrderedJSON.string) ?? .null),
    ])
}

// MARK: - Stable mapping tables (doctor_cmd/json.rs:351-467)

/// `terminal_name` (json.rs:351-374).
public func jsonTerminalName(_ name: TerminalName) -> String {
    switch name {
    case .appleTerminal: return "apple_terminal"
    case .ghostty: return "ghostty"
    case .iterm2: return "iterm2"
    case .warpTerminal: return "warp"
    case .vsCode: return "vs_code"
    case .cursor: return "cursor"
    case .windsurf: return "windsurf"
    case .zed: return "zed"
    case .wezTerm: return "wezterm"
    case .kitty: return "kitty"
    case .alacritty: return "alacritty"
    case .rio: return "rio"
    case .foot: return "foot"
    case .jetBrains: return "jetbrains"
    case .grokDesktop: return "grok_desktop"
    case .vte: return "vte"
    case .terminator: return "terminator"
    case .windowsTerminal: return "windows_terminal"
    case .otty: return "otty"
    case .unknown: return "unknown"
    }
}

/// `multiplexer` (json.rs:376-385).
public func jsonMultiplexer(_ kind: MultiplexerKind) -> String {
    switch kind {
    case .tmux: return "tmux"
    case .screen: return "screen"
    case .zellij: return "zellij"
    case .cmux: return "cmux"
    case .herdr: return "herdr"
    case .undetected: return "undetected"
    }
}

/// `byobu_backend` (json.rs:387-393).
public func jsonByobuBackend(_ backend: ByobuBackend) -> String {
    switch backend {
    case .unknown: return "unknown"
    case .tmux: return "tmux"
    case .screen: return "screen"
    }
}

/// `modifier_fate` (json.rs:395-403).
public func jsonModifierFate(_ fate: ModifierFate) -> String { fate.rawValue }

/// `host_os` (json.rs:405-413).
public func jsonHostOs(_ os: HostOs) -> String { os.rawValue }

/// `native_preflight` (json.rs:415-422).
public func jsonNativePreflight(_ fact: NativeClipboardPreflight) -> String {
    switch fact {
    case .disabled: return "disabled"
    case .localAvailable: return "local_available"
    case .remoteOnly: return "remote_only"
    case .unavailable: return "unavailable"
    }
}

/// `osc52_capability` (json.rs:424-430).
public func jsonOsc52Capability(_ capability: Osc52Capability) -> String { capability.rawValue }

/// `display_server` (json.rs:432-441).
public func jsonDisplayServer(_ server: DisplayServer) -> String { server.rawValue }

/// `clipboard_delivery` (json.rs:443-449).
public func jsonClipboardDelivery(_ delivery: ClipboardDelivery) -> String { delivery.rawValue }

/// `data_control` (json.rs:451-459).
public func jsonDataControl(_ fact: DataControlFact) -> String {
    switch fact {
    case .available: return "available"
    case .missing: return "missing"
    case .unavailable: return "unavailable"
    case .error: return "error"
    case .notApplicable: return "not_applicable"
    }
}

// MARK: - Ordered JSON emitter

/// Minimal ordered JSON tree matching serde_json's pretty printer: objects
/// keep insertion order, 2-space indent, `": "` separators, raw UTF-8
/// strings with standard escapes. Foundation serializers cannot promise key
/// order, which the upstream contract test pins.
public indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Int)
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public func renderedPretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let childPad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return String(value)
        case .string(let value): return OrderedJSON.escape(value)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items
                .map { childPad + $0.renderedPretty(indent: indent + 1) }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            let body = fields
                .map { "\(childPad)\(OrderedJSON.escape($0.0)): \($0.1.renderedPretty(indent: indent + 1))" }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }

    /// serde_json-compatible string escaping: control characters escaped,
    /// non-ASCII emitted raw.
    static func escape(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let scalar where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
