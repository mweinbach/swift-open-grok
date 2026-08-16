// OpenGrokToolTypesTests.swift
//
// Open Grok — Swift port of `xai-tool-types` tests.
//
// Translates the Rust unit tests from:
//   * crates/common/xai-tool-types/src/types.rs (inline `mod tests`)
//   * crates/common/xai-tool-types/src/schema_utils.rs (inline `mod tests`)
//   * crates/common/xai-tool-types/src/serde_lenient.rs (inline `mod tests`)
//   * crates/common/xai-tool-types/src/ext.rs (inline `mod tests`)
//   * crates/common/xai-tool-types/src/task.rs (inline `mod tests`)
//
// Uses Swift Testing (import Testing) to match the W0 convention.

import Testing
import Foundation
@testable import OpenGrokToolTypes
import OpenGrokShared

// MARK: - Helpers

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8)!
}

private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: Data(json.utf8))
}

private func jsonValue(_ s: String) throws -> JSONValue {
    try decodeJSON(JSONValue.self, s)
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let s = try encodeJSON(value)
    return try decodeJSON(T.self, s)
}

// MARK: - ArgumentType tests

@Suite("ArgumentType")
struct ArgumentTypeTests {
    @Test("serde roundtrip for every variant")
    func serdeRoundtrip() throws {
        let cases: [(ArgumentType, String)] = [
            (.string, "\"string\""),
            (.integer, "\"integer\""),
            (.number, "\"number\""),
            (.boolean, "\"boolean\""),
            (.array, "\"array\""),
            (.object, "\"object\""),
            (.null, "\"null\""),
        ]
        for (ty, expected) in cases {
            let json = try encodeJSON(ty)
            #expect(json == expected, "ArgumentType.\(ty) serializes to \(expected)")
            let parsed = try decodeJSON(ArgumentType.self, json)
            #expect(parsed == ty)
        }
    }

    @Test("wireString equals rawValue")
    func wireString() {
        #expect(ArgumentType.string.wireString == "string")
        #expect(ArgumentType.integer.wireString == "integer")
        #expect(ArgumentType.object.wireString == "object")
        #expect(ArgumentType.null.wireString == "null")
    }

    @Test("rejects unknown wire value")
    func rejectsUnknown() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(ArgumentType.self, "\"custom_thing\"")
        }
    }

    @Test("classification: primitive / composite / numeric")
    func classification() {
        #expect(ArgumentType.string.isPrimitive)
        #expect(ArgumentType.integer.isPrimitive)
        #expect(ArgumentType.null.isPrimitive)
        #expect(!ArgumentType.array.isPrimitive)
        #expect(!ArgumentType.object.isPrimitive)

        #expect(ArgumentType.array.isComposite)
        #expect(ArgumentType.object.isComposite)
        #expect(!ArgumentType.string.isComposite)
        #expect(!ArgumentType.null.isComposite)

        #expect(ArgumentType.integer.isNumeric)
        #expect(ArgumentType.number.isNumeric)
        #expect(!ArgumentType.string.isNumeric)
    }
}

// MARK: - SchemaType tests

@Suite("SchemaType")
struct SchemaTypeTests {
    @Test("single serde roundtrip")
    func singleRoundtrip() throws {
        let st = SchemaType.single(.string)
        let json = try encodeJSON(st)
        #expect(json == "\"string\"")
        let parsed = try decodeJSON(SchemaType.self, json)
        #expect(parsed == st)
    }

    @Test("multiple serde roundtrip")
    func multipleRoundtrip() throws {
        let st = SchemaType.multiple([.string, .null])
        // Use an unsorted encoder so array order is preserved (matching
        // Rust serde_json which does not sort keys by default).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(st)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "[\"string\",\"null\"]")
        let parsed = try decodeJSON(SchemaType.self, json)
        #expect(parsed == st)
    }

    @Test("from JSONValue: string")
    func fromValueString() throws {
        let v = try jsonValue("\"integer\"")
        #expect(SchemaType.from(jsonValue: v) == .single(.integer))
    }

    @Test("from JSONValue: array")
    func fromValueArray() throws {
        let v = try jsonValue("[\"string\",\"null\"]")
        #expect(SchemaType.from(jsonValue: v) == .multiple([.string, .null]))
    }

    @Test("from JSONValue: single-element array normalised to single")
    func fromValueSingleElementArray() throws {
        let v = try jsonValue("[\"boolean\"]")
        #expect(SchemaType.from(jsonValue: v) == .single(.boolean))
    }

    @Test("from JSONValue: unknown falls back to default")
    func fromValueUnknownFallsBack() throws {
        let v = try jsonValue("\"custom_thing\"")
        #expect(SchemaType.from(jsonValue: v) == .defaultType)
    }

    @Test("from JSONValue: non-string non-array falls back")
    func fromValueNonStringNonArray() throws {
        let v = try jsonValue("42")
        #expect(SchemaType.from(jsonValue: v) == .defaultType)
    }

    @Test("primaryType")
    func primaryType() {
        #expect(SchemaType.single(.integer).primaryType == .integer)
        #expect(SchemaType.multiple([.string, .null]).primaryType == .string)
        // All-null falls back to .null
        #expect(SchemaType.multiple([.null]).primaryType == .null)
    }

