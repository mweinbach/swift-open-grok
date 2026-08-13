// TextAreaInteraction.swift
//
// Framework-independent mouse, layout, scrollbar, and element-event surface
// ported from xai-ratatui-textarea.

import Foundation
import OpenGrokTerminalCore

// MARK: - Layout types

/// Rectangular area occupied by a text area (absolute screen coordinates).
public struct TextAreaRect: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var right: Int { x + width }
    public var bottom: Int { y + height }

    public func contains(col: Int, row: Int) -> Bool {
        col >= x && col < right && row >= y && row < bottom
    }
}

/// Deterministic visible-line layout snapshot.
public struct TextAreaLayout: Sendable, Equatable {
    public var area: TextAreaRect
    public var textWidth: Int
    public var scroll: Int
    public var wrappedLines: [Range<Int>]
    public var needsScrollbar: Bool
    public var totalLines: Int
    public var visibleRange: Range<Int>

    public init(
        area: TextAreaRect,
        textWidth: Int,
        scroll: Int,
        wrappedLines: [Range<Int>],
        needsScrollbar: Bool
    ) {
        self.area = area
        self.textWidth = textWidth
        self.scroll = scroll
        self.wrappedLines = wrappedLines
        self.needsScrollbar = needsScrollbar
        self.totalLines = wrappedLines.count
        let end = min(wrappedLines.count, scroll + max(area.height, 0))
        self.visibleRange = min(scroll, wrappedLines.count)..<end
    }
}

/// Absolute screen cell of a buffer offset inside a `TextAreaRect`.
public struct TextAreaScreenPosition: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// One visible row of a UTF-8 selection (or any byte range) after wrap/scroll.
///
/// `utf8Range` is the wrapped-row segment (may include trailing wrap spaces
/// whose display is clipped). `displayCols` is 0-based within the content
/// origin, already clamped to `textWidth` so it never covers the scrollbar.
public struct TextAreaSelectionSpan: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var utf8Range: Range<Int>
    public var displayCols: Range<Int>

    public init(x: Int, y: Int, width: Int, utf8Range: Range<Int>, displayCols: Range<Int>) {
        self.x = x
        self.y = y
        self.width = width
        self.utf8Range = utf8Range
        self.displayCols = displayCols
    }

    public var rect: TextAreaRect {
        TextAreaRect(x: x, y: y, width: width, height: 1)
    }
}

/// Hit-test result for a screen cell. `utf8Offset` is grapheme-snapped via
/// `displayColToBufferPos` (wide glyphs land on the cluster start).
public struct TextAreaScreenHit: Sendable, Equatable {
    public var utf8Offset: Int
    public var hitElement: Bool
    /// Wrapped-row index in the wrap cache (not screen-relative).
    public var wrappedRow: Int
    /// Display column relative to the content origin (`col - area.x`).
    public var displayCol: Int

    public init(utf8Offset: Int, hitElement: Bool, wrappedRow: Int, displayCol: Int) {
        self.utf8Offset = utf8Offset
        self.hitElement = hitElement
        self.wrappedRow = wrappedRow
        self.displayCol = displayCol
    }
}

/// Sendable read-only copy of composer buffer + wrap geometry for pager
/// actor/render. Does not retain the `TextArea` object. Wrap rows are the
/// `ensureWrapCache` / `wrappedLines` cache, not an independent wrap.
public struct TextAreaComposerSnapshot: Sendable, Equatable {
    public var text: String
    public var cursorUTF8: Int
    public var selectionUTF8: Range<Int>?
    public var selectedText: String?
    public var state: TextAreaState
    public var scrollOverride: Int?
    public var wrapWidth: Int
    public var wrapOptions: WrapOptions
    public var wrappedRows: [Range<Int>]
    public var cursorScreenPosition: TextAreaScreenPosition?
    public var selectionScreenSpans: [TextAreaSelectionSpan]

    public init(
        text: String,
        cursorUTF8: Int,
        selectionUTF8: Range<Int>?,
        selectedText: String?,
        state: TextAreaState,
        scrollOverride: Int?,
        wrapWidth: Int,
        wrapOptions: WrapOptions,
        wrappedRows: [Range<Int>],
        cursorScreenPosition: TextAreaScreenPosition? = nil,
        selectionScreenSpans: [TextAreaSelectionSpan] = []
    ) {
        self.text = text
        self.cursorUTF8 = cursorUTF8
        self.selectionUTF8 = selectionUTF8
        self.selectedText = selectedText
        self.state = state
        self.scrollOverride = scrollOverride
        self.wrapWidth = wrapWidth
        self.wrapOptions = wrapOptions
        self.wrappedRows = wrappedRows
        self.cursorScreenPosition = cursorScreenPosition
        self.selectionScreenSpans = selectionScreenSpans
    }

    /// UTF-8 slice of one wrap row. Empty when `index` is out of range.
    public func text(ofWrappedRow index: Int) -> String {
        guard wrappedRows.indices.contains(index) else { return "" }
        return text.substring(utf8Range: wrappedRows[index])
    }
}

// MARK: - Pure composer projection (no TextArea instance)

