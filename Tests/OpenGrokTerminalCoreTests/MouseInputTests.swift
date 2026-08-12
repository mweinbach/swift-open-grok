// MouseInputTests.swift
//
// Golden byte sequences for every mouse event kind, chunked delivery,
// malformed-sequence resync, and enable/disable sequence emission.

import Foundation
import Testing
@testable import OpenGrokTerminalCore

private func bytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

/// `ESC [ < b ; x ; y M|m`
private func sgr(_ button: Int, _ column: Int, _ row: Int, press: Bool) -> [UInt8] {
    bytes("\u{1B}[<\(button);\(column);\(row)\(press ? "M" : "m")")
}

private func decodedEvent(_ raw: [UInt8], sourceLocation: SourceLocation = #_sourceLocation)
    throws -> MouseEvent
{
    guard case .event(let event) = MouseReportDecoder.decode(raw) else {
        Issue.record("expected a decoded event", sourceLocation: sourceLocation)
        throw MouseTestError.notAnEvent
    }
    return event
}

private enum MouseTestError: Error {
    case notAnEvent
}

@Suite("Mouse SGR decoding")
struct MouseSGRDecodingTests {
    @Test("Left button press and release")
    func leftPressRelease() throws {
        let press = try decodedEvent(sgr(0, 10, 5, press: true))
        #expect(press.kind == .down)
        #expect(press.resolvedButton == .left)
        #expect(press.x == 9 && press.y == 4)
        #expect(press.modifiers == [])

        let release = try decodedEvent(sgr(0, 10, 5, press: false))
        #expect(release.kind == .up)
        #expect(release.resolvedButton == .left)
        #expect(release.x == 9 && release.y == 4)
    }

    @Test("Middle and right buttons")
    func middleAndRight() throws {
        #expect(try decodedEvent(sgr(1, 1, 1, press: true)).resolvedButton == .middle)
        #expect(try decodedEvent(sgr(2, 1, 1, press: true)).resolvedButton == .right)
    }

    @Test("Extended buttons 8-11 report via bit 7")
    func extendedButtons() throws {
        // 128 + n selects buttons 8..11.
        #expect(try decodedEvent(sgr(128, 4, 4, press: true)).resolvedButton == .other(8))
        #expect(try decodedEvent(sgr(131, 4, 4, press: true)).resolvedButton == .other(11))
    }

    @Test("Wheel up, down, left, right")
    func wheelDirections() throws {
        #expect(try decodedEvent(sgr(64, 20, 7, press: true)).kind == .scrollUp)
        #expect(try decodedEvent(sgr(65, 20, 7, press: true)).kind == .scrollDown)
        #expect(try decodedEvent(sgr(66, 20, 7, press: true)).kind == .scrollLeft)
        #expect(try decodedEvent(sgr(67, 20, 7, press: true)).kind == .scrollRight)

        let wheel = try decodedEvent(sgr(65, 20, 7, press: true))
        #expect(wheel.resolvedButton == .none)
        #expect(wheel.isScroll)
        #expect(wheel.x == 19 && wheel.y == 6)
    }

    @Test("Motion with a held button is a drag; motion alone is a move")
    func motionKinds() throws {
        // 32 = motion, low bits carry the held button.
        let drag = try decodedEvent(sgr(32, 3, 3, press: true))
        #expect(drag.kind == .drag)
        #expect(drag.resolvedButton == .left)

        let rightDrag = try decodedEvent(sgr(34, 3, 3, press: true))
        #expect(rightDrag.kind == .drag)
        #expect(rightDrag.resolvedButton == .right)

        // 35 = motion + button code 3 (no button held).
        let move = try decodedEvent(sgr(35, 3, 3, press: true))
        #expect(move.kind == .move)
        #expect(move.resolvedButton == .none)
        #expect(move.button == MouseEvent.noButton)
    }

    @Test("Modifier bits decode independently")
    func modifiers() throws {
        #expect(try decodedEvent(sgr(4, 1, 1, press: true)).modifiers == [.shift])
        #expect(try decodedEvent(sgr(8, 1, 1, press: true)).modifiers == [.alt])
        #expect(try decodedEvent(sgr(16, 1, 1, press: true)).modifiers == [.control])
        #expect(
            try decodedEvent(sgr(28, 1, 1, press: true)).modifiers == [.shift, .alt, .control]
        )
        // Modifiers ride along with wheel reports too.
        let shiftWheel = try decodedEvent(sgr(69, 1, 1, press: true))
        #expect(shiftWheel.kind == .scrollDown)
        #expect(shiftWheel.modifiers == [.shift])
    }

    @Test("Coordinates convert 1-based to 0-based and clamp at zero")
    func coordinateConversion() throws {
        let origin = try decodedEvent(sgr(0, 1, 1, press: true))
        #expect(origin.x == 0 && origin.y == 0)

        // Some terminals emit 0 for out-of-range positions; clamp instead of
        // producing a negative cell.
        let clamped = try decodedEvent(sgr(0, 0, 0, press: true))
        #expect(clamped.x == 0 && clamped.y == 0)

        let wide = try decodedEvent(sgr(0, 500, 300, press: true))
        #expect(wide.x == 499 && wide.y == 299)
    }
}

