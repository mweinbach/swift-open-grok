// XtversionInputFilterTests.swift
//
// Fire-and-forget XTVERSION swallow on the TTY byte path
// (`PlatformTerminalInput.readEvent` → `XtversionReplyFilter`).
// Pin: xtversion.rs:5-9, xt_filter.rs — DCS > | text ST must not type
// into the composer. No stdin, no timed probe read.

import Foundation
import Testing
@testable import OpenGrokTTY

#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("XTVERSION input filter")
struct XtversionInputFilterTests {
    @Test("default-armed input swallows a DCS reply and delivers following keys")
    func swallowsReplyAndDeliversFollowingKeys() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(
            fd: descriptors.read,
            escapeSequenceTimeoutMilliseconds: 20
        )
        #expect(input.isXtversionReplyFilterArmed)

        var bytes = dcsReply("kitty 0.35.2")
        bytes.append(contentsOf: [0x61, 0x62])
        writeXtversionTestBytes(Data(bytes), to: descriptors.write)

        #expect(try await input.readEvent() == .text("a"))
        #expect(try await input.readEvent() == .text("b"))
        #expect(input.lastSwallowedXtversionPayload == "kitty 0.35.2")
        #expect(!input.isXtversionReplyFilterArmed)
    }

    @Test("typeahead before the DCS survives as residual")
    func typeaheadBeforeReplySurvives() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        var bytes: [UInt8] = [0x68, 0x69]
        bytes.append(contentsOf: dcsReply("WezTerm 20240203-110809"))
        bytes.append(0x21)
        writeXtversionTestBytes(Data(bytes), to: descriptors.write)

        #expect(try await input.readEvent() == .text("h"))
        #expect(try await input.readEvent() == .text("i"))
        #expect(try await input.readEvent() == .text("!"))
        #expect(input.lastSwallowedXtversionPayload == "WezTerm 20240203-110809")
    }

    @Test("split DCS fragments hold across reads then leave following text")
    func splitReplyHoldsThenReleasesText() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        var prefix = dcsReply("foot(1.22.0)")
        prefix.removeLast()
        writeXtversionTestBytes(Data(prefix), to: descriptors.write)
        writeXtversionTestBytes(Data([0x5C, 0x7A]), to: descriptors.write)

        #expect(try await input.readEvent() == .text("z"))
        #expect(input.lastSwallowedXtversionPayload == "foot(1.22.0)")
        #expect(!input.isXtversionReplyFilterArmed)
    }

    @Test("BEL-terminated DCS is swallowed")
    func belTerminatorIsSwallowed() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        var bytes = dcsReply("st 0.9", terminator: .bel)
        bytes.append(0x78)
        writeXtversionTestBytes(Data(bytes), to: descriptors.write)

        #expect(try await input.readEvent() == .text("x"))
        #expect(input.lastSwallowedXtversionPayload == "st 0.9")
    }

    @Test("CRLF after a reply reaches the decoder as two enter bytes")
    func crlfAfterReplyIsTwoBytes() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        var bytes = dcsReply("XTerm(388)")
        bytes.append(contentsOf: [0x0D, 0x0A])
        writeXtversionTestBytes(Data(bytes), to: descriptors.write)

        #expect(try await input.readEvent() == .control(.enter))
        #expect(try await input.readEvent() == .control(.enter))
        #expect(input.lastSwallowedXtversionPayload == "XTerm(388)")
    }

    @Test("unterminated reply then slash drops the fragment")
    func unterminatedThenSlashIsNotEaten() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)

        var bytes = dcsReply("x")
        bytes.removeLast()
        bytes.removeLast()
        bytes.append(0x2F)
        writeXtversionTestBytes(Data(bytes), to: descriptors.write)

        #expect(try await input.readEvent() == .text("/"))
        #expect(input.lastSwallowedXtversionPayload == nil)
    }

    @Test("CSI arrow still decodes while the filter is armed")
    func armedFilterDoesNotEatCSI() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)
        #expect(input.isXtversionReplyFilterArmed)

        writeXtversionTestBytes(Data([0x1B, 0x5B, 0x43]), to: descriptors.write)
        #expect(try await input.readEvent() == .key(.named(.right, modifiers: [])))
        #expect(input.isXtversionReplyFilterArmed)
        #expect(input.lastSwallowedXtversionPayload == nil)
    }

    @Test("held ESC flushes on the existing escape timeout")
    func heldEscapeFlushesWithoutBlockingOnReply() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(
            fd: descriptors.read,
            escapeSequenceTimeoutMilliseconds: 20
        )
        writeXtversionTestBytes(Data([0x1B]), to: descriptors.write)
        #expect(try await input.readEvent() == .control(.escape))
        #expect(input.isXtversionReplyFilterArmed)
    }

    @Test("init flag disables swallowing so DCS reaches the decoder")
    func initFlagDisablesSwallow() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(
            fd: descriptors.read,
            swallowXtversionReply: false
        )
        #expect(!input.isXtversionReplyFilterArmed)

        writeXtversionTestBytes(Data(dcsReply("kitty 0.35.2")), to: descriptors.write)
        #expect(try await input.readEvent() == .key(.character("P", modifiers: .alt)))
        #expect(input.lastSwallowedXtversionPayload == nil)
    }

    @Test("package-visible setter disarms an already constructed input")
    func setterDisarmsFilter() async throws {
        let descriptors = try makeXtversionTestPipe()
        defer {
            close(descriptors.read)
            close(descriptors.write)
        }
        let input = try PosixTerminalInput(fd: descriptors.read)
        #expect(input.isXtversionReplyFilterArmed)
        input.setSwallowXtversionReply(false)
        #expect(!input.isXtversionReplyFilterArmed)

        writeXtversionTestBytes(Data(dcsReply("kitty 0.35.2")), to: descriptors.write)
        #expect(try await input.readEvent() == .key(.character("P", modifiers: .alt)))
        #expect(input.lastSwallowedXtversionPayload == nil)
    }
}

/// 7-bit DCS reply `ESC P > | <payload> ESC \`, or BEL / 8-bit ST.
private func dcsReply(
    _ payload: String,
    terminator: XtversionDcsTerminator = .sevenBitST
) -> [UInt8] {
    var bytes: [UInt8] = [0x1B, 0x50, 0x3E, 0x7C]
    bytes.append(contentsOf: payload.utf8)
    switch terminator {
    case .sevenBitST:
        bytes.append(contentsOf: [0x1B, 0x5C])
    case .eightBitST:
        bytes.append(0x9C)
    case .bel:
        bytes.append(0x07)
    }
    return bytes
}

private enum XtversionDcsTerminator {
    case sevenBitST
    case eightBitST
    case bel
}

private func makeXtversionTestPipe() throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        throw TerminalInputError.ioFailed(
            "pipe failed: \(String(cString: strerror(errno)))"
        )
    }
    return (descriptors[0], descriptors[1])
}

private func writeXtversionTestBytes(_ data: Data, to fd: Int32) {
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
