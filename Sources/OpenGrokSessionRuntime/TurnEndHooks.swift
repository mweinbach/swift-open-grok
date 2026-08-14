// TurnEndHooks.swift
//
// Reports `StopFailure` and `StopCancelled`, the two turn-end hooks that run instead of `Stop`.
// A reporter claims the turn's one report and hands the payload to a background worker, so an
// interrupt cannot abort a hook already running.
// Ported from `crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn_end_hooks.rs`.

import Foundation
import OpenGrokShared

/// This path's slice of the session's ten-second exit budget, spent twice per teardown:
/// once by `flush` and once by `drain`.
public let TURN_END_DRAIN_BUDGET: TimeInterval = 0.25 // 250ms
public let TURN_END_DRAIN_BUDGET_MS: UInt64 = 250

/// Max characters for `StopBackgroundTask`/`StopSessionCron` entries, `StopFailure`'s
/// `errorDetails`, and `StopCancelled`'s `reasonDetails`.
public let MAX_STOP_ENTRY_TEXT_CHARS: Int = 1000

/// Cancel triggers are short tokens.
public let MAX_CANCEL_TRIGGER_CHARS: Int = 64

/// Maximum assistant message characters in hook payloads.
public let MAX_ASSISTANT_MESSAGE_CHARS: Int = 32_768

/// Clips text to `max` characters (on Character boundary) with a `… [+N chars]` marker if truncated.
public func clipText(_ text: String, max: Int) -> String {
    if text.count <= max {
        return text
    }
    let clipped = String(text.prefix(max))
    let remaining = text.count - max
    return "\(clipped)… [+\(remaining) chars]"
}

public func clipStopEntryText(_ text: String) -> String {
    clipText(text, max: MAX_STOP_ENTRY_TEXT_CHARS)
}

public func clipAssistantMessage(_ text: String) -> String {
    clipText(text, max: MAX_ASSISTANT_MESSAGE_CHARS)
}

/// `StopFailure` error kind.
public enum StopFailureKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case rateLimit = "rate_limit"
    case authenticationFailed = "authentication_failed"
    case invalidRequest = "invalid_request"
    case serverError = "server_error"
    case maxOutputTokens = "max_output_tokens"
    case unknown = "unknown"
}

/// `StopCancelled` reason.
public enum StopCancelledReason: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case userInterrupt = "user_interrupt"
    case permissionRejected = "permission_rejected"
    case permissionCancelled = "permission_cancelled"
    case maxTurns = "max_turns"
    case noProgress = "no_progress"
    case unknown = "unknown"

    public var cancelledBy: CancelledBy {
        switch self {
        case .userInterrupt, .permissionRejected, .permissionCancelled:
            return .user
        case .maxTurns, .noProgress:
            return .runtime
        case .unknown:
            return .unknown
        }
    }
}

/// Who initiated the cancellation.
public enum CancelledBy: String, Sendable, Equatable, Hashable, Codable {
    case user = "user"
    case runtime = "runtime"
    case unknown = "unknown"
}

/// Turn end hook event name.
public enum TurnEndEventName: String, Sendable, Equatable, Hashable, Codable {
    case stopFailure = "stop_failure"
    case stopCancelled = "stop_cancelled"
}

