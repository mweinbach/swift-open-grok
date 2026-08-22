import Foundation
import OpenGrokAgentCoordinator
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokSubagentResolution
import Testing
@testable import OpenGrokCLI

private actor CredentialRotationProbe {
    private var enteredStages: Set<String> = []
    private var cancelled: Set<String> = []
    private var released: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, any Error>] = [:]

    func park(_ key: String) async throws {
        enteredStages.insert(key)
        if cancelled.contains(key) { throw CancellationError() }
        if released.contains(key) { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled.contains(key) {
                    continuation.resume(throwing: CancellationError())
                } else if released.contains(key) {
                    continuation.resume()
                } else {
                    waiters[key] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(key) }
        }
    }

    func release(_ key: String) {
        released.insert(key)
        waiters.removeValue(forKey: key)?.resume()
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for (key, continuation) in pending {
            released.insert(key)
            continuation.resume()
        }
    }

    private func cancel(_ key: String) {
        cancelled.insert(key)
        waiters.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }

    func entered(_ key: String) -> Bool {
        enteredStages.contains(key)
    }

    func waitUntilEntered(_ key: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !enteredStages.contains(key), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return enteredStages.contains(key)
    }
}

private struct CredentialRotationFixture {
    let root: URL
    let host: LiveSubagentHost
    let probe: CredentialRotationProbe

