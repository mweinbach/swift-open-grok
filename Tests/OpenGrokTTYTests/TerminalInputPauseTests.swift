// TerminalInputPauseTests.swift
//
// The suspend-for-child park primitive on `PosixTerminalInput`
// (`park_input_reader`, event_loop.rs:326-348), driven over a pipe(2) pair
// the way `TerminalInputTests` drives reads. Every status-returning call is
// asserted at the step it happens (AGENTS.md §3).

import Foundation
import Testing
@testable import OpenGrokTTY

#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Terminal input pause/resume")
struct TerminalInputPauseTests {
    @Test("a paused input withholds bytes and resume delivers them")
    func pauseWithholdsBytesUntilResume() async throws {
        let descriptors = try makePauseTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        #expect(await input.pauseReads())
        writePauseTestBytes(Data([0x61]), to: descriptors.write)

        let delivered = DeliveryFlag()
        let readTask = Task {
            let event = try await input.readEvent()
            delivered.mark()
            return event
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!delivered.isSet)

        input.resumeReads()
        #expect(try await readTask.value == .text("a"))
    }

    @Test("discardPendingInput while paused drops the child's leftover bytes")
    func discardDropsBufferedJunk() async throws {
        let descriptors = try makePauseTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        #expect(await input.pauseReads())
        // A DA reply — the junk a child's exit leaves in the tty buffer
        // (event_loop.rs:407-411).
        writePauseTestBytes(Data("\u{1B}[?1;2c".utf8), to: descriptors.write)
        input.discardPendingInput()
        input.resumeReads()

        writePauseTestBytes(Data([0x7A]), to: descriptors.write)
        #expect(try await input.readEvent() == .text("z"))
    }

    @Test("pause acks while a read is blocked in poll, and the read survives")
    func pauseParksBlockedRead() async throws {
        let descriptors = try makePauseTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        let delivered = DeliveryFlag()
        let readTask = Task {
            let event = try await input.readEvent()
            delivered.mark()
            return event
        }
        // Let the read reach poll(2) before parking it.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await input.pauseReads())

        writePauseTestBytes(Data([0x71]), to: descriptors.write)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!delivered.isSet)

        input.resumeReads()
        #expect(try await readTask.value == .text("q"))
    }

    @Test("close during a pause still terminates the parked read")
    func closeDuringPauseTerminates() async throws {
        let descriptors = try makePauseTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        let readTask = Task {
            try await input.readEvent()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await input.pauseReads())

        await input.close()
        do {
            _ = try await readTask.value
            Issue.record("a closed input should throw")
        } catch TerminalInputError.cancelled, TerminalInputError.closed {
        }
    }
}

/// Cross-task completion flag for "the read has NOT finished yet" assertions.
private final class DeliveryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func mark() {
        lock.lock()
        set = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return set
    }
}

private func makePauseTestPipe() throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        throw TerminalInputError.ioFailed(
            "pipe failed: \(String(cString: strerror(errno)))"
        )
    }
    return (descriptors[0], descriptors[1])
}

private func writePauseTestBytes(_ data: Data, to fd: Int32) {
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
