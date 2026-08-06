// ACPLeaderProtocol.swift
//
// The leader IPC envelope: length-prefixed JSON frames carrying `ClientMessage`
// / `ServerMessage`, so several local clients can share one agent process.
//
// This is deliberately transport-free. Upstream runs it over a Unix domain
// socket (or a named pipe on Windows), but nothing in the envelope depends on
// that, and keeping it separate is what lets the whole control plane be tested
// over an in-memory pipe.
//
// Rust reference: `crates/codegen/xai-grok-shell/src/leader/protocol.rs` —
// framing at :8-75, `ClientMessage` at :290-309, `ServerMessage` at :340-394,
// `ClientCapabilities` at :127-172, `LeaderCapabilities` at :174-191.
//
// Note the two structs use *different* serde conventions upstream and that is
// load-bearing: `ClientCapabilities` has no `rename_all`, so its wire keys are
// the snake_case Rust field names; `LeaderCapabilities` is explicitly
// `rename_all = "snake_case"`, which lands on the same spelling. They agree by
// coincidence, not by rule, so both are pinned by tests here.

import Foundation

// MARK: - Errors

public enum ACPLeaderProtocolError: Error, Sendable, Hashable, CustomStringConvertible {
    case messageTooLarge(bytes: Int, limit: Int)
    case connectionClosed
    case invalidJSON(String)
    case unknownMessageType(String)
    case missingField(String)

    public var description: String {
        switch self {
        case .messageTooLarge(let bytes, let limit):
            return "leader IPC frame of \(bytes) bytes exceeds the \(limit) byte limit"
        case .connectionClosed:
            return "leader IPC connection closed"
        case .invalidJSON(let detail):
            return "leader IPC frame was not valid JSON: \(detail)"
        case .unknownMessageType(let type):
            return "unknown leader IPC message type `\(type)`"
        case .missingField(let field):
            return "leader IPC message is missing required field `\(field)`"
        }
    }
}

// MARK: - Constants

public enum ACPLeaderProtocolLimits {
    /// `protocol.rs:8` — `MAX_MESSAGE_SIZE: u32 = 64 * 1024 * 1024`.
    public static let maximumMessageSize = 64 * 1024 * 1024
    /// `protocol.rs:125` — `LEADER_PROTOCOL_VERSION: u32 = 1`.
    public static let protocolVersion: UInt32 = 1
    /// `server.rs:38` — the client id / request id namespace separator.
    public static let idNamespaceSeparator: Character = "|"
}

// MARK: - Framing

/// 4-byte big-endian length prefix plus a JSON body.
///
/// Incremental by construction: `append` takes whatever a read returned and
/// `nextFrame` yields only complete frames, because a socket read has no
/// obligation to align with a frame boundary in either direction.
public struct ACPLeaderFrameDecoder: Sendable {
    public let maximumMessageSize: Int
    private var buffer: [UInt8] = []

