// CompactionServiceTierTests.swift
//
// The service tier on the Codex compaction wire. Upstream deliberately KEEPS
// `service_tier` in the compact body: the retain lists allow it
// (xai-grok-sampler client.rs:668-692, :694-728), the request inherits the
// session tier through `apply_conversation_defaults` (client.rs:3234-3236),
// and `codex_remote_compaction_v2_body_keeps_stream_contract_fields`
// (client.rs:3827-3858) pins `"service_tier": "priority"` surviving. A Fast
// session's server-side compaction therefore rides the same priority lane as
// its sampling — these tests keep that carriage from silently dropping.

import Foundation
import OpenGrokHTTP
@testable import OpenGrokCompaction
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

/// Replays a scripted Codex event stream, recording the request it was given.
private final class TierScriptedTransport: CodexCompactionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[CodexCompactionStreamEvent]]
    private var requests: [CodexCompactionRequest] = []

    init(scripts: [[CodexCompactionStreamEvent]]) {
        self.scripts = scripts
    }

    var recordedRequests: [CodexCompactionRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    private func nextScript(for request: CodexCompactionRequest) -> [CodexCompactionStreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return scripts.isEmpty ? [] : scripts.removeFirst()
    }

    func send(
        _ request: CodexCompactionRequest,
        onEvent: @Sendable (CodexCompactionStreamEvent) async throws -> Void
    ) async throws {
        for event in nextScript(for: request) {
            try await onEvent(event)
        }
    }
}

private struct TierUnusedSampler: CompactionSampler, Sendable {
    typealias Item = ConversationItem

    func sampleCompaction(
        turns: [ConversationItem],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        LLMCompactionOutput(response: "")
    }
}

/// Big enough to trip a 100k-token window at its default threshold.
private func overflowingConversation() -> [ConversationItem] {
    var items: [ConversationItem] = [.system("You are Open Grok.")]
    for index in 0..<12 {
        items.append(.user("Question \(index): " + String(repeating: "q", count: 20_000)))
        items.append(.assistant(AssistantItem(
            content: "Answer \(index): " + String(repeating: "a", count: 20_000)
        )))
    }
    return items
}

@Suite("Compaction service-tier carriage")
struct CompactionServiceTierTests {
    private func codexEngine(
        transport: TierScriptedTransport,
        serviceTier: String?
    ) -> CompactionEngine<TierUnusedSampler> {
        var policy = CompactionPolicy()
        policy.enabled = true
        policy.mode = .fullReplace
        policy.maxAttempts = 1
        policy.retryDelayMilliseconds = 0
        return CompactionEngine(
            configuration: CompactionEngineConfiguration(
                policy: policy,
                budget: resolveCompactionBudget(
                    contextWindow: 100_000,
                    defaultThresholdPercent: 85
                ),
                strategy: .codexRemoteV2,
                modelID: "gpt-5.6-sol",
                compactionHash: "hash-abc",
                serviceTier: serviceTier
            ),
            sampler: TierUnusedSampler(),
            codexTransport: transport
        )
    }

    @Test("the engine replays the session tier onto the Codex compact request")
    func engineThreadsTierIntoCodexRequest() async throws {
        let encrypted = "gAAAA" + String(repeating: "e", count: 64)
        let raw = JSONValue.object([
            "id": .string("comp_tier"),
            "type": .string("compaction"),
            "encrypted_content": .string(encrypted),
        ])
        let transport = TierScriptedTransport(scripts: [[
            .outputItemDone(CodexCompactionOutputItem(
                id: "comp_tier",
                type: "compaction",
                raw: raw,
                encryptedContent: encrypted
            )),
            .responseCompleted,
        ]])

        let outcome = await codexEngine(transport: transport, serviceTier: "priority")
            .compact(items: overflowingConversation())
        guard case .compacted = outcome else {
            Issue.record("expected a remote compaction, got \(outcome)")
            return
        }
        // Asserted on the recorded request, at the step it happens.
        try #require(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests[0].serviceTier == "priority")
    }

    @Test("the compact body carries service_tier when set and omits it when not")
    func encodedBodyCarriesTier() throws {
        let transport = HTTPCodexCompactionTransport(
            transport: URLSessionHTTPTransport(),
            baseURL: "https://chatgpt.com/backend-api/codex",
            model: "gpt-5.6-sol",
            headers: [:]
        )

        // Fast on: the exact field and wire value upstream's retain-list test
        // pins (client.rs:3837, :3850).
        let fastBody = try transport.encodeBody(CodexCompactionRequest(
            protocolVersion: .remoteV2,
            input: [.user("hello")],
            serviceTier: "priority"
        ))
        let fastObject = try #require(
            try JSONSerialization.jsonObject(with: fastBody) as? [String: Any]
        )
        #expect(fastObject["service_tier"] as? String == "priority")

        // Standard routing is the ABSENCE of the field, never `"default"`.
        let standardBody = try transport.encodeBody(CodexCompactionRequest(
            protocolVersion: .remoteV2,
            input: [.user("hello")]
        ))
        let standardObject = try #require(
            try JSONSerialization.jsonObject(with: standardBody) as? [String: Any]
        )
        #expect(standardObject["service_tier"] == nil)
    }
}
