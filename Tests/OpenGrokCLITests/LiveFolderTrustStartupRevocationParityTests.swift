import Foundation
import OpenGrokFastWorktree
import OpenGrokLSP
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct LiveFolderTrustStartupFixture: Sendable {
    let root: URL
    let ownerHome: URL
    let openGrokHome: URL
    let source: URL
    let environment: [String: String]

    init() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-trust-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        root = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
        ownerHome = root.appendingPathComponent("owner", isDirectory: true)
        openGrokHome = ownerHome.appendingPathComponent(".opengrok", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        for directory in [ownerHome, openGrokHome, source] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var variables = [
            "HOME": ownerHome.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_SANDBOX": "off",
            "GROK_FOLDER_TRUST": "1",
            "GROK_LSP_TOOLS": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        #if os(Windows)
        if let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] {
            variables["SystemRoot"] = systemRoot
        }
        if let commandInterpreter = ProcessInfo.processInfo.environment["COMSPEC"] {
            variables["COMSPEC"] = commandInterpreter
        }
        #endif
        environment = variables

        try initializeRepository(at: source)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent(".opengrok/workflows", isDirectory: true),
            withIntermediateDirectories: true
        )
        try grant(source)
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func initializeRepository(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "--quiet"], cwd: directory)
        try "startup trust parity\n".write(
            to: directory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "README.md"], cwd: directory)
        try git([
            "-c", "user.email=startup-trust@example.test",
            "-c", "user.name=Startup Trust",
            "commit", "--quiet", "-m", "initial",
        ], cwd: directory)
    }

    func git(_ arguments: [String], cwd: URL) throws {
        let result = try runGit(arguments, cwd: cwd)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "LiveFolderTrustStartupRevocationParityTests",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
    }

    func linkedCheckout(name: String = "linked") throws -> URL {
        let destination = root.appendingPathComponent(name, isDirectory: true)
        try git(["worktree", "add", "--quiet", "--detach", destination.path, "HEAD"], cwd: source)
        return destination.standardizedFileURL.resolvingSymlinksInPath()
    }

    func grant(_ repository: URL) throws {
        var store = PersistentFolderTrustStore(environment: environment)
        try store.record(repository, trusted: true)
    }

    func writeProject(in checkout: URL, processMarker: URL, hookMarker: URL) throws {
        let configuration = checkout.appendingPathComponent(".opengrok", isDirectory: true)
        let hooks = configuration.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)

        let command: String
        let arguments: [String]
        let hookCommand: String
        #if os(Windows)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        command = URL(fileURLWithPath: systemRoot).appendingPathComponent("System32/cmd.exe").path
        arguments = ["/d", "/c", "echo started > \"\(processMarker.path)\""]
        hookCommand = "cmd /d /c echo executed > \"\(hookMarker.path)\""
        #else
        command = "/usr/bin/touch"
        arguments = [processMarker.path]
        hookCommand = "/usr/bin/touch '\(hookMarker.path)'"
        #endif

        let encodedCommand = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let encodedArguments = try arguments.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: ", ")
        try """
        [mcp_servers.startup_project]
        command = \(encodedCommand)
        args = [\(encodedArguments)]
        """.write(
            to: configuration.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let hookDocument: [String: Any] = [
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": hookCommand]]]]],
        ]
        try JSONSerialization.data(withJSONObject: hookDocument)
            .write(to: hooks.appendingPathComponent("startup.json"))

        let languageServer = LspServerConfig(
            command: command,
            args: [],
            extensions: [".swift": "swift"]
        )
        try JSONEncoder().encode(["startup_project": languageServer])
            .write(to: configuration.appendingPathComponent("lsp.json"))
    }

    func writeOwnerMCP(marker: URL) throws {
        let command: String
        let arguments: [String]
        #if os(Windows)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        command = URL(fileURLWithPath: systemRoot).appendingPathComponent("System32/cmd.exe").path
        arguments = ["/d", "/c", "echo started > \"\(marker.path)\""]
        #else
        command = "/usr/bin/touch"
        arguments = [marker.path]
        #endif
        let encodedCommand = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let encodedArguments = try arguments.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: ", ")
        try """
        [mcp_servers.startup_owner]
        command = \(encodedCommand)
        args = [\(encodedArguments)]
        """.write(
            to: openGrokHome.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func executor(
        checkout: URL,
        sessionID: String,
        barrier: LiveFolderTrustStartupBarrier? = nil
    ) async throws -> LiveToolExecutor {
        try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            sessionID: sessionID,
            workingDirectory: checkout,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment,
            permissionOptions: CLIPermissionOptions(allowRules: ["Bash"]),
            startupTrustCheckpoint: { checkpoint in
                if case .beforeProjectMCP = checkpoint {
                    await barrier?.pause()
                }
            }
        )
    }

    func change(_ trusted: Bool, sessionID: String, executor: LiveToolExecutor) async -> String {
        await LiveFolderTrustControls.change(
            trusted: trusted,
            workingDirectory: executor.workingDirectory,
            sessionID: sessionID,
            environment: environment,
            executor: executor
        )
    }

    func invokeShell(_ executor: LiveToolExecutor, sessionID: String) async -> Bool {
        #if os(Windows)
        let command = "echo ok"
        #else
        let command = "/usr/bin/true"
        #endif
        let result = await executor.invoke(
            sessionID: sessionID,
            workingDirectory: executor.workingDirectory,
            call: ToolCall(
                id: UUID().uuidString,
                name: "run_terminal_cmd",
                arguments: "{\"command\":\"\(command)\"}"
            )
        )
        if case .success = result { return true }
        return false
    }
}

