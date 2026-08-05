// JavaScriptJSONBridge.swift
//
// JSON marshalling between Swift `JSONValue` and JavaScript values.
// Ported from `crates/codegen/xai-grok-code-mode/src/runtime/value.rs`
// (`v8_value_to_json` / `json_to_v8`).
//
// The Rust port marshals *through JSON text* rather than by walking the
// object graph: `v8::json::stringify` on the way out and `v8::json::parse`
// on the way in. That is load-bearing — it applies `toJSON`, drops
// `undefined` and functions, and turns a non-serializable cycle into a
// throw. This port keeps the same rule with `JSON.stringify` /
// `JSON.parse` so tool arguments and stored values observe identical
// semantics.

import Foundation
import OpenGrokShared

/// Text-level JSON conversion helpers.
///
/// These are deliberately independent of `Codable`: `JSONEncoder` refuses
/// top-level fragments on the package's minimum deployment target, while
/// tool arguments and stored values are routinely bare strings or numbers.
public enum JavaScriptJSONBridge {
    /// Serialize a `JSONValue` to compact JSON text.
    public static func string(from value: JSONValue) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: foundationObject(from: value),
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return text
    }

    /// Parse compact JSON text into a `JSONValue`. Returns `nil` when the
    /// text is not valid JSON.
    public static func value(fromJSON text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return nil
        }
        return jsonValue(from: object)
    }

    // MARK: - Foundation bridging

    static func foundationObject(from value: JSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let flag):
            return NSNumber(value: flag)
        case .number(let number):
            switch number {
            case .int64(let raw): return NSNumber(value: raw)
            case .uint64(let raw): return NSNumber(value: raw)
            case .double(let raw): return NSNumber(value: raw)
            }
        case .string(let text):
            return text
        case .array(let items):
            return items.map(foundationObject(from:))
        case .object(let fields):
            var result: [String: Any] = [:]
            result.reserveCapacity(fields.count)
            for (key, field) in fields {
                result[key] = foundationObject(from: field)
            }
            return result
        }
    }

    static func jsonValue(from object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // `NSNumber` erases Bool into the same class; the ObjC type
            // encoding is the only reliable discriminator.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let text = String(cString: number.objCType)
            if text == "d" || text == "f" {
                return .number(.double(number.doubleValue))
            }
            if let exact = Int64(exactly: number.int64Value), Double(exact) == number.doubleValue {
                return .number(.int64(exact))
            }
            return .number(.double(number.doubleValue))
        case let text as String:
            return .string(text)
        case let items as [Any]:
            return .array(items.map(jsonValue(from:)))
        case let fields as [String: Any]:
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(fields.count)
            for (key, field) in fields {
                result[key] = jsonValue(from: field)
            }
            return .object(result)
        default:
            return .null
        }
    }
}
