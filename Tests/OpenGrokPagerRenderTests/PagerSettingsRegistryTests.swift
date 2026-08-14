// PagerSettingsRegistryTests.swift
//
// Unit tests for Custom Models settings catalog entries and validation in OpenGrokPagerRender.
// Reference: crates/codegen/xai-grok-pager/src/settings/defs.rs and registry.rs (commit d8b8db24).

import Foundation
import Testing
@testable import OpenGrokPagerRender

@Suite("Custom models settings registry")
struct PagerSettingsCustomModelsRegistryTests {
    @Test("Custom model constants and choices are correctly defined")
    func customModelConstants() {
        #expect(CUSTOM_MODEL_CONTEXT_WINDOW_MIN == 1_000)
        #expect(CUSTOM_MODEL_CONTEXT_WINDOW_MAX == 4_000_000)
        #expect(CUSTOM_MODEL_CONTEXT_WINDOW_DEFAULT == 200_000)

        let providerCanonicals = CUSTOM_MODEL_PROVIDER_CHOICES.map(\.canonical)
        #expect(providerCanonicals.contains(""))
        #expect(providerCanonicals.contains("xai"))
        #expect(providerCanonicals.contains("codex"))
        #expect(providerCanonicals.contains("kimi"))
        #expect(providerCanonicals.contains("kimi_code"))
        #expect(providerCanonicals.contains("fireworks"))
        #expect(providerCanonicals.contains("deepseek"))
        #expect(providerCanonicals.contains("wafer"))
        #expect(providerCanonicals.contains("zai"))

        let backendCanonicals = CUSTOM_MODEL_BACKEND_CHOICES.map(\.canonical)
        #expect(backendCanonicals.contains(""))
        #expect(backendCanonicals.contains("chat_completions"))
        #expect(backendCanonicals.contains("responses"))
        #expect(backendCanonicals.contains("messages"))

        #expect(PagerSettingChoices.customModelProvider == CUSTOM_MODEL_PROVIDER_CHOICES)
        #expect(PagerSettingChoices.customModelBackend == CUSTOM_MODEL_BACKEND_CHOICES)
    }

