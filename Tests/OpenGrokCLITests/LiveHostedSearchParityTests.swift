import Foundation
import OpenGrokAgentDefinitions
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokSubagentResolution
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private func hostedSearchParityPolicy(
    configuration: TOMLValue = .table(TOMLTable()),
    environment: [String: String] = [:],
    disableWebSearch: Bool = false,
    toolPolicy: LiveAgentToolPolicy? = nil,
    permissionRules: [PermissionRule] = []
) -> LiveHostedSearchPolicy {
    LiveHostedSearchComposition.policy(
        environment: environment,
        configuration: configuration,
        disableWebSearch: disableWebSearch,
        toolPolicy: toolPolicy,
        permissionRules: permissionRules
    )
}

private func hostedSearchParityTools(
    provider: ModelProvider,
    backend: ApiBackend = .responses,
    modelSupportsBackendSearch: Bool = true,
    policy: LiveHostedSearchPolicy = .unrestricted,
    availableFunctionTools: [ToolSpec] = [],
    existingHostedTools: [HostedTool] = []
) -> [HostedTool] {
    LiveHostedSearchComposition.resolve(
        provider: provider,
        backend: backend,
        modelSupportsBackendSearch: modelSupportsBackendSearch,
        policy: policy,
        availableFunctionTools: availableFunctionTools,
        existingHostedTools: existingHostedTools
    )
}

private actor HostedChildSamplingCapture {
    private var recorded: [OpenGrokLiveSamplingRequest] = []

    func append(_ request: OpenGrokLiveSamplingRequest) {
        recorded.append(request)
    }

    func snapshot() -> [OpenGrokLiveSamplingRequest] {
        recorded
    }
}

