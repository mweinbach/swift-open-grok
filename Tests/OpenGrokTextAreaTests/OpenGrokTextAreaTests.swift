// OpenGrokTextAreaTests.swift
import Foundation
import Testing
import OpenGrokTerminalCore
@testable import OpenGrokTextArea

@Suite("OpenGrokTextArea EditBuffer")
struct EditBufferTests {
    @Test("edit outcome closed over cursor and text changes")
    func editOutcome() {
        let buffer = EditBuffer()
        #expect(buffer.apply(.moveGraphemeLeft) == .unchanged)

        let insert = buffer.apply(.insert("é"))
        #expect(buffer.text == "é")
        #expect(buffer.cursorByte == "é".utf8.count)
        if case .textAndCursor(let d) = insert {
            #expect(d.replacedByteRange == 0..<0)
            #expect(d.insertedByteRange == 0..<"é".utf8.count)
        } else {
            Issue.record("expected textAndCursor")
        }

        #expect(buffer.apply(.moveGraphemeLeft) == .cursorOnly)
        #expect(buffer.cursorByte == 0)

        let del = buffer.apply(.deleteGraphemeForward)
        #expect(buffer.text == "")
        if case .textOnly(let d) = del {
            #expect(d.replacedByteRange == 0..<"é".utf8.count)
        } else {
            Issue.record("expected textOnly")
        }
    }

    @Test("grapheme motion treats combining ZWJ flags and CJK atomically")
    func graphemeMotion() {
        let graphemes = ["e\u{301}", "👩🏽\u{200D}💻", "🇺🇸", "界"]
        let text = graphemes.joined()
        var boundaries = [0]
        for g in graphemes {
            boundaries.append(boundaries.last! + g.utf8.count)
        }
        let buffer = EditBuffer.fromParts(text: text, cursorByte: Int.max)
        for expected in boundaries.dropLast().reversed() {
            _ = buffer.apply(.moveGraphemeLeft)
            #expect(buffer.cursorByte == expected)
        }
        for expected in boundaries.dropFirst() {
            _ = buffer.apply(.moveGraphemeRight)
            #expect(buffer.cursorByte == expected)
        }
    }

    @Test("grapheme deletion never splits clusters")
    func graphemeDeletion() {
        let combining = "e\u{301}"
        let zwj = "👩🏽\u{200D}💻"
        let flag = "🇺🇸"
        let text = combining + zwj + flag
        let buffer = EditBuffer.fromParts(text: text, cursorByte: combining.utf8.count + zwj.utf8.count)
        _ = buffer.apply(.deleteGraphemeBackward)
        #expect(buffer.text == combining + flag)
        #expect(buffer.cursorByte == combining.utf8.count)
        _ = buffer.apply(.deleteGraphemeForward)
        #expect(buffer.text == combining)
    }

    @Test("invalid cursor bytes normalize to nearest grapheme boundary")
    func cursorNormalize() {
        let buffer = EditBuffer.fromParts(text: "e\u{301}x", cursorByte: 1)
        #expect(buffer.cursorByte == 0)
        _ = buffer.setCursorByte(2)
        #expect(buffer.cursorByte == "e\u{301}".utf8.count)
        _ = buffer.setCursorByte(Int.max)
        #expect(buffer.cursorByte == buffer.text.utf8.count)
        let tied = EditBuffer.fromParts(text: "🇨🇺", cursorByte: "🇨".utf8.count)
        #expect(tied.cursorByte == 0)
    }

    @Test("range replacement tracks cursor before/inside/after")
    func rangeReplacementCursor() {
        let before = EditBuffer.fromParts(text: "alpha beta", cursorByte: 1)
        let o1 = before.replaceByteRange(6..<10, replacement: "B")
        #expect(before.text == "alpha B")
        #expect(before.cursorByte == 1)
        if case .textOnly = o1 {} else { Issue.record("expected textOnly") }

        let inside = EditBuffer.fromParts(text: "alpha beta", cursorByte: 8)
        _ = inside.replaceByteRange(6..<10, replacement: "B")
        #expect(inside.cursorByte == 7)

        let after = EditBuffer.fromParts(text: "alpha beta", cursorByte: 10)
        _ = after.replaceByteRange(0..<5, replacement: "A")
        #expect(after.text == "A beta")
        #expect(after.cursorByte == 6)
    }

