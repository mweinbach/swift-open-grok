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
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolRegistry

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
        let result = try await client.listTools()
        return result.tools.map { tool in
            MCPBridgedTool(
                name: tool.name,
                description: tool.description ?? tool.title ?? "",
                inputSchema: tool.inputSchema,
                modelVisible: Self.isModelVisible(tool)
            )
        }
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

    public init() {}

    func retain(_ client: MCPClient, as name: String) {
        clients[name] = client
    }

    public func names() -> [String] { clients.keys.sorted() }

    /// Close every server. Safe to call more than once.
    public func shutdown() async {
        let open = clients
        clients.removeAll()
        for client in open.values {
            try? await client.shutdown()
            await client.close()
        }
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

    /// Subcommands this route accepts.
    public static let actions: Set<String> = ["list", "get", "add", "remove"]

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

        for declaration in loaded.enabledServers {
            results.append(await connect(
                declaration: declaration,
                toolset: toolset,
                connections: connections,
                environment: environment,
                makeHTTPTransport: makeHTTPTransport
            ))
        }
        return results
    }

    /// Connect a single declaration. Exposed so tests can drive one server.
    public static func connect(
        declaration: MCPServerDeclaration,
        toolset: FinalizedToolset,
        connections: MCPSessionConnections,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeHTTPTransport: @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() }
    ) async -> MCPServerConnection {
        let transport: any MCPTransport
        do {
            transport = try declaration.makeTransport(
                httpTransport: makeHTTPTransport(),
                environment: environment
            )
        } catch {
            return MCPServerConnection(name: declaration.name, failure: String(describing: error))
        }

        let client = MCPClient(transport: transport)
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
            into: toolset
        )
        if let failure = registration.failure {
            await client.close()
            return MCPServerConnection(name: declaration.name, failure: failure)
        }

        await connections.retain(client, as: declaration.name)
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
        default:
            throw CLIApplicationError.failed(
                "unknown `mcp` subcommand '\(options.action)' (expected: \(actions.sorted().joined(separator: ", ")))"
            )
        }
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
