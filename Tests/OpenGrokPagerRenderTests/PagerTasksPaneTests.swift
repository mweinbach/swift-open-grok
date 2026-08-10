// PagerTasksPaneTests.swift
//
// Wave 18 B1-t: the Ctrl+G tasks pane's render-side contract — grouping,
// collapse, selection, the desired-height rule, and the per-key
// affordances. Upstream reference at pin 650c1db7: `views/tasks_pane.rs`
// (`GroupKind` order/labels :178-215, `desired_height` :1168-1190) and the
// caller key arms (`agent_view/panes.rs:312-455`). The band's chrome slot
// (below the status bar/banner, conversation shrinks) is asserted through
// the real frame renderer.

import Foundation
import Testing
import OpenGrokTerminalCore
@testable import OpenGrokPagerRender

private func entry(
    _ id: String,
    group: PagerTaskPaneGroup,
    label: String,
    running: Bool = false,
    kill: PagerTaskPaneAction? = nil
) -> PagerTaskPaneEntry {
    PagerTaskPaneEntry(
        id: id,
        group: group,
        spans: [PagerStyledSpan(text: label)],
        running: running,
        killAction: kill
    )
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
