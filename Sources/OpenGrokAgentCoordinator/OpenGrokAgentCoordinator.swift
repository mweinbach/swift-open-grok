import Foundation
import OpenGrokToolTypes

public enum OpenGrokChildOwner: String, Codable, Sendable, Hashable {
    case task
    case swarm
    case workflow
    case antigravity
}

public enum OpenGrokChildCancelTarget: Sendable, Hashable {
    case childID(String)
    case parentSession(String)
    case parentPrompt(sessionID: String, promptID: String)
    case workflowRun(String)
}

public struct OpenGrokChildRequest: Codable, Sendable, Hashable {
    public var id: String
    public var parentSessionID: String
    public var parentPromptID: String?
    public var subagentType: String?
    public var description: String?
    public var childCWD: String?
    public var worktreePath: String?
    public var workflowRunID: String?
    public var owner: OpenGrokChildOwner
    public var runInBackground: Bool
    public var awaitToCompletion: Bool
    public var definitionBackground: Bool
    public var capabilityMode: String?
    public var reasoningEffort: String?
    public var resumeFrom: String?
    public var surfaceCompletion: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case parentSessionID = "parent_session_id"
        case parentPromptID = "parent_prompt_id"
        case subagentType = "subagent_type"
        case description
        case childCWD = "child_cwd"
        case worktreePath = "worktree_path"
        case workflowRunID = "workflow_run_id"
        case owner
        case runInBackground = "run_in_background"
        case awaitToCompletion = "await_to_completion"
        case definitionBackground = "definition_background"
        case capabilityMode = "capability_mode"
        case reasoningEffort = "reasoning_effort"
        case resumeFrom = "resume_from"
        case surfaceCompletion = "surface_completion"
    }

    public init(
        id: String,
        parentSessionID: String,
        parentPromptID: String? = nil,
        subagentType: String? = nil,
        description: String? = nil,
        childCWD: String? = nil,
        worktreePath: String? = nil,
        workflowRunID: String? = nil,
        owner: OpenGrokChildOwner,
        runInBackground: Bool = false,
        awaitToCompletion: Bool = false,
        definitionBackground: Bool = false,
        capabilityMode: String? = nil,
        reasoningEffort: String? = nil,
        resumeFrom: String? = nil,
        surfaceCompletion: Bool = true
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.parentPromptID = parentPromptID
        self.subagentType = subagentType
        self.description = description
        self.childCWD = childCWD
        self.worktreePath = worktreePath
        self.workflowRunID = workflowRunID
        self.owner = owner
        self.runInBackground = runInBackground
        self.awaitToCompletion = awaitToCompletion
        self.definitionBackground = definitionBackground
        self.capabilityMode = capabilityMode
        self.reasoningEffort = reasoningEffort
        self.resumeFrom = resumeFrom
        self.surfaceCompletion = surfaceCompletion
    }
}

public struct OpenGrokChildResult: Codable, Sendable, Hashable {
    public var id: String
    public var success: Bool
    public var output: String
    public var cancelled: Bool
    public var error: String?
    public var tokensUsed: UInt64
    public var durationMS: UInt64

    private enum CodingKeys: String, CodingKey {
        case id
        case success
        case output
        case cancelled
        case error
        case tokensUsed = "tokens_used"
        case durationMS = "duration_ms"
    }

    public init(
        id: String,
        success: Bool,
        output: String = "",
        cancelled: Bool = false,
        error: String? = nil,
        tokensUsed: UInt64 = 0,
        durationMS: UInt64 = 0
    ) {
        self.id = id
        self.success = success
        self.output = output
        self.cancelled = cancelled
        self.error = error
        self.tokensUsed = tokensUsed
        self.durationMS = durationMS
    }
}

public struct OpenGrokChildSummary: Codable, Sendable, Hashable {
    public var request: OpenGrokChildRequest
    public var state: String
    public var result: OpenGrokChildResult?

    public init(request: OpenGrokChildRequest, state: String, result: OpenGrokChildResult? = nil) {
        self.request = request
        self.state = state
        self.result = result
    }
}

