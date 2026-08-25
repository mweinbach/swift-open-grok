import Foundation
import Testing
@testable import OpenGrokPagerRender

@Suite("Settings model storage path parity")
struct PagerSettingsStoragePathParityTests {
    private func temporaryConfig() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-settings-model-paths-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
    }

    @Test("model settings name the canonical upstream TOML destinations")
    func registryUsesCanonicalModelStoragePaths() throws {
        let registry = PagerSettingsRegistry.default

        let memory = try #require(registry.find("memory_model"))
        #expect(memory.storage == .config(path: "models.memory"))

        let fork = try #require(registry.find("fork_secondary_model"))
        #expect(fork.storage == .config(path: "ui.fork_secondary_model"))
    }

    @Test("memory model writes [models].memory and reloads under its UI key")
    func memoryModelPersistsAtCanonicalPath() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())

        let writtenPath = try store.write(key: "memory_model", value: .string("kimi:k2"))
        #expect(writtenPath == "models.memory")

        let contents = try String(contentsOf: store.configPath, encoding: .utf8)
        #expect(contents.contains("[models]"))
        #expect(contents.contains("memory = \"kimi:k2\""))
        #expect(!contents.contains("memory_model ="))
        #expect(try store.load()["memory_model"] == .string("kimi:k2"))
    }

    @Test("fork secondary model writes [ui].fork_secondary_model and reloads")
    func forkSecondaryModelPersistsAtCanonicalPath() throws {
        let store = PagerSettingsStore(configPath: temporaryConfig())

        let writtenPath = try store.write(
            key: "fork_secondary_model",
            value: .string("codex:gpt-5.6")
        )
        #expect(writtenPath == "ui.fork_secondary_model")

        let contents = try String(contentsOf: store.configPath, encoding: .utf8)
        #expect(contents.contains("[ui]"))
        #expect(contents.contains("fork_secondary_model = \"codex:gpt-5.6\""))
        #expect(!contents.contains("[models]"))
        #expect(try store.load()["fork_secondary_model"] == .string("codex:gpt-5.6"))
    }

    @Test("canonical on-disk values take precedence over unsupported old paths")
    func coldLoadReadsCanonicalPathsInsteadOfObsoleteLookalikes() throws {
        let configPath = temporaryConfig()
        try FileManager.default.createDirectory(
            at: configPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [models]
        memory = "canonical-memory"
        memory_model = "obsolete-memory"
        fork_secondary_model = "obsolete-fork"

        [ui]
        fork_secondary_model = "canonical-fork"
        """.write(to: configPath, atomically: true, encoding: .utf8)

        let values = try PagerSettingsStore(configPath: configPath).load()
        #expect(values["memory_model"] == .string("canonical-memory"))
        #expect(values["fork_secondary_model"] == .string("canonical-fork"))
    }
}
