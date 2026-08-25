import Foundation
import Testing

@testable import OpenGrokTerminalCore

@Suite("Pinned wrap OSC 52 streaming and terminal restoration")
struct WrapOSC52FilterTests {
    @Test("plain and ST-terminated OSC 52 payloads are consumed without disturbing output")
    func plainClipboardFrames() {
        let encoded = Data("clipboard 🌍".utf8).base64EncodedString()
        for terminator in ["\u{07}", "\u{1b}\\"] {
            var filter = WrapOSC52Filter()
            let bytes = Data("before\u{1b}]52;c;\(encoded)\(terminator)after".utf8)
            let output = filter.consume(bytes)

            #expect(output.passthrough == Data("beforeafter".utf8))
            #expect(output.clipboardPayloads == [Data("clipboard 🌍".utf8)])
            #expect(output.hostImageRequests == 0)
        }
    }

    @Test("plain and tmux envelopes survive every possible chunk boundary")
    func arbitraryChunkBoundaries() {
        let encoded = Data("split clipboard".utf8).base64EncodedString()
        let sequences = [
            "prefix\u{1b}]52;c;\(encoded)\u{07}suffix",
            "prefix\u{1b}Ptmux;\u{1b}\u{1b}]52;c;\(encoded)\u{07}\u{1b}\\suffix",
        ]

        for sequence in sequences {
            let bytes = Array(sequence.utf8)
            for boundary in 0...bytes.count {
                var filter = WrapOSC52Filter()
                let first = filter.consume(Data(bytes[..<boundary]))
                let second = filter.consume(Data(bytes[boundary...]))

                #expect(first.passthrough + second.passthrough == Data("prefixsuffix".utf8))
                #expect(first.clipboardPayloads + second.clipboardPayloads
                    == [Data("split clipboard".utf8)])
            }
        }
    }

    @Test("valid padded and unpadded Base64 from every clipboard selection is accepted")
    func paddedAndUnpaddedPayloads() {
        for (selection, payload) in [("c", "aGk="), ("p", "aGk"), ("", "aGk=")] {
            var filter = WrapOSC52Filter()
            let result = filter.consume(Data("\u{1b}]52;\(selection);\(payload)\u{07}".utf8))

            #expect(result.passthrough.isEmpty)
            #expect(result.clipboardPayloads == [Data("hi".utf8)])
        }
    }

    @Test("an empty OSC 52 payload is a valid clipboard-clear request")
    func emptyClipboardPayloadClearsSelection() {
        var filter = WrapOSC52Filter()
        let result = filter.consume(Data("\u{1b}]52;c;\u{07}".utf8))

        #expect(result.passthrough.isEmpty)
        #expect(result.clipboardPayloads == [Data()])
    }

    @Test("other OSC, malformed clipboard requests, and unknown DCS remain byte-transparent")
    func nonClipboardOutputRemainsUnchanged() {
        let sequences = [
            "\u{1b}]0;window title\u{07}",
            "\u{1b}]52;c;not valid base64!\u{07}",
            "\u{1b}]52;c;?\u{07}",
            "\u{1b}]52;missing-separator\u{07}",
            "\u{1b}Pother-device-control\u{1b}\\",
            "\u{1b}[31mcolored\u{1b}[0m",
        ]

        for sequence in sequences {
            var filter = WrapOSC52Filter()
            let input = Data(sequence.utf8)
            let output = filter.consume(input)

            #expect(output.passthrough == input)
            #expect(output.clipboardPayloads.isEmpty)
        }
    }

    @Test("private host-image requests are consumed and reported exactly once")
    func imageRequestsAreRecognized() {
        var filter = WrapOSC52Filter()
        let input = Data("before\u{1b}]\(REQUEST_BODY)\u{07}after".utf8)
        let result = filter.consume(input)

        #expect(result.passthrough == Data("beforeafter".utf8))
        #expect(result.hostImageRequests == 1)
        #expect(result.clipboardPayloads.isEmpty)
    }

    @Test("oversized candidate frames fail open byte-for-byte without touching the clipboard")
    func oversizedEscapeIsBounded() {
        var filter = WrapOSC52Filter()
        var input = Data("\u{1b}]52;c;".utf8)
        input.append(Data(repeating: 0x41, count: WrapOSC52Filter.maximumEscapeBytes + 20))
        input.append(0x07)

        let result = filter.consume(input)

        #expect(result.passthrough == input)
        #expect(result.clipboardPayloads.isEmpty)
    }

    @Test("malformed CSI still permits the immediately following OSC clipboard request")
    func malformedControlSequenceResynchronizes() {
        var filter = WrapOSC52Filter()
        let result = filter.consume(Data("\u{1b}[?12\u{1b}]52;c;aGk=\u{07}".utf8))

        #expect(result.passthrough == Data("\u{1b}[?12".utf8))
        #expect(result.clipboardPayloads == [Data("hi".utf8)])
    }

    @Test("cleanly reset child modes leave the outer terminal byte-transparent")
    func cleanModesRequireNoRestoration() {
        var tracker = WrapTerminalModeTracker()
        for sequence in ["\u{1b}[?1000;2004h", "\u{1b}[>1u", "\u{1b}[<u", "\u{1b}[?1000;2004l"] {
            tracker.observe(Data(sequence.utf8))
        }

        #expect(tracker.restoreBytes.isEmpty)
    }

    @Test("abandoned modes unwind in Rust's exact order and kitty pushes pop exactly once")
    func dirtyModesRestoreInPinnedOrder() {
        var tracker = WrapTerminalModeTracker()
        for sequence in [
            "\u{1b}[?2026h", "\u{1b}[?25l", "\u{1b}[?1006;1000;2004h",
            "\u{1b}[>1u", "\u{1b}[>4u", "\u{1b}[?1049h",
        ] {
            tracker.observe(Data(sequence.utf8))
        }

        #expect(tracker.restoreBytes == Data(
            "\u{1b}[?2026l\u{1b}[?25h\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?2004l"
                .appending("\u{1b}[<u\u{1b}[<u\u{1b}[?1049l").utf8
        ))
    }
}
