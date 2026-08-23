import Foundation
import OpenGrokAgentCoordinator
import OpenGrokAgentDefinitions
import OpenGrokFastWorktree
import OpenGrokSamplingTypes
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
import OpenGrokToolRegistry
import OpenGrokWorkflow
import OpenGrokWorkspace
import Testing

@testable import OpenGrokCLI

private actor WorkflowBridgeSamplingObserver {
    struct Observation: Sendable {
        let route: String
        let request: OpenGrokLiveSamplingRequest
    }

    private var observations: [Observation] = []
    private var factories: [String] = []
    private var outputs: [String]
    private let writesIsolatedFile: Bool
    private var sessions: Set<String> = []
    private var isolatedWriteIssued = false

    init(outputs: [String] = ["workflow child finished"], writesIsolatedFile: Bool = false) {
        self.outputs = outputs
        self.writesIsolatedFile = writesIsolatedFile
    }

    func sample(
        route: String,
        request: OpenGrokLiveSamplingRequest
    ) async throws -> OpenGrokLiveSamplingResponse {
        observations.append(Observation(route: route, request: request))
        if request.prompt.contains("park-until-cancelled") {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        let firstRound = sessions.insert(request.sessionID).inserted
        let usage = TokenUsage(promptTokens: 7, completionTokens: 5, totalTokens: 12)
        if writesIsolatedFile && firstRound && !isolatedWriteIssued {
            isolatedWriteIssued = true
            return OpenGrokLiveSamplingResponse(
                output: "Writing inside the child checkout.",
                toolCalls: [ToolCall(
                    id: "write-\(request.sessionID)",
                    name: "search_replace",
                    arguments: #"{"file_path":"workflow-child.txt","old_string":"","new_string":"isolated child"}"#
                )],
                usage: usage
            )
        }
        let output = outputs.count > 1 ? outputs.removeFirst() : outputs.first ?? ""
        return OpenGrokLiveSamplingResponse(output: output, usage: usage)
    }

    func recordFactory(_ model: String) {
        factories.append(model)
    }

    func snapshot() -> [Observation] { observations }
    func factorySnapshot() -> [String] { factories }
}

private struct WorkflowBridgeFixture {
    let root: URL
    let workspace: URL
    let home: URL
    let store: LiveConversationStore
    let rootHost: LiveSubagentHost
    let observer: WorkflowBridgeSamplingObserver
    let sampler: OpenGrokLiveSampler
    let parentSessionID = "workflow-bridge-parent"

    init(
        outputs: [String] = ["workflow child finished"],
        gitRepository: Bool = false,
        writesIsolatedFile: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-workflow-bridge-\(UUID().uuidString)",
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        if gitRepository {
            try Self.git(["init"], at: workspace)
            try Self.git(["config", "user.email", "workflow-bridge@example.test"], at: workspace)
            try Self.git(["config", "user.name", "Workflow Bridge Parity"], at: workspace)
            try "parent checkout\n".write(
                to: workspace.appendingPathComponent("parent.txt"),
                atomically: true,
                encoding: .utf8
            )
            try Self.git(["add", "parent.txt"], at: workspace)
            try Self.git(["commit", "-m", "Initial workflow bridge fixture"], at: workspace)
        }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "GROK_SANDBOX": "off",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
        ]
        let observer = WorkflowBridgeSamplingObserver(
            outputs: outputs,
            writesIsolatedFile: writesIsolatedFile
        )
        self.observer = observer
        let sampler = OpenGrokLiveSampler { request, _ in
            try await observer.sample(route: "parent", request: request)
        }
        self.sampler = sampler
        let store = LiveConversationStore(openGrokHome: home)
        self.store = store
        let permissions = CLIPermissionOptions(alwaysApprove: true)
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false,
            cli: permissions
        )
        let parentSessionID = "workflow-bridge-parent"
        rootHost = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: "grok-parent",
            workingDirectory: workspace,
            sessionID: parentSessionID,
            openGrokHome: home,
            conversationStore: store,
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
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
                definitions: [SubagentDefinition(
                    definition: AgentDefinition(
                        name: "security-auditor",
                        description: "Trusted installed security auditor",
                        promptBody: "INSTALLED_SECURITY_AUDITOR_ROLE"
                    ),
                    source: .user
                )],
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: ["grok-parent", "codex-child"],
            parentProvider: .xai,
            childSamplerFactory: { model, _ in
                await observer.recordFactory(model)
                guard model == "codex-child" else {
                    throw RhaiHostError.failed("unexpected child provider model")
                }
                let childSampler = OpenGrokLiveSampler { request, _ in
                    try await observer.sample(route: "isolated-codex", request: request)
                }
                return LiveSubagentHost.ChildSamplerRoute(
                    sampler: childSampler,
                    provider: .codex
                )
            }
        ))
    }

    func workflowHost(
        runID: String = "workflow-bridge-run",
        provenance: LiveWorkflowSourceProvenance = .untrusted,
        parentCapability: ToolCapabilityMode = .all,
        supportsReasoningEffort: Bool = false,
        progress: RhaiWorkflowProgressBoard = RhaiWorkflowProgressBoard()
    ) -> LiveWorkflowHost {
        let context = RhaiWorkflowRunContext(
            runID: runID,
            workflowName: "user-supplied-name-never-confers-trust",
            arguments: .object([:]),
            agentBudget: 20,
            journalURL: nil,
            cancellation: RhaiCancellationToken(),
            progress: progress
        )
        let bridge = LiveWorkflowSubagentBridge(
            host: rootHost,
            parentSessionID: parentSessionID,
            sourceProvenance: provenance
        )
        let environment = LiveWorkflowAgentEnvironment(
            sampler: sampler,
            model: "grok-parent",
            workspaceRoot: workspace,
            parentCapabilityMode: parentCapability,
            supportsReasoningEffort: supportsReasoningEffort,
            subagentBridge: bridge,
            requiresSubagentBridge: true,
            makeInvoker: { _ in
                throw RhaiHostError.failed("legacy workflow invoker must never initialize")
            }
        )
        return LiveWorkflowHost(
            context: context,
            environment: environment,
            scratchRoot: home.appendingPathComponent("workflow-scratch", isDirectory: true)
        )
    }

    func saveParent(items: [ConversationItem], provider: ModelProvider = .xai) async throws {
        var record = LiveConversationRecord.new(
            sessionID: parentSessionID,
            workingDirectory: workspace
        )
        record.currentProvider = provider
        record.currentModelID = "grok-parent"
        record.items = items
        try await store.save(record)
    }

    func dispose() async {
        await rootHost.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private static func git(_ arguments: [String], at directory: URL) throws -> String {
        let result = try runGit(arguments, cwd: directory)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "LiveWorkflowBridgeGit",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result.stdout
    }
}

