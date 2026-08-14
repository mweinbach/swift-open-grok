// MultiProviderCatalogTests.swift
//
// Tests for Multi-Provider Catalog Resolution and Model Metadata in OpenGrokModels.
// Verifies all 9 providers (.xai, .codex, .kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer, .zai),
// environment key resolution, model capabilities, partition filtering, and custom model merging.

import Foundation
import Testing
import OpenGrokConfigTypes
import OpenGrokModels
import OpenGrokSamplingTypes

// MARK: - Multi-Provider Classification & Identification Tests

@Suite("Multi-Provider Classification & Resolution")
struct MultiProviderClassificationTests {
    @Test func allNineProvidersAreClassifiedAndIdentified() {
        let providers: [ModelProvider] = [
            .xai, .codex, .kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer, .zai
        ]
        #expect(providers.count == 9)

        // Verify ModelInfo helper flags for all 9 providers
        for provider in providers {
            let info = ModelInfo(
                model: "\(provider.asString)-test-model",
                provider: provider
            )
            let entry = ModelEntry(info: info)

            #expect(info.isXai == (provider == .xai))
            #expect(info.isCodex == (provider == .codex))
            #expect(info.isKimi == (provider == .kimi))
            #expect(info.isFireworks == (provider == .fireworks))
            #expect(info.isDeepSeek == (provider == .deepseek))
            #expect(info.isMeta == (provider == .meta))
            #expect(info.isOpenCodeGo == (provider == .openCodeGo))
            #expect(info.isWafer == (provider == .wafer))
            #expect(info.isZai == (provider == .zai))

            #expect(entry.isXai == (provider == .xai))
            #expect(entry.isCodex == (provider == .codex))
            #expect(entry.isKimi == (provider == .kimi))
            #expect(entry.isFireworks == (provider == .fireworks))
            #expect(entry.isDeepSeek == (provider == .deepseek))
            #expect(entry.isMeta == (provider == .meta))
            #expect(entry.isOpenCodeGo == (provider == .openCodeGo))
            #expect(entry.isWafer == (provider == .wafer))
            #expect(entry.isZai == (provider == .zai))
        }
    }

    @Test func modelPartitionKindCoversAllPartitionsAndCustom() {
        let allKinds = ModelPartitionKind.allCases
        #expect(allKinds.count == 10)
        #expect(allKinds.contains(.xai))
        #expect(allKinds.contains(.codex))
        #expect(allKinds.contains(.kimi))
        #expect(allKinds.contains(.fireworks))
        #expect(allKinds.contains(.deepSeek))
        #expect(allKinds.contains(.meta))
        #expect(allKinds.contains(.openCodeGo))
        #expect(allKinds.contains(.wafer))
        #expect(allKinds.contains(.zai))
        #expect(allKinds.contains(.custom))

        // First-party providers map to expected ModelProvider
        #expect(ModelPartitionKind.xai.provider == .xai)
        #expect(ModelPartitionKind.codex.provider == .codex)
        #expect(ModelPartitionKind.kimi.provider == .kimi)
        #expect(ModelPartitionKind.fireworks.provider == .fireworks)
        #expect(ModelPartitionKind.deepSeek.provider == .deepseek)
        #expect(ModelPartitionKind.meta.provider == .meta)
        #expect(ModelPartitionKind.openCodeGo.provider == .openCodeGo)
        #expect(ModelPartitionKind.wafer.provider == .wafer)
        #expect(ModelPartitionKind.zai.provider == .zai)
        #expect(ModelPartitionKind.custom.provider == nil)
    }

