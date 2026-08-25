import Testing
@testable import OpenGrokMarkdown

@Suite("Markdown streaming CRLF parity")
struct MarkdownStreamingCRLFParityTests {
    @Test("CRLF paragraph boundaries freeze complete prefixes and preserve source bytes")
    func crlfParagraphBoundary() {
        let prefix = "Stable **prefix**.\r\n\r\n"
        var renderer = StreamingMarkdownRenderer()

        let output = renderer.pushAndRender(prefix + "Tail")

        #expect(renderer.frozenBytes == prefix.utf8.count)
        #expect(renderer.frozenLinesCount > 0)
        #expect(renderer.lastCheckpoint?.sourceBytes == prefix.utf8.count)
        #expect(renderer.lastCheckpoint?.kind == .paragraph)
        #expect(output == MarkdownRenderer().render(renderer.source))
    }

    @Test("CRLF-frozen tails retain their original source-line offsets")
    func crlfSourceLineOffsets() {
        var renderer = StreamingMarkdownRenderer()
        renderer.pushAndRender("# First\r\n\r\nSecond")

        let output = renderer.pushAndRender(" paragraph")

        #expect(renderer.lastRenderedSourceByteCount < renderer.source.utf8.count)
        #expect(output == MarkdownRenderer().render(renderer.source))
        #expect(output.lineSourceMap.last == 2)
    }

    @Test("CRLF table checkpoints preserve the upstream table classification")
    func crlfTableCheckpoint() {
        let source = "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\n\r\n"
        var renderer = StreamingMarkdownRenderer()

        renderer.pushAndRender(source)

        #expect(renderer.lastCheckpoint?.kind == .table)
        #expect(renderer.frozenBytes == source.utf8.count)
        #expect(renderer.frozenLinesCount > 0)
    }

    @Test("a CRLF split across streaming chunks never freezes an invalid UTF-8 boundary")
    func crlfSplitAcrossChunks() {
        var renderer = StreamingMarkdownRenderer()

        renderer.pushAndRender("Prefix\r\n\r")
        #expect(renderer.frozenBytes == 0)

        let output = renderer.pushAndRender("\nTail")

        #expect(renderer.frozenBytes == "Prefix\r\n\r\n".utf8.count)
        #expect(output == MarkdownRenderer().render(renderer.source))
    }

    @Test("mixed newline styles freeze the final complete blank-line boundary")
    func mixedNewlineStyles() {
        let prefix = "First\r\n\r\nSecond\n\nThird\r\r"
        var renderer = StreamingMarkdownRenderer()

        renderer.pushAndRender(prefix + "Tail")

        #expect(renderer.frozenBytes == prefix.utf8.count)
        #expect(renderer.frozenLinesCount > 0)
        #expect(renderer.output == MarkdownRenderer().render(renderer.source))
    }

    @Test("CRLF fenced code does not freeze blank lines inside an open fence")
    func crlfFenceBoundary() {
        let openFence = "```swift\r\nlet first = 1\r\n\r\nlet second = 2\r\n"
        var renderer = StreamingMarkdownRenderer()

        renderer.pushAndRender(openFence)
        #expect(renderer.frozenBytes == 0)

        let source = openFence + "```\r\n\r\nTail"
        let output = renderer.pushAndRender("```\r\n\r\nTail")

        #expect(renderer.lastCheckpoint?.kind == .codeBlock)
        #expect(renderer.frozenBytes == (openFence + "```\r\n\r\n").utf8.count)
        #expect(output == MarkdownRenderer().render(source))
    }

    @Test("CRLF streaming converges at every Unicode character boundary")
    func everyUnicodeChunkBoundary() {
        let source = "# 🚀 Heading\r\n\r\nBefore [link](https://example.com).\r\n\r\n## 漢字\r\n\r\nTail"
        let expected = MarkdownRenderer().render(source)

        for boundary in source.indices {
            var renderer = StreamingMarkdownRenderer()
            renderer.pushAndRender(String(source[..<boundary]))
            renderer.pushAndRender(String(source[boundary...]))

            #expect(renderer.finish() == expected)
        }
    }
}
