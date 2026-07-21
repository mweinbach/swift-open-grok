// OpenGrokToolTypes.swift
//
// Open Grok — Swift port of `xai-tool-types` (crates/common/xai-tool-types).
//
// Canonical, extensible tool-description types for the Open Grok platform:
//   * `ToolDescription` — model-facing tool declaration (name, namespace,
//     title, description, JSON Schema arguments, kind, opaque extensions).
//   * `ToolArgument` — a single flat argument extracted from a JSON Schema.
//   * `SchemaType` / `ArgumentType` — JSON Schema `"type"` representation.
//   * `ValidationError` / `ValidationErrors` — structural invariant failures.
//   * `Extensions` — type-keyed, cloneable, runtime-only metadata that is
//     NOT serialized and compares as equal (so `ToolDescription`'s derived
//     equality ignores it).
//
// Wire compatibility: every Codable type round-trips byte-significantly
// against the Rust `serde_json` fixtures. Optional fields use
// `encodeNil`-skipping so `None`/`nil` is omitted on the wire, matching
// `#[serde(skip_serializing_if = "Option::is_none")]`. `required` defaults
// to `true` and is omitted when `true`, matching
// `#[serde(default = "default_true", skip_serializing_if = "is_true")]`.
//
// Rust crate mapping: crates/common/xai-tool-types. See CRATE_MAP.md (W1-S1).

import Foundation
import OpenGrokShared

// MARK: - ArgumentType

/// JSON Schema primitive type for a tool argument.
///
/// Mirrors Rust `xai_tool_types::types::ArgumentType`. Serializes as a
/// lowercase string (`"string"`, `"integer"`, …). Unknown wire values are
/// rejected by `decodeFromSchemaType(_:)` (returns `nil`) and by
/// `init(from:)` (throws), matching the Rust `serde` rejection of
/// `"custom_thing"`.
public enum ArgumentType: String, Codable, Sendable, Hashable, CaseIterable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
    case null

    /// Snake/lowercase wire string (e.g. `"string"`). Equals `rawValue`.
    public var wireString: String { rawValue }

    /// Parse from a JSON Schema `"type"` string. Returns `nil` for
    /// unrecognised values, matching Rust `ArgumentType::from_schema_type`.
    public static func from(schemaType s: String) -> ArgumentType? {
        ArgumentType(rawValue: s)
    }

    /// `true` for primitive scalar types (string, integer, number, boolean,
    /// null). Mirrors Rust `ArgumentType::is_primitive`.
    public var isPrimitive: Bool {
        switch self {
        case .string, .integer, .number, .boolean, .null: return true
        case .array, .object: return false
        }
    }

    /// `true` for numeric types (integer, number).
    public var isNumeric: Bool {
        switch self {
        case .integer, .number: return true
        default: return false
        }
    }

    /// `true` for composite types (array, object).
    public var isComposite: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }
}

// MARK: - SchemaType

/// JSON Schema `"type"` value — either a single type (`"string"`) or an
/// array of types (`["string", "null"]`).
///
/// Mirrors Rust `xai_tool_types::types::SchemaType`. Serializes via the
/// `singleOrMultiple` strategy: a single type renders as a bare string,
/// multiple types render as an array of strings. This matches Rust's
/// `#[serde(untagged)]` enum.
public enum SchemaType: Codable, Sendable, Hashable {
    case single(ArgumentType)
    case multiple([ArgumentType])