    @Test("custom_models group row is registered with all 10 children")
    func customModelsGroupRegistered() throws {
        let registry = PagerSettingsRegistry.default
        let groupMeta = try #require(registry.find("custom_models"))
        #expect(groupMeta.category == .models)
        #expect(groupMeta.label == "Custom models")
        #expect(groupMeta.storage == .sessionLocal)

        guard case .group(let children) = groupMeta.kind else {
            Issue.record("custom_models must be a group kind, got \(groupMeta.kind)")
            return
        }
        #expect(children == [
            "custom_models.list",
            "custom_model_id",
            "custom_model_slug",
            "custom_model_name",
            "custom_model_provider",
            "custom_model_base_url",
            "custom_model_context_window",
            "custom_model_backend",
            "custom_model_env_key",
            "custom_model_save"
        ])
    }

    @Test("all 10 custom model child entries are registered with correct types and bounds")
    func customModelChildrenMetadata() throws {
        let registry = PagerSettingsRegistry.default

        // 1. custom_models.list: dynamicMultiSelect(.customModels)
        let listMeta = try #require(registry.find("custom_models.list"))
        #expect(listMeta.category == .models)
        #expect(listMeta.label == "Saved custom models")
        #expect(listMeta.kind == .dynamicMultiSelect(source: .customModels))

        // 2. custom_model_id: String (Catalog key)
        let idMeta = try #require(registry.find("custom_model_id"))
        #expect(idMeta.category == .models)
        #expect(idMeta.label == "Catalog key")
        #expect(idMeta.kind == .string(default: "", validator: .any))

        // 3. custom_model_slug: String (Model id)
        let slugMeta = try #require(registry.find("custom_model_slug"))
        #expect(slugMeta.category == .models)
        #expect(slugMeta.label == "Model id")
        #expect(slugMeta.kind == .string(default: "", validator: .any))

        // 4. custom_model_name: String (Display name)
        let nameMeta = try #require(registry.find("custom_model_name"))
        #expect(nameMeta.category == .models)
        #expect(nameMeta.label == "Display name")
        #expect(nameMeta.kind == .string(default: "", validator: .any))

        // 5. custom_model_provider: Enum
        let providerMeta = try #require(registry.find("custom_model_provider"))
        #expect(providerMeta.category == .models)
        #expect(providerMeta.label == "Provider")
        #expect(providerMeta.kind == .enumeration(default: "", choices: CUSTOM_MODEL_PROVIDER_CHOICES, supportsPreview: false))

        // 6. custom_model_base_url: String (Base URL)
        let baseUrlMeta = try #require(registry.find("custom_model_base_url"))
        #expect(baseUrlMeta.category == .models)
        #expect(baseUrlMeta.label == "Base URL")
        #expect(baseUrlMeta.kind == .string(default: "", validator: .any))

        // 7. custom_model_context_window: Int stepper
        let contextMeta = try #require(registry.find("custom_model_context_window"))
        #expect(contextMeta.category == .models)
        #expect(contextMeta.label == "Context window")
        #expect(contextMeta.kind == .integer(
            default: CUSTOM_MODEL_CONTEXT_WINDOW_DEFAULT,
            minimum: CUSTOM_MODEL_CONTEXT_WINDOW_MIN,
            maximum: CUSTOM_MODEL_CONTEXT_WINDOW_MAX
        ))

        // 8. custom_model_backend: Enum
        let backendMeta = try #require(registry.find("custom_model_backend"))
        #expect(backendMeta.category == .models)
        #expect(backendMeta.label == "API backend")
        #expect(backendMeta.kind == .enumeration(default: "chat_completions", choices: CUSTOM_MODEL_BACKEND_CHOICES, supportsPreview: false))

        // 9. custom_model_env_key: String (API key env var / Env key name)
        let envKeyMeta = try #require(registry.find("custom_model_env_key"))
        #expect(envKeyMeta.category == .models)
        #expect(envKeyMeta.label == "Env key name")
        #expect(envKeyMeta.kind == .string(default: "", validator: .any))

        // 10. custom_model_save: Bool (Save custom model)
        let saveMeta = try #require(registry.find("custom_model_save"))
        #expect(saveMeta.category == .models)
        #expect(saveMeta.label == "Save custom model")
        #expect(saveMeta.kind == .bool(default: false))
    }

    @Test("customModelKeyIsValid validates catalog keys properly")
    func customModelKeyValidation() {
        #expect(customModelKeyIsValid("zai:glm-4") == true)
        #expect(customModelKeyIsValid("custom-model_1.0:test") == true)
        #expect(customModelKeyIsValid("model123") == true)
        #expect(customModelKeyIsValid("  zai:glm-4  ") == true)

        #expect(customModelKeyIsValid("") == false)
        #expect(customModelKeyIsValid("   ") == false)
        #expect(customModelKeyIsValid("with space") == false)
        #expect(customModelKeyIsValid("with\nnewline") == false)
        #expect(customModelKeyIsValid("with\rnewline") == false)
        #expect(customModelKeyIsValid("invalid@char") == false)
        #expect(customModelKeyIsValid("invalid#char") == false)
        #expect(customModelKeyIsValid("invalid/slash") == false)
        #expect(customModelKeyIsValid("invalid$dollar") == false)
    }

    @Test("customModelSlugIsValid validates wire model ids properly")
    func customModelSlugValidation() {
        #expect(customModelSlugIsValid("gpt-4o") == true)
        #expect(customModelSlugIsValid("llama3:latest") == true)
        #expect(customModelSlugIsValid("claude 3.5 sonnet") == true)
        #expect(customModelSlugIsValid("  trimmed-model  ") == true)

        #expect(customModelSlugIsValid("") == false)
        #expect(customModelSlugIsValid("   ") == false)
        #expect(customModelSlugIsValid("model\nwith\nnewline") == false)
        #expect(customModelSlugIsValid("model\rwith\rcarriage") == false)
    }
}
