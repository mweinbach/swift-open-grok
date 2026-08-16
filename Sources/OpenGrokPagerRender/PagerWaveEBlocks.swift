import Foundation

public enum PagerPromptKind: Sendable, Equatable, Hashable {
    case standard
    case bash
    case cron
    case interjection
    case skill

    public var prefix: String {
        switch self {
        case .standard: return "❯ "
        case .bash: return "! "
        case .cron: return "◷ "
        case .interjection: return "↳ "
        case .skill: return "◇ "
        }
    }
}

public enum PagerWelcomeAuthPhase: Sendable, Equatable, Hashable {
    case signingIn
    case trust
    case starting
    case failed
}

public struct PagerWelcomeAuthState: Sendable, Equatable, Hashable {
    public var providerName: String
    public var phase: PagerWelcomeAuthPhase
    public var url: String?
    public var deviceCode: String?
    public var rawURLMode: Bool
    public var message: String?

    public init(
        providerName: String,
        phase: PagerWelcomeAuthPhase,
        url: String? = nil,
        deviceCode: String? = nil,
        rawURLMode: Bool = false,
        message: String? = nil
    ) {
        self.providerName = providerName
        self.phase = phase
        self.url = url
        self.deviceCode = deviceCode
        self.rawURLMode = rawURLMode
        self.message = message
    }

    public static func deviceCode(from url: String) -> String? {
        guard let query = url.split(separator: "?", maxSplits: 1).dropFirst().first else {
            return nil
        }
        guard let value = query.split(separator: "&").compactMap({ field -> Substring? in
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "user_code" else { return nil }
            return parts[1]
        }).first,
              !value.isEmpty,
              value.allSatisfy({ character in
                  character.isASCII
                      && (character.isLetter || character.isNumber || character == "-")
              })
        else { return nil }
        return String(value)
    }
}

public enum PagerActivityState: Sendable, Equatable, Hashable {
    case pending
    case queued
    case running
    case waiting
    case succeeded
    case failed
    case cancelled
}

public enum PagerHookPhase: String, Sendable, Equatable, Hashable {
    case pre
    case post
    case stop
}

public struct PagerHookRun: Sendable, Equatable, Hashable {
    public var name: String
    public var phase: PagerHookPhase
    public var state: PagerActivityState
    public var output: String?

    public init(
        name: String,
        phase: PagerHookPhase,
        state: PagerActivityState,
        output: String? = nil
    ) {
        self.name = name
        self.phase = phase
        self.state = state
        self.output = output
    }
}

public enum PagerLifecycleKind: String, Sendable, Equatable, Hashable {
    case sessionStart = "session_start"
    case userPromptSubmit = "user_prompt_submit"
}

public struct PagerLifecycleBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var kind: PagerLifecycleKind
    public var state: PagerActivityState
    public var hooks: [PagerHookRun]
    public var isExpanded: Bool

    public init(
        id: String,
        kind: PagerLifecycleKind,
        state: PagerActivityState,
        hooks: [PagerHookRun] = [],
        isExpanded: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.hooks = hooks
        self.isExpanded = isExpanded
    }
}

public enum PagerSessionEventKind: Sendable, Equatable, Hashable {
    case turnCompleted(elapsed: TimeInterval?)
    case turnCancelled(elapsed: TimeInterval?)
    case turnHalted(elapsed: TimeInterval?)
    case turnFailed(error: String, elapsed: TimeInterval?)
    case compactionStarted(percentage: Int)
    case compactionCompleted(tokensBefore: Int, tokensAfter: Int, elapsedMilliseconds: Int)
    case compactionFailed(error: String)
    case compactionCancelled
    case retryFailed(error: String, errorType: String)
    case reauthRequired
    case contextTooLarge
    case compactCompleted(elapsed: TimeInterval?)
    case hookAnnotation(message: String)
    case modelUnavailable(previousModelID: String, newModelID: String, reason: String)
    case memorySaved(path: String, trigger: String)
    case goalCompleted(elapsed: TimeInterval?)
    case recap(summary: String?, auto: Bool)
}

public struct PagerSessionEventBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var event: PagerSessionEventKind
    public var isExpanded: Bool
    public var promptID: String?
    public var stopHooks: [PagerHookRun]

    public init(
        id: String,
        event: PagerSessionEventKind,
        isExpanded: Bool = false,
        promptID: String? = nil,
        stopHooks: [PagerHookRun] = []
    ) {
        self.id = id
        self.event = event
        self.isExpanded = isExpanded
        self.promptID = promptID
        self.stopHooks = stopHooks
    }

    public var isRecap: Bool {
        if case .recap = event { return true }
        return false
    }
}

