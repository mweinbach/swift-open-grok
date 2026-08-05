// ProviderCatalogDriftTests.swift
//
// Provider-isolated catalog coverage for the three providers added upstream:
// DeepSeek direct (fb929feb, 3f83f287), OpenCode Go (1e2af500), Wafer AI
// (9b2742fd). Derived from the Rust `deepseek_models.rs`, `opencode_go_models.rs`,
// and `wafer_models.rs` suites.

import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokSamplingTypes

@Suite("DeepSeek catalog")
struct DeepSeekCatalogTests {
    /// Provenance: Rust `trusted_hosts_are_provider_scoped`.
    @Test("only DeepSeek-owned https hosts are trusted")
    func trustedHosts() {
        #expect(DeepSeekModels.isTrustedAPIBaseURL(DeepSeekModels.apiBaseURLDefault))
        #expect(DeepSeekModels.isTrustedAPIBaseURL("https://api.deepseek.com/v1/models"))
        #expect(!DeepSeekModels.isTrustedAPIBaseURL("http://api.deepseek.com"))
        #expect(!DeepSeekModels.isTrustedAPIBaseURL("https://api.deepseek.com.example"))
        #expect(!DeepSeekModels.isTrustedAPIBaseURL("https://api.x.ai/v1"))
        #expect(!DeepSeekModels.isTrustedAPIBaseURL("not a url"))
    }

