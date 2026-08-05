import Foundation

public struct PagerItemID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }
}

public struct PagerTurnID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }
}

public enum PagerMessageRole: String, Hashable, Sendable, Codable {
    case user
    case assistant
    case reasoning
    case system
}

public struct PagerMessageItem: Hashable, Sendable, Codable {
    public var id: PagerItemID
    public var turnID: PagerTurnID?
    public var role: PagerMessageRole
    public var text: String
    public var isStreaming: Bool

    public init(
        id: PagerItemID,
        turnID: PagerTurnID? = nil,
        role: PagerMessageRole,
        text: String,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.turnID = turnID
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

public enum PagerToolStatus: String, Hashable, Sendable, Codable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public struct PagerToolCard: Hashable, Sendable, Codable {
    public var id: PagerItemID
    public var turnID: PagerTurnID
    public var toolCallID: String
    public var name: String
    public var input: String
    public var output: String
    public var status: PagerToolStatus
    public var isExpanded: Bool

    public init(
        id: PagerItemID,
        turnID: PagerTurnID,
        toolCallID: String,
        name: String,
        input: String = "",
        output: String = "",
        status: PagerToolStatus = .pending,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.turnID = turnID
        self.toolCallID = toolCallID
        self.name = name
        self.input = input
        self.output = output
        self.status = status
        self.isExpanded = isExpanded
    }
}

public struct PagerPermissionOption: Hashable, Sendable, Codable {
    public var id: String
    public var label: String
    public var isDestructive: Bool

    public init(id: String, label: String, isDestructive: Bool = false) {
        self.id = id
        self.label = label
        self.isDestructive = isDestructive
    }
}

public enum PagerPermissionResolution: String, Hashable, Sendable, Codable {
    case allowed
    case denied
    case cancelled
}

public struct PagerPermissionCard: Hashable, Sendable, Codable {
    public var id: PagerItemID
    public var turnID: PagerTurnID
    public var requestID: String
    public var toolCallID: String
    public var title: String
    public var detail: String
    public var options: [PagerPermissionOption]
    public var selectedOptionID: String?
    public var resolution: PagerPermissionResolution?

    public init(
        id: PagerItemID,
        turnID: PagerTurnID,
        requestID: String,
        toolCallID: String,
        title: String,
        detail: String = "",
        options: [PagerPermissionOption],
        selectedOptionID: String? = nil,
        resolution: PagerPermissionResolution? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.requestID = requestID
        self.toolCallID = toolCallID
        self.title = title
        self.detail = detail
        self.options = options
        self.selectedOptionID = selectedOptionID
        self.resolution = resolution
    }
}

public struct PagerStatusItem: Hashable, Sendable, Codable {
    public var id: PagerItemID
    public var turnID: PagerTurnID?
    public var phase: PagerStatusPhase
    public var message: String

    public init(id: PagerItemID, turnID: PagerTurnID? = nil, phase: PagerStatusPhase, message: String) {
        self.id = id
        self.turnID = turnID
        self.phase = phase
        self.message = message
    }
}

public enum PagerConversationItem: Hashable, Sendable, Codable {
    case message(PagerMessageItem)
    case tool(PagerToolCard)
    case permission(PagerPermissionCard)
    case status(PagerStatusItem)

    public var id: PagerItemID {
        switch self {
        case .message(let item): return item.id
        case .tool(let item): return item.id
        case .permission(let item): return item.id
        case .status(let item): return item.id
        }
    }

    public var turnID: PagerTurnID? {
        switch self {
        case .message(let item): return item.turnID
        case .tool(let item): return item.turnID
        case .permission(let item): return item.turnID
        case .status(let item): return item.turnID
        }
    }
}

public enum PagerFocus: Hashable, Sendable, Codable {
    case prompt
    case scrollback
    case tool(PagerItemID)
    case permission(String)
}

public enum PagerMode: String, Hashable, Sendable, Codable {
    case idle
    case editing
    case searching
    case streaming
    case awaitingPermission
    case cancelling
    case failed
}

public enum PagerScrollAction: Hashable, Sendable, Codable {
    case up(Int)
    case down(Int)
    case pageUp
    case pageDown
    case top
    case bottom
}

public struct PagerViewportState: Hashable, Sendable, Codable {
    public var offset: Int
    public var height: Int
    public var contentHeight: Int
    public var followsOutput: Bool

    public init(offset: Int = 0, height: Int = 0, contentHeight: Int = 0, followsOutput: Bool = true) {
        self.offset = max(0, offset)
        self.height = max(0, height)
        self.contentHeight = max(0, contentHeight)
        self.followsOutput = followsOutput
        self.offset = followsOutput ? maximumOffset : min(self.offset, maximumOffset)
    }

    public var maximumOffset: Int {
        max(0, contentHeight - height)
    }

    public var isAtBottom: Bool {
        offset >= maximumOffset
    }

    public mutating func clamp() {
        height = max(0, height)
        contentHeight = max(0, contentHeight)
        offset = min(max(0, offset), maximumOffset)
    }

    public mutating func scroll(_ action: PagerScrollAction) {
        switch action {
        case .up(let lines):
            offset -= max(0, lines)
            followsOutput = false
        case .down(let lines):
            offset += max(0, lines)
        case .pageUp:
            offset -= max(1, height)
            followsOutput = false
        case .pageDown:
            offset += max(1, height)
        case .top:
            offset = 0
            followsOutput = false
        case .bottom:
            offset = maximumOffset
            followsOutput = true
        }
        clamp()
        let movedTowardTop: Bool
        switch action {
        case .up, .pageUp, .top:
            movedTowardTop = true
        case .down, .pageDown, .bottom:
            movedTowardTop = false
        }
        if isAtBottom && !movedTowardTop {
            followsOutput = true
        }
    }

    public mutating func update(height: Int, contentHeight: Int) {
        self.height = max(0, height)
        self.contentHeight = max(0, contentHeight)
        if followsOutput {
            offset = maximumOffset
        } else {
            clamp()
        }
    }

    public mutating func setFollowsOutput(_ followsOutput: Bool) {
        self.followsOutput = followsOutput
        if followsOutput {
            offset = maximumOffset
        }
    }

}

public enum PagerStatusPhase: String, Hashable, Sendable, Codable {
    case idle
    case working
    case waitingForPermission
    case completed
    case cancelled
    case warning
    case failed
}

public struct PagerStatusState: Hashable, Sendable, Codable {
    public var phase: PagerStatusPhase
    public var message: String
    public var turnID: PagerTurnID?

    public init(phase: PagerStatusPhase = .idle, message: String = "", turnID: PagerTurnID? = nil) {
        self.phase = phase
        self.message = message
        self.turnID = turnID
    }
}

public enum PagerErrorCode: String, Hashable, Sendable, Codable {
    case unknown
    case transport
    case provider
    case permissionDenied
    case cancelled
    case invalidState
}

public struct PagerErrorState: Hashable, Sendable, Codable {
    public var code: PagerErrorCode
    public var message: String
    public var turnID: PagerTurnID?
    public var recoverable: Bool

    public init(
        code: PagerErrorCode = .unknown,
        message: String,
        turnID: PagerTurnID? = nil,
        recoverable: Bool = true
    ) {
        self.code = code
        self.message = message
        self.turnID = turnID
        self.recoverable = recoverable
    }
}

public enum PagerCancellationPhase: String, Hashable, Sendable, Codable {
    case requested
    case acknowledged
}

public struct PagerCancellationState: Hashable, Sendable, Codable {
    public var phase: PagerCancellationPhase
    public var turnID: PagerTurnID
    public var reason: String?

    public init(phase: PagerCancellationPhase, turnID: PagerTurnID, reason: String? = nil) {
        self.phase = phase
        self.turnID = turnID
        self.reason = reason
    }
}

public struct PagerState: Hashable, Sendable, Codable {
    public var sessionID: String
    public var conversation: [PagerConversationItem]
    public var draft: String
    public var focus: PagerFocus
    public var mode: PagerMode
    public var searchQuery: String
    public var viewport: PagerViewportState
    public var status: PagerStatusState
    public var error: PagerErrorState?
    public var activeTurnID: PagerTurnID?
    public var streamingItemID: PagerItemID?
    public var cancellation: PagerCancellationState?
    public var finishedTurnIDs: Set<PagerTurnID>
    public var nextSequence: UInt64

    public init(
        sessionID: String,
        conversation: [PagerConversationItem] = [],
        draft: String = "",
        focus: PagerFocus = .prompt,
        mode: PagerMode = .idle,
        searchQuery: String = "",
        viewport: PagerViewportState = PagerViewportState(),
        status: PagerStatusState = PagerStatusState(),
        error: PagerErrorState? = nil,
        activeTurnID: PagerTurnID? = nil,
        streamingItemID: PagerItemID? = nil,
        cancellation: PagerCancellationState? = nil,
        finishedTurnIDs: Set<PagerTurnID> = [],
        nextSequence: UInt64 = 0
    ) {
        self.sessionID = sessionID
        self.conversation = conversation
        self.draft = draft
        self.focus = focus
        self.mode = mode
        self.searchQuery = searchQuery
        self.viewport = viewport
        self.status = status
        self.error = error
        self.activeTurnID = activeTurnID
        self.streamingItemID = streamingItemID
        self.cancellation = cancellation
        self.finishedTurnIDs = finishedTurnIDs
        self.nextSequence = nextSequence
    }

    public var pendingPermissionCards: [PagerPermissionCard] {
        conversation.compactMap { item in
            guard case .permission(let card) = item, card.resolution == nil else { return nil }
            return card
        }
    }

    public var pendingToolCards: [PagerToolCard] {
        conversation.compactMap { item in
            guard case .tool(let card) = item, card.status == .pending || card.status == .running else {
                return nil
            }
            return card
        }
    }

    public func item(with id: PagerItemID) -> PagerConversationItem? {
        conversation.first { $0.id == id }
    }

    public func permission(with requestID: String) -> PagerPermissionCard? {
        conversation.compactMap { item -> PagerPermissionCard? in
            guard case .permission(let card) = item, card.requestID == requestID else { return nil }
            return card
        }.first
    }

    fileprivate mutating func nextItemID() -> PagerItemID {
        nextSequence += 1
        return PagerItemID("item-\(nextSequence)")
    }

    fileprivate mutating func nextTurnID() -> PagerTurnID {
        nextSequence += 1
        return PagerTurnID("turn-\(nextSequence)")
    }

    fileprivate func index(of id: PagerItemID) -> Int? {
        conversation.firstIndex { $0.id == id }
    }

    fileprivate func index(ofPermission requestID: String) -> Int? {
        conversation.firstIndex { item in
            guard case .permission(let card) = item else { return false }
            return card.requestID == requestID
        }
    }
}

public enum PagerAction: Hashable, Sendable {
    case updateDraft(String)
    case submitPrompt(String)
    case focus(PagerFocus)
    case setMode(PagerMode)
    case setSearchQuery(String)
    case scroll(PagerScrollAction)
    case setViewport(height: Int, contentHeight: Int)
    case setFollowsOutput(Bool)
    case cancel(reason: String?)
    case resolvePermission(requestID: String, optionID: String)
    case dismissError
    case toggleTool(PagerItemID)
}

public enum PagerEvent: Hashable, Sendable {
    case turnStarted(PagerTurnID)
    case streamStarted(turnID: PagerTurnID, itemID: PagerItemID)
    case streamDelta(turnID: PagerTurnID, itemID: PagerItemID, text: String)
    case streamFinished(turnID: PagerTurnID, itemID: PagerItemID)
    case toolStarted(PagerToolCard)
    case toolUpdated(
        turnID: PagerTurnID,
        itemID: PagerItemID,
        status: PagerToolStatus?,
        input: String?,
        output: String?
    )
    case toolFinished(turnID: PagerTurnID, itemID: PagerItemID, status: PagerToolStatus, output: String?)
    case permissionRequested(PagerPermissionCard)
    case permissionResolved(
        turnID: PagerTurnID,
        requestID: String,
        optionID: String?,
        resolution: PagerPermissionResolution
    )
    case statusChanged(PagerStatusState)
    case error(PagerErrorState, terminal: Bool)
    case turnCompleted(PagerTurnID, message: String?)
    case turnCancelled(PagerTurnID, reason: String?)
    case turnFailed(PagerTurnID, error: PagerErrorState)
}

public enum PagerCommand: Hashable, Sendable {
    case startTurn(turnID: PagerTurnID, prompt: String)
    case cancelTurn(turnID: PagerTurnID)
    case resolvePermission(requestID: String, optionID: String)
}

public struct PagerTransition: Hashable, Sendable {
    public var state: PagerState
    public var commands: [PagerCommand]
    public var ignored: Bool

    public init(state: PagerState, commands: [PagerCommand] = [], ignored: Bool = false) {
        self.state = state
        self.commands = commands
        self.ignored = ignored
    }
}

public enum PagerReducer {
    public static func reduce(_ state: PagerState, _ action: PagerAction) -> PagerTransition {
        var next = state
        var commands: [PagerCommand] = []

        switch action {
        case .updateDraft(let draft):
            guard next.activeTurnID == nil, next.cancellation == nil || next.cancellation?.phase == .acknowledged else {
                return transition(from: state, to: next, commands: commands)
            }
            next.draft = draft
            if next.focus == .prompt {
                next.mode = draft.isEmpty ? .idle : .editing
            }

        case .submitPrompt(let prompt):
            guard next.activeTurnID == nil, next.pendingPermissionCards.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return transition(from: state, to: next, commands: commands)
            }
            let turnID = next.nextTurnID()
            let itemID = next.nextItemID()
            next.conversation.append(.message(PagerMessageItem(
                id: itemID,
                turnID: turnID,
                role: .user,
                text: prompt
            )))
            next.activeTurnID = turnID
            next.streamingItemID = nil
            next.draft = ""
            next.mode = .streaming
            next.error = nil
            next.cancellation = nil
            next.status = PagerStatusState(phase: .working, message: "Working", turnID: turnID)
            next.viewport.setFollowsOutput(true)
            commands.append(.startTurn(turnID: turnID, prompt: prompt))

        case .focus(let focus):
            switch focus {
            case .prompt, .scrollback:
                next.focus = focus
            case .tool(let itemID):
                guard next.item(with: itemID).map(isTool) == true else {
                    return transition(from: state, to: next, commands: commands)
                }
                next.focus = focus
            case .permission(let requestID):
                guard next.permission(with: requestID).map({ $0.resolution == nil }) == true else {
                    return transition(from: state, to: next, commands: commands)
                }
                next.focus = focus
                next.mode = .awaitingPermission
            }
            if next.activeTurnID == nil {
                switch focus {
                case .prompt where next.mode == .idle || next.mode == .searching:
                    next.mode = next.draft.isEmpty ? .idle : .editing
                case .scrollback where next.mode == .editing:
                    next.mode = .idle
                default:
                    break
                }
            }

        case .setMode(let mode):
            guard next.activeTurnID == nil else {
                return transition(from: state, to: next, commands: commands)
            }
            switch mode {
            case .idle:
                next.mode = .idle
            case .editing:
                guard next.focus == .prompt else {
                    return transition(from: state, to: next, commands: commands)
                }
                next.mode = .editing
            case .searching:
                guard next.focus == .scrollback else {
                    return transition(from: state, to: next, commands: commands)
                }
                next.mode = .searching
            case .streaming, .awaitingPermission, .cancelling, .failed:
                return transition(from: state, to: next, commands: commands)
            }

        case .setSearchQuery(let query):
            guard next.mode == .searching else {
                return transition(from: state, to: next, commands: commands)
            }
            next.searchQuery = query

        case .scroll(let action):
            next.viewport.scroll(action)

        case .setViewport(let height, let contentHeight):
            next.viewport.update(height: height, contentHeight: contentHeight)

        case .setFollowsOutput(let followsOutput):
            next.viewport.setFollowsOutput(followsOutput)

        case .cancel(let reason):
            guard let turnID = next.activeTurnID, next.mode != .cancelling else {
                return transition(from: state, to: next, commands: commands)
            }
            next.mode = .cancelling
            next.cancellation = PagerCancellationState(phase: .requested, turnID: turnID, reason: reason)
            next.status = PagerStatusState(phase: .working, message: "Cancelling", turnID: turnID)
            next.resolvePendingPermissions(for: turnID, resolution: .cancelled)
            commands.append(.cancelTurn(turnID: turnID))

        case .resolvePermission(let requestID, let optionID):
            guard let card = next.permission(with: requestID),
                  card.resolution == nil,
                  next.activeTurnID == card.turnID,
                  card.options.contains(where: { $0.id == optionID }) else {
                return transition(from: state, to: next, commands: commands)
            }
            let resolution: PagerPermissionResolution = card.options.first(where: { $0.id == optionID })?.isDestructive == true ? .denied : .allowed
            next.updatePermission(
                requestID: requestID,
                optionID: optionID,
                resolution: resolution
            )
            if next.pendingPermissionCards.isEmpty {
                next.focus = .prompt
                next.mode = .streaming
                next.status = PagerStatusState(phase: .working, message: "Working", turnID: card.turnID)
            }
            commands.append(.resolvePermission(requestID: requestID, optionID: optionID))

        case .dismissError:
            guard next.error != nil else {
                return transition(from: state, to: next, commands: commands)
            }
            next.error = nil
            if next.activeTurnID == nil {
                next.mode = next.focus == .prompt ? .editing : .idle
                next.status = PagerStatusState(phase: .idle)
            } else if next.mode == .failed {
                next.mode = .streaming
            }

        case .toggleTool(let itemID):
            guard next.toggleTool(itemID: itemID) else {
                return transition(from: state, to: next, commands: commands)
            }
        }

        return transition(from: state, to: next, commands: commands)
    }

    public static func apply(_ state: PagerState, _ event: PagerEvent) -> PagerTransition {
        var next = state

        switch event {
        case .turnStarted(let turnID):
            guard !next.finishedTurnIDs.contains(turnID) else {
                return transition(from: state, to: next)
            }
            if let activeTurnID = next.activeTurnID {
                guard activeTurnID == turnID else {
                    return transition(from: state, to: next)
                }
            } else {
                next.activeTurnID = turnID
                next.mode = .streaming
                next.cancellation = nil
                next.status = PagerStatusState(phase: .working, message: "Working", turnID: turnID)
            }

        case .streamStarted(let turnID, let itemID):
            guard next.acceptsLiveEvent(for: turnID), next.mode != .cancelling else {
                return transition(from: state, to: next)
            }
            if let streamingItemID = next.streamingItemID, streamingItemID != itemID {
                return transition(from: state, to: next)
            }
            if let index = next.index(of: itemID) {
                guard case .message(var message) = next.conversation[index], message.turnID == turnID else {
                    return transition(from: state, to: next)
                }
                message.isStreaming = true
                next.conversation[index] = .message(message)
            } else {
                next.conversation.append(.message(PagerMessageItem(
                    id: itemID,
                    turnID: turnID,
                    role: .assistant,
                    text: "",
                    isStreaming: true
                )))
            }
            next.streamingItemID = itemID
            next.mode = .streaming

        case .streamDelta(let turnID, let itemID, let text):
            guard next.acceptsLiveEvent(for: turnID), next.mode != .cancelling else {
                return transition(from: state, to: next)
            }
            guard let index = next.index(of: itemID) else {
                next.conversation.append(.message(PagerMessageItem(
                    id: itemID,
                    turnID: turnID,
                    role: .assistant,
                    text: text,
                    isStreaming: true
                )))
                next.streamingItemID = itemID
                next.mode = .streaming
                return transition(from: state, to: next)
            }
            guard case .message(var message) = next.conversation[index], message.turnID == turnID,
                  message.role == .assistant || message.role == .reasoning else {
                return transition(from: state, to: next)
            }
            message.text.append(text)
            message.isStreaming = true
            next.conversation[index] = .message(message)
            next.streamingItemID = itemID
            next.mode = .streaming

        case .streamFinished(let turnID, let itemID):
            guard next.acceptsLiveEvent(for: turnID), let index = next.index(of: itemID) else {
                return transition(from: state, to: next)
            }
            guard case .message(var message) = next.conversation[index], message.turnID == turnID else {
                return transition(from: state, to: next)
            }
            message.isStreaming = false
            next.conversation[index] = .message(message)
            if next.streamingItemID == itemID {
                next.streamingItemID = nil
            }

        case .toolStarted(let card):
            guard next.acceptsLiveEvent(for: card.turnID), next.mode != .cancelling else {
                return transition(from: state, to: next)
            }
            next.upsertTool(card)
            next.mode = .streaming
            next.status = PagerStatusState(phase: .working, message: "Using \(card.name)", turnID: card.turnID)

        case .toolUpdated(let turnID, let itemID, let status, let input, let output):
            guard next.acceptsLiveEvent(for: turnID), let index = next.index(of: itemID) else {
                return transition(from: state, to: next)
            }
            guard case .tool(var card) = next.conversation[index], card.turnID == turnID else {
                return transition(from: state, to: next)
            }
            if let status { card.status = status }
            if let input { card.input = input }
            if let output { card.output = output }
            next.conversation[index] = .tool(card)
            next.status = PagerStatusState(phase: .working, message: "Using \(card.name)", turnID: turnID)

        case .toolFinished(let turnID, let itemID, let status, let output):
            guard next.acceptsLiveEvent(for: turnID), let index = next.index(of: itemID) else {
                return transition(from: state, to: next)
            }
            guard case .tool(var card) = next.conversation[index], card.turnID == turnID else {
                return transition(from: state, to: next)
            }
            card.status = status
            if let output { card.output = output }
            next.conversation[index] = .tool(card)

        case .permissionRequested(let card):
            guard next.acceptsLiveEvent(for: card.turnID), next.mode != .cancelling else {
                return transition(from: state, to: next)
            }
            next.upsertPermission(card)
            next.focus = .permission(card.requestID)
            next.mode = .awaitingPermission
            next.status = PagerStatusState(phase: .waitingForPermission, message: card.title, turnID: card.turnID)

        case .permissionResolved(let turnID, let requestID, let optionID, let resolution):
            guard next.acceptsLiveEvent(for: turnID), let card = next.permission(with: requestID), card.turnID == turnID,
                  card.resolution == nil else {
                return transition(from: state, to: next)
            }
            next.updatePermission(requestID: requestID, optionID: optionID, resolution: resolution)
            if next.pendingPermissionCards.isEmpty {
                next.focus = .prompt
                next.mode = .streaming
                next.status = PagerStatusState(phase: .working, message: "Working", turnID: turnID)
            }

        case .statusChanged(let status):
            guard status.turnID == nil || status.turnID == next.activeTurnID else {
                return transition(from: state, to: next)
            }
            next.status = status

        case .error(let error, let terminal):
            if let turnID = error.turnID {
                guard next.acceptsLiveEvent(for: turnID) else {
                    return transition(from: state, to: next)
                }
            }
            next.error = error
            next.status = PagerStatusState(phase: .failed, message: error.message, turnID: error.turnID)
            if terminal, let turnID = error.turnID {
                next.finishTurn(turnID: turnID, phase: .failed, message: error.message, error: error)
            } else if !terminal {
                next.mode = next.activeTurnID == nil ? .failed : .streaming
            }

        case .turnCompleted(let turnID, let message):
            guard next.acceptsTerminalEvent(for: turnID) else {
                return transition(from: state, to: next)
            }
            next.finishTurn(turnID: turnID, phase: .completed, message: message ?? "Turn completed", error: nil)

        case .turnCancelled(let turnID, let reason):
            guard next.acceptsTerminalEvent(for: turnID) else {
                return transition(from: state, to: next)
            }
            next.resolvePendingPermissions(for: turnID, resolution: .cancelled)
            next.focus = .prompt
            next.finishTurn(turnID: turnID, phase: .cancelled, message: reason ?? "Turn cancelled", error: nil)
            next.cancellation = PagerCancellationState(
                phase: .acknowledged,
                turnID: turnID,
                reason: reason
            )

        case .turnFailed(let turnID, let error):
            guard next.acceptsTerminalEvent(for: turnID) else {
                return transition(from: state, to: next)
            }
            next.error = error
            next.finishTurn(turnID: turnID, phase: .failed, message: error.message, error: error)
        }

        return transition(from: state, to: next)
    }

    private static func transition(from old: PagerState, to next: PagerState, commands: [PagerCommand] = []) -> PagerTransition {
        PagerTransition(state: next, commands: commands, ignored: old == next && commands.isEmpty)
    }

    private static func isTool(_ item: PagerConversationItem) -> Bool {
        if case .tool = item { return true }
        return false
    }
}

public struct PagerStore: Sendable {
    public private(set) var state: PagerState

