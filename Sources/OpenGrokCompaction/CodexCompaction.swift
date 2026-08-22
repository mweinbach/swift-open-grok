import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

public enum CodexCompactionProtocol: String, Codable, Sendable, Equatable, Hashable {
    case remoteV2 = "remote_compaction_v2"
    case legacyUnary = "legacy_unary"

    public var endpointPath: String {
        switch self {
        case .remoteV2: return "/responses"
        case .legacyUnary: return "/responses/compact"
        }
    }

    public var betaHeaderValue: String? {
        switch self {
        case .remoteV2: return "remote_compaction_v2"
        case .legacyUnary: return nil
        }
    }
}

public struct CodexCompactionSelection: Codable, Sendable, Equatable, Hashable {
    public var remoteV2Enabled: Bool
    public var selectedProtocol: CodexCompactionProtocol

    public init(remoteV2Enabled: Bool) {
        self.remoteV2Enabled = remoteV2Enabled
        self.selectedProtocol = remoteV2Enabled ? .remoteV2 : .legacyUnary
    }

    private enum CodingKeys: String, CodingKey {
        case remoteV2Enabled = "remote_compaction_v2_enabled"
        case selectedProtocol = "selected_protocol"
    }
}

public struct CodexCompactionRequest: Codable, Sendable, Equatable, Hashable {
    public var protocolVersion: CodexCompactionProtocol
    public var instructions: String?
    public var input: [ConversationItem]
    public var compactionTrigger: Bool
    public var compactionHash: String?
    public var turnState: String?
    public var serviceTier: String?
    public var promptCacheKey: String?
    public var tools: [JSONValue]
    public var reasoning: JSONValue?

    public init(
        protocolVersion: CodexCompactionProtocol,
        instructions: String? = nil,
        input: [ConversationItem],
        compactionHash: String? = nil,
        turnState: String? = nil,
        serviceTier: String? = nil,
        promptCacheKey: String? = nil,
        tools: [JSONValue] = [],
        reasoning: JSONValue? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.instructions = instructions
        self.input = input
        self.compactionTrigger = protocolVersion == .remoteV2
        self.compactionHash = compactionHash
        self.turnState = turnState
        self.serviceTier = serviceTier
        self.promptCacheKey = promptCacheKey
        self.tools = tools
        self.reasoning = reasoning
    }

    public var endpointPath: String { protocolVersion.endpointPath }

    public var headers: [(name: String, value: String)] {
        guard let beta = protocolVersion.betaHeaderValue else { return [] }
        return [("x-codex-beta-features", beta)]
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case instructions, input
        case compactionTrigger = "compaction_trigger"
        case compactionHash = "comp_hash"
        case turnState = "turn_state"
        case serviceTier = "service_tier"
        case promptCacheKey = "prompt_cache_key"
        case tools, reasoning
    }
}

public struct CodexCompactionOutputItem: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var type: String
    public var raw: JSONValue
    public var encryptedContent: String?

    public init(
        id: String,
        type: String = "compaction",
        raw: JSONValue,
        encryptedContent: String? = nil
    ) {
        self.id = id
        self.type = type
        self.raw = raw
        self.encryptedContent = encryptedContent
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let object) = value,
              let type = object["type"]?.stringValue,
              !type.isEmpty
        else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Codex compaction output must contain a nonempty type"
            ))
        }

        // Compaction items from the provider have neither an `id` nor a
        // nested `raw` field. Their entire provider-native object is the
        // replay payload; manufacturing an ID inside it changes the next
        // request and invalidates the encrypted compaction contract.
        self.id = object["id"]?.stringValue ?? ""
        self.type = type
        self.raw = value
        self.encryptedContent = object["encrypted_content"]?.stringValue
    }

    public func encode(to encoder: Encoder) throws {
        // The typed ID is only a local sentinel. Preserve an ID-less provider
        // object exactly instead of leaking the sentinel back onto the wire.
        try raw.encode(to: encoder)
    }

    public var isDurableCompactionItem: Bool { type == "compaction" }

    public func asConversationItem() -> ConversationItem {
        .backendToolCall(.init(kind: .codexRawInput(CodexRawInputItem(
            id: id,
            raw: raw,
            crossProviderFallback: nil
        ))))
    }
}

public enum CodexCompactionStreamEvent: Codable, Sendable, Equatable, Hashable {
    case outputItemDone(CodexCompactionOutputItem)
    case responseCompleted
    case responseFailed(code: String?, message: String)
    case unrelated(type: String)

