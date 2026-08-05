import Foundation
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

            switch event.key {
            case .enter:
                // Enter always submits; Tab accepts the highlighted completion.
                // Letting Enter accept would make a fully typed command name
                // need two presses, since its own row stays in the menu.
                return .submit
            case .escape:
                return .escape
            case .tab:
                return completions.isEmpty ? .ignored : .completionAccept
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
                    return .submit
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
            case .backTab, .insert, .f, .null:
                return .ignored
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
            case "p": return completions.isEmpty ? nil : .completionMove(-1)
            case "n": return completions.isEmpty ? nil : .completionMove(1)
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

    private let commands = PagerCommandRegistry(
        commands: OpenGrokPagerInteractiveController.builtinCommands
    )

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

    public func state() -> OpenGrokPagerInteractiveState {
        OpenGrokPagerInteractiveState(
            lifecycle: lifecycle,
            prompt: promptState(),
            submittedPrompts: submittedPrompts,
            completedTurnCount: completedTurnCount,
            activeSessionID: activeSessionID,
            lastSessionID: lastSessionID,
            terminalRestored: terminalRestored
        )
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
                        let action = applyEditorEvent(event)
                        switch action {
                        case .changed, .historyPrevious, .historyNext,
                             .completionMove, .completionAccept:
                            try await emit(.promptChanged(promptState()))
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
                                    try await enqueue(prompt)
                                    await inputPumpGate.resume()
                                }
                            case .viewport(let command):
                                try await emit(.viewport(command))
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
            try await emit(.queueChanged(queuedPromptCount: await promptQueue.count))

            let turnRequest = OpenGrokPagerRequest(
                prompt: entry.text,
                mode: request.mode,
                sessionID: lastSessionID ?? request.sessionID,
                metadata: request.metadata
            )
            let session = try await runtime.makeSession(for: turnRequest)
            submittedPrompts.append(entry.text)
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

    // MARK: - Prompt behavior

    /// Feed one input event to the composer and apply the bookkeeping every
    /// caller shares — confirmation disarming, history detach, completion
    /// movement. Returns the action for the caller to act on.
    private func applyEditorEvent(_ event: InputEvent) -> PromptAction {
        let action = editor.apply(event)
        // Any key other than the armed one clears a pending confirmation,
        // matching `app_view.rs`'s arm lifetime.
        switch action {
        case .escape, .interrupt, .ignored, .resize:
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
                editor.replace(with: editor.completions[index].name)
            }
            editor.completions = []
            editor.selectedCompletion = nil
        default:
            break
        }
        return action
    }

    /// Slash commands the TUI honors locally. The reference registers ~70 and
    /// routes most of them to a pager `Action`; this port lists only the ones
    /// backed by working Swift wiring, so the dropdown never offers a no-op.
    private static let builtinCommands: [PagerCommandDefinition] = [
        PagerCommandDefinition(
            name: "help",
            summary: "Browse commands and keyboard shortcuts"
        ),
        PagerCommandDefinition(
            name: "model",
            summary: "Pick the model for this session"
        ),
        PagerCommandDefinition(
            name: "workflows",
            summary: "Watch background workflow runs"
        ),
        PagerCommandDefinition(
            name: "clear",
            aliases: ["new"],
            summary: "Start a new session"
        ),
        PagerCommandDefinition(
            name: "toggle-mouse-reporting",
            summary: "Toggle mouse reporting (native copy/paste)"
        ),
        PagerCommandDefinition(
            name: "quit",
            aliases: ["exit"],
            summary: "Quit the application"
        )
    ]

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
        let suggestions = commands
            .completions(for: editor.text)
            .prefix(6)
            .map {
                OpenGrokPagerCommandSuggestion(
                    name: $0.displayName,
                    summary: $0.summary,
                    isAvailable: $0.availability.isAvailable
                )
            }
        editor.completions = Array(suggestions)
        editor.selectedCompletion = editor.completions.isEmpty ? nil : 0
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

    private func runSlashCommand(_ text: String) async throws -> SlashOutcome {
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
        case .available(let command):
            switch command.name {
            case "quit":
                return .quit
            case "clear":
                lastSessionID = nil
                try await emit(.notice("started a new session"))
                return .handled
            case "help":
                try await emit(.overlay(.help))
                return .handled
            case "workflows":
                try await emit(.overlay(.workflows))
                return .handled
            case "model":
                try await emit(.overlay(.modelPicker))
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

    /// Body of the `/help` modal. Public so the render layer can lay it out as
    /// a text overlay without duplicating the vocabulary.
    public static let helpText = """
    Commands
      /help                     Browse commands and keyboard shortcuts
      /model                    Pick the model for this session
      /clear  /new              Start a new session
      /toggle-mouse-reporting   Toggle mouse reporting (native copy/paste)
      /quit   /exit             Quit the application

    Keys
      Enter            send (queue while a turn is running)
      Esc              cancel the running turn; press twice to clear a draft
      Ctrl+c           cancel the running turn, or press twice to quit
      Ctrl+d           end input
      Up / Down        prompt history on an empty composer
      PgUp / PgDn      scroll the transcript
      Home / End       jump to the top or bottom of the transcript
      Ctrl+u           scroll up half a page
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
