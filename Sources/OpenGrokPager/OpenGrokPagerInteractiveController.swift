import Foundation
import OpenGrokInterjection
import OpenGrokPagerCommandUI
import OpenGrokPagerMinimal
import OpenGrokPromptQueue
import OpenGrokTerminalCore

public actor OpenGrokPagerInteractiveController: OpenGrokPagerInteractiveFrontend {
    private enum Control: Sendable {
        /// A user Esc or Ctrl+C, fast-pathed ahead of queued input so it lands
        /// promptly during a busy turn.
        case interrupt(isEscape: Bool)
        /// An external `cancel()` — unlike an interrupt this always ends the run.
        case cancel
        case eof
        case shutdown
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
        case session(StreamRead<OpenGrokPagerEvent>)
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
        }

        mutating func replace(with value: String) {
            characters = Array(value)
            cursor = characters.count
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
                return .viewport(.pageUp)
            case .pageDown:
                return .viewport(.pageDown)
            case .backspace:
                guard cursor > 0 else { return .ignored }
                characters.remove(at: cursor - 1)
                cursor -= 1
                return .changed
            case .delete:
                guard cursor < characters.count else { return .ignored }
                characters.remove(at: cursor)
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
    private var activeSessionID: String?
    private var lastSessionID: String?
    private var terminalRestored = false
    private var running = false
    private var rendererBegan = false
    private var shutdownRequested = false
    private var activeSession: (any OpenGrokPagerSessionAdapter)?
    private var activeSessionCancelled = false
    private var activeSessionClosed = false
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

    /// Which region owns the keyboard. `Tab` moves it; nothing else does.
    private var focus: OpenGrokPagerFocusRegion = .prompt
    private var modes = OpenGrokPagerInputModes()

    /// Interjections the user sent mid-turn with `Ctrl+Enter` or, under
    /// `enter_steers`, a bare `Enter`. Drained into the next prompt so a
    /// steer that arrives after the sampler has already committed to the turn
    /// is never silently dropped.
    private let interjections = EventQueue<KindedInterjection<String>>()

    private let commands = PagerCommandRegistry(
        commands: OpenGrokPagerInteractiveController.builtinCommands
    )

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
        output: any OpenGrokPagerInteractiveOutputAdapter
    ) {
        self.input = input
        self.runtime = runtime
        self.renderer = renderer
        self.output = output
    }

    public init(
        input: AsyncStream<InputEvent>,
        runtime: any OpenGrokPagerRuntimeAdapter,
        renderer: any OpenGrokPagerInteractiveRenderAdapter,
        output: any OpenGrokPagerInteractiveOutputAdapter
    ) {
        self.init(
            input: Self.makeThrowingStream(from: input),
            runtime: runtime,
            renderer: renderer,
            output: output
        )
    }

    /// Install the argument-completion source. Call before `run`.
    public func setArgumentSuggestions(
        _ provider: (@Sendable (String, String) -> [OpenGrokPagerCommandSuggestion])?
    ) {
        argumentSuggestions = provider
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

    /// Seed the runtime-toggleable modes. Call before `run`; after that they
    /// belong to `/multiline`, `/vim-mode` and `Ctrl+M`.
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
        rendererBegan = false
        terminalRestored = false
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
                    if !isEscapeHatch,
                       let routing = try? await renderer.handleInput(event),
                       routing == .consumed
                    {
                        await inputPumpGate.resume()
                        continue
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
                            try await handleGlobal(command)
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

        let sessionTask = Task {
            var reachedTerminalEvent = false
            do {
                for try await event in session.events {
                    await mailbox.send(.session(.element(event)))
                    if isTerminal(event) {
                        reachedTerminalEvent = true
                        break
                    }
                }
                if !reachedTerminalEvent {
                    await mailbox.send(.session(.end))
                }
            } catch is CancellationError {
                return
            } catch {
                await mailbox.send(.session(.failure(String(describing: error))))
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
                case .session(let read):
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
                                    // the queue. The Swift runtime has no
                                    // mid-turn injection, so "send now" ends the
                                    // running turn and starts the queued prompt.
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
                                    case .handled:
                                        recordHistory(prompt)
                                        editor.reset()
                                        try await emit(.promptChanged(promptState()))
                                        await inputPumpGate.resume()
                                    case .notACommand where modes.enterSteers:
                                        // `enter_steers` (`defs.rs:724`): the
                                        // draft joins the running turn rather
                                        // than the queue behind it.
                                        try await interject(prompt, kind: .steer)
                                        await inputPumpGate.resume()
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
                                try await handleGlobal(command)
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

    /// Put a prompt at the tail of the queue and clear the composer.
    ///
    /// Enqueuing is what `Enter` does in both states; the only difference is
    /// whether a drain follows immediately.
    private func enqueue(_ prompt: String) async throws {
        nextPromptSequence += 1
        await promptQueue.enqueue(QueueEntryMeta(
            id: "prompt-\(nextPromptSequence)",
            kind: "prompt",
            text: prompt
        ))
        recordHistory(prompt)
        editor.reset()
        try await emit(.promptChanged(promptState()))
        try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))
    }

    /// Buffer a mid-turn message instead of queueing it behind the turn.
    ///
    /// The Swift runtime has no mid-turn injection — a sampler that has already
    /// committed to a turn cannot be handed another user message — so the
    /// honest port of upstream's `InterjectPrompt` and `enter_steers` is to
    /// hold the text in `OpenGrokInterjection`'s buffer and fold it into the
    /// very next prompt, framed by `formatInterjection` exactly as the shell
    /// frames one. Nothing is dropped and nothing pretends to have steered a
    /// turn it could not reach.
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
                _ = try await runSlashCommand(entry.text)
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
                editor.selectedCompletion = ((current + offset) % count + count) % count
            }
        case .completionAccept:
            if let index = editor.selectedCompletion,
               editor.completions.indices.contains(index) {
                editor.replace(with: editor.completions[index].insertText)
            }
            editor.completions = []
            editor.selectedCompletion = nil
        default:
            break
        }
        return action
    }

    /// Slash commands the TUI honors locally. The reference registers ~71 and
    /// routes most of them to a pager `Action`; this port lists only the ones
    /// backed by working Swift wiring, so the dropdown never offers a no-op.
    ///
    /// Summaries are upstream's verbatim (`src/slash/commands/*.rs`) so the
    /// dropdown reads identically for every command both sides have.
    static let builtinCommands: [PagerCommandDefinition] = [
        PagerCommandDefinition(
            name: "quit",
            aliases: ["exit"],
            summary: "Quit the application",
            // `/q` also prefixes `/queue`; upstream registers `quit` first
            // (`slash/commands/mod.rs:78`) so the short form stays `quit`.
            priority: 1
        ),
        PagerCommandDefinition(
            name: "help",
            summary: "Browse commands and keyboard shortcuts",
            // `/h` also prefixes `/history`.
            priority: 1
        ),
        PagerCommandDefinition(
            name: "home",
            aliases: ["welcome"],
            summary: "Return to the welcome screen"
        ),
        PagerCommandDefinition(
            name: "new",
            aliases: ["clear"],
            summary: "Start a new session"
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
        PagerCommandDefinition(
            name: "context",
            summary: "View context usage"
        ),
        PagerCommandDefinition(
            name: "model",
            aliases: ["m"],
            summary: "Switch the active model",
            usage: "/model [name]"
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
        PagerCommandDefinition(
            name: "toggle-mouse-reporting",
            summary: "Toggle terminal mouse reporting (native click-drag copy/paste)"
        ),
        PagerCommandDefinition(
            name: "queue",
            summary: "List the prompts queued behind the running turn"
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
            name: "gboom",
            summary: "Hidden easter egg",
            isHidden: true
        )
    ]

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
        let suggestions: [OpenGrokPagerCommandSuggestion]
        if let argumentPhase = Self.argumentPhase(for: editor.text) {
            // Once the command name is settled the dropdown belongs to the
            // arguments — `commands.completions` would return nothing here
            // anyway, since it refuses any input containing whitespace.
            suggestions = Array(
                (argumentSuggestions?(argumentPhase.command, argumentPhase.query) ?? [])
                    .prefix(6)
            )
        } else {
            suggestions = commands
                .completions(for: editor.text)
                .prefix(6)
                .map {
                    OpenGrokPagerCommandSuggestion(
                        name: $0.displayName,
                        summary: $0.summary,
                        isAvailable: $0.availability.isAvailable
                    )
                }
        }
        editor.completions = suggestions
        editor.selectedCompletion = editor.completions.isEmpty ? nil : 0
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

    private func startNewSession() async throws {
        lastSessionID = nil
        try await emit(.notice("started a new session"))
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
    private func handleGlobal(_ command: OpenGrokPagerGlobalCommand) async throws {
        switch command {
        case .commandPalette:
            try await emit(.overlay(.commandPalette(rows: Self.paletteRows)))
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
            try await startNewSession()
        case .cyclePermissionMode, .toggleTodos, .toggleTasks, .sendToBackground,
             .toggleAlwaysApprove, .openDashboard, .openSessions, .openExtensions:
            // Unbound in `globalAction(for:)` until the backing surface exists.
            break
        }
    }

    /// Every listable command as a palette row.
    static var paletteRows: [OpenGrokPagerCommandSuggestion] {
        builtinCommands
            .filter { !$0.isHidden }
            .map { command in
                OpenGrokPagerCommandSuggestion(
                    name: "/\(command.name)",
                    summary: command.summary,
                    insertText: "/\(command.name)"
                )
            }
    }

    /// Body of the `/help` modal. Public so the render layer can lay it out as
    /// a text overlay without duplicating the vocabulary.
    public static let helpText = """
    Commands
      /help                     Browse commands and keyboard shortcuts
      /model [name]  /m         Switch the active model
      /new    /clear            Start a new session
      /home   /welcome          Return to the welcome screen
      /history                  Search prompt history
      /queue                    Prompts queued behind the running turn
      /context                  View context usage
      /session-info             Show session info
      /copy [N] [file]          Copy a response to the clipboard or a file
      /export [file]            Export the conversation
      /find [text]              Search the conversation scrollback
      /multiline  /ml           Swap what Enter and Shift+Enter do
      /vim-mode                 Vim keys for the focused scrollback
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

    private func transition(to newLifecycle: OpenGrokPagerInteractiveLifecycle) async throws {
        lifecycle = newLifecycle
        try await emit(.lifecycle(newLifecycle))
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
