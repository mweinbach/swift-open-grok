import Foundation
import OpenGrokTerminalCore

// MARK: - Transcript text selection (scrollback/text_selection.rs at pin 650c1db7)
//
// Pure geometry, hit-testing, reconstruction, and highlight helpers. Table-cell
// / table-grid kinds resolve from `PagerTableGeometry`; missing geometry fails
// closed to linear (kind) or no paint/copy (table-shaped overlay). Sticky-header
// drag-start / text-select is deferred — sticky rows are painted but not
// published as selectable lines.

/// Rows of near-edge interior zone that still trigger autoscroll
/// (`EDGE_THRESHOLD`, text_selection.rs:41).
public let pagerTextSelectionAutoscrollEdge = 2

/// Multi-click identity window (`MULTI_CLICK_TIMEOUT_MS`, agent_view/mod.rs:453).
public let pagerTextSelectionMultiClickTimeoutMs: UInt64 = 300

/// Flash highlight TTL (`DEFAULT_SELECTION_HIGHLIGHT_DURATION_MS`,
/// agent_view/mod.rs:463).
public let pagerTextSelectionFlashTTLMs: UInt64 = 150

/// tmux default `word-separators` minus underscore
/// (`DEFAULT_WORD_SEPARATORS`, text_selection.rs:1053).
public let pagerDefaultWordSeparators = "!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~"

/// Direction for timer-driven drag auto-scroll.
public enum PagerTextSelectionAutoScrollDirection: Sendable, Equatable, Hashable {
    case up
    case down
}

/// Autoscroll state recomputed from the pointer vs a pane rect
/// (`DragAutoScrollState`, text_selection.rs:34-38).
public struct PagerTextSelectionAutoScrollState: Sendable, Equatable, Hashable {
    public var direction: PagerTextSelectionAutoScrollDirection
    /// Rows to scroll per tick.
    public var speed: Int

    public init(direction: PagerTextSelectionAutoScrollDirection, speed: Int) {
        self.direction = direction
        self.speed = max(0, speed)
    }
}

/// Stable hit into a selectable range (`RangeHit`, text_selection.rs:208-216).
public struct PagerTextRangeHit: Sendable, Equatable, Hashable {
    public var entryIndex: Int
    public var rangeID: UInt16
    /// Line index within the block's full painted output (stable across scroll).
    public var blockLineIndex: Int
    /// Display column within the line's selectable span.
    public var colWithinRange: Int

    public init(entryIndex: Int, rangeID: UInt16, blockLineIndex: Int, colWithinRange: Int) {
        self.entryIndex = entryIndex
        self.rangeID = rangeID
        self.blockLineIndex = blockLineIndex
        self.colWithinRange = max(0, colWithinRange)
    }
}

/// One endpoint of a selection (`SelectionEndpoint`, text_selection.rs:240-243).
public struct PagerTextSelectionEndpoint: Sendable, Equatable, Hashable {
    public var blockLineIndex: Int
    public var colWithinRange: Int

    public init(blockLineIndex: Int, colWithinRange: Int) {
        self.blockLineIndex = blockLineIndex
        self.colWithinRange = max(0, colWithinRange)
    }
}

/// How a persistent selection was created (`SelectionOrigin`).
public enum PagerTextSelectionOrigin: Sendable, Equatable, Hashable {
    case drag
    case doubleClick
    case tripleClick
}

/// Shape of a text selection: `linear` sweeps whole lines between the
/// endpoints; drags anchored inside a detected table cell are table-shaped
/// (`PagerTableGeometry`).
public enum PagerTextSelectionKind: Sendable, Equatable, Hashable {
    case linear
    /// Head latched to the anchor cell: text selection clamped to the cell's
    /// column band, spanning its wrapped fragment lines.
    case tableCell
    /// A rectangular range of whole cells (`anchor` to `head`), copied as
    /// TSV. Cells are carried, not re-derived: endpoints can sit on columns
    /// that resolve to no cell, and paint/copy must match resolution.
    case tableGrid(anchor: PagerTableCellRef, head: PagerTableCellRef)
}

/// Pending left-down before the drag threshold (`PendingTextDrag`).
public struct PagerPendingTextDrag: Sendable, Equatable, Hashable {
    public var anchor: PagerTextRangeHit
    public var startCol: Int
    public var startRow: Int
    public var anchorContentWidth: Int?

    public init(
        anchor: PagerTextRangeHit,
        startCol: Int,
        startRow: Int,
        anchorContentWidth: Int? = nil
    ) {
        self.anchor = anchor
        self.startCol = startCol
        self.startRow = startRow
        self.anchorContentWidth = anchorContentWidth
    }
}

/// Active text drag (`ActiveTextDrag`).
public struct PagerActiveTextDrag: Sendable, Equatable, Hashable {
    public var anchor: PagerTextRangeHit
    public var head: PagerTextRangeHit
    public var kind: PagerTextSelectionKind
    public var anchorContentWidth: Int?

    public init(
        anchor: PagerTextRangeHit,
        head: PagerTextRangeHit,
        kind: PagerTextSelectionKind = .linear,
        anchorContentWidth: Int? = nil
    ) {
        self.anchor = anchor
        self.head = head
        self.kind = kind
        self.anchorContentWidth = anchorContentWidth
    }
}

/// Persistent selection after mouse-up (`PersistentTextSelection`).
public struct PagerPersistentTextSelection: Sendable, Equatable, Hashable {
    public var entryIndex: Int
    public var rangeID: UInt16
    public var anchor: PagerTextSelectionEndpoint
    public var head: PagerTextSelectionEndpoint
    public var origin: PagerTextSelectionOrigin
    public var kind: PagerTextSelectionKind

    public init(
        entryIndex: Int,
        rangeID: UInt16,
        anchor: PagerTextSelectionEndpoint,
        head: PagerTextSelectionEndpoint,
        origin: PagerTextSelectionOrigin,
        kind: PagerTextSelectionKind = .linear
    ) {
        self.entryIndex = entryIndex
        self.rangeID = rangeID
        self.anchor = anchor
        self.head = head
        self.origin = origin
        self.kind = kind
    }
}

