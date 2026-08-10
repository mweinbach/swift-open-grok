// PagerDashboardStateTests.swift
//
// Wave 18 B1-s: the dashboard value model against upstream 650c1db7 —
// the filter grammar (`state.rs:4831-4891` plus its own tests
// `:5163-5241`, `:5690-5721`), the row-state vocabulary
// (`state.rs:216-258`), cwd compaction (`state.rs:5108-5128`), pins /
// grouping / reorder / gc (`state.rs:1736-1805`,
// `dispatch/dashboard.rs:2329-2367`), the cluster sort ladder
// (`row.rs:879-1050`), and the line/focusable structure including both
// overflow rules (`render.rs:1307-1516`).
//
// Everything asserts through the live seam — `rows(from:)`,
// `lines(from:)`, `focusables(from:)` — rather than the private sort, so
// a refactor that moves the ladder cannot quietly pass.

import Foundation
import Testing
@testable import OpenGrokPagerRender

// MARK: - Fixtures

/// A fixed wall-clock anchor: every `lastChangeAt` is expressed as an
/// offset from here, so the freshness window is exercised without the
/// tests depending on when they run.
private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

private func moment(_ offset: TimeInterval) -> Date { anchor.addingTimeInterval(offset) }

private func session(
    _ id: String,
    state: PagerDashboardRowState = .idle,
    label: String? = nil,
    cwd: String = "/work",
    age: TimeInterval = 0
) -> PagerDashboardRowInput {
    PagerDashboardRowInput(
        id: .session(id),
        label: label ?? id,
        state: state,
        cwd: cwd,
        lastChangeAt: moment(-age)
    )
}

private func child(
    parent: String,
    _ id: String,
    state: PagerDashboardRowState = .working,
    label: String? = nil,
    parentLabel: String? = nil,
    age: TimeInterval = 0
) -> PagerDashboardRowInput {
    PagerDashboardRowInput(
        id: .subagent(parent: parent, child: id),
        label: label ?? id,
        state: state,
        cwd: "/work",
        lastChangeAt: moment(-age),
        indent: 1,
        parentLabel: parentLabel ?? parent
    )
}

private extension Array where Element == PagerDashboardRow {
    var ids: [PagerDashboardRowID] { map(\.id) }
}

private extension Array where Element == PagerDashboardLine {
    /// Header labels in display order — the shape a reader of the pane
    /// would see, which is what the section rules are really about.
    var headerLabels: [String] {
        compactMap { (line: PagerDashboardLine) -> String? in
            switch line {
            case .header(let state, _): return state.groupLabel
            case .pinnedHeader: return "Pinned"
            case .row, .divider, .idleOverflow: return nil
            }
        }
    }

    var rowIDs: [PagerDashboardRowID] {
        compactMap { (line: PagerDashboardLine) -> PagerDashboardRowID? in
            if case .row(let row) = line { return row.id }
            return nil
        }
    }

    var hasPinnedHeader: Bool {
        contains(where: { (line: PagerDashboardLine) -> Bool in
            if case .pinnedHeader = line { return true }
            return false
        })
    }

    /// The Idle fold line, if one was emitted.
    var idleOverflowLine: PagerDashboardLine? {
        first(where: { (line: PagerDashboardLine) -> Bool in
            if case .idleOverflow = line { return true }
            return false
        })
    }

    var idleOverflowIndex: Int? {
        firstIndex(where: { (line: PagerDashboardLine) -> Bool in
            if case .idleOverflow = line { return true }
            return false
        })
    }
}

// MARK: - 1. Filter grammar

@Suite("dashboard state — filter grammar")
struct PagerDashboardFilterParseTests {
    @Test("a: prefix parses an agent needle and an empty one clears")
    func agentPrefix() {
        // `filter_parser_agent_prefix` / `filter_parser_empty_agent_clears`
        // (`state.rs:5162-5175`).
        #expect(PagerDashboardFilter.parse("a:reviewer") == .agent("reviewer"))
        #expect(PagerDashboardFilter.parse("a:  reviewer  ") == .agent("reviewer"))
        #expect(PagerDashboardFilter.parse("a:") == PagerDashboardFilterValue.none)
        #expect(PagerDashboardFilter.parse("a:   ") == PagerDashboardFilterValue.none)
    }

    @Test("s: with a known token parses a state, with synonyms")
    func statePrefix() {
        // `filter_parser_state_known` (`state.rs:5177-5209`).
        #expect(PagerDashboardFilter.parse("s:needs-input") == .state(.needsInput))
        #expect(PagerDashboardFilter.parse("s:needs_input") == .state(.needsInput))
        #expect(PagerDashboardFilter.parse("s:needsinput") == .state(.needsInput))
        #expect(PagerDashboardFilter.parse("s:working") == .state(.working))
        #expect(PagerDashboardFilter.parse("s:idle") == .state(.idle))
        #expect(PagerDashboardFilter.parse("s:blocked") == .state(.blocked))
        #expect(PagerDashboardFilter.parse("s:completed") == .state(.completed))
        #expect(PagerDashboardFilter.parse("s:failed") == .state(.failed))
        #expect(PagerDashboardFilter.parse("s:dormant") == .state(.inactive))
    }

