// LivePagerForkTasksReachabilityTests.swift
//
// The render-layer half of `/fork` and `/tasks`, through the LIVE adapter
// (AGENTS.md §3): the real `LiveInteractiveControllerRenderer` painting into
// a captured sink, with effects asserted where they land — the forked
// session record ON DISK (parent id, copied items, rewind sidecar bytes) and
// the painted tasks block fed by a REAL background shell process and a REAL
// subagent-host child spawned through the real tool dispatch. The controller
// half (registry pins, the verbatim parse catalog, dispatch routing) is
// pinned in `Tests/OpenGrokPagerTests/PagerForkTasksCommandTests.swift`.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

/// Runs nothing; used where a test never exercises the shell.
private actor ForkInertShellBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "", stdout: "", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "bg")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}

private final class ForkCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// A failed `#expect` mirrors captured values; without this, Swift
    /// Testing dumped the ENTIRE byte buffer as decimal text — with a
    /// 30-second animated frame stream behind it, that dump alone
    /// ballooned the test runner into tens of gigabytes.
    var customMirror: Mirror {
        lock.lock(); defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var plain: [UInt8] = []
        plain.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                plain.append(bytes[index])
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        // Decode the stripped bytes as UTF-8 — NOT one scalar per byte.
        // A byte-per-scalar decode mangles every multi-byte glyph ("·" is
        // C2 B7 and became "Â·"), which is exactly how the
        // "Task · long sleeper" needle missed a frame that contained it.
        return String(decoding: plain, as: UTF8.self)
    }
}

/// An isolated workspace + `$HOME`/`$OPENGROK_HOME` so hook and MCP
/// discovery cannot pick up the developer's real configuration, and so the
/// session store the fork writes into is this test's alone.
private struct ForkTasksWorkspace {
    let root: URL
    let grokHome: URL
    let environment: [String: String]

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-fork-tasks-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("repo", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        grokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        for directory in [root, home, grokHome] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": grokHome.path,
        ]
    }

    var sessionsDirectory: URL {
        grokHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Every stored session record id (the `.json` files, not the rewind
    /// sidecars).
    func storedSessionIDs() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// One live session: the real executor and the real renderer holding it —
/// the exact pair the interactive composition wires — plus the session
/// store the fork copies through.
private struct ForkTasksSession {
    let executor: LiveToolExecutor
    let renderer: LiveInteractiveControllerRenderer
    let sink: ForkCapturingSink
    let store: LiveConversationStore
    let sessionID: String

    static func start(
        _ workspace: ForkTasksWorkspace,
        sessionID: String,
        backend: any ShellProcessBackend,
        store: LiveConversationStore,
        subagentHost: LiveSubagentHost? = nil,
        permissionOptions: CLIPermissionOptions = CLIPermissionOptions()
    ) async throws -> ForkTasksSession {
        let executor = try await LiveToolExecutor(
            processBackend: backend,
            sessionID: sessionID,
            workingDirectory: workspace.root,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: workspace.environment,
            permissionOptions: permissionOptions,
            subagentHost: subagentHost
        )
        let sink = ForkCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: workspace.root.path,
            modelName: "test-model",
            sessionID: sessionID,
            conversationStore: store,
            // NOT `minimumPaintCadence` (1 ms): a running background task
            // keeps the motion ticker animating, and at ~1000 fps this
            // suite's 30-second `sleep` test accumulated frame diffs into
            // the capturing sink at >100 MB/s (the 128 GB runner balloon).
            // 10 fps keeps every wait responsive and the capture bounded.
            paintCadence: PagerMotion.maximumPaintCadence,
            environment: workspace.environment,
            toolExecutor: executor
        )
        try await renderer.begin()
        try await renderer.render(.promptChanged(OpenGrokPagerInteractivePromptState()))
        return ForkTasksSession(
            executor: executor,
            renderer: renderer,
            sink: sink,
            store: store,
            sessionID: sessionID
        )
    }

    /// The painted frame with all whitespace removed — the diff encoder
    /// skips blank cells, so multi-word needles never match raw capture.
    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String) async {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func paintedContains(_ needle: String) -> Bool {
        paintedCompact().contains(needle.filter { !$0.isWhitespace })
    }
}

/// A stored source session with items and a rewind sidecar — what a real
/// conversation leaves on disk before `/fork` runs.
private func seedSourceSession(
    _ workspace: ForkTasksWorkspace,
    store: LiveConversationStore,
    sessionID: String,
    rewindBytes: Data?
) async throws -> LiveConversationRecord {
    var source = LiveConversationRecord.new(
        sessionID: sessionID,
        workingDirectory: workspace.root
    )
    source.items = [
        .user("hello from the source session"),
        .assistant(AssistantItem(content: "hi — source answer", toolCalls: [])),
    ]
    try await store.save(source)
    if let rewindBytes {
        let rewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: workspace.grokHome,
            sessionID: sessionID
        )
        try rewindBytes.write(to: rewindURL)
    }
    return source
}

