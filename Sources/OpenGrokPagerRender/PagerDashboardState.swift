// PagerDashboardState.swift
//
// Wave 18 B1-s: the Agent Dashboard's value model — the port of
// `views/dashboard/state.rs` (grouping, filter, pins, reorder, gc) plus
// the parts of `row.rs` (classification vocabulary, filter, sort,
// clustering, subagent overflow) and `render.rs`
// (`build_dashboard_lines` / `focusables`, idle overflow) that decide
// WHAT is on screen rather than how it is painted, all at upstream pin
// 650c1db7.
//
// Everything here is a pure value type: no actors, no environment reads,
// no I/O. The composition owns the feeds (session tabs, the dormant
// catalog, subagent snapshots), classifies each into a
// `PagerDashboardRowInput`, and calls `rows(from:)` → `lines(from:)`;
// this side owns ordering, grouping, filtering, folding, and the cursor
// vocabulary. The split matches `PagerTasksPane`: the composition
// prebuilds entries, the render target owns structure.
//
// LEAD RULINGS this file is written against (Wave 18 B1):
//   - Dormant (on-disk catalog) rows LAND as first-class rows, mapped to
//     `.inactive` — upstream parity with `build_rows_with_roster`
//     (`row.rs:145-167`) where `roster_activity_to_state` folds
//     Idle|Dormant into `RowState::Inactive` (`row.rs:258-269`).
//   - Directory grouping SHIPS (the listings carry real cwds).
//   - `Done` / `Failed` / `Blocked` sections never render, because no
//     port classifier emits those states. The cases still exist: the
//     filter grammar accepts their tokens verbatim (upstream parity,
//     and `s:done` returning an empty list is better feedback than
//     `s:done` silently becoming a substring search), and
//     `groupPriority` / `groupLabel` stay total so a future classifier
//     needs no edits here.

import Foundation

// MARK: - Row state vocabulary

/// Coarse state used for grouping (`state.rs:190-259`).
///
/// Case order is upstream's declaration order, NOT priority order —
/// priority is `groupPriority`, deliberately separate so the two can
/// disagree (`Blocked` declares last-but-one and ranks third).
public enum PagerDashboardRowState: Sendable, Equatable, Hashable, CaseIterable {
    /// Pending permission OR a pending ask-user question.
    case needsInput
    /// Live turn or command running.
    case working
    /// Alive, idle.
    case idle
    /// A catalog-only session: on disk, not attached in this process.
    /// Only the dormant feed produces this — a live tab never classifies
    /// as `.inactive`, so the Idle section stays about sessions you are
    /// actively cycling between (`state.rs:201-207`).
    case inactive
    /// Finished + status "completed". Never emitted by this port.
    case completed
    /// Finished + status failed/cancelled. Never emitted by this port.
    case failed
    /// Goal blocked / paused. Reserved upstream, unused here.
    case blocked

    /// The one "may be deleted" predicate, shared by the renderer's `[✗]`
    /// and the dispatcher (`state.rs:216-225`): only settled rows
    /// qualify, so an in-flight turn is never wiped.
    public var allowsDelete: Bool {
        switch self {
        case .idle, .inactive, .completed, .failed: return true
        case .needsInput, .working, .blocked: return false
        }
    }

    /// Sort priority inside a state group; higher floats up
    /// (`state.rs:227-242`). Pinned rows float above all of these.
    public var groupPriority: Int {
        switch self {
        case .needsInput: return 6
        case .working: return 5
        case .blocked: return 4
        case .idle: return 3
        // Below Idle (not loaded here, so less immediately actionable)
        // but above Done/Failed (still live, resumable sessions).
        case .inactive: return 2
        case .completed: return 1
        case .failed: return 0
        }
    }

    /// Human-readable group header (`state.rs:244-258`). "Done" reads
    /// cleaner as a header than the past-tense "Completed".
    public var groupLabel: String {
        switch self {
        case .needsInput: return "Awaiting"
        case .working: return "Working"
        case .idle: return "Idle"
        case .inactive: return "Inactive"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        }
    }

    /// Parse a state from a user token, accepting upstream's synonyms
    /// (`parse_row_state_token`, `state.rs:4866-4891`).
    ///
    /// Normalisation drops `-`, `_` and space and lowercases ASCII, so
    /// `needs-input`, `needs_input`, `Needs Input` and `NEEDSINPUT` are
    /// one token. ASCII-only lowering on purpose: upstream uses
    /// `to_ascii_lowercase`, and Swift's Unicode-aware `lowercased()`
    /// would fold non-ASCII characters upstream leaves alone.
    public static func parseToken(_ token: String) -> PagerDashboardRowState? {
        var normalised = ""
        normalised.reserveCapacity(token.count)
        for character in token {
            if character == "-" || character == "_" || character == " " { continue }
            if let ascii = character.asciiValue, ascii >= 65, ascii <= 90 {
                normalised.append(Character(UnicodeScalar(ascii + 32)))
            } else {
                normalised.append(character)
            }
        }
        switch normalised {
        case "needsinput", "needs", "input": return .needsInput
        case "working", "busy", "running": return .working
        case "idle": return .idle
        case "inactive", "dormant": return .inactive
        case "completed", "done": return .completed
        case "failed", "errored", "cancelled", "canceled": return .failed
        case "blocked", "paused": return .blocked
        default: return nil
        }
    }
}