@Suite("Mouse X10 decoding")
struct MouseX10DecodingTests
{
    /// `ESC [ M Cb Cx Cy`, each payload byte biased by 32.
    private func x10(_ button: Int, _ column: Int, _ row: Int) -> [UInt8] {
        [0x1B, 0x5B, 0x4D, UInt8(button + 32), UInt8(column + 32), UInt8(row + 32)]
    }

    @Test("Press decodes button and coordinates")
    func press() throws {
        let event = try decodedEvent(x10(0, 10, 5))
        #expect(event.kind == .down)
        #expect(event.resolvedButton == .left)
        #expect(event.x == 9 && event.y == 4)
    }

    @Test("Release carries no button attribution")
    func release() throws {
        let event = try decodedEvent(x10(3, 10, 5))
        #expect(event.kind == .up)
        #expect(event.resolvedButton == .none)
    }

    @Test("Wheel reports use the same bit 6")
    func wheel() throws {
        #expect(try decodedEvent(x10(64, 2, 2)).kind == .scrollUp)
        #expect(try decodedEvent(x10(65, 2, 2)).kind == .scrollDown)
    }

    @Test("Payload bytes below 32 are malformed")
    func truncatedPayload() {
        let raw: [UInt8] = [0x1B, 0x5B, 0x4D, 0x20, 0x10, 0x21]
        #expect(MouseReportDecoder.decode(raw) == .malformed)
    }
}

@Suite("Mouse decoder rejection")
struct MouseDecoderRejectionTests {
    @Test("Non-mouse sequences are reported as such")
    func notMouse() {
        #expect(MouseReportDecoder.decode(bytes("\u{1B}[A")) == .notMouse)
        #expect(MouseReportDecoder.decode(bytes("\u{1B}[200~")) == .notMouse)
        #expect(MouseReportDecoder.decode(bytes("abc")) == .notMouse)
        #expect(MouseReportDecoder.decode([]) == .notMouse)
    }

    @Test("Structurally invalid SGR reports are malformed, not events")
    func malformedSGR() {
        // Too few parameters.
        #expect(MouseReportDecoder.decode(bytes("\u{1B}[<0;5M")) == .malformed)
        // Too many parameters.
        #expect(MouseReportDecoder.decode(bytes("\u{1B}[<0;5;5;5M")) == .malformed)
        // Empty parameter.
        #expect(MouseReportDecoder.decode(bytes("\u{1B}[<0;;5M")) == .malformed)
        // Non-numeric parameter byte.
        #expect(MouseReportDecoder.decode(bytes("\u{1B}[<0;x;5M")) == .malformed)
        // Wrong final byte.
        #expect(MouseReportDecoder.decode(bytes("\u{1B}[<0;5;5R")) == .malformed)
        // Digit run long enough to overflow a naive accumulator.
        #expect(
            MouseReportDecoder.decode(bytes("\u{1B}[<0;99999999999999999999;5M")) == .malformed
        )
    }
}

@Suite("Mouse stream parser")
struct MouseStreamParserTests {
    private func parseAll(_ raw: [UInt8]) -> [MouseParserOutput] {
        var parser = MouseStreamParser()
        var out = parser.feed(raw)
        out.append(contentsOf: parser.finish())
        return out
    }

    private func events(_ outputs: [MouseParserOutput]) -> [MouseEvent] {
        outputs.compactMap { if case .mouse(let e) = $0 { return e } else { return nil } }
    }

    private func passthroughBytes(_ outputs: [MouseParserOutput]) -> [UInt8] {
        outputs.flatMap { output -> [UInt8] in
            if case .passthrough(let b) = output { return b }
            return []
        }
    }

    @Test("A lone report yields one event and no passthrough")
    func singleReport() {
        let out = parseAll(sgr(0, 3, 4, press: true))
        #expect(out.count == 1)
        #expect(events(out).first?.kind == .down)
        #expect(passthroughBytes(out).isEmpty)
    }

