import Testing
@testable import OpenGrokMarkdown

@Suite("OpenGrok Markdown renderer")
struct OpenGrokMarkdownTests {
    private let fence = String(repeating: Character(UnicodeScalar(96)!), count: 3)

    @Test("pretty rendering produces deterministic terminal lines")
    func prettyRendering() {
        let source = """
        # Title

        A **bold** [link](https://example.com).

        - first
        - second

        > quoted

        \(fence)swift
        let value = 1
        \(fence)
        """
        let output = MarkdownRenderer().render(source)
        let lines = output.lines.map(\.text)
        #expect(lines.contains("Title"))
        #expect(lines.contains("• first"))
        #expect(lines.contains("• second"))
        #expect(lines.contains("│ quoted"))
        #expect(lines.contains("  let value = 1"))
        #expect(!lines.contains(where: { $0.contains(fence) }))
        #expect(output.hyperlinks.count == 2)
        #expect(output.hyperlinks[0].url == "https://example.com")
        #expect(output.hyperlinks[0].columnRange == 7..<11)
        #expect(output.codeBlocks.count == 1)
        #expect(output.codeBlocks[0].info == "swift")
    }

    @Test("raw mode preserves markdown delimiters")
    func rawRendering() {
        let source = "# Title\n\n**bold** [link](https://example.com)\n"
        let output = MarkdownRenderer(pretty: false).render(source)
        #expect(output.text.contains("# Title"))
        #expect(output.text.contains("**bold**"))
        #expect(output.text.contains("[link](https://example.com)"))
        #expect(output.lines.count == output.lineSourceMap.count)
    }

    @Test("tables use stable box drawing and respect width limits")
    func tableRendering() {
        let source = "| Name | Description |\n| --- | --- |\n| Alpha | A long description |\n"
        let output = MarkdownRenderer(configuration: MarkdownRenderConfiguration(maxTableWidth: 24)).render(source)
        #expect(output.lines.count >= 5)
        #expect(output.lines.first?.text.first == "┌")
        #expect(output.lines.last?.text.first == "└")
        #expect(output.lines.allSatisfy { $0.text.count <= 24 })
        #expect(output.text.contains("Alpha"))
        #expect(output.text.contains("description"))
    }

    @Test("soft-break mode is explicit and deterministic")
    func softBreakModes() {
        let source = "first\nsecond"
        let collapsed = MarkdownRenderer().render(source)
        #expect(collapsed.text == "first second")

        let preserved = MarkdownRenderer(configuration: MarkdownRenderConfiguration(collapseSoftBreaks: false)).render(source)
        #expect(preserved.lines.map(\.text) == ["first", "second"])
        #expect(preserved.lineSourceMap == [0, 1])
    }

    @Test("streaming output equals full output for every chunk boundary")
    func fullAndChunkedEquivalence() {
        let source = """
        # Stream

        Before **formatting** and [a link](https://example.com).

        \(fence)swift
        let result = 1
        \(fence)

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let full = MarkdownRenderer().render(source)
        for split in 0...source.count {
            let cut = source.index(source.startIndex, offsetBy: split)
            var renderer = StreamingMarkdownRenderer()
            renderer.pushAndRender(String(source[..<cut]))
            renderer.push(String(source[cut...]))
            let chunked = renderer.finish()
            #expect(chunked == full, "Mismatch at split \(split)")
        }
    }

    @Test("streaming state resets preserve source and rerender deterministically")
    func streamingState() {
        var renderer = StreamingMarkdownRenderer()
        renderer.push("## Title\n\nBody")
        #expect(renderer.output.lines.isEmpty)
        renderer.render()
        #expect(renderer.output.text == "Title\n\nBody")
        renderer.setPretty(false)
        #expect(renderer.output.lines.isEmpty)
        let raw = renderer.finish()
        #expect(raw.text == "## Title\n\nBody")
        renderer.clear()
        #expect(renderer.source.isEmpty)
        #expect(renderer.output.lines.isEmpty)
    }

    @Test("fenced Swift, Rust, and citation info produce syntax spans and code backgrounds")
    func fencedSyntaxAndCitation() {
        let swift = MarkdownRenderer().render("```swift\nlet value: String = \"ok\" // note\n```")
        let swiftStyles = swift.lines.flatMap(\.segments).map(\.style)
        #expect(swiftStyles.contains(.syntaxKeyword))
        #expect(swiftStyles.contains(.syntaxType))
        #expect(swiftStyles.contains(.syntaxString))
        #expect(swiftStyles.contains(.syntaxComment))
        #expect(swift.lines.contains { $0.background == .code })

        let rust = MarkdownRenderer().render("```rust\nfn main() { let count = 42; }\n```")
        let rustStyles = rust.lines.flatMap(\.segments).map(\.style)
        #expect(rustStyles.contains(.syntaxKeyword))
        #expect(rustStyles.contains(.syntaxNumber))

        let citation = MarkdownRenderer().render(
            "```10:12:Sources/App.swift\nlet enabled = true\n```"
        )
        #expect(citation.lines.flatMap(\.segments).contains { $0.style == .syntaxKeyword })
        #expect(markdownFenceLanguage("10:12:Sources/App.swift") == "swift")
    }

    @Test("streaming renderer parses only the unfrozen tail after a checkpoint")
    func streamingFrozenPrefixReuse() {
        var renderer = StreamingMarkdownRenderer()
        renderer.pushAndRender("Stable **prefix**.\n\nTail")
        #expect(renderer.frozenBytes > 0)

        let output = renderer.pushAndRender(" grows")
        #expect(renderer.lastRenderedSourceByteCount < renderer.source.utf8.count)
        #expect(output == MarkdownRenderer().render(renderer.source))
    }

    @Test("finish performs an authoritative full render after many checkpoints")
    func streamingFinishFullRender() {
        let block = """
        ## Architecture Overview

        The **streaming** pager keeps [links](https://example.com) stable.

        - first item
          - nested item

        ```swift
        let value = "wide unicode 🚀 漢字"
        ```

        | stage | cached |
        |---|---|
        | markdown | yes |

        """
        let source = String(repeating: block, count: 8)
        var renderer = StreamingMarkdownRenderer()
        let characters = Array(source)
        var offset = 0
        while offset < characters.count {
            let end = min(offset + 32, characters.count)
            renderer.pushAndRender(String(characters[offset..<end]))
            offset = end
        }

        #expect(renderer.finish() == MarkdownRenderer().render(source))
        #expect(renderer.frozenBytes == source.utf8.count)
    }
}
