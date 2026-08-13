// LiveMouseReportingStickyToastTests.swift
//
// Live-seam mouse-off sticky toast against pin 650c1db7: prompt vs
// scrollback copy, persistence, transient precedence/expiry, rollback,
// no transcript note, toast occluder swallow.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class StickyToastCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var writtenByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes.count
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

private struct StickyToastFixture {
    let home: URL
    let sink: StickyToastCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(paintCadence: TimeInterval = PagerMotion.minimumPaintCadence) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-mouse-sticky-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_MOUSE_REPORTING_TOGGLE": "1"
        ]
        sink = StickyToastCapturingSink()
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            sessionID: "mouse-sticky",
            openGrokHome: home,
            paintCadence: paintCadence,
            environment: environment
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("Live mouse-reporting sticky toast")
struct LiveMouseReportingStickyToastTests {
    @Test("toggle off paints prompt copy; scrollback focus swaps to Ctrl+r")
    func promptAndScrollbackCopy() async throws {
        let fixture = try StickyToastFixture()
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()

        try await fixture.renderer.render(.overlay(.toggleMouseReporting))
        let reportingOff = await fixture.renderer.testingIsMouseReportingEnabled()
        #expect(reportingOff == false)
        let stickyOff = await fixture.renderer.testingStickyToast()
        #expect(stickyOff == LiveInteractiveControllerRenderer.mouseOffHintScrollback)
        try await fixture.renderer.testingForcePaint()
        let paintedPrompt = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedPrompt == LiveInteractiveControllerRenderer.mouseOffHintPrompt)
        // First paint of the sticky slot is a full write; later focus swaps
        // may emit only a changed prefix because the suffix stays on screen.
        #expect(fixture.sink.text.contains(
            LiveInteractiveControllerRenderer.mouseOffHintPrompt
        ))
        let messages = await fixture.renderer.testingSystemMessageTexts()
        #expect(!messages.contains { text in
            text.contains("Mouse reporting off") || text.contains("Mouse reporting on")
        })

        try await fixture.renderer.render(.focusChanged(.scrollback))
        try await fixture.renderer.testingForcePaint()
        let paintedScrollback = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedScrollback == LiveInteractiveControllerRenderer.mouseOffHintScrollback)
        let stickyScrollback = await fixture.renderer.testingStickyToast()
        #expect(stickyScrollback == LiveInteractiveControllerRenderer.mouseOffHintScrollback)

        try await fixture.renderer.render(.focusChanged(.prompt))
        try await fixture.renderer.testingForcePaint()
        let paintedPromptAgain = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedPromptAgain == LiveInteractiveControllerRenderer.mouseOffHintPrompt)
    }

    @Test("Esc, click, j/k, and idle do not dismiss the sticky banner")
    func persistenceAcrossInput() async throws {
        let fixture = try StickyToastFixture()
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()
        try await fixture.renderer.render(.overlay(.toggleMouseReporting))
        let sticky = LiveInteractiveControllerRenderer.mouseOffHintScrollback
        let stickyAfterToggle = await fixture.renderer.testingStickyToast()
        #expect(stickyAfterToggle == sticky)

        _ = try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape)))
        let stickyAfterEsc = await fixture.renderer.testingStickyToast()
        #expect(stickyAfterEsc == sticky)
        let paintedAfterEsc = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedAfterEsc != nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: 10, y: 8, button: .left
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: 10, y: 8, button: .left
        )))
        let stickyAfterClick = await fixture.renderer.testingStickyToast()
        #expect(stickyAfterClick == sticky)

        try await fixture.renderer.render(.scrollback(.selectNext))
        try await fixture.renderer.render(.scrollback(.selectPrevious))
        try await fixture.renderer.render(.viewport(.lineDown))
        try await fixture.renderer.render(.viewport(.lineUp))
        let stickyAfterNav = await fixture.renderer.testingStickyToast()
        #expect(stickyAfterNav == sticky)

        try await fixture.renderer.testingForcePaint()
        let stickyAfterIdle = await fixture.renderer.testingStickyToast()
        #expect(stickyAfterIdle == sticky)
        let paintedAfterIdle = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedAfterIdle != nil)
    }

    @Test("transient wins then sticky returns after expiry; re-enable clears sticky")
    func transientPrecedenceAndReenable() async throws {
        let fixture = try StickyToastFixture()
        defer { fixture.cleanup() }
        await fixture.renderer.testingSetMonotonicNow(1_000)
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()

        try await fixture.renderer.render(.overlay(.toggleMouseReporting))
        let paintedOffSticky = await fixture.renderer.testingStickyToast()
        #expect(paintedOffSticky == LiveInteractiveControllerRenderer.mouseOffHintScrollback)
        try await fixture.renderer.testingForcePaint()
        let paintedOff = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedOff == LiveInteractiveControllerRenderer.mouseOffHintPrompt)

        try await fixture.renderer.testingShowTransientToast("Copied!")
        let paintedCopied = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedCopied == "Copied!")
        let stickyDuringCopied = await fixture.renderer.testingStickyToast()
        #expect(stickyDuringCopied == LiveInteractiveControllerRenderer.mouseOffHintScrollback)
        #expect(fixture.sink.text.contains("Copied!"))

        await fixture.renderer.testingSetMonotonicNow(
            1_000 + LiveInteractiveControllerRenderer.transientToastDuration + 0.01
        )
        try await fixture.renderer.testingForcePaint()
        let paintedStickyAgain = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedStickyAgain == LiveInteractiveControllerRenderer.mouseOffHintPrompt)
        let transientAfterExpiry = await fixture.renderer.testingTransientToast()
        #expect(transientAfterExpiry == nil)

        try await fixture.renderer.render(.overlay(.toggleMouseReporting))
        let stickyAfterOn = await fixture.renderer.testingStickyToast()
        #expect(stickyAfterOn == nil)
        let transientOn = await fixture.renderer.testingTransientToast()
        #expect(transientOn == LiveInteractiveControllerRenderer.mouseReportingOnToast)
        try await fixture.renderer.testingForcePaint()
        let paintedOn = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedOn == LiveInteractiveControllerRenderer.mouseReportingOnToast)
    }

    @Test("failed terminal write does not set or clear toast")
    func failedWriteLeavesToastUntouched() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-mouse-sticky-fail-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_MOUSE_REPORTING_TOGGLE": "1"
        ]
        let sink = MouseStickyFailingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            sessionID: "mouse-sticky-fail",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
        try await renderer.begin()
        try await renderer.testingDismissWelcomeOverlay()
        sink.clear()
        sink.failNextDisable = true

        var threw = false
        do {
            try await renderer.render(.overlay(.toggleMouseReporting))
        } catch is MouseStickyWriteFailure {
            threw = true
        }
        #expect(threw)
        let stillEnabled = await renderer.testingIsMouseReportingEnabled()
        #expect(stillEnabled == true)
        let sticky = await renderer.testingStickyToast()
        #expect(sticky == nil)
        let painted = await renderer.testingLastPaintedToast()
        #expect(painted == nil)
        let messages = await renderer.testingSystemMessageTexts()
        #expect(!messages.contains { text in
            text.contains("Mouse reporting")
        })
    }

    @Test("toast occluder swallows clicks before transcript and composer")
    func occluderSwallowsHits() async throws {
        let fixture = try StickyToastFixture()
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()
        // Mouse reporting stays on: a synthetic click after toggle-off is
        // `.notHandled` at the outer guard (the real terminal would send none).
        let reportingOn = await fixture.renderer.testingIsMouseReportingEnabled()
        #expect(reportingOn)
        try await fixture.renderer.testingShowTransientToast("Copied!")
        try await fixture.renderer.testingForcePaint()
        let painted = await fixture.renderer.testingLastPaintedToast()
        #expect(painted == "Copied!")

        let occluder = await fixture.renderer.testingLastToastOccluder()
        #expect(occluder != nil)
        let rect = try #require(occluder)
        let x = rect.x + max(0, rect.width / 2)
        let y = rect.y

        let before = await fixture.renderer.testingScrollbackSelectedIndex()
        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        #expect(down == .consumed)
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: y, button: .left
        )))
        #expect(up == .consumed)
        let pending = await fixture.renderer.testingPendingScrollbackClick()
        #expect(pending == nil)
        let after = await fixture.renderer.testingScrollbackSelectedIndex()
        #expect(after == before)
        let stillEnabled = await fixture.renderer.testingIsMouseReportingEnabled()
        #expect(stillEnabled)
    }

    @Test("idle scroll clock expires transient toast without forced paint")
    func idleScrollClockExpiresTransientToast() async throws {
        let fixture = try StickyToastFixture()
        defer { fixture.cleanup() }
        await fixture.renderer.testingSetMonotonicNow(1_000)
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()

        try await fixture.renderer.render(.overlay(.toggleMouseReporting))
        try await fixture.renderer.testingShowTransientToast("Copied!")
        #expect(await fixture.renderer.testingLastPaintedToast() == "Copied!")
        #expect(fixture.sink.text.contains("Copied!"))

        let deadline = await fixture.renderer.testingScrollClockDeadline(at: 1_000)
        #expect(deadline != nil)
        let remaining = try #require(deadline)
        #expect(remaining > 0)
        #expect(remaining <= LiveInteractiveControllerRenderer.transientToastDuration)

        try await fixture.renderer.render(.overlay(.help))
        let overlayDeadline = await fixture.renderer.testingScrollClockDeadline(at: 1_000)
        #expect(overlayDeadline != nil, "capturing overlay must not starve toast TTL")

        let due = 1_000 + LiveInteractiveControllerRenderer.transientToastDuration + 0.01
        await fixture.renderer.testingSetMonotonicNow(due)
        let bytesBeforeTick = fixture.sink.writtenByteCount
        let tickLines = try await fixture.renderer.testingHandleScrollClockTick(at: due)
        #expect(tickLines == 0)
        #expect(await fixture.renderer.testingTransientToast() == nil)
        let paintedSticky = await fixture.renderer.testingLastPaintedToast()
        #expect(paintedSticky == LiveInteractiveControllerRenderer.mouseOffHintPrompt)
        #expect(fixture.sink.writtenByteCount > bytesBeforeTick)
    }
}

private final class MouseStickyFailingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    var failNextDisable = false

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: newBytes, as: UTF8.self)
        if failNextDisable, text.contains("\u{1B}[?1006l") {
            failNextDisable = false
            throw MouseStickyWriteFailure()
        }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    func clear() {
        lock.lock(); defer { lock.unlock() }
        bytes.removeAll(keepingCapacity: false)
    }
}

private struct MouseStickyWriteFailure: Error {}
