import Foundation
import Testing
@testable import OpenGrokSandbox

@Suite("owner-global sandbox hook write protection")
struct HookWriteDenyParityTests {
    private struct Fixture {
        let root: URL
        let home: URL
        let workspace: URL
        let environment: [String: String]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenGrokHookWriteDeny-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            home = root.appendingPathComponent("owner-home", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            environment = ["OPENGROK_HOME": home.path]
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try ensureGlobalHookSlots(environment: environment)
        }

        var hooks: URL { home.appendingPathComponent("hooks", isDirectory: true) }
        var registry: URL { home.appendingPathComponent("hooks-paths") }

        func write(_ value: String, to path: URL) throws {
            try value.write(to: path, atomically: false, encoding: .utf8)
        }

        func dispose() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("workspace, strict, and read-only protect hooks; devbox inheritance does not")
    func profileClassificationMatchesUpstream() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let config = SandboxConfig(profiles: [
            "development": ProfileConfig(extends: "devbox"),
            "guarded": ProfileConfig(extends: "workspace"),
        ])

        for profile in [ProfileName.workspace, .strict, .readOnly, .custom("guarded")] {
            #expect(requiresHookWriteDeny(profile: profile, workspace: fixture.workspace, config: config))
            let resolved = try profile.resolve(
                workspace: fixture.workspace,
                config: config,
                environment: fixture.environment
            )
            #expect(resolved.writeDeny.map(\.path.path) == [fixture.hooks.path, fixture.registry.path])
            #expect(resolved.readWrite.contains(where: { $0.path == fixture.home.path }))
        }

        for profile in [ProfileName.off, .devbox, .custom("development")] {
            #expect(!requiresHookWriteDeny(profile: profile, workspace: fixture.workspace, config: config))
        }
        let development = try ProfileName.custom("development").resolve(
            workspace: fixture.workspace,
            config: config,
            environment: fixture.environment
        )
        #expect(development.writeDeny.isEmpty)
    }

    @Test("slot preparation creates real owner-global slots without truncating the registry")
    func slotPreparationPreservesRegistry() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        try fixture.write("# existing owner configuration\n", to: fixture.registry)

        try ensureGlobalHookSlots(environment: fixture.environment)

