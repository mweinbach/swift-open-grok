// FeedbackTypes.swift
//
// Feedback API request and response types. Ported from
// prod/mc/cli-chat-proxy-types/src/feedback_types.rs.
//
// These types support the feedback collection system for Grok sessions.
// The agent uses heuristics to determine when to request feedback, and
// clients submit feedback through these types to the feedback backend.

import Foundation

// MARK: - Enums

/// Type of client submitting feedback.
public enum ClientType: String, Sendable, Codable, Equatable, Defaultable {
    case agent
    case tui
    case web
    case `extension`
    case nebula
    case desktop

    public static let defaultValue = ClientType.agent
}

/// Type of feedback being submitted.
public enum FeedbackType: String, Sendable, Codable, Equatable, Defaultable {
    case rating
    case text
    case ratingWithText = "rating_with_text"
    case modelPreference = "model_preference"
    case bugReport = "bug_report"
    case featureRequest = "feature_request"

    public static let defaultValue = FeedbackType.rating
}

/// Type of rating scale used.
public enum RatingType: String, Sendable, Codable, Equatable {
    case thumbs
    case stars
    case nps
}

/// Strength of preference in a comparison.
public enum PreferenceStrength: String, Sendable, Codable, Equatable {
    case strong
    case slight
    case tie
    case bothBad = "both_bad"
    case bothGood = "both_good"
}

/// Status of a feedback request.
public enum FeedbackRequestStatus: String, Sendable, Codable, Equatable {
    case pending
    case delivered
    case completed
    case expired
    case dismissed
}

/// Context type for what the feedback is about.
public enum ContextType: String, Sendable, Codable, Equatable {
    case message
    case session
    case feature
    case toolUse = "tool_use"
    case general
}

/// Type of feedback mode requested.
public enum FeedbackMode: String, Sendable, Codable, Equatable {
    case thumbs
    case stars
    case text
    case thumbsText = "thumbs_text"
    case starsText = "stars_text"
    case comparison
    case survey
    case nps
    case npsText = "nps_text"
}

/// Types of session events that can be recorded.
public enum SessionEventType: String, Sendable, Codable, Equatable {
    case cancellation
    case error
    case compaction
    case toolFailure = "tool_failure"
    case regeneration
    case sessionEnd = "session_end"
}

// MARK: - FeedbackContent

/// Allowed `feedback_type` + value-field combinations.
/// Construct submissions via `FeedbackSubmission.withContent`.
public enum FeedbackContent: Sendable, Equatable {
    case rating(ratingType: RatingType, ratingValue: Int32)
    case text(String)
    case ratingWithText(ratingType: RatingType, ratingValue: Int32, text: String)
}

// MARK: - FeedbackSubmission

/// Request body for POST /v1/feedback.
///
/// Construct via `FeedbackSubmission.withContent`; the parameterless `init`
/// exists for builder-style construction and test fixtures and does not
/// produce a valid submission on its own (empty `sessionId`).
public struct FeedbackSubmission: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var userId: String?
    public var authorName: String?
    public var authorEmail: String?
    public var clientType: ClientType
    public var feedbackType: FeedbackType
    public var turnNumber: Int64?
    public var ratingType: RatingType?
    public var ratingValue: Int32?
    public var feedbackText: String?
    public var feedbackCategories: [String]
    public var messageId: String?
    public var modelId: String?
    public var resolvedModelId: String?
    public var modelFingerprint: String?
    public var contextType: ContextType?
    public var featureName: String?
    public var toolName: String?
    public var experimentId: String?
    public var comparisonId: String?
    public var preferredModelId: String?
    public var preferenceStrength: PreferenceStrength?
    public var preferenceReasons: [String]
    public var requestId: String?
    public var clientVersion: String?
    public var shellVersion: String?
    public var extensionHost: String?
    public var metadata: JSONValue?
    public var lastUserMessage: String?
    public var lastAssistantMessage: String?
    public var toolOutcomes: [FeedbackToolOutcome]
    public var sessionCwd: String?
    public var compactionCount: Int64?
    public var contextWindowUsage: UInt8?
    public var contextTokensUsed: UInt64?
    public var contextWindowTokens: UInt64?
    public var terminalInfo: FeedbackTerminalInfo?
    public var unifiedLogURL: String?

    public init() {
        self.sessionId = ""
        self.clientType = .agent
        self.feedbackType = .rating
        self.feedbackCategories = []
        self.preferenceReasons = []
        self.toolOutcomes = []
    }

    /// Construct from typed content; set optional fields after.
    public static func withContent(
        sessionId: String,
        clientType: ClientType,
        content: FeedbackContent
    ) -> FeedbackSubmission {
        var submission = FeedbackSubmission()
        submission.sessionId = sessionId
        submission.clientType = clientType
        submission.applyContent(content)
        return submission
    }

    /// Apply typed content to this submission, resetting value fields.
    public mutating func applyContent(_ content: FeedbackContent) {
        ratingType = nil
        ratingValue = nil
        feedbackText = nil
        switch content {
        case .rating(let type, let value):
            feedbackType = .rating
            ratingType = type
            ratingValue = value
        case .text(let text):
            feedbackType = .text
            feedbackText = text
        case .ratingWithText(let type, let value, let text):
            feedbackType = .ratingWithText
            ratingType = type
            ratingValue = value
            feedbackText = text
        }
    }

    /// Remove session context and model metadata, preserving only the
    /// user's rating/text and essential identifiers.
    public mutating func stripMetadata() {
        modelId = nil
        resolvedModelId = nil
        turnNumber = nil
        lastUserMessage = nil
        lastAssistantMessage = nil
        toolOutcomes = []
        sessionCwd = nil
        compactionCount = nil
        contextWindowUsage = nil
        contextTokensUsed = nil
        contextWindowTokens = nil
        metadata = nil
        terminalInfo = nil
    }

    /// Merge a JSON object into `metadata`, inserting if absent.
    public mutating func mergeMetadata(_ extra: JSONValue) {
        switch (metadata, extra) {
        case (.object(var existing), .object(let src)):
            for (key, value) in src {
                if existing[key] == nil {
                    existing[key] = value
                }
            }
            metadata = .object(existing)
        default:
            metadata = extra
        }
    }

    // MARK: CodingKeys (camelCase)

    enum CodingKeys: String, CodingKey {
        case sessionId
        case userId
        case authorName
        case authorEmail
        case clientType
        case feedbackType
        case turnNumber
        case ratingType
        case ratingValue
        case feedbackText
        case feedbackCategories
        case messageId
        case modelId
        case resolvedModelId
        case modelFingerprint
        case contextType
        case featureName
        case toolName
        case experimentId
        case comparisonId
        case preferredModelId
        case preferenceStrength
        case preferenceReasons
        case requestId
        case clientVersion
        case shellVersion
        case extensionHost
        case metadata
        case lastUserMessage
        case lastAssistantMessage
        case toolOutcomes
        case sessionCwd
        case compactionCount
        case contextWindowUsage
        case contextTokensUsed
        case contextWindowTokens
        case terminalInfo
        // Rust `#[serde(rename_all = "camelCase")]` maps `unified_log_url` →
        // `unifiedLogUrl` (lower-casing the `U` after `_`), NOT Swift's
        // `unifiedLogURL` acronym preservation. Pin the raw value explicitly
        // so Swift round-trips with Rust peers.
        case unifiedLogURL = "unifiedLogUrl"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        authorEmail = try container.decodeIfPresent(String.self, forKey: .authorEmail)
        clientType = try container.decodeIfPresent(ClientType.self, forKey: .clientType) ?? .agent
        feedbackType = try container.decodeIfPresent(FeedbackType.self, forKey: .feedbackType) ?? .rating
        turnNumber = try container.decodeIfPresent(Int64.self, forKey: .turnNumber)
        ratingType = try container.decodeIfPresent(RatingType.self, forKey: .ratingType)
        ratingValue = try container.decodeIfPresent(Int32.self, forKey: .ratingValue)
        feedbackText = try container.decodeIfPresent(String.self, forKey: .feedbackText)
        feedbackCategories = try container.decodeIfPresent([String].self, forKey: .feedbackCategories) ?? []
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        resolvedModelId = try container.decodeIfPresent(String.self, forKey: .resolvedModelId)
        modelFingerprint = try decodeEmptyStringAsNone(from: container, forKey: .modelFingerprint)
        contextType = try container.decodeIfPresent(ContextType.self, forKey: .contextType)
        featureName = try container.decodeIfPresent(String.self, forKey: .featureName)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        comparisonId = try container.decodeIfPresent(String.self, forKey: .comparisonId)
        preferredModelId = try container.decodeIfPresent(String.self, forKey: .preferredModelId)
        preferenceStrength = try container.decodeIfPresent(PreferenceStrength.self, forKey: .preferenceStrength)
        preferenceReasons = try container.decodeIfPresent([String].self, forKey: .preferenceReasons) ?? []
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion)
        shellVersion = try container.decodeIfPresent(String.self, forKey: .shellVersion)
        extensionHost = try container.decodeIfPresent(String.self, forKey: .extensionHost)
        metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
        // Aliases: lastUserMessage and lastAssistantMessage accept old names
        // (lastUserTurn / lastAssistantTurn).
        lastUserMessage = try container.decodeIfPresent(String.self, forKey: .lastUserMessage)
            ?? (try? container.decode(String.self, forKey: .lastUserMessage))
        if lastUserMessage == nil,
           let anyContainer = try? decoder.container(keyedBy: AnyCodingKey.self),
           let val = try? anyContainer.decodeIfPresent(String.self, forKey: AnyCodingKey("last_user_turn")) {
            lastUserMessage = val
        }
        lastAssistantMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        if lastAssistantMessage == nil,
           let anyContainer = try? decoder.container(keyedBy: AnyCodingKey.self),
           let val = try? anyContainer.decodeIfPresent(String.self, forKey: AnyCodingKey("last_assistant_turn")) {
            lastAssistantMessage = val
        }
        toolOutcomes = try container.decodeIfPresent([FeedbackToolOutcome].self, forKey: .toolOutcomes) ?? []
        sessionCwd = try container.decodeIfPresent(String.self, forKey: .sessionCwd)
        compactionCount = try container.decodeIfPresent(Int64.self, forKey: .compactionCount)
        contextWindowUsage = try container.decodeIfPresent(UInt8.self, forKey: .contextWindowUsage)
        contextTokensUsed = try container.decodeIfPresent(UInt64.self, forKey: .contextTokensUsed)
        contextWindowTokens = try container.decodeIfPresent(UInt64.self, forKey: .contextWindowTokens)
        terminalInfo = try container.decodeIfPresent(FeedbackTerminalInfo.self, forKey: .terminalInfo)
        unifiedLogURL = try container.decodeIfPresent(String.self, forKey: .unifiedLogURL)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encodeIfPresent(authorName, forKey: .authorName)
        try container.encodeIfPresent(authorEmail, forKey: .authorEmail)
        try container.encode(clientType, forKey: .clientType)
        try container.encode(feedbackType, forKey: .feedbackType)
        try container.encodeIfPresent(turnNumber, forKey: .turnNumber)
        try container.encodeIfPresent(ratingType, forKey: .ratingType)
        try container.encodeIfPresent(ratingValue, forKey: .ratingValue)
        try container.encodeIfPresent(feedbackText, forKey: .feedbackText)
        if !feedbackCategories.isEmpty {
            try container.encode(feedbackCategories, forKey: .feedbackCategories)
        }
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encodeIfPresent(modelId, forKey: .modelId)
        try container.encodeIfPresent(resolvedModelId, forKey: .resolvedModelId)
        try container.encodeIfPresent(modelFingerprint, forKey: .modelFingerprint)
        try container.encodeIfPresent(contextType, forKey: .contextType)
        try container.encodeIfPresent(featureName, forKey: .featureName)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(experimentId, forKey: .experimentId)
        try container.encodeIfPresent(comparisonId, forKey: .comparisonId)
        try container.encodeIfPresent(preferredModelId, forKey: .preferredModelId)
        try container.encodeIfPresent(preferenceStrength, forKey: .preferenceStrength)
        if !preferenceReasons.isEmpty {
            try container.encode(preferenceReasons, forKey: .preferenceReasons)
        }
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encodeIfPresent(clientVersion, forKey: .clientVersion)
        try container.encodeIfPresent(shellVersion, forKey: .shellVersion)
        try container.encodeIfPresent(extensionHost, forKey: .extensionHost)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(lastUserMessage, forKey: .lastUserMessage)
        try container.encodeIfPresent(lastAssistantMessage, forKey: .lastAssistantMessage)
        if !toolOutcomes.isEmpty {
            try container.encode(toolOutcomes, forKey: .toolOutcomes)
        }
        try container.encodeIfPresent(sessionCwd, forKey: .sessionCwd)
        try container.encodeIfPresent(compactionCount, forKey: .compactionCount)
        try container.encodeIfPresent(contextWindowUsage, forKey: .contextWindowUsage)
        try container.encodeIfPresent(contextTokensUsed, forKey: .contextTokensUsed)
        try container.encodeIfPresent(contextWindowTokens, forKey: .contextWindowTokens)
        try container.encodeIfPresent(terminalInfo, forKey: .terminalInfo)
        try container.encodeIfPresent(unifiedLogURL, forKey: .unifiedLogURL)
    }
}

