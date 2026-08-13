// LiveMouseBlockSelectionTests.swift
//
// Click-to-select against REAL painted conversation hit geometry
// (AGENTS.md §3): down+up on a content row selects that block and returns
// `.focusScrollback`; gap / capturing overlay / composer / scrollbar gutter /
// system / separator do not. Geometry comes from `lastConversationHit`
// published only by frames that actually painted (not coalesced layouts).

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class BlockSelectCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

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
                       bytes[index + 1] == UInt8(ascii: "\\") {
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
}

private struct BlockSelectFixture {
    let home: URL
    let sink: BlockSelectCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let terminalHeight: Int
    let terminalWidth: Int

    init(
        configTOML: String? = nil,
        terminalHeight: Int = 30,
        terminalWidth: Int = 100,
        paintCadence: TimeInterval = PagerMotion.minimumPaintCadence
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-block-select-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        self.terminalHeight = terminalHeight
        self.terminalWidth = terminalWidth
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = BlockSelectCapturingSink()
        let height = terminalHeight
        let width = terminalWidth
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: width, height: height) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "alpha-model", providerID: "xai", name: "alpha-model"),
                LiveModelPickerEntry(id: "beta-model", providerID: "xai", name: "beta-model"),
            ],
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: home,
                environment: environment
            ),
            sessionID: "block-select",
            openGrokHome: home,
            paintCadence: paintCadence,
            environment: environment
        )
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
        return sink.text.filter { !$0.isWhitespace }.contains(compact)
    }

    /// Seed two user/assistant turns so an inter-block gap exists
    /// (user/assistant are never groupable, so they never pack).
    func seedTwoBlocks() async throws {
        try await renderer.begin()
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "alpha-block-unique-token",
            mode: .fullScreen
        )))
        try await renderer.render(.session(.output("alpha-reply-unique-token\n")))
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "beta-block-unique-token",
            mode: .fullScreen
        )))
        try await renderer.render(.session(.output("beta-reply-unique-token\n")))
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await waitForPaint(containing: "beta-block-unique-token"))
    }
}

/// First on-screen selectable text cell + a same-row drag X that exceeds the
/// ≥1 drag threshold without leaving the line's selectable span.
private func firstVisibleSelectablePoint(
    in text: PagerTextSelectionModel
) -> (x: Int, y: Int, entryIndex: Int, dragX: Int)? {
    for range in text.ranges {
        for line in range.lines {
            guard let screenY = line.screenY else { continue }
            let width = line.selectableCols.upperBound - line.selectableCols.lowerBound
            // Need at least two selectable columns so dx ≥ 1 promotes the drag.
            guard width > 1 else { continue }
            let x = line.screenX + line.selectableCols.lowerBound
            let dragCol = min(2, width - 1)
            let dragX = line.screenX + line.selectableCols.lowerBound + dragCol
            return (x, screenY, range.entryIndex, dragX)
        }
    }
    return nil
}

private func contentPoint(
    in model: PagerConversationHitModel,
    blockIndex: Int
) -> (x: Int, y: Int)? {
    let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2
    // Sticky header band: pinned/pushed user prompts hit via header rows
    // (logical contentY - scrollOffset often lands above the viewport).
    if model.sticky.hasHeader {
        for row in 0..<model.sticky.headerScreenRows {
            if model.sticky.entryAtHeaderRow(row) == blockIndex {
                let screenY = model.conversation.y + row
                guard model.blockIndex(atScreenY: screenY) == blockIndex else { continue }
                return (x, screenY)
            }
        }
    }
    guard model.blockStartLines.indices.contains(blockIndex),
          model.blockHeights.indices.contains(blockIndex),
          model.blockHeights[blockIndex] > 0
    else { return nil }
    let contentY = model.blockStartLines[blockIndex]
    let viewportY = contentY - model.scrollOffset
    let headerRows = model.sticky.hasHeader ? model.sticky.headerScreenRows : 0
    // Content paints below the sticky band; a row inside the header zone is
    // not this block's content (Rust content_y still uses logical scroll).
    guard viewportY >= headerRows,
          viewportY < model.conversation.height
    else { return nil }
    let screenY = model.conversation.y + viewportY
    guard model.blockIndex(atScreenY: screenY) == blockIndex else { return nil }
    return (x, screenY)
}