/// Turn-end payload sent to hooks.
public enum TurnEndPayload: Sendable, Equatable, Codable {
    case stopFailure(
        error: StopFailureKind,
        errorDetails: String?,
        lastAssistantMessage: String?,
        subagentType: String?
    )
    case stopCancelled(
        reason: StopCancelledReason,
        cancelledBy: CancelledBy,
        cancelTrigger: String?,
        reasonDetails: String?,
        lastAssistantMessage: String?,
        subagentType: String?
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case error
        case errorDetails
        case reason
        case cancelledBy
        case cancelTrigger
        case reasonDetails
        case lastAssistantMessage
        case subagentType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let error = try container.decodeIfPresent(StopFailureKind.self, forKey: .error) {
            let errorDetails = try container.decodeIfPresent(String.self, forKey: .errorDetails)
            let lastMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
            let subagent = try container.decodeIfPresent(String.self, forKey: .subagentType)
            self = .stopFailure(error: error, errorDetails: errorDetails, lastAssistantMessage: lastMessage, subagentType: subagent)
        } else if let reason = try container.decodeIfPresent(StopCancelledReason.self, forKey: .reason) {
            let cancelledBy = try container.decode(CancelledBy.self, forKey: .cancelledBy)
            let cancelTrigger = try container.decodeIfPresent(String.self, forKey: .cancelTrigger)
            let reasonDetails = try container.decodeIfPresent(String.self, forKey: .reasonDetails)
            let lastMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
            let subagent = try container.decodeIfPresent(String.self, forKey: .subagentType)
            self = .stopCancelled(
                reason: reason,
                cancelledBy: cancelledBy,
                cancelTrigger: cancelTrigger,
                reasonDetails: reasonDetails,
                lastAssistantMessage: lastMessage,
                subagentType: subagent
            )
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown TurnEndPayload")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stopFailure(let error, let errorDetails, let lastMessage, let subagent):
            try container.encode(error, forKey: .error)
            try container.encodeIfPresent(errorDetails, forKey: .errorDetails)
            try container.encodeIfPresent(lastMessage, forKey: .lastAssistantMessage)
            try container.encodeIfPresent(subagent, forKey: .subagentType)
        case .stopCancelled(let reason, let cancelledBy, let cancelTrigger, let reasonDetails, let lastMessage, let subagent):
            try container.encode(reason, forKey: .reason)
            try container.encode(cancelledBy, forKey: .cancelledBy)
            try container.encodeIfPresent(cancelTrigger, forKey: .cancelTrigger)
            try container.encodeIfPresent(reasonDetails, forKey: .reasonDetails)
            try container.encodeIfPresent(lastMessage, forKey: .lastAssistantMessage)
            try container.encodeIfPresent(subagent, forKey: .subagentType)
        }
    }
}

/// Turn-end description before dispatch.
public enum TurnEnd: Sendable, Equatable {
    case failed(
        error: StopFailureKind,
        errorDetails: String?,
        lastAssistantMessage: String?
    )
    case cancelled(
        reason: StopCancelledReason,
        trigger: String?,
        reasonDetails: String?,
        lastAssistantMessage: String?
    )

    public var eventName: TurnEndEventName {
        switch self {
        case .failed: return .stopFailure
        case .cancelled: return .stopCancelled
        }
    }

    public var isUserInterrupt: Bool {
        if case .cancelled(let reason, _, _, _) = self, reason == .userInterrupt {
            return true
        }
        return false
    }

    public func intoPayload(subagentType: String? = nil) -> TurnEndPayload {
        switch self {
        case .failed(let error, let errorDetails, let lastMessage):
            return .stopFailure(
                error: error,
                errorDetails: errorDetails.map(clipStopEntryText),
                lastAssistantMessage: lastMessage.map(clipAssistantMessage),
                subagentType: subagentType
            )
        case .cancelled(let reason, let trigger, let reasonDetails, let lastMessage):
            return .stopCancelled(
                reason: reason,
                cancelledBy: reason.cancelledBy,
                cancelTrigger: trigger.map { clipText($0, max: MAX_CANCEL_TRIGGER_CHARS) },
                reasonDetails: reasonDetails.map(clipStopEntryText),
                lastAssistantMessage: lastMessage.map(clipAssistantMessage),
                subagentType: subagentType
            )
        }
    }
}

/// Outcome of attempting to report turn-end.
public enum ReportOutcome: Sendable, Equatable, Hashable {
    case queued
    case inheritedInterrupt
    case noListener
    case alreadyReported
    case queueClosed
}

