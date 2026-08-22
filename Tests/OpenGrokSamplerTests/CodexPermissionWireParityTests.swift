// CodexPermissionWireParityTests.swift
//
// Ports `xai-grok-sampler/src/provider.rs:1171-1301` and additionally
// asserts the real streaming HTTP seam from `client.rs:2530-2553`.

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared

@Suite("Codex execution policy wire parity")
struct CodexPermissionWireParityTests {
    private func workspacePermissions(autoReviewEnabled: Bool = true) -> CodexPermissions {
        CodexPermissions(
            sandbox: "seatbelt",
            sandboxMode: "workspace-write",
            sandboxProfile: "workspace",
            networkAccess: true,
            writableRoots: ["/tmp/project", "/tmp/second root"],
            approvalPolicy: .onRequest,
            autoReviewEnabled: autoReviewEnabled
        )
    }

    private func baseRequest() -> JSONValue {
        .object([
            "input": .array([
                .object([
                    "type": .string("message"),
                    "role": .string("system"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string("base prompt")]),
                    ]),
                ]),
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string("hello")]),
                    ]),
                ]),
            ]),
            "reasoning": .object([
                "effort": .string("xhigh"),
                "summary": .string("concise"),
            ]),
        ])
    }

    private func metadata(in request: JSONValue) throws -> JSONValue {
        let encoded = try #require(
            request["client_metadata"]?[X_CODEX_TURN_METADATA_HEADER]?.stringValue
        )
        return try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8))
    }

    private func permissionInstructions(in request: JSONValue) -> [String] {
        (request["input"]?.arrayValue ?? []).compactMap { item in
            guard item["role"]?.stringValue == "developer" else { return nil }
            let text = item["content"]?.arrayValue?
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: "\n")
            return text?.contains("<permissions instructions>") == true ? text : nil
        }
    }

    private func mockResponse() -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            )
        )
    }

    private func recordedBody(from transport: MockHTTPTransport) throws -> JSONValue {
        let request = try #require(transport.recordedRequests.first)
        let body = try #require(request.body)
        return try JSONDecoder().decode(JSONValue.self, from: body)
    }

    @Test("execution policy uses the upstream snake-case Codable contract")
    func codableContract() throws {
        let permissions = workspacePermissions()
        let data = try JSONEncoder().encode(permissions)
        let object = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(object["sandbox"]?.stringValue == "seatbelt")
        #expect(object["sandbox_mode"]?.stringValue == "workspace-write")
        #expect(object["sandbox_profile"]?.stringValue == "workspace")
        #expect(object["network_access"]?.boolValue == true)
        #expect(object["writable_roots"]?.arrayValue?.count == 2)
        #expect(object["approval_policy"]?.stringValue == "on-request")
        #expect(object["auto_review_enabled"]?.boolValue == true)
        #expect(try JSONDecoder().decode(CodexPermissions.self, from: data) == permissions)
    }

    @Test("sampler config preserves policy and remains compatible with older configs")
    func samplerConfigRoundTrip() throws {
        let config = SamplerConfig(
            provider: .codex,
            codexPermissions: workspacePermissions()
        )
        let encoded = try JSONEncoder().encode(config)
        let object = try JSONDecoder().decode(JSONValue.self, from: encoded)

        #expect(object["codex_permissions"]?["sandbox_mode"]?.stringValue == "workspace-write")
        #expect(try JSONDecoder().decode(SamplerConfig.self, from: encoded).codexPermissions == config.codexPermissions)
        #expect(try JSONDecoder().decode(SamplerConfig.self, from: Data("{}".utf8)).codexPermissions == nil)
    }

    @Test("Codex reports applied sandbox and auto-review exactly once")
    func workspaceAutoReviewIsIdempotent() throws {
        var request = baseRequest()
        let policy = ResponsesRequestPolicy(
            codexPermissions: workspacePermissions(),
            sessionID: "session-123",
            turnID: "7"
        )

        providerAdapter(.codex).patchResponsesRequest(&request, policy: policy)
        providerAdapter(.codex).patchResponsesRequest(&request, policy: policy)

        let metadata = try metadata(in: request)
        #expect(metadata["sandbox"]?.stringValue == "seatbelt")
        #expect(metadata["sandbox_mode"]?.stringValue == "workspace-write")
        #expect(metadata["auto_review_enabled"]?.boolValue == true)
        #expect(metadata["session_id"]?.stringValue == "session-123")
        #expect(metadata["thread_id"]?.stringValue == "session-123")
        #expect(metadata["turn_id"]?.stringValue == "7")
        #expect(metadata["open_grok_sandbox_profile"]?.stringValue == "workspace")

        let instructions = permissionInstructions(in: request)
        #expect(instructions.count == 1)
        let instruction = try #require(instructions.first)
        #expect(instruction.contains("`workspace-write`"))
        #expect(instruction.contains("`auto_review`"))
        #expect(instruction.contains("`/tmp/project`, `/tmp/second root`"))
        #expect(request["input"]?[0]?["role"]?.stringValue == "developer")
        #expect(request["input"]?[1]?["role"]?.stringValue == "user")
    }

    @Test("an unsandboxed YOLO session never claims filesystem confinement")
    func unsandboxedYOLOIsTruthful() throws {
        var request = baseRequest()
        providerAdapter(.codex).patchResponsesRequest(
            &request,
            policy: ResponsesRequestPolicy(codexPermissions: CodexPermissions(
                sandbox: "none",
                sandboxMode: "danger-full-access",
                networkAccess: true,
                writableRoots: [],
                approvalPolicy: .never,
                autoReviewEnabled: false
            ))
        )

        let metadata = try metadata(in: request)
        #expect(metadata["sandbox"]?.stringValue == "none")
        #expect(metadata["sandbox_mode"]?.stringValue == "danger-full-access")
        #expect(metadata["open_grok_sandbox_profile"] == nil)

        let instruction = try #require(permissionInstructions(in: request).first)
        #expect(instruction.contains("No filesystem sandbox is active"))
        #expect(instruction.contains("Approval policy is `never`"))
        #expect(!instruction.contains("The writable roots are"))
    }

    @Test("read-only manual approval reports actual network restrictions")
    func readOnlyManualApproval() throws {
        var request = baseRequest()
        providerAdapter(.codex).patchResponsesRequest(
            &request,
            policy: ResponsesRequestPolicy(codexPermissions: CodexPermissions(
                sandbox: "seatbelt",
                sandboxMode: "read-only",
                sandboxProfile: "read-only",
                networkAccess: false,
                writableRoots: [],
                approvalPolicy: .onRequest,
                autoReviewEnabled: false
            ))
        )

        let metadata = try metadata(in: request)
        #expect(metadata["sandbox_mode"]?.stringValue == "read-only")
        #expect(metadata["auto_review_enabled"]?.boolValue == false)
        let instruction = try #require(permissionInstructions(in: request).first)
        #expect(instruction.contains("workspace files cannot be modified"))
        #expect(instruction.contains("Network access is restricted"))
        #expect(instruction.contains("Approval policy is `on-request`"))
        #expect(!instruction.contains("`auto_review`"))
    }

    @Test("Codex policy preserves unrelated client metadata")
    func unrelatedMetadataSurvives() throws {
        var request = baseRequest()
        guard case .object(var object) = request else {
            Issue.record("base request is not an object")
            return
        }
        object["client_metadata"] = .object(["other": .string("preserved")])
        request = .object(object)

        providerAdapter(.codex).patchResponsesRequest(
            &request,
            policy: ResponsesRequestPolicy(codexPermissions: workspacePermissions())
        )

        #expect(request["client_metadata"]?["other"]?.stringValue == "preserved")
        #expect(try metadata(in: request)["sandbox"]?.stringValue == "seatbelt")
    }

    @Test("permission and multi-agent developer instructions coexist without duplication")
    func permissionsCoexistWithMultiAgentPolicy() throws {
        var request = baseRequest()
        let policy = ResponsesRequestPolicy(
            multiAgentV2: true,
            localEffort: .ultra,
            codexPermissions: workspacePermissions()
        )

        providerAdapter(.codex).patchResponsesRequest(&request, policy: policy)
        providerAdapter(.codex).patchResponsesRequest(&request, policy: policy)

        let input = try #require(request["input"]?.arrayValue)
        #expect(input.count == 3)
        #expect(permissionInstructions(in: request).count == 1)
        #expect(input[0]["content"]?[0]?["text"]?.stringValue?.contains(
            "<permissions instructions>"
        ) == true)
        #expect(input[1]["content"]?[0]?["text"]?.stringValue?.contains(
            MULTI_AGENT_MODE_OPEN_TAG
        ) == true)
        #expect(input[2]["role"]?.stringValue == "user")
    }

    @Test("execution policy never crosses to non-Codex provider adapters")
    func adaptersPreserveProviderBoundary() {
        for provider in [ModelProvider.xai, .deepseek, .meta] {
            var request = baseRequest()
            providerAdapter(provider).patchResponsesRequest(
                &request,
                policy: ResponsesRequestPolicy(codexPermissions: workspacePermissions())
            )

            #expect(request["client_metadata"] == nil)
            #expect(permissionInstructions(in: request).isEmpty)
        }
    }

    @Test("live streaming sends byte-identical body metadata and HTTP header")
    func liveStreamingHeaderMatchesBody() async throws {
        let transport = MockHTTPTransport(responses: [mockResponse()])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://codex.example.test",
                model: "gpt-test",
                apiBackend: .responses,
                provider: .codex,
                extraHeaders: [(name: "X-CODEX-TURN-METADATA", value: "forged")],
                codexPermissions: workspacePermissions()
            ),
            transport: transport
        )

        let (_, _, _, _) = try await client.conversationStreamResponses(ConversationRequest(
            items: [.user("hello")],
            xGrokSessionId: "session-live",
            xGrokTurnIdx: "42"
        ))

        let recorded = try #require(transport.recordedRequests.first)
        let body = try recordedBody(from: transport)
        let canonicalMetadata = try #require(
            body["client_metadata"]?[X_CODEX_TURN_METADATA_HEADER]?.stringValue
        )
        #expect(recorded.headers[X_CODEX_TURN_METADATA_HEADER] == canonicalMetadata)
        #expect(!recorded.headers.keys.contains("X-CODEX-TURN-METADATA"))
        #expect(try metadata(in: body)["session_id"]?.stringValue == "session-live")
        #expect(try metadata(in: body)["turn_id"]?.stringValue == "42")
        #expect(permissionInstructions(in: body).count == 1)
    }

    @Test("turn-scoped nil explicitly strips an inherited Codex policy")
    func explicitNilStripsInheritedPolicy() async throws {
        let transport = MockHTTPTransport(responses: [mockResponse()])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://codex.example.test",
                model: "gpt-test",
                apiBackend: .responses,
                provider: .codex,
                extraHeaders: [(name: X_CODEX_TURN_METADATA_HEADER, value: "stale")],
                codexPermissions: workspacePermissions()
            ),
            transport: transport
        )

        let (_, _, _, _) = try await client.conversationStreamResponses(
            ConversationRequest(items: [.user("hello")]),
            codexPermissions: nil
        )

        let recorded = try #require(transport.recordedRequests.first)
        let body = try recordedBody(from: transport)
        #expect(recorded.headers[X_CODEX_TURN_METADATA_HEADER] == nil)
        #expect(body["client_metadata"] == nil)
        #expect(permissionInstructions(in: body).isEmpty)
    }

    @Test("each streaming turn uses its explicitly supplied current approval mode")
    func perTurnApprovalModeUpdates() async throws {
        let transport = MockHTTPTransport(responses: [mockResponse(), mockResponse()])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://codex.example.test",
                model: "gpt-test",
                apiBackend: .responses,
                provider: .codex,
                codexPermissions: workspacePermissions(autoReviewEnabled: false)
            ),
            transport: transport
        )

        let (_, _, _, _) = try await client.conversationStreamResponses(
            ConversationRequest(items: [.user("first")]),
            codexPermissions: workspacePermissions(autoReviewEnabled: false)
        )
        let (_, _, _, _) = try await client.conversationStreamResponses(
            ConversationRequest(items: [.user("second")]),
            codexPermissions: workspacePermissions(autoReviewEnabled: true)
        )

        let requests = transport.recordedRequests
        #expect(requests.count == 2)
        let firstBody = try JSONDecoder().decode(
            JSONValue.self,
            from: try #require(requests[0].body)
        )
        let secondBody = try JSONDecoder().decode(
            JSONValue.self,
            from: try #require(requests[1].body)
        )
        #expect(try metadata(in: firstBody)["auto_review_enabled"]?.boolValue == false)
        #expect(try metadata(in: secondBody)["auto_review_enabled"]?.boolValue == true)
        #expect(!permissionInstructions(in: firstBody)[0].contains("`auto_review`"))
        #expect(permissionInstructions(in: secondBody)[0].contains("`auto_review`"))
    }

    @Test("non-Codex live requests cannot leak execution metadata or headers")
    func liveProviderBoundary() async throws {
        let transport = MockHTTPTransport(responses: [mockResponse()])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://xai.example.test",
                model: "grok-test",
                apiBackend: .responses,
                provider: .xai,
                extraHeaders: [(name: X_CODEX_TURN_METADATA_HEADER, value: "forged")],
                codexPermissions: workspacePermissions()
            ),
            transport: transport
        )

        let (_, _, _, _) = try await client.conversationStreamResponses(
            ConversationRequest(items: [.user("hello")]),
            codexPermissions: workspacePermissions()
        )

        let recorded = try #require(transport.recordedRequests.first)
        let body = try recordedBody(from: transport)
        #expect(recorded.headers[X_CODEX_TURN_METADATA_HEADER] == nil)
        #expect(body["client_metadata"] == nil)
        #expect(permissionInstructions(in: body).isEmpty)
    }
}
