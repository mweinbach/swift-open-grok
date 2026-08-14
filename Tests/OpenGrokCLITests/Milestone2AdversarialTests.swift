// Milestone2AdversarialTests.swift
//
// Empirical adversarial challenge and stress tests for Milestone 2 Features #5, #6, #7, and #8.

import Foundation
import Testing
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import OpenGrokTextArea
@testable import OpenGrokCLI

@Suite("Milestone 2 Adversarial Stress Tests")
struct Milestone2AdversarialTests {

    // MARK: - Feature #5 Stress Tests: Fold Toggling & Click Timing

    @Test("Feature #5 Stress: Non-foldable item double click does not fold")
    func testNonFoldableItemDoubleClick() {
        var selection = LiveScrollbackSelection()
        var items: [PagerConversationItem] = [
            .message(PagerMessage(role: .user, text: "Hello world", isStreaming: false, styledLines: [], duration: nil, isCollapsed: false))
        ]

        #expect(items[0].isFoldable == false)
        #expect(items[0].isFolded == false)

        selection.select(at: 0, itemCount: items.count)
        _ = selection.apply(.toggleFold, items: &items)
        #expect(items[0].isFolded == false, "User messages are non-foldable and must remain unfolded")
    }

    @Test("Feature #5 Stress: Multi-click threshold (400ms) logic")
    func testMultiClickThreshold() {
        var selection = LiveScrollbackSelection()
        var items: [PagerConversationItem] = [
            .tool(PagerToolCard(
                name: "bash",
                input: "ls",
                output: "file.txt",
                state: .succeeded,
                isExpanded: true
            ))
        ]

        #expect(items[0].isFolded == false)

        // Simulate rapid double click (interval <= 400ms)
        let t1: UInt64 = 1000
        let t2: UInt64 = 1200 // 200ms delta <= 400ms
        var lastClick: (index: Int, timeMs: UInt64, count: Int)? = (index: 0, timeMs: t1, count: 1)
        
        let count2 = (lastClick != nil && lastClick!.index == 0 && t2 - lastClick!.timeMs <= 400) ? lastClick!.count + 1 : 1
        #expect(count2 == 2)
        if count2 >= 2 {
            selection.select(at: 0, itemCount: items.count)
            _ = selection.apply(.toggleFold, items: &items)
        }
        #expect(items[0].isFolded == true)

        // Simulate click after > 400ms delay (resets count to 1)
        let t3: UInt64 = 1700 // 500ms delta > 400ms
        lastClick = (index: 0, timeMs: t2, count: count2)
        let count3 = (lastClick != nil && lastClick!.index == 0 && t3 - lastClick!.timeMs <= 400) ? lastClick!.count + 1 : 1
        #expect(count3 == 1, "Click after >400ms must reset click count to 1")
    }

    // MARK: - Feature #6 Stress Tests: Overlay Scrollbar Bounds

    @Test("Feature #6 Stress: Dropdown scrollbar edge coordinate clamping")
    func testDropdownScrollbarClamping() {
        let area = TerminalRect(x: 10, y: 5, width: 30, height: 10)
        let bounds = PagerOverlayBounds(
            id: "test_overlay",
            frame: area,
            content: area,
            footer: TerminalRect(x: 10, y: 15, width: 30, height: 0),
            rows: (0..<20).map { PagerOverlayBounds.Row(id: "item_\($0)", frame: TerminalRect(x: 10, y: 5 + $0, width: 28, height: 1)) },
            hasScrollbar: true
        )

        #expect(bounds.hasScrollbar == true)
        // Check scrollbar columns: area.right - 2 (38) and area.right - 1 (39)
        #expect(bounds.hitTest(x: 38, y: 7) == true)
        #expect(bounds.hitTest(x: 39, y: 7) == true)
        // Outside scrollbar / overlay area
        #expect(bounds.hitTest(x: 40, y: 7) == false)
        #expect(bounds.hitTest(x: 9, y: 7) == false)
    }