    init(blockedFactories: Set<String> = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-provider-rotation-\(UUID().uuidString)",
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
        let probe = CredentialRotationProbe()
        self.probe = probe
        let sampler = OpenGrokLiveSampler { request, _ in
            try await probe.park("sample:\(request.sessionID)")
            return OpenGrokLiveSamplingResponse(output: "delegated work completed")
        }
        let providers: [String: ModelProvider] = [
            "fireworks-child": .fireworks,
            "deferred-fireworks": .fireworks,
            "deepseek-child": .deepseek,
            "meta-child": .meta,
            "kimi-child": .kimi,
            "wafer-child": .wafer,
            "zai-child": .zai,
            "runinfra-child": .runinfra,
            "gemini-child": .gemini,
            "openrouter-child": .openRouter,
            "opencode-child": .openCodeGo,
            // The route metadata, never the public slug, owns provider truth.
            "fireworks-looking-child": .deepseek,
        ]
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
                    try await probe.park("antigravity")
                    return .success(output: "external runner completed", conversationID: nil)
                } catch {
                    return .cancelled
                }
            }
        )
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false
        )
        host = LiveSubagentHost(context: LiveSubagentHost.Context(
            sampler: sampler,
            parentModel: "fireworks-parent",
            workingDirectory: workspace,
            sessionID: "provider-rotation-session",
            openGrokHome: home,
            conversationStore: LiveConversationStore(openGrokHome: home),
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
                includeFilesystemDefinitions: true,
                environment: environment
            ),
            modelSlugs: ["fireworks-parent"] + providers.keys.sorted(),
            antigravityServices: antigravityServices,
            parentProvider: .fireworks,
            childSamplerFactory: { model, _ in
                if blockedFactories.contains(model) {
                    try await probe.park("factory:\(model)")
                }
                guard let provider = providers[model] else {
                    throw CancellationError()
                }
                return LiveSubagentHost.ChildSamplerRoute(
                    sampler: sampler,
                    provider: provider
                )
            }
        ))
    }

    func spawn(id: String, model: String? = nil) async throws {
        var arguments: [String: JSONValue] = [
            "task_id": .string(id),
            "prompt": .string("continue delegated work"),
            "description": .string("provider credential rotation probe"),
            "subagent_type": .string("general-purpose"),
            "background": .bool(true),
        ]
        if let model { arguments["model"] = .string(model) }
        let result = await host.spawn(args: .object(arguments), toolCallID: "call-\(id)")
        guard case .success = result else {
            throw CredentialRotationFixtureError.spawnFailed(String(describing: result))
        }
    }

    func awaitTerminal(_ id: String) async throws -> LiveSubagentSnapshot {
        try #require(await host.awaitSubagent(id: id, timeoutMS: 5_000))
    }

    func dispose() async {
        await probe.releaseAll()
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

private enum CredentialRotationFixtureError: Error {
    case spawnFailed(String)
}

@Suite("Live provider credential rotation parity", .serialized)
struct LiveProviderCredentialRotationParityTests {
    @Test("rotation cancels inherited and resolved same-provider children only")
    func cancelsMatchingProviderAndPreservesOtherProviders() async throws {
        let fixture = try CredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "inherited-fireworks")
        try await fixture.spawn(id: "explicit-fireworks", model: "fireworks-child")
        try await fixture.spawn(id: "unrelated-deepseek", model: "deepseek-child")
        #expect(await fixture.probe.waitUntilEntered("sample:inherited-fireworks"))
        #expect(await fixture.probe.waitUntilEntered("sample:explicit-fireworks"))
        #expect(await fixture.probe.waitUntilEntered("sample:unrelated-deepseek"))

        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.fireworks) == 2)
        #expect(try await fixture.awaitTerminal("inherited-fireworks").status == "cancelled")
        #expect(try await fixture.awaitTerminal("explicit-fireworks").status == "cancelled")
        #expect(await fixture.host.subagentSnapshot(id: "unrelated-deepseek")?.status == "running")

        await fixture.probe.release("sample:unrelated-deepseek")
        #expect(try await fixture.awaitTerminal("unrelated-deepseek").status == "completed")
    }

    @Test("unresolved child is revoked before factory can capture stale credentials")
    func unresolvedRouteFailsClosed() async throws {
        let fixture = try CredentialRotationFixture(blockedFactories: ["deferred-fireworks"])
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "unresolved-child", model: "deferred-fireworks")
        #expect(await fixture.probe.waitUntilEntered("factory:deferred-fireworks"))
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.deepseek) == 1)
        #expect(try await fixture.awaitTerminal("unresolved-child").status == "cancelled")
        #expect(await !fixture.probe.entered("sample:unresolved-child"))
    }

    @Test("authoritative child provider overrides misleading public model names")
    func providerMetadataBeatsModelSlug() async throws {
        let fixture = try CredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "misleading-provider", model: "fireworks-looking-child")
        #expect(await fixture.probe.waitUntilEntered("sample:misleading-provider"))
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.fireworks) == 0)
        #expect(await fixture.host.subagentSnapshot(id: "misleading-provider")?.status == "running")
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.deepseek) == 1)
        #expect(try await fixture.awaitTerminal("misleading-provider").status == "cancelled")
    }

    @Test("external Antigravity children never join provider credential registry")
    func antigravityChildSurvivesProviderRotation() async throws {
        let fixture = try CredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "external-child", model: "antigravity:gemini-3.6-flash")
        #expect(await fixture.probe.waitUntilEntered("antigravity"))
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.fireworks) == 0)
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.gemini) == 0)
        #expect(await fixture.host.subagentSnapshot(id: "external-child")?.status == "running")

        await fixture.probe.release("antigravity")
        #expect(try await fixture.awaitTerminal("external-child").status == "completed")
    }

    @Test("repeated rotation is idempotent and completed children are unregistered")
    func rotationIsIdempotentAndCleansUp() async throws {
        let fixture = try CredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        try await fixture.spawn(id: "one-shot", model: "meta-child")
        #expect(await fixture.probe.waitUntilEntered("sample:one-shot"))
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.meta) == 1)
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.meta) == 0)
        #expect(try await fixture.awaitTerminal("one-shot").status == "cancelled")
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.meta) == 0)
    }

    @Test("every separately authenticated provider is isolated", arguments: [
        ModelProvider.deepseek,
        ModelProvider.meta,
        ModelProvider.kimi,
        ModelProvider.wafer,
        ModelProvider.zai,
        ModelProvider.runinfra,
        ModelProvider.gemini,
        ModelProvider.openRouter,
        ModelProvider.openCodeGo,
    ])
    func allProviderFamiliesAreIndependentlyCancellable(
        provider: ModelProvider
    ) async throws {
        let fixture = try CredentialRotationFixture()
        defer { Task { await fixture.dispose() } }

        let model = provider == .openCodeGo ? "opencode-child" : "\(provider.asString)-child"
        let id = "provider-\(provider.asString)"
        try await fixture.spawn(id: id, model: model)
        #expect(await fixture.probe.waitUntilEntered("sample:\(id)"))
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(.fireworks) == 0)
        #expect(await fixture.host.cancelChildrenForProviderRuntimeChange(provider) == 1)
        #expect(try await fixture.awaitTerminal(id).status == "cancelled")
    }
}
