import Testing
import Foundation
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

private func themedFrame(
    _ theme: PagerRenderTheme,
    width: Int = 60,
    height: Int = 16
) -> PagerRenderResult {
    renderPagerFrame(
        PagerRenderState(
            size: TerminalSize(width: width, height: height),
            statusBar: PagerStatusBar(
                gitBranch: "main",
                contextUsedTokens: 8_500,
                contextTotalTokens: 1_000_000
            ),
            conversation: [
                .message(PagerMessage(role: .user, text: "hello")),
                .message(PagerMessage(role: .assistant, text: "hi"))
            ],
            input: PagerComposerState(text: "draft", modelName: "Grok Build"),
            theme: theme,
            showScrollbar: false
        )
    )
}

/// Every painted cell's colors, in order. Two themes paint the same glyphs, so
/// this — not the snapshot text — is what distinguishes them.
private func colorFingerprint(_ result: PagerRenderResult) -> String {
    let buffer = result.buffer
    var parts: [String] = []
    for y in buffer.area.top..<buffer.area.bottom {
        for x in buffer.area.left..<buffer.area.right {
            guard let cell = buffer.cell(x: x, y: y), !cell.skip else { continue }
            parts.append("\(cell.foreground)/\(cell.background)")
        }
    }
    return parts.joined(separator: ",")
}

// MARK: - Catalog