// MARK: - FeedbackTerminalInfo

/// Snapshot of the user's terminal environment at feedback time.
public struct FeedbackTerminalInfo: Hashable, Sendable, Codable, Equatable {
    public var brand: String
    public var multiplexer: String
    public var isSSH: Bool
    public var isByobu: Bool
    public var termVar: String
    public var tmuxVersion: String?
    public var hyperlinkOsc8Support: String?
    public var clipboardRoute: String?
    public var clipboardNativeTool: String?
    public var displayServer: String?

    public init(
        brand: String,
        multiplexer: String,
        isSSH: Bool,
        isByobu: Bool,
        termVar: String,
        tmuxVersion: String? = nil,
        hyperlinkOsc8Support: String? = nil,
        clipboardRoute: String? = nil,
        clipboardNativeTool: String? = nil,
        displayServer: String? = nil
    ) {
        self.brand = brand
        self.multiplexer = multiplexer
        self.isSSH = isSSH
        self.isByobu = isByobu
        self.termVar = termVar
        self.tmuxVersion = tmuxVersion
        self.hyperlinkOsc8Support = hyperlinkOsc8Support
        self.clipboardRoute = clipboardRoute
        self.clipboardNativeTool = clipboardNativeTool
        self.displayServer = displayServer
    }

    enum CodingKeys: String, CodingKey {
        case brand
        case multiplexer
        // Rust `#[serde(rename_all = "camelCase")]` maps `is_ssh` →
        // `isSsh` (lower-casing the second `S`), NOT Swift's `isSSH`
        // acronym preservation. Pin the raw value explicitly so Swift
        // round-trips with Rust peers.
        case isSSH = "isSsh"
        case isByobu
        case termVar
        case tmuxVersion
        case hyperlinkOsc8Support
        case clipboardRoute
        case clipboardNativeTool
        case displayServer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brand = try container.decode(String.self, forKey: .brand)
        multiplexer = try container.decode(String.self, forKey: .multiplexer)
        isSSH = try container.decode(Bool.self, forKey: .isSSH)
        isByobu = try container.decode(Bool.self, forKey: .isByobu)
        termVar = try container.decode(String.self, forKey: .termVar)
        tmuxVersion = try container.decodeIfPresent(String.self, forKey: .tmuxVersion)
        hyperlinkOsc8Support = try container.decodeIfPresent(String.self, forKey: .hyperlinkOsc8Support)
        clipboardRoute = try container.decodeIfPresent(String.self, forKey: .clipboardRoute)
        clipboardNativeTool = try container.decodeIfPresent(String.self, forKey: .clipboardNativeTool)
        displayServer = try container.decodeIfPresent(String.self, forKey: .displayServer)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(brand, forKey: .brand)
        try container.encode(multiplexer, forKey: .multiplexer)
        try container.encode(isSSH, forKey: .isSSH)
        try container.encode(isByobu, forKey: .isByobu)
        try container.encode(termVar, forKey: .termVar)
        try container.encodeIfPresent(tmuxVersion, forKey: .tmuxVersion)
        try container.encodeIfPresent(hyperlinkOsc8Support, forKey: .hyperlinkOsc8Support)
        try container.encodeIfPresent(clipboardRoute, forKey: .clipboardRoute)
        try container.encodeIfPresent(clipboardNativeTool, forKey: .clipboardNativeTool)
        try container.encodeIfPresent(displayServer, forKey: .displayServer)
    }
}

// MARK: - FeedbackToolOutcome

/// Per-tool call/failure counts for a single tool in a turn.
public struct FeedbackToolOutcome: Hashable, Sendable, Codable, Equatable {
    public var toolName: String
    public var calls: UInt32
    public var failures: UInt32

    public init(toolName: String, calls: UInt32, failures: UInt32) {
        self.toolName = toolName
        self.calls = calls
        self.failures = failures
    }

    enum CodingKeys: String, CodingKey {
        case toolName
        case calls
        case failures
    }
}

// MARK: - FeedbackResponse

/// Response from submitting feedback.
public struct FeedbackResponse: Hashable, Sendable, Codable, Equatable {
    public var feedbackId: String
    public var createdAt: Date

    public init(feedbackId: String, createdAt: Date) {
        self.feedbackId = feedbackId
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case feedbackId
        case createdAt
    }
}

// MARK: - FeedbackRequestCompleteRequest

/// Request body for completing a feedback request (with feedback data).
/// POST /v1/feedback/requests/{request_id}/complete
///
/// Uses `#[serde(flatten)]` — the feedback fields are at the top level of
/// the JSON, not nested under a key.
public struct FeedbackRequestCompleteRequest: Hashable, Sendable, Codable, Equatable {
    public var feedback: FeedbackSubmission

    public init(feedback: FeedbackSubmission) {
        self.feedback = feedback
    }

    public init(from decoder: Decoder) throws {
        feedback = try FeedbackSubmission(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try feedback.encode(to: encoder)
    }
}

// MARK: - FeedbackRequestUpdateResponse

/// Response from completing or dismissing a feedback request.
public struct FeedbackRequestUpdateResponse: Hashable, Sendable, Codable, Equatable {
    public var requestId: String
    public var status: FeedbackRequestStatus
    public var feedbackId: String?
    public var updatedAt: Date