private actor LiveFolderTrustStartupBarrier {
    private var arrived = false
    private var released = false
    private var arrivalContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        arrived = true
        arrivalContinuation?.resume()
        arrivalContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalContinuation = continuation
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Suite("folder trust cannot be revoked during project process startup")
struct LiveFolderTrustStartupRevocationParityTests {
    @Test("source revocation before linked project MCP launch never starts hostile code")
    func sourceRevocationPreventsLinkedProjectMCPHooksAndLSP() async throws {
        let fixture = try LiveFolderTrustStartupFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.linkedCheckout()
        let projectMarker = fixture.root.appendingPathComponent("linked-project-process-ran")
        let hookMarker = fixture.root.appendingPathComponent("linked-project-hook-ran")
        let ownerMarker = fixture.root.appendingPathComponent("owner-process-ran")
        try fixture.writeProject(in: checkout, processMarker: projectMarker, hookMarker: hookMarker)
        try fixture.writeOwnerMCP(marker: ownerMarker)

        let source = try await fixture.executor(checkout: fixture.source, sessionID: "startup-source")
        let sourceInitiallyTrusted = source.projectTrusted
        let initialOwnerProcessStarted = FileManager.default.fileExists(atPath: ownerMarker.path)
        #expect(sourceInitiallyTrusted)
        #expect(initialOwnerProcessStarted)
        try FileManager.default.removeItem(at: ownerMarker)

        let barrier = LiveFolderTrustStartupBarrier()
        let newbornTask = Task {
            try await fixture.executor(
                checkout: checkout,
                sessionID: "startup-linked",
                barrier: barrier
            )
        }
        await barrier.waitUntilArrived()
        let projectBeforeRevoke = FileManager.default.fileExists(atPath: projectMarker.path)
        #expect(projectBeforeRevoke == false)

        let revoked = await fixture.change(false, sessionID: "startup-source", executor: source)
        let ownerAfterRevocation = source.projectTrusted
        let markerAfterRevocation = FileManager.default.fileExists(atPath: projectMarker.path)
        #expect(revoked.hasPrefix("Untrusted:"))
        #expect(ownerAfterRevocation == false)
        #expect(markerAfterRevocation == false)

        await barrier.release()
        let newborn = try await newbornTask.value
        let projectAfterStartup = FileManager.default.fileExists(atPath: projectMarker.path)
        let ownerAfterStartup = FileManager.default.fileExists(atPath: ownerMarker.path)
        let exposesProjectLSP = newborn.currentToolSpecs().contains { $0.name == "pull_diagnostics" }
        let newbornIsTrusted = newborn.projectTrusted
        let launchesOwnerMCP = newborn.mcpServerConnections.contains { $0.name == "startup_owner" }
        let launchesProjectMCP = newborn.mcpServerConnections.contains { $0.name == "startup_project" }
        #expect(newbornIsTrusted == false)
        #expect(projectAfterStartup == false)
        #expect(ownerAfterStartup)
        #expect(launchesOwnerMCP)
        #expect(launchesProjectMCP == false)
        #expect(exposesProjectLSP == false)

        let ownerShellStillWorks = await fixture.invokeShell(newborn, sessionID: "startup-linked")
        let projectHookExecuted = FileManager.default.fileExists(atPath: hookMarker.path)
        #expect(ownerShellStillWorks)
        #expect(projectHookExecuted == false)

        await newborn.shutdown()
        await source.shutdown()
    }

    @Test("explicit regrant during a paused startup restores only newly authorized project code")
    func regrantDuringStartupRestoresTrustedLinkedSources() async throws {
        let fixture = try LiveFolderTrustStartupFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.linkedCheckout(name: "regranted-linked")
        let projectMarker = fixture.root.appendingPathComponent("regranted-project-process-ran")
        let hookMarker = fixture.root.appendingPathComponent("regranted-project-hook-ran")
        try fixture.writeProject(in: checkout, processMarker: projectMarker, hookMarker: hookMarker)

        let source = try await fixture.executor(checkout: fixture.source, sessionID: "regrant-source")
        let barrier = LiveFolderTrustStartupBarrier()
        let newbornTask = Task {
            try await fixture.executor(
                checkout: checkout,
                sessionID: "regrant-linked",
                barrier: barrier
            )
        }
        await barrier.waitUntilArrived()

        let revoked = await fixture.change(false, sessionID: "regrant-source", executor: source)
        let deniedProcessStarted = FileManager.default.fileExists(atPath: projectMarker.path)
        #expect(revoked.hasPrefix("Untrusted:"))
        #expect(deniedProcessStarted == false)

        let restored = await fixture.change(true, sessionID: "regrant-source", executor: source)
        let processBeforeAuthorizedStartup = FileManager.default.fileExists(atPath: projectMarker.path)
        #expect(restored.hasPrefix("Trusted:"))
        #expect(processBeforeAuthorizedStartup == false)

        await barrier.release()
        let newborn = try await newbornTask.value
        let projectStartedAfterGrant = FileManager.default.fileExists(atPath: projectMarker.path)
        let projectLSPAvailable = newborn.currentToolSpecs().contains { $0.name == "pull_diagnostics" }
        let newbornIsTrusted = newborn.projectTrusted
        #expect(newbornIsTrusted)
        #expect(projectStartedAfterGrant)
        #expect(projectLSPAvailable)

        let trustedShellSucceeded = await fixture.invokeShell(newborn, sessionID: "regrant-linked")
        let projectHookExecuted = FileManager.default.fileExists(atPath: hookMarker.path)
        #expect(trustedShellSucceeded)
        #expect(projectHookExecuted)

        await newborn.shutdown()
        await source.shutdown()
    }

    @Test("a durable external revocation is rechecked even without an in-process broadcast")
    func externalStoreRevocationBlocksProjectLaunchAtTheLastStartupGate() async throws {
        let fixture = try LiveFolderTrustStartupFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.linkedCheckout(name: "externally-revoked-startup")
        let projectMarker = fixture.root.appendingPathComponent("external-revoke-project-ran")
        let hookMarker = fixture.root.appendingPathComponent("external-revoke-hook-ran")
        try fixture.writeProject(in: checkout, processMarker: projectMarker, hookMarker: hookMarker)

        let barrier = LiveFolderTrustStartupBarrier()
        let newbornTask = Task {
            try await fixture.executor(
                checkout: checkout,
                sessionID: "external-startup",
                barrier: barrier
            )
        }
        await barrier.waitUntilArrived()
        var store = PersistentFolderTrustStore(environment: fixture.environment)
        try store.record(fixture.source, trusted: false)
        let persistedGrant = PersistentFolderTrustStore(environment: fixture.environment)
            .isTrusted(fixture.source)
        #expect(persistedGrant == false)

        await barrier.release()
        let newborn = try await newbornTask.value
        let projectProcessStarted = FileManager.default.fileExists(atPath: projectMarker.path)
        let projectLSPAvailable = newborn.currentToolSpecs().contains { $0.name == "pull_diagnostics" }
        let newbornIsTrusted = newborn.projectTrusted
        #expect(newbornIsTrusted == false)
        #expect(projectProcessStarted == false)
        #expect(projectLSPAvailable == false)
        await newborn.shutdown()
    }

    @Test("revoking one repository cannot suppress another trusted startup")
    func unrelatedRepositoryRevocationDoesNotPoisonIndependentStartup() async throws {
        let fixture = try LiveFolderTrustStartupFixture()
        defer { fixture.dispose() }
        let unrelated = fixture.root.appendingPathComponent("independent", isDirectory: true)
        try fixture.initializeRepository(at: unrelated)
        try fixture.grant(unrelated)
        let projectMarker = fixture.root.appendingPathComponent("independent-project-ran")
        let hookMarker = fixture.root.appendingPathComponent("independent-hook-ran")
        try fixture.writeProject(in: unrelated, processMarker: projectMarker, hookMarker: hookMarker)

        let source = try await fixture.executor(checkout: fixture.source, sessionID: "unrelated-source")
        let barrier = LiveFolderTrustStartupBarrier()
        let independentTask = Task {
            try await fixture.executor(
                checkout: unrelated,
                sessionID: "independent-startup",
                barrier: barrier
            )
        }
        await barrier.waitUntilArrived()

        let revoked = await fixture.change(false, sessionID: "unrelated-source", executor: source)
        let unrelatedStillTrusted = PersistentFolderTrustStore(environment: fixture.environment)
            .isTrusted(unrelated)
        #expect(revoked.hasPrefix("Untrusted:"))
        #expect(unrelatedStillTrusted)

        await barrier.release()
        let independent = try await independentTask.value
        let independentProcessStarted = FileManager.default.fileExists(atPath: projectMarker.path)
        let independentIsTrusted = independent.projectTrusted
        #expect(independentIsTrusted)
        #expect(independentProcessStarted)

        await independent.shutdown()
        await source.shutdown()
    }
}