private func taskID(from result: Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>) -> String? {
    guard case .success(let output) = result,
          case .object(let object) = output.value,
          case .string(let id)? = object["task_id"] else { return nil }
    return id
}

private func subagentID(from result: Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>) -> String? {
    guard case .success(let output) = result,
          case .object(let object) = output.value,
          case .string(let id)? = object["subagent_id"] else { return nil }
    return id
}

// MARK: - /fork at the live seam

@Suite("/fork live seam", .serialized)
struct LivePagerForkReachabilityTests {
    @Test("/fork writes a REAL forked session record: parent id, copied items, rewind bytes")
    func forkWritesTheForkedRecord() async throws {
        let workspace = ForkTasksWorkspace()
        defer { workspace.cleanup() }
        let store = LiveConversationStore(openGrokHome: workspace.grokHome)
        let rewindBytes = Data("{\"prompt_index\":3}\n".utf8)
        let source = try await seedSourceSession(
            workspace, store: store, sessionID: "fork-live-source", rewindBytes: rewindBytes
        )
        let session = try await ForkTasksSession.start(
            workspace,
            sessionID: source.sessionID,
            backend: ForkInertShellBackend(),
            store: store
        )

        try await session.renderer.render(.overlay(.fork(worktreeOverride: nil, directive: nil)))

        await session.waitForPaint(of: "Forked this session as")
        #expect(session.paintedContains("Forked this session as"))

        // The record is asserted ON DISK, not through the store that wrote
        // it: a decode of the actual file is what a resume will see.
        let forkedIDs = workspace.storedSessionIDs().filter { $0 != source.sessionID }
        try #require(forkedIDs.count == 1, "exactly one forked record, found \(forkedIDs)")
        let forkedID = forkedIDs[0]
        let forkedURL = workspace.sessionsDirectory
            .appendingPathComponent(forkedID).appendingPathExtension("json")
        let forked = try JSONDecoder().decode(
            LiveConversationRecord.self,
            from: Data(contentsOf: forkedURL)
        )
        #expect(forked.sessionID == forkedID)
        #expect(forked.parentSessionID == source.sessionID)
        #expect(forked.items == source.items)
        #expect(forked.workingDirectory == workspace.root.standardizedFileURL.path)

        // The rewind sidecar rides along byte-for-byte, so the fork resumes
        // the parent's prompt numbering and restore points.
        let forkedRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: workspace.grokHome,
            sessionID: forkedID
        )
        #expect(try Data(contentsOf: forkedRewindURL) == rewindBytes)

