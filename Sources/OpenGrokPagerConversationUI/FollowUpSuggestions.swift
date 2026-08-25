import Foundation
import OpenGrokPagerRender

/// A transient, server-originated suggestion set for one authenticated session.
public struct FollowUpSuggestionPayload: Sendable, Equatable, Hashable {
    public static let maximumSuggestions = 6
    public static let maximumLabelScalars = 256
    public static let maximumIdentifierBytes = 128
    public static let maximumWireBytes = 64 * 1_024

    public let sessionID: String
    public let responseID: String
    public let promptID: String?
    public let labels: [String]

    public init?(
        sessionID: String,
        responseID: String,
        promptID: String? = nil,
        labels: [String],
        isReplayed: Bool = false
    ) {
        guard !isReplayed,
              !sessionID.isEmpty,
              sessionID.utf8.count <= Self.maximumIdentifierBytes,
              !responseID.isEmpty,
              responseID.utf8.count <= Self.maximumIdentifierBytes,
              (promptID.map { !$0.isEmpty && $0.utf8.count <= Self.maximumIdentifierBytes } ?? true)
        else { return nil }

        self.sessionID = sessionID
        self.responseID = responseID
        self.promptID = promptID
        self.labels = labels.prefix(Self.maximumSuggestions).compactMap { label in
            let cleaned = Self.sanitize(label)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    public init?(data: Data, authenticatedSessionID: String) {
        guard data.count <= Self.maximumWireBytes,
              let wire = try? JSONDecoder().decode(WirePayload.self, from: data)
        else { return nil }

        self.init(
            sessionID: authenticatedSessionID,
            responseID: wire.responseID ?? "",
            promptID: wire.promptID,
            labels: (wire.suggestions ?? []).map(\.label),
            isReplayed: wire.metadata?.isReplayed == true
        )
    }

    public static func sanitize(_ label: String) -> String {
        var scalars = String.UnicodeScalarView()
        var retained = 0
        for scalar in label.unicodeScalars where !pagerIsUnsafeDisplayScalar(scalar) {
            guard retained < maximumLabelScalars else { break }
            scalars.append(scalar)
            retained += 1
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WirePayload: Decodable {
    let responseID: String?
    let suggestions: [WireSuggestion]?
    let promptID: String?
    let metadata: WireMetadata?

    enum CodingKeys: String, CodingKey {
        case responseID = "response_id"
        case suggestions
        case promptID = "promptId"
        case metadata = "_meta"
    }
}

private struct WireSuggestion: Decodable {
    let label: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case label
    }
}

private struct WireMetadata: Decodable {
    let isReplayed: Bool

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            isReplayed = false
            return
        }
        isReplayed = (try? container.decode(Bool.self, forKey: .replayed)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case replayed = "x.ai/replayed"
    }
}

/// Newest-response-wins state that never lets an older response revive chips.
public struct FollowUpSuggestionsState: Sendable, Equatable {
    public static let maximumPendingTurns = 16

    public private(set) var sessionID: String?
    public private(set) var currentPromptID: String?
    public private(set) var current: FollowUpSuggestionPayload?
    public private(set) var nextGeneration: UInt64 = 0

    private var seenResponseGenerations: [String: UInt64] = [:]
    private var pendingByPromptID: [String: FollowUpSuggestionPayload] = [:]
    private var pendingPromptOrder: [String] = []

    public init(sessionID: String? = nil, currentPromptID: String? = nil) {
        self.sessionID = sessionID
        self.currentPromptID = currentPromptID
    }

    public var currentGeneration: UInt64? {
        current.flatMap { seenResponseGenerations[$0.responseID] }
    }

    public var pendingCount: Int { pendingByPromptID.count }
    public var seenResponseCount: Int { seenResponseGenerations.count }

    public mutating func bind(sessionID: String) {
        guard self.sessionID != sessionID else { return }
        reset(sessionID: sessionID)
    }

    @discardableResult
    public mutating func beginTurn(promptID: String?) -> Bool {
        let hadSuggestions = current != nil
        clearDisplayed()
        currentPromptID = promptID
        guard let promptID,
              let pending = pendingByPromptID.removeValue(forKey: promptID)
        else { return hadSuggestions }
        pendingPromptOrder.removeAll { $0 == promptID }
        return apply(pending) || hadSuggestions
    }

    @discardableResult
    public mutating func apply(_ payload: FollowUpSuggestionPayload) -> Bool {
        guard sessionID == payload.sessionID else { return false }

        if let current, current.responseID == payload.responseID {
            guard current.labels != payload.labels else { return false }
            if payload.labels.isEmpty {
                seenResponseGenerations.removeValue(forKey: payload.responseID)
                self.current = nil
            } else {
                self.current = payload
            }
            return true
        }

        let isCurrentTurn = payload.promptID != nil && payload.promptID == currentPromptID
        let namesOtherActiveTurn = payload.promptID != nil
            && currentPromptID != nil
            && payload.promptID != currentPromptID

        if seenResponseGenerations[payload.responseID] != nil {
            guard isCurrentTurn, !payload.labels.isEmpty else { return false }
            current = payload
            return true
        }

        if namesOtherActiveTurn {
            if let promptID = payload.promptID, !payload.labels.isEmpty {
                buffer(payload, for: promptID)
            }
            return false
        }

        let hadSuggestions = current != nil
        current = nil
        guard !payload.labels.isEmpty else { return hadSuggestions }

        seenResponseGenerations[payload.responseID] = nextGeneration
        nextGeneration &+= 1
        current = payload
        return true
    }

    public mutating func clearDisplayed() {
        current = nil
    }

    public mutating func reset(sessionID: String? = nil, preservingPromptID: String? = nil) {
        let retained = preservingPromptID.flatMap { promptID in
            if current?.promptID == promptID { return current }
            return pendingByPromptID[promptID]
        }

        self.sessionID = sessionID
        currentPromptID = nil
        current = nil
        nextGeneration = 0
        seenResponseGenerations.removeAll(keepingCapacity: false)
        pendingByPromptID.removeAll(keepingCapacity: false)
        pendingPromptOrder.removeAll(keepingCapacity: false)

        if let preservingPromptID, let retained, retained.sessionID == sessionID {
            pendingByPromptID[preservingPromptID] = retained
            pendingPromptOrder.append(preservingPromptID)
        }
    }

    private mutating func buffer(_ payload: FollowUpSuggestionPayload, for promptID: String) {
        let isNewPrompt = pendingByPromptID.updateValue(payload, forKey: promptID) == nil
        guard isNewPrompt else { return }

        pendingPromptOrder.append(promptID)
        if pendingPromptOrder.count > Self.maximumPendingTurns {
            let evicted = pendingPromptOrder.removeFirst()
            pendingByPromptID.removeValue(forKey: evicted)
        }
    }
}
