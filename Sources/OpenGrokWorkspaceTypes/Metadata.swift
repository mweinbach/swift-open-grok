// Metadata.swift
//
// Per-call metadata header map. Ported from
// crates/codegen/xai-grok-workspace-types/src/metadata.rs.
//
// `Metadata` is a string-keyed map intended to mirror gRPC metadata 1:1
// when the call goes over the wire. It carries per-call context like
// session ids, trace context, and deadlines. The in-process typed
// `Extensions` map is deliberately NOT defined here — it is in-process only
// and not serialized, so it lives in the runtime `OpenGrokWorkspace` crate
// alongside the transport implementations.

import Foundation

// MARK: - Standard metadata keys

/// Standard metadata key for the active session id.
public let META_SESSION_ID: String = "x-workspace-session-id"

/// Standard metadata key for the W3C trace parent (`traceparent`).
public let META_TRACEPARENT: String = "traceparent"

/// Standard metadata key for the W3C trace state (`tracestate`).
public let META_TRACESTATE: String = "tracestate"

/// Standard metadata key for the originating client identity.
public let META_CLIENT_ID: String = "x-workspace-client-id"

/// Standard metadata key for the prompt index of the current turn.
public let META_PROMPT_INDEX: String = "x-workspace-prompt-index"

/// Standard metadata key for the gRPC call deadline.
///
/// Note: the gRPC `grpc-timeout` header carries a unit-suffixed string
/// per the gRPC HTTP/2 spec, not a bare millisecond count. Examples:
/// `"100m"` (100 ms), `"30S"` (30 s), `"2H"` (2 h). Callers reading this
/// key are responsible for parsing the unit suffix — the constant only
/// names the header, it does not impose a unit.
public let META_GRPC_TIMEOUT: String = "grpc-timeout"

/// All standard metadata keys defined by this crate, in declaration order.
///
/// Useful for tests that need to assert uniqueness or for callers that want
/// to scrub well-known keys from a metadata map.
public let STANDARD_META_KEYS: [String] = [
    META_SESSION_ID,
    META_TRACEPARENT,
    META_TRACESTATE,
    META_CLIENT_ID,
    META_PROMPT_INDEX,
    META_GRPC_TIMEOUT
]

// MARK: - Metadata map

/// String-keyed metadata headers.
///
/// Backed by a sorted dictionary (`[String: String]` rendered through
/// `WireJSONEncoder.makeSorted()` for deterministic output) so serialization
/// order is deterministic, which matters for snapshot tests and for stable
/// wire-bytes hashing. The on-wire JSON shape is a JSON object.
///
/// Swift 6 Sendability: a struct of `[String: String]` is `Sendable` because
/// `Dictionary` is `Sendable` when its keys and values are `Sendable`
/// (`String` is).
public struct Metadata: Hashable, Sendable, Codable, Equatable {
    /// The backing map. Public so callers can construct / deconstruct
    /// freely; the helpers below preserve the Rust API shape.
    public var entries: [String: String]

    /// Create an empty metadata map.
    public init() {
        self.entries = [:]
    }

    /// Create from an existing dictionary.
    public init(_ entries: [String: String]) {
        self.entries = entries
    }

    /// Insert a header. Returns the previous value if any.
    @discardableResult
    public mutating func insert(_ key: String, _ value: String) -> String? {
        let previous = entries[key]
        entries[key] = value
        return previous
    }

    /// Look up a header by key.
    public func get(_ key: String) -> String? {
        entries[key]
    }

    /// Whether `key` is present in the map.
    public func contains(_ key: String) -> Bool {
        entries[key] != nil
    }

    /// Remove a header. Returns the removed value if any.
    @discardableResult
    public mutating func remove(_ key: String) -> String? {
        entries.removeValue(forKey: key)
    }

    /// Iterate over the map's `(key, value)` pairs in key order.
    public func iter() -> [(String, String)] {
        entries.sorted { $0.key < $1.key }
    }

    /// Iterate over the map's keys in sorted order.
    public func keys() -> [String] {
        entries.keys.sorted()
    }

    /// Iterate over the map's values in key order.
    public func values() -> [String] {
        entries.sorted { $0.key < $1.key }.map { $0.value }
    }

    /// Number of entries in the map.
    public var count: Int { entries.count }

    /// Whether the map is empty.
    public var isEmpty: Bool { entries.isEmpty }

    // MARK: Codable — transparent JSON object

    private enum CodingKeys: String, CodingKey {
        // Transparent map: encode/decode as a JSON object directly. Use
        // `AnyCodingKey` so arbitrary header names round-trip.
        case _any
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // serde(transparent) maps to a bare JSON object.
        self.entries = try container.decode([String: String].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

// MARK: - Default

extension Metadata {
    /// `Metadata` default is an empty map, matching `Metadata::default()`
    /// in the Rust crate.
    public static let empty = Metadata()
}

// MARK: - Sequence-like construction

extension Metadata {
    /// Build a `Metadata` from a sequence of `(String, String)` pairs,
    /// mirroring Rust's `FromIterator<(K, V)>` impl.
    public init<S: Sequence>(_ pairs: S) where S.Element == (String, String) {
        var entries: [String: String] = [:]
        for (k, v) in pairs {
            entries[k] = v
        }
        self.entries = entries
    }
}
