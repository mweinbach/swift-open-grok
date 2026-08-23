import Foundation
import OpenGrokLSP
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct LiveLspProjectTrustFixture {
    let root: URL
    let repository: URL
    let ownerHome: URL
    let openGrokHome: URL
    let environment: [String: String]

    var projectConfig: URL {
        repository.appendingPathComponent(".opengrok/lsp.json")
    }

    var userConfig: URL {
        openGrokHome.appendingPathComponent("lsp.json")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-lsp-trust-\(UUID().uuidString)")
        repository = root.appendingPathComponent("repository")
        ownerHome = root.appendingPathComponent("owner")
        openGrokHome = ownerHome.appendingPathComponent(".opengrok")
        for directory in [repository.appendingPathComponent(".opengrok"), openGrokHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "let sample = true".write(
            to: repository.appendingPathComponent("Sample.swift"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": ownerHome.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_SANDBOX": "off",
            "GROK_FOLDER_TRUST": "1",
            "GROK_LSP_TOOLS": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeServer(named name: String, marker: URL, to path: URL) throws {
        let command: String
        let arguments: [String]
        #if os(Windows)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        command = URL(fileURLWithPath: systemRoot)
            .appendingPathComponent("System32/cmd.exe").path
        arguments = ["/d", "/c", "echo started > \"\(marker.path)\""]
        #else
        command = "/usr/bin/touch"
        arguments = [marker.path]
        #endif
        let configuration = LspServerConfig(
            command: command,
            args: arguments,
            extensions: [".swift": "swift"]
        )
        try JSONEncoder().encode([name: configuration]).write(to: path)
    }

    func trustRepository() throws {
        var trust = PersistentFolderTrustStore(environment: environment)
        try trust.record(repository, trusted: true)
        #expect(PersistentFolderTrustStore(environment: environment).isTrusted(repository))
    }

    func makeExecutor(
        environment override: [String: String]? = nil,
        permissionOptions: CLIPermissionOptions = CLIPermissionOptions(),
        securityContext: LiveSecurityContext? = nil
    ) async throws -> LiveToolExecutor {
        let effectiveEnvironment = override ?? environment
        return try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: effectiveEnvironment),
            sessionID: "lsp-project-trust-\(UUID().uuidString)",
            workingDirectory: repository,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: effectiveEnvironment,
            securityContext: securityContext,
            permissionOptions: permissionOptions
        )
    }

    func pullDiagnostics(using executor: LiveToolExecutor) async {
        let result = await executor.invoke(
            sessionID: "lsp-project-trust-call",
            workingDirectory: repository,
            call: ToolCall(
                id: "lsp-project-trust-diagnostics",
                name: "pull_diagnostics",
                arguments: #"{"path":"Sample.swift"}"#
            )
        )
        if case .failure(let failure) = result {
            Issue.record("the advertised LSP tool failed to dispatch: \(failure)")
        }
    }
}

@Suite("live LSP project commands obey canonical folder trust")
struct LiveLspProjectTrustSecurityTests {
    @Test("GROK_LSP_TOOLS cannot advertise or spawn an untrusted project command")
    func hostileProjectServerNeverAdvertisesOrExecutes() async throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let hostileMarker = fixture.root.appendingPathComponent("hostile-lsp-started")
        try fixture.writeServer(named: "hostile", marker: hostileMarker, to: fixture.projectConfig)
        let security = LiveSecurityContext.resolve(
            workspaceRoot: fixture.repository,
            environment: fixture.environment,
            isInteractive: false
        )
        #expect(security.projectTrusted == false)

        let executor = try await fixture.makeExecutor()
        #expect(executor.tools.allSatisfy { $0.name != "pull_diagnostics" })
        let denied = await executor.invoke(
            sessionID: "lsp-project-trust-call",
            workingDirectory: fixture.repository,
            call: ToolCall(
                id: "hostile-lsp-call",
                name: "pull_diagnostics",
                arguments: #"{"path":"Sample.swift"}"#
            )
        )
        guard case .failure = denied else {
            await executor.shutdown()
            Issue.record("untrusted repository LSP tool unexpectedly dispatched")
            return
        }
        await executor.shutdown()

        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
    }

    @Test("persisted explicit folder trust starts the real project language-server command")
    func durableFolderTrustAllowsRealProjectServer() async throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let trustedMarker = fixture.root.appendingPathComponent("trusted-lsp-started")
        try fixture.writeServer(named: "trusted", marker: trustedMarker, to: fixture.projectConfig)
        try fixture.trustRepository()

        let executor = try await fixture.makeExecutor()
        #expect(executor.tools.contains { $0.name == "pull_diagnostics" })
        await fixture.pullDiagnostics(using: executor)
        await executor.shutdown()

        #expect(FileManager.default.fileExists(atPath: trustedMarker.path))
    }

    @Test("a real owner server survives an untrusted same-name project override")
    func ownerLanguageServerStillRunsInUntrustedRepository() async throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let ownerMarker = fixture.root.appendingPathComponent("owner-lsp-started")
        let hostileMarker = fixture.root.appendingPathComponent("hostile-lsp-started")
        try fixture.writeServer(named: "swift", marker: ownerMarker, to: fixture.userConfig)
        try fixture.writeServer(named: "swift", marker: hostileMarker, to: fixture.projectConfig)

        let executor = try await fixture.makeExecutor()
        #expect(executor.tools.contains { $0.name == "pull_diagnostics" })
        await fixture.pullDiagnostics(using: executor)
        await executor.shutdown()

        #expect(FileManager.default.fileExists(atPath: ownerMarker.path))
        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
    }

    @Test("an explicit trust command-line decision authorizes the project server")
    func explicitTrustFlagAllowsProjectLanguageServer() async throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let trustedMarker = fixture.root.appendingPathComponent("cli-trusted-lsp-started")
        try fixture.writeServer(named: "trusted", marker: trustedMarker, to: fixture.projectConfig)

        let executor = try await fixture.makeExecutor(
            permissionOptions: CLIPermissionOptions(trustFolder: true)
        )
        #expect(executor.tools.contains { $0.name == "pull_diagnostics" })
        await fixture.pullDiagnostics(using: executor)
        await executor.shutdown()

        #expect(FileManager.default.fileExists(atPath: trustedMarker.path))
    }

    @Test("an authoritative untrusted session verdict cannot be widened by --trust")
    func suppliedSecurityContextCannotBeBypassed() async throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let hostileMarker = fixture.root.appendingPathComponent("authoritative-policy-bypassed")
        try fixture.writeServer(named: "hostile", marker: hostileMarker, to: fixture.projectConfig)
        let authoritative = LiveSecurityContext.resolve(
            workspaceRoot: fixture.repository,
            environment: fixture.environment,
            isInteractive: false
        )
        #expect(authoritative.projectTrusted == false)

        let executor = try await fixture.makeExecutor(
            permissionOptions: CLIPermissionOptions(trustFolder: true),
            securityContext: authoritative
        )
        #expect(executor.tools.allSatisfy { $0.name != "pull_diagnostics" })
        await executor.shutdown()

        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
    }

    @Test("owner-disabled folder trust retains upstream project-server behavior")
    func disabledFolderTrustFeatureAllowsProjectLanguageServer() async throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let trustedMarker = fixture.root.appendingPathComponent("feature-disabled-lsp-started")
        try fixture.writeServer(named: "trusted", marker: trustedMarker, to: fixture.projectConfig)
        var environment = fixture.environment
        environment["GROK_FOLDER_TRUST"] = "0"

        let executor = try await fixture.makeExecutor(environment: environment)
        #expect(executor.tools.contains { $0.name == "pull_diagnostics" })
        await fixture.pullDiagnostics(using: executor)
        await executor.shutdown()

        #expect(FileManager.default.fileExists(atPath: trustedMarker.path))
    }

    @Test("direct live composition denies project servers unless trust is explicit")
    func directCompositionRemainsFailClosed() throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let hostileMarker = fixture.root.appendingPathComponent("direct-composition-bypassed")
        try fixture.writeServer(named: "hostile", marker: hostileMarker, to: fixture.projectConfig)

        let denied = LiveLspComposition.loadServers(
            workingDirectory: fixture.repository,
            environment: fixture.environment
        )
        let allowed = LiveLspComposition.loadServers(
            workingDirectory: fixture.repository,
            environment: fixture.environment,
            projectTrusted: true
        )

        #expect(denied.isEmpty)
        #expect(allowed.keys.sorted() == ["hostile"])
        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
    }

    #if !os(Windows)
    @Test("even a trusted repo cannot spawn from an escaping lsp.json symlink")
    func projectSymlinkEscapeNeverSpawnsOutsideCommand() async throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let hostileMarker = fixture.root.appendingPathComponent("escaped-lsp-started")
        let outside = fixture.root.appendingPathComponent("outside-lsp.json")
        try fixture.writeServer(named: "hostile", marker: hostileMarker, to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.projectConfig, withDestinationURL: outside)
        try fixture.trustRepository()

        let executor = try await fixture.makeExecutor()
        #expect(executor.tools.allSatisfy { $0.name != "pull_diagnostics" })
        await executor.shutdown()

        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
    }

    @Test("a user-config symlink into an untrusted checkout cannot bypass project trust")
    func ownerConfigAliasCannotSpawnRepositoryLanguageServer() async throws {
        let fixture = try LiveLspProjectTrustFixture()
        defer { fixture.dispose() }
        let hostileMarker = fixture.root.appendingPathComponent("aliased-lsp-started")
        try fixture.writeServer(named: "hostile", marker: hostileMarker, to: fixture.projectConfig)
        try FileManager.default.createSymbolicLink(
            at: fixture.userConfig,
            withDestinationURL: fixture.projectConfig
        )

        let executor = try await fixture.makeExecutor()
        #expect(executor.tools.allSatisfy { $0.name != "pull_diagnostics" })
        await executor.shutdown()

        #expect(FileManager.default.fileExists(atPath: hostileMarker.path) == false)
    }
    #endif
}
