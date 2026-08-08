// DoctorFixTests.swift
//
// Fix engine tests, ported from
// `xai-grok-pager/src/diagnostics/fix_tests.rs` at reference 650c1db7.
//
// Security contract under test (AGENTS.md §5): every write lands in an
// isolated temp HOME, the managed-block bytes are asserted on the REAL file
// after `applyFix`, the fail-closed path guard rejects `..`/`~`/relative
// homes, and ssh-wrap planning refuses SSH/remote sessions. No
// status-returning call is discarded.

import Testing
import Foundation
@testable import OpenGrokDiagnostics

private struct TempHome {
    let path: String

    init() throws {
        let base = NSTemporaryDirectory() + "doctor-fix-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        self.path = try absoluteLexical((base as NSString).resolvingSymlinksInPath)
    }

    func join(_ name: String) -> String { path + "/" + name }

    func destroy() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// `report()` (fix_tests.rs:7-60).
private func sshWrapReport() -> DiagnosticReport {
    var report = DiagnosticReport(
        facts: DiagnosticFacts(
            terminal: .ghostty,
            xtversion: .unavailable,
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
            color: ColorFacts(level: .unavailable, availableThemes: [], totalThemes: ThemeKind.all.count),
            keyboard: nil,
            newline: nil,
            clipboard: ClipboardFacts(
                nativeRoute: false,
                nativeTool: "none",
                nativePreflight: .disabled,
                tmuxRoute: false,
                osc52Route: false,
                osc52Capability: .unknown,
                wrapSink: false,
                displayServer: .unknown,
                containerNoDisplay: false,
                dataControl: .notApplicable,
                delivery: .failed,
                fix: nil
            ),
            voice: nil
        ),
        findings: [],
        probeNotes: []
    )
    report.findings.append(DiagnosticFinding(
        id: sshWrapID,
        disposition: .recommendation,
        message: "Use local SSH wrapping",
        remediation: ManualRemediation(fix: sshWrapOneOff, configPath: nil),
        automaticRemediation: sshWrapAutomaticRemediation(),
        note: nil
    ))
    return report
}

/// `terminal()` (fix_tests.rs:62-79).
private func localTerminal() -> TerminalContext {
    TerminalContext(
        brand: .ghostty,
        envBrand: .ghostty,
        multiplexer: .undetected,
        termVar: "xterm-256color"
    )
}

/// `request` (fix_tests.rs:81-83).
private func makeRequest(home: String, shell: String) throws -> FixRequest {
    try FixRequest(id: sshWrapID, home: home, shell: shell, validator: nil, byobuConfigDir: nil)
}

/// `tmux_terminal` (fix_tests.rs:141-149).
private func tmuxTerminal(byobu: Bool) -> TerminalContext {
    var terminal = localTerminal()
    terminal.multiplexer = .tmux
    terminal.byobu = byobu ? .tmux : nil
    terminal.tmuxVersion = "tmux 3.4"
    terminal.tmuxExtendedKeys = "off"
    return terminal
}

/// `tmux_report` (fix_tests.rs:151-196).
private func tmuxReport(id: DiagnosticId, evidence: TmuxEvidence) -> DiagnosticReport {
    var report = sshWrapReport()
    report.findings.removeAll()
    report.facts.multiplexer = .tmux
    report.facts.tmux = TmuxFacts(
        extendedKeys: .available(evidence == .extendedKeys ? "off" : "on"),
        setClipboard: .available(evidence == .clipboard ? "off" : "on"),
        allowPassthroughSupport: .supported,
        allowPassthrough: .available(evidence == .dcsPassthrough ? "off" : "on"),
        colorPassthrough: evidence == .colorPassthrough ? .reduced : .forwarded
    )
    report.findings.append(DiagnosticFinding(
        id: id,
        disposition: .issue,
        message: "tmux option disabled",
        remediation: nil,
        automaticRemediation: automaticRemediationFor(id),
        note: nil
    ))
    return report
}

/// `tmux_request` (fix_tests.rs:198-200).
private func tmuxRequest(home: String, id: DiagnosticId) throws -> FixRequest {
    try FixRequest(id: id, home: home, shell: nil, validator: nil, byobuConfigDir: nil)
}

@Suite("Fix registry")
struct FixRegistryTests {
    /// `canonical_and_short_ids_resolve_to_canonical_id` (fix_tests.rs:85-99).
    @Test func canonicalAndShortIDsResolveToCanonicalID() throws {
        #expect(try resolveFixID("terminal.ssh-wrap") == sshWrapID)
        let command = try #require(humanFixCommand(sshWrapID))
        #expect(command == "grok doctor fix ssh-wrap")
        #expect(try resolveFixID(String(command.dropFirst("grok doctor fix ".count))) == sshWrapID)
        #expect(humanFixCommand(DiagnosticId("terminal", "unknown")) == nil)
        #expect(throws: FixError.self) {
            try resolveFixID("terminal.unknown")
        }
    }

    /// `tmux_fix_registry_resolves_every_short_and_canonical_id`
    /// (fix_tests.rs:202-212).
    @Test func registryResolvesEveryShortAndCanonicalID() throws {
        for (id, handle, _) in automaticFixChoices() {
            #expect(try resolveFixID(handle) == id)
            #expect(try resolveFixID(id.description) == id)
            #expect(humanFixCommand(id) == "grok doctor fix \(handle)")
        }
    }

