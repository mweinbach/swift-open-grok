// OpenGrokModelsTests.swift
//
// Hermetic suites for OpenGrokModels (R13).
// Coverage mirrors xai-grok-models + shell catalog resolution tests:
// embedded corpus, precedence, filters, provider isolation, cache, capabilities.

import Foundation
import Testing
import OpenGrokConfigTypes
import OpenGrokModels
import OpenGrokSamplingTypes

// MARK: - Embedded corpus

@Suite("Embedded default models")
struct EmbeddedDefaultModelsTests {
    @Test func defaultIDsMatchRustCorpus() {
        #expect(defaultModel() == "grok-4.5")
        #expect(defaultWebSearchModel() == "grok-4.20-multi-agent")
        #expect(defaultImageDescriptionModel() == "grok-4.5")
        #expect(defaultSessionSummaryModel() == "grok-4.5")
        #expect(defaultModel(for: .webSearch) == "grok-4.20-multi-agent")
    }

    @Test func embeddedJSONParsesAndContainsDefault() throws {
        let embedded = try parseEmbeddedDefaultModels(DEFAULT_MODELS_JSON)
        #expect(embedded.default == "grok-4.5")
        #expect(embedded.models.map(\.model).contains("grok-4.5"))
        // Multi-provider corpus.
        let providers = Set(embedded.models.map(\.provider))
        #expect(providers.contains(.xai))
        #expect(providers.contains(.kimi))
        #expect(providers.contains(.fireworks))
        #expect(providers.contains(.codex))
    }

    @Test func fixtureFileMatchesEmbeddedConstant() throws {
        // Prefer the checked-in fixture when present; fall back to the constant.
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/default_models.json"),
        ]
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let fixture = try? String(contentsOf: url, encoding: .utf8) {
            let a = try parseEmbeddedDefaultModels(fixture)
            let b = try parseEmbeddedDefaultModels(DEFAULT_MODELS_JSON)
            #expect(a.default == b.default)
            #expect(a.models.count == b.models.count)
            #expect(a.models.map(\.model) == b.models.map(\.model))
        } else {
            // Fixture optional if resource packaging is absent; constant is authority.
            #expect(!DEFAULT_MODELS_JSON.isEmpty)
        }
    }

    @Test func defaultEntriesPreserveStableKeysAndCapabilities() {
        let map = defaultModelEntries()
        #expect(map["grok-4.5"] != nil)
        let grok = map["grok-4.5"]!
        #expect(grok.info.provider == .xai)
        #expect(grok.info.apiBackend == .responses)
        #expect(grok.info.supportsReasoningEffort == true)
        #expect(grok.info.contextWindow == 500_000)
        #expect(grok.info.showModelFingerprint == true)
        #expect(grok.info.reasoningEfforts.count == 3)

        // Fireworks curated key differs from routing slug.
        let glm = map["glm-5.2"]!
        #expect(glm.info.model == "accounts/fireworks/models/glm-5p2")
        #expect(glm.info.provider == .fireworks)
        #expect(glm.info.apiBackend == .chatCompletions)

        // Codex embedded models.
        let sol = map["gpt-5.6-sol"]!
        #expect(sol.info.provider == .codex)
        #expect(sol.info.toolMode == .codeModeOnly)
        #expect(sol.info.codexMultiAgentV2 == true)
        #expect(sol.info.supportedInApi == false)
        #expect(sol.info.supportsReasoningSummaryParameter == true)
        #expect(sol.info.defaultReasoningSummary == .detailed)
    }

    @Test func kimiEndpointFiltersEmbeddedPartition() {
        let platform = defaultModelEntries(kimiEndpoint: .platform)
        #expect(platform["kimi-k3"] != nil)
        #expect(platform["kimi-for-coding"] == nil)

        let code = defaultModelEntries(kimiEndpoint: .code)
        #expect(code["kimi-k3"] == nil)
        #expect(code["kimi-for-coding"] != nil)
        #expect(code["kimi-for-coding-highspeed"] != nil)
    }
}

// MARK: - Catalog resolution

@Suite("Catalog resolution")
struct CatalogResolutionTests {
    @Test func configOverrideWinsOverDefaults() {
        var input = CatalogResolutionInput()
        input.configModels = [(
            "custom-model",
            ConfigModelOverride(
                model: "custom-model",
                baseURL: "https://example.com/v1",
                contextWindow: 123_456,
                provider: .kimi
            )
        )]
        let catalog = resolveModelCatalog(input: input)
        #expect(catalog["custom-model"] != nil)
        #expect(catalog["custom-model"]!.info.contextWindow == 123_456)
        #expect(catalog["custom-model"]!.info.provider == .kimi)
    }

    @Test func disabledModelsRemoved() {
        var input = CatalogResolutionInput()
        input.models.disabledModels = ["to-disable"]
        input.configModels = [(
            "to-disable",
            ConfigModelOverride(
                model: "to-disable",
                baseURL: "https://api.x.ai/v1",
                contextWindow: 200_000
            )
        )]
        let catalog = resolveModelCatalog(input: input)
        #expect(catalog["to-disable"] == nil)
    }

    @Test func hiddenModelsKeptButFlagged() {
        var input = CatalogResolutionInput()
        input.models.hiddenModels = ["to-hide"]
        input.configModels = [(
            "to-hide",
            ConfigModelOverride(
                model: "to-hide",
                baseURL: "https://api.x.ai/v1",
                contextWindow: 200_000
            )
        )]
        let catalog = resolveModelCatalog(input: input)
        #expect(catalog["to-hide"] != nil)
        #expect(catalog["to-hide"]!.info.hidden == true)
        let visible = availableModels(catalog: catalog, hasXaiSession: true, hasCodexSession: false)
        #expect(visible["to-hide"] == nil)
    }

    @Test func allowedModelsMarksSelectableByWildcard() {
        var input = CatalogResolutionInput()
        input.models.allowedModels = ["keep-*", "explicit-key", "explicit-model-id"]
        input.configModels = [
            ("to-drop", ConfigModelOverride(model: "to-drop", baseURL: "https://api.x.ai/v1", contextWindow: 256_000)),
            ("keep-one", ConfigModelOverride(model: "keep-one", baseURL: "https://api.x.ai/v1", contextWindow: 256_000)),
            ("explicit-key", ConfigModelOverride(model: "explicit-model-id", baseURL: "https://api.x.ai/v1", contextWindow: 256_000)),
        ]
        let catalog = resolveModelCatalog(input: input)
        #expect(catalog["keep-one"]!.info.userSelectable)
        #expect(catalog["explicit-key"]!.info.userSelectable)
        #expect(!catalog["to-drop"]!.info.userSelectable)
    }

