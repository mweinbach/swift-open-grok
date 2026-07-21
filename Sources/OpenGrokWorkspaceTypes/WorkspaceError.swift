// WorkspaceError.swift
//
// Workspace-wide error type. Ported from
// crates/codegen/xai-grok-workspace-types/src/error.rs.
//
// Every variant is fully serializable so it can travel over the gRPC
// transport. Conversion from non-serializable runtime errors (most notably
// `NSError` / `Error` and tool errors) happens at the workspace-crate
// boundary — this module only owns the wire shape.

import Foundation
import OpenGrokShared

/// Serializable mirror of `std::io::ErrorKind`.
///
/// Tracks every currently-stable variant of `std::io::ErrorKind`. The
/// `other` case is a catch-all for future-stabilized variants and the
/// historical `Other` / `Uncategorized` buckets.
public enum IoKind: Hashable, Sendable, Codable, Equatable {
    case connectionRefused
    case connectionReset
    case hostUnreachable
    case networkUnreachable
    case connectionAborted
    case notConnected
    case addrInUse
    case addrNotAvailable
    case networkDown
    case brokenPipe
    case alreadyExists
    case wouldBlock
    case notADirectory
    case isADirectory
    case directoryNotEmpty
    case readOnlyFilesystem
    case staleNetworkFileHandle
    case invalidInput
    case invalidData
    case timedOut
    case writeZero
    case storageFull
    case notSeekable
    case quotaExceeded
    case fileTooLarge
    case resourceBusy
    case executableFileBusy
    case deadlock
    case crossesDevices
    case tooManyLinks
    case invalidFilename
    case argumentListTooLong
    case interrupted
    case unexpectedEof
    case unsupported
    case outOfMemory
    case notFound
    case permissionDenied
    case other

    /// Whether the I/O kind is transient (the same operation may succeed if
    /// retried). Used by `WorkspaceError.isRetryable`.
    public var isTransient: Bool {
        switch self {
        case .brokenPipe, .connectionReset, .connectionAborted, .connectionRefused,
             .timedOut, .interrupted, .wouldBlock, .hostUnreachable,
             .networkUnreachable, .networkDown, .resourceBusy, .deadlock:
            return true
        default:
            return false
        }
    }

    // MARK: Codable — snake_case wire form

    private static let wireNames: [(IoKind, String)] = [
        (.connectionRefused, "connection_refused"),
        (.connectionReset, "connection_reset"),
        (.hostUnreachable, "host_unreachable"),
        (.networkUnreachable, "network_unreachable"),
        (.connectionAborted, "connection_aborted"),
        (.notConnected, "not_connected"),
        (.addrInUse, "addr_in_use"),
        (.addrNotAvailable, "addr_not_available"),
        (.networkDown, "network_down"),
        (.brokenPipe, "broken_pipe"),
        (.alreadyExists, "already_exists"),
        (.wouldBlock, "would_block"),
        (.notADirectory, "not_a_directory"),
        (.isADirectory, "is_a_directory"),
        (.directoryNotEmpty, "directory_not_empty"),
        (.readOnlyFilesystem, "read_only_filesystem"),
        (.staleNetworkFileHandle, "stale_network_file_handle"),
        (.invalidInput, "invalid_input"),
        (.invalidData, "invalid_data"),
        (.timedOut, "timed_out"),
        (.writeZero, "write_zero"),
        (.storageFull, "storage_full"),
        (.notSeekable, "not_seekable"),
        (.quotaExceeded, "quota_exceeded"),
        (.fileTooLarge, "file_too_large"),
        (.resourceBusy, "resource_busy"),
        (.executableFileBusy, "executable_file_busy"),
        (.deadlock, "deadlock"),
        (.crossesDevices, "crosses_devices"),
        (.tooManyLinks, "too_many_links"),
        (.invalidFilename, "invalid_filename"),
        (.argumentListTooLong, "argument_list_too_long"),
        (.interrupted, "interrupted"),
        (.unexpectedEof, "unexpected_eof"),
        (.unsupported, "unsupported"),
        (.outOfMemory, "out_of_memory"),
        (.notFound, "not_found"),
        (.permissionDenied, "permission_denied"),
        (.other, "other")
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        for (kind, name) in IoKind.wireNames where name == raw {
            self = kind
            return
        }
        // Forward-tolerant: an unknown kind decodes to `.other` (mirrors
        // Rust's `From<std::io::ErrorKind>` fallback for future variants).
        self = .other
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        for (kind, name) in IoKind.wireNames where kind == self {
            try container.encode(name)
            return
        }
        try container.encode("other")
    }
}

