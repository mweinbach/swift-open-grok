// InputValidation.swift
//
// Parse tool arguments before permission classification, matching upstream's
// typed `try_parse` boundary. First-party tools intentionally accept the
// lenient scalar forms their Rust deserializers accept; MCP schemas do not.

import Foundation
import OpenGrokShared
import OpenGrokToolTypes

struct ToolInputValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    let path: String
    let reason: String

    var description: String { "\(path): \(reason)" }
}

struct ToolInputSchemaValidator: Sendable {
    private static let maximumDepth = 64
    private static let lenientIntegerFields: Set<String> = [
        "offset", "timeout", "timeout_ms", "output_byte_limit",
    ]

    let schema: JSONValue
    let namespace: ProductToolNamespace
    let toolID: String

    func normalize(_ arguments: JSONValue) throws -> JSONValue {
        // Older dynamically registered integrations have no usable schema.
        // Their handlers remain the authority until they provide one.
        guard schema.objectValue != nil || schema.boolValue != nil else {
            return arguments
        }

        return try normalize(arguments, against: schema, path: "$", depth: 0)
    }

    private var acceptsFirstPartyCoercions: Bool { namespace != .mcp }

    private var acceptsLegacyTaskIDs: Bool {
        acceptsFirstPartyCoercions
            && ["get_task_output", "get_command_or_subagent_output"].contains(toolID)
    }

    private func normalize(
        _ original: JSONValue,
        against schema: JSONValue,
        path: String,
        depth: Int
    ) throws -> JSONValue {
        guard depth < Self.maximumDepth else {
            throw failure(path, "schema nesting exceeds \(Self.maximumDepth) levels")
        }

        if let accepts = schema.boolValue {
            guard accepts else { throw failure(path, "this value is not permitted") }
            return original
        }

        guard let constraints = schema.objectValue else {
            return original
        }

        var value = original
        if let reference = constraints["$ref"]?.stringValue,
           let referenced = resolve(reference: reference)
        {
            value = try normalize(value, against: referenced, path: path, depth: depth + 1)
        }

        if let type = constraints["type"] {
            value = try normalizeType(value, expected: type, path: path)
        }

        if let permitted = constraints["enum"]?.arrayValue,
           !permitted.contains(value)
        {
            throw failure(path, "value is not one of the permitted choices")
        }

        if let constant = constraints["const"], value != constant {
            throw failure(path, "value does not match the required constant")
        }

        switch value {
        case .object(let object):
            value = .object(try normalizeObject(
                object,
                constraints: constraints,
                path: path,
                depth: depth
            ))
        case .array(let array):
            value = .array(try normalizeArray(
                array,
                constraints: constraints,
                path: path,
                depth: depth
            ))
        case .string(let string):
            try validateString(string, constraints: constraints, path: path)
        case .number(let number):
            try validateNumber(number, constraints: constraints, path: path)
        case .null, .bool:
            break
        }

        if let alternatives = constraints["allOf"]?.arrayValue {
            for alternative in alternatives {
                value = try normalize(value, against: alternative, path: path, depth: depth + 1)
            }
        }

        if let alternatives = constraints["anyOf"]?.arrayValue {
            var matched: JSONValue?
            for alternative in alternatives {
                do {
                    matched = try normalize(value, against: alternative, path: path, depth: depth + 1)
                    break
                } catch is ToolInputValidationError {
                    continue
                }
            }
            guard let matched else {
                throw failure(path, "value does not match any permitted schema")
            }
            value = matched
        }

        if let alternatives = constraints["oneOf"]?.arrayValue {
            var matches: [JSONValue] = []
            for alternative in alternatives {
                do {
                    matches.append(try normalize(
                        value,
                        against: alternative,
                        path: path,
                        depth: depth + 1
                    ))
                } catch is ToolInputValidationError {
                    continue
                }
            }
            guard matches.count == 1, let match = matches.first else {
                throw failure(path, "value matches \(matches.count) alternatives; expected exactly one")
            }
            value = match
        }

        return value
    }