// MARK: - Grouping

/// Grouping mode (`state.rs:293-313`). Ctrl+G flips it; the choice
/// persists under `[dashboard] grouping`.
public enum PagerDashboardGrouping: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Group by row state (the default).
    case state
    /// One section per working directory.
    case directory

    /// Two-way flip — there is no third mode, so this is a toggle rather
    /// than a cycle (`Grouping::toggled`, `state.rs:302-309`).
    public func toggled() -> PagerDashboardGrouping {
        switch self {
        case .state: return .directory
        case .directory: return .state
        }
    }
}

// MARK: - Row identity

/// Stable identity for a dashboard row.
///
/// Ports `DashboardRowId` (`state.rs`) with the port's three grounded
/// kinds: a live session tab, a subagent child of one, and a dormant
/// on-disk session from the catalog. Upstream's `Roster` variant is this
/// port's `.dormant` — same role (a session another process owns / this
/// one has not attached), different feed.
///
/// Upstream keys top-level rows by a per-process `AgentId`; this port
/// keys by the session id directly, which is what persistence wants
/// anyway (`PersistedRowId`, `state.rs:135-181`) and removes upstream's
/// resolve-at-open indirection for live rows.
public enum PagerDashboardRowID: Sendable, Equatable, Hashable {
    case session(String)
    case subagent(parent: String, child: String)
    case dormant(String)

    /// The session id a row belongs to: itself for top-level and dormant
    /// rows, the parent's for a subagent.
    public var owningSessionID: String {
        switch self {
        case .session(let id): return id
        case .subagent(let parent, _): return parent
        case .dormant(let id): return id
        }
    }
}

extension PagerDashboardRowID: Comparable {
    /// A TOTAL order, and that is the point: it is the final tiebreak in
    /// `sortRows`, and `Array.sort` in Swift is NOT stable. Without a
    /// tiebreak that can never return "equal" for two distinct rows, an
    /// all-else-equal group would shuffle between rebuilds — the same
    /// determinism upstream buys with
    /// `sort_rows_tiebreaks_by_id_when_keys_equal` (`row.rs:889-895`).
    public static func < (lhs: PagerDashboardRowID, rhs: PagerDashboardRowID) -> Bool {
        if lhs.variantRank != rhs.variantRank { return lhs.variantRank < rhs.variantRank }
        switch (lhs, rhs) {
        case (.session(let a), .session(let b)): return a < b
        case (.dormant(let a), .dormant(let b)): return a < b
        case (.subagent(let aParent, let aChild), .subagent(let bParent, let bChild)):
            if aParent != bParent { return aParent < bParent }
            return aChild < bChild
        default: return false
        }
    }

    private var variantRank: Int {
        switch self {
        case .session: return 0
        case .subagent: return 1
        case .dormant: return 2
        }
    }
}

// MARK: - Filter

/// Transport type for a parsed filter, kept separate from
/// `PagerDashboardFilter` exactly as upstream keeps `FilterValue`
/// separate from `Filter` (`state.rs:358-375`): parsing reports what was
/// typed, `PagerDashboardFilter.from(_:)` decides whether it filters.
public enum PagerDashboardFilterValue: Sendable, Equatable {
    case none
    case agent(String)
    case state(PagerDashboardRowState)
    case substring(String)
}

/// A filter over the visible rows (`state.rs:315-356`). Never persisted
/// — it is a per-open query, not a preference.
public enum PagerDashboardFilter: Sendable, Equatable {
    /// Show everything.
    case none
    /// `a:<name>` — case-insensitive substring on the row label OR its
    /// parent's label (so filtering by an agent keeps its children).
    case agent(String)
    /// `s:<state>` — exact state match.
    case state(PagerDashboardRowState)
    /// Free text — case-insensitive substring on label OR cwd display.
    case substring(String)

    /// Whether this filter would hide anything. Drives
    /// Esc-clears-the-filter-before-closing (`Filter::is_active`,
    /// `state.rs:351-355`).
    public var isActive: Bool {
        if case .none = self { return false }
        return true
    }

    /// Collapse a parsed value into a filter, turning whitespace-only
    /// needles into "no filter" (`Filter::from_value`, `state.rs:327-348`).
    /// The needle itself is kept untrimmed — only the emptiness TEST
    /// trims, matching upstream.
    public static func from(_ value: PagerDashboardFilterValue) -> PagerDashboardFilter {
        switch value {
        case .none:
            return .none
        case .agent(let needle):
            return needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .none : .agent(needle)
        case .state(let state):
            return .state(state)
        case .substring(let needle):
            return needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .none : .substring(needle)
        }
    }