/// All errors surfaced by a workspace transport.
///
/// Every variant is fully serializable so it can travel over the gRPC
/// transport. Adjacently tagged with `tag = "type", content = "data"` to
/// match every other wire enum in the crate.
public enum WorkspaceError: Error, Hashable, Sendable, Codable, Equatable {
    /// Filesystem I/O failure. Mirrors `std::io::Error` shape.
    case io(message: String, kind: IoKind)
    /// Version-control (git/jj) failure.
    case vcs(String)
    /// Permission denied at the workspace policy layer.
    case permission(reason: String)
    /// Resource not found.
    case notFound(String)
    /// Operation cancelled (caller dropped the receiver or fired the cancel
    /// token).
    case cancelled
    /// Operation exceeded its deadline.
    case timeout(elapsedMs: UInt64)
    /// Session id was not registered with the workspace.
    case sessionNotFound(SessionId)
    /// A tool returned an error. The runtime crate translates its native
    /// tool error into this generic shape.
    case tool(code: String, message: String)
    /// Generic transport-layer failure (gRPC handshake, TLS, ...).
    case remote(String)
    /// The wrong chunk kind arrived on the stream.
    case protocolMismatch(expected: String, got: ChunkKind)
    /// The stream produced something inconsistent with the stream contract
    /// (e.g. a unary op yielded extra chunks).
    case protocolViolation(String)
    /// The stream closed before yielding any chunk.
    case emptyStream
    /// Catch-all for unexpected internal failures.
    case `internal`(String)

    /// Whether the operation is safe to retry.
    ///
    /// Retryable cases:
    /// * `.timeout` — the deadline was exceeded but the upstream may simply
    ///   be slow.
    /// * `.remote` — a transport-layer failure, often transient.
    /// * `.io` with a transient `IoKind` (see `IoKind.isTransient`).
    ///
    /// Non-retryable IO kinds and all domain errors (`.permission`,
    /// `.notFound`, `.sessionNotFound`, ...) return `false`.
    public var isRetryable: Bool {
        switch self {
        case .timeout, .remote:
            return true
        case .io(_, let kind):
            return kind.isTransient
        default:
            return false
        }
    }

    /// Whether this is a cancellation.
    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// Construct from a generic `Error`. Used at the workspace-crate
    /// boundary — this crate does not implement `init(_ error: Error)`
    /// because the underlying error is not necessarily serializable.
    ///
    /// The translation here is best-effort: callers with richer error types
    /// should format with `String(describing:)` before constructing an
    /// `.internal` case, or use the specific variant constructors
    /// (`.io`, `.tool`, ...) directly.
    public static func fromAny(_ error: Error) -> WorkspaceError {
        .internal(String(describing: error))
    }

    // MARK: Codable — adjacent `tag`/`data` tagging, snake_case variants

