import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public let goalClassifierStallThreshold: UInt32 = 2
public let goalStrategistCapBonus: UInt32 = 3
public let goalStrategistStallThreshold: UInt32 = goalClassifierStallThreshold + goalStrategistCapBonus
public let goalHistoryMax = 64
private let goalVerifierPanelMaxBytes = 512 * 1024

public enum GoalPhase: String, Codable, Sendable, Hashable {
    case idle = "Idle"
    case planning = "Planning"
    case executing = "Executing"

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "Idle", "idle": self = .idle
        case "Planning", "planning": self = .planning
        case "Executing", "executing": self = .executing
        default: self = .idle
        }
    }
}

public enum GoalStatus: String, Codable, Sendable, Hashable {
    case active = "active"
    case userPaused = "user_paused"
    case backOffPaused = "back_off_paused"
    case noProgressPaused = "no_progress_paused"
    case infraPaused = "infra_paused"
    case blocked = "blocked"
    case budgetLimited = "budget_limited"
    case complete = "complete"

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self.fromWireString(value)
    }

    public static func fromWireString(_ value: String) -> Self {
        switch value {
        case "active", "Active": return .active
        case "user_paused", "paused", "Paused": return .userPaused
        case "doom_loop_paused": return .userPaused
        case "back_off_paused", "BackOffPaused": return .backOffPaused
        case "no_progress_paused", "NoProgressPaused": return .noProgressPaused
        case "infra_paused", "InfraPaused": return .infraPaused
        case "blocked", "Blocked": return .blocked
        case "budget_limited", "BudgetLimited": return .budgetLimited
        case "complete", "Complete": return .complete
        default: return .userPaused
        }
    }

    public var isPaused: Bool {
        switch self {
        case .userPaused, .backOffPaused, .noProgressPaused, .infraPaused, .blocked:
            return true
        case .active, .budgetLimited, .complete:
            return false
        }
    }

    public var isTerminal: Bool {
        self == .complete || self == .budgetLimited
    }

    public var isResumable: Bool {
        isPaused
    }
}

public enum GoalPauseReason: Sendable, Hashable {
    case user
    case backOff
    case noProgress
    case verification
    case infra

    fileprivate var status: GoalStatus {
        switch self {
        case .user: return .userPaused
        case .backOff: return .backOffPaused
        case .noProgress: return .noProgressPaused
        case .verification: return .blocked
        case .infra: return .infraPaused
        }
    }

    fileprivate var historyDetail: String {
        switch self {
        case .user: return "user"
        case .backOff: return "back_off"
        case .noProgress: return "no_progress"
        case .verification: return "blocked"
        case .infra: return "infra"
        }
    }
}

public enum GoalClassifierVerdict: String, Codable, Sendable, Hashable {
    case achieved
    case notAchieved = "not_achieved"
}

public enum GoalEvent: String, Codable, Sendable, Hashable {
    case goalCreated = "goal_created"
    case planningStarted = "planning_started"
    case planningCompleted = "planning_completed"
    case planningFailed = "planning_failed"
    case workerStarted = "worker_started"
    case workerCompleted = "worker_completed"
    case workerFailed = "worker_failed"
    case contextRotated = "context_rotated"
    case goalPaused = "goal_paused"
    case goalResumed = "goal_resumed"
    case goalCompleted = "goal_completed"
    case goalCleared = "goal_cleared"
    case budgetExceeded = "budget_exceeded"
    case prematureStopDetected = "premature_stop_detected"
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct GoalRoleModel: Codable, Sendable, Hashable {
    public var model: String
    public var agentType: String

    private enum CodingKeys: String, CodingKey {
        case model
        case agentType = "agent_type"
    }

    public init(model: String, agentType: String) {
        self.model = model
        self.agentType = agentType
    }
}

public struct GoalHistoryEntry: Codable, Sendable, Hashable {
    public var timestamp: String
    public var event: GoalEvent
    public var detail: String?
    public var round: UInt32?
    public var tokensUsed: Int64?
    public var unmet: [String]

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case event
        case detail
        case round
        case tokensUsed = "tokens_used"
        case unmet
    }

    public init(
        timestamp: String,
        event: GoalEvent,
        detail: String? = nil,
        round: UInt32? = nil,
        tokensUsed: Int64? = nil,
        unmet: [String] = []
    ) {
        self.timestamp = timestamp
        self.event = event
        self.detail = detail
        self.round = round
        self.tokensUsed = tokensUsed
        self.unmet = unmet
    }

    public static func now(event: GoalEvent, detail: String? = nil, clock: () -> String = currentISO8601Timestamp) -> Self {
        Self(timestamp: clock(), event: event, detail: detail)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        event = try container.decodeIfPresent(GoalEvent.self, forKey: .event) ?? .unknown
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        round = try container.decodeIfPresent(UInt32.self, forKey: .round)
        tokensUsed = try container.decodeIfPresent(Int64.self, forKey: .tokensUsed)
        unmet = try container.decodeIfPresent([String].self, forKey: .unmet) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(round, forKey: .round)
        try container.encodeIfPresent(tokensUsed, forKey: .tokensUsed)
        if !unmet.isEmpty { try container.encode(unmet, forKey: .unmet) }
    }
}

private struct LenientGoalBool: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = false
            return
        }
        if let boolean = try? container.decode(Bool.self) {
            value = boolean
            return
        }
        if let string = try? container.decode(String.self) {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                value = true
                return
            case "false", "no", "0":
                value = false
                return
            default:
                break
            }
        }
        if let number = try? container.decode(Int64.self) {
            switch number {
            case 1:
                value = true
                return
            case 0:
                value = false
                return
            default:
                break
            }
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "expected a boolean (true/false, true/false, yes/no, 1/0, or 1/0)"
        ))
    }
}

public struct UpdateGoalInput: Codable, Sendable, Hashable {
    public var completed: Bool?
    public var message: String?
    public var blockedReason: String?

    private enum CodingKeys: String, CodingKey {
        case completed
        case message
        case blockedReason = "blocked_reason"
    }

    public init(completed: Bool? = nil, message: String? = nil, blockedReason: String? = nil) {
        self.completed = completed
        self.message = message
        self.blockedReason = blockedReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.completed) {
            completed = try container.decode(LenientGoalBool.self, forKey: .completed).value
        } else {
            completed = nil
        }
        message = try container.decodeIfPresent(String.self, forKey: .message)
        blockedReason = try container.decodeIfPresent(String.self, forKey: .blockedReason)
    }

    public func validate() throws {
        if completed == true, blockedReason != nil {
            throw GoalUpdateValidationError.completionAndBlockConflict
        }
        if let blockedReason, blockedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GoalUpdateValidationError.emptyBlockedReason
        }
    }

    public var summary: String {
        var parts: [String] = []
        if completed == true { parts.append("Goal marked complete") }
        if let blockedReason { parts.append("Goal blocked: \(blockedReason)") }
        if let message { parts.append(message) }
        return parts.isEmpty ? "Goal updated." : parts.joined(separator: ". ") + "."
    }
}

