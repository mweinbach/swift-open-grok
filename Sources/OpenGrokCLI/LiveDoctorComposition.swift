// LiveDoctorComposition.swift
//
// The synchronous `open-grok doctor` route: thin wiring between the CLI
// parser and the pure OpenGrokDiagnostics engine, a port of
// `doctor_cmd/mod.rs` (reference 650c1db7). Like `mcp` and `sessions`, the
// route needs nothing from the async application seam — every probe is
// standalone (env-only; a bounded live tmux query only for explicit fix
// planning), so a stuck tmux server or a missing session can never block
// `doctor`.
//
// SECURITY (AGENTS.md §5): `doctor fix <id>` writes the user's shell or tmux
// configuration. The write is confirmation-gated on `--yes` and on nothing
// else; without the flag the route prints the full preview and refuses.
// Upstream additionally offers an interactive [y/N] prompt when stdin is a
// terminal (mod.rs:151-161); `CLIStreams` has no stdin seam, so that leg is
// not ported (recorded divergence — cost: an interactive user must type
// `--yes` instead of answering a prompt, and the refusal copy names `--yes`
// rather than upstream's "run it in an interactive terminal" advice, which
// would be false here).

import Foundation
import OpenGrokDiagnostics

public enum LiveDoctorComposition {
    /// `run` (doctor_cmd/mod.rs:38-48). Returns the process exit code and
    /// writes all of its own output, so the preview-then-refuse ordering on
    /// the unconfirmed fix path stays in one place.
    public static func run(
        options: CLIDoctorOptions,
        environment: [String: String],
        streams: CLIStreams
    ) -> Int32 {
        guard options.fix else {
            return runReport(json: options.json, environment: environment, streams: streams)
        }
        // clap's `args_conflicts_with_subcommands` (mod.rs:14-15): `--json`
        // belongs to the report form only. The port's parser accepts the
        // combination, so the route refuses rather than silently dropping
        // the flag.
        guard !options.json else {
            streams.err("open-grok: '--json' cannot be combined with 'doctor fix'.\n")
            return CLIRunner.ExitCode.usage.rawValue
        }
        return runFix(options: options, environment: environment, streams: streams)
    }

    // MARK: - Report

    /// `run_report` + `collect_report` (mod.rs:58-68).
    private static func runReport(
        json: Bool,
        environment: [String: String],
        streams: CLIStreams
    ) -> Int32 {
        let terminal = standaloneTerminalContext(environment: environment)
        let report = configuredReportForTerminal(
            reportFrom(collectStandalone(terminal: terminal, environment: environment)),
            terminal: terminal,
            environment: environment
        )
        streams.out(json ? DoctorCommandFormat.json(report) : DoctorCommandFormat.human(report))
        return CLIRunner.ExitCode.success.rawValue
    }

    /// `collect_report_with` (mod.rs:85-91) minus `apply_voice_probe`: the
    /// diagnostics library defers voice probing (see the PORT note on
    /// `DiagnosticFacts.voice`), so `facts.voice` stays nil and the Voice
    /// section is absent — recorded divergence, owned by the library slice.
    private static func reportFrom(_ snapshot: StandaloneDiagnosticSnapshot) -> DiagnosticReport {
        DiagnosticsEngine.report(snapshot: DiagnosticSnapshot(standalone: snapshot))
    }

    /// `configured_report_for_terminal` + `shell_home_and_kind`
    /// (mod.rs:70-83, 205-211): once the managed alias is verified in the
    /// user's shell config, the ssh-wrap recommendation is dropped. SSH and
    /// VS Code Remote sessions skip the check — the alias belongs on the
    /// local machine, so the local config proves nothing here.
    private static func configuredReportForTerminal(
        _ report: DiagnosticReport,
        terminal: TerminalContext,
        environment: [String: String]
    ) -> DiagnosticReport {
        if terminal.isSSH || terminal.isOfficialVSCodeRemote { return report }
        var configured = false
        if let home = environment["HOME"], !home.isEmpty,
           let shellPath = environment["SHELL"],
           let shell = ShellKind.fromShellPath(shellPath) {
            configured = managedAliasConfigured(path: shell.configPath(home: home), shell: shell)
        }
        return configuredReport(report, configured: configured)
    }

    // MARK: - Fix

    /// `run_fix` + `apply_fix_plan` (mod.rs:105-203), with the `--yes` gate
    /// in place of upstream's interactive prompt (see the header note).
    private static func runFix(
        options: CLIDoctorOptions,
        environment: [String: String],
        streams: CLIStreams
    ) -> Int32 {
        let terminal = standaloneTerminalContext(environment: environment)
        guard let value = options.fixID else {
            // Bare `doctor fix` (mod.rs:107-121): list the automatic fixes
            // applicable to THIS report, with the bounded live tmux facts.
            let report = configuredReportForTerminal(
                reportFrom(collectStandaloneFix(terminal: terminal, id: nil, environment: environment)),
                terminal: terminal,
                environment: environment
            )
            streams.out(formatApplicableAutomaticFixes(
                report: report, terminal: terminal, environment: environment
            ))
            return CLIRunner.ExitCode.success.rawValue
        }
        do {
            let id = try resolveFixID(value)
            let report = configuredReportForTerminal(
                reportFrom(collectStandaloneFix(terminal: terminal, id: id, environment: environment)),
                terminal: terminal,
                environment: environment
            )
            let request = try FixRequest.fromEnvironment(id: id, environment: environment)
            let plan = try planFix(request, report: report, terminal: terminal)
            // The preview always prints, confirmed or not (mod.rs:149):
            // `--yes` means "apply the displayed changes", so the changes
            // must be displayed.
            streams.out(formatFixPreview(plan))
            guard options.assumeYes else {
                // THE CONFIRMATION GATE. Nothing below this line runs
                // without `--yes`; the plan is discarded and no file is
                // touched (`applyFix` is the only writer on this path).
                streams.err("open-grok: Cannot apply this fix without confirmation. Add `--yes` to apply the displayed changes.\n")
                return CLIRunner.ExitCode.failure.rawValue
            }
            let outcome = try applyFix(plan)
            // Post-apply verification (mod.rs:167-193): both arms re-check
            // the real world and FAIL the command when the write landed but
            // the condition it was meant to satisfy still holds — the
            // "succeeds, does nothing, says nothing" trap (AGENTS.md §3).
            if outcome.activation == .satisfiedNow {
                let postReport = configuredReport(
                    reportFrom(collectStandalone(terminal: terminal, environment: environment)),
                    configured: outcome.managedAliasIsConfigured
                )
                if postReport.findings.contains(where: { $0.id == outcome.id }) {
                    streams.err("open-grok: The change was applied, but Doctor still reports `\(outcome.id)`.\n")
                    return CLIRunner.ExitCode.failure.rawValue
                }
            } else if !verifyPersistentFix(outcome) {
                streams.err("open-grok: The change was applied, but Doctor could not verify `\(outcome.id)` in persistent configuration.\n")
                return CLIRunner.ExitCode.failure.rawValue
            }
            streams.out("\n" + formatFixSuccess(outcome) + "\n")
            return CLIRunner.ExitCode.success.rawValue
        } catch {
            // FixError descriptions are complete sentences (fix.rs:291-377
            // copies); anything else renders through its own description.
            streams.err("open-grok: \(error)\n")
            return CLIRunner.ExitCode.failure.rawValue
        }
    }
}