/// Wrap / caret / selection / hit geometry from text + UTF-8 state.
///
/// This is the render-side seam: pager paint and hit-testing must not
/// construct a second mutable `TextArea`. Matches `TextArea.composerSnapshot`
/// for a buffer with no elements, `tabWidth` 0 by default, and the same
/// `composerWrapOptions` wrap cache.
public func projectComposerGeometry(
    text: String,
    cursorUTF8: Int,
    selectionUTF8: Range<Int>?,
    selectedText: String? = nil,
    state: TextAreaState = TextAreaState(),
    scrollOverride: Int? = nil,
    area: TextAreaRect,
    showScrollbar: Bool = false,
    scrollbarPadding: Int = 0,
    tabWidth: UInt8 = 0
) -> TextAreaComposerSnapshot {
    let (textWidth, _) = projectComposerContentWidth(
        text: text,
        areaWidth: area.width,
        areaHeight: area.height,
        showScrollbar: showScrollbar,
        scrollbarPadding: scrollbarPadding,
        tabWidth: tabWidth
    )
    let opts = composerWrapOptions(width: max(textWidth, 1))
    var rows = wrapRanges(text, options: opts)
    if rows.isEmpty { rows = [0..<0] }
    let cursor = min(max(0, cursorUTF8), text.utf8Count)
    let scroll = projectComposerEffectiveScroll(
        areaHeight: area.height,
        lines: rows,
        currentScroll: state.scroll,
        cursorUTF8: cursor,
        scrollOverride: scrollOverride
    )
    let cursorPos = projectComposerCursorPosition(
        text: text,
        cursorUTF8: cursor,
        lines: rows,
        area: area,
        textWidth: max(textWidth, 1),
        scroll: scroll,
        tabWidth: tabWidth
    )
    let spans: [TextAreaSelectionSpan]
    if let selectionUTF8 {
        spans = projectComposerScreenSpans(
            ofUTF8: selectionUTF8,
            text: text,
            lines: rows,
            area: area,
            textWidth: max(textWidth, 1),
            scroll: scroll,
            tabWidth: tabWidth
        )
    } else {
        spans = []
    }
    return TextAreaComposerSnapshot(
        text: text,
        cursorUTF8: cursor,
        selectionUTF8: selectionUTF8,
        selectedText: selectedText,
        state: TextAreaState(scroll: scroll),
        scrollOverride: scrollOverride,
        wrapWidth: opts.width,
        wrapOptions: opts,
        wrappedRows: rows == [0..<0] && text.isEmpty ? [] : rows,
        cursorScreenPosition: cursorPos,
        selectionScreenSpans: spans
    )
}

/// Hit-test a screen cell against a pure projection. `nil` outside `area`.
public func projectComposerScreenHit(
    col: Int,
    row: Int,
    snapshot: TextAreaComposerSnapshot,
    area: TextAreaRect,
    tabWidth: UInt8 = 0
) -> TextAreaScreenHit? {
    guard area.contains(col: col, row: row) else { return nil }
    var lines = snapshot.wrappedRows
    if lines.isEmpty { lines = [0..<0] }
    let scroll = snapshot.state.scroll
    let visualRow = (row - area.y) + scroll
    let displayCol = max(0, col - area.x)
    let utf8Count = snapshot.text.utf8Count
    let pos: Int
    if visualRow >= lines.count {
        pos = utf8Count
    } else if visualRow < 0 {
        pos = 0
    } else {
        let line = lines[visualRow]
        let lineEnd = min(line.upperBound, utf8Count)
        pos = projectComposerDisplayColToBufferPos(
            text: snapshot.text,
            lineStart: line.lowerBound,
            lineEnd: lineEnd,
            targetCol: displayCol,
            tabWidth: tabWidth
        )
    }
    return TextAreaScreenHit(
        utf8Offset: pos,
        hitElement: false,
        wrappedRow: max(0, visualRow),
        displayCol: displayCol
    )
}

func projectComposerContentWidth(
    text: String,
    areaWidth: Int,
    areaHeight: Int,
    showScrollbar: Bool,
    scrollbarPadding: Int,
    tabWidth: UInt8
) -> (Int, Bool) {
    _ = tabWidth
    if !showScrollbar || areaWidth <= 1 {
        return (areaWidth, false)
    }
    let lines = wrapRanges(text, options: composerWrapOptions(width: max(areaWidth, 1)))
    let needs = lines.count > areaHeight
    if needs {
        let reserved = 1 + scrollbarPadding
        return (max(0, areaWidth - reserved), true)
    }
    return (areaWidth, false)
}

func projectComposerEffectiveScroll(
    areaHeight: Int,
    lines: [Range<Int>],
    currentScroll: Int,
    cursorUTF8: Int,
    scrollOverride: Int?
) -> Int {
    let total = lines.count
    if areaHeight >= total { return 0 }
    let maxScroll = max(0, total - areaHeight)
    if let ovr = scrollOverride {
        return min(max(0, ovr), maxScroll)
    }
    let cursorLine = projectComposerWrappedLineIndexByStart(lines, cursorUTF8) ?? 0
    var scroll = min(max(0, currentScroll), maxScroll)
    if cursorLine < scroll {
        scroll = cursorLine
    } else if cursorLine >= scroll + areaHeight {
        scroll = cursorLine + 1 - areaHeight
    }
    return scroll
}

func projectComposerCursorPosition(
    text: String,
    cursorUTF8: Int,
    lines: [Range<Int>],
    area: TextAreaRect,
    textWidth: Int,
    scroll: Int,
    tabWidth: UInt8
) -> TextAreaScreenPosition? {
    var rows = lines
    if rows.isEmpty { rows = [0..<0] }
    guard var i = projectComposerWrappedLineIndexByStart(rows, cursorUTF8) else { return nil }
    let ls = rows[i]
    var col = projectComposerDisplayWidth(
        ofUTF8Range: ls.lowerBound..<cursorUTF8,
        text: text,
        tabWidth: tabWidth
    )
    if col >= textWidth {
        i += 1
        col = 0
    }
    if i < scroll || i >= scroll + area.height {
        return nil
    }
    return TextAreaScreenPosition(x: area.x + col, y: area.y + (i - scroll))
}

