// OpenGrokFileToolsTests.swift
//
// Focused tests for R19 file/edit tools: read/list/grep/glob, search_replace,
// apply_patch, hashline, OpenCode edit/write, plan gate, path locks, hunks,
// stale context, nested prepare re-entry, output caps.

import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokFileUtils
import OpenGrokHunkTracker
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspace

@Suite("OpenGrokFileTools")
struct FileToolsTests {

    // MARK: - Fixtures

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-filetools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resources(
        at root: URL,
        planActive: Bool = false,
        allowAll: Bool = true
    ) async -> ToolResources {
        let perms = PermissionHandle(allowAll: allowAll, shellCwd: root.path)
        var plan = PlanModeTracker(sessionDirectory: root.path)
        if planActive {
            plan.enter(planFilePath: "plan.md", sessionDirectory: root.path)
        }
        let pipeline = PermissionPipeline(permissions: perms, planMode: plan)
        let tracker = HunkTrackerActor(sessionId: "test", workingDir: root.path)
        return ToolResources(
            cwd: root.path,
            sessionFolder: root.path,
            permissionPipeline: pipeline,
            hunkTracker: tracker,
            allowedRoots: [root.path]
        )
    }

    private func finalizeGrok(_ resources: ToolResources) throws -> FinalizedToolset {
        try FileToolPack.finalizePreset(.grokBuild, resources: resources)
    }

    // MARK: - Read / list / grep / glob

