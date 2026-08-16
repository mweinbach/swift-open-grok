import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("Wave E render")
struct WaveERenderTests {
    @Test("raw auth URL wraps without changing copy bytes")
    func rawAuthURLIsByteExact() {
        let url = "https://example.com/device?user_code=ABCD-1234&payload="
            + String(repeating: "z", count: 70)
        let auth = PagerWelcomeAuthState(
            providerName: "xAI Grok",
            phase: .trust,
            url: url,
            deviceCode: nil,
            rawURLMode: true
        )
        var buffer = CellBuffer.empty(TerminalRect(x: 0, y: 0, width: 19, height: 16))
        _ = renderPagerWelcomeAuth(
            auth,
            in: buffer.area,
            buffer: &buffer,
            theme: .grokNight
        )
        var reconstructed = ""
        for y in 4..<buffer.area.height {
            for x in 0..<buffer.area.width {
                guard let cell = buffer.cell(x: x, y: y), !cell.skip else { continue }
                if cell.grapheme != " " { reconstructed += cell.grapheme }
            }
        }
        #expect(reconstructed.hasPrefix(url))
        #expect(PagerWelcomeAuthState.deviceCode(from: url) == "ABCD-1234")
    }

    @Test("minimal below-prompt panels reuse list state")
    func minimalBelowPromptPanel() {
        var overlay = PagerOverlay.list(
            id: "sessions",
            title: "Resume a session",
            rows: [PagerListRow(id: "one", label: "First session")]
        )
        overlay.minimalBelowPrompt = true
        let height = pagerMinimalBelowPromptHeight(overlay, width: 50)
        var buffer = CellBuffer.empty(TerminalRect(x: 0, y: 0, width: 50, height: height))
        renderPagerMinimalBelowPrompt(
            overlay,
            in: buffer.area,
            buffer: &buffer,
            theme: .grokNight
        )
        let text = (0..<buffer.area.height).map { y in
            (0..<buffer.area.width).compactMap { x in
                buffer.cell(x: x, y: y)?.skip == false
                    ? buffer.cell(x: x, y: y)?.grapheme
                    : nil
            }.joined()
        }.joined(separator: "\n")
        #expect(text.contains("Resume a session"))
        #expect(text.contains("First session"))
        #expect(text.contains("search"))
    }

    @Test("all Wave E prompt kinds have distinct prefixes")
    func promptKindPrefixes() {
        #expect(PagerPromptKind.standard.prefix == "❯ ")
        #expect(PagerPromptKind.bash.prefix == "! ")
        #expect(PagerPromptKind.cron.prefix == "◷ ")
        #expect(PagerPromptKind.interjection.prefix == "↳ ")
        #expect(PagerPromptKind.skill.prefix == "◇ ")
    }

    @Test("expanded transcript uses typed painters and keeps plan comments")
    func expandedANSITranscript() {
        let items: [PagerConversationItem] = [
            .message(PagerMessage(role: .user, promptKind: .skill, text: "run the skill")),
            .block(.plan(PagerPlanBlock(
                id: "plan-1",
                body: "first\nsecond",
                comments: [1: "add regression coverage"],
                isExpanded: false
            ))),
            .block(.creditLimit(PagerCreditLimitBlock(
                id: "credit-1",
                action: .purchaseCredits,
                message: "Credits exhausted",
                accountURL: "https://grok.com?_s=usage"
            )))
        ]
        let ansi = pagerExpandedTranscriptANSI(
            items: items,
            width: 80,
            theme: .grokNight
        )
        #expect(ansi.contains("\u{1B}["))
        #expect(ansi.contains("◇ "))
        #expect(ansi.contains("run the skill"))
        #expect(ansi.contains("second"))
        #expect(ansi.contains("add regression coverage"))
        #expect(ansi.contains("Purchase Credits"))
        #expect(!ansi.contains("ctrl+e to expand"))
    }

    @Test("credit-limit actions keep their safe account URL")
    func creditLimitActions() {
        let url = "https://grok.com?_s=usage"
        let actions: [PagerCreditLimitAction] = [
            .enablePayAsYouGo,
            .increasePayAsYouGoLimit,
            .purchaseCredits,
        ]
        for (index, action) in actions.enumerated() {
            let block = PagerCreditLimitBlock(
                id: "credit-\(index)",
                action: action,
                message: "limit",
                accountURL: url
            )
            #expect(block.accountURL == url)
            #expect(!action.rawValue.isEmpty)
        }
    }
}
