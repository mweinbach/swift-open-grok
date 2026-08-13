// PagerSettingsRegistryMouseTests.swift
//
// Pins the five live Mouse rows against Rust `settings/defs.rs:1615-1744`
// at pin `650c1db7`, including `keep_text_selection` once the live
// transcript text-selection reader exists.

import Foundation
import Testing
@testable import OpenGrokPagerRender

@Suite("Mouse scroll settings registry")
struct PagerSettingsRegistryMouseTests {
    @Test("Mouse catalog order is scroll_* → invert_scroll → keep_text_selection")
    func mouseCatalogOrder() {
        let keys = PagerSettingsRegistry.default.rows(in: .mouse).map(\.key)
        #expect(keys == [
            "scroll_speed", "scroll_mode", "scroll_lines", "invert_scroll",
            "keep_text_selection",
        ])
    }

    @Test("keep_text_selection: Enum flash|hold|word_select, live-apply, no restart")
    func keepTextSelectionMetadata() throws {
        // defs.rs:1715-1744 + TEXT_SELECTION_CHOICES defs.rs:318-334 at 650c1db7.
        let meta = try #require(PagerSettingsRegistry.default.find("keep_text_selection"))
        #expect(meta.category == .mouse)
        #expect(meta.label == "Text selection")
        #expect(meta.description
            == "How long in-app selection stays on screen and what double-click does "
            + "(fold vs. select & copy a word). For your terminal or multiplexer's own "
            + "selection, hold Shift while dragging (native copy).")
        #expect(meta.keywords == [
            "selection", "drag", "copy", "flash", "hold", "shift", "native",
            "mouse", "tmux", "double", "double-click", "word", "terminal",
        ])
        #expect(meta.storage == .config(path: "ui.keep_text_selection"))
        #expect(meta.restartRequired == false)
        #expect(meta.hiddenInMinimal == false)
        guard case .enumeration(let defaultValue, let choices, let supportsPreview) = meta.kind else {
            Issue.record("keep_text_selection must be enumeration, got \(meta.kind)")
            return
        }
        #expect(defaultValue == "flash")
        #expect(supportsPreview == false)
        #expect(choices.map(\.canonical) == ["flash", "hold", "word_select"])
        #expect(choices.map(\.display) == [
            "Flash after copy",
            "Hold until dismissed",
            "Word select (terminal-like)",
        ])
        #expect(choices.map(\.summary) == [
            "Brief highlight on mouse-up, then clear. Double-click toggles fold. Default.",
            "Keep the selection visible until Esc, click, or scroll. Double-click toggles fold.",
            "Double-click selects & copies a word, triple-click a line; selection stays until dismissed.",
        ])
        #expect(meta.defaultValue == .string("flash"))
        // Typo regression: hyphenated `word-select` must not ship.
        #expect(!choices.map(\.canonical).contains("word-select"))
        #expect(PagerKeepTextSelectionMode.fromCanonical("word_select") == .wordSelect)
    }

    @Test("scroll_speed: Int 1…100 default 50, ui.scroll_speed, live-apply")
    func scrollSpeedMetadata() throws {
        // defs.rs:1615-1632 at 650c1db7.
        let meta = try #require(PagerSettingsRegistry.default.find("scroll_speed"))
        #expect(meta.category == .mouse)
        #expect(meta.label == "Scroll speed")
        #expect(meta.description
            == "Mouse-wheel and trackpad scroll speed multiplier (1-100). Higher = faster.")
        #expect(meta.keywords == ["scroll", "speed", "mouse", "wheel", "trackpad", "fast", "slow"])
        #expect(meta.storage == .config(path: "ui.scroll_speed"))
        #expect(meta.restartRequired == false)
        #expect(meta.hiddenInMinimal == false)
        guard case .integer(let defaultValue, let minimum, let maximum) = meta.kind else {
            Issue.record("scroll_speed must be integer, got \(meta.kind)")
            return
        }
        #expect(defaultValue == 50)
        #expect(minimum == 1)
        #expect(maximum == 100)
        #expect(meta.defaultValue == .integer(50))
    }

    @Test("scroll_mode: Enum auto|wheel|trackpad, ui.scroll_mode, no preview, live-apply")
    func scrollModeMetadata() throws {
        // defs.rs:1633-1656 + SCROLL_MODE_CHOICES defs.rs:300-316 at 650c1db7.
        let meta = try #require(PagerSettingsRegistry.default.find("scroll_mode"))
        #expect(meta.category == .mouse)
        #expect(meta.label == "Scroll input")
        #expect(meta.description
            == "Force wheel or trackpad scroll behavior when auto-detection misreads your device.")
        #expect(meta.keywords
            == ["scroll", "mode", "wheel", "trackpad", "mouse", "detect", "force", "input"])
        #expect(meta.storage == .config(path: "ui.scroll_mode"))
        #expect(meta.restartRequired == false)
        #expect(meta.hiddenInMinimal == false)
        guard case .enumeration(let defaultValue, let choices, let supportsPreview) = meta.kind else {
            Issue.record("scroll_mode must be enumeration, got \(meta.kind)")
            return
        }
        #expect(defaultValue == "auto")
        #expect(supportsPreview == false)
        #expect(choices.map(\.canonical) == ["auto", "wheel", "trackpad"])
        #expect(choices.map(\.display) == ["Auto-detect", "Mouse wheel", "Trackpad"])
        #expect(choices.map(\.summary) == [
            "Detect wheel vs trackpad per gesture from event timing. Default.",
            "Always treat scrolling as wheel notches (fixed lines per tick).",
            "Always treat scrolling as a trackpad (fractional accumulation)."
        ])
        #expect(meta.defaultValue == .string("auto"))
    }

    @Test("scroll_lines: Int 1…10 default 3, ui.scroll_lines, live-apply")
    func scrollLinesMetadata() throws {
        // defs.rs:1657-1678 at 650c1db7.
        let meta = try #require(PagerSettingsRegistry.default.find("scroll_lines"))
        #expect(meta.category == .mouse)
        #expect(meta.label == "Scroll lines")
        #expect(meta.description
            == "Lines per scroll tick for both wheel and trackpad (1-10). "
            + "Until set, each terminal's own profile applies.")
        #expect(meta.keywords
            == ["scroll", "lines", "tick", "notch", "wheel", "trackpad", "mouse"])
        #expect(meta.storage == .config(path: "ui.scroll_lines"))
        #expect(meta.restartRequired == false)
        #expect(meta.hiddenInMinimal == false)
        guard case .integer(let defaultValue, let minimum, let maximum) = meta.kind else {
            Issue.record("scroll_lines must be integer, got \(meta.kind)")
            return
        }
        #expect(defaultValue == 3)
        #expect(minimum == 1)
        #expect(maximum == 10)
        #expect(meta.defaultValue == .integer(3))
    }

    @Test("invert_scroll: Bool default false, ui.invert_scroll, live-apply")
    func invertScrollMetadata() throws {
        // defs.rs:1679-1700 at 650c1db7.
        let meta = try #require(PagerSettingsRegistry.default.find("invert_scroll"))
        #expect(meta.category == .mouse)
        #expect(meta.label == "Invert scroll")
        #expect(meta.description == "Reverse vertical scroll direction (natural scrolling).")
        #expect(meta.keywords
            == ["invert", "scroll", "natural", "direction", "reverse", "mouse", "trackpad"])
        #expect(meta.storage == .config(path: "ui.invert_scroll"))
        #expect(meta.restartRequired == false)
        #expect(meta.hiddenInMinimal == false)
        guard case .bool(let defaultValue) = meta.kind else {
            Issue.record("invert_scroll must be bool, got \(meta.kind)")
            return
        }
        #expect(defaultValue == false)
        #expect(meta.defaultValue == .bool(false))
    }
}