    /// `applicable_fix_listing_uses_report_metadata_and_planner_availability`
    /// (fix_tests.rs:101-139).
    @Test func applicableFixListingUsesReportMetadataAndPlannerAvailability() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let report = sshWrapReport()
        let local = localTerminal()
        let localFixes = applicableAutomaticFixes(report: report, terminal: local) { id in
            try FixRequest(id: id, home: temp.path, shell: "/bin/bash", validator: nil, byobuConfigDir: nil)
        }
        #expect(localFixes.count == 1)
        #expect(localFixes[0].0 == sshWrapID)
        #expect(localFixes[0].1 == "ssh-wrap")
        #expect(localFixes[0].2 == .here)

        var remote = local
        remote.isSSH = true
        let remoteFixes = applicableAutomaticFixes(report: report, terminal: remote) { _ in
            throw FixError.homeUnavailable
        }
        #expect(remoteFixes.count == 1)
        #expect(remoteFixes[0].2 == .runLocally)

        var manualOnly = report
        manualOnly.findings[0].automaticRemediation = nil
        #expect(applicableAutomaticFixes(report: manualOnly, terminal: local) { _ in
            throw FixError.homeUnavailable
        }.isEmpty)
    }
}

@Suite("Fail-closed path guard")
struct SafeDirectoryTests {
    /// `safe_absolute_directory_rejects_hostile_home_and_byobu_values`
    /// (fix_tests.rs:286-304).
    @Test func safeAbsoluteDirectoryRejectsHostileValues() {
        for value in [".", "..", "/", "relative", "/tmp/../escape", "/tmp/bad\nname", "~/x"] {
            do {
                _ = try SafeAbsoluteDirectory.parse(value, label: "HOME")
                Issue.record("expected rejection for \(value)")
            } catch let error as FixError {
                guard case .unsafeDirectory = error else {
                    Issue.record("expected unsafeDirectory for \(value), got \(error)")
                    continue
                }
            } catch {
                Issue.record("unexpected error type for \(value): \(error)")
            }
        }
        // The guard is also the FixRequest boundary: a hostile HOME never
        // reaches planning.
        #expect(throws: FixError.self) {
            try FixRequest(id: sshWrapID, home: "/tmp/../escape", shell: "/bin/bash", validator: nil, byobuConfigDir: nil)
        }
    }

    /// `reload_instruction_shell_quotes_and_markdown_escapes_paths`
    /// (fix_tests.rs:307-325).
    @Test func reloadInstructionShellQuotesAndMarkdownEscapesPaths() {
        #expect(reloadInstruction("/tmp/a b/q'v.conf")
            == "Reload tmux with `tmux source-file '/tmp/a b/q'\\''v.conf'`, or restart the tmux server.")
        #expect(reloadInstruction("/tmp/a`b.conf")
            == "Reload tmux with ``tmux source-file '/tmp/a`b.conf'``, or restart the tmux server.")
        #expect(shellQuotePath("/tmp/a`b.conf") == "'/tmp/a`b.conf'")
        #expect(reloadInstruction("/tmp/bad\npath")
            == "Reload your tmux config, or restart the tmux server, to activate the persistent setting.")
        #expect(markdownCodePath("/tmp/a`b") == "``/tmp/a`b``")
    }
}

