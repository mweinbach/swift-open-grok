import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokToolRuntime

@Suite("Recursive list_dir breadth-first budgeting and workspace boundary parity")
struct RecursiveListDirParityTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-recursive-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func resources(at directory: URL) -> ToolResources {
        FileToolSession.makeResources(
            workspaceRoot: directory.path,
            sessionId: "recursive-list-parity",
            policy: .allowAll
        )
    }

    private func write(_ text: String = "", to relativePath: String, in directory: URL) throws {
        let path = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: path)
    }

    private func directory(_ relativePath: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath),
            withIntermediateDirectories: true
        )
    }

    private func liveListing(
        at root: URL,
        target: String = "."
    ) async throws -> [String: JSONValue] {
        let tools = try FileToolPack.finalizeBuildPack(resources: resources(at: root))
        let output = try await tools.prepareAndCall(
            clientName: "list_dir",
            args: .object(["target_directory": .string(target)])
        ).get()
        guard case .object(let fields) = output.value else {
            throw ToolError.invalidArguments("list_dir returned an unexpected output shape")
        }
        return fields
    }

    private func budgetedListing(
        at root: URL,
        maxChars: Int,
        target: String = "."
    ) async throws -> [String: JSONValue] {
        let output = try await ListDirTool.run(
            args: .object(["target_directory": .string(target)]),
            resources: resources(at: root),
            maxChars: maxChars
        ).get()
        guard case .object(let fields) = output.value else {
            throw ToolError.invalidArguments("list_dir returned an unexpected output shape")
        }
        return fields
    }

    private func content(_ listing: [String: JSONValue]) throws -> String {
        guard case .string(let output)? = listing["content"] else {
            throw ToolError.invalidArguments("list_dir did not return visible content")
        }
        return output
    }

    private func body(_ listing: [String: JSONValue]) throws -> String {
        let output = try content(listing)
        guard let newline = output.firstIndex(where: \.isNewline) else {
            throw ToolError.invalidArguments("list_dir omitted its root header")
        }
        return String(output[output.index(after: newline)...])
    }

    @Test("live list_dir recursively renders the pinned Rust tree and counts visible entries")
    func liveListingRecursivelyRendersNestedDirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("root", to: "README.md", in: root)
        try write("swift", to: "Sources/Nested/Main.swift", in: root)
        try write("test", to: "Tests/Spec.swift", in: root)

        let listing = try await liveListing(at: root)
        let visible = try content(listing)

        #expect(visible.hasPrefix("- \(root.path)/\n"))
        #expect(visible.contains("  - README.md\n"))
        #expect(visible.contains("  - Sources/\n"))
        #expect(visible.contains("    - Nested/\n"))
        #expect(visible.contains("      - Main.swift\n"))
        #expect(visible.contains("  - Tests/\n"))
        #expect(visible.contains("    - Spec.swift"))
        #expect(listing["entry_count"] == .number(.int64(6)))
        #expect(listing["truncated"] == .bool(false))
        #expect(listing["path"] == .string(root.path))
        #expect(listing["type"] == .string("list_dir"))
    }

    @Test("mixed files and directories use deterministic case-insensitive ordering")
    func entriesSortCaseInsensitivelyAtEveryDepth() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(to: "zeta.txt", in: root)
        try write(to: "Alpha.txt", in: root)
        try write(to: "apple.txt", in: root)
        try write(to: "beta/z-last.swift", in: root)
        try write(to: "beta/A-first.swift", in: root)

        let visible = try content(await liveListing(at: root))
        let alpha = try #require(visible.range(of: "  - Alpha.txt"))
        let apple = try #require(visible.range(of: "  - apple.txt"))
        let beta = try #require(visible.range(of: "  - beta/"))
        let zeta = try #require(visible.range(of: "  - zeta.txt"))
        let nestedFirst = try #require(visible.range(of: "    - A-first.swift"))
        let nestedLast = try #require(visible.range(of: "    - z-last.swift"))

        #expect(alpha.lowerBound < apple.lowerBound)
        #expect(apple.lowerBound < beta.lowerBound)
        #expect(beta.lowerBound < zeta.lowerBound)
        #expect(nestedFirst.lowerBound < nestedLast.lowerBound)
    }

    @Test("an oversized early sibling remains summarized while a later small sibling expands")
    func fatSiblingCannotStarveLaterSmallDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<50 {
            try write(to: "aaa_big/file_\(index).rs", in: root)
        }
        try write(to: "zzz_small/marker.py", in: root)

        let listing = try await budgetedListing(at: root, maxChars: 180)
        let visible = try content(listing)

        #expect(visible.contains("  - aaa_big/"))
        #expect(visible.contains("[50 files in subtree: 50 *.rs]"))
        #expect(!visible.contains("file_0.rs"))
        #expect(visible.contains("  - zzz_small/"))
        #expect(visible.contains("    - marker.py"))
        #expect(!(try body(listing)).contains("too large to list fully"))
        #expect((try body(listing)).utf8.count <= 180)
        #expect(listing["truncated"] == .bool(true))
    }

    @Test("breadth-first expansion skips multiple fat siblings and preserves interleaved small ones")
    func multipleFatSiblingsDoNotStarveInterleavedDirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<40 {
            try write(to: "aaa_big/file_\(index).rs", in: root)
            try write(to: "ccc_big/file_\(index).jpg", in: root)
        }
        try write(to: "bbb_small/first.swift", in: root)
        try write(to: "ddd_small/second.py", in: root)

        let listing = try await budgetedListing(at: root, maxChars: 300)
        let visible = try content(listing)

        #expect(visible.contains("first.swift"))
        #expect(visible.contains("second.py"))
        #expect(!visible.contains("file_0.rs"))
        #expect(!visible.contains("file_0.jpg"))
        #expect(visible.components(separatedBy: "[40 files in subtree:").count == 3)
        #expect((try body(listing)).utf8.count <= 300)
    }

    @Test("collapsed directories report three deterministic extension buckets and omitted types")
    func extensionSummariesAreAccurateAndBounded() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<4 {
            try write(to: "large/rust_\(index).RS", in: root)
        }
        for index in 0..<3 {
            try write(to: "large/text_\(index).txt", in: root)
        }
        try write(to: "large/README", in: root)
        try write(to: "large/LICENSE", in: root)
        try write(to: "large/one.swift", in: root)
        try write(to: "large/one.js", in: root)

        let listing = try await budgetedListing(at: root, maxChars: 100)
        let visible = try content(listing)

        #expect(visible.contains("  - large/"))
        #expect(visible.contains("[11 files in subtree: 4 *.rs, 3 *.txt, 2 *no-ext, ...]"))
        #expect(!visible.contains("rust_0.RS"))
        #expect(!visible.contains("one.swift"))
        #expect(listing["entry_count"] == .number(.int64(1)))
    }

    @Test("root budget exhaustion appends the exact pinned Rust truncation notice")
    func rootBudgetUsesExactUpstreamNotice() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 {
            try write(to: "file_\(index)_long_name.swift", in: root)
        }

        let listing = try await budgetedListing(at: root, maxChars: 40)
        let visible = try content(listing)
        let exactNotice = "    ...\n\nNote: this directory is too large to list fully. "
            + "Try list_dir on a narrower path, or use grep / bash."

        #expect(visible.hasSuffix(exactNotice))
        #expect(visible.components(separatedBy: "too large to list fully").count == 2)
        #expect(listing["truncated"] == .bool(true))
        guard case .number(let count)? = listing["entry_count"] else {
            Issue.record("truncated directory omitted its visible entry count")
            return
        }
        #expect((count.int64Value ?? 0) < 20)
    }

    @Test("a zero output budget still surfaces the exact root truncation notice")
    func zeroBudgetReportsTruncation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(to: "visible.txt", in: root)

        let listing = try await budgetedListing(at: root, maxChars: 0)

        #expect(listing["entry_count"] == .number(.int64(0)))
        #expect(listing["truncated"] == .bool(true))
        #expect(try content(listing).contains("too large to list fully"))
        #expect(!(try content(listing)).contains("visible.txt"))
    }

    @Test("depth-one siblings survive a deep-walk item limit and retain the exact cutoff notice")
    func seededSiblingsSurviveDeepWalkCap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<15 {
            try write(to: "aaa_early/file_\(index).rs", in: root)
        }
        try write(to: "zzz_late/marker.swift", in: root)
        try write(to: "README.md", in: root)

        let rendered = try ListDirTool.renderDirectory(
            at: root.path,
            allowedRoots: [root.path],
            maxChars: 10_000,
            maximumItems: 5
        )

        #expect(rendered.body.contains("- aaa_early/"))
        #expect(rendered.body.contains("- zzz_late/"))
        #expect(rendered.body.contains("README.md"))
        #expect(!rendered.body.contains("marker.swift"))
        #expect(rendered.body.contains(
            "Note: there are more than 100000 items in the directory, so not all files may be shown."
        ))
        #expect(rendered.truncated)
    }

    @Test("the seed cap independently preserves the upstream deep-item cutoff copy")
    func rootSeedCapReportsExactCutoffNotice() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<8 {
            try write(to: "file_\(index).txt", in: root)
        }

        let rendered = try ListDirTool.renderDirectory(
            at: root.path,
            allowedRoots: [root.path],
            maxChars: 10_000,
            maximumSeeds: 3
        )

        #expect(rendered.entryCount == 3)
        #expect(rendered.truncated)
        #expect(rendered.body.contains("more than 100000 items in the directory"))
        #expect(rendered.body.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("so not all files may be shown."))
    }

    @Test("depth limits stop adversarial nesting without inventing an item-cap notice")
    func depthLimitStopsRecursiveNesting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("secret", to: "one/two/three/four/hidden.swift", in: root)

        let rendered = try ListDirTool.renderDirectory(
            at: root.path,
            allowedRoots: [root.path],
            maxChars: 10_000,
            maximumDepth: 3
        )

        #expect(rendered.body.contains("- one/"))
        #expect(rendered.body.contains("- two/"))
        #expect(rendered.body.contains("- three/"))
        #expect(!rendered.body.contains("four"))
        #expect(!rendered.body.contains("hidden.swift"))
        #expect(!rendered.body.contains("more than 100000 items"))
        #expect(rendered.truncated)
    }

    @Test("root and nested ignore files hide ignored paths while preserving explicit negations")
    func scopedGitignoreRulesAreAppliedRecursively() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("generated/\r\n*.log\r\n!kept.log\r\n", to: ".gitignore", in: root)
        try write("secret.txt\ngenerated/\n", to: "nested/.ignore", in: root)
        try write(to: "generated/never.swift", in: root)
        try write(to: "discarded.log", in: root)
        try write(to: "kept.log", in: root)
        try write(to: "nested/secret.txt", in: root)
        try write(to: "nested/generated/also-hidden.rs", in: root)
        try write(to: "nested/visible.swift", in: root)

        let visible = try content(await liveListing(at: root))

        #expect(visible.contains("kept.log"))
        #expect(visible.contains("nested/"))
        #expect(visible.contains("visible.swift"))
        #expect(!visible.contains("discarded.log"))
        #expect(!visible.contains("secret.txt"))
        #expect(!visible.contains("generated/"))
        #expect(!visible.contains("never.swift"))
        #expect(!visible.contains("also-hidden.rs"))
        #expect(!visible.contains(".gitignore"))
        #expect(!visible.contains(".ignore"))
    }

    @Test("dotfiles and dot-directories are excluded at every depth")
    func hiddenFilesAndDirectoriesNeverAppear() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(to: ".hidden.txt", in: root)
        try write(to: ".hidden-directory/secret.swift", in: root)
        try write(to: "visible/.nested-secret.txt", in: root)
        try write(to: "visible/.nested-directory/deep.swift", in: root)
        try write(to: "visible/public.swift", in: root)

        let listing = try await liveListing(at: root)
        let visible = try content(listing)

        #expect(visible.contains("visible/"))
        #expect(visible.contains("public.swift"))
        #expect(!visible.contains("hidden"))
        #expect(!visible.contains("nested-secret"))
        #expect(!visible.contains("deep.swift"))
        #expect(listing["entry_count"] == .number(.int64(2)))
    }

    @Test("recursive traversal skips inbound and outbound symbolic links")
    func recursiveTraversalNeverFollowsSymbolicLinks() async throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(to: "inside/allowed.swift", in: root)
        try write("TOP_SECRET", to: "classified.txt", in: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-directory"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-file.txt"),
            withDestinationURL: outside.appendingPathComponent("classified.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("inside-alias"),
            withDestinationURL: root.appendingPathComponent("inside")
        )

        let listing = try await liveListing(at: root)
        let visible = try content(listing)

        #expect(visible.contains("inside/"))
        #expect(visible.contains("allowed.swift"))
        #expect(!visible.contains("outside-directory"))
        #expect(!visible.contains("outside-file"))
        #expect(!visible.contains("inside-alias"))
        #expect(!visible.contains("classified"))
        #expect(!visible.contains("TOP_SECRET"))
        #expect(listing["entry_count"] == .number(.int64(2)))
    }

    @Test("outside workspace roots and symbolic-link directory roots fail closed")
    func externalAndSymbolicRootsAreRejected() async throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try directory("inside", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("inside-alias"),
            withDestinationURL: root.appendingPathComponent("inside")
        )

        let outsideResult = await ListDirTool.run(
            args: .object(["target_directory": .string(outside.path)]),
            resources: resources(at: root)
        )
        guard case .failure(let outsideError) = outsideResult else {
            Issue.record("list_dir traversed a directory outside its authorized roots")
            return
        }
        #expect(outsideError.kind == .invalidArguments)
        #expect(outsideError.detail.contains("escapes workspace"))

        let symlinkResult = await ListDirTool.run(
            args: .object(["target_directory": .string("inside-alias")]),
            resources: resources(at: root)
        )
        guard case .failure(let symlinkError) = symlinkResult else {
            Issue.record("list_dir followed an explicitly supplied symbolic-link directory")
            return
        }
        #expect(symlinkError.kind == .invalidArguments)
        #expect(symlinkError.detail.contains("Symbolic link"))
    }

    @Test("empty directories preserve the Rust root header and stable structured fields")
    func emptyDirectoryPreservesRootHeader() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = try await liveListing(at: root)

        #expect(try content(listing) == "- \(root.path)/\n")
        #expect(listing["entry_count"] == .number(.int64(0)))
        #expect(listing["truncated"] == .bool(false))
        #expect(listing["path"] == .string(root.path))
    }

    @Test("UTF-8 filenames obey the upstream byte-based directory-body budget")
    func unicodeNamesUseUTF8Budget() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            try write(to: "emoji🙂🙂🙂-\(index).swift", in: root)
        }

        let listing = try await budgetedListing(at: root, maxChars: 40)
        let visibleBody = try body(listing)
        let shownLines = visibleBody.split(whereSeparator: \.isNewline)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }

        #expect(shownLines.count == 1)
        #expect(listing["entry_count"] == .number(.int64(1)))
        #expect(listing["truncated"] == .bool(true))
        #expect(visibleBody.contains("too large to list fully"))
    }

    @Test("invalid directory budgets are rejected without traversing files")
    func negativeBudgetsAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(to: "visible.swift", in: root)

        let result = await ListDirTool.run(
            args: .object(["target_directory": .string(".")]),
            resources: resources(at: root),
            maxChars: -1
        )

        guard case .failure(let error) = result else {
            Issue.record("negative output budget should have failed")
            return
        }
        #expect(error.kind == .invalidArguments)
        #expect(error.detail.contains("limits must not be negative"))
    }
}