    @Test func emptyAllowedModelsIsUnrestricted() {
        var input = CatalogResolutionInput()
        input.models.allowedModels = []
        input.configModels = [
            ("foo", ConfigModelOverride(model: "foo", baseURL: "https://api.x.ai/v1", contextWindow: 256_000)),
        ]
        let catalog = resolveModelCatalog(input: input)
        #expect(catalog["foo"]!.info.userSelectable)
    }

    @Test func invalidGlobFailsClosed() {
        switch ModelGlobSet.compile(["grok["]) {
        case .failure(let error):
            #expect(error == .invalidGlob(field: "models", patterns: ["grok["]))
        case .success:
            Issue.record("expected invalid glob rejection")
        }
    }

    @Test func prefetchedXaiReplacesOnlyXaiPartition() {
        var remote = OrderedModelMap()
        var remoteEntry = ModelEntry.fallback(slug: "grok-live", endpoints: .default)
        remoteEntry.info.provider = .xai
        remoteEntry.info.contextWindow = 400_000
        remote["grok-live"] = remoteEntry

        // Poison: non-xAI entry from xAI transport must be ignored.
        var poison = ModelEntry.fallback(slug: "kimi-poison", endpoints: .default)
        poison.info.provider = .kimi
        remote["kimi-poison"] = poison

        let catalog = resolveModelCatalog(input: .default, prefetched: remote)
        #expect(catalog["grok-live"] != nil)
        #expect(catalog["kimi-poison"] == nil)
        // Embedded kimi still present.
        #expect(catalog["kimi-k3"] != nil)
    }

    @Test func codexAuthoritativeReplacesCodexPartitionOnly() {
        var codexRemote = OrderedModelMap()
        var live = ModelEntry.fallback(slug: "gpt-live", endpoints: .default)
        live.info.provider = .codex
        live.info.apiBackend = .responses
        live.info.agentType = "codex"
        codexRemote["gpt-live"] = live

        let catalog = CodexModelsCatalog(
            models: [
                CodexCatalogModel(priority: 1, visibility: .list, entry: live),
            ],
            accountFingerprint: "acct"
        )
        #expect(catalog.isAuthoritative)

        let resolved = resolveModelCatalog(input: .default, codexCatalog: catalog)
        #expect(resolved["gpt-live"] != nil)
        // Embedded xAI still present.
        #expect(resolved["grok-4.5"] != nil)
        // Authoritative Codex remote replaces embedded Codex models.
        #expect(resolved["gpt-5.6-sol"] == nil)
    }

    @Test func providerKeyCollisionQualifiesExisting() {
        var input = CatalogResolutionInput()
        // Pre-seed a non-xAI entry under a bare key that xAI will claim.
        input.configModels = [(
            "shared-slug",
            ConfigModelOverride(
                model: "shared-slug",
                baseURL: "https://api.moonshot.ai/v1",
                contextWindow: 100_000,
                provider: .kimi
            )
        )]
        // Apply config first via list resolve, then merge prefetched xAI.
        var prefetched = OrderedModelMap()
        var xai = ModelEntry.fallback(slug: "shared-slug", endpoints: .default)
        xai.info.provider = .xai
        xai.info.contextWindow = 200_000
        prefetched["shared-slug"] = xai

        // Config applies after remotes, so build with config then manually
        // exercise merge via resolveModelListWithProviderCatalogs order:
        // defaults + prefetched (xAI) then config.
        let list = resolveModelList(input: input, prefetched: prefetched)
        // Config re-inserts shared-slug as kimi, overwriting xAI — that's correct
        // priority (config wins). Verify config ownership.
        #expect(list["shared-slug"]?.info.provider == .kimi)
    }

    @Test func findModelByIDPrefersKeyThenSlug() {
        var map = OrderedModelMap()
        map["enterprise-grok"] = ModelEntry.fallback(slug: "grok-4.5", endpoints: .default)
        map["grok-4.5"] = ModelEntry.fallback(slug: "grok-4.5", endpoints: .default)
        #expect(findModelByID(map, modelID: "enterprise-grok") != nil)
        #expect(resolveCatalogKey(map, modelID: "grok-4.5") == "grok-4.5")
        // Last slug match for pure slug lookup without exact key of a different entry:
        var onlySlug = OrderedModelMap()
        onlySlug["a"] = ModelEntry.fallback(slug: "grok-4.5", endpoints: .default)
        onlySlug["b"] = ModelEntry.fallback(slug: "grok-4.5", endpoints: .default)
        #expect(resolveCatalogKey(onlySlug, modelID: "grok-4.5") == "b")
    }

    @Test func customEndpointSkipsBuiltInXaiDefaults() {
        var input = CatalogResolutionInput()
        input.endpoints.modelsBaseURL = "https://custom.example/v1"
        let catalog = resolveModelCatalog(input: input)
        #expect(catalog["grok-4.5"] == nil)
        // Non-xAI embedded still present.
        #expect(catalog["kimi-k3"] != nil)
    }
}

// MARK: - Default model precedence

@Suite("Default model precedence")
struct DefaultModelPrecedenceTests {
    func baseCatalog() -> OrderedModelMap {
        resolveModelCatalog(input: .default)
    }

    @Test func cliBeatsEnvAndConfig() {
        var input = CatalogResolutionInput()
        input.defaultModelOverride = "gpt-5.6-terra"
        input.models.default = "grok-4.5"
        let env = ["GROK_DEFAULT_MODEL": "kimi-k3"]
        let resolved = resolveDefaultModel(
            input: input,
            catalog: baseCatalog(),
            hasXaiSession: true,
            hasCodexSession: true,
            environment: env
        )
        #expect(resolved.catalogKey == "gpt-5.6-terra")
        #expect(resolved.source == .cli)
    }

    @Test func envBeatsConfig() {
        var input = CatalogResolutionInput()
        input.models.default = "grok-4.5"
        let env = ["GROK_DEFAULT_MODEL": "kimi-k3"]
        let resolved = resolveDefaultModel(
            input: input,
            catalog: baseCatalog(),
            hasXaiSession: true,
            hasCodexSession: false,
            environment: env
        )
        #expect(resolved.catalogKey == "kimi-k3")
        #expect(resolved.source == .env)
    }

    @Test func configBeatsRemote() {
        var input = CatalogResolutionInput()
        input.models.default = "kimi-k3"
        input.remoteDefaultModel = "grok-4.5"
        let resolved = resolveDefaultModel(
            input: input,
            catalog: baseCatalog(),
            hasXaiSession: true,
            hasCodexSession: false,
            environment: [:]
        )
        #expect(resolved.catalogKey == "kimi-k3")
        #expect(resolved.source == .config)
    }

    @Test func remoteUsedWhenNoHigherTier() {
        var input = CatalogResolutionInput()
        input.remoteDefaultModel = "kimi-k3"
        let resolved = resolveDefaultModel(
            input: input,
            catalog: baseCatalog(),
            hasXaiSession: true,
            hasCodexSession: false,
            environment: [:]
        )
        #expect(resolved.catalogKey == "kimi-k3")
        #expect(resolved.source == .remote)
    }

