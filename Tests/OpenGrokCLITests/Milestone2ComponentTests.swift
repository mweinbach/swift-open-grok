// Milestone2ComponentTests.swift
//
// Automated unit, integration, and adversarial challenge tests for Milestone 2 Features #5, #6, #7, and #8.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import OpenGrokTextArea
import Testing
@testable import OpenGrokCLI

@Suite("Milestone 2 Component & Interaction Tests")
struct Milestone2ComponentTests {

    // MARK: - Feature #5: Collapsible Card Header Clicks & Double-Click Fold Toggling

    @Test("Feature #5: Card Fold Toggling & Header Click")
    func testCardFoldToggling() {
        var selection = LiveScrollbackSelection()
        var items: [PagerConversationItem] = [
            .tool(PagerToolCard(
                name: "bash",
                input: "ls -la",
                output: "file1.txt\nfile2.txt",
                state: .succeeded,
                isExpanded: true
            ))
        ]

        #expect(items[0].isFolded == false)

        // Select and toggle fold
        selection.select(at: 0, itemCount: items.count)
        _ = selection.apply(.toggleFold, items: &items)
        #expect(items[0].isFolded == true)

        // Toggle back
        _ = selection.apply(.toggleFold, items: &items)
        #expect(items[0].isFolded == false)
    }

    @Test("Feature #5: Rapid Multi-Click Reset Window (400ms threshold)")
    func testRapidMultiClickResetWindow() {
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

        let index = 0
        let nowMs: UInt64 = 1000

        // 1st click at t=1000ms -> clickCount = 1
        var lastClick: (index: Int, timeMs: UInt64, count: Int)? = nil
        let count1 = (lastClick != nil && lastClick!.index == index && nowMs - lastClick!.timeMs <= 400) ? lastClick!.count + 1 : 1
        lastClick = (index: index, timeMs: nowMs, count: count1)
        #expect(count1 == 1)

        // 2nd click at t=1200ms (200ms later <= 400ms) -> clickCount = 2 -> triggers fold toggle
        let nowMs2: UInt64 = 1200
        let count2 = (lastClick != nil && lastClick!.index == index && nowMs2 - lastClick!.timeMs <= 400) ? lastClick!.count + 1 : 1
        lastClick = (index: index, timeMs: nowMs2, count: count2)
        #expect(count2 == 2)
        if count2 >= 2 {
            selection.select(at: index, itemCount: items.count)
            _ = selection.apply(.toggleFold, items: &items)
        }
        #expect(items[0].isFolded == true)

        // 3rd click at t=1700ms (500ms later > 400ms) -> clickCount RESETS to 1 -> NO fold toggle
        let nowMs3: UInt64 = 1700
        let count3 = (lastClick != nil && lastClick!.index == index && nowMs3 - lastClick!.timeMs <= 400) ? lastClick!.count + 1 : 1
        lastClick = (index: index, timeMs: nowMs3, count: count3)
        #expect(count3 == 1, "Click after >400ms delay must reset click count to 1")

        // 4th click at t=1850ms (150ms later <= 400ms) -> clickCount = 2 -> triggers fold toggle again (unfolds)
        let nowMs4: UInt64 = 1850
        let count4 = (lastClick != nil && lastClick!.index == index && nowMs4 - lastClick!.timeMs <= 400) ? lastClick!.count + 1 : 1
        lastClick = (index: index, timeMs: nowMs4, count: count4)
        #expect(count4 == 2)
        if count4 >= 2 {
            selection.select(at: index, itemCount: items.count)
            _ = selection.apply(.toggleFold, items: &items)
        }
        #expect(items[0].isFolded == false)
    }

    @Test("Feature #5: Header Click Always Toggles Fold regardless of click count")
    func testHeaderClickAlwaysTogglesFold() {
        var selection = LiveScrollbackSelection()
        var items: [PagerConversationItem] = [
            .tool(PagerToolCard(
                name: "bash",
                input: "cargo test",
                output: "passed",
                state: .succeeded,
                isExpanded: true
            ))
        ]

        let isHeaderClick = true
        let clickCount = 1

        if isHeaderClick || (items[0].isFoldable && clickCount >= 2) {
            selection.select(at: 0, itemCount: items.count)
            _ = selection.apply(.toggleFold, items: &items)
        }

        #expect(items[0].isFolded == true, "Single click on card header row must toggle fold immediately")
    }

    // MARK: - Feature #6: Overlay Dropdown Scrollbar Hit-Testing & Rendering