    @Test func modelCatalogPartitionMapsToExpectedProviders() {
        let partitions = ModelCatalogPartition.allCases
        #expect(partitions.count == 8)
        #expect(ModelCatalogPartition.codex.provider == .codex)
        #expect(ModelCatalogPartition.kimi.provider == .kimi)
        #expect(ModelCatalogPartition.fireworks.provider == .fireworks)
        #expect(ModelCatalogPartition.deepSeek.provider == .deepseek)
        #expect(ModelCatalogPartition.meta.provider == .meta)
        #expect(ModelCatalogPartition.openCodeGo.provider == .openCodeGo)
        #expect(ModelCatalogPartition.wafer.provider == .wafer)
        #expect(ModelCatalogPartition.zai.provider == .zai)

        // Reverse initializer
        #expect(ModelCatalogPartition(provider: .codex) == .codex)
        #expect(ModelCatalogPartition(provider: .kimi) == .kimi)
        #expect(ModelCatalogPartition(provider: .fireworks) == .fireworks)
        #expect(ModelCatalogPartition(provider: .deepseek) == .deepSeek)
        #expect(ModelCatalogPartition(provider: .meta) == .meta)
        #expect(ModelCatalogPartition(provider: .openCodeGo) == .openCodeGo)
        #expect(ModelCatalogPartition(provider: .wafer) == .wafer)
        #expect(ModelCatalogPartition(provider: .zai) == .zai)
        #expect(ModelCatalogPartition(provider: .xai) == nil)
    }

    @Test func multiProviderCatalogResolutionBuildsExpectedEntries() {
        var map = OrderedModelMap()
        map["grok-4.5"] = ModelEntry(
            info: ModelInfo(model: "grok-4.5", apiBackend: .responses, provider: .xai)
        )
        map["codex:gpt-5-codex"] = ModelEntry(
            info: ModelInfo(model: "gpt-5-codex", apiBackend: .responses, provider: .codex)
        )
        map["kimi-k3"] = ModelEntry(
            info: ModelInfo(model: "kimi-k3", apiBackend: .chatCompletions, provider: .kimi)
        )
        map["fireworks:glm-5.2"] = ModelEntry(
            info: ModelInfo(model: "accounts/fireworks/models/glm-5p2", apiBackend: .chatCompletions, provider: .fireworks)
        )
        map["deepseek:deepseek-chat"] = ModelEntry(
            info: ModelInfo(model: "deepseek-chat", apiBackend: .chatCompletions, provider: .deepseek)
        )
        map["meta:muse-spark-1.2"] = ModelEntry(
            info: ModelInfo(model: "muse-spark-1.2", apiBackend: .responses, provider: .meta)
        )
        map["opencode:claude-3-7-sonnet"] = ModelEntry(
            info: ModelInfo(model: "anthropic/claude-3-7-sonnet", apiBackend: .chatCompletions, provider: .openCodeGo)
        )
        map["wafer:wafer-v1"] = ModelEntry(
            info: ModelInfo(model: "wafer-v1", apiBackend: .chatCompletions, provider: .wafer)
        )
        map["zai:glm-5.2"] = ModelEntry(
            info: ModelInfo(model: "glm-5.2", apiBackend: .chatCompletions, provider: .zai)
        )

        #expect(map.count == 9)
        #expect(map.providers.count == 9)

        // Typealias ModelCatalog check
        let catalog: ModelCatalog = map
        #expect(catalog["grok-4.5"]?.info.isXai == true)
        #expect(catalog["codex:gpt-5-codex"]?.info.isCodex == true)
        #expect(catalog["kimi-k3"]?.info.isKimi == true)
        #expect(catalog["fireworks:glm-5.2"]?.info.isFireworks == true)
        #expect(catalog["deepseek:deepseek-chat"]?.info.isDeepSeek == true)
        #expect(catalog["meta:muse-spark-1.2"]?.info.isMeta == true)
        #expect(catalog["opencode:claude-3-7-sonnet"]?.info.isOpenCodeGo == true)
        #expect(catalog["wafer:wafer-v1"]?.info.isWafer == true)
        #expect(catalog["zai:glm-5.2"]?.info.isZai == true)
    }
}

// MARK: - Environment Variable Resolution Tests