public typealias GoalUpdateRequest = UpdateGoalInput

public enum GoalUpdateValidationError: Error, Sendable, Hashable, CustomStringConvertible {
    case completionAndBlockConflict
    case emptyBlockedReason
    case nonActiveGoal

    public var description: String {
        switch self {
        case .completionAndBlockConflict:
            return "completed and blocked_reason cannot be used together"
        case .emptyBlockedReason:
            return "blocked_reason must contain non-whitespace text"
        case .nonActiveGoal:
            return "goal is not active"
        }
    }
}

public enum GoalUpdateOutcome: Sendable, Hashable {
    case accepted(summary: String)
    case blocked(summary: String)
    case completed(summary: String)
}

public struct GoalTokenBreakdown: Codable, Sendable, Hashable {
    public var modelID: String
    public var tokens: UInt64

    private enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case tokens
    }

    public init(modelID: String, tokens: UInt64) {
        self.modelID = modelID
        self.tokens = tokens
    }
}

public struct GoalTokenRecord: Codable, Sendable, Hashable {
    public var goalID: String?
    public var resumeAnchorCumulative: UInt64
    public var lastCumulativeReported: UInt64
    public var modelID: String?
    public var finished: Bool

    private enum CodingKeys: String, CodingKey {
        case goalID = "goal_id"
        case resumeAnchorCumulative = "resume_anchor_cumulative"
        case lastCumulativeReported = "last_cumulative_reported"
        case modelID = "model_id"
        case finished
    }

    public init(
        goalID: String?,
        resumeAnchorCumulative: UInt64,
        lastCumulativeReported: UInt64,
        modelID: String? = nil,
        finished: Bool = false
    ) {
        self.goalID = goalID
        self.resumeAnchorCumulative = resumeAnchorCumulative
        self.lastCumulativeReported = lastCumulativeReported
        self.modelID = modelID
        self.finished = finished
    }

    public var marginalTokens: UInt64 {
        lastCumulativeReported >= resumeAnchorCumulative
            ? lastCumulativeReported - resumeAnchorCumulative
            : 0
    }
}

public struct GoalOrchestration: Codable, Sendable, Hashable {
    public var goalID: String
    public var objective: String
    public var status: GoalStatus
    public var phase: GoalPhase
    public var tokenBudget: Int64?
    public var elapsedMS: UInt64
    public var createdAt: String
    public var currentSubagentID: String?
    public var currentSubagentRole: String?
    public var totalWorkerRounds: UInt32
    public var totalVerifyRounds: UInt32
    public var budgetLimitReported: Bool
    public var tokenBaseline: Int64
    public var tokensUsedHighWater: Int64
    public var parentTokensSpent: Int64
    public var lastSessionTokensSeen: Int64?
    public var history: [GoalHistoryEntry]
    public var pauseMessage: String?
    public var evaluatorBlockerKey: String?
    public var evaluatorBlockedStreak: UInt32
    public var verifierID: String
    public var classifierRunsAttempted: UInt32
    public var roundsSinceVerify: UInt32
    public var classifierMaxRuns: UInt32?
    public var lastClassifierVerdict: GoalClassifierVerdict?
    public var lastClassifierDetailsPath: String?
    public var lastClassifierAt: String?
    public var lastClassifierGaps: String?
    public var firstFinalResponse: String?
    public var skeptic0SessionID: String?
    public var skepticModelAssignment: [GoalRoleModel]
    public var lastGapFingerprint: String?
    public var classifierStallCount: UInt32
    public var consecutiveNotAchieved: UInt32
    public var lastStrategistFiredAt: UInt32
    public var strategistCapBonus: UInt32
    public var lastStrategyPath: String?
    public var lastStrategyRecommendation: String?
    public var changesBaselineCommit: String?
    public var planFile: String?
    public var planBaselineFile: String?

    public var scratchDirectoryReady: Bool
    public var liveSubagentTokens: UInt64
    public var liveTokensByModel: [GoalTokenBreakdown]
    public var liveContextWindow: UInt64
    public var liveContextPercent: UInt8
    public var liveTurnCount: UInt32
    public var liveToolCallCount: UInt32
    public var planningInFlight: Bool
    public var verifyingInFlight: Bool

    private enum CodingKeys: String, CodingKey {
        case goalID = "goal_id"
        case objective
        case status
        case phase
        case tokenBudget = "token_budget"
        case elapsedMS = "elapsed_ms"
        case createdAt = "created_at"
        case currentSubagentID = "current_subagent_id"
        case currentSubagentRole = "current_subagent_role"
        case totalWorkerRounds = "total_worker_rounds"
        case totalVerifyRounds = "total_verify_rounds"
        case tokenBaseline = "token_baseline"
        case tokensUsedHighWater = "tokens_used_high_water"
        case parentTokensSpent = "parent_tokens_spent"
        case lastSessionTokensSeen = "last_session_tokens_seen"
        case history
        case pauseMessage = "pause_message"
        case evaluatorBlockerKey = "evaluator_blocker_key"
        case evaluatorBlockedStreak = "evaluator_blocked_streak"
        case verifierID = "verifier_id"
        case classifierRunsAttempted = "classifier_runs_attempted"
        case roundsSinceVerify = "rounds_since_verify"
        case classifierMaxRuns = "classifier_max_runs"
        case lastClassifierVerdict = "last_classifier_verdict"
        case lastClassifierDetailsPath = "last_classifier_details_path"
        case lastClassifierAt = "last_classifier_at"
        case lastClassifierGaps = "last_classifier_gaps"
        case firstFinalResponse = "first_final_response"
        case skeptic0SessionID = "skeptic0_session_id"
        case skepticModelAssignment = "skeptic_model_assignment"
        case lastGapFingerprint = "last_gap_fingerprint"
        case classifierStallCount = "classifier_stall_count"
        case consecutiveNotAchieved = "consecutive_not_achieved"
        case lastStrategistFiredAt = "last_strategist_fired_at"
        case strategistCapBonus = "strategist_cap_bonus"
        case lastStrategyPath = "last_strategy_path"
        case lastStrategyRecommendation = "last_strategy_recommendation"
        case changesBaselineCommit = "changes_baseline_commit"
        case planFile = "plan_file"
        case planBaselineFile = "plan_baseline_file"
    }

