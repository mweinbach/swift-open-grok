import Foundation
import OpenGrokConfig
import OpenGrokWorkspace
import Testing

private struct FolderTrustDepthFixture {
    let root: URL
    let repository: URL
    let home: URL
    let state: URL
    let environment: [String: String]

    init(gitRepository: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-folder-trust-depth-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        repository = root.appendingPathComponent("repository")
        home = root.appendingPathComponent("owner")
        state = home.appendingPathComponent(".opengrok")

        for directory in [repository, state] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if gitRepository {
            try FileManager.default.createDirectory(
                at: repository.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
        }

        environment = ["HOME": home.path, "OPENGROK_HOME": state.path]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func nestedDirectory(depth: Int, under base: URL? = nil) throws -> URL {
        let directory = (0..<depth).reduce(base ?? repository) { current, index in
            current.appendingPathComponent("level-\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func writeFile(_ contents: String, at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: path, atomically: true, encoding: .utf8)
    }
}

@Suite("folder trust follows the authoritative project directory chain")
struct FolderTrustDepthSecurityParityTests {
    @Test("a repository-root MCP declaration twelve directories above cwd requires trust")
    func deepRepositoryConfigurationCannotEscapeTheTrustScan() throws {
        let fixture = try FolderTrustDepthFixture()
        defer { fixture.dispose() }
        let nested = try fixture.nestedDirectory(depth: 12)
        let configuration = fixture.repository.appendingPathComponent(".opengrok/config.toml")
        try fixture.writeFile(
            "[mcp_servers.hostile]\ncommand = \"attacker-controlled\"\n",
            at: configuration
        )

        #expect(findProjectConfigs(cwd: nested, environment: fixture.environment) == [configuration])
        #expect(repoConfigsPresent(at: nested, environment: fixture.environment))
        #expect(decideFolderTrust(
            featureEnabled: true,
            inputs: FolderTrustDecideInputs(
                storeTrusted: false,
                repoConfigsPresent: repoConfigsPresent(at: nested, environment: fixture.environment),
                isInteractive: false,
                keyRecordable: true
            )
        ) == .untrusted)
    }

    @Test("the farthest root accepted by the 64-directory config loader is still gated")
    func lastLoadableAncestorCannotEscapeTheTrustScan() throws {
        let fixture = try FolderTrustDepthFixture()
        defer { fixture.dispose() }
        let nested = try fixture.nestedDirectory(depth: 63)
        try fixture.writeFile(
            "[permission]\nallow = [\"Bash\"]\n",
            at: fixture.repository.appendingPathComponent(".opengrok/config.toml")
        )

        #expect(projectDirChain(cwd: nested, environment: fixture.environment).count == 64)
        #expect(findProjectConfigs(cwd: nested, environment: fixture.environment).count == 1)
        #expect(repoConfigsPresent(at: nested, environment: fixture.environment))
    }

    @Test("a root beyond the loader's 64-directory boundary cannot enter project authority")
    func configurationBeyondLoaderDepthIsNotPromoted() throws {
        let fixture = try FolderTrustDepthFixture()
        defer { fixture.dispose() }
        let nested = try fixture.nestedDirectory(depth: 64)
        try fixture.writeFile(
            "[mcp_servers.unreachable]\ncommand = \"attacker-controlled\"\n",
            at: fixture.repository.appendingPathComponent(".opengrok/config.toml")
        )

        #expect(projectDirChain(cwd: nested, environment: fixture.environment) == [nested])
        #expect(findProjectConfigs(cwd: nested, environment: fixture.environment).isEmpty)
        #expect(!repoConfigsPresent(at: nested, environment: fixture.environment))
    }

    @Test("Cursor MCP compatibility files and Claude plugin directories are executable markers")
    func upstreamCompatibilityMarkersRequireTrust() throws {
        let cursorFixture = try FolderTrustDepthFixture()
        defer { cursorFixture.dispose() }
        let cursorDirectory = try cursorFixture.nestedDirectory(depth: 10)
        try cursorFixture.writeFile(
            "{\"mcpServers\":{\"hostile\":{\"command\":\"attacker-controlled\"}}}",
            at: cursorDirectory.appendingPathComponent(".cursor/mcp.json")
        )
        #expect(repoConfigsPresent(at: cursorDirectory, environment: cursorFixture.environment))

        let pluginFixture = try FolderTrustDepthFixture()
        defer { pluginFixture.dispose() }
        let pluginDirectory = try pluginFixture.nestedDirectory(depth: 10)
        try FileManager.default.createDirectory(
            at: pluginFixture.repository.appendingPathComponent(".claude/plugins/hostile"),
            withIntermediateDirectories: true
        )
        #expect(repoConfigsPresent(at: pluginDirectory, environment: pluginFixture.environment))
    }

    @Test("the trust scanner never crosses the Git root to inspect an ancestor project")
    func ancestorBeyondGitBoundaryDoesNotTaintRepository() throws {
        let fixture = try FolderTrustDepthFixture()
        defer { fixture.dispose() }
        let nested = try fixture.nestedDirectory(depth: 12)
        try fixture.writeFile(
            "[mcp_servers.outside]\ncommand = \"attacker-controlled\"\n",
            at: fixture.root.appendingPathComponent(".opengrok/config.toml")
        )
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(".claude/plugins/outside"),
            withIntermediateDirectories: true
        )

        #expect(findProjectConfigs(cwd: nested, environment: fixture.environment).isEmpty)
        #expect(!repoConfigsPresent(at: nested, environment: fixture.environment))
    }

    @Test("a non-Git ancestor configuration is not promoted into project scope")
    func nonRepositoryAncestorConfigurationIsNotProjectOwned() throws {
        let fixture = try FolderTrustDepthFixture(gitRepository: false)
        defer { fixture.dispose() }
        let nested = try fixture.nestedDirectory(depth: 12)
        try fixture.writeFile(
            "[mcp_servers.outside]\ncommand = \"attacker-controlled\"\n",
            at: fixture.repository.appendingPathComponent(".opengrok/config.toml")
        )

        #expect(projectDirChain(cwd: nested, environment: fixture.environment) == [nested])
        #expect(findProjectConfigs(cwd: nested, environment: fixture.environment).isEmpty)
        #expect(!repoConfigsPresent(at: nested, environment: fixture.environment))
    }

    @Test("a symlinked deep working directory still gates its canonical repository root")
    func symlinkedWorkingDirectoryCannotHideRepositoryConfiguration() throws {
        #if !os(Windows)
        let fixture = try FolderTrustDepthFixture()
        defer { fixture.dispose() }
        let nested = try fixture.nestedDirectory(depth: 12)
        let alias = fixture.root.appendingPathComponent("repository-alias")
        try fixture.writeFile(
            "[mcp_servers.hostile]\ncommand = \"attacker-controlled\"\n",
            at: fixture.repository.appendingPathComponent(".opengrok/config.toml")
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)

        #expect(repoConfigsPresent(at: alias, environment: fixture.environment))
        #endif
    }

    @Test("HOME dotfiles and the owner-global Open Grok configuration remain user authority")
    func ownerGlobalConfigurationIsNeverMistakenForRepositoryConfiguration() throws {
        let fixture = try FolderTrustDepthFixture(gitRepository: false)
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try fixture.writeFile(
            "[mcp_servers.owner]\ncommand = \"owner-controlled\"\n",
            at: fixture.state.appendingPathComponent("config.toml")
        )
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".claude/plugins/owner"),
            withIntermediateDirectories: true
        )
        let ownerProject = try fixture.nestedDirectory(depth: 3, under: fixture.home)

        #expect(projectDirChain(cwd: ownerProject, environment: fixture.environment) == [ownerProject])
        #expect(!repoConfigsPresent(at: ownerProject, environment: fixture.environment))
        #expect(!repoConfigsPresent(at: fixture.home, environment: fixture.environment))
    }

    @Test("a dangling Claude plugin marker fails closed")
    func danglingClaudePluginDirectoryCannotHideRepositoryCode() throws {
        #if !os(Windows)
        let fixture = try FolderTrustDepthFixture()
        defer { fixture.dispose() }
        let nested = try fixture.nestedDirectory(depth: 11)
        let claude = fixture.repository.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: claude.appendingPathComponent("plugins").path,
            withDestinationPath: "missing-hostile-plugins"
        )

        #expect(repoConfigsPresent(at: nested, environment: fixture.environment))
        #endif
    }
}
