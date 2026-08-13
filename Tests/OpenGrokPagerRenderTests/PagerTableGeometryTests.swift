import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

// Table-geometry goldens against pin 650c1db7 (`scrollback/table_geometry.rs`,
// wrap-layer `is_table_line` in wrapping.rs). Detect fails closed to nil.

@Suite("PagerTableGeometry")
struct PagerTableGeometryTests {

    private let table = [
        "Intro prose",
        "┌─────────┬────────┐",
        "│ Name    │ Role   │",
        "├─────────┼────────┤",
        "│ Alice   │ Eng    │",
        "├─────────┼────────┤",
        "│ Bob     │ Design │",
        "└─────────┴────────┘",
        "Outro prose",
    ]

    private let wrapped = [
        "┌─────────┬──────────┐",
        "│ Name    │ Notes    │",
        "├─────────┼──────────┤",
        "│ Alice   │ likes    │",
        "│         │ long     │",
        "│         │ walks    │",
        "└─────────┴──────────┘",
    ]

    // MARK: - Detect

    @Test("detects from every content and border line")
    func detectsFromContentAndBorderLines() throws {
        for at in 1...7 {
            let geom = try #require(PagerTableGeometry.detect(lines: table, atLine: at))
            #expect(geom.lineRange == 1..<8)
            #expect(geom.columnCount == 2)
            #expect(geom.rowCount == 3)
            #expect(geom.rowLines(0) == 2..<3)
            #expect(geom.rowLines(2) == 6..<7)
        }
        #expect(pagerMaxTableJunctionSearch == 400)
    }

    @Test("no grid outside table")
    func noGridOutsideTable() {
        #expect(PagerTableGeometry.detect(lines: table, atLine: 0) == nil)
        #expect(PagerTableGeometry.detect(lines: table, atLine: 8) == nil)
    }

    @Test("cell lookup, bands, and junction snapping")
    func cellLookupAndBands() throws {
        let geom = try #require(PagerTableGeometry.detect(lines: table, atLine: 4))
        // "│ Alice   │ Eng    │" — junctions at cols 0, 10, 19.
        #expect(geom.band(0) == 1..<10)
        #expect(geom.band(1) == 11..<19)
        #expect(geom.cellAt(line: 4, col: 3) == PagerTableCellRef(row: 1, col: 0))
        #expect(geom.cellAt(line: 4, col: 12) == PagerTableCellRef(row: 1, col: 1))
        // Junction col snaps right; closing border snaps left.
        #expect(geom.cellAt(line: 4, col: 10) == PagerTableCellRef(row: 1, col: 1))
        #expect(geom.cellAt(line: 4, col: 19) == PagerTableCellRef(row: 1, col: 1))
        #expect(geom.cellAt(line: 4, col: 0) == PagerTableCellRef(row: 1, col: 0))
        #expect(geom.cellAt(line: 3, col: 3) == nil)
        #expect(geom.cellAt(line: 4, col: 25) == nil)
    }

    @Test("latched cell moves only via content or past the edge")
    func latchedCellHysteresis() throws {
        let geom = try #require(PagerTableGeometry.detect(lines: table, atLine: 4))
        let held = PagerTableCellRef(row: 1, col: 0)
        #expect(geom.latchedCellAt(held: held, line: 6, col: 3) == PagerTableCellRef(row: 2, col: 0))
        #expect(geom.latchedCellAt(held: held, line: 5, col: 3) == held)
        #expect(geom.latchedCellAt(held: held, line: 1, col: 3) == held)
        #expect(geom.latchedCellAt(held: held, line: 0, col: 3) == PagerTableCellRef(row: 0, col: 0))
        #expect(geom.latchedCellAt(held: held, line: 8, col: 3) == PagerTableCellRef(row: 2, col: 0))
        #expect(geom.latchedCellAt(held: held, line: 4, col: 9) == held)
        #expect(geom.latchedCellAt(held: held, line: 4, col: 10) == held)
        #expect(geom.latchedCellAt(held: held, line: 4, col: 11) == held)
        #expect(geom.latchedCellAt(held: held, line: 4, col: 12) == PagerTableCellRef(row: 1, col: 1))
        #expect(geom.latchedCellAt(held: held, line: 4, col: 40) == PagerTableCellRef(row: 1, col: 1))
        let heldRole = PagerTableCellRef(row: 1, col: 1)
        #expect(geom.latchedCellAt(held: heldRole, line: 4, col: 10) == heldRole)
        #expect(geom.latchedCellAt(held: heldRole, line: 4, col: 5) == PagerTableCellRef(row: 1, col: 0))
    }