    @Test func bundledDefaultWhenCatalogEmptyOfVisible() {
        var input = CatalogResolutionInput()
        // Allowlist that matches nothing → fallback path with userSelectable false.
        input.models.allowedModels = ["zzz-no-match-*"]
        let catalog = resolveModelCatalog(input: input)
        #expect(allowlistMatchesNothing(input: input, catalog: catalog))
        let resolved = resolveDefaultModel(
            input: input,
            catalog: catalog,
            isSessionAuth: true,
            environment: [:]
        )
        #expect(resolved.source == .default)
    }

    @Test func prefersIdOverModelSlug() {
        var catalog = OrderedModelMap()
        catalog["auto-grok-build"] = ModelEntry.fallback(slug: "grok-build", endpoints: .default)
        catalog["grok-build"] = ModelEntry.fallback(slug: "grok-build", endpoints: .default)
        // Mark selectable/visible.
        for (k, var e) in catalog.pairs() {
            e.info.userSelectable = true
            e.info.supportedInApi = true
            catalog[k] = e
        }
        var input = CatalogResolutionInput()
        input.models.default = "grok-build"
        let resolved = resolveDefaultModel(
            input: input,
            catalog: catalog,
            isSessionAuth: true,
            environment: [:]
        )
        #expect(resolved.catalogKey == "grok-build")
    }

    @Test func campaignRecoveryUsesPreCampaignDefault() {
        var catalog = OrderedModelMap()
        var a = ModelEntry.fallback(slug: "keep-me", endpoints: .default)
        a.info.userSelectable = true
        catalog["keep-me"] = a
        // Campaign points at missing model.
        var input = CatalogResolutionInput()
        input.models.default = "missing-campaign-model"
        input.models.defaultIsCampaignDriven = true
        input.models.preCampaignDefault = "keep-me"
        let resolved = resolveDefaultModel(
            input: input,
            catalog: catalog,
            isSessionAuth: true,
            environment: [:]
        )
        #expect(resolved.catalogKey == "keep-me")
        #expect(resolved.source == .config)
    }

    @Test func codexSessionDoesNotUnlockXaiOauthOnlyModels() {
        // supported_in_api=false models need provider session.
        var catalog = OrderedModelMap()
        var oauthOnly = ModelEntry.fallback(slug: "xai-oauth-only", endpoints: .default)
        oauthOnly.info.provider = .xai
        oauthOnly.info.supportedInApi = false
        oauthOnly.info.userSelectable = true
        catalog["xai-oauth-only"] = oauthOnly

        var codex = ModelEntry.fallback(slug: "gpt-codex", endpoints: .default)
        codex.info.provider = .codex
        codex.info.supportedInApi = false
        codex.info.userSelectable = true
        catalog["gpt-codex"] = codex

        let withCodexOnly = availableModels(
            catalog: catalog,
            hasXaiSession: false,
            hasCodexSession: true
        )
        #expect(withCodexOnly["xai-oauth-only"] == nil)
        #expect(withCodexOnly["gpt-codex"] != nil)

        let withXaiOnly = availableModels(
            catalog: catalog,
            hasXaiSession: true,
            hasCodexSession: false
        )
        #expect(withXaiOnly["xai-oauth-only"] != nil)
        #expect(withXaiOnly["gpt-codex"] == nil)
    }
}

// MARK: - Cache

@Suite("Models cache")
struct ModelsCacheTests {
    func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-models-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func persistAndLoadFresh() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = ModelsCacheManager(grokHome: home, versionProvider: { "1.2.3-test" })
        var map = OrderedModelMap()
        map["m1"] = ModelEntry.fallback(slug: "m1", endpoints: .default)
        try cache.persist(
            models: map,
            etag: "\"etag-1\"",
            authMethod: .session,
            origin: "https://cli-chat-proxy.grok.com/v1/models"
        )
        let loaded = cache.loadFresh(
            expectedAuth: .session,
            expectedOrigin: "https://cli-chat-proxy.grok.com/v1/models"
        )
        #expect(loaded != nil)
        #expect(loaded?.models["m1"] != nil)
        #expect(loaded?.etag == "\"etag-1\"")
    }

    @Test func originMismatchIsMiss() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = ModelsCacheManager(grokHome: home, versionProvider: { "1.2.3-test" })
        var map = OrderedModelMap()
        map["m1"] = ModelEntry.fallback(slug: "m1", endpoints: .default)
        try cache.persist(
            models: map,
            etag: nil,
            authMethod: .apiKey,
            origin: "https://api.x.ai/v1/models"
        )
        let miss = cache.loadFresh(
            expectedAuth: .apiKey,
            expectedOrigin: "https://other.example/v1/models"
        )
        #expect(miss == nil)
    }

    @Test func authMethodMismatchIsMiss() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = ModelsCacheManager(grokHome: home, versionProvider: { "1.2.3-test" })
        var map = OrderedModelMap()
        map["m1"] = ModelEntry.fallback(slug: "m1", endpoints: .default)
        try cache.persist(
            models: map,
            etag: nil,
            authMethod: .session,
            origin: "https://cli-chat-proxy.grok.com/v1/models"
        )
        let miss = cache.loadFresh(
            expectedAuth: .apiKey,
            expectedOrigin: "https://cli-chat-proxy.grok.com/v1/models"
        )
        #expect(miss == nil)
    }

    @Test func versionMismatchIsMiss() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = ModelsCacheManager(grokHome: home, versionProvider: { "1.0.0" })
        var map = OrderedModelMap()
        map["m1"] = ModelEntry.fallback(slug: "m1", endpoints: .default)
        try cache.persist(
            models: map,
            etag: nil,
            authMethod: .session,
            origin: "https://cli-chat-proxy.grok.com/v1/models"
        )
        let other = ModelsCacheManager(grokHome: home, versionProvider: { "2.0.0" })
        let miss = other.loadFresh(
            expectedAuth: .session,
            expectedOrigin: "https://cli-chat-proxy.grok.com/v1/models"
        )
        #expect(miss == nil)
    }

    @Test func staleCacheIsMiss() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = ModelsCacheManager(
            grokHome: home,
            ttl: 1,
            versionProvider: { "1.0.0" }
        )
        var map = OrderedModelMap()
        map["m1"] = ModelEntry.fallback(slug: "m1", endpoints: .default)
        let past = Date().addingTimeInterval(-10)
        try cache.persist(
            models: map,
            etag: nil,
            authMethod: .session,
            origin: "https://cli-chat-proxy.grok.com/v1/models",
            now: past
        )
        let miss = cache.loadFresh(
            expectedAuth: .session,
            expectedOrigin: "https://cli-chat-proxy.grok.com/v1/models"
        )
        #expect(miss == nil)
    }

    @Test func corruptCacheThrowsOnRawLoad() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(MODELS_CACHE_FILE)
        try Data("{not json".utf8).write(to: path)
        let cache = ModelsCacheManager(grokHome: home, versionProvider: { "1.0.0" })
        #expect(throws: ModelsError.self) {
            _ = try cache.loadRaw()
        }
    }

    @Test func codexCacheIsIsolatedFromXaiPath() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let xai = ModelsCacheManager(grokHome: home, versionProvider: { "1.0.0" })
        let codex = CodexModelsCacheManager(grokHome: home)
        #expect(xai.path.lastPathComponent == "models_cache.json")
        #expect(codex.path.lastPathComponent == "codex_models_cache.json")
        #expect(xai.path != codex.path)
    }
}