@Suite("SSH wrap fix")
struct SSHWrapFixTests {
    /// `bash_zsh_and_fish_plans_use_exact_paths_and_aliases`
    /// (fix_tests.rs:713-746) — the managed block shape golden
    /// (fix_tests.rs:728-731).
    @Test func bashZshAndFishPlansUseExactPathsAndAliases() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let cases: [(String, String, String)] = [
            ("/bin/bash", ".bashrc", "alias ssh='open-grok wrap ssh'"),
            ("/bin/zsh", ".zshrc", "alias ssh='open-grok wrap ssh'"),
            ("/usr/local/bin/fish", ".config/fish/config.fish", "alias ssh 'open-grok wrap ssh'"),
        ]
        for (shell, relative, alias) in cases {
            let plan = try planFix(
                try makeRequest(home: temp.path, shell: shell),
                report: sshWrapReport(),
                terminal: localTerminal()
            )
            #expect(plan.id == sshWrapID)
            #expect(plan.change.requestedPath == temp.join(relative))
            #expect(plan.change.block
                == "# >>> grok doctor >>>\n# >>> terminal.ssh-wrap >>>\n\(alias)\n# <<< terminal.ssh-wrap <<<\n# <<< grok doctor <<<")
            #expect(plan.caveats.contains { $0.contains("command ssh") })
            #expect(plan.caveats.contains { $0.contains("ssh -f") })
            #expect(plan.caveats.contains { $0.contains("ControlPersist") })
            #expect(plan.caveats.contains { $0.contains("~^Z") })
        }
    }

    /// `remote_vscode_and_unsupported_shell_are_refused` (fix_tests.rs:748-768).
    @Test func remoteVSCodeAndUnsupportedShellAreRefused() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        var remote = localTerminal()
        remote.isSSH = true
        do {
            _ = try planFix(try makeRequest(home: temp.path, shell: "/bin/zsh"), report: sshWrapReport(), terminal: remote)
            Issue.record("expected RemoteSession")
        } catch let error as FixError {
            guard case .remoteSession = error else {
                Issue.record("expected remoteSession, got \(error)")
                return
            }
        }

        var vscode = localTerminal()
        vscode.isOfficialVSCodeRemote = true
        do {
            _ = try planFix(try makeRequest(home: temp.path, shell: "/bin/zsh"), report: sshWrapReport(), terminal: vscode)
            Issue.record("expected NotApplicable")
        } catch let error as FixError {
            guard case .notApplicable = error else {
                Issue.record("expected notApplicable, got \(error)")
                return
            }
        }

        do {
            _ = try planFix(try makeRequest(home: temp.path, shell: "/bin/tcsh"), report: sshWrapReport(), terminal: localTerminal())
            Issue.record("expected UnsupportedShell")
        } catch let error as FixError {
            guard case .unsupportedShell = error else {
                Issue.record("expected unsupportedShell, got \(error)")
                return
            }
        }

        // Remote evidence in the report alone (facts.ssh) also refuses.
        var reportSSH = sshWrapReport()
        reportSSH.facts.ssh = true
        do {
            _ = try planFix(try makeRequest(home: temp.path, shell: "/bin/zsh"), report: reportSSH, terminal: localTerminal())
            Issue.record("expected RemoteSession from report facts")
        } catch let error as FixError {
            guard case .remoteSession = error else {
                Issue.record("expected remoteSession, got \(error)")
                return
            }
        }
    }

    /// `existing_alias_and_function_conflicts_are_preserved` (fix_tests.rs:783-804).
    @Test func existingAliasAndFunctionConflictsArePreserved() throws {
        let cases: [(String, String, String)] = [
            ("/bin/bash", ".bashrc", "alias ssh='ssh -A'\n"),
            ("/bin/zsh", ".zshrc", "ssh() { command ssh -A \"$@\"; }\n"),
            ("/usr/bin/fish", ".config/fish/config.fish", "function ssh\n  command ssh -A $argv\nend\n"),
        ]
        for (shell, relative, content) in cases {
            let temp = try TempHome()
            defer { temp.destroy() }
            let path = temp.join(relative)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            do {
                _ = try planFix(try makeRequest(home: temp.path, shell: shell), report: sshWrapReport(), terminal: localTerminal())
                Issue.record("expected ExistingCustomization for \(shell)")
            } catch let error as FixError {
                guard case .existingCustomization = error else {
                    Issue.record("expected existingCustomization, got \(error)")
                    continue
                }
            }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == content, "refusal must not modify the file")
        }
    }

    /// `alias_and_fish_function_scanners_accept_shell_whitespace`
    /// (fix_tests.rs:806-843).
    @Test func aliasAndFishFunctionScannersAcceptShellWhitespace() {
        for declaration in ["alias  ssh='ssh -A'", "alias\tssh = 'ssh -A'", "alias \t ssh='ssh -A'"] {
            #expect(detectPOSIXSSHCustomization(declaration) != nil, "\(declaration)")
        }
        for declaration in [
            "alias  ssh 'ssh -A'", "alias\tssh='ssh -A'",
            "function  ssh", "function\tssh --description wrapped",
        ] {
            #expect(detectFishSSHCustomization(declaration) != nil, "\(declaration)")
        }
        for notSSH in ["aliases ssh='ssh -A'", "alias ssh_wrap='ssh -A'", "alias sshuttle='ssh -A'"] {
            #expect(detectPOSIXSSHCustomization(notSSH) == nil, "\(notSSH)")
            #expect(detectFishSSHCustomization(notSSH) == nil, "\(notSSH)")
        }
    }

    /// `posix_function_scanner_requires_exact_ssh_name_boundary`
    /// (fix_tests.rs:845-869).
    @Test func posixFunctionScannerRequiresExactSSHNameBoundary() {
        for declaration in [
            "function ssh { command ssh \"$@\"; }",
            "function ssh() { command ssh \"$@\"; }",
            "ssh() { command ssh \"$@\"; }",
            "ssh () { command ssh \"$@\"; }",
        ] {
            #expect(detectPOSIXSSHCustomization(declaration) != nil, "\(declaration)")
        }
        for notSSH in [
            "function ssh_wrap { :; }",
            "function sshuttle { :; }",
            "ssh_wrap() { :; }",
            "sshuttle () { :; }",
        ] {
            #expect(detectPOSIXSSHCustomization(notSSH) == nil, "\(notSSH)")
        }
    }

    /// `conflict_scan_uses_the_exact_validated_source_snapshot`
    /// (fix_tests.rs:871-888).
    @Test func conflictScanUsesTheExactValidatedSourceSnapshot() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".bashrc")
        try "export KEEP=1\n".write(toFile: path, atomically: true, encoding: .utf8)
        let plan = try planFix(try makeRequest(home: temp.path, shell: "/bin/bash"), report: sshWrapReport(), terminal: localTerminal())
        try "alias ssh='ssh -A'\n".write(toFile: path, atomically: true, encoding: .utf8)
        do {
            _ = try applyFix(plan)
            Issue.record("expected StalePlan")
        } catch let error as FixError {
            guard case .managed(.stalePlan) = error else {
                Issue.record("expected managed(stalePlan), got \(error)")
                return
            }
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "alias ssh='ssh -A'\n")
    }

    /// `non_utf8_source_fails_closed_before_conflict_policy` (fix_tests.rs:890-901).
    @Test func nonUTF8SourceFailsClosedBeforeConflictPolicy() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        try Data([0xFF]).write(to: URL(fileURLWithPath: temp.join(".zshrc")))
        do {
            _ = try planFix(try makeRequest(home: temp.path, shell: "/bin/zsh"), report: sshWrapReport(), terminal: localTerminal())
            Issue.record("expected managed unsafe-path failure")
        } catch let error as FixError {
            guard case .managed(.unsafePath) = error else {
                Issue.record("expected managed(unsafePath), got \(error)")
                return
            }
        }
    }

    /// `comments_and_managed_alias_do_not_create_false_conflicts`
    /// (fix_tests.rs:941-953) — idempotency: applying over an exact managed
    /// alias is AlreadyConfigured with no backup.
    @Test func commentsAndManagedAliasDoNotCreateFalseConflicts() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".zshrc")
        try "# alias ssh='ssh -A'\n# >>> grok doctor >>>\n# >>> terminal.ssh-wrap >>>\nalias ssh='open-grok wrap ssh'\n# <<< terminal.ssh-wrap <<<\n# <<< grok doctor <<<\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let plan = try planFix(try makeRequest(home: temp.path, shell: "/bin/zsh"), report: sshWrapReport(), terminal: localTerminal())
        let outcome = try applyFix(plan)
        #expect(outcome.status == .alreadyConfigured)
        #expect(outcome.backupPath == nil)
    }

    /// `managed_alias_with_later_unmanaged_conflict_is_not_configured`
    /// (fix_tests.rs:955-974).
    @Test func managedAliasWithLaterUnmanagedConflictIsNotConfigured() throws {
        let cases: [(ShellKind, String)] = [
            (.bash, "# >>> grok doctor >>>\n# >>> terminal.ssh-wrap >>>\nalias ssh='open-grok wrap ssh'\n# <<< terminal.ssh-wrap <<<\n# <<< grok doctor <<<\nalias ssh='ssh -A'\n"),
            (.fish, "# >>> grok doctor >>>\n# >>> terminal.ssh-wrap >>>\nalias ssh 'open-grok wrap ssh'\n# <<< terminal.ssh-wrap <<<\n# <<< grok doctor <<<\nfunction ssh\n  command ssh -A $argv\nend\n"),
        ]
        for (shell, content) in cases {
            let temp = try TempHome()
            defer { temp.destroy() }
            let path = shell.configPath(home: temp.path)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            #expect(!managedAliasConfigured(path: path, shell: shell))
        }
    }

    /// `stale_plan_is_rejected_and_apply_verifies_postcondition`
    /// (fix_tests.rs:977-998) — the apply-twice/one-block contract plus the
    /// managed-block bytes asserted on the real file.
    @Test func stalePlanIsRejectedAndApplyVerifiesPostcondition() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".bashrc")
        try "export KEEP=1\n".write(toFile: path, atomically: true, encoding: .utf8)
        let stale = try planFix(try makeRequest(home: temp.path, shell: "/bin/bash"), report: sshWrapReport(), terminal: localTerminal())
        try "export KEEP=2\n".write(toFile: path, atomically: true, encoding: .utf8)
        do {
            _ = try applyFix(stale)
            Issue.record("expected StalePlan")
        } catch let error as FixError {
            guard case .managed(.stalePlan) = error else {
                Issue.record("expected managed(stalePlan), got \(error)")
                return
            }
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "export KEEP=2\n")

        let plan = try planFix(try makeRequest(home: temp.path, shell: "/bin/bash"), report: sshWrapReport(), terminal: localTerminal())
        let outcome = try applyFix(plan)
        #expect(outcome.status == .applied)
        #expect(outcome.id == sshWrapID)
        #expect(outcome.shell == .bash)
        #expect(managedAliasConfigured(path: path, shell: .bash))
        #expect(outcome.managedAliasIsConfigured)

        // Managed-block byte equality on the real file (fix_tests.rs:728-731).
        #expect(try String(contentsOfFile: path, encoding: .utf8)
            == "export KEEP=2\n# >>> grok doctor >>>\n# >>> terminal.ssh-wrap >>>\nalias ssh='open-grok wrap ssh'\n# <<< terminal.ssh-wrap <<<\n# <<< grok doctor <<<\n")

        // Apply twice → still exactly one block, AlreadyConfigured.
        let secondPlan = try planFix(try makeRequest(home: temp.path, shell: "/bin/bash"), report: sshWrapReport(), terminal: localTerminal())
        let second = try applyFix(secondPlan)
        #expect(second.status == .alreadyConfigured)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.components(separatedBy: "# >>> grok doctor >>>").count - 1 == 1)
        #expect(content.components(separatedBy: "# >>> terminal.ssh-wrap >>>").count - 1 == 1)
    }

    /// `ssh_wrap_outcome_verifies_with_planned_shell_not_process_shell`
    /// (fix_tests.rs:1001-1029).
    @Test func sshWrapOutcomeVerifiesWithPlannedShellNotProcessShell() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".bashrc")
        let plan = try planFix(try makeRequest(home: temp.path, shell: "/bin/bash"), report: sshWrapReport(), terminal: localTerminal())
        let outcome = try applyFix(plan)
        #expect(outcome.shell == .bash)
        #expect(outcome.changedPath == path)
        #expect(outcome.managedAliasIsConfigured)

        // Fish uses a different alias syntax; checking the bash-written path
        // with fish must not count as configured.
        #expect(!managedAliasConfigured(path: path, shell: .fish))
        #expect(outcome.managedAliasIsConfigured, "outcome must keep the planned bash shell")

        let filtered = configuredReport(sshWrapReport(), configured: outcome.managedAliasIsConfigured)
        #expect(!filtered.findings.contains { $0.id == sshWrapID })
    }

    /// `configured_report_reaches_pass_state_only_for_exact_managed_alias`
    /// (fix_tests.rs:1032-1058).
    @Test func configuredReportReachesPassStateOnlyForExactManagedAlias() throws {
        var diagnostic = sshWrapReport()
        diagnostic = configuredReport(diagnostic, configured: false)
        #expect(diagnostic.findings.contains { $0.id == sshWrapID })
        diagnostic = configuredReport(diagnostic, configured: true)
        #expect(!diagnostic.findings.contains { $0.id == sshWrapID })

        let temp = try TempHome()
        defer { temp.destroy() }
        var healthy = sshWrapReport()
        healthy.findings.removeAll()
        let plan = try planFix(try makeRequest(home: temp.path, shell: "/bin/bash"), report: healthy, terminal: localTerminal())
        #expect(plan.id == sshWrapID, "healthy reports can plan idempotent setup")
    }

    /// `fix_preview_contains_exact_change_and_caveats` (doctor_cmd/tests.rs:527-549).
    @Test func fixPreviewContainsExactChangeAndCaveats() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let plan = try planFix(
            try makeRequest(home: temp.path, shell: "/bin/bash"),
            report: sshWrapReport(),
            terminal: localTerminal()
        )
        let preview = formatFixPreview(plan)
        #expect(preview.hasPrefix("Doctor Fix\n\nFix: terminal.ssh-wrap\nShell: bash\n"))
        #expect(preview.contains("File: "))
        #expect(preview.contains("# >>> grok doctor >>>\n# >>> terminal.ssh-wrap >>>\nalias ssh='open-grok wrap ssh'"))
        #expect(preview.contains("To use once without changing config: `open-grok wrap ssh <host>`"))
        #expect(preview.contains("Use `command ssh ...` to bypass the alias."))
        #expect(preview.contains("ssh -f"))
        #expect(preview.contains("ControlPersist"))
        #expect(preview.contains("~^Z"))
    }
}