    public init(maximumMessageSize: Int = ACPLeaderProtocolLimits.maximumMessageSize) {
        self.maximumMessageSize = maximumMessageSize
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete body, or `nil` when more bytes are needed.
    ///
    /// An oversized length throws rather than skipping the frame: a length that
    /// large means the stream is already desynchronised, and scanning forward
    /// for a plausible next header is how a desync becomes silent corruption.
    public mutating func nextFrame() throws -> [UInt8]? {
        guard buffer.count >= 4 else { return nil }
        let length =
            Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
        guard length <= maximumMessageSize else {
            throw ACPLeaderProtocolError.messageTooLarge(
                bytes: length,
                limit: maximumMessageSize
            )
        }
        guard buffer.count >= 4 + length else { return nil }
        let body = Array(buffer[4..<(4 + length)])
        buffer.removeFirst(4 + length)
        return body
    }
}

public enum ACPLeaderFrameEncoder {
    /// Prefix `body` with its big-endian length.
    public static func encode(
        _ body: [UInt8],
        maximumMessageSize: Int = ACPLeaderProtocolLimits.maximumMessageSize
    ) throws -> [UInt8] {
        guard body.count <= maximumMessageSize else {
            throw ACPLeaderProtocolError.messageTooLarge(
                bytes: body.count,
                limit: maximumMessageSize
            )
        }
        let length = UInt32(body.count)
        var out: [UInt8] = [
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ]
        out.append(contentsOf: body)
        return out
    }
}

// MARK: - Capabilities

/// `protocol.rs:110-119`. `headless` clients are relay-driven; `stdio` clients
/// are local IPC. The distinction is not cosmetic — only a headless
/// registration signals relay demand (`server.rs:1650-1665`).
public enum ACPLeaderClientMode: String, Sendable, Hashable, Codable {
    case headless
    case stdio
}

/// `protocol.rs:127-172`. Every field defaults, so an older client that omits
/// half of them still registers.
public struct ACPLeaderClientCapabilities: Sendable, Hashable, Codable {
    public var yoloMode: Bool
    public var autoMode: Bool
    public var defaultModel: String?
    public var clientVersion: String?
    public var codeNavEnabled: Bool
    public var terminal: Bool
    public var fsRead: Bool
    public var fsWrite: Bool

    private enum CodingKeys: String, CodingKey {
        case yoloMode = "yolo_mode"
        case autoMode = "auto_mode"
        case defaultModel = "default_model"
        case clientVersion = "client_version"
        case codeNavEnabled = "code_nav_enabled"
        case terminal
        case fsRead = "fs_read"
        case fsWrite = "fs_write"
    }

    public init(
        yoloMode: Bool = false,
        autoMode: Bool = false,
        defaultModel: String? = nil,
        clientVersion: String? = nil,
        codeNavEnabled: Bool = false,
        terminal: Bool = false,
        fsRead: Bool = false,
        fsWrite: Bool = false
    ) {
        self.yoloMode = yoloMode
        self.autoMode = autoMode
        self.defaultModel = defaultModel
        self.clientVersion = clientVersion
        self.codeNavEnabled = codeNavEnabled
        self.terminal = terminal
        self.fsRead = fsRead
        self.fsWrite = fsWrite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        yoloMode = try container.decodeIfPresent(Bool.self, forKey: .yoloMode) ?? false
        autoMode = try container.decodeIfPresent(Bool.self, forKey: .autoMode) ?? false
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion)
        codeNavEnabled = try container.decodeIfPresent(Bool.self, forKey: .codeNavEnabled) ?? false
        terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        fsRead = try container.decodeIfPresent(Bool.self, forKey: .fsRead) ?? false
        fsWrite = try container.decodeIfPresent(Bool.self, forKey: .fsWrite) ?? false
    }
}

/// `protocol.rs:174-191`. Only the flags this port can honestly claim are
/// settable; `control_v1` gates the whole control plane client-side
/// (`client.rs:187-240`), so claiming it without implementing the commands
/// would turn a clean `UnsupportedControl` into a hang. `control_v1` and
/// `workspace_exposure` are claimed: `get_leader_info` and the workspace
/// control commands are implemented (`ACPLeaderControlPlane`). CPU profiling
/// and relaunch-for-update are not, stay unclaimed, and are refused with
/// typed errors rather than answered.
public struct ACPLeaderCapabilities: Sendable, Hashable, Codable {
    public var controlV1: Bool
    public var runtimeCPUProfile: Bool
    public var profileFormats: [String]
    public var workspaceExposure: Bool
    public var relaunchV1: Bool

    private enum CodingKeys: String, CodingKey {
        case controlV1 = "control_v1"
        case runtimeCPUProfile = "runtime_cpu_profile"
        case profileFormats = "profile_formats"
        case workspaceExposure = "workspace_exposure"
        case relaunchV1 = "relaunch_v1"
    }

