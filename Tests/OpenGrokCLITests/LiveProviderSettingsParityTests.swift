import Foundation
import OpenGrokAuth
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokProviderSession
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private final class ProviderSettingsSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}

    func flush() throws {}
}

private struct LiveProviderSettingsFixture {
    let home: URL
    let environment: [String: String]
    let catalog: LiveModelCatalogStore
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-live-provider-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            OpenRouterModels.apiKeyEnv: "openrouter-test-secret",
        ]
        catalog = LiveModelCatalogStore(
            input: CatalogResolutionInput(),
            environment: environment,
            openGrokHome: home
        )
        let response = Data("""
        {"data":[
          {"id":"anthropic/claude-sonnet-4","name":"Claude Sonnet 4","supported_parameters":["tools"]},
          {"id":"openai/gpt-4o","name":"GPT-4o","supported_parameters":["tools"]}
        ]}
        """.utf8)
        let discovered = try OpenRouterModels.parseCatalogSnapshot(
            response,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            apiKey: "openrouter-test-secret"
        )
        guard catalog.applyOpenRouterCatalog(discovered) else {
            throw CLIApplicationError.failed("OpenRouter test catalog was not published")
        }
        renderer = Self.makeRenderer(home: home, environment: environment, catalog: catalog)
    }

    static func makeRenderer(
        home: URL,
        environment: [String: String],
        catalog: LiveModelCatalogStore? = nil,
        modelName: String = "grok-test"
    ) -> LiveInteractiveControllerRenderer {
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        return LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: ProviderSettingsSink(),
            workingDirectory: home.path,
            modelName: modelName,
            catalogStore: catalog,
            sessionID: "live-provider-settings",
            openGrokHome: home,
            environment: environment
        )
    }

    func cleanup() {
        catalog.backgroundRefreshTask?.cancel()
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("Live provider settings and OpenRouter opt-in", .serialized)
struct LiveProviderSettingsParityTests {
    @Test("RunInfra, Gemini, and OpenRouter picker rows retain provider-qualified labels")
    func modelPickerUsesTruthfulProviderLabels() {
        let entries = [
            LiveModelPickerEntry(
                id: "runinfra:deepseek-v4",
                providerID: "runinfra",
                name: "DeepSeek V4"
            ),
            LiveModelPickerEntry(
                id: "gemini:gemini-3.6-pro",
                providerID: "gemini",
                name: "Gemini 3.6 Pro"
            ),
            LiveModelPickerEntry(
                id: "openrouter:anthropic/claude-sonnet-4",
                providerID: "openrouter",
                name: "Claude Sonnet 4"
            ),
        ]
        let rows = LiveModelPicker.rows(entries: entries)
        #expect(rows.map(\.label) == [
            "Google Gemini · Gemini 3.6 Pro",
            "OpenRouter · Claude Sonnet 4",
            "RunInfra · DeepSeek V4",
        ])
        #expect(rows.map(\.selector).contains("openrouter:anthropic/claude-sonnet-4"))
        #expect(LiveModelPicker.providerLabel(forProviderID: "google_gemini") == "Google Gemini")
        #expect(LiveModelPicker.providerLabel(forProviderID: "run-infra") == "RunInfra")
        #expect(LiveModelPicker.providerLabel(forProviderID: "open_router") == "OpenRouter")
    }

    @Test("real login deep links expose the provider's live secure-key status")
    func settingsIntentCarriesProviderCredentialStatus() async throws {
        let fixture = try LiveProviderSettingsFixture()
        defer { fixture.cleanup() }

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.settings(
            deepLinkKey: "openrouter_api_key"
        )))
        #expect(await fixture.renderer.openSettingsRowValue(
            forKey: "openrouter_api_key"
        ) == .secret(.environmentOverride))
        #expect(await fixture.renderer.openSettingsRowValue(
            forKey: "runinfra_api_key"
        ) == .secret(.missing))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("discovered OpenRouter models remain hidden until their real settings checkbox is enabled")
    func openRouterCheckboxUpdatesPersistedAndLiveCatalogs() async throws {
        let fixture = try LiveProviderSettingsFixture()
        defer { fixture.cleanup() }

        #expect(fixture.catalog.openRouterDescriptors().count == 2)
        #expect(fixture.catalog.openRouterEnabledModels().isEmpty)
        #expect(!fixture.catalog.pickerEntries().contains { $0.providerID == "openrouter" })

        let initial = await fixture.renderer.providerSettingsOverlay(
            deepLinkKey: "openrouter_models"
        )
        #expect(initial.selectedKey == "openrouter_models")
        #expect(initial.dynamicChoices[.openRouterModels]?.map(\.canonical) == [
            "anthropic/claude-sonnet-4", "openai/gpt-4o",
        ])
        #expect(initial.multiSelectEnabled["openrouter_models"]?.isEmpty == true)
        #expect(initial.values["openrouter_api_key"] == .secret(.environmentOverride))

        await fixture.renderer.applySettingsEvent(.toggleMultiSelect(
            key: "openrouter_models",
            choice: "anthropic/claude-sonnet-4",
            enabled: true
        ))
        let persisted = PagerSettingsStore(
            configPath: fixture.home.appendingPathComponent("config.toml")
        )
        #expect(try persisted.loadMultiSelect(key: "openrouter_models") == [
            "anthropic/claude-sonnet-4",
        ])
        #expect(fixture.catalog.openRouterEnabledModels() == ["anthropic/claude-sonnet-4"])
        #expect(fixture.catalog.pickerEntries().contains {
            $0.id == "openrouter:anthropic/claude-sonnet-4"
        })
        #expect(!fixture.catalog.pickerEntries().contains { $0.id == "openrouter:openai/gpt-4o" })

        let reopened = await fixture.renderer.providerSettingsOverlay()
        #expect(reopened.multiSelectEnabled["openrouter_models"] == [
            "anthropic/claude-sonnet-4",
        ])

        await fixture.renderer.applySettingsEvent(.toggleMultiSelect(
            key: "openrouter_models",
            choice: "anthropic/claude-sonnet-4",
            enabled: false
        ))
        #expect(try persisted.loadMultiSelect(key: "openrouter_models").isEmpty)
        #expect(fixture.catalog.openRouterEnabledModels().isEmpty)
        #expect(!fixture.catalog.pickerEntries().contains { $0.providerID == "openrouter" })
        #expect(fixture.catalog.openRouterDescriptors().count == 2)
    }

    @Test("undiscovered OpenRouter IDs cannot bypass the settings opt-in gate")
    func unknownOpenRouterModelsCannotBeEnabled() async throws {
        let fixture = try LiveProviderSettingsFixture()
        defer { fixture.cleanup() }

        await fixture.renderer.applySettingsEvent(.toggleMultiSelect(
            key: "openrouter_models",
            choice: "invented/unsafe-model",
            enabled: true
        ))
        #expect(fixture.catalog.openRouterEnabledModels().isEmpty)
        #expect(!fixture.catalog.pickerEntries().contains { $0.providerID == "openrouter" })
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("config.toml").path
        ))
    }

    @Test("provider settings secrets persist to isolated credential scopes and refresh visible status")
    func providerSecretsNeverEnterConfigTOML() async throws {
        let fixture = try LiveProviderSettingsFixture()
        defer { fixture.cleanup() }
        let renderer = LiveProviderSettingsFixture.makeRenderer(
            home: fixture.home,
            environment: [
                "HOME": fixture.home.path,
                "OPENGROK_HOME": fixture.home.path,
                "GOOGLE_API_KEY": "environment-gemini",
            ]
        )

        await renderer.applySettingsEvent(.secret(
            key: "runinfra_api_key",
            value: " runinfra-secret "
        ))
        await renderer.applySettingsEvent(.secret(
            key: "openrouter_api_key",
            value: "openrouter-stored-secret"
        ))
        await renderer.applySettingsEvent(.secret(
            key: "zai_api_key",
            value: "zai-stored-secret"
        ))

        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "runinfra")
            == "runinfra-secret")
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "openrouter")
            == "openrouter-stored-secret")
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "zai")
            == "zai-stored-secret")
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "gemini") == nil)

        let overlay = await renderer.providerSettingsOverlay()
        #expect(overlay.values["runinfra_api_key"] == .secret(.stored))
        #expect(overlay.values["zai_api_key"] == .secret(.stored))
        #expect(overlay.values["gemini_api_key"] == .secret(.environmentOverride))
        #expect(overlay.values["openrouter_api_key"] == .secret(.stored))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("config.toml").path
        ))

        await renderer.applySettingsEvent(.resetRequested(key: "runinfra_api_key"))
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "runinfra") == nil)
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "openrouter")
            == "openrouter-stored-secret")
    }

    @Test("provider quota windows never render new accounts as xAI")
    func providerQuotaSectionsKeepAccountIdentity() async throws {
        let fixture = try LiveProviderSettingsFixture()
        defer { fixture.cleanup() }
        let report = LiveUsageReport(
            context: nil,
            quotaWindows: [
                ProviderQuotaWindow(provider: .runinfra, used: 10, limit: 100),
                ProviderQuotaWindow(provider: .gemini, used: 20, limit: 100),
                ProviderQuotaWindow(provider: .openRouter, used: 30, limit: 100),
            ],
            quotaFailures: [],
            estimatedSessionTokens: 0,
            turnCount: 0
        )
        let block = await fixture.renderer.waveEUsageBlock(report)
        #expect(block.sections.map(\.provider) == [.runinfra, .gemini, .openRouter])
        #expect(block.sections.map { $0.provider.rawValue } == [
            "RunInfra", "Google Gemini", "OpenRouter",
        ])
    }
}
