// AcpCore.swift
//
// Core ACP identifiers and shared wire primitives ported from
// `agent-client-protocol-schema` (re-exported by `xai-acp-lib`).

import Foundation
import OpenGrokShared

// MARK: - Identifiers

/// Unique identifier for a conversation session.
///
/// Wire form: transparent JSON string. Mirrors
/// `agent_client_protocol_schema::SessionId`.
public struct AcpSessionId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

extension AcpSessionId: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

/// Protocol version integer.
///
/// Wire form: JSON number. Mirrors
/// `agent_client_protocol_schema::ProtocolVersion`.
public struct ProtocolVersion: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var rawValue: UInt16

    public init(_ rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let v1 = ProtocolVersion(1)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let u = try? container.decode(UInt16.self) {
            rawValue = u
        } else if let i = try? container.decode(Int.self), i >= 0, i <= Int(UInt16.max) {
            rawValue = UInt16(i)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ProtocolVersion must be a non-negative integer <= 65535"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "\(rawValue)" }
}

/// Unique tool-call identifier within a session.
public struct ToolCallId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Authentication method identifier.
public struct AuthMethodId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Session mode identifier.
public struct SessionModeId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Model identifier.
public struct ModelId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Session configuration option identifier.
public struct SessionConfigId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Session configuration value identifier.
public struct SessionConfigValueId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Terminal identifier.
public struct TerminalId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Permission option identifier.
public struct PermissionOptionId: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

// MARK: - Extension request/response envelopes

/// Arbitrary extension request that is not part of the ACP core surface.
///
/// The method name is used for routing and is not part of the params
/// body on the wire. Mirrors `agent_client_protocol_schema::ExtRequest`.
public struct ExtRequest: Hashable, Sendable {
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue = .object([:])) {
        self.method = method
        self.params = params
    }
}

extension ExtRequest: Codable {
    // Wire form is only the params body; method is transport routing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        params = try container.decode(JSONValue.self)
        method = "ext_method"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(params)
    }
}

extension ExtRequest: AcpRequest {
    public typealias Response = ExtResponse
    public var methodName: String { method }
}

/// Arbitrary extension response body.
public struct ExtResponse: Hashable, Sendable, Codable {
    public var value: JSONValue

    public init(_ value: JSONValue = .object([:])) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(JSONValue.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Arbitrary extension notification.
public struct ExtNotification: Hashable, Sendable {
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue = .object([:])) {
        self.method = method
        self.params = params
    }
}

extension ExtNotification: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        params = try container.decode(JSONValue.self)
        method = "ext_notification"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(params)
    }
}

extension ExtNotification: AcpRequest {
    public typealias Response = EmptyAcpResponse
    public var methodName: String { method }
}

/// Empty ACP response body for notifications and methods that return `{}`.
public struct EmptyAcpResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        // Accept both missing/empty objects and explicit `_meta`.
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        meta = try container?.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - JSON-RPC request ids

/// JSON-RPC 2.0 request id. Mirrors
/// `agent_client_protocol_schema::rpc::RequestId`.
public enum AcpRequestId: Hashable, Sendable, Codable, CustomStringConvertible {
    case null
    case number(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let n = try? container.decode(Int64.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RequestId must be null, number, or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .number(let n):
            try container.encode(n)
        case .string(let s):
            try container.encode(s)
        }
    }

    public var description: String {
        switch self {
        case .null: return "null"
        case .number(let n): return "\(n)"
        case .string(let s): return s
        }
    }
}

// MARK: - JSON-RPC envelopes

/// JSON-RPC 2.0 request envelope with typed params.
public struct JsonRpcRequest<Params: Codable & Sendable>: Hashable, Sendable, Codable
where Params: Hashable {
    public var jsonrpc: String
    public var id: AcpRequestId
    public var method: String
    public var params: Params?

    public init(
        id: AcpRequestId,
        method: String,
        params: Params? = nil,
        jsonrpc: String = "2.0"
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        id = try container.decode(AcpRequestId.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(Params.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// JSON-RPC 2.0 notification envelope (no id).
public struct JsonRpcNotification<Params: Codable & Sendable>: Hashable, Sendable, Codable
where Params: Hashable {
    public var jsonrpc: String
    public var method: String
    public var params: Params?

    public init(method: String, params: Params? = nil, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(Params.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// JSON-RPC 2.0 response envelope with typed result or error.
public enum JsonRpcResponse<Result: Codable & Sendable>: Hashable, Sendable, Codable
where Result: Hashable {
    case result(id: AcpRequestId, result: Result)
    case error(id: AcpRequestId, error: AcpError)

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(AcpRequestId.self, forKey: .id)
        if container.contains(.error) {
            let err = try container.decode(AcpError.self, forKey: .error)
            self = .error(id: id, error: err)
        } else {
            let result = try container.decode(Result.self, forKey: .result)
            self = .result(id: id, result: result)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        switch self {
        case .result(let id, let result):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case .error(let id, let error):
            try container.encode(id, forKey: .id)
            try container.encode(error, forKey: .error)
        }
    }

    public var id: AcpRequestId {
        switch self {
        case .result(let id, _), .error(let id, _):
            return id
        }
    }
}

// MARK: - Meta helpers

public extension AcpMeta {
    /// Decode an optional `_meta` field from a keyed container.
    static func decodeMeta<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> AcpMeta? {
        try container.decodeIfPresent(AcpMeta.self, forKey: key)
    }
}
