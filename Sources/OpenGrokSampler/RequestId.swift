// RequestId.swift
//
// Unique identifier for a sampling request. Mirrors Rust `types::RequestId`.

import Foundation

/// Unique identifier for a sampling request.
///
/// Callers may pass an externally-assigned ID (e.g. a session UUID) or generate
/// a fresh random one via ``RequestId/random()``.
public struct RequestId: Hashable, Sendable, Codable, CustomStringConvertible, Equatable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// Generate a fresh random request ID (UUID string).
    public static func random() -> RequestId {
        RequestId(UUID().uuidString.lowercased())
    }

    public var asString: String { value }

    public var description: String { value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension RequestId: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}
