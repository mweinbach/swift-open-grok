import Foundation
import OpenGrokConfig
import OpenGrokModels
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private final class CustomModelTOMLParitySink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}

    func flush() throws {}
}

@Suite("Live custom-model TOML persistence parity")
struct CustomModelTOMLParityTests {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-custom-model-toml-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func renderer(
        home: URL,
        environment: [String: String]? = nil,
        catalog: LiveModelCatalogStore? = nil,
        permissionPromptSettings: PermissionPromptSettings? = nil
    ) -> LiveInteractiveControllerRenderer {
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        return LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: CustomModelTOMLParitySink(),
            workingDirectory: home.path,
            modelName: "grok-live",
            catalogStore: catalog,
            sessionID: "custom-model-toml-parity",
            openGrokHome: home,
            environment: environment ?? [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
            ],
            permissionPromptSettings: permissionPromptSettings
        )
    }

    @Test("model actor stores all public fields in owner-private canonical config")
    func modelActorPersistsCanonicalTOMLAndFullMetadata() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        try "[ui]\ntheme = \"groknight\"\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )

        let store = CustomModelStore(grokHome: home)
        try await store.upsertCustomModel(CustomModelEntry(
            key: "zai:glm.special",
            modelId: "glm-wire",
            provider: "z-ai",
            baseUrl: "https://api.z.ai/v1",
            contextWindow: 256_000,
            maxOutputTokens: 4096,
            reasoningEfforts: ["low", "high"],
            name: "Friendly GLM",
            apiBackend: "responses",
            envKey: "PRIVATE_GLM_KEY"
        ))

        let document = try parseTOML(Data(contentsOf: config))
        let table = try #require(document[path: ["model", "zai:glm.special"]])
        #expect(table["model"]?.stringValue == "glm-wire")
        #expect(table["provider"]?.stringValue == "zai")
        #expect(table["name"]?.stringValue == "Friendly GLM")
        #expect(table["base_url"]?.stringValue == "https://api.z.ai/v1")
        #expect(table["context_window"]?.int64Value == 256_000)
        #expect(table["max_completion_tokens"]?.int64Value == 4096)
        #expect(table["api_backend"]?.stringValue == "responses")
        #expect(table["env_key"]?.stringValue == "PRIVATE_GLM_KEY")
        #expect(document[path: ["ui", "theme"]]?.stringValue == "groknight")
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("custom_models.json").path
        ))

        let reloaded = try #require(await CustomModelStore(grokHome: home).getCustomModel(
            key: "zai:glm.special"
        ))
        #expect(reloaded.name == "Friendly GLM")
        #expect(reloaded.toModelInfo().apiBackend == .responses)
        #expect(reloaded.toModelEntry().envKey?.primary == "PRIVATE_GLM_KEY")
        #expect(reloaded.toConfigModelOverride().name == "Friendly GLM")

        #if !os(Windows)
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(mode.intValue == 0o600)
        #endif
    }

    @Test("legacy dictionary JSON migrates without replacing canonical provider identity")
    func legacyModelActorMigrationPreservesCanonicalAuthority() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        try """
        [ui]
        theme = "groknight"

        [model."xai:actually-fireworks"]
        model = "canonical-wire"
        provider = "fireworks"
        name = "Canonical Fireworks"
        """.write(to: config, atomically: true, encoding: .utf8)

        let legacyPath = home.appendingPathComponent("custom_models.json")
        let legacy = [
            "collision": CustomModelEntry(
                key: "xai:actually-fireworks",
                modelId: "poisoned-wire",
                provider: "xai"
            ),
            "addition": CustomModelEntry(
                key: "meta:migrated",
                modelId: "meta-wire",
                provider: "meta",
                name: "Migrated Meta",
                apiBackend: "responses",
                envKey: "META_PRIVATE_KEY"
            ),
        ]
        try JSONEncoder().encode(legacy).write(to: legacyPath)

        let overrides = try loadCustomModelOverrides(grokHome: home)
        let collision = try #require(overrides.first { $0.0 == "xai:actually-fireworks" })
        #expect(collision.1.provider == .fireworks)
        #expect(collision.1.model == "canonical-wire")
        let addition = try #require(overrides.first { $0.0 == "meta:migrated" })
        #expect(addition.1.provider == .meta)
        #expect(addition.1.apiBackend == .responses)
        #expect(addition.1.envKey?.primary == "META_PRIVATE_KEY")
        #expect(!FileManager.default.fileExists(atPath: legacyPath.path))

        let actor = CustomModelStore(grokHome: home)
        let removed = try await actor.deleteCustomModel(key: "meta:migrated")
        #expect(removed)
        #expect(try loadCustomModelOverrides(grokHome: home).map(\.0) == [
            "xai:actually-fireworks"
        ])
    }

    @Test("live settings save and delete use one TOML record and populate backed choices")
    func liveSettingsSavePreservesEveryDraftField() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let live = renderer(home: home)

        for (key, value) in [
            ("custom_model_id", "meta:muse-custom"),
            ("custom_model_slug", "muse-wire"),
            ("custom_model_name", "My Muse"),
            ("custom_model_provider", "meta"),
            ("custom_model_base_url", "https://api.meta.example/v1"),
            ("custom_model_backend", "responses"),
            ("custom_model_env_key", "MY_META_API_KEY"),
        ] {
            await live.applySettingsEvent(.commit(key: key, value: .string(value)))
        }
        await live.applySettingsEvent(.commit(
            key: "custom_model_context_window",
            value: .integer(180_000)
        ))
        await live.applySettingsEvent(.commit(key: "custom_model_save", value: .bool(true)))

        let config = home.appendingPathComponent("config.toml")
        let document = try parseTOML(Data(contentsOf: config))
        let table = try #require(document[path: ["model", "meta:muse-custom"]])
        #expect(table["name"]?.stringValue == "My Muse")
        #expect(table["provider"]?.stringValue == "meta")
        #expect(table["api_backend"]?.stringValue == "responses")
        #expect(table["env_key"]?.stringValue == "MY_META_API_KEY")
        #expect(table["context_window"]?.int64Value == 180_000)
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("custom_models.json").path
        ))

        let overlay = await live.providerSettingsOverlay()
        let custom = try #require(overlay.dynamicChoices[.customModels]?.first)
        #expect(custom.canonical == "meta:muse-custom")
        #expect(custom.display == "My Muse")
        #expect(overlay.multiSelectEnabled["custom_models.list"] == ["meta:muse-custom"])
        #expect(overlay.dynamicChoices[.auxiliaryModelCatalog]?.map(\.canonical) == [
            "", "grok-live"
        ])

        await live.applySettingsEvent(.toggleMultiSelect(
            key: "custom_models.list",
            choice: "meta:muse-custom",
            enabled: false
        ))
        let afterDelete = try parseTOML(Data(contentsOf: config))
        #expect(afterDelete["model"] == nil)
    }

    @Test("auxiliary chooser never reintroduces models removed by catalog restrictions")
    func auxiliaryChoicesRespectManagedCatalogFiltering() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        let catalog = LiveModelCatalogStore(
            input: CatalogResolutionInput(
                models: ModelsSectionConfig(allowedModels: ["allowed-model"]),
                configModels: [
                    ("allowed-model", ConfigModelOverride(model: "allowed-wire", provider: .xai)),
                    ("blocked-model", ConfigModelOverride(model: "blocked-wire", provider: .xai)),
                ]
            ),
            environment: environment,
            openGrokHome: home
        )

        let live = renderer(home: home, environment: environment, catalog: catalog)
        let overlay = await live.providerSettingsOverlay()
        #expect(overlay.dynamicChoices[.activeModelCatalog]?.map(\.canonical) == [
            "allowed-model"
        ])
        #expect(overlay.dynamicChoices[.auxiliaryModelCatalog]?.map(\.canonical) == [
            "", "allowed-model"
        ])
    }

    @Test("remembered-command cursor choice follows trusted settings and environment precedence")
    func rememberedApprovalChoiceIsConservativelyGated() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let live = renderer(home: home)
        let disabled = await live.providerSettingsOverlay()
        let setting = try #require(disabled.registry.find("default_selected_permission"))
        #expect(disabled.choices(for: setting).map(\.canonical) == ["allow-once", "reject"])

        try "[ui]\nremember_tool_approvals = true\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let enabled = await live.providerSettingsOverlay()
        #expect(enabled.choices(for: setting).map(\.canonical) == [
            "allow-once", "allow-command-always", "reject"
        ])

        let pinnedOff = renderer(home: home, environment: [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_REMEMBER_TOOL_APPROVALS": "0",
        ])
        let denied = await pinnedOff.providerSettingsOverlay()
        #expect(denied.choices(for: setting).map(\.canonical) == ["allow-once", "reject"])
    }

    @Test("authenticated remote remembered-approval authority reaches the real settings overlay")
    func resolvedRemoteRememberedApprovalsReachSettings() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let live = renderer(
            home: home,
            permissionPromptSettings: PermissionPromptSettings(
                rememberToolApprovals: true
            )
        )
        let overlay = await live.providerSettingsOverlay()
        let setting = try #require(overlay.registry.find("default_selected_permission"))

        #expect(overlay.choices(for: setting).map(\.canonical) == [
            "allow-once", "allow-command-always", "reject",
        ])
    }

    @Test("OpenCode chooser offers only discovered models and persists canonical IDs")
    func openCodeChoicesStayProviderIsolated() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            OpenCodeGoModels.apiKeyEnv: "fixture-opencode-key",
        ]
        let descriptor = OpenCodeGoModelDescriptor(
            key: "opencode-go:gpt-ish",
            id: "gpt-ish",
            name: "GPT-ish",
            apiBackend: .chatCompletions
        )
        let info = ModelInfo(
            id: descriptor.key,
            model: descriptor.id,
            baseURL: OpenCodeGoModels.apiBaseURLDefault,
            name: descriptor.name,
            provider: .openCodeGo
        )
        let remote = OpenCodeGoModelsCatalog(
            entries: OrderedModelMap([
                (descriptor.key, ModelEntry(
                    info: info,
                    envKey: .single(OpenCodeGoModels.apiKeyEnv)
                ))
            ]),
            descriptors: [descriptor],
            warnings: [],
            credentialFingerprint: "6016a36c568a0296"
        )
        let catalog = LiveModelCatalogStore(
            input: CatalogResolutionInput(),
            environment: environment,
            openGrokHome: home
        )
        catalog.applyOpenCodeGoCatalog(remote)
        #expect(catalog.openCodeGoDescriptors() == [descriptor])

        let live = renderer(home: home, environment: environment, catalog: catalog)
        let initial = await live.providerSettingsOverlay()
        #expect(initial.dynamicChoices[.openCodeGoModels]?.map(\.canonical) == ["gpt-ish"])
        #expect(initial.multiSelectEnabled["opencode_go_models"]?.isEmpty == true)

        await live.applySettingsEvent(.toggleMultiSelect(
            key: "opencode_go_models",
            choice: "opencode-go:gpt-ish",
            enabled: true
        ))
        #expect(catalog.openCodeGoEnabledModels() == ["gpt-ish"])
        let document = try parseTOML(Data(contentsOf: home.appendingPathComponent("config.toml")))
        #expect(document[path: ["models", "opencode_go_enabled_models"]]?
            .arrayValue?.compactMap(\.stringValue) == ["gpt-ish"])

        await live.applySettingsEvent(.toggleMultiSelect(
            key: "opencode_go_models",
            choice: "foreign-provider-model",
            enabled: true
        ))
        #expect(catalog.openCodeGoEnabledModels() == ["gpt-ish"])
    }
}
