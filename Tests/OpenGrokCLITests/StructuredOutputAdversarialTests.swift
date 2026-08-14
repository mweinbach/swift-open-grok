// StructuredOutputAdversarialTests.swift
//
// Adversarial edge-case and stress tests for StructuredOutput synthetic tool loop and JSONSchemaValidator.

import Foundation
import Testing
@testable import OpenGrokCLI
@testable import OpenGrokSamplingTypes
@testable import OpenGrokShared
@testable import OpenGrokToolTypes

@Suite("StructuredOutputAdversarialTests")
struct StructuredOutputAdversarialTests {

    // MARK: - 1. Invalid JSON vs Schema Validation Mismatch

    @Test("Adversarial: Invalid JSON string vs schema violation mismatch")
    func testInvalidJsonVsSchemaMismatch() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("city"), .string("population")]),
            "properties": .object([
                "city": .object(["type": .string("string")]),
                "population": .object(["type": .string("integer")])
            ]),
            "additionalProperties": .bool(false)
        ])
        let validator = try JSONSchemaValidator(schema: schema)

        // Case A: Malformed JSON strings (syntax error)
        let malformedInputs = [
            "{city: London}",
            "{",
            "",
            "   \n  \t ",
            "{\"city\": \"London\" \"population\": 9000000}", // missing comma
            "{\"city\": \"London\", \"population\": }", // missing value
            "[1, 2, 3",
            "undefined",
            "<xml></xml>"
        ]

        for input in malformedInputs {
            let res = validator.validate(raw: input)
            guard case .failure(let err) = res else {
                Issue.record("Expected malformed JSON '\(input)' to fail syntax validation")
                continue
            }
            #expect(err.contains("model output was not valid JSON: parse error"), "Got error: \(err)")
        }

        // Case B: Valid JSON but schema violation
        let schemaViolatingInputs = [
            ("{}", "missing required property 'city'"),
            ("{\"city\": \"London\"}", "missing required property 'population'"),
            ("{\"city\": \"London\", \"population\": \"huge\"}", "expected type integer"),
            ("{\"city\": \"London\", \"population\": 9000000, \"country\": \"UK\"}", "unexpected additional property 'country'"),
            ("[1, 2, 3]", "expected type object"),
            ("\"just a string\"", "expected type object"),
            ("12345", "expected type object"),
            ("null", "expected type object")
        ]

        for (input, expectedSubstring) in schemaViolatingInputs {
            let res = validator.validate(raw: input)
            guard case .failure(let err) = res else {
                Issue.record("Expected input '\(input)' to fail schema validation")
                continue
            }
            #expect(err.contains("output does not match the required schema:"), "Got error: \(err)")
            #expect(err.contains(expectedSubstring), "Got error: \(err), expected substring: \(expectedSubstring)")
        }
    }

    // MARK: - 2. Complex Nested Object and Array Validation

    @Test("Adversarial: Deeply nested objects, arrays of objects, and schema additionalProperties")
    func testComplexNestedObjectAndArrayValidation() throws {
        let nestedSchema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("account")]),
            "properties": .object([
                "account": .object([
                    "type": .string("object"),
                    "required": .array([.string("user")]),
                    "properties": .object([
                        "user": .object([
                            "type": .string("object"),
                            "required": .array([.string("profile")]),
                            "properties": .object([
                                "profile": .object([
                                    "type": .string("object"),
                                    "required": .array([.string("address")]),
                                    "properties": .object([
                                        "address": .object([
                                            "type": .string("object"),
                                            "required": .array([.string("city"), .string("zip")]),
                                            "properties": .object([
                                                "city": .object(["type": .string("string"), "minLength": .number(.int64(2))]),
                                                "zip": .object(["type": .string("integer"), "minimum": .number(.int64(10000)), "maximum": .number(.int64(99999))])
                                            ]),
                                            "additionalProperties": .bool(false)
                                        ])
                                    ])
                                ])
                            ])
                        ])
                    ])
                ]),
                "tags": .object([
                    "type": .string("array"),
                    "minItems": .number(.int64(2)),
                    "maxItems": .number(.int64(3)),
                    "items": .object([
                        "type": .string("object"),
                        "required": .array([.string("id"), .string("label")]),
                        "properties": .object([
                            "id": .object(["type": .string("integer")]),
                            "label": .object(["type": .string("string")])
                        ]),
                        "additionalProperties": .bool(false)
                    ])
                ]),
                "meta": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "version": .object(["type": .string("integer")])
                    ]),
                    "additionalProperties": .object([
                        "type": .string("string")
                    ])
                ])
            ])
        ])

        let validator = try JSONSchemaValidator(schema: nestedSchema)

        // Valid deep structure
        let validJSON = """
        {
          "account": {
            "user": {
              "profile": {
                "address": {
                  "city": "Metropolis",
                  "zip": 12345
                }
              }
            }
          },
          "tags": [
            {"id": 1, "label": "primary"},
            {"id": 2, "label": "verified"}
          ],
          "meta": {
            "version": 1,
            "customTagA": "valueA",
            "customTagB": "valueB"
          }
        }
        """
        let validRes = validator.validate(raw: validJSON)
        guard case .success(let val) = validRes else {
            Issue.record("Expected valid nested JSON to pass: \(validRes)")
            return
        }
        #expect(val.objectValue?["account"]?.objectValue?["user"]?.objectValue?["profile"]?.objectValue?["address"]?.objectValue?["city"]?.stringValue == "Metropolis")

        // Invalid: deep nested zip out of range
        let invalidZipJSON = """
        {
          "account": {
            "user": {
              "profile": {
                "address": {
                  "city": "Metropolis",
                  "zip": 999
                }
              }
            }
          }
        }
        """
        let invalidZipRes = validator.validate(raw: invalidZipJSON)
        #expect(!invalidZipRes.isSuccess)

        // Invalid: array items too few (minItems: 2)
        let tooFewTagsJSON = """
        {
          "account": {
            "user": {
              "profile": {
                "address": {
                  "city": "Metropolis",
                  "zip": 12345
                }
              }
            }
          },
          "tags": [
            {"id": 1, "label": "single"}
          ]
        }
        """
        let tooFewRes = validator.validate(raw: tooFewTagsJSON)
        guard case .failure(let err) = tooFewRes else {
            Issue.record("Expected too few items to fail")
            return
        }
        #expect(err.contains("array length 1 is less than minItems 2"))

        // Invalid: additionalProperties in meta has non-string value (violates schema additionalProperties)
        let invalidMetaJSON = """
        {
          "account": {
            "user": {
              "profile": {
                "address": {
                  "city": "Metropolis",
                  "zip": 12345
                }
              }
            }
          },
          "meta": {
            "version": 1,
            "customNumber": 999
          }
        }
        """
        let invalidMetaRes = validator.validate(raw: invalidMetaJSON)
        guard case .failure(let errMeta) = invalidMetaRes else {
            Issue.record("Expected invalid meta additional property to fail")
            return
        }
        #expect(errMeta.contains("expected type string"))
    }

    // MARK: - 3. Combinators (allOf, anyOf, oneOf) and Enums

    @Test("Adversarial: Combinators allOf, anyOf, oneOf, const, and enums")
    func testCombinatorsAndEnums() throws {
        // allOf: Must satisfy both schemas (has 'a' of type string AND has 'b' of type integer)
        let allOfSchema: JSONValue = .object([
            "allOf": .array([
                .object([
                    "type": .string("object"),
                    "required": .array([.string("a")]),
                    "properties": .object(["a": .object(["type": .string("string")])])
                ]),
                .object([
                    "type": .string("object"),
                    "required": .array([.string("b")]),
                    "properties": .object(["b": .object(["type": .string("integer")])])
                ])
            ])
        ])
        let allOfValidator = try JSONSchemaValidator(schema: allOfSchema)

        #expect(!allOfValidator.validate(raw: "{\"a\": \"hello\"}").isSuccess)
        #expect(!allOfValidator.validate(raw: "{\"b\": 42}").isSuccess)
        #expect(allOfValidator.validate(raw: "{\"a\": \"hello\", \"b\": 42}").isSuccess)

        // anyOf: Must satisfy at least one schema (string or integer)
        let anyOfSchema: JSONValue = .object([
            "anyOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("integer")])
            ])
        ])
        let anyOfValidator = try JSONSchemaValidator(schema: anyOfSchema)

        #expect(anyOfValidator.validate(raw: "\"valid string\"").isSuccess)
        #expect(anyOfValidator.validate(raw: "100").isSuccess)
        #expect(!anyOfValidator.validate(raw: "true").isSuccess)
        #expect(!anyOfValidator.validate(raw: "{\"key\": \"val\"}").isSuccess)

        // oneOf: Must satisfy EXACTLY one schema
        // Schema 1: string with maxLength 3
        // Schema 2: string with minLength 2
        let oneOfSchema: JSONValue = .object([
            "oneOf": .array([
                .object(["type": .string("string"), "maxLength": .number(.int64(3))]),
                .object(["type": .string("string"), "minLength": .number(.int64(2))])
            ])
        ])
        let oneOfValidator = try JSONSchemaValidator(schema: oneOfSchema)

        // "a" has length 1 -> matches Schema 1 only -> PASS (count == 1)
        #expect(oneOfValidator.validate(raw: "\"a\"").isSuccess)

        // "abcd" has length 4 -> matches Schema 2 only -> PASS (count == 1)
        #expect(oneOfValidator.validate(raw: "\"abcd\"").isSuccess)

        // "ab" has length 2 -> matches BOTH Schema 1 (<=3) and Schema 2 (>=2) -> FAIL (count == 2)
        let twoMatch = oneOfValidator.validate(raw: "\"ab\"")
        guard case .failure(let errTwo) = twoMatch else {
            Issue.record("Expected oneOf with 2 matches to fail")
            return
        }
        #expect(errTwo.contains("value matched 2 schemas in oneOf, expected exactly 1"))

        // 123 -> matches NEITHER -> FAIL (count == 0)
        let zeroMatch = oneOfValidator.validate(raw: "123")
        guard case .failure(let errZero) = zeroMatch else {
            Issue.record("Expected oneOf with 0 matches to fail")
            return
        }
        #expect(errZero.contains("value matched 0 schemas in oneOf, expected exactly 1"))

        // const and enum tests
        let constEnumSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object(["const": .string("user")]),
                "role": .object(["enum": .array([.string("admin"), .string("member"), .null])])
            ])
        ])
        let constEnumValidator = try JSONSchemaValidator(schema: constEnumSchema)

        #expect(constEnumValidator.validate(raw: "{\"kind\": \"user\", \"role\": \"admin\"}").isSuccess)
        #expect(constEnumValidator.validate(raw: "{\"kind\": \"user\", \"role\": null}").isSuccess)
        #expect(!constEnumValidator.validate(raw: "{\"kind\": \"guest\", \"role\": \"admin\"}").isSuccess)
        #expect(!constEnumValidator.validate(raw: "{\"kind\": \"user\", \"role\": \"superadmin\"}").isSuccess)
    }

    // MARK: - 4. Numerical Ranges and Boundary Conditions

    @Test("Adversarial: Exclusive and inclusive numerical bounds")
    func testNumericalRangesAndBoundaries() throws {
        let rangeSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "inclusive": .object([
                    "type": .string("number"),
                    "minimum": .number(.double(10.0)),
                    "maximum": .number(.double(20.0))
                ]),
                "exclusive": .object([
                    "type": .string("number"),
                    "exclusiveMinimum": .number(.double(5.0)),
                    "exclusiveMaximum": .number(.double(15.0))
                ])
            ])
        ])
        let validator = try JSONSchemaValidator(schema: rangeSchema)

        // Inclusive boundaries
        #expect(validator.validate(raw: "{\"inclusive\": 10.0}").isSuccess)
        #expect(validator.validate(raw: "{\"inclusive\": 20.0}").isSuccess)
        #expect(validator.validate(raw: "{\"inclusive\": 15.0}").isSuccess)
        #expect(!validator.validate(raw: "{\"inclusive\": 9.999}").isSuccess)
        #expect(!validator.validate(raw: "{\"inclusive\": 20.001}").isSuccess)

        // Exclusive boundaries
        #expect(!validator.validate(raw: "{\"exclusive\": 5.0}").isSuccess)
        #expect(!validator.validate(raw: "{\"exclusive\": 15.0}").isSuccess)
        #expect(validator.validate(raw: "{\"exclusive\": 5.0001}").isSuccess)
        #expect(validator.validate(raw: "{\"exclusive\": 14.999}").isSuccess)
    }

    // MARK: - 5. Boolean Schemas (true / false)

    @Test("Adversarial: Boolean schema support (true accepts all, false rejects all)")
    func testBooleanSchemas() throws {
        let trueValidator = try JSONSchemaValidator(schema: .bool(true))
        #expect(trueValidator.validate(raw: "{\"any\": \"object\"}").isSuccess)
        #expect(trueValidator.validate(raw: "[1, 2, 3]").isSuccess)
        #expect(trueValidator.validate(raw: "\"hello\"").isSuccess)
        #expect(trueValidator.validate(raw: "42").isSuccess)
        #expect(trueValidator.validate(raw: "null").isSuccess)

        let falseValidator = try JSONSchemaValidator(schema: .bool(false))
        #expect(!falseValidator.validate(raw: "{\"any\": \"object\"}").isSuccess)
        #expect(!falseValidator.validate(raw: "[1, 2, 3]").isSuccess)
        #expect(!falseValidator.validate(raw: "\"hello\"").isSuccess)
        #expect(!falseValidator.validate(raw: "42").isSuccess)
        #expect(!falseValidator.validate(raw: "null").isSuccess)
    }

    // MARK: - 6. 3-Retries Boundary and Recovery

    @Test("Adversarial: 3-retries exact boundary, exhaustion, and recovery on intermediate attempt")
    func testRetriesExhaustionAndRecovery() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("target")]),
            "properties": .object(["target": .object(["type": .string("integer")])])
        ])

        // Coordinator A: Fails all 4 attempts -> exhausts on 4th
        var coordExhaust = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .messages,
            codeModeOnly: false
        )

        let invalidCall = ToolCall(
            id: "call_bad",
            name: StructuredOutputConstants.toolName,
            arguments: "{\"target\": \"not_an_int\"}"
        )

        // Attempt 1 -> retry (retries becomes 1)
        let (step1, res1) = coordExhaust.handleToolCalls([invalidCall])
        guard case .retry(let toolRes1) = step1 else {
            Issue.record("Expected retry on attempt 1, got \(step1)")
            return
        }
        #expect(coordExhaust.retries == 1)
        #expect(toolRes1.contains(StructuredOutputConstants.retrySuffix))
        #expect(res1[0].content.contains(StructuredOutputConstants.retrySuffix))

        // Attempt 2 -> retry (retries becomes 2)
        let (step2, res2) = coordExhaust.handleToolCalls([invalidCall])
        guard case .retry(let toolRes2) = step2 else {
            Issue.record("Expected retry on attempt 2, got \(step2)")
            return
        }
        #expect(coordExhaust.retries == 2)
        #expect(toolRes2.contains(StructuredOutputConstants.retrySuffix))
        #expect(res2[0].content.contains(StructuredOutputConstants.retrySuffix))

        // Attempt 3 -> retry (retries becomes 3)
        let (step3, res3) = coordExhaust.handleToolCalls([invalidCall])
        guard case .retry(let toolRes3) = step3 else {
            Issue.record("Expected retry on attempt 3, got \(step3)")
            return
        }
        #expect(coordExhaust.retries == 3)
        #expect(toolRes3.contains(StructuredOutputConstants.retrySuffix))
        #expect(res3[0].content.contains(StructuredOutputConstants.retrySuffix))

        // Attempt 4 -> EXHAUSTION (retries is 3, which is NOT < maxRetries)
        let (step4, res4) = coordExhaust.handleToolCalls([invalidCall])
        guard case .complete(let outcome4) = step4, case .failure(let err4) = outcome4 else {
            Issue.record("Expected complete failure on attempt 4, got \(step4)")
            return
        }
        #expect(coordExhaust.retries == 3)
        // Must NOT contain the retry suffix because retries are exhausted!
        #expect(!err4.contains(StructuredOutputConstants.retrySuffix))
        #expect(!res4[0].content.contains(StructuredOutputConstants.retrySuffix))
        #expect(err4.contains("output does not match the required schema: expected type integer"))

        // Coordinator B: Fails attempts 1 & 2, succeeds on attempt 3
        var coordRecover = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .messages,
            codeModeOnly: false
        )

        // Attempt 1: fail
        _ = coordRecover.handleToolCalls([invalidCall])
        #expect(coordRecover.retries == 1)

        // Attempt 2: fail
        _ = coordRecover.handleToolCalls([invalidCall])
        #expect(coordRecover.retries == 2)

        // Attempt 3: valid call
        let validCall = ToolCall(
            id: "call_good",
            name: StructuredOutputConstants.toolName,
            arguments: "{\"target\": 42}"
        )
        let (stepGood, resGood) = coordRecover.handleToolCalls([validCall])
        guard case .complete(let outcomeGood) = stepGood, case .success(let valGood) = outcomeGood else {
            Issue.record("Expected complete success on attempt 3 recovery, got \(stepGood)")
            return
        }
        #expect(valGood.objectValue?["target"]?.doubleValue == 42)
        #expect(resGood[0].content == StructuredOutputConstants.acceptedMessage)
    }

    // MARK: - 7. Multi-Tool Co-Emission Disambiguation

    @Test("Adversarial: Co-emission of multiple tools alongside StructuredOutput")
    func testMultiToolCoEmission() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["msg": .object(["type": .string("string")])])
        ])
        var coord = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .messages,
            codeModeOnly: false
        )

        let tool1 = ToolCall(id: "call_read_1", name: "read_file", arguments: "{\"path\": \"/foo\"}")
        let tool2 = ToolCall(id: "call_struct_1", name: StructuredOutputConstants.toolName, arguments: "{\"msg\": \"hi\"}")
        let tool3 = ToolCall(id: "call_bash_1", name: "bash", arguments: "{\"cmd\": \"pwd\"}")
        let tool4 = ToolCall(id: "call_struct_2", name: StructuredOutputConstants.toolName, arguments: "{\"msg\": \"hi again\"}")

        let (step, results) = coord.handleToolCalls([tool1, tool2, tool3, tool4])

        guard case .proceed(let remaining) = step else {
            Issue.record("Expected .proceed with remaining non-StructuredOutput tools, got \(step)")
            return
        }

        // Remaining tools should preserve order of non-StructuredOutput tools
        #expect(remaining.count == 2)
        #expect(remaining[0].id == "call_read_1")
        #expect(remaining[1].id == "call_bash_1")

        // Refusal results should be returned for BOTH StructuredOutput calls
        #expect(results.count == 2)
        #expect(results[0].callID == "call_struct_1")
        #expect(results[0].content == StructuredOutputConstants.coEmittedRefusal)
        #expect(results[1].callID == "call_struct_2")
        #expect(results[1].content == StructuredOutputConstants.coEmittedRefusal)
    }

    // MARK: - 8. Backend Native Schema vs Synthetic Tool vs Code Mode Only

    @Test("Adversarial: Backend matrix for native schema pass-through vs tool injection vs codeModeOnly")
    func testBackendMatrix() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["key": .object(["type": .string("string")])])
        ])

        let dummyTools = [ToolSpec(name: "test_tool", description: "test", parameters: .object([:]))]

        // Case 1: Native backends (.chatCompletions, .responses)
        let nativeBackends: [ApiBackend] = [.chatCompletions, .responses]
        for backend in nativeBackends {
            let coord = StructuredOutputTurnCoordinator(schema: schema, backend: backend, codeModeOnly: false)
            #expect(coord.structuredOutputNative)
            #expect(!coord.structuredOutputTool)
            let (tools, reminder, nativeSchema) = coord.prepareRequest(tools: dummyTools)
            #expect(tools.count == 1) // not injected
            #expect(tools[0].name == "test_tool")
            #expect(reminder == nil)
            #expect(nativeSchema == schema)
        }

        // Case 2: Non-native backends (.messages)
        let nonNativeBackends: [ApiBackend] = [.messages]
        for backend in nonNativeBackends {
            let coord = StructuredOutputTurnCoordinator(schema: schema, backend: backend, codeModeOnly: false)
            #expect(!coord.structuredOutputNative)
            #expect(coord.structuredOutputTool)
            let (tools, reminder, nativeSchema) = coord.prepareRequest(tools: dummyTools)
            #expect(tools.count == 2) // StructuredOutput injected
            #expect(tools.contains { $0.name == StructuredOutputConstants.toolName })
            #expect(reminder == StructuredOutputConstants.systemReminder)
            #expect(nativeSchema == nil)
        }

        // Case 3: Code Mode Only mode suppression (even on non-native backends)
        for backend in nonNativeBackends {
            let cmCoord = StructuredOutputTurnCoordinator(schema: schema, backend: backend, codeModeOnly: true)
            #expect(!cmCoord.structuredOutputNative)
            #expect(!cmCoord.structuredOutputTool)
            let (tools, reminder, nativeSchema) = cmCoord.prepareRequest(tools: dummyTools)
            #expect(tools.count == 1) // tool NOT injected
            #expect(tools[0].name == "test_tool")
            #expect(reminder == nil)
            #expect(nativeSchema == nil)
        }

        // Case 4: No schema provided
        let noSchemaCoord = StructuredOutputTurnCoordinator(schema: nil, backend: .messages, codeModeOnly: false)
        #expect(!noSchemaCoord.structuredOutputNative)
        #expect(!noSchemaCoord.structuredOutputTool)
        let (tools, reminder, nativeSchema) = noSchemaCoord.prepareRequest(tools: dummyTools)
        #expect(tools.count == 1)
        #expect(reminder == nil)
        #expect(nativeSchema == nil)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