    /// Parse the dispatch/search buffer into a filter value
    /// (`parse_filter`, `state.rs:4831-4864`). First match wins:
    ///
    ///   - `a:`     (empty after trim) → clear the filter
    ///   - `a:name` → agent match
    ///   - `s:`     (empty after trim) → clear the filter
    ///   - `s:<known>`   → state match
    ///   - `s:<unknown>` → substring on the REST, not the whole token
    ///   - `#<n>`   → substring KEEPING the `#`, so it never matches
    ///               arbitrary digits inside a label
    ///   - anything else → substring on the trimmed text
    ///
    /// DISCREPANCY, recorded deliberately: upstream's doc comment
    /// (`state.rs:4822-4825`) says "`s:` (empty) → substring match" and
    /// that unknown state tokens "fall back to substring" on the full
    /// `s:foobar`. Neither is what the code does — `:4844` returns
    /// `FilterValue::None` for the empty case and `:4846` builds the
    /// substring from `rest`, and upstream's own tests pin both
    /// (`filter_parser_state_empty_is_none` `:5219-5226`,
    /// `filter_parser_state_unknown_falls_back_to_substring` `:5213-5218`
    /// asserting `"foobar"`, not `"s:foobar"`). Code + tests are
    /// authoritative here; the stale prose is not ported.
    public static func parse(_ text: String) -> PagerDashboardFilterValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("a:") {
            let rest = String(trimmed.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? .none : .agent(rest)
        }
        if trimmed.hasPrefix("s:") {
            let rest = String(trimmed.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `s:` empty is consistent with `a:` empty: both clear.
            if rest.isEmpty { return .none }
            if let parsed = PagerDashboardRowState.parseToken(rest) { return .state(parsed) }
            // Unknown state token → substring on the REST, so the user
            // still sees their typed text matched against labels AND
            // realises the state path did not take effect.
            return .substring(rest)
        }
        if trimmed.hasPrefix("#") {
            return .substring("#" + String(trimmed.dropFirst()))
        }
        return .substring(trimmed)
    }

    /// Filter a row list (`apply_filter`, `row.rs:847-880`).
    ///
    /// Two load-bearing rules: the needle is lowercased ONCE (a 100-row
    /// list must not allocate 100 lowercase strings per keystroke), and
    /// a `… N more` placeholder is ALWAYS kept — it is a structural
    /// marker, not a row, and dropping it would silently under-report
    /// the hidden count while filtering.
    public func apply(to rows: [PagerDashboardRow]) -> [PagerDashboardRow] {
        if case .none = self { return rows }
        let needle: String
        switch self {
        case .agent(let value), .substring(let value): needle = value.lowercased()
        case .none, .state: needle = ""
        }
        return rows.filter { row in
            if row.isMorePlaceholder { return true }
            switch self {
            case .none:
                return true
            case .agent:
                return row.label.lowercased().contains(needle)
                    || (row.parentLabel?.lowercased().contains(needle) ?? false)
            case .state(let wanted):
                return row.state == wanted
            case .substring:
                if needle.isEmpty { return true }
                return row.label.lowercased().contains(needle)
                    || row.cwdDisplay.lowercased().contains(needle)
            }
        }
    }
}

// MARK: - Sections, rows, lines, cursor targets

/// Stable identity for a collapsible section header (`state.rs:262-271`).
///
/// Keyed by group identity, never by position: collapse state and the
/// header cursor have to survive a re-sort and row churn, and a
/// positional key would silently retarget when a row changes state.
/// Sections exist only in `.state` grouping.
public enum PagerDashboardSectionKey: Sendable, Equatable, Hashable {
    case pinned
    case state(PagerDashboardRowState)
}

/// What the composition hands in per row: identity, display text, the
/// classified state, and the two sort inputs. Everything derived
/// (`cwdDisplay`, `pinned`, the overflow placeholders) is computed here.
public struct PagerDashboardRowInput: Sendable, Equatable {
    public var id: PagerDashboardRowID
    public var label: String
    /// Dim secondary line under the title (last tool call, model id, …).
    public var detail: String?
    public var state: PagerDashboardRowState
    /// Raw working directory. Compacted against `home` for display and
    /// for the substring filter, so both agree.
    public var cwd: String
    /// Wall-clock moment of the row's last change: the age column and
    /// the recency tiebreak. Wall clock rather than a monotonic anchor
    /// because catalog timestamps can predate this process entirely
    /// (`row.rs:40-50`).
    public var lastChangeAt: Date
    /// 0 = top-level, 1 = subagent under its parent.
    public var indent: Int
    /// The parent's display title — scopes the `a:` filter to a whole
    /// cluster and labels the overflow placeholder.
    public var parentLabel: String?

