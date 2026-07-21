// JSONValue.swift
//
// A Sendable Codable representation of arbitrary JSON values. This is the
// Swift equivalent of Rust's `serde_json::Value` — used to retain unknown
// fields for forward-compatible replay, carry opaque provider payloads, and
// preserve telemetry metadata without typed schemas.
//
// The W0-S4 acceptance criteria require: "Unknown JSON object fields can be
// retained where Rust compatibility requires forward-compatible replay."
// `JSONValue` satisfies this by providing a lossless round-tripping
// representation that can be stored alongside typed fields and re-emitted
// byte-significantly.

import Foundation

/// A lossless, Sendable representation of any JSON value.
///
/// Mirrors Rust `serde_json::Value`. Use this to:
/// - Retain unknown object fields during Codable decode (forward compat).
/// - Carry opaque provider/telemetry payloads that the client must not drop.
/// - Embed arbitrary metadata in wire envelopes.
///
/// `JSONValue` is `Codable` with a transparent wire form — encoding a
/// `.string("hi")` produces `"hi"`, encoding an `.object` produces the JSON
/// object, etc. This makes it a drop-in for any `Any?` in a Codable context
/// while preserving full type information for re-serialization.
public enum JSONValue: Codable, Hashable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let double = try? container.decode(Double.self) {
            self = .number(.double(double))
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .number(let number):
            try number.encode(to: encoder)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }

    // MARK: Convenience accessors

    /// `true` when this value is `.null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The bool value, if this is `.bool`.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// The string value, if this is `.string`.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// The numeric value as a `Double`, if this is `.number`.
    public var doubleValue: Double? {
        if case .number(let n) = self { return n.doubleValue }
        return nil
    }

    /// The numeric value as an `Int64`, if this is an integer number.
    public var int64Value: Int64? {
        if case .number(let n) = self { return n.int64Value }
        return nil
    }

    /// The array, if this is `.array`.
    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// The object, if this is `.object`.
    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    /// Subscript access into an object. Returns `nil` for non-objects or
    /// missing keys.
    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// Subscript access into an array. Returns `nil` for non-arrays or
    /// out-of-bounds indices.
    public subscript(index: Int) -> JSONValue? {
        if case .array(let arr) = self, index >= 0, index < arr.count {
            return arr[index]
        }
        return nil
    }

    // MARK: Literal construction helpers

    /// Construct a `JSONValue` from a `Codable` value.
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode a `Codable` type from this `JSONValue`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

/// A JSON number that preserves the integer/double distinction.
///
/// Rust `serde_json::Value::Number` preserves whether a number is an integer
/// or a float. Swift's `JSONDecoder` decodes numbers as `Double` by default,
/// which loses integer precision for large values (e.g. `u64` timestamps).
/// `JSONNumber` retains both representations so round-tripping is lossless.
public enum JSONNumber: Hashable, Sendable, Equatable {
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)

    /// The numeric value as a `Double`.
    public var doubleValue: Double {
        switch self {
        case .int64(let v): return Double(v)
        case .uint64(let v): return Double(v)
        case .double(let v): return v
        }
    }

    /// The numeric value as an `Int64`, if it is an integer that fits.
    public var int64Value: Int64? {
        switch self {
        case .int64(let v): return v
        case .uint64(let v): return Int64(exactly: v)
        case .double(let v):
            if v.truncatingRemainder(dividingBy: 1) == 0 {
                return Int64(exactly: v)
            }
            return nil
        }
    }

    /// The numeric value as a `UInt64`, if it is a non-negative integer that fits.
    public var uint64Value: UInt64? {
        switch self {
        case .uint64(let v): return v
        case .int64(let v) where v >= 0: return UInt64(v)
        case .double(let v):
            if v.truncatingRemainder(dividingBy: 1) == 0, v >= 0 {
                return UInt64(exactly: v)
            }
            return nil
        default: return nil
        }
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try Int64 first, then UInt64, then Double.
        if let int = try? container.decode(Int64.self) {
            self = .int64(int)
        } else if let uint = try? container.decode(UInt64.self) {
            self = .uint64(uint)
        } else {
            let double = try container.decode(Double.self)
            self = .double(double)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int64(let v): try container.encode(v)
        case .uint64(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        }
    }
}

// MARK: - Unknown field retention

/// A wrapper that retains unknown JSON object fields alongside typed ones.
///
/// Use this in `Codable` structs to preserve forward-compatible fields.
/// Pass the set of known key strings so unknown keys can be identified.
public enum UnknownFields {
    /// Decode all keys from the decoder's container that are NOT in
    /// `knownKeyStrings`.
    ///
    /// Returns a `[String: JSONValue]` dictionary of the unknown fields.
    public static func decode(
        from decoder: Decoder,
        knownKeyStrings: Set<String>
    ) throws -> [String: JSONValue] {
        let dynamicContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys {
            if !knownKeyStrings.contains(key.stringValue) {
                unknown[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
            }
        }
        return unknown
    }

    /// Encode unknown fields into the given container.
    public static func encode(
        _ fields: [String: JSONValue],
        into container: inout KeyedEncodingContainer<AnyCodingKey>
    ) throws {
        for (key, value) in fields {
            try container.encode(value, forKey: AnyCodingKey(stringValue: key))
        }
    }
}

/// A type-erased coding key for dynamic JSON keys.
public struct AnyCodingKey: CodingKey {
    public let stringValue: String
    public let intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    public init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }
}

// MARK: - Shared encoder/decoder helpers

/// Pre-configured `JSONEncoder` for Open Grok wire types.
///
/// Uses `.iso8601` date encoding to match Rust `chrono` RFC3339 output and
/// `.withoutEscapingSlashes` to match `serde_json`'s default (serde_json does
/// NOT escape `/` as `\/`). The slash-escaping parity is required for
/// byte-significant golden-fixture round-trips against Rust serializers.
public enum WireJSONEncoder {
    /// Create a configured encoder.
    public static func make() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // serde_json does not escape forward slashes; match it so golden
        // fixtures round-trip byte-significantly. Available macOS 13.3+.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// Create a configured encoder with sorted keys for deterministic output.
    public static func makeSorted() -> JSONEncoder {
        let encoder = make()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// Pre-configured `JSONDecoder` for Open Grok wire types.
///
/// Uses `.iso8601` date decoding to match Rust `chrono` RFC3339 input.
public enum WireJSONDecoder {
    /// Create a configured decoder.
    public static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