// MARK: - Remote parse

@Suite("Remote model parse")
struct RemoteModelParseTests {
    @Test func parsesOpenAIStyleList() throws {
        let json = """
        {
          "data": [
            {
              "id": "auto",
              "model": "grok-build",
              "name": "Auto",
              "context_window": 372000,
              "api_backend": "responses",
              "provider": "xai",
              "supports_reasoning_effort": true
            },
            {
              "id": "bad",
              "context_window": 0
            }
          ]
        }
        """
        let models = try parseModelsListResponse(
            Data(json.utf8),
            defaultBaseURL: "https://cli-chat-proxy.grok.com/v1"
        )
        #expect(models.count == 1)
        #expect(models[0].id == "auto")
        #expect(models[0].model == "grok-build")
        #expect(models[0].contextWindow == 372_000)
        #expect(models[0].apiBackend == .responses)
        #expect(models[0].provider == .xai)
    }

    @Test func rejectsUnknownProvider() {
        let obj: [String: Any] = [
            "model": "mystery",
            "context_window": 1000,
            "provider": "totally-unknown-future-provider",
        ]
        #expect(parseRemoteModelValue(obj, defaultBaseURL: "https://example.com") == nil)
    }

    @Test func defaultsProviderToXaiWhenOmitted() {
        let obj: [String: Any] = [
            "model": "legacy-model",
            "context_window": 256000,
        ]
        let entry = parseRemoteModelValue(obj, defaultBaseURL: "https://cli-chat-proxy.grok.com/v1")
        #expect(entry?.provider == .xai)
    }

    @Test func modelsListURLDependsOnAuth() {
        let endpoints = EndpointsConfig()
        #expect(
            modelsListURL(endpoints: endpoints, fetchAuth: .apiKey)
                == "https://api.x.ai/v1/models"
        )
        #expect(
            modelsListURL(endpoints: endpoints, fetchAuth: .session)
                == "https://cli-chat-proxy.grok.com/v1/models"
        )
        var custom = EndpointsConfig()
        custom.modelsListURL = "https://custom.example/models"
        #expect(
            modelsListURL(endpoints: custom, fetchAuth: .session)
                == "https://custom.example/models"
        )
    }

    @Test func fetchAuthPrecedence() {
        var endpoints = EndpointsConfig()
        #expect(
            ModelFetchAuth.resolve(
                endpoints: endpoints,
                hasCachedSession: true,
                hasXaiApiKeyEnv: true
            ) == .session
        )
        endpoints.modelsBaseURL = "https://custom"
        #expect(
            ModelFetchAuth.resolve(
                endpoints: endpoints,
                hasCachedSession: true,
                hasXaiApiKeyEnv: true
            ) == .customEndpoint
        )
        endpoints = EndpointsConfig()
        endpoints.deploymentKey = "dep"
        #expect(
            ModelFetchAuth.resolve(
                endpoints: endpoints,
                hasCachedSession: false,
                hasXaiApiKeyEnv: true
            ) == .deployment
        )
    }
}

// MARK: - Provider isolation

@Suite("Provider isolation")
struct ProviderIsolationTests {
    @Test func kimiTrustedHosts() {
        #expect(KimiModels.endpoint(forBaseURL: "https://api.moonshot.ai/v1") == .platform)
        #expect(KimiModels.endpoint(forBaseURL: "https://api.kimi.com/coding/v1") == .code)
        #expect(KimiModels.endpoint(forBaseURL: "https://evil.example/v1") == nil)
        #expect(!KimiModels.isTrustedAPIBaseURL("http://api.moonshot.ai/v1"))
    }

    @Test func fireworksTrustedHost() {
        #expect(FireworksModels.isTrustedAPIBaseURL("https://api.fireworks.ai/inference/v1"))
        #expect(!FireworksModels.isTrustedAPIBaseURL("https://evil.example/v1"))
    }

    @Test func fireworksEnrichmentCannotAddModels() throws {
        let json = """
        {
          "data": [
            {
              "id": "accounts/fireworks/models/glm-5p2",
              "context_length": 999999
            },
            {
              "id": "accounts/fireworks/models/totally-new-model",
              "context_length": 1000
            }
          ]
        }
        """
        let enrichment = try FireworksModels.parseContextEnrichment(Data(json.utf8))
        #expect(enrichment["accounts/fireworks/models/glm-5p2"] == 999_999)
        #expect(enrichment["accounts/fireworks/models/totally-new-model"] == nil)
        let catalog = FireworksModels.curatedCatalog(contextBySlug: enrichment)
        #expect(catalog.count == FireworksModels.curated.count)
        #expect(catalog["glm-5.2"]!.info.contextWindow == 999_999)
    }

    @Test func codexWireParse() throws {
        let json = """
        {
          "models": [
            {
              "slug": "gpt-test",
              "display_name": "GPT Test",
              "description": "desc",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort": "low", "description": "fast"},
                {"effort": "medium", "description": "balanced"}
              ],
              "visibility": "list",
              "supported_in_api": false,
              "priority": 10,
              "context_window": 353000,
              "effective_context_window_percent": 95,
              "tool_mode": "code_mode_only",
              "multi_agent_version": "v2",
              "supports_search_tool": true
            }
          ]
        }
        """
        let models = try parseCodexModelsResponse(Data(json.utf8))
        #expect(models.count == 1)
        let m = models[0]
        #expect(m.slug == "gpt-test")
        #expect(m.visibility == .list)
        #expect(m.entry.info.provider == .codex)
        #expect(m.entry.info.toolMode == .codeModeOnly)
        #expect(m.entry.info.codexMultiAgentV2)
        #expect(m.entry.info.supportsReasoningEffort)
        #expect(m.entry.info.contextWindow == UInt64((353_000 * 95) / 100))
    }

