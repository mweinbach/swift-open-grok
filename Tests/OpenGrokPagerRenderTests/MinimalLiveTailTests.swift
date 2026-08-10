// MinimalLiveTailTests.swift
//
// Wave 18 B2-M3: the live tail and the viewport-sizing half of the overlay
// host. Ports the portable tests of `live.rs`/`overlay.rs` at pin 650c1db7
// and pins the port-specific seams: the transcript store's classification
// mapping (which upstream doesn't need — its state entries ARE the render
// blocks), measure/draw agreement (the port's analog of upstream's
// `the_animation_tick_never_changes_a_blocks_height` — one constructor on
// both sides), bottom-anchored clipping, the two `syncViewport` resize
// paths, and the sizing math tables.

import Foundation
import Testing
import OpenGrokMinimalScrollback
import OpenGrokTerminalCore
@testable import OpenGrokPagerRender

private let theme = PagerRenderTheme.default

private func assistant(_ text: String) -> PagerConversationItem {
    .message(PagerMessage(role: .assistant, text: text))
}

@Suite("Minimal transcript store")
struct MinimalTranscriptStoreTests {
    @Test("items classify onto the pipeline block model")
    func itemsClassifyOntoThePipelineBlockModel() {
        #expect(MinimalTranscript.classify(assistant("hi")) == .agentMessage("hi"))
        #expect(
            MinimalTranscript.classify(.message(PagerMessage(role: .reasoning, text: "hm")))
                == .thinking("hm")
        )
        #expect(
            MinimalTranscript.classify(.message(PagerMessage(role: .user, text: "go")))
                == .userPrompt("go")
        )
        #expect(
            MinimalTranscript.classify(.message(PagerMessage(role: .system, text: "note")))
                == .system("note")
        )
        #expect(
            MinimalTranscript.classify(.message(PagerMessage(role: .error, text: "boom")))
                == .system("boom")
        )
        #expect(MinimalTranscript.classify(.separator("──")) == .stub("──"))

        let kinds: [(PagerToolKind, MinimalToolKind)] = [
            (.read, .read),
            (.edit, .edit),
            (.create, .edit), // the edit family: diffs always full (K9)
            (.execute, .execute),
            (.search, .search),
            (.list, .listDir),
            (.fetch, .webFetch),
            (.webSearch, .webSearch),
        ]
        for (portKind, pipelineKind) in kinds {
            let block = MinimalTranscript.classify(.tool(PagerToolCard(
                name: "t", kind: portKind, state: .succeeded
            )))
            #expect(block == .toolCall(kind: pipelineKind, error: nil), "\(portKind)")
        }
        #expect(
            MinimalTranscript.classify(.tool(PagerToolCard(name: "custom_tool", kind: .generic)))
                == .toolCall(kind: .other("custom_tool"), error: nil)
        )
        // Failed/cancelled cards carry an error, so the display-mode policy
        // keeps them Truncated (never a collapsed row hiding the failure).
        #expect(
            MinimalTranscript.classify(.tool(PagerToolCard(name: "Search", kind: .search, state: .failed)))
                == .toolCall(kind: .search, error: "failed")
        )
        #expect(
            MinimalTranscript.classify(.tool(PagerToolCard(name: "Run", kind: .execute, state: .cancelled)))
                == .toolCall(kind: .execute, error: "cancelled")
        )
    }

    @Test("an explicit bg-task classification survives payload updates")
    func explicitBgTaskClassificationSurvivesPayloadUpdates() {
        let transcript = MinimalTranscript()
        let card = PagerToolCard(name: "task", kind: .generic, input: "sleep 60", state: .running)
        let id = transcript.push(
            .tool(card),
            block: .bgTask(command: "sleep 60", taskID: "task-1"),
            running: true
        )
        // The override is what lets the started block commit mid-turn
        // (commit.rs:67-77: the flag is animation-only for lifecycle blocks).
        #expect(isCommittable(
            transcript.state.entry(at: 0)!, turnRunning: true, isLast: true
        ))

        var updated = card
        updated.detail = "(running)"
        #expect(transcript.updateItem(id, .tool(updated)))
        if case .bgTask = transcript.state.entry(at: 0)!.block {
        } else {
            Issue.record("the pinned classification must survive an item update")
        }
    }

    @Test("payloads stay in sync across update, removal, and clear")
    func payloadsStayInSyncAcrossUpdateRemovalAndClear() {
        let transcript = MinimalTranscript()
        let a = transcript.push(assistant("a"))
        let b = transcript.push(.tool(PagerToolCard(name: "Run", kind: .execute, state: .running)), running: true)
        transcript.push(assistant("c"))

        // A state transition re-derives the classification.
        #expect(transcript.updateItem(b, .tool(PagerToolCard(name: "Run", kind: .execute, state: .failed))))
        #expect(
            transcript.state.entry(at: 1)!.block == .toolCall(kind: .execute, error: "failed")
        )

        #expect(transcript.removeEntry(a))
        #expect(transcript.item(for: a) == nil, "removed payloads must not linger")
        #expect(transcript.item(at: 0) != nil, "shifted entries keep their payloads")

        let removed = transcript.removeFrom(1)
        #expect(removed.count == 1)
        #expect(transcript.item(for: removed[0].id) == nil)

        transcript.clear()
        #expect(transcript.state.isEmpty)
        #expect(transcript.item(for: b) == nil)

        // A stale id after clear is an honest no-op, not a resurrection.
        #expect(!transcript.updateItem(b, assistant("ghost")))
    }
}

