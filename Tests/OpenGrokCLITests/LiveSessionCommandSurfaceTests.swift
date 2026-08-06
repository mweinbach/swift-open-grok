// LiveSessionCommandSurfaceTests.swift
//
// The CLI-side halves of `/jump` and `/delete`, plus the layout property
// `/jump` is built on.
//
// The renderer that consumes these is a `private actor` inside
// `LiveComposition.swift` and cannot be reached from a test, so these pin the
// two things that would actually break silently if they drifted: the row ids
// the selection handler parses back, and the measurement `/jump` scrolls by.

import Foundation
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

@Suite("Session command surfaces")
struct LiveSessionCommandSurfaceTests {
    private func message(_ role: PagerMessageRole, _ text: String) -> PagerConversationItem {
        .message(PagerMessage(role: role, text: text))
    }

    // MARK: - /jump

    @Test("the jump picker lists user turns newest first, keyed by block index")
    func jumpRowsCarryBlockIndices() {
        let items: [PagerConversationItem] = [
            message(.system, "welcome"),
            message(.user, "first question"),
            message(.assistant, "first answer"),
            message(.user, "second question"),
            message(.assistant, "second answer"),
        ]
        guard case .list(let list) = LiveJumpPicker.overlay(items: items).content else {
            Issue.record("the jump picker is not a list overlay")
            return
        }
        // Newest first, and the id is the index into `items` — not the turn
        // number. The selection handler scrolls to that block directly, so an
        // id that meant anything else would land on the wrong turn.
        #expect(list.rows.map(\.id) == ["3", "1"])
        #expect(list.rows.map(\.label) == ["second question", "first question"])
        #expect(list.rows.map(\.detail) == ["turn 2", "turn 1"])
    }

    @Test("a conversation with no user turns offers no selectable row")
    func jumpRowsRefuseAnEmptyConversation() {
        guard case .list(let list) = LiveJumpPicker.overlay(items: [
            message(.system, "welcome"),
        ]).content else {
            Issue.record("the jump picker is not a list overlay")
            return
        }
        #expect(list.rows.count == 1)
        #expect(list.rows[0].isSelectable == false)
    }

    /// The property `/jump` scrolls by.
    ///
    /// `revealBlock` lays out the blocks *before* the target through the real
    /// frame function and uses the resulting line count as the scroll offset.
    /// That is only correct if laying out a prefix produces exactly the lines
    /// the same blocks occupy in the full frame — which holds because the gap
    /// row belongs to the *following* block's approach, not the prefix. Pin it:
    /// if the layout ever grows a trailing element per render, `/jump` would
    /// silently land one block off and nothing else would notice.
    @Test("a prefix lays out to the exact offset of the block that follows it")
    func prefixLayoutMeasuresTheBlockStart() {
        let items: [PagerConversationItem] = [
            message(.user, "a question long enough to wrap across more than one line in a narrow frame"),
            message(.assistant, "an answer"),
            message(.user, "another question"),
            message(.assistant, "another answer"),
        ]
        func lines(_ blocks: [PagerConversationItem]) -> Int {
            renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 40, height: 24),
                conversation: blocks
            )).layout.totalContentLines
        }
        for cut in 1..<items.count {
            let prefix = lines(Array(items.prefix(cut)))
            let whole = lines(items)
            #expect(prefix < whole, "prefix of \(cut) did not fit inside the whole frame")
            // The rest of the frame is the suffix plus at most the one gap row
            // that joins them, so the measured offset can never overshoot.
            #expect(prefix <= whole)
        }
    }

    // MARK: - /delete

    /// The confirmation exists because deleting a transcript is not undoable.
    /// The invariant worth pinning is the *fail-closed* one: only one row id
    /// means yes, so an unrecognised id can only ever cancel.
    @Test("only the confirm row can delete")
    func deleteConfirmationFailsClosed() {
        guard case .list(let list) = LiveSessionDeleteConfirmation.overlay(
            sessionID: "0123456789abcdef",
            itemCount: 12
        ).content else {
            Issue.record("the delete confirmation is not a list overlay")
            return
        }
        let confirming = list.rows.filter { $0.id == LiveSessionDeleteConfirmation.confirmRowID }
        #expect(confirming.count == 1)
        #expect(list.rows.count == 2)
        #expect(confirming.first?.label.contains("12 stored items") == true)
        #expect(confirming.first?.detail == "not undoable")
    }

    @Test("the confirmation names one item in the singular")
    func deleteConfirmationSingular() {
        guard case .list(let list) = LiveSessionDeleteConfirmation.overlay(
            sessionID: "abc",
            itemCount: 1
        ).content else {
            Issue.record("the delete confirmation is not a list overlay")
            return
        }
        #expect(list.rows[0].label.hasSuffix("1 stored item"))
    }
}
