// CustomModelStoreTests.swift
//
// Open Grok — Tests for CustomModelEntry and CustomModelStore.

import Foundation
import OpenGrokModels
import OpenGrokSamplingTypes
import Testing

@Suite("Custom Model Store Tests")
struct CustomModelStoreTests {

    private func makeTemporaryFileURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let unique = UUID().uuidString
        return tempDir.appendingPathComponent("custom_models_test_\(unique).json")
    }

    // MARK: - Codable & Equatable

    @Test("CustomModelEntry Codable round-trip and decoding flexibility")
    func testCustomModelEntryCodable() throws {
        let entry = CustomModelEntry(
            key: "zai:glm-4.v1",
            modelId: "glm-4-plus",
            provider: "zai",
            baseUrl: "https://open.bigmodel.cn/api/paas/v4",
            contextWindow: 128_000,
            maxOutputTokens: 4096,
            reasoningEfforts: ["low", "medium", "high"]
        )

        #expect(entry.id == "zai:glm-4.v1")

        // Round-trip encode/decode
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entry)
        let decoded = try JSONDecoder().decode(CustomModelEntry.self, from: data)
        #expect(decoded == entry)

        // Decode from camelCase JSON
        let camelJSON = """
        {
            "key": "custom-gpt",
            "modelId": "gpt-4o",
            "provider": "codex",
            "baseUrl": "https://api.openai.com/v1",
            "contextWindow": 128000,
            "maxOutputTokens": 4096,
            "reasoningEfforts": ["medium"]
        }
        """.data(using: .utf8)!

        let camelDecoded = try JSONDecoder().decode(CustomModelEntry.self, from: camelJSON)
        #expect(camelDecoded.key == "custom-gpt")
        #expect(camelDecoded.modelId == "gpt-4o")
        #expect(camelDecoded.provider == "codex")
        #expect(camelDecoded.baseUrl == "https://api.openai.com/v1")
        #expect(camelDecoded.contextWindow == 128000)
        #expect(camelDecoded.maxOutputTokens == 4096)
        #expect(camelDecoded.reasoningEfforts == ["medium"])

        // Decode with legacy aliases (model, max_completion_tokens)
        let aliasJSON = """
        {
            "key": "alias-model",
            "model": "deepseek-coder",
            "provider": "deepseek",
            "max_completion_tokens": 8192
        }
        """.data(using: .utf8)!

        let aliasDecoded = try JSONDecoder().decode(CustomModelEntry.self, from: aliasJSON)
        #expect(aliasDecoded.key == "alias-model")
        #expect(aliasDecoded.modelId == "deepseek-coder")
        #expect(aliasDecoded.provider == "deepseek")
        #expect(aliasDecoded.maxOutputTokens == 8192)
        #expect(aliasDecoded.contextWindow == nil)
    }

    // MARK: - Validation

    @Test("Validation rules for custom model keys, IDs, and numeric limits")
    func testValidationRules() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = CustomModelStore(fileURL: fileURL)

        // Empty key
        await #expect(throws: CustomModelStoreError.emptyKey) {
            try await store.upsertCustomModel(CustomModelEntry(key: "  ", modelId: "m1"))
        }

        // Empty model ID
        await #expect(throws: CustomModelStoreError.emptyModelId) {
            try await store.upsertCustomModel(CustomModelEntry(key: "k1", modelId: "  "))
        }

        // Key with newlines
        await #expect(throws: CustomModelStoreError.keyContainsNewlines) {
            try await store.upsertCustomModel(CustomModelEntry(key: "k1\nk2", modelId: "m1"))
        }

        // Model ID with newlines
        await #expect(throws: CustomModelStoreError.modelIdContainsNewlines) {
            try await store.upsertCustomModel(CustomModelEntry(key: "k1", modelId: "m1\r\nm2"))
        }

        // Invalid key characters (slashes, spaces, @)
        await #expect(throws: CustomModelStoreError.self) {
            try await store.upsertCustomModel(CustomModelEntry(key: "foo/bar", modelId: "m1"))
        }
        await #expect(throws: CustomModelStoreError.self) {
            try await store.upsertCustomModel(CustomModelEntry(key: "foo bar", modelId: "m1"))
        }

        // Invalid context window (<= 0)
        await #expect(throws: CustomModelStoreError.invalidContextWindow(0)) {
            try await store.upsertCustomModel(CustomModelEntry(key: "k1", modelId: "m1", contextWindow: 0))
        }

        // Invalid max output tokens (<= 0)
        await #expect(throws: CustomModelStoreError.invalidMaxOutputTokens(-10)) {
            try await store.upsertCustomModel(CustomModelEntry(key: "k1", modelId: "m1", maxOutputTokens: -10))
        }

        await #expect(throws: CustomModelStoreError.invalidProvider("anthropic")) {
            try await store.upsertCustomModel(
                CustomModelEntry(key: "custom-claude", modelId: "claude", provider: "anthropic")
            )
        }

        // Valid complex key is accepted
        let validEntry = CustomModelEntry(key: "zai:glm-4.v1_alpha-2", modelId: "glm-4")
        try await store.upsertCustomModel(validEntry)
        let fetched = await store.getCustomModel(key: "zai:glm-4.v1_alpha-2")
        #expect(fetched?.modelId == "glm-4")
    }

    @Test("provider aliases normalize to their canonical persisted identity")
    func providerAliasesAreCanonicalized() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = CustomModelStore(fileURL: fileURL)

        try await store.upsertCustomModel(CustomModelEntry(
            key: "meta:spark",
            modelId: "muse-spark",
            provider: " META_API "
        ))

        let persisted = try #require(await store.getCustomModel(key: "meta:spark"))
        #expect(persisted.provider == "meta")
        #expect(persisted.toModelInfo().provider == .meta)
    }

    @Test("Wafer and Z AI custom models inherit routable endpoints and key names")
    func apiKeyProviderModelsInheritRequiredDefaults() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = CustomModelStore(fileURL: fileURL)

        try await store.upsertCustomModel(CustomModelEntry(
            key: "wafer:custom",
            modelId: "custom-wafer",
            provider: "wafer_ai"
        ))
        try await store.upsertCustomModel(CustomModelEntry(
            key: "zai:custom",
            modelId: "custom-glm",
            provider: "z-ai"
        ))

        let wafer = try #require(await store.getCustomModel(key: "wafer:custom"))
        #expect(wafer.baseUrl == WaferModels.apiBaseURL())
        #expect(wafer.toModelEntry().envKey?.primary == WaferModels.apiKeyEnv)
        #expect(wafer.toConfigModelOverride().envKey?.primary == WaferModels.apiKeyEnv)

        let zai = try #require(await store.getCustomModel(key: "zai:custom"))
        #expect(zai.baseUrl == ZaiModels.apiBaseURL())
        #expect(zai.toModelEntry().envKey?.primary == ZaiModels.apiKeyEnv)
        #expect(zai.toConfigModelOverride().envKey?.primary == ZaiModels.apiKeyEnv)
    }

    @Test("persisted custom models project into synchronous session catalog overrides")
    func persistedModelsBecomeSynchronousCatalogOverrides() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-model-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = CustomModelStore(grokHome: home)
        try await store.upsertCustomModel(CustomModelEntry(
            key: "zai:live-custom",
            modelId: "glm-live-custom",
            provider: "zai",
            contextWindow: 128_000
        ))

        let overrides = try loadCustomModelOverrides(grokHome: home)
        #expect(overrides.count == 1)
        let (key, override) = try #require(overrides.first)
        #expect(key == "zai:live-custom")
        #expect(override.provider == .zai)
        #expect(override.baseURL == ZaiModels.apiBaseURL())
        #expect(override.envKey?.primary == ZaiModels.apiKeyEnv)

        let catalog = resolveModelCatalog(input: CatalogResolutionInput(configModels: overrides))
        #expect(catalog[key]?.info.model == "glm-live-custom")
        #expect(catalog[key]?.info.provider == .zai)
    }

    @Test("unknown custom providers cannot enter a catalog through direct merging")
    func unknownProvidersCannotBeMergedAsXAI() {
        let poisoned = CustomModelEntry(
            key: "poisoned-model",
            modelId: "foreign-model",
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com/v1"
        )
        var map = OrderedModelMap()
        var infos: [ModelInfo] = []
        var entries: [ModelEntry] = []

        CustomModelStore.mergeCustomModels([poisoned], into: &map)
        CustomModelStore.mergeCustomModels([poisoned], into: &infos)
        CustomModelStore.mergeCustomModels([poisoned], into: &entries)
        map.merge(customModels: [poisoned])
        infos.merge(customModels: [poisoned])
        entries.merge(customModels: [poisoned])

        #expect(map.isEmpty)
        #expect(infos.isEmpty)
        #expect(entries.isEmpty)
    }

    @Test("corrupt persisted custom models cannot be silently replaced")
    func corruptedStoreCannotBeOverwritten() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let original = "{ not valid custom model JSON"
        try original.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = CustomModelStore(fileURL: fileURL)

        await #expect(throws: CustomModelStoreError.self) {
            try await store.upsertCustomModel(CustomModelEntry(key: "new-model", modelId: "m1"))
        }
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == original)
    }

    // MARK: - CRUD Workflow

    @Test("Full CRUD operations on CustomModelStore")
    func testStoreCRUD() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = CustomModelStore(fileURL: fileURL)

        // Initially empty
        let initial = await store.listCustomModels()
        #expect(initial.isEmpty)

        // Upsert first model
        let model1 = CustomModelEntry(
            key: "ollama-llama3",
            modelId: "llama3:8b",
            provider: "xai",
            baseUrl: "http://localhost:11434/v1",
            contextWindow: 64_000
        )
        try await store.upsertCustomModel(model1)

        var list = await store.listCustomModels()
        #expect(list.count == 1)
        #expect(list.first?.key == "ollama-llama3")

        // Upsert second model
        let model2 = CustomModelEntry(
            key: "fireworks:mixtral",
            modelId: "accounts/fireworks/models/mixtral-8x7b-instruct",
            provider: "fireworks",
            maxOutputTokens: 2048,
            reasoningEfforts: ["low", "high"]
        )
        try await store.upsertCustomModel(model2)

        list = await store.listCustomModels()
        #expect(list.count == 2)

        // Query by key
        let fetched1 = await store.getCustomModel(key: "ollama-llama3")
        #expect(fetched1?.modelId == "llama3:8b")
        #expect(fetched1?.baseUrl == "http://localhost:11434/v1")

        let nonExistent = await store.getCustomModel(key: "does-not-exist")
        #expect(nonExistent == nil)

        // Update model 1
        let updatedModel1 = CustomModelEntry(
            key: "ollama-llama3",
            modelId: "llama3:70b",
            provider: "xai",
            baseUrl: "http://localhost:11434/v1",
            contextWindow: 128_000
        )
        try await store.upsertCustomModel(updatedModel1)

        list = await store.listCustomModels()
        #expect(list.count == 2)
        let reFetched1 = await store.getCustomModel(key: "ollama-llama3")
        #expect(reFetched1?.modelId == "llama3:70b")
        #expect(reFetched1?.contextWindow == 128_000)

        // Delete model 2
        let deleted = try await store.deleteCustomModel(key: "fireworks:mixtral")
        #expect(deleted == true)

        list = await store.listCustomModels()
        #expect(list.count == 1)
        #expect(list.first?.key == "ollama-llama3")

        // Delete non-existent
        let deletedAgain = try await store.deleteCustomModel(key: "fireworks:mixtral")
        #expect(deletedAgain == false)

        // Clear all
        try await store.clearAll()
        let cleared = await store.listCustomModels()
        #expect(cleared.isEmpty)
    }

    // MARK: - Persistence across instances

    @Test("Persistence survives across different CustomModelStore instances")
    func testPersistenceAcrossInstances() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Instance 1: write 2 models
        let store1 = CustomModelStore(fileURL: fileURL)
        try await store1.upsertCustomModel(CustomModelEntry(key: "model-a", modelId: "slug-a", provider: "zai"))
        try await store1.upsertCustomModel(CustomModelEntry(key: "model-b", modelId: "slug-b", provider: "wafer"))

        // Instance 2: read from the same file
        let store2 = CustomModelStore(fileURL: fileURL)
        let loaded = await store2.listCustomModels()
        #expect(loaded.count == 2)
        #expect(loaded.contains(where: { $0.key == "model-a" && $0.provider == "zai" }))
        #expect(loaded.contains(where: { $0.key == "model-b" && $0.provider == "wafer" }))

        // Instance 2: delete one
        try await store2.deleteCustomModel(key: "model-a")

        // Instance 3: verify deletion on disk
        let store3 = CustomModelStore(fileURL: fileURL)
        let finalLoaded = await store3.listCustomModels()
        #expect(finalLoaded.count == 1)
        #expect(finalLoaded.first?.key == "model-b")
    }

    // MARK: - Model Conversion & Overrides

    @Test("Conversion of CustomModelEntry to ModelInfo, ModelEntry, and ConfigModelOverride")
    func testModelConversion() {
        let entry = CustomModelEntry(
            key: "custom-openai",
            modelId: "gpt-4.5-preview",
            provider: "codex",
            baseUrl: "https://api.openai.com/v1",
            contextWindow: 128_000,
            maxOutputTokens: 16_384,
            reasoningEfforts: ["low", "medium", "high"]
        )

        let info = entry.toModelInfo()
        #expect(info.id == "custom-openai")
        #expect(info.model == "gpt-4.5-preview")
        #expect(info.provider == .codex)
        #expect(info.apiBackend == .responses)
        #expect(info.baseURL == "https://api.openai.com/v1")
        #expect(info.contextWindow == 128_000)
        #expect(info.maxCompletionTokens == 16_384)
        #expect(info.supportsReasoningEffort == true)
        #expect(info.reasoningEfforts.count == 3)

        let modelEntry = entry.toModelEntry()
        #expect(modelEntry.info == info)
        #expect(modelEntry.model == "gpt-4.5-preview")

        let configOverride = entry.toConfigModelOverride()
        #expect(configOverride.model == "gpt-4.5-preview")
        #expect(configOverride.baseURL == "https://api.openai.com/v1")
        #expect(configOverride.provider == .codex)
        #expect(configOverride.contextWindow == 128_000)
    }

    // MARK: - Catalog Merging

    @Test("Merging custom models into ModelInfo and OrderedModelMap catalogs")
    func testCatalogMerging() {
        var catalog: [ModelInfo] = [
            ModelInfo(id: "grok-3", model: "grok-3", baseURL: "https://api.x.ai", provider: .xai),
            ModelInfo(id: "gpt-4o", model: "gpt-4o", baseURL: "https://api.openai.com", provider: .codex)
        ]

        let customModels: [CustomModelEntry] = [
            // Overrides existing "grok-3"
            CustomModelEntry(key: "grok-3", modelId: "grok-3-custom", provider: "xai", baseUrl: "https://custom.x.ai", contextWindow: 500_000),
            // Adds new "custom-claude"
            CustomModelEntry(key: "custom-claude", modelId: "claude-3-5-sonnet", provider: "xai", baseUrl: "https://api.anthropic.com")
        ]

        CustomModelStore.mergeCustomModels(customModels, into: &catalog)

        #expect(catalog.count == 3)

        let grok3 = catalog.first(where: { $0.id == "grok-3" })
        #expect(grok3 != nil)
        #expect(grok3?.model == "grok-3-custom")
        #expect(grok3?.baseURL == "https://custom.x.ai")
        #expect(grok3?.contextWindow == 500_000)

        let claude = catalog.first(where: { $0.id == "custom-claude" })
        #expect(claude != nil)
        #expect(claude?.model == "claude-3-5-sonnet")

        // Test OrderedModelMap merge
        var map = OrderedModelMap()
        map["base-model"] = ModelEntry(info: ModelInfo(model: "base-model"))
        CustomModelStore.mergeCustomModels(customModels, into: &map)

        #expect(map.count == 3)
        #expect(map["grok-3"]?.info.model == "grok-3-custom")
        #expect(map["custom-claude"]?.info.model == "claude-3-5-sonnet")
    }

    // MARK: - Edge Cases

    @Test("Handling of corrupted and dictionary-formatted files")
    func testEdgeCases() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Corrupted JSON
        try "not valid json".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = CustomModelStore(fileURL: fileURL)
        let models = await store.listCustomModels()
        #expect(models.isEmpty)

        // Dictionary JSON format
        let dictJSON = """
        {
            "entry1": {
                "key": "entry1",
                "model_id": "model-1",
                "provider": "zai"
            },
            "entry2": {
                "key": "entry2",
                "model_id": "model-2",
                "provider": "wafer"
            }
        }
        """
        try dictJSON.write(to: fileURL, atomically: true, encoding: .utf8)
        let dictStore = CustomModelStore(fileURL: fileURL)
        let dictModels = await dictStore.listCustomModels()
        #expect(dictModels.count == 2)
        #expect(dictModels.contains(where: { $0.key == "entry1" }))
        #expect(dictModels.contains(where: { $0.key == "entry2" }))
    }
}