@Suite("Minimal live tail")
struct MinimalLiveTailTests {
    @Test("tail height counts only entries past the frontier scan")
    func tailHeightCountsOnlyEntriesPastTheFrontierScan() {
        let transcript = MinimalTranscript()
        transcript.push(assistant("committed already"))
        commitLeadingRun(transcript.state, turnRunning: false) { _, _ in true }

        transcript.push(assistant("streaming answer"), running: true)
        let width = 60
        let expected = MinimalCommitRender.committedLines(
            item: assistant("streaming answer"),
            displayMode: .expanded,
            width: width,
            theme: theme
        ).height + Int(minimalBlockGap)
        #expect(
            MinimalLiveRender.tailHeight(transcript, turnRunning: true, width: width, theme: theme)
                == expected,
            "only the uncommitted running entry is tail"
        )

        // A pending tool holds the frontier — and the tool's arrival RELEASES
        // the running agent message above it (the tracker provably moved
        // past it), so the tail becomes exactly the held tool: its diff
        // preview is what the permission modal needs visible
        // (overlay.rs:284-293).
        let toolItem = PagerConversationItem.tool(PagerToolCard(
            name: "Edit", kind: .edit, input: "a.rs",
            output: "-let x = 1\n+let x = 2\n context line", state: .running
        ))
        let tool = transcript.push(toolItem, running: true)
        transcript.state.setPendingUserInput(tool, pending: true)
        #expect(
            scanFrontier(transcript.state, turnRunning: true).tailStart
                == transcript.state.indexOfID(tool),
            "the released agent message leaves the tail; the held tool starts it"
        )
        let toolHeight = MinimalCommitRender.committedLines(
            item: toolItem, displayMode: .expanded, width: width, theme: theme
        ).height + Int(minimalBlockGap)
        #expect(toolHeight > 1, "the diff preview gives the held tool real height")
        #expect(
            MinimalLiveRender.tailHeight(transcript, turnRunning: true, width: width, theme: theme)
                == toolHeight,
            "the tail is exactly the held tool"
        )
    }

    // The port's analog of upstream's
    // `the_animation_tick_never_changes_a_blocks_height` (live.rs:819-856):
    // the tail measures and draws through the ONE committed constructor, so
    // what tailHeight reports is exactly what drawTail paints.
    @Test("measure and draw agree row for row")
    func measureAndDrawAgreeRowForRow() {
        let transcript = MinimalTranscript()
        transcript.push(.message(PagerMessage(role: .user, text: "do the thing")))
        transcript.push(assistant("first answer line\nsecond answer line"), running: true)
        let width = 40
        let height = MinimalLiveRender.tailHeight(
            transcript, turnRunning: true, width: width, theme: theme
        )
        #expect(height > 0)

        let area = TerminalRect(x: 0, y: 0, width: width, height: height + 5)
        var buffer = CellBuffer.empty(area)
        MinimalLiveRender.drawTail(
            transcript, turnRunning: true, area: area, theme: theme, into: &buffer
        )
        var painted = 0
        for y in 0..<area.height {
            let text = (0..<width)
                .compactMap { buffer.cell(x: $0, y: y)?.grapheme }
                .joined()
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                painted = y + 1
            }
        }
        #expect(painted == height, "tailHeight promised \(height) rows, drawTail painted \(painted)")
    }

    // draw_tail's bottom anchor (live.rs:414-417): when the run is taller
    // than the area, the most recent output is visible and the topmost
    // entry is clipped from the TOP.
    @Test("a tall tail bottom-anchors and clips the top")
    func aTallTailBottomAnchorsAndClipsTheTop() {
        let transcript = MinimalTranscript()
        let body = (0..<12).map { "tail row \($0)" }.joined(separator: "\n")
        transcript.push(assistant(body), running: true)
        let width = 40
        let area = TerminalRect(x: 0, y: 0, width: width, height: 4)
        var buffer = CellBuffer.empty(area)
        MinimalLiveRender.drawTail(
            transcript, turnRunning: true, area: area, theme: theme, into: &buffer
        )
        let rows = (0..<area.height).map { y in
            (0..<width).compactMap { buffer.cell(x: $0, y: y)?.grapheme }.joined()
        }
        #expect(rows[3].contains("tail row 11"), "the last output row is visible: \(rows)")
        #expect(rows[0].contains("tail row 8"), "the top is clipped mid-run: \(rows)")
        #expect(!rows.joined().contains("tail row 0"), "early rows are clipped away")
    }

    @Test("will commit mirrors the frontier and honors the hold")
    func willCommitMirrorsTheFrontierAndHonorsTheHold() {
        let transcript = MinimalTranscript()
        transcript.push(assistant("finalized"))
        #expect(MinimalLiveRender.willCommit(transcript, turnRunning: false, holdCommits: false))
        // The app-modal hold (overlay.rs:206-208): an insert underneath a
        // centered popup would scroll it.
        #expect(!MinimalLiveRender.willCommit(transcript, turnRunning: false, holdCommits: true))
        commitLeadingRun(transcript.state, turnRunning: false) { _, _ in true }
        #expect(!MinimalLiveRender.willCommit(transcript, turnRunning: false, holdCommits: false))
    }
}

