// RhaiMeta.swift
//
// Port of crates/codegen/xai-workflow/src/meta.rs — the `meta` block every
// workflow script must open with, and the validation the registry applies
// before a script is allowed to be installed or run.

import Foundation
import OpenGrokShared

/// meta.rs:21
public struct RhaiPhaseMeta: Sendable, Hashable {
    public var title: String
    public var detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

/// meta.rs:10
public struct RhaiWorkflowMeta: Sendable, Hashable {
    public var name: String
    public var description: String
    public var whenToUse: String?
    public var phases: [RhaiPhaseMeta]

    public init(
        name: String,
        description: String,
        whenToUse: String? = nil,
        phases: [RhaiPhaseMeta] = []
    ) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.phases = phases
    }

    public var json: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "when_to_use": whenToUse.map(JSONValue.string) ?? .null,
            "phases": .array(phases.map { phase in
                .object([
                    "title": .string(phase.title),
                    "detail": phase.detail.map(JSONValue.string) ?? .null,
                ])
            }),
        ])
    }
}

/// meta.rs:28 — message-for-message with the Rust `thiserror` strings.
public enum RhaiMetaError: Error, Sendable, Hashable, CustomStringConvertible {
    case parse(String)
    case metaNotFirst
    case invalidShape(String)
    case missingField(String)
    case invalidName
    case stringTooLong(field: String, maximum: Int, actual: Int)
    case tooManyPhases(maximum: Int, actual: Int)

    public var description: String {
        switch self {
        case .parse(let error):
            return "script failed to parse: \(error)"
        case .metaNotFirst:
            return "first statement must be `let meta = #{ ... };`"
        case .invalidShape(let detail):
            return "meta is not a valid map: \(detail)"
        case .missingField(let field):
            return "\(field) must be a non-empty string"
        case .invalidName:
            return "meta.name must be lowercase ASCII letters or digits separated by single hyphens"
        case .stringTooLong(let field, let maximum, let actual):
            return "\(field) must be at most \(maximum) UTF-8 bytes (got \(actual))"
        case .tooManyPhases(let maximum, let actual):
            return "meta.phases must contain at most \(maximum) entries (got \(actual))"
        }
    }
}

public enum RhaiMeta {
    /// meta.rs:51 — extract and validate the `meta` block.
    ///
    /// Upstream reaches this by compiling the script and reading `meta` out of
    /// the evaluated scope; this port requires the block to be a **pure
    /// literal** instead. That is stricter (upstream would tolerate
    /// `description: "a" + "b"`) and deliberately so: metadata is read by the
    /// registry without running the script, so anything computed could not be
    /// trusted to match what the script would later produce.
    public static func extract(from script: String) throws -> RhaiWorkflowMeta {
        guard firstStatementIsMeta(script) else { throw RhaiMetaError.metaNotFirst }

        let program: RhaiProgram
        do {
            program = try RhaiParser.parse(script)
        } catch let error as RhaiParseError {
            throw RhaiMetaError.parse(rhaiWithHint(error.description))
        }

        guard let first = program.statements.first,
              case .declaration(let declaredName, let value, _, _) = first,
              declaredName == "meta"
        else {
            throw RhaiMetaError.metaNotFirst
        }
        guard let value else { throw RhaiMetaError.metaNotFirst }
        guard case .map(let entries, _) = value else {
            throw RhaiMetaError.invalidShape("meta must be a map literal")
        }

        var fields: [String: JSONValue] = [:]
        var order: [String] = []
        for entry in entries {
            fields[entry.key] = try literal(entry.value, field: "meta.\(entry.key)")
            order.append(entry.key)
        }

        // serde's `deny_unknown_fields` (meta.rs:9).
        let allowed: Set<String> = ["name", "description", "when_to_use", "phases"]
        if let unknown = order.first(where: { !allowed.contains($0) }) {
            throw RhaiMetaError.invalidShape("unknown field `\(unknown)`")
        }

        let name = try requiredString(fields["name"], field: "meta.name")
        let description = try requiredString(fields["description"], field: "meta.description")
        var whenToUse: String?
        if let value = fields["when_to_use"], !value.isNull {
            guard let text = value.stringValue else {
                throw RhaiMetaError.invalidShape("meta.when_to_use must be a string")
            }
            whenToUse = text
        }

        var phases: [RhaiPhaseMeta] = []
        if let value = fields["phases"], !value.isNull {
            guard let items = value.arrayValue else {
                throw RhaiMetaError.invalidShape("meta.phases must be an array")
            }
            for item in items {
                guard let phase = item.objectValue else {
                    throw RhaiMetaError.invalidShape("meta.phases entries must be maps")
                }
                if let unknown = phase.keys.sorted().first(where: { $0 != "title" && $0 != "detail" }) {
                    throw RhaiMetaError.invalidShape("unknown phase field `\(unknown)`")
                }
                guard let title = phase["title"]?.stringValue else {
                    throw RhaiMetaError.missingField("meta.phases[].title")
                }
                var detail: String?
                if let value = phase["detail"], !value.isNull {
                    guard let text = value.stringValue else {
                        throw RhaiMetaError.invalidShape("meta.phases[].detail must be a string")
                    }
                    detail = text
                }
                phases.append(RhaiPhaseMeta(title: title, detail: detail))
            }
        }

        let meta = RhaiWorkflowMeta(
            name: name,
            description: description,
            whenToUse: whenToUse,
            phases: phases
        )
        try validate(meta)
        return meta
    }

