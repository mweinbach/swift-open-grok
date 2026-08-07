// LiveCodexSwitchParityTests.swift
//
// Codex through the LIVE seam (AGENTS.md §3), two halves of one field report:
// the user switched a running xAI session to `gpt-5.6-sol`, the switch
// printed "Provider boundary summary could not be persisted: Open Grok
// session not found: <uuid>", and the first Codex turn died with HTTP 400.
//
// Half A pins the OUTGOING request a mid-session switch produces — endpoint,
// auth header shape, and body dialect — through the real resolver, the real
// `LiveModelSwitchCoordinator`, and the real `OpenGrokLiveSampler.production`
// factory against the mock inference server. The load-bearing byte is
// `store: false` (+ the encrypted-reasoning include), upstream's
// unconditional `apply_response_defaults` leg (xai-grok-sampler
// client.rs:2453-2462) that the port never sent.
//
// Half B pins the boundary-persist ordering: upstream creates the session
// storage record at session open (`init_session` → persistence.rs:2775,
// `initialize_provider_boundary` → :2745-2758), so a switch-time
// `mark_ever_used_codex` always has a record. The port creates the shell
// session lazily at the first prompt, so the pre-first-turn sync now defers
// through `LivePagerRuntimeAdapter` and the created record is seeded from
// the live `ExportBoundary` — the flag can be deferred but never lost.

import Foundation
import Testing
import OpenGrokAuth
import OpenGrokModels
import OpenGrokPagerMinimal
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Fixture

private struct CodexSwitchFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    /// Hermetic home: `[endpoints]` pins xAI at the mock for the session the
    /// switch starts from, and `GROK_CODEX_INFERENCE_BASE_URL` pins the Codex
    /// inference route at the same mock so the switched turn's bytes land in
    /// the request log.
    init(extraEnvironment: [String: String] = [:]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-codex-switch-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        try """
            [endpoints]
            xai_api_base_url = "\(server.url)"
            """
            .write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        var env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
            "GROK_CODEX_INFERENCE_BASE_URL": server.url,
            // The refresh-capable resolver's token endpoint must stay
            // hermetic too: an expired-token test would otherwise attempt a
            // refresh against the real issuer.
            "GROK_CODEX_AUTH_BASE_URL": server.url,
        ]
        for (key, value) in extraEnvironment { env[key] = value }
        environment = env
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    var codexAuthFile: URL {
        OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
    }

    /// Write a Codex OAuth store the resolver accepts. Returns the access
    /// token so the test can assert exactly that bearer reaches the wire.
    @discardableResult
    func writeCodexStore(
        accountID: String,
        accessTokenLifetime: TimeInterval,
        refreshToken: String = "refresh-1"
    ) throws -> String {
        let idToken = buildTestJWT(payload: [
            "email": "person@openai.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_plan_type": "plus",
                "chatgpt_user_id": "user-1",
            ],
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        let accessToken = buildTestJWT(payload: [
            "exp": Int(Date().addingTimeInterval(accessTokenLifetime).timeIntervalSince1970),
        ])
        try persistCodexTokens(
            at: codexAuthFile,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: accountID
        )
        return accessToken
    }

    func launchOptions(_ arguments: [String]) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path] + arguments
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
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

// MARK: - Half A: the switched turn's outgoing request

@Suite("Live codex switch wire parity", .serialized)
struct LiveCodexSwitchWireParityTests {
    /// The full mid-session rebind: xAI session, `/model gpt-5.6-sol`, one
    /// turn. Endpoint, auth identity, and body dialect are pinned against
    /// upstream: `store: false` + encrypted-reasoning include
    /// (client.rs:2453-2462), `prompt_cache_key` = session id
    /// (client.rs:2464-2471, provider.rs:174-184), leading system prompt
    /// extracted to `instructions` with no `system` role left in the input
    /// (the Codex instruction-role patch), and no synthesized x-grok headers
    /// (Codex is a standard-headers provider; client.rs:4342 pins the same).
    @Test("a mid-session codex switch sends the codex dialect to the codex endpoint")
    func switchedTurnSendsCodexDialect() async throws {
        let fixture = try CodexSwitchFixture()
        defer { fixture.dispose() }
        let accessToken = try fixture.writeCodexStore(
            accountID: "acct-cx",
            accessTokenLifetime: 3600
        )

        let sessionID = "session-codex-switch"
        let resolver = LiveModelCatalogResolver(
            environment: fixture.environment,
            openGrokHome: fixture.home,
            sessionID: sessionID,
            workingDirectory: fixture.workspace
        )
        let initial = try await resolver.resolve(modelID: "grok-4.5")
        #expect(initial.sampling.provider == .xai)
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )

        guard case .switched(let summary) = await coordinator.apply(modelID: "gpt-5.6-sol") else {
            Issue.record("expected the codex switch to succeed")
            return
        }
        #expect(summary.provider == .codex)

        let snapshot = await coordinator.snapshot()
        #expect(snapshot.configuration.baseURL == fixture.server.url)
        #expect(snapshot.configuration.apiBackend == .responses)
        // The rebound credential is the Codex OAuth bearer, not the xAI key.
        #expect(snapshot.configuration.apiKey == accessToken)

