// DoctorFormatTests.swift
//
// In-TUI `/doctor` formatter goldens, ported byte-for-byte from
// `xai-grok-pager/src/diagnostics/doctor_format_tests.rs` at reference
// 650c1db7. These pin whole outputs; a wording change fails the suite on
// purpose (the strings are the upstream parity contract).

import Testing
import Foundation
@testable import OpenGrokDiagnostics

private let localRoute = ClipboardRoute(native: true, tmuxBuffer: false, osc52: false, osc52TmuxPassthrough: false)
private let sshRoute = ClipboardRoute(native: true, tmuxBuffer: false, osc52: true, osc52TmuxPassthrough: false)
private let tmuxRoute = ClipboardRoute(native: true, tmuxBuffer: true, osc52: true, osc52TmuxPassthrough: true)

private func makeSnapshot(
    terminal: TerminalContext,
    tmux: TmuxProbeFacts,
    route: ClipboardRoute,
    nativeTool: String,
    osc52SinkActive: Bool,
    colorLevel: ColorLevel,
    runtime: TuiProbeEvidence
) -> DiagnosticSnapshot {
    DiagnosticSnapshot(
        common: CommonProbeSnapshot(
            terminal: terminal,
            tmux: tmux,
            wayland: WaylandProbeFacts(isWayland: false, dataControl: .available(false), wlCopyAvailable: false)
        ),
        clipboard: ClipboardProbeFacts(route: route, nativeTool: nativeTool, osc52SinkActive: osc52SinkActive),
        hostOs: .macos,
        displayServer: .unknown,
        containerNoDisplay: false,
        colorLevel: .available(colorLevel),
        runtime: DiagnosticRuntimeEvidence(runtime)
    )
}

private func makeRuntime(_ xtversion: String?, _ kittyFlagsPushed: Bool) -> TuiProbeEvidence {
    TuiProbeEvidence(fullscreenActive: true, kittyFlagsPushed: kittyFlagsPushed, xtversion: xtversion)
}

private func ghostty(_ isSSH: Bool) -> TerminalContext {
    TerminalContext(brand: .ghostty, envBrand: .ghostty, isSSH: isSSH)
}

private func buildDoctor(_ snapshot: DiagnosticSnapshot) -> String {
    formatDoctor(diagnosticsView(snapshot))
}

