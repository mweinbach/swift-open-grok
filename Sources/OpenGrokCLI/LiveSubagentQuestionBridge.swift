import Foundation
import OpenGrokAgentCoordinator
import OpenGrokConfig
import OpenGrokFileTools
import OpenGrokModels
import OpenGrokPagerRender
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokToolRegistry
import OpenGrokWorkspaceTypes

/// Resolve the already-trusted root session's questionnaire budget. A
/// disabled upstream timer still retains a one-day child-session ceiling: a
/// delegated tool must not outlive its authenticated root indefinitely.
enum LiveSubagentQuestionTimeout {
    static let defaultSeconds: UInt64 = 30 * 60
    static let maximumSeconds: UInt64 = 24 * 60 * 60

    static func resolve(
        security: LiveSecurityContext,
        environment: [String: String]
    ) -> UInt64 {
        let enabledPath = ["toolset", "ask_user_question", "timeout_enabled"]
        let secondsPath = ["toolset", "ask_user_question", "timeout_secs"]

        let requiredEnabled = security.requirements.compactMap {
            $0[path: enabledPath]?.boolValue
        }.first
        let environmentEnabled: Bool?
        switch environment["GROK_ASK_USER_QUESTION_TIMEOUT_ENABLED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "1", "true": environmentEnabled = true
        case "0", "false": environmentEnabled = false
        default: environmentEnabled = nil
        }
        let enabled = requiredEnabled
            ?? environmentEnabled
            ?? security.document[path: enabledPath]?.boolValue
            ?? true
        guard enabled else { return maximumSeconds }

        let requiredSeconds = security.requirements.compactMap { requirement -> UInt64? in
            guard let value = requirement[path: secondsPath]?.int64Value, value > 0 else {
                return nil
            }
            return UInt64(value)
        }.first
        let environmentSeconds = environment["GROK_ASK_USER_QUESTION_TIMEOUT_SECS"]
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0 > 0 ? $0 : nil }
        let configuredSeconds = security.document[path: secondsPath]?.int64Value
            .flatMap { $0 > 0 ? UInt64($0) : nil }
        return min(
            requiredSeconds ?? environmentSeconds ?? configuredSeconds ?? defaultSeconds,
            maximumSeconds
        )
    }
}

/// Exactly-once completion lets the child return at its deadline even if a
/// renderer, coordinator, or cancellation callback races the user's answer.
private final class LiveSubagentQuestionOutcomeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UserQuestionPromptOutcome, Never>?
    private var outcome: UserQuestionPromptOutcome?

    func wait() async -> UserQuestionPromptOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: UserQuestionPromptOutcome) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

/// A root pager capability restricted to one currently registered child.
/// Neither matching strings nor an inherited permission handle alone grants
/// access: every dispatch revalidates the coordinator-owned family identity.
struct LiveSubagentQuestionBridge: ScopedUserQuestionPresenting {
    let coordinator: PagerQuestionCoordinator
    let children: OpenGrokAgentCoordinator
    let parentSessionID: String
    let childSessionID: String
    let timeoutSeconds: UInt64

    var canPresent: Bool {
        get async {
            guard await coordinator.hasPresenter else { return false }
            return await hasAuthenticatedOwner
        }
    }

    func authorizeQuestion(
        sessionID: String,
        authorizationSessionID: String,
        agentID: String,
        toolCallID: String
    ) async -> Bool {
        guard sessionID == childSessionID,
              authorizationSessionID == parentSessionID,
              agentID == "main",
              !toolCallID.isEmpty,
              toolCallID.count <= 512,
              !toolCallID.contains(where: \.isNewline),
              await coordinator.hasPresenter
        else { return false }
        return await hasAuthenticatedOwner
    }

    private var hasAuthenticatedOwner: Bool {
        get async {
            let active = await children.listActive(parentSessionID: parentSessionID)
            return active.contains {
                $0.request.id == childSessionID
                    && $0.request.parentSessionID == parentSessionID
                    && $0.request.owner != .antigravity
            }
        }
    }

