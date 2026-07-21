// Scripted.swift
//
// Port of `xai-grok-test-support/src/scripted.rs`. Data-driven scripted
// responses for the mock inference server: plain status/header/body triples
// queued per path and rendered to HTTP at serve time. Pure data — no router
// or handler types in the public surface.
//
// The Rust source uses `axum::http::{HeaderName, HeaderValue, StatusCode}`
// for eager validation and `axum::response::sse::Event` for SSE rendering.
// The Swift port validates eagerly via `HTTPHeader.validate` / `HTTPStatus`
// and renders to raw HTTP/1.1 bytes in `MockServer`; no axum dependency.

import Foundation

/// One SSE event as `data:` plus an optional `event:` name. Mirrors
/// `scripted::SseEvent`.
public struct SseEvent: Sendable, Equatable, Codable {
    /// Optional `event:` name. `nil` means a bare `data:` line.
    public var event: String?
    /// The `data:` payload (raw string; usually a JSON object literal).
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }

    /// Event with a `data:` payload only.
    public static func data(_ data: String) -> SseEvent {
        SseEvent(event: nil, data: data)
    }

    /// Event with an `event:` name and a `data:` payload.
    public static func withEvent(_ event: String, data: String) -> SseEvent {
        SseEvent(event: event, data: data)
    }

    /// Render to the SSE wire format: optional `event: <name>\n`, then
    /// `data: <payload>\n`, then a blank line terminator.
    public func render() -> String {
        var out = ""
        if let event {
            out += "event: \(event)\n"
        }
        out += "data: \(data)\n"
        out += "\n"
        return out
    }
}

/// Body of a `ScriptedResponse`. Mirrors `scripted::ScriptedBody`.
public enum ScriptedBody: Sendable, Equatable {
    /// JSON body (parsed, re-serialized at serve time).
    case json(JSONValue)
    /// SSE body: a list of `SseEvent`s, served as `text/event-stream`.
    case sse([SseEvent])
    /// Raw body bytes, served verbatim (byte-controllable malformed SSE etc.).
    case raw(String)
}

/// A parsed JSON value, `Sendable` and `Equatable`, used by `ScriptedBody`
/// and the SSE generators. Foundation's `Any` is neither, so this enum
/// re-implements the common subset.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case integer(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Decode `Data` as JSON.
    public static func decode(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue.from(any)
    }

    /// Decode a UTF-8 string as JSON.
    public static func decode(_ string: String) throws -> JSONValue {
        try decode(Data(string.utf8))
    }

    /// Encode to `Data`.
    public func encode() throws -> Data {
        let any = self.toAny()
        return try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
    }

    /// Encode to a UTF-8 string.
    public func encodeString() throws -> String {
        let data = try encode()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Convenience constructor for a JSON object from a dictionary literal.
    public static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        var dict: [String: JSONValue] = [:]
        for (k, v) in pairs { dict[k] = v }
        return .object(dict)
    }

    /// Subscript an object by key. Returns `.null` for missing keys or
    /// non-object values.
    public subscript(key: String) -> JSONValue {
        if case .object(let dict) = self, let v = dict[key] { return v }
        return .null
    }

    /// Subscript an array by index. Returns `.null` for out-of-bounds or
    /// non-array values.
    public subscript(index: Int) -> JSONValue {
        if case .array(let arr) = self, index >= 0, index < arr.count { return arr[index] }
        return .null
    }

    /// Returns the string value if this is a `.string`.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Returns the bool value if this is a `.bool`.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Returns the array if this is `.array`.
    public var arrayValue: [JSONValue]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    /// Returns the object if this is `.object`.
    public var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    /// `true` if this is `.null` (either explicit or a missing-key subscript).
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Convert from `Any` (from `JSONSerialization`).
    static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            // NSNumber bridges both int and double; use objCType to distinguish.
            let type = String(cString: n.objCType)
            switch type {
            case "d", "f": return .number(n.doubleValue)
            default: return .integer(n.int64Value)
            }
        case let s as String: return .string(s)
        case let arr as [Any]: return .array(arr.map { from($0) })
        case let dict as [String: Any]: return .object(dict.mapValues { from($0) })
        default: return .null
        }
    }

    /// Convert to `Any` (for `JSONSerialization`).
    func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .integer(let i): return i
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.toAny() }
        case .object(let dict): return dict.mapValues { $0.toAny() }
        }
    }
}

/// A scripted reply for a single request on one path, consumed FIFO. Takes
/// precedence over the response mode AND the required-auth check — a script
/// is full control over the next reply. Mirrors `scripted::ScriptedResponse`.
public struct ScriptedResponse: Sendable {
    public var status: UInt16
    public var headers: [(String, String)]
    public var body: ScriptedBody