@Suite("Minimal viewport sizing")
struct MinimalViewportSizingTests {
    private func inlineTerminal(
        screen: TerminalSize,
        viewportHeight: Int,
        viewportY: Int
    ) throws -> (Terminal, RecordingBackend) {
        let backend = RecordingBackend(size: screen)
        let terminal = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .inline(height: viewportHeight))
        )
        terminal.setViewportArea(TerminalRect(
            x: 0, y: viewportY, width: screen.width, height: viewportHeight
        ))
        return (terminal, backend)
    }

    @Test("steady state is a no-op")
    func steadyStateIsANoOp() throws {
        let (terminal, backend) = try inlineTerminal(
            screen: TerminalSize(width: 60, height: 20), viewportHeight: 5, viewportY: 10
        )
        let before = terminal.viewportArea
        MinimalLiveRender.syncViewport(terminal: terminal, target: 5, willCommit: true)
        MinimalLiveRender.syncViewport(terminal: terminal, target: 5, willCommit: false)
        #expect(terminal.viewportArea == before)
        #expect(backend.appendedLines == 0)
    }

    // The commit-frame path (overlay.rs:167-182): pre-set the HEIGHT only,
    // keep the top, and do NOT scroll — insertBefore is about to do its own
    // clear/scroll/reposition and the resize must not duplicate it.
    @Test("a pre-commit resize keeps the top and never scrolls")
    func aPreCommitResizeKeepsTheTopAndNeverScrolls() throws {
        // Viewport at the screen bottom: a bottom-pinned grow would HAVE to
        // scroll, which is exactly what this path must not do.
        let (terminal, backend) = try inlineTerminal(
            screen: TerminalSize(width: 60, height: 20), viewportHeight: 4, viewportY: 16
        )
        MinimalLiveRender.syncViewport(terminal: terminal, target: 7, willCommit: true)
        #expect(terminal.viewportArea.height == 7)
        #expect(terminal.viewportArea.top == 16, "the top must not move before the commit")
        #expect(backend.appendedLines == 0, "insertBefore owns the scroll, not the resize")
    }

    // The no-commit path delegates to setViewportHeight (top-fixed grow
    // into empty space; scrolls only on bottom overflow — behavior pinned
    // by the B2-N TerminalCore suite; here the dispatch is what's asserted).
    @Test("an overlay resize grows downward and scrolls only on overflow")
    func anOverlayResizeGrowsDownwardAndScrollsOnlyOnOverflow() throws {
        let (terminal, backend) = try inlineTerminal(
            screen: TerminalSize(width: 60, height: 20), viewportHeight: 4, viewportY: 10
        )
        // Room below: grows in place, no scroll.
        MinimalLiveRender.syncViewport(terminal: terminal, target: 6, willCommit: false)
        #expect(terminal.viewportArea.height == 6)
        #expect(terminal.viewportArea.top == 10)
        #expect(backend.appendedLines == 0)

        // Growth past the screen bottom: committed rows scroll up to make room.
        MinimalLiveRender.syncViewport(terminal: terminal, target: 14, willCommit: false)
        #expect(terminal.viewportArea.height == 14)
        #expect(backend.appendedLines > 0, "bottom overflow must scroll, preserving history")
    }

    @Test("sizing math matches the upstream tables")
    func sizingMathMatchesTheUpstreamTables() {
        // content_target (overlay.rs:343-358): content + status row, floored
        // at 2 (status + prompt), capped at the ceiling.
        #expect(MinimalLiveRender.contentTarget(
            tailHeight: 0, todosHeight: 0, btwHeight: 0, overlayHeight: 1, promptHeight: 1, ceiling: 19
        ) == 3, "idle: status + info + prompt")
        #expect(MinimalLiveRender.contentTarget(
            tailHeight: 8, todosHeight: 2, btwHeight: 0, overlayHeight: 1, promptHeight: 2, ceiling: 19
        ) == 14)
        #expect(MinimalLiveRender.contentTarget(
            tailHeight: 40, todosHeight: 0, btwHeight: 0, overlayHeight: 1, promptHeight: 1, ceiling: 19
        ) == 19, "capped at the ceiling; drawTail clips the overflow")
        #expect(MinimalLiveRender.contentTarget(
            tailHeight: 0, todosHeight: 0, btwHeight: 0, overlayHeight: 0, promptHeight: 0, ceiling: 19
        ) == 2, "floor: status + prompt")

        // modal_target (overlay.rs:125-132): tail + modal + status row,
        // floored at base and 3, capped at the ceiling.
        #expect(MinimalLiveRender.modalTarget(tailHeight: 5, modalHeight: 6, base: 3, ceiling: 19) == 12)
        #expect(MinimalLiveRender.modalTarget(tailHeight: 0, modalHeight: 1, base: 3, ceiling: 19) == 3)
        #expect(MinimalLiveRender.modalTarget(tailHeight: 30, modalHeight: 6, base: 3, ceiling: 19) == 19)

        // app_modal_target (overlay.rs:105-112): 18 rows, clamped.
        #expect(MinimalLiveRender.appModalTarget(base: 3, ceiling: 40) == 18)
        #expect(MinimalLiveRender.appModalTarget(base: 20, ceiling: 40) == 20)
        #expect(MinimalLiveRender.appModalTarget(base: 3, ceiling: 12) == 12)
    }
}
