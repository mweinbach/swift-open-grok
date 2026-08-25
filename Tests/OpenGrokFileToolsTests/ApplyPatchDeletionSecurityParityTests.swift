import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokHunkTracker
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

@Suite("apply_patch deletion security and move attribution parity")
struct ApplyPatchDeletionSecurityParityTests {
    @Test("successful direct deletion records its original content and agent attribution")
    func directDeletionRecordsAttribution() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try write("original\n", relativeTo: fixture.root, path: "source.txt")

        let result = await call(deletionPatch("source.txt"), fixture: fixture)
        guard case .success = result else {
            Issue.record("authorized direct deletion failed: \(result)")
            return
        }

        #expect(!FileManager.default.fileExists(atPath: source.path))
        let snapshot = await fixture.tracker.snapshotState()
        let state = try #require(snapshot.fileStates[source.path])
        #expect(state.baseline == .full("original\n"))
        #expect(state.currentContent == .full(""))
        #expect(state.isAgentFile)
        #expect(state.hunks.allSatisfy { $0.source.isAgentEdit })
        #expect(!state.hunks.isEmpty)
    }

    @Test("successful moves attribute both the destination write and source deletion")
    func successfulMoveRecordsBothPaths() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try write("original\n", relativeTo: fixture.root, path: "source.txt")
        let destination = fixture.root.appendingPathComponent("nested/destination.txt")

        let result = await call(movePatch("source.txt", to: "nested/destination.txt"), fixture: fixture)
        guard case .success = result else {
            Issue.record("authorized move failed: \(result)")
            return
        }

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "updated\n")
        let snapshot = await fixture.tracker.snapshotState()
        let sourceState = try #require(snapshot.fileStates[source.path])
        let destinationState = try #require(snapshot.fileStates[destination.path])
        #expect(sourceState.baseline == .full("original\n"))
        #expect(sourceState.currentContent == .full(""))
        #expect(destinationState.currentContent == .full("updated\n"))
        #expect(sourceState.hunks.allSatisfy { $0.source.agentId == "deletion-agent" })
        #expect(destinationState.hunks.allSatisfy { $0.source.agentId == "deletion-agent" })
        #expect(!sourceState.hunks.isEmpty)
        #expect(!destinationState.hunks.isEmpty)
    }

    @Test("parent replacement after descriptor pinning cannot delete an outside sentinel")
    func directDeletionRejectsParentSwap() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parent = fixture.root.appendingPathComponent("contained", isDirectory: true)
        _ = try write("original\n", relativeTo: fixture.root, path: "contained/sentinel.txt")
        let outside = try write("outside survives\n", relativeTo: fixture.outside, path: "sentinel.txt")
        let displaced = fixture.root.appendingPathComponent("displaced", isDirectory: true)

        fixture.resources.extras.insert(ApplyPatchTool.MutationInterlock { checkpoint, _ in
            guard case .beforeSourceDeletion = checkpoint else { return }
            try FileManager.default.moveItem(at: parent, to: displaced)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.outside)
        })

        let result = await call(deletionPatch("contained/sentinel.txt"), fixture: fixture)
        guard case .failure(let error) = result else {
            Issue.record("parent symlink replacement reported a successful deletion")
            return
        }

        #expect(!error.detail.isEmpty)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside survives\n")
        #expect(FileManager.default.fileExists(atPath: displaced.appendingPathComponent("sentinel.txt").path))
        #expect(await fixture.tracker.snapshotState().fileStates.isEmpty)
    }

    @Test("move parent replacement preserves the outside file and rolls back its destination")
    func moveRejectsParentSwapAndRollsBackDestination() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parent = fixture.root.appendingPathComponent("contained", isDirectory: true)
        _ = try write("original\n", relativeTo: fixture.root, path: "contained/sentinel.txt")
        let outside = try write("outside survives\n", relativeTo: fixture.outside, path: "sentinel.txt")
        let displaced = fixture.root.appendingPathComponent("displaced", isDirectory: true)
        let destination = fixture.root.appendingPathComponent("destination.txt")

        fixture.resources.extras.insert(ApplyPatchTool.MutationInterlock { checkpoint, _ in
            guard case .beforeSourceDeletion = checkpoint else { return }
            try FileManager.default.moveItem(at: parent, to: displaced)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.outside)
        })

        let result = await call(movePatch("contained/sentinel.txt", to: "destination.txt"), fixture: fixture)
        guard case .failure(let error) = result else {
            Issue.record("move through a replaced parent reported success")
            return
        }

        #expect(error.kind == .execution)
        #expect(error.detail.contains("Failed to delete move source"))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside survives\n")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(await fixture.tracker.snapshotState().fileStates.isEmpty)
    }

    @Test("a symlinked parent is rejected even when it points inside the authorized root")
    func internalSymlinkedParentIsRejected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try write("original\n", relativeTo: fixture.root, path: "real/source.txt")
        let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture.root.appendingPathComponent("real", isDirectory: true)
        )

        let result = await call(deletionPatch("alias/source.txt"), fixture: fixture)
        guard case .failure(let error) = result else {
            Issue.record("symlinked parent bypassed descriptor-relative deletion")
            return
        }

        #expect(!error.detail.isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == "original\n")
        #expect(await fixture.tracker.snapshotState().fileStates.isEmpty)
    }

    @Test("a source removed after the destination write fails and rolls the new destination back")
    func missingMoveSourceFailsAndRollsBack() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try write("original\n", relativeTo: fixture.root, path: "source.txt")
        let destination = fixture.root.appendingPathComponent("destination.txt")

        fixture.resources.extras.insert(ApplyPatchTool.MutationInterlock { checkpoint, _ in
            guard case .beforeSourceDeletion = checkpoint else { return }
            try FileManager.default.removeItem(at: source)
        })

        let result = await call(movePatch("source.txt", to: "destination.txt"), fixture: fixture)
        guard case .failure(let error) = result else {
            Issue.record("missing move source was reported as a successful move")
            return
        }

        #expect(error.kind == .execution)
        #expect(error.detail.contains("source.txt"))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(await fixture.tracker.snapshotState().fileStates.isEmpty)
    }

    #if !os(Windows)
    @Test("source deletion permission errors restore an overwritten destination and remain visible")
    func deniedMoveSourceRestoresExistingDestination() async throws {
        let fixture = try makeFixture()
        let parent = fixture.root.appendingPathComponent("protected", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let source = try write("original\n", relativeTo: fixture.root, path: "protected/source.txt")
        let destination = try write("preexisting\n", relativeTo: fixture.root, path: "destination.txt")

        fixture.resources.extras.insert(ApplyPatchTool.MutationInterlock { checkpoint, _ in
            guard case .beforeSourceDeletion = checkpoint else { return }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        })

        let result = await call(movePatch("protected/source.txt", to: "destination.txt"), fixture: fixture)
        guard case .failure(let error) = result else {
            Issue.record("denied source deletion was reported as a successful move")
            return
        }

        #expect(error.kind == .execution)
        #expect(error.detail.localizedCaseInsensitiveContains("permission denied"))
        #expect(try String(contentsOf: source, encoding: .utf8) == "original\n")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "preexisting\n")
        #expect(await fixture.tracker.snapshotState().fileStates.isEmpty)
    }
    #endif

    @Test("source replacement after the asynchronous lock wait is rejected")
    func replacedSourceAfterLockIsRejected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try write("original\n", relativeTo: fixture.root, path: "source.txt")

        fixture.resources.extras.insert(ApplyPatchTool.MutationInterlock { checkpoint, _ in
            guard case .acquiredLock = checkpoint else { return }
            try "replacement\n".write(to: source, atomically: true, encoding: .utf8)
        })

        let result = await call(deletionPatch("source.txt"), fixture: fixture)
        guard case .failure(let error) = result else {
            Issue.record("source changed after authorization was silently deleted")
            return
        }

        #expect(error.kind == .execution)
        #expect(error.detail.contains("changed after it was read"))
        #expect(try String(contentsOf: source, encoding: .utf8) == "replacement\n")
        #expect(await fixture.tracker.snapshotState().fileStates.isEmpty)
    }

    private struct Fixture {
        let directory: URL
        let root: URL
        let outside: URL
        let resources: ToolResources
        let tracker: HunkTrackerActor
        let pack: FinalizedToolset
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-patch-delete-security-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("workspace", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let tracker = HunkTrackerActor(sessionId: "patch-delete-security", workingDir: root.path)
        let resources = FileToolSession.makeResources(
            workspaceRoot: root.path,
            sessionId: "patch-delete-security",
            agentId: "deletion-agent",
            policy: .allowAll,
            hunkTracker: tracker,
            promptIndex: 9
        )
        return Fixture(
            directory: directory,
            root: root,
            outside: outside,
            resources: resources,
            tracker: tracker,
            pack: try FileToolPack.finalizeBuildPack(resources: resources)
        )
    }

    @discardableResult
    private func write(_ content: String, relativeTo root: URL, path: String) throws -> URL {
        let destination = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    private func deletionPatch(_ source: String) -> String {
        "*** Begin Patch\n*** Delete File: \(source)\n*** End Patch"
    }

    private func movePatch(_ source: String, to destination: String) -> String {
        "*** Begin Patch\n*** Update File: \(source)\n*** Move to: \(destination)\n"
            + "@@\n-original\n+updated\n*** End Patch"
    }

    private func call(
        _ patch: String,
        fixture: Fixture
    ) async -> Result<TypedToolOutput, ToolError> {
        await fixture.pack.prepareAndCall(
            clientName: "apply_patch",
            args: .object(["input": .string(patch)])
        )
    }
}
