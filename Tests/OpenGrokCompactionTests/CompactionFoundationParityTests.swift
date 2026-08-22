import Foundation
import OpenGrokHTTP
@testable import OpenGrokCompaction
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

private struct FoundationCompactionSampler: CompactionSampler {
    typealias Item = ConversationItem

    func sampleCompaction(
        turns: [ConversationItem],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        LLMCompactionOutput(response: "unused")
    }
}

@Suite("Codex compaction foundational wire and persistence parity")
struct CompactionFoundationParityTests {
    private func permissions(autoReview: Bool = true) -> CodexPermissions {
        CodexPermissions(
            sandbox: "seatbelt",
            sandboxMode: "workspace-write",
            sandboxProfile: "workspace",
            networkAccess: false,
            writableRoots: ["/tmp/project"],
            approvalPolicy: .onRequest,
            autoReviewEnabled: autoReview
        )
    }

    private func streamingResponse() -> MockHTTPTransport.ScriptedResponse {
        let body = """
        data: {"type":"response.output_item.done","item":{"type":"message","id":"ignored"}}

        data: {"type":"response.output_item.done","item":{"type":"compaction","encrypted_content":"opaque-summary"}}

        data: {"type":"response.completed","response":{"id":"response-1"}}


        """
        return MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data(body.utf8)
        )
    }

    private func policy() -> ResponsesRequestPolicy {
        ResponsesRequestPolicy(
            multiAgentV2: true,
            localEffort: .high,
            reasoningSummary: .detailed,
            codexPermissions: permissions(),
            sessionID: "session-actual",
            turnID: "turn-7"
        )
    }

    @Test("provider-native idless encrypted compaction items survive real SSE unchanged")
    func providerNativeIdlessCompactionItem() async throws {
        let http = MockHTTPTransport(responses: [streamingResponse()])
        let transport = HTTPCodexCompactionTransport(
            transport: http,
            baseURL: "https://codex.example.test",
            model: "gpt-codex",
            headers: [:]
        )

        let result = try await runCodexRemoteCompaction(
            transport: transport,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )

        #expect(result.item.id.isEmpty)
        #expect(result.item.encryptedContent == "opaque-summary")
        #expect(result.item.raw["type"]?.stringValue == "compaction")
        #expect(result.item.raw["encrypted_content"]?.stringValue == "opaque-summary")
        #expect(result.item.raw["id"] == nil)
        #expect(http.recordedRequests.first?.url.path == "/v1/responses")
    }

    @Test("V2 sends exact Responses contract, current permissions, affinity, and canonical metadata")
    func remoteV2WirePolicy() async throws {
        let http = MockHTTPTransport(responses: [streamingResponse()])
        let transport = HTTPCodexCompactionTransport(
            transport: http,
            baseURL: "https://codex.example.test/backend-api/codex",
            model: "gpt-codex",
            headers: [
                "X-CODEX-TURN-METADATA": "forged",
                "Session-ID": "forged-session",
                "x-grok-user-id": "must-not-leak",
                "X-Codex-Beta-Features": "existing_beta,remote_compaction_v2",
            ],
            queryParams: ["origin": "desktop"],
            cacheAffinityID: "session-root-affinity",
            requestPolicy: policy()
        )
        let result = try await runCodexRemoteCompaction(
            transport: transport,
            request: CodexCompactionRequest(
                protocolVersion: .remoteV2,
                input: [.system("system"), .user("hello")],
                compactionHash: "must-not-be-on-wire",
                turnState: "must-not-be-on-wire",
                serviceTier: "priority"
            )
        )
        #expect(result.item.encryptedContent == "opaque-summary")

        let request = try #require(http.recordedRequests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        let input = try #require(body["input"]?.arrayValue)
        let metadataText = try #require(
            body["client_metadata"]?[X_CODEX_TURN_METADATA_HEADER]?.stringValue
        )
        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(metadataText.utf8))

        #expect(request.url.path == "/backend-api/codex/responses")
        #expect(request.url.query == "origin=desktop")
        #expect(request.headers[X_CODEX_TURN_METADATA_HEADER] == metadataText)
        #expect(request.headers["X-CODEX-TURN-METADATA"] == nil)
        #expect(request.headers["Session-ID"] == nil)
        #expect(request.headers[CODEX_SESSION_ID_HEADER] == "session-root-affinity")
        #expect(request.headers[CODEX_THREAD_ID_HEADER] == "session-root-affinity")
        #expect(request.headers[CODEX_CLIENT_REQUEST_ID_HEADER] == "session-root-affinity")
        #expect(request.headers["x-grok-user-id"] == nil)
        #expect(request.headers["x-codex-beta-features"] == "existing_beta,remote_compaction_v2")
        #expect(metadata["session_id"]?.stringValue == "session-actual")
        #expect(metadata["turn_id"]?.stringValue == "turn-7")
        #expect(metadata["sandbox_mode"]?.stringValue == "workspace-write")
        #expect(metadata["auto_review_enabled"]?.boolValue == true)
        #expect(body["store"]?.boolValue == false)
        #expect(body["stream"]?.boolValue == true)
        #expect(body["parallel_tool_calls"]?.boolValue == true)
        #expect(body["tool_choice"]?.stringValue == "auto")
        #expect(body["service_tier"]?.stringValue == "priority")
        #expect(body["prompt_cache_key"]?.stringValue == "session-root-affinity")
        #expect(body["include"]?.arrayValue == [.string("reasoning.encrypted_content")])
        #expect(body["reasoning"]?["effort"]?.stringValue == "high")
        #expect(body["reasoning"]?["summary"]?.stringValue == "detailed")
        #expect(body["compaction_trigger"] == nil)
        #expect(body["comp_hash"] == nil)
        #expect(body["turn_state"] == nil)
        #expect(input.last?["type"]?.stringValue == "compaction_trigger")
        #expect(input.filter { $0["type"]?.stringValue == "compaction_trigger" }.count == 1)
        #expect(input.contains {
            $0["role"]?.stringValue == "developer"
                && ($0["content"]?.arrayValue?.first?["text"]?.stringValue?
                    .contains("<permissions instructions>") == true)
        })
    }

    @Test("a policy-free compaction strips forged metadata and still preserves account headers")
    func policyFreeSanitization() async throws {
        let http = MockHTTPTransport(responses: [streamingResponse()])
        let transport = HTTPCodexCompactionTransport(
            transport: http,
            baseURL: "https://codex.example.test",
            model: "gpt-codex",
            headers: [
                "X-CODEX-TURN-METADATA": "forged",
                "ChatGPT-Account-ID": "account-123",
            ]
        )

        let result = try await runCodexRemoteCompaction(
            transport: transport,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )
        #expect(result.item.type == "compaction")

        let request = try #require(http.recordedRequests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(request.headers[X_CODEX_TURN_METADATA_HEADER] == nil)
        #expect(request.headers["X-CODEX-TURN-METADATA"] == nil)
        #expect(request.headers["ChatGPT-Account-ID"] == "account-123")
        #expect(body["client_metadata"] == nil)
    }

    @Test("legacy unary installs every exact replacement item and strips streaming-only fields")
    func legacyUnaryRetainsCompleteHistory() async throws {
        let output: [JSONValue] = [
            .object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .string("retained prompt"),
            ]),
            .object([
                "type": .string("compaction"),
                "encrypted_content": .string("legacy-opaque"),
            ]),
        ]
        let responseBody = try JSONEncoder().encode(JSONValue.object(["output": .array(output)]))
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: responseBody
            ),
        ])
        let transport = HTTPCodexCompactionTransport(
            transport: http,
            baseURL: "https://codex.example.test",
            model: "gpt-codex",
            headers: [:],
            requestPolicy: policy()
        )
        let engine = CompactionEngine(
            configuration: CompactionEngineConfiguration(
                budget: resolveCompactionBudget(contextWindow: 10_000),
                strategy: .codexLegacyUnary,
                modelID: "gpt-codex"
            ),
            sampler: FoundationCompactionSampler(),
            codexTransport: transport
        )

        let outcome = await engine.compact(items: [.user("original")])
        guard case .compacted(let replacement, let report) = outcome else {
            Issue.record("legacy unary did not install its replacement: \(outcome)")
            return
        }
        #expect(report.kind == .codexLegacyUnary)
        #expect(replacement.count == 2)
        for (index, item) in replacement.enumerated() {
            guard case .backendToolCall(let call) = item,
                  case .codexRawInput(let raw) = call.kind
            else {
                Issue.record("legacy output \(index) was not retained as provider-native input")
                continue
            }
            #expect(raw.raw == output[index])
        }

        let request = try #require(http.recordedRequests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(request.url.path == "/v1/responses/compact")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers[X_CODEX_TURN_METADATA_HEADER] != nil)
        for forbidden in ["store", "stream", "include", "tool_choice", "compaction_trigger", "comp_hash", "turn_state"] {
            #expect(body[forbidden] == nil, "unexpected legacy-only forbidden field \(forbidden)")
        }
        #expect(!(body["input"]?.arrayValue ?? []).contains {
            $0["type"]?.stringValue == "compaction_trigger"
        })
    }

    @Test("canonical ACP and xAI checkpoint envelopes decode without losing replay identity")
    func canonicalSessionUpdateEnvelopes() throws {
        let checkpoint = Data(#"{"method":"_x.ai/session/update","params":{"sessionId":"session","update":{"sessionUpdate":"compaction_checkpoint","checkpoint_id":"checkpoint-1","prompt_index_at_compaction":4,"checkpoint_file":"compaction_checkpoints/checkpoint-1.json","auto_continue":{"prompt_text":"continue"}}}}"#.utf8)
        let user = Data(#"{"method":"session/update","params":{"sessionId":"session","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"question"},"_meta":{"promptIndex":5}}}}"#.utf8)
        let assistant = Data(#"{"method":"session/update","params":{"sessionId":"session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"answer"}}}}"#.utf8)
        let rewind = Data(#"{"method":"_x.ai/session/update","params":{"sessionId":"session","update":{"sessionUpdate":"rewind_marker","target_prompt_index":3}}}"#.utf8)

        #expect(try JSONDecoder().decode(SessionUpdateRecord.self, from: checkpoint)
            == .checkpoint(id: "checkpoint-1", promptIndex: 4, autoContinueText: "continue"))
        #expect(try JSONDecoder().decode(SessionUpdateRecord.self, from: user)
            == .user(text: "question", promptIndex: 5))
        #expect(try JSONDecoder().decode(SessionUpdateRecord.self, from: assistant)
            == .agent(text: "answer"))
        #expect(try JSONDecoder().decode(SessionUpdateRecord.self, from: rewind)
            == .rewindMarker(targetPromptIndex: 3))
    }
}