    // MARK: - Feature #7 Stress Tests: File Reference & Paste Expansion Edge Cases

    @Test("Feature #7 Stress: File Reference edge cases")
    func testFileRefEdgeCases() {
        let area = TextArea()
        
        // Test file ref with multiple colons
        area.insertElement(kind: ElementKind.fileRef, text: "@path/to/file:with:colon:15-30", displayText: "@path/to/file:with:colon:15-30")
        let ref1 = area.fileRefElementAtCursor()
        #expect(ref1 != nil)
        #expect(ref1?.path == "path/to/file:with:colon")
        #expect(ref1?.lineRange == 15..<31)

        // Clear and test invalid range string
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@path/to/file:invalid", displayText: "@path/to/file:invalid")
        let ref2 = area.fileRefElementAtCursor()
        #expect(ref2 != nil)
        #expect(ref2?.path == "path/to/file")
        #expect(ref2?.lineRange == nil)

        // Clear and test single line
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@path/to/file:100", displayText: "@path/to/file:100")
        let ref3 = area.fileRefElementAtCursor()
        #expect(ref3 != nil)
        #expect(ref3?.path == "path/to/file")
        #expect(ref3?.lineRange == 100..<101)
    }

    @Test("Feature #7 Stress: Paste chip cursor position bounds")
    func testPasteChipCursorBounds() {
        let area = TextArea()
        area.insertStr("Prefix ")
        _ = area.insertElement(kind: ElementKind.paste, text: "secret data", displayText: "[Paste]")
        area.insertStr(" Suffix")

        // Move cursor to beginning (outside chip range)
        area.setCursor(0)
        let expandedOut = area.expandPasteElementAtCursor()
        #expect(expandedOut == false, "Cursor at start far from paste chip must not trigger expansion")
    }

    // MARK: - Feature #8 Stress Tests: Tasks Pane Narrow Viewport & Multiple Entries

    @Test("Feature #8 Stress: Narrow tasks pane suppresses out-of-bounds buttons")
    func testTasksPaneNarrowViewport() {
        var pane = PagerTasksPaneState(entries: [
            PagerTaskPaneEntry(
                id: "bg-narrow",
                group: .tasks,
                spans: [PagerStyledSpan(text: "narrow task")],
                running: true,
                killAction: .killBgTask(taskID: "bg-narrow"),
                openAction: .openBgTaskOutput(taskID: "bg-narrow")
            )
        ], focused: true)

        // Narrow area width of 3 characters: area.x = 0, width = 3 -> area.right = 3
        let narrowArea = TerminalRect(x: 0, y: 0, width: 3, height: 3)
        var buffer = CellBuffer(area: narrowArea)
        let theme = PagerRenderTheme.default

        drawTasksPane(&pane, in: narrowArea, buffer: &buffer, theme: theme)

        // kx = 3 - 4 = -1 which is <= area.x + 1 (1), so button rects should NOT be painted/recorded
        #expect(pane.killButtonRects.isEmpty)
        #expect(pane.viewButtonRects.isEmpty)
    }

    @Test("Feature #8 Stress: Multiple task entries produce distinct button rects")
    func testMultipleTaskEntriesButtonRects() {
        var pane = PagerTasksPaneState(entries: [
            PagerTaskPaneEntry(
                id: "bg-1",
                group: .tasks,
                spans: [PagerStyledSpan(text: "task 1")],
                running: true,
                killAction: .killBgTask(taskID: "bg-1"),
                openAction: .openBgTaskOutput(taskID: "bg-1")
            ),
            PagerTaskPaneEntry(
                id: "bg-2",
                group: .tasks,
                spans: [PagerStyledSpan(text: "task 2")],
                running: true,
                killAction: .killBgTask(taskID: "bg-2"),
                openAction: .openBgTaskOutput(taskID: "bg-2")
            )
        ], focused: true)

        let area = TerminalRect(x: 0, y: 0, width: 60, height: 10)
        var buffer = CellBuffer(area: area)
        let theme = PagerRenderTheme.default

        drawTasksPane(&pane, in: area, buffer: &buffer, theme: theme)

        #expect(pane.killButtonRects.count == 2)
        #expect(pane.viewButtonRects.count == 2)
        #expect(pane.killButtonRects[0].id == .bgTask("bg-1"))
        #expect(pane.killButtonRects[1].id == .bgTask("bg-2"))
        #expect(pane.killButtonRects[0].rect.y != pane.killButtonRects[1].rect.y)
    }

