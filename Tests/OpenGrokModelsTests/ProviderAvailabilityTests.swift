// ProviderAvailabilityTests.swift
//
// Golden fixtures for the model-catalog resolution semantics at pin 80dff0a9.
//
// Provenance:
//   * `model_available_for_provider_auth` —
//     `crates/codegen/xai-grok-shell/src/agent/models/resolution.rs:228-250`
//   * `selectable_catalog_key_for_persisted` — resolution.rs:36-51
//   * `is_code_model_slug` —
//     `crates/codegen/xai-grok-shell/src/kimi_models.rs:130`
//   * embedded Kimi Code catalog —
//     `crates/codegen/xai-grok-models/default_models.json` and the assertions
//     in `agent/config.rs:13933-13964`

import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokSamplingTypes

private func entry(
    key: String,
    model: String? = nil,
    provider: ModelProvider,
    apiKey: String? = nil,
    envKey: EnvKeys? = nil,
    userSelectable: Bool = true,
    hidden: Bool = false,
    supportedInApi: Bool = true
) -> ModelEntry {
    var info = ModelInfo(id: key, model: model ?? key, name: key, provider: provider)
    info.userSelectable = userSelectable
    info.hidden = hidden
    info.supportedInApi = supportedInApi
    var e = ModelEntry(info: info)
    e.apiKey = apiKey
    e.envKey = envKey
    return e
}

@Suite("Provider availability")
struct ProviderAvailabilityTests {
    /// resolution.rs:241-246. An API-key-only provider with no resolvable key
    /// must be treated as unavailable, so it never reaches the picker. Bare
    /// `visibleForProviderAuth` returns true here, which is why availability
    /// is a separate, stricter predicate.
    @Test("an API-key-only provider without a key is unavailable but still picker-visible")
    func apiKeyOnlyWithoutKey() {
        let e = entry(key: "k3", provider: .kimi, envKey: .single("KIMI_CODE_API_KEY"))
        #expect(e.info.visibleForProviderAuth(hasXaiSession: true, hasCodexSession: true))
        #expect(!modelAvailableForProviderAuth(
            e, hasXaiSession: true, hasCodexSession: true,
            resolvedAPIKey: { modelEntryAPIKeyFromEnvironment($0, environment: [:]) }
        ))
    }

    @Test("an API-key-only provider with a model-owned or env key is available")
    func apiKeyOnlyWithKey() {
        let owned = entry(key: "k3", provider: .kimi, apiKey: "sk-live")
        #expect(modelAvailableForProviderAuth(
            owned, hasXaiSession: false, hasCodexSession: false,
            resolvedAPIKey: { modelEntryAPIKeyFromEnvironment($0, environment: [:]) }
        ))

        let fromEnv = entry(key: "k3", provider: .kimi, envKey: .single("KIMI_CODE_API_KEY"))
        #expect(modelAvailableForProviderAuth(
            fromEnv, hasXaiSession: false, hasCodexSession: false,
            resolvedAPIKey: {
                modelEntryAPIKeyFromEnvironment($0, environment: ["KIMI_CODE_API_KEY": "sk-env"])
            }
        ))
    }

    /// A blank key is not a key: resolution.rs:244 requires `!key.trim().is_empty()`.
    /// An exported-but-empty variable is a common way to end up here.
    @Test("a whitespace-only key does not make a provider available")
    func whitespaceKeyIsNotAKey() {
        let e = entry(key: "k3", provider: .kimi, envKey: .single("KIMI_CODE_API_KEY"))
        #expect(!modelAvailableForProviderAuth(
            e, hasXaiSession: false, hasCodexSession: false,
            resolvedAPIKey: {
                modelEntryAPIKeyFromEnvironment($0, environment: ["KIMI_CODE_API_KEY": "   "])
            }
        ))
    }

    /// resolution.rs:247-249: OAuth-backed providers are governed by their
    /// isolated login state and are not subjected to a key check.
    @Test("OAuth-backed providers need no API key")
    func oauthProvidersNeedNoKey() {
        let xai = entry(key: "grok-4.5", provider: .xai, supportedInApi: false)
        #expect(modelAvailableForProviderAuth(
            xai, hasXaiSession: true, hasCodexSession: false,
            resolvedAPIKey: { _ in nil }
        ))
        // But one provider's session must not unlock another's models.
        #expect(!modelAvailableForProviderAuth(
            xai, hasXaiSession: false, hasCodexSession: true,
            resolvedAPIKey: { _ in nil }
        ))
    }

    /// A hidden entry is unavailable regardless of credentials
    /// (`visible_for_provider_auth` gates on `!hidden` first).
    @Test("a hidden model is never available")
    func hiddenIsNeverAvailable() {
        let e = entry(key: "internal", provider: .kimi, apiKey: "sk-live", hidden: true)
        #expect(!modelAvailableForProviderAuth(
            e, hasXaiSession: true, hasCodexSession: true, resolvedAPIKey: { _ in "sk-live" }
        ))
    }

    @Test("availableModelsForProviderAuth drops unconfigured providers from the catalog")
    func catalogFiltering() {
        var catalog = OrderedModelMap()
        catalog["grok-4.5"] = entry(key: "grok-4.5", provider: .xai, supportedInApi: false)
        catalog["k3"] = entry(key: "k3", provider: .kimi, envKey: .single("KIMI_CODE_API_KEY"))
        catalog["k3-256k"] = entry(key: "k3-256k", provider: .kimi, apiKey: "sk-live")

        let available = availableModelsForProviderAuth(
            catalog: catalog, hasXaiSession: true, hasCodexSession: false,
            resolvedAPIKey: { modelEntryAPIKeyFromEnvironment($0, environment: [:]) }
        )
        #expect(available.keys == ["grok-4.5", "k3-256k"])
    }
}

