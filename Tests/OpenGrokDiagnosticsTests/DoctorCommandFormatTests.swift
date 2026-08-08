// DoctorCommandFormatTests.swift
//
// Standalone `grok doctor` human + JSON formatter goldens, ported from
// `xai-grok-pager/src/doctor_cmd/tests.rs` at reference 650c1db7
// (`human_healthy_fixture_is_exact`, `human_mixed_fixture_is_exact`,
// `human_incomplete_fixture_is_exact_without_duplicate_probe_rows`,
// `human_wayland_error_includes_detail_once`, the JSON contract tests,
// and the stable mapping tables).

import Testing
import Foundation
@testable import OpenGrokDiagnostics

/// `healthy_report` (doctor_cmd/tests.rs:95-136).
func healthyReport() -> DiagnosticReport {
    DiagnosticReport(
        facts: DiagnosticFacts(
            terminal: .ghostty,
            xtversion: .noReply,
            multiplexer: .undetected,
            byobu: nil,
            ssh: false,
            tmux: TmuxFacts(
                extendedKeys: .unavailable,
                setClipboard: .unavailable,
                allowPassthroughSupport: .unavailable,
                allowPassthrough: .unavailable,
                colorPassthrough: .unknown
            ),
            color: ColorFacts(
                level: .available(.trueColor),
                availableThemes: ThemeKind.all,
                totalThemes: ThemeKind.all.count
            ),
            keyboard: nil,
            newline: nil,
            clipboard: ClipboardFacts(
                nativeRoute: true,
                nativeTool: "pbcopy",
                nativePreflight: .localAvailable,
                tmuxRoute: false,
                osc52Route: false,
                osc52Capability: .supported,
                wrapSink: false,
                displayServer: .unknown,
                containerNoDisplay: false,
                dataControl: .notApplicable,
                delivery: .confirmed,
                fix: nil
            ),
            voice: nil
        ),
        findings: [],
        probeNotes: []
    )
}

/// `mixed_report` (doctor_cmd/tests.rs:138-215).
private func mixedReport() -> DiagnosticReport {
    var report = healthyReport()
    report.facts.xtversion = .available("Ghostty 1.2.3")
    report.facts.multiplexer = .tmux
    report.facts.byobu = .tmux
    report.facts.ssh = true
    report.facts.color = ColorFacts(
        level: .available(.ansi256),
        availableThemes: [.grokNight, .grokDay],
        totalThemes: ThemeKind.all.count
    )
    report.facts.keyboard = KeyboardFact(
        modifierDelivery: ModifierDelivery(cmd: .dropped, opt: .native),
        os: .macos
    )
    report.facts.newline = .xtermJs(terminal: .cursor)
    report.facts.clipboard.tmuxRoute = true
    report.facts.clipboard.osc52Route = true
    report.findings = [
        DiagnosticFinding(
            id: DiagnosticId("terminal", "tmux-clipboard"),
            disposition: .issue,
            message: "OSC 52 clipboard passthrough is disabled",
            remediation: ManualRemediation(fix: "set -g set-clipboard on", configPath: "~/.tmux.conf"),
            automaticRemediation: automaticRemediationFor(DiagnosticId("terminal", "tmux-clipboard")),
            note: "Reload tmux after editing."
        ),
        DiagnosticFinding(
            id: DiagnosticId("terminal", "ssh-wrap"),
            disposition: .recommendation,
            message: "Use local SSH wrapping",
            remediation: ManualRemediation(fix: "open-grok wrap ssh <host>", configPath: nil),
            automaticRemediation: sshWrapAutomaticRemediation(),
            note: nil
        ),
    ]
    report.probeNotes = [
        ProbeNote(probe: "tmux.version", status: .unavailable, message: nil),
        ProbeNote(probe: "tmux.extended-keys", status: .unavailable, message: nil),
        ProbeNote(probe: "tmux.allow-passthrough-support", status: .unsupported, message: nil),
        ProbeNote(probe: "runtime.fullscreen-active", status: .unavailable, message: nil),
        ProbeNote(probe: "tmux.control-mode", status: .error, message: "server unavailable"),
    ]
    return report
}