    func ask(
        questions: [UserQuestion],
        toolCallID: String
    ) async -> UserQuestionPromptOutcome {
        guard !Task.isCancelled,
              await authorizeQuestion(
                sessionID: childSessionID,
                authorizationSessionID: parentSessionID,
                agentID: "main",
                toolCallID: toolCallID
              )
        else { return .cancelled }

        let request = PagerQuestionRequest(
            toolCallID: "\(childSessionID):\(toolCallID)",
            questions: questions.map { question in
                PagerQuestion(
                    text: question.question,
                    options: question.options.map { option in
                        PagerQuestionOption(
                            label: option.label,
                            description: option.description,
                            preview: option.preview
                        )
                    },
                    isMultiSelect: question.multiSelect
                )
            }
        )
        let latch = LiveSubagentQuestionOutcomeLatch()
        let presentation = Task { [coordinator] in
            let outcome = await coordinator.answers(for: request)
            switch outcome {
            case .answered(let answers):
                latch.resolve(.answered(answers.compactMap { answer in
                    guard let first = answer.labels.first else { return nil }
                    return AnsweredUserQuestion(
                        question: answer.question,
                        label: first,
                        extraLabels: Array(answer.labels.dropFirst()),
                        notes: answer.notes
                    )
                }))
            case .cancelled:
                latch.resolve(.cancelled)
            }
        }
        let timeout = Task { [coordinator] in
            do {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            } catch {
                return
            }
            await coordinator.resolve(requestID: request.id, outcome: .cancelled)
            latch.resolve(.cancelled)
        }

        let outcome = await withTaskCancellationHandler {
            await latch.wait()
        } onCancel: { [coordinator] in
            Task {
                await coordinator.resolve(requestID: request.id, outcome: .cancelled)
                latch.resolve(.cancelled)
            }
        }
        timeout.cancel()
        presentation.cancel()
        return outcome
    }
}

/// The scheduler-facing waiting/retrying transitions emitted by actual child
/// provider failures (`task/types.rs:85-103`). Kept provider-scoped so one
/// provider's 429 cannot throttle another provider's authenticated transport.
struct LiveSwarmRetryStatus: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case waiting
        case retrying
    }

    var childID: String
    var provider: ModelProvider
    var attempt: UInt32
    var delayMilliseconds: UInt64
    var phase: Phase
}

