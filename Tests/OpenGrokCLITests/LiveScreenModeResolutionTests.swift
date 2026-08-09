// LiveScreenModeResolutionTests.swift
//
// B2-S1: `[ui] screen_mode` gets its first reader. The key had a registered,
// restart-required settings row WRITING it and nothing reading it — "How
// Open Grok opens next time" was false (the Wave 18 B2 research's §4
// finding). These pins cover the parse grammar and the flag/config/TTY
// resolution matrix.
//
// Upstream reference at pin 650c1db7: `parse_screen_mode`
// (`app/screen_mode_relaunch.rs:316-328`, its values test `:733-771`) —
// trimmed, case-insensitive `minimal`, `fullscreen`/`full`, everything else
// (including `inline`) rejected so env/config can never force Inline — and
// the resolution order (`app/mod.rs:790-855`: CLI flags before
// `[ui] screen_mode`).

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

private func launchOptions(_ args: [String]) throws -> CLIExecutionOptions {
    let command = try CLICommandParser.parseOrThrow(args, environment: [:])
    guard case .launch(let options) = command else {
        throw CLIParseError.unknownCommand(args.first ?? "")
    }
    return options
}

private func terminal(tty: Bool) -> OpenGrokLiveTerminal {
    OpenGrokLiveTerminal(
        isTTY: { tty },
        size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
        write: { _ in }
    )
}

@Suite("screen-mode resolution")
struct LiveScreenModeResolutionTests {
    // MARK: The parse grammar (`parse_screen_mode_values`, :733-771)

    @Test("the config grammar accepts minimal/fullscreen/full case-insensitively and rejects the rest")
    func parseGrammar() {
        typealias L = OpenGrokLiveApplicationLauncher
        #expect(L.parseConfiguredScreenMode("minimal") == .minimal)
        #expect(L.parseConfiguredScreenMode("MINIMAL") == .minimal)
        #expect(L.parseConfiguredScreenMode("  minimal  ") == .minimal)
        #expect(L.parseConfiguredScreenMode("fullscreen") == .fullScreen)
        #expect(L.parseConfiguredScreenMode("full") == .fullScreen)
        #expect(L.parseConfiguredScreenMode("FULL") == .fullScreen)

        // Rejected so config can never force Inline — upstream's deliberate
        // hole in the grammar (`:321-327` has no inline arm).
        #expect(L.parseConfiguredScreenMode("inline") == nil)
        #expect(L.parseConfiguredScreenMode("auto") == nil)
        #expect(L.parseConfiguredScreenMode("default") == nil)
        #expect(L.parseConfiguredScreenMode("") == nil)
        #expect(L.parseConfiguredScreenMode("   ") == nil)
        #expect(L.parseConfiguredScreenMode(nil) == nil)
        #expect(L.parseConfiguredScreenMode("garbage") == nil)
    }

    // MARK: The resolution matrix (CLI beats config; TTY degrade)

    @Test("config minimal opens a TTY session minimal; junk and absence keep the default")
    func configDrivesTheDefaultMode() throws {
        typealias L = OpenGrokLiveApplicationLauncher
        let options = try launchOptions(["hello"])

        #expect(try L.resolveInteractivePagerMode(
            options: options, terminal: terminal(tty: true), configScreenMode: "minimal"
        ) == .minimal)
        #expect(try L.resolveInteractivePagerMode(
            options: options, terminal: terminal(tty: true), configScreenMode: "full"
        ) == .fullScreen)
        // Unparseable values fall through to normal resolution, never an
        // error (upstream returns None and continues).
        #expect(try L.resolveInteractivePagerMode(
            options: options, terminal: terminal(tty: true), configScreenMode: "inline"
        ) == .fullScreen)
        #expect(try L.resolveInteractivePagerMode(
            options: options, terminal: terminal(tty: true), configScreenMode: nil
        ) == .fullScreen)
    }

    @Test("CLI flags beat the config key in upstream's resolution order")
    func cliFlagsBeatConfig() throws {
        typealias L = OpenGrokLiveApplicationLauncher

        // --fullscreen over config minimal.
        #expect(try L.resolveInteractivePagerMode(
            options: try launchOptions(["--fullscreen", "hello"]),
            terminal: terminal(tty: true),
            configScreenMode: "minimal"
        ) == .fullScreen)

        // --minimal over config fullscreen.
        #expect(try L.resolveInteractivePagerMode(
            options: try launchOptions(["--minimal", "hello"]),
            terminal: terminal(tty: true),
            configScreenMode: "fullscreen"
        ) == .minimal)

        // --no-alt-screen wins over everything (the stricter request).
        #expect(try L.resolveInteractivePagerMode(
            options: try launchOptions(["--no-alt-screen", "hello"]),
            terminal: terminal(tty: true),
            configScreenMode: "minimal"
        ) == .inline)
    }

    @Test("a configured mode degrades to inline off a TTY — ambient config never throws")
    func configDegradesOffTTY() throws {
        typealias L = OpenGrokLiveApplicationLauncher
        let options = try launchOptions(["hello"])

        // Config minimal piped: the same degrade as the --minimal flag.
        #expect(try L.resolveInteractivePagerMode(
            options: options, terminal: terminal(tty: false), configScreenMode: "minimal"
        ) == .inline)
        // Config fullscreen piped: falls to inline rather than throwing —
        // an explicit `--fullscreen` FLAG contradicting a pipe is an error
        // worth surfacing (the arm above it), but a config key set weeks ago
        // must not break every piped run. Recorded divergence in-source.
        #expect(try L.resolveInteractivePagerMode(
            options: options, terminal: terminal(tty: false), configScreenMode: "fullscreen"
        ) == .inline)
    }

    // MARK: The settings row stops advertising absent commands (ruling c)

    @Test("the screen_mode row no longer names /minimal or /fullscreen until S2 lands them")
    func rowDescriptionNamesNoAbsentCommands() throws {
        let row = try #require(pagerDefaultSettings.first { $0.key == "screen_mode" })
        #expect(!row.description.contains("/minimal"))
        #expect(!row.description.contains("/fullscreen"))
        // The truthful half stays.
        #expect(row.description.contains("How Open Grok opens next time"))
        #expect(row.restartRequired)
    }
}
