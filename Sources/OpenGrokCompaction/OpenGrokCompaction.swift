import Foundation
import OpenGrokChatState
import OpenGrokSamplingTypes
import OpenGrokTokenEstimation

public let DEFAULT_COMPACTION_MODEL_NAME = "grok-4.20"
public let DEFAULT_AUTO_COMPACT_THRESHOLD_PERCENT: UInt8 = 85
public let MIN_SUMMARY_SEED_CHARS = 500
public let CODEX_REMOTE_COMPACTION_V2_RETAINED_USER_TOKENS: UInt64 = 64_000

public enum CompactionTarget: String, Codable, Sendable, Equatable, Hashable {
    case stepsOnly = "steps_only"
    case historyOnly = "history_only"
    case historyThenSteps = "history_then_steps"
    case fullReplace = "full_replace"

    public static var steps: Self { .stepsOnly }
    public static var history: Self { .historyOnly }
}

public enum IntraSummarizer: String, Codable, Sendable, Equatable, Hashable {
    case shared
    case legacy
}

public struct CompactionPolicy: Codable, Sendable, Equatable, Hashable {
    public var enabled: Bool
    public var mode: CompactionTarget
    public var triggerThresholdPercent: UInt8
    public var minStepsBeforeCompact: UInt32
    public var minCompactableTokens: UInt64
    public var maxReductionRatio: Double
    public var compactionModelName: String?
    public var samplingTimeoutSeconds: UInt64
    public var maxAttempts: UInt32
    public var retryDelayMilliseconds: UInt64
    public var compactionVersion: String
    public var summarizer: IntraSummarizer
    public var targetThresholdPercent: UInt8
    public var stepsTriggerRatio: Double
    public var userMessageTruncateCharacters: UInt32

    public init(
        enabled: Bool = false,
        mode: CompactionTarget = .fullReplace,
        triggerThresholdPercent: UInt8 = DEFAULT_AUTO_COMPACT_THRESHOLD_PERCENT,
        minStepsBeforeCompact: UInt32 = 3,
        minCompactableTokens: UInt64 = 5_000,
        maxReductionRatio: Double = 0.8,
        compactionModelName: String? = DEFAULT_COMPACTION_MODEL_NAME,
        samplingTimeoutSeconds: UInt64 = 120,
        maxAttempts: UInt32 = 2,
        retryDelayMilliseconds: UInt64 = 3_000,
        compactionVersion: String = "intra-v1",
        summarizer: IntraSummarizer = .shared,
        targetThresholdPercent: UInt8 = 50,
        stepsTriggerRatio: Double = 0.3,
        userMessageTruncateCharacters: UInt32 = 3_000
    ) {
        self.enabled = enabled
        self.mode = mode
        self.triggerThresholdPercent = triggerThresholdPercent
        self.minStepsBeforeCompact = minStepsBeforeCompact
        self.minCompactableTokens = minCompactableTokens
        self.maxReductionRatio = maxReductionRatio
        self.compactionModelName = compactionModelName
        self.samplingTimeoutSeconds = samplingTimeoutSeconds
        self.maxAttempts = maxAttempts
        self.retryDelayMilliseconds = retryDelayMilliseconds
        self.compactionVersion = compactionVersion
        self.summarizer = summarizer
        self.targetThresholdPercent = targetThresholdPercent
        self.stepsTriggerRatio = stepsTriggerRatio
        self.userMessageTruncateCharacters = userMessageTruncateCharacters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            mode: try container.decodeIfPresent(CompactionTarget.self, forKey: .mode) ?? .fullReplace,
            triggerThresholdPercent: try container.decodeIfPresent(UInt8.self, forKey: .triggerThresholdPercent) ?? DEFAULT_AUTO_COMPACT_THRESHOLD_PERCENT,
            minStepsBeforeCompact: try container.decodeIfPresent(UInt32.self, forKey: .minStepsBeforeCompact) ?? 3,
            minCompactableTokens: try container.decodeIfPresent(UInt64.self, forKey: .minCompactableTokens) ?? 5_000,
            maxReductionRatio: try container.decodeIfPresent(Double.self, forKey: .maxReductionRatio) ?? 0.8,
            compactionModelName: try container.decodeIfPresent(String.self, forKey: .compactionModelName) ?? DEFAULT_COMPACTION_MODEL_NAME,
            samplingTimeoutSeconds: try container.decodeIfPresent(UInt64.self, forKey: .samplingTimeoutSeconds) ?? 120,
            maxAttempts: try container.decodeIfPresent(UInt32.self, forKey: .maxAttempts) ?? 2,
            retryDelayMilliseconds: try container.decodeIfPresent(UInt64.self, forKey: .retryDelayMilliseconds) ?? 3_000,
            compactionVersion: try container.decodeIfPresent(String.self, forKey: .compactionVersion) ?? "intra-v1",
            summarizer: try container.decodeIfPresent(IntraSummarizer.self, forKey: .summarizer) ?? .shared,
            targetThresholdPercent: try container.decodeIfPresent(UInt8.self, forKey: .targetThresholdPercent) ?? 50,
            stepsTriggerRatio: try container.decodeIfPresent(Double.self, forKey: .stepsTriggerRatio) ?? 0.3,
            userMessageTruncateCharacters: try container.decodeIfPresent(UInt32.self, forKey: .userMessageTruncateCharacters) ?? 3_000
        )
    }

    public var effectiveCompactionModelName: String {
        guard let value = compactionModelName?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return DEFAULT_COMPACTION_MODEL_NAME
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode
        case triggerThresholdPercent = "trigger_threshold_percent"
        case minStepsBeforeCompact = "min_steps_before_compact"
        case minCompactableTokens = "min_compactable_tokens"
        case maxReductionRatio = "max_reduction_ratio"
        case compactionModelName = "compaction_model_name"
        case samplingTimeoutSeconds = "sampling_timeout_secs"
        case maxAttempts = "max_attempts"
        case retryDelayMilliseconds = "retry_delay_ms"
        case compactionVersion = "compaction_version"
        case summarizer
        case targetThresholdPercent = "target_threshold_percent"
        case stepsTriggerRatio = "steps_trigger_ratio"
        case userMessageTruncateCharacters = "user_message_truncate_chars"
    }
}

