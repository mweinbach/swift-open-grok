// MCPEndToEndTests.swift
//
// End-to-end proof that an MCP server's tools are reachable from a live
// session: a real `MCPServer` actor answers over `MCPInMemoryTransport`, a real
// `MCPClient` actor talks to it, the production `MCPClientToolProvider` adapts
// it, and `MCPToolBridge` publishes the result into a `FinalizedToolset` whose
// calls go through the real permission pipeline.
//
// Nothing here is stubbed except the server's own business logic.

import Foundation
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

// MARK: - In-process server

/// A small but real MCP server: three tools, one of which blocks until
/// cancelled so the cancel path can be exercised.
private actor EndToEndHandler: MCPServerHandler {
    private(set) var callCount = 0
    private(set) var lastArguments: JSONValue?

    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        _ = params
        return MCPListToolsResult(tools: [
            MCPTool(
                name: "echo",
                description: "Echo the supplied text.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["text": .object(["type": .string("string")])]),
                    "required": .array([.string("text")]),
                ])
            ),
            MCPTool(
                name: "boom",
                description: "Always reports an error."
            ),
            MCPTool(
                name: "forever",
                description: "Never returns until cancelled."
            ),
            MCPTool(
                name: "hidden",
                description: "Not for the model.",
                meta: .object(["ui": .object(["visibility": .array([.string("ui")])])])
            ),
        ])
    }

    func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult {
        callCount += 1
        lastArguments = params.arguments

        switch params.name {
        case "echo":
            var text = ""
            if case .object(let object)? = params.arguments,
               case .string(let value)? = object["text"] {
                text = value
            }
            return MCPCallToolResult(content: [.text(text: "echo: \(text)")])
        case "boom":
            return MCPCallToolResult(
                content: [.text(text: "the server refused")],
                isError: true
            )
        case "forever":
            // Cooperatively cancellable: the server actor cancels the in-flight
            // task when it receives notifications/cancelled.
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        default:
            throw MCPError.invalidParams("unknown tool \(params.name)")
        }
    }

    func counters() -> (calls: Int, lastArguments: JSONValue?) {
        (callCount, lastArguments)
    }
}

private func makeConnectedClient(
    handler: EndToEndHandler
) async throws -> MCPClient {
    let server = MCPServer(
        configuration: MCPServerConfiguration(
            serverInfo: MCPImplementation(name: "e2e", version: "1.0.0"),
            capabilities: MCPCapabilities(tools: MCPToolsCapability())
        ),
        handler: handler
    )
    let client = MCPClient(transport: MCPInMemoryTransport(server: server))
    _ = try await client.initialize()
    return client
}

private func makeToolset(pipeline: PermissionPipeline) -> FinalizedToolset {
    FinalizedToolset(
        tools: [],
        resources: ToolResources(
            cwd: NSTemporaryDirectory(),
            permissionPipeline: pipeline
        ),
        codeModeNamespaces: [:],
        options: .unrestricted
    )
}

private func allowAllPipeline(hooks: (any PreToolUseHookRunner)? = nil) -> PermissionPipeline {
    PermissionPipeline(
        permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory()),
        hooks: FailOpenPreToolUseHookRunner(inner: hooks)
    )
}

// MARK: - Tests

