// JSONValue.swift
//
// A local Sendable Codable representation of arbitrary JSON values for the
// cli-chat-proxy types. This is the Swift equivalent of Rust's
// `serde_json::Value` — the Rust crate `prod-mc-cli-chat-proxy-types` uses
// `serde_json::Value` directly (not via xai-grok-shared), so this target is
// self-contained.
//
// OpenGrokShared also defines a `JSONValue` type with the same semantics.
// They are distinct Swift types (`OpenGrokCLIChatProxyTypes.JSONValue` vs
// `OpenGrokShared.JSONValue`) that happen to have identical wire forms.
// A future integration slice may add a dependency edge from
// OpenGrokCLIChatProxyTypes to OpenGrokShared and consolidate; until then
// this local copy avoids a cross-target dependency that is not predeclared
// in Package.swift.

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
///
/// Number fidelity: Rust `serde_json::Value::Number` preserves whether a
/// number is a signed integer, unsigned integer, or float, and re-emits
/// integers without decimal points. The Swift `Double`-only representation
/// loses precision for values above 2^53 (e.g. `9007199254740993` rounds to
/// `9007199254740992`) and re-emits integers like `42` as `42.0`. To match
/// `serde_json` byte-significantly, numbers are stored as `JSONNumber` which
/// retains the `Int64`/`UInt64`/`Double` distinction.
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
        } else if let number = try? container.decode(JSONNumber.self) {
            self = .number(number)
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

    // MARK: Convenience

    public var isNull: Bool { self == .null }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }

    /// The numeric value as a `Double`, if this is `.number`.
    ///
    /// Note: this loses precision for integers above 2^53. Use
    /// `int64Value`/`uint64Value` for exact integer access.
    public var doubleValue: Double? { if case .number(let n) = self { return n.doubleValue }; return nil }

    /// The numeric value as an `Int64`, if this is an integer number.
    public var int64Value: Int64? { if case .number(let n) = self { return n.int64Value }; return nil }

    /// The numeric value as a `UInt64`, if this is a non-negative integer number.
    public var uint64Value: UInt64? { if case .number(let n) = self { return n.uint64Value }; return nil }

    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let arr) = self, index >= 0, index < arr.count {
            return arr[index]
        }
        return nil
    }
}

/// A JSON number that preserves the integer/double distinction.
///
/// Rust `serde_json::Value::Number` preserves whether a number is an integer
/// or a float, and serializes integral numbers without a decimal point. The
/// `Double`-only model used previously by this target rounded integers above
/// 2^53 and re-emitted `42` as `42.0`, breaking byte-significant round-trips
/// against `serde_json`. `JSONNumber` retains the `Int64`/`UInt64`/`Double`
/// representation so round-tripping is lossless and byte-significant.
public enum JSONNumber: Hashable, Sendable, Equatable, Codable {
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
        // Try Int64 first (covers the common signed-integer case), then
        // UInt64 (covers values above Int64.max such as UInt64.max), then
        // Double (covers fractional and exponent values). This matches
        // serde_json's Number::from JSON parser ordering closely enough for
        // byte-significant re-encoding.
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

/// A type-erased coding key for dynamic JSON keys (e.g. serde alias decoding).
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

/// A type with a default value, used for serde `#[default]` compatibility.
public protocol Defaultable {
    static var defaultValue: Self { get }
}
