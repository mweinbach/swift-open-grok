import Foundation
import OpenGrokTerminalCore

// MARK: - Box-drawing table grid (scrollback/table_geometry.rs at pin 650c1db7)
//
// Detect from full selectable line text by display columns. Anything `detect`
// cannot prove falls back to nil (callers then use linear). Table-shaped
// paint lines never soft-wrap, so one rendered line is one block line.

/// Walk-up cap when the anchor is a content row
/// (`MAX_JUNCTION_SEARCH`, table_geometry.rs:194).
public let pagerMaxTableJunctionSearch = 400

/// A cell position within a detected grid: `row` indexes logical rows
/// (header = 0), `col` indexes columns left to right (`CellRef`).
public struct PagerTableCellRef: Sendable, Equatable, Hashable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

/// Geometry of one box-drawing table, in the block's line/column space:
/// line indices are `blockLineIndex` values, columns are display columns in
/// the same space as `PagerTextRangeHit.colWithinRange`.
public struct PagerTableGeometry: Sendable, Equatable, Hashable {
    /// Full extent of the grid, top border line ..= bottom border line
    /// (half-open).
    public var lineRange: Range<Int>
    /// Display columns of the vertical grid lines, ascending.
    /// `junctionCols.count == columnCount + 1`.
    public var junctionCols: [Int]
    /// Per logical row, the contiguous block-line range of its content lines
    /// (a row wrapped inside cells spans several lines). Never empty.
    public var rows: [Range<Int>]

    public init(lineRange: Range<Int>, junctionCols: [Int], rows: [Range<Int>]) {
        self.lineRange = lineRange
        self.junctionCols = junctionCols
        self.rows = rows
    }

    public var columnCount: Int { max(0, junctionCols.count - 1) }
    public var rowCount: Int { rows.count }

    /// The logical row containing `line`, if `line` is a content line.
    public func rowOfLine(_ line: Int) -> Int? {
        rows.firstIndex { $0.contains(line) }
    }

    /// Content-line range of a logical row.
    public func rowLines(_ row: Int) -> Range<Int> {
        guard rows.indices.contains(row) else { return 0..<0 }
        return rows[row]
    }

    /// Display-column band of a column's cell interior: everything strictly
    /// between the two flanking `│` glyphs (padding included).
    public func band(_ col: Int) -> Range<Int> {
        guard col >= 0, col + 1 < junctionCols.count else { return 0..<0 }
        let start = junctionCols[col] + 1
        return start..<junctionCols[col + 1]
    }

    /// The cell at (`line`, `col`), or `nil` when `line` is a border row or
    /// `col` falls outside the grid. A click exactly on a `│` snaps to the
    /// cell on its right (left for the closing border).
    public func cellAt(line: Int, col: Int) -> PagerTableCellRef? {
        guard let row = rowOfLine(line),
              let first = junctionCols.first,
              let last = junctionCols.last
        else { return nil }
        if col < first || col > last { return nil }
        let c: Int
        if let j = junctionCols.lastIndex(where: { $0 <= col }) {
            c = (j == junctionCols.count - 1) ? columnCount - 1 : j
        } else {
            c = 0
        }
        return PagerTableCellRef(row: row, col: c)
    }

    /// The column whose content interior (band minus the renderer's one
    /// padding column per side) contains `col`.
    func interiorCol(at col: Int) -> Int? {
        for c in 0..<columnCount {
            let band = self.band(c)
            let lo = band.lowerBound + 1
            let hi = band.upperBound > 0 ? band.upperBound - 1 : 0
            if col >= lo && col < hi { return c }
        }
        return nil
    }

    /// Latched head-cell resolution: borders, padding, and divider rows
    /// keep `held`; only another cell's content interior (or the grid's
    /// outer edge, which clamps) moves it. Empty cells never capture it.
    public func latchedCellAt(held: PagerTableCellRef, line: Int, col: Int) -> PagerTableCellRef {
        let row: Int
        if let found = rowOfLine(line) {
            row = found
        } else if line < lineRange.lowerBound {
            row = 0
        } else if line >= lineRange.upperBound {
            row = rowCount - 1
        } else {
            row = held.row
        }
        let resolvedCol: Int
        if let found = interiorCol(at: col) {
            resolvedCol = found
        } else if let first = junctionCols.first, col < first {
            resolvedCol = 0
        } else if let last = junctionCols.last, col > last {
            resolvedCol = columnCount - 1
        } else {
            resolvedCol = held.col
        }
        return PagerTableCellRef(row: row, col: resolvedCol)
    }

