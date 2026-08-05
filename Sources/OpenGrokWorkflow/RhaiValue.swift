// RhaiValue.swift
//
// The interpreter's runtime value. Distinct from `JSONValue` because Rhai
// separates integers from floats (`type_of(x) == "i64"` is load-bearing in the
// shipped workflows) and because a value can be a closure. Conversion happens
// only at the boundaries: `args` coming in, host payloads going out, journaled
// results coming back.

import Foundation
import OpenGrokShared

public struct RhaiClosureValue: Sendable {
    public var parameters: [String]
    public var body: RhaiBlock
    /// Rhai closures capture by value, so the defining scope is snapshotted.
    public var captured: [String: RhaiValue]
}

public indirect enum RhaiValue: Sendable {
    case unit
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case string(String)
    /// Indexing a string yields a `char` in Rhai, not a one-character string.
    /// The distinction matters: field access on a char is the classic authoring
    /// mistake upstream attaches a hint to (lib.rs:27).
    case character(Character)
    case array([RhaiValue])
    case map([String: RhaiValue])
    case closure(RhaiClosureValue)

    /// The name `type_of()` reports. These strings are matched literally by the
    /// shipped workflows, so they follow Rhai's spelling, not Swift's.
    public var typeName: String {
        switch self {
        case .unit: return "()"
        case .bool: return "bool"
        case .int: return "i64"
        case .float: return "f64"
        case .string: return "string"
        case .character: return "char"
        case .array: return "array"
        case .map: return "map"
        case .closure: return "FnPtr"
        }
    }

    public var isUnit: Bool {
        if case .unit = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .float(let value): return value
        default: return nil
        }
    }

    public var arrayValue: [RhaiValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var mapValue: [String: RhaiValue]? {
        if case .map(let fields) = self { return fields }
        return nil
    }

    // MARK: - JSON bridging

    public var json: JSONValue {
        switch self {
        case .unit, .closure:
            return .null
        case .bool(let value):
            return .bool(value)
        case .int(let value):
            return .number(.int64(value))
        case .float(let value):
            return .number(.double(value))
        case .string(let value):
            return .string(value)
        case .character(let value):
            return .string(String(value))
        case .array(let items):
            return .array(items.map(\.json))
        case .map(let fields):
            return .object(fields.mapValues(\.json))
        }
    }

    public static func from(json: JSONValue) -> RhaiValue {
        switch json {
        case .null:
            return .unit
        case .bool(let value):
            return .bool(value)
        case .number(let number):
            switch number {
            case .int64(let value): return .int(value)
            case .uint64(let value):
                return Int64(exactly: value).map(RhaiValue.int) ?? .float(Double(value))
            case .double(let value):
                // A JSON `4` decoded as a double still has to look like an
                // integer to `type_of()`, or `args.breadth` checks fail.
                if let exact = Int64(exactly: value.rounded()), Double(exact) == value {
                    return .int(exact)
                }
                return .float(value)
            }
        case .string(let value):
            return .string(value)
        case .array(let items):
            return .array(items.map { RhaiValue.from(json: $0) })
        case .object(let fields):
            return .map(fields.mapValues { RhaiValue.from(json: $0) })
        }
    }

    // MARK: - Conversions

    /// What `to_string()` and string concatenation produce.
    public var displayText: String {
        switch self {
        case .unit:
            return ""
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .float(let value):
            if let exact = Int64(exactly: value.rounded()), Double(exact) == value {
                return "\(exact).0"
            }
            return "\(value)"
        case .string(let value):
            return value
        case .character(let value):
            return String(value)
        case .array(let items):
            return "[" + items.map(\.debugText).joined(separator: ", ") + "]"
        case .map(let fields):
            let body = fields.keys.sorted()
                .map { "\($0): \((fields[$0] ?? .unit).debugText)" }
                .joined(separator: ", ")
            return "#{" + body + "}"
        case .closure:
            return "Fn"
        }
    }

    /// Rhai's `debug` form, which quotes strings inside containers.
    public var debugText: String {
        if case .string(let text) = self {
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return displayText
    }

    /// Rhai compares mismatched types as unequal rather than erroring, which is
    /// what makes the ubiquitous `if r == () { ... }` guard work when `r` is a
    /// map. Integers and floats compare numerically across the divide.
    public func rhaiEquals(_ other: RhaiValue) -> Bool {
        switch (self, other) {
        case (.unit, .unit):
            return true
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs
        case (.string(let lhs), .string(let rhs)):
            return lhs == rhs
        case (.character(let lhs), .character(let rhs)):
            return lhs == rhs
        case (.int(let lhs), .int(let rhs)):
            return lhs == rhs
        case (.array(let lhs), .array(let rhs)):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.rhaiEquals($1) }
        case (.map(let lhs), .map(let rhs)):
            guard lhs.count == rhs.count else { return false }
            return lhs.allSatisfy { key, value in
                guard let counterpart = rhs[key] else { return false }
                return value.rhaiEquals(counterpart)
            }
        default:
            if let lhs = doubleValue, let rhs = other.doubleValue { return lhs == rhs }
            return false
        }
    }
}
