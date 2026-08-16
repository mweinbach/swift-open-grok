// LiveTableTextSelectionTests.swift
//
// Live-seam proofs for table cell/grid transcript selection against
// last-painted `PagerTextSelectionModel` (AGENTS.md §3, pin 650c1db7).
// Injects pre-styled box-drawing fixture lines so paint preserves the grid
// (markdown `fit`s cells onto one line rather than wrapping fragments).

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class TableSelectCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var rawUTF8: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        var output = ""
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.unicodeScalars.append(Unicode.Scalar(bytes[index]))
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\")
                    {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return output
    }

    func lastOSC52Payload() -> String? {
        let raw = rawUTF8
        guard let range = raw.range(of: "52;c;", options: .backwards) else { return nil }
        var b64 = raw[range.upperBound...]
        if let bel = b64.firstIndex(of: "\u{07}") {
            b64 = b64[..<bel]
        } else if let st = b64.range(of: "\u{1B}\\") {
            b64 = b64[..<st.lowerBound]
        }
        guard let data = Data(base64Encoded: String(b64)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class TableSelectSizeBox: @unchecked Sendable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Box-drawing fixture matching PagerTextSelectionModelTests (wrapped Name cell).
private let tableFixtureLines = [
    "┌─────────┬────────┐",
    "│ Name    │ Role   │",
    "├─────────┼────────┤",
    "│ Alice   │ Eng    │",
    "│ Smith   │        │",
    "├─────────┼────────┤",
    "│ Bob     │ Design │",
    "└─────────┴────────┘",
]

private let malformedTableLines = [
    "┌────┐",
    "│ x  │",
]

private struct TableSelectFixture {
    let home: URL
    let sink: TableSelectCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let sizeBox: TableSelectSizeBox

    init(
        configTOML: String? = nil,
        terminalHeight: Int = 36,
        terminalWidth: Int = 100,
        paintCadence: TimeInterval = PagerMotion.minimumPaintCadence
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-table-select-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        sizeBox = TableSelectSizeBox(width: terminalWidth, height: terminalHeight)
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = TableSelectCapturingSink()
        let box = sizeBox
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: box.width, height: box.height) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "alpha-model", providerID: "xai", name: "alpha-model"),
            ],
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: home,
                environment: environment
            ),
            sessionID: "table-select",
            openGrokHome: home,
            paintCadence: paintCadence,
            environment: environment
        )
    }

    func resize(width: Int, height: Int? = nil) async throws {
        sizeBox.width = width
        if let height { sizeBox.height = height }
        try await renderer.resize(to: TerminalSize(width: sizeBox.width, height: sizeBox.height))
        if await renderer.testingHasPendingFlushTask() {
            await renderer.testingFlushPendingFrameNow()
        }
        await renderer.testingFlushPendingFrameNow()
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func waitForPaint(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let compact = needle.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.text.filter({ !$0.isWhitespace }).contains(compact) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.text.filter({ !$0.isWhitespace }).contains(compact)
    }

    func seedStyledTable(lines: [String] = tableFixtureLines) async throws {
        try await renderer.begin()
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "table-select-user-prompt-unique",
            mode: .fullScreen
        )))
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        try await renderer.testingAppendConversationItem(.message(PagerMessage(
            role: .assistant,
            text: lines.joined(separator: "\n"),
            styledLines: lines.map { PagerStyledLine(text: $0) }
        )))
        let needle = lines.first { $0.contains("Alice") || $0.contains("x") } ?? lines[1]
        let token = needle.split(whereSeparator: { $0 == "│" || $0 == " " })
            .map(String.init)
            .first { !$0.isEmpty } ?? "Alice"
        #expect(await waitForPaint(containing: token))
    }
}

