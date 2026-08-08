import Foundation
import OpenGrokPagerRender
import OpenGrokTerminalCore

public typealias OpenGrokPagerInputEventStream = AsyncThrowingStream<InputEvent, Error>

/// One wall-clock animation tick from the controller's motion ticker.
///
/// `tick` is derived from elapsed wall time (`elapsed / tickInterval`), never
/// from an event counter — the whole point of the ticker is that a silent
/// operation keeps the spinner moving. `seconds` is the same clock in seconds
/// for the wall-time animations (welcome shimmer, finish flash); feed it to
/// `PagerMotionSnapshot.seconds` and stamp `PagerToolCard.finishedAt` from it.
public struct OpenGrokPagerAnimationFrame: Sendable, Equatable {
    public let tick: Int
    public let seconds: TimeInterval
    /// The demand this frame was scheduled under — `.slow` frames arrive at
    /// ~12 fps, `.fast` at the configured animation fps (default 30).
    public let demand: PagerTickDemand

    public init(tick: Int, seconds: TimeInterval, demand: PagerTickDemand) {
        self.tick = tick
        self.seconds = seconds
        self.demand = demand
    }
}

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
    /// `enter_steers` (`defaults.rs:627-660`). On, `Enter` during a turn sends
    /// now: it cancels the running turn and runs the draft next, ahead of queued
    /// follow-ups. Off, `Enter` queues at the tail.
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
    /// `/transcript` (alias `/log`) — the conversation transcript written to a
    /// temp file and opened in `$PAGER` over a suspended TUI
    /// (`slash/commands/transcript.rs`, `dispatch/transcript.rs:239-279`).
    /// An intent rather than a modal because only the render layer can park
    /// input and tear the terminal down around a child process.
    case transcriptPager
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
    /// `/rewind [n] [--mode=…] [--force]`, alias `/undo` — the rewind picker on
    /// a bare invocation, a dry-run preview with a prompt number, and the real
    /// restore only with `--force`. The whole argument string rides along
    /// because the rewind grammar is owned by the CLI layer, not here.
    case rewind(argument: String)
    /// `/jump` — pick a user turn and scroll the transcript to it. Upstream
    /// gates this to fullscreen (`jump.rs`, `ModeSupport::FullscreenOnly`);
    /// minimal mode scrolls with the terminal's own scrollback.
    case jumpPicker
    /// `/delete` — delete this session's stored transcript.
    ///
    /// `confirmed` is false for the command itself, which only raises the
    /// confirmation; the picker's own row sends the confirmed form. Deleting a
    /// transcript is not undoable, so it never happens on one keystroke.
    case deleteSession(confirmed: Bool)
    /// `/remember [text]` — write a note to workspace memory.
    case remember(text: String)
    /// `/recall <query>` — search workspace memory.
    case recall(query: String)
    /// `/flush <notes>` — append to today's session memory log.
    case flush(text: String)
    /// `/goal [objective|status|pause|resume|clear]` — the goal tracker.
    case goal(argument: String)
    /// Bare `/plan` — arm plan mode (upstream `Action::SetPlanMode(On)`,
    /// `slash/commands/plan.rs:45-49`, dispatched by `set_plan_mode`,
    /// `dispatch/modes.rs:122-195`). Idempotent at the live seam: an
    /// already-armed session gets the toast without a second arm.
    case planModeOn
    /// `/plan <description>` — the mode-switch half of upstream's
    /// `Action::EnterPlanMode` (`plan.rs:50-52`, `dispatch/modes.rs:37-120`).
    /// Carries no description on purpose: the controller emits this intent
    /// and AWAITS its handling before enqueueing the description as a normal
    /// prompt, which is how the port keeps upstream's `SetModeThenPrompt`
    /// ordering — the arm must land before the prompt's turn starts.
    case enterPlanMode
    /// `/view-plan` — upstream `Action::ShowPlan` (`view_plan.rs:30-32`):
    /// a pending plan approval reopens its sheet, else the saved plan opens
    /// in a preview, else the "No plan written yet." toast
    /// (`dispatch/modes.rs:16-25`, `agent_view/plan.rs:125-146`).
    case showPlan
    /// `/resume` — the stored-session picker (upstream
    /// `Action::ShowSessionPicker`, `slash/commands/resume.rs:21-23`). The
    /// session store is a CLI-layer concern, so the intent carries no rows.
    case sessionPicker
    /// `/usage`, alias `/cost` — session token usage as a text modal
    /// (upstream `Action::ShowUsage`, `slash/commands/usage.rs:59`). The
    /// billing-surface arm (`manage`) is not ported; see the controller.
    case usage
    /// `/mcps` — per-server MCP connection status (upstream opens the
    /// extensions modal's MCP tab, `slash/commands/mcps.rs:19-24`; this port
    /// renders the same facts as a read-only list).
    case mcpServers
    /// `/effort [level]` — reasoning effort on the *current* model (upstream
    /// `slash/commands/effort.rs:57-92`, a thin wrapper over
    /// `Action::SwitchModel` with the session's model id). Same shape as
    /// `.modelPicker`: the controller cannot resolve the level because it
    /// does not own the model catalog.
    case reasoningEffort(query: String?)
    /// `/rename <title>`, alias `/title` — retitle the current session
    /// (upstream `Action::RenameSession`, `slash/commands/rename.rs:42-53`).
    /// The empty-title refusal happens in the controller, so `title` here is
    /// always non-empty.
    case renameSession(title: String)
    /// Bare `/login` — the provider chooser (upstream
    /// `Action::OpenLoginProviderPicker`, `dispatch/auth.rs:26-66`). The rows
    /// and alias table live in `PagerLoginProviders`; only the render layer
    /// can add the live API-key statuses upstream's modal shows.
    case loginProviderPicker
    /// `/login xai` (upstream `Action::Login`, `dispatch/auth.rs:668-706`).
    /// The port has no xAI browser OAuth wired at the live seam; the renderer
    /// answers with the honest CLI route rather than faking a flow.
    case loginXAI
    /// `/login codex` (upstream `Action::LoginCodex`,
    /// `dispatch/auth.rs:111-127`) — browser OAuth into the isolated Codex
    /// store, run without blocking the turn loop.
    case loginCodex
    /// `/logout` / `/logout codex` (upstream `Action::Logout` /
    /// `Action::LogoutCodex`, `slash/commands/logout.rs:38-45`). Credential
    /// removal happens in the render layer, which owns the auth-store home.
    case logout(account: OpenGrokPagerAuthAccount)
    /// `/fork [--worktree|--no-worktree] [directive]` — upstream
    /// `Action::Fork(ForkArgs)` (`slash/commands/fork.rs:130-135`). The
    /// controller owns the verbatim grammar (`PagerForkArguments.parse`);
    /// the render layer owns the session store, so the parsed payload rides
    /// the intent. Upstream's dispatch spawns a peer agent tab in the
    /// multi-agent dashboard; this single-session port's live backing is
    /// the on-disk session fork, so the renderer decides which arms it can
    /// honestly serve.
    case fork(worktreeOverride: Bool?, directive: String?)
    /// `/tasks` — upstream `Action::ShowTasks` (`slash/commands/tasks.rs:36`),
    /// dispatched by `dispatch_show_tasks` (`app/dispatch/status.rs:362-370`)
    /// as a read-only system block. The task sources (workflow registry,
    /// subagent host, shell background tasks) live in the render layer.
    case showTasks
    /// Bare `/docs` (and its how-to-list argument forms) — upstream
    /// `Action::OpenHowtoGuides` (`slash/commands/docs.rs:72-74`), dispatched
    /// by `dispatch_open_howto_guides` (`dispatch/settings/ui.rs:248-262`)
    /// as the "How-to Guides" DocPicker. The intent carries no rows: the
    /// corpus is `PagerDocs`, which the render layer reads directly.
    case howtoGuides
    /// `/docs web` — upstream `Action::OpenUrl(BUILD_DOCS_URL)`
    /// (`docs.rs:75-77`, dispatched at `dispatch/router.rs:1208-1223`).
    /// The URL rides the intent exactly as it rides upstream's action; the
    /// browser opener is a render-layer seam.
    case openURL(String)
    /// `/docs <title>` — upstream `Action::ShowReleaseNotes{title, content}`
    /// (`docs.rs:78-82`), the reused fullscreen doc viewer. Content rides
    /// along because the controller resolved the title (`find_doc`) and the
    /// viewer needs nothing else.
    case showDocument(title: String, content: String)
    case dismissAll
}

