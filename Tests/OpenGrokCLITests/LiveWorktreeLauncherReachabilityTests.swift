import Foundation
import OpenGrokFastWorktree
@testable import OpenGrokGitStatus
import Testing
@testable import OpenGrokCLI

@Suite("worktree route is reachable from the launcher")
struct LiveWorktreeLauncherReachabilityTests {
    @Test("worktree list reaches the live registry and renders JSON")
    func listReachesLiveRoute() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("state", isDirectory: true)
        let source = root.appendingPathComponent("repo", isDirectory: true)
        let registry = WorktreeRegistry(openGrokHome: home)
        let destination = registry.poolRoot.appendingPathComponent("registered", isDirectory: true)
        let report = try WorktreeBuilder(
            source: source,
            dest: destination,
            creationMode: .gitCheckout,
            allowedPoolRoot: registry.poolRoot
        ).create()
        try registry.register(WorktreeRecord(
            path: report.worktreePath,
            sourceRepository: source,
            repositoryName: source.lastPathComponent,
            kind: .manual,
            creationMode: report.creationMode,
            head: report.commit
        ))

        let command = try CLICommandParser.parseOrThrow(["worktree", "list", "--json"])
        let (streams, out, err) = CLIStreams.buffered()
        let context = CLIApplicationContext(
            environment: ["OPENGROK_HOME": home.path],
            streams: streams,
            control: .never
        )
        let session = try await OpenGrokLiveApplicationLauncher().launcher.start(command, context)
        try await session.waitForExit()
        await session.shutdown()

        #expect(out.contents.contains(destination.path.replacingOccurrences(of: "/", with: "\\/")))
        #expect(out.contents.contains("\"type\":\"manual\""))
        #expect(!out.contents.contains("not implemented"))
        #expect(err.contents.isEmpty)
    }

    @Test("worktree launch creates an isolated cwd without changing process cwd")
    func launchCreatesIsolatedWorktree() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("repo", isDirectory: true)
        let home = root.appendingPathComponent("state", isDirectory: true)
        let before = FileManager.default.currentDirectoryPath
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    await emit(.output("ok"))
                    return OpenGrokLiveSamplingResponse(output: "ok", stopReason: "stop")
                }
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "hello", "--cwd", source.path,
            "-w", "isolated", "--ref", "HEAD"
        ])
        let (streams, _, err) = CLIStreams.buffered()
        let context = CLIApplicationContext(
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": home.path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            control: .never
        )
        let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
            .launcher.start(command, context)
        try await session.waitForExit()
        await session.shutdown()

        let records = try WorktreeRegistry(openGrokHome: home).records()
        let record = try #require(records.first)
        let sessionID = try #require(record.sessionID)
        let sessionURL = home.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID)
            .appendingPathExtension("json")
        let data = try Data(contentsOf: sessionURL)
        let persisted = try JSONDecoder().decode(LiveConversationRecord.self, from: data)

        #expect(record.path.hasPrefix(home.appendingPathComponent("worktrees").path))
        #expect(persisted.workingDirectory == record.path)
        #expect(FileManager.default.currentDirectoryPath == before)
        #expect(err.contents.isEmpty)
    }

    @Test("forking and worktree launch is a parser conflict")
    func forkWorktreeConflict() {
        guard case .invalid(let error) = CLICommandParser.parse([
            "headless", "--fork-session", "--worktree"
        ]) else {
            Issue.record("expected --fork-session and --worktree to conflict")
            return
        }
        #expect(error == .conflictingOptions("--fork-session", "--worktree"))
    }

    @Test("worktree action flags are not silently discarded")
    func actionSpecificFlagsAreRejected() {
        guard case .invalid(let error) = CLICommandParser.parse([
            "worktree", "list", "--force"
        ]) else {
            Issue.record("list must reject the rm/gc-only --force flag")
            return
        }
        #expect(error.description.contains("does not accept --force"))
    }

    @Test("live dirty guard reads HEAD from packed Git objects")
    func packedGitDirtyGuard() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("repo", isDirectory: true)
        let destination = root.appendingPathComponent("packed-worktree", isDirectory: true)
        let report = try WorktreeBuilder(
            source: source,
            dest: destination,
            creationMode: .gitCheckout,
            allowedPoolRoot: root
        ).create()
        let packed = try runGit(["gc", "--prune=now"], cwd: source)
        #expect(packed.exitCode == 0)
        let record = WorktreeRecord(
            id: "packed",
            path: report.worktreePath,
            sourceRepository: source,
            repositoryName: "repo",
            kind: .manual,
            creationMode: report.creationMode,
            head: report.commit
        )

        do {
            let (_, gitDir, meta) = try discoverRepository(from: record.path)
            _ = try GitObjectStore(gitDir: resolveCommonGitDir(gitDir: gitDir))
                .loadHeadTree(headCommitHex: meta.headCommit)
            let snapshot = try gitStatus(path: record.path)
            if !snapshot.clean {
                Issue.record("packed Git status entries: \(snapshot.entries)")
            }
            let hasLocalChanges = try LiveWorktreeComposition.hasLocalChanges(record)
            #expect(hasLocalChanges == false)
        } catch {
            Issue.record("packed Git dirty guard failed: \(error)")
            return
        }
        try "changed\n".write(
            to: destination.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try LiveWorktreeComposition.hasLocalChanges(record) == true)
    }

    @Test("missing worktree targets propagate a failure")
    func missingTargetFails() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-worktree-negative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let command = try CLICommandParser.parseOrThrow(["worktree", "show", "missing"])
        let (streams, out, err) = CLIStreams.buffered()
        let context = CLIApplicationContext(
            environment: ["OPENGROK_HOME": home.path],
            streams: streams,
            control: .never
        )

        do {
            _ = try await OpenGrokLiveApplicationLauncher().launcher.start(command, context)
            Issue.record("missing worktree target must fail")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("worktree not found"))
        }
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
    }

    private func makeRepository() throws -> URL {
        // Unique per call: two tests in this suite build repositories in
        // parallel, and a shared literal path made their `git init`s race
        // ("File exists") in any parallel run while the serial gate stayed
        // green.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-worktree-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let result = try runGit(args, cwd: repository)
            guard result.exitCode == 0 else {
                throw NSError(domain: "LiveWorktreeTests", code: Int(result.exitCode), userInfo: [
                    NSLocalizedDescriptionKey: result.stderr
                ])
            }
        }
        try git(["init", "--quiet"])
        try "hello\n".write(
            to: repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "README.md"])
        try git([
            "-c", "user.email=test@example.com", "-c", "user.name=Test",
            "commit", "--quiet", "-m", "initial"
        ])
        return root
    }
}