@Suite("Theme catalog")
struct PagerThemeCatalogTests {
    @Test("all six reference palettes are present and selectable in order")
    func sixThemes() {
        #expect(PagerThemeKind.selectable == [
            .grokNight, .grokDay, .tokyoNight, .rosePineMoon, .oscuraMidnight
        ])
        #expect(PagerThemeKind.allCases.count == 6)
    }

    @Test("theme names and every reference alias resolve")
    func aliases() {
        #expect(PagerThemeKind.named("groknight") == .grokNight)
        #expect(PagerThemeKind.named("dark") == .grokNight)
        #expect(PagerThemeKind.named("GROK-NIGHT") == .grokNight)
        #expect(PagerThemeKind.named("light") == .grokDay)
        #expect(PagerThemeKind.named("day") == .grokDay)
        #expect(PagerThemeKind.named("tokyo") == .tokyoNight)
        #expect(PagerThemeKind.named("rose-pine") == .rosePineMoon)
        #expect(PagerThemeKind.named("rosepine-moon") == .rosePineMoon)
        #expect(PagerThemeKind.named("oscura") == .oscuraMidnight)
        #expect(PagerThemeKind.named("nonsense") == nil)
        // `auto` is a preference, not a palette.
        #expect(PagerThemeKind.named("auto") == nil)
        #expect(PagerThemePreference.named("auto") == .auto)
        #expect(PagerThemePreference.named("system") == .auto)
    }

    @Test("display names are human-facing, including the one the reference drops")
    func displayNames() {
        #expect(PagerThemeKind.grokNight.displayName == "Grok Night")
        #expect(PagerThemeKind.rosePineMoon.displayName == "Rose Pine Moon")
        // Upstream's table omits this key and falls through to the raw slug.
        #expect(PagerThemeKind.oscuraMidnight.displayName == "Oscura Midnight")
    }

    @Test("the three ported themes carry the reference's exact anchor colors")
    func anchorColors() {
        #expect(PagerRenderTheme.tokyoNight.bgBase == .rgb(36, 40, 59))
        #expect(PagerRenderTheme.tokyoNight.accentUser == .rgb(122, 162, 247))
        #expect(PagerRenderTheme.tokyoNight.textPrimary == .rgb(192, 202, 245))

        #expect(PagerRenderTheme.rosePineMoon.bgBase == .rgb(35, 33, 54))
        #expect(PagerRenderTheme.rosePineMoon.accentAssistant == .rgb(196, 167, 231))
        #expect(PagerRenderTheme.rosePineMoon.command == .rgb(246, 193, 119))

        #expect(PagerRenderTheme.oscuraMidnight.bgBase == .rgb(3, 3, 4))
        #expect(PagerRenderTheme.oscuraMidnight.accentSystem == .rgb(125, 207, 223))
        // The scrollbar thumb is HIGHLIGHT_HIGH, not ELEVATED — the reference
        // fixed this because ELEVATED was darker than its own track.
        #expect(PagerRenderTheme.oscuraMidnight.scrollbarForeground == .rgb(52, 48, 72))
        #expect(PagerRenderTheme.oscuraMidnight.scrollbarBackground == .rgb(18, 16, 28))
    }

    @Test("GrokDay matches the reference rather than the port's earlier guess")
    func grokDayCorrected() {
        #expect(PagerRenderTheme.grokDay.bgBase == .rgb(238, 238, 238))
        #expect(PagerRenderTheme.grokDay.textPrimary == .rgb(38, 38, 38))
        #expect(PagerRenderTheme.grokDay.accentAssistant == .rgb(125, 75, 198))
        #expect(PagerRenderTheme.grokDay.accentModel == .rgb(10, 142, 112))
    }

    @Test("terminal_default uses only Reset and named ANSI colors")
    func terminalDefaultIsSafe() {
        let theme = PagerRenderTheme.terminalDefault
        for keyPath in PagerRenderTheme.colorSlots {
            switch theme[keyPath: keyPath] {
            case .rgb, .indexed:
                Issue.record("terminal_default must not carry an RGB or indexed color")
            default:
                break
            }
        }
    }

    @Test("polarity is measured, not declared")
    func polarity() {
        #expect(PagerRenderTheme.grokNight.isDark)
        #expect(PagerRenderTheme.tokyoNight.isDark)
        #expect(PagerRenderTheme.rosePineMoon.isDark)
        #expect(PagerRenderTheme.oscuraMidnight.isDark)
        #expect(!PagerRenderTheme.grokDay.isDark)
    }

    @Test("every theme paints a distinct frame")
    func themesAreDistinguishable() {
        var seen: Set<String> = []
        for kind in PagerThemeKind.selectable {
            let fingerprint = colorFingerprint(themedFrame(kind.theme))
            #expect(!seen.contains(fingerprint), "\(kind.rawValue) paints like another theme")
            seen.insert(fingerprint)
        }
        #expect(seen.count == PagerThemeKind.selectable.count)
    }

    @Test("a themed frame renders identical text regardless of palette")
    func themeChangesColorNotLayout() {
        let reference = themedFrame(.grokNight).snapshot()
        for kind in PagerThemeKind.selectable {
            #expect(themedFrame(kind.theme).snapshot() == reference,
                    "\(kind.rawValue) changed the layout, not just the colors")
        }
    }
}

// MARK: - Color support

@Suite("Color support detection")
struct PagerColorSupportTests {
    @Test("NO_COLOR wins over everything, at any value")
    func noColorWins() {
        #expect(pagerDetectColorLevel(environment: ["NO_COLOR": "", "COLORTERM": "truecolor"]) == .none)
        #expect(pagerDetectColorLevel(environment: ["NO_COLOR": "1", "TERM": "xterm-256color"]) == .none)
    }

    @Test("COLORTERM and known terminal programs report truecolor")
    func trueColorSources() {
        #expect(pagerDetectColorLevel(environment: ["TERM": "xterm", "COLORTERM": "truecolor"]) == .trueColor)
        #expect(pagerDetectColorLevel(environment: ["TERM": "xterm", "COLORTERM": "24bit"]) == .trueColor)
        #expect(pagerDetectColorLevel(environment: ["TERM": "xterm", "TERM_PROGRAM": "Ghostty"]) == .trueColor)
        #expect(pagerDetectColorLevel(environment: ["TERM": "xterm", "TERM_PROGRAM": "iTerm.app"]) == .trueColor)
    }