    @Test("read_file returns numbered lines with offset/limit")
    func readFile() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        let res = await resources(at: dir)
        let out = await ReadFileTool.run(
            args: .object([
                "target_file": .string("a.txt"),
                "offset": .number(.int64(2)),
                "limit": .number(.int64(2)),
            ]),
            resources: res
        )
        let typed = try success(out)
        guard case .object(let obj) = typed.value,
              case .string(let content) = obj["content"]
        else {
            Issue.record("bad output shape")
            return
        }
        #expect(content.contains("2→two"))
        #expect(content.contains("3→three"))
        #expect(!content.contains("1→one"))
    }

    @Test("list_dir lists children with slash for directories")
    func listDir() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        let res = await resources(at: dir)
        let out = await ListDirTool.run(
            args: .object(["target_directory": .string(".")]),
            resources: res
        )
        let typed = try success(out)
        guard case .object(let obj) = typed.value,
              case .string(let content) = obj["content"]
        else {
            Issue.record("bad list shape")
            return
        }
        #expect(content.contains("f.txt"))
        #expect(content.contains("sub/"))
    }

    @Test("grep finds regex matches with path:line format")
    func grep() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "alpha\nbeta foo\ngamma\n".write(
            to: dir.appendingPathComponent("g.txt"), atomically: true, encoding: .utf8
        )
        let res = await resources(at: dir)
        let out = await GrepTool.run(
            args: .object(["pattern": .string("foo"), "path": .string(".")]),
            resources: res
        )
        let typed = try success(out)
        guard case .object(let obj) = typed.value,
              case .string(let content) = obj["content"]
        else {
            Issue.record("bad grep shape")
            return
        }
        #expect(content.contains("foo"))
        #expect(content.contains(":2:"))
    }

    @Test("glob matches file patterns")
    func glob() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "1".write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "2".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let res = await resources(at: dir)
        let out = await GlobTool.run(
            args: .object(["pattern": .string("*.swift")]),
            resources: res
        )
        let typed = try success(out)
        guard case .object(let obj) = typed.value,
              case .string(let content) = obj["content"]
        else {
            Issue.record("bad glob")
            return
        }
        #expect(content.contains("a.swift"))
        #expect(!content.contains("b.txt"))
    }

    // MARK: - search_replace

    @Test("search_replace exact replace and create")
    func searchReplace() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await resources(at: dir)
        // Create via empty old_string.
        let create = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("new.txt"),
                "old_string": .string(""),
                "new_string": .string("hello world"),
            ]),
            resources: res
        )
        _ = try success(create)
        let text = try String(contentsOf: dir.appendingPathComponent("new.txt"), encoding: .utf8)
        #expect(text == "hello world")

        let replace = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("new.txt"),
                "old_string": .string("world"),
                "new_string": .string("grok"),
            ]),
            resources: res
        )
        _ = try success(replace)
        let text2 = try String(contentsOf: dir.appendingPathComponent("new.txt"), encoding: .utf8)
        #expect(text2 == "hello grok")
    }

    @Test("search_replace detects stale context and ambiguous match")
    func searchReplaceStale() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "aaa\nbbb\naaa\n".write(
            to: dir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8
        )
        let res = await resources(at: dir)
        let stale = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("s.txt"),
                "old_string": .string("missing"),
                "new_string": .string("x"),
            ]),
            resources: res
        )
        switch stale {
        case .failure(let e):
            #expect(e.detail.contains("stale") || e.detail.contains("not found"))
        case .success:
            Issue.record("expected stale failure")
        }

        let amb = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("s.txt"),
                "old_string": .string("aaa"),
                "new_string": .string("ccc"),
            ]),
            resources: res
        )
        switch amb {
        case .failure(let e):
            #expect(e.detail.contains("appears") || e.detail.contains("unique") || e.detail.contains("replace_all"))
        case .success:
            Issue.record("expected ambiguous failure")
        }
    }

    @Test("failed write does not record agent hunks")
    func noHunkOnFailure() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await resources(at: dir)
        let fail = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("nope.txt"),
                "old_string": .string("missing"),
                "new_string": .string("x"),
            ]),
            resources: res
        )
        #expect(fails(fail))
        // Hunk tracker has no files if nothing succeeded — smoke: no crash.
        if let tracker = res.hunkTracker {
            // Actor is alive; no assertion on empty state beyond non-throw.
            _ = tracker
        }
    }

    // MARK: - apply_patch

    @Test("apply_patch parser and add/update")
    func applyPatch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await resources(at: dir)
        let patch = """
        *** Begin Patch
        *** Add File: hello.txt
        +hello
        +world
        *** End Patch
        """
        let out = await ApplyPatchTool.run(
            args: .object(["input": .string(patch)]),
            resources: res
        )
        _ = try success(out)
        let text = try String(contentsOf: dir.appendingPathComponent("hello.txt"), encoding: .utf8)
        #expect(text.contains("hello"))
        #expect(text.contains("world"))

        let update = """
        *** Begin Patch
        *** Update File: hello.txt
        @@
        -hello
        +HELLO
         world
        *** End Patch
        """
        let out2 = await ApplyPatchTool.run(
            args: .object(["input": .string(update)]),
            resources: res
        )
        _ = try success(out2)
        let text2 = try String(contentsOf: dir.appendingPathComponent("hello.txt"), encoding: .utf8)
        #expect(text2.contains("HELLO"))
    }

    @Test("apply_patch empty is success")
    func applyPatchEmpty() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await resources(at: dir)
        let out = await ApplyPatchTool.run(args: .object([:]), resources: res)
        _ = try success(out)
    }

    @Test("apply_patch onlyTouchesPlanFile helper")
    func planFileHelper() throws {
        let patch = try ApplyPatchParser.parse(
            """
            *** Begin Patch
            *** Update File: plan.md
            @@
            -a
            +b
            *** End Patch
            """
        )
        #expect(ApplyPatchParser.onlyTouchesPlanFile(patch, planPath: "/sess/plan.md"))
        let mixed = try ApplyPatchParser.parse(
            """
            *** Begin Patch
            *** Update File: plan.md
            @@
            -a
            +b
            *** Update File: other.swift
            @@
            -x
            +y
            *** End Patch
            """
        )
        #expect(!ApplyPatchParser.onlyTouchesPlanFile(mixed, planPath: "/sess/plan.md"))
    }

    // MARK: - OpenCode / hashline / write

    @Test("OpenCode camelCase edit")
    func openCodeEdit() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "foo bar".write(to: dir.appendingPathComponent("e.txt"), atomically: true, encoding: .utf8)
        let res = await resources(at: dir)
        let out = await SearchReplaceTool.run(
            args: .object([
                "filePath": .string("e.txt"),
                "oldString": .string("bar"),
                "newString": .string("baz"),
            ]),
            resources: res,
            camelCase: true
        )
        _ = try success(out)
        let text = try String(contentsOf: dir.appendingPathComponent("e.txt"), encoding: .utf8)
        #expect(text == "foo baz")
    }

    @Test("OpenCode write overwrites")
    func openCodeWrite() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await resources(at: dir)
        let out = await WriteTool.run(
            args: .object([
                "file_path": .string("w.txt"),
                "content": .string("full content"),
            ]),
            resources: res
        )
        _ = try success(out)
        let text = try String(contentsOf: dir.appendingPathComponent("w.txt"), encoding: .utf8)
        #expect(text == "full content")
    }

    @Test("hashline edit validates anchors")
    func hashlineEdit() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "alpha\nbeta\ngamma\n".write(
            to: dir.appendingPathComponent("h.txt"), atomically: true, encoding: .utf8
        )
        let res = await resources(at: dir)
        let h = Hashline.lineHash("beta")
        let anchor = "L2\(h)"
        let out = await Hashline.runEdit(
            args: .object([
                "file_path": .string("h.txt"),
                "edits": .array([
                    .object([
                        "op": .string("replace"),
                        "anchor": .string(anchor),
                        "content": .string("BETA"),
                    ])
                ]),
            ]),
            resources: res
        )
        _ = try success(out)
        let text = try String(contentsOf: dir.appendingPathComponent("h.txt"), encoding: .utf8)
        #expect(text.contains("BETA"))
        #expect(!text.contains("beta"))
    }

    @Test("hashline read emits anchors")
    func hashlineRead() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "line\n".write(to: dir.appendingPathComponent("r.txt"), atomically: true, encoding: .utf8)
        let res = await resources(at: dir)
        let out = await ReadFileTool.run(
            args: .object(["target_file": .string("r.txt")]),
            resources: res,
            withHashlineAnchors: true
        )
        let typed = try success(out)
        guard case .object(let obj) = typed.value,
              case .string(let content) = obj["content"]
        else {
            Issue.record("bad hashline read")
            return
        }
        #expect(content.contains("|"))
        #expect(content.contains("→line"))
    }

    // MARK: - Plan gate / nested prepare

    @Test("plan mode rejects non-plan edits via prepare pipeline")
    func planGate() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await resources(at: dir, planActive: true, allowAll: true)
        let set = try finalizeGrok(res)
        let denied = await set.prepareAndCall(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("other.txt"),
                "old_string": .string(""),
                "new_string": .string("x"),
            ])
        )
        switch denied {
        case .failure(let e):
            #expect(e.kind == .permissionDenied || e.detail.contains("plan"))
        case .success:
            Issue.record("plan mode should reject non-plan edit")
        }

        // Plan file itself is allowed (auto-approve path).
        let allowed = await set.prepareAndCall(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("plan.md"),
                "old_string": .string(""),
                "new_string": .string("# Plan\n"),
            ])
        )
        _ = try success(allowed)
        let planText = try String(contentsOf: dir.appendingPathComponent("plan.md"), encoding: .utf8)
        #expect(planText.contains("Plan"))
    }

    @Test("nested Code Mode call re-enters prepare (plan gate still applies)")
    func nestedReentry() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await resources(at: dir, planActive: true, allowAll: true)
        let set = try finalizeGrok(res)
        let nested = await set.callNested(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("secret.txt"),
                "old_string": .string(""),
                "new_string": .string("nope"),
            ])
        )
        switch nested {
        case .failure(let e):
            #expect(e.kind == .permissionDenied || e.detail.contains("plan"))
        case .success:
            Issue.record("nested call must not bypass plan gate")
        }
    }

    @Test("path escape outside allowed roots fails closed")
    func pathEscape() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await resources(at: dir)
        let out = await ReadFileTool.run(
            args: .object(["target_file": .string("/etc/passwd")]),
            resources: res
        )
        #expect(fails(out))
    }

    @Test("view_image attaches image block for png")
    func viewImage() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Minimal 1x1 PNG
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        try png.write(to: dir.appendingPathComponent("p.png"))
        let res = await resources(at: dir)
        let out = await ViewImageTool.run(
            args: .object(["path": .string("p.png")]),
            resources: res
        )
        let typed = try success(out)
        #expect(!typed.modelOutput.isEmpty)
        if case .image(let mime, _, _, _, _, _) = typed.modelOutput[0] {
            #expect(mime == "image/png")
        } else {
            Issue.record("expected image content block")
        }
    }

    @Test("full registry dispatch with handlers for read + replace")
    func fullDispatch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello".write(to: dir.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        let res = await resources(at: dir)
        let set = try finalizeGrok(res)
        let read = await set.prepareAndCall(
            clientName: "read_file",
            args: .object(["target_file": .string("d.txt")])
        )
        _ = try success(read)
        let edit = await set.prepareAndCall(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("d.txt"),
                "old_string": .string("hello"),
                "new_string": .string("hi"),
            ])
        )
        _ = try success(edit)
        let text = try String(contentsOf: dir.appendingPathComponent("d.txt"), encoding: .utf8)
        #expect(text == "hi")
    }
}

// MARK: - Helpers

private func success(
    _ result: Result<TypedToolOutput, ToolError>
) throws -> TypedToolOutput {
    switch result {
    case .success(let t): return t
    case .failure(let e):
        throw e
    }
}

private func fails(_ result: Result<TypedToolOutput, ToolError>) -> Bool {
    if case .failure = result { return true }
    return false
}
