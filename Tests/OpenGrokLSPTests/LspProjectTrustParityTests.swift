import Foundation
import OpenGrokLSP
import Testing

private struct LspProjectTrustFixture {
    let root: URL
    let workspace: URL
    let userConfig: URL
    let projectConfig: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-lsp-config-trust-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        userConfig = root.appendingPathComponent("owner/lsp.json")
        projectConfig = workspace.appendingPathComponent(".opengrok/lsp.json")
        for directory in [userConfig.deletingLastPathComponent(), projectConfig.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(
        _ configuration: [String: LspServerConfig],
        to location: URL
    ) throws {
        try JSONEncoder().encode(configuration).write(to: location)
    }

    func configuration(command: String) -> LspServerConfig {
        LspServerConfig(command: command, extensions: [".swift": "swift"])
    }
}

@Suite("LSP project configuration trust and source provenance")
struct LspProjectTrustParityTests {
    @Test("the workspace-aware loader denies project commands by default")
    func projectConfigurationIsFailClosedByDefault() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.write(["owner": fixture.configuration(command: "owner-server")], to: fixture.userConfig)
        try fixture.write(["project": fixture.configuration(command: "project-server")], to: fixture.projectConfig)

        let servers = LSPConfigLoader.loadMerged(
            userConfigPath: fixture.userConfig,
            projectConfigPath: fixture.projectConfig,
            workspaceRoot: fixture.workspace
        )

        #expect(servers.keys.sorted() == ["owner"])
        #expect(servers["owner"]?.command == "owner-server")
    }

    @Test("an untrusted collision cannot override or erase an owner server")
    func untrustedProjectCollisionPreservesOwnerConfiguration() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.write(["swift": fixture.configuration(command: "owner-server")], to: fixture.userConfig)
        try fixture.write(["swift": fixture.configuration(command: "hostile-server")], to: fixture.projectConfig)

        let servers = LSPConfigLoader.loadMerged(
            userConfigPath: fixture.userConfig,
            projectConfigPath: fixture.projectConfig,
            workspaceRoot: fixture.workspace,
            projectTrusted: false
        )