/// Which credential store `/logout` targets. Two stores, never one file:
/// `auth.json` (xAI and provider API keys) and the isolated `codex-auth.json`.
public enum OpenGrokPagerAuthAccount: String, Sendable, Equatable, Hashable {
    case xai
    case codex
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
    /// Handled, and the controller should now run this slash command as if the
    /// user had typed and submitted it.
    ///
    /// This exists for the command palette, whose rows *are* commands. Upstream
    /// resolves a palette row to `Action::SendSlashCommandPreservingDraft`
    /// (`app/modals.rs:932`) — it runs the command and leaves the composer
    /// draft alone. The renderer cannot reach the command vocabulary (it lives
    /// in the controller) and the event flow is otherwise one-way, so the
    /// routing value carries the command back up. Nothing here touches the
    /// composer, which is what "preserving draft" means.
    case runCommand(String)
}

public enum OpenGrokPagerInteractiveEvent: Sendable, Equatable {
    case lifecycle(OpenGrokPagerInteractiveLifecycle)
    case promptChanged(OpenGrokPagerInteractivePromptState)
    case turnStarted(OpenGrokPagerRequest)
    case session(OpenGrokPagerEvent)
    case turnFinished(OpenGrokPagerRuntimeResult)
    /// The live runtime committed a fresh session and the renderer must clear
    /// its transcript without deleting the previous session's record.
    case sessionReplaced(sessionID: String)
    /// The live runtime swapped the conversation to a stored session
    /// (`/resume`). Distinct from `.sessionReplaced`: the renderer paints the
    /// restored transcript instead of the welcome screen.
    case sessionResumed(sessionID: String)
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
    /// A turn failed but the session stays open for the next prompt — the
    /// renderer paints upstream's `SessionEvent::TurnFailed` marker
    /// (`scrollback/blocks/session_event.rs:172`). Distinct from `.failed`,
    /// which ends the whole run: a provider error is a property of one turn,
    /// not of the session (`dispatch/prompt.rs:1399-1402`).
    case turnFailed(message: String)
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

    /// A wall-clock animation tick. Fired by the controller's motion ticker
    /// while something on screen demands frames (upstream's `schedule_tick`,
    /// `event_loop.rs:3172-3189`); never fired while the demand is `.none`,
    /// which is why an idle screen costs no wakeups.
    ///
    /// A live renderer stores `frame.tick`/`frame.seconds` into its
    /// `PagerMotionSnapshot` and repaints — through a coalescing path
    /// (`PagerTerminalRenderer.requestFrame`) so tick-rate requests fold into
    /// the min-draw cadence. This is a protocol extension default (no-op)
    /// rather than an event enum case so existing adapters keep compiling
    /// and simply stay still; the cost is that this seam is easy to forget —
    /// a renderer that never implements it silently keeps the frozen UI.
    func renderAnimationTick(_ frame: OpenGrokPagerAnimationFrame) async throws
}

extension OpenGrokPagerInteractiveRenderAdapter {
    public func resize(to size: TerminalSize) async throws {
        _ = size
    }

    public func handleInput(_ event: InputEvent) async throws -> OpenGrokPagerInputRouting {
        _ = event
        return .notHandled
    }

    public func renderAnimationTick(_ frame: OpenGrokPagerAnimationFrame) async throws {
        _ = frame
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
