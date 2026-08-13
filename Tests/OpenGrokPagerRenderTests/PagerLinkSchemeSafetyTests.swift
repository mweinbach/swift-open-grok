// PagerLinkSchemeSafetyTests.swift
//
// Pure Standard-scheme gate + paint-time LinkSpan filtering against
// `SchemeFilter::Standard` / `is_safe_to_open` at pin 650c1db7. No browser
// side effects.

import Foundation
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

@Suite("Pager link scheme safety")
struct PagerLinkSchemeSafetyTests {
    @Test("standard filter allows http https mailto only")
    func standardAllowsMatrix() {
        #expect(pagerURLIsSafeToOpen("http://example.com"))
        #expect(pagerURLIsSafeToOpen("https://example.com/path?q=1"))
        #expect(pagerURLIsSafeToOpen("mailto:user@example.com"))
        #expect(pagerURLIsSafeToOpen("  https://example.com  "))
        #expect(pagerURLIsSafeToOpen("HTTPS://EXAMPLE.COM"))
        #expect(pagerURLIsSafeToOpen("MAILTO:user@example.com"))

        #expect(!pagerURLIsSafeToOpen("file:///tmp/doc.pdf"))
        #expect(!pagerURLIsSafeToOpen("javascript:alert(1)"))
        #expect(!pagerURLIsSafeToOpen("custom://something"))
        #expect(!pagerURLIsSafeToOpen("data:text/html,<h1>hi</h1>"))
        #expect(!pagerURLIsSafeToOpen("ftp://files.example.com/pub"))
        #expect(!pagerURLIsSafeToOpen("vscode://file/path"))
        #expect(!pagerURLIsSafeToOpen("tel:+1234567890"))
        #expect(!pagerURLIsSafeToOpen(""))
        #expect(!pagerURLIsSafeToOpen("not-a-url"))
        #expect(!pagerURLIsSafeToOpen("://missing-scheme"))
        // Relative / absolute filesystem paths are not Standard URLs —
        // must not be treated as openable (upstream resolves some relative
        // media links via LinkTarget::File, not this filter).
        #expect(!pagerURLIsSafeToOpen("videos/1.mp4"))
        #expect(!pagerURLIsSafeToOpen("/tmp/secret"))
        #expect(!pagerURLIsSafeToOpen("~/Desktop/x.md"))
    }

    @Test("editorExtended allows file and editor schemes but not javascript")
    func editorExtendedMatrix() {
        #expect(pagerURLIsSafeToOpen("file:///tmp/doc.pdf", filter: .editorExtended))
        #expect(pagerURLIsSafeToOpen("vscode://file/path", filter: .editorExtended))
        #expect(!pagerURLIsSafeToOpen("javascript:alert(1)", filter: .editorExtended))
        #expect(!pagerURLIsSafeToOpen("custom://x", filter: .editorExtended))
    }

    @Test("paint publishes http https mailto LinkSpans and drops unsafe schemes")
    func paintPublishesOnlySafeSchemes() {
        func frame(url: String, label: String = "Label") -> PagerRenderResult {
            renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 40, height: 8),
                conversation: [
                    .message(PagerMessage(
                        role: .assistant,
                        text: "see \(label)",
                        styledLines: [PagerStyledLine(spans: [
                            PagerStyledSpan(text: "see "),
                            PagerStyledSpan(
                                text: label,
                                style: [.underline],
                                url: url
                            )
                        ])]
                    ))
                ],
                input: PagerComposerState(text: "", isFocused: false),
                showScrollbar: false
            ))
        }

        for url in [
            "http://example.com/a",
            "https://example.com/b",
            "mailto:user@example.com",
        ] {
            let result = frame(url: url)
            #expect(result.links.count == 1, "expected publish for \(url)")
            #expect(result.links.first?.url == url)
            // Label text still paints when the link is published.
            #expect(result.snapshot().contains("Label"))
        }

        for url in [
            "file:///tmp/doc.pdf",
            "javascript:alert(1)",
            "custom://something",
            "videos/1.mp4",
            "/tmp/secret",
        ] {
            let result = frame(url: url, label: "Unsafe")
            #expect(result.links.isEmpty, "must not publish \(url)")
            // Text still paints — only the hyperlink region is omitted.
            #expect(result.snapshot().contains("Unsafe"))
        }
    }
}