public enum PagerBackgroundTaskKind: String, Sendable, Equatable, Hashable {
    case process
    case monitor
    case scheduled
}

public struct PagerBackgroundTaskBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var kind: PagerBackgroundTaskKind
    public var title: String
    public var state: PagerActivityState
    public var outputTail: String?
    public var exitCode: Int?
    public var duration: TimeInterval?

    public init(
        id: String,
        kind: PagerBackgroundTaskKind,
        title: String,
        state: PagerActivityState,
        outputTail: String? = nil,
        exitCode: Int? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.outputTail = outputTail
        self.exitCode = exitCode
        self.duration = duration
    }
}

public struct PagerSubagentBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var state: PagerActivityState
    public var activity: String?
    public var turnCount: Int
    public var toolCount: Int
    public var duration: TimeInterval?
    public var outcome: String?
    public var isExpanded: Bool

    public init(
        id: String,
        label: String,
        state: PagerActivityState,
        activity: String? = nil,
        turnCount: Int = 0,
        toolCount: Int = 0,
        duration: TimeInterval? = nil,
        outcome: String? = nil,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.label = label
        self.state = state
        self.activity = activity
        self.turnCount = turnCount
        self.toolCount = toolCount
        self.duration = duration
        self.outcome = outcome
        self.isExpanded = isExpanded
    }
}

public struct PagerSwarmMember: Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var state: PagerActivityState
    public var activity: String?
    public var turnCount: Int
    public var toolCount: Int
    public var duration: TimeInterval?
    public var outcome: String?

    public init(
        id: String,
        label: String,
        state: PagerActivityState,
        activity: String? = nil,
        turnCount: Int = 0,
        toolCount: Int = 0,
        duration: TimeInterval? = nil,
        outcome: String? = nil
    ) {
        self.id = id
        self.label = label
        self.state = state
        self.activity = activity
        self.turnCount = turnCount
        self.toolCount = toolCount
        self.duration = duration
        self.outcome = outcome
    }
}

public struct PagerSwarmBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var objective: String
    public var state: PagerActivityState
    public var members: [PagerSwarmMember]
    public var outcome: String?
    public var isExpanded: Bool

    public init(
        id: String,
        objective: String,
        state: PagerActivityState,
        members: [PagerSwarmMember] = [],
        outcome: String? = nil,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.objective = objective
        self.state = state
        self.members = members
        self.outcome = outcome
        self.isExpanded = isExpanded
    }
}

public struct PagerWorkflowPhase: Sendable, Equatable, Hashable {
    public var label: String
    public var state: PagerActivityState

    public init(label: String, state: PagerActivityState) {
        self.label = label
        self.state = state
    }
}

public struct PagerWorkflowBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var objective: String
    public var state: PagerActivityState
    public var phases: [PagerWorkflowPhase]
    public var agentCount: Int
    public var outcome: String?
    public var isExpanded: Bool

    public init(
        id: String,
        name: String,
        objective: String,
        state: PagerActivityState,
        phases: [PagerWorkflowPhase] = [],
        agentCount: Int = 0,
        outcome: String? = nil,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.objective = objective
        self.state = state
        self.phases = phases
        self.agentCount = agentCount
        self.outcome = outcome
        self.isExpanded = isExpanded
    }
}

public struct PagerBtwBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var question: String
    public var answer: String?
    public var isExpanded: Bool

    public init(id: String, question: String, answer: String? = nil, isExpanded: Bool = true) {
        self.id = id
        self.question = question
        self.answer = answer
        self.isExpanded = isExpanded
    }
}

public enum PagerContextCategory: String, Sendable, Equatable, Hashable, CaseIterable {
    case system
    case messages
    case reasoning
    case free
    case toolDefinitions = "tools"
}

public struct PagerContextUsage: Sendable, Equatable, Hashable {
    public var category: PagerContextCategory
    public var tokens: Int

    public init(category: PagerContextCategory, tokens: Int) {
        self.category = category
        self.tokens = max(0, tokens)
    }
}

public struct PagerContextBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var totalTokens: Int
    public var rows: [PagerContextUsage]

    public init(id: String, totalTokens: Int, rows: [PagerContextUsage]) {
        self.id = id
        self.totalTokens = max(0, totalTokens)
        self.rows = rows
    }
}

public enum PagerUsageProvider: String, Sendable, Equatable, Hashable {
    case xai = "xAI"
    case codex = "Codex"
    case antigravity = "Antigravity"
}