public struct OpenGrokCompletion: Codable, Sendable, Hashable {
    public var parentSessionID: String
    public var childID: String
    public var result: OpenGrokChildResult
    public var autoWakeSuppressed: Bool

    private enum CodingKeys: String, CodingKey {
        case parentSessionID = "parent_session_id"
        case childID = "child_id"
        case result
        case autoWakeSuppressed = "auto_wake_suppressed"
    }

    public init(parentSessionID: String, childID: String, result: OpenGrokChildResult, autoWakeSuppressed: Bool) {
        self.parentSessionID = parentSessionID
        self.childID = childID
        self.result = result
        self.autoWakeSuppressed = autoWakeSuppressed
    }
}

public struct OpenGrokUsageFold: Codable, Sendable, Hashable {
    public var parentSessionID: String
    public var promptID: String
    public var tokensUsed: UInt64
    public var childIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case parentSessionID = "parent_session_id"
        case promptID = "prompt_id"
        case tokensUsed = "tokens_used"
        case childIDs = "child_ids"
    }
}

public struct OpenGrokFinalChildCapabilities: Codable, Sendable, Hashable {
    public var capabilityMode: String
    public var canSpawnChildren: Bool
    public var canAutoWake: Bool

    public init(capabilityMode: String = "read-only", canSpawnChildren: Bool = false, canAutoWake: Bool = false) {
        self.capabilityMode = capabilityMode
        self.canSpawnChildren = canSpawnChildren
        self.canAutoWake = canAutoWake
    }
}

public enum OpenGrokCoordinatorError: Error, Sendable, Hashable, CustomStringConvertible {
    case duplicateChild(String)
    case spawnBlocked(String)
    case childNotFound(String)
    case timeout

    public var description: String {
        switch self {
        case .duplicateChild(let id): return "child id already exists: \(id)"
        case .spawnBlocked(let session): return "child spawning is blocked for session \(session)"
        case .childNotFound(let id): return "child not found: \(id)"
        case .timeout: return "foreground child await timed out"
        }
    }
}

