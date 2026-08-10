// LiveDashboardOverlayTests.swift
//
// Wave 18 B1-d: the roster overlay's build rules — active-first ordering,
// the active session's state word, subagent children under the ACTIVE row
// only (non-selectable until peek/attach-to-subagent land), and the attach
// row ids the select arm strips into `/resume <id>`.

import Foundation
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

private func tab(_ id: String, title: String, activity: TimeInterval) -> LiveSessionTab {
    LiveSessionTab(
        sessionID: id,
        title: title,
        lastActivity: Date(timeIntervalSince1970: activity)
    )
}

@Suite("Dashboard roster overlay")
struct LiveDashboardOverlayTests {
    @Test("active first, then most recent activity; attach ids carry the session")
    func orderingAndAttachIDs() {
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
        guard case .list(let list) = overlay.content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows.map(\.id) == [
            "attach:active-1", "attach:recent", "attach:old",
        ])
        #expect(list.rows[0].label.hasPrefix("\u{25CF} "), "the active row wears the marker")
        #expect(list.rows[0].detail?.contains("attached") == true)
        #expect(list.rows[1].detail?.contains("idle") == true)
    }

    @Test("a running turn shows on the active row")
    func runningTurnShowsOnTheActiveRow() {
        let overlay = LiveDashboardOverlay.overlay(
            tabs: [tab("a", title: "work", activity: 1)],
            activeSessionID: "a",
            activeTurnRunning: true,
            subagents: []
        )
        guard case .list(let list) = overlay.content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows[0].detail?.contains("running") == true)
    }

    @Test("subagent children sit under the active row only, non-selectable")
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
        guard case .list(let list) = overlay.content else {
            Issue.record("expected a list overlay")
            return
        }
        // active, its child, then the other session.
        #expect(list.rows.count == 3)
        #expect(list.rows[1].id == "subagent:sub-1")
        #expect(list.rows[1].label.contains("Explore"))
        #expect(
            !list.rows[1].isSelectable,
            "peek/attach-to-subagent are deferred; a row that dispatches nowhere must not be selectable"
        )
        #expect(list.rows[2].id == "attach:other")
    }
}
