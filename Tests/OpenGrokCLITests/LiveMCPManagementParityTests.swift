import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokMCP
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct MCPManagementFixture {
    let root: URL
    let home: URL
    let state: URL
    let workspace: URL
    let environment: [String: String]

    var userConfig: URL { state.appendingPathComponent("config.toml") }
    var projectConfig: URL { workspace.appendingPathComponent(".opengrok/config.toml") }

    var executable: String {
        #if os(Windows)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        return URL(fileURLWithPath: systemRoot).appendingPathComponent("System32/cmd.exe").path
        #else
        return "/usr/bin/true"
        #endif
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-mcp-management-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        state = root.appendingPathComponent("state")
        workspace = root.appendingPathComponent("workspace")
        for directory in [home, state, workspace] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func run(_ arguments: [String]) -> (code: Int32, output: String, error: String) {
        let (streams, output, error) = CLIStreams.buffered()
        let code = CLIRunner.main(
            ["--cwd", workspace.path] + arguments,
            environment: environment,
            streams: streams
        )
        return (code, output.contents, error.contents)
    }

    func trustWorkspace() throws {
        var store = PersistentFolderTrustStore(environment: environment)
        try store.record(workspace, trusted: true)
        #expect(PersistentFolderTrustStore(environment: environment).isTrusted(workspace))
    }

    func write(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    func declarations(at path: URL) throws -> MCPConfigLoadResult {
        let document = try parseTOML(String(contentsOf: path, encoding: .utf8))
        return MCPConfigLoader.load(from: document)
    }
}

@Suite("Live MCP CLI management parity and authority")
struct LiveMCPManagementParityTests {
    @Test("real CLI persists repeated stdio environment values in owner-private TOML")
    func repeatedEnvironmentRoundTripsThroughCLIRunner() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }

        let add = fixture.run([
            "mcp", "add", "files",
            "-e", "API_TOKEN=super-secret-token",
            "--env", "REGION=us=east",
            "--", fixture.executable, "--root", "/workspace",
        ])
        #expect(add.code == CLIRunner.ExitCode.success.rawValue)
        #expect(!add.output.contains("super-secret-token"))
        #expect(!add.error.contains("super-secret-token"))
        #expect(try SecureFile.isOwnerOnly(at: fixture.userConfig))

        let declaration = try #require(
            try fixture.declarations(at: fixture.userConfig).servers.first
        )
        guard case .stdio(let command, let arguments, let environment, _) =
            declaration.config.transport
        else {
            Issue.record("expected a persisted stdio transport")
            return
        }
        #expect(command == fixture.executable)
        #expect(arguments == ["--root", "/workspace"])
        #expect(environment?["API_TOKEN"] == "super-secret-token")
        #expect(environment?["REGION"] == "us=east")

        let list = fixture.run(["mcp", "list", "--json"])
        #expect(list.code == CLIRunner.ExitCode.success.rawValue)
        #expect(list.output.contains("files"))
        #expect(!list.output.contains("super-secret-token"))
    }

    @Test("HTTP positional URLs and repeated headers persist without disclosing secrets")
    func positionalHTTPAndHeadersRoundTrip() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }

        let add = fixture.run([
            "mcp", "add", "--transport", "http", "remote",
            "https://mcp.example.test/server",
            "-H", "Authorization: Bearer hidden-access-token",
            "--header", "X-Region: us-east",
        ])
        #expect(add.code == CLIRunner.ExitCode.success.rawValue)
        #expect(!add.output.contains("hidden-access-token"))
        #expect(!add.error.contains("hidden-access-token"))
        #expect(try SecureFile.isOwnerOnly(at: fixture.userConfig))

        let declaration = try #require(
            try fixture.declarations(at: fixture.userConfig).servers.first
        )
        guard case .streamableHttp(let endpoint, let type, _, let headers, _, _, _) =
            declaration.config.transport
        else {
            Issue.record("expected a persisted HTTP transport")
            return
        }
        #expect(endpoint == "https://mcp.example.test/server")
        #expect(type == nil)
        #expect(headers?["Authorization"] == "Bearer hidden-access-token")
        #expect(headers?["X-Region"] == "us-east")

        let get = fixture.run(["mcp", "get", "remote", "--json"])
        #expect(get.code == CLIRunner.ExitCode.success.rawValue)
        #expect(!get.output.contains("hidden-access-token"))
    }

    @Test("legacy --command/--args and --url/--type remain functional")
    func legacyTransportFormsRemainFunctional() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }

        let stdio = fixture.run([
            "mcp", "add", "legacy", "--command", fixture.executable,
            "--args", "first", "second",
        ])
        #expect(stdio.code == CLIRunner.ExitCode.success.rawValue)
        let first = try #require(
            try fixture.declarations(at: fixture.userConfig).servers
                .first { $0.name == "legacy" }
        )
        guard case .stdio(_, let arguments, _, _) = first.config.transport else {
            Issue.record("expected legacy stdio transport")
            return
        }
        #expect(arguments == ["first", "second"])

        let remote = fixture.run([
            "mcp", "add", "events", "--url", "https://mcp.example.test/events",
            "--type", "sse",
        ])
        #expect(remote.code == CLIRunner.ExitCode.success.rawValue)
        let second = try #require(
            try fixture.declarations(at: fixture.userConfig).servers
                .first { $0.name == "events" }
        )
        guard case .streamableHttp(_, let type, _, _, _, _, _) = second.config.transport else {
            Issue.record("expected legacy SSE transport")
            return
        }
        #expect(type == "sse")
    }

    @Test("invalid names, transport combinations, environment, and headers fail closed")
    func invalidConfigurationNeverWrites() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }

        let invalid: [[String]] = [
            ["mcp", "add", "bad.name", "--", fixture.executable],
            ["mcp", "add", "badenv", "-e", "9INVALID=secret", "--", fixture.executable],
            ["mcp", "add", "badenv", "-e", "NOT_A_PAIR", "--", fixture.executable],
            ["mcp", "add", "stdio", "-H", "Authorization: secret", "--", fixture.executable],
            ["mcp", "add", "--transport", "http", "remote", "https://safe.test", "-e", "KEY=secret"],
            ["mcp", "add", "--transport", "http", "remote", "https://safe.test", "-H", "Bad Header: secret"],
            ["mcp", "add", "--transport", "http", "remote", "https://safe.test", "-H", "X-A: one", "-H", "x-a: two"],
            ["mcp", "add", "--transport", "http", "remote", "file:///tmp/not-http"],
            ["mcp", "add", "--transport", "http", "remote", "https://owner:secret@safe.test"],
            ["mcp", "add", "wrong", "--type", "sse", "--", fixture.executable],
            ["mcp", "add", "wrong", "--args", "orphan"],
            ["mcp", "add", "wrong", "--scope", "local", "--", fixture.executable],
        ]

        for arguments in invalid {
            let result = fixture.run(arguments)
            #expect(result.code != CLIRunner.ExitCode.success.rawValue)
            #expect(!result.output.contains("9INVALID=secret"))
            #expect(!result.error.contains("9INVALID=secret"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.userConfig.path))
    }

    @Test("project writes require persisted folder trust and cannot fall back to user scope")
    func projectScopeRequiresExplicitTrust() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }

        let rejected = fixture.run([
            "mcp", "add", "--scope", "project", "repo", "--", fixture.executable,
        ])
        #expect(rejected.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(rejected.error.localizedCaseInsensitiveContains("trust"))
        #expect(!FileManager.default.fileExists(atPath: fixture.projectConfig.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.userConfig.path))

        let accepted = fixture.run([
            "--trust", "mcp", "add", "--scope", "project", "repo", "--", fixture.executable,
        ])
        #expect(accepted.code == CLIRunner.ExitCode.success.rawValue)
        #expect(FileManager.default.fileExists(atPath: fixture.projectConfig.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.userConfig.path))
        #expect(try SecureFile.isOwnerOnly(at: fixture.projectConfig))

        let list = fixture.run(["mcp", "list"])
        #expect(list.code == CLIRunner.ExitCode.success.rawValue)
        #expect(list.output.contains("repo"))
        #expect(list.output.contains("project"))
    }

    @Test("untrusted project declarations stay invisible and doctor never executes their commands")
    func untrustedProjectNeverCrossesTheManagementSeam() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("unexpected-project-execution")
        let quotedCommand = String(decoding: try JSONEncoder().encode(fixture.executable), as: UTF8.self)
        let quotedMarker = String(decoding: try JSONEncoder().encode(marker.path), as: UTF8.self)
        try fixture.write("""
        [mcp_servers.hostile]
        command = \(quotedCommand)
        args = [\(quotedMarker)]
        """, to: fixture.projectConfig)

        let list = fixture.run(["mcp", "list", "--json"])
        #expect(list.code == CLIRunner.ExitCode.success.rawValue)
        #expect(!list.output.contains("hostile"))

        let explicit = fixture.run([
            "mcp", "get", "hostile", "--config", fixture.projectConfig.path,
        ])
        #expect(explicit.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(explicit.error.localizedCaseInsensitiveContains("trust"))

        let doctor = fixture.run(["mcp", "doctor", "--json"])
        #expect(doctor.code == CLIRunner.ExitCode.success.rawValue)
        #expect(doctor.output.contains("skipped"))
        #expect(!doctor.output.contains("hostile"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("live CLI catalog resolves persisted setup preferences without exposing private headers")
    func setupPreferencesResolveAcrossIndependentCLIInvocations() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        try fixture.write("""
        [mcp_servers.configured]
        url = "{{endpoint}}"
        headers = { Authorization = "Bearer {{token}}" }

        [[mcp_servers.configured.setup.fields]]
        id = "region"
        label = "Region"
        type = "select"
        required = true
        options = [{ label = "United States", value = "us" }]

        [mcp_servers.configured.setup.variables.endpoint]
        from = "region"
        map = { us = "https://us.example.test/mcp" }

        [mcp_servers.configured.setup.variables.token]
        from = "region"
        map = { us = "setup-private-access-token" }
        """, to: fixture.userConfig)

        let unresolved = fixture.run(["mcp", "list", "--json"])
        #expect(unresolved.code == CLIRunner.ExitCode.success.rawValue)
        #expect(unresolved.output.contains("setup_required"))
        #expect(!unresolved.output.contains("setup-private-access-token"))

        try MCPSetupPreferencesStore.updateServer(
            named: "configured",
            preferences: McpServerPreferences(values: ["region": "us"]),
            home: fixture.state
        )

        let resolved = fixture.run(["mcp", "list", "--json"])
        #expect(resolved.code == CLIRunner.ExitCode.success.rawValue)
        #expect(resolved.output.contains("https://us.example.test/mcp"))
        #expect(!resolved.output.contains("setup_required"))
        #expect(!resolved.output.contains("setup-private-access-token"))
    }

    @Test("enable and disable persist real state and user-visible readback")
    func userTogglePersistsAndReadsBack() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        #expect(fixture.run([
            "mcp", "add", "toggle", "--", fixture.executable,
        ]).code == CLIRunner.ExitCode.success.rawValue)

        let disabled = fixture.run(["mcp", "disable", "toggle"])
        #expect(disabled.code == CLIRunner.ExitCode.success.rawValue)
        let disabledText = try String(contentsOf: fixture.userConfig, encoding: .utf8)
        #expect(disabledText.contains("disabled_mcp_servers"))
        #expect(disabledText.contains("enabled = false"))
        #expect(fixture.run(["mcp", "list"]).output.contains("(disabled)"))

        let enabled = fixture.run(["mcp", "enable", "toggle"])
        #expect(enabled.code == CLIRunner.ExitCode.success.rawValue)
        let enabledText = try String(contentsOf: fixture.userConfig, encoding: .utf8)
        #expect(!enabledText.contains("disabled_mcp_servers"))
        #expect(enabledText.contains("enabled = true"))
        #expect(!fixture.run(["mcp", "list"]).output.contains("(disabled)"))
        #expect(try SecureFile.isOwnerOnly(at: fixture.userConfig))
    }

    @Test("disabling a project server stays personal and never changes shared config")
    func projectDisableOnlyTouchesOwnerConfig() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        try fixture.trustWorkspace()
        #expect(fixture.run([
            "mcp", "add", "--scope", "project", "shared", "--", fixture.executable,
        ]).code == CLIRunner.ExitCode.success.rawValue)
        let original = try Data(contentsOf: fixture.projectConfig)

        let disabled = fixture.run(["mcp", "disable", "shared"])
        #expect(disabled.code == CLIRunner.ExitCode.success.rawValue)
        #expect(try Data(contentsOf: fixture.projectConfig) == original)
        #expect(fixture.run(["mcp", "list"]).output.contains("(disabled)"))

        let enabled = fixture.run(["mcp", "enable", "shared"])
        #expect(enabled.code == CLIRunner.ExitCode.success.rawValue)
        #expect(try Data(contentsOf: fixture.projectConfig) == original)
        #expect(!fixture.run(["mcp", "list"]).output.contains("(disabled)"))
    }

    @Test("enable clears a trusted project's sticky disabled field")
    func enableClearsTrustedStickyProjectState() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        try fixture.trustWorkspace()
        let quotedCommand = String(decoding: try JSONEncoder().encode(fixture.executable), as: UTF8.self)
        try fixture.write("""
        [mcp_servers.sticky]
        command = \(quotedCommand)
        enabled = false
        """, to: fixture.projectConfig)

        let result = fixture.run(["mcp", "enable", "sticky"])
        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        let persisted = try String(contentsOf: fixture.projectConfig, encoding: .utf8)
        #expect(persisted.contains("enabled = true"))
        #expect(!fixture.run(["mcp", "list"]).output.contains("(disabled)"))
    }

    @Test("remove requires an explicit scope when both config authorities define a name")
    func removalDetectsAmbiguousScope() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        try fixture.trustWorkspace()
        #expect(fixture.run([
            "mcp", "add", "same", "--", fixture.executable,
        ]).code == CLIRunner.ExitCode.success.rawValue)
        #expect(fixture.run([
            "mcp", "add", "--scope", "project", "same", "--", fixture.executable,
        ]).code == CLIRunner.ExitCode.success.rawValue)

        let ambiguous = fixture.run(["mcp", "remove", "same"])
        #expect(ambiguous.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(ambiguous.error.contains("--scope"))
        #expect(try fixture.declarations(at: fixture.userConfig).servers.count == 1)
        #expect(try fixture.declarations(at: fixture.projectConfig).servers.count == 1)

        let project = fixture.run(["mcp", "remove", "same", "--scope", "project"])
        #expect(project.code == CLIRunner.ExitCode.success.rawValue)
        #expect(project.error.contains("still defined"))
        #expect(try fixture.declarations(at: fixture.projectConfig).servers.isEmpty)
        #expect(try fixture.declarations(at: fixture.userConfig).servers.count == 1)

        let user = fixture.run(["mcp", "remove", "same", "--scope", "user"])
        #expect(user.code == CLIRunner.ExitCode.success.rawValue)
        #expect(try fixture.declarations(at: fixture.userConfig).servers.isEmpty)
    }

    @Test("corrupt existing TOML is never replaced by a successful-looking mutation")
    func corruptOwnerConfigIsPreserved() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        let original = "[mcp_servers.broken\ncommand = \\\"keep-every-byte\\\"\n"
        try fixture.write(original, to: fixture.userConfig)

        let result = fixture.run([
            "mcp", "add", "safe", "--", fixture.executable,
        ])
        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("cannot safely edit"))
        #expect(try String(contentsOf: fixture.userConfig, encoding: .utf8) == original)
    }

    @Test("managed enterprise policy blocks add and enable before changing owner state")
    func managedPolicyRemainsAuthoritative() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        let (streams, _, _) = CLIStreams.buffered()
        let policy = ManagedMCPPolicy(deniedServers: [.command(fixture.executable)])

        #expect(throws: CLIApplicationError.self) {
            try LiveMCPComposition.runAdd(
                options: CLIResourceOptions(
                    action: "add", target: "blocked", values: [fixture.executable]
                ),
                environment: fixture.environment,
                streams: streams,
                cwd: fixture.workspace,
                managedMCPPolicy: policy
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.userConfig.path))

        #expect(fixture.run([
            "mcp", "add", "allowed", "--", fixture.executable,
        ]).code == CLIRunner.ExitCode.success.rawValue)
        #expect(fixture.run(["mcp", "disable", "allowed"]).code == 0)
        let before = try Data(contentsOf: fixture.userConfig)

        #expect(throws: CLIApplicationError.self) {
            try LiveMCPComposition.runSetEnabled(
                options: CLIResourceOptions(action: "enable", target: "allowed"),
                enabled: true,
                environment: fixture.environment,
                streams: streams,
                cwd: fixture.workspace,
                managedMCPPolicy: policy
            )
        }
        #expect(try Data(contentsOf: fixture.userConfig) == before)
    }

    @Test("doctor validates executable reachability without ever spawning the server")
    func doctorChecksExecutableWithoutExecution() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("doctor-executed-server")
        #expect(fixture.run([
            "mcp", "add", "safe", "--", fixture.executable, marker.path,
        ]).code == CLIRunner.ExitCode.success.rawValue)

        let doctor = fixture.run(["mcp", "doctor", "safe", "--json"])
        #expect(doctor.code == CLIRunner.ExitCode.success.rawValue)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(doctor.output.utf8)) as? [String: Any]
        )
        #expect(object["healthy_count"] as? Int == 1)
        #expect(object["failing_count"] as? Int == 0)
        let server = try #require((object["servers"] as? [[String: Any]])?.first)
        #expect(server["name"] as? String == "safe")
        #expect(server["healthy"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("doctor reports missing commands and disabled servers with failing exit status")
    func doctorFailuresAreRealAndActionable() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        #expect(fixture.run([
            "mcp", "add", "missing", "--", "not-an-installed-mcp-executable",
        ]).code == CLIRunner.ExitCode.success.rawValue)

        let missing = fixture.run(["mcp", "doctor", "missing", "--json"])
        #expect(missing.code == CLIRunner.ExitCode.failure.rawValue)
        let report = try #require(
            try JSONSerialization.jsonObject(with: Data(missing.output.utf8)) as? [String: Any]
        )
        #expect(report["healthy_count"] as? Int == 0)
        #expect(report["failing_count"] as? Int == 1)
        #expect(missing.output.contains("not executable"))

        #expect(fixture.run(["mcp", "disable", "missing"]).code == 0)
        let disabled = fixture.run(["mcp", "doctor", "missing", "--json"])
        #expect(disabled.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(disabled.output.contains("disabled in config"))

        let unknown = fixture.run(["mcp", "doctor", "unknown"])
        #expect(unknown.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(unknown.error.contains("available servers: missing"))
    }

    @Test("HTTP doctor probes reachability while redacting URL and header credentials")
    func doctorRedactsSecretsOnHTTPFailure() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        let secret = "doctor-secret-must-never-appear"
        #expect(fixture.run([
            "mcp", "add", "--transport", "http", "offline",
            "http://127.0.0.1:1/mcp?api_key=\(secret)",
            "--header", "Authorization: Bearer \(secret)",
        ]).code == CLIRunner.ExitCode.success.rawValue)

        let result = fixture.run(["mcp", "doctor", "offline", "--json"])
        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.contains("HTTP endpoint reachable"))
        #expect(!result.output.contains(secret))
        #expect(!result.error.contains(secret))
        #expect(result.output.contains("REDACTED"))
    }

    @Test("explicit --config stays isolated across add, list, get, and remove")
    func explicitConfigNeverReadsOrWritesTheOwnerDefault() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        let explicit = fixture.root.appendingPathComponent("isolated/config.toml")

        #expect(fixture.run([
            "mcp", "add", "isolated", "--config", explicit.path, "--", fixture.executable,
        ]).code == CLIRunner.ExitCode.success.rawValue)
        #expect(FileManager.default.fileExists(atPath: explicit.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.userConfig.path))

        #expect(fixture.run(["mcp", "list", "--config", explicit.path]).output.contains("isolated"))
        #expect(!fixture.run(["mcp", "list"]).output.contains("isolated"))
        #expect(fixture.run([
            "mcp", "get", "isolated", "--config", explicit.path,
        ]).code == CLIRunner.ExitCode.success.rawValue)
        #expect(fixture.run([
            "mcp", "remove", "isolated", "--config", explicit.path,
        ]).code == CLIRunner.ExitCode.success.rawValue)
        #expect(try fixture.declarations(at: explicit).servers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.userConfig.path))
    }

    #if !os(Windows)
    @Test("a symlinked project config directory cannot escape its trusted workspace")
    func projectSymlinkEscapeIsRejected() throws {
        let fixture = try MCPManagementFixture()
        defer { fixture.dispose() }
        try fixture.trustWorkspace()
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent(".opengrok"),
            withDestinationURL: outside
        )

        let result = fixture.run([
            "mcp", "add", "--scope", "project", "escape", "--", fixture.executable,
        ])
        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("config.toml").path
        ))
    }
    #endif
}