    private enum CodingKeys: String, CodingKey { case type, item, code, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "response.output_item.done":
            self = .outputItemDone(try container.decode(CodexCompactionOutputItem.self, forKey: .item))
        case "response.completed":
            self = .responseCompleted
        case "response.failed", "error":
            self = .responseFailed(
                code: try container.decodeIfPresent(String.self, forKey: .code),
                message: try container.decodeIfPresent(String.self, forKey: .message) ?? "Codex compaction failed"
            )
        default:
            self = .unrelated(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .outputItemDone(let item):
            try container.encode("response.output_item.done", forKey: .type)
            try container.encode(item, forKey: .item)
        case .responseCompleted:
            try container.encode("response.completed", forKey: .type)
        case .responseFailed(let code, let message):
            try container.encode("response.failed", forKey: .type)
            try container.encodeIfPresent(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case .unrelated(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

public enum CodexCompactionProtocolError: Error, Sendable, Equatable, Hashable {
    case failed(code: String?, message: String)
    case completedWithoutCompactionItem
    case multipleCompactionItems
    case eventAfterCompletion
    case incompleteResponse
}

public enum CodexCompactionRetryCause: Sendable, Equatable, Hashable {
    case authentication(status: Int)
    case transient
    case deterministic
    case partialResponse
    case cancelled
}

public struct CodexCompactionRetryPolicy: Codable, Sendable, Equatable, Hashable {
    public var maxAttempts: UInt32
    public var maxAuthRefreshes: UInt32

    public init(maxAttempts: UInt32 = 3, maxAuthRefreshes: UInt32 = 1) {
        self.maxAttempts = max(1, maxAttempts)
        self.maxAuthRefreshes = maxAuthRefreshes
    }

    public func canRetry(
        cause: CodexCompactionRetryCause,
        attemptsMade: UInt32,
        authRefreshesUsed: UInt32
    ) -> Bool {
        guard attemptsMade < maxAttempts else { return false }
        switch cause {
        case .authentication:
            return authRefreshesUsed < maxAuthRefreshes
        case .transient:
            return true
        case .deterministic, .partialResponse, .cancelled:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maxAttempts = "max_attempts"
        case maxAuthRefreshes = "max_auth_refreshes"
    }
}

public struct CodexRemoteCompactionResult: Sendable, Equatable, Hashable {
    public var item: CodexCompactionOutputItem
    public var attempts: UInt32
    public var refreshedAuth: Bool

    public init(item: CodexCompactionOutputItem, attempts: UInt32, refreshedAuth: Bool) {
        self.item = item
        self.attempts = attempts
        self.refreshedAuth = refreshedAuth
    }

    public func replacementHistory(
        promptInput: [ConversationItem],
        retainedUserTokenBudget: UInt64 = CODEX_REMOTE_COMPACTION_V2_RETAINED_USER_TOKENS
    ) -> [ConversationItem] {
        buildCodexRemoteCompactionV2History(
            promptInput: promptInput,
            compactionItem: item.asConversationItem(),
            retainedUserTokenBudget: retainedUserTokenBudget
        )
    }
}

public struct CodexCompactionV2Collector: Sendable, Equatable, Hashable {
    private var completed = false
    private var item: CodexCompactionOutputItem?
    private var failure: CodexCompactionProtocolError?

    public init() {}

    public mutating func consume(_ event: CodexCompactionStreamEvent) throws {
        if let failure { throw failure }
        switch event {
        case .outputItemDone(let output):
            guard !completed else {
                failure = .eventAfterCompletion
                throw CodexCompactionProtocolError.eventAfterCompletion
            }
            guard output.isDurableCompactionItem else { return }
            guard item == nil else {
                failure = .multipleCompactionItems
                throw CodexCompactionProtocolError.multipleCompactionItems
            }
            item = output
        case .responseCompleted:
            completed = true
        case .responseFailed(let code, let message):
            failure = .failed(code: code, message: message)
            throw CodexCompactionProtocolError.failed(code: code, message: message)
        case .unrelated:
            break
        }
    }

    public func finish(attempts: UInt32, refreshedAuth: Bool = false) throws -> CodexRemoteCompactionResult {
        if let failure { throw failure }
        guard completed else { throw CodexCompactionProtocolError.incompleteResponse }
        guard let item else { throw CodexCompactionProtocolError.completedWithoutCompactionItem }
        return CodexRemoteCompactionResult(item: item, attempts: attempts, refreshedAuth: refreshedAuth)
    }
}
