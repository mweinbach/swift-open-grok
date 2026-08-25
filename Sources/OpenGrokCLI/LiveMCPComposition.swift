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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenGrokACPRuntime
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokComputerHubMCPAdapter
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspace

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
        var icons: [String: [MCPIcon]] = [:]
        var cursor: String?
        var visitedCursors = Set<String>()
        repeat {
            let page = try await client.listTools(MCPListToolsParams(cursor: cursor))
            for tool in page.tools where !tool.icons.isEmpty {
                icons[tool.name] = tool.icons
            }
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
        await client.replaceToolIcons(icons)
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
        var icons: [String: [MCPIcon]] = [:]
        var cursor: String?
        var visitedCursors = Set<String>()
        repeat {
            let page = try await client.listTools(MCPListToolsParams(cursor: cursor))
            for tool in page.tools where !tool.icons.isEmpty {
                icons[tool.name] = tool.icons
            }
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
        await client.replaceToolIcons(icons)
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

    public func callBridgedTool(
        name: String,
        arguments: JSONValue,
        onProgress: @escaping ToolProgressHandler
    ) async throws -> MCPBridgedCallResult {
        let result = try await client.callTool(
            MCPCallToolParams(name: name, arguments: arguments),
            onProgress: { update in
                if let message = update.message, !message.isEmpty {
                    await onProgress(.text(text: message))
                } else {
                    var fields: [String: JSONValue] = [
                        "progress": .number(.double(update.progress))
                    ]
                    if let total = update.total {
                        fields["total"] = .number(.double(total))
                    }
                    await onProgress(.custom(subkind: "mcp_progress", payload: .object(fields)))
                }
            }
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
    public static let actions: Set<String> = [
        "list", "get", "add", "remove", "enable", "disable", "doctor", "login",
    ]

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
        makeHTTPTransport: @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() },
        managedMCPPolicy: ManagedMCPPolicy? = nil
    ) async -> [MCPServerConnection] {
        guard let document else { return [] }
        let preferences = userGrokHome(environment: environment).map {
            MCPSetupPreferencesStore.load(home: $0).file
        }
        let loaded = MCPConfigLoader.load(from: document, preferences: preferences)

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
                disabledToolNames: disabledToolsByServer[declaration.name] ?? [],
                managedMCPPolicy: managedMCPPolicy
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
        makeHTTPTransport: @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() },
        managedMCPPolicy: ManagedMCPPolicy? = nil
    ) async -> [HubMCPClientEntry] {
        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL
        let security = LiveSecurityContext.resolve(
            workspaceRoot: cwdURL,
            environment: environment,
            isInteractive: false
        )
        let preferences = userGrokHome(environment: environment).map {
            MCPSetupPreferencesStore.load(home: $0).file
        }
        let loaded = MCPConfigLoader.load(from: security.document, preferences: preferences)
        let disabledServers = disabledMCPServers(in: security.document)

        var entries: [HubMCPClientEntry] = []
        for declaration in loaded.enabledServers {
            if disabledServers.contains(declaration.name) {
                continue
            }
            if let entry = await connectClientForHub(
                declaration: declaration,
                connections: connections,
                environment: environment,
                makeHTTPTransport: makeHTTPTransport,
                managedMCPPolicy: managedMCPPolicy ?? security.managedMCPPolicy
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
        makeHTTPTransport: @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() },
        managedMCPPolicy: ManagedMCPPolicy? = nil
    ) async -> HubMCPClientEntry? {
        let policy = managedMCPPolicy ?? LiveSecurityContext.currentManagedMCPPolicy()
        let identity = ManagedMCPServerIdentity(
            name: declaration.name,
            transport: declaration.config.transport
        )
        guard policy.isServerAllowed(identity) else { return nil }

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
        disabledToolNames: Set<String> = [],
        managedMCPPolicy: ManagedMCPPolicy? = nil
    ) async -> MCPServerConnection {
        let policy = managedMCPPolicy ?? LiveSecurityContext.currentManagedMCPPolicy()
        let identity = ManagedMCPServerIdentity(
            name: declaration.name,
            transport: declaration.config.transport
        )
        guard policy.isServerAllowed(identity) else {
            return MCPServerConnection(
                name: declaration.name,
                failure: policy.blockReason(for: identity)
                    ?? "MCP server '\(declaration.name)' is blocked by managed policy"
            )
        }

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
        case "enable":
            try runSetEnabled(
                options: options, enabled: true, environment: environment, streams: streams
            )
        case "disable":
            try runSetEnabled(
                options: options, enabled: false, environment: environment, streams: streams
            )
        case "doctor":
            try runDoctor(options: options, environment: environment, streams: streams)
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
        let loaded = try loadDeclarations(
            environment: environment,
            cwd: workingDirectory(options: options, fallback: cwd),
            options: options
        )
        guard let declaration = loaded.servers.first(where: { $0.name == name }) else {
            let known = loaded.servers.map(\.name).sorted()
            throw CLIApplicationError.failed(
                known.isEmpty
                    ? "no MCP server named '\(name)' (none are configured)"
                    : "no MCP server named '\(name)' (configured: \(known.joined(separator: ", ")))"
            )
        }
        let managedPolicy = LiveSecurityContext.currentManagedMCPPolicy()
        let managedIdentity = ManagedMCPServerIdentity(
            name: declaration.name,
            transport: declaration.config.transport
        )
        if let reason = managedPolicy.blockReason(for: managedIdentity) {
            throw CLIApplicationError.failed(
                "MCP server '\(name)' blocked by managed policy: \(reason)"
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

    /// Resolve the session cwd instead of silently falling back to the host
    /// process cwd when a root-level `--cwd` was supplied.
    static func workingDirectory(options: CLIResourceOptions, fallback: URL) -> URL {
        guard let supplied = options.common.cwd, !supplied.isEmpty else {
            return fallback.standardizedFileURL
        }
        return URL(fileURLWithPath: supplied, relativeTo: fallback).standardizedFileURL
    }

    private static func scope(options: CLIResourceOptions) throws -> String? {
        guard let value = options.options["--scope"] else { return nil }
        guard value == "user" || value == "project" else {
            throw CLIApplicationError.failed(
                "invalid MCP config scope '\(value)' (expected: user or project)"
            )
        }
        return value
    }

    /// Project MCP config is executable configuration. Merely creating the
    /// first project file cannot grant itself folder trust: otherwise the
    /// write succeeds but the next process correctly refuses to load it.
    private static func requireTrustedProject(
        cwd: URL,
        environment: [String: String],
        permissions: CLIPermissionOptions
    ) throws {
        let security = LiveSecurityContext.resolve(
            workspaceRoot: cwd,
            environment: environment,
            isInteractive: false,
            cli: permissions
        )
        guard security.projectTrusted else {
            throw CLIApplicationError.failed(
                "project-scoped MCP configuration requires a trusted folder; "
                    + "trust '\(cwd.path)' before reading or modifying .opengrok/config.toml"
            )
        }

        if folderTrustEnabled(document: security.document, environment: environment) {
            let identity = LiveWorkspaceTrustIdentity.resolve(
                workingDirectory: cwd, environment: environment
            )
            guard PersistentFolderTrustStore(environment: environment).isTrusted(identity) else {
                throw CLIApplicationError.failed(
                    "project-scoped MCP configuration requires persisted folder trust; "
                        + "rerun with --trust before the mcp subcommand"
                )
            }
        }
    }

    /// The exact user/project file selected by `--scope`; `--config` remains
    /// the port's backwards-compatible explicit-file escape hatch.
    static func editTarget(
        options: CLIResourceOptions,
        environment: [String: String],
        cwd: URL
    ) throws -> URL {
        let effectiveCWD = workingDirectory(options: options, fallback: cwd)
        let requestedScope = try scope(options: options)
        if let explicit = options.options["--config"], !explicit.isEmpty {
            guard requestedScope == nil else {
                throw CLIApplicationError.failed(
                    "--config and --scope select different configuration authorities; use only one"
                )
            }
            let path = URL(fileURLWithPath: explicit, relativeTo: effectiveCWD)
                .standardizedFileURL
            if sameConfigPath(path, projectConfigPath(cwd: effectiveCWD)) {
                try requireTrustedProject(
                    cwd: effectiveCWD,
                    environment: environment,
                    permissions: options.common.permissions
                )
            }
            return path
        }

        if requestedScope == "project" {
            try requireTrustedProject(
                cwd: effectiveCWD,
                environment: environment,
                permissions: options.common.permissions
            )
            let path = projectConfigPath(cwd: effectiveCWD).standardizedFileURL
            let canonicalWorkspace = effectiveCWD.resolvingSymlinksInPath()
                .standardizedFileURL.path
            let canonicalParent = path.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalParent.hasPrefix(canonicalWorkspace + "/") else {
                throw CLIApplicationError.failed(
                    "project MCP config directory resolves outside its trusted workspace"
                )
            }
            return path
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
    /// Compatibility inspection seam used by ACP callers. CLI mutations use
    /// `loadForMutation` instead so corrupt existing config never becomes an
    /// empty replacement document.
    static func loadForEdit(at path: URL) -> TOMLValue? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        return (try? parseTOML(text)) ?? .table(TOMLTable())
    }

    /// Unlike the legacy inspection helper, mutations never replace a corrupt
    /// or unreadable existing owner configuration with an empty document.
    private static func loadForMutation(at path: URL) throws -> TOMLValue? {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil {
            throw CLIApplicationError.failed("refusing to edit a symlinked MCP config file")
        }
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        do {
            let text = try String(contentsOf: path, encoding: .utf8)
            return try parseTOML(text)
        } catch {
            throw CLIApplicationError.failed(
                "cannot safely edit unreadable or invalid MCP config at \(path.path): \(error)"
            )
        }
    }

    /// Environment variables and Authorization headers are credentials. Use
    /// the no-follow, durable owner-only writer instead of the generic TOML
    /// writer, whose temporary file inherits the process umask.
    static func writePrivateConfigFile(_ root: TOMLValue, to path: URL) throws {
        guard root.isTable else { throw TOMLWriteError.rootIsNotATable }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AtomicFile.write(path, contents: TOMLEncoder.encode(root), options: .ownerOnly)
        try SecureFile.ensureOwnerOnlyPermissions(at: path)
    }

    private static func sameConfigPath(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath().path
            == second.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A `KEY=VALUE` positional, per upstream's `looks_like_env_pair`
    /// (`mcp_cmd.rs:458`): a non-empty name before the first `=`.
    static func envPair(_ token: String) -> (String, String)? {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
            return nil
        }
        return (String(token[..<separator]), String(token[token.index(after: separator)...]))
    }

    private static func validateServerName(_ name: String) throws {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "-" || scalar == "_"
                  )
              })
        else {
            throw CLIApplicationError.failed(
                "invalid MCP server name; use only ASCII letters, numbers, hyphens, and underscores"
            )
        }
    }

    private static func validatedEnvironment(
        _ entries: [String]
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        for entry in entries {
            guard let (key, value) = envPair(entry),
                  let first = key.unicodeScalars.first,
                  first.isASCII,
                  CharacterSet.letters.contains(first) || first == "_",
                  key.unicodeScalars.dropFirst().allSatisfy({ scalar in
                      scalar.isASCII && (
                          CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
                      )
                  }),
                  !value.unicodeScalars.contains(where: { $0.value == 0 })
            else {
                throw CLIApplicationError.failed(
                    "invalid environment variable; pass each value as -e KEY=value "
                        + "with an ASCII variable name"
                )
            }
            values[key] = value
        }
        return values
    }

    private static func validatedHeaders(_ entries: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        var names: Set<String> = []
        let punctuation = "!#$%&'*+-.^_`|~"
        for entry in entries {
            guard let separator = entry.firstIndex(of: ":") else {
                throw CLIApplicationError.failed(
                    "invalid HTTP header; expected -H 'Name: value'"
                )
            }
            let name = entry[..<separator].trimmingCharacters(in: .whitespaces)
            let value = entry[entry.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ scalar in
                      scalar.isASCII && (
                          CharacterSet.alphanumerics.contains(scalar)
                              || punctuation.unicodeScalars.contains(scalar)
                      )
                  }),
                  !value.unicodeScalars.contains(where: { scalar in
                      scalar.value == 0 || scalar.value == 10 || scalar.value == 13
                  })
            else {
                throw CLIApplicationError.failed(
                    "invalid HTTP header name or value; control characters are not permitted"
                )
            }
            guard names.insert(name.lowercased()).inserted else {
                throw CLIApplicationError.failed("duplicate HTTP header '\(name)'")
            }
            values[name] = value
        }
        return values
    }

    private static func validatedEndpoint(_ raw: String) throws -> URL {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url
        else {
            throw CLIApplicationError.failed(
                "invalid MCP server URL; use an http:// or https:// endpoint "
                    + "without embedded credentials"
            )
        }
        return url
    }

    /// Upstream `mcp_cmd.rs:275-398`: transport chooses the positional source;
    /// repeated environment/header options cannot silently cross transports.
    static func resolveAdd(options: CLIResourceOptions) throws -> McpServerConfig {
        if let name = options.target { try validateServerName(name) }

        let suppliedTransport = options.options["--transport"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let suppliedTransport,
           !["stdio", "http", "sse"].contains(suppliedTransport) {
            throw CLIApplicationError.failed(
                "invalid MCP transport '\(suppliedTransport)' (expected: stdio, http, or sse)"
            )
        }

        let legacyURL = options.options["--url"]
        let legacyCommand = options.options["--command"]
        let legacySource = options.options["--source"]
        let legacyType = options.options["--type"]?.lowercased()
        let legacyArguments = options.repeatedOptions["--args"] ?? []

        if legacyType != nil && legacyURL == nil {
            throw CLIApplicationError.failed(
                "--type is valid only together with --url; use --transport instead"
            )
        }
        if let legacyType, !["http", "sse"].contains(legacyType) {
            throw CLIApplicationError.failed("invalid legacy MCP transport type '\(legacyType)'")
        }
        if !legacyArguments.isEmpty && legacyCommand == nil {
            throw CLIApplicationError.failed("--args requires --command")
        }

        let namedSources = [legacyURL, legacyCommand, legacySource].compactMap { $0 }
        if namedSources.count > 1 || (!namedSources.isEmpty && !options.values.isEmpty) {
            throw CLIApplicationError.failed(
                "choose exactly one MCP server source: a positional command/URL, --command, or --url"
            )
        }

        let transport = suppliedTransport
            ?? (legacyURL != nil ? (legacyType == "sse" ? "sse" : "http") : "stdio")
        if legacyURL != nil && transport == "stdio" {
            throw CLIApplicationError.failed("--url cannot be combined with --transport stdio")
        }

        let source = namedSources.first ?? options.values.first
        guard let source, !source.isEmpty else {
            throw CLIApplicationError.failed(
                """
                `mcp add` needs a transport: pass a command (\
                `open-grok mcp add NAME -- npx server`) or a URL (\
                `open-grok mcp add --transport http NAME https://example.com/mcp`).
                """
            )
        }

        let arguments = legacyCommand == nil
            ? Array(options.values.dropFirst())
            : legacyArguments
        let environment = options.repeatedOptions["--env"] ?? []
        let headers = options.repeatedOptions["--header"] ?? []

        if transport == "stdio" {
            guard headers.isEmpty else {
                throw CLIApplicationError.failed(
                    "--header can only be used with HTTP or SSE servers"
                )
            }
            if envPair(source) != nil {
                throw CLIApplicationError.failed(
                    "the server command looks like an environment variable; "
                        + "pass each variable separately as -e KEY=value"
                )
            }
            let values = try validatedEnvironment(environment)
            return McpServerConfig(
                transport: .stdio(
                    command: source,
                    args: arguments,
                    env: values.isEmpty ? nil : values,
                    cwd: nil
                )
            )
        }

        guard arguments.isEmpty else {
            throw CLIApplicationError.failed("HTTP and SSE MCP servers accept exactly one URL")
        }
        guard environment.isEmpty else {
            throw CLIApplicationError.failed("--env can only be used with stdio servers")
        }
        let endpoint = try validatedEndpoint(source)
        let values = try validatedHeaders(headers)
        return McpServerConfig(
            transport: .streamableHttp(
                url: endpoint.absoluteString,
                transportType: transport == "sse" ? "sse" : nil,
                bearerTokenEnvVar: nil,
                headers: values.isEmpty ? nil : values,
                oauthClientId: nil,
                oauthClientSecretEnvVar: nil,
                oauthScopes: nil
            )
        )
    }

    static func runAdd(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        managedMCPPolicy: ManagedMCPPolicy? = nil
    ) throws {
        guard let name = options.target, !name.isEmpty else {
            throw CLIApplicationError.failed("`mcp add` needs a server name")
        }
        try validateServerName(name)
        let path = try editTarget(options: options, environment: environment, cwd: cwd)
        let config = try resolveAdd(options: options)

        let policy = managedMCPPolicy ?? LiveSecurityContext.currentManagedMCPPolicy()
        let identity = ManagedMCPServerIdentity(name: name, transport: config.transport)
        if let reason = policy.blockReason(for: identity) {
            throw CLIApplicationError.failed(
                "MCP server '\(name)' is blocked by managed policy: \(reason)"
            )
        }

        var root = try loadForMutation(at: path) ?? .table(TOMLTable())
        let replacing = mcpServerIsDefined(name, in: root)
        if replacing && !options.force {
            throw CLIApplicationError.failed(
                "MCP server '\(name)' already exists in \(path.path); pass --force to replace it"
            )
        }
        do {
            try upsertMCPServer(name, config: config, in: &root)
            try writePrivateConfigFile(root, to: path)
        } catch {
            throw CLIApplicationError.failed(
                "could not update \(path.path): \(error)"
            )
        }
        streams.out(
            "\(replacing ? "Replaced" : "Added") MCP server '\(name)' in \(path.path)\n"
        )
        if options.options["--transport"] == nil,
           options.options["--url"] == nil,
           case .stdio(let command, _, _, _) = config.transport,
           command.hasPrefix("http://") || command.hasPrefix("https://")
                || command.hasPrefix("localhost") {
            let endpoint = command.hasPrefix("http://") || command.hasPrefix("https://")
                ? command
                : "http://\(command)"
            streams.err(
                "warning: '\(redactedEndpoint(endpoint))' looks like a URL but was added as "
                    + "a stdio command; use --transport http for a remote MCP server\n"
            )
        }
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
        let effectiveCWD = workingDirectory(options: options, fallback: cwd)
        let path = try removalTarget(
            name: name, options: options, environment: environment, cwd: effectiveCWD
        )

        guard var root = try loadForMutation(at: path) else {
            throw CLIApplicationError.failed("no MCP server named '\(name)' in \(path.path)")
        }
        let removed: Bool
        do {
            removed = try removeMCPServer(name, from: &root)
            if removed { try writePrivateConfigFile(root, to: path) }
        } catch {
            throw CLIApplicationError.failed("could not update \(path.path): \(error)")
        }
        guard removed else {
            throw CLIApplicationError.failed("no MCP server named '\(name)' in \(path.path)")
        }
        streams.out("Removed MCP server '\(name)' from \(path.path)\n")

        // A scoped delete can leave the name defined in another layer, where it
        // still resolves for sessions (upstream `mcp_cmd.rs:672-682`).
        if let survivors = try? loadDeclarations(environment: environment, cwd: effectiveCWD),
           let survivor = survivors.servers.first(where: { $0.name == name }) {
            streams.err(
                "note: '\(name)' is still defined in the \(survivor.scope ?? "merged") config\n"
            )
        }
    }

    private static func removalTarget(
        name: String,
        options: CLIResourceOptions,
        environment: [String: String],
        cwd: URL
    ) throws -> URL {
        if options.options["--config"] != nil {
            return try editTarget(options: options, environment: environment, cwd: cwd)
        }
        if try scope(options: options) != nil {
            return try editTarget(options: options, environment: environment, cwd: cwd)
        }

        let userPath = try editTarget(options: options, environment: environment, cwd: cwd)
        let userDefined = (try loadForMutation(at: userPath)).map {
            mcpServerIsDefined(name, in: $0)
        } ?? false

        let security = LiveSecurityContext.resolve(
            workspaceRoot: cwd,
            environment: environment,
            isInteractive: false,
            cli: options.common.permissions
        )
        let projectPath = projectConfigPath(cwd: cwd)
        let projectDefined: Bool
        if security.projectTrusted,
           let project = try loadForMutation(at: projectPath) {
            projectDefined = mcpServerIsDefined(name, in: project)
        } else {
            projectDefined = false
        }

        if userDefined && projectDefined {
            throw CLIApplicationError.failed(
                "MCP server '\(name)' exists in both user and project config; "
                    + "specify --scope user or --scope project"
            )
        }
        if projectDefined {
            var projectOptions = options
            projectOptions.options["--scope"] = "project"
            return try editTarget(options: projectOptions, environment: environment, cwd: cwd)
        }
        return userPath
    }

    /// Disable is always personal: shared project declarations stay untouched.
    /// Enabling clears both the user's disabled list and a trusted project's
    /// sticky `enabled = false`, matching `mcp.rs:678-708`.
    static func runSetEnabled(
        options: CLIResourceOptions,
        enabled: Bool,
        environment: [String: String],
        streams: CLIStreams,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        managedMCPPolicy: ManagedMCPPolicy? = nil
    ) throws {
        guard let name = options.target, !name.isEmpty else {
            throw CLIApplicationError.failed(
                "`mcp \(enabled ? "enable" : "disable")` needs a server name"
            )
        }
        guard !name.contains(":") else {
            throw CLIApplicationError.failed(
                "gateway MCP connectors cannot be toggled through the CLI"
            )
        }
        if try scope(options: options) == "project" {
            throw CLIApplicationError.failed(
                "MCP enable/disable preferences are user-scoped and never disable a shared project"
            )
        }

        let effectiveCWD = workingDirectory(options: options, fallback: cwd)
        let loaded = try loadDeclarations(
            environment: environment, cwd: effectiveCWD, options: options
        )
        let declaration = loaded.servers.first { $0.name == name }
            ?? loaded.setupServers.first { $0.name == name }
        guard let declaration else {
            let known = Set(loaded.servers.map(\.name) + loaded.setupServers.map(\.name))
                .sorted()
            let action = enabled ? "enable" : "disable"
            throw CLIApplicationError.failed(
                known.isEmpty
                    ? "cannot \(action) MCP server '\(name)': no MCP servers are configured"
                    : "cannot \(action) MCP server '\(name)': configured servers are "
                        + known.joined(separator: ", ")
            )
        }

        if enabled {
            let policy = managedMCPPolicy ?? LiveSecurityContext.currentManagedMCPPolicy()
            let identity = ManagedMCPServerIdentity(
                name: name, transport: declaration.config.transport
            )
            if let reason = policy.blockReason(for: identity) {
                throw CLIApplicationError.failed(
                    "MCP server '\(name)' is blocked by managed policy: \(reason)"
                )
            }
        }

        var userOptions = options
        userOptions.options.removeValue(forKey: "--scope")
        let userPath = try editTarget(
            options: userOptions, environment: environment, cwd: effectiveCWD
        )
        let previousUser = try loadForMutation(at: userPath)
        var userRoot = previousUser ?? .table(TOMLTable())
        try applyMCPServerEnabled(name, enabled: enabled, in: &userRoot)
        let userChanged = TOMLEncoder.encode(userRoot)
            != TOMLEncoder.encode(previousUser ?? .table(TOMLTable()))
        if userChanged {
            try writePrivateConfigFile(userRoot, to: userPath)
        }

        if enabled,
           options.options["--config"] == nil,
           declaration.scope == "project" {
            do {
                let projectPath = projectConfigPath(cwd: effectiveCWD)
                if var projectRoot = try loadForMutation(at: projectPath),
                   mcpServerIsDefined(name, in: projectRoot) {
                    let previous = TOMLEncoder.encode(projectRoot)
                    try applyMCPServerEnabled(name, enabled: true, in: &projectRoot)
                    if TOMLEncoder.encode(projectRoot) != previous {
                        try requireTrustedProject(
                            cwd: effectiveCWD,
                            environment: environment,
                            permissions: options.common.permissions
                        )
                        try writePrivateConfigFile(projectRoot, to: projectPath)
                    }
                }
            } catch {
                if userChanged {
                    if let previousUser {
                        try? writePrivateConfigFile(previousUser, to: userPath)
                    } else {
                        try? FileManager.default.removeItem(at: userPath)
                    }
                }
                throw CLIApplicationError.failed(
                    "could not enable MCP server '\(name)' without modifying trusted project config: \(error)"
                )
            }
        }

        let refreshed = try loadDeclarations(
            environment: environment, cwd: effectiveCWD, options: options
        )
        let actual = refreshed.servers.first { $0.name == name }
            ?? refreshed.setupServers.first { $0.name == name }
        guard actual?.isEnabled == enabled else {
            throw CLIApplicationError.failed(
                "MCP server '\(name)' remains \(enabled ? "disabled" : "enabled") after updating its configuration"
            )
        }
        streams.out("\(enabled ? "Enabled" : "Disabled") MCP server '\(name)'.\n")
    }

    static func runList(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams
    ) throws {
        let cwd = workingDirectory(
            options: options,
            fallback: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let loaded = try loadDeclarations(environment: environment, cwd: cwd, options: options)

        if options.json {
            streams.out(jsonList(loaded) + "\n")
            return
        }

        if loaded.servers.isEmpty && loaded.setupRequiredServers.isEmpty {
            streams.out("No MCP servers configured.\n")
        } else {
            for declaration in loaded.servers {
                let status = declaration.isEnabled ? "" : " (disabled)"
                let scope = declaration.scope.map { " (\($0))" } ?? ""
                streams.out("  \(declaration.name): \(declaration.transportSummary)\(status)\(scope)\n")
            }
            for declaration in loaded.setupRequiredServers {
                let scope = declaration.scope.map { " (\($0))" } ?? ""
                streams.out("  \(declaration.name): setup required\(scope)\n")
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
        let cwd = workingDirectory(
            options: options,
            fallback: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let loaded = try loadDeclarations(environment: environment, cwd: cwd, options: options)

        guard let declaration = loaded.servers.first(where: { $0.name == name }) else {
            if loaded.setupRequiredServers.contains(where: { $0.name == name }) {
                throw CLIApplicationError.failed(
                    "MCP server '\(name)' requires setup before its transport can be used"
                )
            }
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

    // MARK: Doctor

    private struct DoctorCheck {
        let label: String
        let passed: Bool
        let detail: String
        let hint: String?

        var object: [String: Any] {
            var result: [String: Any] = [
                "label": label,
                "passed": passed,
                "detail": detail,
            ]
            if let hint { result["hint"] = hint }
            return result
        }
    }

    /// A HEAD probe observes HTTP reachability without starting stdio commands
    /// or forwarding configured Authorization headers/environment secrets.
    private final class DoctorHTTPProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var statusCode: Int?
        private var failure: String?

        func complete(response: URLResponse?, error: (any Error)?) {
            lock.lock()
            statusCode = (response as? HTTPURLResponse)?.statusCode
            if let error {
                if let network = error as? URLError {
                    failure = "network probe failed (code \(network.code.rawValue))"
                } else {
                    failure = "network probe failed before an HTTP response arrived"
                }
            }
            lock.unlock()
        }

        var snapshot: (statusCode: Int?, failure: String?) {
            lock.lock()
            defer { lock.unlock() }
            return (statusCode, failure)
        }
    }

    static func runDoctor(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        managedMCPPolicy: ManagedMCPPolicy? = nil
    ) throws {
        let effectiveCWD = workingDirectory(options: options, fallback: cwd)
        let loaded = try loadDeclarations(
            environment: environment, cwd: effectiveCWD, options: options
        )
        let setupRequired = Set(loaded.setupRequiredServers.map(\.name))
        let allDeclarations = loaded.servers + loaded.setupRequiredServers
        let allNames = Set(
            allDeclarations.map(\.name) + loaded.problems.map(\.server)
        ).sorted()

        if let name = options.target, !allNames.contains(name) {
            throw CLIApplicationError.failed(
                allNames.isEmpty
                    ? "MCP server '\(name)' not found; no servers are configured"
                    : "MCP server '\(name)' not found; available servers: \(allNames.joined(separator: ", "))"
            )
        }

        let policy = managedMCPPolicy ?? LiveSecurityContext.currentManagedMCPPolicy()
        var servers: [[String: Any]] = []

        for declaration in allDeclarations.sorted(by: { $0.name < $1.name }) {
            if let filter = options.target, declaration.name != filter { continue }
            var checks: [DoctorCheck] = []
            let identity = ManagedMCPServerIdentity(
                name: declaration.name,
                transport: declaration.config.transport
            )
            if let reason = policy.blockReason(for: identity) {
                checks.append(DoctorCheck(
                    label: "blocked by organization policy",
                    passed: false,
                    detail: reason,
                    hint: "ask your administrator to authorize this MCP server"
                ))
            } else if !declaration.isEnabled {
                checks.append(DoctorCheck(
                    label: "disabled in config",
                    passed: false,
                    detail: "server is disabled in owner or project configuration",
                    hint: "run open-grok mcp enable \(declaration.name)"
                ))
            } else if setupRequired.contains(declaration.name) {
                checks.append(DoctorCheck(
                    label: "setup required",
                    passed: false,
                    detail: "server configuration must be completed before it can connect",
                    hint: "complete the server's MCP setup"
                ))
            } else {
                checks.append(doctorTransportCheck(
                    declaration: declaration,
                    cwd: effectiveCWD,
                    environment: environment
                ))
            }

            let transport: String
            let target: String
            switch declaration.config.transport {
            case .stdio(let command, _, _, _):
                transport = "stdio"
                target = command
            case .streamableHttp(let url, let type, _, _, _, _, _):
                transport = type ?? "http"
                target = redactedEndpoint(url)
            }

            servers.append([
                "name": declaration.name,
                "transport": transport,
                "target": target,
                "source": declaration.scope ?? "user",
                "checks": checks.map(\.object),
                "healthy": checks.allSatisfy(\.passed),
            ])
        }

        for problem in loaded.problems.sorted(by: { $0.server < $1.server }) {
            if let filter = options.target, problem.server != filter { continue }
            servers.append([
                "name": problem.server,
                "transport": "unknown",
                "target": "",
                "source": "config",
                "checks": [DoctorCheck(
                    label: "valid configuration",
                    passed: false,
                    detail: problem.message,
                    hint: "repair the server's MCP configuration"
                ).object],
                "healthy": false,
            ])
        }

        let healthyCount = servers.filter { $0["healthy"] as? Bool == true }.count
        let failingCount = servers.count - healthyCount
        let report: [String: Any] = [
            "sources": try doctorSources(
                options: options,
                loaded: loaded,
                environment: environment,
                cwd: effectiveCWD
            ),
            "servers": servers,
            "healthy_count": healthyCount,
            "failing_count": failingCount,
        ]

        if options.json {
            streams.out(encode(report) + "\n")
        } else if servers.isEmpty {
            streams.out("No MCP servers configured.\n")
        } else {
            for server in servers {
                let healthy = server["healthy"] as? Bool == true
                let name = server["name"] as? String ?? "unknown"
                streams.out("\(healthy ? "✓" : "✗") \(name)\n")
                for check in server["checks"] as? [[String: Any]] ?? [] {
                    let passed = check["passed"] as? Bool == true
                    let label = check["label"] as? String ?? "check"
                    let detail = check["detail"] as? String ?? ""
                    streams.out("  \(passed ? "✓" : "✗") \(label): \(detail)\n")
                    if let hint = check["hint"] as? String {
                        streams.out("    hint: \(hint)\n")
                    }
                }
            }
            streams.out("\(healthyCount) healthy, \(failingCount) failing\n")
        }

        if failingCount > 0 {
            throw CLIApplicationError.failed(
                "\(failingCount) MCP server\(failingCount == 1 ? "" : "s") failed diagnostic checks"
            )
        }
    }

    private static func doctorSources(
        options: CLIResourceOptions,
        loaded: MCPConfigLoadResult,
        environment: [String: String],
        cwd: URL
    ) throws -> [[String: Any]] {
        let declarations = loaded.servers + loaded.setupRequiredServers
        if options.options["--config"] != nil {
            let path = try editTarget(options: options, environment: environment, cwd: cwd)
            let found = FileManager.default.fileExists(atPath: path.path)
            var source: [String: Any] = [
                "path": path.path,
                "status": found ? "found" : "not_found",
            ]
            if found { source["server_count"] = declarations.count }
            return [source]
        }

        var sources: [[String: Any]] = []
        if let home = userGrokHome(environment: environment) {
            let path = home.appendingPathComponent("config.toml")
            let found = FileManager.default.fileExists(atPath: path.path)
            var source: [String: Any] = [
                "path": path.path,
                "status": found ? "found" : "not_found",
            ]
            if found {
                source["server_count"] = declarations.filter { $0.scope == "user" }.count
            }
            sources.append(source)
        }

        let project = projectConfigPath(cwd: cwd)
        if FileManager.default.fileExists(atPath: project.path) {
            let security = LiveSecurityContext.resolve(
                workspaceRoot: cwd,
                environment: environment,
                isInteractive: false,
                cli: options.common.permissions
            )
            if security.projectTrusted {
                sources.append([
                    "path": project.path,
                    "status": "found",
                    "server_count": declarations.filter { $0.scope == "project" }.count,
                ])
            } else {
                sources.append([
                    "path": project.path,
                    "status": "skipped",
                    "reason": "project folder is not trusted",
                ])
            }
        }
        return sources
    }

    private static func doctorTransportCheck(
        declaration: MCPServerDeclaration,
        cwd: URL,
        environment: [String: String]
    ) -> DoctorCheck {
        switch declaration.config.transport {
        case .stdio(let command, _, _, let serverCWD):
            let commandCWD = serverCWD.map {
                URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL
            } ?? cwd
            guard FileManager.default.fileExists(atPath: commandCWD.path) else {
                return DoctorCheck(
                    label: "working directory exists",
                    passed: false,
                    detail: "configured command working directory does not exist",
                    hint: "create the working directory or update the server config"
                )
            }
            guard let executable = executablePath(
                command, cwd: commandCWD, environment: environment
            ) else {
                return DoctorCheck(
                    label: "command available",
                    passed: false,
                    detail: "command '\(command)' is not executable or was not found in PATH",
                    hint: "install the command or provide its absolute executable path"
                )
            }
            return DoctorCheck(
                label: "command available",
                passed: true,
                detail: "executable exists at \(executable); no process was started",
                hint: nil
            )

        case .streamableHttp(let raw, _, _, _, _, _, _):
            let endpoint: URL
            do {
                endpoint = try validatedEndpoint(raw)
            } catch {
                return DoctorCheck(
                    label: "valid HTTP endpoint",
                    passed: false,
                    detail: "server URL is not a valid HTTP(S) endpoint",
                    hint: "configure a URL with an http:// or https:// scheme"
                )
            }
            let probe = probeEndpoint(endpoint)
            if let statusCode = probe.statusCode {
                return DoctorCheck(
                    label: "HTTP endpoint reachable",
                    passed: true,
                    detail: "server answered an unauthenticated HEAD request (HTTP \(statusCode))",
                    hint: nil
                )
            }
            return DoctorCheck(
                label: "HTTP endpoint reachable",
                passed: false,
                detail: probe.failure ?? "server did not answer within the diagnostic timeout",
                hint: "confirm the server is running and its URL is reachable"
            )
        }
    }

    private static func executablePath(
        _ command: String,
        cwd: URL,
        environment: [String: String]
    ) -> String? {
        let manager = FileManager.default
        if command.contains("/") || command.contains("\\") {
            let candidate = URL(fileURLWithPath: command, relativeTo: cwd).standardizedFileURL
            return manager.isExecutableFile(atPath: candidate.path) ? candidate.path : nil
        }

        #if os(Windows)
        let separator: Character = ";"
        let extensions = (environment["PATHEXT"] ?? ".COM;.EXE;.BAT;.CMD")
            .split(separator: ";").map(String.init)
        #else
        let separator: Character = ":"
        let extensions: [String] = [""]
        #endif

        for directory in (environment["PATH"] ?? "").split(separator: separator) {
            for suffix in extensions {
                let candidate = URL(fileURLWithPath: String(directory), relativeTo: cwd)
                    .appendingPathComponent(command + suffix)
                if manager.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
        }
        return nil
    }

    private static func probeEndpoint(_ endpoint: URL) -> (
        statusCode: Int?, failure: String?
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2
        let state = DoctorHTTPProbeState()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            state.complete(response: response, error: error)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return (nil, "server did not answer within the diagnostic timeout")
        }
        session.finishTasksAndInvalidate()
        return state.snapshot
    }

    private static func redactedEndpoint(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return "<invalid endpoint>" }
        components.user = nil
        components.password = nil
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                let sensitive = ["token", "key", "secret", "password", "auth", "signature"]
                    .contains { item.name.localizedCaseInsensitiveContains($0) }
                return sensitive ? URLQueryItem(name: item.name, value: "[REDACTED]") : item
            }
        }
        return components.string ?? "<invalid endpoint>"
    }

    // MARK: Loading

    /// Merge the user and project layers, tagging each server with its scope so
    /// `list` can show where a declaration came from. Project wins on a name
    /// collision, matching config layering.
    static func loadDeclarations(
        environment: [String: String],
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        options: CLIResourceOptions? = nil
    ) throws -> MCPConfigLoadResult {
        var servers: [MCPServerDeclaration] = []
        var setupServers: [MCPServerDeclaration] = []
        var problems: [MCPConfigProblem] = []
        var disabled: Set<String> = []
        let preferences = userGrokHome(environment: environment).map {
            MCPSetupPreferencesStore.load(home: $0).file
        }

        for (scope, document) in try configLayers(
            environment: environment, cwd: cwd, options: options
        ) {
            let loaded = MCPConfigLoader.load(
                from: document, scope: scope, preferences: preferences
            )
            disabled.formUnion(disabledMCPServers(in: document))
            let replaced = Set(loaded.servers.map(\.name) + loaded.setupServers.map(\.name))
            servers.removeAll { replaced.contains($0.name) }
            setupServers.removeAll { replaced.contains($0.name) }
            for declaration in loaded.servers {
                servers.append(declaration)
            }
            setupServers.append(contentsOf: loaded.setupServers)
            problems.append(contentsOf: loaded.problems)
        }
        for index in servers.indices where disabled.contains(servers[index].name) {
            servers[index].config.enabled = false
        }
        for index in setupServers.indices where disabled.contains(setupServers[index].name) {
            setupServers[index].config.enabled = false
        }
        return MCPConfigLoadResult(
            servers: servers, setupServers: setupServers, problems: problems
        )
    }

    private static func configLayers(
        environment: [String: String],
        cwd: URL,
        options: CLIResourceOptions? = nil
    ) throws -> [(String, TOMLValue)] {
        var layers: [(String, TOMLValue)] = []
        let requestedScope: String?
        if let options {
            requestedScope = try scope(options: options)
        } else {
            requestedScope = nil
        }

        if let options, options.options["--config"] != nil {
            let path = try editTarget(options: options, environment: environment, cwd: cwd)
            if let document = try loadForMutation(at: path) {
                let label = sameConfigPath(path, projectConfigPath(cwd: cwd)) ? "project" : "user"
                layers.append((label, document))
            }
            return layers
        }

        if requestedScope != "project", let user = try? loadFromDisk(environment: environment) {
            layers.append(("user", user))
        }

        guard requestedScope != "user" else { return layers }
        let permissions = options?.common.permissions ?? CLIPermissionOptions()
        let security = LiveSecurityContext.resolve(
            workspaceRoot: cwd,
            environment: environment,
            isInteractive: false,
            cli: permissions
        )
        if requestedScope == "project" {
            try requireTrustedProject(cwd: cwd, environment: environment, permissions: permissions)
        }
        if security.projectTrusted,
           let project = try? loadProjectConfig(cwd: cwd, environment: environment) {
            layers.append(("project", project))
        }
        return layers
    }

    // MARK: JSON rendering

    static func jsonList(_ loaded: MCPConfigLoadResult) -> String {
        var servers = loaded.servers.map(serverObject)
        for declaration in loaded.setupRequiredServers {
            var entry: [String: Any] = [
                "name": declaration.name,
                "enabled": declaration.isEnabled,
                "setup_required": true,
            ]
            if let scope = declaration.scope { entry["scope"] = scope }
            servers.append(entry)
        }
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
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