    public init(
        controlV1: Bool = false,
        runtimeCPUProfile: Bool = false,
        profileFormats: [String] = [],
        workspaceExposure: Bool = false,
        relaunchV1: Bool = false
    ) {
        self.controlV1 = controlV1
        self.runtimeCPUProfile = runtimeCPUProfile
        self.profileFormats = profileFormats
        self.workspaceExposure = workspaceExposure
        self.relaunchV1 = relaunchV1
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        controlV1 = try container.decodeIfPresent(Bool.self, forKey: .controlV1) ?? false
        runtimeCPUProfile =
            try container.decodeIfPresent(Bool.self, forKey: .runtimeCPUProfile) ?? false
        profileFormats = try container.decodeIfPresent([String].self, forKey: .profileFormats) ?? []
        workspaceExposure =
            try container.decodeIfPresent(Bool.self, forKey: .workspaceExposure) ?? false
        relaunchV1 = try container.decodeIfPresent(Bool.self, forKey: .relaunchV1) ?? false
    }

    /// What this port actually supports. Upstream advertises `control_v1` and
    /// `workspace_exposure` unconditionally because the feature is in the
    /// binary (`server.rs:153-160`); both are set here for the same reason now
    /// that `ACPLeaderControlPlane` exists. `runtime_cpu_profile` stays false
    /// — the port has no profiler where upstream compiles one in on unix
    /// (`cpu_profile.rs:650-655`) — and `relaunch_v1` stays false, which
    /// upstream clients degrade on gracefully by advising a manual restart
    /// (`protocol.rs:185-190`). `profile_formats` is empty on both sides
    /// (`cpu_profile.rs:658-664`).
    public static let supported = ACPLeaderCapabilities(
        controlV1: true,
        workspaceExposure: true
    )
}

/// `protocol.rs:320-332`.
public enum ACPLeaderShutdownReason: String, Sendable, Hashable, Codable {
    case autoUpdate = "auto_update"
    case idleTimeout = "idle_timeout"
    case manual
}

// MARK: - Control payloads

/// `protocol.rs:265-276` — `ControlPayload::WorkspaceStatus`: the leader's
/// report on the shared workspace exposure.
///
/// Absent optionals encode as explicit `null`, not omitted keys: serde marks
/// `hub_url`/`cwd`/`sessions` `#[serde(default)]` but has no
/// `skip_serializing_if`, and the Rust goldens pin the nulls
/// (`protocol.rs:735-747`). Each payload struct writes its own serde tag on
/// encode — serde internally tags the enum (`protocol.rs:227-229`) — and
/// ignores it on decode; `ACPLeaderControlPayload` is the tagged entry point.
public struct ACPLeaderWorkspaceStatus: Sendable, Hashable {
    public var state: String
    public var hubURL: String?
    public var cwd: String?
    public var uptimeMs: UInt64
    public var activeToolCalls: UInt32
    public var sessions: [String]
    public var pid: UInt32

    public init(
        state: String,
        hubURL: String? = nil,
        cwd: String? = nil,
        uptimeMs: UInt64 = 0,
        activeToolCalls: UInt32 = 0,
        sessions: [String] = [],
        pid: UInt32
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

extension ACPLeaderWorkspaceStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case state
        case hubURL = "hub_url"
        case cwd
        case uptimeMs = "uptime_ms"
        case activeToolCalls = "active_tool_calls"
        case sessions
        case pid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        hubURL = try container.decodeIfPresent(String.self, forKey: .hubURL)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        uptimeMs = try container.decodeIfPresent(UInt64.self, forKey: .uptimeMs) ?? 0
        activeToolCalls = try container.decodeIfPresent(UInt32.self, forKey: .activeToolCalls) ?? 0
        sessions = try container.decodeIfPresent([String].self, forKey: .sessions) ?? []
        pid = try container.decode(UInt32.self, forKey: .pid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("workspace_status", forKey: .type)
        try container.encode(state, forKey: .state)
        if let hubURL {
            try container.encode(hubURL, forKey: .hubURL)
        } else {
            try container.encodeNil(forKey: .hubURL)
        }
        if let cwd {
            try container.encode(cwd, forKey: .cwd)
        } else {
            try container.encodeNil(forKey: .cwd)
        }
        try container.encode(uptimeMs, forKey: .uptimeMs)
        try container.encode(activeToolCalls, forKey: .activeToolCalls)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(pid, forKey: .pid)
    }
}

/// `protocol.rs:230-243` — `ControlPayload::LeaderInfo`: what the leader is
/// and where it listens, plus the profiling facts of this build.
public struct ACPLeaderInfo: Sendable, Hashable {
    public var pid: UInt32
    public var socketPath: String
    public var lockPath: String
    public var wsURLSuffix: String
    public var leaderProtocolVersion: UInt32
    public var leaderBinaryVersion: String
    public var profilingSupported: Bool
    public var profilingCompiledIn: Bool
    public var cpuProfileActive: Bool
    public var cpuProfileStopping: Bool
    public var profileStartedAt: String?
    public var profileFormats: [String]

