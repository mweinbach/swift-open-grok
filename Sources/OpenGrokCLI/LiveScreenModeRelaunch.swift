// LiveScreenModeRelaunch.swift
//
// Wave 18 B2-S2: rebuild process argv and re-exec the pager into a
// different screen mode — the port of
// `xai-grok-pager/src/app/screen_mode_relaunch.rs` at pin 650c1db7. Used by
// `/minimal` and `/fullscreen`: the interactive loop quits, the terminal is
// restored, then this module replaces the process image with the same
// binary pointed at the active session under the requested render mode.
// Unix `execv` keeps the PTY/fd identity, so the launching shell stays
// parked behind the same process exactly as before the switch.

import Foundation
#if os(Windows)
import WinSDK
import ucrt
#endif

enum LiveScreenModeRelaunch {
    /// Env var that forces screen-mode resolution regardless of CLI flag or
    /// config (`GROK_SCREEN_MODE_ENV`, `screen_mode_relaunch.rs:17-23`). Set
    /// only on the re-exec path so a config `[ui] screen_mode = "minimal"`
    /// cannot keep a `/fullscreen` relaunch stuck in minimal, and
    /// vice-versa. Consumed (read AND removed) exactly once at startup by
    /// `takeScreenModeEnvOverride` — not a public user interface.
    static let environmentKey = "GROK_SCREEN_MODE"

    /// Root-parser flags whose value arrives as a following token when not
    /// written `--flag=value`. Upstream derives this from clap
    /// (`value_taking_flag_tokens`, `:38-63`) so it can never drift; this
    /// port's parser is a hand-written switch with no table to derive from,
    /// so the list is hand-maintained AND pinned by a test that walks
    /// representative flags through the rebuild — a stale entry here would
    /// silently misclassify a flag's value as the bare positional prompt
    /// and drop it from the relaunch argv (upstream's own warning).
    static let valueTakingFlags: Set<String> = [
        // consumeCommon (CLICommand.swift:1460-1491)
        "--cwd", "--model", "-m", "--provider", "--profile", "--agent-profile",
        "--plugin-dir", "--mcp-config", "--workflow", "--debug-file",
        "--leader-socket", "--allow", "--allowedTools", "--deny",
        "--disallowedTools", "--permission-mode", "--sandbox",
        // root parser (CLICommand.swift:1590-1656)
        "--prompt", "-p", "--single", "--print", "--prompt-json",
        "--prompt-file", "--json-schema", "--output-format",
        "--reasoning-effort", "--effort", "--rules", "--append-system-prompt",
        "--system-prompt-override", "--system-prompt", "--agent", "--agents",
        "--tools", "--max-turns", "--id",
    ]

    /// Boolean flags that must NOT survive into the rebuilt argv
    /// (`:108-124`): both screen-mode flags go (the right one is re-appended;
    /// a stale opposite would trip the `--minimal`/`--fullscreen` conflict or
    /// fight the requested mode), and the one-shot directives already did
    /// their job in the process being replaced (`--restore-code` would
    /// re-checkout the original session commit).
    private static let droppedBooleanFlags: Set<String> = [
        "--minimal", "--fullscreen", "--continue", "-c", "--fork-session",
        "--restore-code",
    ]

    /// Session-selection / one-shot session-creation flags dropped WITH any
    /// following value (`:138-163`): the session rebinds via a fresh
    /// `--resume <id>`; a kept `--session-id` makes that an invalid combo
    /// that kills the relaunch at startup, and a kept `--worktree` /
    /// `--worktree-ref` would create a SECOND worktree.
    private static let droppedValueFlags: Set<String> = [
        "--resume", "-r", "--load", "--session-id", "-s", "--worktree", "-w",
        "--worktree-ref", "--ref",
    ]

    private static let droppedEqualsPrefixes = [
        "--resume=", "--load=", "--session-id=", "-s=", "--worktree=",
        "--worktree-ref=", "--ref=",
    ]

    /// Rebuild argv (without the binary name) for reopening `sessionID` in
    /// the requested screen mode (`build_screen_mode_relaunch_args`,
    /// `:85-194`). Strips prior session-selection / mode flags, one-shot
    /// directives, and any bare positional prompt — a cold-start
    /// `open-grok "do the thing"` must not re-submit on resume. Keeps
    /// everything else (`--no-leader`, `--model`, endpoint overrides)
    /// intact, including the value token following value-taking flags.
    static func buildRelaunchArgs(
        currentArgs: [String],
        sessionID: String,
        wantMinimal: Bool
    ) -> [String] {
        var out: [String] = []
        var iterator = currentArgs.dropFirst().makeIterator()
        var pending = iterator.next()
        while let arg = pending {
            pending = iterator.next()

            // `--` ends flag parsing: everything after is the positional
            // prompt, which must not re-fire on resume. The separator goes
            // too — keeping it would make the appended `--resume` positional.
            if arg == "--" {
                break
            }
            if droppedBooleanFlags.contains(arg) {
                continue
            }
            if droppedEqualsPrefixes.contains(where: { arg.hasPrefix($0) }) {
                continue
            }
            if droppedValueFlags.contains(arg) {
                // Optional/required following value token goes with the flag.
                if let next = pending, !next.hasPrefix("-") {
                    pending = iterator.next()
                }
                continue
            }
            if arg.hasPrefix("-") {
                out.append(arg)
                if !arg.contains("="), valueTakingFlags.contains(arg),
                   let next = pending, !next.hasPrefix("-") {
                    out.append(next)
                    pending = iterator.next()
                }
                continue
            }
            // Bare positional prompt — values for earlier flags were already
            // consumed above, so any remaining bare word here is the prompt.
            continue
        }

        out.append("--resume")
        out.append(sessionID)
        // Keep a CLI mode flag for hand-pasted resume hints that omit the
        // env override (`:187-192`).
        out.append(wantMinimal ? "--minimal" : "--fullscreen")
        return out
    }