        #expect(try String(contentsOf: fixture.registry, encoding: .utf8)
            == "# existing owner configuration\n")
        let directory = try captureHookPathIdentity(fixture.hooks)
        let registry = try captureHookPathIdentity(fixture.registry)
        #expect(directory.isDirectory)
        #expect(!registry.isDirectory)
        #expect(registry.linkCount == 1)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("installed-plugins").path
        ))
    }

    @Test("installed plugin registries, manifests, hooks, and scripts share one immutable root")
    func installedPluginExecutableAuthorityIsProtected() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let installed = fixture.home.appendingPathComponent("installed-plugins", isDirectory: true)
        let plugin = installed.appendingPathComponent("example-repo", isDirectory: true)
        let manifestDirectory = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
        let hookDirectory = plugin.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
        let registry = installed.appendingPathComponent("registry.json")
        let manifest = manifestDirectory.appendingPathComponent("plugin.json")
        let hooks = hookDirectory.appendingPathComponent("hooks.json")
        let executable = plugin.appendingPathComponent("run-hook.sh")
        for authority in [registry, manifest, hooks, executable] {
            try fixture.write("{}", to: authority)
        }

        let resolved = try ProfileName.workspace.resolve(
            workspace: fixture.workspace,
            config: SandboxConfig(),
            environment: fixture.environment
        )
        let source = try #require(resolved.writeDeny.first(where: {
            $0.kind == .installedPluginDirectory
        }))
        #expect(source.path.path == installed.path)

        let plan = try buildHookWriteDenyPlan(
            sources: resolved.writeDeny,
            writableRoots: [fixture.home]
        )
        #expect(plan.leaves.contains(where: { $0.path.path == installed.path }))
        let snapshot = try #require(plan.directorySnapshots.first(where: {
            $0.directory.path == installed.path
        }))
        #expect(snapshot.recursive)
        for authority in [registry, manifest, hooks, executable] {
            #expect(snapshot.files.contains(where: { $0.path.path == authority.path }))
        }

        let command = try #require(bwrapReexecCommand(
            denyWrite: [],
            denyRead: [],
            environment: fixture.environment,
            executable: URL(fileURLWithPath: "/bin/open-grok"),
            readWrite: [fixture.home.path],
            hookWriteDeny: plan
        ))
        #expect(bindingIndex(command, operation: "--ro-bind", path: installed.path) != nil)
        #expect(bindingIndex(command, operation: "--ro-bind", path: fixture.home.path) == nil)

        let lateAuthority = plugin.appendingPathComponent("late-hook.sh")
        try fixture.write("new executable authority", to: lateAuthority)
        #expect(throws: HookWriteDenyError.directorySnapshotChanged(installed)) {
            try revalidateHookWriteDenyPlan(plan)
        }

        #if os(macOS)
        let seatbelt = buildSeatbeltProfile(resolved, workspace: fixture.workspace)
        #expect(seatbelt.contains("(deny file-write* (subpath \"\(installed.path)\"))"))
        #expect(!seatbelt.contains("(deny file-write* (subpath \"\(fixture.home.path)\"))"))
        #endif
    }

    @Test("installed plugin hard-link aliases and symlink escapes refuse activation", arguments: [
        "hard-link",
        "symlink",
    ])
    func installedPluginAliasesAreRejected(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let installed = fixture.home.appendingPathComponent("installed-plugins", isDirectory: true)
        let plugin = installed.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let authority = plugin.appendingPathComponent("hook-authority")
        try fixture.write("executable", to: authority)

        if kind == "hard-link" {
            try FileManager.default.linkItem(
                at: authority,
                to: fixture.root.appendingPathComponent("writable-plugin-alias")
            )
        } else {
            try FileManager.default.createSymbolicLink(
                at: plugin.appendingPathComponent("outside"),
                withDestinationURL: fixture.workspace
            )
        }

        #expect(throws: HookWriteDenyError.self) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }
    }

    @Test("absolute configured directories/files are deduplicated; relative registry lines stay inert")
    func configuredSourcesPreserveOwnerScope() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let configuredDirectory = fixture.root.appendingPathComponent("configured-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredDirectory, withIntermediateDirectories: true)
        let configuredFile = configuredDirectory.appendingPathComponent("configured.json")
        try fixture.write("{}", to: configuredFile)
        try fixture.write("{}", to: fixture.hooks.appendingPathComponent("hooks.json"))
        try fixture.write(
            "  \(configuredDirectory.path)  \r\nrelative/hooks.json\r\n"
                + "\(configuredFile.path)\r\n\(configuredDirectory.path)\r\n",
            to: fixture.registry
        )

        let sources = try resolveHookWriteDenySources(environment: fixture.environment)

        #expect(sources.map(\.path.path) == [
            fixture.hooks.path,
            fixture.registry.path,
            configuredDirectory.path,
            configuredFile.path,
        ])
        #expect(sources.map(\.kind) == [
            .hookDirectory,
            .registryFile,
            .configuredSource,
            .configuredSource,
        ])
        let plan = try buildHookWriteDenyPlan(sources: sources, writableRoots: [fixture.home])
        #expect(plan.leaves.contains(where: {
            $0.path.path == fixture.hooks.appendingPathComponent("hooks.json").path
        }))
        #expect(plan.leaves.contains(where: { $0.path.path == configuredFile.path }))
    }

    @Test("missing configured absolute sources refuse profile resolution")
    func missingConfiguredSourceFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let missing = fixture.root.appendingPathComponent("not-created.json")
        try fixture.write("\(missing.path)\n", to: fixture.registry)

        #expect(throws: HookWriteDenyError.missingConfigured(missing)) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }
        #expect(throws: HookWriteDenyError.self) {
            try ProfileName.workspace.resolve(
                workspace: fixture.workspace,
                config: SandboxConfig(),
                environment: fixture.environment
            )
        }
    }

    @Test("oversized owner-global hook registries fail closed before unbounded reads")
    func oversizedRegistryIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        try fixture.write(String(repeating: "#", count: 256 * 1_024 + 1), to: fixture.registry)

        #expect(throws: HookWriteDenyError.self) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }
    }

    @Test("configured ancestor and traversal entries cannot swallow writable owner state")
    func configuredAncestorsAndTraversalAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }

        try fixture.write("\(fixture.root.path)\n", to: fixture.registry)
        #expect(throws: HookWriteDenyError.invalidSource(fixture.root)) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }

        let traversed = "\(fixture.root.path)/workspace/../owner-home/hooks"
        try fixture.write("\(traversed)\n", to: fixture.registry)
        #expect(throws: HookWriteDenyError.self) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }
    }

    @Test("symlinked owner home and hook slots fail closed")
    func ownerHomeAndHookSymlinksAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let alias = fixture.root.appendingPathComponent("owner-home-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)

        #expect(throws: HookWriteDenyError.self) {
            try resolveHookWriteDenySources(environment: ["OPENGROK_HOME": alias.path])
        }
        #expect(throws: HookWriteDenyError.self) {
            try ensureGlobalHookSlots(environment: ["OPENGROK_HOME": alias.path])
        }

        try FileManager.default.removeItem(at: fixture.hooks)
        try FileManager.default.createSymbolicLink(at: fixture.hooks, withDestinationURL: fixture.workspace)
        #expect(throws: HookWriteDenyError.self) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }
    }

    @Test("a symlinked ancestor of a configured source cannot escape protection")
    func configuredSymlinkAncestorIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let real = fixture.root.appendingPathComponent("real-configured", isDirectory: true)
        let nested = real.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = fixture.root.appendingPathComponent("configured-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        try fixture.write("\(alias.appendingPathComponent("hooks").path)\n", to: fixture.registry)

        #expect(throws: HookWriteDenyError.self) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }
    }

    @Test("symlinked immediate hooks.json entries refuse startup")
    func symlinkedDirectJSONIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let outside = fixture.root.appendingPathComponent("outside.json")
        try fixture.write("{}", to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.hooks.appendingPathComponent("hooks.json"),
            withDestinationURL: outside
        )

        #expect(throws: HookWriteDenyError.self) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }
    }

    @Test("hard-linked hook JSON, registry, and configured files are refused", arguments: [
        "hook-json",
        "registry",
        "configured-file",
    ])
    func hardLinkAliasesAreRejected(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let target: URL
        switch kind {
        case "hook-json":
            target = fixture.hooks.appendingPathComponent("hooks.json")
            try fixture.write("{}", to: target)
        case "registry":
            target = fixture.registry
        default:
            target = fixture.root.appendingPathComponent("configured.json")
            try fixture.write("{}", to: target)
            try fixture.write("\(target.path)\n", to: fixture.registry)
        }
        try FileManager.default.linkItem(
            at: target,
            to: fixture.root.appendingPathComponent("writable-hard-link")
        )

        #expect(throws: HookWriteDenyError.self) {
            try resolveHookWriteDenySources(environment: fixture.environment)
        }
    }

    @Test("late JSON insertion and renamed source identities invalidate captured plans")
    func sourceAndSnapshotRacesFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let existing = fixture.hooks.appendingPathComponent("hooks.json")
        try fixture.write("{}", to: existing)
        let sources = try resolveHookWriteDenySources(environment: fixture.environment)
        let plan = try buildHookWriteDenyPlan(sources: sources, writableRoots: [fixture.home])
        try revalidateHookWriteDenyPlan(plan)

        let late = fixture.hooks.appendingPathComponent("late.json")
        try fixture.write("{}", to: late)
        #expect(throws: HookWriteDenyError.directorySnapshotChanged(fixture.hooks)) {
            try revalidateHookWriteDenyPlan(plan)
        }
        try FileManager.default.removeItem(at: late)

        let displaced = fixture.root.appendingPathComponent("displaced-hooks")
        try FileManager.default.moveItem(at: fixture.hooks, to: displaced)
        try FileManager.default.createDirectory(at: fixture.hooks, withIntermediateDirectories: false)
        #expect(throws: HookWriteDenyError.identityChanged(fixture.hooks)) {
            try revalidateHookWriteDenyPlan(plan)
        }
    }

    @Test("bubblewrap ancestor pins never grant writable hostile siblings")
    func bubblewrapPlanDoesNotWidenWritableRoots() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let hostileSibling = fixture.root.appendingPathComponent("hostile-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: hostileSibling, withIntermediateDirectories: true)
        let sources = try resolveHookWriteDenySources(environment: fixture.environment)
        let plan = try buildHookWriteDenyPlan(sources: sources, writableRoots: [fixture.home])

        #expect(plan.writableAncestors.contains(where: { $0.path.path == fixture.home.path }))
        #expect(!plan.writableAncestors.contains(where: { $0.path.path == fixture.root.path }))
        #expect(!plan.writableAncestors.contains(where: { $0.path.path == "/" }))
        let arguments = try #require(bwrapReexecCommand(
            denyWrite: [],
            denyRead: [],
            environment: fixture.environment,
            executable: URL(fileURLWithPath: "/bin/open-grok"),
            readWrite: [fixture.home.path],
            hookWriteDeny: plan
        ))

        let homePin = try #require(bindingIndex(arguments, operation: "--bind", path: fixture.home.path))
        let directoryDeny = try #require(bindingIndex(arguments, operation: "--ro-bind", path: fixture.hooks.path))
        let registryDeny = try #require(bindingIndex(arguments, operation: "--ro-bind", path: fixture.registry.path))
        #expect(homePin < directoryDeny)
        #expect(homePin < registryDeny)
        #expect(bindingIndex(arguments, operation: "--bind", path: fixture.root.path) == nil)
        #expect(bindingIndex(arguments, operation: "--bind", path: hostileSibling.path) == nil)
    }

    @Test("strict profiles refuse configured sources outside their existing readable roots")
    func strictPlanDoesNotWidenReadableRoots() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let external = fixture.root.appendingPathComponent("external.json")
        try fixture.write("{}", to: external)
        try fixture.write("\(external.path)\n", to: fixture.registry)
        let sources = try resolveHookWriteDenySources(environment: fixture.environment)

        #expect(throws: HookWriteDenyError.inaccessibleUnderProfile(external)) {
            try buildHookWriteDenyPlan(
                sources: sources,
                writableRoots: [fixture.home],
                readableRoots: [fixture.workspace],
                defaultRead: false
            )
        }
    }

    #if os(Linux)
    @Test("an ordinary writable filesystem never qualifies as enforced hook isolation")
    func linuxVerificationRejectsWritableHookMounts() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let sources = try resolveHookWriteDenySources(environment: fixture.environment)

        #expect(throws: HookWriteDenyError.notReadOnly(fixture.hooks)) {
            try verifyHookWriteDenyEnforced(sources)
        }
    }

    @Test("hook-bearing Linux profiles remain fail-closed even when graceful fallback was requested")
    func linuxHookProtectionCannotDegradeGracefully() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let environment = fixture.environment
        let seams = LinuxBwrapReexecHooks(
            environment: { environment },
            arguments: { [] },
            executable: { "/bin/open-grok" },
            supportInfo: {
                SandboxSupportInfo(isSupported: false, backend: .none, details: "injected unavailable")
            },
            discoverBubblewrap: { _ in nil },
            probe: { _ in false },
            exec: { _, _, _ in
                throw SandboxError.enforcementFailed("unavailable backend reached exec")
            }
        )
        let manager = SandboxManager(
            profile: .workspace,
            workspace: fixture.workspace,
            failClosed: false,
            linuxReexecHooks: seams
        )

        #expect(throws: SandboxError.self) {
            try manager.apply(workspace: fixture.workspace)
        }
        #expect(!manager.applied)
    }
    #endif

    #if os(macOS)
    @Test("the applied Seatbelt profile denies every hook mutation while keeping owner state writable")
    func seatbeltProfileAppliesNarrowWriteDenies() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let configured = fixture.workspace.appendingPathComponent("configured-hooks.json")
        try fixture.write("{}", to: configured)
        try fixture.write("{}", to: fixture.hooks.appendingPathComponent("hooks.json"))
        try fixture.write("\(configured.path)\n", to: fixture.registry)
        let resolved = try ProfileName.workspace.resolve(
            workspace: fixture.workspace,
            config: SandboxConfig(),
            environment: fixture.environment
        )

        let profile = buildSeatbeltProfile(resolved, workspace: fixture.workspace)

        #expect(profile.contains("(allow file-read* file-write* (subpath \"\(fixture.home.path)\"))"))
        #expect(!profile.contains("(deny file-write* (subpath \"\(fixture.home.path)\"))"))
        #expect(profile.contains("(deny file-write* (subpath \"\(fixture.hooks.path)\"))"))
        #expect(profile.contains("(deny file-write* (literal \"\(fixture.registry.path)\"))"))
        #expect(profile.contains("(deny file-write* (literal \"\(configured.path)\"))"))
        #expect(profile.contains("(deny file-write-unlink (literal \"\(fixture.home.path)\"))"))
        #expect(profile.contains("(allow file-read* (subpath \"\(fixture.hooks.path)\"))"))
        #expect(!profile.contains("(deny file-read* (subpath \"\(fixture.hooks.path)\"))"))
        for action in seatbeltWriteDenyActions {
            #expect(profile.contains("(deny \(action) (subpath \"\(fixture.hooks.path)\"))"))
            #expect(profile.contains("(deny \(action) (literal \"\(fixture.registry.path)\"))"))
        }
    }
    #endif

    private func bindingIndex(_ arguments: [String], operation: String, path: String) -> Int? {
        guard arguments.count >= 3 else { return nil }
        for index in 0...(arguments.count - 3)
        where arguments[index] == operation
            && arguments[index + 1] == path
            && arguments[index + 2] == path {
            return index
        }
        return nil
    }
}
