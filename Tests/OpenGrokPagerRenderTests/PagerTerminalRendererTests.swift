import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("Pager terminal renderer")
struct PagerTerminalRendererTests {
    @Test("renders a full-screen frame with alternate screen, diffing, and cursor state")
    func fullScreenLifecycleAndDiffing() throws {
        let sink = RecordingPagerTerminalSink()
        let renderer = PagerTerminalRenderer(sink: sink)
        let state = PagerRenderState(
            size: TerminalSize(width: 12, height: 8),
            conversation: [.message(PagerMessage(role: .assistant, text: "hello"))],
            input: PagerComposerState(text: "x")
        )

        let first = try renderer.render(state)
        let firstOutput = sink.output
        let second = try renderer.render(state)

        #expect(first.didUseFullRedraw)
        #expect(first.changedCellCount > 0)
        #expect(second.changedCellCount == 0)
        #expect(firstOutput.contains("\u{1B}[?1049h"))
        #expect(firstOutput.contains("\u{1B}[?25l"))
        #expect(firstOutput.contains("\u{1B}[?25h"))
        #expect(sink.visibleText.contains("hello"))
        #expect(sink.flushCount == 3)

        try renderer.restore()
        try renderer.restore()
        let restoredOutput = sink.output
        #expect(restoredOutput.components(separatedBy: "\u{1B}[?1049l").count == 2)
        #expect(sink.flushCount == 4)
    }

    @Test("inline mode projects the bottom viewport and avoids alternate-screen sequences")
    func inlineProjection() throws {
        let sink = RecordingPagerTerminalSink()
        let renderer = PagerTerminalRenderer(
            sink: sink,
            configuration: PagerTerminalRendererConfiguration(
                mode: .inline(height: 9),
                useAlternateScreen: true
            )
        )
        let result = try renderer.render(PagerRenderState(
            size: TerminalSize(width: 16, height: 9),
            conversation: [
                .message(PagerMessage(role: .assistant, text: "top")),
                .message(PagerMessage(role: .assistant, text: "bottom"))
            ],
            input: PagerComposerState(isFocused: false)
        ))

        #expect(result.didUseFullRedraw)
        #expect(sink.visibleText.contains("bottom"))
        #expect(!sink.output.contains("\u{1B}[?1049h"))
        #expect(!sink.output.contains("\u{1B}[?1049l"))
    }

    @Test("resize clears the old viewport and forces a full redraw")
    func resize() throws {
        let sink = RecordingPagerTerminalSink()
        let renderer = PagerTerminalRenderer(sink: sink)
        let state = PagerRenderState(
            size: TerminalSize(width: 10, height: 3),
            conversation: [.message(PagerMessage(role: .assistant, text: "frame"))],
            input: PagerComposerState(isFocused: false)
        )

        _ = try renderer.render(state)
        try renderer.resize(to: TerminalSize(width: 14, height: 4))
        let resized = try renderer.render(state.withSize(width: 14, height: 4))

        #expect(resized.didResize)
        #expect(resized.didUseFullRedraw)
        #expect(sink.output.contains("\u{1B}[2J"))
    }

    @Test("capability gaps fail closed without unsupported lifecycle escapes")
    func capabilityGapsFailClosed() throws {
        let sink = RecordingPagerTerminalSink(capabilities: PagerTerminalCapabilities(
            supportsCursorPositioning: true,
            supportsCursorVisibility: false,
            supportsHyperlinks: false,
            supportsSynchronizedOutput: false,
            supportsAlternateScreen: false
        ))
        let renderer = PagerTerminalRenderer(sink: sink)

        _ = try renderer.render(PagerRenderState(
            size: TerminalSize(width: 8, height: 2),
            conversation: [.message(PagerMessage(role: .assistant, text: "ok"))],
            input: PagerComposerState(isFocused: false)
        ))

        #expect(!sink.output.contains("?1049"))
        #expect(!sink.output.contains("?2026"))
        #expect(!sink.output.contains("?25"))
    }

    @Test("missing cursor positioning is rejected before writing")
    func missingCursorPositioningIsRejected() throws {
        let sink = RecordingPagerTerminalSink(capabilities: .conservative)
        let renderer = PagerTerminalRenderer(sink: sink)

        #expect(throws: PagerTerminalRendererError.unsupportedCursorPositioning) {
            try renderer.start()
        }
        #expect(sink.output.isEmpty)
    }
}

private final class RecordingPagerTerminalSink: PagerTerminalSink, @unchecked Sendable {
    let capabilities: PagerTerminalCapabilities
    private(set) var bytes: [UInt8] = []
    private(set) var flushCount = 0

    init(capabilities: PagerTerminalCapabilities = .standard) {
        self.capabilities = capabilities
    }

    func write(bytes: [UInt8]) throws {
        self.bytes.append(contentsOf: bytes)
    }

    func flush() throws {
        flushCount += 1
    }

    var output: String {
        String(decoding: bytes, as: UTF8.self)
    }

    var visibleText: String {
        var text = ""
        var skippingEscape = false
        var skippingCSI = false
        for scalar in output.unicodeScalars {
            if skippingEscape {
                if !skippingCSI, scalar.value == 0x5B {
                    skippingCSI = true
                    continue
                }
                if skippingCSI, (0x40...0x7E).contains(scalar.value) {
                    skippingEscape = false
                    skippingCSI = false
                }
                continue
            }
            if scalar.value == 0x1B {
                skippingEscape = true
                skippingCSI = false
                continue
            }
            if scalar.value >= 0x20 {
                text.unicodeScalars.append(scalar)
            }
        }
        return text
    }
}

private extension PagerRenderState {
    func withSize(width: Int, height: Int) -> PagerRenderState {
        var copy = self
        copy.size = TerminalSize(width: width, height: height)
        return copy
    }
}
