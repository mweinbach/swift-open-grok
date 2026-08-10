// ACPCredentialFamilyTests.swift
//
// The ACP extension-method router table and the `open-grok/*/models`
// credential family, asserted at the live seams:
//
//   * The table pins drive the SAME router builder the live composition
//     installs (`LiveACPExtensionRouter.build`) through a real
//     `ACPAgentRuntime` — every method upstream dispatches at the pin
//     (`acp_agent.rs:3794-4472`) is either routed or refused with
//     upstream's terminal error byte-exact. No silent unknowns.
//   * The ws:// end-to-end drives the REAL serve host over a real loopback
//     socket: a key saved through the real store (`storeProviderAPIKey`,
//     the same write the settings surface performs) reaches BOTH the
//     partition refetch and the RUNNING session's next sampling request —
//     the request bytes are asserted on the mock inference transport the
//     production sampler is built over (`OpenGrokLiveSamplingConfiguration
//     .transport`, the documented composition-test seam). The sampler, the
//     resolver, the coordinator, the router, the runtime, and the WebSocket
//     framing are all production code. The mock cannot sit behind a
//     loopback URL because the stored-key trust gate releases a Fireworks
//     key only to `https://api.fireworks.ai`
//     (`trustedBuiltInSessionEndpoint`; upstream fireworks_models.rs:87-92)
//     — widening that gate for a test is forbidden, so the assertion is
//     made on the fully formed request the production stack hands its
//     transport, official URL included.

import Foundation
import OpenGrokACP
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokProviderSession
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

// Both OpenGrokShared and OpenGrokCLIChatProxyTypes export a `JSONValue`;
// every use in this file means the ACP wire one.
private typealias JSONValue = OpenGrokShared.JSONValue

// MARK: - Harness

private func makeTemporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-acp-cred-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A fully pinned environment: no ambient key or endpoint variable can
/// leak in, because every seam below takes this dictionary explicitly.
private func pinnedEnvironment(home: URL, extra: [String: String] = [:]) -> [String: String] {
    var environment = [
        "OPENGROK_HOME": home.path,
        "HOME": home.path,
    ]
    for (key, value) in extra { environment[key] = value }
    return environment
}

private let fireworksModelsBody = Data(
    #"{ "data": [{ "id": "accounts/fireworks/models/glm-5p2", "context_length": 1040000 }] }"#.utf8
)

private let kimiModelsBody = Data(
    #"{ "data": [{ "id": "kimi-k3", "context_length": 256000, "supports_reasoning": true }] }"#.utf8
)

private func catalogOK(_ body: Data) -> MockHTTPTransport.ScriptedResponse {
    .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body)
}

private func sseResponse(text: String) -> MockHTTPTransport.ScriptedResponse {
    let chunk = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":"#
        + #"[{"index":0,"delta":{"role":"assistant","content":"\#(text)"},"finish_reason":"stop"}]}"#
    return .init(
        metadata: HTTPResponseMetadata(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"]
        ),
        body: Data("data: \(chunk)\n\ndata: [DONE]\n\n".utf8)
    )
}

private struct HermeticFamily {
    let home: URL
    let environment: [String: String]
    let store: LiveModelCatalogStore
    let catalogTransport: MockHTTPTransport
    let runtime: ACPAgentRuntime

    init(
        extraEnvironment: [String: String] = [:],
        catalogResponses: [MockHTTPTransport.ScriptedResponse] = [],
        coordinator: LiveModelSwitchCoordinator? = nil,
        feedback: LiveFeedbackACPHandler? = nil,
        home: URL? = nil
    ) throws {
        let resolvedHome = try home ?? makeTemporaryHome()
        self.home = resolvedHome
        self.environment = pinnedEnvironment(home: resolvedHome, extra: extraEnvironment)
        self.catalogTransport = MockHTTPTransport(responses: catalogResponses)
        self.store = LiveModelCatalogStore(
            input: .default,
            environment: environment,
            openGrokHome: resolvedHome,
            transport: catalogTransport
        )
        let router = LiveACPExtensionRouter.build(
            feedback: feedback,
            models: LiveModelsACPHandler(catalogStore: store, modelSwitch: coordinator)
        )
        self.runtime = ACPAgentRuntime(extensionRouter: router)
    }