    private enum Tag: String, Codable {
        case io, vcs, permission, notFound = "not_found", cancelled, timeout,
             sessionNotFound = "session_not_found", tool, remote,
             protocolMismatch = "protocol_mismatch",
             protocolViolation = "protocol_violation",
             emptyStream = "empty_stream", internal_ = "internal"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    private enum IoPayload: Codable {
        case io(message: String, kind: IoKind)
        enum CodingKeys: String, CodingKey { case message, kind }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .io(message: try c.decode(String.self, forKey: .message),
                        kind: try c.decode(IoKind.self, forKey: .kind))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .io(let m, let k):
                try c.encode(m, forKey: .message)
                try c.encode(k, forKey: .kind)
            }
        }
    }

    private enum TimeoutPayload: Codable {
        case timeout(elapsedMs: UInt64)
        enum CodingKeys: String, CodingKey { case elapsedMs = "elapsed_ms" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .timeout(elapsedMs: try c.decode(UInt64.self, forKey: .elapsedMs))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .timeout(let m):
                try c.encode(m, forKey: .elapsedMs)
            }
        }
    }

    private enum ToolPayload: Codable {
        case tool(code: String, message: String)
        enum CodingKeys: String, CodingKey { case code, message }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .tool(code: try c.decode(String.self, forKey: .code),
                         message: try c.decode(String.self, forKey: .message))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .tool(let code, let m):
                try c.encode(code, forKey: .code)
                try c.encode(m, forKey: .message)
            }
        }
    }

    private enum ProtocolMismatchPayload: Codable {
        case protocolMismatch(expected: String, got: ChunkKind)
        enum CodingKeys: String, CodingKey { case expected, got }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .protocolMismatch(expected: try c.decode(String.self, forKey: .expected),
                                      got: try c.decode(ChunkKind.self, forKey: .got))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .protocolMismatch(let e, let g):
                try c.encode(e, forKey: .expected)
                try c.encode(g, forKey: .got)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(Tag.self, forKey: .type)
        switch tag {
        case .io:
            let p = try container.decode(IoPayload.self, forKey: .data)
            guard case .io(let m, let k) = p else { throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "io payload") }
            self = .io(message: m, kind: k)
        case .vcs:
            self = .vcs(try container.decode(String.self, forKey: .data))
        case .permission:
            // `permission` payload is `{ "reason": "..." }`.
            let inner = try container.nestedContainer(keyedBy: PermissionPayloadKeys.self, forKey: .data)
            self = .permission(reason: try inner.decode(String.self, forKey: .reason))
        case .notFound:
            self = .notFound(try container.decode(String.self, forKey: .data))
        case .cancelled:
            // Unit variant — `data` may be `null` or absent; tolerate either.
            if container.contains(.data) {
                _ = try? container.decode(JSONValue?.self, forKey: .data)
            }
            self = .cancelled
        case .timeout:
            let p = try container.decode(TimeoutPayload.self, forKey: .data)
            guard case .timeout(let m) = p else { throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "timeout payload") }
            self = .timeout(elapsedMs: m)
        case .sessionNotFound:
            self = .sessionNotFound(try container.decode(SessionId.self, forKey: .data))
        case .tool:
            let p = try container.decode(ToolPayload.self, forKey: .data)
            guard case .tool(let c, let m) = p else { throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "tool payload") }
            self = .tool(code: c, message: m)
        case .remote:
            self = .remote(try container.decode(String.self, forKey: .data))
        case .protocolMismatch:
            let p = try container.decode(ProtocolMismatchPayload.self, forKey: .data)
            guard case .protocolMismatch(let e, let g) = p else { throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "protocol_mismatch payload") }
            self = .protocolMismatch(expected: e, got: g)
        case .protocolViolation:
            self = .protocolViolation(try container.decode(String.self, forKey: .data))
        case .emptyStream:
            if container.contains(.data) {
                _ = try? container.decode(JSONValue?.self, forKey: .data)
            }
            self = .emptyStream
        case .internal_:
            self = .internal(try container.decode(String.self, forKey: .data))
        }
    }

    private enum PermissionPayloadKeys: String, CodingKey { case reason }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .io(let m, let k):
            try container.encode(Tag.io, forKey: .type)
            try container.encode(IoPayload.io(message: m, kind: k), forKey: .data)
        case .vcs(let s):
            try container.encode(Tag.vcs, forKey: .type)
            try container.encode(s, forKey: .data)
        case .permission(let reason):
            try container.encode(Tag.permission, forKey: .type)
            var inner = container.nestedContainer(keyedBy: PermissionPayloadKeys.self, forKey: .data)
            try inner.encode(reason, forKey: .reason)
        case .notFound(let s):
            try container.encode(Tag.notFound, forKey: .type)
            try container.encode(s, forKey: .data)
        case .cancelled:
            try container.encode(Tag.cancelled, forKey: .type)
            // Unit variant — omit `data` (serde omits `content` for unit
            // variants under adjacent tagging, producing `{"type":"cancelled"}`).
        case .timeout(let m):
            try container.encode(Tag.timeout, forKey: .type)
            try container.encode(TimeoutPayload.timeout(elapsedMs: m), forKey: .data)
        case .sessionNotFound(let id):
            try container.encode(Tag.sessionNotFound, forKey: .type)
            try container.encode(id, forKey: .data)
        case .tool(let c, let m):
            try container.encode(Tag.tool, forKey: .type)
            try container.encode(ToolPayload.tool(code: c, message: m), forKey: .data)
        case .remote(let s):
            try container.encode(Tag.remote, forKey: .type)
            try container.encode(s, forKey: .data)
        case .protocolMismatch(let e, let g):
            try container.encode(Tag.protocolMismatch, forKey: .type)
            try container.encode(ProtocolMismatchPayload.protocolMismatch(expected: e, got: g), forKey: .data)
        case .protocolViolation(let s):
            try container.encode(Tag.protocolViolation, forKey: .type)
            try container.encode(s, forKey: .data)
        case .emptyStream:
            try container.encode(Tag.emptyStream, forKey: .type)
        case .internal(let s):
            try container.encode(Tag.internal_, forKey: .type)
            try container.encode(s, forKey: .data)
        }
    }
}

extension WorkspaceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .io(let message, let kind):
            return "io: \(message) (\(kind))"
        case .vcs(let s):
            return "vcs: \(s)"
        case .permission(let reason):
            return "permission denied: \(reason)"
        case .notFound(let s):
            return "not found: \(s)"
        case .cancelled:
            return "cancelled"
        case .timeout(let elapsed):
            return "deadline exceeded after \(elapsed)ms"
        case .sessionNotFound(let id):
            return "session not found: \(id)"
        case .tool(let code, let message):
            return "tool error [\(code)]: \(message)"
        case .remote(let s):
            return "transport: \(s)"
        case .protocolMismatch(let expected, let got):
            return "protocol mismatch: expected \(expected), got \(got)"
        case .protocolViolation(let s):
            return "protocol violation: \(s)"
        case .emptyStream:
            return "empty stream (expected at least one chunk)"
        case .internal(let s):
            return "internal: \(s)"
        }
    }
}