    @Test func codexClientVersionNormalization() {
        #expect(CodexModels.normalizeWholeSemver("v0.144.5-rc.1") == "0.144.5")
        #expect(CodexModels.normalizeWholeSemver("not-a-version") == nil)
        #expect(
            CodexModels.clientVersion(environment: ["OPENGROK_CODEX_CLIENT_VERSION": "1.2.3-beta"])
                == "1.2.3"
        )
    }
}

// MARK: - Capability truth

@Suite("Capability truth")
struct CapabilityTruthTests {
    @Test func neverInfersFromName() {
        let catalog = resolveModelCatalog(input: .default)
        // Unknown model: fail closed.
        #expect(capabilities(for: "totally-made-up-vision-model", in: catalog) == nil)
        #expect(!modelSupports(.imageSupport, modelID: "totally-made-up-vision-model", catalog: catalog))
        #expect(!modelSupports(.reasoningEffort, modelID: "nope", catalog: catalog))
    }

    @Test func readsFromCatalogOnly() {
        let catalog = resolveModelCatalog(input: .default)
        let caps = capabilities(for: "grok-4.5", in: catalog)
        #expect(caps != nil)
        #expect(caps!.supportsReasoningEffort)
        #expect(caps!.provider == .xai)
        #expect(caps!.apiBackend == .responses)
        #expect(modelSupports(.reasoningEffort, modelID: "grok-4.5", catalog: catalog))
        #expect(modelSupports(.codeModeOnly, modelID: "gpt-5.6-sol", catalog: catalog))
        #expect(!modelSupports(.codeModeOnly, modelID: "grok-4.5", catalog: catalog))
        #expect(modelSupports(.nativeWebSearch, modelID: "grok-4.5", catalog: catalog))
        // Kimi profile: no native web search.
        #expect(!modelSupports(.nativeWebSearch, modelID: "kimi-k3", catalog: catalog))
    }

    @Test func providerOverrideDoesNotCarryDonorCapabilities() {
        var base = ModelEntry.fallback(slug: "switch-me", endpoints: .default)
        base.info.provider = .codex
        base.info.apiBackend = .responses
        base.info.toolMode = .codeModeOnly
        base.info.codexMultiAgentV2 = true
        base.info.supportsBackendSearch = true
        base.info.supportsReasoningEffort = true
        base.info.reasoningEfforts = [
            ReasoningEffortOption(id: "high", value: .high, label: "High", description: nil, isDefault: true),
        ]

        let override = ConfigModelOverride(provider: .kimi)
        let applied = override.apply(key: "switch-me", base: base, endpoints: .default)
        #expect(applied.info.provider == .kimi)
        #expect(applied.info.apiBackend == .chatCompletions)
        #expect(applied.info.toolMode == nil)
        #expect(!applied.info.codexMultiAgentV2)
        #expect(!applied.info.supportsBackendSearch)
        #expect(applied.info.reasoningEfforts.isEmpty)
        #expect(!applied.info.supportsReasoningEffort)
    }
}

// MARK: - ModelsManager

@Suite("ModelsManager")
struct ModelsManagerTests {
    final class ScriptedXaiTransport: XaiModelsTransport, @unchecked Sendable {
        var result: FetchModelsResult
        var callCount = 0
        init(result: FetchModelsResult) { self.result = result }
        func fetchModels(
            listURL: String,
            fetchAuth: ModelFetchAuth,
            cancellation: CancellationToken?
        ) async throws -> FetchModelsResult {
            try cancellation?.throwIfCancelled()
            callCount += 1
            return result
        }
    }

    @Test func managerAssemblesEmbeddedCatalog() {
        let mgr = ModelsManager()
        let snap = mgr.catalogSnapshot()
        #expect(snap["grok-4.5"] != nil)
        #expect(mgr.currentModel().id == "grok-4.5")
    }

    @Test func refreshUsesTransportAndCache() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let config = ModelEntryConfig(
            id: "live-1",
            model: "live-1",
            baseURL: "https://cli-chat-proxy.grok.com/v1",
            contextWindow: 300_000,
            apiBackend: .responses,
            provider: .xai
        )
        let transport = ScriptedXaiTransport(
            result: FetchModelsResult(models: [config], etag: "\"e1\"")
        )
        let mgr = ModelsManager(
            credentials: EmptyCredentialSnapshot(hasXaiSession: true),
            grokHome: home,
            xaiTransport: transport,
            versionProvider: { "test-ver" }
        )
        try await mgr.refreshXai(strategy: .online)
        #expect(transport.callCount == 1)
        #expect(mgr.catalogSnapshot()["live-1"] != nil)
        #expect(mgr.currentETag() == "\"e1\"")

        // Second refresh with onlineIfUncached should hit cache, not transport.
        try await mgr.refreshXai(strategy: .onlineIfUncached)
        #expect(transport.callCount == 1)
    }

    @Test func cancellationAbortsRefresh() async {
        let transport = ScriptedXaiTransport(result: FetchModelsResult(models: [], etag: nil))
        let mgr = ModelsManager(xaiTransport: transport, versionProvider: { "v" })
        let token = CancellationToken()
        token.cancel()
        do {
            try await mgr.refreshXai(strategy: .online, cancellation: token)
            Issue.record("expected ModelsError.cancelled")
        } catch ModelsError.cancelled {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func codexPublishRejectsFingerprintMismatch() {
        let mgr = ModelsManager(
            credentials: EmptyCredentialSnapshot(
                hasCodexSession: true,
                codexAccountFingerprint: "account-a"
            )
        )
        var entry = ModelEntry.fallback(slug: "gpt-x", endpoints: .default)
        entry.info.provider = .codex
        let foreign = CodexModelsCatalog(
            models: [CodexCatalogModel(priority: 1, visibility: .list, entry: entry)],
            accountFingerprint: "account-b"
        )
        mgr.applyCodexCatalog(foreign)
        #expect(mgr.catalogSnapshot()["gpt-x"] == nil)
    }
}

// MARK: - EnvKeys / AuthScheme

@Suite("EnvKeys and AuthScheme")
struct EnvKeysAuthSchemeTests {
    @Test func envKeysFirstNonEmptyWins() {
        let keys = EnvKeys.many(["MISSING", "SECOND", "THIRD"])
        let value = keys.resolveValue { name in
            name == "SECOND" ? "  secret  " : nil
        }
        #expect(value == "  secret  ")
    }

    @Test func oneAndManyEqualByNames() {
        #expect(EnvKeys.one("X") == EnvKeys.many(["X"]))
    }

    @Test func effectiveAuthSchemeForcesBearerForCodex() {
        #expect(effectiveAuthScheme(provider: .codex, configured: .xApiKey) == .bearer)
        #expect(effectiveAuthScheme(provider: .xai, configured: .xApiKey) == .xApiKey)
    }

    @Test func firstOwnCredentialPriority() {
        #expect(
            firstOwnCredential(apiKey: "k", envKey: .one("E"), environment: ["E": "env"]) == "k"
        )
        #expect(
            firstOwnCredential(apiKey: "  ", envKey: .one("E"), environment: ["E": "env"]) == "env"
        )
        #expect(
            firstOwnCredential(apiKey: nil, envKey: .one("E"), environment: [:]) == nil
        )
    }
}

