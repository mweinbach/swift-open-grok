// MinimalCommitInsertTests.swift
//
// Wave 18 B2-M2, the live seam: `insertCommitted` drives the REAL
// `Terminal.insertBefore` (B2-N) — the committed text must actually reach
// the terminal, the cap must bound the insert height, and a failed write
// must THROW so the frontier walk can leave the entry uncommitted
// (`insert_committed`, `commit.rs:319-343`: "Propagated (not swallowed):
// the caller must NOT mark the entry committed when the terminal write
// failed — print-once means a marked-but-unprinted block can never be
// emitted again").

import Foundation
import Testing
import OpenGrokMinimalScrollback
import OpenGrokTerminalCore
@testable import OpenGrokPagerRender

/// Backend whose draws fail on demand — the failed-terminal-write case.
private final class FailingDrawBackend: TerminalBackend {
    let memoryWriter = MemoryTerminalWriter()
    var terminalSize: TerminalSize
    var cursor = TerminalPoint(x: 0, y: 0)
    var failDraws = false

    init(size: TerminalSize) {
        self.terminalSize = size
    }

    var writer: TerminalWriter { memoryWriter }

    func draw(_ updates: [CellUpdate]) throws {
        if failDraws {
            throw CocoaError(.fileWriteUnknown)
        }
        for u in updates where !u.cell.skip {
            try memoryWriter.write(string: u.cell.grapheme)
        }
    }

    func hideCursor() throws {}
    func showCursor() throws {}
    func cursorPosition() throws -> TerminalPoint { cursor }
    func setCursorPosition(_ position: TerminalPoint) throws { cursor = position }
    func clear() throws {}
    func clearRegion(_ type: ClearType) throws {}
    func appendLines(_ n: Int) throws {}
    func size() throws -> TerminalSize { terminalSize }
    func flush() throws {}
}

private func inlineTerminal(
    backend: TerminalBackend,
    viewportHeight: Int = 3
) throws -> Terminal {
    try Terminal(
        backend: backend,
        options: TerminalOptions(viewport: .inline(height: viewportHeight))
    )
}

@Suite("Minimal committed insert — live seam")
struct MinimalCommitInsertTests {
    @Test("a committed block's text reaches the terminal through insertBefore")
    func committedBlockTextReachesTheTerminal() throws {
        let backend = RecordingBackend(size: TerminalSize(width: 60, height: 12))
        let terminal = try inlineTerminal(backend: backend)
        let block = MinimalCommitRender.committedLines(
            item: .message(PagerMessage(role: .assistant, text: "committed answer")),
            displayMode: .expanded,
            width: 60,
            theme: PagerRenderTheme.default
        )
        try MinimalCommitRender.insertCommitted(
            block,
            into: terminal,
            maxRows: 0,
            theme: PagerRenderTheme.default
        )
        let written = backend.memoryWriter.utf8String
        #expect(written.contains("committed answer"), "drawn bytes: \(written)")
    }

    @Test("the cap bounds the inserted height and the footer is what lands")
    func capBoundsTheInsertedHeightAndTheFooterLands() throws {
        let backend = RecordingBackend(size: TerminalSize(width: 60, height: 12))
        let terminal = try inlineTerminal(backend: backend)
        let tall = (0..<40).map { "row \($0)" }.joined(separator: "\n")
        let block = MinimalCommitRender.committedLines(
            item: .message(PagerMessage(role: .assistant, text: tall)),
            displayMode: .expanded,
            width: 60,
            theme: PagerRenderTheme.default
        )
        #expect(block.height == 40)
        try MinimalCommitRender.insertCommitted(
            block,
            into: terminal,
            maxRows: 6,
            theme: PagerRenderTheme.default
        )
        let written = backend.memoryWriter.utf8String
        #expect(written.contains("row 0"))
        #expect(written.contains("more lines"), "the footer is the last committed row")
        #expect(
            !written.contains("row 20"),
            "content past the cap must not reach the terminal: the cap bounds the burst"
        )
    }

    @Test("a failed terminal write propagates out of insertCommitted")
    func failedTerminalWritePropagates() throws {
        let backend = FailingDrawBackend(size: TerminalSize(width: 60, height: 12))
        let terminal = try inlineTerminal(backend: backend)
        let block = MinimalCommitRender.committedLines(
            item: .message(PagerMessage(role: .assistant, text: "never printed")),
            displayMode: .expanded,
            width: 60,
            theme: PagerRenderTheme.default
        )
        backend.failDraws = true
        #expect(throws: (any Error).self) {
            try MinimalCommitRender.insertCommitted(
                block,
                into: terminal,
                maxRows: 0,
                theme: PagerRenderTheme.default
            )
        }
    }
}