    public init(
        pid: UInt32,
        socketPath: String,
        lockPath: String,
        wsURLSuffix: String,
        leaderProtocolVersion: UInt32,
        leaderBinaryVersion: String,
        profilingSupported: Bool = false,
        profilingCompiledIn: Bool = false,
        cpuProfileActive: Bool = false,
        cpuProfileStopping: Bool = false,
        profileStartedAt: String? = nil,
        profileFormats: [String] = []
    ) {
        self.pid = pid
        self.socketPath = socketPath
        self.lockPath = lockPath
        self.wsURLSuffix = wsURLSuffix
        self.leaderProtocolVersion = leaderProtocolVersion
        self.leaderBinaryVersion = leaderBinaryVersion
        self.profilingSupported = profilingSupported
        self.profilingCompiledIn = profilingCompiledIn
        self.cpuProfileActive = cpuProfileActive
        self.cpuProfileStopping = cpuProfileStopping
        self.profileStartedAt = profileStartedAt
        self.profileFormats = profileFormats
    }
}

extension ACPLeaderInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case pid
        case socketPath = "socket_path"
        case lockPath = "lock_path"
        case wsURLSuffix = "ws_url_suffix"
        case leaderProtocolVersion = "leader_protocol_version"
        case leaderBinaryVersion = "leader_binary_version"
        case profilingSupported = "profiling_supported"
        case profilingCompiledIn = "profiling_compiled_in"
        case cpuProfileActive = "cpu_profile_active"
        case cpuProfileStopping = "cpu_profile_stopping"
        case profileStartedAt = "profile_started_at"
        case profileFormats = "profile_formats"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(UInt32.self, forKey: .pid)
        socketPath = try container.decode(String.self, forKey: .socketPath)
        lockPath = try container.decode(String.self, forKey: .lockPath)
        wsURLSuffix = try container.decode(String.self, forKey: .wsURLSuffix)
        leaderProtocolVersion = try container.decode(UInt32.self, forKey: .leaderProtocolVersion)
        leaderBinaryVersion = try container.decode(String.self, forKey: .leaderBinaryVersion)
        profilingSupported = try container.decode(Bool.self, forKey: .profilingSupported)
        profilingCompiledIn = try container.decode(Bool.self, forKey: .profilingCompiledIn)
        cpuProfileActive = try container.decode(Bool.self, forKey: .cpuProfileActive)
        // `protocol.rs:240-242` — `cpu_profile_stopping` has `#[serde(default)]`
        // so an older leader's payload decodes; the others are required.
        cpuProfileStopping = try container.decodeIfPresent(Bool.self, forKey: .cpuProfileStopping) ?? false
        profileStartedAt = try container.decodeIfPresent(String.self, forKey: .profileStartedAt)
        profileFormats = try container.decodeIfPresent([String].self, forKey: .profileFormats) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("leader_info", forKey: .type)
        try container.encode(pid, forKey: .pid)
        try container.encode(socketPath, forKey: .socketPath)
        try container.encode(lockPath, forKey: .lockPath)
        try container.encode(wsURLSuffix, forKey: .wsURLSuffix)
        try container.encode(leaderProtocolVersion, forKey: .leaderProtocolVersion)
        try container.encode(leaderBinaryVersion, forKey: .leaderBinaryVersion)
        try container.encode(profilingSupported, forKey: .profilingSupported)
        try container.encode(profilingCompiledIn, forKey: .profilingCompiledIn)
        try container.encode(cpuProfileActive, forKey: .cpuProfileActive)
        try container.encode(cpuProfileStopping, forKey: .cpuProfileStopping)
        if let profileStartedAt {
            try container.encode(profileStartedAt, forKey: .profileStartedAt)
        } else {
            try container.encodeNil(forKey: .profileStartedAt)
        }
        try container.encode(profileFormats, forKey: .profileFormats)
    }
}