/// First real inter-block gap whose screen row sits inside the published
/// conversation rect. Follow-tail often scrolls the earliest gap off-screen,
/// so every adjacent pair is scanned — packed neighbors (gapContentY ==
/// nextStart) are skipped. Candidates must also resolve to `nil` through
/// `blockIndex(atScreenY:)` so a content row can never be mistaken for a gap.
private func gapPoint(in model: PagerConversationHitModel) -> (x: Int, y: Int)? {
    let count = min(model.blockStartLines.count, model.blockHeights.count)
    guard count >= 2 else { return nil }
    let area = model.conversation
    guard area.height > 0 else { return nil }
    let x = area.x + PagerLayoutMetrics.chromeWidth + 2
    let headerRows = model.sticky.hasHeader ? model.sticky.headerScreenRows : 0
    for index in 0..<(count - 1) {
        let gapContentY = model.blockStartLines[index] + model.blockHeights[index]
        // Packed neighbors abut; only a real inter-block gap is a nil hit.
        guard gapContentY < model.blockStartLines[index + 1] else { continue }
        let viewportY = gapContentY - model.scrollOffset
        // Content-area gaps only — sticky header/gap rows are covered by
        // LiveStickyHeaderTests, not this inter-block fixture.
        guard viewportY >= headerRows, viewportY < area.height else { continue }
        let screenY = area.y + viewportY
        // Refuse any candidate the hit model still treats as content.
        guard model.blockIndex(atScreenY: screenY) == nil else { continue }
        return (x, screenY)
    }
    return nil
}