    public init(
        goalID: String,
        objective: String,
        status: GoalStatus = .active,
        phase: GoalPhase = .idle,
        tokenBudget: Int64? = nil,
        elapsedMS: UInt64 = 0,
        createdAt: String,
        currentSubagentID: String? = nil,
        currentSubagentRole: String? = nil,
        totalWorkerRounds: UInt32 = 0,
        totalVerifyRounds: UInt32 = 0,
        budgetLimitReported: Bool = false,
        tokenBaseline: Int64 = 0,
        tokensUsedHighWater: Int64 = 0,
        parentTokensSpent: Int64 = 0,
        lastSessionTokensSeen: Int64? = nil,
        history: [GoalHistoryEntry] = [],
        pauseMessage: String? = nil,
        evaluatorBlockerKey: String? = nil,
        evaluatorBlockedStreak: UInt32 = 0,
        verifierID: String = generateVerifierID(),
        classifierRunsAttempted: UInt32 = 0,
        roundsSinceVerify: UInt32 = 0,
        classifierMaxRuns: UInt32? = nil,
        lastClassifierVerdict: GoalClassifierVerdict? = nil,
        lastClassifierDetailsPath: String? = nil,
        lastClassifierAt: String? = nil,
        lastClassifierGaps: String? = nil,
        firstFinalResponse: String? = nil,
        skeptic0SessionID: String? = nil,
        skepticModelAssignment: [GoalRoleModel] = [],
        lastGapFingerprint: String? = nil,
        classifierStallCount: UInt32 = 0,
        consecutiveNotAchieved: UInt32 = 0,
        lastStrategistFiredAt: UInt32 = 0,
        strategistCapBonus: UInt32 = 0,
        lastStrategyPath: String? = nil,
        lastStrategyRecommendation: String? = nil,
        changesBaselineCommit: String? = nil,
        planFile: String? = nil,
        planBaselineFile: String? = nil,
        scratchDirectoryReady: Bool = false,
        liveSubagentTokens: UInt64 = 0,
        liveTokensByModel: [GoalTokenBreakdown] = [],
        liveContextWindow: UInt64 = 0,
        liveContextPercent: UInt8 = 0,
        liveTurnCount: UInt32 = 0,
        liveToolCallCount: UInt32 = 0,
        planningInFlight: Bool = false,
        verifyingInFlight: Bool = false
    ) {
        self.goalID = goalID
        self.objective = objective
        self.status = status
        self.phase = phase
        self.tokenBudget = tokenBudget
        self.elapsedMS = elapsedMS
        self.createdAt = createdAt
        self.currentSubagentID = currentSubagentID
        self.currentSubagentRole = currentSubagentRole
        self.totalWorkerRounds = totalWorkerRounds
        self.totalVerifyRounds = totalVerifyRounds
        self.budgetLimitReported = budgetLimitReported
        self.tokenBaseline = tokenBaseline
        self.tokensUsedHighWater = tokensUsedHighWater
        self.parentTokensSpent = parentTokensSpent
        self.lastSessionTokensSeen = lastSessionTokensSeen
        self.history = history
        self.pauseMessage = pauseMessage
        self.evaluatorBlockerKey = evaluatorBlockerKey
        self.evaluatorBlockedStreak = evaluatorBlockedStreak
        self.verifierID = verifierID
        self.classifierRunsAttempted = classifierRunsAttempted
        self.roundsSinceVerify = roundsSinceVerify
        self.classifierMaxRuns = classifierMaxRuns
        self.lastClassifierVerdict = lastClassifierVerdict
        self.lastClassifierDetailsPath = lastClassifierDetailsPath
        self.lastClassifierAt = lastClassifierAt
        self.lastClassifierGaps = lastClassifierGaps
        self.firstFinalResponse = firstFinalResponse
        self.skeptic0SessionID = skeptic0SessionID
        self.skepticModelAssignment = skepticModelAssignment
        self.lastGapFingerprint = lastGapFingerprint
        self.classifierStallCount = classifierStallCount
        self.consecutiveNotAchieved = consecutiveNotAchieved
        self.lastStrategistFiredAt = lastStrategistFiredAt
        self.strategistCapBonus = strategistCapBonus
        self.lastStrategyPath = lastStrategyPath
        self.lastStrategyRecommendation = lastStrategyRecommendation
        self.changesBaselineCommit = changesBaselineCommit
        self.planFile = planFile
        self.planBaselineFile = planBaselineFile
        self.scratchDirectoryReady = scratchDirectoryReady
        self.liveSubagentTokens = liveSubagentTokens
        self.liveTokensByModel = liveTokensByModel
        self.liveContextWindow = liveContextWindow
        self.liveContextPercent = liveContextPercent
        self.liveTurnCount = liveTurnCount
        self.liveToolCallCount = liveToolCallCount
        self.planningInFlight = planningInFlight
        self.verifyingInFlight = verifyingInFlight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goalID = try container.decodeIfPresent(String.self, forKey: .goalID) ?? ""
        objective = try container.decodeIfPresent(String.self, forKey: .objective) ?? ""
        status = try container.decodeIfPresent(GoalStatus.self, forKey: .status) ?? .userPaused
        phase = try container.decodeIfPresent(GoalPhase.self, forKey: .phase) ?? .idle
        tokenBudget = try container.decodeIfPresent(Int64.self, forKey: .tokenBudget)
        elapsedMS = try container.decodeIfPresent(UInt64.self, forKey: .elapsedMS) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        currentSubagentID = try container.decodeIfPresent(String.self, forKey: .currentSubagentID)
        currentSubagentRole = try container.decodeIfPresent(String.self, forKey: .currentSubagentRole)
        totalWorkerRounds = try container.decodeIfPresent(UInt32.self, forKey: .totalWorkerRounds) ?? 0
        totalVerifyRounds = try container.decodeIfPresent(UInt32.self, forKey: .totalVerifyRounds) ?? 0
        budgetLimitReported = false
        tokenBaseline = try container.decodeIfPresent(Int64.self, forKey: .tokenBaseline) ?? 0
        tokensUsedHighWater = try container.decodeIfPresent(Int64.self, forKey: .tokensUsedHighWater) ?? 0
        parentTokensSpent = try container.decodeIfPresent(Int64.self, forKey: .parentTokensSpent) ?? 0
        lastSessionTokensSeen = try container.decodeIfPresent(Int64.self, forKey: .lastSessionTokensSeen)
        history = try container.decodeIfPresent([GoalHistoryEntry].self, forKey: .history) ?? []
        pauseMessage = try container.decodeIfPresent(String.self, forKey: .pauseMessage)
        evaluatorBlockerKey = try container.decodeIfPresent(String.self, forKey: .evaluatorBlockerKey)
        evaluatorBlockedStreak = try container.decodeIfPresent(UInt32.self, forKey: .evaluatorBlockedStreak) ?? 0
        verifierID = try container.decodeIfPresent(String.self, forKey: .verifierID) ?? generateVerifierID()
        classifierRunsAttempted = try container.decodeIfPresent(UInt32.self, forKey: .classifierRunsAttempted) ?? 0
        roundsSinceVerify = try container.decodeIfPresent(UInt32.self, forKey: .roundsSinceVerify) ?? 0
        classifierMaxRuns = try container.decodeIfPresent(UInt32.self, forKey: .classifierMaxRuns)
        lastClassifierVerdict = try container.decodeIfPresent(GoalClassifierVerdict.self, forKey: .lastClassifierVerdict)
        lastClassifierDetailsPath = try container.decodeIfPresent(String.self, forKey: .lastClassifierDetailsPath)
        lastClassifierAt = try container.decodeIfPresent(String.self, forKey: .lastClassifierAt)
        lastClassifierGaps = try container.decodeIfPresent(String.self, forKey: .lastClassifierGaps)
        firstFinalResponse = try container.decodeIfPresent(String.self, forKey: .firstFinalResponse)
        skeptic0SessionID = try container.decodeIfPresent(String.self, forKey: .skeptic0SessionID)
        skepticModelAssignment = try container.decodeIfPresent([GoalRoleModel].self, forKey: .skepticModelAssignment) ?? []
        lastGapFingerprint = try container.decodeIfPresent(String.self, forKey: .lastGapFingerprint)
        classifierStallCount = try container.decodeIfPresent(UInt32.self, forKey: .classifierStallCount) ?? 0
        consecutiveNotAchieved = try container.decodeIfPresent(UInt32.self, forKey: .consecutiveNotAchieved) ?? 0
        lastStrategistFiredAt = try container.decodeIfPresent(UInt32.self, forKey: .lastStrategistFiredAt) ?? 0
        strategistCapBonus = try container.decodeIfPresent(UInt32.self, forKey: .strategistCapBonus) ?? 0
        lastStrategyPath = try container.decodeIfPresent(String.self, forKey: .lastStrategyPath)
        lastStrategyRecommendation = try container.decodeIfPresent(String.self, forKey: .lastStrategyRecommendation)
        changesBaselineCommit = try container.decodeIfPresent(String.self, forKey: .changesBaselineCommit)
        planFile = try container.decodeIfPresent(String.self, forKey: .planFile)
        planBaselineFile = try container.decodeIfPresent(String.self, forKey: .planBaselineFile)
        scratchDirectoryReady = false
        liveSubagentTokens = 0
        liveTokensByModel = []
        liveContextWindow = 0
        liveContextPercent = 0
        liveTurnCount = 0
        liveToolCallCount = 0
        planningInFlight = false
        verifyingInFlight = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(goalID, forKey: .goalID)
        try container.encode(objective, forKey: .objective)
        try container.encode(status, forKey: .status)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(tokenBudget, forKey: .tokenBudget)
        try container.encode(elapsedMS, forKey: .elapsedMS)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(currentSubagentID, forKey: .currentSubagentID)
        try container.encodeIfPresent(currentSubagentRole, forKey: .currentSubagentRole)
        try container.encode(totalWorkerRounds, forKey: .totalWorkerRounds)
        try container.encode(totalVerifyRounds, forKey: .totalVerifyRounds)
        try container.encode(tokenBaseline, forKey: .tokenBaseline)
        try container.encode(tokensUsedHighWater, forKey: .tokensUsedHighWater)
        try container.encode(parentTokensSpent, forKey: .parentTokensSpent)
        try container.encodeIfPresent(lastSessionTokensSeen, forKey: .lastSessionTokensSeen)
        try container.encode(history, forKey: .history)
        try container.encodeIfPresent(pauseMessage, forKey: .pauseMessage)
        try container.encodeIfPresent(evaluatorBlockerKey, forKey: .evaluatorBlockerKey)
        try container.encode(evaluatorBlockedStreak, forKey: .evaluatorBlockedStreak)
        try container.encode(verifierID, forKey: .verifierID)
        try container.encode(classifierRunsAttempted, forKey: .classifierRunsAttempted)
        try container.encode(roundsSinceVerify, forKey: .roundsSinceVerify)
        try container.encodeIfPresent(classifierMaxRuns, forKey: .classifierMaxRuns)
        try container.encodeIfPresent(lastClassifierVerdict, forKey: .lastClassifierVerdict)
        try container.encodeIfPresent(lastClassifierDetailsPath, forKey: .lastClassifierDetailsPath)
        try container.encodeIfPresent(lastClassifierAt, forKey: .lastClassifierAt)
        try container.encodeIfPresent(lastClassifierGaps, forKey: .lastClassifierGaps)
        try container.encodeIfPresent(firstFinalResponse, forKey: .firstFinalResponse)
        try container.encodeIfPresent(skeptic0SessionID, forKey: .skeptic0SessionID)
        if !skepticModelAssignment.isEmpty { try container.encode(skepticModelAssignment, forKey: .skepticModelAssignment) }
        try container.encodeIfPresent(lastGapFingerprint, forKey: .lastGapFingerprint)
        try container.encode(classifierStallCount, forKey: .classifierStallCount)
        try container.encode(consecutiveNotAchieved, forKey: .consecutiveNotAchieved)
        try container.encode(lastStrategistFiredAt, forKey: .lastStrategistFiredAt)
        try container.encode(strategistCapBonus, forKey: .strategistCapBonus)
        try container.encodeIfPresent(lastStrategyPath, forKey: .lastStrategyPath)
        try container.encodeIfPresent(lastStrategyRecommendation, forKey: .lastStrategyRecommendation)
        try container.encodeIfPresent(changesBaselineCommit, forKey: .changesBaselineCommit)
        try container.encodeIfPresent(planFile, forKey: .planFile)
        try container.encodeIfPresent(planBaselineFile, forKey: .planBaselineFile)
    }
}

