// PagerTasksPaneTests.swift
//
// Wave 18 B1-t: the Ctrl+G tasks pane's render-side contract — grouping,
// collapse, selection, the desired-height rule, the `f` filter bar, and the
// per-key affordances. Upstream reference at pin 650c1db7:
// `views/tasks_pane.rs` (`GroupKind` order/labels :178-215,
// `desired_height` :1168-1190), the caller key arms
// (`agent_view/panes.rs:312-455`), and the shared list pane's input bar
// (`views/list_pane/state/methods.rs:1551-1660`, `:1873-1915`). The band's
// chrome slot (below the status bar/banner, conversation shrinks) is
// asserted through the real frame renderer.

import Foundation
import Testing
import OpenGrokTerminalCore
@testable import OpenGrokPagerRender

private func entry(
    _ id: String,
    group: PagerTaskPaneGroup,
    label: String,
    running: Bool = false,
    kill: PagerTaskPaneAction? = nil,
    copy: PagerTaskPaneAction? = nil,
    open: PagerTaskPaneAction? = nil
) -> PagerTaskPaneEntry {
    PagerTaskPaneEntry(
        id: id,
        group: group,
        spans: [PagerStyledSpan(text: label)],
        running: running,
        killAction: kill,
        copyAction: copy,
        openAction: open
    )
}

/// Drive the filter bar the way a user does. The FIRST `f` opens the bar
/// (the bar then swallows every later key, `f` included).
private func type(_ text: String, into pane: inout PagerTasksPaneState) {
    for character in text {
        _ = pane.handle(KeyEvent(key: .char(character)))
    }
}

