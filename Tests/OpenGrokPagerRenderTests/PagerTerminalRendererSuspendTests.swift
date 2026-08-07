// PagerTerminalRendererSuspendTests.swift
//
// The renderer half of suspend-for-child (`suspend_for_child`,
// event_loop.rs:394-406): teardown order on suspend, re-entry order on
// resume, the paint gate in between, and the interaction with `restore()`.

import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("Pager terminal renderer suspend/resume")
struct PagerTerminalRendererSuspendTests {
    private static func makeFixture() throws -> (
        sink: SuspendRecordingSink,
        renderer: PagerTerminalRenderer,
        state: PagerRenderState
    ) {
        let sink = SuspendRecordingSink()
        let renderer = PagerTerminalRenderer(
            sink: sink,
            configuration: PagerTerminalRendererConfiguration(
                mode: .fullscreen,
                useAlternateScreen: true,
                useMouseReporting: true
            )
        )
        let state = PagerRenderState(
            size: TerminalSize(width: 20, height: 8),
            conversation: [.message(PagerMessage(role: .assistant, text: "hello"))],
            input: PagerComposerState(text: "x")
        )
        _ = try renderer.render(state)
        return (sink, renderer, state)
    }

    @Test("suspend tears modes down in restore order: mouse reset before the alt-screen leave, cursor shown")
    func suspendTeardownOrder() throws {
        let (sink, renderer, _) = try Self.makeFixture()

        let before = sink.byteCount
        try renderer.suspendToChild()
        let output = sink.output(from: before)

        let mouseReset = output.range(of: ANSIMouse.trackingReset)
        let altLeave = output.range(of: "\u{1B}[?1049l")
        #expect(mouseReset != nil)
        #expect(altLeave != nil)
        if let mouseReset, let altLeave {
            #expect(mouseReset.lowerBound < altLeave.lowerBound)
        }
        #expect(output.contains("\u{1B}[?25h"))
        #expect(renderer.isSuspended)
    }

    @Test("renders and folded frames write zero bytes while suspended")
    func suspendedRendersAreGated() throws {
        let (sink, renderer, state) = try Self.makeFixture()
        try renderer.suspendToChild()

        let during = sink.byteCount
        let report = try renderer.render(state)
        #expect(report.changedCellCount == 0)
        #expect(!report.didUseFullRedraw)
        #expect(try renderer.requestFrame(state, at: 100) == nil)
        #expect(try renderer.flushPendingFrame(state, at: 200) == nil)
        // No fold survives the suspension either: an armed flush timer must
        // not spin against a schedule frozen in the past.
        #expect(renderer.scheduledFrameAt == nil)
        #expect(sink.byteCount == during)
    }

    @Test("resume re-enters alt before hiding the cursor, mouse last, and forces a full redraw")
    func resumeReentryOrderAndFullRedraw() throws {
        let (sink, renderer, state) = try Self.makeFixture()
        try renderer.suspendToChild()

        let before = sink.byteCount
        try renderer.resumeFromChild()
        let output = sink.output(from: before)

        let altEnter = output.range(of: "\u{1B}[?1049h")
        let cursorHide = output.range(of: "\u{1B}[?25l")
        let mouseEnable = output.range(of: ANSIMouse.enableReporting)
        #expect(altEnter != nil)
        #expect(cursorHide != nil)
        #expect(mouseEnable != nil)
        if let altEnter, let cursorHide, let mouseEnable {
            #expect(altEnter.lowerBound < cursorHide.lowerBound)
            #expect(cursorHide.lowerBound < mouseEnable.lowerBound)
        }
        #expect(!renderer.isSuspended)

        let painted = sink.byteCount
        let report = try renderer.render(state)
        #expect(report.didUseFullRedraw)
        #expect(sink.byteCount > painted)
    }

    @Test("restore after suspend still latches and never leaves the alt screen twice")
    func restoreAfterSuspendLatches() throws {
        let (sink, renderer, _) = try Self.makeFixture()
        try renderer.suspendToChild()

        try renderer.restore()
        #expect(renderer.isRestored)
        #expect(!renderer.isSuspended)
        // The alt-screen leave happened once, on suspend; restore skipped it.
        #expect(sink.output(from: 0).components(separatedBy: "\u{1B}[?1049l").count == 2)

        // The latch holds: a second restore writes nothing at all.
        let after = sink.byteCount
        try renderer.restore()
        #expect(sink.byteCount == after)
    }
}

private final class SuspendRecordingSink: PagerTerminalSink, @unchecked Sendable {
    let capabilities: PagerTerminalCapabilities = .standard
    private(set) var bytes: [UInt8] = []

    func write(bytes: [UInt8]) throws {
        self.bytes.append(contentsOf: bytes)
    }

    func flush() throws {}

    var byteCount: Int { bytes.count }

    func output(from offset: Int) -> String {
        String(decoding: bytes[offset...], as: UTF8.self)
    }
}
