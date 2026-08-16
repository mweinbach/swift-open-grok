import Foundation
import OpenGrokPagerRender
@testable import OpenGrokCLI
import Testing

@Suite("Wave B edit highlight worker")
struct WaveBEditHighlightWorkerTests {
    @Test("worker reads within caps validates hunks and highlights Swift")
    func highlightsValidatedSwiftFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-b-highlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Example.swift")
        try "let value = \"hello\"\n".write(to: path, atomically: true, encoding: .utf8)
        let file = PagerEditFile(
            path: path.path,
            hunks: diffHunksFromStrings(
                oldText: "let value = \"old\"\n",
                newText: "let value = \"hello\"\n",
                startLine: 1
            )
        )

        let result = await LiveEditHighlightWorker().highlight(
            callID: "entry",
            files: [file],
            workingDirectory: directory
        )
        let spans = result?.first?.highlights.first?.spans ?? []
        #expect(spans.contains { $0.kind == .keyword })
        #expect(spans.contains { $0.kind == .string })
    }

    @Test("worker falls back to hunk-only on disk mismatch")
    func mismatchedDiskTextReturnsNoUpgrade() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-b-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Example.swift")
        try "let value = 99\n".write(to: path, atomically: true, encoding: .utf8)
        let file = PagerEditFile(
            path: path.path,
            hunks: diffHunksFromStrings(oldText: "let value = 1\n", newText: "let value = 2\n", startLine: 1)
        )

        let result = await LiveEditHighlightWorker().highlight(
            callID: "entry",
            files: [file],
            workingDirectory: directory
        )
        #expect(result == nil)
    }

    @Test("latest job wins for one visible edit entry")
    func latestJobWins() async {
        let worker = LiveEditHighlightWorker(operation: { files, _ in
            if files.first?.path == "slow.swift" {
                Thread.sleep(forTimeInterval: 0.15)
            }
            var output = files
            output[0].highlights = [
                PagerEditLineHighlight(lineNumber: 1, spans: [
                    PagerEditHighlightSpan(start: 0, length: 1, kind: .keyword)
                ])
            ]
            return output
        })
        let slow = PagerEditFile(path: "slow.swift", hunks: [])
        let fast = PagerEditFile(path: "fast.swift", hunks: [])
        let directory = FileManager.default.temporaryDirectory

        async let first = worker.highlight(
            callID: "same-entry",
            files: [slow],
            workingDirectory: directory
        )
        try? await Task.sleep(for: .milliseconds(15))
        let second = await worker.highlight(
            callID: "same-entry",
            files: [fast],
            workingDirectory: directory
        )
        let stale = await first

        #expect(stale == nil)
        #expect(second?.first?.path == "fast.swift")
    }
}