    public init(requestId: String, status: FeedbackRequestStatus, feedbackId: String? = nil, updatedAt: Date) {
        self.requestId = requestId
        self.status = status
        self.feedbackId = feedbackId
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case requestId
        case status
        case feedbackId
        case updatedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(feedbackId, forKey: .feedbackId)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - CreateFeedbackRequestInput

/// Request body for creating a new feedback request.
/// POST /v1/feedback/requests
public struct CreateFeedbackRequestInput: Hashable, Sendable, Codable, Equatable {
    public var requestId: String
    public var sessionId: String
    public var clientType: ClientType
    public var feedbackMode: FeedbackMode
    public var feedbackPrompt: String?
    public var priority: Int32
    public var triggerType: String
    public var triggerReason: String?
    public var contextType: ContextType?
    public var contextMessageIds: [String]
    public var expiresAt: Date?
    public var experimentId: String?
    public var triggerCondition: JSONValue?
    public var promptId: String?

    public init(
        requestId: String,
        sessionId: String,
        clientType: ClientType,
        feedbackMode: FeedbackMode,
        feedbackPrompt: String? = nil,
        priority: Int32 = 5,
        triggerType: String,
        triggerReason: String? = nil,
        contextType: ContextType? = nil,
        contextMessageIds: [String] = [],
        expiresAt: Date? = nil,
        experimentId: String? = nil,
        triggerCondition: JSONValue? = nil,
        promptId: String? = nil
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.clientType = clientType
        self.feedbackMode = feedbackMode
        self.feedbackPrompt = feedbackPrompt
        self.priority = priority
        self.triggerType = triggerType
        self.triggerReason = triggerReason
        self.contextType = contextType
        self.contextMessageIds = contextMessageIds
        self.expiresAt = expiresAt
        self.experimentId = experimentId
        self.triggerCondition = triggerCondition
        self.promptId = promptId
    }

    enum CodingKeys: String, CodingKey {
        case requestId
        case sessionId
        case clientType
        case feedbackMode
        case feedbackPrompt
        case priority
        case triggerType
        case triggerReason
        case contextType
        case contextMessageIds
        case expiresAt
        case experimentId
        case triggerCondition
        case promptId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        clientType = try container.decode(ClientType.self, forKey: .clientType)
        feedbackMode = try container.decode(FeedbackMode.self, forKey: .feedbackMode)
        feedbackPrompt = try container.decodeIfPresent(String.self, forKey: .feedbackPrompt)
        priority = try container.decodeIfPresent(Int32.self, forKey: .priority) ?? 5
        triggerType = try container.decode(String.self, forKey: .triggerType)
        triggerReason = try container.decodeIfPresent(String.self, forKey: .triggerReason)
        contextType = try container.decodeIfPresent(ContextType.self, forKey: .contextType)
        contextMessageIds = try container.decodeIfPresent([String].self, forKey: .contextMessageIds) ?? []
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        triggerCondition = try container.decodeIfPresent(JSONValue.self, forKey: .triggerCondition)
        promptId = try container.decodeIfPresent(String.self, forKey: .promptId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(clientType, forKey: .clientType)
        try container.encode(feedbackMode, forKey: .feedbackMode)
        try container.encodeIfPresent(feedbackPrompt, forKey: .feedbackPrompt)
        try container.encode(priority, forKey: .priority)
        try container.encode(triggerType, forKey: .triggerType)
        try container.encodeIfPresent(triggerReason, forKey: .triggerReason)
        try container.encodeIfPresent(contextType, forKey: .contextType)
        if !contextMessageIds.isEmpty {
            try container.encode(contextMessageIds, forKey: .contextMessageIds)
        }
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(experimentId, forKey: .experimentId)
        try container.encodeIfPresent(triggerCondition, forKey: .triggerCondition)
        try container.encodeIfPresent(promptId, forKey: .promptId)
    }
}

/// Response from creating a feedback request.
public struct CreateFeedbackRequestResponse: Hashable, Sendable, Codable, Equatable {
    public var requestId: String
    public var createdAt: Date

    public init(requestId: String, createdAt: Date) {
        self.requestId = requestId
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case requestId
        case createdAt
    }
}

// MARK: - SessionEventRequest / SessionEventResponse

/// Request body for recording a session event.
/// POST /v1/sessions/{session_id}/events
public struct SessionEventRequest: Hashable, Sendable, Codable, Equatable {
    public var eventType: SessionEventType
    public var eventData: JSONValue?
    public var timestamp: Date?

    public init(eventType: SessionEventType, eventData: JSONValue? = nil, timestamp: Date? = nil) {
        self.eventType = eventType
        self.eventData = eventData
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case eventType
        case eventData
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decode(SessionEventType.self, forKey: .eventType)
        eventData = try container.decodeIfPresent(JSONValue.self, forKey: .eventData)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventType, forKey: .eventType)
        try container.encodeIfPresent(eventData, forKey: .eventData)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
    }
}

/// Response from recording a session event.
public struct SessionEventResponse: Hashable, Sendable, Codable, Equatable {
    public var success: Bool
    public var recordedAt: Date

    public init(success: Bool, recordedAt: Date) {
        self.success = success
        self.recordedAt = recordedAt
    }

    enum CodingKeys: String, CodingKey {
        case success
        case recordedAt
    }
}

// MARK: - SessionSignalsUpdate

/// Request body for updating session signals.
/// POST /v1/sessions/{session_id}/signals
public struct SessionSignalsUpdate: Hashable, Sendable, Codable, Equatable {
    public var clientType: ClientType
    public var totalTurns: Int64?
    public var userMessageCount: Int64?
    public var assistantMessageCount: Int64?
    public var cancellationCount: Int64?
    public var consecutiveCancellations: Int64?
    public var errorCount: Int64?
    public var toolFailureCount: Int64?
    public var toolCallCount: Int64?
    public var compactionCount: Int64?
    public var regenerationCount: Int64?
    public var editAndRetryCount: Int64?
    public var positiveRatings: Int64?
    public var negativeRatings: Int64?
    public var longPausesCount: Int64?
    public var sessionDurationSeconds: Int64?
    public var toolsUsed: [String]
    public var modelsUsed: [String]
    public var primaryModelId: String?
    public var avgTimeToFirstTokenMs: Int64?
    public var avgResponseTimeMs: Int64?
    public var minTimeToFirstTokenMs: Int64?
    public var maxTimeToFirstTokenMs: Int64?
    public var latencySampleCount: Int64?
    public var lastItlP50Ms: Int64?
    public var lastItlP99Ms: Int64?
    public var worstItlMaxMs: Int64?
    public var avgItlMeanMs: Int64?
    public var totalChunkCount: Int64?
    public var itlSampleCount: Int64?
    // LOC attribution
    public var agentLinesAdded: Int64?
    public var agentLinesRemoved: Int64?
    public var agentLinesAddedReverted: Int64?
    public var agentLinesRemovedReverted: Int64?
    public var humanLinesAdded: Int64?
    public var humanLinesRemoved: Int64?
    public var humanLinesAddedReverted: Int64?
    public var humanLinesRemovedReverted: Int64?
    public var agentFilesTouched: Int64?
    public var humanFilesTouched: Int64?
    public var totalFilesTouched: Int64?
    // Inference idle timeout tracing
    public var inferenceIdleTimeouts: Int64?
    public var inferenceIdleTimeoutConfiguredSecs: Int64?
    // Doom loop detection tracing
    public var doomLoopWarnings: Int64?
    public var doomLoopTerminations: Int64?
    public var doomLoopThreshold: Int64?
    public var doomLoopRoThreshold: Int64?
    public var doomLoopRecoveryFired: Bool?
    public var doomLoopRecoveryAttempts: Int64?
    public var doomLoopRecoveryAcceptedAfterBudget: Int64?
    public var doomLoopRecoveryTopTrigger: String?
    public var doomLoopRecoveryAbortedChunks: Int64?
    // GCS upload queue tracing
    public var gcsQueueEnqueued: Int64?
    public var gcsQueueUploaded: Int64?
    public var gcsQueueFailed: Int64?
    public var gcsQueueFallbacks: Int64?
    public var gcsQueueCircuitBreakerTrips: Int64?
    public var gcsQueuePending: Int64?
    public var gcsQueuePendingBytes: Int64?
    public var gcsQueueOrphansCleaned: Int64?
    public var metadata: JSONValue?

    public init(clientType: ClientType) {
        self.clientType = clientType
        self.toolsUsed = []
        self.modelsUsed = []
    }

    enum CodingKeys: String, CodingKey {
        case clientType
        case totalTurns
        case userMessageCount
        case assistantMessageCount
        case cancellationCount
        case consecutiveCancellations
        case errorCount
        case toolFailureCount
        case toolCallCount
        case compactionCount
        case regenerationCount
        case editAndRetryCount
        case positiveRatings
        case negativeRatings
        case longPausesCount
        case sessionDurationSeconds
        case toolsUsed
        case modelsUsed
        case primaryModelId
        case avgTimeToFirstTokenMs
        case avgResponseTimeMs
        case minTimeToFirstTokenMs
        case maxTimeToFirstTokenMs
        case latencySampleCount
        case lastItlP50Ms
        case lastItlP99Ms
        case worstItlMaxMs
        case avgItlMeanMs
        case totalChunkCount
        case itlSampleCount
        case agentLinesAdded
        case agentLinesRemoved
        case agentLinesAddedReverted
        case agentLinesRemovedReverted
        case humanLinesAdded
        case humanLinesRemoved
        case humanLinesAddedReverted
        case humanLinesRemovedReverted
        case agentFilesTouched
        case humanFilesTouched
        case totalFilesTouched
        case inferenceIdleTimeouts
        case inferenceIdleTimeoutConfiguredSecs
        case doomLoopWarnings
        case doomLoopTerminations
        case doomLoopThreshold
        case doomLoopRoThreshold
        case doomLoopRecoveryFired
        case doomLoopRecoveryAttempts
        case doomLoopRecoveryAcceptedAfterBudget
        case doomLoopRecoveryTopTrigger
        case doomLoopRecoveryAbortedChunks
        case gcsQueueEnqueued
        case gcsQueueUploaded
        case gcsQueueFailed
        case gcsQueueFallbacks
        case gcsQueueCircuitBreakerTrips
        case gcsQueuePending
        case gcsQueuePendingBytes
        case gcsQueueOrphansCleaned
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientType = try container.decode(ClientType.self, forKey: .clientType)
        totalTurns = try container.decodeIfPresent(Int64.self, forKey: .totalTurns)
        userMessageCount = try container.decodeIfPresent(Int64.self, forKey: .userMessageCount)
        assistantMessageCount = try container.decodeIfPresent(Int64.self, forKey: .assistantMessageCount)
        cancellationCount = try container.decodeIfPresent(Int64.self, forKey: .cancellationCount)
        consecutiveCancellations = try container.decodeIfPresent(Int64.self, forKey: .consecutiveCancellations)
        errorCount = try container.decodeIfPresent(Int64.self, forKey: .errorCount)
        toolFailureCount = try container.decodeIfPresent(Int64.self, forKey: .toolFailureCount)
        toolCallCount = try container.decodeIfPresent(Int64.self, forKey: .toolCallCount)
        compactionCount = try container.decodeIfPresent(Int64.self, forKey: .compactionCount)
        regenerationCount = try container.decodeIfPresent(Int64.self, forKey: .regenerationCount)
        editAndRetryCount = try container.decodeIfPresent(Int64.self, forKey: .editAndRetryCount)
        positiveRatings = try container.decodeIfPresent(Int64.self, forKey: .positiveRatings)
        negativeRatings = try container.decodeIfPresent(Int64.self, forKey: .negativeRatings)
        longPausesCount = try container.decodeIfPresent(Int64.self, forKey: .longPausesCount)
        sessionDurationSeconds = try container.decodeIfPresent(Int64.self, forKey: .sessionDurationSeconds)
        toolsUsed = try container.decodeIfPresent([String].self, forKey: .toolsUsed) ?? []
        modelsUsed = try container.decodeIfPresent([String].self, forKey: .modelsUsed) ?? []
        primaryModelId = try container.decodeIfPresent(String.self, forKey: .primaryModelId)
        avgTimeToFirstTokenMs = try container.decodeIfPresent(Int64.self, forKey: .avgTimeToFirstTokenMs)
        avgResponseTimeMs = try container.decodeIfPresent(Int64.self, forKey: .avgResponseTimeMs)
        minTimeToFirstTokenMs = try container.decodeIfPresent(Int64.self, forKey: .minTimeToFirstTokenMs)
        maxTimeToFirstTokenMs = try container.decodeIfPresent(Int64.self, forKey: .maxTimeToFirstTokenMs)
        latencySampleCount = try container.decodeIfPresent(Int64.self, forKey: .latencySampleCount)
        lastItlP50Ms = try container.decodeIfPresent(Int64.self, forKey: .lastItlP50Ms)
        lastItlP99Ms = try container.decodeIfPresent(Int64.self, forKey: .lastItlP99Ms)
        worstItlMaxMs = try container.decodeIfPresent(Int64.self, forKey: .worstItlMaxMs)
        avgItlMeanMs = try container.decodeIfPresent(Int64.self, forKey: .avgItlMeanMs)
        totalChunkCount = try container.decodeIfPresent(Int64.self, forKey: .totalChunkCount)
        itlSampleCount = try container.decodeIfPresent(Int64.self, forKey: .itlSampleCount)
        agentLinesAdded = try container.decodeIfPresent(Int64.self, forKey: .agentLinesAdded)
        agentLinesRemoved = try container.decodeIfPresent(Int64.self, forKey: .agentLinesRemoved)
        agentLinesAddedReverted = try container.decodeIfPresent(Int64.self, forKey: .agentLinesAddedReverted)
        agentLinesRemovedReverted = try container.decodeIfPresent(Int64.self, forKey: .agentLinesRemovedReverted)
        humanLinesAdded = try container.decodeIfPresent(Int64.self, forKey: .humanLinesAdded)
        humanLinesRemoved = try container.decodeIfPresent(Int64.self, forKey: .humanLinesRemoved)
        humanLinesAddedReverted = try container.decodeIfPresent(Int64.self, forKey: .humanLinesAddedReverted)
        humanLinesRemovedReverted = try container.decodeIfPresent(Int64.self, forKey: .humanLinesRemovedReverted)
        agentFilesTouched = try container.decodeIfPresent(Int64.self, forKey: .agentFilesTouched)
        humanFilesTouched = try container.decodeIfPresent(Int64.self, forKey: .humanFilesTouched)
        totalFilesTouched = try container.decodeIfPresent(Int64.self, forKey: .totalFilesTouched)
        inferenceIdleTimeouts = try container.decodeIfPresent(Int64.self, forKey: .inferenceIdleTimeouts)
        inferenceIdleTimeoutConfiguredSecs = try container.decodeIfPresent(Int64.self, forKey: .inferenceIdleTimeoutConfiguredSecs)
        doomLoopWarnings = try container.decodeIfPresent(Int64.self, forKey: .doomLoopWarnings)
        doomLoopTerminations = try container.decodeIfPresent(Int64.self, forKey: .doomLoopTerminations)
        doomLoopThreshold = try container.decodeIfPresent(Int64.self, forKey: .doomLoopThreshold)
        doomLoopRoThreshold = try container.decodeIfPresent(Int64.self, forKey: .doomLoopRoThreshold)
        doomLoopRecoveryFired = try container.decodeIfPresent(Bool.self, forKey: .doomLoopRecoveryFired)
        doomLoopRecoveryAttempts = try container.decodeIfPresent(Int64.self, forKey: .doomLoopRecoveryAttempts)
        doomLoopRecoveryAcceptedAfterBudget = try container.decodeIfPresent(Int64.self, forKey: .doomLoopRecoveryAcceptedAfterBudget)
        doomLoopRecoveryTopTrigger = try container.decodeIfPresent(String.self, forKey: .doomLoopRecoveryTopTrigger)
        doomLoopRecoveryAbortedChunks = try container.decodeIfPresent(Int64.self, forKey: .doomLoopRecoveryAbortedChunks)
        gcsQueueEnqueued = try container.decodeIfPresent(Int64.self, forKey: .gcsQueueEnqueued)
        gcsQueueUploaded = try container.decodeIfPresent(Int64.self, forKey: .gcsQueueUploaded)
        gcsQueueFailed = try container.decodeIfPresent(Int64.self, forKey: .gcsQueueFailed)
        gcsQueueFallbacks = try container.decodeIfPresent(Int64.self, forKey: .gcsQueueFallbacks)
        gcsQueueCircuitBreakerTrips = try container.decodeIfPresent(Int64.self, forKey: .gcsQueueCircuitBreakerTrips)
        gcsQueuePending = try container.decodeIfPresent(Int64.self, forKey: .gcsQueuePending)
        gcsQueuePendingBytes = try container.decodeIfPresent(Int64.self, forKey: .gcsQueuePendingBytes)
        gcsQueueOrphansCleaned = try container.decodeIfPresent(Int64.self, forKey: .gcsQueueOrphansCleaned)
        metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientType, forKey: .clientType)
        try container.encodeIfPresent(totalTurns, forKey: .totalTurns)
        try container.encodeIfPresent(userMessageCount, forKey: .userMessageCount)
        try container.encodeIfPresent(assistantMessageCount, forKey: .assistantMessageCount)
        try container.encodeIfPresent(cancellationCount, forKey: .cancellationCount)
        try container.encodeIfPresent(consecutiveCancellations, forKey: .consecutiveCancellations)
        try container.encodeIfPresent(errorCount, forKey: .errorCount)
        try container.encodeIfPresent(toolFailureCount, forKey: .toolFailureCount)
        try container.encodeIfPresent(toolCallCount, forKey: .toolCallCount)
        try container.encodeIfPresent(compactionCount, forKey: .compactionCount)
        try container.encodeIfPresent(regenerationCount, forKey: .regenerationCount)
        try container.encodeIfPresent(editAndRetryCount, forKey: .editAndRetryCount)
        try container.encodeIfPresent(positiveRatings, forKey: .positiveRatings)
        try container.encodeIfPresent(negativeRatings, forKey: .negativeRatings)
        try container.encodeIfPresent(longPausesCount, forKey: .longPausesCount)
        try container.encodeIfPresent(sessionDurationSeconds, forKey: .sessionDurationSeconds)
        if !toolsUsed.isEmpty { try container.encode(toolsUsed, forKey: .toolsUsed) }
        if !modelsUsed.isEmpty { try container.encode(modelsUsed, forKey: .modelsUsed) }
        try container.encodeIfPresent(primaryModelId, forKey: .primaryModelId)
        try container.encodeIfPresent(avgTimeToFirstTokenMs, forKey: .avgTimeToFirstTokenMs)
        try container.encodeIfPresent(avgResponseTimeMs, forKey: .avgResponseTimeMs)
        try container.encodeIfPresent(minTimeToFirstTokenMs, forKey: .minTimeToFirstTokenMs)
        try container.encodeIfPresent(maxTimeToFirstTokenMs, forKey: .maxTimeToFirstTokenMs)
        try container.encodeIfPresent(latencySampleCount, forKey: .latencySampleCount)
        try container.encodeIfPresent(lastItlP50Ms, forKey: .lastItlP50Ms)
        try container.encodeIfPresent(lastItlP99Ms, forKey: .lastItlP99Ms)
        try container.encodeIfPresent(worstItlMaxMs, forKey: .worstItlMaxMs)
        try container.encodeIfPresent(avgItlMeanMs, forKey: .avgItlMeanMs)
        try container.encodeIfPresent(totalChunkCount, forKey: .totalChunkCount)
        try container.encodeIfPresent(itlSampleCount, forKey: .itlSampleCount)
        try container.encodeIfPresent(agentLinesAdded, forKey: .agentLinesAdded)
        try container.encodeIfPresent(agentLinesRemoved, forKey: .agentLinesRemoved)
        try container.encodeIfPresent(agentLinesAddedReverted, forKey: .agentLinesAddedReverted)
        try container.encodeIfPresent(agentLinesRemovedReverted, forKey: .agentLinesRemovedReverted)
        try container.encodeIfPresent(humanLinesAdded, forKey: .humanLinesAdded)
        try container.encodeIfPresent(humanLinesRemoved, forKey: .humanLinesRemoved)
        try container.encodeIfPresent(humanLinesAddedReverted, forKey: .humanLinesAddedReverted)
        try container.encodeIfPresent(humanLinesRemovedReverted, forKey: .humanLinesRemovedReverted)
        try container.encodeIfPresent(agentFilesTouched, forKey: .agentFilesTouched)
        try container.encodeIfPresent(humanFilesTouched, forKey: .humanFilesTouched)
        try container.encodeIfPresent(totalFilesTouched, forKey: .totalFilesTouched)
        try container.encodeIfPresent(inferenceIdleTimeouts, forKey: .inferenceIdleTimeouts)
        try container.encodeIfPresent(inferenceIdleTimeoutConfiguredSecs, forKey: .inferenceIdleTimeoutConfiguredSecs)
        try container.encodeIfPresent(doomLoopWarnings, forKey: .doomLoopWarnings)
        try container.encodeIfPresent(doomLoopTerminations, forKey: .doomLoopTerminations)
        try container.encodeIfPresent(doomLoopThreshold, forKey: .doomLoopThreshold)
        try container.encodeIfPresent(doomLoopRoThreshold, forKey: .doomLoopRoThreshold)
        try container.encodeIfPresent(doomLoopRecoveryFired, forKey: .doomLoopRecoveryFired)
        try container.encodeIfPresent(doomLoopRecoveryAttempts, forKey: .doomLoopRecoveryAttempts)
        try container.encodeIfPresent(doomLoopRecoveryAcceptedAfterBudget, forKey: .doomLoopRecoveryAcceptedAfterBudget)
        try container.encodeIfPresent(doomLoopRecoveryTopTrigger, forKey: .doomLoopRecoveryTopTrigger)
        try container.encodeIfPresent(doomLoopRecoveryAbortedChunks, forKey: .doomLoopRecoveryAbortedChunks)
        try container.encodeIfPresent(gcsQueueEnqueued, forKey: .gcsQueueEnqueued)
        try container.encodeIfPresent(gcsQueueUploaded, forKey: .gcsQueueUploaded)
        try container.encodeIfPresent(gcsQueueFailed, forKey: .gcsQueueFailed)
        try container.encodeIfPresent(gcsQueueFallbacks, forKey: .gcsQueueFallbacks)
        try container.encodeIfPresent(gcsQueueCircuitBreakerTrips, forKey: .gcsQueueCircuitBreakerTrips)
        try container.encodeIfPresent(gcsQueuePending, forKey: .gcsQueuePending)
        try container.encodeIfPresent(gcsQueuePendingBytes, forKey: .gcsQueuePendingBytes)
        try container.encodeIfPresent(gcsQueueOrphansCleaned, forKey: .gcsQueueOrphansCleaned)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

// MARK: - SessionSignals

/// Session signals data (for GET response).
public struct SessionSignals: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var userId: String?
    public var clientType: ClientType
    public var sessionStartAt: Date
    public var lastActivityAt: Date
    public var sessionDurationSeconds: Int64?
    public var totalTurns: Int64
    public var userMessageCount: Int64
    public var assistantMessageCount: Int64
    public var cancellationCount: Int64
    public var consecutiveCancellations: Int64
    public var errorCount: Int64
    public var toolFailureCount: Int64
    public var compactionCount: Int64
    public var regenerationCount: Int64
    public var toolsUsed: [String]
    public var modelsUsed: [String]
    public var primaryModelId: String?
    public var avgTimeToFirstTokenMs: Int64
    public var avgResponseTimeMs: Int64
    public var minTimeToFirstTokenMs: Int64
    public var maxTimeToFirstTokenMs: Int64
    public var latencySampleCount: Int64
    public var lastItlP50Ms: Int64?
    public var lastItlP99Ms: Int64?
    public var worstItlMaxMs: Int64
    public var avgItlMeanMs: Int64
    public var totalChunkCount: Int64
    public var itlSampleCount: Int64
    public var feedbackRequestsSent: Int64
    public var feedbackRequestsCompleted: Int64
    public var lastFeedbackRequestAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: JSONValue?

    public init(
        sessionId: String,
        clientType: ClientType,
        sessionStartAt: Date,
        lastActivityAt: Date,
        totalTurns: Int64 = 0,
        userMessageCount: Int64 = 0,
        assistantMessageCount: Int64 = 0,
        cancellationCount: Int64 = 0,
        consecutiveCancellations: Int64 = 0,
        errorCount: Int64 = 0,
        toolFailureCount: Int64 = 0,
        compactionCount: Int64 = 0,
        regenerationCount: Int64 = 0,
        toolsUsed: [String] = [],
        modelsUsed: [String] = [],
        avgTimeToFirstTokenMs: Int64 = 0,
        avgResponseTimeMs: Int64 = 0,
        minTimeToFirstTokenMs: Int64 = 0,
        maxTimeToFirstTokenMs: Int64 = 0,
        latencySampleCount: Int64 = 0,
        worstItlMaxMs: Int64 = 0,
        avgItlMeanMs: Int64 = 0,
        totalChunkCount: Int64 = 0,
        itlSampleCount: Int64 = 0,
        feedbackRequestsSent: Int64 = 0,
        feedbackRequestsCompleted: Int64 = 0,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.clientType = clientType
        self.sessionStartAt = sessionStartAt
        self.lastActivityAt = lastActivityAt
        self.totalTurns = totalTurns
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.cancellationCount = cancellationCount
        self.consecutiveCancellations = consecutiveCancellations
        self.errorCount = errorCount
        self.toolFailureCount = toolFailureCount
        self.compactionCount = compactionCount
        self.regenerationCount = regenerationCount
        self.toolsUsed = toolsUsed
        self.modelsUsed = modelsUsed
        self.avgTimeToFirstTokenMs = avgTimeToFirstTokenMs
        self.avgResponseTimeMs = avgResponseTimeMs
        self.minTimeToFirstTokenMs = minTimeToFirstTokenMs
        self.maxTimeToFirstTokenMs = maxTimeToFirstTokenMs
        self.latencySampleCount = latencySampleCount
        self.worstItlMaxMs = worstItlMaxMs
        self.avgItlMeanMs = avgItlMeanMs
        self.totalChunkCount = totalChunkCount
        self.itlSampleCount = itlSampleCount
        self.feedbackRequestsSent = feedbackRequestsSent
        self.feedbackRequestsCompleted = feedbackRequestsCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case userId
        case clientType
        case sessionStartAt
        case lastActivityAt
        case sessionDurationSeconds
        case totalTurns
        case userMessageCount
        case assistantMessageCount
        case cancellationCount
        case consecutiveCancellations
        case errorCount
        case toolFailureCount
        case compactionCount
        case regenerationCount
        case toolsUsed
        case modelsUsed
        case primaryModelId
        case avgTimeToFirstTokenMs
        case avgResponseTimeMs
        case minTimeToFirstTokenMs
        case maxTimeToFirstTokenMs
        case latencySampleCount
        case lastItlP50Ms
        case lastItlP99Ms
        case worstItlMaxMs
        case avgItlMeanMs
        case totalChunkCount
        case itlSampleCount
        case feedbackRequestsSent
        case feedbackRequestsCompleted
        case lastFeedbackRequestAt
        case createdAt
        case updatedAt
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        clientType = try container.decode(ClientType.self, forKey: .clientType)
        sessionStartAt = try container.decode(Date.self, forKey: .sessionStartAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        sessionDurationSeconds = try container.decodeIfPresent(Int64.self, forKey: .sessionDurationSeconds)
        totalTurns = try container.decodeIfPresent(Int64.self, forKey: .totalTurns) ?? 0
        userMessageCount = try container.decodeIfPresent(Int64.self, forKey: .userMessageCount) ?? 0
        assistantMessageCount = try container.decodeIfPresent(Int64.self, forKey: .assistantMessageCount) ?? 0
        cancellationCount = try container.decodeIfPresent(Int64.self, forKey: .cancellationCount) ?? 0
        consecutiveCancellations = try container.decodeIfPresent(Int64.self, forKey: .consecutiveCancellations) ?? 0
        errorCount = try container.decodeIfPresent(Int64.self, forKey: .errorCount) ?? 0
        toolFailureCount = try container.decodeIfPresent(Int64.self, forKey: .toolFailureCount) ?? 0
        compactionCount = try container.decodeIfPresent(Int64.self, forKey: .compactionCount) ?? 0
        regenerationCount = try container.decodeIfPresent(Int64.self, forKey: .regenerationCount) ?? 0
        toolsUsed = try container.decodeIfPresent([String].self, forKey: .toolsUsed) ?? []
        modelsUsed = try container.decodeIfPresent([String].self, forKey: .modelsUsed) ?? []
        primaryModelId = try container.decodeIfPresent(String.self, forKey: .primaryModelId)
        avgTimeToFirstTokenMs = try container.decodeIfPresent(Int64.self, forKey: .avgTimeToFirstTokenMs) ?? 0
        avgResponseTimeMs = try container.decodeIfPresent(Int64.self, forKey: .avgResponseTimeMs) ?? 0
        minTimeToFirstTokenMs = try container.decodeIfPresent(Int64.self, forKey: .minTimeToFirstTokenMs) ?? 0
        maxTimeToFirstTokenMs = try container.decodeIfPresent(Int64.self, forKey: .maxTimeToFirstTokenMs) ?? 0
        latencySampleCount = try container.decodeIfPresent(Int64.self, forKey: .latencySampleCount) ?? 0
        lastItlP50Ms = try container.decodeIfPresent(Int64.self, forKey: .lastItlP50Ms)
        lastItlP99Ms = try container.decodeIfPresent(Int64.self, forKey: .lastItlP99Ms)
        worstItlMaxMs = try container.decodeIfPresent(Int64.self, forKey: .worstItlMaxMs) ?? 0
        avgItlMeanMs = try container.decodeIfPresent(Int64.self, forKey: .avgItlMeanMs) ?? 0
        totalChunkCount = try container.decodeIfPresent(Int64.self, forKey: .totalChunkCount) ?? 0
        itlSampleCount = try container.decodeIfPresent(Int64.self, forKey: .itlSampleCount) ?? 0
        feedbackRequestsSent = try container.decodeIfPresent(Int64.self, forKey: .feedbackRequestsSent) ?? 0
        feedbackRequestsCompleted = try container.decodeIfPresent(Int64.self, forKey: .feedbackRequestsCompleted) ?? 0
        lastFeedbackRequestAt = try container.decodeIfPresent(Date.self, forKey: .lastFeedbackRequestAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }
}

/// Response for session signals update.
public struct SessionSignalsUpdateResponse: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var updatedAt: Date

    public init(sessionId: String, updatedAt: Date) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case updatedAt
    }
}

// MARK: - FeedbackRequest

/// Pending feedback request (returned by GET /v1/feedback/requests).
public struct FeedbackRequest: Hashable, Sendable, Codable, Equatable {
    public var requestId: String
    public var sessionId: String
    public var feedbackMode: FeedbackMode
    public var feedbackPrompt: String?
    public var priority: Int32
    public var triggerType: String
    public var triggerReason: String?
    public var contextType: ContextType?
    public var contextMessageIds: [String]
    public var status: FeedbackRequestStatus
    public var createdAt: Date
    public var expiresAt: Date?
    public var experimentId: String?
    public var comparisonId: String?

    public init(
        requestId: String,
        sessionId: String,
        feedbackMode: FeedbackMode,
        feedbackPrompt: String? = nil,
        priority: Int32,
        triggerType: String,
        triggerReason: String? = nil,
        contextType: ContextType? = nil,
        contextMessageIds: [String] = [],
        status: FeedbackRequestStatus,
        createdAt: Date,
        expiresAt: Date? = nil,
        experimentId: String? = nil,
        comparisonId: String? = nil
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.feedbackMode = feedbackMode
        self.feedbackPrompt = feedbackPrompt
        self.priority = priority
        self.triggerType = triggerType
        self.triggerReason = triggerReason
        self.contextType = contextType
        self.contextMessageIds = contextMessageIds
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.experimentId = experimentId
        self.comparisonId = comparisonId
    }

    enum CodingKeys: String, CodingKey {
        case requestId
        case sessionId
        case feedbackMode
        case feedbackPrompt
        case priority
        case triggerType
        case triggerReason
        case contextType
        case contextMessageIds
        case status
        case createdAt
        case expiresAt
        case experimentId
        case comparisonId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        feedbackMode = try container.decode(FeedbackMode.self, forKey: .feedbackMode)
        feedbackPrompt = try container.decodeIfPresent(String.self, forKey: .feedbackPrompt)
        priority = try container.decodeIfPresent(Int32.self, forKey: .priority) ?? 5
        triggerType = try container.decode(String.self, forKey: .triggerType)
        triggerReason = try container.decodeIfPresent(String.self, forKey: .triggerReason)
        contextType = try container.decodeIfPresent(ContextType.self, forKey: .contextType)
        contextMessageIds = try container.decodeIfPresent([String].self, forKey: .contextMessageIds) ?? []
        status = try container.decode(FeedbackRequestStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        comparisonId = try container.decodeIfPresent(String.self, forKey: .comparisonId)
    }
}

/// Query parameters for GET /v1/feedback/requests.
public struct FeedbackRequestsQuery: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var status: FeedbackRequestStatus

    public init(sessionId: String, status: FeedbackRequestStatus = .pending) {
        self.sessionId = sessionId
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        status = try container.decodeIfPresent(FeedbackRequestStatus.self, forKey: .status) ?? .pending
    }
}

// MARK: - TierConfig

/// Configuration for a single feedback tier.
public struct TierConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    public var sampleRate: Double
    public var minTurns: Int64
    public var minToolCalls: Int64
    public var minCompactions: Int64
    public var minErrors: Int64
    public var noCancellations: Bool
    public var requiresCancellation: Bool
    public var requiresRevert: Bool
    public var requiresRecovery: Bool
    public var feedbackMode: FeedbackMode
    public var dismissible: Bool
    public var prompt: String
    public var maxTriggers: Int32

    public init(
        enabled: Bool = true,
        sampleRate: Double = 0.0005,
        minTurns: Int64 = 10,
        minToolCalls: Int64 = 5,
        minCompactions: Int64 = 2,
        minErrors: Int64 = 0,
        noCancellations: Bool = false,
        requiresCancellation: Bool = false,
        requiresRevert: Bool = false,
        requiresRecovery: Bool = false,
        feedbackMode: FeedbackMode = .thumbs,
        dismissible: Bool = true,
        prompt: String = "",
        maxTriggers: Int32 = 1
    ) {
        self.enabled = enabled
        self.sampleRate = sampleRate
        self.minTurns = minTurns
        self.minToolCalls = minToolCalls
        self.minCompactions = minCompactions
        self.minErrors = minErrors
        self.noCancellations = noCancellations
        self.requiresCancellation = requiresCancellation
        self.requiresRevert = requiresRevert
        self.requiresRecovery = requiresRecovery
        self.feedbackMode = feedbackMode
        self.dismissible = dismissible
        self.prompt = prompt
        self.maxTriggers = maxTriggers
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case sampleRate
        case minTurns
        case minToolCalls
        case minCompactions
        case minErrors
        case noCancellations
        case requiresCancellation
        case requiresRevert
        case requiresRecovery
        case feedbackMode
        case dismissible
        case prompt
        case maxTriggers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0.0005
        minTurns = try container.decodeIfPresent(Int64.self, forKey: .minTurns) ?? 10
        minToolCalls = try container.decodeIfPresent(Int64.self, forKey: .minToolCalls) ?? 5
        minCompactions = try container.decodeIfPresent(Int64.self, forKey: .minCompactions) ?? 2
        minErrors = try container.decodeIfPresent(Int64.self, forKey: .minErrors) ?? 0
        noCancellations = try container.decodeIfPresent(Bool.self, forKey: .noCancellations) ?? false
        requiresCancellation = try container.decodeIfPresent(Bool.self, forKey: .requiresCancellation) ?? false
        requiresRevert = try container.decodeIfPresent(Bool.self, forKey: .requiresRevert) ?? false
        requiresRecovery = try container.decodeIfPresent(Bool.self, forKey: .requiresRecovery) ?? false
        feedbackMode = try container.decodeIfPresent(FeedbackMode.self, forKey: .feedbackMode) ?? .thumbs
        dismissible = try container.decodeIfPresent(Bool.self, forKey: .dismissible) ?? true
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        maxTriggers = try container.decodeIfPresent(Int32.self, forKey: .maxTriggers) ?? 1
    }
}

// MARK: - FeedbackHeuristicsConfig

/// Configuration for feedback heuristics loaded from remote config.
public struct FeedbackHeuristicsConfig: Hashable, Sendable, Codable, Equatable {
    public var configId: String
    public var configVersion: Int64
    public var enabled: Bool
    public var cooldownSeconds: Int64
    public var maxRequestsPerSession: Int64
    // Tier 1
    public var tier1Enabled: Bool
    public var tier1SampleRate: Double
    public var tier1MinTurns: Int64
    public var tier1MinToolCalls: Int64
    public var tier1MinCompactions: Int64
    public var tier1NoCancellations: Bool
    public var tier1FeedbackMode: String
    public var tier1Dismissible: Bool
    public var tier1Prompt: String
    public var tier1MaxTriggers: Int32
    // Tier 2
    public var tier2Enabled: Bool
    public var tier2SampleRate: Double
    public var tier2MinTurns: Int64
    public var tier2MinToolCalls: Int64
    public var tier2MinCompactions: Int64
    public var tier2MinErrors: Int64
    public var tier2FeedbackMode: String
    public var tier2Dismissible: Bool
    public var tier2Prompt: String
    public var tier2MaxTriggers: Int32
    // Tier 3
    public var tier3Enabled: Bool
    public var tier3SampleRate: Double
    public var tier3MinTurns: Int64
    public var tier3RequiresCancellation: Bool
    public var tier3RequiresRevert: Bool
    public var tier3RequiresRecovery: Bool
    public var tier3FeedbackMode: String
    public var tier3Dismissible: Bool
    public var tier3Prompt: String
    public var tier3MaxTriggers: Int32
    // Metadata
    public var createdAt: Date?
    public var updatedAt: Date?
    public var createdBy: String?
    public var description: String?
    // Lifecycle
    public var effectiveFrom: Date?
    public var effectiveUntil: Date?
    public var isActive: Bool
    public var targetUserCohorts: [String]
    public var priority: Int32

