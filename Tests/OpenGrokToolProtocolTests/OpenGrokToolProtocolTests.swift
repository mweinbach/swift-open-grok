// OpenGrokToolProtocolTests.swift
//
// Open Grok — Rust-derived golden and concurrency tests for xai-tool-protocol.
//
// Translates tests from:
//   * crates/common/xai-tool-protocol/tests/*
//   * crates/common/xai-tool-protocol/src/error_codes.rs (inline)
//   * crates/common/xai-tool-protocol/src/session_event.rs (inline)
//   * crates/common/xai-tool-protocol/src/turn_hook.rs (inline)

import Testing
import Foundation
@testable import OpenGrokToolProtocol
import OpenGrokShared
import OpenGrokToolTypes

// MARK: - Helpers

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8)!
}

private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try decodeJSON(T.self, try encodeJSON(value))
}

// MARK: - Identifiers

@Suite("ToolId")
struct ToolIdTests {
    @Test("accepts bare and namespaced forms")
    func wellFormed() throws {
        #expect(try ToolId("grep").rawValue == "grep")
        #expect(try ToolId("GrokBuild:grep").rawValue == "GrokBuild:grep")
        #expect(try ToolId("a-b_C9").rawValue == "a-b_C9")
    }

    @Test("rejects empty, multi-colon, and bad charset")
    func rejectsInvalid() {
        #expect(throws: IdError.self) { try ToolId("") }
        #expect(throws: IdError.self) { try ToolId("a:b:c") }
        #expect(throws: IdError.self) { try ToolId("has space") }
        #expect(throws: IdError.self) { try ToolId("dot.name") }
    }

    @Test("serde roundtrip as bare string")
    func serde() throws {
        let id = try ToolId("ns:name")
        #expect(try encodeJSON(id) == "\"ns:name\"")
        #expect(try decodeJSON(ToolId.self, "\"ns:name\"") == id)
    }
}

@Suite("ServerId")
struct ServerIdTests {
    @Test("rejects reserved auto: prefix from clients")
    func reservedPrefix() {
        #expect(throws: IdError.self) { try ServerId("auto:tool:x") }
    }

    @Test("synthesizeForTool bypasses reserved-prefix check")
    func synthesize() throws {
        let conn = try ConnectionId("conn-1")
        let tool = try ToolId("grep")
        let sid = ServerId.synthesizeForTool(connectionId: conn, toolId: tool)
        #expect(sid.rawValue == "auto:tool:grep")
    }
}

@Suite("FrameSeq")
struct FrameSeqTests {
    @Test("default is zero and Codable")
    func defaultZero() throws {
        #expect(FrameSeq.defaultValue.rawValue == 0)
        let s = FrameSeq(42)
        #expect(try encodeJSON(s) == "42")
        #expect(try decodeJSON(FrameSeq.self, "0").rawValue == 0)
    }
}

// MARK: - Envelope

@Suite("JsonRpc envelope")
struct EnvelopeTests {
    @Test("request roundtrip with session_id")
    func requestRoundtrip() throws {
        let req = JsonRpcRequest(
            id: .string("1"),
            sessionId: try SessionId("sess-1"),
            method: Method.toolCall.rawValue,
            params: ToolCallParams(
                toolCallId: try ToolCallId("call-1"),
                toolId: try ToolId("grep"),
                arguments: .object(["pattern": .string("foo")])
            )
        )
        let back = try roundTrip(req)
        #expect(back.method == "tool.call")
        #expect(back.sessionId?.rawValue == "sess-1")
        #expect(back.params.toolId.rawValue == "grep")
    }

    @Test("response accepts result XOR error")
    func responseXor() throws {
        let ok = JsonRpcResponse.ok(id: .number(1), result: "hi")
        let okJSON = try encodeJSON(ok)
        #expect(okJSON.contains("\"result\""))
        #expect(!okJSON.contains("\"error\""))

        let err = JsonRpcResponse<String>.err(
            id: .string("x"),
            error: JsonRpcError(code: -32601, message: "nope")
        )
        let back = try roundTrip(err)
        if case .error(let e) = back.outcome {
            #expect(e.code == -32601)
        } else {
            Issue.record("expected error outcome")
        }
    }

