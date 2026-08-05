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

/// Which region owns the keyboard.
///
/// The reference splits its binding table across `When::PromptFocused` and
/// `When::ScrollbackFocused` (`src/actions/mod.rs:149-167`) and switches
/// between them with `Tab` alone — `FocusScrollback` (`defaults.rs:488`) and
/// `FocusPrompt` (`defaults.rs:475`). Esc is deliberately *not* a focus key
/// upstream; it belongs to the cancel/clear/rewind ladder.
public enum OpenGrokPagerFocusRegion: String, Sendable, Equatable, Hashable {
    case prompt
    case scrollback
}

/// A scrollback movement the transcript viewport should apply.
///
/// The reference binds these under `When::ScrollbackFocused`
/// (`src/actions/defaults.rs:175-239`). This port now has a real focus model,
/// so they arrive from either region: the scroll semantics stay available from
/// the composer (an empty-composer `Up`, `PageUp`, `Ctrl+U`) and the full set
/// is reachable once focus moves to the scrollback.
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

/// An action on the *selected block*, bound under `When::ScrollbackFocused`.
///
/// These are the 21 bindings the port could not reach before, because with a
/// single focus region there was no notion of a selected block to act on. The
/// controller owns the focus and the key mapping; the render layer owns the
/// block list, so it owns the selection cursor and every effect below.
public enum OpenGrokPagerScrollbackCommand: Sendable, Equatable, Hashable {
    /// `j` / `k` (`defaults.rs:85,98`).
    case selectNext
    case selectPrevious
    /// `L` / `H` — whole user↔assistant exchanges (`:111,124`).
    case nextTurn
    case previousTurn
    /// `J` / `K` — assistant responses only (`:137,150`).
    case nextResponse
    case previousResponse
    /// `g` / `G` (`:163,176`). Distinct from `.viewport(.top/.bottom)`: these
    /// move the *selection*, and the viewport follows it.
    case selectFirst
    case selectLast
    /// `h` / `l` (`:272,285`).
    case collapse
    case expand
    /// `e` / `E` / `Ctrl+E` (`:298,313,328`).
    case toggleFold
    case toggleExpandAll
    case expandAllThinking
    /// `r` (`:343`) — show the block's source instead of its rendering.
    case toggleRaw
    /// `y` / `Y` (`:359,374`).
    case copyBlockContent
    case copyBlockMetadata
    /// `Enter` (`:389`).
    case openBlockViewer
    /// `o` / `O` (`:405,418`).
    case openNextLink
    case openPreviousLink
    /// `x` (`:447`).
    case killBackgroundTask
}

/// An application-level action bound under `When::AgentScreen` or
/// `When::Always` — the chords that work regardless of which region has focus.
///
/// Only the ones this port can route somewhere real are ever emitted; see
/// `OpenGrokPagerInteractiveController.controlCommand(for:)`.
public enum OpenGrokPagerGlobalCommand: Sendable, Equatable, Hashable {
    /// `Ctrl+P` (`defaults.rs:786`). Falls through from the dropdown intercept:
    /// while a completion menu is open `Ctrl+P` moves its selection instead,
    /// exactly as `app/agent_view/prompt.rs:212-221` does.
    case commandPalette
    /// `Ctrl+.` with `Ctrl+X` as the alternate (`:801`).
    case shortcutsHelp
    /// `Ctrl+M` off the prompt (`:824`). In the prompt the same chord toggles
    /// multiline (`:702`), which is why this is resolved against focus.
    case modelPicker
    /// `Ctrl+T` (`:536`).
    case toggleTodos
    /// `Ctrl+G` (`:49`).
    case toggleTasks
    /// `Ctrl+;` with `Ctrl+'` as the alternate (`:551`).
    case toggleQueue
    /// `Ctrl+B` (`:614`).
    case sendToBackground
    /// `Ctrl+N` (`:748`). Like `Ctrl+P` this falls through the dropdown
    /// intercept, and like upstream it requires a confirming second press.
    case newSession
    /// `Ctrl+O` (`:733`).
    case toggleAlwaysApprove
    /// `Shift+Tab` / `BackTab` (`:518`).
    case cyclePermissionMode
    /// `Ctrl+\` (`:890`).
    case openDashboard
    /// `F2` (`:839`).
    case openSettings
    /// `Ctrl+S` (`:579`).
    case openSessions
    /// `Ctrl+L` (`:594`).
    case openExtensions
}