    @Test("Text around a report is passed through in order")
    func interleavedText() {
        var raw = bytes("hi")
        raw.append(contentsOf: sgr(65, 2, 2, press: true))
        raw.append(contentsOf: bytes("bye"))
        let out = parseAll(raw)
        #expect(out.count == 3)
        #expect(out[0] == .passthrough(bytes("hi")))
        if case .mouse(let event) = out[1] {
            #expect(event.kind == .scrollDown)
        } else {
            Issue.record("expected a mouse event in the middle")
        }
        #expect(out[2] == .passthrough(bytes("bye")))
    }

    @Test("A report split one byte per feed decodes identically")
    func bytewiseDelivery() {
        let raw = sgr(2, 42, 17, press: true)
        var parser = MouseStreamParser()
        var out: [MouseParserOutput] = []
        for (index, byte) in raw.enumerated() {
            let step = parser.feed(byte)
            if index < raw.count - 1 {
                #expect(step.isEmpty)
                #expect(parser.hasPendingBytes)
            }
            out.append(contentsOf: step)
        }
        #expect(out.count == 1)
        guard case .mouse(let event) = out.first else {
            Issue.record("expected a mouse event")
            return
        }
        #expect(event.kind == .down)
        #expect(event.resolvedButton == .right)
        #expect(event.x == 41 && event.y == 16)
        #expect(!parser.hasPendingBytes)
    }

    @Test("Arbitrary chunk boundaries produce the same events")
    func arbitraryChunking() {
        var raw: [UInt8] = []
        raw.append(contentsOf: sgr(64, 1, 1, press: true))
        raw.append(contentsOf: sgr(0, 2, 2, press: true))
        raw.append(contentsOf: sgr(0, 2, 2, press: false))
        raw.append(contentsOf: sgr(35, 3, 3, press: true))

        for splitSize in 1...raw.count {
            var parser = MouseStreamParser()
            var out: [MouseParserOutput] = []
            var index = 0
            while index < raw.count {
                let end = min(index + splitSize, raw.count)
                out.append(contentsOf: parser.feed(Array(raw[index..<end])))
                index = end
            }
            out.append(contentsOf: parser.finish())
            let kinds = events(out).map(\.kind)
            #expect(
                kinds == [.scrollUp, .down, .up, .move],
                "chunk size \(splitSize) changed the event stream"
            )
            #expect(passthroughBytes(out).isEmpty, "chunk size \(splitSize) leaked bytes")
        }
    }

    @Test("Malformed reports pass through without desyncing the parser")
    func malformedDoesNotDesync() {
        var raw = bytes("\u{1B}[<0;5M")  // too few parameters
        raw.append(contentsOf: sgr(0, 7, 8, press: true))
        let out = parseAll(raw)
        #expect(passthroughBytes(out) == bytes("\u{1B}[<0;5M"))
        let recovered = events(out)
        #expect(recovered.count == 1)
        #expect(recovered.first?.x == 6 && recovered.first?.y == 7)
    }

    @Test("Non-mouse CSI sequences are handed back byte-for-byte")
    func nonMouseCSIPassthrough() {
        var raw = bytes("\u{1B}[A\u{1B}[200~")
        raw.append(contentsOf: sgr(0, 1, 1, press: true))
        let out = parseAll(raw)
        #expect(passthroughBytes(out) == bytes("\u{1B}[A\u{1B}[200~"))
        #expect(events(out).count == 1)
    }

    @Test("A truncated report abandons cleanly when a new escape arrives")
    func truncatedThenNewSequence() {
        // ESC [ < 0 ; 5 (no final byte) immediately followed by a real report.
        var raw = bytes("\u{1B}[<0;5")
        raw.append(contentsOf: sgr(0, 9, 9, press: true))
        let out = parseAll(raw)
        #expect(passthroughBytes(out) == bytes("\u{1B}[<0;5"))
        #expect(events(out).count == 1)
        #expect(events(out).first?.x == 8)
    }

    @Test("An overlong parameter run is abandoned rather than buffered forever")
    func parameterRunCap() {
        var raw = bytes("\u{1B}[<")
        raw.append(contentsOf: Array(repeating: UInt8(0x31), count: 64))  // '1' x64
        raw.append(contentsOf: sgr(0, 1, 1, press: true))
        let out = parseAll(raw)
        #expect(!passthroughBytes(out).isEmpty)
        #expect(events(out).count == 1)
    }

    @Test("An unterminated report is flushed by finish()")
    func finishFlushesPending() {
        var parser = MouseStreamParser()
        let partial = bytes("\u{1B}[<0;5;5")
        #expect(parser.feed(partial).isEmpty)
        #expect(parser.hasPendingBytes)
        #expect(parser.finish() == [.passthrough(partial)])
        #expect(!parser.hasPendingBytes)
    }

    @Test("X10 payload bytes are consumed verbatim, even ESC")
    func x10PayloadWithEscape() {
        // Column byte 0x1B would otherwise be read as a new escape.
        let raw: [UInt8] = [0x1B, 0x5B, 0x4D, 0x20, 0x1B, 0x21]
        var parser = MouseStreamParser()
        let out = parser.feed(raw) + parser.finish()
        #expect(!parser.hasPendingBytes)
        // 0x1B < 32 makes the report malformed, but all six bytes come back.
        #expect(passthroughBytes(out) == raw)
    }

    @Test("A doubled escape still parses the report that follows")
    func doubledEscape() {
        var raw = bytes("\u{1B}")
        raw.append(contentsOf: sgr(0, 4, 4, press: true))
        let out = parseAll(raw)
        #expect(passthroughBytes(out) == bytes("\u{1B}"))
        #expect(events(out).count == 1)
    }
}

