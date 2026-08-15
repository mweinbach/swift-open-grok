// TmuxTermVersionTests.swift
//
// Pure env / parse / compare coverage for TmuxProbe and TermVersion.
// No live PTY, no process env mutation.

import Foundation
import Testing
@testable import OpenGrokTerminalCore

@Suite("TmuxProbe env and parse")
struct TmuxProbeTests {
    @Test("TMUX env present is tmux")
    func tmuxEnvPresent() {
        let probe = TmuxProbe.detect(env: [
            "TMUX": "/tmp/tmux-501/default,12345,0",
            "TMUX_PANE": "%0",
        ])
        #expect(probe.isPresent)
        #expect(probe.tmuxEnv == "/tmp/tmux-501/default,12345,0")
        #expect(probe.tmuxPane == "%0")
    }

    @Test("missing or empty TMUX is not tmux")
    func tmuxEnvAbsentOrEmpty() {
        let missing = TmuxProbe.detect(env: [:])
        #expect(!missing.isPresent)
        #expect(missing.tmuxEnv == nil)
        #expect(missing.tmuxPane == nil)

        let empty = TmuxProbe.detect(env: ["TMUX": "", "TMUX_PANE": "%stale"])
        #expect(!empty.isPresent)
        #expect(empty.tmuxEnv == nil)
        // TMUX_PANE is recorded independently; presence still requires TMUX.
        #expect(empty.tmuxPane == "%stale")
    }

    @Test("command protocol uses exact argv")
    func commandProtocolArgv() {
        #expect(TmuxQueryCommand.program == "tmux")
        #expect(TmuxQueryCommand.version.arguments == ["-V"])
        #expect(TmuxQueryCommand.optionValue("set-clipboard").arguments
            == ["show-option", "-gqv", "set-clipboard"])
        #expect(TmuxQueryCommand.optionSupport("allow-passthrough").arguments
            == ["show-option", "-gv", "allow-passthrough"])
        #expect(TmuxQueryCommand.controlMode.arguments
            == ["display-message", "-p", "#{client_flags}"])
        #expect(TmuxQueryCommand.clientFeatures.arguments
            == ["display-message", "-p", "#{client_termfeatures}"])
    }

    @Test("parse_value trims success and fail-opens otherwise")
    func parseValueArms() {
        let available = TmuxProbe.parseValue(statusSuccess: true, stdout: " on\n")
        #expect(available == .available("on"))
        #expect(available.intoOption() == "on")

        let empty = TmuxProbe.parseValue(statusSuccess: true, stdout: "  \n")
        #expect(empty == .unavailable)
        #expect(empty.intoOption() == nil)

        let failed = TmuxProbe.parseValue(
            statusSuccess: false,
            stdout: "on",
            error: nil
        )
        #expect(failed == .unavailable)

        let spawn = TmuxProbe.parseValue(
            statusSuccess: false,
            stdout: "",
            error: "spawn failed"
        )
        #expect(spawn == .error("spawn failed"))
        #expect(spawn.intoOption() == nil)
    }

    @Test("support query accepts both known spellings only")
    func optionSupportSpellings() {
        for stderr in [
            "invalid option: allow-passthrough\n",
            "unknown option: allow-passthrough\n",
            "invalid option: allow-passthrough\r\n",
        ] {
            let result = TmuxProbe.parseOptionSupport(
                statusSuccess: false,
                stderr: stderr,
                option: "allow-passthrough"
            )
            #expect(result == .unsupported)
        }

        let other = TmuxProbe.parseOptionSupport(
            statusSuccess: false,
            stderr: "no server running\n",
            option: "allow-passthrough"
        )
        #expect(other == .unavailable)

        let ok = TmuxProbe.parseOptionSupport(
            statusSuccess: true,
            stderr: "",
            option: "allow-passthrough"
        )
        #expect(ok == .available(true))

        let spawn = TmuxProbe.parseOptionSupport(
            statusSuccess: false,
            stderr: "",
            option: "allow-passthrough",
            error: "spawn failed"
        )
        #expect(spawn == .error("spawn failed"))
    }

    @Test("control-mode is a contains check on successful stdout")
    func controlModeParse() {
        let on = TmuxProbe.parseControlMode(
            statusSuccess: true,
            stdout: "control-mode,utf8\n"
        )
        #expect(on == .available(true))
        #expect(on.intoOption() == true)

        let off = TmuxProbe.parseControlMode(statusSuccess: true, stdout: "utf8\n")
        #expect(off == .available(false))

        let failed = TmuxProbe.parseControlMode(statusSuccess: false, stdout: "control-mode")
        #expect(failed == .unavailable)
    }

    @Test("tmux version compare: 3.3a parses, unknown stays old not zero")
    func tmuxVersionCompare() {
        #expect(TmuxProbe.parseMajorMinor("tmux 3.4")! == (3, 4))
        #expect(TmuxProbe.parseMajorMinor("tmux 3.3a")! == (3, 3))
        #expect(TmuxProbe.parseMajorMinor("3.4") == nil)
        #expect(TmuxProbe.parseMajorMinor("") == nil)

        #expect(TmuxProbe.isVersion("tmux 3.4", orLater: 3, 3))
        #expect(!TmuxProbe.isVersion("tmux 3.2", orLater: 3, 3))
        #expect(!TmuxProbe.isVersion(nil, orLater: 3, 3))
        #expect(!TmuxProbe.isVersion("n/a", orLater: 0, 0))
    }
}