/// Adaptive provider-local concurrency gate. Existing requests finish; after
/// a 429, fresh attempts narrow to half the observed concurrency and recover
/// one permit at a time after successful responses.
actor LiveSwarmAdaptiveRequestGate {
    private struct ProviderState {
        var active = 0
        var capacity: Int?
    }

    private var states: [ModelProvider: ProviderState] = [:]

    func acquire(provider: ModelProvider) async throws {
        while true {
            try Task.checkCancellation()
            var state = states[provider, default: ProviderState()]
            if state.capacity.map({ state.active < $0 }) ?? true {
                state.active += 1
                states[provider] = state
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func release(provider: ModelProvider, rateLimited: Bool) {
        var state = states[provider, default: ProviderState()]
        let observedConcurrency = max(state.active, 1)
        state.active = max(0, state.active - 1)
        if rateLimited {
            let reduced = max(1, observedConcurrency / 2)
            state.capacity = min(state.capacity ?? observedConcurrency, reduced)
        } else if let capacity = state.capacity {
            state.capacity = capacity >= 32 ? nil : capacity + 1
        }
        states[provider] = state
    }
}

/// A backend tool starting is already a remote side effect, even though the
/// parent has not rendered any child output. Retrying it could duplicate work.
actor LiveSubagentSamplingReplayBoundary {
    private(set) var replayUnsafe = false

    func observe(_ event: OpenGrokLiveSamplingEvent) {
        switch event {
        case .output(let text), .reasoning(let text):
            replayUnsafe = replayUnsafe || !text.isEmpty
        case .backendToolCallStarted, .backendToolCallCompleted:
            replayUnsafe = true
        default:
            break
        }
    }
}

extension LiveSubagentHost {
    static let maximumSwarmRateLimitRetries: UInt32 = 3

    /// Rust `task/types.rs:77-83`: 3, 6, 12, 24 seconds, with saturating
    /// arithmetic. The bounded child policy caps a server-provided delay at
    /// 30 seconds so cancellation and foreground orchestration stay prompt.
    static func swarmRateLimitBackoffMilliseconds(
        attempt: UInt32,
        retryAfterSeconds: UInt64? = nil
    ) -> UInt64 {
        let exponent = min(attempt.saturatingSubtracting(1), 63)
        let multiplier = UInt64(1) << exponent
        let multiplied = UInt64(3_000).multipliedReportingOverflow(by: multiplier)
        let exponential = multiplied.overflow ? UInt64.max : multiplied.partialValue
        let hinted: UInt64
        if let retryAfterSeconds {
            let milliseconds = retryAfterSeconds.multipliedReportingOverflow(by: 1_000)
            hinted = milliseconds.overflow ? UInt64.max : milliseconds.partialValue
        } else {
            hinted = 0
        }
        return min(max(exponential, hinted), 30_000)
    }

    private struct SwarmRateLimitFailure {
        var retryAfterSeconds: UInt64?
    }

    private static func swarmRateLimitFailure(_ error: any Error) -> SwarmRateLimitFailure? {
        if let failure = error as? SamplingErrorInfo,
           failure.kind == .rateLimited || failure.statusCode == 429 {
            return SwarmRateLimitFailure(retryAfterSeconds: failure.retryAfterSecs)
        }
        if let failure = error as? SamplingError, failure.isRateLimited {
            return SwarmRateLimitFailure(retryAfterSeconds: failure.retryAfter)
        }
        return nil
    }

    private func hasOtherUnfinishedSwarmMembers() -> Bool {
        swarmRegistry.transcriptSnapshots(parentSessionID: context.sessionID)
            .filter(\.isActive)
            .contains { snapshot in
                snapshot.slots.filter { $0 == nil }.count > 1
            }
    }

    func sampleChildWithSwarmRetries(
        _ request: OpenGrokLiveSamplingRequest,
        route: ChildSamplerRoute,
        childID: String,
        swarmOwned: Bool,
        replayAllowed: Bool
    ) async throws -> OpenGrokLiveSamplingResponse {
        var attempt: UInt32 = 0
        while true {
            try Task.checkCancellation()
            if swarmOwned {
                try await swarmRequestGate.acquire(provider: route.provider)
            }
            let replayBoundary = LiveSubagentSamplingReplayBoundary()
            do {
                let response = try await route.sampler.sample(request) { event in
                    await replayBoundary.observe(event)
                }
                if swarmOwned {
                    await swarmRequestGate.release(provider: route.provider, rateLimited: false)
                }
                return response
            } catch {
                let rateLimit = Self.swarmRateLimitFailure(error)
                if swarmOwned {
                    await swarmRequestGate.release(
                        provider: route.provider,
                        rateLimited: rateLimit != nil
                    )
                }
                guard swarmOwned,
                      replayAllowed,
                      let rateLimit,
                      !(await replayBoundary.replayUnsafe),
                      attempt < Self.maximumSwarmRateLimitRetries,
                      hasOtherUnfinishedSwarmMembers()
                else { throw error }

                attempt += 1
                let delay = Self.swarmRateLimitBackoffMilliseconds(
                    attempt: attempt,
                    retryAfterSeconds: rateLimit.retryAfterSeconds
                )
                let waiting = LiveSwarmRetryStatus(
                    childID: childID,
                    provider: route.provider,
                    attempt: attempt,
                    delayMilliseconds: delay,
                    phase: .waiting
                )
                await context.swarmRetryStatusSink?(waiting)
                if let sleeper = context.swarmRetrySleeper {
                    try await sleeper(delay)
                } else {
                    try await Task.sleep(nanoseconds: delay * 1_000_000)
                }
                try Task.checkCancellation()
                var retrying = waiting
                retrying.phase = .retrying
                await context.swarmRetryStatusSink?(retrying)
            }
        }
    }
}

private extension UInt32 {
    func saturatingSubtracting(_ value: UInt32) -> UInt32 {
        self >= value ? self - value : 0
    }
}
