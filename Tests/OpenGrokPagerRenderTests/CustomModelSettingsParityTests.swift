import Foundation
import Testing
@testable import OpenGrokPagerRender

@Suite("Custom-model settings TOML parity")
struct CustomModelSettingsParityTests {
    private func temporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-custom-model-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("settings draft persists every upstream field in its literal model table")
    func draftPersistsCompleteCanonicalTOMLRecord() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        let store = PagerSettingsStore(configPath: config)

        let saved = try store.saveCustomModelDraft(CustomModelDraft(
            id: "zai:glm-special.v1",
            slug: "glm-special",
            name: "GLM Special",
            provider: "zai",
            baseUrl: "https://api.z.ai/v1",
            contextWindow: 128_000,
            backend: "responses",
            envKey: "PRIVATE_ZAI_KEY"
        ))

        #expect(saved.key == "zai:glm-special.v1")
        #expect(saved.name == "GLM Special")
        #expect(saved.apiBackend == "responses")
        #expect(saved.envKey == "PRIVATE_ZAI_KEY")

        let contents = try String(contentsOf: config, encoding: .utf8)
        #expect(contents.contains("[model.\"zai:glm-special.v1\"]"))
        #expect(contents.contains("model = \"glm-special\""))
        #expect(contents.contains("name = \"GLM Special\""))
        #expect(contents.contains("provider = \"zai\""))
        #expect(contents.contains("base_url = \"https://api.z.ai/v1\""))
        #expect(contents.contains("context_window = 128000"))
        #expect(contents.contains("api_backend = \"responses\""))
        #expect(contents.contains("env_key = \"PRIVATE_ZAI_KEY\""))
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("custom_models.json").path
        ))

        let reloaded = try #require(store.loadCustomModels().first)
        #expect(reloaded == saved)

        #if !os(Windows)
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(mode.intValue == 0o600)
        #endif
    }

    @Test("legacy JSON migrates once while canonical tables and unrelated config win")
    func legacyJSONMigratesWithoutReplacingCanonicalRecords() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        try """
        [ui]
        theme = "groknight"

        [model."zai:shared"]
        model = "canonical-model"
        provider = "zai"
        description = "preserve this field"
        """.write(to: config, atomically: true, encoding: .utf8)

        let legacy = [
            PagerCustomModelRecord(
                key: "zai:shared",
                modelId: "obsolete-model",
                provider: "zai"
            ),
            PagerCustomModelRecord(
                key: "wafer:migrated",
                modelId: "wafer-wire",
                provider: "wafer",
                contextWindow: 96_000,
                name: "Migrated Wafer",
                apiBackend: "chat_completions",
                envKey: "MIGRATED_WAFER_KEY"
            ),
        ]
        let legacyPath = home.appendingPathComponent("custom_models.json")
        try JSONEncoder().encode(legacy).write(to: legacyPath)

        let store = PagerSettingsStore(configPath: config)
        let records = try store.loadCustomModels()
        #expect(records.count == 2)
        #expect(records.first { $0.key == "zai:shared" }?.modelId == "canonical-model")
        #expect(records.first { $0.key == "wafer:migrated" }?.name == "Migrated Wafer")
        #expect(!FileManager.default.fileExists(atPath: legacyPath.path))

        let migrated = try String(contentsOf: config, encoding: .utf8)
        #expect(migrated.contains("theme = \"groknight\""))
        #expect(migrated.contains("description = \"preserve this field\""))
        #expect(migrated.contains("env_key = \"MIGRATED_WAFER_KEY\""))

        let deleted = try store.deleteCustomModel(key: "wafer:migrated")
        #expect(deleted)
        #expect(try store.loadCustomModels().map(\.key) == ["zai:shared"])
    }

    @Test("upsert preserves sibling metadata and an env key removes stale inline secrets")
    func upsertPreservesSiblingsAndReplacesInlineSecret() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        try """
        [model.keep]
        model = "keep-wire"
        provider = "xai"

        [model.target]
        model = "old-wire"
        provider = "xai"
        description = "unmodeled metadata"
        api_key = "stale-secret"
        """.write(to: config, atomically: true, encoding: .utf8)

        let store = PagerSettingsStore(configPath: config)
        let saved = try store.saveCustomModelDraft(CustomModelDraft(
            id: "target",
            slug: "new-wire",
            provider: "xai",
            envKey: "TARGET_SECRET_ENV"
        ))
        #expect(saved.envKey == "TARGET_SECRET_ENV")

        let contents = try String(contentsOf: config, encoding: .utf8)
        #expect(contents.contains("[model.keep]"))
        #expect(contents.contains("description = \"unmodeled metadata\""))
        #expect(!contents.contains("stale-secret"))
        #expect(contents.contains("env_key = \"TARGET_SECRET_ENV\""))
    }

    @Test("invalid TOML and malformed migration JSON fail without overwriting either source")
    func malformedPersistenceFailsClosed() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        let original = "[model.broken\nmodel = \"keep me\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)

        let store = PagerSettingsStore(configPath: config)
        #expect(throws: PagerSettingsStoreError.self) {
            try store.saveCustomModelDraft(CustomModelDraft(id: "valid", slug: "wire"))
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == original)

        try "[ui]\ntheme = \"groknight\"\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        let legacy = home.appendingPathComponent("custom_models.json")
        try "{ invalid json".write(to: legacy, atomically: true, encoding: .utf8)
        #expect(throws: PagerSettingsStoreError.self) {
            try store.loadCustomModels()
        }
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "{ invalid json")
    }

    @Test("upstream Meta and OpenCode Go providers have backed custom-model choices")
    func upstreamCustomProvidersAreAvailable() {
        let choices = Set(CUSTOM_MODEL_PROVIDER_CHOICES.map(\.canonical))
        #expect(choices.contains("meta"))
        #expect(choices.contains("opencode_go"))
    }

    @Test("permission cursor defaults to one-time approval and never offers global grants")
    func permissionCursorChoicesReflectActualPermissionSheet() throws {
        let setting = try #require(PagerSettingsRegistry.default.find(
            "default_selected_permission"
        ))
        #expect(setting.defaultValue == .string("allow-once"))
        let choices = PagerSettingChoices.defaultSelectedPermission.map(\.canonical)
        #expect(choices == ["allow-once", "allow-command-always", "reject"])
        #expect(!choices.contains("always-allow-all-sessions"))
    }
}