    /// Default is `Single(.string)` (Rust uses `ArgumentType::default()` =
    /// `String`).
    public static let defaultType: SchemaType = .single(.string)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try string first (Single), then array (Multiple).
        if let s = try? container.decode(String.self),
           let t = ArgumentType(rawValue: s)
        {
            self = .single(t)
            return
        }
        if let arr = try? container.decode([String].self) {
            let types = arr.compactMap { ArgumentType(rawValue: $0) }
            switch types.count {
            case 0:
                self = .defaultType
            case 1:
                self = .single(types[0])
            default:
                self = .multiple(types)
            }
            return
        }
        // Non-string, non-array → default, matching Rust's fallthrough.
        self = .defaultType
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let t):
            try container.encode(t.rawValue)
        case .multiple(let types):
            try container.encode(types.map(\.rawValue))
        }
    }

    /// Parse a `JSONValue` (already-decoded JSON) into a `SchemaType`,
    /// matching Rust `SchemaType::from_value`.
    public static func from(jsonValue v: JSONValue) -> SchemaType {
        switch v {
        case .string(let s):
            if let t = ArgumentType(rawValue: s) {
                return .single(t)
            }
            return .defaultType
        case .array(let arr):
            let types = arr.compactMap { item -> ArgumentType? in
                if case .string(let s) = item {
                    return ArgumentType(rawValue: s)
                }
                return nil
            }
            switch types.count {
            case 0: return .defaultType
            case 1: return .single(types[0])
            default: return .multiple(types)
            }
        default:
            return .defaultType
        }
    }

    /// The "primary" (first non-null) type, used for classification.
    public var primaryType: ArgumentType {
        switch self {
        case .single(let t): return t
        case .multiple(let types):
            return types.first(where: { $0 != .null }) ?? .null
        }
    }

    /// `true` when the union includes `.null`.
    public var isNullable: Bool {
        switch self {
        case .single(let t): return t == .null
        case .multiple(let types): return types.contains(.null)
        }
    }

    /// `true` when the union contains `ty`.
    public func contains(_ ty: ArgumentType) -> Bool {
        switch self {
        case .single(let t): return t == ty
        case .multiple(let types): return types.contains(ty)
        }
    }

    /// `true` when every type in the union is primitive.
    public var isPrimitive: Bool {
        switch self {
        case .single(let t): return t.isPrimitive
        case .multiple(let types): return types.allSatisfy(\.isPrimitive)
        }
    }

    /// `true` when ANY type in the union is composite.
    public var isComposite: Bool {
        switch self {
        case .single(let t): return t.isComposite
        case .multiple(let types): return types.contains(where: \.isComposite)
        }
    }

    /// `true` when ANY type in the union is numeric.
    public var isNumeric: Bool {
        switch self {
        case .single(let t): return t.isNumeric
        case .multiple(let types): return types.contains(where: \.isNumeric)
        }
    }

    /// JSON Schema `"type"` representation as a `JSONValue`.
    public func toSchemaValue() -> JSONValue {
        switch self {
        case .single(let t):
            return .string(t.rawValue)
        case .multiple(let types):
            return .array(types.map { .string($0.rawValue) })
        }
    }
}

// MARK: - ToolArgument

/// A single argument for a tool, extracted from a JSON Schema.
///
/// Mirrors Rust `xai_tool_types::types::ToolArgument`. The `required`
/// field defaults to `true` and is OMITTED from JSON when `true` (matching
/// `#[serde(default = "default_true", skip_serializing_if = "is_true")]`).
/// `allowedValues` is omitted when empty.
public struct ToolArgument: Codable, Sendable, Hashable {
    /// Argument name (e.g. `"file_path"`).
    public var name: String

    /// Human-readable description.
    public var description: String

    /// Argument type. Encoded under the `"type"` key.
    public var argType: SchemaType

    /// Schema for Array/Object types; ignored for primitives.
    public var schema: JSONValue?

    /// Whether the argument is required. Defaults to `true`; omitted from
    /// JSON when `true`.
    public var required: Bool

    /// Default value.
    public var `default`: JSONValue?

    /// Restricted set of valid values. Empty means no restrictions.
    /// Omitted from JSON when empty.
    public var allowedValues: [JSONValue]

    /// Inclusive lower bound (JSON Schema `minimum`).
    public var minimum: JSONNumber?

    /// Inclusive upper bound (JSON Schema `maximum`).
    public var maximum: JSONNumber?

    /// Exclusive lower bound (JSON Schema `exclusiveMinimum`).
    public var exclusiveMinimum: JSONNumber?