        // The note names both real open routes for the new id.
        #expect(session.paintedContains("/resume \(forkedID)"))
        #expect(session.paintedContains("open-grok --resume \(forkedID)"))
        try await session.renderer.restoreTerminal()
    }

    @Test("/fork --worktree refuses by name and writes nothing")
    func forkWorktreeRefuses() async throws {
        let workspace = ForkTasksWorkspace()
        defer { workspace.cleanup() }
        let store = LiveConversationStore(openGrokHome: workspace.grokHome)
        let source = try await seedSourceSession(
            workspace, store: store, sessionID: "fork-live-worktree", rewindBytes: nil
        )
        let session = try await ForkTasksSession.start(
            workspace,
            sessionID: source.sessionID,
            backend: ForkInertShellBackend(),
            store: store
        )

        try await session.renderer.render(.overlay(.fork(worktreeOverride: true, directive: nil)))

        await session.waitForPaint(of: "/fork --worktree is not available")
        #expect(session.paintedContains(LivePagerForkCommand.worktreeRefusal))
        // Refusal means refusal: no record appeared.
        #expect(workspace.storedSessionIDs() == [source.sessionID])
        try await session.renderer.restoreTerminal()
    }

    @Test("/fork with a directive refuses BEFORE the disk fork — the text is never dropped")
    func forkDirectiveRefusesWithoutForking() async throws {
        let workspace = ForkTasksWorkspace()
        defer { workspace.cleanup() }
        let store = LiveConversationStore(openGrokHome: workspace.grokHome)
        let source = try await seedSourceSession(
            workspace, store: store, sessionID: "fork-live-directive", rewindBytes: nil
        )
        let session = try await ForkTasksSession.start(
            workspace,
            sessionID: source.sessionID,
            backend: ForkInertShellBackend(),
            store: store
        )

        try await session.renderer.render(.overlay(.fork(
            worktreeOverride: nil,
            directive: "explore the rate-limit hypothesis"
        )))

        await session.waitForPaint(of: "/fork with a directive is not available")
        #expect(session.paintedContains(LivePagerForkCommand.directiveRefusal))
        #expect(workspace.storedSessionIDs() == [source.sessionID])
        try await session.renderer.restoreTerminal()
    }

    @Test("/fork with no stored source surfaces the store's own error")
    func forkWithoutStoredSourceReportsNotFound() async throws {
        let workspace = ForkTasksWorkspace()
        defer { workspace.cleanup() }
        let store = LiveConversationStore(openGrokHome: workspace.grokHome)
        // No seed: the session id has no record on disk yet.
        let session = try await ForkTasksSession.start(
            workspace,
            sessionID: "fork-live-missing",
            backend: ForkInertShellBackend(),
            store: store
        )

        try await session.renderer.render(.overlay(.fork(worktreeOverride: nil, directive: nil)))

        await session.waitForPaint(of: "session not found: fork-live-missing")
        #expect(session.paintedContains("session not found: fork-live-missing"))
        #expect(workspace.storedSessionIDs().isEmpty)
        try await session.renderer.restoreTerminal()
    }
}

// MARK: - /tasks at the live seam

@Suite("/tasks live seam", .serialized)
struct LivePagerTasksReachabilityTests {
    @Test("/tasks with no session paints upstream's No active session error")
    func tasksWithoutSessionErrors() async throws {
        let workspace = ForkTasksWorkspace()
        defer { workspace.cleanup() }
        // The empty session id is the port's one session-less state — the
        // arm `tasks.rs:33-35` errors on. No executor: a session-less
        // renderer cannot have registered a shell session either.
        let sink = ForkCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: workspace.root.path,
            modelName: "test-model",
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: workspace.environment
        )
        try await renderer.begin()
        try await renderer.render(.promptChanged(OpenGrokPagerInteractivePromptState()))

        try await renderer.render(.overlay(.showTasks))