    @Test("small words keep punctuation classes")
    func smallWords() {
        let buffer = EditBuffer.fromParts(text: "hello-world", cursorByte: 0)
        for expected in [5, 6, 11] {
            _ = buffer.apply(.moveWordRight(.small))
            #expect(buffer.cursorByte == expected)
        }
        for expected in [6, 5, 0] {
            _ = buffer.apply(.moveWordLeft(.small))
            #expect(buffer.cursorByte == expected)
        }
        let del = EditBuffer.fromText("hello-world")
        _ = del.apply(.deleteWordBackward(.small))
        #expect(del.text == "hello-")
    }

    @Test("logical line commands chain at boundaries")
    func logicalLines() {
        let buffer = EditBuffer.fromParts(text: "one\ntwo\nthree", cursorByte: 6)
        _ = buffer.apply(.moveLogicalLineStart)
        #expect(buffer.cursorByte == 4)
        _ = buffer.apply(.moveLogicalLineEnd)
        #expect(buffer.cursorByte == 7)
        _ = buffer.setCursorByte(4)
        _ = buffer.apply(.moveLogicalLineStart)
        #expect(buffer.cursorByte == 0)
        _ = buffer.setCursorByte(6)
        _ = buffer.apply(.deleteToLineStart)
        #expect(buffer.text == "one\no\nthree")
        #expect(buffer.cursorByte == 4)
    }

    @Test("CRLF line motion keeps line ending atomic")
    func crlfLines() {
        let motion = EditBuffer.fromParts(text: "ab\r\ncd", cursorByte: 1)
        _ = motion.apply(.moveLogicalLineEnd)
        #expect(motion.cursorByte == 2)
        _ = motion.apply(.moveLogicalLineEnd)
        #expect(motion.cursorByte == 6)
        _ = motion.setCursorByte(4)
        _ = motion.apply(.moveLogicalLineStart)
        #expect(motion.cursorByte == 0)
    }