public struct GoalProgressUpdate: Codable, Sendable, Hashable {
    public var goalID: String
    public var objective: String
    public var status: GoalStatus
    public var phase: GoalPhase
    public var tokenBudget: Int64?
    public var tokensUsed: Int64
    public var elapsedMS: UInt64
    public var totalWorkerRounds: UInt32
    public var totalVerifyRounds: UInt32
    public var tokenBaseline: Int64
    public var finishedSubagentTokens: Int64
    public var currentSubagentRole: String?
    public var liveSubagentTokens: UInt64?
    public var liveTokensByModel: [GoalTokenBreakdown]
    public var liveContextPercent: UInt8?
    public var liveTurnCount: UInt32?
    public var liveToolCallCount: UInt32?
    public var lastEvent: GoalEvent?
    public var lastEventDetail: String?
    public var lastEventTimestamp: String?
    public var pauseMessage: String?
    public var classifierRunsAttempted: UInt32?
    public var classifierMaxRuns: UInt32?
    public var lastClassifierVerdict: GoalClassifierVerdict?
    public var lastClassifierDetailsPath: String?
    public var verifyingCompletion: Bool?
    public var planning: Bool?

    private enum CodingKeys: String, CodingKey {
        case goalID = "goal_id"
        case objective
        case status
        case phase
        case tokenBudget = "token_budget"
        case tokensUsed = "tokens_used"
        case elapsedMS = "elapsed_ms"
        case totalWorkerRounds = "total_worker_rounds"
        case totalVerifyRounds = "total_verify_rounds"
        case tokenBaseline = "token_baseline"
        case finishedSubagentTokens = "finished_subagent_tokens"
        case currentSubagentRole = "current_subagent_role"
        case liveSubagentTokens = "live_subagent_tokens"
        case liveTokensByModel = "live_tokens_by_model"
        case liveContextPercent = "live_context_pct"
        case liveTurnCount = "live_turn_count"
        case liveToolCallCount = "live_tool_call_count"
        case lastEvent = "last_event"
        case lastEventDetail = "last_event_detail"
        case lastEventTimestamp = "last_event_timestamp"
        case pauseMessage = "pause_message"
        case classifierRunsAttempted = "classifier_runs_attempted"
        case classifierMaxRuns = "classifier_max_runs"
        case lastClassifierVerdict = "last_classifier_verdict"
        case lastClassifierDetailsPath = "last_classifier_details_path"
        case verifyingCompletion = "verifying_completion"
        case planning
    }

