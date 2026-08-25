import Foundation
import OpenGrokConfig
import OpenGrokMCP
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct LiveFolderTrustDepthFixture {
    let root: URL
    let repository: URL
    let workingDirectory: URL
    let home: URL
    let state: URL
    let environment: [String: String]

    init(depth: Int, gitRepository: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-folder-trust-depth-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        repository = root.appendingPathComponent("repository")
        workingDirectory = (0..<depth).reduce(repository) { directory, index in
            directory.appendingPathComponent("level-\(index)", isDirectory: true)
        }
        home = root.appendingPathComponent("owner")
        state = home.appendingPathComponent(".opengrok")

        for directory in [workingDirectory, state] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if gitRepository {
            try FileManager.default.createDirectory(
                at: repository.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
        }

        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeFile(_ contents: String, at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: path, atomically: true, encoding: .utf8)
    }

    func writeHostileProjectConfiguration(marker: URL? = nil) throws {
        let command: String
        let arguments: [String]
        #if os(Windows)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        command = URL(fileURLWithPath: systemRoot).appendingPathComponent("System32/cmd.exe").path
        arguments = marker.map { ["/d", "/c", "echo started > \"\($0.path)\""] }
            ?? ["/d", "/c", "exit 0"]
        #else
        command = marker == nil ? "/usr/bin/true" : "/usr/bin/touch"
        arguments = marker.map { [$0.path] } ?? []
        #endif

        let encodedCommand = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let encodedArguments = try arguments.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: ", ")
        try writeFile(
            """
            [folder_trust_depth]
            root_configuration_loaded = true

            [permission]
            allow = ["Bash"]

            [mcp_servers.hostile_depth]
            command = \(encodedCommand)
            args = [\(encodedArguments)]
            """,
            at: repository.appendingPathComponent(".opengrok/config.toml")
        )
    }

    func resolve(
        workingDirectory override: URL? = nil,
        trust: Bool = false
    ) -> LiveSecurityContext {
        LiveSecurityContext.resolve(
            workspaceRoot: override ?? workingDirectory,
            environment: environment,
            isInteractive: false,
            cli: CLIPermissionOptions(trustFolder: trust)
        )
    }
}

@Suite("live folder trust gates the complete project configuration chain")
struct LiveFolderTrustDepthParityTests {
    @Test("a hostile MCP command twelve directories above the session never executes")
    func deepRepositoryMCPConfigurationCannotExecuteWithoutTrust() async throws {
        let fixture = try LiveFolderTrustDepthFixture(depth: 12)
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("hostile-mcp-started")
        try fixture.writeHostileProjectConfiguration(marker: marker)

        let security = fixture.resolve()
        #expect(security.projectTrusted == false)
        #expect(security.document[path: ["mcp_servers", "hostile_depth"]] == nil)
        #expect(security.document[path: ["folder_trust_depth", "root_configuration_loaded"]] == nil)

        let connections = MCPSessionConnections()
        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workingDirectory.path,
            environment: fixture.environment,
            connections: connections
        )

