import Foundation
import OpenGrokHooks
import Testing
@testable import OpenGrokCLI

@Suite("Live hook authority foundation")
struct LiveHookAuthorityFoundationTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-live-hook-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeHook(_ command: String, to file: URL) throws {
        try """
        [[hooks.PreToolUse]]
        matcher = "Bash"
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "\(command)"
        """.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test("managed and user hook arrays both reach the executable's live gate")
    func managedAndUserHooksRemainAdditive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeHook("user-check", to: home.appendingPathComponent("config.toml"))
        try writeHook("managed-check", to: home.appendingPathComponent("managed_config.toml"))

        let loaded = LiveHooksComposition.load(
            sessionId: "hook-foundation",
            workspaceRoot: home,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )

        let hooks = loaded.result.registry.allHooks()
        #expect(hooks.compactMap(\.command) == ["user-check", "managed-check"])
        #expect(hooks.map(\.sourceKind) == [.user, .managed])
        #expect(loaded.gate != nil)
    }

    @Test("malformed user hooks cannot erase administrator hooks")
    func malformedUserHooksCannotEraseManagedHooks() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "hooks = false\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try writeHook("mandatory-check", to: home.appendingPathComponent("managed_config.toml"))

        let loaded = LiveHooksComposition.load(
            sessionId: "hook-foundation",
            workspaceRoot: home,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )

        #expect(loaded.result.registry.allHooks().compactMap(\.command) == ["mandatory-check"])
        #expect(loaded.result.registry.allHooks().first?.sourceKind == .managed)
    }

    @Test("hook commands expand the injected environment exactly once")
    func hookCommandsExpandExactlyOnce() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeHook("${HOOK_COMMAND}", to: home.appendingPathComponent("config.toml"))

        let loaded = LiveHooksComposition.load(
            sessionId: "hook-foundation",
            workspaceRoot: home,
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "HOOK_COMMAND": "$DO_NOT_EXPAND_AGAIN",
                "DO_NOT_EXPAND_AGAIN": "unsafe-second-expansion",
            ]
        )

        let hook = try #require(loaded.result.registry.allHooks().first)
        #expect(hook.commandRaw == "${HOOK_COMMAND}")
        #expect(hook.command == "$DO_NOT_EXPAND_AGAIN")
    }
}
