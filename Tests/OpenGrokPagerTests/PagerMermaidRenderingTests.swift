import Foundation
import Testing
@testable import OpenGrokPager

private final class MermaidRenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

@Suite("Pager Mermaid rendering", .serialized)
struct PagerMermaidRenderingTests {
    @Test("streaming fence renders only after close with one affordance row")
    func streamingFenceClosesBeforeRender() {
        let worker = PagerMermaidWorker()
        var renderer = PagerMarkdownRenderer(
            mermaidWorker: worker
        ).makeStreamingRenderer(maxTableWidth: 72)

        let open = renderer.pushAndRender("""
        Before

        ```mermaid
        flowchart TD
          A --> B

        """)
        let openText = open.map(\.text).joined(separator: "\n")
        #expect(openText.contains("flowchart TD"))
        #expect(!openText.contains("◇ mermaid"))

        let closed = renderer.pushAndRender("""
        ```

        After
        """)
        let closedText = closed.map(\.text).joined(separator: "\n")
        #expect(closedText.contains("┌"))
        #expect(closedText.contains("A"))
        #expect(closedText.contains("B"))
        #expect(closed.filter { $0.text.contains("◇ mermaid") }.count == 1)
        #expect(closedText.contains("[Open Image]"))
        #expect(closedText.contains("[Copy Source]"))
        #expect(!closedText.contains("flowchart TD"))
    }

    @Test("concurrent identical requests render once and reuse the cache")
    func coalescesConcurrentRequests() async {
        let counter = MermaidRenderCounter()
        let worker = PagerMermaidWorker { source, width in
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return PagerMermaidRender(lines: ["\(width):\(source)"])
        }

        let results = await withTaskGroup(of: PagerMermaidRender?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    worker.render(source: "flowchart TD\nA --> B", width: 80)
                }
            }
            var values: [PagerMermaidRender?] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(counter.read() == 1)
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0?.lines == ["80:flowchart TD\nA --> B"] })
        #expect(worker.render(source: "flowchart TD\nA --> B", width: 80) != nil)
        #expect(counter.read() == 1)
    }
}
