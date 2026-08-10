// LiveDashboardOverlay.swift
//
// Wave 18 B1-d (v1): the Agent Dashboard roster — the port of
// `views/dashboard/` at pin 650c1db7, scoped to what the port's
// single-runtime architecture grounds: the in-process session tabs
// (B1-m's registry) with the ACTIVE session's live subagents as child
// rows, Enter attaching a top-level row through the SAME `/resume`
// machinery the sessions picker rides. The full upstream surface —
// grouping, filters, pins, peek panel, dispatch, location picker, the
// worktree dialog (~26k lines) — is deferred with the ledger entry; rows
// and attach are the dashboard's load-bearing core (`dashboard/mod.rs`:
// "agent-native list of every top-level agent and its subagents … with
// peek, attach, and dispatch affordances").

import Foundation
import OpenGrokPagerRender

/// One in-process session tab — B1-m's registry entry. Metadata only: the
/// pre-ruled divergence keeps background tabs idle, so a row needs no
/// retained conversation to be truthful.
struct LiveSessionTab: Sendable, Equatable {
    var sessionID: String
    var title: String
    var lastActivity: Date
}

enum LiveDashboardOverlay {
    static let overlayID = "dashboard"

    /// Row id prefix for attachable top-level sessions; the select arm
    /// strips it and rides `/resume <id>`.
    static let attachPrefix = "attach:"
    /// The `x` close verb's row-action prefix (B1 C-1): the dispatched rowID
    /// is `close:attach:<sessionID>`.
    static let closePrefix = "close"

    static func overlay(
        tabs: [LiveSessionTab],
        activeSessionID: String,
        activeTurnRunning: Bool,
        subagents: [LiveSubagentSnapshot],
        armedCloseSessionID: String? = nil,
        now: Date = Date()
    ) -> PagerOverlay {
        var rows: [PagerListRow] = []

        // Active first, then most-recent activity — the dashboard's sort
        // spirit (`row.rs` state + last_change_at) reduced to the two
        // signals the registry carries.
        let ordered = tabs.sorted { a, b in
            let (aActive, bActive) = (a.sessionID == activeSessionID, b.sessionID == activeSessionID)
            if aActive != bActive { return aActive }
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            return a.sessionID < b.sessionID
        }
        for tab in ordered {
            let isActive = tab.sessionID == activeSessionID
            let state: String
            if isActive {
                state = activeTurnRunning ? "running" : "attached"
            } else {
                state = "idle"
            }
            // An armed close shows its confirmation ON the row — the port's
            // press-again-no-timer analog of upstream's 2 s arm window
            // (`arm_or_delete`, dispatch/dashboard.rs:2125-2140).
            let detail = tab.sessionID == armedCloseSessionID
                ? "press x again to delete"
                : "\(shortID(tab.sessionID)) \u{00B7} \(state)"
            rows.append(PagerListRow(
                id: attachPrefix + tab.sessionID,
                label: (isActive ? "\u{25CF} " : "  ") + tab.title,
                detail: detail
            ))
            guard isActive else { continue }
            // The active session's subagent children — the "agent map"
            // half the subagent host grounds today. Running first, the
            // pane's order.
            let children = subagents.sorted { a, b in
                let (aRunning, bRunning) = (a.status == "running", b.status == "running")
                if aRunning != bRunning { return aRunning }
                return a.startedAt > b.startedAt
            }
            for child in children {
                let (typeLabel, description) = LivePagerTasksBlock.subagentLabel(
                    type: child.subagentType,
                    description: child.description
                )
                let label = description.isEmpty ? typeLabel : "\(typeLabel) \u{00B7} \(description)"
                let elapsed = child.status == "running"
                    ? max(0, now.timeIntervalSince(child.startedAt))
                    : TimeInterval(child.durationMS) / 1_000
                rows.append(PagerListRow(
                    id: "subagent:\(child.subagentID)",
                    label: "    \u{21B3} \(label)",
                    detail: "\(child.status) \u{00B7} \(LivePagerTasksBlock.formatDuration(elapsed))",
                    // Peek/attach-to-subagent are deferred surfaces; a row
                    // that dispatches nowhere must not be selectable (§4).
                    isSelectable: false
                ))
            }
        }

        var overlay = PagerOverlay.list(
            id: overlayID,
            title: "Agent Dashboard",
            rows: rows,
            isFilterable: true,
            hints: [
                PagerOverlayHint(key: "\u{2191}\u{2193}", label: "select"),
                PagerOverlayHint(key: "enter", label: "attach"),
                PagerOverlayHint(key: "x", label: "delete session"),
                PagerOverlayHint(key: "esc", label: "close"),
            ]
        )
        if case .list(var list) = overlay.content {
            // `x` deletes the selected session row — the port of upstream's
            // Ctrl+X delete leg (`dispatch_dashboard_stop`,
            // dispatch/dashboard.rs:1980-2062). The chord is a bare `x`
            // because the list's action table is consulted before the filter
            // takes the character (recorded cost: `x` no longer types into
            // this overlay's filter). The busy-stop leg has no port analog —
            // background tabs are idle by construction, and the ACTIVE row
            // refuses with the /delete route.
            list.rowActions = [PagerListRowAction(key: "x", rowIDPrefix: closePrefix)]
            overlay.content = .list(list)
        }
        return overlay
    }

    private static func shortID(_ id: String) -> String {
        id.count > 8 ? String(id.prefix(8)) : id
    }
}
