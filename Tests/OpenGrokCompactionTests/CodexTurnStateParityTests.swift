// CodexTurnStateParityTests.swift
//
// Ports `xai-grok-sampler/src/client.rs:2297-2305,2403-2413,2454-2467`:
// successful compaction responses share the inference turn's first routing
// token; rejected responses and caller-supplied headers cannot replace it.

import Foundation
import OpenGrokCompaction
import OpenGrokHTTP
import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing

@Suite("Codex compaction sticky turn-state parity")
struct CodexTurnStateParityTests {
    private func streamingResponse(
        status: Int = 200,
        headerState: String? = nil,
        metadataState: String? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        if let headerState {
            headers[X_CODEX_TURN_STATE_HEADER] = headerState
        }
        guard (200..<300).contains(status) else {
            return .init(
                metadata: HTTPResponseMetadata(statusCode: status, headers: headers),
                body: Data(#"{"error":{"message":"rejected"}}"#.utf8)
            )
        }

        var events: [String] = []
        if let metadataState {
            events.append(
                #"{"type":"response.metadata","headers":{"x-codex-turn-state":"\#(metadataState)"}}"#
            )
        }
        events.append(
            #"{"type":"response.output_item.done","item":{"type":"compaction","encrypted_content":"opaque-summary"}}"#
        )
        events.append(#"{"type":"response.completed","response":{"id":"response-1"}}"#)
        let body = events.map { "data: \($0)\n\n" }.joined()
        return .init(
            metadata: HTTPResponseMetadata(statusCode: status, headers: headers),
            body: Data(body.utf8)
        )
    }

    private func unaryResponse(
        status: Int = 200,
        headerState: String? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let headerState {
            headers[X_CODEX_TURN_STATE_HEADER] = headerState
        }
        let body = (200..<300).contains(status)
            ? #"{"output":[{"type":"compaction","encrypted_content":"opaque-summary"}]}"#
            : #"{"error":{"message":"rejected"}}"#
        return .init(
            metadata: HTTPResponseMetadata(statusCode: status, headers: headers),
            body: Data(body.utf8)
        )
    }

    private func makeTransport(
        http: MockHTTPTransport,
        state: CodexTurnStateCell?,
        headers: [String: String] = [:]
    ) -> HTTPCodexCompactionTransport {
        HTTPCodexCompactionTransport(
            transport: http,
            baseURL: "https://codex.example.test",
            model: "gpt-test",
            headers: headers,
            codexTurnState: state,
            requestPolicy: ResponsesRequestPolicy(
                sessionID: "session-actual",
                turnID: "turn-actual"
            )
        )
    }

    @Test("V2 replays the inference token, rejects forged headers, and preserves its first value")
    func streamingCompactionReplaysFirstValue() async throws {
        let state = CodexTurnStateCell()
        #expect(state.setIfEmpty("inference-state"))
        let http = MockHTTPTransport(responses: [
            streamingResponse(headerState: "compaction-state"),
        ])
        let transport = makeTransport(
            http: http,
            state: state,
            headers: ["X-CODEX-TURN-STATE": "forged-state"]
        )

        let result = try await runCodexRemoteCompaction(
            transport: transport,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )

        #expect(result.item.encryptedContent == "opaque-summary")
        let request = try #require(http.recordedRequests.first)
        #expect(request.headers[X_CODEX_TURN_STATE_HEADER] == "inference-state")
        #expect(request.headers["X-CODEX-TURN-STATE"] == nil)
        #expect(state.get() == "inference-state")
    }

    @Test("V2 compaction can seed an empty logical turn from successful HTTP headers")
    func streamingCompactionSeedsTurn() async throws {
        let state = CodexTurnStateCell()
        let http = MockHTTPTransport(responses: [
            streamingResponse(headerState: "compaction-first"),
        ])
        let transport = makeTransport(http: http, state: state)

        let result = try await runCodexRemoteCompaction(
            transport: transport,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )

        #expect(result.item.encryptedContent == "opaque-summary")
        #expect(http.recordedRequests.first?.headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(state.get() == "compaction-first")
    }

    @Test("V2 response.metadata can seed the same turn when HTTP headers omit routing")
    func streamingMetadataSeedsTurn() async throws {
        let state = CodexTurnStateCell()
        let http = MockHTTPTransport(responses: [
            streamingResponse(metadataState: "metadata-state"),
        ])
        let transport = makeTransport(http: http, state: state)

        let result = try await runCodexRemoteCompaction(
            transport: transport,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )

        #expect(result.item.encryptedContent == "opaque-summary")
        #expect(state.get() == "metadata-state")
    }

    @Test("a rejected V2 response cannot poison the first-write-wins turn")
    func rejectedStreamingResponseCannotSeedTurn() async throws {
        let state = CodexTurnStateCell()
        let http = MockHTTPTransport(responses: [
            streamingResponse(status: 401, headerState: "rejected-state"),
        ])
        let transport = makeTransport(http: http, state: state)

        do {
            try await transport.send(
                CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")]),
                onEvent: { _ in }
            )
            Issue.record("rejected compaction unexpectedly succeeded")
        } catch {
            #expect(state.get() == nil)
        }
    }

    @Test("legacy unary compaction replays and seeds the same sticky routing contract")
    func legacyCompactionSeedsTurn() async throws {
        let state = CodexTurnStateCell()
        let http = MockHTTPTransport(responses: [
            unaryResponse(headerState: "legacy-state"),
        ])
        let transport = makeTransport(
            http: http,
            state: state,
            headers: ["X-Codex-Turn-State": "forged-state"]
        )

        let replacement = try await transport.compactLegacy(
            CodexCompactionRequest(protocolVersion: .legacyUnary, input: [.user("hello")])
        )

        #expect(replacement.count == 1)
        let request = try #require(http.recordedRequests.first)
        #expect(request.headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(request.headers["X-Codex-Turn-State"] == nil)
        #expect(state.get() == "legacy-state")
    }

    @Test("a rejected unary response cannot poison the first-write-wins turn")
    func rejectedUnaryResponseCannotSeedTurn() async throws {
        let state = CodexTurnStateCell()
        let http = MockHTTPTransport(responses: [
            unaryResponse(status: 429, headerState: "rejected-state"),
        ])
        let transport = makeTransport(http: http, state: state)

        do {
            let replacement = try await transport.compactLegacy(
                CodexCompactionRequest(protocolVersion: .legacyUnary, input: [.user("hello")])
            )
            Issue.record("rejected compaction unexpectedly returned \(replacement.count) items")
        } catch {
            #expect(state.get() == nil)
        }
    }

    @Test("a policy-free compaction cannot forward a forged sticky-routing header")
    func absentCellStripsForgedHeader() async throws {
        let http = MockHTTPTransport(responses: [streamingResponse()])
        let transport = makeTransport(
            http: http,
            state: nil,
            headers: ["X-CODEX-TURN-STATE": "forged-state"]
        )

        let result = try await runCodexRemoteCompaction(
            transport: transport,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )

        #expect(result.item.encryptedContent == "opaque-summary")
        let request = try #require(http.recordedRequests.first)
        #expect(request.headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(request.headers["X-CODEX-TURN-STATE"] == nil)
    }
}