    public init(
        id: PagerDashboardRowID,
        label: String,
        detail: String? = nil,
        state: PagerDashboardRowState,
        cwd: String = "",
        lastChangeAt: Date,
        indent: Int = 0,
        parentLabel: String? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.state = state
        self.cwd = cwd
        self.lastChangeAt = lastChangeAt
        self.indent = indent
        self.parentLabel = parentLabel
    }
}

/// A built row: the input plus everything the state machinery derives.
public struct PagerDashboardRow: Sendable, Equatable {
    public var id: PagerDashboardRowID
    public var label: String
    public var detail: String?
    public var state: PagerDashboardRowState
    public var cwd: String
    /// `cwd` compacted against `$HOME` (`~/rest`).
    public var cwdDisplay: String
    public var lastChangeAt: Date
    public var indent: Int
    public var parentLabel: String?
    /// Pinned rows float above every group.
    public var pinned: Bool
    /// True for a `… N more` collapse placeholder: dimmed, not
    /// selectable, and immune to filtering.
    public var isMorePlaceholder: Bool
    /// How many rows the placeholder stands for.
    public var moreCount: Int

    public init(
        id: PagerDashboardRowID,
        label: String,
        detail: String? = nil,
        state: PagerDashboardRowState,
        cwd: String = "",
        cwdDisplay: String = "",
        lastChangeAt: Date,
        indent: Int = 0,
        parentLabel: String? = nil,
        pinned: Bool = false,
        isMorePlaceholder: Bool = false,
        moreCount: Int = 0
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.state = state
        self.cwd = cwd
        self.cwdDisplay = cwdDisplay
        self.lastChangeAt = lastChangeAt
        self.indent = indent
        self.parentLabel = parentLabel
        self.pinned = pinned
        self.isMorePlaceholder = isMorePlaceholder
        self.moreCount = moreCount
    }
}

/// One painted line (`DashboardLine`, `render.rs:1270-1295`). The
/// renderer iterates THIS, not `rows`, so header lines count against the
/// viewport's height budget.
public enum PagerDashboardLine: Sendable, Equatable {
    /// `Pinned N` — only when grouping is on.
    case pinnedHeader(count: Int)
    /// Textless separator below the pinned block when grouping is off.
    case divider
    /// A per-state section header with its true group size.
    case header(state: PagerDashboardRowState, count: Int)
    case row(PagerDashboardRow)
    /// The Idle group's fold toggle: `hidden` rows behind it, `expanded`
    /// when `idleShowAll` has flipped it open.
    case idleOverflow(hidden: Int, expanded: Bool)
}

/// A keyboard cursor target, in display order (`Focusable`,
/// `state.rs:280-290`; `focusables`, `render.rs:1490-1516`). Derived
/// from the SAME line list the renderer paints, so navigation and
/// rendering can never disagree about what is on screen.
public enum PagerDashboardFocusable: Sendable, Equatable {
    case section(PagerDashboardSectionKey)
    case row(PagerDashboardRowID)
    case idleOverflow
}

// MARK: - State

/// The dashboard's whole in-memory state.
///
/// A value type the composition stores and mutates; `rows(from:)` and
/// `lines(from:)` are pure functions of it, so a test can assert the
/// exact on-screen structure without a terminal.
///
/// Persisted: `grouping`, `pinned`, `reorder` (plus the `enabled` flag,
/// which lives on the store side). NOT persisted: `filter`,
/// `searchActive`, `collapsedSections`, `idleShowAll`, and the cursor —
/// all per-open (`state.rs:377-399`).
public struct PagerDashboardState: Sendable, Equatable {
    /// Maximum subagents shown per parent before the rest fold
    /// (`MAX_VISIBLE_SUBAGENTS`, `row.rs:98`).
    public static let maxVisibleSubagents = 8
    /// Maximum top-level Idle rows before the tail folds
    /// (`MAX_VISIBLE_IDLE`, `render.rs:1466`).
    public static let maxVisibleIdle = 8
    /// Idle rows touched within this window are never folded, even past
    /// the cap — a burst of fresh sessions stays visible
    /// (`IDLE_FRESHNESS`, `render.rs:1471`).
    public static let idleFreshness: TimeInterval = 60 * 60
    /// Never fold fewer than this: one folded row costs exactly the
    /// vertical space its overflow line takes (`MIN_IDLE_FOLD`,
    /// `render.rs:1475`).
    public static let minIdleFold = 2

    /// Pinned rows. A `Set` and not an ordered collection on purpose —
    /// pinning carries no order of its own, the sort decides it — which
    /// means anything WRITING these must sort first (see
    /// `PagerDashboardStore`).
    public var pinned: Set<PagerDashboardRowID>
    /// Explicit user ordering (Shift+↑/↓). An ordering LIST, not an
    /// index map: membership plus position is the whole model, and a row
    /// absent from it simply sorts after every listed one in its group.
    public var reorder: [PagerDashboardRowID]
    public var grouping: PagerDashboardGrouping
    public var filter: PagerDashboardFilter
    /// Ctrl+/ live-search. Needed ALONGSIDE the filter check when
    /// deciding whether to fold idle rows: entering search clears the
    /// filter to `.none` (the query rebuilds it per keystroke), so an
    /// empty search box would otherwise leave old rows folded while the
    /// user is actively looking for one (`render.rs:1383-1387`).
    public var searchActive: Bool
    /// Collapsed sections. In-memory for the dashboard's lifetime.
    public var collapsedSections: Set<PagerDashboardSectionKey>
    /// When true the Idle group shows everything; the fold line flips it.
    public var idleShowAll: Bool
    /// Row cursor. Mutually exclusive with `selectedSection` /
    /// `selectedIdleOverflow`.
    public var selected: PagerDashboardRowID?
    /// Section-header cursor.
    public var selectedSection: PagerDashboardSectionKey?
    /// Cursor on the Idle fold line.
    public var selectedIdleOverflow: Bool
    /// `$HOME` for cwd compaction. Injected rather than read here: the
    /// render target does no environment lookups, so the composition
    /// (which already resolves OPENGROK_HOME) supplies it.
    public var home: String?

