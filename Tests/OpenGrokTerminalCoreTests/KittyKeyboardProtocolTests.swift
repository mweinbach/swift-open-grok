// KittyKeyboardProtocolTests.swift
//
// Empirical challenge tests for Kitty keyboard protocol flag negotiation,
// state tracking, and escape sequence formatting.

import Foundation
import Testing
@testable import OpenGrokTerminalCore

@Suite("Kitty Keyboard Protocol Negotiation & State")
struct KittyKeyboardProtocolTests {
    @Test("Flag negotiation with skipReason always withholding all flags")
    func skipReasonWithholdsAllFlags() {
        #expect(negotiatedKittyFlags(skipReason: "unsupported terminal", da2Packed: 2500) == [])
        #expect(negotiatedKittyFlags(skipReason: "tmux active", da2Packed: nil) == [])
        #expect(negotiatedKittyFlags(skipReason: "", da2Packed: 0) == [])
    }

    @Test("Flag negotiation when da2Packed is nil defaults to standard flags including reportEventTypes")
    func nilDa2PackedNegotiatesReportEventTypes() {
        let flags = negotiatedKittyFlags(skipReason: nil, da2Packed: nil)
        #expect(flags.contains(.disambiguateEscapeCodes))
        #expect(flags.contains(.reportEventTypes))
        #expect(flags == [.disambiguateEscapeCodes, .reportEventTypes])
    }

    @Test("Alacritty DA2 packed <= 2401 withholds reportEventTypes")
    func alacrittyBrokenVersionsWithholdReportEventTypes() {
        // Alacritty 0.14.0 (alacritty_terminal 0.24.1 -> 2401)
        let flags2401 = negotiatedKittyFlags(skipReason: nil, da2Packed: 2401)
        #expect(flags2401 == [.disambiguateEscapeCodes])
        #expect(!flags2401.contains(.reportEventTypes))

        // Alacritty 0.24.0 -> 2400
        let flags2400 = negotiatedKittyFlags(skipReason: nil, da2Packed: 2400)
        #expect(flags2400 == [.disambiguateEscapeCodes])

        // Zero DA2 packed -> 0
        let flags0 = negotiatedKittyFlags(skipReason: nil, da2Packed: 0)
        #expect(flags0 == [.disambiguateEscapeCodes])
    }

    @Test("Alacritty DA2 packed > 2401 includes reportEventTypes")
    func alacrittyFixedVersionsIncludeReportEventTypes() {
        // Alacritty 0.24.2 / 0.14.1+ fixed release -> 2402
        let flags2402 = negotiatedKittyFlags(skipReason: nil, da2Packed: 2402)
        #expect(flags2402 == [.disambiguateEscapeCodes, .reportEventTypes])

        // Future version 0.25.0 -> 2500
        let flags2500 = negotiatedKittyFlags(skipReason: nil, da2Packed: 2500)
        #expect(flags2500 == [.disambiguateEscapeCodes, .reportEventTypes])

        // High version -> 99999
        let flagsLarge = negotiatedKittyFlags(skipReason: nil, da2Packed: 99999)
        #expect(flagsLarge == [.disambiguateEscapeCodes, .reportEventTypes])
    }

    @Test("KittyKeyboardState thread-safe singleton lifecycle and querying")
    func kittyKeyboardStateLifecycle() {
        let state = KittyKeyboardState.shared
        // Reset state for isolation
        _ = state.takeKittyFlagsPushed()

        #expect(!state.kittyFlagsPushed())
        #expect(!state.kittyReleasesReported())
        #expect(!state.kittyEventTypesWithheld())
        #expect(state.currentPushedFlags() == [])

        // Push flags without event types (Alacritty shape)
        state.setPushedFlags([.disambiguateEscapeCodes])
        #expect(state.kittyFlagsPushed())
        #expect(!state.kittyReleasesReported())
        #expect(state.kittyEventTypesWithheld())
        #expect(state.currentPushedFlags() == [.disambiguateEscapeCodes])

        // Push flags with event types (Kitty / fixed Alacritty shape)
        state.setPushedFlags([.disambiguateEscapeCodes, .reportEventTypes])
        #expect(state.kittyFlagsPushed())
        #expect(state.kittyReleasesReported())
        #expect(!state.kittyEventTypesWithheld())

        // Take pushed flags clears state and returns true
        #expect(state.takeKittyFlagsPushed())
        #expect(!state.kittyFlagsPushed())
        #expect(!state.takeKittyFlagsPushed())
    }

    @Test("KittyKeyboardSequences format escape strings properly")
    func kittyKeyboardSequencesFormat() {
        #expect(KittyKeyboardSequences.pushFlags([]) == "\u{1B}[>0u")
        #expect(KittyKeyboardSequences.pushFlags([.disambiguateEscapeCodes]) == "\u{1B}[>1u")
        #expect(KittyKeyboardSequences.pushFlags([.disambiguateEscapeCodes, .reportEventTypes]) == "\u{1B}[>3u")
        #expect(KittyKeyboardSequences.popFlags == "\u{1B}[<u")
    }
}