@Suite("tmux option fixes")
struct TmuxOptionFixTests {
    /// `tmux_specs_plan_exact_independent_managed_items` (fix_tests.rs:242-283).
    @Test func tmuxSpecsPlanExactIndependentManagedItems() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let cases: [(DiagnosticId, TmuxEvidence, String)] = [
            (tmuxClipboardID, .clipboard, "set -g set-clipboard on"),
            (dcsPassthroughID, .dcsPassthrough, "set -wg allow-passthrough on"),
            (tmuxExtendedKeysID, .extendedKeys, "set -g extended-keys on"),
            (tmuxTruecolorID, .colorPassthrough, "set -as terminal-features \",*:RGB\""),
        ]
        for (id, evidence, line) in cases {
            let plan = try planFix(
                try tmuxRequest(home: temp.path, id: id),
                report: tmuxReport(id: id, evidence: evidence),
                terminal: tmuxTerminal(byobu: false)
            )
            #expect(plan.change.requestedPath == temp.join(".tmux.conf"))
            #expect(plan.change.block.contains("# >>> \(id) >>>\n\(line)\n# <<< \(id) <<<"))
            #expect(!plan.change.block.contains("terminal.ssh-wrap"))
            let preview = formatFixPreview(plan)
            #expect(preview.contains("does not reload or modify the live tmux server"))
            #expect(preview.contains("Run /doctor again to verify the live setting"))
        }
    }

    /// `tmux_managed_items_coexist_and_each_apply_is_one_transaction`
    /// (fix_tests.rs:402-448).
    @Test func tmuxManagedItemsCoexistAndEachApplyIsOneTransaction() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".tmux.conf")
        let cases: [(DiagnosticId, TmuxEvidence, String)] = [
            (tmuxClipboardID, .clipboard, "set -g set-clipboard on"),
            (dcsPassthroughID, .dcsPassthrough, "set -wg allow-passthrough on"),
            (tmuxExtendedKeysID, .extendedKeys, "set -g extended-keys on"),
            (tmuxTruecolorID, .colorPassthrough, "set -as terminal-features \",*:RGB\""),
        ]
        for (id, evidence, line) in cases {
            let plan = try planFix(
                try tmuxRequest(home: temp.path, id: id),
                report: tmuxReport(id: id, evidence: evidence),
                terminal: tmuxTerminal(byobu: false)
            )
            let outcome = try applyFix(plan)
            #expect(outcome.activation == .requiresReload)
            #expect(outcome.changedPath == path)
            #expect(formatFixSuccess(outcome).contains("Run /doctor again"))
            #expect(try String(contentsOfFile: path, encoding: .utf8).contains(line))
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.components(separatedBy: "# >>> grok doctor >>>").count - 1 == 1)
        for id in [tmuxClipboardID, dcsPassthroughID, tmuxExtendedKeysID, tmuxTruecolorID] {
            #expect(content.components(separatedBy: "# >>> \(id) >>>").count - 1 == 1)
        }
    }

    /// `tmux_plain_byobu_and_custom_config_paths_are_physical`
    /// (fix_tests.rs:356-399).
    @Test func tmuxPlainByobuAndCustomConfigPathsArePhysical() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let report = tmuxReport(id: tmuxClipboardID, evidence: .clipboard)
        let plain = try planFix(
            try tmuxRequest(home: temp.path, id: tmuxClipboardID),
            report: report,
            terminal: tmuxTerminal(byobu: false)
        )
        #expect(plain.change.requestedPath == temp.join(".tmux.conf"))
        #expect(!plain.change.requestedPath.contains("~"))

        let customDir = temp.join("custom-byobu")
        try FileManager.default.createDirectory(atPath: customDir, withIntermediateDirectories: true)
        let custom = try FixRequest(
            id: tmuxClipboardID, home: temp.path, shell: nil, validator: nil, byobuConfigDir: customDir
        )
        let byobu = try planFix(custom, report: report, terminal: tmuxTerminal(byobu: true))
        #expect(byobu.change.requestedPath == customDir + "/.tmux.conf")

        do {
            _ = try planFix(
                try tmuxRequest(home: temp.path, id: tmuxClipboardID),
                report: report,
                terminal: tmuxTerminal(byobu: true)
            )
            Issue.record("expected ByobuConfigUnavailable")
        } catch let error as FixError {
            guard case .byobuConfigUnavailable = error else {
                Issue.record("expected byobuConfigUnavailable, got \(error)")
                return
            }
        }
    }

    /// `tmux_fix_is_available_here_in_remote_sessions_while_ssh_wrap_stays_local_only`
    /// (fix_tests.rs:215-239).
    @Test func tmuxFixAvailableHereInRemoteSessions() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        var terminal = tmuxTerminal(byobu: false)
        terminal.isSSH = true
        var report = tmuxReport(id: tmuxClipboardID, evidence: .clipboard)
        report.facts.ssh = true
        let fixes = applicableAutomaticFixes(report: report, terminal: terminal) { id in
            try tmuxRequest(home: temp.path, id: id)
        }
        #expect(fixes.count == 1)
        #expect(fixes[0].0 == tmuxClipboardID)
        #expect(fixes[0].1 == "tmux-clipboard")
        #expect(fixes[0].2 == .here)
        #expect((try? planFix(
            try tmuxRequest(home: temp.path, id: tmuxClipboardID),
            report: report,
            terminal: terminal
        )) != nil)
    }

    /// `tmux_applicability_uses_exact_positive_probe_gates` (fix_tests.rs:614-657).
    @Test func tmuxApplicabilityUsesExactPositiveProbeGates() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let terminal = tmuxTerminal(byobu: false)

        var clipboard = tmuxReport(id: tmuxClipboardID, evidence: .clipboard)
        clipboard.facts.tmux.setClipboard = .available("external")
        #expect(throws: FixError.self) {
            try planFix(try tmuxRequest(home: temp.path, id: tmuxClipboardID), report: clipboard, terminal: terminal)
        }

        var dcs = tmuxReport(id: dcsPassthroughID, evidence: .dcsPassthrough)
        for support in [TmuxSupportFact.unsupported, .unavailable, .error] {
            dcs.facts.tmux.allowPassthroughSupport = support
            #expect(throws: FixError.self) {
                try planFix(try tmuxRequest(home: temp.path, id: dcsPassthroughID), report: dcs, terminal: terminal)
            }
        }

        var extended = tmuxReport(id: tmuxExtendedKeysID, evidence: .extendedKeys)
        extended.facts.tmux.extendedKeys = .unavailable
        #expect(throws: FixError.self) {
            try planFix(try tmuxRequest(home: temp.path, id: tmuxExtendedKeysID), report: extended, terminal: terminal)
        }
    }

    /// `tmux_stale_plan_and_idempotence_reuse_managed_writer_safety`
    /// (fix_tests.rs:660-710).
    @Test func tmuxStalePlanAndIdempotenceReuseManagedWriterSafety() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".tmux.conf")
        try "set -g mouse on\n".write(toFile: path, atomically: true, encoding: .utf8)
        let report = tmuxReport(id: tmuxClipboardID, evidence: .clipboard)
        let stale = try planFix(
            try tmuxRequest(home: temp.path, id: tmuxClipboardID), report: report, terminal: tmuxTerminal(byobu: false)
        )
        try "set -g mouse off\n".write(toFile: path, atomically: true, encoding: .utf8)
        do {
            _ = try applyFix(stale)
            Issue.record("expected tmuxManaged(stalePlan)")
        } catch let error as FixError {
            guard case .tmuxManaged(.stalePlan) = error else {
                Issue.record("expected tmuxManaged(stalePlan), got \(error)")
                return
            }
        }

        try "set -g set-clipboard on\n".write(toFile: path, atomically: true, encoding: .utf8)
        let plan = try planFix(
            try tmuxRequest(home: temp.path, id: tmuxClipboardID), report: report, terminal: tmuxTerminal(byobu: false)
        )
        let preview = formatFixPreview(plan)
        #expect(preview.contains("Text to add: None"), "\(preview)")
        #expect(!preview.contains("Backup will be saved"), "\(preview)")
        let outcome = try applyFix(plan)
        #expect(outcome.status == .alreadyConfigured)
        #expect(verifyPersistentFix(outcome))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "set -g set-clipboard on\n")

        let staleAfter = try planFix(
            try tmuxRequest(home: temp.path, id: tmuxClipboardID), report: report, terminal: tmuxTerminal(byobu: false)
        )
        try "set -g set-clipboard off\n".write(toFile: path, atomically: true, encoding: .utf8)
        do {
            _ = try applyFix(staleAfter)
            Issue.record("expected tmuxManaged(stalePlan) after direct edit")
        } catch let error as FixError {
            guard case .tmuxManaged(.stalePlan) = error else {
                Issue.record("expected tmuxManaged(stalePlan), got \(error)")
                return
            }
        }
    }

    /// `conflicting_direct_form_after_managed_block_fails_persistent_verification`
    /// (fix_tests.rs:562-585).
    @Test func conflictingDirectFormAfterManagedBlockFailsPersistentVerification() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".tmux.conf")
        for conflict in [
            "set set-clipboard off",
            "set -s set-clipboard off",
            "set-option -g set-clipboard off",
            "set -g mouse on; set -g set-clipboard off",
            "se -g set-clipboard off",
        ] {
            try "# >>> grok doctor >>>\n# >>> terminal.tmux-clipboard >>>\nset -g set-clipboard on\n# <<< terminal.tmux-clipboard <<<\n# <<< grok doctor <<<\n\(conflict)\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
            #expect(!tmuxOptionConfigured(path: path, spec: tmuxClipboardSpec), "\(conflict)")
        }
    }

    /// `healthy_direct_does_not_suppress_repair_of_noncanonical_managed_item`
    /// (fix_tests.rs:588-612).
    @Test func healthyDirectDoesNotSuppressRepairOfNoncanonicalManagedItem() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".tmux.conf")
        let report = tmuxReport(id: tmuxClipboardID, evidence: .clipboard)
        for content in [
            "set -g set-clipboard on\n# >>> grok doctor >>>\n# >>> terminal.tmux-clipboard >>>\nset -g set-clipboard off\n# <<< terminal.tmux-clipboard <<<\n# <<< grok doctor <<<\n",
            "# >>> grok doctor >>>\n# >>> terminal.tmux-clipboard >>>\nset -g set-clipboard off\n# <<< terminal.tmux-clipboard <<<\n# <<< grok doctor <<<\nset -g set-clipboard on\n",
        ] {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            let plan = try planFix(
                try tmuxRequest(home: temp.path, id: tmuxClipboardID),
                report: report,
                terminal: tmuxTerminal(byobu: false)
            )
            #expect(formatFixPreview(plan).contains("Text to add:\n"))
            let outcome = try applyFix(plan)
            #expect(outcome.status == .applied)
            #expect(try String(contentsOfFile: path, encoding: .utf8)
                .contains("# >>> terminal.tmux-clipboard >>>\nset -g set-clipboard on\n"))
        }
    }

    /// `tmux_truecolor_fix_appends_alongside_existing_terminal_features`
    /// (fix_tests.rs:1224-1246).
    @Test func tmuxTruecolorFixAppendsAlongsideExistingTerminalFeatures() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let path = temp.join(".tmux.conf")
        try "set -g mouse on\nset -as terminal-features \",xterm-256color:RGB\"\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let plan = try planFix(
            try tmuxRequest(home: temp.path, id: tmuxTruecolorID),
            report: tmuxReport(id: tmuxTruecolorID, evidence: .colorPassthrough),
            terminal: tmuxTerminal(byobu: false)
        )
        let outcome = try applyFix(plan)
        #expect(outcome.status == .applied)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("set -as terminal-features \",xterm-256color:RGB\""))
        #expect(content.contains("set -as terminal-features \",*:RGB\""))
    }

    /// `tmux_truecolor_fix_requires_a_reducing_client` (fix_tests.rs:1248-1261).
    @Test func tmuxTruecolorFixRequiresAReducingClient() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let report = tmuxReport(id: tmuxTruecolorID, evidence: .clipboard)
        do {
            _ = try planFix(
                try tmuxRequest(home: temp.path, id: tmuxTruecolorID),
                report: report,
                terminal: tmuxTerminal(byobu: false)
            )
            Issue.record("expected TmuxNotApplicable")
        } catch let error as FixError {
            guard case .tmuxNotApplicable = error else {
                Issue.record("expected tmuxNotApplicable, got \(error)")
                return
            }
        }
    }
}