    /// The recorded doc-vs-code discrepancy. Upstream's comment
    /// (`state.rs:4822-4825`) claims `s:` empty is a substring match and
    /// that an unknown token falls back to a substring on the FULL
    /// `s:foobar`; the code (`:4844`, `:4846`) and upstream's own tests
    /// (`filter_parser_state_empty_is_none` `:5219-5226`,
    /// `filter_parser_state_unknown_falls_back_to_substring`
    /// `:5213-5218`) say otherwise. This pins the code's behaviour, so a
    /// future reader who ports the prose instead trips here.
    @Test("s: empty clears and an unknown token falls back to the REST, not the whole token")
    func stateFallbacksFollowTheCodeNotTheDocComment() {
        #expect(PagerDashboardFilter.parse("s:") == PagerDashboardFilterValue.none)
        #expect(PagerDashboardFilter.parse("s:   ") == PagerDashboardFilterValue.none)
        #expect(PagerDashboardFilter.parse("s:foobar") == .substring("foobar"))
        #expect(PagerDashboardFilter.parse("s:foobar") != .substring("s:foobar"))
    }

    @Test("#<n> keeps the hash in the needle, and anything else is free text")
    func hashAndFreeText() {
        // `filter_parser_pr_prefix_keeps_hash` (`:5228-5236`): keeping
        // the `#` stops the needle matching arbitrary digits in a label.
        #expect(PagerDashboardFilter.parse("#42") == .substring("#42"))
        #expect(PagerDashboardFilter.parse("auth flow") == .substring("auth flow"))
        #expect(PagerDashboardFilter.parse("  auth flow  ") == .substring("auth flow"))
        #expect(PagerDashboardFilter.parse("") == .substring(""))
    }

    @Test("from(_:) collapses whitespace-only needles to no filter")
    func fromValueCollapsesBlankNeedles() {
        // `Filter::from_value` (`state.rs:327-348`).
        #expect(PagerDashboardFilter.from(.agent("   ")) == PagerDashboardFilter.none)
        #expect(PagerDashboardFilter.from(.substring("  ")) == PagerDashboardFilter.none)
        #expect(PagerDashboardFilter.from(.agent(" rev ")) == .agent(" rev "))
        #expect(PagerDashboardFilter.from(.state(.idle)) == .state(.idle))
        #expect(
            PagerDashboardFilter.from(PagerDashboardFilterValue.none) == PagerDashboardFilter.none
        )
    }

    @Test("isActive drives Esc-clears-the-filter-first")
    func isActive() {
        #expect(PagerDashboardFilter.none.isActive == false)
        #expect(PagerDashboardFilter.agent("x").isActive)
        #expect(PagerDashboardFilter.state(.idle).isActive)
        #expect(PagerDashboardFilter.substring("x").isActive)
    }
}

// MARK: - 2. parseToken synonym table

@Suite("dashboard state — row state token synonyms")
struct PagerDashboardRowStateTokenTests {
    @Test("every upstream synonym maps, including punctuation and case variants")
    func allSynonyms() {
        // `parse_row_state_token_all_synonyms` (`state.rs:5690-5721`).
        let table: [(String, PagerDashboardRowState)] = [
            ("needsinput", .needsInput), ("needs", .needsInput), ("input", .needsInput),
            ("working", .working), ("busy", .working), ("running", .working),
            ("idle", .idle),
            ("inactive", .inactive), ("dormant", .inactive),
            ("completed", .completed), ("done", .completed),
            ("failed", .failed), ("errored", .failed),
            ("cancelled", .failed), ("canceled", .failed),
            ("blocked", .blocked), ("paused", .blocked),
            // Normalisation drops `-`, `_` and space, and lowercases.
            ("needs-input", .needsInput), ("NEEDS_INPUT", .needsInput),
            ("Needs Input", .needsInput), ("  W O R K I N G", .working),
        ]
        for (token, expected) in table {
            #expect(
                PagerDashboardRowState.parseToken(token) == expected,
                "token \(token) should parse as \(expected)"
            )
        }
    }

    @Test("empties and nonsense parse to nothing")
    func rejections() {
        for token in ["", " ", "-", "_", "   -_ ", "nonsense", "idles", "wor king x"] {
            #expect(
                PagerDashboardRowState.parseToken(token) == nil,
                "token \(token) should not parse"
            )
        }
    }
}

// MARK: - 3/4/5. Priority, delete predicate, labels