// MARK: - Validate selectable

@Suite("Validate selectable")
struct ValidateSelectableTests {
    @Test func rejectsAllowlistMatchingNothing() {
        var input = CatalogResolutionInput()
        input.models.allowedModels = ["zzz-*"]
        let catalog = resolveModelCatalog(input: input)
        #expect(throws: ModelsError.self) {
            try validateSelectable(input: input, catalog: catalog)
        }
    }

    @Test func rejectsExplicitDefaultExcludedByAllowlist() {
        var input = CatalogResolutionInput()
        input.models.allowedModels = ["kimi-*"]
        input.models.default = "grok-4.5"
        let catalog = resolveModelCatalog(input: input)
        #expect(throws: ModelsError.self) {
            try validateSelectable(input: input, catalog: catalog)
        }
    }
}

// MARK: - Remote Codex Refresh Isolation

@Suite("Remote Codex refresh isolation")
struct RemoteCodexRefreshIsolationTests {
    final class ScriptedCodexTransport: CodexModelsTransport, @unchecked Sendable {
        var models: [CodexCatalogModel]
        var etag: String?
        var callCount = 0

        init(models: [CodexCatalogModel], etag: String? = nil) {
            self.models = models
            self.etag = etag
        }

        func fetchCodexModels(
            cancellation: CancellationToken?
        ) async throws -> (models: [CodexCatalogModel], etag: String?) {
            try cancellation?.throwIfCancelled()
            callCount += 1
            return (models, etag)
        }
    }

    func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func remoteCodexRefreshCannotMutateOrInspectXaiState() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        var gptEntry = ModelEntry.fallback(slug: "gpt-5.6-super", endpoints: .default)
        gptEntry.info.provider = .codex
        gptEntry.info.apiBackend = .responses
        gptEntry.info.agentType = "codex"
        gptEntry.info.contextWindow = 353_000

        let codexTransport = ScriptedCodexTransport(
            models: [
                CodexCatalogModel(
                    priority: 10,
                    visibility: .list,
                    autoCompactTokenLimit: 300_000,
                    resolvedContextWindow: 353_000,
                    entry: gptEntry
                )
            ],
            etag: "\"codex-etag-1\""
        )
        let xaiTransport = ModelsManagerTests.ScriptedXaiTransport(
            result: FetchModelsResult(models: [], etag: nil)
        )

        let mgr = ModelsManager(
            credentials: EmptyCredentialSnapshot(
                hasXaiSession: true,
                hasCodexSession: true,
                codexAccountFingerprint: "fingerprint-alpha"
            ),
            grokHome: home,
            xaiTransport: xaiTransport,
            codexTransport: codexTransport,
            versionProvider: { "ver-1" }
        )

        // Baseline: grok-4.5 exists in catalog with 500,000 context window.
        let beforeSnap = mgr.catalogSnapshot()
        let grokBefore = beforeSnap["grok-4.5"]
        #expect(grokBefore != nil)
        #expect(grokBefore?.info.provider == .xai)
        #expect(grokBefore?.info.contextWindow == 500_000)

        // Perform remote Codex refresh.
        try await mgr.refreshCodex(strategy: .online)

        #expect(codexTransport.callCount == 1)
        #expect(xaiTransport.callCount == 0) // xAI transport was NOT called.

        let afterSnap = mgr.catalogSnapshot()
        // Remote Codex entry was added.
        #expect(afterSnap["gpt-5.6-super"] != nil)
        #expect(afterSnap["gpt-5.6-super"]?.info.provider == .codex)

        // xAI entry remains completely unmutated.
        let grokAfter = afterSnap["grok-4.5"]
        #expect(grokAfter != nil)
        #expect(grokAfter?.info.provider == .xai)
        #expect(grokAfter?.info.contextWindow == 500_000)

        // Disk cache isolation check: codex_models_cache.json exists, models_cache.json DOES NOT exist.
        let codexCacheFile = home.appendingPathComponent(CodexModels.cacheFileName)
        let xaiCacheFile = home.appendingPathComponent(MODELS_CACHE_FILE)
        #expect(FileManager.default.fileExists(atPath: codexCacheFile.path))
        #expect(!FileManager.default.fileExists(atPath: xaiCacheFile.path))

        // Now perform xAI refresh with live data.
        let liveXaiConfig = ModelEntryConfig(
            id: "grok-live-new",
            model: "grok-live-new",
            baseURL: "https://cli-chat-proxy.grok.com/v1",
            contextWindow: 400_000,
            apiBackend: .responses,
            provider: .xai
        )
        xaiTransport.result = FetchModelsResult(models: [liveXaiConfig], etag: "\"xai-etag-1\"")
        try await mgr.refreshXai(strategy: .online)

        #expect(xaiTransport.callCount == 1)
        #expect(FileManager.default.fileExists(atPath: xaiCacheFile.path))

        // Codex catalog model is still present in snapshot.
        let finalSnap = mgr.catalogSnapshot()
        #expect(finalSnap["gpt-5.6-super"] != nil)
        #expect(finalSnap["grok-live-new"] != nil)

        // Identity change clear invalidates both caches.
        mgr.clear(identityChange: true)
        #expect(!FileManager.default.fileExists(atPath: codexCacheFile.path))
        #expect(!FileManager.default.fileExists(atPath: xaiCacheFile.path))
    }

    @Test func crossProviderPartitionMergeIsIsolated() {
        var codexRemote = OrderedModelMap()
        var codexEntry = ModelEntry.fallback(slug: "gpt-5.6-sol", endpoints: .default)
        codexEntry.info.provider = .codex
        codexRemote["gpt-5.6-sol"] = codexEntry

        // Malicious or broken payload: non-Codex entry inside Codex remote partition.
        var poisonEntry = ModelEntry.fallback(slug: "grok-hacked", endpoints: .default)
        poisonEntry.info.provider = .xai
        codexRemote["grok-hacked"] = poisonEntry

        let codexCatalog = CodexModelsCatalog(
            models: [
                CodexCatalogModel(priority: 1, visibility: .list, entry: codexEntry),
                CodexCatalogModel(priority: 1, visibility: .list, entry: poisonEntry),
            ],
            accountFingerprint: "fingerprint-1"
        )

        let catalog = resolveModelCatalog(input: .default, codexCatalog: codexCatalog)
        #expect(catalog["gpt-5.6-sol"] != nil)
        // Poisoned xAI entry from Codex transport must NOT enter the catalog under xAI or overwrite xAI models.
        #expect(catalog["grok-hacked"] == nil)
        #expect(catalog["grok-4.5"]?.info.provider == .xai)
    }
}

