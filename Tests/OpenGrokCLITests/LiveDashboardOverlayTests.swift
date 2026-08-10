// LiveDashboardOverlayTests.swift
//
// Wave 18 B1-d / B1-w2: the roster overlay riding the state machinery —
// section headers with counts and collapse chevrons, state classification
// (active working/needs-input, background idle BY CONSTRUCTION, dormant
// inactive), dormant catalog rows joining as attachable rows, directory
// grouping, filters, pins, the idle fold, the armed close row, and the
// chord-side id mapping helpers.

import Foundation
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

private func tab(_ id: String, title: String, activity: TimeInterval, cwd: String = "") -> LiveSessionTab {
    LiveSessionTab(
        sessionID: id,
        title: title,
        lastActivity: Date(timeIntervalSince1970: activity),
        cwd: cwd
    )
}

private func dormant(
    _ id: String,
    cwd: String,
    title: String? = nil,
    activity: TimeInterval = 10
) -> LiveSessionListing {
    LiveSessionListing(
        sessionID: id,
        workingDirectory: cwd,
        title: title,
        model: "grok-4",
        createdAt: Date(timeIntervalSince1970: 1),
        lastActivityAt: Date(timeIntervalSince1970: activity),
        messageCount: 1,
        userMessageCount: 1,
        assistantMessageCount: 0
    )
}

private func list(_ overlay: PagerOverlay) -> PagerListOverlay? {
    guard case .list(let value) = overlay.content else { return nil }
    return value
}

