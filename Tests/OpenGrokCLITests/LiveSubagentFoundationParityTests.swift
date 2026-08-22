import Foundation
import OpenGrokAgentCoordinator
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing

@testable import OpenGrokCLI

private actor FoundationParityShellBackend: ShellProcessBackend {
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

private final class FoundationSamplingRecorder: @unchecked Sendable {
    struct RecordedRequest: Sendable {
        var route: String
        var request: OpenGrokLiveSamplingRequest
    }

    struct FactoryCall: Sendable {
        var model: String
        var permissions: CodexPermissions?
    }

    private let lock = NSLock()
    private var requests: [RecordedRequest] = []
    private var factoryCalls: [FactoryCall] = []

    func record(route: String, request: OpenGrokLiveSamplingRequest) {
        lock.lock()
        requests.append(RecordedRequest(route: route, request: request))
        lock.unlock()
    }

    func recordFactory(model: String, permissions: CodexPermissions?) {
        lock.lock()
        factoryCalls.append(FactoryCall(model: model, permissions: permissions))
        lock.unlock()
    }

    func requestSnapshot() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func factorySnapshot() -> [FactoryCall] {
        lock.lock()
        defer { lock.unlock() }
        return factoryCalls
    }
}

private struct FoundationSubagentFixture {
    let root: URL
    let host: LiveSubagentHost
    let store: LiveConversationStore
    let recorder: FoundationSamplingRecorder

    init(
        parentModel: String,
        parentProvider: ModelProvider,
        permissions: CodexPermissions? = nil,
        childRouteProvider: ModelProvider? = nil,
        parentCacheAffinityID: String? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-subagent-foundation-\(UUID().uuidString)",
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
        let recorder = FoundationSamplingRecorder()
        self.recorder = recorder
        let store = LiveConversationStore(openGrokHome: home)
        self.store = store
        let parentSampler = OpenGrokLiveSampler { request, _ in
            recorder.record(route: "parent", request: request)
            return OpenGrokLiveSamplingResponse(output: "the child completed its delegated task")
        }

        let childSamplerFactory: (
            @Sendable (String, CodexPermissions?) async throws -> LiveSubagentHost.ChildSamplerRoute
        )?
        if let childRouteProvider {
            childSamplerFactory = { model, inheritedPermissions in
                recorder.recordFactory(model: model, permissions: inheritedPermissions)
                let sampler = OpenGrokLiveSampler { request, _ in
                    recorder.record(route: "child", request: request)
                    return OpenGrokLiveSamplingResponse(
                        output: "the child completed its delegated task"
                    )
                }
                return LiveSubagentHost.ChildSamplerRoute(
                    sampler: sampler,
                    provider: childRouteProvider,
                    codexPermissions: inheritedPermissions
                )
            }
        } else {
            childSamplerFactory = nil
        }

        let securityContext = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false
        )
        host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: parentSampler,
            parentModel: parentModel,
            workingDirectory: workspace,
            sessionID: "foundation-session",
            openGrokHome: home,
            conversationStore: store,
            processBackend: FoundationParityShellBackend(),
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
            modelSlugs: ["gpt-5.4", "gpt-5.3", "grok-4.5"],
            parentCacheAffinityID: parentCacheAffinityID,
            parentProvider: parentProvider,
            parentCodexPermissions: permissions,
            childSamplerFactory: childSamplerFactory
        ))
    }

    func dispose() async {
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func spawn(
        id: String,
        model: String? = nil,
        resumeFrom: String? = nil
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        var arguments: [String: JSONValue] = [
            "task_id": .string(id),
            "prompt": .string("Inspect the provider boundary and report its policy"),
            "description": .string("Inspect provider boundary"),
            "subagent_type": .string("general-purpose"),
            "background": .bool(false),
        ]
        if let model {
            arguments["model"] = .string(model)
        }
        if let resumeFrom {
            arguments["resume_from"] = .string(resumeFrom)
        }
        return await host.spawn(args: .object(arguments), toolCallID: "call-\(id)")
    }

    static var sandboxedPermissions: CodexPermissions {
        CodexPermissions(
            sandbox: "seatbelt",
            sandboxMode: "workspace-write",
            sandboxProfile: "workspace",
            networkAccess: false,
            writableRoots: ["/workspace"],
            approvalPolicy: .onRequest,
            autoReviewEnabled: true
        )
    }
}