    @Test("TERM alone distinguishes 256 from 16")
    func termFallbacks() {
        #expect(pagerDetectColorLevel(environment: ["TERM": "xterm-256color"]) == .ansi256)
        #expect(pagerDetectColorLevel(environment: ["TERM": "xterm"]) == .basic)
    }

    @Test("a dumb or absent TERM reports no color on a tty, truecolor off one")
    func dumbTerminal() {
        #expect(pagerDetectColorLevel(environment: ["TERM": "dumb"], isTTY: true) == .none)
        #expect(pagerDetectColorLevel(environment: [:], isTTY: true) == .none)
        // Off a tty the output is being captured, not displayed, so nothing is lost
        // by keeping full color in the stream.
        #expect(pagerDetectColorLevel(environment: [:], isTTY: false) == .trueColor)
    }

    @Test("GROK_FORCE_COLOR_LEVEL overrides detection")
    func forcedLevel() {
        let env = ["TERM": "xterm-256color", "GROK_FORCE_COLOR_LEVEL": "basic"]
        #expect(pagerDetectColorLevel(environment: env) == .basic)
    }

    @Test("quantization folds RGB down and leaves named colors alone")
    func quantization() {
        #expect(pagerQuantize(.rgb(255, 0, 0), to: .trueColor) == .rgb(255, 0, 0))
        #expect(pagerQuantize(.rgb(255, 0, 0), to: .basic) == .brightRed)
        #expect(pagerQuantize(.rgb(0, 0, 0), to: .basic) == .black)
        #expect(pagerQuantize(.rgb(255, 255, 255), to: .basic) == .brightWhite)
        #expect(pagerQuantize(.rgb(120, 120, 120), to: .none) == .reset)
        #expect(pagerQuantize(.blue, to: .basic) == .blue)
        if case .indexed = pagerQuantize(.rgb(200, 100, 50), to: .ansi256) {} else {
            Issue.record("a 256-color terminal should receive an indexed color")
        }
    }

    @Test("a quantized theme carries no RGB left behind")
    func quantizedThemeIsComplete() {
        let folded = PagerRenderTheme.tokyoNight.quantized(to: .basic)
        for keyPath in PagerRenderTheme.colorSlots {
            if case .rgb = folded[keyPath: keyPath] {
                Issue.record("a slot survived quantization as RGB — colorSlots is missing a field")
            }
        }
    }
}

// MARK: - OSC-11 and appearance

private struct StubProbe: PagerOSC11Transport {
    var reply: String?
    func exchange(query: String, timeout: TimeInterval) throws -> String? { reply }
}

private struct FailingProbe: PagerOSC11Transport {
    struct Failure: Error {}
    func exchange(query: String, timeout: TimeInterval) throws -> String? { throw Failure() }
}

@Suite("OSC-11 background probe")
struct PagerOSC11Tests {
    @Test("the query is the reference's exact escape sequence")
    func querySequence() {
        #expect(PagerOSC11.query == "\u{1B}]11;?\u{07}")
        #expect(PagerOSC11.timeout == 0.5)
    }

    @Test("both channel widths parse to the same color")
    func parseChannelWidths() {
        let wide = PagerOSC11.parse(reply: "\u{1B}]11;rgb:1a1a/1b1b/2626\u{07}")
        #expect(wide?.red == 0x1a)
        #expect(wide?.green == 0x1b)
        #expect(wide?.blue == 0x26)

        let narrow = PagerOSC11.parse(reply: "\u{1B}]11;rgb:ff/ff/ff\u{07}")
        #expect(narrow?.red == 255)
        let padded = PagerOSC11.parse(reply: "\u{1B}]11;rgb:ffff/ffff/ffff\u{07}")
        #expect(padded?.red == 255)
    }

    @Test("a reply without an rgb payload yields nothing")
    func parseRejectsGarbage() {
        #expect(PagerOSC11.parse(reply: "not a reply") == nil)
        #expect(PagerOSC11.parse(reply: "\u{1B}]11;rgb:ff\u{07}") == nil)
    }

