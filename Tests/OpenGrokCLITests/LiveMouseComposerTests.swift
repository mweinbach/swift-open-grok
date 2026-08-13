// LiveMouseComposerTests.swift
//
// Composer mouse against REAL last-painted `PagerComposerHitModel`
// (AGENTS.md §3): chrome returns `.focusComposer`; content arms a
// prompt-owned gesture and returns `.composerMouse` with the last-painted
// content rect. Capturing modals block; transcript click still
// `.focusScrollback`. Wheel over composer never scrolls the transcript.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class ComposerCapturingSink: PagerTerminalSink, @unchecked Sendable {
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

private struct ComposerMouseFixture {
    let home: URL
    let sink: ComposerCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let terminalHeight: Int
    let terminalWidth: Int

    init(
        terminalHeight: Int = 30,
        terminalWidth: Int = 100,
        paintCadence: TimeInterval = PagerMotion.minimumPaintCadence
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-composer-mouse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        self.terminalHeight = terminalHeight
        self.terminalWidth = terminalWidth
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = ComposerCapturingSink()
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
            sessionID: "composer-mouse",
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

    func seedTranscriptAndDraft(_ draft: String = "hello-composer-draft") async throws {
        try await renderer.begin()
        try await renderer.testingDismissWelcomeOverlay()
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "alpha-composer-unique-token",
            mode: .fullScreen
        )))
        try await renderer.render(.session(.output("alpha-reply-composer-unique\n")))
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await waitForPaint(containing: "alpha-composer-unique-token"))
        try await renderer.render(.promptChanged(OpenGrokPagerInteractivePromptState(
            text: draft,
            cursorOffset: draft.count
        )))
        // Wait until the painted hit model carries the draft.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let hit = await renderer.lastComposerHit, hit.lines.contains(where: { $0.text.contains("hello") || draft.isEmpty }) {
                return
            }
            if draft.isEmpty, await renderer.lastComposerHit != nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await renderer.lastComposerHit != nil)
    }

    func selectScrollbackBlock() async throws {
        let model = try #require(await renderer.lastConversationHit)
        #expect(!model.blockStartLines.isEmpty)
        let target = 0
        let contentY = model.blockStartLines[target]
        let screenY = model.conversation.y + contentY - model.scrollOffset
        let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2
        let down = try await renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: screenY, button: .left
        )))
        #expect(down == .consumed)
        let up = try await renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: screenY, button: .left
        )))
        #expect(up == .focusScrollback)
        try await renderer.render(.focusChanged(.scrollback))
        #expect(await renderer.testingScrollbackSelectedIndex() != nil)
    }
}

