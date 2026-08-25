import Foundation
import OpenGrokHooks
import Testing

private struct GlobalHookSourceFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let ownerHooks: URL
    let configuredHooks: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-global-hook-sources-\(UUID().uuidString)")
        home = root.appendingPathComponent("owner")
        workspace = root.appendingPathComponent("workspace")
        ownerHooks = home.appendingPathComponent("hooks")
        configuredHooks = root.appendingPathComponent("configured")
        for directory in [home, workspace, ownerHooks, configuredHooks] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
    }

    var registry: URL {
        home.appendingPathComponent("hooks-paths")
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeRegistry(_ lines: [String], separator: String = "\n") throws {
        try (lines.joined(separator: separator) + separator)
            .write(to: registry, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func writeHook(named name: String, command: String, directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("\(name).json")
        let object: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": command]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return file
    }

    func discover(environment override: [String: String]? = nil) -> HookLoadResult {
        HookDiscovery.loadDefaults(
            workspaceRoot: workspace,
            environment: override ?? environment,
            projectTrusted: false
        )
    }
}

@Suite("owner-global hook source discovery and hostile-path parity")
struct GlobalHookSourceSecurityParityTests {
    @Test("owner hooks and absolute registry directories/files load once in upstream order")
    func absoluteSourcesAreOrderedDeduplicatedAndNonRecursive() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "02-owner", command: "owner-second", directory: fixture.ownerHooks)
        try fixture.writeHook(named: "01-owner", command: "owner-first", directory: fixture.ownerHooks)
        try fixture.writeHook(named: "02-extra", command: "configured-second", directory: fixture.configuredHooks)
        try fixture.writeHook(named: "01-extra", command: "configured-first", directory: fixture.configuredHooks)
        try fixture.writeHook(named: ".hidden", command: "hidden-hook", directory: fixture.configuredHooks)
        let nested = fixture.configuredHooks.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.writeHook(named: "nested", command: "nested-hook", directory: nested)
        let singleDirectory = fixture.root.appendingPathComponent("single")
        try FileManager.default.createDirectory(at: singleDirectory, withIntermediateDirectories: true)
        let single = try fixture.writeHook(named: "settings", command: "configured-file", directory: singleDirectory)
        try fixture.writeRegistry([
            "  \(fixture.configuredHooks.path)  ",
            "relative/hooks",
            fixture.configuredHooks.appendingPathComponent(".").path,
            single.path,
        ], separator: "\r\n")

        let resolved = GlobalHookSourceDiscovery.resolve(environment: fixture.environment)
        let result = fixture.discover()

        #expect(resolved.errors.isEmpty)
        #expect(resolved.sources.map(\.kind) == [.hookDirectory, .registryFile, .configuredSource, .configuredSource])
        #expect(resolved.discoverySources.count == 3)
        #expect(result.errors.isEmpty)
        #expect(result.registry.allHooks().compactMap(\.command) == [
            "owner-first",
            "owner-second",
            "configured-first",
            "configured-second",
            "configured-file",
        ])
    }

    @Test("the hooks-paths control file is never treated as hook JSON")
    func registryIsNotADiscoverySource() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try """
        {"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"registry-executed"}]}]}}
        """.write(to: fixture.registry, atomically: true, encoding: .utf8)

        let resolved = GlobalHookSourceDiscovery.resolve(environment: fixture.environment)
        let result = fixture.discover()

        #expect(resolved.sources.contains { $0.kind == .registryFile && !$0.isDiscoverySource })
        #expect(result.errors.isEmpty)
        #expect(result.registry.isEmpty)
    }

    @Test("an absent configured absolute source is diagnosed without disabling owner hooks")
    func missingConfiguredSourceFailsClosed() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "owner", command: "owner-safe", directory: fixture.ownerHooks)
        try fixture.writeRegistry([fixture.root.appendingPathComponent("does-not-exist").path])

        let result = fixture.discover()

        #expect(result.registry.allHooks().compactMap(\.command) == ["owner-safe"])
        #expect(result.errors.contains { $0.description.contains("does not exist") })
    }

    @Test("a configured source cannot contain the writable OPENGROK_HOME")
    func configuredAncestorOfOwnerStateIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "owner", command: "owner-safe", directory: fixture.ownerHooks)
        try fixture.writeRegistry([fixture.root.path, fixture.home.path])

        let result = fixture.discover()

        #expect(result.registry.allHooks().compactMap(\.command) == ["owner-safe"])
        #expect(result.errors.count == 2)
        #expect(result.errors.allSatisfy { $0.description.contains("cannot contain OPENGROK_HOME") })
    }

    #if !os(Windows)
    @Test("a symbolic-link OPENGROK_HOME cannot contribute executable hook commands")
    func symlinkedOwnerHomeIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "hostile", command: "symlink-home-hook", directory: fixture.ownerHooks)
        let alias = fixture.root.appendingPathComponent("owner-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)

        let result = fixture.discover(environment: ["HOME": fixture.root.path, "OPENGROK_HOME": alias.path])

        #expect(result.registry.isEmpty)
        #expect(result.errors.contains { $0.description.contains("symbolic-link") })
    }

    @Test("a symbolic-link owner hooks directory cannot redirect hook discovery")
    func symlinkedOwnerHookDirectoryIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "hostile", command: "redirected-hook", directory: fixture.configuredHooks)
        try FileManager.default.removeItem(at: fixture.ownerHooks)
        try FileManager.default.createSymbolicLink(at: fixture.ownerHooks, withDestinationURL: fixture.configuredHooks)

        let result = fixture.discover()

        #expect(result.registry.isEmpty)
        #expect(result.errors.contains { $0.description.contains("symbolic-link") })
    }

    @Test("a symbolic-link registry cannot add externally controlled hook sources")
    func symlinkedRegistryIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "owner", command: "owner-safe", directory: fixture.ownerHooks)
        try fixture.writeHook(named: "hostile", command: "registry-redirect", directory: fixture.configuredHooks)
        let externalRegistry = fixture.root.appendingPathComponent("external-registry")
        try fixture.configuredHooks.path.write(to: externalRegistry, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.registry, withDestinationURL: externalRegistry)

        let result = fixture.discover()

        #expect(result.registry.allHooks().compactMap(\.command) == ["owner-safe"])
        #expect(result.errors.contains { $0.description.contains("symbolic-link") })
    }

    @Test("a retargetable ancestor in an absolute configured source cannot load hooks")
    func symlinkedConfiguredAncestorIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "hostile", command: "configured-alias-hook", directory: fixture.configuredHooks)
        let ancestor = fixture.root.appendingPathComponent("configured-alias")
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: fixture.configuredHooks)
        try fixture.writeRegistry([ancestor.path])

        let result = fixture.discover()

        #expect(result.registry.isEmpty)
        #expect(result.errors.contains { $0.description.contains("symbolic-link") })
    }

    @Test("symlink JSON and hard-linked JSON are rejected while safe siblings still load")
    func hostileHookFilesAreRejectedWithoutSuppressingSafeHooks() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "00-safe", command: "safe-hook", directory: fixture.ownerHooks)
        let hostile = try fixture.writeHook(named: "hostile", command: "hostile-hook", directory: fixture.configuredHooks)
        try FileManager.default.createSymbolicLink(
            at: fixture.ownerHooks.appendingPathComponent("01-symlink.json"),
            withDestinationURL: hostile
        )
        try FileManager.default.linkItem(
            at: hostile,
            to: fixture.ownerHooks.appendingPathComponent("02-hardlink.json")
        )

        let result = fixture.discover()

        #expect(result.registry.allHooks().compactMap(\.command) == ["safe-hook"])
        #expect(result.errors.contains { $0.description.contains("symbolic-link") })
        #expect(result.errors.contains { $0.description.contains("hard-link aliases") })
    }

    @Test("a hard-linked hooks-paths registry cannot authorize an alias-controlled source")
    func hardLinkedRegistryIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try fixture.writeHook(named: "hostile", command: "hard-linked-registry-hook", directory: fixture.configuredHooks)
        let source = fixture.root.appendingPathComponent("registry-alias")
        try fixture.configuredHooks.path.write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: source, to: fixture.registry)

        let result = fixture.discover()

        #expect(result.registry.isEmpty)
        #expect(result.errors.contains { $0.description.contains("hard-link aliases") })
    }

    @Test("a configured regular file owned by another user is never parsed")
    func nonOwnerConfiguredSourceIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        let rootOwnedFile = URL(fileURLWithPath: "/etc/hosts")
        let candidateOwner = try FileManager.default.attributesOfItem(atPath: rootOwnedFile.path)[.ownerAccountID] as? NSNumber
        let currentOwner = try FileManager.default.attributesOfItem(atPath: fixture.home.path)[.ownerAccountID] as? NSNumber
        guard candidateOwner != currentOwner else { return }
        try fixture.writeRegistry([rootOwnedFile.path])

        let result = fixture.discover()

        #expect(result.registry.isEmpty)
        #expect(result.errors.contains { $0.description.contains("not owned by the current user") })
    }
    #endif

    @Test("oversized owner hook JSON is rejected before parsing")
    func oversizedHookDocumentIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        let oversized = fixture.ownerHooks.appendingPathComponent("oversized.json")
        try String(repeating: "x", count: GlobalHookSourceDiscovery.maximumHookBytes + 1)
            .write(to: oversized, atomically: true, encoding: .utf8)

        let result = fixture.discover()

        #expect(result.registry.isEmpty)
        #expect(result.errors.contains { $0.description.contains("byte limit") })
    }

    @Test("oversized source registries cannot trigger unbounded source discovery")
    func oversizedRegistryIsRejected() throws {
        let fixture = try GlobalHookSourceFixture()
        defer { fixture.dispose() }
        try String(repeating: "x", count: GlobalHookSourceDiscovery.maximumRegistryBytes + 1)
            .write(to: fixture.registry, atomically: true, encoding: .utf8)

        let result = fixture.discover()

        #expect(result.registry.isEmpty)
        #expect(result.errors.contains { $0.description.contains("byte limit") })
    }
}