private func needleDisplayCols(in text: String, needle: String) -> Range<Int>? {
    guard let range = text.range(of: needle) else { return nil }
    let prefix = String(text[..<range.lowerBound])
    let start = UnicodeDisplayWidth.width(of: prefix)
    let width = UnicodeDisplayWidth.width(of: needle)
    guard width > 0 else { return nil }
    return start..<(start + width)
}

private func textPoint(
    in model: PagerTextSelectionModel,
    containing needle: String,
    colOffset: Int = 0
) -> (x: Int, y: Int, hit: PagerTextRangeHit)? {
    for range in model.ranges {
        for line in range.lines {
            guard let screenY = line.screenY,
                  let needleCols = needleDisplayCols(in: line.text, needle: needle)
            else { continue }
            let lineWidth = line.selectableCols.upperBound - line.selectableCols.lowerBound
            guard lineWidth > 0 else { continue }
            let needleLast = needleCols.upperBound - 1
            let raw = needleCols.lowerBound + max(0, colOffset)
            let colWithin = min(max(needleCols.lowerBound, min(raw, needleLast)), lineWidth - 1)
            let x = line.screenX + line.selectableCols.lowerBound + colWithin
            return (
                x,
                screenY,
                PagerTextRangeHit(
                    entryIndex: range.entryIndex,
                    rangeID: range.rangeID,
                    blockLineIndex: line.blockLineIndex,
                    colWithinRange: colWithin
                )
            )
        }
    }
    return nil
}

private func colPoint(
    in model: PagerTextSelectionModel,
    containing needle: String,
    colWithinRange: Int
) -> (x: Int, y: Int, hit: PagerTextRangeHit)? {
    for range in model.ranges {
        for line in range.lines {
            guard let screenY = line.screenY, line.text.contains(needle) else { continue }
            let lineWidth = line.selectableCols.upperBound - line.selectableCols.lowerBound
            guard lineWidth > 0 else { continue }
            let colWithin = min(max(0, colWithinRange), lineWidth - 1)
            let x = line.screenX + line.selectableCols.lowerBound + colWithin
            return (
                x,
                screenY,
                PagerTextRangeHit(
                    entryIndex: range.entryIndex,
                    rangeID: range.rangeID,
                    blockLineIndex: line.blockLineIndex,
                    colWithinRange: colWithin
                )
            )
        }
    }
    return nil
}

private func isTableShaped(_ kind: PagerTextSelectionKind) -> Bool {
    switch kind {
    case .linear: return false
    case .tableCell, .tableGrid: return true
    }
}

/// Force-paint until `needle` has a non-nil `screenY`. Wall-clock
/// `testingFlushPendingFrameNow` is not due under a long cadence, so
/// last-painted geometry can stay on a previous follow-tail frame.
/// Callers that need the needle on-screen should seed it at the tail
/// (this helper re-engages `.bottom`, it does not hunt via lineUp).
private func paintedModelShowing(
    _ fixture: TableSelectFixture,
    needle: String,
    paintCadence: TimeInterval
) async throws -> PagerTextSelectionModel? {
    var flushAt = await fixture.renderer.testingMonotonicNow() + paintCadence + 1
    for _ in 0..<16 {
        try await fixture.renderer.render(.viewport(.bottom))
        _ = await fixture.renderer.testingFlushPendingFrame(at: flushAt)
        flushAt += paintCadence + 1
        if let model = await fixture.renderer.testingLastTextSelection(),
           model.ranges.contains(where: { range in
               range.lines.contains { line in
                   line.screenY != nil && line.text.contains(needle)
               }
           })
        {
            return model
        }
    }
    return nil
}

private func tripleClick(
    on fixture: TableSelectFixture,
    at point: (x: Int, y: Int, hit: PagerTextRangeHit),
    startMs: UInt64 = 1_000
) async throws {
    for step in 0..<3 {
        await fixture.renderer.testingSetTextSelectionNowMs(startMs + UInt64(step) * 100)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: point.x, y: point.y, button: .left
        )))
    }
}