@Suite("Live mouse composer focus", .serialized)
struct LiveMouseComposerTests {
    @Test("scrollback-focused composer pane click returns focusComposer and clears selection")
    func composerClickFocusesAndClearsSelection() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft("hello-composer-draft")
        try await fixture.selectScrollbackBlock()
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() != nil)

        let composer = try #require(await fixture.renderer.lastComposerHit)
        // Border / prefix → focus only (nil cursor).
        let borderX = composer.pane.x
        let borderY = composer.textArea.y
        let borderRoute = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: borderX, y: borderY, button: .left
        )))
        #expect(borderRoute == .focusComposer)
        #expect(await fixture.renderer.testingComposerGestureArmed() == false)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)

        // Chrome click unfocused the scrollback; last-painted composer
        // geometry updates on the real paint, not a coalesced request.
        let focusedDeadline = Date().addingTimeInterval(5)
        var refreshed: PagerComposerHitModel?
        while Date() < focusedDeadline {
            if let hit = await fixture.renderer.lastComposerHit, hit.isFocused {
                refreshed = hit
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let focused = try #require(refreshed)
        let contentX = focused.textArea.x + focused.prefixWidth + 2
        let contentY = focused.textArea.y
        #expect(focused.hit(x: contentX, y: contentY) == .content)
        let textRoute = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: contentX, y: contentY, button: .left
        )))
        guard case .composerMouse(let claim) = textRoute else {
            Issue.record("expected composerMouse, got \(textRoute)")
            return
        }
        #expect(claim.event.kind == .down)
        #expect(claim.content == focused.contentRect)
        #expect(await fixture.renderer.testingComposerGestureArmed())
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: contentX, y: contentY, button: .left
        )))
        guard case .composerMouse(let upClaim) = up else {
            Issue.record("expected composerMouse up, got \(up)")
            return
        }
        #expect(upClaim.event.kind == .up)
        #expect(await fixture.renderer.testingComposerGestureArmed() == false)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("capturing modal blocks composer focus")
    func capturingModalBlocksComposer() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        try await fixture.renderer.render(.overlay(.modelPicker(query: nil)))
        #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))

        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let routing = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        if case .focusComposer = routing {
            Issue.record("composer must not focus under a capturing modal")
        }
        if case .composerMouse = routing {
            Issue.record("composer must not receive mouse under a capturing modal")
        }
        try await fixture.renderer.restoreTerminal()
    }

    @Test("transcript content click still returns focusScrollback")
    func transcriptClickStillFocusesScrollback() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()

        let model = try #require(await fixture.renderer.lastConversationHit)
        let contentY = model.blockStartLines[0]
        let screenY = model.conversation.y + contentY - model.scrollOffset
        let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: screenY, button: .left
        )))
        #expect(down == .consumed)
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: screenY, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == 0)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("composer left-down clears pending link and block latches")
    func composerDownClearsPendingLatches() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()

        let model = try #require(await fixture.renderer.lastConversationHit)
        let contentY = model.blockStartLines[0]
        let screenY = model.conversation.y + contentY - model.scrollOffset
        let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2
        let blockDown = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: screenY, button: .left
        )))
        #expect(blockDown == .consumed)
        // Pending block armed; composer down must clear it without selecting.
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let cx = composer.textArea.x + composer.prefixWidth
        let cy = composer.textArea.y
        let route = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: cx, y: cy, button: .left
        )))
        guard case .composerMouse = route else {
            Issue.record("expected composerMouse, got \(route)")
            return
        }
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: screenY, button: .left
        )))
        guard case .composerMouse(let upClaim) = up else {
            Issue.record("prompt-owned up outside pane must still forward, got \(up)")
            return
        }
        #expect(upClaim.event.kind == .up)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("wheel over composer is composerMouse, not transcript scroll")
    func wheelOverComposerDoesNotScrollTranscript() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        let before = try #require(await fixture.renderer.lastConversationHit).scrollOffset
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let route = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .scrollDown, x: x, y: y, button: .none
        )))
        guard case .composerMouse(let claim) = route else {
            Issue.record("expected composerMouse wheel, got \(route)")
            return
        }
        #expect(claim.event.kind == .scrollDown)
        let after = try #require(await fixture.renderer.lastConversationHit).scrollOffset
        #expect(after == before)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("X10 left-down on content is composerMouse; no synthesized drag")
    func x10DownDoesNotFakeDrag() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: 0
        )))
        guard case .composerMouse(let claim) = down else {
            Issue.record("expected composerMouse, got \(down)")
            return
        }
        #expect(claim.event.kind == .down)
        #expect(await fixture.renderer.testingComposerGestureArmed())
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: y, button: MouseEvent.noButton
        )))
        guard case .composerMouse(let upClaim) = up else {
            Issue.record("expected composerMouse X10 up, got \(up)")
            return
        }
        #expect(upClaim.event.kind == .up)
        #expect(upClaim.event.resolvedButton == .none)
        #expect(await fixture.renderer.testingComposerGestureArmed() == false)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("prompt-owned drag outside the pane still forwards")
    func dragOutsidePaneStillForwards() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        guard case .composerMouse = down else {
            Issue.record("expected composerMouse down, got \(down)")
            return
        }
        let outsideY = composer.pane.y - 2
        let drag = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: x, y: outsideY, button: .left
        )))
        guard case .composerMouse(let claim) = drag else {
            Issue.record("expected composerMouse drag outside pane, got \(drag)")
            return
        }
        #expect(claim.event.y == outsideY)
        #expect(claim.content == composer.contentRect)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("resize mid-drag publishes the newly painted content rect")
    func resizeMidDragUsesLastPaintedRect() async throws {
        let fixture = try ComposerMouseFixture(terminalHeight: 30, terminalWidth: 100)
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        guard case .composerMouse(let before) = down else {
            Issue.record("expected composerMouse, got \(down)")
            return
        }
        try await fixture.renderer.resize(to: TerminalSize(width: 80, height: 24))
        let deadline = Date().addingTimeInterval(5)
        var refreshed: PagerComposerHitModel?
        while Date() < deadline {
            if let hit = await fixture.renderer.lastComposerHit, hit.contentRect != before.content {
                refreshed = hit
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let painted = try #require(refreshed)
        let drag = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: painted.contentRect.x + 1, y: painted.contentRect.y, button: .left
        )))
        guard case .composerMouse(let after) = drag else {
            Issue.record("expected composerMouse after resize, got \(drag)")
            return
        }
        #expect(after.content == painted.contentRect)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("unfocused composer pane click is focus-only")
    func collapsedUnfocusedIsFocusOnly() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        try await fixture.selectScrollbackBlock()
        let composer = try #require(await fixture.renderer.lastComposerHit)
        #expect(composer.isFocused == false)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let route = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        #expect(route == .focusComposer)
        #expect(await fixture.renderer.testingComposerGestureArmed() == false)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("wheel over unfocused composer is composerMouse without focusComposer")
    func unfocusedWheelDoesNotFocusOrExpand() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        try await fixture.selectScrollbackBlock()
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() != nil)
        let composer = try #require(await fixture.renderer.lastComposerHit)
        #expect(composer.isFocused == false)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let route = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .scrollDown, x: x, y: y, button: .none
        )))
        guard case .composerMouse(let claim) = route else {
            Issue.record("unfocused wheel follows pin prompt.handle_mouse, got \(route)")
            return
        }
        #expect(claim.event.kind == .scrollDown)
        #expect(await fixture.renderer.testingComposerGestureArmed() == false)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() != nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("capturing overlay mid-gesture does not forward composerMouse")
    func overlayMidGestureDoesNotForward() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        guard case .composerMouse = down else {
            Issue.record("expected composerMouse down, got \(down)")
            return
        }
        try await fixture.renderer.render(.overlay(.modelPicker(query: nil)))
        #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))
        let drag = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: x, y: y - 2, button: .left
        )))
        if case .composerMouse = drag {
            Issue.record("overlay must not forward a prompt-owned drag")
        }
        #expect(await fixture.renderer.testingComposerGestureArmed() == false)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("prompt-owned up uses last known content rect when hit model is nil")
    func nilHitUpForwardsLastKnownRect() async throws {
        let fixture = try ComposerMouseFixture(terminalHeight: 30, terminalWidth: 100)
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        guard case .composerMouse(let before) = down else {
            Issue.record("expected composerMouse, got \(down)")
            return
        }
        try await fixture.renderer.resize(to: TerminalSize(width: 3, height: 10))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await fixture.renderer.lastComposerHit == nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await fixture.renderer.lastComposerHit == nil)
        let known = await fixture.renderer.lastComposerContentRect()
        #expect(known == before.content)
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: y, button: MouseEvent.noButton
        )))
        guard case .composerMouse(let claim) = up else {
            Issue.record("nil-hit up must still forward, got \(up)")
            return
        }
        #expect(claim.event.kind == .up)
        #expect(claim.content == before.content)
        #expect(await fixture.renderer.testingComposerGestureArmed() == false)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("restore clears toast occluder and composer gesture caches")
    func restoreClearsComposerCachesAndToastOccluder() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        try await fixture.renderer.testingShowTransientToast("Copied!")
        try await fixture.renderer.testingForcePaint()
        #expect(await fixture.renderer.testingLastToastOccluder() != nil)
        #expect(await fixture.renderer.lastComposerHit != nil)
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        guard case .composerMouse = down else {
            Issue.record("expected composerMouse, got \(down)")
            return
        }
        #expect(await fixture.renderer.testingComposerGestureArmed())
        try await fixture.renderer.restoreTerminal()
        #expect(await fixture.renderer.testingLastToastOccluder() == nil)
        #expect(await fixture.renderer.lastComposerHit == nil)
        #expect(await fixture.renderer.lastComposerContentRect() == nil)
        #expect(await fixture.renderer.testingComposerGestureArmed() == false)
    }

    @Test("composer left-down cancels residual MouseScrollState")
    func composerDownCancelsWheelResidual() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        await fixture.renderer.testingResetMouseScrollState(at: 1)
        let applied = try await fixture.renderer.testingApplyTranscriptScroll(direction: .down, at: 1)
        #expect(applied >= 0)
        #expect(await fixture.renderer.testingHasActiveScrollStream())
        let composer = try #require(await fixture.renderer.lastComposerHit)
        let x = composer.textArea.x + composer.prefixWidth
        let y = composer.textArea.y
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        guard case .composerMouse = down else {
            Issue.record("expected composerMouse, got \(down)")
            return
        }
        #expect(await !fixture.renderer.testingHasActiveScrollStream())
        try await fixture.renderer.restoreTerminal()
    }

    @Test("transcript left-down cancels residual MouseScrollState")
    func transcriptDownCancelsWheelResidual() async throws {
        let fixture = try ComposerMouseFixture()
        defer { fixture.dispose() }
        try await fixture.seedTranscriptAndDraft()
        await fixture.renderer.testingResetMouseScrollState(at: 1)
        let applied = try await fixture.renderer.testingApplyTranscriptScroll(direction: .down, at: 1)
        #expect(applied >= 0)
        #expect(await fixture.renderer.testingHasActiveScrollStream())
        let model = try #require(await fixture.renderer.lastConversationHit)
        #expect(!model.blockStartLines.isEmpty)
        let contentY = model.blockStartLines[0]
        let screenY = model.conversation.y + contentY - model.scrollOffset
        let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: screenY, button: .left
        )))
        #expect(down == .consumed)
        #expect(await !fixture.renderer.testingHasActiveScrollStream())
        try await fixture.renderer.restoreTerminal()
    }
}
