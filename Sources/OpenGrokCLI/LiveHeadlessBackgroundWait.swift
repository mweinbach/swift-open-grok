import Foundation
import OpenGrokAgentCoordinator
import OpenGrokShell
import OpenGrokShellBase

/// Headless Rust drains session-owned bash jobs and subagents after its prompt
/// completes (`xai-grok-pager/src/headless.rs:1333-1449`). This observer never
/// kills anything: normal launcher teardown remains the sole session reaper.
struct LiveHeadlessBackgroundWait: Sendable {
    struct Policy: Sendable, Equatable {
        static let defaultTimeoutSeconds: UInt64 = 600
        static let defaultNoWaitGraceMilliseconds: UInt64 = 750
        static let maximumTimeoutSeconds: UInt64 = 24 * 60 * 60
        static let defaultPollIntervalMilliseconds: UInt64 = 25

        var waitForBackground: Bool
        var timeoutMilliseconds: UInt64
        var noWaitGraceMilliseconds: UInt64
        var pollIntervalMilliseconds: UInt64

        init(
            waitForBackground: Bool,
            timeoutMilliseconds: UInt64,
            noWaitGraceMilliseconds: UInt64 = defaultNoWaitGraceMilliseconds,
            pollIntervalMilliseconds: UInt64 = defaultPollIntervalMilliseconds
        ) {
            self.waitForBackground = waitForBackground
            self.timeoutMilliseconds = min(
                timeoutMilliseconds,
                Self.maximumTimeoutSeconds * 1_000
            )
            self.noWaitGraceMilliseconds = min(
                noWaitGraceMilliseconds,
                Self.maximumTimeoutSeconds * 1_000
            )
            self.pollIntervalMilliseconds = max(
                1,
                min(pollIntervalMilliseconds, 1_000)
            )
        }

        init(options: CLIAdvancedOptions) {
            let seconds = min(
                options.backgroundWaitTimeoutSeconds,
                Self.maximumTimeoutSeconds
            )
            self.init(
                waitForBackground: !options.noWaitForBackground,
                timeoutMilliseconds: seconds * 1_000
            )
        }

        var effectiveBudgetMilliseconds: UInt64 {
            waitForBackground ? timeoutMilliseconds : noWaitGraceMilliseconds
        }
    }

    struct PendingWork: Sendable, Equatable {
        var shellTaskIDs: [String]
        var subagentIDs: [String]

        var isEmpty: Bool { shellTaskIDs.isEmpty && subagentIDs.isEmpty }
    }

    enum StopReason: Sendable, Equatable {
        case completed
        case timedOut
        case graceExpired
    }

    struct Outcome: Sendable, Equatable {
        var reason: StopReason
        var pending: PendingWork
        var elapsedMilliseconds: UInt64
    }

    enum OwnershipError: Error, Sendable, Equatable, CustomStringConvertible {
        case sessionMismatch
        case workingDirectoryMismatch
        case unavailableExecution
        case unrelatedSubagentHost

        var description: String {
            switch self {
            case .sessionMismatch:
                return "headless background wait requires the authenticated root session"
            case .workingDirectoryMismatch:
                return "headless background wait requires the root session working directory"
            case .unavailableExecution:
                return "headless background wait could not access the root session process table"
            case .unrelatedSubagentHost:
                return "headless background wait cannot observe another session's subagents"
            }
        }
    }

    let sessionID: String
    let workingDirectory: URL
    let policy: Policy
    private let execution: any OpenGrokShellProcessExecution
    private let coordinator: OpenGrokAgentCoordinator?

    /// Production entry: authenticate against both the immutable root scope
    /// and the owned process execution before reading either work table.
    init(
        sessionID: String,
        workingDirectory: URL,
        executor: LiveToolExecutor,
        subagents: LiveSubagentHost?,
        options: CLIAdvancedOptions
    ) async throws {
        try LiveConversationStore.validateSessionID(sessionID)
        guard executor.resourceAuthorizationScope.authorizationSessionID == sessionID else {
            throw OwnershipError.sessionMismatch
        }
        guard LiveToolExecutor.workspaceRootsMatch(
            executor.workingDirectory,
            workingDirectory
        ) else {
            throw OwnershipError.workingDirectoryMismatch
        }
        if let subagents, await subagents.context.sessionID != sessionID {
            throw OwnershipError.unrelatedSubagentHost
        }
        guard let execution = await executor.processExecution(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        ) else {
            throw OwnershipError.unavailableExecution
        }
        try self.init(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            execution: execution,
            coordinator: subagents?.coordinator,
            policy: Policy(options: options)
        )
    }

    /// The same authenticated owned-execution seam is directly useful for
    /// focused process/coordinator regressions without a full pager launch.
    init(
        sessionID: String,
        workingDirectory: URL,
        execution: any OpenGrokShellProcessExecution,
        coordinator: OpenGrokAgentCoordinator? = nil,
        policy: Policy
    ) throws {
        try LiveConversationStore.validateSessionID(sessionID)
        guard execution.sessionID == sessionID else {
            throw OwnershipError.sessionMismatch
        }
        guard LiveToolExecutor.workspaceRootsMatch(
            execution.workingDirectory,
            workingDirectory
        ) else {
            throw OwnershipError.workingDirectoryMismatch
        }
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.execution = execution
        self.coordinator = coordinator
        self.policy = policy
    }

    /// Launcher-facing shape deliberately returns no discardable status.
    /// Timeout and no-wait grace are normal exits; cancellation remains typed.
    func wait() async throws {
        switch try await awaitBackgroundWork().reason {
        case .completed, .timedOut, .graceExpired:
            return
        }
    }

    func awaitBackgroundWork() async throws -> Outcome {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let budgetNanoseconds = policy.effectiveBudgetMilliseconds * 1_000_000
        let deadlineResult = startedAt.addingReportingOverflow(budgetNanoseconds)
        let deadline = deadlineResult.overflow ? UInt64.max : deadlineResult.partialValue

        while true {
            try Task.checkCancellation()
            let pending = await pendingWork()
            try Task.checkCancellation()

            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= startedAt ? (now - startedAt) / 1_000_000 : 0
            if policy.waitForBackground, pending.isEmpty {
                return Outcome(reason: .completed, pending: pending, elapsedMilliseconds: elapsed)
            }
            if now >= deadline {
                return Outcome(
                    reason: policy.waitForBackground ? .timedOut : .graceExpired,
                    pending: pending,
                    elapsedMilliseconds: elapsed
                )
            }

            let remaining = deadline - now
            let pollNanoseconds = policy.pollIntervalMilliseconds * 1_000_000
            try await Task.sleep(nanoseconds: min(remaining, pollNanoseconds))
        }
    }

    func pendingWork() async -> PendingWork {
        let snapshots = await execution.listTasks()
        let shellTaskIDs = snapshots
            .filter { !$0.completed && $0.ownerSessionID == sessionID }
            .map(\.taskID)
            .sorted()

        let subagentIDs: [String]
        if let coordinator {
            subagentIDs = await coordinator.listActive(parentSessionID: sessionID)
                .filter { $0.request.parentSessionID == sessionID }
                .map { $0.request.id }
                .sorted()
        } else {
            subagentIDs = []
        }

        return PendingWork(shellTaskIDs: shellTaskIDs, subagentIDs: subagentIDs)
    }
}
