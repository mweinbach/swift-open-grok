// LiveWorkspaceComposition.swift
//
// The `open-grok workspace` route: Computer Hub workspace exposure.
//
// The shape to understand before reading: **no workspace subcommand does the
// exposing.** Every one of them is a control message to a *leader* process,
// which owns the hub connection and the exposed workspace; the CLI is a thin
// client that dials the leader's Unix socket, asks, and renders the answer.
// That is why `start` still requires leader mode and why `status` needs a
// leader to already be running.
//
// Rust reference (`/Users/mweinbach/Projects/grok-build` @ 9ed09e2a):
//
//   * `crates/codegen/xai-grok-pager/src/app/cli.rs:174-232` — the subcommand
//     surface and flags (`WorkspaceMgmtCommand`, `WorkspaceStartArgs`,
//     `LeaderTargetArgs`). `status` carries the `list` visible alias.
//   * `crates/codegen/xai-grok-pager-bin/src/main.rs:295-352`
//     (`run_workspace_mgmt`) — the gate order ported in `preflight` below.
//   * `main.rs:247-290` — `WORKSPACE_COMMAND_ENV`, `env_flag_enabled`,
//     `workspace_command_gate`, and the `WorkspaceGate` tri-state.
//   * `main.rs:353-362` (`ensure_workspace_caps`) — the leader capability
//     check and its exact error text.
//   * `main.rs:363-386` (`connect_workspace_control`) — the no-leader error.
//   * `main.rs:387-401` (`workspace_control`) and `403-466` (`workspace_start`).
//   * `main.rs:468-514` (`render_workspace_payload`) — the human and `--json`
//     output shapes, reproduced field for field in `renderStatus`.
//
// CURRENT CONTROL-PLANE BOUNDARY
//
// The leader now advertises and serves the control protocol, including a
// truthful `workspace_status` result. The hub connection remains an injected
// backend seam: a leader without that backend refuses `workspace_start` with
// a typed error, while status still reports `none`. This client must consume
// `controlResult` directly; skipping it would make a valid leader response
// look like a hang.
//
// The launcher hook that routes here goes in `LiveComposition.swift`, which
// this slice does not own; the diff is in INTEGRATION-w9-hub.md.

import Foundation
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokComputerHubCore
import OpenGrokComputerHubMCPAdapter
import OpenGrokComputerHubSDK
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokModels
import OpenGrokSandbox
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspaceClient

// MARK: - Errors

/// A refusal from this route. Every case carries the message the user sees;
/// the wording tracks the cited Rust line so a parity diff is a string diff.
public struct WorkspaceRouteError: Error, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

// MARK: - Feature gate

/// `main.rs:251-256`. Tri-state on purpose: "the flag says off" and "I could
/// not read the flag" both refuse, but only the second is the user's network
/// rather than their account, and they earn different messages.
public enum WorkspaceGate: Sendable, Equatable {
    case enabled
    case disabled
    case unknown
}

/// `main.rs:247`.
public let workspaceCommandEnvironmentKey = "GROK_WORKSPACE_COMMAND"

