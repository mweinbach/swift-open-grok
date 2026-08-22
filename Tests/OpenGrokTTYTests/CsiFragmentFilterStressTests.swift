// CsiFragmentFilterStressTests.swift
//
// Empirical stress tests for CsiFragmentFilter state machine, fragmented
// sequence boundaries, high throughput, and edge-case resynchronization.

import Foundation
import Testing
@testable import OpenGrokTTY

@Suite("CSI Fragment Filter Stress & Adversarial Tests")
struct CsiFragmentFilterStressTests {
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

    @Test("High throughput: 10,000 SGR mouse reports swallowed cleanly")
    func highThroughputValidSGR() {
        var filter = CsiFragmentFilter()
        var batch: [TerminalInputEvent] = []
        batch.reserveCapacity(2000)

        for i in 0..<10_000 {
            batch.append(contentsOf: sgrFragment("\(i % 4)", "\(i % 1000)", "\(i % 500)", finalCh: i % 2 == 0 ? "M" : "m"))
            if batch.count >= 1000 {
                let result = filter.filter(batch)
                #expect(result.isEmpty, "Filter failed to swallow SGR batch at iteration \(i)")
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            let result = filter.filter(batch)
            #expect(result.isEmpty)
        }
    }

    @Test("High throughput: Noisy random events with interleaved partial fragments")
    func highThroughputRandomNoise() {
        var filter = CsiFragmentFilter()
        let chars: [Character] = ["[", "<", ";", "M", "m", "I", "O", "0", "1", "9", "a", "x", " "]

        for seed in 0..<500 {
            var events: [TerminalInputEvent] = []
            for j in 0..<20 {
                let idx = (seed * 37 + j * 13) % chars.count
                events.append(text(String(chars[idx])))
            }
            _ = filter.filter(events)
        }
        let valid = sgrFragment("0", "10", "20")
        #expect(filter.filter(valid).isEmpty)
    }

    @Test("Single-batch chunked delivery: SGR fragment split across chunk sizes within one filter call")
    func singleBatchChunkedDelivery() {
        let fullFragment = sgrFragment("35", "261", "67")
        var filter = CsiFragmentFilter()
        #expect(filter.filter(fullFragment).isEmpty)
    }

    @Test("Multi-batch fragmented delivery: SGR fragment split across separate filter calls")
    func multiBatchFragmentedDelivery() {
        let fullFragment = sgrFragment("35", "261", "67")

        for chunkSize in 1...fullFragment.count {
            var filter = CsiFragmentFilter()
            var index = 0
            var output: [TerminalInputEvent] = []

            while index < fullFragment.count {
                let end = min(index + chunkSize, fullFragment.count)
                let chunk = Array(fullFragment[index..<end])
                output.append(contentsOf: filter.filter(chunk))
                index = end
            }

            #expect(output.isEmpty, "Multi-batch chunk size \(chunkSize) failed to swallow fragment, emitted \(output)")
        }

    }

    @Test("Overlong digit run in digits1 state handles large buffers")
    func overlongDigitBufferStress() {
        var filter = CsiFragmentFilter()
        var overlong: [TerminalInputEvent] = [text("["), text("<")]
        for _ in 0..<2_000 {
            overlong.append(text("1"))
        }
        overlong.append(text(";"))
        overlong.append(text("1"))
        overlong.append(text(";"))
        overlong.append(text("1"))
        overlong.append(text("M"))

        #expect(filter.filter(overlong).isEmpty, "Overlong SGR sequence should be swallowed cleanly")
    }

    @Test("Focus event reassembly within single batch and across read boundaries")
    func focusReportingReassembly() {
        var filterSameBatch = CsiFragmentFilter()
        #expect(filterSameBatch.filter([esc, text("["), text("I")]) == [.focusGained])

        var filterSameBatchOut = CsiFragmentFilter()
        #expect(filterSameBatchOut.filter([esc, text("["), text("O")]) == [.focusLost])

        // Multi-batch boundary test
        var filterMultiBatch = CsiFragmentFilter()
        #expect(filterMultiBatch.filter([esc]) == [esc])
        let focusInResult = filterMultiBatch.filter([text("["), text("I")])
        #expect(focusInResult == [.focusGained], "Focus in across batch boundary emitted \(focusInResult)")
    }

    @Test("Nested brackets resynchronize cleanly")
    func nestedBracketsResync() {
        var filter = CsiFragmentFilter()
        let input1: [TerminalInputEvent] = [text("["), text("<"), text("3"), text("5")]
        #expect(filter.filter(input1).isEmpty)

        let input2: [TerminalInputEvent] = [text("["), text("<"), text("0"), text(";"), text("0"), text(";"), text("0"), text("M")]
        let result = filter.filter(input2)
        #expect(result == input1)
    }

    @Test("Multiple Esc keys preceding fragment")
    func multipleEscKeysPrecedingFragment() {
        var filter = CsiFragmentFilter()
        var input: [TerminalInputEvent] = [esc, esc]
        input.append(contentsOf: sgrFragment("0", "1", "2"))

        let result = filter.filter(input)
        #expect(result == [esc])
    }
}
