import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokSubagentResolution
import Testing
@testable import OpenGrokCLI

private final class InteractiveCredentialRotationSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}

    func flush() throws {}
}

private actor InteractiveCredentialChildGate {
    private var entered: Set<String> = []
    private var released: Set<String> = []
    private var cancelled: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, any Error>] = [:]

    func park(_ id: String) async throws {
        entered.insert(id)
        if cancelled.contains(id) { throw CancellationError() }
        if released.contains(id) { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled.contains(id) {
                    continuation.resume(throwing: CancellationError())
                } else if released.contains(id) {
                    continuation.resume()
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: String) {
        released.insert(id)
        continuations.removeValue(forKey: id)?.resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for (id, continuation) in pending {
            released.insert(id)
            continuation.resume()
        }
    }

    private func cancel(_ id: String) {
        cancelled.insert(id)
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func waitUntilEntered(_ id: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !entered.contains(id), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered.contains(id)
    }
}

private struct InteractiveCredentialRotationFixture {
    let home: URL
    let environment: [String: String]
    let inference: MockHTTPTransport
    let catalog: LiveModelCatalogStore
    let coordinator: LiveModelSwitchCoordinator
    let host: LiveSubagentHost
    let executor: LiveToolExecutor
    let renderer: LiveInteractiveControllerRenderer
    let childGate: InteractiveCredentialChildGate

    init(extraEnvironment: [String: String] = [:]) async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-interactive-credential-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ]
        for (key, value) in extraEnvironment { environment[key] = value }
        self.environment = environment
        try storeProviderAPIKey(
            grokHome: home,
            provider: ModelProvider.fireworks.asString,
            apiKey: "fireworks-before-rotation"
        )

        let catalogBody = Data(
            #"{"data":[{"id":"accounts/fireworks/models/glm-5p2","context_length":1040000}]}"#.utf8
        )
        let catalogResponse = MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: catalogBody
        )
        catalog = LiveModelCatalogStore(
            input: .default,
            environment: environment,
            openGrokHome: home,
            transport: MockHTTPTransport(responses: Array(repeating: catalogResponse, count: 20))
        )
        inference = MockHTTPTransport(responses: (0..<8).map { turn in
            let event = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"turn-\#(turn)"},"finish_reason":"stop"}]}"#
            return MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data("data: \(event)\n\ndata: [DONE]\n\n".utf8)
            )
        })
        let inference = self.inference
        let makeSampler: @Sendable (
            OpenGrokLiveSamplingConfiguration
        ) throws -> OpenGrokLiveSampler = { configuration in
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
                transport: inference
            ))
        }
        let catalog = self.catalog
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "interactive-credential-session",
            workingDirectory: home,
            catalogSource: { catalog.snapshot() },
            makeCredentialResolver: { environment, home in
                LiveCredentialResolver(environment: environment, openGrokHome: home)
            }
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let initialSampler = try makeSampler(initial.sampling)
        coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: initialSampler,
            resolver: resolver,
            makeSampler: makeSampler,
            history: nil
        )

        let childGate = InteractiveCredentialChildGate()
        self.childGate = childGate
        let childSampler = OpenGrokLiveSampler { request, _ in
            try await childGate.park(request.sessionID)
            return OpenGrokLiveSamplingResponse(output: "child completed")
        }
        let antigravityServices = LiveAntigravityServices(
            loadConfig: { _ in
                LiveAntigravityConfig(enabled: true, binary: "agy", skipPermissions: false)
            },
            isCLIInstalled: { _, _ in true },
            probeModels: { _ in
                LiveAntigravityStatus(
                    signedIn: true,
                    models: ["gemini-3.6-flash"],
                    detail: nil
                )
            },
            runPrint: { _ in
                do {
                    try await childGate.park("external-antigravity")
                    return .success(output: "external agent completed", conversationID: nil)
                } catch {
                    return .cancelled
                }
            }
        )
        let processBackend = LocalShellProcessBackend(inheritedEnvironment: environment)
        let security = LiveSecurityContext.resolve(
            workspaceRoot: home,
            environment: environment,
            isInteractive: false
        )
        let host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: initialSampler,
            parentModel: initial.sampling.model,
            workingDirectory: home,
            sessionID: "interactive-credential-session",
            openGrokHome: home,
            conversationStore: LiveConversationStore(openGrokHome: home),
            processBackend: processBackend,
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
                cwd: home,
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: [
                initial.sampling.model,
                "fireworks-child",
                "deepseek-child",
                "unresolved-fireworks",
            ],
            antigravityServices: antigravityServices,
            parentProvider: .fireworks,
            childSamplerFactory: { model, _ in
                if model == "unresolved-fireworks" {
                    try await childGate.park("factory-unresolved")
                }
                return LiveSubagentHost.ChildSamplerRoute(
                    sampler: childSampler,
                    provider: model == "deepseek-child" ? .deepseek : .fireworks
                )
            }
        ))
        self.host = host
        executor = try await LiveToolExecutor(
            processBackend: processBackend,
            sessionID: "interactive-credential-session",
            workingDirectory: home,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment,
            securityContext: security,
            subagentHost: host
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: InteractiveCredentialRotationSink(),
            workingDirectory: home.path,
            modelName: initial.sampling.model,
            catalogStore: catalog,
            modelSwitch: coordinator,
            sessionID: "interactive-credential-session",
            openGrokHome: home,
            environment: environment,
            toolExecutor: executor
        )
    }

    func sample(turn: String) async throws {
        let snapshot = await coordinator.snapshot()
        let response = try await snapshot.sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "interactive-credential-session",
                turnID: turn,
                model: snapshot.modelID,
                prompt: "check the provider credential"
            ),
            emit: { _ in }
        )
        #expect(!response.output.isEmpty)
    }

    func spawn(id: String, model: String) async throws {
        let result = await host.spawn(
            args: .object([
                "task_id": .string(id),
                "prompt": .string("wait for a credential update"),
                "description": .string("credential rotation child"),
                "subagent_type": .string("general-purpose"),
                "background": .bool(true),
                "model": .string(model),
            ]),
            toolCallID: "call-\(id)"
        )
        guard case .success = result else {
            throw CLIApplicationError.failed("subagent did not start: \(result)")
        }
    }

    func dispose() async {
        catalog.backgroundRefreshTask?.cancel()
        await catalog.backgroundRefreshTask?.value
        await childGate.releaseAll()
        await executor.shutdown()
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("Live interactive credential rotation parity", .serialized)
struct LiveInteractiveCredentialRotationParityTests {
    @Test("actual settings save replaces the next root provider request bearer")
    func settingsSaveRebindsProductionSampler() async throws {
        let fixture = try await InteractiveCredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.sample(turn: "before-save")
        #expect(fixture.inference.recordedRequests.first?.headers["Authorization"]
            == "Bearer fireworks-before-rotation")

        await fixture.renderer.applySettingsEvent(.secret(
            key: "fireworks_api_key",
            value: "  fireworks-after-rotation  "
        ))
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "fireworks")
            == "fireworks-after-rotation")

        try await fixture.sample(turn: "after-save")
        #expect(fixture.inference.recordedRequests.count == 2)
        #expect(fixture.inference.recordedRequests[1].headers["Authorization"]
            == "Bearer fireworks-after-rotation")
        let notes = await fixture.renderer.testingSystemMessageTexts()
        #expect(notes.contains { $0.contains("running session is using the updated credential") })
        #expect(!notes.contains { $0.contains("keeps its current credential") })
        #expect(!notes.contains { $0.contains("fireworks-after-rotation") })
    }

    @Test("settings reset removes active credentials and blocks the stale root sampler")
    func settingsResetFailsClosedWithoutFallback() async throws {
        let fixture = try await InteractiveCredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.sample(turn: "before-clear")
        await fixture.renderer.applySettingsEvent(.resetRequested(key: "fireworks_api_key"))

        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "fireworks") == nil)
        do {
            try await fixture.sample(turn: "after-clear")
            Issue.record("the old provider bearer remained usable after settings removal")
        } catch {
            #expect(fixture.inference.recordedRequests.count == 1)
        }
        let errors = await fixture.renderer.testingErrorMessageTexts()
        #expect(errors.contains { $0.contains("Sampling is blocked") })
    }

    @Test("removing a stored key rebinds the active session to its environment fallback")
    func settingsRemovalPreservesRealEnvironmentFallback() async throws {
        let fixture = try await InteractiveCredentialRotationFixture(extraEnvironment: [
            "FIREWORKS_API_KEY": "fireworks-environment-fallback",
        ])
        defer { Task { await fixture.dispose() } }

        await fixture.renderer.applySettingsEvent(.resetRequested(key: "fireworks_api_key"))
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "fireworks") == nil)
        try await fixture.sample(turn: "environment-fallback")
        #expect(fixture.inference.recordedRequests.first?.headers["Authorization"]
            == "Bearer fireworks-environment-fallback")
        #expect(await fixture.renderer.testingErrorMessageTexts().isEmpty)
    }

    @Test("settings save revokes matching children without touching another provider")
    func settingsSaveCancelsOnlyAffectedSubagents() async throws {
        let fixture = try await InteractiveCredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "affected-child", model: "fireworks-child")
        try await fixture.spawn(id: "unrelated-child", model: "deepseek-child")
        #expect(await fixture.childGate.waitUntilEntered("affected-child"))
        #expect(await fixture.childGate.waitUntilEntered("unrelated-child"))

        await fixture.renderer.applySettingsEvent(.secret(
            key: "fireworks_api_key",
            value: "fireworks-revoked-children"
        ))
        let affected = try #require(await fixture.host.awaitSubagent(
            id: "affected-child",
            timeoutMS: 5_000
        ))
        #expect(affected.status == "cancelled")
        #expect(await fixture.host.subagentSnapshot(id: "unrelated-child")?.status == "running")
        let notes = await fixture.renderer.testingSystemMessageTexts()
        #expect(notes.contains { $0.contains("Stopped 1 subagent") })

        await fixture.childGate.release("unrelated-child")
        let unrelated = try #require(await fixture.host.awaitSubagent(
            id: "unrelated-child",
            timeoutMS: 5_000
        ))
        #expect(unrelated.status == "completed")
    }

    @Test("settings rotation cancels unresolved children before they receive a provider sampler")
    func settingsRotationCancelsUnresolvedSubagents() async throws {
        let fixture = try await InteractiveCredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "unresolved-provider-child", model: "unresolved-fireworks")
        #expect(await fixture.childGate.waitUntilEntered("factory-unresolved"))

        await fixture.renderer.applySettingsEvent(.secret(
            key: "fireworks_api_key",
            value: "fireworks-after-unresolved"
        ))
        let unresolved = try #require(await fixture.host.awaitSubagent(
            id: "unresolved-provider-child",
            timeoutMS: 5_000
        ))
        #expect(unresolved.status == "cancelled")
        try await fixture.sample(turn: "after-unresolved-cancellation")
        #expect(fixture.inference.recordedRequests.first?.headers["Authorization"]
            == "Bearer fireworks-after-unresolved")
    }

    @Test("settings credential changes do not cancel independent Antigravity processes")
    func settingsRotationPreservesAntigravityChild() async throws {
        let fixture = try await InteractiveCredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(
            id: "external-provider-child",
            model: "antigravity:gemini-3.6-flash"
        )
        #expect(await fixture.childGate.waitUntilEntered("external-antigravity"))

        await fixture.renderer.applySettingsEvent(.secret(
            key: "fireworks_api_key",
            value: "fireworks-antigravity-safe"
        ))
        #expect(await fixture.host.subagentSnapshot(id: "external-provider-child")?.status
            == "running")
        await fixture.childGate.release("external-antigravity")
        let completed = try #require(await fixture.host.awaitSubagent(
            id: "external-provider-child",
            timeoutMS: 5_000
        ))
        #expect(completed.status == "completed")
    }

    @Test("another provider's settings credential never replaces the active bearer")
    func unrelatedProviderSecretPreservesRootSession() async throws {
        let fixture = try await InteractiveCredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        await fixture.renderer.applySettingsEvent(.secret(
            key: "deepseek_api_key",
            value: "deepseek-isolated-secret"
        ))
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "deepseek")
            == "deepseek-isolated-secret")
        try await fixture.sample(turn: "unrelated-provider")
        #expect(fixture.inference.recordedRequests.first?.headers["Authorization"]
            == "Bearer fireworks-before-rotation")
    }

    @Test("Kimi platform and code secrets retain independent scopes")
    func kimiEndpointScopesStayIndependent() async throws {
        let fixture = try await InteractiveCredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        await fixture.renderer.applySettingsEvent(.secret(
            key: "kimi_api_key",
            value: "kimi-platform-secret"
        ))
        await fixture.renderer.applySettingsEvent(.secret(
            key: "kimi_code_api_key",
            value: "kimi-code-secret"
        ))
        #expect(readScopedAPIKey(
            grokHome: fixture.home,
            scope: kimiAPIKeyScope(.platform)
        ) == "kimi-platform-secret")
        #expect(readScopedAPIKey(
            grokHome: fixture.home,
            scope: kimiAPIKeyScope(.code)
        ) == "kimi-code-secret")

        await fixture.renderer.applySettingsEvent(.resetRequested(key: "kimi_api_key"))
        #expect(readScopedAPIKey(grokHome: fixture.home, scope: kimiAPIKeyScope(.platform)) == nil)
        #expect(readScopedAPIKey(grokHome: fixture.home, scope: kimiAPIKeyScope(.code))
            == "kimi-code-secret")
    }
}
