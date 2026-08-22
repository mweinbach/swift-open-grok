import Foundation
import OpenGrokConfigTypes
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokModels

private actor ProviderIntegrationCatalogTransport: ModelCatalogTransport {
    private var responses: [ModelCatalogResponse]
    private var requests: [ModelCatalogRequest] = []

    init(responses: [ModelCatalogResponse]) {
        self.responses = responses
    }

    func send(
        _ request: ModelCatalogRequest,
        cancellation: CancellationToken?
    ) async throws -> ModelCatalogResponse {
        try cancellation?.throwIfCancelled()
        requests.append(request)
        guard !responses.isEmpty else {
            return ModelCatalogResponse(status: 503, body: Data("unavailable".utf8))
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [ModelCatalogRequest] {
        requests
    }
}

private actor ProviderIntegrationCredentialBroker: ModelCatalogCredentialBroker {
    private var credentials: [ModelCatalogPartition: ProviderCatalogCredential] = [:]
    private var requested: [ModelCatalogPartition] = []

    func set(
        _ partition: ModelCatalogPartition,
        apiKey: String,
        fingerprint: String
    ) {
        credentials[partition] = ProviderCatalogCredential(
            apiKey: apiKey,
            fingerprint: fingerprint
        )
    }

    func credential(for partition: ModelCatalogPartition) async -> ProviderCatalogCredential? {
        requested.append(partition)
        return credentials[partition]
    }

    func codexCredential(forceRefresh: Bool) async -> CodexCatalogCredential? {
        nil
    }

    func requestedPartitions() -> [ModelCatalogPartition] {
        requested
    }
}

private actor ProviderIntegrationCredentialSequence {
    private var values: [ProviderCatalogCredential]

    init(_ values: [ProviderCatalogCredential]) {
        self.values = values
    }

    func next() -> ProviderCatalogCredential? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private let providerIntegrationOpenRouterResponse = Data(#"""
{
  "data": [
    {
      "id": "anthropic/claude-sonnet-4",
      "name": "Claude Sonnet 4",
      "context_length": 200000,
      "supported_parameters": ["tools", "reasoning"],
      "architecture": { "output_modalities": ["text"] }
    },
    {
      "id": "openai/gpt-5.4",
      "name": "GPT 5.4",
      "context_length": 128000,
      "supported_parameters": ["tools"],
      "architecture": { "output_modalities": ["text"] }
    }
  ]
}
"""#.utf8)

private func providerIntegrationTemporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "opengrok-provider-integration-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@Suite("Provider catalog integration parity", .serialized)
struct ProviderCatalogIntegrationParityTests {
    @Test("new provider partitions map to their own canonical wire identity")
    func providerPartitionsRemainDistinct() {
        #expect(ModelCatalogPartition.runinfra.provider == .runinfra)
        #expect(ModelCatalogPartition.runinfra.rawValue == "runinfra")
        #expect(ModelCatalogPartition.gemini.provider == .gemini)
        #expect(ModelCatalogPartition.gemini.rawValue == "gemini")
        #expect(ModelCatalogPartition.openRouter.provider == .openRouter)
        #expect(ModelCatalogPartition.openRouter.rawValue == "openrouter")
    }

    @Test("stored provider credentials trust only each provider's exact HTTPS host")
    func providerStoredCredentialEndpointsFailClosed() {
        let trusted: [(ModelProvider, String)] = [
            (.runinfra, "https://api.runinfra.ai/v1"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai"),
            (.openRouter, "https://openrouter.ai/api/v1"),
        ]
        for (provider, endpoint) in trusted {
            #expect(trustedBuiltInSessionEndpoint(provider: provider, baseURL: endpoint))
            #expect(!trustedBuiltInSessionEndpoint(
                provider: provider,
                baseURL: endpoint.replacingOccurrences(of: "https://", with: "http://")
            ))
            let host = URL(string: endpoint)?.host ?? ""
            #expect(!trustedBuiltInSessionEndpoint(
                provider: provider,
                baseURL: endpoint.replacingOccurrences(of: host, with: "\(host).attacker.example")
            ))
        }

        #expect(!trustedBuiltInSessionEndpoint(
            provider: .runinfra,
            baseURL: GeminiModels.apiBaseURLDefault
        ))
        #expect(!trustedBuiltInSessionEndpoint(
            provider: .gemini,
            baseURL: OpenRouterModels.apiBaseURLDefault
        ))
        #expect(!trustedBuiltInSessionEndpoint(
            provider: .openRouter,
            baseURL: RunInfraModels.apiBaseURLDefault
        ))
    }

    @Test("OpenRouter remains hidden until an exact provider model is explicitly enabled")
    func openRouterOptInAppliesToCatalogKeysAndWireIDs() throws {
        let apiKey = "openrouter-integration-key"
        let catalog = try OpenRouterModels.parseCatalogSnapshot(
            providerIntegrationOpenRouterResponse,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: apiKey
        )
        let first = try #require(catalog.descriptors.first)
        let second = try #require(catalog.descriptors.dropFirst().first)

        let disabled = resolveModelCatalog(
            input: CatalogResolutionInput(),
            openRouterCatalog: catalog
        )
        #expect(disabled[first.key] == nil)
        #expect(disabled[second.key] == nil)

        let byWireID = resolveModelCatalog(
            input: CatalogResolutionInput(
                models: ModelsSectionConfig(openRouterEnabledModels: [first.id])
            ),
            openRouterCatalog: catalog
        )
        #expect(byWireID[first.key]?.info.provider == .openRouter)
        #expect(byWireID[second.key] == nil)

        let byCatalogKey = resolveModelCatalog(
            input: CatalogResolutionInput(
                models: ModelsSectionConfig(openRouterEnabledModels: [second.key])
            ),
            openRouterCatalog: catalog
        )
        #expect(byCatalogKey[first.key] == nil)
        #expect(byCatalogKey[second.key]?.info.model == second.id)
    }

    @Test("OpenRouter descriptor discovery survives disabling while picker entries disappear")
    func openRouterManagerRetainsCatalogBehindExplicitOptIn() throws {
        let apiKey = "manager-openrouter-key"
        let catalog = try OpenRouterModels.parseCatalogSnapshot(
            providerIntegrationOpenRouterResponse,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: apiKey
        )
        let descriptor = try #require(catalog.descriptors.first)
        let manager = ModelsManager(
            credentials: EmptyCredentialSnapshot(
                openRouterCredentialFingerprint: OpenRouterModels.credentialFingerprint(apiKey)
            )
        )

        #expect(manager.applyOpenRouterCatalog(catalog))
        #expect(manager.openRouterDescriptors().count == 2)
        #expect(manager.catalogSnapshot()[descriptor.key] == nil)

        manager.applyOpenRouterEnabledModels([descriptor.id, "", descriptor.id])
        #expect(manager.openRouterEnabledModels() == [descriptor.id])
        #expect(manager.catalogSnapshot()[descriptor.key]?.info.provider == .openRouter)

        manager.applyOpenRouterEnabledModels([])
        #expect(manager.catalogSnapshot()[descriptor.key] == nil)
        #expect(manager.openRouterDescriptors().count == 2)
    }

    @Test("cross-provider catalog publishing rejects credentials from another principal")
    func providerCatalogPublicationRequiresMatchingCredential() throws {
        let runinfraKey = "runinfra-principal"
        let geminiKey = "gemini-principal"
        let openRouterKey = "openrouter-principal"
        let manager = ModelsManager(
            input: CatalogResolutionInput(
                models: ModelsSectionConfig(openRouterEnabledModels: ["anthropic/claude-sonnet-4"])
            ),
            credentials: EmptyCredentialSnapshot(
                runinfraCredentialFingerprint: RunInfraModels.credentialFingerprint(apiKey: runinfraKey),
                geminiCredentialFingerprint: GeminiModels.credentialFingerprint(apiKey: geminiKey),
                openRouterCredentialFingerprint: OpenRouterModels.credentialFingerprint(openRouterKey)
            )
        )

        let forgedRuninfra = RunInfraModelsCatalog(
            entries: RunInfraModels.curatedCatalog(),
            credentialFingerprint: "other-principal"
        )
        #expect(!manager.applyRunInfraCatalog(forgedRuninfra))

        let validRuninfra = RunInfraModelsCatalog(
            entries: RunInfraModels.curatedCatalog(),
            credentialFingerprint: RunInfraModels.credentialFingerprint(apiKey: runinfraKey)
        )
        #expect(manager.applyRunInfraCatalog(validRuninfra))

        let forgedGemini = GeminiModelsCatalog(
            entries: GeminiModels.curatedCatalog(),
            credentialFingerprint: "other-principal"
        )
        #expect(!manager.applyGeminiCatalog(forgedGemini))
        #expect(manager.applyGeminiCatalog(GeminiModelsCatalog(
            entries: GeminiModels.curatedCatalog(),
            credentialFingerprint: GeminiModels.credentialFingerprint(apiKey: geminiKey)
        )))

        let wrongOpenRouter = try OpenRouterModels.parseCatalogSnapshot(
            providerIntegrationOpenRouterResponse,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: "other-principal"
        )
        #expect(!manager.applyOpenRouterCatalog(wrongOpenRouter))

        let validOpenRouter = try OpenRouterModels.parseCatalogSnapshot(
            providerIntegrationOpenRouterResponse,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: openRouterKey
        )
        #expect(manager.applyOpenRouterCatalog(validOpenRouter))

        let snapshot = manager.catalogSnapshot()
        #expect(snapshot["runinfra:deepseek-v4-flash"]?.info.provider == .runinfra)
        #expect(snapshot["gemini:gemini-3.7-flash"]?.info.provider == .gemini)
        let descriptor = try #require(validOpenRouter.descriptors.first)
        #expect(snapshot[descriptor.key]?.info.provider == .openRouter)
        #expect(snapshot["grok-4.5"]?.info.provider == .xai)
    }

    @Test("RunInfra fetch failure publishes curated fallback only for an authenticated principal")
    func runInfraFallbackRequiresUsableProviderCredential() async throws {
        let home = try providerIntegrationTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = ProviderIntegrationCatalogTransport(responses: [
            ModelCatalogResponse(status: 503, body: Data("gateway unavailable".utf8))
        ])
        let broker = ProviderIntegrationCredentialBroker()
        let apiKey = "runinfra-fallback-key"
        let fingerprint = RunInfraModels.credentialFingerprint(apiKey: apiKey)
        await broker.set(.runinfra, apiKey: apiKey, fingerprint: fingerprint)

        let manager = ModelsManager(
            credentials: EmptyCredentialSnapshot(runinfraCredentialFingerprint: fingerprint),
            grokHome: home,
            liveCatalogs: LiveCatalogRefreshers.live(
                transport: transport,
                broker: broker,
                grokHome: home,
                environment: [:]
            )
        )
        let outcome = await manager.refreshPartition(.runinfra)
        #expect(outcome.published)
        let snapshot = manager.catalogSnapshot()
        for modelID in RunInfraModels.fallbackModelIDs {
            #expect(snapshot[RunInfraModels.catalogKey(modelID: modelID)]?.info.provider == .runinfra)
        }

        let requests = await transport.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.headerValue("Authorization") == "Bearer \(apiKey)")
        #expect(request.url == "https://api.runinfra.ai/v1/models")
        #expect((await broker.requestedPartitions()).allSatisfy { $0 == .runinfra })

        let unconfiguredTransport = ProviderIntegrationCatalogTransport(responses: [])
        let unconfiguredBroker = ProviderIntegrationCredentialBroker()
        let unconfigured = ModelsManager(
            grokHome: home,
            liveCatalogs: LiveCatalogRefreshers.live(
                transport: unconfiguredTransport,
                broker: unconfiguredBroker,
                grokHome: home,
                environment: [:]
            )
        )
        let skipped = await unconfigured.refreshPartition(.runinfra)
        #expect(!skipped.published)
        #expect(unconfigured.catalogSnapshot().pairs().allSatisfy { $0.1.info.provider != .runinfra })
        #expect(await unconfiguredTransport.recordedRequests().isEmpty)
    }

    @Test("Gemini discovery failure preserves only its authenticated reviewed catalog")
    func geminiAuthenticatedFailureRetainsExactlyCuratedModels() async throws {
        let home = try providerIntegrationTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = ProviderIntegrationCatalogTransport(responses: [
            ModelCatalogResponse(status: 503, body: Data("temporarily unavailable".utf8)),
        ])
        let broker = ProviderIntegrationCredentialBroker()
        let apiKey = "gemini-fallback-key"
        let fingerprint = GeminiModels.credentialFingerprint(apiKey: apiKey)
        await broker.set(.gemini, apiKey: apiKey, fingerprint: fingerprint)
        let manager = ModelsManager(
            credentials: EmptyCredentialSnapshot(geminiCredentialFingerprint: fingerprint),
            grokHome: home,
            liveCatalogs: LiveCatalogRefreshers.live(
                transport: transport,
                broker: broker,
                grokHome: home,
                environment: [:]
            )
        )

        let outcome = await manager.refreshPartition(.gemini)
        #expect(outcome.published)
        let geminiEntries = manager.catalogSnapshot().pairs().filter {
            $0.1.info.provider == .gemini
        }
        #expect(geminiEntries.count == 4)
        #expect(Set(geminiEntries.map { $0.1.info.model }) == Set([
            "gemini-3.7-flash",
            "gemini-3.6-flash",
            "gemini-3.5-flash-lite",
            "gemini-3.1-pro-preview",
        ]))
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.headerValue("Authorization") == "Bearer \(apiKey)")
        #expect(request.url == "https://generativelanguage.googleapis.com/v1beta/openai/models")
    }

    @Test("Gemini discovery rejects missing, forged, or rotated provider credentials")
    func geminiFallbackCannotPublishAfterPrincipalChanges() async throws {
        let missingTransport = ProviderIntegrationCatalogTransport(responses: [])
        let absent = ProviderCatalogActors.gemini(
            transport: missingTransport,
            credentialSource: { nil },
            baseURL: GeminiModels.apiBaseURLDefault
        )
        #expect(try await absent.fetch() == nil)
        #expect(await missingTransport.recordedRequests().isEmpty)

        let forged = ProviderCatalogActors.gemini(
            transport: missingTransport,
            credentialSource: {
                ProviderCatalogCredential(apiKey: "gemini-secret", fingerprint: "forged")
            },
            baseURL: GeminiModels.apiBaseURLDefault
        )
        #expect(try await forged.fetch() == nil)
        #expect(await missingTransport.recordedRequests().isEmpty)

        let original = "gemini-original-secret"
        let replacement = "gemini-replacement-secret"
        let credentials = ProviderIntegrationCredentialSequence([
            ProviderCatalogCredential(
                apiKey: original,
                fingerprint: GeminiModels.credentialFingerprint(apiKey: original)
            ),
            ProviderCatalogCredential(
                apiKey: replacement,
                fingerprint: GeminiModels.credentialFingerprint(apiKey: replacement)
            ),
        ])
        let failingTransport = ProviderIntegrationCatalogTransport(responses: [
            ModelCatalogResponse(status: 503, body: Data("unavailable".utf8)),
        ])
        let rotating = ProviderCatalogActors.gemini(
            transport: failingTransport,
            credentialSource: { await credentials.next() },
            baseURL: GeminiModels.apiBaseURLDefault
        )
        #expect(try await rotating.fetch() == nil)
        #expect(await failingTransport.recordedRequests().count == 1)
    }

    @Test("OpenRouter model requests preserve attribution and provider-local credentials")
    func openRouterFetchUsesExactProviderHeadersAndPrincipal() async throws {
        let apiKey = "openrouter-fetch-key"
        let transport = ProviderIntegrationCatalogTransport(responses: [
            ModelCatalogResponse(status: 200, body: providerIntegrationOpenRouterResponse)
        ])
        let actor = ProviderCatalogActors.openRouter(
            transport: transport,
            credentialSource: {
                ProviderCatalogCredential(
                    apiKey: apiKey,
                    fingerprint: OpenRouterModels.credentialFingerprint(apiKey)
                )
            },
            baseURL: OpenRouterModels.apiBaseURLDefault
        )

        let catalog = try #require(try await actor.fetch())
        #expect(catalog.credentialFingerprint == OpenRouterModels.credentialFingerprint(apiKey))
        #expect(catalog.descriptors.count == 2)

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url == "https://openrouter.ai/api/v1/models")
        #expect(request.timeout == 15)
        #expect(request.headers.map(\.name) == ["Authorization", "HTTP-Referer", "X-Title"])
        #expect(request.headerValue("Authorization") == "Bearer \(apiKey)")
        #expect(request.headerValue("HTTP-Referer") == "https://github.com/mweinbach/open-grok")
        #expect(request.headerValue("X-Title") == "Open Grok")
    }

    @Test("configured custom provider overrides survive authoritative provider partitions")
    func configuredProviderOverrideWinsAfterProviderCatalogReplace() throws {
        var override = ConfigModelOverride()
        override.provider = .gemini
        override.name = "Explicit Gemini Override"
        let key = GeminiModels.catalogKey(modelID: "gemini-3.7-flash")
        let catalog = resolveModelCatalog(
            input: CatalogResolutionInput(configModels: [(key, override)]),
            geminiCatalog: GeminiModelsCatalog(
                entries: GeminiModels.curatedCatalog(),
                credentialFingerprint: "gemini-principal"
            )
        )

        let entry = try #require(catalog[key])
        #expect(entry.info.name == "Explicit Gemini Override")
        #expect(entry.info.provider == .gemini)
        #expect(entry.info.model == "gemini-3.7-flash")
        #expect(catalog["grok-4.5"]?.info.provider == .xai)
    }
}
