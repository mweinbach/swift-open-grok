import Foundation

public enum OpenGrokChildOwner: String, Codable, Sendable, Hashable {
    case task
    case swarm
    case workflow
    case antigravity
}

public enum OpenGrokChildCancelTarget: Sendable, Hashable {
    case childID(String)
    case parentSession(String)
    case workflowRun(String)
}

public struct OpenGrokChildRequest: Codable, Sendable, Hashable {
    public var id: String
    public var parentSessionID: String
    public var parentPromptID: String?
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
    }

    private var active: [String: ActiveChild] = [:]
    private var completed: [String: OpenGrokChildSummary] = [:]
    private var completedOrder: [String] = []
    private var completions: [OpenGrokCompletion] = []
    private var blockedSessions = Set<String>()
    private var suppressedAutoWakeSessions = Set<String>()
    private var usage: [String: UInt64] = [:]
    private var usageNotApplied = Set<String>()

    public init() {}

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
        active[request.id] = ActiveChild(request: request, task: task, cancellationRequested: false)
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
            ids = active.values.filter { $0.request.parentSessionID == sessionID }.map { $0.request.id }
            blockedSessions.insert(sessionID)
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
        let ids = active.values.filter { $0.request.parentSessionID == sessionID }.map { $0.request.id }
        for id in ids {
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
            if matchesSession && !suppressIDs.contains(completion.childID) {
                selected.append(completion)
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
        usage[scopeKey(sessionID: parentSessionID, promptID: promptID)] = (usage[scopeKey(sessionID: parentSessionID, promptID: promptID)] ?? 0).saturatingAdd(tokens)
    }

    public func foldUsage(parentSessionID: String, promptID: String, childIDs: [String]) -> OpenGrokUsageFold {
        let key = scopeKey(sessionID: parentSessionID, promptID: promptID)
        return OpenGrokUsageFold(parentSessionID: parentSessionID, promptID: promptID, tokensUsed: usage[key] ?? 0, childIDs: childIDs.sorted())
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
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 { addingReportingOverflow(value).overflow ? UInt64.max : self + value }
}
