// SwarmMode.swift
//
// Session-local swarm mode state — the Swift port of
// `xai-grok-shell/src/session/swarm_mode.rs` (pin 650c1db7).
//
// Swarm mode is a per-session flag with three entry triggers whose
// lifetimes differ: `manual` (from `/swarm` or the persisted `ui.swarm_mode`
// setting) survives turns; `task` (a one-shot `/swarm <task>`) and `tool`
// (the model called `agent_swarm` while the mode was off) auto-exit at the
// turn boundary. What the mode CHANGES about a turn is exactly one thing:
// a `<system-reminder>` user message injected at the next turn start —
// `swarmModeReminder` on entry, `swarmModeExitReminder` after an exit — so
// the model is steered into (and back out of) the one-exclusive-`agent_swarm`
// call discipline. A tracker that flips a boolean nobody reads would be the
// exact "succeeds, does nothing" surface AGENTS.md §3 warns about; the
// reminder pending bits are the mode's entire behavioral payload.

/// What entered swarm mode. Mirrors Rust `SwarmModeTrigger`
/// (swarm_mode.rs:3-19); wire form is snake_case where serialized.
public enum SwarmModeTrigger: String, Sendable, Hashable, Codable {
    case manual
    case task
    case tool

    /// Whether entering with this trigger queues the swarm reminder
    /// (swarm_mode.rs:12-14). A `tool` entry does not: the model already
    /// made the `agent_swarm` call the reminder exists to elicit.
    public var injectsReminder: Bool {
        self == .manual || self == .task
    }

    /// Whether the mode survives the turn boundary (swarm_mode.rs:16-18).
    public var survivesTurn: Bool {
        self == .manual
    }
}

/// The session's swarm-mode state machine. Mirrors Rust `SwarmModeTracker`
/// (swarm_mode.rs:21-96). A value type on purpose — the owner provides the
/// isolation (upstream holds it inside the session-state mutex).
public struct SwarmModeTracker: Sendable, Hashable {
    private var trigger: SwarmModeTrigger?
    private var reminderPending = false
    private var exitReminderPending = false

    public init() {}

    /// Enter swarm mode. A weaker trigger never downgrades a manual entry
    /// (swarm_mode.rs:32-39); the effective trigger is returned.
    @discardableResult
    public mutating func enter(_ trigger: SwarmModeTrigger) -> SwarmModeTrigger {
        if self.trigger == .manual && trigger != .manual {
            return .manual
        }
        self.trigger = trigger
        reminderPending = trigger.injectsReminder
        return trigger
    }

    /// Exit swarm mode, queuing the exit reminder when the entry injected
    /// one (swarm_mode.rs:41-50).
    public mutating func exit() {
        if trigger?.injectsReminder == true {
            exitReminderPending = true
        }
        trigger = nil
        reminderPending = false
    }

    /// Take-and-clear the pending entry reminder (swarm_mode.rs:52-56).
    public mutating func takeReminder() -> Bool {
        let pending = reminderPending
        reminderPending = false
        return pending
    }

    /// Take-and-clear the pending exit reminder (swarm_mode.rs:58-62).
    public mutating func takeExitReminder() -> Bool {
        let pending = exitReminderPending
        exitReminderPending = false
        return pending
    }

    public var currentTrigger: SwarmModeTrigger? { trigger }

    public var enabled: Bool { trigger != nil }

    /// Exit only when the current trigger matches (swarm_mode.rs:72-78) —
    /// how a one-shot task's rollback avoids killing a manual mode.
    @discardableResult
    public mutating func exitIfTrigger(_ trigger: SwarmModeTrigger) -> Bool {
        guard self.trigger == trigger else { return false }
        exit()
        return true
    }

    /// Clears one-shot task/tool state at the turn boundary and returns
    /// whether it changed (swarm_mode.rs:80-89).
    @discardableResult
    public mutating func autoExitTurn() -> Bool {
        guard let trigger, !trigger.survivesTurn else { return false }
        exit()
        return true
    }

    /// A restored session keeps only a manual entry (swarm_mode.rs:91-95).
    public mutating func restoredManualOnly() {
        if trigger != .manual {
            exit()
        }
    }
}

/// The turn-start steering text swarm mode injects. Verbatim copy of Rust
/// `SWARM_MODE_REMINDER` (swarm_mode.rs:98-110).
public let swarmModeReminder: String =
    "Swarm mode is active. Do a small amount of exploratory work first, then decide whether "
    + "the request actually benefits from parallel subagents. If no swarm is warranted, say so "
    + "and wait for the user instead of forcing one. Once you have enough context and a swarm is "
    + "warranted, do not do the main work yourself: make one exclusive agent_swarm call with a "
    + "prompt_template containing literal {{item}} and an items array. Partition work into "
    + "distinct, independent scopes with no duplicate or conflicting ownership; read-only "
    + "exploration may overlap slightly. Unless the user limits scope, decompose as finely as "
    + "useful up to 128 members, combining only genuinely inseparable work. Use ordinary task "
    + "calls instead for a few heterogeneous tasks. Do not mix agent_swarm with any other tool "
    + "call in the same batch. Keep the subagent tree flat: do not instruct swarm members to "
    + "launch additional task or agent_swarm calls; each member should return a complete handoff."

/// The exit notice injected after swarm mode ends. Verbatim copy of the
/// literal in `maybe_inject_swarm_reminder` (reminders.rs:588).
public let swarmModeExitReminder: String =
    "Swarm mode is no longer active. Resume normal tool selection; "
    + "do not treat the previous swarm-only instruction as active."

/// Wrap reminder content in the `<system-reminder>` tag, escaping an
/// embedded closing tag exactly as upstream's `push_system_reminder_with_tag`
/// does (reminders.rs:613-616).
public func wrapSystemReminder(_ content: String) -> String {
    let escaped = content.replacingOccurrences(
        of: "</system-reminder>",
        with: "<\\/system-reminder>"
    )
    return "<system-reminder>\n\(escaped)\n</system-reminder>"
}