    public init(status: UInt16, headers: [(String, String)] = [], body: ScriptedBody) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func == (lhs: ScriptedResponse, rhs: ScriptedResponse) -> Bool {
        guard lhs.status == rhs.status else { return false }
        guard lhs.headers.count == rhs.headers.count else { return false }
        for (l, r) in zip(lhs.headers, rhs.headers) {
            guard l.0 == r.0 && l.1 == r.1 else { return false }
        }
        return lhs.body == rhs.body
    }

    /// 200 SSE response built from an event list.
    public static func sse(_ events: [SseEvent]) -> ScriptedResponse {
        ScriptedResponse(status: 200, headers: [], body: .sse(events))
    }

    /// JSON body with the given status.
    public static func json(status: UInt16, _ body: JSONValue) -> ScriptedResponse {
        ScriptedResponse(status: status, headers: [], body: .json(body))
    }

    /// Raw text body with the given status.
    public static func text(status: UInt16, _ body: String) -> ScriptedResponse {
        ScriptedResponse(status: status, headers: [], body: .raw(body))
    }

    /// Validate status and headers eagerly so a bad script panics at the
    /// enqueue call site rather than far away at serve time. Mirrors
    /// `ScriptedResponse::validate`.
    public func validate() throws {
        guard (100...599).contains(status) else {
            throw ScriptedResponseError.invalidStatus(status)
        }
        for (name, value) in headers {
            try HTTPHeader.validate(name: name, value: value)
        }
    }
}

/// Errors thrown by `ScriptedResponse.validate`.
public enum ScriptedResponseError: Error, Equatable, CustomStringConvertible {
    case invalidStatus(UInt16)
    case invalidHeaderName(String)
    case invalidHeaderValue(String)

    public var description: String {
        switch self {
        case let .invalidStatus(s): return "Invalid scripted status code: \(s)"
        case let .invalidHeaderName(n): return "Invalid scripted header name: \(n)"
        case let .invalidHeaderValue(v): return "Invalid scripted header value: \(v)"
        }
    }
}

/// HTTP header validation helpers. Mirrors the eager checks the Rust source
/// does via `HeaderName::from_bytes` / `HeaderValue::from_str`.
public enum HTTPHeader {
    /// Validate that `name` is a legal HTTP/1.1 header name (token chars
    /// only, no whitespace/control).
    public static func validate(name: String, value: String) throws {
        try validateName(name)
        try validateValue(value)
    }

    /// Validate a header name (RFC 7230 token: `!#$%&'*+-.^_`|~0-9A-Za-z`).
    public static func validateName(_ name: String) throws {
        if name.isEmpty {
            throw ScriptedResponseError.invalidHeaderName(name)
        }
        for byte in name.utf8 {
            // RFC 7230: tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
            let isToken = (byte >= 0x21 && byte <= 0x7E) && byte != 0x22 && byte != 0x28 && byte != 0x29 && byte != 0x2C && byte != 0x2F && byte != 0x3A && byte != 0x3B && byte != 0x3C && byte != 0x3D && byte != 0x3E && byte != 0x3F && byte != 0x40 && byte != 0x5B && byte != 0x5C && byte != 0x5D && byte != 0x7B && byte != 0x7D
            // Simpler: allow RFC 7230 tchar set explicitly.
            let allowed: Set<UInt8> = Set("!#$%&'*+-.^_`|~".utf8)
                .union(Set(0x30...0x39))  // 0-9
                .union(Set(0x41...0x5A))  // A-Z
                .union(Set(0x61...0x7A))  // a-z
            if !allowed.contains(byte) || !isToken {
                throw ScriptedResponseError.invalidHeaderName(name)
            }
        }
    }

    /// Validate a header value (RFC 7230 field-vchar: visible ASCII + SP,
    /// plus obs-text 0x80-0xFF; no CR/LF except as part of obs-fold which we
    /// reject).
    public static func validateValue(_ value: String) throws {
        for byte in value.utf8 {
            // Reject CR/LF outright (no obs-fold support).
            if byte == 0x0D || byte == 0x0A {
                throw ScriptedResponseError.invalidHeaderValue(value)
            }
            // Allow SP (0x20), HTAB (0x09), VCHAR (0x21-0x7E), obs-text (0x80-0xFF).
            let allowed = byte == 0x20 || byte == 0x09 || (byte >= 0x21 && byte <= 0x7E) || byte >= 0x80
            if !allowed {
                throw ScriptedResponseError.invalidHeaderValue(value)
            }
        }
    }
}