@Suite("Tasks pane state")
struct PagerTasksPaneStateTests {
    @Test("groups order fixed, headers only for non-empty groups")
    func groupOrderAndHeaders() {
        // GroupKind::order (tasks_pane.rs:203-210): Workflows → Subagents →
        // Tasks → Watchers; an empty group contributes no header.
        let pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "task one"),
            entry("w1", group: .workflows, label: "wf one"),
            entry("l1", group: .watchers, label: "loop one"),
        ])
        let rows = pane.visibleRows
        #expect(rows.count == 6, "three headers + three entries")
        guard case .header(let firstGroup, 1, false) = rows[0] else {
            Issue.record("expected a workflows header first, got \(rows[0])")
            return
        }
        #expect(firstGroup == .workflows)
        guard case .header(let thirdGroup, _, _) = rows[2] else {
            Issue.record("expected the tasks header at index 2")
            return
        }
        #expect(thirdGroup == .tasks, "no Subagents header when the group is empty")
    }

    @Test("collapse hides a group's entries and Enter toggles it")
    func collapseHidesEntries() {
        var pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "one"),
            entry("t2", group: .tasks, label: "two"),
        ])
        #expect(pane.visibleRows.count == 3)
        // Selection starts on the header; Enter collapses (panes.rs:342-344).
        #expect(pane.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(pane.visibleRows.count == 1, "collapsed group hides its entries")
        // Right expands a collapsed header (panes.rs:327-337).
        #expect(pane.handle(KeyEvent(key: .right)) == .redraw)
        #expect(pane.visibleRows.count == 3)
        // Left collapses it again.
        #expect(pane.handle(KeyEvent(key: .left)) == .redraw)
        #expect(pane.visibleRows.count == 1)
    }

    @Test("x maps to the selected entry's kill action; finished entries refuse")
    func killMapping() {
        var pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "running", running: true,
                  kill: .killBgTask(taskID: "task-1")),
            entry("t2", group: .tasks, label: "done"),
        ])
        _ = pane.handle(KeyEvent(key: .down)) // header → first entry
        #expect(
            pane.handle(KeyEvent(key: .char("x")))
                == .action(.killBgTask(taskID: "task-1"))
        )
        _ = pane.handle(KeyEvent(key: .down))
        #expect(
            pane.handle(KeyEvent(key: .char("x"))) == .consumed,
            "a finished entry has no kill target (panes.rs:388-392 running gate)"
        )
    }

    @Test("Tab keeps the pane and focuses the prompt; Esc closes")
    func focusAndClose() {
        var pane = PagerTasksPaneState(entries: [entry("t1", group: .tasks, label: "one")])
        #expect(pane.handle(KeyEvent(key: .tab)) == .focusPrompt)
        #expect(pane.handle(KeyEvent(key: .escape)) == .close)
        #expect(
            pane.handle(KeyEvent(key: .char("g"), modifiers: [.control])) == .close,
            "Ctrl+G toggles off from inside the pane"
        )
    }

    @Test("a refresh preserves collapse and re-anchors selection by id")
    func refreshPreservesSelection() {
        var pane = PagerTasksPaneState(entries: [
            entry("a", group: .tasks, label: "a"),
            entry("b", group: .tasks, label: "b"),
        ])
        _ = pane.handle(KeyEvent(key: .down))
        _ = pane.handle(KeyEvent(key: .down)) // select "b"
        #expect(pane.selectedEntry?.id == "b")
        // A newer entry lands above "b" in the same group.
        pane.updateEntries([
            entry("c", group: .tasks, label: "c"),
            entry("a", group: .tasks, label: "a"),
            entry("b", group: .tasks, label: "b"),
        ])
        #expect(pane.selectedEntry?.id == "b", "selection follows the id, not the index")
    }

    @Test("Enter opens the selected entry and headers keep toggling")
    func enterOpensTheSelectedEntry() {
        // panes.rs:339-383: the open key checks `selected_header_group()`
        // FIRST, so growing an open arm must not cost headers their toggle.
        var pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "one", open: .openBgTaskOutput(taskID: "bg-1")),
            entry("t2", group: .tasks, label: "two"),
        ])
        #expect(pane.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(pane.visibleRows.count == 1, "Enter on the header still collapses")
        #expect(pane.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(pane.visibleRows.count == 3, "and still expands")
        _ = pane.handle(KeyEvent(key: .down))
        #expect(
            pane.handle(KeyEvent(key: .enter)) == .action(.openBgTaskOutput(taskID: "bg-1")),
            "Enter on a bg task opens the block viewer over its stdout"
        )
        _ = pane.handle(KeyEvent(key: .down))
        #expect(
            pane.handle(KeyEvent(key: .enter)) == .consumed,
            "a row upstream opens nothing for (Scheduled, panes.rs:371) stays inert"
        )
    }

    @Test("y maps to the selected entry's copy action; a row with no output refuses")
    func copyMapping() {
        // panes.rs:422-430 gates the copy on `!task.stdout.is_empty()`; the
        // builder is what applies that gate, so the pane just honors the
        // target it was handed — and refuses when there is none.
        var pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "with output",
                  copy: .copyBgTaskOutput(taskID: "task-1")),
            entry("t2", group: .tasks, label: "silent"),
        ])
        _ = pane.handle(KeyEvent(key: .down))
        #expect(
            pane.handle(KeyEvent(key: .char("y")))
                == .action(.copyBgTaskOutput(taskID: "task-1"))
        )
        _ = pane.handle(KeyEvent(key: .down))
        #expect(pane.handle(KeyEvent(key: .char("y"))) == .consumed)
    }

    @Test("desired height hides under 12 rows and caps at min(8, 15%)")
    func desiredHeightRule() {
        // tasks_pane.rs:1168-1190.
        let empty = PagerTasksPaneState()
        #expect(empty.desiredHeight(viewHeight: 11) == 0, "short terminals hide the pane")
        #expect(empty.desiredHeight(viewHeight: 40) == 1, "empty pane is one row")

        let many = PagerTasksPaneState(entries: (0..<20).map {
            entry("t\($0)", group: .tasks, label: "task \($0)")
        })
        // 40 rows → 15% = 6, under the 8 cap.
        #expect(many.desiredHeight(viewHeight: 40) == 6)
        // 100 rows → 15% = 15, capped at 8.
        #expect(many.desiredHeight(viewHeight: 100) == 8)
        let few = PagerTasksPaneState(entries: [entry("t1", group: .tasks, label: "one")])
        #expect(few.desiredHeight(viewHeight: 40) == 2, "header + entry fit uncapped")
    }
}

@Suite("Tasks pane filter bar")
struct PagerTasksPaneFilterTests {
    private func filterPane() -> PagerTasksPaneState {
        PagerTasksPaneState(entries: [
            entry("w1", group: .workflows, label: "audit"),
            entry("t1", group: .tasks, label: "build the thing"),
            entry("t2", group: .tasks, label: "deploy the thing"),
        ])
    }

