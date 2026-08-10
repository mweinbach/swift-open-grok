// MinimalCommit.swift
//
// Minimal-mode commit pipeline: which finalized blocks get printed into the
// terminal's native scrollback, and in what display mode. Ported from the
// pin (650c1db7): `xai-grok-pager-minimal/src/commit.rs` — the pure,
// terminal-agnostic half. The actual `insertBefore` call is injected by the
// caller (the per-frame draw loop, M2), exactly as upstream injects its
// closure: the "committed frontier" is the leading contiguous run of
// finalized, non-pending entries; everything past it stays in the live
// region until it finalizes.

/// Blank rows emitted after each committed block — and held after each
/// live-tail entry — in minimal mode (`commit.rs:42`).
///
/// Now `0`: adjacent blocks abut, relying on each block's own chrome to
/// read the boundary (a full separator row per block made the transcript
/// too airy — upstream dogfood feedback). The constant is kept so the
/// spacing stays tunable in one place. Whatever the value, it must be
/// applied identically on BOTH sides of the commit frontier (the committed
/// footprint and the live-tail footprint) so a block's total height is
/// unchanged when it crosses — otherwise the prompt shifts on every commit.
public let minimalBlockGap: UInt16 = 0

/// Whether the entry at the commit frontier may be committed to native
/// scrollback yet (`commit.rs:92-115`). `isLast` is whether it is the final
/// entry in the scrollback — the only one that may still be actively
/// streaming.
///
/// The load-bearing rules, carried from upstream:
///
/// - A block awaiting user input holds the frontier in EVERY turn state,
///   not just mid-turn: its rendered form still changes when the prompt
///   resolves, and committing it (print-once) would freeze the "waiting"
///   form on the terminal. The idle case is defensive — a pending mark must
///   never be committed out from under its modal.
/// - Once the turn is idle, everything else is stable and committable: the
///   tracker can leave a stale `isRunning` flag (a finalize missed at a
///   transition), and that stale flag must not permanently wedge the
///   frontier. The caller finalizes such entries before rendering.
/// - Mid-turn, two kinds commit despite a set `isRunning` flag: a BgTask
///   lifecycle block (the flag is animation-only; content never changes,
///   and an async task can outlive its turn — gating on the flag would hide
///   the task in the scrolled-out live tail until it finished), and a
///   non-last agent message (the tracker provably moved past it — it resets
///   its current-message pointer WITHOUT finishing the entry when a tool
///   follows, and holding on that stale flag would pile the rest of the
///   turn into the fixed-height live tail). A running TOOL may still update
///   its result, and the LAST entry may still be streaming — both stay live.
public func isCommittable(
    _ entry: MinimalScrollbackEntry,
    turnRunning: Bool,
    isLast: Bool
) -> Bool {
    if entry.isPendingUserInput {
        return false
    }
    if !turnRunning {
        return true
    }
    if !entry.isRunning {
        return true
    }
    switch entry.block {
    case .bgTask:
        return true
    case .agentMessage:
        return !isLast
    default:
        return false
    }
}

/// The display mode a block should be committed in (minimal mode,
/// print-once) — `commit.rs:122-141`. Stamped on BOTH the entry being
/// committed and the still-uncommitted live-tail entries, so a block's
/// height is identical either side of the frontier and the prompt does not
/// jerk when it crosses.
///
/// Policy: Edit tools always Expanded (diffs always full — K9, even
/// failed); successful lookups (Search / Read / ListDir / MemorySearch /
/// IntegrationSearch) Collapsed; every other or FAILED tool Truncated — a
/// failed lookup must stay visible enough to show its error; Thinking
/// Collapsed iff the `collapseThinking` toggle; everything else Expanded.
public func minimalCommitDisplayMode(
    for block: MinimalBlock,
    collapseThinking: Bool
) -> MinimalDisplayMode {
    switch block {
    case .toolCall(kind: .edit, error: _):
        return .expanded
    case let .toolCall(kind, _):
        switch kind {
        case .search, .read, .listDir, .memorySearch, .integrationSearch:
            return block.toolCallSucceeded == true ? .collapsed : .truncated
        default:
            return .truncated
        }
    case .thinking:
        return collapseThinking ? .collapsed : .expanded
    default:
        return .expanded
    }
}