@Suite("Default Environment Key Resolution")
struct EnvironmentKeyResolutionTests {
    @Test func defaultEnvVarNamesForAllNineProviders() {
        #expect(ModelProvider.xai.defaultEnvVarNames == ["XAI_API_KEY"])
        #expect(ModelProvider.codex.defaultEnvVarNames == ["CODEX_API_KEY"])
        #expect(ModelProvider.kimi.defaultEnvVarNames.contains("KIMI_API_KEY"))
        #expect(ModelProvider.kimi.defaultEnvVarNames.contains("MOONSHOT_API_KEY"))
        #expect(ModelProvider.fireworks.defaultEnvVarNames == ["FIREWORKS_API_KEY"])
        #expect(ModelProvider.deepseek.defaultEnvVarNames == ["DEEPSEEK_API_KEY"])
        #expect(ModelProvider.meta.defaultEnvVarNames == ["META_API_KEY"])
        #expect(ModelProvider.openCodeGo.defaultEnvVarNames.contains("OPENCODE_GO_API_KEY"))
        #expect(ModelProvider.openCodeGo.defaultEnvVarNames.contains("OPENCODE_API_KEY"))
        #expect(ModelProvider.wafer.defaultEnvVarNames == ["WAFER_API_KEY"])
        #expect(ModelProvider.zai.defaultEnvVarNames.contains("ZAI_API_KEY"))
        #expect(ModelProvider.zai.defaultEnvVarNames.contains("GLM_API_KEY"))
    }

    @Test func directKeyResolutionFromEnvironment() {
        let env: [String: String] = [
            "XAI_API_KEY": "xai-secret",
            "CODEX_API_KEY": "codex-secret",
            "KIMI_API_KEY": "kimi-secret",
            "FIREWORKS_API_KEY": "fireworks-secret",
            "DEEPSEEK_API_KEY": "deepseek-secret",
            "META_API_KEY": "meta-secret",
            "OPENCODE_GO_API_KEY": "opencode-go-secret",
            "WAFER_API_KEY": "wafer-secret",
            "ZAI_API_KEY": "zai-secret",
        ]

        #expect(ModelProvider.xai.resolveEnvironmentKey(environment: env) == "xai-secret")
        #expect(ModelProvider.codex.resolveEnvironmentKey(environment: env) == "codex-secret")
        #expect(ModelProvider.kimi.resolveEnvironmentKey(environment: env) == "kimi-secret")
        #expect(ModelProvider.fireworks.resolveEnvironmentKey(environment: env) == "fireworks-secret")
        #expect(ModelProvider.deepseek.resolveEnvironmentKey(environment: env) == "deepseek-secret")
        #expect(ModelProvider.meta.resolveEnvironmentKey(environment: env) == "meta-secret")
        #expect(ModelProvider.openCodeGo.resolveEnvironmentKey(environment: env) == "opencode-go-secret")
        #expect(ModelProvider.wafer.resolveEnvironmentKey(environment: env) == "wafer-secret")
        #expect(ModelProvider.zai.resolveEnvironmentKey(environment: env) == "zai-secret")
    }

    @Test func aliasKeyFallbackResolution() {
        // Test Kimi alias fallback to MOONSHOT_API_KEY
        let kimiFallbackEnv = ["MOONSHOT_API_KEY": "moonshot-key"]
        #expect(ModelProvider.kimi.resolveEnvironmentKey(environment: kimiFallbackEnv) == "moonshot-key")

        // Test OpenCode Go alias fallback to OPENCODE_API_KEY
        let opencodeFallbackEnv = ["OPENCODE_API_KEY": "opencode-key"]
        #expect(ModelProvider.openCodeGo.resolveEnvironmentKey(environment: opencodeFallbackEnv) == "opencode-key")

        // Test Z AI alias fallback to GLM_API_KEY
        let zaiFallbackEnv = ["GLM_API_KEY": "glm-key"]
        #expect(ModelProvider.zai.resolveEnvironmentKey(environment: zaiFallbackEnv) == "glm-key")

        // Primary key precedence over alias
        let bothKimiEnv = ["KIMI_API_KEY": "primary-kimi", "MOONSHOT_API_KEY": "fallback-kimi"]
        #expect(ModelProvider.kimi.resolveEnvironmentKey(environment: bothKimiEnv) == "primary-kimi")

        let bothZaiEnv = ["ZAI_API_KEY": "primary-zai", "GLM_API_KEY": "fallback-zai"]
        #expect(ModelProvider.zai.resolveEnvironmentKey(environment: bothZaiEnv) == "primary-zai")

        let bothOpenCodeEnv = ["OPENCODE_GO_API_KEY": "primary-opencode", "OPENCODE_API_KEY": "fallback-opencode"]
        #expect(ModelProvider.openCodeGo.resolveEnvironmentKey(environment: bothOpenCodeEnv) == "primary-opencode")
    }

