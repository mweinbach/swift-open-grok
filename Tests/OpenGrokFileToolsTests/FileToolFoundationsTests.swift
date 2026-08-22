import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspace

@Suite("OpenGrokFileTools foundational text and boundary parity")
struct FileToolFoundationsTests {
    private struct ChildOnlyDenyHook: PreToolUseHookRunner {
        func runPreToolUse(
            toolName: String,
            toolCallId: String,
            access: AccessKind,
            permissionMode: String?
        ) async -> PreToolUseHookDecision {
            .deny(reason: "child-local hook", hookName: "child-only")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-file-foundations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func resources(at directory: URL) -> ToolResources {
        FileToolSession.makeResources(
            workspaceRoot: directory.path,
            sessionId: "file-foundations",
            policy: .allowAll
        )
    }

    private func buildPack(at directory: URL) throws -> FinalizedToolset {
        try FileToolPack.finalizeBuildPack(resources: resources(at: directory))
    }

    private func requireSuccess(_ result: Result<TypedToolOutput, ToolError>) throws -> TypedToolOutput {
        switch result {
        case .success(let output):
            return output
        case .failure(let error):
            throw error
        }
    }

    @Test("child sessions inherit the exact permission actor without sharing plan mode or hooks")
    func childSessionsSharePermissionsButNotPipelineState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = resources(at: directory)
        let parentPipeline = try #require(parent.permissionPipeline)
        let parentHandle = await parentPipeline.permissions

        var childPlan = PlanModeTracker(sessionDirectory: directory.path)
        childPlan.enter(planFilePath: "child-plan.md")
        let child = FileToolSession.makeResources(
            workspaceRoot: directory.path,
            sessionId: "child-foundations",
            agentId: "child",
            policy: .denyMutations,
            planMode: childPlan,
            hooks: ChildOnlyDenyHook(),
            inheritedPermissionHandle: parentHandle
        )
        let childPipeline = try #require(child.permissionPipeline)

        #expect(childPipeline !== parentPipeline)
        let childHandle = await childPipeline.permissions
        #expect(childHandle === parentHandle)
        #expect(child.cwd == parent.cwd)
        #expect(await parentPipeline.planModeActive == false)
        #expect(await childPipeline.planModeActive == true)

        let request = PrepareToolAccessRequest(
            access: .edit(directory.appendingPathComponent("shared.txt").path),
            toolName: "write",
            toolCallId: "child-inheritance"
        )
        let planDecision = await childPipeline.prepare(request)
        #expect(planDecision.source == .planModeGate)
        #expect(!planDecision.mayDispatch)

        await childPipeline.exitPlanMode()
        let hookDecision = await childPipeline.prepare(request)
        #expect(hookDecision.source == .preToolUseHook)
        #expect(!hookDecision.mayDispatch)

        let parentDecision = await parentPipeline.prepare(request)
        #expect(parentDecision.source == .permissionEngine)
        #expect(parentDecision.mayDispatch)
        #expect(await parentPipeline.planModeActive == false)
    }

