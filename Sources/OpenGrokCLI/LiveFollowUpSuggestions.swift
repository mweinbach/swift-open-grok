import Foundation
import OpenGrokPager
import OpenGrokPagerConversationUI
import OpenGrokPagerRender
import OpenGrokShared

struct LiveFollowUpSuggestionConnection: Sendable, Equatable, Hashable {
    let sessionID: String
    let generation: UInt64
    let connectionID: UUID
}

struct LiveFollowUpSuggestions: Sendable {
    private(set) var conversation = FollowUpSuggestionsState()
    private(set) var connection: LiveFollowUpSuggestionConnection?
    private(set) var hoveredIndex: Int?
    private var connectionGeneration: UInt64 = 0

    var renderModel: PagerFollowUpSuggestions? {
        guard let connection,
              let payload = conversation.current,
              let generation = conversation.currentGeneration
        else { return nil }
        return PagerFollowUpSuggestions(
            sessionID: payload.sessionID,
            responseID: payload.responseID,
            generation: generation,
            connectionID: connection.connectionID.uuidString,
            connectionGeneration: connection.generation,
            labels: payload.labels,
            hoveredIndex: hoveredIndex
        )
    }

    mutating func connect(sessionID: String) -> LiveFollowUpSuggestionConnection? {
        guard !sessionID.isEmpty,
              sessionID.utf8.count <= FollowUpSuggestionPayload.maximumIdentifierBytes
        else {
            disconnect()
            return nil
        }
        connectionGeneration &+= 1
        if connection != nil {
            conversation.reset(sessionID: sessionID)
        } else {
            conversation.bind(sessionID: sessionID)
        }
        hoveredIndex = nil
        let connection = LiveFollowUpSuggestionConnection(
            sessionID: sessionID,
            generation: connectionGeneration,
            connectionID: UUID()
        )
        self.connection = connection
        return connection
    }

    mutating func disconnect() {
        connectionGeneration &+= 1
        connection = nil
        hoveredIndex = nil
        conversation.reset()
    }

    @discardableResult
    mutating func beginTurn(promptID: String?) -> Bool {
        hoveredIndex = nil
        return conversation.beginTurn(promptID: promptID)
    }

    @discardableResult
    mutating func receive(
        sessionID: String,
        connectionID: UUID,
        generation: UInt64,
        params: JSONValue
    ) -> Bool {
        guard let connection,
              connection.sessionID == sessionID,
              connection.connectionID == connectionID,
              connection.generation == generation,
              conversation.sessionID == sessionID,
              let payload = Self.decode(params, authenticatedSessionID: sessionID)
        else { return false }

        let changed = conversation.apply(payload)
        if changed { hoveredIndex = nil }
        return changed
    }

    @discardableResult
    mutating func updateHover(_ index: Int?) -> Bool {
        guard hoveredIndex != index else { return false }
        hoveredIndex = index
        return true
    }

    mutating func takePrompt(
        for chip: PagerFollowUpSuggestionChip,
        activeSessionID: String
    ) -> String? {
        guard let connection,
              connection.sessionID == activeSessionID,
              chip.sessionID == activeSessionID,
              chip.connectionID == connection.connectionID.uuidString,
              chip.connectionGeneration == connection.generation,
              let payload = conversation.current,
              payload.responseID == chip.responseID,
              conversation.currentGeneration == chip.generation,
              payload.labels.indices.contains(chip.index),
              payload.labels[chip.index] == chip.label
        else { return nil }

        conversation.clearDisplayed()
        hoveredIndex = nil
        return chip.label
    }

