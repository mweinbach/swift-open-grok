// LiveMCPComposition.swift
//
// Live MCP wiring: the `open-grok mcp` CLI route, and the session-time path
// that connects configured servers and publishes their tools into the tool
// registry.
//
// This is the only place that sees both `OpenGrokMCP` and
// `OpenGrokToolRegistry`. The registry deliberately does not depend on MCP, so
// the `MCPToolProviding` conformance for the real client actor lives here.
//
// Like `LiveAuthComposition`, this file is self-contained: the launcher hook
// that routes `mcp` here belongs in `LiveComposition.swift`, which the
// integration slice owns.

import Foundation
import OpenGrokACPRuntime
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokComputerHubMCPAdapter
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolRegistry

// MARK: - Hub bridge transport

/// One live MCP client to bridge onto the hub tool server.
///
/// Rust reference: `handle.rs:start_session_mcp_servers` retains started
/// clients per server name before wrapping them in `McpClientTransportAdapter`.
public struct HubMCPClientEntry: Sendable {
    public let serverName: String
    public let client: MCPClient

    public init(serverName: String, client: MCPClient) {
        self.serverName = serverName
        self.client = client
    }
}

/// Adapts [`MCPClient`] to [`McpTransport`] for [`McpBridge`].
///
/// Rust reference: `crates/codegen/xai-grok-workspace/src/mcp.rs:21-136`.
public struct MCPClientTransportAdapter: McpTransport {
    private let client: MCPClient

    public init(client: MCPClient) {
        self.client = client
    }

    public func initialize() async throws -> McpServerInfo {
        let result: MCPInitializeResult
        if await client.state() == .initialized,
           let existing = await client.initializeResultValue()
        {
            result = existing
        } else {
            result = try await client.initialize()
        }
        let capabilities = (try? JSONValue.encode(result.capabilities)) ?? .null
        return McpServerInfo(
            name: result.serverInfo.name,
            version: result.serverInfo.version,
            capabilities: capabilities
        )
    }

    public func listTools() async throws -> [McpToolDefinition] {
        var allTools: [McpToolDefinition] = []
        var cursor: String?
        var visitedCursors = Set<String>()
        repeat {
            let page = try await client.listTools(MCPListToolsParams(cursor: cursor))
            allTools.append(contentsOf: page.tools.map { tool in
                McpToolDefinition(
                    name: tool.name,
                    description: tool.description ?? tool.title,
                    inputSchema: tool.inputSchema
                )
            })
            cursor = page.nextCursor
            if let cursor, !visitedCursors.insert(cursor).inserted {
                throw MCPError.invalidRequest("MCP tools/list repeated pagination cursor '\(cursor)'")
            }
        } while cursor != nil
        return allTools
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> McpCallResult {
        let argsObject: JSONValue?
        switch arguments {
        case .object:
            argsObject = arguments
        case .null:
            argsObject = nil
        default:
            argsObject = .object(["value": arguments])
        }
        let result = try await client.callTool(
            MCPCallToolParams(name: name, arguments: argsObject)
        )
        return McpCallResult(
            content: result.content.map(hubMcpContent(from:)),
            isError: result.isError
        )
    }

    public func close() async throws {
        // No-op: the session owner retains and shuts down the client.
    }
}

private func hubMcpContent(from block: MCPContent) -> McpContent {
    switch block {
    case .text(let text, _):
        return .text(text: text)
    case .image(let data, let mimeType, _):
        return .image(mimeType: mimeType, data: data)
    case .audio(let data, let mimeType, _):
        return .text(text: "[audio: \(mimeType), \(data.count) bytes]")
    case .resource(let embedded):
        return .resource(
            uri: embedded.resource.uri,
            mimeType: embedded.resource.mimeType,
            text: embedded.resource.text
        )
    case .resourceLink(let link):
        return .text(text: "[resource: \(link.uri)]")
    }
}

// MARK: - Client adapter

/// Adapts the `MCPClient` actor to the registry's provider seam.
///
/// The registry never learns what MCP is; it sees a name, a tool list, and a
/// call function. Cancellation of an in-flight call is the client actor's job
/// (`MCPClient.cancel(requestID:reason:)`), reached here by cancelling the
/// surrounding task — `performRequest` installs a cancellation handler that
/// emits `notifications/cancelled` to the server.
public struct MCPClientToolProvider: MCPToolProviding {
    public let serverName: String
    private let client: MCPClient

    public init(serverName: String, client: MCPClient) {
        self.serverName = serverName
        self.client = client
    }

    public func listBridgedTools() async throws -> [MCPBridgedTool] {
        var bridged: [MCPBridgedTool] = []
        var cursor: String?
        var visitedCursors = Set<String>()
        repeat {
            let page = try await client.listTools(MCPListToolsParams(cursor: cursor))
            bridged.append(contentsOf: page.tools.map { tool in
                MCPBridgedTool(
                    name: tool.name,
                    description: tool.description ?? tool.title ?? "",
                    inputSchema: Self.normalizedInputSchema(tool.inputSchema),
                    modelVisible: Self.isModelVisible(tool)
                )
            })
            cursor = page.nextCursor
            if let cursor, !visitedCursors.insert(cursor).inserted {
                throw MCPError.invalidRequest("MCP tools/list repeated pagination cursor '\(cursor)'")
            }
        } while cursor != nil
        return bridged
    }

    private static func normalizedInputSchema(_ schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema else {
            return .object(["type": .string("object"), "properties": .object([:])])
        }
        if object["type"] == nil {
            object["type"] = .string("object")
        }
        if object["properties"] == nil {
            object["properties"] = .object([:])
        }
        return .object(object)
    }

