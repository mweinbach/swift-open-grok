// XtversionTests.swift
//
// XTVERSION query / parse / byte-filter coverage. No stdin, no raw mode,
// no live TTY.
//
// Pin: `xtversion.rs`, `probe.rs`, `xt_filter.rs` at 650c1db7.

import Foundation
import Testing
@testable import OpenGrokTerminalCore

private func utf8(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

/// 7-bit DCS reply `ESC P > | <payload> ESC \`.
private func dcsReply(_ payload: String, terminator: DcsTerminator = .sevenBitST) -> [UInt8] {
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

private enum DcsTerminator {
    case sevenBitST
    case eightBitST
    case bel
}

@Suite("XTVERSION query, parse, and byte filter")
struct XtversionTests {

    // MARK: - Query / probe bounds

    @Test("Query bytes are CSI > 0 q")
    func queryBytesExact() {
        #expect(XTVERSION_QUERY == [0x1B, 0x5B, 0x3E, 0x30, 0x71])
        #expect(Array(XTVERSION_QUERY_STRING.utf8) == XTVERSION_QUERY)
        #expect(probeQueryBytes(XTVERSION_QUERY) == XTVERSION_QUERY)
    }

    @Test("writeProbeQuery appends the XTVERSION query")
    func writeQueryHelper() {
        var destination: [UInt8] = []
        #expect(writeProbeQuery(XTVERSION_QUERY, into: &destination))
        #expect(destination == [0x1B, 0x5B, 0x3E, 0x30, 0x71])

        var empty: [UInt8] = [0x41]
        #expect(!writeProbeQuery([], into: &empty))
        #expect(empty == [0x41])
    }

    @Test("MAX_PROBE_RESPONSE is 256")
    func maxProbeResponse() {
        #expect(MAX_PROBE_RESPONSE == 256)
        #expect(LATE_REPLY_GRACE_MILLISECONDS == 100)
        #expect(LATE_REPLY_QUIET_MILLISECONDS == 25)
        #expect(probeResponseReachedCap([UInt8](repeating: 0, count: 256)))
        #expect(!probeResponseReachedCap([UInt8](repeating: 0, count: 255)))

        let almost = [UInt8](repeating: 0x41, count: 255)
        #expect(
            shouldStopProbeResponse(
                almost + [0x07],
                lastByte: 0x07,
                isTerminated: probeReplyIsBelOrSevenBitST
            )
        )
        #expect(
            !shouldStopProbeResponse(
                almost,
                lastByte: 0x41,
                isTerminated: probeReplyIsBelOrSevenBitST
            )
        )
    }

    // MARK: - Parse

    @Test("parse WezTerm DCS payload")
    func parseWezTermPayload() {
        let reply = dcsReply("WezTerm 20240203-110809")
        #expect(parseXtversionReply(reply) == "WezTerm 20240203-110809")
        #expect(
            parseXtversionReply(dcsReply("WezTerm 20240203-110809", terminator: .bel))
                == "WezTerm 20240203-110809"
        )

        var eightBit: [UInt8] = [0x90, 0x3E, 0x7C]
        eightBit.append(contentsOf: "WezTerm 20240203-110809".utf8)
        eightBit.append(0x9C)
        #expect(parseXtversionReply(eightBit) == "WezTerm 20240203-110809")
    }

    @Test("parse sanitizes controls and rejects empty")
    func parseSanitizeAndEmpty() {
        #expect(sanitizeXtversionPayload("kitty 0.35.2") == "kitty 0.35.2")
        #expect(sanitizeXtversionPayload(" We\u{01}zTerm 2.0 ") == "WezTerm 2.0")
        #expect(sanitizeXtversionPayload("") == nil)
        #expect(sanitizeXtversionPayload(" \u{07} ") == nil)
        #expect(parseXtversionReply(nil) == nil)
        #expect(parseXtversionReply([]) == nil)
        #expect(parseXtversionReply(dcsReply("")) == nil)
        #expect(parseXtversionReply(utf8("hi")) == nil)
    }

    // MARK: - Filter

    @Test("filter swallows reply and leaves following keystrokes")
    func filterSwallowsReplyLeavesKeystrokes() {
        var filter = XtversionReplyFilter()
        var bytes = utf8("hi")
        bytes.append(contentsOf: dcsReply("WezTerm 20240203-110809"))
        bytes.append(contentsOf: utf8("!"))
        let step = filter.feed(bytes)
        #expect(step.residual == utf8("hi!"))
        #expect(step.completedPayload == "WezTerm 20240203-110809")
        #expect(!filter.armed)
        #expect(!filter.holding)
    }

    @Test("truncated ST holds fragments across chunks, CRLF-safe")
    func truncatedSTHoldsAcrossChunks() {
        var filter = XtversionReplyFilter()
        var prefix = dcsReply("WezTerm 20240203-110809")
        // Drop the final `\` of 7-bit ST so the last held byte is ESC.
        prefix.removeLast()
        let first = filter.feed(prefix)
        #expect(first.residual.isEmpty)
        #expect(first.completedPayload == nil)
        #expect(filter.holding)

        // Completing ST then a CRLF pair + text: residual must keep 0x0D 0x0A
        // as two bytes (`\r\n` is one Character if scanned as String).
        var rest = utf8("\\")
        rest.append(contentsOf: [0x0D, 0x0A])
        rest.append(contentsOf: utf8("next"))
        let second = filter.feed(rest)
        #expect(second.completedPayload == "WezTerm 20240203-110809")
        #expect(second.residual == [0x0D, 0x0A] + utf8("next"))
        #expect(second.residual.count == 6)
        #expect(second.residual[0] == 0x0D)
        #expect(second.residual[1] == 0x0A)
        #expect(!filter.holding)
    }

    @Test("BEL terminator swallows the reply")
    func belTerminator() {
        var filter = XtversionReplyFilter()
        var bytes = dcsReply("st 0.9", terminator: .bel)
        bytes.append(contentsOf: utf8("x"))
        let step = filter.feed(bytes)
        #expect(step.residual == utf8("x"))
        #expect(step.completedPayload == "st 0.9")
    }

    @Test("disarmed filter passes the DCS through")
    func disarmedPassesThrough() {
        var filter = XtversionReplyFilter(armed: false)
        let reply = dcsReply("kitty 0.35.2")
        let step = filter.feed(reply)
        #expect(step.residual == reply)
        #expect(step.completedPayload == nil)
    }

    @Test("unterminated reply then slash drops the fragment")
    func unterminatedThenSlash() {
        var filter = XtversionReplyFilter()
        var bytes = dcsReply("x")
        bytes.removeLast() // drop `\`
        bytes.removeLast() // drop ESC of ST
        bytes.append(0x2F) // '/'
        let step = filter.feed(bytes)
        #expect(step.residual == [0x2F])
        #expect(step.completedPayload == nil)
        #expect(!filter.holding)
    }

    // MARK: - Gate

    @Test("gate allows unknown and allowlisted brands")
    func gateAllowsUnknownAndAllowlisted() {
        let brands: [XtversionProbeBrand] = [
            .unknown, .kitty, .wezTerm, .ghostty, .iterm2, .rio,
        ]
        for brand in brands {
            #expect(
                gateAllowsXtversionProbe(brand: brand, multiplexer: .undetected),
                "\(brand) should be probed"
            )
            #expect(
                gateAllowsXtversionProbe(brand: brand, multiplexer: .cmux),
                "\(brand) under cmux should still be probed"
            )
            #expect(
                !gateAllowsXtversionProbe(brand: brand, multiplexer: .tmux),
                "\(brand) under tmux should be skipped"
            )
            #expect(
                !gateAllowsXtversionProbe(brand: brand, multiplexer: .herdr),
                "\(brand) under herdr should be skipped"
            )
        }
        #expect(!gateAllowsXtversionProbe(brand: .other, multiplexer: .undetected))
        #expect(XtversionProbeMultiplexer.screen.interceptsCsiQueries)
        #expect(XtversionProbeMultiplexer.zellij.interceptsCsiQueries)
        #expect(!XtversionProbeMultiplexer.cmux.interceptsCsiQueries)
    }
}