func projectComposerScreenSpans(
    ofUTF8 range: Range<Int>,
    text: String,
    lines: [Range<Int>],
    area: TextAreaRect,
    textWidth: Int,
    scroll: Int,
    tabWidth: UInt8
) -> [TextAreaSelectionSpan] {
    var spans: [TextAreaSelectionSpan] = []
    if range.lowerBound >= range.upperBound
        || range.upperBound > text.utf8Count
        || !isUTF8ScalarBoundary(range.lowerBound, in: text)
        || !isUTF8ScalarBoundary(range.upperBound, in: text)
    {
        return spans
    }
    var rows = lines
    if rows.isEmpty { rows = [0..<0] }
    let first = projectComposerWrappedLineIndexByStart(rows, range.lowerBound) ?? 0
    let rightEdge = area.x + textWidth
    if first < rows.count {
        for i in first..<rows.count {
            let ls = rows[i]
            if ls.lowerBound >= range.upperBound { break }
            if i < scroll { continue }
            if i >= scroll + area.height { break }
            let segStart = max(range.lowerBound, ls.lowerBound)
            let segEnd = min(range.upperBound, ls.upperBound)
            if segStart >= segEnd { continue }
            let startX = min(
                area.x + projectComposerDisplayWidth(
                    ofUTF8Range: ls.lowerBound..<segStart,
                    text: text,
                    tabWidth: tabWidth
                ),
                rightEdge
            )
            let endX = min(
                area.x + projectComposerDisplayWidth(
                    ofUTF8Range: ls.lowerBound..<segEnd,
                    text: text,
                    tabWidth: tabWidth
                ),
                rightEdge
            )
            if startX < endX {
                spans.append(TextAreaSelectionSpan(
                    x: startX,
                    y: area.y + (i - scroll),
                    width: endX - startX,
                    utf8Range: segStart..<segEnd,
                    displayCols: (startX - area.x)..<(endX - area.x)
                ))
            }
        }
    }
    return spans
}

func projectComposerWrappedLineIndexByStart(_ lines: [Range<Int>], _ pos: Int) -> Int? {
    lines.lastIndex(where: { $0.lowerBound <= pos })
}

func projectComposerDisplayWidth(ofUTF8Range range: Range<Int>, text: String, tabWidth: UInt8) -> Int {
    if range.lowerBound >= range.upperBound { return 0 }
    return plainDisplayWidth(text.substring(utf8Range: range), tabWidth: tabWidth)
}

func projectComposerDisplayColToBufferPos(
    text: String,
    lineStart: Int,
    lineEnd: Int,
    targetCol: Int,
    tabWidth: UInt8
) -> Int {
    var widthSoFar = 0
    var pos = lineStart
    while pos < lineEnd {
        let next = text.nextGraphemeBoundary(byte: pos)
        if next <= pos { break }
        let g = text.substring(utf8Range: pos..<min(next, lineEnd))
        let gw = graphemeDisplayWidth(g, tabWidth: tabWidth)
        widthSoFar += gw
        if widthSoFar > targetCol {
            return text.normalizeExternalCursor(byte: pos)
        }
        pos = next
    }
    return text.normalizeExternalCursor(byte: lineEnd)
}

// MARK: - Interaction extension

extension TextArea {
    // MARK: Scroll override API

    public func setScrollOverride(_ scroll: Int?) {
        scrollOverrideStorage = scroll.map { max(0, $0) }
    }

    public var scrollOverrideValue: Int? { scrollOverrideStorage }

    // MARK: Element events

    public func pollElementEvent() -> TextElementEvent? {
        let e = pendingElementEvent
        pendingElementEvent = nil
        return e
    }

    // MARK: Layout

    /// Content width for wrapping (area width minus scrollbar column when needed).
    public func textWidth(area: TextAreaRect) -> Int {
        contentWidth(areaWidth: area.width, areaHeight: area.height).0
    }

    public func contentWidth(areaWidth: Int, areaHeight: Int) -> (Int, Bool) {
        if !showScrollbar || areaWidth <= 1 {
            return (areaWidth, false)
        }
        let lines = wrappedLines(width: max(areaWidth, 1))
        let needs = lines.count > areaHeight
        if needs {
            let reserved = 1 + scrollbarPadding
            return (max(0, areaWidth - reserved), true)
        }
        return (areaWidth, false)
    }

    public func effectiveScroll(areaHeight: Int, lines: [Range<Int>], currentScroll: Int) -> Int {
        let total = lines.count
        if areaHeight >= total { return 0 }
        let maxScroll = max(0, total - areaHeight)
        if let ovr = scrollOverrideStorage {
            return min(ovr, maxScroll)
        }
        let cursorLine = wrappedLineIndex(lines, cursor) ?? 0
        var scroll = min(max(0, currentScroll), maxScroll)
        if cursorLine < scroll {
            scroll = cursorLine
        } else if cursorLine >= scroll + areaHeight {
            scroll = cursorLine + 1 - areaHeight
        }
        return scroll
    }

    public func layout(area: TextAreaRect, state: TextAreaState) -> TextAreaLayout {
        let (tw, needsSB) = contentWidth(areaWidth: area.width, areaHeight: area.height)
        let lines = wrappedLines(width: max(tw, 1))
        let scroll = effectiveScroll(areaHeight: area.height, lines: lines, currentScroll: state.scroll)
        return TextAreaLayout(
            area: area,
            textWidth: tw,
            scroll: scroll,
            wrappedLines: lines,
            needsScrollbar: needsSB
        )
    }

    /// Buffer + wrap-cache snapshot. Screen cursor/spans stay empty; use
    /// `composerSnapshot(area:state:)` when the pager has a painted rect.
    public func composerSnapshot(wrapWidth: Int) -> TextAreaComposerSnapshot {
        let opts = composerWrapOptions(width: wrapWidth)
        let rows = wrappedLines(width: opts.width)
        return TextAreaComposerSnapshot(
            text: text,
            cursorUTF8: cursor,
            selectionUTF8: selectionRange,
            selectedText: selectedText(),
            state: TextAreaState(scroll: scrollOverrideStorage ?? 0),
            scrollOverride: scrollOverrideValue,
            wrapWidth: opts.width,
            wrapOptions: opts,
            wrappedRows: rows
        )
    }