/// One step of the frontier walk — the single classification shared by
/// every consumer (`commit.rs:149-158`). Keeping this in one place is
/// load-bearing: the commit pass, the will-commit resize gate, the viewport
/// sizing, and the tail renderer must all agree on where the frontier
/// stops, or a block's height flips between the live region and native
/// scrollback and the prompt jumps on commit.
private enum FrontierStep {
    /// Uncommitted and committable: a commit pass consumes it.
    case commit
    /// Already committed: skip over it (the id-set is authoritative; the
    /// scan cursor is only a lower-bound hint).
    case skip
    /// End of entries, or the first uncommitted non-committable entry —
    /// the live tail starts here.
    case stop
}

/// Classify the entry at `index` relative to the commit frontier
/// (`commit.rs:161-169`).
private func classify(
    _ state: MinimalScrollbackState,
    at index: Int,
    turnRunning: Bool
) -> FrontierStep {
    let isLast = index + 1 >= state.count
    guard let entry = state.entry(at: index) else {
        return .stop
    }
    if state.isCommitted(entry.id) {
        return .skip
    }
    if !isCommittable(entry, turnRunning: turnRunning, isLast: isLast) {
        return .stop
    }
    return .commit
}

/// Read-only projection of what a commit pass would do, for the consumers
/// that must agree with it without running it (`commit.rs:173-181`).
public struct MinimalFrontierScan: Sendable, Equatable {
    /// Index of the first entry a commit pass would NOT consume — where the
    /// live tail starts after this frame's commit.
    public let tailStart: Int
    /// Whether a commit pass would emit at least one block this frame.
    public let willCommit: Bool

    public init(tailStart: Int, willCommit: Bool) {
        self.tailStart = tailStart
        self.willCommit = willCommit
    }
}

/// Walk the frontier read-only — no cursor mutation, nothing marked
/// committed (`commit.rs:188-205`). Used by the overlay host's viewport
/// sizing and its commit gate (M3) — both run BEFORE the commit pass in the
/// frame and must mirror its stop condition exactly.
public func scanFrontier(
    _ state: MinimalScrollbackState,
    turnRunning: Bool
) -> MinimalFrontierScan {
    var i = state.commitScanCursor
    var willCommit = false
    while true {
        switch classify(state, at: i, turnRunning: turnRunning) {
        case .stop:
            return MinimalFrontierScan(tailStart: i, willCommit: willCommit)
        case .skip:
            i += 1
        case .commit:
            willCommit = true
            i += 1
        }
    }
}

/// Commit the leading contiguous run of newly-committable entries, in
/// insertion order (`commit.rs:225-248`). This is the ONE mutating frontier
/// walk; the production frame loop drives it and the ported tests drive it
/// directly, so the tested loop and the production loop cannot drift.
///
/// For each entry, `onCommit(state, index)` runs FIRST — the caller
/// finalizes/stamps the entry and renders it into native scrollback — and
/// only if it returns `true` is the entry marked committed. A `false`
/// return (the terminal write failed) stops the walk with the entry still
/// uncommitted and the cursor before it, so the next frame retries instead
/// of marking a block committed that never reached the terminal — a
/// print-once mode can never re-emit it, and the block would silently
/// vanish forever.
///
/// Returns the number of entries committed.
@discardableResult
public func commitLeadingRun(
    _ state: MinimalScrollbackState,
    turnRunning: Bool,
    onCommit: (MinimalScrollbackState, Int) -> Bool
) -> Int {
    var i = state.commitScanCursor
    var count = 0
    walk: while true {
        switch classify(state, at: i, turnRunning: turnRunning) {
        case .stop:
            break walk
        case .skip:
            i += 1
        case .commit:
            guard onCommit(state, i) else {
                break walk // emit failed — leave uncommitted, retry next frame
            }
            state.markCommitted(at: i)
            count += 1
            i += 1
        }
    }
    state.setCommitScanCursor(i)
    return count
}