    @Test("live read_file counts CRLF lines and honors its requested window")
    func readFileCountsCRLFLineWindow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("windows.txt")
        try Data("one\r\ntwo\r\nthree\r\nfour\r\n".utf8).write(to: file)

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "read_file",
            args: .object([
                "target_file": .string("windows.txt"),
                "offset": .number(.int64(2)),
                "limit": .number(.int64(2)),
            ])
        ))

        guard case .object(let value) = output.value else {
            Issue.record("read_file returned an unexpected output shape")
            return
        }
        #expect(value["content"] == .string("2→two\n3→three"))
        #expect(value["total_lines"] == .number(.int64(4)))
        #expect(value["start_line"] == .number(.int64(2)))
        #expect(value["end_line"] == .number(.int64(3)))
        #expect(value["truncated"] == .bool(true))
    }

    @Test("live grep reports logical CRLF line numbers without carriage returns")
    func grepReportsCRLFLineNumbers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("first\r\nsecond needle\r\nthird needle\r\n".utf8)
            .write(to: directory.appendingPathComponent("windows.txt"))

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "grep",
            args: .object([
                "pattern": .string("needle"),
                "path": .string("."),
            ])
        ))

        guard case .object(let value) = output.value,
              case .array(let matches)? = value["matches"]
        else {
            Issue.record("grep returned an unexpected output shape")
            return
        }
        #expect(value["match_count"] == .number(.int64(2)))
        #expect(matches.count == 2)
        if case .object(let first) = matches[0] {
            #expect(first["line_number"] == .number(.int64(2)))
            #expect(first["text"] == .string("second needle"))
        } else {
            Issue.record("first grep result is not an object")
        }
        if case .object(let second) = matches[1] {
            #expect(second["line_number"] == .number(.int64(3)))
            #expect(second["text"] == .string("third needle"))
        } else {
            Issue.record("second grep result is not an object")
        }
    }

    @Test("recursive grep never follows a file symlink outside its authorized roots")
    func grepRejectsOutboundFileSymlink() async throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }

        let secret = outside.appendingPathComponent("credentials.txt")
        try "OUTSIDE_SECRET_TOKEN\n".write(to: secret, atomically: true, encoding: .utf8)
        try "INSIDE_SECRET_TOKEN\n".write(
            to: directory.appendingPathComponent("allowed.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("leaked.txt"),
            withDestinationURL: secret
        )

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "grep",
            args: .object([
                "pattern": .string("SECRET_TOKEN"),
                "path": .string("."),
            ])
        ))

        guard case .object(let value) = output.value,
              case .string(let content)? = value["content"],
              case .array(let matches)? = value["matches"]
        else {
            Issue.record("grep returned an unexpected output shape")
            return
        }
        #expect(content.contains("INSIDE_SECRET_TOKEN"))
        #expect(!content.contains("OUTSIDE_SECRET_TOKEN"))
        #expect(!content.contains("leaked.txt"))
        #expect(matches.count == 1)
        #expect(value["match_count"] == .number(.int64(1)))
    }

    @Test("recursive grep honors root and nested ignore files before reading content")
    func grepRespectsScopedGitignoreRules() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        let ignoredDirectory = directory.appendingPathComponent("generated", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        try Data("ignored.txt\r\ngenerated/\r\n".utf8)
            .write(to: directory.appendingPathComponent(".gitignore"))
        try "nested-secret.txt\n".write(
            to: nested.appendingPathComponent(".ignore"),
            atomically: true,
            encoding: .utf8
        )
        for file in [
            directory.appendingPathComponent("ignored.txt"),
            ignoredDirectory.appendingPathComponent("output.txt"),
            nested.appendingPathComponent("nested-secret.txt"),
        ] {
            try "needle ignored\n".write(to: file, atomically: true, encoding: .utf8)
        }
        try "needle allowed\n".write(
            to: nested.appendingPathComponent("allowed.txt"),
            atomically: true,
            encoding: .utf8
        )

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "grep",
            args: .object([
                "pattern": .string("needle"),
                "path": .string("."),
            ])
        ))

        guard case .object(let value) = output.value,
              case .string(let content)? = value["content"]
        else {
            Issue.record("grep returned an unexpected output shape")
            return
        }
        #expect(value["match_count"] == .number(.int64(1)))
        #expect(content.contains("allowed.txt"))
        #expect(!content.contains("ignored.txt"))
        #expect(!content.contains("generated"))
        #expect(!content.contains("nested-secret.txt"))
    }

    @Test("grep supports brace alternation and recursive double-star glob patterns")
    func grepSupportsRipgrepGlobForms() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in ["app.ts", "nested/view.tsx", "skip.js"] {
            try "needle\n".write(
                to: directory.appendingPathComponent(path),
                atomically: true,
                encoding: .utf8
            )
        }

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "grep",
            args: .object([
                "pattern": .string("needle"),
                "path": .string("."),
                "glob": .string("**/*.{ts,tsx}"),
            ])
        ))

        guard case .object(let value) = output.value,
              case .string(let content)? = value["content"]
        else {
            Issue.record("grep returned an unexpected output shape")
            return
        }
        #expect(value["match_count"] == .number(.int64(2)))
        #expect(content.contains("app.ts"))
        #expect(content.contains("view.tsx"))
        #expect(!content.contains("skip.js"))
    }

    @Test("search_replace matches LF model context against CRLF and preserves CRLF bytes")
    func searchReplacePreservesCRLF() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("windows.txt")
        try Data("header\r\nhello\r\nworld\r\nfooter\r\n".utf8).write(to: file)

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("windows.txt"),
                "old_string": .string("hello\nworld"),
                "new_string": .string("goodbye\nearth"),
            ])
        ))

        #expect(try Data(contentsOf: file) == Data("header\r\ngoodbye\r\nearth\r\nfooter\r\n".utf8))
        guard case .object(let value) = output.value,
              case .object(let edits)? = value["edits"],
              case .array(let details)? = edits["details"],
              case .object(let detail)? = details.first
        else {
            Issue.record("search_replace returned an unexpected edit shape")
            return
        }
        #expect(detail["old_line"] == .number(.int64(2)))
        #expect(detail["new_line"] == .number(.int64(2)))
    }

    @Test("search_replace replace_all normalizes mixed endings to the original CRLF style")
    func searchReplaceAllNormalizesMixedCRLF() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed.txt")
        try Data("foo\r\nbar\nfoo\r\nbaz\n".utf8).write(to: file)

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("mixed.txt"),
                "old_string": .string("foo"),
                "new_string": .string("qux"),
                "replace_all": .bool(true),
            ])
        ))

        #expect(try Data(contentsOf: file) == Data("qux\r\nbar\r\nqux\r\nbaz\r\n".utf8))
        guard case .object(let value) = output.value else {
            Issue.record("search_replace returned an unexpected output shape")
            return
        }
        #expect(value["replacements"] == .number(.int64(2)))
    }

    @Test("CRLF patch text updates CRLF files without rewriting their line endings")
    func applyPatchParsesAndPreservesCRLF() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("windows.txt")
        try Data("alpha\r\nbeta\r\ngamma\r\n".utf8).write(to: file)
        let patch = [
            "*** Begin Patch",
            "*** Update File: windows.txt",
            "@@",
            " alpha",
            "-beta",
            "+BETA",
            " gamma",
            "*** End Patch",
        ].joined(separator: "\r\n")

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "apply_patch",
            args: .object(["input": .string(patch)])
        ))

        #expect(try Data(contentsOf: file) == Data("alpha\r\nBETA\r\ngamma\r\n".utf8))
        guard case .object(let value) = output.value else {
            Issue.record("apply_patch returned an unexpected output shape")
            return
        }
        #expect(value["lines_added"] == .number(.int64(1)))
        #expect(value["lines_removed"] == .number(.int64(1)))
    }

    @Test("patch matching mirrors upstream trailing-whitespace and Unicode punctuation fallback")
    func applyPatchUsesUpstreamFuzzyContextMatching() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let whitespace = directory.appendingPathComponent("spaces.swift")
        let punctuation = directory.appendingPathComponent("unicode.swift")
        try "func run() {   \n    oldValue()\t\n}\n"
            .write(to: whitespace, atomically: true, encoding: .utf8)
        try "let message = \"hello – world\"\n"
            .write(to: punctuation, atomically: true, encoding: .utf8)
        let patch = """
            *** Begin Patch
            *** Update File: spaces.swift
            @@ func run() {
            -    oldValue()
            +    newValue()
            *** Update File: unicode.swift
            @@
            -let message = "hello - world"
            +let message = "updated"
            *** End Patch
            """

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "apply_patch",
            args: .object(["input": .string(patch)])
        ))

        guard case .object(let value) = output.value else {
            Issue.record("apply_patch returned an unexpected output shape")
            return
        }
        #expect(value["trusted"] == .bool(false))
        #expect(try String(contentsOf: whitespace, encoding: .utf8) == "func run() {   \n    newValue()\n}\n")
        #expect(try String(contentsOf: punctuation, encoding: .utf8) == "let message = \"updated\"\n")
    }

    @Test("patch EOF markers update the final repeated matching region")
    func applyPatchEndOfFilePrefersFinalMatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("repeated.txt")
        try "header\nrepeat\nseparator\nrepeat\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let patch = """
            *** Begin Patch
            *** Update File: repeated.txt
            @@
            -repeat
            +final
            *** End of File
            *** End Patch
            """

        let output = try requireSuccess(await buildPack(at: directory).prepareAndCall(
            clientName: "apply_patch",
            args: .object(["input": .string(patch)])
        ))

        guard case .object(let value) = output.value else {
            Issue.record("apply_patch returned an unexpected output shape")
            return
        }
        #expect(value["lines_added"] == .number(.int64(1)))
        #expect(try String(contentsOf: file, encoding: .utf8) == "header\nrepeat\nseparator\nfinal\n")
    }

    @Test("missing patch change-context never silently applies a matching line elsewhere")
    func applyPatchRejectsMissingChangeContext() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("context.txt")
        let original = "existing context\ntarget\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let patch = """
            *** Begin Patch
            *** Update File: context.txt
            @@ nonexistent context
            -target
            +changed
            *** End Patch
            """

        let pack = try buildPack(at: directory)
        let result = await pack.prepareAndCall(
            clientName: "apply_patch",
            args: .object(["input": .string(patch)])
        )

        switch result {
        case .failure(let error):
            #expect(error.detail.contains("nonexistent context"))
            #expect(error.detail.contains("No changes were applied"))
        case .success:
            Issue.record("apply_patch ignored its missing change-context")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test("hashline read anchors and edits target logical CRLF lines")
    func hashlineReadAndEditPreserveCRLF() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("windows.txt")
        try Data("alpha\r\nbeta\r\ngamma\r\n".utf8).write(to: file)
        let pack = try FileToolPack.finalizePreset(.hashline, resources: resources(at: directory))

        let read = try requireSuccess(await pack.prepareAndCall(
            clientName: "hashline_read",
            args: .object(["target_file": .string("windows.txt")])
        ))
        let anchor = Hashline.anchor(for: "beta", line: 2)
        guard case .object(let readValue) = read.value,
              case .string(let readContent)? = readValue["content"]
        else {
            Issue.record("hashline_read returned an unexpected output shape")
            return
        }
        #expect(readContent.contains("2|\(anchor)→beta"))
        #expect(readValue["total_lines"] == .number(.int64(3)))

        let edit = try requireSuccess(await pack.prepareAndCall(
            clientName: "hashline_edit",
            args: .object([
                "file_path": .string("windows.txt"),
                "edits": .array([
                    .object([
                        "op": .string("replace"),
                        "anchor": .string(anchor),
                        "content": .string("BETA\nINSERTED"),
                    ])
                ]),
            ])
        ))
        guard case .object(let editValue) = edit.value else {
            Issue.record("hashline_edit returned an unexpected output shape")
            return
        }
        #expect(editValue["applied"] == .number(.int64(1)))
        #expect(try Data(contentsOf: file) == Data("alpha\r\nBETA\r\nINSERTED\r\ngamma\r\n".utf8))
    }

    @Test("invalid UTF-8 fails closed across every live mutation without changing bytes")
    func invalidUTF8CannotBeSilentlyRewritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invalid.txt")
        let original = Data([0x68, 0x69, 0x0A, 0xFF, 0xFE, 0x0A])
        try original.write(to: file)
        let pack = try buildPack(at: directory)

        let calls: [(String, JSONValue)] = [
            ("read_file", .object(["target_file": .string("invalid.txt")])),
            ("search_replace", .object([
                "file_path": .string("invalid.txt"),
                "old_string": .string("hi"),
                "new_string": .string("changed"),
            ])),
            ("search_replace", .object([
                "file_path": .string("invalid.txt"),
                "old_string": .string(""),
                "new_string": .string("changed"),
            ])),
            ("write", .object([
                "file_path": .string("invalid.txt"),
                "content": .string("changed"),
            ])),
            ("apply_patch", .object([
                "input": .string("""
                    *** Begin Patch
                    *** Update File: invalid.txt
                    @@
                    -hi
                    +changed
                    *** End Patch
                    """),
            ])),
        ]

        for (name, arguments) in calls {
            let result = await pack.prepareAndCall(clientName: name, args: arguments)
            switch result {
            case .failure(let error):
                #expect(error.detail.localizedCaseInsensitiveContains("UTF-8"), "\(name): \(error)")
            case .success:
                Issue.record("\(name) unexpectedly accepted invalid UTF-8")
            }
            #expect(try Data(contentsOf: file) == original, "\(name) modified invalid UTF-8 bytes")
        }
    }

    @Test("an invalid UTF-8 add hunk prevents every earlier patch write")
    func invalidUTF8PatchAddRemainsAtomic() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("invalid.txt")
        let original = Data([0x80, 0x81, 0x0A])
        try original.write(to: invalid)
        let patch = """
            *** Begin Patch
            *** Add File: fresh.txt
            +new content
            *** Add File: invalid.txt
            +replacement
            *** End Patch
            """

        let pack = try buildPack(at: directory)
        let result = await pack.prepareAndCall(
            clientName: "apply_patch",
            args: .object(["input": .string(patch)])
        )

        switch result {
        case .failure(let error):
            #expect(error.detail.localizedCaseInsensitiveContains("UTF-8"))
            #expect(error.detail.contains("No changes were applied"))
        case .success:
            Issue.record("apply_patch unexpectedly accepted invalid UTF-8")
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("fresh.txt").path
        ))
        #expect(try Data(contentsOf: invalid) == original)
    }

    @Test("patch overlays remember deleted files and reject later updates atomically")
    func patchOverlayPreservesDeletedTombstone() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("delete.txt")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let patch = """
            *** Begin Patch
            *** Delete File: delete.txt
            *** Update File: delete.txt
            @@
            -original
            +changed
            *** End Patch
            """

        let pack = try buildPack(at: directory)
        let result = await pack.prepareAndCall(
            clientName: "apply_patch",
            args: .object(["input": .string(patch)])
        )

        switch result {
        case .failure(let error):
            #expect(error.detail.contains("deleted by an earlier hunk"))
            #expect(error.detail.contains("No changes were applied"))
        case .success:
            Issue.record("apply_patch updated a file its prior hunk deleted")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")
    }
}
