import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokTestSupport
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

private actor LiveIconPagedMCPHandler: MCPServerHandler {
    private let firstIcon: MCPIcon
    private let secondIcon: MCPIcon
    private var iconsEnabled = true

    init(firstIcon: MCPIcon, secondIcon: MCPIcon) {
        self.firstIcon = firstIcon
        self.secondIcon = secondIcon
    }

    func removeIcons() {
        iconsEnabled = false
    }

    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        if params.cursor == nil {
            return MCPListToolsResult(
                tools: [MCPTool(name: "first", icons: iconsEnabled ? [firstIcon] : [])],
                nextCursor: "second"
            )
        }
        return MCPListToolsResult(
            tools: [MCPTool(name: "second", icons: iconsEnabled ? [secondIcon] : [])]
        )
    }
}

private final class LiveIconMCPHTTPHandler: HttpRequestHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var iconDownloads: [String] = []
    private var methods: [String] = []

    func changeGeneration(to value: Int) {
        lock.lock()
        generation = value
        lock.unlock()
    }

    var requestedIconPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return iconDownloads
    }

    var listedToolCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return methods.filter { $0 == "tools/list" }.count
    }

    func handle(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST", request.pathOnly == "/mcp" else {
            if request.pathOnly.contains("icon") || request.pathOnly.hasSuffix(".png") {
                lock.lock()
                iconDownloads.append(request.pathOnly)
                lock.unlock()
            }
            return .notFound
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body)
            as? [String: Any],
              let method = message["method"] as? String
        else {
            return HttpResponse(status: 400, body: .bytes(Data()))
        }
        guard let id = message["id"] else {
            return HttpResponse(status: 202, body: .bytes(Data()))
        }

        lock.lock()
        methods.append(method)
        let current = generation
        lock.unlock()

        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": [
                    "name": "icon-server",
                    "version": "1.0.0",
                    "icons": [
                        ["src": "http://127.0.0.1:1/unsafe-server.png"],
                        [
                            "src": "  https://127.0.0.1:1/server-icon.png  ",
                            "mimeType": " image/png ",
                            "sizes": [" 48x48 "],
                            "theme": "dark",
                        ] as [String: Any],
                        ["src": "data:image/svg+xml;base64,not-actually-base64"],
                    ],
                ] as [String: Any],
            ]
        case "tools/list":
            var search: [String: Any] = [
                "name": "search",
                "description": "Search MCP documents",
                "inputSchema": ["type": "object"] as [String: Any],
            ]
            switch current {
            case 0:
                search["icons"] = [
                    ["src": "javascript:alert(1)"],
                    [
                        "src": "https://127.0.0.1:1/tool-v1.png",
                        "mimeType": " text/html ",
                        "sizes": [
                            String(repeating: "x", count: 33),
                            " 32x32 ",
                        ],
                        "theme": "light",
                    ] as [String: Any],
                ]
            case 1:
                search["icons"] = [
                    ["src": "https://127.0.0.1:1/tool-v2.png", "theme": "dark"],
                ]
            default:
                break
            }
            let plain: [String: Any] = [
                "name": "plain",
                "description": "Tool without an icon",
                "inputSchema": ["type": "object"] as [String: Any],
            ]
            result = ["tools": [search, plain]]
        case "shutdown":
            result = [:]
        default:
            result = [:]
        }

        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        let body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        return HttpResponse(
            status: 200,
            headers: [("content-type", "application/json")],
            body: .bytes(body)
        )
    }
}

private struct LiveIconACPHarness {
    let home: URL
    let mcp: LiveIconMCPHTTPHandler
    let http: HttpServer
    let connections: MCPSessionConnections
    let runtime: ACPAgentRuntime
    let sessionID: String