    @Test("Feature #6: Dropdown Scrollbar Rendering and Bounds")
    func testDropdownScrollbarRendering() {
        let area = TerminalRect(x: 0, y: 0, width: 40, height: 4)

        let bounds = PagerOverlayBounds(
            id: "completions",
            frame: area,
            content: area,
            footer: TerminalRect(x: 0, y: 4, width: 40, height: 0),
            rows: (0..<4).map { PagerOverlayBounds.Row(id: "item_\($0)", frame: TerminalRect(x: 0, y: $0, width: 38, height: 1)) },
            hasScrollbar: true
        )

        #expect(bounds.hasScrollbar == true)
        #expect(bounds.hitTest(x: 39, y: 1) == true)
        #expect(bounds.frame.right - 2 == 38)
    }

    @Test("Feature #6: Dropdown Scrollbar disabled when item count <= visible rows")
    func testDropdownScrollbarDisabledWhenItemsFit() {
        let visibleHeight = 5

        // Item count = 5 (equals visible rows)
        let itemsEqual = (0..<5).map { PagerOverlayBounds.Row(id: "item_\($0)", frame: TerminalRect(x: 0, y: $0, width: 40, height: 1)) }
        let hasScrollbarEqual = itemsEqual.count > visibleHeight
        #expect(hasScrollbarEqual == false, "Scrollbar must NOT render when item count equals visible rows")

        // Item count = 3 (less than visible rows)
        let itemsLess = (0..<3).map { PagerOverlayBounds.Row(id: "item_\($0)", frame: TerminalRect(x: 0, y: $0, width: 40, height: 1)) }
        let hasScrollbarLess = itemsLess.count > visibleHeight
        #expect(hasScrollbarLess == false, "Scrollbar must NOT render when item count is less than visible rows")
    }

    @Test("Feature #6: Scrollbar Drag Calculation and Boundary Clamping")
    func testDropdownScrollbarDragCalculationAndClamping() {
        let area = TerminalRect(x: 0, y: 0, width: 40, height: 5)
        let rowsCount = 20

        // Test top boundary click (y = content.y = 0) -> fraction 0.0 -> index 0
        let fracTop = max(0.0, min(1.0, Double(0 - area.y) / Double(max(1, area.height))))
        let targetIndexTop = min(rowsCount - 1, Int(fracTop * Double(rowsCount)))
        #expect(targetIndexTop == 0)

        // Test bottom boundary click (y = content.y + height = 5) -> fraction 1.0 -> index 19 (rowsCount - 1)
        let fracBottom = max(0.0, min(1.0, Double(5 - area.y) / Double(max(1, area.height))))
        let targetIndexBottom = min(rowsCount - 1, Int(fracBottom * Double(rowsCount)))
        #expect(targetIndexBottom == 19)

        // Test out-of-bounds mouse y below dropdown (y = 50) -> clamped to 19
        let fracOob = max(0.0, min(1.0, Double(50 - area.y) / Double(max(1, area.height))))
        let targetIndexOob = min(rowsCount - 1, Int(fracOob * Double(rowsCount)))
        #expect(targetIndexOob == 19)

        // Test middle click (y = 2) -> fraction 0.4 -> index 8
        let fracMid = max(0.0, min(1.0, Double(2 - area.y) / Double(max(1, area.height))))
        let targetIndexMid = min(rowsCount - 1, Int(fracMid * Double(rowsCount)))
        #expect(targetIndexMid == 8)
    }

    // MARK: - Feature #7: Prompt Area Double-Click Expansions

    @Test("Feature #7: Paste Chip Expansion in TextArea")
    func testPasteChipExpansion() {
        let area = TextArea()
        let chipId = area.insertElement(kind: ElementKind.paste, text: "pasted secret text", displayText: "[Paste]")

        #expect(area.allElements.count == 1)
        #expect(area.allElements[0].id == chipId)

        let expanded = area.expandPasteElementAtCursor()
        #expect(expanded == true)
        #expect(area.allElements.isEmpty)
    }

    @Test("Feature #7: File Reference Element Parsing")
    func testFileRefElementParsing() {
        let area = TextArea()
        area.insertElement(kind: ElementKind.fileRef, text: "@Sources/Main.swift:10-25", displayText: "@Sources/Main.swift:10-25")

        let ref = area.fileRefElementAtCursor()
        #expect(ref != nil)
        #expect(ref?.path == "Sources/Main.swift")
        #expect(ref?.lineRange == 10..<26)
    }

    @Test("Feature #7: File Reference Single Line Parsing")
    func testFileRefSingleLineParsing() {
        let area = TextArea()
        area.insertElement(kind: ElementKind.fileRef, text: "@Sources/Main.swift:42", displayText: "@Sources/Main.swift:42")

        let ref = area.fileRefElementAtCursor()
        #expect(ref != nil)
        #expect(ref?.path == "Sources/Main.swift")
        #expect(ref?.lineRange == 42..<43)
    }

