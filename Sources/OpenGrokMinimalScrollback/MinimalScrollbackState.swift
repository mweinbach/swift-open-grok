// MinimalScrollbackState.swift
//
// The ordered entry store with the minimal-mode committed frontier. Ported
// from the pin (650c1db7): `xai-grok-pager/src/scrollback/state/mod.rs` —
// the content-management ops the commit pipeline depends on (`push`
// `:578`, `insert_block_before` `:651`, `remove_entry` `:710`,
// `remove_from` `:739`, `clear` `:1075`, `set_pending_user_input` `:1491`)
// and the frontier section (`:1093-1150`).
//
// The frontier contract, verbatim from upstream: the authoritative state is
// the per-entry `committed` id-set, which travels with the entry across
// index shifts; `commitScanCursor` is ONLY a lower-bound hint that keeps
// the per-frame scan O(new). The cursor may move down freely (the scan
// re-skips committed entries), but must never sit above an uncommitted
// entry's index — an entry below the cursor is scanned by nobody: neither
// committed to native scrollback nor drawn in the live tail, silently
// missing from minimal mode (`state/mod.rs:88-100`). Every mutating op
// below keeps that invariant; the ported tests pin each one.

public final class MinimalScrollbackState {
    private var entries: [MinimalScrollbackEntry] = []
    private var committedIDs: Set<MinimalEntryID> = []
    // Start at 1 so 0 can be a sentinel (`state/mod.rs:239`).
    private var nextID: UInt64 = 1
    private var scanCursor: Int = 0
    private var expandRing: [MinimalEntryID] = []

    /// Maximum folded-commit ids retained for `Ctrl+E` / `/expand`
    /// (`state/mod.rs:1125`).
    private static let expandRingCap = 256

    public init() {}

    // MARK: - Content management

    /// Append an entry, assigning it a unique id (`state/mod.rs:578`).
    @discardableResult
    public func push(_ entry: MinimalScrollbackEntry) -> MinimalEntryID {
        var entry = entry
        let id = MinimalEntryID(nextID)
        nextID += 1
        entry.id = id
        entries.append(entry)
        return id
    }

    /// Append a finalized block (`state/mod.rs:638`).
    @discardableResult
    public func pushBlock(_ block: MinimalBlock) -> MinimalEntryID {
        push(MinimalScrollbackEntry(block))
    }

    /// Insert a finalized block immediately BEFORE `anchor`; falls back to
    /// append when the anchor is gone (`state/mod.rs:651-685`).
    ///
    /// The anchor must not already be committed: a terminal's native
    /// scrollback is append-only, so inserting above a block already printed
    /// there would emit the new block below content that logically follows
    /// it. Debug-asserted, as upstream.
    @discardableResult
    public func insertBlockBefore(
        anchor: MinimalEntryID,
        block: MinimalBlock
    ) -> MinimalEntryID {
        guard let index = indexOfID(anchor) else {
            return pushBlock(block)
        }
        assert(
            !committedIDs.contains(anchor),
            "insertBlockBefore: anchor \(anchor) is already committed — the inserted "
                + "block would print out of order in native scrollback"
        )
        var entry = MinimalScrollbackEntry(block)
        let id = MinimalEntryID(nextID)
        nextID += 1
        entry.id = id
        entries.insert(entry, at: index)
        // Pull the hint back so the inserted entry is inside the scanned
        // range; committed entries above it are re-skipped by id.
        scanCursor = min(scanCursor, index)
        return id
    }

    /// Remove an entry by id; `false` when absent (`state/mod.rs:710-737`).
    @discardableResult
    public func removeEntry(_ id: MinimalEntryID) -> Bool {
        guard let index = indexOfID(id) else {
            return false
        }
        entries.remove(at: index)
        committedIDs.remove(id)
        // Clamping alone is not enough: removing BELOW the cursor shifts
        // every uncommitted entry down one, and an unmoved cursor would
        // strand the first of them beneath it — never committed, never
        // drawn (the `/resume` placeholder-removal regression,
        // `state/mod.rs:726-731`).
        if index < scanCursor {
            scanCursor -= 1
        }
        scanCursor = min(scanCursor, entries.count)
        return true
    }