    static func start() async throws -> Self {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-mcp-icons-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let mcp = LiveIconMCPHTTPHandler()
        let http = HttpServer(handler: mcp, basePath: "")
        try http.start()

        do {
            let environment = ["OPENGROK_HOME": home.path, "HOME": home.path]
            let configuration = """
            [mcpServers.icon]
            url = "\(http.baseURL)/mcp"
            """
            try configuration.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
            let declarations = LiveMCPACPHandler.trustGatedDeclarationSource(
                workspaceRoot: home,
                environment: environment,
                cli: CLIPermissionOptions()
            )
            let toolset = FinalizedToolset(
                tools: [],
                resources: ToolResources(
                    cwd: home.path,
                    permissionPipeline: PermissionPipeline(
                        permissions: PermissionHandle(allowAll: true, shellCwd: home.path),
                        hooks: FailOpenPreToolUseHookRunner(inner: nil)
                    )
                ),
                codeModeNamespaces: [:],
                options: .unrestricted
            )
            let connections = MCPSessionConnections()
            var outcomes: [MCPServerConnection] = []
            for declaration in declarations().enabledServers {
                let result = await LiveMCPComposition.connect(
                    declaration: declaration,
                    toolset: toolset,
                    connections: connections,
                    environment: environment
                )
                outcomes.append(result)
            }
            guard outcomes.count == 1, outcomes[0].isConnected else {
                throw ACPRuntimeError.transport("live icon MCP server failed to connect: \(outcomes)")
            }

            let gateway = ACPNotificationGateway()
            let state = LiveMCPACPState(
                connections: connections,
                toolset: toolset,
                outcomes: outcomes
            )
            let handler = LiveMCPACPHandler(
                gateway: gateway,
                state: state,
                declarations: declarations,
                userConfigPath: home.appendingPathComponent("config.toml"),
                openGrokHome: home,
                environment: environment
            )
            let router = ACPExtensionMethodRouter()
                .register(prefix: "x.ai/mcp/", handler: handler)
            let runtime = ACPAgentRuntime(extensionRouter: router)
            await gateway.attach(runtime)

            let initialized = await runtime.handle(.request(
                id: .string("initialize"),
                method: AgentMethodNames.initialize,
                params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
            ))
            guard case .response(_, _, nil)? = initialized.last else {
                throw ACPRuntimeError.transport("live icon ACP initialization failed")
            }
            let opened = await runtime.handle(.request(
                id: .string("session"),
                method: AgentMethodNames.sessionNew,
                params: .object(["cwd": .string(home.path), "mcpServers": .array([])])
            ))
            guard case .response(_, let response?, nil)? = opened.last,
                  let sessionID = response["sessionId"]?.stringValue
            else {
                throw ACPRuntimeError.transport("live icon ACP session creation failed")
            }

            await connections.startLifecycle(
                sessionID: sessionID,
                toolset: toolset,
                declarations: declarations,
                environment: environment
            )
            await handler.attachLifecycle(sessionID: sessionID)

            return Self(
                home: home,
                mcp: mcp,
                http: http,
                connections: connections,
                runtime: runtime,
                sessionID: sessionID
            )
        } catch {
            http.stop()
            try? FileManager.default.removeItem(at: home)
            throw error
        }
    }