    public init(
        pinned: Set<PagerDashboardRowID> = [],
        reorder: [PagerDashboardRowID] = [],
        grouping: PagerDashboardGrouping = .state,
        filter: PagerDashboardFilter = .none,
        searchActive: Bool = false,
        collapsedSections: Set<PagerDashboardSectionKey> = [],
        idleShowAll: Bool = false,
        selected: PagerDashboardRowID? = nil,
        selectedSection: PagerDashboardSectionKey? = nil,
        selectedIdleOverflow: Bool = false,
        home: String? = nil
    ) {
        self.pinned = pinned
        self.reorder = reorder
        self.grouping = grouping
        self.filter = filter
        self.searchActive = searchActive
        self.collapsedSections = collapsedSections
        self.idleShowAll = idleShowAll
        self.selected = selected
        self.selectedSection = selectedSection
        self.selectedIdleOverflow = selectedIdleOverflow
        self.home = home
    }

    // MARK: Mutations

    /// Toggle the pin on `id`, returning the new pinned-ness
    /// (`toggle_pin_selected`, `state.rs:1798-1805`).
    @discardableResult
    public mutating func togglePin(_ id: PagerDashboardRowID) -> Bool {
        if pinned.remove(id) != nil { return false }
        pinned.insert(id)
        return true
    }

    /// Ctrl+T on the selected row. Returns the toggled id, or nil when
    /// nothing is selected.
    @discardableResult
    public mutating func togglePinSelected() -> PagerDashboardRowID? {
        guard let id = selected else { return nil }
        togglePin(id)
        return id
    }

    /// Ctrl+G (`toggle_grouping`, `state.rs:1782-1796`).
    ///
    /// Sections exist only in `.state` grouping, so a header cursor has
    /// to go somewhere valid when grouping leaves it. Upstream parks it
    /// on the `[+ New Agent]` button; this port has no such button in
    /// the overlay, so the header cursor is simply dropped and the
    /// overlay falls back to its own first selectable row — recorded
    /// divergence. Upstream additionally clears its manual-scroll latch;
    /// the port's viewport lives in `PagerOverlay`, so there is nothing
    /// to clear here.
    public mutating func toggleGrouping() {
        grouping = grouping.toggled()
        if selectedSection != nil, grouping != .state {
            selectedSection = nil
        }
    }

    public mutating func toggleSection(_ key: PagerDashboardSectionKey) {
        if collapsedSections.remove(key) == nil { collapsedSections.insert(key) }
    }

    public func isCollapsed(_ key: PagerDashboardSectionKey) -> Bool {
        collapsedSections.contains(key)
    }

    /// Shift+↑ / Shift+↓ on the selected row
    /// (`dispatch_dashboard_reorder`, `dispatch/dashboard.rs:2329-2367`).
    ///
    /// The list is an ORDERING, so the moves are list surgery, not index
    /// arithmetic: moving up out of position 0 REMOVES the entry (the
    /// row returns to natural order rather than pinning itself to the
    /// top forever), moving down off the tail is a no-op, and a row not
    /// yet in the list is inserted at the front (up) or appended (down).
    @discardableResult
    public mutating func reorderSelected(up: Bool) -> PagerDashboardRowID? {
        guard let selection = selected else { return nil }
        reorderRow(selection, up: up)
        return selection
    }

    /// The reorder mechanics, id-explicit for callers that already know
    /// the target.
    public mutating func reorderRow(_ id: PagerDashboardRowID, up: Bool) {
        let position = reorder.firstIndex(of: id)
        if up {
            switch position {
            case .some(0):
                reorder.removeFirst()
            case .some(let index):
                reorder.swapAt(index, index - 1)
            case .none:
                reorder.insert(id, at: 0)
            }
        } else {
            switch position {
            case .some(let index) where index + 1 < reorder.count:
                reorder.swapAt(index, index + 1)
            case .some:
                break // Already at the bottom.
            case .none:
                reorder.append(id)
            }
        }
    }

    /// Drop references to rows that no longer exist (`gc_stale_refs`,
    /// `state.rs:1736-1780`). Called at open time, after the persisted
    /// pins/reorder are resolved against the live feeds.
    ///
    /// `reorder` is filtered rather than rebuilt so the surviving
    /// entries keep their relative positions — the whole point of the
    /// list is its order, and a set-based gc would destroy it.
    public mutating func gcStaleRefs(isAlive: (PagerDashboardRowID) -> Bool) {
        pinned = pinned.filter(isAlive)
        reorder = reorder.filter(isAlive)
        if let selection = selected, !isAlive(selection) { selected = nil }
    }

