import Foundation
import OpenGrokFastWorktree
import OpenGrokFileUtils
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokSubagentResolution
import Testing

@testable import OpenGrokCLI

private struct DurableSubagentMetadataFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let store: LiveSubagentMetadataStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-durable-subagent-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        store = LiveSubagentMetadataStore(
            openGrokHome: home,
            parentSessionID: "durable-parent",
            parentWorkingDirectory: workspace
        )
    }

    func metadata(id: String = "child-one", worktree: URL? = nil) -> LiveSubagentMetadata {
        LiveSubagentMetadata(
            subagentID: id,
            parentSessionID: "durable-parent",
            subagentType: "general-purpose",
            description: "Recover the completed child",
            prompt: "Preserve the actual child execution",
            persona: "careful",
            childCWD: (worktree ?? workspace).path,
            worktreePath: worktree?.path,
            effectiveModelID: "grok-4.5",
            modelRoute: SubagentModelRoute(configuredModelID: "grok-4.5", provider: "xai")
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func git(_ arguments: [String], in directory: URL? = nil) throws {
        let result = try runGit(arguments, cwd: directory ?? workspace)
        guard result.exitCode == 0 else {
            throw NSError(domain: "DurableSubagentGit", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: result.stderr,
            ])
        }
    }
}

@Suite("Durable subagent resume metadata", .serialized)
struct LiveSubagentMetadataParityTests {
    @Test("Rust-compatible metadata is atomic, parent-scoped, and owner-private")
    func exactRustShapeAndPrivateStorage() throws {
        let fixture = try DurableSubagentMetadataFixture()
        defer { fixture.dispose() }
        try fixture.store.save(fixture.metadata())

        let path = try fixture.store.metadataURL(id: "child-one")
        let expectedParent = try SessionDocumentStore(grokHome: fixture.home)
            .sessionDirectory(sessionID: "durable-parent", cwd: fixture.workspace.path)
        #expect(path == expectedParent
            .appendingPathComponent("subagents")
            .appendingPathComponent("child-one")
            .appendingPathComponent("meta.json"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path))
            as? [String: Any])
        #expect(object["subagent_id"] as? String == "child-one")
        #expect(object["parent_session_id"] as? String == "durable-parent")
        #expect(object["child_session_id"] as? String == "child-one")
        #expect(object["effective_model_id"] as? String == "grok-4.5")
        #expect((object["model_route"] as? [String: String])?["provider"] == "xai")
        #expect(try SecureFile.isOwnerOnly(at: path))

        #if !os(Windows)
        for directory in [path.deletingLastPathComponent(),
                          path.deletingLastPathComponent().deletingLastPathComponent()] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        #endif
    }

    @Test("Only terminal completed, failed, or cancelled children resume after a fresh store")
    func terminalStatusesAndRestartRecovery() throws {
        let fixture = try DurableSubagentMetadataFixture()
        defer { fixture.dispose() }

        for (index, status) in [
            LiveSubagentMetadata.Status.completed,
            .failed,
            .cancelled,
        ].enumerated() {
            let id = "child-\(index)"
            try fixture.store.save(fixture.metadata(id: id))
            #expect(try fixture.store.resumeSource(id: id) == nil)
            try fixture.store.updateStatus(
                id: id,
                status: status,
                durationMS: 123,
                toolCalls: 4,
                turns: 2,
                error: status == .completed ? nil : "stopped"
            )
            let recoveredStore = LiveSubagentMetadataStore(
                openGrokHome: fixture.home,
                parentSessionID: "durable-parent",
                parentWorkingDirectory: fixture.workspace
            )
            let source = try #require(try recoveredStore.resumeSource(id: id))
            #expect(source.childSessionID == id)
            #expect(source.persona == "careful")
            #expect(source.modelRoute?.provider == "xai")
            let persisted = try #require(try recoveredStore.load(id: id))
            #expect(persisted.status == status)
            #expect(persisted.durationMS == 123)
            #expect(persisted.toolCalls == 4)
            #expect(persisted.turns == 2)
            #expect(persisted.completedAt != nil)
        }
    }

    @Test("Foreign parents, swapped children, and forged provider routes fail closed")
    func rejectsForgedDurableIdentityAndRoutes() throws {
        let fixture = try DurableSubagentMetadataFixture()
        defer { fixture.dispose() }

        var foreign = fixture.metadata()
        foreign.parentSessionID = "foreign-parent"
        #expect(throws: LiveSubagentMetadataError.self) {
            try fixture.store.save(foreign)
        }

        var swapped = fixture.metadata()
        swapped.childSessionID = "another-child"
        #expect(throws: LiveSubagentMetadataError.self) {
            try fixture.store.save(swapped)
        }

        var forged = fixture.metadata()
        forged.modelRoute = SubagentModelRoute(
            configuredModelID: "a-different-model",
            provider: "xai"
        )
        #expect(throws: LiveSubagentMetadataError.self) {
            try fixture.store.save(forged)
        }

        var unknown = fixture.metadata()
        unknown.modelRoute = SubagentModelRoute(
            configuredModelID: "grok-4.5",
            provider: "invented-provider"
        )
        #expect(throws: LiveSubagentMetadataError.self) {
            try fixture.store.save(unknown)
        }

        try fixture.store.save(fixture.metadata())
        try fixture.store.updateStatus(id: "child-one", status: .completed)
        #expect(throws: LiveSubagentMetadataError.self) {
            _ = try fixture.store.resumeSource(id: "child-one", expectedProvider: .codex)
        }
    }

    @Test("Traversal identifiers and redirected subagent directories never escape the parent")
    func rejectsTraversalAndSymlinkRedirection() throws {
        let fixture = try DurableSubagentMetadataFixture()
        defer { fixture.dispose() }

        for id in ["..", "../outside", "a/b", "a\\b", "", "."] {
            #expect(throws: LiveSubagentMetadataError.self) {
                _ = try fixture.store.metadataURL(id: id)
            }
        }

        #if !os(Windows)
        let parent = try SessionDocumentStore(grokHome: fixture.home)
            .sessionDirectory(sessionID: "durable-parent", cwd: fixture.workspace.path)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("subagents"),
            withDestinationURL: outside
        )
        #expect(throws: LiveSubagentMetadataError.self) {
            try fixture.store.save(fixture.metadata())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #endif
    }

    @Test("A restarted session reuses only the actual preserved linked Git worktree")
    func restartRetainsAndValidatesRealGitWorktree() async throws {
        let fixture = try DurableSubagentMetadataFixture()
        defer { fixture.dispose() }

        try fixture.git(["init"])
        try fixture.git(["config", "user.email", "durable-subagent@example.test"])
        try fixture.git(["config", "user.name", "Durable Subagent"])
        try "parent contents\n".write(
            to: fixture.workspace.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.git(["add", "tracked.txt"])
        try fixture.git(["commit", "-m", "Initialize durable worktree fixture"])

        let worktree = try await LiveSubagentWorktree.prepare(
            sourceDirectory: fixture.workspace,
            openGrokHome: fixture.home,
            childID: "isolated-child"
        )
        try "preserved child edit\n".write(
            to: worktree.path.appendingPathComponent("child.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.store.save(fixture.metadata(id: "isolated-child", worktree: worktree.path))
        try fixture.store.updateStatus(id: "isolated-child", status: .completed)

        let restarted = LiveSubagentMetadataStore(
            openGrokHome: fixture.home,
            parentSessionID: "durable-parent",
            parentWorkingDirectory: fixture.workspace
        )
        let resumed = try #require(try restarted.resumeSource(id: "isolated-child"))
        #expect(resumed.worktreePath == worktree.path.resolvingSymlinksInPath())
        #expect(try String(
            contentsOf: worktree.path.appendingPathComponent("child.txt"),
            encoding: .utf8
        ) == "preserved child edit\n")

        let removed = try worktreeRemove(source: fixture.workspace, dest: worktree.path, force: true)
        #expect(removed.removed)
        #expect(throws: (any Error).self) {
            _ = try restarted.resumeSource(id: "isolated-child")
        }
    }
}
