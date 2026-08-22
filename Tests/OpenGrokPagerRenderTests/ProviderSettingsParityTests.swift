import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

@Suite("Provider settings and OpenRouter opt-in parity")
struct ProviderSettingsParityTests {
    @Test("new provider credentials use secure stores and OpenRouter models remain opt-in")
    func providerRowsHaveCorrectOwnership() throws {
        let registry = PagerSettingsRegistry.default
        for (key, account, label) in [
            ("zai_api_key", "zai", "Z AI API key"),
            ("runinfra_api_key", "runinfra", "RunInfra API key"),
            ("gemini_api_key", "gemini", "Google Gemini API key"),
            ("openrouter_api_key", "openrouter", "OpenRouter API key"),
        ] {
            let row = try #require(registry.find(key))
            #expect(row.category == .models)
            #expect(row.label == label)
            #expect(row.kind == .secret)
            #expect(row.storage == .secretStore(account: account))
        }

        let openRouter = try #require(registry.find("openrouter_models"))
        #expect(openRouter.kind == .dynamicMultiSelect(source: .openRouterModels))
        #expect(openRouter.storage == .config(path: "models.openrouter_enabled_models"))

        let customProviders = CUSTOM_MODEL_PROVIDER_CHOICES.map(\.canonical)
        #expect(customProviders.contains("runinfra"))
        #expect(customProviders.contains("gemini"))
        #expect(customProviders.contains("openrouter"))
    }

    @Test("OpenRouter model selections default empty and persist sorted unique nonblank IDs")
    func openRouterSelectionPersistenceIsExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-provider-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        let store = PagerSettingsStore(configPath: config)

        #expect(try store.loadMultiSelect(key: "openrouter_models").isEmpty)
        let written = try store.writeMultiSelect(
            key: "openrouter_models",
            enabled: [" openai/gpt-4o ", "anthropic/claude-sonnet-4", "", "  "]
        )
        #expect(written == "models.openrouter_enabled_models")
        #expect(try store.loadMultiSelect(key: "openrouter_models") == [
            "anthropic/claude-sonnet-4", "openai/gpt-4o",
        ])

        let document = try String(contentsOf: config, encoding: .utf8)
        let anthropic = try #require(document.range(of: "anthropic/claude-sonnet-4"))
        let openAI = try #require(document.range(of: "openai/gpt-4o"))
        #expect(anthropic.lowerBound < openAI.lowerBound)
        #expect(!document.contains("openrouter_api_key"))

        let cleared = try store.writeMultiSelect(key: "openrouter_models", enabled: [])
        #expect(cleared == "models.openrouter_enabled_models")
        #expect(try store.loadMultiSelect(key: "openrouter_models").isEmpty)
    }

    @Test("OpenRouter checkboxes emit canonical model IDs without enabling sibling models")
    func openRouterCheckboxesAreIndependent() throws {
        var overlay = PagerSettingsOverlay(
            dynamicChoices: [.openRouterModels: [
                PagerSettingChoice(
                    canonical: "anthropic/claude-sonnet-4",
                    display: "Claude Sonnet 4"
                ),
                PagerSettingChoice(canonical: "openai/gpt-4o", display: "GPT-4o"),
            ]],
            multiSelectEnabled: ["openrouter_models": []]
        )
        let rowIndex = try #require(overlay.visibleRows.firstIndex {
            $0.settingKey == "openrouter_models"
        })
        overlay.selectedIndex = rowIndex
        let opened = overlay.handle(KeyEvent(key: .enter))
        #expect(opened == .redraw)
        #expect(overlay.mode == .pickingGroup(key: "openrouter_models", childIndex: 0))

        let enabled = overlay.handle(KeyEvent(key: .enter))
        #expect(enabled == .event(.toggleMultiSelect(
            key: "openrouter_models",
            choice: "anthropic/claude-sonnet-4",
            enabled: true
        )))
        #expect(overlay.multiSelectEnabled["openrouter_models"] == [
            "anthropic/claude-sonnet-4",
        ])

        let disabled = overlay.handle(KeyEvent(key: .enter))
        #expect(disabled == .event(.toggleMultiSelect(
            key: "openrouter_models",
            choice: "anthropic/claude-sonnet-4",
            enabled: false
        )))
        #expect(overlay.multiSelectEnabled["openrouter_models"]?.isEmpty == true)
    }

    @Test("usage providers retain truthful account labels")
    func providerUsageLabelsAreDistinct() {
        #expect(PagerUsageProvider.runinfra.rawValue == "RunInfra")
        #expect(PagerUsageProvider.gemini.rawValue == "Google Gemini")
        #expect(PagerUsageProvider.openRouter.rawValue == "OpenRouter")
        #expect(PagerUsageProvider.antigravity.rawValue == "Antigravity")
    }
}