public struct PagerUsageSection: Sendable, Equatable, Hashable {
    public var provider: PagerUsageProvider
    public var used: Double
    public var limit: Double?
    public var unit: String
    public var resetDescription: String?
    public var isAuthoritative: Bool

    public init(
        provider: PagerUsageProvider,
        used: Double,
        limit: Double? = nil,
        unit: String = "credits",
        resetDescription: String? = nil,
        isAuthoritative: Bool = true
    ) {
        self.provider = provider
        self.used = max(0, used)
        self.limit = limit.map { max(0, $0) }
        self.unit = unit
        self.resetDescription = resetDescription
        self.isAuthoritative = isAuthoritative
    }
}

public struct PagerUsageBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var sections: [PagerUsageSection]

    public init(id: String, sections: [PagerUsageSection]) {
        self.id = id
        self.sections = sections
    }
}

public enum PagerCreditLimitAction: String, Sendable, Equatable, Hashable {
    case enablePayAsYouGo = "Enable PAYG"
    case increasePayAsYouGoLimit = "Increase PAYG Limit"
    case purchaseCredits = "Purchase Credits"
}

public struct PagerCreditLimitBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var action: PagerCreditLimitAction
    public var message: String
    public var accountURL: String

    public init(id: String, action: PagerCreditLimitAction, message: String, accountURL: String) {
        self.id = id
        self.action = action
        self.message = message
        self.accountURL = accountURL
    }
}

public struct PagerPlanBlock: Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var body: String
    public var comments: [Int: String]
    public var isExpanded: Bool

    public init(
        id: String,
        title: String = "Plan",
        body: String,
        comments: [Int: String] = [:],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.comments = comments
        self.isExpanded = isExpanded
    }
}

public enum PagerTranscriptBlock: Sendable, Equatable, Hashable {
    case sessionEvent(PagerSessionEventBlock)
    case lifecycle(PagerLifecycleBlock)
    case backgroundTask(PagerBackgroundTaskBlock)
    case subagent(PagerSubagentBlock)
    case swarm(PagerSwarmBlock)
    case workflow(PagerWorkflowBlock)
    case btw(PagerBtwBlock)
    case context(PagerContextBlock)
    case usage(PagerUsageBlock)
    case creditLimit(PagerCreditLimitBlock)
    case plan(PagerPlanBlock)

    public var stableID: String {
        switch self {
        case .sessionEvent(let block): return block.id
        case .lifecycle(let block): return block.id
        case .backgroundTask(let block): return block.id
        case .subagent(let block): return block.id
        case .swarm(let block): return block.id
        case .workflow(let block): return block.id
        case .btw(let block): return block.id
        case .context(let block): return block.id
        case .usage(let block): return block.id
        case .creditLimit(let block): return block.id
        case .plan(let block): return block.id
        }
    }

    var isGroupable: Bool {
        switch self {
        case .sessionEvent(let block): return !block.isRecap
        case .lifecycle, .backgroundTask: return true
        case .subagent, .swarm, .workflow, .btw, .context, .usage, .creditLimit, .plan:
            return false
        }
    }

    var isCollapsed: Bool {
        switch self {
        case .sessionEvent(let block): return !block.isExpanded
        case .lifecycle(let block): return !block.isExpanded
        case .backgroundTask: return true
        case .subagent(let block): return !block.isExpanded
        case .swarm(let block): return !block.isExpanded
        case .workflow(let block): return !block.isExpanded
        case .btw(let block): return !block.isExpanded
        case .plan(let block): return !block.isExpanded
        case .context, .usage, .creditLimit: return false
        }
    }

    public var isFoldable: Bool {
        switch self {
        case .sessionEvent(let block): return block.isRecap
        case .lifecycle(let block): return !block.hooks.isEmpty
        case .subagent, .swarm, .workflow, .btw, .plan: return true
        case .backgroundTask, .context, .usage, .creditLimit: return false
        }
    }

    public var isRunning: Bool {
        switch self {
        case .sessionEvent(let block):
            switch block.event {
            case .compactionStarted: return true
            case .recap(let summary, _): return summary == nil
            default: return false
            }
        case .lifecycle(let block): return block.state == .pending || block.state == .running
        case .backgroundTask(let block):
            return block.state == .pending || block.state == .queued || block.state == .running || block.state == .waiting
        case .subagent(let block):
            return block.state == .pending || block.state == .queued || block.state == .running || block.state == .waiting
        case .swarm(let block):
            return block.state == .pending || block.state == .queued || block.state == .running || block.state == .waiting
        case .workflow(let block):
            return block.state == .pending || block.state == .queued || block.state == .running || block.state == .waiting
        case .btw(let block): return block.answer == nil
        case .context, .usage, .creditLimit, .plan: return false
        }
    }
}

