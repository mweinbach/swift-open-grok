// Envelope.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/envelope.rs`.
//
// JSON-RPC 2.0 envelope types with the Grok `session_id` / `seq`
// extensions: `JsonRpcVersion`, `JsonRpcId`, `JsonRpcRequest`,
// `JsonRpcNotification`, `JsonRpcError`, `JsonRpcResponse`.

import Foundation
import OpenGrokShared

/// JSON-RPC 2.0 protocol version marker. Serializes as the literal
/// string `"2.0"` and rejects any other value on deserialize.
///
/// Mirrors Rust `JsonRpcVersion`.
public struct JsonRpcVersion: Codable, Sendable, Hashable, Equatable {
    public static let version = "2.0"

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        guard s == Self.version else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected jsonrpc \"\(Self.version)\", got \"\(s)\""
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.version)
    }
}

/// JSON-RPC 2.0 envelope `id` field. Per the spec the `id` MAY be a
/// string or a number. We emit a string ourselves; null ids are not
/// produced.
///
/// Mirrors Rust `JsonRpcId`.
public enum JsonRpcId: Codable, Sendable, Hashable, Equatable, CustomStringConvertible {
    case string(String)
    case number(Int64)

    public var description: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let n = try? container.decode(Int64.self) {
            self = .number(n)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JsonRpcId must be a string or number"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }

    /// Build a fresh UUID-backed id.
    public static func newUUID() -> JsonRpcId {
        .string(UUID().uuidString.lowercased())
    }

    /// Build from a `RequestId`.
    public static func from(requestId: RequestId) -> JsonRpcId {
        .string(requestId.asStr)
    }

    /// Project to a `RequestId`. Numeric ids are stringified. Returns
    /// an error if the resulting string would be empty.
    public func asRequestId() throws -> RequestId {
        switch self {
        case .string(let s): return try RequestId(s)
        case .number(let n): return try RequestId(String(n))
        }
    }
}

/// JSON-RPC 2.0 request envelope. Generic over `params`.
///
/// Mirrors Rust `JsonRpcRequest<P>`.
public struct JsonRpcRequest<P: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc: JsonRpcVersion
    public var id: JsonRpcId
    /// Grok extension: routing/sanity-check session id.
    public var sessionId: SessionId?
    public var method: String
    public var params: P

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case sessionId = "session_id"
        case method
        case params
    }

    public init(jsonrpc: JsonRpcVersion = JsonRpcVersion(), id: JsonRpcId, sessionId: SessionId? = nil, method: String, params: P) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.sessionId = sessionId
        self.method = method
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(JsonRpcVersion.self, forKey: .jsonrpc)
        self.id = try c.decode(JsonRpcId.self, forKey: .id)
        self.sessionId = try c.decodeIfPresent(SessionId.self, forKey: .sessionId)
        self.method = try c.decode(String.self, forKey: .method)
        self.params = try c.decode(P.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(method, forKey: .method)
        try c.encode(params, forKey: .params)
    }
}

/// JSON-RPC 2.0 notification envelope. No `id` (notifications do not
/// produce a response). `seq` is an optional per-connection monotonic
/// counter.
///
/// Mirrors Rust `JsonRpcNotification<P>`.
public struct JsonRpcNotification<P: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc: JsonRpcVersion
    public var sessionId: SessionId?
    public var seq: FrameSeq?
    public var method: String
    public var params: P

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case sessionId = "session_id"
        case seq
        case method
        case params
    }

    public init(jsonrpc: JsonRpcVersion = JsonRpcVersion(), sessionId: SessionId? = nil, seq: FrameSeq? = nil, method: String, params: P) {
        self.jsonrpc = jsonrpc
        self.sessionId = sessionId
        self.seq = seq
        self.method = method
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(JsonRpcVersion.self, forKey: .jsonrpc)
        self.sessionId = try c.decodeIfPresent(SessionId.self, forKey: .sessionId)
        self.seq = try c.decodeIfPresent(FrameSeq.self, forKey: .seq)
        self.method = try c.decode(String.self, forKey: .method)
        self.params = try c.decode(P.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encode(method, forKey: .method)
        try c.encode(params, forKey: .params)
    }
}

/// JSON-RPC error object.
///
/// Mirrors Rust `JsonRpcError`. `code` is the numeric envelope code;
/// `data` typically carries a serialized `ToolErrorWire`.
public struct JsonRpcError: Codable, Sendable, Hashable {
    public var code: Int32
    public var message: String
    public var data: JSONValue?

    public init(code: Int32, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Either a `result` payload (success) or a `JsonRpcError` (failure).
///
/// Mirrors Rust `ResponseOutcome<R>`.
public enum ResponseOutcome<R: Codable & Sendable>: Codable, Sendable {
    case result(R)
    case error(JsonRpcError)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try decoding as a JsonRpcError first (has "code" field),
        // otherwise as the result type R.
        if let err = try? container.decode(JsonRpcError.self) {
            self = .error(err)
        } else {
            let r = try container.decode(R.self)
            self = .result(r)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .result(let r): try container.encode(r)
        case .error(let e): try container.encode(e)
        }
    }
}

/// JSON-RPC 2.0 response envelope. Per the spec exactly one of
/// `result` / `error` is present. The custom `Codable` impl enforces
/// that invariant: a payload containing both keys, or neither, fails
/// to deserialize.
///
/// Mirrors Rust `JsonRpcResponse<R>`.
public struct JsonRpcResponse<R: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc: JsonRpcVersion
    public var id: JsonRpcId
    public var sessionId: SessionId?
    public var outcome: ResponseOutcome<R>

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case sessionId = "session_id"
        case result
        case error
    }

    public init(jsonrpc: JsonRpcVersion = JsonRpcVersion(), id: JsonRpcId, sessionId: SessionId? = nil, outcome: ResponseOutcome<R>) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.sessionId = sessionId
        self.outcome = outcome
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(JsonRpcVersion.self, forKey: .jsonrpc)
        self.id = try c.decode(JsonRpcId.self, forKey: .id)
        self.sessionId = try c.decodeIfPresent(SessionId.self, forKey: .sessionId)
        let hasResult = c.contains(.result)
        let hasError = c.contains(.error)
        switch (hasResult, hasError) {
        case (true, false):
            let r = try c.decode(R.self, forKey: .result)
            self.outcome = .result(r)
        case (false, true):
            let e = try c.decode(JsonRpcError.self, forKey: .error)
            self.outcome = .error(e)
        case (true, true):
            throw DecodingError.dataCorruptedError(
                forKey: .result, in: c,
                debugDescription: "JSON-RPC response must contain `result` XOR `error`, got both"
            )
        case (false, false):
            throw DecodingError.dataCorruptedError(
                forKey: .result, in: c,
                debugDescription: "JSON-RPC response must contain `result` or `error`"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        switch outcome {
        case .result(let r): try c.encode(r, forKey: .result)
        case .error(let e): try c.encode(e, forKey: .error)
        }
    }

    public static func ok(id: JsonRpcId, result: R) -> JsonRpcResponse<R> {
        JsonRpcResponse(id: id, outcome: .result(result))
    }

    public static func err(id: JsonRpcId, error: JsonRpcError) -> JsonRpcResponse<R> {
        JsonRpcResponse(id: id, outcome: .error(error))
    }

    public func withSession(_ sid: SessionId) -> JsonRpcResponse<R> {
        var copy = self
        copy.sessionId = sid
        return copy
    }
}
