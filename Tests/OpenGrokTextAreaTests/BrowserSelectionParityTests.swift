import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokTextArea

@Suite("Rust browser-style prompt selection and clipboard parity")
struct BrowserSelectionParityTests {
    @Test("Shift arrows extend from a stable anchor and reversal clears the selection")
    func shiftArrowSelection() {
        let area = makeArea("alpha beta", cursor: 0)

        area.input(key(.right, [.shift]))
        area.input(key(.right, [.shift]))
        #expect(area.selectionRange == 0..<2)
        #expect(area.cursor == 2)

        area.input(key(.left, [.shift]))
        #expect(area.selectionRange == 0..<1)
        area.input(key(.left, [.shift]))
        #expect(area.selectionRange == nil)
        #expect(area.cursor == 0)
    }

    @Test("plain grapheme movement collapses to the directional edge without moving again")
    func directionalArrowCollapse() {
        let left = makeArea("alpha beta", cursor: 0)
        left.input(key(.right, [.shift]))
        left.input(key(.right, [.shift]))
        left.input(key(.left))
        #expect(left.selectionRange == nil)
        #expect(left.cursor == 0)

        let right = makeArea("alpha beta", cursor: 5)
        right.input(key(.left, [.shift]))
        right.input(key(.left, [.shift]))
        right.input(key(.right))
        #expect(right.selectionRange == nil)
        #expect(right.cursor == 5)
    }

    @Test("Alt and Control Shift arrows select full words")
    func wordSelection() {
        for modifier: KeyModifiers in [.alt, .control] {
            let area = makeArea("alpha beta", cursor: 0)
            area.input(key(.right, [.shift, modifier]))
            #expect(area.selectedText() == "alpha")

            area.input(key(.right, [.shift, modifier]))
            #expect(area.selectedText() == "alpha beta")
            area.input(key(.left, [.shift, modifier]))
            #expect(area.selectedText() == "alpha ")
        }
    }

    @Test("typing and Enter replace selections in exactly one undo step")
    func replacementUndoGrouping() {
        let typing = makeArea("alpha beta", cursor: 0)
        typing.clearHistory()
        typing.input(key(.right, [.shift, .alt]))
        typing.input(key(.char("x")))
        #expect(typing.text == "x beta")
        #expect(typing.selectionRange == nil)
        #expect(typing.undo())
        #expect(typing.text == "alpha beta")
        #expect(!typing.canUndo)

        let newline = makeArea("hello world")
        newline.clearHistory()
        newline.setSelection(anchor: 0, head: 5)
        newline.input(key(.enter))
        #expect(newline.text == "\n world")
        #expect(newline.undo())
        #expect(newline.text == "hello world")
        #expect(!newline.canUndo)
    }

    @Test("Home and End select full logical lines rather than wrapped visual rows")
    func shiftHomeEnd() {
        let area = makeArea("abcdefghijk", cursor: 7)
        _ = area.wrappedLines(width: 5)

        area.input(key(.end, [.shift]))
        #expect(area.selectionRange == 7..<11)
        area.input(key(.home, [.shift]))
        #expect(area.selectionRange == 0..<7)
    }

    @Test("Super and Meta arrows target the current visual wrapped row")
    func superVisualRowMovement() {
        for commandModifier: KeyModifiers in [.superKey, .meta] {
            let left = makeArea("abcdefghijk", cursor: 7)
            _ = left.wrappedLines(width: 5)
            left.input(key(.left, [commandModifier]))
            #expect(left.cursor == 5)

            let right = makeArea("abcdefghijk", cursor: 7)
            _ = right.wrappedLines(width: 5)
            right.input(key(.right, [commandModifier]))
            #expect(right.cursor == 10)

            let selecting = makeArea("abcdefghijk", cursor: 7)
            _ = selecting.wrappedLines(width: 5)
            selecting.input(key(.right, [.shift, commandModifier]))
            #expect(selecting.selectionRange == 7..<10)
        }
    }