    /// Exclusive upper bound (JSON Schema `exclusiveMaximum`).
    public var exclusiveMaximum: JSONNumber?

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case argType = "type"
        case schema
        case required
        case `default`
        case allowedValues = "allowed_values"
        case minimum
        case maximum
        case exclusiveMinimum = "exclusiveMinimum"
        case exclusiveMaximum = "exclusiveMaximum"
    }

    public init(name: String, description: String) {
        self.name = name
        self.description = description
        self.argType = .defaultType
        self.schema = nil
        self.required = true
        self.`default` = nil
        self.allowedValues = []
        self.minimum = nil
        self.maximum = nil
        self.exclusiveMinimum = nil
        self.exclusiveMaximum = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decode(String.self, forKey: .description)
        // `type` defaults to SchemaType.default when absent.
        if c.contains(.argType) {
            self.argType = try c.decode(SchemaType.self, forKey: .argType)
        } else {
            self.argType = .defaultType
        }
        self.schema = try c.decodeIfPresent(JSONValue.self, forKey: .schema)
        // `required` defaults to true when absent.
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        self.`default` = try c.decodeIfPresent(JSONValue.self, forKey: .default)
        self.allowedValues = try c.decodeIfPresent([JSONValue].self, forKey: .allowedValues) ?? []
        // JSONNumber is Codable (via extension in SchemaUtils.swift) and
        // decodes Int64 → UInt64 → Double, preserving integer precision.
        self.minimum = try c.decodeIfPresent(JSONNumber.self, forKey: .minimum)
        self.maximum = try c.decodeIfPresent(JSONNumber.self, forKey: .maximum)
        self.exclusiveMinimum = try c.decodeIfPresent(JSONNumber.self, forKey: .exclusiveMinimum)
        self.exclusiveMaximum = try c.decodeIfPresent(JSONNumber.self, forKey: .exclusiveMaximum)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(argType, forKey: .argType)
        try c.encodeIfPresent(schema, forKey: .schema)
        // Omit `required` when true (the default).
        if !required {
            try c.encode(false, forKey: .required)
        }
        try c.encodeIfPresent(`default`, forKey: .default)
        if !allowedValues.isEmpty {
            try c.encode(allowedValues, forKey: .allowedValues)
        }
        // JSONNumber is Codable; encode directly.
        try c.encodeIfPresent(minimum, forKey: .minimum)
        try c.encodeIfPresent(maximum, forKey: .maximum)
        try c.encodeIfPresent(exclusiveMinimum, forKey: .exclusiveMinimum)
        try c.encodeIfPresent(exclusiveMaximum, forKey: .exclusiveMaximum)
    }

    // MARK: Builders (mirror Rust's with_* chain)

    public func withType(_ t: SchemaType) -> ToolArgument {
        var copy = self
        copy.argType = t
        return copy
    }

    public func withType(_ t: ArgumentType) -> ToolArgument {
        withType(.single(t))
    }

    public func withSchema(_ s: JSONValue) -> ToolArgument {
        var copy = self
        copy.schema = s
        return copy
    }

    public func setOptional() -> ToolArgument {
        var copy = self
        copy.required = false
        return copy
    }

    public func withDefault(_ d: JSONValue) -> ToolArgument {
        var copy = self
        copy.`default` = d
        return copy
    }

    public func withAllowedValues(_ values: [JSONValue]) -> ToolArgument {
        var copy = self
        copy.allowedValues = values
        return copy
    }

    public func withMinimum(_ n: JSONNumber) -> ToolArgument {
        var copy = self
        copy.minimum = n
        return copy
    }

    public func withMaximum(_ n: JSONNumber) -> ToolArgument {
        var copy = self
        copy.maximum = n
        return copy
    }

    public func withExclusiveMinimum(_ n: JSONNumber) -> ToolArgument {
        var copy = self
        copy.exclusiveMinimum = n
        return copy
    }

    public func withExclusiveMaximum(_ n: JSONNumber) -> ToolArgument {
        var copy = self
        copy.exclusiveMaximum = n
        return copy
    }
}

// MARK: - Validation

/// A single structural validation failure for a `ToolDescription`.
public struct ValidationError: Error, Sendable, Hashable, CustomStringConvertible {
    public var field: String
    public var message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { "\(field): \(message)" }
}

/// A collection of `ValidationError`s (all issues found, not just the first).
public struct ValidationErrors: Error, Sendable, Hashable, Sequence, CustomStringConvertible {
    public let errors: [ValidationError]

    public init(_ errors: [ValidationError]) {
        self.errors = errors
    }

    public var count: Int { errors.count }
    public var isEmpty: Bool { errors.isEmpty }

