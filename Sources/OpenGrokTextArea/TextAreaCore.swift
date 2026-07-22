// TextAreaCore.swift
//
// Framework-independent text area: editing, cursor, selection, undo/redo,
// wrapping, elements, clipboard. Port of the deterministic state machine from
// xai-ratatui-textarea (without ratatui widget rendering).

import Foundation
import OpenGrokTerminalCore

// MARK: - Elements & clipboard

public struct ElementId: Hashable, Sendable, Equatable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
    public static func fromRaw(_ raw: UInt64) -> ElementId { ElementId(raw: raw) }
}

public struct ElementKind: Hashable, Sendable, Equatable {
    public let raw: UInt16
    public init(_ raw: UInt16) { self.raw = raw }
}

public protocol ClipboardProvider: AnyObject {
    func get() -> String?
    func set(_ text: String)
}

public final class InternalClipboard: ClipboardProvider {
    private var contents: String?
    public init() {}
    public func get() -> String? { contents }
    public func set(_ text: String) { contents = text }
}

public struct TextElement: Sendable, Equatable {
    public var id: ElementId
    public var range: Range<Int>
    public var kind: ElementKind
    public var displayText: String?

    public init(id: ElementId, range: Range<Int>, kind: ElementKind, displayText: String? = nil) {
        self.id = id
        self.range = range
        self.kind = kind
        self.displayText = displayText
    }
}

public struct TextElementEvent: Sendable, Equatable {
    public var id: ElementId
    public var kind: TextElementEventKind
    public init(id: ElementId, kind: TextElementEventKind) {
        self.id = id
        self.kind = kind
    }
}

public enum TextElementEventKind: Sendable, Equatable {
    case click, hoverEnter, hoverLeave
}

public struct Selection: Sendable, Equatable {
    public var anchor: Int
    public var head: Int
    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public var range: Range<Int> {
        min(anchor, head)..<max(anchor, head)
    }
}

public enum MouseAction: Sendable, Equatable {
    case nothing
    case cursorPlaced
    case selectionUpdated
    case selectionFinished
    case scrolled
}

public struct TextAreaState: Sendable, Equatable {
    public var scroll: Int
    public init(scroll: Int = 0) { self.scroll = scroll }
}

// MARK: - Undo

private enum MutationKind: Equatable {
    case insert, delete, kill, element, replace
}

private struct UndoEntry {
    var text: String
    var cursor: Int
    var elements: [TextElement]
}

private struct UndoState {
    var stack: [UndoEntry] = []
    var redo: [UndoEntry] = []
    var maxDepth: Int = 100
    var lastKind: MutationKind?
    var lastCursor: Int = 0
    var lastInsertWS: Bool = false
    var groupDepth: Int = 0
    var groupCheckpoint: UndoEntry?
}

// MARK: - TextArea

public final class TextArea {
    private var buffer: EditBuffer
    private var wrapCache: (width: Int, lines: [Range<Int>])?
    /// Preferred visual column for vertical motion (cleared on horizontal edits).
    var preferredColStorage: Int?
    private var elements: [TextElement] = []
    private var nextElementId: UInt64 = 0
    private var killBuffer: String = ""
    private var undo = UndoState()
    private var selection: Selection?
    private var clipboardProvider: ClipboardProvider
    private var clipboardNotification: String?
    public var keepSelectionAfterMouseUp: Bool = true
    /// Internal scroll override (mouse wheel / scrollbar). Cleared on cursor motion.
    var scrollOverrideStorage: Int?
    public var showScrollbar: Bool = true
    /// Extra columns reserved between text and scrollbar when visible.
    public var scrollbarPadding: Int = 0
    public var tabWidth: UInt8 = 4 {
        didSet { if oldValue != tabWidth { wrapCache = nil } }
    }

    // Mouse / interaction state
    var mouseDownPos: (Int, Int)?
    var dragAnchor: Int?
    var dragActive: Bool = false
    var lastDragScrollMs: Int?
    var dragScrollSteps: UInt32 = 0
    var pendingDragScroll: MouseEvent?
    var clickTracker = ClickTracker()
    var scrollbarDragging: Bool = false
    var hoveredElement: ElementId?
    var pendingElementEvent: TextElementEvent?

    public init() {
        buffer = EditBuffer()
        clipboardProvider = InternalClipboard()
    }