    static func decode(
        _ params: JSONValue,
        authenticatedSessionID: String
    ) -> FollowUpSuggestionPayload? {
        guard case .object(let fields) = params,
              let responseID = fields["response_id"]?.stringValue
        else { return nil }

        for key in ["sessionId", "session_id"] {
            if let session = fields[key], session.stringValue != authenticatedSessionID {
                return nil
            }
        }
        let promptID: String?
        if let prompt = fields["promptId"] {
            guard let value = prompt.stringValue else { return nil }
            promptID = value
        } else {
            promptID = nil
        }
        let replayed = fields["_meta"]?["x.ai/replayed"]?.boolValue == true
        let rawSuggestions: [JSONValue]
        if let suggestions = fields["suggestions"] {
            guard let values = suggestions.arrayValue else { return nil }
            rawSuggestions = values
        } else {
            rawSuggestions = []
        }
        var labels: [String] = []
        labels.reserveCapacity(min(rawSuggestions.count, FollowUpSuggestionPayload.maximumSuggestions))
        for suggestion in rawSuggestions.prefix(FollowUpSuggestionPayload.maximumSuggestions) {
            guard let fields = suggestion.objectValue else { return nil }
            if let label = fields["label"] {
                guard let value = label.stringValue else { return nil }
                labels.append(value)
            } else {
                labels.append("")
            }
        }

        return FollowUpSuggestionPayload(
            sessionID: authenticatedSessionID,
            responseID: responseID,
            promptID: promptID,
            labels: labels,
            isReplayed: replayed
        )
    }
}

actor LiveFollowUpSuggestionRelay {
    static let shared = LiveFollowUpSuggestionRelay()

    private struct Registration: Sendable {
        let connection: LiveFollowUpSuggestionConnection
        let receive: @Sendable (LiveFollowUpSuggestionConnection, JSONValue) async -> Void
    }

    private var registrations: [String: Registration] = [:]

    func register(
        _ connection: LiveFollowUpSuggestionConnection,
        receive: @escaping @Sendable (LiveFollowUpSuggestionConnection, JSONValue) async -> Void
    ) {
        registrations[connection.sessionID] = Registration(connection: connection, receive: receive)
    }

    func unregister(_ connection: LiveFollowUpSuggestionConnection) {
        guard registrations[connection.sessionID]?.connection == connection else { return }
        registrations.removeValue(forKey: connection.sessionID)
    }

    func uniquelyRegisteredSessionID() -> String? {
        registrations.count == 1 ? registrations.keys.first : nil
    }

    func contains(_ connection: LiveFollowUpSuggestionConnection) -> Bool {
        registrations[connection.sessionID]?.connection == connection
    }

    func publish(sessionID: String, params: JSONValue) async {
        guard let registration = registrations[sessionID],
              registration.connection.sessionID == sessionID,
              registrations[sessionID]?.connection == registration.connection
        else { return }

        await registration.receive(registration.connection, params)
    }
}

extension LiveInteractiveControllerRenderer {
    func resetFollowUpSuggestionSession(to sessionID: String) {
        guard self.sessionID == sessionID else { return }
        let previous = liveFollowUpSuggestions.connection
        liveFollowUpSuggestions.disconnect()
        Task { [weak self] in
            if let previous {
                await LiveFollowUpSuggestionRelay.shared.unregister(previous)
            }
            guard let self else { return }
            await self.installFollowUpSuggestionRelay()
        }
    }

    func installFollowUpSuggestionRelay() async {
        if let previous = liveFollowUpSuggestions.connection {
            await LiveFollowUpSuggestionRelay.shared.unregister(previous)
        }
        guard let connection = liveFollowUpSuggestions.connect(sessionID: sessionID) else { return }

        await LiveFollowUpSuggestionRelay.shared.register(connection) { [weak self] connection, params in
            await self?.receiveFollowUpNotification(connection: connection, params: params)
        }
    }

    func uninstallFollowUpSuggestionRelay() async {
        let previous = liveFollowUpSuggestions.connection
        liveFollowUpSuggestions.disconnect()
        if let previous {
            await LiveFollowUpSuggestionRelay.shared.unregister(previous)
        }
    }

    func receiveFollowUpNotification(
        connection: LiveFollowUpSuggestionConnection,
        params: JSONValue
    ) async {
        guard await LiveFollowUpSuggestionRelay.shared.contains(connection),
              sessionID == connection.sessionID,
              liveFollowUpSuggestions.receive(
                  sessionID: connection.sessionID,
                  connectionID: connection.connectionID,
                  generation: connection.generation,
                  params: params
              )
        else { return }

        try? renderState()
    }

    func followUpSuggestionChip(atX x: Int, y: Int) -> PagerFollowUpSuggestionChip? {
        renderer.lastFollowUpSuggestionChips.first { $0.contains(x: x, y: y) }
    }

    func followUpSuggestionChipsForTesting() -> [PagerFollowUpSuggestionChip] {
        renderer.lastFollowUpSuggestionChips
    }
}
