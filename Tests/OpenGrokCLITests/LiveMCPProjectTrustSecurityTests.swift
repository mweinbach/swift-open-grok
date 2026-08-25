import Foundation
@testable import OpenGrokCLI
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing

private final class ProjectTrustHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []

    var requestedURLs: [String] {
        lock.withLock { urls }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { urls.append(request.url.absoluteString) }
        let message = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
        guard let id = message["id"] else {
            return HTTPResponse(metadata: HTTPResponseMetadata(statusCode: 202), body: Data())
        }
        let response: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string(request.url.host ?? "trusted"),
                    "version": .string("1.0.0"),
                ]),
            ]),
        ])
        return HTTPResponse(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "application/json"]
            ),
            body: try JSONEncoder().encode(response)
        )
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await send(request)
                    continuation.yield(.metadata(response.metadata))
                    if !response.body.isEmpty {
                        continuation.yield(.body(response.body))
                    }
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct MCPProjectTrustFixture {
    let root: URL
    let home: URL
    let state: URL
    let workspace: URL

    var environment: [String: String] {
        [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "1",
        ]
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mcp-project-trust-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        state = root.appendingPathComponent("state")
        workspace = root.appendingPathComponent("workspace")
        for directory in [home, state, workspace.appendingPathComponent(".opengrok")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeProject(_ document: String) throws {
        try document.write(
            to: workspace.appendingPathComponent(".opengrok/config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeUser(_ document: String) throws {
        try document.write(
            to: state.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeManaged(_ document: String) throws {
        try document.write(
            to: state.appendingPathComponent("managed_config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func trustWorkspace() throws {
        var store = PersistentFolderTrustStore(environment: environment)
        try store.record(workspace, trusted: true)
    }

    func processServer(named name: String, marker: URL, enabled: Bool = true) throws -> String {
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

        let encodedCommand = try quoted(command)
        let encodedArguments = try arguments.map(quoted).joined(separator: ", ")
        return """
        [mcp_servers.\(name)]
        command = \(encodedCommand)
        args = [\(encodedArguments)]
        enabled = \(enabled)
        """
    }

    func httpServer(named name: String, host: String) -> String {
        """
        [mcp_servers.\(name)]
        url = "https://\(host).example.test/mcp"
        [mcp_servers.\(name).headers]
        Authorization = "Bearer trust-test"
        """
    }

    private func quoted(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

@Suite("Hub MCP folder trust and pre-spawn security")
struct LiveMCPProjectTrustSecurityTests {
    @Test("An untrusted project MCP command is never spawned by the real hub connector")
    func untrustedProjectCommandNeverStarts() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("project-process-started")
        try fixture.writeProject(try fixture.processServer(named: "project", marker: marker))
        let connections = MCPSessionConnections()

        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workspace.path,
            environment: fixture.environment,
            connections: connections
        )

        #expect(entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await connections.names().isEmpty)
        await connections.shutdown()
    }

    @Test("Persisted folder trust explicitly authorizes a project MCP command")
    func trustedProjectCommandStarts() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("trusted-process-started")
        try fixture.writeProject(try fixture.processServer(named: "project", marker: marker))
        try fixture.trustWorkspace()
        let connections = MCPSessionConnections()

        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workspace.path,
            environment: fixture.environment,
            connections: connections
        )

        #expect(entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        await connections.shutdown()
    }

    @Test("Untrusted collisions and disabled lists cannot override a real user MCP client")
    func untrustedProjectCannotReplaceOrDisableUserClient() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("collision-process-started")
        try fixture.writeUser(fixture.httpServer(named: "shared", host: "user"))
        try fixture.writeProject("""
        disabled_mcp_servers = ["shared"]
        \(try fixture.processServer(named: "shared", marker: marker))
        """)
        let transport = ProjectTrustHTTPTransport()
        let connections = MCPSessionConnections()

        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workspace.path,
            environment: fixture.environment,
            connections: connections,
            makeHTTPTransport: { transport }
        )

        #expect(entries.map(\.serverName) == ["shared"])
        #expect(transport.requestedURLs == [
            "https://user.example.test/mcp",
            "https://user.example.test/mcp",
        ])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await connections.names() == ["shared"])
        await connections.shutdown()
    }

    @Test("Trusted project declarations retain their normal override precedence")
    func trustedProjectOverridesUserClient() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        try fixture.writeUser(fixture.httpServer(named: "shared", host: "user"))
        try fixture.writeProject(fixture.httpServer(named: "shared", host: "project"))
        try fixture.trustWorkspace()
        let transport = ProjectTrustHTTPTransport()
        let connections = MCPSessionConnections()

        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workspace.path,
            environment: fixture.environment,
            connections: connections,
            makeHTTPTransport: { transport }
        )

        #expect(entries.map(\.serverName) == ["shared"])
        #expect(transport.requestedURLs.allSatisfy {
            $0 == "https://project.example.test/mcp"
        })
        #expect(transport.requestedURLs.count == 2)
        await connections.shutdown()
    }

    @Test("Managed MCP clients remain live when project commands are untrusted")
    func managedClientsSurviveProjectTrustGate() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("untrusted-managed-neighbor")
        try fixture.writeManaged(fixture.httpServer(named: "managed", host: "managed"))
        try fixture.writeProject(try fixture.processServer(named: "project", marker: marker))
        let transport = ProjectTrustHTTPTransport()
        let connections = MCPSessionConnections()

        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workspace.path,
            environment: fixture.environment,
            connections: connections,
            makeHTTPTransport: { transport }
        )

        #expect(entries.map(\.serverName) == ["managed"])
        #expect(transport.requestedURLs.count == 2)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        await connections.shutdown()
    }

    @Test("Disabled global declarations never start either stdio command")
    func disabledDeclarationsRemainFailClosed() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        let explicitlyDisabled = fixture.root.appendingPathComponent("disabled-list-started")
        let flagDisabled = fixture.root.appendingPathComponent("disabled-flag-started")
        try fixture.writeUser("""
        disabled_mcp_servers = ["preference"]
        \(try fixture.processServer(named: "preference", marker: explicitlyDisabled))
        \(try fixture.processServer(named: "flag", marker: flagDisabled, enabled: false))
        """)
        let connections = MCPSessionConnections()

        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workspace.path,
            environment: fixture.environment,
            connections: connections
        )

        #expect(entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: explicitlyDisabled.path))
        #expect(!FileManager.default.fileExists(atPath: flagDisabled.path))
        await connections.shutdown()
    }

    @Test("Unreadable authority configuration cannot authorize a trusted project command")
    func malformedAuthorityFailsClosed() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("malformed-authority-started")
        try fixture.writeProject(try fixture.processServer(named: "project", marker: marker))
        try fixture.trustWorkspace()
        try fixture.writeUser("[invalid\n")
        let connections = MCPSessionConnections()

        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workspace.path,
            environment: fixture.environment,
            connections: connections
        )

        #expect(entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        await connections.shutdown()
    }

    @Test("Managed command denial blocks a trusted project before the hub spawns it")
    func managedDenialBlocksTrustedHubCommand() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("managed-hub-denial-started")
        let document = try fixture.processServer(named: "blocked", marker: marker)
        try fixture.writeProject(document)
        try fixture.trustWorkspace()
        let declaration = try #require(MCPConfigLoader.load(from: try parseTOML(document)).servers.first)
        let identity = ManagedMCPServerIdentity(
            name: declaration.name,
            transport: declaration.config.transport
        )
        guard case .stdio(let command) = identity.transport else {
            Issue.record("fixture must represent a real stdio command")
            return
        }
        let policy = ManagedMCPPolicy(
            allowedServers: [.command(command)],
            deniedServers: [.command(command)]
        )
        let connections = MCPSessionConnections()

        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: fixture.workspace.path,
            environment: fixture.environment,
            connections: connections,
            managedMCPPolicy: policy
        )

        #expect(entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await connections.names().isEmpty)
        await connections.shutdown()
    }

    @Test("Managed command denial blocks normal session MCP before process spawn")
    func managedDenialBlocksSessionCommand() async throws {
        let fixture = try MCPProjectTrustFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("managed-session-denial-started")
        let document = try parseTOML(try fixture.processServer(named: "blocked", marker: marker))
        let declaration = try #require(MCPConfigLoader.load(from: document).servers.first)
        let identity = ManagedMCPServerIdentity(
            name: declaration.name,
            transport: declaration.config.transport
        )
        guard case .stdio(let command) = identity.transport else {
            Issue.record("fixture must represent a real stdio command")
            return
        }
        let policy = ManagedMCPPolicy(deniedServers: [.command(command)])
        let toolset = FinalizedToolset(
            tools: [],
            resources: ToolResources(cwd: fixture.workspace.path),
            codeModeNamespaces: [:],
            options: .unrestricted
        )
        let connections = MCPSessionConnections()

        let outcomes = await LiveMCPComposition.connectConfiguredServers(
            document: document,
            toolset: toolset,
            connections: connections,
            environment: fixture.environment,
            managedMCPPolicy: policy
        )

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.name == "blocked")
        #expect(outcomes.first?.failure?.contains("deniedMcpServers") == true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(toolset.clientNames.isEmpty)
        #expect(await connections.names().isEmpty)
        await connections.shutdown()
    }
}
