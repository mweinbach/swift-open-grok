// DiagnosticsViewTests.swift
//
// Diagnostics view tests, ported from
// `xai-grok-pager/src/diagnostics/view_tests.rs` at reference 650c1db7.
// Everything runs against injected snapshots — no live terminal, no tmux.

import Testing
import Foundation
@testable import OpenGrokDiagnostics

/// `ROUTE` (view_tests.rs:11-16).
private let fullRoute = ClipboardRoute(native: true, tmuxBuffer: true, osc52: true, osc52TmuxPassthrough: true)

private func makeSnapshot(
    terminal: TerminalContext,
    tmux: TmuxProbeFacts,
    runtime: DiagnosticRuntimeEvidence,
    osc52SinkActive: Bool,
    hostOs: HostOs = .macos,
    wayland: WaylandProbeFacts = WaylandProbeFacts(
        isWayland: false, dataControl: .unavailable, wlCopyAvailable: false
    ),
    displayServer: DisplayServer = .unknown,
    route: ClipboardRoute = fullRoute
) -> DiagnosticSnapshot {
    DiagnosticSnapshot(
        common: CommonProbeSnapshot(terminal: terminal, tmux: tmux, wayland: wayland),
        clipboard: ClipboardProbeFacts(route: route, nativeTool: "pbcopy", osc52SinkActive: osc52SinkActive),
        hostOs: hostOs,
        displayServer: displayServer,
        containerNoDisplay: false,
        colorLevel: .available(.trueColor),
        runtime: runtime
    )
}

private func makeRuntime(
    kittyFlagsPushed: RuntimeEvidence<Bool>,
    xtversion: RuntimeEvidence<String?>
) -> DiagnosticRuntimeEvidence {
    DiagnosticRuntimeEvidence(
        fullscreenActive: .available(true),
        kittyFlagsPushed: kittyFlagsPushed,
        xtversion: xtversion
    )
}

private func availableRuntime() -> DiagnosticRuntimeEvidence {
    makeRuntime(kittyFlagsPushed: .available(false), xtversion: .available(nil))
}

/// `plain_tmux` (view_tests.rs:406-416).
private func plainTmux() -> TmuxProbeFacts {
    TmuxProbeFacts(
        version: .unavailable,
        extendedKeys: .unavailable,
        setClipboard: .available("on"),
        allowPassthroughSupport: .available(true),
        allowPassthrough: .available("on"),
        controlMode: .available(false),
        clientFeatures: .unavailable
    )
}