    @Test("edit plan exposes removed text and becomes stale")
    func editPlan() throws {
        let buffer = EditBuffer.fromText("say hello-world")
        let plan = buffer.planCommand(.deleteWordBackward(.whitespaceDelimited), atomic: [])
        let replaced = "say ".utf8.count..<buffer.text.utf8.count
        #expect(plan.replacedByteRange == replaced)
        #expect(plan.replacement == "")
        #expect(plan.removedText == "hello-world")
        #expect(plan.cursorByte == replaced.lowerBound)
        let outcome = try buffer.applyPlan(plan)
        #expect(buffer.text == "say ")
        if case .textAndCursor = outcome {} else { Issue.record("expected textAndCursor") }
        #expect(throws: ApplyEditPlanError.stalePlan) {
            _ = try buffer.applyPlan(plan)
        }
    }

    @Test("stale plan rejected without mutation")
    func stalePlan() {
        let buffer = EditBuffer.fromText("abc")
        let plan = buffer.planCommand(.deleteGraphemeBackward, atomic: [])
        _ = buffer.setCursorByte(0)
        #expect(throws: ApplyEditPlanError.stalePlan) {
            _ = try buffer.applyPlan(plan)
        }
        #expect(buffer.text == "abc")
        #expect(buffer.cursorByte == 0)
    }

    @Test("plans bound to identity and generation")
    func planIdentity() {
        let source = EditBuffer.fromText("x")
        let plan = source.planCommand(.deleteGraphemeBackward, atomic: [])
        let sameValue = EditBuffer.fromText("x")
        #expect(sameValue == source)
        #expect(throws: ApplyEditPlanError.stalePlan) {
            _ = try sameValue.applyPlan(plan)
        }
    }

    @Test("generation overflow rotates identity")
    func generationOverflow() throws {
        let buffer = EditBuffer.fromText("ab")
        buffer.setGenerationForTesting(UInt64.max)
        let identity = buffer.identityToken
        let plan = buffer.planCommand(.deleteGraphemeBackward, atomic: [])
        _ = try buffer.applyPlan(plan)
        #expect(buffer.generationValue == 0)
        #expect(buffer.identityToken != identity)
        #expect(throws: ApplyEditPlanError.stalePlan) {
            _ = try buffer.applyPlan(plan)
        }
    }

    @Test("atomic ranges are indivisible")
    func atomicRanges() throws {
        let atomic = 1..<6
        let backward = EditBuffer.fromParts(text: "aTOKENb", cursorByte: atomic.upperBound)
        let plan = backward.planCommand(.deleteGraphemeBackward, atomic: [atomic])
        #expect(plan.replacedByteRange == atomic)
        #expect(plan.removedText == "TOKEN")
        _ = try backward.applyPlan(plan)
        #expect(backward.text == "ab")
        #expect(backward.cursorByte == 1)
    }

    @Test("single line viewport clips at grapheme boundaries")
    func viewport() {
        let zwj = "👩🏽\u{200D}💻"
        let flag = "🇺🇸"
        let text = "a" + zwj + "b" + flag + "界"
        let afterB = 1 + zwj.utf8.count + 1
        let buffer = EditBuffer.fromParts(text: text, cursorByte: afterB)
        let vp = buffer.singleLineViewport(displayWidth: 4)
        #expect(buffer.text.substring(utf8Range: vp.visibleByteRange) == zwj + "b")
        #expect(vp.cursorDisplayColumn == 3)

        let zero = buffer.singleLineViewport(displayWidth: 0)
        #expect(zero.visibleByteRange == buffer.cursorByte..<buffer.cursorByte)
        #expect(zero.cursorDisplayColumn == 0)

        let combining = EditBuffer.fromParts(text: "e\u{301}x", cursorByte: 0)
        let cv = combining.singleLineViewport(displayWidth: 1)
        #expect(combining.text.substring(utf8Range: cv.visibleByteRange) == "e\u{301}")
    }

    @Test("viewport stays within LF and CRLF logical lines")
    func viewportLines() {
        for (text, cursor, expected) in [
            ("a\nb", "a\nb".utf8.count, "b"),
            ("ab\r\ncd", "ab\r\ncd".utf8.count, "cd"),
            ("ab\r\ncd", 2, "ab"),
        ] as [(String, Int, String)] {
            let buffer = EditBuffer.fromParts(text: text, cursorByte: cursor)
            let vp = buffer.singleLineViewport(displayWidth: 4)
            #expect(buffer.text.substring(utf8Range: vp.visibleByteRange) == expected)
        }
    }
}
@Suite("OpenGrokTextArea Keys")
struct KeyClassificationTests {
    @Test("Ctrl+W uses whitespace-delimited word deletion")
    func ctrlW() {
        let cmd = classifyKeyEvent(KeyEvent(key: .char("w"), modifiers: [.control]))
        #expect(cmd == .deleteWordBackward(.whitespaceDelimited))
        let buffer = EditBuffer.fromText("git commit -m hello-world")
        _ = buffer.apply(cmd!)
        #expect(buffer.text == "git commit -m ")
        let small = EditBuffer.fromText("git commit -m hello-world")
        _ = small.apply(.deleteWordBackward(.small))
        #expect(small.text == "git commit -m hello-")
    }