@Suite("dashboard state — row state vocabulary")
struct PagerDashboardRowStateVocabularyTests {
    @Test("group priority is the exact upstream ladder")
    func groupPriority() {
        // `RowState::group_priority` (`state.rs:227-242`).
        #expect(PagerDashboardRowState.needsInput.groupPriority == 6)
        #expect(PagerDashboardRowState.working.groupPriority == 5)
        #expect(PagerDashboardRowState.blocked.groupPriority == 4)
        #expect(PagerDashboardRowState.idle.groupPriority == 3)
        #expect(PagerDashboardRowState.inactive.groupPriority == 2)
        #expect(PagerDashboardRowState.completed.groupPriority == 1)
        #expect(PagerDashboardRowState.failed.groupPriority == 0)
        // Inactive sits BELOW Idle (not loaded here, less actionable)
        // but ABOVE Done/Failed (still live, resumable sessions).
        #expect(
            PagerDashboardRowState.idle.groupPriority
                > PagerDashboardRowState.inactive.groupPriority
        )
        #expect(
            PagerDashboardRowState.inactive.groupPriority
                > PagerDashboardRowState.completed.groupPriority
        )
    }

    @Test("only settled rows allow delete — an in-flight turn is never wiped")
    func allowsDelete() {
        // `RowState::allows_delete` (`state.rs:216-225`).
        #expect(PagerDashboardRowState.idle.allowsDelete)
        #expect(PagerDashboardRowState.inactive.allowsDelete)
        #expect(PagerDashboardRowState.completed.allowsDelete)
        #expect(PagerDashboardRowState.failed.allowsDelete)
        #expect(PagerDashboardRowState.working.allowsDelete == false)
        #expect(PagerDashboardRowState.needsInput.allowsDelete == false)
        #expect(PagerDashboardRowState.blocked.allowsDelete == false)
    }

    @Test("group labels are the short upstream spellings")
    func groupLabel() {
        // `RowState::group_label` (`state.rs:244-258`).
        #expect(PagerDashboardRowState.needsInput.groupLabel == "Awaiting")
        #expect(PagerDashboardRowState.working.groupLabel == "Working")
        #expect(PagerDashboardRowState.idle.groupLabel == "Idle")
        #expect(PagerDashboardRowState.inactive.groupLabel == "Inactive")
        #expect(PagerDashboardRowState.completed.groupLabel == "Done")
        #expect(PagerDashboardRowState.failed.groupLabel == "Failed")
        #expect(PagerDashboardRowState.blocked.groupLabel == "Blocked")
    }
}

// MARK: - 6. compactCWD

@Suite("dashboard state — cwd compaction")
struct PagerDashboardCompactCWDTests {
    @Test("home is replaced by ~, and home itself collapses to a bare ~")
    func compaction() {
        // `compact_cwd` (`state.rs:5108-5128`): the empty-rest branch
        // exists precisely so `cwd == home` is `~` and not `~/`.
        #expect(
            PagerDashboardState.compactCWD("/Users/mw/code/app", home: "/Users/mw")
                == "~/code/app"
        )
        #expect(PagerDashboardState.compactCWD("/Users/mw", home: "/Users/mw") == "~")
        #expect(PagerDashboardState.compactCWD("/Users/mw/", home: "/Users/mw") == "~")
    }

    /// The Swift-specific trap: `strip_prefix` upstream is COMPONENT
    /// -wise, so `/Users/mweinbach` is not inside a home of
    /// `/Users/mw`. A `hasPrefix` port would render it `~einbach`.
    @Test("a sibling directory sharing a textual prefix is not compacted")
    func componentWiseNotTextual() {
        #expect(
            PagerDashboardState.compactCWD("/Users/mweinbach/app", home: "/Users/mw")
                == "/Users/mweinbach/app"
        )
    }

    @Test("no home, an empty home, or a non-home path passes through unchanged")
    func passthrough() {
        #expect(PagerDashboardState.compactCWD("/tmp/x", home: nil) == "/tmp/x")
        #expect(PagerDashboardState.compactCWD("/tmp/x", home: "") == "/tmp/x")
        #expect(PagerDashboardState.compactCWD("/tmp/x", home: "/Users/mw") == "/tmp/x")
        // Mixed absoluteness never matches, as `Path::strip_prefix` also
        // refuses to.
        #expect(PagerDashboardState.compactCWD("Users/mw/x", home: "/Users/mw") == "Users/mw/x")
    }

    @Test("built rows carry the compacted cwd so display and filtering agree")
    func rowsUseCompactedCWD() {
        var state = PagerDashboardState(home: "/Users/mw")
        state.filter = .substring("~/code")
        let rows = state.rows(from: [
            session("a", cwd: "/Users/mw/code/app"),
            session("b", cwd: "/tmp/other"),
        ])
        #expect(rows.ids == [.session("a")])
        #expect(rows[0].cwdDisplay == "~/code/app")
    }
}

// MARK: - 7/8. Pins and grouping

@Suite("dashboard state — pins and grouping")
struct PagerDashboardPinGroupingTests {
    @Test("Ctrl+T toggles the pin both ways and reports the new state")
    func togglePin() {
        // `toggle_pin_selected` (`state.rs:1798-1805`).
        var state = PagerDashboardState()
        let pinnedOn = state.togglePin(.session("a"))
        #expect(pinnedOn)
        #expect(state.pinned == [.session("a")])
        let pinnedOff = state.togglePin(.session("a"))
        #expect(pinnedOff == false)
        #expect(state.pinned.isEmpty)
    }

    @Test("togglePinSelected is a no-op without a selection")
    func togglePinSelected() {
        var state = PagerDashboardState()
        let withoutSelection = state.togglePinSelected()
        #expect(withoutSelection == nil)
        #expect(state.pinned.isEmpty)
        state.selected = .dormant("s1")
        let toggled = state.togglePinSelected()
        #expect(toggled == .dormant("s1"))
        #expect(state.pinned == [.dormant("s1")])
    }