    /// Env value written for a relaunch (`screen_mode_env_value`, `:197-203`).
    static func environmentValue(wantMinimal: Bool) -> String {
        wantMinimal ? "minimal" : "fullscreen"
    }

    /// Pasteable shell command when auto re-exec fails
    /// (`screen_mode_relaunch_resume_hint`, `:206-214`).
    static func resumeHint(sessionID: String, wantMinimal: Bool) -> String {
        let mode = environmentValue(wantMinimal: wantMinimal)
        let flag = wantMinimal ? "--minimal" : "--fullscreen"
        return "\(environmentKey)=\(mode) open-grok \(flag) --resume \(sessionID)"
    }

    /// The relaunch banner printed to stderr just before exec (`:231-237`).
    static func relaunchBanner(wantMinimal: Bool) -> String {
        let label = environmentValue(wantMinimal: wantMinimal)
        let reverse = wantMinimal ? "/fullscreen" : "/minimal"
        return "Reopening session in \(label) mode\u{2026} (switch back with \(reverse))"
    }

    /// Consume the one-shot screen-mode override env
    /// (`take_screen_mode_env_override`, `:330-354`): read AND remove, so
    /// the override never lingers where spawned children (tool shells,
    /// workers, nested invocations) would inherit a forced screen mode the
    /// user never asked for. Any set value is removed, even an unparseable
    /// one. When set, the returned value WINS over CLI flags and config —
    /// that way `/fullscreen` always reopens fullscreen even under a
    /// preserved `--no-alt-screen` or a `[ui] screen_mode = "minimal"`.
    static func takeScreenModeEnvOverride() -> String? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else {
            return nil
        }
        #if os(Windows)
        _ = _putenv_s(environmentKey, "")
        #else
        unsetenv(environmentKey)
        #endif
        return raw
    }

    /// Replace the current process with a relaunch into the requested mode
    /// (`exec_screen_mode_relaunch`, `:222-290`). On success this never
    /// returns: Unix replaces the process image, while Windows spawns on the
    /// inherited console, parks the parent, and exits with the child's status.
    /// On failure the IO error string returns so the caller can fall back to
    /// the pasteable resume hint.
    static func exec(sessionID: String, wantMinimal: Bool) -> String {
        let exe = CommandLine.arguments[0]
        let exePath: String
        if exe.contains("/") || exe.contains("\\") {
            exePath = URL(fileURLWithPath: exe).path
        } else if let resolved = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: pathListSeparator)
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent(exe).path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            exePath = resolved
        } else {
            exePath = exe
        }
        let args = buildRelaunchArgs(
            currentArgs: CommandLine.arguments,
            sessionID: sessionID,
            wantMinimal: wantMinimal
        )

        FileHandle.standardError.write(Data((relaunchBanner(wantMinimal: wantMinimal) + "\n").utf8))

        #if os(Windows)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exePath)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment[environmentKey] = environmentValue(wantMinimal: wantMinimal)
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        // The parent must remain attached until the replacement exits. If it
        // returns early, the launching shell and child TUI concurrently read
        // the same console. Ignoring Ctrl events keeps the parked parent from
        // being killed while the child still owns that console; the short
        // delay lets the old input reader finish its final poll first.
        _ = SetConsoleCtrlHandler(nil, true)
        Thread.sleep(forTimeInterval: 0.15)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return "failed to spawn relaunch: \(error)"
        }
        finished.wait()
        exit(process.terminationStatus)
        #else
        // Force mode resolution even when config carries the opposite
        // preference; the replacement consumes it at startup.
        setenv(environmentKey, environmentValue(wantMinimal: wantMinimal), 1)
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(exePath)]
        argv.append(contentsOf: args.map { strdup($0) })
        argv.append(nil)
        execv(exePath, argv)
        // execv only returns on failure.
        let message = String(cString: strerror(errno))
        for pointer in argv { free(pointer) }
        return "failed to exec relaunch: \(message)"
        #endif
    }

    private static var pathListSeparator: Character {
        #if os(Windows)
        ";"
        #else
        ":"
        #endif
    }
}