    public init() {
        self.configId = "default"
        self.configVersion = 1
        self.enabled = true
        self.cooldownSeconds = 300
        self.maxRequestsPerSession = 3
        // Tier 1
        self.tier1Enabled = true
        self.tier1SampleRate = 0.0005
        self.tier1MinTurns = 10
        self.tier1MinToolCalls = 5
        self.tier1MinCompactions = 2
        self.tier1NoCancellations = true
        self.tier1FeedbackMode = "thumbs"
        self.tier1Dismissible = true
        self.tier1Prompt = "You've been using Grok Code productively! Would you mind sharing quick feedback?"
        self.tier1MaxTriggers = 1
        // Tier 2
        self.tier2Enabled = true
        self.tier2SampleRate = 0.0002
        self.tier2MinTurns = 15
        self.tier2MinToolCalls = 10
        self.tier2MinCompactions = 3
        self.tier2MinErrors = 1
        self.tier2FeedbackMode = "thumbs_text"
        self.tier2Dismissible = true
        self.tier2Prompt = "You've worked through a complex session. Your feedback would help us improve."
        self.tier2MaxTriggers = 1
        // Tier 3
        self.tier3Enabled = true
        self.tier3SampleRate = 0.0001
        self.tier3MinTurns = 20
        self.tier3RequiresCancellation = false
        self.tier3RequiresRevert = false
        self.tier3RequiresRecovery = true
        self.tier3FeedbackMode = "stars_text"
        self.tier3Dismissible = true
        self.tier3Prompt = "Thanks for sticking with us through that session. Got a moment to share feedback?"
        self.tier3MaxTriggers = 1
        // Lifecycle
        self.isActive = true
        self.targetUserCohorts = ["all"]
        self.priority = 0
    }