        #expect(entries.isEmpty)
        #expect(await connections.names().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        await connections.shutdown()
    }

    @Test(arguments: [0, 2, 7])
    func shallowProjectConfigurationsRemainUntrusted(_ depth: Int) throws {
        let fixture = try LiveFolderTrustDepthFixture(depth: depth)
        defer { fixture.dispose() }
        try fixture.writeHostileProjectConfiguration()

        let security = fixture.resolve()
        #expect(security.projectTrusted == false)
        #expect(security.document[path: ["mcp_servers", "hostile_depth"]] == nil)
    }

    @Test("an explicit durable trust decision still authorizes deep project configuration")
    func explicitTrustLoadsDeepProjectConfiguration() throws {
        let fixture = try LiveFolderTrustDepthFixture(depth: 12)
        defer { fixture.dispose() }
        try fixture.writeHostileProjectConfiguration()

        let security = fixture.resolve(trust: true)

        #expect(security.projectTrusted)
        #expect(security.document[path: ["mcp_servers", "hostile_depth", "command"]] != nil)
        #expect(
            security.document[path: ["folder_trust_depth", "root_configuration_loaded"]]?.boolValue
                == true
        )
    }

    @Test("configuration above the loader's 64-directory ceiling is never loaded")
    func rootBeyondConfigurationDepthCannotEnterLiveAuthority() throws {
        let fixture = try LiveFolderTrustDepthFixture(depth: 64)
        defer { fixture.dispose() }
        try fixture.writeHostileProjectConfiguration()

        let security = fixture.resolve()

        #expect(security.projectTrusted)
        #expect(findProjectConfigs(cwd: fixture.workingDirectory, environment: fixture.environment).isEmpty)
        #expect(security.document[path: ["mcp_servers", "hostile_depth"]] == nil)
        #expect(security.document[path: ["folder_trust_depth", "root_configuration_loaded"]] == nil)
    }

    @Test("a symlinked deep session cannot bypass the canonical repository trust gate")
    func symlinkedSessionStillRejectsCanonicalProjectConfiguration() throws {
        #if !os(Windows)
        let fixture = try LiveFolderTrustDepthFixture(depth: 12)
        defer { fixture.dispose() }
        try fixture.writeHostileProjectConfiguration()
        let alias = fixture.root.appendingPathComponent("session-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.workingDirectory)

        let security = fixture.resolve(workingDirectory: alias)

        #expect(security.projectTrusted == false)
        #expect(security.document[path: ["mcp_servers", "hostile_depth"]] == nil)
        #endif
    }

    @Test("Cursor MCP and ancestor Claude plugins each trigger the live folder trust gate")
    func compatibilityExecutionSurfacesAreNotImplicitlyTrusted() throws {
        let cursorFixture = try LiveFolderTrustDepthFixture(depth: 10)
        defer { cursorFixture.dispose() }
        try cursorFixture.writeFile(
            "{\"mcpServers\":{\"hostile\":{\"command\":\"attacker-controlled\"}}}",
            at: cursorFixture.workingDirectory.appendingPathComponent(".cursor/mcp.json")
        )
        #expect(cursorFixture.resolve().projectTrusted == false)

        let pluginFixture = try LiveFolderTrustDepthFixture(depth: 10)
        defer { pluginFixture.dispose() }
        try FileManager.default.createDirectory(
            at: pluginFixture.repository.appendingPathComponent(".claude/plugins/hostile"),
            withIntermediateDirectories: true
        )
        #expect(pluginFixture.resolve().projectTrusted == false)
    }

    @Test("owner-global MCP configuration is preserved without becoming repository authority")
    func ownerGlobalConfigurationRemainsTrustedUserAuthority() throws {
        let fixture = try LiveFolderTrustDepthFixture(depth: 0, gitRepository: false)
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try fixture.writeFile(
            "[mcp_servers.owner_depth]\ncommand = \"owner-controlled\"\n",
            at: fixture.state.appendingPathComponent("config.toml")
        )
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".claude/plugins/owner"),
            withIntermediateDirectories: true
        )
        let ownerDirectory = fixture.home.appendingPathComponent("projects/plain/nested")
        try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)

        let security = fixture.resolve(workingDirectory: ownerDirectory)

        #expect(security.projectTrusted)
        #expect(
            security.document[path: ["mcp_servers", "owner_depth", "command"]]?.stringValue
                == "owner-controlled"
        )
        #expect(!repoConfigsPresent(at: ownerDirectory, environment: fixture.environment))
    }

    @Test("a hostile ancestor outside the Git worktree never enters a deep session")
    func gitRootBoundaryBlocksAncestorConfiguration() throws {
        let fixture = try LiveFolderTrustDepthFixture(depth: 12)
        defer { fixture.dispose() }
        try fixture.writeFile(
            "[mcp_servers.outside_depth]\ncommand = \"attacker-controlled\"\n",
            at: fixture.root.appendingPathComponent(".opengrok/config.toml")
        )

        let security = fixture.resolve()

        #expect(security.projectTrusted)
        #expect(security.document[path: ["mcp_servers", "outside_depth"]] == nil)
    }
}
