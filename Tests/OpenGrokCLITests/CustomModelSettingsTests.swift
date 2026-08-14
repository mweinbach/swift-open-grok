import Foundation
import OpenGrokModels
import OpenGrokPagerRender
import OpenGrokSessionRuntime
import Testing
@testable import OpenGrokCLI

private final class MockSettingsSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes: [UInt8]) throws {}
    func flush() throws {}
}

private func makeRenderer(home: URL) -> LiveInteractiveControllerRenderer {
    let terminal = OpenGrokLiveTerminal(
        isTTY: { false },
        size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
        write: { _ in }
    )
    return LiveInteractiveControllerRenderer(
        mode: .fullScreen,
        terminal: terminal,
        sink: MockSettingsSink(),
        workingDirectory: home.path,
        modelName: "test-model",
        sessionID: "custom-model-settings-test",
        openGrokHome: home,
        environment: [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ]
    )
}

@Suite("Custom model settings & cold-start cache rendering tests")
struct CustomModelSettingsTests {

    @Test("Custom model draft updates and clamping")
    func draftUpdatesAndClamping() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "custom-models-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var store = PagerSettingsStore(
            configPath: tempDir.appendingPathComponent("config.toml")
        )
        store.clearDraft()

        store.updateDraft(key: "custom_model_id", value: .string("zai:glm-special"))
        store.updateDraft(key: "custom_model_slug", value: .string("glm-4-special"))
        store.updateDraft(key: "custom_model_name", value: .string("GLM Special"))
        store.updateDraft(key: "custom_model_provider", value: .string("zai"))
        store.updateDraft(key: "custom_model_base_url", value: .string("https://api.z.ai/v1"))
        store.updateDraft(key: "custom_model_context_window", value: .integer(500)) // Below minimum (1,000)
        store.updateDraft(key: "custom_model_backend", value: .string("chat_completions"))
        store.updateDraft(key: "custom_model_env_key", value: .string("ZAI_CUSTOM_KEY"))

        var draft = store.getDraft()
        #expect(draft.id == "zai:glm-special")
        #expect(draft.slug == "glm-4-special")
        #expect(draft.name == "GLM Special")
        #expect(draft.provider == "zai")
        #expect(draft.baseUrl == "https://api.z.ai/v1")
        #expect(draft.contextWindow == 1_000) // Clamped to min
        #expect(draft.backend == "chat_completions")
        #expect(draft.envKey == "ZAI_CUSTOM_KEY")

        // Test upper bound clamping
        store.updateDraft(key: "custom_model_context_window", value: .integer(10_000_000))
        draft = store.getDraft()
        #expect(draft.contextWindow == 4_000_000)

        // Test clearing draft
        store.clearDraft()
        let cleared = store.getDraft()
        #expect(cleared.id == "")
        #expect(cleared.slug == "")
        #expect(cleared.contextWindow == 200_000)
    }

    @Test("Custom model validation rejects invalid keys and slugs")
    func validationRejection() {
        // Empty key
        #expect(throws: PagerSettingsStoreError.emptyCustomModelKey) {
            try PagerSettingsStore.validateCustomModelKey("")
        }

        // Key with newlines
        #expect(throws: PagerSettingsStoreError.customModelKeyContainsNewlines) {
            try PagerSettingsStore.validateCustomModelKey("bad\nkey")
        }

        // Key with invalid characters
        #expect(throws: PagerSettingsStoreError.invalidCustomModelKeyCharacters("bad key with spaces")) {
            try PagerSettingsStore.validateCustomModelKey("bad key with spaces")
        }
        #expect(throws: PagerSettingsStoreError.invalidCustomModelKeyCharacters("key@invalid!")) {
            try PagerSettingsStore.validateCustomModelKey("key@invalid!")
        }

        // Valid keys (letters, digits, :, ., -, _)
        #expect(throws: Never.self) {
            try PagerSettingsStore.validateCustomModelKey("zai:glm-4.extra_1")
            try PagerSettingsStore.validateCustomModelKey("my-ollama.model:v1")
        }

        // Empty slug
        #expect(throws: PagerSettingsStoreError.emptyCustomModelSlug) {
            try PagerSettingsStore.validateCustomModelSlug("")
        }

        // Slug with newlines
        #expect(throws: PagerSettingsStoreError.customModelSlugContainsNewlines) {
            try PagerSettingsStore.validateCustomModelSlug("slug\nwith\nnewlines")
        }

        // Valid slug
        #expect(throws: Never.self) {
            try PagerSettingsStore.validateCustomModelSlug("glm-4-plus:latest")
        }
    }

    @Test("Save custom model writes to custom_models.json and clears draft")
    func saveCustomModelPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "custom-models-save-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var store = PagerSettingsStore(
            configPath: tempDir.appendingPathComponent("config.toml")
        )
        store.clearDraft()

        store.updateDraft(key: "custom_model_id", value: .string("wafer:custom-model"))
        store.updateDraft(key: "custom_model_slug", value: .string("wafer-v1"))
        store.updateDraft(key: "custom_model_provider", value: .string("wafer"))
        store.updateDraft(key: "custom_model_context_window", value: .integer(128_000))

        let record = try store.saveCustomModelDraft()
        #expect(record.key == "wafer:custom-model")
        #expect(record.modelId == "wafer-v1")
        #expect(record.provider == "wafer")
        #expect(record.contextWindow == 128_000)

        // Draft must be cleared after save
        let draftAfter = store.getDraft()
        #expect(draftAfter.id == "")
        #expect(draftAfter.slug == "")

        // Verify loaded from file
        let loaded = try store.loadCustomModels()
        #expect(loaded.count == 1)
        #expect(loaded.first?.key == "wafer:custom-model")
        #expect(loaded.first?.modelId == "wafer-v1")

        // Saving another model appends to the list
        store.updateDraft(key: "custom_model_id", value: .string("zai:extra"))
        store.updateDraft(key: "custom_model_slug", value: .string("glm-extra"))
        store.updateDraft(key: "custom_model_provider", value: .string("zai"))
        try store.saveCustomModelDraft()

        let updatedList = try store.loadCustomModels()
        #expect(updatedList.count == 2)
        #expect(updatedList.map(\.key).sorted() == ["wafer:custom-model", "zai:extra"])
    }

    @Test("Delete custom model removes from custom_models.json")
    func deleteCustomModel() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "custom-models-delete-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var store = PagerSettingsStore(
            configPath: tempDir.appendingPathComponent("config.toml")
        )
        store.clearDraft()

        store.updateDraft(key: "custom_model_id", value: .string("model-to-delete"))
        store.updateDraft(key: "custom_model_slug", value: .string("slug-1"))
        try store.saveCustomModelDraft()

        store.updateDraft(key: "custom_model_id", value: .string("model-to-keep"))
        store.updateDraft(key: "custom_model_slug", value: .string("slug-2"))
        try store.saveCustomModelDraft()

        #expect((try store.loadCustomModels()).count == 2)

        let deleted = try store.deleteCustomModel(key: "model-to-delete")
        #expect(deleted == true)

        let remaining = try store.loadCustomModels()
        #expect(remaining.count == 1)
        #expect(remaining.first?.key == "model-to-keep")

        // Deleting non-existent returns false
        let deletedNonExistent = try store.deleteCustomModel(key: "non-existent")
        #expect(deletedNonExistent == false)

        // MultiSelect deselect deletes
        try store.writeMultiSelect(key: "custom_models.list", enabled: [])
        #expect((try store.loadCustomModels()).isEmpty)
    }

    @Test("Cold start cache telemetry rendering for Turn #1")
    func coldStartTelemetryRendering() {
        let resp = SessionCacheResponse(
            summary: SessionCacheSnapshot(
                cacheHitRate: 0.0,
                totalPromptTokens: 2500,
                cachedTokens: 200,
                breakEvents: [],
                totalTurns: 1,
                hits: 0,
                partialHits: 0,
                breaks: 0,
                steadyPromptTokens: 0,
                steadyCachedTokens: 0,
                lastBreakDiagnostic: nil
            ),
            recentTurns: [
                LiveInteractiveControllerRenderer.makeTurnRecord(
                    turnIdx: "1",
                    loopIndex: 0,
                    promptTokens: 2500,
                    cachedPromptTokens: 200,
                    completionTokens: 150,
                    status: .firstTurn,
                    divergence: .firstTurn,
                    diagnostic: "First turn in session (cold cache)."
                )
            ]
        )

        let text = LiveInteractiveControllerRenderer.sessionCacheBlockText(resp)
        #expect(text.contains("Cache hit rate: n/a (cold-start request only so far)"))
        #expect(text.contains("Turn #1 (loop 0) — cold start (2,500 in)"))
        #expect(!text.contains("% hit ("))
    }

    @Test("Steady-state cache telemetry rendering with intact prefix diagnostic")
    func steadyStateAndIntactPrefixRendering() {
        let resp = SessionCacheResponse(
            summary: SessionCacheSnapshot(
                cacheHitRate: 85.0,
                totalPromptTokens: 10000,
                cachedTokens: 6575,
                breakEvents: [],
                totalTurns: 2,
                hits: 1,
                partialHits: 0,
                breaks: 0,
                steadyPromptTokens: 7500,
                steadyCachedTokens: 6375,
                lastBreakDiagnostic: nil
            ),
            recentTurns: [
                LiveInteractiveControllerRenderer.makeTurnRecord(
                    turnIdx: "1",
                    loopIndex: 0,
                    promptTokens: 2500,
                    cachedPromptTokens: 200,
                    completionTokens: 150,
                    status: .firstTurn,
                    divergence: .firstTurn,
                    diagnostic: "First turn in session (cold cache)."
                ),
                LiveInteractiveControllerRenderer.makeTurnRecord(
                    turnIdx: "2",
                    loopIndex: 0,
                    promptTokens: 7500,
                    cachedPromptTokens: 6375,
                    completionTokens: 200,
                    status: .hit,
                    divergence: .prefixIntact(preservedItems: 2, newItems: 1)
                )
            ]
        )

        let text = LiveInteractiveControllerRenderer.sessionCacheBlockText(resp)
        #expect(text.contains("Cache hit rate: 85.0% (6,375 of 7,500 steady-state input tokens cached; cold start excluded)"))
        #expect(text.contains("Turns tracked:  2 (1 hits · 0 partial · 0 breaks)"))
        #expect(text.contains("Turn #2 (loop 0) — 85.0% hit (7,500 in, 6,375 cached)"))
        #expect(text.contains("Remaining tokens are new content appended since the previous request."))
    }

    @Test("Session usage text renders n/a for cold-start only turn 1")
    func sessionUsageColdStartRendering() {
        let usageTextColdStart = LiveInteractiveControllerRenderer.sessionUsageBlockText(
            turnCount: 1,
            estimatedTokens: 2500,
            cacheHitRatePct: nil,
            isColdStartOnly: true
        )
        #expect(usageTextColdStart.contains("Cache hit rate: n/a (cold-start request only so far)"))

        let usageTextSteadyState = LiveInteractiveControllerRenderer.sessionUsageBlockText(
            turnCount: 3,
            estimatedTokens: 8000,
            cacheHitRatePct: 92.5,
            isColdStartOnly: false
        )
        #expect(usageTextSteadyState.contains("Cache hit rate: 92.5%"))
    }

    @Test("Live settings events wiring for custom model save and delete")
    func liveSettingsEventsWiring() async throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            "custom-models-live-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let renderer = makeRenderer(home: tempHome)

        // Set draft fields via settings event
        await renderer.applySettingsEvent(.commit(key: "custom_model_id", value: .string("zai:test-key")))
        await renderer.applySettingsEvent(.commit(key: "custom_model_slug", value: .string("glm-test")))
        await renderer.applySettingsEvent(.commit(key: "custom_model_provider", value: .string("zai")))

        let store = PagerSettingsStore(configPath: tempHome.appendingPathComponent("config.toml"))
        let draft = store.getDraft()
        #expect(draft.id == "zai:test-key")
        #expect(draft.slug == "glm-test")
        #expect(draft.provider == "zai")

        // Save custom model via commit(key: "custom_model_save", value: .bool(true))
        await renderer.applySettingsEvent(.commit(key: "custom_model_save", value: .bool(true)))

        let customStore = CustomModelStore(grokHome: tempHome)
        let savedModels = await customStore.listCustomModels()
        #expect(savedModels.contains(where: { $0.key == "zai:test-key" && $0.modelId == "glm-test" }))

        // Uncheck / delete via toggleMultiSelect
        await renderer.applySettingsEvent(.toggleMultiSelect(key: "custom_models.list", choice: "zai:test-key", enabled: false))
        let afterDelete = try await customStore.reloadFromDisk()
        #expect(!afterDelete.contains(where: { $0.key == "zai:test-key" }))
    }
}