    /// Snapshot including effective scroll and screen geometry for `area`.
    public func composerSnapshot(area: TextAreaRect, state: TextAreaState) -> TextAreaComposerSnapshot {
        let layout = layout(area: area, state: state)
        var snap = composerSnapshot(wrapWidth: max(layout.textWidth, 1))
        snap.wrappedRows = layout.wrappedLines
        snap.state = TextAreaState(scroll: layout.scroll)
        snap.cursorScreenPosition = cursorPosition(area: area, state: state)
        snap.selectionScreenSpans = selectionScreenSpans(area: area, state: state)
        return snap
    }

    /// On-screen cursor with wrap-boundary adjustment. `nil` when the cursor
    /// row is scrolled out of the viewport.
    ///
    /// Port of `cursor_pos` / `cursor_pos_with_state` (`textarea.rs:720-759`).
    public func cursorPosition(area: TextAreaRect, state: TextAreaState = TextAreaState()) -> TextAreaScreenPosition? {
        let tw = textWidth(area: area)
        var lines = wrappedLines(width: max(tw, 1))
        // `desiredHeight` floors at 1; empty wrap cache still has a cursor cell.
        if lines.isEmpty { lines = [0..<0] }
        let effectiveScroll = effectiveScroll(areaHeight: area.height, lines: lines, currentScroll: state.scroll)
        guard var i = wrappedLineIndexByStart(lines, cursor) else { return nil }
        let ls = lines[i]
        var col = displayWidth(ofUTF8Range: ls.lowerBound..<cursor)
        // Cursor at the exact wrap boundary sits on the next visual line
        // (`textarea.rs:741-749`), including a virtual row when the last
        // line is exactly full.
        if col >= tw {
            i += 1
            col = 0
        }
        let scroll = effectiveScroll
        if i < scroll || i >= scroll + area.height {
            return nil
        }
        let screenRow = i - scroll
        return TextAreaScreenPosition(x: area.x + col, y: area.y + screenRow)
    }

    /// On-screen cell of an arbitrary UTF-8 offset. No wrap-boundary bump —
    /// see `cursorPosition` for the cursor. Port of `screen_position_of`
    /// (`textarea.rs:766-786`).
    public func screenPosition(
        ofUTF8 pos: Int,
        area: TextAreaRect,
        state: TextAreaState
    ) -> TextAreaScreenPosition? {
        let tw = textWidth(area: area)
        var lines = wrappedLines(width: max(tw, 1))
        if lines.isEmpty { lines = [0..<0] }
        let effectiveScroll = effectiveScroll(areaHeight: area.height, lines: lines, currentScroll: state.scroll)
        guard let i = wrappedLineIndexByStart(lines, pos) else { return nil }
        let ls = lines[i]
        let col = displayWidth(ofUTF8Range: ls.lowerBound..<pos)
        let scroll = effectiveScroll
        if i < scroll || i >= scroll + area.height {
            return nil
        }
        let screenRow = i - scroll
        return TextAreaScreenPosition(x: area.x + col, y: area.y + screenRow)
    }

    /// Visible selection (or any UTF-8 range) as height-1 spans. Empty when
    /// the range is empty, past the text, or not on UTF-8 scalar boundaries.
    /// Port of `screen_spans_of_range` (`textarea.rs:799-856`).
    public func screenSpans(
        ofUTF8 range: Range<Int>,
        area: TextAreaRect,
        state: TextAreaState
    ) -> [TextAreaSelectionSpan] {
        var spans: [TextAreaSelectionSpan] = []
        if range.lowerBound >= range.upperBound
            || range.upperBound > text.utf8Count
            || !isUTF8ScalarBoundary(range.lowerBound, in: text)
            || !isUTF8ScalarBoundary(range.upperBound, in: text)
        {
            return spans
        }
        let tw = textWidth(area: area)
        let lines = wrappedLines(width: max(tw, 1))
        let scroll = effectiveScroll(areaHeight: area.height, lines: lines, currentScroll: state.scroll)
        let first = wrappedLineIndexByStart(lines, range.lowerBound) ?? 0
        let rightEdge = area.x + tw
        if first < lines.count {
            for i in first..<lines.count {
                let ls = lines[i]
                if ls.lowerBound >= range.upperBound { break }
                if i < scroll { continue }
                if i >= scroll + area.height { break }
                let segStart = max(range.lowerBound, ls.lowerBound)
                let segEnd = min(range.upperBound, ls.upperBound)
                if segStart >= segEnd { continue }
                let startX = min(area.x + displayWidth(ofUTF8Range: ls.lowerBound..<segStart), rightEdge)
                let endX = min(area.x + displayWidth(ofUTF8Range: ls.lowerBound..<segEnd), rightEdge)
                if startX < endX {
                    let displayStart = startX - area.x
                    let displayEnd = endX - area.x
                    spans.append(TextAreaSelectionSpan(
                        x: startX,
                        y: area.y + (i - scroll),
                        width: endX - startX,
                        utf8Range: segStart..<segEnd,
                        displayCols: displayStart..<displayEnd
                    ))
                }
            }
        }
        return spans
    }

    public func selectionScreenSpans(area: TextAreaRect, state: TextAreaState) -> [TextAreaSelectionSpan] {
        guard let range = selectionRange else { return [] }
        return screenSpans(ofUTF8: range, area: area, state: state)
    }