/// Frame input for painting an active or persistent text highlight.
public enum PagerTextSelectionHighlight: Sendable, Equatable, Hashable {
    case active(PagerActiveTextDrag)
    case persistent(PagerPersistentTextSelection)
}

/// `[ui] keep_text_selection` mode
/// (`appearance/text_selection.rs` TextSelection).
public enum PagerKeepTextSelectionMode: String, Sendable, Equatable, Hashable {
    case flash
    case hold
    case wordSelect = "word_select"

    public var canonical: String { rawValue }

    public static func fromCanonical(_ value: String) -> PagerKeepTextSelectionMode? {
        PagerKeepTextSelectionMode(rawValue: value)
    }

    /// Never timer-dismiss (`hold` / `word_select`).
    public var holds: Bool {
        switch self {
        case .hold, .wordSelect: return true
        case .flash: return false
        }
    }

    /// Double-click selects a word (`word_select` only).
    public var selectsWord: Bool {
        self == .wordSelect
    }
}

/// Prior text-click identity for multi-click counting.
public struct PagerTextClickIdentity: Sendable, Equatable, Hashable {
    public var entryIndex: Int
    public var rangeID: UInt16
    public var blockLineIndex: Int
    public var timeMs: UInt64
    public var clickCount: UInt8

    public init(
        entryIndex: Int,
        rangeID: UInt16,
        blockLineIndex: Int,
        timeMs: UInt64,
        clickCount: UInt8 = 1
    ) {
        self.entryIndex = entryIndex
        self.rangeID = rangeID
        self.blockLineIndex = blockLineIndex
        self.timeMs = timeMs
        self.clickCount = max(1, clickCount)
    }
}

/// Visible block hit geometry (`VisibleBlockGeometry`).
public struct PagerVisibleBlockGeometry: Sendable, Equatable, Hashable {
    public var entryIndex: Int
    public var area: TerminalRect
    public var contentArea: TerminalRect
    public var selectionArea: TerminalRect
    public var contentWidth: Int
    public var topClipped: Bool
    public var bottomClipped: Bool
    public var dragStartable: Bool

    public init(
        entryIndex: Int,
        area: TerminalRect,
        contentArea: TerminalRect,
        selectionArea: TerminalRect,
        contentWidth: Int,
        topClipped: Bool,
        bottomClipped: Bool,
        dragStartable: Bool
    ) {
        self.entryIndex = entryIndex
        self.area = area
        self.contentArea = contentArea
        self.selectionArea = selectionArea
        self.contentWidth = max(0, contentWidth)
        self.topClipped = topClipped
        self.bottomClipped = bottomClipped
        self.dragStartable = dragStartable
    }
}

/// One selectable line — screen geometry when visible; text/joiner/cols always
/// present so copy can reconstruct across off-screen lines
/// (`ResolvedSelectableLine`).
public struct PagerSelectableLine: Sendable, Equatable, Hashable {
    public var entryIndex: Int
    public var rangeID: UInt16
    public var blockLineIndex: Int
    /// Absolute screen row when this line is painted in the content band;
    /// `nil` when off-screen (or sticky-only — not drag-startable this phase).
    public var screenY: Int?
    public var screenX: Int
    /// Display-column range of selectable text within the content row
    /// (`selectable_cols`).
    public var selectableCols: Range<Int>
    public var text: String
    public var joinerToPrevious: String?

    public init(
        entryIndex: Int,
        rangeID: UInt16,
        blockLineIndex: Int,
        screenY: Int?,
        screenX: Int,
        selectableCols: Range<Int>,
        text: String,
        joinerToPrevious: String? = nil
    ) {
        self.entryIndex = entryIndex
        self.rangeID = rangeID
        self.blockLineIndex = blockLineIndex
        self.screenY = screenY
        self.screenX = screenX
        self.selectableCols = selectableCols
        self.text = text
        self.joinerToPrevious = joinerToPrevious
    }

    public var isOnScreen: Bool { screenY != nil }

    /// `(col distance, clamped col-within-range)` — single source of column
    /// semantics for every hit test (`col_metrics`, text_selection.rs:174-193).
    func colMetrics(col: Int) -> (distance: Int, colWithinRange: Int)? {
        let start = screenX + selectableCols.lowerBound
        let end = screenX + selectableCols.upperBound
        guard end > start else { return nil }
        let width = end - start
        if col < start {
            return (start - col, 0)
        }
        if col >= end {
            return (col - (end - 1), width - 1)
        }
        return (0, col - start)
    }
}

/// Contiguous selectable lines sharing `(entryIndex, rangeID)`.
public struct PagerSelectableRange: Sendable, Equatable, Hashable {
    public var entryIndex: Int
    public var rangeID: UInt16
    public var lines: [PagerSelectableLine]

    public init(entryIndex: Int, rangeID: UInt16, lines: [PagerSelectableLine] = []) {
        self.entryIndex = entryIndex
        self.rangeID = rangeID
        self.lines = lines
    }
}

/// Per-frame resolved selection metadata (`ResolvedSelectionModel`).
///
/// `contentArea` excludes the sticky header band. Autoscroll callers may pass
/// the full conversation pane instead (`pane_areas.scrollback` upstream).
public struct PagerTextSelectionModel: Sendable, Equatable {
    public var ranges: [PagerSelectableRange]
    public var visibleBlocks: [PagerVisibleBlockGeometry]
    /// Sticky-excluded content band — text hits outside this are rejected.
    public var contentArea: TerminalRect
    /// Full conversation pane (autoscroll may use this).
    public var conversationArea: TerminalRect

    public init(
        ranges: [PagerSelectableRange] = [],
        visibleBlocks: [PagerVisibleBlockGeometry] = [],
        contentArea: TerminalRect = TerminalRect(x: 0, y: 0, width: 0, height: 0),
        conversationArea: TerminalRect = TerminalRect(x: 0, y: 0, width: 0, height: 0)
    ) {
        self.ranges = ranges
        self.visibleBlocks = visibleBlocks
        self.contentArea = contentArea
        self.conversationArea = conversationArea
    }

