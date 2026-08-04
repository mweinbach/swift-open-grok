import Foundation
import OpenGrokPagerMinimal
import OpenGrokTerminalCore

public actor OpenGrokPagerInteractiveController: OpenGrokPagerInteractiveFrontend {
    private enum Control: Sendable {
        case cancel
        case eof
        case shutdown
    }

    private enum PromptAction: Sendable {
        case changed
        case submit
        case cancel
        case eof
        case ignored
    }

    private enum TurnOutcome: Sendable {
        case finished(OpenGrokPagerRuntimeResult)
        case eof
        case cancelled
        case shutdown
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

        init(text: String) {
            characters = Array(text)
            cursor = characters.count
        }

        var text: String { String(characters) }

        var state: OpenGrokPagerInteractivePromptState {
            OpenGrokPagerInteractivePromptState(text: text, cursorOffset: cursor)
        }

        mutating func apply(_ event: InputEvent) -> PromptAction {
            switch event {
            case .paste(let value):
                insert(Array(value))
                return value.isEmpty ? .ignored : .changed
            case .key(let key):
                return apply(key)
            case .mouse, .focusGained, .focusLost, .resize:
                return .ignored
            }
        }

        mutating func reset() {
            characters.removeAll(keepingCapacity: true)
            cursor = 0
        }

        private mutating func apply(_ event: KeyEvent) -> PromptAction {
            if let control = controlAction(for: event) {
                return control
            }

            switch event.key {
            case .enter:
                return .submit
            case .escape:
                return .cancel
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
                guard cursor != 0 else { return .ignored }
                cursor = 0
                return .changed
            case .end:
                guard cursor != characters.count else { return .ignored }
                cursor = characters.count
                return .changed
            case .char(let character):
                if character == "\r" || character == "\n" {
                    return .submit
                }
                if character == "\u{3}" {
                    return .cancel
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
            case .tab, .backTab, .up, .down, .pageUp, .pageDown, .insert, .f, .null:
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
            case "c": return .cancel
            case "d": return .eof
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
    private var pendingInput: [InputEvent] = []

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
            prompt: editor.state,
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
        pendingInput.removeAll(keepingCapacity: false)
        let mailbox = SignalMailbox()
        signalMailbox = mailbox
        let inputReader = ThrowingStreamReader(input)
        let inputPumpGate = InputPumpGate()
        self.inputPumpGate = inputPumpGate
        inputPump = Task {
            while !Task.isCancelled {
                guard await inputPumpGate.waitUntilAllowed() else { return }
                let read = await inputReader.next()
                await inputPumpGate.pause()
                switch read {
                case .element(let event):
                    switch Self.controlAction(for: event) {
                    case .cancel:
                        await mailbox.send(.control(.cancel), priority: true)
                    case .eof:
                        await mailbox.send(.control(.eof), priority: true)
                    case .none, .some(.changed), .some(.submit), .some(.ignored):
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
            try await emit(.promptChanged(editor.state))

            if let initialSession {
                let initialRequest = request
                if !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submittedPrompts.append(request.prompt)
                }
                let turnOutcome = try await runTurn(
                    session: initialSession,
                    request: initialRequest,
                    mailbox: mailbox,
                    inputPumpGate: inputPumpGate
                )
                switch turnOutcome {
                case .finished(let result):
                    lastSessionID = result.sessionID ?? lastSessionID
                    if result.lifecycle == .cancelled {
                        try await emit(.cancelled)
                        outcome = .cancelled
                    } else {
                        completedTurnCount += 1
                        editor.reset()
                        try await transition(to: .editing)
                        try await emit(.promptChanged(editor.state))
                    }
                case .eof:
                    try await emit(.eof)
                    outcome = .eof
                case .cancelled:
                    try await emit(.cancelled)
                    outcome = .cancelled
                case .shutdown:
                    try await emit(.shutdown)
                    outcome = .shutdown
                }
            } else {
                try await transition(to: .editing)
            }

            while outcome == .completed {
                try Task.checkCancellation()
                let signal: Signal
                if !pendingInput.isEmpty {
                    signal = .input(.element(pendingInput.removeFirst()))
                } else {
                    guard let nextSignal = await mailbox.next() else {
                        try await emit(.eof)
                        outcome = .eof
                        continue
                    }
                    signal = nextSignal
                }
                switch signal {
                case .session:
                    continue
                case .control(let control):
                    switch control {
                    case .cancel:
                        try await emit(.cancelled)
                        outcome = .cancelled
                    case .eof:
                        try await emit(.eof)
                        outcome = .eof
                    case .shutdown:
                        try await emit(.shutdown)
                        outcome = .shutdown
                    }
                case .input(let read):
                    switch read {
                    case .element(let event):
                        switch editor.apply(event) {
                        case .changed:
                            try await emit(.promptChanged(editor.state))
                            await inputPumpGate.resume()
                        case .submit:
                            let prompt = editor.text
                            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                try await emit(.notice("prompt cannot be empty"))
                                await inputPumpGate.resume()
                                continue
                            }

                            let turnRequest = OpenGrokPagerRequest(
                                prompt: prompt,
                                mode: request.mode,
                                sessionID: lastSessionID ?? request.sessionID,
                                metadata: request.metadata
                            )
                            let session = try await runtime.makeSession(for: turnRequest)
                            submittedPrompts.append(prompt)
                            let turnOutcome = try await runTurn(
                                session: session,
                                request: turnRequest,
                                mailbox: mailbox,
                                inputPumpGate: inputPumpGate
                            )
                            switch turnOutcome {
                            case .finished(let result):
                                lastSessionID = result.sessionID ?? lastSessionID
                                if result.lifecycle == .cancelled {
                                    try await emit(.cancelled)
                                    outcome = .cancelled
                                } else {
                                    completedTurnCount += 1
                                    editor.reset()
                                    try await transition(to: .editing)
                                    try await emit(.promptChanged(editor.state))
                                }
                            case .eof:
                                try await emit(.eof)
                                outcome = .eof
                            case .cancelled:
                                try await emit(.cancelled)
                                outcome = .cancelled
                            case .shutdown:
                                try await emit(.shutdown)
                                outcome = .shutdown
                            }
                        case .cancel:
                            try await emit(.cancelled)
                            outcome = .cancelled
                        case .eof:
                            try await emit(.eof)
                            outcome = .eof
                        case .ignored:
                            await inputPumpGate.resume()
                            continue
                        }
                    case .end:
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
                        case .lifecycle, .output, .status, .permissionRequested:
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
                        switch Self.controlAction(for: event) {
                        case .cancel:
                            await cancelActiveSession()
                            turnOutcome = .cancelled
                        case .eof:
                            await cancelActiveSession()
                            turnOutcome = .eof
                        case .none, .some(.changed), .some(.submit), .some(.ignored):
                            pendingInput.append(event)
                            await inputPumpGate.resume()
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
        case .lifecycle, .output, .status, .permissionRequested:
            return false
        }
    }

    private static func controlAction(for event: InputEvent) -> PromptAction? {
        guard case .key(let key) = event else { return nil }
        if key.key == .escape { return .cancel }
        guard key.modifiers.contains(.control) else {
            if key.key == .char("\u{3}") { return .cancel }
            if key.key == .char("\u{4}") { return .eof }
            return nil
        }
        switch key.key {
        case .char("c"), .char("C"):
            return .cancel
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