public extension PagerTranscriptBlock {
    var displayTitle: String {
        switch self {
        case .sessionEvent(let block):
            if case .recap = block.event { return "Recap" }
            return "Session Event"
        case .lifecycle: return "Lifecycle"
        case .backgroundTask: return "Background Task"
        case .subagent: return "Subagent"
        case .swarm: return "Swarm"
        case .workflow(let block): return "Workflow: \(block.name)"
        case .btw: return "BTW"
        case .context: return "Context"
        case .usage: return "Usage"
        case .creditLimit(let block): return block.action.rawValue
        case .plan(let block): return block.title
        }
    }

    var plainText: String {
        switch self {
        case .sessionEvent(let block):
            return block.plainText
        case .lifecycle(let block):
            var lines = ["Lifecycle: \(block.kind.rawValue) [\(block.state)]"]
            lines.append(contentsOf: block.hooks.map { hook in
                let output = hook.output.map { ": \($0)" } ?? ""
                return "\(hook.phase.rawValue) \(hook.name) [\(hook.state)]\(output)"
            })
            return lines.joined(separator: "\n")
        case .backgroundTask(let block):
            var lines = ["Background task: \(block.title) [\(block.state)]"]
            if let outputTail = block.outputTail, !outputTail.isEmpty { lines.append(outputTail) }
            if let exitCode = block.exitCode { lines.append("Exit code: \(exitCode)") }
            return lines.joined(separator: "\n")
        case .subagent(let block):
            return [
                "Subagent: \(block.label) [\(block.state)]",
                block.activity,
                block.outcome
            ].compactMap { $0 }.joined(separator: "\n")
        case .swarm(let block):
            var lines = ["Swarm: \(block.objective) [\(block.state)]"]
            lines.append(contentsOf: block.members.map { member in
                let activity = member.activity.map { ": \($0)" } ?? ""
                return "\(member.label) [\(member.state)]\(activity)"
            })
            if let outcome = block.outcome, !outcome.isEmpty { lines.append(outcome) }
            return lines.joined(separator: "\n")
        case .workflow(let block):
            var lines = ["Workflow \(block.name): \(block.objective) [\(block.state)]"]
            lines.append(contentsOf: block.phases.map { "\($0.label) [\($0.state)]" })
            if let outcome = block.outcome, !outcome.isEmpty { lines.append(outcome) }
            return lines.joined(separator: "\n")
        case .btw(let block):
            return ["BTW: \(block.question)", block.answer].compactMap { $0 }.joined(separator: "\n")
        case .context(let block):
            var lines = ["Context: \(block.totalTokens) tokens"]
            lines.append(contentsOf: block.rows.map { "\($0.category.rawValue): \($0.tokens)" })
            return lines.joined(separator: "\n")
        case .usage(let block):
            return block.sections.map { section in
                let limit = section.limit.map { " / \($0)" } ?? ""
                let reset = section.resetDescription.map { " (\($0))" } ?? ""
                return "\(section.provider.rawValue): \(section.used)\(limit) \(section.unit)\(reset)"
            }.joined(separator: "\n")
        case .creditLimit(let block):
            return "\(block.action.rawValue)\n\(block.message)\n\(block.accountURL)"
        case .plan(let block):
            return block.body
        }
    }

    func settingCollapsed(_ collapsed: Bool) -> PagerTranscriptBlock {
        switch self {
        case .sessionEvent(var block):
            guard block.isRecap else { return self }
            block.isExpanded = !collapsed
            return .sessionEvent(block)
        case .lifecycle(var block):
            guard !block.hooks.isEmpty else { return self }
            block.isExpanded = !collapsed
            return .lifecycle(block)
        case .subagent(var block):
            block.isExpanded = !collapsed
            return .subagent(block)
        case .swarm(var block):
            block.isExpanded = !collapsed
            return .swarm(block)
        case .workflow(var block):
            block.isExpanded = !collapsed
            return .workflow(block)
        case .btw(var block):
            block.isExpanded = !collapsed
            return .btw(block)
        case .plan(var block):
            block.isExpanded = !collapsed
            return .plan(block)
        case .backgroundTask, .context, .usage, .creditLimit:
            return self
        }
    }
}

