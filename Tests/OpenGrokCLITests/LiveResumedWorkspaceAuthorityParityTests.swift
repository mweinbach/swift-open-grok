import Foundation
import OpenGrokFastWorktree
import OpenGrokPager
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import Testing

@testable import OpenGrokCLI

private actor WorkspaceAuthoritySamplingProbe {
    private var requests: [OpenGrokLiveSamplingRequest] = []

    func sample(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        let previousRounds = requests.filter { $0.sessionID == request.sessionID }.count
        requests.append(request)
        if previousRounds == 0 {
            return OpenGrokLiveSamplingResponse(
                output: "writing in the authorized workspace",
                toolCalls: [ToolCall(
                    id: "workspace-write-\(request.sessionID)",
                    name: "write",
                    arguments: #"{"file_path":"workspace-authority.txt","content":"authorized"}"#
                )]
            )
        }
        return OpenGrokLiveSamplingResponse(output: "authorized workspace complete")
    }

    var requestCount: Int { requests.count }
}

private final class WorkspaceAuthorityProviderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func recordConstruction() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct ResumedWorkspaceAuthorityFixture {
    let root: URL
    let parent: URL
    let child: URL
    let home: URL
    let context: CLIApplicationContext
    let probe: WorkspaceAuthoritySamplingProbe
    let dependencies: OpenGrokLiveCompositionDependencies
    let foundation: OpenGrokLiveApplicationLauncher.LiveSessionFoundation
    let stack: OpenGrokLiveApplicationLauncher.LiveAgentStack
    let adapter: LivePagerRuntimeAdapter

