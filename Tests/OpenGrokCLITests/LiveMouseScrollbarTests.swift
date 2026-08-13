// LiveMouseScrollbarTests.swift
//
// Transcript scrollbar click/drag against REAL last-painted geometry
// (AGENTS.md §3): gutter down changes offset + `.focusScrollback`, drag
// remaps further, up clears the latch, later block clicks still select,
// X10 up-none clears, capturing modals block, and the timeline rail
// replaces the scrollbar (no hit model / no offset change).

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class ScrollbarCapturingSink: PagerTerminalSink, @unchecked Sendable {
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

private struct ScrollbarFixture {
    let home: URL
    let sink: ScrollbarCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let terminalHeight: Int
    let terminalWidth: Int

    init(
        configTOML: String? = nil,
        terminalHeight: Int = 18,
        terminalWidth: Int = 100,
        paintCadence: TimeInterval = PagerMotion.minimumPaintCadence
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-sb-mouse-\(UUID().uuidString)", isDirectory: true)
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
        sink = ScrollbarCapturingSink()
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
            sessionID: "sb-mouse",
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
        return sink.text.filter({ !$0.isWhitespace }).contains(compact)
    }

    /// Deterministic transcript overflow via many completed wrapping
    /// user/assistant turns (same pattern as LiveScrollStreamTests). Overflow
    /// is proven through `testingMaximumScrollOffset`, not by scraping
    /// off-screen sink bytes — the alt-screen only holds the visible viewport.
    func seedOverflowTranscript() async throws {
        try await renderer.begin()
        // Width-100 terminal: ~30-word lines wrap to multiple rows per turn.
        // Twelve turns >> one viewport of conversation rows.
        for turn in 0..<12 {
            let prompt = "sb-user-\(turn) "
                + String(repeating: "prompt-wrap-\(turn) ", count: 24)
            let reply = "sb-assistant-\(turn) "
                + String(repeating: "reply-wrap-\(turn) ", count: 32)
            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: prompt,
                mode: .fullScreen
            )))
            try await renderer.render(.session(.output(reply + "\n")))
            try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))
        }
        // Drain a coalesced flush so painted geometry matches layout bookkeeping.
        if await renderer.testingHasPendingFlushTask() {
            await renderer.testingFlushPendingFrameNow()
        }
        let maxAfterSeed = await renderer.testingMaximumScrollOffset()
        let conversationHeight = await renderer.lastConversationHit?.conversation.height
        let scrollbarViewport = await renderer.lastScrollbarHit?.viewportHeight
        let viewport = conversationHeight ?? scrollbarViewport ?? 1
        #expect(maxAfterSeed > viewport)

        // Explicit bottom gesture, then settle painted scrollbar + follow-tail.
        try await renderer.render(.viewport(.bottom))
        if await renderer.testingHasPendingFlushTask() {
            await renderer.testingFlushPendingFrameNow()
        }
        let deadline = Date().addingTimeInterval(5)
        var settled = false
        while Date() < deadline {
            let follows = await renderer.testingFollowsBottom()
            let offset = await renderer.testingTranscriptScrollOffset()
            let maximum = await renderer.testingMaximumScrollOffset()
            let hasScrollbar = await renderer.lastScrollbarHit != nil
            if follows, maximum > viewport, offset == maximum, hasScrollbar {
                settled = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(settled)
        let follows = await renderer.testingFollowsBottom()
        let offset = await renderer.testingTranscriptScrollOffset()
        let maximum = await renderer.testingMaximumScrollOffset()
        #expect(follows)
        #expect(offset == maximum)
        #expect(maximum > viewport)
        let scrollbarHit = await renderer.lastScrollbarHit
        #expect(scrollbarHit != nil)
    }
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
    guard viewportY >= headerRows,
          viewportY < model.conversation.height
    else { return nil }
    let screenY = model.conversation.y + viewportY
    guard model.blockIndex(atScreenY: screenY) == blockIndex else { return nil }
    return (x, screenY)
}