@Suite("Diagnostics view")
struct DiagnosticsViewTests {
    /// `warning_category_ids_are_stable` (view_tests.rs:124-162).
    @Test func warningCategoryIDsAreStable() {
        let categories: [WarningCategory] = [
            .clipboard, .dcsPassthrough, .controlMode, .byobuScreen,
            .unsupportedTerminal, .tmuxExtendedKeysOff, .waylandNoDataControl,
            .wezTermKittyKeyboardOff, .limitedColorSupport, .sshWithoutWrap,
            .notificationProtocolFallback, .focusTrackingUnavailable,
            .sandboxProfileConflict,
        ]
        let ids = categories.map { idFor($0)!.description }
        #expect(ids == [
            "terminal.tmux-clipboard",
            "terminal.dcs-passthrough",
            "terminal.control-mode",
            "terminal.byobu-screen",
            "terminal.unsupported-emulator",
            "terminal.tmux-extended-keys",
            "terminal.wayland-data-control",
            "terminal.wezterm-kitty",
            "terminal.limited-color",
            "terminal.ssh-wrap",
            "notifications.protocol-fallback",
            "notifications.focus-tracking-unavailable",
            "sandbox.profile-conflict",
        ])
        #expect(idFor(.tmuxColorReduced)?.description == "terminal.tmux-truecolor")
    }

    /// `findings_have_stable_semantic_ids_and_dispositions` (view_tests.rs:164-233).
    @Test func findingsHaveStableSemanticIDsAndDispositions() {
        let terminal = TerminalContext(
            brand: .iterm2, envBrand: .iterm2, multiplexer: .tmux, isSSH: true
        )
        let report = diagnosticsView(makeSnapshot(
            terminal: terminal,
            tmux: TmuxProbeFacts(
                version: .unavailable,
                extendedKeys: .unavailable,
                setClipboard: .available("off"),
                allowPassthroughSupport: .available(true),
                allowPassthrough: .available("on"),
                controlMode: .available(false),
                clientFeatures: .unavailable
            ),
            runtime: availableRuntime(),
            osc52SinkActive: false
        ))

        let observed = report.findings.map { ($0.id, $0.disposition) }
        #expect(observed.count == 3)
        #expect(observed[0].0 == DiagnosticId("terminal", "tmux-clipboard"))
        #expect(observed[0].1 == .issue)
        #expect(observed[1].0 == iterm2ClipboardPermissionID)
        #expect(observed[1].1 == .recommendation)
        #expect(observed[2].0 == DiagnosticId("terminal", "ssh-wrap"))
        #expect(observed[2].1 == .recommendation)

        #expect(report.facts.clipboard.delivery == .confirmed)
        #expect(report.facts.clipboard.nativePreflight == .remoteOnly)
        let sshWrap = report.findings.first { $0.id == sshWrapID }
        #expect(sshWrap?.automaticRemediation == sshWrapAutomaticRemediation())
        #expect(report.findings[0].automaticRemediation
            == automaticRemediationFor(DiagnosticId("terminal", "tmux-clipboard")))
    }

    /// `all_tmux_finding_metadata_uses_stable_automatic_fix_ids_without_schema_changes`
    /// (view_tests.rs:235-305).
    @Test func tmuxFindingMetadataUsesStableAutomaticFixIDs() {
        var terminal = TerminalContext(
            brand: .iterm2, envBrand: .iterm2, multiplexer: .tmux,
            tmuxVersion: "tmux 3.4", tmuxExtendedKeys: "off"
        )
        let report = diagnosticsView(makeSnapshot(
            terminal: terminal,
            tmux: TmuxProbeFacts(
                version: .available("tmux 3.4"),
                extendedKeys: .available("off"),
                setClipboard: .available("off"),
                allowPassthroughSupport: .available(true),
                allowPassthrough: .available("off"),
                controlMode: .available(false),
                clientFeatures: .unavailable
            ),
            runtime: availableRuntime(),
            osc52SinkActive: false
        ))

        let automatic = report.findings.compactMap(\.automaticRemediation).map { ($0.fixID, $0.command) }
        #expect(automatic.count == 3)
        #expect(automatic[0].0 == tmuxClipboardID)
        #expect(automatic[0].1 == "grok doctor fix terminal.tmux-clipboard")
        #expect(automatic[1].0 == dcsPassthroughID)
        #expect(automatic[1].1 == "grok doctor fix terminal.dcs-passthrough")
        #expect(automatic[2].0 == tmuxExtendedKeysID)
        #expect(automatic[2].1 == "grok doctor fix terminal.tmux-extended-keys")

        terminal.tmuxExtendedKeys = "on"
        let healthy = diagnosticsView(makeSnapshot(
            terminal: terminal,
            tmux: TmuxProbeFacts(
                version: .available("tmux 3.4"),
                extendedKeys: .available("on"),
                setClipboard: .available("external"),
                allowPassthroughSupport: .available(true),
                allowPassthrough: .available("all"),
                controlMode: .available(false),
                clientFeatures: .unavailable
            ),
            runtime: availableRuntime(),
            osc52SinkActive: false
        ))
        for id in [tmuxClipboardID, dcsPassthroughID, tmuxExtendedKeysID] {
            #expect(healthy.findings.allSatisfy { $0.id != id })
        }
    }

    /// `unavailable_runtime_evidence_is_honest_and_fail_open` (view_tests.rs:307-357).
    @Test func unavailableRuntimeEvidenceIsHonestAndFailOpen() {
        let terminal = TerminalContext(brand: .wezTerm, envBrand: .wezTerm, multiplexer: .tmux)
        let report = diagnosticsView(makeSnapshot(
            terminal: terminal,
            tmux: TmuxProbeFacts(
                version: .unavailable,
                extendedKeys: .unavailable,
                setClipboard: .available("on"),
                allowPassthroughSupport: .available(true),
                allowPassthrough: .available("on"),
                controlMode: .available(true),
                clientFeatures: .unavailable
            ),
            runtime: .unavailable,
            osc52SinkActive: true
        ))

        #expect(!report.findings.contains { $0.id == DiagnosticId("terminal", "wezterm-kitty") })
        let controlMode = report.findings.first { $0.id == DiagnosticId("terminal", "control-mode") }
        #expect(controlMode?.message == "Display may be limited in tmux control mode")
        #expect(report.probeNotes.filter { $0.probe.hasPrefix("runtime.") }.count == 3)
    }

    /// `unavailable_and_error_probe_evidence_is_retained_without_findings`
    /// (view_tests.rs:359-404).
    @Test func unavailableAndErrorProbeEvidenceRetainedWithoutFindings() {
        let terminal = TerminalContext(brand: .iterm2, envBrand: .iterm2, multiplexer: .tmux)
        let report = diagnosticsView(makeSnapshot(
            terminal: terminal,
            tmux: TmuxProbeFacts(
                version: .unavailable,
                extendedKeys: .unavailable,
                setClipboard: .error("server unreachable"),
                allowPassthroughSupport: .unsupported,
                allowPassthrough: .unavailable,
                controlMode: .unavailable,
                clientFeatures: .unavailable
            ),
            runtime: availableRuntime(),
            osc52SinkActive: true,
            wayland: WaylandProbeFacts(isWayland: true, dataControl: .unavailable, wlCopyAvailable: false)
        ))

        #expect(report.findings.isEmpty)
        #expect(report.facts.clipboard.delivery == .confirmed)
        #expect(report.probeNotes.count == 7)
        #expect(report.probeNotes[0].probe == "tmux.version")
        #expect(report.probeNotes[1].probe == "tmux.extended-keys")
        #expect(report.probeNotes[2].status == .error)
        #expect(report.probeNotes[2].message == "server unreachable")
        #expect(report.probeNotes[3].status == .unsupported)
        #expect(report.probeNotes[4].probe == "tmux.control-mode")
        #expect(report.probeNotes[5].probe == "tmux.client-features")
        #expect(report.probeNotes[6].probe == "wayland.data-control")
    }

    /// `local_wezterm_without_kitty_evidence_has_no_alt_enter_fallback`
    /// (view_tests.rs:418-442).
    @Test func localWeztermWithoutKittyEvidenceHasNoAltEnterFallback() {
        let terminal = TerminalContext(brand: .wezTerm, envBrand: .wezTerm)
        let report = diagnosticsView(makeSnapshot(
            terminal: terminal,
            tmux: plainTmux(),
            runtime: makeRuntime(kittyFlagsPushed: .unavailable, xtversion: .available(nil)),
            osc52SinkActive: true
        ))
        #expect(report.facts.newline == nil)
        #expect(!report.findings.contains { $0.id == DiagnosticId("terminal", "wezterm-kitty") })
    }

    /// `ssh_xtversion_wezterm_without_kitty_evidence_has_no_alt_enter_fallback`
    /// (view_tests.rs:444-467).
    @Test func sshXtversionWeztermWithoutKittyEvidenceHasNoAltEnterFallback() {
        let terminal = TerminalContext(isSSH: true)
        let report = diagnosticsView(makeSnapshot(
            terminal: terminal,
            tmux: plainTmux(),
            runtime: makeRuntime(kittyFlagsPushed: .unavailable, xtversion: .available("WezTerm 20240203")),
            osc52SinkActive: true
        ))
        #expect(report.facts.newline == nil)
        #expect(!report.findings.contains { $0.id == DiagnosticId("terminal", "wezterm-kitty") })
    }

    /// `non_wezterm_without_kitty_evidence_keeps_ordinary_fallback`
    /// (view_tests.rs:469-504).
    @Test func nonWeztermWithoutKittyEvidenceKeepsOrdinaryFallback() {
        let terminal = TerminalContext(brand: .vsCode, envBrand: .vsCode)
        let report = diagnosticsView(makeSnapshot(
            terminal: terminal,
            tmux: plainTmux(),
            runtime: makeRuntime(kittyFlagsPushed: .unavailable, xtversion: .available(nil)),
            osc52SinkActive: true
        ))
        #expect(report.facts.newline == .xtermJs(terminal: .vsCode))
        let finding = report.findings.first { $0.id == newlineFallbackID }
        #expect(finding?.disposition == .recommendation)
        #expect(finding?.note?.contains("Alt+Enter") == true)
    }

    /// `clipboard_delivery_findings_own_remediation_while_fix_fact_stays_compatible`
    /// (view_tests.rs:506-579).
    @Test func clipboardDeliveryFindingsOwnRemediation() {
        struct Case {
            var terminal: TerminalContext
            var hostOs: HostOs
            var displayServer: DisplayServer
            var route: ClipboardRoute
            var delivery: ClipboardDelivery
            var id: DiagnosticId
            var compatibleFix: String
        }
        let cases = [
            Case(
                terminal: TerminalContext(isSSH: true),
                hostOs: .linux,
                displayServer: .unknown,
                route: ClipboardRoute(native: true, tmuxBuffer: false, osc52: true, osc52TmuxPassthrough: false),
                delivery: .unverified,
                id: clipboardDeliveryUnverifiedID,
                compatibleFix: "grok wrap <ssh command> or /minimal"
            ),
            Case(
                terminal: TerminalContext(brand: .vte, envBrand: .vte),
                hostOs: .other,
                displayServer: .unknown,
                route: ClipboardRoute(native: false, tmuxBuffer: false, osc52: false, osc52TmuxPassthrough: false),
                delivery: .failed,
                id: clipboardDeliveryUnavailableID,
                compatibleFix: "/minimal"
            ),
        ]
        for testCase in cases {
            let report = diagnosticsView(makeSnapshot(
                terminal: testCase.terminal,
                tmux: plainTmux(),
                runtime: makeRuntime(kittyFlagsPushed: .available(true), xtversion: .available(nil)),
                osc52SinkActive: false,
                hostOs: testCase.hostOs,
                displayServer: testCase.displayServer,
                route: testCase.route
            ))
            #expect(report.facts.clipboard.delivery == testCase.delivery)
            #expect(report.facts.clipboard.fix == testCase.compatibleFix)
            let finding = report.findings.first { $0.id == testCase.id }
            #expect(finding != nil)
            #expect(finding?.note?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            #expect(!formatDoctor(report).contains("  fix          "))
        }
    }

    /// `iterm2_and_vscode_clipboard_caveats_are_named_recommendations`
    /// (view_tests.rs:581-663).
    @Test func iterm2AndVSCodeClipboardCaveatsAreNamedRecommendations() {
        let cases: [(TerminalName, DiagnosticId, String)] = [
            (.iterm2, iterm2ClipboardPermissionID, "Settings"),
            (.vsCode, vscodeSSHNonASCIIID, "/minimal"),
            (.cursor, vscodeSSHNonASCIIID, "/minimal"),
            (.windsurf, vscodeSSHNonASCIIID, "/minimal"),
            (.zed, vscodeSSHNonASCIIID, "/minimal"),
        ]
        for (brand, id, expectedGuidance) in cases {
            let terminal = TerminalContext(brand: brand, envBrand: brand, isSSH: true)
            let report = diagnosticsView(makeSnapshot(
                terminal: terminal,
                tmux: plainTmux(),
                runtime: makeRuntime(kittyFlagsPushed: .available(true), xtversion: .available(nil)),
                osc52SinkActive: false,
                hostOs: .linux
            ))
            let finding = report.findings.first { $0.id == id }
            #expect(finding?.disposition == .recommendation, "\(brand)")
            #expect(finding?.note?.contains(expectedGuidance) == true, "\(brand)")
        }

        let ghostty = TerminalContext(brand: .ghostty, envBrand: .ghostty, isSSH: true)
        let report = diagnosticsView(makeSnapshot(
            terminal: ghostty,
            tmux: plainTmux(),
            runtime: makeRuntime(kittyFlagsPushed: .available(true), xtversion: .available(nil)),
            osc52SinkActive: false,
            hostOs: .linux
        ))
        #expect(report.findings.allSatisfy { $0.id != vscodeSSHNonASCIIID })
    }

    /// `available_wezterm_evidence_retains_finding_and_backslash_note`
    /// (view_tests.rs:665-686).
    @Test func availableWeztermEvidenceRetainsFindingAndBackslashNote() {
        let terminal = TerminalContext(brand: .wezTerm, envBrand: .wezTerm)
        let report = diagnosticsView(makeSnapshot(
            terminal: terminal, tmux: plainTmux(), runtime: availableRuntime(), osc52SinkActive: true
        ))
        #expect(report.facts.newline == nil)
        let finding = report.findings.first { $0.id == DiagnosticId("terminal", "wezterm-kitty") }
        #expect(finding?.note?.contains("type `\\` and then press Enter") == true)
    }

    /// `keyboard_fact_and_formatter_use_snapshot_host` (view_tests.rs:688-721),
    /// pinned to both hosts rather than the ambient one — the snapshot host
    /// is injected, so both sides are testable everywhere.
    @Test func keyboardFactAndFormatterUseSnapshotHost() {
        let terminal = TerminalContext(brand: .wezTerm, envBrand: .wezTerm)
        for host in [HostOs.macos, HostOs.linux] {
            let report = diagnosticsView(makeSnapshot(
                terminal: terminal,
                tmux: plainTmux(),
                runtime: makeRuntime(kittyFlagsPushed: .available(true), xtversion: .available(nil)),
                osc52SinkActive: true,
                hostOs: host
            ))
            let output = formatDoctor(report)
            if host == .macos {
                #expect(report.facts.keyboard?.os == .macos)
                #expect(output.contains("(OS rescue active)"))
            } else {
                #expect(report.facts.keyboard == nil)
                #expect(!output.contains("  keyboard     "))
            }
        }
    }

    /// `client_features_decide_color_passthrough` (view_tests.rs:726-771).
    @Test func clientFeaturesDecideColorPassthrough() {
        let cases: [(TmuxProbeResult<String>, TmuxColorPassthrough)] = [
            (.available("bpaste,ccolour,clipboard,cstyle,focus,RGB,title"), .forwarded),
            (.available("RGB"), .forwarded),
            (.available("bpaste,ccolour,clipboard,cstyle,focus,title"), .reduced),
            (.available(""), .unknown),
            (.available("   "), .unknown),
            (.unsupported, .unknown),
            (.unavailable, .unknown),
            (.error("tmux unreachable"), .unknown),
        ]
        for (result, expected) in cases {
            #expect(tmuxColorPassthroughFact(result) == expected)
        }
    }
}