    public init(snapshot: GoalOrchestration, tokensUsed: Int64, finishedSubagentTokens: Int64) {
        let last = snapshot.history.last
        goalID = snapshot.goalID
        objective = snapshot.objective
        status = snapshot.status
        phase = snapshot.phase
        tokenBudget = snapshot.tokenBudget
        self.tokensUsed = tokensUsed
        elapsedMS = snapshot.elapsedMS
        totalWorkerRounds = snapshot.totalWorkerRounds
        totalVerifyRounds = snapshot.totalVerifyRounds
        tokenBaseline = snapshot.tokenBaseline
        self.finishedSubagentTokens = finishedSubagentTokens
        currentSubagentRole = snapshot.currentSubagentRole
        liveSubagentTokens = snapshot.liveSubagentTokens > 0 ? snapshot.liveSubagentTokens : nil
        let sortedTokens = GoalTracker.sortedTokenBreakdown(snapshot.liveTokensByModel)
        liveTokensByModel = sortedTokens.count >= 2 ? sortedTokens : []
        liveContextPercent = snapshot.liveContextPercent > 0 ? snapshot.liveContextPercent : nil
        liveTurnCount = snapshot.liveTurnCount > 0 ? snapshot.liveTurnCount : nil
        liveToolCallCount = snapshot.liveToolCallCount > 0 ? snapshot.liveToolCallCount : nil
        lastEvent = last?.event
        lastEventDetail = last?.detail
        lastEventTimestamp = last?.timestamp
        pauseMessage = snapshot.pauseMessage
        classifierRunsAttempted = snapshot.classifierRunsAttempted > 0 ? snapshot.classifierRunsAttempted : nil
        classifierMaxRuns = snapshot.classifierMaxRuns
        lastClassifierVerdict = snapshot.lastClassifierVerdict
        lastClassifierDetailsPath = snapshot.lastClassifierDetailsPath
        verifyingCompletion = snapshot.verifyingInFlight ? true : nil
        planning = snapshot.planningInFlight ? true : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(goalID, forKey: .goalID)
        try container.encode(objective, forKey: .objective)
        try container.encode(status, forKey: .status)
        try container.encode(phase.rawValue.lowercased(), forKey: .phase)
        try container.encodeIfPresent(tokenBudget, forKey: .tokenBudget)
        try container.encode(tokensUsed, forKey: .tokensUsed)
        try container.encode(elapsedMS, forKey: .elapsedMS)
        try container.encode(totalWorkerRounds, forKey: .totalWorkerRounds)
        try container.encode(totalVerifyRounds, forKey: .totalVerifyRounds)
        try container.encode(tokenBaseline, forKey: .tokenBaseline)
        try container.encode(finishedSubagentTokens, forKey: .finishedSubagentTokens)
        try container.encodeIfPresent(currentSubagentRole, forKey: .currentSubagentRole)
        try container.encodeIfPresent(liveSubagentTokens, forKey: .liveSubagentTokens)
        if !liveTokensByModel.isEmpty { try container.encode(liveTokensByModel, forKey: .liveTokensByModel) }
        try container.encodeIfPresent(liveContextPercent, forKey: .liveContextPercent)
        try container.encodeIfPresent(liveTurnCount, forKey: .liveTurnCount)
        try container.encodeIfPresent(liveToolCallCount, forKey: .liveToolCallCount)
        try container.encodeIfPresent(lastEvent, forKey: .lastEvent)
        try container.encodeIfPresent(lastEventDetail, forKey: .lastEventDetail)
        try container.encodeIfPresent(lastEventTimestamp, forKey: .lastEventTimestamp)
        try container.encodeIfPresent(pauseMessage, forKey: .pauseMessage)
        try container.encodeIfPresent(classifierRunsAttempted, forKey: .classifierRunsAttempted)
        try container.encodeIfPresent(classifierMaxRuns, forKey: .classifierMaxRuns)
        try container.encodeIfPresent(lastClassifierVerdict, forKey: .lastClassifierVerdict)
        try container.encodeIfPresent(lastClassifierDetailsPath, forKey: .lastClassifierDetailsPath)
        try container.encodeIfPresent(verifyingCompletion, forKey: .verifyingCompletion)
        try container.encodeIfPresent(planning, forKey: .planning)
    }
}

public struct GoalTracker: Sendable {
    private var orchestration: GoalOrchestration?
    private let sessionDirectory: URL
    private var activeSince: Date?
    private var blockedAttemptStreak: UInt32

    public init(sessionDirectory: URL) {
        self.sessionDirectory = sessionDirectory
        self.orchestration = nil
        self.activeSince = nil
        self.blockedAttemptStreak = 0
    }

    public init(sessionDirectory: String) {
        self.init(sessionDirectory: URL(fileURLWithPath: sessionDirectory, isDirectory: true))
    }

    public init(sessionDir: URL) {
        self.init(sessionDirectory: sessionDir)
    }

    public init(sessionDir: String) {
        self.init(sessionDirectory: sessionDir)
    }