    @Test("rejects response with both result and error")
    func rejectsBoth() {
        let json = #"{"jsonrpc":"2.0","id":"1","result":"x","error":{"code":1,"message":"e"}}"#
        #expect(throws: DecodingError.self) {
            try decodeJSON(JsonRpcResponse<String>.self, json)
        }
    }

    @Test("notification carries optional seq")
    func notification() throws {
        let n = JsonRpcNotification(
            sessionId: try SessionId("s"),
            seq: FrameSeq(3),
            method: Method.toolCallProgress.rawValue,
            params: ToolCallProgressFrame(
                toolCallId: try ToolCallId("c"),
                kind: "chunk",
                body: .object([:])
            )
        )
        let back = try roundTrip(n)
        #expect(back.seq?.rawValue == 3)
    }
}

// MARK: - Error codes / wire

@Suite("Error codes")
struct ErrorCodeTests {
    @Test("numeric_for and string_for are inverses for table")
    func tableRoundtrip() {
        for (n, s) in errorCodes {
            #expect(numericCode(for: s) == n)
            #expect(stringCode(for: n) == s)
        }
        #expect(numericCode(for: "nope") == nil)
        #expect(stringCode(for: -1) == nil)
    }

    @Test("workspace_unavailable builder emits custom with details")
    func workspaceUnavailable() throws {
        let wire = workspaceUnavailableWire(reason: .idleTimeout, phase: .routeMissing)
        let v = try JSONValue.encode(wire)
        guard case .object(let obj) = v else {
            Issue.record("expected object"); return
        }
        #expect(obj["code"] == .string("custom"))
        #expect(obj["subcode"] == .string(workspaceUnavailableSubcode))
        if case .object(let details) = obj["details"] {
            #expect(details["code"] == .string(workspaceUnavailableSubcode))
            #expect(details["reason"] == .string("idle_timeout"))
            #expect(details["phase"] == .string("route_missing"))
            #expect(details["retryable"] == .bool(true))
        } else {
            Issue.record("missing details")
        }
    }

    @Test("unknown reason/phase deserialize to unknown")
    func unknownEnums() throws {
        let json = """
        {"code":"workspace_unavailable","reason":"reason_from_a_newer_hub","phase":"phase_from_a_newer_hub","retryable":true}
        """
        let details = try decodeJSON(WorkspaceUnavailableDetails.self, json)
        #expect(details.reason == .unknown)
        #expect(details.phase == .unknown)
    }

    @Test("custom variant preserves unknown future details")
    func customForwardCompat() throws {
        let future = """
        {"code":"custom","subcode":"some_future_subcode","message":"from a newer peer","details":{"code":"some_future_subcode","extra_new_field":{"nested":[1,2,3]}}}
        """
        let wire = try decodeJSON(ToolErrorWire.self, future)
        if case .custom(let subcode, _, let details) = wire {
            #expect(subcode == "some_future_subcode")
            if case .object(let d) = details {
                #expect(d["extra_new_field"] != nil)
            } else {
                Issue.record("details missing")
            }
        } else {
            Issue.record("expected custom")
        }
        let reser = try encodeJSON(wire)
        #expect(reser.contains("extra_new_field"))
    }
}

// MARK: - Output / notification wire

@Suite("ToolOutputWire")
struct OutputWireTests {
    @Test("text/json/mcp roundtrip")
    func kinds() throws {
        let text = ToolOutputWire.text("hello")
        #expect(try encodeJSON(text).contains("\"kind\":\"text\""))
        #expect(try roundTrip(text) == text)

        // Use a string-bearing object so JSON number width (int64 vs double)
        // cannot cause a false equality mismatch after re-decode.
        let json = ToolOutputWire.json(.object(["a": .string("1")]))
        #expect(try roundTrip(json) == json)
        // Also confirm a numeric payload still round-trips structurally.
        let numeric = ToolOutputWire.json(.object(["n": .number(.int64(1))]))
        let numericBack = try roundTrip(numeric)
        if case .json(let v) = numericBack, case .object(let o) = v {
            #expect(o["n"]?.doubleValue == 1)
        } else {
            Issue.record("expected json object after round-trip")
        }

        let mcp = ToolOutputWire.mcp(blocks: [
            .text(text: "t"),
            .image(mimeType: "image/png", data: "abc"),
            .resource(uri: "file:///x", mimeType: nil, text: "preview"),
        ])
        #expect(try roundTrip(mcp) == mcp)
    }
}