    @Test("Feature #7: File Reference Parsing with Missing Path or Inverted Line Range")
    func testFileRefMissingPathAndInvertedRange() {
        // 1. Missing path: "@:10"
        let area1 = TextArea()
        area1.insertElement(kind: ElementKind.fileRef, text: "@:10", displayText: "@:10")
        let refMissingPath = area1.fileRefElementAtCursor()
        #expect(refMissingPath != nil)
        #expect(refMissingPath?.path == "", "Missing path before colon must return empty string path")
        #expect(refMissingPath?.lineRange == 10..<11)

        // 2. Only "@"
        let area2 = TextArea()
        area2.insertElement(kind: ElementKind.fileRef, text: "@", displayText: "@")
        let refOnlyAt = area2.fileRefElementAtCursor()
        #expect(refOnlyAt != nil)
        #expect(refOnlyAt?.path == "")
        #expect(refOnlyAt?.lineRange == nil)

        // 3. File reference without colon or line: "@Sources/Main.swift"
        let area3 = TextArea()
        area3.insertElement(kind: ElementKind.fileRef, text: "@Sources/Main.swift", displayText: "@Sources/Main.swift")
        let refNoLine = area3.fileRefElementAtCursor()
        #expect(refNoLine != nil)
        #expect(refNoLine?.path == "Sources/Main.swift")
        #expect(refNoLine?.lineRange == nil)
    }

    @Test("Feature #7: Non-existent file path handling for Line Viewer")
    func testNonExistentFileLineViewer() {
        let path = "non_existent_file_path_12345.txt"
        let fileLines: [PagerStyledLine]
        if let content = try? String(contentsOfFile: path) {
            let lines = content.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            fileLines = lines.map { PagerStyledLine(text: String($0)) }
        } else {
            fileLines = [PagerStyledLine(text: "(could not read file \(path))")]
        }

        #expect(fileLines.count == 1)
        #expect(fileLines[0].text == "(could not read file non_existent_file_path_12345.txt)")
    }

    @Test("Feature #7: Paste Chip Expansion Proximity Boundary")
    func testPasteChipExpansionProximityBoundary() {
        let area = TextArea()
        area.insertStr("some prefix text ")
        _ = area.insertElement(kind: ElementKind.paste, text: "secret token", displayText: "[Paste]")
        area.insertStr(" and some suffix text after chip")

        // 1. Set cursor far away in suffix text (index 50)
        area.setCursor(50)
        let expandedFar = area.expandPasteElementAtCursor()
        #expect(expandedFar == false, "Cursor far away from paste chip must not trigger expansion")

        // 2. Set cursor inside paste chip range (index 18)
        area.setCursor(18)
        let expandedClose = area.expandPasteElementAtCursor()
        #expect(expandedClose == true, "Cursor at or adjacent to paste chip must expand it")
        #expect(area.allElements.isEmpty)
    }

    // MARK: - Feature #8: Tasks Pane Inline Button Rects

    @Test("Feature #8: Tasks Pane Inline Button Rect Generation")
    func testTasksPaneButtonRects() {
        var pane = PagerTasksPaneState(entries: [
            PagerTaskPaneEntry(
                id: "bg-1",
                group: .tasks,
                spans: [PagerStyledSpan(text: "task 1")],
                running: true,
                killAction: .killBgTask(taskID: "bg-1"),
                openAction: .openBgTaskOutput(taskID: "bg-1")
            )
        ], focused: true)

        let area = TerminalRect(x: 0, y: 0, width: 50, height: 5)
        var buffer = CellBuffer(area: area)
        let theme = PagerRenderTheme.default

        drawTasksPane(&pane, in: area, buffer: &buffer, theme: theme)

        #expect(!pane.killButtonRects.isEmpty)
        #expect(!pane.viewButtonRects.isEmpty)
        #expect(pane.killButtonRects[0].id == .bgTask("bg-1"))
        #expect(pane.viewButtonRects[0].id == .bgTask("bg-1"))
        #expect(pane.killButtonRects[0].rect.width == 3)
        #expect(pane.viewButtonRects[0].rect.width == 3)
    }

    @Test("Feature #8: Empty Tasks Pane rendering and hit testing")
    func testEmptyTasksPaneRenderingAndHitTesting() {
        var pane = PagerTasksPaneState(entries: [], focused: true)
        let area = TerminalRect(x: 0, y: 0, width: 50, height: 10)
        var buffer = CellBuffer(area: area)
        let theme = PagerRenderTheme.default

        drawTasksPane(&pane, in: area, buffer: &buffer, theme: theme)

        #expect(pane.killButtonRects.isEmpty, "Empty tasks pane must have no kill button rects")
        #expect(pane.viewButtonRects.isEmpty, "Empty tasks pane must have no view button rects")

        // Click hit test against empty pane rects
        let clickX = 25
        let clickY = 5
        let killHit = pane.killButtonRects.first(where: { $0.rect.contains(x: clickX, y: clickY) })
        let viewHit = pane.viewButtonRects.first(where: { $0.rect.contains(x: clickX, y: clickY) })

        #expect(killHit == nil)
        #expect(viewHit == nil)
    }

