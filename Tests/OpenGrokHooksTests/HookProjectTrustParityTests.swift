import Foundation
import OpenGrokHooks
import Testing

private struct HookProjectTrustFixture {
    let root: URL
    let project: URL
    let global: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-hook-project-trust-\(UUID().uuidString)")
        project = root.appendingPathComponent("repository/.opengrok/hooks")
        global = root.appendingPathComponent("owner/hooks")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        environment = ["OPENGROK_HOME": root.appendingPathComponent("owner").path]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeHook(named name: String, command: String, directory: URL) throws {
        let object: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": command]]],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: directory.appendingPathComponent("\(name).json"))
    }
}

@Suite("project hook discovery requires an explicit trust verdict")
struct HookProjectTrustParityTests {
    @Test("discovery denies project sources by default and preserves owner hooks")
    func unspecifiedProjectTrustFailsClosed() throws {
        let fixture = try HookProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "owner", command: "owner-hook", directory: fixture.global)
        try fixture.writeHook(named: "repository", command: "repository-hook", directory: fixture.project)

        let result = HookDiscovery.load(
            globalDirectory: fixture.global,
            projectDirectory: fixture.project,
            environment: fixture.environment
        )

        #expect(result.errors.isEmpty)
        #expect(result.registry.allHooks().compactMap(\.command) == ["owner-hook"])
        #expect(result.registry.allHooks().allSatisfy { $0.name.hasPrefix("global/") })
    }

    @Test("an untrusted project source is not parsed or reported")
    func untrustedProjectIsNeverInspected() throws {
        let fixture = try HookProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "owner", command: "owner-hook", directory: fixture.global)
        try "not valid json".write(
            to: fixture.project.appendingPathComponent("hostile.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = HookDiscovery.load(
            globalSources: [.directory(fixture.global)],
            projectSources: [.directory(fixture.project)],
            environment: fixture.environment,
            projectTrusted: false
        )

        #expect(result.errors.isEmpty)
        #expect(result.registry.allHooks().compactMap(\.command) == ["owner-hook"])
    }

    @Test("an explicitly trusted project loads alongside owner hooks")
    func explicitlyTrustedProjectIsDiscovered() throws {
        let fixture = try HookProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "owner", command: "owner-hook", directory: fixture.global)
        try fixture.writeHook(named: "repository", command: "repository-hook", directory: fixture.project)

        let result = HookDiscovery.loadDefaults(
            workspaceRoot: fixture.root.appendingPathComponent("repository"),
            environment: fixture.environment,
            projectTrusted: true
        )

        #expect(result.errors.isEmpty)
        #expect(result.registry.allHooks().compactMap(\.command) == ["owner-hook", "repository-hook"])
        #expect(result.registry.allHooks().map(\.name).contains { $0.hasPrefix("project/") })
    }

    @Test("the session loader never silently upgrades an omitted project verdict")
    func sessionLoaderPropagatesTheExactTrustVerdict() throws {
        let fixture = try HookProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "repository", command: "repository-hook", directory: fixture.project)
        let repository = fixture.root.appendingPathComponent("repository")

        let untrusted = HookSessionLoader.load(
            configDocument: nil,
            configPath: fixture.root.appendingPathComponent("config.toml"),
            workspaceRoot: repository,
            environment: fixture.environment
        )
        let trusted = HookSessionLoader.load(
            configDocument: nil,
            configPath: fixture.root.appendingPathComponent("config.toml"),
            workspaceRoot: repository,
            environment: fixture.environment,
            projectTrusted: true
        )

        #expect(untrusted.registry.isEmpty)
        #expect(trusted.registry.allHooks().compactMap(\.command) == ["repository-hook"])
    }

    @Test("trusted discovery resolves a symlinked workspace to its canonical hook root")
    func trustedWorkspaceAliasResolvesCanonicalProjectDirectory() throws {
        #if !os(Windows)
        let fixture = try HookProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "repository", command: "repository-hook", directory: fixture.project)
        let alias = fixture.root.appendingPathComponent("repository-alias")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture.root.appendingPathComponent("repository")
        )

        let result = HookDiscovery.loadDefaults(
            workspaceRoot: alias,
            environment: fixture.environment,
            projectTrusted: true
        )

        #expect(result.registry.allHooks().compactMap(\.command) == ["repository-hook"])
        #endif
    }
}
