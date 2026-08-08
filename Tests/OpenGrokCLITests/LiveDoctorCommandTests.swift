// LiveDoctorCommandTests.swift
//
// `open-grok doctor` at the CLI seam (AGENTS.md §3): the real async
// `CLIRunner.run` entry point — the one `OpenGrokExecutable/main.swift`
// calls — with a fully injected environment and captured streams, evidence
// taken from exit codes, stream bytes, and (for the fix path) what actually
// lands in an isolated `$HOME`. The security-shaped assertions here are the
// confirmation gate: `doctor fix <id>` without `--yes` must write NOTHING,
// and `--yes` must write the managed block and be idempotent.

import Foundation
import Testing
@testable import OpenGrokCLI

/// An isolated `$HOME` so the ssh-wrap fix can only ever touch this test's
/// own directory, plus the minimal terminal identity the probes read.
private struct DoctorHome {
    let home: URL
    var environment: [String: String]

    init() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-doctor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color",
        ]
    }

    var zshrc: URL { home.appendingPathComponent(".zshrc") }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("open-grok doctor CLI seam")
struct LiveDoctorCommandTests {
    @Test("doctor prints a real human report and exits 0")
    func reportPrintsRealReport() async {
        let workspace = DoctorHome()
        defer { workspace.cleanup() }
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["doctor"], environment: workspace.environment, streams: streams
        )