/// `main.rs:285-290`. Everything enables except the common falsy spellings.
public func workspaceEnvFlagEnabled(_ value: String) -> Bool {
    !["", "0", "false", "off", "no"].contains(
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
}

/// `main.rs:259-263`.
public func workspaceCommandEnvironmentOverride(
    _ environment: [String: String]
) -> Bool? {
    environment[workspaceCommandEnvironmentKey].map(workspaceEnvFlagEnabled)
}

/// `main.rs:266-282`. Precedence: env override > remote `Some(true)` >
/// loaded-but-off > settings-not-loaded.
public func workspaceCommandGate(
    environmentOverride: Bool?,
    remoteSettings: RemoteSettings?
) -> WorkspaceGate {
    if let environmentOverride {
        return environmentOverride ? .enabled : .disabled
    }
    // Absent settings stay `.unknown` (main.rs:266-282). Only the
    // allowlisted projection may decide once settings are loaded — other
    // RemoteSettings fields must not reach this gate.
    guard let remoteSettings else { return .unknown }
    let allowed = AllowlistedRemoteSettings(projecting: remoteSettings)
    return (allowed.workspaceCommandEnabled ?? false) ? .enabled : .disabled
}

// MARK: - Status payload

/// The `ControlPayload::WorkspaceStatus` fields, `main.rs:469-478`.
public struct WorkspaceStatusPayload: Sendable, Equatable, Codable {
    public var state: String
    public var hubURL: String?
    public var cwd: String?
    public var uptimeMs: UInt64
    public var activeToolCalls: Int
    public var sessions: [String]
    public var pid: Int

    private enum CodingKeys: String, CodingKey {
        case state
        case hubURL = "hubUrl"
        case cwd
        case uptimeMs
        case activeToolCalls
        case sessions
        case pid
    }

    public init(
        state: String,
        hubURL: String? = nil,
        cwd: String? = nil,
        uptimeMs: UInt64 = 0,
        activeToolCalls: Int = 0,
        sessions: [String] = [],
        pid: Int
    ) {
        self.state = state
        self.hubURL = hubURL
        self.cwd = cwd
        self.uptimeMs = uptimeMs
        self.activeToolCalls = activeToolCalls
        self.sessions = sessions
        self.pid = pid
    }
}

// MARK: - Control channel

/// The leader control operations this route issues, `main.rs:333-350`.
public enum WorkspaceControlCommand: Sendable, Equatable {
    case start(hubURL: String?, cwd: String)
    case pause
    case resume
    case stop
    case status

    /// Wire spelling of `ControlCommand`, matching the leader protocol's
    /// flat `[String: String]` control frame (`ACPLeaderProtocol.swift:251`).
    public var wire: [String: String] {
        switch self {
        case .start(let hubURL, let cwd):
            var body = ["command": "workspace_start", "cwd": cwd]
            if let hubURL { body["hub_url"] = hubURL }
            return body
        case .pause: return ["command": "workspace_pause"]
        case .resume: return ["command": "workspace_resume"]
        case .stop: return ["command": "workspace_stop"]
        case .status: return ["command": "workspace_status"]
        }
    }
}

/// A connected leader, from this route's point of view.
///
/// Injectable so the tests can drive the whole route — gate, capability
/// check, render — against an in-process leader instead of requiring a real
/// one on the machine.
public protocol WorkspaceControlChannel: Sendable {
    /// Capabilities the leader advertised in its `registered` frame.
    /// `nil` when it advertised none (an older leader).
    var advertisedCapabilities: ACPLeaderCapabilities? { get }

    /// Send one control command and decode the leader's answer.
    func send(_ command: WorkspaceControlCommand) async throws -> WorkspaceStatusPayload

    func close() async
}

/// Injectable edges owned by the executable workspace route.
///
/// The loader is deliberately environment-driven so production uses the same
/// home, auth, and endpoint resolution as the rest of the CLI while tests can
/// replace both network and leader IPC with in-process seams.
public struct LiveWorkspaceRouteDependencies: Sendable {
    public let loadRemoteSettings: @Sendable ([String: String]) async -> RemoteSettings?
    public let connect: @Sendable ([String: String]) async throws -> any WorkspaceControlChannel

    public init(
        loadRemoteSettings: @escaping @Sendable ([String: String]) async -> RemoteSettings?,
        connect: @escaping @Sendable ([String: String]) async throws -> any WorkspaceControlChannel
    ) {
        self.loadRemoteSettings = loadRemoteSettings
        self.connect = connect
    }

    public static func production(
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) -> LiveWorkspaceRouteDependencies {
        LiveWorkspaceRouteDependencies(
            loadRemoteSettings: { environment in
                await loadWorkspaceRemoteSettings(environment: environment, transport: transport)
            },
            connect: { environment in
                try await LiveWorkspaceComposition.dialLeader(environment: environment)
            }
        )
    }
}

/// Fetch authenticated `/v1/settings`, failing closed on every unavailable
/// auth, endpoint, transport, status, or decoding outcome.
public func loadWorkspaceRemoteSettings(
    environment: [String: String],
    transport: any HTTPTransport
) async -> RemoteSettings? {
    let home = OpenGrokHomeResolver.resolve(environment: environment)
    let authManager = AuthManager(
        grokHome: home,
        config: GrokComConfig.default(environment: environment),
        environment: environment
    )
    guard let auth = try? await authManager.auth() else { return nil }

    let baseURLString = EndpointsConfig(
        cliChatProxyBaseURL: environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
    ).proxyURL()
    guard let baseURL = URL(string: baseURLString),
          baseURL.scheme != nil,
          baseURL.host != nil
    else { return nil }

    var headers = [
        "Accept": "application/json",
        "Authorization": "Bearer \(auth.key)",
        "X-XAI-Token-Auth": GrokComConfig.default(environment: environment).tokenHeader,
    ]
    if !auth.userID.isEmpty { headers["x-userid"] = auth.userID }
    if let email = auth.email { headers["x-email"] = email }

    let request = HTTPRequest(
        method: .get,
        url: baseURL.appendingPathComponent("settings"),
        headers: headers,
        timeout: 10
    )
    guard let response = try? await transport.send(request),
          (200..<300).contains(response.metadata.statusCode)
    else { return nil }
    return try? JSONDecoder().decode(RemoteSettings.self, from: response.body)
}

/// `main.rs:353-362` (`ensure_workspace_caps`).
public func ensureWorkspaceCapabilities(
    _ capabilities: ACPLeaderCapabilities?
) throws {
    guard capabilities?.workspaceExposure == true else {
        throw WorkspaceRouteError(
            "the running leader does not support workspace exposure — stop the "
                + "leader process and re-run to pick up the new version"
        )
    }
}

// MARK: - Route

public enum LiveWorkspaceComposition {
    public static let routeName = "workspace"

    /// `cli.rs:179-216`. `list` is `status`'s visible alias (`cli.rs:206`).
    public static let actions: Set<String> = [
        "start", "restart", "pause", "resume", "stop", "status", "list",
    ]

    /// Subcommands that (re)activate exposure, and so are refused under a
    /// sandbox confinement profile — `main.rs:296-309`.
    public static let activatingActions: Set<String> = ["start", "restart", "resume"]

    public static func handles(_ command: CLICommand) -> Bool {
        if case .utility(let options) = command, options.name == routeName {
            return true
        }
        return false
    }

    /// Launcher entry point, matching `LiveMCPComposition.session`.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        routeDependencies: LiveWorkspaceRouteDependencies = .production()
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, options.name == routeName else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        let sandboxProfile = OpenGrokSandbox.configuredProfile()
        if let rawAction = options.values.first {
            let action = rawAction == "list" ? "status" : rawAction
            try enforceSandboxProfile(action: action, profile: sandboxProfile)
        }
        let remoteSettings: RemoteSettings?
        if workspaceCommandEnvironmentOverride(context.environment) == nil {
            remoteSettings = await routeDependencies.loadRemoteSettings(context.environment)
        } else {
            remoteSettings = nil
        }
        try await run(
            options: options,
            environment: context.environment,
            streams: context.streams,
            sandboxProfile: sandboxProfile,
            remoteSettings: remoteSettings,
            connect: routeDependencies.connect
        )
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    // MARK: Preflight

    /// The gate chain from `run_workspace_mgmt` (`main.rs:295-331`), in
    /// upstream's order. Throws the first refusal; returns on success.
    ///
    /// Order is load-bearing: the sandbox refusal precedes the feature gate
    /// so a confined session is told it is confined rather than being told
    /// its account lacks a flag.
    public static func preflight(
        action: String,
        environment: [String: String],
        sandboxProfile: String?,
        remoteSettings: RemoteSettings?
    ) throws {
        try enforceSandboxProfile(action: action, profile: sandboxProfile)

        let override = workspaceCommandEnvironmentOverride(environment)
        // `main.rs:311-315`: the remote fetch is skipped entirely when the
        // env override decides, so an offline user with the override set is
        // not blocked on a network round trip.
        let settings = override == nil ? remoteSettings : nil

        switch workspaceCommandGate(environmentOverride: override, remoteSettings: settings) {
        case .enabled:
            return
        case .disabled:
            throw WorkspaceRouteError(
                "`open-grok workspace` is not enabled for this account "
                    + "(gated by a server-side feature flag that is currently off)."
            )
        case .unknown:
            throw WorkspaceRouteError(
                "Could not load your settings for `open-grok workspace`. Check your "
                    + "network connection (run `open-grok login` if you are signed "
                    + "out), then try again."
            )
        }
    }

    private static func enforceSandboxProfile(action: String, profile: String?) throws {
        if activatingActions.contains(action), let profile {
            throw WorkspaceRouteError(
                "`open-grok workspace` start/restart/resume is unavailable under "
                    + "sandbox profile '\(profile)': those commands (re)activate "
                    + "shared-leader workspace exposure that this session cannot "
                    + "prove is confined by that profile. Disable the profile at "
                    + "the source that selected it (CLI, env, config, or a managed "
                    + "requirement)."
            )
        }
    }

    // MARK: Run

    /// Execute one `workspace` invocation.
    ///
    /// `connect` is injected so the whole route is exercisable against an
    /// in-process leader; the production default dials the real socket.
    public static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        sandboxProfile: String? = OpenGrokSandbox.configuredProfile(),
        remoteSettings: RemoteSettings? = nil,
        connect: (@Sendable ([String: String]) async throws -> any WorkspaceControlChannel)? = nil
    ) async throws {
        // `cli.rs:206`: bare `workspace` is not a thing upstream — clap
        // requires a subcommand — and `status` is the documented default
        // nowhere, so an empty action is a usage error, not a silent status.
        guard let rawAction = options.values.first else {
            throw WorkspaceRouteError(
                "`open-grok workspace` requires a subcommand: "
                    + actions.sorted().joined(separator: ", ")
            )
        }
        // `list` is an alias, not a distinct command (`cli.rs:206`).
        let action = rawAction == "list" ? "status" : rawAction

        try preflight(
            action: action,
            environment: environment,
            sandboxProfile: sandboxProfile,
            remoteSettings: remoteSettings
        )

        let command: WorkspaceControlCommand
        switch action {
        case "start", "restart":
            command = .start(
                hubURL: options.options["--hub-url"],
                cwd: try resolveCwd(options.options["--cwd"], environment: environment)
            )
        case "pause": command = .pause
        case "resume": command = .resume
        case "stop": command = .stop
        case "status": command = .status
        default:
            throw WorkspaceRouteError(
                "unknown `workspace` subcommand '\(rawAction)': "
                    + actions.sorted().joined(separator: ", ")
            )
        }

        // `main.rs:422-431` — start/restart additionally require leader mode
        // before anything is dialled, because the exposure lives in the
        // leader and a non-leader session has nowhere to put it.
        if action == "start" || action == "restart" {
            try requireLeaderMode(options: options)
        }

        var leaderEnvironment = environment
        if let socketOverride = options.common.leaderSocket, !socketOverride.isEmpty {
            leaderEnvironment[ACPLeaderSocketPaths.socketEnvironmentVariable] = socketOverride
        }
        let channel = try await (connect ?? Self.dialLeader)(leaderEnvironment)
        defer { Task { await channel.close() } }

        try ensureWorkspaceCapabilities(channel.advertisedCapabilities)

        // `main.rs:451`: restart is stop-then-start, and the stop's failure is
        // deliberately ignored upstream (`let _ = ...`) — a workspace that was
        // not running is not a reason to refuse to start one.
        if action == "restart" {
            _ = try? await channel.send(.stop)
        }

        let payload = try await channel.send(command)
        renderStatus(payload, json: options.json, streams: streams)
    }

    /// `main.rs:422-431`.
    private static func requireLeaderMode(options: CLIUtilityOptions) throws {
        if options.isSet("--no-leader") {
            throw WorkspaceRouteError(
                "`open-grok workspace` requires leader mode (the workspace is "
                    + "shared via the leader).\nEnable it with `[cli] use_leader = "
                    + "true` in ~/.opengrok/config.toml, or pass --leader."
            )
        }
    }

    /// `main.rs:453-458`. Defaults to the process cwd, then absolutises.
    private static func resolveCwd(
        _ requested: String?,
        environment: [String: String]
    ) throws -> String {
        let raw = requested ?? FileManager.default.currentDirectoryPath
        guard !raw.isEmpty else {
            throw WorkspaceRouteError("cannot determine current directory")
        }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    // MARK: Rendering

    /// `main.rs:468-514` (`render_workspace_payload`), field for field.
    public static func renderStatus(
        _ payload: WorkspaceStatusPayload,
        json: Bool,
        streams: CLIStreams
    ) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(payload),
               let text = String(data: data, encoding: .utf8)
            {
                streams.out(text + "\n")
            }
            return
        }

        if payload.state == "none" {
            streams.out(
                "Workspace exposure: not running (leader PID \(payload.pid))\n"
            )
            return
        }

        var out = "Workspace exposure: \(payload.state)\n"
        if let url = payload.hubURL { out += "  hub:      \(url)\n" }
        if let dir = payload.cwd { out += "  cwd:      \(dir)\n" }
        out += "  uptime:   \(payload.uptimeMs / 1000)s\n"
        out += "  active:   \(payload.activeToolCalls) tool call(s)\n"
        let list = payload.sessions.isEmpty ? "-" : payload.sessions.joined(separator: ", ")
        out += "  sessions: \(payload.sessions.count) (\(list))\n"
        out += "  leader:   PID \(payload.pid)\n"
        streams.out(out)
    }

    // MARK: Real leader dial

    /// `main.rs:363-386` (`connect_workspace_control`).
    @Sendable
    static func dialLeader(
        environment: [String: String]
    ) async throws -> any WorkspaceControlChannel {
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let paths = ACPLeaderSocketPaths.resolve(
            openGrokHome: home,
            relayURL: environment["GROK_WS_URL"],
            environment: environment
        )
        do {
            let channel = try await ACPLeaderSocketDialer.connect(path: paths.socket)
            return try await LeaderWorkspaceControlChannel.register(channel: channel)
        } catch let error as WorkspaceRouteError {
            throw error
        } catch {
            throw WorkspaceRouteError(
                "no running leader for this environment (\(error)). "
                    + "Start an open-grok session, or run `open-grok workspace start`."
            )
        }
    }
}