/// Queued report item ready for hook dispatch.
public struct TurnEndReport: Sendable, Equatable {
    public let promptID: String
    public let event: TurnEndEventName
    public let payload: TurnEndPayload

    public init(promptID: String, event: TurnEndEventName, payload: TurnEndPayload) {
        self.promptID = promptID
        self.event = event
        self.payload = payload
    }
}

// MARK: - Cancellation Classification

public enum CancelKind: Sendable, Equatable, Hashable {
    case stopGesture
    case replace
    case teardown
}

public enum CancelTrigger: Sendable, Equatable, Hashable {
    case ctrlC
    case esc
    case client(String)
    case sendNow
    case shutdown
    case sessionClose
    case sessionDelete

    public var kind: CancelKind {
        switch self {
        case .ctrlC, .esc, .client:
            return .stopGesture
        case .sendNow:
            return .replace
        case .shutdown, .sessionClose, .sessionDelete:
            return .teardown
        }
    }
}

public struct CancelOptions: Sendable, Equatable, Hashable {
    public var trigger: CancelTrigger?
    public var userInitiated: Bool

    public init(trigger: CancelTrigger? = nil, userInitiated: Bool = false) {
        self.trigger = trigger
        self.userInitiated = userInitiated
    }
}

public func cancelReasonForOptions(_ options: CancelOptions) -> StopCancelledReason? {
    if let trigger = options.trigger {
        switch trigger.kind {
        case .stopGesture:
            return .userInterrupt
        case .replace, .teardown:
            return nil
        }
    }
    if options.userInitiated {
        return .userInterrupt
    }
    return nil
}

public enum CancellationCategory: Sendable, Equatable, Hashable {
    case permissionRejected
    case permissionCancelled
    case midTurnAbort
    case hookDenied
}

public struct CancellationContext: Sendable, Equatable, Hashable {
    public var toolName: String?
    public var hookName: String?
    public var reason: String?
    public var trigger: String?

    public init(
        toolName: String? = nil,
        hookName: String? = nil,
        reason: String? = nil,
        trigger: String? = nil
    ) {
        self.toolName = toolName
        self.hookName = hookName
        self.reason = reason
        self.trigger = trigger
    }
}

public enum PromptCompletionKind: Sendable, Equatable {
    case completed
    case cancelled(category: CancellationCategory?, context: CancellationContext? = nil)
    case maxTurnsReached(limit: Int)
    case stationarityEnded
    case rewound
    case removedFromQueue
}

public func cancelReasonForCompletion(_ kind: PromptCompletionKind) -> StopCancelledReason? {
    switch kind {
    case .cancelled(let category, _):
        switch category {
        case .permissionRejected:
            return .permissionRejected
        case .permissionCancelled:
            return .permissionCancelled
        case .midTurnAbort:
            return .userInterrupt
        case .hookDenied, .none:
            return .unknown
        }
    case .maxTurnsReached:
        return .maxTurns
    case .stationarityEnded:
        return .noProgress
    case .completed, .rewound, .removedFromQueue:
        return nil
    }
}

public func cancelDetails(_ kind: PromptCompletionKind) -> String? {
    guard case .cancelled(_, let context) = kind, let ctx = context else {
        return nil
    }
    let subject = ctx.toolName ?? ctx.hookName
    switch (subject, ctx.reason) {
    case (let sub?, let reason?):
        return "\(sub): \(reason)"
    case (let sub?, nil):
        return sub
    case (nil, let reason?):
        return reason
    case (nil, nil):
        return nil
    }
}

// MARK: - Turn Report Slot & Epoch Tracking

public struct TurnEpoch: Sendable, Equatable, Comparable, Hashable {
    public var value: UInt64

    public init(_ value: UInt64 = 0) {
        self.value = value
    }

    public static func < (lhs: TurnEpoch, rhs: TurnEpoch) -> Bool {
        lhs.value < rhs.value
    }
}

public enum ClaimKind: Sendable, Equatable {
    case gate
    case report
}

