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
        #expect(selected?.id == "attach:active-1", "the cursor starts on the active row")
        #expect(LiveDashboardPeek.peek(
            forRowID: selected?.id ?? "",
            cache: cache,
            activeSessionID: "active-1",
            activeItems: [.message(PagerMessage(role: .user, text: "ask"))],
            turnActivity: "Thinking\u{2026}"
        )?.statusLabel == "Thinking")
        #expect(LiveDashboardPeek.peek(
            forRowID: list.rows[1].id,
            cache: cache,
            activeSessionID: "active-1",
            activeItems: [],
            turnActivity: nil
        ) == nil, "a row that dispatches nowhere gets no peek either")
    }
}

extension LiveDashboardOverlayTests {
    /// The C-1 close verb's overlay half: the `x` action is registered with
    /// the `close` prefix, and an ARMED session shows its confirmation ON the
    /// row — the port's press-again analog of upstream's 2 s arm window
    /// (`arm_or_delete`, dispatch/dashboard.rs:2125-2140). Un-armed rows keep
    /// the id·state detail; other rows never inherit the armed text.
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
        #expect(list.rows[1].detail == "press x again to delete")
        #expect(list.rows[2].detail?.contains("idle") == true, "only the armed row wears the confirmation")
        #expect(armed.hints.contains { $0.key == "x" })
    }
}