    @Test("cell text and TSV, including reversed endpoints")
    func cellTextAndTSV() throws {
        let geom = try #require(PagerTableGeometry.detect(lines: table, atLine: 4))
        let src: (Int) -> String? = { self.table.indices.contains($0) ? self.table[$0] : nil }
        #expect(geom.cellText(PagerTableCellRef(row: 1, col: 0), textAt: src) == "Alice")
        #expect(
            geom.gridTSV(
                PagerTableCellRef(row: 1, col: 0),
                PagerTableCellRef(row: 2, col: 0),
                textAt: src
            ) == "Alice\nBob"
        )
        #expect(
            geom.gridTSV(
                PagerTableCellRef(row: 2, col: 1),
                PagerTableCellRef(row: 1, col: 0),
                textAt: src
            ) == "Alice\tEng\nBob\tDesign"
        )
    }

    @Test("wrapped cell fragments join with space; empty fragments skipped")
    func wrappedCellFragments() throws {
        let geom = try #require(PagerTableGeometry.detect(lines: wrapped, atLine: 4))
        let src: (Int) -> String? = { self.wrapped.indices.contains($0) ? self.wrapped[$0] : nil }
        #expect(geom.rowCount == 2)
        #expect(geom.rowLines(1) == 3..<6)
        #expect(geom.cellText(PagerTableCellRef(row: 1, col: 1), textAt: src) == "likes long walks")
        #expect(geom.cellText(PagerTableCellRef(row: 1, col: 0), textAt: src) == "Alice")
    }

    @Test("blockquoted table with quote-bar prefix")
    func blockquotedTable() throws {
        let quoted = [
            "│ ┌─────┬─────┐",
            "│ │ A   │ B   │",
            "│ ├─────┼─────┤",
            "│ │ one │ two │",
            "│ └─────┴─────┘",
        ]
        let geom = try #require(PagerTableGeometry.detect(lines: quoted, atLine: 3))
        #expect(geom.columnCount == 2)
        let src: (Int) -> String? = { quoted.indices.contains($0) ? quoted[$0] : nil }
        #expect(geom.cellText(PagerTableCellRef(row: 1, col: 0), textAt: src) == "one")
    }

    @Test("wide glyphs use display columns")
    func wideGlyphsUseDisplayColumns() throws {
        let emoji = ["┌──────┬──────┐", "│ 名前 │ ok   │", "└──────┴──────┘"]
        let geom = try #require(PagerTableGeometry.detect(lines: emoji, atLine: 1))
        #expect(geom.band(0) == 1..<7)
        let src: (Int) -> String? = { emoji.indices.contains($0) ? emoji[$0] : nil }
        #expect(geom.cellText(PagerTableCellRef(row: 0, col: 0), textAt: src) == "名前")
        #expect(geom.cellAt(line: 1, col: 3) == PagerTableCellRef(row: 0, col: 0))
    }

    @Test("inconsistent junctions bail")
    func inconsistentJunctionsBail() {
        let broken = [
            "┌─────┬─────┐",
            "│ A   │ B   │",
            "├────────┼──┤",
            "│ one │ two │",
            "└─────┴─────┘",
        ]
        #expect(PagerTableGeometry.detect(lines: broken, atLine: 1) == nil)
    }

    @Test("unclosed grid bails")
    func unclosedGridBails() {
        let unclosed = ["┌─────┬─────┐", "│ A   │ B   │", "prose again"]
        #expect(PagerTableGeometry.detect(lines: unclosed, atLine: 1) == nil)
    }

    @Test("stray bar in cell content is not a junction")
    func strayBarIsContent() throws {
        let stray = ["┌───────┬─────┐", "│ a │ b │ c   │", "└───────┴─────┘"]
        let geom = try #require(PagerTableGeometry.detect(lines: stray, atLine: 1))
        #expect(geom.columnCount == 2)
        let src: (Int) -> String? = { stray.indices.contains($0) ? stray[$0] : nil }
        #expect(geom.cellText(PagerTableCellRef(row: 0, col: 0), textAt: src) == "a │ b")
    }

    @Test("plain prose and rules are not grids")
    func proseAndRulesAreNotGrids() {
        let prose = ["hello world", "─────────", "goodbye"]
        #expect(PagerTableGeometry.detect(lines: prose, atLine: 0) == nil)
        #expect(PagerTableGeometry.detect(lines: prose, atLine: 1) == nil)
    }

    @Test("tabs inside cells flatten to spaces in TSV")
    func tabsSanitizedInTSV() throws {
        let geom = try #require(PagerTableGeometry.detect(lines: table, atLine: 4))
        let src: (Int) -> String? = { i in
            if i == 4 { return "│ Al\tce   │ Eng    │" }
            return self.table.indices.contains(i) ? self.table[i] : nil
        }
        let raw = geom.cellText(PagerTableCellRef(row: 1, col: 0), textAt: src)
        let tsv = geom.gridTSV(
            PagerTableCellRef(row: 1, col: 0),
            PagerTableCellRef(row: 1, col: 0),
            textAt: src
        )
        #expect(tsv == raw.replacingOccurrences(of: "\t", with: " "))
        #expect(!tsv.contains("\t"))
    }

    // MARK: - Wrap-skip heuristic (wrapping.rs is_table_line)

    @Test("table-shaped lines match wrap-skip heuristic; blockquotes do not")
    func looksLikeTableHeuristic() {
        #expect(pagerLineLooksLikeTable("┌─────┐"))
        #expect(pagerLineLooksLikeTable("└─────┘"))
        #expect(pagerLineLooksLikeTable("├─────┤"))
        #expect(pagerLineLooksLikeTable("─────"))
        #expect(pagerLineLooksLikeTable("│ cell │"))
        #expect(pagerLineLooksLikeTable("│ a │ b │"))
        #expect(pagerLineLooksLikeTable("| cell |"))
        #expect(!pagerLineLooksLikeTable("Hello world"))
        #expect(!pagerLineLooksLikeTable("  indented text"))
        #expect(!pagerLineLooksLikeTable(""))
        #expect(!pagerLineLooksLikeTable("> blockquote"))
        #expect(!pagerLineLooksLikeTable("│ blockquote text"))
        #expect(!pagerLineLooksLikeTable("│ │ nested blockquote"))
        #expect(!pagerLineLooksLikeTable("\u{2503} text"))
        // Quote-bar prefix then a box border (no second │ on the top rule).
        #expect(pagerLineLooksLikeTable("│ ┌─────┬─────┐"))
        #expect(pagerLineLooksLikeTable("│ ├─────┼─────┤"))
        #expect(pagerLineLooksLikeTable("│ └─────┴─────┘"))
        #expect(pagerLineLooksLikeTable("│ │ ┌─────┬─────┐"))
        #expect(pagerLineLooksLikeTable("│ │ A   │ B   │"))
    }

    @Test("paint does not soft-wrap table-shaped styled lines")
    func paintDoesNotSoftWrapTableLines() throws {
        let tableLine = "┌─────────┬────────┐"
        #expect(pagerSelectionDisplayWidth(tableLine) == 20)
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 14, height: 8),
            conversation: [
                .message(PagerMessage(
                    role: .assistant,
                    text: tableLine,
                    styledLines: [PagerStyledLine(text: tableLine)]
                ))
            ],
            input: PagerComposerState(text: "", isFocused: false),
            showScrollbar: false,
            compactMode: true
        ))
        let selection = try #require(result.layout.textSelection)
        let range = try #require(selection.range(entryIndex: 0, rangeID: 0))
        #expect(range.lines.count == 1)
        #expect(range.lines[0].joinerToPrevious == nil)
        // Clipped to content width (14 − 5 chrome = 9), still one selectable line.
        #expect(pagerSelectionDisplayWidth(range.lines[0].text) <= 9)
        #expect(range.lines[0].text.hasPrefix("┌"))
    }

    @Test("prose still soft-wraps at the same width")
    func proseStillWraps() throws {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 14, height: 8),
            conversation: [
                .message(PagerMessage(
                    role: .assistant,
                    text: "abcdefghijkl",
                    styledLines: [PagerStyledLine(text: "abcdefghijkl")]
                ))
            ],
            input: PagerComposerState(text: "", isFocused: false),
            showScrollbar: false,
            compactMode: true
        ))
        let selection = try #require(result.layout.textSelection)
        let range = try #require(selection.range(entryIndex: 0, rangeID: 0))
        #expect(range.lines.count > 1)
    }

    @Test("sidecar forSelection matches key and ignores stale keys")
    func sidecarMatch() throws {
        let geom = try #require(PagerTableGeometry.detect(lines: table, atLine: 4))
        let sidecar = PagerTableSelectionGeometry(entryIndex: 2, rangeID: 7, geometry: geom)
        #expect(sidecar.forSelection(entryIndex: 2, rangeID: 7) != nil)
        #expect(sidecar.forSelection(entryIndex: 2, rangeID: 0) == nil)
        #expect(sidecar.forSelection(entryIndex: 0, rangeID: 7) == nil)
    }
}