    private func normalizeObject(
        _ original: [String: JSONValue],
        constraints: [String: JSONValue],
        path: String,
        depth: Int
    ) throws -> [String: JSONValue] {
        var object = original
        let properties = constraints["properties"]?.objectValue ?? [:]

        if acceptsLegacyTaskIDs,
           properties["task_ids"] != nil,
           object["task_ids"] == nil,
           let legacy = object.removeValue(forKey: "task_id")
        {
            object["task_ids"] = legacy
        }

        let required = constraints["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for key in required where object[key] == nil {
            throw failure(path, "missing required field `\(key)`")
        }

        for key in properties.keys.sorted() {
            guard let candidate = object[key], let property = properties[key] else { continue }
            let propertyPath = path + "." + key

            // Optional Rust fields accept explicit null even when a hand-built
            // Swift catalog omitted JSON Schema's nullable type union.
            if acceptsFirstPartyCoercions,
               candidate.isNull,
               !required.contains(key),
               !declaresBoolean(property)
            {
                object.removeValue(forKey: key)
                continue
            }

            object[key] = try normalize(
                candidate,
                against: property,
                path: propertyPath,
                depth: depth + 1
            )
        }

        if let additional = constraints["additionalProperties"] {
            for key in object.keys.sorted() where properties[key] == nil {
                if let permitted = additional.boolValue {
                    guard permitted else {
                        throw failure(path + "." + key, "unexpected additional property `\(key)`")
                    }
                } else if additional.objectValue != nil, let candidate = object[key] {
                    object[key] = try normalize(
                        candidate,
                        against: additional,
                        path: path + "." + key,
                        depth: depth + 1
                    )
                }
            }
        }

        if let minimum = constraints["minProperties"]?.int64Value,
           Int64(object.count) < minimum
        {
            throw failure(path, "expected at least \(minimum) properties, got \(object.count)")
        }
        if let maximum = constraints["maxProperties"]?.int64Value,
           Int64(object.count) > maximum
        {
            throw failure(path, "expected at most \(maximum) properties, got \(object.count)")
        }

        return object
    }

    private func normalizeArray(
        _ array: [JSONValue],
        constraints: [String: JSONValue],
        path: String,
        depth: Int
    ) throws -> [JSONValue] {
        if let minimum = constraints["minItems"]?.int64Value,
           Int64(array.count) < minimum
        {
            throw failure(path, "expected at least \(minimum) items, got \(array.count)")
        }
        if let maximum = constraints["maxItems"]?.int64Value,
           Int64(array.count) > maximum
        {
            throw failure(path, "expected at most \(maximum) items, got \(array.count)")
        }

        var normalized: [JSONValue] = []
        normalized.reserveCapacity(array.count)
        let prefix = constraints["prefixItems"]?.arrayValue ?? []
        for (index, candidate) in array.enumerated() {
            let itemSchema = index < prefix.count ? prefix[index] : constraints["items"]
            if let itemSchema {
                normalized.append(try normalize(
                    candidate,
                    against: itemSchema,
                    path: "\(path)[\(index)]",
                    depth: depth + 1
                ))
            } else {
                normalized.append(candidate)
            }
        }

        if constraints["uniqueItems"]?.boolValue == true,
           Set(normalized).count != normalized.count
        {
            throw failure(path, "array items must be unique")
        }

        return normalized
    }

    private func normalizeType(
        _ value: JSONValue,
        expected type: JSONValue,
        path: String
    ) throws -> JSONValue {
        let allowed: [String]
        if let single = type.stringValue {
            allowed = [single]
        } else if let multiple = type.arrayValue {
            allowed = multiple.compactMap(\.stringValue)
        } else {
            return value
        }

        if allowed.contains(where: { matches(value, type: $0) }) {
            return value
        }

        if acceptsFirstPartyCoercions,
           allowed.contains("boolean"),
           let boolean = lenientBoolFromJSON(value)
        {
            return .bool(boolean)
        }

        if acceptsFirstPartyCoercions,
           allowed.contains("integer"),
           Self.lenientIntegerFields.contains(path.split(separator: ".").last.map(String.init) ?? ""),
           let number = lenientInteger(value)
        {
            return .number(number)
        }

        if acceptsLegacyTaskIDs,
           allowed.contains("array"),
           path.hasSuffix(".task_ids"),
           let ids = lenientTaskIDs(value)
        {
            return .array(ids.map(JSONValue.string))
        }

        if allowed == ["array"], path != "$" {
            let field = path.split(separator: ".").last.map(String.init) ?? path
            throw failure(path, "`\(field)` must be an array (got \(typeName(value)))")
        }

        throw failure(
            path,
            "expected \(allowed.joined(separator: " or ")), got \(typeName(value))"
        )
    }

