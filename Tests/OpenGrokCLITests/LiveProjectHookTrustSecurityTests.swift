import Foundation
import OpenGrokHooks
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct LiveProjectHookTrustFixture {
    let root: URL
    let repository: URL
    let ownerHome: URL
    let openGrokHome: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-project-hook-trust-\(UUID().uuidString)")
        repository = root.appendingPathComponent("repository")
        ownerHome = root.appendingPathComponent("owner")
        openGrokHome = ownerHome.appendingPathComponent(".opengrok")
        for directory in [repository, ownerHome, openGrokHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": ownerHome.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_SANDBOX": "off",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeHook(named name: String, marker: URL, project: Bool) throws {
        let directory = project
            ? repository.appendingPathComponent(".opengrok/hooks")
            : openGrokHome.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let command = "/usr/bin/touch '\(marker.path)'"
        let document: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": command]]],
                ],
            ],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: document)
        try encoded.write(to: directory.appendingPathComponent("\(name).json"))
    }

    func writeManagedHook(marker: URL) throws {
        try """
        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "/usr/bin/touch '\(marker.path)'"
        """.write(
            to: openGrokHome.appendingPathComponent("managed_config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func trustRepository() throws {
        var store = PersistentFolderTrustStore(environment: environment)
        try store.record(repository, trusted: true)
        #expect(PersistentFolderTrustStore(environment: environment).isTrusted(repository))
    }

    func invokeRealTool(
        environment override: [String: String]? = nil,
        permissionOptions: CLIPermissionOptions = CLIPermissionOptions(allowRules: ["Bash"]),
        securityContext: LiveSecurityContext? = nil
    ) async throws {
        let effectiveEnvironment = override ?? environment
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: effectiveEnvironment),
            sessionID: "project-hook-trust",
            workingDirectory: repository,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: effectiveEnvironment,
            securityContext: securityContext,
            permissionOptions: permissionOptions
        )
        let result = await executor.invoke(
            sessionID: "project-hook-trust",
            workingDirectory: repository,
            call: ToolCall(
                id: "real-trust-gated-tool",
                name: "run_terminal_cmd",
                arguments: #"{"command":"/usr/bin/true"}"#
            )
        )
        await executor.shutdown()
        switch result {
        case .success:
            break
        case .failure(let error):
            Issue.record("the actual live tool did not dispatch: \(error)")
        }
    }

    func advertisedHooks(projectTrusted: Bool? = nil) -> [String] {
        LiveExtensionsComposition.hookRows(
            workingDirectory: repository.path,
            openGrokHome: openGrokHome,
            sessionID: "project-hook-trust",
            environment: environment,
            projectTrusted: projectTrusted
        ).compactMap(\.command)
    }
}

@Suite("live project hooks obey folder trust before command discovery")
struct LiveProjectHookTrustSecurityTests {
    @Test("a hooks-only untrusted clone never spawns or advertises its command")
    func hostileProjectHookCannotExecuteOrAppearInTheExtensionsUI() async throws {
        let fixture = try LiveProjectHookTrustFixture()
        defer { fixture.dispose() }
        let hostileMarker = fixture.root.appendingPathComponent("hostile-project-executed")
        try fixture.writeHook(named: "hostile", marker: hostileMarker, project: true)

        let security = LiveSecurityContext.resolve(
            workspaceRoot: fixture.repository,
            environment: fixture.environment,
            isInteractive: false
        )
        #expect(security.projectTrusted == false)
        #expect(fixture.advertisedHooks().isEmpty)

        try await fixture.invokeRealTool()

        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
    }

    @Test("owner and managed command hooks still spawn while hostile project hooks do not")
    func trustedOwnerSourcesSurviveAnUntrustedProject() async throws {
        let fixture = try LiveProjectHookTrustFixture()
        defer { fixture.dispose() }
        let hostileMarker = fixture.root.appendingPathComponent("hostile-project-executed")
        let ownerMarker = fixture.root.appendingPathComponent("owner-hook-executed")
        let managedMarker = fixture.root.appendingPathComponent("managed-hook-executed")
        try fixture.writeHook(named: "hostile", marker: hostileMarker, project: true)
        try fixture.writeHook(named: "owner", marker: ownerMarker, project: false)
        try fixture.writeManagedHook(marker: managedMarker)

        let visible = fixture.advertisedHooks()
        #expect(visible.contains { $0.contains(ownerMarker.path) })
        #expect(visible.contains { $0.contains(managedMarker.path) })
        #expect(visible.allSatisfy { !$0.contains(hostileMarker.path) })

        try await fixture.invokeRealTool()

        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
        #expect(FileManager.default.fileExists(atPath: ownerMarker.path))
        #expect(FileManager.default.fileExists(atPath: managedMarker.path))
    }

