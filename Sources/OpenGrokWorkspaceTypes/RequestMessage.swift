// RequestMessage.swift
//
// The wire-side request envelope. Ported from
// crates/codegen/xai-grok-workspace-types/src/request.rs.
//
// `RequestMessage<T>` carries just the parts that need to survive a network
// hop: a typed payload (`message`), per-call `metadata`, and an optional
// `deadline`. The runtime envelope (in `OpenGrokWorkspace`) wraps this with
// a cancellation token and an in-process extensions map — those are runtime
// concerns (cancellation propagates via receiver-drop in-process, via gRPC
// stream-cancel over the network; extensions are explicitly "in-process
// only; not serialized") and do not belong on the wire type.

import Foundation

/// Wire-side request envelope.
///
/// Wraps a typed payload (`message`) with per-call `metadata` and an
/// optional `deadline`. Generic over the payload type `T` so the same
/// envelope shape is reused for `WorkspaceRequest`, `ToolRequest`,
/// `WorkspaceOpsRequest`, and `SessionLifecycleRequest`.
public struct RequestMessage<T: Codable & Sendable & Hashable & Equatable>: Hashable, Sendable, Codable, Equatable {
    /// The typed request payload (one of the `*Request` enums).
    public var message: T

    /// String-keyed metadata for the call (auth tokens, trace context,
    /// session id, ...). See `Metadata` for the standard keys.
    public var metadata: Metadata

    /// Optional absolute deadline for the call, in UTC.
    ///
    /// Encoded as an ISO-8601 string in JSON. The runtime layer is
    /// responsible for translating this to a sleep / `grpc-timeout` header.
    public var deadline: Date?

    /// Construct a new request with empty metadata and no deadline.
    public init(_ message: T) {
        self.message = message
        self.metadata = Metadata()
        self.deadline = nil
    }

    /// Builder: attach metadata.
    @discardableResult
    public func withMetadata(_ metadata: Metadata) -> Self {
        var copy = self
        copy.metadata = metadata
        return copy
    }

    /// Builder: set the absolute deadline.
    @discardableResult
    public func withDeadline(_ deadline: Date) -> Self {
        var copy = self
        copy.deadline = deadline
        return copy
    }

    /// Map the inner payload while preserving metadata and deadline.
    public func map<U>(_ transform: (T) -> U) -> RequestMessage<U> where U: Codable & Sendable & Hashable & Equatable {
        RequestMessage<U>(
            message: transform(message),
            metadata: metadata,
            deadline: deadline
        )
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case message
        case metadata
        case deadline
    }

    public init(message: T, metadata: Metadata, deadline: Date?) {
        self.message = message
        self.metadata = metadata
        self.deadline = deadline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(T.self, forKey: .message)
        // `#[serde(default)]` — missing metadata decodes to an empty map.
        metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata) ?? Metadata()
        // `#[serde(default, skip_serializing_if = "Option::is_none")]` —
        // missing deadline decodes to nil; absent on the wire when nil.
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        // Match Rust `#[serde(default)]` semantics: always emit metadata
        // (the default empty map still serializes as `{}`).
        try container.encode(metadata, forKey: .metadata)
        // `skip_serializing_if = "Option::is_none"` — only emit when set.
        if let deadline = deadline {
            try container.encode(deadline, forKey: .deadline)
        }
    }
}
