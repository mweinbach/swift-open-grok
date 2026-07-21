// ChatStateTypes.swift
//
// Open Grok — Swift port of the shared domain types for the chat state actor
// in `crates/codegen/xai-chat-state/src/types.rs`.
//
// These are the value types the `ChatStateActor` (see `ChatStateActor.swift`)
// owns and exchanges with its handle. The snapshot is `Codable` so it can be
// persisted and restored for forking/rewind.

import Foundation
import OpenGrokSamplingTypes

/// Canonical marker for an injected memory-context block. Shared by the
/// emitter in the shell and the upsert/detection here — a drift would
/// silently break dedup and let blocks accumulate in the prompt prefix.
public let MEMORY_CONTEXT_OPEN_TAG = "<memory-context>"
public let MEMORY_CONTEXT_CLOSE_TAG = "</memory-context>"

/// Configuration for the `ChatStateActor` at spawn time.
public struct ChatStateConfig: Sendable, Equatable {
    /// Initial conversation items to populate the state with.
    public var initialConversation: [ConversationItem]
    /// Sampling configuration (model, context window, etc.).
    public var samplingConfig: SamplingConfig

    public init(initialConversation: [ConversationItem], samplingConfig: SamplingConfig) {
        self.initialConversation = initialConversation
        self.samplingConfig = samplingConfig
    }
}

/// Immutable snapshot of the actor's state (for forking, rewind).
public struct ChatStateSnapshot: Codable, Sendable, Equatable {
    /// The full conversation history.
    public var conversation: [ConversationItem]
    /// Current sampling configuration.
    public var samplingConfig: SamplingConfig
    /// Current prompt index (incremented per user turn).
    public var promptIndex: Int
    /// Accumulated token usage.
    public var totalTokens: UInt64
    /// Bytes/4 estimate of the conversation as of the last
    /// `recordTokenUsage`. `0` means unknown (pre-field snapshot); restore
    /// re-estimates instead.
    public var estimateAtLastResponse: UInt64
    /// File paths the agent has edited.
    public var agentEditedPaths: [String]
    /// Cached prompt texts for rewind preview.
    public var promptTexts: [String]
    /// Timestamp when the current stream started (epoch ms).
    public var streamStartMs: Int64?
    /// Timestamp when the current turn started (epoch ms).
    public var turnStartMs: Int64?
    /// Prompt index at which the last compaction occurred.
    public var lastCompactionPromptIndex: Int?
    /// Opaque credential secrets (API key, optional extra auth, client version).
    public var credentials: Credentials

    public init(
        conversation: [ConversationItem] = [],
        samplingConfig: SamplingConfig,
        promptIndex: Int = 0,
        totalTokens: UInt64 = 0,
        estimateAtLastResponse: UInt64 = 0,
        agentEditedPaths: [String] = [],
        promptTexts: [String] = [],
        streamStartMs: Int64? = nil,
        turnStartMs: Int64? = nil,
        lastCompactionPromptIndex: Int? = nil,
        credentials: Credentials = Credentials()
    ) {
        self.conversation = conversation
        self.samplingConfig = samplingConfig
        self.promptIndex = promptIndex
        self.totalTokens = totalTokens
        self.estimateAtLastResponse = estimateAtLastResponse
        self.agentEditedPaths = agentEditedPaths
        self.promptTexts = promptTexts
        self.streamStartMs = streamStartMs
        self.turnStartMs = turnStartMs
        self.lastCompactionPromptIndex = lastCompactionPromptIndex
        self.credentials = credentials
    }

    public enum CodingKeys: String, CodingKey {
        case conversation
        case samplingConfig = "sampling_config"
        case promptIndex = "prompt_index"
        case totalTokens = "total_tokens"
        case estimateAtLastResponse = "estimate_at_last_response"
        case agentEditedPaths = "agent_edited_paths"
        case promptTexts = "prompt_texts"
        case streamStartMs = "stream_start_ms"
        case turnStartMs = "turn_start_ms"
        case lastCompactionPromptIndex = "last_compaction_prompt_index"
        case credentials
    }
}

/// Metadata for session notifications (timing info).
public struct NotificationMeta: Sendable, Equatable {
    public var streamStartMs: Int64?
    public var turnStartMs: Int64?

    public init(streamStartMs: Int64?, turnStartMs: Int64?) {
        self.streamStartMs = streamStartMs
        self.turnStartMs = turnStartMs
    }
}

