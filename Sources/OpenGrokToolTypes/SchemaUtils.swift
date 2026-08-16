// SchemaUtils.swift
//
// Open Grok — Swift port of `xai-tool-types/src/schema_utils.rs`.
//
// `parseArgumentsFromSchemaLossy(_:)` extracts flat, top-level properties
// from an "object"-typed JSON Schema into `[ToolArgument]`. It is
// intentionally a minimal subset of JSON Schema — just enough for render
// tools to work as they don't speak JSON schema.
//
// Supported keywords (mirror the Rust table in schema_utils.rs):
//   * `properties` (top-level)        — each key becomes a `ToolArgument`
//   * `required` (top-level)          — marks arguments as required
//   * `$defs` (top-level)             — resolved when referenced by `$ref`
//   * `type` (per-property)           — string or array via `SchemaType.from`
//   * `description` (per-property)    — mapped to `ToolArgument.description`
//   * `default` (per-property)        — mapped to `ToolArgument.default`
//   * `enum` / `allowed_values`       — mapped to `allowedValues`
//   * `minimum` / `maximum`           — inclusive numeric bounds
//   * `exclusiveMinimum` / `exclusiveMaximum` — exclusive numeric bounds
//   * `$ref` (per-property)           — resolved against `$defs` for enums
//   * `anyOf` (per-property)          — `$ref` branches follow `$defs`,
//                                        type-only branches infer `SchemaType`
//   * `oneOf` (in `$defs`)            — `const` values extracted as enum
//                                        variants
//
// NOT supported (silently dropped): allOf, if/then/else, patternProperties,
// additionalProperties, pattern, minLength, format, items, prefixItems, etc.
//
// Returns `[]` when `schema` has no `"properties"` key (or it isn't an
// object).

import Foundation
import OpenGrokShared

/// Parse a JSON Schema `"parameters"` object into a list of `ToolArgument`s.
///
/// Mirrors Rust `xai_tool_types::schema_utils::parse_arguments_from_schema_lossy`.
public func parseArgumentsFromSchemaLossy(_ schema: JSONValue) -> [ToolArgument] {
    guard let properties = schema["properties"]?.objectValue else {
        return []
    }
    let requiredSet: Set<String> = {
        guard let arr = schema["required"]?.arrayValue else { return [] }
        return Set(arr.compactMap { $0.stringValue })
    }()
    let defs = schema["$defs"]?.objectValue

    // Preserve JSON object insertion order. JSONValue.object is
    // `[String: JSONValue]` which does NOT preserve order; the Rust
    // `serde_json::Map` (with `preserve_order` feature via
    // `BTreeMap`/`IndexMap`) does. For the lossy extractor the order
    // only affects display; sorting keys gives deterministic output.
    let sortedKeys = properties.keys.sorted()

    return sortedKeys.map { name in
        let prop = properties[name]!
        let resolved = resolveRefType(prop: prop, defs: defs)

        let argType = resolved.type
            ?? (prop["type"].map { SchemaType.from(jsonValue: $0) } ?? .defaultType)

        let description = prop["description"]?.stringValue ?? ""

        let defaultVal: JSONValue? = (resolved.`default` ?? prop["default"]).map { normalizeJSONNumber($0) }

        let isRequired = requiredSet.contains(name)

        let allowedValues: [JSONValue] = (resolved.values
            ?? (prop["allowed_values"] ?? prop["enum"])?.arrayValue ?? [])
            .map(normalizeJSONNumber)

        let schemaVal: JSONValue? = resolved.schema ?? {
            if argType.isComposite {
                return prop
            }
            return nil
        }()

        let minimum = JSONNumber(normalizedFrom: prop["minimum"])
        let maximum = JSONNumber(normalizedFrom: prop["maximum"])
        let exclusiveMinimum = JSONNumber(normalizedFrom: prop["exclusiveMinimum"])
        let exclusiveMaximum = JSONNumber(normalizedFrom: prop["exclusiveMaximum"])

        var arg = ToolArgument(name: name, description: description)
            .withType(argType)
            .withAllowedValues(allowedValues)
        if !isRequired {
            arg = arg.setOptional()
        }
        if let d = defaultVal {
            arg = arg.withDefault(d)
        }
        if let s = schemaVal {
            arg = arg.withSchema(s)
        }
        if let min = minimum {
            arg = arg.withMinimum(min)
        }
        if let max = maximum {
            arg = arg.withMaximum(max)
        }
        if let emin = exclusiveMinimum {
            arg = arg.withExclusiveMinimum(emin)
        }
        if let emax = exclusiveMaximum {
            arg = arg.withExclusiveMaximum(emax)
        }
        return arg
    }
}