/// `protocol.rs:245-251` — `ControlPayload::CpuProfileStatus`. This build has
/// no profiler, so the only payload it ever produces is the all-inactive one;
/// the type exists so that answer is upstream-shaped rather than an error.
public struct ACPLeaderCpuProfileStatus: Sendable, Hashable {
    public var active: Bool
    public var stopping: Bool
    public var startedAt: String?
    public var svgPath: String?
    public var frequencyHz: Int32?

    public init(
        active: Bool = false,
        stopping: Bool = false,
        startedAt: String? = nil,
        svgPath: String? = nil,
        frequencyHz: Int32? = nil
    ) {
        self.active = active
        self.stopping = stopping
        self.startedAt = startedAt
        self.svgPath = svgPath
        self.frequencyHz = frequencyHz
    }
}

extension ACPLeaderCpuProfileStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case active
        case stopping
        case startedAt = "started_at"
        case svgPath = "svg_path"
        case frequencyHz = "frequency_hz"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decode(Bool.self, forKey: .active)
        stopping = try container.decodeIfPresent(Bool.self, forKey: .stopping) ?? false
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        svgPath = try container.decodeIfPresent(String.self, forKey: .svgPath)
        frequencyHz = try container.decodeIfPresent(Int32.self, forKey: .frequencyHz)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("cpu_profile_status", forKey: .type)
        try container.encode(active, forKey: .active)
        try container.encode(stopping, forKey: .stopping)
        if let startedAt {
            try container.encode(startedAt, forKey: .startedAt)
        } else {
            try container.encodeNil(forKey: .startedAt)
        }
        if let svgPath {
            try container.encode(svgPath, forKey: .svgPath)
        } else {
            try container.encodeNil(forKey: .svgPath)
        }
        if let frequencyHz {
            try container.encode(frequencyHz, forKey: .frequencyHz)
        } else {
            try container.encodeNil(forKey: .frequencyHz)
        }
    }
}

/// `protocol.rs:227-287` — the `Ok` half of a control result. Only the
/// variants this port can produce are modeled; a foreign payload fails to
/// decode rather than being approximated.
public enum ACPLeaderControlPayload: Sendable, Hashable {
    case leaderInfo(ACPLeaderInfo)
    case cpuProfileStatus(ACPLeaderCpuProfileStatus)
    case workspaceStatus(ACPLeaderWorkspaceStatus)
}

extension ACPLeaderControlPayload: Codable {
    private enum TypeKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "leader_info":
            self = .leaderInfo(try ACPLeaderInfo(from: decoder))
        case "cpu_profile_status":
            self = .cpuProfileStatus(try ACPLeaderCpuProfileStatus(from: decoder))
        case "workspace_status":
            self = .workspaceStatus(try ACPLeaderWorkspaceStatus(from: decoder))
        case let other:
            throw ACPLeaderProtocolError.unknownMessageType("control payload `\(other)`")
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Each struct writes its own tag: an encoder hands out one keyed
        // container per key type, so the enum cannot write `type` and then
        // delegate to a differently-keyed container on the same encoder.
        switch self {
        case .leaderInfo(let info):
            try info.encode(to: encoder)
        case .cpuProfileStatus(let status):
            try status.encode(to: encoder)
        case .workspaceStatus(let status):
            try status.encode(to: encoder)
        }
    }
}

// MARK: - Client -> leader

