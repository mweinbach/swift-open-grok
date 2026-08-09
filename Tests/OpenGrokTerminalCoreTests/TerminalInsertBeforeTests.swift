// TerminalInsertBeforeTests.swift
//
// B2-N: the native-scrollback injection primitive. `insertBefore` is the port
// of xai-ratatui-inline's `insert_before_no_scrolling_regions`
// (`terminal.rs:812-993` at pin 650c1db7) — the one capability the B2
// research found entirely absent ("the port has zero terminal-scrollback-
// injection capability"). These tests pin the scroll math, the push-down /
// scroll-up regimes, the DEFERRED clear (the tmux garbage artifact,
// `terminal.rs:986-989`), error propagation (the print-once commit pipeline
// marks an entry committed only after a successful insert), and the two
// viewport-height regressions from upstream's test suite
// (`tests.rs:226-300`).

import Foundation
import Testing
@testable import OpenGrokTerminalCore

/// Backend that logs every operation IN ORDER, so ordering pins (clear after
/// draw; scroll before draw) are assertable, and renders drawn rows as text.
private final class OpLogBackend: TerminalBackend {
    enum Op: Equatable {
        case draw(rows: [Int: String])
        case appendLines(Int)
        case clearRegion
        case setCursor(x: Int, y: Int)
    }

    let memoryWriter = MemoryTerminalWriter()
    var ops: [Op] = []
    var terminalSize: TerminalSize
    var cursor = TerminalPoint(x: 0, y: 0)
    /// When set, `draw` throws — the failed-terminal-write case.
    var failDraws = false

    init(size: TerminalSize) {
        self.terminalSize = size
    }

    var writer: TerminalWriter { memoryWriter }

    func draw(_ updates: [CellUpdate]) throws {
        if failDraws {
            throw CocoaError(.fileWriteUnknown)
        }
        var rows: [Int: String] = [:]
        for u in updates.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) where !u.cell.skip {
            rows[u.y, default: ""] += u.cell.grapheme
        }
        ops.append(.draw(rows: rows.mapValues {
            var s = $0
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }))
    }

    func hideCursor() throws {}
    func showCursor() throws {}
    func cursorPosition() throws -> TerminalPoint { cursor }
    func setCursorPosition(_ position: TerminalPoint) throws {
        cursor = position
        ops.append(.setCursor(x: position.x, y: position.y))
    }
    func clear() throws {}
    func clearRegion(_ type: ClearType) throws {
        _ = type
        ops.append(.clearRegion)
    }
    func appendLines(_ n: Int) throws {
        ops.append(.appendLines(n))
    }
    func size() throws -> TerminalSize { terminalSize }
    func flush() throws {}

    var totalScrolled: Int {
        ops.reduce(0) { total, op in
            if case .appendLines(let n) = op { return total + n }
            return total
        }
    }

    /// Every drawn row as `y: text`, merged across draw calls (later wins).
    var drawnRows: [Int: String] {
        var merged: [Int: String] = [:]
        for op in ops {
            if case .draw(let rows) = op {
                merged.merge(rows) { _, new in new }
            }
        }
        return merged
    }
}

private func inlineTerminal(
    width: Int = 40,
    height: Int = 12,
    viewportHeight: Int = 3,
    viewportY: Int? = nil
) throws -> (Terminal, OpLogBackend) {
    let backend = OpLogBackend(size: TerminalSize(width: width, height: height))
    let terminal = try Terminal(
        backend: backend,
        options: TerminalOptions(viewport: .inline(height: viewportHeight))
    )
    if let viewportY {
        terminal.setViewportArea(TerminalRect(
            x: 0, y: viewportY, width: width, height: viewportHeight
        ))
    }
    backend.ops.removeAll()
    return (terminal, backend)
}

private func fill(_ lines: [String]) -> (inout CellBuffer) -> Void {
    { buffer in
        for (i, line) in lines.enumerated() {
            _ = buffer.setString(x: 0, y: i, text: line)
        }
    }
}