    public func callBridgedTool(
        name: String,
        arguments: JSONValue
    ) async throws -> MCPBridgedCallResult {
        let result = try await client.callTool(
            MCPCallToolParams(name: name, arguments: arguments)
        )
        return MCPBridgedCallResult(
            text: Self.flatten(result.content),
            structuredContent: result.structuredContent,
            isError: result.isError
        )
    }

    /// A server can hide a tool from the model with
    /// `_meta.ui.visibility = [...]`; absent metadata means visible.
    static func isModelVisible(_ tool: MCPTool) -> Bool {
        guard case .object(let meta)? = tool.meta,
              case .object(let ui)? = meta["ui"],
              case .array(let visibility)? = ui["visibility"] else {
            return true
        }
        return visibility.contains { entry in
            if case .string(let value) = entry { return value == "model" }
            return false
        }
    }

    /// Flatten MCP content blocks into the single text body the tool runtime
    /// hands back to the model. Binary payloads are summarised rather than
    /// inlined so a large image cannot blow up the transcript.
    static func flatten(_ content: [MCPContent]) -> String {
        content.map { block in
            switch block {
            case .text(let text, _):
                return text
            case .image(_, let mimeType, _):
                return "[image: \(mimeType)]"
            case .audio(_, let mimeType, _):
                return "[audio: \(mimeType)]"
            case .resource(let embedded):
                return Self.describe(embedded)
            case .resourceLink(let link):
                return "[resource: \(link.uri)]"
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func describe(_ embedded: MCPEmbeddedResource) -> String {
        if let text = embedded.resource.text, !text.isEmpty { return text }
        return "[resource: \(embedded.resource.uri)]"
    }
}

// MARK: - Connection results

/// Outcome of bringing one configured server online.
public struct MCPServerConnection: Sendable {
    public var name: String
    /// Qualified tool names this server contributed (`{server}__{tool}`).
    public var toolNames: [String]
    /// Populated when the server could not be used. Never fatal.
    public var failure: String?
    /// Tools the server advertised but that were not registered.
    public var skipped: [String: String]

    public init(
        name: String,
        toolNames: [String] = [],
        failure: String? = nil,
        skipped: [String: String] = [:]
    ) {
        self.name = name
        self.toolNames = toolNames
        self.failure = failure
        self.skipped = skipped
    }

    public var isConnected: Bool { failure == nil }
}

/// Live MCP servers held open for the duration of a session.
public actor MCPSessionConnections {
    private var clients: [String: MCPClient] = [:]
    private var clientIdentifiers: [String: UInt64] = [:]
    private var resources: [String: [MCPResource]] = [:]
    private var nextClientIdentifier: UInt64 = 1
    private var lifecycle: LiveMCPLifecycle?
    nonisolated let events = MCPEventStream()

    public init() {}

    func reserveClientIdentifier() -> UInt64 {
        let identifier = nextClientIdentifier
        nextClientIdentifier &+= 1
        if nextClientIdentifier == 0 {
            nextClientIdentifier = 1
        }
        return identifier
    }

    func retain(_ client: MCPClient, as name: String, clientID: UInt64? = nil) {
        clients[name] = client
        clientIdentifiers[name] = clientID ?? reserveClientIdentifier()
    }

    /// The retained client for one server, for the `x.ai/mcp/call` /
    /// `read_resource` ext methods — the SAME client the session's bridged
    /// tools call through, so a direct call and a model tool call cannot
    /// observe different servers.
    func client(named name: String) -> MCPClient? { clients[name] }

    func clientIdentifier(named name: String) -> UInt64? { clientIdentifiers[name] }

    func resourceSnapshot(named name: String) -> [MCPResource] {
        resources[name] ?? []
    }

    func replaceResources(_ updated: [MCPResource], for name: String) {
        resources[name] = updated
    }

    /// Remove one server's client from the pool WITHOUT closing it — the
    /// caller owns the shutdown, because teardown must also unregister the
    /// server's tools and only the caller holds the toolset.
    func release(named name: String) -> MCPClient? {
        clientIdentifiers.removeValue(forKey: name)
        resources.removeValue(forKey: name)
        return clients.removeValue(forKey: name)
    }

    public func names() -> [String] { clients.keys.sorted() }

    func startLifecycle(
        sessionID: String,
        toolset: FinalizedToolset,
        declarations: @escaping @Sendable () -> MCPConfigLoadResult,
        environment: [String: String],
        disabledTools: @escaping @Sendable (String) -> Set<String> = { _ in [] }
    ) async {
        guard lifecycle == nil else { return }
        let live = LiveMCPLifecycle(
            sessionID: sessionID,
            connections: self,
            toolset: toolset,
            declarations: declarations,
            environment: environment,
            disabledTools: disabledTools
        )
        lifecycle = live
        await live.start(events: events.subscribe())
    }

    func attachLifecycle(
        gateway: ACPNotificationGateway,
        state: LiveMCPACPState,
        declarations: @escaping @Sendable () -> MCPConfigLoadResult,
        disabledTools: @escaping @Sendable (String) -> Set<String>
    ) async {
        await lifecycle?.attach(
            gateway: gateway,
            state: state,
            declarations: declarations,
            disabledTools: disabledTools
        )
    }

    func markServerShuttingDown(_ name: String) async {
        await lifecycle?.markShuttingDown(name)
    }

    func markServerAvailable(_ name: String) async {
        await lifecycle?.markAvailable(name)
    }

    func flushLifecycle() async {
        await lifecycle?.flush()
    }

    /// Close every server. Safe to call more than once.
    public func shutdown() async {
        let live = lifecycle
        lifecycle = nil
        await live?.close()
        events.finish()
        let open = clients
        clients.removeAll()
        clientIdentifiers.removeAll()
        resources.removeAll()
        for client in open.values {
            try? await client.shutdown()
            await client.close()
        }
    }
}

private actor LiveMCPLifecycle: McpRestartActions {
    private let sessionID: String
    private let connections: MCPSessionConnections
    private let toolset: FinalizedToolset
    private let environment: [String: String]
    private var declarationSource: @Sendable () -> MCPConfigLoadResult
    private var disabledToolSource: @Sendable (String) -> Set<String>
    private var dispatcher: McpEventDispatcher?
    private var gateway: ACPNotificationGateway?
    private var state: LiveMCPACPState?
    private var restarting: Set<String> = []
    private var shuttingDown: Set<String> = []
    private var isClosed = false

    init(
        sessionID: String,
        connections: MCPSessionConnections,
        toolset: FinalizedToolset,
        declarations: @escaping @Sendable () -> MCPConfigLoadResult,
        environment: [String: String],
        disabledTools: @escaping @Sendable (String) -> Set<String>
    ) {
        self.sessionID = sessionID
        self.connections = connections
        self.toolset = toolset
        self.declarationSource = declarations
        self.environment = environment
        self.disabledToolSource = disabledTools
    }

    func start(events: AsyncStream<McpClientEvent>) async {
        let callbacks = McpEventDispatcherCallbacks(
            isConfiguredAndEnabled: { [weak self] name in
                await self?.isConfiguredAndEnabled(server: name) ?? false
            },
            currentClientID: { [weak self] name in
                guard let self else { return nil }
                return await self.connections.clientIdentifier(named: name)
            },
            removeClient: { [weak self] name in
                await self?.removeClosedClient(server: name)
            },
            refreshTools: { [weak self] name in
                await self?.refreshTools(server: name)
            },
            refreshResources: { [weak self] name in
                await self?.refreshResources(server: name)
            },
            pushStatus: { [weak self] payload in
                await self?.pushStatus(payload: payload)
            }
        )
        let dispatcher = McpEventDispatcher(
            sessionID: sessionID,
            callbacks: callbacks,
            restartActions: self
        )
        self.dispatcher = dispatcher
        await dispatcher.start(events: events)
    }

    func attach(
        gateway: ACPNotificationGateway,
        state: LiveMCPACPState,
        declarations: @escaping @Sendable () -> MCPConfigLoadResult,
        disabledTools: @escaping @Sendable (String) -> Set<String>
    ) {
        self.gateway = gateway
        self.state = state
        self.declarationSource = declarations
        let originalDisabledTools = disabledToolSource
        self.disabledToolSource = { name in
            originalDisabledTools(name).union(disabledTools(name))
        }
    }

    func markShuttingDown(_ server: String) {
        shuttingDown.insert(server)
    }

    func markAvailable(_ server: String) {
        shuttingDown.remove(server)
    }

    func flush() async {
        await dispatcher?.flush()
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let names = await connections.names()
        shuttingDown.formUnion(names)
        await dispatcher?.close()
        dispatcher = nil
        gateway = nil
        state = nil
    }

    private func declaration(named server: String) -> MCPServerDeclaration? {
        declarationSource().servers.first { $0.name == server }
    }

    private func isConfiguredAndEnabled(server: String) -> Bool {
        !isClosed && !shuttingDown.contains(server)
            && declaration(named: server)?.isEnabled == true
    }

    private func removeClosedClient(server: String) async {
        guard let previous = await connections.release(named: server) else { return }
        await previous.close()
        MCPToolBridge.unregister(server: server, from: toolset)
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)
        await state?.record(MCPServerConnection(
            name: server,
            failure: "MCP server transport closed"
        ))
    }

    private func refreshTools(server: String) async {
        guard isConfiguredAndEnabled(server: server),
              let client = await connections.client(named: server)
        else { return }

        MCPToolBridge.unregister(server: server, from: toolset)
        let registration = await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: server, client: client),
            into: toolset,
            disabledToolNames: disabledToolSource(server)
        )
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)
        let outcome = MCPServerConnection(
            name: server,
            toolNames: registration.registeredNames,
            failure: registration.failure,
            skipped: registration.skipped
        )
        await state?.record(outcome)
        if let failure = registration.failure {
            await pushStatus(payload: McpServerStatusPayload(
                sessionId: sessionID,
                name: server,
                source: McpServerSource.classify(name: server),
                status: .unavailable,
                reason: .unavailable,
                detail: failure
            ))
        }
    }