@Suite("tmux config scanner")
struct TmuxScannerTests {
    /// `tmux_scanner_handles_server_scopes_separators_prefixes_and_native_blocks`
    /// (fix_tests.rs:452-560).
    @Test func scannerHandlesScopesSeparatorsPrefixesAndNativeBlocks() throws {
        let path = "/tmp/tmux.conf"
        for spec in [tmuxClipboardSpec, tmuxExtendedKeysSpec] {
            let healthy = spec.healthyValues[0]
            for assignment in [
                "set \(spec.option) \(healthy)\n",
                "set -s \(spec.option) \(healthy)\n",
                "set-option -gq \(spec.option) \(healthy)\n",
                "set -w \(spec.option) \(healthy)\n",
                "FOO=bar set -g \(spec.option) \(healthy)\n",
                "set -g mouse on; set -g \(spec.option) \(healthy)\n",
            ] {
                #expect(try scanDirectTmuxOption(text: assignment, path: path, spec: spec) == .healthy, "\(assignment)")
            }
            for conflict in [
                "set \(spec.option) off\n",
                "set -s \(spec.option) off\n",
                "set-option -g \(spec.option) off\n",
                "set -w \(spec.option) off\n",
                "set -g mouse on; set -g \(spec.option) off\n",
                "set -g \(spec.option) o\\\nff\n",
            ] {
                #expect(throws: FixError.self, "\(conflict)") {
                    try scanDirectTmuxOption(text: conflict, path: path, spec: spec)
                }
            }
        }