private extension PagerSessionEventBlock {
    var plainText: String {
        let summary: String
        switch event {
        case .turnCompleted(let elapsed): summary = "Turn completed\(elapsedSuffix(elapsed))"
        case .turnCancelled(let elapsed): summary = "Turn cancelled\(elapsedSuffix(elapsed))"
        case .turnHalted(let elapsed): summary = "Turn halted\(elapsedSuffix(elapsed))"
        case .turnFailed(let error, let elapsed): summary = "Turn failed\(elapsedSuffix(elapsed)): \(error)"
        case .compactionStarted(let percentage): summary = "Compaction started at \(percentage)%"
        case .compactionCompleted(let before, let after, let milliseconds):
            summary = "Compaction completed: \(before) -> \(after) tokens in \(milliseconds)ms"
        case .compactionFailed(let error): summary = "Compaction failed: \(error)"
        case .compactionCancelled: summary = "Compaction cancelled"
        case .retryFailed(let error, let errorType): summary = "Retry failed (\(errorType)): \(error)"
        case .reauthRequired: summary = "Authentication required"
        case .contextTooLarge: summary = "Context too large"
        case .compactCompleted(let elapsed): summary = "Compact completed\(elapsedSuffix(elapsed))"
        case .hookAnnotation(let message): summary = message
        case .modelUnavailable(let previous, let next, let reason):
            summary = "Model unavailable: \(previous) -> \(next): \(reason)"
        case .memorySaved(let path, let trigger): summary = "Memory saved: \(path) (\(trigger))"
        case .goalCompleted(let elapsed): summary = "Goal completed\(elapsedSuffix(elapsed))"
        case .recap(let summaryText, let auto):
            summary = [auto ? "Automatic recap" : "Recap", summaryText].compactMap { $0 }.joined(separator: "\n")
        }
        guard !stopHooks.isEmpty else { return summary }
        let hookLines = stopHooks.map { hook in
            let output = hook.output.map { ": \($0)" } ?? ""
            return "stop \(hook.name) [\(hook.state)]\(output)"
        }
        return ([summary] + hookLines).joined(separator: "\n")
    }

    func elapsedSuffix(_ elapsed: TimeInterval?) -> String {
        elapsed.map { " in \($0)s" } ?? ""
    }
}

public enum PagerTodoStatus: String, Sendable, Equatable, Hashable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled
}

public struct PagerTodoItem: Sendable, Equatable, Hashable {
    public var id: String
    public var content: String
    public var status: PagerTodoStatus

    public init(id: String, content: String, status: PagerTodoStatus) {
        self.id = id
        self.content = content
        self.status = status
    }
}

public struct PagerTodoPane: Sendable, Equatable, Hashable {
    public var items: [PagerTodoItem]
    public var showCompleted: Bool
    public var forceVisible: Bool
    public var isMinimal: Bool

    public init(
        items: [PagerTodoItem],
        showCompleted: Bool = true,
        forceVisible: Bool = false,
        isMinimal: Bool = false
    ) {
        self.items = items
        self.showCompleted = showCompleted
        self.forceVisible = forceVisible
        self.isMinimal = isMinimal
    }

    public var visibleItems: [PagerTodoItem] {
        let filtered = showCompleted ? items : items.filter { $0.status != .completed }
        return isMinimal ? Array(filtered.prefix(8)) : filtered
    }

    public func desiredHeight(viewHeight: Int) -> Int {
        let rows = visibleItems.count
        if rows == 0 && !forceVisible { return 0 }
        let cap = isMinimal ? 8 : max(1, viewHeight / 3)
        return min(max(rows, forceVisible ? 1 : 0), cap)
    }
}

public struct PagerCreditStatus: Sendable, Equatable, Hashable {
    public var provider: PagerUsageProvider
    public var used: Double
    public var limit: Double

    public init(provider: PagerUsageProvider, used: Double, limit: Double) {
        self.provider = provider
        self.used = max(0, used)
        self.limit = max(0, limit)
    }

    public var fractionUsed: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }
}

public struct PagerScrollDebugOverlay: Sendable, Equatable, Hashable {
    public var rawDelta: Int
    public var normalizedDelta: Int
    public var scrollOffset: Int
    public var maximumOffset: Int
    public var followingTail: Bool

    public init(
        rawDelta: Int,
        normalizedDelta: Int,
        scrollOffset: Int,
        maximumOffset: Int,
        followingTail: Bool
    ) {
        self.rawDelta = rawDelta
        self.normalizedDelta = normalizedDelta
        self.scrollOffset = max(0, scrollOffset)
        self.maximumOffset = max(0, maximumOffset)
        self.followingTail = followingTail
    }
}