    public init(state: PagerState) {
        self.state = state
    }

    @discardableResult
    public mutating func dispatch(_ action: PagerAction) -> PagerTransition {
        let transition = PagerReducer.reduce(state, action)
        state = transition.state
        return transition
    }

    @discardableResult
    public mutating func receive(_ event: PagerEvent) -> PagerTransition {
        let transition = PagerReducer.apply(state, event)
        state = transition.state
        return transition
    }
}

private extension PagerState {
    func acceptsLiveEvent(for turnID: PagerTurnID) -> Bool {
        activeTurnID == turnID && !finishedTurnIDs.contains(turnID)
    }

    func acceptsTerminalEvent(for turnID: PagerTurnID) -> Bool {
        acceptsLiveEvent(for: turnID)
    }

    mutating func upsertTool(_ card: PagerToolCard) {
        if let index = index(of: card.id) {
            conversation[index] = .tool(card)
        } else {
            conversation.append(.tool(card))
        }
    }

    mutating func upsertPermission(_ card: PagerPermissionCard) {
        if let index = index(of: card.id) {
            conversation[index] = .permission(card)
        } else if let index = index(ofPermission: card.requestID) {
            conversation[index] = .permission(card)
        } else {
            conversation.append(.permission(card))
        }
    }

    mutating func updatePermission(
        requestID: String,
        optionID: String?,
        resolution: PagerPermissionResolution
    ) {
        guard let index = index(ofPermission: requestID), case .permission(var card) = conversation[index] else {
            return
        }
        card.selectedOptionID = optionID
        card.resolution = resolution
        conversation[index] = .permission(card)
    }