    @Test("f opens the bar and buys it a row")
    func filterOpensAndTakesARow() {
        var pane = filterPane()
        // 15% of 40 = 6, so the five rows fit uncapped.
        #expect(pane.visibleRows.count == 5)
        #expect(pane.desiredHeight(viewHeight: 40) == 5)
        #expect(pane.handle(KeyEvent(key: .char("f"))) == .redraw)
        #expect(pane.filterQuery == "", "the bar opens empty (open_input, methods.rs:1873-1889)")
        #expect(
            pane.desiredHeight(viewHeight: 40) == 6,
            "the bar gets its own row instead of displacing an entry (tasks_pane.rs:1181-1190)"
        )
    }

    @Test("typing hides non-matching entries and the headers left holding nothing")
    func typingFiltersRowsAndHeaders() {
        var pane = filterPane()
        type("f", into: &pane)
        type("deploy", into: &pane)
        #expect(pane.filterQuery == "deploy")
        let rows = pane.visibleRows
        #expect(rows.count == 2, "the Tasks header plus its one match, got \(rows)")
        guard case .header(let group, 1, _) = rows[0] else {
            Issue.record("expected a header first, got \(rows[0])")
            return
        }
        #expect(group == .tasks, "the Workflows header goes with its only entry")
        #expect(pane.selectedIndex < rows.count, "the selection cannot point past the rows")
        // Case-insensitive: the matcher is a lowercased substring, not a
        // case-sensitive one.
        var upper = pane
        _ = upper.handle(KeyEvent(key: .escape))
        type("f", into: &upper)
        type("DEPLOY", into: &upper)
        #expect(upper.visibleRows.count == 2)
    }

    @Test("Enter accepts and keeps the filter; Esc drops it")
    func acceptAndCancel() {
        var pane = filterPane()
        type("f", into: &pane)
        type("audit", into: &pane)
        #expect(pane.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(pane.filterQuery == nil, "the bar closes")
        #expect(pane.acceptedFilter == "audit", "the matcher survives it (accept_input)")
        #expect(pane.visibleRows.count == 2, "and the pane stays filtered")
        #expect(
            pane.desiredHeight(viewHeight: 40) == 3,
            "an accepted matcher keeps the status row (tasks_pane.rs:1181-1190)"
        )
        // Reopening on a live matcher keeps the buffer text.
        #expect(pane.handle(KeyEvent(key: .char("f"))) == .redraw)
        #expect(pane.filterQuery == "audit")
        #expect(pane.handle(KeyEvent(key: .escape)) == .redraw)
        #expect(pane.acceptedFilter == nil, "Esc drops the matcher too (cancel_input)")
        #expect(pane.visibleRows.count == 5)
        #expect(pane.desiredHeight(viewHeight: 40) == 5)
    }

    @Test("an empty query accepts nothing, and empties close the bar")
    func emptyQueryPaths() {
        var pane = filterPane()
        type("f", into: &pane)
        #expect(pane.handle(KeyEvent(key: .backspace)) == .redraw)
        #expect(pane.filterQuery == nil, "Backspace on an empty query closes the bar")
        type("f", into: &pane)
        type("ab", into: &pane)
        #expect(pane.handle(KeyEvent(key: .char("c"), modifiers: [.control])) == .redraw)
        #expect(pane.filterQuery == "", "Ctrl+C clears a non-empty query")
        #expect(pane.acceptedFilter == nil)
        #expect(pane.handle(KeyEvent(key: .char("c"), modifiers: [.control])) == .redraw)
        #expect(pane.filterQuery == nil, "a second Ctrl+C closes the emptied bar")
        type("f", into: &pane)
        #expect(pane.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(pane.acceptedFilter == nil, "Enter on an empty query accepts no matcher")
        #expect(pane.desiredHeight(viewHeight: 40) == 5, "and gives the row back")
    }

    @Test("x / y / Enter / Tab are inert while the bar is open; Ctrl+G is not")
    func barConsumesTheAffordanceKeys() {
        // The port-bug hiding place: upstream guards every caller arm with
        // `input_mode().is_none()` (panes.rs:327-431). Here the bar consumes
        // first, which is the same thing — except Ctrl+G, the one arm
        // upstream deliberately leaves outside the guard (panes.rs:318-326).
        var pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "running", running: true,
                  kill: .killBgTask(taskID: "task-1"),
                  copy: .copyBgTaskOutput(taskID: "task-1"),
                  open: .openBgTaskOutput(taskID: "task-1")),
        ])
        _ = pane.handle(KeyEvent(key: .down))
        #expect(pane.selectedEntry?.id == "t1")
        type("f", into: &pane)
        #expect(pane.handle(KeyEvent(key: .char("x"))) == .redraw, "x types, it does not kill")
        #expect(pane.handle(KeyEvent(key: .char("y"))) == .redraw, "y types, it does not copy")
        #expect(pane.filterQuery == "xy")
        #expect(pane.handle(KeyEvent(key: .tab)) == .consumed, "Tab does not hand back focus")
        #expect(
            pane.handle(KeyEvent(key: .enter)) == .redraw,
            "Enter accepts the query, it does not open the viewer"
        )
        #expect(pane.acceptedFilter == "xy")
        type("f", into: &pane)
        #expect(
            pane.handle(KeyEvent(key: .char("g"), modifiers: [.control])) == .close,
            "Ctrl+G still toggles the band off from inside the bar"
        )
    }

    @Test("the selection re-anchors when the filter hides the selected row")
    func selectionSurvivesFiltering() {
        var pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "alpha"),
            entry("t2", group: .tasks, label: "beta"),
        ])
        _ = pane.handle(KeyEvent(key: .down))
        _ = pane.handle(KeyEvent(key: .down))
        #expect(pane.selectedEntry?.id == "t2")
        type("f", into: &pane)
        type("alpha", into: &pane)
        #expect(pane.visibleRows.count == 2, "header + the one match")
        #expect(
            pane.selectedIndex < pane.visibleRows.count,
            "a stale index would paint a selection band on a row that is gone"
        )
        #expect(pane.selectedEntry?.id == "t1", "the selection lands on a surviving row")
    }
}

