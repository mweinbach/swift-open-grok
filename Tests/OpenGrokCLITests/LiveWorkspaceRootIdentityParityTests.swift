import Foundation
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

private struct LiveWorkspaceRootIdentityFixture: Sendable {
    let root: URL
    let workspace: URL
    let unrelated: URL
    let environment: [String: String]

    init() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-workspace-root-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        root = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        let ownerHome = root.appendingPathComponent("owner", isDirectory: true)
        let openGrokHome = ownerHome.appendingPathComponent(".opengrok", isDirectory: true)
        for directory in [workspace, unrelated, ownerHome, openGrokHome] {
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

    func executor(directory: URL, sessionID: String) async throws -> LiveToolExecutor {
        try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            sessionID: sessionID,
            workingDirectory: directory,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment,
            permissionOptions: CLIPermissionOptions(allowRules: ["Bash"])
        )
    }

    func invokeShell(
        executor: LiveToolExecutor,
        sessionID: String,
        directory: URL,
        marker: URL
    ) async -> Bool {
        let command: String
        #if os(Windows)
        command = "echo authorized > \"\(marker.path)\""
        #else
        command = "/usr/bin/touch '\(marker.path)'"
        #endif
        guard let encoded = try? JSONSerialization.data(withJSONObject: ["command": command]) else {
            return false
        }
        let result = await executor.invoke(
            sessionID: sessionID,
            workingDirectory: directory,
            call: ToolCall(
                id: UUID().uuidString,
                name: "run_terminal_cmd",
                arguments: String(decoding: encoded, as: UTF8.self)
            )
        )
        if case .success = result { return true }
        return false
    }

    func isAuthorized(
        executor: LiveToolExecutor,
        sessionID: String,
        directory: URL,
        requiresRegisteredSession: Bool = false
    ) async -> Bool {
        do {
            try await executor.validateWorkspaceAuthority(
                sessionID: sessionID,
                workingDirectory: directory,
                requiresRegisteredSession: requiresRegisteredSession
            )
            return true
        } catch {
            return false
        }
    }
}

@Suite("live workspace authority uses canonical filesystem identity")
struct LiveWorkspaceRootIdentityParityTests {
    @Test("directory and file URL metadata resolve to the same exact workspace")
    func directoryMetadataCannotChangeFilesystemRootIdentity() throws {
        let fixture = try LiveWorkspaceRootIdentityFixture()
        defer { fixture.dispose() }
        let directoryURL = URL(fileURLWithPath: fixture.workspace.path, isDirectory: true)
        let fileMetadataURL = URL(fileURLWithPath: fixture.workspace.path, isDirectory: false)
        let metadataDiffers = directoryURL.hasDirectoryPath != fileMetadataURL.hasDirectoryPath
        let aliasesMatch = LiveToolExecutor.workspaceRootsMatch(directoryURL, fileMetadataURL)
        let reverseAliasesMatch = LiveToolExecutor.workspaceRootsMatch(fileMetadataURL, directoryURL)

        #expect(metadataDiffers)
        #expect(aliasesMatch)
        #expect(reverseAliasesMatch)
    }

    @Test("an actual executor accepts directory metadata aliases and dispatches its shell")
    func realExecutorRunsWhenItsRegistriesDisagreeOnDirectoryMetadata() async throws {
        let fixture = try LiveWorkspaceRootIdentityFixture()
        defer { fixture.dispose() }
        let fileMetadataURL = URL(fileURLWithPath: fixture.workspace.path, isDirectory: false)
        let directoryURL = URL(fileURLWithPath: fixture.workspace.path, isDirectory: true)
        let sessionID = "workspace-root-metadata"
        let executor = try await fixture.executor(directory: fileMetadataURL, sessionID: sessionID)
        let aliasIsAuthorized = await fixture.isAuthorized(
            executor: executor,
            sessionID: sessionID,
            directory: directoryURL
        )
        let marker = fixture.workspace.appendingPathComponent("authorized-shell-ran")
        let dispatched = await fixture.invokeShell(
            executor: executor,
            sessionID: sessionID,
            directory: fileMetadataURL,
            marker: marker
        )
        let markerExists = FileManager.default.fileExists(atPath: marker.path)

        #expect(aliasIsAuthorized)
        #expect(dispatched)
        #expect(markerExists)
        await executor.shutdown()
    }

