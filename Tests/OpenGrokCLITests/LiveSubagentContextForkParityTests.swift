import Foundation
import OpenGrokAgentDefinitions
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSubagentResolution
import OpenGrokToolTypes
import Testing

@testable import OpenGrokCLI

private actor SubagentContextForkProbe {
    private var requests: [OpenGrokLiveSamplingRequest] = []
    private let scriptedToolRounds: Int
    private let scriptedToolName: String

    init(
        scriptedToolRounds: Int = 0,
        scriptedToolName: String = "context_parity_missing_tool"
    ) {
        self.scriptedToolRounds = scriptedToolRounds
        self.scriptedToolName = scriptedToolName
    }

    func sample(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        let sampleNumber = requests.filter { $0.sessionID == request.sessionID }.count
        if sampleNumber <= scriptedToolRounds {
            return OpenGrokLiveSamplingResponse(
                output: "",
                toolCalls: [ToolCall(
                    id: "call-\(request.sessionID)-\(sampleNumber)",
                    name: scriptedToolName,
                    arguments: "{}"
                )]
            )
        }
        return OpenGrokLiveSamplingResponse(output: "delegated investigation completed")
    }

    func samples(for sessionID: String) -> [OpenGrokLiveSamplingRequest] {
        requests.filter { $0.sessionID == sessionID }
    }
}

private actor ParentSessionStandaloneSearchBackend: LiveStandaloneWebSearchBackend {
    private(set) var invocations: [JSONValue] = []

    func search(commands: JSONValue) async throws -> String {
        invocations.append(commands)
        return "PARENT_SESSION_HISTORY_MUST_NEVER_REACH_CHILD"
    }
}

private enum SubagentContextForkFixtureError: Error {
    case spawnFailed(String)
}

private struct SubagentContextForkFixture {
    let root: URL
    let workspace: URL
    let store: LiveConversationStore
    let host: LiveSubagentHost
    let probe: SubagentContextForkProbe