    @Test("grouping is a two-way flip")
    func groupingToggled() {
        #expect(PagerDashboardGrouping.state.toggled() == .directory)
        #expect(PagerDashboardGrouping.directory.toggled() == .state)
        #expect(PagerDashboardGrouping.state.toggled().toggled() == .state)
    }

    /// Sections exist only under `.state` grouping, so a header cursor
    /// must not survive the flip away from it — otherwise the cursor
    /// points at a header the renderer no longer paints
    /// (`toggle_grouping`, `state.rs:1782-1796`).
    @Test("leaving state grouping drops a header cursor, returning to it keeps the row cursor")
    func toggleGroupingClearsSectionCursor() {
        var state = PagerDashboardState()
        state.selectedSection = .state(.working)
        state.selected = nil
        state.toggleGrouping()
        #expect(state.grouping == .directory)
        #expect(state.selectedSection == nil)

        state.selected = .session("a")
        state.toggleGrouping()
        #expect(state.grouping == .state)
        #expect(state.selected == .session("a"))
    }

    @Test("section collapse toggles both ways")
    func collapseToggles() {
        var state = PagerDashboardState()
        #expect(state.isCollapsed(.state(.idle)) == false)
        state.toggleSection(.state(.idle))
        #expect(state.isCollapsed(.state(.idle)))
        state.toggleSection(.state(.idle))
        #expect(state.isCollapsed(.state(.idle)) == false)
    }
}

// MARK: - 9. gc

@Suite("dashboard state — stale reference gc")
struct PagerDashboardGCTests {
    /// The reorder list is an ORDERING; a gc that rebuilt it from a set
    /// would keep the right members and lose the whole point
    /// (`gc_stale_refs`, `state.rs:1736-1780`).
    @Test("gc drops dead ids and preserves the surviving reorder order")
    func gcPreservesOrder() {
        var state = PagerDashboardState(
            pinned: [.session("a"), .session("b")],
            reorder: [.session("e"), .session("d"), .session("c"), .session("b"), .session("a")],
            selected: .session("d")
        )
        let dead: Set<PagerDashboardRowID> = [.session("b"), .session("d")]
        state.gcStaleRefs { !dead.contains($0) }
        #expect(state.pinned == [.session("a")])
        #expect(state.reorder == [.session("e"), .session("c"), .session("a")])
        // A selection pointing at a row that no longer exists is
        // cleared, so Enter can never dispatch against a phantom.
        #expect(state.selected == nil)
    }

    @Test("gc leaves a live selection alone")
    func gcKeepsLiveSelection() {
        var state = PagerDashboardState(selected: .session("a"))
        state.gcStaleRefs { _ in true }
        #expect(state.selected == .session("a"))
    }
}

// MARK: - 10/11. Sorting