    public func bufferPosAtScreen(col: Int, row: Int, area: TextAreaRect, state: TextAreaState) -> Int? {
        guard area.contains(col: col, row: row) else { return nil }
        return bufferPosAtScreenEx(col: col, row: row, area: area, state: state)?.0
    }

    /// Strict-bounds hit mapping (same containment as `bufferPosAtScreen`)
    /// with wrap-row / display-col / element flags `handleMouse` already uses.
    public func screenHit(
        col: Int,
        row: Int,
        area: TextAreaRect,
        state: TextAreaState
    ) -> TextAreaScreenHit? {
        guard area.contains(col: col, row: row) else { return nil }
        guard let (pos, hitElement) = bufferPosAtScreenEx(col: col, row: row, area: area, state: state) else {
            return nil
        }
        let tw = textWidth(area: area)
        let lines = wrappedLines(width: max(tw, 1))
        let scroll = effectiveScroll(areaHeight: area.height, lines: lines, currentScroll: state.scroll)
        let visualRow = (row - area.y) + scroll
        let displayCol = max(0, col - area.x)
        return TextAreaScreenHit(
            utf8Offset: pos,
            hitElement: hitElement,
            wrappedRow: visualRow,
            displayCol: displayCol
        )
    }

    public func elementAtScreen(col: Int, row: Int, area: TextAreaRect, state: TextAreaState) -> TextElement? {
        guard let (pos, hitElement) = bufferPosAtScreenEx(col: col, row: row, area: area, state: state) else {
            return nil
        }
        if hitElement {
            return allElements.first { pos >= $0.range.lowerBound && pos <= $0.range.upperBound && !$0.range.isEmpty }
        }
        return allElements.first { pos >= $0.range.lowerBound && pos < $0.range.upperBound }
    }

    /// Unified input entry for key + mouse events.
    public func input(_ event: InputEvent, area: TextAreaRect, state: inout TextAreaState) -> MouseAction? {
        switch event {
        case .key(let key):
            input(key)
            return nil
        case .mouse(let mouse):
            return handleMouse(mouse, area: area, state: state)
        default:
            return nil
        }
    }

    // MARK: Mouse

    /// Drop an in-flight left gesture without copying. Overlay / nil-hit /
    /// resize / suspend / restore must call this so `dragActive` and
    /// `pendingDragScroll` cannot strand the host clock. The next left-down
    /// starts fresh. Cost: a mid-drag cancel leaves the highlight as-is
    /// (no OSC 52); that is the point — do not synthesize a copy.
    public func cancelMouseGesture() {
        mouseDownPos = nil
        dragActive = false
        scrollbarDragging = false
        pendingDragScroll = nil
        dragAnchor = nil
        lastDragScrollMs = nil
        dragScrollSteps = 0
    }

