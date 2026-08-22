import Foundation
import OpenGrokConfig
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct LivePersistentFolderTrustFixture {
    let root: URL
    let home: URL
    let state: URL
    let workspace: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-persistent-trust-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        state = home.appendingPathComponent(".opengrok")
        workspace = root.appendingPathComponent("workspace")
        for directory in [state, workspace.appendingPathComponent(".opengrok")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try """
        [persistent_trust_fixture]
        project_configuration_loaded = true
        """.write(
            to: workspace.appendingPathComponent(".opengrok/config.toml"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "1",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func resolve(
        workspace override: URL? = nil,
        environment overrideEnvironment: [String: String]? = nil,
        trust: Bool = false
    ) -> LiveSecurityContext {
        LiveSecurityContext.resolve(
            workspaceRoot: override ?? workspace,
            environment: overrideEnvironment ?? environment,
            isInteractive: false,
            cli: CLIPermissionOptions(trustFolder: trust)
        )
    }
}

@Suite("explicit folder trust survives fresh live security resolutions")
struct LivePersistentFolderTrustParityTests {
    @Test("--trust writes an owner-private grant before loading repository configuration")
    func explicitTrustPersistsBeforeProjectConfigurationLoads() throws {
        let fixture = try LivePersistentFolderTrustFixture()
        defer { fixture.dispose() }

        let security = fixture.resolve(trust: true)
        let trustPath = fixture.state.appendingPathComponent("trusted_folders.toml")

        #expect(security.projectTrusted)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
        #expect(security.document[path: ["persistent_trust_fixture", "project_configuration_loaded"]]?.boolValue == true)
        #if !os(Windows)
        let permissions = try FileManager.default.attributesOfItem(atPath: trustPath.path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.uint16Value == 0o600)
        #else
        #expect(FileManager.default.fileExists(atPath: trustPath.path))
        #endif
    }

    @Test("a fresh launch without --trust honors the previous durable decision")
    func freshResolutionReadsPersistedExplicitGrant() throws {
        let fixture = try LivePersistentFolderTrustFixture()
        defer { fixture.dispose() }

        #expect(fixture.resolve().projectTrusted == false)
        #expect(fixture.resolve(trust: true).projectTrusted)

        let relaunched = fixture.resolve()
        #expect(relaunched.projectTrusted)
        #expect(relaunched.document[path: ["persistent_trust_fixture", "project_configuration_loaded"]]?.boolValue == true)
    }

    @Test("without an explicit grant a repository configuration remains untrusted")
    func noImplicitTrustDecisionIsPersisted() throws {
        let fixture = try LivePersistentFolderTrustFixture()
        defer { fixture.dispose() }

        let first = fixture.resolve()
        let second = fixture.resolve()

        #expect(first.projectTrusted == false)
        #expect(second.projectTrusted == false)
        #expect(first.document[path: ["persistent_trust_fixture", "project_configuration_loaded"]] == nil)
        #expect(FileManager.default.fileExists(
            atPath: fixture.state.appendingPathComponent("trusted_folders.toml").path
        ) == false)
    }

    @Test("failed durable persistence cannot authorize repository-owned configuration")
    func failedPersistenceRejectsTheExplicitGrant() throws {
        let fixture = try LivePersistentFolderTrustFixture()
        defer { fixture.dispose() }
        let trustPath = fixture.state.appendingPathComponent("trusted_folders.toml")
        try FileManager.default.createDirectory(at: trustPath, withIntermediateDirectories: true)

        let denied = fixture.resolve(trust: true)

        #expect(denied.projectTrusted == false)
        #expect(denied.document[path: ["persistent_trust_fixture", "project_configuration_loaded"]] == nil)
        #expect(fixture.resolve().projectTrusted == false)
    }

    @Test("trusting a symlink persists only its canonical workspace identity")
    func symlinkTrustDoesNotAuthorizeSiblingsOrParents() throws {
        #if !os(Windows)
        let fixture = try LivePersistentFolderTrustFixture()
        defer { fixture.dispose() }
        let alias = fixture.root.appendingPathComponent("workspace-alias")
        let sibling = fixture.root.appendingPathComponent("sibling")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.workspace)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        #expect(fixture.resolve(workspace: alias, trust: true).projectTrusted)

        let persisted = PersistentFolderTrustStore(environment: fixture.environment)
        #expect(persisted.isTrusted(fixture.workspace))
        #expect(persisted.isTrusted(alias))
        #expect(persisted.isTrusted(sibling) == false)
        #expect(persisted.isTrusted(fixture.root) == false)
        let contents = try String(
            contentsOf: fixture.state.appendingPathComponent("trusted_folders.toml"),
            encoding: .utf8
        )
        #expect(contents.contains(fixture.workspace.resolvingSymlinksInPath().path))
        #expect(contents.contains(alias.path) == false)
        #endif
    }

    @Test("--trust refuses to durably authorize the user's entire home directory")
    func unsafeHomeRootFailsClosed() throws {
        let fixture = try LivePersistentFolderTrustFixture()
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".opengrok/hooks"),
            withIntermediateDirectories: true
        )

        let denied = fixture.resolve(workspace: fixture.home, trust: true)

        #expect(denied.projectTrusted == false)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.home) == false)
        #expect(FileManager.default.fileExists(
            atPath: fixture.state.appendingPathComponent("trusted_folders.toml").path
        ) == false)
    }
}
