// LiveArgumentSuggestionTests.swift
//
// `/export` path completion — the port of `list_path_completions`
// (upstream export.rs:83-160).

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("Export path completion")
struct LiveExportPathSuggestionTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-export-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("notes.md").path,
            contents: Data()
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".hidden").path,
            contents: Data()
        )
        FileManager.default.createFile(
            atPath: docs.appendingPathComponent("guide.md").path,
            contents: Data()
        )
        return root
    }

    @Test("directories lead, hidden entries are skipped, and rows commit the whole command")
    func listsDirectoryFirst() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = LiveExportPathSuggestions.suggestions(query: "d", workingDirectory: root)
        // Prefix `d` matches only the directory; its insert text keeps the
        // dropdown open for drill-down via the trailing slash.
        #expect(rows.map(\.name) == ["docs/"])
        #expect(rows.first?.insertText == "/export docs/")

        let all = LiveExportPathSuggestions.suggestions(query: "docs/", workingDirectory: root)
        #expect(all.map(\.name) == ["guide.md"])
        #expect(all.first?.insertText == "/export docs/guide.md")

        // Hidden entries never appear (export.rs:126-128).
        let n = LiveExportPathSuggestions.suggestions(query: "n", workingDirectory: root)
        #expect(n.map(\.name) == ["notes.md"])

        // An empty query offers nothing: bare `/export` is the clipboard path.
        #expect(LiveExportPathSuggestions.suggestions(query: "", workingDirectory: root).isEmpty)
    }
}