public enum CompactionTriggerReason: String, Codable, Sendable, Equatable, Hashable {
    case tokenThreshold = "token_threshold"
    case modelCompatibility = "model_compatibility"
    case manual
    case forced
}

public struct CompactionTrigger: Codable, Sendable, Equatable, Hashable {
    public var lastPromptTokens: UInt64
    public var contextWindow: UInt64
    public var utilizationPercent: UInt8
    public var step: UInt32
    public var reason: CompactionTriggerReason

    public init(
        lastPromptTokens: UInt64,
        contextWindow: UInt64,
        utilizationPercent: UInt8,
        step: UInt32,
        reason: CompactionTriggerReason = .tokenThreshold
    ) {
        self.lastPromptTokens = lastPromptTokens
        self.contextWindow = contextWindow
        self.utilizationPercent = utilizationPercent
        self.step = step
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case lastPromptTokens = "last_prompt_tokens"
        case contextWindow = "context_window"
        case utilizationPercent = "utilization_percent"
        case step, reason
    }
}

public func shouldCompact(
    policy: CompactionPolicy,
    lastPromptTokens: UInt64,
    contextWindow: UInt64,
    currentStep: UInt32
) -> CompactionTrigger? {
    guard policy.enabled, contextWindow > 0 else { return nil }
    if policy.mode != .fullReplace && currentStep < policy.minStepsBeforeCompact {
        return nil
    }
    let threshold = saturatingMultiply(contextWindow, UInt64(policy.triggerThresholdPercent)) / 100
    guard lastPromptTokens > threshold else { return nil }
    let percentage = UInt8(min(UInt64(100), saturatingMultiply(lastPromptTokens, 100) / contextWindow))
    return CompactionTrigger(
        lastPromptTokens: lastPromptTokens,
        contextWindow: contextWindow,
        utilizationPercent: percentage,
        step: currentStep
    )
}

public struct ModelCompactionContract: Codable, Sendable, Equatable, Hashable {
    public var modelSlug: String
    public var contextWindow: UInt64
    public var autoCompactTokenLimit: UInt64?
    public var compactionHash: String?

    public init(
        modelSlug: String,
        contextWindow: UInt64,
        autoCompactTokenLimit: UInt64? = nil,
        compactionHash: String? = nil
    ) {
        self.modelSlug = modelSlug
        self.contextWindow = contextWindow
        self.autoCompactTokenLimit = autoCompactTokenLimit
        self.compactionHash = compactionHash
    }

    private enum CodingKeys: String, CodingKey {
        case modelSlug = "model_slug"
        case contextWindow = "context_window"
        case autoCompactTokenLimit = "auto_compact_token_limit"
        case compactionHash = "comp_hash"
    }
}

public struct CompactionBudget: Codable, Sendable, Equatable, Hashable {
    public var contextWindow: UInt64
    public var triggerTokenLimit: UInt64
    public var targetTokenLimit: UInt64
    public var source: String
    public var compatibilityRequired: Bool

    public init(
        contextWindow: UInt64,
        triggerTokenLimit: UInt64,
        targetTokenLimit: UInt64,
        source: String,
        compatibilityRequired: Bool = false
    ) {
        self.contextWindow = contextWindow
        self.triggerTokenLimit = triggerTokenLimit
        self.targetTokenLimit = targetTokenLimit
        self.source = source
        self.compatibilityRequired = compatibilityRequired
    }

    private enum CodingKeys: String, CodingKey {
        case contextWindow = "context_window"
        case triggerTokenLimit = "trigger_token_limit"
        case targetTokenLimit = "target_token_limit"
        case source
        case compatibilityRequired = "compatibility_required"
    }
}

public func resolveCompactionBudget(
    contextWindow: UInt64,
    defaultThresholdPercent: UInt8 = DEFAULT_AUTO_COMPACT_THRESHOLD_PERCENT,
    targetThresholdPercent: UInt8 = 50,
    explicitTokenLimit: UInt64? = nil,
    modelTokenLimit: UInt64? = nil,
    previousCompactionHash: String? = nil,
    currentCompactionHash: String? = nil
) -> CompactionBudget {
    let rawLimit: UInt64
    let source: String
    if let explicitTokenLimit {
        rawLimit = explicitTokenLimit
        source = "operator"
    } else if let modelTokenLimit {
        rawLimit = min(modelTokenLimit, saturatingMultiply(contextWindow, 90) / 100)
        source = "model"
    } else {
        rawLimit = saturatingMultiply(contextWindow, UInt64(defaultThresholdPercent)) / 100
        source = "default"
    }
    let trigger = min(rawLimit, contextWindow)
    let target = min(
        saturatingMultiply(contextWindow, UInt64(targetThresholdPercent)) / 100,
        trigger
    )
    let compatibilityRequired = currentCompactionHash != nil
        && previousCompactionHash != nil
        && currentCompactionHash != previousCompactionHash
    return CompactionBudget(
        contextWindow: contextWindow,
        triggerTokenLimit: trigger,
        targetTokenLimit: target,
        source: source,
        compatibilityRequired: compatibilityRequired
    )
}

public enum CompactionFailureKind: String, Codable, Sendable, Equatable, Hashable {
    case deterministic
    case transient
}

public enum CompactionSuppression: String, Codable, Sendable, Equatable, Hashable {
    case none
    case turn
    case sticky
    case untilSuccess = "until_success"
    case auth
}

public struct CompactionOperationState: Codable, Sendable, Equatable, Hashable {
    public var operationID: String
    public var target: CompactionTarget
    public var snapshotFingerprint: UInt64
    public var promptIndex: Int
    public var attempts: UInt32