@Suite("dashboard state — sort ladder")
struct PagerDashboardSortTests {
    @Test("state priority orders the groups, most-recent first inside one")
    func statePriorityThenRecency() {
        let state = PagerDashboardState()
        let rows = state.rows(from: [
            session("idle-old", state: .idle, age: 100),
            session("await", state: .needsInput, age: 500),
            session("idle-new", state: .idle, age: 10),
            session("work", state: .working, age: 900),
            session("dormant", state: .inactive, age: 1),
        ])
        #expect(rows.ids == [
            .session("await"), .session("work"),
            .session("idle-new"), .session("idle-old"),
            .session("dormant"),
        ])
    }

    @Test("pinned rows float above every group regardless of state")
    func pinnedFloats() {
        var state = PagerDashboardState()
        state.pinned = [.session("idle-pinned")]
        let rows = state.rows(from: [
            session("await", state: .needsInput, age: 5),
            session("idle-pinned", state: .idle, age: 900),
        ])
        #expect(rows.ids == [.session("idle-pinned"), .session("await")])
        #expect(rows[0].pinned)
    }

    /// The Idle → Working → Idle regression (`row.rs:1013-1022`):
    /// ranking the reorder above the state key let a reordered Idle row
    /// jump the Working group, which made the line builder emit a second
    /// "Idle" header underneath it.
    @Test("a reorder floats a row inside its own state group, never across groups")
    func reorderIsConfinedToItsGroup() {
        var state = PagerDashboardState()
        state.reorder = [.session("i2")]
        let rows = state.rows(from: [
            session("w1", state: .working, age: 10),
            session("i1", state: .idle, age: 5),
            session("i2", state: .idle, age: 900),
        ])
        #expect(rows.ids == [.session("w1"), .session("i2"), .session("i1")])
        // And the headers stay contiguous: one Working, one Idle.
        #expect(state.lines(from: rows, now: anchor).headerLabels == ["Working", "Idle"])
    }

    /// `Array.sort` in Swift is NOT stable, so without the id tiebreak an
    /// all-else-equal group would reshuffle between rebuilds.
    @Test("rows tying on every other key fall back to id order, deterministically")
    func idTiebreak() {
        let state = PagerDashboardState()
        let inputs = ["e", "d", "c", "b", "a"].map { session($0, state: .idle, age: 0) }
        let first = state.rows(from: inputs)
        #expect(first.ids == [
            .session("a"), .session("b"), .session("c"), .session("d"), .session("e"),
        ])
        // Rebuilding from a different input order lands identically.
        #expect(state.rows(from: Array(inputs.reversed())).ids == first.ids)
    }

    @Test("directory grouping sorts by cwd first, above state priority")
    func directoryGrouping() {
        var state = PagerDashboardState(home: "/Users/mw")
        state.grouping = .directory
        let rows = state.rows(from: [
            session("b-working", state: .working, cwd: "/Users/mw/b", age: 5),
            session("a-idle", state: .idle, cwd: "/Users/mw/a", age: 900),
            session("a-await", state: .needsInput, cwd: "/Users/mw/a", age: 900),
        ])
        // `~/a` before `~/b` even though the `~/b` row is Working.
        #expect(rows.ids == [
            .session("a-await"), .session("a-idle"), .session("b-working"),
        ])
    }

    @Test("in directory grouping a reorder may cross states inside one cwd")
    func directoryReorderCrossesStates() {
        // `sort_cluster_key(state_before_reorder: false)` (`row.rs:1023-1030`):
        // within a cwd there are no state sub-headers to split, so the
        // reorder outranks state priority.
        var state = PagerDashboardState()
        state.grouping = .directory
        state.reorder = [.session("idle")]
        let rows = state.rows(from: [
            session("await", state: .needsInput, cwd: "/w", age: 5),
            session("idle", state: .idle, cwd: "/w", age: 900),
        ])
        #expect(rows.ids == [.session("idle"), .session("await")])
    }

    /// Port pin: subagent rows are a recorded addition over upstream's
    /// live dashboard, and they are only coherent if they never detach
    /// from their parent (`build_clusters`, `row.rs:1037-1050`).
    @Test("subagents move with their parent — the sort unit is the cluster")
    func clustersStayGlued() {
        let state = PagerDashboardState()
        let rows = state.rows(from: [
            session("idle-parent", state: .idle, age: 900),
            child(parent: "idle-parent", "c1", state: .working, age: 1),
            child(parent: "idle-parent", "c2", state: .working, age: 2),
            session("await", state: .needsInput, age: 900),
        ])
        #expect(rows.ids == [
            .session("await"),
            .session("idle-parent"),
            .subagent(parent: "idle-parent", child: "c1"),
            .subagent(parent: "idle-parent", child: "c2"),
        ])
        // A Working child never drags its Idle parent up a group.
        #expect(state.lines(from: rows, now: anchor).headerLabels == ["Awaiting", "Idle"])
    }
}

// MARK: - 11. Reorder mechanics

@Suite("dashboard state — reorder mechanics")
struct PagerDashboardReorderTests {
    /// `dispatch_dashboard_reorder` (`dispatch/dashboard.rs:2329-2367`)
    /// is list surgery, not index arithmetic — walked here across all
    /// five arms with five rows.
    @Test("the five reorder arms: insert, append, swap up, remove at head, tail no-op")
    func reorderArms() {
        var state = PagerDashboardState()
        let r = (1...5).map { PagerDashboardRowID.session("r\($0)") }

        // Not in the list, moving up → inserted at the front.
        state.reorderRow(r[2], up: true)
        #expect(state.reorder == [r[2]])

        // Not in the list, moving down → appended.
        state.reorderRow(r[0], up: false)
        #expect(state.reorder == [r[2], r[0]])

        // In the list, moving up → swap with the entry above.
        state.reorderRow(r[0], up: true)
        #expect(state.reorder == [r[0], r[2]])

        // At the head, moving up → REMOVED, so the row returns to its
        // natural order instead of pinning itself to the top forever.
        state.reorderRow(r[0], up: true)
        #expect(state.reorder == [r[2]])

        // At the tail, moving down → no-op.
        state.reorderRow(r[2], up: false)
        #expect(state.reorder == [r[2]])

        // Fifth row appended, then swapped down past nothing / up past one.
        state.reorderRow(r[4], up: false)
        #expect(state.reorder == [r[2], r[4]])
        state.reorderRow(r[2], up: false)
        #expect(state.reorder == [r[4], r[2]])
    }

    @Test("reorderSelected needs a selection and reports the moved row")
    func reorderSelected() {
        var state = PagerDashboardState()
        let withoutSelection = state.reorderSelected(up: true)
        #expect(withoutSelection == nil)
        #expect(state.reorder.isEmpty)
        state.selected = .session("a")
        let moved = state.reorderSelected(up: true)
        #expect(moved == .session("a"))
        #expect(state.reorder == [.session("a")])
    }
}

// MARK: - 12. Subagent overflow

@Suite("dashboard state — subagent overflow")
struct PagerDashboardSubagentOverflowTests {
    private func parentWithChildren(_ count: Int) -> [PagerDashboardRowInput] {
        var inputs = [session("p", state: .working, label: "parent", age: 0)]
        for index in 0..<count {
            inputs.append(child(
                parent: "p", "c\(index)", state: .working,
                parentLabel: "parent", age: TimeInterval(index)
            ))
        }
        return inputs
    }

