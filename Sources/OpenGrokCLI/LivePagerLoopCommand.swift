// LivePagerLoopCommand.swift
//
// The `/loop` slash command — upstream `LoopCommand`
// (`xai-grok-pager/src/slash/commands/loop_cmd.rs`). Like `/imagine`, the
// command is a prompt injection, not a tool call: empty args echo the usage
// message; anything else expands to `loopScheduleInstruction(args, mode)` —
// the model turns the request into a `scheduler_create` call — plus a
// provisional preview row for the tasks pane so the schedule shows before
// the model round-trips (`app/dispatch/prompt.rs:775-794`).
//
// Registration is gated on the session's advertised toolset actually
// carrying `scheduler_create` — upstream's `required_tools:
// [SCHEDULER_CREATE_TOOL_NAME]` (loop_cmd.rs:12, 107-109) — read off the
// same list the model is offered, the `/imagine` gate precedent: a session
// that cannot act on the injection never lists the row (AGENTS.md §4).
//
// Fire mode is pinned to `.inSession`: this port's only fire path is the
// in-session cron turn. Upstream resolves `[scheduler] background_loops`
// (default true → Detached); the Detached loop-subagent mode is a deferred
// slice, so the resolved value would be overridden either way and the
// instruction must describe the runtime the user actually has. The
// `background_loops` config reader lands with the Detached slice — wiring
// the key now would give it a parse with no behavioral reader (AGENTS.md §3).

import Foundation
import OpenGrokPager
import OpenGrokToolsAPI

enum LiveLoopCommand {
    /// The conditional registration the interactive composition installs.
    /// Name `"loop"` (loop_cmd.rs:83-85), description "Run a prompt on a
    /// recurring interval" (loop_cmd.rs:87-89) and usage
    /// "/loop [interval] <prompt>" (loop_cmd.rs:91-93), all verbatim.
    /// Upstream's `arg_placeholder("[interval] <prompt>")` has no port
    /// channel (the `/imagine` divergence, shared).
    static func registrations(
        advertisedToolNames: Set<String>
    ) -> [OpenGrokPagerCommandRegistration] {
        guard advertisedToolNames.contains(schedulerCreateToolName) else { return [] }
        return [OpenGrokPagerCommandRegistration(
            name: "loop",
            summary: "Run a prompt on a recurring interval",
            usage: "/loop [interval] <prompt>"
        )]
    }

    /// The provisional tasks-pane row `/loop` seeds before `scheduler_create`
    /// lands the real one (`ScheduledTaskPreview`, loop_cmd.rs:138-143 with
    /// `tag: "loop"`).
    struct Preview: Sendable, Equatable {
        var prompt: String
        var humanSchedule: String
    }

    enum Dispatch: Sendable, Equatable {
        case usage(String)
        case schedule(instruction: String, preview: Preview)
    }

    /// `LoopCommand::run` (loop_cmd.rs:111-145): trimmed-empty args → the
    /// usage message; otherwise the schedule instruction built from the RAW
    /// argument tail (upstream passes `args` unmodified) plus the preview.
    static func dispatch(
        rawArgumentTail: String,
        fireMode: LoopFireMode = .inSession
    ) -> Dispatch {
        if rawArgumentTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .usage(loopUsageMessage())
        }
        let (intervalToken, prompt) = parseLoopArgs(rawArgumentTail)
        // A concrete cadence only for an unambiguous leading token; otherwise
        // the neutral placeholder — the authoritative schedule arrives with
        // the model's scheduler_create and replaces this provisional entry
        // (loop_cmd.rs:123-130).
        let humanSchedule = intervalToken.map(intervalTokenToHuman) ?? "scheduling\u{2026}"
        return .schedule(
            instruction: loopScheduleInstruction(rawArgumentTail, mode: fireMode),
            preview: Preview(prompt: prompt, humanSchedule: humanSchedule)
        )
    }

    /// Split `/loop` args into an optional leading compact interval token
    /// (only for seeding the provisional preview) and the prompt. Port of
    /// `parse_loop_args` (loop_cmd.rs:20-30): `Some(token)` only for a
    /// `^\d+[smhd]$` first token followed by prompt text; otherwise `None`,
    /// leaving the model to derive the real interval. No host-side default.
    static func parseLoopArgs(_ args: String) -> (intervalToken: String?, prompt: String) {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if let boundary = trimmed.firstIndex(where: \.isWhitespace) {
            let first = String(trimmed[..<boundary])
            let rest = String(trimmed[boundary...].drop(while: \.isWhitespace))
            if isIntervalToken(first), !rest.isEmpty {
                return (first, rest)
            }
        }
        return (nil, trimmed)
    }

    /// Whether a token is a schedulable interval: non-zero digits followed by
    /// one of s/m/h/d. Port of `is_interval_token` (loop_cmd.rs:35-43); zero
    /// is rejected so the preview never shows a cadence the tool would
    /// refuse. Upstream splits at the last BYTE and would panic on a
    /// multi-byte final character; splitting on the last `Character` rejects
    /// such tokens instead (the `parseInterval` divergence, shared).
    static func isIntervalToken(_ s: String) -> Bool {
        guard s.count >= 2, let suffix = s.last else { return false }
        guard "smhd".contains(suffix) else { return false }
        let digits = s.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return false
        }
        guard let value = UInt64(digits), value > 0 else { return false }
        return true
    }

    /// Convert an interval token like "5m" to a human string like
    /// "every 5 minutes". Port of loop_cmd.rs's LOCAL `interval_to_human`
    /// (loop_cmd.rs:46-80) — distinct from the library's seconds-based
    /// formatter: this one keeps the token's own unit ("60s" stays
    /// "every 60 seconds") and `n <= 1` seconds reads "every 1 second".
    static func intervalTokenToHuman(_ token: String) -> String {
        let digits = String(token.dropLast())
        let value = UInt64(digits) ?? 0
        switch token.last {
        case "s":
            return value <= 1 ? "every 1 second" : "every \(value) seconds"
        case "m":
            return value == 1 ? "every 1 minute" : "every \(value) minutes"
        case "h":
            return value == 1 ? "every 1 hour" : "every \(value) hours"
        case "d":
            return value == 1 ? "every 1 day" : "every \(value) days"
        default:
            return "every \(token)"
        }
    }
}