    public static func fromSnapshot(sessionDirectory: URL, snapshot: GoalOrchestration) -> Self {
        var tracker = Self(sessionDirectory: sessionDirectory)
        tracker.restore(snapshot)
        return tracker
    }

    public static func fromSnapshot(sessionDir: URL, snapshot: GoalOrchestration) -> Self {
        Self.fromSnapshot(sessionDirectory: sessionDir, snapshot: snapshot)
    }

    public var snapshotValue: GoalOrchestration? { orchestration }
    public var isActive: Bool { orchestration?.status == .active }
    public var phase: GoalPhase? { orchestration?.phase }
    public var status: GoalStatus? { orchestration?.status }
    public var currentSubagentID: String? { orchestration?.currentSubagentID }
    public var objective: String? { orchestration?.objective }
    public var tokenBudget: Int64? { orchestration?.tokenBudget }

    public func snapshot() -> GoalOrchestration? { orchestration }

    public mutating func modifySnapshot(_ body: (inout GoalOrchestration) -> Void) {
        guard var value = orchestration else { return }
        body(&value)
        orchestration = value
    }

    public func planURL() -> URL {
        sessionDirectory.appendingPathComponent("goal", isDirectory: true).appendingPathComponent("plan.md")
    }

    public func planPath() -> String { planURL().path }

    public func planBaselineURL() -> URL {
        sessionDirectory.appendingPathComponent("goal", isDirectory: true).appendingPathComponent("plan.baseline.md")
    }

    public func planBaselinePath() -> String { planBaselineURL().path }

    public func strategyURL() -> URL {
        sessionDirectory.appendingPathComponent("goal", isDirectory: true).appendingPathComponent("strategy.md")
    }

    public func strategyPath() -> String { strategyURL().path }

    public mutating func createGoal(
        goalID: String,
        objective: String,
        tokenBudget: Int64? = nil,
        tokenBaseline: Int64 = 0,
        createdAt: String = currentISO8601Timestamp(),
        baselineCommit: String? = nil
    ) {
        try? FileManager.default.createDirectory(at: planURL().deletingLastPathComponent(), withIntermediateDirectories: true)
        if let prior = orchestration {
            rescueClassifierDetails()
            removeScratchDirectory(for: prior.verifierID)
        }
        blockedAttemptStreak = 0
        let verifierID = generateVerifierID()
        let scratchReady = createScratchDirectory(for: verifierID)
        orchestration = GoalOrchestration(
            goalID: goalID,
            objective: objective,
            status: .active,
            phase: .executing,
            tokenBudget: tokenBudget,
            createdAt: createdAt,
            tokenBaseline: tokenBaseline,
            lastSessionTokensSeen: tokenBaseline,
            verifierID: verifierID,
            changesBaselineCommit: baselineCommit,
            scratchDirectoryReady: scratchReady
        )
        activeSince = Date()
        recordEvent(.goalCreated)
    }

    public mutating func setPhase(_ phase: GoalPhase) {
        orchestration?.phase = phase
    }

    public mutating func setCurrentSubagent(id: String?, role: String?) {
        orchestration?.currentSubagentID = id
        orchestration?.currentSubagentRole = role
    }

    public mutating func pause(_ reason: GoalPauseReason) -> Bool {
        pause(reason, message: nil)
    }

    public mutating func pauseWithMessage(_ reason: GoalPauseReason, message: String) -> Bool {
        pause(reason, message: message)
    }

    public mutating func cancel() -> Bool {
        pause(.user)
    }

    @discardableResult
    private mutating func pause(_ reason: GoalPauseReason, message: String?) -> Bool {
        guard orchestration?.status == .active else { return false }
        flushElapsed()
        guard var value = orchestration else { return false }
        value.status = reason.status
        if let message { value.pauseMessage = message }
        orchestration = value
        activeSince = nil
        recordEvent(.goalPaused, detail: reason.historyDetail)
        return true
    }

    public mutating func resume() -> Bool {
        guard var value = orchestration, value.status.isPaused else { return false }
        value.status = .active
        value.pauseMessage = nil
        value.classifierRunsAttempted = 0
        value.roundsSinceVerify = 0
        resetStrategistFields(&value)
        resetClassifierStallFields(&value)
        resetEvaluatorBlockerFields(&value)
        blockedAttemptStreak = 0
        orchestration = value
        activeSince = Date()
        recordEvent(.goalResumed)
        return true
    }

    public mutating func complete() -> Bool {
        guard let status = orchestration?.status, status == .active || status.isPaused else { return false }
        flushElapsed()
        guard var value = orchestration else { return false }
        value.status = .complete
        value.phase = .idle
        value.currentSubagentID = nil
        value.currentSubagentRole = nil
        value.pauseMessage = nil
        value.skeptic0SessionID = nil
        value.skepticModelAssignment.removeAll(keepingCapacity: false)
        value.planBaselineFile = nil
        resetStrategistFields(&value)
        resetEvaluatorBlockerFields(&value)
        orchestration = value
        rescueClassifierDetails()
        if let current = orchestration { removeScratchDirectory(for: current.verifierID) }
        activeSince = nil
        blockedAttemptStreak = 0
        recordEvent(.goalCompleted)
        return true
    }

    public mutating func budgetLimit() -> Bool {
        guard let status = orchestration?.status, status == .active || status.isPaused else { return false }
        flushElapsed()
        guard var value = orchestration else { return false }
        value.status = .budgetLimited
        value.phase = .idle
        value.currentSubagentID = nil
        value.currentSubagentRole = nil
        value.pauseMessage = nil
        value.skeptic0SessionID = nil
        value.skepticModelAssignment.removeAll(keepingCapacity: false)
        value.planBaselineFile = nil
        resetStrategistFields(&value)
        resetEvaluatorBlockerFields(&value)
        orchestration = value
        rescueClassifierDetails()
        if let current = orchestration { removeScratchDirectory(for: current.verifierID) }
        activeSince = nil
        blockedAttemptStreak = 0
        recordEvent(.budgetExceeded)
        return true
    }

    public mutating func clear() {
        rescueClassifierDetails()
        if let current = orchestration { removeScratchDirectory(for: current.verifierID) }
        orchestration = nil
        activeSince = nil
        blockedAttemptStreak = 0
    }

    public mutating func updateLiveProgress(
        subagentTokens: UInt64,
        tokensByModel: [GoalTokenBreakdown],
        contextWindow: UInt64,
        contextPercent: UInt8,
        turnCount: UInt32,
        toolCallCount: UInt32
    ) {
        guard var value = orchestration else { return }
        value.liveSubagentTokens = subagentTokens
        value.liveTokensByModel = Self.sortedTokenBreakdown(tokensByModel)
        value.liveContextWindow = contextWindow
        value.liveContextPercent = contextPercent
        value.liveTurnCount = turnCount
        value.liveToolCallCount = toolCallCount
        orchestration = value
    }