    // MARK: Text access

    public var text: String { buffer.text }
    public var cursor: Int { buffer.cursorByte }
    public var isEmpty: Bool { buffer.isEmpty }

    public func setText(_ text: String) {
        let savedCursor = cursor
        let expanded = expandTabs(text, tabWidth: tabWidth)
        let plan = buffer.planReplaceByteRange(0..<buffer.count, replacement: expanded, atomic: [])
        preMutate(.replace)
        _ = buffer.applyValidatedPlan(plan)
        elements.removeAll()
        _ = buffer.setCursorByte(min(savedCursor, buffer.count))
        wrapCache = nil
        preferredColStorage = nil
        selection = nil
        scrollOverrideStorage = nil
        postMutate()
    }

    public func insertStr(_ text: String) {
        if text.isEmpty { return }
        scrollOverrideStorage = nil
        if let first = text.first {
            let firstWS = first.isWhitespace
            if undo.lastKind == .insert && undo.lastInsertWS != firstWS {
                undo.lastKind = nil
            }
        }
        applyEditReplacement(cursor..<cursor, text, .insert)
        if let last = text.last {
            undo.lastInsertWS = last.isWhitespace
        }
    }

    public func insertStrAt(_ pos: Int, _ text: String) {
        if text.isEmpty { return }
        applyEditReplacement(pos..<pos, text, .insert)
        if let last = text.last {
            undo.lastInsertWS = last.isWhitespace
        }
    }

    public func replaceRange(_ range: Range<Int>, with text: String) {
        applyEditReplacement(range, text, .replace)
    }

    public func setCursor(_ pos: Int) {
        let clamped = min(max(0, pos), buffer.count)
        let normalized = buffer.text.normalizeExternalCursor(byte: clamped)
        // Snap out of elements
        let snapped = clampPosToNearestBoundary(normalized)
        _ = buffer.setCursorByte(snapped)
        preferredColStorage = nil
        scrollOverrideStorage = nil
    }

    /// Set cursor without clearing scroll override (mouse drag / internal).
    func setCursorInner(_ pos: Int) {
        _ = buffer.setCursorByte(min(max(0, pos), buffer.count))
    }

    func clampPosToNearestBoundaryPublic(_ pos: Int) -> Int {
        clampPosToNearestBoundary(pos)
    }

    func setClipboardTextPublic(_ text: String) {
        setClipboardText(text)
    }

    // MARK: Selection

    public var selectionRange: Range<Int>? {
        selection.map(\.range)
    }

    public func selectedText() -> String? {
        guard let r = selectionRange, !r.isEmpty else { return nil }
        return buffer.text.substring(utf8Range: r)
    }

    public func clearSelection() {
        selection = nil
    }

    @discardableResult
    public func deleteSelection() -> Bool {
        guard let r = selectionRange, !r.isEmpty else { return false }
        applyEditReplacement(r, "", .delete)
        selection = nil
        return true
    }

    public func setSelection(anchor: Int, head: Int) {
        selection = Selection(anchor: anchor, head: head)
    }

    // MARK: Clipboard

    public func takeClipboard() -> String? {
        let v = clipboardNotification
        clipboardNotification = nil
        return v
    }

    public func clipboard() -> String? { clipboardNotification }

    public func setClipboardProvider(_ provider: ClipboardProvider) {
        clipboardProvider = provider
    }

    func setClipboardText(_ text: String) {
        clipboardProvider.set(text)
        clipboardNotification = text
    }

    // MARK: Input