    @Test("a registered sibling session accepts the same canonical directory alias")
    func registeredSessionRetainsExactlyTheOriginalFilesystemAuthority() async throws {
        let fixture = try LiveWorkspaceRootIdentityFixture()
        defer { fixture.dispose() }
        let fileMetadataURL = URL(fileURLWithPath: fixture.workspace.path, isDirectory: false)
        let directoryURL = URL(fileURLWithPath: fixture.workspace.path, isDirectory: true)
        let executor = try await fixture.executor(directory: fileMetadataURL, sessionID: "root-owner")
        try await executor.registerSession(sessionID: "root-alias", workingDirectory: directoryURL)
        let aliasIsRegistered = await fixture.isAuthorized(
            executor: executor,
            sessionID: "root-alias",
            directory: directoryURL,
            requiresRegisteredSession: true
        )
        let marker = fixture.workspace.appendingPathComponent("registered-alias-shell-ran")
        let dispatched = await fixture.invokeShell(
            executor: executor,
            sessionID: "root-alias",
            directory: directoryURL,
            marker: marker
        )
        let markerExists = FileManager.default.fileExists(atPath: marker.path)

        #expect(aliasIsRegistered)
        #expect(dispatched)
        #expect(markerExists)
        await executor.shutdown()
    }

    @Test("unrelated, ancestor, and nested directories never inherit workspace authority")
    func pathIdentityNeverBroadensToOtherDirectories() async throws {
        let fixture = try LiveWorkspaceRootIdentityFixture()
        defer { fixture.dispose() }
        let nested = fixture.workspace.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let sessionID = "exact-workspace-root"
        let executor = try await fixture.executor(directory: fixture.workspace, sessionID: sessionID)

        for candidate in [fixture.unrelated, fixture.root, nested] {
            let matchesWorkspace = LiveToolExecutor.workspaceRootsMatch(candidate, fixture.workspace)
            let candidateIsAuthorized = await fixture.isAuthorized(
                executor: executor,
                sessionID: sessionID,
                directory: candidate
            )
            #expect(matchesWorkspace == false)
            #expect(candidateIsAuthorized == false)
        }

        let marker = fixture.unrelated.appendingPathComponent("unauthorized-shell-ran")
        let dispatched = await fixture.invokeShell(
            executor: executor,
            sessionID: sessionID,
            directory: fixture.unrelated,
            marker: marker
        )
        let markerExists = FileManager.default.fileExists(atPath: marker.path)
        #expect(dispatched == false)
        #expect(markerExists == false)
        await executor.shutdown()
    }

    #if !os(Windows)
    @Test("an alias into the workspace is accepted while an escaping symlink is denied")
    func symlinkNormalizationNeverAuthorizesAnEscapingWorkspace() async throws {
        let fixture = try LiveWorkspaceRootIdentityFixture()
        defer { fixture.dispose() }
        let sessionID = "symlink-workspace-root"
        let executor = try await fixture.executor(directory: fixture.workspace, sessionID: sessionID)
        let legitimateAlias = fixture.root.appendingPathComponent("workspace-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: legitimateAlias, withDestinationURL: fixture.workspace)
        let escapingAlias = fixture.workspace.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapingAlias, withDestinationURL: fixture.unrelated)

        let legitimateMatches = LiveToolExecutor.workspaceRootsMatch(legitimateAlias, fixture.workspace)
        let legitimateIsAuthorized = await fixture.isAuthorized(
            executor: executor,
            sessionID: sessionID,
            directory: legitimateAlias
        )
        let escapeMatches = LiveToolExecutor.workspaceRootsMatch(escapingAlias, fixture.workspace)
        let escapeIsAuthorized = await fixture.isAuthorized(
            executor: executor,
            sessionID: sessionID,
            directory: escapingAlias
        )
        #expect(legitimateMatches)
        #expect(legitimateIsAuthorized)
        #expect(escapeMatches == false)
        #expect(escapeIsAuthorized == false)

        let marker = fixture.unrelated.appendingPathComponent("escaping-shell-ran")
        let dispatched = await fixture.invokeShell(
            executor: executor,
            sessionID: sessionID,
            directory: escapingAlias,
            marker: marker
        )
        let markerExists = FileManager.default.fileExists(atPath: marker.path)
        #expect(dispatched == false)
        #expect(markerExists == false)
        await executor.shutdown()
    }
    #endif
}