@Suite("grok doctor human formatter goldens")
struct DoctorHumanFormatTests {
    /// `human_healthy_fixture_is_exact` (doctor_cmd/tests.rs:450-475).
    @Test func humanHealthyFixtureIsExact() {
        #expect(DoctorCommandFormat.human(healthyReport()) == [
            "Grok Doctor\n",
            "\n",
            "Environment\n",
            "  · terminal                     Ghostty\n",
            "  ? terminal version             no reply\n",
            "  · multiplexer                  None detected\n",
            "  · ssh                          no\n",
            "  · color                        truecolor\n",
            "  · themes                       all\n",
            "\n",
            "Clipboard\n",
            "  · native                       local (pbcopy)\n",
            "  · tmux                         off\n",
            "  · osc 52                       off\n",
            "  · SSH wrap                     off\n",
            "  · status                       confirmed\n",
            "\n",
            "0 issues, 0 recommendations\n",
        ].joined())
    }

    /// `human_mixed_fixture_is_exact` (doctor_cmd/tests.rs:477-524).
    @Test func humanMixedFixtureIsExact() {
        #expect(DoctorCommandFormat.human(mixedReport()) == [
            "Grok Doctor\n",
            "\n",
            "Environment\n",
            "  · terminal                     Ghostty\n",
            "  · terminal version             Ghostty 1.2.3\n",
            "  · multiplexer                  tmux\n",
            "  · byobu                        tmux\n",
            "  · ssh                          yes\n",
            "  · color                        256\n",
            "  · themes                       2/5: groknight, grokday\n",
            "  · keyboard                     cmd=dropped, opt=native (OS rescue active)\n",
            "  · newline                      Alt+Enter (Cursor: xterm.js cannot distinguish Shift+Enter)\n",
            "\n",
            "Clipboard\n",
            "  · native                       local (pbcopy)\n",
            "  · tmux                         on\n",
            "  · osc 52                       supported\n",
            "  · SSH wrap                     off\n",
            "  · status                       confirmed\n",
            "\n",
            "Findings\n",
            "  ! terminal.tmux-clipboard      OSC 52 clipboard passthrough is disabled\n",
            "    → Automatic setup: `grok doctor fix tmux-clipboard`\n",
            "    → Add `set -g set-clipboard on` to ~/.tmux.conf\n",
            "      Reload tmux after editing.\n",
            "  i terminal.ssh-wrap            Use local SSH wrapping\n",
            "    → Automatic setup: `grok doctor fix ssh-wrap`\n",
            "    → One-off: `open-grok wrap ssh <host>`\n",
            "\n",
            "Checks not completed\n",
            "  ? tmux.version                 unavailable\n",
            "  ? tmux.extended-keys           unavailable\n",
            "  ? tmux.allow-passthrough-support unsupported\n",
            "  ? runtime.fullscreen-active    unavailable\n",
            "  ? tmux.control-mode            error: server unavailable\n",
            "\n",
            "Needs a running session\n",
            "  Some checks only run in Grok. Start Grok and run /doctor.\n",
            "\n",
            "1 issue, 1 recommendation\n",
        ].joined())
    }

    /// `human_incomplete_fixture_is_exact_without_duplicate_probe_rows`
    /// (doctor_cmd/tests.rs:613-663).
    @Test func humanIncompleteFixtureIsExactWithoutDuplicateProbeRows() {
        var report = healthyReport()
        report.facts.xtversion = .unavailable
        report.facts.color.level = .unavailable
        report.facts.color.availableThemes = []
        report.facts.clipboard.dataControl = .unavailable
        report.probeNotes = [
            ProbeNote(probe: "runtime.xtversion", status: .unavailable, message: nil),
            ProbeNote(probe: "terminal.color", status: .unavailable, message: nil),
            ProbeNote(probe: "wayland.data-control", status: .unavailable, message: nil),
        ]
        #expect(DoctorCommandFormat.human(report) == [
            "Grok Doctor\n",
            "\n",
            "Environment\n",
            "  · terminal                     Ghostty\n",
            "  ? terminal version             unavailable\n",
            "  · multiplexer                  None detected\n",
            "  · ssh                          no\n",
            "  ? color                        unavailable\n",
            "  ? themes                       unavailable\n",
            "\n",
            "Clipboard\n",
            "  · native                       local (pbcopy)\n",
            "  · tmux                         off\n",
            "  · osc 52                       off\n",
            "  · SSH wrap                     off\n",
            "  · status                       confirmed\n",
            "\n",
            "Needs a running session\n",
            "  Some checks only run in Grok. Start Grok and run /doctor.\n",
            "\n",
            "0 issues, 0 recommendations\n",
        ].joined())
    }

    /// `human_wayland_error_includes_detail_once` (doctor_cmd/tests.rs:317-371).
    @Test func humanWaylandErrorIncludesDetailOnce() {
        var report = healthyReport()
        report.facts.clipboard.nativePreflight = .unavailable
        report.facts.clipboard.displayServer = .wayland
        report.facts.clipboard.dataControl = .error
        report.facts.clipboard.delivery = .failed
        report.facts.clipboard.fix = "/minimal"
        report.findings.append(DiagnosticFinding(
            id: clipboardDeliveryUnavailableID,
            disposition: .issue,
            message: "No configured clipboard route can reach the intended clipboard",
            remediation: nil,
            automaticRemediation: nil,
            note: "Each in-app copy is also written to the backup path shown by the operation. Use `/copy <file>` for an explicit file or `/minimal` for terminal-native selection, then check the native clipboard tool reported above."
        ))
        report.probeNotes = [
            ProbeNote(probe: "wayland.data-control", status: .error, message: "probe worker died"),
        ]
        #expect(DoctorCommandFormat.human(report) == [
            "Grok Doctor\n",
            "\n",
            "Environment\n",
            "  · terminal                     Ghostty\n",
            "  ? terminal version             no reply\n",
            "  · multiplexer                  None detected\n",
            "  · ssh                          no\n",
            "  · color                        truecolor\n",
            "  · themes                       all\n",
            "\n",
            "Clipboard\n",
            "  · native                       unavailable\n",
            "  · tmux                         off\n",
            "  · osc 52                       off\n",
            "  · SSH wrap                     off\n",
            "  ? data-control                 error: probe worker died\n",
            "  · status                       unavailable\n",
            "\n",
            "Findings\n",
            "  ! clipboard.delivery-unavailable No configured clipboard route can reach the intended clipboard\n",
            "      Each in-app copy is also written to the backup path shown by the operation. Use `/copy <file>` for an explicit file or `/minimal` for terminal-native selection, then check the native clipboard tool reported above.\n",
            "\n",
            "1 issue, 0 recommendations\n",
        ].joined())
    }
}

