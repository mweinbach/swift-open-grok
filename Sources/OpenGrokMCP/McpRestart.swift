// McpRestart.swift
//
// Bounded stdio MCP auto-restart and exponential backoff.
// Ported from `crates/codegen/xai-grok-shell/src/session/mcp_restart.rs`.
//
// ## Backoff Schedule
// Exactly 3 attempts at:
// - attempt 1 -> +1s  (t=1s)
// - attempt 2 -> +4s  (t=5s)
// - attempt 3 -> +16s (t=21s)
// Encoded as `BACKOFF = [1.0, 4.0, 16.0]`. Full window before exhaustion is 21 seconds.
//
// ## Guard Rails (Skip Conditions)
// 1. Non-restart event kind: only `transportClosed` and `handshakeFailed` trigger restarts.
// 2. HTTP/OAuth transports: auto-restart is stdio-only; HTTP/OAuth use in-place recovery / tool reset.
// 3. Intentional teardown: `isInShuttingDown` skips auto-restart on config drop / killOnDrop.
// 4. Disabled / unconfigured: checks `isStdioServerConfigured` at schedule time and inside the loop.
// 5. Already empty: servers that already exhausted handshakes are not restarted.
// 6. In-flight dedup: prevents concurrent duplicate restart tasks for the same server.

import Foundation
import OpenGrokShared
import OpenGrokToolTypes

/// Error type for MCP restart and recovery failures.
public struct McpRestartError: Error, Sendable, CustomStringConvertible, Equatable, Codable, ExpressibleByStringLiteral {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public init(stringLiteral value: String) {
        self.message = value
    }

    public var description: String { message }
}

/// State representation for an active, finished, or exhausted MCP restart loop.
public struct McpRestartState: Sendable, Codable, Equatable {
    /// Current restart attempt index (1..3, or 0 if not started).
    public var attempt: Int
    /// Next scheduled backoff delay in seconds.
    public var nextBackoffDelay: TimeInterval
    /// Current status reason (e.g. `.restarting`, `.unavailable`, `.disabled`, `.restartFailed`, `.restartSucceeded`).
    public var statusReason: McpServerStatusReason
    /// True when all 3 backoff attempts have failed.
    public var isExhausted: Bool
    /// Optional last error description from failed respawn attempts.
    public var lastError: String?

    public init(
        attempt: Int = 0,
        nextBackoffDelay: TimeInterval = 1.0,
        statusReason: McpServerStatusReason = .restarting,
        isExhausted: Bool = false,
        lastError: String? = nil
    ) {
        self.attempt = attempt
        self.nextBackoffDelay = nextBackoffDelay
        self.statusReason = statusReason
        self.isExhausted = isExhausted
        self.lastError = lastError
    }

    /// Exponential backoff delays for the three stdio respawn attempts: `[1.0, 4.0, 16.0]`.
    public static let BACKOFF: [TimeInterval] = [1.0, 4.0, 16.0]

    /// HTTP in-place recovery backoff ladder (first attempt is immediate, then 7 backoff steps).
    public static let HTTP_RECOVERY_BACKOFF: [TimeInterval] = [1.0, 4.0, 16.0, 30.0, 30.0, 30.0, 30.0]

    /// Maximum number of stdio auto-restart attempts.
    public static let maxAttempts: Int = 3

    /// Total cumulative backoff exhaustion window in seconds (1.0 + 4.0 + 16.0 = 21.0s).
    public static let totalExhaustionWindow: TimeInterval = 21.0

    /// Returns the backoff delay for the given 1-based attempt index, or `nil` if out of range.
    public static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1 && attempt <= BACKOFF.count else { return nil }
        return BACKOFF[attempt - 1]
    }

    /// Returns cumulative elapsed backoff target for the given 1-based attempt index (t=1s, t=5s, t=21s).
    public static func cumulativeDelay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1 && attempt <= BACKOFF.count else { return nil }
        var sum: TimeInterval = 0
        for i in 0..<attempt {
            sum += BACKOFF[i]
        }
        return sum
    }

    /// Convenience checks
    public var isRestarting: Bool { statusReason == .restarting }
    public var isUnavailable: Bool { statusReason == .unavailable || statusReason == .restartFailed }
    public var isDisabled: Bool { statusReason == .disabled }
}

