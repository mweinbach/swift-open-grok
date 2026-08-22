import Foundation
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

private struct LiveSessionFoundationDiskFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-session-foundation-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func record(id: String, title: String? = nil) -> LiveConversationRecord {
        var record = LiveConversationRecord.new(sessionID: id, workingDirectory: workspace)
        record.items = [
            .user("inspect the durable session"),
            .assistant(AssistantItem(
                content: "checking the file",
                toolCalls: [ToolCall(
                    id: "call-1",
                    name: "read_durable_artifact",
                    arguments: #"{"path":"src/extraordinary-ledger.swift"}"#
                )]
            )),
            .toolResult(ToolResultItem(toolCallId: "call-1", content: "exact result")),
        ]
        record.currentModelID = "grok-4.5"
        record.currentProvider = .xai
        record.title = title
        return record
    }

    func mirrorURL(_ sessionID: String) -> URL {
        home.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
    }
}

private struct LiveSessionFoundationTurnFixture {
    let disk: LiveSessionFoundationDiskFixture
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        disk = try LiveSessionFoundationDiskFixture()
        server = try MockInferenceServer()
        try """
        [endpoints]
        xai_api_base_url = "\(server.url)"
        """.write(
            to: disk.home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": disk.home.path,
            "OPENGROK_HOME": disk.home.path,
            "XDG_STATE_HOME": disk.home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
    }

    func cleanup() {
        server.stop()
        disk.cleanup()
    }

    func options() throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "hello", "--cwd", disk.workspace.path,
            "--model", "grok-4.5",
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("foundation fixture did not parse a launch")
        }
        return options
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }
}

private actor LiveSessionFoundationFailingSampler {
    let failureRound: Int
    private(set) var requests: [OpenGrokLiveSamplingRequest] = []

    init(failureRound: Int) {
        self.failureRound = failureRound
    }

    func sample(_ request: OpenGrokLiveSamplingRequest) throws -> OpenGrokLiveSamplingResponse {
        if request.turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compacted summary")
        }
        requests.append(request)
        if requests.count >= failureRound {
            throw SamplingError.api(
                status: HTTPStatus(500),
                message: "provider exploded",
                modelMetadata: nil,
                retryAfterSecs: nil,
                shouldRetry: false
            )
        }
        return OpenGrokLiveSamplingResponse(
            output: "checking the task",
            toolCalls: [ToolCall(
                id: "durable-tool",
                name: "todo_write",
                arguments: #"{"todos":[{"id":"one","content":"persist the task","status":"pending"}]}"#
            )]
        )
    }
}