// MARK: - Leader-backed channel

/// Workspace control uses the same production leader client as pager launches.
/// Keeping one reader loop prevents ACP notifications from racing control
/// replies on this mixed-purpose socket.
public final class LeaderWorkspaceControlChannel: WorkspaceControlChannel, @unchecked Sendable {
    public let advertisedCapabilities: ACPLeaderCapabilities?

    private let client: ACPLeaderClient

    private init(
        client: ACPLeaderClient,
        capabilities: ACPLeaderCapabilities?
    ) {
        self.client = client
        self.advertisedCapabilities = capabilities
    }

    /// Perform the `register` handshake and capture the advertised
    /// capabilities from the `registered` reply.
    public static func register(
        channel: any WebSocketByteChannel,
        clientType: String = "grok-workspace-cli"
    ) async throws -> LeaderWorkspaceControlChannel {
        let client = ACPLeaderClient(
            channel: channel,
            clientType: clientType,
            mode: .stdio,
            capabilities: ACPLeaderClientCapabilities()
        )
        do {
            let registration = try await client.start()
            return LeaderWorkspaceControlChannel(
                client: client,
                capabilities: registration.capabilities
            )
        } catch {
            await client.close()
            throw WorkspaceRouteError(String(describing: error))
        }
    }

    public func send(
        _ command: WorkspaceControlCommand
    ) async throws -> WorkspaceStatusPayload {
        let payload: ACPLeaderControlPayload
        do {
            payload = try await client.control(command.wire)
        } catch {
            throw WorkspaceRouteError(String(describing: error))
        }
        guard case .workspaceStatus(let status) = payload else {
            throw WorkspaceRouteError(
                "the leader answered `workspace \(command.wire["command"] ?? "?")` "
                    + "with an unexpected payload: \(payload)"
            )
        }
        return WorkspaceStatusPayload(
            state: status.state,
            hubURL: status.hubURL,
            cwd: status.cwd,
            uptimeMs: status.uptimeMs,
            activeToolCalls: Int(status.activeToolCalls),
            sessions: status.sessions,
            pid: Int(status.pid)
        )
    }