    /// meta.rs:82 — the checks in upstream's order, because the first failure
    /// is what the operator sees.
    public static func validate(_ meta: RhaiWorkflowMeta) throws {
        guard !meta.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RhaiMetaError.missingField("meta.name")
        }
        try checkLength("meta.name", meta.name, rhaiMaxWorkflowNameLength)
        guard isValidName(meta.name) else { throw RhaiMetaError.invalidName }

        guard !meta.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RhaiMetaError.missingField("meta.description")
        }
        try checkLength("meta.description", meta.description, rhaiMaxWorkflowDescriptionLength)
        if let whenToUse = meta.whenToUse {
            try checkLength("meta.when_to_use", whenToUse, rhaiMaxWorkflowWhenToUseLength)
        }

        guard meta.phases.count <= rhaiMaxWorkflowPhases else {
            throw RhaiMetaError.tooManyPhases(maximum: rhaiMaxWorkflowPhases, actual: meta.phases.count)
        }
        var seen = Set<String>()
        for (index, phase) in meta.phases.enumerated() {
            guard !phase.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RhaiMetaError.missingField("meta.phases[].title")
            }
            guard seen.insert(phase.title).inserted else {
                throw RhaiMetaError.invalidShape("duplicate meta.phases[].title: \"\(phase.title)\"")
            }
            try checkLength("meta.phases[\(index)].title", phase.title, rhaiMaxPhaseTitleLength)
            if let detail = phase.detail {
                try checkLength("meta.phases[\(index)].detail", detail, rhaiMaxPhaseDetailLength)
            }
        }
    }

    // MARK: - Helpers

    private static func requiredString(_ value: JSONValue?, field: String) throws -> String {
        guard let value else { throw RhaiMetaError.missingField(field) }
        guard let text = value.stringValue else {
            throw RhaiMetaError.invalidShape("\(field) must be a string")
        }
        return text
    }

    private static func checkLength(_ field: String, _ value: String, _ maximum: Int) throws {
        let actual = value.utf8.count
        guard actual <= maximum else {
            throw RhaiMetaError.stringTooLong(field: field, maximum: maximum, actual: actual)
        }
    }

    /// meta.rs:151 — lowercase ASCII letters or digits, single hyphens only,
    /// never leading, trailing, or doubled.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, let last = bytes.last else { return false }
        func isAlphanumeric(_ byte: UInt8) -> Bool {
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
        }
        guard isAlphanumeric(first), isAlphanumeric(last) else { return false }
        guard bytes.allSatisfy({ isAlphanumeric($0) || $0 == 0x2D }) else { return false }
        for index in bytes.indices.dropLast() where bytes[index] == 0x2D && bytes[index + 1] == 0x2D {
            return false
        }
        return true
    }

    /// meta.rs:166 — the textual pre-check, run before parsing so a script
    /// whose `meta` is merely misplaced reports that rather than a parse error.
    static func firstStatementIsMeta(_ script: String) -> Bool {
        var rest = Substring(script)
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.hasPrefix("//") {
                guard let newline = rest.firstIndex(of: "\n") else { return false }
                rest = rest[rest.index(after: newline)...]
                continue
            }
            if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return false }
                rest = rest[end.upperBound...]
                continue
            }
            break
        }
        return rest.hasPrefix("let meta") || rest.hasPrefix("const meta")
    }

    /// The `meta` block is literal-only: every value must fold to a constant
    /// without running anything.
    private static func literal(_ expression: RhaiExpression, field: String) throws -> JSONValue {
        switch expression {
        case .unit:
            return .null
        case .boolean(let value, _):
            return .bool(value)
        case .integer(let value, _):
            return .number(.int64(value))
        case .float(let value, _):
            return .number(.double(value))
        case .string(let value, _):
            return .string(value)
        case .array(let items, _):
            return .array(try items.map { try literal($0, field: field) })
        case .map(let entries, _):
            var fields: [String: JSONValue] = [:]
            for entry in entries {
                fields[entry.key] = try literal(entry.value, field: "\(field).\(entry.key)")
            }
            return .object(fields)
        default:
            throw RhaiMetaError.invalidShape("\(field) must be a literal value")
        }
    }
}
