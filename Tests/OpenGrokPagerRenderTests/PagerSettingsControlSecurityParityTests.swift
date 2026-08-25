import OpenGrokTerminalCore
import Testing

@testable import OpenGrokPagerRender

@Suite("Settings modal terminal control injection protection")
struct PagerSettingsControlSecurityParityTests {
    @Test("all C0, DEL, and C1 controls are refused", arguments: Array(0...31) + Array(127...159))
    func terminalControlsCannotEnterSettings(_ value: Int) {
        let scalar = Unicode.Scalar(value)!
        let character = Character(scalar)

        #expect(!isSafeSettingsCharacter(character))

        let overlay = PagerSettingsOverlay()
        #expect(overlay.validateSecret("safe\(scalar)secret") == "Key contains control characters")
    }

    @Test("bidirectional and invisible formatting controls are refused", arguments: [
        0x061C, 0x200B, 0x200F, 0x202A, 0x202E, 0x2060, 0x2069, 0xFEFF,
    ])
    func invisibleFormattingCannotEnterSettings(_ value: Int) {
        let scalar = Unicode.Scalar(value)!

        #expect(!isSafeSettingsCharacter(Character(scalar)))
        #expect(PagerSettingsOverlay().validateSecret("key\(scalar)")
            == "Key contains control characters")
    }

    @Test("safe multilingual text remains accepted")
    func ordinaryUnicodeRemainsAvailable() {
        #expect(isSafeSettingsCharacter("é"))
        #expect(isSafeSettingsCharacter("語"))
        #expect(PagerSettingsOverlay().validateSecret("safe-é-語") == nil)
    }

    @Test("filter input rejects terminal escapes and bidi overrides")
    func filteringRejectsUntrustedControlInput() {
        for scalar in [Unicode.Scalar(0x9B)!, Unicode.Scalar(0x202E)!] {
            var overlay = PagerSettingsOverlay()
            overlay.mode = .filtering
            let character = Character(scalar)
            let outcome = overlay.handle(KeyEvent(
                key: .char(character),
                modifiers: [],
                character: character
            ))

            #expect(outcome == .consumed)
            #expect(overlay.filterQuery.isEmpty)
        }
    }
}
