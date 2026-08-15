// Da2Tests.swift
//
// DA2 parse/unpack tests. No stdin, no raw mode, no live TTY.
//
// Pin: crates/codegen/xai-grok-pager-render/src/terminal/da2.rs tests
// @ 650c1db7.

import Foundation
import Testing
@testable import OpenGrokTerminalCore

private func parsed(_ reply: String) -> (UInt32, String)? {
    let version = parseDa2Reply(Array(reply.utf8))
    return version.map { ($0.packed, $0.text) }
}

private func parsed(_ reply: [UInt8]) -> (UInt32, String)? {
    let version = parseDa2Reply(reply)
    return version.map { ($0.packed, $0.text) }
}

@Suite("DA2 probe parse and unpack")
struct Da2Tests {

    @Test("Query bytes are CSI > 0 c")
    func queryBytes() {
        #expect(DA2_QUERY == [0x1B, 0x5B, 0x3E, 0x30, 0x63])
        #expect(Array(DA2_QUERY_STRING.utf8) == DA2_QUERY)
        #expect(DA2_REPLY_TIMEOUT_MILLISECONDS == 500)
        #expect(DA2_MAX_PACKED_VERSION == 999_999)
        #expect(DA2_MAX_PROBE_RESPONSE == 256)
        #expect(DA2_LATE_REPLY_GRACE_MILLISECONDS == 100)
        #expect(DA2_LATE_REPLY_QUIET_MILLISECONDS == 25)
    }

    @Test("unpack 2401 is 0.24.1")
    func unpack2401() {
        let version = unpackDa2Version(2401)
        #expect(version?.packed == 2401)
        #expect(version?.major == 0)
        #expect(version?.minor == 24)
        #expect(version?.patch == 1)
        #expect(version?.text == "0.24.1")
    }

    @Test("packed version round trips")
    func packedVersionRoundTrips() {
        // Real `alacritty_terminal` versions, not the releases they ship in:
        // 0.21 is Alacritty 0.13.x; 0.25 is 0.15.1+ (0.15.0 still shipped 0.24.2).
        #expect(parsed("\u{1B}[>0;2100;1c")?.0 == 2100)
        #expect(parsed("\u{1B}[>0;2100;1c")?.1 == "0.21.0")
        #expect(parsed("\u{1B}[>0;2500;1c")?.0 == 2500)
        #expect(parsed("\u{1B}[>0;2500;1c")?.1 == "0.25.0")
        #expect(parsed("\u{1B}[>0;2601;1c")?.0 == 2601)
        #expect(parsed("\u{1B}[>0;2601;1c")?.1 == "0.26.1")
        #expect(parsed("\u{1B}[>0;2401;1c")?.0 == 2401)
        #expect(parsed("\u{1B}[>0;2401;1c")?.1 == "0.24.1")
        // Typeahead consumed ahead of the reply: the last `>` is still the
        // reply's, so its parameters are what get parsed.
        #expect(parsed("ls > out.c\u{1B}[>0;2500;1c")?.0 == 2500)
        #expect(parsed("ls > out.c\u{1B}[>0;2500;1c")?.1 == "0.25.0")
    }

    @Test("parse valid CSI > reply")
    func parseValidCsiGreaterReply() {
        let version = parseDa2Reply(Array("\u{1B}[>0;2401;1c".utf8))
        #expect(version != nil)
        #expect(version?.packed == 2401)
        #expect(version?.text == "0.24.1")
        #expect(version?.major == 0)
        #expect(version?.minor == 24)
        #expect(version?.patch == 1)
    }

    @Test("another emulator's DA2 is not a version")
    func anotherEmulatorsDa2IsNotAVersion() {
        // xterm's `Pv` is a patch level and VTE's is its own numbering; both
        // would otherwise decode cleanly.
        #expect(parseDa2Reply(Array("\u{1B}[>41;389;0c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0;388;0c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>65;6003;1c".utf8)) == nil)
    }

    @Test("truncated and garbage replies are nil")
    func undecodablePayloadsAreNone() {
        #expect(parseDa2Reply(Array("c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0;;1c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[?62;1;6c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0;abc;1c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0;-1;1c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0;0;1c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0;4294967295;1c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0;99999999999999999999;1c".utf8)) == nil)
        #expect(parseDa2Reply(Array("\u{1B}[>0;1000000;1c".utf8)) == nil)

        var invalidUTF8: [UInt8] = [0x1B, 0x5B, 0x3E, 0x30, 0x3B]
        invalidUTF8.append(contentsOf: [0xFF, 0xFE])
        invalidUTF8.append(contentsOf: [0x3B, 0x31, 0x63])
        #expect(parseDa2Reply(invalidUTF8) == nil)
    }

    @Test("empty and no-reply are nil not packed 0")
    func emptyAndNoReplyAreNilNotZero() {
        #expect(parseDa2Reply(Optional<[UInt8]>.none) == nil)
        #expect(parseDa2Reply([UInt8]()) == nil)
        #expect(parseDa2Reply(Array("".utf8)) == nil)
        #expect(unpackDa2Version(0) == nil)
        #expect(consumeDa2Reply([]) == nil)

        let consumed = consumeDa2Reply([])
        #expect(consumed == nil)
        #expect(parseDa2Reply(consumed) == nil)
    }

    @Test("consume stops at DA2 terminator and respects the buffer cap")
    func consumeStopsAtTerminator() {
        let reply = Array("\u{1B}[>0;2401;1cTRAILING".utf8)
        let consumed = consumeDa2Reply(reply)
        #expect(consumed == Array("\u{1B}[>0;2401;1c".utf8))
        let version = parseDa2Reply(consumed)
        #expect(version?.packed == 2401)
        #expect(version?.text == "0.24.1")

        // Typeahead `ls > out.c` is not a terminator: intro `ESC [ >` is required.
        let typeahead = Array("ls > out.c".utf8)
        #expect(da2ReplyIsComplete(buffer: typeahead, lastByte: 0x63) == false)
        let typeaheadThenReply = Array("ls > out.c\u{1B}[>0;2500;1c".utf8)
        let consumedTypeahead = consumeDa2Reply(typeaheadThenReply)
        #expect(consumedTypeahead == typeaheadThenReply)
        #expect(parseDa2Reply(consumedTypeahead)?.packed == 2500)

        var oversized = [UInt8](repeating: 0x41, count: DA2_MAX_PROBE_RESPONSE + 16)
        oversized[0] = 0x1B
        let capped = consumeDa2Reply(oversized)
        #expect(capped?.count == DA2_MAX_PROBE_RESPONSE)
    }
}
