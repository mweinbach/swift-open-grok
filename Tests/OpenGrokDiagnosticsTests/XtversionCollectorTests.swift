// XtversionCollectorTests.swift
//
// Tests for the injectable XTVERSION probe: payload sanitizer, gate logic,
// and collector behavior (unavailable outside TTY, prerecorded injection).

import Testing
@testable import OpenGrokDiagnostics

@Suite("XTVERSION collector")
struct XtversionCollectorTests {

    // MARK: - Payload sanitizer

    @Suite("sanitizeXtversionPayload")
    struct SanitizeTests {
        @Test("plain payload passes through")
        func plainPayload() {
            #expect(sanitizeXtversionPayload("kitty 0.35.2") == "kitty 0.35.2")
            #expect(sanitizeXtversionPayload("XTerm(388)") == "XTerm(388)")
        }

        @Test("strips control characters and trims whitespace")
        func stripsControls() {
            #expect(sanitizeXtversionPayload(" We\u{01}zTerm 2.0 ") == "WezTerm 2.0")
        }

        @Test("empty or control-only payload returns nil")
        func emptyIsNil() {
            #expect(sanitizeXtversionPayload("") == nil)
            #expect(sanitizeXtversionPayload(" \u{07} ") == nil)
        }

        @Test("foot version format")
        func footVersion() {
            #expect(sanitizeXtversionPayload("foot(1.22.0)") == "foot(1.22.0)")
        }
    }

    // MARK: - Gate logic

    @Suite("gateAllowsXtversionProbe")
    struct GateTests {
        @Test("allows unknown and allowlisted brands without CSI-intercepting mux")
        func allowsBrands() {
            let brands: [TerminalName] = [.unknown, .kitty, .wezTerm, .ghostty, .iterm2, .rio]
            for brand in brands {
                let ctx = TerminalContext(brand: brand, multiplexer: .undetected)
                #expect(gateAllowsXtversionProbe(ctx), "\(brand) should be probed")
            }
        }

        @Test("allows transparent multiplexer (cmux)")
        func allowsCmux() {
            let ctx = TerminalContext(brand: .unknown, multiplexer: .cmux)
            #expect(gateAllowsXtversionProbe(ctx))
        }

        @Test("rejects CSI-intercepting multiplexers")
        func rejectsIntercepting() {
            for mux in [MultiplexerKind.tmux, .screen, .zellij, .herdr] {
                let ctx = TerminalContext(brand: .unknown, multiplexer: mux)
                #expect(!gateAllowsXtversionProbe(ctx), "\(mux) should block the probe")
            }
        }

        @Test("rejects non-allowlisted brands")
        func rejectsOtherBrands() {
            let reject: [TerminalName] = [
                .appleTerminal, .vsCode, .cursor, .windsurf, .alacritty,
                .jetBrains, .warpTerminal, .grokDesktop, .foot,
            ]
            for brand in reject {
                let ctx = TerminalContext(brand: brand, multiplexer: .undetected)
                #expect(!gateAllowsXtversionProbe(ctx), "\(brand) should not be probed")
            }
        }

        @Test("allowlisted brand under tmux is rejected")
        func allowlistedUnderTmux() {
            let ctx = TerminalContext(brand: .kitty, multiplexer: .tmux)
            #expect(!gateAllowsXtversionProbe(ctx))
        }
    }

    // MARK: - Collector behavior

    @Suite("UnavailableXtversionCollector")
    struct UnavailableTests {
        @Test("always returns unavailable")
        func alwaysUnavailable() {
            let collector = UnavailableXtversionCollector()
            let ctx = TerminalContext(brand: .unknown, multiplexer: .undetected)
            #expect(collector.collect(context: ctx) == .unavailable)
        }
    }

    @Suite("PrerecordedXtversionCollector")
    struct PrerecordedTests {
        @Test("injects pre-collected payload")
        func injectsPayload() {
            let collector = PrerecordedXtversionCollector(payload: "ghostty 1.2.0")
            let ctx = TerminalContext(brand: .ghostty, multiplexer: .undetected)
            #expect(collector.collect(context: ctx) == .available("ghostty 1.2.0"))
        }

        @Test("injects nil payload (no reply)")
        func injectsNoReply() {
            let collector = PrerecordedXtversionCollector(payload: nil)
            let ctx = TerminalContext(brand: .unknown, multiplexer: .undetected)
            #expect(collector.collect(context: ctx) == .available(nil))
        }

        @Test("injects unavailable evidence")
        func injectsUnavailable() {
            let collector = PrerecordedXtversionCollector(.unavailable)
            let ctx = TerminalContext(brand: .kitty, multiplexer: .undetected)
            #expect(collector.collect(context: ctx) == .unavailable)
        }
    }

    @Suite("LiveXtversionCollector gate rejection")
    struct LiveGateTests {
        @Test("returns unavailable when gate rejects the terminal")
        func gateRejectsAppleTerminal() {
            let collector = LiveXtversionCollector()
            let ctx = TerminalContext(brand: .appleTerminal, multiplexer: .undetected)
            #expect(collector.collect(context: ctx) == .unavailable)
        }

        @Test("returns unavailable when multiplexer intercepts CSI")
        func gateRejectsTmux() {
            let collector = LiveXtversionCollector()
            let ctx = TerminalContext(brand: .kitty, multiplexer: .tmux)
            #expect(collector.collect(context: ctx) == .unavailable)
        }
    }

    // MARK: - MultiplexerKind.interceptsCsiQueries

    @Suite("interceptsCsiQueries")
    struct InterceptsCsiTests {
        @Test("intercepting multiplexers")
        func intercepting() {
            #expect(MultiplexerKind.tmux.interceptsCsiQueries)
            #expect(MultiplexerKind.screen.interceptsCsiQueries)
            #expect(MultiplexerKind.zellij.interceptsCsiQueries)
            #expect(MultiplexerKind.herdr.interceptsCsiQueries)
        }

        @Test("non-intercepting multiplexers")
        func nonIntercepting() {
            #expect(!MultiplexerKind.cmux.interceptsCsiQueries)
            #expect(!MultiplexerKind.undetected.interceptsCsiQueries)
        }
    }
}