    private func refreshResources(server: String) async {
        guard isConfiguredAndEnabled(server: server),
              let client = await connections.client(named: server),
              await client.serverCapabilities()?.resources != nil
        else { return }

        var collected: [MCPResource] = []
        var cursor: String?
        var visitedCursors: Set<String> = []
        do {
            repeat {
                let page = try await client.listResources(MCPListResourcesParams(cursor: cursor))
                collected.append(contentsOf: page.resources)
                cursor = page.nextCursor
                if let cursor, !visitedCursors.insert(cursor).inserted {
                    throw MCPError.invalidRequest(
                        "MCP resources/list repeated pagination cursor '\(cursor)'"
                    )
                }
            } while cursor != nil
            await connections.replaceResources(collected, for: server)
        } catch {
            await pushStatus(payload: McpServerStatusPayload(
                sessionId: sessionID,
                name: server,
                source: McpServerSource.classify(name: server),
                status: .unavailable,
                reason: .unavailable,
                detail: "resources/list failed: \(error)"
            ))
        }
    }

    func isStdioServerConfigured(server: String) async -> Bool {
        guard isConfiguredAndEnabled(server: server),
              case .stdio = declaration(named: server)?.config.transport
        else { return false }
        return true
    }

    func isHttpServerConfigured(server: String) async -> Bool {
        guard isConfiguredAndEnabled(server: server),
              case .streamableHttp = declaration(named: server)?.config.transport
        else { return false }
        return true
    }