    public init(
        operationID: String,
        target: CompactionTarget,
        snapshotFingerprint: UInt64,
        promptIndex: Int,
        attempts: UInt32 = 0
    ) {
        self.operationID = operationID
        self.target = target
        self.snapshotFingerprint = snapshotFingerprint
        self.promptIndex = promptIndex
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case target
        case snapshotFingerprint = "snapshot_fingerprint"
        case promptIndex = "prompt_index"
        case attempts
    }
}

public struct CompactionFailureState: Codable, Sendable, Equatable, Hashable {
    public var kind: CompactionFailureKind
    public var message: String
    public var attempts: UInt32
    public var contextOverflow: Bool

    public init(
        kind: CompactionFailureKind,
        message: String,
        attempts: UInt32,
        contextOverflow: Bool = false
    ) {
        self.kind = kind
        self.message = message
        self.attempts = attempts
        self.contextOverflow = contextOverflow
    }

    private enum CodingKeys: String, CodingKey {
        case kind, message, attempts
        case contextOverflow = "context_overflow"
    }
}

public struct CompactionPersistenceState: Codable, Sendable, Equatable, Hashable {
    public var suppression: CompactionSuppression
    public var operation: CompactionOperationState?
    public var lastFailure: CompactionFailureState?
    public var compactionCount: UInt64
    public var lastCompactionPromptIndex: Int?
    public var previousModel: ModelCompactionContract?

    public init(
        suppression: CompactionSuppression = .none,
        operation: CompactionOperationState? = nil,
        lastFailure: CompactionFailureState? = nil,
        compactionCount: UInt64 = 0,
        lastCompactionPromptIndex: Int? = nil,
        previousModel: ModelCompactionContract? = nil
    ) {
        self.suppression = suppression
        self.operation = operation
        self.lastFailure = lastFailure
        self.compactionCount = compactionCount
        self.lastCompactionPromptIndex = lastCompactionPromptIndex
        self.previousModel = previousModel
    }

    private enum CodingKeys: String, CodingKey {
        case suppression, operation
        case lastFailure = "last_failure"
        case compactionCount = "compaction_count"
        case lastCompactionPromptIndex = "last_compaction_prompt_index"
        case previousModel = "previous_model"
    }

    public mutating func begin(
        operationID: String,
        target: CompactionTarget,
        snapshot: [ConversationItem],
        promptIndex: Int
    ) -> Bool {
        guard operation == nil else { return false }
        operation = CompactionOperationState(
            operationID: operationID,
            target: target,
            snapshotFingerprint: compactionFingerprint(snapshot),
            promptIndex: promptIndex
        )
        lastFailure = nil
        return true
    }

    public mutating func recordAttempt() {
        guard var operation else { return }
        operation.attempts = operation.attempts.addingReportingOverflow(1).partialValue
        self.operation = operation
    }

    public mutating func commitSuccess(promptIndex: Int, model: ModelCompactionContract? = nil) {
        operation = nil
        lastFailure = nil
        suppression = .none
        compactionCount = compactionCount.addingReportingOverflow(1).partialValue
        lastCompactionPromptIndex = promptIndex
        previousModel = model
    }

    public mutating func recordFailure(
        _ failure: CompactionFailureState,
        suppression: CompactionSuppression
    ) {
        operation = nil
        lastFailure = failure
        self.suppression = suppression
    }

    public mutating func beginTurn() {
        if suppression == .turn { suppression = .none }
    }

    public mutating func clearForContextChange() {
        if suppression == .sticky || suppression == .untilSuccess { suppression = .none }
    }

    public mutating func clearAfterAuthRefresh() {
        if suppression == .auth { suppression = .none }
    }
}

public enum CompactionCommitResult: String, Sendable, Equatable, Hashable {
    case applied
    case staleSnapshot = "stale_snapshot"
    case emptyReplacement = "empty_replacement"
}

public func commitCompactionReplacement(
    snapshot: [ConversationItem],
    current: [ConversationItem],
    replacement: [ConversationItem]
) -> CompactionCommitResult {
    guard !replacement.isEmpty else { return .emptyReplacement }
    guard snapshot == current else { return .staleSnapshot }
    return .applied
}

public func compactionMeetsReductionGuard(
    tokensBefore: UInt64,
    tokensAfter: UInt64,
    maxReductionRatio: Double
) -> Bool {
    guard tokensBefore > 0, maxReductionRatio >= 0 else { return false }
    return Double(tokensAfter) <= Double(tokensBefore) * maxReductionRatio
}

public func shouldCompactStepsAfterHistory(
    stepsTokens: UInt64,
    historyTokens: UInt64,
    policy: CompactionPolicy
) -> Bool {
    guard policy.mode == .historyThenSteps else { return false }
    let ratioThreshold = ceil(Double(historyTokens) * policy.stepsTriggerRatio)
    return Double(stepsTokens) > ratioThreshold
}

public func suppressionForCompactionFailure(_ error: CompactionSampleError) -> CompactionSuppression {
    if error.isContextOverflow { return .untilSuccess }
    if case .api(let status, _) = error, status == 401 { return .auth }
    return error.isDeterministic ? .sticky : .turn
}

public func compactionFingerprint(_ items: [ConversationItem]) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for item in items {
        let encoded = (try? JSONEncoder().encode(item)) ?? Data(item.textContent().utf8)
        for byte in encoded {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        hash ^= 0xff
        hash = hash &* 1_099_511_628_211
    }
    return hash
}

public struct CompactionPrompt: Codable, Sendable, Equatable, Hashable {
    public var system: String
    public var user: String

    public init(system: String = "", user: String) {
        self.system = system
        self.user = user
    }
}

public enum SummaryPromptKind: String, Codable, Sendable, Equatable, Hashable {
    case structured
    case selfSummarization = "self_summarization"
}

public func buildSummaryPrompt(userContext: String? = nil) -> String {
    buildSummaryPrompt(kind: .structured, userContext: userContext)
}