    /// Get the Tier 1 configuration as a `TierConfig`.
    public func tier1Config() -> TierConfig {
        TierConfig(
            enabled: tier1Enabled,
            sampleRate: tier1SampleRate,
            minTurns: tier1MinTurns,
            minToolCalls: tier1MinToolCalls,
            minCompactions: tier1MinCompactions,
            minErrors: 0,
            noCancellations: tier1NoCancellations,
            requiresCancellation: false,
            requiresRevert: false,
            requiresRecovery: false,
            feedbackMode: parseFeedbackModeStr(tier1FeedbackMode),
            dismissible: tier1Dismissible,
            prompt: tier1Prompt,
            maxTriggers: tier1MaxTriggers
        )
    }

    /// Get the Tier 2 configuration as a `TierConfig`.
    public func tier2Config() -> TierConfig {
        TierConfig(
            enabled: tier2Enabled,
            sampleRate: tier2SampleRate,
            minTurns: tier2MinTurns,
            minToolCalls: tier2MinToolCalls,
            minCompactions: tier2MinCompactions,
            minErrors: tier2MinErrors,
            noCancellations: false,
            requiresCancellation: false,
            requiresRevert: false,
            requiresRecovery: false,
            feedbackMode: parseFeedbackModeStr(tier2FeedbackMode),
            dismissible: tier2Dismissible,
            prompt: tier2Prompt,
            maxTriggers: tier2MaxTriggers
        )
    }