    @Test("eight children fit; the ninth folds the tail into one placeholder")
    func foldsPastEight() {
        // `MAX_VISIBLE_SUBAGENTS` (`row.rs:98`, `:212-250`).
        let state = PagerDashboardState()
        #expect(state.rows(from: parentWithChildren(8)).count == 9)

        let rows = state.rows(from: parentWithChildren(11))
        #expect(rows.count == 10) // parent + 8 kept + 1 placeholder
        let placeholder = rows[9]
        #expect(placeholder.isMorePlaceholder)
        #expect(placeholder.moreCount == 3)
        #expect(placeholder.label == "\u{2026} 3 more")
        #expect(placeholder.state == .idle)
        #expect(placeholder.indent == 1)
        #expect(placeholder.parentLabel == "parent")
        #expect(placeholder.pinned == false)
        #expect(placeholder.id == .subagent(parent: "p", child: "__more_p"))
    }

    /// The placeholder is a structural marker, not a row: filtering it
    /// out would silently under-report the hidden count
    /// (`apply_filter`, `row.rs:855-857`).
    @Test("the placeholder is immune to every filter arm")
    func placeholderIsFilterImmune() {
        var state = PagerDashboardState()
        let filters: [PagerDashboardFilter] = [
            .substring("nothing-matches-this"),
            .agent("nothing-matches-this"),
            .state(.needsInput),
        ]
        for filter in filters {
            state.filter = filter
            let rows = state.rows(from: parentWithChildren(11))
            #expect(rows.count == 1, "only the placeholder should survive \(filter)")
            #expect(rows[0].isMorePlaceholder)
        }
    }

    @Test("the placeholder is not a cursor target")
    func placeholderIsNotFocusable() {
        let state = PagerDashboardState()
        let rows = state.rows(from: parentWithChildren(11))
        let focusables = state.focusables(from: rows, now: anchor)
        #expect(focusables.contains(.row(.subagent(parent: "p", child: "__more_p"))) == false)
        #expect(focusables.contains(.row(.subagent(parent: "p", child: "c0"))))
    }

    @Test("each parent folds independently")
    func perParentFolding() {
        let state = PagerDashboardState()
        var inputs = parentWithChildren(10)
        inputs.append(session("q", state: .working, label: "other", age: 1))
        inputs.append(child(parent: "q", "qc", state: .working, parentLabel: "other"))
        let rows = state.rows(from: inputs)
        let placeholders = rows.filter(\.isMorePlaceholder)
        #expect(placeholders.count == 1)
        #expect(placeholders[0].moreCount == 2)
    }
}

// MARK: - 13. Idle overflow

@Suite("dashboard state — idle overflow fold")
struct PagerDashboardIdleOverflowTests {
    /// `age` in seconds; anything past an hour is outside the freshness
    /// window (`IDLE_FRESHNESS`, `render.rs:1471`).
    private func idleRows(_ count: Int, age: TimeInterval) -> [PagerDashboardRowInput] {
        (0..<count).map { index in
            session(String(format: "i%02d", index), state: .idle, age: age + TimeInterval(index))
        }
    }

    @Test("eleven stale idle rows fold to eight plus a three-row toggle")
    func foldsStaleTail() {
        // base_limit = max(8, recent=0).min(11) = 8; hidden = 3 ≥ 2.
        let state = PagerDashboardState()
        let rows = state.rows(from: idleRows(11, age: 7_200))
        let lines = state.lines(from: rows, now: anchor)
        #expect(lines.rowIDs.count == 8)
        #expect(lines.idleOverflowLine == PagerDashboardLine.idleOverflow(
            hidden: 3, expanded: false
        ))
        // The header still reports the TRUE group size.
        #expect(lines.first == PagerDashboardLine.header(state: .idle, count: 11))
    }

    @Test("hiding a single row is not worth a fold line")
    func minimumFold() {
        // hidden = 1 < MIN_IDLE_FOLD (`render.rs:1475`): the toggle row
        // would cost exactly the space the row it hides takes.
        let state = PagerDashboardState()
        let lines = state.lines(from: state.rows(from: idleRows(9, age: 7_200)), now: anchor)
        #expect(lines.rowIDs.count == 9)
        #expect(lines.idleOverflowLine == nil)
    }

    @Test("a burst of fresh idle rows is never folded, even past the cap")
    func freshnessWindowExtendsTheCap() {
        // recent = 11 → base_limit = max(8, 11).min(11) = 11, hidden = 0.
        let state = PagerDashboardState()
        let lines = state.lines(from: state.rows(from: idleRows(11, age: 60)), now: anchor)
        #expect(lines.rowIDs.count == 11)
        #expect(lines.idleOverflowLine == nil)
    }

    @Test("idleShowAll expands the group but keeps the toggle, flagged expanded")
    func showAllExpands() {
        var state = PagerDashboardState()
        state.idleShowAll = true
        let lines = state.lines(from: state.rows(from: idleRows(11, age: 7_200)), now: anchor)
        #expect(lines.rowIDs.count == 11)
        #expect(lines.idleOverflowLine == PagerDashboardLine.idleOverflow(
            hidden: 3, expanded: true
        ))
    }

    /// Two suppressions, not one: entering search clears the filter to
    /// `.none` (the query rebuilds it per keystroke), so the filter check
    /// alone would leave old rows folded while the user is searching
    /// (`render.rs:1383-1387`).
    @Test("folding is suppressed while filtering and while searching")
    func suppressedUnderFilterOrSearch() {
        var state = PagerDashboardState()
        state.filter = .substring("i")
        var lines = state.lines(from: state.rows(from: idleRows(11, age: 7_200)), now: anchor)
        #expect(lines.rowIDs.count == 11)
        #expect(lines.idleOverflowLine == nil)

        state.filter = .none
        state.searchActive = true
        lines = state.lines(from: state.rows(from: idleRows(11, age: 7_200)), now: anchor)
        #expect(lines.rowIDs.count == 11)
        #expect(lines.idleOverflowLine == nil)
    }

    @Test("the fold line lands at the group's end, before the next header")
    func foldLineSitsAtGroupEnd() {
        let state = PagerDashboardState()
        var inputs = idleRows(11, age: 7_200)
        inputs.append(session("dormant", state: .inactive, age: 10))
        let lines = state.lines(from: state.rows(from: inputs), now: anchor)
        let inactiveHeader = PagerDashboardLine.header(state: .inactive, count: 1)
        guard let overflowIndex = lines.idleOverflowIndex,
              let inactiveIndex = lines.firstIndex(of: inactiveHeader) else {
            Issue.record("expected both an overflow line and an Inactive header")
            return
        }
        #expect(overflowIndex == inactiveIndex - 1)
    }

    @Test("a collapsed Idle group folds nothing — its rows are already hidden")
    func collapsedGroupSkipsTheFold() {
        var state = PagerDashboardState()
        state.collapsedSections = [.state(.idle)]
        let lines = state.lines(from: state.rows(from: idleRows(11, age: 7_200)), now: anchor)
        #expect(lines.rowIDs.isEmpty)
        #expect(lines.idleOverflowLine == nil)
        #expect(lines.headerLabels == ["Idle"])
    }

    @Test("the fold line is a cursor target at the group's end")
    func foldLineIsFocusable() {
        let state = PagerDashboardState()
        let rows = state.rows(from: idleRows(11, age: 7_200))
        #expect(state.focusables(from: rows, now: anchor).last
            == PagerDashboardFocusable.idleOverflow)
    }
}

