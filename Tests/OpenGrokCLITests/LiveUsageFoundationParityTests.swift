import Foundation
import OpenGrokAgentCoordinator
import OpenGrokChatState
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing

@testable import OpenGrokCLI

private actor UsageFoundationShellBackend: ShellProcessBackend {
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

private enum UsageFoundationScriptError: Error {
    case responsesExhausted
}

private final class UsageFoundationSamplingScript: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [OpenGrokLiveSamplingResponse]
    private var requests: [OpenGrokLiveSamplingRequest] = []

    init(responses: [OpenGrokLiveSamplingResponse]) {
        self.responses = responses
    }

    func next(_ request: OpenGrokLiveSamplingRequest) throws -> OpenGrokLiveSamplingResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !responses.isEmpty else {
            throw UsageFoundationScriptError.responsesExhausted
        }
        return responses.removeFirst()
    }

    func requestSnapshot() -> [OpenGrokLiveSamplingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private struct UsageFoundationFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let store: LiveConversationStore
    let history: LiveConversationHistory
    let host: LiveSubagentHost
    let script: UsageFoundationSamplingScript

    init(responses: [OpenGrokLiveSamplingResponse]) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-usage-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]
        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(sessionID: "usage-root", workingDirectory: workspace)
        record.currentModelID = "grok-4.5"
        record.currentProvider = .xai
        let samplingConfig = SamplingConfig(
            baseURL: "https://api.example.invalid/v1",
            model: "grok-4.5",
            provider: .xai,
            contextWindow: 128_000
        )
        let history = LiveConversationHistory(
            record: record,
            store: store,
            samplingConfig: samplingConfig
        )
        try await store.save(record)

        let script = UsageFoundationSamplingScript(responses: responses)
        let sampler = OpenGrokLiveSampler { request, _ in
            try script.next(request)
        }
        let securityContext = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false
        )
        let host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: "grok-4.5",
            workingDirectory: workspace,
            sessionID: "usage-root",
            openGrokHome: home,
            conversationStore: store,
            processBackend: UsageFoundationShellBackend(),
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
            environment: environment,
            parentCapabilityCeiling: nil,
            definitionContext: DefinitionResolutionContext(
                cwd: workspace,
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: ["grok-4.5", "gpt-5.4"],
            parentProvider: .xai,
            childSamplerFactory: { _, _ in
                LiveSubagentHost.ChildSamplerRoute(sampler: sampler, provider: .codex)
            }
        ))
        await host.installParentUsageHistory(history)

        self.root = root
        self.home = home
        self.workspace = workspace
        self.store = store
        self.history = history
        self.host = host
        self.script = script
    }

    func spawn(
        id: String,
        promptID: String,
        model: String? = nil
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        var arguments: [String: JSONValue] = [
            "task_id": .string(id),
            "prompt": .string("Report exact provider usage"),
            "description": .string("Audit child provider usage"),
            "subagent_type": .string("general-purpose"),
            "background": .bool(false),
        ]
        if let model {
            arguments["model"] = .string(model)
        }
        return await LiveSubagentParentPromptContext.$promptID.withValue(promptID) {
            await host.spawn(args: .object(arguments), toolCallID: "usage-call-\(id)")
        }
    }

    func dispose() async {
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live usage accounting foundation", .serialized)
struct LiveUsageFoundationParityTests {
    @Test("durable usage snapshots retain cache writes, exact cost, and missing-cost truth")
    func usageSnapshotRoundTripsWithoutLosingBillingTruth() throws {
        let ledger = UsageLedger()
        ledger.recordMainLoopCall(
            modelId: "grok-4.5",
            usage: TokenUsage(
                promptTokens: 90,
                completionTokens: 12,
                totalTokens: 102,
                reasoningTokens: 4,
                cachedPromptTokens: 30,
                cacheCreationPromptTokens: 7
            ),
            apiDurationMs: 25,
            costUsdTicks: 1_250
        )
        ledger.recordSubagent(
            byModel: [(
                model: "gpt-5.4",
                totals: UsageTotals(
                    inputTokens: 20,
                    outputTokens: 6,
                    cachedReadTokens: 5,
                    reasoningTokens: 2,
                    modelCalls: 1,
                    costMissingCalls: 1,
                    cachedCreationTokens: 3
                )
            )],
            incomplete: false
        )

        let snapshot = LiveSessionUsageSnapshot(
            ledger: ledger,
            unattributedPromptIDs: ["old-turn", "old-turn"]
        )
        let restored = try JSONDecoder().decode(
            LiveSessionUsageSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(restored == snapshot)
        #expect(restored.usageLedger == ledger)
        #expect(restored.totals.totalTokens == 128)
        #expect(restored.totals.cachedReadTokens == 35)
        #expect(restored.totals.cacheCreationTokens == 10)
        #expect(restored.totals.reasoningTokens == 6)
        #expect(restored.totals.costIsPartial)
        #expect(restored.trustedCostUsdTicks == nil)
        #expect(restored.mainLoopModelCalls == 1)
        #expect(restored.unattributedPromptIDs == ["old-turn"])
    }

    @Test("real cross-provider child spend folds once into its parent and canonical session")
    func childProviderUsageFoldsIntoParentAndDurableSession() async throws {
        let fixture = try await UsageFoundationFixture(responses: [
            OpenGrokLiveSamplingResponse(
                output: "provider usage captured",
                usage: TokenUsage(
                    promptTokens: 100,
                    completionTokens: 20,
                    totalTokens: 999,
                    reasoningTokens: 5,
                    cachedPromptTokens: 35,
                    cacheCreationPromptTokens: 7
                ),
                costUsdTicks: 2_000
            )
        ])
        defer { Task { await fixture.dispose() } }

        await fixture.history.beginUsagePrompt("parent-turn")
        try await fixture.history.recordMainUsage(
            modelID: "grok-4.5",
            usage: TokenUsage(
                promptTokens: 40,
                completionTokens: 10,
                totalTokens: 50,
                reasoningTokens: 3,
                cachedPromptTokens: 8,
                cacheCreationPromptTokens: 2
            ),
            costUsdTicks: 1_000
        )

        let result = await fixture.spawn(
            id: "metered-child",
            promptID: "parent-turn",
            model: "gpt-5.4"
        )
        guard case .success = result else {
            Issue.record("metered child did not complete: \(result)")
            return
        }

        let session = try #require(await fixture.history.usageSnapshot)
        #expect(session.totals.inputTokens == 140)
        #expect(session.totals.outputTokens == 30)
        #expect(session.totals.totalTokens == 170)
        #expect(session.totals.cachedReadTokens == 43)
        #expect(session.totals.cacheCreationTokens == 9)
        #expect(session.totals.reasoningTokens == 8)
        #expect(session.totals.modelCalls == 2)
        #expect(session.mainLoopModelCalls == 1)
        #expect(session.trustedCostUsdTicks == 3_000)
        #expect(!session.incomplete)
        #expect(session.models.map(\.modelID) == ["grok-4.5", "gpt-5.4"])

        let completed = try #require(
            await fixture.host.coordinator.listCompleted().first {
                $0.request.id == "metered-child"
            }
        )
        #expect(try #require(completed.result).tokensUsed == 120)

        let reloaded = try await fixture.store.load(sessionID: "usage-root")
        #expect(reloaded.usageSnapshot == session)

        let directory = try SessionDocumentStore(grokHome: fixture.home).sessionDirectory(
            sessionID: "usage-root",
            cwd: fixture.workspace.path
        )
        let summary = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("summary.json"))
        ) as? [String: Any])
        let persistedUsage = try #require(summary["session_usage"] as? [String: Any])
        let persistedTotals = try #require(persistedUsage["totals"] as? [String: Any])
        #expect(persistedTotals["cacheCreationTokens"] as? Int == 9)
        #expect(persistedTotals["costUsdTicks"] as? Int == 3_000)
    }

    @Test("a child response without provider usage contributes no invented tokens or cost")
    func unmeteredChildFailsClosedWithoutCharacterEstimates() async throws {
        let fixture = try await UsageFoundationFixture(responses: [
            OpenGrokLiveSamplingResponse(
                output: String(repeating: "this output must never become billed tokens ", count: 8)
            )
        ])
        defer { Task { await fixture.dispose() } }

        await fixture.history.beginUsagePrompt("unmetered-turn")
        try await fixture.history.recordMainUsage(
            modelID: "grok-4.5",
            usage: TokenUsage(promptTokens: 12, completionTokens: 3, totalTokens: 15),
            costUsdTicks: 750
        )
        let result = await fixture.spawn(id: "unmetered-child", promptID: "unmetered-turn")
        guard case .success = result else {
            Issue.record("unmetered child should complete with an incomplete bill: \(result)")
            return
        }

        let parent = try #require(await fixture.history.usageSnapshot)
        #expect(parent.incomplete)
        #expect(parent.totals.totalTokens == 15)
        #expect(parent.trustedCostUsdTicks == nil)
        let completed = try #require(
            await fixture.host.coordinator.listCompleted().first {
                $0.request.id == "unmetered-child"
            }
        )
        #expect(try #require(completed.result).tokensUsed == 0)

        let child = try await fixture.store.load(sessionID: "unmetered-child")
        let childUsage = try #require(child.usageSnapshot)
        #expect(childUsage.incomplete)
        #expect(childUsage.totals.totalTokens == 0)
        #expect(childUsage.totals.modelCalls == 1)
    }

    @Test("a late child lands on session billing without staining the next parent turn")
    func lateChildIsSessionOnlyAndPreservesStampedPromptWarning() async throws {
        let fixture = try await UsageFoundationFixture(responses: [
            OpenGrokLiveSamplingResponse(
                output: "late child finished",
                usage: TokenUsage(promptTokens: 30, completionTokens: 5, totalTokens: 35),
                costUsdTicks: 400
            )
        ])
        defer { Task { await fixture.dispose() } }

        await fixture.history.beginUsagePrompt("old-prompt")
        await fixture.history.endUsagePrompt("old-prompt")
        await fixture.history.beginUsagePrompt("next-prompt")
        try await fixture.history.recordMainUsage(
            modelID: "grok-4.5",
            usage: TokenUsage(promptTokens: 10, completionTokens: 2, totalTokens: 12),
            costUsdTicks: 100
        )

        let result = await fixture.spawn(id: "late-child", promptID: "old-prompt")
        guard case .success = result else {
            Issue.record("late child did not complete: \(result)")
            return
        }

        let session = try #require(await fixture.history.usageSnapshot)
        #expect(session.totals.totalTokens == 47)
        #expect(session.trustedCostUsdTicks == 500)
        #expect(!session.incomplete)
        #expect(session.unattributedPromptIDs == ["old-prompt"])
        #expect(session.mainLoopModelCalls == 1)

        let restored = try await fixture.store.load(sessionID: "usage-root")
        #expect(restored.usageSnapshot?.unattributedPromptIDs == ["old-prompt"])
        #expect(restored.usageSnapshot?.incomplete == false)
    }

    @Test("child tool rounds keep one logical turn while preserving distinct wire turns")
    func childToolRoundsPreserveStickyLogicalTurnAndFoldEveryModelCall() async throws {
        let fixture = try await UsageFoundationFixture(responses: [
            OpenGrokLiveSamplingResponse(
                output: "checking the team",
                toolCalls: [ToolCall(id: "team-lookup", name: "list_agents", arguments: "{}")],
                usage: TokenUsage(promptTokens: 20, completionTokens: 5, totalTokens: 25),
                costUsdTicks: 150
            ),
            OpenGrokLiveSamplingResponse(
                output: "team inspection completed",
                usage: TokenUsage(promptTokens: 32, completionTokens: 8, totalTokens: 40),
                costUsdTicks: 250
            )
        ])
        defer { Task { await fixture.dispose() } }

        await fixture.history.beginUsagePrompt("sticky-parent")
        let result = await fixture.spawn(id: "sticky-child", promptID: "sticky-parent")
        guard case .success = result else {
            Issue.record("multi-round child did not complete: \(result)")
            return
        }

        let requests = fixture.script.requestSnapshot()
        #expect(requests.count == 2)
        #expect(requests.map(\.turnID) == ["sticky-child-0", "sticky-child-1"])
        #expect(requests.map(\.logicalTurnID) == ["sticky-child-0", "sticky-child-0"])

        let session = try #require(await fixture.history.usageSnapshot)
        #expect(session.totals.totalTokens == 65)
        #expect(session.totals.modelCalls == 2)
        #expect(session.mainLoopModelCalls == 0)
        #expect(session.trustedCostUsdTicks == 400)
        #expect(session.models.count == 1)
        #expect(session.models.first?.totals.modelCalls == 2)
    }

    @Test("resuming a canonical session seeds its exact existing ledger only once")
    func resumedSessionPreservesPriorProviderUsageWithoutDoubleCounting() async throws {
        let fixture = try await UsageFoundationFixture(responses: [])
        defer { Task { await fixture.dispose() } }

        await fixture.history.beginUsagePrompt("original-prompt")
        try await fixture.history.recordMainUsage(
            modelID: "grok-4.5",
            usage: TokenUsage(
                promptTokens: 60,
                completionTokens: 15,
                totalTokens: 75,
                cachedPromptTokens: 12,
                cacheCreationPromptTokens: 4
            ),
            costUsdTicks: 900
        )
        await fixture.history.endUsagePrompt("original-prompt")

        let restoredRecord = try await fixture.store.load(sessionID: "usage-root")
        let resumed = LiveConversationHistory(
            record: restoredRecord,
            store: fixture.store,
            samplingConfig: SamplingConfig(
                baseURL: "https://api.example.invalid/v1",
                model: "grok-4.5",
                provider: .xai,
                contextWindow: 128_000
            )
        )
        await resumed.beginUsagePrompt("resumed-prompt")
        try await resumed.recordMainUsage(
            modelID: "grok-4.5",
            usage: TokenUsage(
                promptTokens: 20,
                completionTokens: 5,
                totalTokens: 25,
                cachedPromptTokens: 3,
                cacheCreationPromptTokens: 1
            ),
            costUsdTicks: 300
        )

        let usage = try #require(await resumed.usageSnapshot)
        #expect(usage.totals.totalTokens == 100)
        #expect(usage.totals.cachedReadTokens == 15)
        #expect(usage.totals.cacheCreationTokens == 5)
        #expect(usage.mainLoopModelCalls == 2)
        #expect(usage.trustedCostUsdTicks == 1_200)
        #expect(usage.models.count == 1)
        #expect(usage.models.first?.totals.modelCalls == 2)
    }
}