    init() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-resume-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for directory in [parent, child, home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "[session_bus]\nenabled = false\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let context = CLIApplicationContext(
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "XAI_API_KEY": "workspace-authority-test-key",
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
            ],
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let probe = WorkspaceAuthoritySamplingProbe()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    await probe.sample(request)
                }
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "initialize authority", "--cwd", parent.path,
            "--model", "grok-4.5", "--always-approve",
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("workspace authority fixture did not parse")
        }
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context,
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: context,
            dependencies: dependencies
        )
        let adapter = LivePagerRuntimeAdapter(
            shell: stack.shell,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration,
            conversationHistory: stack.conversationHistory,
            conversationStore: foundation.conversationStore,
            toolExecutor: foundation.toolExecutor,
            compaction: stack.compaction,
            modelSwitch: stack.modelSwitch
        )

        self.root = root
        self.parent = parent
        self.child = child
        self.home = home
        self.context = context
        self.probe = probe
        self.dependencies = dependencies
        self.foundation = foundation
        self.stack = stack
        self.adapter = adapter
    }

    func saveSession(id: String, workingDirectory: URL) async throws -> LiveConversationRecord {
        var record = await stack.conversationHistory.snapshot()
        record.sessionID = id
        record.workingDirectory = workingDirectory.path
        record.parentSessionID = foundation.sessionID
        record.items = [.user("existing transcript in \(id)")]
        try await foundation.conversationStore.save(record)
        return try await foundation.conversationStore.load(sessionID: id)
    }

    func shutdown() async {
        _ = await stack.shell.shutdown()
        await foundation.toolExecutor.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func initializeRepository(at directory: URL) throws {
        let hooks = directory.appendingPathComponent("isolated-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for arguments in [
            ["init"],
            ["config", "user.name", "Workspace Authority"],
            ["config", "user.email", "workspace-authority@example.test"],
            ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", hooks.path],
        ] {
            let result = try runGit(arguments, cwd: directory)
            guard result.exitCode == 0 else {
                throw CLIApplicationError.failed(
                    "could not initialize repository \(directory.path): \(result.stderr)"
                )
            }
        }

        try "committed source\n".write(
            to: directory.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "isolated-hooks/\nignored-source.txt\n".write(
            to: directory.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        for arguments in [
            ["add", "tracked.txt", ".gitignore"],
            ["commit", "-m", "Initialize workspace authority fixture"],
        ] {
            let result = try runGit(arguments, cwd: directory)
            guard result.exitCode == 0 else {
                throw CLIApplicationError.failed(
                    "could not commit repository \(directory.path): \(result.stderr)"
                )
            }
        }

        try "dirty source\n".write(
            to: directory.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "untracked source\n".write(
            to: directory.appendingPathComponent("untracked-source.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored source\n".write(
            to: directory.appendingPathComponent("ignored-source.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    func resumeInWorktreeOptions(sessionID: String, cwd: URL) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "resume in isolated worktree",
            "--resume", sessionID, "--cwd", cwd.path, "--worktree",
            "--model", "grok-4.5", "--always-approve",
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("worktree-resume fixture did not parse")
        }
        return options
    }
}

@Suite("Resumed session workspace authority", .serialized)
struct LiveResumedWorkspaceAuthorityParityTests {
    @Test("cross-workspace resume fails before session, transcript, sampler, or file mutation")
    func crossWorkspaceResumeFailsClosedBeforeMutation() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }
        let child = try await fixture.saveSession(
            id: "cross-root-child",
            workingDirectory: fixture.child
        )
        let parentBefore = await fixture.stack.conversationHistory.snapshot()

        do {
            _ = try await fixture.adapter.resumeSession(sessionID: child.sessionID)
            Issue.record("cross-workspace resume unexpectedly reused the parent tool authority")
        } catch {
            #expect(String(describing: error).contains("separate process"))
            #expect(String(describing: error).contains(fixture.child.path))
        }

        #expect(await fixture.stack.conversationHistory.snapshot() == parentBefore)
        let persistedChild = try await fixture.foundation.conversationStore.load(
            sessionID: child.sessionID
        )
        #expect(persistedChild == child)
        #expect(await fixture.stack.shell.lookupSession(SessionID(child.sessionID)) == nil)
        #expect(await fixture.probe.requestCount == 0)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.parent.appendingPathComponent("workspace-authority.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.child.appendingPathComponent("workspace-authority.txt").path
        ))
    }

    @Test("dashboard replacement in another workspace fails before creating a session")
    func crossWorkspaceReplacementFailsClosedBeforeMutation() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }
        let parentBefore = await fixture.stack.conversationHistory.snapshot()

        do {
            _ = try await fixture.adapter.replaceSession(
                from: OpenGrokPagerRequest(prompt: "new workspace", mode: .fullScreen),
                workingDirectory: fixture.child.path
            )
            Issue.record("cross-workspace dashboard replacement unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("separate process"))
        }

        #expect(await fixture.stack.conversationHistory.snapshot() == parentBefore)
        #expect(await fixture.probe.requestCount == 0)
    }

    @Test("a symlink-equivalent workspace resumes and executes its actual file tool")
    func equivalentWorkspaceResumeStillRunsAuthorizedTools() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }

        let equivalentRoot: URL
        #if os(Windows)
        equivalentRoot = URL(
            fileURLWithPath: fixture.parent.path.uppercased(),
            isDirectory: true
        )
        #else
        equivalentRoot = fixture.root.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: equivalentRoot,
            withDestinationURL: fixture.parent
        )
        #endif
        let child = try await fixture.saveSession(
            id: "same-root-child",
            workingDirectory: equivalentRoot
        )

        let resumedSessionID = try await fixture.adapter.resumeSession(
            sessionID: child.sessionID
        )
        #expect(resumedSessionID == child.sessionID)
        let handle = try await fixture.stack.shell.submitTurn(
            sessionID: SessionID(child.sessionID),
            request: OpenGrokShellTurnRequest(
                promptID: "same-root-write",
                text: "write in the authorized workspace"
            )
        )
        let result = try await fixture.stack.shell.waitForTurn(
            handle,
            timeout: ShellDuration(timeInterval: 15)
        )
        #expect(result.output == "authorized workspace complete")
        let authorizedContents = try String(
            contentsOf: fixture.parent.appendingPathComponent("workspace-authority.txt"),
            encoding: .utf8
        )
        #expect(authorizedContents == "authorized")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.child.appendingPathComponent("workspace-authority.txt").path
        ))
    }

    @Test("direct, absolute, nested, and process invocations reject a mismatched workspace")
    func mismatchedToolInvocationsCannotFallBackToParent() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }
        let parentTarget = fixture.parent.appendingPathComponent("workspace-authority.txt")
        let childTarget = fixture.child.appendingPathComponent("workspace-authority.txt")
        let relative = ToolCall(
            id: "mismatched-relative",
            name: "write",
            arguments: #"{"file_path":"workspace-authority.txt","content":"unsafe"}"#
        )
        let absolute = ToolCall(
            id: "mismatched-absolute",
            name: "write",
            arguments: String(
                data: try JSONSerialization.data(withJSONObject: [
                    "file_path": parentTarget.path,
                    "content": "unsafe",
                ]),
                encoding: .utf8
            )!
        )
        let terminal = ToolCall(
            id: "mismatched-terminal",
            name: "run_terminal_cmd",
            arguments: #"{"command":"pwd"}"#
        )

        for call in [relative, absolute, terminal] {
            let result = await fixture.foundation.toolExecutor.invoke(
                sessionID: fixture.foundation.sessionID,
                workingDirectory: fixture.child,
                call: call
            )
            guard case .failure(let error) = result else {
                Issue.record("mismatched \(call.name) unexpectedly dispatched")
                continue
            }
            #expect(error.description.contains("separate process"))
        }

        let nested = await fixture.foundation.toolExecutor.invoke(
            sessionID: fixture.foundation.sessionID,
            workingDirectory: fixture.child,
            call: relative,
            onOutput: nil,
            onProgress: { _ in }
        )
        guard case .failure(let nestedError) = nested else {
            Issue.record("mismatched nested write unexpectedly dispatched")
            return
        }
        #expect(nestedError.description.contains("separate process"))
        #expect(!FileManager.default.fileExists(atPath: parentTarget.path))
        #expect(!FileManager.default.fileExists(atPath: childTarget.path))
    }

    @Test("an explicit separate-process resume pins foundation and real file dispatch to its stored workspace")
    func separateProcessResumeUsesStoredWorkspaceBeforeBootstrap() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }
        let child = try await fixture.saveSession(
            id: "external-root-child",
            workingDirectory: fixture.child
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "resume external workspace", "--resume", child.sessionID,
            "--model", "grok-4.5", "--always-approve",
        ])
        guard case .launch(let options) = command else {
            Issue.record("external resume command did not produce launch options")
            return
        }
        let resumed = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        defer { Task { await resumed.toolExecutor.shutdown() } }

        #expect(LiveToolExecutor.workspaceRootsMatch(resumed.cwd, fixture.child))
        #expect(LiveToolExecutor.workspaceRootsMatch(resumed.toolExecutor.workingDirectory, fixture.child))
        #expect(resumed.sessionID == child.sessionID)
        let result = await resumed.toolExecutor.invoke(
            sessionID: child.sessionID,
            workingDirectory: resumed.cwd,
            call: ToolCall(
                id: "external-authorized-write",
                name: "write",
                arguments: #"{"file_path":"workspace-authority.txt","content":"authorized"}"#
            )
        )
        guard case .success = result else {
            Issue.record("separate-process resumed tool did not dispatch in its own workspace")
            return
        }
        let authorizedContents = try String(
            contentsOf: fixture.child.appendingPathComponent("workspace-authority.txt"),
            encoding: .utf8
        )
        #expect(authorizedContents == "authorized")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.parent.appendingPathComponent("workspace-authority.txt").path
        ))
    }

    @Test("an explicit conflicting resume cwd is rejected before provider construction")
    func conflictingExplicitResumeCwdFailsBeforeProviderConstruction() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }
        let child = try await fixture.saveSession(
            id: "conflicting-root-child",
            workingDirectory: fixture.child
        )
        let constructions = WorkspaceAuthorityProviderCounter()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                constructions.recordConstruction()
                return OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "must not initialize")
                }
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "conflicting resume", "--resume", child.sessionID,
            "--cwd", fixture.parent.path, "--model", "grok-4.5", "--always-approve",
        ])
        guard case .launch(let options) = command else {
            Issue.record("conflicting resume command did not produce launch options")
            return
        }

        do {
            _ = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
                options: options,
                context: fixture.context,
                dependencies: dependencies
            )
            Issue.record("explicit conflicting resume cwd unexpectedly constructed a foundation")
        } catch {
            #expect(String(describing: error).contains("workspace"))
        }
        #expect(constructions.count == 0)
        let persistedChild = try await fixture.foundation.conversationStore.load(
            sessionID: child.sessionID
        )
        #expect(persistedChild == child)
    }

    @Test("resume plus worktree rejects a source from another git repository before all mutation")
    func foreignWorktreeResumeFailsBeforeCreationOrProviderConstruction() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }
        try fixture.initializeRepository(at: fixture.parent)
        try fixture.initializeRepository(at: fixture.child)
        let source = try await fixture.saveSession(
            id: "foreign-worktree-source",
            workingDirectory: fixture.child
        )
        let parentBefore = await fixture.stack.conversationHistory.snapshot()
        let registry = WorktreeRegistry(openGrokHome: fixture.home)
        let registryBefore = try registry.records()
        let poolExistedBefore = FileManager.default.fileExists(atPath: registry.poolRoot.path)
        let constructions = WorkspaceAuthorityProviderCounter()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                constructions.recordConstruction()
                return OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "must not initialize")
                }
            }
        )

        do {
            _ = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
                options: fixture.resumeInWorktreeOptions(
                    sessionID: source.sessionID,
                    cwd: fixture.parent
                ),
                context: fixture.context,
                dependencies: dependencies
            )
            Issue.record("an unrelated repository unexpectedly adopted the source session")
        } catch {
            #expect(String(describing: error).contains("repository"))
        }

        let sourceAfter = try await fixture.foundation.conversationStore.load(
            sessionID: source.sessionID
        )
        let registryAfter = try registry.records()
        #expect(sourceAfter == source)
        #expect(await fixture.stack.conversationHistory.snapshot() == parentBefore)
        #expect(registryAfter == registryBefore)
        #expect(FileManager.default.fileExists(atPath: registry.poolRoot.path) == poolExistedBefore)
        #expect(constructions.count == 0)
    }

    @Test("same-repository resume plus worktree forks a new session and preserves the dirty source")
    func sameRepositoryWorktreeResumeForksWithoutMutatingSource() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }
        try fixture.initializeRepository(at: fixture.parent)
        let source = try await fixture.saveSession(
            id: "same-repository-worktree-source",
            workingDirectory: fixture.parent
        )
        let sourceIdentity = try discoverGitRepo(at: fixture.parent)
        let resumed = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.resumeInWorktreeOptions(
                sessionID: source.sessionID,
                cwd: fixture.parent
            ),
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        defer { Task { await resumed.toolExecutor.shutdown() } }

        let sourceAfter = try await fixture.foundation.conversationStore.load(
            sessionID: source.sessionID
        )
        let forked = try await fixture.foundation.conversationStore.load(
            sessionID: resumed.sessionID
        )
        let forkIdentity = try discoverGitRepo(at: resumed.cwd)
        let records = try WorktreeRegistry(openGrokHome: fixture.home).records()
        let copiedTracked = try String(
            contentsOf: resumed.cwd.appendingPathComponent("tracked.txt"),
            encoding: .utf8
        )
        let copiedUntracked = try String(
            contentsOf: resumed.cwd.appendingPathComponent("untracked-source.txt"),
            encoding: .utf8
        )

        #expect(resumed.sessionID != source.sessionID)
        #expect(sourceAfter == source)
        #expect(forked.parentSessionID == source.sessionID)
        #expect(forked.sessionKind == "worktree")
        #expect(forked.items == source.items)
        #expect(LiveToolExecutor.workspaceRootsMatch(
            URL(fileURLWithPath: forked.workingDirectory),
            resumed.cwd
        ))
        #expect(!LiveToolExecutor.workspaceRootsMatch(resumed.cwd, fixture.parent))
        #expect(LiveToolExecutor.workspaceRootsMatch(
            sourceIdentity.commonDir,
            forkIdentity.commonDir
        ))
        #expect(records.count == 1)
        #expect(records.first?.sessionID == resumed.sessionID)
        #expect(copiedTracked == "dirty source\n")
        #expect(copiedUntracked == "untracked source\n")
        #expect(!FileManager.default.fileExists(
            atPath: resumed.cwd.appendingPathComponent("ignored-source.txt").path
        ))
    }

    @Test("a failed resume transcript fork reclaims its materialized worktree and registry row")
    func failedWorktreeResumeForkRollsBackCreation() async throws {
        let fixture = try await ResumedWorkspaceAuthorityFixture()
        defer { Task { await fixture.shutdown() } }
        try fixture.initializeRepository(at: fixture.parent)
        var legacy = try await fixture.saveSession(
            id: "legacy-worktree-source",
            workingDirectory: fixture.parent
        )
        legacy.everUsedNonXAI = nil
        try await fixture.foundation.conversationStore.save(legacy)
        let sourceBefore = try await fixture.foundation.conversationStore.load(
            sessionID: legacy.sessionID
        )
        let registry = WorktreeRegistry(openGrokHome: fixture.home)
        let registryBefore = try registry.records()

        do {
            _ = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
                options: fixture.resumeInWorktreeOptions(
                    sessionID: legacy.sessionID,
                    cwd: fixture.parent
                ),
                context: fixture.context,
                dependencies: fixture.dependencies
            )
            Issue.record("legacy source unexpectedly forked without its export boundary")
        } catch {
            #expect(String(describing: error).contains("export-boundary"))
        }

        let sourceAfter = try await fixture.foundation.conversationStore.load(
            sessionID: legacy.sessionID
        )
        let registryAfter = try registry.records()
        let poolEntries: [URL]
        if FileManager.default.fileExists(atPath: registry.poolRoot.path) {
            poolEntries = try FileManager.default.contentsOfDirectory(
                at: registry.poolRoot,
                includingPropertiesForKeys: nil
            )
        } else {
            poolEntries = []
        }
        #expect(sourceAfter == sourceBefore)
        #expect(registryAfter == registryBefore)
        #expect(poolEntries.isEmpty)
    }
}
