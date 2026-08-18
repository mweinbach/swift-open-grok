// LiveScreenModeRelaunchTests.swift
//
// B2-S2: the exec-based screen-mode relaunch — argv rebuild, the
// consume-once GROK_SCREEN_MODE override, and the resume hint. Upstream
// reference at pin 650c1db7: `app/screen_mode_relaunch.rs` (the rebuild
// `:85-194`, its test tables `:400-914`, the env consumption `:330-354`,
// the hint `:206-214`). The exec itself replaces the process image and is
// deliberately not invoked here; its failure path returns the error string
// the composition prints with the hint.

import Foundation
import OpenGrokPager
import Testing
@testable import OpenGrokCLI
#if os(Windows)
import ucrt
#endif

private func setScreenModeEnvironment(_ value: String) {
    #if os(Windows)
    _ = _putenv_s(LiveScreenModeRelaunch.environmentKey, value)
    #else
    setenv(LiveScreenModeRelaunch.environmentKey, value, 1)
    #endif
}

private func rebuild(
    _ args: [String],
    sessionID: String = "sess-1",
    wantMinimal: Bool = true
) -> [String] {
    LiveScreenModeRelaunch.buildRelaunchArgs(
        currentArgs: ["open-grok"] + args,
        sessionID: sessionID,
        wantMinimal: wantMinimal
    )
}

@Suite("screen-mode relaunch argv rebuild")
struct ScreenModeRelaunchArgvTests {
    @Test("a bare launch rebinds to --resume plus the mode flag")
    func bareLaunchRebinds() {
        // `:185-192`: the fresh `--resume <id>` plus a CLI mode flag for
        // hand-pasted resume hints that omit the env override.
        #expect(rebuild([]) == ["--resume", "sess-1", "--minimal"])
        #expect(rebuild([], wantMinimal: false) == ["--resume", "sess-1", "--fullscreen"])
    }

    @Test("prior mode flags and one-shot directives are stripped")
    func priorModeFlagsAndOneShotsAreStripped() {
        // `:108-124`: a stale opposite mode flag would trip the
        // --minimal/--fullscreen conflict; --restore-code already did its
        // checkout in the process being replaced.
        #expect(rebuild(["--fullscreen", "--restore-code", "--continue"])
            == ["--resume", "sess-1", "--minimal"])
        #expect(rebuild(["--minimal", "-c", "--fork-session"], wantMinimal: false)
            == ["--resume", "sess-1", "--fullscreen"])
    }

    @Test("session-selection flags drop with their values, space and equals forms")
    func sessionSelectionFlagsDropWithValues() {
        // `:126-163`: the session rebinds via the fresh --resume; a kept
        // --session-id is an invalid combo that kills the relaunch at
        // startup, and a kept --worktree would create a SECOND worktree.
        #expect(rebuild(["--resume", "old-id"]) == ["--resume", "sess-1", "--minimal"])
        #expect(rebuild(["--resume=old-id"]) == ["--resume", "sess-1", "--minimal"])
        #expect(rebuild(["-r", "old-id"]) == ["--resume", "sess-1", "--minimal"])
        #expect(rebuild(["--session-id", "sid", "--worktree", "path", "--worktree-ref", "main"])
            == ["--resume", "sess-1", "--minimal"])
        #expect(rebuild(["-s=sid", "--worktree=path", "--ref=main"])
            == ["--resume", "sess-1", "--minimal"])
        // Optional-value flags keep a following FLAG intact (`:156-161`:
        // only a non-dash token is the value).
        #expect(rebuild(["--resume", "--no-leader"])
            == ["--no-leader", "--resume", "sess-1", "--minimal"])
    }

    @Test("kept flags carry their value tokens through")
    func keptFlagsCarryTheirValues() {
        // `:165-175`: everything else survives, including the value token
        // following a value-taking flag — a misclassified value would be
        // dropped as the bare prompt (upstream's drift warning, the reason
        // the hand-maintained classification is pinned here).
        #expect(rebuild(["--model", "grok-4", "--no-leader", "--effort", "high"])
            == ["--model", "grok-4", "--no-leader", "--effort", "high",
                "--resume", "sess-1", "--minimal"])
        #expect(rebuild(["--cwd", "/tmp/project", "--sandbox", "strict"])
            == ["--cwd", "/tmp/project", "--sandbox", "strict",
                "--resume", "sess-1", "--minimal"])
        // `--flag=value` forms pass through as one token.
        #expect(rebuild(["--model=grok-4"])
            == ["--model=grok-4", "--resume", "sess-1", "--minimal"])
    }

    @Test("the bare positional prompt never re-fires on resume")
    func barePromptNeverReFires() {
        // `:178-183`: a cold-start `open-grok "do the thing"` must not
        // re-submit its prompt on every mode switch.
        #expect(rebuild(["fix the bug"]) == ["--resume", "sess-1", "--minimal"])
        #expect(rebuild(["--no-leader", "fix the bug"])
            == ["--no-leader", "--resume", "sess-1", "--minimal"])
    }

    @Test("a double dash ends flag parsing and everything after it drops")
    func doubleDashEndsParsing() {
        // `:101-106`: keeping the separator would make the appended
        // --resume positional.
        #expect(rebuild(["--no-leader", "--", "prompt", "words"])
            == ["--no-leader", "--resume", "sess-1", "--minimal"])
    }
}

