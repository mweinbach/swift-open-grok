import Foundation
import OpenGrokAgentCoordinator
import OpenGrokFastWorktree
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing

@testable import OpenGrokCLI

private actor WorktreeParityShellBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "", stdout: "", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "background")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        nil
    }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}

private actor WorktreeSamplingBehavior {
    private let performWrite: Bool
    private var roundsBySession: [String: Int] = [:]

    init(performWrite: Bool) {
        self.performWrite = performWrite
    }

    func next(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        let round = roundsBySession[request.sessionID] ?? 0
        roundsBySession[request.sessionID] = round + 1
        let usage = TokenUsage(promptTokens: 7, completionTokens: 5, totalTokens: 12)
        if performWrite, round == 0 {
            return OpenGrokLiveSamplingResponse(
                output: "Creating an isolated file.",
                toolCalls: [ToolCall(
                    id: "write-\(request.sessionID)",
                    name: "search_replace",
                    arguments: #"{"file_path":"child-created.txt","old_string":"","new_string":"only the child"}"#
                )],
                usage: usage
            )
        }
        return OpenGrokLiveSamplingResponse(
            output: "isolated child completed",
            usage: usage
        )
    }

    var totalRounds: Int {
        roundsBySession.values.reduce(0, +)
    }
}

private struct SubagentWorktreeFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let host: LiveSubagentHost
    let store: LiveConversationStore
    let sampling: WorktreeSamplingBehavior

    init(
        gitRepository: Bool = true,
        performWrite: Bool = false,
        homeInsideWorkspace: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-subagent-worktree-\(UUID().uuidString)",
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        home = homeInsideWorkspace
            ? workspace.appendingPathComponent("private-home", isDirectory: true)
            : root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        if gitRepository {
            try Self.git(["init"], at: workspace)
            try Self.git(["config", "user.email", "subagent-worktree@example.test"], at: workspace)
            try Self.git(["config", "user.name", "Subagent Worktree Parity"], at: workspace)
            try "committed parent\n".write(
                to: workspace.appendingPathComponent("tracked.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "ignored-parent.txt\nprivate-home/\n".write(
                to: workspace.appendingPathComponent(".gitignore"),
                atomically: true,
                encoding: .utf8
            )
            try Self.git(["add", "tracked.txt", ".gitignore"], at: workspace)
            try Self.git(["commit", "-m", "Initial worktree fixture"], at: workspace)

            try "dirty parent\n".write(
                to: workspace.appendingPathComponent("tracked.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "untracked parent\n".write(
                to: workspace.appendingPathComponent("untracked-parent.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "staged parent\n".write(
                to: workspace.appendingPathComponent("staged-parent.txt"),
                atomically: true,
                encoding: .utf8
            )
            try Self.git(["add", "staged-parent.txt"], at: workspace)
            try "ignored parent\n".write(
                to: workspace.appendingPathComponent("ignored-parent.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]
        let store = LiveConversationStore(openGrokHome: home)
        self.store = store
        let sampling = WorktreeSamplingBehavior(performWrite: performWrite)
        self.sampling = sampling
        let sampler = OpenGrokLiveSampler { request, _ in
            await sampling.next(request)
        }
        let permissions = CLIPermissionOptions(alwaysApprove: true)
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false,
            cli: permissions
        )
        host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: "grok-4.5",
            workingDirectory: workspace,
            sessionID: "worktree-root-session",
            openGrokHome: home,
            conversationStore: store,
            processBackend: WorktreeParityShellBackend(),
            securityContext: security,
            sandboxDecision: LiveSandboxDecision(
                profileName: "none",
                mode: .none,
                enforced: false
            ),
            permissionOptions: permissions,
            fileAccessPolicy: .allowAll,
            telemetryBootstrapContext: .empty,
            imageToolContext: nil,
            webToolContext: nil,
            environment: environment,
            parentCapabilityCeiling: nil,
            definitionContext: DefinitionResolutionContext(
                cwd: workspace,
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: ["grok-4.5"],
            parentProvider: .xai
        ))
    }

    func dispose() async {
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func spawn(
        id: String,
        isolation: String? = "worktree",
        resumeFrom: String? = nil,
        cwd: String? = nil
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        var arguments: [String: JSONValue] = [
            "task_id": .string(id),
            "prompt": .string("Complete the isolated git workspace task"),
            "description": .string("Inspect isolated worktree"),
            "subagent_type": .string("general-purpose"),
            "background": .bool(false),
        ]
        if let isolation { arguments["isolation"] = .string(isolation) }
        if let resumeFrom { arguments["resume_from"] = .string(resumeFrom) }
        if let cwd { arguments["cwd"] = .string(cwd) }
        return await host.spawn(args: .object(arguments), toolCallID: "call-\(id)")
    }

    @discardableResult
    static func git(_ arguments: [String], at directory: URL) throws -> String {
        let result = try runGit(arguments, cwd: directory)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "SubagentWorktreeGit",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result.stdout
    }

    static func text(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }
}

@Suite("Live subagent git worktree isolation", .serialized)
struct LiveSubagentWorktreeParityTests {
    @Test("isolation=none preserves the original shared-workspace execution contract")
    func isolationNoneKeepsParentWorkspace() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "shared-child", isolation: "none")
        guard case .success(let output) = result else {
            Issue.record("shared-workspace child unexpectedly failed: \(result)")
            return
        }
        #expect(output.value["worktree_path"] == nil)
        #expect(!output.promptText.contains("<worktree_path>"))
        let record = try await fixture.store.load(sessionID: "shared-child")
        #expect(record.workingDirectory == fixture.workspace.path)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("worktrees").path
        ))
    }

    @Test("actual child tool dispatch stays isolated and preserves dirty tracked, staged, and untracked state")
    func actualChildRunsInsideIsolatedDirtyGitWorktree() async throws {
        let fixture = try SubagentWorktreeFixture(performWrite: true)
        defer { Task { await fixture.dispose() } }
        let parentStatusBefore = try SubagentWorktreeFixture.git(
            ["status", "--porcelain"],
            at: fixture.workspace
        )

        let result = await fixture.spawn(id: "isolated-child")
        guard case .success(let output) = result else {
            Issue.record("isolated live child failed: \(result)")
            return
        }
        let completedRecord = try await fixture.store.load(sessionID: "isolated-child")
        let writeResult = try #require(completedRecord.items.compactMap { item -> ToolResultItem? in
            guard case .toolResult(let value) = item else { return nil }
            return value
        }.first)
        guard !writeResult.content.hasPrefix("Tool search_replace failed:") else {
            Issue.record("isolated child write was refused: \(writeResult.content)")
            return
        }
        let worktreeString = try #require(output.value["worktree_path"]?.stringValue)
        let worktree = URL(fileURLWithPath: worktreeString).standardizedFileURL
        #expect(output.promptText.contains(
            "<worktree_path>\(worktreeString)</worktree_path>"
        ))
        #expect(worktree != fixture.workspace)
        #expect(worktree.lastPathComponent == "subagent-isolated-child")
        #expect(worktree.path.hasPrefix(
            fixture.home.appendingPathComponent("worktrees").path + "/"
        ))

        let parentIdentity = try discoverGitRepo(at: fixture.workspace)
        let childIdentity = try discoverGitRepo(at: worktree)
        #expect(childIdentity.commonDir.resolvingSymlinksInPath()
            == parentIdentity.commonDir.resolvingSymlinksInPath())
        #expect(childIdentity.toplevel?.standardizedFileURL == worktree)
        #expect(childIdentity.isDetached)
        #expect(try SubagentWorktreeFixture.text(worktree.appendingPathComponent("tracked.txt"))
            == "dirty parent\n")
        #expect(try SubagentWorktreeFixture.text(worktree.appendingPathComponent("untracked-parent.txt"))
            == "untracked parent\n")
        #expect(try SubagentWorktreeFixture.text(worktree.appendingPathComponent("staged-parent.txt"))
            == "staged parent\n")
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("ignored-parent.txt").path
        ))
        #expect(try SubagentWorktreeFixture.text(worktree.appendingPathComponent("child-created.txt"))
            == "only the child")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("child-created.txt").path
        ))
        #expect(try SubagentWorktreeFixture.git(["status", "--porcelain"], at: fixture.workspace)
            == parentStatusBefore)

        let childStatus = try SubagentWorktreeFixture.git(["status", "--porcelain"], at: worktree)
        #expect(childStatus.contains("A  staged-parent.txt"))
        #expect(childStatus.contains("?? child-created.txt"))

        let record = try await fixture.store.load(sessionID: "isolated-child")
        #expect(record.workingDirectory == worktree.path)
        #expect(record.parentSessionID == "worktree-root-session")
        let summaries = await fixture.host.coordinator.listCompleted()
        let summary = try #require(summaries.first { $0.request.id == "isolated-child" })
        #expect(summary.request.childCWD == worktree.path)
        #expect(summary.request.worktreePath == worktree.path)

        await fixture.host.shutdown()
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(try SubagentWorktreeFixture.text(worktree.appendingPathComponent("child-created.txt"))
            == "only the child")
    }

    @Test("resume_from reuses the same verified isolated checkout and retained child changes")
    func resumedChildReusesManagedWorktree() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }

        let initial = await fixture.spawn(id: "resume-source")
        guard case .success(let initialOutput) = initial else {
            Issue.record("initial isolated child failed: \(initial)")
            return
        }
        let worktreePath = try #require(initialOutput.value["worktree_path"]?.stringValue)
        let worktree = URL(fileURLWithPath: worktreePath)
        try "kept for resume".write(
            to: worktree.appendingPathComponent("resume-marker.txt"),
            atomically: true,
            encoding: .utf8
        )

        let resumed = await fixture.spawn(
            id: "resume-continuation",
            isolation: nil,
            resumeFrom: "resume-source"
        )
        guard case .success(let resumedOutput) = resumed else {
            Issue.record("resumed isolated child failed: \(resumed)")
            return
        }
        #expect(resumedOutput.value["worktree_path"]?.stringValue == worktreePath)
        #expect(try SubagentWorktreeFixture.text(worktree.appendingPathComponent("resume-marker.txt"))
            == "kept for resume")
        #expect(!FileManager.default.fileExists(
            atPath: worktree.deletingLastPathComponent()
                .appendingPathComponent("subagent-resume-continuation").path
        ))
        let record = try await fixture.store.load(sessionID: "resume-continuation")
        #expect(record.workingDirectory == worktreePath)
        #expect(try listLinkedWorktrees(source: fixture.workspace).count == 2)
    }

    @Test("a missing genuine isolated checkout never resumes in the parent workspace")
    func missingOwnedWorktreeFailsClosedOnResume() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }

        let initial = await fixture.spawn(id: "missing-source")
        guard case .success(let output) = initial else {
            Issue.record("initial isolated child failed: \(initial)")
            return
        }
        let path = URL(fileURLWithPath: try #require(output.value["worktree_path"]?.stringValue))
        let removed = try worktreeRemove(source: fixture.workspace, dest: path, force: true)
        #expect(removed.removed)
        let roundsBefore = await fixture.sampling.totalRounds

        let resumed = await fixture.spawn(
            id: "missing-continuation",
            isolation: nil,
            resumeFrom: "missing-source"
        )
        guard case .failure(let error) = resumed else {
            Issue.record("a missing isolated worktree unexpectedly resumed: \(resumed)")
            return
        }
        #expect(error.description.contains("its worktree is unavailable"))
        #expect(await fixture.sampling.totalRounds == roundsBefore)
        #expect(try await fixture.store.loadIfPresent(sessionID: "missing-continuation") == nil)
        #expect(try SubagentWorktreeFixture.text(fixture.workspace.appendingPathComponent("tracked.txt"))
            == "dirty parent\n")
    }

    @Test("a replaced isolated checkout cannot redirect resume into the parent workspace")
    func replacedOwnedWorktreeFailsClosedOnResume() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }

        let initial = await fixture.spawn(id: "replaced-source")
        guard case .success(let output) = initial else {
            Issue.record("initial isolated child failed: \(initial)")
            return
        }
        let path = URL(fileURLWithPath: try #require(output.value["worktree_path"]?.stringValue))
        let removed = try worktreeRemove(source: fixture.workspace, dest: path, force: true)
        #expect(removed.removed)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.workspace)
        let roundsBefore = await fixture.sampling.totalRounds

        let resumed = await fixture.spawn(
            id: "replaced-continuation",
            isolation: nil,
            resumeFrom: "replaced-source"
        )
        guard case .failure(let error) = resumed else {
            Issue.record("a replaced isolated checkout unexpectedly resumed: \(resumed)")
            return
        }
        #expect(error.description.contains("unsafe or unavailable"))
        #expect(await fixture.sampling.totalRounds == roundsBefore)
        #expect(try await fixture.store.loadIfPresent(sessionID: "replaced-continuation") == nil)
    }

    @Test("worktree isolation refuses a non-Git workspace without sampling in the parent")
    func nonGitWorkspaceFailsClosed() async throws {
        let fixture = try SubagentWorktreeFixture(gitRepository: false)
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "not-a-repository")
        guard case .failure(let error) = result else {
            Issue.record("a non-git workspace unexpectedly spawned: \(result)")
            return
        }
        #expect(error.description.contains("worktree isolation is unavailable"))
        #expect(error.description.contains("refusing to use the parent workspace"))
        #expect(await fixture.sampling.totalRounds == 0)
        #expect(await fixture.host.coordinator.listCompleted().isEmpty)
        #expect(try await fixture.store.loadIfPresent(sessionID: "not-a-repository") == nil)
    }

    @Test("an existing cwd and explicit worktree isolation are rejected before worktree creation")
    func explicitExistingCWDCannotOverrideIsolation() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "ambiguous-cwd", cwd: fixture.workspace.path)
        guard case .failure(let error) = result else {
            Issue.record("ambiguous cwd and worktree unexpectedly spawned: \(result)")
            return
        }
        #expect(error.description.contains("mutually exclusive"))
        #expect(await fixture.sampling.totalRounds == 0)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("worktrees").path
        ))
    }

    @Test("a hallucinated cwd is discarded so explicit isolation still creates the real checkout")
    func nonexistentCWDDoesNotPreventIsolation() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "hallucinated-cwd", cwd: "does-not-exist")
        guard case .success(let output) = result else {
            Issue.record("isolated child with hallucinated cwd failed: \(result)")
            return
        }
        let path = try #require(output.value["worktree_path"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!path.contains("does-not-exist"))
    }

    @Test("managed worktree paths reject repository-directory symlink escapes")
    func symlinkedRepositoryPoolCannotEscapeHome() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }
        let managed = fixture.home.appendingPathComponent("worktrees", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let slug = LiveSubagentWorktree.repositorySlug(fixture.workspace)
        try FileManager.default.createSymbolicLink(
            at: managed.appendingPathComponent(slug),
            withDestinationURL: outside
        )

        let result = await fixture.spawn(id: "pool-escape")
        guard case .failure(let error) = result else {
            Issue.record("symlinked pool unexpectedly spawned: \(result)")
            return
        }
        #expect(error.description.contains("worktree isolation is unavailable"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(await fixture.sampling.totalRounds == 0)
    }

    @Test("a symlinked worktrees root cannot redirect isolated checkout creation outside OPENGROK_HOME")
    func symlinkedManagedRootCannotEscapeHome() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }
        let outside = fixture.root.appendingPathComponent("outside-root", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("worktrees"),
            withDestinationURL: outside
        )

        let result = await fixture.spawn(id: "root-escape")
        guard case .failure(let error) = result else {
            Issue.record("symlinked worktrees root unexpectedly spawned: \(result)")
            return
        }
        #expect(error.description.contains("escapes OPENGROK_HOME"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(await fixture.sampling.totalRounds == 0)
    }

    @Test("a child rejected by coordinator admission leaves no worktree or Git registration")
    func failedCoordinatorRegistrationReclaimsFreshWorktree() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }
        let parentStatusBefore = try SubagentWorktreeFixture.git(
            ["status", "--porcelain"],
            at: fixture.workspace
        )
        #expect(await fixture.host.coordinator.cancel(
            .parentSession("worktree-root-session")
        ) == 0)

        let result = await fixture.spawn(id: "blocked-registration")
        guard case .failure = result else {
            Issue.record("a blocked session unexpectedly registered a child: \(result)")
            return
        }
        let destination = fixture.home
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(LiveSubagentWorktree.repositorySlug(fixture.workspace))
            .appendingPathComponent("subagent-blocked-registration")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try listLinkedWorktrees(source: fixture.workspace).count == 1)
        #expect(try SubagentWorktreeFixture.git(["status", "--porcelain"], at: fixture.workspace)
            == parentStatusBefore)
        #expect(await fixture.sampling.totalRounds == 0)
    }

    @Test("an OPENGROK_HOME nested in the parent repository cannot materialize a child inside it")
    func worktreeDestinationInsideParentFailsClosed() async throws {
        let fixture = try SubagentWorktreeFixture(homeInsideWorkspace: true)
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "nested-home")
        guard case .failure(let error) = result else {
            Issue.record("nested home unexpectedly created an in-parent worktree: \(result)")
            return
        }
        #expect(error.description.contains("inside the parent workspace"))
        #expect(await fixture.sampling.totalRounds == 0)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("worktrees").path
        ))
    }

    @Test("a managed parent worktree reuses its original repository bucket")
    func alreadyManagedParentRetainsRepositoryBucket() async throws {
        let fixture = try SubagentWorktreeFixture()
        defer { Task { await fixture.dispose() } }
        let original = try await LiveSubagentWorktree.prepare(
            sourceDirectory: fixture.workspace,
            openGrokHome: fixture.home,
            childID: "managed-source"
        )
        let nestedChild = try await LiveSubagentWorktree.prepare(
            sourceDirectory: original.path,
            openGrokHome: fixture.home,
            childID: "managed-descendant"
        )

        #expect(nestedChild.path.deletingLastPathComponent()
            == original.path.deletingLastPathComponent())
        #expect(nestedChild.path.lastPathComponent == "subagent-managed-descendant")
        #expect(!nestedChild.path.path.hasPrefix(original.path.path + "/"))
        #expect(try listLinkedWorktrees(source: fixture.workspace).count == 3)
    }

    @Test("repository slugs match the upstream two-component ASCII sanitization contract")
    func repositorySlugParity() {
        #expect(LiveSubagentWorktree.repositorySlug(
            URL(fileURLWithPath: "/Users/alex/Projects/My_Repo")
        ) == "projects-my-repo")
        #expect(LiveSubagentWorktree.repositorySlug(
            URL(fileURLWithPath: "/home/.hidden")
        ) == "repo")
        let long = String(repeating: "a", count: 100)
        #expect(LiveSubagentWorktree.repositorySlug(
            URL(fileURLWithPath: "/tmp/\(long)")
        ).count == 64)
    }
}