    func isInShuttingDown(server: String) async -> Bool {
        isClosed || shuttingDown.contains(server)
    }

    func beginRestart(server: String) async -> Bool {
        restarting.insert(server).inserted
    }

    func endRestart(server: String) async {
        restarting.remove(server)
    }

    func respawnStdio(server: String) async -> Result<Void, McpRestartError> {
        guard let declaration = declaration(named: server),
              case .stdio = declaration.config.transport,
              isConfiguredAndEnabled(server: server)
        else { return .failure(McpRestartError("server is disabled or no longer configured")) }

        if let previous = await connections.release(named: server) {
            await previous.close()
        }
        MCPToolBridge.unregister(server: server, from: toolset)
        let outcome = await LiveMCPComposition.connect(
            declaration: declaration,
            toolset: toolset,
            connections: connections,
            environment: environment,
            disabledToolNames: disabledToolSource(server)
        )
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)
        await state?.record(outcome)
        if let failure = outcome.failure {
            return .failure(McpRestartError(failure))
        }
        return .success(())
    }

    func resetHttpClient(server: String) async -> Result<Void, McpRestartError> {
        guard let declaration = declaration(named: server),
              case .streamableHttp = declaration.config.transport,
              isConfiguredAndEnabled(server: server)
        else { return .failure(McpRestartError("server is disabled or no longer configured")) }

        if let previous = await connections.release(named: server) {
            await previous.close()
        }
        MCPToolBridge.unregister(server: server, from: toolset)
        let outcome = await LiveMCPComposition.connect(
            declaration: declaration,
            toolset: toolset,
            connections: connections,
            environment: environment,
            disabledToolNames: disabledToolSource(server)
        )
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)
        await state?.record(outcome)
        if let failure = outcome.failure {
            return .failure(McpRestartError(failure))
        }
        return .success(())
    }

    func unregisterServerTools(server: String) async {
        MCPToolBridge.unregister(server: server, from: toolset)
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)
    }

    func serverClientStateKind(server: String) async -> ClientStateKind? {
        guard let client = await connections.client(named: server) else { return nil }
        switch await client.state() {
        case .initialized:
            return .ready
        case .initializing:
            return .initializing
        case .disconnected:
            return .pending
        case .shuttingDown, .closed:
            return .empty
        }
    }

    func pushStatus(payload: McpServerStatusPayload) async {
        var fields: [String: JSONValue] = [
            "sessionId": .string(payload.sessionId),
            "name": .string(payload.name),
            "source": .string(payload.source.rawValue),
            "status": .string(payload.status.rawValue),
            "reason": .string(payload.reason.rawValue),
            "tools": payload.tools ?? .null,
        ]
        if let detail = payload.detail {
            fields["detail"] = .string(detail)
        }
        await gateway?.send(method: "x.ai/mcp/server_status", params: .object(fields))
    }
}

// MARK: - /mcps status overlay

/// The `/mcps` read-only status body, built from the connection outcomes the
/// session recorded when it brought its configured servers online (upstream
/// opens the extensions modal's MCP tab, `slash/commands/mcps.rs:19-24`; this
/// port renders the same facts — name, connected/failed, tools — as text).
enum LiveMCPStatusOverlay {
    static func lines(connections: [MCPServerConnection]) -> [String] {
        guard !connections.isEmpty else {
            return ["No MCP servers configured for this session."]
        }
        var lines: [String] = []
        for connection in connections.sorted(by: { $0.name < $1.name }) {
            if let failure = connection.failure {
                lines.append("✗ \(connection.name) — \(failure)")
                continue
            }
            let toolCount = connection.toolNames.count
            lines.append(
                "● \(connection.name) — connected, "
                    + "\(toolCount) tool\(toolCount == 1 ? "" : "s")"
            )
            for tool in connection.toolNames.sorted() {
                lines.append("    \(tool)")
            }
            for (tool, reason) in connection.skipped.sorted(by: { $0.key < $1.key }) {
                lines.append("    (skipped) \(tool) — \(reason)")
            }
        }
        return lines
    }
}

// MARK: - Composition

public enum LiveMCPComposition {
    public static let routeName = "mcp"

    /// Subcommands this route accepts. `login` is this port's explicit MCP
    /// OAuth trigger — the honest equivalent of upstream's user-initiated
    /// `x.ai/mcp/auth_trigger` ext method (xai-grok-shell/src/extensions/
    /// mcp.rs:40,1526-1578 → `force_reauth(true)`), which has no ACP surface
    /// in this port.
    public static let actions: Set<String> = ["list", "get", "add", "remove", "login"]

    public static func handles(_ command: CLICommand) -> Bool {
        if case .mcp = command { return true }
        return false
    }

