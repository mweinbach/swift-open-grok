// PagerComposerHitTests.swift
//
// Pure hit mapping against `PagerComposerHitModel` / `makePagerComposerHitModel`
// — same `projectComposerGeometry` wrap as `renderComposer`.
// No LiveComposition / PromptEditor / TextArea instance.

import Testing
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore
import OpenGrokTextArea

@Suite("PagerComposerHit")
struct PagerComposerHitTests {
    private func model(
        text: String,
        width: Int = 40,
        height: Int = 6,
        cursor: Int? = nil,
        cursorUTF8: Int? = nil,
        selectionUTF8: Range<Int>? = nil,
        isFocused: Bool = true,
        maximumHeight: Int = 8
    ) throws -> PagerComposerHitModel {
        let input = PagerComposerState(
            text: text,
            cursorCharacterOffset: cursor,
            cursorUTF8: cursorUTF8,
            selectionUTF8: selectionUTF8,
            isFocused: isFocused,
            maximumHeight: maximumHeight
        )
        let area = TerminalRect(x: 2, y: 10, width: width, height: height)
        return try #require(makePagerComposerHitModel(input, in: area))
    }

    @Test("wrapDisplayLinesWithRanges still matches wrapDisplayLines for transcript")
    func rangesMatchWrapDisplayLines() {
        let samples = ["", "hello", "hello\nworld", "a\n\nb", String(repeating: "x", count: 30)]
        for sample in samples {
            let width = 8
            let plain = wrapDisplayLines(sample, width: width)
            let ranged = wrapDisplayLinesWithRanges(sample, width: width)
            #expect(ranged.map(\.text) == plain)
        }
    }

    @Test("composer wrap rows match composerWrapOptions, not wrapDisplayLinesWithRanges")
    func composerRowsUseTextAreaWrap() throws {
        let hit = try model(text: "hello world", width: 20, height: 6, cursor: 0)
        let expected = wrapRanges("hello world", options: composerWrapOptions(width: hit.textWidth))
        #expect(hit.lines.map(\.utf8Range) == expected)
        #expect(hit.textWidth == 14)
    }

    @Test("single-line text cells are content; prefix and border are focus-only")
    func singleLineContentVsChrome() throws {
        let hit = try model(text: "hello", cursor: 5)
        let contentX = hit.textArea.x + hit.prefixWidth
        let y = hit.textArea.y
        #expect(hit.hit(x: contentX, y: y) == .content)
        #expect(hit.hit(x: contentX + 2, y: y) == .content)
        #expect(hit.hit(x: contentX + 10, y: y) == .content)
        #expect(hit.hit(x: hit.pane.x, y: y) == .focusOnly)
        #expect(hit.hit(x: hit.textArea.x, y: y) == .focusOnly)
        #expect(hit.hit(x: hit.pane.x - 1, y: y) == nil)
        let projected = projectComposerGeometry(
            text: "hello",
            cursorUTF8: 5,
            selectionUTF8: nil,
            area: hit.contentRect
        )
        let screenHit = projectComposerScreenHit(
            col: contentX + 2,
            row: y,
            snapshot: projected,
            area: hit.contentRect
        )
        #expect(screenHit?.utf8Offset == 2)
    }

    @Test("multiline hard-newline rows stay content hits")
    func multilineHardNewlines() throws {
        let hit = try model(text: "ab\ncd", cursor: 0)
        let contentX = hit.textArea.x + hit.prefixWidth
        #expect(hit.lines.count >= 2)
        #expect(hit.hit(x: contentX + 1, y: hit.textArea.y) == .content)
        #expect(hit.hit(x: contentX, y: hit.textArea.y + 1) == .content)
    }

    @Test("soft-wrapped rows use composerWrapOptions width")
    func softWrappedRows() throws {
        let hit = try model(text: String(repeating: "a", count: 20), width: 20, height: 6, cursor: 0)
        #expect(hit.textWidth == 14)
        #expect(hit.lines.count >= 2)
        #expect(hit.lines[0].endOffset == 14)
        #expect(hit.lines[1].startOffset == 14)
        let contentX = hit.textArea.x + hit.prefixWidth
        #expect(hit.hit(x: contentX, y: hit.textArea.y + 1) == .content)
        let projected = projectComposerGeometry(
            text: String(repeating: "a", count: 20),
            cursorUTF8: 0,
            selectionUTF8: nil,
            area: hit.contentRect
        )
        let screenHit = projectComposerScreenHit(
            col: contentX + 2,
            row: hit.textArea.y + 1,
            snapshot: projected,
            area: hit.contentRect
        )
        #expect(screenHit?.utf8Offset == 16)
    }