@Suite("TermVersion assemble and consumer gates")
struct TermVersionTests {
    @Test("source labels are pinned")
    func sourceLabels() {
        #expect(TermVersionSource.none.description == "none")
        #expect(TermVersionSource.da2.description == "da2")
        #expect(TermVersionSource.termProgram.description == "term_program")
        #expect(TermVersionSource.wezTerm.description == "wezterm")
        #expect(TermVersionSource.vte.description == "vte")
    }

    @Test("Alacritty packed 2401 vs 2402 is the consumer gate")
    func alacrittyPackedCompare() {
        let broken = TermVersion.assemble(da2Packed: 2401)
        #expect(broken.da2Packed == 2401)
        #expect(broken.version == "0.24.1")
        #expect(broken.source == .da2)
        #expect(broken.alacrittyMisEncodesEventTypes)
        #expect(negotiatedKittyFlags(skipReason: nil, da2Packed: broken.da2Packed)
            == [.disambiguateEscapeCodes])

        let fixed = TermVersion.assemble(da2Packed: 2402)
        #expect(fixed.da2Packed == 2402)
        #expect(fixed.version == "0.24.2")
        #expect(fixed.source == .da2)
        #expect(!fixed.alacrittyMisEncodesEventTypes)
        #expect(negotiatedKittyFlags(skipReason: nil, da2Packed: fixed.da2Packed)
            == [.disambiguateEscapeCodes, .reportEventTypes])
    }

    @Test("WezTerm XTVERSION prefix identifies WezTerm")
    func wezTermXtversionPrefix() {
        let identified = TermVersion.assemble(xtversion: "WezTerm 20240203-110809")
        #expect(identified.xtversion == "WezTerm 20240203-110809")
        #expect(identified.xtversionIdentifiesWezTerm)

        let padded = TermVersion.assemble(xtversion: "  WezTerm 2.0")
        #expect(padded.xtversionIdentifiesWezTerm)

        let controls = TermVersion.assemble(xtversion: " We\u{01}zTerm 2.0 ")
        #expect(controls.xtversion == "WezTerm 2.0")
        #expect(controls.xtversionIdentifiesWezTerm)

        let other = TermVersion.assemble(xtversion: "kitty 0.35.2")
        #expect(!other.xtversionIdentifiesWezTerm)
    }

    @Test("missing probes stay unknown not zero")
    func missingProbesStayUnknown() {
        let absent = TermVersion.assemble()
        #expect(absent.da2Packed == nil)
        #expect(absent.xtversion == nil)
        #expect(absent.version == "")
        #expect(absent.source == .none)
        #expect(!absent.alacrittyMisEncodesEventTypes)
        #expect(!absent.xtversionIdentifiesWezTerm)
        #expect(negotiatedKittyFlags(skipReason: nil, da2Packed: absent.da2Packed)
            == [.disambiguateEscapeCodes, .reportEventTypes])

        let rejectedZero = TermVersion.assemble(da2Packed: 0)
        #expect(rejectedZero.da2Packed == nil)
        #expect(rejectedZero.source == .none)
        #expect(!rejectedZero.alacrittyMisEncodesEventTypes)

        let emptyXt = TermVersion.assemble(xtversion: "")
        #expect(emptyXt.xtversion == nil)
        #expect(!emptyXt.xtversionIdentifiesWezTerm)

        let controlOnly = TermVersion.assemble(xtversion: " \u{07} ")
        #expect(controlOnly.xtversion == nil)
    }

    @Test("DA2 outranks env; env outranks none")
    func bestTermVersionPrecedence() {
        let env = TermVersion(version: "7402", source: .vte)
        let da2Wins = TermVersion.best(da2: "0.25.0", envVersion: env)
        #expect(da2Wins.0 == "0.25.0")
        #expect(da2Wins.1 == .da2)

        let envWins = TermVersion.best(da2: nil, envVersion: env)
        #expect(envWins.0 == "7402")
        #expect(envWins.1 == .vte)

        let none = TermVersion.best(da2: nil, envVersion: nil)
        #expect(none.0 == "")
        #expect(none.1 == .none)
    }

    @Test("tmux TERM_PROGRAM_VERSION is not the terminal version")
    func tmuxTermProgramVersionIgnored() {
        let assembled = TermVersion.assemble(env: [
            "TMUX": "/tmp/tmux-501/default,12345,0",
            "TERM_PROGRAM": "tmux",
            "TERM_PROGRAM_VERSION": "3.5",
            "ITERM_SESSION_ID": "w0t0p0:1234",
        ])
        #expect(assembled.version == "")
        #expect(assembled.source == .none)
    }

    @Test("iTerm2 in tmux falls through to LC_TERMINAL_VERSION")
    func iterm2InTmuxUsesLcTerminalVersion() {
        let assembled = TermVersion.assemble(env: [
            "TMUX": "/tmp/tmux-501/default,12345,0",
            "TERM_PROGRAM": "tmux",
            "TERM_PROGRAM_VERSION": "3.5",
            "LC_TERMINAL": "iTerm2",
            "LC_TERMINAL_VERSION": "3.5.6",
        ])
        #expect(assembled.version == "3.5.6")
        #expect(assembled.source == .termProgram)
    }
}