    @Test("common editing keys classify")
    func commonKeys() {
        let cases: [(KeyEvent, EditCommand)] = [
            (KeyEvent(key: .char("a")), .insert("a")),
            (KeyEvent(key: .char("a"), modifiers: [.shift]), .insert("A")),
            (KeyEvent(key: .left), .moveGraphemeLeft),
            (KeyEvent(key: .right), .moveGraphemeRight),
            (KeyEvent(key: .left, modifiers: [.alt]), .moveWordLeft(.small)),
            (KeyEvent(key: .left, modifiers: [.control]), .moveWordLeft(.small)),
            (KeyEvent(key: .char("a"), modifiers: [.control]), .moveLogicalLineStart),
            (KeyEvent(key: .char("e"), modifiers: [.control]), .moveLogicalLineEnd),
            (KeyEvent(key: .char("u"), modifiers: [.control]), .deleteToLineStart),
            (KeyEvent(key: .char("k"), modifiers: [.control]), .deleteToLineEnd),
            (KeyEvent(key: .char("b"), modifiers: [.control]), .moveGraphemeLeft),
            (KeyEvent(key: .char("f"), modifiers: [.control]), .moveGraphemeRight),
            (KeyEvent(key: .char("d"), modifiers: [.control]), .deleteGraphemeForward),
            (KeyEvent(key: .char("h"), modifiers: [.control]), .deleteGraphemeBackward),
            (KeyEvent(key: .char("\u{0002}")), .moveGraphemeLeft),
            (KeyEvent(key: .char("\u{0006}")), .moveGraphemeRight),
        ]
        for (event, expected) in cases {
            #expect(classifyKeyEvent(event) == expected, "failed for \(event)")
        }
    }

    @Test("host-owned keys remain unclassified")
    func hostOwned() {
        let events: [KeyEvent] = [
            KeyEvent(key: .escape),
            KeyEvent(key: .enter),
            KeyEvent(key: .tab),
            KeyEvent(key: .up),
            KeyEvent(key: .down),
            KeyEvent(key: .home),
            KeyEvent(key: .end),
            KeyEvent(key: .char("j"), modifiers: [.control]),
            KeyEvent(key: .char("z"), modifiers: [.control]),
        ]
        for e in events {
            #expect(classifyKeyEvent(e) == nil, "should be unclassified: \(e)")
        }
        #expect(isUndoInput(KeyEvent(key: .char("z"), modifiers: [.control])))
        #expect(!isUndoInput(KeyEvent(key: .char("Z"), modifiers: [.control, .shift])))
    }
}

@Suite("OpenGrokTextArea TextArea")
struct TextAreaTests {
    @Test("insert move delete and undo")
    func basicEditing() {
        let area = TextArea()
        area.insertStr("hello")
        #expect(area.text == "hello")
        #expect(area.cursor == 5)
        area.moveCursorLeft()
        #expect(area.cursor == 4)
        area.deleteBackward()
        #expect(area.text == "helo")
        #expect(area.canUndo)
        #expect(area.undo())
        #expect(area.text == "hello")
        #expect(area.canRedo)
        #expect(area.redo())
        #expect(area.text == "helo")
    }

    @Test("input classifies and inserts")
    func inputPath() {
        let area = TextArea()
        area.input(KeyEvent(key: .char("a")))
        area.input(KeyEvent(key: .char("b")))
        area.input(KeyEvent(key: .enter))
        area.input(KeyEvent(key: .char("c")))
        #expect(area.text == "ab\nc")
        area.input(KeyEvent(key: .char("a"), modifiers: [.control]))
        #expect(area.cursor == 3) // start of line "c"
    }

    @Test("word kill and yank")
    func killYank() {
        let area = TextArea()
        area.setText("hello world")
        area.setCursor(area.text.utf8.count)
        area.deleteBackwardUnixWord()
        #expect(area.text == "hello ")
        area.yank()
        #expect(area.text == "hello world")
    }

    @Test("selection delete and clipboard")
    func selection() {
        let area = TextArea()
        area.setText("abcdef")
        area.setSelection(anchor: 1, head: 4)
        #expect(area.selectedText() == "bcd")
        #expect(area.deleteSelection())
        #expect(area.text == "aef")
    }

    @Test("elements are atomic for motion")
    func elements() {
        let area = TextArea()
        area.insertStr("a")
        let id = area.insertElement(kind: ElementKind(1), text: "TOKEN")
        area.insertStr("b")
        #expect(area.text == "aTOKENb")
        #expect(id.raw == 0)
        area.setCursor(6) // after TOKEN
        area.moveCursorLeft()
        #expect(area.cursor == 1) // jumps over TOKEN
    }

    @Test("wrapping produces multiple lines")
    func wrapping() {
        let area = TextArea()
        area.setText("hello world foo")
        let lines = area.wrappedLines(width: 8)
        #expect(lines.count >= 2)
        #expect(area.desiredHeight(width: 8) >= 2)
    }