@Suite("Standalone snapshot")
struct StandaloneSnapshotTests {
    /// `fake_standalone_facts_compose_through_shared_view`
    /// (doctor_cmd/tests.rs:217-257).
    @Test func fakeStandaloneFactsComposeThroughSharedView() {
        let terminal = TerminalContext(brand: .iterm2, envBrand: .iterm2, multiplexer: .tmux)
        let snapshot = collectStandaloneFrom(
            terminal: terminal,
            tmux: TmuxProbeFacts(
                version: .unavailable,
                extendedKeys: .unavailable,
                setClipboard: .available("off"),
                allowPassthroughSupport: .available(true),
                allowPassthrough: .available("on"),
                controlMode: .available(false),
                clientFeatures: .unavailable
            ),
            wayland: WaylandProbeFacts(isWayland: false, dataControl: .unavailable, wlCopyAvailable: false),
            nativeTool: "pbcopy",
            route: ClipboardRoute(native: true, tmuxBuffer: true, osc52: true, osc52TmuxPassthrough: true),
            osc52SinkActive: true,
            hostOs: .macos,
            displayServer: .unknown,
            containerNoDisplay: false,
            colorLevel: .available(.trueColor)
        )
        let report = DiagnosticsEngine.report(snapshot: DiagnosticSnapshot(standalone: snapshot))

        #expect(report.issueCount == 1)
        #expect(report.findings.allSatisfy { $0.id != DiagnosticId("terminal", "control-mode") })
        #expect(report.findings.first?.id == DiagnosticId("terminal", "tmux-clipboard"))
    }

