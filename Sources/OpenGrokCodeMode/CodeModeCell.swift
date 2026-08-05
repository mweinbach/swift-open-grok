// CodeModeCell.swift
//
// The per-cell lifecycle actor. Ported from
// `crates/codegen/xai-grok-code-mode/src/cell_actor/mod.rs` (`run_cell`),
// `cell_actor/types.rs` (`CellState` / `CellPhase`), and
// `cell_actor/callbacks.rs` (`spawn_tool`, `spawn_notification`,
// `finish_callbacks`).
//
// The Rust actor is a `tokio::select!` loop over four sources: the
// cancellation token, the observation command channel, the yield timer, and
// the runtime event channel. Swift actors serialize those four sources for
// free, so this port keeps the Rust *state machine* verbatim while
// expressing each source as an actor entry point:
//
//   Rust `select!` arm            this port
//   --------------------------    ------------------------------------
//   cancellation_token.cancelled  `beginTerminationLocally()` (fired by
//                                 the cell token's cancel handler)
//   command_rx (Observe)          `observe(_:)`
//   yield_timer                   `yieldTimerFired(generation:)`
//   event_rx                      `handle(_:)` from the event pump task
//   event_rx == None              `runtimeStreamClosed()`
//
// `CellState`'s mutex disappears: the actor *is* the linearization point
// for the phase machine, which is exactly the invariant the Rust comment on
// `CellState` (cell_actor/types.rs:99) describes.

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokJavaScriptRuntime
import OpenGrokShared

/// Session-side callbacks a cell needs. Mirrors the `CellHost` trait
/// (cell_actor/types.rs:40).
protocol CodeModeCellHost: Sendable {
    func invokeTool(
        _ invocation: CodeModeCellToolCall,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<JSONValue, CodeModeError>

    func notify(
        callId: String,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError>

    /// Publish the cell's stored-value writes. Returns false when the cell
    /// was cancelled before the session could commit, which rejects the
    /// completion exactly as `commit_completion` does (session_runtime/mod.rs:273).
    func commitStoredValues(
        _ writes: [String: JSONValue],
        cancellationToken: CodeModeCancellationToken
    ) async -> Bool

    /// The cell can no longer be routed to. Mirrors `CellHost::closed`.
    func cellClosed() async
}

actor CodeModeCell {
    // MARK: Phase machine (cell_actor/types.rs:113)

    private enum Phase {
        case running
        case terminating(TerminationWaiter)
        case completed(CodeModeCellEvent)
        case completionClaimed(CodeModeCellEvent)
        case tombstone
    }

    /// One-shot delivery handle, resolvable before anyone awaits it.
    ///
    /// The buffering matters for the `execute` handoff: Rust hands the cell
    /// actor a `oneshot::Sender` at creation (cell_actor/mod.rs:65), so an
    /// event that lands before the caller awaits `initial_response` is still
    /// delivered. Guarantees the exactly-once continuation discipline the
    /// protocol's `StartedCell` also promises.
    ///
    /// Only ever touched from inside the cell actor.
    private final class Waiter {
        typealias Outcome = Result<CodeModeCellEvent, CodeModeCellError>

        private var continuation: CheckedContinuation<Outcome, Never>?
        private var stored: Outcome?
        private var resolved = false

        var isPending: Bool { !resolved }

        /// Resolve exactly once. Returns false if already resolved.
        @discardableResult
        func resume(_ value: Outcome) -> Bool {
            guard !resolved else { return false }
            resolved = true
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: value)
            } else {
                stored = value
            }
            return true
        }

        func attach(_ continuation: CheckedContinuation<Outcome, Never>) {
            if let stored {
                self.stored = nil
                continuation.resume(returning: stored)
                return
            }
            self.continuation = continuation
        }
    }

    private typealias TerminationWaiter = Waiter

    private struct Observer {
        var mode: CodeModeObserveMode
        var waiter: Waiter
    }

    // MARK: State

    let cellId: CellId
    private let host: CodeModeCellHost
    private let cancellationToken: CodeModeCancellationToken
    private let callbackCancellationToken: CodeModeCancellationToken
    private let runtime: JavaScriptCellRuntime

    private var phase: Phase = .running
    private var observer: Observer?
    private let initialWaiter: Waiter
    private var contentItems: [FunctionCallOutputContentItem] = []
    private var pendingToolCallIds: [String] = []
    private var pendingFrontierReady = false
    private var terminating = false
    private var runtimeClosed = false
    private var runtimePaused = false
    private var finished = false

