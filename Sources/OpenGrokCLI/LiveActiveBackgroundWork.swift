// LiveActiveBackgroundWork.swift
//
// Shared push/cache contract for the status-bar background-task chip and
// `PagerMotionState.hasBackgroundTasks`. Hosts emit idempotent upsert/remove
// events (and atomic same-kind replace for provisional→durable swaps); the
// interactive renderer owns a value-type cache and is the only reader used
// for paint/motion.
//
// Count definition matches Rust `TasksPane::running_count`
// (`tasks_pane.rs:1132-1149` @ `650c1db7`):
//   * outstanding shell + monitor tasks (both `.shell` — one map upstream)
//   * running subagents with no workflow run id
//   * every scheduled `/loop` entry
//   * active workflows
// ID sets (not ±1) keep unordered async delivery from double-counting or
// going negative. Blank ids never enter the cache. `.replace` swaps one
// kind's set in a single mutation so scheduler provisional→durable never
// paints a transient 0 or 2.

import Foundation

/// Kinds that contribute to the status-chip active count.
///
/// Monitors share `.shell` with background bash: Rust stores both in
/// `bg_tasks` and counts every `Running` entry once. A separate monitor
/// kind would double-count the same task id.
enum LiveActiveBackgroundWorkKind: String, Sendable, Hashable, CaseIterable {
    case shell
    case subagent
    case scheduled
    case workflow
}

/// Stable identity for one active entry. Equality is `(kind, id)` so the
/// same string may be live under two kinds without collision.
struct LiveActiveBackgroundWorkKey: Sendable, Hashable, Equatable {
    var kind: LiveActiveBackgroundWorkKind
    var id: String

    /// `nil` when `id` is empty — blank ids never become keys.
    init?(kind: LiveActiveBackgroundWorkKind, id: String) {
        guard !id.isEmpty else { return nil }
        self.kind = kind
        self.id = id
    }
}

/// Idempotent lifecycle event for the active-background-work cache.
enum LiveActiveBackgroundWorkEvent: Sendable, Hashable, Equatable {
    case upsert(LiveActiveBackgroundWorkKey)
    case remove(LiveActiveBackgroundWorkKey)
    /// Atomically replace one kind's membership. Other kinds are untouched.
    case replace(kind: LiveActiveBackgroundWorkKind, ids: Set<String>)

    /// `nil` when `id` is empty (typed false — caller skips the sink).
    static func upsert(
        kind: LiveActiveBackgroundWorkKind,
        id: String
    ) -> LiveActiveBackgroundWorkEvent? {
        guard let key = LiveActiveBackgroundWorkKey(kind: kind, id: id) else { return nil }
        return .upsert(key)
    }

    /// `nil` when `id` is empty (typed false — caller skips the sink).
    static func remove(
        kind: LiveActiveBackgroundWorkKind,
        id: String
    ) -> LiveActiveBackgroundWorkEvent? {
        guard let key = LiveActiveBackgroundWorkKey(kind: kind, id: id) else { return nil }
        return .remove(key)
    }

    /// Validated replace: trims each id and drops blanks. Always returns an
    /// event (an empty sanitized set clears that kind only). Named
    /// `replacing` so it does not collide with the `.replace(kind:ids:)`
    /// case constructor.
    static func replacing(
        kind: LiveActiveBackgroundWorkKind,
        ids: Set<String>
    ) -> LiveActiveBackgroundWorkEvent {
        .replace(kind: kind, ids: Self.sanitizedIDs(ids))
    }

    /// Trim whitespace and drop empty / whitespace-only ids.
    fileprivate static func sanitizedIDs(_ ids: Set<String>) -> Set<String> {
        var sanitized: Set<String> = []
        sanitized.reserveCapacity(ids.count)
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sanitized.insert(trimmed)
        }
        return sanitized
    }
}

/// Value-type ID sets owned by the renderer actor (not an actor itself).
///
/// Apply under the renderer's isolation; paint and motion read `count` /
/// `hasActive` from this cache only — never re-query host lists on the
/// hot path.
struct LiveActiveBackgroundWorkCache: Sendable, Equatable {
    private var shellIDs: Set<String> = []
    private var subagentIDs: Set<String> = []
    private var scheduledIDs: Set<String> = []
    private var workflowIDs: Set<String> = []

    init() {}

    /// Total active entries across all kinds — the status-chip numeral.
    var count: Int {
        shellIDs.count + subagentIDs.count + scheduledIDs.count + workflowIDs.count
    }

    /// Whether any counted work is outstanding (`PagerMotionState.hasBackgroundTasks`).
    var hasActive: Bool { count > 0 }

    /// Per-kind active count.
    func count(of kind: LiveActiveBackgroundWorkKind) -> Int {
        set(for: kind).count
    }

    /// Apply one event. Returns `true` when membership changed.
    ///
    /// Upsert of an already-present key and remove of an absent key are
    /// no-ops (`false`). `.replace` swaps exactly one kind's set in a
    /// single mutation (sanitizing blanks) so other kinds stay untouched.
    /// Blank keys cannot be constructed on upsert/remove, so those paths
    /// never count an empty id.
    @discardableResult
    mutating func apply(_ event: LiveActiveBackgroundWorkEvent) -> Bool {
        switch event {
        case .upsert(let key):
            return mutate(kind: key.kind) { $0.insert(key.id).inserted }
        case .remove(let key):
            return mutate(kind: key.kind) { $0.remove(key.id) != nil }
        case .replace(let kind, let ids):
            let next = LiveActiveBackgroundWorkEvent.sanitizedIDs(ids)
            return mutate(kind: kind) { current in
                guard current != next else { return false }
                current = next
                return true
            }
        }
    }

    /// Drop every tracked id. Used on session teardown so a lost remove
    /// during kill storms cannot leave the chip/motion armed.
    mutating func removeAll() {
        shellIDs.removeAll()
        subagentIDs.removeAll()
        scheduledIDs.removeAll()
        workflowIDs.removeAll()
    }

    private func set(for kind: LiveActiveBackgroundWorkKind) -> Set<String> {
        switch kind {
        case .shell: return shellIDs
        case .subagent: return subagentIDs
        case .scheduled: return scheduledIDs
        case .workflow: return workflowIDs
        }
    }

    private mutating func mutate(
        kind: LiveActiveBackgroundWorkKind,
        _ body: (inout Set<String>) -> Bool
    ) -> Bool {
        switch kind {
        case .shell: return body(&shellIDs)
        case .subagent: return body(&subagentIDs)
        case .scheduled: return body(&scheduledIDs)
        case .workflow: return body(&workflowIDs)
        }
    }
}

/// Optional async sink hosts hold and call without importing the renderer.
///
/// Composition installs `{ [weak renderer] in await renderer.apply…($0) }`.
/// Hosts fire-and-forget `await sink?(event)` at lifecycle edges.
typealias LiveActiveBackgroundWorkSink =
    @Sendable (LiveActiveBackgroundWorkEvent) async -> Void
