// TerminalTryDrawTests.swift
//
// WAVE-T-TERMINAL-DRAW: pin `try_draw` (`terminal.rs:594-643` at 650c1db7).
// A throwing callback must not flip `current` onto the back buffer or leave a
// half-painted frame in place; a successful tryDraw swaps exactly once; cursor
// hide/show follows the frame's cursor_position the same way as Rust
// (`terminal.rs:618-625`).

import Foundation
import Testing
@testable import OpenGrokTerminalCore

private enum DrawProbeError: Error, Equatable {
    case boom
}

/// Backend that records hide/show pairing and every flushed glyph run.
private final class TryDrawBackend: TerminalBackend {
    let memoryWriter = MemoryTerminalWriter()
    var terminalSize: TerminalSize
    var cursor = TerminalPoint(x: 0, y: 0)
    var hiddenCursor = false
    var hideCount = 0
    var showCount = 0
    var flushCount = 0
    var drawCount = 0
    var drawnGraphemes: [String] = []

    init(size: TerminalSize) {
        self.terminalSize = size
    }

    var writer: TerminalWriter { memoryWriter }

    func draw(_ updates: [CellUpdate]) throws {
        drawCount += 1
        var run = ""
        for update in updates where !update.cell.skip {
            run += update.cell.grapheme
        }
        if !run.isEmpty {
            drawnGraphemes.append(run)
        }
        for update in updates where !update.cell.skip {
            try memoryWriter.write(string: update.cell.grapheme)
        }
    }

    func hideCursor() throws {
        hiddenCursor = true
        hideCount += 1
    }

    func showCursor() throws {
        hiddenCursor = false
        showCount += 1
    }

    func cursorPosition() throws -> TerminalPoint { cursor }

    func setCursorPosition(_ position: TerminalPoint) throws {
        cursor = position
    }

    func clear() throws {}
    func clearRegion(_ type: ClearType) throws { _ = type }
    func appendLines(_ n: Int) throws { _ = n }
    func size() throws -> TerminalSize { terminalSize }
    func flush() throws {
        flushCount += 1
        try memoryWriter.flush()
    }
}

private func fixedTerminal(
    width: Int = 20,
    height: Int = 3
) throws -> (Terminal, TryDrawBackend) {
    let backend = TryDrawBackend(size: TerminalSize(width: width, height: height))
    let terminal = try Terminal(
        backend: backend,
        options: TerminalOptions(
            viewport: .fixed(TerminalRect(x: 0, y: 0, width: width, height: height))
        )
    )
    return (terminal, backend)
}

private func rowText(_ buffer: CellBuffer, y: Int = 0) -> String {
    var text = ""
    for x in 0..<buffer.width {
        guard let cell = buffer.cell(x: x, y: y), !cell.skip else { continue }
        text += cell.grapheme
    }
    while text.hasSuffix(" ") { text.removeLast() }
    return text
}

private func isBlank(_ buffer: CellBuffer) -> Bool {
    buffer.content.allSatisfy { $0 == .blank || $0.skip }
}

@Suite("terminal tryDraw")
struct TerminalTryDrawTests {
    @Test("successful tryDraw swaps once and leaves the painted frame as previous")
    func successfulTryDrawSwapsOnce() throws {
        let (terminal, backend) = try fixedTerminal()

        let first = try terminal.tryDraw { frame in
            let written = frame.buffer.setString(x: 0, y: 0, text: "HELLO")
            #expect(written == 5)
        }
        #expect(first.count == 0)
        #expect(terminal.frameCount == 1)
        #expect(isBlank(terminal.currentBuffer()))
        #expect(backend.drawnGraphemes.contains { $0.contains("HELLO") })

        backend.memoryWriter.reset()
        let glyphsAfterFirst = backend.drawnGraphemes
        let second = try terminal.tryDraw { frame in
            let written = frame.buffer.setString(x: 0, y: 0, text: "HELLO")
            #expect(written == 5)
        }
        #expect(second.count == 1)
        #expect(terminal.frameCount == 2)
        #expect(isBlank(terminal.currentBuffer()))
        // Previous frame still holds HELLO, so the identical second paint diffs empty.
        #expect(backend.drawnGraphemes == glyphsAfterFirst)
        #expect(backend.memoryWriter.buffer.isEmpty)
    }

    @Test("tryDraw failure leaves the previous frame and does not swap")
    func tryDrawFailureLeavesPreviousFrame() throws {
        let (terminal, backend) = try fixedTerminal()

        let first = try terminal.tryDraw { frame in
            let written = frame.buffer.setString(x: 0, y: 0, text: "HELLO")
            #expect(written == 5)
        }
        #expect(first.count == 0)
        #expect(terminal.frameCount == 1)
        let drawsAfterFirst = backend.drawCount
        let flushesAfterFirst = backend.flushCount

        #expect(throws: DrawProbeError.boom) {
            try terminal.tryDraw { frame in
                let written = frame.buffer.setString(x: 0, y: 0, text: "WORLD")
                #expect(written == 5)
                throw DrawProbeError.boom
            }
        }