@Suite("Persisted model key resolution")
struct PersistedModelKeyTests {
    private func fixture() -> (models: OrderedModelMap, available: OrderedModelMap) {
        var models = OrderedModelMap()
        // A non-selectable entry whose *catalog key* is the slug we will look
        // up, plus a later selectable entry whose *routing slug* matches. The
        // ordering matters: the selectable slug match must win.
        models["shadow"] = entry(key: "shadow", model: "kimi-for-coding", provider: .kimi,
                                 userSelectable: false)
        models["kimi-for-coding"] = entry(key: "kimi-for-coding", provider: .kimi,
                                          userSelectable: false)
        models["user-kimi"] = entry(key: "user-kimi", model: "kimi-for-coding", provider: .kimi)
        models["grok-4.5"] = entry(key: "grok-4.5", provider: .xai)

        var available = OrderedModelMap()
        available["user-kimi"] = models["user-kimi"]
        available["grok-4.5"] = models["grok-4.5"]
        return (models, available)
    }

    /// resolution.rs:41-43: an available exact key short-circuits everything.
    @Test("an available exact catalog key wins immediately")
    func exactKeyWins() {
        let (models, available) = fixture()
        #expect(selectableCatalogKeyForPersisted(
            models: models, available: available, modelID: "grok-4.5") == "grok-4.5")
    }

    /// resolution.rs:44-49: the **last** available slug match wins, so a
    /// bundled default cannot shadow a user override that shares the slug,
    /// and a non-selectable exact-key entry cannot shadow a selectable slug
    /// match either.
    @Test("the last available slug match wins over a non-selectable exact key")
    func lastSlugMatchWins() {
        let (models, available) = fixture()
        #expect(selectableCatalogKeyForPersisted(
            models: models, available: available, modelID: "kimi-for-coding") == "user-kimi")
    }

    @Test("an id with no available match resolves to nil")
    func noMatch() {
        let (models, available) = fixture()
        #expect(selectableCatalogKeyForPersisted(
            models: models, available: available, modelID: "gone-from-catalog") == nil)
    }
}

@Suite("Current-model repair")
struct CurrentModelRepairTests {
    private func catalogs() -> (models: OrderedModelMap, available: OrderedModelMap) {
        var models = OrderedModelMap()
        models["grok-4.5"] = entry(key: "grok-4.5", provider: .xai)
        models["k3"] = entry(key: "k3", provider: .kimi)
        var available = OrderedModelMap()
        available["grok-4.5"] = models["grok-4.5"]
        return (models, available)
    }