@Suite("WireToolNotification")
struct NotificationWireTests {
    @Test("known and custom shapes")
    func shapes() throws {
        let known = WireToolNotification.known(.object(["type": .string("BashOutputChunk")]))
        let back = try roundTrip(known)
        #expect(back == known)

        let custom = WireToolNotification.custom(
            WireCustomNotification(kind: "my.progress", payload: .object([:]))
        )
        #expect(try roundTrip(custom) == custom)
    }

    @Test("checkCustomKind rejects known PascalCase")
    func collision() {
        #expect(checkCustomKind("BashOutputChunk").isFailure)
        #expect(checkCustomKind("my.custom").isSuccess)
    }
}

// MARK: - Registration / methods

@Suite("Registration")
struct RegistrationTests {
    @Test("deriveToolId from description")
    func derive() throws {
        var desc = ToolDescription(name: "grep", description: "search")
        desc = desc.withNamespace("GrokBuild")
        let withSchema = ToolDescriptionWithSchema(description: desc)
        #expect(try withSchema.deriveToolId().rawValue == "GrokBuild:grep")
    }

    @Test("registration outcome wire")
    func outcomes() throws {
        let o = RegistrationOutcome.registered(toolId: try ToolId("t"), generation: 2)
        let json = try encodeJSON(o)
        #expect(json.contains("\"outcome\":\"registered\""))
        #expect(try roundTrip(o) == o)
    }
}

@Suite("Method catalog")
struct MethodTests {
    @Test("every case has a wire string and inverse")
    func catalog() {
        for m in Method.allCases {
            #expect(Method.fromWireStr(m.wireString) == m)
        }
        #expect(Method.fromWireStr("nope") == nil)
        #expect(unknownMethodMsgPrefix == "unknown method `")
    }
}

// MARK: - Session events / turn hooks

@Suite("SessionEvent")
struct SessionEventTests {
    @Test("turn_started roundtrip and yolo default")
    func turnStarted() throws {
        let event = SessionEvent.turnStarted(turnNumber: 1, modelId: "grok-3", yoloMode: true)
        let v = try encodeJSON(event)
        #expect(v.contains("\"event_type\":\"turn_started\""))
        #expect(try roundTrip(event) == event)

        let sparse = #"{"event_type":"turn_started","turn_number":5,"model_id":"grok-3"}"#
        let parsed = try decodeJSON(SessionEvent.self, sparse)
        #expect(parsed == .turnStarted(turnNumber: 5, modelId: "grok-3", yoloMode: false))
    }

    @Test("unknown event_type preserves full payload losslessly")
    func unknownEvent() throws {
        let v = #"{"event_type":"some_future_event","extra":123}"#
        let parsed = try decodeJSON(SessionEvent.self, v)
        guard case .unknown(let eventType, let payload) = parsed else {
            Issue.record("expected unknown"); return
        }
        #expect(eventType == "some_future_event")
        if case .object(let obj) = payload {
            #expect(obj["event_type"] == .string("some_future_event"))
            #expect(obj["extra"] != nil)
        } else {
            Issue.record("expected object payload")
        }
        // Re-encode preserves original discriminator and extras.
        let back = try encodeJSON(parsed)
        #expect(back.contains("\"event_type\":\"some_future_event\""))
        #expect(back.contains("\"extra\":"))
        let round = try decodeJSON(SessionEvent.self, back)
        guard case .unknown(let et2, _) = round else {
            Issue.record("expected unknown after roundtrip"); return
        }
        #expect(et2 == "some_future_event")
    }

    @Test("tool_call_outcome and session_phase preserve unknown raw values")
    func unknownInner() throws {
        #expect(try decodeJSON(ToolCallOutcome.self, "\"timeout\"") == .unknown("timeout"))
        #expect(try decodeJSON(SessionPhase.self, "\"cleanup\"") == .unknown("cleanup"))
        #expect(try encodeJSON(ToolCallOutcome.unknown("timeout")) == "\"timeout\"")
        #expect(try encodeJSON(SessionPhase.unknown("cleanup")) == "\"cleanup\"")
    }
}