    /// A cell's text: its per-line band slices trimmed and joined with a
    /// space (cells wrap at spaces/punctuation, so a space join reconstructs
    /// the content).
    public func cellText(_ cell: PagerTableCellRef, textAt: (Int) -> String?) -> String {
        let band = self.band(cell.col)
        var out = ""
        for line in rowLines(cell.row) {
            guard let text = textAt(line) else { continue }
            let fragment = pagerSliceDisplayCols(text, start: band.lowerBound, end: band.upperBound)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fragment.isEmpty { continue }
            if !out.isEmpty { out += " " }
            out += fragment
        }
        return out
    }

    /// TSV for the rectangular cell range spanned by `a` and `b` (order
    /// irrelevant): cells tab-joined, rows newline-joined. Tabs inside cell
    /// text are flattened to spaces so the TSV shape survives.
    public func gridTSV(
        _ a: PagerTableCellRef,
        _ b: PagerTableCellRef,
        textAt: (Int) -> String?
    ) -> String {
        let r0 = min(a.row, b.row)
        let r1 = max(a.row, b.row)
        let c0 = min(a.col, b.col)
        let c1 = max(a.col, b.col)
        var rowsOut: [String] = []
        if r0 <= r1 {
            for row in r0...r1 {
                var cells: [String] = []
                if c0 <= c1 {
                    for col in c0...c1 {
                        cells.append(
                            cellText(PagerTableCellRef(row: row, col: col), textAt: textAt)
                                .replacingOccurrences(of: "\t", with: " ")
                        )
                    }
                }
                rowsOut.append(cells.joined(separator: "\t"))
            }
        }
        return rowsOut.joined(separator: "\n")
    }

    /// Detect the grid containing `atLine`, reading lines through `textAt`.
    /// `nil` unless `atLine` sits inside a fully-enclosed, column-consistent
    /// grid — callers then fall back to linear.
    public static func detect(atLine: Int, textAt: (Int) -> String?) -> PagerTableGeometry? {
        guard atLine >= 0, let anchorText = textAt(atLine) else { return nil }
        let junctions: [Int]
        if let parsed = pagerParseTableBorderRow(anchorText) {
            junctions = parsed.junctions
        } else {
            var found: [Int]?
            var line = atLine
            while line > 0, atLine - line < pagerMaxTableJunctionSearch {
                line -= 1
                guard let text = textAt(line) else { break }
                if let parsed = pagerParseTableBorderRow(text) {
                    found = parsed.junctions
                    break
                }
                // Cheap plausibility gate so we don't scan a whole prose
                // block: rows of a grid always start with a prefix char.
                guard let first = text.unicodeScalars.first,
                      pagerIsTablePrefixChar(Character(first))
                else { break }
            }
            guard let found else { return nil }
            junctions = found
        }

        var top = atLine
        while true {
            guard let text = textAt(top) else { return nil }
            switch pagerClassifyTableLine(text, junctions: junctions) {
            case .border(_, .top):
                break
            case .border(_, .bottom) where top < atLine:
                return nil
            case .border, .content:
                // Rust: `Border { .. } | Content if top > 0` — the guard
                // applies to both; a border at line 0 is not a grid.
                guard top > 0 else { return nil }
                top -= 1
                continue
            case .other:
                return nil
            }
            break
        }

        var bottom = atLine
        while true {
            guard let text = textAt(bottom) else { return nil }
            switch pagerClassifyTableLine(text, junctions: junctions) {
            case .border(_, .bottom):
                break
            case .border(_, .top) where bottom > atLine:
                return nil
            case .border, .content:
                bottom += 1
                continue
            case .other:
                return nil
            }
            break
        }

        var rows: [Range<Int>] = []
        var runStart: Int?
        for line in top...bottom {
            guard let text = textAt(line) else { return nil }
            switch pagerClassifyTableLine(text, junctions: junctions) {
            case .content:
                if runStart == nil { runStart = line }
            case .border:
                if let start = runStart {
                    rows.append(start..<line)
                    runStart = nil
                }
            case .other:
                return nil
            }
        }
        if rows.isEmpty { return nil }

        return PagerTableGeometry(
            lineRange: top..<(bottom + 1),
            junctionCols: junctions,
            rows: rows
        )
    }