// MARK: - $ref / $defs / anyOf / oneOf resolution

/// Result of resolving a property's `$ref`/`anyOf` patterns.
private struct ResolvedRef {
    var type: SchemaType?
    var values: [JSONValue]?
    var `default`: JSONValue?
    var schema: JSONValue?
}

/// Resolve type info from a property, following `$ref` → `$defs` and
/// `anyOf` patterns that schemars generates for Rust enums and
/// `Option<Enum>` types.
///
/// Mirrors Rust `resolve_ref_type`. Returns `(type, allowed_values,
/// default, raw_schema)`.
private func resolveRefType(prop: JSONValue, defs: [String: JSONValue]?) -> ResolvedRef {
    guard let propObj = prop.objectValue else {
        return ResolvedRef()
    }

    // Pattern 1: `anyOf` — schemars uses this for `Option<Enum>` and
    // union types.
    if let anyOf = propObj["anyOf"]?.arrayValue {
        // Check if any branch is a `$ref` to a `$defs` enum.
        for item in anyOf {
            if case .string(let refPath) = item["$ref"] ?? .null,
               refPath.hasPrefix("#/$defs/"),
               let enumName = refPath.split(separator: "/").last.map(String.init),
               let enumDef = defs?[enumName]
            {
                let extracted = extractEnumFromDef(enumDef)
                return ResolvedRef(
                    type: extracted.type.map { SchemaType.single($0) },
                    values: extracted.values,
                    default: extracted.`default`,
                    schema: nil
                )
            }
        }

        // No $ref found — infer a union type from the branches' `type`
        // fields.
        if propObj["type"] == nil {
            let types = anyOf.compactMap { branch -> ArgumentType? in
                guard case .string(let s) = branch["type"] ?? .null else { return nil }
                return ArgumentType(rawValue: s)
            }
            let schemaType: SchemaType? = {
                switch types.count {
                case 0: return nil
                case 1: return .single(types[0])
                default: return .multiple(types)
                }
            }()
            if schemaType != nil {
                return ResolvedRef(
                    type: schemaType,
                    values: nil,
                    default: nil,
                    schema: .object(propObj)
                )
            }
        }
    }

    // Pattern 2: direct `$ref` (no `anyOf` wrapper) — schemars uses this
    // for non-optional enum fields.
    if case .string(let refPath) = propObj["$ref"] ?? .null,
       refPath.hasPrefix("#/$defs/"),
       let enumName = refPath.split(separator: "/").last.map(String.init),
       let enumDef = defs?[enumName]
    {
        let extracted = extractEnumFromDef(enumDef)
        return ResolvedRef(
            type: extracted.type.map { SchemaType.single($0) },
            values: extracted.values,
            default: extracted.`default`,
            schema: nil
        )
    }

    return ResolvedRef()
}

/// Extract enum info from a `$defs` entry.
///
/// Handles two schemars patterns:
///   * Compact: `{ "type": "string", "enum": ["a", "b"] }`
///   * oneOf:   `{ "oneOf": [{ "const": "a" }, { "const": "b" }] }`
///
/// Mirrors Rust `extract_enum_from_def`.
private func extractEnumFromDef(_ enumDef: JSONValue) -> (type: ArgumentType?, values: [JSONValue]?, `default`: JSONValue?) {
    guard let obj = enumDef.objectValue else {
        return (nil, nil, nil)
    }

    // Compact form: `"enum": [...]`
    if case .array(let values)? = obj["enum"], !values.isEmpty {
        let firstValue = values.first
        return (inferArgType(firstValue), values, firstValue)
    }

    // oneOf form: `"oneOf": [{"const": ...}, ...]`
    guard case .array(let oneOf)? = obj["oneOf"] else {
        return (nil, nil, nil)
    }
    var values: [JSONValue] = []
    var firstValue: JSONValue? = nil
    for variant in oneOf {
        if let constVal = variant["const"] {
            if firstValue == nil {
                firstValue = constVal
            }
            values.append(constVal)
        }
    }
    if values.isEmpty {
        return (nil, nil, nil)
    }
    return (inferArgType(firstValue), values, firstValue)
}

