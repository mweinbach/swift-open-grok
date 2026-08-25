import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokModels

@Suite("Standalone web search and subagent model capability parity")
struct StandaloneWebSearchCapabilityParityTests {
    @Test("nullable standalone-search capability survives persistence without changing old models")
    func standaloneSearchCapabilityCodablePreservesThreeStates() throws {
        let unspecified = ModelInfo(model: "unspecified")
        let unspecifiedJSON = try JSONEncoder().encode(unspecified)
        let unspecifiedObject = try #require(
            JSONSerialization.jsonObject(with: unspecifiedJSON) as? [String: Any]
        )

        #expect(unspecified.supportsStandaloneWebSearch == nil)
        #expect(unspecifiedObject["supports_standalone_web_search"] == nil)
        #expect(try JSONDecoder().decode(ModelInfo.self, from: unspecifiedJSON) == unspecified)

        for capability in [false, true] {
            let model = ModelInfo(
                model: "configured",
                supportsStandaloneWebSearch: capability
            )
            let encoded = try JSONEncoder().encode(model)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let decoded = try JSONDecoder().decode(ModelInfo.self, from: encoded)

            #expect(object["supports_standalone_web_search"] as? Bool == capability)
            #expect(decoded.supportsStandaloneWebSearch == capability)
            #expect(decoded == model)
            #expect(decoded != ModelInfo(model: "configured"))
        }
    }

    @Test("remote catalogs accept camel and snake case at both metadata levels")
    func remoteStandaloneSearchCapabilityPreservesExplicitFalseAndPrecedence() throws {
        for field in ["supportsStandaloneWebSearch", "supports_standalone_web_search"] {
            for capability in [false, true] {
                let topLevel = try #require(parseRemoteModelValue(
                    ["model": "remote-top", field: capability],
                    defaultBaseURL: "https://provider.example/v1"
                ))
                let metadata = try #require(parseRemoteModelValue(
                    ["model": "remote-meta", "_meta": [field: capability]],
                    defaultBaseURL: "https://provider.example/v1"
                ))

                #expect(topLevel.supportsStandaloneWebSearch == capability)
                #expect(metadata.supportsStandaloneWebSearch == capability)
                #expect(ModelEntry.fromConfigEntry(topLevel).info.supportsStandaloneWebSearch == capability)
                #expect(ModelEntry.fromConfigEntry(metadata).info.supportsStandaloneWebSearch == capability)
            }
        }

        let topLevelWins = try #require(parseRemoteModelValue(
            [
                "model": "remote-precedence",
                "supportsStandaloneWebSearch": false,
                "_meta": ["supports_standalone_web_search": true],
            ],
            defaultBaseURL: "https://provider.example/v1"
        ))
        #expect(topLevelWins.supportsStandaloneWebSearch == false)

        let absent = try #require(parseRemoteModelValue(
            ["model": "legacy-remote"],
            defaultBaseURL: "https://provider.example/v1"
        ))
        #expect(absent.supportsStandaloneWebSearch == nil)
    }

    @Test("per-model TOML capability overrides remain authoritative over live catalogs")
    func configuredCapabilityOverridesRemoteMetadata() throws {
        let remoteConfig = try #require(parseRemoteModelValue(
            ["model": "remote-search", "supportsStandaloneWebSearch": true],
            defaultBaseURL: "https://api.x.ai/v1"
        ))
        var remote = OrderedModelMap()
        remote["remote-search"] = ModelEntry.fromConfigEntry(remoteConfig)

        let document = try parseTOML("""
        [model.remote-search]
        supports_standalone_web_search = false
        """)
        let configured = parseConfiguredModelCatalog(from: document)
        let catalog = resolveModelCatalog(
            input: CatalogResolutionInput(configModels: configured.modelOverrides),
            prefetched: remote
        )

        #expect(configured.warnings.isEmpty)
        #expect(configured.modelOverrides.first?.1.supportsStandaloneWebSearch == false)
        #expect(catalog["remote-search"]?.info.supportsStandaloneWebSearch == false)
    }

    @Test("provider changes clear inherited search and subagent metadata before explicit overrides")
    func providerChangesResetProviderLocalCapabilities() {
        let base = ModelEntry(info: ModelInfo(
            model: "donor",
            baseURL: "https://chatgpt.com/backend-api/codex",
            apiBackend: .responses,
            provider: .codex,
            subagentContextDefault: .fork,
            supportsBackendSearch: true,
            supportsStandaloneWebSearch: true
        ))

        let switched = ConfigModelOverride(provider: .kimi).apply(
            key: "donor",
            base: base,
            endpoints: .default
        )
        #expect(switched.info.provider == .kimi)
        #expect(switched.info.supportsBackendSearch == false)
        #expect(switched.info.supportsStandaloneWebSearch == nil)
        #expect(switched.info.subagentContextDefault == nil)

        let optedIn = ConfigModelOverride(
            provider: .kimi,
            subagentContextDefault: .fresh,
            supportsStandaloneWebSearch: false
        ).apply(key: "donor", base: base, endpoints: .default)
        #expect(optedIn.info.supportsStandaloneWebSearch == false)
        #expect(optedIn.info.subagentContextDefault == .fresh)
    }

    @Test("subagent-context aliases decode exactly like Rust and encode canonically")
    func subagentContextAliasesRoundTripCanonically() throws {
        for alias in ["fork", "Fork", "forked", "Forked"] {
            let data = Data("{\"model\":\"sol\",\"subagent_context_default\":\"\(alias)\"}".utf8)
            let model = try JSONDecoder().decode(ModelInfo.self, from: data)
            let encoded = try JSONEncoder().encode(model)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

            #expect(model.subagentContextDefault == .fork)
            #expect(object["subagent_context_default"] as? String == "fork")
        }

        for alias in ["fresh", "Fresh", "new", "clean"] {
            let data = Data("{\"model\":\"fresh\",\"subagent_context_default\":\"\(alias)\"}".utf8)
            #expect(try JSONDecoder().decode(ModelInfo.self, from: data).subagentContextDefault == .fresh)
        }

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ModelInfo.self,
                from: Data(#"{"model":"invalid","subagent_context_default":"telepathic"}"#.utf8)
            )
        }
    }

    @Test("remote subagent-context metadata honors aliases and safely ignores future values")
    func remoteSubagentContextMetadataIgnoresUnknownValues() throws {
        for field in ["subagentContextDefault", "subagent_context_default"] {
            let topLevel = try #require(parseRemoteModelValue(
                ["model": "sol-top", field: "forked"],
                defaultBaseURL: "https://provider.example/v1"
            ))
            let metadata = try #require(parseRemoteModelValue(
                ["model": "sol-meta", "_meta": [field: "fork"]],
                defaultBaseURL: "https://provider.example/v1"
            ))

            #expect(topLevel.subagentContextDefault == .fork)
            #expect(metadata.subagentContextDefault == .fork)
        }

        let unknown = try #require(parseRemoteModelValue(
            ["model": "future", "subagentContextDefault": "telepathic"],
            defaultBaseURL: "https://provider.example/v1"
        ))
        #expect(unknown.subagentContextDefault == nil)

        let nullFallsThrough = try #require(parseRemoteModelValue(
            [
                "model": "sol-null",
                "subagentContextDefault": NSNull(),
                "_meta": ["subagent_context_default": "forked"],
            ],
            defaultBaseURL: "https://provider.example/v1"
        ))
        #expect(nullFallsThrough.subagentContextDefault == .fork)
    }

    @Test("mixed remote metadata preserves typed capabilities, precedence, and malformed fallbacks")
    func remoteMetadataPreservesReasoningCompactionAndDetectorFields() throws {
        let metadata: [String: Any] = [
            "reasoningEffort": "high",
            "supportsReasoningEffort": true,
            "reasoningEfforts": [
                ["id": "deep", "value": "high", "label": "Deep", "default": true],
                "low",
                ["value": "unknown-future-effort"],
            ],
            "supportsBackendSearch": true,
            "compactionsRemaining": 7,
            "compactionAtTokens": 120_000,
            "showModelFingerprint": true,
            "lazinessDetector": [
                "enabled": true,
                "max_nudges_per_session": 2,
                "idle_threshold_ms": 1_500,
                "min_confidence": 0.75,
                "include_reasoning": true,
            ],
        ]
        let parsed = try #require(parseRemoteModelValue(
            [
                "model": "mixed-metadata",
                "reasoningEffort": "medium",
                "_meta": metadata,
            ],
            defaultBaseURL: "https://provider.example/v1"
        ))

        #expect(parsed.reasoningEffort == .medium)
        #expect(parsed.supportsReasoningEffort)
        #expect(parsed.reasoningEfforts.map(\.id) == ["deep", "low"])
        #expect(parsed.reasoningEfforts.first?.isDefault == true)
        #expect(parsed.supportsReasoningSummaryParameter == false)
        #expect(parsed.defaultReasoningSummary == .none)
        #expect(parsed.supportsBackendSearch)
        #expect(parsed.compactionsRemaining == .fixed(7))
        #expect(parsed.compactionAtTokens == .fixed(120_000))
        #expect(parsed.showModelFingerprint)
        #expect(parsed.lazinessDetector.enabled)
        #expect(parsed.lazinessDetector.maxNudgesPerSession == 2)
        #expect(parsed.lazinessDetector.idleThresholdMs == 1_500)
        #expect(parsed.lazinessDetector.minConfidence == 0.75)
        #expect(parsed.lazinessDetector.includeReasoning == true)

        let malformed = try #require(parseRemoteModelValue(
            [
                "model": "malformed-metadata",
                "supportsReasoningEffort": "yes",
                "reasoningEfforts": "not-an-array",
                "compactionsRemaining": 999,
                "sendCompactionsRemaining": true,
                "compactionAtTokens": 4.5,
                "showModelFingerprint": false,
                "lazinessDetector": ["enabled": "yes"],
                "_meta": metadata,
            ],
            defaultBaseURL: "https://provider.example/v1"
        ))

        #expect(malformed.supportsReasoningEffort == false)
        #expect(malformed.reasoningEfforts.isEmpty)
        #expect(malformed.compactionsRemaining == .dynamic(true))
        #expect(malformed.compactionAtTokens == nil)
        #expect(malformed.showModelFingerprint == false)
        #expect(malformed.lazinessDetector.enabled == false)
        #expect(malformed.lazinessDetector.maxNudgesPerSession == 0)

        let legacy = try #require(parseRemoteModelValue(
            [
                "model": "legacy-metadata",
                "_meta": ["sendCompactionsRemaining": false],
            ],
            defaultBaseURL: "https://provider.example/v1"
        ))
        #expect(legacy.compactionsRemaining == .dynamic(false))
    }

    @Test("actual Codex provider catalogs retain search and context metadata")
    func codexProviderWirePreservesCapabilitiesAndIgnoresUnknownContext() throws {
        let data = Data(#"""
        {
          "models": [
            {
              "slug": "gpt-5.6-sol",
              "visibility": "list",
              "priority": 1,
              "subagent_context_default": "forked",
              "supports_standalone_web_search": false
            },
            {
              "slug": "future-codex",
              "visibility": "list",
              "priority": 2,
              "subagent_context_default": "telepathic",
              "supportsStandaloneWebSearch": true
            }
          ]
        }
        """#.utf8)
        let models = try parseCodexModelsResponse(data)
        let sol = try #require(models.first { $0.slug == "gpt-5.6-sol" })
        let future = try #require(models.first { $0.slug == "future-codex" })

        #expect(sol.entry.info.subagentContextDefault == .fork)
        #expect(sol.entry.info.supportsStandaloneWebSearch == false)
        #expect(future.entry.info.subagentContextDefault == nil)
        #expect(future.entry.info.supportsStandaloneWebSearch == true)
    }

    @Test("Codex refresh inherits Sol's embedded fork default without overwriting live overrides")
    func codexRefreshRetainsSameProviderEmbeddedContextDefault() throws {
        func resolvedContext(_ wireContext: String?) throws -> ModelSubagentContextMode? {
            var wire: [String: Any] = [
                "slug": "gpt-5.6-sol",
                "visibility": "list",
                "context_window": 400_000,
            ]
            if let wireContext { wire["subagent_context_default"] = wireContext }
            let data = try JSONSerialization.data(withJSONObject: ["models": [wire]])
            let catalog = CodexModelsCatalog(
                models: try parseCodexModelsResponse(data),
                accountFingerprint: "codex-account"
            )
            let resolved = resolveModelCatalog(input: .default, codexCatalog: catalog)
            return try #require(resolved["gpt-5.6-sol"]).info.subagentContextDefault
        }

        #expect(try resolvedContext(nil) == .fork)
        #expect(try resolvedContext("telepathic") == .fork)
        #expect(try resolvedContext("fresh") == .fresh)
        #expect(try resolvedContext("forked") == .fork)
    }

    @Test("slug sibling inheritance stays inside its originating provider")
    func siblingContextInheritanceIsProviderScoped() throws {
        let catalog = resolveModelCatalog(input: CatalogResolutionInput(configModels: [
            ("codex-sol-alias", ConfigModelOverride(
                model: "gpt-5.6-sol",
                baseURL: CodexModels.defaultInferenceBaseURL,
                provider: .codex,
                contextWindow: DEFAULT_CONTEXT_WINDOW
            )),
            ("kimi-sol-alias", ConfigModelOverride(
                model: "gpt-5.6-sol",
                baseURL: "https://api.moonshot.ai/v1",
                provider: .kimi,
                contextWindow: DEFAULT_CONTEXT_WINDOW
            )),
        ]))

        #expect(try #require(catalog["codex-sol-alias"]).info.subagentContextDefault == .fork)
        #expect(try #require(catalog["kimi-sol-alias"]).info.subagentContextDefault == nil)
    }

    @Test("embedded catalogs accept Rust context aliases and reject malformed capability metadata")
    func embeddedCatalogValidatesContextAndSearchCapability() throws {
        #expect(try #require(defaultModelEntries()["grok-4.6"]).info.supportsVision)
        #expect(try #require(defaultModelEntries()["grok-4.5"]).info.supportsVision)

        let valid = try parseEmbeddedDefaultModels(#"""
        {
          "default": "embedded-sol",
          "models": [{
            "model": "embedded-sol",
            "subagent_context_default": "forked",
            "supports_standalone_web_search": false
          }]
        }
        """#)
        let model = try #require(valid.models.first)
        #expect(model.subagentContextDefault == .fork)
        #expect(model.supportsStandaloneWebSearch == false)

        let projected = DefaultModelJSON.fromCatalogEntry(ModelEntry(info: ModelInfo(
            model: "projected-sol",
            subagentContextDefault: .fork,
            supportsStandaloneWebSearch: false
        )))
        #expect(projected.subagentContextDefault == .fork)
        #expect(projected.supportsStandaloneWebSearch == false)

        #expect(throws: ModelsError.self) {
            try parseEmbeddedDefaultModels(#"""
            {
              "default": "embedded-invalid",
              "models": [{
                "model": "embedded-invalid",
                "subagent_context_default": "telepathic"
              }]
            }
            """#)
        }

        #expect(throws: ModelsError.self) {
            try parseEmbeddedDefaultModels(#"""
            {
              "default": "embedded-invalid",
              "models": [{
                "model": "embedded-invalid",
                "supports_standalone_web_search": "yes"
              }]
            }
            """#)
        }
    }
}