        let dcs = dcsPassthroughSpec
        for healthy in [
            "setw -g allow-passthrough on\n",
            "set-window-option -g allow-passthrough all\n",
            "set -wg allow-passthrough on\n",
        ] {
            #expect(try scanDirectTmuxOption(text: healthy, path: path, spec: dcs) == .healthy, "\(healthy)")
        }
        for conflict in [
            "setw -g allow-passthrough off\n",
            "set-window-option -g allow-passthrough off\n",
            "set -wg allow-passthrough off\n",
        ] {
            #expect(throws: FixError.self, "\(conflict)") {
                try scanDirectTmuxOption(text: conflict, path: path, spec: dcs)
            }
        }
        for local in [
            "set allow-passthrough on\n",
            "setw allow-passthrough on\n",
            "setw -t:1 allow-passthrough off\n",
        ] {
            #expect(try scanDirectTmuxOption(text: local, path: path, spec: dcs) == .absent, "\(local)")
        }

        for spec in [tmuxClipboardSpec, dcsPassthroughSpec, tmuxExtendedKeysSpec] {
            for ignored in [
                "# set -g \(spec.option) off\n",
                "set -g @\(spec.option) off\n",
                "set -g \(spec.option)-copy off\n",
                "%if 1\nset -g \(spec.option) off\n%endif\n",
                "if-shell true { set -g \(spec.option) off }\n",
            ] {
                #expect(try scanDirectTmuxOption(text: ignored, path: path, spec: spec) == .absent, "\(ignored)")
            }
            for ambiguous in [
                "se -g \(spec.option) off\n",
                "set -g \(spec.option) off extra\n",
                "set -g \(spec.option)\n",
                "set -g \(spec.option) 'unterminated\n",
                "set -g \(spec.option) \\\n",
                "set -t target\nset -g \(spec.option) off\n",
            ] {
                #expect(throws: FixError.self, "\(ambiguous)") {
                    try scanDirectTmuxOption(text: ambiguous, path: path, spec: spec)
                }
            }
        }
    }
}

