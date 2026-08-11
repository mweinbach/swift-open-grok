// LiveMCPACPHandlers.swift
//
// The `x.ai/mcp/*` ACP extension family — Wave 15 item 3.
//
// Upstream routes every method under the `x.ai/mcp/` prefix into one module
// dispatcher (`acp_agent.rs:4420-4422` → `extensions/mcp.rs:374-389`), whose
// forward routes at the pin are list / call / read_resource / auth_status /
// auth_trigger / setup / toggle / toggle_tool / upsert / delete
// (`mcp_methods`, mcp.rs:33-50; `route_mcp_method`, mcp.rs:358-372). This
// port routes the nine with real backings and refuses the rest:
//
//   * `list` (mcp.rs:899-1185) — the local server catalog (trust-gated
//     config layers) annotated with the live session's connection state.
//     NOT ported inside it: managed connectors, the managed gateway tool
//     catalog, setup-schema rows, and disabled-name placeholders — those
//     subsystems (cli-chat-proxy fetch, `mcp_preferences.json`,
//     `disabled_mcp_servers`) do not exist in this port, so their rows are
//     absent rather than invented. `cache:false`'s managed-cache
//     invalidation is likewise a no-op — there is no managed cache.
//   * `call` (`wire::MCP_CALL`, mcp.rs:1189-1223, 825-895) — invoke a tool
//     on a connected server directly, outside the LLM loop, through the
//     SAME retained client the session's bridged tools use. Upstream's
//     no-session arm dials a separate agent-level pool (config.toml only);
//     this process has exactly one live stack, so both arms answer from
//     the session pool — recorded divergence.
//   * `read_resource` (mcp.rs:1225-1325) — `resources/read` on a connected
//     server. The port's `MCPResourceContents` carries no `_meta`, so that
//     optional field is never present — recorded.
//   * `auth_status` (mcp.rs:1499-1507; run_loop.rs:1750-1762) — the
//     servers currently stuck on OAuth, status `"needs_auth"`.
//   * `auth_trigger` (mcp.rs:1526-1578; acp_session_impl/mcp.rs:405-514) —
//     the REAL E7 browser flow (`mcpAuthenticateServer(force: true)`), then
//     a live reconnect that registers the server's tools into the running
//     toolset. The setup-schema pre-check (mcp.rs:1541-1562) is skipped:
//     no setup surface exists here.
//   * `upsert` (mcp.rs:1874-1900) — persist to the user `config.toml`
//     (`upsertMCPServer` + `writeConfigFile`, the same write `mcp add`
//     performs), then live-swap the server in the running session.
//   * `delete` (mcp.rs:1910-1941) — remove from the user `config.toml`,
//     then live teardown (tools unregistered, client shut down).
//   * `toggle` (mcp.rs:1714-1820) — persist to `disabled_mcp_servers` in
//     the user `config.toml`, then live-swap (connect or teardown). Emits
//     `x.ai/mcp/tools_changed` only after successful swap. Managed
//     connectors, gateway prefix routing, and plugin registry are out of
//     scope — those branches are absent.
//   * `toggle_tool` (mcp.rs:1833-1870) — persist per-tool disable to
//     `disabled_mcp_tools` in `config.toml`, then live remove/restore the
//     qualified tool in the running toolset. Emits `tools_changed` after.
//
// Refused, with the shape upstream itself uses for the prefix:
//
//   * `setup` — upstream serves this; this port has no
//     `mcp_preferences.json` setup-values surface and no setup-schema
//     resolution, so the schema cannot be driven. Refused with the
//     port's terminal ext-method error (data naming the method) so a peer
//     can tell "not ported" from upstream's bare unknown-name refusal below.
//   * Anything else under the prefix — including an inbound copy of the
//     emit-only reverse method `x.ai/mcp/sdk_call` — gets upstream's OWN
//     refusal for unknown `x.ai/mcp/*` names: bare `method_not_found`, NO
//     data (mcp.rs:387 and the pin's regression test mcp.rs:1952-1965).
//
// The `sdk_call` reverse bridge itself (agent → client, in-process SDK MCP
// servers, session/acp_mcp.rs) is NOT implemented: it needs a `session/new`
// `_meta["x.ai/mcp/servers"]` seam from the runtime into the live toolset,
// per-ACP-session tool scoping (this port's toolset is per-process), and an
// MCP-handshake-over-reverse-channel transport. Because the bridge is
// absent, the initialize `_meta` deliberately does NOT advertise
// `x.ai/mcp/sdk` (upstream acp_agent.rs:700-702, wire.rs:25-27) — the SDK
// reads that flag to enable `transport="acp"`, and advertising it without
// the bridge would break every SDK client that trusts it.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolRegistry

// MARK: - Live MCP state