@Suite("Live workflow production subagent bridge parity", .serialized)
struct LiveWorkflowSubagentBridgeParityTests {
    @Test("real workflow progress, coordinator, result, and session share one child id")
    func realChildIdentityIsConsistentAcrossEveryLiveSurface() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        let progress = RhaiWorkflowProgressBoard()
        let workflow = fixture.workflowHost(progress: progress)

        let result = try await workflow.spawnAgent(RhaiAgentOptions(
            prompt: "prove the actual child identity",
            label: "human-facing label"
        ))
        let row = try #require((await progress.snapshot()).agents.first)
        let completed = try #require((await fixture.rootHost.coordinator.listCompleted()).first)
        let request = try #require((await fixture.observer.snapshot()).first?.request)

        #expect(result.agentID == row.agentID)
        #expect(result.agentID == completed.request.id)
        #expect(result.agentID == request.sessionID)
        #expect(UUID(uuidString: result.agentID) != nil)
        #expect(row.label == "human-facing label")
        #expect(row.state == .succeeded)
        #expect(try await fixture.store.loadIfPresent(sessionID: result.agentID) != nil)
    }

    @Test("workflow children have real run ownership and never surface in parent turn output")
    func realChildOwnershipAndCompletionPrivacy() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        let workflow = fixture.workflowHost(runID: "owned-workflow")

        let result = try await workflow.spawnAgent(RhaiAgentOptions(prompt: "inspect safely"))
        #expect(result.success)
        #expect(result.tokensUsed == 12)

        let completed = await fixture.rootHost.coordinator.listCompleted()
        let child = try #require(completed.first { $0.request.id == result.agentID })
        #expect(child.request.owner == .workflow)
        #expect(child.request.workflowRunID == "owned-workflow")
        #expect(child.request.parentSessionID == fixture.parentSessionID)
        #expect(child.request.parentPromptID == nil)
        #expect(child.request.awaitToCompletion)
        #expect(!child.request.runInBackground)
        #expect(!child.request.surfaceCompletion)
        let surfaced = await fixture.rootHost.coordinator.pollCompletions(
            parentSessionID: fixture.parentSessionID
        )
        #expect(surfaced.isEmpty)
        let record = try await fixture.store.loadIfPresent(sessionID: result.agentID)
        #expect(record?.parentSessionID == fixture.parentSessionID)
    }

    @Test("foreign model uses its own provider sampler without invoking the parent's transport")
    func crossProviderModelUsesIsolatedRoute() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }

        let result = try await fixture.workflowHost().spawnAgent(RhaiAgentOptions(
            prompt: "use the explicitly selected provider",
            model: "codex-child"
        ))
        #expect(result.success)
        let observations = await fixture.observer.snapshot()
        #expect(observations.count == 1)
        #expect(observations.first?.route == "isolated-codex")
        #expect(observations.first?.request.model == "codex-child")
        #expect(observations.first?.request.codexPermissions == nil)
        let factories = await fixture.observer.factorySnapshot()
        #expect(factories == ["codex-child"])
    }

    @Test("custom agent_type resolves an installed real role instead of the parent profile")
    func customAgentTypeUsesAuthoritativeRoleDefinition() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }

        let result = try await fixture.workflowHost().spawnAgent(RhaiAgentOptions(
            prompt: "audit the workspace using your installed role",
            agentType: "security-auditor"
        ))
        #expect(result.success)
        let observations = await fixture.observer.snapshot()
        let request = try #require(observations.first?.request)
        let contents = String(data: try JSONEncoder().encode(request.items), encoding: .utf8) ?? ""
        #expect(contents.contains("INSTALLED_SECURITY_AUDITOR_ROLE"))
        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(completed.first?.request.subagentType == "security-auditor")
    }

    @Test("explicit worktree creates a real checkout, confines writes, and durable resume reuses it")
    func realWorktreeAndDurableResume() async throws {
        let fixture = try WorkflowBridgeFixture(
            gitRepository: true,
            writesIsolatedFile: true
        )
        defer { Task { await fixture.dispose() } }
        let workflow = fixture.workflowHost()

        let first = try await workflow.spawnAgent(RhaiAgentOptions(
            prompt: "create the isolated child file",
            isolationWorktree: true
        ))
        #expect(first.success)
        let completed = await fixture.rootHost.coordinator.listCompleted()
        let initial = try #require(completed.first { $0.request.id == first.agentID })
        let worktree = try #require(initial.request.worktreePath)
        #expect(worktree != fixture.workspace.path)
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: worktree)
                .appendingPathComponent("workflow-child.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("workflow-child.txt").path
        ))

        let resumed = try await workflow.spawnAgent(RhaiAgentOptions(
            prompt: "continue inside the same isolated checkout",
            resumeFrom: first.agentID
        ))
        #expect(resumed.success)
        let later = await fixture.rootHost.coordinator.listCompleted()
        let resumedRequest = try #require(later.first { $0.request.id == resumed.agentID })
        #expect(resumedRequest.request.resumeFrom == first.agentID)
        #expect(resumedRequest.request.worktreePath == worktree)
    }

    @Test("schema stays host-side, retries once by resuming, and accounts actual child usage")
    func hostSideSchemaContractRetriesExactlyOnce() async throws {
        let fixture = try WorkflowBridgeFixture(outputs: [
            "I finished but forgot the JSON.",
            "Corrected result:\n```json\n{\"ok\":true}\n```",
        ])
        defer { Task { await fixture.dispose() } }
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("ok")]),
            "properties": .object([
                "ok": .object(["type": .string("boolean")]),
            ]),
        ])

        let result = try await fixture.workflowHost().spawnAgent(RhaiAgentOptions(
            prompt: "inspect files before reporting",
            outputSchema: schema
        ))
        #expect(result.success)
        #expect(result.output == .object(["ok": .bool(true)]))
        #expect(result.tokensUsed == 24)
        let observations = await fixture.observer.snapshot()
        #expect(observations.count == 2)
        #expect(observations.allSatisfy { $0.request.jsonSchema == nil })
        #expect(observations[0].request.prompt.contains("<output-contract>"))
        #expect(observations[1].request.prompt.contains("did not satisfy the output contract"))
        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(completed.count == 2)
        #expect(completed[1].request.resumeFrom == completed[0].request.id)
        #expect(result.agentID == completed[0].request.id)
    }

    @Test("a second invalid structured response fails truthfully without a third child")
    func schemaValidationStopsAfterSingleCorrection() async throws {
        let fixture = try WorkflowBridgeFixture(outputs: ["first invalid", "second invalid"])
        defer { Task { await fixture.dispose() } }
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("ok")]),
        ])

        let result = try await fixture.workflowHost().spawnAgent(RhaiAgentOptions(
            prompt: "return a valid structured object",
            outputSchema: schema
        ))
        #expect(!result.success)
        #expect(result.tokensUsed == 24)
        #expect(result.output.stringValue?.contains("structured output validation failed") == true)
        let observations = await fixture.observer.snapshot()
        #expect(observations.count == 2)
        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(completed.count == 2)
    }

    @Test("user workflows cannot fork even when names or resume options impersonate built-ins")
    func untrustedForkFailsBeforeChildAdmission() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        try await fixture.saveParent(items: [.user("private parent conversation")])

        do {
            let result = try await fixture.workflowHost().spawnAgent(RhaiAgentOptions(
                prompt: "capture the parent history",
                forkContext: true,
                resumeFrom: "pretend-prior-child"
            ))
            Issue.record("untrusted workflow unexpectedly forked: \(result)")
        } catch let error as RhaiHostError {
            #expect(error == .unsupported("fork_context is restricted to built-in workflows"))
        }

        let requests = await fixture.observer.snapshot()
        #expect(requests.isEmpty)
        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(completed.isEmpty)
    }

    @Test("trusted built-in forks copy only real text turns and strip provider/tool secrets")
    func trustedBuiltInForkSanitizesConversation() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        try await fixture.saveParent(items: [
            .system("SYSTEM_PRIVATE_SECRET"),
            .user("safe actual user question"),
            .userMeta("SYNTHETIC_PRIVATE_SECRET"),
            .assistant(AssistantItem(
                content: "safe visible assistant answer",
                toolCalls: [ToolCall(
                    id: "opaque-tool",
                    name: "read_file",
                    arguments: "TOOL_ARGUMENT_PRIVATE_SECRET"
                )],
                modelId: "PARENT_PROVIDER_PRIVATE_METADATA"
            )),
            .toolResult(ToolResultItem(
                toolCallId: "opaque-tool",
                content: "TOOL_OUTPUT_PRIVATE_SECRET"
            )),
            .reasoning(ReasoningItem(
                id: "opaque-reasoning",
                encryptedContent: "ENCRYPTED_PROVIDER_PRIVATE_SECRET"
            )),
        ])

        let result = try await fixture.workflowHost(
            provenance: .trustedBuiltIn
        ).spawnAgent(RhaiAgentOptions(
            prompt: "continue the authorized conversation",
            model: "codex-child",
            forkContext: true
        ))
        #expect(result.success)
        let observations = await fixture.observer.snapshot()
        let request = try #require(observations.first?.request)
        let serialized = String(
            data: try JSONEncoder().encode(request.items),
            encoding: .utf8
        ) ?? ""
        #expect(serialized.contains("safe actual user question"))
        #expect(serialized.contains("safe visible assistant answer"))
        #expect(!serialized.contains("SYSTEM_PRIVATE_SECRET"))
        #expect(!serialized.contains("SYNTHETIC_PRIVATE_SECRET"))
        #expect(!serialized.contains("TOOL_ARGUMENT_PRIVATE_SECRET"))
        #expect(!serialized.contains("TOOL_OUTPUT_PRIVATE_SECRET"))
        #expect(!serialized.contains("ENCRYPTED_PROVIDER_PRIVATE_SECRET"))
        #expect(!serialized.contains("PARENT_PROVIDER_PRIVATE_METADATA"))
    }

    @Test("workflow capability clamp narrows the real child executor tool surface")
    func parentCapabilityCeilingReachesActualChildTools() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }

        let result = try await fixture.workflowHost(
            parentCapability: .readOnly
        ).spawnAgent(RhaiAgentOptions(
            prompt: "try requesting all authority",
            capabilityMode: "all"
        ))
        #expect(result.success)
        let observations = await fixture.observer.snapshot()
        let toolNames = try #require(observations.first?.request.tools.map(\.name))
        #expect(!toolNames.contains("search_replace"))
        #expect(!toolNames.contains("write_file"))
        #expect(!toolNames.contains("bash"))
        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(completed.first?.request.capabilityMode == "read-only")
    }

    @Test("incomparable execute and read-write capabilities intersect to read-only")
    func incomparableCapabilitiesCannotGrantEitherExclusiveAuthority() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }

        let writeParent = fixture.workflowHost(
            runID: "parent-can-write",
            parentCapability: .readWrite
        )
        let executeRequest = try await writeParent.spawnAgent(RhaiAgentOptions(
            prompt: "ask for execute without inheriting parent writes",
            capabilityMode: "execute"
        ))
        #expect(executeRequest.success)

        let executeParent = fixture.workflowHost(
            runID: "parent-can-execute",
            parentCapability: .execute
        )
        let writeRequest = try await executeParent.spawnAgent(RhaiAgentOptions(
            prompt: "ask for writes without inheriting parent execution",
            capabilityMode: "read-write"
        ))
        #expect(writeRequest.success)

        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(completed.count == 2)
        #expect(completed.allSatisfy { $0.request.capabilityMode == "read-only" })
        let observations = await fixture.observer.snapshot()
        #expect(observations.allSatisfy { observation in
            let names = Set(observation.request.tools.map(\.name))
            return !names.contains("search_replace")
                && !names.contains("write_file")
                && !names.contains("bash")
        })
    }

    @Test("malformed capability and unsupported child effort fail before any provider call")
    func malformedOptionsRemainFailClosedOnRealBridge() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        let workflow = fixture.workflowHost()

        for options in [
            RhaiAgentOptions(prompt: "escalate", capabilityMode: "read_only;all"),
            RhaiAgentOptions(prompt: "invalid effort", reasoningEffort: "super-secret"),
            RhaiAgentOptions(
                prompt: "unverified foreign effort",
                model: "codex-child",
                reasoningEffort: "high"
            ),
        ] {
            do {
                let result = try await workflow.spawnAgent(options)
                Issue.record("invalid workflow authority unexpectedly ran: \(result)")
            } catch is RhaiHostError {
                // The effect, not only the error vocabulary, is the invariant.
            }
        }
        let observations = await fixture.observer.snapshot()
        #expect(observations.isEmpty)
        let children = await fixture.rootHost.coordinator.listCompleted()
        #expect(children.isEmpty)
    }

    @Test("normalized supported reasoning effort reaches the genuine child sampling request")
    func supportedReasoningEffortReachesRealProviderRequest() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }

        let result = try await fixture.workflowHost(
            supportsReasoningEffort: true
        ).spawnAgent(RhaiAgentOptions(
            prompt: "reason carefully through the real child route",
            reasoningEffort: " HIGH "
        ))
        #expect(result.success)
        let observations = await fixture.observer.snapshot()
        #expect(observations.first?.request.reasoningEffort == .high)
        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(completed.first?.request.reasoningEffort == "high")
    }

    @Test("a production workflow with no root subagent host refuses to run its legacy sampler")
    func missingRootHostNeverFallsBackToMiniatureAgent() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        let environment = LiveWorkflowAgentEnvironment(
            sampler: fixture.sampler,
            model: "grok-parent",
            workspaceRoot: fixture.workspace,
            requiresSubagentBridge: true,
            makeInvoker: { _ in
                throw RhaiHostError.failed("legacy invoker must never initialize")
            }
        )
        let child = LiveWorkflowChildAgent(
            runID: "missing-root-host",
            environment: environment,
            cancellation: RhaiCancellationToken()
        )

        do {
            let result = try await child.run(
                agentID: "no-bridge",
                options: RhaiAgentOptions(prompt: "attempt a legacy fallback"),
                emit: { _ in }
            )
            Issue.record("missing root host unexpectedly sampled: \(result)")
        } catch let error as RhaiHostError {
            #expect(error == .failed("workflow child subagent host is unavailable"))
        }
        let observations = await fixture.observer.snapshot()
        #expect(observations.isEmpty)
    }

    @Test("parallel workflow runs with matching labels receive globally unique real child ids")
    func independentRunsCannotCollideInRootCoordinator() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        let first = fixture.workflowHost(runID: "first-workflow")
        let second = fixture.workflowHost(runID: "second-workflow")
        let options = RhaiAgentOptions(prompt: "inspect shared parent", label: "same label")

        async let firstResult = first.spawnAgent(options)
        async let secondResult = second.spawnAgent(options)
        let results = try await [firstResult, secondResult]
        #expect(results[0].success)
        #expect(results[1].success)
        #expect(results[0].agentID != results[1].agentID)
        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(Set(completed.map { $0.request.workflowRunID }) == Set([
            Optional("first-workflow"), Optional("second-workflow"),
        ]))
    }

    @Test("run-scoped cancellation terminates its workflow child without touching ordinary tasks")
    func workflowCancellationDoesNotCancelOrdinaryRootChildren() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }

        let ordinary = await fixture.rootHost.spawn(
            args: .object([
                "task_id": .string("ordinary-root-task"),
                "prompt": .string("park-until-cancelled ordinary root task"),
                "description": .string("ordinary root child"),
                "subagent_type": .string("general-purpose"),
                "run_in_background": .bool(true),
            ]),
            toolCallID: "ordinary-root-tool"
        )
        guard case .success = ordinary else {
            Issue.record("could not launch ordinary root child: \(ordinary)")
            return
        }

        let workflow = fixture.workflowHost(runID: "cancel-only-workflow")
        let task = Task {
            try await workflow.spawnAgent(RhaiAgentOptions(
                prompt: "park-until-cancelled workflow child"
            ))
        }
        var workflowActive = false
        for _ in 0..<200 {
            let active = await fixture.rootHost.coordinator.listActive(
                workflowRunID: "cancel-only-workflow"
            )
            if !active.isEmpty {
                workflowActive = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(workflowActive)

        let cancelled = await fixture.rootHost.coordinator.cancel(
            .workflowRun("cancel-only-workflow")
        )
        #expect(cancelled == 1)
        do {
            let result = try await task.value
            Issue.record("cancelled workflow unexpectedly completed: \(result)")
        } catch let error as RhaiHostError {
            #expect(error == .cancelled)
        }
        let remaining = await fixture.rootHost.coordinator.listActive()
        #expect(remaining.contains { $0.request.id == "ordinary-root-task" })
        let ordinaryCancelled = await fixture.rootHost.coordinator.cancel(
            .childID("ordinary-root-task")
        )
        #expect(ordinaryCancelled == 1)
    }

    @Test("oversized and externally referenced schemas are rejected before child admission")
    func unsafeSchemasFailBeforeProviderOrWorkspaceEffects() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        let workflow = fixture.workflowHost()
        let schemas: [JSONValue] = [
            .object(["$ref": .string("https://attacker.example/secret-schema")]),
            .object([
                "type": .string("object"),
                "description": .string(String(repeating: "x", count: 262_145)),
            ]),
            .object(["type": .string("string"), "pattern": .string("^(a+)+$")]),
        ]

        for schema in schemas {
            do {
                let result = try await workflow.spawnAgent(RhaiAgentOptions(
                    prompt: "validate without making a request",
                    outputSchema: schema
                ))
                Issue.record("unsafe schema unexpectedly ran: \(result)")
            } catch is RhaiHostError {}
        }
        let observations = await fixture.observer.snapshot()
        #expect(observations.isEmpty)
        let completed = await fixture.rootHost.coordinator.listCompleted()
        #expect(completed.isEmpty)
    }

    @Test("malformed supported schema keywords fail before child or provider admission")
    func malformedSupportedSchemaGrammarHasNoLiveSideEffects() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        let workflow = fixture.workflowHost()
        let schemas: [JSONValue] = [
            .object(["$ref": .number(.int64(7))]),
            .object(["type": .string("filesystem")]),
            .object(["type": .array([.string("string"), .number(.int64(1))])]),
            .object(["required": .string("answer")]),
            .object(["properties": .array([])]),
            .object(["properties": .object(["answer": .string("not-a-schema")])]),
            .object(["additionalProperties": .string("yes")]),
            .object(["items": .array([])]),
            .object(["allOf": .object([:])]),
            .object(["minItems": .number(.int64(-1))]),
            .object(["minimum": .string("zero")]),
            .object(["enum": .array([])]),
        ]

        for schema in schemas {
            do {
                let result = try await workflow.spawnAgent(RhaiAgentOptions(
                    prompt: "this must never reach a child",
                    outputSchema: schema
                ))
                Issue.record("malformed schema unexpectedly ran: \(result)")
            } catch is RhaiHostError {}
        }

        #expect((await fixture.observer.snapshot()).isEmpty)
        #expect((await fixture.rootHost.coordinator.listActive()).isEmpty)
        #expect((await fixture.rootHost.coordinator.listCompleted()).isEmpty)
    }

    @Test("built-in fork fails closed when parent conversation provider authority is stale")
    func staleParentProviderCannotForkAcrossAuthorityBoundary() async throws {
        let fixture = try WorkflowBridgeFixture()
        defer { Task { await fixture.dispose() } }
        try await fixture.saveParent(items: [.user("provider-private text")], provider: .codex)

        do {
            let result = try await fixture.workflowHost(
                provenance: .trustedBuiltIn
            ).spawnAgent(RhaiAgentOptions(prompt: "fork stale parent", forkContext: true))
            Issue.record("stale provider parent unexpectedly forked: \(result)")
        } catch let error as RhaiHostError {
            guard case .failed(let message) = error else {
                Issue.record("unexpected stale-parent error: \(error)")
                return
            }
            #expect(message.contains("parent conversation ownership could not be verified"))
        }
        let observations = await fixture.observer.snapshot()
        #expect(observations.isEmpty)
    }
}