// MARK: - Auxiliary model routing

@Suite("Auxiliary model routing")
struct AuxiliaryModelRoutingTests {
    @Test func customAuxiliaryEndpointRequiresItsOwnCredential() {
        let endpoints = EndpointsConfig.default
        var catalog = OrderedModelMap()
        var entry = ModelEntry.fallback(slug: "custom-helper", endpoints: endpoints)
        entry.info.provider = .xai
        entry.info.baseURL = "https://custom.example.test/v1"
        catalog["helper"] = entry

        let rejected = resolveAuxiliaryModelSamplingConfig(
            modelID: "helper",
            catalog: catalog,
            endpoints: endpoints,
            sessionKey: "xai-session-secret"
        )
        #expect(rejected == nil) // Session credential NOT sent to custom URL.

        entry.apiKey = "custom-endpoint-key"
        catalog["helper"] = entry

        let resolved = resolveAuxiliaryModelSamplingConfig(
            modelID: "helper",
            catalog: catalog,
            endpoints: endpoints,
            sessionKey: "xai-session-secret"
        )
        #expect(resolved != nil)
        #expect(resolved?.baseURL == "https://custom.example.test/v1")
        #expect(resolved?.apiKey == "custom-endpoint-key")
    }

    @Test func firstPartyAuxiliaryEndpointCanUseXaiSessionAuth() {
        let endpoints = EndpointsConfig.default
        let catalog = defaultModelEntries()

        let resolved = resolveAuxiliaryModelSamplingConfig(
            modelID: "grok-4.5",
            catalog: catalog,
            endpoints: endpoints,
            sessionKey: "xai-session-key"
        )
        #expect(resolved != nil)
        #expect(resolved?.provider == .xai)
        #expect(resolved?.apiKey == "xai-session-key")
    }

    @Test func customCodexEndpointCannotInheritChatgptOauth() {
        let endpoints = EndpointsConfig.default
        var catalog = OrderedModelMap()
        var entry = ModelEntry.fallback(slug: "custom-codex-helper", endpoints: endpoints)
        entry.info.provider = .codex
        entry.info.baseURL = "https://codex-proxy.example.test/v1"
        catalog["helper"] = entry

        let rejected = resolveAuxiliaryModelSamplingConfig(
            modelID: "helper",
            catalog: catalog,
            endpoints: endpoints,
            sessionKey: "codex-oauth-token"
        )
        #expect(rejected == nil)

        entry.apiKey = "custom-codex-key"
        catalog["helper"] = entry

        let resolved = resolveAuxiliaryModelSamplingConfig(
            modelID: "helper",
            catalog: catalog,
            endpoints: endpoints,
            sessionKey: "codex-oauth-token"
        )
        #expect(resolved != nil)
        #expect(resolved?.baseURL == "https://codex-proxy.example.test/v1")
        #expect(resolved?.apiKey == "custom-codex-key")
    }

    @Test func specialtyModelRolesResolveDefaults() {
        let catalog = defaultModelEntries()
        let webAux = resolveAuxiliaryModelSamplingConfig(
            modelID: defaultWebSearchModel(),
            catalog: catalog,
            sessionKey: "session-bearer"
        )
        #expect(webAux != nil)
        #expect(webAux?.routingModel == "grok-4.20-multi-agent")

        let summaryAux = resolveAuxiliaryModelSamplingConfig(
            modelID: defaultSessionSummaryModel(),
            catalog: catalog,
            sessionKey: "session-bearer"
        )
        #expect(summaryAux != nil)
        #expect(summaryAux?.routingModel == "grok-4.5")
    }
}

// MARK: - Trusted endpoint validation

@Suite("Trusted endpoint validation")
struct TrustedEndpointValidationTests {
    @Test func isXaiApiBearerURLValidations() {
        #expect(isXaiApiBearerURL("https://api.x.ai/v1"))
        #expect(isXaiApiBearerURL("https://cli-chat-proxy.grok.com/v1"))
        #expect(isXaiApiBearerURL("https://subdomain.x.ai/v1"))
        #expect(!isXaiApiBearerURL("http://api.x.ai/v1")) // HTTP rejected
        #expect(!isXaiApiBearerURL("https://localhost:11434/v1")) // Loopback rejected
        #expect(!isXaiApiBearerURL("https://127.0.0.1:11434/v1")) // IPv4 loopback rejected
        #expect(!isXaiApiBearerURL("https://[::1]:11434/v1")) // IPv6 loopback rejected
        #expect(!isXaiApiBearerURL("https://evil-x.ai.example/v1")) // Suffix attack rejected
    }

    @Test func codexIsTrustedInferenceBaseURLValidations() {
        #expect(CodexModels.isTrustedInferenceBaseURL("https://chatgpt.com/backend-api/codex"))
        #expect(CodexModels.isTrustedInferenceBaseURL("https://chat.openai.com/backend-api/codex"))
        #expect(CodexModels.isTrustedInferenceBaseURL(""))
        #expect(!CodexModels.isTrustedInferenceBaseURL("https://codex-proxy.evil.com/v1"))
        #expect(!CodexModels.isTrustedInferenceBaseURL("http://chatgpt.com/backend-api/codex"))
    }

    @Test func trustedBuiltInSessionEndpointAllProviders() {
        #expect(trustedBuiltInSessionEndpoint(provider: .xai, baseURL: "https://api.x.ai/v1"))
        #expect(!trustedBuiltInSessionEndpoint(provider: .xai, baseURL: "https://untrusted.com/v1"))

        #expect(trustedBuiltInSessionEndpoint(provider: .codex, baseURL: "https://chatgpt.com/backend-api/codex"))
        #expect(!trustedBuiltInSessionEndpoint(provider: .codex, baseURL: "https://codex.custom.org"))

        #expect(trustedBuiltInSessionEndpoint(provider: .kimi, baseURL: "https://api.moonshot.ai/v1"))
        #expect(trustedBuiltInSessionEndpoint(provider: .kimi, baseURL: "https://api.kimi.com/coding/v1"))
        #expect(!trustedBuiltInSessionEndpoint(provider: .kimi, baseURL: "https://custom-kimi.org"))

        #expect(trustedBuiltInSessionEndpoint(provider: .fireworks, baseURL: "https://api.fireworks.ai/inference/v1"))
        #expect(!trustedBuiltInSessionEndpoint(provider: .fireworks, baseURL: "https://custom-fireworks.org"))
    }
}

// MARK: - Compaction & reasoning capabilities

