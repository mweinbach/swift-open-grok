import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokSamplingTypes

@Suite("OpenRouter provider-isolated, explicitly opted-in model catalog")
struct OpenRouterModelsParityTests {
    @Test("stored OpenRouter credentials trust only the exact official HTTPS host")
    func trustedProviderHost() {
        #expect(OpenRouterModels.isTrustedAPIBaseURL("https://openrouter.ai/api/v1"))
        #expect(OpenRouterModels.isTrustedAPIBaseURL("https://openrouter.ai/api/v1/models"))
        #expect(OpenRouterModels.isTrustedAPIBaseURL("https://OPENROUTER.AI/api/v1"))
        #expect(!OpenRouterModels.isTrustedAPIBaseURL("http://openrouter.ai/api/v1"))
        #expect(!OpenRouterModels.isTrustedAPIBaseURL("https://openrouter.ai.example/v1"))
        #expect(!OpenRouterModels.isTrustedAPIBaseURL("https://api.openrouter.ai/v1"))
        #expect(!OpenRouterModels.isTrustedAPIBaseURL("https://api.x.ai/v1"))
        #expect(!OpenRouterModels.isTrustedAPIBaseURL("not a url"))
    }

    @Test("OpenRouter endpoint environment overrides trim whitespace and trailing slashes")
    func configuredBaseURL() {
        #expect(OpenRouterModels.apiBaseURL(environment: [:]) == "https://openrouter.ai/api/v1")
        #expect(
            OpenRouterModels.apiBaseURL(environment: [
                OpenRouterModels.apiBaseURLEnv: "  https://gateway.example/v2///  "
            ]) == "https://gateway.example/v2"
        )
        #expect(
            OpenRouterModels.apiBaseURL(environment: [OpenRouterModels.apiBaseURLEnv: " / "])
                == OpenRouterModels.apiBaseURLDefault
        )
    }

    @Test("only OPENROUTER_API_KEY supplies this provider's environment credential")
    func isolatedEnvironmentCredential() {
        #expect(OpenRouterModels.environmentAPIKey(environment: [
            OpenRouterModels.apiKeyEnv: "  openrouter-secret  ",
            "XAI_API_KEY": "xai-secret",
            "OPENAI_API_KEY": "openai-secret",
        ]) == "openrouter-secret")
        #expect(OpenRouterModels.environmentAPIKey(environment: [
            "XAI_API_KEY": "xai-secret",
            "OPENAI_API_KEY": "openai-secret",
        ]) == nil)
        #expect(!OpenRouterModels.environmentAPIKeyIsConfigured(environment: [
            OpenRouterModels.apiKeyEnv: " \t "
        ]))
        #expect(OpenRouterModels.environmentAPIKeyIsConfigured(environment: [
            OpenRouterModels.apiKeyEnv: "openrouter-secret"
        ]))
    }

    @Test("stored credentials stay on the official host while explicit keys permit overrides")
    func storedCredentialsStayProviderScoped() {
        #expect(OpenRouterModels.selectAPIKey(
            baseURL: OpenRouterModels.apiBaseURLDefault,
            environmentKey: nil,
            storedKey: " stored-secret "
        ) == "stored-secret")
        #expect(OpenRouterModels.selectAPIKey(
            baseURL: "https://openrouter.ai.evil.example/api/v1",
            environmentKey: nil,
            storedKey: "stored-secret"
        ) == nil)
        #expect(OpenRouterModels.selectAPIKey(
            baseURL: "http://openrouter.ai/api/v1",
            environmentKey: nil,
            storedKey: "stored-secret"
        ) == nil)
        #expect(OpenRouterModels.selectAPIKey(
            baseURL: "https://gateway.example/v1",
            environmentKey: " explicit-secret ",
            storedKey: "stored-secret"
        ) == "explicit-secret")
    }

    @Test("credential identity uses the exact Rust BLAKE3 principal digest")
    func credentialFingerprintMatchesRust() {
        let fingerprint = OpenRouterModels.credentialFingerprint("abc")
        #expect(fingerprint ==
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
        #expect(fingerprint.count == 64)
        #expect(fingerprint != OpenRouterModels.credentialFingerprint("abcd"))
        #expect(!OpenRouterModels.credentialFingerprint("bearer-secret").contains("bearer-secret"))
    }

    @Test("catalog requests include ordered bearer and attribution headers with 15-second timeout")
    func attributedCatalogRequest() {
        let request = OpenRouterModels.modelsRequest(
            apiKey: "openrouter-secret",
            baseURL: "https://openrouter.ai/api/v1///"
        )

        #expect(request.method == "GET")
        #expect(request.url == "https://openrouter.ai/api/v1/models")
        #expect(request.timeout == 15)
        #expect(request.headers.map(\.name) == ["Authorization", "HTTP-Referer", "X-Title"])
        #expect(request.headerValue("authorization") == "Bearer openrouter-secret")
        #expect(request.headerValue("HTTP-Referer") ==
            "https://github.com/mweinbach/open-grok")
        #expect(request.headerValue("x-title") == "Open Grok")
    }

    @Test("mixed Rust fixture keeps only text models advertising tools and surfaces skip reasons")
    func mixedRustFixtureFiltersUnsupportedModels() throws {
        let snapshot = try Self.mixedCatalog(apiKey: "openrouter-secret")

        #expect(snapshot.entries.keys == [
            "openrouter:anthropic/claude-sonnet-4",
            "openrouter:openai/gpt-4o",
        ])
        #expect(snapshot.descriptors.map(\.name) == [
            "Anthropic: Claude Sonnet 4",
            "OpenAI: GPT-4o",
        ])
        #expect(snapshot.warnings == [
            "OpenRouter model `black-forest-labs/flux` omitted: no text output",
            "OpenRouter model `openai/text-embedding-3-large` omitted: no text output",
            "OpenRouter model `meta-llama/llama-3.1-8b-instruct` omitted: "
                + "does not advertise tool calling",
        ])
        #expect(snapshot.isAuthoritative)
        #expect(snapshot.credentialFingerprint ==
            OpenRouterModels.credentialFingerprint("openrouter-secret"))
        #expect(snapshot.matchesCredential(fingerprint:
            OpenRouterModels.credentialFingerprint("openrouter-secret")))
        #expect(!snapshot.matchesCredential(fingerprint:
            OpenRouterModels.credentialFingerprint("other-principal")))
        #expect(!snapshot.matchesCredential(fingerprint: ""))
    }

    @Test("accepted models have isolated OpenRouter provider routing and no embedded secret")
    func acceptedModelMetadata() throws {
        let snapshot = try Self.mixedCatalog(apiKey: "openrouter-secret")
        let entry = try #require(snapshot.entries["openrouter:anthropic/claude-sonnet-4"])

        #expect(entry.info.id == "openrouter:anthropic/claude-sonnet-4")
        #expect(entry.info.model == "anthropic/claude-sonnet-4")
        #expect(entry.info.name == "Anthropic: Claude Sonnet 4")
        #expect(entry.info.description == "A capable coding model")
        #expect(entry.info.baseURL == OpenRouterModels.apiBaseURLDefault)
        #expect(entry.info.provider == .openRouter)
        #expect(entry.info.apiBackend == .chatCompletions)
        #expect(entry.info.authScheme == .bearer)
        #expect(entry.info.toolMode == .direct)
        #expect(entry.info.supportedInApi)
        #expect(entry.info.contextWindow == 200_000)
        #expect(entry.info.maxCompletionTokens == 8_192)
        #expect(entry.info.extraHeaders.map(\.0) == ["HTTP-Referer", "X-Title"])
        #expect(entry.info.extraHeaders.map(\.1) == [
            "https://github.com/mweinbach/open-grok",
            "Open Grok",
        ])
        #expect(entry.apiKey == nil)
        #expect(entry.authProvider == nil)
        #expect(entry.envKey?.names == ["OPENROUTER_API_KEY"])
    }

    @Test("reasoning-capable models expose the exact None-to-Xhigh menu with Medium default")
    func reasoningCapabilities() throws {
        let snapshot = try Self.mixedCatalog(apiKey: "openrouter-secret")
        let reasoning = try #require(snapshot.entries["openrouter:anthropic/claude-sonnet-4"])
        let ordinary = try #require(snapshot.entries["openrouter:openai/gpt-4o"])

        #expect(reasoning.info.supportsReasoningEffort)
        #expect(reasoning.info.reasoningEffort == .medium)
        #expect(reasoning.info.reasoningEfforts.map(\.value) == [
            .none, .low, .medium, .high, .xhigh,
        ])
        #expect(reasoning.info.reasoningEfforts.map(\.label) == [
            "None", "Low", "Medium", "High", "Xhigh",
        ])
        #expect(reasoning.info.reasoningEfforts.filter(\.isDefault).map(\.value) == [.medium])
        #expect(reasoning.info.reasoningEfforts.allSatisfy { $0.description == nil })

        #expect(!ordinary.info.supportsReasoningEffort)
        #expect(ordinary.info.reasoningEffort == nil)
        #expect(ordinary.info.reasoningEfforts.isEmpty)
    }

    @Test("reasoning_effort and tool capability matching are case-insensitive")
    func caseInsensitiveCapabilities() throws {
        let wire = Data(#"""
        {"data":[{
          "id":"provider/reasoner",
          "architecture":{"output_modalities":["TEXT"]},
          "supported_parameters":["TOOLS","ReAsOnInG_EfFoRt"]
        }]}
        """#.utf8)

        let entry = try #require(OpenRouterModels.parseCatalog(
            wire,
            baseURL: OpenRouterModels.apiBaseURLDefault
        )["openrouter:provider/reasoner"])

        #expect(entry.info.supportsReasoningEffort)
        #expect(entry.info.reasoningEffort == .medium)
    }

    @Test("missing capability advertisements remain backward-compatible")
    func missingCapabilitiesRemainUsable() throws {
        let wire = Data(#"""
        {"data":[
          {"id":"provider/no-architecture"},
          {"id":"provider/no-output","architecture":{"output_modalities":[]}},
          {"id":"provider/text-modality","architecture":{"modality":"text->text"}},
          {"id":"provider/explicit-empty","supported_parameters":[]}
        ]}
        """#.utf8)

        let catalog = try OpenRouterModels.parseCatalog(
            wire,
            baseURL: OpenRouterModels.apiBaseURLDefault
        )
        #expect(catalog.keys == [
            "openrouter:provider/no-architecture",
            "openrouter:provider/no-output",
            "openrouter:provider/text-modality",
            "openrouter:provider/explicit-empty",
        ])
        #expect(catalog.values().allSatisfy { !$0.info.supportsReasoningEffort })
    }

    @Test("legacy modality metadata excludes embeddings, image, audio, and video outputs")
    func legacyNonTextModalitiesAreExcluded() throws {
        let wire = Data(#"""
        {"data":[
          {"id":"provider/embedding","architecture":{"modality":"text->EMBEDDING"}},
          {"id":"provider/image","architecture":{"modality":"text->IMAGE"}},
          {"id":"provider/audio","architecture":{"modality":"text->audio"}},
          {"id":"provider/video","architecture":{"modality":"text->video"}},
          {"id":"provider/multimodal","architecture":{"output_modalities":["image","TEXT"]}}
        ]}
        """#.utf8)

        let snapshot = try OpenRouterModels.parseCatalogSnapshot(
            wire,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: "secret"
        )
        #expect(snapshot.entries.keys == ["openrouter:provider/multimodal"])
        #expect(snapshot.warnings.count == 4)
        #expect(snapshot.warnings.allSatisfy { $0.hasSuffix("no text output") })
    }

    @Test("explicit nonempty supported parameters must include tools")
    func nonToolModelsAreExcluded() throws {
        let wire = Data(#"""
        {"data":[
          {"id":"provider/no-tools","supported_parameters":["temperature","reasoning"]},
          {"id":"provider/tools","supported_parameters":["temperature","TOOLS"]}
        ]}
        """#.utf8)

        let snapshot = try OpenRouterModels.parseCatalogSnapshot(
            wire,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: "secret"
        )
        #expect(snapshot.entries.keys == ["openrouter:provider/tools"])
        #expect(snapshot.warnings == [
            "OpenRouter model `provider/no-tools` omitted: does not advertise tool calling"
        ])
    }

    @Test("served context and bounded completion limits follow the upstream fallback chain")
    func contextAndCompletionLimitFallbacks() throws {
        let wire = Data(#"""
        {"data":[
          {"id":"provider/top-context","top_provider":{
            "context_length":128000,"max_completion_tokens":8192
          }},
          {"id":"provider/top-level-wins","context_length":32000,"top_provider":{
            "context_length":128000,"max_completion_tokens":4294967295
          }},
          {"id":"provider/top-level-zero","context_length":0,"top_provider":{
            "context_length":128000,"max_completion_tokens":0
          }},
          {"id":"provider/overflow","top_provider":{"max_completion_tokens":4294967296}},
          {"id":"provider/missing"}
        ]}
        """#.utf8)

        let catalog = try OpenRouterModels.parseCatalog(
            wire,
            baseURL: OpenRouterModels.apiBaseURLDefault
        )

        let top = try #require(catalog["openrouter:provider/top-context"])
        #expect(top.info.contextWindow == 128_000)
        #expect(top.info.maxCompletionTokens == 8_192)

        let topLevel = try #require(catalog["openrouter:provider/top-level-wins"])
        #expect(topLevel.info.contextWindow == 32_000)
        #expect(topLevel.info.maxCompletionTokens == UInt32.max)

        let zero = try #require(catalog["openrouter:provider/top-level-zero"])
        #expect(zero.info.contextWindow == 200_000)
        #expect(zero.info.maxCompletionTokens == nil)

        #expect(try #require(catalog["openrouter:provider/overflow"])
            .info.maxCompletionTokens == nil)
        #expect(try #require(catalog["openrouter:provider/missing"])
            .info.contextWindow == 200_000)
    }

    @Test("blank model IDs vanish while valid IDs are trimmed and insertion order survives")
    func modelIdentifierNormalization() throws {
        let wire = Data(#"""
        {"data":[
          {"id":"  "},
          {"id":" provider/zulu ","name":"Zulu"},
          {"id":"provider/alpha","name":"Alpha"}
        ]}
        """#.utf8)

        let snapshot = try OpenRouterModels.parseCatalogSnapshot(
            wire,
            baseURL: "https://openrouter.ai/api/v1///",
            apiKey: "secret"
        )
        #expect(snapshot.entries.keys == [
            "openrouter:provider/zulu",
            "openrouter:provider/alpha",
        ])
        #expect(snapshot.descriptors.map(\.id) == ["provider/alpha", "provider/zulu"])
        #expect(snapshot.warnings.isEmpty)
        #expect(try #require(snapshot.entries["openrouter:provider/zulu"])
            .info.baseURL == OpenRouterModels.apiBaseURLDefault)
    }

    @Test("descriptor display sorting breaks equal-name ties on raw provider identifiers")
    func descriptorSortOrder() throws {
        let wire = Data(#"""
        {"data":[
          {"id":"provider/b","name":"Shared"},
          {"id":"provider/z","name":"Alpha"},
          {"id":"provider/a","name":"Shared"},
          {"id":"provider/unnamed"}
        ]}
        """#.utf8)

        let snapshot = try OpenRouterModels.parseCatalogSnapshot(
            wire,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: "secret"
        )
        #expect(snapshot.descriptors.map(\.id) == [
            "provider/z",
            "provider/a",
            "provider/b",
            "provider/unnamed",
        ])
        #expect(snapshot.descriptors.last?.name == "provider/unnamed")
    }

    @Test("empty successful responses remain authoritative and principal-bound")
    func emptyResponseRemainsAuthoritative() throws {
        for response in [#"{"data":[]}"#, #"{}"#] {
            let snapshot = try OpenRouterModels.parseCatalogSnapshot(
                Data(response.utf8),
                baseURL: OpenRouterModels.apiBaseURLDefault,
                apiKey: "secret"
            )
            #expect(snapshot.isAuthoritative)
            #expect(snapshot.entries.isEmpty)
            #expect(snapshot.descriptors.isEmpty)
            #expect(snapshot.warnings.isEmpty)
            #expect(snapshot.credentialFingerprint == OpenRouterModels.credentialFingerprint("secret"))
        }
    }

    @Test("malformed provider payloads fail closed without manufacturing fallback models")
    func malformedPayloadFailsClosed() {
        let invalid = [
            "",
            "[]",
            #"{"data":null}"#,
            #"{"data":{}}"#,
            #"{"data":[{}]}"#,
            #"{"data":[{"id":7}]}"#,
            #"{"data":[{"id":"provider/model","context_length":-1}]}"#,
            #"{"data":[{"id":"provider/model","supported_parameters":null}]}"#,
            #"{"data":[{"id":"provider/model","supported_parameters":[9]}]}"#,
            #"{"data":[{"id":"provider/model","architecture":{"output_modalities":null}}]}"#,
        ]

        for response in invalid {
            #expect(throws: ModelsError.self) {
                try OpenRouterModels.parseCatalog(
                    Data(response.utf8),
                    baseURL: OpenRouterModels.apiBaseURLDefault
                )
            }
        }
    }

    @Test("unauthenticated snapshots cannot be created with a missing or blank credential")
    func unauthenticatedSnapshotsFailClosed() {
        for credential in ["", "  \t "] {
            #expect(throws: ModelsError.self) {
                try OpenRouterModels.parseCatalogSnapshot(
                    Data(#"{"data":[]}"#.utf8),
                    baseURL: OpenRouterModels.apiBaseURLDefault,
                    apiKey: credential
                )
            }
        }

        let unauthenticated = OpenRouterModelsCatalog(
            entries: OrderedModelMap(),
            descriptors: [],
            credentialFingerprint: ""
        )
        #expect(!unauthenticated.matchesCredential(fingerprint: ""))
    }

    @Test("no discovered OpenRouter models are selectable until explicitly opted in")
    func discoveryDefaultsToZeroEnabledModels() throws {
        let snapshot = try Self.mixedCatalog(apiKey: "secret")
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.selectableEntries().isEmpty)
        #expect(snapshot.selectableEntries(enabledModels: []).isEmpty)
        #expect(snapshot.selectableEntries(enabledModels: ["provider/unknown"]).isEmpty)
        #expect(snapshot.selectableEntries(enabledModels: ["openrouter:*"]).isEmpty)
        #expect(snapshot.selectableEntries(enabledModels: ["openai/"]).isEmpty)
    }

    @Test("opt-in allowlist accepts only exact catalog keys or exact provider model IDs")
    func allowlistMatchesOnlyExplicitModel() throws {
        let snapshot = try Self.mixedCatalog(apiKey: "secret")

        let rawID = snapshot.selectableEntries(enabledModels: ["openai/gpt-4o"])
        #expect(rawID.keys == ["openrouter:openai/gpt-4o"])

        let fullKey = snapshot.selectableEntries(enabledModels: [
            "openrouter:anthropic/claude-sonnet-4"
        ])
        #expect(fullKey.keys == ["openrouter:anthropic/claude-sonnet-4"])

        let both = snapshot.selectableEntries(enabledModels: [
            "openai/gpt-4o",
            "openrouter:anthropic/claude-sonnet-4",
        ])
        #expect(both.keys == snapshot.entries.keys)
    }

    @Test("a forged cross-provider catalog entry cannot pass OpenRouter's opt-in boundary")
    func allowlistRejectsCrossProviderEntries() {
        var entries = OrderedModelMap()
        entries["openrouter:provider/forged"] = ModelEntry(
            info: ModelInfo(model: "provider/forged", provider: .xai)
        )
        let snapshot = OpenRouterModelsCatalog(
            entries: entries,
            descriptors: [],
            credentialFingerprint: OpenRouterModels.credentialFingerprint("secret")
        )

        #expect(snapshot.selectableEntries(enabledModels: [
            "openrouter:provider/forged",
            "provider/forged",
        ]).isEmpty)
    }

    @Test("provider decimal pricing is preserved without inventing absent amounts")
    func providerPricingMetadata() throws {
        let snapshot = try Self.mixedCatalog(apiKey: "secret")
        let descriptor = try #require(snapshot.descriptors.first {
            $0.id == "anthropic/claude-sonnet-4"
        })
        let pricing = try #require(descriptor.pricing)

        #expect(pricing.prompt == Decimal(string: "0.000003"))
        #expect(pricing.completion == Decimal(string: "0.000015"))
        #expect(pricing.inputCacheRead == Decimal(string: "0.0000003"))
        #expect(pricing.request == nil)
        #expect(pricing.image == nil)
        #expect(pricing.webSearch == nil)

        let ordinary = try #require(snapshot.descriptors.first { $0.id == "openai/gpt-4o" })
        #expect(ordinary.pricing == nil)
    }

    @Test("invalid pricing never rejects a Rust-compatible model and numeric free tiers survive")
    func malformedPricingRemainsBestEffort() throws {
        let wire = Data(#"""
        {"data":[
          {"id":"provider/malformed","pricing":"unknown"},
          {"id":"provider/negative","pricing":{"prompt":"-0.01","completion":"broken"}},
          {"id":"provider/free","pricing":{"prompt":"0","completion":0}},
          {"id":"provider/mixed","pricing":{"prompt":"invalid","request":"0.002"}}
        ]}
        """#.utf8)

        let snapshot = try OpenRouterModels.parseCatalogSnapshot(
            wire,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: "secret"
        )
        #expect(snapshot.entries.count == 4)
        #expect(snapshot.descriptors.first { $0.id == "provider/malformed" }?.pricing == nil)
        #expect(snapshot.descriptors.first { $0.id == "provider/negative" }?.pricing == nil)

        let free = try #require(snapshot.descriptors.first { $0.id == "provider/free" }?.pricing)
        #expect(free.prompt == Decimal(0))
        #expect(free.completion == Decimal(0))

        let mixed = try #require(snapshot.descriptors.first { $0.id == "provider/mixed" }?.pricing)
        #expect(mixed.prompt == nil)
        #expect(mixed.request == Decimal(string: "0.002"))
    }

    @Test("provider error excerpts redact credentials, collapse CRLF, and cap at 512 characters")
    func safeErrorExcerpt() {
        let raw = "prefix secret-key\r\nsecond-line " + String(repeating: "x", count: 600)
        let sanitized = OpenRouterModels.safeErrorExcerpt(raw, apiKey: "secret-key")

        #expect(sanitized.count == 512)
        #expect(sanitized.hasPrefix("prefix [REDACTED]  second-line "))
        #expect(!sanitized.contains("secret-key"))
        #expect(!sanitized.contains("\r"))
        #expect(!sanitized.contains("\n"))
    }

    @Test("descriptor JSON preserves Rust snake_case API backend and additive pricing")
    func descriptorCodableShape() throws {
        let original = OpenRouterModelDescriptor(
            key: "openrouter:provider/model",
            id: "provider/model",
            name: "Provider Model",
            apiBackend: .chatCompletions,
            pricing: OpenRouterModelPricing(
                prompt: Decimal(string: "0.001"),
                inputCacheRead: Decimal(string: "0.0001")
            )
        )

        let data = try JSONEncoder().encode(original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["api_backend"] as? String == ApiBackend.chatCompletions.rawValue)
        let pricing = try #require(json["pricing"] as? [String: Any])
        #expect(pricing["input_cache_read"] != nil)
        #expect(try JSONDecoder().decode(OpenRouterModelDescriptor.self, from: data) == original)
    }

    private static func mixedCatalog(apiKey: String) throws -> OpenRouterModelsCatalog {
        let wire = Data(#"""
        {"data":[
          {
            "id":"anthropic/claude-sonnet-4",
            "name":"Anthropic: Claude Sonnet 4",
            "description":"A capable coding model",
            "context_length":200000,
            "architecture":{"output_modalities":["text"]},
            "top_provider":{"context_length":200000,"max_completion_tokens":8192},
            "supported_parameters":["tools","reasoning"],
            "pricing":{
              "prompt":"0.000003",
              "completion":"0.000015",
              "input_cache_read":"0.0000003"
            }
          },
          {
            "id":"openai/gpt-4o",
            "name":"OpenAI: GPT-4o",
            "context_length":128000,
            "architecture":{"output_modalities":["text"]},
            "top_provider":{"context_length":128000,"max_completion_tokens":8192},
            "supported_parameters":["tools","temperature"]
          },
          {
            "id":"black-forest-labs/flux",
            "name":"Flux",
            "architecture":{"output_modalities":["image"]},
            "supported_parameters":["tools"]
          },
          {
            "id":"openai/text-embedding-3-large",
            "name":"Embeddings",
            "architecture":{"output_modalities":["embeddings"]},
            "supported_parameters":[]
          },
          {
            "id":"meta-llama/llama-3.1-8b-instruct",
            "name":"Llama 3.1 8B",
            "architecture":{"output_modalities":["text"]},
            "supported_parameters":["temperature"]
          }
        ]}
        """#.utf8)

        return try OpenRouterModels.parseCatalogSnapshot(
            wire,
            baseURL: "https://openrouter.ai/api/v1/",
            apiKey: apiKey
        )
    }
}