    /// Get the Tier 3 configuration as a `TierConfig`.
    public func tier3Config() -> TierConfig {
        TierConfig(
            enabled: tier3Enabled,
            sampleRate: tier3SampleRate,
            minTurns: tier3MinTurns,
            minToolCalls: 0,
            minCompactions: 0,
            minErrors: 0,
            noCancellations: false,
            requiresCancellation: tier3RequiresCancellation,
            requiresRevert: tier3RequiresRevert,
            requiresRecovery: tier3RequiresRecovery,
            feedbackMode: parseFeedbackModeStr(tier3FeedbackMode),
            dismissible: tier3Dismissible,
            prompt: tier3Prompt,
            maxTriggers: tier3MaxTriggers
        )
    }

    enum CodingKeys: String, CodingKey {
        case configId
        case configVersion
        case enabled
        case cooldownSeconds
        case maxRequestsPerSession
        case tier1Enabled
        case tier1SampleRate
        case tier1MinTurns
        case tier1MinToolCalls
        case tier1MinCompactions
        case tier1NoCancellations
        case tier1FeedbackMode
        case tier1Dismissible
        case tier1Prompt
        case tier1MaxTriggers
        case tier2Enabled
        case tier2SampleRate
        case tier2MinTurns
        case tier2MinToolCalls
        case tier2MinCompactions
        case tier2MinErrors
        case tier2FeedbackMode
        case tier2Dismissible
        case tier2Prompt
        case tier2MaxTriggers
        case tier3Enabled
        case tier3SampleRate
        case tier3MinTurns
        case tier3RequiresCancellation
        case tier3RequiresRevert
        case tier3RequiresRecovery
        case tier3FeedbackMode
        case tier3Dismissible
        case tier3Prompt
        case tier3MaxTriggers
        case createdAt
        case updatedAt
        case createdBy
        case description
        case effectiveFrom
        case effectiveUntil
        case isActive
        case targetUserCohorts
        case priority
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configId = try c.decodeIfPresent(String.self, forKey: .configId) ?? "default"
        configVersion = try c.decodeIfPresent(Int64.self, forKey: .configVersion) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cooldownSeconds = try c.decodeIfPresent(Int64.self, forKey: .cooldownSeconds) ?? 300
        maxRequestsPerSession = try c.decodeIfPresent(Int64.self, forKey: .maxRequestsPerSession) ?? 3
        tier1Enabled = try c.decodeIfPresent(Bool.self, forKey: .tier1Enabled) ?? true
        tier1SampleRate = try c.decodeIfPresent(Double.self, forKey: .tier1SampleRate) ?? 0.0005
        tier1MinTurns = try c.decodeIfPresent(Int64.self, forKey: .tier1MinTurns) ?? 10
        tier1MinToolCalls = try c.decodeIfPresent(Int64.self, forKey: .tier1MinToolCalls) ?? 5
        tier1MinCompactions = try c.decodeIfPresent(Int64.self, forKey: .tier1MinCompactions) ?? 2
        tier1NoCancellations = try c.decodeIfPresent(Bool.self, forKey: .tier1NoCancellations) ?? true
        tier1FeedbackMode = try c.decodeIfPresent(String.self, forKey: .tier1FeedbackMode) ?? "thumbs"
        tier1Dismissible = try c.decodeIfPresent(Bool.self, forKey: .tier1Dismissible) ?? true
        tier1Prompt = try c.decodeIfPresent(String.self, forKey: .tier1Prompt) ?? ""
        tier1MaxTriggers = try c.decodeIfPresent(Int32.self, forKey: .tier1MaxTriggers) ?? 1
        tier2Enabled = try c.decodeIfPresent(Bool.self, forKey: .tier2Enabled) ?? true
        tier2SampleRate = try c.decodeIfPresent(Double.self, forKey: .tier2SampleRate) ?? 0.0002
        tier2MinTurns = try c.decodeIfPresent(Int64.self, forKey: .tier2MinTurns) ?? 15
        tier2MinToolCalls = try c.decodeIfPresent(Int64.self, forKey: .tier2MinToolCalls) ?? 10
        tier2MinCompactions = try c.decodeIfPresent(Int64.self, forKey: .tier2MinCompactions) ?? 3
        tier2MinErrors = try c.decodeIfPresent(Int64.self, forKey: .tier2MinErrors) ?? 1
        tier2FeedbackMode = try c.decodeIfPresent(String.self, forKey: .tier2FeedbackMode) ?? "thumbs_text"
        tier2Dismissible = try c.decodeIfPresent(Bool.self, forKey: .tier2Dismissible) ?? true
        tier2Prompt = try c.decodeIfPresent(String.self, forKey: .tier2Prompt) ?? ""
        tier2MaxTriggers = try c.decodeIfPresent(Int32.self, forKey: .tier2MaxTriggers) ?? 1
        tier3Enabled = try c.decodeIfPresent(Bool.self, forKey: .tier3Enabled) ?? true
        tier3SampleRate = try c.decodeIfPresent(Double.self, forKey: .tier3SampleRate) ?? 0.0001
        tier3MinTurns = try c.decodeIfPresent(Int64.self, forKey: .tier3MinTurns) ?? 20
        tier3RequiresCancellation = try c.decodeIfPresent(Bool.self, forKey: .tier3RequiresCancellation) ?? false
        tier3RequiresRevert = try c.decodeIfPresent(Bool.self, forKey: .tier3RequiresRevert) ?? false
        tier3RequiresRecovery = try c.decodeIfPresent(Bool.self, forKey: .tier3RequiresRecovery) ?? true
        tier3FeedbackMode = try c.decodeIfPresent(String.self, forKey: .tier3FeedbackMode) ?? "stars_text"
        tier3Dismissible = try c.decodeIfPresent(Bool.self, forKey: .tier3Dismissible) ?? true
        tier3Prompt = try c.decodeIfPresent(String.self, forKey: .tier3Prompt) ?? ""
        tier3MaxTriggers = try c.decodeIfPresent(Int32.self, forKey: .tier3MaxTriggers) ?? 1
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        effectiveFrom = try c.decodeIfPresent(Date.self, forKey: .effectiveFrom)
        effectiveUntil = try c.decodeIfPresent(Date.self, forKey: .effectiveUntil)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        targetUserCohorts = try c.decodeIfPresent([String].self, forKey: .targetUserCohorts) ?? ["all"]
        priority = try c.decodeIfPresent(Int32.self, forKey: .priority) ?? 0
    }
}

/// Parse a feedback mode string to `FeedbackMode`.
public func parseFeedbackModeStr(_ s: String) -> FeedbackMode {
    switch s {
    case "thumbs": return .thumbs
    case "stars": return .stars
    case "text": return .text
    case "thumbs_text": return .thumbsText
    case "stars_text": return .starsText
    case "comparison": return .comparison
    case "survey": return .survey
    case "nps": return .nps
    case "nps_text": return .npsText
    default: return .thumbs
    }
}

// MARK: - SessionTurnDelta

/// Per-turn delta sent at the end of every turn.
/// POST /v1/sessions/{session_id}/turn-deltas
public struct SessionTurnDelta: Hashable, Sendable, Codable, Equatable {
    public var clientType: ClientType
    public var turnNumber: Int64
    // Delta counters
    public var deltaToolCalls: Int64
    public var deltaToolFailures: Int64
    public var deltaErrors: Int64
    public var deltaCancellations: Int64
    public var deltaRegenerations: Int64
    public var deltaCompactions: Int64
    public var deltaEditAndRetries: Int64
    public var deltaPositiveRatings: Int64
    public var deltaNegativeRatings: Int64
    public var deltaAssistantMessages: Int64
    public var deltaLongPauses: Int64
    public var deltaSuccessfulToolUses: Int64
    // Turn-level snapshot values
    public var consecutiveCancellations: Int64
    // Turn-level absolute values
    public var timeToFirstTokenMs: Int64?
    public var totalResponseTimeMs: Int64?
    public var itlP50Ms: Int64?
    public var itlP99Ms: Int64?
    public var itlMaxMs: Int64?
    public var itlMeanMs: Int64?
    public var contextWindowUsage: Int64
    public var modelId: String?
    public var turnDurationMs: Int64?
    public var turnOutcome: String?
    public var modelFingerprint: String?
    public var toolsUsedThisTurn: [String]
    public var errorTypesThisTurn: [String]
    public var toolOutcomes: String
    // Cumulative totals
    public var cumulativeToolCalls: Int64
    public var cumulativeErrors: Int64
    public var sessionDurationSeconds: Int64
    public var totalTokensBeforeCompaction: Int64
    public var metadata: JSONValue?
    public var requestId: String?
    public var sessionStartAt: Date?
    public var feedbackRequestsSent: Int64
    public var lastFeedbackRequestAt: Date?
    public var responseTokens: Int64?
    public var thinkingTokens: Int64?
    // LOC attribution deltas
    public var deltaAgentLinesAdded: Int64
    public var deltaAgentLinesRemoved: Int64
    public var deltaAgentLinesAddedReverted: Int64
    public var deltaAgentLinesRemovedReverted: Int64
    public var deltaHumanLinesAdded: Int64
    public var deltaHumanLinesRemoved: Int64
    public var deltaHumanLinesAddedReverted: Int64
    public var deltaHumanLinesRemovedReverted: Int64
    public var deltaAgentFilesTouched: Int64
    public var deltaHumanFilesTouched: Int64
    public var deltaTotalFilesTouched: Int64
    public var locTrackingEnabled: Bool

