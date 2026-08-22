import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

@Suite("Live prompt file references")
struct LivePromptFileReferenceParityTests {
    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "opengrok-prompt-files-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        func directory(_ path: String) throws {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }

        func file(_ path: String, content: String = "content") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("bare @ browses only alphabetically sorted top-level entries")
    func bareAtBrowsesTopLevelOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("zeta.md")
        try fixture.file("alpha.swift")
        try fixture.file("Sources/Nested.swift")
        try fixture.file(".hidden")
        try fixture.file(".git/config")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        let rows = references.suggestions(query: "", isDirectoryMode: false, hidden: false)

        #expect(rows.map(\.insertText) == ["Sources", "alpha.swift", "zeta.md"])
        #expect(rows.first?.summary == "dir")
        #expect(rows.allSatisfy { !$0.insertText.contains("/") })
        #expect(references.indexBuildCount == 1)
    }

    @Test("normal search honors nested CRLF gitignore, ignore, and git excludes")
    func normalSearchHonorsEveryIgnoreLayer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file(".gitignore", content: "ignored.txt\r\nbuild/\r\n*.log\r\n!keep.log\r\n")
        try fixture.file(".git/info/exclude", content: "local.tmp\r\n")
        try fixture.file(".ignore", content: "root-private.txt\r\n")
        try fixture.file("Sources/.gitignore", content: "Generated.swift\r\n")
        try fixture.file("Sources/.ignore", content: "Private.swift\r\n")
        try fixture.file("ignored.txt")
        try fixture.file("build/artifact.swift")
        try fixture.file("drop.log")
        try fixture.file("keep.log")
        try fixture.file("local.tmp")
        try fixture.file("root-private.txt")
        try fixture.file("Sources/Generated.swift")
        try fixture.file("Sources/Private.swift")
        try fixture.file("Sources/Visible.swift")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        let hiddenPaths = references.suggestions(
            query: "",
            isDirectoryMode: false,
            hidden: false
        ).map(\.insertText)

        #expect(hiddenPaths.contains("keep.log"))
        #expect(!hiddenPaths.contains("drop.log"))
        #expect(!hiddenPaths.contains("ignored.txt"))
        #expect(!hiddenPaths.contains("local.tmp"))
        #expect(!hiddenPaths.contains("root-private.txt"))
        #expect(!hiddenPaths.contains("build"))
        #expect(references.suggestions(query: "Generated", isDirectoryMode: false, hidden: false).isEmpty)
        #expect(references.suggestions(query: "Private", isDirectoryMode: false, hidden: false).isEmpty)
        #expect(references.suggestions(query: "Visible", isDirectoryMode: false, hidden: false)
            .map(\.insertText) == ["Sources/Visible.swift"])
    }

    @Test("hidden mode includes dotfiles and ignored files while .git stays excluded")
    func hiddenModeRestoresIgnoredFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file(".gitignore", content: "ignored.swift\n")
        try fixture.file("ignored.swift")
        try fixture.file(".private/Hidden.swift")
        try fixture.file(".git/objects/secret.swift")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        #expect(references.suggestions(query: "ignored", isDirectoryMode: false, hidden: false)
            .isEmpty)
        #expect(references.suggestions(query: "ignored", isDirectoryMode: false, hidden: true)
            .map(\.insertText) == ["ignored.swift"])
        #expect(references.suggestions(query: "Hidden", isDirectoryMode: false, hidden: true)
            .map(\.insertText) == [".private/Hidden.swift"])
        #expect(references.suggestions(query: "secret", isDirectoryMode: false, hidden: true)
            .isEmpty)
        #expect(references.indexBuildCount == 2)
    }

    @Test("trailing slash retains files underneath the scoped directory")
    func directoryQueryDoesNotHideFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("Sources/Visible.swift")
        try fixture.file("Sources/Nested/Child.swift")
        try fixture.file("Other.swift")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        let rows = references.suggestions(
            query: "Sources/",
            isDirectoryMode: true,
            hidden: false
        )

        #expect(rows.contains { $0.insertText == "Sources/Visible.swift" })
        #expect(rows.contains { $0.insertText == "Sources/Nested/Child.swift" })
        #expect(rows.contains { $0.insertText == "Sources/Nested" && $0.summary == "dir" })
        #expect(!rows.contains { $0.insertText == "Other.swift" })
    }

    @Test("smart-case matching and Rust score, length, then path ranking")
    func smartCaseAndRanking() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("Visible.swift")
        try fixture.file("Sources/Visible.swift")
        try fixture.file("visible-lower.swift")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        let insensitive = references.suggestions(
            query: "visible",
            isDirectoryMode: false,
            hidden: false
        )
        #expect(insensitive.contains { $0.insertText == "Visible.swift" })
        #expect(insensitive.contains { $0.insertText == "visible-lower.swift" })

        let sensitive = references.suggestions(
            query: "Visible",
            isDirectoryMode: false,
            hidden: false
        )
        #expect(sensitive.first?.insertText == "Visible.swift")
        #expect(sensitive.contains { $0.insertText == "Sources/Visible.swift" })
        #expect(!sensitive.contains { $0.insertText == "visible-lower.swift" })
    }

    @Test("line references preserve validated line and range suffixes")
    func lineReferenceSuffixes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("Sources/Visible.swift")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        #expect(references.suggestions(
            query: "Visible.swift:12",
            isDirectoryMode: false,
            hidden: false
        ).map(\.insertText) == ["Sources/Visible.swift:12"])
        #expect(references.suggestions(
            query: "Visible.swift:12-18",
            isDirectoryMode: false,
            hidden: false
        ).map(\.insertText) == ["Sources/Visible.swift:12-18"])

        for invalid in ["Visible.swift:0", "Visible.swift:8-2", "Visible.swift:",
                        "Visible.swift:-2", "Visible.swift:99999999999999999999999"] {
            #expect(references.suggestions(
                query: invalid,
                isDirectoryMode: false,
                hidden: false
            ).isEmpty)
        }
    }

    @Test("recursive indexes are reused per visibility mode and explicitly invalidated")
    func indexesAreSessionScopedAndCached() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("Sources/Visible.swift")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        #expect(references.suggestions(query: "Visible", isDirectoryMode: false, hidden: false)
            .count == 1)
        #expect(references.suggestions(query: "Vis", isDirectoryMode: false, hidden: false)
            .count == 1)
        #expect(references.indexBuildCount == 1)

        try fixture.file("Sources/Added.swift")
        #expect(references.suggestions(query: "Added", isDirectoryMode: false, hidden: false)
            .isEmpty)
        references.invalidate()
        #expect(references.suggestions(query: "Added", isDirectoryMode: false, hidden: false)
            .map(\.insertText) == ["Sources/Added.swift"])
        #expect(references.indexBuildCount == 2)

        #expect(references.suggestions(query: "Added", isDirectoryMode: false, hidden: true)
            .map(\.insertText) == ["Sources/Added.swift"])
        #expect(references.indexBuildCount == 3)
    }

    @Test("index size, output size, and pathological queries remain bounded")
    func searchWorkIsBounded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0..<40 {
            try fixture.file("file-\(index).swift")
        }

        let references = LivePromptFileReferences(
            workingDirectory: fixture.root,
            maximumIndexedEntries: 5,
            maximumResults: 3
        )
        let oversized = String(repeating: "a", count: 4_097)
        #expect(references.suggestions(query: oversized, isDirectoryMode: false, hidden: false)
            .isEmpty)
        #expect(references.indexBuildCount == 0)

        let rows = references.suggestions(query: "file", isDirectoryMode: false, hidden: false)
        #expect(rows.count == 3)
        #expect(references.indexBuildCount == 1)
    }

    @Test("viewer resolution rejects absolute, traversal, drives, and nonexistent paths")
    func viewerResolutionRejectsUntrustedPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("Sources/Visible.swift")

        let expected = fixture.root.appendingPathComponent("Sources/Visible.swift")
            .standardizedFileURL.resolvingSymlinksInPath()
        #expect(LivePromptFileReferences.validatedFileURL(
            for: "Sources/Visible.swift",
            workingDirectory: fixture.root
        ) == expected)
        #expect(LivePromptFileReferences.validatedFileURL(
            for: "./Sources/Visible.swift",
            workingDirectory: fixture.root
        ) == expected)

        for invalid in ["", "../outside.swift", "Sources/../../outside.swift",
                        "/etc/passwd", "C:\\Windows\\win.ini", "C:/Windows/win.ini",
                        "Sources\\Visible.swift", "Sources/missing.swift"] {
            #expect(LivePromptFileReferences.validatedFileURL(
                for: invalid,
                workingDirectory: fixture.root
            ) == nil)
            #expect(referencesReject(query: invalid, root: fixture.root))
        }
    }

    #if !os(Windows)
    @Test("symlink files, escaped directories, and cyclic links are never indexed")
    func symlinkEscapesAndCyclesStayOutsideTheIndex() throws {
        let fixture = try Fixture()
        let outside = try Fixture()
        defer {
            fixture.remove()
            outside.remove()
        }
        try outside.file("secret.swift")
        try fixture.file("Sources/Visible.swift")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("linked-file.swift"),
            withDestinationURL: outside.root.appendingPathComponent("secret.swift")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("linked-directory"),
            withDestinationURL: outside.root
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("Sources/cycle"),
            withDestinationURL: fixture.root
        )

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        for query in ["secret", "linked", "cycle"] {
            #expect(references.suggestions(query: query, isDirectoryMode: false, hidden: true)
                .isEmpty)
        }
        #expect(references.suggestions(query: "Visible", isDirectoryMode: false, hidden: false)
            .map(\.insertText) == ["Sources/Visible.swift"])
        #expect(LivePromptFileReferences.validatedFileURL(
            for: "linked-file.swift",
            workingDirectory: fixture.root
        ) == nil)
        #expect(LivePromptFileReferences.validatedFileURL(
            for: "linked-directory/secret.swift",
            workingDirectory: fixture.root
        ) == nil)
    }
    #endif

    @Test("real pager composer accepts an actual workspace file completion")
    func liveComposerAcceptsWorkspaceFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("Sources/Visible.swift")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        let renderer = FileReferenceRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                continuation.yield(.paste("inspect @Vis"))
                continuation.yield(.key(KeyEvent(key: .tab)))
                continuation.finish()
            },
            runtime: FileReferenceUnusedRuntime(),
            renderer: renderer,
            output: FileReferenceSilentOutput()
        )
        await controller.setFileSearchSuggestions { query, isDirectoryMode, hidden in
            references.suggestions(
                query: query,
                isDirectoryMode: isDirectoryMode,
                hidden: hidden
            )
        }

        let result = try await controller.run(.init(prompt: "", mode: .inline))
        #expect(result.lifecycle == .eof)
        let states = await renderer.states
        #expect(states.contains {
            $0.completions.contains { $0.insertText == "Sources/Visible.swift" }
        })
        #expect(states.last?.text == "inspect @Sources/Visible.swift ")
    }

    @Test("real pager hidden-mode completion reaches an ignored workspace file")
    func liveComposerAcceptsIgnoredFileInHiddenMode() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file(".gitignore", content: "ignored.swift\n")
        try fixture.file("ignored.swift")

        let references = LivePromptFileReferences(workingDirectory: fixture.root)
        let renderer = FileReferenceRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                continuation.yield(.paste("inspect @!ignored"))
                continuation.yield(.key(KeyEvent(key: .tab)))
                continuation.finish()
            },
            runtime: FileReferenceUnusedRuntime(),
            renderer: renderer,
            output: FileReferenceSilentOutput()
        )
        await controller.setFileSearchSuggestions { query, isDirectoryMode, hidden in
            references.suggestions(
                query: query,
                isDirectoryMode: isDirectoryMode,
                hidden: hidden
            )
        }

        let result = try await controller.run(.init(prompt: "", mode: .inline))
        #expect(result.lifecycle == .eof)
        let states = await renderer.states
        #expect(states.contains {
            $0.completions.contains { $0.insertText == "ignored.swift" }
        })
        #expect(states.last?.text == "inspect @ignored.swift ")
    }

    private func referencesReject(query: String, root: URL) -> Bool {
        if query.isEmpty || query == "Sources/missing.swift" { return true }
        let references = LivePromptFileReferences(workingDirectory: root)
        return references.suggestions(query: query, isDirectoryMode: false, hidden: false)
            .isEmpty
    }
}

private actor FileReferenceRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private(set) var states: [OpenGrokPagerInteractivePromptState] = []

    func begin() async throws {}

    func render(_ event: OpenGrokPagerInteractiveEvent) async throws {
        if case .promptChanged(let state) = event {
            states.append(state)
        }
    }

    func restoreTerminal() async throws {}
}

private struct FileReferenceUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        throw FileReferenceRuntimeError.unexpectedSession(request.prompt)
    }
}

private enum FileReferenceRuntimeError: Error {
    case unexpectedSession(String)
}

private struct FileReferenceSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {}
}