// MARK: - 14. Lines, sections and focusables

@Suite("dashboard state — lines, sections and focusables")
struct PagerDashboardLineTests {
    private let mixed: [PagerDashboardRowInput] = [
        session("await", state: .needsInput, age: 5),
        session("work", state: .working, age: 5),
        session("idle", state: .idle, age: 5),
        session("dormant", state: .inactive, age: 5),
    ]

    @Test("state grouping emits one header per state transition, with true counts")
    func stateHeaders() {
        let state = PagerDashboardState()
        let lines = state.lines(from: state.rows(from: mixed), now: anchor)
        #expect(lines.headerLabels == ["Awaiting", "Working", "Idle", "Inactive"])
        #expect(lines.contains(PagerDashboardLine.header(state: .working, count: 1)))
    }

    /// Port pin (lead ruling): no classifier emits Done / Failed /
    /// Blocked, so those sections never reach the screen. This guards
    /// the state side of it — an ungrounded header can only appear if a
    /// row carrying that state does.
    @Test("only grounded sections render for the states the port can produce")
    func noUngroundedSections() {
        let state = PagerDashboardState()
        let labels = state.lines(from: state.rows(from: mixed), now: anchor).headerLabels
        #expect(labels.contains("Done") == false)
        #expect(labels.contains("Failed") == false)
        #expect(labels.contains("Blocked") == false)
    }

    @Test("directory grouping suppresses state headers entirely")
    func directorySuppressesHeaders() {
        var state = PagerDashboardState()
        state.grouping = .directory
        let lines = state.lines(from: state.rows(from: mixed), now: anchor)
        #expect(lines.headerLabels.isEmpty)
        #expect(lines.rowIDs.count == 4)
    }

    /// A state-filtered view holds exactly one state, so its header is
    /// redundant chrome (`render.rs:1308-1312`).
    @Test("a state filter suppresses state headers but keeps the pinned header")
    func stateFilterSuppressesHeaders() {
        var state = PagerDashboardState()
        state.pinned = [.session("await")]
        state.filter = .state(.needsInput)
        let lines = state.lines(from: state.rows(from: mixed), now: anchor)
        #expect(lines.headerLabels == ["Pinned"])
        #expect(lines.rowIDs == [.session("await")])
    }

    @Test("pinned rows get a labelled header with grouping on, a divider with it off")
    func pinnedPrefix() {
        var state = PagerDashboardState()
        state.pinned = [.session("idle")]
        var lines = state.lines(from: state.rows(from: mixed), now: anchor)
        #expect(lines.first == PagerDashboardLine.pinnedHeader(count: 1))
        #expect(lines.contains(PagerDashboardLine.divider) == false)

        state.grouping = .directory
        lines = state.lines(from: state.rows(from: mixed), now: anchor)
        #expect(lines.hasPinnedHeader == false)
        #expect(lines[1] == PagerDashboardLine.divider)
    }

