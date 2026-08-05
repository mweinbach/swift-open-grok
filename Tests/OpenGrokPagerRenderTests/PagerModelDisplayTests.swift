import Testing
import Foundation
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

private func frame(
    input: PagerComposerState,
    statusBar: PagerStatusBar? = nil,
    width: Int = 70,
    height: Int = 12
) -> [String] {
    renderPagerFrame(
        PagerRenderState(
            size: TerminalSize(width: width, height: height),
            statusBar: statusBar,
            conversation: [.message(PagerMessage(role: .assistant, text: "hi"))],
            input: input,
            showScrollbar: false
        )
    )
    .snapshot()
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
}

// MARK: - Composer

@Suite("Composer model display")
struct PagerComposerModelTests {
    @Test("the model name sits on the composer's bottom border")
    func modelOnBottomBorder() {
        let rows = frame(input: PagerComposerState(text: "", modelName: "Grok Build"))
        #expect(rows.contains { $0.contains("Grok Build") && $0.contains("╰") })
    }

    @Test("reasoning effort renders as a parenthetical after the name")
    func effortSuffix() {
        let state = PagerComposerState(
            text: "", modelName: "Grok Build", reasoningEffort: "xhigh"
        )
        #expect(state.modelDisplay == "Grok Build (xhigh)")
        #expect(frame(input: state).contains { $0.contains("Grok Build (xhigh)") })
    }

    @Test("a model with no selectable effort shows the bare name")
    func noEffort() {
        #expect(PagerComposerState(modelName: "Grok Build").modelDisplay == "Grok Build")
        // An effort that is present but blank must not produce empty parens.
        #expect(PagerComposerState(modelName: "Grok Build", reasoningEffort: "  ").modelDisplay
            == "Grok Build")
        #expect(PagerComposerState(modelName: nil, reasoningEffort: "high").modelDisplay == nil)
    }

    @Test("flags follow the model, separated by the reference's middle dot")
    func flagsAfterModel() {
        let rows = frame(input: PagerComposerState(
            text: "",
            modelName: "Grok Build",
            reasoningEffort: "high",
            flags: [
                PagerComposerFlag(label: "plan"),
                PagerComposerFlag(label: "always-approve")
            ]
        ))
        let border = rows.first { $0.contains("Grok Build") } ?? ""
        #expect(border.contains("Grok Build (high) · plan · always-approve"))
    }

    @Test("multiline is the right group and does not displace the model")
    func multilineIsRightAligned() {
        let rows = frame(input: PagerComposerState(
            text: "", modelName: "Grok Build", isMultiline: true
        ))
        let border = rows.first { $0.contains("Grok Build") } ?? ""
        #expect(border.contains("multiline"))
        #expect(border.range(of: "Grok Build")!.lowerBound < border.range(of: "multiline")!.lowerBound)
    }
}

// MARK: - Status bar

@Suite("Status bar context readout")
struct PagerContextReadoutTests {
    @Test("the context readout is `used / total` in the reference's compact form")
    func contextFormat() {
        let rows = frame(
            input: PagerComposerState(text: ""),
            statusBar: PagerStatusBar(contextUsedTokens: 8_500, contextTotalTokens: 1_000_000)
        )
        // `fmt_tokens` renders 1_000_000 as "1.0M": the `{:.1}M` branch covers
        // 1M..<10M, and the bare `{}M` form only starts at 10M
        // (`views/context_bar.rs:42-54`).
        #expect(rows.contains { $0.contains("8.5K / 1.0M") })
    }

    @Test("fmt_tokens matches the reference at every breakpoint")
    func tokenFormatting() {
        #expect(pagerFormatTokens(0) == "0")
        #expect(pagerFormatTokens(999) == "999")
        #expect(pagerFormatTokens(1_200) == "1.2K")
        #expect(pagerFormatTokens(12_000) == "12K")
        #expect(pagerFormatTokens(999_000) == "999K")
        #expect(pagerFormatTokens(1_200_000) == "1.2M")
        #expect(pagerFormatTokens(123_000_000) == "123M")
    }

    @Test("fmt_pct5 is always five columns, so the bar never shifts")
    func percentFormatting() {
        #expect(pagerFormatPercent(0) == "0.00%")
        #expect(pagerFormatPercent(5.125) == "5.12%")
        #expect(pagerFormatPercent(9.99) == "9.99%")
        #expect(pagerFormatPercent(10) == "10.0%")
        #expect(pagerFormatPercent(99.9) == "99.9%")
        #expect(pagerFormatPercent(100) == "MAX %")
        #expect(pagerFormatPercent(140) == "MAX %")
        for value in stride(from: 0.0, through: 100.0, by: 0.37) {
            #expect(pagerFormatPercent(value).count == 5)
        }
    }

    @Test("the readout is hidden without a context window rather than shown as 0")
    func hiddenWithoutTotal() {
        let rows = frame(
            input: PagerComposerState(text: ""),
            statusBar: PagerStatusBar(contextUsedTokens: 500, contextTotalTokens: 0)
        )
        #expect(!rows.contains { $0.contains("/ 0") })
    }

    @Test("the readout's color follows the usage ramp")
    func contextColorRamp() {
        let theme = PagerRenderTheme.grokNight
        #expect(pagerContextColor(fraction: 0, theme: theme) == theme.textPrimary)
        #expect(pagerContextColor(fraction: 0.5, theme: theme) == theme.accentUser)
        #expect(pagerContextColor(fraction: 0.85, theme: theme) == theme.warning)
        #expect(pagerContextColor(fraction: 1.0, theme: theme) == theme.accentError)
    }
}

// MARK: - Picker rows

@Suite("Model picker rows")
struct PagerModelPickerRowTests {
    @Test("a picker row carries provider, context window, and the current marker")
    func pickerRowShape() {
        let rows = [
            PagerListRow(
                id: "codex:gpt-5.6-sol",
                label: "OpenAI Codex · GPT-5.6 Sol",
                detail: "codex:gpt-5.6-sol",
                summary: "gpt-5.6-sol · 353.4K context · Fast reasoning"
            ),
            PagerListRow(
                id: "xai:grok-build",
                label: "xAI · Grok Build (current)",
                detail: "xai:grok-build  ✓",
                summary: "grok-build · 1M context"
            )
        ]
        let result = renderPagerFrame(
            PagerRenderState(
                size: TerminalSize(width: 90, height: 24),
                input: PagerComposerState(),
                showScrollbar: false,
                overlays: PagerOverlayStack([
                    PagerOverlay.list(id: "model", title: "Select model", rows: rows)
                ])
            )
        )
        let joined = result.snapshot()
        #expect(joined.contains("OpenAI Codex · GPT-5.6 Sol"))
        #expect(joined.contains("xAI · Grok Build (current)"))
        // The current model is marked, so the list answers "what am I on now?".
        #expect(joined.contains("✓"))
    }
}