    public func input(_ event: KeyEvent) {
        if selection != nil {
            if let cmd = classifyKeyEvent(event), case .insert(let ch) = cmd {
                beginUndoGroup()
                if !deleteSelection() { clearSelection() }
                insertStr(String(ch))
                endUndoGroup()
                return
            }
            switch event.key {
            case .enter:
                beginUndoGroup()
                if !deleteSelection() { clearSelection() }
                insertStr("\n")
                endUndoGroup()
                return
            case .backspace, .delete:
                if deleteSelection() { return }
                clearSelection()
            case .char(let ch) where ch == "x" && event.modifiers == [.control]:
                if let t = selectedText() { setClipboardText(t) }
                if deleteSelection() { return }
                clearSelection()
            default:
                clearSelection()
            }
        }

        if let command = classifyKeyEvent(event) {
            applyClassifiedCommand(command)
            return
        }

        if isUndoInput(event) {
            undo()
            return
        }

        let mods = event.modifiers
        switch event.key {
        case .enter:
            insertStr("\n")
        case .char(let ch) where (ch == "j" || ch == "m") && mods == [.control]:
            insertStr("\n")
        case .char(let ch) where ch == "y" && mods == [.control]:
            yank()
        case .char(let ch) where (ch == "Z" || ch == "z")
            && mods.contains(.shift)
            && (mods.contains(.control) || mods.contains(.superKey) || mods.contains(.meta)):
            redo()
        case .char(let ch) where ch == "r" && mods == [.control]:
            redo()
        case .char(let ch) where ch == "v" && mods == [.control]:
            if let t = clipboardProvider.get() { insertStr(t) }
        case .left where mods.contains(.superKey) || mods.contains(.meta):
            moveCursorToBeginningOfLine(moveUpAtBOL: false)
        case .right where mods.contains(.superKey) || mods.contains(.meta):
            moveCursorToEndOfLine(moveDownAtEOL: false)
        case .up:
            moveCursorUp()
        case .down:
            moveCursorDown()
        case .char(let ch) where ch == "p" && mods == [.control]:
            moveCursorUp()
        case .char(let ch) where ch == "n" && mods == [.control]:
            moveCursorDown()
        case .home:
            moveCursorToBeginningOfLine(moveUpAtBOL: false)
        case .end:
            moveCursorToEndOfLine(moveDownAtEOL: false)
        default:
            break
        }
    }

    private func applyClassifiedCommand(_ command: EditCommand) {
        if case .insert(let ch) = command {
            insertStr(String(ch))
            return
        }
        let kind: MutationKind?
        switch command.category {
        case .insert: kind = .insert
        case .navigation: kind = nil
        case .delete: kind = .delete
        case .kill: kind = .kill
        }
        applyEditCommand(command, kind)
    }

    // MARK: Movement / editing API

    public func deleteBackward(_ n: Int = 1) {
        guard n > 0 else { return }
        if n == 1 {
            applyEditCommand(.deleteGraphemeBackward, .delete)
            return
        }
        beginUndoGroup()
        for _ in 0..<n {
            if case .unchanged = applyEditCommand(.deleteGraphemeBackward, .delete) { break }
        }
        endUndoGroup()
    }

    public func deleteForward(_ n: Int = 1) {
        guard n > 0 else { return }
        if n == 1 {
            applyEditCommand(.deleteGraphemeForward, .delete)
            return
        }
        beginUndoGroup()
        for _ in 0..<n {
            if case .unchanged = applyEditCommand(.deleteGraphemeForward, .delete) { break }
        }
        endUndoGroup()
    }

    public func deleteBackwardWord() {
        applyEditCommand(.deleteWordBackward(.small), .kill)
    }

    public func deleteBackwardUnixWord() {
        applyEditCommand(.deleteWordBackward(.whitespaceDelimited), .kill)
    }

    public func deleteForwardWord() {
        applyEditCommand(.deleteWordForward(.small), .kill)
    }

    public func killToEndOfLine() {
        applyEditCommand(.deleteToLineEnd, .kill)
    }

    public func killToBeginningOfLine() {
        applyEditCommand(.deleteToLineStart, .kill)
    }

    public func yank() {
        guard !killBuffer.isEmpty else { return }
        let text = killBuffer
        applyEditReplacement(cursor..<cursor, text, .insert)
        if let last = text.last { undo.lastInsertWS = last.isWhitespace }
    }

    public func moveCursorLeft() { applyEditCommand(.moveGraphemeLeft, nil) }
    public func moveCursorRight() { applyEditCommand(.moveGraphemeRight, nil) }