    @Test("prefix and border cells are focus-only; outside pane is nil")
    func prefixBorderAndOutside() throws {
        let hit = try model(text: "hello", cursor: 0)
        #expect(hit.hit(x: hit.pane.x, y: hit.textArea.y) == .focusOnly)
        #expect(hit.hit(x: hit.textArea.x, y: hit.textArea.y) == .focusOnly)
        #expect(hit.hit(x: hit.textArea.x + hit.prefixWidth - 1, y: hit.textArea.y) == .focusOnly)
        #expect(hit.hit(x: hit.textArea.x + hit.prefixWidth, y: hit.pane.y) == .focusOnly)
        #expect(hit.hit(x: hit.pane.x - 1, y: hit.textArea.y) == nil)
        #expect(hit.hit(x: hit.pane.right, y: hit.textArea.y) == nil)
        #expect(hit.hit(x: hit.textArea.x + hit.prefixWidth, y: hit.pane.bottom) == nil)
    }

    @Test("wide emoji content hit; projection snaps to cluster start")
    func wideEmojiClamp() throws {
        let text = "a😀b"
        let hit = try model(text: text, cursor: 0)
        let contentX = hit.textArea.x + hit.prefixWidth
        let y = hit.textArea.y
        let emojiWidth = UnicodeDisplayWidth.width(ofGrapheme: "😀")
        #expect(emojiWidth == 2)
        #expect(hit.hit(x: contentX, y: y) == .content)
        #expect(hit.hit(x: contentX + 1, y: y) == .content)
        #expect(hit.hit(x: contentX + 2, y: y) == .content)
        let projected = projectComposerGeometry(
            text: text,
            cursorUTF8: 0,
            selectionUTF8: nil,
            area: hit.contentRect
        )
        #expect(projectComposerScreenHit(
            col: contentX + 1, row: y, snapshot: projected, area: hit.contentRect
        )?.utf8Offset == 1)
        #expect(projectComposerScreenHit(
            col: contentX + 2, row: y, snapshot: projected, area: hit.contentRect
        )?.utf8Offset == 1)
    }

    @Test("vertical scroll uses firstVisibleRow from TextArea effective scroll")
    func verticalScrollAndClamp() throws {
        let text = (0..<8).map { "line\($0)" }.joined(separator: "\n")
        let hit = try model(text: text, width: 40, height: 5, cursor: text.count)
        #expect(hit.textArea.height == 3)
        #expect(hit.firstVisibleRow > 0)
        let contentX = hit.textArea.x + hit.prefixWidth
        #expect(hit.hit(x: contentX, y: hit.textArea.y) == .content)
        #expect(hit.lines[hit.firstVisibleRow].startOffset > 0)
    }

    @Test("empty draft text cell is content")
    func emptyDraft() throws {
        let hit = try model(text: "", cursor: 0)
        let contentX = hit.textArea.x + hit.prefixWidth
        #expect(hit.hit(x: contentX, y: hit.textArea.y) == .content)
    }

    @Test("selection spans paint with the same projection the hit model uses")
    func selectionHighlightUsesProjection() {
        let text = "hello world"
        let input = PagerComposerState(
            text: text,
            cursorCharacterOffset: 5,
            cursorUTF8: 5,
            selectionUTF8: 0..<5,
            selectedText: "hello",
            isFocused: true,
            maximumHeight: 8
        )
        let area = TerminalRect(x: 0, y: 0, width: 40, height: 6)
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 12),
            input: input
        ))
        let hit = result.layout.composerHit
        #expect(hit != nil)
        let content = hit!.contentRect
        let snap = projectComposerGeometry(
            text: text,
            cursorUTF8: 5,
            selectionUTF8: 0..<5,
            selectedText: "hello",
            area: content
        )
        #expect(!snap.selectionScreenSpans.isEmpty)
        let span = snap.selectionScreenSpans[0]
        let theme = PagerRenderTheme.default
        var highlighted = 0
        for dx in 0..<span.width {
            if let cell = result.buffer.cell(x: span.x + dx, y: span.y) {
                if cell.background == theme.textPrimary
                    || cell.style.contains(.reverse)
                {
                    highlighted += 1
                }
            }
        }
        #expect(highlighted == span.width)
    }
}