    @Test("Shift vertical movement selects rows while Super vertical remains host-reserved")
    func shiftVerticalSelection() {
        let area = makeArea("one\ntwo\nthree", cursor: 4)

        area.input(key(.down, [.shift]))
        #expect(area.selectionRange == 4..<8)
        area.input(key(.up, [.shift]))
        #expect(area.selectionRange == nil)
        #expect(area.cursor == 4)

        area.input(key(.down, [.shift, .superKey]))
        #expect(area.selectionRange == nil)
    }

    @Test("Command copy preserves selection while Command cut removes and stages it")
    func commandCopyAndCut() {
        for commandModifier: KeyModifiers in [.superKey, .meta] {
            let area = makeArea("alpha beta")
            area.setSelection(anchor: 0, head: 5)

            area.input(key(.char("c"), [commandModifier]))
            #expect(area.takeClipboard() == "alpha")
            #expect(area.selectionRange == 0..<5)
            #expect(area.text == "alpha beta")

            area.input(key(.char("x"), [commandModifier]))
            #expect(area.takeClipboard() == "alpha")
            #expect(area.text == " beta")
            #expect(area.selectionRange == nil)
        }
    }

    @Test("Control X cuts selections without changing Control C or Command A ownership")
    func terminalOwnedShortcuts() {
        let cutting = makeArea("alpha beta")
        cutting.setSelection(anchor: 0, head: 5)
        cutting.input(key(.char("x"), [.control]))
        #expect(cutting.text == " beta")
        #expect(cutting.takeClipboard() == "alpha")

        let readline = makeArea("alpha beta", cursor: 5)
        readline.input(key(.char("a"), [.control]))
        #expect(readline.cursor == 0)
        #expect(readline.selectionRange == nil)

        readline.setCursor(5)
        readline.input(key(.char("a"), [.superKey]))
        #expect(readline.cursor == 5)
        #expect(readline.selectionRange == nil)

        readline.setSelection(anchor: 0, head: 5)
        readline.input(key(.char("c"), [.control]))
        #expect(readline.takeClipboard() == nil)
    }

    @Test("Control V and external paste replace the selection as one undo action")
    func pasteReplacesSelection() {
        let clipboard = InternalClipboard()
        clipboard.set("replacement")
        let pasted = makeArea("hello world")
        pasted.setClipboardProvider(clipboard)
        pasted.clearHistory()
        pasted.setSelection(anchor: 6, head: 11)
        pasted.input(key(.char("v"), [.control]))
        #expect(pasted.text == "hello replacement")
        #expect(pasted.selectionRange == nil)
        #expect(pasted.undo())
        #expect(pasted.text == "hello world")
        #expect(!pasted.canUndo)

        let external = makeArea("hello world")
        external.clearHistory()
        external.setSelection(anchor: 6, head: 11)
        external.insertStrReplacingSelection("🌍")
        #expect(external.text == "hello 🌍")
        #expect(external.undo())
        #expect(external.text == "hello world")
    }

    @Test("Control Y replaces selections without losing the kill-ring contents")
    func yankReplacesSelection() {
        let area = makeArea("alpha beta", cursor: 5)
        area.input(key(.char("k"), [.control]))
        #expect(area.text == "alpha")

        area.clearHistory()
        area.setSelection(anchor: 0, head: 5)
        area.input(key(.char("y"), [.control]))
        #expect(area.text == " beta")
        #expect(area.selectionRange == nil)
        #expect(area.undo())
        #expect(area.text == "alpha")
        #expect(!area.canUndo)
    }

    @Test("kill chords remove only the selection and preserve it for a later yank")
    func killSelectedText() {
        let commands = [
            key(.char("k"), [.control]),
            key(.char("u"), [.control]),
            key(.char("w"), [.control]),
            key(.delete, [.control]),
            key(.char("d"), [.alt])
        ]

        for command in commands {
            let area = makeArea("alpha beta")
            area.setSelection(anchor: 0, head: 5)
            area.input(command)
            #expect(area.text == " beta")
            area.input(key(.char("y"), [.control]))
            #expect(area.text == "alpha beta")
        }
    }