    private func validateString(
        _ string: String,
        constraints: [String: JSONValue],
        path: String
    ) throws {
        let count = string.unicodeScalars.count
        if let minimum = constraints["minLength"]?.int64Value, Int64(count) < minimum {
            throw failure(path, "expected at least \(minimum) characters, got \(count)")
        }
        if let maximum = constraints["maxLength"]?.int64Value, Int64(count) > maximum {
            throw failure(path, "expected at most \(maximum) characters, got \(count)")
        }
        if let pattern = constraints["pattern"]?.stringValue,
           let expression = try? NSRegularExpression(pattern: pattern),
           expression.firstMatch(
               in: string,
               range: NSRange(string.startIndex..., in: string)
           ) == nil
        {
            throw failure(path, "value does not match the required pattern")
        }
    }

    private func validateNumber(
        _ number: JSONNumber,
        constraints: [String: JSONValue],
        path: String
    ) throws {
        let value = number.doubleValue
        if let minimum = constraints["minimum"]?.doubleValue, value < minimum {
            throw failure(path, "value must be at least \(minimum)")
        }
        if let maximum = constraints["maximum"]?.doubleValue, value > maximum {
            throw failure(path, "value must be at most \(maximum)")
        }
        if let minimum = constraints["exclusiveMinimum"]?.doubleValue, value <= minimum {
            throw failure(path, "value must be greater than \(minimum)")
        }
        if let maximum = constraints["exclusiveMaximum"]?.doubleValue, value >= maximum {
            throw failure(path, "value must be less than \(maximum)")
        }
    }

    private func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string),
             ("number", .number), ("object", .object), ("array", .array):
            return true
        case ("integer", .number(let number)):
            switch number {
            case .int64, .uint64:
                return true
            case .double(let number):
                return number.isFinite && number.rounded(.towardZero) == number
            }
        default:
            return false
        }
    }

    private func typeName(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        case .number(let number):
            return matches(.number(number), type: "integer") ? "integer" : "number"
        }
    }

    private func declaresBoolean(_ schema: JSONValue) -> Bool {
        guard let type = schema["type"] else { return false }
        if type.stringValue == "boolean" { return true }
        return type.arrayValue?.contains(.string("boolean")) == true
    }

    private func lenientInteger(_ value: JSONValue) -> JSONNumber? {
        guard case .string(let raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let signed = Int64(trimmed) { return .int64(signed) }
        if let unsigned = UInt64(trimmed) { return .uint64(unsigned) }
        guard let numeric = Double(trimmed),
              numeric.isFinite,
              abs(numeric) <= 9_007_199_254_740_992,
              numeric.rounded(.towardZero) == numeric
        else { return nil }
        if let signed = Int64(exactly: numeric) { return .int64(signed) }
        if let unsigned = UInt64(exactly: numeric) { return .uint64(unsigned) }
        return nil
    }

    private func lenientTaskIDs(_ value: JSONValue) -> [String]? {
        switch value {
        case .null:
            return []
        case .string(let string):
            return [string]
        case .number(let number):
            switch number {
            case .int64(let value): return [String(value)]
            case .uint64(let value): return [String(value)]
            case .double(let value): return [String(value)]
            }
        default:
            return nil
        }
    }

    private func resolve(reference: String) -> JSONValue? {
        guard reference.hasPrefix("#/") else { return nil }
        var current = schema
        for raw in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = String(raw).replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let next = current[key] else { return nil }
            current = next
        }
        return current
    }

    private func failure(_ path: String, _ reason: String) -> ToolInputValidationError {
        ToolInputValidationError(path: path, reason: reason)
    }
}
