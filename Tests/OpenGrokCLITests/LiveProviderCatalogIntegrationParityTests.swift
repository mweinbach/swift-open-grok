import Foundation
import OpenGrokAuth
import OpenGrokModels
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokCLI

private final class LiveProviderCatalogFixture: @unchecked Sendable {
    let home: URL
    let environment: [String: String]

    init(extraEnvironment: [String: String] = [:]) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-provider-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var values = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XAI_API_KEY": "live-xai-private",
        ]
        for (key, value) in extraEnvironment {
            values[key] = value
        }
        environment = values
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func resolver(for store: LiveModelCatalogStore) -> LiveModelCatalogResolver {
        LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "live-provider-catalog-session",
            workingDirectory: home,
            catalogSource: { store.snapshot() }
        )
    }

    func openRouterCatalog(
        modelID: String = "anthropic/claude-sonnet-4",
        apiKey: String
    ) throws -> OpenRouterModelsCatalog {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": [[
                "id": modelID,
                "name": "Provider Integration Model",
                "context_length": 200_000,
                "supported_parameters": ["tools", "reasoning"],
                "architecture": ["output_modalities": ["text"]],
            ]],
        ])
        return try OpenRouterModels.parseCatalogSnapshot(
            data,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: apiKey
        )
    }
}

@Suite("Live provider catalog integration parity", .serialized)
struct LiveProviderCatalogIntegrationParityTests {
    @Test("live provider routes retain isolated credentials, aliases, and endpoints")
    func liveProviderCatalogRoutesNeverBorrowSiblingCredentials() async throws {
        let fixture = try LiveProviderCatalogFixture(extraEnvironment: [
            RunInfraModels.gatewayKeyEnv: "runinfra-gateway-private",
            RunInfraModels.apiKeyEnv: "runinfra-alias-private",
            GeminiModels.googleAPIKeyEnv: "gemini-google-private",
            OpenRouterModels.apiKeyEnv: "openrouter-private",
        ])
        defer { fixture.dispose() }
        let openRouterModel = "anthropic/claude-sonnet-4"
        let store = LiveModelCatalogStore(
            input: CatalogResolutionInput(models: ModelsSectionConfig(
                openRouterEnabledModels: [openRouterModel]
            )),
            environment: fixture.environment,
            openGrokHome: fixture.home
        )

        #expect(store.applyRunInfraCatalog(RunInfraModelsCatalog(
            entries: RunInfraModels.curatedCatalog(),
            credentialFingerprint: RunInfraModels.credentialFingerprint(
                apiKey: "runinfra-gateway-private"
            )
        )))
        #expect(store.applyGeminiCatalog(GeminiModelsCatalog(
            entries: GeminiModels.curatedCatalog(),
            credentialFingerprint: GeminiModels.credentialFingerprint(
                apiKey: "gemini-google-private"
            )
        )))
        #expect(store.applyOpenRouterCatalog(try fixture.openRouterCatalog(
            modelID: openRouterModel,
            apiKey: "openrouter-private"
        )))

        let resolver = fixture.resolver(for: store)
        let runinfra = try await resolver.resolve(modelID: "runinfra:deepseek-v4-flash")
        #expect(runinfra.sampling.provider == .runinfra)
        #expect(runinfra.sampling.baseURL == RunInfraModels.apiBaseURLDefault)
        #expect(runinfra.credential.bearer == "runinfra-gateway-private")

        let gemini = try await resolver.resolve(modelID: "gemini:gemini-3.7-flash")
        #expect(gemini.sampling.provider == .gemini)
        #expect(gemini.sampling.baseURL == GeminiModels.apiBaseURLDefault)
        #expect(gemini.credential.bearer == "gemini-google-private")

        let openRouter = try await resolver.resolve(modelID: "openrouter:\(openRouterModel)")
        #expect(openRouter.sampling.provider == .openRouter)
        #expect(openRouter.sampling.baseURL == OpenRouterModels.apiBaseURLDefault)
        #expect(openRouter.credential.bearer == "openrouter-private")
        #expect(openRouter.sampling.extraHeaders["HTTP-Referer"] == OpenRouterModels.httpReferer)
        #expect(openRouter.sampling.extraHeaders["X-Title"] == OpenRouterModels.appTitle)
    }

    @Test("live OpenRouter discovery remains unavailable until explicit model opt-in")
    func liveOpenRouterEnableAndDisableChangeActualResolvableRoutes() async throws {
        let fixture = try LiveProviderCatalogFixture(extraEnvironment: [
            OpenRouterModels.apiKeyEnv: "router-live-private",
        ])
        defer { fixture.dispose() }
        let catalog = try fixture.openRouterCatalog(apiKey: "router-live-private")
        let descriptor = try #require(catalog.descriptors.first)
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(store.applyOpenRouterCatalog(catalog))
        #expect(store.openRouterDescriptors() == [descriptor])
        #expect(store.snapshot()[descriptor.key] == nil)
        #expect(!store.pickerEntries().contains { $0.id == descriptor.key })

        let resolver = fixture.resolver(for: store)
        await #expect(throws: LiveModelSwitchError.unknownModel(descriptor.key)) {
            try await resolver.resolve(modelID: descriptor.key)
        }

        store.applyOpenRouterEnabledModels([descriptor.id])
        #expect(store.pickerEntries().contains { $0.id == descriptor.key })
        let active = try await resolver.resolve(modelID: descriptor.key)
        #expect(active.sampling.provider == .openRouter)
        #expect(active.credential.bearer == "router-live-private")

        store.applyOpenRouterEnabledModels([])
        #expect(!store.pickerEntries().contains { $0.id == descriptor.key })
        #expect(store.openRouterDescriptors() == [descriptor])
        await #expect(throws: LiveModelSwitchError.unknownModel(descriptor.key)) {
            try await resolver.resolve(modelID: descriptor.key)
        }
    }

    @Test("cross-provider matching wire slugs rebuild the live sampler and credentials")
    func matchingProviderWireIDsCannotSilentlyRetainOldRoute() async throws {
        let sharedModel = "deepseek-v4-flash"
        let fixture = try LiveProviderCatalogFixture(extraEnvironment: [
            RunInfraModels.gatewayKeyEnv: "collision-runinfra-private",
            OpenRouterModels.apiKeyEnv: "collision-openrouter-private",
        ])
        defer { fixture.dispose() }
        let store = LiveModelCatalogStore(
            input: CatalogResolutionInput(models: ModelsSectionConfig(
                openRouterEnabledModels: [sharedModel]
            )),
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(store.applyRunInfraCatalog(RunInfraModelsCatalog(
            entries: RunInfraModels.curatedCatalog(),
            credentialFingerprint: RunInfraModels.credentialFingerprint(
                apiKey: "collision-runinfra-private"
            )
        )))
        #expect(store.applyOpenRouterCatalog(try fixture.openRouterCatalog(
            modelID: sharedModel,
            apiKey: "collision-openrouter-private"
        )))

        let resolver = fixture.resolver(for: store)
        let initial = try await resolver.resolve(modelID: "runinfra:\(sharedModel)")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )
        let outcome = await coordinator.apply(modelID: "openrouter:\(sharedModel)")
        guard case .switched(let summary) = outcome else {
            Issue.record("matching wire identifiers silently retained the previous provider")
            return
        }

        #expect(summary.provider == .openRouter)
        #expect(summary.changedProvider)
        let snapshot = await coordinator.snapshot()
        #expect(snapshot.modelID == sharedModel)
        #expect(snapshot.provider == .openRouter)
        #expect(snapshot.configuration.apiKey == "collision-openrouter-private")
        #expect(snapshot.configuration.apiKey != "collision-runinfra-private")
        #expect(snapshot.configuration.baseURL == OpenRouterModels.apiBaseURLDefault)
        #expect(store.entryForWireModel(sharedModel, provider: .runinfra)?.id
            == "runinfra:\(sharedModel)")
        #expect(store.entryForWireModel(sharedModel, provider: .openRouter)?.id
            == "openrouter:\(sharedModel)")
    }

    @Test("revoking the selected OpenRouter model rebuilds the actual fallback sampler")
    func disablingActiveProviderModelRebuildsLiveRoute() async throws {
        let modelID = "anthropic/claude-sonnet-4"
        let fixture = try LiveProviderCatalogFixture(extraEnvironment: [
            OpenRouterModels.apiKeyEnv: "revoked-openrouter-private",
        ])
        defer { fixture.dispose() }
        let catalog = try fixture.openRouterCatalog(
            modelID: modelID,
            apiKey: "revoked-openrouter-private"
        )
        let store = LiveModelCatalogStore(
            input: CatalogResolutionInput(models: ModelsSectionConfig(
                openRouterEnabledModels: [modelID]
            )),
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(store.applyOpenRouterCatalog(catalog))
        let resolver = fixture.resolver(for: store)
        let key = OpenRouterModels.catalogKey(modelID: modelID)
        let initial = try await resolver.resolve(modelID: key)
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )
        store.noteModelSwitch(catalogID: key, effort: initial.sampling.reasoningEffort)
        store.applyOpenRouterEnabledModels([])
        #expect(store.snapshot()[key] == nil)

        let result = try #require(await applyLiveModelCatalogReconcile(
            catalogStore: store,
            modelSwitch: coordinator
        ))
        #expect(result.samplerNeedsRebuild)
        #expect(result.currentModelID != key)
        let fallback = await coordinator.snapshot()
        #expect(fallback.provider == .xai)
        #expect(fallback.configuration.apiKey == "live-xai-private")
        #expect(fallback.configuration.apiKey != "revoked-openrouter-private")
    }

    @Test("persisted OpenRouter opt-in is read through the real authority composition")
    func persistedOpenRouterSelectionsReachLiveCatalogInput() throws {
        let fixture = try LiveProviderCatalogFixture()
        defer { fixture.dispose() }
        let configuration = """
        [models]
        openrouter_enabled_models = ["anthropic/claude-sonnet-4", "openai/gpt-5.4"]
        """
        try Data(configuration.utf8).write(
            to: fixture.home.appendingPathComponent("config.toml"),
            options: .atomic
        )

        let input = liveCatalogResolutionInput(
            workingDirectory: fixture.home,
            environment: fixture.environment
        )
        #expect(input.models.openRouterEnabledModels == [
            "anthropic/claude-sonnet-4",
            "openai/gpt-5.4",
        ])
    }

    @Test("stored provider secrets never satisfy a provider's untrusted proxy endpoint")
    func storedProviderCredentialsCannotEscapeProviderOwnedHosts() async throws {
        let fixture = try LiveProviderCatalogFixture()
        defer { fixture.dispose() }
        try storeRunInfraAPIKey(grokHome: fixture.home, apiKey: "stored-runinfra-private")
        try storeGeminiAPIKey(grokHome: fixture.home, apiKey: "stored-gemini-private")
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "stored-openrouter-private")

        let trusted = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(await trusted.hasUsableCredential(for: .runinfra))
        #expect(await trusted.hasUsableCredential(for: .gemini))
        #expect(await trusted.hasUsableCredential(for: .openRouter))

        let overrides: [(ModelCatalogPartition, String, String)] = [
            (.runinfra, RunInfraModels.apiBaseURLEnv, RunInfraModels.gatewayKeyEnv),
            (.gemini, GeminiModels.apiBaseURLEnv, GeminiModels.apiKeyEnv),
            (.openRouter, OpenRouterModels.apiBaseURLEnv, OpenRouterModels.apiKeyEnv),
        ]
        for (partition, endpointVariable, credentialVariable) in overrides {
            var untrustedEnvironment = fixture.environment
            untrustedEnvironment[endpointVariable] = "https://untrusted.example.test/v1"
            let denied = LiveModelCatalogStore(
                input: .default,
                environment: untrustedEnvironment,
                openGrokHome: fixture.home
            )
            #expect(await !denied.hasUsableCredential(for: partition))

            untrustedEnvironment[credentialVariable] = "explicit-user-proxy-key"
            let explicit = LiveModelCatalogStore(
                input: .default,
                environment: untrustedEnvironment,
                openGrokHome: fixture.home
            )
            #expect(await explicit.hasUsableCredential(for: partition))
        }
    }
}