    /// Launcher entry point. Runs to completion and hands back a finished
    /// session, matching `LiveAuthComposition`.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .mcp(let options) = command else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        // `login` runs a browser consent flow and so needs this async seam;
        // the other actions stay on the synchronous `run` path shared with
        // `CLIRunner.main`.
        if options.action == "login" {
            try await runLogin(options: options, environment: context.environment, streams: context.streams)
            return CLIApplicationSession(waitForExit: {}, shutdown: {})
        }
        try run(options: options, environment: context.environment, streams: context.streams)
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    // MARK: Session wiring

    /// Connect every enabled server in `document` and publish its tools into
    /// `toolset`.
    ///
    /// A server that fails to start, fails to initialize, or advertises
    /// unusable tools yields a connection carrying the reason; the toolset
    /// keeps working and the remaining servers still connect. Nothing here can
    /// throw into the session.
    @discardableResult
    public static func connectConfiguredServers(
        document: TOMLValue?,
        toolset: FinalizedToolset,
        connections: MCPSessionConnections,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeHTTPTransport: @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() }
    ) async -> [MCPServerConnection] {
        guard let document else { return [] }
        let loaded = MCPConfigLoader.load(from: document)

        var results: [MCPServerConnection] = loaded.problems.map {
            MCPServerConnection(name: $0.server, failure: $0.message)
        }

        let disabledServers = disabledMCPServers(in: document)
        let disabledToolsByServer = allDisabledMCPTools(in: document)

        for declaration in loaded.enabledServers {
            if disabledServers.contains(declaration.name) {
                continue
            }
            results.append(await connect(
                declaration: declaration,
                toolset: toolset,
                connections: connections,
                environment: environment,
                makeHTTPTransport: makeHTTPTransport,
                disabledToolNames: disabledToolsByServer[declaration.name] ?? []
            ))
        }
        return results
    }

    /// Connect configured MCP servers for hub session bridging only.
    ///
    /// Unlike `connectConfiguredServers`, this does **not** register tools
    /// into a session `FinalizedToolset`. Upstream's
    /// `start_session_mcp_servers` bridges local MCP clients onto the hub
    /// tool server instead.
    public static func connectConfiguredClientsForHub(
        cwd: String,
        environment: [String: String],
        connections: MCPSessionConnections,
        makeHTTPTransport: @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() }
    ) async -> [HubMCPClientEntry] {
        let cwdURL = URL(fileURLWithPath: cwd)
        let loaded: MCPConfigLoadResult
        do {
            loaded = try loadDeclarations(environment: environment, cwd: cwdURL)
        } catch {
            return []
        }

        var disabledServers = Set<String>()
        if let layers = try? configLayers(environment: environment, cwd: cwdURL) {
            for (_, document) in layers {
                disabledServers.formUnion(disabledMCPServers(in: document))
            }
        }

        var entries: [HubMCPClientEntry] = []
        for declaration in loaded.enabledServers {
            if disabledServers.contains(declaration.name) {
                continue
            }
            if let entry = await connectClientForHub(
                declaration: declaration,
                connections: connections,
                environment: environment,
                makeHTTPTransport: makeHTTPTransport
            ) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Connect one MCP server for hub bridging without touching a toolset.
    static func connectClientForHub(
        declaration: MCPServerDeclaration,
        connections: MCPSessionConnections,
        environment: [String: String],
        makeHTTPTransport: @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() }
    ) async -> HubMCPClientEntry? {
        var authorization: (any MCPAuthorizationProviding)?
        if let endpoint = declaration.oauthEligibleEndpoint(environment: environment),
           let home = userGrokHome(environment: environment)
        {
            let storage = MCPFileCredentialStorage(
                home: home, serverName: declaration.name, serverURL: endpoint)
            if (try? storage.load())?.tokenResponse != nil {
                authorization = MCPAuthorizationManager(
                    baseURL: endpoint,
                    transport: makeHTTPTransport(),
                    storage: storage
                )
            } else if await MCPOAuthProbe.serverAdvertisesOAuth(
                url: endpoint, transport: makeHTTPTransport()
            ) {
                return nil
            }
        }

        let transport: any MCPTransport
        do {
            transport = try declaration.makeTransport(
                httpTransport: makeHTTPTransport(),
                environment: environment,
                authorization: authorization
            )
        } catch {
            return nil
        }

        let client = MCPClient(transport: transport)
        let clientID = await connections.reserveClientIdentifier()
        await client.setEventSink(
            connections.events,
            serverName: declaration.name,
            clientID: clientID
        )
        do {
            _ = try await client.initialize()
        } catch {
            await client.close()
            return nil
        }

        await connections.retain(client, as: declaration.name, clientID: clientID)
        return HubMCPClientEntry(serverName: declaration.name, client: client)
    }

    /// The `/mcps` row for an OAuth server with no usable stored token —
    /// the port's rendering of upstream's `auth_required` session state
    /// (xai-grok-shell/src/extensions/mcp.rs:149-153), pointing at the
    /// trigger that exists here.
    static func authorizationRequiredNotice(serverName: String) -> String {
        "authorization required — run `open-grok mcp login \(serverName)` to sign in"
    }

    /// Connect a single declaration. Exposed so tests can drive one server.
    ///
    /// OAuth wiring, mirroring upstream's connect-time posture
    /// (`discover_and_prepare_auth`, xai-grok-mcp/src/servers.rs:1826-1906):
    /// stored tokens attach through the live `MCPAuthorizationManager`
    /// (proactive refresh + 401 recovery); a server that advertises OAuth but
    /// has no stored token records an auth-required outcome for `/mcps`
    /// instead of starting an unauthenticated worker; a server with a static
    /// `Authorization` header (or bearer env var) skips OAuth entirely
    /// (servers.rs:4294-4304). Upstream defers the browser to a user trigger
    /// rather than opening it at connect; this port's trigger is
    /// `open-grok mcp login <name>`.
    public static func connect(
        declaration: MCPServerDeclaration,
        toolset: FinalizedToolset,
        connections: MCPSessionConnections,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeHTTPTransport: @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() },
        disabledToolNames: Set<String> = []
    ) async -> MCPServerConnection {
        var authorization: (any MCPAuthorizationProviding)?
        if let endpoint = declaration.oauthEligibleEndpoint(environment: environment),
           let home = userGrokHome(environment: environment) {
            let storage = MCPFileCredentialStorage(
                home: home, serverName: declaration.name, serverURL: endpoint)
            if (try? storage.load())?.tokenResponse != nil {
                authorization = MCPAuthorizationManager(
                    baseURL: endpoint,
                    transport: makeHTTPTransport(),
                    storage: storage
                )
            } else if await MCPOAuthProbe.serverAdvertisesOAuth(
                url: endpoint, transport: makeHTTPTransport()
            ) {
                return MCPServerConnection(
                    name: declaration.name,
                    failure: authorizationRequiredNotice(serverName: declaration.name)
                )
            }
        }

        let transport: any MCPTransport
        do {
            transport = try declaration.makeTransport(
                httpTransport: makeHTTPTransport(),
                environment: environment,
                authorization: authorization
            )
        } catch {
            return MCPServerConnection(name: declaration.name, failure: String(describing: error))
        }

        let client = MCPClient(transport: transport)
        let clientID = await connections.reserveClientIdentifier()
        await client.setEventSink(
            connections.events,
            serverName: declaration.name,
            clientID: clientID
        )
        do {
            _ = try await client.initialize()
        } catch {
            await client.close()
            return MCPServerConnection(
                name: declaration.name,
                failure: "initialize failed: \(error)"
            )
        }

        let registration = await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: declaration.name, client: client),
            into: toolset,
            disabledToolNames: disabledToolNames
        )
        if let failure = registration.failure {
            await client.close()
            return MCPServerConnection(name: declaration.name, failure: failure)
        }

        await connections.retain(client, as: declaration.name, clientID: clientID)
        return MCPServerConnection(
            name: declaration.name,
            toolNames: registration.registeredNames,
            skipped: registration.skipped
        )
    }

    // MARK: CLI

    public static func run(
        options: CLIResourceOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        streams: CLIStreams
    ) throws {
        switch options.action {
        case "list":
            try runList(options: options, environment: environment, streams: streams)
        case "get":
            try runGet(options: options, environment: environment, streams: streams)
        case "add":
            try runAdd(options: options, environment: environment, streams: streams)
        case "remove":
            try runRemove(options: options, environment: environment, streams: streams)
        case "login":
            // Reachable only through `CLIRunner.main`'s synchronous seam; the
            // executable's async path dispatches login in `session` above.
            throw CLIApplicationError.failed(
                "`mcp login` is interactive and needs the async runner; invoke it through the open-grok binary"
            )
        default:
            throw CLIApplicationError.failed(
                "unknown `mcp` subcommand '\(options.action)' (expected: \(actions.sorted().joined(separator: ", ")))"
            )
        }
    }

    // MARK: login

    /// `open-grok mcp login <name>` — run the interactive OAuth flow for one
    /// configured HTTP MCP server and persist tokens to the real
    /// `$OPENGROK_HOME/mcp_credentials.json`.
    ///
    /// This is the port's user-initiated trigger, standing in for upstream's
    /// `x.ai/mcp/auth_trigger` → `force_reauth(true)` (extensions/mcp.rs:
    /// 1526-1578, acp_session_impl/mcp.rs:405-426): `force: true` skips the
    /// dedup layers so a stale abandoned flow never blocks a fresh consent,
    /// and the refresh-first arm inside the flow still avoids the browser
    /// when a refresh grant suffices.
    static func runLogin(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        transport: (any HTTPTransport)? = nil,
        openBrowser: (@Sendable (URL) -> Void)? = nil,
        timeoutSeconds: TimeInterval = mcpBrowserAuthTimeoutSeconds
    ) async throws {
        guard let name = options.target, !name.isEmpty else {
            throw CLIApplicationError.failed("`mcp login` needs a server name")
        }
        let loaded = try loadDeclarations(environment: environment, cwd: cwd)
        guard let declaration = loaded.servers.first(where: { $0.name == name }) else {
            let known = loaded.servers.map(\.name).sorted()
            throw CLIApplicationError.failed(
                known.isEmpty
                    ? "no MCP server named '\(name)' (none are configured)"
                    : "no MCP server named '\(name)' (configured: \(known.joined(separator: ", ")))"
            )
        }
        guard case .streamableHttp = declaration.config.transport else {
            // Upstream's auth trigger reports the same class of refusal for
            // non-OAuth servers ("does not use OAuth").
            throw CLIApplicationError.failed("MCP server '\(name)' does not use OAuth")
        }
        guard let endpoint = declaration.oauthEligibleEndpoint(environment: environment) else {
            throw CLIApplicationError.failed(
                "MCP server '\(name)' already authenticates with a configured Authorization header"
            )
        }
        guard let home = userGrokHome(environment: environment) else {
            throw CLIApplicationError.failed(
                "cannot resolve the user config directory (set $OPENGROK_HOME or $HOME)"
            )
        }

        let httpTransport = transport ?? URLSessionHTTPTransport()
        let announce: @Sendable (URL) -> Void = { url in
            streams.out("Opening browser for MCP OAuth consent:\n\(url.absoluteString)\n")
            if let openBrowser {
                openBrowser(url)
            } else {
                LiveAuthComposition.openInSystemBrowser(url)
            }
        }

        do {
            try await mcpAuthenticateServer(
                serverName: name,
                serverURL: endpoint,
                home: home,
                transport: httpTransport,
                byoConfig: declaration.config.oauthConfig(environment: environment),
                force: true,
                openBrowser: announce,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            throw CLIApplicationError.failed(
                "Authentication failed for MCP server '\(name)': \(error)"
            )
        }

        // Assert the store write at the step it happened (AGENTS.md §3) —
        // "flow returned" is not "token landed".
        let storage = MCPFileCredentialStorage(home: home, serverName: name, serverURL: endpoint)
        guard (try? storage.load())?.tokenResponse != nil else {
            throw CLIApplicationError.failed(
                "Authentication failed for MCP server '\(name)': no credentials were stored"
            )
        }
        streams.out("Authenticated MCP server '\(name)'.\n")
    }

    // MARK: add / remove

    /// The config file `add` / `remove` edit.
    ///
    /// Upstream picks between user and project scope with `--scope`
    /// (`mcp_cmd.rs:478`, `scope_target`). This CLI's resource parser has no
    /// `--scope` flag, so the default is user scope and `--config <path>`
    /// selects an explicit file instead.
    static func editTarget(
        options: CLIResourceOptions,
        environment: [String: String],
        cwd: URL
    ) throws -> URL {
        if let explicit = options.options["--config"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit, relativeTo: cwd)
            return url.standardizedFileURL
        }
        guard let home = userGrokHome(environment: environment) else {
            throw CLIApplicationError.failed(
                "cannot resolve the user config directory; pass --config <path> to choose a file"
            )
        }
        return home.appendingPathComponent("config.toml")
    }

    /// Read a config file as a raw TOML document for editing.
    ///
    /// Mirrors upstream (`mcp.rs:865-868`): an unparseable file yields an empty
    /// root rather than failing, because the write replaces the document
    /// wholesale. A *missing* file returns `nil` so the two callers can differ —
    /// `add` treats it as an empty document, `remove` reports "not found"
    /// instead of writing a stub.
    static func loadForEdit(at path: URL) -> TOMLValue? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        return (try? parseTOML(text)) ?? .table(TOMLTable())
    }

    /// A `KEY=VALUE` positional, per upstream's `looks_like_env_pair`
    /// (`mcp_cmd.rs:458`): a non-empty name before the first `=`.
    static func envPair(_ token: String) -> (String, String)? {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
            return nil
        }
        return (String(token[..<separator]), String(token[token.index(after: separator)...]))
    }

    /// Build the server config from the parsed CLI surface.
    ///
    /// `--url` (or `--transport http`/`sse`) selects the streamable-HTTP
    /// transport; otherwise the leading `KEY=VALUE` positionals become `env`
    /// and the remainder is the command and its arguments, matching upstream's
    /// `resolve_add` (`mcp_cmd.rs:275`).
    static func resolveAdd(options: CLIResourceOptions) throws -> McpServerConfig {
        let transportType = options.options["--transport"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let url = options.options["--url"], !url.isEmpty {
            return McpServerConfig(
                transport: .streamableHttp(
                    url: url,
                    transportType: transportType,
                    bearerTokenEnvVar: nil,
                    headers: nil,
                    oauthClientId: nil,
                    oauthClientSecretEnvVar: nil,
                    oauthScopes: nil
                )
            )
        }

        var tokens = options.values
        if let command = options.options["--command"], !command.isEmpty {
            tokens.insert(command, at: 0)
        }

        var env: [String: String] = [:]
        while let first = tokens.first, let pair = envPair(first) {
            env[pair.0] = pair.1
            tokens.removeFirst()
        }

        guard let command = tokens.first, !command.isEmpty else {
            throw CLIApplicationError.failed(
                """
                `mcp add` needs a transport: pass a command (\
                `open-grok mcp add NAME -- npx server`) or `--url <endpoint>`.
                """
            )
        }
        if transportType == "http" || transportType == "sse" {
            throw CLIApplicationError.failed(
                "`--transport \(transportType!)` needs `--url <endpoint>`, not a command"
            )
        }
        return McpServerConfig(
            transport: .stdio(
                command: command,
                args: Array(tokens.dropFirst()),
                env: env.isEmpty ? nil : env,
                cwd: nil
            )
        )
    }

    static func runAdd(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws {
        guard let name = options.target, !name.isEmpty else {
            throw CLIApplicationError.failed("`mcp add` needs a server name")
        }
        let path = try editTarget(options: options, environment: environment, cwd: cwd)
        let config = try resolveAdd(options: options)

        var root = loadForEdit(at: path) ?? .table(TOMLTable())
        let replacing = mcpServerIsDefined(name, in: root)
        if replacing && !options.force {
            throw CLIApplicationError.failed(
                "MCP server '\(name)' already exists in \(path.path); pass --force to replace it"
            )
        }
        do {
            try upsertMCPServer(name, config: config, in: &root)
            try writeConfigFile(root, to: path)
        } catch {
            throw CLIApplicationError.failed(
                "could not update \(path.path): \(error)"
            )
        }
        streams.out(
            "\(replacing ? "Replaced" : "Added") MCP server '\(name)' in \(path.path)\n"
        )
    }

    static func runRemove(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws {
        guard let name = options.target, !name.isEmpty else {
            throw CLIApplicationError.failed("`mcp remove` needs a server name")
        }
        let path = try editTarget(options: options, environment: environment, cwd: cwd)

        guard var root = loadForEdit(at: path) else {
            throw CLIApplicationError.failed("no MCP server named '\(name)' in \(path.path)")
        }
        let removed: Bool
        do {
            removed = try removeMCPServer(name, from: &root)
            if removed { try writeConfigFile(root, to: path) }
        } catch {
            throw CLIApplicationError.failed("could not update \(path.path): \(error)")
        }
        guard removed else {
            throw CLIApplicationError.failed("no MCP server named '\(name)' in \(path.path)")
        }
        streams.out("Removed MCP server '\(name)' from \(path.path)\n")

        // A scoped delete can leave the name defined in another layer, where it
        // still resolves for sessions (upstream `mcp_cmd.rs:672-682`).
        if let survivors = try? loadDeclarations(environment: environment, cwd: cwd),
           let survivor = survivors.servers.first(where: { $0.name == name }) {
            streams.err(
                "note: '\(name)' is still defined in the \(survivor.scope ?? "merged") config\n"
            )
        }
    }

    static func runList(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams
    ) throws {
        let loaded = try loadDeclarations(environment: environment)

        if options.json {
            streams.out(jsonList(loaded) + "\n")
            return
        }

        if loaded.servers.isEmpty {
            streams.out("No MCP servers configured.\n")
        } else {
            for declaration in loaded.servers {
                let status = declaration.isEnabled ? "" : " (disabled)"
                let scope = declaration.scope.map { " (\($0))" } ?? ""
                streams.out("  \(declaration.name): \(declaration.transportSummary)\(status)\(scope)\n")
            }
        }
        for problem in loaded.problems {
            streams.err("  \(problem.server): unusable — \(problem.message)\n")
        }
    }

    static func runGet(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams
    ) throws {
        guard let name = options.target, !name.isEmpty else {
            throw CLIApplicationError.failed("`mcp get` needs a server name")
        }
        let loaded = try loadDeclarations(environment: environment)

        guard let declaration = loaded.servers.first(where: { $0.name == name }) else {
            if let problem = loaded.problems.first(where: { $0.server == name }) {
                throw CLIApplicationError.failed(
                    "MCP server '\(name)' is configured but unusable: \(problem.message)"
                )
            }
            let known = loaded.servers.map(\.name).sorted()
            throw CLIApplicationError.failed(
                known.isEmpty
                    ? "no MCP server named '\(name)' (none are configured)"
                    : "no MCP server named '\(name)' (configured: \(known.joined(separator: ", ")))"
            )
        }

        if options.json {
            streams.out(jsonServer(declaration) + "\n")
            return
        }
        streams.out("\(declaration.name)\n")
        streams.out("  transport: \(declaration.transportSummary)\n")
        streams.out("  enabled: \(declaration.isEnabled)\n")
        if let scope = declaration.scope {
            streams.out("  scope: \(scope)\n")
        }
        if let timeout = declaration.config.toolTimeoutSec {
            streams.out("  tool_timeout_sec: \(timeout)\n")
        }
        if let timeout = declaration.config.startupTimeoutSec {
            streams.out("  startup_timeout_sec: \(timeout)\n")
        }
    }

    // MARK: Loading

    /// Merge the user and project layers, tagging each server with its scope so
    /// `list` can show where a declaration came from. Project wins on a name
    /// collision, matching config layering.
    static func loadDeclarations(
        environment: [String: String],
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> MCPConfigLoadResult {
        var servers: [MCPServerDeclaration] = []
        var problems: [MCPConfigProblem] = []

        for (scope, document) in try configLayers(environment: environment, cwd: cwd) {
            let loaded = MCPConfigLoader.load(from: document, scope: scope)
            for declaration in loaded.servers {
                servers.removeAll { $0.name == declaration.name }
                servers.append(declaration)
            }
            problems.append(contentsOf: loaded.problems)
        }
        return MCPConfigLoadResult(servers: servers, problems: problems)
    }

    private static func configLayers(
        environment: [String: String],
        cwd: URL
    ) throws -> [(String, TOMLValue)] {
        var layers: [(String, TOMLValue)] = []
        if let user = try? loadFromDisk(environment: environment) {
            layers.append(("user", user))
        }
        if let project = try? loadProjectConfig(cwd: cwd) {
            layers.append(("project", project))
        }
        return layers
    }

    // MARK: JSON rendering

    static func jsonList(_ loaded: MCPConfigLoadResult) -> String {
        let servers = loaded.servers.map(serverObject)
        let problems = loaded.problems.map { problem in
            ["server": problem.server, "error": problem.message]
        }
        return encode(["servers": servers, "problems": problems])
    }

    static func jsonServer(_ declaration: MCPServerDeclaration) -> String {
        encode(serverObject(declaration))
    }

    private static func serverObject(_ declaration: MCPServerDeclaration) -> [String: Any] {
        var object: [String: Any] = [
            "name": declaration.name,
            "enabled": declaration.isEnabled,
            "transport": declaration.transportSummary,
        ]
        if let scope = declaration.scope { object["scope"] = scope }
        switch declaration.config.transport {
        case .stdio(let command, let args, _, let cwd):
            object["type"] = "stdio"
            object["command"] = command
            object["args"] = args
            if let cwd { object["cwd"] = cwd }
        case .streamableHttp(let url, let transportType, _, _, _, _, _):
            object["type"] = transportType ?? "http"
            object["url"] = url
        }
        return object
    }

    private static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