    mutating func resolvePendingPermissions(for turnID: PagerTurnID, resolution: PagerPermissionResolution) {
        for index in conversation.indices {
            guard case .permission(var card) = conversation[index], card.turnID == turnID, card.resolution == nil else {
                continue
            }
            card.resolution = resolution
            conversation[index] = .permission(card)
        }
    }

    mutating func toggleTool(itemID: PagerItemID) -> Bool {
        guard let index = index(of: itemID), case .tool(var card) = conversation[index] else {
            return false
        }
        card.isExpanded.toggle()
        conversation[index] = .tool(card)
        return true
    }

    mutating func finishTurn(
        turnID: PagerTurnID,
        phase: PagerStatusPhase,
        message: String,
        error: PagerErrorState?
    ) {
        guard activeTurnID == turnID else { return }
        for index in conversation.indices {
            guard case .message(var item) = conversation[index], item.turnID == turnID else { continue }
            item.isStreaming = false
            conversation[index] = .message(item)
        }
        activeTurnID = nil
        streamingItemID = nil
        finishedTurnIDs.insert(turnID)
        self.error = error
        status = PagerStatusState(phase: phase, message: message, turnID: turnID)
        if phase != .cancelled {
            cancellation = nil
        }
        mode = phase == .failed ? .failed : (focus == .prompt ? .editing : .idle)
    }
}
