import Foundation
import OpenGrokConfig
import OpenGrokFastWorktree
import OpenGrokSessionPersistence
import Testing

@testable import OpenGrokCLI

@Suite("Live --restore-code local Git checkout parity")
struct LiveRestoreCodeLaunchParityTests {
    @Test("the actual launcher restores the exact persisted local commit")
    func launcherRestoresPersistedCommit() async throws {
        let fixture = try LiveRestoreCodeFixture()
        defer { fixture.dispose() }
        let original = try await fixture.saveSession()
        let expected = try #require(original.headCommit)
        let newer = try fixture.advanceCommit()
        #expect(newer != expected)

        try await fixture.launch(sessionID: original.sessionID)

        #expect(try fixture.git(["rev-parse", "HEAD"]) == expected)
        #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
        let persisted = try #require(try SessionDocumentStore(grokHome: fixture.home).load(
            sessionID: original.sessionID,
            cwd: fixture.repository.path
        ))
        #expect(persisted.summary.extra["head_commit"]?.stringValue == expected)
    }

    @Test("dirty tracked and untracked files survive in the exact upstream stash")
    func launcherPreservesDirtyTrackedAndUntrackedFiles() async throws {
        let fixture = try LiveRestoreCodeFixture()
        defer { fixture.dispose() }
        let original = try await fixture.saveSession()
        let expected = try #require(original.headCommit)
        try fixture.advanceCommit()
        try "tracked local changes\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "untracked local changes\n".write(
            to: fixture.repository.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await fixture.launch(sessionID: original.sessionID)

        #expect(try fixture.git(["rev-parse", "HEAD"]) == expected)
        let message = try fixture.git(["log", "-1", "--format=%s", "stash@{0}"])
        #expect(message.hasPrefix("On main: grok: pre-restore-code \(original.sessionID) "))
        let preserved = try fixture.git([
            "stash", "show", "--include-untracked", "--name-only", "stash@{0}",
        ])
        #expect(preserved.contains("tracked.txt"))
        #expect(preserved.contains("untracked.txt"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.repository.appendingPathComponent("untracked.txt").path
        ))
    }

    @Test("managed worktree restoration never changes its dirty source and persists child identity")
    func managedWorktreeRestoresWithoutTouchingSource() async throws {
        let fixture = try LiveRestoreCodeFixture()
        defer { fixture.dispose() }
        let original = try await fixture.saveSession()
        let target = try #require(original.headCommit)
        let sourceHead = try fixture.advanceCommit()
        let sourceTracked = fixture.repository.appendingPathComponent("tracked.txt")
        let sourceUntracked = fixture.repository.appendingPathComponent("source-only.txt")
        try "keep source checkout dirty\n".write(to: sourceTracked, atomically: true, encoding: .utf8)
        try "preserve the source too\n".write(to: sourceUntracked, atomically: true, encoding: .utf8)

        try await fixture.launch(
            sessionID: original.sessionID,
            arguments: ["--worktree", "restored"]
        )

        let registration = try #require(try WorktreeRegistry(openGrokHome: fixture.home).records().first)
        let childSessionID = try #require(registration.sessionID)
        #expect(childSessionID != original.sessionID)
        #expect(try fixture.git(["rev-parse", "HEAD"]) == sourceHead)
        #expect(try String(contentsOf: sourceTracked, encoding: .utf8) == "keep source checkout dirty\n")
        #expect(FileManager.default.fileExists(atPath: sourceUntracked.path))
        #expect(try fixture.git(["rev-parse", "HEAD"], at: registration.url) == target)

        let parent = try await LiveConversationStore(openGrokHome: fixture.home)
            .load(sessionID: original.sessionID)
        let child = try await LiveConversationStore(openGrokHome: fixture.home)
            .load(sessionID: childSessionID)
        #expect(parent.headCommit == target)
        #expect(child.headCommit == target)
        #expect(child.workingDirectory == registration.path)
        let canonical = try #require(try SessionDocumentStore(grokHome: fixture.home).load(
            sessionID: childSessionID,
            cwd: registration.path
        ))
        #expect(canonical.summary.extra["head_commit"]?.stringValue == target)
        let mirrorURL = fixture.home.appendingPathComponent("sessions")
            .appendingPathComponent("\(childSessionID).json")
        let mirror = try JSONDecoder().decode(LiveConversationRecord.self, from: Data(contentsOf: mirrorURL))
        #expect(mirror.headCommit == target)
    }

    @Test("malformed or unavailable commits and foreign checkouts fail before mutation")
    func hostileTargetsFailClosed() async throws {
        let fixture = try LiveRestoreCodeFixture()
        defer { fixture.dispose() }
        let original = try await fixture.saveSession()
        let current = try fixture.advanceCommit()
        let options = CLIExecutionOptions(resume: original.sessionID, restoreCode: true)
        let source = try #require(try await LiveRestoreCodeLaunch.capture(
            options: options,
            workingDirectory: fixture.repository,
            openGrokHome: fixture.home
        ))

        for invalid in ["--upload-pack=unsafe", String(repeating: "a", count: 39)] {
            let malformed = LiveRestoreCodeSource(
                sessionID: source.sessionID,
                persistedWorkingDirectory: source.persistedWorkingDirectory,
                headCommit: invalid
            )
            #expect(throws: CLIApplicationError.self) {
                try LiveRestoreCodeLaunch.restore(
                    options: options,
                    source: malformed,
                    workingDirectory: fixture.repository,
                    preparation: nil,
                    openGrokHome: fixture.home
                )
            }
        }

        let unavailable = LiveRestoreCodeSource(
            sessionID: source.sessionID,
            persistedWorkingDirectory: source.persistedWorkingDirectory,
            headCommit: String(repeating: "a", count: 40)
        )
        do {
            try LiveRestoreCodeLaunch.restore(
                options: options,
                source: unavailable,
                workingDirectory: fixture.repository,
                preparation: nil,
                openGrokHome: fixture.home
            )
            Issue.record("an unavailable object must never fetch or checkout")
        } catch {
            #expect(String(describing: error).contains("automatic network fetching is disabled"))
        }

        #expect(throws: CLIApplicationError.self) {
            try LiveRestoreCodeLaunch.restore(
                options: options,
                source: source,
                workingDirectory: fixture.root,
                preparation: nil,
                openGrokHome: fixture.home
            )
        }
        #expect(try fixture.git(["rev-parse", "HEAD"]) == current)
    }

    @Test("an in-progress merge refuses restoration before stashing dirty files")
    func inProgressGitOperationFailsClosed() async throws {
        let fixture = try LiveRestoreCodeFixture()
        defer { fixture.dispose() }
        let original = try await fixture.saveSession()
        let current = try fixture.advanceCommit()
        try "do not stash this\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let marker = fixture.repository.appendingPathComponent(".git/MERGE_HEAD")
        try "\(try #require(original.headCommit))\n".write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )

        do {
            try await fixture.launch(sessionID: original.sessionID)
            Issue.record("an in-progress merge must prevent destructive restoration")
        } catch {
            #expect(String(describing: error).contains("MERGE_HEAD"))
        }

        #expect(try fixture.git(["rev-parse", "HEAD"]) == current)
        #expect(try fixture.git(["stash", "list"]).isEmpty)
        #expect(try String(
            contentsOf: fixture.repository.appendingPathComponent("tracked.txt"),
            encoding: .utf8
        ) == "do not stash this\n")
    }
}