    @Test func partitionEnvironmentKeyResolution() {
        let env: [String: String] = [
            "CODEX_API_KEY": "codex-part-key",
            "FIREWORKS_API_KEY": "fw-part-key",
            "DEEPSEEK_API_KEY": "ds-part-key",
            "META_API_KEY": "meta-part-key",
            "WAFER_API_KEY": "wafer-part-key",
            "ZAI_API_KEY": "zai-part-key",
        ]

        #expect(ModelCatalogPartition.codex.resolveEnvironmentKey(environment: env) == "codex-part-key")
        #expect(ModelCatalogPartition.fireworks.resolveEnvironmentKey(environment: env) == "fw-part-key")
        #expect(ModelCatalogPartition.deepSeek.resolveEnvironmentKey(environment: env) == "ds-part-key")
        #expect(ModelCatalogPartition.meta.resolveEnvironmentKey(environment: env) == "meta-part-key")
        #expect(ModelCatalogPartition.wafer.resolveEnvironmentKey(environment: env) == "wafer-part-key")
        #expect(ModelCatalogPartition.zai.resolveEnvironmentKey(environment: env) == "zai-part-key")
    }

    @Test func modelEntryOwnOrProviderCredentialResolution() {
        let env: [String: String] = [
            "XAI_API_KEY": "env-xai-key",
            "CUSTOM_VAR": "custom-var-key",
        ]

        // 1. Own apiKey wins over envKey and provider default
        let entryWithApiKey = ModelEntry(
            info: ModelInfo(model: "grok-4.5", provider: .xai),
            apiKey: "explicit-api-key",
            envKey: .single("CUSTOM_VAR")
        )
        #expect(entryWithApiKey.ownOrProviderCredential(environment: env) == "explicit-api-key")

        // 2. Own envKey wins over provider default
        let entryWithEnvKey = ModelEntry(
            info: ModelInfo(model: "grok-4.5", provider: .xai),
            envKey: .single("CUSTOM_VAR")
        )
        #expect(entryWithEnvKey.ownOrProviderCredential(environment: env) == "custom-var-key")

        // 3. Fallback to provider default envKey
        let entryDefault = ModelEntry(
            info: ModelInfo(model: "grok-4.5", provider: .xai)
        )
        #expect(entryDefault.ownOrProviderCredential(environment: env) == "env-xai-key")
    }
}

// MARK: - Model Capabilities & Limits Tests

@Suite("Model Capability Flags & Limits")
struct ModelCapabilitiesTests {
    @Test func thinkingAndReasoningEffortCapabilities() {
        // Model with supportsReasoningEffort = true
        var grok = ModelInfo(model: "grok-4.5", provider: .xai)
        grok.supportsReasoningEffort = true
        grok.reasoningEfforts = [
            ReasoningEffortOption(id: "low", value: .low, label: "Low", description: nil, isDefault: false),
            ReasoningEffortOption(id: "high", value: .high, label: "High", description: nil, isDefault: true),
        ]
        #expect(grok.supportsThinking == true)

        // Model with explicit reasoningEffort set
        let deepseek = ModelInfo(
            model: "deepseek-reasoner",
            provider: .deepseek,
            reasoningEffort: .high
        )
        #expect(deepseek.supportsThinking == true)

        // Model without reasoning support
        let standard = ModelInfo(model: "basic-model", provider: .xai)
        #expect(standard.supportsThinking == false)
    }

