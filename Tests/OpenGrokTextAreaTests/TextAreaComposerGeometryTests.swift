// TextAreaComposerGeometryTests.swift
//
// Stage 0 composer APIs: Character↔UTF-8 converters, wrap-option lockstep,
// snapshots, and ratatui screen geometry against the existing wrap cache.

import Testing
@testable import OpenGrokTextArea

@Suite("OpenGrokTextArea composer converters")
struct TextAreaComposerConverterTests {
    @Test("Character↔UTF-8 round trips and clamps")
    func roundTripAndClamp() {
        let text = "ab"
        for i in 0...text.count {
            let utf8 = utf8Offset(fromCharacter: i, in: text)
            #expect(characterOffset(fromUTF8: utf8, in: text) == i)
        }
        #expect(utf8Offset(fromCharacter: -3, in: text) == 0)
        #expect(utf8Offset(fromCharacter: 99, in: text) == text.utf8.count)
        #expect(characterOffset(fromUTF8: -1, in: text) == 0)
        #expect(characterOffset(fromUTF8: 99, in: text) == text.count)
        #expect(utf8Offset(fromCharacter: 0, in: "") == 0)
        #expect(characterOffset(fromUTF8: 0, in: "") == 0)
    }

    @Test("CRLF is one Character and mid-CRLF snaps left")
    func crlfSnap() {
        let text = "ab\r\ncd"
        #expect(text.count == 5)
        #expect(text.utf8.count == 6)
        #expect(utf8Offset(fromCharacter: 2, in: text) == 2)
        #expect(utf8Offset(fromCharacter: 3, in: text) == 4)
        #expect(characterOffset(fromUTF8: 2, in: text) == 2)
        #expect(characterOffset(fromUTF8: 3, in: text) == 2)
        #expect(characterOffset(fromUTF8: 4, in: text) == 3)
        for i in 0...text.count {
            #expect(characterOffset(fromUTF8: utf8Offset(fromCharacter: i, in: text), in: text) == i)
        }
    }

    @Test("combining mark cluster snaps nearest, ties left")
    func combiningSnap() {
        let text = "e\u{301}x"
        #expect(text.count == 2)
        let clusterEnd = utf8Offset(fromCharacter: 1, in: text)
        #expect(clusterEnd == "e\u{301}".utf8.count)
        #expect(utf8Offset(fromCharacter: 2, in: text) == text.utf8.count)
        #expect(characterOffset(fromUTF8: 0, in: text) == 0)
        #expect(characterOffset(fromUTF8: 1, in: text) == 0)
        #expect(characterOffset(fromUTF8: clusterEnd, in: text) == 1)
        let mid = clusterEnd - 1
        if mid > 0 {
            let snapped = characterOffset(fromUTF8: mid, in: text)
            #expect(snapped == 0 || snapped == 1)
            let back = utf8Offset(fromCharacter: snapped, in: text)
            #expect(back == 0 || back == clusterEnd)
        }
        for i in 0...text.count {
            #expect(characterOffset(fromUTF8: utf8Offset(fromCharacter: i, in: text), in: text) == i)
        }
    }

    @Test("emoji ZWJ and flags are single Character indices")
    func emojiZWJFlags() {
        let zwj = "👩🏽\u{200D}💻"
        let flag = "🇺🇸"
        let text = "a" + zwj + flag + "界"
        #expect(text.count == 4)
        #expect(utf8Offset(fromCharacter: 1, in: text) == 1)
        #expect(utf8Offset(fromCharacter: 2, in: text) == 1 + zwj.utf8.count)
        #expect(utf8Offset(fromCharacter: 3, in: text) == 1 + zwj.utf8.count + flag.utf8.count)
        let insideZWJ = 1 + max(1, zwj.utf8.count / 2)
        let snapped = characterOffset(fromUTF8: insideZWJ, in: text)
        #expect(snapped == 1 || snapped == 2)
        for i in 0...text.count {
            let u = utf8Offset(fromCharacter: i, in: text)
            #expect(characterOffset(fromUTF8: u, in: text) == i)
            #expect(text.isGraphemeBoundary(byte: u))
        }
    }
}