    /// Provenance: Rust `stored_keys_never_leave_owned_hosts`. A stored
    /// provider key must not follow a redirected base URL to a foreign host.
    @Test("a stored key never leaves DeepSeek-owned hosts")
    func storedKeyIsolation() {
        #expect(
            DeepSeekModels.selectAPIKey(
                baseURL: DeepSeekModels.apiBaseURLDefault,
                environmentKey: nil,
                storedKey: "deepseek-stored-secret"
            ) == "deepseek-stored-secret"
        )
        #expect(
            DeepSeekModels.selectAPIKey(
                baseURL: "https://evil.example/v1",
                environmentKey: nil,
                storedKey: "deepseek-stored-secret"
            ) == nil
        )
        // An environment key is the user's explicit per-invocation choice.
        #expect(
            DeepSeekModels.selectAPIKey(
                baseURL: "https://evil.example/v1",
                environmentKey: "env-key",
                storedKey: "deepseek-stored-secret"
            ) == "env-key"
        )
    }

    @Test("base URL resolves from the environment override, trimmed")
    func baseURLOverride() {
        #expect(DeepSeekModels.apiBaseURL(environment: [:]) == "https://api.deepseek.com")
        #expect(
            DeepSeekModels.apiBaseURL(
                environment: [DeepSeekModels.apiBaseURLEnv: "  https://proxy.example/v1/  "]
            ) == "https://proxy.example/v1"
        )
        #expect(
            DeepSeekModels.apiBaseURL(environment: [DeepSeekModels.apiBaseURLEnv: "   "])
                == "https://api.deepseek.com"
        )
    }

    /// The routing decision the V4 Flash commits make: Pro stays on Chat
    /// Completions, Flash goes to the DeepSeek Responses dialect.
    @Test("V4 Flash routes to Responses while V4 Pro stays on Chat Completions")
    func perModelProtocolRouting() throws {
        let catalog = DeepSeekModels.curatedCatalog(baseURL: "https://api.deepseek.com")

        let pro = try #require(catalog["deepseek:deepseek-v4-pro"])
        #expect(pro.info.provider == .deepseek)
        #expect(pro.info.apiBackend == .chatCompletions)
        #expect(!pro.info.supportsBackendSearch)
        #expect(pro.info.model == "deepseek-v4-pro")

        let flash = try #require(catalog["deepseek:deepseek-v4-flash"])
        #expect(flash.info.provider == .deepseek)
        #expect(flash.info.apiBackend == .responses)
        #expect(flash.info.supportsBackendSearch, "Flash carries hosted web search")
        #expect(flash.info.model == "deepseek-v4-flash")

        // Both entries authenticate from the provider's own env key.
        for entry in [pro, flash] {
            #expect(entry.envKey == .single(DeepSeekModels.apiKeyEnv))
            #expect(entry.apiKey == nil)
            #expect(entry.info.toolMode == .direct)
            #expect(entry.info.contextWindow == 1_000_000)
            #expect(entry.info.maxCompletionTokens == 384_000)
        }
    }

    @Test("the reasoning menu is DeepSeek's documented low/high/max with high default")
    func reasoningMenu() throws {
        let efforts = DeepSeekModels.reasoningEfforts
        #expect(efforts.map(\.value) == [.low, .high, .max])
        let defaults = efforts.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(defaults.first?.value == .high)

        let entry = try #require(
            DeepSeekModels.curatedCatalog()["deepseek:deepseek-v4-pro"]
        )
        #expect(entry.info.supportsReasoningEffort)
        #expect(entry.info.reasoningEffort == .high)
    }

    /// Unknown future ids fail closed until their limits are reviewed.
    @Test("/models restricts to the curated partition in both directions")
    func remoteRestriction() throws {
        let body = Data(#"""
        {"data":[
          {"id":"deepseek-v4-pro"},
          {"id":"deepseek-v9-unreleased"},
          {"id":"  "}
        ]}
        """#.utf8)
        let slugs = try DeepSeekModels.parseAvailableSlugs(body)
        #expect(slugs == ["deepseek-v4-pro"])

        #expect(throws: ModelsError.self) {
            _ = try DeepSeekModels.parseAvailableSlugs(Data(#"{"models":[]}"#.utf8))
        }
    }
}

@Suite("Wafer catalog")
struct WaferCatalogTests {
    /// Provenance: Rust `trusted_hosts_are_provider_scoped`.
    @Test("only Wafer-owned https hosts are trusted")
    func trustedHosts() {
        #expect(WaferModels.isTrustedAPIBaseURL(WaferModels.apiBaseURLDefault))
        #expect(WaferModels.isTrustedAPIBaseURL("https://pass.wafer.ai/v1/models"))
        #expect(!WaferModels.isTrustedAPIBaseURL("http://pass.wafer.ai/v1"))
        #expect(!WaferModels.isTrustedAPIBaseURL("https://pass.wafer.ai.example/v1"))
        #expect(!WaferModels.isTrustedAPIBaseURL("https://api.x.ai/v1"))
    }

    @Test("a stored key never leaves Wafer-owned hosts")
    func storedKeyIsolation() {
        #expect(
            WaferModels.selectAPIKey(
                baseURL: WaferModels.apiBaseURLDefault,
                environmentKey: nil,
                storedKey: "wafer-stored-secret"
            ) == "wafer-stored-secret"
        )
        #expect(
            WaferModels.selectAPIKey(
                baseURL: "https://elsewhere.example/v1",
                environmentKey: nil,
                storedKey: "wafer-stored-secret"
            ) == nil
        )
    }

    /// Wafer's `/models` is authoritative: the catalog is exactly what the
    /// provider returned, never a static list.
    @Test("the dynamic catalog is built only from the provider's response")
    func dynamicCatalog() throws {
        let body = Data(#"""
        {"data":[{"id":"wafer-large"},{"id":"wafer-small"},{"id":"   "}]}
        """#.utf8)
        let catalog = try WaferModels.parseCatalog(body, baseURL: "https://pass.wafer.ai/v1")
        #expect(catalog.count == 2)

        let entry = try #require(catalog["wafer:wafer-large"])
        #expect(entry.info.provider == .wafer)
        #expect(entry.info.model == "wafer-large")
        #expect(entry.info.name == "wafer-large")
        #expect(entry.info.apiBackend == .chatCompletions)
        #expect(entry.info.toolMode == .direct)
        #expect(!entry.info.supportsReasoningEffort)
        #expect(!entry.info.supportsBackendSearch)
        #expect(entry.envKey == .single(WaferModels.apiKeyEnv))
        #expect(entry.info.baseURL == "https://pass.wafer.ai/v1")

        // An absent `data` array is an empty catalog, not a hard failure.
        let empty = try WaferModels.parseCatalog(Data("{}".utf8), baseURL: "https://pass.wafer.ai/v1")
        #expect(empty.isEmpty)
    }

    /// Catalog cache isolation: a snapshot may only be reused under the
    /// credential that produced it.
    @Test("a cached catalog is scoped to its credential fingerprint")
    func catalogCacheIsolation() {
        let catalog = WaferModelsCatalog(
            entries: OrderedModelMap(),
            credentialFingerprint: "fingerprint-a"
        )
        #expect(catalog.matchesCredential(fingerprint: "fingerprint-a"))
        #expect(!catalog.matchesCredential(fingerprint: "fingerprint-b"))
        // Wafer's remote response is always authoritative for its partition,
        // so an empty snapshot means "no models", not "fall back".
        #expect(catalog.isAuthoritative)
    }

    @Test("error bodies are redacted and truncated before surfacing")
    func errorRedaction() {
        let excerpt = WaferModels.safeErrorExcerpt(
            "bad key\nwafer-secret rejected",
            apiKey: "wafer-secret"
        )
        #expect(!excerpt.contains("wafer-secret"))
        #expect(excerpt.contains("[REDACTED]"))
        #expect(!excerpt.contains("\n"))

        let long = WaferModels.safeErrorExcerpt(String(repeating: "x", count: 900), apiKey: "k")
        #expect(long.count == 512)
    }
}

@Suite("OpenCode Go catalog")
struct OpenCodeGoCatalogTests {
    @Test("only OpenCode-owned https hosts are trusted")
    func trustedHosts() {
        #expect(OpenCodeGoModels.isTrustedAPIBaseURL(OpenCodeGoModels.apiBaseURLDefault))
        #expect(!OpenCodeGoModels.isTrustedAPIBaseURL("http://opencode.ai/zen/go/v1"))
        #expect(!OpenCodeGoModels.isTrustedAPIBaseURL("https://opencode.ai.example/v1"))
    }

    /// Provenance: Rust `protocol_metadata_maps_per_model`.
    @Test("models.dev SDK metadata selects the wire protocol")
    func protocolMapping() {
        #expect(OpenCodeGoModels.protocolForSDK("@ai-sdk/anthropic")?.0 == .messages)
        #expect(OpenCodeGoModels.protocolForSDK("@ai-sdk/anthropic")?.1 == .xApiKey)
        #expect(OpenCodeGoModels.protocolForSDK("@ai-sdk/openai-compatible")?.0 == .chatCompletions)
        #expect(OpenCodeGoModels.protocolForSDK("@ai-sdk/openai-compatible")?.1 == .bearer)
        #expect(OpenCodeGoModels.protocolForSDK("@ai-sdk/openai")?.0 == .chatCompletions)
        #expect(OpenCodeGoModels.protocolForSDK("@ai-sdk/unknown") == nil)
    }

    /// Provenance: Rust `catalog_intersects_availability_and_fails_closed`.
    /// A model the provider serves but models.dev does not describe, or whose
    /// SDK has no known protocol, is dropped with a warning rather than guessed.
    @Test("availability intersects metadata and fails closed")
    func intersectionFailsClosed() throws {
        let metadata = ModelsDevProvider(
            npm: "@ai-sdk/openai-compatible",
            models: [
                "gpt-ish": ModelsDevModel(
                    name: "GPT-ish",
                    description: "an openai-compatible model",
                    limit: ModelsDevLimit(context: 400_000, output: 64_000)
                ),
                "claude-ish": ModelsDevModel(
                    name: "Claude-ish",
                    provider: ModelsDevModelProvider(npm: "@ai-sdk/anthropic"),
                    limit: ModelsDevLimit(context: 200_000, output: 32_000)
                ),
                "mystery": ModelsDevModel(
                    name: "Mystery",
                    provider: ModelsDevModelProvider(npm: "@ai-sdk/unknown")
                ),
            ]
        )

        let result = OpenCodeGoModels.catalog(
            availableIDs: ["gpt-ish", "claude-ish", "mystery", "undocumented"],
            metadata: metadata,
            baseURL: "https://opencode.ai/zen/go/v1"
        )

        #expect(result.entries.count == 2)
        #expect(result.warnings.count == 2)
        #expect(result.warnings.contains { $0.contains("undocumented") })
        #expect(result.warnings.contains { $0.contains("@ai-sdk/unknown") })

        // The per-model SDK override wins over the provider-level default, so
        // one provider key drives two different wire protocols.
        let openAIish = try #require(result.entries["opencode-go:gpt-ish"])
        #expect(openAIish.info.apiBackend == .chatCompletions)
        #expect(openAIish.info.authScheme == .bearer)
        #expect(openAIish.info.contextWindow == 400_000)
        #expect(openAIish.info.maxCompletionTokens == 64_000)
        #expect(openAIish.info.name == "GPT-ish")
        #expect(openAIish.envKey == .single(OpenCodeGoModels.apiKeyEnv))

        let anthropicish = try #require(result.entries["opencode-go:claude-ish"])
        #expect(anthropicish.info.apiBackend == .messages)
        #expect(anthropicish.info.authScheme == .xApiKey)

        // Descriptors are sorted by name then id for a stable menu.
        #expect(result.descriptors.map(\.name) == ["Claude-ish", "GPT-ish"])
    }

    @Test("a missing context limit falls back rather than producing a zero window")
    func contextFallback() throws {
        let metadata = ModelsDevProvider(
            npm: "@ai-sdk/openai-compatible",
            models: ["m": ModelsDevModel(limit: ModelsDevLimit(context: nil, output: nil))]
        )
        let result = OpenCodeGoModels.catalog(
            availableIDs: ["m"],
            metadata: metadata,
            baseURL: "https://opencode.ai/zen/go/v1"
        )
        let entry = try #require(result.entries["opencode-go:m"])
        #expect(entry.info.contextWindow == OpenCodeGoModels.fallbackContextWindow)
        #expect(entry.info.maxCompletionTokens == nil)
        // A model without a name falls back to its id.
        #expect(entry.info.name == "m")
    }

    @Test("models.dev parsing requires the opencode-go provider entry")
    func modelsDevParsing() throws {
        let body = Data(#"""
        {"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{
          "m":{"name":"M","limit":{"context":128000,"output":8192}}
        }}}
        """#.utf8)
        let provider = try OpenCodeGoModels.parseModelsDev(body)
        #expect(provider.npm == "@ai-sdk/openai-compatible")
        #expect(provider.models["m"]?.name == "M")
        #expect(provider.models["m"]?.limit?.context == 128_000)

        #expect(throws: ModelsError.self) {
            _ = try OpenCodeGoModels.parseModelsDev(Data(#"{"other-provider":{}}"#.utf8))
        }
    }

    @Test("availability ids parse from the provider response")
    func availabilityParsing() throws {
        let ids = try OpenCodeGoModels.parseAvailableIDs(
            Data(#"{"data":[{"id":"a"},{"id":"  "},{"id":"b"}]}"#.utf8)
        )
        #expect(ids == ["a", "b"])
        #expect(try OpenCodeGoModels.parseAvailableIDs(Data("{}".utf8)).isEmpty)
    }
}

@Suite("Provider endpoint trust policy")
struct ProviderEndpointTrustTests {
    /// Built-in session bearers must never reach a provider that only has an
    /// API key, and each provider's trust check is its own host list.
    @Test("each new provider trusts only its own endpoint")
    func trustedEndpointsAreProviderScoped() {
        #expect(trustedBuiltInSessionEndpoint(provider: .deepseek, baseURL: "https://api.deepseek.com"))
        #expect(!trustedBuiltInSessionEndpoint(provider: .deepseek, baseURL: "https://pass.wafer.ai/v1"))

        #expect(trustedBuiltInSessionEndpoint(provider: .wafer, baseURL: "https://pass.wafer.ai/v1"))
        #expect(!trustedBuiltInSessionEndpoint(provider: .wafer, baseURL: "https://api.deepseek.com"))

        #expect(
            trustedBuiltInSessionEndpoint(
                provider: .openCodeGo,
                baseURL: "https://opencode.ai/zen/go/v1"
            )
        )
        #expect(!trustedBuiltInSessionEndpoint(provider: .openCodeGo, baseURL: "https://api.x.ai/v1"))
    }
}
