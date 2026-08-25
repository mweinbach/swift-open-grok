import Foundation
import OpenGrokAgentDefinitions
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

@testable import OpenGrokCLI

private enum LiveSwarmRetryFailureMode: Sendable {
    case typedRateLimit(failures: Int)
    case rawRateLimit
    case visibleOutput
    case backendSideEffect
    case afterToolCall
    case unrelatedFailure
}

private actor LiveSwarmRetryProbe {
    private let mode: LiveSwarmRetryFailureMode
    private var requests: [OpenGrokLiveSamplingRequest] = []

    init(mode: LiveSwarmRetryFailureMode) {
        self.mode = mode
    }

    func sample(
        _ request: OpenGrokLiveSamplingRequest,
        emit: @escaping OpenGrokLiveSampler.Emit
    ) async throws -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        guard request.prompt.contains("alpha") else {
            try await Task.sleep(nanoseconds: 50_000_000)
            return OpenGrokLiveSamplingResponse(output: "completed \(request.prompt)")
        }

        let attempts = requests.filter { $0.sessionID == request.sessionID }.count
        switch mode {
        case .typedRateLimit(let failures) where attempts <= failures:
            throw SamplingErrorInfo(
                kind: .rateLimited,
                statusCode: 429,
                message: "provider rate limited this real child",
                isRetryable: true
            )
        case .rawRateLimit where attempts == 1:
            throw SamplingError.api(
                status: HTTPStatus(429),
                message: "provider rate limited this real child",
                modelMetadata: nil,
                retryAfterSecs: nil,
                shouldRetry: true
            )
        case .visibleOutput where attempts == 1:
            await emit(.output("already visible partial output"))
            throw Self.rateLimit
        case .backendSideEffect where attempts == 1:
            await emit(.backendToolCallStarted(callId: "remote-call", name: "web_search"))
            throw Self.rateLimit
        case .afterToolCall where attempts == 1:
            return OpenGrokLiveSamplingResponse(
                output: "",
                toolCalls: [ToolCall(
                    id: "already-executed-tool",
                    name: "missing_child_tool",
                    arguments: "{}"
                )]
            )
        case .afterToolCall where attempts == 2:
            throw Self.rateLimit
        case .unrelatedFailure where attempts == 1:
            throw SamplingError.api(
                status: HTTPStatus(503),
                message: "service unavailable",
                modelMetadata: nil,
                retryAfterSecs: nil,
                shouldRetry: true
            )
        default:
            return OpenGrokLiveSamplingResponse(output: "completed \(request.prompt)")
        }
    }

    private static var rateLimit: SamplingErrorInfo {
        SamplingErrorInfo(
            kind: .rateLimited,
            statusCode: 429,
            message: "provider rate limited this real child",
            isRetryable: true
        )
    }

    func alphaRequests() -> [OpenGrokLiveSamplingRequest] {
        requests.filter { $0.prompt.contains("alpha") }
    }
}

private actor LiveSwarmRetryObserver {
    private(set) var delays: [UInt64] = []
    private(set) var statuses: [LiveSwarmRetryStatus] = []

    func delay(_ value: UInt64) { delays.append(value) }
    func status(_ value: LiveSwarmRetryStatus) { statuses.append(value) }
}

@Suite("Adaptive swarm rate-limit parity", .serialized)
struct LiveSwarmRetryParityTests {
    private func fixture(
        mode: LiveSwarmRetryFailureMode
    ) async throws -> (
        fixture: LiveDelegatedParityFixture,
        probe: LiveSwarmRetryProbe,
        observer: LiveSwarmRetryObserver
    ) {
        let probe = LiveSwarmRetryProbe(mode: mode)
        let observer = LiveSwarmRetryObserver()
        let fixture = try await LiveDelegatedParityFixture(
            sampler: OpenGrokLiveSampler { request, emit in
                try await probe.sample(request, emit: emit)
            },
            swarmRetrySleeper: { await observer.delay($0) },
            swarmRetryStatusSink: { await observer.status($0) }
        )
        return (fixture, probe, observer)
    }

    private func run(_ fixture: LiveDelegatedParityFixture) async -> String? {
        let result = await fixture.host.runSwarm(
            args: .object([
                "description": .string("adaptive provider retry parity"),
                "subagent_type": .string("general-purpose"),
                "prompt_template": .string("investigate {{item}}"),
                "items": .array([.string("alpha"), .string("beta")]),
            ]),
            toolCallID: "swarm-retry-call"
        )
        guard case .success(let output) = result else {
            Issue.record("real swarm invocation failed: \(result)")
            return nil
        }
        return output.promptText
    }

