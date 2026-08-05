import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPager

@Suite("PagerMarkdownRenderer")
struct PagerMarkdownRenderingTests {
    private let renderer = PagerMarkdownRenderer()

    private func spans(_ source: String) -> [PagerStyledSpan] {
        renderer.render(source).flatMap(\.spans)
    }

    @Test("headings map to bold accent spans")
    func headings() {
        let heading = spans("# Title").first { $0.text.contains("Title") }
        #expect(heading != nil)
        #expect(heading?.style.contains(.bold) == true)
        #expect(heading?.foreground == .brightCyan)

        let deeper = spans("### Deeper").first { $0.text.contains("Deeper") }
        #expect(deeper?.style.contains(.bold) == true)
        // Only the top level is underlined, so nesting stays visually distinct.
        #expect(deeper?.style.contains(.underline) == false)
    }

    @Test("bold and italic map to the matching cell styles")
    func emphasis() {
        let bold = spans("**loud**").first { $0.text.contains("loud") }
        #expect(bold?.style.contains(.bold) == true)
        // Inline emphasis inherits the message color rather than overriding it.
        #expect(bold?.foreground == nil)

        let italic = spans("*quiet*").first { $0.text.contains("quiet") }
        #expect(italic?.style.contains(.italic) == true)

        let struck = spans("~~gone~~").first { $0.text.contains("gone") }
        #expect(struck?.style.contains(.strike) == true)
    }

    @Test("code spans and fenced code blocks map to the code color")
    func code() {
        let inline = spans("use `printf` here").first { $0.text.contains("printf") }
        #expect(inline?.foreground == .brightYellow)

        let fenced = spans("```swift\nlet x = 1\n```")
        let body = fenced.first { $0.text.contains("let x = 1") }
        #expect(body != nil)
        #expect(body?.foreground == .brightYellow)
    }

    @Test("list markers are styled separately from item text")
    func lists() {
        let unordered = renderer.render("- first\n- second")
        #expect(unordered.count >= 2)
        let marker = unordered.flatMap(\.spans).first { $0.foreground == .brightCyan }
        #expect(marker != nil)
        #expect(unordered.map(\.text).joined(separator: "\n").contains("first"))
        #expect(unordered.map(\.text).joined(separator: "\n").contains("second"))

        let ordered = renderer.render("1. one\n2. two")
        #expect(ordered.contains { $0.text.contains("one") })
        #expect(ordered.contains { $0.text.contains("two") })
    }

    @Test("links carry their destination on the styled span")
    func links() {
        let rendered = spans("see [Example](https://example.com) now")
        let link = rendered.first { $0.url != nil }
        #expect(link != nil)
        #expect(link?.url == "https://example.com")
        #expect(link?.text.contains("Example") == true)
        #expect(link?.style.contains(.underline) == true)
        #expect(link?.foreground == .brightBlue)
    }

    @Test("plain prose renders as a single inheriting span")
    func plainProse() {
        let rendered = renderer.render("just a sentence")
        #expect(rendered.map(\.text).joined().contains("just a sentence"))
        #expect(rendered.flatMap(\.spans).allSatisfy { $0.foreground == nil && $0.style.isEmpty })
    }

    @Test("empty source yields no styled lines so callers fall back to plain text")
    func emptySource() {
        #expect(renderer.render("").isEmpty)
    }

    @Test("unterminated markdown still renders its visible text")
    func malformedInput() {
        // An unclosed fence and a dangling emphasis must not lose content.
        let rendered = renderer.render("```swift\nlet x = 1")
        #expect(rendered.map(\.text).joined().contains("let x = 1"))

        let dangling = renderer.render("**never closed")
        #expect(dangling.map(\.text).joined().contains("never closed"))
    }
}