@Suite("grok doctor JSON formatter")
struct DoctorJSONFormatTests {
    private func decodeJSON(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// `json_empty_fixture_pins_null_policy` (doctor_cmd/tests.rs:665-713).
    @Test func jsonEmptyFixturePinsNullPolicy() throws {
        var report = healthyReport()
        report.facts.xtversion = .unavailable
        report.facts.color.level = .unavailable
        report.facts.color.availableThemes = []
        report.facts.clipboard.dataControl = .unavailable
        let text = DoctorCommandFormat.json(report)
        let json = try #require(try decodeJSON(text) as? [String: Any])

        #expect(json["schemaVersion"] as? String == "1")
        let facts = try #require(json["facts"] as? [String: Any])
        let terminal = try #require(facts["terminal"] as? [String: Any])
        #expect(terminal["name"] as? String == "ghostty")
        let xtversion = try #require(terminal["xtversion"] as? [String: Any])
        #expect(xtversion["status"] as? String == "unavailable")
        #expect(xtversion["value"] is NSNull)
        let multiplexer = try #require(facts["multiplexer"] as? [String: Any])
        #expect(multiplexer["kind"] as? String == "undetected")
        #expect(multiplexer["byobu"] is NSNull)
        #expect(facts["ssh"] as? Bool == false)
        let color = try #require(facts["color"] as? [String: Any])
        let level = try #require(color["level"] as? [String: Any])
        #expect(level["status"] as? String == "unavailable")
        #expect(level["value"] is NSNull)
        #expect((color["availableThemes"] as? [Any])?.isEmpty == true)
        #expect(color["totalThemes"] as? Int == 5)
        #expect(facts["keyboard"] is NSNull)
        #expect(facts["newline"] is NSNull)
        let clipboard = try #require(facts["clipboard"] as? [String: Any])
        #expect(clipboard["nativeRoute"] as? Bool == true)
        #expect(clipboard["nativeTool"] as? String == "pbcopy")
        #expect(clipboard["nativePreflight"] as? String == "local_available")
        #expect(clipboard["tmuxRoute"] as? Bool == false)
        #expect(clipboard["osc52Route"] as? Bool == false)
        #expect(clipboard["osc52Capability"] as? String == "supported")
        #expect(clipboard["wrapSink"] as? Bool == false)
        #expect(clipboard["displayServer"] as? String == "unknown")
        #expect(clipboard["containerNoDisplay"] as? Bool == false)
        #expect(clipboard["dataControl"] as? String == "unavailable")
        #expect(clipboard["delivery"] as? String == "confirmed")
        #expect(clipboard["fix"] is NSNull)
        #expect(facts["voice"] == nil, "voice is omitted, not null")
        #expect((json["findings"] as? [Any])?.isEmpty == true)
        #expect((json["probeNotes"] as? [Any])?.isEmpty == true)
        let counts = try #require(json["counts"] as? [String: Any])
        #expect(counts["issues"] as? Int == 0)
        #expect(counts["recommendations"] as? Int == 0)
        #expect(counts["probeNotes"] as? Int == 0)
    }

    /// `json_contract_is_structural_stable_ordered_and_ansi_free`
    /// (doctor_cmd/tests.rs:715-807).
    @Test func jsonContractIsStructuralStableOrderedAndANSIFree() throws {
        let text = DoctorCommandFormat.json(mixedReport())
        let json = try #require(try decodeJSON(text) as? [String: Any])

        let facts = try #require(json["facts"] as? [String: Any])
        let terminal = try #require(facts["terminal"] as? [String: Any])
        let xtversion = try #require(terminal["xtversion"] as? [String: Any])
        #expect(xtversion["status"] as? String == "available")
        #expect(xtversion["value"] as? String == "Ghostty 1.2.3")
        let multiplexer = try #require(facts["multiplexer"] as? [String: Any])
        #expect(multiplexer["kind"] as? String == "tmux")
        #expect(multiplexer["byobu"] as? String == "tmux")
        #expect(facts["ssh"] as? Bool == true)
        let color = try #require(facts["color"] as? [String: Any])
        #expect((color["availableThemes"] as? [String]) == ["groknight", "grokday"])
        let keyboard = try #require(facts["keyboard"] as? [String: Any])
        #expect(keyboard["cmd"] as? String == "dropped")
        #expect(keyboard["opt"] as? String == "native")
        #expect(keyboard["os"] as? String == "macos")
        let newline = try #require(facts["newline"] as? [String: Any])
        #expect(newline["kind"] as? String == "xterm_js")
        #expect(newline["terminalName"] as? String == "cursor")

        let findings = try #require(json["findings"] as? [[String: Any]])
        #expect(findings.count == 2)
        #expect(findings[0]["id"] as? String == "terminal.tmux-clipboard")
        #expect(findings[0]["disposition"] as? String == "issue")
        let remediation = try #require(findings[0]["remediation"] as? [String: Any])
        #expect(remediation["fix"] as? String == "set -g set-clipboard on")
        #expect(remediation["configPath"] as? String == "~/.tmux.conf")
        let automatic = try #require(findings[0]["automaticRemediation"] as? [String: Any])
        #expect(automatic["fixId"] as? String == "terminal.tmux-clipboard")
        #expect(automatic["command"] as? String == "grok doctor fix terminal.tmux-clipboard")
        #expect(findings[1]["id"] as? String == "terminal.ssh-wrap")
        #expect(findings[1]["note"] is NSNull)

        let probeNotes = try #require(json["probeNotes"] as? [[String: Any]])
        #expect(probeNotes.map { $0["probe"] as? String } == [
            "tmux.version", "tmux.extended-keys", "tmux.allow-passthrough-support",
            "runtime.fullscreen-active", "tmux.control-mode",
        ])
        #expect(probeNotes[4]["status"] as? String == "error")
        #expect(probeNotes[4]["message"] as? String == "server unavailable")
        let counts = try #require(json["counts"] as? [String: Any])
        #expect(counts["issues"] as? Int == 1)
        #expect(counts["recommendations"] as? Int == 1)
        #expect(counts["probeNotes"] as? Int == 5)

