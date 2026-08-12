// LiveTUISuspend.swift
//
// The suspend-for-child seam `/transcript` and the persona detail's
// `i` (`$EDITOR`) run through: the one-shot input suspension ticket, the
// composition-provided host the live renderer consumes, `$PAGER` and
// `$VISUAL`/`$EDITOR` resolution, and the synchronous child runner. The
// suspend sequence itself is the port of `suspend_for_child`
// (`xai-grok-pager/src/app/event_loop.rs:356-423`), consumed by the
// `$EDITOR` arm of `run_pending_suspends` (`event_loop.rs:677-736`) and
// the `$PAGER` arm (`event_loop.rs:739-814`) — upstream's two arms share
// the identical park/teardown/child/restore dance, which is why one host
// serves both.

import Foundation

/// A live TUI input suspension in progress: reader parked, raw-mode lease
/// released. One-shot by construction — the only way to get one is
/// `OpenGrokLiveInteractiveInput.beginSuspension()`, and `end()` is the only
/// way back, so "resume without pause" and "double suspend" are
/// unrepresentable at this seam.
public struct LiveInputSuspension: Sendable {
    private let endOperation: @Sendable () async throws -> Void

    init(end: @escaping @Sendable () async throws -> Void) {
        self.endOperation = end
    }

    /// Re-enter raw mode, discard the bytes the terminal buffered while the
    /// child ran, and resume the reader — in that order. Throws when raw mode
    /// cannot be re-entered; the reader then stays paused rather than
    /// resuming into a cooked terminal (see
    /// `LiveInteractiveInputResource.endSuspension`).
    public func end() async throws {
        try await endOperation()
    }
}

/// What the live renderer needs from the composition to host `/transcript`'s
/// suspend: the input-suspension entry point and the session's environment.
/// Installed post-construction (`setSuspendHost`); absent in headless and
/// test compositions, where `/transcript` reports instead of suspending.
struct LiveTUISuspendHost: Sendable {
    /// Parks the terminal reader and releases the raw-mode lease; `nil` when
    /// the park was not acknowledged within its 500 ms bound.
    let beginInputSuspension: @Sendable () async -> LiveInputSuspension?
    /// Passed explicitly from the composition's context — resolving `$PAGER`
    /// through `ProcessInfo` here would read process-global state the
    /// composition never audited, the same trap as process-cwd defaults
    /// (AGENTS.md §2).
    let environment: [String: String]
    /// Cancel+await the controller's motion ticker before tty teardown.
    /// Composition wires a weak controller capture; the default is a no-op
    /// so reachability fixtures keep compiling before that wiring lands.
    let suspendMotion: @Sendable () async -> Void
    /// Re-arm the controller's motion ticker after terminal+input restore.
    /// Same weak-capture / no-op-default shape as `suspendMotion`.
    let resumeMotion: @Sendable () async -> Void

    /// Source-compatible with the two-argument call sites: motion callbacks
    /// default to no-ops so production/tests compile before composition
    /// wires `suspendMotionTicker` / `resumeMotionTicker`.
    init(
        beginInputSuspension: @escaping @Sendable () async -> LiveInputSuspension?,
        environment: [String: String],
        suspendMotion: @escaping @Sendable () async -> Void = {},
        resumeMotion: @escaping @Sendable () async -> Void = {}
    ) {
        self.beginInputSuspension = beginInputSuspension
        self.environment = environment
        self.suspendMotion = suspendMotion
        self.resumeMotion = resumeMotion
    }

    /// `$PAGER`, trimmed, whitespace-split into program + arguments so values
    /// like `less -R` work; default `less` (event_loop.rs:741-756). No
    /// `-R`/`+G` injection — those are upstream's minimal-mode ANSI-transcript
    /// arms (event_loop.rs:757-782), and this path writes plain text.
    static func resolvePager(
        environment: [String: String]
    ) -> (program: String, arguments: [String]) {
        let raw = environment["PAGER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = raw.isEmpty ? "less" : raw
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = parts.first else { return ("less", []) }
        return (program, Array(parts.dropFirst()))
    }

    /// `$VISUAL` → `$EDITOR` → `vi` (`external_editor.rs:131-137` at pin
    /// 650c1db7: blank values fall through), split shlex-style
    /// (`parse_editor_argv`, `:125-129` — quotes group arguments, so
    /// `editor --name 'prompt draft'` carries a spaced argument). Returns
    /// nil when the command cannot parse or yields no program — the
    /// caller surfaces upstream's `"could not parse $VISUAL or $EDITOR"`.
    static func resolveEditor(
        environment: [String: String]
    ) -> (program: String, arguments: [String])? {
        let visual = environment["VISUAL"].flatMap { value -> String? in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        let editor = environment["EDITOR"].flatMap { value -> String? in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        let command = visual ?? editor ?? "vi"
        guard let parts = shellSplit(command),
              let program = parts.first, !program.isEmpty
        else { return nil }
        return (program, Array(parts.dropFirst()))
    }

    /// A minimal shlex: whitespace-separated words, single quotes literal,
    /// double quotes with backslash escapes, backslash escaping outside
    /// quotes. Nil on an unterminated quote or trailing backslash — the
    /// parse failures upstream's `shlex::split` reports as `None`.
    private static func shellSplit(_ command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var iterator = command.makeIterator()

        func nextCharacter() -> Character? {
            iterator.next()
        }

        while let character = nextCharacter() {
            if character.isWhitespace {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            switch character {
            case "'":
                hasToken = true
                var closed = false
                while let inner = nextCharacter() {
                    if inner == "'" { closed = true; break }
                    current.append(inner)
                }
                guard closed else { return nil }
            case "\"":
                hasToken = true
                var closed = false
                while let inner = nextCharacter() {
                    if inner == "\"" { closed = true; break }
                    if inner == "\\" {
                        guard let escaped = nextCharacter() else { return nil }
                        current.append(escaped)
                        continue
                    }
                    current.append(inner)
                }
                guard closed else { return nil }
            case "\\":
                guard let escaped = nextCharacter() else { return nil }
                hasToken = true
                current.append(escaped)
            default:
                hasToken = true
                current.append(character)
            }
        }
        if hasToken { tokens.append(current) }
        guard !tokens.isEmpty else { return nil }
        return tokens
    }

    /// Run the child with inherited stdio, through `/usr/bin/env` so a bare
    /// `$PAGER` name gets PATH lookup. Returns the launch error, if any; the
    /// exit status is discarded as upstream discards it
    /// (event_loop.rs:783-786).
    ///
    /// `terminationHandler` bridged to a continuation — `waitUntilExit` is
    /// banned in this repo (AGENTS.md §2: it parks a run loop on a death
    /// notification the child may already have spent).
    static func runChild(
        program: String,
        arguments: [String],
        environment: [String: String]
    ) async -> (any Error)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        process.environment = environment
        return await withCheckedContinuation { continuation in
            // Exactly-once: the handler is installed before `run()` and fires
            // once after exit; the catch arm only runs when the process never
            // launched, so the two resumes are mutually exclusive.
            process.terminationHandler = { _ in
                continuation.resume(returning: nil)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: error)
            }
        }
    }
}
