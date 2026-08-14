// LiveConversationStructuredOutput.swift
//
// Open Grok — StructuredOutput synthetic tool loop and JSON schema validator.
// Ported from the Rust reference at pin 650c1db7 / b849ec76:
//
//   * `STRUCTURED_OUTPUT_TOOL` & `STRUCTURED_OUTPUT_MAX_RETRIES` —
//     `crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn.rs:8-66`.
//   * `validate_structured_output` —
//     `turn.rs:55-66`.
//   * Synthetic tool steering & ToolSpec injection —
//     `turn.rs:2370-2396, 2512-2522`.
//   * Co-emission disambiguation & retry loop —
//     `turn.rs:1939-1987, 3056-3101`.
//   * ACP _meta structuredOutput / structuredOutputError serialization —
//     `crates/codegen/xai-grok-shell/src/agent/mvp_agent/mod.rs:571-594`.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolTypes

extension String: @retroactive Error {}

// MARK: - Constants

public enum StructuredOutputConstants {
    public static let toolName = "StructuredOutput"
    public static let maxRetries: UInt32 = 3
    public static let schemaName = "structured_output"
    public static let systemReminder =
        "A response schema is required. After any tool use, call the "
        + "`StructuredOutput` tool exactly once with your final answer as its "
        + "arguments; do not return the answer as text."
    public static let toolDescription =
        "Return your final answer as JSON matching the required schema. "
        + "Call this exactly once, at the end."
    public static let acceptedMessage = "Structured output accepted."
    public static let coEmittedRefusal =
        "Call StructuredOutput alone, exactly once, after all other tools finish."
    public static let retrySuffix = "Fix the arguments and call StructuredOutput again."
}

// MARK: - Step Outcome State Machine

public enum StructuredOutputStep: Sendable, Equatable {
    case complete(Result<JSONValue, String>)
    case retry(toolResult: String)
    case proceed(remainingToolCalls: [ToolCall])
}

// MARK: - JSON Schema Validator

public struct JSONSchemaValidator: Sendable {
    public let schema: JSONValue

    public init(schema: JSONValue) throws {
        self.schema = schema
        try Self.validateSchema(schema)
    }

    public static func validateSchema(_ schema: JSONValue) throws {
        guard schema.objectValue != nil || schema.boolValue != nil else {
            throw CLIApplicationError.failed("invalid output schema: schema must be an object or boolean")
        }
    }