@Suite("TurnHook")
struct TurnHookTests {
    @Test("before_turn roundtrip and defaults")
    func beforeTurn() throws {
        let payload = BeforeTurnPayload(
            turnNumber: 42,
            modelId: "grok-3",
            yoloMode: true,
            conversationMessageCount: 9,
            sessionRelationship: "subagent",
            schemaVersion: "1.0"
        )
        #expect(try roundTrip(payload) == payload)

        let sparse = #"{"turn_number":1,"model_id":"grok-3"}"#
        let p = try decodeJSON(BeforeTurnPayload.self, sparse)
        #expect(p.yoloMode == false)
        #expect(p.sessionRelationship == defaultSessionRelationship)
    }

    @Test("hook reply defaults to no-op")
    func hookReplyDefault() throws {
        let reply = try decodeJSON(HookReply.self, "{}")
        #expect(reply.injections.isEmpty)
        #expect(reply.control == .auto)
        #expect(reply.afterTurnAck == nil)
    }
}

// MARK: - Capabilities / handshake / frames

@Suite("Capabilities and handshake")
struct CapabilitiesHandshakeTests {
    @Test("ToolCapabilities defaults and wire")
    func caps() throws {
        let caps = ToolCapabilities(supportsCancel: true, isReadOnly: true)
        let back = try roundTrip(caps)
        #expect(back.supportsCancel)
        #expect(back.isReadOnly)
        #expect(back.hooks.isEmpty)
    }

    @Test("ToolDefinitionMode adjacent tag")
    func definitionMode() throws {
        let full = ToolDefinitionMode.full
        #expect(try encodeJSON(full) == #"{"mode":"full"}"#)
        let concise = ToolDefinitionMode.concise(
            metaSearch: try ToolId("search"),
            metaCall: try ToolId("call")
        )
        #expect(try roundTrip(concise) == concise)
    }

    @Test("HelloMsg / HelloAckMsg roundtrip")
    func hello() throws {
        let hello = HelloMsg(kind: .toolServer, serverId: try ServerId("srv-1"))
        #expect(try roundTrip(hello) == hello)
        let ack = HelloAckMsg(
            connectionId: try ConnectionId("c1"),
            userId: try UserId("u1"),
            computerHubVersion: "1.0",
            supportedProtocolVersions: [toolProtocolVersion]
        )
        #expect(try roundTrip(ack) == ack)
    }

    @Test("PingFrame / PongFrame method tag")
    func pingPong() throws {
        let ping = PingFrame(tsMs: 100)
        let json = try encodeJSON(ping)
        #expect(json.contains("\"method\":\"ping\""))
        #expect(try decodeJSON(PingFrame.self, #"{"ts_ms":100}"#).tsMs == 100)
        #expect(throws: DecodingError.self) {
            try decodeJSON(PingFrame.self, #"{"method":"pong","ts_ms":1}"#)
        }
    }
}

@Suite("Hook frames")
struct HookFrameTests {
    @Test("cancel builder and custom request")
    func builders() throws {
        let cancel = HookFrame.cancel(
            sessionId: try SessionId("s"),
            toolId: try ToolId("bash"),
            callId: try ToolCallId("c1")
        )
        #expect(cancel.event == .cancel)
        #expect(cancel.callId?.rawValue == "c1")

        let custom = HookFrame.customRequest(
            sessionId: try SessionId("s"),
            hookId: "h1",
            kind: "turn_hook",
            payload: .object([:])
        )
        #expect(custom.hookId == "h1")
        if case .custom(let kind, _) = custom.event {
            #expect(kind == "turn_hook")
        } else {
            Issue.record("expected custom")
        }
    }
}

// MARK: - Concurrency

@Suite("Identifier concurrency")
struct IdConcurrencyTests {
    @Test("concurrent ToolCallId generation is unique")
    func concurrentIds() async {
        let count = 200
        let ids = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<count {
                group.addTask { ToolCallId.newV7().rawValue }
            }
            var out: [String] = []
            for await id in group { out.append(id) }
            return out
        }
        #expect(Set(ids).count == count)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
    var isFailure: Bool { !isSuccess }
}
