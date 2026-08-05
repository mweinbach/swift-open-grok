// RhaiBuiltins.swift
//
// The pure (non-host) part of the script surface: free functions and the
// methods the shipped workflows call on strings, arrays, and maps.
//
// The method set was taken from what the two built-in workflows actually use
// (`push`, `len`, `to_string`, `trim`, `split`, `contains`, `sub_string`,
// `map`), plus the small set of obvious neighbours. Anything else is rejected
// by name and receiver type — a workflow that calls an unimplemented method
// gets a clear error rather than a silently wrong value.

import Foundation
import OpenGrokShared

enum RhaiBuiltins {
    struct MethodOutcome {
        var value: RhaiValue
        /// True when the method mutated its receiver in Rhai (`push`, `trim`,
        /// `pop`, ...), which the caller must write back to the variable.
        var mutated: Bool
    }

    typealias ClosureInvoker = (RhaiClosureValue, [RhaiValue]) async throws -> RhaiValue

    // MARK: - Free functions

    static func function(
        name: String,
        arguments: [RhaiValue],
        position: RhaiSourcePosition
    ) throws -> RhaiValue {
        switch name {
        case "type_of":
            guard let value = arguments.first else {
                throw RhaiRuntimeError("type_of() takes one argument", at: position)
            }
            return .string(value.typeName)

        case "json_encode":
            // engine.rs:874. serde_json's map is key-sorted, so the canonical
            // writer produces byte-identical output to upstream.
            let value = arguments.first ?? .unit
            return .string(RhaiCanonicalJSON.string(value.json))

        case "fingerprint":
            // engine.rs:871 — a pure, stable content hash a script can use to
            // detect repeats without reaching for wall-clock time.
            guard case .some(.string(let text)) = arguments.first else {
                throw RhaiRuntimeError("fingerprint() expects a string", at: position)
            }
            return .string(rhaiRequestHash(kind: "fingerprint", payload: .string(text)))

        case "len":
            guard let value = arguments.first else {
                throw RhaiRuntimeError("len() takes one argument", at: position)
            }
            return try length(of: value, position: position)

        case "parse_int":
            guard case .some(.string(let text)) = arguments.first else {
                throw RhaiRuntimeError("parse_int() expects a string", at: position)
            }
            guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                throw RhaiRuntimeError("`\(text)` is not an integer", at: position)
            }
            return .int(value)

        case "abs":
            switch arguments.first {
            case .some(.int(let value)): return .int(value < 0 ? -value : value)
            case .some(.float(let value)): return .float(Swift.abs(value))
            default: throw RhaiRuntimeError("abs() expects a number", at: position)
            }

        case "min", "max":
            guard arguments.count == 2,
                  let lhs = arguments[0].doubleValue,
                  let rhs = arguments[1].doubleValue
            else {
                throw RhaiRuntimeError("\(name)() expects two numbers", at: position)
            }
            let takeLeft = name == "min" ? lhs <= rhs : lhs >= rhs
            return takeLeft ? arguments[0] : arguments[1]

        default:
            throw RhaiRuntimeError("function not found: \(name)", at: position)
        }
    }

    // MARK: - Methods

    static func method(
        name: String,
        receiver: inout RhaiValue,
        arguments: [RhaiValue],
        position: RhaiSourcePosition,
        invokeClosure: ClosureInvoker
    ) async throws -> MethodOutcome {
        // Methods available on every value.
        switch name {
        case "to_string":
            return MethodOutcome(value: .string(receiver.displayText), mutated: false)
        case "len":
            return MethodOutcome(value: try length(of: receiver, position: position), mutated: false)
        case "is_empty":
            let count = try length(of: receiver, position: position)
            return MethodOutcome(value: .bool(count.intValue == 0), mutated: false)
        default:
            break
        }

        switch receiver {
        case .string(let text):
            return try stringMethod(
                name: name,
                text: text,
                arguments: arguments,
                position: position,
                receiver: &receiver
            )

        case .array(let items):
            return try await arrayMethod(
                name: name,
                items: items,
                arguments: arguments,
                position: position,
                receiver: &receiver,
                invokeClosure: invokeClosure
            )

        case .map(let fields):
            return try mapMethod(
                name: name,
                fields: fields,
                arguments: arguments,
                position: position,
                receiver: &receiver
            )

        case .int(let value):
            switch name {
            case "to_float": return MethodOutcome(value: .float(Double(value)), mutated: false)
            case "abs": return MethodOutcome(value: .int(value < 0 ? -value : value), mutated: false)
            default: break
            }

        case .float(let value):
            switch name {
            case "to_int": return MethodOutcome(value: .int(Int64(value)), mutated: false)
            case "round": return MethodOutcome(value: .float(value.rounded()), mutated: false)
            case "abs": return MethodOutcome(value: .float(Swift.abs(value)), mutated: false)
            default: break
            }

        default:
            break
        }

        throw RhaiRuntimeError(
            "method `\(name)` is not available on a `\(receiver.typeName)` in the supported "
                + "workflow-script subset",
            at: position
        )
    }

    private static func stringMethod(
        name: String,
        text: String,
        arguments: [RhaiValue],
        position: RhaiSourcePosition,
        receiver: inout RhaiValue
    ) throws -> MethodOutcome {
        func argumentString(_ index: Int) throws -> String {
            guard index < arguments.count, case .string(let value) = arguments[index] else {
                throw RhaiRuntimeError("`\(name)` expects a string argument", at: position)
            }
            return value
        }
        func argumentInt(_ index: Int) throws -> Int {
            guard index < arguments.count, case .int(let value) = arguments[index] else {
                throw RhaiRuntimeError("`\(name)` expects an integer argument", at: position)
            }
            return Int(value)
        }

        switch name {
        case "trim":
            // Rhai's `trim` mutates the receiver and returns unit.
            receiver = .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return MethodOutcome(value: .unit, mutated: true)
        case "contains":
            return MethodOutcome(value: .bool(text.contains(try argumentString(0))), mutated: false)
        case "starts_with":
            return MethodOutcome(value: .bool(text.hasPrefix(try argumentString(0))), mutated: false)
        case "ends_with":
            return MethodOutcome(value: .bool(text.hasSuffix(try argumentString(0))), mutated: false)
        case "index_of":
            let needle = try argumentString(0)
            guard let range = text.range(of: needle) else {
                return MethodOutcome(value: .int(-1), mutated: false)
            }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            return MethodOutcome(value: .int(Int64(offset)), mutated: false)
        case "split":
            let separator = try argumentString(0)
            guard !separator.isEmpty else {
                throw RhaiRuntimeError("`split` needs a non-empty separator", at: position)
            }
            let parts = text.components(separatedBy: separator).map { RhaiValue.string($0) }
            return MethodOutcome(value: .array(parts), mutated: false)
        case "sub_string":
            let characters = Array(text)
            let start = Swift.max(0, Swift.min(try argumentInt(0), characters.count))
            let length = arguments.count > 1
                ? Swift.max(0, Swift.min(try argumentInt(1), characters.count - start))
                : characters.count - start
            return MethodOutcome(
                value: .string(String(characters[start..<(start + length)])),
                mutated: false
            )
        case "replace":
            receiver = .string(text.replacingOccurrences(
                of: try argumentString(0),
                with: try argumentString(1)
            ))
            return MethodOutcome(value: .unit, mutated: true)
        case "to_upper":
            return MethodOutcome(value: .string(text.uppercased()), mutated: false)
        case "to_lower":
            return MethodOutcome(value: .string(text.lowercased()), mutated: false)
        default:
            throw RhaiRuntimeError(
                "method `\(name)` is not available on a string in the supported "
                    + "workflow-script subset",
                at: position
            )
        }
    }

    private static func arrayMethod(
        name: String,
        items: [RhaiValue],
        arguments: [RhaiValue],
        position: RhaiSourcePosition,
        receiver: inout RhaiValue,
        invokeClosure: ClosureInvoker
    ) async throws -> MethodOutcome {
        switch name {
        case "push":
            guard let value = arguments.first else {
                throw RhaiRuntimeError("`push` takes one argument", at: position)
            }
            receiver = .array(items + [value])
            return MethodOutcome(value: .unit, mutated: true)
        case "pop":
            guard let last = items.last else {
                return MethodOutcome(value: .unit, mutated: false)
            }
            receiver = .array(items.dropLast())
            return MethodOutcome(value: last, mutated: true)
        case "clear":
            receiver = .array([])
            return MethodOutcome(value: .unit, mutated: true)
        case "remove":
            guard case .some(.int(let offset)) = arguments.first,
                  offset >= 0, Int(offset) < items.count
            else {
                throw RhaiRuntimeError("`remove` needs an in-bounds index", at: position)
            }
            var copy = items
            let removed = copy.remove(at: Int(offset))
            receiver = .array(copy)
            return MethodOutcome(value: removed, mutated: true)
        case "contains":
            guard let needle = arguments.first else {
                throw RhaiRuntimeError("`contains` takes one argument", at: position)
            }
            return MethodOutcome(
                value: .bool(items.contains { $0.rhaiEquals(needle) }),
                mutated: false
            )
        case "join":
            guard case .some(.string(let separator)) = arguments.first else {
                throw RhaiRuntimeError("`join` expects a string separator", at: position)
            }
            return MethodOutcome(
                value: .string(items.map(\.displayText).joined(separator: separator)),
                mutated: false
            )
        case "map", "filter":
            guard case .some(.closure(let closure)) = arguments.first else {
                throw RhaiRuntimeError("`\(name)` expects a closure", at: position)
            }
            var results: [RhaiValue] = []
            for (offset, item) in items.enumerated() {
                let produced = try await invokeClosure(closure, [item, .int(Int64(offset))])
                if name == "map" {
                    results.append(produced)
                } else {
                    guard case .bool(let keep) = produced else {
                        throw RhaiRuntimeError("`filter` closure must return a boolean", at: position)
                    }
                    if keep { results.append(item) }
                }
            }
            return MethodOutcome(value: .array(results), mutated: false)
        default:
            throw RhaiRuntimeError(
                "method `\(name)` is not available on an array in the supported "
                    + "workflow-script subset",
                at: position
            )
        }
    }

    private static func mapMethod(
        name: String,
        fields: [String: RhaiValue],
        arguments: [RhaiValue],
        position: RhaiSourcePosition,
        receiver: inout RhaiValue
    ) throws -> MethodOutcome {
        switch name {
        case "keys":
            return MethodOutcome(
                value: .array(fields.keys.sorted().map { RhaiValue.string($0) }),
                mutated: false
            )
        case "values":
            return MethodOutcome(
                value: .array(fields.keys.sorted().map { fields[$0] ?? .unit }),
                mutated: false
            )
        case "contains":
            guard case .some(.string(let key)) = arguments.first else {
                throw RhaiRuntimeError("`contains` expects a string key", at: position)
            }
            return MethodOutcome(value: .bool(fields[key] != nil), mutated: false)
        case "remove":
            guard case .some(.string(let key)) = arguments.first else {
                throw RhaiRuntimeError("`remove` expects a string key", at: position)
            }
            var copy = fields
            let removed = copy.removeValue(forKey: key) ?? .unit
            receiver = .map(copy)
            return MethodOutcome(value: removed, mutated: true)
        default:
            throw RhaiRuntimeError(
                "method `\(name)` is not available on a map in the supported "
                    + "workflow-script subset",
                at: position
            )
        }
    }

    private static func length(of value: RhaiValue, position: RhaiSourcePosition) throws -> RhaiValue {
        switch value {
        case .string(let text): return .int(Int64(text.count))
        case .array(let items): return .int(Int64(items.count))
        case .map(let fields): return .int(Int64(fields.count))
        default:
            throw RhaiRuntimeError("`len` is not defined for a `\(value.typeName)`", at: position)
        }
    }
}