    @Test func visionAndMultimodalCapabilities() {
        let visionModels = [
            "grok-4.5",
            "grok-vision-beta",
            "gpt-4o",
            "gpt-4o-mini",
            "qwen-2.5-vl-72b",
            "anthropic/claude-3-7-sonnet",
        ]
        for slug in visionModels {
            let info = ModelInfo(model: slug, provider: .xai)
            #expect(info.supportsVision == true, "Expected \(slug) to support vision")
        }

        let textOnlyModels = [
            "deepseek-chat",
            "llama-3.3-70b",
            "mistral-large",
        ]
        for slug in textOnlyModels {
            let info = ModelInfo(model: slug, provider: .xai)
            #expect(info.supportsVision == false, "Expected \(slug) to NOT support vision")
        }
    }

    @Test func hostedToolsCapabilities() {
        // xAI responses backend models support hosted tools
        let xaiResponses = ModelInfo(model: "grok-4.5", apiBackend: .responses, provider: .xai)
        #expect(xaiResponses.supportsHostedTools == true)

        // Codex models support hosted tools
        let codexModel = ModelInfo(model: "gpt-5-codex", apiBackend: .responses, provider: .codex)
        #expect(codexModel.supportsHostedTools == true)

        // Model with backend search support
        var metaModel = ModelInfo(model: "muse-spark-1.2", apiBackend: .responses, provider: .meta)
        metaModel.supportsBackendSearch = true
        #expect(metaModel.supportsHostedTools == true)

        // Model with toolMode
        var toolModeModel = ModelInfo(model: "custom-model", provider: .kimi)
        toolModeModel.toolMode = .codeMode
        #expect(toolModeModel.supportsHostedTools == true)
    }

    @Test func contextWindowSizesAndInvariants() {
        // Default context window
        let defaultInfo = ModelInfo(model: "test-model")
        #expect(defaultInfo.contextWindow == 200_000)

        // Explicit context window
        let grok = ModelInfo(model: "grok-4.5", contextWindow: 500_000)
        #expect(grok.contextWindow == 500_000)

        let meta = ModelInfo(model: "muse-spark-1.2", contextWindow: 1_000_000)
        #expect(meta.contextWindow == 1_000_000)

        // Non-zero invariant: 0 becomes max(1, 0) == 1
        let zeroCw = ModelInfo(model: "zero-model", contextWindow: 0)
        #expect(zeroCw.contextWindow == 1)
    }
}

// MARK: - Partition-Scoped Filtering & Custom Model Merging Tests

@Suite("Partition Filtering & Custom Model Merging")
struct PartitionFilteringAndCustomMergingTests {
    private func createTestMultiProviderCatalog() -> OrderedModelMap {
        var map = OrderedModelMap()
        map["grok-4.5"] = ModelEntry(
            info: ModelInfo(model: "grok-4.5", provider: .xai)
        )
        map["grok-4-mini"] = ModelEntry(
            info: ModelInfo(model: "grok-4-mini", provider: .xai)
        )
        map["codex:gpt-5-codex"] = ModelEntry(
            info: ModelInfo(model: "gpt-5-codex", provider: .codex)
        )
        map["kimi-k3"] = ModelEntry(
            info: ModelInfo(model: "kimi-k3", provider: .kimi)
        )
        map["fireworks:glm-5.2"] = ModelEntry(
            info: ModelInfo(model: "glm-5.2", provider: .fireworks)
        )
        map["deepseek:deepseek-chat"] = ModelEntry(
            info: ModelInfo(model: "deepseek-chat", provider: .deepseek)
        )
        map["meta:muse-spark-1.2"] = ModelEntry(
            info: ModelInfo(model: "muse-spark-1.2", provider: .meta)
        )
        map["opencode:claude-3-7-sonnet"] = ModelEntry(
            info: ModelInfo(model: "claude-3-7-sonnet", provider: .openCodeGo)
        )
        map["wafer:wafer-v1"] = ModelEntry(
            info: ModelInfo(model: "wafer-v1", provider: .wafer)
        )
        map["zai:glm-5.2"] = ModelEntry(
            info: ModelInfo(model: "glm-5.2", provider: .zai)
        )
        return map
    }