    public func makeIterator() -> Array<ValidationError>.Iterator {
        errors.makeIterator()
    }

    public var description: String {
        errors.map(\.description).joined(separator: "; ")
    }
}

/// Validate a `ToolDescription` identifier (name or namespace).
///
/// Mirrors Rust `validate_identifier`: empty strings are rejected, and
/// every character must be ASCII alphanumeric, `_`, or `-`.
public func validateIdentifier(field: String, value: String) -> ValidationError? {
    if value.isEmpty {
        return ValidationError(field: field, message: "\(field) must not be empty")
    }
    let allValid = value.allSatisfy { c in
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
    }
    if !allValid {
        return ValidationError(
            field: field,
            message: "\(field) \"\(value)\" contains invalid characters (allowed: a-z, A-Z, 0-9, _, -)"
        )
    }
    return nil
}

// MARK: - Extensions (runtime-only, type-keyed metadata)

/// Cloneable, type-keyed storage for runtime-only metadata.
///
/// Mirrors Rust `xai_tool_types::ext::Extensions`. NOT serialized and NOT
/// part of equality: two `Extensions` always compare equal, so a
/// `ToolDescription`'s derived equality ignores its `extra` field.
///
/// Swift's type-erasure story differs from Rust's `Box<dyn Any + Send +
/// Sync>`: we store values behind a `AnyExtensionValue` protocol with a
/// `copy()` requirement. Concrete stored values must conform to
/// `ExtensionValue` (which is `Sendable`).
public protocol ExtensionValue: Sendable {
    func copy() -> AnyExtensionValue
}

/// Type-erased extension value.
public struct AnyExtensionValue: @unchecked Sendable {
    fileprivate let base: any ExtensionValue

    public init(_ base: any ExtensionValue) {
        self.base = base
    }

    public func copy() -> AnyExtensionValue { base.copy() }

    public func `as`<T>(_ type: T.Type) -> T? where T: ExtensionValue {
        base as? T
    }
}

/// Cloneable, type-keyed storage for metadata.
///
/// `Extensions` always compares as equal (it carries opaque runtime data),
/// so `ToolDescription`'s derived equality ignores this field — matching
/// Rust's `impl PartialEq for Extensions { fn eq(&self, _: &Self) -> bool { true } }`.
public struct Extensions: @unchecked Sendable {
    fileprivate var entries: [ObjectIdentifier: AnyExtensionValue]

    public init() {
        self.entries = [:]
    }

    public func get<T>(_ type: T.Type) -> T? where T: ExtensionValue {
        guard let boxed = entries[ObjectIdentifier(T.self)] else { return nil }
        return boxed.as(T.self)
    }

    public mutating func set<T>(_ value: T) where T: ExtensionValue {
        entries[ObjectIdentifier(T.self)] = AnyExtensionValue(value)
    }

    public mutating func remove<T>(_ type: T.Type) -> T? where T: ExtensionValue {
        guard let boxed = entries.removeValue(forKey: ObjectIdentifier(T.self)) else {
            return nil
        }
        return boxed.as(T.self)
    }

    public func contains<T>(_ type: T.Type) -> Bool where T: ExtensionValue {
        entries[ObjectIdentifier(T.self)] != nil
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
}

extension Extensions: Equatable {
    public static func == (lhs: Extensions, rhs: Extensions) -> Bool {
        // Always equal — runtime-only metadata, matches Rust.
        return true
    }
}

extension Extensions: Hashable {
    public func hash(into hasher: inout Hasher) {
        // Hash as empty so equality is consistent with `==`.
        hasher.combine(0)
    }
}

// MARK: - ToolDescription

/// Canonical, extensible tool description.
///
/// Mirrors Rust `xai_tool_types::types::ToolDescription`. The `extra`
/// field is runtime-only metadata: it is NOT serialized (no `CodingKeys`
/// entry) and compares as equal, so two descriptions with different
/// `extra` values are equal.
public struct ToolDescription: Codable, Sendable, Hashable {
    /// Tool name (e.g. `"web_search"`, `"read_file"`).
    public var name: String

    /// Optional namespace grouping (e.g. `"github"`, `"slack"`). `nil` for
    /// xAI native tools.
    public var namespace: String?