    public static func detect(lines: [String], atLine: Int) -> PagerTableGeometry? {
        detect(atLine: atLine) { lines.indices.contains($0) ? lines[$0] : nil }
    }
}

/// Side-car geometry keyed to the selection it was resolved for.
/// Consumers check the key; a stale side-car is ignored (table kinds paint
/// nothing without geometry).
public struct PagerTableSelectionGeometry: Sendable, Equatable, Hashable {
    public var entryIndex: Int
    public var rangeID: UInt16
    public var geometry: PagerTableGeometry

    public init(entryIndex: Int, rangeID: UInt16, geometry: PagerTableGeometry) {
        self.entryIndex = entryIndex
        self.rangeID = rangeID
        self.geometry = geometry
    }

    /// The geometry, if it was resolved for (`entryIndex`, `rangeID`).
    public func forSelection(entryIndex: Int, rangeID: UInt16) -> PagerTableGeometry? {
        (self.entryIndex == entryIndex && self.rangeID == rangeID) ? geometry : nil
    }
}

// MARK: - Line classification

private let pagerTableBar: Character = "\u{2502}" // │

private enum PagerTableBorderKind: Sendable, Equatable {
    /// `┌──┬──┐`
    case top
    /// `├──┼──┤`
    case divider
    /// `└──┴──┘`
    case bottom
}

private enum PagerTableGridLine: Sendable, Equatable {
    case border(junctions: [Int], kind: PagerTableBorderKind)
    case content
    case other
}

/// Chars permitted before a grid's left edge: indentation and blockquote
/// bars (`│ `-prefixed tables render inside quotes with fully selectable
/// text).
private func pagerIsTablePrefixChar(_ c: Character) -> Bool {
    c == " " || c == pagerTableBar
}

/// Wrap-layer table-line heuristic (`wrapping.rs` `is_table_line`), plus quoted
/// box borders: after a `│`/space prefix, a non-vertical box-drawing glyph
/// (`U+2500...257F` except `│`/`┃`) is a table, not prose. Broader than
/// `detect`. Blockquotes that only have a leading `│` prefix still wrap.
func pagerLineLooksLikeTable(_ text: String) -> Bool {
    var scalars = text.unicodeScalars.makeIterator()
    guard let first = scalars.next() else { return false }
    let value = first.value
    if pagerIsNonVerticalBoxDrawing(value) {
        return true
    }
    if value == 0x2502 {
        var inPrefix = true
        while let scalar = scalars.next() {
            if inPrefix && (scalar.value == 0x2502 || scalar.value == 0x20) {
                continue
            }
            inPrefix = false
            // Content row: a later cell bar. Quoted border: ┌/┬/┐/─/…
            if scalar.value == 0x2502 || pagerIsNonVerticalBoxDrawing(scalar.value) {
                return true
            }
        }
        return false
    }
    return first.value == 0x7C
}

/// Box-drawing except vertical bars (`│` U+2502, `┃` U+2503), which are
/// blockquote prefixes rather than table borders.
private func pagerIsNonVerticalBoxDrawing(_ value: UInt32) -> Bool {
    (0x2500...0x257F).contains(value) && value != 0x2502 && value != 0x2503
}

/// (display column, first char) for every grapheme in `text`, mirroring the
/// column arithmetic of `slice_display_cols` / `word_boundaries_at_col`.
private func pagerTableGraphemeCols(_ text: String) -> [(col: Int, char: Character)] {
    var col = 0
    var out: [(col: Int, char: Character)] = []
    for grapheme in text {
        let s = String(grapheme)
        let width = max(0, UnicodeDisplayWidth.width(ofGrapheme: s))
        if width == 0 { continue }
        let first = grapheme.unicodeScalars.first.map { Character($0) } ?? " "
        out.append((col, first))
        col += width
    }
    return out
}