    @Test("with nothing but pinned rows there is no divider to draw")
    func noDividerWithoutARest() {
        var state = PagerDashboardState()
        state.grouping = .directory
        state.pinned = [.session("only")]
        let lines = state.lines(from: state.rows(from: [session("only")]), now: anchor)
        #expect(lines.contains(PagerDashboardLine.divider) == false)
        #expect(lines.rowIDs == [.session("only")])
    }

    @Test("a collapsed section keeps its header and hides its rows")
    func collapsedSectionKeepsHeader() {
        var state = PagerDashboardState()
        state.collapsedSections = [.state(.working)]
        let lines = state.lines(from: state.rows(from: mixed), now: anchor)
        #expect(lines.headerLabels == ["Awaiting", "Working", "Idle", "Inactive"])
        #expect(lines.rowIDs == [.session("await"), .session("idle"), .session("dormant")])
        // The header stays selectable so it can be re-opened.
        #expect(state.focusables(from: state.rows(from: mixed), now: anchor)
            .contains(.section(.state(.working))))
    }

    @Test("a collapsed Pinned section keeps its header, and collapse needs grouping on")
    func collapsedPinnedSection() {
        var state = PagerDashboardState()
        state.pinned = [.session("idle")]
        state.collapsedSections = [.pinned]
        var lines = state.lines(from: state.rows(from: mixed), now: anchor)
        #expect(lines.first == PagerDashboardLine.pinnedHeader(count: 1))
        #expect(lines.rowIDs.contains(.session("idle")) == false)

        // Grouping off: the divider carries no toggle affordance, so
        // collapse cannot apply and the pinned rows stay visible.
        state.grouping = .directory
        lines = state.lines(from: state.rows(from: mixed), now: anchor)
        #expect(lines.rowIDs.contains(.session("idle")))
    }

    @Test("focusables follow the painted lines exactly, headers included")
    func focusablesMirrorLines() {
        let state = PagerDashboardState()
        let rows = state.rows(from: mixed)
        #expect(state.focusables(from: rows, now: anchor) == [
            .section(.state(.needsInput)), .row(.session("await")),
            .section(.state(.working)), .row(.session("work")),
            .section(.state(.idle)), .row(.session("idle")),
            .section(.state(.inactive)), .row(.session("dormant")),
        ])
    }

    @Test("a subagent whose state differs from its parent does not open a section")
    func childrenNeverEmitHeaders() {
        let state = PagerDashboardState()
        let rows = state.rows(from: [
            session("p", state: .idle, age: 5),
            child(parent: "p", "c", state: .needsInput),
        ])
        #expect(state.lines(from: rows, now: anchor).headerLabels == ["Idle"])
    }
}

// MARK: - 15. Filtering arms

@Suite("dashboard state — filter application")
struct PagerDashboardApplyFilterTests {
    private let rows: [PagerDashboardRow] = [
        PagerDashboardRow(
            id: .session("p"), label: "Reviewer", state: .working,
            cwdDisplay: "~/code/app", lastChangeAt: anchor
        ),
        PagerDashboardRow(
            id: .subagent(parent: "p", child: "c"), label: "fix login", state: .working,
            cwdDisplay: "~/code/app", lastChangeAt: anchor,
            indent: 1, parentLabel: "Reviewer"
        ),
        PagerDashboardRow(
            id: .dormant("d"), label: "old thing", state: .inactive,
            cwdDisplay: "~/other", lastChangeAt: anchor
        ),
    ]

    @Test("agent matches the label OR the parent label, case-insensitively")
    func agentArm() {
        // Matching the parent label is what keeps a filtered agent's
        // children with it (`row.rs:861-868`).
        #expect(PagerDashboardFilter.agent("review").apply(to: rows).ids == [
            .session("p"), .subagent(parent: "p", child: "c"),
        ])
        #expect(PagerDashboardFilter.agent("REVIEW").apply(to: rows).count == 2)
        #expect(PagerDashboardFilter.agent("login").apply(to: rows).ids == [
            .subagent(parent: "p", child: "c"),
        ])
        #expect(PagerDashboardFilter.agent("zzz").apply(to: rows).isEmpty)
    }

    @Test("state matches exactly — never by priority or by group")
    func stateArm() {
        #expect(PagerDashboardFilter.state(.inactive).apply(to: rows).ids == [.dormant("d")])
        #expect(PagerDashboardFilter.state(.working).apply(to: rows).count == 2)
        #expect(PagerDashboardFilter.state(.idle).apply(to: rows).isEmpty)
    }

    @Test("substring matches the label OR the compacted cwd")
    func substringArm() {
        #expect(PagerDashboardFilter.substring("code").apply(to: rows).count == 2)
        #expect(PagerDashboardFilter.substring("OTHER").apply(to: rows).ids == [.dormant("d")])
        // The parent label is NOT a substring target — only agent is.
        #expect(PagerDashboardFilter.substring("Reviewer").apply(to: rows).ids == [.session("p")])
    }

    @Test("no filter and an empty substring needle both keep everything")
    func passthroughArms() {
        #expect(PagerDashboardFilter.none.apply(to: rows).count == 3)
        // `from(_:)` would have collapsed this to `.none`; constructed
        // directly it must still keep every row (`row.rs:872-874`).
        #expect(PagerDashboardFilter.substring("").apply(to: rows).count == 3)
    }
}
