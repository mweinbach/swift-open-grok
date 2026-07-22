// Identifiers.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/ids.rs`.
//
// Every wire-traveling id has a dedicated newtype to prevent accidental
// mixing (e.g. passing a `SessionId` where a `ToolId` is expected).
// Constructors validate; `Decodable` re-uses the constructor, so values
// that round-trip from the wire share the same invariants as values
// built locally.
//
// Wire form: every identifier serializes as a bare JSON string
// (`"sess-123"`, not `{"value":"sess-123"}`), matching the Rust
// `#[serde(transparent)]` contract.

import Foundation
import OpenGrokShared

/// Errors produced by id constructors and validators.
///
/// Mirrors Rust `xai_tool_protocol::ids::IdError`.
public enum IdError: Error, Sendable, Hashable, CustomStringConvertible {
    case empty
    case invalidFormat(value: String)
    case reservedPrefix(value: String)

    public var description: String {
        switch self {
        case .empty: return "identifier must not be empty"
        case .invalidFormat(let value): return "identifier \"\(value)\" has invalid format"
        case .reservedPrefix(let value): return "identifier \"\(value)\" uses a reserved prefix"
        }
    }
}

// MARK: - ID validation helpers

@inline(__always)
private func isIDChar(_ c: Character) -> Bool {
    c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
}

private func isValidSegment(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy(isIDChar)
}

private func ensureNonEmpty(_ s: String) throws {
    if s.isEmpty { throw IdError.empty }
}

// MARK: - OpaqueID base

/// A string-backed opaque identifier newtype that serializes as a bare
/// JSON string. Validates on construction.
///
/// Mirrors the Rust `opaque_id!` macro output. Each concrete id type
/// wraps `OpaqueID` to preserve type safety while sharing one Codable
/// implementation.
public struct OpaqueID: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: String

    /// Construct, validating non-emptiness.
    public init(_ rawValue: String) throws {
        try ensureNonEmpty(rawValue)
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public var stringValue: String { rawValue }
    public var isEmpty: Bool { rawValue.isEmpty }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try ensureNonEmpty(raw)
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Concrete identifier types

/// Session identifier. Service-issued or carried from a JWT claim.
/// Mirrors Rust `SessionId`.
public struct SessionId: Hashable, Sendable, CustomStringConvertible, Codable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try ensureNonEmpty(rawValue)
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public var stringValue: String { rawValue }
    public var asStr: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try ensureNonEmpty(raw)
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: SessionId, rhs: SessionId) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// User identifier (the JWT `sub` claim). Mirrors Rust `UserId`.
public struct UserId: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try ensureNonEmpty(rawValue)
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public var stringValue: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try ensureNonEmpty(raw)
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Per-connection identifier issued by the computer hub.
/// Mirrors Rust `ConnectionId`.
public struct ConnectionId: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try ensureNonEmpty(rawValue)
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public var stringValue: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try ensureNonEmpty(raw)
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// JSON-RPC request id as it appears on the wire.
/// Mirrors Rust `RequestId`.
public struct RequestId: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try ensureNonEmpty(rawValue)
        self.rawValue = rawValue
    }

    public init?(_ rawValue: String?) {
        guard let raw = rawValue, !raw.isEmpty else { return nil }
        self.rawValue = raw
    }

    public var description: String { rawValue }
    public var stringValue: String { rawValue }
    public var asStr: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try ensureNonEmpty(raw)
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// End-to-end identifier for a single tool invocation.
/// SDKs SHOULD use UUID v7. Mirrors Rust `ToolCallId`.
public struct ToolCallId: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try ensureNonEmpty(rawValue)
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public var stringValue: String { rawValue }
    public var asStr: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try ensureNonEmpty(raw)
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Generate a fresh UUID v7-backed `ToolCallId`.
    /// Swift's Foundation doesn't provide UUID v7 directly; we use a
    /// UUID v4 string as a reasonable substitute (the wire contract is
    /// just "non-empty string", and v7 is a SHOULD not a MUST).
    public static func newV7() -> ToolCallId {
        // UUID v4 as a fallback; the wire contract only requires non-empty.
        let s = UUID().uuidString.lowercased()
        return try! ToolCallId(s)
    }
}

// MARK: - ServerId (with reserved-prefix validation)

/// The `auto:` prefix is reserved for computer-hub-synthesised ids and
/// rejected from client-supplied values.
public let serverIdReservedPrefix = "auto:"

private func validateServerId(_ s: String) throws {
    if s.hasPrefix(serverIdReservedPrefix) {
        throw IdError.reservedPrefix(value: s)
    }
}

/// Server identifier. Opaque non-empty string; the lexical prefix
/// `auto:` is reserved. Mirrors Rust `ServerId`.
public struct ServerId: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try ensureNonEmpty(rawValue)
        try validateServerId(rawValue)
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public var stringValue: String { rawValue }
    public var asStr: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try ensureNonEmpty(raw)
        try validateServerId(raw)
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Synthesise the deterministic computer-hub-side id for a single-tool
    /// `register_tool` that omits `server_id`. Bypasses the reserved-prefix
    /// check. Mirrors Rust `ServerId::synthesize_for_tool`.
    ///
    /// `connectionId` is part of the signature so callers can't omit the
    /// connection scope they are implicitly relying on, even though the
    /// current encoding does not mix it in.
    public static func synthesizeForTool(connectionId: ConnectionId, toolId: ToolId) -> ServerId {
        _ = connectionId
        return ServerId(unchecked: "\(serverIdReservedPrefix)tool:\(toolId.rawValue)")
    }

    /// Unchecked constructor used only by hub-side synthesis paths that
    /// intentionally produce reserved-prefix ids.
    fileprivate init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - ToolId (with format validation)

/// Format: `{namespace}:{name}` or `{name}`. Each segment must match
/// `[a-zA-Z0-9_-]+`. Mirrors Rust `ToolId`.
public struct ToolId: Hashable, Sendable, CustomStringConvertible, Codable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try ensureNonEmpty(rawValue)
        if !isWellFormedToolId(rawValue) {
            throw IdError.invalidFormat(value: rawValue)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public var stringValue: String { rawValue }
    public var asStr: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try ensureNonEmpty(raw)
        if !isWellFormedToolId(raw) {
            throw IdError.invalidFormat(value: raw)
        }
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ToolId, rhs: ToolId) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private func isWellFormedToolId(_ s: String) -> Bool {
    let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    guard let first = parts.first else { return false }
    switch parts.count {
    case 1:
        return isValidSegment(String(first))
    case 2:
        return isValidSegment(String(first)) && isValidSegment(String(parts[1]))
    default:
        return false
    }
}

// MARK: - FrameSeq

/// Per-connection monotonic notification sequence (starts at 0 on every
/// new connection). Mirrors Rust `FrameSeq`.
public struct FrameSeq: Hashable, Sendable, CustomStringConvertible, Codable, Comparable, Defaultable {
    public let rawValue: UInt64

    public init(_ value: UInt64) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { String(rawValue) }
    public var get: UInt64 { rawValue }

    public static func < (lhs: FrameSeq, rhs: FrameSeq) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static var defaultValue: FrameSeq { FrameSeq(0) }
}