@Suite("OpenGrokTextArea composer wrap and snapshot")
struct TextAreaComposerWrapSnapshotTests {
    @Test("composerWrapOptions match ensureWrapCache exactly")
    func wrapOptionsLockstep() {
        let opts = composerWrapOptions(width: 8)
        #expect(opts.width == 8)
        #expect(opts.breakWords)
        #expect(opts.wrapAlgorithm == .firstFit)
        #expect(opts.wordSeparator == .unicodeBreakProperties)
        #expect(opts.wordSplitter == .hyphenSplitter)
        #expect(opts.lineEnding == .lf)
        #expect(opts.initialIndent == "")
        #expect(opts.subsequentIndent == "")
        #expect(composerWrapOptions(width: 0).width == 1)

        let area = TextArea()
        area.setText("hello-world foo")
        let wrapped = area.wrappedLines(width: 8)
        let independent = wrapRanges(area.text, options: composerWrapOptions(width: 8))
        #expect(wrapped == independent)
        let snap = area.composerSnapshot(wrapWidth: 8)
        #expect(snap.wrapOptions == composerWrapOptions(width: 8))
        #expect(snap.wrappedRows == wrapped)
        #expect(snap.wrapWidth == 8)
        #expect(snap.text == area.text)
        #expect(snap.cursorUTF8 == area.cursor)
    }

    @Test("area snapshot copies UTF-8 cursor selection and wrap rows")
    func areaSnapshot() {
        let area = TextArea()
        area.showScrollbar = false
        area.setText("hello world")
        area.setSelection(anchor: 0, head: 5)
        area.setCursor(5)
        let rect = TextAreaRect(x: 2, y: 1, width: 40, height: 3)
        let snap = area.composerSnapshot(area: rect, state: TextAreaState())
        #expect(snap.text == "hello world")
        #expect(snap.cursorUTF8 == 5)
        #expect(snap.selectionUTF8 == 0..<5)
        #expect(snap.selectedText == "hello")
        #expect(snap.wrappedRows == area.wrappedLines(width: snap.wrapWidth))
        #expect(snap.wrapOptions == composerWrapOptions(width: snap.wrapWidth))
        #expect(snap.cursorScreenPosition != nil)
        #expect(snap.selectionScreenSpans.count == 1)
        #expect(snap.selectionScreenSpans == area.selectionScreenSpans(area: rect, state: TextAreaState()))
    }
}

@Suite("OpenGrokTextArea composer screen geometry")
struct TextAreaComposerScreenGeometryTests {
    @Test("cursor at wrap boundary sits on the next visual line")
    func wrappedCursor() {
        let area = TextArea()
        area.showScrollbar = false
        area.setText("abcde")
        area.setCursor(5)
        let rect = TextAreaRect(x: 0, y: 0, width: 5, height: 3)
        let pos = area.cursorPosition(area: rect)
        #expect(pos == TextAreaScreenPosition(x: 0, y: 1))

        let wrapped = TextArea()
        wrapped.showScrollbar = false
        wrapped.setText("abcdefgh")
        wrapped.setCursor(5)
        let wrapPos = wrapped.cursorPosition(area: rect)
        #expect(wrapPos == TextAreaScreenPosition(x: 0, y: 1))
        let rows = wrapped.wrappedLines(width: 5)
        #expect(rows.count >= 2)
        #expect(rows[1].lowerBound == 5)
        let hit = wrapped.screenHit(col: 0, row: 1, area: rect, state: TextAreaState())
        #expect(hit?.utf8Offset == 5)
        #expect(hit?.wrappedRow == 1)
        #expect(wrapped.bufferPosAtScreen(col: 0, row: 1, area: rect, state: TextAreaState()) == 5)
    }

    @Test("cursor position is consistent with wrappedLines")
    func cursorMatchesWrapCache() {
        let area = TextArea()
        area.showScrollbar = false
        area.setText("hello world here")
        let rect = TextAreaRect(x: 0, y: 0, width: 6, height: 10)
        let rows = area.wrappedLines(width: 6)
        #expect(rows.count >= 3)
        let world = area.text.utf8OffsetOfASCII("world")
        area.setCursor(world + 3)
        let pos = area.cursorPosition(area: rect)
        #expect(pos != nil)
        let row = rows.lastIndex(where: { $0.lowerBound <= area.cursor }) ?? 0
        #expect(pos?.y == rect.y + row)
    }