@Suite("terminal insertBefore")
struct TerminalInsertBeforeTests {
    @Test("a viewport above the bottom is pushed down without scrolling")
    func pushesViewportDown() throws {
        // 12-row screen, 3-row viewport at y=2: two inserted rows land at
        // rows 2-3 and push the viewport to y=4 — nothing scrolls
        // (`terminal.rs:742-745`: "inserted lines will push it towards the
        // bottom").
        let (terminal, backend) = try inlineTerminal(viewportY: 2)
        try terminal.insertBefore(2, draw: fill(["first", "second"]))

        #expect(backend.totalScrolled == 0)
        #expect(backend.drawnRows[2] == "first")
        #expect(backend.drawnRows[3] == "second")
        #expect(terminal.viewportArea.y == 4)
        #expect(terminal.viewportArea.height == 3)
    }

    @Test("a viewport at the bottom scrolls exactly the inserted height into scrollback")
    func scrollsAtTheBottom() throws {
        // Viewport pinned at the bottom (y=9 of 12): inserting 2 rows must
        // scroll the screen up by exactly 2 — those two rows are what lands
        // in the terminal's native scrollback.
        let (terminal, backend) = try inlineTerminal(viewportY: 9)
        try terminal.insertBefore(2, draw: fill(["one", "two"]))

        #expect(backend.totalScrolled == 2)
        // Drawn where the viewport top WAS, minus the scroll: rows 7-8.
        #expect(backend.drawnRows[7] == "one")
        #expect(backend.drawnRows[8] == "two")
        // The viewport stays bottom-anchored.
        #expect(terminal.viewportArea.y == 9)
    }

    @Test("content taller than the screen is drawn in chunks and all rows scroll through")
    func tallInsertChunks() throws {
        // 20 rows through a 12-row screen with a 3-row viewport at the
        // bottom: every inserted row must eventually scroll up so the
        // viewport ends bottom-anchored — total scroll equals the full
        // inserted height (rows above the final screen all reached native
        // scrollback).
        let lines = (1...20).map { "row-\($0)" }
        let (terminal, backend) = try inlineTerminal(viewportY: 9)
        try terminal.insertBefore(20, draw: fill(lines))

        #expect(backend.totalScrolled == 20)
        #expect(terminal.viewportArea.y == 9)
        // Every row was drawn exactly once across the chunked walk: the
        // consumed-row cursor never re-reads or skips a buffer row.
        let drawnTexts = backend.ops.flatMap { op -> [String] in
            if case .draw(let rows) = op { return Array(rows.values) }
            return []
        }
        for line in lines {
            #expect(drawnTexts.filter { $0 == line }.count == 1, "row \(line) drawn once")
        }
    }

    @Test("the viewport clear is deferred until AFTER the content is drawn — the tmux pin")
    func clearIsDeferred() throws {
        // Upstream's in-source reason (`terminal.rs:986-989`): "there is a
        // weird bug with tmux where a full screen clear plus immediate
        // scrolling causes some garbage to go into the scrollback" — so the
        // clear must come after every draw and every scroll, never between
        // a clear and a following scroll. Do not reorder.
        let (terminal, backend) = try inlineTerminal(viewportY: 9)
        try terminal.insertBefore(2, draw: fill(["a", "b"]))

        let clearIndex = try #require(backend.ops.firstIndex(of: .clearRegion))
        for (i, op) in backend.ops.enumerated() {
            switch op {
            case .draw, .appendLines:
                #expect(i < clearIndex, "op \(i) (\(op)) must precede the deferred clear")
            case .clearRegion, .setCursor:
                break
            }
        }
    }

    @Test("a failed terminal write propagates — print-once must not mark unprinted blocks")
    func drawFailurePropagates() throws {
        // The commit pipeline marks an entry committed ONLY when the insert
        // succeeded (`commit.rs:225-248`: "a `false` return stops the walk
        // with the entry still uncommitted"); a swallowed error here would
        // make blocks silently vanish from a print-once transcript.
        let (terminal, backend) = try inlineTerminal(viewportY: 9)
        backend.failDraws = true
        #expect(throws: (any Error).self) {
            try terminal.insertBefore(1, draw: fill(["lost"]))
        }
    }

    @Test("non-inline viewports are a no-op")
    func nonInlineNoOp() throws {
        let backend = OpLogBackend(size: TerminalSize(width: 40, height: 12))
        let terminal = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .fullscreen)
        )
        backend.ops.removeAll()
        try terminal.insertBefore(2, draw: fill(["x", "y"]))
        #expect(backend.ops.isEmpty)
    }

    @Test("a full-height viewport sends the whole insert through scrollback")
    func fullHeightViewport() throws {
        // Viewport == screen: there is no on-screen row to give the content,
        // so all of it scrolls straight into native scrollback
        // (`terminal.rs:785-787`: "At the limit ... all lines will be
        // inserted directly into the scrollback buffer").
        let (terminal, backend) = try inlineTerminal(
            height: 6, viewportHeight: 6, viewportY: 0
        )
        try terminal.insertBefore(4, draw: fill(["s1", "s2", "s3", "s4"]))

        #expect(backend.totalScrolled == 4)
        #expect(terminal.viewportArea.y == 0)
        #expect(terminal.viewportArea.height == 6)
    }
}