/// Skip reason labels when auto-restart or HTTP recovery does not fire.
public enum McpRestartSkipReason: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    /// Server is in intentional shutdown (`isInShuttingDown` is true).
    case shuttingDown = "shutting_down"
    /// Server was not configured as stdio at schedule time.
    case notConfigured = "not_configured"
    /// Server was disabled or removed mid-backoff loop.
    case disabled = "disabled"
    /// A restart task is already in progress for this server.
    case inProgress = "in_progress"
    /// The event kind was not `transportClosed` or `handshakeFailed`.
    case nonRestartEvent = "non_restart_event"
    /// Non-stdio transport (e.g. HTTP/OAuth).
    case nonStdioTransport = "non_stdio_transport"
    /// Server is in empty (exhausted) state.
    case alreadyEmpty = "already_empty"
}

/// Side-effect and state interrogation interface required by auto-restart routines.
public protocol McpRestartActions: Sendable {
    /// Returns `true` iff the server still has a stdio entry in configs AND is enabled.
    func isStdioServerConfigured(server: String) async -> Bool

    /// Returns `true` iff the server is in the intentional shutdown / config removal set.
    func isInShuttingDown(server: String) async -> Bool

    /// Re-runs server startup, performs handshake, and swaps the new client.
    func respawnStdio(server: String) async -> Result<Void, McpRestartError>

    /// Emits a status update payload over ACP.
    func pushStatus(payload: McpServerStatusPayload) async

    /// Atomically claims the in-flight restart slot for `server`. Returns `true` if claimed.
    func beginRestart(server: String) async -> Bool

    /// Releases the in-flight restart claim for `server`.
    func endRestart(server: String) async

    /// Returns `true` iff the server has an enabled HTTP/SSE entry in configs.
    func isHttpServerConfigured(server: String) async -> Bool

    /// Performs in-place HTTP client transport reset and re-handshake.
    func resetHttpClient(server: String) async -> Result<Void, McpRestartError>

    /// Drops the server's registered tools when restart exhausts retries.
    func unregisterServerTools(server: String) async

    /// Returns the current client state kind if known.
    func serverClientStateKind(server: String) async -> ClientStateKind?
}

public extension McpRestartActions {
    func beginRestart(server: String) async -> Bool { true }
    func endRestart(server: String) async {}
    func isHttpServerConfigured(server: String) async -> Bool { false }
    func resetHttpClient(server: String) async -> Result<Void, McpRestartError> {
        .failure("resetHttpClient not implemented")
    }
    func unregisterServerTools(server: String) async {}
    func serverClientStateKind(server: String) async -> ClientStateKind? { nil }
}