public func buildSummaryPrompt(kind: SummaryPromptKind, userContext: String? = nil) -> String {
    let context = userContext.map { value in
        "\n\n**User-provided context for this compaction:**\n\(value)\n\nPlease incorporate this context into the relevant sections.\n"
    } ?? ""
    switch kind {
    case .structured:
        return """
        Create a faithful continuation summary of the Open Grok conversation so far. Preserve the user's explicit requests, decisions, files, code changes, tool results, errors, verification, and pending work. Only use information present in the conversation. Keep Open Grok branding and exact file paths intact.

        Return only one <summary> block with these numbered sections:
        1. Primary Request and Intent
        2. Key Technical Concepts
        3. Files and Code Sections
        4. Errors and Fixes
        5. Problem Solving
        6. All User Messages
        7. Pending Tasks
        8. Current Work
        9. Optional Next Step
        \(context)
        """
    case .selfSummarization:
        return """
        Summarize the tool-call history for the Open Grok assistant. Preserve all facts needed to continue the current task, including file paths, commands, code signatures, errors, and user corrections. Return a concise continuation summary inside one <summary> block.
        \(context)
        """
    }
}

public func formatCompactionPrompt() -> CompactionPrompt {
    CompactionPrompt(
        system: "You are summarizing the tool-call history of an Open Grok assistant that is partway through answering a user's question.",
        user: "Create a detailed continuation summary. Preserve prior compaction summaries, exact paths, commands, code, errors, and pending work."
    )
}