private actor LiveSessionFoundationOutputCollector {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@Suite("Live session foundation parity", .serialized)
struct LiveSessionFoundationParityTests {
    @Test("live saves publish canonical Rust session documents and replayable ACP updates")
    func liveSavePublishesCanonicalDocuments() async throws {
        let fixture = try LiveSessionFoundationDiskFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(id: "canonical-save", title: "Durable session")
        let liveStore = LiveConversationStore(openGrokHome: fixture.home)
        let documents = SessionDocumentStore(grokHome: fixture.home)

        try await liveStore.save(record)

        let directory = try documents.sessionDirectory(
            sessionID: record.sessionID,
            cwd: fixture.workspace.path
        )
        let summary = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("summary.json"))
        ) as? [String: Any])
        let info = try #require(summary["info"] as? [String: Any])
        #expect(info["id"] as? String == record.sessionID)
        #expect(info["cwd"] as? String == fixture.workspace.path)
        #expect(summary["num_chat_messages"] as? Int == 3)
        #expect(summary["num_messages"] as? Int == 4)
        #expect(summary["generated_title"] as? String == "Durable session")
        #expect(summary["title_is_manual"] as? Bool == true)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("events.jsonl").path
        ))
        #expect(FileManager.default.fileExists(atPath: fixture.mirrorURL(record.sessionID).path))

        let persisted = try #require(try documents.load(sessionID: record.sessionID))
        let tags = persisted.updates.compactMap {
            $0.params.objectValue?["update"]?.objectValue?["sessionUpdate"]?.stringValue
        }
        #expect(tags == [
            "user_message_chunk", "agent_message_chunk", "tool_call", "tool_call_update",
        ])
        #expect(persisted.updates.allSatisfy { $0.method == "session/update" })
        #expect(try await liveStore.load(sessionID: record.sessionID).items == record.items)
    }

    @Test("canonical-only sessions remain visible, searchable, and resumable by title")
    func catalogFindsCanonicalOnlySessions() async throws {
        let fixture = try LiveSessionFoundationDiskFixture()
        defer { fixture.cleanup() }
        let store = LiveConversationStore(openGrokHome: fixture.home)
        let first = fixture.record(id: "canonical-only", title: "Investigate ledger")
        try await store.save(first)
        try FileManager.default.removeItem(at: fixture.mirrorURL(first.sessionID))

        let catalog = LiveSessionCatalog(openGrokHome: fixture.home)
        #expect(try catalog.list().map(\.sessionID) == [first.sessionID])
        #expect(try catalog.records().map(\.sessionID) == [first.sessionID])
        #expect(try catalog.load(sessionID: first.sessionID)?.model == "grok-4.5")
        let documents = try catalog.documents()
        #expect(LiveSessionSearch.rank(
            documents: documents,
            query: "extraordinary-ledger",
            limit: 10
        ).map(\.sessionID) == [first.sessionID])
        #expect(try LiveSessionTitleResolver.resolve(
            value: "investigate ledger",
            in: catalog.list(),
            workingDirectory: fixture.workspace
        ) == first.sessionID)

        var second = fixture.record(id: "canonical-duplicate", title: "Investigate ledger")
        second.updatedAt = first.updatedAt.addingTimeInterval(1)
        try await store.save(second)
        do {
            _ = try LiveSessionTitleResolver.resolve(
                value: "Investigate ledger",
                in: catalog.list(),
                workingDirectory: fixture.workspace
            )
            Issue.record("an ambiguous canonical session title resolved to an arbitrary session")
        } catch LiveSessionResolveFailure.ambiguous(_, let candidates) {
            #expect(candidates == ["canonical-duplicate", "canonical-only"])
        }
    }

    @Test("canonical documents override stale compatibility mirrors without duplicate rows")
    func canonicalAuthorityBeatsStaleMirror() async throws {
        let fixture = try LiveSessionFoundationDiskFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(id: "canonical-authority", title: "Canonical truth")
        let store = LiveConversationStore(openGrokHome: fixture.home)
        try await store.save(record)

        var stale = record
        stale.title = "Stale compatibility mirror"
        stale.items = [.user("stale history")]
        try JSONEncoder().encode(stale).write(to: fixture.mirrorURL(record.sessionID))

        let loaded = try await store.load(sessionID: record.sessionID)
        #expect(loaded.title == "Canonical truth")
        #expect(loaded.items == record.items)
        let listings = try LiveSessionCatalog(openGrokHome: fixture.home).list()
        #expect(listings.count == 1)
        #expect(listings.first?.title == "Canonical truth")
    }

    @Test("legacy migration keeps unknown export boundaries fail closed and can upgrade safely")
    func legacyMigrationPreservesExportBoundary() async throws {
        let fixture = try LiveSessionFoundationDiskFixture()
        defer { fixture.cleanup() }
        var legacy = fixture.record(id: "legacy-boundary")
        legacy.everUsedNonXAI = nil
        let mirror = fixture.mirrorURL(legacy.sessionID)
        try FileManager.default.createDirectory(
            at: mirror.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(legacy).write(to: mirror)

        let store = LiveConversationStore(openGrokHome: fixture.home)
        let loadedLegacy = try await store.load(sessionID: legacy.sessionID)
        #expect(loadedLegacy.everUsedNonXAI == nil)
        let documents = SessionDocumentStore(grokHome: fixture.home)
        let migrated = try #require(try documents.load(sessionID: legacy.sessionID))
        #expect(migrated.summary.extra["swift_legacy_export_boundary_missing"] == .bool(true))
        do {
            _ = try await store.fork(
                sourceSessionID: legacy.sessionID,
                destinationSessionID: "unsafe-fork",
                workingDirectory: fixture.workspace
            )
            Issue.record("fork accepted a legacy session with an unknown export boundary")
        } catch {
            #expect(String(describing: error).contains("export-boundary"))
        }

        legacy.everUsedNonXAI = false
        try await store.save(legacy)
        #expect(try await store.load(sessionID: legacy.sessionID).everUsedNonXAI == false)
        let child = try await store.fork(
            sourceSessionID: legacy.sessionID,
            destinationSessionID: "safe-fork",
            workingDirectory: fixture.workspace
        )
        #expect(child.sessionKind == "fork")
        let parentState = try #require(try documents.load(sessionID: legacy.sessionID))
        let childState = try #require(try documents.load(sessionID: child.sessionID))
        #expect(childState.summary.extra["cache_affinity_id"]
            == parentState.summary.extra["cache_affinity_id"])
        #expect(child.cacheAffinityID == parentState.summary.extra["cache_affinity_id"]?.stringValue)
        #expect(childState.updates.allSatisfy {
            $0.params.objectValue?["sessionId"]?.stringValue == child.sessionID
        })
    }

    @Test("delete removes canonical documents, compatibility state, goals, and rewind snapshots")
    func deleteRemovesEverySessionRepresentation() async throws {
        let fixture = try LiveSessionFoundationDiskFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(id: "delete-everything")
        let store = LiveConversationStore(openGrokHome: fixture.home)
        let documents = SessionDocumentStore(grokHome: fixture.home)
        try await store.save(record)
        let canonical = try documents.sessionDirectory(
            sessionID: record.sessionID,
            cwd: fixture.workspace.path
        )
        let legacy = fixture.home.appendingPathComponent("sessions")
            .appendingPathComponent(record.sessionID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("goals"),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("state.json"))
        let rewind = LiveRewindStore.rewindFileURL(
            openGrokHome: fixture.home,
            sessionID: record.sessionID
        )
        try Data("private source snapshot\n".utf8).write(to: rewind)

        let catalog = LiveSessionCatalog(openGrokHome: fixture.home)
        #expect(try catalog.delete(sessionID: record.sessionID))
        #expect(!FileManager.default.fileExists(atPath: canonical.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.mirrorURL(record.sessionID).path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: rewind.path))
        #expect(try catalog.delete(sessionID: record.sessionID) == false)
    }

    @Test("subagent sessions remain hidden while explicitly unhidden sessions remain visible")
    func subagentVisibilityUsesCanonicalKind() async throws {
        let fixture = try LiveSessionFoundationDiskFixture()
        defer { fixture.cleanup() }
        var record = fixture.record(id: "hidden-child")
        record.parentSessionID = "parent"
        record.sessionKind = "subagent_background"
        let store = LiveConversationStore(openGrokHome: fixture.home)
        try await store.save(record)
        let catalog = LiveSessionCatalog(openGrokHome: fixture.home)
        #expect(try catalog.list().isEmpty)
        #expect(try await store.latest(workingDirectory: fixture.workspace) == nil)
        #expect(try await store.load(sessionID: record.sessionID).sessionKind == "subagent_background")

        let documents = SessionDocumentStore(grokHome: fixture.home)
        var state = try #require(try documents.load(sessionID: record.sessionID))
        state.summary.extra["hidden"] = .bool(false)
        try documents.save(state)
        #expect(try catalog.list().map(\.sessionID) == [record.sessionID])
    }

    @Test("a missing chat cache recovers exact user, assistant, tool call, and result")
    func missingChatHistoryRecoversFromLiveUpdates() async throws {
        let fixture = try LiveSessionFoundationDiskFixture()
        defer { fixture.cleanup() }
        let record = fixture.record(id: "recover-chat")
        let store = LiveConversationStore(openGrokHome: fixture.home)
        try await store.save(record)
        let documents = SessionDocumentStore(grokHome: fixture.home)
        let directory = try documents.sessionDirectory(
            sessionID: record.sessionID,
            cwd: fixture.workspace.path
        )
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("chat_history.jsonl")
        )

        let recovered = try await store.load(sessionID: record.sessionID)
        #expect(recovered.items == record.items)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("chat_history.jsonl").path
        ))
    }

    @Test("rewind snapshots are durable before endPrompt returns")
    func rewindEndPromptWaitsForDurability() async throws {
        let fixture = try LiveSessionFoundationDiskFixture()
        defer { fixture.cleanup() }
        let source = fixture.workspace.appendingPathComponent("main.swift")
        try Data("before".utf8).write(to: source)
        let rewind = await LiveRewindCoordinator(
            openGrokHome: fixture.home,
            sessionID: "rewind-durable",
            workingDirectory: fixture.workspace
        )
        await rewind.beginPrompt(text: "edit source")
        await rewind.capture(paths: ["main.swift"])
        try Data("after".utf8).write(to: source)

        await rewind.endPrompt()

        let points = await rewind.points()
        #expect(points.count == 1)
        #expect(points.first?.fileCount == 1)
    }

    @Test("provider failure before sampling still leaves the submitted prompt durable")
    func firstProviderFailureRetainsPrompt() async throws {
        try await assertFailedTurnRetainsProgress(failureRound: 1, expectsTool: false)
    }

    @Test("provider failure after a tool still leaves the assistant call and result durable")
    func laterProviderFailureRetainsToolResults() async throws {
        try await assertFailedTurnRetainsProgress(failureRound: 2, expectsTool: true)
    }

    @Test("unstreamed final assistant text is emitted once and streamed text is never duplicated")
    func finalAssistantTextFallbackIsExact() async throws {
        let fixture = try LiveSessionFoundationTurnFixture()
        defer { fixture.cleanup() }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, emit in
                    if request.turnID == "already-streamed" {
                        await emit(.output("streamed final answer"))
                        return OpenGrokLiveSamplingResponse(output: "streamed final answer")
                    }
                    return OpenGrokLiveSamplingResponse(output: "unstreamed final answer")
                }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.options(),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )
        let shell = stack.shell
        _ = try await shell.start()
        let sessionID = SessionID(foundation.sessionID)
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))
        let events = await shell.events()
        let output = LiveSessionFoundationOutputCollector()
        let observe = Task {
            for try await event in events {
                switch event {
                case .turnUpdate(let update):
                    if case .assistantText(let text) = update.kind {
                        await output.append(text)
                    }
                case .turnCompleted(let result) where result.turnID == "already-streamed":
                    return
                case .turnFailed:
                    return
                default:
                    continue
                }
            }
        }

        let first = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: "first",
                text: "show the final response",
                turnID: "not-streamed"
            )
        )
        _ = try await shell.waitForTurn(first, timeout: ShellDuration(timeInterval: 30))
        let second = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: "second",
                text: "do not duplicate the stream",
                turnID: "already-streamed"
            )
        )
        _ = try await shell.waitForTurn(second, timeout: ShellDuration(timeInterval: 30))
        try await observe.value
        #expect(await output.values == ["unstreamed final answer", "streamed final answer"])

        _ = await shell.shutdown()
        await foundation.toolExecutor.shutdown()
    }

    @Test("resume restores canonical shell metadata before recreating the live session")
    func resumeRestoresCanonicalState() async throws {
        let fixture = try LiveSessionFoundationTurnFixture()
        defer { fixture.cleanup() }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "done") }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.options(),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )
        var record = fixture.disk.record(id: "resume-canonical", title: "Recovered session")
        record.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await foundation.conversationStore.save(record)
        let documents = SessionDocumentStore(grokHome: fixture.disk.home)
        var state = try #require(try documents.load(sessionID: record.sessionID))
        state.summary.nextTraceTurn = 47
        state.summary.extra["cwd_generation"] = .number(.uint64(3))
        try documents.save(state)

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
        #expect(try await adapter.resumeSession(sessionID: record.sessionID) == record.sessionID)
        let descriptor = await stack.shell.lookupSession(SessionID(record.sessionID))
        #expect(descriptor?.createdAt == record.createdAt)
        let auxiliary = try #require(try await SessionStateStore(root: fixture.disk.home)
            .load(sessionID: SessionID(record.sessionID)))
        #expect(auxiliary.summary.nextTraceTurn == 47)
        #expect(auxiliary.summary.extra["cwd_generation"]?.uint64Value == 3)

        _ = await stack.shell.shutdown()
        await foundation.toolExecutor.shutdown()
    }

    private func assertFailedTurnRetainsProgress(
        failureRound: Int,
        expectsTool: Bool
    ) async throws {
        let fixture = try LiveSessionFoundationTurnFixture()
        defer { fixture.cleanup() }
        let sampler = LiveSessionFoundationFailingSampler(failureRound: failureRound)
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    try await sampler.sample(request)
                }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.options(),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )
        let shell = stack.shell
        _ = try await shell.start()
        let sessionID = SessionID(foundation.sessionID)
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: "durable-prompt",
                text: "never lose this prompt",
                turnID: "durable-turn"
            )
        )
        do {
            _ = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 30))
            Issue.record("the failing provider incorrectly completed its turn")
        } catch OpenGrokShellError.turnFailed(let message) {
            #expect(message.contains("provider exploded"))
        }

        let record = try await LiveConversationStore(openGrokHome: fixture.disk.home)
            .load(sessionID: foundation.sessionID)
        #expect(record.items.contains { item in
            guard case .user(let user) = item else { return false }
            return user.content == [.text(text: "never lose this prompt")]
        })
        if expectsTool {
            #expect(record.items.contains { item in
                guard case .assistant(let assistant) = item else { return false }
                return assistant.toolCalls.map(\.id) == ["durable-tool"]
            })
            #expect(record.items.contains { item in
                guard case .toolResult(let result) = item else { return false }
                return result.toolCallId == "durable-tool"
            })
            #expect(await sampler.requests.count == 2)
        }
        let sampledRequests = await sampler.requests
        #expect(sampledRequests.allSatisfy {
            $0.sessionID == foundation.sessionID && $0.cacheAffinityID == foundation.sessionID
        })

        _ = await shell.shutdown()
        await foundation.toolExecutor.shutdown()
    }
}