@Suite("Dashboard roster overlay")
struct LiveDashboardOverlayTests {
    @Test("state headers group the roster; recency orders within a group")
    func headersAndOrdering() {
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [
                tab("old", title: "old work", activity: 100),
                tab("active-1", title: "current work", activity: 50),
                tab("recent", title: "recent work", activity: 200),
            ],
            activeSessionID: "active-1",
            activeTurnRunning: false,
            subagents: []
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        // Nothing is running, so every tab is Idle — one header, then
        // recency order. The active row keeps its marker and "attached"
        // state word without jumping the sort (upstream sorts by
        // state + recency, never active-first).
        #expect(list.rows.map(\.id) == [
            "section:idle", "attach:recent", "attach:old", "attach:active-1",
        ])
        #expect(list.rows[0].label.contains("Idle (3)"))
        #expect(!list.rows[0].label.contains("\u{25B8}"), "an uncollapsed header wears \u{25BE}")
        #expect(list.rows[3].label.contains("\u{25CF} "), "the active row wears the marker")
        #expect(list.rows[3].detail?.contains("attached") == true)
        #expect(list.rows[1].detail?.contains("idle") == true)
        // The cursor opens on the first session row, not the header.
        #expect(list.selectedRow?.id == "attach:recent")
    }

    @Test("a running turn lifts the active row into Working; background stays idle by construction")
    func runningTurnClassification() {
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [
                tab("bg", title: "background work", activity: 900),
                tab("a", title: "work", activity: 1),
            ],
            activeSessionID: "a",
            activeTurnRunning: true,
            subagents: []
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        // The background tab is MORE recent, but it can never be Working —
        // no parallel top-level turns in one process (the pre-ruled
        // divergence, pinned here).
        #expect(list.rows.map(\.id) == [
            "section:working", "attach:a", "section:idle", "attach:bg",
        ])
        #expect(list.rows[0].label.contains("Working (1)"))
        #expect(list.rows[1].detail?.contains("running") == true)
    }

    @Test("a pending approval classifies the active session as Awaiting")
    func needsInputClassification() {
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [tab("a", title: "work", activity: 1)],
            activeSessionID: "a",
            activeTurnRunning: true,
            activeNeedsInput: true,
            subagents: []
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows[0].label.contains("Awaiting (1)"), "needs-input outranks working")
    }

    @Test("subagent children glue under the active row, non-selectable")
    func subagentChildrenUnderTheActiveRowOnly() {
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [
                tab("active-1", title: "current", activity: 100),
                tab("other", title: "other", activity: 50),
            ],
            activeSessionID: "active-1",
            activeTurnRunning: true,
            subagents: [LiveSubagentSnapshot(
                subagentID: "sub-1",
                subagentType: "Explore",
                description: "map the tree",
                status: "running",
                output: "",
                startedAt: Date(),
                durationMS: 0,
                exitCode: nil
            )]
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows.map(\.id) == [
            "section:working", "attach:active-1", "subagent:sub-1",
            "section:idle", "attach:other",
        ])
        #expect(list.rows[0].label.contains("Working (1)"), "the header counts top-level rows only")
        #expect(list.rows[2].label.contains("Explore"))
        #expect(
            !list.rows[2].isSelectable,
            "peek/attach-to-subagent are deferred; a row that dispatches nowhere must not be selectable"
        )
    }

    @Test("dormant catalog sessions join as attachable Inactive rows, live ids skipped")
    func dormantRowsJoinTheRoster() {
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [tab("live-1", title: "live", activity: 100)],
            activeSessionID: "live-1",
            activeTurnRunning: false,
            subagents: [],
            dormant: [
                dormant("cold-1", cwd: "/Users/max/projects/alpha"),
                dormant("live-1", cwd: "/anywhere", title: "must not duplicate"),
            ]
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows.map(\.id) == [
            "section:idle", "attach:live-1", "section:inactive", "attach:cold-1",
        ])
        #expect(list.rows[2].label.contains("Inactive (1)"))
        #expect(list.rows[3].label.contains("alpha"), "an untitled dormant row is labelled by cwd basename")
        #expect(list.rows[3].detail?.contains("inactive") == true)
        #expect(list.rows[3].isSelectable, "dormant rows attach through the same /resume machinery")
    }

    @Test("directory grouping suppresses state headers and orders by compacted cwd")
    func directoryGrouping() {
        var state = PagerDashboardState()
        state.grouping = .directory
        state.home = "/Users/max"
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [tab("a", title: "work", activity: 1, cwd: "/Users/max/zeta")],
            activeSessionID: "a",
            activeTurnRunning: false,
            subagents: [],
            dormant: [dormant("cold", cwd: "/Users/max/alpha", title: "cold work")],
            state: state
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows.map(\.id) == ["attach:cold", "attach:a"], "cwd asc, no state headers")
        #expect(list.rows[0].detail?.contains("~/alpha") == true, "the cwd column compacts against home")
    }

    @Test("a state filter keeps exactly its rows and drops the redundant header")
    func stateFilterView() {
        var state = PagerDashboardState()
        state.filter = .from(PagerDashboardFilter.parse("s:working"))
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [
                tab("bg", title: "background", activity: 900),
                tab("a", title: "work", activity: 1),
            ],
            activeSessionID: "a",
            activeTurnRunning: true,
            subagents: [],
            state: state
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows.map(\.id) == ["attach:a"], "one state in view ⇒ no header chrome")
    }

    @Test("a collapsed section keeps its header, wearing the collapsed chevron, and hides its rows")
    func collapsedSection() {
        var state = PagerDashboardState()
        state.toggleSection(.state(.idle))
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [
                tab("bg", title: "background", activity: 900),
                tab("a", title: "work", activity: 1),
            ],
            activeSessionID: "a",
            activeTurnRunning: true,
            subagents: [],
            state: state
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows.map(\.id) == ["section:working", "attach:a", "section:idle"])
        #expect(list.rows[2].label.contains("\u{25B8}"))
        #expect(list.rows[2].label.contains("Idle (1)"), "the count stays true while collapsed")
    }

    @Test("pinned rows float above every group under the Pinned header")
    func pinnedRowsFloat() {
        var state = PagerDashboardState()
        state.togglePin(.session("bg"))
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [
                tab("bg", title: "background", activity: 5),
                tab("a", title: "work", activity: 900),
            ],
            activeSessionID: "a",
            activeTurnRunning: true,
            subagents: [],
            state: state
        )
        guard let list = list(overlay) else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows.map(\.id) == [
            "section:pinned", "attach:bg", "section:working", "attach:a",
        ])
        #expect(list.rows[0].label.contains("Pinned (1)"))
        #expect(list.rows[1].label.contains("\u{2299}"), "the pinned row wears the pin marker")
    }

    @Test("the idle fold lands at the group's end and expands through idleShowAll")
    func idleFold() {
        let tabs = [tab("a", title: "active", activity: 5_000)]
            + (0..<11).map { tab("idle-\($0)", title: "idle \($0)", activity: Double(100 - $0)) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let folded = LiveDashboardOverlay.overlay(
            tabs: tabs,
            activeSessionID: "a",
            activeTurnRunning: true,
            subagents: [],
            now: now
        )
        guard let foldedList = list(folded) else {
            Issue.record("expected a list overlay")
            return
        }
        let foldRow = foldedList.rows.first { $0.id == LiveDashboardOverlay.idleOverflowRowID }
        #expect(foldRow?.label.contains("\u{2026} 3 more idle") == true)
        #expect(
            foldedList.rows.filter { $0.id.hasPrefix("attach:idle-") }.count == 8,
            "the fold keeps the freshest 8"
        )

        var expandedState = PagerDashboardState()
        expandedState.idleShowAll = true
        let expanded = LiveDashboardOverlay.overlay(
            tabs: tabs,
            activeSessionID: "a",
            activeTurnRunning: true,
            subagents: [],
            state: expandedState,
            now: now
        )
        guard let expandedList = list(expanded) else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(expandedList.rows.filter { $0.id.hasPrefix("attach:idle-") }.count == 11)
        let toggle = expandedList.rows.first { $0.id == LiveDashboardOverlay.idleOverflowRowID }
        #expect(toggle?.label.contains("show fewer") == true)
    }

    @Test("the search query and a confirmed filter both surface in the title")
    func titleCarriesSearchAndFilter() {
        var filtered = PagerDashboardState()
        filtered.filter = .from(PagerDashboardFilter.parse("a:work"))
        let searching = LiveDashboardOverlay.overlay(
            tabs: [tab("a", title: "work", activity: 1)],
            activeSessionID: "a",
            activeTurnRunning: false,
            subagents: [],
            searchQuery: "s:idle"
        )
        let confirmed = LiveDashboardOverlay.overlay(
            tabs: [tab("a", title: "work", activity: 1)],
            activeSessionID: "a",
            activeTurnRunning: false,
            subagents: [],
            state: filtered
        )
        #expect(searching.title == "Agent Dashboard \u{2014} /s:idle")
        #expect(confirmed.title == "Agent Dashboard \u{2014} filtered")
    }

    @Test("chord-side id mapping round-trips rows and sections")
    func chordSideMapping() {
        let live: Set<String> = ["live-1"]
        #expect(LiveDashboardOverlay.dashboardRowID(
            forListRowID: "attach:live-1", activeSessionID: "live-1", liveSessionIDs: live
        ) == .session("live-1"))
        #expect(LiveDashboardOverlay.dashboardRowID(
            forListRowID: "attach:cold-1", activeSessionID: "live-1", liveSessionIDs: live
        ) == .dormant("cold-1"))
        #expect(LiveDashboardOverlay.dashboardRowID(
            forListRowID: "subagent:sub-9", activeSessionID: "live-1", liveSessionIDs: live
        ) == .subagent(parent: "live-1", child: "sub-9"))
        #expect(LiveDashboardOverlay.dashboardRowID(
            forListRowID: "section:idle", activeSessionID: "live-1", liveSessionIDs: live
        ) == nil, "a header is not a pinnable row")

        #expect(LiveDashboardOverlay.sectionKey(forListRowID: "section:pinned") == .pinned)
        #expect(LiveDashboardOverlay.sectionKey(forListRowID: "attach:live-1") == nil)
        for state in [PagerDashboardRowState.needsInput, .working, .idle, .inactive,
                      .completed, .failed, .blocked] {
            #expect(
                LiveDashboardOverlay.sectionKey(
                    forListRowID: "section:" + LiveDashboardOverlay.token(for: state)
                ) == .state(state),
                "the section id vocabulary round-trips through parseToken"
            )
        }
    }
}