    public func moveCursorUp() {
        scrollOverrideStorage = nil
        ensureWrapCache(width: wrapCache?.width ?? 80)
        if let cache = wrapCache, let idx = wrappedLineIndex(cache.lines, cursor) {
            let cur = cache.lines[idx]
            let targetCol = preferredColStorage ?? plainDisplayWidth(
                buffer.text.substring(utf8Range: cur.lowerBound..<cursor),
                tabWidth: tabWidth
            )
            if idx > 0 {
                preferredColStorage = preferredColStorage ?? targetCol
                let prev = cache.lines[idx - 1]
                moveToDisplayCol(on: prev, targetCol: targetCol)
                return
            } else {
                _ = buffer.setCursorByte(0)
                preferredColStorage = nil
                return
            }
        }
        // Logical fallback via LF byte scan
        let bytes = Array(buffer.text.utf8)
        var i = cursor
        while i > 0 {
            i -= 1
            if bytes[i] == 0x0A {
                let prevEnd = i
                var prevStart = 0
                var j = i
                while j > 0 {
                    j -= 1
                    if bytes[j] == 0x0A { prevStart = j + 1; break }
                }
                let targetCol = preferredColStorage ?? currentDisplayCol()
                preferredColStorage = preferredColStorage ?? targetCol
                moveToDisplayCol(on: prevStart..<prevEnd, targetCol: targetCol)
                return
            }
        }
        _ = buffer.setCursorByte(0)
        preferredColStorage = nil
    }

    public func moveCursorDown() {
        scrollOverrideStorage = nil
        ensureWrapCache(width: wrapCache?.width ?? 80)
        if let cache = wrapCache, let idx = wrappedLineIndex(cache.lines, cursor) {
            let cur = cache.lines[idx]
            let targetCol = preferredColStorage ?? plainDisplayWidth(
                buffer.text.substring(utf8Range: cur.lowerBound..<cursor),
                tabWidth: tabWidth
            )
            if idx + 1 < cache.lines.count {
                preferredColStorage = preferredColStorage ?? targetCol
                moveToDisplayCol(on: cache.lines[idx + 1], targetCol: targetCol)
                return
            } else {
                _ = buffer.setCursorByte(buffer.count)
                preferredColStorage = nil
                return
            }
        }
        let bytes = Array(buffer.text.utf8)
        var i = cursor
        while i < bytes.count {
            if bytes[i] == 0x0A {
                let nextStart = i + 1
                var nextEnd = bytes.count
                var j = nextStart
                while j < bytes.count {
                    if bytes[j] == 0x0A { nextEnd = j; break }
                    j += 1
                }
                let targetCol = preferredColStorage ?? currentDisplayCol()
                preferredColStorage = preferredColStorage ?? targetCol
                moveToDisplayCol(on: nextStart..<nextEnd, targetCol: targetCol)
                return
            }
            i += 1
        }
        _ = buffer.setCursorByte(buffer.count)
        preferredColStorage = nil
    }

    public func moveCursorToBeginningOfLine(moveUpAtBOL: Bool) {
        scrollOverrideStorage = nil
        let bol = beginningOfCurrentLine()
        if moveUpAtBOL && cursor == bol && bol > 0 {
            _ = buffer.setCursorByte(bol - 1)
            let newBOL = beginningOfCurrentLine()
            _ = buffer.setCursorByte(newBOL)
        } else {
            _ = buffer.setCursorByte(bol)
        }
        preferredColStorage = nil
    }

    public func moveCursorToEndOfLine(moveDownAtEOL: Bool) {
        scrollOverrideStorage = nil
        let eol = endOfCurrentLine()
        if moveDownAtEOL && cursor == eol && eol < buffer.count {
            _ = buffer.setCursorByte(eol + 1)
            let newEOL = endOfCurrentLine()
            _ = buffer.setCursorByte(newEOL)
        } else {
            _ = buffer.setCursorByte(eol)
        }
        preferredColStorage = nil
    }

    // MARK: Elements

    @discardableResult
    public func insertElement(kind: ElementKind, text: String, displayText: String? = nil) -> ElementId {
        let expanded = expandTabs(text, tabWidth: tabWidth)
        let start = cursor
        preMutate(.element)
        let plan = buffer.planReplaceByteRange(start..<start, replacement: expanded, atomic: elementRanges())
        _ = buffer.applyValidatedPlan(plan)
        let id = ElementId(raw: nextElementId)
        nextElementId += 1
        let range = start..<(start + expanded.utf8Count)
        elements.append(TextElement(id: id, range: range, kind: kind, displayText: displayText))
        wrapCache = nil
        preferredColStorage = nil
        postMutate()
        return id
    }

    public func elementAtCursor() -> TextElement? {
        elements.first { cursor >= $0.range.lowerBound && cursor < $0.range.upperBound }
    }

    public var allElements: [TextElement] { elements }

    // MARK: Wrap / viewport