        // Ordering and hygiene (doctor_cmd/tests.rs:793-806).
        let issue = try #require(text.range(of: "terminal.tmux-clipboard"))
        let recommendation = try #require(text.range(of: "terminal.ssh-wrap"))
        let version = try #require(text.range(of: "tmux.version"))
        let extended = try #require(text.range(of: "tmux.extended-keys"))
        let unsupported = try #require(text.range(of: "tmux.allow-passthrough-support"))
        let unavailable = try #require(text.range(of: "runtime.fullscreen-active"))
        #expect(issue.lowerBound < recommendation.lowerBound)
        #expect(version.lowerBound < extended.lowerBound)
        #expect(extended.lowerBound < unsupported.lowerBound)
        #expect(unsupported.lowerBound < unavailable.lowerBound)
        #expect(!text.contains("\u{1b}"))
        #expect(!text.contains("Grok Doctor"))
        #expect(text.hasSuffix("\n"))
    }

    /// `newline_variant_and_field_mappings_are_stable` (doctor_cmd/tests.rs:950-987).
    @Test func newlineVariantAndFieldMappingsAreStable() throws {
        var report = healthyReport()
        report.facts.newline = .vte(version: "8200")
        var json = try #require(try decodeJSON(DoctorCommandFormat.json(report)) as? [String: Any])
        var facts = try #require(json["facts"] as? [String: Any])
        var newline = try #require(facts["newline"] as? [String: Any])
        #expect(newline["kind"] as? String == "vte")
        #expect(newline["version"] as? String == "8200")

        report.facts.newline = .noKittyKeyboardProtocol
        json = try #require(try decodeJSON(DoctorCommandFormat.json(report)) as? [String: Any])
        facts = try #require(json["facts"] as? [String: Any])
        newline = try #require(facts["newline"] as? [String: Any])
        #expect(newline["kind"] as? String == "no_kitty_keyboard_protocol")
        #expect(newline.count == 1)
    }

    /// `clipboard_issue_count_preserves_legacy_reports_without_double_counting_named_findings`
    /// (doctor_cmd/tests.rs:989-1003).
    @Test func clipboardIssueCountAvoidsDoubleCounting() {
        var report = healthyReport()
        report.facts.clipboard.delivery = .failed
        #expect(report.issueCount == 1, "legacy fact-only report")
        report.findings.append(DiagnosticFinding(
            id: clipboardDeliveryUnavailableID,
            disposition: .issue,
            message: "clipboard unavailable",
            remediation: nil,
            automaticRemediation: nil,
            note: "manual recovery"
        ))
        #expect(report.issueCount == 1, "named finding replaces fact count")
    }

    /// `new_named_findings_extend_json_without_schema_changes`
    /// (doctor_cmd/tests.rs:1005-1030).
    @Test func newNamedFindingsExtendJSONWithoutSchemaChanges() throws {
        var report = healthyReport()
        report.facts.clipboard.delivery = .unverified
        report.facts.clipboard.fix = "grok wrap <ssh command> or /minimal"
        report.findings.append(DiagnosticFinding(
            id: clipboardDeliveryUnverifiedID,
            disposition: .issue,
            message: "Clipboard delivery could not be verified across this remote boundary",
            remediation: nil,
            automaticRemediation: nil,
            note: "Run /doctor guidance"
        ))
        let json = try #require(try decodeJSON(DoctorCommandFormat.json(report)) as? [String: Any])
        #expect(json["schemaVersion"] as? String == "1")
        let facts = try #require(json["facts"] as? [String: Any])
        let clipboard = try #require(facts["clipboard"] as? [String: Any])
        #expect(clipboard["delivery"] as? String == "unverified")
        #expect(clipboard["fix"] as? String == "grok wrap <ssh command> or /minimal")
        let findings = try #require(json["findings"] as? [[String: Any]])
        #expect(findings[0]["id"] as? String == "clipboard.delivery-unverified")
        let counts = try #require(json["counts"] as? [String: Any])
        #expect(counts["issues"] as? Int == 1)
    }

    /// `stable_mapping_tables_are_complete` (doctor_cmd/tests.rs:809-948).
    @Test func stableMappingTablesAreComplete() {
        #expect(TerminalName.allCases.map(jsonTerminalName) == [
            "apple_terminal", "ghostty", "iterm2", "warp", "vs_code", "cursor",
            "windsurf", "zed", "wezterm", "kitty", "alacritty", "rio", "foot",
            "jetbrains", "grok_desktop", "vte", "terminator", "windows_terminal",
            "otty", "unknown",
        ])
        #expect(
            [MultiplexerKind.tmux, .screen, .zellij, .cmux, .herdr, .undetected].map(jsonMultiplexer)
                == ["tmux", "screen", "zellij", "cmux", "herdr", "undetected"]
        )
        #expect(
            [ByobuBackend.unknown, .tmux, .screen].map(jsonByobuBackend)
                == ["unknown", "tmux", "screen"]
        )
        #expect(
            [DataControlFact.available, .missing, .unavailable, .error, .notApplicable].map(jsonDataControl)
                == ["available", "missing", "unavailable", "error", "not_applicable"]
        )
        #expect(jsonModifierFate(.native) == "native")
        #expect(jsonModifierFate(.dropped) == "dropped")
        #expect(jsonModifierFate(.unrecoverable) == "unrecoverable")
        #expect(jsonModifierFate(.unknown) == "unknown")
        #expect(jsonHostOs(.macos) == "macos")
        #expect(jsonHostOs(.linux) == "linux")
        #expect(jsonHostOs(.windows) == "windows")
        #expect(jsonHostOs(.other) == "other")
        #expect(
            [NativeClipboardPreflight.disabled, .localAvailable, .remoteOnly, .unavailable].map(jsonNativePreflight)
                == ["disabled", "local_available", "remote_only", "unavailable"]
        )
        #expect(
            [Osc52Capability.supported, .unsupported, .unknown].map(jsonOsc52Capability)
                == ["supported", "unsupported", "unknown"]
        )
        #expect(
            [ClipboardDelivery.confirmed, .unverified, .failed].map(jsonClipboardDelivery)
                == ["confirmed", "unverified", "failed"]
        )
        #expect(
            [DisplayServer.quartz, .wayland, .x11, .win32, .unknown].map(jsonDisplayServer)
                == ["quartz", "wayland", "x11", "win32", "unknown"]
        )
    }
}