    public mutating func pushLine(_ line: PagerSelectableLine) {
        if var last = ranges.last,
           last.entryIndex == line.entryIndex,
           last.rangeID == line.rangeID
        {
            last.lines.append(line)
            ranges[ranges.count - 1] = last
            return
        }
        ranges.append(PagerSelectableRange(
            entryIndex: line.entryIndex,
            rangeID: line.rangeID,
            lines: [line]
        ))
    }

    public func range(entryIndex: Int, rangeID: UInt16) -> PagerSelectableRange? {
        ranges.first { $0.entryIndex == entryIndex && $0.rangeID == rangeID }
    }

    public func line(for hit: PagerTextRangeHit) -> PagerSelectableLine? {
        range(entryIndex: hit.entryIndex, rangeID: hit.rangeID)?
            .lines
            .first { $0.blockLineIndex == hit.blockLineIndex }
    }

    /// Exact hit on selectable columns only (`hit_test_text_exact`).
    /// Sticky header band (above `contentArea`) never hits.
    public func hitTestTextExact(col: Int, row: Int) -> PagerTextRangeHit? {
        guard contentAreaContains(col: col, row: row) else { return nil }
        for range in ranges {
            for line in range.lines {
                guard let screenY = line.screenY, screenY == row else { continue }
                guard let (distance, colWithin) = line.colMetrics(col: col), distance == 0 else {
                    continue
                }
                return PagerTextRangeHit(
                    entryIndex: range.entryIndex,
                    rangeID: range.rangeID,
                    blockLineIndex: line.blockLineIndex,
                    colWithinRange: colWithin
                )
            }
        }
        return nil
    }

    /// Same-row exact or nearest-column clamp (`hit_test_selectable_range`).
    /// Rows in the sticky header band (`row < contentArea.y`) never hit.
    public func hitTestSelectableRange(col: Int, row: Int) -> PagerTextRangeHit? {
        if contentArea.height > 0, row < contentArea.y {
            return nil
        }
        var best: (distance: Int, hit: PagerTextRangeHit)?
        for range in ranges {
            for line in range.lines {
                guard let screenY = line.screenY, screenY == row else { continue }
                guard let (distance, colWithin) = line.colMetrics(col: col) else { continue }
                let hit = PagerTextRangeHit(
                    entryIndex: range.entryIndex,
                    rangeID: range.rangeID,
                    blockLineIndex: line.blockLineIndex,
                    colWithinRange: colWithin
                )
                if distance == 0 { return hit }
                if best == nil || distance < best!.distance {
                    best = (distance, hit)
                }
            }
        }
        return best?.hit
    }

    /// Nearest line of the anchor's range — drag-head resolver with
    /// tie-away-from-anchor (`hit_test_nearest_in_range`).
    public func hitTestNearestInRange(
        anchor: PagerTextRangeHit,
        col: Int,
        row: Int
    ) -> PagerTextRangeHit? {
        guard let range = range(entryIndex: anchor.entryIndex, rangeID: anchor.rangeID) else {
            return nil
        }
        var best: (key: (Int, Int), anchorDistance: Int, hit: PagerTextRangeHit)?
        for line in range.lines {
            guard let screenY = line.screenY else { continue }
            guard let (colDistance, colWithin) = line.colMetrics(col: col) else { continue }
            let key = (abs(screenY - row), colDistance)
            let anchorDistance = abs(line.blockLineIndex - anchor.blockLineIndex)
            let hit = PagerTextRangeHit(
                entryIndex: range.entryIndex,
                rangeID: range.rangeID,
                blockLineIndex: line.blockLineIndex,
                colWithinRange: colWithin
            )
            if let current = best {
                if key.0 < current.key.0
                    || (key.0 == current.key.0 && key.1 < current.key.1)
                    || (key == current.key && anchorDistance > current.anchorDistance)
                {
                    best = (key, anchorDistance, hit)
                }
            } else {
                best = (key, anchorDistance, hit)
            }
        }
        return best?.hit
    }

    public func hitTestVisibleBlock(col: Int, row: Int) -> PagerVisibleBlockGeometry? {
        visibleBlocks.first { $0.area.contains(x: col, y: row) }
    }

    public func visibleBlockContentWidth(entryIndex: Int) -> Int? {
        visibleBlocks.first { $0.entryIndex == entryIndex }?.contentWidth
    }

    private func contentAreaContains(col: Int, row: Int) -> Bool {
        // Sticky header short-circuit: anything above the content band is out.
        if contentArea.height > 0, row < contentArea.y { return false }
        return contentArea.contains(x: col, y: row)
    }
}

// MARK: - Autoscroll / threshold

/// Compute autoscroll from mouse row vs a pane (`compute_autoscroll`).
/// Pass the full conversation rect when sticky headers are active — upstream
/// uses `pane_areas.scrollback`, not the sticky-excluded content band.
public func pagerComputeTextSelectionAutoscroll(
    mouseRow: Int,
    contentArea: TerminalRect
) -> PagerTextSelectionAutoScrollState? {
    let top = contentArea.y
    let bottom = contentArea.y + contentArea.height
    guard contentArea.height > 0 else { return nil }
    let edge = pagerTextSelectionAutoscrollEdge

    if mouseRow < top + edge {
        let distance = (top + edge) - mouseRow
        return PagerTextSelectionAutoScrollState(
            direction: .up,
            speed: pagerTextSelectionAutoscrollSpeed(distance: distance)
        )
    }
    if mouseRow >= bottom - edge {
        let distance = mouseRow - (bottom - edge) + 1
        return PagerTextSelectionAutoScrollState(
            direction: .down,
            speed: pagerTextSelectionAutoscrollSpeed(distance: distance)
        )
    }
    return nil
}

/// Speed ladder 1 / 2 / 3 / 5 (`speed_for_distance`, text_selection.rs:79-86).
public func pagerTextSelectionAutoscrollSpeed(distance: Int) -> Int {
    switch max(0, distance) {
    case 0...2: return 1
    case 3...5: return 2
    case 6...10: return 3
    default: return 5
    }
}

/// `dx >= 1 || dy >= 1` (`drag_threshold_exceeded`).
public func pagerTextDragThresholdExceeded(
    pending: PagerPendingTextDrag,
    col: Int,
    row: Int
) -> Bool {
    abs(pending.startCol - col) >= 1 || abs(pending.startRow - row) >= 1
}