    @Test("isNullable")
    func isNullable() {
        #expect(!SchemaType.single(.string).isNullable)
        #expect(SchemaType.single(.null).isNullable)
        #expect(SchemaType.multiple([.string, .null]).isNullable)
        #expect(!SchemaType.multiple([.string, .integer]).isNullable)
    }

    @Test("contains")
    func contains() {
        let st = SchemaType.multiple([.string, .null])
        #expect(st.contains(.string))
        #expect(st.contains(.null))
        #expect(!st.contains(.integer))
    }

    @Test("primitive / composite (single)")
    func primitiveCompositeSingle() {
        #expect(SchemaType.single(.string).isPrimitive)
        #expect(!SchemaType.single(.string).isComposite)

        #expect(!SchemaType.single(.array).isPrimitive)
        #expect(SchemaType.single(.array).isComposite)

        #expect(SchemaType.single(.null).isPrimitive)
        #expect(!SchemaType.single(.null).isComposite)
    }

    @Test("primitive / composite (multiple)")
    func primitiveCompositeMultiple() {
        let nullableString = SchemaType.multiple([.string, .null])
        #expect(nullableString.isPrimitive)
        #expect(!nullableString.isComposite)

        let nullableArray = SchemaType.multiple([.array, .null])
        #expect(!nullableArray.isPrimitive)
        #expect(nullableArray.isComposite)

        let mixed = SchemaType.multiple([.string, .object])
        #expect(!mixed.isPrimitive)
        #expect(mixed.isComposite)
    }

    @Test("default is single string")
    func defaultIsSingleString() {
        #expect(SchemaType.defaultType == .single(.string))
    }
}

// MARK: - ToolArgument tests

@Suite("ToolArgument")
struct ToolArgumentTests {
    @Test("new defaults")
    func newDefaults() {
        let arg = ToolArgument(name: "query", description: "Search query")
        #expect(arg.name == "query")
        #expect(arg.argType == .single(.string))
        #expect(arg.required)
        #expect(arg.`default` == nil)
        #expect(arg.allowedValues.isEmpty)
    }

    @Test("builder chain")
    func builderChain() throws {
        let arg = ToolArgument(name: "mode", description: "Processing mode")
            .withType(.string)
            .withAllowedValues([.string("fast"), .string("slow"), .string("auto")])
            .setOptional()
            .withDefault(.string("auto"))

        #expect(!arg.required)
        #expect(arg.`default` == .string("auto"))
        #expect(arg.allowedValues.count == 3)
    }

    @Test("withDefault does not change required")
    func withDefaultDoesNotChangeRequired() throws {
        let arg = ToolArgument(name: "x", description: "test").withDefault(.number(.int64(42)))
        #expect(arg.required)
        #expect(arg.`default` == .number(.int64(42)))
    }

    @Test("serde roundtrip")
    func serdeRoundtrip() throws {
        // Use string allowed-values to avoid JSONNumber case-tag mismatches
        // (JSONValue decodes all JSON numbers as .double, so .int64 values
        // don't survive a Codable round-trip as .int64).
        let arg = ToolArgument(name: "count", description: "Number of items")
            .withType(.integer)
            .setOptional()
            .withDefault(.string("five"))
            .withAllowedValues([.string("one"), .string("five"), .string("ten")])

        let parsed = try roundTrip(arg)
        #expect(arg == parsed)
    }

    @Test("required=true omitted from JSON; required=false present")
    func serdeRequiredDefaultOmitted() throws {
        // Required=true is the default, so it should be omitted.
        let argReq = ToolArgument(name: "x", description: "test")
        let jsonReq = try encodeJSON(argReq)
        #expect(!jsonReq.contains("required"), "required=true should be omitted: \(jsonReq)")

        // Optional should include required=false.
        let argOpt = ToolArgument(name: "x", description: "test").setOptional()
        let jsonOpt = try encodeJSON(argOpt)
        #expect(jsonOpt.contains("\"required\":false"), "required=false should be present: \(jsonOpt)")
    }

    @Test("deserialize missing required defaults true")
    func deserializeMissingRequiredDefaultsTrue() throws {
        let json = #"{"name":"x","description":"test","type":"string"}"#
        let arg = try decodeJSON(ToolArgument.self, json)
        #expect(arg.required)
    }
}

// MARK: - ToolDescription tests

@Suite("ToolDescription")
struct ToolDescriptionTests {
    @Test("new defaults")
    func newDefaults() {
        let tool = ToolDescription(name: "search", description: "Search things")
        #expect(tool.name == "search")
        #expect(tool.description == "Search things")
        #expect(tool.namespace == nil)
        #expect(tool.title == nil)
        #expect(tool.toArgumentsLossy().isEmpty)
        #expect(tool.argumentsSchema == nil)
    }