    public func handleMouse(_ event: MouseEvent, area: TextAreaRect, state: TextAreaState) -> MouseAction {
        let tw = textWidth(area: area)
        let hasScrollbar = showScrollbar && tw < area.width
        let onScrollbar = hasScrollbar && event.x == area.x + area.width - 1

        if scrollbarDragging {
            switch event.kind {
            case .drag, .down:
                // Explicit gate: a comma-list `where` only binds the last
                // pattern, so middle/right drag would keep the thumb moving.
                if isLeftButton(event) {
                    return handleScrollbarClick(row: event.y, area: area, textWidth: tw)
                }
            case .up:
                if isLeftRelease(event) {
                    scrollbarDragging = false
                    return .scrolled
                }
            default:
                break
            }
        }

        if onScrollbar, event.kind == .down, isLeftButton(event) {
            scrollbarDragging = true
            if isScrollbarThumbAt(row: event.y, area: area, textWidth: tw, state: state) {
                return .scrolled
            }
            return handleScrollbarClick(row: event.y, area: area, textWidth: tw)
        }

        switch event.kind {
        case .down:
            guard isLeftButton(event) else { return .nothing }
            if dragActive {
                let dragEvent = MouseEvent(kind: .drag, x: event.x, y: event.y, button: event.button, modifiers: event.modifiers)
                return handleMouse(dragEvent, area: area, state: state)
            }

            let col = event.x
            let row = event.y
            // Outside the textarea area → nothing (strict bounds for click placement).
            if !area.contains(col: col, row: row) {
                scrollOverrideStorage = nil
                dragAnchor = nil
                return .nothing
            }
            let clickCount = clickTracker.register(col: col, row: row)
            mouseDownPos = (col, row)
            dragActive = false
            lastDragScrollMs = nil
            dragScrollSteps = 0
            pendingDragScroll = nil
            clearSelection()

            guard let (pos, hitElement) = bufferPosAtScreenEx(col: col, row: row, area: area, state: state) else {
                scrollOverrideStorage = nil
                dragAnchor = nil
                return .nothing
            }
            scrollOverrideStorage = nil

            switch clickCount {
            case 2:
                if let action = elementClickSnap(pos: pos, hitElement: hitElement) {
                    return action
                }
                let isWS: Bool = {
                    if pos >= text.utf8Count { return true }
                    let ch = text.substring(utf8Range: pos..<text.nextGraphemeBoundary(byte: pos))
                    return ch.first?.isWhitespace == true
                }()
                let start = wordStartAt(pos)
                let end = wordEndAt(pos)
                if !isWS && start < end {
                    setSelection(anchor: start, head: end)
                    // Cursor on last character of selection
                    let last = text.previousGraphemeBoundary(byte: end)
                    setCursorInner(last >= start ? last : start)
                    preferredColStorage = nil
                    if let t = selectedText() { setClipboardTextPublic(t) }
                    return .selectionFinished
                }
                setCursorInner(pos)
                preferredColStorage = nil
                return .cursorPlaced
            case 3:
                let lineStart = beginningOfLine(pos)
                let lineEndExcl = endOfLine(pos)
                let lineEnd = lineEndExcl < text.utf8Count ? lineEndExcl + 1 : lineEndExcl
                setSelection(anchor: lineStart, head: lineEnd)
                setCursorInner(pos)
                preferredColStorage = nil
                if let t = selectedText() { setClipboardTextPublic(t) }
                return .selectionFinished
            default:
                if let action = elementClickSnap(pos: pos, hitElement: hitElement) {
                    return action
                }
                dragAnchor = pos
                setCursorInner(pos)
                preferredColStorage = nil
                return .cursorPlaced
            }

        case .drag:
            guard isLeftButton(event) else { return .nothing }
            guard let anchor = dragAnchor else { return .nothing }
            let outside = event.y < area.y || event.y >= area.bottom
            if outside {
                pendingDragScroll = event
                let now = monotonicMs()
                let interval = dragScrollInterval(dragScrollSteps)
                if let last = lastDragScrollMs, now - last < interval {
                    return .nothing
                }
                lastDragScrollMs = now
                dragScrollSteps &+= 1
            } else {
                pendingDragScroll = nil
            }

            let lines = wrappedLines(width: max(tw, 1))
            let scroll = effectiveScroll(areaHeight: area.height, lines: lines, currentScroll: state.scroll)
            let visibleEnd = scroll + area.height
            let head: Int
            var newScroll: Int?

            if event.y < area.y {
                let dist = area.y - event.y
                let n = dragScrollLines(forDistance: dist)
                let targetLine = max(0, scroll - n)
                if targetLine < lines.count {
                    let col = max(0, event.x - area.x)
                    let line = lines[targetLine]
                    let lineEnd = min(line.upperBound, text.utf8Count)
                    let p = displayColToBufferPos(lineStart: line.lowerBound, lineEnd: lineEnd, targetCol: col).0
                    head = clampToLine(p, lineStart: line.lowerBound, lineEnd: lineEnd)
                } else {
                    head = 0
                }
                newScroll = targetLine
            } else if event.y >= area.bottom {
                let dist = event.y - area.bottom + 1
                let n = dragScrollLines(forDistance: dist)
                let targetLine = min(max(0, lines.count - 1), visibleEnd + n - 1)
                let maxScroll = max(0, lines.count - area.height)
                newScroll = min(maxScroll, max(0, targetLine + 1 - area.height))
                if targetLine < lines.count {
                    let col = max(0, event.x - area.x)
                    let line = lines[targetLine]
                    let lineEnd = min(line.upperBound, text.utf8Count)
                    let p = displayColToBufferPos(lineStart: line.lowerBound, lineEnd: lineEnd, targetCol: col).0
                    head = clampToLine(p, lineStart: line.lowerBound, lineEnd: lineEnd)
                } else {
                    head = text.utf8Count
                }
            } else {
                let col = min(max(event.x, area.x), area.x + max(tw, 1) - 1)
                guard let pos = bufferPosAtScreen(col: col, row: event.y, area: area, state: state) else {
                    return .nothing
                }
                head = pos
                newScroll = nil
            }

            if let s = newScroll { scrollOverrideStorage = s }
            if head == anchor {
                dragActive = false
                clearSelection()
            } else {
                dragActive = true
                setSelection(anchor: anchor, head: head)
            }
            setCursorInner(head)
            preferredColStorage = nil
            return selectionRange == nil ? .cursorPlaced : .selectionUpdated

        case .up:
            // X10 release is `.up` + `noButton`; finish/copy/cancel the
            // active LEFT gesture exactly like button 0. Middle/right up
            // never do (`isLeftRelease`).
            guard isLeftRelease(event) else { return .nothing }
            mouseDownPos = nil
            let wasDrag = dragActive
            dragActive = false
            scrollbarDragging = false
            pendingDragScroll = nil
            dragAnchor = nil
            if wasDrag {
                if selectionRange == nil {
                    clearSelection()
                    return .cursorPlaced
                }
                if let t = selectedText(), !t.isEmpty {
                    setClipboardTextPublic(t)
                }
                if !keepSelectionAfterMouseUp {
                    clearSelection()
                }
                return .selectionFinished
            }
            return .nothing

        case .scrollDown:
            return handleScroll(delta: 1, area: area, state: state)
        case .scrollUp:
            return handleScroll(delta: -1, area: area, state: state)

        case .move:
            let hovered = elementAtScreen(col: event.x, row: event.y, area: area, state: state)?.id
            let prev = hoveredElement
            if hovered != prev {
                if let old = prev {
                    pendingElementEvent = TextElementEvent(id: old, kind: .hoverLeave)
                }
                if let newId = hovered {
                    pendingElementEvent = TextElementEvent(id: newId, kind: .hoverEnter)
                }
                hoveredElement = hovered
            }
            return .nothing

        default:
            return .nothing
        }
    }

    /// Timer-driven work (drag-scroll continuation). Host should call when poll times out.
    public func tick(area: TextAreaRect, state: TextAreaState) -> MouseAction {
        if let event = pendingDragScroll {
            return handleMouse(event, area: area, state: state)
        }
        return .nothing
    }

    public func pollTimeoutMs() -> UInt64? {
        guard pendingDragScroll != nil else { return nil }
        return UInt64(dragScrollInterval(dragScrollSteps))
    }

    // MARK: - Private interaction helpers

    /// SGR/X10 left down and drag. X10 release is `noButton`, not 0.
    fileprivate func isLeftButton(_ event: MouseEvent) -> Bool {
        event.button == 0
    }

    /// Left release: SGR button 0, or X10/legacy up with no button
    /// attribution. Middle/right up must never finish a left gesture.
    fileprivate func isLeftRelease(_ event: MouseEvent) -> Bool {
        event.button == 0 || event.button == MouseEvent.noButton
    }

