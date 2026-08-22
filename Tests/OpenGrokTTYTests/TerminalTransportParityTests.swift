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

@Suite("Terminal transport protocol parity")
struct TerminalTransportParityTests {
    private func decode(
        _ input: String,
        using decoder: inout TerminalInputDecoder
    ) throws -> [TerminalInputEvent] {
        var events: [TerminalInputEvent] = []
        for byte in input.utf8 {
            events.append(contentsOf: try decoder.feed(byte))
        }
        return events
    }

    private func pastedText(_ events: [TerminalInputEvent]) -> String {
        events.reduce(into: "") { result, event in
            if case .text(let text) = event {
                result.append(text)
            }
        }
    }

    @Test("Kitty CSI-u printable keys preserve modifiers and alternate codepoints")
    func kittyPrintableKeys() throws {
        var decoder = TerminalInputDecoder()
        let events = try decode(
            "\u{1B}[97u"
                + "\u{1B}[97;2u"
                + "\u{1B}[97;7u"
                + "\u{1B}[57:40;4u"
                + "\u{1B}[128512;1u"
                + "\u{1B}[97;9u"
                + "\u{1B}[97;33u",
            using: &decoder
        )

        #expect(events == [
            .key(.character("a", modifiers: [])),
            .key(.character("A", modifiers: .shift)),
            .key(.character("a", modifiers: [.alt, .control])),
            .key(.character("(", modifiers: .alt)),
            .key(.character("😀", modifiers: [])),
            .key(.character("a", modifiers: .superKey)),
            .key(.character("a", modifiers: .meta)),
        ])
    }

    @Test("Kitty CSI-u preserves modifiers on Enter, Tab, Backspace, and Escape")
    func kittyModifiedControlKeys() throws {
        var decoder = TerminalInputDecoder()
        let events = try decode(
            "\u{1B}[13;5u"
                + "\u{1B}[13;2u"
                + "\u{1B}[9;2u"
                + "\u{1B}[127;3u"
                + "\u{1B}[27;5u"
                + "\u{1B}[57414;5u",
            using: &decoder
        )

        #expect(events == [
            .key(.named(.enter, modifiers: .control)),
            .key(.named(.enter, modifiers: .shift)),
            .key(.named(.tab, modifiers: .shift)),
            .key(.named(.backspace, modifiers: .alt)),
            .key(.named(.escape, modifiers: .control)),
            .key(.named(.enter, modifiers: .control)),
        ])
    }

    @Test("Kitty releases never become duplicate submits or navigation presses")
    func kittyReleaseEventsAreSuppressed() throws {
        var decoder = TerminalInputDecoder()
        let events = try decode(
            "\u{1B}[13;5:1u"
                + "\u{1B}[13;5:3u"
                + "\u{1B}[97;1:2u"
                + "\u{1B}[97;1:3u"
                + "\u{1B}[1;5:3A"
                + "\u{1B}[1;5:2A"
                + "z",
            using: &decoder
        )

        #expect(events == [
            .key(.named(.enter, modifiers: .control)),
            .key(.character("a", modifiers: [])),
            .key(.named(.up, modifiers: .control)),
            .text("z"),
        ])
    }

    @Test("Kitty private-use keypad and extended function keys decode honestly")
    func kittyFunctionalKeys() throws {
        var decoder = TerminalInputDecoder()
        let events = try decode(
            "\u{1B}[57376u"
                + "\u{1B}[57398u"
                + "\u{1B}[57399u"
                + "\u{1B}[57408u"
                + "\u{1B}[57419;2u"
                + "\u{1B}[57426;5u",
            using: &decoder
        )

        #expect(events == [
            .key(.named(.function(13), modifiers: [])),
            .key(.named(.function(35), modifiers: [])),
            .key(.character("0", modifiers: [])),
            .key(.character("9", modifiers: [])),
            .key(.named(.up, modifiers: .shift)),
            .key(.named(.delete, modifiers: .control)),
        ])
    }

    @Test("Malformed Kitty reports stay intact and never poison following text")
    func malformedKittyReportsRemainUnknown() throws {
        let reports = [
            "\u{1B}[u",
            "\u{1B}[?1u",
            "\u{1B}[1114112u",
            "\u{1B}[55296u",
            "\u{1B}[97;0u",
            "\u{1B}[97;257u",
            "\u{1B}[97;1:4u",
            "\u{1B}[57358u",
            "\u{1B}[999999999999999999999999999u",
        ]

        for report in reports {
            var decoder = TerminalInputDecoder()
            let events = try decode(report + "x", using: &decoder)
            #expect(events == [.unknown(Data(report.utf8)), .text("x")])
            #expect(!decoder.hasPendingEscapeSequence)
        }
    }

    @Test("Complete CSI focus reports are routed rather than silently discarded")
    func completeFocusReports() throws {
        var decoder = TerminalInputDecoder()
        let events = try decode(
            "\u{1B}[I\u{1B}[O\u{1B}[1I",
            using: &decoder
        )

        #expect(events == [
            .focusGained,
            .focusLost,
            .unknown(Data("\u{1B}[1I".utf8)),
        ])
    }

    @Test("Alt-prefixed three- and four-byte UTF-8 characters survive split reads")
    func altModifiedMultibyteCharacters() throws {
        var decoder = TerminalInputDecoder()
        let events = try decode("\u{1B}€\u{1B}😀", using: &decoder)

        #expect(events == [
            .key(.character("€", modifiers: .alt)),
            .key(.character("😀", modifiers: .alt)),
        ])
    }

    @Test("Bracketed paste keeps line endings, tabs, interrupts, and ESC literal")
    func bracketedPasteTreatsControlsAsData() throws {
        var decoder = TerminalInputDecoder()
        let payload = "first\r\nsecond\t\u{03} third\u{1B}[2D 😀"
        let events = try decode(
            "\u{1B}[200~" + payload + "\u{1B}[201~\r",
            using: &decoder
        )

        #expect(events.first == .pasteStart)
        #expect(Array(events.suffix(2)) == [.pasteEnd, .control(.enter)])
        #expect(pastedText(events) == payload)
        #expect(!events.contains(.control(.interrupt)))
        #expect(events.filter { $0 == .control(.enter) }.count == 1)
    }

    @Test("False and overlapping paste terminators are preserved without leaking keys")
    func bracketedPasteTerminatorMatching() throws {
        var decoder = TerminalInputDecoder()
        let payload = "before\u{1B}[20x\u{1B}[20\u{1B}[201xafter"
        let events = try decode(
            "\u{1B}[200~" + payload + "\u{1B}[201~",
            using: &decoder
        )

        #expect(events.first == .pasteStart)
        #expect(events.last == .pasteEnd)
        #expect(pastedText(events) == payload)
        #expect(!events.contains { event in
            if case .key = event { return true }
            if case .unknown = event { return true }
            return false
        })
    }

    @Test("Byte-split paste terminators never leak partial delimiters")
    func byteSplitPasteTerminator() throws {
        var decoder = TerminalInputDecoder()
        #expect(try decode("\u{1B}[200~hello", using: &decoder).last == .text("o"))

        let terminator = Array("\u{1B}[201~".utf8)
        for byte in terminator.dropLast() {
            #expect(try decoder.feed(byte).isEmpty)
            #expect(decoder.hasPendingEscapeSequence)
        }
        #expect(try decoder.feed(terminator.last!) == [.pasteEnd])
        #expect(!decoder.hasPendingEscapeSequence)
        #expect(try decoder.feed(0x0d) == [.control(.enter)])
    }

    @Test("Partial pasted ESC flushes literally while keeping the paste open")
    func incompletePasteTerminatorFlush() throws {
        var decoder = TerminalInputDecoder()
        #expect(try decode("\u{1B}[200~", using: &decoder) == [.pasteStart])
        #expect(try decode("\u{1B}[20", using: &decoder).isEmpty)
        #expect(try decoder.finish() == [.text("\u{1B}[20")])
        #expect(try decode("rest\u{1B}[201~", using: &decoder).last == .pasteEnd)
    }

    @Test("Large bracketed pastes stream without hitting the CSI sequence ceiling")
    func largePasteStreamsWithoutBuffering() throws {
        var decoder = TerminalInputDecoder(maxSequenceLength: 8)
        #expect(try decode("\u{1B}[200~", using: &decoder) == [.pasteStart])

        for _ in 0..<16_384 {
            #expect(try decoder.feed(0x61) == [.text("a")])
        }

        #expect(try decode("\u{1B}[201~", using: &decoder) == [.pasteEnd])
    }

    #if os(macOS) || os(Linux)
    @Test("Live POSIX input preserves pasted mouse-like text and DCS probe replies")
    func posixPasteBypassesControlFilters() async throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw TerminalInputError.ioFailed("pipe failed")
        }
        let readFD = descriptors[0]
        let writeFD = descriptors[1]
        defer { close(readFD) }

        let payload = "first\n[<0;3;7M\u{1B}P>|kitty 1\u{1B}\\\tlast"
        let wire = Data(("\u{1B}[200~" + payload + "\u{1B}[201~\r").utf8)
        let count = wire.withUnsafeBytes { raw in
            write(writeFD, raw.baseAddress, raw.count)
        }
        close(writeFD)
        #expect(count == wire.count)

        let input = try PosixTerminalInput(
            fd: readFD,
            escapeSequenceTimeoutMilliseconds: 10,
            swallowXtversionReply: true
        )
        var events: [TerminalInputEvent] = []
        while let event = try await input.readEvent() {
            events.append(event)
        }

        #expect(events.first == .pasteStart)
        #expect(Array(events.suffix(2)) == [.pasteEnd, .control(.enter)])
        #expect(pastedText(events) == payload)
        #expect(input.lastSwallowedXtversionPayload == nil)
    }

    @Test("A lone typed bracket reaches the live input without another keystroke")
    func posixLoneBracketIsImmediate() async throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw TerminalInputError.ioFailed("pipe failed")
        }
        defer { close(descriptors[0]) }
        var bracket: UInt8 = 0x5b
        #expect(write(descriptors[1], &bracket, 1) == 1)
        close(descriptors[1])

        let input = try PosixTerminalInput(fd: descriptors[0])
        #expect(try await input.readEvent() == .text("["))
        #expect(try await input.readEvent() == nil)
    }
    #endif
}