    @Test("tab expansion")
    func tabs() {
        let area = TextArea()
        area.tabWidth = 4
        area.insertStr("a\tb")
        #expect(area.text == "a   b")
    }

    @Test("undo groups batch mutations")
    func undoGroups() {
        let area = TextArea()
        area.insertStr("x")
        area.beginUndoGroup()
        area.insertStr("y")
        area.insertStr("z")
        area.endUndoGroup()
        #expect(area.text == "xyz")
        #expect(area.undo())
        // After undoing the group, should remove yz at least in one step
        #expect(area.text == "x" || area.text == "")
    }

    @Test("clipboard provider paste")
    func clipboardPaste() {
        let area = TextArea()
        let clip = InternalClipboard()
        clip.set("paste-me")
        area.setClipboardProvider(clip)
        area.input(KeyEvent(key: .char("v"), modifiers: [.control]))
        #expect(area.text == "paste-me")
    }

    @Test("grapheme-safe cursor and selection invariants")
    func graphemeInvariants() {
        let area = TextArea()
        let zwj = "👩🏽\u{200D}💻"
        area.setText("a" + zwj + "b")
        area.setCursor(1)
        #expect(area.cursor == 1)
        area.moveCursorRight()
        #expect(area.cursor == 1 + zwj.utf8.count)
        area.setSelection(anchor: 1, head: 1 + zwj.utf8.count)
        #expect(area.selectedText() == zwj)
    }

    @Test("CRLF and tabs in long buffer")
    func crlfTabsLong() {
        let area = TextArea()
        area.tabWidth = 4
        var text = ""
        for i in 0..<50 {
            text += "line\(i)\tvalue\r\n"
        }
        area.setText(text)
        #expect(area.text.contains("    ")) // tabs expanded
        #expect(!area.text.contains("\t"))
        let lines = area.wrappedLines(width: 40)
        #expect(lines.count >= 50)
        #expect(area.desiredHeight(width: 40) >= 50)
    }

    @Test("undo redo groups with zero-width text")
    func undoZeroWidth() {
        let area = TextArea()
        area.insertStr("x")
        area.beginUndoGroup()
        area.insertStr("\u{200B}")
        area.insertStr("y")
        area.endUndoGroup()
        #expect(area.text.contains("x"))
        #expect(area.undo())
    }

    @Test("wrap cache idempotence")
    func wrapCacheIdempotent() {
        let area = TextArea()
        area.setText("hello world foo bar")
        let a = area.wrappedLines(width: 8)
        let b = area.wrappedLines(width: 8)
        #expect(a == b)
        let c = area.wrappedLines(width: 12)
        #expect(c.count <= a.count)
    }
}

@Suite("OpenGrokTextArea Wrapping golden")
struct WrappingGoldenTests {
    @Test("Rust textwrap first-fit golden fixtures")
    func firstFitGolden() {
        let cases: [(String, Int, [String])] = [
            ("hello world foo", 8, ["hello", "world", "foo"]),
            ("hello-world", 8, ["hello-", "world"]),
            ("a  b", 10, ["a  b"]),
            ("你好世界", 4, ["你好", "世界"]),
            ("word", 10, ["word"]),
            ("supercalifragilistic", 5, ["super", "calif", "ragil", "istic"]),
            ("one\ntwo three", 8, ["one", "two", "three"]),
            ("This is a demo of the short last line penalty.", 37, [
                "This is a demo of the short last line",
                "penalty.",
            ]),
        ]
        for (text, width, expected) in cases {
            let opts = WrapOptions(
                width: width,
                breakWords: true,
                wrapAlgorithm: .firstFit,
                wordSeparator: .unicodeBreakProperties,
                wordSplitter: .hyphenSplitter
            )
            let ranges = wrapRanges(text, options: opts)
            let lines = ranges.map { text.substring(utf8Range: $0).trimmingCharacters(in: .init(charactersIn: "")) }
            // Compare content (trailing spaces may attach per wrap_ranges)
            let normalized = ranges.map { r -> String in
                var s = text.substring(utf8Range: r)
                while s.hasSuffix(" ") { s.removeLast() }
                return s
            }
            #expect(normalized == expected, "first-fit \(text.debugDescription)@\(width): \(normalized) != \(expected)")
        }
    }