    /// Drop every entry from `index` on, returning them in order
    /// (`state/mod.rs:739-768`). The rewind path: without the cursor clamp
    /// this would leave the cursor past the end and silently skip future
    /// commits.
    @discardableResult
    public func removeFrom(_ index: Int) -> [MinimalScrollbackEntry] {
        guard index < entries.count else {
            return []
        }
        let removed = Array(entries[index...])
        entries.removeSubrange(index...)
        for entry in removed {
            committedIDs.remove(entry.id)
        }
        scanCursor = min(scanCursor, entries.count)
        return removed
    }

    /// Remove all entries and reset the frontier (`state/mod.rs:1075-1091`).
    /// `nextID` is deliberately NOT reset, so ids are never reused.
    public func clear() {
        entries.removeAll()
        committedIDs.removeAll()
        scanCursor = 0
        expandRing.removeAll()
    }

    public var count: Int {
        entries.count
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// Entry by index (`state/mod.rs:1152`).
    public func entry(at index: Int) -> MinimalScrollbackEntry? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    /// Mutate the entry at `index` in place (`get_mut`,
    /// `state/mod.rs:1157`); `false` when out of range.
    @discardableResult
    public func updateEntry(
        at index: Int,
        _ mutate: (inout MinimalScrollbackEntry) -> Void
    ) -> Bool {
        guard entries.indices.contains(index) else { return false }
        mutate(&entries[index])
        return true
    }

    /// Index of an entry by id (`state/mod.rs:1334`).
    public func indexOfID(_ id: MinimalEntryID) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    /// Flip an entry's running flag (`set_entry_running`,
    /// `state/mod.rs:1184-1199`, minus the tool-timing and finish-flash
    /// arms, which are renderer concerns). The M4 frame driver uses this to
    /// mirror item lifecycle transitions and to finalize a stale-running
    /// entry before the commit pass renders it (`commit.rs:451-456`).
    public func setEntryRunning(_ id: MinimalEntryID, running: Bool) {
        guard let index = indexOfID(id) else { return }
        entries[index].isRunning = running
    }

    /// Flag an entry as awaiting (or no longer awaiting) user input.
    /// Returns `true` only when the flag actually changed; `false` for an
    /// unknown id or a repeated value (`state/mod.rs:1491-1508`).
    @discardableResult
    public func setPendingUserInput(_ id: MinimalEntryID, pending: Bool) -> Bool {
        guard let index = indexOfID(id) else {
            return false
        }
        guard entries[index].isPendingUserInput != pending else {
            return false
        }
        entries[index].isPendingUserInput = pending
        return true
    }

    // MARK: - Minimal-mode committed frontier (state/mod.rs:1093-1150)

    /// Lowest entry index that may still be uncommitted — a hint, not truth.
    public var commitScanCursor: Int {
        scanCursor
    }

    /// Advance the scan cursor, clamped to the entry count
    /// (`state/mod.rs:1107-1109`).
    public func setCommitScanCursor(_ cursor: Int) {
        scanCursor = min(cursor, entries.count)
    }

    /// Whether the entry was already emitted into native scrollback
    /// (`state/mod.rs:1112-1114`).
    public func isCommitted(_ id: MinimalEntryID) -> Bool {
        committedIDs.contains(id)
    }

    /// Mark the entry at `index` committed; no-op out of range
    /// (`state/mod.rs:1118-1122`).
    public func markCommitted(at index: Int) {
        guard let entry = entry(at: index) else { return }
        committedIDs.insert(entry.id)
    }

    /// Record a block committed in a folded mode so `Ctrl+E` / `/expand`
    /// can re-print it in full later; bounded — the oldest id drops once
    /// the ring is full (`state/mod.rs:1131-1136`).
    public func recordCommittedForExpand(_ id: MinimalEntryID) {
        expandRing.append(id)
        while expandRing.count > Self.expandRingCap {
            expandRing.removeFirst()
        }
    }

    /// Pop the most-recently committed folded entry that still exists;
    /// stale ids (removed by rewind / clear) are skipped
    /// (`state/mod.rs:1142-1149`).
    public func takeExpandableCommitted() -> MinimalEntryID? {
        while let id = expandRing.popLast() {
            if indexOfID(id) != nil {
                return id
            }
        }
        return nil
    }
}
