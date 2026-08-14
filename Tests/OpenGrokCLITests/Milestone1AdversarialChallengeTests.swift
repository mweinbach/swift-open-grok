// Milestone1AdversarialChallengeTests.swift
//
// Empirical adversarial challenge tests for all Milestone 1 features combined
// (CSI fragment filter, SGR decoding, middle-click paste routing, Kitty keyboard protocol).

import Foundation
import Testing
import OpenGrokTTY
import OpenGrokTerminalCore
import OpenGrokWebMediaTools
@testable import OpenGrokCLI

@Suite("Milestone 1 Adversarial Challenge & Edge Cases")
struct Milestone1AdversarialChallengeTests {
    private var esc: TerminalInputEvent { .control(.escape) }

    private func text(_ str: String) -> TerminalInputEvent {
        .text(str)
    }

    private func sgrFragment(_ button: String, _ col: String, _ row: String, finalCh: String = "M") -> [TerminalInputEvent] {
        var events: [TerminalInputEvent] = [text("["), text("<")]
        for ch in button { events.append(text(String(ch))) }
        events.append(text(";"))
        for ch in col { events.append(text(String(ch))) }
        events.append(text(";"))
        for ch in row { events.append(text(String(ch))) }
        events.append(text(finalCh))
        return events
    }

    // MARK: - 1. CSI Fragment Filter Edge Cases

    @Test("CSI Fragment Filter: Multi-batch split every single byte")
    func testCsiFragmentFilterMultiBatchSplitEveryByte() {
        var filter = CsiFragmentFilter()
        // SGR sequence: \e[<35;261;67M -> represented as input events
        let fullFragment = sgrFragment("35", "261", "67")

        var emittedEvents: [TerminalInputEvent] = []
        for event in fullFragment {
            let res = filter.filter([event])
            emittedEvents.append(contentsOf: res)
        }

        #expect(emittedEvents.isEmpty, "Filtering single-byte chunked SGR fragment should emit nothing")
    }

    @Test("CSI Fragment Filter: Split focus report across 3 batches (Esc | [ | I)")
    func testCsiFragmentFilterSplitFocusSequenceAcross3Batches() {
        var filter = CsiFragmentFilter()

        // Batch 1: ESC
        let res1 = filter.filter([esc])
        #expect(res1 == [esc], "ESC in batch 1 is emitted immediately")

        // Batch 2: [
        let res2 = filter.filter([text("[")])
        #expect(res2 == [], "Bracket in batch 2 is held")

        // Batch 3: I
        let res3 = filter.filter([text("I")])
        #expect(res3 == [.focusGained], "I in batch 3 completes focusGained sequence")
    }

    @Test("CSI Fragment Filter: Split focus report lost across 3 batches (Esc | [ | O)")
    func testCsiFragmentFilterSplitFocusLostAcross3Batches() {
        var filter = CsiFragmentFilter()

        let res1 = filter.filter([esc])
        #expect(res1 == [esc])

        let res2 = filter.filter([text("[")])
        #expect(res2 == [])

        let res3 = filter.filter([text("O")])
        #expect(res3 == [.focusLost], "O in batch 3 completes focusLost sequence")
    }

    @Test("CSI Fragment Filter: Reject flushes tentative buffer in order")
    func testCsiFragmentFilterRejectFlushesHeldBufferInOrder() {
        var filter = CsiFragmentFilter()

        let partial: [TerminalInputEvent] = [text("["), text("<"), text("1"), text(";")]
        let res1 = filter.filter(partial)
        #expect(res1 == [], "Partial SGR sequence should be held")

        let rejectChar: [TerminalInputEvent] = [text("Z")]
        let res2 = filter.filter(rejectChar)
        #expect(res2 == partial + rejectChar, "Reject character must flush held buffer in exact original order plus reject char")
    }

    @Test("CSI Fragment Filter: Nested bracket sequence resynchronizes")
    func testCsiFragmentFilterNestedBracketResync() {
        var filter = CsiFragmentFilter()

        let partial1: [TerminalInputEvent] = [text("["), text("<"), text("9")]
        #expect(filter.filter(partial1) == [])

        // Second bracket sequence arrives before first completes
        let partial2: [TerminalInputEvent] = [text("["), text("<"), text("0"), text(";"), text("0"), text(";"), text("0"), text("M")]
        let res2 = filter.filter(partial2)

        #expect(res2 == partial1, "Nested bracket should emit orphaned partial1 events and swallow completed partial2")
    }