    fileprivate func handleScroll(delta: Int, area: TextAreaRect, state: TextAreaState) -> MouseAction {
        let tw = textWidth(area: area)
        let lines = wrappedLines(width: max(tw, 1))
        let total = lines.count
        if total <= area.height { return .nothing }
        let maxScroll = total - area.height
        let current = scrollOverrideStorage
            ?? effectiveScroll(areaHeight: area.height, lines: lines, currentScroll: state.scroll)
        let step = scrollLinesForHeight(area.height)
        let newScroll: Int
        if delta > 0 {
            newScroll = min(maxScroll, current + step)
        } else {
            newScroll = max(0, current - step)
        }
        if newScroll == current { return .nothing }
        var dragNewPos: Int?
        if dragActive {
            if delta > 0 {
                let target = min(lines.count - 1, newScroll + area.height - 1)
                dragNewPos = lines[target].lowerBound
            } else {
                dragNewPos = newScroll < lines.count ? lines[newScroll].lowerBound : 0
            }
        }
        scrollOverrideStorage = newScroll
        if let p = dragNewPos {
            if let sel = selectionRange {
                setSelection(anchor: sel.lowerBound == cursor ? sel.upperBound : sel.lowerBound, head: p)
                // preserve anchor: use dragAnchor if present
                if let a = dragAnchor {
                    setSelection(anchor: a, head: p)
                }
            }
            setCursorInner(p)
        }
        return .scrolled
    }

    fileprivate func handleScrollbarClick(row: Int, area: TextAreaRect, textWidth tw: Int) -> MouseAction {
        if area.height == 0 { return .nothing }
        let lines = wrappedLines(width: max(tw, 1))
        let total = lines.count
        if total <= area.height { return .nothing }
        let maxScroll = total - area.height
        let rel = max(0, row - area.y)
        let scroll: Int
        if area.height <= 1 {
            scroll = 0
        } else {
            scroll = min(maxScroll, (rel * maxScroll) / (area.height - 1))
        }
        scrollOverrideStorage = scroll
        return .scrolled
    }

    fileprivate func isScrollbarThumbAt(row: Int, area: TextAreaRect, textWidth tw: Int, state: TextAreaState) -> Bool {
        if area.height == 0 { return false }
        let lines = wrappedLines(width: max(tw, 1))
        let total = lines.count
        if total <= area.height { return false }
        let scroll = scrollOverrideStorage ?? 0
        // Approximate tui-scrollbar thumb placement: proportional block.
        let thumbLen = max(1, (area.height * area.height) / total)
        let maxScroll = total - area.height
        let thumbStart: Int
        if maxScroll == 0 {
            thumbStart = 0
        } else {
            thumbStart = (scroll * (area.height - thumbLen)) / maxScroll
        }
        let rel = row - area.y
        return rel >= thumbStart && rel < thumbStart + thumbLen
    }

    fileprivate func elementClickSnap(pos: Int, hitElement: Bool) -> MouseAction? {
        guard hitElement else { return nil }
        guard let elem = allElements.first(where: {
            pos >= $0.range.lowerBound && pos <= $0.range.upperBound && !$0.range.isEmpty
        }) else { return nil }
        setCursorInner(elem.range.lowerBound)
        preferredColStorage = nil
        dragAnchor = elem.range.lowerBound
        pendingElementEvent = TextElementEvent(id: elem.id, kind: .click)
        return .cursorPlaced
    }

    fileprivate func bufferPosAtScreenEx(
        col: Int,
        row: Int,
        area: TextAreaRect,
        state: TextAreaState
    ) -> (Int, Bool)? {
        // Rust `buffer_pos_at_screen_ex` only rejects coordinates above/left of area.
        if col < area.x || row < area.y { return nil }

        let tw = textWidth(area: area)
        let lines = wrappedLines(width: max(tw, 1))
        let scroll = effectiveScroll(areaHeight: area.height, lines: lines, currentScroll: state.scroll)
        let visualRow = (row - area.y) + scroll
        if visualRow >= lines.count {
            return (text.utf8Count, false)
        }
        if visualRow < 0 { return (0, false) }
        let line = lines[visualRow]
        let targetCol = max(0, col - area.x)
        let lineEnd = min(line.upperBound, text.utf8Count)
        return displayColToBufferPos(lineStart: line.lowerBound, lineEnd: lineEnd, targetCol: targetCol)
    }

    fileprivate func displayColToBufferPos(lineStart: Int, lineEnd: Int, targetCol: Int) -> (Int, Bool) {
        var widthSoFar = 0
        var pos = lineStart
        while pos < lineEnd {
            if let elem = allElements.first(where: { pos >= $0.range.lowerBound && pos < $0.range.upperBound }) {
                let elemStart = elem.range.lowerBound
                let elemBufEnd = elem.range.upperBound
                let elemLineEnd = min(elemBufEnd, lineEnd)
                if pos == elemStart {
                    let displayW: Int
                    if let dt = elem.displayText {
                        displayW = UnicodeDisplayWidth.width(of: dt)
                    } else {
                        displayW = plainDisplayWidth(text.substring(utf8Range: elemStart..<elemLineEnd), tabWidth: tabWidth)
                    }
                    if widthSoFar + displayW > targetCol {
                        let distStart = targetCol - widthSoFar
                        let distEnd = displayW - distStart
                        if distStart <= distEnd {
                            return (elemStart, true)
                        } else {
                            return (elemBufEnd, true)
                        }
                    }
                    widthSoFar += displayW
                    pos = min(elemBufEnd, lineEnd)
                } else {
                    let partial = plainDisplayWidth(text.substring(utf8Range: pos..<elemLineEnd), tabWidth: tabWidth)
                    if widthSoFar + partial > targetCol {
                        return (elemBufEnd, true)
                    }
                    widthSoFar += partial
                    pos = min(elemBufEnd, lineEnd)
                }
                continue
            }
            let next = text.nextGraphemeBoundary(byte: pos)
            if next <= pos { break }
            let g = text.substring(utf8Range: pos..<min(next, lineEnd))
            let gw = graphemeDisplayWidth(g, tabWidth: tabWidth)
            widthSoFar += gw
            if widthSoFar > targetCol {
                return (clampPosToNearestBoundaryPublic(pos), false)
            }
            pos = next
        }
        return (clampPosToNearestBoundaryPublic(lineEnd), false)
    }

