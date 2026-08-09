// FireworksPacingGateTests.swift
//
// The `.58` Fireworks pacing gate: a process-global two-permit semaphore
// (client.rs:59-83) that only Fireworks requests acquire, held until the
// response stream drops on the streaming path (client.rs:1937, :2097-2100).
// The boundedness test is the port of
// `fireworks_request_gate_is_provider_local_and_bounded` (client.rs:4191-4229)
// with deterministic orchestration (actor state instead of timeouts); the
// live-seam tests prove acquisition and release through the real client
// request path against injected gates, because the process-global gate is
// shared with every other suite's Fireworks client under parallel runs.

import Foundation
import Testing
@testable import OpenGrokSampler
import OpenGrokHTTP
import OpenGrokSamplingTypes

/// Bounded poll on actor state. The 1ms sleep is pacing between observations,
/// never a correctness delay: the awaited condition is the assertion, and a
/// condition that never turns true fails the test rather than hanging it.
private func pollUntil(
    timeout: MonotonicDuration = .seconds(10),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let startedAt = MonotonicInstant.now
    while MonotonicInstant.now - startedAt < timeout {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

private func sseBody(_ events: [String]) -> Data {
    var s = ""
    for e in events {
        s += "data: \(e)\n\n"
    }
    s += "data: [DONE]\n\n"
    return Data(s.utf8)
}

private let chunkJSON =
    #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]}"#

private func fireworksClient(
    transport: MockHTTPTransport,
    gate: RequestPacingSemaphore
) throws -> SamplingClient {
    let client = try SamplingClient(
        config: SamplerConfig(
            apiKey: "test-key",
            baseURL: "https://api.fireworks.ai/inference/v1",
            model: "accounts/fireworks/models/glm-5p2",
            apiBackend: .chatCompletions,
            provider: .fireworks
        ),
        transport: transport
    )
    client.providerRequestGate = gate
    return client
}

@Suite("Fireworks request pacing gate")
struct FireworksPacingGateTests {
    /// Port of `fireworks_request_gate_is_provider_local_and_bounded`
    /// (client.rs:4191-4229). Upstream proves "the third request blocks" with
    /// a 10ms timeout race; here the actor exposes its waiter queue, so the
    /// block is observed directly and no wall-clock guess can flake.
    @Test("the gate is provider-local and bounded at two permits")
    func gateIsProviderLocalAndBounded() async throws {
        let gate = RequestPacingSemaphore(permits: FIREWORKS_MAX_CONCURRENT_REQUESTS)

        // client.rs:4195-4200 — a non-Fireworks provider bypasses entirely.
        let bypass = try await acquireProviderRequestPermit(provider: .xai, gate: gate)
        #expect(bypass == nil)
        #expect(await gate.availablePermits == FIREWORKS_MAX_CONCURRENT_REQUESTS)

        // client.rs:4202-4209 — two Fireworks permits exhaust the gate.
        let first = try #require(
            try await acquireProviderRequestPermit(provider: .fireworks, gate: gate)
        )
        let second = try #require(
            try await acquireProviderRequestPermit(provider: .fireworks, gate: gate)
        )
        #expect(await gate.availablePermits == 0)

        // client.rs:4211-4217 — a third Fireworks request must wait.
        let third = Task {
            try await acquireProviderRequestPermit(provider: .fireworks, gate: gate)
        }
        #expect(await pollUntil { await gate.waiterCount == 1 })
        #expect(await gate.availablePermits == 0)

        // client.rs:4219-4227 — releasing a permit wakes the waiter.
        first.release()
        let woken = try await third.value
        #expect(woken != nil)
        #expect(await gate.waiterCount == 0)

        second.release()
        woken?.release()
        #expect(await pollUntil {
            await gate.availablePermits == FIREWORKS_MAX_CONCURRENT_REQUESTS
        })
    }

    /// Live-seam bypass proof: the injected gate has ZERO permits, so any
    /// acquisition on the xAI request path would park forever. The request
    /// completing at all is the proof that non-Fireworks providers never
    /// touch the gate (client.rs:74-76).
    @Test("a non-Fireworks request never touches the gate")
    func nonFireworksRequestsBypassTheGate() async throws {
        let sealed = RequestPacingSemaphore(permits: 0)
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([chunkJSON])
            ),
        ])
        let client = try SamplingClient(
            config: SamplerConfig(
                apiKey: "test-key",
                baseURL: "https://api.example.test",
                model: "test-model",
                apiBackend: .chatCompletions,
                provider: .xai
            ),
            transport: transport
        )
        client.providerRequestGate = sealed

        let response = try await client.conversationCollect(
            ConversationRequest(items: [.user("hello")]),
            idleTimeout: .seconds(30)
        )
        #expect(response.assistantText() == "Hi")
        #expect(await sealed.waiterCount == 0)
    }

    /// The M-sized question of this slice: the permit must span the returned
    /// stream's whole lifetime — held while the stream is alive, released
    /// exactly once when it drains (client.rs:2097-2100 moves the permit into
    /// the stream closure so it drops with the stream).
    @Test("the permit is held across the stream and released on drain")
    func permitSpansStreamAndReleasesOnDrain() async throws {
        let gate = RequestPacingSemaphore(permits: 2)
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([chunkJSON])
            ),
        ])
        let client = try fireworksClient(transport: transport, gate: gate)

        let (stream, _) = try await client.conversationStream(
            ConversationRequest(items: [.user("hello")])
        )
        // Acquisition happens inline before `conversationStream` returns, so
        // this observation is deterministic, not a poll.
        #expect(await gate.availablePermits == 1)

        var chunks = 0
        for await result in stream {
            if case .success = result { chunks += 1 }
        }
        #expect(chunks == 1)
        #expect(await pollUntil { await gate.availablePermits == 2 })
    }

    /// Dropping the stream without consuming it must also release — that is
    /// the "until the response stream drops" half of upstream's semantics,
    /// covering consumers that abandon a response mid-flight.
    @Test("dropping an unconsumed stream releases the permit")
    func droppingUnconsumedStreamReleases() async throws {
        let gate = RequestPacingSemaphore(permits: 2)
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([chunkJSON])
            ),
        ])
        let client = try fireworksClient(transport: transport, gate: gate)

        do {
            let (stream, _) = try await client.conversationStream(
                ConversationRequest(items: [.user("hello")])
            )
            #expect(await gate.availablePermits == 1)
            _ = stream
        }
        // The stream deallocated unconsumed; its termination handler must
        // have returned the permit.
        #expect(await pollUntil { await gate.availablePermits == 2 })
    }

    /// A request that fails before any stream exists (non-2xx) has no
    /// termination handler to release through; the error path must release.
    /// Upstream gets this from RAII on the early `?` returns after the
    /// client.rs:1937 binding.
    @Test("a failed request releases the permit")
    func failedRequestReleases() async throws {
        let gate = RequestPacingSemaphore(permits: 2)
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 500, headers: [:]),
                body: Data(#"{"error":{"message":"transient","type":"server_error"}}"#.utf8)
            ),
        ])
        let client = try fireworksClient(transport: transport, gate: gate)

        await #expect(throws: SamplingError.self) {
            _ = try await client.conversationStream(
                ConversationRequest(items: [.user("hello")])
            )
        }
        #expect(await pollUntil { await gate.availablePermits == 2 })
        #expect(await gate.waiterCount == 0)
    }

    /// Cancellation semantics the port had to make explicit (tokio gets them
    /// from dropping the acquire future): a cancelled parked waiter throws,
    /// consumes no permit, leaves the queue, and cannot eat a later release.
    /// The double-release arm rides the permit's exactly-once guard — a
    /// second `release()` is a no-op, and a real double-release would trap
    /// the gate's over-release precondition and fail this test loudly.
    @Test("a cancelled waiter neither deadlocks the gate nor double-releases")
    func cancelledWaiterIsSafe() async throws {
        let gate = RequestPacingSemaphore(permits: 2)
        let first = try #require(
            try await acquireProviderRequestPermit(provider: .fireworks, gate: gate)
        )
        let second = try #require(
            try await acquireProviderRequestPermit(provider: .fireworks, gate: gate)
        )

        let parked = Task {
            try await acquireProviderRequestPermit(provider: .fireworks, gate: gate)
        }
        #expect(await pollUntil { await gate.waiterCount == 1 })

        parked.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await parked.value
        }
        #expect(await pollUntil { await gate.waiterCount == 0 })
        // The cancelled waiter consumed nothing…
        #expect(await gate.availablePermits == 0)

        // …and does not swallow the next release: the permit becomes
        // available instead of waking a ghost.
        first.release()
        #expect(await pollUntil { await gate.availablePermits == 1 })

        // The gate still serves: a fresh acquire takes the freed permit.
        let next = try #require(
            try await acquireProviderRequestPermit(provider: .fireworks, gate: gate)
        )
        #expect(await gate.availablePermits == 0)

        second.release()
        next.release()
        #expect(await pollUntil { await gate.availablePermits == 2 })

        // Double release of an already-released permit is a guarded no-op:
        // capacity stays 2 (a leak past the guard would trap the gate's
        // precondition here).
        first.release()
        second.release()
        #expect(await gate.availablePermits == 2)
    }
}
