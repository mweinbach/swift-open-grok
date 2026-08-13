// LiveTranscriptTextSelectionTests.swift
//
// Live-seam proofs for linear transcript text drag + word_select multi-click
// against last-painted `PagerTextSelectionModel` (AGENTS.md §3). Table grids
// degrade to linear; sticky-header drag-start stays excluded; PromptEditor
// drag-to-select remains deferred.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class TextSelectCapturingSink: PagerTerminalSink, @unchecked Sendable {
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

    /// Strip CSI / OSC envelopes for paint waits.
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

    /// Decode the most recent OSC 52 payload (`\e]52;c;<base64>\a`), or `nil`.
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

/// Mutable tty size box so mid-drag resize tests can shrink wrap width.
private final class TextSelectSizeBox: @unchecked Sendable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

private struct TextSelectFixture {
    let home: URL
    let projectRoot: URL
    let sink: TextSelectCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let sizeBox: TextSelectSizeBox
    var terminalHeight: Int { sizeBox.height }
    var terminalWidth: Int { sizeBox.width }

    init(
        configTOML: String? = nil,
        projectConfigTOML: String? = nil,
        terminalHeight: Int = 36,
        terminalWidth: Int = 100,
        paintCadence: TimeInterval = PagerMotion.minimumPaintCadence
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-text-select-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        if let projectConfigTOML {
            let opengrok = projectRoot.appendingPathComponent(".opengrok", isDirectory: true)
            try FileManager.default.createDirectory(at: opengrok, withIntermediateDirectories: true)
            try projectConfigTOML.write(
                to: opengrok.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        // Resolve against the project cwd whenever a project config is planted
        // so authority merge includes `.opengrok/config.toml`.
        let cwd = projectConfigTOML == nil ? home : projectRoot
        sizeBox = TextSelectSizeBox(width: terminalWidth, height: terminalHeight)
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = TextSelectCapturingSink()
        let box = sizeBox
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: box.width, height: box.height) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: cwd.path,
            modelName: "alpha-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "alpha-model", providerID: "xai", name: "alpha-model"),
            ],
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: cwd,
                environment: environment
            ),
            sessionID: "text-select",
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
        // Resize can leave a coalesced frame; flush so lastTextSelection matches.
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

    func seedMultilineAssistant() async throws {
        try await renderer.begin()
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "text-select-user-prompt-unique",
            mode: .fullScreen
        )))
        try await renderer.render(.session(.output(
            "alpha-line-one-unique-token\n"
                + "beta-line-two-unique-token https://example.com/path\n"
                + "gamma-line-three-ユニコード-token\n"
        )))
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await waitForPaint(containing: "alpha-line-one-unique-token"))
        #expect(await waitForPaint(containing: "gamma-line-three"))
    }
}

/// Display-column range of `needle` inside `text` (Unicode width of the
/// prefix … needle), or `nil` when absent / zero-width.
private func needleDisplayCols(in text: String, needle: String) -> Range<Int>? {
    guard let range = text.range(of: needle) else { return nil }
    let prefix = String(text[..<range.lowerBound])
    let start = UnicodeDisplayWidth.width(of: prefix)
    let width = UnicodeDisplayWidth.width(of: needle)
    guard width > 0 else { return nil }
    return start..<(start + width)
}

/// First on-screen selectable cell on a line containing `needle`.
/// `colOffset` is relative to the needle's display-column start (not the
/// line start), then clamped to the needle span and the line's selectable
/// width so URL / mid-line / Unicode needles land on real model hits.
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
            let hit = PagerTextRangeHit(
                entryIndex: range.entryIndex,
                rangeID: range.rangeID,
                blockLineIndex: line.blockLineIndex,
                colWithinRange: colWithin
            )
            return (x, screenY, hit)
        }
    }
    return nil
}