    @Test("luminance classification uses the 0.5 threshold on linearized sRGB")
    func classification() {
        #expect(PagerOSC11.classify(red: 0x1a, green: 0x1b, blue: 0x26) == .dark)
        #expect(PagerOSC11.classify(red: 255, green: 255, blue: 255) == .light)
        #expect(PagerOSC11.classify(red: 0, green: 0, blue: 0) == .dark)
    }

    @Test("a truncated reply is refused rather than half-parsed")
    func requiresTerminator() {
        #expect(PagerOSC11.detect(transport: StubProbe(reply: "\u{1B}]11;rgb:1a1a/1b1b/2626")) == nil)
        #expect(PagerOSC11.detect(transport: StubProbe(reply: "\u{1B}]11;rgb:1a1a/1b1b/2626\u{07}")) == .dark)
        // The ST terminator is equally valid.
        #expect(PagerOSC11.detect(
            transport: StubProbe(reply: "\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\")
        ) == .light)
    }

    @Test("a silent or failing terminal falls through instead of hanging a decision")
    func failureIsSilent() {
        #expect(PagerOSC11.detect(transport: StubProbe(reply: nil)) == nil)
        #expect(PagerOSC11.detect(transport: FailingProbe()) == nil)
    }
}

@Suite("Theme resolution")
struct PagerThemeResolutionTests {
    @Test("a fixed preference resolves to itself")
    func fixedPreference() {
        let resolved = pagerResolveTheme(preference: .fixed(.tokyoNight), colorLevel: .trueColor)
        #expect(resolved.kind == .tokyoNight)
        #expect(!resolved.followsSystemAppearance)
    }

    @Test("auto follows the detected appearance and honours the two overrides")
    func autoFollowsAppearance() {
        let dark = pagerResolveTheme(
            preference: .auto, colorLevel: .trueColor, appearance: .dark
        )
        #expect(dark.kind == .grokNight)
        #expect(dark.followsSystemAppearance)

        let light = pagerResolveTheme(
            preference: .auto, colorLevel: .trueColor, appearance: .light
        )
        #expect(light.kind == .grokDay)

        let overridden = pagerResolveTheme(
            preference: .auto, colorLevel: .trueColor, appearance: .dark,
            darkTheme: .oscuraMidnight, lightTheme: .grokDay
        )
        #expect(overridden.kind == .oscuraMidnight)
    }

    @Test("auto with no detection falls back to dark, which is the legible failure")
    func autoWithoutDetection() {
        let resolved = pagerResolveTheme(preference: .auto, colorLevel: .trueColor, appearance: nil)
        #expect(resolved.kind == .grokNight)
    }

    @Test("a truecolor-only theme is clamped before it is quantized")
    func clampBeforeQuantize() {
        let resolved = pagerResolveTheme(preference: .fixed(.rosePineMoon), colorLevel: .basic)
        // Folding Rose Pine's near-neighbour shades into 16 colors makes mush;
        // the reference falls back instead.
        #expect(resolved.kind == .grokNight)
        #expect(PagerThemeKind.available(colorLevel: .basic) == [.grokNight, .grokDay])
        #expect(PagerThemeKind.available(colorLevel: .trueColor).count == 5)
    }

    @Test("minimal mode locks the terminal palette and caps color at 16")
    func terminalNativeLock() {
        let resolved = pagerResolveTheme(
            preference: .fixed(.tokyoNight), colorLevel: .trueColor, terminalNativeLock: true
        )
        #expect(resolved.kind == .terminalDefault)
        #expect(resolved.colorLevel == .basic)
        #expect(!resolved.followsSystemAppearance)
    }

    @Test("a resolved theme is already quantized for the terminal it will paint on")
    func resolvedThemeIsQuantized() {
        let resolved = pagerResolveTheme(preference: .fixed(.grokNight), colorLevel: .basic)
        for keyPath in PagerRenderTheme.colorSlots {
            if case .rgb = resolved.theme[keyPath: keyPath] {
                Issue.record("resolution handed back an unquantized palette")
            }
        }
    }
}