    private var yieldTimerGeneration: UInt64 = 0
    private var yieldTimerTask: Task<Void, Never>?
    private var eventPumpTask: Task<Void, Never>?
    // Kept apart because `finish_callbacks` (cell_actor/callbacks.rs:79)
    // drains notifications before cancelling, then cancels before draining
    // tool calls — a tool call still in flight at completion must not be
    // waited on forever.
    private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    private var toolTasks: [UUID: Task<Void, Never>] = [:]

    init(
        cellId: CellId,
        host: CodeModeCellHost,
        runtime: JavaScriptCellRuntime,
        cancellationToken: CodeModeCancellationToken,
        initialObserveMode: CodeModeObserveMode
    ) {
        self.cellId = cellId
        self.host = host
        self.runtime = runtime
        self.cancellationToken = cancellationToken
        self.callbackCancellationToken = cancellationToken.childToken()

        // The exec observation is attached before the runtime can produce
        // anything, matching `CellActor::prepare` (cell_actor/mod.rs:84).
        let initialWaiter = Waiter()
        self.initialWaiter = initialWaiter
        self.observer = Observer(mode: initialObserveMode, waiter: initialWaiter)
    }

    /// Begin consuming runtime events and arm cancellation. Separate from
    /// `init` only because an actor's initializer cannot touch isolated
    /// state; the session calls it before the cell is reachable, so no
    /// observation can race it.
    func start(events: AsyncStream<JavaScriptRuntimeEvent>) {
        // The token is the cancellation edge from session → cell → callbacks
        // (cell_actor/types.rs:99). Firing it is what `terminate` and
        // `shutdown` do; the handler performs Rust's `begin_termination`.
        cancellationToken.onCancel { [weak self] in
            guard let self else { return }
            Task { await self.beginTerminationLocally() }
        }
        eventPumpTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
            await self?.runtimeStreamClosed()
        }
    }

    /// The `exec` call's own observation. Mirrors
    /// `StartedCell::initial_event` (session_runtime/mod.rs:219).
    func initialEvent() async -> Result<CodeModeCellEvent, CodeModeCellError> {
        await withCheckedContinuation { continuation in
            initialWaiter.attach(continuation)
        }
    }

    // MARK: Observation (cell_actor/mod.rs:170, types.rs:264)

    func observe(_ mode: CodeModeObserveMode) async -> Result<CodeModeCellEvent, CodeModeCellError> {
        // `accepting_observations` (cell_actor/types.rs:155).
        switch phase {
        case .running, .completed:
            if cancellationToken.isCancelled { return .failure(.closed) }
        case .terminating, .completionClaimed, .tombstone:
            return .failure(.closed)
        }

        switch phase {
        case .completed(let event):
            // A buffered completion is claimed by the first observer, which
            // also ends the cell (`ObservationDelivery::Delivered`).
            phase = .tombstone
            cancellationToken.cancel()
            await finishCell()
            return .success(event)

        case .running:
            if observer != nil || terminating {
                return .failure(.busy)
            }
            if case .pendingFrontier = mode, pendingFrontierReady {
                pendingFrontierReady = false
                return .success(takePendingEvent())
            }
            let waiter = Waiter()
            observer = Observer(mode: mode, waiter: waiter)
            if runtimePaused, case .yieldAfter = mode {
                pendingFrontierReady = false
                pendingToolCallIds.removeAll()
            }
            startYieldTimer(for: mode)
            resumeForObservation(mode)
            return await withCheckedContinuation { continuation in
                waiter.attach(continuation)
            }

        case .terminating, .completionClaimed, .tombstone:
            return .failure(.closed)
        }
    }

    // MARK: Termination (cell_actor/types.rs:166)

    func terminate() async -> Result<CodeModeCellEvent, CodeModeCellError> {
        switch phase {
        case .running:
            let waiter = Waiter()
            phase = .terminating(waiter)
            cancellationToken.cancel()
            return await withCheckedContinuation { continuation in
                waiter.attach(continuation)
            }
        case .terminating, .completionClaimed:
            return .failure(.alreadyTerminating)
        case .completed(let event):
            phase = .completionClaimed(event)
            cancellationToken.cancel()
            await finishCell()
            return .success(event)
        case .tombstone:
            return .failure(.closed)
        }
    }

    /// The cancellation arm of the Rust `select!` (cell_actor/mod.rs:142).
    private func beginTerminationLocally() async {
        guard !terminating else { return }
        terminating = true
        cancelYieldTimer()
        runtime.beginTermination()
        if runtimeClosed {
            await finishTermination()
        }
    }

    // MARK: Runtime events (cell_actor/mod.rs:330)

    private func handle(_ event: JavaScriptRuntimeEvent) async {
        switch event {
        case .started:
            // The observer's budget starts when the engine does.
            if let observer { startYieldTimer(for: observer.mode) }

        case .pending:
            runtimePaused = true
            if let observer, case .pendingFrontier = observer.mode {
                cancelYieldTimer()
                pendingFrontierReady = false
                deliverToObserver(takePendingEvent())
            } else {
                pendingToolCallIds.removeAll()
                runtime.sendControl(.continue)
                runtimePaused = false
            }

        case .contentItem(let item):
            contentItems.append(item)

        case .yieldRequested:
            if let observer, case .yieldAfter = observer.mode {
                cancelYieldTimer()
                deliverYield()
            }

        case .notify(let callId, let text):
            spawnNotification(callId: callId, text: text)

        case .toolCall(let id, let name, let kind, let input):
            pendingToolCallIds.append(id)
            spawnTool(
                CodeModeCellToolCall(id: id, name: name, kind: kind, input: input)
            )

        case .result(let storedValueWrites, let errorText):
            guard !runtimeClosed else { return }
            runtimeClosed = true
            cancelYieldTimer()
            if terminating || cancellationToken.isCancelled {
                await drainCallbacks(cancelling: true)
                await finishTermination()
                return
            }
            await drainCallbacks(cancelling: false)
            await completeCell(storedValueWrites: storedValueWrites, errorText: errorText)

        case .runtimeFailed:
            // Recorded for parity with `RuntimeEvent::ThreadPanicked`; the
            // stream closing is what drives the terminal transition.
            break
        }
    }

    /// The `event_rx.recv() == None` arm (cell_actor/mod.rs:261).
    private func runtimeStreamClosed() async {
        guard !runtimeClosed else { return }
        runtimeClosed = true
        cancelYieldTimer()
        if terminating || cancellationToken.isCancelled {
            await drainCallbacks(cancelling: true)
            await finishTermination()
            return
        }
        await drainCallbacks(cancelling: false)
        await completeCell(
            storedValueWrites: [:],
            errorText: CodeModeError.runtimeEnded.message
        )
    }

    // MARK: Terminal transitions

    /// Mirrors `finish_termination` (cell_actor/mod.rs:555 + types.rs:349):
    /// the terminating caller and any waiting observer both see the event.
    private func finishTermination() async {
        let event = CodeModeCellEvent.terminated(contentItems: takeContentItems())
        let observerEvent: CodeModeCellEvent?
        switch phase {
        case .running:
            observerEvent = event
        case .terminating(let waiter):
            waiter.resume(.success(event))
            observerEvent = event
        case .completed(let completed):
            observerEvent = completed
        case .completionClaimed(let claimed):
            observerEvent = claimed
        case .tombstone:
            observerEvent = nil
        }
        phase = .tombstone
        cancellationToken.cancel()
        if let observerEvent {
            deliverToObserver(observerEvent)
        }
        await finishCell()
    }

    /// Mirrors the `commit_completion` + `deliver_completion` pair
    /// (cell_actor/mod.rs:446).
    private func completeCell(
        storedValueWrites: [String: JSONValue],
        errorText: String?
    ) async {
        let event = CodeModeCellEvent.completed(
            contentItems: takeContentItems(),
            errorText: errorText
        )
        let committed = await host.commitStoredValues(
            storedValueWrites,
            cancellationToken: cancellationToken
        )
        guard committed, case .running = phase, !cancellationToken.isCancelled else {
            // Rejected commit: the cell is terminating, so it ends as
            // `Terminated` carrying whatever the rejected event held.
            contentItems = event.contentItems
            await finishTermination()
            return
        }
        phase = .completed(event)

        if let observer {
            self.observer = nil
            cancelYieldTimer()
            observer.waiter.resume(.success(event))
            phase = .tombstone
            cancellationToken.cancel()
            await finishCell()
        }
        // No observer: the completion stays buffered until a `wait` or
        // `terminate` claims it (`CompletionDelivery::Buffered`).
    }

    /// Everything after a Rust `break` in `run_cell`: tombstone, stop the
    /// runtime, cancel callbacks, then hand the cell back to the session.
    private func finishCell() async {
        guard !finished else { return }
        finished = true
        phase = .tombstone
        cancelYieldTimer()
        cancellationToken.cancel()
        runtime.beginTermination()
        await drainCallbacks(cancelling: true)
        eventPumpTask?.cancel()
        eventPumpTask = nil
        // Anything still awaiting a frontier learns the cell is gone, the
        // way Rust's dropped `oneshot::Sender` yields `CellError::Closed`.
        if let observer {
            self.observer = nil
            observer.waiter.resume(.failure(.closed))
        }
        initialWaiter.resume(.failure(.closed))
        await host.cellClosed()
    }

    // MARK: Delivery helpers

    private func deliverYield() {
        deliverToObserver(.yielded(contentItems: takeContentItems()))
    }

    /// Delivers to the attached observer, or keeps the payload for the next
    /// one. Mirrors `send_observer_event` + `restore_undelivered_yield`
    /// (cell_actor/mod.rs:516, 534).
    private func deliverToObserver(_ event: CodeModeCellEvent) {
        guard let observer else {
            restore(event)
            return
        }
        self.observer = nil
        cancelYieldTimer()
        guard observer.waiter.resume(.success(event)) else {
            restore(event)
            return
        }
    }

    private func restore(_ event: CodeModeCellEvent) {
        switch event {
        case .yielded(let items), .terminated(let items):
            contentItems = items + contentItems
        case .pending(let items, let ids):
            contentItems = items + contentItems
            pendingToolCallIds = ids + pendingToolCallIds
            pendingFrontierReady = true
        case .completed(let items, _):
            contentItems = items + contentItems
        }
    }

    private func takeContentItems() -> [FunctionCallOutputContentItem] {
        defer { contentItems.removeAll() }
        return contentItems
    }

    private func takePendingEvent() -> CodeModeCellEvent {
        defer {
            contentItems.removeAll()
            pendingToolCallIds.removeAll()
        }
        return .pending(contentItems: contentItems, pendingToolCallIds: pendingToolCallIds)
    }

    // MARK: Yield timer

    private func startYieldTimer(for mode: CodeModeObserveMode) {
        cancelYieldTimer()
        guard case .yieldAfter(let milliseconds) = mode else { return }
        yieldTimerGeneration &+= 1
        let generation = yieldTimerGeneration
        yieldTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: milliseconds &* 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.yieldTimerFired(generation: generation)
        }
    }

    private func cancelYieldTimer() {
        yieldTimerTask?.cancel()
        yieldTimerTask = nil
    }

    private func yieldTimerFired(generation: UInt64) {
        guard generation == yieldTimerGeneration, observer != nil, !terminating else { return }
        yieldTimerTask = nil
        deliverYield()
    }

    // MARK: Runtime steering (cell_actor/mod.rs:574)

    private func resumeForObservation(_ mode: CodeModeObserveMode) {
        if runtimePaused {
            switch mode {
            case .yieldAfter: runtime.sendControl(.continue)
            case .pendingFrontier: runtime.sendControl(.resume)
            }
            runtimePaused = false
        } else if case .pendingFrontier = mode {
            runtime.send(.observePendingFrontier)
        }
    }

    // MARK: Callbacks (cell_actor/callbacks.rs)

    private func spawnTool(_ invocation: CodeModeCellToolCall) {
        let id = UUID()
        let token = callbackCancellationToken.childToken()
        let host = self.host
        let runtime = self.runtime
        let callId = invocation.id
        toolTasks[id] = Task { [weak self] in
            let result = await host.invokeTool(invocation, cancellationToken: token)
            switch result {
            case .success(let value):
                runtime.send(.toolResponse(id: callId, result: value))
            case .failure(let error):
                runtime.send(.toolError(id: callId, errorText: error.message))
            }
            await self?.toolCallbackFinished(id)
        }
    }

    private func spawnNotification(callId: String, text: String) {
        let id = UUID()
        let token = callbackCancellationToken.childToken()
        let host = self.host
        notificationTasks[id] = Task { [weak self] in
            _ = await host.notify(callId: callId, text: text, cancellationToken: token)
            await self?.notificationCallbackFinished(id)
        }
    }

    private func toolCallbackFinished(_ id: UUID) {
        toolTasks[id] = nil
    }

    private func notificationCallbackFinished(_ id: UUID) {
        notificationTasks[id] = nil
    }

    /// Mirrors `finish_callbacks` (cell_actor/callbacks.rs:79): a clean
    /// finish drains outstanding host work, a terminal one cancels it first.
    private func drainCallbacks(cancelling: Bool) async {
        if cancelling {
            callbackCancellationToken.cancel()
        }
        while let (id, task) = notificationTasks.first {
            notificationTasks[id] = nil
            await task.value
        }
        // Tool callbacks are cancelled before they are awaited: a nested
        // call still outstanding when the cell finishes would otherwise
        // hold the cell open for as long as the host takes.
        callbackCancellationToken.cancel()
        while let (id, task) = toolTasks.first {
            toolTasks[id] = nil
            await task.value
        }
    }
}