@Suite("Live provider-hosted search parity")
struct LiveHostedSearchParityTests {
    private func childSamplingRequest(
        provider: ModelProvider = .codex,
        backend: ApiBackend? = .responses,
        modelSupportsBackendSearch: Bool? = true,
        parentPolicy: LiveHostedSearchPolicy? = .unrestricted,
        disableWebSearch: Bool = false,
        definition: AgentDefinition = AgentDefinition(
            name: "search-child",
            description: "search the web"
        ),
        permissionRules: [PermissionRule] = [],
        crossProvider: ModelProvider? = nil
    ) async throws -> OpenGrokLiveSamplingRequest {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hosted-search-child-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]
        let capture = HostedChildSamplingCapture()
        let sampler = OpenGrokLiveSampler { request, _ in
            await capture.append(request)
            return OpenGrokLiveSamplingResponse(
                output: "child completed",
                usage: TokenUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2)
            )
        }
        var security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false
        )
        security.permissions.config.rules = permissionRules
        let childFactory: (
            @Sendable (String, CodexPermissions?) async throws -> LiveSubagentHost.ChildSamplerRoute
        )?
        if let crossProvider {
            childFactory = { _, inheritedPermissions in
                LiveSubagentHost.ChildSamplerRoute(
                    sampler: sampler,
                    provider: crossProvider,
                    codexPermissions: inheritedPermissions,
                    apiBackend: backend,
                    supportsBackendSearch: modelSupportsBackendSearch
                )
            }
        } else {
            childFactory = nil
        }
        let host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: "parent-search-model",
            workingDirectory: workspace,
            sessionID: "parent-search-session",
            openGrokHome: home,
            conversationStore: LiveConversationStore(openGrokHome: home),
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            securityContext: security,
            sandboxDecision: LiveSandboxDecision(profileName: "none", mode: .none, enforced: false),
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
            modelSlugs: ["parent-search-model", "child-search-model"],
            parentProvider: provider,
            parentHostedSearchPolicy: parentPolicy,
            parentAPIBackend: backend,
            parentSupportsBackendSearch: modelSupportsBackendSearch,
            disableWebSearch: disableWebSearch,
            childSamplerFactory: childFactory
        ))
        let result = await host.runChild(
            childID: "hosted-search-child",
            prompt: "Find relevant documentation",
            definition: definition,
            runtime: EffectiveRuntimeConfig(),
            model: crossProvider == nil ? "parent-search-model" : "child-search-model",
            cwd: workspace,
            resumeItems: nil
        )
        await host.shutdown()
        #expect(result.success, "child runner failed: \(result.error ?? "unknown error")")
        let recorded = await capture.snapshot()
        #expect(recorded.count == 1)
        return try #require(recorded.first)
    }

    private func productionRequestBody(
        provider: ModelProvider,
        hostedTools: [HostedTool],
        functionTools: [ToolSpec] = []
    ) async throws -> JSONValue {
        let completed = #"{"type":"response.completed","response":{"id":"response-1","model":"search-test","status":"completed","output":[{"type":"message","role":"assistant","content":"ok"}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data("data: \(completed)\n\n".utf8)
            ),
        ])
        let sampler = try OpenGrokLiveSampler.production(
            configuration: OpenGrokLiveSamplingConfiguration(
                model: "search-test",
                baseURL: "https://provider.example.test",
                apiKey: "provider-owned-bearer",
                provider: provider,
                apiBackend: .responses,
                tuning: OpenGrokLiveSamplingTuning(supportsBackendSearch: true),
                transport: transport
            )
        )
        let response = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "hosted-search-session",
                turnID: "hosted-search-turn",
                model: "search-test",
                prompt: "search",
                tools: functionTools,
                hostedTools: hostedTools
            ),
            emit: { _ in }
        )
        #expect(response.output == "ok")
        #expect(transport.recordedRequests.count == 1)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer provider-owned-bearer")
        return try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
    }

    @Test("real Codex production requests include native custom exec and hosted web, never xAI search")
    func codexCapabilitiesReachActualProviderRequest() async throws {
        let exec = HostedTool.clientCustom(CustomToolSpec(
            name: "exec",
            description: "run code",
            format: .grammar
        ))
        let hosted = hostedSearchParityTools(provider: .codex, existingHostedTools: [exec])
        let body = try await productionRequestBody(provider: .codex, hostedTools: hosted)
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["type"]?.stringValue } == ["custom", "web_search"])
        #expect(tools[0]["name"]?.stringValue == "exec")
        #expect(tools[0]["format"]?["type"]?.stringValue == "grammar")
        #expect(tools[1]["external_web_access"]?.boolValue == true)
        #expect(body["include"] == .array([
            .string("web_search_call.action.sources"),
            .string("reasoning.encrypted_content"),
        ]))
    }

    @Test("real xAI production requests contain exactly one native web and one X search")
    func xaiCapabilitiesReachActualProviderRequest() async throws {
        let hosted = hostedSearchParityTools(provider: .xai)
        let body = try await productionRequestBody(
            provider: .xai,
            hostedTools: hosted,
            functionTools: [
                ToolSpec(name: "web_search", description: nil, parameters: .object([:])),
            ]
        )
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["type"]?.stringValue } == ["web_search", "x_search"])
        #expect(!tools.contains { $0["type"]?.stringValue == "function" })
    }

    @Test("a no-web session sends neither search descriptor on an actual provider request")
    func noWebNeverReachesProductionWire() async throws {
        let hosted = hostedSearchParityTools(
            provider: .codex,
            policy: hostedSearchParityPolicy(disableWebSearch: true)
        )
        let body = try await productionRequestBody(provider: .codex, hostedTools: hosted)
        #expect(body["tools"] == nil)
        #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
    }

    @Test("a real child turn carries the provider-native web descriptor but no unsupported custom exec")
    func childTurnReceivesAuthorizedHostedSearch() async throws {
        let request = try await childSamplingRequest(provider: .codex)
        #expect(request.hostedTools.map(\.wireName) == ["web_search"])
        #expect(!request.hostedTools.contains {
            if case .clientCustom = $0 { return true }
            return false
        })
    }

    @Test("the inherited no-web master switch removes child web and X search")
    func childTurnHonorsNoWebMasterSwitch() async throws {
        let request = try await childSamplingRequest(provider: .xai, disableWebSearch: true)
        #expect(request.hostedTools.isEmpty)
    }

    @Test("child definition denylists narrow provider-native capabilities")
    func childDefinitionDeniesHostedSearch() async throws {
        let definition = AgentDefinition(
            name: "no-search-child",
            description: "search forbidden",
            disallowedTools: ["web_search", "x_search"]
        )
        let request = try await childSamplingRequest(provider: .xai, definition: definition)
        #expect(request.hostedTools.isEmpty)
    }

    @Test("a parent deny remains binding even when the child profile allows search")
    func childCannotWidenParentHostedPolicy() async throws {
        let parent = LiveHostedSearchPolicy(
            backendSearchEnabled: true,
            webSearchAllowed: false,
            xSearchAllowed: false,
            allowedDomains: nil,
            excludedDomains: nil
        )
        let definition = AgentDefinition(
            name: "search-child",
            description: "attempt to widen parent policy",
            tools: ["web_search", "x_search"]
        )
        let request = try await childSamplingRequest(
            provider: .xai,
            parentPolicy: parent,
            definition: definition
        )
        #expect(request.hostedTools.isEmpty)
    }

    @Test("child-hosted execution cannot bypass ask and deny permission rules",
          arguments: [RuleAction.ask, .deny])
    func childPermissionRulesFailClosed(_ action: RuleAction) async throws {
        let request = try await childSamplingRequest(
            provider: .codex,
            permissionRules: [PermissionRule(action: action, tool: .webSearch)]
        )
        #expect(request.hostedTools.isEmpty)
    }

    @Test("providers and models without hosted-search support receive no child descriptors")
    func unsupportedChildRouteRemainsSearchFree() async throws {
        let unsupportedProvider = try await childSamplingRequest(
            provider: .kimi,
            backend: .chatCompletions
        )
        #expect(unsupportedProvider.hostedTools.isEmpty)

        let unsupportedModel = try await childSamplingRequest(
            provider: .codex,
            modelSupportsBackendSearch: false
        )
        #expect(unsupportedModel.hostedTools.isEmpty)
    }

    @Test("missing parent policy or authoritative route metadata fails closed")
    func childMissingSearchAuthorityFailsClosed() async throws {
        let noParentPolicy = try await childSamplingRequest(parentPolicy: nil)
        #expect(noParentPolicy.hostedTools.isEmpty)

        let noBackend = try await childSamplingRequest(backend: nil)
        #expect(noBackend.hostedTools.isEmpty)

        let noModelCapability = try await childSamplingRequest(modelSupportsBackendSearch: nil)
        #expect(noModelCapability.hostedTools.isEmpty)
    }

    @Test("cross-provider child routes keep destination search capabilities without leaking X search")
    func crossProviderChildUsesItsOwnHostedDialect() async throws {
        let request = try await childSamplingRequest(
            provider: .xai,
            crossProvider: .codex
        )
        #expect(request.hostedTools.map(\.wireName) == ["web_search"])
    }

    @Test("Codex, DeepSeek Responses and Meta expose web but never xAI X search",
          arguments: [ModelProvider.codex, .deepseek, .meta])
    func openAIDialectsExposeOnlyWeb(_ provider: ModelProvider) {
        #expect(hostedSearchParityTools(provider: provider).map(\.wireName) == ["web_search"])
    }

    @Test("xAI Responses offers both native search capabilities")
    func xaiExposesWebAndXSearch() {
        #expect(hostedSearchParityTools(provider: .xai).map(\.wireName)
            == ["web_search", "x_search"])
    }

    @Test("providers without native search never inherit another provider's tools",
          arguments: [ModelProvider.kimi, .fireworks, .wafer, .openCodeGo, .zai,
                      .runinfra, .gemini, .openRouter])
    func unsupportedProvidersRemainIsolated(_ provider: ModelProvider) {
        #expect(hostedSearchParityTools(
            provider: provider,
            existingHostedTools: [.webSearch(allowedDomains: nil), .xSearch]
        ).isEmpty)
    }

    @Test("Chat Completions and Messages never receive Responses hosted tools",
          arguments: [ApiBackend.chatCompletions, .messages])
    func nonResponsesBackendsDoNotExposeHostedSearch(_ backend: ApiBackend) {
        #expect(hostedSearchParityTools(provider: .xai, backend: backend).isEmpty)
    }

    @Test("the current model capability gates search after a model switch")
    func modelCapabilityIsEvaluatedForEveryProviderSnapshot() {
        #expect(hostedSearchParityTools(
            provider: .codex,
            modelSupportsBackendSearch: false
        ).isEmpty)
        #expect(hostedSearchParityTools(
            provider: .deepseek,
            modelSupportsBackendSearch: true
        ).map(\.wireName) == ["web_search"])
    }

    @Test("environment overrides feature policy; backend search otherwise defaults on")
    func backendSearchFlagPrecedence() throws {
        let disabledConfiguration = try parseTOML("[features]\nbackend_tools = false\n")
        let enabledConfiguration = try parseTOML("[features]\nbackend_tools = true\n")

        #expect(hostedSearchParityPolicy().backendSearchEnabled)
        #expect(!hostedSearchParityPolicy(configuration: disabledConfiguration).backendSearchEnabled)
        #expect(hostedSearchParityPolicy(
            configuration: disabledConfiguration,
            environment: ["GROK_BACKEND_SEARCH": "true"]
        ).backendSearchEnabled)
        #expect(!hostedSearchParityPolicy(
            configuration: enabledConfiguration,
            environment: ["GROK_BACKEND_SEARCH": "0"]
        ).backendSearchEnabled)
    }

    @Test("the no-web master switch removes web and X search but preserves Code Mode exec")
    func noWebDoesNotDiscardNativeCustomExec() {
        let exec = HostedTool.clientCustom(CustomToolSpec(
            name: "exec",
            description: "execute Code Mode",
            format: .grammar
        ))
        let policy = hostedSearchParityPolicy(disableWebSearch: true)
        #expect(hostedSearchParityTools(
            provider: .codex,
            policy: policy,
            existingHostedTools: [exec, .webSearch(allowedDomains: nil), .xSearch]
        ) == [exec])
        #expect(hostedSearchParityTools(provider: .xai, policy: policy).isEmpty)
    }

    @Test("agent own allowlists gate hosted names without requiring tool_config membership")
    func hostedAllowlistDoesNotDependOnClientToolCatalog() {
        let definition = AgentDefinition(
            name: "search-only",
            description: "hosted search",
            tools: ["GrokBuild:web_search"]
        )
        let policy = hostedSearchParityPolicy(toolPolicy: LiveAgentToolPolicy(definition: definition))
        #expect(hostedSearchParityTools(provider: .xai, policy: policy).map(\.wireName)
            == ["web_search"])
    }

    @Test("deny rules win over wildcard allowlists and session clamps")
    func hostedDeniesAndSessionClamps() {
        var definition = AgentDefinition(
            name: "clamped-search",
            description: "session-restricted search",
            tools: ["*"],
            disallowedTools: ["GrokBuild:x_search"]
        )
        definition.sessionToolsAllowlist = ["GrokBuild:web_search"]
        var policy = hostedSearchParityPolicy(toolPolicy: LiveAgentToolPolicy(definition: definition))
        #expect(hostedSearchParityTools(provider: .xai, policy: policy).map(\.wireName)
            == ["web_search"])

        definition.sessionToolsDenylist = ["web_search"]
        policy = hostedSearchParityPolicy(toolPolicy: LiveAgentToolPolicy(definition: definition))
        #expect(hostedSearchParityTools(provider: .xai, policy: policy).isEmpty)
    }

    @Test("a CLI --tools allowlist cannot leak unlisted hosted capabilities")
    func commandLineToolAllowlistAppliesToHostedSearch() {
        let toolPolicy = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: "read_file,web_search",
            disallowedTools: nil,
            profile: nil
        )
        let policy = hostedSearchParityPolicy(toolPolicy: toolPolicy)
        #expect(hostedSearchParityTools(provider: .xai, policy: policy).map(\.wireName)
            == ["web_search"])
    }

    @Test("provider-side search cannot bypass explicit deny or ask permission rules",
          arguments: [RuleAction.deny, .ask])
    func permissionRulesFailClosed(_ action: RuleAction) {
        let policy = hostedSearchParityPolicy(permissionRules: [
            PermissionRule(action: action, tool: .webSearch, pattern: "private.example"),
        ])
        #expect(hostedSearchParityTools(provider: .xai, policy: policy).isEmpty)
    }

    @Test("a catch-all permission denial also blocks provider-side search")
    func catchAllPermissionDenyFailsClosed() {
        let policy = hostedSearchParityPolicy(permissionRules: [
            PermissionRule(action: .deny, tool: .any),
        ])
        #expect(hostedSearchParityTools(provider: .codex, policy: policy).isEmpty)
    }

    @Test("unrelated permission rules do not disable hosted search")
    func unrelatedPermissionDoesNotAffectSearch() {
        let policy = hostedSearchParityPolicy(permissionRules: [
            PermissionRule(action: .deny, tool: .edit),
            PermissionRule(action: .allow, tool: .webSearch),
        ])
        #expect(hostedSearchParityTools(provider: .codex, policy: policy).map(\.wireName)
            == ["web_search"])
    }

    @Test("a registered replacement suppresses native web only on non-xAI providers")
    func registeredClientReplacementSuppressesNativeWeb() {
        let clientSearch = ToolSpec(name: "web_search", description: nil, parameters: .object([:]))
        #expect(hostedSearchParityTools(
            provider: .codex,
            availableFunctionTools: [clientSearch]
        ).isEmpty)
        #expect(hostedSearchParityTools(
            provider: .xai,
            availableFunctionTools: [clientSearch]
        ).map(\.wireName) == ["web_search", "x_search"])
    }

    @Test("the web__run replacement counts; unrelated or filtered replacements do not")
    func replacementRequiresAnActualRegisteredSearchTool() {
        let webRun = ToolSpec(name: "web__run", description: nil, parameters: .object([:]))
        let unrelated = ToolSpec(name: "read_file", description: nil, parameters: .object([:]))
        #expect(hostedSearchParityTools(
            provider: .meta,
            availableFunctionTools: [webRun]
        ).isEmpty)
        #expect(hostedSearchParityTools(
            provider: .deepseek,
            availableFunctionTools: [unrelated]
        ).map(\.wireName) == ["web_search"])
    }

    @Test("native custom exec stays first and duplicate hosted descriptors are removed")
    func hostedCustomAndSearchMergeDeterministically() {
        let exec = HostedTool.clientCustom(CustomToolSpec(name: "exec", description: nil, format: .grammar))
        let web = HostedTool.webSearch(allowedDomains: nil)
        #expect(hostedSearchParityTools(
            provider: .codex,
            existingHostedTools: [exec, exec, web, web, .xSearch]
        ).map(\.wireName) == ["exec", "web_search"])
    }

    @Test("domain allowlists are trimmed and capped; allow beats exclude")
    func authorizedDomainAllowlistIsPropagated() throws {
        let configuration = try parseTOML("""
        [toolset.web_search]
        allowed_domains = [" a.example ", "b.example", "c.example", "d.example", "e.example", "f.example"]
        excluded_domains = ["blocked.example"]
        """)
        let policy = hostedSearchParityPolicy(configuration: configuration)
        #expect(policy.allowedDomains == [
            "a.example", "b.example", "c.example", "d.example", "e.example",
        ])
        #expect(policy.excludedDomains == nil)
        guard case .webSearch(_, let domains, _, _, _)? = hostedSearchParityTools(
            provider: .codex,
            policy: policy
        ).first else {
            Issue.record("expected an authorized native web-search declaration")
            return
        }
        #expect(domains == policy.allowedDomains)
    }

    @Test("an unrepresentable domain blocklist suppresses web instead of leaking unrestricted search")
    func unsupportedExcludedDomainPolicyFailsClosed() throws {
        let configuration = try parseTOML("""
        [toolset.web_search]
        excluded_domains = ["private.example"]
        """)
        let policy = hostedSearchParityPolicy(configuration: configuration)
        #expect(policy.excludedDomains == ["private.example"])
        #expect(hostedSearchParityTools(provider: .codex, policy: policy).isEmpty)
        #expect(hostedSearchParityTools(provider: .xai, policy: policy).map(\.wireName)
            == ["x_search"])
    }
}