    func initialize() async throws {
        let output = await runtime.handle(.request(
            id: .string("init"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = output[0] else {
            throw ACPTransportError.invalidMessage("initialize failed: \(output)")
        }
    }

    func call(
        _ method: String,
        id: String,
        params: OpenGrokShared.JSONValue = .object([:])
    ) async -> (result: OpenGrokShared.JSONValue?, error: AcpError?) {
        let output = await runtime.handle(.request(
            id: .string(id),
            method: method,
            params: params
        ))
        guard case .response(_, let result, let error) = output[0] else {
            return (nil, AcpError.internalError("no response for \(method)"))
        }
        return (result, error)
    }
}

// MARK: - Method table pins

/// Every exact method name upstream's ext dispatch matches
/// (`acp_agent.rs:3794-4471`) that this port has NOT implemented, plus one
/// representative per prefix family (`s.starts_with(...)` arms) and the
/// leader-internal names (`InternalMethod::name`, leader/protocol.rs:
/// 410-420). Each must be refused with the terminal arm's error — never
/// silently mis-routed, never accepted as a no-op.
///
/// Count discipline: 76 entries when the pin landed with E10; 69 now —
/// `x.ai/session/rename`/`delete`/`fork` left with the session-admin trio
/// (ACPSessionAdminExtensionTests pins their routing), `x.ai/btw` left with
/// the side-question slice (ACPBtwExtensionTests pins its routing), and the
/// leader roster's `x.ai/sessions/list` left with the leader bridge slice;
/// two `x.ai/mcp/` representatives left with the MCP family
/// (ACPMCPExtensionTests pins the routed seven AND the family's two
/// refusal shapes: terminal-with-data for the unported
/// setup/toggle/toggle_tool, upstream's bare method_not_found for unknown
/// names under the prefix, mcp.rs:387 — a shape this harness cannot
/// express because its router deliberately has no mcp arm).
private let refusedUpstreamMethods: [String] = [
    // :4050
    "open-grok/toolset/perplexity-web-search/reload",
    // :4112
    "x.ai/getApiKey", "x.ai/setApiKey",
    // :4115-4150. rename/delete/fork (:4146-4150) left this list with the
    // session-admin trio — see the header note.
    "x.ai/session/info", "x.ai/session/close", "x.ai/session/list",
    "x.ai/workspaces/list", "x.ai/session/updates",
    "x.ai/session/state", "x.ai/session/import", "x.ai/session/load_history",
    "x.ai/session/search", "x.ai/session/resolve_local_for_worktree_resume",
    "x.ai/session/rehydrate", "x.ai/session/add_local_workspace",
    "x.ai/session/update_mcp_servers",
    "x.ai/plugins/reload", "x.ai/commands/list",
    // :4151-4153 (InternalMethod::from_name)
    "x.ai/internal/auth_cleared", "x.ai/internal/evict_sessions",
    "x.ai/internal/reload_all_mcp_servers", "x.ai/internal/reload_models",
    "x.ai/internal/reload_models_cache",
    "x.ai/internal/reload_project_mcp_servers", "x.ai/internal/reload_skills",
    "x.ai/internal/reload_workflows",
    // :4154-4165
    "x.ai/session/repair", "x.ai/session/usage", "x.ai/memory/flush",
    "x.ai/memory/rewrite", "x.ai/skills/refresh-baseline", "x.ai/interject",
    // :4166 — feedback dismiss routes to feedback::handle upstream and has
    // no port backing yet. Its `x.ai/btw` sibling left this list with the
    // side-question slice: the live composition routes it
    // (`LiveBtwACPHandler`), and this harness builds its router without a
    // btw arm on purpose, so the method is exercised in
    // ACPBtwExtensionTests instead.
    "x.ai/feedback/dismiss",
    // `x.ai/recap` (:4169) left this list with the notification gateway:
    // the live composition routes it (`LiveRecapACPHandler`), and this
    // harness builds its router without a recap arm on purpose, so the
    // method is exercised in ACPNotificationGatewayTests instead.
    // :4170-4386
    "x.ai/cloud/terminate", "x.ai/cloud/env/list", "x.ai/cloud/env/create",
    "x.ai/cloud/env/update", "x.ai/cloud/env/delete", "x.ai/billing",
    "x.ai/auto-topup-rule", "x.ai/share_session",
    "x.ai/privacy/setCodingDataRetention", "x.ai/rollout/survey",
    "x.ai/prompt_history", "x.ai/suggest", "x.ai/suggestPrompt",
    // :4387-4466 — prefix families, one representative each. The
    // `x.ai/mcp/` representatives (:4420) left this list with the routed
    // family — see the header note.
    "x.ai/auth/get_url", "x.ai/session_summaries/latest",
    "x.ai/git/worktree/list", "x.ai/git/status", "x.ai/compact_conversation",
    "x.ai/plugins/list", "x.ai/marketplace/search", "x.ai/hooks/list",
    "x.ai/hunk-tracker/state", "x.ai/pr/status",
    "x.ai/task/list", "x.ai/scheduler/list",
    "x.ai/subagent/list", "x.ai/terminal/create", "x.ai/fs/list",
    "x.ai/search/files", "x.ai/bundle/create", "x.ai/code/definition",
    "x.ai/skills/list", "x.ai/workflows/list", "x.ai/review",
    "x.ai/debug/state", "x.ai/rewind",
]

@Suite("ACP extension method table")
struct ACPExtensionMethodTableTests {
    @Test("every credential-family method routes through the live router")
    func routedMethods() async throws {
        let family = try HermeticFamily()
        try await family.initialize()

        for (index, method) in LiveModelsACPHandler.methods.enumerated() {
            let params: OpenGrokShared.JSONValue = method == "open-grok/kimi/endpoint/apply"
                ? .object(["endpoint": .string("platform")])
                : .object([:])
            let (result, error) = await family.call(method, id: "routed-\(index)", params: params)
            #expect(error == nil, "\(method) must route, got \(String(describing: error))")
            // Every family arm answers inside upstream's ExtMethodResult
            // envelope (`{"result": …}`, session/result.rs:29-44).
            #expect(result?["result"] != nil, "\(method) must answer in the result envelope")
        }
    }

    @Test("x.ai/feedback still routes beside the family")
    func feedbackStillRoutes() async throws {
        let store = RecordingFeedbackStore()
        let family = try HermeticFamily(
            feedback: LiveFeedbackACPHandler(composition: LiveFeedbackComposition(
                sessionID: "table-feedback",
                boundary: ExportBoundary(),
                feedbackEnabled: false,
                store: store,
                client: nil
            ))
        )
        try await family.initialize()

        let submission = FeedbackSubmission.withContent(
            sessionId: "",
            clientType: .tui,
            content: .text("router feedback")
        )
        let (result, error) = await family.call(
            "x.ai/feedback",
            id: "feedback-1",
            params: try JSONValue.encode(submission)
        )
        #expect(error == nil)
        #expect(result?["status"]?.stringValue == "persisted_local_only")
        #expect(store.count == 1)
    }

    @Test("x.ai/sessions/list is the live leader roster snapshot")
    func leaderRosterListRoutes() async throws {
        let family = try HermeticFamily()
        try await family.initialize()

        let (result, error) = await family.call("x.ai/sessions/list", id: "roster-list")
        #expect(error == nil)
        #expect(result?["sessions"] == .array([]))
    }

    @Test("every unimplemented upstream method is refused with the terminal error, byte-exact")
    func refusedMethods() async throws {
        let family = try HermeticFamily()
        try await family.initialize()

        for (index, method) in refusedUpstreamMethods.enumerated() {
            let (result, error) = await family.call(method, id: "refused-\(index)")
            #expect(result == nil, "\(method) must not be answered")
            #expect(error?.code == .methodNotFound, "\(method)")
            #expect(error?.message == "Method not found", "\(method)")
            #expect(
                error?.data == .string("unknown ACP extension method: \(method)"),
                "\(method) must carry upstream's terminal data copy"
            )
        }
    }
}

private final class RecordingFeedbackStore: LiveFeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [FeedbackSubmission] = []

    func persist(_ submission: FeedbackSubmission) async throws {
        record(submission)
    }

    private func record(_ submission: FeedbackSubmission) {
        lock.lock()
        submissions.append(submission)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return submissions.count
    }
}

// MARK: - Family arms (hermetic)

@Suite("ACP credential family arms")
struct ACPCredentialFamilyArmTests {
    @Test("kimi query publishes under an env key, then clear reports and empties honestly")
    func kimiQueryThenClear() async throws {
        let family = try HermeticFamily(
            extraEnvironment: [KimiModels.platformAPIKeyEnv: "kimi-env-key"],
            catalogResponses: [catalogOK(kimiModelsBody)]
        )
        try await family.initialize()

        let (queryResult, queryError) = await family.call("open-grok/kimi/models/query", id: "q1")
        #expect(queryError == nil)
        #expect(queryResult?["result"]?["refreshed"]?.boolValue == true)
        // The catalog fetch carried the pinned env key to the official host.
        let fetch = try #require(family.catalogTransport.recordedRequests.first)
        #expect(fetch.headers["Authorization"] == "Bearer kimi-env-key")
        #expect(fetch.url.host == "api.moonshot.ai")

        let (clearResult, clearError) = await family.call("open-grok/kimi/models/clear", id: "c1")
        #expect(clearError == nil)
        #expect(clearResult?["result"]?["cleared"]?.boolValue == true)

        // Second clear: nothing left to drop — upstream's `had_catalog`
        // report, not a hardcoded true.
        let (again, _) = await family.call("open-grok/kimi/models/clear", id: "c2")
        #expect(again?["result"]?["cleared"]?.boolValue == false)
    }

