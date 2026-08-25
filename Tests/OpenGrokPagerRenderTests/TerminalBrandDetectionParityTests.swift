import Testing
@testable import OpenGrokPagerRender

@Suite("Pinned terminal brand and graphics detection parity")
struct TerminalBrandDetectionParityTests {
    @Test("brand-specific markers survive missing TERM_PROGRAM", arguments: [
        (["KITTY_WINDOW_ID": "1"], TerminalName.kitty),
        (["TERM": "xterm-kitty"], TerminalName.kitty),
        (["WEZTERM_VERSION": "20240203"], TerminalName.wezTerm),
        (["LC_TERMINAL": "iTerm2", "SSH_CONNECTION": "remote"], TerminalName.iterm2),
        (["TERMINAL_EMULATOR": "JetBrains-JediTerm"], TerminalName.jetBrains),
        (["ALACRITTY_SOCKET": "/tmp/alacritty.sock"], TerminalName.alacritty),
        (["TERM": "foot-extra"], TerminalName.foot),
        (["TERMINATOR_UUID": "pane", "VTE_VERSION": "8200"], TerminalName.terminator),
        (["VTE_VERSION": "8200"], TerminalName.vte),
        (["WT_SESSION": "session"], TerminalName.windowsTerminal),
    ])
    func detectsEnvironmentMarkers(
        environment: [String: String],
        expected: TerminalName
    ) {
        #expect(detectTerminalBrandFromEnv(environment) == expected)
    }

    @Test("explicit program beats inherited brand markers")
    func terminalProgramTakesPrecedence() {
        #expect(detectTerminalBrandFromEnv([
            "TERM_PROGRAM": "Ghostty",
            "WEZTERM_VERSION": "20240203",
            "KITTY_WINDOW_ID": "1",
        ]) == .ghostty)
        #expect(detectTerminalBrandFromEnv(["TERM_PROGRAM": " Apple-Terminal "]) == .appleTerminal)
        #expect(detectTerminalBrandFromEnv(["TERM_PROGRAM": "grok.desktop"]) == .grokDesktop)
    }

    @Test("IDE-specific markers disambiguate inherited VS Code TERM_PROGRAM")
    func ideMarkersTakePrecedence() {
        #expect(detectTerminalBrandFromEnv([
            "TERM_PROGRAM": "vscode",
            "CURSOR_TRACE_ID": "trace",
        ]) == .cursor)
        #expect(detectTerminalBrandFromEnv([
            "TERM_PROGRAM": "vscode",
            "VSCODE_GIT_ASKPASS_MAIN": "/Applications/Windsurf/askpass.js",
        ]) == .windsurf)
        #expect(detectTerminalBrandFromEnv([
            "VSCODE_GIT_ASKPASS_MAIN": "/home/user/.vscode-server/askpass.js",
        ]) == .vsCode)
    }

    @Test("empty inherited markers do not claim terminal capabilities")
    func emptyMarkersAreIgnored() {
        #expect(detectTerminalBrandFromEnv([
            "TERM_PROGRAM": "",
            "KITTY_WINDOW_ID": "",
            "WEZTERM_VERSION": "",
        ]) == .unknown)
    }

    @Test("real Kitty and WezTerm markers enable supported inline graphics")
    func graphicsFollowActualTerminalMarkers() {
        #expect(detectGraphicsProtocol(environment: ["KITTY_WINDOW_ID": "1"], host: .macos) == .kitty)
        #expect(detectGraphicsProtocol(environment: ["TERM": "xterm-kitty"], host: .linux) == .kitty)
        #expect(detectGraphicsProtocol(environment: ["WEZTERM_VERSION": "20240203"], host: .linux) == .kitty)
        #expect(detectGraphicsProtocol(environment: ["TERM_PROGRAM": "Ghostty"], host: .macos) == .kitty)
    }

    @Test("SSH and NO_COLOR do not falsely erase the independent graphics capability")
    func independentColorAndSSHPoliciesPreserveGraphics() {
        #expect(detectGraphicsProtocol(environment: [
            "TERM": "xterm-kitty",
            "SSH_CONNECTION": "127.0.0.1 22 127.0.0.1 20",
            "NO_COLOR": "1",
        ], host: .linux) == .kitty)
    }

    @Test("tmux and dumb terminals fail closed without supported graphics passthrough")
    func unsupportedTerminalLayersSuppressGraphics() {
        #expect(detectGraphicsProtocol(environment: [
            "TERM_PROGRAM": "Ghostty",
            "TMUX": "/tmp/tmux-501/default,1,0",
        ], host: .macos) == .none)
        #expect(detectGraphicsProtocol(environment: [
            "TERM_PROGRAM": "WezTerm",
            "BYOBU_BACKEND": "tmux",
        ], host: .linux) == .none)
        #expect(detectGraphicsProtocol(environment: [
            "KITTY_WINDOW_ID": "1",
            "TERM": "dumb",
        ], host: .linux) == .none)
    }

    @Test("screen backend and empty TMUX do not inherit stale tmux suppression")
    func byobuScreenAndEmptyTmuxDoNotSuppressGraphics() {
        #expect(detectGraphicsProtocol(environment: [
            "TERM_PROGRAM": "Ghostty",
            "BYOBU_BACKEND": "screen",
            "TMUX": "/tmp/stale-tmux",
        ], host: .linux) == .kitty)
        #expect(detectGraphicsProtocol(environment: [
            "TERM": "xterm-kitty",
            "TMUX": "",
        ], host: .linux) == .kitty)
    }

    @Test("Windows and iTerm2 never advertise unsupported graphics protocols")
    func unsupportedHostsAndBrandsRemainDisabled() {
        #expect(detectGraphicsProtocol(environment: ["KITTY_WINDOW_ID": "1"], host: .windows) == .none)
        #expect(detectGraphicsProtocol(environment: [
            "TERM_PROGRAM": "Ghostty",
            "OS": "Windows_NT",
        ], host: .linux) == .none)
        #expect(detectGraphicsProtocol(environment: ["LC_TERMINAL": "iTerm2"], host: .macos) == .none)
    }
}