/// The mutable MCP session state the `x.ai/mcp/*` handlers read and write:
/// the retained client pool, the live toolset, and the per-server connect
/// outcomes (`/mcps` facts). Seeded from the tool executor's composition-time
/// snapshot; `auth_trigger`/`upsert`/`delete` mutate it as they mutate the
/// pool, so `list`/`auth_status` always describe the pool as it is NOW.
actor LiveMCPACPState {
    let connections: MCPSessionConnections
    let toolset: FinalizedToolset
    private var outcomes: [String: MCPServerConnection]

    init(
        connections: MCPSessionConnections,
        toolset: FinalizedToolset,
        outcomes: [MCPServerConnection]
    ) {
        self.connections = connections
        self.toolset = toolset
        self.outcomes = Dictionary(
            outcomes.map { ($0.name, $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    func outcome(for name: String) -> MCPServerConnection? { outcomes[name] }

    func record(_ outcome: MCPServerConnection) {
        outcomes[outcome.name] = outcome
    }

    func removeOutcome(name: String) {
        outcomes.removeValue(forKey: name)
    }

    /// The port of the session's `auth_required` set (mcp_servers.rs state):
    /// servers whose connect outcome was the deferred-OAuth notice. Cleared
    /// by a successful `auth_trigger` reconnect recording a fresh outcome.
    func authRequiredServers() -> [String] {
        outcomes.values
            .filter {
                $0.failure == LiveMCPComposition.authorizationRequiredNotice(serverName: $0.name)
            }
            .map(\.name)
            .sorted()
    }
}

// MARK: - Handler

struct LiveMCPACPHandler: ACPAgentExtensionHandler, Sendable {
    /// Upstream's routing prefix (`mcp_methods::PREFIX`, mcp.rs:35).
    static let prefix = "x.ai/mcp/"
    /// `MANAGED_MCP_PREFIX` (xai-grok-workspace permission/resolution.rs:1213).
    static let managedServerPrefix = "grok_com_"
    /// Upstream's per-tool-call ceiling when config sets none
    /// (`DEFAULT_TOOL_TIMEOUT_SECS`, xai-grok-mcp servers.rs:1070).
    static let defaultToolTimeoutSeconds: UInt64 = 6000

    let gateway: ACPNotificationGateway
    let state: LiveMCPACPState
    /// Trust-gated declaration source: re-reads the config layers through the
    /// SAME folder-trust gate the composition used (`LiveSecurityContext`),
    /// so an untrusted repo's `.opengrok/config.toml` servers can no more
    /// enter this surface than they could enter the session's pool.
    let declarations: @Sendable () -> MCPConfigLoadResult
    /// The `upsert`/`delete` write target — the user `config.toml`, the same
    /// file `open-grok mcp add`/`remove` edit (upstream
    /// `save_mcp_server_config`/`delete_mcp_server_config` edit the grok-home
    /// config.toml, util/config/mcp.rs:860-948).
    let userConfigPath: URL
    let openGrokHome: URL
    let environment: [String: String]
    // auth_trigger injectables — the E7 seams: a real HTTP transport and the
    // system browser in production; a scripted transport and a fake browser
    // driving the REAL loopback listener in tests.
    let makeHTTPTransport: @Sendable () -> any HTTPTransport
    let openBrowser: @Sendable (URL) -> Void
    let authTimeoutSeconds: TimeInterval
    let authCredentialPollIntervalSeconds: TimeInterval

    init(
        gateway: ACPNotificationGateway,
        state: LiveMCPACPState,
        declarations: @escaping @Sendable () -> MCPConfigLoadResult,
        userConfigPath: URL,
        openGrokHome: URL,
        environment: [String: String],
        makeHTTPTransport: @escaping @Sendable () -> any HTTPTransport = { URLSessionHTTPTransport() },
        openBrowser: (@Sendable (URL) -> Void)? = nil,
        authTimeoutSeconds: TimeInterval = mcpBrowserAuthTimeoutSeconds,
        authCredentialPollIntervalSeconds: TimeInterval = mcpCredentialPollIntervalSeconds
    ) {
        self.gateway = gateway
        self.state = state
        self.declarations = declarations
        self.userConfigPath = userConfigPath
        self.openGrokHome = openGrokHome
        self.environment = environment
        self.makeHTTPTransport = makeHTTPTransport
        self.openBrowser = openBrowser ?? { LiveAuthComposition.openInSystemBrowser($0) }
        self.authTimeoutSeconds = authTimeoutSeconds
        self.authCredentialPollIntervalSeconds = authCredentialPollIntervalSeconds
    }

    /// The production declaration source: re-resolve the config layers
    /// through the SAME folder-trust gate the session composition used
    /// (`LiveSecurityContext.resolve`), so upsert/delete writes become
    /// visible on the next read while an untrusted repo's
    /// `.opengrok/config.toml` stays out of the merge — the property the
    /// composition-time connect relied on (LiveComposition.swift, the
    /// `security.document` comment at the pool's construction).
    /// `isInteractive: false` because no trust sheet can be raised over
    /// ACP; an undecided folder therefore stays untrusted — the fail-closed
    /// direction.
    static func trustGatedDeclarationSource(
        workspaceRoot: URL,
        environment: [String: String],
        cli: CLIPermissionOptions
    ) -> @Sendable () -> MCPConfigLoadResult {
        let root = workspaceRoot.standardizedFileURL
        return {
            let security = LiveSecurityContext.resolve(
                workspaceRoot: root,
                environment: environment,
                isInteractive: false,
                cli: cli
            )
            return MCPConfigLoader.load(from: security.document)
        }
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "x.ai/mcp/list":
            return try await handleList(params)
        case "x.ai/mcp/call":
            return try await handleCall(params)
        case "x.ai/mcp/read_resource":
            return try await handleReadResource(params)
        case "x.ai/mcp/auth_status":
            return try await handleAuthStatus(params)
        case "x.ai/mcp/auth_trigger":
            return try await handleAuthTrigger(params)
        case "x.ai/mcp/upsert":
            return try await handleUpsert(params)
        case "x.ai/mcp/delete":
            return try await handleDelete(params)
        case "x.ai/mcp/setup":
            // Upstream serves setup; this port has no setup-schema surface or
            // `mcp_preferences.json` setup-values layer — the schema cannot
            // resolve and the preference cannot persist. Refused with the
            // data-carrying terminal error (distinguishes "not ported" from
            // the bare unknown-name refusal below).
            throw ACPExtensionMethodRouter.unknownExtensionMethodError(method)
        case "x.ai/mcp/toggle":
            return try await handleToggle(params)
        case "x.ai/mcp/toggle_tool":
            return try await handleToggleTool(params)
        default:
            // Upstream's own arm for an unknown name under the prefix —
            // including an inbound copy of the emit-only reverse method
            // `x.ai/mcp/sdk_call`: bare `method_not_found()`, no data
            // (mcp.rs:387; regression-pinned upstream at mcp.rs:1952-1965).
            throw AcpError(
                code: .methodNotFound,
                message: AcpErrorCode.methodNotFound.displayName
            )
        }
    }

    // MARK: Shared pieces

    /// `{"result": payload}` — `to_ext_response(Ok(...))`
    /// (extensions/mod.rs:63-67 → session/result.rs).
    private func envelope(_ payload: JSONValue) -> JSONValue {
        .object(["result": payload])
    }

    /// `parse_params`'s failure shape (extensions/mod.rs:53-56): the prose
    /// after the "invalid params: " prefix is serde-generated upstream and
    /// hand-written here — recorded.
    private func invalidParams(_ detail: String) -> AcpError {
        AcpError(
            code: .invalidParams,
            message: AcpErrorCode.invalidParams.displayName,
            data: .string(detail)
        )
    }

    private func internalError(_ detail: String) -> AcpError {
        AcpError(
            code: .internalError,
            message: AcpErrorCode.internalError.displayName,
            data: .string(detail)
        )
    }

    /// The session gate shared by call/read_resource/auth_*/upsert/delete:
    /// upstream resolves the handle and refuses with
    /// `invalid_params().data("session not found")` (mcp.rs:1201, 1234,
    /// 1504, 1531, 1892, 1929).
    private func requireSession(_ sessionID: String) async throws {
        guard await gateway.sessionExists(AcpSessionId(sessionID)) else {
            throw invalidParams("session not found")
        }
    }

    // MARK: x.ai/mcp/list

    /// `handle_list` (mcp.rs:899-1185), reduced to the subsystems this port
    /// has: local config-layer servers, annotated with the live session's
    /// state when the caller names a session this runtime holds. A named
    /// session that does NOT resolve still returns the plain catalog —
    /// upstream logs and continues (mcp.rs:932-937), never errors.
    private func handleList(_ params: JSONValue) async throws -> JSONValue {
        let sessionID = params["sessionId"]?.stringValue
        // `cache:false` invalidates the managed-MCP caches upstream
        // (mcp.rs:921-924); this port has no managed cache, so the flag is
        // accepted and changes nothing — recorded in the file header.
        let annotate: Bool
        if let sessionID {
            annotate = await gateway.sessionExists(AcpSessionId(sessionID))
        } else {
            annotate = false
        }

        let loaded = declarations()
        var servers: [JSONValue] = []
        for declaration in loaded.servers {
            servers.append(await serverEntry(declaration, annotate: annotate))
        }
        return envelope(.object(["servers": .array(servers)]))
    }

    /// One `McpServerEntry` in upstream's serde spelling: camelCase keys,
    /// the transport config flattened beside them under a `type` tag,
    /// lowercase `source`, and every `skip_serializing_if` honored
    /// (mcp.rs:79-176).
    private func serverEntry(
        _ declaration: MCPServerDeclaration,
        annotate: Bool
    ) async -> JSONValue {
        var entry: [String: JSONValue] = [
            "name": .string(declaration.name),
            // `McpServerSource`: managed-prefixed names report "managed"
            // even from local config (mcp.rs:505-509).
            "source": .string(
                declaration.name.hasPrefix(Self.managedServerPrefix) ? "managed" : "local"
            ),
        ]
        switch declaration.config.transport {
        case .stdio(let command, let args, let env, _):
            entry["type"] = .string("stdio")
            entry["command"] = .string(command)
            // `skip_serializing_if = "Vec::is_empty"` on args/env
            // (mcp.rs:117-122).
            if !args.isEmpty {
                entry["args"] = .array(args.map(JSONValue.string))
            }
            if let env, !env.isEmpty {
                entry["env"] = .array(env.sorted(by: { $0.key < $1.key }).map { name, value in
                    .object(["name": .string(name), "value": .string(value)])
                })
            }
        case .streamableHttp(let url, _, _, _, _, _, _):
            entry["type"] = .string("http")
            entry["url"] = .string(url)
            // scope/scopeId/scopeName are managed-connector facts
            // (mcp.rs:106-115); local servers carry none, matching
            // upstream's local arm (mcp.rs:511-517).
        }

        guard annotate else { return .object(entry) }

        // The session-state annotation loop (mcp.rs:1106-1144): enabled from
        // the session's configured set, status/tools from the live client,
        // authRequired from the session's OAuth-deferred set.
        var session: [String: JSONValue] = [
            "enabled": .bool(declaration.isEnabled),
        ]
        if let outcome = await state.outcome(for: declaration.name) {
            if outcome.isConnected {
                session["status"] = .string("ready")
                let tools = await connectedToolEntries(
                    serverName: declaration.name,
                    qualifiedNames: outcome.toolNames
                )
                if !tools.isEmpty {
                    session["tools"] = .array(tools)
                }
            } else if outcome.failure
                == LiveMCPComposition.authorizationRequiredNotice(serverName: declaration.name) {
                // Upstream: an auth-required server has no ready client, so
                // status stays absent and `authRequired` rides
                // (mcp.rs:1137-1143).
                session["authRequired"] = .bool(true)
            }
            // Any other failure: no client — status absent, like upstream's
            // annotation for a server the snapshot has no client for.
        }
        entry["session"] = .object(session)
        return .object(entry)
    }

    /// `McpToolEntry` rows for a connected server: UNQUALIFIED tool names
    /// (upstream strips the `{server}__` prefix, mcp.rs:678-691),
    /// descriptions from the live toolset — the set the model is actually
    /// offered — and stable alphabetical order (mcp.rs:711-713).
    private func connectedToolEntries(
        serverName: String,
        qualifiedNames: [String]
    ) async -> [JSONValue] {
        let toolset = state.toolset
        let descriptions = Dictionary(
            toolset.topLevelDefinitions().map { ($0.name, $0.description) },
            uniquingKeysWith: { first, _ in first }
        )
        let prefix = mcpToolNamePrefix(serverName)
        return qualifiedNames.sorted().map { qualified in
            let unqualified = qualified.hasPrefix(prefix)
                ? String(qualified.dropFirst(prefix.count))
                : qualified
            var tool: [String: JSONValue] = [
                "name": .string(unqualified),
                "enabled": .bool(true),
            ]
            if let description = descriptions[qualified], !description.isEmpty {
                tool["description"] = .string(description)
            }
            return .object(tool)
        }
    }

    // MARK: x.ai/mcp/call

    /// `handle_call` (mcp.rs:1189-1223) + `call_mcp_tool` (mcp.rs:825-895).
    private func handleCall(_ params: JSONValue) async throws -> JSONValue {
        guard let server = params["server"]?.stringValue,
              let tool = params["tool"]?.stringValue else {
            throw invalidParams("invalid params: missing field `server` or `tool`")
        }
        if let sessionID = params["sessionId"]?.stringValue {
            try await requireSession(sessionID)
        }
        let serverURL = params["serverUrl"]?.stringValue
        let arguments = params["arguments"] ?? .null

        // Resolution order (name + url) > url-only > name-only
        // (mcp.rs:836-857), against the current declarations.
        let target = resolveServerName(server: server, serverURL: serverURL)
        guard let client = await state.connections.client(named: target) else {
            throw internalError("server '\(target)' not found")
        }

        let timeoutSeconds = toolTimeoutSeconds(server: target, tool: tool)
        let result: MCPCallToolResult
        do {
            result = try await withTimeout(seconds: timeoutSeconds) {
                try await client.callTool(MCPCallToolParams(name: tool, arguments: arguments))
            }
        } catch is LiveMCPACPTimeout {
            throw internalError("tool '\(tool)' timed out after \(timeoutSeconds)s")
        } catch {
            throw internalError("tool call failed: \(error)")
        }

        // Content mapping (mcp.rs:873-889): text and embedded-resource
        // blocks survive (the resource serialized as JSON text); image /
        // audio / resource-link blocks are dropped, upstream's `_ => None`.
        var content: [JSONValue] = []
        for block in result.content {
            switch block {
            case .text(let text, _):
                content.append(.object(["type": .string("text"), "text": .string(text)]))
            case .resource(let embedded):
                let json = (try? JSONEncoder().encode(embedded))
                    .flatMap { String(data: $0, encoding: .utf8) }
                if let json {
                    content.append(.object([
                        "type": .string("resource"), "text": .string(json),
                    ]))
                }
            case .image, .audio, .resourceLink:
                continue
            }
        }
        // Upstream's `is_error` is the server's optional flag, omitted when
        // the server sent none; this port's client flattens it to a Bool, so
        // the field is always present — recorded.
        return envelope(.object([
            "content": .array(content),
            "isError": .bool(result.isError),
        ]))
    }

    private func resolveServerName(server: String, serverURL: String?) -> String {
        guard let serverURL else { return server }
        let loaded = declarations()
        func url(_ declaration: MCPServerDeclaration) -> String? {
            guard case .streamableHttp(let url, _, _, _, _, _, _) =
                declaration.config.transport else { return nil }
            return url
        }
        if let exact = loaded.servers.first(where: {
            $0.name == server && url($0) == serverURL
        }) {
            return exact.name
        }
        if let byURL = loaded.servers.first(where: { url($0) == serverURL }) {
            return byURL.name
        }
        return server
    }

    /// Upstream's timeout ladder for one call (`tool_timeout_for`,
    /// servers.rs:3228-3233): per-tool override, else the server's
    /// `tool_timeout_sec`, else 6000s.
    private func toolTimeoutSeconds(server: String, tool: String) -> UInt64 {
        guard let declaration = declarations().servers.first(where: { $0.name == server }) else {
            return Self.defaultToolTimeoutSeconds
        }
        return declaration.config.toolTimeouts?[tool]
            ?? declaration.config.toolTimeoutSec
            ?? Self.defaultToolTimeoutSeconds
    }

    // MARK: x.ai/mcp/read_resource

    /// `handle_read_resource` (mcp.rs:1225-1246) + `read_mcp_resource`
    /// (mcp.rs:1248-1325).
    private func handleReadResource(_ params: JSONValue) async throws -> JSONValue {
        guard let server = params["server"]?.stringValue,
              let uri = params["uri"]?.stringValue else {
            throw invalidParams("invalid params: missing field `server` or `uri`")
        }
        if let sessionID = params["sessionId"]?.stringValue {
            try await requireSession(sessionID)
        }
        guard let client = await state.connections.client(named: server) else {
            throw internalError("server '\(server)' not found")
        }

        let result: MCPReadResourceResult
        do {
            result = try await client.readResource(MCPReadResourceParams(uri: uri))
        } catch {
            throw internalError("resource read failed: \(error)")
        }
        guard !result.contents.isEmpty else {
            throw internalError("empty resource")
        }

        // Upstream keeps text and blob variants and drops unknown ones
        // (mcp.rs:1276-1318); the port's model has exactly those two shapes,
        // so a row with neither is the degenerate drop case.
        var contents: [JSONValue] = []
        for item in result.contents {
            guard item.text != nil || item.blob != nil else { continue }
            var row: [String: JSONValue] = ["uri": .string(item.uri)]
            if let mimeType = item.mimeType { row["mimeType"] = .string(mimeType) }
            if let text = item.text { row["text"] = .string(text) }
            if let blob = item.blob { row["blob"] = .string(blob) }
            contents.append(.object(row))
        }
        guard !contents.isEmpty else {
            throw internalError("resource contained only unsupported content variants")
        }
        return envelope(.object(["contents": .array(contents)]))
    }

    // MARK: x.ai/mcp/auth_status

    /// `handle_auth_status` (mcp.rs:1499-1507): the session's `auth_required`
    /// set as `{server_name, status: "needs_auth"}` rows
    /// (run_loop.rs:1750-1762). These two request/response structs have no
    /// serde rename upstream, so the wire spelling is snake_case.
    private func handleAuthStatus(_ params: JSONValue) async throws -> JSONValue {
        guard let sessionID = params["session_id"]?.stringValue else {
            throw invalidParams("invalid params: missing field `session_id`")
        }
        try await requireSession(sessionID)
        let entries = await state.authRequiredServers().map { name in
            JSONValue.object([
                "server_name": .string(name),
                "status": .string("needs_auth"),
            ])
        }
        return envelope(.object(["servers": .array(entries)]))
    }

    // MARK: x.ai/mcp/auth_trigger

    /// `handle_auth_trigger` (mcp.rs:1526-1578) over
    /// `handle_mcp_auth_trigger` (acp_session_impl/mcp.rs:405-443): every
    /// config-shaped refusal rides INSIDE the response payload as
    /// `{status: "failed", error}`, never as a JSON-RPC error — only the
    /// missing session is a protocol error. On success the flow re-connects
    /// the server and registers its tools into the live toolset, the port of
    /// upstream's post-auth `get_tool_registrations` + register loop.
    private func handleAuthTrigger(_ params: JSONValue) async throws -> JSONValue {
        guard let sessionID = params["session_id"]?.stringValue,
              let serverName = params["server_name"]?.stringValue else {
            throw invalidParams("invalid params: missing field `session_id` or `server_name`")
        }
        try await requireSession(sessionID)

        // Managed connectors authenticate at grok.com, byte-copy of the
        // refusal (acp_session_impl/mcp.rs:406-408).
        if serverName.hasPrefix(Self.managedServerPrefix) {
            return authTriggerFailure("To authenticate, visit grok.com")
        }
        guard let declaration = declarations().servers.first(where: { $0.name == serverName })
        else {
            // `recreate_http_client_with_oauth`'s missing-config arm
            // (acp_session_impl/mcp.rs:459).
            return authTriggerFailure("MCP server '\(serverName)' not found in config")
        }
        guard case .streamableHttp = declaration.config.transport else {
            // The non-HTTP arm (acp_session_impl/mcp.rs:460-465).
            return authTriggerFailure("MCP server '\(serverName)' does not use OAuth")
        }
        guard let endpoint = declaration.oauthEligibleEndpoint(environment: environment) else {
            // A static Authorization header IS the auth; upstream would run
            // discovery and report "does not support OAuth" — this port
            // knows without dialing, and says which header. Recorded
            // divergence (hand-written copy, LiveMCPComposition.runLogin's
            // sibling arm).
            return authTriggerFailure(
                "MCP server '\(serverName)' already authenticates with a configured Authorization header"
            )
        }

        // The REAL E7 flow: force reauth so a stale abandoned flow never
        // blocks a fresh consent (upstream `force_reauth(true)`,
        // acp_session_impl/mcp.rs:413).
        do {
            try await mcpAuthenticateServer(
                serverName: serverName,
                serverURL: endpoint,
                home: openGrokHome,
                transport: makeHTTPTransport(),
                byoConfig: declaration.config.oauthConfig(environment: environment),
                force: true,
                openBrowser: openBrowser,
                timeoutSeconds: authTimeoutSeconds,
                credentialPollIntervalSeconds: authCredentialPollIntervalSeconds
            )
        } catch {
            // Upstream's generic flow failure, byte-copy
            // (acp_session_impl/mcp.rs:413-418).
            return authTriggerFailure("Authentication failed for MCP server '\(serverName)'")
        }
        // Assert the store write at the step it happened (AGENTS.md §3):
        // "flow returned" is not "token landed".
        let storage = MCPFileCredentialStorage(
            home: openGrokHome, serverName: serverName, serverURL: endpoint
        )
        guard (try? storage.load())?.tokenResponse != nil else {
            return authTriggerFailure("Authentication failed for MCP server '\(serverName)'")
        }

        // Live re-init + tool registration (acp_session_impl/mcp.rs:419-437):
        // tear down any previous client for the name, then connect fresh with
        // the just-stored token so the tools land in the RUNNING toolset.
        let connections = state.connections
        let toolset = state.toolset
        MCPToolBridge.unregister(server: serverName, from: toolset)
        if let previous = await connections.release(named: serverName) {
            try? await previous.shutdown()
            await previous.close()
        }
        let makeHTTPTransport = self.makeHTTPTransport
        let outcome = await LiveMCPComposition.connect(
            declaration: declaration,
            toolset: toolset,
            connections: connections,
            environment: environment,
            makeHTTPTransport: { makeHTTPTransport() }
        )
        await state.record(outcome)
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)
        if let failure = outcome.failure {
            // Upstream's post-auth registration failure copy
            // (acp_session_impl/mcp.rs:420-423).
            return authTriggerFailure("Failed to get tools after auth: \(failure)")
        }
        return envelope(.object(["status": .string("authenticated")]))
    }

    /// `McpAuthTriggerResponse { status: "failed", error }` — snake_case
    /// fields, `setup` omitted (mcp.rs:1515-1524, 1569-1576).
    private func authTriggerFailure(_ error: String) -> JSONValue {
        envelope(.object([
            "status": .string("failed"),
            "error": .string(error),
        ]))
    }

    // MARK: x.ai/mcp/upsert

    /// `handle_upsert` (mcp.rs:1874-1900): persist to config.toml FIRST,
    /// then live-add through the running session. Upstream reuses its
    /// toggle path for the live half; this port's equivalent is a fresh
    /// `LiveMCPComposition.connect` after tearing down any previous client
    /// with the same name.
    private func handleUpsert(_ params: JSONValue) async throws -> JSONValue {
        guard let sessionID = params["session_id"]?.stringValue,
              let serverName = params["server_name"]?.stringValue else {
            throw invalidParams("invalid params: missing field `session_id` or `server_name`")
        }
        let config: McpServerConfig
        do {
            config = try params.decode(McpServerConfig.self)
        } catch {
            throw invalidParams("invalid params: \(error)")
        }
        // The port's transport decoder tolerates a missing `url` where
        // upstream's serde rejects it (mcp.rs parse_params); the blank check
        // restores the refusal before anything is persisted.
        if let blank = MCPConfigLoader.blankTransportField(config) {
            throw invalidParams("invalid params: missing or empty '\(blank)'")
        }

        // 1. Persist — the same write `open-grok mcp add` lands
        //    (upsertMCPServer + writeConfigFile → user config.toml), the
        //    port of `save_mcp_server_config` (mcp.rs:1878-1881).
        var root = LiveMCPComposition.loadForEdit(at: userConfigPath) ?? .table(TOMLTable())
        do {
            try upsertMCPServer(serverName, config: config, in: &root)
            try writeConfigFile(root, to: userConfigPath)
        } catch {
            throw internalError("\(error)")
        }

        // 2. A disabled config persists but cannot be live-added
        //    (`to_acp_mcp_server` → None, mcp.rs:1884-1887).
        guard config.enabled else {
            throw invalidParams("server config is disabled")
        }

        // 3. Session lookup AFTER the persist, upstream's order
        //    (mcp.rs:1890-1892).
        try await requireSession(sessionID)

        // 4. Live swap: tear down any previous client under this name, then
        //    connect the new declaration and register its tools.
        let connections = state.connections
        let toolset = state.toolset
        MCPToolBridge.unregister(server: serverName, from: toolset)
        if let previous = await connections.release(named: serverName) {
            try? await previous.shutdown()
            await previous.close()
        }
        let declaration = MCPServerDeclaration(name: serverName, config: config, scope: "user")
        let makeHTTPTransport = self.makeHTTPTransport
        let outcome = await LiveMCPComposition.connect(
            declaration: declaration,
            toolset: toolset,
            connections: connections,
            environment: environment,
            makeHTTPTransport: { makeHTTPTransport() }
        )
        await state.record(outcome)
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)
        if let failure = outcome.failure {
            // Deferred OAuth is upstream's ok arm: the spawn succeeds with
            // auth pending and the session marks auth_required. Any other
            // failure surfaces — upstream's toggle path maps live-spawn
            // errors to internal_error (mcp.rs:1894-1897); upstream's
            // background init would defer some of these, this port connects
            // synchronously — recorded.
            if failure
                != LiveMCPComposition.authorizationRequiredNotice(serverName: serverName) {
                throw internalError(failure)
            }
        }
        return envelope(.object(["ok": .bool(true)]))
    }

    // MARK: x.ai/mcp/toggle

    /// `handle_toggle` (mcp.rs:1714-1820): persist-then-swap, with a
    /// `tools_changed` notification ONLY after a successful live swap.
    ///
    /// This port carries no managed connectors, no gateway prefix routing, and
    /// no plugin registry — those subsystems are explicitly out of scope and
    /// their conditional branches are absent rather than stubbed.
    private func handleToggle(_ params: JSONValue) async throws -> JSONValue {
        guard let sessionID = params["session_id"]?.stringValue
                ?? params["sessionId"]?.stringValue,
              let serverName = params["server_name"]?.stringValue
                ?? params["serverName"]?.stringValue else {
            throw invalidParams("invalid params: missing field `session_id` or `server_name`")
        }
        let enabled: Bool
        if let e = params["enabled"]?.boolValue {
            enabled = e
        } else {
            throw invalidParams("invalid params: missing field `enabled`")
        }

        try await requireSession(sessionID)

        // 1. Persist the enable/disable to config.toml FIRST (fail-closed).
        var root = LiveMCPComposition.loadForEdit(at: userConfigPath) ?? .table(TOMLTable())
        do {
            try applyMCPServerEnabled(serverName, enabled: enabled, in: &root)
            try writeConfigFile(root, to: userConfigPath)
        } catch {
            throw internalError("failed to persist toggle: \(error)")
        }

        // 2. Live swap: connect or teardown depending on direction.
        if enabled {
            guard let declaration = declarations().servers.first(where: { $0.name == serverName })
            else {
                throw invalidParams("server '\(serverName)' not found in config")
            }
            let connections = state.connections
            let toolset = state.toolset
            MCPToolBridge.unregister(server: serverName, from: toolset)
            if let previous = await connections.release(named: serverName) {
                try? await previous.shutdown()
                await previous.close()
            }
            let makeHTTPTransport = self.makeHTTPTransport
            let disabledTools = allDisabledMCPTools(in: root)
            let outcome = await LiveMCPComposition.connect(
                declaration: declaration,
                toolset: toolset,
                connections: connections,
                environment: environment,
                makeHTTPTransport: { makeHTTPTransport() },
                disabledToolNames: disabledTools[serverName] ?? []
            )
            await state.record(outcome)
            if let failure = outcome.failure,
               failure != LiveMCPComposition.authorizationRequiredNotice(serverName: serverName) {
                throw internalError(failure)
            }
            // Notification ONLY after successful swap.
            await emitToolsChanged(sessionID: sessionID, serverName: serverName)
        } else {
            let toolset = state.toolset
            MCPToolBridge.unregister(server: serverName, from: toolset)
            if let previous = await state.connections.release(named: serverName) {
                try? await previous.shutdown()
                await previous.close()
            }
            await state.removeOutcome(name: serverName)
            await emitToolsChanged(sessionID: sessionID, serverName: serverName)
        }
        return envelope(.object(["ok": .bool(true)]))
    }

    // MARK: x.ai/mcp/toggle_tool

    /// `handle_toggle_tool` (mcp.rs:1833-1870): persist per-tool disable,
    /// then live unregister/re-register the single qualified tool.
    private func handleToggleTool(_ params: JSONValue) async throws -> JSONValue {
        guard let sessionID = params["session_id"]?.stringValue
                ?? params["sessionId"]?.stringValue,
              let serverName = params["server_name"]?.stringValue
                ?? params["serverName"]?.stringValue,
              let toolName = params["tool_name"]?.stringValue
                ?? params["toolName"]?.stringValue else {
            throw invalidParams(
                "invalid params: missing field `session_id`, `server_name`, or `tool_name`"
            )
        }
        let enabled: Bool
        if let e = params["enabled"]?.boolValue {
            enabled = e
        } else {
            throw invalidParams("invalid params: missing field `enabled`")
        }

        try await requireSession(sessionID)

        // 1. Persist the per-tool disable/enable to config.toml FIRST.
        var root = LiveMCPComposition.loadForEdit(at: userConfigPath) ?? .table(TOMLTable())
        do {
            try applyMCPToolEnabled(server: serverName, tool: toolName, enabled: enabled, in: &root)
            try writeConfigFile(root, to: userConfigPath)
        } catch {
            throw internalError("failed to persist tool toggle: \(error)")
        }

        // 2. Live swap: remove or restore the single qualified tool.
        let toolset = state.toolset
        if enabled {
            // Re-register the full server's tool set to pick up the re-enabled
            // tool. Unregister first so the bridge can re-register cleanly.
            MCPToolBridge.unregister(server: serverName, from: toolset)
            if let client = await state.connections.client(named: serverName) {
                let provider = MCPClientToolProvider(serverName: serverName, client: client)
                let disabledTools = allDisabledMCPTools(in: root)
                let registration = await MCPToolBridge.register(
                    provider: provider,
                    into: toolset,
                    disabledToolNames: disabledTools[serverName] ?? []
                )
                await state.record(MCPServerConnection(
                    name: serverName,
                    toolNames: registration.registeredNames,
                    skipped: registration.skipped
                ))
            }
        } else {
            // Unregister just the one qualified name.
            if let qualified = qualifiedMCPToolName(server: serverName, tool: toolName) {
                toolset.unregister(prefix: qualified)
            }
        }

        // Notification after swap.
        await emitToolsChanged(sessionID: sessionID, serverName: serverName)
        return envelope(.object(["ok": .bool(true)]))
    }

    // MARK: Notifications

    /// Emit `x.ai/mcp/tools_changed` — the per-server push that tells the
    /// pager to schedule a debounced `mcp/list` refetch (mcp.rs:248-270).
    /// The `sessionId` routes the push to the owning agent on multi-agent
    /// runtimes; `serverName` and `tools` are currently unread by the pager
    /// (mcp.rs:262-270) and left minimal for forward-compat.
    private func emitToolsChanged(sessionID: String, serverName: String) async {
        // Keep `search_tool`'s index aligned with the live MCP toolset after
        // every tools-changed mutation (toggle / reconnect / delete).
        LiveMCPToolSearchIndex.refreshIfPresent(in: state.toolset)
        let params = JSONValue.object([
            "sessionId": .string(sessionID),
            "serverName": .string(serverName),
        ])
        await gateway.send(method: "x.ai/mcp/tools_changed", params: params)
    }

    // MARK: x.ai/mcp/delete

    /// `handle_delete` (mcp.rs:1910-1941): config removal first — refusing
    /// names that were never locally configured with the byte-exact copy —
    /// then the live teardown. Also clears `disabled_mcp_servers` for the
    /// deleted name (mcp.rs:1936-1938) so a recreate does not inherit a
    /// stale disable.
    private func handleDelete(_ params: JSONValue) async throws -> JSONValue {
        guard let sessionID = params["session_id"]?.stringValue,
              let serverName = params["server_name"]?.stringValue else {
            throw invalidParams("invalid params: missing field `session_id` or `server_name`")
        }

        var existed = false
        var deletedDeclaration: MCPServerDeclaration?
        if var root = LiveMCPComposition.loadForEdit(at: userConfigPath) {
            do {
                deletedDeclaration = MCPConfigLoader.load(from: root)
                    .servers.first { $0.name == serverName }
                existed = try removeMCPServer(serverName, from: &root)
                if existed {
                    // Upstream's trailing cleanup (mcp.rs:1936-1938): a
                    // deleted server must leave `disabled_mcp_servers` too,
                    // or a recreate would inherit a stale disable.
                    try? applyMCPServerEnabled(serverName, enabled: true, in: &root)
                    try writeConfigFile(root, to: userConfigPath)
                }
            } catch {
                throw internalError("\(error)")
            }
        }
        guard existed else {
            throw invalidParams(
                "server '\(serverName)' not found in config.toml (only locally-configured servers can be deleted)"
            )
        }

        try await requireSession(sessionID)

        // Live teardown (mcp.rs:1926-1934): the tools leave the advertised
        // set and the client shuts down.
        let toolset = state.toolset
        MCPToolBridge.unregister(server: serverName, from: toolset)
        if let previous = await state.connections.release(named: serverName) {
            try? await previous.shutdown()
            await previous.close()
        }
        await state.removeOutcome(name: serverName)
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)

        // Credential teardown is intentionally separate from config removal:
        // remote RFC 7009 revocation is best-effort and reported honestly,
        // while locked local deletion is mandatory. The pinned Rust store's
        // durability contract is credentials.rs:291-300 and :392-406.
        var credentialsRemoved = 0
        var remoteStatus: MCPRemoteRevocationStatus = .notAttempted
        if let declaration = deletedDeclaration,
           let endpoint = declaration.oauthEligibleEndpoint(environment: environment) {
            let manager = MCPAuthorizationManager(
                baseURL: endpoint,
                transport: makeHTTPTransport(),
                storage: MCPFileCredentialStorage(
                    home: openGrokHome,
                    serverName: serverName,
                    serverURL: endpoint
                )
            )
            let revocation = try await manager.revokeStoredCredentials(
                clientSecret: declaration.config.oauthConfig(environment: environment)?.clientSecret
            )
            if revocation.credentialsRemoved { credentialsRemoved += 1 }
            remoteStatus = revocation.remoteStatus
        }
        credentialsRemoved += try MCPCredentialStore.removeByServerNameAndSave(
            home: openGrokHome,
            serverName: serverName
        )

        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "credentials_removed": .bool(credentialsRemoved > 0),
        ]
        switch remoteStatus {
        case .notAttempted:
            result["remote_revocation"] = .string("not_attempted")
        case .succeeded:
            result["remote_revocation"] = .string("succeeded")
        case .unsupported:
            result["remote_revocation"] = .string("unsupported")
        case .failed(let error):
            result["remote_revocation"] = .string("failed")
            result["revocation_error"] = .string(error)
        }
        return envelope(.object(result))
    }
}

// MARK: - Timeout helper

private struct LiveMCPACPTimeout: Error {}

/// Race one MCP call against upstream's per-tool ceiling
/// (`tokio::time::timeout`, mcp.rs:866-870). The losing task is cancelled;
/// `MCPClient` translates task cancellation into `notifications/cancelled`
/// toward the server.
private func withTimeout<T: Sendable>(
    seconds: UInt64,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw LiveMCPACPTimeout()
        }
        guard let first = try await group.next() else {
            throw LiveMCPACPTimeout()
        }
        group.cancelAll()
        return first
    }
}