    @Test("apply without any usable credential reports refreshed:false and fetches nothing")
    func applyWithoutCredential() async throws {
        let family = try HermeticFamily()
        try await family.initialize()

        let (result, error) = await family.call("open-grok/fireworks/models/apply", id: "a1")
        #expect(error == nil)
        #expect(result?["result"]?["refreshed"]?.boolValue == false)
        // The no-key arm clears instead of fetching (agent/models.rs:711-714)
        // — no request may leave the process.
        #expect(family.catalogTransport.recordedRequests.isEmpty)
        #expect(result?["result"]?["warning"] == nil)
    }

    @Test("kimi endpoint apply switches the service and reports the effective endpoint")
    func kimiEndpointApply() async throws {
        let family = try HermeticFamily(
            extraEnvironment: [KimiModels.codeAPIKeyEnv: "kimi-code-key"],
            catalogResponses: [catalogOK(kimiModelsBody)]
        )
        try await family.initialize()

        let (result, error) = await family.call(
            "open-grok/kimi/endpoint/apply",
            id: "k1",
            params: .object(["endpoint": .string("code")])
        )
        #expect(error == nil)
        let payload = result?["result"]
        #expect(payload?["endpoint"]?.stringValue == "code")
        #expect(payload?["effective_endpoint"]?.stringValue == "code")
        #expect(payload?["refreshed"]?.boolValue == true)
        // The rebuilt partition actor fetched from the CODE service with the
        // Code-scoped key — the whole point of rebuilding the refreshers
        // (upstream rebuilds kimi_client in apply_config,
        // agent/models.rs:1029-1043).
        let fetch = try #require(family.catalogTransport.recordedRequests.first)
        #expect(fetch.url.host == "api.kimi.com")
        #expect(fetch.headers["Authorization"] == "Bearer kimi-code-key")
    }