        #expect(servers.count == 1)
        #expect(servers["swift"]?.command == "owner-server")
    }

    @Test("an explicitly trusted project retains its normal override precedence")
    func trustedProjectOverridesOwnerConfiguration() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.write(["swift": fixture.configuration(command: "owner-server")], to: fixture.userConfig)
        try fixture.write(["swift": fixture.configuration(command: "trusted-project")], to: fixture.projectConfig)

        let sourced = LSPConfigLoader.loadSourced(
            userConfigPath: fixture.userConfig,
            projectConfigPath: fixture.projectConfig,
            workspaceRoot: fixture.workspace,
            projectTrusted: true
        )

        #expect(sourced["swift"]?.configuration.command == "trusted-project")
        #expect(sourced["swift"]?.source == .project)
        #expect(LSPConfigLoader.filterProjectServers(sourced).isEmpty)
        #expect(
            LSPConfigLoader.filterProjectServers(sourced, projectTrusted: true)["swift"]?.command
                == "trusted-project"
        )
    }

    @Test("owner and project source provenance is retained independently")
    func sourceProvenanceSurvivesTheMerge() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.write(["owner": fixture.configuration(command: "owner-server")], to: fixture.userConfig)
        try fixture.write(["project": fixture.configuration(command: "project-server")], to: fixture.projectConfig)

        let sourced = LSPConfigLoader.loadSourced(
            userConfigPath: fixture.userConfig,
            projectConfigPath: fixture.projectConfig,
            workspaceRoot: fixture.workspace,
            projectTrusted: true
        )

        #expect(sourced["owner"]?.source == .user)
        #expect(sourced["project"]?.source == .project)
        #expect(LSPConfigLoader.filterProjectServers(sourced).keys.sorted() == ["owner"])
    }

    @Test("a repo-owned config cannot masquerade as the owner config")
    func projectConfigurationPassedAsOwnerIsStillTrustGated() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.write(["hostile": fixture.configuration(command: "hostile-server")], to: fixture.projectConfig)

        let denied = LSPConfigLoader.loadMerged(
            userConfigPath: fixture.projectConfig,
            projectConfigPath: nil,
            workspaceRoot: fixture.workspace
        )
        let allowed = LSPConfigLoader.loadSourced(
            userConfigPath: fixture.projectConfig,
            projectConfigPath: nil,
            workspaceRoot: fixture.workspace,
            projectTrusted: true
        )

        #expect(denied.isEmpty)
        #expect(allowed["hostile"]?.source == .project)
    }

    @Test("a sibling whose name shares the workspace prefix is not contained")
    func sharedPathPrefixCannotEscapeTheWorkspaceBoundary() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        let sibling = fixture.root.appendingPathComponent("workspace-attacker/lsp.json")
        try FileManager.default.createDirectory(
            at: sibling.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fixture.write(["hostile": fixture.configuration(command: "outside-server")], to: sibling)

        let servers = LSPConfigLoader.loadMerged(
            userConfigPath: nil,
            projectConfigPath: sibling,
            workspaceRoot: fixture.workspace,
            projectTrusted: true
        )

        #expect(servers.isEmpty)
    }

    @Test("invalid project JSON cannot erase a valid owner configuration")
    func malformedProjectConfigurationPreservesOwnerConfiguration() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.write(["owner": fixture.configuration(command: "owner-server")], to: fixture.userConfig)
        try "{invalid json".write(to: fixture.projectConfig, atomically: true, encoding: .utf8)

        let servers = LSPConfigLoader.loadMerged(
            userConfigPath: fixture.userConfig,
            projectConfigPath: fixture.projectConfig,
            workspaceRoot: fixture.workspace,
            projectTrusted: true
        )

        #expect(servers.keys.sorted() == ["owner"])
    }

    #if !os(Windows)
    @Test("a trusted repo cannot follow its project config symlink outside the repo")
    func projectSymlinkOutsideWorkspaceIsRejected() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        let outside = fixture.root.appendingPathComponent("outside-lsp.json")
        try fixture.write(["hostile": fixture.configuration(command: "outside-server")], to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.projectConfig, withDestinationURL: outside)

        let servers = LSPConfigLoader.loadMerged(
            userConfigPath: nil,
            projectConfigPath: fixture.projectConfig,
            workspaceRoot: fixture.workspace,
            projectTrusted: true
        )

        #expect(servers.isEmpty)
    }

    @Test("an owner-config symlink into an untrusted repo does not bypass its scope")
    func ownerConfigAliasIntoUntrustedRepositoryIsRejected() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.write(["hostile": fixture.configuration(command: "hostile-server")], to: fixture.projectConfig)
        try FileManager.default.createSymbolicLink(
            at: fixture.userConfig,
            withDestinationURL: fixture.projectConfig
        )

        let servers = LSPConfigLoader.loadMerged(
            userConfigPath: fixture.userConfig,
            projectConfigPath: fixture.projectConfig,
            workspaceRoot: fixture.workspace
        )

        #expect(servers.isEmpty)
    }

    @Test("workspace aliases retain canonical trust boundaries")
    func canonicalWorkspaceAliasCannotBypassTrust() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.write(["project": fixture.configuration(command: "project-server")], to: fixture.projectConfig)
        let alias = fixture.root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.workspace)
        let aliasedProject = alias.appendingPathComponent(".opengrok/lsp.json")

        let denied = LSPConfigLoader.loadMerged(
            userConfigPath: nil,
            projectConfigPath: aliasedProject,
            workspaceRoot: alias
        )
        let allowed = LSPConfigLoader.loadMerged(
            userConfigPath: nil,
            projectConfigPath: aliasedProject,
            workspaceRoot: alias,
            projectTrusted: true
        )

        #expect(denied.isEmpty)
        #expect(allowed["project"]?.command == "project-server")
    }

    @Test("a symlinked project configuration directory cannot escape the repo")
    func projectDirectorySymlinkOutsideWorkspaceIsRejected() throws {
        let fixture = try LspProjectTrustFixture()
        defer { fixture.dispose() }
        let projectDirectory = fixture.projectConfig.deletingLastPathComponent()
        try FileManager.default.removeItem(at: projectDirectory)
        let outside = fixture.root.appendingPathComponent("outside-config")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try fixture.write(
            ["hostile": fixture.configuration(command: "outside-server")],
            to: outside.appendingPathComponent("lsp.json")
        )
        try FileManager.default.createSymbolicLink(at: projectDirectory, withDestinationURL: outside)

        let servers = LSPConfigLoader.loadMerged(
            userConfigPath: nil,
            projectConfigPath: fixture.projectConfig,
            workspaceRoot: fixture.workspace,
            projectTrusted: true
        )

        #expect(servers.isEmpty)
    }
    #endif
}