    @Test("toInputSchema prefers raw with $defs")
    func toInputSchemaPrefersRawWithDefs() throws {
        let raw = try jsonValue(##"{"type":"object","$defs":{"PricingItemSpec":{"type":"object","properties":{"amount":{"type":"number"}}}},"properties":{"item":{"$ref":"#/$defs/PricingItemSpec"}},"required":["item"]}"##)
        let tool = ToolDescription(name: "price", description: "Price a thing").withArgumentsSchema(raw)
        #expect(tool.toInputSchema() == raw)
    }

    @Test("toInputSchema empty when no raw")
    func toInputSchemaEmptyWhenNoRaw() throws {
        let tool = ToolDescription(name: "echo", description: "Echo a string")
        let schema = tool.toInputSchema()
        if case .object(let dict) = schema {
            #expect(dict["type"] == .string("object"))
            #expect(dict["properties"] == .object([:]))
        } else {
            Issue.record("expected object schema")
        }
    }

    @Test("arguments_schema serde roundtrip preserves $defs")
    func argumentsSchemaSerdeRoundtrip() throws {
        let raw = try jsonValue(##"{"type":"object","$defs":{"X":{"type":"string","enum":["a","b"]}},"properties":{"x":{"$ref":"#/$defs/X"}}}"##)
        let tool = ToolDescription(name: "t", description: "d").withArgumentsSchema(raw)
        let back = try roundTrip(tool)
        #expect(back.argumentsSchema == raw)
    }

    @Test("builder chain")
    func builder() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"org":{"type":"string","description":"Organization name"},"limit":{"type":"integer","description":"Max results","default":30}},"required":["org"]}"#)
        let tool = ToolDescription(name: "list_repos", description: "List repositories")
            .withNamespace("github")
            .withTitle("List Repositories")
            .withArgumentsSchema(schema)

        #expect(tool.namespace == "github")
        #expect(tool.toArgumentsLossy().count == 2)
    }

    @Test("display: name — description")
    func display() {
        let tool = ToolDescription(name: "read_file", description: "Read a file").withTitle("Read File")
        // Display uses description, not title.
        #expect(tool.displayDescription == "read_file — Read a file")
    }

    @Test("display: namespaced")
    func displayNamespaced() {
        let tool = ToolDescription(name: "search", description: "Search").withNamespace("github")
        #expect(tool.displayDescription == "github.search — Search")

        let plain = ToolDescription(name: "stop", description: "Stop execution")
        #expect(plain.displayDescription == "stop — Stop execution")
    }

    @Test("serde roundtrip")
    func serdeRoundtrip() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"query":{"type":"string","description":"Search query","enum":["code","issues","prs"]},"limit":{"type":"integer","description":"Max results","default":25}},"required":["query"]}"#)
        let tool = ToolDescription(name: "search", description: "Search repositories")
            .withNamespace("github")
            .withTitle("GitHub Search")
            .withArgumentsSchema(schema)

        let parsed = try roundTrip(tool)
        #expect(tool == parsed)
    }

    @Test("deserialize minimal")
    func deserializeMinimal() throws {
        let json = #"{"name":"stop","description":"Stop"}"#
        let tool = try decodeJSON(ToolDescription.self, json)
        #expect(tool.name == "stop")
        #expect(tool.toArgumentsLossy().isEmpty)
        #expect(tool.extra.isEmpty)
    }

    // -- Validation --

    @Test("validate ok")
    func validateOk() {
        let tool = ToolDescription(name: "good-tool_1", description: "A good tool").withNamespace("my-ns")
        #expect(ToolError.resultSuccess(tool.validate()))
    }

    @Test("validate empty name")
    func validateEmptyName() {
        let tool = ToolDescription(name: "", description: "desc")
        if case .failure(let errors) = tool.validate() {
            #expect(errors.contains { $0.field == "name" })
        } else {
            Issue.record("expected validation failure")
        }
    }

    @Test("validate invalid name chars")
    func validateInvalidNameChars() {
        let tool = ToolDescription(name: "bad name!", description: "desc")
        if case .failure(let errors) = tool.validate() {
            #expect(errors.contains { $0.field == "name" && $0.message.contains("invalid") })
        } else {
            Issue.record("expected validation failure")
        }
    }

    @Test("validate empty namespace")
    func validateEmptyNamespace() {
        var tool = ToolDescription(name: "ok", description: "desc")
        tool.namespace = ""
        if case .failure(let errors) = tool.validate() {
            #expect(errors.contains { $0.field == "namespace" })
        } else {
            Issue.record("expected validation failure")
        }
    }

    @Test("validate collects all errors")
    func validateCollectsAllErrors() {
        var tool = ToolDescription(name: "", description: "desc")
        tool.namespace = ""
        if case .failure(let errors) = tool.validate() {
            #expect(errors.count >= 2)
        } else {
            Issue.record("expected validation failure")
        }
    }
}

// MARK: - Extensions tests

private struct LocalToolContext: ExtensionValue, Equatable {
    var userId: String
    var conversationId: String

    func copy() -> AnyExtensionValue { AnyExtensionValue(self) }
}

@Suite("Extensions")
struct ExtensionsTests {
    @Test("set and get")
    func setAndGet() {
        var ext = Extensions()
        ext.set(LocalToolContext(userId: "123", conversationId: "456"))
        let hints = ext.get(LocalToolContext.self)
        #expect(hints?.userId == "123")
        #expect(hints?.conversationId == "456")
    }

    @Test("missing returns nil")
    func missingReturnsNil() {
        let ext = Extensions()
        #expect(ext.get(LocalToolContext.self) == nil)
        #expect(!ext.contains(LocalToolContext.self))
    }

