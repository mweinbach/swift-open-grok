// SerdeLenient.swift
//
// Open Grok — Swift port of `xai-tool-types/src/serde_lenient.rs`.
//
// Lenient parsing of tool-argument booleans: a boolean may arrive as a
// JSON string (`"true"`) or number (`1`) when a client doesn't coerce
// args against the tool schema. Accepted forms (strings case-insensitive,
// trimmed; `null` is `false`):
//
//   Truthy:  true, "true", "yes", "1", 1
//   Falsy:   false, "false", "no", "0", 0, null
//
// Mirrors Rust `xai_tool_types::serde_lenient`.

import Foundation
import OpenGrokShared

private let trueLiterals: [String] = ["true", "yes", "1"]
private let falseLiterals: [String] = ["false", "no", "0"]

/// Parse a `JSONValue` into a `Bool` per the accepted lenient forms;
/// returns `nil` for unrecognised values.
///
/// Mirrors Rust `lenient_bool_from_json`.
public func lenientBoolFromJSON(_ value: JSONValue) -> Bool? {
    switch value {
    case .bool(let b):
        return b
    case .null:
        return false
    case .string(let s):
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trueLiterals.contains(where: { trimmed.lowercased() == $0 }) {
            return true
        }
        if falseLiterals.contains(where: { trimmed.lowercased() == $0 }) {
            return false
        }
        return nil
    case .number(let n):
        switch n {
        case .int64(let i): return i == 1 ? true : (i == 0 ? false : nil)
        case .uint64(let u): return u == 1 ? true : (u == 0 ? false : nil)
        case .double: return nil
        }
    default:
        return nil
    }
}

/// Error thrown when a lenient bool cannot be parsed.
public struct LenientBoolError: Error, Sendable, CustomStringConvertible {
    public let value: JSONValue
    public init(_ value: JSONValue) { self.value = value }
    public var description: String {
        "expected a boolean (true/false, \"true\"/\"false\", \"yes\"/\"no\", \"1\"/\"0\", 1/0), got \(value)"
    }
}

/// Decode a required lenient `Bool` from a `JSONValue`, throwing on
/// unrecognised forms. Pair with a default value for an absent key.
///
/// Mirrors Rust `deserialize_lenient_bool`.
public func decodeLenientBool(_ value: JSONValue) throws -> Bool {
    if let b = lenientBoolFromJSON(value) {
        return b
    }
    throw LenientBoolError(value)
}

/// Decode an optional lenient `Bool` from a `JSONValue`: the caller
/// distinguishes "absent key" (`nil`) from "explicit null" (`false`).
///
/// Mirrors Rust `deserialize_lenient_option_bool`.
public func decodeLenientOptionBool(_ value: JSONValue?) throws -> Bool? {
    guard let value = value else { return nil }
    if let b = lenientBoolFromJSON(value) {
        return b
    }
    throw LenientBoolError(value)
}
