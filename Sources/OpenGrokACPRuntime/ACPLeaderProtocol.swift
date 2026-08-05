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
/// would turn a clean `UnsupportedControl` into a hang.
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

    /// What this port actually supports. The control plane is not implemented,
    /// so every flag is false and clients get `UnsupportedControl` immediately
    /// instead of waiting out a request that will never be answered.
    public static let supported = ACPLeaderCapabilities()
}

/// `protocol.rs:320-332`.
public enum ACPLeaderShutdownReason: String, Sendable, Hashable, Codable {
    case autoUpdate = "auto_update"
    case idleTimeout = "idle_timeout"
    case manual
}

// MARK: - Client -> leader

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
            self = .control(
                requestID: try container.decode(String.self, forKey: .requestID),
                command: try container.decodeIfPresent([String: String].self, forKey: .command) ?? [:]
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
            let error = try result.decode(ControlError.self, forKey: .err)
            self = .controlError(requestID: requestID, code: error.code, message: error.message)
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
        encoder.outputFormatting = [.sortedKeys]
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
