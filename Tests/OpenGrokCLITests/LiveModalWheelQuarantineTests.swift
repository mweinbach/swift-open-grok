// LiveModalWheelQuarantineTests.swift
//
// Capturing overlays are scroll-blocking (Rust `is_scroll_blocking_modal_open`):
// wheel outside the focused overlay must not move the transcript; wheel over
// the focused overlay still moves its selection.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class WheelCapturingSink: PagerTerminalSink, @unchecked Sendable {
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

private struct WheelFixture {
    let home: URL
    let sink: WheelCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-wheel-quarantine-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = WheelCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "alpha-model", providerID: "xai", name: "alpha-model"),
                LiveModelPickerEntry(id: "beta-model", providerID: "xai", name: "beta-model"),
            ],
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
            ]
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
}

private func withWheelFixture(
    _ body: (WheelFixture) async throws -> Void
) async throws {
    let fixture = try WheelFixture()
    do {
        try await body(fixture)
        try await fixture.renderer.restoreTerminal()
        fixture.dispose()
    } catch {
        try? await fixture.renderer.restoreTerminal()
        fixture.dispose()
        throw error
    }
}

@Suite("Live modal wheel quarantine", .serialized)
struct LiveModalWheelQuarantineTests {
    @Test("wheel outside a capturing overlay leaves transcript offset unchanged; inside moves selection")
    func capturingOverlayQuarantinesTranscriptWheel() async throws {
        try await withWheelFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()

            // Tall transcript so the viewport can leave follow-tail.
            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "fill",
                mode: .fullScreen
            )))
            for index in 0..<60 {
                try await renderer.render(.session(.output(
                    "scroll filler line \(index) with enough width to paint\n"
                )))
            }
            try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))

            try await renderer.render(.viewport(.pageUp))
            try await renderer.render(.viewport(.pageUp))
            #expect(await !renderer.testingFollowsBottom())

            try await renderer.render(.overlay(.modelPicker(query: nil)))
            #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))

            let focusedID = try #require(await renderer.testingFocusedOverlayID())
            let focused = try #require(
                await renderer.lastOverlayBounds.last(where: { $0.id == focusedID })
            )
            let offsetWithOverlay = await renderer.testingTranscriptScrollOffset()
            let selectedBefore = try #require(await renderer.testingFocusedOverlaySelectedIndex())

            // Choose a cell that is asserted outside the focused overlay —
            // `y - 2` / `x: 1` can still land inside a top-anchored modal and
            // silently exercise the inside path (app_view.rs:3016-3033).
            let outsidePoint = try #require(pointOutside(focused.frame, terminalWidth: 100, terminalHeight: 30))
            #expect(!focused.hitTest(x: outsidePoint.x, y: outsidePoint.y))

            let outside = try await renderer.handleInput(.mouse(MouseEvent(
                kind: .scrollDown,
                x: outsidePoint.x,
                y: outsidePoint.y,
                button: MouseEvent.noButton
            )))
            #expect(outside == .consumed)
            #expect(await renderer.testingTranscriptScrollOffset() == offsetWithOverlay)
            #expect(await !renderer.testingFollowsBottom())
            #expect(await renderer.testingFocusedOverlaySelectedIndex() == selectedBefore)

            // Wheel over the focused picker still moves selection one row.
            let inside = try await renderer.handleInput(.mouse(MouseEvent(
                kind: .scrollDown,
                x: focused.frame.x + focused.frame.width / 2,
                y: focused.frame.y + focused.frame.height / 2,
                button: MouseEvent.noButton
            )))
            #expect(inside == .consumed)
            #expect(await renderer.testingTranscriptScrollOffset() == offsetWithOverlay)
            #expect(await renderer.testingFocusedOverlaySelectedIndex() == selectedBefore + 1)
        }
    }

    @Test("horizontal wheel over a focused overlay is consumed without moving selection or transcript")
    func horizontalWheelOverFocusedOverlayIsNoOp() async throws {
        try await withWheelFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()

            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "fill",
                mode: .fullScreen
            )))
            for index in 0..<60 {
                try await renderer.render(.session(.output(
                    "scroll filler line \(index) with enough width to paint\n"
                )))
            }
            try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))

            try await renderer.render(.viewport(.pageUp))
            try await renderer.render(.viewport(.pageUp))
            #expect(await !renderer.testingFollowsBottom())

            try await renderer.render(.overlay(.modelPicker(query: nil)))
            #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))

            let focusedID = try #require(await renderer.testingFocusedOverlayID())
            let focused = try #require(
                await renderer.lastOverlayBounds.last(where: { $0.id == focusedID })
            )
            let offsetWithOverlay = await renderer.testingTranscriptScrollOffset()
            let selectedBefore = try #require(await renderer.testingFocusedOverlaySelectedIndex())
            let insideX = focused.frame.x + focused.frame.width / 2
            let insideY = focused.frame.y + focused.frame.height / 2
            #expect(focused.hitTest(x: insideX, y: insideY))

            for kind: MouseEvent.Kind in [.scrollLeft, .scrollRight] {
                let routed = try await renderer.handleInput(.mouse(MouseEvent(
                    kind: kind,
                    x: insideX,
                    y: insideY,
                    button: MouseEvent.noButton
                )))
                #expect(routed == .consumed)
                #expect(await renderer.testingTranscriptScrollOffset() == offsetWithOverlay)
                #expect(await renderer.testingFocusedOverlaySelectedIndex() == selectedBefore)
                #expect(await !renderer.testingFollowsBottom())
            }
        }
    }
}

/// A screen cell strictly outside `frame`, preferring above / below / left /
/// right in that order. Returns nil only if the frame fills the whole terminal.
private func pointOutside(
    _ frame: TerminalRect,
    terminalWidth: Int,
    terminalHeight: Int
) -> (x: Int, y: Int)? {
    if frame.y > 0 {
        return (frame.x + min(frame.width / 2, max(0, frame.width - 1)), frame.y - 1)
    }
    if frame.bottom < terminalHeight {
        return (frame.x + min(frame.width / 2, max(0, frame.width - 1)), frame.bottom)
    }
    if frame.x > 0 {
        return (frame.x - 1, frame.y + min(frame.height / 2, max(0, frame.height - 1)))
    }
    if frame.right < terminalWidth {
        return (frame.right, frame.y + min(frame.height / 2, max(0, frame.height - 1)))
    }
    return nil
}
