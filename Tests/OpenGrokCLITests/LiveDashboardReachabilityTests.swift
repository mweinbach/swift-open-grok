import Foundation
import OpenGrokFastWorktree
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class DashboardCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var plainText: String {
        lock.lock()
        defer { lock.unlock() }
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.append(bytes[index])
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
                    if bytes[index] == 0x07 {
                        index += 1
                        break
                    }
                    if bytes[index] == 0x1B,
                       index + 1 < bytes.count,
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
        return String(decoding: output, as: UTF8.self)
    }

    func contains(_ needle: String) -> Bool {
        let compact = plainText.filter { !$0.isWhitespace }
        return compact.contains(needle.filter { !$0.isWhitespace })
    }
}

private struct DashboardOutput: OpenGrokPagerInteractiveOutputAdapter, Sendable {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        _ = event
    }
}

private enum DashboardRuntimeError: Error, Sendable {
    case noTurnExpected
}

private struct DashboardRuntime: OpenGrokPagerRuntimeAdapter, Sendable {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw DashboardRuntimeError.noTurnExpected
    }
}

private struct DashboardControllerHarness: Sendable {
    let continuation: AsyncStream<InputEvent>.Continuation
    let task: Task<OpenGrokPagerInteractiveResult, Error>
}

private func ctrlKey(_ character: Character) -> InputEvent {
    .key(KeyEvent(key: .char(character), modifiers: .control, character: character))
}

private func key(_ character: Character) -> InputEvent {
    .key(KeyEvent(key: .char(character), character: character))
}

private func typeDashboardText(
    _ text: String,
    into renderer: LiveInteractiveControllerRenderer
) async throws {
    for character in text {
        #expect(try await renderer.handleInput(key(character)) == .consumed)
    }
}

private func userItem(_ text: String) -> ConversationItem {
    .user(UserItem(content: [.text(text: text)]))
}

private func assistantItem(_ text: String) -> ConversationItem {
    .assistant(AssistantItem(content: text))
}

private func record(
    _ sessionID: String,
    workingDirectory: URL,
    updatedAt: Date,
    items: [ConversationItem]
) -> LiveConversationRecord {
    LiveConversationRecord(
        sessionID: sessionID,
        workingDirectory: workingDirectory.path,
        parentSessionID: nil,
        createdAt: updatedAt.addingTimeInterval(-60),
        updatedAt: updatedAt,
        items: items
    )
}

private struct DashboardFixture {
    let home: URL
    let sink: DashboardCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let workingDirectory: URL
    let activeID = "active-session"
    let dormantID = "dormant-session"