extension LiveDashboardOverlayTests {
    /// The roster's initial cursor must resolve a peek, and a non-selectable
    /// subagent child must never request one (peek-onto-a-subagent lands with
    /// subagent attach, the B1 peek ruling).
    @Test func initialPeekAndSubagentRefusal() {
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [tab("active-1", title: "current", activity: 100)],
            activeSessionID: "active-1",
            activeTurnRunning: true,
            subagents: [LiveSubagentSnapshot(
                subagentID: "sub-1", subagentType: "Explore", description: "map",
                status: "running", output: "", startedAt: Date(),
                durationMS: 0, exitCode: nil
            )]
        )
        guard case .list(let list) = overlay.content else {
            Issue.record("expected a list overlay")
            return
        }
        let cache = LiveDashboardPeekCache()
        let selected = list.selectedRow
        #expect(selected?.id == "attach:active-1", "the cursor starts on the active row, not its header")
        #expect(LiveDashboardPeek.peek(
            forRowID: selected?.id ?? "",
            cache: cache,
            activeSessionID: "active-1",
            activeItems: [.message(PagerMessage(role: .user, text: "ask"))],
            turnActivity: "Thinking\u{2026}"
        )?.statusLabel == "Thinking")
        let childRowID = list.rows.first { $0.id.hasPrefix("subagent:") }?.id ?? ""
        #expect(LiveDashboardPeek.peek(
            forRowID: childRowID,
            cache: cache,
            activeSessionID: "active-1",
            activeItems: [],
            turnActivity: nil
        ) == nil, "a row that dispatches nowhere gets no peek either")
    }

    /// The C-1 close verb's overlay half: the `x` action is registered with
    /// the `close` prefix, and an ARMED session shows its confirmation ON the
    /// row — the port's press-again analog of upstream's 2 s arm window
    /// (`arm_or_delete`, dispatch/dashboard.rs:2125-2140). Un-armed rows keep
    /// their meta detail; other rows never inherit the armed text.
    @Test func closeActionRegistrationAndArmedRowDetail() {
        let armed = LiveDashboardOverlay.overlay(
            tabs: [
                tab("active-1", title: "current", activity: 100),
                tab("bg-1", title: "background", activity: 50),
                tab("bg-2", title: "other background", activity: 25),
            ],
            activeSessionID: "active-1",
            activeTurnRunning: false,
            subagents: [],
            armedCloseSessionID: "bg-1"
        )
        guard case .list(let list) = armed.content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rowActions == [PagerListRowAction(key: "x", rowIDPrefix: "close")])
        let byID = Dictionary(uniqueKeysWithValues: list.rows.map { ($0.id, $0) })
        #expect(byID["attach:bg-1"]?.detail == "press x again to delete")
        #expect(byID["attach:bg-2"]?.detail?.contains("idle") == true, "only the armed row wears the confirmation")
        #expect(armed.hints.contains { $0.key == "x" })
    }
}
