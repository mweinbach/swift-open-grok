import Foundation
import OpenGrokMarkdown
import OpenGrokMarkdownCore
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("Markdown render fuzzing")
struct MarkdownRenderFuzzingTests {
    private static let chunkSizes = [1, 16, 32]

    @Test("render_all seeds and bounded mutations preserve render invariants")
    func renderAllSeeds() {
        for seed in RenderAllSeedCorpus.all {
            for source in mutations(of: seed.source) {
                for pretty in [true, false] {
                    let configuration = MarkdownRenderConfiguration(pretty: pretty)
                    let full = MarkdownRenderer(configuration: configuration).render(source)
                    assertOutputInvariants(full, source: source)

                    for chunkSize in Self.chunkSizes {
                        var streaming = StreamingMarkdownRenderer(configuration: configuration)
                        let characters = Array(source)
                        var offset = 0
                        while offset < characters.count {
                            let end = min(offset + chunkSize, characters.count)
                            _ = streaming.pushAndRender(String(characters[offset..<end]))
                            offset = end
                        }
                        #expect(streaming.finish() == full, "stream mismatch for \(seed.filename), pretty=\(pretty), chunk=\(chunkSize)")
                    }

                    let mapped = PagerMarkdownRenderer.map(full)
                    let rendered = PagerMarkdownRenderer(configuration: configuration).render(source)
                    #expect(rendered == mapped)
                    #expect(mapped.flatMap(\.spans).allSatisfy { !$0.text.isEmpty })
                    if !full.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        #expect(!mapped.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    #expect(mapped.flatMap(\.spans).filter { $0.url != nil }.allSatisfy { !$0.url!.isEmpty })
                }
            }
        }
    }

    private func mutations(of source: String) -> [String] {
        let characters = Array(source)
        var variants = [source]
        variants.append(source.replacingOccurrences(of: "\n", with: "\r\n"))
        for divisor in [2, 3, 5] where characters.count > divisor {
            variants.append(String(characters.prefix(max(1, characters.count / divisor))))
        }
        variants.append(source + "\n" + String(repeating: "*`_~", count: 8))
        variants.append(String(repeating: "#*`_~", count: 6) + "\n" + source)
        return variants
    }

    private func assertOutputInvariants(_ output: MarkdownRenderOutput, source: String) {
        #expect(output.lineSourceMap.count == output.lines.count)
        #expect(output.lines.count <= max(1, source.count * 4 + 64))
        for hyperlink in output.hyperlinks {
            #expect(output.lines.indices.contains(hyperlink.lineIndex))
            if output.lines.indices.contains(hyperlink.lineIndex) {
                let lineDisplayWidth = UnicodeDisplayWidth.width(of: output.lines[hyperlink.lineIndex].text)
                #expect(hyperlink.columnRange.lowerBound >= 0)
                #expect(hyperlink.columnRange.upperBound <= lineDisplayWidth)
                #expect(hyperlink.columnRange.lowerBound < hyperlink.columnRange.upperBound)
            }
            #expect(!hyperlink.url.isEmpty)
        }
        for codeBlock in output.codeBlocks {
            #expect(codeBlock.outputLineRange.lowerBound >= 0)
            #expect(codeBlock.outputLineRange.upperBound <= output.lines.count)
            #expect(codeBlock.sourceByteRange.lowerBound >= 0)
            #expect(codeBlock.sourceByteRange.upperBound <= source.utf8.count + 1)
        }
    }
}