/// Last display cell of `needle` on an on-screen selectable line — use when
/// a drag/copy assertion needs the full token (beta / URL / Unicode).
private func textPointEnd(
    in model: PagerTextSelectionModel,
    containing needle: String
) -> (x: Int, y: Int, hit: PagerTextRangeHit)? {
    for range in model.ranges {
        for line in range.lines {
            guard let screenY = line.screenY,
                  let needleCols = needleDisplayCols(in: line.text, needle: needle)
            else { continue }
            let lineWidth = line.selectableCols.upperBound - line.selectableCols.lowerBound
            guard lineWidth > 0 else { continue }
            let colWithin = min(needleCols.upperBound - 1, lineWidth - 1)
            let x = line.screenX + line.selectableCols.lowerBound + colWithin
            let hit = PagerTextRangeHit(
                entryIndex: range.entryIndex,
                rangeID: range.rangeID,
                blockLineIndex: line.blockLineIndex,
                colWithinRange: colWithin
            )
            return (x, screenY, hit)
        }
    }
    return nil
}

/// First on-screen selectable line cell from the live model (any range).
private func anyVisibleTextPoint(
    in model: PagerTextSelectionModel
) -> (x: Int, y: Int, hit: PagerTextRangeHit)? {
    for range in model.ranges {
        for line in range.lines {
            guard let screenY = line.screenY else { continue }
            let lineWidth = line.selectableCols.upperBound - line.selectableCols.lowerBound
            guard lineWidth > 0 else { continue }
            let colWithin = 0
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

/// Attempt a forced flush at `flushAt`. Accept `false` when the wall timer
/// already painted so `lastConversationHit.scrollOffset` matches live — assert
/// the synchronized postcondition, not which painter won. Fail when neither
/// force nor timer left the cache current.
private func ensurePaintedScrollCacheSynced(
    _ renderer: LiveInteractiveControllerRenderer,
    at flushAt: TimeInterval
) async throws {
    let didPaint = await renderer.testingFlushPendingFrame(at: flushAt)
    let live = await renderer.testingTranscriptScrollOffset()
    let painted = try #require(await renderer.lastConversationHit).scrollOffset
    #expect(
        painted == live,
        didPaint
            ? "forced flush painted but scrollOffset \(painted) != live \(live)"
            : "forced flush returned false and painted scrollOffset \(painted) != live \(live)"
    )
}

/// Drag-select a short span of `alpha-line-one` (hold/flash lifetime proofs).
private func dragSelectAlphaSpan(on fixture: TextSelectFixture) async throws {
    let model = try #require(await fixture.renderer.testingLastTextSelection())
    let start = try #require(textPoint(in: model, containing: "alpha-line-one", colOffset: 0))
    let end = try #require(textPoint(in: model, containing: "alpha-line-one", colOffset: 6))
    _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
        kind: .down, x: start.x, y: start.y, button: .left
    )))
    _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
        kind: .drag, x: end.x, y: end.y, button: .left
    )))
    _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
        kind: .up, x: end.x, y: end.y, button: .left
    )))
}

/// A conversation-band cell with no selectable text on that row (gap / chrome
/// row) — arms `deferredTextPress` for chrome→text conversion proofs.
private func deferredPressPoint(
    conversation: PagerConversationHitModel,
    text: PagerTextSelectionModel
) -> (x: Int, y: Int)? {
    let area = conversation.conversation
    guard area.height > 0 else { return nil }
    let x = area.x + PagerLayoutMetrics.chromeWidth + 2
    for row in area.y..<(area.y + area.height) {
        guard conversation.containsSelectablePoint(x: x, y: row) else { continue }
        if text.hitTestSelectableRange(col: x, row: row) == nil {
            return (x, row)
        }
    }
    return nil
}