    public func ensureWrapCache(width: Int) {
        let w = max(width, 1)
        if let cache = wrapCache, cache.width == w { return }
        // Match Rust textarea wrap cache: FirstFit (not OptimalFit).
        let opts = WrapOptions(
            width: w,
            breakWords: true,
            wrapAlgorithm: .firstFit,
            wordSeparator: .unicodeBreakProperties,
            wordSplitter: .hyphenSplitter
        )
        wrapCache = (w, wrapRanges(buffer.text, options: opts))
    }

    public func wrappedLines(width: Int) -> [Range<Int>] {
        ensureWrapCache(width: width)
        return wrapCache?.lines ?? []
    }

    public func desiredHeight(width: Int) -> Int {
        max(1, wrappedLines(width: width).count)
    }

    public func singleLineViewport(displayWidth: Int) -> SingleLineViewport {
        buffer.singleLineViewport(displayWidth: displayWidth, atomic: elementRanges())
    }

    // MARK: Undo / redo

    public func clearHistory() {
        undo.stack.removeAll()
        undo.redo.removeAll()
        undo.lastKind = nil
    }

    @discardableResult
    public func undo() -> Bool {
        guard let entry = undo.stack.popLast() else { return false }
        undo.redo.append(snapshot())
        restore(entry)
        undo.lastKind = nil
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let entry = undo.redo.popLast() else { return false }
        undo.stack.append(snapshot())
        restore(entry)
        undo.lastKind = nil
        return true
    }

    public var canUndo: Bool { !undo.stack.isEmpty }
    public var canRedo: Bool { !undo.redo.isEmpty }

    public func beginUndoGroup() {
        if undo.groupDepth == 0 {
            undo.groupCheckpoint = snapshot()
        }
        undo.groupDepth += 1
    }

    public func endUndoGroup() {
        guard undo.groupDepth > 0 else { return }
        undo.groupDepth -= 1
        if undo.groupDepth == 0, let cp = undo.groupCheckpoint {
            pushUndo(cp)
            undo.groupCheckpoint = nil
            undo.redo.removeAll()
        }
    }

    public func cancelUndoGroup() {
        guard undo.groupDepth > 0 else { return }
        undo.groupDepth = 0
        if let cp = undo.groupCheckpoint {
            restore(cp)
            undo.groupCheckpoint = nil
        }
    }

    // MARK: Private edit plumbing

    private func elementRanges() -> [Range<Int>] {
        elements.map(\.range)
    }

    private func applyEditReplacement(_ range: Range<Int>, _ replacement: String, _ kind: MutationKind?) {
        let expanded = expandTabs(replacement, tabWidth: tabWidth)
        let plan = buffer.planReplaceByteRange(range, replacement: expanded, atomic: elementRanges())
        applyEditPlan(plan, kind)
    }

    @discardableResult
    private func applyEditCommand(_ command: EditCommand, _ kind: MutationKind?) -> EditOutcome {
        let plan = buffer.planCommand(command, atomic: elementRanges())
        let outcome = applyEditPlan(plan, kind)
        if command.category == .navigation {
            preferredColStorage = nil
            scrollOverrideStorage = nil
        }
        return outcome
    }

    @discardableResult
    private func applyEditPlan(_ plan: EditPlan, _ kind: MutationKind?) -> EditOutcome {
        let semantic = plan.removedText != plan.replacement || !plan.replacedByteRange.isEmpty
        if semantic, let kind {
            preMutate(kind)
        }
        let replaced = plan.replacedByteRange
        let insertedLen = plan.replacement.utf8Count
        let outcome = buffer.applyValidatedPlan(plan)
        if semantic {
            updateElementsAfterReplace(replacedStart: replaced.lowerBound, replacedEnd: replaced.upperBound, insertedLen: insertedLen)
            if var sel = selection {
                sel.anchor = adjustPosition(sel.anchor, replaced: replaced, insertedLen: insertedLen)
                sel.head = adjustPosition(sel.head, replaced: replaced, insertedLen: insertedLen)
                selection = sel.anchor == sel.head ? nil : sel
            }
            wrapCache = nil
            if kind == .kill {
                killBuffer = plan.removedText
            }
        }
        if semantic || outcome != .unchanged {
            preferredColStorage = nil
            scrollOverrideStorage = nil
        }
        if semantic, kind != nil {
            postMutate()
        }
        return outcome
    }

