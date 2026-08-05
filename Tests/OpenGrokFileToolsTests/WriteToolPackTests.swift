// WriteToolPackTests.swift
//
// Write-capable `.build` pack: preset composition, schema round-trips,
// atomic writes, containment / symlink escape, stale-edit detection, and
// permission denial blocking dispatch.

import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace

@Suite("OpenGrokFileTools write pack")
struct WriteToolPackTests {

    // MARK: - Fixtures

    private func tempDir(_ label: String = "root") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-writepack-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resources(
        at root: URL,
        policy: FileToolAccessPolicy = .allowAll
    ) -> ToolResources {
        FileToolSession.makeResources(
            workspaceRoot: root.path,
            sessionId: "write-pack-test",
            policy: policy
        )
    }

    private func buildPack(
        at root: URL,
        policy: FileToolAccessPolicy = .allowAll,
        capabilityMode: ToolCapabilityMode = .readWrite
    ) throws -> FinalizedToolset {
        try FileToolPack.finalizeBuildPack(
            resources: resources(at: root, policy: policy),
            capabilityMode: capabilityMode
        )
    }

    // MARK: - Preset composition

    @Test("build preset exposes the mutation tools alongside the read tools")
    func buildPresetComposition() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = Set(try buildPack(at: dir).topLevelDefinitions().map(\.name))
        #expect(names.isSuperset(of: [
            "read_file", "list_dir", "grep", "glob", "view_image",
            "search_replace", "write", "apply_patch",
        ]))
    }

    @Test("read-only capability drops every mutating tool from the build preset")
    func buildPresetReadOnlyDropsMutations() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = Set(
            try buildPack(at: dir, capabilityMode: .readOnly).topLevelDefinitions().map(\.name)
        )
        #expect(names.contains("read_file"))
        #expect(!names.contains("write"))
        #expect(!names.contains("search_replace"))
        #expect(!names.contains("apply_patch"))
    }

    @Test("mutation tool schemas declare the parameters their parsers require")
    func mutationSchemaRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let definitions = try buildPack(at: dir).topLevelDefinitions()
        let expected: [String: [String]] = [
            "write": ["file_path", "content"],
            "search_replace": ["file_path", "old_string", "new_string"],
            "apply_patch": ["input"],
        ]
        for (name, required) in expected {
            guard let definition = definitions.first(where: { $0.name == name }),
                  case .object(let schema)? = definition.argumentsSchema,
                  case .object(let properties)? = schema["properties"],
                  case .array(let requiredValues)? = schema["required"]
            else {
                Issue.record("missing schema for \(name)")
                continue
            }
            let requiredNames = Set(requiredValues.compactMap { value -> String? in
                if case .string(let s) = value { return s }
                return nil
            })
            for key in required {
                #expect(properties[key] != nil, "\(name) schema lacks \(key)")
                #expect(requiredNames.contains(key), "\(name) does not require \(key)")
            }
        }
    }

    // MARK: - Writes

    @Test("write replaces content atomically and leaves no temp files behind")
    func atomicWriteLeavesNoResidue() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("app.txt")
        try "old\n".write(to: file, atomically: true, encoding: .utf8)

        let set = try buildPack(at: dir)
        let result = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("app.txt"),
                "content": .string("new\n"),
            ])
        )
        _ = try success(result)

        #expect(try String(contentsOf: file, encoding: .utf8) == "new\n")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries == ["app.txt"])
    }

    @Test("write creates missing parent directories inside the workspace")
    func writeCreatesParents() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildPack(at: dir)
        let result = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("nested/deep/new.txt"),
                "content": .string("hello"),
            ])
        )
        _ = try success(result)
        let created = dir.appendingPathComponent("nested/deep/new.txt")
        #expect(try String(contentsOf: created, encoding: .utf8) == "hello")
    }

    @Test("apply_patch adds and updates files through the build pack")
    func applyPatchThroughPack() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "alpha\nbeta\n".write(
            to: dir.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8
        )
        let set = try buildPack(at: dir)
        let patch = """
            *** Begin Patch
            *** Add File: added.txt
            +fresh
            *** Update File: existing.txt
            @@
            -beta
            +gamma
            *** End Patch
            """
        let result = await set.prepareAndCall(
            clientName: "apply_patch",
            args: .object(["input": .string(patch)])
        )
        _ = try success(result)
        #expect(
            try String(contentsOf: dir.appendingPathComponent("added.txt"), encoding: .utf8)
                .contains("fresh")
        )
        #expect(
            try String(contentsOf: dir.appendingPathComponent("existing.txt"), encoding: .utf8)
                .contains("gamma")
        )
    }

    // MARK: - Containment

    @Test("writes outside the allowed roots are rejected")
    func rejectsEscapeOutsideRoots() async throws {
        let dir = try tempDir()
        let outside = try tempDir("outside")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let set = try buildPack(at: dir)
        let absolute = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string(outside.appendingPathComponent("x.txt").path),
                "content": .string("nope"),
            ])
        )
        #expect(fails(absolute))
        let traversal = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("../escape.txt"),
                "content": .string("nope"),
            ])
        )
        #expect(fails(traversal))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("x.txt").path))
    }

    @Test("symlinks pointing outside the workspace are rejected")
    func rejectsSymlinkEscape() async throws {
        let dir = try tempDir()
        let outside = try tempDir("outside")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let target = outside.appendingPathComponent("secret.txt")
        try "secret\n".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let set = try buildPack(at: dir)
        let result = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("link.txt"),
                "content": .string("overwritten"),
            ])
        )
        #expect(fails(result))
        #expect(try String(contentsOf: target, encoding: .utf8) == "secret\n")
    }

    // MARK: - Stale context

    @Test("search_replace reports stale context when old_string is absent")
    func staleEditDetection() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.txt")
        try "current contents\n".write(to: file, atomically: true, encoding: .utf8)
        let set = try buildPack(at: dir)
        let result = await set.prepareAndCall(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("s.txt"),
                "old_string": .string("stale contents"),
                "new_string": .string("replacement"),
            ])
        )
        guard case .failure(let error) = result else {
            Issue.record("expected stale-context failure")
            return
        }
        #expect(error.detail.contains("stale context"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "current contents\n")
    }

    @Test("ambiguous matches are rejected unless replace_all is set")
    func ambiguousEditRejected() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dup.txt")
        try "x\nx\n".write(to: file, atomically: true, encoding: .utf8)
        let set = try buildPack(at: dir)
        let ambiguous = await set.prepareAndCall(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("dup.txt"),
                "old_string": .string("x"),
                "new_string": .string("y"),
            ])
        )
        #expect(fails(ambiguous))
        let all = await set.prepareAndCall(
            clientName: "search_replace",
            args: .object([
                "file_path": .string("dup.txt"),
                "old_string": .string("x"),
                "new_string": .string("y"),
                "replace_all": .bool(true),
            ])
        )
        _ = try success(all)
        #expect(try String(contentsOf: file, encoding: .utf8) == "y\ny\n")
    }

    // MARK: - Permission gate

    @Test("deny-by-default policy blocks mutation dispatch but keeps reads")
    func permissionDenyBlocksDispatch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("guarded.txt")
        try "untouched\n".write(to: file, atomically: true, encoding: .utf8)

        let set = try buildPack(at: dir, policy: .denyByDefault)
        let write = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("guarded.txt"),
                "content": .string("mutated"),
            ])
        )
        guard case .failure(let error) = write else {
            Issue.record("expected permission denial")
            return
        }
        #expect(error.kind == .permissionDenied)
        #expect(try String(contentsOf: file, encoding: .utf8) == "untouched\n")

        let read = await set.prepareAndCall(
            clientName: "read_file",
            args: .object(["target_file": .string("guarded.txt")])
        )
        _ = try success(read)
    }

    @Test("headless prompt policy denies edits without dispatching")
    func headlessPromptDeniesEdits() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildPack(at: dir, policy: .prompt(HeadlessPermissionPrompter()))
        let result = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("blocked.txt"),
                "content": .string("nope"),
            ])
        )
        #expect(fails(result))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("blocked.txt").path))
    }

    @Test("plan mode blocks edits to files other than the plan file")
    func planModeGatesEdits() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var plan = PlanModeTracker(sessionDirectory: dir.path)
        plan.enter(planFilePath: "plan.md", sessionDirectory: dir.path)
        let resources = FileToolSession.makeResources(
            workspaceRoot: dir.path,
            sessionId: "plan-test",
            policy: .allowAll,
            planMode: plan
        )
        let set = try FileToolPack.finalizeBuildPack(resources: resources)
        let blocked = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("code.swift"),
                "content": .string("nope"),
            ])
        )
        #expect(fails(blocked))
        let allowed = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("plan.md"),
                "content": .string("# plan\n"),
            ])
        )
        _ = try success(allowed)
    }
}

// MARK: - Helpers

private func success(
    _ result: Result<TypedToolOutput, ToolError>
) throws -> TypedToolOutput {
    switch result {
    case .success(let t): return t
    case .failure(let e): throw e
    }
}

private func fails(_ result: Result<TypedToolOutput, ToolError>) -> Bool {
    if case .failure = result { return true }
    return false
}
