// LiveMouseOverlayRoutingTests.swift
//
// Mouse routing against REAL painted overlay bounds: a wheel report over the
// focused model picker must move its selection, and a click on a row must
// select it. The parity suite injects synthetic `.mouse` events into the
// controller's input stream but never asserts against the renderer's
// published bounds — which is exactly where a live "mouse does nothing"
// break hides.

import Foundation
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class MouseCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// The capture with CSI/OSC escape sequences removed. Every painted cell
    /// is prefixed by a cursor move, so raw bytes interleave escapes between
    /// the letters of every word; matching needs the stripped form.
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

@Suite("Live mouse overlay routing", .serialized)
struct LiveMouseOverlayRoutingTests {
    private func makeRenderer(sink: MouseCapturingSink) -> LiveInteractiveControllerRenderer {
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        return LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: "/work",
            modelName: "alpha-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "alpha-model", providerID: "xai", name: "alpha-model"),
                LiveModelPickerEntry(id: "beta-model", providerID: "xai", name: "beta-model"),
            ],
            paintCadence: PagerMotion.minimumPaintCadence
        )
    }

    /// Whitespace-insensitive paint poll; the frame diff encoder skips blank
    /// cells, so multi-word needles never match the raw capture.
    private func waitForPaint(
        _ sink: MouseCapturingSink,
        containing needle: String
    ) async -> Bool {
        let compact = needle.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if sink.text.filter({ !$0.isWhitespace }).contains(compact) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @Test("a wheel report over the focused picker moves its selection")
    func wheelMovesPickerSelection() async throws {
        let sink = MouseCapturingSink()
        let renderer = makeRenderer(sink: sink)
        try await renderer.begin()
        try await renderer.render(.overlay(.modelPicker(query: nil)))
        #expect(await waitForPaint(sink, containing: "alpha-model (current)"))

        // One wheel notch over the focused picker moves the selection one
        // row; Enter then lands on the SECOND catalog entry. Without a live
        // switch coordinator the selection prints "Model set to <id>", which
        // carries exactly which row the wheel landed on.
        let routing = try await renderer.handleInput(.mouse(MouseEvent(
            kind: .scrollDown,
            x: 50,
            y: 12,
            button: MouseEvent.noButton
        )))
        #expect(routing == .consumed)
        let selected = try await renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(selected == .consumed)
        #expect(await waitForPaint(sink, containing: "Model set to beta-model"))
        try await renderer.restoreTerminal()
    }
}