    @Test("pinned Rust exponential delays are preserved and hostile server hints are bounded")
    func pinnedBackoffSchedule() {
        #expect(LiveSubagentHost.swarmRateLimitBackoffMilliseconds(attempt: 1) == 3_000)
        #expect(LiveSubagentHost.swarmRateLimitBackoffMilliseconds(attempt: 2) == 6_000)
        #expect(LiveSubagentHost.swarmRateLimitBackoffMilliseconds(attempt: 3) == 12_000)
        #expect(LiveSubagentHost.swarmRateLimitBackoffMilliseconds(attempt: 4) == 24_000)
        #expect(LiveSubagentHost.swarmRateLimitBackoffMilliseconds(
            attempt: UInt32.max,
            retryAfterSeconds: UInt64.max
        ) == 30_000)
    }

    @Test("a real swarm child retries a typed 429 on its identical provider request")
    func typedRateLimitRetriesSameChildRequest() async throws {
        let (fixture, probe, observer) = try await fixture(mode: .typedRateLimit(failures: 1))
        defer { Task { await fixture.dispose() } }
        let output = await run(fixture)
        #expect(output?.contains("<summary>completed=2 failed=0 aborted=0</summary>") == true)

        let requests = await probe.alphaRequests()
        #expect(requests.count == 2)
        if requests.count == 2 {
            #expect(requests[0].sessionID == requests[1].sessionID)
            #expect(requests[0].model == requests[1].model)
            #expect(requests[0].turnID == requests[1].turnID)
            #expect(requests[0].maxOutputTokens == requests[1].maxOutputTokens)
            #expect(requests[0].retryOnlyBeforeOutput)
            #expect(requests[1].retryOnlyBeforeOutput)
        }
        #expect(await observer.delays == [3_000])
        let statuses = await observer.statuses
        #expect(statuses.map(\.phase) == [.waiting, .retrying])
        #expect(statuses.allSatisfy { $0.provider == .xai && $0.attempt == 1 })
    }

    @Test("the raw transport's 429 remains eligible for the same bounded retry")
    func rawRateLimitRetries() async throws {
        let (fixture, probe, observer) = try await fixture(mode: .rawRateLimit)
        defer { Task { await fixture.dispose() } }
        let output = await run(fixture)
        #expect(output?.contains("completed=2 failed=0") == true)
        #expect(await probe.alphaRequests().count == 2)
        #expect(await observer.delays == [3_000])
    }

    @Test("retries stop after the configured child-local maximum")
    func repeatedRateLimitsRemainBounded() async throws {
        let (fixture, probe, observer) = try await fixture(mode: .typedRateLimit(failures: 12))
        defer { Task { await fixture.dispose() } }
        let unfinishedSiblingCohort = DetachedSwarm(
            swarmID: "other-unfinished-cohort",
            description: "another authenticated unfinished root cohort",
            parentSessionID: "delegation-parent",
            expectedMembers: 2
        )
        fixture.host.swarmRegistry.insert(unfinishedSiblingCohort)
        defer { fixture.host.swarmRegistry.remove("other-unfinished-cohort") }

        let output = await run(fixture)
        #expect(output?.contains("completed=1 failed=1") == true)
        #expect(await probe.alphaRequests().count == 4)
        #expect(await observer.delays == [3_000, 6_000, 12_000])
    }

    @Test("already streamed visible output is never replayed")
    func visibleOutputBlocksReplay() async throws {
        let (fixture, probe, observer) = try await fixture(mode: .visibleOutput)
        defer { Task { await fixture.dispose() } }
        let output = await run(fixture)
        #expect(output?.contains("completed=1 failed=1") == true)
        #expect(await probe.alphaRequests().count == 1)
        #expect(await observer.delays.isEmpty)
    }

    @Test("provider-executed tools are irrevocable even without visible text")
    func hostedToolSideEffectBlocksReplay() async throws {
        let (fixture, probe, observer) = try await fixture(mode: .backendSideEffect)
        defer { Task { await fixture.dispose() } }
        let output = await run(fixture)
        #expect(output?.contains("completed=1 failed=1") == true)
        #expect(await probe.alphaRequests().count == 1)
        #expect(await observer.delays.isEmpty)
    }

    @Test("a prior dispatched tool prevents replay of every later child round")
    func priorToolDispatchBlocksReplay() async throws {
        let (fixture, probe, observer) = try await fixture(mode: .afterToolCall)
        defer { Task { await fixture.dispose() } }
        let output = await run(fixture)
        #expect(output?.contains("completed=1 failed=1") == true)
        #expect(await probe.alphaRequests().count == 2)
        #expect(await observer.delays.isEmpty)
    }

    @Test("non-rate-limit server failures never enter the adaptive retry path")
    func unrelatedFailureIsNotRetried() async throws {
        let (fixture, probe, observer) = try await fixture(mode: .unrelatedFailure)
        defer { Task { await fixture.dispose() } }
        let output = await run(fixture)
        #expect(output?.contains("completed=1 failed=1") == true)
        #expect(await probe.alphaRequests().count == 1)
        #expect(await observer.delays.isEmpty)
    }

    @Test("adaptive throttling never transfers a 429 across provider boundaries")
    func adaptiveGateIsProviderScoped() async throws {
        let gate = LiveSwarmAdaptiveRequestGate()
        try await gate.acquire(provider: .xai)
        await gate.release(provider: .xai, rateLimited: true)
        try await gate.acquire(provider: .xai)
        try await gate.acquire(provider: .codex)
        await gate.release(provider: .codex, rateLimited: false)
        await gate.release(provider: .xai, rateLimited: false)
    }
}