@Suite("Live mouse block selection", .serialized)
struct LiveMouseBlockSelectionTests {
    @Test("down+up on a content row selects that block and returns focusScrollback")
    func contentClickSelectsAndFocuses() async throws {
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()

        let model = try #require(await fixture.renderer.lastConversationHit)
        // Prefer a later visible content block (assistant reply of turn 1).
        let target = min(2, model.blockStartLines.count - 1)
        let point = try #require(contentPoint(in: model, blockIndex: target))

        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: point.x,
            y: point.y,
            button: .left
        )))
        #expect(down == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up,
            x: point.x,
            y: point.y,
            button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == target)
        #expect(await !fixture.renderer.testingFollowsBottom())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("down+up on an inter-block gap does not select")
    func gapClickIsNoOp() async throws {
        // Tall enough that two short turns leave at least one inter-block
        // gap inside the published conversation rect at follow-tail — a
        // 30-row chrome can scroll the earliest gap away.
        let fixture = try BlockSelectFixture(terminalHeight: 48)
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()

        let model = try #require(await fixture.renderer.lastConversationHit)
        let point = try #require(gapPoint(in: model))
        #expect(model.blockIndex(atScreenY: point.y) == nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: point.x, y: point.y, button: .left
        )))
        #expect(up == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a capturing modal click does not select the transcript underneath")
    func capturingOverlayBlocksSelection() async throws {
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()

        let before = await fixture.renderer.testingScrollbackSelectedIndex()
        try await fixture.renderer.render(.overlay(.modelPicker(query: nil)))
        #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))

        let focusedID = try #require(await fixture.renderer.testingFocusedOverlayID())
        let focused = try #require(
            await fixture.renderer.lastOverlayBounds.last(where: { $0.id == focusedID })
        )
        let x = focused.frame.x + max(1, focused.frame.width / 2)
        let y = focused.frame.y + max(1, focused.frame.height / 2)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: y, button: .left
        )))
        #expect(up != .focusScrollback)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == before)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a click in the composer band does not select a transcript block")
    func composerClickDoesNotSelect() async throws {
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()

        let model = try #require(await fixture.renderer.lastConversationHit)
        // First row below the conversation pane — chrome places the composer
        // (or turn-status/shortcuts) there; never a content row.
        let y = model.conversation.y + model.conversation.height
        #expect(y < 30)
        let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: y, button: .left
        )))
        #expect(up == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a rail tick click still jumps and does not leave a scrollback selection")
    func railPriorityPreserved() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-block-rail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try "[ui]\nshow_timeline = true\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(sessionID: "rail-select", workingDirectory: home)
        record.items = [
            .user("alpha anchor question"),
            .assistant(AssistantItem(
                content: (0..<25).map { "afill \($0)" }.joined(separator: "\n\n")
            )),
            .user("second question zebra"),
            .assistant(AssistantItem(
                content: (0..<25).map { "bfill \($0)" }.joined(separator: "\n\n")
            )),
        ]
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        let sink = BlockSelectCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "unknown",
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: home,
                environment: environment
            ),
            sessionID: "rail-select",
            conversationHistory: history,
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
        try await renderer.begin()
        try await renderer.render(.sessionResumed(sessionID: "rail-select"))
        let deadline = Date().addingTimeInterval(5)
        var painted = false
        while Date() < deadline {
            if sink.text.filter({ !$0.isWhitespace }).contains("restored.") {
                painted = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(painted)

        // Same geometry the timeline click test pins: rail at x=98, turn-1 tick y=13.
        let routing = try await renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: 98,
            y: 13,
            button: .left
        )))
        #expect(routing == .consumed)
        #expect(await renderer.testingScrollbackSelectedIndex() == nil)
        try await renderer.restoreTerminal()
    }

    @Test("scrollbar gutter click does not select with timeline off (default)")
    func scrollbarGutterExcludedLive() async throws {
        // Short viewport + tall assistant body forces the default scrollbar
        // (show_timeline stays false — the rail must not steal the gutter).
        let fixture = try BlockSelectFixture(terminalHeight: 18)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        let tall = (0..<60).map { "scrollbar-fill-\($0)-unique" }.joined(separator: "\n")
        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "scrollbar-prompt-unique",
            mode: .fullScreen
        )))
        try await fixture.renderer.render(.session(.output(tall + "\n")))
        try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await fixture.waitForPaint(containing: "scrollbar-fill-0-unique"))

        let model = try #require(await fixture.renderer.lastConversationHit)
        let gutterX = model.selectableEndX
        #expect(model.conversation.contains(x: gutterX, y: model.conversation.y))
        #expect(!model.containsSelectablePoint(x: gutterX, y: model.conversation.y))
        // Content band still arms.
        let content = try #require(contentPoint(in: model, blockIndex: 0))
        #expect(model.containsSelectablePoint(x: content.x, y: content.y))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: gutterX, y: content.y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: gutterX, y: content.y, button: .left
        )))
        #expect(up == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("system and separator blocks are not selected by click")
    func systemAndSeparatorNoSelect() async throws {
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()
        let before = await fixture.renderer.testingScrollbackSelectedIndex()

        try await fixture.renderer.testingAppendConversationItem(
            .message(PagerMessage(role: .system, text: "system-no-select-unique-token"))
        )
        #expect(await fixture.waitForPaint(containing: "system-no-select-unique-token"))
        var model = try #require(await fixture.renderer.lastConversationHit)
        let systemIndex = await fixture.renderer.testingConversationItemCount() - 1
        let systemPoint = try #require(contentPoint(in: model, blockIndex: systemIndex))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: systemPoint.x, y: systemPoint.y, button: .left
        )))
        var up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: systemPoint.x, y: systemPoint.y, button: .left
        )))
        #expect(up == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == before)

        try await fixture.renderer.testingAppendConversationItem(
            .separator("separator-no-select-unique-token")
        )
        #expect(await fixture.waitForPaint(containing: "separator-no-select-unique-token"))
        model = try #require(await fixture.renderer.lastConversationHit)
        let separatorIndex = await fixture.renderer.testingConversationItemCount() - 1
        let separatorPoint = try #require(contentPoint(in: model, blockIndex: separatorIndex))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: separatorPoint.x, y: separatorPoint.y, button: .left
        )))
        up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: separatorPoint.x, y: separatorPoint.y, button: .left
        )))
        #expect(up == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == before)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("X10-style up with no button completes against the pending left-down")
    func x10StyleUpNoneCompletesPendingClick() async throws {
        // Legacy X10 releases decode as `.up` + `resolvedButton == .none`
        // (wire code 3). Pending is armed only by left-down; the up half
        // must still complete against that frozen snapshot.
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()

        let model = try #require(await fixture.renderer.lastConversationHit)
        let target = min(2, model.blockStartLines.count - 1)
        let point = try #require(contentPoint(in: model, blockIndex: target))

        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: point.x,
            y: point.y,
            button: .left
        )))
        #expect(down == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up,
            x: point.x,
            y: point.y,
            button: .none
        )))
        #expect(up == .focusScrollback)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == target)
        #expect(await !fixture.renderer.testingFollowsBottom())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("middle or right up clears pending and does not select")
    func nonLeftUpRejectsPendingClick() async throws {
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()

        let model = try #require(await fixture.renderer.lastConversationHit)
        let target = min(2, model.blockStartLines.count - 1)
        let point = try #require(contentPoint(in: model, blockIndex: target))

        for button: MouseButton in [.middle, .right] {
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .down, x: point.x, y: point.y, button: .left
            )))
            let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .up, x: point.x, y: point.y, button: button
            )))
            #expect(up == .consumed)
            #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)

            // Pending must be cleared: a later X10-style `.none` up alone
            // cannot resurrect the armed left-down.
            let stray = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .up, x: point.x, y: point.y, button: .none
            )))
            #expect(stray == .consumed)
            #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        }
        try await fixture.renderer.restoreTerminal()
    }

    @Test("jittered up without a drag still selects the down cell")
    func jitteredUpStillSelects() async throws {
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()

        let model = try #require(await fixture.renderer.lastConversationHit)
        let target = min(2, model.blockStartLines.count - 1)
        let point = try #require(contentPoint(in: model, blockIndex: target))
        // One cell of jitter still inside the content band — not a drag event.
        let upX = point.x + 1
        #expect(model.containsSelectablePoint(x: upX, y: point.y))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: upX, y: point.y, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == target)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("drag on selectable text promotes text drag over pending block click")
    func selectableTextDragPromotesOverBlockClick() async throws {
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let conversation = try #require(await fixture.renderer.lastConversationHit)
        let textModel = try #require(await fixture.renderer.testingLastTextSelection())
        // Block-start contentPoint often lands on vpad/chrome with no text hit —
        // arm from the first on-screen selectable line cell.
        let point = try #require(firstVisibleSelectablePoint(in: textModel))
        let blockAtY = try #require(conversation.blockIndex(atScreenY: point.y))
        #expect(blockAtY == point.entryIndex)
        // Published selectable lines only come from mouse-selectable entries
        // (system never contributes). Threshold drag must promote text.
        #expect(textModel.hitTestSelectableRange(col: point.x, row: point.y) != nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        #expect(await fixture.renderer.testingPendingScrollbackClick() != nil)
        #expect(await fixture.renderer.testingPendingTextDrag() != nil)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)

        let dragX = point.dragX
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: dragX, y: point.y, button: .left
        )))
        // Text drag wins: pending block click cleared, active drag armed.
        #expect(await fixture.renderer.testingPendingScrollbackClick() == nil)
        #expect(await fixture.renderer.testingActiveTextDrag() != nil)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: dragX, y: point.y, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(await fixture.renderer.testingActiveTextDrag() == nil)
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(persistent.origin == .drag)
        #expect(persistent.entryIndex == point.entryIndex)
        // Finish focuses the text entry (not a lingering pending-click select).
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == point.entryIndex)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("drag on nonselectable system clears pending without block select")
    func nonselectableDragClearsPendingNoBlockSelect() async throws {
        let fixture = try BlockSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()
        try await fixture.renderer.testingAppendConversationItem(
            .message(PagerMessage(role: .system, text: "system-drag-no-select-unique-token"))
        )
        #expect(await fixture.waitForPaint(containing: "system-drag-no-select-unique-token"))

        let model = try #require(await fixture.renderer.lastConversationHit)
        let systemIndex = await fixture.renderer.testingConversationItemCount() - 1
        let point = try #require(contentPoint(in: model, blockIndex: systemIndex))
        // System publishes no selectable text — drag cannot promote text selection.
        let textModel = await fixture.renderer.testingLastTextSelection()
        #expect(textModel?.hitTestSelectableRange(col: point.x, row: point.y) == nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        // Chrome/system miss arms deferred_text_press; that owns the gesture
        // so pending block click may remain until up (Rust deferred press).
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: point.x + 2, y: point.y, button: .left
        )))
        #expect(await fixture.renderer.testingActiveTextDrag() == nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: point.x + 2, y: point.y, button: .left
        )))
        #expect(up == .consumed)
        #expect(await fixture.renderer.testingPendingScrollbackClick() == nil)
        #expect(await fixture.renderer.testingDeferredTextPress() == nil)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)

        try await fixture.renderer.restoreTerminal()
    }

    @Test("coalesced layout does not publish unpainted hit geometry")
    func coalescedLayoutDoesNotClaimHitGeometry() async throws {
        // Long cadence: two back-to-back notices after a settled paint fold
        // into one deferred flush. The first may paint (cadence already
        // elapsed) or coalesce; the second must coalesce if a flush is
        // scheduled, and hit geometry must not advance to the second notice
        // until that flush paints.
        let fixture = try BlockSelectFixture(paintCadence: 1.0)
        defer { fixture.dispose() }
        try await fixture.seedTwoBlocks()
        let before = try #require(await fixture.renderer.lastConversationHit)
        let beforeCount = before.blockStartLines.count

        try await fixture.renderer.render(.notice("coalesce-hit-first-unique"))
        try await fixture.renderer.render(.notice("coalesce-hit-second-unique"))

        if await fixture.renderer.testingHasScheduledFrame() {
            let mid = try #require(await fixture.renderer.lastConversationHit)
            // At most the first notice could have painted; the second is
            // folded and must not appear in last-painted hit geometry yet.
            #expect(mid.blockStartLines.count <= beforeCount + 1)
            #expect(mid.blockStartLines.count < beforeCount + 2)
        }

        #expect(await fixture.waitForPaint(containing: "coalesce-hit-second-unique", timeout: 4))
        let after = try #require(await fixture.renderer.lastConversationHit)
        #expect(after.blockStartLines.count == beforeCount + 2)
        try await fixture.renderer.restoreTerminal()
    }
}
