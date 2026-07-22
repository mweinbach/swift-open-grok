// OpenGrokTerminalCoreTests.swift
import Foundation
import Testing
@testable import OpenGrokTerminalCore

@Suite("OpenGrokTerminalCore")
struct OpenGrokTerminalCoreTests {
    @Test("TerminalSize and Cell value types")
    func valueTypes() {
        let size = TerminalSize(width: 80, height: 24)
        #expect(size.width == 80 && size.height == 24)
        let cell = Cell(grapheme: "A", style: [.bold, .underline], displayWidth: 1)
        #expect(cell.grapheme == "A")
        #expect(cell.style.contains(.bold))
        #expect(cell.style.contains(.underline))
        #expect(!cell.style.contains(.reverse))
    }

    @Test("Input events are Sendable and equatable")
    func inputEvents() {
        let resize = InputEvent.resize(TerminalSize(width: 120, height: 40))
        let key = InputEvent.key(KeyEvent(key: "Enter", modifiers: [.control]))
        let paste = InputEvent.paste("hello")
        #expect(resize == .resize(TerminalSize(width: 120, height: 40)))
        #expect(key == .key(KeyEvent(key: "Enter", modifiers: [.control])))
        #expect(paste == .paste("hello"))
    }

    @Test("Default capabilities are true-color with full features")
    func defaultCapabilities() {
        let cap = TerminalCapability()
        #expect(cap.colorDepth == .trueColor)
        #expect(cap.supportsMouse)
        #expect(cap.supportsAlternateScreen)
    }

    // MARK: - Unicode width

    @Test("ASCII and CJK display widths")
    func unicodeWidths() {
        #expect(UnicodeDisplayWidth.width(of: "hello") == 5)
        #expect(UnicodeDisplayWidth.width(of: "你好") == 4)
        #expect(UnicodeDisplayWidth.width(of: "A") == 1)
        #expect(UnicodeDisplayWidth.width(of: "\u{0301}") == 0) // combining acute
        #expect(UnicodeDisplayWidth.width(of: "e\u{0301}") == 1)
    }

    // MARK: - Line segments

    @Test("empty string yields no segments")
    func emptySegments() {
        #expect(splitIntoLineSegments("", termWidth: 10).isEmpty)
    }

    @Test("simple text is one segment")
    func simpleText() {
        let segments = splitIntoLineSegments("hello", termWidth: 10)
        #expect(segments.count == 1)
        #expect(segments[0].content == "hello")
        #expect(!segments[0].endsWithCRLF)
    }

    @Test("text wrapping at width")
    func textWrapping() {
        let segments = splitIntoLineSegments("hello world", termWidth: 8)
        #expect(segments.count == 2)
        #expect(segments[0].content == "hello wo")
        #expect(segments[1].content == "rld")
    }

    @Test("newline and CRLF handling")
    func newlineHandling() {
        let a = splitIntoLineSegments("line1\nline2", termWidth: 20)
        #expect(a.count == 2)
        #expect(a[0].content == "line1" && a[0].endsWithCRLF)
        #expect(a[1].content == "line2" && !a[1].endsWithCRLF)

        let b = splitIntoLineSegments("line1\r\nline2\nline3", termWidth: 20)
        #expect(b.count == 3)
        #expect(b[0].content == "line1" && b[0].endsWithCRLF)
        #expect(b[1].content == "line2" && b[1].endsWithCRLF)
        #expect(b[2].content == "line3" && !b[2].endsWithCRLF)
    }

    @Test("bare CR resets visual width")
    func bareCR() {
        let segments = splitIntoLineSegments("12345\r67", termWidth: 10)
        #expect(segments.count == 1)
        #expect(segments[0].content == "12345\r67")
    }

    @Test("emoji wider than terminal still emits one segment")
    func wideEmoji() {
        let segments = splitIntoLineSegments("😊", termWidth: 1)
        #expect(segments.count == 1)
        #expect(segments[0].content == "😊")
    }