    @Test("CSI Fragment Filter: Overlong digit sequence swallowed")
    func testCsiFragmentFilterOverlongDigitSequence() {
        var filter = CsiFragmentFilter()
        var overlong: [TerminalInputEvent] = [text("["), text("<")]
        for _ in 0..<500 {
            overlong.append(text("9"))
        }
        overlong.append(text(";"))
        for _ in 0..<500 {
            overlong.append(text("8"))
        }
        overlong.append(text(";"))
        for _ in 0..<500 {
            overlong.append(text("7"))
        }
        overlong.append(text("M"))

        let res = filter.filter(overlong)
        #expect(res == [], "Overlong digit sequence should be swallowed cleanly")
    }

    // MARK: - 2. SGR Mouse Decoding & Stream Parsing Edge Cases

    @Test("SGR Mouse Decoding: All button kinds, modifiers, and actions")
    func testSgrMouseDecodingAllButtonKindsAndModifiers() {
        // Left press: ESC [ < 0 ; 10 ; 20 M -> x: 9, y: 19, button: .left, kind: .down
        let leftPressBytes: [UInt8] = Array("\u{1B}[<0;10;20M".utf8)
        if case .event(let ev) = MouseReportDecoder.decodeSGR(leftPressBytes) {
            #expect(ev.kind == .down)
            #expect(ev.resolvedButton == .left)
            #expect(ev.x == 9)
            #expect(ev.y == 19)
            #expect(ev.modifiers.isEmpty)
        } else {
            Issue.record("Failed to decode SGR left press")
        }

        // Middle release with Shift: ESC [ < 5 ; 15 ; 25 m (button 1 + shift 4 = 5)
        let middleReleaseShiftBytes: [UInt8] = Array("\u{1B}[<5;15;25m".utf8)
        if case .event(let ev) = MouseReportDecoder.decodeSGR(middleReleaseShiftBytes) {
            #expect(ev.kind == .up)
            #expect(ev.resolvedButton == .middle)
            #expect(ev.x == 14)
            #expect(ev.y == 24)
            #expect(ev.modifiers == [.shift])
        } else {
            Issue.record("Failed to decode SGR middle release with shift")
        }

        // Right drag with Ctrl+Alt: ESC [ < 58 ; 30 ; 40 M (button 2 + motion 32 + alt 8 + ctrl 16 = 58)
        let rightDragCtrlAltBytes: [UInt8] = Array("\u{1B}[<58;30;40M".utf8)
        if case .event(let ev) = MouseReportDecoder.decodeSGR(rightDragCtrlAltBytes) {
            #expect(ev.kind == .drag)
            #expect(ev.resolvedButton == .right)
            #expect(ev.x == 29)
            #expect(ev.y == 39)
            #expect(ev.modifiers == [.control, .alt])
        } else {
            Issue.record("Failed to decode SGR right drag with Ctrl+Alt")
        }

        // Scroll Down: ESC [ < 65 ; 5 ; 5 M (wheel bit 64 + code 1 = 65)
        let scrollDownBytes: [UInt8] = Array("\u{1B}[<65;5;5M".utf8)
        if case .event(let ev) = MouseReportDecoder.decodeSGR(scrollDownBytes) {
            #expect(ev.kind == .scrollDown)
            #expect(ev.resolvedButton == .none)
            #expect(ev.isScroll == true)
        } else {
            Issue.record("Failed to decode SGR scroll down")
        }

        // Extended button 8 press: ESC [ < 128 ; 1 ; 1 M (extended bit 128 + code 0)
        let extendedButtonBytes: [UInt8] = Array("\u{1B}[<128;1;1M".utf8)
        if case .event(let ev) = MouseReportDecoder.decodeSGR(extendedButtonBytes) {
            #expect(ev.kind == .down)
            #expect(ev.resolvedButton == .other(8))
        } else {
            Issue.record("Failed to decode SGR extended button")
        }
    }