@Suite("Mouse reporting control sequences")
struct MouseReportingSequenceTests {
    @Test("Enable emits the 1000/1002/1003/1015/1006 set in crossterm order")
    func enableSequence() {
        #expect(ANSIMouse.enableReporting == "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1015h\u{1B}[?1006h")
    }

    @Test("Disable reverses the enable order")
    func disableSequence() {
        #expect(ANSIMouse.disableReporting == "\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l")
    }

    @Test("Tracking reset matches the Rust crash-handler constant")
    func trackingReset() {
        #expect(ANSIMouse.trackingReset == "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1015l\u{1B}[?1006l")
    }

    @Test("Every enabled mode has a matching disable")
    func enableDisableAreBalanced() {
        func modes(_ sequence: String, suffix: Character) -> Set<String> {
            Set(
                sequence.components(separatedBy: "\u{1B}[?")
                    .filter { $0.hasSuffix(String(suffix)) }
                    .map { String($0.dropLast()) }
            )
        }
        let enabled = modes(ANSIMouse.enableReporting, suffix: "h")
        #expect(enabled == ["1000", "1002", "1003", "1015", "1006"])
        #expect(modes(ANSIMouse.disableReporting, suffix: "l") == enabled)
        #expect(modes(ANSIMouse.trackingReset, suffix: "l") == enabled)
    }

    @Test("Focus reporting pairs")
    func focusReporting() {
        #expect(ANSIMouse.enableFocusReporting == "\u{1B}[?1004h")
        #expect(ANSIMouse.disableFocusReporting == "\u{1B}[?1004l")
    }
}

@Suite("Mouse reporting controller")
struct MouseReportingControllerTests {
    @Test("Enable then disable writes each sequence exactly once")
    func enableDisable() throws {
        let writer = MemoryTerminalWriter()
        let controller = MouseReportingController(writer: writer)
        #expect(!controller.isEnabled)

        #expect(try controller.enable())
        #expect(controller.isEnabled)
        #expect(writer.utf8String == ANSIMouse.enableReporting)

        writer.reset()
        #expect(try controller.disable())
        #expect(!controller.isEnabled)
        #expect(writer.utf8String == ANSIMouse.disableReporting)
    }

    @Test("Repeated enable or disable is a no-op")
    func idempotent() throws {
        let writer = MemoryTerminalWriter()
        let controller = MouseReportingController(writer: writer)

        #expect(try controller.disable() == false)
        #expect(writer.buffer.isEmpty)

        #expect(try controller.enable())
        writer.reset()
        #expect(try controller.enable() == false)
        #expect(writer.buffer.isEmpty)
    }

    @Test("forceReset always writes, even when never enabled")
    func forceReset() {
        let writer = MemoryTerminalWriter()
        let controller = MouseReportingController(writer: writer)
        controller.forceReset()
        #expect(writer.utf8String == ANSIMouse.trackingReset)
        #expect(!controller.isEnabled)
    }

    @Test("forceReset after enable clears the enabled flag so teardown is quiet")
    func forceResetAfterEnable() throws {
        let writer = MemoryTerminalWriter()
        let controller = MouseReportingController(writer: writer)
        try controller.enable()
        controller.forceReset()
        #expect(!controller.isEnabled)
        writer.reset()
        #expect(try controller.disable() == false)
        #expect(writer.buffer.isEmpty)
    }
}

