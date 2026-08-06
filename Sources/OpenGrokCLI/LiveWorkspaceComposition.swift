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
import OpenGrokComputerHubCore
import OpenGrokComputerHubSDK
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokSandbox
import OpenGrokShared
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
    guard let remoteSettings else { return .unknown }
    return (remoteSettings.workspaceCommandEnabled ?? false) ? .enabled : .disabled
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
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, options.name == routeName else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try await run(options: options, environment: context.environment, streams: context.streams)
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
        if activatingActions.contains(action), let profile = sandboxProfile {
            throw WorkspaceRouteError(
                "`open-grok workspace` start/restart/resume is unavailable under "
                    + "sandbox profile '\(profile)': those commands (re)activate "
                    + "shared-leader workspace exposure that this session cannot "
                    + "prove is confined by that profile. Disable the profile at "
                    + "the source that selected it (CLI, env, config, or a managed "
                    + "requirement)."
            )
        }

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

        let channel = try await (connect ?? Self.dialLeader)(environment)
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
    private static func dialLeader(
        environment: [String: String]
    ) async throws -> any WorkspaceControlChannel {
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let paths = ACPLeaderSocketPaths.resolve(
            openGrokHome: home,
            relayURL: environment["GROK_WS_URL"],
            environment: environment
        )
        do {
            let channel = try await UnixSocketDialer.connect(path: paths.socket.path)
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

/// Speaks the leader IPC framing directly: this port has no `LeaderClient`
/// (the Rust type at `leader/client.rs`), only the socket dialer and the
/// frame codec, so the register/control exchange is assembled here.
public final class LeaderWorkspaceControlChannel: WorkspaceControlChannel, @unchecked Sendable {
    public let advertisedCapabilities: ACPLeaderCapabilities?

    private let channel: any WebSocketByteChannel
    private let lock = NSLock()
    private var decoder = ACPLeaderFrameDecoder()

    private init(
        channel: any WebSocketByteChannel,
        capabilities: ACPLeaderCapabilities?
    ) {
        self.channel = channel
        self.advertisedCapabilities = capabilities
    }

    /// Perform the `register` handshake and capture the advertised
    /// capabilities from the `registered` reply.
    public static func register(
        channel: any WebSocketByteChannel,
        clientType: String = "grok-workspace-cli"
    ) async throws -> LeaderWorkspaceControlChannel {
        let pending = LeaderWorkspaceControlChannel(channel: channel, capabilities: nil)
        try await pending.write(
            .register(
                clientType: clientType,
                mode: .stdio,
                capabilities: ACPLeaderClientCapabilities()
            )
        )
        guard let reply = try await pending.readMessage() else {
            throw WorkspaceRouteError(
                "the leader closed the connection during registration"
            )
        }
        guard case .registered(_, _, _, _, let capabilities) = reply else {
            throw WorkspaceRouteError(
                "unexpected leader reply to register: \(reply)"
            )
        }
        return LeaderWorkspaceControlChannel(channel: channel, capabilities: capabilities)
    }

    public func send(
        _ command: WorkspaceControlCommand
    ) async throws -> WorkspaceStatusPayload {
        let requestID = UUID().uuidString
        try await write(.control(requestID: requestID, command: command.wire))

        // Skip frames that are not the answer to this request: the leader
        // multiplexes ACP traffic onto the same socket, so an unrelated
        // frame arriving first must not be mistaken for our reply.
        while let message = try await readMessage() {
            switch message {
            case .controlResult(let id, let payload) where id == requestID:
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
            case .controlError(let id, let code, let text) where id == requestID:
                throw WorkspaceRouteError(
                    "the leader refused `workspace \(command.wire["command"] ?? "?")` "
                        + "(code \(code)): \(text)"
                )
            case .shuttingDown, .shutdown:
                throw WorkspaceRouteError("the leader shut down before answering")
            case .error(let code, let text):
                throw WorkspaceRouteError("leader error \(code): \(text)")
            default:
                continue
            }
        }
        throw WorkspaceRouteError(
            "the leader closed the connection without answering `workspace "
                + "\(command.wire["command"] ?? "?")`"
        )
    }

    public func close() async {
        await channel.close()
    }

    private func write(_ message: ACPLeaderClientMessage) async throws {
        try await channel.write(try ACPLeaderCodec.encode(message))
    }

    private func readMessage() async throws -> ACPLeaderServerMessage? {
        while true {
            if let body = try nextBufferedFrame() {
                return try ACPLeaderCodec.decode(ACPLeaderServerMessage.self, from: body)
            }
            guard let bytes = try await channel.read(), !bytes.isEmpty else { return nil }
            buffer(bytes)
        }
    }

    private func buffer(_ bytes: [UInt8]) {
        lock.lock()
        decoder.append(bytes)
        lock.unlock()
    }

    private func nextBufferedFrame() throws -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return try decoder.nextFrame()
    }
}
