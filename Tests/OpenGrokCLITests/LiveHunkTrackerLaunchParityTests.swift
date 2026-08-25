import Foundation
import OpenGrokFileTools
import OpenGrokHunkTracker
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private enum LiveHunkTrackerObservedMode: Equatable, Sendable {
    case off
    case agentOnly
    case allDirty
}

private struct LiveHunkTrackerLaunchObservation: Sendable {
    let mode: LiveHunkTrackerObservedMode
    let projectTrusted: Bool
    let sessionID: String?
}

private struct LiveHunkTrackerLaunchFixture: Sendable {
    let root: URL
    let workspace: URL
    let openGrokHome: URL
    let environment: [String: String]

    init() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-hunk-launch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        root = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let ownerHome = root.appendingPathComponent("owner", isDirectory: true)
        openGrokHome = ownerHome.appendingPathComponent(".opengrok", isDirectory: true)

        for directory in [workspace, ownerHome, openGrokHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var variables = [
            "HOME": ownerHome.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_SANDBOX": "off",
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
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeUserMode(_ mode: String) throws {
        try "[ui]\nhunk_tracker_mode = \"\(mode)\"\n".write(
            to: openGrokHome.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeProjectMode(_ mode: String) throws {
        let projectConfiguration = workspace.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectConfiguration,
            withIntermediateDirectories: true
        )
        try "[ui]\nhunk_tracker_mode = \"\(mode)\"\n".write(
            to: projectConfiguration.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func executor(
        sessionID: String,
        commandLineMode: String? = nil,
        environmentOverrides: [String: String] = [:],
        policy: FileToolAccessPolicy = .allowAll,
        trustFolder: Bool = false
    ) async throws -> LiveToolExecutor {
        let sessionEnvironment = environment.merging(environmentOverrides) { _, override in
            override
        }
        return try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: sessionEnvironment),
            sessionID: sessionID,
            workingDirectory: workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: policy,
            environment: sessionEnvironment,
            permissionOptions: CLIPermissionOptions(trustFolder: trustFolder),
            hunkTrackerMode: commandLineMode
        )
    }

    func observe(
        commandLineMode: String? = nil,
        environmentOverrides: [String: String] = [:],
        trustFolder: Bool = false
    ) async throws -> LiveHunkTrackerLaunchObservation {
        let sessionID = "hunk-launch-\(UUID().uuidString)"
        let executor = try await executor(
            sessionID: sessionID,
            commandLineMode: commandLineMode,
            environmentOverrides: environmentOverrides,
            trustFolder: trustFolder
        )
        let projectTrusted = executor.projectTrusted
        guard let tracker = executor.mcpToolset.resources.hunkTracker else {
            await executor.shutdown()
            return LiveHunkTrackerLaunchObservation(
                mode: .off,
                projectTrusted: projectTrusted,
                sessionID: nil
            )
        }

        let externalFile = workspace.appendingPathComponent("external-\(UUID().uuidString).txt")
        do {
            try "external change\n".write(to: externalFile, atomically: true, encoding: .utf8)
        } catch {
            await executor.shutdown()
            throw error
        }
        await tracker.handleFileChange(path: externalFile.path)
        let tracked = await tracker.getAllTrackedPaths().contains(externalFile.path)
        let actorSessionID = await tracker.currentSessionId
        await executor.shutdown()
        return LiveHunkTrackerLaunchObservation(
            mode: tracked ? .allDirty : .agentOnly,
            projectTrusted: projectTrusted,
            sessionID: actorSessionID
        )
    }

    func invokeWrite(
        executor: LiveToolExecutor,
        sessionID: String,
        path: URL,
        content: String = "agent content\n"
    ) async throws -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let arguments = try JSONEncoder().encode([
            "file_path": path.path,
            "content": content,
        ])
        return await executor.invoke(
            sessionID: sessionID,
            workingDirectory: workspace,
            call: ToolCall(
                id: "hunk-write-\(UUID().uuidString)",
                name: "write",
                arguments: String(decoding: arguments, as: UTF8.self)
            )
        )
    }
}

@Suite("pinned Rust live hunk tracker launch parity")
struct LiveHunkTrackerLaunchParityTests {
    @Test("default tracker ignores external dirty files and belongs to its own session")
    func defaultIsSessionBoundAgentOnly() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }

        let first = try await fixture.observe()
        let second = try await fixture.observe()

        #expect(first.mode == .agentOnly)
        #expect(second.mode == .agentOnly)
        #expect(first.sessionID != nil)
        #expect(second.sessionID != nil)
        #expect(first.sessionID != second.sessionID)
    }