public actor OpenGrokAgentCoordinator {
    public static let maxCompletedEntries = 256
    public static let maxCompletionEntries = 256

    private struct ActiveChild {
        var request: OpenGrokChildRequest
        var task: Task<OpenGrokChildResult, Never>
        var cancellationRequested: Bool
        var parentTornDown: Bool
    }

    private var active: [String: ActiveChild] = [:]
    private var completed: [String: OpenGrokChildSummary] = [:]
    private var completedOrder: [String] = []
    private var completions: [OpenGrokCompletion] = []
    private var blockedSessions = Set<String>()
    private var suppressedAutoWakeSessions = Set<String>()
    private var usage: [String: [String: UInt64]] = [:]
    private var usageNotApplied = Set<String>()

    // MARK: Team-scoped mailboxes
    //
    // Rust `SubagentCoordinator` gained `mailboxes` / `mailbox_waiters` in
    // commit 7957721e (task/coordinator.rs:53-54, 78-89). The Swift actor keeps
    // the same two maps under the same `(team_scope_id, agent_id)` key.

    struct MailboxKey: Hashable, Sendable {
        var teamScopeID: String
        var agentID: String

        init(_ identity: AgentMailboxIdentity) {
            self.teamScopeID = identity.teamScopeID
            self.agentID = identity.agentID
        }

        init(teamScopeID: String, agentID: String) {
            self.teamScopeID = teamScopeID
            self.agentID = agentID
        }
    }

    private struct MailboxWaiter {
        var token: UInt64
        var resume: (WaitAgentMessagesOutput) -> Void
    }

    private var mailboxes: [MailboxKey: [AgentMailboxMessage]] = [:]
    private var mailboxWaiters: [MailboxKey: MailboxWaiter] = [:]
    private var nextWaiterToken: UInt64 = 0

    /// Live-delivery seam for follow-up messages, mirroring Rust
    /// `ChildControl::deliver_followup` (coordinator_state.rs:41-43) and
    /// `ChildRunner::deliver_root_followup` (coordinator_state.rs:124-130).
    /// Returns `true` when the host handed the message to a running turn.
    /// The Rust defaults return `false`, and so does this one.
    ///
    /// `async` where Rust's hook is a synchronous channel send: the Swift
    /// hosts deliver into actors (the subagent host's child buffers, the root
    /// session's interjection actor), and a sync hook could not reach either.
    /// The cost is actor reentrancy during the await — `sendAgentMessage`
    /// re-checks for a waiter that parked mid-await before queueing, so a
    /// racing `wait_agent` cannot be left parked beside a queued message.
    private var deliverFollowup: @Sendable (String, AgentMailboxMessage) async -> Bool = { _, _ in false }

    /// Observer for every accepted send, mirroring Rust
    /// `ChildRunner::on_agent_message` (coordinator_state.rs:132-138).
    private var onAgentMessage: @Sendable (AgentMailboxMessage, AgentMessageDeliveryStatus) -> Void = { _, _ in }

    public init() {}

    /// Install the host's live-delivery and observation hooks. Without them the
    /// coordinator is pure store-and-poll: sends queue and `waitAgentMessages`
    /// drains, which is exactly the Rust behaviour when neither `deliver_*`
    /// override is provided.
    public func installMailboxHooks(
        deliverFollowup: @escaping @Sendable (String, AgentMailboxMessage) async -> Bool,
        onAgentMessage: @escaping @Sendable (AgentMailboxMessage, AgentMessageDeliveryStatus) -> Void = { _, _ in }
    ) {
        self.deliverFollowup = deliverFollowup
        self.onAgentMessage = onAgentMessage
    }

    /// Replace ONLY the accepted-send observer, leaving live-delivery routing
    /// in place. The ACP notification gateway subscribes after the agent
    /// stack has already wired `deliverFollowup` (the interjection/buffer
    /// seams), and re-calling `installMailboxHooks` there would silently
    /// clobber that routing back to queue-only.
    public func installAgentMessageObserver(
        _ observer: @escaping @Sendable (AgentMailboxMessage, AgentMessageDeliveryStatus) -> Void
    ) {
        onAgentMessage = observer
    }

    @discardableResult
    public func spawn(
        _ request: OpenGrokChildRequest,
        operation: @escaping @Sendable () async -> OpenGrokChildResult
    ) throws -> String {
        guard !active.keys.contains(request.id), !completed.keys.contains(request.id) else {
            throw OpenGrokCoordinatorError.duplicateChild(request.id)
        }
        if blockedSessions.contains(request.parentSessionID), request.owner != .workflow {
            throw OpenGrokCoordinatorError.spawnBlocked(request.parentSessionID)
        }
        let task = Task { await operation() }
        active[request.id] = ActiveChild(
            request: request,
            task: task,
            cancellationRequested: false,
            parentTornDown: false
        )
        Task { [weak self] in
            let result = await task.value
            await self?.finish(requestID: request.id, result: result)
        }
        return request.id
    }

    public func cancel(_ target: OpenGrokChildCancelTarget) -> Int {
        let ids: [String]
        switch target {
        case .childID(let id):
            ids = active[id] == nil ? [] : [id]
        case .parentSession(let sessionID):
            ids = active.values
                .filter { $0.request.parentSessionID == sessionID && $0.request.owner != .workflow }
                .map { $0.request.id }
            blockedSessions.insert(sessionID)
        case .parentPrompt(let sessionID, let promptID):
            ids = active.values
                .filter {
                    $0.request.parentSessionID == sessionID
                        && $0.request.parentPromptID == promptID
                }
                .map { $0.request.id }
        case .workflowRun(let runID):
            ids = active.values.filter { $0.request.workflowRunID == runID }.map { $0.request.id }
        }
        for id in ids {
            active[id]?.cancellationRequested = true
            active[id]?.task.cancel()
        }
        return ids.count
    }

    public func openSpawnAdmission(for sessionID: String) {
        blockedSessions.remove(sessionID)
    }

    public func teardown(sessionID: String) {
        blockedSessions.remove(sessionID)
        suppressedAutoWakeSessions.remove(sessionID)
        completions.removeAll { $0.parentSessionID == sessionID }
        let sessionPrefix = "\(sessionID)\n"
        usage = usage.filter { !$0.key.hasPrefix(sessionPrefix) }
        usageNotApplied = usageNotApplied.filter { !$0.hasPrefix(sessionPrefix) }
        // Rust `SubagentEvent::TeardownSession` drops the team's mailboxes and
        // closes its waiters as timed out (coordinator.rs:369-384).
        mailboxes = mailboxes.filter { $0.key.teamScopeID != sessionID }
        let closing = mailboxWaiters.filter { $0.key.teamScopeID == sessionID }
        for (key, waiter) in closing {
            mailboxWaiters.removeValue(forKey: key)
            waiter.resume(WaitAgentMessagesOutput(messages: [], timedOut: true))
        }
        let ids = active.values.filter { $0.request.parentSessionID == sessionID }.map { $0.request.id }
        for id in ids {
            // A late cancellation completion must not resurrect a deleted
            // session's notification after its pending queue was cleared.
            active[id]?.request.surfaceCompletion = false
            active[id]?.parentTornDown = true
            active[id]?.cancellationRequested = true
            active[id]?.task.cancel()
        }
    }

    public func suppressAutoWake(for sessionID: String) {
        suppressedAutoWakeSessions.insert(sessionID)
    }

    public func allowAutoWake(for sessionID: String) {
        suppressedAutoWakeSessions.remove(sessionID)
    }

    public func listActive(parentSessionID: String? = nil, workflowRunID: String? = nil) -> [OpenGrokChildSummary] {
        active.values
            .filter {
                (parentSessionID == nil || $0.request.parentSessionID == parentSessionID) &&
                (workflowRunID == nil || $0.request.workflowRunID == workflowRunID)
            }
            .map { OpenGrokChildSummary(request: $0.request, state: "active") }
            .sorted { $0.request.id < $1.request.id }
    }

    public func listCompleted() -> [OpenGrokChildSummary] {
        completedOrder.compactMap { completed[$0] }
    }

    public func pollCompletions(parentSessionID: String? = nil, suppressIDs: Set<String> = []) -> [OpenGrokCompletion] {
        var selected: [OpenGrokCompletion] = []
        var remaining: [OpenGrokCompletion] = []
        for completion in completions {
            let matchesSession = parentSessionID == nil || completion.parentSessionID == parentSessionID
            if matchesSession {
                if !suppressIDs.contains(completion.childID) {
                    selected.append(completion)
                }
            } else {
                remaining.append(completion)
            }
        }
        completions = remaining
        return selected
    }

    public func awaitResult(_ childID: String, timeoutMS: UInt64? = nil) async throws -> OpenGrokChildResult {
        if let result = completed[childID]?.result { return result }
        guard active[childID] != nil else { throw OpenGrokCoordinatorError.childNotFound(childID) }
        let deadline = timeoutMS.map { UInt64(Date().timeIntervalSince1970 * 1_000).saturatingAdd($0) }
        while true {
            if let result = completed[childID]?.result { return result }
            if let deadline, UInt64(Date().timeIntervalSince1970 * 1_000) >= deadline {
                throw OpenGrokCoordinatorError.timeout
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    public func markUsageNotApplied(parentSessionID: String, promptID: String) {
        usageNotApplied.insert(scopeKey(sessionID: parentSessionID, promptID: promptID))
    }

    public func clearUsageNotApplied(parentSessionID: String, promptID: String) {
        usageNotApplied.remove(scopeKey(sessionID: parentSessionID, promptID: promptID))
    }

    public func recordUsage(parentSessionID: String, promptID: String, childID: String, tokens: UInt64) {
        let key = scopeKey(sessionID: parentSessionID, promptID: promptID)
        var scopedUsage = usage[key] ?? [:]
        scopedUsage[childID] = (scopedUsage[childID] ?? 0).saturatingAdd(tokens)
        usage[key] = scopedUsage
    }

    public func foldUsage(parentSessionID: String, promptID: String, childIDs: [String]) -> OpenGrokUsageFold {
        let key = scopeKey(sessionID: parentSessionID, promptID: promptID)
        let uniqueChildIDs = Array(Set(childIDs)).sorted()
        let tokensUsed = uniqueChildIDs.reduce(UInt64.zero) { total, childID in
            total.saturatingAdd(usage[key]?[childID] ?? 0)
        }
        return OpenGrokUsageFold(
            parentSessionID: parentSessionID,
            promptID: promptID,
            tokensUsed: tokensUsed,
            childIDs: uniqueChildIDs
        )
    }

    public func outstanding(parentSessionID: String, promptID: String) -> (liveIDs: [String], backgroundLive: Bool, usageNotApplied: Bool) {
        let children = active.values.filter { $0.request.parentSessionID == parentSessionID && $0.request.parentPromptID == promptID }
        let live = children.filter { !$0.request.runInBackground && !$0.request.definitionBackground }.map { $0.request.id }.sorted()
        let background = children.contains { $0.request.runInBackground || $0.request.definitionBackground }
        return (live, background, usageNotApplied.contains(scopeKey(sessionID: parentSessionID, promptID: promptID)))
    }

    public func finalCapabilities(for childID: String) -> OpenGrokFinalChildCapabilities? {
        guard completed[childID] != nil else { return nil }
        return OpenGrokFinalChildCapabilities()
    }

    public func counts() -> (pending: Int, active: Int, completed: Int) {
        (0, active.count, completed.count)
    }

    private func finish(requestID: String, result: OpenGrokChildResult) {
        guard let child = active.removeValue(forKey: requestID) else { return }
        var finalResult = result
        if child.cancellationRequested {
            finalResult.cancelled = true
            finalResult.success = false
            finalResult.error = finalResult.error ?? "child cancelled"
        }
        if !child.parentTornDown,
           let promptID = child.request.parentPromptID,
           !promptID.isEmpty {
            recordUsage(
                parentSessionID: child.request.parentSessionID,
                promptID: promptID,
                childID: requestID,
                tokens: finalResult.tokensUsed
            )
        }
        let summary = OpenGrokChildSummary(request: child.request, state: finalResult.cancelled ? "cancelled" : (finalResult.success ? "completed" : "failed"), result: finalResult)
        completed[requestID] = summary
        completedOrder.removeAll { $0 == requestID }
        completedOrder.append(requestID)
        while completedOrder.count > Self.maxCompletedEntries {
            let oldest = completedOrder.removeFirst()
            completed.removeValue(forKey: oldest)
        }
        guard child.request.surfaceCompletion else { return }
        let suppress = suppressedAutoWakeSessions.contains(child.request.parentSessionID)
        completions.append(OpenGrokCompletion(parentSessionID: child.request.parentSessionID, childID: requestID, result: finalResult, autoWakeSuppressed: suppress))
        if completions.count > Self.maxCompletionEntries { completions.removeFirst(completions.count - Self.maxCompletionEntries) }
    }

    private func scopeKey(sessionID: String, promptID: String) -> String { "\(sessionID)\n\(promptID)" }

    // MARK: - Mailbox operations

    /// Roster of the calling agent's collaboration team: the root first, then
    /// every child of that team sorted by agent id.
    ///
    /// Mirrors Rust `SubagentCoordinator::list_agents`
    /// (task/coordinator.rs:536-593). Rust reports `pending`, `active`, and
    /// `completed` children separately; this coordinator has no distinct
    /// pending phase — `spawn` publishes into `active` immediately — so the
    /// pending rows have no Swift counterpart. Task metadata is retained on
    /// the request so running and completed rows expose the same labels.
    /// Marked `async` even though the actor body never suspends: the
    /// signature must be IDENTICAL to the `AgentMailboxBackend` requirement.
    /// With a synchronous member, the protocol extension's no-backend
    /// default (empty roster) is also visible on the concrete type, and
    /// Swift prefers the nonisolated-async extension overload at direct
    /// call sites — every direct `listAgents` call silently returned an
    /// empty roster (AGENTS.md §3; caught by the pre-existing roster test).
    public func listAgents(identity: AgentMailboxIdentity) async -> ListAgentsOutput {
        var agents = [
            AgentRosterEntry(
                agentID: identity.teamScopeID,
                isRoot: true,
                status: "running",
                description: "Root agent"
            )
        ]
        let scope = identity.teamScopeID
        var children: [AgentRosterEntry] = active.values
            .filter { $0.request.parentSessionID == scope }
            .map { child in
                AgentRosterEntry(
                    agentID: child.request.id,
                    isRoot: false,
                    status: "running",
                    subagentType: child.request.subagentType,
                    description: child.request.description,
                    resumedFrom: child.request.resumeFrom,
                    worktreePath: child.request.worktreePath
                )
            }
        children.append(contentsOf: completed.values
            .filter { $0.request.parentSessionID == scope }
            .map { summary in
                AgentRosterEntry(
                    agentID: summary.request.id,
                    isRoot: false,
                    status: summary.state,
                    subagentType: summary.request.subagentType,
                    description: summary.request.description,
                    resumedFrom: summary.request.resumeFrom,
                    worktreePath: summary.request.worktreePath
                )
            })
        children.sort { $0.agentID < $1.agentID }
        agents.append(contentsOf: children)
        return ListAgentsOutput(teamScopeID: scope, agents: agents)
    }

    /// Resolve a model-supplied target to a team member id.
    ///
    /// Mirrors Rust `resolve_message_target` (task/coordinator.rs:595-635):
    /// `"root"` (case-insensitive) and the scope id both name the root, a
    /// self-send is rejected, and anything else must belong to this team.
    private func resolveMessageTarget(
        identity: AgentMailboxIdentity,
        target rawTarget: String
    ) throws -> String {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentMailboxError.emptyTarget }
        let target = (trimmed.lowercased() == "root" || trimmed == identity.teamScopeID)
            ? identity.teamScopeID
            : trimmed
        if target == identity.agentID { throw AgentMailboxError.selfSend }
        if target == identity.teamScopeID { return target }
        let belongsToTeam =
            active[target]?.request.parentSessionID == identity.teamScopeID
            || completed[target]?.request.parentSessionID == identity.teamScopeID
        guard belongsToTeam else {
            throw AgentMailboxError.unknownTarget(
                target: target,
                teamScopeID: identity.teamScopeID
            )
        }
        return target
    }

    /// Deliver or queue one peer message.
    ///
    /// Mirrors Rust `send_agent_message` (task/coordinator.rs:637-700): a
    /// parked `wait_agent` takes the message directly, a follow-up first tries
    /// the host's live-delivery hook, and everything else lands in the
    /// recipient's mailbox for the next `wait_agent` to drain.
    public func sendAgentMessage(
        identity: AgentMailboxIdentity,
        target rawTarget: String,
        message: AgentMailboxMessage
    ) async throws -> AgentMessageSendOutput {
        guard message.teamScopeID == identity.teamScopeID,
              message.fromAgentID == identity.agentID
        else { throw AgentMailboxError.identityMismatch }

        let target = try resolveMessageTarget(identity: identity, target: rawTarget)
        var stamped = message
        stamped.toAgentID = target

        if target != identity.teamScopeID,
           completed[target]?.request.parentSessionID == identity.teamScopeID {
            throw AgentMailboxError.targetFinished(target)
        }

        let key = MailboxKey(teamScopeID: identity.teamScopeID, agentID: target)
        let status: AgentMessageDeliveryStatus
        if let waiter = mailboxWaiters.removeValue(forKey: key) {
            waiter.resume(WaitAgentMessagesOutput(messages: [stamped], timedOut: false))
            status = .delivered
        } else if stamped.kind.wakesRecipient {
            if await deliverFollowup(target, stamped) {
                status = .delivered
            } else if let waiter = mailboxWaiters.removeValue(forKey: key) {
                // The await above is a reentrancy window Rust does not have
                // (its hook is a sync channel send): a `wait_agent` that
                // parked during it would otherwise sit beside a queued
                // message forever. Hand the message to that waiter instead.
                waiter.resume(WaitAgentMessagesOutput(messages: [stamped], timedOut: false))
                status = .delivered
            } else if target == identity.teamScopeID || active[target] != nil {
                // Rust queues an undelivered follow-up only for a target still
                // in `pending`. This coordinator has no pending phase, so the
                // equivalent "known to the team but not yet holding a live
                // turn" set is the root plus the active children.
                try enqueue(key: key, message: stamped)
                status = .queued
            } else {
                throw AgentMailboxError.targetUnavailable(target)
            }
        } else {
            try enqueue(key: key, message: stamped)
            status = .queued
        }

        onAgentMessage(stamped, status)
        return AgentMessageSendOutput(
            messageID: stamped.messageID,
            targetAgentID: target,
            status: status
        )
    }

    /// Mirrors Rust `enqueue_agent_message` (task/coordinator.rs:702-716).
    private func enqueue(key: MailboxKey, message: AgentMailboxMessage) throws {
        var mailbox = mailboxes[key] ?? []
        guard mailbox.count < agentMailboxMaxQueuedMessages else {
            throw AgentMailboxError.mailboxFull
        }
        mailbox.append(message)
        mailboxes[key] = mailbox
    }

    /// Drain this agent's inbox, parking for `timeoutMS` when it is empty.
    ///
    /// Mirrors Rust `wait_agent_messages` (task/coordinator.rs:718-763):
    /// queued messages return immediately (up to 20, FIFO), `timeout_ms == 0`
    /// is a non-blocking poll, and a second waiter for the same mailbox
    /// displaces the first, which returns empty and *not* timed out.
    public func waitAgentMessages(
        identity: AgentMailboxIdentity,
        timeoutMS: UInt64
    ) async -> WaitAgentMessagesOutput {
        let key = MailboxKey(identity)
        if var mailbox = mailboxes[key], !mailbox.isEmpty {
            let drained = Array(mailbox.prefix(agentMailboxMaxDrainMessages))
            mailbox.removeFirst(drained.count)
            if mailbox.isEmpty {
                mailboxes.removeValue(forKey: key)
            } else {
                mailboxes[key] = mailbox
            }
            return WaitAgentMessagesOutput(messages: drained, timedOut: false)
        }
        if timeoutMS == 0 {
            return WaitAgentMessagesOutput(messages: [], timedOut: true)
        }

        nextWaiterToken &+= 1
        let token = nextWaiterToken
        // A newly parked waiter displaces the previous one, which returns empty
        // and not timed out (Rust coordinator.rs:753-762).
        mailboxWaiters.removeValue(forKey: key)?
            .resume(WaitAgentMessagesOutput(messages: [], timedOut: false))
        let expiry = expireTask(key: key, token: token, timeoutMS: timeoutMS)

        let output: WaitAgentMessagesOutput = await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            mailboxWaiters[key] = MailboxWaiter(token: token) { output in
                box.resume(output)
            }
        }
        expiry.cancel()
        return output
    }

    /// Arm the deadline that closes a parked waiter as timed out. Rust folds
    /// the deadline into the coordinator's `select` loop
    /// (task/coordinator.rs:1142, 1189-1202); the Swift actor uses a detached
    /// sleep that no-ops when the waiter has already been answered.
    @discardableResult
    private func expireTask(key: MailboxKey, token: UInt64, timeoutMS: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutMS * 1_000_000)
            await self?.expireWaiter(key: key, token: token)
        }
    }

    private func expireWaiter(key: MailboxKey, token: UInt64) {
        guard let waiter = mailboxWaiters[key], waiter.token == token else { return }
        mailboxWaiters.removeValue(forKey: key)
        waiter.resume(WaitAgentMessagesOutput(messages: [], timedOut: true))
    }

    /// Queued (undrained) message count for a mailbox — test/inspection seam.
    public func queuedMessageCount(identity: AgentMailboxIdentity) -> Int {
        mailboxes[MailboxKey(identity)]?.count ?? 0
    }

    /// Number of `wait_agent` calls currently parked — test/inspection seam.
    public var parkedWaiterCount: Int { mailboxWaiters.count }
}

/// One-shot wrapper so a `CheckedContinuation` can be stored in the actor's
/// waiter map and resumed from whichever path answers first.
private final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<WaitAgentMessagesOutput, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<WaitAgentMessagesOutput, Never>) {
        self.continuation = continuation
    }

    func resume(_ output: WaitAgentMessagesOutput) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: output)
    }
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 { addingReportingOverflow(value).overflow ? UInt64.max : self + value }
}
