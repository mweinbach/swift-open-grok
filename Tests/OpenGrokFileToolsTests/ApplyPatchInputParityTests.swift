import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

@Suite("apply_patch input and empty-patch parity")
struct ApplyPatchInputParityTests {
    @Test("missing and non-string patch arguments are typed failures")
    func missingOrNonStringArgumentsFail() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let invalidArguments: [JSONValue] = [
            .object([:]),
            .object(["input": .null]),
            .object(["input": .number(.int64(3))]),
            .object(["patch": .bool(true)]),
            .array([]),
            .null,
        ]

        for arguments in invalidArguments {
            let result = await ApplyPatchTool.run(args: arguments, resources: fixture.resources)
            guard case .failure(let error) = result else {
                Issue.record("invalid apply_patch input reported success: \(arguments)")
                continue
            }
            #expect(error.kind == .invalidArguments)
            #expect(!error.detail.isEmpty)
            try assertFixtureUnchanged(fixture)
        }
    }

    @Test("missing required patch input fails through the production tool pack")
    func missingInputFailsThroughToolPack() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.pack.prepareAndCall(
            clientName: "apply_patch",
            args: .object([:])
        )

        guard case .failure(let error) = result else {
            Issue.record("production apply_patch pack reported success without input")
            return
        }
        #expect(error.kind == .invalidArguments)
        #expect(error.detail.contains("patch"))
        try assertFixtureUnchanged(fixture)
    }

    @Test("empty and whitespace patch text never reports a successful mutation")
    func emptyAndWhitespacePatchTextFail() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for text in ["", " ", "\t\n", "\r\n\r\n"] {
            let arguments: JSONValue = .object(["input": .string(text)])
            let results = [
                await ApplyPatchTool.run(args: arguments, resources: fixture.resources),
                await fixture.pack.prepareAndCall(clientName: "apply_patch", args: arguments),
            ]

            for result in results {
                guard case .failure(let error) = result else {
                    Issue.record("empty apply_patch text reported success: \(text.debugDescription)")
                    continue
                }
                #expect(error.kind == .invalidArguments)
                #expect(error.detail.contains("Invalid patch:"))
                #expect(error.detail.contains("*** Begin Patch"))
                try assertFixtureUnchanged(fixture)
            }
        }
    }

    @Test("malformed patch boundaries reject the entire patch before writes")
    func malformedPatchBoundariesFailAtomically() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let invalidPatches = [
            "*** End Patch",
            "*** Begin Patch",
            "not a patch\n*** End Patch",
            "*** Begin Patch\n*** Add File: created.txt\n+fresh",
            "*** Begin Patch\n*** Delete File: sentinel.txt\n*** End Patch\ntrailing",
            "*** Begin Patch *** End Patch",
        ]

        for patch in invalidPatches {
            let result = await fixture.pack.prepareAndCall(
                clientName: "apply_patch",
                args: .object(["input": .string(patch)])
            )
            guard case .failure(let error) = result else {
                Issue.record("malformed patch boundary reported success: \(patch)")
                continue
            }
            #expect(error.kind == .invalidArguments)
            #expect(error.detail.contains("Invalid patch:"))
            try assertFixtureUnchanged(fixture)
        }
    }

    @Test("malformed and empty hunks reject all staged changes atomically")
    func malformedHunksFailAtomically() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let invalidPatches = [
            "*** Begin Patch\n*** Update File: sentinel.txt\n*** End Patch",
            "*** Begin Patch\n*** Update File: sentinel.txt\n@@\n*** End Patch",
            "*** Begin Patch\n*** Update File: sentinel.txt\n@@ named context\n*** End Patch",
            "*** Begin Patch\n*** Update File: sentinel.txt\n@@\nraw context\n*** End Patch",
            "*** Begin Patch\n*** Add File: created.txt\n+fresh\nraw content\n*** End Patch",
            "*** Begin Patch\n*** Add File: created.txt\n+fresh\n*** Update File: sentinel.txt\n@@\n*** End Patch",
            "*** Begin Patch\n*** Update File: sentinel.txt\n@@\n*** End of File\n*** End Patch",
        ]

        for patch in invalidPatches {
            let result = await fixture.pack.prepareAndCall(
                clientName: "apply_patch",
                args: .object(["input": .string(patch)])
            )
            guard case .failure(let error) = result else {
                Issue.record("malformed apply_patch hunk reported success: \(patch)")
                continue
            }
            #expect(error.kind == .invalidArguments)
            #expect(error.detail.contains("Invalid patch:"))
            try assertFixtureUnchanged(fixture)
        }
    }

    @Test("marker-only patches return the upstream EmptyPatch output honestly")
    func markerOnlyPatchesReportNoModifiedFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let markerOnlyPatches = [
            "*** Begin Patch\n*** End Patch",
            "*** Begin Patch\r\n*** End Patch",
            " \t*** Begin Patch \r\n *** End Patch \t",
            "<<EOF\n*** Begin Patch\n*** End Patch\nEOF",
            "<<'EOF'\n*** Begin Patch\n*** End Patch\nEOF",
        ]

        for patch in markerOnlyPatches {
            let result = await fixture.pack.prepareAndCall(
                clientName: "apply_patch",
                args: .object(["input": .string(patch)])
            )
            guard case .success(let output) = result,
                  case .object(let payload) = output.value
            else {
                Issue.record("valid marker-only patch did not return EmptyPatch: \(patch)")
                continue
            }

            #expect(payload["type"] == .string("apply_patch"))
            #expect(payload["EmptyPatch"] == .string("No files were modified."))
            #expect(payload["content"] == .string("No files were modified."))
            #expect(payload["files"] == .array([]))
            #expect(payload["file_results"] == .array([]))
            #expect(payload["lines_added"] == .number(.int64(0)))
            #expect(payload["lines_removed"] == .number(.int64(0)))
            #expect(payload["trusted"] == .bool(false))
            #expect(output.modelOutput == [.text(text: "No files were modified.")])
            try assertFixtureUnchanged(fixture)
        }
    }

    @Test("canonical and legacy arguments retain the real mutation permission gate")
    func argumentAliasesCannotBypassMutationPermissions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let deniedResources = FileToolSession.makeResources(
            workspaceRoot: fixture.root.path,
            sessionId: "apply-patch-denied-parity",
            policy: .denyMutations
        )
        let deniedPack = try FileToolPack.finalizeBuildPack(resources: deniedResources)
        let patch = "*** Begin Patch\n*** Add File: created.txt\n+fresh\n*** End Patch"

        for arguments in [
            JSONValue.object(["patch": .string(patch)]),
            JSONValue.object(["input": .string(patch)]),
        ] {
            let result = await deniedPack.prepareAndCall(
                clientName: "apply_patch",
                args: arguments
            )
            guard case .failure(let error) = result else {
                Issue.record("apply_patch alias bypassed the mutation permission gate")
                continue
            }
            #expect(error.kind == .permissionDenied)
            try assertFixtureUnchanged(fixture)
        }
    }

    @Test("conflicting canonical and legacy aliases fail before any mutation")
    func conflictingAliasesFailAtomically() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let canonical = "*** Begin Patch\n*** Add File: created.txt\n+fresh\n*** End Patch"
        let conflict = "*** Begin Patch\n*** Delete File: sentinel.txt\n*** End Patch"
        let arguments: JSONValue = .object([
            "patch": .string(canonical),
            "input": .string(conflict),
        ])
        let results = [
            await ApplyPatchTool.run(args: arguments, resources: fixture.resources),
            await fixture.pack.prepareAndCall(clientName: "apply_patch", args: arguments),
        ]

        for result in results {
            guard case .failure(let error) = result else {
                Issue.record("conflicting apply_patch aliases reported success")
                continue
            }
            #expect(error.kind == .invalidArguments)
            #expect(error.detail.contains("conflicting"))
            try assertFixtureUnchanged(fixture)
        }
    }

    @Test("supported direct patch argument aliases still apply legitimate edits")
    func supportedPatchAliasesRemainFunctional() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for (index, key) in ["input", "patch", "apply_patch"].enumerated() {
            let name = "created-\(index).txt"
            let patch = "*** Begin Patch\n*** Add File: \(name)\n+fresh\n*** End Patch"
            let result = await ApplyPatchTool.run(
                args: .object([key: .string(patch)]),
                resources: fixture.resources
            )
            guard case .success(let output) = result,
                  case .object(let payload) = output.value
            else {
                Issue.record("valid apply_patch alias failed: \(key)")
                continue
            }
            #expect(payload["EmptyPatch"] == nil)
            #expect(
                try String(contentsOf: fixture.root.appendingPathComponent(name), encoding: .utf8)
                    == "fresh\n"
            )
        }

        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent("sentinel.txt"), encoding: .utf8)
                == "untouched\n"
        )
    }

    private struct Fixture {
        var root: URL
        var resources: ToolResources
        var pack: FinalizedToolset
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-apply-patch-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "untouched\n".write(
            to: root.appendingPathComponent("sentinel.txt"),
            atomically: true,
            encoding: .utf8
        )
        let resources = FileToolSession.makeResources(
            workspaceRoot: root.path,
            sessionId: "apply-patch-input-parity",
            policy: .allowAll
        )
        return Fixture(
            root: root,
            resources: resources,
            pack: try FileToolPack.finalizeBuildPack(resources: resources)
        )
    }

    private func assertFixtureUnchanged(_ fixture: Fixture) throws {
        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent("sentinel.txt"), encoding: .utf8)
                == "untouched\n"
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["sentinel.txt"])
    }
}