@Suite("Mouse wheel tuning")
struct MouseWheelTuningTests {
    @Test("Defaults match the Rust pager")
    func defaults() {
        #expect(MouseWheelTuning.defaultLinesPerTick == 3)
        #expect(MouseWheelTuning.defaultEventsPerTick == 3)
        #expect(MouseWheelTuning().linesPerEvent == 1)
        let fromNil = MouseWheelTuning.forTerminalProgram(nil)
        #expect(fromNil.linesPerTick == 3)
        #expect(fromNil.eventsPerTick == 3)
        #expect(fromNil.linesPerEvent == 1)
    }

    @Test("One-report-per-notch terminals get the full notch distance")
    func singleEventTerminals() {
        // VS Code-family shape: ept=1 with default LPT → 3 lines/report.
        let tuning = MouseWheelTuning(linesPerTick: 3, eventsPerTick: 1)
        #expect(tuning.linesPerEvent == 3)
    }

    @Test("linesPerEvent never rounds down to zero")
    func neverZero() {
        #expect(MouseWheelTuning(linesPerTick: 1, eventsPerTick: 8).linesPerEvent == 1)
    }

    @Test("iTerm.app and WezTerm are 1/1 → one line per report")
    func itermAndWezTermOneLinePerReport() {
        for program in ["iTerm.app", "WezTerm", "iterm2", "iTerm"] {
            let tuning = MouseWheelTuning.forTerminalProgram(program)
            #expect(tuning.linesPerTick == 1, "\(program)")
            #expect(tuning.eventsPerTick == 1, "\(program)")
            #expect(tuning.linesPerEvent == 1, "\(program)")
        }
    }

    @Test("forTerminalProgram covers every named terminal explicitly")
    func terminalLookup() {
        // iTerm / WezTerm: both fields drop to 1 (Rust mouse.rs:340,337 + 367).
        assertTuning("iTerm.app", lines: 1, events: 1, perEvent: 1)
        assertTuning("WezTerm", lines: 1, events: 1, perEvent: 1)

        // VS Code family + Zed: ept=1, default LPT (Rust:341-344; LPT stays 3).
        assertTuning("vscode", lines: 3, events: 1, perEvent: 3)
        assertTuning("cursor", lines: 3, events: 1, perEvent: 3)
        assertTuning("windsurf", lines: 3, events: 1, perEvent: 3)
        assertTuning("zed", lines: 3, events: 1, perEvent: 3)

        // Default 3/3 brands / unknown (Rust AppleTerminal/Warp/Ghostty/Kitty/…).
        assertTuning("Apple_Terminal", lines: 3, events: 3, perEvent: 1)
        assertTuning("WarpTerminal", lines: 3, events: 3, perEvent: 1)
        assertTuning("Ghostty", lines: 3, events: 3, perEvent: 1)
        assertTuning("kitty", lines: 3, events: 3, perEvent: 1)
        assertTuning("Alacritty", lines: 3, events: 3, perEvent: 1)
        assertTuning(nil, lines: 3, events: 3, perEvent: 1)

        // Compatibility helper delegates to the factory's events field.
        #expect(MouseWheelTuning.eventsPerTick(forTerminalProgram: "iTerm.app") == 1)
        #expect(MouseWheelTuning.eventsPerTick(forTerminalProgram: "WezTerm") == 1)
        #expect(MouseWheelTuning.eventsPerTick(forTerminalProgram: "vscode") == 1)
        #expect(MouseWheelTuning.eventsPerTick(forTerminalProgram: "Apple_Terminal") == 3)
        #expect(MouseWheelTuning.eventsPerTick(forTerminalProgram: nil) == 3)
    }

    @Test("Zero or negative inputs are clamped to one")
    func clamping() {
        let tuning = MouseWheelTuning(linesPerTick: 0, eventsPerTick: -4)
        #expect(tuning.linesPerTick == 1)
        #expect(tuning.eventsPerTick == 1)
    }

    private func assertTuning(
        _ program: String?,
        lines: Int,
        events: Int,
        perEvent: Int
    ) {
        let tuning = MouseWheelTuning.forTerminalProgram(program)
        let label = program ?? "nil"
        #expect(tuning.linesPerTick == lines, "\(label) linesPerTick")
        #expect(tuning.eventsPerTick == events, "\(label) eventsPerTick")
        #expect(tuning.linesPerEvent == perEvent, "\(label) linesPerEvent")
    }
}
