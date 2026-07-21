// SerdeHelpers.swift
//
// Shared serde helpers for the cli-chat-proxy types. Ported from
// prod/mc/cli-chat-proxy-types/src/serde_helpers.rs.
//
// The Rust `empty_string_as_none` deserializer treats empty strings as `nil`
// during decode. This is used for fields like `model_fingerprint` where an
// empty string from the server should be treated as "not present".

import Foundation

/// Decode a `String?` where an empty string is treated as `nil`.
///
/// This is the Swift equivalent of Rust's `empty_string_as_none` serde
/// helper. Use it in custom `init(from:)` implementations:
///
/// ```swift
/// modelFingerprint = try Self.decodeEmptyStringAsNone(from: container, forKey: .modelFingerprint)
/// ```
public func decodeEmptyStringAsNone<K: CodingKey>(
    from container: KeyedDecodingContainer<K>,
    forKey key: K
) throws -> String? {
    guard container.contains(key) else { return nil }
    if let str = try? container.decode(String.self, forKey: key) {
        return str.isEmpty ? nil : str
    }
    return try container.decodeIfPresent(String.self, forKey: key)
}
