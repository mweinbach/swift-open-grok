import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokModels

@Suite("Configured model override and transport-secret parity")
struct ConfiguredModelOverrideParityTests {
    @Test("all modeled TOML override fields reach the real configured catalog")
    func everySupportedModelOverrideFieldIsParsedAndApplied() throws {
        let document = try parseTOML("""
        [auth_provider.corp]
        command = "corp-token"

        [model.enterprise]
        model = "enterprise-v1"
        base_url = "https://gateway.example/v1"
        name = "Enterprise"
        description = "Private enterprise model"
        api_key = "configured-static-key"
        env_key = ["PRIMARY_MODEL_KEY", "SECONDARY_MODEL_KEY"]
        api_base_url = "https://gateway.example/api"
        auth_provider = "corp"
        query_params = { tenant = "acme" }
        env_http_headers = { X-Tenant-Token = "TENANT_TOKEN" }
        max_completion_tokens = 4096
        temperature = 0.25
        top_p = 0.75
        api_backend = "responses"
        provider = "codex"
        auth_scheme = "x_api_key"
        tool_mode = "code_mode_only"
        subagent_context_default = "forked"
        extra_headers = { X-Static = "keep" }
        context_window = 320000
        auto_compact_threshold_percent = 77
        system_prompt_label = "Enterprise identity"
        use_concise = true
        agent_type = "codex"
        inference_idle_timeout_secs = 120
        max_retries = 3
        hidden = true
        supported_in_api = false
        reasoning_effort = "high"
        supports_reasoning_effort = true
        reasoning_efforts = [
          { id = "deep", value = "high", label = "Deep", description = "Deep thinking", default = true },
          "low",
        ]
        supports_reasoning_summary_parameter = false
        default_reasoning_summary = "detailed"
        supports_backend_search = true
        supports_standalone_web_search = true
        compactions_remaining = 4
        compaction_at_tokens = 100000
        show_model_fingerprint = true
        stream_tool_calls = false
        """)
        let configured = parseConfiguredModelCatalog(
            from: document,
            environment: ["TENANT_TOKEN": "must-never-be-persisted"]
        )
        let override = try #require(configured.modelOverrides.first?.1)

        #expect(configured.modelOverrides.first?.0 == "enterprise")
        #expect(override.model == "enterprise-v1")
        #expect(override.baseURL == "https://gateway.example/v1")
        #expect(override.name == "Enterprise")
        #expect(override.description == "Private enterprise model")
        #expect(override.apiKey == "configured-static-key")
        #expect(override.envKey?.names == ["PRIMARY_MODEL_KEY", "SECONDARY_MODEL_KEY"])
        #expect(override.apiBaseURL == "https://gateway.example/api")
        #expect(override.authProvider == "corp")
        #expect(override.queryParams.first?.0 == "tenant")
        #expect(override.queryParams.first?.1 == "acme")
        #expect(override.envHTTPHeaders.first?.0 == "X-Tenant-Token")
        #expect(override.envHTTPHeaders.first?.1 == "TENANT_TOKEN")
        #expect(override.maxCompletionTokens == 4096)
        #expect(override.temperature == 0.25)
        #expect(override.topP == 0.75)
        #expect(override.apiBackend == .responses)
        #expect(override.provider == .codex)
        #expect(override.authScheme == .xApiKey)
        #expect(override.toolMode == .codeModeOnly)
        #expect(override.subagentContextDefault == .fork)
        #expect(override.extraHeaders.first?.0 == "X-Static")
        #expect(override.extraHeaders.first?.1 == "keep")
        #expect(override.contextWindow == 320000)
        #expect(override.autoCompactThresholdPercent == 77)
        #expect(override.systemPromptLabel == "Enterprise identity")
        #expect(override.useConcise == true)
        #expect(override.agentType == "codex")
        #expect(override.inferenceIdleTimeoutSecs == 120)
        #expect(override.maxRetries == 3)
        #expect(override.hidden == true)
        #expect(override.supportedInApi == false)
        #expect(override.reasoningEffort == .high)
        #expect(override.supportsReasoningEffort == true)
        #expect(override.reasoningEfforts.map(\.id) == ["deep", "low"])
        #expect(override.reasoningEfforts.map(\.value) == [.high, .low])
        #expect(override.reasoningEfforts.first?.isDefault == true)
        #expect(override.supportsReasoningSummaryParameter == false)
        #expect(override.defaultReasoningSummary == .detailed)
        #expect(override.supportsBackendSearch == true)
        #expect(override.supportsStandaloneWebSearch == true)
        #expect(override.compactionsRemaining == .fixed(4))
        #expect(override.compactionAtTokens == .fixed(100000))
        #expect(override.showModelFingerprint == true)
        #expect(override.streamToolCalls == false)
        #expect(configured.warnings.count == 1)
        #expect(configured.warnings.first?.field == "auth_provider")
        #expect(configured.warnings.first?.kind == .conflictingFields)

        let catalog = resolveModelCatalog(input: CatalogResolutionInput(
            configModels: configured.modelOverrides
        ))
        let model = try #require(catalog["enterprise"])
        #expect(model.info.provider == .codex)
        #expect(model.info.apiBackend == .responses)
        #expect(model.info.toolMode == .codeModeOnly)
        #expect(model.info.subagentContextDefault == .fork)
        #expect(model.info.supportsStandaloneWebSearch == true)
        #expect(model.info.supportsBackendSearch)
        #expect(model.info.compactionsRemaining == .fixed(4))
        #expect(model.info.compactionAtTokens == .fixed(100000))
        #expect(model.info.streamToolCalls == false)
        #expect(model.envHTTPHeaders["X-Tenant-Token"] == "TENANT_TOKEN")
        #expect(model.info.extraHeaders.first?.1 == "keep")
    }

