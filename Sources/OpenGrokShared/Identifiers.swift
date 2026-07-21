// Identifiers.swift
//
// Stable Sendable Codable identifiers used across process, ACP, tool, and
// persistence boundaries. These are the Swift equivalents of the Rust
// newtype identifiers scattered across xai-grok-workspace-types/identity.rs
// (SessionId, ToolCallId, HunkId), xai-grok-sampler/types.rs (RequestId),
// xai-grok-shell/terminal/background_task.rs (TaskId), and the model/turn/
// worktree identifiers used throughout the shell and pager.
//
// Wire form: every identifier serializes as a bare JSON string
// (`"sess-123"`, not `{"value":"sess-123"}`), matching the Rust
// `#[serde(transparent)]` contract. This is the stable Codable wire form
// required by the W0-S4 acceptance criteria.
//
// Ordering: all identifiers implement `Comparable` so collections sort
// deterministically by the wrapped string. This satisfies the "deterministic
// ordering" acceptance criterion and lets persistence/telemetry layers emit
// sorted identifiers without ad-hoc comparators.

import Foundation

/// A stable, Sendable, Codable identifier wrapping a string.
///
/// All Open Grok identifiers share this shape: a `String` newtype that
/// serializes transparently as a bare JSON string, is `Hashable` for
/// `Set`/`Dictionary` keys, `Comparable` for deterministic ordering, and
/// `Sendable` for cross-actor exchange.
public protocol IdentifierProtocol: Hashable, Comparable, CustomStringConvertible, Sendable {
    /// The raw string value.
    var rawValue: String { get }

    /// Construct from a string.
    init(_ rawValue: String)
}

// MARK: - Generic Identifier

/// A generic string-backed identifier that serializes as a bare JSON string.
///
/// This is the concrete storage backing all typed identifiers. Each typed
/// identifier wraps a `RawIdentifier` to preserve type safety while sharing
/// one Codable implementation.
public struct RawIdentifier: IdentifierProtocol, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    // MARK: Comparable

    public static func < (lhs: RawIdentifier, rhs: RawIdentifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: Codable — transparent string wire form

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: Convenience

    /// Borrow the wrapped string (alias for `rawValue`).
    public var stringValue: String { rawValue }

    /// `true` when the identifier is the empty string.
    public var isEmpty: Bool { rawValue.isEmpty }
}

// MARK: - Typed Identifiers

/// Unique session identifier.
///
/// Swift equivalent of Rust `xai_grok_workspace_types::identity::SessionId`
/// and `agent_client_protocol::SessionId`. Serializes as `"sess-123"`.
public struct SessionID: IdentifierProtocol, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func < (lhs: SessionID, rhs: SessionID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Borrow the wrapped string.
    public var stringValue: String { rawValue }

    /// `true` when the identifier is the empty string.
    public var isEmpty: Bool { rawValue.isEmpty }
}

/// Unique turn identifier within a session.
///
/// In Rust, turns are typically tracked by a `u64`/`i64` turn number. The
/// identifier form wraps the string representation so it can be used in
/// wire types, persistence keys, and telemetry correlation. Serializes as
/// `"turn-42"` or `"42"` depending on the producer.
public struct TurnID: IdentifierProtocol, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func < (lhs: TurnID, rhs: TurnID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var stringValue: String { rawValue }
    public var isEmpty: Bool { rawValue.isEmpty }
}

/// Unique tool-call identifier within a session.
///
/// Swift equivalent of Rust `xai_grok_workspace_types::identity::ToolCallId`.
/// Serializes as `"call-abc"`.
public struct ToolCallID: IdentifierProtocol, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func < (lhs: ToolCallID, rhs: ToolCallID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var stringValue: String { rawValue }
    public var isEmpty: Bool { rawValue.isEmpty }
}

/// Unique background task identifier.
///
/// Swift equivalent of Rust `xai_grok_shell::terminal::background_task::TaskId`
/// (currently `pub type TaskId = String`). Serializes as a bare string.
public struct TaskID: IdentifierProtocol, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func < (lhs: TaskID, rhs: TaskID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var stringValue: String { rawValue }
    public var isEmpty: Bool { rawValue.isEmpty }
}

/// Unique worktree identifier.
///
/// Used by fast-worktree (W4-S2) and session persistence (W7-S2) to name
/// worktrees deterministically. Serializes as a bare string.
public struct WorktreeID: IdentifierProtocol, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func < (lhs: WorktreeID, rhs: WorktreeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var stringValue: String { rawValue }
    public var isEmpty: Bool { rawValue.isEmpty }
}

/// Model identifier (e.g. `"grok-3"`, `"codex-1"`).
///
/// Model IDs are opaque strings resolved by the model catalog (W3-S2).
/// Serializes as a bare string so wire types that embed a model ID stay
/// compact.
public struct ModelID: IdentifierProtocol, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func < (lhs: ModelID, rhs: ModelID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var stringValue: String { rawValue }
    public var isEmpty: Bool { rawValue.isEmpty }
}

/// Unique request identifier for a sampling/inference request.
///
/// Swift equivalent of Rust `xai_grok_sampler::types::RequestId`. Wraps a
/// UUID string (typically v4). Serializes as a bare string.
public struct RequestID: IdentifierProtocol, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func < (lhs: RequestID, rhs: RequestID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var stringValue: String { rawValue }
    public var isEmpty: Bool { rawValue.isEmpty }

    /// Generate a fresh random request ID backed by a UUID v4.
    public static func random() -> RequestID {
        RequestID(UUID().uuidString.lowercased())
    }
}

/// Unique hunk identifier produced by the hunk tracker.
///
/// Swift equivalent of Rust `xai_grok_workspace_types::identity::HunkId`.
/// Serializes as `"hunk-xyz"`.
public struct HunkID: IdentifierProtocol, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static func < (lhs: HunkID, rhs: HunkID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var stringValue: String { rawValue }
    public var isEmpty: Bool { rawValue.isEmpty }
}

// MARK: - Deterministic ordering helpers

/// Deterministic ordering utilities for identifier collections.
public enum IdentifierOrdering {
    /// Return a sorted array of identifiers (ascending by raw string).
    public static func sorted<T: IdentifierProtocol>(_ ids: [T]) -> [T] {
        ids.sorted()
    }

    /// Return a sorted array of (identifier, value) pairs by identifier.
    public static func sortedByKey<T: IdentifierProtocol, V>(
        _ pairs: [(T, V)]
    ) -> [(T, V)] {
        pairs.sorted { $0.0 < $1.0 }
    }

    /// Return a deduplicated, sorted array of identifiers.
    public static func deduplicatedSorted<T: IdentifierProtocol>(_ ids: [T]) -> [T] {
        Array(Set(ids)).sorted()
    }
}
