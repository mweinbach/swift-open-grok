import Foundation
import OpenGrokTerminalCore

public typealias OpenGrokPagerInputEventStream = AsyncThrowingStream<InputEvent, Error>

public enum OpenGrokPagerInteractiveLifecycle: String, Sendable, Equatable {
    case idle
    case starting
    case editing
    case running
    case cancelling
    case eof
    case completed
    case cancelled
    case failed
    case shutdown
}

public struct OpenGrokPagerInteractivePromptState: Sendable, Equatable {
    public let text: String
    public let cursorOffset: Int

    public init(text: String = "", cursorOffset: Int = 0) {
        self.text = text
        self.cursorOffset = max(0, min(cursorOffset, text.count))
    }
}

public struct OpenGrokPagerInteractiveState: Sendable, Equatable {
    public let lifecycle: OpenGrokPagerInteractiveLifecycle
    public let prompt: OpenGrokPagerInteractivePromptState
    public let submittedPrompts: [String]
    public let completedTurnCount: Int
    public let activeSessionID: String?
    public let lastSessionID: String?
    public let terminalRestored: Bool

    public init(
        lifecycle: OpenGrokPagerInteractiveLifecycle,
        prompt: OpenGrokPagerInteractivePromptState,
        submittedPrompts: [String],
        completedTurnCount: Int,
        activeSessionID: String?,
        lastSessionID: String?,
        terminalRestored: Bool
    ) {
        self.lifecycle = lifecycle
        self.prompt = prompt
        self.submittedPrompts = submittedPrompts
        self.completedTurnCount = completedTurnCount
        self.activeSessionID = activeSessionID
        self.lastSessionID = lastSessionID
        self.terminalRestored = terminalRestored
    }
}

public struct OpenGrokPagerInteractiveResult: Sendable, Equatable {
    public let lifecycle: OpenGrokPagerInteractiveLifecycle
    public let sessionID: String?
    public let submittedPrompts: [String]
    public let completedTurnCount: Int
    public let terminalRestored: Bool

    public init(
        lifecycle: OpenGrokPagerInteractiveLifecycle,
        sessionID: String?,
        submittedPrompts: [String],
        completedTurnCount: Int,
        terminalRestored: Bool
    ) {
        self.lifecycle = lifecycle
        self.sessionID = sessionID
        self.submittedPrompts = submittedPrompts
        self.completedTurnCount = completedTurnCount
        self.terminalRestored = terminalRestored
    }
}

public enum OpenGrokPagerInteractiveEvent: Sendable, Equatable {
    case lifecycle(OpenGrokPagerInteractiveLifecycle)
    case promptChanged(OpenGrokPagerInteractivePromptState)
    case turnStarted(OpenGrokPagerRequest)
    case session(OpenGrokPagerEvent)
    case turnFinished(OpenGrokPagerRuntimeResult)
    case notice(String)
    case eof
    case cancelled
    case failed(String)
    case shutdown
}

public protocol OpenGrokPagerInteractiveRenderAdapter: Sendable {
    func begin() async throws
    func render(_ event: OpenGrokPagerInteractiveEvent) async throws
    func resize(to size: TerminalSize) async throws
    func restoreTerminal() async throws
}

extension OpenGrokPagerInteractiveRenderAdapter {
    public func resize(to size: TerminalSize) async throws {
        _ = size
    }
}

public protocol OpenGrokPagerInteractiveOutputAdapter: Sendable {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws
}

public protocol OpenGrokPagerInteractiveFrontend: Sendable {
    func run(_ request: OpenGrokPagerRequest) async throws -> OpenGrokPagerInteractiveResult

    func cancel() async
    func shutdown() async
}

public enum OpenGrokPagerInteractiveError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case shutdown
    case inputFailed(String)
    case sessionFailed(String)
    case terminalRestorationFailed(String)

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "interactive pager is already running"
        case .shutdown:
            return "interactive pager has been shut down"
        case .inputFailed(let message):
            return "interactive pager input failed: \(message)"
        case .sessionFailed(let message):
            return "interactive pager session failed: \(message)"
        case .terminalRestorationFailed(let message):
            return "interactive pager could not restore the terminal: \(message)"
        }
    }
}