    public func validate(raw: String) -> Result<JSONValue, String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .failure("model output was not valid JSON: parse error")
        }
        return validate(value: json)
    }

    public func validate(value: JSONValue) -> Result<JSONValue, String> {
        do {
            try Self.validateValue(value, against: schema)
            return .success(value)
        } catch let err as CLIApplicationError {
            return .failure("output does not match the required schema: \(err.description)")
        } catch {
            return .failure("output does not match the required schema: \(error)")
        }
    }

    private static func validateValue(_ value: JSONValue, against schema: JSONValue) throws {
        if let boolSchema = schema.boolValue {
            if !boolSchema {
                throw CLIApplicationError.failed("schema is false (rejects all values)")
            }
            return
        }

        guard let schemaObj = schema.objectValue else {
            throw CLIApplicationError.failed("schema must be an object")
        }

        // 1. type
        if let typeVal = schemaObj["type"] {
            try validateType(value, typeVal: typeVal)
        }

        // 2. enum
        if let enumVal = schemaObj["enum"]?.arrayValue {
            guard enumVal.contains(value) else {
                throw CLIApplicationError.failed("value \(value) is not in enum \(enumVal)")
            }
        }

        // 3. const
        if let constVal = schemaObj["const"] {
            guard value == constVal else {
                throw CLIApplicationError.failed("value \(value) does not match const \(constVal)")
            }
        }

        // 4. Object validations
        if let obj = value.objectValue {
            // required properties
            if let requiredArr = schemaObj["required"]?.arrayValue {
                for req in requiredArr {
                    guard let key = req.stringValue else { continue }
                    if obj[key] == nil {
                        throw CLIApplicationError.failed("missing required property '\(key)'")
                    }
                }
            }

            // properties
            let properties = schemaObj["properties"]?.objectValue ?? [:]
            for (key, propSchema) in properties {
                if let propVal = obj[key] {
                    try validateValue(propVal, against: propSchema)
                }
            }

            // additionalProperties
            if let addProps = schemaObj["additionalProperties"] {
                if let allowAdd = addProps.boolValue {
                    if !allowAdd {
                        for key in obj.keys {
                            if properties[key] == nil {
                                throw CLIApplicationError.failed("unexpected additional property '\(key)'")
                            }
                        }
                    }
                } else if addProps.objectValue != nil {
                    for (key, propVal) in obj {
                        if properties[key] == nil {
                            try validateValue(propVal, against: addProps)
                        }
                    }
                }
            }

            // minProperties / maxProperties
            if let minProps = schemaObj["minProperties"]?.int64Value {
                guard obj.count >= minProps else {
                    throw CLIApplicationError.failed("object properties count \(obj.count) is less than minProperties \(minProps)")
                }
            }
            if let maxProps = schemaObj["maxProperties"]?.int64Value {
                guard obj.count <= maxProps else {
                    throw CLIApplicationError.failed("object properties count \(obj.count) is greater than maxProperties \(maxProps)")
                }
            }
        }

        // 5. Array validations
        if let arr = value.arrayValue {
            if let itemsSchema = schemaObj["items"] {
                for (index, item) in arr.enumerated() {
                    do {
                        try validateValue(item, against: itemsSchema)
                    } catch {
                        throw CLIApplicationError.failed("array item at index \(index) invalid: \(error.localizedDescription)")
                    }
                }
            }
            if let minItems = schemaObj["minItems"]?.int64Value {
                guard arr.count >= minItems else {
                    throw CLIApplicationError.failed("array length \(arr.count) is less than minItems \(minItems)")
                }
            }
            if let maxItems = schemaObj["maxItems"]?.int64Value {
                guard arr.count <= maxItems else {
                    throw CLIApplicationError.failed("array length \(arr.count) is greater than maxItems \(maxItems)")
                }
            }
        }

        // 6. String validations
        if let str = value.stringValue {
            if let minLen = schemaObj["minLength"]?.int64Value {
                guard str.count >= minLen else {
                    throw CLIApplicationError.failed("string length \(str.count) is less than minLength \(minLen)")
                }
            }
            if let maxLen = schemaObj["maxLength"]?.int64Value {
                guard str.count <= maxLen else {
                    throw CLIApplicationError.failed("string length \(str.count) is greater than maxLength \(maxLen)")
                }
            }
        }

        // 7. Number validations
        if let num = value.doubleValue {
            if let min = schemaObj["minimum"]?.doubleValue {
                guard num >= min else {
                    throw CLIApplicationError.failed("number \(num) is less than minimum \(min)")
                }
            }
            if let max = schemaObj["maximum"]?.doubleValue {
                guard num <= max else {
                    throw CLIApplicationError.failed("number \(num) is greater than maximum \(max)")
                }
            }
            if let exMin = schemaObj["exclusiveMinimum"]?.doubleValue {
                guard num > exMin else {
                    throw CLIApplicationError.failed("number \(num) is less than or equal to exclusiveMinimum \(exMin)")
                }
            }
            if let exMax = schemaObj["exclusiveMaximum"]?.doubleValue {
                guard num < exMax else {
                    throw CLIApplicationError.failed("number \(num) is greater than or equal to exclusiveMaximum \(exMax)")
                }
            }
        }

        // 8. Combinators: allOf, anyOf, oneOf
        if let allOf = schemaObj["allOf"]?.arrayValue {
            for sub in allOf {
                try validateValue(value, against: sub)
            }
        }
        if let anyOf = schemaObj["anyOf"]?.arrayValue {
            var matched = false
            for sub in anyOf {
                if (try? validateValue(value, against: sub)) != nil {
                    matched = true
                    break
                }
            }
            guard matched else {
                throw CLIApplicationError.failed("value does not match any schema in anyOf")
            }
        }
        if let oneOf = schemaObj["oneOf"]?.arrayValue {
            var matchCount = 0
            for sub in oneOf {
                if (try? validateValue(value, against: sub)) != nil {
                    matchCount += 1
                }
            }
            guard matchCount == 1 else {
                throw CLIApplicationError.failed("value matched \(matchCount) schemas in oneOf, expected exactly 1")
            }
        }
    }

    private static func validateType(_ value: JSONValue, typeVal: JSONValue) throws {
        let allowedTypes: [String]
        if let single = typeVal.stringValue {
            allowedTypes = [single]
        } else if let arr = typeVal.arrayValue {
            allowedTypes = arr.compactMap(\.stringValue)
        } else {
            return
        }

        let matches = allowedTypes.contains { typeStr in
            switch typeStr {
            case "null": return value.isNull
            case "boolean": return value.boolValue != nil
            case "string": return value.stringValue != nil
            case "number": return value.doubleValue != nil
            case "integer":
                if let d = value.doubleValue {
                    return floor(d) == d
                }
                return false
            case "object": return value.objectValue != nil
            case "array": return value.arrayValue != nil
            default: return true
            }
        }

        guard matches else {
            throw CLIApplicationError.failed("expected type \(allowedTypes.joined(separator: ", ")), got \(valueTypeName(value))")
        }
    }

    private static func valueTypeName(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .number(let n):
            if n.int64Value != nil || n.uint64Value != nil { return "integer" }
            return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - Structured Output Turn Coordinator

public struct StructuredOutputTurnCoordinator: Sendable {
    public let validator: JSONSchemaValidator?
    public let backend: ApiBackend
    public let codeModeOnly: Bool
    public private(set) var retries: UInt32 = 0

    public init(
        schema: JSONValue?,
        backend: ApiBackend,
        codeModeOnly: Bool = false
    ) {
        self.backend = backend
        self.codeModeOnly = codeModeOnly
        if let schema {
            self.validator = try? JSONSchemaValidator(schema: schema)
        } else {
            self.validator = nil
        }
    }

    public var structuredOutputNative: Bool {
        validator != nil && backend.supportsNativeSchema
    }

    public var structuredOutputTool: Bool {
        validator != nil && !backend.supportsNativeSchema && !codeModeOnly
    }

    public func prepareRequest(
        tools: [ToolSpec]
    ) -> (tools: [ToolSpec], systemReminder: String?, nativeSchema: JSONValue?) {
        guard let validator else {
            return (tools: tools, systemReminder: nil, nativeSchema: nil)
        }

        if structuredOutputNative {
            return (tools: tools, systemReminder: nil, nativeSchema: validator.schema)
        } else if structuredOutputTool {
            var nextTools = tools
            nextTools.append(ToolSpec(
                name: StructuredOutputConstants.toolName,
                description: StructuredOutputConstants.toolDescription,
                parameters: validator.schema
            ))
            return (
                tools: nextTools,
                systemReminder: StructuredOutputConstants.systemReminder,
                nativeSchema: nil
            )
        } else {
            return (tools: tools, systemReminder: nil, nativeSchema: nil)
        }
    }

    public mutating func handleToolCalls(
        _ toolCalls: [ToolCall]
    ) -> (step: StructuredOutputStep, results: [(callID: String, content: String)]) {
        let structuredCalls = toolCalls.filter { $0.name == StructuredOutputConstants.toolName }
        guard !structuredCalls.isEmpty else {
            return (step: .proceed(remainingToolCalls: toolCalls), results: [])
        }

        // Co-emitted tools: strip StructuredOutput and return guidance
        if toolCalls.count > 1 {
            let results = structuredCalls.map {
                (callID: $0.id, content: StructuredOutputConstants.coEmittedRefusal)
            }
            let remaining = toolCalls.filter { $0.name != StructuredOutputConstants.toolName }
            return (step: .proceed(remainingToolCalls: remaining), results: results)
        }

        // Sole StructuredOutput call
        guard let soleCall = structuredCalls.first else {
            return (step: .proceed(remainingToolCalls: toolCalls), results: [])
        }

        guard let validator else {
            return (
                step: .complete(.failure("no validator configured for structured output")),
                results: [(callID: soleCall.id, content: "invalid output schema: no validator configured")]
            )
        }

        let rawArgs = soleCall.arguments
        let validationResult = validator.validate(raw: rawArgs)
        switch validationResult {
        case .success(let value):
            return (
                step: .complete(.success(value)),
                results: [(callID: soleCall.id, content: StructuredOutputConstants.acceptedMessage)]
            )
        case .failure(let errorMsg):
            if retries < StructuredOutputConstants.maxRetries {
                retries += 1
                let corrective = "\(errorMsg)\n\(StructuredOutputConstants.retrySuffix)"
                return (
                    step: .retry(toolResult: corrective),
                    results: [(callID: soleCall.id, content: corrective)]
                )
            } else {
                return (
                    step: .complete(.failure(errorMsg)),
                    results: [(callID: soleCall.id, content: errorMsg)]
                )
            }
        }
    }

    public func validateAssistantText(_ text: String) -> Result<JSONValue, String>? {
        guard let validator else { return nil }
        return validator.validate(raw: text)
    }
}