    /// `standalone_runtime_and_tmux_are_unavailable_without_false_wezterm_finding`
    /// (doctor_cmd/tests.rs:374-448).
    @Test func standaloneRuntimeAndTmuxUnavailableWithoutFalseWeztermFinding() {
        let terminal = TerminalContext(brand: .wezTerm, envBrand: .wezTerm, multiplexer: .tmux)
        let snapshot = collectStandaloneFrom(
            terminal: terminal,
            tmux: .unavailable,
            wayland: WaylandProbeFacts(isWayland: false, dataControl: .unavailable, wlCopyAvailable: false),
            nativeTool: "pbcopy",
            route: ClipboardRoute(native: true, tmuxBuffer: false, osc52: false, osc52TmuxPassthrough: false),
            osc52SinkActive: true,
            hostOs: .macos,
            displayServer: .unknown,
            containerNoDisplay: false,
            colorLevel: .available(.trueColor)
        )
        let report = DiagnosticsEngine.report(snapshot: DiagnosticSnapshot(standalone: snapshot))

        #expect(report.findings.allSatisfy {
            $0.id != DiagnosticId("terminal", "wezterm-kitty")
                && $0.id != DiagnosticId("terminal", "control-mode")
        })
        #expect(report.facts.xtversion == .unavailable)
        #expect(report.probeNotes.filter { $0.probe.hasPrefix("tmux.") }.map(\.probe) == [
            "tmux.version",
            "tmux.extended-keys",
            "tmux.set-clipboard",
            "tmux.allow-passthrough-support",
            "tmux.control-mode",
            "tmux.client-features",
        ])
        let runtimeNotes = report.probeNotes.filter { $0.probe.hasPrefix("runtime.") }
        let expectedRuntimeNotes = [
            ProbeNote(probe: "runtime.fullscreen-active", status: .unavailable, message: nil),
            ProbeNote(probe: "runtime.kitty-flags-pushed", status: .unavailable, message: nil),
            ProbeNote(probe: "runtime.xtversion", status: .unavailable, message: nil),
        ]
        #expect(runtimeNotes == expectedRuntimeNotes)
        #expect(runtimeNotes.allSatisfy(probeRequiresLiveTUI))
        #expect(report.probeNotes.filter { $0.probe.hasPrefix("tmux.") }.allSatisfy { !probeRequiresLiveTUI($0) })
    }

    /// `standalone_wayland_missing_is_issue_but_no_seats_or_errors_are_not`
    /// (doctor_cmd/tests.rs:260-315).
    @Test func standaloneWaylandMissingIsIssueButUnavailableAndErrorAreNot() {
        let terminal = TerminalContext()
        let cases: [TmuxProbeResult<Bool>] = [
            .available(false),
            .unavailable,
            .error("probe worker died"),
        ]
        for dataControl in cases {
            let snapshot = collectStandaloneFrom(
                terminal: terminal,
                tmux: .unavailable,
                wayland: WaylandProbeFacts(isWayland: true, dataControl: dataControl, wlCopyAvailable: false),
                nativeTool: "arboard",
                route: ClipboardRoute(native: true, tmuxBuffer: false, osc52: false, osc52TmuxPassthrough: false),
                osc52SinkActive: false,
                hostOs: .macos,
                displayServer: .wayland,
                containerNoDisplay: false,
                colorLevel: .available(.trueColor)
            )
            let report = DiagnosticsEngine.report(snapshot: DiagnosticSnapshot(standalone: snapshot))
            let hasIssue = report.findings.contains { $0.id == DiagnosticId("terminal", "wayland-data-control") }
            switch report.facts.clipboard.dataControl {
            case .missing:
                #expect(hasIssue)
            case .unavailable:
                #expect(!hasIssue)
                #expect(report.probeNotes.first { $0.probe == "wayland.data-control" }?.message == nil)
            case .error:
                #expect(!hasIssue)
                #expect(report.probeNotes.first { $0.probe == "wayland.data-control" }?.message == "probe worker died")
            default:
                Issue.record("unexpected data-control fact: \(report.facts.clipboard.dataControl)")
            }
        }
    }
}