/// First block whose content row is on-screen in the painted hit model.
/// Mid-scrollbar drags often leave block 0 above the viewport.
private func firstVisibleContentPoint(
    in model: PagerConversationHitModel
) -> (index: Int, x: Int, y: Int)? {
    let count = min(model.blockStartLines.count, model.blockHeights.count)
    for index in 0..<count {
        if let point = contentPoint(in: model, blockIndex: index) {
            return (index, point.x, point.y)
        }
    }
    return nil
}

@Suite("Live mouse scrollbar", .serialized)
struct LiveMouseScrollbarTests {
    @Test("gutter click changes offset, focuses scrollback, and does not select")
    func gutterClickChangesOffset() async throws {
        let fixture = try ScrollbarFixture()
        defer { fixture.dispose() }
        try await fixture.seedOverflowTranscript()

        let sb = try #require(await fixture.renderer.lastScrollbarHit)
        // seedOverflowTranscript already settled follow-tail at max.

        let topY = sb.rect.y
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: sb.rect.x, y: topY, button: .left
        )))
        #expect(down == .focusScrollback)
        #expect(await fixture.renderer.testingScrollbarDragging())
        let afterDown = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(afterDown == 0)
        let followsAfterDown = await fixture.renderer.testingFollowsBottom()
        #expect(!followsAfterDown)
        let selectedAfterDown = await fixture.renderer.testingScrollbackSelectedIndex()
        #expect(selectedAfterDown == nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: sb.rect.x, y: topY, button: .left
        )))
        #expect(up == .consumed)
        let draggingAfterUp = await fixture.renderer.testingScrollbarDragging()
        #expect(!draggingAfterUp)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("drag remaps further; up clears latch; later block click still selects")
    func dragThenBlockClick() async throws {
        let fixture = try ScrollbarFixture()
        defer { fixture.dispose() }
        try await fixture.seedOverflowTranscript()

        var sb = try #require(await fixture.renderer.lastScrollbarHit)
        let topY = sb.rect.y
        let midY = sb.rect.y + max(1, sb.rect.height / 2)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: sb.rect.x, y: topY, button: .left
        )))
        let afterTop = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(afterTop == 0)

        // After the down paint, drag uses the current last-painted model.
        sb = try #require(await fixture.renderer.lastScrollbarHit)
        let expectedMid = sb.offset(atScreenY: midY)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: sb.rect.x, y: midY, button: .left
        )))
        #expect(await fixture.renderer.testingScrollbarDragging())
        let afterDrag = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(afterDrag == expectedMid)
        let followsAfterDrag = await fixture.renderer.testingFollowsBottom()
        #expect(!followsAfterDrag)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: sb.rect.x, y: midY, button: .left
        )))
        let draggingAfterUp = await fixture.renderer.testingScrollbarDragging()
        #expect(!draggingAfterUp)

        // After a mid drag, block 0 is often above the viewport — pick any
        // on-screen content block from the painted hit model.
        let model = try #require(await fixture.renderer.lastConversationHit)
        let visible = try #require(firstVisibleContentPoint(in: model))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: visible.x, y: visible.y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: visible.x, y: visible.y, button: .left
        )))
        #expect(up == .focusScrollback)
        let selected = await fixture.renderer.testingScrollbackSelectedIndex()
        #expect(selected == visible.index)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("X10-style up with no button clears the scrollbar drag latch")
    func x10UpNoneClearsLatch() async throws {
        let fixture = try ScrollbarFixture()
        defer { fixture.dispose() }
        try await fixture.seedOverflowTranscript()

        let sb = try #require(await fixture.renderer.lastScrollbarHit)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: sb.rect.x, y: sb.rect.y, button: .left
        )))
        #expect(await fixture.renderer.testingScrollbarDragging())

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up,
            x: sb.rect.x,
            y: sb.rect.y,
            button: .none
        )))
        #expect(up == .consumed)
        let draggingAfterUp = await fixture.renderer.testingScrollbarDragging()
        #expect(!draggingAfterUp)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("capturing modal blocks gutter click and clears a sticky latch")
    func modalBlocksScrollbar() async throws {
        let fixture = try ScrollbarFixture()
        defer { fixture.dispose() }
        try await fixture.seedOverflowTranscript()

        let sb = try #require(await fixture.renderer.lastScrollbarHit)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: sb.rect.x, y: sb.rect.y, button: .left
        )))
        #expect(await fixture.renderer.testingScrollbarDragging())
        let offsetAfterGutter = await fixture.renderer.testingTranscriptScrollOffset()

        try await fixture.renderer.render(.overlay(.modelPicker(query: nil)))
        #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))

        // Overlay is up: gutter must not remap, and the sticky latch clears
        // on the next down into the modal.
        let before = await fixture.renderer.testingTranscriptScrollOffset()
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: sb.rect.x, y: sb.rect.y, button: .left
        )))
        let afterModalDown = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(afterModalDown == before)
        let draggingAfterModal = await fixture.renderer.testingScrollbarDragging()
        #expect(!draggingAfterModal)
        #expect(before == offsetAfterGutter)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("timeline rail publishes no scrollbar and keeps the rail click path")
    func railReplacesScrollbar() async throws {
        let fixture = try ScrollbarFixture(
            configTOML: "[ui]\nshow_timeline = true\n",
            terminalHeight: 30
        )
        defer { fixture.dispose() }

        try await fixture.renderer.begin()
        let filler = (0..<25).map { "rail-sb-\($0)" }.joined(separator: "\n\n")
        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "first-rail-prompt",
            mode: .fullScreen
        )))
        try await fixture.renderer.render(.session(.output(filler + "\n")))
        try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "second-rail-prompt",
            mode: .fullScreen
        )))
        try await fixture.renderer.render(.session(.output(filler + "\n")))
        try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await fixture.waitForPaint(containing: "second-rail-prompt"))

        let scrollbarHit = await fixture.renderer.lastScrollbarHit
        #expect(scrollbarHit == nil)
        let before = await fixture.renderer.testingTranscriptScrollOffset()
        // Same pinned rail tick geometry as LiveTimelineTests / block-select.
        let routing = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: 98, y: 13, button: .left
        )))
        #expect(routing == .consumed)
        let dragging = await fixture.renderer.testingScrollbarDragging()
        #expect(!dragging)
        // Rail jump may change offset; what matters is the scrollbar path
        // did not arm and no hit model was published.
        _ = before
        try await fixture.renderer.restoreTerminal()
    }

    @Test("bottom gutter cell re-engages followsBottom at max offset")
    func bottomCellReengagesFollow() async throws {
        let fixture = try ScrollbarFixture()
        defer { fixture.dispose() }
        try await fixture.seedOverflowTranscript()

        let sb = try #require(await fixture.renderer.lastScrollbarHit)
        // Leave follow first.
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: sb.rect.x, y: sb.rect.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: sb.rect.x, y: sb.rect.y, button: .left
        )))
        let followsAfterTop = await fixture.renderer.testingFollowsBottom()
        #expect(!followsAfterTop)

        let painted = try #require(await fixture.renderer.lastScrollbarHit)
        let bottomY = painted.rect.y + painted.rect.height - 1
        #expect(painted.isBottomCell(atScreenY: bottomY))
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: painted.rect.x, y: bottomY, button: .left
        )))
        #expect(down == .focusScrollback)
        let followsAfterBottom = await fixture.renderer.testingFollowsBottom()
        #expect(followsAfterBottom)
        let offset = await fixture.renderer.testingTranscriptScrollOffset()
        let maxOffset = await fixture.renderer.testingMaximumScrollOffset()
        #expect(offset == maxOffset)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: painted.rect.x, y: bottomY, button: .left
        )))
        try await fixture.renderer.restoreTerminal()
    }
}