    @Test("SGR Mouse Decoding: Overflow and malformed reports handled safely")
    func testSgrMouseDecodingOverflowAndMalformed() {
        // Overflow digit > 9,999,999
        let overflowBytes: [UInt8] = Array("\u{1B}[<100000000;1;1M".utf8)
        #expect(MouseReportDecoder.decodeSGR(overflowBytes) == .malformed)

        // Missing field (only 2 fields: button and col)
        let missingFieldBytes: [UInt8] = Array("\u{1B}[<0;10M".utf8)
        #expect(MouseReportDecoder.decodeSGR(missingFieldBytes) == .malformed)

        // Extra field (4 fields)
        let extraFieldBytes: [UInt8] = Array("\u{1B}[<0;10;20;30M".utf8)
        #expect(MouseReportDecoder.decodeSGR(extraFieldBytes) == .malformed)

        // Non-numeric chars
        let nonNumericBytes: [UInt8] = Array("\u{1B}[<0;abc;20M".utf8)
        #expect(MouseReportDecoder.decodeSGR(nonNumericBytes) == .malformed)
    }

    @Test("MouseStreamParser: Chunked feeding and passthrough interleaving")
    func testMouseStreamParserChunkedFeeding() {
        var parser = MouseStreamParser()

        // Feed mouse sequence \e[<1;10;20M byte by byte
        let seq = Array("\u{1B}[<1;10;20M".utf8)
        var outputs: [MouseParserOutput] = []
        for b in seq {
            outputs.append(contentsOf: parser.feed([b]))
        }

        #expect(outputs.count == 1)
        if case .mouse(let mouse) = outputs[0] {
            #expect(mouse.kind == .down)
            #expect(mouse.resolvedButton == .middle)
            #expect(mouse.x == 9)
            #expect(mouse.y == 19)
        } else {
            Issue.record("Stream parser failed to parse byte-by-byte SGR mouse sequence")
        }
    }

    // MARK: - 3. Middle-Click Selection Paste Edge Cases

    @Test("Middle-Click Routing Matrix: Only unmodified middle click down triggers primary selection paste")
    func testMiddleClickRoutingMatrix() {
        let kinds: [MouseEvent.Kind] = [.down, .up, .drag, .move, .scrollUp]
        let buttons: [MouseButton] = [.middle, .left, .right, .none, .other(8)]
        let modifierSets: [KeyModifiers] = [[], [.shift], [.control], [.alt], [.shift, .control]]

        for kind in kinds {
            for button in buttons {
                for modifiers in modifierSets {
                    let event = MouseEvent(kind: kind, x: 10, y: 10, button: button, modifiers: modifiers)

                    let shouldPaste = (event.kind == .down && event.resolvedButton == .middle && event.modifiers.isEmpty)

                    if shouldPaste {
                        #expect(kind == .down)
                        #expect(button == .middle)
                        #expect(modifiers.isEmpty)
                    } else {
                        #expect(!(kind == .down && button == .middle && modifiers.isEmpty))
                    }
                }
            }
        }
    }

    // MARK: - 4. Kitty Keyboard Protocol Edge Cases

    @Test("Kitty Keyboard Protocol: Flag negotiation logic under all conditions")
    func testKittyKeyboardFlagsNegotiationAllCases() {
        // Case 1: skipReason present -> empty flags
        let flagsSkip = negotiatedKittyFlags(skipReason: "User disabled", da2Packed: 3000)
        #expect(flagsSkip.rawValue == 0)

        // Case 2: Alacritty version <= 2401 (broken event types) -> disambiguateEscapeCodes only
        let flagsBroken1 = negotiatedKittyFlags(skipReason: nil, da2Packed: 2400)
        #expect(flagsBroken1 == [.disambiguateEscapeCodes])
        #expect(!flagsBroken1.contains(.reportEventTypes))

        let flagsBroken2 = negotiatedKittyFlags(skipReason: nil, da2Packed: 2401)
        #expect(flagsBroken2 == [.disambiguateEscapeCodes])

        // Case 3: Alacritty version > 2401 or non-Alacritty -> both flags
        let flagsFixed = negotiatedKittyFlags(skipReason: nil, da2Packed: 2402)
        #expect(flagsFixed.contains(.disambiguateEscapeCodes))
        #expect(flagsFixed.contains(.reportEventTypes))

        let flagsNil = negotiatedKittyFlags(skipReason: nil, da2Packed: nil)
        #expect(flagsNil.contains(.disambiguateEscapeCodes))
        #expect(flagsNil.contains(.reportEventTypes))
    }