    @Test("kimi endpoint apply refuses malformed params with the invalid-params prefix")
    func kimiEndpointApplyInvalidParams() async throws {
        let family = try HermeticFamily()
        try await family.initialize()

        let (result, error) = await family.call(
            "open-grok/kimi/endpoint/apply",
            id: "k-bad",
            params: .object(["endpoint": .string("moonbase")])
        )
        #expect(result == nil)
        #expect(error?.code == .invalidParams)
        #expect(error?.message == "Invalid params")
        // Upstream surfaces serde's failure behind the "invalid params: "
        // data prefix (extensions/mod.rs:53-56); the prose after the prefix
        // is serde-generated there and hand-written here (recorded).
        let data = error?.data?.stringValue ?? ""
        #expect(data.hasPrefix("invalid params: "), "got \(data)")
    }

    @Test("opencode-go apply normalizes and echoes the allowlist with the catalog")
    func openCodeGoApply() async throws {
        let family = try HermeticFamily()
        try await family.initialize()

        let (result, error) = await family.call(
            "open-grok/opencode-go/models/apply",
            id: "o1",
            params: .object(["enabled_models": .array([
                .string("beta"), .string("alpha"), .string("alpha"),
            ])])
        )
        #expect(error == nil)
        let payload = result?["result"]
        // Sorted + deduped (apply_opencode_go_enabled_models,
        // agent/models.rs:1017-1023).
        #expect(payload?["enabled_models"] == .array([.string("alpha"), .string("beta")]))
        #expect(payload?["catalog"] == .array([]))
        #expect(payload?["refreshed"]?.boolValue == false)
    }

