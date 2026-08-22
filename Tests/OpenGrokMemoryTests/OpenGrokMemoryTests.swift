import Foundation
import Testing
@testable import OpenGrokMemory
import OpenGrokConfigTypes

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-memory-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTemporaryDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

@Suite("OpenGrokMemory chunking")
struct OpenGrokMemoryChunkingTests {
    @Test("chunk hashes and markdown boundaries are deterministic")
    func deterministicChunking() {
        let content = "## Parent\n\n### Child\n\nThis paragraph contains enough words to force a split when the chunk limit is small.\n\nSecond paragraph continues the same topic."
        let config = MemoryIndexConfig(maxChunkChars: 58, chunkOverlapChars: 8)
        let first = chunkMarkdown(content, config: config)
        let second = chunkMarkdown(content, config: config)

        #expect(first == second)
        #expect(first.count >= 2)
        #expect(first.contains { $0.text.contains("[Context: ## Parent]") })
        #expect(chunkHash("hello") == chunkHash("hello"))
        #expect(chunkHash("hello") != chunkHash("world"))
    }

    @Test("empty input and header syntax follow Rust behavior")
    func emptyAndHeaders() {
        #expect(chunkMarkdown("").isEmpty)
        #expect(markdownHeaderLevel("## Section") == 2)
        #expect(markdownHeaderLevel("#tag") == nil)
        #expect(markdownHeaderLevel("not a header") == nil)
        #expect(markdownHeaderLevel("###") == 3)
    }

    @Test("memory content normalization preserves authored markdown")
    func normalization() {
        #expect(normalizeMemoryContent("   ") == "")
        #expect(normalizeMemoryContent("# Existing\n\nBody") == "# Existing\n\nBody")
        #expect(normalizeMemoryContent("single note") == "## single note")
        #expect(normalizeMemoryContent("Title\n\nBody") == "## Title\n\nBody")
        #expect(normalizeMemoryContent("Title\r\n\r\nBody") == "## Title\n\nBody")
        #expect(slugify("My Project / API", maxLength: 40) == "my-project-api")
    }
}

@Suite("OpenGrokMemory storage")
struct OpenGrokMemoryStorageTests {
    @Test("OPENGROK_HOME isolates memory and never uses legacy path")
    func stateIsolationAndInitialization() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let cwd = URL(fileURLWithPath: "/workspace/opengrok-memory-tests", isDirectory: true)
        let storage = MemoryStorage(
            cwd: cwd,
            environment: [
                "OPENGROK_HOME": root.appendingPathComponent("state", isDirectory: true).path,
                "HOME": root.appendingPathComponent("home", isDirectory: true).path,
            ]
        )

        #expect(storage.globalDir.path.hasSuffix("state/memory"))
        #expect(!storage.globalDir.path.contains(".grok"))
        try storage.ensureInitialized()
        try storage.appendToMemory(scope: .global, content: "Remember the Rust API")

        let files = try storage.listMemoryFiles()
        #expect(files.contains(storage.globalMemoryFile))
        #expect(files.contains(storage.workspaceMemoryFile))
        #expect(try storage.readFile(path: storage.globalMemoryFile).contains("Remember the Rust API"))
    }

    @Test("readFile canonicalizes symlinks and rejects paths outside memory")
    func pathSafety() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let memoryRoot = root.appendingPathComponent("memory", isDirectory: true)
        let storage = MemoryStorage.newFlat(cwd: root, root: memoryRoot)
        try storage.writeLongTerm(scope: .global, content: "safe")

        let outside = root.appendingPathComponent("outside.md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        #expect(throws: MemoryError.self) {
            _ = try storage.readFile(path: outside)
        }

        let traversal = memoryRoot.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("outside.md")
        #expect(throws: MemoryError.self) {
            _ = try storage.readFile(path: traversal)
        }
    }

    @Test("CRLF memory reads count each physical line exactly once")
    func crlfMemoryLineWindows() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(
            cwd: root,
            root: root.appendingPathComponent("memory", isDirectory: true)
        )
        try storage.writeLongTerm(scope: .global, content: "one\r\ntwo\r\nthree\r\nfour\r\n")

        #expect(try storage.readFile(path: storage.globalMemoryFile, from: 1, lines: 2) == "two\nthree")
        #expect(try storage.readFile(path: storage.globalMemoryFile, from: 2) == "three\nfour")
    }

    @Test("memory append never replaces an existing invalid UTF-8 file")
    func appendRejectsInvalidUTF8WithoutDataLoss() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(
            cwd: root,
            root: root.appendingPathComponent("memory", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: storage.globalDir, withIntermediateDirectories: true)
        let original = Data([0x80, 0x81, 0x0A])
        try original.write(to: storage.globalMemoryFile)

        #expect(throws: (any Error).self) {
            try storage.appendToMemory(scope: .global, content: "must not erase existing notes")
        }
        #expect(try Data(contentsOf: storage.globalMemoryFile) == original)
    }

    @Test("daily logs reject path separators and append with separators")
    func dailyLogSafety() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))

        #expect(throws: MemoryError.self) {
            _ = try storage.writeDailyLog(date: "2026/08/04", slug: "bad", sessionID: "id", content: "x", append: false)
        }
        let path = try storage.writeDailyLog(
            date: "2026-08-04",
            slug: "session",
            sessionID: "123456789",
            content: "first",
            append: false
        )
        _ = try storage.writeDailyLog(
            date: "2026-08-04",
            slug: "session",
            sessionID: "123456789",
            content: "second",
            append: true
        )
        let output = try String(contentsOf: path, encoding: .utf8)
        #expect(output.contains("<!-- flush "))
        #expect(output.contains("first"))
        #expect(output.contains("second"))
    }
}