@Suite("viewport height regressions")
struct TerminalViewportHeightRegressionTests {
    @Test("grow after an out-of-band area shrink still scrolls — the stored-height drift bug")
    func growAfterOutOfBandShrink() throws {
        // Upstream regression (`tests.rs:251-300` + the in-source comment at
        // `terminal.rs:851-861`): minimal mode shrinks the viewport
        // out-of-band via set_viewport_area, leaving the STORED Inline
        // height stale. Grow-vs-shrink must be judged against the ACTUAL
        // area height, or a genuine grow reads as a shrink, skips the
        // grow-time scroll, and the taller viewport runs off the bottom of
        // the screen (the "empty dropdown over a full screen" bug).
        let backend = OpLogBackend(size: TerminalSize(width: 80, height: 24))
        let terminal = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .inline(height: 21))
        )
        // Out-of-band shrink to 3 rows pinned at the bottom; stored height
        // stays 21 — the drift.
        terminal.setViewportArea(TerminalRect(x: 0, y: 21, width: 80, height: 3))
        backend.ops.removeAll()

        // Grow to 10: against the REAL height (3) this overflows the bottom
        // by (21 + 10) - 24 = 7 rows, which must scroll up.
        try terminal.setViewportHeight(10)

        #expect(backend.totalScrolled >= 7)
        #expect(terminal.viewportArea.height == 10)
        #expect(
            terminal.viewportArea.y + terminal.viewportArea.height <= 24,
            "the grown viewport must fit on screen"
        )
    }

    @Test("a full-height inline viewport tracks the terminal through resizes")
    func fullHeightInlineTracksResizes() throws {
        // Upstream's inline_resize_tests (`terminal.rs:1350-1406`): the
        // full-height inline viewport is the alt-screen-unavailable stance
        // (tmux control mode, --no-alt-screen); it must keep spanning the
        // terminal in BOTH directions, repeatedly, and never end up
        // truncated or off-screen.
        let backend = OpLogBackend(size: TerminalSize(width: 80, height: 24))
        let terminal = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .inline(height: 24))
        )
        #expect(terminal.viewportArea == TerminalRect(x: 0, y: 0, width: 80, height: 24))

        backend.terminalSize = TerminalSize(width: 80, height: 40)
        try terminal.autoresize()
        #expect(terminal.viewportArea == TerminalRect(x: 0, y: 0, width: 80, height: 40))

        backend.terminalSize = TerminalSize(width: 80, height: 20)
        try terminal.autoresize()
        #expect(terminal.viewportArea == TerminalRect(x: 0, y: 0, width: 80, height: 20))

        backend.terminalSize = TerminalSize(width: 100, height: 50)
        try terminal.autoresize()
        #expect(terminal.viewportArea == TerminalRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test("a small inline viewport is not forced to full height by a resize")
    func smallInlineNotForcedFull() throws {
        // The full-height special case keys off the viewport spanning the
        // whole terminal (`terminal.rs:1408-1434`); a small inline viewport
        // keeps its height while the width tracks the resize.
        let backend = OpLogBackend(size: TerminalSize(width: 80, height: 24))
        let terminal = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .inline(height: 3))
        )
        #expect(terminal.viewportArea.height == 3)

        backend.terminalSize = TerminalSize(width: 120, height: 40)
        try terminal.autoresize()

        #expect(terminal.viewportArea.height == 3)
        #expect(terminal.viewportArea.width == 120)
    }
}