        #expect(code == 0)
        // The stub said "not implemented"; a real report has the header,
        // both fact sections, and — standalone evidence only — the
        // needs-a-running-session CTA (doctor_cmd/human.rs:8, 176-180).
        let output = out.contents
        #expect(output.hasPrefix("Grok Doctor\n\nEnvironment\n"))
        #expect(output.contains("\nClipboard\n"))
        #expect(output.contains("Some checks only run in Grok. Start Grok and run /doctor."))
        #expect(!output.contains("not implemented"))
        #expect(err.contents.isEmpty)
    }

    @Test("doctor --json emits valid JSON with the pinned top-level shape")
    func jsonReportIsValidJSON() async throws {
        let workspace = DoctorHome()
        defer { workspace.cleanup() }
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["doctor", "--json"], environment: workspace.environment, streams: streams
        )

        #expect(code == 0)
        #expect(err.contents.isEmpty)
        let object = try JSONSerialization.jsonObject(with: Data(out.contents.utf8))
        let root = try #require(object as? [String: Any])
        // `JsonReport` (doctor_cmd/json.rs:23-47).
        #expect(root["schemaVersion"] as? String == "1")
        #expect(root["facts"] is [String: Any])
        #expect(root["findings"] is [Any])
        #expect(root["probeNotes"] is [Any])
        #expect(root["counts"] is [String: Any])
    }

    @Test("doctor fix on a local session reports no applicable fixes, byte-exact")
    func fixListEmptyLocally() async {
        let workspace = DoctorHome()
        defer { workspace.cleanup() }
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["doctor", "fix"], environment: workspace.environment, streams: streams
        )

        #expect(code == 0)
        // `format_applicable_automatic_fixes` empty arm (fix.rs:604-606):
        // a local, non-tmux session has no findings carrying an automatic
        // remediation.
        #expect(out.contents == "No automatic fixes are available here.\n")
        #expect(err.contents.isEmpty)
    }

    @Test("doctor fix under SSH lists ssh-wrap as run-locally")
    func fixListUnderSSH() async {
        var workspace = DoctorHome()
        defer { workspace.cleanup() }
        workspace.environment["SSH_CONNECTION"] = "10.0.0.1 50000 10.0.0.2 22"
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["doctor", "fix"], environment: workspace.environment, streams: streams
        )

        #expect(code == 0)
        // The ssh-wrap recommendation (view.rs ssh_wrap_hint) becomes a
        // RunLocally row: the alias belongs on the local machine
        // (fix.rs:600-623).
        let output = out.contents
        #expect(output.contains("Automatic fixes:"))
        #expect(output.contains("ssh-wrap"))
        #expect(output.contains("On your local computer, run: grok doctor fix ssh-wrap"))
        #expect(err.contents.isEmpty)
    }

    @Test("doctor fix ssh-wrap WITHOUT --yes prints the preview, refuses, and writes NOTHING")
    func fixWithoutYesRefusesAndWritesNothing() async {
        let workspace = DoctorHome()
        defer { workspace.cleanup() }
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["doctor", "fix", "ssh-wrap"], environment: workspace.environment, streams: streams
        )

        // The refusal is an error exit, like upstream's bail (mod.rs:153-156).
        #expect(code == 1)
        // The full preview printed first — `--yes` means "apply the
        // displayed changes", so the changes must be displayed.
        let output = out.contents
        #expect(output.contains("Doctor Fix"))
        #expect(output.contains("Fix: terminal.ssh-wrap"))
        #expect(output.contains("alias ssh='open-grok wrap ssh'"))
        #expect(err.contents.contains("Cannot apply this fix without confirmation"))
        // THE GATE: nothing landed in $HOME.
        #expect(!FileManager.default.fileExists(atPath: workspace.zshrc.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: workspace.home.path)) ?? []
        #expect(leftovers.isEmpty, "refusal must leave $HOME untouched, found \(leftovers)")
    }

    @Test("doctor fix ssh-wrap --yes writes the managed block to the isolated HOME and is idempotent")
    func fixWithYesAppliesAndIsIdempotent() async throws {
        let workspace = DoctorHome()
        defer { workspace.cleanup() }
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["doctor", "fix", "ssh-wrap", "--yes"],
            environment: workspace.environment,
            streams: streams
        )

        #expect(code == 0, "apply failed: \(err.contents)")
        #expect(out.contents.contains("Set up SSH wrapping in"))
        let written = try String(contentsOf: workspace.zshrc, encoding: .utf8)
        // The managed block: namespace markers + the alias body
        // (fix.rs:30-31, managed_text format grammar).
        #expect(written.contains("grok doctor"))
        #expect(written.contains("terminal.ssh-wrap"))
        #expect(written.contains("alias ssh='open-grok wrap ssh'"))

        // Second run: already configured, and the file is untouched
        // byte-for-byte — the managed-text engine never rewrites a
        // satisfied block.
        let (secondStreams, secondOut, secondErr) = CLIStreams.buffered()
        let secondCode = await CLIRunner.run(
            ["doctor", "fix", "ssh-wrap", "--yes"],
            environment: workspace.environment,
            streams: secondStreams
        )
        #expect(secondCode == 0, "re-apply failed: \(secondErr.contents)")
        #expect(secondOut.contents.contains("SSH wrapping is already set up in"))
        let rewritten = try String(contentsOf: workspace.zshrc, encoding: .utf8)
        #expect(rewritten == written)
    }

    @Test("an unknown fix id fails with the registry's own error")
    func unknownFixIDFails() async {
        let workspace = DoctorHome()
        defer { workspace.cleanup() }
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["doctor", "fix", "nope"], environment: workspace.environment, streams: streams
        )

        #expect(code == 1)
        #expect(out.contents.isEmpty)
        // `resolve_fix_id` unknown-id copy (fix.rs:291-377).
        #expect(err.contents.contains("`nope` is not an available Doctor fix"))
        #expect(!FileManager.default.fileExists(atPath: workspace.zshrc.path))
    }

    @Test("--json cannot be combined with doctor fix")
    func jsonConflictsWithFix() async {
        // `doctor --json fix` already dies in the parser (the `fix`
        // subcommand token is only recognized first); `doctor fix --json`
        // parses, so the ROUTE must refuse it — clap's
        // `args_conflicts_with_subcommands` (doctor_cmd/mod.rs:14-15).
        let workspace = DoctorHome()
        defer { workspace.cleanup() }
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["doctor", "fix", "--json"], environment: workspace.environment, streams: streams
        )

        #expect(code == 2)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("'--json' cannot be combined with 'doctor fix'"))
    }
}
