// CsiFragmentFilterTests.swift
//
// Unit tests for CsiFragmentFilter.
// Ported from `crates/codegen/xai-grok-pager/src/app/csi_filter.rs`.

import Foundation
import Testing
@testable import OpenGrokTTY

@Suite("CSI Fragment Filter")
struct CsiFragmentFilterTests {
    private var esc: TerminalInputEvent { .control(.escape) }
    private var resize: TerminalInputEvent { .resize(TerminalSize(width: 80, height: 24)) }

    private func text(_ str: String) -> TerminalInputEvent {
        .text(str)
    }

    private func charKey(_ ch: Character, shift: Bool = false) -> TerminalInputEvent {
        .key(.character(String(ch), modifiers: shift ? [.shift] : []))
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

    @Test("Empty input filter returns empty")
    func csiFilterEmpty() {
        var filter = CsiFragmentFilter()
        #expect(filter.filter([]) == [])
    }

    @Test("Normal keys pass through unchanged")
    func csiFilterNormalKeysUnchanged() {
        var filter = CsiFragmentFilter()
        let input: [TerminalInputEvent] = [text("h"), text("i"), .control(.enter)]
        #expect(filter.filter(input) == input)
    }

    @Test("Single SGR mouse fragment removed")
    func csiFilterSingleFragmentRemoved() {
        var filter = CsiFragmentFilter()
        let fragment = sgrFragment("35", "261", "67")
        #expect(filter.filter(fragment) == [])
    }

    @Test("Multiple SGR mouse fragments removed")
    func csiFilterMultipleFragmentsRemoved() {
        var filter = CsiFragmentFilter()
        var input = sgrFragment("35", "261", "67")
        input.append(contentsOf: sgrFragment("35", "263", "64"))
        #expect(filter.filter(input) == [])
    }

    @Test("Esc before fragment is removed along with fragment")
    func csiFilterEscBeforeFragmentRemoved() {
        var filter = CsiFragmentFilter()
        var input: [TerminalInputEvent] = [esc]
        input.append(contentsOf: sgrFragment("35", "261", "67"))
        #expect(filter.filter(input) == [])
    }

    @Test("Partial fragment held and flushed on non-matching character")
    func csiFilterPartialFragmentHeld() {
        var filter = CsiFragmentFilter()
        let partial: [TerminalInputEvent] = [text("["), text("<"), text("3"), text("5"), text(";"), text("2"), text("6"), text("1"), text(";")]
        #expect(filter.filter(partial) == [])

        let followUp: [TerminalInputEvent] = [.control(.enter)]
        #expect(filter.filter(followUp) == partial + followUp)
    }

    @Test("Mixed normal keys and fragment")
    func csiFilterMixedNormalAndFragment() {
        var filter = CsiFragmentFilter()
        var input: [TerminalInputEvent] = [text("h"), text("i")]
        input.append(contentsOf: sgrFragment("35", "261", "67"))
        input.append(text("!"))
        #expect(filter.filter(input) == [text("h"), text("i"), text("!")])
    }

    @Test("Lowercase 'm' release fragment removed")
    func csiFilterLowercaseMRemoved() {
        var filter = CsiFragmentFilter()
        let fragment = sgrFragment("35", "261", "67", finalCh: "m")
        #expect(filter.filter(fragment) == [])
    }

    @Test("Non-key events preserved around fragments")
    func csiFilterNonKeyEventsPreserved() {
        var filter = CsiFragmentFilter()
        var input: [TerminalInputEvent] = [resize]
        input.append(contentsOf: sgrFragment("35", "261", "67"))
        input.append(resize)
        #expect(filter.filter(input) == [resize, resize])
    }

    @Test("Esc not immediately before fragment is kept")
    func csiFilterEscNotImmediatelyBeforeFragmentKept() {
        var filter = CsiFragmentFilter()
        var input: [TerminalInputEvent] = [esc, text("x")]
        input.append(contentsOf: sgrFragment("35", "261", "67"))
        #expect(filter.filter(input) == [esc, text("x")])
    }

    @Test("Multiple Esc and fragment pairs removed")
    func csiFilterEscAndFragmentPairs() {
        var filter = CsiFragmentFilter()
        var input: [TerminalInputEvent] = [esc]
        input.append(contentsOf: sgrFragment("35", "261", "67"))
        input.append(esc)
        input.append(contentsOf: sgrFragment("35", "263", "64"))
        #expect(filter.filter(input) == [])
    }

    @Test("Reject re-evaluates bracket starting new fragment")
    func csiFilterRejectReEvaluatesBracket() {
        var filter = CsiFragmentFilter()
        let input: [TerminalInputEvent] = [text("["), text("<"), text("3"), text("5"), text("["), text("<"), text("0"), text(";"), text("0"), text(";"), text("0"), text("M")]
        #expect(filter.filter(input) == [text("["), text("<"), text("3"), text("5")])
    }

    @Test("Lone typed bracket renders immediately rather than waiting for another key")
    func csiFilterLoneBracketEmittedImmediately() {
        var filter = CsiFragmentFilter()
        #expect(filter.filter([text("[")]) == [text("[")])
        #expect(filter.filter([text("a")]) == [text("a")])
    }

    @Test("Min coordinates 0;0;0M swallowed")
    func csiFilterMinCoordinates() {
        var filter = CsiFragmentFilter()
        let fragment = sgrFragment("0", "0", "0")
        #expect(filter.filter(fragment) == [])
    }

    @Test("Large coordinates 999;9999;9999M swallowed")
    func csiFilterLargeCoordinates() {
        var filter = CsiFragmentFilter()
        let fragment = sgrFragment("999", "9999", "9999")
        #expect(filter.filter(fragment) == [])
    }

    @Test("Empty digit field rejected and passed through")
    func csiFilterEmptyDigitFieldKept() {
        var filter = CsiFragmentFilter()
        let input: [TerminalInputEvent] = [text("["), text("<"), text(";"), text("1"), text(";"), text("1"), text("M")]
        #expect(filter.filter(input) == input)
    }

    @Test("Cross-batch Esc then fragment: Esc emitted in batch 1, fragment swallowed in batch 2")
    func csiFilterCrossBatchEscThenFragment() {
        var filter = CsiFragmentFilter()
        #expect(filter.filter([esc]) == [esc])

        let fragment = sgrFragment("64", "91", "51")
        #expect(filter.filter(fragment) == [])
    }

    @Test("Cross-batch partial then rest swallowed together")
    func csiFilterCrossBatchPartialThenRest() {
        var filter = CsiFragmentFilter()
        let batch1: [TerminalInputEvent] = [text("["), text("<"), text("6"), text("4"), text(";")]
        #expect(filter.filter(batch1) == [])

        let batch2: [TerminalInputEvent] = [text("9"), text("1"), text(";"), text("5"), text("1"), text("M")]
        #expect(filter.filter(batch2) == [])
    }

    @Test("Uppercase 'M' with shift modifier swallowed")
    func csiFilterUppercaseMWithShiftModifier() {
        var filter = CsiFragmentFilter()
        var fragment: [TerminalInputEvent] = [text("["), text("<"), text("3"), text("5"), text(";"), text("2"), text("6"), text("1"), text(";"), text("6"), text("7")]
        fragment.append(charKey("M", shift: true))
        #expect(filter.filter(fragment) == [])
    }

    @Test("Many uppercase 'M' fragments with shift modifier all swallowed")
    func csiFilterManyUppercaseMFragments() {
        var filter = CsiFragmentFilter()
        var input: [TerminalInputEvent] = []
        for _ in 0..<20 {
            input.append(contentsOf: [text("["), text("<"), text("3"), text("5"), text(";"), text("2"), text("6"), text("1"), text(";"), text("6"), text("7"), charKey("M", shift: true)])
        }
        #expect(filter.filter(input) == [])
    }

    @Test("Cross-batch partial then reject flushes held events")
    func csiFilterCrossBatchPartialThenReject() {
        var filter = CsiFragmentFilter()
        let batch1: [TerminalInputEvent] = [text("["), text("<"), text("6")]
        #expect(filter.filter(batch1) == [])

        let batch2: [TerminalInputEvent] = [text("a")]
        #expect(filter.filter(batch2) == [text("["), text("<"), text("6"), text("a")])
    }

    @Test("Focus IN after Esc translated to focusGained with bare Esc removed")
    func csiFilterFocusInAfterEscTranslated() {
        var filter = CsiFragmentFilter()
        let input: [TerminalInputEvent] = [esc, text("["), text("I")]
        #expect(filter.filter(input) == [.focusGained])
    }

    @Test("Focus OUT after Esc translated to focusLost with bare Esc removed")
    func csiFilterFocusOutAfterEscTranslated() {
        var filter = CsiFragmentFilter()
        let input: [TerminalInputEvent] = [esc, text("["), text("O")]
        #expect(filter.filter(input) == [.focusLost])
    }

    @Test("Typed '[I' without preceding bare Esc passed through")
    func csiFilterTypedBracketIKept() {
        var filter = CsiFragmentFilter()
        let input: [TerminalInputEvent] = [text("["), text("I")]
        #expect(filter.filter(input) == [text("["), text("I")])
    }

    @Test("SS3 sequence Esc+O+A not eaten by CSI filter")
    func csiFilterSS3NotEaten() {
        var filter = CsiFragmentFilter()
        let input: [TerminalInputEvent] = [esc, text("O"), text("A")]
        #expect(filter.filter(input) == input)
    }
}
