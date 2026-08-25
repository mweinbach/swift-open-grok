import Foundation

public let goalEvaluatorMaximumAttempts: UInt32 = 2
public let goalPlannerMaximumAttempts: UInt32 = 5
public let goalVerifierMaximumAttemptsDefault: UInt32 = 10
public let goalVerifierDefaultSkepticCount: UInt32 = 3
public let goalVerifierMaximumSkepticCount: UInt32 = 5
public let goalTodoGateMaximumFiresDefault: UInt32 = 2
public let goalTodoGateMaximumFiresCeiling: UInt32 = 16
public let goalMaximumWorkerRoundsCeiling: UInt32 = 128

public enum GoalOrchestrationRole: String, Codable, Sendable, Hashable, CaseIterable {
    case planner
    case implementer
    case evaluator
    case strategist
    case skeptic
}

public enum GoalRoleRunState: String, Codable, Sendable, Hashable {
    case running
    case succeeded
    case failed
    case cancelled
}

public struct GoalRoleSnapshot: Codable, Sendable, Hashable {
    public var role: GoalOrchestrationRole
    public var model: String
    public var agentType: String
    public var runID: String
    public var state: GoalRoleRunState
    public var round: UInt32
    public var evidence: String?

    private enum CodingKeys: String, CodingKey {
        case role
        case model
        case agentType = "agent_type"
        case runID = "run_id"
        case state
        case round
        case evidence
    }

    public init(
        role: GoalOrchestrationRole,
        model: String,
        agentType: String = "general-purpose",
        runID: String,
        state: GoalRoleRunState = .running,
        round: UInt32 = 0,
        evidence: String? = nil
    ) {
        self.role = role
        self.model = model
        self.agentType = agentType
        self.runID = runID
        self.state = state
        self.round = round
        self.evidence = evidence
    }
}

public struct GoalTodoSnapshot: Codable, Sendable, Hashable {
    public var id: String
    public var content: String
    public var status: String

    public init(id: String, content: String, status: String) {
        self.id = id
        self.content = content
        self.status = status
    }

    public var isOutstanding: Bool {
        status == "pending" || status == "in_progress"
    }
}

public struct GoalRuntimePolicy: Sendable, Hashable {
    public var maximumWorkerRounds: UInt32
    public var maximumEvaluatorAttempts: UInt32
    public var maximumPlannerAttempts: UInt32
    public var maximumVerifierAttempts: UInt32
    public var skepticCount: UInt32
    public var strategistEvery: UInt32
    public var todoGateEnabled: Bool
    public var maximumTodoGateFiresPerPrompt: UInt32

    public init(
        maximumWorkerRounds: UInt32 = 64,
        maximumEvaluatorAttempts: UInt32 = goalEvaluatorMaximumAttempts,
        maximumPlannerAttempts: UInt32 = goalPlannerMaximumAttempts,
        maximumVerifierAttempts: UInt32 = goalVerifierMaximumAttemptsDefault,
        skepticCount: UInt32 = goalVerifierDefaultSkepticCount,
        strategistEvery: UInt32 = 5,
        todoGateEnabled: Bool = false,
        maximumTodoGateFiresPerPrompt: UInt32 = goalTodoGateMaximumFiresDefault
    ) {
        self.maximumWorkerRounds = min(max(1, maximumWorkerRounds), goalMaximumWorkerRoundsCeiling)
        self.maximumEvaluatorAttempts = min(max(1, maximumEvaluatorAttempts), goalEvaluatorMaximumAttempts)
        self.maximumPlannerAttempts = min(max(1, maximumPlannerAttempts), goalPlannerMaximumAttempts)
        self.maximumVerifierAttempts = min(max(1, maximumVerifierAttempts), goalVerifierMaximumAttemptsDefault)
        self.skepticCount = min(max(1, skepticCount), goalVerifierMaximumSkepticCount)
        self.strategistEvery = max(1, strategistEvery)
        self.todoGateEnabled = todoGateEnabled
        self.maximumTodoGateFiresPerPrompt = min(
            maximumTodoGateFiresPerPrompt,
            goalTodoGateMaximumFiresCeiling
        )
    }
}