@Suite("screen-mode env override", .serialized)
struct ScreenModeEnvOverrideTests {
    @Test("the override is consumed exactly once and removed from the environment")
    func overrideIsConsumedOnce() {
        // `:330-354`: read AND removed, so spawned children (tool shells,
        // workers, nested invocations) never inherit a forced mode.
        setScreenModeEnvironment("minimal")
        #expect(LiveScreenModeRelaunch.takeScreenModeEnvOverride() == "minimal")
        #expect(getenv(LiveScreenModeRelaunch.environmentKey) == nil)
        #expect(LiveScreenModeRelaunch.takeScreenModeEnvOverride() == nil)

        // Even an unparseable value is removed — it must not linger either.
        setScreenModeEnvironment("bogus")
        #expect(LiveScreenModeRelaunch.takeScreenModeEnvOverride() == "bogus")
        #expect(getenv(LiveScreenModeRelaunch.environmentKey) == nil)
    }

    @Test("the override wins over CLI flags and config in mode resolution")
    func overrideWinsOverFlagsAndConfig() throws {
        let command = try CLICommandParser.parseOrThrow(["--fullscreen"], environment: [:])
        guard case .launch(let options) = command else {
            Issue.record("expected a launch parse")
            return
        }
        let tty = OpenGrokLiveTerminal(
            isTTY: { true },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        // `:337-341`: a preserved --fullscreen (or a config
        // screen_mode = "fullscreen") must not keep a /minimal relaunch out
        // of minimal, and vice-versa.
        #expect(try OpenGrokLiveApplicationLauncher.resolveInteractivePagerMode(
            options: options, terminal: tty,
            configScreenMode: "fullscreen", screenModeEnvOverride: "minimal"
        ) == .minimal)
        // A garbage override falls through to normal resolution.
        #expect(try OpenGrokLiveApplicationLauncher.resolveInteractivePagerMode(
            options: options, terminal: tty,
            configScreenMode: nil, screenModeEnvOverride: "bogus"
        ) == .fullScreen)
        // Off a TTY the forced mode degrades to inline like the S1 config
        // arm — an env var no user typed must not break a piped run.
        let piped = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        #expect(try OpenGrokLiveApplicationLauncher.resolveInteractivePagerMode(
            options: options, terminal: piped,
            configScreenMode: nil, screenModeEnvOverride: "minimal"
        ) == .inline)
    }
}

@Suite("screen-mode relaunch surfaces")
struct ScreenModeRelaunchSurfaceTests {
    @Test("the resume hint is the pasteable env + flag + resume command")
    func resumeHintIsPasteable() {
        // `:206-214`.
        #expect(
            LiveScreenModeRelaunch.resumeHint(sessionID: "sess-9", wantMinimal: true)
                == "GROK_SCREEN_MODE=minimal open-grok --minimal --resume sess-9"
        )
        #expect(
            LiveScreenModeRelaunch.resumeHint(sessionID: "sess-9", wantMinimal: false)
                == "GROK_SCREEN_MODE=fullscreen open-grok --fullscreen --resume sess-9"
        )
    }

    @Test("the relaunch banner names the mode and the way back")
    func relaunchBannerNamesTheWayBack() {
        // `:231-237`.
        #expect(
            LiveScreenModeRelaunch.relaunchBanner(wantMinimal: true)
                == "Reopening session in minimal mode\u{2026} (switch back with /fullscreen)"
        )
        #expect(
            LiveScreenModeRelaunch.relaunchBanner(wantMinimal: false)
                == "Reopening session in fullscreen mode\u{2026} (switch back with /minimal)"
        )
    }
}