@Suite("Live subagent foundational parity", .serialized)
struct LiveSubagentFoundationParityTests {
    @Test("an inherited Codex model preserves the parent's applied execution policy")
    func inheritedCodexChildReceivesExecutionPolicy() async throws {
        let permissions = FoundationSubagentFixture.sandboxedPermissions
        let fixture = try FoundationSubagentFixture(
            parentModel: "gpt-5.4",
            parentProvider: .codex,
            permissions: permissions
        )
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "codex-child")
        guard case .success = result else {
            Issue.record("Codex child did not complete: \(result)")
            return
        }

        let sampled = try #require(fixture.recorder.requestSnapshot().first)
        #expect(sampled.route == "parent")
        #expect(sampled.request.sessionID == "codex-child")
        #expect(sampled.request.cacheAffinityID == "foundation-session")
        #expect(sampled.request.codexPermissions == permissions)
        #expect(fixture.recorder.factorySnapshot().isEmpty)
    }

    @Test("a forked parent passes its inherited cache route without changing child identity")
    func childInheritsForkPromptCacheAffinity() async throws {
        let fixture = try FoundationSubagentFixture(
            parentModel: "grok-4.5",
            parentProvider: .xai,
            parentCacheAffinityID: "original-root-session"
        )
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "fork-descendant")
        guard case .success = result else {
            Issue.record("fork-descendant child did not complete: \(result)")
            return
        }

        let sampled = try #require(fixture.recorder.requestSnapshot().first)
        #expect(sampled.request.sessionID == "fork-descendant")
        #expect(sampled.request.cacheAffinityID == "original-root-session")
        let record = try await fixture.store.loadIfPresent(sessionID: "fork-descendant")
        #expect(record?.cacheAffinityID == "original-root-session")
    }

    @Test("a non-Codex child receives an isolated provider sampler and no Codex policy")
    func nonCodexChildCannotInheritCodexProviderPolicy() async throws {
        let permissions = FoundationSubagentFixture.sandboxedPermissions
        let fixture = try FoundationSubagentFixture(
            parentModel: "gpt-5.4",
            parentProvider: .codex,
            permissions: permissions,
            childRouteProvider: .xai
        )
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "xai-child", model: "grok-4.5")
        guard case .success = result else {
            Issue.record("provider-isolated child did not complete: \(result)")
            return
        }

        let sampled = try #require(fixture.recorder.requestSnapshot().first)
        #expect(sampled.route == "child")
        #expect(sampled.request.model == "grok-4.5")
        #expect(sampled.request.codexPermissions == nil)
        #expect(fixture.recorder.factorySnapshot().first?.permissions == permissions)

        let record = try await fixture.store.loadIfPresent(
            sessionID: "xai-child"
        )
        #expect(record?.currentProvider == .xai)
        #expect(record?.sessionKind == "subagent")
    }

    @Test("a Codex child of another provider receives its own route and truthful policy")
    func crossProviderCodexChildUsesItsOwnCredentialsAndPolicy() async throws {
        let permissions = FoundationSubagentFixture.sandboxedPermissions
        let fixture = try FoundationSubagentFixture(
            parentModel: "grok-4.5",
            parentProvider: .xai,
            permissions: permissions,
            childRouteProvider: .codex
        )
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "codex-child", model: "gpt-5.4")
        guard case .success = result else {
            Issue.record("cross-provider Codex child did not complete: \(result)")
            return
        }

        let sampled = try #require(fixture.recorder.requestSnapshot().first)
        #expect(sampled.route == "child")
        #expect(sampled.request.model == "gpt-5.4")
        #expect(sampled.request.codexPermissions == permissions)
        let factoryCall = try #require(fixture.recorder.factorySnapshot().first)
        #expect(factoryCall.model == "gpt-5.4")
        #expect(factoryCall.permissions == permissions)

        let record = try await fixture.store.loadIfPresent(
            sessionID: "codex-child"
        )
        #expect(record?.currentProvider == .codex)
        #expect(record?.everUsedNonXAI == true)
        #expect(record?.sessionKind == "subagent")
    }

    @Test("Codex children observe later approval changes through the parent's same handle")
    func sharedParentPermissionHandleRemainsLive() async throws {
        let fixture = try FoundationSubagentFixture(
            parentModel: "gpt-5.4",
            parentProvider: .codex,
            permissions: FoundationSubagentFixture.sandboxedPermissions
        )
        defer { Task { await fixture.dispose() } }

        let parentPermissions = PermissionHandle(
            yoloMode: false,
            autoMode: true,
            shellCwd: fixture.root.appendingPathComponent("workspace").path
        )
        await fixture.host.installParentPermissionHandle(parentPermissions)

        let initial = await fixture.spawn(id: "auto-child")
        guard case .success = initial else {
            Issue.record("automatic-review child did not complete: \(initial)")
            return
        }
        let firstRequest = try #require(fixture.recorder.requestSnapshot().first)
        #expect(firstRequest.request.codexPermissions?.approvalPolicy == .onRequest)
        #expect(firstRequest.request.codexPermissions?.autoReviewEnabled == true)

        await parentPermissions.setAutoMode(false)
        await parentPermissions.setYoloMode(true)
        let updated = await fixture.spawn(id: "yolo-child")
        guard case .success = updated else {
            Issue.record("updated-permission child did not complete: \(updated)")
            return
        }
        let secondRequest = try #require(
            fixture.recorder.requestSnapshot().first {
                $0.request.sessionID == "yolo-child"
            }
        )
        #expect(secondRequest.request.codexPermissions?.approvalPolicy == .never)
        #expect(secondRequest.request.codexPermissions?.autoReviewEnabled == false)
    }

    @Test("a provider change fails closed without an isolated credential route")
    func crossProviderChildWithoutFactoryCannotSample() async throws {
        let fixture = try FoundationSubagentFixture(
            parentModel: "grok-4.5",
            parentProvider: .xai
        )
        defer { Task { await fixture.dispose() } }

        let result = await fixture.spawn(id: "blocked-child", model: "gpt-5.4")
        guard case .failure(let error) = result else {
            Issue.record("cross-provider child unexpectedly reused parent credentials")
            return
        }
        #expect(error.description.contains("requires an isolated provider sampling route"))
        #expect(fixture.recorder.requestSnapshot().isEmpty)
    }

    @Test("the parent turn scope reaches real child registration and token folding")
    func parentPromptScopeReachesRegisteredChild() async throws {
        let fixture = try FoundationSubagentFixture(
            parentModel: "grok-4.5",
            parentProvider: .xai
        )
        defer { Task { await fixture.dispose() } }

        let result = await LiveSubagentParentPromptContext.$promptID.withValue("root-turn-42") {
            await fixture.spawn(id: "scoped-child")
        }
        guard case .success = result else {
            Issue.record("prompt-scoped child did not complete: \(result)")
            return
        }

        let child = try #require(
            await fixture.host.coordinator.listCompleted().first {
                $0.request.id == "scoped-child"
            }
        )
        #expect(child.request.parentPromptID == "root-turn-42")
        #expect(child.request.subagentType == "general-purpose")
        #expect(child.request.description == "Inspect provider boundary")
        let usage = await fixture.host.coordinator.foldUsage(
            parentSessionID: "foundation-session",
            promptID: "root-turn-42",
            childIDs: ["scoped-child"]
        )
        #expect(usage.tokensUsed > 0)

        let roster = await fixture.host.coordinator.listAgents(
            identity: AgentMailboxIdentity(
                teamScopeID: "foundation-session",
                agentID: "foundation-session"
            )
        )
        let rosterEntry = try #require(roster.agents.first { $0.agentID == "scoped-child" })
        #expect(rosterEntry.subagentType == "general-purpose")
        #expect(rosterEntry.description == "Inspect provider boundary")
    }

    @Test("resume ignores an unavailable model override and retains the original provider")
    func resumeIgnoresUnavailableModelOverride() async throws {
        let fixture = try FoundationSubagentFixture(
            parentModel: "grok-4.5",
            parentProvider: .xai
        )
        defer { Task { await fixture.dispose() } }

        let initial = await fixture.spawn(id: "original-child")
        guard case .success = initial else {
            Issue.record("source child did not complete: \(initial)")
            return
        }

        let resumed = await fixture.spawn(
            id: "resumed-child",
            model: "unavailable-model",
            resumeFrom: "original-child"
        )
        guard case .success = resumed else {
            Issue.record("resume incorrectly validated its ignored model override: \(resumed)")
            return
        }

        let resumedRequest = try #require(
            fixture.recorder.requestSnapshot().first {
                $0.request.sessionID == "resumed-child"
            }
        )
        #expect(resumedRequest.request.model == "grok-4.5")
    }
}