/// Configuration for tool-result pruning.
///
/// Prunes old, large tool results from the conversation to reclaim context
/// space. Two modes: soft trim (keep head + tail) and hard clear (replace
/// entirely).
public struct PruningConfig: Sendable, Equatable {
    /// Whether pruning is enabled.
    public var enabled: Bool
    /// Number of recent turns whose tool results are never pruned.
    public var keepLastNTurns: Int
    /// Character threshold above which old tool results are soft-trimmed.
    public var softTrimThreshold: Int
    /// Characters to keep from the start of a soft-trimmed result.
    public var softTrimHead: Int
    /// Characters to keep from the end of a soft-trimmed result.
    public var softTrimTail: Int
    /// Turn age after which tool results are hard-cleared (replaced with
    /// placeholder).
    public var hardClearAgeTurns: Int

    public init(
        enabled: Bool = true,
        keepLastNTurns: Int = 3,
        softTrimThreshold: Int = 4000,
        softTrimHead: Int = 1500,
        softTrimTail: Int = 1500,
        hardClearAgeTurns: Int = 10
    ) {
        self.enabled = enabled
        self.keepLastNTurns = keepLastNTurns
        self.softTrimThreshold = softTrimThreshold
        self.softTrimHead = softTrimHead
        self.softTrimTail = softTrimTail
        self.hardClearAgeTurns = hardClearAgeTurns
    }
}

/// Where the session's current `apiKey` came from. Determines whether the
/// key can be refreshed.
public enum AuthType: String, Codable, Sendable, Equatable, Hashable, Defaultable {
    case sessionToken
    case apiKey

    public static let defaultValue: AuthType = .sessionToken

    public enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case apiKey = "api_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "session_token": self = .sessionToken
        case "api_key": self = .apiKey
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown AuthType: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .sessionToken: try container.encode("session_token")
        case .apiKey: try container.encode("api_key")
        }
    }
}

/// Credential/secret fields that the actor stores opaquely. The actor just
/// stores and returns them — it never interprets them.
public struct Credentials: Codable, Sendable, Equatable, Hashable {
    /// API key for authentication.
    public var apiKey: String?
    /// Whether this is a session token (refreshable) or user-provided api key.
    public var authType: AuthType
    /// Optional extra auth material forwarded with requests when present.
    public var alphaTestKey: String?
    /// Client version string.
    public var clientVersion: String?

    public init(
        apiKey: String? = nil,
        authType: AuthType = .defaultValue,
        alphaTestKey: String? = nil,
        clientVersion: String? = nil
    ) {
        self.apiKey = apiKey
        self.authType = authType
        self.alphaTestKey = alphaTestKey
        self.clientVersion = clientVersion
    }

    public enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case authType = "auth_type"
        case alphaTestKey = "alpha_test_key"
        case clientVersion = "client_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        self.authType = try c.decodeIfPresent(AuthType.self, forKey: .authType) ?? .defaultValue
        self.alphaTestKey = try c.decodeIfPresent(String.self, forKey: .alphaTestKey)
        self.clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
    }
}

/// The messages captured during a single conversation turn.
public struct TurnCapture: Sendable, Equatable {
    /// The ordered sequence of messages appended during this turn.
    public var messages: [ConversationItem]
    /// Whether compaction (conversation replacement) occurred mid-turn.
    public var compactionOccurred: Bool

    public init(messages: [ConversationItem], compactionOccurred: Bool) {
        self.messages = messages
        self.compactionOccurred = compactionOccurred
    }
}

/// Item counts for a conversation, broken down by role.
public struct ConversationCounts: Sendable, Equatable, Hashable {
    public var total: Int
    public var user: Int
    public var assistant: Int
    public var toolResult: Int

    public init(total: Int = 0, user: Int = 0, assistant: Int = 0, toolResult: Int = 0) {
        self.total = total
        self.user = user
        self.assistant = assistant
        self.toolResult = toolResult
    }
}

/// Info returned when auto-compact threshold is exceeded.
public struct AutoCompactTrigger: Sendable, Equatable, Hashable {
    /// Current total token count.
    public var totalTokens: UInt64
    /// Model's context window size.
    public var contextWindow: UInt64
    /// Current utilization as a percentage (0–100).
    public var utilizationPercent: UInt8

    public init(totalTokens: UInt64, contextWindow: UInt64, utilizationPercent: UInt8) {
        self.totalTokens = totalTokens
        self.contextWindow = contextWindow
        self.utilizationPercent = utilizationPercent
    }
}

/// Resolved model metadata carried on `ChatStateCommand.getLastModelMetadata`.
public struct ModelMetadata: Sendable, Equatable, Hashable {
    public var resolvedModelId: String?
    public var modelFingerprint: String?

    public init(resolvedModelId: String? = nil, modelFingerprint: String? = nil) {
        self.resolvedModelId = resolvedModelId
        self.modelFingerprint = modelFingerprint
    }
}
