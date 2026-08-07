import Dispatch
import Foundation
import OpenGrokInterjection
import OpenGrokPagerCommandUI
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokPromptQueue
import OpenGrokTerminalCore

public actor OpenGrokPagerInteractiveController: OpenGrokPagerInteractiveFrontend {
    public typealias CustomCommandHandler = @Sendable (
        PagerCommandInvocation
    ) async throws -> String?
    public typealias LocalCommandHandler = @Sendable (
        PagerCommandInvocation
    ) async throws -> String?

    private enum Control: Sendable {
        /// A user Esc or Ctrl+C, fast-pathed ahead of queued input so it lands
        /// promptly during a busy turn.
        case interrupt(isEscape: Bool)
        /// An external `cancel()` — unlike an interrupt this always ends the run.
        case cancel
        case eof
        case shutdown
        /// A slash command the renderer resolved on the controller's behalf —
        /// today, a command-palette row. It travels as a control signal rather
        /// than as input so it lands in the same dispatch the composer's own
        /// submit uses, including the mid-turn deferral for history-rewriting
        /// commands.
        case command(String)
    }

    /// What an Esc or Ctrl+C resolved to.
    private enum InterruptOutcome: Sendable {
        /// Handled inside the prompt; redraw and keep going.
        case consumed
        case cancelTurn
        case quit
    }

    private enum PromptAction: Sendable {
        case changed
        case submit
        /// A bare `Esc`. What it means depends on whether a turn is running and
        /// whether the composer holds a draft — see `resolveEscape`.
        case escape
        /// `Ctrl+C`.
        case interrupt
        /// `Ctrl+D`.
        case eof
        case resize(TerminalSize)
        case historyPrevious
        case historyNext
        case completionMove(Int)
        case completionAccept
        case viewport(OpenGrokPagerViewportCommand)
        /// `Tab` on a closed dropdown — hand the keyboard to the scrollback.
        case focusScrollback
        /// `Ctrl+M` in the composer (`defaults.rs:702`).
        case toggleMultiline
        /// An application chord that is not the composer's to service.
        case global(OpenGrokPagerGlobalCommand)
        case ignored
    }

    private enum TurnOutcome: Sendable {
        case finished(OpenGrokPagerRuntimeResult)
        case eof
        /// The user cancelled the turn; the run continues at the prompt.
        case turnCancelled
        /// A bare `Enter` on an empty composer force-sent the head of the
        /// queue. The turn ends the same way a cancel does, but the queue keeps
        /// draining instead of parking at the composer.
        case turnPreempted
        /// An external cancel or a fatal condition; the run ends.
        case cancelled
        case shutdown
    }

    /// What the run loop should do once a turn has been accounted for.
    private enum TurnDisposition: Sendable {
        /// Back to the composer, leaving anything queued queued.
        case keepEditing
        /// Start the next queued prompt immediately.
        case drainNext
        case end(OpenGrokPagerInteractiveLifecycle)
    }

    private enum StreamRead<Element: Sendable>: Sendable {
        case element(Element)
        case end
        case failure(String)
        case cancelled
    }

    private enum Signal: Sendable {
        /// `generation` is the turn that owns the event. A preempted turn's
        /// dying session races its `.cancelled` into the mailbox after the
        /// loop has already decided `.turnPreempted`; the send-now drain goes
        /// straight into the next turn without passing the idle loop (which
        /// swallows stale session signals), so an untagged event would be
        /// adopted by the next turn, reported as that turn's cancellation,
        /// and end the whole run with the queue discarded.
        case session(generation: UInt64, StreamRead<OpenGrokPagerEvent>)
        case input(StreamRead<InputEvent>)
        case control(Control)
    }

    private struct PromptEditor: Sendable {
        private var characters: [Character]
        private(set) var cursor: Int
        /// Open slash-command dropdown. When non-empty, `↑`/`↓` move the
        /// selection instead of recalling history, matching the reference's
        /// dropdown intercept ahead of the history step.
        var completions: [OpenGrokPagerCommandSuggestion] = []
        var selectedCompletion: Int?
        /// Esc closed the dropdown (`slash_close`, `prompt.rs:229-233`); it
        /// stays closed until the text actually changes. Without the latch,
        /// the refresh that follows any `.changed` action — cursor moves
        /// included — would reopen the menu the same keystroke that closed it.
        var completionsDismissed = false
        /// Set while history browsing is open. Without it, `Down` would stop
        /// browsing the moment `Up` filled the composer with a recalled prompt.
        var isBrowsingHistory = false
        /// Mirrors `OpenGrokPagerInputModes.isMultiline`. Held here because it
        /// changes what `Enter` means, which only the editor can decide.
        var isMultiline = false

        init(text: String) {
            characters = Array(text)
            cursor = characters.count
        }

        var text: String { String(characters) }
        var isEmpty: Bool { characters.isEmpty }

        func state(
            pendingKey: String? = nil,
            pendingLabel: String? = nil
        ) -> OpenGrokPagerInteractivePromptState {
            OpenGrokPagerInteractivePromptState(
                text: text,
                cursorOffset: cursor,
                completions: completions,
                selectedCompletion: selectedCompletion,
                pendingConfirmationKey: pendingKey,
                pendingConfirmationLabel: pendingLabel
            )
        }

        mutating func apply(_ event: InputEvent) -> PromptAction {
            switch event {
            case .paste(let value):
                insert(Array(value))
                return value.isEmpty ? .ignored : .changed
            case .key(let key):
                return apply(key)
            case .resize(let size):
                return .resize(size)
            case .mouse, .focusGained, .focusLost:
                return .ignored
            }
        }

        mutating func reset() {
            characters.removeAll(keepingCapacity: true)
            cursor = 0
            completions = []
            selectedCompletion = nil
            completionsDismissed = false
        }

        mutating func replace(with value: String) {
            characters = Array(value)
            cursor = characters.count
            completionsDismissed = false
        }

        /// Close the dropdown, latching it shut until the text changes.
        /// Returns whether there was anything to close, so the Esc handler
        /// can fall through to the cancel/clear ladder when there was not.
        mutating func dismissCompletions() -> Bool {
            guard !completions.isEmpty else { return false }
            completions = []
            selectedCompletion = nil
            completionsDismissed = true
            return true
        }

        private mutating func apply(_ event: KeyEvent) -> PromptAction {
            if let control = controlAction(for: event) {
                return control
            }
            if let global = Self.globalAction(for: event) {
                return .global(global)
            }

            switch event.key {
            case .enter:
                // Enter submits and Shift+Enter (or Alt+Enter, which is what
                // terminals without the Kitty protocol can actually report)
                // inserts a newline — multiline mode swaps the two, which is
                // the whole of `/multiline` upstream.
                return resolveEnter(modifiers: event.modifiers)
            case .escape:
                // Unreachable in a live run: the input pump classifies a bare
                // Esc as a control signal before the editor sees the event.
                // The dropdown intercept therefore lives in
                // `handleInterrupt`, not here — an editor-side close was
                // landed once and silently did nothing.
                return .escape
            case .tab:
                // Tab accepts the highlighted completion; with the dropdown
                // closed it is the focus switch (`defaults.rs:488`). Letting
                // Enter accept instead would make a fully typed command name
                // need two presses, since its own row stays in the menu.
                return completions.isEmpty ? .focusScrollback : .completionAccept
            case .backTab:
                return .global(.cyclePermissionMode)
            case .up:
                if !completions.isEmpty { return .completionMove(-1) }
                // `Up` recalls history only on an empty composer
                // (`app/agent_view/prompt.rs:465-486`); with a draft it is a
                // scrollback movement instead.
                return isEmpty || isBrowsingHistory ? .historyPrevious : .viewport(.lineUp)
            case .down:
                if !completions.isEmpty { return .completionMove(1) }
                return isEmpty || isBrowsingHistory ? .historyNext : .viewport(.lineDown)
            case .pageUp:
                // With the dropdown open the paging keys page the menu
                // (`prompt.rs:187-198`), one visible window per press.
                if !completions.isEmpty {
                    return .completionMove(-PagerLayoutMetrics.maxDropdownRows)
                }
                return .viewport(.pageUp)
            case .pageDown:
                if !completions.isEmpty {
                    return .completionMove(PagerLayoutMetrics.maxDropdownRows)
                }
                return .viewport(.pageDown)
            case .backspace:
                guard cursor > 0 else { return .ignored }
                characters.remove(at: cursor - 1)
                cursor -= 1
                completionsDismissed = false
                return .changed
            case .delete:
                guard cursor < characters.count else { return .ignored }
                characters.remove(at: cursor)
                completionsDismissed = false
                return .changed
            case .left:
                guard cursor > 0 else { return .ignored }
                cursor -= 1
                return .changed
            case .right:
                guard cursor < characters.count else { return .ignored }
                cursor += 1
                return .changed
            case .home:
                // With a draft, Home is a line-editing key; on an empty
                // composer it jumps the transcript to the top.
                guard !isEmpty else { return .viewport(.top) }
                guard cursor != 0 else { return .ignored }
                cursor = 0
                return .changed
            case .end:
                guard !isEmpty else { return .viewport(.bottom) }
                guard cursor != characters.count else { return .ignored }
                cursor = characters.count
                return .changed
            case .char(let character):
                if character == "\r" || character == "\n" {
                    return resolveEnter(modifiers: event.modifiers)
                }
                if character == "\u{3}" {
                    return .interrupt
                }
                if character == "\u{4}" {
                    return .eof
                }
                guard !event.modifiers.contains(.control),
                      !event.modifiers.contains(.meta),
                      !event.modifiers.contains(.alt)
                else { return .ignored }
                insert([event.character ?? character])
                return .changed
            case .insert, .f, .null:
                return .ignored
            }
        }

        /// What `Enter` means right now.
        ///
        /// Three inputs decide it: the multiline mode, whether the report
        /// carried Shift or Alt, and whether the draft ends in a backslash.
        /// The backslash is upstream's rescue for terminals that cannot
        /// distinguish `Shift+Enter` from `Enter` at all
        /// (`views/prompt_widget/mod.rs:2137-2142`) — it eats the backslash and
        /// continues the line, so multiline stays reachable everywhere.
        private mutating func resolveEnter(modifiers: KeyModifiers) -> PromptAction {
            let wantsNewline = modifiers.contains(.shift) || modifiers.contains(.alt)
            if isMultiline != wantsNewline {
                insert(["\n"])
                return .changed
            }
            // This press would have sent. A line ending in a backslash says
            // "not yet" — the rescue only applies here, on the send path, and
            // only with the cursor at the end, which is where it is when
            // someone types a line and reaches for Enter.
            guard characters.last == "\\", cursor == characters.count else { return .submit }
            characters.removeLast()
            cursor = characters.count
            insert(["\n"])
            return .changed
        }

        /// Application chords that mean the same thing wherever they land.
        ///
        /// Only the ones this port routes to a real surface are bound. The
        /// unbound half of upstream's `AgentScreen` table — `Ctrl+T` todos,
        /// `Ctrl+G` tasks, `Ctrl+B` background, `Ctrl+S` sessions, `Ctrl+L`
        /// extensions, `Ctrl+\` dashboard — stays inert on purpose, for the
        /// same reason the dropdown lists no no-op command.
        static func globalAction(for event: KeyEvent) -> OpenGrokPagerGlobalCommand? {
            // `F2` carries no modifier, so it is resolved ahead of the Ctrl
            // gate (`defaults.rs:839`). The bare form only: a modified `F2` is
            // a different chord and must not silently open settings. The
            // `Ctrl+,` / `Cmd+,` alternates are left unbound because most
            // terminals cannot report either.
            if case .f(2) = event.key, event.modifiers.isEmpty { return .openSettings }
            guard event.modifiers.contains(.control) else { return nil }
            let character: Character?
            switch event.key {
            case .char(let value): character = value
            default: character = event.character
            }
            switch character?.lowercased() {
            // `Ctrl+.` primary with `Ctrl+X` as the alternate, both bound
            // because `ctrl_dot_unreliable()` terminals swap them
            // (`defaults.rs:801-823`).
            case ".", "x": return .shortcutsHelp
            // `Ctrl+;` primary, `Ctrl+'` alternate (`defaults.rs:551-578`).
            case ";", "'": return .toggleQueue
            // Upstream's send-now chord is Ctrl+Enter with Ctrl+I, Ctrl+O, or
            // Ctrl+L alternates (`defaults.rs:635-651`). Ctrl+Enter is the same
            // CR byte as Enter here, Ctrl+I is Tab, Ctrl+O already toggles
            // always-approve, and Ctrl+L stays reserved for extensions. Send-now
            // is therefore reachable through `enter_steers` or an empty-composer
            // force-send. The cost is no one-keystroke send-now for a full
            // composer while `enter_steers` is off.
            case "o": return .toggleAlwaysApprove
            default: return nil
            }
        }

        private func controlAction(for event: KeyEvent) -> PromptAction? {
            guard event.modifiers.contains(.control) else { return nil }
            let character: Character?
            switch event.key {
            case .char(let value):
                character = value
            default:
                character = event.character
            }
            switch character?.lowercased() {
            case "c": return .interrupt
            case "d": return .eof
            case "u": return .viewport(.halfPageUp)
            case "j": return .viewport(.lineDown)
            case "k": return .viewport(.lineUp)
            // Not a mis-assignment against the reference, as it first looks:
            // upstream hard-codes the same dropdown intercept ahead of the
            // action registry (`app/agent_view/prompt.rs:212-221`), so
            // `Ctrl+P`/`Ctrl+N` move the menu while one is open and otherwise
            // fall through to `CommandPalette` (`defaults.rs:786`) and
            // `NewSession` (`:748`). That fall-through is what was missing.
            case "p": return completions.isEmpty ? .global(.commandPalette) : .completionMove(-1)
            case "n": return completions.isEmpty ? .global(.newSession) : .completionMove(1)
            // `Ctrl+M` toggles multiline in the prompt and opens the model
            // picker outside it. Upstream registers both in different `When`
            // contexts and resolves by focus (`defaults.rs:702` and `:824`);
            // this branch is the prompt half.
            case "m": return .toggleMultiline
            default: return nil
            }
        }

        private mutating func insert(_ values: [Character]) {
            guard !values.isEmpty else { return }
            characters.insert(contentsOf: values, at: cursor)
            cursor += values.count
            // New text lifts the Esc dismissal: typing after closing the
            // dropdown is a fresh query.
            completionsDismissed = false
        }
    }

    private actor StreamChannel<Element: Sendable> {
        private var queued: [StreamRead<Element>] = []
        private var waiter: (UUID, CheckedContinuation<StreamRead<Element>, Never>)?
        private var isFinished = false

        func send(_ value: StreamRead<Element>) {
            guard !isFinished else { return }
            if let waiter {
                self.waiter = nil
                waiter.1.resume(returning: value)
            } else {
                queued.append(value)
            }
        }

        func next() async -> StreamRead<Element> {
            if !queued.isEmpty { return queued.removeFirst() }
            if isFinished { return .end }
            let waiterID = UUID()
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if !queued.isEmpty {
                        continuation.resume(returning: queued.removeFirst())
                    } else if isFinished {
                        continuation.resume(returning: .end)
                    } else {
                        waiter = (waiterID, continuation)
                    }
                }
            }, onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            })
        }

        func finish() {
            guard !isFinished else { return }
            isFinished = true
            waiter?.1.resume(returning: .end)
            waiter = nil
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard waiter?.0 == waiterID, let waiter else { return }
            self.waiter = nil
            waiter.1.resume(returning: .cancelled)
        }
    }

    private actor ThrowingStreamReader<Element: Sendable> {
        private let channel: StreamChannel<Element>
        private let producer: Task<Void, Never>

        init(_ stream: AsyncThrowingStream<Element, Error>) {
            let channel = StreamChannel<Element>()
            self.channel = channel
            self.producer = Task {
                do {
                    for try await element in stream {
                        await channel.send(.element(element))
                    }
                    await channel.send(.end)
                } catch is CancellationError {
                    await channel.send(.cancelled)
                } catch {
                    await channel.send(.failure(String(describing: error)))
                }
                await channel.finish()
            }
        }

        func next() async -> StreamRead<Element> {
            await channel.next()
        }

        func cancel() async {
            producer.cancel()
            await channel.finish()
        }
    }

    private actor SignalMailbox {
        private var queued: [Signal] = []
        private var waiter: (UUID, CheckedContinuation<Signal?, Never>)?
        private var isClosed = false

        func send(_ signal: Signal, priority: Bool = false) {
            guard !isClosed else { return }
            if let waiter {
                self.waiter = nil
                waiter.1.resume(returning: signal)
            } else if priority {
                queued.insert(signal, at: 0)
            } else {
                queued.append(signal)
            }
        }

        func next() async -> Signal? {
            if let signal = dequeue() { return signal }
            if isClosed { return nil }
            let waiterID = UUID()
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if let signal = dequeue() {
                        continuation.resume(returning: signal)
                    } else if isClosed {
                        continuation.resume(returning: nil)
                    } else {
                        waiter = (waiterID, continuation)
                    }
                }
            }, onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            })
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            waiter?.1.resume(returning: nil)
            waiter = nil
            queued.removeAll(keepingCapacity: false)
        }

        private func dequeue() -> Signal? {
            if let index = queued.firstIndex(where: { signal in
                if case .control = signal { return true }
                return false
            }) {
                return queued.remove(at: index)
            }
            if let index = queued.firstIndex(where: { signal in
                if case .session = signal { return true }
                return false
            }) {
                return queued.remove(at: index)
            }
            guard !queued.isEmpty else { return nil }
            return queued.removeFirst()
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard waiter?.0 == waiterID, let waiter else { return }
            self.waiter = nil
            waiter.1.resume(returning: nil)
        }
    }

    private actor InputPumpGate {
        private var isAllowed = true
        private var isClosed = false
        private var waiter: (UUID, CheckedContinuation<Bool, Never>)?

        func pause() {
            isAllowed = false
        }

        func resume() {
            guard !isClosed else { return }
            isAllowed = true
            waiter?.1.resume(returning: true)
            waiter = nil
        }

        func waitUntilAllowed() async -> Bool {
            if isClosed { return false }
            if isAllowed { return true }
            let waiterID = UUID()
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if isClosed {
                        continuation.resume(returning: false)
                    } else if isAllowed {
                        continuation.resume(returning: true)
                    } else {
                        waiter = (waiterID, continuation)
                    }
                }
            }, onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            })
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            waiter?.1.resume(returning: false)
            waiter = nil
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard waiter?.0 == waiterID, let waiter else { return }
            self.waiter = nil
            waiter.1.resume(returning: false)
        }
    }

    private let input: AsyncThrowingStream<InputEvent, Error>
    private let runtime: any OpenGrokPagerRuntimeAdapter
    private let renderer: any OpenGrokPagerInteractiveRenderAdapter
    private let output: any OpenGrokPagerInteractiveOutputAdapter

    private var lifecycle: OpenGrokPagerInteractiveLifecycle = .idle
    private var editor = PromptEditor(text: "")
    private var submittedPrompts: [String] = []
    private var completedTurnCount = 0
    private var currentRequest: OpenGrokPagerRequest?
    private var activeSessionID: String?
    private var lastSessionID: String?
    private var terminalRestored = false
    private var running = false
    private var rendererBegan = false
    private var shutdownRequested = false
    private var activeSession: (any OpenGrokPagerSessionAdapter)?
    private var activeSessionCancelled = false
    private var activeSessionClosed = false
    /// Monotonic turn counter stamped onto `.session` signals; see `Signal`.
    private var turnGeneration: UInt64 = 0
    private var signalMailbox: SignalMailbox?
    private var inputPumpGate: InputPumpGate?
    private var inputPump: Task<Void, Never>?

    /// Every prompt the user submits goes through the queue, whether the shell
    /// was idle or busy when they pressed Enter. An idle submit enqueues and
    /// drains in the same breath, so there is a single ordering authority and
    /// the drain path is not a second, subtly different code path.
    private let promptQueue = PromptQueue(sessionId: "interactive")
    private var nextPromptSequence = 0

    /// Prompt history, oldest first. `historyIndex` is the browse cursor;
    /// `historySavedDraft` is the composer text stashed when browsing opened,
    /// restored when the user pages back past the newest entry.
    private var history: [String] = []
    private var historyIndex: Int?
    private var historySavedDraft: String?

    /// An armed double-press confirmation and the instant it expires.
    private var pendingConfirmation: (key: String, label: String, deadline: Date)?

    /// What the render layer last reported as moving on screen. Merged with
    /// the controller's own turn state in `currentMotionDemand()`; the
    /// controller cannot see a visible running block or the welcome logo, and
    /// the renderer cannot see a turn that has produced no events yet, so
    /// neither view alone is the truth.
    private var externalMotionState = PagerMotionState()
    /// `[animation].fps` (`appearance/config.rs:371-397`), clamped 1...60.
    private var motionFPS = PagerMotion.defaultFPS
    /// The motion epoch, as monotonic uptime nanoseconds. The animation tick
    /// is `elapsed / tickInterval` — derived from this wall clock, never from
    /// an event counter, so a silent turn cannot freeze the spinner.
    private var motionEpochNanos: UInt64?
    /// The demand-driven ticker (`schedule_tick`, `event_loop.rs:3172-3189`).
    /// `nil` exactly when no tick is armed, which is the idle case and the
    /// reason a still screen costs no wakeups.
    private var motionTicker: Task<Void, Never>?

    /// Slash-command recency. Defaults to the in-memory store, exactly like
    /// upstream's default controllers (`mru.rs:9-10`); the live composition
    /// injects the disk-backed store via `setSlashMru`.
    private var slashMru = PagerSlashMru()

    /// Which region owns the keyboard. `Tab` moves it; nothing else does.
    private var focus: OpenGrokPagerFocusRegion = .prompt
    private var modes = OpenGrokPagerInputModes()

    /// Side questions buffered by `/btw`. Drained into the next prompt so a
    /// follow-up that arrives after the sampler has committed to the turn is
    /// never silently dropped. Enter-steers does not write here: it is
    /// cancel-and-send per `defaults.rs:630-632`.
    private let interjections = EventQueue<KindedInterjection<String>>()

    private let commands: PagerCommandRegistry
    private let paletteRows: [OpenGrokPagerCommandSuggestion]
    private let customCommandNames: Set<String>
    private let customCommandHandler: CustomCommandHandler?
    private let localCommandNames: Set<String>
    private let localCommandHandler: LocalCommandHandler?

    /// Completions for the *arguments* of a command whose name is already
    /// typed, as `(command, argumentQuery) -> rows`.
    ///
    /// The controller owns the command vocabulary but none of the vocabularies
    /// the arguments come from — it cannot name a model any more than the
    /// render layer can. So the host supplies this and does its own matching;
    /// the controller only decides *when* the prompt is in the argument phase.
    /// Upstream's equivalent is `SlashCommand::suggest_args`
    /// (`slash/command.rs`), which `/model` implements by listing the catalog.
    private var argumentSuggestions: (
        @Sendable (String, String) -> [OpenGrokPagerCommandSuggestion]
    )?

    public init(
        input: AsyncThrowingStream<InputEvent, Error>,
        runtime: any OpenGrokPagerRuntimeAdapter,
        renderer: any OpenGrokPagerInteractiveRenderAdapter,
        output: any OpenGrokPagerInteractiveOutputAdapter,
        customCommands: [OpenGrokPagerCommandRegistration] = [],
        customCommandHandler: CustomCommandHandler? = nil,
        localCommands: [OpenGrokPagerCommandRegistration] = [],
        localCommandHandler: LocalCommandHandler? = nil,
        workflowsEnabled: Bool = true
    ) {
        self.input = input
        self.runtime = runtime
        self.renderer = renderer
        self.output = output
        let definitions = customCommands.map { registration in
            PagerCommandDefinition(
                name: registration.name,
                aliases: registration.aliases,
                summary: registration.summary,
                usage: registration.usage
            )
        }
        let builtinCommands = Self.builtinCommands.filter { workflowsEnabled || $0.name != "workflows" }
        self.commands = PagerCommandRegistry(
            commands: builtinCommands + definitions + localCommands.map { registration in
                PagerCommandDefinition(
                    name: registration.name,
                    aliases: registration.aliases,
                    summary: registration.summary,
                    usage: registration.usage
                )
            }
        )
        self.paletteRows = builtinCommands
            .filter { !$0.isHidden }
            .map { command in
                OpenGrokPagerCommandSuggestion(
                    name: "/\(command.name)",
                    summary: command.summary,
                    insertText: "/\(command.name)"
                )
            }
        self.customCommandNames = Set(definitions.map(\.name))
        self.customCommandHandler = customCommandHandler
        self.localCommandNames = Set(localCommands.map { PagerCommandDefinition.normalize($0.name) })
        self.localCommandHandler = localCommandHandler
    }

    public init(
        input: AsyncStream<InputEvent>,
        runtime: any OpenGrokPagerRuntimeAdapter,
        renderer: any OpenGrokPagerInteractiveRenderAdapter,
        output: any OpenGrokPagerInteractiveOutputAdapter,
        customCommands: [OpenGrokPagerCommandRegistration] = [],
        customCommandHandler: CustomCommandHandler? = nil,
        localCommands: [OpenGrokPagerCommandRegistration] = [],
        localCommandHandler: LocalCommandHandler? = nil,
        workflowsEnabled: Bool = true
    ) {
        self.init(
            input: Self.makeThrowingStream(from: input),
            runtime: runtime,
            renderer: renderer,
            output: output,
            customCommands: customCommands,
            customCommandHandler: customCommandHandler,
            localCommands: localCommands,
            localCommandHandler: localCommandHandler,
            workflowsEnabled: workflowsEnabled
        )
    }

    /// Install the argument-completion source. Call before `run`.
    public func setArgumentSuggestions(
        _ provider: (@Sendable (String, String) -> [OpenGrokPagerCommandSuggestion])?
    ) {
        argumentSuggestions = provider
    }

    /// Report what the render layer knows is in motion — visible running
    /// blocks, the welcome logo, background-task chips, and whether the
    /// terminal can animate at all. Callable at any time, including mid-run;
    /// a rising demand arms the ticker, a falling one lets it park itself.
    public func setMotionState(_ state: PagerMotionState) {
        externalMotionState = state
        armMotionTickerIfNeeded()
    }

    /// Set the animation tick rate (`[animation].fps`). Call before `run`;
    /// the tick derivation divides wall time by this, so changing it mid-run
    /// would make the tick counter jump.
    public func setMotionFPS(_ fps: Int) {
        motionFPS = min(max(fps, PagerMotion.minimumFPS), PagerMotion.maximumFPS)
    }

    /// Install the slash-command MRU store. Call before `run`. Without this
    /// the controller uses an isolated in-memory store — recency boosts work
    /// within the session but do not persist, mirroring upstream's default
    /// controllers (`mru.rs:9-10`).
    public func setSlashMru(_ mru: PagerSlashMru) {
        slashMru = mru
    }

    public func state() -> OpenGrokPagerInteractiveState {
        OpenGrokPagerInteractiveState(
            lifecycle: lifecycle,
            prompt: promptState(),
            submittedPrompts: submittedPrompts,
            completedTurnCount: completedTurnCount,
            activeSessionID: activeSessionID,
            lastSessionID: lastSessionID,
            terminalRestored: terminalRestored,
            focus: focus,
            modes: modes
        )
    }

    /// Replace the runtime-toggleable mode snapshot before or during `run`.
    ///
    /// A mid-run call is safe because the controller is an actor and the input
    /// loop reads `modes` at await points. The cost is that a mode flip lands
    /// between keystrokes, never midway through one keystroke.
    public func setInputModes(_ newModes: OpenGrokPagerInputModes) {
        modes = newModes
        editor.isMultiline = newModes.isMultiline
    }

    public func run(_ request: OpenGrokPagerRequest) async throws -> OpenGrokPagerInteractiveResult {
        try await run(initialSession: nil, request: request)
    }

    public func run(
        initialSession: any OpenGrokPagerSessionAdapter,
        request: OpenGrokPagerRequest
    ) async throws -> OpenGrokPagerInteractiveResult {
        try await run(initialSession: Optional(initialSession), request: request)
    }

    public func cancel() async {
        guard running else { return }
        lifecycle = .cancelling
        await signalMailbox?.send(.control(.cancel), priority: true)
        await cancelActiveSession()
    }

    public func shutdown() async {
        shutdownRequested = true
        guard running else {
            lifecycle = .shutdown
            return
        }
        lifecycle = .cancelling
        await signalMailbox?.send(.control(.shutdown), priority: true)
        await cancelActiveSession()
    }

    private func run(
        initialSession: (any OpenGrokPagerSessionAdapter)?,
        request: OpenGrokPagerRequest
    ) async throws -> OpenGrokPagerInteractiveResult {
        guard !running else { throw OpenGrokPagerInteractiveError.alreadyRunning }
        guard !shutdownRequested else { throw OpenGrokPagerInteractiveError.shutdown }

        running = true
        currentRequest = request
        rendererBegan = false
        terminalRestored = false
        // One epoch per run: every animation frame's tick and seconds are
        // measured from here, so all motion styles share one clock.
        motionEpochNanos = DispatchTime.now().uptimeNanoseconds
        let mailbox = SignalMailbox()
        signalMailbox = mailbox
        let inputReader = ThrowingStreamReader(input)
        let inputPumpGate = InputPumpGate()
        self.inputPumpGate = inputPumpGate
        let renderer = self.renderer
        inputPump = Task {
            while !Task.isCancelled {
                guard await inputPumpGate.waitUntilAllowed() else { return }
                let read = await inputReader.next()
                await inputPumpGate.pause()
                switch read {
                case .element(let event):
                    // Overlays and the mouse router get first refusal, ahead of
                    // both the interrupt classifier and the prompt state
                    // machine. Ctrl+C / Ctrl+D are deliberately exempt so a
                    // modal can never trap the session.
                    let isEscapeHatch: Bool
                    switch Self.controlAction(for: event) {
                    case .some(.interrupt), .some(.eof): isEscapeHatch = true
                    default: isEscapeHatch = false
                    }
                    if !isEscapeHatch {
                        switch try? await renderer.handleInput(event) {
                        case .some(.consumed):
                            await inputPumpGate.resume()
                            continue
                        case .some(.runCommand(let text)):
                            // The gate stays paused: whichever loop services the
                            // control signal resumes it, exactly as for an
                            // interrupt.
                            await mailbox.send(.control(.command(text)), priority: true)
                            continue
                        case .some(.notHandled), .none:
                            break
                        }
                    }
                    switch Self.controlAction(for: event) {
                    case .some(.escape):
                        await mailbox.send(.control(.interrupt(isEscape: true)), priority: true)
                    case .some(.interrupt):
                        await mailbox.send(.control(.interrupt(isEscape: false)), priority: true)
                    case .some(.eof):
                        await mailbox.send(.control(.eof), priority: true)
                    default:
                        await mailbox.send(.input(read))
                    }
                case .end, .failure, .cancelled:
                    await mailbox.send(.input(read))
                    return
                }
            }
        }
        var outcome: OpenGrokPagerInteractiveLifecycle = .completed
        var runError: Error?

        do {
            try await renderer.begin()
            rendererBegan = true
            try await transition(to: .starting)
            editor = PromptEditor(text: request.prompt)
            // A fresh editor starts in single-line mode; anything seeded by
            // `setInputModes` has to survive the rebuild or `/multiline` would
            // silently reset itself at the top of every run.
            editor.isMultiline = modes.isMultiline
            try await emit(.promptChanged(promptState()))

            if let initialSession {
                let initialRequest = request
                if !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submittedPrompts.append(request.prompt)
                }
                // The opening turn owns a session the caller already built, so
                // it cannot go through the drain loop; only what it leaves
                // behind in the queue can.
                editor.reset()
                let turnOutcome = try await runTurn(
                    session: initialSession,
                    request: initialRequest,
                    mailbox: mailbox,
                    inputPumpGate: inputPumpGate
                )
                switch try await apply(
                    turnOutcome: turnOutcome,
                    inputPumpGate: inputPumpGate
                ) {
                case .end(let lifecycle):
                    outcome = lifecycle
                case .keepEditing:
                    break
                case .drainNext:
                    if let lifecycle = try await drainQueue(
                        request: request,
                        mailbox: mailbox,
                        inputPumpGate: inputPumpGate
                    ) {
                        outcome = lifecycle
                    }
                }
            } else {
                try await transition(to: .editing)
            }

            while outcome == .completed {
                try Task.checkCancellation()
                guard let signal = await mailbox.next() else {
                    try await discardQueue(reason: "input ended")
                    try await emit(.eof)
                    outcome = .eof
                    continue
                }
                switch signal {
                case .session:
                    continue
                case .control(let control):
                    switch control {
                    case .interrupt(let isEscape):
                        switch handleInterrupt(isEscape: isEscape, isTurnRunning: false) {
                        case .quit:
                            try await discardQueue(reason: "quitting")
                            try await emit(.cancelled)
                            outcome = .cancelled
                        case .consumed, .cancelTurn:
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        }
                    case .cancel:
                        try await discardQueue(reason: "run cancelled")
                        try await emit(.cancelled)
                        outcome = .cancelled
                    case .eof:
                        try await discardQueue(reason: "input ended")
                        try await emit(.eof)
                        outcome = .eof
                    case .shutdown:
                        try await discardQueue(reason: "shutting down")
                        try await emit(.shutdown)
                        outcome = .shutdown
                    case .command(let text):
                        switch try await runSlashCommand(text) {
                        case .quit:
                            try await discardQueue(reason: "quitting")
                            try await emit(.shutdown)
                            outcome = .shutdown
                        case .submit(let generatedPrompt):
                            try await enqueue(generatedPrompt, historyText: text)
                            if let lifecycle = try await drainQueue(
                                request: request,
                                mailbox: mailbox,
                                inputPumpGate: inputPumpGate
                            ) {
                                outcome = lifecycle
                            }
                        case .handled, .notACommand:
                            // The draft is deliberately untouched — upstream's
                            // `SendSlashCommandPreservingDraft`.
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        }
                    }
                case .input(let read):
                    switch read {
                    case .element(let event):
                        // The scrollback gets the key first when it has focus,
                        // and never hands one back to the composer.
                        if try await handleScrollbackEvent(event) {
                            await inputPumpGate.resume()
                            continue
                        }
                        let action = applyEditorEvent(event)
                        switch action {
                        case .changed, .historyPrevious, .historyNext,
                             .completionMove, .completionAccept:
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        case .focusScrollback:
                            try await setFocus(.scrollback)
                            await inputPumpGate.resume()
                        case .toggleMultiline:
                            try await setMultiline(!modes.isMultiline)
                            await inputPumpGate.resume()
                        case .global(let command):
                            try await handleGlobal(command, isTurnRunning: false)
                            await inputPumpGate.resume()
                        case .viewport(let command):
                            try await emit(.viewport(command))
                            await inputPumpGate.resume()
                        case .escape, .interrupt:
                            let isEscape: Bool
                            if case .escape = action { isEscape = true } else { isEscape = false }
                            switch handleInterrupt(isEscape: isEscape, isTurnRunning: false) {
                            case .quit:
                                try await discardQueue(reason: "quitting")
                                try await emit(.cancelled)
                                outcome = .cancelled
                                continue
                            case .consumed, .cancelTurn:
                                try await emit(.promptChanged(promptState()))
                                await inputPumpGate.resume()
                            }
                        case .submit:
                            let prompt = editor.text
                            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                // Nothing to send and nothing queued — the
                                // send-now path only exists during a turn.
                                try await emit(.notice("prompt cannot be empty"))
                                await inputPumpGate.resume()
                                continue
                            }
                            switch try await runSlashCommand(prompt) {
                            case .quit:
                                try await discardQueue(reason: "quitting")
                                try await emit(.shutdown)
                                outcome = .shutdown
                                continue
                            case .submit(let generatedPrompt):
                                try await enqueue(generatedPrompt, historyText: prompt)
                                if let lifecycle = try await drainQueue(
                                    request: request,
                                    mailbox: mailbox,
                                    inputPumpGate: inputPumpGate
                                ) {
                                    outcome = lifecycle
                                }
                                continue
                            case .handled:
                                recordHistory(prompt)
                                editor.reset()
                                try await emit(.promptChanged(promptState()))
                                await inputPumpGate.resume()
                                continue
                            case .notACommand:
                                break
                            }
                            try await enqueue(prompt)
                            if let lifecycle = try await drainQueue(
                                request: request,
                                mailbox: mailbox,
                                inputPumpGate: inputPumpGate
                            ) {
                                outcome = lifecycle
                            }
                        case .eof:
                            try await discardQueue(reason: "input ended")
                            try await emit(.eof)
                            outcome = .eof
                        case .resize(let size):
                            try await renderer.resize(to: size)
                            await inputPumpGate.resume()
                        case .ignored:
                            await inputPumpGate.resume()
                            continue
                        }
                    case .end:
                        try await discardQueue(reason: "input ended")
                        try await emit(.eof)
                        outcome = .eof
                    case .failure(let message):
                        throw OpenGrokPagerInteractiveError.inputFailed(message)
                    case .cancelled:
                        throw CancellationError()
                    }
                }
            }
        } catch is CancellationError {
            outcome = .cancelled
            runError = CancellationError()
            await cancelActiveSession()
            try? await emit(.cancelled)
        } catch {
            outcome = .failed
            runError = error
            await cancelActiveSession()
            try? await emit(.failed(String(describing: error)))
        }

        // Stop the motion ticker and wait for it to land before touching the
        // terminal: a tick racing `restoreTerminal` could paint into a
        // restored screen. Awaiting is safe — the ticker's sleeps are actor
        // suspensions, so it observes the cancellation promptly.
        motionTicker?.cancel()
        if let motionTicker {
            _ = await motionTicker.value
        }
        motionTicker = nil

        await closeActiveSession()
        inputPump?.cancel()
        await inputPumpGate.close()
        await inputReader.cancel()
        if let inputPump {
            _ = await inputPump.value
        }
        self.inputPump = nil
        self.inputPumpGate = nil
        await mailbox.close()
        signalMailbox = nil

        if rendererBegan {
            do {
                try await renderer.restoreTerminal()
                terminalRestored = true
            } catch {
                outcome = .failed
                if runError == nil {
                    runError = OpenGrokPagerInteractiveError.terminalRestorationFailed(String(describing: error))
                }
            }
        }

        running = false
        activeSessionID = nil
        lifecycle = outcome

        let result = OpenGrokPagerInteractiveResult(
            lifecycle: outcome,
            sessionID: lastSessionID ?? request.sessionID,
            submittedPrompts: submittedPrompts,
            completedTurnCount: completedTurnCount,
            terminalRestored: terminalRestored
        )
        if let runError {
            throw runError
        }
        return result
    }

    private func runTurn(
        session: any OpenGrokPagerSessionAdapter,
        request: OpenGrokPagerRequest,
        mailbox: SignalMailbox,
        inputPumpGate: InputPumpGate
    ) async throws -> TurnOutcome {
        activeSession = session
        activeSessionID = session.sessionID ?? request.sessionID
        activeSessionCancelled = false
        activeSessionClosed = false
        try await emit(.turnStarted(request))
        try await transition(to: .running)

        turnGeneration &+= 1
        let generation = turnGeneration
        let sessionTask = Task {
            var reachedTerminalEvent = false
            do {
                for try await event in session.events {
                    await mailbox.send(.session(generation: generation, .element(event)))
                    if isTerminal(event) {
                        reachedTerminalEvent = true
                        break
                    }
                }
                if !reachedTerminalEvent {
                    await mailbox.send(.session(generation: generation, .end))
                }
            } catch is CancellationError {
                return
            } catch {
                await mailbox.send(.session(
                    generation: generation,
                    .failure(String(describing: error))
                ))
            }
        }
        await Task.yield()
        await inputPumpGate.resume()
        var eventCount = 0
        var terminalLifecycle: OpenGrokPagerMinimalLifecycle = .completed
        var turnOutcome: TurnOutcome?

        do {
            while turnOutcome == nil {
                try Task.checkCancellation()
                guard let signal = await mailbox.next() else {
                    turnOutcome = .eof
                    continue
                }
                switch signal {
                case .session(let signalGeneration, let read):
                    // A stale signal is a previous turn's death, not this
                    // turn's; adopting it would cancel this turn and discard
                    // the queue (see `Signal.session`).
                    guard signalGeneration == generation else { continue }
                    switch read {
                    case .element(let event):
                        try await emit(.session(event))
                        eventCount += 1
                        switch event {
                        case .completed:
                            terminalLifecycle = .completed
                        case .cancelled:
                            terminalLifecycle = .cancelled
                        case .lifecycle, .output, .status, .tool, .permissionRequested:
                            continue
                        }
                        let result = OpenGrokPagerRuntimeResult(
                            lifecycle: terminalLifecycle,
                            sessionID: session.sessionID ?? request.sessionID,
                            forwardedEventCount: eventCount,
                            terminalRestored: false
                        )
                        try await emit(.turnFinished(result))
                        turnOutcome = .finished(result)
                    case .end:
                        let result = OpenGrokPagerRuntimeResult(
                            lifecycle: terminalLifecycle,
                            sessionID: session.sessionID ?? request.sessionID,
                            forwardedEventCount: eventCount,
                            terminalRestored: false
                        )
                        try await emit(.turnFinished(result))
                        turnOutcome = .finished(result)
                    case .failure(let message):
                        throw OpenGrokPagerInteractiveError.sessionFailed(message)
                    case .cancelled:
                        throw CancellationError()
                    }
                case .input(let read):
                    switch read {
                    case .element(let event):
                        if case .resize(let size) = event {
                            try await renderer.resize(to: size)
                            await inputPumpGate.resume()
                            continue
                        }
                        switch Self.controlAction(for: event) {
                        case .some(.escape), .some(.interrupt):
                            var isEscape = false
                            if case .some(.escape) = Self.controlAction(for: event) { isEscape = true }
                            switch handleInterrupt(isEscape: isEscape, isTurnRunning: true) {
                            case .cancelTurn:
                                await cancelActiveSession()
                                turnOutcome = .turnCancelled
                            case .consumed, .quit:
                                try await emit(.promptChanged(promptState()))
                                await inputPumpGate.resume()
                            }
                        case .some(.eof):
                            await cancelActiveSession()
                            turnOutcome = .eof
                        default:
                            if try await handleScrollbackEvent(event) {
                                await inputPumpGate.resume()
                                continue
                            }
                            // The composer stays live while a turn runs — that
                            // is the whole point of the send→queue flip in the
                            // shortcuts bar.
                            switch applyEditorEvent(event) {
                            case .submit:
                                let prompt = editor.text
                                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    // Bare Enter on an empty composer with a
                                    // follow-up waiting force-sends the head of
                                    // the queue. Send-now cancels the running
                                    // turn and lets `.turnPreempted` drain that
                                    // already-frontmost prompt next.
                                    if await promptQueue.isEmpty {
                                        try await emit(.notice("prompt cannot be empty"))
                                        await inputPumpGate.resume()
                                    } else {
                                        await cancelActiveSession()
                                        turnOutcome = .turnPreempted
                                    }
                                } else {
                                    // A UI-only slash command runs now rather
                                    // than queueing behind the turn — `/queue`
                                    // is only ever useful *here*, and queueing
                                    // it would make it unreachable at the one
                                    // moment it answers a real question.
                                    //
                                    // A history-mutating one must NOT: it would
                                    // rewrite the item list underneath a
                                    // streaming sampler. Those go to the queue,
                                    // which is what upstream does for the whole
                                    // category via `CommandResult::QueueCommand`.
                                    switch try await runSlashCommand(
                                        prompt,
                                        isTurnRunning: true
                                    ) {
                                    case .quit:
                                        await cancelActiveSession()
                                        turnOutcome = .shutdown
                                    case .submit(let generatedPrompt):
                                        try await enqueue(generatedPrompt, historyText: prompt)
                                        await inputPumpGate.resume()
                                    case .handled:
                                        recordHistory(prompt)
                                        editor.reset()
                                        try await emit(.promptChanged(promptState()))
                                        await inputPumpGate.resume()
                                    case .notACommand where modes.enterSteers:
                                        // With `enter_steers` on, Enter takes
                                        // upstream's cancel-and-send role
                                        // (`defaults.rs:630-632`): the draft
                                        // runs next, ahead of waiting follow-ups.
                                        try await enqueue(prompt, insertion: .front)
                                        await cancelActiveSession()
                                        turnOutcome = .turnPreempted
                                    case .notACommand:
                                        try await enqueue(prompt)
                                        await inputPumpGate.resume()
                                    }
                                }
                            case .viewport(let command):
                                try await emit(.viewport(command))
                                await inputPumpGate.resume()
                            case .focusScrollback:
                                try await setFocus(.scrollback)
                                await inputPumpGate.resume()
                            case .toggleMultiline:
                                try await setMultiline(!modes.isMultiline)
                                await inputPumpGate.resume()
                            case .global(let command):
                                try await handleGlobal(command, isTurnRunning: true)
                                await inputPumpGate.resume()
                            case .ignored:
                                await inputPumpGate.resume()
                            case .changed, .historyPrevious, .historyNext,
                                 .completionMove, .completionAccept,
                                 .escape, .interrupt, .eof, .resize:
                                try await emit(.promptChanged(promptState()))
                                await inputPumpGate.resume()
                            }
                        }
                    case .end:
                        await cancelActiveSession()
                        turnOutcome = .eof
                    case .failure(let message):
                        throw OpenGrokPagerInteractiveError.inputFailed(message)
                    case .cancelled:
                        throw CancellationError()
                    }
                case .control(let control):
                    switch control {
                    case .interrupt(let isEscape):
                        switch handleInterrupt(isEscape: isEscape, isTurnRunning: true) {
                        case .cancelTurn:
                            await cancelActiveSession()
                            turnOutcome = .turnCancelled
                        case .consumed, .quit:
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        }
                    case .cancel:
                        await cancelActiveSession()
                        turnOutcome = .cancelled
                    case .eof:
                        await cancelActiveSession()
                        turnOutcome = .eof
                    case .shutdown:
                        await cancelActiveSession()
                        turnOutcome = .shutdown
                    case .command(let text):
                        switch try await runSlashCommand(text, isTurnRunning: true) {
                        case .quit:
                            await cancelActiveSession()
                            turnOutcome = .shutdown
                        case .submit(let generatedPrompt):
                            try await enqueue(generatedPrompt, historyText: text)
                            await inputPumpGate.resume()
                        case .handled, .notACommand:
                            try await emit(.promptChanged(promptState()))
                            await inputPumpGate.resume()
                        }
                    }
                }
            }
        } catch {
            sessionTask.cancel()
            _ = await sessionTask.value
            throw error
        }

        sessionTask.cancel()
        _ = await sessionTask.value
        await closeActiveSession()
        return turnOutcome ?? .eof
    }

    // MARK: - Queue

    private enum QueueInsertion {
        case front
        case tail
    }

    /// Put a prompt in the queue and clear the composer.
    ///
    /// Normal follow-ups use the tail. Send-now uses the front, then cancels the
    /// active turn so the existing drain path runs it next.
    private func enqueue(
        _ prompt: String,
        historyText: String? = nil,
        insertion: QueueInsertion = .tail
    ) async throws {
        nextPromptSequence += 1
        let entry = QueueEntryMeta(
            id: "prompt-\(nextPromptSequence)",
            kind: "prompt",
            text: prompt
        )
        switch insertion {
        case .front:
            await promptQueue.enqueueFront(entry)
        case .tail:
            await promptQueue.enqueue(entry)
        }
        recordHistory(historyText ?? prompt)
        editor.reset()
        try await emit(.promptChanged(promptState()))
        try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))
    }

    /// Buffer `/btw` outside the prompt queue.
    ///
    /// The Swift runtime cannot hand a side question to a sampler that already
    /// committed to a turn, so `/btw` holds the text until the next prompt and
    /// frames it with `formatInterjection`. Enter-steers deliberately does not
    /// use this soft-interjection path; upstream defines it as cancel-and-send
    /// (`defaults.rs:630-632`).
    private func interject(_ text: String, kind: InterjectionKind) async throws {
        interjections.push(KindedInterjection(kind: kind, text: text))
        recordHistory(text)
        editor.reset()
        try await emit(.promptChanged(promptState()))
        try await emit(.notice(
            "Held for the running turn — it will lead the next prompt."
        ))
    }

    /// Fold any buffered interjections into the front of `prompt`.
    private func withInterjections(_ prompt: String) -> String {
        let drained = drainKindedFormatted(interjections)
        guard !drained.isEmpty else { return prompt }
        return (drained.map(\.formatted.text) + [prompt]).joined(separator: "\n\n")
    }

    /// Throw away everything still queued. Reserved for the ways a run *ends* —
    /// quit, EOF, external cancel. Cancelling a turn deliberately does not come
    /// here: the reference keeps follow-ups across an interrupt.
    private func discardQueue(reason: String) async throws {
        let discarded = await promptQueue.removeAll()
        guard !discarded.isEmpty else { return }
        let plural = discarded.count == 1 ? "prompt" : "prompts"
        try await emit(.notice("discarded \(discarded.count) queued \(plural) — \(reason)"))
        try await emit(.queueChanged(queuedPromptCount: 0))
    }

    /// Run queued prompts in order until the queue empties or something ends
    /// the run. Returns the terminal lifecycle, or `nil` to continue editing.
    private func drainQueue(
        request: OpenGrokPagerRequest,
        mailbox: SignalMailbox,
        inputPumpGate: InputPumpGate
    ) async throws -> OpenGrokPagerInteractiveLifecycle? {
        while true {
            let entry: QueueEntryMeta
            do {
                entry = try await promptQueue.beginNext()
            } catch {
                // `.empty` is the normal exit; `.alreadyRunning` cannot happen
                // because every path below clears the running marker.
                return nil
            }
            // A queued slash command is a command, not a prompt. This is the
            // other half of the mid-turn deferral: `/compact` was put here
            // precisely so it would run against a settled conversation, and
            // sending its text to the model instead would be worse than having
            // run it early.
            if case .command = PagerCommandParser.parse(entry.text) {
                await promptQueue.completeRunning()
                switch try await runSlashCommand(entry.text) {
                case .submit(let generatedPrompt):
                    try await enqueue(generatedPrompt, historyText: entry.text)
                case .quit, .handled, .notACommand:
                    break
                }
                try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))
                continue
            }

            // `combine_queued_prompts` (`defs.rs:708`): take the whole backlog
            // as one turn rather than one turn each. Only the entries already
            // waiting are folded in — anything enqueued during the turn stays
            // for the next drain, so a fast typist cannot starve the model.
            var promptText = entry.text
            if modes.combineQueuedPrompts {
                let rest = await promptQueue.removeAll().map(\.text)
                if !rest.isEmpty {
                    promptText = ([entry.text] + rest).joined(separator: "\n\n")
                }
            }
            try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))

            let turnRequest = OpenGrokPagerRequest(
                prompt: withInterjections(promptText),
                mode: request.mode,
                sessionID: lastSessionID ?? request.sessionID,
                metadata: request.metadata
            )
            let session = try await runtime.makeSession(for: turnRequest)
            submittedPrompts.append(promptText)
            let turnOutcome = try await runTurn(
                session: session,
                request: turnRequest,
                mailbox: mailbox,
                inputPumpGate: inputPumpGate
            )
            switch try await apply(turnOutcome: turnOutcome, inputPumpGate: inputPumpGate) {
            case .drainNext:
                continue
            case .keepEditing:
                return nil
            case .end(let lifecycle):
                return lifecycle
            }
        }
    }

    /// Account for a finished turn: clear the queue's running marker, emit the
    /// matching event, and say whether the queue should keep draining.
    private func apply(
        turnOutcome: TurnOutcome,
        inputPumpGate: InputPumpGate
    ) async throws -> TurnDisposition {
        switch turnOutcome {
        case .finished(let result):
            await promptQueue.completeRunning()
            lastSessionID = result.sessionID ?? lastSessionID
            if result.lifecycle == .cancelled {
                try await discardQueue(reason: "run cancelled")
                try await emit(.cancelled)
                return .end(.cancelled)
            }
            completedTurnCount += 1
            try await transition(to: .editing)
            try await emit(.promptChanged(promptState()))
            return .drainNext
        case .eof:
            await promptQueue.cancelRunning()
            try await discardQueue(reason: "input ended")
            try await emit(.eof)
            return .end(.eof)
        case .turnCancelled:
            // Cancelling a turn returns to the prompt and keeps the queue; only
            // an external cancel ends the run.
            await promptQueue.cancelRunning()
            try await emit(.turnCancelled)
            try await transition(to: .editing)
            try await emit(.promptChanged(promptState()))
            await inputPumpGate.resume()
            return .keepEditing
        case .turnPreempted:
            await promptQueue.cancelRunning()
            try await emit(.notice("sending the queued prompt now"))
            try await transition(to: .editing)
            try await emit(.promptChanged(promptState()))
            await inputPumpGate.resume()
            return .drainNext
        case .cancelled:
            await promptQueue.cancelRunning()
            try await discardQueue(reason: "run cancelled")
            try await emit(.cancelled)
            return .end(.cancelled)
        case .shutdown:
            await promptQueue.cancelRunning()
            try await discardQueue(reason: "shutting down")
            try await emit(.shutdown)
            return .end(.shutdown)
        }
    }

    // MARK: - Scrollback focus

    /// What the scrollback does with a key while it holds focus.
    private enum ScrollbackRouting: Sendable {
        case focusPrompt
        case command(OpenGrokPagerScrollbackCommand)
        case viewport(OpenGrokPagerViewportCommand)
        /// The scrollback has focus and declines to act, but a focused region
        /// never leaks a keystroke to the composer — upstream's rule for
        /// modals, applied to the focus split for the same reason.
        case swallowed
    }

    /// Map a key under `When::ScrollbackFocused` (`defaults.rs:84-460,475`).
    ///
    /// Bare-letter and Shift-letter bindings are suppressed unless vim mode is
    /// on, mirroring `lookup_with_mode` (`actions/mod.rs:397-430`). With vim
    /// off the region is still fully usable through the arrows, `Enter`, `Tab`,
    /// the paging keys and the `Ctrl` chords — which is the point of the gate:
    /// typing `y` at a transcript should not silently copy something.
    private func scrollbackRouting(for event: InputEvent) -> ScrollbackRouting {
        guard case .key(let key) = event else { return .swallowed }

        if key.modifiers.contains(.control) {
            let character: Character?
            switch key.key {
            case .char(let value): character = value
            default: character = key.character
            }
            switch character?.lowercased() {
            case "k": return .viewport(.lineUp)
            case "j": return .viewport(.lineDown)
            case "u": return .viewport(.halfPageUp)
            case "e": return .command(.expandAllThinking)
            default: return .swallowed
            }
        }

        let isShifted = key.modifiers.contains(.shift)
        switch key.key {
        case .tab:
            return .focusPrompt
        case .enter:
            return .command(.openBlockViewer)
        case .up:
            return .command(.selectPrevious)
        case .down:
            return .command(.selectNext)
        case .left:
            return isShifted ? .command(.previousTurn) : .command(.collapse)
        case .right:
            return isShifted ? .command(.nextTurn) : .command(.expand)
        case .pageUp:
            return .viewport(.pageUp)
        case .pageDown:
            return .viewport(.pageDown)
        case .home:
            return .command(.selectFirst)
        case .end:
            return .command(.selectLast)
        case .char(let character):
            guard modes.isVimMode else { return .swallowed }
            return Self.vimRouting(for: character)
        default:
            return .swallowed
        }
    }

    private static func vimRouting(for character: Character) -> ScrollbackRouting {
        switch character {
        case "j": return .command(.selectNext)
        case "k": return .command(.selectPrevious)
        case "L": return .command(.nextTurn)
        case "H": return .command(.previousTurn)
        case "J": return .command(.nextResponse)
        case "K": return .command(.previousResponse)
        case "g": return .command(.selectFirst)
        case "G": return .command(.selectLast)
        case "h": return .command(.collapse)
        case "l": return .command(.expand)
        case "e": return .command(.toggleFold)
        case "E": return .command(.toggleExpandAll)
        case "r": return .command(.toggleRaw)
        case "y": return .command(.copyBlockContent)
        case "Y": return .command(.copyBlockMetadata)
        case "o": return .command(.openNextLink)
        case "O": return .command(.openPreviousLink)
        case "x": return .command(.killBackgroundTask)
        // `d`/`u` are the VS Code family's half-page bindings upstream
        // (`defaults.rs:231-235`); this port keeps `Ctrl+D` on EOF
        // unconditionally so a focus region can never trap the session, and
        // takes the bare-letter form instead.
        case "d": return .viewport(.halfPageDown)
        case "u": return .viewport(.halfPageUp)
        // `i` and `Space` enter the prompt but, unlike `Tab`, do not leave it
        // (`defaults.rs:475-487`).
        case "i", " ": return .focusPrompt
        default: return .swallowed
        }
    }

    /// Apply one key while the scrollback holds focus. Returns false when the
    /// caller should fall through to the composer — which only happens when
    /// focus was not on the scrollback to begin with.
    private func handleScrollbackEvent(_ event: InputEvent) async throws -> Bool {
        guard focus == .scrollback else { return false }
        if case .resize(let size) = event {
            try await renderer.resize(to: size)
            return true
        }
        switch scrollbackRouting(for: event) {
        case .focusPrompt:
            try await setFocus(.prompt)
        case .command(let command):
            try await emit(.scrollback(command))
        case .viewport(let command):
            try await emit(.viewport(command))
        case .swallowed:
            break
        }
        return true
    }

    private func setFocus(_ region: OpenGrokPagerFocusRegion) async throws {
        guard focus != region else { return }
        focus = region
        // A focus change disarms anything the composer had pending: the arming
        // key is no longer the one the next press would hit.
        pendingConfirmation = nil
        try await emit(.focusChanged(region))
        try await emit(.promptChanged(promptState()))
    }

    private func setMultiline(_ isOn: Bool) async throws {
        guard modes.isMultiline != isOn else { return }
        modes.isMultiline = isOn
        editor.isMultiline = isOn
        try await emit(.modeChanged(modes))
        try await emit(.notice(isOn
            ? "Multiline on. Enter inserts a newline; Shift+Enter sends."
            : "Multiline off. Enter sends; Shift+Enter inserts a newline."))
    }

    // MARK: - Prompt behavior

    /// Feed one input event to the composer and apply the bookkeeping every
    /// caller shares — confirmation disarming, history detach, completion
    /// movement. Returns the action for the caller to act on.
    private func applyEditorEvent(_ event: InputEvent) -> PromptAction {
        let action = editor.apply(event)
        // Any key other than the armed one clears a pending confirmation,
        // matching `app_view.rs`'s arm lifetime. `.global` is exempt because a
        // confirming chord's second press *is* the armed key — disarming here
        // would make `Ctrl+N` unconfirmable — so `handleGlobal` owns the
        // lifetime for those.
        switch action {
        case .escape, .interrupt, .ignored, .resize, .global:
            break
        default:
            pendingConfirmation = nil
        }
        switch action {
        case .changed:
            detachHistory()
            refreshCompletions()
        case .historyPrevious:
            browseHistory(offset: -1)
        case .historyNext:
            browseHistory(offset: 1)
        case .completionMove(let offset):
            if !editor.completions.isEmpty {
                let count = editor.completions.count
                let current = editor.selectedCompletion ?? 0
                if abs(offset) == 1 {
                    // Arrow steps wrap (`slash_move_selection`).
                    editor.selectedCompletion = ((current + offset) % count + count) % count
                } else {
                    // Page steps clamp at the ends, no wrap-around
                    // (`slash_scroll_selection`, `prompt_widget/mod.rs:1185-1190`).
                    editor.selectedCompletion = min(max(current + offset, 0), count - 1)
                }
            }
        case .completionAccept:
            if let index = editor.selectedCompletion,
               editor.completions.indices.contains(index) {
                let suggestion = editor.completions[index]
                // Accepting a *command* row records MRU; an argument row does
                // not (`record_mru = snap.cursor_in_command`,
                // `prompt_widget/mod.rs:1206-1211`).
                if Self.argumentPhase(for: editor.text) == nil {
                    recordSlashMruUse(commandNamed: suggestion.name)
                }
                editor.replace(with: suggestion.insertText)
            }
            editor.completions = []
            editor.selectedCompletion = nil
        default:
            break
        }
        return action
    }

    /// Record an accepted slash command in the MRU and hand a persistence
    /// snapshot to the serialized writer. The write happens off this actor; a
    /// failed write re-marks the store dirty so the next accept retries —
    /// upstream's exact recovery (`prompt_widget/mod.rs:1268`, `mru.rs:
    /// 411-421`).
    private func recordSlashMruUse(commandNamed name: String) {
        slashMru.touch(name, now: UInt64(Date().timeIntervalSince1970))
        guard let snapshot = slashMru.takePersistSnapshot() else { return }
        Task {
            // The Task inherits this actor's isolation, so re-marking dirty
            // after a failed write mutates the store race-free.
            let written = await PagerSlashMruWriter.shared.write(snapshot)
            if !written {
                self.slashMru.markDirty()
            }
        }
    }

    /// Slash commands the TUI honors locally. The reference registers ~71 and
    /// routes most of them to a pager `Action`; this port lists only the ones
    /// backed by working Swift wiring, so the dropdown never offers a no-op.
    ///
    /// Summaries are upstream's verbatim (`src/slash/commands/*.rs`) so the
    /// dropdown reads identically for every command both sides have.
    static let builtinCommands: [PagerCommandDefinition] = [
        // Registration order is display order: a bare `/` lists exactly this
        // sequence, mirroring upstream's `builtin_commands()` ("in display
        // order", `slash/commands/mod.rs:78-81`). `quit` and `help` lead for
        // the same reason they lead upstream. Ranked queries no longer read
        // an explicit priority — ordering is fuzzy score, then recency, then
        // display (`slash/mod.rs:996-1003`), so `/q` resolves its tie by
        // display order, exactly as upstream's dropdown does.
        PagerCommandDefinition(
            name: "quit",
            aliases: ["exit"],
            summary: "Quit the application"
        ),
        PagerCommandDefinition(
            name: "help",
            summary: "Browse commands and keyboard shortcuts"
        ),
        PagerCommandDefinition(
            name: "home",
            aliases: ["welcome"],
            summary: "Return to the welcome screen"
        ),
        PagerCommandDefinition(
            name: "new",
            aliases: ["clear"],
            summary: "Start a new session",
            mutatesConversationHistory: true
        ),
        // `/resume` (`slash/commands/resume.rs:9-19`). Committing a picked
        // session replaces the live conversation, so it takes the same
        // mid-turn deferral `/new` does.
        PagerCommandDefinition(
            name: "resume",
            summary: "Resume a previous session",
            usage: "/resume",
            mutatesConversationHistory: true
        ),
        PagerCommandDefinition(
            name: "copy",
            summary: "Copy last response to clipboard or file (/copy [N] [file])",
            usage: "/copy [N] [file]"
        ),
        PagerCommandDefinition(
            name: "find",
            summary: "Search the conversation scrollback",
            usage: "/find [text]"
        ),
        PagerCommandDefinition(
            name: "history",
            summary: "Search prompt history"
        ),
        PagerCommandDefinition(
            name: "export",
            summary: "Export the current conversation to a file or clipboard",
            usage: "/export [filename]"
        ),
        // `/transcript`, alias `/log` (`slash/commands/transcript.rs:16-34`);
        // summary is upstream's description verbatim (`transcript.rs:24-26`),
        // placed after `/export` in upstream's display order
        // (`slash/commands/mod.rs:94-95`). Not history-mutating: the pager
        // view is read-only, so upstream dispatches it mid-turn too.
        PagerCommandDefinition(
            name: "transcript",
            aliases: ["log"],
            summary: "View the full conversation transcript in your pager ($PAGER)",
            usage: "/transcript"
        ),
        PagerCommandDefinition(
            name: "context",
            summary: "View context usage"
        ),
        // `/usage`, alias `/cost` (`slash/commands/usage.rs:10-16`). The
        // usage string is the non-consumer grammar (`usage.rs:57-61`, bare
        // `/usage` only): this port has no billing surface, so advertising
        // upstream's `[show|manage]` arms would register rows with no
        // backing.
        PagerCommandDefinition(
            name: "usage",
            aliases: ["cost"],
            summary: "View session token usage",
            usage: "/usage"
        ),
        PagerCommandDefinition(
            name: "model",
            aliases: ["m"],
            summary: "Switch the active model",
            usage: "/model [name]"
        ),
        // `/effort` (`slash/commands/effort.rs:14-30`): reasoning effort on
        // the current model without re-picking it.
        PagerCommandDefinition(
            name: "effort",
            summary: "Set reasoning effort for the current model",
            usage: "/effort <level>"
        ),
        PagerCommandDefinition(
            name: "multiline",
            aliases: ["ml"],
            summary: "Toggle multiline input mode (swap Enter and Shift+Enter)"
        ),
        PagerCommandDefinition(
            name: "vim-mode",
            summary: "Toggle vim-style scrollback keybindings (j/k, h/l, g/G, y/Y, …)"
        ),
        PagerCommandDefinition(
            name: "session-info",
            summary: "Show session info"
        ),
        PagerCommandDefinition(
            name: "workflows",
            summary: "Show workflow runs (phases, agents, progress)"
        ),
        // `/mcps` (`slash/commands/mcps.rs:7-17`).
        PagerCommandDefinition(
            name: "mcps",
            summary: "Show MCP server status",
            usage: "/mcps"
        ),
        PagerCommandDefinition(
            name: "toggle-mouse-reporting",
            summary: "Toggle terminal mouse reporting (native click-drag copy/paste)"
        ),
        PagerCommandDefinition(
            name: "queue",
            summary: "List the prompts queued behind the running turn"
        ),
        // `/btw` (`slash/commands/btw.rs:12-38`). Upstream fires an ACP ext
        // method that bypasses the prompt queue; this port maps it onto the
        // interjection buffer, which is the same promise — the question rides
        // ahead of the queue instead of behind it.
        PagerCommandDefinition(
            name: "btw",
            summary: "Ask a side question without interrupting",
            usage: "/btw <question>"
        ),
        PagerCommandDefinition(
            name: "compact",
            summary: "Compact conversation history",
            usage: "/compact [instructions]",
            // The one command that must never run inline: it rewrites the
            // items a streaming turn is sampling from.
            mutatesConversationHistory: true
        ),
        PagerCommandDefinition(
            name: "settings",
            aliases: ["config", "preferences", "prefs"],
            summary: "Open the settings modal"
        ),
        PagerCommandDefinition(
            name: "privacy",
            summary: "Open coding data, retention, and training settings"
        ),
        PagerCommandDefinition(
            name: "theme",
            aliases: ["t"],
            summary: "Switch the color theme",
            usage: "/theme [name]"
        ),
        PagerCommandDefinition(
            name: "tutorial",
            aliases: ["tour", "onboarding"],
            summary: "Quick tips to get the most out of Open Grok"
        ),
        PagerCommandDefinition(
            name: "rewind",
            aliases: ["undo"],
            summary: "Rewind to a previous turn",
            usage: "/rewind [n] [--mode=all|files|conversation] [--force]",
            // A forced rewind rewrites history and restores files. Running that
            // against the item list a turn is sampling from is the same hazard
            // `/compact` carries, so it takes the same deferral.
            mutatesConversationHistory: true
        ),
        PagerCommandDefinition(
            name: "jump",
            summary: "Jump to a turn in the conversation"
        ),
        PagerCommandDefinition(
            name: "delete",
            summary: "Delete this session and return home"
        ),
        // `/rename`, alias `/title` (`slash/commands/rename.rs:10-28`).
        PagerCommandDefinition(
            name: "rename",
            aliases: ["title"],
            summary: "Rename the current session",
            usage: "/rename <title>"
        ),
        PagerCommandDefinition(
            name: "remember",
            summary: "Save a memory note",
            usage: "/remember [text]"
        ),
        PagerCommandDefinition(
            name: "recall",
            summary: "Search workspace memory",
            usage: "/recall <query>"
        ),
        PagerCommandDefinition(
            name: "flush",
            summary: "Write notes to this session's memory log",
            usage: "/flush <notes>"
        ),
        PagerCommandDefinition(
            name: "goal",
            summary: "Set or inspect the session goal",
            usage: "/goal [objective|status|pause|resume|clear]"
        ),
        PagerCommandDefinition(
            name: "gboom",
            summary: "Hidden easter egg",
            isHidden: true
        )
    ]

    public static var builtinCommandCatalog: [OpenGrokPagerCommandRegistration] {
        builtinCommands.map { command in
            OpenGrokPagerCommandRegistration(
                name: command.name,
                aliases: command.aliases,
                summary: command.summary,
                usage: command.usage
            )
        }
    }

    public static var builtinCommandNames: Set<String> {
        Set(builtinCommands.flatMap(\.allNames))
    }

    /// The settings row `/privacy` deep-links to
    /// (`PagerSettingsRegistry.swift:856`), matching upstream's
    /// `CODING_DATA_SHARING_KEY`.
    static let codingDataSharingKey = "coding_data_sharing"

    /// `PendingAction::TTL` (`app_view.rs:591`) — a confirmation stays armed
    /// for one second and any other key clears it.
    private static let confirmationTimeToLive: TimeInterval = 1.0

    private func promptState() -> OpenGrokPagerInteractivePromptState {
        expirePendingConfirmation()
        return editor.state(
            pendingKey: pendingConfirmation?.key,
            pendingLabel: pendingConfirmation?.label
        )
    }

    private func expirePendingConfirmation() {
        if let pending = pendingConfirmation, pending.deadline <= Date() {
            pendingConfirmation = nil
        }
    }

    /// Returns true when `key` was already armed, i.e. this is the confirming
    /// second press.
    private func confirm(key: String, label: String) -> Bool {
        expirePendingConfirmation()
        if let pending = pendingConfirmation, pending.key == key {
            pendingConfirmation = nil
            return true
        }
        pendingConfirmation = (
            key: key,
            label: label,
            deadline: Date().addingTimeInterval(Self.confirmationTimeToLive)
        )
        return false
    }

    private func refreshCompletions() {
        // Esc closed the menu; it stays closed until the text changes.
        guard !editor.completionsDismissed else {
            editor.completions = []
            editor.selectedCompletion = nil
            return
        }
        let suggestions: [OpenGrokPagerCommandSuggestion]
        if let argumentPhase = Self.argumentPhase(for: editor.text) {
            // Once the command name is settled the dropdown belongs to the
            // arguments — `commands.completions` would return nothing here
            // anyway, since it refuses any input containing whitespace. The
            // host's provider gets first refusal; commands whose argument
            // vocabulary lives pager-side fall through to the built-ins.
            let provided = argumentSuggestions?(argumentPhase.command, argumentPhase.query) ?? []
            suggestions = provided.isEmpty
                ? Self.builtinArgumentSuggestions(
                    command: argumentPhase.command,
                    query: argumentPhase.query
                )
                : provided
        } else {
            // Recency scores resolved in one pass, keyed by canonical name —
            // one keystroke, one store read (`slash/mod.rs:985-992`).
            let now = UInt64(Date().timeIntervalSince1970)
            var recency: [String: UInt64] = [:]
            for command in commands.commands where !command.isHidden {
                let score = slashMru.rankScore(command.name, now: now)
                if score > 0 { recency[command.name] = score }
            }
            suggestions = commands
                .completions(for: editor.text, recency: recency)
                .map {
                    OpenGrokPagerCommandSuggestion(
                        name: $0.displayName,
                        summary: $0.summary,
                        isAvailable: $0.availability.isAvailable
                    )
                }
        }
        // No row cap: every match rides through and the dropdown renderer
        // scrolls the six-row window ("No cap here -- the dropdown renderer
        // handles scrolling", `slash/mod.rs:866-867`). The old `prefix(6)`
        // here is what made `/theme` unreachable from a bare `/`.
        editor.completions = suggestions
        editor.selectedCompletion = editor.completions.isEmpty ? nil : 0
    }

    /// Argument rows for commands whose vocabulary lives inside the pager
    /// targets. Today that is `/theme`: `auto` first, then the selectable
    /// themes in catalog order, fuzzy-filtered by the typed fragment —
    /// `ThemeCommand::suggest_args` (`slash/commands/theme.rs:81-110`) run
    /// through the arg matcher (`slash/mod.rs:1070-1085`).
    ///
    /// The `(active)` marker upstream appends is deliberately absent: the
    /// controller does not own the live theme (the render layer does), and a
    /// guessed marker would be wrong exactly when it matters.
    static func builtinArgumentSuggestions(
        command: String,
        query: String
    ) -> [OpenGrokPagerCommandSuggestion] {
        guard command == "theme" || command == "t" else { return [] }
        let names = ["auto"] + PagerThemeKind.selectable.map(\.displayName)
        let rows = names.map { name in
            OpenGrokPagerCommandSuggestion(
                name: name,
                summary: name == "auto" ? "auto (follow system)" : name,
                // The row commits the whole composer text, not the bare
                // argument — accepting must leave `/theme Tokyo Night`.
                insertText: "/theme \(name)"
            )
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        let matcher = PagerFuzzyMatcher()
        return matcher
            .rank(rows, query: trimmed, limit: rows.count) { $0.name }
            .map { rows[$0.index] }
    }

    /// `/model codex:` → `(command: "model", query: "codex:")`.
    ///
    /// The phase opens at the first whitespace after the command name, which is
    /// upstream's rule too: a trailing space is what moves the `/model`
    /// dropdown from the model list into the effort sub-menu. So `/model ` is a
    /// real query that happens to be empty, not an absent one — the whitespace
    /// decides the phase before it is trimmed out of the query.
    static func argumentPhase(for input: String) -> (command: String, query: String)? {
        let leading = input.drop { $0.isWhitespace }
        guard leading.first == "/" else { return nil }
        let body = leading.dropFirst()
        guard let split = body.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let command = PagerCommandDefinition.normalize(String(body[..<split]))
        guard !command.isEmpty else { return nil }
        let query = body[body.index(after: split)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, query)
    }

    /// Step to an older (`offset < 0`) or newer prompt. Paging past the newest
    /// entry closes browsing and restores the stashed draft, mirroring
    /// `close_history_restoring_saved` (`prompt.rs:997`).
    private func browseHistory(offset: Int) {
        guard !history.isEmpty else { return }
        guard let current = historyIndex else {
            // Down never opens browsing — only Up does.
            guard offset < 0 else { return }
            historySavedDraft = editor.text
            historyIndex = history.count - 1
            editor.isBrowsingHistory = true
            editor.replace(with: history[history.count - 1])
            refreshCompletions()
            return
        }
        let candidate = current + (offset < 0 ? -1 : 1)
        guard candidate < history.count else {
            editor.replace(with: historySavedDraft ?? "")
            detachHistory()
            refreshCompletions()
            return
        }
        let index = max(0, candidate)
        historyIndex = index
        editor.replace(with: history[index])
        refreshCompletions()
    }

    private func detachHistory() {
        historyIndex = nil
        historySavedDraft = nil
        editor.isBrowsingHistory = false
    }

    private func recordHistory(_ prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if history.last != prompt { history.append(prompt) }
        detachHistory()
    }

    /// Esc / Ctrl+C policy, mirroring `try_handle_esc_policy`
    /// (`app/agent_view/prompt.rs:841`) and the Ctrl+C handler
    /// (`app/agent_view/input.rs:1359`).
    ///
    /// The load-bearing asymmetries: Esc cancels a running turn even with a
    /// draft in the composer, while Ctrl+C clears the draft first and only
    /// cancels on the second press. When idle, Esc arms a clear and is
    /// otherwise swallowed — it never exits — whereas Ctrl+C on an empty
    /// composer arms a quit.
    private func handleInterrupt(isEscape: Bool, isTurnRunning: Bool) -> InterruptOutcome {
        // The dropdown intercepts Esc ahead of the whole cancel/clear ladder
        // (`prompt.rs:229-233`), idle or mid-turn: close the menu, keep the
        // draft, arm nothing. This must live here rather than in the
        // editor's key map — the input pump classifies a bare Esc as a
        // control signal before the editor ever sees the event, so an
        // editor-side close is unreachable in a live run.
        if isEscape, editor.dismissCompletions() {
            return .consumed
        }
        if isTurnRunning {
            if !isEscape, !editor.text.isEmpty {
                editor.reset()
                detachHistory()
                pendingConfirmation = nil
                return .consumed
            }
            return .cancelTurn
        }
        if !editor.text.isEmpty {
            if isEscape {
                if confirm(key: "Esc", label: "clear") {
                    editor.reset()
                    detachHistory()
                }
            } else {
                editor.reset()
                detachHistory()
                pendingConfirmation = nil
            }
            return .consumed
        }
        guard !isEscape else { return .consumed }
        return confirm(key: "Ctrl+c", label: "quit") ? .quit : .consumed
    }

    /// The outcome of a locally handled slash command.
    private enum SlashOutcome {
        case notACommand
        case handled
        case quit
        case submit(String)
    }

    /// Run a slash command.
    ///
    /// `isTurnRunning` is what keeps a history-mutating command from firing
    /// while the sampler is streaming. It is deliberately a parameter rather
    /// than read from state: the two callers are the idle-loop submit and the
    /// mid-turn submit, and making each say which it is means the guarantee
    /// cannot be lost again by someone adding a third caller.
    private func runSlashCommand(
        _ text: String,
        isTurnRunning: Bool = false
    ) async throws -> SlashOutcome {
        guard case .command(let invocation) = PagerCommandParser.parse(text) else {
            return .notACommand
        }
        switch commands.resolve(invocation) {
        case .unknown(let name):
            try await emit(.notice("unknown command: /\(name)"))
            return .handled
        case .unavailable(_, let reason):
            try await emit(.notice(reason))
            return .handled
        case .available(let command) where isTurnRunning
            && command.mutatesConversationHistory:
            // Queue it as written, so it runs against a settled conversation
            // once the turn ends — upstream's `CommandResult::QueueCommand`.
            try await enqueue(text)
            try await emit(.notice(
                "/\(command.name) edits the conversation, so it will run when this turn finishes."
            ))
            return .handled
        case .available(let command):
            if localCommandNames.contains(command.name) {
                guard let localCommandHandler else {
                    try await emit(.notice("/\(command.name) is unavailable in this session"))
                    return .handled
                }
                if let notice = try await localCommandHandler(invocation), !notice.isEmpty {
                    try await emit(.notice(notice))
                }
                return .handled
            }
            if customCommandNames.contains(command.name) {
                guard let customCommandHandler else {
                    try await emit(.notice("/\(command.name) is unavailable in this session"))
                    return .handled
                }
                guard let generatedPrompt = try await customCommandHandler(invocation) else {
                    try await emit(.notice("/\(command.name) could not load its skill definition"))
                    return .handled
                }
                return .submit(generatedPrompt)
            }
            switch command.name {
            case "quit":
                return .quit
            case "new":
                try await startNewSession()
                return .handled
            case "help":
                try await emit(.overlay(.help))
                return .handled
            case "home":
                try await emit(.overlay(.welcomeScreen))
                return .handled
            case "workflows":
                try await emit(.overlay(.workflows))
                return .handled
            case "history":
                try await emit(.overlay(.promptHistory(entries: history)))
                return .handled
            case "queue":
                try await emit(.overlay(.promptQueue(
                    entries: await promptQueue.orderedTexts
                )))
                return .handled
            case "context":
                try await emit(.overlay(.contextUsage))
                return .handled
            case "usage":
                // Non-consumer arm only (`usage.rs:57-61`): bare `/usage`
                // shows the readout; any argument is refused with upstream's
                // copy. `show`/`manage` belong to the billing surface this
                // port does not have.
                let usageArgument = Self.rejoined(invocation.arguments)
                guard usageArgument.isEmpty else {
                    try await emit(.notice(
                        "Unknown argument: \(usageArgument). Use /usage"
                    ))
                    return .handled
                }
                try await emit(.overlay(.usage))
                return .handled
            case "resume":
                // Bare `/resume` opens the picker (`resume.rs:21-23`); the
                // argument form exists only as the picker's return path — a
                // selected row round-trips as `/resume <session-id>`.
                let sessionArgument = Self.rejoined(invocation.arguments)
                guard !sessionArgument.isEmpty else {
                    try await emit(.overlay(.sessionPicker))
                    return .handled
                }
                try await resumeStoredSession(sessionID: sessionArgument)
                return .handled
            case "btw":
                let question = Self.rejoined(invocation.arguments)
                guard !question.isEmpty else {
                    try await emit(.notice("Usage: /btw <question>"))
                    return .handled
                }
                // Upstream's SendBtw bypasses the prompt queue (`btw.rs:3-4`).
                // The port's equivalent out-of-band channel is the
                // interjection buffer: the question leads the next prompt
                // instead of queueing behind the backlog.
                try await interject(question, kind: .followUp)
                return .handled
            case "mcps":
                try await emit(.overlay(.mcpServers))
                return .handled
            case "effort":
                let level = Self.rejoined(invocation.arguments)
                try await emit(.overlay(.reasoningEffort(
                    query: level.isEmpty ? nil : level
                )))
                return .handled
            case "rename":
                let title = Self.rejoined(invocation.arguments)
                guard !title.isEmpty else {
                    // Upstream's empty-title refusal (`rename.rs:48-50`).
                    try await emit(.notice("Usage: /rename <new title>"))
                    return .handled
                }
                try await emit(.overlay(.renameSession(title: title)))
                return .handled
            case "session-info":
                try await emit(.overlay(.sessionInfo))
                return .handled
            case "copy":
                let (index, path) = Self.parseCopyArguments(invocation.arguments)
                try await emit(.overlay(.copyResponse(index: index, filePath: path)))
                return .handled
            case "export":
                let path = invocation.arguments.first
                try await emit(.overlay(.exportConversation(filePath: path)))
                return .handled
            case "transcript":
                // Arguments are ignored — same dispatch either way
                // (`transcript.rs:36-41`, `Action::OpenTranscriptPager`).
                try await emit(.overlay(.transcriptPager))
                return .handled
            case "find":
                let query = invocation.arguments
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await emit(.overlay(.scrollbackSearch(query: query.isEmpty ? nil : query)))
                return .handled
            case "multiline":
                try await setMultiline(!modes.isMultiline)
                return .handled
            case "vim-mode":
                modes.isVimMode.toggle()
                try await emit(.modeChanged(modes))
                try await emit(.notice(modes.isVimMode
                    ? "Vim scrollback keys on — Tab to focus the scrollback, then j/k/h/l/e/y."
                    : "Vim scrollback keys off — the scrollback still takes arrows, Enter and the Ctrl chords."))
                return .handled
            case "compact":
                let instructions = invocation.arguments
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await emit(.overlay(.compact(
                    instructions: instructions.isEmpty ? nil : instructions
                )))
                return .handled
            case "settings":
                try await emit(.overlay(.settings(deepLinkKey: nil)))
                return .handled
            case "privacy":
                // The same modal aimed at one row — upstream's
                // `OpenSettingsFocus{key: CODING_DATA_SHARING_KEY}`.
                try await emit(.overlay(.settings(deepLinkKey: Self.codingDataSharingKey)))
                return .handled
            case "theme":
                let name = invocation.arguments
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await emit(.overlay(.themePicker(query: name.isEmpty ? nil : name)))
                return .handled
            case "tutorial":
                try await emit(.overlay(.tutorial))
                return .handled
            case "rewind":
                try await emit(.overlay(.rewind(
                    argument: invocation.arguments.joined(separator: " ")
                )))
                return .handled
            case "jump":
                try await emit(.overlay(.jumpPicker))
                return .handled
            case "delete":
                // Never confirmed from the command itself — the renderer raises
                // a confirmation and only its row sends `confirmed: true`.
                try await emit(.overlay(.deleteSession(confirmed: false)))
                return .handled
            case "remember":
                try await emit(.overlay(.remember(text: Self.rejoined(invocation.arguments))))
                return .handled
            case "recall":
                try await emit(.overlay(.recall(query: Self.rejoined(invocation.arguments))))
                return .handled
            case "flush":
                try await emit(.overlay(.flush(text: Self.rejoined(invocation.arguments))))
                return .handled
            case "goal":
                try await emit(.overlay(.goal(argument: Self.rejoined(invocation.arguments))))
                return .handled
            case "gboom":
                try await emit(.overlay(.easterEgg))
                return .handled
            case "model":
                // The parser has already split and unquoted the arguments;
                // rejoining on a single space is what upstream resolves against
                // (`model.rs` trims `args` and matches the whole string first,
                // so a multi-word display name like `Grok 4.5` survives).
                let selector = invocation.arguments
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await emit(.overlay(.modelPicker(query: selector.isEmpty ? nil : selector)))
                return .handled
            case "toggle-mouse-reporting":
                try await emit(.overlay(.toggleMouseReporting))
                return .handled
            default:
                try await emit(.notice("unknown command: /\(command.name)"))
                return .handled
            }
        }
    }

    /// Put a parsed argument list back together as the user typed it.
    ///
    /// The parser splits and unquotes; every command whose argument is prose
    /// rather than a token list wants the whole tail back, and rejoining on a
    /// single space is what upstream's `args.trim()` receives.
    private static func rejoined(_ arguments: [String]) -> String {
        arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startNewSession() async throws {
        guard let currentRequest else {
            throw OpenGrokPagerInteractiveError.sessionFailed("no active request for new session")
        }
        let sessionID = try await runtime.replaceSession(from: currentRequest)
        lastSessionID = sessionID
        activeSessionID = nil
        editor.reset()
        await promptQueue.removeAll()
        interjections.clear()
        try await emit(.sessionReplaced(sessionID: sessionID))
    }

    /// Commit a `/resume` selection: swap the runtime to the stored session
    /// and tell the renderer to paint its transcript.
    ///
    /// A refused resume is a notice, not a run failure — the current session
    /// is untouched on every error path because the runtime mutates nothing
    /// until its own swap succeeds. Queue and interjections are cleared like
    /// `/new`: they were written against the conversation being left behind.
    private func resumeStoredSession(sessionID: String) async throws {
        let resumedID: String
        do {
            resumedID = try await runtime.resumeSession(sessionID: sessionID)
        } catch {
            try await emit(.notice(
                "Could not resume session \(sessionID): \(String(describing: error))"
            ))
            return
        }
        lastSessionID = resumedID
        activeSessionID = nil
        editor.reset()
        await promptQueue.removeAll()
        interjections.clear()
        try await emit(.sessionResumed(sessionID: resumedID))
    }

    /// `/copy [N] [file]` — `N` is 1-based and counts back from the newest
    /// response, so a bare `/copy` is `/copy 1`. A single non-numeric argument
    /// is the file, which is what upstream's parse does too.
    static func parseCopyArguments(_ arguments: [String]) -> (index: Int, filePath: String?) {
        var index = 1
        var remaining = arguments[...]
        if let first = remaining.first, let parsed = Int(first), parsed > 0 {
            index = parsed
            remaining = remaining.dropFirst()
        }
        let path = remaining.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (index, path?.isEmpty == false ? path : nil)
    }

    /// Service an application chord. Only the commands the port routes
    /// somewhere real are ever bound, so the remaining cases are unreachable
    /// rather than silently ignored.
    private func handleGlobal(
        _ command: OpenGrokPagerGlobalCommand,
        isTurnRunning: Bool = false
    ) async throws {
        switch command {
        case .commandPalette:
            try await emit(.overlay(.commandPalette(rows: paletteRows)))
        case .shortcutsHelp:
            try await emit(.overlay(.shortcutsHelp))
        case .toggleQueue:
            try await emit(.overlay(.promptQueue(entries: await promptQueue.orderedTexts)))
        case .modelPicker:
            try await emit(.overlay(.modelPicker(query: nil)))
        case .openSettings:
            try await emit(.overlay(.settings(deepLinkKey: nil)))
        case .newSession:
            // `requires_confirmation` upstream (`defaults.rs:758`) — throwing
            // away a session on one keystroke is not recoverable.
            guard confirm(key: "Ctrl+n", label: "start a new session") else {
                try await emit(.promptChanged(promptState()))
                return
            }
            if isTurnRunning {
                try await enqueue("/new")
                try await emit(.notice(
                    "/new edits the conversation, so it will run when this turn finishes."
                ))
                return
            }
            try await startNewSession()
        case .cyclePermissionMode, .toggleAlwaysApprove:
            try await emit(.global(command))
        case .toggleTodos, .toggleTasks, .sendToBackground,
             .openDashboard, .openSessions, .openExtensions:
            // Unbound in `globalAction(for:)` until the backing surface exists.
            break
        }
    }

    /// Body of the `/help` modal. Public so the render layer can lay it out as
    /// a text overlay without duplicating the vocabulary.
    public static let helpText = """
    Commands
      /help                     Browse commands and keyboard shortcuts
      /model [name]  /m         Switch the active model
      /effort <level>           Set reasoning effort for the current model
      /new    /clear            Start a new session
      /resume                   Resume a previous session
      /rename <title>  /title   Rename the current session
      /home   /welcome          Return to the welcome screen
      /history                  Search prompt history
      /queue                    Prompts queued behind the running turn
      /btw <question>           Ask a side question without interrupting
      /context                  View context usage
      /usage  /cost             View session token usage
      /session-info             Show session info
      /mcps                     Show MCP server status
      /copy [N] [file]          Copy a response to the clipboard or a file
      /export [file]            Export the conversation
      /transcript  /log         View the transcript in your pager ($PAGER)
      /find [text]              Search the conversation scrollback
      /jump                     Jump to a turn in the conversation
      /rewind [n]  /undo        Rewind to before a previous turn
      /delete                   Delete this session's stored transcript
      /compact [instructions]   Compact conversation history
      /remember [text]          Save a memory note
      /recall <query>           Search workspace memory
      /flush <notes>            Write notes to this session's memory log
      /goal [objective]         Set or inspect the session goal
      /multiline  /ml           Swap what Enter and Shift+Enter do
      /vim-mode                 Vim keys for the focused scrollback
      /settings   /config       Open the settings modal
      /privacy                  Coding data, retention and training settings
      /theme [name]  /t         Switch the color theme
      /tutorial                 Quick tips
      /workflows                Show workflow runs
      /toggle-mouse-reporting   Toggle mouse reporting (native copy/paste)
      /quit   /exit             Quit the application

    Composer
      Enter            send (queue while a turn is running)
      Shift+Enter      insert a newline — or a trailing \\ before Enter
      Ctrl+m           toggle multiline (swaps the two above)
      Tab              accept a completion, else focus the scrollback
      Esc              cancel the running turn; press twice to clear a draft
      Ctrl+c           cancel the running turn, or press twice to quit
      Ctrl+d           end input
      Ctrl+p           command palette (moves the dropdown while it is open)
      Ctrl+n           new session (moves the dropdown while it is open)
      Ctrl+.  Ctrl+x   this shortcuts sheet
      Ctrl+;  Ctrl+'   show the prompt queue
      Up / Down        prompt history on an empty composer
      PgUp / PgDn      scroll the transcript
      Home / End       jump to the top or bottom of the transcript
      Ctrl+u           scroll up half a page

    Scrollback (Tab to focus it)
      ↑ / ↓            select the previous or next block
      ← / →            collapse or expand the selected block
      Shift+← / →      previous or next turn
      Enter            open the selected block in the viewer
      Ctrl+e           expand or collapse all thinking
      Ctrl+j / Ctrl+k  scroll a line
      Tab              back to the composer
      With /vim-mode:  j k h l g G e E r y Y o O x d u, i or Space to exit

    Mouse
      Wheel            scroll the transcript, or the open overlay
      Click            choose a row in an overlay
    """

    public static func helpText(workflowsEnabled: Bool) -> String {
        guard !workflowsEnabled else { return helpText }
        return helpText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("/workflows") }
            .joined(separator: "\n")
    }

    private func transition(to newLifecycle: OpenGrokPagerInteractiveLifecycle) async throws {
        lifecycle = newLifecycle
        try await emit(.lifecycle(newLifecycle))
        // A lifecycle change is a demand change: `.running` raises fast
        // demand even before the render layer has seen a single event.
        armMotionTickerIfNeeded()
    }

    // MARK: - Motion ticker

    /// The demand right now: the render layer's report, plus what only the
    /// controller knows — that a turn is running (`tick_demand`,
    /// `app_view.rs:6078-6120` folds the same two kinds of source).
    private func currentMotionDemand() -> PagerTickDemand {
        var state = externalMotionState
        state.hasRunningTurn = state.hasRunningTurn || lifecycle == .running
        return state.demand
    }

    /// Arm the ticker when demanded and none is pending — `schedule_tick`
    /// (`event_loop.rs:3172-3189`). Idempotent; called from every place the
    /// demand can rise (run start, lifecycle transitions, `setMotionState`).
    private func armMotionTickerIfNeeded() {
        guard running, motionTicker == nil, currentMotionDemand() != .none else { return }
        // The unstructured Task inherits the actor's isolation, so the loop
        // body runs on the controller and `Task.sleep` suspends without
        // holding it.
        motionTicker = Task { await self.runMotionTicker() }
    }

    private func runMotionTicker() async {
        defer { motionTicker = nil }
        while !Task.isCancelled, running {
            let demand = currentMotionDemand()
            // Demand fell to none: park. The next `armMotionTickerIfNeeded`
            // re-arms — this loop never spins on an idle screen.
            guard demand != .none else { return }
            // `.slow` is the welcome shimmer's ~12 fps (`SLOW_TICK_INTERVAL`,
            // `app_view.rs:259`); `.fast` is the configured animation fps.
            // A demand change mid-sleep is picked up on the next wake, so a
            // slow→fast rise can lag one slow interval (≤83 ms) — the same
            // bound upstream accepts between `schedule_tick` re-arms.
            let interval = demand == .slow
                ? PagerMotion.slowTickInterval
                : PagerMotion.tickInterval(fps: motionFPS)
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, running, currentMotionDemand() != .none else { return }
            do {
                try await renderer.renderAnimationTick(makeAnimationFrame(demand: demand))
            } catch {
                // A renderer that throws on a tick gets no more ticks: a
                // still UI beats a 30 Hz error loop. The cost is deliberate —
                // motion stays off for the rest of the run even if the
                // renderer recovers, because a tick has no channel to report
                // failure without failing the run itself.
                return
            }
        }
    }

    private func makeAnimationFrame(demand: PagerTickDemand) -> OpenGrokPagerAnimationFrame {
        // DispatchTime is the monotonic clock available at this package's
        // macOS 12 floor (ContinuousClock is 13+).
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let epoch = motionEpochNanos ?? nowNanos
        if motionEpochNanos == nil { motionEpochNanos = epoch }
        let seconds = Double(nowNanos &- epoch) / 1_000_000_000
        let tick = Int(seconds / PagerMotion.tickInterval(fps: motionFPS))
        return OpenGrokPagerAnimationFrame(tick: tick, seconds: seconds, demand: demand)
    }

    private func emit(_ event: OpenGrokPagerInteractiveEvent) async throws {
        try await renderer.render(event)
        try await output.forward(event)
    }

    private func cancelActiveSession() async {
        guard let activeSession, !activeSessionCancelled else { return }
        activeSessionCancelled = true
        await activeSession.cancel()
    }

    private func closeActiveSession() async {
        guard let activeSession, !activeSessionClosed else { return }
        activeSessionClosed = true
        await activeSession.close()
        self.activeSession = nil
        activeSessionID = nil
    }

    private func isTerminal(_ event: OpenGrokPagerEvent) -> Bool {
        switch event {
        case .completed, .cancelled:
            return true
        case .lifecycle, .output, .status, .tool, .permissionRequested:
            return false
        }
    }

    private static func controlAction(for event: InputEvent) -> PromptAction? {
        guard case .key(let key) = event else { return nil }
        if key.key == .escape { return .escape }
        guard key.modifiers.contains(.control) else {
            if key.key == .char("\u{3}") { return .interrupt }
            if key.key == .char("\u{4}") { return .eof }
            return nil
        }
        switch key.key {
        case .char("c"), .char("C"):
            return .interrupt
        case .char("d"), .char("D"):
            return .eof
        default:
            return nil
        }
    }

    private static func makeThrowingStream(
        from stream: AsyncStream<InputEvent>
    ) -> AsyncThrowingStream<InputEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for await event in stream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}