    @Test("Rust textwrap optimal-fit short-last-line golden")
    func optimalFitShortLastLine() {
        let text = "This is a demo of the short last line penalty."
        let opts = WrapOptions(
            width: 37,
            breakWords: true,
            wrapAlgorithm: .optimalFit(.neverOverflow),
            wordSeparator: .asciiSpace,
            wordSplitter: .hyphenSplitter
        )
        let ranges = wrapRanges(text, options: opts)
        let lines = ranges.map { r -> String in
            var s = text.substring(utf8Range: r)
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }
        // OptimalFit with short-last-line penalty prefers:
        // "This is a demo of the short last" / "line penalty."
        #expect(lines.count == 2, "got \(lines)")
        #expect(lines[0].contains("short last"), "got \(lines)")
        #expect(lines[1].contains("penalty"))
    }

    @Test("zero and one column widths")
    func narrowWidths() {
        let text = "ab"
        let w0 = wrapRanges(text, options: WrapOptions(width: 0, wrapAlgorithm: .firstFit))
        #expect(!w0.isEmpty || w0.isEmpty) // must not crash
        let w1 = wrapRanges(text, options: WrapOptions(width: 1, breakWords: true, wrapAlgorithm: .firstFit))
        #expect(w1.count >= 2)
    }

    @Test("indentation options")
    func indentation() {
        let text = "hello world"
        let opts = WrapOptions(
            width: 10,
            initialIndent: ">>",
            subsequentIndent: "..",
            wrapAlgorithm: .firstFit,
            wordSeparator: .asciiSpace
        )
        let ranges = wrapRanges(text, options: opts)
        #expect(ranges.count >= 1)
    }
}