    /// Display name shown to the model. If absent, derive from `name`.
    public var title: String?

    /// Description of the tool.
    public var description: String

    /// Raw JSON Schema describing the tool's arguments.
    public var argumentsSchema: JSONValue?

    /// High-level tool kind (stable snake_case, e.g. `"read"`), set by the
    /// tool server. `nil` if undeclared.
    public var kind: String?

    /// Runtime-only metadata. NOT serialized and NOT part of equality.
    public var extra: Extensions

    private enum CodingKeys: String, CodingKey {
        case name, namespace, title, description
        case argumentsSchema = "arguments_schema"
        case kind
    }

    public init(name: String, description: String) {
        self.name = name
        self.namespace = nil
        self.title = nil
        self.description = description
        self.argumentsSchema = nil
        self.kind = nil
        self.extra = Extensions()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.description = try c.decode(String.self, forKey: .description)
        self.argumentsSchema = try c.decodeIfPresent(JSONValue.self, forKey: .argumentsSchema)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        self.extra = Extensions()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(namespace, forKey: .namespace)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(argumentsSchema, forKey: .argumentsSchema)
        try c.encodeIfPresent(kind, forKey: .kind)
        // `extra` is intentionally NOT encoded.
    }

    // MARK: Builders

    public func withNamespace(_ ns: String) -> ToolDescription {
        var copy = self
        copy.namespace = ns
        return copy
    }

    public func withKind(_ k: String) -> ToolDescription {
        var copy = self
        copy.kind = k
        return copy
    }

    public func withTitle(_ t: String) -> ToolDescription {
        var copy = self
        copy.title = t
        return copy
    }

    public func withArgumentsSchema(_ schema: JSONValue) -> ToolDescription {
        var copy = self
        copy.argumentsSchema = schema
        return copy
    }

    // MARK: Schema accessors

    /// The raw JSON Schema for the tool's arguments, if attached.
    public func argumentsSchemaValue() -> JSONValue? {
        argumentsSchema
    }

    /// Derive structured arguments from the attached `argumentsSchema`.
    ///
    /// **Lossy** — extracts flat, top-level properties and a limited subset
    /// of JSON Schema keywords. Used by UI/render helpers that do not speak
    /// full JSON Schema. See `parseArgumentsFromSchemaLossy(_:)`.
    public func toArgumentsLossy() -> [ToolArgument] {
        guard let schema = argumentsSchema else { return [] }
        return parseArgumentsFromSchemaLossy(schema)
    }

    /// Return the JSON Schema for this tool's arguments.
    ///
    /// If a raw `argumentsSchema` is attached, return it verbatim
    /// (preserving top-level `$defs`). Otherwise return an empty object
    /// schema `{"type":"object","properties":{},"required":[]}`.
    public func toInputSchema() -> JSONValue {
        if let raw = argumentsSchema {
            return raw
        }
        return .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([]),
        ])
    }

    /// Validate structural invariants: `name` is non-empty and contains
    /// only `[a-zA-Z0-9_-]`; `namespace` (if set) follows the same rules.
    /// Returns all issues found (not just the first).
    public func validate() -> Result<Void, ValidationErrors> {
        var errors: [ValidationError] = []
        if let e = validateIdentifier(field: "name", value: name) {
            errors.append(e)
        }
        if let ns = namespace {
            if ns.isEmpty {
                errors.append(ValidationError(
                    field: "namespace",
                    message: "namespace must not be empty when set"
                ))
            } else if let e = validateIdentifier(field: "namespace", value: ns) {
                errors.append(e)
            }
        }
        if errors.isEmpty {
            return .success(())
        }
        return .failure(ValidationErrors(errors))
    }
}

extension ToolDescription {
    /// Display format: `namespace.name — description` or `name — description`.
    /// Used for display/debugging only; not a canonical identifier.
    ///
    /// Note: This is NOT `CustomStringConvertible.description` because
    /// `ToolDescription` already has a stored property named `description`
    /// (the tool's description text, which is wire-significant). The Rust
    /// `fmt::Display` impl maps to this method instead.
    public var displayDescription: String {
        let id = namespace.map { "\($0).\(name)" } ?? name
        if description.isEmpty {
            return id
        }
        return "\(id) — \(description)"
    }
}