    public mutating func accountElapsed() {
        flushElapsed()
        if orchestration?.status == .active { activeSince = Date() }
    }

    public mutating func recordClassifierStall(_ fingerprint: String) -> Bool {
        guard var value = orchestration else { return false }
        if value.lastGapFingerprint == fingerprint {
            value.classifierStallCount = value.classifierStallCount.saturatingAdd(1)
        } else {
            value.lastGapFingerprint = fingerprint
            value.classifierStallCount = 1
        }
        let threshold = value.strategistCapBonus > 0 ? goalStrategistStallThreshold : goalClassifierStallThreshold
        orchestration = value
        return value.classifierStallCount >= threshold
    }

    public mutating func recordEvaluatorBlocker(_ blockerKey: String) -> UInt32 {
        guard var value = orchestration else { return 0 }
        if value.evaluatorBlockerKey == blockerKey {
            value.evaluatorBlockedStreak = value.evaluatorBlockedStreak.saturatingAdd(1)
        } else {
            value.evaluatorBlockerKey = blockerKey
            value.evaluatorBlockedStreak = 1
        }
        orchestration = value
        return value.evaluatorBlockedStreak
    }

    public mutating func resetEvaluatorBlocker() {
        guard var value = orchestration else { return }
        resetEvaluatorBlockerFields(&value)
        orchestration = value
    }

    public mutating func rollbackClassifierAttempt() {
        guard var value = orchestration else { return }
        value.classifierRunsAttempted = value.classifierRunsAttempted.saturatingSubtract(1)
        orchestration = value
    }

    public mutating func resetClassifierStall() {
        guard var value = orchestration else { return }
        resetClassifierStallFields(&value)
        orchestration = value
    }

    public mutating func recordNotAchievedStreak() -> UInt32 {
        guard var value = orchestration else { return 0 }
        value.consecutiveNotAchieved = value.consecutiveNotAchieved.saturatingAdd(1)
        orchestration = value
        return value.consecutiveNotAchieved
    }

    public mutating func claimStrategistFire(_ shouldFire: (UInt32, UInt32) -> Bool) -> UInt32? {
        guard var value = orchestration else { return nil }
        guard shouldFire(value.consecutiveNotAchieved, value.lastStrategistFiredAt) else { return nil }
        value.lastStrategistFiredAt = value.consecutiveNotAchieved
        value.strategistCapBonus = goalStrategistCapBonus
        resetClassifierStallFields(&value)
        orchestration = value
        return value.consecutiveNotAchieved
    }

    public mutating func revokeStrategistCapBonus() {
        guard var value = orchestration else { return }
        value.strategistCapBonus = 0
        orchestration = value
    }

    public mutating func resetStrategistState() {
        guard var value = orchestration else { return }
        resetStrategistFields(&value)
        orchestration = value
    }

    public mutating func recordStrategyRecommendation(path: String, recommendation: String) {
        guard var value = orchestration else { return }
        value.lastStrategyPath = path
        value.lastStrategyRecommendation = recommendation
        orchestration = value
    }

    public mutating func appendHistory(_ entry: GoalHistoryEntry) {
        guard var value = orchestration else { return }
        value.history.append(entry)
        if value.history.count > goalHistoryMax {
            value.history.removeFirst(value.history.count - goalHistoryMax)
        }
        orchestration = value
    }

    public func progressUpdate(tokensUsed: Int64, finishedSubagentTokens: Int64) -> GoalProgressUpdate? {
        guard let orchestration else { return nil }
        return GoalProgressUpdate(snapshot: orchestration, tokensUsed: tokensUsed, finishedSubagentTokens: finishedSubagentTokens)
    }

    public mutating func applyUpdate(_ input: UpdateGoalInput) throws -> GoalUpdateOutcome {
        try input.validate()
        if let reason = input.blockedReason {
            guard orchestration?.status == .active else { throw GoalUpdateValidationError.nonActiveGoal }
            blockedAttemptStreak = blockedAttemptStreak.saturatingAdd(1)
            guard blockedAttemptStreak >= 3 else {
                return .accepted(summary: "Blocked attempt \(blockedAttemptStreak)/3 recorded. The harness needs 3 consecutive blocked attempts before pausing the goal — continue retrying or refining the approach.")
            }
            let pauseMessage = input.message.map { "\(reason)\n\($0)" } ?? reason
            _ = pauseWithMessage(.verification, message: pauseMessage)
            return .blocked(summary: "Goal blocked: \(reason).")
        }
        guard orchestration?.status == .active else { throw GoalUpdateValidationError.nonActiveGoal }
        guard input.completed == true else { return .accepted(summary: input.summary) }
        blockedAttemptStreak = 0
        _ = complete()
        return .completed(summary: input.summary)
    }

    public mutating func recordGoalTokens(currentSessionTokens: Int64, subagentTokens: Int64 = 0) -> Int64 {
        guard var value = orchestration else { return 0 }
        let lastSeen = value.lastSessionTokensSeen ?? value.tokenBaseline
        if currentSessionTokens > lastSeen {
            value.parentTokensSpent = value.parentTokensSpent.saturatingAdd(currentSessionTokens - lastSeen)
        }
        value.lastSessionTokensSeen = currentSessionTokens
        let raw = value.parentTokensSpent.saturatingAdd(max(0, subagentTokens))
        value.tokensUsedHighWater = max(value.tokensUsedHighWater, raw)
        orchestration = value
        return value.tokensUsedHighWater
    }

    public static func foldTokenBreakdown(
        records: [GoalTokenRecord],
        goalID: String,
        currentModelID: String,
        includeFinished: Bool = true
    ) -> [GoalTokenBreakdown] {
        var totals: [String: UInt64] = [:]
        for record in records where record.goalID == goalID && (includeFinished || !record.finished) {
            let marginal = record.marginalTokens
            guard marginal > 0 else { continue }
            let modelID = record.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? record.modelID!.trimmingCharacters(in: .whitespacesAndNewlines)
                : currentModelID
            totals[modelID, default: 0] = totals[modelID, default: 0].saturatingAdd(marginal)
        }
        return sortedTokenBreakdown(totals.map { GoalTokenBreakdown(modelID: $0.key, tokens: $0.value) })
    }

    public static func sortedTokenBreakdown(_ entries: [GoalTokenBreakdown]) -> [GoalTokenBreakdown] {
        var totals: [String: UInt64] = [:]
        for entry in entries {
            totals[entry.modelID, default: 0] = totals[entry.modelID, default: 0].saturatingAdd(entry.tokens)
        }
        return totals.map { GoalTokenBreakdown(modelID: $0.key, tokens: $0.value) }
            .sorted { left, right in
                if left.tokens != right.tokens { return left.tokens > right.tokens }
                return left.modelID < right.modelID
            }
    }

