// LiveInterjection.swift
//
// The session half of TRUE mid-turn interjection: the buffer the live turn
// loop drains between sampler rounds, plus the running/idle decision the
// producer needs.
//
// Upstream splits this across two seams. The pager sends `x.ai/interject`
// over ACP and the session actor's `SessionCommand::Interject` arm decides:
// a RUNNING turn buffers the text into `pending_interjections`
// (run_loop.rs:1974-1979); an idle session converts it into a front-of-queue
// prompt turn instead (run_loop.rs:1980-1989, `queue_interjection_fallback_
// prompt`). This port is single-process, so the wire hop collapses into a
// direct call through the buffer actor, and a `false` return is the
// producer's cue to run the fallback path — the prompt queue lives on the
// controller in this port, not in the shell.
//
// The running/idle decision and the buffer mutation live together in one
// actor because upstream's correctness argument is serialization: the
// `Interject` arm and the turn-completion arm run in the same actor loop, so
// a push can never land in a buffer whose turn has already flushed
// (run_loop.rs:437-444, the INVARIANT comment). Here `turnActive` and the
// buffer are only touched inside this actor, which is the same guarantee.
//
// Rust reference: crates/codegen/xai-grok-shell/src/session/acp_session_impl/
// interjection.rs and run_loop.rs at the pinned commit (650c1db7).

import OpenGrokInterjection

/// Mid-turn interjection buffer for one live session, shared between the
/// producer (the subagent collaboration quartet's root delivery,
/// `LiveSubagentHost`) and the consumer (`LiveShellSamplingDriver.runTurn`'s
/// drain points). `/btw` stopped producing here when it became a real side
/// question (`startSideQuestion` in LiveComposition.swift).
///
/// The attachment type is `String` for symmetry with the shared
/// `InterjectionBuffer`; this port's composer has no image attachments on
/// the interjection path, so the array is always empty (upstream's image
/// pipeline, interjection.rs:122-150, has nothing to carry here).
actor LiveSessionInterjections {
    private let pendingInterjections = InterjectionBuffer<String>()
    /// Whether the sampling driver is inside a turn right now. Flipped by
    /// the driver at the same points upstream's `current_prompt_id` becomes
    /// Some/None around `process_conversation_turn`.
    private var turnActive = false

    /// The driver entered a turn; interjections may now merge into it.
    func beginTurn() {
        turnActive = true
    }

    /// The turn ended (completed or failed). The buffer is deliberately left
    /// intact: entries that raced past the final drain are "stranded" and the
    /// controller converts them into front-of-queue prompt turns, upstream's
    /// completion-arm flush (`flush_stranded_interjections`,
    /// run_loop.rs:432-447).
    func endTurn() {
        turnActive = false
    }

    /// The turn was cancelled. Upstream clears the buffer here — "the turn is
    /// being cancelled, so they have no active turn to inject into"
    /// (run_loop.rs:989-991) — and the completion-arm flush relies on that
    /// clear to never resurrect a cancelled turn's interjections.
    func cancelTurn() {
        turnActive = false
        pendingInterjections.clear()
    }

    /// The `SessionCommand::Interject` decision (run_loop.rs:1962-1989):
    /// buffer into an actually-running turn and return `true`; return `false`
    /// when no turn runs, in which case the CALLER queues the text as its own
    /// front-of-queue prompt turn (the buffer is drained exclusively by the
    /// turn loop, so pushing while idle would strand the message forever).
    func interject(_ text: String) -> Bool {
        guard turnActive else { return false }
        pendingInterjections.push(PendingInterjection(text: text))
        return true
    }

    /// Drain for the turn loop's safe points (FIFO). The port of the manual
    /// `drain_all` inside `drain_pending_interjections`
    /// (interjection.rs:294).
    func drainAll() -> [PendingInterjection<String>] {
        pendingInterjections.drainAll()
    }

    /// Drain interjections stranded past the completed turn's final drain,
    /// for conversion into fallback prompt turns
    /// (`flush_stranded_interjections`, interjection.rs:105-116).
    func collectStranded() -> [String] {
        pendingInterjections.drainAll().map(\.text)
    }

    /// Test observability: whether anything is buffered.
    var isEmpty: Bool {
        pendingInterjections.isEmpty
    }
}