    @Test("codex clear reports false on a home with no codex state")
    func codexClearEmpty() async throws {
        let family = try HermeticFamily()
        try await family.initialize()

        let (result, error) = await family.call("open-grok/codex/models/clear", id: "cc1")
        #expect(error == nil)
        #expect(result?["result"]?["cleared"]?.boolValue == false)
    }
}

// MARK: - ws:// end-to-end

/// Drives one real sampling round per prompt through the coordinator's
/// snapshot — the identical read the live turn driver performs at turn
/// start (`LiveShellSamplingDriver` takes `modelSwitch.snapshot()`), so a
/// rebound sampler is observed exactly where production observes it.
private struct SnapshotSamplingPromptDriver: ACPPromptDriver {
    let coordinator: LiveModelSwitchCoordinator

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        let snapshot = await coordinator.snapshot()
        let response = try await snapshot.sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: context.session.sessionId.rawValue,
                turnID: UUID().uuidString,
                model: snapshot.modelID,
                prompt: "credential probe"
            ),
            emit: { _ in }
        )
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(
                    ContentChunk(content: .text(TextContent(text: response.output)))
                )
            ),
            .live
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private func wsConnect(
    to endpoint: ACPServeEndpoint,
    secret: String
) async throws -> ACPWebSocketConnectionTransport {
    let channel = try await WebSocketNetworkChannel.connect(
        host: endpoint.host,
        port: endpoint.port
    )
    let connection = try await WebSocketClientUpgrade.connect(
        channel: channel,
        host: endpoint.address,
        target: endpoint.path + "?server-key=\(secret)"
    )
    return ACPWebSocketConnectionTransport(connection: connection)
}

private func wsDrain(
    _ transport: ACPWebSocketConnectionTransport,
    limit: Int = 40,
    until match: (ACPMessage) -> Bool
) async throws -> ACPMessage {
    for _ in 0..<limit {
        let message = try await transport.receive()
        if match(message) { return message }
    }
    throw ACPTransportError.closed
}

@Suite("ACP credential family over ws://", .serialized)
struct ACPCredentialFamilyServeTests {
    @Test("a settings-saved key persists, refetches the catalog, and reaches the running session's next sampling request")
    func appliedKeyReachesRunningSession() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = pinnedEnvironment(home: home)

        // The settings-save write this family reacts to — the same store
        // function the pager's key modal persists through, and the same
        // auth.json the resolver reads back.
        try storeProviderAPIKey(
            grokHome: home,
            provider: ModelProvider.fireworks.asString,
            apiKey: "fw-old"
        )