        let needle = "No active session".filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !sink.strippedText.filter({ !$0.isWhitespace }).contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sink.strippedText.filter { !$0.isWhitespace }.contains(needle))
        try await renderer.restoreTerminal()
    }

    @Test("/tasks with nothing running paints upstream's empty-state copy")
    func tasksEmptyStatePaints() async throws {
        let workspace = ForkTasksWorkspace()
        defer { workspace.cleanup() }
        let store = LiveConversationStore(openGrokHome: workspace.grokHome)
        let session = try await ForkTasksSession.start(
            workspace,
            sessionID: "tasks-live-empty",
            backend: ForkInertShellBackend(),
            store: store
        )

        try await session.renderer.render(.overlay(.showTasks))

        // `status_blocks.rs:169`, byte for byte.
        await session.waitForPaint(of: "No background tasks, workflows, or subagents.")
        #expect(session.paintedContains("No background tasks, workflows, or subagents."))
        try await session.renderer.restoreTerminal()
    }

    @Test("/tasks paints a REAL background shell task started through the real dispatch")
    func tasksPaintsALiveShellTask() async throws {
        let workspace = ForkTasksWorkspace()
        defer { workspace.cleanup() }
        let store = LiveConversationStore(openGrokHome: workspace.grokHome)
        let session = try await ForkTasksSession.start(
            workspace,
            sessionID: "tasks-live-shell",
            backend: LocalShellProcessBackend(),
            store: store,
            // The flag a real user types (`--always-approve`) — never an
            // env bypass — so the headless bash dispatch has no prompter to
            // miss (AGENTS.md §5).
            permissionOptions: CLIPermissionOptions(alwaysApprove: true)
        )

        // A real process, backgrounded by the model's own flag.
        let spawned = await session.executor.invoke(
            sessionID: session.sessionID,
            workingDirectory: workspace.root,
            call: ToolCall(
                id: "bg-1",
                name: "run_terminal_cmd",
                arguments: #"{"command": "sleep 30", "is_background": true, "description": "long sleeper"}"#
            )
        )
        let spawnedTaskID = taskID(from: spawned)
        try #require(spawnedTaskID != nil, "background spawn failed: \(spawned)")

        try await session.renderer.render(.overlay(.showTasks))

        await session.waitForPaint(of: "Task · long sleeper")
        // Header (`Task (1):`), status, kind and the description one-liner.
        #expect(session.paintedContains("Task (1):"))
        #expect(session.paintedContains("running"))
        #expect(session.paintedContains("Task · long sleeper"))

        // Tear the process down through the REAL kill tool, asserting on
        // the outcome at the call site — never `_ =`.
        let killed = await session.executor.invoke(
            sessionID: session.sessionID,
            workingDirectory: workspace.root,
            call: ToolCall(
                id: "kill-1",
                name: "kill_command_or_subagent",
                arguments: #"{"task_id": "\#(spawnedTaskID ?? "")"}"#
            )
        )
        guard case .success(let killResult) = killed else {
            Issue.record("kill_command_or_subagent failed: \(killed)")
            try await session.renderer.restoreTerminal()
            return
        }
        #expect(killResult.promptText.contains("terminated")
            || killResult.promptText.contains("already exited"))
        try await session.renderer.restoreTerminal()
        await session.executor.shutdown()
    }

    @Test("/tasks paints a live subagent-host child spawned through the real tool dispatch")
    func tasksPaintsALiveSubagentChild() async throws {
        let workspace = ForkTasksWorkspace()
        defer { workspace.cleanup() }
        let store = LiveConversationStore(openGrokHome: workspace.grokHome)
        let backend = ForkInertShellBackend()

        // A canned sampler: the child's one turn answers with no tool
        // calls, so the child completes on its own.
        let sampler = OpenGrokLiveSampler { _, _ in
            OpenGrokLiveSamplingResponse(output: "probe complete")
        }
        let securityContext = LiveSecurityContext.resolve(
            workspaceRoot: workspace.root,
            environment: workspace.environment,
            isInteractive: false
        )
        let host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: "test-model",
            workingDirectory: workspace.root,
            sessionID: "tasks-live-subagent",
            openGrokHome: workspace.grokHome,
            conversationStore: store,
            processBackend: backend,
            securityContext: securityContext,
            sandboxDecision: LiveSandboxDecision(
                profileName: "none",
                mode: .none,
                enforced: false
            ),
            permissionOptions: CLIPermissionOptions(),
            fileAccessPolicy: .allowAll,
            telemetryBootstrapContext: .empty,
            imageToolContext: nil,
            webToolContext: nil,
            environment: workspace.environment,
            parentCapabilityCeiling: nil,
            definitionContext: DefinitionResolutionContext(
                cwd: workspace.root,
                includeFilesystemDefinitions: true,
                environment: workspace.environment
            ),
            modelSlugs: []
        ))
        let session = try await ForkTasksSession.start(
            workspace,
            sessionID: "tasks-live-subagent",
            backend: backend,
            store: store,
            subagentHost: host
        )

        // Spawn through the REAL dispatch, the way a model turn does.
        let spawned = await session.executor.invoke(
            sessionID: session.sessionID,
            workingDirectory: workspace.root,
            call: ToolCall(
                id: "spawn-1",
                name: "spawn_subagent",
                arguments: #"{"prompt": "probe", "description": "probe the fixture", "subagent_type": "explore", "background": true}"#
            )
        )
        let childID = subagentID(from: spawned)
        try #require(childID != nil, "spawn_subagent failed: \(spawned)")

        // Bounded poll until the child lands as terminal — never a one-shot
        // read of a spawned-task effect.
        var terminalStatus: String?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let snapshot = await host.subagentSnapshot(id: childID ?? ""),
               snapshot.completed {
                terminalStatus = snapshot.status
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(terminalStatus == "completed", "child never completed")

        try await session.renderer.render(.overlay(.showTasks))

        // `format_subagent_label`: "explore" is a meaningful type, so the
        // label is "Explore · <description>".
        await session.waitForPaint(of: "Explore · probe the fixture")
        #expect(session.paintedContains("Task (1):"))
        #expect(session.paintedContains("completed"))
        #expect(session.paintedContains("Explore · probe the fixture"))
        try await session.renderer.restoreTerminal()
        await session.executor.shutdown()
    }
}