/// One scalar in a control frame. This port's own clients send strings only,
/// but upstream's typed `ControlCommand` encodes `frequency_hz` as a *number*
/// (`protocol.rs:198-202`), which a strict `[String: String]` decode would
/// reject whole-frame — wedging the connection rather than refusing the one
/// command. Tolerated here and flattened to its string spelling before
/// dispatch.
private enum ACPLeaderControlField: Decodable {
    case string(String)
    case number(Int64)
    case bool(Bool)

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        throw ACPLeaderProtocolError.invalidJSON(
            "control command fields must be strings, numbers or booleans"
        )
    }
}

public enum ACPLeaderClientMessage: Sendable, Hashable {
    case register(
        clientType: String,
        mode: ACPLeaderClientMode,
        capabilities: ACPLeaderClientCapabilities
    )
    /// One raw ACP JSON-RPC line. The client is a dumb pipe; the leader does
    /// all multiplexing (`client.rs:181-185`).
    case acp(payload: String)
    case control(requestID: String, command: [String: String])
    case ping
    case disconnect
}

extension ACPLeaderClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case clientType = "client_type"
        case mode
        case capabilities
        case payload
        case requestID = "request_id"
        case command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "register":
            self = .register(
                clientType: try container.decode(String.self, forKey: .clientType),
                mode: try container.decode(ACPLeaderClientMode.self, forKey: .mode),
                capabilities: try container.decodeIfPresent(
                    ACPLeaderClientCapabilities.self,
                    forKey: .capabilities
                ) ?? ACPLeaderClientCapabilities()
            )
        case "acp":
            self = .acp(payload: try container.decode(String.self, forKey: .payload))
        case "control":
            let fields = try container.decodeIfPresent(
                [String: ACPLeaderControlField].self,
                forKey: .command
            ) ?? [:]
            self = .control(
                requestID: try container.decode(String.self, forKey: .requestID),
                command: fields.mapValues(\.stringValue)
            )
        case "ping":
            self = .ping
        case "disconnect":
            self = .disconnect
        default:
            throw ACPLeaderProtocolError.unknownMessageType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register(let clientType, let mode, let capabilities):
            try container.encode("register", forKey: .type)
            try container.encode(clientType, forKey: .clientType)
            try container.encode(mode, forKey: .mode)
            try container.encode(capabilities, forKey: .capabilities)
        case .acp(let payload):
            try container.encode("acp", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .control(let requestID, let command):
            try container.encode("control", forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(command, forKey: .command)
        case .ping:
            try container.encode("ping", forKey: .type)
        case .disconnect:
            try container.encode("disconnect", forKey: .type)
        }
    }
}

// MARK: - Leader -> client

public enum ACPLeaderServerMessage: Sendable, Hashable {
    case registered(
        clientID: UInt64,
        ready: Bool,
        protocolVersion: UInt32?,
        binaryVersion: String?,
        capabilities: ACPLeaderCapabilities?
    )
    case acp(payload: String)
    /// The `Ok` half of a control result (`protocol.rs:364-367`); serde
    /// encodes `Result<ControlPayload, ControlError>` as `{"Ok": ...}` /
    /// `{"Err": ...}` under one `control_result` message type.
    case controlResult(requestID: String, payload: ACPLeaderControlPayload)
    case controlError(requestID: String, code: Int, message: String)
    case pong
    case error(code: Int, message: String)
    case shuttingDown(reason: ACPLeaderShutdownReason, delayMilliseconds: UInt64)
    case shutdown
    case leaderReady
}