    func catalog(sessionID: String?) async throws -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["sessionId"] = .string(sessionID) }
        let response = await runtime.handle(.request(
            id: .string(UUID().uuidString),
            method: "x.ai/mcp/list",
            params: .object(params)
        ))
        guard case .response(_, let result?, nil)? = response.last else {
            throw ACPRuntimeError.transport("live icon ACP catalog request failed: \(response)")
        }
        return result
    }

    func refresh(until source: String?) async throws {
        connections.events.publish(.toolsChanged(server: "icon"))
        guard let client = await connections.client(named: "icon") else {
            throw ACPRuntimeError.transport("live icon MCP client disappeared")
        }
        for _ in 0..<100 {
            await Task.yield()
            await connections.flushLifecycle()
            let current = await client.toolIcons(named: "search").first?.src
            if current == source { return }
        }
        throw ACPRuntimeError.transport("live icon refresh did not reach generation \(source ?? "none")")
    }

    func shutdown() async {
        await runtime.close()
        await connections.shutdown()
        http.stop()
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("Live Rust-compatible MCP server and tool icon propagation", .serialized)
struct LiveMCPIconParityTests {
    @Test("the real hub MCP adapter atomically refreshes icon metadata across every tools/list page")
    func workspaceBridgeKeepsPagedIconsAndEvictsStaleSnapshots() async throws {
        let first = try #require(MCPIcon(src: "https://example.com/first.png"))
        let second = try #require(MCPIcon(src: "https://example.com/second.png"))
        let handler = LiveIconPagedMCPHandler(firstIcon: first, secondIcon: second)
        let server = MCPServer(
            configuration: MCPServerConfiguration(
                serverInfo: MCPImplementation(name: "hub-icons", version: "1"),
                capabilities: MCPCapabilities(tools: MCPToolsCapability())
            ),
            handler: handler
        )
        let client = MCPClient(transport: MCPInMemoryTransport(server: server))
        let initialized = try await client.initialize()
        #expect(initialized.serverInfo.name == "hub-icons")
        let adapter = MCPClientTransportAdapter(client: client)

        let initial = try await adapter.listTools()
        #expect(initial.map(\.name) == ["first", "second"])
        #expect(await client.toolIcons(named: "first") == [first])
        #expect(await client.toolIcons(named: "second") == [second])

        await handler.removeIcons()
        let refreshed = try await adapter.listTools()
        #expect(refreshed.map(\.name) == ["first", "second"])
        #expect(await client.toolIconsSnapshot().isEmpty)
        await client.close()
    }

    @Test("real HTTP MCP initialize and tools/list expose only sanitized icons over the actual ACP router")
    func serverAndToolIconsReachLiveACPCatalog() async throws {
        let harness = try await LiveIconACPHarness.start()
        defer { Task { await harness.shutdown() } }

        let plain = try await harness.catalog(sessionID: nil)
        let plainEntry = try #require(plain["result"]?["servers"]?.arrayValue?.first)
        #expect(plainEntry["icons"] == nil)
        #expect(plainEntry["session"] == nil)

        let unknown = try await harness.catalog(sessionID: "another-session")
        let unknownEntry = try #require(unknown["result"]?["servers"]?.arrayValue?.first)
        #expect(unknownEntry["icons"] == nil)
        #expect(unknownEntry["session"] == nil)

        let catalog = try await harness.catalog(sessionID: harness.sessionID)
        let server = try #require(catalog["result"]?["servers"]?.arrayValue?.first)
        let serverIcons = try #require(server["icons"]?.arrayValue)
        #expect(serverIcons.count == 2)
        #expect(serverIcons[0]["src"] == .string("https://127.0.0.1:1/server-icon.png"))
        #expect(serverIcons[0]["mimeType"] == .string("image/png"))
        #expect(serverIcons[0]["sizes"] == .array([.string("48x48")]))
        #expect(serverIcons[0]["theme"] == .string("dark"))
        #expect(serverIcons[1]["src"] == .string("data:image/svg+xml;base64,not-actually-base64"))
        #expect(serverIcons[1]["mimeType"] == nil)

        let tools = try #require(server["session"]?["tools"]?.arrayValue)
        let search = try #require(tools.first { $0["name"] == .string("search") })
        let icon = try #require(search["icons"]?.arrayValue?.first)
        #expect(icon["src"] == .string("https://127.0.0.1:1/tool-v1.png"))
        #expect(icon["mimeType"] == .string("text/html"))
        #expect(icon["sizes"] == .array([.string("32x32")]))
        #expect(icon["theme"] == .string("light"))

        let ordinary = try #require(tools.first { $0["name"] == .string("plain") })
        #expect(ordinary["icons"] == nil)
        #expect(harness.mcp.requestedIconPaths.isEmpty)
    }

    @Test("real tools/list_changed refresh replaces icons and removes stale metadata when icons disappear")
    func liveRefreshReplacesAndThenEvictsIcons() async throws {
        let harness = try await LiveIconACPHarness.start()
        defer { Task { await harness.shutdown() } }

        harness.mcp.changeGeneration(to: 1)
        try await harness.refresh(until: "https://127.0.0.1:1/tool-v2.png")
        let refreshed = try await harness.catalog(sessionID: harness.sessionID)
        let refreshedTools = try #require(
            refreshed["result"]?["servers"]?[0]?["session"]?["tools"]?.arrayValue
        )
        let refreshedSearch = try #require(refreshedTools.first { $0["name"] == .string("search") })
        let refreshedIcon = try #require(refreshedSearch["icons"]?.arrayValue?.first)
        #expect(refreshedIcon["src"] == .string("https://127.0.0.1:1/tool-v2.png"))
        #expect(refreshedIcon["theme"] == .string("dark"))
        #expect(refreshedIcon["mimeType"] == nil)

        harness.mcp.changeGeneration(to: 2)
        try await harness.refresh(until: nil)
        let cleared = try await harness.catalog(sessionID: harness.sessionID)
        let clearedTools = try #require(
            cleared["result"]?["servers"]?[0]?["session"]?["tools"]?.arrayValue
        )
        let clearedSearch = try #require(clearedTools.first { $0["name"] == .string("search") })
        #expect(clearedSearch["icons"] == nil)
        #expect(harness.mcp.listedToolCount >= 3)
        #expect(harness.mcp.requestedIconPaths.isEmpty)
    }
}