private struct LiveRestoreCodeFixture: Sendable {
    let root: URL
    let home: URL
    let repository: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-restore-code-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        repository = root.appendingPathComponent("repository", isDirectory: true)
        let hooks = root.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        #if os(Windows)
        try createDirAllOwnerOnly(home, stateRoot: home)
        #else
        try createDirAllOwnerOnly(home)
        #endif

        for arguments in [
            ["init", "--initial-branch=main"],
            ["config", "user.name", "Restore Code Parity"],
            ["config", "user.email", "restore-code@example.test"],
            ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", hooks.path],
        ] {
            try git(arguments)
        }
        try "initial persisted checkout\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "tracked.txt"])
        try git(["commit", "--quiet", "-m", "Persist the original session checkout"])
    }

    func saveSession() async throws -> LiveConversationRecord {
        let sessionID = "restore-\(UUID().uuidString)"
        let store = LiveConversationStore(openGrokHome: home)
        try await store.save(LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: repository
        ))
        return try await store.load(sessionID: sessionID)
    }

    @discardableResult
    func advanceCommit() throws -> String {
        try "newer committed checkout\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "tracked.txt"])
        try git(["commit", "--quiet", "-m", "Advance after the saved session"])
        return try git(["rev-parse", "HEAD"])
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let result = try runGit(arguments, cwd: directory ?? repository)
        guard result.exitCode == 0 else {
            throw NSError(domain: "LiveRestoreCodeFixture", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: result.stderr,
            ])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func launch(sessionID: String, arguments: [String] = []) async throws {
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    await emit(.output("restored"))
                    return OpenGrokLiveSamplingResponse(output: "restored", stopReason: "stop")
                }
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "verify restored checkout", "--cwd", repository.path,
            "--resume", sessionID, "--restore-code",
        ] + arguments)
        let (streams, _, _) = CLIStreams.buffered()
        let context = CLIApplicationContext(
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": home.path,
                "GROK_SANDBOX": "off",
                "GROK_WORKTREE_AUTO_GC": "false",
                "XAI_API_KEY": "restore-code-test-key",
            ],
            streams: streams,
            control: .never
        )
        let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
            .launcher.start(command, context)
        do {
            try await session.waitForExit()
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }
}