@Suite("Validator resolution")
struct ValidatorResolutionTests {
    /// `validator_prefers_custom_executable_shell_and_uses_path_for_basename_only`
    /// (fix_tests.rs:903-938).
    @Test func validatorPrefersCustomExecutableShellAndUsesPathForBasenameOnly() throws {
        let temp = try TempHome()
        defer { temp.destroy() }
        let fm = FileManager.default
        let shadow = temp.join("shadow")
        let valid = temp.join("valid")
        try fm.createDirectory(atPath: shadow, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: valid, withIntermediateDirectories: true)
        try "not executable".write(toFile: shadow + "/bash", atomically: true, encoding: .utf8)
        let real = valid + "/bash"
        try "#!/bin/sh\nexit 0\n".write(toFile: real, atomically: true, encoding: .utf8)
        #expect(chmod(real, 0o755) == 0)
        #expect(findOnPathIn("bash", directories: [shadow, valid]) == real)

        let custom = temp.join("custom/bash")
        try fm.createDirectory(atPath: (custom as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(toFile: custom, atomically: true, encoding: .utf8)
        #expect(chmod(custom, 0o755) == 0)
        #expect(resolveValidatorProgram(custom, environment: [:]) == custom)

        #expect(chmod(custom, 0o644) == 0)
        // A non-executable explicit SHELL path is not silently substituted
        // with a different same-basename shell from PATH.
        #expect(resolveValidatorProgram(custom, environment: ["PATH": valid]) == nil)

        #expect(findOnPathIn("bash", directories: [shadow, valid]) == real,
                "basename-only shell names may resolve through PATH")
    }
}