public struct GoalRoleModels: Sendable, Hashable {
    public var planner: GoalRoleModel?
    public var evaluator: GoalRoleModel?
    public var strategist: GoalRoleModel?
    public var skepticPool: [GoalRoleModel]

    public init(
        planner: GoalRoleModel? = nil,
        evaluator: GoalRoleModel? = nil,
        strategist: GoalRoleModel? = nil,
        skepticPool: [GoalRoleModel] = []
    ) {
        self.planner = planner
        self.evaluator = evaluator
        self.strategist = strategist
        self.skepticPool = skepticPool
    }

    public func assignment(
        for role: GoalOrchestrationRole,
        fallbackModel: String,
        skepticIndex: Int = 0
    ) -> GoalRoleModel {
        let configured: GoalRoleModel?
        switch role {
        case .planner:
            configured = planner
        case .evaluator:
            configured = evaluator
        case .strategist:
            configured = strategist
        case .skeptic:
            configured = skepticPool.isEmpty
                ? nil
                : skepticPool[max(0, skepticIndex) % skepticPool.count]
        case .implementer:
            configured = nil
        }
        return configured ?? GoalRoleModel(model: fallbackModel, agentType: "general-purpose")
    }
}

public enum GoalEvaluationDecision: String, Codable, Sendable, Hashable {
    case continueWork = "continue"
    case candidateComplete = "candidate_complete"
    case blocked
}

public enum GoalOrchestrationValidationError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidJSON(String)
    case unexpectedFields([String])
    case missingField(String)
    case emptyField(String)
    case invalidBlockerKey
    case unexpectedBlockerKey
    case invalidVerification(String)
    case evaluationUnavailable
    case verificationUnavailable
    case cancelled
    case staleGoal
    case budgetExceeded(String)

    public var description: String {
        switch self {
        case .invalidJSON(let reason):
            return "goal evaluator output is not valid JSON: \(reason)"
        case .unexpectedFields(let fields):
            return "goal verdict contains unexpected fields: \(fields.sorted().joined(separator: ", "))"
        case .missingField(let field):
            return "goal verdict is missing required field `\(field)`"
        case .emptyField(let field):
            return "goal verdict field `\(field)` must not be empty"
        case .invalidBlockerKey:
            return "goal evaluator blocker_key must use lowercase snake_case"
        case .unexpectedBlockerKey:
            return "goal evaluator blocker_key must be empty unless decision is blocked"
        case .invalidVerification(let reason):
            return "goal verification verdict is invalid: \(reason)"
        case .evaluationUnavailable:
            return "goal evaluation is unavailable"
        case .verificationUnavailable:
            return "goal verification is unavailable"
        case .cancelled:
            return "goal orchestration was cancelled"
        case .staleGoal:
            return "goal changed while an independent role was running"
        case .budgetExceeded(let message):
            return message
        }
    }
}