    @Test("malformed enums and polymorphic values warn without dropping valid model fields")
    func invalidFieldsAreExplicitlyRejectedWhileValidSiblingsSurvive() throws {
        let document = try parseTOML("""
        [model.resilient]
        name = "Retained model"
        api_backend = "future-backend"
        provider = "unknown-provider"
        auth_scheme = "custom-auth"
        tool_mode = "automatic"
        subagent_context_default = "telepathic"
        reasoning_effort = "infinite"
        default_reasoning_summary = "essay"
        env_key = ["VALID_ENV_NAME", 42]
        compactions_remaining = "many"
        compaction_at_tokens = -1
        reasoning_efforts = ["high", "unlimited"]
        max_retries = -1
        supports_standalone_web_search = "yes"
        extra_headers = { Valid = "ok", Invalid = 42 }
        unknown_model_option = true
        """)
        let configured = parseConfiguredModelCatalog(from: document)
        let override = try #require(configured.modelOverrides.first?.1)
        let invalidFields = Set(configured.warnings.compactMap(\.field))

        #expect(override.name == "Retained model")
        #expect(override.apiBackend == nil)
        #expect(override.provider == nil)
        #expect(override.authScheme == nil)
        #expect(override.toolMode == nil)
        #expect(override.subagentContextDefault == nil)
        #expect(override.reasoningEffort == nil)
        #expect(override.defaultReasoningSummary == nil)
        #expect(override.envKey == nil)
        #expect(override.compactionsRemaining == nil)
        #expect(override.compactionAtTokens == nil)
        #expect(override.reasoningEfforts.isEmpty)
        #expect(override.maxRetries == nil)
        #expect(override.supportsStandaloneWebSearch == nil)
        #expect(override.extraHeaders.isEmpty)
        #expect(invalidFields == Set([
            "api_backend", "provider", "auth_scheme", "tool_mode",
            "subagent_context_default", "reasoning_effort", "default_reasoning_summary",
            "env_key", "compactions_remaining", "compaction_at_tokens",
            "reasoning_efforts", "max_retries", "supports_standalone_web_search",
            "extra_headers", "unknown_model_option",
        ]))
        #expect(configured.warnings.first { $0.field == "unknown_model_option" }?.kind == .unknownField)
        #expect(configured.warnings.filter { $0.kind == .invalidValue }.count == 14)

        let catalog = resolveModelCatalog(input: CatalogResolutionInput(
            configModels: configured.modelOverrides
        ))
        #expect(catalog["resilient"]?.info.name == "Retained model")
    }

    @Test("legacy compaction aliases follow canonical precedence and invalid fallback")
    func compactionAliasPrecedenceRetainsValidValues() throws {
        let fallbackDocument = try parseTOML("""
        [model.fallback]
        compactions_remaining = "bad"
        send_compactions_remaining = 2
        compaction_at_tokens = true
        """)
        let fallback = parseConfiguredModelCatalog(from: fallbackDocument)
        let fallbackOverride = try #require(fallback.modelOverrides.first?.1)

        #expect(fallbackOverride.compactionsRemaining == .fixed(2))
        #expect(fallbackOverride.compactionAtTokens == .enabled(true))
        #expect(fallback.warnings.count == 1)
        #expect(fallback.warnings.first?.field == "compactions_remaining")

        let canonicalDocument = try parseTOML("""
        [model.canonical]
        compactions_remaining = false
        send_compactions_remaining = 7
        """)
        let canonical = parseConfiguredModelCatalog(from: canonicalDocument)

        #expect(canonical.modelOverrides.first?.1.compactionsRemaining == .dynamic(false))
        #expect(canonical.warnings.count == 1)
        #expect(canonical.warnings.first?.field == "send_compactions_remaining")
    }

    @Test("provider header mappings remain unresolved through model catalog persistence")
    func environmentHeaderSecretsNeverEnterCatalogOrPersistedModels() throws {
        let secret = "tenant-secret-4bb89a7d-never-persist"
        let document = try parseTOML("""
        [model_providers.gateway]
        base_url = "https://gateway.example/v1"
        context_window = 160000
        extra_headers = { X-Tenant = "static-placeholder" }
        env_http_headers = { x-tenant = "TENANT_SECRET", X-Missing = "UNSET_SECRET" }

        [model.enterprise]
        model = "enterprise-v1"
        model_provider = "gateway"
        """)
        let configured = parseConfiguredModelCatalog(
            from: document,
            environment: ["TENANT_SECRET": secret]
        )
        let override = try #require(configured.modelOverrides.first?.1)
        let mappings = Dictionary(uniqueKeysWithValues: override.envHTTPHeaders)

        #expect(configured.warnings.isEmpty)
        #expect(mappings["x-tenant"] == "TENANT_SECRET")
        #expect(mappings["X-Missing"] == "UNSET_SECRET")
        #expect(override.extraHeaders.count == 1)
        #expect(override.extraHeaders.first?.0 == "X-Tenant")
        #expect(override.extraHeaders.first?.1 == "static-placeholder")
        #expect(!override.extraHeaders.contains { $0.1 == secret })

        let catalog = resolveModelCatalog(input: CatalogResolutionInput(
            configModels: configured.modelOverrides
        ))
        let model = try #require(catalog["enterprise"])
        let persistedEntry = String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
        let persistedInfo = String(decoding: try JSONEncoder().encode(model.info), as: UTF8.self)

        #expect(model.envHTTPHeaders["x-tenant"] == "TENANT_SECRET")
        #expect(model.info.extraHeaders.first?.1 == "static-placeholder")
        #expect(persistedEntry.contains("TENANT_SECRET"))
        #expect(persistedEntry.contains("static-placeholder"))
        #expect(!persistedEntry.contains(secret))
        #expect(!persistedInfo.contains(secret))
    }

    @Test("invalid model sections and entries are visible on the public warning surface")
    func invalidSectionsAndEntriesAreReported() throws {
        let invalidSection = parseConfiguredModelCatalog(from: try parseTOML("model = 7"))
        #expect(invalidSection.modelOverrides.isEmpty)
        #expect(invalidSection.warnings.count == 1)
        #expect(invalidSection.warnings.first?.kind == .notATable)

        let invalidEntry = parseConfiguredModelCatalog(from: try parseTOML("""
        [model]
        scalar = 7

        [model.valid]
        name = "Still present"
        """))
        #expect(invalidEntry.modelOverrides.count == 1)
        #expect(invalidEntry.modelOverrides.first?.0 == "valid")
        #expect(invalidEntry.warnings.first?.name == "scalar")
        #expect(invalidEntry.warnings.first?.kind == .notATable)
    }
}
