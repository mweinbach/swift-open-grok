import Foundation
import OpenGrokAgentDefinitions
import OpenGrokConfig
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
import OpenGrokToolRegistry
import OpenGrokToolTypes
import Testing

@testable import OpenGrokCLI

struct LiveDelegatedParityFixture {
    let root: URL
    let workspace: URL
    let host: LiveSubagentHost
    let security: LiveSecurityContext
    let environment: [String: String]

    init(
        sampler: OpenGrokLiveSampler,
        environmentOverrides: [String: String] = [:],
        definitions: [AgentDefinition] = [],
        swarmRetrySleeper: (@Sendable (UInt64) async throws -> Void)? = nil,
        swarmRetryStatusSink: (@Sendable (LiveSwarmRetryStatus) async -> Void)? = nil
    ) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-delegation-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]
        environment.merge(environmentOverrides) { _, replacement in replacement }
        self.environment = environment

        let store = LiveConversationStore(openGrokHome: home)
        var parent = LiveConversationRecord.new(
            sessionID: "delegation-parent",
            workingDirectory: workspace
        )
        parent.currentModelID = "grok-4.5"
        parent.currentProvider = .xai
        try await store.save(parent)

        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false
        )
        self.security = security
        let host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: "grok-4.5",
            workingDirectory: workspace,
            sessionID: "delegation-parent",
            openGrokHome: home,
            conversationStore: store,
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            securityContext: security,
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
                cliAgents: definitions,
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: ["grok-4.5"],
            parentProvider: .xai,
            swarmRetrySleeper: swarmRetrySleeper,
            swarmRetryStatusSink: swarmRetryStatusSink
        ))
        await host.installParentUsageHistory(
            LiveConversationHistory(record: parent, store: store)
        )
        await host.installParentAuthorizationScope(ToolResourceAuthorizationScope(
            authorizationSessionID: "delegation-parent",
            allowedRoots: [workspace.path]
        ))
        self.host = host
    }

    func spawn(
        id: String = "question-child",
        subagentType: String = "general-purpose"
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        await host.spawn(
            args: .object([
                "task_id": .string(id),
                "prompt": .string("Ask before choosing a database"),
                "description": .string("delegated interaction parity"),
                "subagent_type": .string(subagentType),
                "background": .bool(false),
            ]),
            toolCallID: "parent-call-\(id)"
        )
    }

    func dispose() async {
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor LiveSubagentQuestionSamplingProbe {
    private var requests: [OpenGrokLiveSamplingRequest] = []

    func sample(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        let childRound = requests.filter { $0.sessionID == request.sessionID }.count
        if childRound == 1,
           request.tools.contains(where: { $0.name == "ask_user_question" }) {
            return OpenGrokLiveSamplingResponse(
                output: "",
                toolCalls: [ToolCall(
                    id: "child-question-call",
                    name: "ask_user_question",
                    arguments: #"{"questions":[{"question":"Which database?","options":[{"label":"Redis","description":"In-memory database"},{"label":"Postgres","description":"Relational database"}]}]}"#
                )]
            )
        }
        return OpenGrokLiveSamplingResponse(output: "delegated decision completed")
    }

    func samples() -> [OpenGrokLiveSamplingRequest] { requests }
}

private actor LiveSubagentQuestionPresentationProbe {
    private(set) var requests: [PagerQuestionRequest] = []

    func record(_ request: PagerQuestionRequest) {
        requests.append(request)
    }
}

@Suite("Interactive subagent question parity", .serialized)
struct LiveSubagentQuestionParityTests {
    private func makeFixture(
        probe: LiveSubagentQuestionSamplingProbe,
        environment: [String: String] = [:],
        definitions: [AgentDefinition] = []
    ) async throws -> LiveDelegatedParityFixture {
        try await LiveDelegatedParityFixture(
            sampler: OpenGrokLiveSampler { request, _ in
                await probe.sample(request)
            },
            environmentOverrides: environment,
            definitions: definitions
        )
    }

    @Test("an authorized child advertises the tool and routes its answer through the root pager")
    func authorizedChildUsesRootQuestionSurface() async throws {
        let sampler = LiveSubagentQuestionSamplingProbe()
        let fixture = try await makeFixture(probe: sampler)
        defer { Task { await fixture.dispose() } }

        let presentation = LiveSubagentQuestionPresentationProbe()
        let coordinator = PagerQuestionCoordinator()
        await coordinator.setPresenter { request in
            guard let request else { return }
            await presentation.record(request)
            await coordinator.resolve(
                requestID: request.id,
                outcome: .answered([
                    PagerQuestionAnswer(question: "Which database?", label: "Postgres")
                ])
            )
        }
        await fixture.host.installParentQuestionCoordinator(coordinator)

        let result = await fixture.spawn()
        guard case .success = result else {
            Issue.record("authorized child failed: \(result)")
            return
        }
        let requests = await sampler.samples()
        #expect(requests.count == 2)
        #expect(requests.first?.tools.contains { $0.name == "ask_user_question" } == true)
        let prompts = await presentation.requests
        #expect(prompts.count == 1)
        #expect(prompts.first?.toolCallID == "question-child:child-question-call")
        #expect(prompts.first?.questions.first?.text == "Which database?")
        let toolOutput = requests.last?.items.compactMap { item -> String? in
            if case .toolResult(let result) = item { return result.content }
            return nil
        }
        #expect(toolOutput?.contains { $0.contains("Postgres") } == true)
        #expect(await coordinator.pendingCount == 0)
    }

    @Test("headless children never advertise a fake interactive capability")
    func headlessChildDoesNotAdvertiseQuestions() async throws {
        let sampler = LiveSubagentQuestionSamplingProbe()
        let fixture = try await makeFixture(probe: sampler)
        defer { Task { await fixture.dispose() } }

        guard case .success = await fixture.spawn() else {
            Issue.record("headless child failed before sampling")
            return
        }
        let requests = await sampler.samples()
        #expect(requests.count == 1)
        #expect(requests[0].tools.allSatisfy { $0.name != "ask_user_question" })
    }

    @Test("an installed coordinator without a renderer still fails closed")
    func coordinatorWithoutPresenterDoesNotAdvertiseQuestions() async throws {
        let sampler = LiveSubagentQuestionSamplingProbe()
        let fixture = try await makeFixture(probe: sampler)
        defer { Task { await fixture.dispose() } }
        await fixture.host.installParentQuestionCoordinator(PagerQuestionCoordinator())

        guard case .success = await fixture.spawn() else {
            Issue.record("presenter-less child failed before sampling")
            return
        }
        let requests = await sampler.samples()
        #expect(requests.count == 1)
        #expect(requests[0].tools.allSatisfy { $0.name != "ask_user_question" })
    }

    @Test("a child denylist cannot be bypassed by inheriting the parent's UI")
    func definitionDenylistRemainsEffective() async throws {
        var definition = AgentDefinition.builtinDefaults(
            name: "no-questions",
            description: "Questionless worker"
        )
        definition.disallowedTools = ["ask_user_question"]
        let sampler = LiveSubagentQuestionSamplingProbe()
        let fixture = try await makeFixture(probe: sampler, definitions: [definition])
        defer { Task { await fixture.dispose() } }
        let coordinator = PagerQuestionCoordinator()
        await coordinator.setPresenter { _ in }
        await fixture.host.installParentQuestionCoordinator(coordinator)

        guard case .success = await fixture.spawn(subagentType: "no-questions") else {
            Issue.record("denylisted child failed before sampling")
            return
        }
        let requests = await sampler.samples()
        #expect(requests[0].tools.allSatisfy { $0.name != "ask_user_question" })
        #expect(await coordinator.pendingCount == 0)
    }

    @Test("trusted timeout requirements outrank environment and effective configuration")
    func trustedTimeoutResolution() async throws {
        let sampler = LiveSubagentQuestionSamplingProbe()
        let fixture = try await makeFixture(probe: sampler)
        defer { Task { await fixture.dispose() } }

        var security = fixture.security
        security.document = .table(try parseTOMLTable("""
        [toolset.ask_user_question]
        timeout_secs = 17
        """))
        #expect(LiveSubagentQuestionTimeout.resolve(
            security: security,
            environment: ["GROK_ASK_USER_QUESTION_TIMEOUT_SECS": "9"]
        ) == 9)

        security.requirements = [.table(try parseTOMLTable("""
        [toolset.ask_user_question]
        timeout_secs = 4
        """))]
        #expect(LiveSubagentQuestionTimeout.resolve(
            security: security,
            environment: ["GROK_ASK_USER_QUESTION_TIMEOUT_SECS": "9"]
        ) == 4)

        security.requirements = []
        #expect(LiveSubagentQuestionTimeout.resolve(
            security: security,
            environment: ["GROK_ASK_USER_QUESTION_TIMEOUT_ENABLED": "false"]
        ) == LiveSubagentQuestionTimeout.maximumSeconds)
    }

    @Test("a configured child deadline closes its own root-pager request")
    func configuredTimeoutDrainsOwnedQuestion() async throws {
        let sampler = LiveSubagentQuestionSamplingProbe()
        let fixture = try await makeFixture(
            probe: sampler,
            environment: ["GROK_ASK_USER_QUESTION_TIMEOUT_SECS": "1"]
        )
        defer { Task { await fixture.dispose() } }
        let coordinator = PagerQuestionCoordinator()
        await coordinator.setPresenter { _ in }
        await fixture.host.installParentQuestionCoordinator(coordinator)

        let result = await fixture.spawn(id: "timed-question-child")
        guard case .success = result else {
            Issue.record("timed-out questionnaire should continue the child, got \(result)")
            return
        }
        #expect(await coordinator.pendingCount == 0)
        let requests = await sampler.samples()
        #expect(requests.count == 2)
        let toolOutput = requests.last?.items.compactMap { item -> String? in
            if case .toolResult(let result) = item { return result.content }
            return nil
        }
        #expect(toolOutput?.contains { $0.contains("User declined to answer") } == true)
    }

    @Test("cancelling a child resolves only its owned root-pager request")
    func cancellationDrainsOwnedQuestion() async throws {
        let sampler = LiveSubagentQuestionSamplingProbe()
        let fixture = try await makeFixture(probe: sampler)
        defer { Task { await fixture.dispose() } }
        let coordinator = PagerQuestionCoordinator()
        await coordinator.setPresenter { _ in }
        await fixture.host.installParentQuestionCoordinator(coordinator)

        let invocation = Task { await fixture.spawn(id: "cancelled-question-child") }
        let deadline = Date().addingTimeInterval(3)
        while await coordinator.pendingCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await coordinator.pendingCount == 1)
        #expect(await fixture.host.cancelSubagent(id: "cancelled-question-child") == .cancelled)
        let cancelled = await invocation.value
        guard case .failure(.cancelled) = cancelled else {
            Issue.record("expected cancelled child result, got \(cancelled)")
            return
        }

        let drainDeadline = Date().addingTimeInterval(3)
        while await coordinator.pendingCount != 0, Date() < drainDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await coordinator.pendingCount == 0)
    }
}