public struct GoalEvaluationVerdict: Codable, Sendable, Hashable {
    public var decision: GoalEvaluationDecision
    public var evidence: String
    public var nextStep: String
    public var blockerKey: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case decision
        case evidence
        case nextStep = "next_step"
        case blockerKey = "blocker_key"
    }

    public init(
        decision: GoalEvaluationDecision,
        evidence: String,
        nextStep: String,
        blockerKey: String = ""
    ) throws {
        self.decision = decision
        self.evidence = evidence
        self.nextStep = nextStep
        self.blockerKey = blockerKey
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: GoalDynamicCodingKey.self)
        let actual = Set(dynamic.allKeys.map(\.stringValue))
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        let extras = actual.subtracting(expected)
        guard extras.isEmpty else {
            throw GoalOrchestrationValidationError.unexpectedFields(Array(extras))
        }
        if let missing = expected.subtracting(actual).sorted().first {
            throw GoalOrchestrationValidationError.missingField(missing)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(GoalEvaluationDecision.self, forKey: .decision)
        evidence = try container.decode(String.self, forKey: .evidence)
        nextStep = try container.decode(String.self, forKey: .nextStep)
        blockerKey = try container.decode(String.self, forKey: .blockerKey)
        try validate()
    }

    public static func parse(_ raw: String) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        } catch let error as GoalOrchestrationValidationError {
            throw error
        } catch {
            throw GoalOrchestrationValidationError.invalidJSON(String(describing: error))
        }
    }

    private func validate() throws {
        guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoalOrchestrationValidationError.emptyField("evidence")
        }
        guard !nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoalOrchestrationValidationError.emptyField("next_step")
        }
        let key = blockerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch decision {
        case .blocked:
            guard !key.isEmpty else {
                throw GoalOrchestrationValidationError.emptyField("blocker_key")
            }
            guard key.unicodeScalars.allSatisfy({ scalar in
                (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value)
                    || scalar.value == 95
            }) else {
                throw GoalOrchestrationValidationError.invalidBlockerKey
            }
        case .continueWork, .candidateComplete:
            guard key.isEmpty else {
                throw GoalOrchestrationValidationError.unexpectedBlockerKey
            }
        }
    }
}

private struct GoalDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

public struct GoalEvaluationRequest: Sendable, Hashable {
    public var goalID: String
    public var objective: String
    public var transcript: String
    public var plan: String?
    public var outstandingTodos: [GoalTodoSnapshot]
    public var workerRound: UInt32
    public var currentTokens: Int64
    public var evaluationID: String?

    public init(
        goalID: String,
        objective: String,
        transcript: String,
        plan: String? = nil,
        outstandingTodos: [GoalTodoSnapshot] = [],
        workerRound: UInt32 = 0,
        currentTokens: Int64 = 0,
        evaluationID: String? = nil
    ) {
        self.goalID = goalID
        self.objective = objective
        self.transcript = transcript
        self.plan = plan
        self.outstandingTodos = outstandingTodos
        self.workerRound = workerRound
        self.currentTokens = currentTokens
        self.evaluationID = evaluationID
    }
}

public enum GoalVerificationDecision: String, Codable, Sendable, Hashable {
    case achieved
    case notAchieved = "not_achieved"
    case blocked
}

public struct GoalVerificationVerdict: Codable, Sendable, Hashable {
    public var decision: GoalVerificationDecision
    public var evidence: String
    public var nextStep: String
    public var gaps: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case decision
        case evidence
        case nextStep = "next_step"
        case gaps
    }

    public init(
        decision: GoalVerificationDecision,
        evidence: String,
        nextStep: String,
        gaps: [String] = []
    ) throws {
        self.decision = decision
        self.evidence = evidence
        self.nextStep = nextStep
        self.gaps = gaps
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: GoalDynamicCodingKey.self)
        let actual = Set(dynamic.allKeys.map(\.stringValue))
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        let extras = actual.subtracting(expected)
        guard extras.isEmpty else {
            throw GoalOrchestrationValidationError.unexpectedFields(Array(extras))
        }
        if let missing = expected.subtracting(actual).sorted().first {
            throw GoalOrchestrationValidationError.missingField(missing)
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(GoalVerificationDecision.self, forKey: .decision)
        evidence = try container.decode(String.self, forKey: .evidence)
        nextStep = try container.decode(String.self, forKey: .nextStep)
        gaps = try container.decode([String].self, forKey: .gaps)
        try validate()
    }

    public static func parse(_ raw: String) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        } catch let error as GoalOrchestrationValidationError {
            throw error
        } catch {
            throw GoalOrchestrationValidationError.invalidJSON(String(describing: error))
        }
    }

    private func validate() throws {
        guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoalOrchestrationValidationError.emptyField("evidence")
        }
        guard !nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoalOrchestrationValidationError.emptyField("next_step")
        }
        if decision == .achieved, !gaps.isEmpty {
            throw GoalOrchestrationValidationError.invalidVerification(
                "an achieved verdict cannot contain unresolved gaps"
            )
        }
        if decision == .notAchieved,
           gaps.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw GoalOrchestrationValidationError.invalidVerification(
                "a not_achieved verdict must identify a concrete gap"
            )
        }
    }
}