    @Test("persisted explicit trust makes the actual project hook execute and appear")
    func durableOwnerTrustAllowsRealProjectHookExecution() async throws {
        let fixture = try LiveProjectHookTrustFixture()
        defer { fixture.dispose() }
        let trustedMarker = fixture.root.appendingPathComponent("trusted-project-executed")
        try fixture.writeHook(named: "trusted", marker: trustedMarker, project: true)
        try fixture.trustRepository()

        #expect(fixture.advertisedHooks().contains { $0.contains(trustedMarker.path) })

        try await fixture.invokeRealTool()

        #expect(FileManager.default.fileExists(atPath: trustedMarker.path))
    }

    @Test("an explicit --trust decision is forwarded to discovery without a second policy")
    func explicitTrustFlagAllowsTheProjectHook() async throws {
        let fixture = try LiveProjectHookTrustFixture()
        defer { fixture.dispose() }
        let trustedMarker = fixture.root.appendingPathComponent("cli-trusted-project-executed")
        try fixture.writeHook(named: "trusted", marker: trustedMarker, project: true)

        #expect(fixture.advertisedHooks().isEmpty)
        #expect(fixture.advertisedHooks(projectTrusted: false).isEmpty)
        #expect(fixture.advertisedHooks(projectTrusted: true).contains { $0.contains(trustedMarker.path) })

        try await fixture.invokeRealTool(
            permissionOptions: CLIPermissionOptions(allowRules: ["Bash"], trustFolder: true)
        )

        #expect(FileManager.default.fileExists(atPath: trustedMarker.path))
    }

    @Test("an owner-disabled folder-trust feature retains upstream project-hook behavior")
    func disabledFolderTrustFeaturePreservesExplicitPolicy() async throws {
        let fixture = try LiveProjectHookTrustFixture()
        defer { fixture.dispose() }
        let trustedMarker = fixture.root.appendingPathComponent("feature-disabled-project-executed")
        try fixture.writeHook(named: "trusted", marker: trustedMarker, project: true)
        var environment = fixture.environment
        environment["GROK_FOLDER_TRUST"] = "0"

        try await fixture.invokeRealTool(environment: environment)

        #expect(FileManager.default.fileExists(atPath: trustedMarker.path))
    }

    @Test("a supplied authoritative untrusted context cannot be widened by a later CLI flag")
    func authoritativeSecurityVerdictCannotBeBypassed() async throws {
        let fixture = try LiveProjectHookTrustFixture()
        defer { fixture.dispose() }
        let hostileMarker = fixture.root.appendingPathComponent("authoritative-policy-bypassed")
        try fixture.writeHook(named: "hostile", marker: hostileMarker, project: true)
        let authoritative = LiveSecurityContext.resolve(
            workspaceRoot: fixture.repository,
            environment: fixture.environment,
            isInteractive: false
        )
        #expect(authoritative.projectTrusted == false)

        try await fixture.invokeRealTool(
            permissionOptions: CLIPermissionOptions(allowRules: ["Bash"], trustFolder: true),
            securityContext: authoritative
        )

        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
        #expect(fixture.advertisedHooks(projectTrusted: authoritative.projectTrusted).isEmpty)
    }

    @Test("a disabled trusted project hook remains visible but its command never spawns")
    func disabledTrustedHookIsAdvertisedWithoutExecuting() async throws {
        let fixture = try LiveProjectHookTrustFixture()
        defer { fixture.dispose() }
        let disabledMarker = fixture.root.appendingPathComponent("disabled-project-executed")
        try fixture.writeHook(named: "disabled", marker: disabledMarker, project: true)
        try fixture.trustRepository()
        let loaded = LiveHooksComposition.load(
            sessionId: "project-hook-trust",
            workspaceRoot: fixture.repository,
            environment: fixture.environment,
            projectTrusted: true
        )
        let hookName = try #require(loaded.result.registry.allHooks().first?.name)
        try "\(hookName)\n".write(
            to: fixture.openGrokHome.appendingPathComponent("disabled-hooks"),
            atomically: true,
            encoding: .utf8
        )
        let rows = LiveExtensionsComposition.hookRows(
            workingDirectory: fixture.repository.path,
            openGrokHome: fixture.openGrokHome,
            sessionID: "project-hook-trust",
            environment: fixture.environment,
            projectTrusted: true
        )
        #expect(rows.count == 1)
        #expect(rows.first?.disabled == true)

        try await fixture.invokeRealTool()

        #expect(FileManager.default.fileExists(atPath: disabledMarker.path) == false)
    }
}
