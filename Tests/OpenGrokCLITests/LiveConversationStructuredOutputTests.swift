// LiveConversationStructuredOutputTests.swift
//
// Tests for StructuredOutput synthetic tool loop and JSON schema validation.

import Foundation
import Testing
@testable import OpenGrokCLI
@testable import OpenGrokSamplingTypes
@testable import OpenGrokShared
@testable import OpenGrokToolTypes

@Suite("LiveConversationStructuredOutputTests")
struct LiveConversationStructuredOutputTests {

    @Test("JSONSchemaValidator primitive types and required properties")
    func testSchemaValidationPrimitivesAndRequired() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("name"), .string("age")]),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "age": .object(["type": .string("integer"), "minimum": .number(.int64(0))]),
            ]),
            "additionalProperties": .bool(false)
        ])

        let validator = try JSONSchemaValidator(schema: schema)

        // Valid JSON
        let valid = validator.validate(raw: """
        {"name": "Alice", "age": 30}
        """)
        guard case .success(let value) = valid else {
            Issue.record("Expected valid JSON to pass validation, got \(valid)")
            return
        }
        #expect(value.objectValue?["name"]?.stringValue == "Alice")
        #expect(value.objectValue?["age"]?.doubleValue == 30)

        // Missing required property
        let missing = validator.validate(raw: """
        {"name": "Alice"}
        """)
        guard case .failure(let err1) = missing else {
            Issue.record("Expected missing property to fail")
            return
        }
        #expect(err1.contains("missing required property 'age'"))

        // Additional property when additionalProperties is false
        let extra = validator.validate(raw: """
        {"name": "Alice", "age": 30, "extra": true}
        """)
        guard case .failure(let err2) = extra else {
            Issue.record("Expected extra property to fail")
            return
        }
        #expect(err2.contains("unexpected additional property 'extra'"))

        // Invalid type (age string instead of integer)
        let badType = validator.validate(raw: """
        {"name": "Alice", "age": "thirty"}
        """)
        guard case .failure(let err3) = badType else {
            Issue.record("Expected wrong type to fail")
            return
        }
        #expect(err3.contains("expected type integer"))
    }

    @Test("JSONSchemaValidator enums and number ranges")
    func testSchemaValidationEnumsAndRanges() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "status": .object([
                    "enum": .array([.string("active"), .string("inactive")])
                ]),
                "score": .object([
                    "type": .string("number"),
                    "minimum": .number(.double(1.0)),
                    "maximum": .number(.double(5.0))
                ])
            ])
        ])

        let validator = try JSONSchemaValidator(schema: schema)

        // Valid
        let valid = validator.validate(raw: """
        {"status": "active", "score": 4.5}
        """)
        #expect(valid.isSuccess)

        // Invalid enum
        let badEnum = validator.validate(raw: """
        {"status": "pending", "score": 4.5}
        """)
        #expect(!badEnum.isSuccess)

        // Out of range number
        let outOfRange = validator.validate(raw: """
        {"status": "active", "score": 6.0}
        """)
        #expect(!outOfRange.isSuccess)
    }

    @Test("StructuredOutputTurnCoordinator request preparation for native vs tool mode")
    func testCoordinatorRequestPreparation() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["result": .object(["type": .string("string")])])
        ])

        // Chat Completions (Native Schema support)
        let nativeCoordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .chatCompletions,
            codeModeOnly: false
        )
        #expect(nativeCoordinator.structuredOutputNative)
        #expect(!nativeCoordinator.structuredOutputTool)
        let (nativeTools, nativeReminder, nativeJsonSchema) = nativeCoordinator.prepareRequest(tools: [])
        #expect(nativeTools.isEmpty)
        #expect(nativeReminder == nil)
        #expect(nativeJsonSchema == schema)

        // Messages (Non-native schema backend)
        let toolCoordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .messages,
            codeModeOnly: false
        )
        #expect(!toolCoordinator.structuredOutputNative)
        #expect(toolCoordinator.structuredOutputTool)
        let (toolTools, toolReminder, toolJsonSchema) = toolCoordinator.prepareRequest(tools: [])
        #expect(toolTools.count == 1)
        #expect(toolTools[0].name == StructuredOutputConstants.toolName)
        #expect(toolReminder == StructuredOutputConstants.systemReminder)
        #expect(toolJsonSchema == nil)

        // Messages under Code Mode Only (Tool injection suppressed)
        let codeModeOnlyCoordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .messages,
            codeModeOnly: true
        )
        #expect(!codeModeOnlyCoordinator.structuredOutputNative)
        #expect(!codeModeOnlyCoordinator.structuredOutputTool)
        let (cmTools, cmReminder, cmJsonSchema) = codeModeOnlyCoordinator.prepareRequest(tools: [])
        #expect(cmTools.isEmpty)
        #expect(cmReminder == nil)
        #expect(cmJsonSchema == nil)
    }

    @Test("StructuredOutputTurnCoordinator co-emitted tool stripping")
    func testCoEmittedToolStripping() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["answer": .object(["type": .string("string")])])
        ])
        var coordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .responses,
            codeModeOnly: false
        )

        let bashCall = ToolCall(id: "call_bash_1", name: "bash", arguments: "{\"command\": \"ls\"}")
        let structuredCall = ToolCall(
            id: "call_struct_1",
            name: StructuredOutputConstants.toolName,
            arguments: "{\"answer\": \"done\"}"
        )

        let (step, results) = coordinator.handleToolCalls([bashCall, structuredCall])

        // Step should proceed with remaining tools (bash)
        guard case .proceed(let remaining) = step else {
            Issue.record("Expected .proceed with remaining tools, got \(step)")
            return
        }
        #expect(remaining.count == 1)
        #expect(remaining[0].name == "bash")

        // StructuredOutput should have received refusal message
        #expect(results.count == 1)
        #expect(results[0].callID == "call_struct_1")
        #expect(results[0].content == StructuredOutputConstants.coEmittedRefusal)
    }

    @Test("StructuredOutputTurnCoordinator in-turn retries and exhaustion")
    func testRetryLoopAndExhaustion() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("count")]),
            "properties": .object(["count": .object(["type": .string("integer")])])
        ])
        var coordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .responses,
            codeModeOnly: false
        )

        let badCall = ToolCall(
            id: "call_1",
            name: StructuredOutputConstants.toolName,
            arguments: "{\"count\": \"invalid_integer\"}"
        )

        // Attempt 1 -> retry
        let (step1, res1) = coordinator.handleToolCalls([badCall])
        guard case .retry(let msg1) = step1 else {
            Issue.record("Expected retry on attempt 1, got \(step1)")
            return
        }
        #expect(msg1.contains(StructuredOutputConstants.retrySuffix))
        #expect(res1[0].content.contains(StructuredOutputConstants.retrySuffix))
        #expect(coordinator.retries == 1)

        // Attempt 2 -> retry
        let (step2, _) = coordinator.handleToolCalls([badCall])
        guard case .retry = step2 else {
            Issue.record("Expected retry on attempt 2, got \(step2)")
            return
        }
        #expect(coordinator.retries == 2)

        // Attempt 3 -> retry
        let (step3, _) = coordinator.handleToolCalls([badCall])
        guard case .retry = step3 else {
            Issue.record("Expected retry on attempt 3, got \(step3)")
            return
        }
        #expect(coordinator.retries == 3)

        // Attempt 4 -> exhaustion
        let (step4, res4) = coordinator.handleToolCalls([badCall])
        guard case .complete(let outcome) = step4, case .failure(let err4) = outcome else {
            Issue.record("Expected complete failure on 4th attempt, got \(step4)")
            return
        }
        #expect(!err4.contains(StructuredOutputConstants.retrySuffix))
        #expect(!res4[0].content.contains(StructuredOutputConstants.retrySuffix))
    }

    @Test("StructuredOutputTurnCoordinator acceptance on valid call")
    func testAcceptanceOnValidOutput() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("greeting")]),
            "properties": .object(["greeting": .object(["type": .string("string")])])
        ])
        var coordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .responses,
            codeModeOnly: false
        )

        let validCall = ToolCall(
            id: "call_valid",
            name: StructuredOutputConstants.toolName,
            arguments: "{\"greeting\": \"hello world\"}"
        )

        let (step, res) = coordinator.handleToolCalls([validCall])
        guard case .complete(let outcome) = step, case .success(let val) = outcome else {
            Issue.record("Expected success on valid call, got \(step)")
            return
        }
        #expect(val.objectValue?["greeting"]?.stringValue == "hello world")
        #expect(res[0].content == StructuredOutputConstants.acceptedMessage)
    }

    @Test("StructuredOutput assistant text validation")
    func testAssistantTextValidation() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("ok")]),
            "properties": .object(["ok": .object(["type": .string("boolean")])])
        ])
        let coordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .chatCompletions,
            codeModeOnly: false
        )

        let validRes = coordinator.validateAssistantText("{\"ok\": true}")
        #expect(validRes?.isSuccess == true)

        let invalidRes = coordinator.validateAssistantText("{\"ok\": \"not a bool\"}")
        #expect(invalidRes?.isSuccess == false)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