    @Test func partitionScopedModelFiltering() {
        let catalog = createTestMultiProviderCatalog()

        let xaiModels = catalog.models(for: .xai)
        #expect(xaiModels.count == 2)
        #expect(xaiModels.allSatisfy { $0.info.isXai })

        let codexModels = catalog.models(for: .codex)
        #expect(codexModels.count == 1)
        #expect(codexModels.first?.info.isCodex == true)

        let deepSeekModels = catalog.models(forPartition: .deepSeek)
        #expect(deepSeekModels.count == 1)
        #expect(deepSeekModels.first?.info.isDeepSeek == true)

        let metaModels = catalog.models(forPartition: .meta)
        #expect(metaModels.count == 1)
        #expect(metaModels.first?.info.isMeta == true)

        let zaiModels = catalog.models(forPartition: .zai)
        #expect(zaiModels.count == 1)
        #expect(zaiModels.first?.info.isZai == true)

        let xaiByKind = catalog.models(forKind: .xai)
        #expect(xaiByKind.count == 2)
    }

    @Test func customModelMergingIntoCatalogMap() {
        var catalog = createTestMultiProviderCatalog()
        let initialCount = catalog.count

        let custom1 = CustomModelEntry(
            key: "my-ollama-llama",
            modelId: "llama3.3:latest",
            provider: "xai",
            baseUrl: "http://localhost:11434/v1",
            contextWindow: 128_000,
            maxOutputTokens: 8192
        )
        let custom2 = CustomModelEntry(
            key: "deepseek:deepseek-chat", // Overwrite existing key
            modelId: "deepseek-chat-custom-routing",
            provider: "deepseek",
            contextWindow: 64_000
        )

        catalog.merge(customModels: [custom1, custom2])

        // Total count increased by 1 (1 added, 1 overwritten)
        #expect(catalog.count == initialCount + 1)

        // Verify newly added custom model
        let added = catalog["my-ollama-llama"]
        #expect(added != nil)
        #expect(added?.info.model == "llama3.3:latest")
        #expect(added?.info.baseURL == "http://localhost:11434/v1")
        #expect(added?.info.contextWindow == 128_000)
        #expect(added?.info.maxCompletionTokens == 8192)

        // Verify overwritten entry
        let overwritten = catalog["deepseek:deepseek-chat"]
        #expect(overwritten != nil)
        #expect(overwritten?.info.model == "deepseek-chat-custom-routing")
        #expect(overwritten?.info.contextWindow == 64_000)

        // Verify other provider entries were not dropped or corrupted
        #expect(catalog["grok-4.5"]?.info.provider == .xai)
        #expect(catalog["codex:gpt-5-codex"]?.info.provider == .codex)
        #expect(catalog["meta:muse-spark-1.2"]?.info.provider == .meta)
        #expect(catalog["zai:glm-5.2"]?.info.provider == .zai)
    }

    @Test func customModelMergingIntoModelInfoArray() {
        var infos: [ModelInfo] = [
            ModelInfo(model: "grok-4.5", provider: .xai),
            ModelInfo(id: "deepseek:deepseek-chat", model: "deepseek-chat", provider: .deepseek),
        ]

        let custom1 = CustomModelEntry(
            key: "my-custom-model",
            modelId: "custom-v1",
            provider: "zai"
        )
        let custom2 = CustomModelEntry(
            key: "deepseek:deepseek-chat",
            modelId: "deepseek-chat-v2",
            provider: "deepseek"
        )

        infos.merge(customModels: [custom1, custom2])

        #expect(infos.count == 3)
        #expect(infos.contains(where: { ($0.id ?? $0.model) == "my-custom-model" }))
        #expect(infos.first(where: { ($0.id ?? $0.model) == "deepseek:deepseek-chat" })?.model == "deepseek-chat-v2")
    }

    @Test func resolveModelCatalogWithCustomModelsPipeline() {
        let input = CatalogResolutionInput.default
        let custom = CustomModelEntry(
            key: "custom-pipeline-model",
            modelId: "pipeline-v1",
            provider: "xai",
            contextWindow: 150_000
        )

        let catalog = resolveModelCatalog(
            input: input,
            customModels: [custom]
        )

        #expect(catalog.contains("custom-pipeline-model"))
        let entry = catalog["custom-pipeline-model"]
        #expect(entry?.info.contextWindow == 150_000)
        #expect(entry?.info.userSelectable == true)
    }
}