extension ACPLeaderServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case clientID = "client_id"
        case ready
        case protocolVersion = "leader_protocol_version"
        case binaryVersion = "leader_binary_version"
        case capabilities = "leader_capabilities"
        case payload
        case requestID = "request_id"
        case result
        case code
        case message
        case reason
        case delayMilliseconds = "delay_ms"
    }

    private enum ResultKeys: String, CodingKey {
        case ok = "Ok"
        case err = "Err"
    }

    private struct ControlError: Codable, Hashable {
        var code: Int
        var message: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "registered":
            self = .registered(
                clientID: try container.decode(UInt64.self, forKey: .clientID),
                // `protocol.rs:335-337` defaults this to true so a leader
                // predating the field decodes as already initialised.
                ready: try container.decodeIfPresent(Bool.self, forKey: .ready) ?? true,
                protocolVersion: try container.decodeIfPresent(UInt32.self, forKey: .protocolVersion),
                binaryVersion: try container.decodeIfPresent(String.self, forKey: .binaryVersion),
                capabilities: try container.decodeIfPresent(
                    ACPLeaderCapabilities.self,
                    forKey: .capabilities
                )
            )
        case "acp":
            self = .acp(payload: try container.decode(String.self, forKey: .payload))
        case "control_result":
            let requestID = try container.decode(String.self, forKey: .requestID)
            let result = try container.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
            // Serde's `Result` encoding: exactly one of `Ok` / `Err` is
            // present (`protocol.rs:364-367`).
            if result.contains(.ok) {
                self = .controlResult(
                    requestID: requestID,
                    payload: try result.decode(ACPLeaderControlPayload.self, forKey: .ok)
                )
            } else {
                let error = try result.decode(ControlError.self, forKey: .err)
                self = .controlError(requestID: requestID, code: error.code, message: error.message)
            }
        case "pong":
            self = .pong
        case "error":
            self = .error(
                code: try container.decode(Int.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "shutting_down":
            self = .shuttingDown(
                reason: try container.decode(ACPLeaderShutdownReason.self, forKey: .reason),
                delayMilliseconds: try container.decodeIfPresent(
                    UInt64.self,
                    forKey: .delayMilliseconds
                ) ?? 0
            )
        case "shutdown":
            self = .shutdown
        case "leader_ready":
            self = .leaderReady
        default:
            throw ACPLeaderProtocolError.unknownMessageType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .registered(let clientID, let ready, let protocolVersion, let binaryVersion, let capabilities):
            try container.encode("registered", forKey: .type)
            try container.encode(clientID, forKey: .clientID)
            try container.encode(ready, forKey: .ready)
            try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
            try container.encodeIfPresent(binaryVersion, forKey: .binaryVersion)
            try container.encodeIfPresent(capabilities, forKey: .capabilities)
        case .acp(let payload):
            try container.encode("acp", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .controlResult(let requestID, let payload):
            try container.encode("control_result", forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            var result = container.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
            try result.encode(payload, forKey: .ok)
        case .controlError(let requestID, let code, let message):
            try container.encode("control_result", forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            var result = container.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
            try result.encode(ControlError(code: code, message: message), forKey: .err)
        case .pong:
            try container.encode("pong", forKey: .type)
        case .error(let code, let message):
            try container.encode("error", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case .shuttingDown(let reason, let delayMilliseconds):
            try container.encode("shutting_down", forKey: .type)
            try container.encode(reason, forKey: .reason)
            try container.encode(delayMilliseconds, forKey: .delayMilliseconds)
        case .shutdown:
            try container.encode("shutdown", forKey: .type)
        case .leaderReady:
            try container.encode("leader_ready", forKey: .type)
        }
    }
}

// MARK: - Registration error codes

/// `server.rs:2379, 2422, 2489` — the only three codes the leader emits during
/// registration.
public enum ACPLeaderRegistrationError {
    public static let expectedRegister = 1
    public static let alreadyRegistered = 2
    public static let registrationTimeout = 3
}

// MARK: - Codec

public enum ACPLeaderCodec {
    public static func encode<T: Encodable>(_ message: T) throws -> [UInt8] {
        let encoder = JSONEncoder()
        // Stable key order keeps the golden tests readable and diffable; the
        // wire format does not care.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try ACPLeaderFrameEncoder.encode(Array(encoder.encode(message)))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: [UInt8]) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(body))
        } catch let error as ACPLeaderProtocolError {
            throw error
        } catch {
            throw ACPLeaderProtocolError.invalidJSON(String(describing: error))
        }
    }
}