@Suite("Live transcript text selection", .serialized)
struct LiveTranscriptTextSelectionTests {
    @Test("drag ≥1 copies exact multiline OSC52 payload and sets highlight")
    func dragCopiesMultilineAndHighlights() async throws {
        let fixture = try TextSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "alpha-line-one-unique-token"))
        let end = try #require(textPointEnd(in: model, containing: "beta-line-two-unique-token"))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        #expect(await fixture.renderer.testingPendingTextDrag() != nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        #expect(await fixture.renderer.testingActiveTextDrag() != nil)
        #expect(await fixture.renderer.testingPendingTextDrag() == nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(up == .focusScrollback)
        let payload = try #require(fixture.sink.lastOSC52Payload())
        #expect(payload.contains("alpha-line-one-unique-token"))
        #expect(payload.contains("beta-line-two-unique-token"))
        let persistent = try #require(await fixture.renderer.testingPersistentTextSelection())
        #expect(persistent.origin == .drag)
        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("no-drag down+up keeps block select unchanged")
    func noDragBlockSelectUnchanged() async throws {
        let fixture = try TextSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()
        await fixture.renderer.testingSetKeepTextSelectionMode(.flash)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let point = try #require(textPoint(in: model, containing: "alpha-line-one", colOffset: 2))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: point.x, y: point.y, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)
        #expect(fixture.sink.lastOSC52Payload() == nil)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() != nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("chrome/gap press then drag into text converts to text drag")
    func chromeToTextConversion() async throws {
        let fixture = try TextSelectFixture(terminalHeight: 48)
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()
        // Second turn so an inter-block gap exists inside the band.
        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "second-user-for-gap",
            mode: .fullScreen
        )))
        try await fixture.renderer.render(.session(.output("second-assistant-reply\n")))
        try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await fixture.waitForPaint(containing: "second-assistant-reply"))

        let conversation = try #require(await fixture.renderer.lastConversationHit)
        let textModel = try #require(await fixture.renderer.testingLastTextSelection())
        let deferred = try #require(deferredPressPoint(conversation: conversation, text: textModel))
        // Prefer a still-visible late line after the second turn (follow-tail);
        // needle-relative offset keeps the hit inside the token.
        let target = try #require(
            textPoint(in: textModel, containing: "second-assistant-reply", colOffset: 3)
                ?? textPoint(in: textModel, containing: "alpha-line-one-unique-token", colOffset: 3)
        )

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: deferred.x, y: deferred.y, button: .left
        )))
        #expect(await fixture.renderer.testingDeferredTextPress() != nil)
        #expect(await fixture.renderer.testingPendingTextDrag() == nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: target.x, y: target.y, button: .left
        )))
        #expect(await fixture.renderer.testingActiveTextDrag() != nil)
        #expect(await fixture.renderer.testingDeferredTextPress() == nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: target.x, y: target.y, button: .left
        )))
        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("link / scrollbar / composer / modal priorities beat text arming")
    func prioritiesBeatTextArming() async throws {
        let fixture = try TextSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()

        // Capturing modal.
        try await fixture.renderer.render(.overlay(.modelPicker(query: nil)))
        #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))
        let focusedID = try #require(await fixture.renderer.testingFocusedOverlayID())
        let focused = try #require(
            await fixture.renderer.lastOverlayBounds.last(where: { $0.id == focusedID })
        )
        let mx = focused.frame.x + max(1, focused.frame.width / 2)
        let my = focused.frame.y + max(1, focused.frame.height / 2)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: mx, y: my, button: .left
        )))
        #expect(await fixture.renderer.testingPendingTextDrag() == nil)
        // Dismiss via Esc path on overlay — push a key through renderer.
        _ = try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape)))

        // Composer pane.
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let cx = composer.pane.x + 2
        let cy = composer.pane.y + min(1, max(0, composer.pane.height - 1))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: cx, y: cy, button: .left
        )))
        #expect(await fixture.renderer.testingPendingTextDrag() == nil)

        // Scrollbar gutter when present.
        if let sb = await fixture.renderer.lastScrollbarHit {
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .down, x: sb.rect.x, y: sb.rect.y, button: .left
            )))
            #expect(await fixture.renderer.testingPendingTextDrag() == nil)
            #expect(await fixture.renderer.testingScrollbarDragging())
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .up, x: sb.rect.x, y: sb.rect.y, button: .left
            )))
        }

        try await fixture.renderer.restoreTerminal()
    }

    @Test("X10-style up-none finishes an active text drag")
    func x10UpNoneFinishesTextDrag() async throws {
        let fixture = try TextSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "alpha-line-one-unique-token"))
        // End at the last cell of the full token so the claimed substring is covered.
        let end = try #require(textPointEnd(in: model, containing: "alpha-line-one-unique-token"))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .none
        )))
        #expect(up == .focusScrollback)
        let x10Payload = try #require(fixture.sink.lastOSC52Payload())
        #expect(x10Payload.contains("alpha-line-one-unique-token"))
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("word_select double URL, triple line; flash/hold keep block path")
    func wordSelectMultiClick() async throws {
        let fixture = try TextSelectFixture(
            configTOML: """
            [ui]
            keep_text_selection = "word_select"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .wordSelect)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        // Land inside the URL span (needle-relative col, not line start).
        let urlPoint = try #require(
            textPoint(in: model, containing: "https://example.com/path", colOffset: 2)
        )
        await fixture.renderer.testingSetTextSelectionNowMs(1_000)

        // Click 1 — block select.
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: urlPoint.x, y: urlPoint.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: urlPoint.x, y: urlPoint.y, button: .left
        )))
        #expect(await fixture.renderer.testingLastTextClick()?.clickCount == 1)

        // Click 2 — URL.
        await fixture.renderer.testingSetTextSelectionNowMs(1_100)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: urlPoint.x, y: urlPoint.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: urlPoint.x, y: urlPoint.y, button: .left
        )))
        let urlPayload = try #require(fixture.sink.lastOSC52Payload())
        #expect(urlPayload.contains("https://example.com/path"))
        #expect(await fixture.renderer.testingPersistentTextSelection()?.origin == .doubleClick)

        // Click 3 — full line.
        await fixture.renderer.testingSetTextSelectionNowMs(1_200)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: urlPoint.x, y: urlPoint.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: urlPoint.x, y: urlPoint.y, button: .left
        )))
        let linePayload = try #require(fixture.sink.lastOSC52Payload())
        #expect(linePayload.contains("beta-line-two-unique-token"))
        #expect(linePayload.contains("https://example.com/path"))
        #expect(await fixture.renderer.testingPersistentTextSelection()?.origin == .tripleClick)

        // flash/hold: double-click does not invent fold / word select.
        await fixture.renderer.testingSetKeepTextSelectionMode(.flash)
        await fixture.renderer.testingSetTextSelectionNowMs(nil)
        try await fixture.renderer.testingForceFlashExpiry()
        let flashModel = try #require(await fixture.renderer.testingLastTextSelection())
        let wordPoint = try #require(
            textPoint(in: flashModel, containing: "alpha-line-one", colOffset: 2)
        )
        await fixture.renderer.testingSetTextSelectionNowMs(2_000)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: wordPoint.x, y: wordPoint.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: wordPoint.x, y: wordPoint.y, button: .left
        )))
        await fixture.renderer.testingSetTextSelectionNowMs(2_100)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: wordPoint.x, y: wordPoint.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: wordPoint.x, y: wordPoint.y, button: .left
        )))
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("flash expires via injected seam; hold clears on Esc / new down")
    func flashAndHoldLifetime() async throws {
        let fixture = try TextSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "alpha-line-one", colOffset: 0))
        let end = try #require(textPoint(in: model, containing: "alpha-line-one", colOffset: 6))

        await fixture.renderer.testingSetKeepTextSelectionMode(.flash)
        await fixture.renderer.testingSetFlashSleepNanos(0)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        // Injected 0-ns flash Task + force seam.
        try await fixture.renderer.testingForceFlashExpiry()
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)

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
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)

        let esc = try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape)))
        #expect(esc == .consumed)
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)

        // Re-arm hold, then new left down clears.
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("project reset reloads keep_text_selection like scroll")
    func projectResetReloadsMode() async throws {
        let fixture = try TextSelectFixture(
            configTOML: """
            [ui]
            keep_text_selection = "hold"
            """
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .hold)

        await fixture.renderer.testingApplySetting(
            .commit(key: "keep_text_selection", value: .string("word_select"))
        )
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .wordSelect)

        await fixture.renderer.testingApplySetting(.resetRequested(key: "keep_text_selection"))
        // User-home leaf cleared (no project/managed layer in this fixture) →
        // effective resolve is the flash default — exact, not hold||flash.
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .flash)

        try await fixture.renderer.restoreTerminal()
    }

    @Test("commit flash atomically clears legacy word_select / duration 0")
    func commitFlashClearsLegacyKeys() async throws {
        let fixture = try TextSelectFixture(
            configTOML: """
            [ui]
            double_click_action = "word_select"
            selection_highlight_duration_ms = 0
            """
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        // Legacy precedence: word_select wins over duration 0 → hold.
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .wordSelect)

        await fixture.renderer.testingApplySetting(
            .commit(key: "keep_text_selection", value: .string("flash"))
        )
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .flash)

        let text = try String(
            contentsOf: fixture.home.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        #expect(text.contains("keep_text_selection = \"flash\""))
        #expect(!text.contains("double_click_action"))
        #expect(!text.contains("selection_highlight_duration_ms"))

        // Reset must not resurrect legacy → flash default.
        await fixture.renderer.testingApplySetting(.resetRequested(key: "keep_text_selection"))
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .flash)
        let afterReset = try String(
            contentsOf: fixture.home.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        #expect(!afterReset.contains("double_click_action"))
        #expect(!afterReset.contains("selection_highlight_duration_ms"))
        #expect(!afterReset.contains("keep_text_selection"))

        try await fixture.renderer.restoreTerminal()
    }

    @Test("flash deadline survives suspend; resume clears or re-arms")
    func flashDeadlineAcrossSuspend() async throws {
        let fixture = try TextSelectFixture()
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: model, containing: "alpha-line-one", colOffset: 0))
        let end = try #require(textPoint(in: model, containing: "alpha-line-one", colOffset: 6))

        await fixture.renderer.testingSetKeepTextSelectionMode(.flash)
        await fixture.renderer.testingSetFlashSleepNanos(0)
        await fixture.renderer.testingSetTextSelectionNowMs(1_000)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        let deadline = try #require(await fixture.renderer.testingTextSelectionFlashDeadlineMs())
        #expect(deadline == 1_000 + pagerTextSelectionFlashTTLMs)

        // Suspend before expiry: task cancelled, highlight + deadline retained.
        await fixture.renderer.testingSuspendTextSelectionFlash()
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        #expect(await fixture.renderer.testingTextSelectionFlashDeadlineMs() == deadline)

        // Advance past deadline → resume clears.
        await fixture.renderer.testingSetTextSelectionNowMs(deadline + 1)
        try await fixture.renderer.testingResumeTextSelectionFlash()
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)
        #expect(await fixture.renderer.testingTextSelectionFlashDeadlineMs() == nil)

        // Re-arm: suspend, resume before expiry, then advance + reconcile.
        await fixture.renderer.testingSetTextSelectionNowMs(2_000)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        let deadline2 = try #require(await fixture.renderer.testingTextSelectionFlashDeadlineMs())
        await fixture.renderer.testingSuspendTextSelectionFlash()
        await fixture.renderer.testingSetTextSelectionNowMs(deadline2 - 10)
        try await fixture.renderer.testingResumeTextSelectionFlash()
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        #expect(await fixture.renderer.testingTextSelectionFlashDeadlineMs() == deadline2)

        await fixture.renderer.testingSetTextSelectionNowMs(deadline2 + 1)
        try await fixture.renderer.testingReconcileTextSelectionFlashDeadline()
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("resize mid-drag keeps OSC52 against frozen wrap width")
    func resizeMidDragFrozenCopy() async throws {
        let fixture = try TextSelectFixture(terminalWidth: 100)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        let lineA = "REFLOW-AAA-UNIQUE " + String(repeating: "wrap-token ", count: 24)
        let lineB = "REFLOW-BBB-UNIQUE " + String(repeating: "wrap-token ", count: 24)
        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "reflow-user-prompt",
            mode: .fullScreen
        )))
        try await fixture.renderer.render(.session(.output(lineA + "\n" + lineB + "\n")))
        try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await fixture.waitForPaint(containing: "REFLOW-AAA-UNIQUE"))
        await fixture.renderer.testingSetKeepTextSelectionMode(.hold)

        let before = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(textPoint(in: before, containing: "REFLOW-AAA-UNIQUE"))
        let end = try #require(textPointEnd(in: before, containing: "REFLOW-BBB-UNIQUE"))
        let expected = try #require(pagerReconstructSelectionText(
            model: before,
            drag: PagerActiveTextDrag(anchor: start.hit, head: end.hit, kind: .linear)
        ))
        #expect(expected.contains("REFLOW-AAA-UNIQUE"))
        #expect(expected.contains("REFLOW-BBB-UNIQUE"))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: end.x, y: end.y, button: .left
        )))
        #expect(await fixture.renderer.testingActiveTextDrag() != nil)
        #expect(await fixture.renderer.testingFrozenDragTextSelection() != nil)
        let frozenWidth = await fixture.renderer.testingActiveTextDrag()?.anchorContentWidth
        #expect(frozenWidth != nil)

        // Shrink wrap mid-drag — live model reflows; copy must stay frozen.
        try await fixture.resize(width: 40)
        let after = try #require(await fixture.renderer.testingLastTextSelection())
        #expect(after != before)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: end.x, y: end.y, button: .left
        )))
        let payload = try #require(fixture.sink.lastOSC52Payload())
        #expect(payload == expected)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("autoscroll tick reclamps head against action-time model under paint coalesce")
    func autoscrollActionTimeReclampUnderCoalesce() async throws {
        // Long paint cadence so the post-scroll renderState coalesces;
        // force paints via a synthetic monotonic clock. Under suite load the
        // wall flush timer can win the race — accept that when the painted
        // scroll cache is already synchronized with live.
        let paintCadence: TimeInterval = 5.0
        let fixture = try TextSelectFixture(
            terminalHeight: 24,
            paintCadence: paintCadence
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        for turn in 0..<12 {
            let prompt = "as-user-\(turn) "
                + String(repeating: "prompt-wrap-\(turn) ", count: 24)
            let reply = "as-assistant-\(turn) "
                + String(repeating: "reply-wrap-\(turn) ", count: 32)
            try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: prompt,
                mode: .fullScreen
            )))
            try await fixture.renderer.render(.session(.output(reply + "\n")))
            try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))
        }
        // Synthetic paint clock: each forced flush advances by cadence+1 so
        // FrameClock lastPaintAt + cadence is satisfied when the force path wins.
        var flushAt = await fixture.renderer.testingMonotonicNow() + paintCadence + 1
        try await ensurePaintedScrollCacheSynced(fixture.renderer, at: flushAt)
        flushAt += paintCadence + 1
        let maxAfterSeed = await fixture.renderer.testingMaximumScrollOffset()
        let viewport = await fixture.renderer.lastConversationHit?.conversation.height ?? 1
        #expect(maxAfterSeed > viewport)

        try await fixture.renderer.render(.viewport(.bottom))
        try await ensurePaintedScrollCacheSynced(fixture.renderer, at: flushAt)
        flushAt += paintCadence + 1
        let settleDeadline = Date().addingTimeInterval(5)
        while Date() < settleDeadline {
            let follows = await fixture.renderer.testingFollowsBottom()
            let offset = await fixture.renderer.testingTranscriptScrollOffset()
            let maxOff = await fixture.renderer.testingMaximumScrollOffset()
            if follows, offset == maxOff, offset > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await fixture.renderer.testingTranscriptScrollOffset() > 0)

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        let start = try #require(anyVisibleTextPoint(in: model))
        let edgeY = model.conversationArea.y

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: start.x, y: start.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: start.x, y: edgeY, button: .left
        )))
        #expect(await fixture.renderer.testingActiveTextDrag() != nil)
        #expect(await fixture.renderer.testingDragAutoscroll()?.direction == .up)

        // Baseline: painted cache synchronized with live (force or timer).
        try await ensurePaintedScrollCacheSynced(fixture.renderer, at: flushAt)
        flushAt += paintCadence + 1

        let paintedHitBefore = try #require(await fixture.renderer.lastConversationHit)
        let preScrollPaintedOffset = paintedHitBefore.scrollOffset
        let liveOffsetBefore = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(preScrollPaintedOffset == liveOffsetBefore)
        #expect(preScrollPaintedOffset > 0)
        let pointer = try #require(await fixture.renderer.testingLastDragPointer())
        let deadline = await fixture.renderer.testingScrollClockDeadline(at: 0)
        #expect(deadline == 0.016)

        _ = try await fixture.renderer.testingHandleScrollClockTick(at: 0)
        let liveOffsetAfter = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(liveOffsetAfter < liveOffsetBefore)

        // Immediately after the tick: either coalesce left the painted cache
        // stale, or the wall timer already painted the new offset.
        let paintedHitAfterTick = try #require(await fixture.renderer.lastConversationHit)
        let coalescedStale =
            paintedHitAfterTick.scrollOffset == preScrollPaintedOffset
            && paintedHitAfterTick.scrollOffset != liveOffsetAfter
        let timerAlreadyCurrent = paintedHitAfterTick.scrollOffset == liveOffsetAfter
        #expect(
            coalescedStale || timerAlreadyCurrent,
            "after autoscroll tick: painted \(paintedHitAfterTick.scrollOffset) neither stale \(preScrollPaintedOffset) nor live \(liveOffsetAfter)"
        )

        // Action-time head uses the current (scrolled) model via stable
        // joined-text identity — required on both coalesce and timer paths.
        let action = try #require(await fixture.renderer.testingActionTimeTextSelection())
        let drag = try #require(await fixture.renderer.testingActiveTextDrag())
        let frozen = try #require(await fixture.renderer.testingFrozenDragTextSelection())
        let liveAnchor = pagerMapTextHit(drag.anchor, from: frozen, to: action) ?? drag.anchor
        let intendedLive = try #require(action.hitTestNearestInRange(
            anchor: liveAnchor, col: pointer.col, row: pointer.row
        ))
        let intendedFrozen = try #require(pagerMapTextHit(intendedLive, from: action, to: frozen))
        let headOffset = try #require(pagerAbsoluteTextUTF8Offset(in: frozen, hit: drag.head))
        let intendedOffset = try #require(
            pagerAbsoluteTextUTF8Offset(in: frozen, hit: intendedFrozen)
        )
        #expect(headOffset == intendedOffset)
        let headInAction = try #require(pagerMapTextHit(drag.head, from: frozen, to: action))
        #expect(action.line(for: headInAction) != nil)

        let expectedCopy = try #require(
            pagerReconstructSelectionText(model: frozen, drag: drag)
        )
        #expect(!expectedCopy.isEmpty)

        // Final sync: cache must match live scrolled offset (who painted is irrelevant).
        try await ensurePaintedScrollCacheSynced(fixture.renderer, at: flushAt)
        let paintedHitAfterFlush = try #require(await fixture.renderer.lastConversationHit)
        let liveOffsetAfterFlush = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(paintedHitAfterFlush.scrollOffset == liveOffsetAfterFlush)
        #expect(paintedHitAfterFlush.scrollOffset != preScrollPaintedOffset)

        let paintedAfterFlush = try #require(await fixture.renderer.testingLastTextSelection())
        let headInPainted = try #require(
            pagerMapTextHit(drag.head, from: frozen, to: paintedAfterFlush)
        )
        #expect(paintedAfterFlush.line(for: headInPainted) != nil)
        let headOffsetInPainted = try #require(
            pagerAbsoluteTextUTF8Offset(in: paintedAfterFlush, hit: headInPainted)
        )
        #expect(headOffsetInPainted == headOffset)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: pointer.col, y: pointer.row, button: .left
        )))
        #expect(up == .focusScrollback || up == .consumed)
        let payload = try #require(fixture.sink.lastOSC52Payload())
        #expect(payload == expectedCopy)
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("reset hold→default flash clears expired highlight")
    func resetHoldToDefaultFlashExpired() async throws {
        let fixture = try TextSelectFixture(
            configTOML: """
            [ui]
            keep_text_selection = "hold"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .hold)

        await fixture.renderer.testingSetTextSelectionNowMs(1_000)
        try await dragSelectAlphaSpan(on: fixture)
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        #expect(await fixture.renderer.testingTextSelectionCreatedAtMs() == 1_000)
        #expect(await fixture.renderer.testingTextSelectionFlashDeadlineMs() == nil)

        await fixture.renderer.testingSetTextSelectionNowMs(
            1_000 + pagerTextSelectionFlashTTLMs
        )
        await fixture.renderer.testingApplySetting(.resetRequested(key: "keep_text_selection"))
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .flash)
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)
        #expect(await fixture.renderer.testingTextSelectionFlashDeadlineMs() == nil)
        #expect(await fixture.renderer.testingTextSelectionCreatedAtMs() == nil)

        try await fixture.renderer.restoreTerminal()
    }

    @Test("reset hold→default flash arms remaining TTL when unexpired")
    func resetHoldToDefaultFlashUnexpired() async throws {
        let fixture = try TextSelectFixture(
            configTOML: """
            [ui]
            keep_text_selection = "hold"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()

        await fixture.renderer.testingSetTextSelectionNowMs(1_000)
        await fixture.renderer.testingSetFlashSleepNanos(0)
        try await dragSelectAlphaSpan(on: fixture)
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)

        await fixture.renderer.testingSetTextSelectionNowMs(1_100)
        await fixture.renderer.testingApplySetting(.resetRequested(key: "keep_text_selection"))
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .flash)
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        #expect(
            await fixture.renderer.testingTextSelectionFlashDeadlineMs()
                == 1_000 + pagerTextSelectionFlashTTLMs
        )

        await fixture.renderer.testingSetTextSelectionNowMs(
            1_000 + pagerTextSelectionFlashTTLMs + 1
        )
        try await fixture.renderer.testingReconcileTextSelectionFlashDeadline()
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("reset hold→project flash clears expired highlight")
    func resetHoldToProjectFlashExpired() async throws {
        let fixture = try TextSelectFixture(
            projectConfigTOML: """
            [ui]
            keep_text_selection = "flash"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()
        // Project layer is flash at cold start; commit hold into the user file.
        await fixture.renderer.testingApplySetting(
            .commit(key: "keep_text_selection", value: .string("hold"))
        )
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .hold)

        await fixture.renderer.testingSetTextSelectionNowMs(2_000)
        try await dragSelectAlphaSpan(on: fixture)
        #expect(await fixture.renderer.testingTextSelectionFlashDeadlineMs() == nil)

        await fixture.renderer.testingSetTextSelectionNowMs(
            2_000 + pagerTextSelectionFlashTTLMs
        )
        await fixture.renderer.testingApplySetting(.resetRequested(key: "keep_text_selection"))
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .flash)
        #expect(await fixture.renderer.testingPersistentTextSelection() == nil)

        try await fixture.renderer.restoreTerminal()
    }

    @Test("reset hold→project flash arms remaining TTL when unexpired")
    func resetHoldToProjectFlashUnexpired() async throws {
        let fixture = try TextSelectFixture(
            projectConfigTOML: """
            [ui]
            keep_text_selection = "flash"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()
        await fixture.renderer.testingApplySetting(
            .commit(key: "keep_text_selection", value: .string("hold"))
        )
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .hold)

        await fixture.renderer.testingSetTextSelectionNowMs(3_000)
        await fixture.renderer.testingSetFlashSleepNanos(0)
        try await dragSelectAlphaSpan(on: fixture)

        await fixture.renderer.testingSetTextSelectionNowMs(3_050)
        await fixture.renderer.testingApplySetting(.resetRequested(key: "keep_text_selection"))
        #expect(await fixture.renderer.testingKeepTextSelectionMode() == .flash)
        #expect(await fixture.renderer.testingPersistentTextSelection() != nil)
        #expect(
            await fixture.renderer.testingTextSelectionFlashDeadlineMs()
                == 3_000 + pagerTextSelectionFlashTTLMs
        )

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("sticky header rows are not text-selectable; Unicode reconstructs")
    func stickyExcludedAndUnicode() async throws {
        let fixture = try TextSelectFixture(
            configTOML: """
            [ui]
            show_timeline = false
            keep_text_selection = "hold"
            """
        )
        defer { fixture.dispose() }
        try await fixture.seedMultilineAssistant()

        let model = try #require(await fixture.renderer.testingLastTextSelection())
        // Sticky band (if any) sits above contentArea.y — exact hits reject.
        if model.contentArea.height > 0, model.contentArea.y > model.conversationArea.y {
            let stickyY = model.conversationArea.y
            let x = model.contentArea.x + 2
            #expect(model.hitTestTextExact(col: x, row: stickyY) == nil)
            #expect(model.hitTestSelectableRange(col: x, row: stickyY) == nil)
        }

        let uni = try #require(textPoint(in: model, containing: "ユニコード"))
        let uniEnd = try #require(textPointEnd(in: model, containing: "ユニコード"))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: uni.x, y: uni.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: uniEnd.x, y: uniEnd.y, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: uniEnd.x, y: uniEnd.y, button: .left
        )))
        let payload = try #require(fixture.sink.lastOSC52Payload())
        #expect(payload.contains("ユニコード"))

        await fixture.renderer.testingAwaitTextSelectionFlashCleanup()
        try await fixture.renderer.restoreTerminal()
    }
}