public struct GoalVerificationRequest: Sendable, Hashable {
    public var evaluation: GoalEvaluationRequest
    public var candidateEvidence: String
    public var attempt: UInt32
    public var skepticModels: [GoalRoleModel]
    public var skepticRunIDs: [String]

    public init(
        evaluation: GoalEvaluationRequest,
        candidateEvidence: String,
        attempt: UInt32,
        skepticModels: [GoalRoleModel],
        skepticRunIDs: [String] = []
    ) {
        self.evaluation = evaluation
        self.candidateEvidence = candidateEvidence
        self.attempt = attempt
        self.skepticModels = skepticModels
        self.skepticRunIDs = skepticRunIDs
    }
}

public protocol GoalIndependentEvaluator: Sendable {
    func evaluateGoal(_ request: GoalEvaluationRequest) async throws -> GoalEvaluationVerdict
}

public protocol GoalIndependentVerifier: Sendable {
    func verifyGoal(_ request: GoalVerificationRequest) async throws -> GoalVerificationVerdict
}

public struct GoalRoleRequest: Sendable, Hashable {
    public var role: GoalOrchestrationRole
    public var goalID: String
    public var objective: String
    public var transcript: String
    public var model: GoalRoleModel
    public var attempt: UInt32
    public var gaps: [String]
    public var runID: String

    public init(
        role: GoalOrchestrationRole,
        goalID: String,
        objective: String,
        transcript: String,
        model: GoalRoleModel,
        attempt: UInt32 = 1,
        gaps: [String] = [],
        runID: String = UUID().uuidString
    ) {
        self.role = role
        self.goalID = goalID
        self.objective = objective
        self.transcript = transcript
        self.model = model
        self.attempt = attempt
        self.gaps = gaps
        self.runID = runID
    }
}

public protocol GoalRoleRunner: Sendable {
    func runGoalRole(_ request: GoalRoleRequest) async throws -> String
}

public enum GoalRoundOutcome: Sendable, Hashable {
    case continuePursuit(String)
    case completed(String)
    case paused(GoalStatus, String)
    case budgetLimited(String)
    case failed(String)
    case idle
}

public enum GoalOrchestrationEngine {
    public static func strategistShouldFire(
        consecutive: UInt32,
        lastFired: UInt32,
        every: UInt32
    ) -> Bool {
        guard every > 0 else { return false }
        let (threshold, overflow) = lastFired.addingReportingOverflow(every)
        return !overflow && consecutive >= threshold
    }

    public static func cappedText(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        var count = 0
        for character in value {
            let size = String(character).utf8.count
            guard size <= maximumBytes - count else { break }
            result.append(character)
            count += size
        }
        return result
    }

    public static func carryForwardDirective(
        objective: String,
        nextStep: String,
        outstandingTodos: [GoalTodoSnapshot],
        gaps: String?,
        strategy: String?,
        prematureStopPattern: String?
    ) -> String {
        var sections = [
            "<system-reminder>",
            "The autonomous goal remains active: \(objective)",
        ]
        if let prematureStopPattern {
            sections.append(
                "Your previous response attempted to stop early (\(prematureStopPattern)). "
                    + "Continue working; do not hand unfinished work back to the user."
            )
        }
        if !outstandingTodos.isEmpty {
            sections.append("Outstanding todos:")
            sections.append(contentsOf: outstandingTodos.map {
                "- [\($0.status)] \($0.content)"
            })
        }
        if let gaps, !gaps.isEmpty {
            sections.append("Independent verifier gaps: \(gaps)")
        }
        if let strategy, !strategy.isEmpty {
            sections.append("Strategist recommendation: \(strategy)")
        }
        sections.append("Evaluator next step: \(nextStep)")
        sections.append("</system-reminder>")
        return sections.joined(separator: "\n")
    }
}