    @Test("selection spans cover wrapped rows and match wrap cache")
    func selectionSpansWrapped() {
        let area = TextArea()
        area.showScrollbar = false
        area.setText("supercalifragilistic")
        let rect = TextAreaRect(x: 0, y: 0, width: 5, height: 8)
        let rows = area.wrappedLines(width: 5)
        #expect(rows.count >= 4)
        let end = area.text.utf8.count
        area.setSelection(anchor: 0, head: end)
        let spans = area.selectionScreenSpans(area: rect, state: TextAreaState())
        #expect(spans.count == rows.count)
        #expect(spans.allSatisfy { $0.rect.height == 1 })
        for (i, pair) in spans.enumerated() {
            #expect(pair.utf8Range == rows[i])
            #expect(pair.y == rect.y + i)
            #expect(pair.displayCols.lowerBound == 0)
        }
        let total = spans.reduce(0) { $0 + $1.width }
        #expect(total == 20)
        #expect(area.screenSpans(ofUTF8: 4..<4, area: rect, state: TextAreaState()).isEmpty)
        #expect(area.screenSpans(ofUTF8: 4..<999, area: rect, state: TextAreaState()).isEmpty)
    }

    @Test("selection spans reject non-scalar UTF-8 endpoints")
    func selectionRejectsMidScalar() {
        let area = TextArea()
        area.showScrollbar = false
        area.setText("héllo")
        let rect = TextAreaRect(x: 0, y: 0, width: 10, height: 2)
        let state = TextAreaState()
        #expect(area.screenSpans(ofUTF8: 2..<5, area: rect, state: state).isEmpty)
        #expect(area.screenSpans(ofUTF8: 0..<2, area: rect, state: state).isEmpty)
    }