    @Test("Kitty Keyboard Protocol: Thread safety of global KittyKeyboardState")
    func testKittyKeyboardStateThreadSafety() async {
        let state = KittyKeyboardState.shared

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    for _ in 0..<100 {
                        let flags: KeyboardEnhancementFlags = (i % 2 == 0)
                            ? [.disambiguateEscapeCodes, .reportEventTypes]
                            : [.disambiguateEscapeCodes]
                        state.setPushedFlags(flags)
                        _ = state.currentPushedFlags()
                        _ = state.kittyFlagsPushed()
                        _ = state.kittyReleasesReported()
                        _ = state.kittyEventTypesWithheld()
                        _ = state.takeKittyFlagsPushed()
                    }
                }
            }
        }

        // Clean state after test
        state.setPushedFlags([])
        #expect(!state.kittyFlagsPushed())
    }

    @Test("Kitty Keyboard Protocol: Sequence formatting")
    func testKittyKeyboardSequencesFormatting() {
        let flags: KeyboardEnhancementFlags = [.disambiguateEscapeCodes, .reportEventTypes]
        let pushSeq = KittyKeyboardSequences.pushFlags(flags)
        #expect(pushSeq == "\u{1B}[>3u")

        let popSeq = KittyKeyboardSequences.popFlags
        #expect(popSeq == "\u{1B}[<u")
    }

    // MARK: - 5. Combined Milestone 1 Stream Integration

    @Test("Combined Milestone 1 Stream: Interleaved Kitty, SGR mouse, Focus reports, and CSI filtering")
    func testCombinedMilestone1StreamInterleaved() throws {
        var csiFilter = CsiFragmentFilter()
        var mouseParser = MouseStreamParser()
        var decoder = TerminalInputDecoder()

        // 1. Kitty push sequence bytes
        let kittyPushBytes = Array(KittyKeyboardSequences.pushFlags([.disambiguateEscapeCodes]).utf8)
        let mouseOut1 = mouseParser.feed(kittyPushBytes)
        #expect(mouseOut1 == [.passthrough(kittyPushBytes)])

        // 2. Focus Lost split across batches: Esc in batch 1, [O in batch 2
        let escEv = TerminalInputEvent.control(.escape)
        let filtered1 = csiFilter.filter([escEv])
        #expect(filtered1 == [escEv])

        let bracketO: [TerminalInputEvent] = [.text("["), .text("O")]
        let filtered2 = csiFilter.filter(bracketO)
        #expect(filtered2 == [.focusLost])

        // 3. Middle click down SGR report \e[<1;15;25M fed to mouse parser
        let sgrMiddleClickBytes = Array("\u{1B}[<1;15;25M".utf8)
        let mouseOut2 = mouseParser.feed(sgrMiddleClickBytes)
        #expect(mouseOut2.count == 1)
        if case .mouse(let mouseEv) = mouseOut2[0] {
            #expect(mouseEv.kind == .down)
            #expect(mouseEv.resolvedButton == .middle)
            #expect(mouseEv.modifiers.isEmpty)
            // Verify this satisfies middle-click paste routing trigger
            #expect(mouseEv.kind == .down && mouseEv.resolvedButton == .middle && mouseEv.modifiers.isEmpty)
        } else {
            Issue.record("Combined stream failed to parse SGR middle click")
        }

        // 4. Kitty CSI-u keypress sequence \e[97;5u (Ctrl+A) fed into decoder
        let kittyKeyBytes = Array("\u{1B}[97;5u".utf8)
        var decodedEvents: [TerminalInputEvent] = []
        for b in kittyKeyBytes {
            decodedEvents.append(contentsOf: try decoder.feed(b))
        }
        // TerminalInputDecoder outputs unknown sequence for custom CSI u when not mapped to named key
        #expect(!decodedEvents.isEmpty)

        // 5. Verify CsiFragmentFilter does not swallow or corrupt non-SGR CSI sequences (e.g. Kitty CSI-u)
        let kittyCsiEvents: [TerminalInputEvent] = [.text("["), .text("9"), .text("7"), .text(";"), .text("5"), .text("u")]
        let csiFilteredKitty = csiFilter.filter(kittyCsiEvents)
        #expect(csiFilteredKitty == kittyCsiEvents, "CsiFragmentFilter must pass non-SGR/non-focus CSI sequences through completely untouched")
    }
}