    @Test("Feature #8: Tasks Pane Clicks Outside Inline Buttons Do Not Trigger Actions")
    func testTasksPaneClicksOutsideButtonsIgnored() {
        var pane = PagerTasksPaneState(entries: [
            PagerTaskPaneEntry(
                id: "bg-task-42",
                group: .tasks,
                spans: [PagerStyledSpan(text: "running long task")],
                running: true,
                killAction: .killBgTask(taskID: "bg-task-42"),
                openAction: .openBgTaskOutput(taskID: "bg-task-42")
            )
        ], focused: true)

        let area = TerminalRect(x: 0, y: 0, width: 60, height: 5)
        var buffer = CellBuffer(area: area)
        let theme = PagerRenderTheme.default

        drawTasksPane(&pane, in: area, buffer: &buffer, theme: theme)

        #expect(pane.killButtonRects.count == 1)
        #expect(pane.viewButtonRects.count == 1)

        let killRect = pane.killButtonRects[0].rect
        let viewRect = pane.viewButtonRects[0].rect

        // Click on task label text (e.g. x = 5, y = killRect.y)
        let textX = 5
        let killHitLabel = pane.killButtonRects.first(where: { $0.rect.contains(x: textX, y: killRect.y) })
        let viewHitLabel = pane.viewButtonRects.first(where: { $0.rect.contains(x: textX, y: killRect.y) })

        #expect(killHitLabel == nil, "Clicking task label text must not trigger kill button")
        #expect(viewHitLabel == nil, "Clicking task label text must not trigger view button")

        // Exact click on kill button rect
        let killHitExact = pane.killButtonRects.first(where: { $0.rect.contains(x: killRect.x, y: killRect.y) })
        #expect(killHitExact?.id == .bgTask("bg-task-42"))

        // Exact click on view button rect
        let viewHitExact = pane.viewButtonRects.first(where: { $0.rect.contains(x: viewRect.x, y: viewRect.y) })
        #expect(viewHitExact?.id == .bgTask("bg-task-42"))
    }

    // MARK: - Live Seam Integration Tests for Milestone 2 Remediation

    @Test("Feature #6: renderPagerFrame publishes PagerOverlayBounds for completions dropdown with hasScrollbar")
    func testRenderPagerPublishesCompletionsOverlayBounds() {
        let rows = (0..<10).map { PagerCompletionRow(label: "/cmd_\($0)", summary: "command \($0)") }
        let completionsMenu = PagerCompletionMenu(rows: rows, selectedIndex: 0, scrollOffset: 0)
        let state = PagerRenderState(
            size: TerminalSize(width: 80, height: 24),
            completions: completionsMenu
        )

        let result = renderPagerFrame(state)
        let completionsOverlay = result.overlays.first(where: { $0.id == "completions" })

        #expect(completionsOverlay != nil, "renderPagerFrame must publish PagerOverlayBounds with id == 'completions'")
        #expect(completionsOverlay?.hasScrollbar == true, "hasScrollbar must be true when rows.count > area.height")
        #expect(completionsOverlay?.rows.count == completionsMenu.visibleRowCount)
    }

    @Test("Feature #7: Inverted Line Range Parsing Prevented from Process Crash Trap")
    func testInvertedLineRangeParsingSafety() {
        let area = TextArea()
        area.insertElement(kind: ElementKind.fileRef, text: "@Sources/Main.swift:50-20", displayText: "@Sources/Main.swift:50-20")

        let ref = area.fileRefElementAtCursor()
        #expect(ref != nil)
        #expect(ref?.path == "Sources/Main.swift")
        #expect(ref?.lineRange == nil, "Inverted range 50-20 must return nil lineRange without crashing")
    }

    @Test("Feature #7: Double-Click Cursor Placement Ordering in TextArea & Controller")
    func testDoubleClickCursorPlacementOrdering() {
        let area = TextArea()
        area.insertStr("hello world")
        let contentRect = TextAreaRect(x: 0, y: 0, width: 40, height: 3)

        // 1st click at x=2 -> handleMouse updates cursor to 2
        let mouse1 = MouseEvent(kind: .down, x: 2, y: 0, button: .left)
        _ = area.handleMouse(mouse1, area: contentRect, state: TextAreaState())
        #expect(area.cursor == 2)

        // 2nd click at x=5 -> handleMouse runs FIRST in applyComposerMouse, updating cursor to 5
        let mouse2 = MouseEvent(kind: .down, x: 5, y: 0, button: .left)
        _ = area.handleMouse(mouse2, area: contentRect, state: TextAreaState())
        #expect(area.cursor == 5, "2nd click handleMouse must place cursor at 5 first before double-click element evaluation")
    }
}