@Suite("Live table text selection", .serialized)
struct LiveTableTextSelectionTests {

    @Test("cell drag copies wrapped fragments space-joined and keeps sidecar")
    func cellDragCopy() async throws {
        let fixture = try TableSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "Alice", colOffset: 0))
        // Pin reconstruct respects endpoints (`"Ali"` golden); same-cell
        // drag is not snapped to the whole cell. Land on the Name band end
        // of the wrapped fragment (unit golden `(4, 9)`).
        let end = try #require(colPoint(in: model, containing: "Smith", colWithinRange: 9))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        let drag = try #require(await fixture.renderer.testingActiveTextDrag())
        #expect(drag.kind == .tableCell)
        #expect(await fixture.renderer.testingTableSelectionGeometry() != nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(fixture.sink.lastOSC52Payload() == "Alice Smith")
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(persistent.origin == .drag)
        #expect(persistent.kind == .tableCell)
        let sidecar = try #require(await fixture.renderer.testingTableSelectionGeometry())
        #expect(sidecar.forSelection(entryIndex: persistent.entryIndex, rangeID: persistent.rangeID) != nil)
        #expect(await fixture.renderer.testingRenderStateTableSelectionGeometry() == sidecar)
        switch try #require(await fixture.renderer.testingCurrentTextSelectionHighlight()) {
        case .persistent(let painted):
            #expect(painted.kind == .tableCell)
        case .active:
            Issue.record("expected persistent table highlight after mouse-up")
        }

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
        #expect(await fixture.renderer.testingTableSelectionGeometry() == nil)
    }

    @Test("grid drag copies TSV of the cell rectangle")
    func gridDragTSV() async throws {
        let fixture = try TableSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "Alice", colOffset: 1))
        let end = try #require(textPoint(in: model, containing: "Eng", colOffset: 0))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        let drag = try #require(await fixture.renderer.testingActiveTextDrag())
        switch drag.kind {
        case .tableGrid(let a, let h):
            #expect(min(a.col, h.col) == 0)
            #expect(max(a.col, h.col) == 1)
        case .linear, .tableCell:
            Issue.record("expected tableGrid, got \(drag.kind)")
        }

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(fixture.sink.lastOSC52Payload() == "Alice Smith\tEng")
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        switch persistent.kind {
        case .tableGrid:
            break
        case .linear, .tableCell:
            Issue.record("expected persisted tableGrid")
        }
        #expect(await fixture.renderer.testingTableSelectionGeometry() != nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("hysteresis keeps grid across padding then de-escalates in-cell")
    func hysteresisAndDeescalation() async throws {
        let fixture = try TableSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let alice = try #require(textPoint(in: model, containing: "Alice", colOffset: 1))
        let eng = try #require(textPoint(in: model, containing: "Eng", colOffset: 0))
        // Name band is 1..<10, interior 2..<9. Col 9 is padding (unit goldens
        // keep prior kind at 9/10/11; col 8 is interior and de-escalates).
        let padding = try #require(colPoint(in: model, containing: "Alice", colWithinRange: 9))
        let aliceInterior = try #require(colPoint(in: model, containing: "Alice", colWithinRange: 3))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: alice.x, y: alice.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: eng.x, y: eng.y, button: .left
        )))
        switch try #require(await fixture.renderer.testingActiveTextDrag()).kind {
        case .tableGrid: break
        case .linear, .tableCell:
            Issue.record("expected grid after crossing into Eng")
        }

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: padding.x, y: padding.y, button: .left
        )))
        switch try #require(await fixture.renderer.testingActiveTextDrag()).kind {
        case .tableGrid: break
        case .linear, .tableCell:
            Issue.record("hysteresis should keep grid on original-cell padding")
        }

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: aliceInterior.x, y: aliceInterior.y, button: .left
        )))
        #expect(try #require(await fixture.renderer.testingActiveTextDrag()).kind == .tableCell)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: aliceInterior.x, y: aliceInterior.y, button: .left
        )))
        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("border/divider drag stays linear and drops sidecar on persist")
    func borderDragLinear() async throws {
        let fixture = try TableSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "┌", colOffset: 3))
        let end = try #require(textPoint(in: model, containing: "Alice", colOffset: 1))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        #expect(try #require(await fixture.renderer.testingActiveTextDrag()).kind == .linear)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(persistent.kind == .linear)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == nil)
        let payload = try #require(fixture.sink.lastOSC52Payload())
        #expect(!payload.contains("\t"))

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("empty padding cell stays table path: no OSC52, no persist chrome")
    func emptyPaddingCellNoCopyNoChrome() async throws {
        let fixture = try TableSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        // Name band 1..<10; "Alice" occupies 2..<7, cols 7-9 are padding.
        let start = try #require(colPoint(in: model, containing: "Alice", colWithinRange: 7))
        let end = try #require(colPoint(in: model, containing: "Alice", colWithinRange: 9))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        #expect(try #require(await fixture.renderer.testingActiveTextDrag()).kind == .tableCell)
        #expect(await fixture.renderer.testingTableSelectionGeometry() != nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(fixture.sink.lastOSC52Payload() == nil)
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == nil)
        #expect(await fixture.renderer.testingRenderStateTableSelectionGeometry() == nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("word_select triple cell copies wrapped cell; border copies whole TSV")
    func tripleClickCellAndWholeTable() async throws {
        let fixture = try TableSelectFixture(
            configTOML: """
            [ui]
            keep_text_selection = "word_select"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .wordSelect)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let alice = try #require(textPoint(in: model, containing: "Alice", colOffset: 1))
        try await tripleClick(on: fixture, at: alice, startMs: 1_000)
        #expect(fixture.sink.lastOSC52Payload() == "Alice Smith")
        let cell = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(cell.origin == .tripleClick)
        #expect(cell.kind == .tableCell)
        #expect(await fixture.renderer.testingTableSelectionGeometry() != nil)

        let border = try #require(textPoint(in: model, containing: "├", colOffset: 3))
        try await tripleClick(on: fixture, at: border, startMs: 2_000)
        #expect(
            fixture.sink.lastOSC52Payload()
                == "Name\tRole\nAlice Smith\tEng\nBob\tDesign"
        )
        let grid = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(grid.origin == .tripleClick)
        switch grid.kind {
        case .tableGrid(let a, let h):
            #expect(a == PagerTableCellRef(row: 0, col: 0))
            #expect(h == PagerTableCellRef(row: 2, col: 1))
        case .linear, .tableCell:
            Issue.record("expected whole-table tableGrid")
        }

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("word_select double stays word, not the whole cell")
    func doubleClickStaysWord() async throws {
        let fixture = try TableSelectFixture(
            configTOML: """
            [ui]
            keep_text_selection = "word_select"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let alice = try #require(textPoint(in: model, containing: "Alice", colOffset: 1))
        await fixture.renderer.testingSetTextSelectionNowMs(1_000)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: alice.x, y: alice.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: alice.x, y: alice.y, button: .left
        )))
        await fixture.renderer.testingSetTextSelectionNowMs(1_100)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: alice.x, y: alice.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: alice.x, y: alice.y, button: .left
        )))
        #expect(fixture.sink.lastOSC52Payload() == "Alice")
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(persistent.origin == .doubleClick)
        #expect(persistent.kind == .linear)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("malformed box lines degrade to linear")
    func malformedFallsToLinear() async throws {
        let fixture = try TableSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedStyledTable(lines: malformedTableLines)
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "x", colOffset: 0))
        let end = try #require(textPoint(in: model, containing: "┌", colOffset: 2))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        #expect(try #require(await fixture.renderer.testingActiveTextDrag()).kind == .linear)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(persistent.kind == .linear)
        let payload = try #require(fixture.sink.lastOSC52Payload())
        #expect(payload.contains("x"))
        #expect(!payload.contains("\t"))

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("resize mid-drag copies from frozen sidecar; autoscroll keeps table kind")
    func resizeAndAutoscrollUseFrozenSidecar() async throws {
        let paintCadence: TimeInterval = 5.0
        let fixture = try TableSelectFixture(
            terminalHeight: 24,
            paintCadence: paintCadence
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        // Fillers first so follow-tail keeps the table on-screen; autoscroll
        // up still has content above. `viewport(.top)` plus wall-clock flush
        // leaves last-painted `screenY` nil under a long paint cadence.
        for turn in 0..<8 {
            try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "table-filler-user-\(turn) " + String(repeating: "wrap ", count: 20),
                mode: .fullScreen
            )))
            try await fixture.renderer.render(.session(.output(
                "table-filler-assistant-\(turn) " + String(repeating: "reply ", count: 24) + "\n"
            )))
            try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))
        }
        try await fixture.renderer.testingAppendConversationItem(.message(PagerMessage(
            role: .assistant,
            text: tableFixtureLines.joined(separator: "\n"),
            styledLines: tableFixtureLines.map { PagerStyledLine(text: $0) }
        )))
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(
            await paintedModelShowing(fixture, needle: "Alice", paintCadence: paintCadence)
        )
        let start = try #require(textPoint(in: model, containing: "Alice", colOffset: 1))
        let smith = try #require(textPoint(in: model, containing: "Smith", colOffset: 0))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: smith.x, y: smith.y, button: .left
        )))
        #expect(try #require(await fixture.renderer.testingActiveTextDrag()).kind == .tableCell)
        let frozenSidecar = try #require(await fixture.renderer.testingTableSelectionGeometry())

        try await fixture.resize(width: 28)
        let afterResize = try #require(await fixture.renderer.testingActiveTextDrag())
        #expect(afterResize.kind == .tableCell)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == frozenSidecar)

        let edgeY = try #require(await fixture.renderer.testingLastTextSelection()).conversationArea.y
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: start.x, y: edgeY, button: .left
        )))
        if await fixture.renderer.testingDragAutoscroll()?.direction == .up {
            _ = try await fixture.renderer.testingHandleScrollClockTick(at: 0)
        }
        let duringScroll = try #require(await fixture.renderer.testingActiveTextDrag())
        #expect(isTableShaped(duringScroll.kind))
        #expect(await fixture.renderer.testingTableSelectionGeometry() != nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: start.x, y: edgeY, button: .left
        )))
        // Top-edge autoscroll reclamps the head inside the anchor cell;
        // reconstruct stays endpoint-true (partial / reversed), not a
        // whole-cell snap. Wrap-destroyed fail-closed copy is the
        // `narrowResizeBelowTableWidthFailClosed` test (exact fragment).
        let payload = try #require(fixture.sink.lastOSC52Payload())
        #expect(!payload.isEmpty)
        #expect(!payload.contains("\t"))
        #expect(!payload.contains("table-filler"))
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(isTableShaped(persistent.kind))
        #expect(await fixture.renderer.testingTableSelectionGeometry() != nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("narrow resize below table width fail-closes paint and copies exact frozen fragment")
    func narrowResizeBelowTableWidthFailClosed() async throws {
        let fixture = try TableSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "Alice", colOffset: 0))
        let end = try #require(colPoint(in: model, containing: "Smith", colWithinRange: 9))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        #expect(try #require(await fixture.renderer.testingActiveTextDrag()).kind == .tableCell)
        let frozenSidecar = try #require(await fixture.renderer.testingTableSelectionGeometry())
        #expect(await fixture.renderer.testingRenderStateTableSelectionGeometry() == frozenSidecar)

        // Table is 20 cols; chrome is 5 + optional scrollbar. Width 16
        // wraps the grid so live detect cannot match the frozen sidecar.
        try await fixture.resize(width: 16)
        #expect(try #require(await fixture.renderer.testingActiveTextDrag()).kind == .tableCell)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == frozenSidecar)

        let liveModel = try #require(await fixture.renderer.testingLastTextSelection())
        let liveDetect = pagerDetectTableGeometry(
            in: liveModel,
            entryIndex: frozenSidecar.entryIndex,
            rangeID: frozenSidecar.rangeID,
            atLine: frozenSidecar.geometry.lineRange.lowerBound
        )
        #expect(liveDetect != frozenSidecar.geometry)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(fixture.sink.lastOSC52Payload() == "Alice Smith")
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(persistent.kind == .tableCell)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == frozenSidecar)
        #expect(await fixture.renderer.testingRenderStateTableSelectionGeometry() == frozenSidecar)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("sticky header rows stay excluded; table interiors highlight without borders")
    func stickyExclusionAndHighlightInteriors() async throws {
        let fixture = try TableSelectFixture(
            configTOML: """
            [ui]
            show_timeline = false
            keep_text_selection = "hold"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        if model.contentArea.height > 0, model.contentArea.y > model.conversationArea.y {
            let stickyY = model.conversationArea.y
            let x = model.contentArea.x + 2
            #expect(model.hitTestTextExact(col: x, row: stickyY) == nil)
            #expect(model.hitTestSelectableRange(col: x, row: stickyY) == nil)
        }

        let start = try #require(textPoint(in: model, containing: "Alice", colOffset: 0))
        let end = try #require(textPoint(in: model, containing: "Smith", colOffset: 4))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(fixture.sink.lastOSC52Payload() == "Alice Smith")

        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(persistent.kind == .tableCell)
        let sidecar = try #require(await fixture.renderer.testingTableSelectionGeometry())
        let geom = try #require(
            sidecar.forSelection(entryIndex: persistent.entryIndex, rangeID: persistent.rangeID)
        )
        let cell = try #require(
            geom.cellAt(
                line: persistent.anchor.blockLineIndex,
                col: persistent.anchor.colWithinRange
            )
        )
        let band = geom.band(cell.col)
        let junctions = Set(geom.junctionCols)
        #expect(!junctions.contains(persistent.anchor.colWithinRange))
        #expect(!junctions.contains(persistent.head.colWithinRange))
        #expect(band.contains(persistent.anchor.colWithinRange)
            || persistent.anchor.colWithinRange == band.lowerBound)
        #expect(band.contains(persistent.head.colWithinRange)
            || persistent.head.colWithinRange == band.upperBound - 1)
        let rowLines = geom.rowLines(cell.row)
        #expect(rowLines.contains(persistent.anchor.blockLineIndex))
        #expect(rowLines.contains(persistent.head.blockLineIndex))

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Esc / new down / flash expiry drop sidecar with the highlight")
    func sidecarLifecycle() async throws {
        let fixture = try TableSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedStyledTable()

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "Alice", colOffset: 0))
        let end = try #require(textPoint(in: model, containing: "Smith", colOffset: 0))

        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(await fixture.renderer.testingTableSelectionGeometry() != nil)

        _ = try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape)))
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == nil)

        await fixture.renderer.testingSetKeepTextSelectionMode(.flash)
        await fixture.renderer.testingSetTextSelectionNowMs(5_000)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(await fixture.renderer.testingTableSelectionGeometry() != nil)
        let deadline = try #require(await fixture.renderer.testingTextSelectionFlashDeadlineMs())
        #expect(deadline == 5_000 + pagerTextSelectionFlashTTLMs)
        await fixture.renderer.testingSetTextSelectionNowMs(deadline + 1)
        try await fixture.renderer.testingReconcileTextSelectionFlashDeadline()
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)
        #expect(await fixture.renderer.testingTableSelectionGeometry() == nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }
}
