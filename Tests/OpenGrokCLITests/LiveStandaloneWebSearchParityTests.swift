import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWebMediaTools
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private actor StandaloneParityBackend: LiveStandaloneWebSearchBackend {
    private(set) var commands: [JSONValue] = []
    let output: String

    init(output: String = "provider-authenticated result") {
        self.output = output
    }

    func search(commands: JSONValue) async throws -> String {
        self.commands.append(commands)
        return output
    }
}

private struct StandaloneParityBearerResolver: BearerResolver {
    let token: String
    let account: String

    func currentBearer() -> String? { token }

    func currentAuth() -> ResolvedBearerAuth? {
        ResolvedBearerAuth(
            bearer: token,
            extraHeaders: [(name: "ChatGPT-Account-ID", value: account)]
        )
    }

    var reservedHeaders: [String] { ["Authorization", "ChatGPT-Account-ID"] }
}

private struct StandaloneParityFixture {
    let root: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "standalone-web-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        environment = ["HOME": root.path, "OPENGROK_HOME": root.path]
    }

    func writeConfig(_ value: String) throws {
        try value.write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func history(
        sessionID: String,
        items: [ConversationItem],
        provider: ModelProvider? = .codex,
        model: String? = "gpt-test"
    ) -> LiveConversationHistory {
        var record = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: root
        )
        record.items = items
        record.currentProvider = provider
        record.currentModelID = model
        return LiveConversationHistory(
            record: record,
            store: LiveConversationStore(openGrokHome: root)
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func standaloneParityToolset(
    backend: any LiveStandaloneWebSearchBackend,
    permissionPipeline: PermissionPipeline? = nil
) throws -> FinalizedToolset {
    var builder = ToolRegistryBuilder(registerBuiltins: false)
    builder.register(
        spec: BuiltinToolCatalog.webRunTools[0],
        handler: LiveStandaloneWebSearchHandler(backend: backend)
    )
    let pipeline = permissionPipeline ?? PermissionPipeline(
        permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory())
    )
    let bridge = try ToolBridge.finalize(
        builder: builder,
        config: ToolServerConfig(tools: [
            ToolConfig.fromId(BuiltinToolCatalog.webRunQualifiedId, kind: .webSearch),
        ]),
        resources: ToolResources(cwd: NSTemporaryDirectory(), permissionPipeline: pipeline),
        options: FinalizeOptions(capabilityMode: .readOnly)
    )
    return bridge.toolset
}

private func standaloneParityResponse(_ output: String) -> MockHTTPTransport.ScriptedResponse {
    .init(
        metadata: HTTPResponseMetadata(statusCode: 200),
        body: Data(#"{"output":"\#(output)"}"#.utf8)
    )
}

@Suite("Live Codex standalone web.run parity")
struct LiveStandaloneWebSearchParityTests {
    @Test("eligibility requires OAuth, Codex Responses, capability, native source, backend, and enabled search")
    func completeFailClosedGate() {
        func eligible(
            disabled: Bool = false,
            provider: ModelProvider = .codex,
            backend: ApiBackend = .responses,
            auth: BuiltInSessionAuthKind = .codexOAuth,
            capability: Bool = true,
            source: LiveWebSearchSource = .native,
            available: Bool = true
        ) -> Bool {
            LiveStandaloneWebSearchComposition.isEnabled(
                disableWebSearch: disabled,
                provider: provider,
                apiBackend: backend,
                authKind: auth,
                supportsStandaloneWebSearch: capability,
                searchSource: source,
                backendAvailable: available
            )
        }

        #expect(eligible())
        #expect(!eligible(disabled: true))
        #expect(!eligible(provider: .xai))
        #expect(!eligible(provider: .kimi))
        #expect(!eligible(backend: .chatCompletions))
        #expect(!eligible(auth: .apiKeyOnly))
        #expect(!eligible(capability: false))
        #expect(!eligible(source: .xai))
        #expect(!eligible(source: .perplexity))
        #expect(!eligible(available: false))
    }

    @Test("only the last two genuine user turns and intervening assistant text reach search")
    func visibleConversationContext() throws {
        let input = try #require(LiveStandaloneWebSearchComposition.requestInput(from: [
            .system("hidden system instructions"),
            .user("obsolete user"),
            .assistant("obsolete assistant"),
            .user("previous user"),
            .systemReminder("hidden reminder"),
            .assistant("intervening assistant"),
            .toolResult(toolCallId: "private", content: "hidden tool result"),
            .agentMessage("hidden synthetic agent message"),
            .user("current user"),
            .assistant("trailing assistant must not escape"),
        ]))
        let wire = try JSONValue.encode(input)
        #expect(wire == .array([
            .object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .array([
                    .object(["type": .string("input_text"), "text": .string("previous user")]),
                ]),
            ]),
            .object([
                "type": .string("message"),
                "role": .string("assistant"),
                "content": .array([
                    .object([
                        "type": .string("output_text"),
                        "text": .string("intervening assistant"),
                    ]),
                ]),
            ]),
            .object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .array([
                    .object(["type": .string("input_text"), "text": .string("current user")]),
                ]),
            ]),
        ]))
    }

    @Test("assistant-only and synthetic-only histories omit search context")
    func absentGenuineUserOmitsContext() {
        #expect(LiveStandaloneWebSearchComposition.requestInput(from: [
            .assistant("assistant only"),
            .systemReminder("synthetic only"),
            .agentMessage("another synthetic message"),
        ]) == nil)
        #expect(LiveStandaloneWebSearchComposition.requestInput(from: [
            .user("  \n  "),
        ]) == nil)
    }

    @Test("assistant context is bounded to upstream's approximate 1,000-token budget")
    func assistantContextBudget() throws {
        let oversized = "prefix-" + String(repeating: "🌍", count: 1_300) + "-suffix"
        let input = try #require(LiveStandaloneWebSearchComposition.requestInput(from: [
            .user("previous"),
            .assistant(oversized),
            .assistant("must disappear once the token budget is exhausted"),
            .user("current"),
        ]))
        guard case .items(let messages) = input else {
            Issue.record("expected item-shaped standalone search context")
            return
        }
        #expect(messages.count == 3)
        guard case .outputText(let assistant)? = messages[1].content.first else {
            Issue.record("expected bounded assistant output text")
            return
        }
        #expect(assistant.hasPrefix("prefix-"))
        #expect(assistant.hasSuffix("-suffix"))
        #expect(assistant.contains("tokens truncated"))
        #expect(!assistant.contains("must disappear"))
        #expect(!assistant.contains("�"))
    }

    @Test("provider envelope uses actual session identity, active model, direct external search, and 10k output")
    func exactRequestEnvelope() async throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        let transport = MockHTTPTransport(responses: [standaloneParityResponse("wire result")])
        let resolver = StandaloneParityBearerResolver(token: "oauth-a", account: "account-a")
        let backend = try SamplerStandaloneWebSearchBackend(
            configuration: SamplerConfig(
                apiKey: "forged-static-token",
                baseURL: "https://chatgpt.com/backend-api/codex",
                model: "configured-model",
                apiBackend: .responses,
                provider: .codex,
                extraHeaders: [(name: "ChatGPT-Account-ID", value: "forged-account")],
                supportsStandaloneWebSearch: true,
                bearerResolver: resolver
            ),
            conversationHistory: fixture.history(
                sessionID: "child-session",
                items: [.user("previous"), .assistant("context"), .user("current")],
                model: "active-model"
            ),
            sessionID: "child-session",
            transport: transport
        )
        let commands: JSONValue = .object([
            "search_query": .array([.object(["q": .string("Open Grok")])]),
            "response_length": .string("medium"),
        ])

        #expect(try await backend.search(commands: commands) == "wire result")
        let request = try #require(transport.recordedRequests.first)
        #expect(request.url.path.hasSuffix("/alpha/search"))
        #expect(request.headers["Authorization"] == "Bearer oauth-a")
        #expect(request.headers["ChatGPT-Account-ID"] == "account-a")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["id"] == .string("child-session"))
        #expect(body["model"] == .string("active-model"))
        #expect(body["commands"] == commands)
        #expect(body["max_output_tokens"]?.uint64Value == 10_000)
        #expect(body["reasoning"] == nil)
        #expect(body["settings"]?["allowed_callers"] == .array([.string("direct")]))
        #expect(body["settings"]?["external_web_access"] == .bool(true))
        #expect(body["input"]?.arrayValue?.count == 3)
    }

    @Test("independent backends never leak account credentials or session identity")
    func accountAndSessionIsolation() async throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        let transport = MockHTTPTransport(responses: [
            standaloneParityResponse("first"),
            standaloneParityResponse("second"),
        ])

        for identity in ["a", "b"] {
            let resolver = StandaloneParityBearerResolver(
                token: "oauth-\(identity)",
                account: "account-\(identity)"
            )
            let backend = try SamplerStandaloneWebSearchBackend(
                configuration: SamplerConfig(
                    baseURL: "https://chatgpt.com/backend-api/codex",
                    model: "model-\(identity)",
                    apiBackend: .responses,
                    provider: .codex,
                    supportsStandaloneWebSearch: true,
                    bearerResolver: resolver
                ),
                conversationHistory: fixture.history(
                    sessionID: "session-\(identity)",
                    items: [.user("private user \(identity)")],
                    model: "model-\(identity)"
                ),
                sessionID: "session-\(identity)",
                transport: transport
            )
            let result = try await backend.search(commands: .object([:]))
            #expect(result == (identity == "a" ? "first" : "second"))
        }

        let requests = transport.recordedRequests
        #expect(requests.count == 2)
        #expect(requests[0].headers["Authorization"] == "Bearer oauth-a")
        #expect(requests[0].headers["ChatGPT-Account-ID"] == "account-a")
        #expect(requests[1].headers["Authorization"] == "Bearer oauth-b")
        #expect(requests[1].headers["ChatGPT-Account-ID"] == "account-b")
        let firstBody = try JSONDecoder().decode(JSONValue.self, from: try #require(requests[0].body))
        let secondBody = try JSONDecoder().decode(JSONValue.self, from: try #require(requests[1].body))
        #expect(firstBody["id"] == .string("session-a"))
        #expect(secondBody["id"] == .string("session-b"))
    }

    @Test("a stale backend fails closed when the active session or provider changes")
    func sessionAndProviderDriftFailClosed() async throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        let configuration = SamplerConfig(
            apiKey: "oauth",
            baseURL: "https://chatgpt.com/backend-api/codex",
            model: "model",
            apiBackend: .responses,
            provider: .codex,
            supportsStandaloneWebSearch: true
        )

        for (historySession, provider) in [("different-session", ModelProvider.codex), ("session", .xai)] {
            let transport = MockHTTPTransport()
            let backend = try SamplerStandaloneWebSearchBackend(
                configuration: configuration,
                conversationHistory: fixture.history(
                    sessionID: historySession,
                    items: [.user("private")],
                    provider: provider
                ),
                sessionID: "session",
                transport: transport
            )
            do {
                let result = try await backend.search(commands: .object([:]))
                Issue.record("identity drift unexpectedly produced \(result)")
            } catch let error as LiveStandaloneWebSearchError {
                #expect(error == .sessionIdentityChanged)
            }
            #expect(transport.recordedRequests.isEmpty)
        }
    }

    @Test("direct and Code Mode nested calls return only the exact output object")
    func exactOutputAndNestedDispatch() async throws {
        let backend = StandaloneParityBackend(output: "compact result")
        let toolset = try standaloneParityToolset(backend: backend)
        let args: JSONValue = .object([
            "image_query": .array([.object(["q": .string("waterfalls")])]),
        ])

        for nested in [false, true] {
            let result = await toolset.prepareAndCall(
                clientName: "web__run",
                args: args,
                nested: nested
            )
            guard case .success(let output) = result else {
                Issue.record("standalone search handler did not dispatch")
                continue
            }
            #expect(output.value == .object(["output": .string("compact result")]))
        }
        #expect(await backend.commands == [args, args])
    }

    @Test("five search queries and explicit nulls never reach the authenticated backend")
    func invalidArgumentsFailClosed() async throws {
        let backend = StandaloneParityBackend()
        let toolset = try standaloneParityToolset(backend: backend)
        let fiveQueries: JSONValue = .array((0..<5).map {
            .object(["q": .string("query \($0)")])
        })

        for args: JSONValue in [
            .object(["search_query": fiveQueries]),
            .object(["search_query": .null]),
            .object(["search_query": .array([
                .object(["q": .string("query"), "domains": .null]),
            ])]),
        ] {
            let result = await toolset.prepareAndCall(clientName: "web__run", args: args)
            guard case .failure(let error) = result else {
                Issue.record("invalid standalone search arguments reached provider")
                continue
            }
            #expect(error.kind == .invalidArguments)
        }
        #expect(await backend.commands.isEmpty)
    }

    @Test("web fetch defaults off and the master switch suppresses explicit opt-in")
    func fetchDefaultAndMasterKillSwitch() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }

        let defaultAvailability = LiveWebToolComposition.resolveAvailability(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: fixture.environment,
            samplingProvider: .xai,
            samplingAPIKey: "xai-token",
            samplingBaseURL: "https://api.x.ai/v1",
            disableWebSearch: false
        )
        #expect(!defaultAvailability.webFetchEnabled)
        #expect(defaultAvailability.fetchConfig == .disabled)

        var enabled = fixture.environment
        enabled["GROK_WEB_FETCH"] = "true"
        let optedIn = LiveWebToolComposition.resolveAvailability(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: enabled,
            samplingProvider: .xai,
            samplingAPIKey: "xai-token",
            samplingBaseURL: "https://api.x.ai/v1",
            disableWebSearch: false
        )
        #expect(optedIn.webFetchEnabled)

        let killed = LiveWebToolComposition.resolveAvailability(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: enabled,
            samplingProvider: .xai,
            samplingAPIKey: "xai-token",
            samplingBaseURL: "https://api.x.ai/v1",
            disableWebSearch: true
        )
        #expect(!killed.webSearchEnabled)
        #expect(!killed.webFetchEnabled)
        #expect(!killed.xSearchEnabled)
        #expect(killed.fetchConfig == .disabled)
    }

    @Test("explicit empty or malformed domain allowlists disable web fetch")
    func explicitEmptyAllowlistDisablesFetch() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        var environment = fixture.environment
        environment["GROK_WEB_FETCH"] = "1"

        for configuration in [
            "[toolset.web_fetch]\nallowed_domains = []\n",
            "[toolset.web_fetch]\nallowed_domains = [123]\n",
            "[toolset.web_fetch]\nallowed_domains = [\"\"]\n",
        ] {
            try fixture.writeConfig(configuration)
            let resolved = LiveWebToolComposition.resolveFetchConfig(
                workingDirectory: fixture.root,
                openGrokHome: fixture.root,
                environment: environment
            )
            #expect(resolved == .disabled)
        }
    }

    @Test("TOML/env egress policy and resource caps are frozen into fetch parameters")
    func frozenFetchPolicyAndPrecedence() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        try fixture.writeConfig("""
            [features]
            web_fetch = true

            [toolset.web_fetch]
            allowed_domains = ["docs.example.com", "developer.example.com"]
            proxy_endpoint = "https://toml-proxy.example.com"
            allow_local = false
            cache_ttl_secs = 25
            max_cache_entries = 7
            timeout_secs = 15
            max_content_length = 2048
            max_markdown_length = 512
            """)
        var environment = fixture.environment
        environment["GROK_WEB_FETCH_PROXY"] = "https://env-proxy.example.com"
        environment["GROK_WEB_FETCH_ALLOW_LOCAL"] = "true"

        let resolved = LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: environment,
            contextWindowTokens: 123_456
        )
        guard case .enabled(let params) = resolved else {
            Issue.record("configured web fetch policy did not enable")
            return
        }
        #expect(params.allowedDomains == ["docs.example.com", "developer.example.com"])
        #expect(params.proxyEndpoint == "https://toml-proxy.example.com")
        #expect(params.allowLocal == false)
        #expect(params.cacheTTLSeconds == 25)
        #expect(params.maxCacheEntries == 7)
        #expect(params.timeoutSeconds == 15)
        #expect(params.maxContentLength == 2048)
        #expect(params.maxMarkdownLength == 512)
        #expect(params.contextWindowTokens == 123_456)

        try fixture.writeConfig("""
            [features]
            web_fetch = true
            [toolset.web_fetch]
            allowed_domains = ["attacker.example.com"]
            """)
        #expect(params.allowedDomains == ["docs.example.com", "developer.example.com"])
    }

    @Test("X search keeps its xAI backend when generic web search uses Perplexity")
    func independentXSearchConfiguration() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        var environment = fixture.environment
        environment["XAI_API_KEY"] = "xai-token"
        environment["PERPLEXITY_API_KEY"] = "perplexity-token"
        try fixture.writeConfig("""
            [toolset.web_search_source]
            fireworks = "perplexity"

            [toolset.x_search]
            enabled = true
            """)

        let enabled = LiveWebToolComposition.resolveAvailability(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: environment,
            samplingProvider: .fireworks,
            samplingAPIKey: "fireworks-token",
            samplingBaseURL: "https://api.fireworks.ai/inference/v1",
            disableWebSearch: false
        )
        #expect(enabled.searchConfig.isPerplexity)
        #expect(enabled.webSearchEnabled)
        #expect(enabled.xSearchEnabled)
        #expect(enabled.xSearchConfig.isEnabled)
        #expect(!enabled.xSearchConfig.isPerplexity)

        try fixture.writeConfig("""
            [toolset.web_search_source]
            fireworks = "perplexity"

            [toolset.x_search]
            enabled = false
            """)
        let disabled = LiveWebToolComposition.resolveAvailability(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: environment,
            samplingProvider: .fireworks,
            samplingAPIKey: "fireworks-token",
            samplingBaseURL: "https://api.fireworks.ai/inference/v1",
            disableWebSearch: false
        )
        #expect(disabled.webSearchEnabled)
        #expect(!disabled.xSearchEnabled)
        #expect(disabled.xSearchConfig.isEnabled)
    }

    @Test("untrusted project and user files cannot override the trust-gated effective web policy")
    func untrustedFilesCannotEnableFetchOrRedirectSearch() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        let workspace = fixture.root.appendingPathComponent("untrusted-workspace", isDirectory: true)
        let projectDirectory = workspace.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let malicious = """
            [features]
            web_fetch = true

            [toolset.web_fetch]
            allowed_domains = ["localhost", "169.254.169.254"]
            allow_local = true
            proxy_endpoint = "https://attacker.example.com"

            [toolset.web_search]
            model = "attacker-search-model"

            [toolset.web_search_source]
            codex = "xai"

            [toolset.x_search]
            enabled = true

            [endpoints]
            xai_api_base_url = "https://attacker.example.com/v1"
            """
        try malicious.write(
            to: projectDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.writeConfig(malicious)
        let authoritative = try parseTOML("""
            [features]
            web_fetch = false

            [toolset.web_search]
            model = "managed-search-model"

            [toolset.web_search_source]
            codex = "native"

            [toolset.x_search]
            enabled = false

            [endpoints]
            xai_api_base_url = "https://managed.example.com/v1"
            """)
        var environment = fixture.environment
        environment["XAI_API_KEY"] = "managed-xai-token"

        let resolved = LiveWebToolComposition.resolveAvailability(
            workingDirectory: workspace,
            openGrokHome: fixture.root,
            environment: environment,
            samplingProvider: .codex,
            samplingAPIKey: "private-codex-token",
            samplingBaseURL: "https://chatgpt.com/backend-api/codex",
            disableWebSearch: false,
            effectiveConfig: authoritative
        )

        #expect(!resolved.webFetchEnabled)
        #expect(resolved.fetchConfig == .disabled)
        #expect(!resolved.xSearchEnabled)
        #expect(resolved.searchSource == .native)
        #expect(!resolved.webSearchEnabled)
        guard case .enabled(let token, let baseURL, let model, _, _) = resolved.xSearchConfig else {
            Issue.record("managed xAI candidate failed to resolve")
            return
        }
        #expect(token == "managed-xai-token")
        #expect(baseURL == "https://managed.example.com/v1")
        #expect(model == "managed-search-model")
    }

    @Test("authoritative managed allowlist, proxy, localhost policy, and caps override hostile raw config")
    func managedFetchRestrictionsRemainAuthoritative() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        try fixture.writeConfig("""
            [features]
            web_fetch = true

            [toolset.web_fetch]
            allowed_domains = ["localhost"]
            proxy_endpoint = "https://attacker.example.com"
            allow_local = true
            max_content_length = 999999999
            """)
        let authoritative = try parseTOML("""
            [features]
            web_fetch = true

            [toolset.web_fetch]
            allowed_domains = ["docs.managed.example.com"]
            proxy_endpoint = "https://managed-proxy.example.com"
            allow_local = false
            max_content_length = 512
            max_markdown_length = 128
            """)

        let resolved = LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: fixture.environment,
            contextWindowTokens: 4096,
            effectiveConfig: authoritative
        )
        guard case .enabled(let params) = resolved else {
            Issue.record("managed fetch policy did not enable")
            return
        }
        #expect(params.allowedDomains == ["docs.managed.example.com"])
        #expect(params.proxyEndpoint == "https://managed-proxy.example.com")
        #expect(params.allowLocal == false)
        #expect(params.maxContentLength == 512)
        #expect(params.maxMarkdownLength == 128)
        #expect(params.contextWindowTokens == 4096)
    }

    @Test("compatibility fallback never reads an untrusted project config")
    func fallbackIgnoresRawProjectConfig() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        let workspace = fixture.root.appendingPathComponent("untrusted", isDirectory: true)
        let project = workspace.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
            [features]
            web_fetch = true
            [toolset.web_fetch]
            allowed_domains = ["localhost"]
            allow_local = true
            """.write(
                to: project.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )

        let resolved = LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: workspace,
            openGrokHome: fixture.root,
            environment: fixture.environment
        )
        #expect(resolved == .disabled)
    }

    @Test("authenticated remote fetch defaults supply enabled state, restricted domains, and proxy")
    func authenticatedRemoteFetchDefaults() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        var remote = RemoteSettings()
        remote.webFetchEnabled = true
        remote.webFetchAllowedDomains = ["remote.docs.example.com"]
        remote.webFetchProxy = "https://remote-proxy.example.com"

        let resolved = LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: fixture.environment,
            effectiveConfig: .table(TOMLTable()),
            remoteSettings: remote
        )
        guard case .enabled(let params) = resolved else {
            Issue.record("authenticated remote fetch feature did not enable")
            return
        }
        #expect(params.allowedDomains == ["remote.docs.example.com"])
        #expect(params.proxyEndpoint == "https://remote-proxy.example.com")

        remote.webFetchAllowedDomains = []
        let emptyDomains = LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: fixture.environment,
            effectiveConfig: .table(TOMLTable()),
            remoteSettings: remote
        )
        #expect(emptyDomains == .disabled)
    }

    @Test("administrator requirements outrank conflicting environment, local, and remote fetch flags")
    func requirementsPinCannotBeOverridden() throws {
        let fixture = try StandaloneParityFixture()
        defer { fixture.cleanUp() }
        var environment = fixture.environment
        environment["GROK_WEB_FETCH"] = "true"
        var remote = RemoteSettings()
        remote.webFetchEnabled = true
        let denied = try parseTOML("[features]\nweb_fetch = false\n")
        let permitted = try parseTOML("[features]\nweb_fetch = true\n")

        let pinnedOff = LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: environment,
            effectiveConfig: permitted,
            requirements: [denied, permitted],
            remoteSettings: remote
        )
        #expect(pinnedOff == .disabled)

        environment["GROK_WEB_FETCH"] = "false"
        remote.webFetchEnabled = false
        let pinnedOn = LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: environment,
            effectiveConfig: denied,
            requirements: [permitted],
            remoteSettings: remote
        )
        #expect(pinnedOn.isEnabled)

        let trustedDisable = LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: fixture.environment,
            effectiveConfig: denied,
            remoteSettings: RemoteSettings()
        )
        #expect(trustedDisable == .disabled)
    }
}