/// Parse a border row (`┌──┬──┐` / `├──┼──┤` / `└──┴──┘`), tolerating an
/// indentation/blockquote prefix.
private func pagerParseTableBorderRow(_ text: String) -> (junctions: [Int], kind: PagerTableBorderKind)? {
    let topOpen: Character = "\u{250C}" // ┌
    let topMid: Character = "\u{252C}" // ┬
    let topClose: Character = "\u{2510}" // ┐
    let divOpen: Character = "\u{251C}" // ├
    let divMid: Character = "\u{253C}" // ┼
    let divClose: Character = "\u{2524}" // ┤
    let botOpen: Character = "\u{2514}" // └
    let botMid: Character = "\u{2534}" // ┴
    let botClose: Character = "\u{2518}" // ┘
    let h: Character = "\u{2500}" // ─

    var junctions: [Int] = []
    var family: PagerTableBorderKind?
    var closed = false

    for (col, c) in pagerTableGraphemeCols(text) {
        if family == nil {
            let opened: PagerTableBorderKind?
            if c == topOpen {
                opened = .top
            } else if c == divOpen {
                opened = .divider
            } else if c == botOpen {
                opened = .bottom
            } else if pagerIsTablePrefixChar(c) {
                opened = nil
            } else {
                return nil
            }
            if let opened {
                family = opened
                junctions.append(col)
            }
            continue
        }
        if closed {
            return nil
        }
        let mid: Character
        let close: Character
        switch family {
        case .top:
            mid = topMid
            close = topClose
        case .divider:
            mid = divMid
            close = divClose
        case .bottom:
            mid = botMid
            close = botClose
        case nil:
            return nil
        }
        if c == mid {
            junctions.append(col)
        } else if c == close {
            junctions.append(col)
            closed = true
        } else if c != h {
            return nil
        }
    }

    guard closed, junctions.count >= 2, let family else { return nil }
    return (junctions, family)
}

/// Whether `text` is a content row of a grid with the given junction set:
/// a `│` at every junction column, nothing but prefix chars before the left
/// edge, and nothing after the right edge (selection text is end-trimmed).
private func pagerIsTableContentRow(_ text: String, junctions: [Int]) -> Bool {
    guard let left = junctions.first, let right = junctions.last else { return false }
    var neededIndex = 0
    var lastCol = 0
    for (col, c) in pagerTableGraphemeCols(text) {
        lastCol = col
        if col < left && !pagerIsTablePrefixChar(c) { return false }
        if col > right { return false }
        if neededIndex < junctions.count, junctions[neededIndex] == col {
            if c != pagerTableBar { return false }
            neededIndex += 1
        }
    }
    return neededIndex == junctions.count && lastCol == right
}

private func pagerClassifyTableLine(_ text: String, junctions: [Int]) -> PagerTableGridLine {
    if let parsed = pagerParseTableBorderRow(text) {
        if parsed.junctions == junctions {
            return .border(junctions: parsed.junctions, kind: parsed.kind)
        }
        return .other
    }
    if pagerIsTableContentRow(text, junctions: junctions) {
        return .content
    }
    return .other
}

/// Detect from a selectable range's full line texts (off-screen included).
public func pagerDetectTableGeometry(
    in model: PagerTextSelectionModel,
    entryIndex: Int,
    rangeID: UInt16,
    atLine: Int
) -> PagerTableGeometry? {
    guard let range = model.range(entryIndex: entryIndex, rangeID: rangeID) else {
        return nil
    }
    var texts: [Int: String] = [:]
    texts.reserveCapacity(range.lines.count)
    for line in range.lines {
        texts[line.blockLineIndex] = line.text
    }
    return PagerTableGeometry.detect(atLine: atLine) { texts[$0] }
}

func pagerSelectionLineTextAt(
    model: PagerTextSelectionModel,
    entryIndex: Int,
    rangeID: UInt16
) -> ((Int) -> String?)? {
    guard let range = model.range(entryIndex: entryIndex, rangeID: rangeID) else {
        return nil
    }
    var texts: [Int: String] = [:]
    texts.reserveCapacity(range.lines.count)
    for line in range.lines {
        texts[line.blockLineIndex] = line.text
    }
    return { texts[$0] }
}