@Suite("Env detection")
struct EnvDetectionTests {
    /// Standalone context is env-only (`standalone_terminal_context`,
    /// terminal/mod.rs:639-650) — brand, multiplexer, Byobu, SSH, VS Code
    /// remote all from the injected map, no subprocess.
    @Test func standaloneContextDetectsFromEnvOnly() {
        let ctx = standaloneTerminalContext(
            environment: [
                "TERM_PROGRAM": "ghostty",
                "TERM": "xterm-ghostty",
                "SSH_CONNECTION": "1.2.3.4 1 5.6.7.8 22",
            ],
            host: .macos
        )
        #expect(ctx.brand == .ghostty)
        #expect(ctx.multiplexer == .undetected)
        #expect(ctx.isSSH)
        #expect(!ctx.isOfficialVSCodeRemote)
        #expect(ctx.tmuxVersion == nil, "standalone context must not shell out for tmux facts")

        let tmux = standaloneTerminalContext(
            environment: [
                "TMUX": "/tmp/tmux-501/default,12345,0",
                "TMUX_PANE": "%0",
                "TERM": "screen-256color",
            ],
            host: .macos
        )
        #expect(tmux.multiplexer == .tmux)
        #expect(tmux.tmuxMeta.tmuxEnv == "/tmp/tmux-501/default,12345,0")
        #expect(tmux.tmuxMeta.tmuxPane == "%0")

        let byobuScreen = standaloneTerminalContext(
            environment: ["BYOBU_BACKEND": "screen", "STY": "1234.pts-0.host"],
            host: .linux
        )
        #expect(byobuScreen.byobu == .screen)
        #expect(byobuScreen.multiplexer == .screen)

        let vscodeRemote = standaloneTerminalContext(
            environment: [
                "SSH_CONNECTION": "1.2.3.4 1 5.6.7.8 22",
                "VSCODE_GIT_ASKPASS_MAIN": "/home/user/.vscode-server/bin/x/askpass-main.js",
            ],
            host: .linux
        )
        #expect(vscodeRemote.isOfficialVSCodeRemote)
        #expect(vscodeRemote.brand == .vsCode)
    }

