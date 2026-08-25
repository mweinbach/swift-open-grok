import Foundation
import Testing
@testable import OpenGrokTerminalCore

@Suite("OSC 8 hyperlink control-character security parity")
struct OSC8ControlSecurityParityTests {
    @Test(
        "Every C0, DEL, and C1 control is removed from hyperlink URLs",
        arguments: Array(0x00...0x1F) + Array(0x7F...0x9F)
    )
    func everyUnicodeControlIsRemoved(codePoint: Int) {
        guard let control = Unicode.Scalar(codePoint) else {
            Issue.record("Invalid control code point: \(codePoint)")
            return
        }

        let url = "https://safe.example/\(control)visible"

        #expect(
            ANSIOutput.osc8Open(url: url, id: nil)
                == "\u{1B}]8;;https://safe.example/visible\u{07}"
        )
        #expect(
            ANSIOutput.osc8Open(url: url, id: 42)
                == "\u{1B}]8;id=42;https://safe.example/visible\u{07}"
        )
    }

    @Test("Embedded C1 ST, CSI, and OSC cannot terminate or inject terminal sequences")
    func embeddedControlSequenceInjectionIsNeutralized() {
        let maliciousURL = "https://safe.example/\u{009C}\u{009B}31m"
            + "\u{009D}8;;https://evil.example\u{009C}\u{001B}[2J"
        let encoded = ANSIOutput.osc8Open(url: maliciousURL, id: nil)

        #expect(
            encoded
                == "\u{1B}]8;;https://safe.example/31m8;;https://evil.example[2J\u{07}"
        )
        #expect(controlValues(in: encoded) == [0x1B, 0x07])
    }

    @Test("Valid UTF-8, combining marks, and zero-width joiners remain unchanged")
    func validUnicodeAndFormatScalarsArePreserved() {
        let url = "https://例子.example/cafe\u{0301}/👩\u{200D}💻/✈️"
        let encoded = ANSIOutput.osc8Open(url: url, id: 9)
        let expected = "\u{1B}]8;id=9;\(url)\u{07}"

        #expect(encoded == expected)
        #expect(Array(encoded.utf8) == Array(expected.utf8))
        #expect(encoded.unicodeScalars.contains(Unicode.Scalar(0x200D)!))
        #expect(String(data: Data(encoded.utf8), encoding: .utf8) == expected)
        #expect(controlValues(in: encoded) == [0x1B, 0x07])
    }

    @Test("Encoded cell streams contain only intentional OSC and cursor framing controls")
    func encodedCellStreamCannotEmitInjectedControls() {
        let label = "文"
        let encoded = CellStreamEncoder.encode(
            updates: [CellUpdate(x: 0, y: 0, cell: Cell(grapheme: label))],
            linkIds: [1],
            linkTable: [LinkRef(url: "https://safe.example/\u{009C}\u{009B}label")],
            area: TerminalRect(x: 0, y: 0, width: 2, height: 1)
        )

        guard let output = String(data: encoded, encoding: .utf8) else {
            Issue.record("Encoded OSC 8 cell stream is not valid UTF-8")
            return
        }

        #expect(
            output
                == "\u{1B}]8;;https://safe.example/label\u{07}"
                + "\u{1B}[1;1H\(label)\u{1B}]8;;\u{07}"
        )
        #expect(controlValues(in: output) == [0x1B, 0x07, 0x1B, 0x1B, 0x07])
    }

    @Test("The live terminal backend strips all 65 controls while preserving its visible label")
    func liveTerminalOutputContainsOnlyIntentionalOSC8Framing() throws {
        let codePoints = Array(0x00...0x1F) + Array(0x7F...0x9F)
        let controls = String(String.UnicodeScalarView(codePoints.compactMap(Unicode.Scalar.init)))
        let backend = RecordingBackend(size: TerminalSize(width: 2, height: 1))
        let label = "文"

        #expect(codePoints.count == 65)
        try backend.drawWithLinks(
            [CellUpdate(x: 0, y: 0, cell: Cell(grapheme: label))],
            linkIds: [1],
            linkTable: [LinkRef(url: "https://safe.example/\(controls)label", id: 7)],
            area: TerminalRect(x: 0, y: 0, width: 2, height: 1)
        )

        let output = backend.memoryWriter.utf8String
        #expect(
            output
                == "\u{1B}]8;id=7;https://safe.example/label\u{07}"
                + "\(label)\u{1B}]8;;\u{07}"
        )
        #expect(controlValues(in: output) == [0x1B, 0x07, 0x1B, 0x07])
    }

    private func controlValues(in output: String) -> [UInt32] {
        output.unicodeScalars
            .filter { $0.properties.generalCategory == .control }
            .map(\.value)
    }
}