    @Test("stale UTF-8 offsets expand outward to whole scalar and grapheme clusters")
    func unicodeSelectionBoundaries() {
        let bulb = makeArea("a💡z")
        bulb.setSelection(anchor: 2, head: 3)
        #expect(bulb.selectionRange == 1..<5)
        #expect(bulb.selectedText() == "💡")

        let cluster = "👩🏽\u{200D}💻"
        let combined = makeArea("a\(cluster)z")
        combined.setSelection(anchor: 3, head: 5)
        #expect(combined.selectionRange == 1..<(1 + cluster.utf8.count))
        #expect(combined.selectedText() == cluster)

        combined.input(key(.char("x")))
        #expect(combined.text == "axz")
    }

    @Test("selection ranges include entire atomic file and paste elements")
    func atomicElementSelectionBoundaries() {
        let area = makeArea("a", cursor: 1)
        let element = area.insertElement(kind: .fileRef, text: "TOKEN")
        area.insertStr("z")
        area.setSelection(anchor: 2, head: 3)

        #expect(area.selectionRange == 1..<6)
        #expect(area.selectedText() == "TOKEN")
        #expect(area.allElements.contains { $0.id == element })
        #expect(area.deleteSelection())
        #expect(area.text == "az")
        #expect(area.allElements.isEmpty)
    }

    @Test("uppercase Control Shift readline chords extend rather than insert")
    func uppercaseReadlineSelection() {
        let right = makeArea("hello world", cursor: 5)
        right.input(key(.char("E"), [.control, .shift]))
        #expect(right.selectionRange == 5..<11)

        let left = makeArea("hello world", cursor: 5)
        left.input(key(.char("A"), [.control, .shift]))
        #expect(left.selectionRange == 0..<5)

        let grapheme = makeArea("hello", cursor: 2)
        grapheme.input(key(.char("F"), [.control, .shift]))
        #expect(grapheme.selectionRange == 2..<3)
    }

    @Test("plain word and logical movements continue after collapsing to the matching edge")
    func continuingMovementAfterCollapse() {
        let word = makeArea("alpha beta gamma")
        word.setSelection(anchor: 6, head: 10)
        word.input(key(.right, [.alt]))
        #expect(word.selectionRange == nil)
        #expect(word.cursor == 16)

        let line = makeArea("alpha beta gamma")
        line.setSelection(anchor: 6, head: 10)
        line.input(key(.home))
        #expect(line.selectionRange == nil)
        #expect(line.cursor == 0)
    }

    @Test("zero-width stale selections do not swallow normal deletion")
    func zeroWidthSelectionFallback() {
        let area = makeArea("abc", cursor: 2)
        area.setSelection(anchor: 2, head: 2)
        area.input(key(.backspace))

        #expect(area.text == "ac")
        #expect(area.selectionRange == nil)
    }

    @Test("movement resolver classifies navigation without stealing text or host chords")
    func movementResolver() {
        #expect(resolveMovement(key(.left)) == .command(.moveGraphemeLeft, .start))
        #expect(resolveMovement(key(.right, [.alt])) == .command(.moveWordRight(.small), .end))
        #expect(resolveMovement(key(.left, [.superKey])) == .visualRowStart)
        #expect(resolveMovement(key(.right, [.meta])) == .visualRowEnd)
        #expect(resolveMovement(key(.home)) == .logicalLineStart)
        #expect(resolveMovement(key(.end)) == .logicalLineEnd)
        #expect(resolveMovement(key(.char("p"), [.control])) == .visualRowUp)
        #expect(resolveMovement(key(.char("n"), [.control])) == .visualRowDown)
        #expect(resolveMovement(key(.char("x"))) == nil)
        #expect(resolveMovement(key(.char("a"), [.superKey])) == nil)
    }

    private func makeArea(_ text: String, cursor: Int? = nil) -> TextArea {
        let area = TextArea()
        area.setText(text)
        if let cursor { area.setCursor(cursor) }
        return area
    }

    private func key(_ code: KeyCode, _ modifiers: KeyModifiers = []) -> KeyEvent {
        KeyEvent(key: code, modifiers: modifiers)
    }
}