    @Test("a live persisted model resolves to its catalog key")
    func liveModelResolves() {
        let (models, available) = catalogs()
        #expect(repairCurrentModel(
            persistedID: "grok-4.5", models: models, available: available,
            fallbackKey: "grok-4.5") == .resolved(key: "grok-4.5"))
    }

    /// The case the repair exists for: a persisted id that the catalog no
    /// longer offers — dropped by a refresh, removed by a `disabled_models`
    /// edit, or made unavailable by a cleared provider credential. Leaving
    /// the dangling id persisted means the next turn fails at request time.
    @Test("a stale or provider-deconfigured model is repointed at the default")
    func staleModelIsRepaired() {
        let (models, available) = catalogs()
        // `k3` is still in the catalog but its provider has no credential.
        #expect(repairCurrentModel(
            persistedID: "k3", models: models, available: available,
            fallbackKey: "grok-4.5") == .repaired(from: "k3", key: "grok-4.5"))
        // `removed-model` is gone from the catalog entirely.
        #expect(repairCurrentModel(
            persistedID: "removed-model", models: models, available: available,
            fallbackKey: "grok-4.5") == .repaired(from: "removed-model", key: "grok-4.5"))
    }

    /// With nothing available the caller must fall back to the bundled
    /// default rather than persist a dangling id.
    @Test("no available fallback reports unavailable rather than inventing a key")
    func noFallback() {
        let (models, _) = catalogs()
        #expect(repairCurrentModel(
            persistedID: "k3", models: models, available: OrderedModelMap(),
            fallbackKey: "grok-4.5") == .unavailable(from: "k3"))
        #expect(repairCurrentModel(
            persistedID: "k3", models: models, available: OrderedModelMap(),
            fallbackKey: nil) == .unavailable(from: "k3"))
    }
}

@Suite("Kimi Code catalog at pin 80dff0a9")
struct KimiCodeCatalogTests {
    /// `is_code_model_slug`, kimi_models.rs:130. The `kimi-k3` exclusion is
    /// the load-bearing case: it is the **Platform** model on Moonshot, and
    /// misclassifying it would route Platform traffic at the Code endpoint
    /// with the wrong credential.
    @Test("Code slugs are classified without capturing the Platform model")
    func codeSlugClassifier() {
        #expect(KimiModels.isCodeModelSlug("k3"))
        #expect(KimiModels.isCodeModelSlug("k3-256k"))
        #expect(KimiModels.isCodeModelSlug("kimi-for-coding"))
        #expect(KimiModels.isCodeModelSlug("kimi-for-coding-highspeed"))
        #expect(!KimiModels.isCodeModelSlug("kimi-k3"))
        #expect(!KimiModels.isCodeModelSlug("grok-4.5"))
    }

    /// Provenance: `embedded_kimi_code_catalog_is_selected_as_one_isolated_partition`,
    /// agent/config.rs:13933-13964, plus the JSON bodies at
    /// `xai-grok-models/default_models.json:56-89`. `k3` and `k3-256k` are
    /// the entries added at this pin.
    @Test("k3 and k3-256k are in the embedded catalog with their Rust values")
    func embeddedK3Entries() throws {
        let code = defaultModelEntries(kimiEndpoint: .code)
        for (slug, contextWindow) in [
            ("k3", UInt64(1_048_576)),
            ("k3-256k", UInt64(262_144)),
            ("kimi-for-coding", UInt64(262_144)),
            ("kimi-for-coding-highspeed", UInt64(262_144)),
        ] {
            let e = try #require(code[slug], "embedded Kimi Code model \(slug)")
            #expect(e.info.provider == .kimi)
            #expect(e.info.apiBackend == .chatCompletions)
            #expect(e.info.baseURL == KimiModels.codeAPIBaseURL)
            #expect(e.info.contextWindow == contextWindow)
            #expect(e.info.toolMode == .direct)
            #expect(e.envKey?.primary == KimiModels.codeAPIKeyEnv)
        }
    }