    /// Windows refinement (`refine_unknown_brand_for_host`, terminal/mod.rs:831-837).
    @Test func unknownBrandRefinesToWindowsTerminalOnWindowsOnly() {
        #expect(standaloneTerminalContext(environment: [:], host: .windows).brand == .windowsTerminal)
        #expect(standaloneTerminalContext(environment: [:], host: .macos).brand == .unknown)
        // env_brand keeps the raw detection for fail-closed consumers.
        #expect(standaloneTerminalContext(environment: [:], host: .windows).envBrand == .unknown)
    }

    /// `standalone_from_env` color evidence (color_support.rs:170-201).
    @Test func standaloneColorEvidenceMatrix() {
        #expect(standaloneColorEvidence(
            environment: ["NO_COLOR": ""], stderrIsTerminal: false,
            controllingTerminal: false, terminal: .unknown
        ) == .available(.none))
        #expect(standaloneColorEvidence(
            environment: [:], stderrIsTerminal: false,
            controllingTerminal: false, terminal: .ghostty
        ) == .unavailable)
        #expect(standaloneColorEvidence(
            environment: ["COLORTERM": "truecolor", "TERM": "xterm"], stderrIsTerminal: true,
            controllingTerminal: false, terminal: .unknown
        ) == .available(.trueColor))
        #expect(standaloneColorEvidence(
            environment: ["TERM": "xterm"], stderrIsTerminal: true,
            controllingTerminal: false, terminal: .ghostty
        ) == .available(.trueColor))
        #expect(standaloneColorEvidence(
            environment: ["TERM": "xterm-256color"], stderrIsTerminal: true,
            controllingTerminal: false, terminal: .unknown
        ) == .available(.ansi256))
        #expect(standaloneColorEvidence(
            environment: ["TERM": "dumb"], stderrIsTerminal: true,
            controllingTerminal: false, terminal: .unknown
        ) == .unavailable)
        #expect(standaloneColorEvidence(
            environment: ["TERM": "xterm"], stderrIsTerminal: true,
            controllingTerminal: false, terminal: .unknown
        ) == .available(.basic))
    }
}