    @Test("clone preserves values (value type copy)")
    func clonePreservesValues() {
        var ext = Extensions()
        ext.set(LocalToolContext(userId: "123", conversationId: "456"))
        var cloned = ext
        #expect(cloned.get(LocalToolContext.self)?.userId == "123")
        #expect(cloned.get(LocalToolContext.self)?.conversationId == "456")
        // Mutating the clone must not affect the original (value semantics).
        cloned.set(LocalToolContext(userId: "999", conversationId: "888"))
        #expect(ext.get(LocalToolContext.self)?.userId == "123")
    }

    @Test("always equal (runtime-only metadata)")
    func alwaysEqual() {
        var a = Extensions()
        var b = Extensions()
        a.set(LocalToolContext(userId: "1", conversationId: "1"))
        b.set(LocalToolContext(userId: "2", conversationId: "2"))
        #expect(a == b)
    }
}

// MARK: - parseArgumentsFromSchemaLossy tests

@Suite("parseArgumentsFromSchemaLossy")
struct ParseSchemaTests {
    @Test("basic")
    func basic() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"limit":{"type":"integer","description":"Max results","default":10}},"required":["query"]}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args.count == 2)

        let query = args.first { $0.name == "query" }!
        #expect(query.argType == .single(.string))
        #expect(query.required)
        #expect(query.`default` == nil)

        let limit = args.first { $0.name == "limit" }!
        #expect(limit.argType == .single(.integer))
        #expect(!limit.required)
        #expect(limit.`default` == .number(.int64(10)))
    }

    @Test("enum values")
    func enumValues() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"mode":{"type":"string","description":"Processing mode","enum":["fast","slow","auto"],"default":"auto"}}}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args.count == 1)
        #expect(args[0].allowedValues.count == 3)
        #expect(!args[0].required)
    }

    @Test("composite stores schema")
    func compositeStoresSchema() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"filters":{"type":"object","description":"Filter object","properties":{"key":{"type":"string"}}},"tags":{"type":"array","description":"Tag list","items":{"type":"string"}}},"required":["filters"]}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args.count == 2)

        let filters = args.first { $0.name == "filters" }!
        #expect(filters.argType == .single(.object))
        #expect(filters.schema != nil)
        #expect(filters.required)

        let tags = args.first { $0.name == "tags" }!
        #expect(tags.argType == .single(.array))
        #expect(tags.schema != nil)
        #expect(!tags.required)
    }

    @Test("primitives no schema")
    func primitivesNoSchema() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"flag":{"type":"boolean","description":"A flag"}}}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args[0].argType == .single(.boolean))
        #expect(args[0].schema == nil)
    }

    @Test("empty or missing")
    func emptyOrMissing() throws {
        #expect(parseArgumentsFromSchemaLossy(try jsonValue("{}")).isEmpty)
        #expect(parseArgumentsFromSchemaLossy(.null).isEmpty)
        #expect(parseArgumentsFromSchemaLossy(try jsonValue(#"{"properties":null}"#)).isEmpty)
    }

    @Test("required and default are orthogonal")
    func requiredAndDefaultOrthogonal() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"x":{"type":"integer","description":"test","default":1}},"required":["x"]}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args[0].required, "required should be preserved")
        #expect(args[0].`default` == .number(.int64(1)))
    }

    @Test("null type")
    func nullType() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"placeholder":{"type":"null","description":"Always null"}}}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args.count == 1)
        #expect(args[0].argType == .single(.null))
    }

    @Test("nullable string")
    func nullableString() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"name":{"type":["string","null"],"description":"Optional name"}},"required":["name"]}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args.count == 1)
        #expect(args[0].argType.isNullable)
        #expect(args[0].argType.primaryType == .string)
    }

    @Test("multi type no null")
    func multiTypeNoNull() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"value":{"type":["string","integer"],"description":"String or integer"}}}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args.count == 1)
        #expect(!args[0].argType.isNullable)
        #expect(args[0].argType.contains(.string))
        #expect(args[0].argType.contains(.integer))
    }

    // -- $ref / $defs / anyOf resolution --

    @Test("anyOf ref resolves enum")
    func anyOfRefResolvesEnum() throws {
        let schema = try jsonValue(##"{"type":"object","$defs":{"MyEnum":{"oneOf":[{"const":"a"},{"const":"b"}]}},"properties":{"mode":{"anyOf":[{"$ref":"#/$defs/MyEnum"},{"type":"null"}],"default":null,"description":"The mode"}},"required":["mode"]}"##)
        let args = parseArgumentsFromSchemaLossy(schema)
        let mode = args[0]
        #expect(mode.argType == .single(.string))
        #expect(mode.allowedValues == [.string("a"), .string("b")])
        // The resolved default is "a" (first enum variant), not null.
        #expect(mode.`default` == .string("a"))
        #expect(mode.schema == nil)
    }

    @Test("direct ref resolves enum")
    func directRefResolvesEnum() throws {
        let schema = try jsonValue(##"{"type":"object","$defs":{"Color":{"oneOf":[{"const":"red"},{"const":"blue"}]}},"properties":{"color":{"$ref":"#/$defs/Color","description":"Pick a color"}},"required":["color"]}"##)
        let args = parseArgumentsFromSchemaLossy(schema)
        let color = args[0]
        #expect(color.argType == .single(.string))
        #expect(color.allowedValues == [.string("red"), .string("blue")])
    }

    @Test("compact enum in $defs")
    func compactEnumInDefs() throws {
        let schema = try jsonValue(##"{"type":"object","$defs":{"Duration":{"type":"string","enum":["6","10"]}},"properties":{"dur_optional":{"anyOf":[{"$ref":"#/$defs/Duration"},{"type":"null"}],"default":null,"description":"Duration (optional)"},"dur_required":{"$ref":"#/$defs/Duration","description":"Duration (required)"}},"required":["dur_optional","dur_required"]}"##)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args.count == 2)

        let opt = args.first { $0.name == "dur_optional" }!
        #expect(opt.allowedValues == [.string("6"), .string("10")])

        let req = args.first { $0.name == "dur_required" }!
        #expect(req.allowedValues == [.string("6"), .string("10")])
    }

    @Test("anyOf union type without ref")
    func anyOfUnionTypeWithoutRef() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"to":{"anyOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}],"description":"Recipients"}},"required":["to"]}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        let to = args[0]
        #expect(to.argType.primaryType == .string)
        #expect(to.required)
        #expect(to.schema != nil, "anyOf schema should be stored")
    }

    @Test("no defs still works")
    func noDefsStillWorks() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"name":{"type":"string","description":"A name","enum":["x","y"],"default":"x"}}}"#)
        let args = parseArgumentsFromSchemaLossy(schema)
        #expect(args[0].allowedValues == [.string("x"), .string("y")])
        #expect(args[0].`default` == .string("x"))
    }

    // -- numeric constraints --

    @Test("numeric constraints")
    func numericConstraints() throws {
        let schema = try jsonValue(#"{"type":"object","properties":{"offset":{"type":"integer","description":"Start line","minimum":0,"default":1},"limit":{"type":"integer","description":"Line count","exclusiveMinimum":0,"default":2000},"timeout":{"type":"integer","description":"Timeout in seconds","minimum":0,"maximum":600}},"required":["timeout"]}"#)
        let args = parseArgumentsFromSchemaLossy(schema)

        let offset = args.first { $0.name == "offset" }!
        #expect(offset.minimum == .int64(0))
        #expect(offset.maximum == nil)
        #expect(offset.exclusiveMinimum == nil)

        let limit = args.first { $0.name == "limit" }!
        #expect(limit.exclusiveMinimum == .int64(0))
        #expect(limit.minimum == nil)

        let timeout = args.first { $0.name == "timeout" }!
        #expect(timeout.minimum == .int64(0))
        #expect(timeout.maximum == .int64(600))
        #expect(timeout.required)
    }
}