    public init(
        clientType: ClientType,
        turnNumber: Int64,
        contextWindowUsage: Int64 = 0,
        consecutiveCancellations: Int64 = 0,
        cumulativeToolCalls: Int64 = 0,
        cumulativeErrors: Int64 = 0,
        sessionDurationSeconds: Int64 = 0,
        totalTokensBeforeCompaction: Int64 = 0,
        feedbackRequestsSent: Int64 = 0
    ) {
        self.clientType = clientType
        self.turnNumber = turnNumber
        self.contextWindowUsage = contextWindowUsage
        self.consecutiveCancellations = consecutiveCancellations
        self.cumulativeToolCalls = cumulativeToolCalls
        self.cumulativeErrors = cumulativeErrors
        self.sessionDurationSeconds = sessionDurationSeconds
        self.totalTokensBeforeCompaction = totalTokensBeforeCompaction
        self.feedbackRequestsSent = feedbackRequestsSent
        // Delta counters default to 0
        self.deltaToolCalls = 0
        self.deltaToolFailures = 0
        self.deltaErrors = 0
        self.deltaCancellations = 0
        self.deltaRegenerations = 0
        self.deltaCompactions = 0
        self.deltaEditAndRetries = 0
        self.deltaPositiveRatings = 0
        self.deltaNegativeRatings = 0
        self.deltaAssistantMessages = 0
        self.deltaLongPauses = 0
        self.deltaSuccessfulToolUses = 0
        // LOC defaults
        self.deltaAgentLinesAdded = 0
        self.deltaAgentLinesRemoved = 0
        self.deltaAgentLinesAddedReverted = 0
        self.deltaAgentLinesRemovedReverted = 0
        self.deltaHumanLinesAdded = 0
        self.deltaHumanLinesRemoved = 0
        self.deltaHumanLinesAddedReverted = 0
        self.deltaHumanLinesRemovedReverted = 0
        self.deltaAgentFilesTouched = 0
        self.deltaHumanFilesTouched = 0
        self.deltaTotalFilesTouched = 0
        self.locTrackingEnabled = false
        // Collections
        self.toolsUsedThisTurn = []
        self.errorTypesThisTurn = []
        self.toolOutcomes = ""
    }

