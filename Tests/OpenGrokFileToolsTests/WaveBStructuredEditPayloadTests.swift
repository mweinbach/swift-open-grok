// WaveBStructuredEditPayloadTests.swift
//
// Wave B-FILETOOLS — structured edit payload producer.
// Proves: multi-hunk search_replace + replace_all, apply_patch edits
// (add/update/delete/move, atomic failure), write/create classification
// vs overwrite, insert/delete counts, honest paths, trusted/untrusted
// provenance, and that failure outputs remain honest (no fabricated diffs).
//
// Rust refs (pin 650c1db7):
// - types/output.rs SearchReplaceEditsApplied / SearchReplaceEditDetail / line_diff / ApplyPatchFileResult
// - diff.rs build_diff_hunks / stitch_overlapping_hunks
// - implementations/grok_build/search_replace/helpers.rs build_edit_details
// - implementations/opencode/write/mod.rs WriteTool
// - implementations/codex/apply_patch/tool.rs compute_all_changes
// - acp/tracker.rs EditToolCallBlock summary_untrusted (multi-file / multi-diff)

import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspace

@Suite("WaveB structured edit payloads")
struct WaveBStructuredEditPayloadTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-waveb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resources(at url: URL) -> ToolResources {
        ToolResources(
            cwd: url.path,
            sessionFolder: url.path,
            permissionPipeline: PermissionPipeline(
                permissions: PermissionHandle(allowAll: true, shellCwd: url.path)
            ),
            allowedRoots: [url.path]
        )
    }

    private func obj(_ typed: TypedToolOutput) throws -> [String: JSONValue] {
        guard case .object(let o) = typed.value else {
            throw ToolError.invalidArguments("not an object: \(typed.value)")
        }
        return o
    }

    private func requireString(_ o: [String: JSONValue], key: String) throws -> String {
        guard case .string(let s) = o[key] else { throw ToolError.invalidArguments("missing string \(key)") }
        return s
    }

    private func requireInt(_ o: [String: JSONValue], key: String) throws -> Int64 {
        guard case .number(let n) = o[key], let v = n.int64Value else { throw ToolError.invalidArguments("missing int \(key)") }
        return v
    }

    private func requireBool(_ o: [String: JSONValue], key: String) throws -> Bool {
        guard case .bool(let b) = o[key] else { throw ToolError.invalidArguments("missing bool \(key)") }
        return b
    }

    // MARK: SearchReplace — single hunk honest

    @Test("search_replace single replacement emits honest single-detail payload")
    func searchReplaceSingleHunk() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one\ntwo OLD here\nthree\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let res = resources(at: dir)
        let out = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("a.txt"),
                "old_string": .string("OLD"),
                "new_string": .string("NEW"),
            ]),
            resources: res
        )
        let typed = try success(out)
        let o = try obj(typed)
        let path = try requireString(o, key: "path")
        #expect(path.hasSuffix("a.txt"))
        let absPath = try requireString(o, key: "absolute_path")
        #expect(absPath == path)
        #expect(try requireInt(o, key: "replacements") == 1)
        #expect(try requireString(o, key: "old_string") == "OLD")
        #expect(try requireString(o, key: "new_string") == "NEW")
        #expect(try requireBool(o, key: "trusted"))
        #expect(!(try requireBool(o, key: "created")))
        guard case .object(let edits) = o["edits"], case .array(let details) = edits["details"] else {
            Issue.record("missing edits.details array"); return
        }
        #expect(details.count == 1)
        guard case .object(let d) = details[0] else { Issue.record("detail not object"); return }
        #expect(try requireString(d, key: "old_string") == "OLD")
        #expect(try requireString(d, key: "new_string") == "NEW")
        // Honest region: context covers neighbouring lines, line numbers are sane and 1-based.
        guard case .string(let before) = d["context_before"], case .string(let after) = d["context_after"] else {
            Issue.record("missing context"); return
        }
        #expect(before.contains("one") || before.contains("two"))
        let oldLine = try requireInt(d, key: "old_line")
        let newLine = try requireInt(d, key: "new_line")
        #expect(oldLine >= 1 && oldLine <= 3)
        #expect(newLine == oldLine)
        _ = after
        // Counts are honest for the *edit strings*, not the whole file.
        let added = try requireInt(o, key: "lines_added")
        let removed = try requireInt(o, key: "lines_removed")
        #expect(added >= 0 && removed >= 0)
        // Legacy `type/content/created` still present for provider-wire compat.
        #expect(try requireString(o, key: "type") == "edits_applied")
        #expect(o["content"] != nil)
    }

    @Test("search_replace multi-hunk via replace_all produces N details and untrusted summary")
    func searchReplaceMultiHunkReplaceAll() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x=1\nhi\nhi\nhi\nend\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let res = resources(at: dir)
        let out = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("b.txt"),
                "old_string": .string("hi"),
                "new_string": .string("hello"),
                "replace_all": .bool(true),
            ]),
            resources: res
        )
        let typed = try success(out)
        let o = try obj(typed)
        #expect(try requireInt(o, key: "replacements") == 3)
        #expect(!(try requireBool(o, key: "trusted")), "replace_all multi-edit must be untrusted")
        guard case .object(let edits) = o["edits"], case .array(let details) = edits["details"] else {
            Issue.record("missing details"); return
        }
        #expect(details.count == 3, "three occurrences → three details")
        // Each detail points at its own region (different line numbers).
        var lines: Set<Int64> = []
        for det in details {
            guard case .object(let d) = det, case .number(let n) = d["new_line"], let v = n.int64Value else { continue }
            lines.insert(v)
        }
        #expect(lines.count == 3, "hunks at distinct lines, not one fabricated region")
        let added = try requireInt(o, key: "lines_added")
        let removed = try requireInt(o, key: "lines_removed")
        #expect(added == 3 && removed == 3, "three one-line replaces → 3 added / 3 removed")
        let text = try String(contentsOf: dir.appendingPathComponent("b.txt"), encoding: .utf8)
        #expect(text.filter { $0 == "h" }.count >= 3)
    }

    @Test("search_replace failure does not fabricate structured payload")
    func searchReplaceFailureHonest() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello\n".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let res = resources(at: dir)
        let missing = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("c.txt"),
                "old_string": .string("nope"),
                "new_string": .string("x"),
            ]),
            resources: res
        )
        switch missing {
        case .success:
            Issue.record("must fail on missing old_string")
        case .failure(let e):
            #expect(e.detail.contains("stale") || e.detail.contains("not found"))
        }
        let amb = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("c.txt"),
                "old_string": .string("l"),
                "new_string": .string("L"),
            ]),
            resources: res
        )
        switch amb {
        case .failure(let e):
            // "l" appears twice in "hello" → ambiguous
            #expect(e.detail.lowercased().contains("appears") || e.detail.contains("unique") || e.detail.contains("replace_all"))
        case .success:
            Issue.record("ambiguous without replace_all must fail")
        }
    }

    @Test("search_replace creation is creating, not editing — trusted single detail")
    func searchReplaceCreationClassification() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = resources(at: dir)
        let out = await SearchReplaceTool.run(
            args: .object([
                "file_path": .string("new.txt"),
                "old_string": .string(""),
                "new_string": .string("hello\nworld\n"),
            ]),
            resources: res
        )
        let typed = try success(out)
        let o = try obj(typed)
        #expect(try requireBool(o, key: "created"))
        #expect(try requireBool(o, key: "is_new_file"))
        #expect(try requireBool(o, key: "trusted"))
        let added = try requireInt(o, key: "lines_added")
        #expect(added == 2)
    }

    // MARK: WriteTool — creating vs editing, paths, counts

    @Test("write creates new file — Creating classification, path honest")
    func writeCreating() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = resources(at: dir)
        let out = await WriteTool.run(
            args: .object([
                "file_path": .string("w_new.txt"),
                "content": .string("a\nb\n"),
            ]),
            resources: res
        )
        let typed = try success(out)
        let o = try obj(typed)
        #expect(try requireBool(o, key: "created"))
        #expect(try requireBool(o, key: "is_new_file"))
        #expect(try requireBool(o, key: "trusted"))
        let path = try requireString(o, key: "path")
        #expect(path.hasSuffix("w_new.txt"))
        #expect(try requireString(o, key: "absolute_path") == path)
        #expect(try requireInt(o, key: "lines_added") == 2)
        #expect(try requireInt(o, key: "lines_removed") == 0)
        let onDisk = try String(contentsOf: dir.appendingPathComponent("w_new.txt"), encoding: .utf8)
        #expect(onDisk == "a\nb\n")
    }

    @Test("write overwrites existing file — editing classification, honest old/new")
    func writeOverwriteIsEditing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "old\n".write(to: dir.appendingPathComponent("w_old.txt"), atomically: true, encoding: .utf8)
        let res = resources(at: dir)
        let out = await WriteTool.run(
            args: .object([
                "file_path": .string("w_old.txt"),
                "content": .string("new\nline2\n"),
            ]),
            resources: res
        )
        let typed = try success(out)
        let o = try obj(typed)
        #expect(!(try requireBool(o, key: "created")), "overwrite is not a creation")
        #expect(!(try requireBool(o, key: "is_new_file")))
        #expect(try requireString(o, key: "old_string") == "old\n")
        #expect(try requireString(o, key: "new_string") == "new\nline2\n")
        // Honest counts for full-file overwrite (LCS over the file strings).
        let added = try requireInt(o, key: "lines_added")
        let removed = try requireInt(o, key: "lines_removed")
        #expect(added == 2 && removed == 1)
    }

    // MARK: ApplyPatch — multi-file edits, regions, trusted, failure honesty

    @Test("apply_patch multi-hunk multi-file has honest file_results, counts, trusted=false")
    func applyPatchMultiFileHonest() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a1\na2\n".write(to: dir.appendingPathComponent("f1.txt"), atomically: true, encoding: .utf8)
        try "b1\nb2\n".write(to: dir.appendingPathComponent("f2.txt"), atomically: true, encoding: .utf8)
        let res = resources(at: dir)
        let patch = """
        *** Begin Patch
        *** Add File: added.txt
        +fresh
        +line
        *** Update File: f1.txt
        @@
        -a1
        +A1
         a2
        *** Update File: f2.txt
        @@
        -b2
        +B2
        *** End Patch
        """
        let out = await ApplyPatchTool.run(args: .object(["input": .string(patch)]), resources: res)
        let typed = try success(out)
        let o = try obj(typed)
        let trusted = try requireBool(o, key: "trusted")
        #expect(!trusted, "multi-file patch must be summary-untrusted")
        let patchBack = try requireString(o, key: "patch")
        #expect(patchBack.contains("*** Begin Patch"))
        guard case .array(let files)? = o["file_results"] else {
            Issue.record("missing file_results array"); return
        }
        #expect(files.count == 3)
        // Each file has honest path + action + old/new + line counts + edits.details.
        for f in files {
            guard case .object(let fo) = f else { Issue.record("file not object"); continue }
            #expect(fo["path"] != nil)
            #expect(fo["action"] != nil)
            #expect(fo["new_text"] != nil)
            #expect(fo["lines_added"] != nil)
            #expect(fo["lines_removed"] != nil)
            guard case .object(let ed) = fo["edits"], case .array(let ds) = ed["details"] else {
                Issue.record("missing edits.details for file \(fo["path"] ?? .null)"); continue
            }
            #expect(!ds.isEmpty)
        }
        // At least one of the update files has +1/-1, and the add file has +2.
        let addedSum = try requireInt(o, key: "lines_added")
        let removedSum = try requireInt(o, key: "lines_removed")
        #expect(addedSum >= 3 && removedSum >= 2)
        // Disk must reflect all three.
        #expect(try String(contentsOf: dir.appendingPathComponent("added.txt"), encoding: .utf8).contains("fresh"))
        #expect(try String(contentsOf: dir.appendingPathComponent("f1.txt"), encoding: .utf8).contains("A1"))
        #expect(try String(contentsOf: dir.appendingPathComponent("f2.txt"), encoding: .utf8).contains("B2"))
    }

    @Test("apply_patch single-file update is trusted with honest counts")
    func applyPatchSingleFileTrusted() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x\ny\nz\n".write(to: dir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let res = resources(at: dir)
        let patch = """
        *** Begin Patch
        *** Update File: s.txt
        @@
        -y
        +Y
         z
        *** End Patch
        """
        let out = await ApplyPatchTool.run(args: .object(["input": .string(patch)]), resources: res)
        let typed = try success(out)
        let o = try obj(typed)
        #expect(try requireBool(o, key: "trusted"))
        #expect(try requireInt(o, key: "lines_added") == 1)
        #expect(try requireInt(o, key: "lines_removed") == 1)
        guard case .array(let fr)? = o["file_results"], case .object(let fo) = fr[0] else {
            Issue.record("missing file_results[0]"); return
        }
        #expect(try requireString(fo, key: "path").hasSuffix("s.txt"))
        #expect(try requireString(fo, key: "action") == "modified")
    }

    @Test("apply_patch failure is atomic and reports No changes were applied")
    func applyPatchFailureAtomicHonest() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "good\n".write(to: dir.appendingPathComponent("good.txt"), atomically: true, encoding: .utf8)
        try "bad\n".write(to: dir.appendingPathComponent("bad.txt"), atomically: true, encoding: .utf8)
        let res = resources(at: dir)
        let patch = """
        *** Begin Patch
        *** Update File: good.txt
        @@
        -good
        +GOOD
        *** Update File: bad.txt
        @@
        -nonexistent
        +X
        *** End Patch
        """
        let out = await ApplyPatchTool.run(args: .object(["input": .string(patch)]), resources: res)
        switch out {
        case .success:
            Issue.record("multi-hunk with one bad chunk must fail")
        case .failure(let e):
            #expect(e.detail.contains("No changes were applied"))
            #expect(e.detail.contains("1 of 2"))
        }
        // Atomic: the valid hunk's file must still hold its old content.
        #expect(try String(contentsOf: dir.appendingPathComponent("good.txt"), encoding: .utf8) == "good\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("bad.txt"), encoding: .utf8) == "bad\n")
    }

    @Test("apply_patch parse failure stays invalidArguments, no file_results fabricated")
    func applyPatchParseFailureHonest() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = resources(at: dir)
        let out = await ApplyPatchTool.run(args: .object(["input": .string("not a patch")]), resources: res)
        switch out {
        case .success:
            Issue.record("bad patch must not succeed")
        case .failure(let e):
            #expect(e.kind == .invalidArguments)
            #expect(e.detail.contains("Begin Patch"))
        }
    }

    // MARK: Helpers — assert status-returning calls rather than discarding

    private func success(_ r: Result<TypedToolOutput, ToolError>) throws -> TypedToolOutput {
        switch r {
        case .success(let t): return t
        case .failure(let e): throw e
        }
    }
}