/// Cooperative cancellation token for scheduling and backoff loops.
public final class McpRestartCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelledFlag = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { isCancelledFlag }
    }

    public func cancel() {
        let resumeList: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !isCancelledFlag else { return [] }
            isCancelledFlag = true
            let list = continuations
            continuations.removeAll()
            return list
        }
        for continuation in resumeList {
            continuation.resume()
        }
    }

    public func cancelled() async {
        let alreadyCancelled: Bool = lock.withLock { isCancelledFlag }
        if alreadyCancelled { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResumeImmediately: Bool = lock.withLock {
                if isCancelledFlag {
                    return true
                } else {
                    continuations.append(continuation)
                    return false
                }
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}

/// Namespace and executor for MCP auto-restart routines.
public enum McpRestart {
    /// Sleeper closure type used for injecting custom/mock sleep intervals in unit tests.
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    /// Decides whether to schedule an auto-restart task for a client event, applying guard rails.
    /// Returns `true` iff a restart task was spawned.
    @discardableResult
    public static func maybeScheduleRestart(
        actions: any McpRestartActions,
        sessionId: String,
        server: String,
        kind: McpClientEventKind,
        cancellationToken: McpRestartCancellationToken? = nil,
        sleeper: Sleeper? = nil,
        onStateChange: (@Sendable (McpRestartState) async -> Void)? = nil
    ) async -> Bool {
        // Guard 1: Non-restart event kind — only transportClosed / handshakeFailed trigger restarts.
        guard kind.isRestartTrigger else {
            return false
        }

        // Guard 2: Already-empty — a previous handshake exhausted attempts.
        if let stateKind = await actions.serverClientStateKind(server: server), stateKind == .empty {
            return false
        }

        // Guard 3: Intentional shutdown / killOnDrop.
        if await actions.isInShuttingDown(server: server) {
            return false
        }

        // Guard 4: Stdio only — must be currently configured as stdio and enabled.
        // Non-stdio (HTTP/OAuth) returns false here, skipping auto-restart.
        guard await actions.isStdioServerConfigured(server: server) else {
            return false
        }

        // Guard 5: Dedup against an already-in-flight restart task.
        guard await actions.beginRestart(server: server) else {
            return false
        }

        Task {
            defer {
                Task {
                    await actions.endRestart(server: server)
                }
            }
            await autoRestartStdio(
                actions: actions,
                sessionId: sessionId,
                server: server,
                cancellationToken: cancellationToken,
                sleeper: sleeper,
                onStateChange: onStateChange
            )
        }
        return true
    }

    /// One-shot bounded stdio restart loop: sleeps backoff, re-checks guard rails, and calls `respawnStdio`.
    /// Attempts up to 3 times (1s, 4s, 16s) before parking the server as unavailable.
    @discardableResult
    public static func autoRestartStdio(
        actions: any McpRestartActions,
        sessionId: String,
        server: String,
        cancellationToken: McpRestartCancellationToken? = nil,
        sleeper: Sleeper? = nil,
        onStateChange: (@Sendable (McpRestartState) async -> Void)? = nil
    ) async -> McpRestartState {
        let sleepFunc: Sleeper = sleeper ?? { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        for (idx, wait) in McpRestartState.BACKOFF.enumerated() {
            let attempt = idx + 1
            let nextDelay = (attempt < McpRestartState.BACKOFF.count) ? McpRestartState.BACKOFF[attempt] : 0.0

            let restartingState = McpRestartState(
                attempt: attempt,
                nextBackoffDelay: wait,
                statusReason: .restarting,
                isExhausted: false
            )
            await onStateChange?(restartingState)

            // Sleep with cancellation support
            if let cancellationToken {
                if cancellationToken.isCancelled || Task.isCancelled {
                    return restartingState
                }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await sleepFunc(wait)
                        }
                        group.addTask {
                            await cancellationToken.cancelled()
                            throw CancellationError()
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                } catch {
                    return restartingState
                }
            } else {
                if Task.isCancelled { return restartingState }
                do {
                    try await sleepFunc(wait)
                } catch {
                    return restartingState
                }
            }

            if (cancellationToken?.isCancelled ?? false) || Task.isCancelled {
                return restartingState
            }

            // In-loop Guard 1: Must still be configured as stdio and enabled
            if !(await actions.isStdioServerConfigured(server: server)) {
                let disabledState = McpRestartState(
                    attempt: attempt,
                    nextBackoffDelay: 0,
                    statusReason: .disabled,
                    isExhausted: false
                )
                await onStateChange?(disabledState)
                let payload = McpServerStatusPayload(
                    sessionId: sessionId,
                    name: server,
                    source: McpServerSource.classify(name: server),
                    status: .unavailable,
                    reason: .disabled,
                    detail: nil
                )
                await actions.pushStatus(payload: payload)
                return disabledState
            }

            // In-loop Guard 2: Must not be in intentional shutdown
            if await actions.isInShuttingDown(server: server) {
                let shutdownState = McpRestartState(
                    attempt: attempt,
                    nextBackoffDelay: 0,
                    statusReason: .unavailable,
                    isExhausted: false
                )
                await onStateChange?(shutdownState)
                return shutdownState
            }

            // Execute respawn
            let respawnResult = await actions.respawnStdio(server: server)
            switch respawnResult {
            case .success:
                let succeededState = McpRestartState(
                    attempt: attempt,
                    nextBackoffDelay: 0,
                    statusReason: .restartSucceeded,
                    isExhausted: false
                )
                await onStateChange?(succeededState)
                let payload = McpServerStatusPayload(
                    sessionId: sessionId,
                    name: server,
                    source: McpServerSource.classify(name: server),
                    status: .ready,
                    reason: .restartSucceeded,
                    detail: nil
                )
                await actions.pushStatus(payload: payload)
                return succeededState

            case .failure(let error):
                let failedState = McpRestartState(
                    attempt: attempt,
                    nextBackoffDelay: nextDelay,
                    statusReason: .restartFailed,
                    isExhausted: attempt >= McpRestartState.maxAttempts,
                    lastError: error.message
                )
                await onStateChange?(failedState)
                let payload = McpServerStatusPayload(
                    sessionId: sessionId,
                    name: server,
                    source: McpServerSource.classify(name: server),
                    status: .unavailable,
                    reason: .restartFailed,
                    detail: "attempt \(attempt) of \(McpRestartState.BACKOFF.count): \(error.message)"
                )
                await actions.pushStatus(payload: payload)
            }
        }

        // All attempts exhausted — park the server as unavailable and unregister its tools
        let exhaustedState = McpRestartState(
            attempt: McpRestartState.maxAttempts,
            nextBackoffDelay: 0,
            statusReason: .unavailable,
            isExhausted: true,
            lastError: "exhausted after \(McpRestartState.BACKOFF.count) attempts"
        )
        await onStateChange?(exhaustedState)
        let finalPayload = McpServerStatusPayload(
            sessionId: sessionId,
            name: server,
            source: McpServerSource.classify(name: server),
            status: .unavailable,
            reason: .restartFailed,
            detail: "exhausted after \(McpRestartState.BACKOFF.count) attempts"
        )
        await actions.pushStatus(payload: finalPayload)
        await actions.unregisterServerTools(server: server)
        return exhaustedState
    }

    /// Schedules an HTTP recovery task if guard rails pass.
    @discardableResult
    public static func maybeScheduleHttpRecovery(
        actions: any McpRestartActions,
        server: String,
        cancellationToken: McpRestartCancellationToken? = nil,
        sleeper: Sleeper? = nil
    ) async -> Bool {
        // Guard 1: Intentional teardown
        if await actions.isInShuttingDown(server: server) {
            return false
        }

        // Guard 2: Must be an enabled HTTP/SSE entry
        guard await actions.isHttpServerConfigured(server: server) else {
            return false
        }

        // Guard 3: Dedup in-flight restart/recovery task
        guard await actions.beginRestart(server: server) else {
            return false
        }

        Task {
            defer {
                Task {
                    await actions.endRestart(server: server)
                }
            }
            await httpRecoveryLoop(
                actions: actions,
                server: server,
                cancellationToken: cancellationToken,
                sleeper: sleeper
            )
        }
        return true
    }

    /// Retry loop backing HTTP recovery: immediate attempt, then back off on `HTTP_RECOVERY_BACKOFF`.
    public static func httpRecoveryLoop(
        actions: any McpRestartActions,
        server: String,
        cancellationToken: McpRestartCancellationToken? = nil,
        sleeper: Sleeper? = nil
    ) async {
        let sleepFunc: Sleeper = sleeper ?? { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        let delays: [TimeInterval?] = [nil] + McpRestartState.HTTP_RECOVERY_BACKOFF.map { Optional($0) }

        for waitBefore in delays {
            if let wait = waitBefore {
                if let cancellationToken {
                    if cancellationToken.isCancelled || Task.isCancelled { return }
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask {
                                try await sleepFunc(wait)
                            }
                            group.addTask {
                                await cancellationToken.cancelled()
                                throw CancellationError()
                            }
                            try await group.next()
                            group.cancelAll()
                        }
                    } catch {
                        return
                    }
                } else {
                    if Task.isCancelled { return }
                    do {
                        try await sleepFunc(wait)
                    } catch {
                        return
                    }
                }
            }

            if (cancellationToken?.isCancelled ?? false) || Task.isCancelled {
                return
            }

            if await actions.isInShuttingDown(server: server) {
                return
            }

            if !(await actions.isHttpServerConfigured(server: server)) {
                return
            }

            let result = await actions.resetHttpClient(server: server)
            if case .success = result {
                return
            }
        }
    }
}