// MARK: - Multi-click identity

/// Count text-level multi-clicks on the same `(entry, range, line)` within
/// `pagerTextSelectionMultiClickTimeoutMs` (`count_text_click`).
public func pagerCountTextClick(
    previous: PagerTextClickIdentity?,
    hit: PagerTextRangeHit,
    nowMs: UInt64
) -> UInt8 {
    guard let previous,
          previous.entryIndex == hit.entryIndex,
          previous.rangeID == hit.rangeID,
          previous.blockLineIndex == hit.blockLineIndex,
          nowMs >= previous.timeMs,
          nowMs - previous.timeMs < pagerTextSelectionMultiClickTimeoutMs
    else {
        return 1
    }
    return previous.clickCount &+ 1
}

public func pagerMakeTextClickIdentity(
    hit: PagerTextRangeHit,
    nowMs: UInt64,
    clickCount: UInt8
) -> PagerTextClickIdentity {
    PagerTextClickIdentity(
        entryIndex: hit.entryIndex,
        rangeID: hit.rangeID,
        blockLineIndex: hit.blockLineIndex,
        timeMs: nowMs,
        clickCount: clickCount
    )
}

// MARK: - Column / Unicode helpers

/// Display width of `text` via extended grapheme clusters.
public func pagerSelectionDisplayWidth(_ text: String) -> Int {
    var width = 0
    for grapheme in text {
        let w = max(0, UnicodeDisplayWidth.width(ofGrapheme: String(grapheme)))
        if w == 0 { continue }
        width += w
    }
    return width
}

/// Slice `text` to display columns `[start, end)` — wide/zero-width safe
/// (`slice_display_cols`, types.rs:325-358). Mid-glyph starts skip the
/// straddling grapheme (no half-glyph copy).
public func pagerSliceDisplayCols(_ text: String, start: Int, end: Int) -> String {
    guard start < end, !text.isEmpty else { return "" }
    var out = ""
    var col = 0
    for grapheme in text {
        let s = String(grapheme)
        let width = max(0, UnicodeDisplayWidth.width(ofGrapheme: s))
        let next = col + width
        if width == 0 {
            if col >= start && col < end {
                out += s
            }
            continue
        }
        if next <= start {
            col = next
            continue
        }
        if col >= end { break }
        if col >= start && next <= end {
            out += s
        }
        col = next
    }
    return out
}

/// Snap a display column to the start of the grapheme that owns it.
/// Past-end clamps to `displayWidth`; empty → 0.
public func pagerSnapDisplayColumn(_ text: String, col: Int) -> Int {
    guard col > 0, !text.isEmpty else { return 0 }
    var current = 0
    for grapheme in text {
        let width = max(0, UnicodeDisplayWidth.width(ofGrapheme: String(grapheme)))
        if width == 0 { continue }
        let next = current + width
        if col < next { return current }
        current = next
    }
    return current
}

// MARK: - Word / URL / line bounds

private enum PagerWordCharClass {
    case word
    case whitespace
    case separator
}

private func pagerClassifyGrapheme(_ grapheme: String, separators: String) -> PagerWordCharClass {
    guard let first = grapheme.unicodeScalars.first else { return .word }
    if Character(first).isWhitespace { return .whitespace }
    if separators.unicodeScalars.contains(first) { return .separator }
    return .word
}

/// tmux-style three-class word boundaries at a display column
/// (`word_boundaries_at_col`).
public func pagerWordBoundariesAtCol(
    _ text: String,
    col: Int,
    separators: String = pagerDefaultWordSeparators
) -> Range<Int> {
    var segments: [(start: Int, end: Int, class: PagerWordCharClass)] = []
    var current = 0
    for grapheme in text {
        let s = String(grapheme)
        let width = max(0, UnicodeDisplayWidth.width(ofGrapheme: s))
        if width == 0 { continue }
        let next = current + width
        segments.append((current, next, pagerClassifyGrapheme(s, separators: separators)))
        current = next
    }
    guard !segments.isEmpty else { return 0..<0 }
    let targetIdx = segments.firstIndex { col >= $0.start && col < $0.end }
        ?? segments.count - 1
    let targetClass = segments[targetIdx].class
    var left = targetIdx
    while left > 0, segments[left - 1].class == targetClass {
        left -= 1
    }
    var right = targetIdx
    while right + 1 < segments.count, segments[right + 1].class == targetClass {
        right += 1
    }
    return segments[left].start..<segments[right].end
}

private let pagerTrailingURLPunct: Set<Character> = [
    ".", ",", ":", ";", "!", "?", ")", "]", "}", ">", "\"", "'"
]

private func pagerStripTrailingURLPunctuation(_ url: Substring) -> Substring {
    var end = url.endIndex
    while end > url.startIndex {
        let lastIndex = url.index(before: end)
        let last = url[lastIndex]
        guard pagerTrailingURLPunct.contains(last) else { break }
        if let open: Character = {
            switch last {
            case ")": return "("
            case "]": return "["
            case "}": return "{"
            case ">": return "<"
            default: return nil
            }
        }() {
            let body = url[..<end]
            let opens = body.filter { $0 == open }.count
            let closes = body.filter { $0 == last }.count
            if opens >= closes { break }
        }
        end = lastIndex
    }
    return url[..<end]
}

/// URL-like run at a display column (`url_range_at_col`). Schemes:
/// `https?://`, `ftp://`, `file://` (case-insensitive).
public func pagerURLRangeAtCol(_ text: String, col: Int) -> Range<Int>? {
    // Rust: `(?i)\b(?:https?|ftp|file)://[^\s\x{00}-\x{1f}]+`
    guard let regex = try? NSRegularExpression(
        pattern: #"(?i)\b(?:https?|ftp|file)://\S+"#,
        options: []
    ) else {
        return nil
    }
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    for match in regex.matches(in: text, options: [], range: full) {
        guard let swiftRange = Range(match.range, in: text) else { continue }
        let raw = text[swiftRange]
        let stripped = pagerStripTrailingURLPunctuation(raw)
        if let schemeEnd = stripped.range(of: "://"),
           stripped[schemeEnd.upperBound...].isEmpty
        {
            continue
        }
        let prefix = String(text[..<swiftRange.lowerBound])
        let colStart = pagerSelectionDisplayWidth(prefix)
        let colEnd = colStart + pagerSelectionDisplayWidth(String(stripped))
        if col >= colStart && col < colEnd {
            return colStart..<colEnd
        }
    }
    return nil
}

