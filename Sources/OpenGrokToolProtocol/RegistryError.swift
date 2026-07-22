// RegistryError.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/registry_error.rs`.
//
// Serializable registry-level errors for failures that occur **inside**
// the registry (mismatched session, server-id collisions, stale generation).

import Foundation

/// Registry-level error. Internally tagged on `"code"` with snake_case
/// discriminators.
public enum RegistryError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    case alreadyRegistered(toolId: ToolId)
    case sessionMismatch(tokenSession: SessionId, regSession: SessionId)
    case serverIdCollision(serverId: ServerId)
    case serverIdInUse(serverId: ServerId)
    case invalidDescription(message: String)
    case staleGeneration(expected: UInt64, actual: UInt64)

    private enum CodingKeys: String, CodingKey {
        case code
        case toolId = "tool_id"
        case tokenSession = "token_session"
        case regSession = "reg_session"
        case serverId = "server_id"
        case message
        case expected
        case actual
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        switch code {
        case "tool_already_registered":
            self = .alreadyRegistered(toolId: try c.decode(ToolId.self, forKey: .toolId))
        case "session_mismatch":
            self = .sessionMismatch(
                tokenSession: try c.decode(SessionId.self, forKey: .tokenSession),
                regSession: try c.decode(SessionId.self, forKey: .regSession)
            )
        case "server_id_collision":
            self = .serverIdCollision(serverId: try c.decode(ServerId.self, forKey: .serverId))
        case "server_id_in_use":
            self = .serverIdInUse(serverId: try c.decode(ServerId.self, forKey: .serverId))
        case "invalid_description":
            self = .invalidDescription(message: try c.decode(String.self, forKey: .message))
        case "stale_generation":
            self = .staleGeneration(
                expected: try c.decode(UInt64.self, forKey: .expected),
                actual: try c.decode(UInt64.self, forKey: .actual)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .code, in: c,
                debugDescription: "unknown RegistryError code: \(code)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .alreadyRegistered(let toolId):
            try c.encode("tool_already_registered", forKey: .code)
            try c.encode(toolId, forKey: .toolId)
        case .sessionMismatch(let tokenSession, let regSession):
            try c.encode("session_mismatch", forKey: .code)
            try c.encode(tokenSession, forKey: .tokenSession)
            try c.encode(regSession, forKey: .regSession)
        case .serverIdCollision(let serverId):
            try c.encode("server_id_collision", forKey: .code)
            try c.encode(serverId, forKey: .serverId)
        case .serverIdInUse(let serverId):
            try c.encode("server_id_in_use", forKey: .code)
            try c.encode(serverId, forKey: .serverId)
        case .invalidDescription(let message):
            try c.encode("invalid_description", forKey: .code)
            try c.encode(message, forKey: .message)
        case .staleGeneration(let expected, let actual):
            try c.encode("stale_generation", forKey: .code)
            try c.encode(expected, forKey: .expected)
            try c.encode(actual, forKey: .actual)
        }
    }

    public var description: String {
        switch self {
        case .alreadyRegistered(let id):
            return "tool already registered: \(id)"
        case .sessionMismatch(let token, let reg):
            return "session mismatch: token session=\(token), registration session=\(reg)"
        case .serverIdCollision(let id):
            return "server_id \(id) collides with an active server in this session"
        case .serverIdInUse(let id):
            return "server_id \(id) already owned by an earlier registration on this connection"
        case .invalidDescription(let message):
            return "invalid description: \(message)"
        case .staleGeneration(let expected, let actual):
            return "stale generation: expected=\(expected), actual=\(actual)"
        }
    }
}