    enum CodingKeys: String, CodingKey {
        case clientType
        case turnNumber
        case deltaToolCalls
        case deltaToolFailures
        case deltaErrors
        case deltaCancellations
        case deltaRegenerations
        case deltaCompactions
        case deltaEditAndRetries
        case deltaPositiveRatings
        case deltaNegativeRatings
        case deltaAssistantMessages
        case deltaLongPauses
        case deltaSuccessfulToolUses
        case consecutiveCancellations
        case timeToFirstTokenMs
        case totalResponseTimeMs
        case itlP50Ms
        case itlP99Ms
        case itlMaxMs
        case itlMeanMs
        case contextWindowUsage
        case modelId
        case turnDurationMs
        case turnOutcome
        case modelFingerprint
        case toolsUsedThisTurn
        case errorTypesThisTurn
        case toolOutcomes
        case cumulativeToolCalls
        case cumulativeErrors
        case sessionDurationSeconds
        case totalTokensBeforeCompaction
        case metadata
        case requestId
        case sessionStartAt
        case feedbackRequestsSent
        case lastFeedbackRequestAt
        case responseTokens
        case thinkingTokens
        case deltaAgentLinesAdded
        case deltaAgentLinesRemoved
        case deltaAgentLinesAddedReverted
        case deltaAgentLinesRemovedReverted
        case deltaHumanLinesAdded
        case deltaHumanLinesRemoved
        case deltaHumanLinesAddedReverted
        case deltaHumanLinesRemovedReverted
        case deltaAgentFilesTouched
        case deltaHumanFilesTouched
        case deltaTotalFilesTouched
        case locTrackingEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Required (no #[serde(default)] in Rust): these throw on missing,
        // matching the Rust contract documented in session_turn_delta_latency_backward_compat:
        // "Required (non-Option) counters must be present because they have no serde default."
        clientType = try c.decode(ClientType.self, forKey: .clientType)
        turnNumber = try c.decode(Int64.self, forKey: .turnNumber)
        deltaToolCalls = try c.decode(Int64.self, forKey: .deltaToolCalls)
        deltaToolFailures = try c.decode(Int64.self, forKey: .deltaToolFailures)
        deltaErrors = try c.decode(Int64.self, forKey: .deltaErrors)
        deltaCancellations = try c.decode(Int64.self, forKey: .deltaCancellations)
        deltaRegenerations = try c.decode(Int64.self, forKey: .deltaRegenerations)
        deltaCompactions = try c.decode(Int64.self, forKey: .deltaCompactions)
        deltaEditAndRetries = try c.decode(Int64.self, forKey: .deltaEditAndRetries)
        deltaPositiveRatings = try c.decode(Int64.self, forKey: .deltaPositiveRatings)
        deltaNegativeRatings = try c.decode(Int64.self, forKey: .deltaNegativeRatings)
        deltaAssistantMessages = try c.decode(Int64.self, forKey: .deltaAssistantMessages)
        deltaLongPauses = try c.decode(Int64.self, forKey: .deltaLongPauses)
        deltaSuccessfulToolUses = try c.decode(Int64.self, forKey: .deltaSuccessfulToolUses)
        consecutiveCancellations = try c.decode(Int64.self, forKey: .consecutiveCancellations)
        // Optional (skip_serializing_if = "Option::is_none")
        timeToFirstTokenMs = try c.decodeIfPresent(Int64.self, forKey: .timeToFirstTokenMs)
        totalResponseTimeMs = try c.decodeIfPresent(Int64.self, forKey: .totalResponseTimeMs)
        itlP50Ms = try c.decodeIfPresent(Int64.self, forKey: .itlP50Ms)
        itlP99Ms = try c.decodeIfPresent(Int64.self, forKey: .itlP99Ms)
        itlMaxMs = try c.decodeIfPresent(Int64.self, forKey: .itlMaxMs)
        itlMeanMs = try c.decodeIfPresent(Int64.self, forKey: .itlMeanMs)
        // Required
        contextWindowUsage = try c.decode(Int64.self, forKey: .contextWindowUsage)
        // Optional
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        turnDurationMs = try c.decodeIfPresent(Int64.self, forKey: .turnDurationMs)
        turnOutcome = try c.decodeIfPresent(String.self, forKey: .turnOutcome)
        modelFingerprint = try c.decodeIfPresent(String.self, forKey: .modelFingerprint)
        // Default + skip_serializing_if = "Vec::is_empty"
        toolsUsedThisTurn = try c.decodeIfPresent([String].self, forKey: .toolsUsedThisTurn) ?? []
        errorTypesThisTurn = try c.decodeIfPresent([String].self, forKey: .errorTypesThisTurn) ?? []
        // Default + skip_serializing_if = "String::is_empty"
        toolOutcomes = try c.decodeIfPresent(String.self, forKey: .toolOutcomes) ?? ""
        // Required
        cumulativeToolCalls = try c.decode(Int64.self, forKey: .cumulativeToolCalls)
        cumulativeErrors = try c.decode(Int64.self, forKey: .cumulativeErrors)
        sessionDurationSeconds = try c.decode(Int64.self, forKey: .sessionDurationSeconds)
        // Default (#[serde(default)])
        totalTokensBeforeCompaction = try c.decodeIfPresent(Int64.self, forKey: .totalTokensBeforeCompaction) ?? 0
        // Optional
        metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        sessionStartAt = try c.decodeIfPresent(Date.self, forKey: .sessionStartAt)
        // Default (#[serde(default)])
        feedbackRequestsSent = try c.decodeIfPresent(Int64.self, forKey: .feedbackRequestsSent) ?? 0
        // Optional
        lastFeedbackRequestAt = try c.decodeIfPresent(Date.self, forKey: .lastFeedbackRequestAt)
        responseTokens = try c.decodeIfPresent(Int64.self, forKey: .responseTokens)
        thinkingTokens = try c.decodeIfPresent(Int64.self, forKey: .thinkingTokens)
        // Default LOC deltas (#[serde(default)])
        deltaAgentLinesAdded = try c.decodeIfPresent(Int64.self, forKey: .deltaAgentLinesAdded) ?? 0
        deltaAgentLinesRemoved = try c.decodeIfPresent(Int64.self, forKey: .deltaAgentLinesRemoved) ?? 0
        deltaAgentLinesAddedReverted = try c.decodeIfPresent(Int64.self, forKey: .deltaAgentLinesAddedReverted) ?? 0
        deltaAgentLinesRemovedReverted = try c.decodeIfPresent(Int64.self, forKey: .deltaAgentLinesRemovedReverted) ?? 0
        deltaHumanLinesAdded = try c.decodeIfPresent(Int64.self, forKey: .deltaHumanLinesAdded) ?? 0
        deltaHumanLinesRemoved = try c.decodeIfPresent(Int64.self, forKey: .deltaHumanLinesRemoved) ?? 0
        deltaHumanLinesAddedReverted = try c.decodeIfPresent(Int64.self, forKey: .deltaHumanLinesAddedReverted) ?? 0
        deltaHumanLinesRemovedReverted = try c.decodeIfPresent(Int64.self, forKey: .deltaHumanLinesRemovedReverted) ?? 0
        deltaAgentFilesTouched = try c.decodeIfPresent(Int64.self, forKey: .deltaAgentFilesTouched) ?? 0
        deltaHumanFilesTouched = try c.decodeIfPresent(Int64.self, forKey: .deltaHumanFilesTouched) ?? 0
        deltaTotalFilesTouched = try c.decodeIfPresent(Int64.self, forKey: .deltaTotalFilesTouched) ?? 0
        // Default (#[serde(default)]); always serialized (no skip_serializing_if).
        locTrackingEnabled = try c.decodeIfPresent(Bool.self, forKey: .locTrackingEnabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientType, forKey: .clientType)
        try c.encode(turnNumber, forKey: .turnNumber)
        try c.encode(deltaToolCalls, forKey: .deltaToolCalls)
        try c.encode(deltaToolFailures, forKey: .deltaToolFailures)
        try c.encode(deltaErrors, forKey: .deltaErrors)
        try c.encode(deltaCancellations, forKey: .deltaCancellations)
        try c.encode(deltaRegenerations, forKey: .deltaRegenerations)
        try c.encode(deltaCompactions, forKey: .deltaCompactions)
        try c.encode(deltaEditAndRetries, forKey: .deltaEditAndRetries)
        try c.encode(deltaPositiveRatings, forKey: .deltaPositiveRatings)
        try c.encode(deltaNegativeRatings, forKey: .deltaNegativeRatings)
        try c.encode(deltaAssistantMessages, forKey: .deltaAssistantMessages)
        try c.encode(deltaLongPauses, forKey: .deltaLongPauses)
        try c.encode(deltaSuccessfulToolUses, forKey: .deltaSuccessfulToolUses)
        try c.encode(consecutiveCancellations, forKey: .consecutiveCancellations)
        try c.encodeIfPresent(timeToFirstTokenMs, forKey: .timeToFirstTokenMs)
        try c.encodeIfPresent(totalResponseTimeMs, forKey: .totalResponseTimeMs)
        try c.encodeIfPresent(itlP50Ms, forKey: .itlP50Ms)
        try c.encodeIfPresent(itlP99Ms, forKey: .itlP99Ms)
        try c.encodeIfPresent(itlMaxMs, forKey: .itlMaxMs)
        try c.encodeIfPresent(itlMeanMs, forKey: .itlMeanMs)
        try c.encode(contextWindowUsage, forKey: .contextWindowUsage)
        try c.encodeIfPresent(modelId, forKey: .modelId)
        try c.encodeIfPresent(turnDurationMs, forKey: .turnDurationMs)
        try c.encodeIfPresent(turnOutcome, forKey: .turnOutcome)
        try c.encodeIfPresent(modelFingerprint, forKey: .modelFingerprint)
        if !toolsUsedThisTurn.isEmpty { try c.encode(toolsUsedThisTurn, forKey: .toolsUsedThisTurn) }
        if !errorTypesThisTurn.isEmpty { try c.encode(errorTypesThisTurn, forKey: .errorTypesThisTurn) }
        if !toolOutcomes.isEmpty { try c.encode(toolOutcomes, forKey: .toolOutcomes) }
        try c.encode(cumulativeToolCalls, forKey: .cumulativeToolCalls)
        try c.encode(cumulativeErrors, forKey: .cumulativeErrors)
        try c.encode(sessionDurationSeconds, forKey: .sessionDurationSeconds)
        try c.encode(totalTokensBeforeCompaction, forKey: .totalTokensBeforeCompaction)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(requestId, forKey: .requestId)
        try c.encodeIfPresent(sessionStartAt, forKey: .sessionStartAt)
        try c.encode(feedbackRequestsSent, forKey: .feedbackRequestsSent)
        try c.encodeIfPresent(lastFeedbackRequestAt, forKey: .lastFeedbackRequestAt)
        try c.encodeIfPresent(responseTokens, forKey: .responseTokens)
        try c.encodeIfPresent(thinkingTokens, forKey: .thinkingTokens)
        try c.encode(deltaAgentLinesAdded, forKey: .deltaAgentLinesAdded)
        try c.encode(deltaAgentLinesRemoved, forKey: .deltaAgentLinesRemoved)
        try c.encode(deltaAgentLinesAddedReverted, forKey: .deltaAgentLinesAddedReverted)
        try c.encode(deltaAgentLinesRemovedReverted, forKey: .deltaAgentLinesRemovedReverted)
        try c.encode(deltaHumanLinesAdded, forKey: .deltaHumanLinesAdded)
        try c.encode(deltaHumanLinesRemoved, forKey: .deltaHumanLinesRemoved)
        try c.encode(deltaHumanLinesAddedReverted, forKey: .deltaHumanLinesAddedReverted)
        try c.encode(deltaHumanLinesRemovedReverted, forKey: .deltaHumanLinesRemovedReverted)
        try c.encode(deltaAgentFilesTouched, forKey: .deltaAgentFilesTouched)
        try c.encode(deltaHumanFilesTouched, forKey: .deltaHumanFilesTouched)
        try c.encode(deltaTotalFilesTouched, forKey: .deltaTotalFilesTouched)
        try c.encode(locTrackingEnabled, forKey: .locTrackingEnabled)
    }
}

/// Response for POST /v1/sessions/{session_id}/turn-deltas.
public struct SessionTurnDeltaResponse: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var turnNumber: Int64
    public var recordedAt: Date

    public init(sessionId: String, turnNumber: Int64, recordedAt: Date) {
        self.sessionId = sessionId
        self.turnNumber = turnNumber
        self.recordedAt = recordedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case turnNumber
        case recordedAt
    }
}