    public func close() async {
        await client.close()
    }
}

// MARK: - Hub session MCP bridge (Rust direction)

/// Result of bridging local MCP clients onto a hub session.
public struct LiveHubSessionMCPStartResult: Sendable {
    public var started: [String]
    public var failed: [(name: String, error: String)]

    public init(started: [String] = [], failed: [(name: String, error: String)] = []) {
        self.started = started
        self.failed = failed
    }
}

/// Bridges local MCP clients onto the hub tool server for one session.
///
/// Rust reference: `handle.rs:start_session_mcp_servers` and
/// `mcp.rs:McpClientTransportAdapter` / `QualifiedMcpToolHandler`.
///
/// This is the inverse of [`HubMCPBridgeCoordinator`], which registers hub
/// tools into a local `FinalizedToolset` and is kept as a loopback harness.
public enum LiveHubSessionMCP {
    public final class Handle: @unchecked Sendable {
        fileprivate var bridges: [McpBridge] = []
        fileprivate var registeredToolIds: [ToolId] = []
        private let lock = NSLock()

        public var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return bridges.isEmpty && registeredToolIds.isEmpty
        }

        fileprivate func append(bridge: McpBridge, toolIds: [ToolId]) {
            lock.lock()
            bridges.append(bridge)
            registeredToolIds.append(contentsOf: toolIds)
            lock.unlock()
        }

