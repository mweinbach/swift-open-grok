// PinnedCallbackProtoParityTests.swift
//
// Binary and JSON fixtures derived from Rust 00e176c8:
// xai-grok-tools-api/proto/grok-tools.proto:178-195,234-247,324-415 and
// xai-grok-tools-api/tests/wire_shape.rs:117-149.

import Foundation
import Testing
@testable import OpenGrokToolsAPI

@Suite("Pinned callback protobuf parity")
struct PinnedCallbackProtoParityTests {
    @Test("finalize callback fields encode in pinned protobuf tag order")
    func finalizeCallbackFieldWireShape() throws {
        let request = FinalizeToolServerConfigRequest(
            systemRemindersEnabled: true,
            initialToolStateJson: "",
            behaviorPreset: "p",
            clientCallbackAddr: "h",
            sessionId: "s",
            clientCallbackSecret: "k"
        )
        let fixture: [UInt8] = [
            0x18, 0x01,
            0x22, 0x00,
            0x2a, 0x01, 0x70,
            0x32, 0x01, 0x68,
            0x3a, 0x01, 0x73,
            0x42, 0x01, 0x6b,
        ]

        #expect(Array(request.protobufData()) == fixture)
        #expect(try FinalizeToolServerConfigRequest(protobufBytes: Data(fixture)) == request)
        #expect(FinalizeToolServerConfigRequest.FieldNumber.clientCallbackAddr == 6)
        #expect(FinalizeToolServerConfigRequest.FieldNumber.sessionId == 7)
        #expect(FinalizeToolServerConfigRequest.FieldNumber.clientCallbackSecret == 8)
    }

    @Test("optional callback strings distinguish absent from present-empty")
    func finalizeCallbackPresence() throws {
        let absent = FinalizeToolServerConfigRequest()
        #expect(absent.protobufData().isEmpty)

        let present = FinalizeToolServerConfigRequest(
            clientCallbackAddr: "",
            sessionId: "",
            clientCallbackSecret: ""
        )
        let fixture: [UInt8] = [0x32, 0x00, 0x3a, 0x00, 0x42, 0x00]
        #expect(Array(present.protobufData()) == fixture)

        let decoded = try FinalizeToolServerConfigRequest(protobufBytes: Data(fixture))
        #expect(decoded.clientCallbackAddr == "")
        #expect(decoded.sessionId == "")
        #expect(decoded.clientCallbackSecret == "")
    }

    @Test("legacy finalize payloads and future reserved fields remain decodable")
    func legacyFinalizeCompatibility() throws {
        let legacy: [UInt8] = [0x18, 0x01, 0x2a, 0x01, 0x70]
        let decoded = try FinalizeToolServerConfigRequest(protobufBytes: Data(legacy))
        #expect(decoded.systemRemindersEnabled)
        #expect(decoded.behaviorPreset == "p")
        #expect(decoded.clientCallbackAddr == nil)
        #expect(decoded.sessionId == nil)
        #expect(decoded.clientCallbackSecret == nil)
        #expect(Array(decoded.protobufData()) == legacy)

        let future: [UInt8] = legacy + [0x4a, 0x01, 0x78, 0xa0, 0x01, 0x01]
        #expect(try FinalizeToolServerConfigRequest(protobufBytes: Data(future)) == decoded)
    }