@Suite("Tasks pane in the frame")
struct PagerTasksPaneFrameTests {
    @Test("the pane paints as a band below the chrome and shrinks the transcript")
    func panePaintsAsABand() {
        let pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "PANEROW", running: true,
                  kill: .killBgTask(taskID: "t1")),
        ])
        let withPane = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 80, height: 30),
            statusBar: PagerStatusBar(workingDirectory: "/tmp"),
            conversation: [.message(PagerMessage(role: .assistant, text: "TRANSCRIPTWORD"))],
            input: PagerComposerState(),
            tasksPane: pane
        ))
        var text = ""
        for y in 0..<30 {
            for x in 0..<80 {
                text += withPane.buffer.cell(x: x, y: y)?.grapheme ?? " "
            }
            text += "\n"
        }
        #expect(text.contains("Tasks"), "the group header paints")
        #expect(text.contains("PANEROW"), "the entry paints")
        #expect(text.contains("TRANSCRIPTWORD"), "the transcript still paints below")
        let paneLine = text.split(separator: "\n").firstIndex { $0.contains("PANEROW") }
        let transcriptLine = text.split(separator: "\n").firstIndex { $0.contains("TRANSCRIPTWORD") }
        #expect(
            paneLine != nil && transcriptLine != nil && paneLine! < transcriptLine!,
            "the band sits between the status bar and the transcript (agent.rs:210-213)"
        )
    }

    @Test("the filter bar paints on its own row, then the accepted matcher")
    func filterBarPaints() {
        func frameText(_ pane: PagerTasksPaneState) -> String {
            let render = renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 80, height: 30),
                statusBar: PagerStatusBar(workingDirectory: "/tmp"),
                conversation: [.message(PagerMessage(role: .assistant, text: "TRANSCRIPTWORD"))],
                input: PagerComposerState(),
                tasksPane: pane
            ))
            var text = ""
            for y in 0..<30 {
                for x in 0..<80 {
                    text += render.buffer.cell(x: x, y: y)?.grapheme ?? " "
                }
                text += "\n"
            }
            return text
        }
        var pane = PagerTasksPaneState(entries: [
            entry("t1", group: .tasks, label: "PANEROW"),
            entry("t2", group: .tasks, label: "OTHERROW"),
        ])
        type("f", into: &pane)
        type("PANE", into: &pane)
        let open = frameText(pane)
        #expect(open.contains("f> PANE"), "the open bar shows the prompt (InputBarMode::prompt)")
        #expect(open.contains("PANEROW"), "the match still paints above the bar")
        #expect(open.contains("OTHERROW") == false, "the non-match is filtered out")
        #expect(open.contains("TRANSCRIPTWORD"), "the transcript still paints below the band")

        _ = pane.handle(KeyEvent(key: .enter))
        let accepted = frameText(pane)
        #expect(
            accepted.contains("[filter: PANE]"),
            "an accepted matcher says why the pane is showing fewer rows (render.rs:580-591)"
        )
        #expect(accepted.contains("PANEROW"))
    }

    @Test("a hidden pane changes nothing")
    func hiddenPaneChangesNothing() {
        let without = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 80, height: 30),
            conversation: [.message(PagerMessage(role: .assistant, text: "steady"))],
            input: PagerComposerState()
        ))
        let withNil = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 80, height: 30),
            conversation: [.message(PagerMessage(role: .assistant, text: "steady"))],
            input: PagerComposerState(),
            tasksPane: nil
        ))
        #expect(without.buffer == withNil.buffer)
    }
}