/// Infer the `ArgumentType` from a sample enum value.
///
/// Mirrors Rust `infer_arg_type`. Defaults to `.string` for unknown shapes.
private func inferArgType(_ sample: JSONValue?) -> ArgumentType {
    switch sample {
    case .string: return .string
    case .number(let n):
        switch n {
        case .int64, .uint64: return .integer
        case .double: return .number
        }
    case .bool: return .boolean
    default: return .string
    }
}

// MARK: - JSONNumber helper

/// Normalise whole-number `.double` values inside a `JSONValue` to
/// `.int64`/`.uint64`, matching Rust `serde_json::Number` semantics.
///
/// Programmatically constructed schemas can still carry whole-number
/// `.double(...)` values, but JSON Schema values like `"default": 10`
/// should be `.number(.int64(10))` (matching Rust
/// `serde_json::Number::from(10)`). This normaliser walks the value and
/// converts whole-number doubles to their integer representation,
/// preferring `.int64` for values that fit (matching the Rust
/// `serde_json::Number` i64/u64/f64 representation where small positive
/// integers are stored as `PosInt(u64)` but compare equal to `I64`).
private func normalizeJSONNumber(_ v: JSONValue) -> JSONValue {
    switch v {
    case .number(let n):
        if case .double(let d) = n, d.truncatingRemainder(dividingBy: 1) == 0 {
            // Prefer Int64 for values that fit (including small positive
            // integers), then UInt64 for large positive, then Double.
            if let i = Int64(exactly: d) {
                return .number(.int64(i))
            } else if d >= 0, let u = UInt64(exactly: d) {
                return .number(.uint64(u))
            }
        }
        return .number(n)
    case .array(let arr):
        return .array(arr.map(normalizeJSONNumber))
    case .object(let dict):
        return .object(dict.mapValues(normalizeJSONNumber))
    default:
        return v
    }
}

extension JSONNumber {
    /// Construct a `JSONNumber` from a `JSONValue`, returning `nil` for
    /// non-numbers. Used by the schema parser for `minimum`/`maximum` etc.
    public init?(jsonValue v: JSONValue) {
        if case .number(let n) = v {
            self = n
        } else {
            return nil
        }
    }

    /// Construct a `JSONNumber` from a `JSONValue`, normalising whole-number
    /// doubles to `Int64`/`UInt64` to match Rust `serde_json::Number` semantics.
    ///
    /// Programmatically constructed schema bounds may still be whole-number
    /// doubles. Values like `"minimum": 0` should be `.int64(0)` (matching
    /// Rust `serde_json::Number::from(0)`), so this normaliser converts them
    /// to their integer representation.
    public init?(normalizedFrom v: JSONValue?) {
        guard let v = v else { return nil }
        guard case .number(let n) = v else { return nil }
        switch n {
        case .double(let d):
            // Normalise whole-number doubles to Int64/UInt64, preferring
            // Int64 for values that fit (matching the normalizeJSONNumber
            // function's preference and Rust serde_json::Number semantics
            // where small positive integers compare equal to i64).
            if d.truncatingRemainder(dividingBy: 1) == 0 {
                if let i = Int64(exactly: d) {
                    self = .int64(i)
                } else if d >= 0, let u = UInt64(exactly: d) {
                    self = .uint64(u)
                } else {
                    self = .double(d)
                }
            } else {
                self = .double(d)
            }
        default:
            self = n
        }
    }

    /// Convert this `JSONNumber` back to a `JSONValue` for encoding.
    public var jsonValue: JSONValue {
        .number(self)
    }
}