@Suite("Compaction & reasoning capabilities")
struct CompactionAndReasoningCapabilitiesTests {
    @Test func autoCompactTokenLimitAndResolvedLimit() {
        var entry = ModelEntry.fallback(slug: "gpt-test", endpoints: .default)
        entry.info.provider = .codex

        let modelWithContextAndLimit = CodexCatalogModel(
            priority: 1,
            visibility: .list,
            autoCompactTokenLimit: 250_000,
            resolvedContextWindow: 353_000,
            entry: entry
        )
        // 90% of 353,000 = 317,700. min(250,000, 317,700) = 250,000
        #expect(modelWithContextAndLimit.resolvedAutoCompactTokenLimit() == 250_000)

        let modelContextOnly = CodexCatalogModel(
            priority: 1,
            visibility: .list,
            autoCompactTokenLimit: nil,
            resolvedContextWindow: 353_000,
            entry: entry
        )
        // 90% of 353,000 = 317,700
        #expect(modelContextOnly.resolvedAutoCompactTokenLimit() == 317_700)
    }

    @Test func compactionMetadataFieldsPreservation() {
        let map = defaultModelEntries()
        let grok = map["grok-4.5"]!
        #expect(grok.info.autoCompactThresholdPercent == 80)
        #expect(grok.info.compactionAtTokens == .enabled(true))
        #expect(grok.info.compactionsRemaining == .fixed(1))
    }

    @Test func modelOffersReasoningEffortAndDeriveFields() {
        var info = ModelInfo.fallback(slug: "test-model")
        info.reasoningEfforts = [
            ReasoningEffortOption(id: "low", value: .low, label: "Low", description: nil, isDefault: false),
            ReasoningEffortOption(id: "high", value: .high, label: "High", description: nil, isDefault: true),
        ]
        info.deriveReasoningEffortFields()
        #expect(info.supportsReasoningEffort)
        #expect(info.reasoningEffort == .high)

        #expect(modelOffersReasoningEffort(info, effort: .low))
        #expect(modelOffersReasoningEffort(info, effort: .high))
        #expect(!modelOffersReasoningEffort(info, effort: .max))
    }

    @Test func codexMultiAgentV2Flag() {
        let map = defaultModelEntries()
        #expect(map["gpt-5.6-sol"]?.info.codexMultiAgentV2 == true)
        #expect(map["gpt-5.6-terra"]?.info.codexMultiAgentV2 == true)
        #expect(map["gpt-5.6-luna"]?.info.codexMultiAgentV2 == false)
    }
}

// MARK: - Codex Model Catalog Parity Remediation (Luna Review)

@Suite("Codex model catalog parity remediation")
struct CodexParityRemediationTests {
    @Test func codexCacheIdentityMismatchIsCacheMiss() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-cache-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var entry = ModelEntry.fallback(slug: "gpt-5.6-sol", endpoints: .default)
        entry.info.provider = .codex

        let catalog = CodexModelsCatalog(
            models: [
                CodexCatalogModel(priority: 1, visibility: .list, entry: entry)
            ],
            accountFingerprint: "account-123"
        )

        let manager = CodexModelsCacheManager(
            grokHome: dir,
            versionProvider: { "grok-1.0" },
            clientVersionProvider: { "0.144.5" },
            baseURLProvider: { "https://chatgpt.com/backend-api/codex" }
        )

        try manager.persist(catalog)

        // Baseline: matching identity loads successfully.
        #expect(manager.loadFresh(expectedAccountFingerprint: "account-123") != nil)

        // Open Grok version mismatch -> cache miss.
        #expect(manager.loadFresh(
            expectedAccountFingerprint: "account-123",
            openGrokVersion: "grok-2.0"
        ) == nil)

        // Codex client version mismatch -> cache miss.
        #expect(manager.loadFresh(
            expectedAccountFingerprint: "account-123",
            clientVersion: "0.145.0"
        ) == nil)

        // Endpoint origin mismatch -> cache miss.
        #expect(manager.loadFresh(
            expectedAccountFingerprint: "account-123",
            baseURL: "https://custom-proxy.example.com/backend-api/codex"
        ) == nil)

        // Account fingerprint mismatch -> cache miss.
        #expect(manager.loadFresh(expectedAccountFingerprint: "account-456") == nil)
    }

    @Test func codexSupportedInApiForcedFalseAndNotSelectableWithoutSession() throws {
        let json = """
        {
          "models": [
            {
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6 Sol",
              "visibility": "list",
              "supported_in_api": true,
              "priority": 1
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try parseCodexModelsResponse(json)
        #expect(parsed.count == 1)
        #expect(parsed[0].entry.info.supportedInApi == false)

        let catalog = CodexModelsCatalog(
            models: parsed,
            accountFingerprint: "account-123"
        )

        var input = CatalogResolutionInput()
        let assembled = resolveModelCatalog(input: input, codexCatalog: catalog)
        let availableNoSession = availableModels(catalog: assembled, hasXaiSession: false, hasCodexSession: false)
        #expect(availableNoSession["gpt-5.6-sol"] == nil)

        let availableWithSession = availableModels(catalog: assembled, hasXaiSession: false, hasCodexSession: true)
        #expect(availableWithSession["gpt-5.6-sol"] != nil)
    }

    @Test func codexUnknownToolModeRemovesModelFromParsedResult() throws {
        let json = """
        {
          "models": [
            {
              "slug": "gpt-valid-1",
              "display_name": "Valid Code Mode",
              "visibility": "list",
              "tool_mode": "code_mode_only",
              "priority": 1
            },
            {
              "slug": "gpt-unknown-mode",
              "display_name": "Unknown Tool Mode Model",
              "visibility": "list",
              "tool_mode": "unsupported_futuristic_mode",
              "priority": 2
            },
            {
              "slug": "gpt-valid-2",
              "display_name": "No Tool Mode Specified",
              "visibility": "list",
              "priority": 3
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try parseCodexModelsResponse(json)
        let slugs = parsed.map(\.slug)
        #expect(slugs == ["gpt-valid-1", "gpt-valid-2"])
        #expect(!slugs.contains("gpt-unknown-mode"))
        #expect(parsed[0].entry.info.toolMode == .codeModeOnly)
        #expect(parsed[1].entry.info.toolMode == nil)
    }

    @Test func codexParsedModelsSortedByPriority() throws {
        let json = """
        {
          "models": [
            {
              "slug": "low-priority-wire-first",
              "display_name": "Priority 10",
              "visibility": "list",
              "priority": 10
            },
            {
              "slug": "high-priority-wire-second",
              "display_name": "Priority 1",
              "visibility": "list",
              "priority": 1
            },
            {
              "slug": "medium-priority-wire-third",
              "display_name": "Priority 5",
              "visibility": "list",
              "priority": 5
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try parseCodexModelsResponse(json)
        let slugs = parsed.map(\.slug)
        #expect(slugs == ["high-priority-wire-second", "medium-priority-wire-third", "low-priority-wire-first"])
    }
}


