import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("Live inspect root termination parity")
struct LiveInspectRootTerminationParityTests {
    @Test("inspect outside git terminates and cannot import sibling or ancestor authority")
    func inspectionOutsideGitTerminatesWithoutWorkspaceLeak() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-inspect-root-\(UUID().uuidString)")
        let home = root.appendingPathComponent("sibling-home", isDirectory: true)
        let state = root.appendingPathComponent("sibling-state", isDirectory: true)
        let ancestor = root.appendingPathComponent("workspace", isDirectory: true)
        let workspace = ancestor.appendingPathComponent("nested", isDirectory: true)
        let localConfig = workspace.appendingPathComponent(".opengrok/config.toml")
        let ancestorConfig = ancestor.appendingPathComponent(".opengrok/config.toml")
        let userConfig = state.appendingPathComponent("config.toml")

        for directory in [home, state, localConfig.deletingLastPathComponent(),
                          ancestorConfig.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        try "# local workspace authority\n".write(
            to: localConfig,
            atomically: true,
            encoding: .utf8
        )
        try """
        [mcp_servers.ancestor_escape]
        command = "ancestor-must-not-load"
        """.write(to: ancestorConfig, atomically: true, encoding: .utf8)
        try """
        [mcp_servers.actual_user]
        command = "user-authority"
        """.write(to: userConfig, atomically: true, encoding: .utf8)

        let (streams, output, errors) = CLIStreams.buffered()
        let clock = ContinuousClock()
        let started = clock.now
        let exit = CLIRunner.main(
            ["inspect", "--json"],
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": state.path,
                "PWD": workspace.path,
            ],
            streams: streams
        )
        let elapsed = started.duration(to: clock.now)

        #expect(exit == CLIRunner.ExitCode.success.rawValue)
        #expect(elapsed < .seconds(10))
        #expect(errors.contents.isEmpty)
        let data = try #require(output.contents.data(using: .utf8))
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["cwd"] as? String == workspace.standardizedFileURL.path)
        #expect(report["projectRoot"] is NSNull)

        let sources = try #require(report["configSources"] as? [String: Any])
        let layers = try #require(sources["layers"] as? [[String: Any]])
        #expect(layers.contains {
            $0["role"] as? String == "user" && $0["path"] as? String == userConfig.path
        })
        #expect(layers.contains {
            $0["role"] as? String == "project" && $0["path"] as? String == localConfig.path
        })
        #expect(!layers.contains { $0["path"] as? String == ancestorConfig.path })

        let servers = try #require(report["mcpServers"] as? [[String: Any]])
        #expect(servers.map { $0["name"] as? String } == ["actual_user"])
        #expect(!output.contents.contains("ancestor-must-not-load"))

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(!output.contents.contains(repository.path))
    }
}