@Suite("format_doctor goldens")
struct DoctorFormatTests {
    /// `healthy_local_output_is_stable` (doctor_format_tests.rs:120-153).
    @Test func healthyLocalOutputIsStable() {
        let terminal = ghostty(false)
        let output = buildDoctor(makeSnapshot(
            terminal: terminal, tmux: .unavailable, route: localRoute,
            nativeTool: "pbcopy", osc52SinkActive: false,
            colorLevel: .trueColor, runtime: makeRuntime(nil, true)
        ))
        #expect(output == [
            "Environment\n",
            "  terminal     Ghostty\n",
            "  multiplexer  None detected\n",
            "  ssh          no\n",
            "  color        truecolor\n",
            "  themes       all\n",
            "\n",
            "Clipboard\n",
            "  native       local (pbcopy)\n",
            "  tmux         off\n",
            "  osc 52       off\n",
            "  wrap         off\n",
            "  status       confirmed\n",
            "\n",
            "No issues found.\n",
        ].joined())
    }

    /// `tmux_config_and_reload_notes_output_is_stable` (doctor_format_tests.rs:155-220).
    @Test func tmuxConfigAndReloadNotesOutputIsStable() {
        let terminal = TerminalContext(
            brand: .iterm2, envBrand: .iterm2, multiplexer: .tmux, byobu: .tmux,
            tmuxVersion: "tmux 3.4", tmuxExtendedKeys: "off"
        )
        let output = buildDoctor(makeSnapshot(
            terminal: terminal,
            tmux: TmuxProbeFacts(
                version: .unavailable,
                extendedKeys: .available("off"),
                setClipboard: .available("off"),
                allowPassthroughSupport: .available(true),
                allowPassthrough: .available("off"),
                controlMode: .available(false),
                clientFeatures: .unavailable
            ),
            route: tmuxRoute, nativeTool: "pbcopy", osc52SinkActive: false,
            colorLevel: .trueColor, runtime: makeRuntime(nil, false)
        ))
        #expect(output == [
            "Environment\n",
            "  terminal     iTerm2\n",
            "  multiplexer  tmux\n",
            "  byobu        tmux\n",
            "  ssh          no\n",
            "  color        truecolor\n",
            "  themes       all\n",
            "\n",
            "Clipboard\n",
            "  native       local (pbcopy)\n",
            "  tmux         on\n",
            "  osc 52       supported\n",
            "  wrap         off\n",
            "  status       confirmed\n",
            "\n",
            "Issues (3)\n",
            "\n",
            "  ! terminal.tmux-clipboard  `set-clipboard` is off in tmux, so OSC 52 clipboard copies are blocked\n",
            "      Automatic setup: `grok doctor fix tmux-clipboard`\n",
            "      Add `set -g set-clipboard on` to ~/.byobu/.tmux.conf\n",
            "      Note: Reload tmux with `tmux source-file ~/.byobu/.tmux.conf`, or restart the tmux server.\n",
            "\n",
            "  ! terminal.dcs-passthrough  `allow-passthrough` is off in tmux, which can block clipboard copies in nested sessions\n",
            "      Automatic setup: `grok doctor fix dcs-passthrough`\n",
            "      Add `set -wg allow-passthrough on` to ~/.byobu/.tmux.conf\n",
            "      Note: Reload tmux with `tmux source-file ~/.byobu/.tmux.conf`, or restart the tmux server.\n",
            "\n",
            "  ! terminal.tmux-extended-keys  `extended-keys` is off in tmux, so some shortcuts may not work\n",
            "      Automatic setup: `grok doctor fix tmux-extended-keys`\n",
            "      Add `set -g extended-keys on` to ~/.byobu/.tmux.conf\n",
            "      Note: Reload tmux with `tmux source-file ~/.byobu/.tmux.conf`, or restart the tmux server.\n",
        ].joined())
    }

    /// `limited_color_output_is_stable` (doctor_format_tests.rs:222-259).
    @Test func limitedColorOutputIsStable() {
        let output = buildDoctor(makeSnapshot(
            terminal: ghostty(false), tmux: .unavailable, route: localRoute,
            nativeTool: "pbcopy", osc52SinkActive: false,
            colorLevel: .ansi256, runtime: makeRuntime(nil, true)
        ))
        #expect(output == [
            "Environment\n",
            "  terminal     Ghostty\n",
            "  multiplexer  None detected\n",
            "  ssh          no\n",
            "  color        256\n",
            "  themes       2/5: groknight, grokday\n",
            "\n",
            "Clipboard\n",
            "  native       local (pbcopy)\n",
            "  tmux         off\n",
            "  osc 52       off\n",
            "  wrap         off\n",
            "  status       confirmed\n",
            "\n",
            "Issues (1)\n",
            "\n",
            "  ! terminal.limited-color  This terminal reports 256 color, so truecolor themes are unavailable\n",
            "      Run: `export COLORTERM=truecolor`\n",
            "      Note: Add this export to your shell startup file, such as `~/.zshrc` or `~/.bashrc`, then restart Grok.\n",
        ].joined())
    }

    /// `unwrapped_ssh_recommendation_with_no_issues_output_is_stable`
    /// (doctor_format_tests.rs:261-301).
    @Test func unwrappedSSHRecommendationOutputIsStable() {
        let output = buildDoctor(makeSnapshot(
            terminal: ghostty(true), tmux: .unavailable, route: sshRoute,
            nativeTool: "pbcopy", osc52SinkActive: false,
            colorLevel: .trueColor, runtime: makeRuntime(nil, true)
        ))
        #expect(output == [
            "Environment\n",
            "  terminal     Ghostty\n",
            "  multiplexer  None detected\n",
            "  ssh          yes\n",
            "  color        truecolor\n",
            "  themes       all\n",
            "\n",
            "Clipboard\n",
            "  native       remote (pbcopy)\n",
            "  tmux         off\n",
            "  osc 52       supported\n",
            "  wrap         off\n",
            "  status       confirmed\n",
            "\n",
            "No issues found.\n",
            "\n",
            "Recommendations\n",
            "\n",
            "  i terminal.ssh-wrap  Use local SSH wrapping for more reliable clipboard copy and terminal recovery\n",
            "      Automatic setup: `grok doctor fix ssh-wrap`\n",
            "      One-off: `open-grok wrap ssh <host>`\n",
            "      Note: Run this on your local computer instead of plain `ssh`. It forwards copies to your local clipboard and restores terminal modes if the connection drops.\n",
        ].joined())
    }

    /// `wrapped_ssh_output_has_no_recommendation` (doctor_format_tests.rs:303-336).
    @Test func wrappedSSHOutputHasNoRecommendation() {
        let output = buildDoctor(makeSnapshot(
            terminal: ghostty(true), tmux: .unavailable, route: sshRoute,
            nativeTool: "pbcopy", osc52SinkActive: true,
            colorLevel: .trueColor, runtime: makeRuntime(nil, true)
        ))
        #expect(output == [
            "Environment\n",
            "  terminal     Ghostty\n",
            "  multiplexer  None detected\n",
            "  ssh          yes\n",
            "  color        truecolor\n",
            "  themes       all\n",
            "\n",
            "Clipboard\n",
            "  native       remote (pbcopy)\n",
            "  tmux         off\n",
            "  osc 52       supported\n",
            "  wrap         on\n",
            "  status       confirmed\n",
            "\n",
            "No issues found.\n",
        ].joined())
    }

    /// `wezterm_xtversion_runtime_evidence_output_is_stable`
    /// (doctor_format_tests.rs:338-378).
    @Test func weztermXtversionRuntimeEvidenceOutputIsStable() {
        let terminal = TerminalContext(isSSH: true)
        let output = buildDoctor(makeSnapshot(
            terminal: terminal, tmux: .unavailable, route: sshRoute,
            nativeTool: "pbcopy", osc52SinkActive: true,
            colorLevel: .trueColor, runtime: makeRuntime("WezTerm 20240203-110809", false)
        ))
        #expect(output == [
            "Environment\n",
            "  terminal     Unknown\n",
            "  xtversion    WezTerm 20240203-110809\n",
            "  multiplexer  None detected\n",
            "  ssh          yes\n",
            "  color        truecolor\n",
            "  themes       all\n",
            "\n",
            "Clipboard\n",
            "  native       remote (pbcopy)\n",
            "  tmux         off\n",
            "  osc 52       supported\n",
            "  wrap         on\n",
            "  status       confirmed\n",
            "\n",
            "Issues (1)\n",
            "\n",
            "  ! terminal.wezterm-kitty  Shift+Enter can't insert a newline in WezTerm over SSH\n",
            "      Note: For this session, type `\\` and then press Enter. Grok can't negotiate the Kitty keyboard protocol over SSH yet. `enable_kitty_keyboard = true` applies only to local WezTerm sessions.\n",
        ].joined())
    }

    /// `unavailable_and_error_probes_do_not_create_false_issues`
    /// (doctor_format_tests.rs:380-427).
    @Test func unavailableAndErrorProbesDoNotCreateFalseIssues() {
        let terminal = TerminalContext(
            brand: .iterm2, envBrand: .iterm2, multiplexer: .tmux, tmuxVersion: "tmux 3.4"
        )
        let output = buildDoctor(makeSnapshot(
            terminal: terminal,
            tmux: TmuxProbeFacts(
                version: .unavailable,
                extendedKeys: .unavailable,
                setClipboard: .error("tmux server unreachable"),
                allowPassthroughSupport: .unavailable,
                allowPassthrough: .error("query failed"),
                controlMode: .unavailable,
                clientFeatures: .unavailable
            ),
            route: tmuxRoute, nativeTool: "pbcopy", osc52SinkActive: false,
            colorLevel: .trueColor, runtime: makeRuntime(nil, false)
        ))
        #expect(output == [
            "Environment\n",
            "  terminal     iTerm2\n",
            "  multiplexer  tmux\n",
            "  ssh          no\n",
            "  color        truecolor\n",
            "  themes       all\n",
            "\n",
            "Clipboard\n",
            "  native       local (pbcopy)\n",
            "  tmux         on\n",
            "  osc 52       supported\n",
            "  wrap         off\n",
            "  status       confirmed\n",
            "\n",
            "No issues found.\n",
        ].joined())
    }

    /// `vscode_newline_output_is_platform_neutral` (doctor_format_tests.rs:429-472).
    @Test func vscodeNewlineOutputIsPlatformNeutral() {
        let terminal = TerminalContext(brand: .vsCode, envBrand: .vsCode)
        let output = buildDoctor(makeSnapshot(
            terminal: terminal, tmux: .unavailable, route: localRoute,
            nativeTool: "pbcopy", osc52SinkActive: false,
            colorLevel: .trueColor, runtime: makeRuntime(nil, false)
        ))
        #expect(output == [
            "Environment\n",
            "  terminal     VS Code\n",
            "  multiplexer  None detected\n",
            "  ssh          no\n",
            "  color        truecolor\n",
            "  themes       all\n",
            "  newline      Alt+Enter (VS Code: xterm.js can't distinguish Shift+Enter)\n",
            "\n",
            "Clipboard\n",
            "  native       local (pbcopy)\n",
            "  tmux         off\n",
            "  osc 52       off\n",
            "  wrap         off\n",
            "  status       confirmed\n",
            "\n",
            "No issues found.\n",
            "\n",
            "Recommendations\n",
            "\n",
            "  i terminal.newline-fallback  Shift+Enter can't insert a newline in this xterm.js terminal\n",
            "      Note: Use Alt+Enter to insert a newline in VS Code. xterm.js sends Shift+Enter as Enter in this setup.\n",
        ].joined())
    }

    /// `legacy_fact_only_clipboard_issue_never_claims_no_issues`
    /// (doctor_format_tests.rs:594-611).
    @Test func legacyFactOnlyClipboardIssueNeverClaimsNoIssues() {
        var report = diagnosticsView(makeSnapshot(
            terminal: ghostty(false), tmux: .unavailable, route: localRoute,
            nativeTool: "pbcopy", osc52SinkActive: false,
            colorLevel: .trueColor, runtime: makeRuntime(nil, true)
        ))
        report.facts.clipboard.delivery = .failed
        #expect(report.issueCount == 1)
        let output = formatDoctor(report)
        #expect(output.contains("An issue is shown in the Clipboard status above."))
        #expect(!output.contains("No issues found."))
    }

    /// `keyboard_fact_formats_from_explicit_target_evidence`
    /// (doctor_format_tests.rs:613-683).
    @Test func keyboardFactFormatsFromExplicitTargetEvidence() {
        let report = DiagnosticReport(
            facts: DiagnosticFacts(
                terminal: .wezTerm,
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
                color: ColorFacts(level: .available(.trueColor), availableThemes: ThemeKind.all, totalThemes: ThemeKind.all.count),
                keyboard: KeyboardFact(
                    modifierDelivery: ModifierDelivery(cmd: .dropped, opt: .native),
                    os: .macos
                ),
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
        #expect(formatDoctor(report) == [
            "Environment\n",
            "  terminal     WezTerm\n",
            "  multiplexer  None detected\n",
            "  ssh          no\n",
            "  color        truecolor\n",
            "  themes       all\n",
            "  keyboard     cmd=dropped, opt=native (OS rescue active)\n",
            "\n",
            "Clipboard\n",
            "  native       local (pbcopy)\n",
            "  tmux         off\n",
            "  osc 52       off\n",
            "  wrap         off\n",
            "  status       confirmed\n",
            "\n",
            "No issues found.\n",
        ].joined())
    }
}