    // MARK: cwd display

    /// Compact a path against `$HOME` (`compact_cwd`, `state.rs:5108-5128`).
    ///
    /// Matching is COMPONENT-wise, not string-prefix: upstream's
    /// `Path::strip_prefix` refuses to match `/Users/foobar` against a
    /// home of `/Users/foo`, and a naive `hasPrefix` here would render
    /// that as `~bar`. The `cwd == home` case collapses to a bare `~`
    /// rather than upstream's earlier `~/` with a trailing slash.
    public static func compactCWD(_ cwd: String, home: String?) -> String {
        guard let home, !home.isEmpty else { return cwd }
        guard cwd.hasPrefix("/") == home.hasPrefix("/") else { return cwd }
        let cwdParts = pathComponents(cwd)
        let homeParts = pathComponents(home)
        guard !homeParts.isEmpty, cwdParts.count >= homeParts.count,
              Array(cwdParts.prefix(homeParts.count)) == homeParts else { return cwd }
        let rest = cwdParts.dropFirst(homeParts.count)
        if rest.isEmpty { return "~" }
        return "~/" + rest.joined(separator: "/")
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: Row building

    /// Build the display row list: derive `cwdDisplay` / `pinned`, fold
    /// each parent's subagent overflow, filter, then sort
    /// (`build_rows_with_roster`, `row.rs:145-167`).
    ///
    /// Order matters. The overflow placeholder is created BEFORE the
    /// filter so its count reflects the true child total, and the sort
    /// runs last so pins and reorder apply to what actually survived.
    public func rows(from inputs: [PagerDashboardRowInput]) -> [PagerDashboardRow] {
        var built = foldSubagentOverflow(inputs)
        built = filter.apply(to: built)
        return Self.sortRows(built, grouping: grouping, reorder: reorder)
    }

    /// Cap each parent's children at `maxVisibleSubagents`, appending a
    /// `… N more` placeholder inside the parent's cluster
    /// (`row.rs:212-250`).
    ///
    /// The child ORDER is the composition's (running first, then newest
    /// — the tasks-pane convention); this side only truncates. Upstream
    /// stamps the placeholder with `SystemTime::now()`; the port reuses
    /// the parent's `lastChangeAt` instead, which is deterministic in
    /// tests and behaviourally identical because a child row never sorts
    /// independently of its cluster.
    private func foldSubagentOverflow(
        _ inputs: [PagerDashboardRowInput]
    ) -> [PagerDashboardRow] {
        var out: [PagerDashboardRow] = []
        out.reserveCapacity(inputs.count)
        var index = 0
        while index < inputs.count {
            let parent = inputs[index]
            out.append(row(from: parent))
            index += 1
            var kept = 0
            var total = 0
            while index < inputs.count, inputs[index].indent > 0 {
                total += 1
                if kept < Self.maxVisibleSubagents {
                    out.append(row(from: inputs[index]))
                    kept += 1
                }
                index += 1
            }
            guard total > kept else { continue }
            let hidden = total - kept
            out.append(PagerDashboardRow(
                id: .subagent(
                    parent: parent.id.owningSessionID,
                    child: "__more_\(parent.id.owningSessionID)"
                ),
                // Upstream's label is `"… {n} more"` (`row.rs:228`); the
                // B1 research note abbreviating it to `"… N"` is a
                // transcription slip — the code is authoritative.
                label: "\u{2026} \(hidden) more",
                state: .idle,
                lastChangeAt: parent.lastChangeAt,
                indent: 1,
                parentLabel: parent.label,
                pinned: false,
                isMorePlaceholder: true,
                moreCount: hidden
            ))
        }
        return out
    }

    private func row(from input: PagerDashboardRowInput) -> PagerDashboardRow {
        PagerDashboardRow(
            id: input.id,
            label: input.label,
            detail: input.detail,
            state: input.state,
            cwd: input.cwd,
            cwdDisplay: Self.compactCWD(input.cwd, home: home),
            lastChangeAt: input.lastChangeAt,
            indent: input.indent,
            parentLabel: input.parentLabel,
            pinned: pinned.contains(input.id)
        )
    }

    // MARK: Sorting

    /// Sort clusters (`sort_rows`, `row.rs:879-908`).
    ///
    /// Ladder, in order:
    ///   1. pinned first, regardless of group;
    ///   2. `.state` grouping: state priority desc → reorder index
    ///      (present before absent, ascending) → `lastChangeAt` desc →
    ///      id asc;
    ///      `.directory` grouping: `cwdDisplay` asc → reorder index →
    ///      state priority desc → `lastChangeAt` desc → id asc;
    ///   3. subagents move WITH their parent — the unit of sorting is
    ///      the cluster, never the row.
    static func sortRows(
        _ rows: [PagerDashboardRow],
        grouping: PagerDashboardGrouping,
        reorder: [PagerDashboardRowID]
    ) -> [PagerDashboardRow] {
        let clusters = buildClusters(rows)
        guard clusters.count > 1 else { return rows }
        let stateBeforeReorder = grouping == .state
        let keyed = clusters.map { range -> (Range<Int>, ClusterKey) in
            let parent = rows[range.lowerBound]
            return (range, ClusterKey(
                pinned: parent.pinned,
                priority: parent.state.groupPriority,
                lastChangeAt: parent.lastChangeAt,
                reorderIndex: reorder.firstIndex(of: parent.id),
                id: parent.id,
                cwdDisplay: parent.cwdDisplay
            ))
        }
        let sorted = keyed.sorted { lhs, rhs in
            if grouping == .directory, lhs.1.cwdDisplay != rhs.1.cwdDisplay {
                return lhs.1.cwdDisplay < rhs.1.cwdDisplay
            }
            return compare(lhs.1, rhs.1, stateBeforeReorder: stateBeforeReorder)
                == .orderedAscending
        }
        var out: [PagerDashboardRow] = []
        out.reserveCapacity(rows.count)
        for (range, _) in sorted { out.append(contentsOf: rows[range]) }
        return out
    }

    private struct ClusterKey {
        var pinned: Bool
        var priority: Int
        var lastChangeAt: Date
        var reorderIndex: Int?
        var id: PagerDashboardRowID
        var cwdDisplay: String
    }

    /// Compare two cluster keys (`sort_cluster_key`, `row.rs:989-1035`).
    ///
    /// `stateBeforeReorder` decides where an explicit reorder sits
    /// relative to state priority, and that choice is what keeps the
    /// rendered groups CONTIGUOUS. Under `.state` grouping, ranking the
    /// reorder above state let a reordered Idle row jump over the
    /// Working group, so the line builder emitted a second "Idle" header
    /// below the Working one (Idle → Working → Idle). Keeping state
    /// first confines a reorder to its own group. Under `.directory`
    /// grouping the cwd is the grouping primitive (compared before this
    /// function is even called), so within a cwd the reorder is free to
    /// cross states — there are no state sub-headers to split.
    ///
    /// Never returns `.orderedSame` for two distinct clusters: the id
    /// tiebreak is total, which is what makes the unstable `sorted(by:)`
    /// deterministic.
    private static func compare(
        _ lhs: ClusterKey,
        _ rhs: ClusterKey,
        stateBeforeReorder: Bool
    ) -> ComparisonResult {
        if lhs.pinned != rhs.pinned { return lhs.pinned ? .orderedAscending : .orderedDescending }
        func byReorder() -> ComparisonResult {
            switch (lhs.reorderIndex, rhs.reorderIndex) {
            case (.some(let a), .some(let b)):
                if a == b { return .orderedSame }
                return a < b ? .orderedAscending : .orderedDescending
            case (.some, .none): return .orderedAscending
            case (.none, .some): return .orderedDescending
            case (.none, .none): return .orderedSame
            }
        }
        func byState() -> ComparisonResult {
            if lhs.priority == rhs.priority { return .orderedSame }
            return lhs.priority > rhs.priority ? .orderedAscending : .orderedDescending
        }
        if stateBeforeReorder {
            let state = byState()
            if state != .orderedSame { return state }
            let reordered = byReorder()
            if reordered != .orderedSame { return reordered }
        } else {
            let reordered = byReorder()
            if reordered != .orderedSame { return reordered }
            let state = byState()
            if state != .orderedSame { return state }
        }
        if lhs.lastChangeAt != rhs.lastChangeAt {
            return lhs.lastChangeAt > rhs.lastChangeAt ? .orderedAscending : .orderedDescending
        }
        if lhs.id == rhs.id { return .orderedSame }
        return lhs.id < rhs.id ? .orderedAscending : .orderedDescending
    }

    /// `(start, end)` ranges of clustered rows — one top-level row plus
    /// the indented rows that follow it (`build_clusters`,
    /// `row.rs:1037-1050`).
    static func buildClusters(_ rows: [PagerDashboardRow]) -> [Range<Int>] {
        var clusters: [Range<Int>] = []
        var index = 0
        while index < rows.count {
            let start = index
            index += 1
            while index < rows.count, rows[index].indent > 0 { index += 1 }
            clusters.append(start..<index)
        }
        return clusters
    }

    // MARK: Lines

    /// Flatten sorted rows into painted lines
    /// (`build_dashboard_lines`, `render.rs:1307-1462`).
    ///
    /// State headers are suppressed when grouping is `.directory` (the
    /// cwd is the grouping primitive; state headers would land
    /// out-of-band) and when the filter is `.state(_)` (the view already
    /// holds exactly one state, so the header is redundant chrome).
    public func lines(
        from rows: [PagerDashboardRow],
        now: Date = Date()
    ) -> [PagerDashboardLine] {
        let groupsOn = grouping == .state
        var emitStateHeaders = groupsOn
        if case .state = filter { emitStateHeaders = false }

        // Pinned top-level clusters sort to the front, so they form a
        // contiguous prefix. Splitting it out is what makes a pinned
        // idle agent read as PINNED rather than landing under "Idle".
        var pinnedEnd = 0
        var pinnedCount = 0
        var scan = 0
        while scan < rows.count, rows[scan].indent == 0, rows[scan].pinned {
            pinnedCount += 1
            scan += 1
            while scan < rows.count, rows[scan].indent != 0 { scan += 1 }
            pinnedEnd = scan
        }

        var out: [PagerDashboardLine] = []
        out.reserveCapacity(rows.count + 6)
        if pinnedCount > 0 {
            if groupsOn { out.append(.pinnedHeader(count: pinnedCount)) }
            // A collapsed Pinned section keeps its header and hides its
            // rows. Collapse applies only with grouping on: the header
            // IS the toggle affordance, and the grouping-off divider
            // has none.
            let pinnedCollapsed = groupsOn && collapsedSections.contains(.pinned)
            if !pinnedCollapsed {
                out.append(contentsOf: rows[0..<pinnedEnd].map(PagerDashboardLine.row))
            }
            if !groupsOn, pinnedEnd < rows.count { out.append(.divider) }
        }

        let rest = Array(rows[pinnedEnd...])
        if !emitStateHeaders {
            out.append(contentsOf: rest.map(PagerDashboardLine.row))
            return out
        }

        var lastTopState: PagerDashboardRowState?
        var currentCollapsed = false
        // Idle-fold bookkeeping for the group being emitted. `idleLimit`
        // is set only inside a capped Idle group; `idleCapping` latches
        // once past it so over-cap rows AND their children are skipped;
        // `pendingOverflow` holds the fold line to emit at the group's
        // end (after its rows, before the next header).
        var idleLimit: Int?
        var idleTopSeen = 0
        var idleCapping = false
        var pendingOverflow: (hidden: Int, expanded: Bool)?
        // Folding is suppressed whenever the user is filtering OR
        // searching: when you are looking for something, every match
        // shows.
        let idleCapActive = !filter.isActive && !searchActive

        for (offset, row) in rest.enumerated() {
            if row.indent == 0, row.state != lastTopState {
                // Emit the fold line of the group being left BEFORE the
                // new header, so it lands at the bottom of its group.
                if let overflow = pendingOverflow {
                    out.append(.idleOverflow(hidden: overflow.hidden, expanded: overflow.expanded))
                    pendingOverflow = nil
                }
                // Count this group's true size by looking forward over
                // top-level rows only — children share their parent's
                // group and must not break the run. The count stays
                // true even when the group is collapsed or capped.
                var count = 0
                var recent = 0
                for candidate in rest[offset...] {
                    if candidate.indent != 0 { continue }
                    if candidate.state != row.state { break }
                    count += 1
                    if Self.idleRowIsRecent(candidate, now: now) { recent += 1 }
                }
                out.append(.header(state: row.state, count: count))
                lastTopState = row.state
                currentCollapsed = collapsedSections.contains(.state(row.state))
                idleLimit = nil
                idleTopSeen = 0
                idleCapping = false
                if row.state == .idle, idleCapActive, !currentCollapsed {
                    // Keep the freshest: at least `maxVisibleIdle`,
                    // extended to cover everything still inside the
                    // freshness window. Fold only when it hides at
                    // least `minIdleFold` rows.
                    let baseLimit = min(max(Self.maxVisibleIdle, recent), count)
                    let baseHidden = count - baseLimit
                    if baseHidden >= Self.minIdleFold {
                        idleLimit = idleShowAll ? count : baseLimit
                        pendingOverflow = (hidden: baseHidden, expanded: idleShowAll)
                    }
                }
            }
            if currentCollapsed { continue }
            if let limit = idleLimit {
                if row.indent == 0 {
                    idleTopSeen += 1
                    idleCapping = idleTopSeen > limit
                }
                if idleCapping { continue }
            }
            out.append(.row(row))
        }
        if let overflow = pendingOverflow {
            out.append(.idleOverflow(hidden: overflow.hidden, expanded: overflow.expanded))
        }
        return out
    }

    /// Whether an Idle row was touched within the freshness window.
    /// A FUTURE timestamp counts as recent — clock skew between pager
    /// processes and the on-disk catalog is real, and folding a row
    /// because its clock ran fast would be the wrong call
    /// (`idle_row_is_recent`, `render.rs:1480-1487`).
    static func idleRowIsRecent(_ row: PagerDashboardRow, now: Date) -> Bool {
        now.timeIntervalSince(row.lastChangeAt) < idleFreshness
    }

    /// Cursor targets in display order, derived from the same line list
    /// the renderer paints (`focusables`, `render.rs:1490-1516`).
    /// Collapsed sections contribute only their header, and `… N more`
    /// placeholders contribute nothing — they are not selectable.
    public func focusables(
        from rows: [PagerDashboardRow],
        now: Date = Date()
    ) -> [PagerDashboardFocusable] {
        lines(from: rows, now: now).compactMap { line in
            switch line {
            case .pinnedHeader: return .section(.pinned)
            case .header(let state, _): return .section(.state(state))
            case .row(let row): return row.isMorePlaceholder ? nil : .row(row.id)
            case .idleOverflow: return .idleOverflow
            case .divider: return nil
            }
        }
    }
}
