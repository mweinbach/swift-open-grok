import Foundation
import Testing
@testable import OpenGrokTTY

#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#endif

@Suite("Terminal input")
struct TerminalInputTests {
    @Test("incremental decoder emits UTF-8 text and control keys")
    func decodesTextAndControls() throws {
        var decoder = TerminalInputDecoder()
        var events: [TerminalInputEvent] = []
        let input = Data([0x41, 0x08, 0x09, 0x0d, 0x03, 0xc3, 0xa9, 0x7f])

        for byte in input {
            events.append(contentsOf: try decoder.feed(byte))
        }

        #expect(events == [
            .text("A"),
            .control(.backspace),
            .control(.tab),
            .control(.enter),
            .control(.interrupt),
            .text("é"),
            .control(.backspace),
        ])
    }

    @Test("decoder maps CSI, SS3, modifiers, function keys, and bracketed paste")
    func decodesEscapeSequences() throws {
        var decoder = TerminalInputDecoder()
        var events: [TerminalInputEvent] = []
        let input = Data([
            0x1b, 0x5b, 0x41,
            0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44,
            0x1b, 0x5b, 0x31, 0x35, 0x7e,
            0x1b, 0x4f, 0x50,
            0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e,
            0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e,
        ])

        for byte in input {
            events.append(contentsOf: try decoder.feed(byte))
        }

        #expect(events == [
            .key(.named(.up, modifiers: [])),
            .key(.named(.left, modifiers: .control)),
            .key(.named(.function(5), modifiers: [])),
            .key(.named(.function(1), modifiers: [])),
            .pasteStart,
            .pasteEnd,
        ])
    }

    @Test("decoder preserves a bare escape and rejects malformed UTF-8")
    func handlesIncompleteInput() throws {
        var decoder = TerminalInputDecoder()
        #expect(try decoder.feed(0x1b).isEmpty)
        #expect(try decoder.finish() == [.control(.escape)])

        do {
            _ = try decoder.feed(0xc3)
            _ = try decoder.feed(0x28)
            Issue.record("malformed UTF-8 should throw")
        } catch TerminalInputError.invalidUTF8 {
        }

        #expect(try decoder.feed(0x78) == [.text("x")])
    }

    /// `ESC [ M Cb Cx Cy` — each payload byte is `value + 32`.
    private func x10Report(button: Int, column: Int, row: Int) -> [UInt8] {
        [
            0x1b, 0x5b, 0x4d,
            UInt8(button + 32),
            UInt8(column + 32),
            UInt8(row + 32),
        ]
    }

    private func feedAll(
        _ bytes: [UInt8],
        into decoder: inout TerminalInputDecoder
    ) throws -> [TerminalInputEvent] {
        var events: [TerminalInputEvent] = []
        for byte in bytes {
            let produced = try decoder.feed(byte)
            events.append(contentsOf: produced)
        }
        return events
    }

    @Test("X10 click becomes one intact unknown event with zero text")
    func x10ClickEmitsIntactUnknown() throws {
        var decoder = TerminalInputDecoder()
        let report = x10Report(button: 0, column: 3, row: 7)
        let events = try feedAll(report, into: &decoder)

        #expect(events == [.unknown(Data(report))])
        #expect(events.filter { if case .text = $0 { true } else { false } }.isEmpty)
        #expect(!decoder.hasPendingEscapeSequence)

        // Following text must not be swallowed by a stuck X10 state.
        #expect(try decoder.feed(0x41) == [.text("A")])
    }

    @Test("X10 wheel becomes one intact unknown event with zero text")
    func x10WheelEmitsIntactUnknown() throws {
        var decoder = TerminalInputDecoder()
        let report = x10Report(button: 64, column: 10, row: 5)
        let events = try feedAll(report, into: &decoder)

        #expect(events == [.unknown(Data(report))])
        #expect(events.filter { if case .text = $0 { true } else { false } }.isEmpty)
    }

    @Test("X10 reports survive byte-by-byte split feeds")
    func x10SplitFeedStaysIntact() throws {
        var decoder = TerminalInputDecoder()
        let report = x10Report(button: 0, column: 10, row: 5)
        var events: [TerminalInputEvent] = []
        for byte in report {
            let produced = try decoder.feed(byte)
            #expect(produced.filter { if case .text = $0 { true } else { false } }.isEmpty)
            events.append(contentsOf: produced)
            if events.isEmpty {
                #expect(decoder.hasPendingEscapeSequence)
            }
        }
        #expect(events == [.unknown(Data(report))])
        #expect(!decoder.hasPendingEscapeSequence)
    }

    @Test("truncated X10 finish returns buffered bytes without hanging")
    func x10FinishReturnsPartialHonestly() throws {
        var decoder = TerminalInputDecoder()
        // ESC [ M and one payload byte — two short of a full report.
        let partial: [UInt8] = [0x1b, 0x5b, 0x4d, 0x20]
        #expect(try feedAll(partial, into: &decoder).isEmpty)
        #expect(decoder.hasPendingEscapeSequence)

        let finished = try decoder.finish()
        #expect(finished == [.unknown(Data(partial))])
        #expect(!decoder.hasPendingEscapeSequence)

        // Decoder is usable again; unrelated text is not swallowed.
        #expect(try decoder.feed(0x7a) == [.text("z")])
    }

    @Test("X10 payload bytes are not re-scanned as escapes or UTF-8")
    func x10PayloadBytesConsumedVerbatim() throws {
        var decoder = TerminalInputDecoder()
        // Column 0x1B would otherwise open a new escape; 0xC3 would start UTF-8.
        let report: [UInt8] = [0x1b, 0x5b, 0x4d, 0x20, 0x1b, 0xc3]
        let events = try feedAll(report, into: &decoder)
        #expect(events == [.unknown(Data(report))])
        #expect(events.filter { if case .text = $0 { true } else { false } }.isEmpty)
        #expect(try decoder.finish().isEmpty)
    }

    @Test("SGR mouse final M is unchanged and still one unknown")
    func sgrMouseStillUnknown() throws {
        var decoder = TerminalInputDecoder()
        let sgr = Array("\u{1B}[<0;3;7M".utf8)
        let events = try feedAll(sgr, into: &decoder)
        #expect(events == [.unknown(Data(sgr))])
    }

    @Test("X10 ignores maxSequenceLength < 6 and never leaks payload as text")
    func x10MaxSequenceBound() throws {
        // A generic CSI ceiling of 4 is below the fixed 6-byte X10 length.
        // The `.x10` arm must still buffer the full report — flushing mid-
        // payload would emit Cx/Cy as `.text` / composer keys.
        var decoder = TerminalInputDecoder(maxSequenceLength: 4)
        let report = x10Report(button: 0, column: 3, row: 7)
        let events = try feedAll(report, into: &decoder)

        #expect(events == [.unknown(Data(report))])
        #expect(events.filter { if case .text = $0 { true } else { false } }.isEmpty)
        #expect(events.filter { if case .key = $0 { true } else { false } }.isEmpty)
        #expect(!decoder.hasPendingEscapeSequence)
        // Ordinary text after a complete report must still decode normally.
        #expect(try decoder.feed(0x42) == [.text("B")])
    }

    #if os(macOS) || os(Linux)
    @Test("POSIX input reads decoded events from a pipe")
    func posixReadsEvents() async throws {
        let descriptors = try makePipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(
            fd: descriptors.read,
            escapeSequenceTimeoutMilliseconds: 10
        )
        let bytes = Data([
            0xc3, 0xa9,
            0x1b, 0x5b, 0x43,
            0x03,
        ])
        writeAll(bytes, to: descriptors.write)

        var events: [TerminalInputEvent] = []
        for _ in 0..<3 {
            if let event = try await input.readEvent() {
                events.append(event)
            }
        }

        #expect(events == [
            .text("é"),
            .key(.named(.right, modifiers: [])),
            .control(.interrupt),
        ])
    }

    @Test("POSIX byte reads are cancellable without closing the fd")
    func posixReadCancellation() async throws {
        let descriptors = try makePipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        let pendingRead = Task {
            try await input.readByte()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        pendingRead.cancel()

        do {
            _ = try await pendingRead.value
            Issue.record("cancelled read should throw")
        } catch TerminalInputError.cancelled {
        }

        let nextRead = Task {
            try await input.readByte()
        }
        writeAll(Data([0x71]), to: descriptors.write)
        #expect(try await nextRead.value == 0x71)
    }

    @Test("closing POSIX input wakes a blocked read")
    func posixCloseWakesRead() async throws {
        let descriptors = try makePipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)
        let pendingRead = Task {
            try await input.readByte()
        }

        await input.close()

        do {
            _ = try await pendingRead.value
            Issue.record("closed input should throw")
        } catch TerminalInputError.cancelled, TerminalInputError.closed {
        }
    }

    @Test("POSIX byte reads return nil at EOF")
    func posixEOF() async throws {
        let descriptors = try makePipe()
        close(descriptors.write)
        defer { close(descriptors.read) }
        let input = try PosixTerminalInput(fd: descriptors.read)

        #expect(try await input.readByte() == nil)
    }

    @Test("POSIX resize monitor stops without installing a signal handler")
    func resizeMonitorStopsCleanly() async throws {
        let descriptors = try makePipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let monitor = PosixTerminalResizeMonitor(
            fd: descriptors.read,
            pollIntervalMilliseconds: 5
        )
        let stream = monitor.events()
        var iterator = stream.makeAsyncIterator()
        monitor.stop()

        #expect(await iterator.next() == nil)
    }
    #endif
}

#if os(macOS) || os(Linux)
private func makePipe() throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        throw TerminalInputError.ioFailed(
            "pipe failed: \(String(cString: strerror(errno)))"
        )
    }
    return (descriptors[0], descriptors[1])
}

private func writeAll(_ data: Data, to fd: Int32) {
    data.withUnsafeBytes { raw in
        guard let baseAddress = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let result = write(fd, baseAddress.advanced(by: offset), raw.count - offset)
            if result > 0 {
                offset += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
#endif