@Suite("OpenGrokMemory index")
struct OpenGrokMemoryIndexTests {
    @Test("reindex is hash-aware, updates chunks, deletes idempotently, and persists")
    func reindexLifecycle() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let memoryRoot = root.appendingPathComponent("memory", isDirectory: true)
        let storage = MemoryStorage.newFlat(cwd: root, root: memoryRoot)
        let indexURL = root.appendingPathComponent("index.json")
        let file = root.appendingPathComponent("note.md")
        try "# Note\n\nRust indexing behavior.".write(to: file, atomically: true, encoding: .utf8)

        let index = try MemoryIndex(indexURL: indexURL, storage: storage)
        let added = try index.reindexFile(path: file, source: "workspace")
        #expect(added == ReindexResult(added: 1, updated: 0, removed: 0))
        let unchanged = try index.reindexFile(path: file, source: "workspace")
        #expect(unchanged == ReindexResult())

        let original = try #require(try index.getChunk("\(file.path):0"))
        try "# Note\n\nUpdated Rust indexing behavior.".write(to: file, atomically: true, encoding: .utf8)
        let updated = try index.reindexFile(path: file, source: "workspace")
        #expect(updated.updated == 1)
        let current = try #require(try index.getChunk(original.id))
        #expect(current.createdAt == original.createdAt)
        #expect(current.updatedAt >= original.updatedAt)
        #expect(current.text.contains("Updated"))

        let reopened = try MemoryIndex(indexURL: indexURL, storage: storage)
        #expect(try reopened.getChunk(original.id)?.text == current.text)
        #expect(try reopened.deletePath(file) == 1)
        #expect(try reopened.deletePath(file) == 0)
        #expect(try reopened.allIndexedPaths().isEmpty)
    }

    @Test("FTS keyword extraction filters conversational stop words")
    func ftsKeywords() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let index = try MemoryIndex(indexURL: root.appendingPathComponent("index.json"), storage: storage)
        let file = root.appendingPathComponent("guide.md")
        try "# Guide\n\nRust async programming patterns.".write(to: file, atomically: true, encoding: .utf8)
        _ = try index.reindexFile(path: file, source: "workspace")

        #expect(extractKeywords("that thing we discussed about the API") == ["discussed", "api"])
        #expect(extractKeywords("what is that?").isEmpty)
        #expect(try index.searchFTS("what is rust", limit: 10).count == 1)
        #expect(try index.searchFTS("what is that", limit: 10).isEmpty)
    }

    @Test("claim coordination, deterministic serialization, and vector dimensions")
    func claimsSerializationAndVectors() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let indexURL = root.appendingPathComponent("index.json")
        let index = try MemoryIndex(indexURL: indexURL, storage: storage, embeddingDimensions: 2)
        let file = root.appendingPathComponent("vector.md")
        try "# Vector\n\nRust vector search.".write(to: file, atomically: true, encoding: .utf8)
        _ = try index.reindexFile(path: file, source: "workspace")
        let id = "\(file.path):0"

        try index.upsertEmbedding(id, embedding: [1, 0])
        #expect(try index.vectorSearch(queryEmbedding: [1, 0], k: 1).first?.0 == id)
        #expect(throws: MemoryError.self) {
            try index.upsertEmbedding(id, embedding: [1])
        }

        #expect(index.tryClaimReindex(staleThresholdSeconds: 60, now: 1000))
        #expect(!index.tryClaimReindex(staleThresholdSeconds: 60, now: 1000))
        index.releaseClaim()
        #expect(index.getReindexClaim().isEmpty)

        let first = try index.serializedData()
        let second = try index.serializedData()
        #expect(first == second)
        let decoded = try JSONDecoder().decode(MemoryIndexSnapshot.self, from: first)
        #expect(decoded.version == 1)
    }
}