    init(
        parentModel: String = "gpt-5.6-sol",
        parentProvider: ModelProvider = .codex,
        parentItems: [ConversationItem] = [],
        modelDefaults: [String: ModelSubagentContextMode] = [:],
        childProviders: [String: ModelProvider] = [:],
        parentWebToolContext: LiveWebToolContext? = nil,
        parentMaxTurns: Int? = nil,
        definitionMaxTurns: Int? = nil,
        scriptedToolRounds: Int = 0,
        scriptedToolName: String = "context_parity_missing_tool"
    ) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-subagent-context-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]
        let store = LiveConversationStore(openGrokHome: home)
        self.store = store
        var parentRecord = LiveConversationRecord.new(
            sessionID: "context-parent",
            workingDirectory: workspace
        )
        parentRecord.currentModelID = parentModel
        parentRecord.currentProvider = parentProvider
        parentRecord.items = parentItems
        try await store.save(parentRecord)

        let history = LiveConversationHistory(record: parentRecord, store: store)
        let probe = SubagentContextForkProbe(
            scriptedToolRounds: scriptedToolRounds,
            scriptedToolName: scriptedToolName
        )
        self.probe = probe
        let sampler = OpenGrokLiveSampler { request, _ in
            await probe.sample(request)
        }
        var agents: [AgentDefinition] = []
        if let definitionMaxTurns {
            var definition = AgentDefinition.builtinDefaults(
                name: "bounded-worker",
                description: "Bounded context parity worker"
            )
            definition.maxTurns = definitionMaxTurns
            agents.append(definition)
        }
        let modelSlugs = Array(Set(
            [parentModel, "gpt-5.6-luna", "grok-4.5"]
                + Array(modelDefaults.keys)
                + Array(childProviders.keys)
        )).sorted()
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false
        )
        let host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: parentModel,
            workingDirectory: workspace,
            sessionID: "context-parent",
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
            webToolContext: parentWebToolContext,
            environment: environment,
            parentCapabilityCeiling: nil,
            definitionContext: DefinitionResolutionContext(
                cwd: workspace,
                cliAgents: agents,
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: modelSlugs,
            parentProvider: parentProvider,
            childSamplerFactory: { model, _ in
                LiveSubagentHost.ChildSamplerRoute(
                    sampler: sampler,
                    provider: childProviders[model] ?? parentProvider
                )
            },
            parentMaxTurns: parentMaxTurns,
            childModelContextDefault: { modelDefaults[$0] }
        ))
        await host.installParentUsageHistory(history)
        self.host = host
    }

    @discardableResult
    func spawn(
        id: String,
        prompt: String = "continue the delegated investigation",
        model: String? = nil,
        context: String? = nil,
        resumeFrom: String? = nil,
        subagentType: String = "general-purpose"
    ) async throws -> OpenGrokShellToolCallResult {
        var arguments: [String: JSONValue] = [
            "task_id": .string(id),
            "prompt": .string(prompt),
            "description": .string("subagent context parity"),
            "subagent_type": .string(subagentType),
            "background": .bool(false),
        ]
        if let model { arguments["model"] = .string(model) }
        if let context { arguments["context"] = .string(context) }
        if let resumeFrom { arguments["resume_from"] = .string(resumeFrom) }

        let outcome = await host.spawn(
            args: .object(arguments),
            toolCallID: "context-call-\(id)"
        )
        guard case .success(let result) = outcome else {
            throw SubagentContextForkFixtureError.spawnFailed(String(describing: outcome))
        }
        return result
    }

    func dispose() async {
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live subagent context fork parity", .serialized)
struct LiveSubagentContextForkParityTests {
    @Test("task input accepts exact Rust context aliases and preserves omission")
    func taskContextWireAliases() throws {
        let aliases: [(String, SubagentContextMode)] = [
            ("fork", .fork),
            ("Fork", .fork),
            ("forked", .fork),
            ("Forked", .fork),
            ("fresh", .fresh),
            ("Fresh", .fresh),
            ("new", .fresh),
            ("clean", .fresh),
        ]
        for (alias, expected) in aliases {
            let value = try JSONDecoder().decode(
                TaskToolInput.self,
                from: Data(#"{"prompt":"p","description":"d","context":"\#(alias)"}"#.utf8)
            )
            #expect(value.context == expected)
            let object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
            )
            #expect(object["context"] as? String == expected.rawValue)
        }

        let omitted = try JSONDecoder().decode(
            TaskToolInput.self,
            from: Data(#"{"prompt":"p","description":"d"}"#.utf8)
        )
        #expect(omitted.context == nil)
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(omitted)) as? [String: Any]
        )
        #expect(encoded["context"] == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                TaskToolInput.self,
                from: Data(#"{"prompt":"p","description":"d","context":"FORK"}"#.utf8)
            )
        }
    }

    @Test("the model-facing task schema exposes fork and fresh")
    func taskSchemaAdvertisesContext() async throws {
        let fixture = try await SubagentContextForkFixture()
        defer { Task { await fixture.dispose() } }

        guard case .object(let schema) = fixture.host.toolSpec.parameters,
              case .object(let properties)? = schema["properties"],
              case .object(let context)? = properties["context"]
        else {
            Issue.record("spawn_subagent does not advertise the context parameter")
            return
        }
        #expect(context["type"] == .string("string"))
        #expect(context["enum"] == .array([.string("fork"), .string("fresh")]))
        #expect(context["description"]?.stringValue?.contains("child's model") == true)
    }

    @Test("omitted context uses the child model default and preserves the same-model prefix")
    func omittedContextForksVerbatimOnSameModel() async throws {
        let raw = ConversationItem.backendToolCall(BackendToolCallItem(kind: .codexRawInput(
            CodexRawInputItem(
                id: "opaque-parent-state",
                raw: .object(["encrypted_content": .string("SAME_MODEL_OPAQUE_STATE")])
            )
        )))
        let parentItems: [ConversationItem] = [
            .system("parent original system prompt"),
            .user("parent investigation question"),
            .userMeta("cached synthetic reminder stays verbatim"),
            raw,
            .assistant(AssistantItem(
                content: "parent investigation finding",
                modelId: "parent-provider-model-metadata"
            )),
        ]
        let fixture = try await SubagentContextForkFixture(
            parentItems: parentItems,
            modelDefaults: ["gpt-5.6-sol": .fork]
        )
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "verbatim-child", prompt: "extend the current analysis")
        let requests = await fixture.probe.samples(for: "verbatim-child")
        let request = try #require(requests.first)
        #expect(request.items == parentItems + [.user("extend the current analysis")])
    }

    @Test("an explicit fresh request overrides a fork-default model")
    func explicitFreshOverridesModelDefault() async throws {
        let fixture = try await SubagentContextForkFixture(
            parentItems: [.user("PARENT_HISTORY_MUST_NOT_APPEAR"), .assistant("parent answer")],
            modelDefaults: ["gpt-5.6-sol": .fork]
        )
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "fresh-child", context: "new")
        let requests = await fixture.probe.samples(for: "fresh-child")
        let request = try #require(requests.first)
        let serialized = String(decoding: try JSONEncoder().encode(request.items), as: UTF8.self)
        #expect(!serialized.contains("PARENT_HISTORY_MUST_NOT_APPEAR"))
    }

    @Test("an explicit fork overrides a fresh model default")
    func explicitForkOverridesModelDefault() async throws {
        let parentItems: [ConversationItem] = [
            .user("explicit fork must inherit this finding"),
            .assistant("the parent already verified it"),
        ]
        let fixture = try await SubagentContextForkFixture(
            parentItems: parentItems,
            modelDefaults: ["gpt-5.6-sol": .fresh]
        )
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "explicit-fork", context: "forked")
        let requests = await fixture.probe.samples(for: "explicit-fork")
        let request = try #require(requests.first)
        #expect(Array(request.items.prefix(parentItems.count)) == parentItems)
    }

    @Test("omission resolves the effective child's default, never the parent's")
    func childModelOwnsDefaultPrecedence() async throws {
        let fixture = try await SubagentContextForkFixture(
            parentItems: [.user("CHILD_MODEL_DEFAULT_HISTORY"), .assistant("parent finding")],
            modelDefaults: [
                "gpt-5.6-sol": .fork,
                "gpt-5.6-luna": .fresh,
            ]
        )
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "fresh-model-child", model: "gpt-5.6-luna")
        let requests = await fixture.probe.samples(for: "fresh-model-child")
        let request = try #require(requests.first)
        let serialized = String(decoding: try JSONEncoder().encode(request.items), as: UTF8.self)
        #expect(!serialized.contains("CHILD_MODEL_DEFAULT_HISTORY"))
        #expect(!serialized.contains("<forked_context>"))
    }

    @Test("different models receive sanitized digest only, even on the same provider")
    func crossModelDigestNeverTransfersProviderState() async throws {
        let parentItems: [ConversationItem] = [
            .system("SYSTEM_PROVIDER_SECRET"),
            .user("safe user investigation"),
            .userMeta("SYNTHETIC_PROVIDER_SECRET"),
            .assistant(AssistantItem(
                content: "safe assistant finding",
                toolCalls: [ToolCall(
                    id: "opaque-call",
                    name: "read_file",
                    arguments: "TOOL_ARGUMENT_PROVIDER_SECRET"
                )],
                modelId: "MODEL_METADATA_PROVIDER_SECRET"
            )),
            .toolResult(ToolResultItem(
                toolCallId: "opaque-call",
                content: "TOOL_RESULT_PROVIDER_SECRET"
            )),
            .reasoning(ReasoningItem(
                id: "reasoning-provider-id",
                summary: [.summaryText(text: "safe reasoning summary")],
                content: [ReasoningTextContent(text: "RAW_REASONING_PROVIDER_SECRET")],
                encryptedContent: "ENCRYPTED_PROVIDER_SECRET"
            )),
            .backendToolCall(BackendToolCallItem(kind: .codexRawInput(CodexRawInputItem(
                id: "opaque-provider-item",
                raw: .object([
                    "encrypted_content": .string("OPAQUE_PROVIDER_SECRET"),
                    "authorization": .string("BEARER_CREDENTIAL_SECRET"),
                ]),
                crossProviderFallback: "safe provider-neutral fallback"
            )))),
            .assistant("final safe parent finding"),
        ]
        let fixture = try await SubagentContextForkFixture(
            parentItems: parentItems,
            modelDefaults: ["gpt-5.6-luna": .fork],
            childProviders: ["gpt-5.6-luna": .codex]
        )
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "digest-child", model: "gpt-5.6-luna")
        let requests = await fixture.probe.samples(for: "digest-child")
        let request = try #require(requests.first)
        let serialized = String(decoding: try JSONEncoder().encode(request.items), as: UTF8.self)
        #expect(serialized.contains("<forked_context>"))
        #expect(serialized.contains("safe user investigation"))
        #expect(serialized.contains("safe assistant finding"))
        #expect(serialized.contains("safe reasoning summary"))
        #expect(serialized.contains("safe provider-neutral fallback"))
        #expect(serialized.contains("read_file"))
        for secret in [
            "SYSTEM_PROVIDER_SECRET",
            "SYNTHETIC_PROVIDER_SECRET",
            "TOOL_ARGUMENT_PROVIDER_SECRET",
            "MODEL_METADATA_PROVIDER_SECRET",
            "TOOL_RESULT_PROVIDER_SECRET",
            "RAW_REASONING_PROVIDER_SECRET",
            "ENCRYPTED_PROVIDER_SECRET",
            "OPAQUE_PROVIDER_SECRET",
            "BEARER_CREDENTIAL_SECRET",
        ] {
            #expect(!serialized.contains(secret))
        }
        #expect(!request.items.contains { item in
            switch item {
            case .reasoning, .backendToolCall, .toolResult, .customToolOutput:
                return true
            case .system, .user, .assistant:
                return false
            }
        })
    }

    @Test("cross-provider forks receive plaintext context through their isolated sampler")
    func crossProviderDigestNeverTransfersCredentials() async throws {
        let parentItems: [ConversationItem] = [
            .user("safe cross-provider investigation"),
            .backendToolCall(BackendToolCallItem(kind: .codexRawInput(CodexRawInputItem(
                id: "codex-opaque-history",
                raw: .object([
                    "authorization": .string("PARENT_CODEX_BEARER_SECRET"),
                    "encrypted_content": .string("PARENT_CODEX_ENCRYPTED_SECRET"),
                ])
            )))),
            .assistant("safe Codex investigation finding"),
        ]
        let fixture = try await SubagentContextForkFixture(
            parentItems: parentItems,
            modelDefaults: ["grok-4.5": .fork],
            childProviders: ["grok-4.5": .xai]
        )
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "xai-digest-child", model: "grok-4.5")
        let requests = await fixture.probe.samples(for: "xai-digest-child")
        let request = try #require(requests.first)
        let serialized = String(decoding: try JSONEncoder().encode(request.items), as: UTF8.self)
        #expect(request.model == "grok-4.5")
        #expect(request.codexPermissions == nil)
        #expect(serialized.contains("<forked_context>"))
        #expect(serialized.contains("safe cross-provider investigation"))
        #expect(serialized.contains("safe Codex investigation finding"))
        #expect(!serialized.contains("PARENT_CODEX_BEARER_SECRET"))
        #expect(!serialized.contains("PARENT_CODEX_ENCRYPTED_SECRET"))
        let record = try #require(await fixture.store.loadIfPresent(
            sessionID: "xai-digest-child"
        ))
        #expect(record.currentProvider == .xai)
    }

    @Test("child tools never inherit the parent's authenticated standalone search backend")
    func parentStandaloneSearchBackendCannotCrossChildSession() async throws {
        let parentBackend = ParentSessionStandaloneSearchBackend()
        let parentWebContext = LiveWebToolContext(
            availability: .unavailable,
            transport: MockHTTPTransport(),
            standaloneWebSearchBackend: parentBackend
        )
        let fixture = try await SubagentContextForkFixture(
            parentItems: [.user("PARENT_SESSION_HISTORY_MUST_NEVER_REACH_CHILD")],
            parentWebToolContext: parentWebContext,
            scriptedToolRounds: 1,
            scriptedToolName: "web__run"
        )
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "isolated-web-child")
        let requests = await fixture.probe.samples(for: "isolated-web-child")
        let request = try #require(requests.first)
        #expect(!request.tools.contains { $0.name == "web__run" })
        #expect(requests.count == 2)
        #expect(await parentBackend.invocations.isEmpty)
    }

    @Test("resume wins over an explicit fork and a fork-default child model")
    func resumeAlwaysBeatsFork() async throws {
        let fixture = try await SubagentContextForkFixture(
            parentItems: [.user("PARENT_HISTORY_MUST_NOT_REPLACE_RESUME")],
            modelDefaults: ["gpt-5.6-sol": .fork]
        )
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(
            id: "resume-source",
            prompt: "ORIGINAL_CHILD_TRANSCRIPT",
            context: "fresh"
        )
        let original = try #require(await fixture.store.loadIfPresent(sessionID: "resume-source"))
        try await fixture.spawn(
            id: "resume-continuation",
            prompt: "continue the prior child",
            context: "fork",
            resumeFrom: "resume-source"
        )

        let requests = await fixture.probe.samples(for: "resume-continuation")
        let request = try #require(requests.first)
        #expect(request.items == original.items + [.user("continue the prior child")])
        let serialized = String(decoding: try JSONEncoder().encode(request.items), as: UTF8.self)
        #expect(serialized.contains("ORIGINAL_CHILD_TRANSCRIPT"))
        #expect(!serialized.contains("PARENT_HISTORY_MUST_NOT_REPLACE_RESUME"))
    }

    @Test("same-model forks discard only dangling parent tool-call tails")
    func cleanPrefixPreservesCompleteToolPairs() {
        let completed = ToolCall(id: "completed-call", name: "read_file", arguments: "{}")
        let dangling = ToolCall(id: "dangling-call", name: "task", arguments: "{}")
        let clean: [ConversationItem] = [
            .system("original system"),
            .user("investigate"),
            .assistant(AssistantItem(content: "", toolCalls: [completed])),
            .toolResult(ToolResultItem(toolCallId: completed.callId, content: "finding")),
            .assistant("completed parent turn"),
        ]
        let incomplete = clean + [
            .reasoning(ReasoningItem(id: "pending-reasoning")),
            .assistant(AssistantItem(content: "", toolCalls: [dangling])),
        ]

        #expect(LiveSubagentHost.cleanForkPrefix(incomplete) == clean)
    }

    @Test("children without configured turn limits continue beyond sixteen tool rounds")
    func absentTurnLimitDoesNotInventSixteenRoundCeiling() async throws {
        let fixture = try await SubagentContextForkFixture(scriptedToolRounds: 17)
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "unlimited-child")
        let requests = await fixture.probe.samples(for: "unlimited-child")
        #expect(requests.count == 18)
        let snapshot = try #require(await fixture.host.subagentSnapshot(id: "unlimited-child"))
        #expect(snapshot.status == "completed")
        #expect(snapshot.turnCount == 17)
    }

    @Test("a child definition turn limit overrides the inherited parent limit")
    func childDefinitionOwnsTurnLimit() async throws {
        let fixture = try await SubagentContextForkFixture(
            parentMaxTurns: 1,
            definitionMaxTurns: 3,
            scriptedToolRounds: 5
        )
        defer { Task { await fixture.dispose() } }

        let outcome = await fixture.host.spawn(
            args: .object([
                "task_id": .string("bounded-child"),
                "prompt": .string("keep calling tools"),
                "description": .string("bounded parity worker"),
                "subagent_type": .string("bounded-worker"),
                "background": .bool(false),
            ]),
            toolCallID: "bounded-call"
        )
        guard case .failure(.invalidCall(let message)) = outcome else {
            Issue.record("bounded child did not report its configured turn limit: \(outcome)")
            return
        }
        #expect(message.contains("exceeded 3 tool rounds"))
        let requests = await fixture.probe.samples(for: "bounded-child")
        #expect(requests.count == 3)
        let snapshot = try #require(await fixture.host.subagentSnapshot(id: "bounded-child"))
        #expect(snapshot.status == "failed")
        #expect(snapshot.turnCount == 3)
    }

    @Test("children inherit a parent turn limit when their definition has none")
    func parentTurnLimitIsInherited() async throws {
        let fixture = try await SubagentContextForkFixture(
            parentMaxTurns: 2,
            scriptedToolRounds: 5
        )
        defer { Task { await fixture.dispose() } }

        let outcome = await fixture.host.spawn(
            args: .object([
                "task_id": .string("parent-bounded-child"),
                "prompt": .string("keep calling tools"),
                "description": .string("inherited turn limit"),
                "subagent_type": .string("general-purpose"),
                "background": .bool(false),
            ]),
            toolCallID: "parent-bounded-call"
        )
        guard case .failure(.invalidCall(let message)) = outcome else {
            Issue.record("parent-bounded child did not report its inherited limit: \(outcome)")
            return
        }
        #expect(message.contains("exceeded 2 tool rounds"))
        let requests = await fixture.probe.samples(for: "parent-bounded-child")
        #expect(requests.count == 2)
        let snapshot = try #require(await fixture.host.subagentSnapshot(id: "parent-bounded-child"))
        #expect(snapshot.status == "failed")
        #expect(snapshot.turnCount == 2)
    }
}