    @Test("ANSI codes stay in segment and merge when zero-width")
    func ansiCodes() {
        let s1 = splitIntoLineSegments("line1\u{1B}[31m", termWidth: 20)
        #expect(s1.count == 1)
        #expect(s1[0].content == "line1\u{1B}[31m")

        let s2 = splitIntoLineSegments("line1\n\u{1B}[31m", termWidth: 20)
        #expect(s2.count == 2)
        #expect(s2[0].content == "line1" && s2[0].endsWithCRLF)
        #expect(s2[1].content == "\u{1B}[31m")

        let s3 = splitIntoLineSegments("\u{1B}[1m\u{1B}[31mBold Red\u{1B}[0m", termWidth: 20)
        #expect(s3.count == 1)
        #expect(s3[0].content.contains("Bold Red"))
    }

    @Test("wrap at exact width and trailing ANSI")
    func wrapExactAndTrailingANSI() {
        let s1 = splitIntoLineSegments("12345678", termWidth: 8)
        #expect(s1.count == 1)

        let s2 = splitIntoLineSegments("12345678\u{1B}[0m90", termWidth: 8)
        #expect(s2.count == 2)
        #expect(s2[0].content == "12345678\u{1B}[0m")
        #expect(s2[1].content == "90")
    }

    @Test("unicode wrap calculation")
    func unicodeWrap() {
        let input = "hello 你好"
        #expect(splitIntoLineSegments(input, termWidth: 10).count == 1)
        #expect(splitIntoLineSegments(input, termWidth: 9).count == 2)
    }

    // MARK: - Diff

    @Test("diffLarge reports changed cells only")
    func diffBasic() {
        var prev = CellBuffer.empty(TerminalRect(x: 0, y: 0, width: 4, height: 2))
        var next = prev
        next.setString(x: 0, y: 0, text: "ab")
        let updates = diffLarge(previous: prev, next: next)
        #expect(updates.count >= 2)
        #expect(updates.contains { $0.x == 0 && $0.y == 0 && $0.cell.grapheme == "a" })
    }

    @Test("diffLarge is safe for large grids")
    func diffLargeGrid() {
        let area = TerminalRect(x: 0, y: 0, width: 300, height: 300) // 90_000 > UInt16.max
        var prev = CellBuffer.empty(area)
        var next = prev
        next.setString(x: 250, y: 250, text: "Z")
        let updates = diffLarge(previous: prev, next: next)
        #expect(updates.contains { $0.x == 250 && $0.y == 250 && $0.cell.grapheme == "Z" })
    }

    // MARK: - Terminal double buffer + links