    private func adjustPosition(_ position: Int, replaced: Range<Int>, insertedLen: Int) -> Int {
        if position < replaced.lowerBound { return position }
        if position <= replaced.upperBound { return replaced.lowerBound + insertedLen }
        return position - (replaced.upperBound - replaced.lowerBound) + insertedLen
    }

    private func updateElementsAfterReplace(replacedStart: Int, replacedEnd: Int, insertedLen: Int) {
        let delta = insertedLen - (replacedEnd - replacedStart)
        elements = elements.compactMap { el in
            var e = el
            if e.range.upperBound <= replacedStart {
                return e
            }
            if e.range.lowerBound >= replacedEnd {
                e.range = (e.range.lowerBound + delta)..<(e.range.upperBound + delta)
                return e
            }
            // Overlaps edit — drop element (destroyed by edit)
            return nil
        }
    }

    func clampPosToNearestBoundary(_ pos: Int) -> Int {
        for el in elements {
            if pos > el.range.lowerBound && pos < el.range.upperBound {
                if pos - el.range.lowerBound <= el.range.upperBound - pos {
                    return el.range.lowerBound
                }
                return el.range.upperBound
            }
        }
        return pos
    }

    private func beginningOfCurrentLine() -> Int {
        let bytes = Array(buffer.text.utf8)
        var i = cursor
        while i > 0 {
            i -= 1
            if bytes[i] == 0x0A { return i + 1 }
        }
        return 0
    }

    private func endOfCurrentLine() -> Int {
        let bytes = Array(buffer.text.utf8)
        var i = cursor
        while i < bytes.count {
            if bytes[i] == 0x0A { return i }
            i += 1
        }
        return buffer.count
    }

    private func currentDisplayCol() -> Int {
        let bol = beginningOfCurrentLine()
        return plainDisplayWidth(buffer.text.substring(utf8Range: bol..<cursor), tabWidth: tabWidth)
    }

    private func moveToDisplayCol(on line: Range<Int>, targetCol: Int) {
        var col = 0
        var pos = line.lowerBound
        let text = buffer.text
        while pos < line.upperBound {
            let next = text.nextGraphemeBoundary(byte: pos)
            let g = text.substring(utf8Range: pos..<next)
            let w = graphemeDisplayWidth(g, tabWidth: tabWidth)
            if col + w > targetCol { break }
            col += w
            pos = next
        }
        _ = buffer.setCursorByte(pos)
    }

    func wrappedLineIndex(_ lines: [Range<Int>], _ pos: Int) -> Int? {
        for (i, r) in lines.enumerated() {
            if pos >= r.lowerBound && pos <= r.upperBound {
                // Prefer line where pos is not only the end of previous unless last
                if pos == r.upperBound && i + 1 < lines.count && lines[i + 1].lowerBound == pos {
                    continue
                }
                return i
            }
        }
        // Fallback: last line starting at or before pos
        return lines.lastIndex(where: { $0.lowerBound <= pos })
    }

    private func snapshot() -> UndoEntry {
        UndoEntry(text: buffer.text, cursor: cursor, elements: elements)
    }

    private func restore(_ entry: UndoEntry) {
        buffer = EditBuffer.fromParts(text: entry.text, cursorByte: entry.cursor)
        elements = entry.elements
        wrapCache = nil
        preferredColStorage = nil
    }

    private func preMutate(_ kind: MutationKind) {
        if undo.groupDepth > 0 { return }
        let shouldCheckpoint: Bool
        if undo.lastKind == nil {
            shouldCheckpoint = true
        } else if kind == .kill || kind == .element || kind == .replace {
            shouldCheckpoint = true
        } else if undo.lastKind != kind {
            shouldCheckpoint = true
        } else if undo.lastCursor != cursor {
            shouldCheckpoint = true
        } else {
            shouldCheckpoint = false
        }
        if shouldCheckpoint {
            pushUndo(snapshot())
            undo.redo.removeAll()
        }
        undo.lastKind = kind
    }

    private func postMutate() {
        undo.lastCursor = cursor
    }

    private func pushUndo(_ entry: UndoEntry) {
        undo.stack.append(entry)
        if undo.stack.count > undo.maxDepth {
            undo.stack.removeFirst(undo.stack.count - undo.maxDepth)
        }
    }
}