/// Word or preferred URL range at a hit (`semantic_selection_at`).
public func pagerSemanticSelectionAt(
    model: PagerTextSelectionModel,
    hit: PagerTextRangeHit,
    separators: String = pagerDefaultWordSeparators
) -> (cols: Range<Int>, text: String)? {
    guard let line = model.line(for: hit) else { return nil }
    let range = pagerURLRangeAtCol(line.text, col: hit.colWithinRange)
        ?? pagerWordBoundariesAtCol(line.text, col: hit.colWithinRange, separators: separators)
    guard !range.isEmpty else { return nil }
    let text = pagerSliceDisplayCols(line.text, start: range.lowerBound, end: range.upperBound)
    return (range, text)
}

/// Full-line selectable column span for triple-click (`select_line_at`).
public func pagerLineBounds(for line: PagerSelectableLine) -> Range<Int>? {
    let width = line.selectableCols.upperBound - line.selectableCols.lowerBound
    guard width > 0 else { return nil }
    return 0..<width
}

// MARK: - Selection value + reconstruction

/// Normalized `(start, end)` endpoints so start ≤ end in document order.
public func pagerNormalizedSelectionOrder(
    anchor: PagerTextSelectionEndpoint,
    head: PagerTextSelectionEndpoint
) -> (start: PagerTextSelectionEndpoint, end: PagerTextSelectionEndpoint) {
    if anchor.blockLineIndex < head.blockLineIndex {
        return (anchor, head)
    }
    if anchor.blockLineIndex > head.blockLineIndex {
        return (head, anchor)
    }
    if anchor.colWithinRange <= head.colWithinRange {
        return (anchor, head)
    }
    return (head, anchor)
}

/// Selected display-column range on one line for linear endpoints
/// (`selected_cols_for_endpoints`).
public func pagerSelectedColsForEndpoints(
    anchor: PagerTextSelectionEndpoint,
    head: PagerTextSelectionEndpoint,
    line: PagerSelectableLine
) -> Range<Int>? {
    let width = max(0, line.selectableCols.upperBound - line.selectableCols.lowerBound)
    let startBL = min(anchor.blockLineIndex, head.blockLineIndex)
    let endBL = max(anchor.blockLineIndex, head.blockLineIndex)
    let bl = line.blockLineIndex
    guard bl >= startBL, bl <= endBL else { return nil }
    let anchorIsStart = anchor.blockLineIndex <= head.blockLineIndex

    if startBL == endBL {
        let start = min(anchor.colWithinRange, head.colWithinRange)
        let end = max(anchor.colWithinRange, head.colWithinRange) + 1
        return min(start, width)..<min(end, width)
    }
    if bl == startBL {
        let start = anchorIsStart ? anchor.colWithinRange : head.colWithinRange
        return min(start, width)..<width
    }
    if bl == endBL {
        let endCol = anchorIsStart ? head.colWithinRange : anchor.colWithinRange
        return 0..<min(endCol + 1, width)
    }
    return 0..<width
}

/// Joined selectable text for one range using the same joiners as
/// `pagerReconstructSelectionText` — soft-wrap fragments concatenate to a
/// stable logical string across reflows when joiners are preserved.
public func pagerJoinedRangeText(
    model: PagerTextSelectionModel,
    entryIndex: Int,
    rangeID: UInt16
) -> String? {
    guard let range = model.range(entryIndex: entryIndex, rangeID: rangeID) else {
        return nil
    }
    var out = ""
    var first = true
    for line in range.lines {
        if !first {
            out += line.joinerToPrevious ?? "\n"
        }
        first = false
        out += line.text
    }
    return first ? nil : out
}

/// UTF-8 byte offset of `hit` into `pagerJoinedRangeText` for that range.
/// Stable across wrap reflows that preserve joiners + fragment text.
public func pagerAbsoluteTextUTF8Offset(
    in model: PagerTextSelectionModel,
    hit: PagerTextRangeHit
) -> Int? {
    guard let range = model.range(entryIndex: hit.entryIndex, rangeID: hit.rangeID) else {
        return nil
    }
    var prefix = ""
    var first = true
    for line in range.lines {
        if !first {
            prefix += line.joinerToPrevious ?? "\n"
        }
        first = false
        if line.blockLineIndex == hit.blockLineIndex {
            prefix += pagerSliceDisplayCols(line.text, start: 0, end: hit.colWithinRange)
            return prefix.utf8.count
        }
        prefix += line.text
    }
    return nil
}

/// Inverse of `pagerAbsoluteTextUTF8Offset` — map a stable offset back into
/// a (possibly reflowed) model's line identity.
public func pagerHitFromAbsoluteTextUTF8Offset(
    in model: PagerTextSelectionModel,
    entryIndex: Int,
    rangeID: UInt16,
    utf8Offset: Int
) -> PagerTextRangeHit? {
    guard let range = model.range(entryIndex: entryIndex, rangeID: rangeID),
          !range.lines.isEmpty
    else { return nil }
    let target = max(0, utf8Offset)
    var consumed = 0
    var first = true
    for (index, line) in range.lines.enumerated() {
        if !first {
            let joiner = line.joinerToPrevious ?? "\n"
            let joinerCount = joiner.utf8.count
            if target < consumed + joinerCount {
                return PagerTextRangeHit(
                    entryIndex: entryIndex,
                    rangeID: rangeID,
                    blockLineIndex: line.blockLineIndex,
                    colWithinRange: 0
                )
            }
            consumed += joinerCount
        }
        first = false
        let lineCount = line.text.utf8.count
        let lineEnd = consumed + lineCount
        let isLast = index == range.lines.count - 1
        if target < lineEnd || (isLast && target >= lineEnd) {
            let within = min(max(0, target - consumed), lineCount)
            let prefixBytes = Array(line.text.utf8.prefix(within))
            let prefix = String(decoding: prefixBytes, as: UTF8.self)
            let col = pagerSelectionDisplayWidth(prefix)
            let width = max(0, line.selectableCols.upperBound - line.selectableCols.lowerBound)
            let colWithin = width > 0 ? min(max(0, col), width - 1) : 0
            return PagerTextRangeHit(
                entryIndex: entryIndex,
                rangeID: rangeID,
                blockLineIndex: line.blockLineIndex,
                colWithinRange: colWithin
            )
        }
        consumed = lineEnd
    }
    return nil
}

