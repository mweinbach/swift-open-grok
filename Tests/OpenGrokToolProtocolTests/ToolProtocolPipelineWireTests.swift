// ToolProtocolPipelineWireTests.swift
//
// Open Grok — Tests for tool protocol wire frames, hook control messages,
// error code mapping, and pipeline lifecycle assertions.

import Foundation
import Testing
@testable import OpenGrokToolProtocol
import OpenGrokShared
import OpenGrokToolTypes

@Suite("Tool Protocol Pipeline & Hook Frames")
struct ToolProtocolPipelineWireTests {

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Hook Frame Builders & Wire Serialization

    @Test("Cancel hook frame encodes with method and call ID")
    func cancelHookFrame() throws {
        let sessionId = try SessionId("sess-xyz")
        let toolId = try ToolId("bash")
        let callId = try ToolCallId("call-123")

        let cancel = HookFrame.cancel(sessionId: sessionId, toolId: toolId, callId: callId)
        #expect(cancel.sessionId == sessionId)
        #expect(cancel.toolId == toolId)
        #expect(cancel.callId == callId)
        #expect(cancel.event == .cancel)

        let json = try encodeJSON(cancel)
        #expect(json.contains("\"call_id\":\"call-123\""))
        #expect(json.contains("\"tool_id\":\"bash\""))
        #expect(json.contains("\"session_id\":\"sess-xyz\""))
        #expect(json.contains("\"event\":{\"type\":\"Cancel\"}"))
    }

    @Test("Custom request hook frame preserves hook ID and payload")
    func customRequestHookFrame() throws {
        let sessionId = try SessionId("sess-1")
        let payload = JSONValue.object([
            "action": .string("pre_tool_validation"),
            "allow_bypass": .bool(false),
        ])
        let frame = HookFrame.customRequest(
            sessionId: sessionId,
            hookId: "security_hook_v1",
            kind: "pre_tool_use",
            payload: payload
        )
        #expect(frame.hookId == "security_hook_v1")
        if case .custom(let kind, let body) = frame.event {
            #expect(kind == "pre_tool_use")
            #expect(body == payload)
        } else {
            Issue.record("expected custom event")
        }
    }

    // MARK: - Handshake & Capability Frames

    @Test("HelloMsg and HelloAckMsg protocol version negotiation")
    func handshakeNegotiation() throws {
        let serverId = try ServerId("tool-server-alpha")
        let hello = HelloMsg(
            kind: .toolServer,
            serverId: serverId,
            description: "Primary tool server"
        )
        let helloJson = try encodeJSON(hello)
        let backHello = try decodeJSON(HelloMsg.self, helloJson)
        #expect(backHello.serverId == serverId)
        #expect(backHello.description == "Primary tool server")

        let connId = try ConnectionId("conn-42")
        let userId = try UserId("user-open-grok")
        let ack = HelloAckMsg(
            connectionId: connId,
            userId: userId,
            computerHubVersion: "1.0.0",
            supportedProtocolVersions: [toolProtocolVersion],
            capabilities: ["cancel", "progress"]
        )
        let ackJson = try encodeJSON(ack)
        let backAck = try decodeJSON(HelloAckMsg.self, ackJson)
        #expect(backAck.connectionId == connId)
        #expect(backAck.supportedProtocolVersions.contains(toolProtocolVersion))
        #expect(backAck.capabilities.contains("cancel"))
    }

    @Test("PingFrame and PongFrame validate timestamp sequence")
    func pingPongValidation() throws {
        let ping = PingFrame(tsMs: 1723650000000)
        let pingJson = try encodeJSON(ping)
        #expect(pingJson.contains("\"method\":\"ping\""))
        #expect(pingJson.contains("1723650000000"))

        let pong = PongFrame(tsMs: 1723650000000)
        let pongJson = try encodeJSON(pong)
        #expect(pongJson.contains("\"method\":\"pong\""))
        #expect(pongJson.contains("1723650000000"))
    }

    // MARK: - Tool Description and Schema Derivation

    @Test("ToolDescription deriveToolId combines namespace and name")
    func toolIdDerivation() throws {
        var desc = ToolDescription(name: "search_replace", description: "Edit files")
        desc = desc.withNamespace("GrokBuild")
        let schemaDesc = ToolDescriptionWithSchema(description: desc)
        let derivedId = try schemaDesc.deriveToolId()
        #expect(derivedId.rawValue == "GrokBuild:search_replace")
    }

    @Test("ToolErrorWire distinguishes standard and custom errors")
    func toolErrorWireVarieties() throws {
        let notFound = ToolErrorWire.toolNotFound(toolId: try ToolId("unknown_tool"))
        let notFoundJson = try encodeJSON(notFound)
        #expect(notFoundJson.contains("\"code\":\"tool_not_found\""))
        #expect(notFoundJson.contains("\"tool_id\":\"unknown_tool\""))

        let invalidArgs = ToolErrorWire.invalidArguments(message: "Missing required parameter: query", details: nil)
        let invalidArgsJson = try encodeJSON(invalidArgs)
        #expect(invalidArgsJson.contains("\"code\":\"invalid_params\""))
        #expect(invalidArgsJson.contains("Missing required parameter: query"))

        let permDenied = ToolErrorWire.permissionDenied(reason: "Plan mode active: cannot edit src/main.rs")
        let permDeniedJson = try encodeJSON(permDenied)
        #expect(permDeniedJson.contains("\"code\":\"forbidden\""))
        #expect(permDeniedJson.contains("Plan mode active: cannot edit src/main.rs"))

        let timeout = ToolErrorWire.timeout(toolId: try ToolId("bash"), elapsedMs: 120_000)
        let timeoutJson = try encodeJSON(timeout)
        #expect(timeoutJson.contains("\"code\":\"timeout\""))
        #expect(timeoutJson.contains("120000"))
    }
}