public enum TurnReportState: Sendable, Equatable {
    case free
    case held(claim: UInt64, kind: ClaimKind)
    case reported
}

public enum CommitOutcome: Sendable, Equatable {
    case reported
    case lostToAnotherReporter
}

public final class TurnReportSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var state: TurnReportState = .free
    private var currentEpoch: TurnEpoch = TurnEpoch(0)
    private var nextClaim: UInt64 = 0

    public init() {}

    public var epoch: TurnEpoch {
        lock.lock()
        defer { lock.unlock() }
        return currentEpoch
    }

    public func claimAt(epoch: TurnEpoch, kind: ClaimKind = .report) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard currentEpoch == epoch, state == .free else { return nil }
        nextClaim += 1
        let claimID = nextClaim
        state = .held(claim: claimID, kind: kind)
        return claimID
    }

    public func commit(claim: UInt64) -> CommitOutcome {
        lock.lock()
        defer { lock.unlock() }
        if case .held(let heldClaim, _) = state, heldClaim == claim {
            state = .reported
            return .reported
        }
        return .lostToAnotherReporter
    }

    public func release(claim: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if case .held(let heldClaim, _) = state, heldClaim == claim {
            state = .free
        }
    }

    public func startNextTurn() {
        lock.lock()
        defer { lock.unlock() }
        currentEpoch = TurnEpoch(currentEpoch.value + 1)
        state = .free
    }

    public func reportState() -> TurnReportState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

// MARK: - TurnEndQueue (Worker and Teardown Drain)

/// Asynchronous queue and background worker for dispatching turn-end hook reports in FIFO order.
/// Provides bounded flush and drain lifecycle with a teardown budget of 250ms (`TURN_END_DRAIN_BUDGET`).
public actor TurnEndQueue {
    public typealias HookDispatchHandler = @Sendable (TurnEndReport) async -> Void

    private enum QueueItem: Sendable {
        case report(TurnEndReport)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private var queue: [QueueItem] = []
    private var isDisarmed: Bool = false
    private var isDrained: Bool = false
    private var isProcessing: Bool = false
    private var workerTask: Task<Void, Never>?
    private let dispatchHandler: HookDispatchHandler

    public init(dispatchHandler: @escaping HookDispatchHandler) {
        self.dispatchHandler = dispatchHandler
    }

    /// Enqueues a turn end report for background delivery.
    /// Returns `true` if queued, or `false` if the queue is closed/drained.
    public func enqueue(_ report: TurnEndReport) -> Bool {
        guard !isDisarmed && !isDrained else { return false }
        queue.append(.report(report))
        ensureWorkerRunning()
        return true
    }

    /// Flushes all currently queued items, waiting up to `budget` seconds.
    /// Leaves the queue open for subsequent turn reports.
    public func flush(timeoutSeconds: TimeInterval = TURN_END_DRAIN_BUDGET) async {
        guard !isDrained else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.append(.barrier(continuation))
            ensureWorkerRunning()
        }
    }

    /// Closes the queue to new items and waits up to `timeoutSeconds` for the worker to finish processing.
    public func drain(timeoutSeconds: TimeInterval = TURN_END_DRAIN_BUDGET) async {
        isDisarmed = true
        isDrained = true

        let worker = workerTask
        guard let worker else { return }

        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await worker.value
                return true
            }
            group.addTask {
                let nanos = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !completed {
            worker.cancel()
        }
        self.workerTask = nil
    }

    private func ensureWorkerRunning() {
        guard !isProcessing && workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.processLoop()
        }
    }

    private func processLoop() async {
        isProcessing = true
        while true {
            guard !queue.isEmpty else { break }
            let item = queue.removeFirst()
            switch item {
            case .report(let report):
                await dispatchHandler(report)
            case .barrier(let continuation):
                continuation.resume()
            }
        }
        isProcessing = false
        workerTask = nil
        if !queue.isEmpty {
            ensureWorkerRunning()
        }
    }
}