@Suite("MCP end to end through the tool registry")
struct MCPEndToEndTests {
    @Test("tools/list reaches the registry under qualified names")
    func listsThroughTheRegistry() async throws {
        let handler = EndToEndHandler()
        let client = try await makeConnectedClient(handler: handler)
        defer { Task { await client.close() } }

        let toolset = makeToolset(pipeline: allowAllPipeline())
        let registration = await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: "demo", client: client),
            into: toolset
        )

        #expect(registration.failure == nil)
        // Registration preserves the order the server advertised its tools in.
        #expect(registration.registeredNames == ["demo__echo", "demo__boom", "demo__forever"])
        // The toolset itself keeps a stable sorted order for the model.
        #expect(toolset.clientNames == ["demo__boom", "demo__echo", "demo__forever"])
        // The server marked `hidden` as UI-only, so the model never sees it.
        #expect(registration.skipped["hidden"] != nil)
        #expect(toolset.tool(named: "demo__hidden") == nil)

        let definition = try #require(
            toolset.topLevelDefinitions().first { $0.name == "demo__echo" }
        )
        #expect(definition.description == "Echo the supplied text.")
        #expect(definition.argumentsSchema != nil)
    }

    @Test("tools/call round-trips through the registry to the server and back")
    func callsThroughTheRegistry() async throws {
        let handler = EndToEndHandler()
        let client = try await makeConnectedClient(handler: handler)
        defer { Task { await client.close() } }

        let toolset = makeToolset(pipeline: allowAllPipeline())
        await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: "demo", client: client),
            into: toolset
        )

        let outcome = await toolset.prepareAndCall(
            clientName: "demo__echo",
            args: .object(["text": .string("hello")])
        )
        guard case .success(let typed) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(typed.modelOutput == [.text(text: "echo: hello")])

        let counters = await handler.counters()
        #expect(counters.calls == 1)
        // The server received the raw arguments, with the qualified prefix
        // stripped from the tool name.
        #expect(counters.lastArguments == .object(["text": .string("hello")]))
    }

    @Test("a server-side tool error surfaces as a tool failure")
    func serverErrorSurfaces() async throws {
        let handler = EndToEndHandler()
        let client = try await makeConnectedClient(handler: handler)
        defer { Task { await client.close() } }

        let toolset = makeToolset(pipeline: allowAllPipeline())
        await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: "demo", client: client),
            into: toolset
        )

        let outcome = await toolset.prepareAndCall(
            clientName: "demo__boom",
            args: .object([:])
        )
        guard case .failure(let error) = outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.detail == "the server refused")
        // The rest of the toolset is unaffected.
        #expect(toolset.clientNames.count == 3)
    }

    @Test("cancelling an in-flight call unblocks the caller and the server")
    func cancelsAnInFlightCall() async throws {
        let handler = EndToEndHandler()
        let client = try await makeConnectedClient(handler: handler)
        defer { Task { await client.close() } }

        let toolset = makeToolset(pipeline: allowAllPipeline())
        await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: "demo", client: client),
            into: toolset
        )

        let call = Task {
            await toolset.prepareAndCall(clientName: "demo__forever", args: .object([:]))
        }
        // Give the request time to reach the server's in-flight table.
        try await Task.sleep(nanoseconds: 150_000_000)
        call.cancel()

        let outcome = await call.value
        guard case .failure(let error) = outcome else {
            Issue.record("expected the cancelled call to fail rather than hang")
            return
        }
        #expect(error.detail.contains("demo__forever"))

        // The connection survives the cancellation: the next call still works.
        let after = await toolset.prepareAndCall(
            clientName: "demo__echo",
            args: .object(["text": .string("still here")])
        )
        guard case .success(let typed) = after else {
            Issue.record("expected the client to survive cancellation, got \(after)")
            return
        }
        #expect(typed.modelOutput == [.text(text: "echo: still here")])
    }

    @Test("a closed server degrades its own tools and no others")
    func closedServerIsContained() async throws {
        let healthyHandler = EndToEndHandler()
        let healthy = try await makeConnectedClient(handler: healthyHandler)
        defer { Task { await healthy.close() } }

        let doomedHandler = EndToEndHandler()
        let doomed = try await makeConnectedClient(handler: doomedHandler)

        let toolset = makeToolset(pipeline: allowAllPipeline())
        await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: "healthy", client: healthy),
            into: toolset
        )
        await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: "doomed", client: doomed),
            into: toolset
        )

        await doomed.close()

        let failed = await toolset.prepareAndCall(
            clientName: "doomed__echo",
            args: .object(["text": .string("x")])
        )
        guard case .failure = failed else {
            Issue.record("expected the closed server's tool to fail")
            return
        }

        let ok = await toolset.prepareAndCall(
            clientName: "healthy__echo",
            args: .object(["text": .string("fine")])
        )
        guard case .success(let typed) = ok else {
            Issue.record("expected the healthy server to keep working, got \(ok)")
            return
        }
        #expect(typed.modelOutput == [.text(text: "echo: fine")])
    }

    @Test("a PreToolUse hook deny stops the call before it reaches the server")
    func hookDenyStopsTheCall() async throws {
        let handler = EndToEndHandler()
        let client = try await makeConnectedClient(handler: handler)
        defer { Task { await client.close() } }

        let toolset = makeToolset(pipeline: allowAllPipeline(hooks: DenyingHookRunner()))
        await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: "demo", client: client),
            into: toolset
        )

        let outcome = await toolset.prepareAndCall(
            clientName: "demo__echo",
            args: .object(["text": .string("hello")])
        )
        guard case .failure = outcome else {
            Issue.record("expected the hook deny to block the call")
            return
        }
        let counters = await handler.counters()
        #expect(counters.calls == 0)
    }

    @Test("connectConfiguredServers tolerates a server that cannot start")
    func connectToleratesBrokenServers() async throws {
        let document = try parseTOML("""
        [mcpServers.missing]
        command = "/definitely/not/here/mcp-server"

        [mcpServers.malformed]
        url = "not a url"

        [mcpServers.disabled]
        command = "/bin/true"
        enabled = false
        """)

        let toolset = makeToolset(pipeline: allowAllPipeline())
        let connections = MCPSessionConnections()

        let results = await LiveMCPComposition.connectConfiguredServers(
            document: document,
            toolset: toolset,
            connections: connections,
            environment: [:]
        )

        // The disabled server is not dialed; the other two fail without
        // throwing and without registering anything.
        #expect(results.allSatisfy { !$0.isConnected })
        #expect(Set(results.map(\.name)) == ["missing", "malformed"])
        #expect(toolset.clientNames.isEmpty)
        #expect(await connections.names().isEmpty)
    }
}