    @Test("callback finalize JSON uses Rust serde snake_case and sparse defaults")
    func finalizeCallbackJSONWireShape() throws {
        let request = FinalizeToolServerConfigRequest(
            clientCallbackAddr: "http://127.0.0.1:50051",
            sessionId: "session-123",
            clientCallbackSecret: "secret-123"
        )
        let json = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])

        #expect(object["client_callback_addr"] as? String == "http://127.0.0.1:50051")
        #expect(object["session_id"] as? String == "session-123")
        #expect(object["client_callback_secret"] as? String == "secret-123")
        #expect(object["system_reminders_enabled"] as? Bool == false)
        #expect(object["clientCallbackAddr"] == nil)

        let sparse = Data(#"{"tools":[],"system_reminders_enabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(FinalizeToolServerConfigRequest.self, from: sparse)
        #expect(decoded.clientCallbackAddr == nil)
        #expect(decoded.sessionId == nil)
        #expect(decoded.clientCallbackSecret == nil)
    }

    @Test("callback status preserves repeated order and an explicitly empty message")
    func callbackStatusWireShape() throws {
        let status = CallbackStatus(connected: true, activeSurfaces: ["n", "s"], message: "")
        let fixture: [UInt8] = [
            0x08, 0x01,
            0x12, 0x01, 0x6e,
            0x12, 0x01, 0x73,
            0x1a, 0x00,
        ]

        #expect(Array(status.protobufData()) == fixture)
        #expect(try CallbackStatus(protobufBytes: Data(fixture)) == status)
        #expect(CallbackStatus.FieldNumber.connected == 1)
        #expect(CallbackStatus.FieldNumber.activeSurfaces == 2)
        #expect(CallbackStatus.FieldNumber.message == 3)
    }

    @Test("finalize response nests optional callback status at field five")
    func finalizeResponseCallbackStatus() throws {
        let status = CallbackStatus(connected: true, activeSurfaces: ["n", "s"], message: "")
        let response = FinalizeToolServerConfigResponse(
            success: true,
            message: "ok",
            callbackStatus: status
        )
        let fixture: [UInt8] = [
            0x08, 0x01,
            0x12, 0x02, 0x6f, 0x6b,
            0x2a, 0x0a,
            0x08, 0x01,
            0x12, 0x01, 0x6e,
            0x12, 0x01, 0x73,
            0x1a, 0x00,
        ]

        #expect(Array(response.protobufData()) == fixture)
        #expect(try FinalizeToolServerConfigResponse(protobufBytes: Data(fixture)) == response)
        #expect(FinalizeToolServerConfigResponse.FieldNumber.callbackStatus == 5)

        let presentEmpty = FinalizeToolServerConfigResponse(callbackStatus: CallbackStatus())
        #expect(Array(presentEmpty.protobufData()) == [0x2a, 0x00])
        let decodedEmpty = try FinalizeToolServerConfigResponse(
            protobufBytes: presentEmpty.protobufData()
        )
        #expect(decodedEmpty.callbackStatus != nil)

        let legacy = Data([0x08, 0x01, 0x12, 0x02, 0x6f, 0x6b])
        let decodedLegacy = try FinalizeToolServerConfigResponse(protobufBytes: legacy)
        #expect(decodedLegacy.callbackStatus == nil)
        #expect(decodedLegacy.protobufData() == legacy)
    }

    @Test("finalize response and callback status use pinned JSON field names")
    func finalizeResponseCallbackJSON() throws {
        let response = FinalizeToolServerConfigResponse(
            callbackStatus: CallbackStatus(connected: true, activeSurfaces: ["notifications"])
        )
        let json = try JSONEncoder().encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let status = try #require(object["callback_status"] as? [String: Any])

        #expect(status["connected"] as? Bool == true)
        #expect(status["active_surfaces"] as? [String] == ["notifications"])
        #expect(object["version_warnings"] as? [Any] != nil)

        let sparse = Data(#"{"success":true,"message":"","tools":[],"version_warnings":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(FinalizeToolServerConfigResponse.self, from: sparse)
        #expect(decoded.callbackStatus == nil)
    }

    @Test("notification wire pins the session, serde JSON and uint64 sequence")
    func toolNotificationWireShape() throws {
        let notification = ToolNotificationMsg(sessionId: "s", notificationJson: "{}", sequence: 300)
        let fixture: [UInt8] = [
            0x0a, 0x01, 0x73,
            0x12, 0x02, 0x7b, 0x7d,
            0x18, 0xac, 0x02,
        ]

        #expect(Array(notification.protobufData()) == fixture)
        #expect(try ToolNotificationMsg(protobufBytes: Data(fixture)) == notification)
        #expect(ToolNotificationMsg.FieldNumber.sessionId == 1)
        #expect(ToolNotificationMsg.FieldNumber.notificationJson == 2)
        #expect(ToolNotificationMsg.FieldNumber.sequence == 3)
    }

    @Test("empty notification acknowledgments tolerate future fields")
    func notificationAckForwardCompatibility() throws {
        let acknowledgment = NotificationAck()
        #expect(acknowledgment.protobufData().isEmpty)

        let future = Data([0x08, 0x01, 0x12, 0x01, 0x78])
        #expect(try NotificationAck(protobufBytes: future) == acknowledgment)
    }

    @Test("spawn request preserves reserved gaps and repeated empty tool names")
    func spawnSubagentWireShape() throws {
        let request = SpawnSubagentRequest(
            id: "i",
            prompt: "p",
            description: "d",
            subagentType: "t",
            parentSessionId: "s",
            parentPromptId: "",
            resumeFrom: "r",
            cwd: "/",
            systemPrompt: "y",
            toolNames: ["a", "", "b"],
            initialUserMessage: "u"
        )
        let fixture: [UInt8] = [
            0x0a, 0x01, 0x69,
            0x12, 0x01, 0x70,
            0x1a, 0x01, 0x64,
            0x22, 0x01, 0x74,
            0x2a, 0x01, 0x73,
            0x32, 0x00,
            0x3a, 0x01, 0x72,
            0x42, 0x01, 0x2f,
            0x72, 0x01, 0x79,
            0x7a, 0x01, 0x61,
            0x7a, 0x00,
            0x7a, 0x01, 0x62,
            0x82, 0x01, 0x01, 0x75,
        ]

        #expect(Array(request.protobufData()) == fixture)
        #expect(try SpawnSubagentRequest(protobufBytes: Data(fixture)) == request)
        #expect(SpawnSubagentRequest.FieldNumber.cwd == 8)
        #expect(SpawnSubagentRequest.FieldNumber.systemPrompt == 14)
        #expect(SpawnSubagentRequest.FieldNumber.toolNames == 15)
        #expect(SpawnSubagentRequest.FieldNumber.initialUserMessage == 16)
    }

    @Test("spawn decoder skips all reserved fields and malformed known wire types")
    func spawnReservedFieldCompatibility() throws {
        let fixture: [UInt8] = [
            0x0a, 0x01, 0x69,
            0x4a, 0x01, 0x78,
            0x50, 0x01,
            0x5a, 0x00,
            0x60, 0x00,
            0x68, 0x00,
            0x70, 0x01,
            0x72, 0x01, 0x79,
            0x7a, 0x01, 0x61,
        ]
        let decoded = try SpawnSubagentRequest(protobufBytes: Data(fixture))

        #expect(decoded.id == "i")
        #expect(decoded.systemPrompt == "y")
        #expect(decoded.toolNames == ["a"])
        #expect(Array(decoded.protobufData()) == [
            0x0a, 0x01, 0x69,
            0x72, 0x01, 0x79,
            0x7a, 0x01, 0x61,
        ])
    }

    @Test("subagent result pins every scalar width and optional token presence")
    func subagentResultWireShape() throws {
        let result = SubagentResultMsg(
            success: true,
            output: "o",
            error: "",
            cancelled: true,
            subagentId: "i",
            childSessionId: "s",
            toolCalls: 150,
            turns: 2,
            durationMs: 300,
            tokensUsed: 1000,
            worktreePath: "/",
            backgrounded: true,
            outputTokensUsed: 0,
            totalTokensUsed: 300
        )
        let fixture: [UInt8] = [
            0x08, 0x01,
            0x12, 0x01, 0x6f,
            0x1a, 0x00,
            0x20, 0x01,
            0x2a, 0x01, 0x69,
            0x32, 0x01, 0x73,
            0x38, 0x96, 0x01,
            0x40, 0x02,
            0x48, 0xac, 0x02,
            0x50, 0xe8, 0x07,
            0x5a, 0x01, 0x2f,
            0x60, 0x01,
            0x68, 0x00,
            0x70, 0xac, 0x02,
        ]

        #expect(Array(result.protobufData()) == fixture)
        #expect(try SubagentResultMsg(protobufBytes: Data(fixture)) == result)
        #expect(SubagentResultMsg.FieldNumber.outputTokensUsed == 13)
        #expect(SubagentResultMsg.FieldNumber.totalTokensUsed == 14)
    }

    @Test("optional zero token counts are distinct from legacy absent fields")
    func subagentResultTokenPresence() throws {
        let absent = SubagentResultMsg()
        #expect(absent.protobufData().isEmpty)

        let present = SubagentResultMsg(outputTokensUsed: 0, totalTokensUsed: 0)
        #expect(Array(present.protobufData()) == [0x68, 0x00, 0x70, 0x00])
        let decoded = try SubagentResultMsg(protobufBytes: present.protobufData())
        #expect(decoded.outputTokensUsed == 0)
        #expect(decoded.totalTokensUsed == 0)
        #expect(try SubagentResultMsg(protobufBytes: Data()).outputTokensUsed == nil)
    }

    @Test("callback messages expose the same serde field names as pinned Rust")
    func callbackMessageJSONFieldNames() throws {
        let request = SpawnSubagentRequest(
            subagentType: "explore",
            parentSessionId: "parent",
            parentPromptId: "prompt",
            systemPrompt: "system",
            toolNames: ["read"],
            initialUserMessage: "start"
        )
        let json = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])

        #expect(object["subagent_type"] as? String == "explore")
        #expect(object["parent_session_id"] as? String == "parent")
        #expect(object["parent_prompt_id"] as? String == "prompt")
        #expect(object["system_prompt"] as? String == "system")
        #expect(object["tool_names"] as? [String] == ["read"])
        #expect(object["initial_user_message"] as? String == "start")
        #expect(object["parentSessionId"] == nil)

        let result = SubagentResultMsg(durationMs: 12, outputTokensUsed: 0, totalTokensUsed: 4)
        let resultJSON = try JSONEncoder().encode(result)
        let resultObject = try #require(
            JSONSerialization.jsonObject(with: resultJSON) as? [String: Any]
        )
        #expect(resultObject["duration_ms"] as? Int == 12)
        #expect(resultObject["output_tokens_used"] as? Int == 0)
        #expect(resultObject["total_tokens_used"] as? Int == 4)
    }

    @Test("callback descriptor exposes exactly two unary RPCs in proto order")
    func callbackServiceDescriptor() {
        #expect(GrokToolsCallbackServiceDescriptor.packageName == "xai.grok.tools.v1")
        #expect(
            GrokToolsCallbackServiceDescriptor.serviceName
                == "xai.grok.tools.v1.GrokToolsCallbackService"
        )
        #expect(grokToolsCallbackServiceRPCNames == ["SendNotification", "SpawnSubagent"])
        #expect(grokToolsCallbackServiceStreamingRPCs.isEmpty)
        #expect(GrokToolsCallbackServiceDescriptor.allMethodPaths == [
            "/xai.grok.tools.v1.GrokToolsCallbackService/SendNotification",
            "/xai.grok.tools.v1.GrokToolsCallbackService/SpawnSubagent",
        ])
        #expect(
            GrokToolsCallbackServiceDescriptor.methodSendNotification
                == "/xai.grok.tools.v1.GrokToolsCallbackService/SendNotification"
        )
        #expect(
            GrokToolsCallbackServiceDescriptor.methodSpawnSubagent
                == "/xai.grok.tools.v1.GrokToolsCallbackService/SpawnSubagent"
        )
    }

    @Test("callback protocol uses the exact request and unary response types")
    func callbackServiceTypedContract() async throws {
        let service: any GrokToolsCallbackService = PinnedCallbackServiceStub()
        let acknowledgment = try await service.sendNotification(
            ToolNotificationMsg(sessionId: "session", notificationJson: "{}", sequence: 1)
        )
        #expect(acknowledgment == NotificationAck())

        let result = try await service.spawnSubagent(SpawnSubagentRequest(id: "child"))
        #expect(result.success)
        #expect(result.subagentId == "child")
    }

    @Test("callback bearer is present on the wire but redacted from diagnostics")
    func callbackBearerDiagnosticRedaction() throws {
        let secret = "callback-bearer-never-print-4de33b61"
        let request = FinalizeToolServerConfigRequest(
            clientCallbackAddr: "http://127.0.0.1:50051",
            sessionId: "session-123",
            clientCallbackSecret: secret
        )

        #expect(request.protobufData().range(of: Data(secret.utf8)) != nil)
        let wireJSON = try JSONEncoder().encode(request)
        let wireObject = try #require(JSONSerialization.jsonObject(with: wireJSON) as? [String: Any])
        #expect(wireObject["client_callback_secret"] as? String == secret)

        var dumped = ""
        dump(request, to: &dumped)
        let mirroredChildren = Mirror(reflecting: request).children.map {
            "\($0.label ?? ""): \(String(reflecting: $0.value))"
        }
        let diagnostics = [
            request.description,
            request.debugDescription,
            String(describing: request),
            String(reflecting: request),
            "\(request)",
            dumped,
        ] + mirroredChildren

        for diagnostic in diagnostics {
            #expect(!diagnostic.contains(secret))
        }
        #expect(request.description.contains("[REDACTED]"))
        #expect(dumped.contains("[REDACTED]"))
    }
}

private struct PinnedCallbackServiceStub: GrokToolsCallbackService {
    func sendNotification(_ request: ToolNotificationMsg) async throws -> NotificationAck {
        NotificationAck()
    }

    func spawnSubagent(_ request: SpawnSubagentRequest) async throws -> SubagentResultMsg {
        SubagentResultMsg(success: true, subagentId: request.id)
    }
}
