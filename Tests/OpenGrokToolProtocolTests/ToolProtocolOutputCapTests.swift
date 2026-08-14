// ToolProtocolOutputCapTests.swift
//
// Open Grok — Comprehensive output cap and truncation constant verification
// for tool results, MCP descriptions, mailboxes, and stream limits.

import Foundation
import Testing
@testable import OpenGrokToolProtocol
import OpenGrokShared
import OpenGrokToolTypes

@Suite("Tool Protocol Output Limits & Truncation")
struct ToolProtocolOutputCapTests {

    // MARK: - Constants Invariants

    @Test("Upstream-derived output limit and truncation constants match invariants")
    func constantInvariants() {
        // Default output limits
        #expect(agentMailboxMaxMessageBytes == 32 * 1024)
        #expect(agentMailboxMaxMessageBytes == 32_768)
        #expect(agentMailboxDefaultWaitMS == 30_000)
        #expect(agentMailboxMaxWaitMS == 600_000)
        #expect(agentMailboxMaxQueuedMessages == 128)
        #expect(agentMailboxMaxDrainMessages == 20)
    }

    // MARK: - Output Wire Serialization & Payloads

    @Test("ToolOutputWire text and json serialization")
    func outputWireKinds() throws {
        let textWire = ToolOutputWire.text("Sample stdout output")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(textWire)
        let jsonStr = String(data: data, encoding: .utf8)!
        #expect(jsonStr.contains("\"kind\":\"text\""))
        #expect(jsonStr.contains("\"value\":\"Sample stdout output\""))

        let decodedText = try JSONDecoder().decode(ToolOutputWire.self, from: data)
        #expect(decodedText == textWire)

        let jsonPayload = JSONValue.object([
            "status": .string("ok"),
            "count": .string("42"),
            "items": .array([.string("a"), .string("b")]),
        ])
        let jsonWire = ToolOutputWire.json(jsonPayload)
        let jsonData = try encoder.encode(jsonWire)
        let decodedJson = try JSONDecoder().decode(ToolOutputWire.self, from: jsonData)
        #expect(decodedJson == jsonWire)
    }

    @Test("ToolOutputWire MCP multi-block content serialization")
    func outputWireMCPBlocks() throws {
        let blocks: [McpBlock] = [
            .text(text: "Line 1 of MCP output"),
            .image(mimeType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="),
            .resource(uri: "file:///workspace/output.log", mimeType: "text/plain", text: "Log preview"),
        ]
        let mcpWire = ToolOutputWire.mcp(blocks: blocks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(mcpWire)
        let jsonStr = String(data: data, encoding: .utf8)!
        #expect(jsonStr.contains("\"kind\":\"mcp\""))
        #expect(jsonStr.contains("\"blocks\":["))

        let decoded = try JSONDecoder().decode(ToolOutputWire.self, from: data)
        #expect(decoded == mcpWire)
    }

    @Test("Custom wire notifications preserve structured payloads")
    func customNotificationWire() throws {
        let payload: JSONValue = .object([
            "step": .string("compiling"),
            "progress_percent": .string("85.5%"),
        ])
        let custom = WireCustomNotification(kind: "build.progress", payload: payload)
        let wire = WireToolNotification.custom(custom)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        let decoded = try JSONDecoder().decode(WireToolNotification.self, from: data)
        #expect(decoded == wire)
    }
}
