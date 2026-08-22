import Foundation
import Testing
@testable import OpenGrokConfig

@Suite("Independent trusted hook configuration layers")
struct HookConfigLayerTests {
    @Test("all hook tiers remain additive in upstream authority order")
    func independentHookTiersRemainAdditive() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let system = fixture.appendingPathComponent("system", isDirectory: true)
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try writeHookConfig(command: "system-requirement", filename: "requirements.toml", directory: system)
        try writeHookConfig(command: "user-requirement", filename: "requirements.toml", directory: home)
        try writeHookConfig(command: "user-hook", filename: "config.toml", directory: home)
        try writeHookConfig(command: "managed-hook", filename: "managed_config.toml", directory: home)
        try writeHookConfig(
            command: "system-managed-hook",
            filename: "managed_config.toml",
            directory: system
        )

        let layers = hookConfigLayersAt(systemDir: system, userHome: home)

        #expect(
            layers.map(\.sourceName)
                == ["requirements/system", "requirements/user", "user", "managed", "system_managed"]
        )
        #expect(
            layers.map(\.provenance)
                == [.requirements, .requirements, .user, .managed, .systemManaged]
        )
        #expect(layers.map(hookCommand) == [
            "system-requirement",
            "user-requirement",
            "user-hook",
            "managed-hook",
            "system-managed-hook",
        ])
        #expect(layers[0].path == system.appendingPathComponent("requirements.toml"))
    }

    @Test("raw hook commands are not expanded before reaching the hook runner")
    func rawHookCommandsRemainUnexpanded() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        try writeHookConfig(command: "${HOME}/hooks/check", filename: "config.toml", directory: fixture)

        let layers = hookConfigLayersAt(
            systemDir: nil,
            userHome: fixture,
            environment: ["HOME": "/must/not/be/expanded/here"]
        )

        #expect(layers.count == 1)
        #expect(hookCommand(layers[0]) == "${HOME}/hooks/check")
    }

    @Test("malformed user configuration cannot discard managed administrator hooks")
    func malformedUserLayerCannotDiscardManagedHooks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        try "not = = valid TOML".write(
            to: fixture.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try writeHookConfig(command: "mandatory-admin-hook", filename: "managed_config.toml", directory: fixture)

        let layers = hookConfigLayersAt(systemDir: nil, userHome: fixture)

        #expect(layers.map(\.sourceName) == ["managed"])
        #expect(hookCommand(layers[0]) == "mandatory-admin-hook")
    }

    @Test("non-table hooks declarations do not shadow other configuration layers")
    func nonTableHookDeclarationCannotShadowOtherLayers() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        try "hooks = false\n".write(
            to: fixture.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try writeHookConfig(command: "still-mandatory", filename: "managed_config.toml", directory: fixture)

        let layers = hookConfigLayersAt(systemDir: nil, userHome: fixture)

        #expect(layers.map(\.sourceName) == ["managed"])
        #expect(hookCommand(layers[0]) == "still-mandatory")
    }

    @Test("version-selected hook declarations use session version without expanding commands")
    func versionSelectedHooksRemainRaw() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        try """
        [[version_overrides]]
        minimum_version = "2.0.0"
        [[version_overrides.hooks.PreToolUse]]
        matcher = "Bash"
        [[version_overrides.hooks.PreToolUse.hooks]]
        type = "command"
        command = "$HOOK_COMMAND"
        """.write(
            to: fixture.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let active = hookConfigLayersAt(
            systemDir: nil,
            userHome: fixture,
            environment: ["GROK_TEST_VERSION": "2.1.0", "HOOK_COMMAND": "expanded-too-early"]
        )
        let inactive = hookConfigLayersAt(
            systemDir: nil,
            userHome: fixture,
            environment: ["GROK_TEST_VERSION": "1.9.0"]
        )

        #expect(active.count == 1)
        #expect(hookCommand(active[0]) == "$HOOK_COMMAND")
        #expect(inactive.isEmpty)
    }

    @Test("unknown hook provenance wire values decode conservatively")
    func unknownHookProvenanceDecodesConservatively() throws {
        let decoded = try JSONDecoder().decode(HookProvenance.self, from: Data("\"future-admin-tier\"".utf8))
        #expect(decoded == .unknown)
        #expect(try JSONDecoder().decode(HookProvenance.self, from: Data("\"system_managed\"".utf8)) == .systemManaged)
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-hook-layers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeHookConfig(command: String, filename: String, directory: URL) throws {
        try """
        [[hooks.PreToolUse]]
        matcher = "Bash"
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "\(command)"
        """.write(
            to: directory.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    private func hookCommand(_ layer: HookConfigLayer) -> String? {
        layer.hooks["PreToolUse"]?.arrayValue?.first?["hooks"]?
            .arrayValue?.first?["command"]?.stringValue
    }
}