    @Test("CJK wrap spans use display columns")
    func cjkDisplaySpans() {
        let area = TextArea()
        area.showScrollbar = false
        area.setText("日本語")
        let rect = TextAreaRect(x: 1, y: 0, width: 4, height: 3)
        let rows = area.wrappedLines(width: 4)
        #expect(rows.count == 2)
        let spans = area.screenSpans(ofUTF8: 0..<9, area: rect, state: TextAreaState())
        #expect(spans.map(\.rect) == [
            TextAreaRect(x: 1, y: 0, width: 4, height: 1),
            TextAreaRect(x: 1, y: 1, width: 2, height: 1),
        ])
        #expect(spans[0].displayCols == 0..<4)
        #expect(spans[1].displayCols == 0..<2)
        #expect(spans[0].utf8Range == rows[0])
        #expect(spans[1].utf8Range == rows[1])
    }

    @Test("scroll override clips cursor and offscreen selection head")
    func scrollClipping() {
        let area = TextArea()
        area.showScrollbar = false
        area.setText("supercalifragilistic")
        let rect = TextAreaRect(x: 0, y: 0, width: 5, height: 2)
        let rows = area.wrappedLines(width: 5)
        #expect(rows.count >= 4)
        area.setCursor(0)
        area.setScrollOverride(2)
        #expect(area.cursorPosition(area: rect, state: TextAreaState()) == nil)
        #expect(area.screenPosition(ofUTF8: 0, area: rect, state: TextAreaState()) == nil)

        area.setCursor(area.text.utf8.count)
        area.setScrollOverride(nil)
        let spans = area.screenSpans(
            ofUTF8: 0..<area.text.utf8.count,
            area: rect,
            state: TextAreaState()
        )
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { (rect.y..<(rect.y + rect.height)).contains($0.y) })
        let total = spans.reduce(0) { $0 + $1.width }
        #expect(total < 20)
        #expect(spans.count < rows.count)
    }

    @Test("wide grapheme hit snaps to cluster start")
    func wideGraphemeHit() {
        let area = TextArea()
        area.showScrollbar = false
        area.setText("a🦀b")
        let rect = TextAreaRect(x: 0, y: 0, width: 20, height: 5)
        let state = TextAreaState()
        #expect(area.bufferPosAtScreen(col: 0, row: 0, area: rect, state: state) == 0)
        #expect(area.bufferPosAtScreen(col: 1, row: 0, area: rect, state: state) == 1)
        #expect(area.bufferPosAtScreen(col: 2, row: 0, area: rect, state: state) == 1)
        #expect(area.bufferPosAtScreen(col: 3, row: 0, area: rect, state: state) == 5)
        let hit = area.screenHit(col: 2, row: 0, area: rect, state: state)
        #expect(hit?.utf8Offset == 1)
        #expect(hit?.hitElement == false)
        #expect(hit?.displayCol == 2)
        #expect(area.screenHit(col: 0, row: 0, area: TextAreaRect(x: 5, y: 5, width: 10, height: 3), state: state) == nil)

        let pos = area.cursorPosition(area: rect)
        area.setCursor(1)
        let crab = area.cursorPosition(area: rect)
        #expect(crab?.x == 1)
        _ = pos
    }

    @Test("scrollbar clamps selection span to content edge")
    func scrollbarContentEdge() {
        let area = TextArea()
        area.showScrollbar = true
        area.setText("ab   cd ef gh")
        area.setCursor(0)
        let rect = TextAreaRect(x: 0, y: 0, width: 5, height: 2)
        let layout = area.layout(area: rect, state: TextAreaState())
        #expect(layout.needsScrollbar)
        let spans = area.screenSpans(ofUTF8: 0..<5, area: rect, state: TextAreaState())
        #expect(spans.count == 1)
        #expect(spans[0].width == layout.textWidth)
        #expect(spans[0].x + spans[0].width <= rect.x + layout.textWidth)
        #expect(spans[0].displayCols == 0..<layout.textWidth)
    }

    @Test("empty composer snapshot still reports a cursor cell")
    func emptyCursor() {
        let area = TextArea()
        area.showScrollbar = false
        let rect = TextAreaRect(x: 3, y: 4, width: 20, height: 2)
        let pos = area.cursorPosition(area: rect)
        #expect(pos == TextAreaScreenPosition(x: 3, y: 4))
        let snap = area.composerSnapshot(area: rect, state: TextAreaState())
        #expect(snap.text.isEmpty)
        #expect(snap.cursorUTF8 == 0)
        #expect(snap.cursorScreenPosition == pos)
        #expect(snap.wrappedRows.isEmpty || snap.wrappedRows == [0..<0])
    }

    @Test("pure projection matches TextArea snapshot without a second buffer")
    func pureProjectionLockstep() {
        let area = TextArea()
        area.showScrollbar = false
        area.tabWidth = 0
        area.setText("hello world")
        area.setSelection(anchor: 0, head: 5)
        area.setCursor(5)
        let rect = TextAreaRect(x: 2, y: 1, width: 40, height: 3)
        let fromArea = area.composerSnapshot(area: rect, state: TextAreaState())
        let projected = projectComposerGeometry(
            text: area.text,
            cursorUTF8: area.cursor,
            selectionUTF8: area.selectionRange,
            selectedText: area.selectedText(),
            state: TextAreaState(),
            scrollOverride: area.scrollOverrideValue,
            area: rect,
            showScrollbar: false,
            tabWidth: 0
        )
        #expect(projected.text == fromArea.text)
        #expect(projected.cursorUTF8 == fromArea.cursorUTF8)
        #expect(projected.selectionUTF8 == fromArea.selectionUTF8)
        #expect(projected.selectedText == fromArea.selectedText)
        #expect(projected.wrapOptions == fromArea.wrapOptions)
        #expect(projected.wrappedRows == fromArea.wrappedRows)
        #expect(projected.cursorScreenPosition == fromArea.cursorScreenPosition)
        #expect(projected.selectionScreenSpans == fromArea.selectionScreenSpans)
        let hit = projectComposerScreenHit(col: 4, row: 1, snapshot: projected, area: rect)
        #expect(hit?.utf8Offset == area.bufferPosAtScreen(col: 4, row: 1, area: rect, state: TextAreaState()))
    }
}

private extension String {
    func utf8OffsetOfASCII(_ needle: String) -> Int {
        guard let range = range(of: needle) else { return 0 }
        return self[..<range.lowerBound].utf8.count
    }
}