// MARK: - serde_lenient tests

@Suite("LenientBool")
struct LenientBoolTests {
    @Test("parses native bools")
    func nativeBools() {
        #expect(lenientBoolFromJSON(.bool(true)) == true)
        #expect(lenientBoolFromJSON(.bool(false)) == false)
    }

    @Test("parses string true/false")
    func stringTrueFalse() {
        #expect(lenientBoolFromJSON(.string("true")) == true)
        #expect(lenientBoolFromJSON(.string("false")) == false)
    }

    @Test("parses yes/no")
    func yesNo() {
        #expect(lenientBoolFromJSON(.string("yes")) == true)
        #expect(lenientBoolFromJSON(.string("no")) == false)
    }

    @Test("parses string 1/0")
    func stringOneZero() {
        #expect(lenientBoolFromJSON(.string("1")) == true)
        #expect(lenientBoolFromJSON(.string("0")) == false)
    }

    @Test("parses numeric 1/0")
    func numericOneZero() {
        #expect(lenientBoolFromJSON(.number(.int64(1))) == true)
        #expect(lenientBoolFromJSON(.number(.int64(0))) == false)
    }

    @Test("case insensitive and trims")
    func caseInsensitiveAndTrims() {
        #expect(lenientBoolFromJSON(.string("TRUE")) == true)
        #expect(lenientBoolFromJSON(.string("False")) == false)
        #expect(lenientBoolFromJSON(.string("  yes  ")) == true)
        #expect(lenientBoolFromJSON(.string("No")) == false)
    }

    @Test("null is false")
    func nullIsFalse() {
        #expect(lenientBoolFromJSON(.null) == false)
    }

    @Test("rejects unknown forms")
    func rejectsUnknown() {
        let bad: [JSONValue] = [
            .string("maybe"), .string(""), .number(.int64(2)),
            .number(.int64(-1)), .number(.double(1.5)),
            .number(.double(1.0)), .array([]), .object([:]),
        ]
        for v in bad {
            #expect(lenientBoolFromJSON(v) == nil, "should reject \(v)")
        }
    }

    @Test("decodeLenientBool throws on unknown")
    func decodeThrowsOnUnknown() {
        #expect(throws: LenientBoolError.self) {
            try decodeLenientBool(.string("nope"))
        }
    }

    @Test("decodeLenientOptionBool: nil absent vs false null")
    func decodeOptionBool() throws {
        #expect(try decodeLenientOptionBool(nil) == nil)
        #expect(try decodeLenientOptionBool(.null) == false)
        #expect(try decodeLenientOptionBool(.string("yes")) == true)
        #expect(try decodeLenientOptionBool(.number(.int64(0))) == false)
        #expect(throws: LenientBoolError.self) {
            try decodeLenientOptionBool(.string("nope"))
        }
    }
}