/// Translate a hit from one wrap-width model into another via joined-text
/// identity. Falls back to exact block-line match when offsets cannot map.
public func pagerMapTextHit(
    _ hit: PagerTextRangeHit,
    from source: PagerTextSelectionModel,
    to destination: PagerTextSelectionModel
) -> PagerTextRangeHit? {
    if let offset = pagerAbsoluteTextUTF8Offset(in: source, hit: hit),
       let mapped = pagerHitFromAbsoluteTextUTF8Offset(
           in: destination,
           entryIndex: hit.entryIndex,
           rangeID: hit.rangeID,
           utf8Offset: offset
       )
    {
        return mapped
    }
    if destination.line(for: hit) != nil {
        return hit
    }
    return nil
}

/// Reconstruct selected text from model lines/joiners — includes off-screen
/// lines that still carry text (`reconstruct_selection_text` enriched with
/// full-model lines). Table kinds copy via `pagerReconstructTableSelectionText`
/// when geometry is present; missing geometry yields `nil` (no table copy).
/// Empty linear selection → `nil`.
public func pagerReconstructSelectionText(
    model: PagerTextSelectionModel,
    drag: PagerActiveTextDrag,
    table: PagerTableGeometry? = nil
) -> String? {
    switch drag.kind {
    case .linear:
        break
    case .tableCell, .tableGrid:
        let geom = table ?? pagerDetectTableGeometry(
            in: model,
            entryIndex: drag.anchor.entryIndex,
            rangeID: drag.anchor.rangeID,
            atLine: drag.anchor.blockLineIndex
        )
        guard let geom,
              let textAt = pagerSelectionLineTextAt(
                  model: model,
                  entryIndex: drag.anchor.entryIndex,
                  rangeID: drag.anchor.rangeID
              )
        else { return nil }
        return pagerReconstructTableSelectionText(geom, drag: drag, textAt: textAt)
    }
    guard let range = model.range(
        entryIndex: drag.anchor.entryIndex,
        rangeID: drag.anchor.rangeID
    ) else {
        return nil
    }
    let startBL = min(drag.anchor.blockLineIndex, drag.head.blockLineIndex)
    let endBL = max(drag.anchor.blockLineIndex, drag.head.blockLineIndex)
    let anchor = PagerTextSelectionEndpoint(
        blockLineIndex: drag.anchor.blockLineIndex,
        colWithinRange: drag.anchor.colWithinRange
    )
    let head = PagerTextSelectionEndpoint(
        blockLineIndex: drag.head.blockLineIndex,
        colWithinRange: drag.head.colWithinRange
    )

    var out = ""
    var first = true
    for line in range.lines {
        guard line.blockLineIndex >= startBL, line.blockLineIndex <= endBL else { continue }
        guard let cols = pagerSelectedColsForEndpoints(anchor: anchor, head: head, line: line)
        else { continue }
        if !first {
            out += line.joinerToPrevious ?? "\n"
        }
        first = false
        out += pagerSliceDisplayCols(line.text, start: cols.lowerBound, end: cols.upperBound)
    }
    if first { return nil }
    return out
}

/// Reconstruct from a persistent selection value.
public func pagerReconstructSelectionText(
    model: PagerTextSelectionModel,
    selection: PagerPersistentTextSelection,
    table: PagerTableGeometry? = nil
) -> String? {
    let drag = PagerActiveTextDrag(
        anchor: PagerTextRangeHit(
            entryIndex: selection.entryIndex,
            rangeID: selection.rangeID,
            blockLineIndex: selection.anchor.blockLineIndex,
            colWithinRange: selection.anchor.colWithinRange
        ),
        head: PagerTextRangeHit(
            entryIndex: selection.entryIndex,
            rangeID: selection.rangeID,
            blockLineIndex: selection.head.blockLineIndex,
            colWithinRange: selection.head.colWithinRange
        ),
        kind: selection.kind
    )
    return pagerReconstructSelectionText(model: model, drag: drag, table: table)
}

// MARK: - Highlight paint

/// Apply selection band styling to one cell (`apply_selection_highlight`).
public func pagerApplyTextSelectionHighlight(
    theme: PagerRenderTheme,
    to cell: inout Cell
) {
    if theme.textPrimary == .reset || theme.bgBase == .reset {
        cell.style.insert(.reverse)
        return
    }
    cell.style.remove(.reverse)
    cell.foreground = theme.bgBase
    cell.background = theme.textPrimary
}