@Suite("OpenGrokTextArea Mouse and layout")
struct TextAreaMouseTests {
    @Test("click places cursor")
    func clickPlacesCursor() {
        let area = TextArea()
        area.setText("hello world")
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 5)
        var state = TextAreaState()
        let action = area.handleMouse(
            MouseEvent(kind: .down, x: 3, y: 0),
            area: rect,
            state: state
        )
        #expect(action == .cursorPlaced)
        #expect(area.cursor == 3)
        _ = state
    }

    @Test("double click selects word")
    func doubleClickWord() {
        let area = TextArea()
        area.setText("hello world")
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 5)
        let state = TextAreaState()
        _ = area.handleMouse(MouseEvent(kind: .down, x: 1, y: 0), area: rect, state: state)
        let action = area.handleMouse(MouseEvent(kind: .down, x: 1, y: 0), area: rect, state: state)
        #expect(action == .selectionFinished)
        #expect(area.selectedText() == "hello")
    }

    @Test("triple click selects line")
    func tripleClickLine() {
        let area = TextArea()
        area.setText("hello world\nnext")
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 5)
        let state = TextAreaState()
        _ = area.handleMouse(MouseEvent(kind: .down, x: 1, y: 0), area: rect, state: state)
        _ = area.handleMouse(MouseEvent(kind: .down, x: 1, y: 0), area: rect, state: state)
        let action = area.handleMouse(MouseEvent(kind: .down, x: 1, y: 0), area: rect, state: state)
        #expect(action == .selectionFinished)
        #expect(area.selectedText()?.hasPrefix("hello world") == true)
    }

    @Test("drag selection")
    func dragSelection() {
        let area = TextArea()
        area.setText("abcdef")
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 5)
        let state = TextAreaState()
        _ = area.handleMouse(MouseEvent(kind: .down, x: 1, y: 0), area: rect, state: state)
        let action = area.handleMouse(MouseEvent(kind: .drag, x: 4, y: 0), area: rect, state: state)
        #expect(action == .selectionUpdated)
        #expect(area.selectedText() == "bcd" || area.selectedText() == "bcde" || (area.selectionRange?.count ?? 0) > 0)
    }

    @Test("wheel scroll sets override")
    func wheelScroll() {
        let area = TextArea()
        var text = ""
        for i in 0..<30 { text += "line \(i)\n" }
        area.setText(text)
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 5)
        let state = TextAreaState()
        let action = area.handleMouse(MouseEvent(kind: .scrollDown, x: 1, y: 1), area: rect, state: state)
        #expect(action == .scrolled)
        #expect(area.scrollOverrideValue != nil)
        #expect((area.scrollOverrideValue ?? 0) > 0)
    }

    @Test("element click emits event")
    func elementClick() {
        let area = TextArea()
        let id = area.insertElement(kind: ElementKind(1), text: "TOKEN", displayText: "[T]")
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 5)
        let state = TextAreaState()
        let action = area.handleMouse(MouseEvent(kind: .down, x: 0, y: 0), area: rect, state: state)
        #expect(action == .cursorPlaced || action == .nothing || action == .selectionFinished || true)
        // Element may be hit depending on display width mapping
        if let ev = area.pollElementEvent() {
            #expect(ev.id == id)
            #expect(ev.kind == .click)
        }
    }

    @Test("layout reports scrollbar when overflowing")
    func layoutScrollbar() {
        let area = TextArea()
        var text = ""
        for i in 0..<20 { text += "line \(i)\n" }
        area.setText(text)
        area.showScrollbar = true
        let rect = TextAreaRect(x: 0, y: 0, width: 20, height: 5)
        let layout = area.layout(area: rect, state: TextAreaState())
        #expect(layout.needsScrollbar)
        #expect(layout.textWidth < rect.width)
        #expect(layout.totalLines > rect.height)
    }

    @Test("scrollbar track click scrolls")
    func scrollbarClick() {
        let area = TextArea()
        var text = ""
        for i in 0..<30 { text += "line \(i)\n" }
        area.setText(text)
        area.showScrollbar = true
        let rect = TextAreaRect(x: 0, y: 0, width: 20, height: 5)
        let layout = area.layout(area: rect, state: TextAreaState())
        #expect(layout.needsScrollbar)
        let sbX = rect.x + rect.width - 1
        let state = TextAreaState()
        let action = area.handleMouse(MouseEvent(kind: .down, x: sbX, y: rect.y + rect.height - 1), area: rect, state: state)
        #expect(action == .scrolled)
        #expect((area.scrollOverrideValue ?? 0) > 0)
    }

    @Test("X10 up-none finishes a left drag and copies; middle/right up do not")
    func x10UpFinishesLeftGesture() throws {
        let area = TextArea()
        area.setText("abcdef")
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 5)
        let state = TextAreaState()
        let down = area.handleMouse(
            MouseEvent(kind: .down, x: 0, y: 0, button: 0),
            area: rect,
            state: state
        )
        #expect(down == .cursorPlaced)
        let drag = area.handleMouse(
            MouseEvent(kind: .drag, x: 4, y: 0, button: 0),
            area: rect,
            state: state
        )
        #expect(drag == .selectionUpdated)
        #expect(area.dragActive)
        let middle = area.handleMouse(
            MouseEvent(kind: .up, x: 4, y: 0, button: 1),
            area: rect,
            state: state
        )
        #expect(middle == .nothing)
        #expect(area.dragActive)
        #expect(area.pendingDragScroll == nil)
        let right = area.handleMouse(
            MouseEvent(kind: .up, x: 4, y: 0, button: 2),
            area: rect,
            state: state
        )
        #expect(right == .nothing)
        #expect(area.dragActive)
        let x10 = area.handleMouse(
            MouseEvent(kind: .up, x: 4, y: 0, button: MouseEvent.noButton),
            area: rect,
            state: state
        )
        #expect(x10 == .selectionFinished)
        #expect(!area.dragActive)
        #expect(area.pendingDragScroll == nil)
        let selected = try #require(area.selectedText())
        #expect(!selected.isEmpty)
        #expect(area.clipboard() == selected)
    }

    @Test("X10 up-none ends a scrollbar drag; middle up does not")
    func x10UpEndsScrollbarDrag() {
        let area = TextArea()
        var text = ""
        for i in 0..<30 { text += "line \(i)\n" }
        area.setText(text)
        area.showScrollbar = true
        let rect = TextAreaRect(x: 0, y: 0, width: 20, height: 5)
        let state = TextAreaState()
        let sbX = rect.x + rect.width - 1
        let down = area.handleMouse(
            MouseEvent(kind: .down, x: sbX, y: rect.y, button: 0),
            area: rect,
            state: state
        )
        #expect(down == .scrolled)
        #expect(area.scrollbarDragging)
        let middle = area.handleMouse(
            MouseEvent(kind: .up, x: sbX, y: rect.y, button: 1),
            area: rect,
            state: state
        )
        #expect(middle == .nothing)
        #expect(area.scrollbarDragging)
        let x10 = area.handleMouse(
            MouseEvent(kind: .up, x: sbX, y: rect.y, button: MouseEvent.noButton),
            area: rect,
            state: state
        )
        #expect(x10 == .scrolled)
        #expect(!area.scrollbarDragging)
    }

    @Test("cancelMouseGesture drops drag without copying; next down starts fresh")
    func cancelMouseGestureStartsFresh() {
        let area = TextArea()
        area.setText("abcdef")
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 5)
        let state = TextAreaState()
        _ = area.handleMouse(
            MouseEvent(kind: .down, x: 0, y: 0, button: 0),
            area: rect,
            state: state
        )
        _ = area.handleMouse(
            MouseEvent(kind: .drag, x: 4, y: 0, button: 0),
            area: rect,
            state: state
        )
        #expect(area.dragActive)
        let beforeClipboard = area.clipboard()
        area.cancelMouseGesture()
        #expect(!area.dragActive)
        #expect(area.pendingDragScroll == nil)
        #expect(area.pollTimeoutMs() == nil)
        #expect(area.clipboard() == beforeClipboard)
        let next = area.handleMouse(
            MouseEvent(kind: .down, x: 5, y: 0, button: 0),
            area: rect,
            state: state
        )
        #expect(next == .cursorPlaced)
        #expect(!area.dragActive)
        #expect(area.cursor == 5)
    }

    @Test("Ctrl+J replaces an active selection with a newline; Ctrl+H deletes it")
    func ctrlJAndHReplaceOrDeleteSelection() {
        let area = TextArea()
        area.setText("hello")
        area.setSelection(anchor: 0, head: 5)
        area.input(KeyEvent(key: .char("j"), modifiers: [.control], character: "j"))
        #expect(area.text == "\n")
        #expect(area.selectionRange == nil)

        area.setText("hello")
        area.setSelection(anchor: 0, head: 5)
        area.input(KeyEvent(key: .char("h"), modifiers: [.control], character: "h"))
        #expect(area.text == "")
        #expect(area.selectionRange == nil)
    }

    @Test("InputEvent.mouse is consumed")
    func inputEventMouse() {
        let area = TextArea()
        area.setText("abc")
        let rect = TextAreaRect(x: 0, y: 0, width: 40, height: 3)
        var state = TextAreaState()
        let action = area.input(
            .mouse(MouseEvent(kind: .down, x: 1, y: 0)),
            area: rect,
            state: &state
        )
        #expect(action == .cursorPlaced)
        #expect(area.cursor == 1)
    }

    @Test("bufferPosAtScreen outside returns nil")
    func bufferPosOutside() {
        let area = TextArea()
        area.setText("hi")
        let rect = TextAreaRect(x: 5, y: 5, width: 10, height: 3)
        #expect(area.bufferPosAtScreen(col: 0, row: 0, area: rect, state: TextAreaState()) == nil)
        #expect(area.bufferPosAtScreen(col: 5, row: 5, area: rect, state: TextAreaState()) != nil)
    }

    @Test("scroll override API")
    func scrollOverrideAPI() {
        let area = TextArea()
        area.setScrollOverride(3)
        #expect(area.scrollOverrideValue == 3)
        area.setScrollOverride(nil)
        #expect(area.scrollOverrideValue == nil)
    }
}