        fileprivate func snapshot() -> (bridges: [McpBridge], toolIds: [ToolId]) {
            lock.lock()
            defer { lock.unlock() }
            return (bridges, registeredToolIds)
        }
    }

    /// Connect each live MCP client, discover tools, and register qualified
    /// handlers on `harness.local` for `sessionId`.
    ///
    /// With no clients, or when every bridge fails, returns an empty handle
    /// and leaves the harness unchanged apart from successful registrations.
    @discardableResult
    public static func start(
        sessionId: SessionId,
        clients: [HubMCPClientEntry],
        harness: ToolHarness,
        mediation: HubMediation,
        principal: Principal
    ) async -> (handle: Handle, result: LiveHubSessionMCPStartResult) {
        guard !clients.isEmpty else {
            return (Handle(), LiveHubSessionMCPStartResult())
        }

        let handle = Handle()
        var started: [String] = []
        var failed: [(name: String, error: String)] = []

        for entry in clients {
            let transport = MCPClientTransportAdapter(client: entry.client)
            let config = McpBridgeConfig(
                sessionId: sessionId,
                mediation: mediation,
                namespace: entry.serverName
            )
            do {
                let bridgeHandle = try await McpBridge.connect(transport, config)
                let bridge = bridgeHandle.bridge
                var toolIds: [ToolId] = []
                for handler in bridge.handlers() {
                    guard let qualifiedName = qualifiedMCPToolName(
                        server: entry.serverName,
                        tool: handler.definition.name
                    ) else {
                        continue
                    }
                    guard let qualifiedId = try? ToolId(qualifiedName) else { continue }

                    let tool = QualifiedHubMcpTool(
                        qualifiedId: qualifiedId,
                        qualifiedName: qualifiedName,
                        inner: handler
                    )
                    let descriptionText = handler.definition.description
                        ?? "MCP tool '\(handler.definition.name)' on '\(entry.serverName)'"
                    let registration = ToolRegistration(
                        toolId: qualifiedId,
                        sessions: [sessionId],
                        userId: principal.userId,
                        description: ToolDescription(name: qualifiedName, description: descriptionText),
                        inputSchema: handler.definition.inputSchema,
                        transportKind: .local
                    )
                    harness.local.registerDyn(tool, registration: registration)
                    toolIds.append(qualifiedId)
                }
                handle.append(bridge: bridge, toolIds: toolIds)
                started.append(entry.serverName)
            } catch {
                failed.append((name: entry.serverName, error: String(describing: error)))
            }
        }

        return (handle, LiveHubSessionMCPStartResult(started: started, failed: failed))
    }

    /// Unregister every tool this session bridge contributed and shut down
    /// retained transports. Safe when the handle is empty.
    public static func stop(_ handle: Handle, harness: ToolHarness) async {
        let snapshot = handle.snapshot()
        for toolId in snapshot.toolIds {
            harness.local.unregister(toolId)
        }
        for bridge in snapshot.bridges {
            try? await bridge.shutdown()
        }
    }
}

