// PagerExtensionsByteStreamTests.swift
//
// The extensions modal at the BYTE-STREAM seam: what `PagerTerminalRenderer`
// actually emits, not the logical `snapshot()`. The shape this pins was
// misread as a paint bug once already: when the previous frame happens to
// hold a cell identical to one the modal is about to paint — the welcome
// hero's path subtitle leaving an `o` exactly where a hook description's
// `o` lands — the frame diff correctly never re-emits that cell, so the raw
// glyph stream shows `→ ech audited` while the terminal's screen is intact.
// The assertions here state both halves: the diff omission is deliberate
// (ratatui `Buffer::diff` parity), and a screen replay of the full stream
// still shows every character. If a future change makes the replay lose a
// cell, that IS a real dropped character — this test is where it surfaces.

import Foundation
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

// MARK: - Capture

private final class ByteStreamSink: PagerTerminalSink, @unchecked Sendable {
    var bytes: [UInt8] = []
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes newBytes: [UInt8]) throws { bytes.append(contentsOf: newBytes) }
    func flush() throws {}
}

/// Emitted glyphs in emission order, escapes stripped — the raw stream view
/// that CANNOT see diff-skipped cells.
private func emittedGlyphs(_ bytes: [UInt8]) -> String {
    var plain: [UInt8] = []
    var index = 0
    while index < bytes.count {
        guard bytes[index] == 0x1B else {
            plain.append(bytes[index])
            index += 1
            continue
        }
        index += 1
        guard index < bytes.count else { break }
        switch bytes[index] {
        case UInt8(ascii: "["):
            index += 1
            while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) { index += 1 }
            index += 1
        case UInt8(ascii: "]"):
            index += 1
            while index < bytes.count {
                if bytes[index] == 0x07 { index += 1; break }
                if bytes[index] == 0x1B, index + 1 < bytes.count,
                   bytes[index + 1] == UInt8(ascii: "\\") { index += 2; break }
                index += 1
            }
        default:
            index += 1
        }
    }
    return String(decoding: plain, as: UTF8.self)
}

/// Replay the stream through a cursor-addressed screen — the terminal's view,
/// which DOES retain cells the diff skipped.
private func replayedScreenRows(_ bytes: [UInt8], width: Int, height: Int) -> [String] {
    var rows = Array(repeating: Array(repeating: " ", count: width), count: height)
    var cursorX = 0
    var cursorY = 0
    let text = String(decoding: bytes, as: UTF8.self)
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        guard character == "\u{1B}" else {
            if cursorY >= 0, cursorY < height, cursorX >= 0, cursorX < width {
                rows[cursorY][cursorX] = String(character)
            }
            cursorX += max(1, UnicodeDisplayWidth.width(of: String(character)))
            index = text.index(after: index)
            continue
        }
        let introducer = text.index(after: index)
        guard introducer < text.endIndex else { break }
        switch text[introducer] {
        case "[":
            var scan = text.index(after: introducer)
            var parameters = ""
            while scan < text.endIndex, !("\u{40}"..."\u{7E}" ~= text[scan]) {
                parameters.append(text[scan])
                scan = text.index(after: scan)
            }
            guard scan < text.endIndex else { return rows.map { $0.joined() } }
            switch text[scan] {
            case "H":
                let parts = parameters.split(separator: ";").compactMap { Int($0) }
                cursorY = (parts.first ?? 1) - 1
                cursorX = (parts.count > 1 ? parts[1] : 1) - 1
            case "J" where parameters.isEmpty || parameters == "2":
                rows = Array(repeating: Array(repeating: " ", count: width), count: height)
            case "K":
                if cursorY >= 0, cursorY < height {
                    for column in max(0, cursorX)..<width { rows[cursorY][column] = " " }
                }
            default:
                break
            }
            index = text.index(after: scan)
        case "]":
            var scan = text.index(after: introducer)
            while scan < text.endIndex, text[scan] != "\u{07}" { scan = text.index(after: scan) }
            index = scan < text.endIndex ? text.index(after: scan) : scan
        default:
            index = text.index(after: introducer)
        }
    }
    return rows.map { $0.joined() }
}

// MARK: - Tests

@Suite("extensions modal byte stream")
struct PagerExtensionsByteStreamTests {
    @Test("a cell the previous frame already holds is diff-skipped, yet the screen keeps the full description")
    func coincidentCellSurvivesDiffOnScreen() throws {
        let width = 140
        let height = 34
        let modalFrame = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: width, height: height),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
            input: PagerComposerState(text: ""),
            theme: .grokNight,
            showScrollbar: false,
            overlays: PagerOverlayStack([PagerOverlay.extensions(PagerExtensionsOverlay(
                activeTab: .hooks,
                hooks: [PagerExtensionsHookRow(
                    event: "Pre-Tool Use",
                    matcher: "Bash",
                    command: "echo audited",
                    sourceDir: "/tmp/home/hooks",
                    sourceLabel: "Global hooks"
                )]
            ))])
        ))
        // The logical snapshot — the view the unit suite always asserted —
        // has the full line. That is necessary but NOT sufficient.
        #expect(modalFrame.snapshot().contains("\u{2192} echo audited"))

        // Find the description's `o` of "echo" in the frame buffer, then build
        // a previous frame that holds EXACTLY that cell (grapheme + attributes)
        // and nothing else — the deterministic form of the welcome-subtitle
        // coincidence.
        var arrow: (x: Int, y: Int)?
        for y in 0..<height {
            for x in 0..<width where modalFrame.buffer.cell(x: x, y: y)?.grapheme == "\u{2192}" {
                arrow = (x, y)
            }
        }
        let arrowAt = try #require(arrow)
        let oCell = try #require(modalFrame.buffer.cell(x: arrowAt.x + 5, y: arrowAt.y))
        #expect(oCell.grapheme == "o")

        var coincidentBuffer = CellBuffer(
            area: TerminalRect(x: 0, y: 0, width: width, height: height)
        )
        coincidentBuffer.setCell(oCell, x: arrowAt.x + 5, y: arrowAt.y)
        var previousFrame = modalFrame
        previousFrame.buffer = coincidentBuffer
        previousFrame.links = []
        previousFrame.overlays = []

        let sink = ByteStreamSink()
        let renderer = PagerTerminalRenderer(
            sink: sink,
            configuration: PagerTerminalRendererConfiguration(mode: .fullscreen)
        )
        try renderer.render(previousFrame)
        let firstFrameEnd = sink.bytes.count
        try renderer.render(modalFrame)
        let secondFrame = Array(sink.bytes[firstFrameEnd...])

        // The diff must NOT re-emit the unchanged `o` (`diffLarge`, ratatui
        // `Buffer::diff` parity) — so the raw stream reads "ech" + "audited".
        // This is the exact artifact once misread as a dropped character;
        // anyone matching needles against raw emission order will hit it.
        let raw = emittedGlyphs(secondFrame)
        #expect(!raw.contains("\u{2192} echo audited"))
        #expect(raw.contains("ech"))

        // The terminal's screen — the replayed stream — keeps every painted
        // byte of the description line. THIS failing means a character truly
        // dropped, and that is a real renderer bug.
        let rows = replayedScreenRows(sink.bytes, width: width, height: height)
        let descriptionRow = try #require(rows.first { $0.contains("\u{2192}") })
        #expect(descriptionRow.contains("\u{2192} echo audited"))
    }
}
