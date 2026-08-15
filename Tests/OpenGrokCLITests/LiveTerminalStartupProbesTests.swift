// LiveTerminalStartupProbesTests.swift
//
// Pure DA2 gate + Kitty push decisions. No live stdin, no raw mode, no
// 500 ms wait. Pin: da2.rs / kitty_keyboard.rs / app/mod.rs @ 650c1db7.

import Foundation
import OpenGrokDiagnostics
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

@Suite("Live terminal startup probes")
struct LiveTerminalStartupProbesTests {

    @Test("DA2 probe is Alacritty-only and skips CSI-intercepting mux")
    func da2GateIsAlacrittyOnly() {
        for brand in OpenGrokDiagnostics.TerminalName.allCases {
            let probeOpen = shouldProbeDa2(brand: brand, multiplexerInterceptsCsi: false)
            let probeMux = shouldProbeDa2(brand: brand, multiplexerInterceptsCsi: true)
            if brand == .alacritty {
                #expect(probeOpen)
            } else {
                #expect(!probeOpen)
            }
            #expect(!probeMux)
        }
    }

    @Test("No brand is probed by both XTVERSION and DA2")
    func da2AndXtversionGatesAreDisjoint() {
        for brand in OpenGrokDiagnostics.TerminalName.allCases {
            let ctx = TerminalContext(brand: brand, multiplexer: .undetected)
            let da2 = shouldProbeDa2(brand: brand, multiplexerInterceptsCsi: false)
            let xtversion = gateAllowsXtversionProbe(ctx)
            #expect(!(da2 && xtversion), "\(brand) would be probed by both")
        }
        // tmux intercepts CSI: both gates refuse even Alacritty.
        #expect(!shouldProbeDa2(brand: .alacritty, multiplexerInterceptsCsi: true))
        #expect(!gateAllowsXtversionProbe(TerminalContext(brand: .alacritty, multiplexer: .tmux)))
        #expect(!gateAllowsXtversionProbe(TerminalContext(brand: .kitty, multiplexer: .tmux)))
    }

    @Test("Canned DA2 reply yields packed version; silence is nil not 0")
    func probeFromReplyBufferNeverInventedZero() {
        #expect(probeDa2Packed(fromReply: []) == nil)
        #expect(probeDa2Packed(fromReply: Array("".utf8)) == nil)
        #expect(probeDa2Packed(fromReply: Array("c".utf8)) == nil)
        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>0c".utf8)) == nil)
        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>0;0;1c".utf8)) == nil)
        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>0;388;0c".utf8)) == nil)
        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>41;389;0c".utf8)) == nil)

        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>0;2100;1c".utf8)) == 2100)
        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>0;2401;1c".utf8)) == 2401)
        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>0;2402;1c".utf8)) == 2402)
        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>0;2500;1c".utf8)) == 2500)
        #expect(probeDa2Packed(fromReply: Array("\u{1B}[>0;2601;1c".utf8)) == 2601)
        // Typeahead consumed ahead of the reply: last `>` still wins.
        #expect(probeDa2Packed(fromReply: Array("ls > out.c\u{1B}[>0;2500;1c".utf8)) == 2500)
    }

    @Test("Silence does not downgrade Kitty release events")
    func nilPackedKeepsReportEventTypes() {
        let applied = applyKittyKeyboard(da2Packed: nil, skipReason: nil)
        #expect(applied.flags == [.disambiguateEscapeCodes, .reportEventTypes])
        #expect(applied.pushSequence == KittyKeyboardSequences.pushFlags(applied.flags))
        #expect(applied.pushSequence == "\u{1B}[>3u")
        // Packed 0 is the opposite: a positively identified broken value.
        let zero = applyKittyKeyboard(da2Packed: 0, skipReason: nil)
        #expect(zero.flags == [.disambiguateEscapeCodes])
        #expect(zero.pushSequence == "\u{1B}[>1u")
    }

    @Test("Broken Alacritty 2401 withholds REPORT_EVENT_TYPES; 2402 does not")
    func downgradeBoundaryIsLastBrokenLibraryVersion() {
        let broken = applyKittyKeyboard(da2Packed: 2401, skipReason: nil)
        #expect(broken.flags == [.disambiguateEscapeCodes])
        #expect(broken.pushSequence == "\u{1B}[>1u")

        let fixed = applyKittyKeyboard(da2Packed: 2402, skipReason: nil)
        #expect(fixed.flags == [.disambiguateEscapeCodes, .reportEventTypes])
        #expect(fixed.pushSequence == "\u{1B}[>3u")
    }

    @Test("A skip reason pushes nothing regardless of packed version")
    func skipReasonPushesNothing() {
        for packed: UInt32? in [nil, 2401, 2402] {
            let applied = applyKittyKeyboard(da2Packed: packed, skipReason: "vscode")
            #expect(applied.flags.isEmpty, "da2Packed=\(String(describing: packed))")
            #expect(applied.pushSequence == nil, "da2Packed=\(String(describing: packed))")
        }
    }

    @Test("Gate-closed brand ignores a canned Alacritty reply")
    func closedGateDoesNotConsumeReply() {
        let reply = Array("\u{1B}[>0;2401;1c".utf8)
        let applied = decideTerminalStartupProbes(
            brand: .kitty,
            multiplexerInterceptsCsi: false,
            skipReason: nil,
            replyBytes: reply
        )
        // No query would have been sent, so silence — not the 2401 downgrade.
        #expect(applied.flags.contains(.reportEventTypes))
        #expect(applied.pushSequence == "\u{1B}[>3u")
    }

    @Test("Alacritty under tmux does not treat silence as packed 0")
    func alacrittyTmuxSilenceKeepsReleases() {
        let applied = decideTerminalStartupProbes(
            brand: .alacritty,
            multiplexerInterceptsCsi: true,
            skipReason: nil,
            replyBytes: nil
        )
        #expect(applied.flags.contains(.reportEventTypes))
    }

    @Test("Open Alacritty with a 2401 reply withholds event types")
    func openAlacrittyBrokenReplyDowngrades() {
        let applied = decideTerminalStartupProbes(
            brand: .alacritty,
            multiplexerInterceptsCsi: false,
            skipReason: nil,
            replyBytes: Array("\u{1B}[>0;2401;1c".utf8)
        )
        #expect(applied.flags == [.disambiguateEscapeCodes])
        #expect(!applied.flags.contains(.reportEventTypes))
    }

    @Test("XTVERSION query bytes are CSI > 0 q and are not a timed read")
    func xtversionQueryBytesAreFireAndForget() {
        #expect(writeXtversionQueryBytes() == XTVERSION_QUERY)
        #expect(writeXtversionQueryBytes() == [0x1B, 0x5B, 0x3E, 0x30, 0x71])
        #expect(writeXtversionQueryBytes() != DA2_QUERY)
    }
}