@Suite("OpenGrokMemory ranking")
struct OpenGrokMemoryRankingTests {
    @Test("hybrid ranking is deterministic, source-weighted, and filters scaffolding")
    func deterministicRanking() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let index = try MemoryIndex(indexURL: root.appendingPathComponent("index.json"), storage: storage)

        let global = root.appendingPathComponent("global.md")
        let workspace = root.appendingPathComponent("workspace.md")
        let scaffold = root.appendingPathComponent("scaffold.md")
        try "# Global\n\nRust durable knowledge.".write(to: global, atomically: true, encoding: .utf8)
        try "# Workspace\n\nRust durable knowledge.".write(to: workspace, atomically: true, encoding: .utf8)
        try "# Global\n\n<!-- template only -->".write(to: scaffold, atomically: true, encoding: .utf8)
        _ = try index.reindexFile(path: global, source: "global")
        _ = try index.reindexFile(path: workspace, source: "workspace")
        _ = try index.reindexFile(path: scaffold, source: "global")

        var config = MemorySearchConfig()
        config.maxResults = 10
        config.minScore = 0
        config.temporalDecay.enabled = false
        config.sourceWeights["workspace"] = 2

        let first = try hybridSearch(index: index, query: "rust", config: config, now: 2_000_000_000)
        let second = try hybridSearch(index: index, query: "rust", config: config, now: 2_000_000_000)
        #expect(first == second)
        #expect(first.count == 2)
        #expect(first.first?.source == "workspace")
        #expect(first.allSatisfy { !$0.snippet.contains("template only") })
        #expect(first.allSatisfy { $0.score >= 0 && $0.score <= 1 })
    }

    @Test("a scaffold line does not suppress real content sharing its chunk")
    func scaffoldDoesNotSuppressRealContent() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let index = try MemoryIndex(indexURL: root.appendingPathComponent("index.json"), storage: storage)

        // This is the exact shape `/remember` produces: `ensureInitialized()`
        // writes the scaffold into MEMORY.md, then `appendToMemory` appends the
        // user's note to the same file. At the default 1600-character chunk
        // size both land in one chunk.
        let memory = root.appendingPathComponent("MEMORY.md")
        try """
        # Project Memory — /repo

        > Auto-populated by dream consolidation. Edit freely.

        This project pins the Rust reference at 9ed09e2a.
        """.write(to: memory, atomically: true, encoding: .utf8)
        _ = try index.reindexFile(path: memory, source: "workspace")

        var config = MemorySearchConfig()
        config.maxResults = 10
        config.minScore = 0
        config.temporalDecay.enabled = false

        // Previously the scaffold marker was matched against the whole chunk,
        // so the user's own saved memory was classified content-free and
        // dropped — `/remember` reported success and the note was unfindable.
        let results = try hybridSearch(index: index, query: "Rust reference", config: config)
        #expect(results.count == 1)
        #expect(results.first?.snippet.contains("9ed09e2a") == true)
    }

    @Test("a chunk holding only scaffold is still dropped")
    func scaffoldOnlyChunkIsDropped() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let index = try MemoryIndex(indexURL: root.appendingPathComponent("index.json"), storage: storage)

        // The other half of the rule: an untouched scaffold carries no
        // knowledge and must not surface as a hit.
        let memory = root.appendingPathComponent("MEMORY.md")
        try """
        # Project Memory — /repo

        > Auto-populated by dream consolidation. Edit freely.
        """.write(to: memory, atomically: true, encoding: .utf8)
        _ = try index.reindexFile(path: memory, source: "workspace")

        var config = MemorySearchConfig()
        config.maxResults = 10
        config.minScore = 0
        config.temporalDecay.enabled = false

        #expect(try hybridSearch(index: index, query: "project memory", config: config).isEmpty)
    }

    @Test("MMR promotes diverse snippets without changing result count")
    func mmrDiversity() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let index = try MemoryIndex(
            indexURL: root.appendingPathComponent("index.json"),
            storage: storage,
            config: MemoryIndexConfig(maxChunkChars: 80, chunkOverlapChars: 0)
        )
        let values = [
            "# One\n\nRust async programming patterns.",
            "# Two\n\nRust async programming tutorial.",
            "# Three\n\nPython web framework deployment."
        ]
        for (offset, value) in values.enumerated() {
            let file = root.appendingPathComponent("\(offset).md")
            try value.write(to: file, atomically: true, encoding: .utf8)
            _ = try index.reindexFile(path: file, source: "workspace")
        }

        var config = MemorySearchConfig()
        config.maxResults = 3
        config.minScore = 0
        config.temporalDecay.enabled = false
        config.mmr = MmrConfig(enabled: true, lambda: 0.5)
        let results = try hybridSearch(index: index, query: "rust programming", config: config, now: 2_000_000_000)
        #expect(results.count == 2)
        #expect(results.first?.snippet.contains("Rust") == true)
    }
}
