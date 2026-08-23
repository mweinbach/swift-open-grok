import Foundation
import OpenGrokFastWorktree
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import Testing

@testable import OpenGrokCLI

private struct LiveSessionGitFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-session-git-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func initializeRepository(committed: Bool = true) throws {
        let hooks = root.appendingPathComponent("isolated-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--initial-branch=main"],
            ["config", "user.name", "Session Git Parity"],
            ["config", "user.email", "session-git@example.test"],
            ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", hooks.path],
        ] {
            try git(arguments)
        }
        guard committed else { return }
        try "session metadata\n".write(
            to: workspace.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "tracked.txt"])
        try git(["commit", "-m", "Initialize durable session Git identity"])
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let result = try runGit(arguments, cwd: directory ?? workspace)
        guard result.exitCode == 0 else {
            throw NSError(domain: "LiveSessionGit", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: result.stderr,
            ])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func save(_ sessionID: String, cwd: URL? = nil) async throws -> LiveConversationRecord {
        let directory = cwd ?? workspace
        let store = LiveConversationStore(openGrokHome: home)
        try await store.save(LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: directory
        ))
        return try await store.load(sessionID: sessionID)
    }

    func summary(_ sessionID: String, cwd: URL? = nil) throws -> [String: Any] {
        let directory = try SessionDocumentStore(grokHome: home).sessionDirectory(
            sessionID: sessionID,
            cwd: (cwd ?? workspace).path
        )
        let data = try Data(contentsOf: directory.appendingPathComponent("summary.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LiveSessionGit", code: 1)
        }
        return object
    }

    func compatibility(_ sessionID: String) throws -> [String: Any] {
        let file = home.appendingPathComponent("sessions")
            .appendingPathComponent("\(sessionID).json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any]
        else {
            throw NSError(domain: "LiveSessionGit", code: 2)
        }
        return object
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct LiveSessionGitProviderFactory: OpenGrokShellProviderFactory {
    func makeSession(
        for request: OpenGrokShellSessionRequest
    ) throws -> any OpenGrokShellProviderSession {
        LiveSessionGitProvider(sessionID: request.sessionID.rawValue)
    }
}

private struct LiveSessionGitProvider: OpenGrokShellProviderSession {
    let sessionID: String

    func snapshot() async -> OpenGrokShellProviderSessionSnapshot {
        OpenGrokShellProviderSessionSnapshot(
            sessionID: sessionID,
            modelID: "session-git-model",
            provider: "xai",
            generation: 0
        )
    }

    func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext {
        OpenGrokShellProviderTurnContext(
            sessionID: sessionID,
            turnID: turnID,
            modelID: "session-git-model",
            attempt: 0
        )
    }

    func finishTurn(turnID: String) async throws {}
    func failTurn(turnID: String) async {}
    func cancelTurn(turnID: String) async throws {}
}

private struct LiveSessionGitTurnDriver: OpenGrokShellTurnDriver {
    func submit(
        providerSession: any OpenGrokShellProviderSession,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellTurnResult {
        throw OpenGrokShellError.invalidTurnRequest("Git persistence fixture never samples")
    }

    func cancel(
        providerSession: any OpenGrokShellProviderSession,
        turnID: String
    ) async throws {}
}

@Suite("Live durable session Git metadata parity", .serialized)
struct LiveSessionGitMetadataParityTests {
    @Test("actual summaries and compatibility mirrors publish credential-free refs once")
    func genuineSessionsPublishAndPreserveGitIdentity() async throws {
        let fixture = try LiveSessionGitFixture()
        defer { fixture.dispose() }
        try fixture.initializeRepository()
        try fixture.git([
            "remote", "add", "origin",
            "https://username:never-persist-this-token@git.example.test/team/project.git",
        ])
        try fixture.git([
            "remote", "add", "duplicate",
            "https://git.example.test/team/project.git",
        ])
        let expectedCommit = try fixture.git(["rev-parse", "HEAD"])
        let original = try await fixture.save("real-git-session")

        let summary = try fixture.summary(original.sessionID)
        let compatibility = try fixture.compatibility(original.sessionID)
        let expectedRemote = "https://git.example.test/team/project.git"
        for object in [summary, compatibility] {
            #expect(object["git_root_dir"] as? String == fixture.workspace.path)
            #expect(object["git_remotes"] as? [String] == [expectedRemote])
            #expect(object["head_commit"] as? String == expectedCommit)
            #expect(object["head_branch"] as? String == "main")
            let encoded = try JSONSerialization.data(withJSONObject: object)
            #expect(String(decoding: encoded, as: UTF8.self)
                .contains("never-persist-this-token") == false)
        }
        #expect(original.gitRootDirectory == fixture.workspace.path)
        #expect(original.gitRemotes == [expectedRemote])
        #expect(original.headCommit == expectedCommit)
        #expect(original.headBranch == "main")

        try fixture.git(["checkout", "-b", "changed-after-creation"])
        var forged = original
        forged.gitRootDirectory = fixture.root.appendingPathComponent("outside").path
        forged.gitRemotes = ["https://attacker:secret@invalid.example/forged"]
        forged.headCommit = String(repeating: "f", count: 40)
        forged.headBranch = "../../outside"
        let restarted = LiveConversationStore(openGrokHome: fixture.home)
        try await restarted.save(forged)
        let restored = try await restarted.load(sessionID: original.sessionID)
        #expect(restored.gitRootDirectory == original.gitRootDirectory)
        #expect(restored.gitRemotes == original.gitRemotes)
        #expect(restored.headCommit == expectedCommit)
        #expect(restored.headBranch == "main")
        let preserved = try fixture.summary(original.sessionID)
        #expect(preserved["head_branch"] as? String == "main")
    }

    @Test("non-repositories omit every field and unborn branches publish only root/remotes")
    func absentAndUnbornHeadsFollowRustOptionalEncoding() async throws {
        let fixture = try LiveSessionGitFixture()
        defer { fixture.dispose() }
        let outside = try await fixture.save("not-a-git-repository")
        let outsideSummary = try fixture.summary(outside.sessionID)
        let outsideCompatibility = try fixture.compatibility(outside.sessionID)
        for key in ["git_root_dir", "git_remotes", "head_commit", "head_branch"] {
            #expect(outsideSummary[key] == nil)
            #expect(outsideCompatibility[key] == nil)
        }
        #expect(outside.gitRemotes.isEmpty)

        try fixture.initializeRepository(committed: false)
        try fixture.git(["remote", "add", "origin", "https://git.example.test/unborn.git"])
        let unborn = try await fixture.save("unborn-git-repository")
        let unbornSummary = try fixture.summary(unborn.sessionID)
        let unbornCompatibility = try fixture.compatibility(unborn.sessionID)
        for object in [unbornSummary, unbornCompatibility] {
            #expect(object["git_root_dir"] as? String == fixture.workspace.path)
            #expect(object["git_remotes"] as? [String] == ["https://git.example.test/unborn.git"])
            #expect(object["head_commit"] == nil)
            #expect(object["head_branch"] == nil)
        }
        #expect(unborn.headCommit == nil)
        #expect(unborn.headBranch == nil)
    }

    @Test("loose and packed HEAD refs persist even when neither referenced object exists")
    func missingCommitObjectsNeverEraseAuthenticReferences() async throws {
        let fixture = try LiveSessionGitFixture()
        defer { fixture.dispose() }
        try fixture.initializeRepository(committed: false)
        let gitDirectory = fixture.workspace.appendingPathComponent(".git", isDirectory: true)
        let looseRef = gitDirectory.appendingPathComponent("refs/heads/main")
        try FileManager.default.createDirectory(
            at: looseRef.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let missingLooseObject = String(repeating: "ab", count: 20)
        try "\(missingLooseObject)\n".write(to: looseRef, atomically: true, encoding: .utf8)

        let loose = try await fixture.save("missing-loose-object")
        let looseSummary = try fixture.summary(loose.sessionID)
        #expect(loose.headCommit == missingLooseObject)
        #expect(loose.headBranch == "main")
        #expect(looseSummary["head_commit"] as? String == missingLooseObject)
        #expect(FileManager.default.fileExists(atPath: gitDirectory
            .appendingPathComponent("objects/ab/\(String(missingLooseObject.dropFirst(2)))").path)
            == false)

        try FileManager.default.removeItem(at: looseRef)
        let missingPackedObject = String(repeating: "cd", count: 20)
        try "# pack-refs with: sorted\n\(missingPackedObject) refs/heads/main\n".write(
            to: gitDirectory.appendingPathComponent("packed-refs"),
            atomically: true,
            encoding: .utf8
        )
        let packed = try await fixture.save("missing-packed-object")
        let packedSummary = try fixture.summary(packed.sessionID)
        #expect(packed.headCommit == missingPackedObject)
        #expect(packed.headBranch == "main")
        #expect(packedSummary["head_commit"] as? String == missingPackedObject)
    }

    @Test("detached HEAD publishes its advertised OID without a branch or commit object")
    func detachedHeadNeverInventsBranchOrLoadsObjects() async throws {
        let fixture = try LiveSessionGitFixture()
        defer { fixture.dispose() }
        try fixture.initializeRepository(committed: false)
        let missingDetachedObject = String(repeating: "de", count: 20)
        try "\(missingDetachedObject)\n".write(
            to: fixture.workspace.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let detached = try await fixture.save("missing-detached-object")
        let summary = try fixture.summary(detached.sessionID)
        #expect(detached.headCommit == missingDetachedObject)
        #expect(detached.headBranch == nil)
        #expect(summary["head_commit"] as? String == missingDetachedObject)
        #expect(summary["head_branch"] == nil)
    }

    @Test("hostile traversal and redirected refs never become durable session identity")
    func hostileGitReferencesFailClosedBeforePersistence() async throws {
        let fixture = try LiveSessionGitFixture()
        defer { fixture.dispose() }
        try fixture.initializeRepository(committed: false)
        let gitDirectory = fixture.workspace.appendingPathComponent(".git", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside-ref")
        try "\(String(repeating: "ef", count: 20))\n".write(
            to: outside,
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/../../outside-ref\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let traversal = try await fixture.save("hostile-traversal-ref")
        let traversalSummary = try fixture.summary(traversal.sessionID)
        #expect(traversal.gitRootDirectory == fixture.workspace.path)
        #expect(traversal.headCommit == nil)
        #expect(traversal.headBranch == nil)
        #expect(traversalSummary["head_commit"] == nil)
        #expect(traversalSummary["head_branch"] == nil)

        #if !os(Windows)
        let redirected = gitDirectory.appendingPathComponent("refs/heads/redirected")
        try FileManager.default.createDirectory(
            at: redirected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: outside)
        try "ref: refs/heads/redirected\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let symlink = try await fixture.save("hostile-symlink-ref")
        let symlinkSummary = try fixture.summary(symlink.sessionID)
        #expect(symlink.headCommit == nil)
        #expect(symlink.headBranch == nil)
        #expect(symlinkSummary["head_commit"] == nil)
        #expect(symlinkSummary["head_branch"] == nil)
        #endif
    }

    @Test("worktree forks publish child-bound metadata first and retain their durable directive")
    func forkedWorktreeNeverInheritsTheParentWorkspaceIdentity() async throws {
        let fixture = try LiveSessionGitFixture()
        defer { fixture.dispose() }
        try fixture.initializeRepository()
        try fixture.git(["remote", "add", "origin", "https://git.example.test/team/project.git"])
        let parent = try await fixture.save("git-parent-session")
        let childWorkspace = fixture.root.appendingPathComponent("child-worktree", isDirectory: true)
        try fixture.git(["worktree", "add", "-b", "child-branch", childWorkspace.path, "HEAD"])
        let store = LiveConversationStore(openGrokHome: fixture.home)
        let directive = "inspect the linked checkout without touching its parent"

        let child = try await store.fork(
            sourceSessionID: parent.sessionID,
            destinationSessionID: "git-worktree-child",
            workingDirectory: childWorkspace,
            pendingFirstPrompt: directive
        )

        let childSummary = try fixture.summary(child.sessionID, cwd: childWorkspace)
        let childMirror = try fixture.compatibility(child.sessionID)
        for object in [childSummary, childMirror] {
            #expect(object["git_root_dir"] as? String == childWorkspace.path)
            #expect(object["head_commit"] as? String == parent.headCommit)
            #expect(object["head_branch"] as? String == "child-branch")
            #expect(object["git_remotes"] as? [String] == parent.gitRemotes)
        }
        #expect(child.gitRootDirectory == childWorkspace.path)
        #expect(child.headBranch == "child-branch")
        #expect(child.pendingFirstPrompt?.directive == directive)
        #expect(child.pendingFirstPrompt?.workingDirectory == childWorkspace.path)
        let parentAfter = try await store.load(sessionID: parent.sessionID)
        #expect(parentAfter == parent)

        let outside = fixture.root.appendingPathComponent("outside-git", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let nonGitChild = try await store.fork(
            sourceSessionID: parent.sessionID,
            destinationSessionID: "non-git-child",
            workingDirectory: outside
        )
        let outsideSummary = try fixture.summary(nonGitChild.sessionID, cwd: outside)
        for key in ["git_root_dir", "git_remotes", "head_commit", "head_branch"] {
            #expect(outsideSummary[key] == nil)
        }
        #expect(nonGitChild.gitRootDirectory == nil)
        #expect(nonGitChild.headCommit == nil)
    }

    @Test("real shell creation persists refs and process restart preserves the original snapshot")
    func liveShellCreationAndRestartShareTheAuthenticSessionIdentity() async throws {
        let fixture = try LiveSessionGitFixture()
        defer { fixture.dispose() }
        try fixture.initializeRepository()
        let expectedCommit = try fixture.git(["rev-parse", "HEAD"])
        let sessionID = SessionID("shell-git-session")

        let first = OpenGrokShell(configuration: OpenGrokShellConfiguration(
            openGrokHome: fixture.home,
            processBackend: LocalShellProcessBackend(),
            providerFactory: LiveSessionGitProviderFactory(),
            turnDriver: LiveSessionGitTurnDriver()
        ))
        let started = try await first.start()
        #expect(started.state == .running)
        let created = try await first.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: fixture.workspace
        ))
        #expect(created.sessionID == sessionID)
        let firstState = try #require(try await SessionStateStore(root: fixture.home)
            .load(sessionID: sessionID))
        #expect(firstState.summary.extra["git_root_dir"]?.stringValue == fixture.workspace.path)
        #expect(firstState.summary.extra["head_commit"]?.stringValue == expectedCommit)
        #expect(firstState.summary.extra["head_branch"]?.stringValue == "main")
        let firstShutdown = await first.shutdown(timeout: ShellDuration(timeInterval: 2))
        #expect(firstShutdown.state == .closed)

        let liveStore = LiveConversationStore(openGrokHome: fixture.home)
        let migrated = try await liveStore.load(sessionID: sessionID.rawValue)
        #expect(migrated.headCommit == expectedCommit)
        try fixture.git(["checkout", "-b", "changed-before-resume"])

        let restarted = OpenGrokShell(configuration: OpenGrokShellConfiguration(
            openGrokHome: fixture.home,
            processBackend: LocalShellProcessBackend(),
            providerFactory: LiveSessionGitProviderFactory(),
            turnDriver: LiveSessionGitTurnDriver()
        ))
        let restartedState = try await restarted.start()
        #expect(restartedState.state == .running)
        let restored = try await restarted.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: fixture.workspace,
            restorePersistedState: true
        ))
        #expect(restored.sessionID == sessionID)
        let durable = try #require(try await SessionStateStore(root: fixture.home)
            .load(sessionID: sessionID))
        #expect(durable.summary.extra["head_commit"]?.stringValue == expectedCommit)
        #expect(durable.summary.extra["head_branch"]?.stringValue == "main")
        let restartedShutdown = await restarted.shutdown(timeout: ShellDuration(timeInterval: 2))
        #expect(restartedShutdown.state == .closed)
    }
}