    @Test("all_dirty is trimmed, case insensitive, and observes real external changes")
    func allDirtyCanonicalizationUsesActorBehavior() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }

        let configured = try await fixture.observe(commandLineMode: "  ALL_Dirty\t")

        #expect(configured.mode == .allDirty)
        #expect(configured.sessionID != nil)
    }

    @Test("off and disabled aliases actually remove the session tracker")
    func disabledModesRemoveTracker() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }

        let off = try await fixture.observe(commandLineMode: "  oFf  ")
        let disabled = try await fixture.observe(
            environmentOverrides: ["GROK_HUNK_TRACKER": " DiSaBlEd "]
        )

        #expect(off.mode == .off)
        #expect(off.sessionID == nil)
        #expect(disabled.mode == .off)
        #expect(disabled.sessionID == nil)
    }

    @Test("CLI outranks environment, environment outranks trusted config, blanks skip")
    func launchPrecedenceAndBlankSkipping() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }
        try fixture.writeUserMode("all_dirty")

        let configOnly = try await fixture.observe()
        let environmentWins = try await fixture.observe(
            environmentOverrides: ["GROK_HUNK_TRACKER": "off"]
        )
        let commandLineWins = try await fixture.observe(
            commandLineMode: "all_dirty",
            environmentOverrides: ["GROK_HUNK_TRACKER": "off"]
        )
        let blankCommandLineSkips = try await fixture.observe(
            commandLineMode: " \t ",
            environmentOverrides: ["GROK_HUNK_TRACKER": "off"]
        )
        let blankEnvironmentSkips = try await fixture.observe(
            environmentOverrides: ["GROK_HUNK_TRACKER": " \t "]
        )

        #expect(configOnly.mode == .allDirty)
        #expect(environmentWins.mode == .off)
        #expect(commandLineWins.mode == .allDirty)
        #expect(blankCommandLineSkips.mode == .off)
        #expect(blankEnvironmentSkips.mode == .allDirty)
    }

    @Test("unknown selected values canonicalize to agent_only without falling through")
    func unknownHigherTierDoesNotFallThrough() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }
        try fixture.writeUserMode("off")

        let unknownCommandLine = try await fixture.observe(
            commandLineMode: "unrecognized-mode",
            environmentOverrides: ["GROK_HUNK_TRACKER": "all_dirty"]
        )
        let unknownEnvironment = try await fixture.observe(
            environmentOverrides: ["GROK_HUNK_TRACKER": "not-a-mode"]
        )

        #expect(unknownCommandLine.mode == .agentOnly)
        #expect(unknownEnvironment.mode == .agentOnly)
    }

    @Test("an untrusted project cannot suppress the owner's hunk tracking mode")
    func untrustedProjectCannotDisableTracking() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }
        try fixture.writeUserMode("all_dirty")
        try fixture.writeProjectMode("off")

        let untrusted = try await fixture.observe()
        let trusted = try await fixture.observe(trustFolder: true)

        #expect(untrusted.projectTrusted == false)
        #expect(untrusted.mode == .allDirty)
        #expect(trusted.projectTrusted)
        #expect(trusted.mode == .off)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
    }

    @Test("an untrusted project cannot broaden agent-only tracking to all dirty files")
    func untrustedProjectCannotBroadenTracking() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }
        try fixture.writeProjectMode("all_dirty")

        let untrusted = try await fixture.observe()
        let trusted = try await fixture.observe(trustFolder: true)

        #expect(untrusted.projectTrusted == false)
        #expect(untrusted.mode == .agentOnly)
        #expect(trusted.projectTrusted)
        #expect(trusted.mode == .allDirty)
    }

    @Test("successful live file tools attribute only their own session and agent")
    func successfulWritePreservesSessionBoundAttribution() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }
        let sessionID = "hunk-authorized-session"
        let executor = try await fixture.executor(sessionID: sessionID)
        let tracker = try #require(executor.mcpToolset.resources.hunkTracker)
        let target = fixture.workspace.appendingPathComponent("authorized.txt")

        let result = try await fixture.invokeWrite(
            executor: executor,
            sessionID: sessionID,
            path: target
        )
        guard case .success = result else {
            await executor.shutdown()
            Issue.record("authorized file tool did not dispatch: \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
        let hunks = await tracker.getHunksForPath(target.path)
        let sessionSnapshot = await tracker.snapshotState()
        await executor.shutdown()

        let hunk = try #require(hunks.first)
        #expect(hunk.source.isAgentEdit)
        #expect(hunk.source.sessionId == sessionID)
        #expect(hunk.source.agentId == "main")
        #expect(sessionSnapshot.sessionId == sessionID)
    }

    @Test("denied mutations and workspace escapes never write or create attributed hunks")
    func deniedAndEscapingWritesNeverAttribute() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }

        let deniedSessionID = "hunk-denied-session"
        let deniedExecutor = try await fixture.executor(
            sessionID: deniedSessionID,
            commandLineMode: "all_dirty",
            policy: .denyByDefault
        )
        let deniedTracker = try #require(deniedExecutor.mcpToolset.resources.hunkTracker)
        let deniedPath = fixture.workspace.appendingPathComponent("denied.txt")
        let denied = try await fixture.invokeWrite(
            executor: deniedExecutor,
            sessionID: deniedSessionID,
            path: deniedPath
        )
        guard case .failure = denied else {
            await deniedExecutor.shutdown()
            Issue.record("denied file tool unexpectedly dispatched")
            return
        }
        let deniedHunks = await deniedTracker.getAllHunks()
        await deniedExecutor.shutdown()
        #expect(FileManager.default.fileExists(atPath: deniedPath.path) == false)
        #expect(deniedHunks.isEmpty)

        let escapingSessionID = "hunk-escaping-session"
        let escapingExecutor = try await fixture.executor(sessionID: escapingSessionID)
        let escapingTracker = try #require(escapingExecutor.mcpToolset.resources.hunkTracker)
        let escapedPath = fixture.root.appendingPathComponent("outside-workspace.txt")
        let escaped = try await fixture.invokeWrite(
            executor: escapingExecutor,
            sessionID: escapingSessionID,
            path: escapedPath
        )
        guard case .failure = escaped else {
            await escapingExecutor.shutdown()
            Issue.record("workspace escape unexpectedly dispatched")
            return
        }
        let escapingHunks = await escapingTracker.getAllHunks()
        await escapingExecutor.shutdown()
        #expect(FileManager.default.fileExists(atPath: escapedPath.path) == false)
        #expect(escapingHunks.isEmpty)
    }

    @Test("disabled tracking changes attribution only and never bypasses permissions")
    func disabledTrackingPreservesPermissionGate() async throws {
        let fixture = try LiveHunkTrackerLaunchFixture()
        defer { fixture.dispose() }

        let allowedSessionID = "hunk-disabled-allowed"
        let allowedExecutor = try await fixture.executor(
            sessionID: allowedSessionID,
            commandLineMode: "disabled"
        )
        #expect(allowedExecutor.mcpToolset.resources.hunkTracker == nil)
        let allowedPath = fixture.workspace.appendingPathComponent("allowed-without-tracker.txt")
        let allowed = try await fixture.invokeWrite(
            executor: allowedExecutor,
            sessionID: allowedSessionID,
            path: allowedPath
        )
        await allowedExecutor.shutdown()
        guard case .success = allowed else {
            Issue.record("disabled tracking blocked an otherwise authorized write")
            return
        }
        #expect(FileManager.default.fileExists(atPath: allowedPath.path))

        let deniedSessionID = "hunk-disabled-denied"
        let deniedExecutor = try await fixture.executor(
            sessionID: deniedSessionID,
            commandLineMode: "off",
            policy: .denyByDefault
        )
        #expect(deniedExecutor.mcpToolset.resources.hunkTracker == nil)
        let deniedPath = fixture.workspace.appendingPathComponent("denied-without-tracker.txt")
        let denied = try await fixture.invokeWrite(
            executor: deniedExecutor,
            sessionID: deniedSessionID,
            path: deniedPath
        )
        await deniedExecutor.shutdown()
        guard case .failure = denied else {
            Issue.record("disabled tracking bypassed the existing write permission gate")
            return
        }
        #expect(FileManager.default.fileExists(atPath: deniedPath.path) == false)
    }
}