/// Wraps an adapter [`McpToolHandler`] with a qualified `server__tool` id for
/// hub registration.
struct QualifiedHubMcpTool: ToolDyn {
    let qualifiedId: ToolId
    let qualifiedName: String
    let inner: McpToolHandler

    func id() -> ToolId { qualifiedId }

    func description(ctx: ListToolsContext) -> ToolDescription {
        var description = inner.description(ctx: ctx)
        description.name = qualifiedName
        return description
    }

    func capabilities() -> ToolCapabilities {
        inner.capabilities()
    }

    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        await inner.execute(ctx: ctx, args: args)
    }
}

// MARK: - Hub MCP bridge coordinator

/// Manages the lifecycle of MCP tools bridged from a Computer Hub session.
///
/// Tools are registered into the retained toolset only when a live hub
/// connection exists; `disconnect` removes them. The bridge's
/// `McpBridgeConfig.mediation` gates every call before it leaves the
/// process, so a `disconnect` racing an in-flight call still denies
/// rather than dispatching against a torn-down transport.
///
/// Rust reference: `crates/codegen/xai-grok-workspace/src/mcp.rs:3-22`
/// (transport adapter) and `:33` onward (bridge lifecycle).
public final class HubMCPBridgeCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var activeBridge: McpBridge?
    private var activeServerName: String?

    public init() {}

    /// The server name tools are registered under, or `nil` when no hub is
    /// connected.
    public var serverName: String? {
        lock.lock(); defer { lock.unlock() }
        return activeServerName
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeBridge != nil
    }

    /// Connect to a hub's MCP transport, discover tools, and register them
    /// into `toolset`. Returns the qualified names that were registered, or
    /// an empty array when no usable tools were discovered.
    ///
    /// Calling `connect` while already connected is a programming error on
    /// the caller's side; the previous bridge is shut down first so the
    /// toolset never accumulates stale entries.
    @discardableResult
    public func connect(
        transport: any McpTransport,
        config: McpBridgeConfig,
        toolset: FinalizedToolset
    ) async throws -> [String] {
        if isConnected {
            await disconnect(toolset: toolset)
        }

        let handle = try await McpBridge.connect(transport, config)
        let bridge = handle.bridge
        let name = handle.serverInfo.name

        let registered = Self.registerHandlers(
            bridge: bridge,
            serverName: name,
            toolset: toolset
        )

        // NSLock is sync-only under Swift 6; keep the critical section off
        // the async function body.
        installActive(bridge: bridge, serverName: name)
        return registered
    }

    /// Unregister every tool this bridge contributed and shut down the
    /// transport. Safe to call when already disconnected.
    public func disconnect(toolset: FinalizedToolset) async {
        let snapshot = takeActive()
        if let name = snapshot.serverName {
            MCPToolBridge.unregister(server: name, from: toolset)
        }
        if let bridge = snapshot.bridge {
            try? await bridge.shutdown()
        }
    }

    /// Names currently registered by this bridge in `toolset`.
    public func registeredNames(in toolset: FinalizedToolset) -> [String] {
        guard let name = serverName else { return [] }
        return MCPToolBridge.registeredNames(for: name, in: toolset)
    }

    private func installActive(bridge: McpBridge, serverName: String) {
        lock.lock()
        activeBridge = bridge
        activeServerName = serverName
        lock.unlock()
    }

    private func takeActive() -> (bridge: McpBridge?, serverName: String?) {
        lock.lock()
        defer { lock.unlock() }
        let bridge = activeBridge
        let name = activeServerName
        activeBridge = nil
        activeServerName = nil
        return (bridge, name)
    }

    // MARK: - Registration

    /// Create `FinalizedTool` entries from the bridge's handlers and
    /// register them into the toolset. Each handler already carries the
    /// `McpBridgeConfig.mediation` gate; the `HubBridgedMcpHandler`
    /// wrapper routes through `McpToolHandler.execute`, so every call is
    /// mediated.
    static func registerHandlers(
        bridge: McpBridge,
        serverName: String,
        toolset: FinalizedToolset
    ) -> [String] {
        var registered: [String] = []
        for handler in bridge.handlers() {
            let tool = handler.definition
            guard let clientName = qualifiedMCPToolName(
                server: serverName, tool: tool.name
            ) else {
                continue
            }
            guard (try? ToolId(clientName)) != nil else { continue }

            let desc = tool.description ?? "Hub MCP tool '\(tool.name)' on '\(serverName)'"
            var definition = ToolDescription(name: clientName, description: desc)
                .withKind(ProductToolKind.other.rawValue)
                .withNamespace(ProductToolNamespace.mcp.rawValue)
            if let schema = tool.inputSchema {
                definition = definition.withArgumentsSchema(schema)
            }

            toolset.registerDynamic(FinalizedTool(
                qualifiedId: "\(ProductToolNamespace.mcp.displayName):\(clientName)",
                namespace: .mcp,
                id: clientName,
                clientName: clientName,
                kind: .other,
                description: desc,
                definition: definition,
                inputSchema: tool.inputSchema ?? .object(["type": .string("object")]),
                reverseParams: [:],
                contractVersion: nil,
                visibility: .topLevel,
                exposure: .ordinary,
                handler: HubBridgedMcpHandler(inner: handler)
            ))
            registered.append(clientName)
        }
        return registered
    }
}

/// Adapts the hub adapter's `McpToolHandler` to the registry's
/// `ToolHandler` protocol, preserving the built-in mediation gate.
///
/// The call chain: `FinalizedToolset` dispatches → `invoke` here →
/// `McpToolHandler.execute` (which runs `mediation.admit` before
/// touching the transport) → terminal stream result.
struct HubBridgedMcpHandler: ToolHandler {
    let inner: McpToolHandler

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = (clientName, resources)
        return await consumeStreamTerminal(
            await inner.execute(ctx: ctx, args: args)
        )
    }
}