        let catalogTransport = MockHTTPTransport(responses: [catalogOK(fireworksModelsBody)])
        let store = LiveModelCatalogStore(
            input: .default,
            environment: environment,
            openGrokHome: home,
            transport: catalogTransport
        )
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "acp-cred-e2e",
            workingDirectory: home,
            catalogSource: { store.snapshot() },
            makeCredentialResolver: { environment, openGrokHome in
                LiveCredentialResolver(environment: environment, openGrokHome: openGrokHome)
            }
        )

        // The PRODUCTION sampler over a recording transport: the request the
        // mock receives — URL, headers, body — is the request the shipping
        // sampler formed. Two scripted turns: before and after the apply.
        let inferenceTransport = MockHTTPTransport(responses: [
            sseResponse(text: "before"),
            sseResponse(text: "after"),
        ])
        let makeSampler: @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler = { configuration in
            try OpenGrokLiveSampler.production(configuration: OpenGrokLiveSamplingConfiguration(
                model: configuration.model,
                baseURL: configuration.baseURL,
                apiKey: configuration.apiKey,
                provider: configuration.provider,
                apiBackend: configuration.apiBackend,
                extraHeaders: configuration.extraHeaders,
                queryParams: configuration.queryParams,
                tuning: configuration.tuning,
                bearerResolver: configuration.bearerResolver,
                credentialProvider: configuration.credentialProvider,
                transport: inferenceTransport
            ))
        }

        let initial = try await resolver.resolve(modelID: "glm-5.2")
        // The stored rung is what is under test: the key came from
        // auth.json, released only because the endpoint is the official
        // Fireworks host.
        #expect(initial.credential.source == .storedAPIKey)
        #expect(initial.sampling.apiKey == "fw-old")

        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try makeSampler(initial.sampling),
            resolver: resolver,
            makeSampler: makeSampler,
            history: nil
        )
        let router = LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(catalogStore: store, modelSwitch: coordinator)
        )
        let sessionStore = InMemoryACPSessionStore()
        let host = ACPServeHost(
            configuration: ACPServeConfiguration(
                host: "127.0.0.1",
                port: 0,
                secret: "cred-secret",
                keepAliveInterval: nil
            ),
            makeRuntime: {
                ACPAgentRuntime(
                    store: sessionStore,
                    promptDriver: SnapshotSamplingPromptDriver(coordinator: coordinator),
                    extensionRouter: router
                )
            }
        )
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let client = try await wsConnect(to: endpoint, secret: "cred-secret")
        try await client.send(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object([
                "protocolVersion": .number(.int64(1)),
                "clientCapabilities": .object([:]),
            ])
        ))
        _ = try await wsDrain(client) { $0.id == .number(1) }
        try await client.send(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: .object(["cwd": .string(home.path), "mcpServers": .array([])])
        ))
        let created = try await wsDrain(client) { $0.id == .number(2) }
        guard case .response(_, .object(let sessionObject)?, _) = created,
              case .string(let sessionId)? = sessionObject["sessionId"] else {
            Issue.record("no sessionId in \(created)")
            return
        }

        func prompt(id: Int64) async throws {
            try await client.send(.request(
                id: .number(id),
                method: AgentMethodNames.sessionPrompt,
                params: .object([
                    "sessionId": .string(sessionId),
                    "prompt": .array([.object([
                        "type": .string("text"),
                        "text": .string("probe"),
                    ])]),
                ])
            ))
            let response = try await wsDrain(client) { $0.id == .number(id) }
            guard case .response(_, _, nil) = response else {
                Issue.record("prompt \(id) failed: \(response)")
                return
            }
        }

        // Turn 1: the running session samples with the pre-apply key.
        try await prompt(id: 3)
        let first = try #require(inferenceTransport.recordedRequests.first)
        #expect(first.headers["Authorization"] == "Bearer fw-old")
        #expect(first.url.host == "api.fireworks.ai")

        // The settings save: the NEW key lands in the real store…
        try storeProviderAPIKey(
            grokHome: home,
            provider: ModelProvider.fireworks.asString,
            apiKey: "fw-new"
        )
        #expect(readProviderAPIKey(
            grokHome: home,
            provider: ModelProvider.fireworks.asString
        ) == "fw-new")

        // …and the apply reaches the agent over the real socket.
        try await client.send(.request(
            id: .number(4),
            method: "open-grok/fireworks/models/apply",
            params: .object([:])
        ))
        let applied = try await wsDrain(client) { $0.id == .number(4) }
        guard case .response(_, let appliedResult?, nil) = applied else {
            Issue.record("apply failed: \(applied)")
            return
        }
        let payload = appliedResult["result"]
        #expect(payload?["refreshed"]?.boolValue == true)
        #expect(payload?["warning"] == nil)
        #expect(payload?["models"]?["currentModelId"] != nil)

        // Leg 1 — the partition refetch carried the NEW key to the official
        // catalog endpoint (apply_fireworks_credential_change refreshing,
        // agent/models.rs:708-710).
        let catalogFetch = try #require(catalogTransport.recordedRequests.first)
        #expect(catalogFetch.headers["Authorization"] == "Bearer fw-new")
        #expect(catalogFetch.url.host == "api.fireworks.ai")
        #expect(catalogFetch.url.path.hasSuffix("/models"))

        // Leg 2 — the RUNNING session's next sampling request carries the
        // NEW key: the Wave 12 deferral, closed. Same coordinator, same
        // snapshot read the live turn driver performs, production sampler.
        try await prompt(id: 5)
        #expect(inferenceTransport.recordedRequests.count == 2)
        let second = inferenceTransport.recordedRequests[1]
        #expect(second.headers["Authorization"] == "Bearer fw-new")
        #expect(second.url.host == "api.fireworks.ai")

        await client.close()
    }
}