// MARK: - TaskTools tests

@Suite("TaskTools")
struct TaskToolsTests {
    private func resultWithStatus(_ status: String) -> TaskOutputOutput {
        .result(TaskOutputResult(taskId: "t", status: status))
    }

    @Test("isTerminal by status")
    func isTerminalByStatus() {
        #expect(!resultWithStatus("running").isTerminal)
        #expect(!resultWithStatus("pending").isTerminal)
        #expect(!resultWithStatus("initializing").isTerminal)
        #expect(!resultWithStatus("").isTerminal)

        #expect(resultWithStatus("completed").isTerminal)
        #expect(resultWithStatus("failed").isTerminal)
        #expect(resultWithStatus("cancelled").isTerminal)
    }

    @Test("isTerminal: not-found and multi")
    func isTerminalNotFoundAndMulti() {
        #expect(!TaskOutputOutput.taskNotFound("x").isTerminal)
        #expect(TaskOutputOutput.multiResult(MultiTaskOutputResult(mode: "wait_all")).isTerminal)
    }

    @Test("TaskToolInput defaults background true")
    func taskToolInputDefaultsBackgroundTrue() throws {
        let input = try decodeJSON(TaskToolInput.self, #"{"description":"test","prompt":"do it"}"#)
        #expect(input.subagentType == "general-purpose")
        #expect(input.runInBackground, "run_in_background should default to true")

        let foreground = try decodeJSON(TaskToolInput.self, #"{"description":"test","prompt":"do it","run_in_background":false}"#)
        #expect(!foreground.runInBackground)
    }

    @Test("TaskToolInput lenient bool for run_in_background")
    func taskToolInputLenientBool() throws {
        let input = try decodeJSON(TaskToolInput.self, #"{"description":"test","prompt":"do it","run_in_background":"yes"}"#)
        #expect(input.runInBackground)
    }

    @Test("TaskToolInput model omitted is nil")
    func taskToolInputModelOmittedIsNil() throws {
        let input = try decodeJSON(TaskToolInput.self, #"{"description":"d","prompt":"p"}"#)
        #expect(input.model == nil)
    }

    @Test("TaskToolInput model parses explicit")
    func taskToolInputModelParsesExplicit() throws {
        let input = try decodeJSON(TaskToolInput.self, #"{"description":"d","prompt":"p","model":"grok-3"}"#)
        #expect(input.model == "grok-3")
    }

    @Test("TaskToolInput reasoning effort parses and round-trips")
    func taskToolInputReasoningEffort() throws {
        let input = try decodeJSON(TaskToolInput.self, #"{"description":"d","prompt":"p","reasoning_effort":"xhigh"}"#)
        #expect(input.reasoningEffort == "xhigh")

        let json = try encodeJSON(input)
        #expect(json.contains(#""reasoning_effort":"xhigh""#))
    }

    @Test("TaskToolInput model nil skips serialize")
    func taskToolInputModelNilSkipsSerialize() throws {
        let input = TaskToolInput(prompt: "p", description: "d", runInBackground: false)
        let json = try encodeJSON(input)
        #expect(!json.contains("\"model\""))
        #expect(!json.contains("\"reasoning_effort\""))
    }

    @Test("sanitizeOptionalArg")
    func sanitizeOptionalArgTest() {
        #expect(sanitizeOptionalArg("grok-3") == "grok-3")
        #expect(sanitizeOptionalArg("  grok-3  ") == "grok-3")
        #expect(sanitizeOptionalArg("null") == nil)
        #expect(sanitizeOptionalArg("  NULL  ") == nil)
        #expect(sanitizeOptionalArg(nil) == nil)
    }

    @Test("resolveTaskIds dedupes and trims")
    func resolveTaskIdsTest() {
        #expect(resolveTaskIds(["a", "b", "a", "  c  ", ""]) == ["a", "b", "c"])
    }

    @Test("taskOutputWaits")
    func taskOutputWaitsTest() {
        #expect(!taskOutputWaits(nil))
        #expect(!taskOutputWaits(0))
        #expect(taskOutputWaits(1))
        #expect(taskOutputWaits(1000))
    }

    @Test("builtin subagent catalog names")
    func builtinSubagentCatalogNames() {
        #expect(builtinSubagents.map(\.name) == ["general-purpose", "explore", "plan"])
    }

    @Test("builtin subagent by name")
    func builtinSubagentByNameLookup() {
        #expect(builtinSubagentByName("explore")?.name == "explore")
        #expect(builtinSubagentByName("general-purpose")?.promptTemplate == generalPurposePrompt)
        #expect(builtinSubagentByName("plan")?.promptTemplate == planPrompt)
        #expect(builtinSubagentByName("code-reviewer") == nil)
    }

    @Test("prompt templates reference tools via by_kind placeholders")
    func promptTemplatesReferenceTools() {
        for b in builtinSubagents {
            #expect(!b.promptTemplate.isEmpty)
            #expect(b.promptTemplate.contains("${{ tools.by_kind."))
        }
        // Read-only profiles carry the read-only banner; general-purpose doesn't.
        #expect(explorePrompt.contains("=== READ-ONLY MODE ==="))
        #expect(planPrompt.contains("=== READ-ONLY MODE ==="))
        #expect(!generalPurposePrompt.contains("READ-ONLY"))
    }

    @Test("renderTools substitutes naming with bare-kind fallback")
    func renderToolsBareKindFallback() {
        let plain = SubagentToolNaming(
            execute: "execute", read: "read", edit: "edit",
            list: "list", search: "search", webSearch: "web_search", plan: "plan"
        )
        #expect(generalPurposeSubagent.renderTools(plain) ==
            "Has access to all tools: execute, read, edit, list, search, web_search, and plan.")
        #expect(planSubagent.renderTools(plain).contains(
            "Read-only \u{2014} has access to all tools except file editing (edit is not available):"
        ))

        let real = SubagentToolNaming(
            execute: "run_terminal_cmd", read: "read_file", edit: "search_replace",
            list: "list_dir", search: "grep", webSearch: "web_search", plan: "todo_write"
        )
        #expect(exploreSubagent.renderTools(real) ==
            "Read-only \u{2014} has access to: read_file, list_dir, grep.")
    }

    @Test("toDescriptor uses bare-kind naming")
    func toDescriptorBareKind() {
        let plain = SubagentToolNaming(
            execute: "execute", read: "read", edit: "edit",
            list: "list", search: "search", webSearch: "web_search", plan: "plan"
        )
        let desc = exploreSubagent.toDescriptor(plain)
        #expect(desc.name == "explore")
        #expect(desc.description == exploreSubagent.description)
        #expect(desc.tools == "Read-only \u{2014} has access to: read, list, search.")
    }

    // -- Description builders (lock exact model-facing text) --

    private func literalNaming() -> TaskToolNaming {
        TaskToolNaming(
            taskTool: "task",
            subagentTypeParam: "subagent_type",
            runInBackgroundParam: "run_in_background",
            resumeFromParam: "resume_from",
            backgroundRetrievalTool: "get_task_output",
            isolationParam: "isolation"
        )
    }

    @Test("buildTaskDescription substitutes names and lists agents")
    func buildTaskDescriptionListsAgents() {
        let subagents = [
            SubagentDescriptor(name: "general-purpose", description: "General-purpose agent.", tools: "Has access to all tools."),
            SubagentDescriptor(name: "code-reviewer", description: "Reviews code.", tools: nil),
        ]
        let desc = buildTaskDescription(subagents: subagents, naming: literalNaming())
        #expect(desc.hasPrefix("Start a subagent that works on a task independently"))
        #expect(desc.contains("Agent types:"))
        #expect(desc.contains("- **general-purpose**: General-purpose agent. Has access to all tools."))
        #expect(desc.contains("- **code-reviewer**: Reviews code."))
        #expect(desc.contains("## Usage notes"))
        #expect(desc.contains(
            "run_in_background: Returns immediately with a subagent_id. Use get_task_output to retrieve results. This is set to true by default."
        ))
        #expect(desc.contains("you must specify a subagent_type parameter"))
        #expect(desc.contains("Use resume_from to continue"))
    }