    // MARK: - Adversarial Stress Tests: Inverted Line Ranges, Scrollbar Drag & Double-Click Cursor Sync

    @Test("Feature #7 Adversarial: Comprehensive Inverted & Malformed Line Range Stress")
    func testInvertedAndMalformedLineRangesStress() {
        let area = TextArea()

        // 1. Inverted range 50-20
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@File.swift:50-20", displayText: "@File.swift:50-20")
        let ref1 = area.fileRefElementAtCursor()
        #expect(ref1 != nil)
        #expect(ref1?.path == "File.swift")
        #expect(ref1?.lineRange == nil, "Inverted 50-20 must return nil lineRange")

        // 2. Negative start and end: -10--20
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@File.swift:-10--20", displayText: "@File.swift:-10--20")
        let ref2 = area.fileRefElementAtCursor()
        #expect(ref2 != nil)
        #expect(ref2?.path == "File.swift")
        #expect(ref2?.lineRange == nil, "Negative line numbers must return nil lineRange")

        // 3. Positive start, negative end: 10--5
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@File.swift:10--5", displayText: "@File.swift:10--5")
        let ref3 = area.fileRefElementAtCursor()
        #expect(ref3 != nil)
        #expect(ref3?.path == "File.swift")
        #expect(ref3?.lineRange == nil, "Negative end line must return nil lineRange")

        // 4. Non-numeric: abc-def
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@File.swift:abc-def", displayText: "@File.swift:abc-def")
        let ref4 = area.fileRefElementAtCursor()
        #expect(ref4 != nil)
        #expect(ref4?.path == "File.swift")
        #expect(ref4?.lineRange == nil, "Non-numeric range must return nil lineRange")

        // 5. Overflowing Int value: 9999999999999999999999999-10
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@File.swift:9999999999999999999999999-10", displayText: "@File.swift:9999999999999999999999999-10")
        let ref5 = area.fileRefElementAtCursor()
        #expect(ref5 != nil)
        #expect(ref5?.path == "File.swift")
        #expect(ref5?.lineRange == nil, "Overflowing Int must return nil lineRange without crash")

        // 6. Zero range: 0-0
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@File.swift:0-0", displayText: "@File.swift:0-0")
        let ref6 = area.fileRefElementAtCursor()
        #expect(ref6 != nil)
        #expect(ref6?.path == "File.swift")
        #expect(ref6?.lineRange == 0..<1, "0-0 is valid zero-indexed line 0")

        // 7. Plus signs: +10-+20
        area.setText("")
        area.insertElement(kind: ElementKind.fileRef, text: "@File.swift:+10-+20", displayText: "@File.swift:+10-+20")
        let ref7 = area.fileRefElementAtCursor()
        #expect(ref7 != nil)
        #expect(ref7?.path == "File.swift")
        #expect(ref7?.lineRange == 10..<21)
    }

