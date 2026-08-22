// LiveCodexTurnStateTests.swift
//
// Executes the production sampler and compaction HTTP seams against the
// upstream `test_actor.rs:2290-2444` sticky-turn routing contract.

import Foundation
@testable import OpenGrokCLI
import OpenGrokCompaction
import OpenGrokHTTP
import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing

@Suite("Live Codex turn-scoped sticky routing")
struct LiveCodexTurnStateTests {
    private func inferenceResponse(
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
            #"{"type":"response.completed","response":{"id":"response-1","model":"gpt-test","status":"completed","output":[{"type":"message","role":"assistant","content":"ok"}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#
        )
        let body = events.map { "data: \($0)\n\n" }.joined()
        return .init(
            metadata: HTTPResponseMetadata(statusCode: status, headers: headers),
            body: Data(body.utf8)
        )
    }

    private func compactionResponse(headerState: String) -> MockHTTPTransport.ScriptedResponse {
        let body = """
        data: {"type":"response.output_item.done","item":{"type":"compaction","encrypted_content":"opaque-summary"}}

        data: {"type":"response.completed","response":{"id":"compaction-response"}}


        """
        return .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: [X_CODEX_TURN_STATE_HEADER: headerState]
            ),
            body: Data(body.utf8)
        )
    }

    private func makeSampler(
        transport: MockHTTPTransport,
        provider: ModelProvider = .codex,
        extraHeaders: [String: String] = [:]
    ) throws -> OpenGrokLiveSampler {
        try OpenGrokLiveSampler.production(configuration: OpenGrokLiveSamplingConfiguration(
            model: "gpt-test",
            baseURL: "https://provider.example.test",
            apiKey: "test-key",
            provider: provider,
            apiBackend: .responses,
            extraHeaders: extraHeaders,
            transport: transport
        ))
    }

    private func sample(
        _ sampler: OpenGrokLiveSampler,
        sessionID: String,
        turnID: String,
        logicalTurnID: String? = nil
    ) async throws {
        let result = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: sessionID,
                turnID: turnID,
                logicalTurnID: logicalTurnID,
                model: "gpt-test",
                prompt: "hello"
            ),
            emit: { _ in }
        )
        #expect(result.output == "ok")
    }

    private func makeCompaction(
        transport: MockHTTPTransport,
        state: CodexTurnStateCell
    ) -> HTTPCodexCompactionTransport {
        HTTPCodexCompactionTransport(
            transport: transport,
            baseURL: "https://provider.example.test",
            model: "gpt-test",
            headers: [:],
            codexTurnState: state,
            requestPolicy: ResponsesRequestPolicy(sessionID: "session", turnID: "turn-a")
        )
    }

    @Test("production replays the first token only within one logical session turn")
    func productionTurnReplayAndReset() async throws {
        let transport = MockHTTPTransport(responses: [
            inferenceResponse(headerState: "turn-a-state"),
            inferenceResponse(headerState: "must-not-replace-turn-a"),
            inferenceResponse(),
            inferenceResponse(headerState: "turn-b-state"),
            inferenceResponse(),
        ])
        let sampler = try makeSampler(transport: transport)

        try await sample(sampler, sessionID: "session", turnID: "turn-a")
        try await sample(sampler, sessionID: "session", turnID: "turn-a")
        try await sample(sampler, sessionID: "session", turnID: "turn-a")
        try await sample(sampler, sessionID: "session", turnID: "turn-b")
        try await sample(sampler, sessionID: "session", turnID: "turn-b")

        let requests = transport.recordedRequests
        #expect(requests.count == 5)
        #expect(requests[0].headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(requests[1].headers[X_CODEX_TURN_STATE_HEADER] == "turn-a-state")
        #expect(requests[2].headers[X_CODEX_TURN_STATE_HEADER] == "turn-a-state")
        #expect(requests[3].headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(requests[4].headers[X_CODEX_TURN_STATE_HEADER] == "turn-b-state")
    }

    @Test("parent and child sessions stay isolated while child tool rounds share a logical turn")
    func parentChildIsolationAndStableChildTurn() async throws {
        let transport = MockHTTPTransport(responses: [
            inferenceResponse(headerState: "parent-state"),
            inferenceResponse(headerState: "child-state"),
            inferenceResponse(),
            inferenceResponse(),
        ])
        let sampler = try makeSampler(transport: transport)

        try await sample(sampler, sessionID: "parent", turnID: "parent-turn")
        try await sample(
            sampler,
            sessionID: "child",
            turnID: "child-round-0",
            logicalTurnID: "child-logical-turn"
        )
        try await sample(sampler, sessionID: "parent", turnID: "parent-turn")
        try await sample(
            sampler,
            sessionID: "child",
            turnID: "child-round-1",
            logicalTurnID: "child-logical-turn"
        )

        let requests = transport.recordedRequests
        #expect(requests.count == 4)
        #expect(requests[0].headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(requests[1].headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(requests[2].headers[X_CODEX_TURN_STATE_HEADER] == "parent-state")
        #expect(requests[3].headers[X_CODEX_TURN_STATE_HEADER] == "child-state")
    }

    @Test("SSE response.metadata seeds the production sampler when HTTP omits the token")
    func responseMetadataSeedsProductionTurn() async throws {
        let transport = MockHTTPTransport(responses: [
            inferenceResponse(metadataState: "metadata-state"),
            inferenceResponse(),
        ])
        let sampler = try makeSampler(transport: transport)

        try await sample(sampler, sessionID: "session", turnID: "turn")
        try await sample(sampler, sessionID: "session", turnID: "turn")

        #expect(transport.recordedRequests[0].headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(transport.recordedRequests[1].headers[X_CODEX_TURN_STATE_HEADER] == "metadata-state")
    }

    @Test("a rejected inference response cannot poison its logical turn")
    func rejectedResponseCannotPoisonTurn() async throws {
        let transport = MockHTTPTransport(responses: [
            inferenceResponse(status: 429, headerState: "rejected-state"),
            inferenceResponse(headerState: "accepted-state"),
            inferenceResponse(),
        ])
        let sampler = try makeSampler(transport: transport)

        do {
            try await sample(sampler, sessionID: "session", turnID: "turn")
            Issue.record("rejected inference unexpectedly succeeded")
        } catch {
            let cell = try #require(sampler.codexTurnState(sessionID: "session", turnID: "turn"))
            #expect(cell.get() == nil)
        }
        try await sample(sampler, sessionID: "session", turnID: "turn")
        try await sample(sampler, sessionID: "session", turnID: "turn")

        let requests = transport.recordedRequests
        #expect(requests.count == 3)
        #expect(requests[1].headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(requests[2].headers[X_CODEX_TURN_STATE_HEADER] == "accepted-state")
    }

    @Test("forged sticky-routing headers are scrubbed before Codex and xAI requests")
    func forgedAndCrossProviderHeadersStayIsolated() async throws {
        let codexHTTP = MockHTTPTransport(responses: [inferenceResponse()])
        let codex = try makeSampler(
            transport: codexHTTP,
            extraHeaders: ["X-CODEX-TURN-STATE": "forged-state"]
        )
        let xaiHTTP = MockHTTPTransport(responses: [inferenceResponse()])
        let xai = try makeSampler(
            transport: xaiHTTP,
            provider: .xai,
            extraHeaders: ["X-CODEX-TURN-STATE": "forged-state"]
        )

        try await sample(codex, sessionID: "codex", turnID: "turn")
        try await sample(xai, sessionID: "xai", turnID: "turn")

        for request in codexHTTP.recordedRequests + xaiHTTP.recordedRequests {
            #expect(request.headers[X_CODEX_TURN_STATE_HEADER] == nil)
            #expect(request.headers["X-CODEX-TURN-STATE"] == nil)
        }
        #expect(xai.codexTurnState(sessionID: "xai", turnID: "turn") == nil)
    }

    @Test("bounded turn generation cannot resurrect an older session token")
    func oldTurnStateCannotResurrect() throws {
        let sampler = try makeSampler(transport: MockHTTPTransport())
        let old = try #require(sampler.codexTurnState(sessionID: "session", turnID: "turn-a"))
        #expect(old.setIfEmpty("expired-state"))
        let next = try #require(sampler.codexTurnState(sessionID: "session", turnID: "turn-b"))

        #expect(next.get() == nil)
        #expect(old !== next)
        let recreated = try #require(sampler.codexTurnState(sessionID: "session", turnID: "turn-a"))
        #expect(recreated.get() == nil)
        #expect(recreated !== old)

        let custom = OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "ok") }
        #expect(custom.codexTurnState(sessionID: "session", turnID: "turn-a") == nil)
    }

    @Test("inference and compaction replay one first-write-wins production token")
    func inferenceCompactionAndInferenceShareTurn() async throws {
        let inferenceHTTP = MockHTTPTransport(responses: [
            inferenceResponse(headerState: "inference-state"),
            inferenceResponse(),
        ])
        let sampler = try makeSampler(transport: inferenceHTTP)
        try await sample(sampler, sessionID: "session", turnID: "turn-a")

        let state = try #require(sampler.codexTurnState(sessionID: "session", turnID: "turn-a"))
        let compactionHTTP = MockHTTPTransport(responses: [
            compactionResponse(headerState: "must-not-replace-inference"),
        ])
        let compaction = makeCompaction(transport: compactionHTTP, state: state)
        let result = try await runCodexRemoteCompaction(
            transport: compaction,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )
        #expect(result.item.encryptedContent == "opaque-summary")

        try await sample(sampler, sessionID: "session", turnID: "turn-a")

        #expect(compactionHTTP.recordedRequests.first?.headers[X_CODEX_TURN_STATE_HEADER] == "inference-state")
        #expect(inferenceHTTP.recordedRequests[1].headers[X_CODEX_TURN_STATE_HEADER] == "inference-state")
        #expect(state.get() == "inference-state")
    }

    @Test("auto-compaction before first inference creates and seeds the production turn")
    func compactionFirstSeedsProductionInference() async throws {
        let inferenceHTTP = MockHTTPTransport(responses: [inferenceResponse()])
        let sampler = try makeSampler(transport: inferenceHTTP)
        let state = try #require(sampler.codexTurnState(sessionID: "session", turnID: "turn-a"))
        let compactionHTTP = MockHTTPTransport(responses: [
            compactionResponse(headerState: "compaction-state"),
        ])
        let compaction = makeCompaction(transport: compactionHTTP, state: state)

        let result = try await runCodexRemoteCompaction(
            transport: compaction,
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )
        #expect(result.item.encryptedContent == "opaque-summary")
        try await sample(sampler, sessionID: "session", turnID: "turn-a")

        #expect(compactionHTTP.recordedRequests.first?.headers[X_CODEX_TURN_STATE_HEADER] == nil)
        #expect(inferenceHTTP.recordedRequests.first?.headers[X_CODEX_TURN_STATE_HEADER] == "compaction-state")
    }
}