/// One row of the slash-command dropdown.
public struct OpenGrokPagerCommandSuggestion: Sendable, Equatable, Hashable {
    public let name: String
    public let summary: String
    public let isAvailable: Bool
    /// The whole composer text this row commits to. For a command row that is
    /// just the command name, but an argument row has to carry the command
    /// along with it — accepting `codex:gpt-5.6-sol` must leave `/model
    /// codex:gpt-5.6-sol` behind, not the bare selector.
    public let insertText: String

    public init(
        name: String,
        summary: String,
        isAvailable: Bool = true,
        insertText: String? = nil
    ) {
        self.name = name
        self.summary = summary
        self.isAvailable = isAvailable
        self.insertText = insertText ?? name
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

/// The composer/scrollback modes a user can flip at runtime.
///
/// Upstream keeps each of these in the settings registry (`settings/defs.rs`)
/// and exposes a slash command per row; this port carries the four the TUI can
/// honor today as one value so a renderer only has to agree with a snapshot.
public struct OpenGrokPagerInputModes: Sendable, Equatable, Hashable {
    /// `/multiline`, `Ctrl+M` (`defs.rs`, `defaults.rs:702`). Swaps which of
    /// `Enter` and `Shift+Enter` sends and which inserts a newline.
    public var isMultiline: Bool
    /// `/vim-mode` (`defs.rs:754`). Off, the scrollback's bare-letter bindings
    /// (`j`, `k`, `h`, `l`, `e`, `y`, …) are suppressed and only the arrows,
    /// `Enter`, `Tab` and the `Ctrl` chords act — upstream's `lookup_with_mode`
    /// (`actions/mod.rs:397-430`).
    public var isVimMode: Bool
    /// `enter_steers` (`defs.rs:724`). On, `Enter` during a turn interjects the
    /// draft into the running turn instead of parking it in the queue.
    public var enterSteers: Bool
    /// `combine_queued_prompts` (`defs.rs:708`). On, a drain takes the whole
    /// queue as one prompt instead of running each entry as its own turn.
    public var combineQueuedPrompts: Bool

    public init(
        isMultiline: Bool = false,
        isVimMode: Bool = false,
        enterSteers: Bool = false,
        combineQueuedPrompts: Bool = false
    ) {
        self.isMultiline = isMultiline
        self.isVimMode = isVimMode
        self.enterSteers = enterSteers
        self.combineQueuedPrompts = combineQueuedPrompts
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
    public let focus: OpenGrokPagerFocusRegion
    public let modes: OpenGrokPagerInputModes

    public init(
        lifecycle: OpenGrokPagerInteractiveLifecycle,
        prompt: OpenGrokPagerInteractivePromptState,
        submittedPrompts: [String],
        completedTurnCount: Int,
        activeSessionID: String?,
        lastSessionID: String?,
        terminalRestored: Bool,
        focus: OpenGrokPagerFocusRegion = .prompt,
        modes: OpenGrokPagerInputModes = OpenGrokPagerInputModes()
    ) {
        self.lifecycle = lifecycle
        self.prompt = prompt
        self.submittedPrompts = submittedPrompts
        self.completedTurnCount = completedTurnCount
        self.activeSessionID = activeSessionID
        self.lastSessionID = lastSessionID
        self.terminalRestored = terminalRestored
        self.focus = focus
        self.modes = modes
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
    /// `/model` — the model picker, or, when `query` is non-nil, the typed
    /// selector the user supplied after the command name. A typed selector that
    /// names exactly one model switches without ever showing the overlay, which
    /// is why the query rides on the overlay request rather than being resolved
    /// here: the controller does not own the model catalog.
    case modelPicker(query: String?)
    /// `/toggle-mouse-reporting` — hand click-drag back to the terminal for
    /// native copy/paste, or take it back.
    case toggleMouseReporting
    /// `/workflows` — the background workflow-run overlay.
    case workflows
    /// `Ctrl+P` and `/help`'s upstream target (`OpenCommandPalette`) — every
    /// registered command as a filterable list.
    case commandPalette(rows: [OpenGrokPagerCommandSuggestion])
    /// `/history` — the prompt-history search modal. The controller owns the
    /// history, so it ships the rows rather than an intent to go find them.
    case promptHistory(entries: [String])
    /// `/queue` — the prompts waiting behind the running turn, newest last.
    case promptQueue(entries: [String])
    /// `/session-info` — the text modal `PagerOverlay.sessionInfo` has always
    /// built and nothing ever constructed.
    case sessionInfo
    /// `/context` — context-window usage as a text modal.
    case contextUsage
    /// `/copy [N] [file]` — copy the Nth-from-last assistant response to the
    /// clipboard, or to `filePath` when one is given. `index` is 1-based and
    /// counts backwards, matching upstream's `/copy 2` = "the one before last".
    case copyResponse(index: Int, filePath: String?)
    /// `/export [file]` — the whole conversation to a file, or to the clipboard
    /// when `filePath` is nil.
    case exportConversation(filePath: String?)
    /// `/find [text]` — search the scrollback.
    case scrollbackSearch(query: String?)
    /// `/home`, `/welcome` — put the welcome screen back.
    case welcomeScreen
    /// `Ctrl+.` — the shortcuts cheatsheet, which upstream keeps separate from
    /// `/help`'s command palette.
    case shortcutsHelp
    /// `/tutorial`, `/tour`, `/onboarding`.
    case tutorial
    /// `/gboom` — the hidden easter egg. Registered but never listed, matching
    /// upstream's `visible() == false`.
    case easterEgg
    /// `/settings`, `/privacy`, `F2` — the settings modal.
    ///
    /// `deepLinkKey` selects a specific row on open rather than landing at the
    /// top: `/privacy` is upstream's `OpenSettingsFocus{key: CODING_DATA_SHARING_KEY}`
    /// (`slash/commands/privacy.rs`), which is the same modal aimed at one row.
    case settings(deepLinkKey: String?)
    /// `/compact [instructions]` — rewrite the conversation into a summary.
    ///
    /// Only ever emitted from an idle composer or a queue drain; the controller
    /// refuses to dispatch it inline during a turn. See
    /// `PagerCommandDefinition.mutatesConversationHistory`.
    case compact(instructions: String?)
    /// `/theme [name]` — the theme picker, or the typed name when one is given.
    ///
    /// Same shape as `.modelPicker` and for the same reason: a name that
    /// resolves to exactly one theme applies without ever showing the picker,
    /// and the controller cannot resolve it because it does not own the
    /// catalog.
    case themePicker(query: String?)
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
    /// Keyboard focus moved between the composer and the scrollback. The
    /// renderer unfocuses the composer and starts painting a selected block.
    case focusChanged(OpenGrokPagerFocusRegion)
    /// An action on the selected block. Only ever emitted while the scrollback
    /// has focus.
    case scrollback(OpenGrokPagerScrollbackCommand)
    /// An application-level chord the controller cannot service itself.
    case global(OpenGrokPagerGlobalCommand)
    /// A composer mode flipped — `/multiline`, `/vim-mode`. Carried as a whole
    /// snapshot rather than a delta so a renderer that missed one still agrees.
    case modeChanged(OpenGrokPagerInputModes)
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