        _ = try await snapshot.sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: sessionID,
                turnID: "turn-1",
                model: snapshot.modelID,
                prompt: "hello",
                items: [.system("You are terse."), .user("hello")]
            ),
            emit: { _ in }
        )

        let entry = fixture.server.requests().last { $0.path == "/v1/responses" }
        #expect(entry != nil, "no responses POST reached the codex endpoint")
        #expect(entry?.authorization == "Bearer \(accessToken)")
        #expect(entry?.authorization != "Bearer test-xai-key")
        #expect(entry?.header("ChatGPT-Account-ID") == "acct-cx")
        #expect(entry?.header("x-grok-conv-id") == nil)
        #expect(entry?.header("x-grok-model-override") == nil)

        let body = entry?.body
        #expect(body?["model"].stringValue == "gpt-5.6-sol")
        #expect(body?["stream"].boolValue == true)
        #expect(body?["store"].boolValue == false)
        let include = body?["include"].arrayValue?.compactMap { $0.stringValue }
        #expect(include == ["reasoning.encrypted_content"])
        #expect(body?["prompt_cache_key"].stringValue == sessionID)
        #expect(body?["instructions"].stringValue == "You are terse.")
        let inputRoles = body?["input"].arrayValue?.compactMap { $0["role"].stringValue }
        #expect(inputRoles?.contains("system") == false)
    }

    /// The switch path resolves Codex credentials through the same
    /// refresh-capable resolver the cold start builds. An expired access
    /// token must refuse the switch (here the mock IdP 404s the token
    /// exchange), never ship the stale bearer — the resolver's
    /// no-stale-fallback contract, which the previous `.storeOnly` default
    /// silently violated on exactly the switch path.
    @Test("an expired codex token refuses the switch instead of sending a stale bearer")
    func expiredTokenRefusesTheSwitch() async throws {
        let fixture = try CodexSwitchFixture()
        defer { fixture.dispose() }
        // The IdP is the same mock: its unknown-path handler answers the
        // token exchange with a deterministic 404, so no listener race and
        // no real network.
        var environment = fixture.environment
        environment["GROK_CODEX_AUTH_BASE_URL"] = fixture.server.url
        try fixture.writeCodexStore(
            accountID: "acct-cx",
            accessTokenLifetime: -120,
            refreshToken: "refresh-expired"
        )

        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: fixture.home,
            sessionID: "session-codex-expired",
            workingDirectory: fixture.workspace
        )
        let initial = try await resolver.resolve(modelID: "grok-4.5")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )

        let outcome = await coordinator.apply(modelID: "gpt-5.6-sol")
        guard case .failed(_, let message) = outcome else {
            Issue.record("expected the switch to refuse a stale codex token, got \(outcome)")
            return
        }
        #expect(message.contains("could not be refreshed"))
        // Still on the previous model, and the stale bearer never traveled.
        #expect(await coordinator.activeProvider == .xai)
        #expect(!fixture.server.requests().contains { $0.path == "/v1/responses" })
    }
}

// MARK: - Half B: pre-first-turn boundary persistence

@Suite("Live provider boundary pre-first-turn", .serialized)
struct LiveProviderBoundaryPreFirstTurnTests {
    /// The reported wart end to end: `/model` to a codex model BEFORE the
    /// first prompt, then the boundary sync, then the first prompt. The sync
    /// must not fail with "session not found", and the shell session created
    /// afterwards must carry `ever_used_codex: true` in its persisted
    /// summary — deferred is acceptable, lost is not.
    @Test("a pre-first-turn codex switch defers the sync and the created record carries the flag")
    func preFirstTurnSwitchDefersWithoutLosingTheFlag() async throws {
        let fixture = try CodexSwitchFixture()
        defer { fixture.dispose() }
        try fixture.writeCodexStore(accountID: "acct-cx", accessTokenLifetime: 3600)

        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "done") }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(["--model", "grok-4.5"]),
            context: fixture.context(),
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: dependencies
        )
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

        // The real `/model` path: resolution, sampler rebuild, and the
        // history reconciliation that closes the shared export boundary.
        guard case .switched = await stack.modelSwitch.apply(modelID: "gpt-5.6-sol") else {
            Issue.record("expected the codex switch to succeed")
            return
        }
        let boundary = await stack.conversationHistory.sharedExportBoundary
        #expect(boundary.everUsedNonXAI)

        // No shell session exists yet — this is the window that used to
        // throw "Open Grok session not found" into the transcript.
        let sessionID = SessionID(foundation.sessionID)
        #expect(await stack.shell.lookupSession(sessionID) == nil)
        try await adapter.synchronizeProviderBoundary(
            everUsedNonXAI: boundary.everUsedNonXAI
        )

        // First prompt: the shell session is created and must be born
        // carrying the boundary truth (upstream `initialize_provider_boundary`
        // marks the store at session open, persistence.rs:2745-2758).
        _ = try await adapter.makeSession(
            for: OpenGrokPagerMinimalRequest(prompt: "hello", sessionID: foundation.sessionID)
        )
        let store = SessionStateStore(root: fixture.home)
        let persisted = try await store.load(sessionID: sessionID)
        #expect(persisted?.summary.everUsedCodex == true)

        // With the session in place the sync is a real write again, and the
        // shell's own missing-session guard is untouched for genuinely
        // unknown ids — the deferral must not have weakened it.
        try await adapter.synchronizeProviderBoundary(everUsedNonXAI: true)
        do {
            try await stack.shell.synchronizeProviderBoundary(
                sessionID: SessionID("no-such-session"),
                everUsedNonXAI: true
            )
            Issue.record("the shell accepted a boundary sync for an unknown session")
        } catch let error as OpenGrokShellError {
            guard case .sessionNotFound = error else {
                Issue.record("unexpected shell error: \(error)")
                return
            }
        }

        _ = await stack.shell.shutdown(timeout: ShellDuration(timeInterval: 10))
        await foundation.toolExecutor.shutdown()
    }
}