public func formatCompactSummary(_ rawSummary: String) -> String {
    var result = rawSummary

    while let startRange = result.range(of: "<analysis>") {
        let summaryStart = result.range(of: "<summary>")?.lowerBound
        let isLeading: Bool
        if let summaryStart {
            isLeading = startRange.lowerBound < summaryStart
                || result[result.index(summaryStart, offsetBy: "<summary>".count)..<startRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            isLeading = result[..<startRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard isLeading else { break }
        if let endRange = result.range(of: "</analysis>", range: startRange.lowerBound..<result.endIndex) {
            result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        } else if let summaryStart {
            result.removeSubrange(startRange.lowerBound..<summaryStart)
            break
        } else {
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
            break
        }
    }

    if let start = result.range(of: "<summary>"),
       let end = result.range(of: "</summary>", options: .backwards),
       start.lowerBound < end.lowerBound {
        let innerStart = start.upperBound
        let inner = result[innerStart..<end.lowerBound]
        result = String(result[..<start.lowerBound])
            + "Summary:\n"
            + String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            + String(result[end.upperBound...])
    }

    result = result
        .replacingOccurrences(of: "</summary>", with: "<\u{200B}/summary>")
        .replacingOccurrences(of: "<summary>", with: "<\u{200B}summary>")
        .replacingOccurrences(of: "</analysis>", with: "<\u{200B}/analysis>")
        .replacingOccurrences(of: "<analysis>", with: "<\u{200B}analysis>")
        .replacingOccurrences(of: "</summary_request>", with: "<\u{200B}/summary_request>")
        .replacingOccurrences(of: "<summary_request>", with: "<\u{200B}summary_request>")
    while result.contains("\n\n\n") {
        result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func isDegenerateSummary(_ rawSummary: String) -> Bool {
    formatCompactSummary(rawSummary).count < MIN_SUMMARY_SEED_CHARS
}

public func formatCompactSummaryContent(_ rawSummary: String) -> String {
    "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\n\(formatCompactSummary(rawSummary))"
}

public func wrapUserQuery(_ text: String) -> String {
    "<user_query>\n\(text)\n</user_query>"
}

public struct CompactionSelection: Sendable, Equatable, Hashable {
    public var splitIndex: Int
    public var tokensToCompact: UInt64
    public var tokensToKeep: UInt64

    public init(splitIndex: Int, tokensToCompact: UInt64, tokensToKeep: UInt64) {
        self.splitIndex = splitIndex
        self.tokensToCompact = tokensToCompact
        self.tokensToKeep = tokensToKeep
    }
}

public func selectTurnsToCompact(
    itemTokenCounts: [UInt64],
    items: [ConversationItem],
    targetTokens: UInt64,
    minCompactableTokens: UInt64
) -> CompactionSelection? {
    guard !items.isEmpty, itemTokenCounts.count == items.count else { return nil }
    var kept: UInt64 = 0
    var split = items.count
    for index in stride(from: items.count - 1, through: 0, by: -1) {
        let next = kept.addingReportingOverflow(itemTokenCounts[index])
        if next.overflow || next.partialValue > targetTokens {
            split = index + 1
            break
        }
        kept = next.partialValue
        split = index
    }
    guard split > 0 else { return nil }
    while split < items.count && isToolOutput(items[split]) {
        split += 1
    }
    guard split < items.count else { return nil }
    let compacted = itemTokenCounts[..<split].reduce(0, saturatingAdd)
    guard compacted >= minCompactableTokens else { return nil }
    let retained = itemTokenCounts[split...].reduce(0, saturatingAdd)
    return CompactionSelection(splitIndex: split, tokensToCompact: compacted, tokensToKeep: retained)
}

public func selectTurnsToCompact(
    items: [ConversationItem],
    targetTokens: UInt64,
    minCompactableTokens: UInt64
) -> CompactionSelection? {
    selectTurnsToCompact(
        itemTokenCounts: items.map(estimateItemTokens),
        items: items,
        targetTokens: targetTokens,
        minCompactableTokens: minCompactableTokens
    )
}

public func filterTurnsForBasic(_ turns: [ConversationItem]) -> [ConversationItem] {
    turns.filter { item in
        if case .system = item { return false }
        if case .user(let user) = item, user.syntheticReason == .projectInstructions { return false }
        return true
    }
}

public func filterTurnsForInterCompaction(_ turns: [ConversationItem]) -> [ConversationItem] {
    turns.compactMap { item in
        switch item {
        case .system, .toolResult, .customToolOutput, .backendToolCall, .reasoning:
            return nil
        case .assistant(let assistant):
            guard !assistant.content.isEmpty else { return nil }
            return .assistant(AssistantItem(
                content: assistant.content,
                modelId: assistant.modelId,
                modelFingerprint: assistant.modelFingerprint,
                reasoningEffort: assistant.reasoningEffort
            ))
        case .user:
            return item
        }
    }
}

public func extractRealUserQueries(_ conversation: [ConversationItem]) -> [String] {
    conversation.compactMap { item in
        guard isRealUserTurn(item) else { return nil }
        let text = extractUserQueryText(item.textContent())
        return text.isEmpty ? nil : text
    }
}

public func extractLastRealUserQuery(_ conversation: [ConversationItem]) -> String? {
    extractRealUserQueries(conversation).last
}

public func extractUserQueriesFromTurns(
    _ turns: [ConversationItem],
    maxCharacters: Int = 3_000
) -> String? {
    let queries = turns.compactMap { item -> String? in
        guard isRealUserTurn(item) else { return nil }
        let text = extractUserQueryText(item.textContent())
        guard !text.isEmpty else { return nil }
        let bounded = text.count > maxCharacters ? truncateMiddle(text, maxCharacters: maxCharacters) : text
        return "<grok_query>\(bounded)</grok_query>"
    }
    guard !queries.isEmpty else { return nil }
    return "<grok_user_queries>\n\(queries.joined(separator: "\n"))\n</grok_user_queries>"
}

public struct SeparatedHistoryTurns: Sendable, Equatable {
    public var turnsForLLM: [ConversationItem]
    public var priorUserQueries: String?
    public var hasPriorCompaction: Bool

    public init(turnsForLLM: [ConversationItem], priorUserQueries: String?, hasPriorCompaction: Bool) {
        self.turnsForLLM = turnsForLLM
        self.priorUserQueries = priorUserQueries
        self.hasPriorCompaction = hasPriorCompaction
    }
}

public func separatePriorUserQueries(_ turns: [ConversationItem]) -> SeparatedHistoryTurns {
    var stripped: [ConversationItem] = []
    var prior: [String] = []
    var found = false
    for item in turns {
        guard isCompactionSummary(item) else {
            stripped.append(item)
            continue
        }
        found = true
        let text = item.textContent()
        if let open = text.range(of: "<grok_user_queries>"),
           let close = text.range(of: "</grok_user_queries>", range: open.upperBound..<text.endIndex) {
            prior.append(String(text[open.lowerBound..<close.upperBound]))
            let remainder = String(text[..<open.lowerBound]) + String(text[close.upperBound...])
            if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stripped.append(.userMeta(remainder.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        } else {
            stripped.append(item)
        }
    }
    return SeparatedHistoryTurns(
        turnsForLLM: stripped,
        priorUserQueries: prior.isEmpty ? nil : prior.joined(separator: "\n"),
        hasPriorCompaction: found
    )
}

public func assembleUserQueriesPreamble(prior: String?, current: String?) -> String {
    [prior, current].compactMap { (value: String?) -> String? in
        guard let value, !value.isEmpty else { return nil }
        return value
    }.map { "\($0)\n\n" }.joined()
}

public func buildUserQueriesPreamble(
    turns: [ConversationItem],
    currentUserQueries: String?
) -> String {
    let separated = separatePriorUserQueries(turns)
    return assembleUserQueriesPreamble(prior: separated.priorUserQueries, current: currentUserQueries)
}

public struct CompactedHistoryParts: Sendable, Equatable {
    public var systemMessage: ConversationItem
    public var userMessagePrefix: String
    public var agentsMDReminder: String?
    public var lastUserQuery: String?
    public var recentMessages: [ConversationItem]
    public var compactionSummary: String
    public var systemReminder: String?
    public var transcriptHint: String?

    public init(
        systemMessage: ConversationItem,
        userMessagePrefix: String,
        agentsMDReminder: String? = nil,
        lastUserQuery: String? = nil,
        recentMessages: [ConversationItem] = [],
        compactionSummary: String,
        systemReminder: String? = nil,
        transcriptHint: String? = nil
    ) {
        self.systemMessage = systemMessage
        self.userMessagePrefix = userMessagePrefix
        self.agentsMDReminder = agentsMDReminder
        self.lastUserQuery = lastUserQuery
        self.recentMessages = recentMessages
        self.compactionSummary = compactionSummary
        self.systemReminder = systemReminder
        self.transcriptHint = transcriptHint
    }
}

public func assembleCompactedHistory(_ parts: CompactedHistoryParts) -> [ConversationItem] {
    var history: [ConversationItem] = [
        parts.systemMessage,
        .userMeta(parts.userMessagePrefix)
    ]
    if let reminder = parts.agentsMDReminder {
        history.append(.projectInstructions(reminder))
    }
    if let query = parts.lastUserQuery {
        history.append(.user(wrapUserQuery(query)))
    }
    history.append(contentsOf: parts.recentMessages)
    var summary = formatCompactSummaryContent(parts.compactionSummary)
    if let hint = parts.transcriptHint { summary += hint }
    history.append(.userMeta(summary))
    if let reminder = parts.systemReminder {
        history.append(.systemReminder(reminder))
    }
    return history
}

public struct CompactionHistoryValidation: Sendable, Equatable, Hashable {
    public var invalidToolCallIDs: [String]

    public init(invalidToolCallIDs: [String]) {
        self.invalidToolCallIDs = invalidToolCallIDs
    }

    public var isValid: Bool { invalidToolCallIDs.isEmpty }
}

public func validateCompactedHistory(_ items: [ConversationItem]) -> CompactionHistoryValidation {
    var seen: Set<String> = []
    var invalid: [String] = []
    for item in items {
        switch item {
        case .assistant(let assistant):
            seen.formUnion(assistant.toolCalls.map(\.callId))
        case .toolResult(let result) where !seen.contains(result.toolCallId):
            invalid.append(result.toolCallId)
        case .customToolOutput(let output) where !seen.contains(output.callId):
            invalid.append(output.callId)
        default:
            break
        }
    }
    return CompactionHistoryValidation(invalidToolCallIDs: invalid)
}

public struct CompactionSanitizeResult: Sendable, Equatable {
    public var items: [ConversationItem]
    public var strippedToolCallIDs: [String]

    public init(items: [ConversationItem], strippedToolCallIDs: [String]) {
        self.items = items
        self.strippedToolCallIDs = strippedToolCallIDs
    }
}

public func sanitizeCompactedHistory(_ items: [ConversationItem]) -> CompactionSanitizeResult {
    var seen: Set<String> = []
    var stripped: [String] = []
    let sanitized = items.filter { item in
        switch item {
        case .assistant(let assistant):
            seen.formUnion(assistant.toolCalls.map(\.callId))
            return true
        case .toolResult(let result):
            guard seen.contains(result.toolCallId) else {
                stripped.append(result.toolCallId)
                return false
            }
            return true
        case .customToolOutput(let output):
            guard seen.contains(output.callId) else {
                stripped.append(output.callId)
                return false
            }
            return true
        default:
            return true
        }
    }
    return CompactionSanitizeResult(items: sanitized, strippedToolCallIDs: stripped)
}

public func codexRemoteCompactionV2Interjections(
    snapshot: [ConversationItem],
    current: [ConversationItem]
) -> [ConversationItem]? {
    guard current.count >= snapshot.count,
          Array(current.prefix(snapshot.count)) == snapshot else { return nil }
    return current.dropFirst(snapshot.count).compactMap { item in
        guard case .user(let user) = item else { return nil }
        if user.syntheticReason == nil || user.syntheticReason == .interjection {
            return item
        }
        return nil
    }
}

public func buildCodexRemoteCompactionV2History(
    promptInput: [ConversationItem],
    compactionItem: ConversationItem,
    retainedUserTokenBudget: UInt64 = CODEX_REMOTE_COMPACTION_V2_RETAINED_USER_TOKENS
) -> [ConversationItem] {
    let users = promptInput.compactMap(codexRetainedUser)
    var remaining = retainedUserTokenBudget
    var retained: [ConversationItem] = []
    for item in users.reversed() {
        guard remaining > 0 else { break }
        let cost = codexUserTextTokens(item)
        if cost <= remaining {
            retained.append(item)
            remaining -= cost
        } else if let partial = truncateCodexUser(item, to: remaining) {
            retained.append(partial)
            remaining = 0
        }
    }
    retained.reverse()
    retained.append(compactionItem)
    return retained
}

private func isRealUserTurn(_ item: ConversationItem) -> Bool {
    guard case .user(let user) = item else { return false }
    return user.syntheticReason == nil && !extractUserQueryText(item.textContent()).isEmpty
}

private func isCompactionSummary(_ item: ConversationItem) -> Bool {
    guard case .user(let user) = item else { return false }
    guard user.syntheticReason == .compactionMeta else { return false }
    let text = item.textContent()
    return text.contains("<grok_user_queries>") || text.contains("This session is being continued")
}

private func extractUserQueryText(_ text: String) -> String {
    if let open = text.range(of: "<user_query>"),
       let close = text.range(of: "</user_query>", range: open.upperBound..<text.endIndex) {
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func truncateMiddle(_ text: String, maxCharacters: Int) -> String {
    guard maxCharacters > 0, text.count > maxCharacters else { return text }
    let marker = "...[truncated]..."
    guard maxCharacters > marker.count else { return String(text.prefix(maxCharacters)) }
    let left = (maxCharacters - marker.count) / 2
    let right = maxCharacters - marker.count - left
    return String(text.prefix(left)) + marker + String(text.suffix(right))
}

private func isToolOutput(_ item: ConversationItem) -> Bool {
    switch item {
    case .toolResult, .customToolOutput: return true
    default: return false
    }
}

private func codexRetainedUser(_ item: ConversationItem) -> ConversationItem? {
    guard case .user(let user) = item else { return nil }
    guard user.syntheticReason == nil || user.syntheticReason == .interjection else { return nil }
    var copy = user
    copy.content = user.content.compactMap { part in
        switch part {
        case .image:
            return part
        case .text(let text):
            let extracted = extractUserQueryText(text)
            return extracted.isEmpty ? nil : .text(text: extracted)
        }
    }
    return copy.content.isEmpty ? nil : .user(copy)
}

private func codexUserTextTokens(_ item: ConversationItem) -> UInt64 {
    guard case .user(let user) = item else { return 0 }
    let textBytes = user.content.reduce(0) { partial, part in
        if case .text(let text) = part { return partial + text.utf8.count }
        return partial
    }
    return max(1, UInt64((textBytes + 3) / 4))
}

private func truncateCodexUser(_ item: ConversationItem, to maxTokens: UInt64) -> ConversationItem? {
    guard case .user(var user) = item else { return nil }
    var remaining = maxTokens
    var content: [ContentPart] = []
    for part in user.content {
        switch part {
        case .image:
            content.append(part)
        case .text(let text):
            guard remaining > 0 else { continue }
            let fullTokens = UInt64((text.utf8.count + 3) / 4)
            if fullTokens <= remaining {
                content.append(part)
                remaining -= fullTokens
            } else {
                let maxBytes = Int(min(UInt64(Int.max), remaining * 4))
                let prefix = String(decoding: text.utf8.prefix(maxBytes), as: UTF8.self)
                if !prefix.isEmpty { content.append(.text(text: prefix)) }
                remaining = 0
            }
        }
    }
    user.content = content
    guard !content.isEmpty else { return nil }
    return .user(user)
}

private func saturatingMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    return result.overflow ? UInt64.max : result.partialValue
}

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? UInt64.max : result.partialValue
}

public struct LLMCompactionOutput: Sendable, Equatable, Hashable {
    public var response: String
    public var thinking: String

    public init(response: String, thinking: String = "") {
        self.response = response
        self.thinking = thinking
    }
}

public enum CompactionSampleError: Error, Sendable, Equatable, Hashable {
    case timeout(timeoutSeconds: UInt64, collectedBytes: UInt64)
    case build(String)
    case start(String)
    case emptyResponse
    case api(status: Int, message: String)
    case stream(code: String?, message: String)
    case cancelled
    case other(String)

    public var message: String {
        switch self {
        case .timeout(let seconds, let bytes):
            return "Compaction sampling timed out after \(seconds)s (collected \(bytes) bytes so far)"
        case .build(let message): return "Compaction sampler build failed: \(message)"
        case .start(let message): return "Compaction sampler start failed: \(message)"
        case .emptyResponse: return "Compaction sampler returned no response channel content"
        case .api(let status, let message): return "API error (status \(status)): \(message)"
        case .stream(let code, let message): return "Stream error (\(code ?? "unknown")): \(message)"
        case .cancelled: return "Compaction sampling was cancelled"
        case .other(let message): return message
        }
    }

    public var isDeterministic: Bool {
        switch self {
        case .build, .start: return true
        case .api(let status, let message):
            return classifyCompactionHTTPStatus(status, message: message) == .deterministic
        case .stream(let code, let message):
            return classifyCompactionStreamError(code: code, message: message) == .deterministic
        case .timeout, .emptyResponse, .cancelled, .other:
            if case .other(let message) = self {
                return message.contains("Failed to build AgenticScheduler")
                    || message.contains("Failed to start compaction sample")
            }
            return false
        }
    }

    public var isContextOverflow: Bool {
        isCompactionContextLengthError(message)
    }
}

public protocol CompactionSampler: Sendable {
    associatedtype Item: Sendable

    func sampleCompaction(
        turns: [Item],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput
}

public enum CompactionFailureClassification: String, Sendable, Equatable, Hashable {
    case deterministic
    case transient
}

public func isCompactionContextLengthError(_ message: String) -> Bool {
    let lowercased = message.lowercased()
    return lowercased.contains("too long for this model")
        || lowercased.contains("prompt is too long")
        || lowercased.contains("maximum prompt length")
        || lowercased.contains("maximum context length")
        || lowercased.contains("context_length_exceeded")
}

public func classifyCompactionHTTPStatus(
    _ status: Int,
    message: String
) -> CompactionFailureClassification {
    if isCompactionContextLengthError(message)
        || ((400..<500).contains(status) && status != 408 && status != 429) {
        return .deterministic
    }
    return .transient
}

public func classifyCompactionStreamError(
    code: String?,
    message: String
) -> CompactionFailureClassification {
    if code == "invalid_request_error" || message.contains("invalid_request_error") {
        return .deterministic
    }
    if let status = code.flatMap(Int.init),
       (400..<500).contains(status), status != 408, status != 429 {
        return .deterministic
    }
    return isCompactionContextLengthError(message) ? .deterministic : .transient
}

public enum CompactionAttemptOutcome: String, Codable, Sendable, Equatable, Hashable {
    case success
    case empty
    case degenerate
    case deterministic
    case transient
    case cancelled
}

public struct CompactionAttempt: Codable, Sendable, Equatable, Hashable {
    public var attempt: UInt32
    public var outcome: CompactionAttemptOutcome
    public var summaryCharacters: UInt64
    public var summary: String?
    public var error: String?

    public init(
        attempt: UInt32,
        outcome: CompactionAttemptOutcome,
        summaryCharacters: UInt64 = 0,
        summary: String? = nil,
        error: String? = nil
    ) {
        self.attempt = attempt
        self.outcome = outcome
        self.summaryCharacters = summaryCharacters
        self.summary = summary
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case attempt, outcome
        case summaryCharacters = "summary_chars"
        case summary, error
    }
}

public protocol CompactionObserver: Sendable {
    func onAttempt(_ attempt: CompactionAttempt)
    func onSuccess(attempts: UInt32, summaryCharacters: UInt64)
    func onError(attempts: UInt32)
}

public extension CompactionObserver {
    func onAttempt(_ attempt: CompactionAttempt) {}
    func onSuccess(attempts: UInt32, summaryCharacters: UInt64) {}
    func onError(attempts: UInt32) {}
}

public struct NoopCompactionObserver: CompactionObserver, Sendable {
    public init() {}
}

public struct CompactionRetrySuccess: Sendable, Equatable, Hashable {
    public var summary: String
    public var thinking: String
    public var attempts: UInt32

    public init(summary: String, thinking: String, attempts: UInt32) {
        self.summary = summary
        self.thinking = thinking
        self.attempts = attempts
    }
}

public enum CompactionRetryFailure: Error, Sendable, Equatable, Hashable {
    case empty(attempts: UInt32)
    case failure(
        message: String,
        deterministic: Bool,
        contextOverflow: Bool,
        attempts: UInt32
    )

    public var attempts: UInt32 {
        switch self {
        case .empty(let attempts): return attempts
        case .failure(_, _, _, let attempts): return attempts
        }
    }
}

public func sampleCompactionWithRetries<S: CompactionSampler, O: CompactionObserver>(
    sampler: S,
    turns: [S.Item],
    prompt: CompactionPrompt,
    maxAttempts: UInt32,
    retryDelayMilliseconds: UInt64,
    timeoutSeconds: UInt64,
    observer: O = NoopCompactionObserver()
) async throws -> CompactionRetrySuccess {
    let attemptLimit = max(1, maxAttempts)
    for attempt in 1...attemptLimit {
        if Task.isCancelled { throw CompactionRetryFailure.failure(message: "Compaction sampling was cancelled", deterministic: true, contextOverflow: false, attempts: attempt - 1) }
        do {
            let output = try await sampler.sampleCompaction(
                turns: turns,
                prompt: prompt,
                timeoutSeconds: timeoutSeconds
            )
            let trimmed = output.response.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                observer.onAttempt(CompactionAttempt(attempt: attempt, outcome: .empty))
                if attempt == attemptLimit {
                    observer.onError(attempts: attempt)
                    throw CompactionRetryFailure.empty(attempts: attempt)
                }
                try await compactionRetrySleep(milliseconds: retryDelayMilliseconds)
                continue
            }
            if isDegenerateSummary(trimmed) {
                observer.onAttempt(CompactionAttempt(
                    attempt: attempt,
                    outcome: .degenerate,
                    summaryCharacters: UInt64(trimmed.count),
                    summary: boundCompactionOutput(trimmed, maxCharacters: 8_192)
                ))
                if attempt == attemptLimit {
                    observer.onError(attempts: attempt)
                    throw CompactionRetryFailure.empty(attempts: attempt)
                }
                try await compactionRetrySleep(milliseconds: retryDelayMilliseconds)
                continue
            }
            observer.onAttempt(CompactionAttempt(
                attempt: attempt,
                outcome: .success,
                summaryCharacters: UInt64(trimmed.count)
            ))
            observer.onSuccess(attempts: attempt, summaryCharacters: UInt64(trimmed.count))
            return CompactionRetrySuccess(summary: output.response, thinking: output.thinking, attempts: attempt)
        } catch let error as CompactionRetryFailure {
            throw error
        } catch let error as CompactionSampleError {
            let deterministic = error.isDeterministic || error.isContextOverflow
            let contextOverflow = error.isContextOverflow
            let outcome: CompactionAttemptOutcome = deterministic ? .deterministic : .transient
            observer.onAttempt(CompactionAttempt(
                attempt: attempt,
                outcome: outcome,
                error: error.message
            ))
            if deterministic || attempt == attemptLimit {
                observer.onError(attempts: attempt)
                throw CompactionRetryFailure.failure(
                    message: error.message,
                    deterministic: deterministic,
                    contextOverflow: contextOverflow,
                    attempts: attempt
                )
            }
            try await compactionRetrySleep(milliseconds: retryDelayMilliseconds)
        } catch is CancellationError {
            observer.onAttempt(CompactionAttempt(attempt: attempt, outcome: .cancelled))
            observer.onError(attempts: attempt)
            throw CompactionRetryFailure.failure(message: "Compaction sampling was cancelled", deterministic: true, contextOverflow: false, attempts: attempt)
        } catch {
            let mapped = CompactionSampleError.other(String(describing: error))
            observer.onAttempt(CompactionAttempt(attempt: attempt, outcome: .transient, error: mapped.message))
            if attempt == attemptLimit {
                observer.onError(attempts: attempt)
                throw CompactionRetryFailure.failure(message: mapped.message, deterministic: false, contextOverflow: false, attempts: attempt)
            }
            try await compactionRetrySleep(milliseconds: retryDelayMilliseconds)
        }
    }
    throw CompactionRetryFailure.empty(attempts: attemptLimit)
}

public enum FullReplaceCompactionError: Error, Sendable, Equatable, Hashable {
    case nothingToCompact
    case emptyResponse
    case sampler(CompactionRetryFailure)
}

public struct FullReplaceSummary: Sendable, Equatable, Hashable {
    public var summary: String
    public var thinking: String
    public var attempts: UInt32

    public init(summary: String, thinking: String, attempts: UInt32) {
        self.summary = summary
        self.thinking = thinking
        self.attempts = attempts
    }
}

public struct FullReplaceConfig: Codable, Sendable, Equatable, Hashable {
    public var maxAttempts: UInt32
    public var retryDelaySeconds: UInt64
    public var samplingTimeoutSeconds: UInt64

    public init(
        maxAttempts: UInt32 = 3,
        retryDelaySeconds: UInt64 = 3,
        samplingTimeoutSeconds: UInt64 = 120
    ) {
        self.maxAttempts = maxAttempts
        self.retryDelaySeconds = retryDelaySeconds
        self.samplingTimeoutSeconds = samplingTimeoutSeconds
    }

    public var retryDelayMilliseconds: UInt64 {
        saturatingMultiply(retryDelaySeconds, 1_000)
    }

    private enum CodingKeys: String, CodingKey {
        case maxAttempts = "max_attempts"
        case retryDelaySeconds = "retry_delay_secs"
        case samplingTimeoutSeconds = "sampling_timeout_secs"
    }
}

public func sampleFullReplaceSummary<S: CompactionSampler, O: CompactionObserver>(
    sampler: S,
    turns: [S.Item],
    userContext: String? = nil,
    config: FullReplaceConfig = FullReplaceConfig(),
    observer: O = NoopCompactionObserver()
) async throws -> FullReplaceSummary {
    guard !turns.isEmpty else { throw FullReplaceCompactionError.nothingToCompact }
    do {
        let result = try await sampleCompactionWithRetries(
            sampler: sampler,
            turns: turns,
            prompt: CompactionPrompt(user: buildSummaryPrompt(userContext: userContext)),
            maxAttempts: max(1, config.maxAttempts),
            retryDelayMilliseconds: config.retryDelayMilliseconds,
            timeoutSeconds: config.samplingTimeoutSeconds,
            observer: observer
        )
        return FullReplaceSummary(summary: result.summary, thinking: result.thinking, attempts: result.attempts)
    } catch let error as CompactionRetryFailure {
        throw FullReplaceCompactionError.sampler(error)
    }
}

private func boundCompactionOutput(_ text: String, maxCharacters: Int) -> String {
    guard text.count > maxCharacters else { return text }
    let head = maxCharacters / 2
    let tail = maxCharacters - head
    return "\(text.prefix(head))\n\n…[\(text.count - maxCharacters) chars elided]…\n\n\(text.suffix(tail))"
}

private func compactionRetrySleep(milliseconds: UInt64) async throws {
    guard milliseconds > 0 else { return }
    let nanoseconds = min(milliseconds, UInt64.max / 1_000_000) * 1_000_000
    try await Task.sleep(nanoseconds: nanoseconds)
}