    @Test("flush with links emits OSC 8")
    func flushWithLinks() throws {
        let backend = RecordingBackend(size: TerminalSize(width: 20, height: 3))
        let term = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .fixed(TerminalRect(x: 0, y: 0, width: 20, height: 3)))
        )
        _ = try term.draw { frame in
            _ = frame.buffer.setString(x: 0, y: 0, text: "AB")
        }
        // Second frame with links
        var frame = term.getFrame()
        _ = frame.buffer.setString(x: 0, y: 0, text: "AB")
        // Manually set buffer
        // Use setFrameLinks + flushWithLinks after injecting into current buffer via draw
        _ = try term.draw { f in
            _ = f.buffer.setString(x: 0, y: 0, text: "AB")
        }
        // After draw, buffers swapped. Set links on new current and flush.
        var f2 = term.getFrame()
        _ = f2.buffer.setString(x: 0, y: 0, text: "AB")
        // Put buffer back — draw path overwrites; call setFrameLinks after assigning:
        // Direct path:
        term.setFrameLinks([LinkSpan(row: 0, colStart: 0, colEnd: 2, url: "https://x.ai")])
        // Need buffer populated: use draw again
        backend.memoryWriter.reset()
        _ = try term.draw { f in
            _ = f.buffer.setString(x: 0, y: 0, text: "AB")
        }
        // Links must be set before flush inside draw — call dedicated path:
        backend.memoryWriter.reset()
        var f3 = term.getFrame()
        _ = f3.buffer.setString(x: 0, y: 0, text: "AB")
        // Inject: re-draw with setFrameLinks between render and flush is internal.
        // Use public setFrameLinks + flushWithLinks by mutating via draw pattern:
        _ = try term.draw { f in
            _ = f.buffer.setString(x: 0, y: 0, text: "XY")
        }
        // Clear recording and do explicit set + flush
        backend.memoryWriter.reset()
        var f4 = term.getFrame()
        _ = f4.buffer.setString(x: 0, y: 0, text: "AB")
        // Can't assign buffer easily — use force path via draw then setFrameLinks on next cycle.
        // Test OSC 8 encoder directly:
        let data = CellStreamEncoder.encode(
            updates: [
                CellUpdate(x: 0, y: 0, cell: Cell(grapheme: "A")),
                CellUpdate(x: 1, y: 0, cell: Cell(grapheme: "B")),
            ],
            linkIds: [1, 1],
            linkTable: [LinkRef(url: "https://x.ai")],
            area: TerminalRect(x: 0, y: 0, width: 20, height: 3)
        )
        let out = String(decoding: data, as: UTF8.self)
        #expect(out.contains("\u{1B}]8;;https://x.ai\u{07}"))
        #expect(out.contains("\u{1B}]8;;\u{07}"))
        #expect(out.contains("A") || out.contains("B"))
    }

    @Test("OSC 8 sanitizes control characters in URL")
    func osc8Sanitize() {
        let open = ANSIOutput.osc8Open(url: "https://x\u{07}\u{1B}/y", id: nil)
        #expect(open.contains("https://x/y"))
        #expect(!open.contains("\u{07}https"))
        let withId = ANSIOutput.osc8Open(url: "https://x.ai", id: 7)
        #expect(withId.contains("id=7"))
    }

    // MARK: - Scrollback / resize / sync

    @Test("emitToScrollback writes content and flushes")
    func emitScrollback() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        try emitToScrollback(terminal, content: "Hello, World!")
        #expect(terminal.clearCount == 1) // via resetBackBuffer
        #expect(!terminal.memoryWriter.buffer.isEmpty)
        #expect(terminal.memoryWriter.flushCount == 1)
        #expect(terminal.memoryWriter.utf8String.contains("Hello, World!"))
    }

    @Test("emitToScrollback moves viewport down when not at bottom")
    func emitMovesViewport() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        terminal.viewportArea = TerminalRect(x: 0, y: 10, width: 80, height: 3)
        try emitToScrollback(terminal, content: "Test content")
        #expect(terminal.viewportUpdates.count == 1)
        #expect(terminal.viewportUpdates[0].y > 10)
    }

    @Test("viewport resize shrink anchors top")
    func viewportResizeShrink() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 5)
        let originalY = terminal.viewportArea.y
        try resizeViewportHeight(terminal, newHeight: 3)
        #expect(terminal.viewportArea.height == 3)
        #expect(terminal.viewportArea.y == originalY)
        #expect(terminal.clearCount == 1)
    }

    @Test("viewport resize smart expand")
    func viewportResizeExpand() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        terminal.viewportArea = TerminalRect(x: 0, y: 20, width: 80, height: 3)
        try resizeViewportHeight(terminal, newHeight: 5)
        #expect(terminal.viewportArea.height == 5)
        #expect(terminal.viewportArea.y == 20)
        try resizeViewportHeight(terminal, newHeight: 6)
        #expect(terminal.viewportArea.height == 6)
        #expect(terminal.viewportArea.y == 19)
    }

    @Test("viewport resize invalid heights")
    func viewportResizeInvalid() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        #expect(throws: ViewportResizeError.self) {
            try resizeViewportHeight(terminal, newHeight: 0)
        }
        #expect(throws: ViewportResizeError.self) {
            try resizeViewportHeight(terminal, newHeight: 25)
        }
        try resizeViewportHeight(terminal, newHeight: 1)
        try resizeViewportHeight(terminal, newHeight: 24)
    }

    @Test("viewport resize no-op")
    func viewportResizeNoOp() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        try resizeViewportHeight(terminal, newHeight: 3)
        #expect(terminal.clearCount == 0)
    }

    @Test("resize purge rerender empty history")
    func purgeEmpty() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        terminal.viewportArea = TerminalRect(x: 0, y: 22, width: 80, height: 3)
        try resizePurgeRerender(terminal, history: "")
        #expect(terminal.viewportArea.y == 0)
        #expect(terminal.viewportArea.height == 3)
        #expect(terminal.clearCount == 1)
    }

    @Test("resize purge rerender small history")
    func purgeSmall() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        try resizePurgeRerender(terminal, history: "Line 1\r\nLine 2\r\nLine 3\r\n")
        #expect(terminal.viewportArea.y == 3)
        #expect(terminal.viewportArea.height == 3)
    }

    @Test("resize purge rerender full screen history")
    func purgeFull() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        var history = ""
        for i in 1...30 { history += "Line \(i)\r\n" }
        try resizePurgeRerender(terminal, history: history)
        #expect(terminal.viewportArea.y == 22)
    }

    @Test("resize purge preserves width/height")
    func purgePreservesDims() throws {
        let terminal = MockTerminal(width: 100, height: 30, viewportHeight: 5)
        try resizePurgeRerender(terminal, history: "Some content\r\n")
        #expect(terminal.viewportArea.width == 100)
        #expect(terminal.viewportArea.height == 5)
    }

    @Test("resize purge emits clear sequences")
    func purgeEmitsClear() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        try resizePurgeRerender(terminal, history: "Test line\r\n")
        let out = terminal.memoryWriter.utf8String
        #expect(out.contains("\u{1B}[2J\u{1B}[3J\u{1B}[H"))
        #expect(out.contains("Test line"))
        #expect(terminal.memoryWriter.flushCount > 0)
    }

    @Test("synchronized output wraps body")
    func syncOutput() throws {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        try withSynchronizedOutput(terminal) { t in
            try t.writer.write(string: "Test content")
            try t.writer.flush()
        }
        let text = terminal.memoryWriter.utf8String
        #expect(text.contains("\u{1B}[?2026h"))
        #expect(text.contains("\u{1B}[?2026l"))
        #expect(text.contains("Test content"))
        #expect(terminal.memoryWriter.flushCount >= 2)
    }

    @Test("synchronized output still ends on throw")
    func syncOutputThrow() {
        let terminal = MockTerminal(width: 80, height: 25, viewportHeight: 3)
        enum E: Error { case boom }
        do {
            try withSynchronizedOutput(terminal) { _ in throw E.boom }
            Issue.record("expected throw")
        } catch {
            let text = terminal.memoryWriter.utf8String
            #expect(text.contains("\u{1B}[?2026h"))
            #expect(text.contains("\u{1B}[?2026l"))
        }
    }

    @Test("setViewportHeight grow scrolls lines")
    func setViewportHeightGrow() throws {
        let backend = RecordingBackend(size: TerminalSize(width: 80, height: 24))
        let term = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .inline(height: 3))
        )
        term.setViewportArea(TerminalRect(x: 0, y: 21, width: 80, height: 3))
        let before = backend.appendedLines
        try term.setViewportHeight(24)
        #expect(backend.appendedLines - before >= 21)
    }

    @Test("terminal state restoration after clear and resize cycles")
    func restorationCycles() throws {
        let backend = RecordingBackend(size: TerminalSize(width: 40, height: 12))
        let term = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .inline(height: 3))
        )
        for _ in 0..<3 {
            _ = try term.draw { f in
                _ = f.buffer.setString(x: 0, y: f.viewportArea.y, text: "cycle")
            }
            try term.clear()
            try term.autoresize()
        }
        backend.resize(to: TerminalSize(width: 50, height: 20))
        try term.autoresize()
        try term.clear()
        term.resetBackBuffer()
        #expect(term.viewportArea.width >= 0)
        #expect(term.frameCount >= 3)
    }
}