/// Paint selection highlight into `buffer`, clipped to `clipArea`
/// (sticky-excluded content band). Table kinds need a matching keyed
/// sidecar (or an explicit `table` for unit tests); without it they paint
/// nothing rather than a linear sweep. Live detect must equal the sidecar
/// when present — a different grid is a mismatch, not a replacement.
public func pagerPaintTextSelectionHighlight(
    model: PagerTextSelectionModel,
    highlight: PagerTextSelectionHighlight,
    theme: PagerRenderTheme,
    clipArea: TerminalRect,
    buffer: inout CellBuffer,
    table: PagerTableGeometry? = nil,
    tableSidecar: PagerTableSelectionGeometry? = nil
) {
    let entryIndex: Int
    let rangeID: UInt16
    let anchor: PagerTextSelectionEndpoint
    let head: PagerTextSelectionEndpoint
    let kind: PagerTextSelectionKind
    switch highlight {
    case .active(let drag):
        entryIndex = drag.anchor.entryIndex
        rangeID = drag.anchor.rangeID
        kind = drag.kind
        anchor = PagerTextSelectionEndpoint(
            blockLineIndex: drag.anchor.blockLineIndex,
            colWithinRange: drag.anchor.colWithinRange
        )
        head = PagerTextSelectionEndpoint(
            blockLineIndex: drag.head.blockLineIndex,
            colWithinRange: drag.head.colWithinRange
        )
    case .persistent(let selection):
        entryIndex = selection.entryIndex
        rangeID = selection.rangeID
        kind = selection.kind
        anchor = selection.anchor
        head = selection.head
    }
    guard let range = model.range(entryIndex: entryIndex, rangeID: rangeID) else { return }

    // Table kinds need their keyed sidecar (and a live structural match
    // when the model still detects a grid). Without it — or when live
    // detect yields a different grid — paint nothing rather than a
    // misleading linear sweep or a re-detected replacement
    // (`render_selection_overlay_impl`). Pin uses the sidecar.
    let tableGeom: PagerTableGeometry?
    switch kind {
    case .linear:
        tableGeom = nil
    case .tableCell, .tableGrid:
        tableGeom = pagerTableGeometry(
            for: highlight,
            in: model,
            table: table,
            sidecar: tableSidecar
        )
        if tableGeom == nil { return }
    }

    let startBL = min(anchor.blockLineIndex, head.blockLineIndex)
    let endBL = max(anchor.blockLineIndex, head.blockLineIndex)

    for line in range.lines {
        guard let screenY = line.screenY else { continue }
        guard clipArea.height <= 0
            || (screenY >= clipArea.y && screenY < clipArea.y + clipArea.height)
        else { continue }
        let colRanges: [Range<Int>]
        if let geom = tableGeom {
            colRanges = pagerTableSelectedColsForLine(
                geom,
                kind: kind,
                anchor: anchor,
                head: head,
                blockLineIndex: line.blockLineIndex
            ).compactMap { cols -> Range<Int>? in
                guard cols.lowerBound < cols.upperBound else { return nil }
                let snapped = pagerEndpointStartCol(line.text, col: cols.lowerBound)
                    ..< pagerEndpointEndCol(line.text, col: cols.upperBound - 1)
                return pagerClipSelectionColsToContent(line.text, cols: snapped)
            }
        } else {
            if line.blockLineIndex < startBL || line.blockLineIndex > endBL {
                continue
            }
            guard let cols = pagerSelectedColsForEndpoints(anchor: anchor, head: head, line: line)
            else { continue }
            colRanges = [cols]
        }
        for cols in colRanges {
            for col in cols {
                let screenX = line.screenX + line.selectableCols.lowerBound + col
                if clipArea.width > 0 {
                    guard screenX >= clipArea.x, screenX < clipArea.x + clipArea.width else {
                        continue
                    }
                }
                guard var cell = buffer.cell(x: screenX, y: screenY), !cell.skip else { continue }
                pagerApplyTextSelectionHighlight(theme: theme, to: &cell)
                buffer.setCell(cell, x: screenX, y: screenY)
            }
        }
    }
}

// MARK: - Table-shaped selection

/// Display-cell range of the grapheme covering `col`, or `nil` when `col`
/// is past the last grapheme (`grapheme_cells_at`).
func pagerGraphemeCellsAt(_ text: String, col: Int) -> Range<Int>? {
    var current = 0
    for grapheme in text {
        let width = max(0, UnicodeDisplayWidth.width(ofGrapheme: String(grapheme)))
        if width == 0 { continue }
        let next = current + width
        if next > col { return current..<next }
        current = next
    }
    return nil
}

/// Exclusive display column just past the grapheme occupying `col`
/// (`col_past_grapheme`).
func pagerColPastGrapheme(_ text: String, col: Int) -> Int {
    pagerGraphemeCellsAt(text, col: col)?.upperBound ?? pagerSelectionDisplayWidth(text)
}

/// Exclusive end for a selection that includes the cell at `col`.
func pagerEndpointEndCol(_ text: String, col: Int) -> Int {
    max(pagerColPastGrapheme(text, col: col), col + 1)
}

/// Start of a selection whose first cell is `col` (wide glyphs selected whole).
func pagerEndpointStartCol(_ text: String, col: Int) -> Int {
    pagerGraphemeCellsAt(text, col: col)?.lowerBound ?? col
}

/// A table-cell selection's endpoints clamped into the cell's box, normalized
/// so start <= end (`table_cell_span`).
func pagerTableCellSpan(
    _ geom: PagerTableGeometry,
    cell: PagerTableCellRef,
    anchor: PagerTextSelectionEndpoint,
    head: PagerTextSelectionEndpoint
) -> ((line: Int, col: Int), (line: Int, col: Int)) {
    let lines = geom.rowLines(cell.row)
    let band = geom.band(cell.col)
    let lastLine = max(lines.lowerBound, lines.upperBound - 1)
    let lastCol = max(band.lowerBound, band.upperBound - 1)
    func clamp(_ ep: PagerTextSelectionEndpoint) -> (Int, Int) {
        (
            min(max(ep.blockLineIndex, lines.lowerBound), lastLine),
            min(max(ep.colWithinRange, band.lowerBound), lastCol)
        )
    }
    let a = clamp(anchor)
    let h = clamp(head)
    if a <= h { return (a, h) }
    return (h, a)
}

/// Clip a painted column range to the non-whitespace content it covers,
/// mirroring the copy (which trims fragments and skips blank ones).
func pagerClipSelectionColsToContent(_ text: String, cols: Range<Int>) -> Range<Int> {
    var start: Int?
    var end = cols.lowerBound
    var col = 0
    for grapheme in text {
        let s = String(grapheme)
        let width = max(0, UnicodeDisplayWidth.width(ofGrapheme: s))
        if width == 0 { continue }
        let next = col + width
        if col >= cols.upperBound { break }
        if next > cols.lowerBound && !s.unicodeScalars.allSatisfy({ Character($0).isWhitespace }) {
            if start == nil {
                start = max(col, cols.lowerBound)
            }
            end = min(next, cols.upperBound)
        }
        col = next
    }
    if let start {
        return start..<end
    }
    return cols.lowerBound..<cols.lowerBound
}