    init(
        config: String? = nil,
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        questionCoordinator: PagerQuestionCoordinator? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-dashboard-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        self.workingDirectory = workingDirectory ?? home
        if let config {
            try config.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }

        var auditedEnvironment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ]
        auditedEnvironment.merge(environment) { _, replacement in replacement }
        sink = DashboardCapturingSink()
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 40) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: self.workingDirectory.path,
            questionCoordinator: questionCoordinator,
            sessionID: activeID,
            sessionCatalog: LiveSessionCatalog(openGrokHome: home),
            conversationStore: LiveConversationStore(openGrokHome: home),
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: auditedEnvironment
        )
    }

    func seed(_ records: [LiveConversationRecord]) async throws {
        let store = LiveConversationStore(openGrokHome: home)
        for record in records {
            try await store.save(record)
        }
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func waitForPaint(_ marker: String, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.contains(marker) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.contains(marker)
    }

    func dashboardRows() async -> [PagerOverlayBounds.Row] {
        await renderer.lastOverlayBounds
            .last { $0.id == LiveDashboardOverlay.overlayID }?
            .rows ?? []
    }

    func selectDashboardRow(
        _ rowID: String,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var selectedRowID: String?
        while Date() < deadline {
            let snapshot = await renderer.dashboardSnapshotForTesting()
            selectedRowID = snapshot.selectedRowID
            if selectedRowID == rowID { return }
            guard snapshot.isOpen, snapshot.rowLabels[rowID] != nil else {
                try? await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            if try await renderer.handleInput(.key(KeyEvent(key: .down))) != .consumed {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(selectedRowID == rowID)
    }

    func waitForConfig(
        _ predicate: @escaping @Sendable (PagerPersistedDashboard?) -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let store = PagerDashboardStore(
            configPath: home.appendingPathComponent("config.toml")
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(store.load()) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate(store.load())
    }

    func openDirect() async throws {
        try await renderer.begin()
        try await renderer.render(.global(.openDashboard))
        #expect(await waitForPaint("Agent Dashboard"))
    }
}

private func startController(for fixture: DashboardFixture) -> DashboardControllerHarness {
    let (input, continuation) = AsyncStream<InputEvent>.makeStream()
    let controller = OpenGrokPagerInteractiveController(
        input: input,
        runtime: DashboardRuntime(),
        renderer: fixture.renderer,
        output: DashboardOutput()
    )
    let task = Task {
        try await controller.run(OpenGrokPagerRequest(
            prompt: "",
            mode: .fullScreen,
            sessionID: fixture.activeID
        ))
    }
    return DashboardControllerHarness(continuation: continuation, task: task)
}

private func seedRecords(for fixture: DashboardFixture) -> [LiveConversationRecord] {
    let activeTime = Date(timeIntervalSince1970: 20_000)
    let dormantTime = Date(timeIntervalSince1970: 10_000)
    return [
        record(
            fixture.activeID,
            workingDirectory: fixture.workingDirectory,
            updatedAt: activeTime,
            items: [userItem("active prompt"), assistantItem("active response")]
        ),
        record(
            fixture.dormantID,
            workingDirectory: fixture.workingDirectory,
            updatedAt: dormantTime,
            items: [
                userItem("dormant prompt"),
                assistantItem("dormant cached transcript needle")
            ]
        ),
    ]
}

private func makeDashboardRepository() throws -> (root: URL, repository: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-dashboard-worktree-\(UUID().uuidString)")
    let repository = root.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    func git(_ arguments: [String]) throws {
        let result = try runGit(arguments, cwd: repository)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "LiveDashboardReachabilityTests",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
    }
    try git(["init", "--quiet"])
    try "dashboard\n".write(
        to: repository.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    try git(["add", "README.md"])
    try git([
        "-c", "user.email=test@example.com", "-c", "user.name=Test",
        "commit", "--quiet", "-m", "initial",
    ])
    return (root, repository)
}

@Suite("Live dashboard orchestration", .serialized)
struct LiveDashboardReachabilityTests {
    @Test("open gate honors env and persisted disable, then hydrates dormant rows")
    func openGateAndHydration() async throws {
        let envFixture = try DashboardFixture(environment: ["GROK_AGENT_DASHBOARD": "0"])
        defer { envFixture.dispose() }
        try await envFixture.renderer.begin()
        try await envFixture.renderer.render(.global(.openDashboard))
        #expect(await envFixture.waitForPaint("GROK_AGENT_DASHBOARD=0"))
        #expect(!(await envFixture.renderer.dashboardSnapshotForTesting().isOpen))
        try await envFixture.renderer.restoreTerminal()

        let disabledFixture = try DashboardFixture(
            config: "[dashboard]\nenabled = false\n"
        )
        defer { disabledFixture.dispose() }
        try await disabledFixture.renderer.begin()
        try await disabledFixture.renderer.render(.global(.openDashboard))
        #expect(await disabledFixture.waitForPaint("enabled = false"))
        #expect(!(await disabledFixture.renderer.dashboardSnapshotForTesting().isOpen))
        try await disabledFixture.renderer.restoreTerminal()

        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        let harness = startController(for: fixture)
        harness.continuation.yield(.paste("/dashboard"))
        harness.continuation.yield(.key(KeyEvent(key: .escape)))
        harness.continuation.yield(.key(KeyEvent(key: .enter)))
        #expect(await fixture.waitForPaint("Agent Dashboard"))
        #expect(await fixture.waitForPaint("dormant prompt"))
        #expect(await fixture.waitForPaint("inactive"))
        #expect(await fixture.renderer.dashboardSnapshotForTesting().dormantSessionIDs.contains(fixture.dormantID))
        let rowIDs = await fixture.dashboardRows().map(\.id)
        #expect(rowIDs.contains(LiveDashboardOverlay.attachPrefix + fixture.activeID))
        #expect(rowIDs.contains(LiveDashboardOverlay.attachPrefix + fixture.dormantID))
        harness.continuation.finish()
        let result = try await harness.task.value
        #expect(result.lifecycle == .eof)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("controller-routed Ctrl+T and live grouping command persist dashboard state")
    func pinAndGroupingPersistence() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        let harness = startController(for: fixture)
        harness.continuation.yield(.paste("/dashboard"))
        harness.continuation.yield(.key(KeyEvent(key: .escape)))
        harness.continuation.yield(.key(KeyEvent(key: .enter)))
        #expect(await fixture.waitForPaint("Agent Dashboard"))

        let activeID = fixture.activeID
        try await fixture.selectDashboardRow(LiveDashboardOverlay.attachPrefix + activeID)
        harness.continuation.yield(ctrlKey("t"))
        #expect(await fixture.waitForConfig { persisted in
            persisted?.pinned == [.topLevel(sessionID: activeID)]
        })

        try await fixture.renderer.render(.global(.toggleTasks))
        #expect(await fixture.waitForConfig { persisted in
            persisted?.grouping == .directory
        })
        let persisted = PagerDashboardStore(
            configPath: fixture.home.appendingPathComponent("config.toml")
        ).load()
        #expect(persisted?.pinned == [.topLevel(sessionID: activeID)])
        #expect(persisted?.grouping == .directory)

        harness.continuation.finish()
        let result = try await harness.task.value
        #expect(result.lifecycle == .eof)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Ctrl+/ search keeps its filter on Enter and Esc clears before dismissal")
    func searchRouting() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        try await fixture.openDirect()

        #expect(try await fixture.renderer.handleInput(ctrlKey("/")) == .consumed)
        #expect(try await fixture.renderer.handleInput(key("d")) == .consumed)
        #expect(await fixture.renderer.dashboardSnapshotForTesting().searchQuery == "d")
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter))) == .consumed)
        let afterEnter = await fixture.renderer.dashboardSnapshotForTesting()
        #expect(afterEnter.isOpen)
        #expect(afterEnter.searchQuery == nil)
        #expect(await fixture.waitForPaint("filtered"))

        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)
        let afterClear = await fixture.renderer.dashboardSnapshotForTesting()
        #expect(afterClear.isOpen)
        #expect(afterClear.searchQuery == nil)
        #expect(await fixture.waitForPaint("New session"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("dashboard selection follows a dormant cached transcript")
    func selectionFollowingPeek() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        try await fixture.openDirect()

        let dormantRowID = LiveDashboardOverlay.attachPrefix + fixture.dormantID
        try await fixture.selectDashboardRow(dormantRowID)
        #expect(await fixture.waitForPaint("dormant cached transcript needle"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("active x refuses and dormant x arms then deletes with persistence GC")
    func closeBehavior() async throws {
        let activeFixture = try DashboardFixture()
        defer { activeFixture.dispose() }
        try await activeFixture.seed(seedRecords(for: activeFixture))
        try await activeFixture.openDirect()

        let activeURL = activeFixture.home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(activeFixture.activeID)
            .appendingPathExtension("json")
        #expect(FileManager.default.fileExists(atPath: activeURL.path))
        try await activeFixture.selectDashboardRow(
            LiveDashboardOverlay.attachPrefix + activeFixture.activeID
        )
        #expect(try await activeFixture.renderer.handleInput(ctrlKey("x")) == .consumed)
        #expect(await activeFixture.renderer.dashboardSnapshotForTesting().isOpen)
        #expect(FileManager.default.fileExists(atPath: activeURL.path))
        try await activeFixture.renderer.restoreTerminal()

        let deletionFixture = try DashboardFixture(config: """
        [dashboard]
        enabled = true
        pinned = ["top:dormant-session"]
        reorder = ["top:dormant-session"]
        """)
        defer { deletionFixture.dispose() }
        try await deletionFixture.seed(seedRecords(for: deletionFixture))
        try await deletionFixture.openDirect()

        let dormantURL = deletionFixture.home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(deletionFixture.dormantID)
            .appendingPathExtension("json")
        #expect(FileManager.default.fileExists(atPath: dormantURL.path))
        try await deletionFixture.selectDashboardRow(
            LiveDashboardOverlay.attachPrefix + deletionFixture.dormantID
        )

        #expect(try await deletionFixture.renderer.handleInput(ctrlKey("x")) == .consumed)
        #expect(FileManager.default.fileExists(atPath: dormantURL.path))
        #expect(try await deletionFixture.renderer.handleInput(ctrlKey("x")) == .consumed)
        #expect(await deletionFixture.waitForConfig { persisted in
            persisted?.pinned.isEmpty == true && persisted?.reorder.isEmpty == true
        })
        #expect(!FileManager.default.fileExists(atPath: dormantURL.path))
        try await deletionFixture.renderer.restoreTerminal()
    }

    @Test("dashboard dismissal releases cached, dormant, and search state")
    func dismissalCleanup() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        try await fixture.openDirect()

        #expect(try await fixture.renderer.handleInput(ctrlKey("/")) == .consumed)
        #expect(try await fixture.renderer.handleInput(key("d")) == .consumed)
        #expect(await fixture.renderer.dashboardSnapshotForTesting().cachedSessionIDs.contains(fixture.dormantID))
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter))) == .consumed)
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)
        let clearedFilter = await fixture.renderer.dashboardSnapshotForTesting()
        #expect(clearedFilter.isOpen)
        #expect(clearedFilter.searchQuery == nil)

        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)
        let dismissed = await fixture.renderer.dashboardSnapshotForTesting()
        #expect(!dismissed.isOpen)
        #expect(dismissed.searchQuery == nil)
        #expect(dismissed.cachedSessionIDs.isEmpty)
        #expect(dismissed.dormantSessionIDs.isEmpty)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("bare slash edits the dashboard prompt while Ctrl+/ remains search")
    func bareSlashIsDispatchText() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        try await fixture.openDirect()

        #expect(try await fixture.renderer.handleInput(key("/")) == .consumed)
        let composing = await fixture.renderer.dashboardSnapshotForTesting()
        #expect(composing.searchQuery == nil)
        #expect(composing.inputText == "/")

        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)
        #expect(try await fixture.renderer.handleInput(ctrlKey("/")) == .consumed)
        let searching = await fixture.renderer.dashboardSnapshotForTesting()
        #expect(searching.searchQuery == "")
        #expect(searching.inputText.isEmpty)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("typed text replies to an explicit retained row and the default row dispatches a new one")
    func replyAndNewDispatchRouting() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        try await fixture.openDirect()

        try await fixture.selectDashboardRow(
            LiveDashboardOverlay.attachPrefix + fixture.activeID
        )
        try await typeDashboardText("reply now", into: fixture.renderer)
        #expect(
            try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
                == .dispatchPrompt(sessionID: fixture.activeID, prompt: "reply now")
        )

        try await fixture.renderer.render(.global(.openDashboard))
        #expect(
            await fixture.renderer.dashboardSnapshotForTesting().selectedRowID
                == LiveDashboardOverlay.newAgentRowID
        )
        try await typeDashboardText("new task", into: fixture.renderer)
        #expect(
            try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
                == .dispatchNew(prompt: "new task", workingDirectory: fixture.home.path)
        )
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Ctrl+R commits an inline persisted rename")
    func inlineRename() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        try await fixture.openDirect()

        try await fixture.selectDashboardRow(
            LiveDashboardOverlay.attachPrefix + fixture.activeID
        )
        #expect(try await fixture.renderer.handleInput(ctrlKey("r")) == .consumed)
        try await typeDashboardText("renamed active", into: fixture.renderer)
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter))) == .consumed)
        let stored = try await LiveConversationStore(openGrokHome: fixture.home)
            .load(sessionID: fixture.activeID)
        #expect(stored.title == "renamed active")
        let renamedLabel = await fixture.renderer.dashboardSnapshotForTesting().rowLabels[
            LiveDashboardOverlay.attachPrefix + fixture.activeID
        ]
        #expect(renamedLabel?.contains("renamed active") == true)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("dashboard question mode resolves the real coordinator")
    func questionMode() async throws {
        let coordinator = PagerQuestionCoordinator()
        let fixture = try DashboardFixture(questionCoordinator: coordinator)
        defer { fixture.dispose() }
        try await fixture.seed(seedRecords(for: fixture))
        try await fixture.openDirect()
        try await fixture.selectDashboardRow(
            LiveDashboardOverlay.attachPrefix + fixture.activeID
        )

        let request = PagerQuestionRequest(
            id: "dashboard-question",
            toolCallID: "call-dashboard-question",
            questions: [PagerQuestion(
                text: "Choose release timing",
                options: [
                    PagerQuestionOption(label: "Ship now"),
                    PagerQuestionOption(label: "Hold"),
                ]
            )]
        )
        let waiter = Task { await coordinator.answers(for: request) }
        #expect(await fixture.waitForPaint("Choose release timing"))
        #expect(try await fixture.renderer.handleInput(key("2")) == .consumed)
        #expect(
            await waiter.value == .answered([
                PagerQuestionAnswer(question: "Choose release timing", label: "Hold")
            ])
        )
        #expect(await fixture.renderer.dashboardSnapshotForTesting().isOpen)
        #expect(await coordinator.pendingCount == 0)

        let multiRequest = PagerQuestionRequest(
            id: "dashboard-multi-question",
            toolCallID: "call-dashboard-multi-question",
            questions: [PagerQuestion(
                text: "Choose several",
                options: [
                    PagerQuestionOption(label: "A"),
                    PagerQuestionOption(label: "B"),
                ],
                isMultiSelect: true
            )]
        )
        let multiWaiter = Task { await coordinator.answers(for: multiRequest) }
        #expect(await fixture.waitForPaint("Choose several"))
        #expect(try await fixture.renderer.handleInput(key("1")) == .consumed)
        #expect(await coordinator.pendingCount == 1)
        #expect(await fixture.renderer.dashboardSnapshotForTesting().isOpen)
        await coordinator.resolveAll()
        #expect(await multiWaiter.value == .cancelled)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("dashboard worktree dialog dispatches through the shared registry")
    func worktreeDispatch() async throws {
        let repository = try makeDashboardRepository()
        defer { try? FileManager.default.removeItem(at: repository.root) }
        let fixture = try DashboardFixture(workingDirectory: repository.repository)
        defer { fixture.dispose() }
        let processDirectory = FileManager.default.currentDirectoryPath
        try await fixture.openDirect()

        #expect(try await fixture.renderer.handleInput(ctrlKey("w")) == .consumed)
        #expect(
            await fixture.renderer.dashboardSnapshotForTesting().rowLabels[
                LiveDashboardOverlay.newAgentRowID
            ] == "+ New worktree"
        )
        try await typeDashboardText("isolated task", into: fixture.renderer)
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter))) == .consumed)
        try await typeDashboardText("dashboard-wt", into: fixture.renderer)
        let routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        guard case .dispatchNew(let prompt, let workingDirectory) = routing else {
            Issue.record("expected dashboard worktree dispatch")
            return
        }
        let worktreeDirectory = try #require(workingDirectory)
        #expect(prompt == "isolated task")
        #expect(worktreeDirectory != repository.repository.path)
        #expect(FileManager.default.fileExists(atPath: worktreeDirectory))
        #expect(FileManager.default.currentDirectoryPath == processDirectory)

        var records = try WorktreeRegistry(openGrokHome: fixture.home).records()
        #expect(records.count == 1)
        #expect(records[0].label == "dashboard-wt")
        #expect(records[0].sessionID == nil)
        try await fixture.renderer.render(.sessionReplaced(sessionID: "dashboard-worktree-session"))
        records = try WorktreeRegistry(openGrokHome: fixture.home).records()
        #expect(records[0].sessionID == "dashboard-worktree-session")
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/cd opens the location picker and a path updates dashboard dispatch cwd")
    func locationPickerAndSetWorkingDir() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.dispose() }
        let processDirectory = FileManager.default.currentDirectoryPath
        defer {
            let restored = FileManager.default.changeCurrentDirectoryPath(processDirectory)
            if !restored { Issue.record("could not restore process working directory") }
        }
        try await fixture.seed(seedRecords(for: fixture))
        let destination = fixture.home.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await fixture.openDirect()

        #expect(try await fixture.renderer.handleInput(ctrlKey("l")) == .consumed)
        #expect(await fixture.renderer.lastOverlayBounds.contains { $0.id == "dashboard-location" })
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)

        try await typeDashboardText("/cd", into: fixture.renderer)
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter))) == .consumed)
        #expect(await fixture.renderer.lastOverlayBounds.contains { $0.id == "dashboard-location" })
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)

        try await typeDashboardText("/cd \(destination.path)", into: fixture.renderer)
        #expect(try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter))) == .consumed)
        #expect(
            await fixture.renderer.dashboardSnapshotForTesting().dispatchWorkingDirectory
                == destination.standardizedFileURL.path
        )
        try await fixture.renderer.restoreTerminal()
    }
}