// MARK: - The tasks-block formatter (byte-exact row pins)

@Suite("tasks_block_text port")
struct LivePagerTasksBlockTests {
    private func snapshot(
        id: String,
        type: String = "explore",
        description: String = "",
        status: String,
        startedAt: Date,
        durationMS: UInt64 = 0
    ) -> LiveSubagentSnapshot {
        LiveSubagentSnapshot(
            subagentID: id,
            subagentType: type,
            description: description,
            status: status,
            output: "",
            startedAt: startedAt,
            durationMS: durationMS,
            exitCode: nil
        )
    }

    private func shellTask(
        id: String,
        command: String = "sleep 5",
        description: String? = nil,
        completed: Bool,
        exitCode: Int32? = nil,
        explicitlyKilled: Bool = false,
        startTime: Date,
        endTime: Date? = nil
    ) -> ShellTaskSnapshot {
        ShellTaskSnapshot(
            taskID: id,
            command: command,
            cwd: URL(fileURLWithPath: "/tmp"),
            startTime: startTime,
            endTime: endTime,
            exitCode: exitCode,
            completed: completed,
            explicitlyKilled: explicitlyKilled,
            description: description
        )
    }

    @Test("empty sources render upstream's empty-state copy, byte-exact")
    func emptyState() {
        #expect(LivePagerTasksBlock.text(
            workflowRows: [], subagents: [], tasks: [], now: Date()
        ) == "No background tasks, workflows, or subagents.")
    }

    @Test("the header is singular for one row and plural with the count")
    func headerPluralization() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let one = LivePagerTasksBlock.text(
            workflowRows: [],
            subagents: [snapshot(id: "a", status: "completed", startedAt: now, durationMS: 1_000)],
            tasks: [],
            now: now
        )
        #expect(one.hasPrefix("Task (1):\n"))
        let two = LivePagerTasksBlock.text(
            workflowRows: [],
            subagents: [
                snapshot(id: "a", status: "completed", startedAt: now, durationMS: 1_000),
                snapshot(id: "b", status: "completed", startedAt: now, durationMS: 1_000),
            ],
            tasks: [],
            now: now
        )
        #expect(two.hasPrefix("Tasks (2):\n"))
    }

    @Test("workflow rows carry status, phase, agent count and duration in upstream's format")
    func workflowRowFormat() {
        let now = Date(timeIntervalSince1970: 2_000)
        let active = LivePagerTasksBlock.WorkflowRow(
            runID: "run-a",
            name: "nightly",
            status: "active",
            currentPhase: "  build  ",
            activeAgentCount: 2,
            createdAtMS: 1_700_000  // 300s before `now`
        )
        let text = LivePagerTasksBlock.text(
            workflowRows: [active], subagents: [], tasks: [], now: now
        )
        // `status_blocks.rs:72-81`: `"  {status:<9}Workflow · {name}{phase}{agents}  ({duration})"`,
        // the phase trimmed, "running" for an active run.
        #expect(text == "Task (1):\n  running  Workflow · nightly · build · 2 agents  (5m0s)")
    }

    @Test("a terminal workflow's status swaps underscores and its elapsed freezes at the last journal entry")
    func workflowTerminalRow() {
        let now = Date(timeIntervalSince1970: 9_999)
        let exceeded = LivePagerTasksBlock.WorkflowRow(
            runID: "run-b",
            name: "sweep",
            status: "budget_exceeded",
            createdAtMS: 1_000_000,
            lastEntryAtMS: 1_012_000  // 12s of journaled work
        )
        let text = LivePagerTasksBlock.text(
            workflowRows: [exceeded], subagents: [], tasks: [], now: now
        )
        #expect(text == "Task (1):\n  budget exceededWorkflow · sweep  (12s)")
    }

    @Test("subagent rows use the label port: type when meaningful, tag fallback, General")
    func subagentRowsAndLabels() {
        let now = Date(timeIntervalSince1970: 5_000)
        let rows = LivePagerTasksBlock.text(
            workflowRows: [],
            subagents: [
                snapshot(
                    id: "a", type: "explore", description: "find auth code",
                    status: "completed", startedAt: now, durationMS: 12_000
                ),
            ],
            tasks: [],
            now: now
        )
        // `status_blocks.rs:110-113`: `"  {status:<9}{label}  ({duration})"`,
        // label `type · desc` — "completed" is exactly 9 columns, so no
        // separating space, exactly as Rust's `{:<9}` pads.
        #expect(rows == "Task (1):\n  completedExplore · find auth code  (12s)")

        // `format_subagent_label` fallbacks (subagent.rs:404-433).
        #expect(LivePagerTasksBlock.subagentLabel(
            type: "general-purpose", description: "[security-fix] patch XSS"
        ) == ("Security-fix", "patch XSS"))
        #expect(LivePagerTasksBlock.subagentLabel(
            type: "general-purpose", description: "do a thing"
        ) == ("General", "do a thing"))
        #expect(LivePagerTasksBlock.subagentLabel(
            type: "general-purpose", description: "[] do something"
        ) == ("General", "[] do something"))
        #expect(LivePagerTasksBlock.subagentLabel(
            type: "general-purpose", description: "[broken description"
        ) == ("General", "[broken description"))
        #expect(LivePagerTasksBlock.subagentLabel(
            type: "custom-agent", description: ""
        ) == ("Custom-agent", ""))
    }

    @Test("task rows prefer the description and fall back to the first non-empty command line")
    func taskRowOneLiner() {
        let now = Date(timeIntervalSince1970: 100)
        let described = shellTask(
            id: "t1", description: "long sleeper", completed: false,
            startTime: now.addingTimeInterval(-3.24)
        )
        let bare = shellTask(
            id: "t2", command: "\n  \n  make build \nmake test", completed: true,
            exitCode: 0,
            startTime: now.addingTimeInterval(-90), endTime: now.addingTimeInterval(-29)
        )
        let text = LivePagerTasksBlock.text(
            workflowRows: [], subagents: [], tasks: [described, bare], now: now
        )
        // Running sorts first; a clean exit is upstream's "done"
        // (`status_blocks.rs:138-142`); durations through `format_duration`
        // (util.rs:81-97): sub-10s keeps a decimal, a 61s span is "1m1s".
        #expect(text == "Tasks (2):\n"
            + "  running  Task · long sleeper  (3.2s)\n"
            + "  done     Task · make build  (1m1s)")
    }

    @Test("an explicitly killed task paints the port's cancelled state")
    func taskCancelledRow() {
        let now = Date(timeIntervalSince1970: 100)
        let killed = shellTask(
            id: "t3", description: "doomed", completed: true,
            explicitlyKilled: true,
            startTime: now.addingTimeInterval(-15), endTime: now.addingTimeInterval(-1)
        )
        let text = LivePagerTasksBlock.text(
            workflowRows: [], subagents: [], tasks: [killed], now: now
        )
        #expect(text == "Task (1):\n  cancelledTask · doomed  (14s)")
    }

    @Test("sections sort exactly as upstream: active/running first, then newest, then id")
    func sortOrders() {
        let now = Date(timeIntervalSince1970: 10_000)
        let workflows = [
            LivePagerTasksBlock.WorkflowRow(
                runID: "w-old-active", name: "old-active", status: "active",
                createdAtMS: 1_000_000
            ),
            LivePagerTasksBlock.WorkflowRow(
                runID: "w-done", name: "done-run", status: "completed",
                createdAtMS: 9_000_000, lastEntryAtMS: 9_001_000
            ),
            LivePagerTasksBlock.WorkflowRow(
                runID: "w-new-active", name: "new-active", status: "active",
                createdAtMS: 2_000_000
            ),
        ]
        let subagents = [
            snapshot(id: "s-done", status: "completed",
                     startedAt: now.addingTimeInterval(-10), durationMS: 5_000),
            snapshot(id: "s-run-old", status: "running",
                     startedAt: now.addingTimeInterval(-100)),
            snapshot(id: "s-run-new", status: "running",
                     startedAt: now.addingTimeInterval(-50)),
        ]
        let tasks = [
            shellTask(id: "t-done", completed: true, exitCode: 0,
                      startTime: now.addingTimeInterval(-500),
                      endTime: now.addingTimeInterval(-400)),
            shellTask(id: "t-run", completed: false,
                      startTime: now.addingTimeInterval(-30)),
        ]
        let text = LivePagerTasksBlock.text(
            workflowRows: workflows, subagents: subagents, tasks: tasks, now: now
        )
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 9)
        // Workflows: actives first (newest created leads), then terminal.
        #expect(lines[1].contains("new-active"))
        #expect(lines[2].contains("old-active"))
        #expect(lines[3].contains("done-run"))
        // Subagents: running first, newest started leads.
        #expect(lines[4].contains("(50s)"))   // s-run-new
        #expect(lines[5].contains("(1m40s)")) // s-run-old
        #expect(lines[6].contains("(5.0s)"))  // s-done, frozen duration
        // Tasks: running before done.
        #expect(lines[7].contains("running"))
        #expect(lines[8].contains("done"))
    }

    @Test("the duration formatter matches util.rs:81-97 bucket for bucket")
    func durationBuckets() {
        #expect(LivePagerTasksBlock.formatDuration(0) == "0.0s")
        #expect(LivePagerTasksBlock.formatDuration(3.24) == "3.2s")
        #expect(LivePagerTasksBlock.formatDuration(9.99) == "10.0s")
        #expect(LivePagerTasksBlock.formatDuration(10) == "10s")
        #expect(LivePagerTasksBlock.formatDuration(59.9) == "59s")
        #expect(LivePagerTasksBlock.formatDuration(61) == "1m1s")
        #expect(LivePagerTasksBlock.formatDuration(3_599) == "59m59s")
        #expect(LivePagerTasksBlock.formatDuration(3_600) == "1h0m")
        #expect(LivePagerTasksBlock.formatDuration(3_721) == "1h2m")
    }
}