extension GoalTracker {
    @discardableResult
    public mutating func beginRole(
        _ role: GoalOrchestrationRole,
        model: GoalRoleModel,
        runID: String,
        round: UInt32
    ) -> Bool {
        guard isActive else { return false }
        modifySnapshot { snapshot in
            snapshot.currentSubagentID = runID
            snapshot.currentSubagentRole = role.rawValue
            snapshot.phase = role == .planner ? .planning : .executing
            snapshot.planningInFlight = role == .planner
            snapshot.verifyingInFlight = role == .skeptic
            snapshot.roleSnapshots.append(GoalRoleSnapshot(
                role: role,
                model: model.model,
                agentType: model.agentType,
                runID: runID,
                round: round
            ))
            if snapshot.roleSnapshots.count > 64 {
                snapshot.roleSnapshots.removeFirst(snapshot.roleSnapshots.count - 64)
            }
        }
        if role == .planner {
            appendHistory(.now(event: .planningStarted, detail: model.model))
        } else if role == .implementer {
            appendHistory(.now(event: .workerStarted, detail: model.model))
        }
        return true
    }

    @discardableResult
    public mutating func finishRole(
        runID: String,
        state: GoalRoleRunState,
        evidence: String? = nil
    ) -> Bool {
        guard let snapshot = snapshotValue,
              let index = snapshot.roleSnapshots.lastIndex(where: { $0.runID == runID })
        else { return false }
        let role = snapshot.roleSnapshots[index].role
        modifySnapshot { current in
            current.roleSnapshots[index].state = state
            current.roleSnapshots[index].evidence = evidence.map {
                GoalOrchestrationEngine.cappedText($0, maximumBytes: 500)
            }
            if current.currentSubagentID == runID {
                current.currentSubagentID = nil
                current.currentSubagentRole = nil
            }
            if role == .planner { current.planningInFlight = false }
            if role == .skeptic { current.verifyingInFlight = false }
            if current.status == .active { current.phase = .executing }
        }
        if role == .planner {
            appendHistory(.now(
                event: state == .succeeded ? .planningCompleted : .planningFailed,
                detail: evidence
            ))
        }
        return true
    }

    @discardableResult
    public mutating func recordWorkerRound(evidence: String, failed: Bool = false) -> UInt32 {
        guard isActive else { return 0 }
        var round: UInt32 = 0
        modifySnapshot { snapshot in
            snapshot.totalWorkerRounds = snapshot.totalWorkerRounds == .max
                ? .max
                : snapshot.totalWorkerRounds + 1
            round = snapshot.totalWorkerRounds
        }
        var entry = GoalHistoryEntry.now(
            event: failed ? .workerFailed : .workerCompleted,
            detail: GoalOrchestrationEngine.cappedText(evidence, maximumBytes: 500)
        )
        entry.round = round
        appendHistory(entry)
        return round
    }

    @discardableResult
    public mutating func reserveVerificationAttempt(maximumAttempts: UInt32) -> UInt32? {
        guard isActive,
              let snapshot = snapshotValue,
              snapshot.classifierRunsAttempted < maximumAttempts
        else { return nil }
        var attempt: UInt32 = 0
        modifySnapshot { current in
            current.classifierRunsAttempted += 1
            current.classifierMaxRuns = maximumAttempts
            current.roundsSinceVerify = 0
            current.totalVerifyRounds = current.totalVerifyRounds == .max
                ? .max
                : current.totalVerifyRounds + 1
            attempt = current.classifierRunsAttempted
        }
        return attempt
    }
}