    /// config.rs:13959-13963: K3 offers three reasoning levels defaulting to
    /// high, unlike the Platform `kimi-k3` entry which offers only `max`.
    @Test("k3 offers three reasoning levels defaulting to high")
    func k3ReasoningEfforts() throws {
        let code = defaultModelEntries(kimiEndpoint: .code)
        let k3 = try #require(code["k3"])
        #expect(k3.info.supportsReasoningEffort)
        #expect(k3.info.reasoningEffort == .high)
        #expect(k3.info.reasoningEfforts.count == 3)

        let platform = try #require(defaultModelEntries(kimiEndpoint: .platform)["kimi-k3"])
        #expect(platform.info.baseURL == KimiModels.platformAPIBaseURL)
        #expect(platform.info.reasoningEfforts.count == 1)
        #expect(platform.envKey?.primary == KimiModels.platformAPIKeyEnv)
    }
}

@Suite("Kimi service-partitioned default selection")
struct KimiServiceDefaultSelectionTests {
    /// The two Kimi services must never leak into each other's catalog: they
    /// have separate endpoints and separate credential scopes
    /// (`kimi::api_key` vs `kimi_code::api_key`). Partition filter:
    /// `agent/config.rs:4163-4170`.
    @Test("each Kimi endpoint sees only its own service's models")
    func partitionsAreDisjoint() {
        let platform = embeddedModels(forProvider: .kimi, kimiEndpoint: .platform, environment: [:])
            .map(\.model)
        let code = embeddedModels(forProvider: .kimi, kimiEndpoint: .code, environment: [:])
            .map(\.model)

        #expect(platform == ["kimi-k3"])
        #expect(code == ["k3", "k3-256k", "kimi-for-coding", "kimi-for-coding-highspeed"])
        #expect(Set(platform).intersection(Set(code)).isEmpty)
    }

    /// With no user preference upstream falls back to the first entry in
    /// catalog order within the selected partition
    /// (`resolve_default_model_with_provider_auth`, resolution.rs:116-142).
    /// Upstream lists `k3` first in the Code partition, so `k3` — not the
    /// older `kimi-for-coding` — is that service's default.
    @Test("each Kimi service defaults to its own first catalog entry")
    func perServiceDefault() throws {
        let platform = try #require(
            defaultEmbeddedModel(forProvider: .kimi, kimiEndpoint: .platform, environment: [:]))
        #expect(platform.model == "kimi-k3")
        #expect(platform.baseURL == KimiModels.platformAPIBaseURL)

        let code = try #require(
            defaultEmbeddedModel(forProvider: .kimi, kimiEndpoint: .code, environment: [:]))
        #expect(code.model == "k3")
        #expect(code.baseURL == KimiModels.codeAPIBaseURL)
    }

    /// `OPENGROK_KIMI_API_BASE_URL` selects the service, so a coding base URL
    /// must move selection to the Code partition even when the configured
    /// endpoint is Platform. Without this, a Code-only credential gets paired
    /// with the Platform model.
    @Test("the base-URL override picks the service, overriding the configured endpoint")
    func envOverrideSelectsService() throws {
        let env = ["OPENGROK_KIMI_API_BASE_URL": "https://api.kimi.com/coding/v1"]
        let selected = try #require(
            defaultEmbeddedModel(forProvider: .kimi, kimiEndpoint: .platform, environment: env))
        #expect(selected.model == "k3")
    }

    /// Non-Kimi providers have no partition, and xAI keeps resolving to the
    /// globally bundled default rather than merely the first xAI entry.
    @Test("xAI resolves the bundled default; other providers take their first entry")
    func otherProviders() throws {
        let xai = try #require(defaultEmbeddedModel(forProvider: .xai, environment: [:]))
        #expect(xai.model == defaultModel())

        let fireworks = try #require(defaultEmbeddedModel(forProvider: .fireworks, environment: [:]))
        #expect(fireworks.provider == .fireworks)
    }
}