    fileprivate func clampToLine(_ pos: Int, lineStart: Int, lineEnd: Int) -> Int {
        if lineEnd > lineStart {
            let last = text.previousGraphemeBoundary(byte: lineEnd)
            let lastStart = last >= lineStart ? last : lineStart
            return min(pos, lastStart)
        }
        return lineStart
    }

    fileprivate func beginningOfLine(_ pos: Int) -> Int {
        let bytes = Array(text.utf8)
        var i = pos
        while i > 0 {
            i -= 1
            if bytes[i] == 0x0A && !isInsideElement(i) {
                return i + 1
            }
        }
        return 0
    }

    fileprivate func endOfLine(_ pos: Int) -> Int {
        let bytes = Array(text.utf8)
        var i = pos
        while i < bytes.count {
            if bytes[i] == 0x0A && !isInsideElement(i) {
                return i
            }
            i += 1
        }
        return text.utf8Count
    }

    fileprivate func isInsideElement(_ pos: Int) -> Bool {
        allElements.contains { pos >= $0.range.lowerBound && pos < $0.range.upperBound }
    }

    fileprivate func wordStartAt(_ pos: Int) -> Int {
        if let elem = allElements.first(where: { pos >= $0.range.lowerBound && pos < $0.range.upperBound }) {
            return elem.range.lowerBound
        }
        let targetClass: UInt8
        if pos < text.utf8Count {
            let ch = text.substring(utf8Range: pos..<text.nextGraphemeBoundary(byte: pos))
            targetClass = charClass(ch.first ?? " ")
        } else if pos > 0 {
            let prev = text.previousGraphemeBoundary(byte: pos)
            let ch = text.substring(utf8Range: prev..<pos)
            targetClass = charClass(ch.first ?? " ")
        } else {
            return 0
        }
        var i = pos
        while i > 0 {
            let prev = text.previousGraphemeBoundary(byte: i)
            let ch = text.substring(utf8Range: prev..<i)
            if charClass(ch.first ?? " ") != targetClass { break }
            i = prev
        }
        return adjustPosOutOfElements(i, preferStart: true)
    }

    fileprivate func wordEndAt(_ pos: Int) -> Int {
        if let elem = allElements.first(where: { pos >= $0.range.lowerBound && pos < $0.range.upperBound }) {
            return elem.range.upperBound
        }
        guard pos < text.utf8Count else { return text.utf8Count }
        let ch0 = text.substring(utf8Range: pos..<text.nextGraphemeBoundary(byte: pos))
        let targetClass = charClass(ch0.first ?? " ")
        var i = pos
        while i < text.utf8Count {
            let next = text.nextGraphemeBoundary(byte: i)
            let ch = text.substring(utf8Range: i..<next)
            if charClass(ch.first ?? " ") != targetClass { break }
            i = next
        }
        return adjustPosOutOfElements(i, preferStart: false)
    }

    fileprivate func charClass(_ ch: Character) -> UInt8 {
        if ch.isWhitespace { return 0 }
        if ch.isLetter || ch.isNumber || ch == "_" { return 1 }
        return 2
    }

    fileprivate func adjustPosOutOfElements(_ pos: Int, preferStart: Bool) -> Int {
        if let elem = allElements.first(where: { pos > $0.range.lowerBound && pos < $0.range.upperBound }) {
            return preferStart ? elem.range.lowerBound : elem.range.upperBound
        }
        return pos
    }

    fileprivate func scrollLinesForHeight(_ height: Int) -> Int {
        switch height {
        case 0...5: return 1
        case 6...15: return 2
        default: return 3
        }
    }

    fileprivate func dragScrollInterval(_ step: UInt32) -> Int {
        let ramp = [80, 60, 40]
        let idx = min(Int(step), ramp.count - 1)
        return ramp[idx]
    }

    fileprivate func dragScrollLines(forDistance distance: Int) -> Int {
        switch distance {
        case 0...2: return 1
        case 3...5: return 2
        case 6...10: return 3
        default: return 5
        }
    }

    fileprivate func monotonicMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

/// UTF-8 scalar (Rust `is_char_boundary`) — not grapheme — so a combining
/// mark start is valid while a continuation byte inside `é` is not.
fileprivate func isUTF8ScalarBoundary(_ byte: Int, in text: String) -> Bool {
    let n = text.utf8Count
    if byte < 0 || byte > n { return false }
    if byte == 0 || byte == n { return true }
    let idx = text.utf8.index(text.utf8.startIndex, offsetBy: byte)
    return text.utf8[idx] & 0xC0 != 0x80
}

// MARK: - Click tracker

struct ClickTracker {
    var lastTimeMs: Int = 0
    var lastPos: (Int, Int) = (Int.max, Int.max)
    var count: UInt8 = 0
    static let multiClickMs = 500

    mutating func register(col: Int, row: Int) -> UInt8 {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if now - lastTimeMs < Self.multiClickMs, lastPos == (col, row), count < 3 {
            count += 1
        } else {
            count = 1
        }
        lastTimeMs = now
        lastPos = (col, row)
        return count
    }
}