    @Test("buildTaskDescription includes isolation paragraph")
    func buildTaskDescriptionIncludesIsolation() {
        let subagents = [SubagentDescriptor(name: "explore", description: "Explore.", tools: nil)]
        let desc = buildTaskDescription(subagents: subagents, naming: literalNaming())
        #expect(desc.contains("Isolation mode:"))
        #expect(desc.contains("Use isolation to control the child's execution environment."))
    }

    @Test("buildTaskDescription preserves template placeholders")
    func buildTaskDescriptionPreservesPlaceholders() {
        let subagents = [SubagentDescriptor(
            name: "explore",
            description: "Explore.",
            tools: "Read-only — has access to: ${{ tools.by_kind.read }}."
        )]
        let naming = TaskToolNaming(
            taskTool: "${{ tools.by_kind.task }}",
            subagentTypeParam: "${{ params.task.subagent_type }}",
            runInBackgroundParam: "${{ params.task.run_in_background }}",
            resumeFromParam: "${{ params.task.resume_from }}",
            backgroundRetrievalTool: "${{ tools.by_kind.background_task_action }}",
            isolationParam: "${{ params.task.isolation }}"
        )
        let desc = buildTaskDescription(subagents: subagents, naming: naming)
        #expect(desc.contains("When using the ${{ tools.by_kind.task }} tool"))
        #expect(desc.contains("${{ tools.by_kind.read }}"))
        #expect(desc.contains(
            "${{ params.task.run_in_background }}: Returns immediately with a subagent_id. Use ${{ tools.by_kind.background_task_action }} to retrieve results. This is set to true by default."
        ))
        #expect(desc.contains("Use ${{ params.task.isolation }} to control"))
    }

    // -- Lifecycle tool descriptions --

    @Test("kill_task matches CLI default POSIX")
    func killTaskCliDefaultPosix() {
        let desc = buildKillTaskDescription(KillTaskToolNaming(
            monitorTool: "monitor",
            subagentPresent: true,
            bashPresent: true,
            isWindows: false,
            taskIdParam: "task_id"
        ))
        let expected = """
        Terminate a running background task, monitor, or subagent.

        Usage notes:
        - Pass its task_id (a monitor's task_id is returned by monitor).
        - Sends SIGTERM/SIGKILL to a bash task or monitor; sends Cancel+Shutdown to a subagent.
        - Returns success if the task was killed or had already exited.
        """
        #expect(desc == expected)
    }

    @Test("kill_task matches CLI default Windows")
    func killTaskCliDefaultWindows() {
        let desc = buildKillTaskDescription(KillTaskToolNaming(
            monitorTool: "monitor",
            subagentPresent: true,
            bashPresent: true,
            isWindows: true,
            taskIdParam: "task_id"
        ))
        #expect(desc.contains(
            "- Terminates the Job Object of a bash task or monitor; sends Cancel+Shutdown to a subagent."
        ))
    }

    @Test("kill_task subagent-only toolbox")
    func killTaskSubagentOnly() {
        let desc = buildKillTaskDescription(KillTaskToolNaming(
            monitorTool: nil,
            subagentPresent: true,
            bashPresent: false,
            isWindows: false,
            taskIdParam: "task_id"
        ))
        let expected = """
        Terminate a running background task or subagent.

        Usage notes:
        - Pass its task_id.
        - Sends Cancel+Shutdown to a subagent.
        - Returns success if the task was killed or had already exited.
        """
        #expect(desc == expected)
    }

    @Test("kill_task tracks renamed task_id")
    func killTaskTracksRenamed() {
        let desc = buildKillTaskDescription(KillTaskToolNaming(
            monitorTool: "monitor",
            subagentPresent: false,
            bashPresent: true,
            isWindows: false,
            taskIdParam: "id"
        ))
        #expect(desc.contains("Pass its id (a monitor's id is returned by monitor)"))
        #expect(!desc.contains("task_id"), "canonical task_id must not remain after rename: \(desc)")
    }

    @Test("task_output matches CLI default")
    func taskOutputCliDefault() {
        let desc = buildTaskOutputDescription(TaskOutputToolNaming(
            monitorTool: "monitor",
            readTool: "read_file",
            bashBackgroundParam: "background",
            subagentBackgroundParam: "background",
            taskIdsParam: "task_ids",
            timeoutMsParam: "timeout_ms",
            taskIdParam: "task_id"
        ))
        let expected = """
        Get output and status from a background task, monitor, or subagent.

        Usage notes:
        - Pass task_ids with one or more ids from background=true commands or background=true subagents (a monitor's task_id is returned by monitor); for a single task use a one-element array. Multiple ids with a positive timeout_ms wait until all complete
        - Omit timeout_ms or pass 0 for a non-blocking status snapshot; set a positive timeout_ms to wait up to that many milliseconds, capped at ~10 min
        - Returns current output, status, and exit code if completed
        - If output is large, use read_file on the output_file path
        """
        #expect(desc == expected)
    }

    @Test("task_output subagent-only toolbox")
    func taskOutputSubagentOnly() {
        let desc = buildTaskOutputDescription(TaskOutputToolNaming(
            monitorTool: nil,
            readTool: "read_file",
            bashBackgroundParam: nil,
            subagentBackgroundParam: "run_in_background",
            taskIdsParam: "task_ids",
            timeoutMsParam: "timeout_ms",
            taskIdParam: "task_id"
        ))
        let expected = """
        Get output and status from a background task or subagent.

        Usage notes:
        - Pass task_ids with one or more ids from run_in_background=true subagents; for a single task use a one-element array. Multiple ids with a positive timeout_ms wait until all complete
        - Omit timeout_ms or pass 0 for a non-blocking status snapshot; set a positive timeout_ms to wait up to that many milliseconds, capped at ~10 min
        - Returns current output, status, and exit code if completed
        - If output is large, use read_file on the output_file path
        """
        #expect(desc == expected)
    }

    @Test("wait_tasks matches CLI default")
    func waitTasksCliDefault() {
        let desc = buildWaitTasksDescription(WaitTasksToolNaming(
            backgroundRetrievalTool: "get_command_or_subagent_output",
            bashBackgroundParam: "background",
            subagentBackgroundParam: "background"
        ))
        let expected = """
        Wait for multiple background tasks or subagents to complete.

        Prefer get_command_or_subagent_output with task_ids and a positive timeout_ms. This tool is kept for compatibility.

        Usage notes:
        - task_ids: list of task IDs from background=true or background=true
        - mode: 'wait_all' or 'wait_any'
        - timeout_ms: optional max wait, default 30s, capped at ~10 min
        """
        #expect(desc == expected)
    }

    @Test("wait_tasks subagent-only toolbox")
    func waitTasksSubagentOnly() {
        let desc = buildWaitTasksDescription(WaitTasksToolNaming(
            backgroundRetrievalTool: "get_task_output",
            bashBackgroundParam: nil,
            subagentBackgroundParam: "run_in_background"
        ))
        #expect(desc.contains("- task_ids: list of task IDs from run_in_background=true\n"))
        #expect(desc.contains("Prefer get_task_output with task_ids"))
    }
}

// MARK: - ToolError helper for test ergonomics

private enum ToolError {
    static func resultSuccess(_ result: Result<Void, ValidationErrors>) -> Bool {
        if case .success = result { return true }
        return false
    }
}
