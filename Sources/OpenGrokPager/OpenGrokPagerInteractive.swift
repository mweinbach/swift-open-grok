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

/// A scrollback movement the transcript viewport should apply.
///
/// The reference binds these under `When::ScrollbackFocused`
/// (`src/actions/defaults.rs:175-239`); this port routes them from the prompt
/// because the Swift TUI has a single focus region.
public enum OpenGrokPagerViewportCommand: Sendable, Equatable, Hashable {
    case lineUp
    case lineDown
    case halfPageUp
    case halfPageDown
    case pageUp
    case pageDown
    case top
    case bottom
}

/// One row of the slash-command dropdown.
public struct OpenGrokPagerCommandSuggestion: Sendable, Equatable, Hashable {
    public let name: String
    public let summary: String
    public let isAvailable: Bool

    public init(name: String, summary: String, isAvailable: Bool = true) {
        self.name = name
        self.summary = summary
        self.isAvailable = isAvailable
    }
}

public struct OpenGrokPagerInteractivePromptState: Sendable, Equatable {
    public let text: String
    public let cursorOffset: Int
    /// Slash-command completions for the current text. Empty when the dropdown
    /// is closed.
    public let completions: [OpenGrokPagerCommandSuggestion]
    public let selectedCompletion: Int?
    /// An armed double-press confirmation, as `(key, label)`. The renderer
    /// replaces the whole shortcuts bar with `press again to {label}`.
    public let pendingConfirmationKey: String?
    public let pendingConfirmationLabel: String?

    public init(
        text: String = "",
        cursorOffset: Int = 0,
        completions: [OpenGrokPagerCommandSuggestion] = [],
        selectedCompletion: Int? = nil,
        pendingConfirmationKey: String? = nil,
        pendingConfirmationLabel: String? = nil
    ) {
        self.text = text
        self.cursorOffset = max(0, min(cursorOffset, text.count))
        self.completions = completions
        self.selectedCompletion = selectedCompletion
        self.pendingConfirmationKey = pendingConfirmationKey
        self.pendingConfirmationLabel = pendingConfirmationLabel
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

/// A UI surface the controller asks the renderer to present. The controller
/// owns the slash-command vocabulary but not the overlay stack, which lives in
/// the render layer, so the command handler emits an intent instead of a modal.
public enum OpenGrokPagerOverlayRequest: Sendable, Equatable, Hashable {
    /// `/help` — the shortcuts modal (spec §16.5), not a transcript dump.
    case help
    /// `/model` — the model picker.
    case modelPicker
    /// `/toggle-mouse-reporting` — hand click-drag back to the terminal for
    /// native copy/paste, or take it back.
    case toggleMouseReporting
    /// `/workflows` — the background workflow-run overlay.
    case workflows
    case dismissAll
}

/// Whether the renderer already consumed an input event.
///
/// An active overlay swallows every key, including keys it does not act on —
/// the reference's rule that a modal never leaks a keystroke to the composer.
public enum OpenGrokPagerInputRouting: Sendable, Equatable, Hashable {
    /// Nothing claimed the event; run the normal prompt pipeline.
    case notHandled
    /// Fully handled and already repainted.
    case consumed
}

public enum OpenGrokPagerInteractiveEvent: Sendable, Equatable {
    case lifecycle(OpenGrokPagerInteractiveLifecycle)
    case promptChanged(OpenGrokPagerInteractivePromptState)
    case turnStarted(OpenGrokPagerRequest)
    case session(OpenGrokPagerEvent)
    case turnFinished(OpenGrokPagerRuntimeResult)
    case notice(String)
    /// The user moved the transcript viewport.
    case viewport(OpenGrokPagerViewportCommand)
    /// Present (or dismiss) an overlay. Renderers with no overlay stack — the
    /// headless and test adapters — ignore it.
    case overlay(OpenGrokPagerOverlayRequest)
    /// A turn was cancelled but the session stays open for the next prompt —
    /// distinct from `.cancelled`, which ends the run.
    case turnCancelled
    /// The number of prompts waiting behind the running turn changed. Carried
    /// as a count rather than the queue itself: the renderer paints `+{n}` and
    /// the `"Enter to send now"` suffix, and needs nothing else.
    case queueChanged(queuedPromptCount: Int)
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

    /// First refusal on raw input, ahead of the prompt state machine.
    ///
    /// Overlays and the mouse router live in the render layer, so the
    /// controller offers every event here before interpreting it. Renderers
    /// with neither default to `.notHandled` and behave exactly as before.
    func handleInput(_ event: InputEvent) async throws -> OpenGrokPagerInputRouting
}

extension OpenGrokPagerInteractiveRenderAdapter {
    public func resize(to size: TerminalSize) async throws {
        _ = size
    }

    public func handleInput(_ event: InputEvent) async throws -> OpenGrokPagerInputRouting {
        _ = event
        return .notHandled
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