/// Selected column ranges on one line of a table-shaped selection:
/// `tableCell` at most one band-clamped range, `tableGrid` one band per
/// selected column. Border glyphs are never included.
func pagerTableSelectedColsForLine(
    _ geom: PagerTableGeometry,
    kind: PagerTextSelectionKind,
    anchor: PagerTextSelectionEndpoint,
    head: PagerTextSelectionEndpoint,
    blockLineIndex: Int
) -> [Range<Int>] {
    if !geom.lineRange.contains(blockLineIndex) { return [] }
    switch kind {
    case .linear:
        return []
    case .tableCell:
        guard let cell = geom.cellAt(line: anchor.blockLineIndex, col: anchor.colWithinRange)
        else { return [] }
        let band = geom.band(cell.col)
        let (startEP, endEP) = pagerTableCellSpan(geom, cell: cell, anchor: anchor, head: head)
        if blockLineIndex < startEP.line || blockLineIndex > endEP.line {
            return []
        }
        let start = blockLineIndex == startEP.line ? startEP.col : band.lowerBound
        let end = blockLineIndex == endEP.line
            ? min(endEP.col + 1, band.upperBound)
            : band.upperBound
        if start >= end { return [] }
        return [start..<end]
    case .tableGrid(let a, let h):
        guard let row = geom.rowOfLine(blockLineIndex) else { return [] }
        let r0 = min(a.row, h.row)
        let r1 = max(a.row, h.row)
        let c0 = min(a.col, h.col)
        let c1 = max(a.col, h.col)
        if row < r0 || row > r1 { return [] }
        return (c0...c1).map { geom.band($0) }
    }
}

/// Resolve a drag's `PagerTextSelectionKind`, with hysteresis: the head is
/// latched from the cell the drag already holds, so only another cell's
/// content changes the mode. Grid-line anchors stay `linear`.
public func pagerResolveTableDragKind(
    _ geom: PagerTableGeometry?,
    anchor: PagerTextRangeHit,
    head: PagerTextRangeHit,
    prev: PagerTextSelectionKind
) -> PagerTextSelectionKind {
    guard let geom else { return .linear }
    guard let a = geom.cellAt(line: anchor.blockLineIndex, col: anchor.colWithinRange) else {
        return .linear
    }
    let held: PagerTableCellRef
    switch prev {
    case .tableGrid(_, let headCell):
        held = headCell
    case .linear, .tableCell:
        held = a
    }
    let h = geom.latchedCellAt(held: held, line: head.blockLineIndex, col: head.colWithinRange)
    if a == h {
        return .tableCell
    }
    return .tableGrid(anchor: a, head: h)
}

/// Copied text for a table-shaped selection: the band-clamped span for
/// `tableCell`, whole cells as TSV for `tableGrid`. `nil` (= fall back to
/// linear) for `linear` drags or an anchor that no longer resolves.
public func pagerReconstructTableSelectionText(
    _ geom: PagerTableGeometry,
    drag: PagerActiveTextDrag,
    textAt: (Int) -> String?
) -> String? {
    let anchor = PagerTextSelectionEndpoint(
        blockLineIndex: drag.anchor.blockLineIndex,
        colWithinRange: drag.anchor.colWithinRange
    )
    let head = PagerTextSelectionEndpoint(
        blockLineIndex: drag.head.blockLineIndex,
        colWithinRange: drag.head.colWithinRange
    )
    switch drag.kind {
    case .linear:
        return nil
    case .tableCell:
        guard let cell = geom.cellAt(line: anchor.blockLineIndex, col: anchor.colWithinRange)
        else { return nil }
        let band = geom.band(cell.col)
        let (startEP, endEP) = pagerTableCellSpan(geom, cell: cell, anchor: anchor, head: head)
        var out = ""
        if startEP.line <= endEP.line {
            for line in startEP.line...endEP.line {
                guard let text = textAt(line) else { return nil }
                let start = line == startEP.line
                    ? max(pagerEndpointStartCol(text, col: startEP.col), band.lowerBound)
                    : band.lowerBound
                let end = line == endEP.line
                    ? min(pagerEndpointEndCol(text, col: endEP.col), band.upperBound)
                    : band.upperBound
                let fragment = pagerSliceDisplayCols(text, start: start, end: end)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if fragment.isEmpty { continue }
                if !out.isEmpty { out += " " }
                out += fragment
            }
        }
        return out
    case .tableGrid(let a, let h):
        return geom.gridTSV(a, h, textAt: textAt)
    }
}

/// Geometry for a table-shaped highlight: an explicit value, or a keyed
/// sidecar that still matches the live model. Never re-detects a
/// replacement grid — missing/stale sidecar or a live structural mismatch
/// yields `nil` (paint nothing, never another grid / linear).
func pagerTableGeometry(
    for highlight: PagerTextSelectionHighlight,
    in model: PagerTextSelectionModel,
    table: PagerTableGeometry? = nil,
    sidecar: PagerTableSelectionGeometry? = nil
) -> PagerTableGeometry? {
    let entryIndex: Int
    let rangeID: UInt16
    let atLine: Int
    let kind: PagerTextSelectionKind
    switch highlight {
    case .active(let drag):
        kind = drag.kind
        entryIndex = drag.anchor.entryIndex
        rangeID = drag.anchor.rangeID
        atLine = drag.anchor.blockLineIndex
    case .persistent(let selection):
        kind = selection.kind
        entryIndex = selection.entryIndex
        rangeID = selection.rangeID
        atLine = selection.anchor.blockLineIndex
    }
    switch kind {
    case .linear:
        return nil
    case .tableCell, .tableGrid:
        // Explicit geometry is for unit tests that already hold the grid.
        if let table { return table }
        guard let matched = sidecar?.forSelection(entryIndex: entryIndex, rangeID: rangeID)
        else { return nil }
        // Mapped live endpoints must still resolve to this sidecar. A
        // different detected grid (reflow / stream) must not replace it.
        let live = pagerDetectTableGeometry(
            in: model,
            entryIndex: entryIndex,
            rangeID: rangeID,
            atLine: atLine
        )
        guard live == matched else { return nil }
        return matched
    }
}