private struct DenyingHookRunner: PreToolUseHookRunner {
    func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision {
        .deny(reason: "no outbound MCP", hookName: "test-gate")
    }
}

// MARK: - CLI route

@Suite("mcp CLI route")
struct MCPCLIRouteTests {
    private func home(_ config: String) throws -> (root: URL, environment: [String: String]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try config.write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        return (root, ["OPENGROK_HOME": root.path, "HOME": root.path])
    }

    @Test("mcp list renders configured servers")
    func listsServers() throws {
        let (root, environment) = try home("""
        [mcpServers.files]
        command = "mcp-files"
        args = ["--root", "/tmp"]

        [mcpServers.off]
        command = "other"
        enabled = false
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let (streams, out, err) = CLIStreams.buffered()
        try LiveMCPComposition.run(
            options: CLIResourceOptions(action: "list"),
            environment: environment,
            streams: streams
        )

        #expect(out.contents.contains("files: mcp-files --root /tmp"))
        #expect(out.contents.contains("off: other (disabled)"))
        #expect(err.contents.isEmpty)
    }

    @Test("mcp list --json emits servers and problems")
    func listsAsJSON() throws {
        let (root, environment) = try home("""
        [mcpServers.files]
        command = "mcp-files"

        [mcpServers.broken]
        enabled = true
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let (streams, out, _) = CLIStreams.buffered()
        try LiveMCPComposition.run(
            options: CLIResourceOptions(action: "list", json: true),
            environment: environment,
            streams: streams
        )

        let data = Data(out.contents.utf8)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let servers = try #require(object["servers"] as? [[String: Any]])
        #expect(servers.map { $0["name"] as? String } == ["files"])
        #expect(servers.first?["type"] as? String == "stdio")

        let problems = try #require(object["problems"] as? [[String: Any]])
        #expect(problems.first?["server"] as? String == "broken")
    }

    @Test("mcp list on an empty config says so")
    func listsNothing() throws {
        let (root, environment) = try home("[other]\nkey = 1\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let (streams, out, _) = CLIStreams.buffered()
        try LiveMCPComposition.run(
            options: CLIResourceOptions(action: "list"),
            environment: environment,
            streams: streams
        )
        #expect(out.contents.contains("No MCP servers configured."))
    }

    @Test("mcp get prints one server")
    func getsOneServer() throws {
        let (root, environment) = try home("""
        [mcpServers.remote]
        url = "https://example.test/mcp"
        type = "sse"
        tool_timeout_sec = 30
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let (streams, out, _) = CLIStreams.buffered()
        try LiveMCPComposition.run(
            options: CLIResourceOptions(action: "get", target: "remote"),
            environment: environment,
            streams: streams
        )
        #expect(out.contents.contains("remote"))
        #expect(out.contents.contains("sse https://example.test/mcp"))
        #expect(out.contents.contains("tool_timeout_sec: 30"))
    }

    @Test("mcp get names the servers that do exist when one does not")
    func getUnknownServer() throws {
        let (root, environment) = try home("""
        [mcpServers.files]
        command = "mcp-files"
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let (streams, _, _) = CLIStreams.buffered()
        #expect(throws: CLIApplicationError.self) {
            try LiveMCPComposition.run(
                options: CLIResourceOptions(action: "get", target: "nope"),
                environment: environment,
                streams: streams
            )
        }
    }

    @Test("mcp get with no name is an error")
    func getWithoutName() throws {
        let (root, environment) = try home("")
        defer { try? FileManager.default.removeItem(at: root) }

        let (streams, _, _) = CLIStreams.buffered()
        #expect(throws: CLIApplicationError.self) {
            try LiveMCPComposition.run(
                options: CLIResourceOptions(action: "get"),
                environment: environment,
                streams: streams
            )
        }
    }

    /// `add` and `remove` used to refuse outright, because the config layer had
    /// no serializer. They are implemented now, so this covers the round trip
    /// through the user config file rather than the old refusal wording.
    @Test("mcp add writes a server that list and remove then see")
    func addThenRemoveRoundTrips() throws {
        let (root, environment) = try home("")
        defer { try? FileManager.default.removeItem(at: root) }

        let (addStreams, addOut, _) = CLIStreams.buffered()
        try LiveMCPComposition.run(
            options: CLIResourceOptions(
                action: "add",
                target: "files",
                values: ["mcp-files", "--root", "/tmp"]
            ),
            environment: environment,
            streams: addStreams
        )
        #expect(addOut.contents.contains("files"))

        // The write landed in the user config, and `list` reads it back.
        let written = try String(
            contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8
        )
        #expect(written.contains("[mcp_servers.files]"))
        #expect(written.contains("command = \"mcp-files\""))

        let (listStreams, listOut, _) = CLIStreams.buffered()
        try LiveMCPComposition.run(
            options: CLIResourceOptions(action: "list"),
            environment: environment,
            streams: listStreams
        )
        #expect(listOut.contents.contains("files"))

        let (removeStreams, removeOut, _) = CLIStreams.buffered()
        try LiveMCPComposition.run(
            options: CLIResourceOptions(action: "remove", target: "files"),
            environment: environment,
            streams: removeStreams
        )
        #expect(removeOut.contents.contains("Removed"))
        let after = try String(
            contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8
        )
        #expect(!after.contains("mcp_servers"))
    }

    /// Adding over an existing name needs `--force`, so a stray `mcp add`
    /// cannot silently replace a hand-written entry.
    @Test("mcp add refuses to overwrite an existing server without --force")
    func addRefusesToClobber() throws {
        let (root, environment) = try home("""
        [mcp_servers.files]
        command = "original"
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let (streams, _, _) = CLIStreams.buffered()
        var caught: CLIApplicationError?
        do {
            try LiveMCPComposition.run(
                options: CLIResourceOptions(
                    action: "add", target: "files", values: ["replacement"]
                ),
                environment: environment,
                streams: streams
            )
        } catch let error as CLIApplicationError {
            caught = error
        }
        let error = try #require(caught)
        #expect(error.description.contains("already exists"))
        #expect(error.description.contains("--force"))

        // The original entry survived the refusal.
        let written = try String(
            contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8
        )
        #expect(written.contains("original"))
    }

    /// The actionable-error path is kept for input that cannot be satisfied.
    @Test("mcp add and remove still fail actionably on bad input")
    func addAndRemoveAreActionable() throws {
        let (root, environment) = try home("")
        defer { try? FileManager.default.removeItem(at: root) }

        // `add` with neither a command nor a URL has no transport to record.
        let (addStreams, _, _) = CLIStreams.buffered()
        var addError: CLIApplicationError?
        do {
            try LiveMCPComposition.run(
                options: CLIResourceOptions(action: "add", target: "files"),
                environment: environment,
                streams: addStreams
            )
        } catch let error as CLIApplicationError {
            addError = error
        }
        #expect(try #require(addError).description.contains("needs a transport"))

        // `remove` of a name that was never declared says so.
        let (removeStreams, _, _) = CLIStreams.buffered()
        var removeError: CLIApplicationError?
        do {
            try LiveMCPComposition.run(
                options: CLIResourceOptions(action: "remove", target: "files"),
                environment: environment,
                streams: removeStreams
            )
        } catch let error as CLIApplicationError {
            removeError = error
        }
        #expect(try #require(removeError).description.contains("no MCP server named 'files'"))
    }

    @Test("an unknown subcommand lists the ones that exist")
    func unknownSubcommand() throws {
        let (root, environment) = try home("")
        defer { try? FileManager.default.removeItem(at: root) }

        let (streams, _, _) = CLIStreams.buffered()
        #expect(throws: CLIApplicationError.self) {
            try LiveMCPComposition.run(
                options: CLIResourceOptions(action: "frobnicate"),
                environment: environment,
                streams: streams
            )
        }
    }

    @Test("the route claims only mcp commands")
    func routeClaimsOnlyMCP() {
        #expect(LiveMCPComposition.handles(.mcp(CLIResourceOptions(action: "list"))))
        #expect(!LiveMCPComposition.handles(.version(json: false)))
        #expect(!LiveMCPComposition.handles(.plugin(CLIResourceOptions(action: "list"))))
    }
}
