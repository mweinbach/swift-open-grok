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
