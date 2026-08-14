// ToolProtocolSchemaTests.swift
//
// Open Grok — Comprehensive schema validation and parameter decoding tests
// for the tool protocol layer.

import Foundation
import Testing
@testable import OpenGrokToolProtocol
import OpenGrokShared
import OpenGrokToolTypes

@Suite("Tool Protocol Schema & Parameter Validation")
struct ToolProtocolSchemaTests {

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - JSON-RPC Envelope & Error Code Validation

    @Test("JSON-RPC standard error codes match specification")
    func standardErrorCodes() {
        #expect(numericCode(for: "invalid_request") == -32600)
        #expect(numericCode(for: "method_not_found") == -32601)
        #expect(numericCode(for: "invalid_params") == -32602)
        #expect(numericCode(for: "internal_error") == -32603)
        #expect(numericCode(for: "parse_error") == -32700)
        #expect(stringCode(for: -32600) == "invalid_request")
        #expect(stringCode(for: -32601) == "method_not_found")
        #expect(stringCode(for: -32602) == "invalid_params")
        #expect(stringCode(for: -32603) == "internal_error")
        #expect(stringCode(for: -32700) == "parse_error")
    }

    @Test("Missing required toolCallId or toolId in ToolCallParams fails decoding")
    func missingRequiredParams() {
        let missingToolId = """
        {"tool_call_id":"call-1","arguments":{}}
        """
        #expect(throws: DecodingError.self) {
            try decodeJSON(ToolCallParams.self, missingToolId)
        }

        let missingToolCallId = """
        {"tool_id":"grep","arguments":{}}
        """
        #expect(throws: DecodingError.self) {
            try decodeJSON(ToolCallParams.self, missingToolCallId)
        }
    }

    @Test("Malformed tool IDs are rejected at protocol boundary")
    func malformedToolIds() {
        #expect(throws: IdError.self) { try ToolId("") }
        #expect(throws: IdError.self) { try ToolId("invalid:namespace:with:many:colons") }
        #expect(throws: IdError.self) { try ToolId("spaces not allowed") }
        #expect(throws: IdError.self) { try ToolId("dots.not.allowed") }
    }

    @Test("ToolCallId generation complies with UUIDv7 format")
    func toolCallIdFormat() {
        let id = ToolCallId.newV7()
        #expect(!id.rawValue.isEmpty)
        #expect(id.rawValue.count == 36)
        #expect(id.rawValue.split(separator: "-").count == 5)
    }

    // MARK: - Agent Mailbox Parameter Decoding & Limits

    @Test("SendAgentMessageInput decodes valid target and message")
    func validSendMessageInput() throws {
        let json = """
        {"target":"worker-1","message":"Please inspect test results"}
        """
        let input = try decodeJSON(SendAgentMessageInput.self, json)
        let (target, body) = try validateAgentMessage(input)
        #expect(target == "worker-1")
        #expect(body == "Please inspect test results")
    }

    @Test("SendAgentMessageInput rejects empty target or message")
    func emptySendMessageInput() throws {
        let emptyTarget = SendAgentMessageInput(target: "   ", message: "Hello")
        #expect(throws: AgentMailboxError.self) {
            try validateAgentMessage(emptyTarget)
        }

        let emptyMessage = SendAgentMessageInput(target: "worker-1", message: "  \n\t  ")
        #expect(throws: AgentMailboxError.self) {
            try validateAgentMessage(emptyMessage)
        }
    }

    @Test("SendAgentMessageInput enforces 32KB message size ceiling")
    func messageSizeCeiling() throws {
        #expect(agentMailboxMaxMessageBytes == 32 * 1024)

        // Exact boundary (32,768 bytes)
        let exactBody = String(repeating: "A", count: 32 * 1024)
        let exactInput = SendAgentMessageInput(target: "peer", message: exactBody)
        let validated = try validateAgentMessage(exactInput)
        #expect(validated.body.utf8.count == 32 * 1024)

        // Over budget (32,769 bytes)
        let oversizedBody = String(repeating: "A", count: 32 * 1024 + 1)
        let oversizedInput = SendAgentMessageInput(target: "peer", message: oversizedBody)
        #expect(throws: AgentMailboxError.self) {
            try validateAgentMessage(oversizedInput)
        }
    }

    @Test("SendAgentMessageInput rejects unknown fields (deny_unknown_fields)")
    func denyUnknownFieldsInSendMessage() {
        let jsonWithExtra = """
        {"target":"worker-1","message":"Hello","extra_param":"unexpected"}
        """
        #expect(throws: DecodingError.self) {
            try decodeJSON(SendAgentMessageInput.self, jsonWithExtra)
        }
    }

    @Test("WaitAgentInput decodes optional timeout and caps effective timeout")
    func waitAgentInputCaps() throws {
        // Default when omitted
        let omitted = try decodeJSON(WaitAgentInput.self, "{}")
        #expect(omitted.timeoutMS == nil)
        #expect(omitted.effectiveTimeoutMS() == agentMailboxDefaultWaitMS)
        #expect(omitted.effectiveTimeoutMS() == 30_000)

        // Explicit non-blocking poll
        let poll = try decodeJSON(WaitAgentInput.self, #"{"timeout_ms":0}"#)
        #expect(poll.timeoutMS == 0)
        #expect(poll.effectiveTimeoutMS() == 0)

        // Above max ceiling (e.g. 1,000,000 ms capped to 600,000 ms)
        let excess = try decodeJSON(WaitAgentInput.self, #"{"timeout_ms":1000000}"#)
        #expect(excess.effectiveTimeoutMS() == agentMailboxMaxWaitMS)
        #expect(excess.effectiveTimeoutMS() == 600_000)
    }

    @Test("WaitAgentInput rejects unknown fields")
    func denyUnknownFieldsInWaitAgent() {
        let jsonWithExtra = #"{"timeout_ms":1000,"invalid_key":"foo"}"#
        #expect(throws: DecodingError.self) {
            try decodeJSON(WaitAgentInput.self, jsonWithExtra)
        }
    }

    // MARK: - Turn Hook & Session Event Schemas

    @Test("BeforeTurnPayload decodes with defaults for yoloMode and sessionRelationship")
    func beforeTurnDefaults() throws {
        let json = #"{"turn_number":2,"model_id":"grok-3"}"#
        let payload = try decodeJSON(BeforeTurnPayload.self, json)
        #expect(payload.turnNumber == 2)
        #expect(payload.modelId == "grok-3")
        #expect(payload.yoloMode == false)
        #expect(payload.sessionRelationship == defaultSessionRelationship)
    }

    @Test("HookReply parses control actions and prompt injections")
    func hookReplyParsing() throws {
        let json = """
        {
            "injections": [{"role": "system", "content": "Remember to write tests"}],
            "control": "force_continue"
        }
        """
        let reply = try decodeJSON(HookReply.self, json)
        #expect(reply.injections.count == 1)
        #expect(reply.injections.first?.role == .system)
        #expect(reply.control == .forceContinue)
        #expect(reply.afterTurnAck == nil)
    }

    @Test("SessionEvent roundtrips with turn and tool call tracking")
    func sessionEventRoundtrips() throws {
        let startEvent = SessionEvent.turnStarted(turnNumber: 3, modelId: "grok-4", yoloMode: true)
        let encoded = try encodeJSON(startEvent)
        #expect(encoded.contains("\"event_type\":\"turn_started\""))
        #expect(encoded.contains("\"turn_number\":3"))
        let back = try decodeJSON(SessionEvent.self, encoded)
        #expect(back == startEvent)
    }
}