    private mutating func restore(_ source: GoalOrchestration) {
        var value = source
        if value.phase == .planning || value.phase == .executing {
            value.phase = .idle
            value.currentSubagentID = nil
            value.currentSubagentRole = nil
        }
        if value.status == .active { value.status = .userPaused }
        value.planningInFlight = false
        value.verifyingInFlight = false
        value.skeptic0SessionID = nil
        if !isCanonicalVerifierID(value.verifierID) { value.verifierID = generateVerifierID() }
        value.scratchDirectoryReady = value.status != .complete && value.status != .budgetLimited
            ? createScratchDirectory(for: value.verifierID)
            : false
        orchestration = value
        activeSince = value.status == .active ? Date() : nil
        blockedAttemptStreak = 0
    }

    private mutating func flushElapsed() {
        guard var value = orchestration, let activeSince else { return }
        let milliseconds = max(0, Int64(Date().timeIntervalSince(activeSince) * 1_000))
        value.elapsedMS = value.elapsedMS.saturatingAdd(UInt64(milliseconds))
        orchestration = value
        self.activeSince = Date()
    }

    private mutating func recordEvent(_ event: GoalEvent, detail: String? = nil) {
        appendHistory(.now(event: event, detail: detail))
    }

    private func resetStrategistFields(_ value: inout GoalOrchestration) {
        value.consecutiveNotAchieved = 0
        value.lastStrategistFiredAt = 0
        value.strategistCapBonus = 0
        value.lastStrategyPath = nil
        value.lastStrategyRecommendation = nil
    }

    private func resetClassifierStallFields(_ value: inout GoalOrchestration) {
        value.lastGapFingerprint = nil
        value.classifierStallCount = 0
    }

    private func resetEvaluatorBlockerFields(_ value: inout GoalOrchestration) {
        value.evaluatorBlockerKey = nil
        value.evaluatorBlockedStreak = 0
    }

    private mutating func rescueClassifierDetails() {
        guard var value = orchestration, let sourcePath = value.lastClassifierDetailsPath else { return }
        let source = URL(fileURLWithPath: sourcePath)
        let root = scratchRootURL(for: value.verifierID)
        guard source.pathComponents.first(where: { $0 == ".." }) == nil,
              source.path.hasPrefix(root.path + "/"),
              isSecureRealDirectory(root),
              !source.lastPathComponent.isEmpty else { return }
        let destinationDirectory = planURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            appendSkepticReports(from: root, to: destination)
            value.lastClassifierDetailsPath = destination.path
            orchestration = value
        } catch {
            guard !FileManager.default.fileExists(atPath: destination.path), let data = try? Data(contentsOf: source) else { return }
            do {
                try data.write(to: destination, options: [.withoutOverwriting])
                appendSkepticReports(from: root, to: destination)
                value.lastClassifierDetailsPath = destination.path
                orchestration = value
            } catch { return }
        }
    }

    private func scratchRootURL(for verifierID: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("grok-goal-\(verifierID)", isDirectory: true)
    }

    private func createScratchDirectory(for verifierID: String) -> Bool {
        guard isCanonicalVerifierID(verifierID) else { return false }
        let root = scratchRootURL(for: verifierID)
        guard ensureSecureDirectory(root) else { return false }
        return ensureSecureDirectory(root.appendingPathComponent("implementer", isDirectory: true))
    }

    private func removeScratchDirectory(for verifierID: String) {
        guard isCanonicalVerifierID(verifierID) else { return }
        try? FileManager.default.removeItem(at: scratchRootURL(for: verifierID))
    }

    private func ensureSecureDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            return isSecureRealDirectory(url)
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            return isSecureRealDirectory(url)
        } catch {
            return false
        }
    }

    private func isSecureRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
#if canImport(Darwin) || canImport(Glibc)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let ownerID = attributes[.ownerAccountID] as? NSNumber,
           ownerID.uint64Value != UInt64(getuid()) {
            return false
        }
#endif
        return true
    }

    private func appendSkepticReports(from scratchRoot: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: scratchRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let reports = entries.compactMap { url -> (attempt: UInt32, index: UInt32, url: URL)? in
            guard let order = skepticReportOrder(for: url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return (order.attempt, order.index, url)
        }.sorted {
            if $0.attempt != $1.attempt { return $0.attempt > $1.attempt }
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        guard !reports.isEmpty, let handle = try? FileHandle(forWritingTo: destination) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        var remaining = UInt64(goalVerifierPanelMaxBytes)
        for report in reports {
            let name = report.url.lastPathComponent
            let header = "\n\n---\n## Inlined skeptic report: \(name)\n\n".data(using: .utf8) ?? Data()
            guard let attributes = try? fileManager.attributesOfItem(atPath: report.url.path),
                  let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else { continue }
            if UInt64(header.count) + fileSize > remaining {
                handle.write(Data("\n\n---\n(remaining skeptic reports elided: rescue budget reached)\n".utf8))
                return
            }
            guard let body = try? Data(contentsOf: report.url) else { continue }
            if UInt64(header.count) + UInt64(body.count) > remaining {
                handle.write(Data("\n\n---\n(remaining skeptic reports elided: rescue budget reached)\n".utf8))
                return
            }
            handle.write(header)
            handle.write(body)
            remaining -= UInt64(header.count + body.count)
        }
    }

    private func skepticReportOrder(for url: URL) -> (attempt: UInt32, index: UInt32)? {
        let name = url.lastPathComponent
        guard name.hasSuffix(".md") else { return nil }
        let stem = String(name.dropLast(3))
        guard let marker = stem.range(of: "-skeptic-", options: .backwards),
              let index = UInt32(stem[marker.upperBound...]) else { return nil }
        let head = stem[..<marker.lowerBound]
        guard let separator = head.lastIndex(of: "-"),
              let attempt = UInt32(head[head.index(after: separator)...]) else { return nil }
        return (attempt, index)
    }
}

public func currentISO8601Timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

public func generateVerifierID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
}

private func isCanonicalVerifierID(_ value: String) -> Bool {
    value.count == 12 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
}

private extension UInt32 {
    func saturatingAdd(_ value: UInt32) -> UInt32 {
        addingReportingOverflow(value).overflow ? .max : self + value
    }

    func saturatingSubtract(_ value: UInt32) -> UInt32 {
        self >= value ? self - value : 0
    }
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 {
        addingReportingOverflow(value).overflow ? .max : self + value
    }
}

private extension Int64 {
    func saturatingAdd(_ value: Int64) -> Int64 {
        addingReportingOverflow(value).overflow ? (value >= 0 ? .max : .min) : self + value
    }
}