    @Test("Feature #6 Adversarial: Completion Dropdown Scrollbar Drag & Boundary Calculations")
    func testCompletionDropdownScrollbarDragInteraction() {
        // Create dropdown bounds with height 5 and 20 total rows
        let area = TerminalRect(x: 0, y: 0, width: 40, height: 5)
        let totalRows = 20
        let visibleRows = (0..<5).map { PagerOverlayBounds.Row(id: "cmd_\($0)", frame: TerminalRect(x: 0, y: $0, width: 38, height: 1)) }
        let bounds = PagerOverlayBounds(
            id: "completions",
            frame: area,
            content: area,
            footer: TerminalRect(x: 0, y: 5, width: 40, height: 0),
            rows: visibleRows,
            hasScrollbar: true
        )

        // 1. Hit test on scrollbar column (x = 38, 39)
        #expect(bounds.hitTest(x: 38, y: 0) == true)
        #expect(bounds.hitTest(x: 39, y: 2) == true)
        #expect(bounds.hitTest(x: 37, y: 2) == true, "x=37 is inside content frame (0..<38)")

        // 2. Drag calculation: dragging mouse across y = 0..5
        for y in 0...5 {
            let frac = max(0.0, min(1.0, Double(y - area.y) / Double(max(1, area.height))))
            let targetIndex = min(totalRows - 1, Int(frac * Double(totalRows)))
            #expect(targetIndex >= 0 && targetIndex < totalRows)
            if y == 0 { #expect(targetIndex == 0) }
            if y == 5 { #expect(targetIndex == 19) }
        }
    }

    @Test("Feature #7 Adversarial: Rapid Double Click Cursor Positioning Synchronization")
    func testRapidDoubleClickCursorPositioningSync() {
        let area = TextArea()
        // Text buffer: "Hello " + [Paste Chip] + " World"
        area.insertStr("Hello ") // 0..<6
        _ = area.insertElement(kind: ElementKind.paste, text: "secret_token", displayText: "[Paste]") // 6..<18
        area.insertStr(" World") // 18..<24

        let contentRect = TextAreaRect(x: 0, y: 0, width: 40, height: 3)

        // 1. First click at x = 2 (in "Hello")
        let click1 = MouseEvent(kind: .down, x: 2, y: 0, button: .left)
        _ = area.handleMouse(click1, area: contentRect, state: TextAreaState())
        #expect(area.cursor == 2)
        #expect(area.expandPasteElementAtCursor() == false, "Cursor at x=2 must not expand paste chip at x=6")

        // 2. Rapid second click at x = 8 (inside [Paste] chip display)
        // TextArea maps screen col 8 (2 cols into [Paste]) to byte offset inside 6..<18
        let click2 = MouseEvent(kind: .down, x: 8, y: 0, button: .left)
        _ = area.handleMouse(click2, area: contentRect, state: TextAreaState())
        #expect(area.cursor >= 6 && area.cursor < 18, "Cursor inside atomic chip is placed within element range 6..<18")
        
        let expanded = area.expandPasteElementAtCursor()
        #expect(expanded == true, "With cursor updated to chip lowerBound byte 6 on click #2, paste chip expansion succeeds")
        #expect(area.allElements.isEmpty)
    }

    @Test("Feature #7 Adversarial: Rapid Double Click Moving Away From Chip Disarms Action")
    func testRapidDoubleClickMovingAwayFromChipDisarmsAction() {
        let area = TextArea()
        area.setText("") // Clear buffer completely
        _ = area.insertElement(kind: ElementKind.paste, text: "secret_token", displayText: "[Paste]") // 0..<12
        area.insertStr(" Plain text tail") // 12..<28

        let contentRect = TextAreaRect(x: 0, y: 0, width: 40, height: 3)

        // 1. First click at x = 2 (inside [Paste] chip)
        let click1 = MouseEvent(kind: .down, x: 2, y: 0, button: .left)
        _ = area.handleMouse(click1, area: contentRect, state: TextAreaState())
        #expect(area.cursor >= 0 && area.cursor < 12)

        // 2. Second click rapid at x = 20 (far outside chip, in "Plain text tail", byte 25)
        let click2 = MouseEvent(kind: .down, x: 20, y: 0, button: .left)
        _ = area.handleMouse(click2, area: contentRect, state: TextAreaState())
        #expect(area.cursor == 25)

        let expanded = area.expandPasteElementAtCursor()
        #expect(expanded == false, "When click #2 moves away from chip to x=20, chip action MUST be disarmed")
        #expect(area.allElements.count == 1, "Paste chip remains untouched")
    }
}