        #expect(terminal.frameCount == 1)
        #expect(isBlank(terminal.currentBuffer()))
        #expect(backend.drawCount == drawsAfterFirst)
        #expect(backend.flushCount == flushesAfterFirst)
        #expect(!backend.memoryWriter.utf8String.contains("WORLD"))

        backend.memoryWriter.reset()
        let glyphsBeforeReplay = backend.drawnGraphemes
        let replay = try terminal.tryDraw { frame in
            let written = frame.buffer.setString(x: 0, y: 0, text: "HELLO")
            #expect(written == 5)
        }
        #expect(replay.count == 1)
        #expect(terminal.frameCount == 2)
        #expect(backend.drawnGraphemes == glyphsBeforeReplay)
        #expect(backend.memoryWriter.buffer.isEmpty)
    }

    @Test("draw failed callback does not leave the back buffer as current")
    func drawFailureDoesNotSwap() throws {
        let (terminal, _) = try fixedTerminal()
        let first = try terminal.draw { frame in
            let written = frame.buffer.setString(x: 0, y: 0, text: "KEEP")
            #expect(written == 4)
        }
        #expect(first.count == 0)
        #expect(isBlank(terminal.currentBuffer()))

        #expect(throws: DrawProbeError.boom) {
            try terminal.draw { frame in
                let written = frame.buffer.setString(x: 0, y: 0, text: "DROP")
                #expect(written == 4)
                throw DrawProbeError.boom
            }
        }
        #expect(terminal.frameCount == 1)
        #expect(isBlank(terminal.currentBuffer()))
        #expect(rowText(terminal.currentBuffer()) != "DROP")
    }

    @Test("drawWithLinks failed callback does not leave the back buffer as current")
    func drawWithLinksFailureDoesNotSwap() throws {
        let (terminal, backend) = try fixedTerminal()
        let span = LinkSpan(row: 0, colStart: 0, colEnd: 4, url: "https://x.ai")
        let first = try terminal.drawWithLinks([span]) { frame in
            let written = frame.buffer.setString(x: 0, y: 0, text: "LINK")
            #expect(written == 4)
        }
        #expect(first.count == 0)
        #expect(isBlank(terminal.currentBuffer()))
        #expect(backend.memoryWriter.utf8String.contains("\u{1B}]8;;https://x.ai\u{07}"))

        #expect(throws: DrawProbeError.boom) {
            try terminal.drawWithLinks([span]) { frame in
                let written = frame.buffer.setString(x: 0, y: 0, text: "FAIL")
                #expect(written == 4)
                throw DrawProbeError.boom
            }
        }
        #expect(terminal.frameCount == 1)
        #expect(isBlank(terminal.currentBuffer()))
        #expect(!backend.memoryWriter.utf8String.contains("FAIL"))
    }

    @Test("hide and show cursor pair from the frame cursor position")
    func hideShowCursorPairing() throws {
        let (terminal, backend) = try fixedTerminal()

        let shown = try terminal.tryDraw { frame in
            frame.setCursorPosition(TerminalPoint(x: 2, y: 1))
            let written = frame.buffer.setString(x: 0, y: 0, text: "ON")
            #expect(written == 2)
        }
        #expect(shown.count == 0)
        #expect(backend.hiddenCursor == false)
        #expect(backend.showCount == 1)
        #expect(backend.hideCount == 0)
        #expect(backend.cursor == TerminalPoint(x: 2, y: 1))
        #expect(try terminal.getCursorPosition() == TerminalPoint(x: 2, y: 1))

        let hidden = try terminal.tryDraw { frame in
            let written = frame.buffer.setString(x: 0, y: 0, text: "OFF")
            #expect(written == 3)
        }
        #expect(hidden.count == 1)
        #expect(backend.hiddenCursor == true)
        #expect(backend.hideCount == 1)
        #expect(backend.showCount == 1)

        let hideBeforeFail = backend.hideCount
        let showBeforeFail = backend.showCount
        let cursorBeforeFail = backend.cursor
        #expect(throws: DrawProbeError.boom) {
            try terminal.tryDraw { frame in
                frame.setCursorPosition(TerminalPoint(x: 9, y: 2))
                let written = frame.buffer.setString(x: 0, y: 0, text: "NO")
                #expect(written == 2)
                throw DrawProbeError.boom
            }
        }
        #expect(backend.hiddenCursor == true)
        #expect(backend.hideCount == hideBeforeFail)
        #expect(backend.showCount == showBeforeFail)
        #expect(backend.cursor == cursorBeforeFail)
        #expect(try terminal.getCursorPosition() == cursorBeforeFail)
    }

    @Test("getCursor and setCursor wrap the Position APIs")
    func cursorU16PairShims() throws {
        let (terminal, backend) = try fixedTerminal()
        try terminal.setCursor(3, 2)
        #expect(backend.cursor == TerminalPoint(x: 3, y: 2))
        #expect(try terminal.getCursorPosition() == TerminalPoint(x: 3, y: 2))
        let pair = try terminal.getCursor()
        #expect(pair.0 == 3)
        #expect(pair.1 == 2)
    }
}
