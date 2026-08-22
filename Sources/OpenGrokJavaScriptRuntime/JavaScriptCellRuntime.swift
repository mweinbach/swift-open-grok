// JavaScriptCellRuntime.swift
//
// The per-cell JavaScript engine thread. Ported from
// `crates/codegen/xai-grok-code-mode/src/runtime/mod.rs` (`spawn_runtime`,
// `run_runtime`, `next_runtime_command`) with the host callbacks from
// `runtime/callbacks.rs`, the global surface from `runtime/globals.rs`, the
// timer wheel from `runtime/timers.rs`, and the module/promise plumbing
// from `runtime/module_loader.rs`.
//
// Structure parity with the Rust source
// -------------------------------------
//   * one OS thread and one engine per cell, created eagerly so the caller
//     can fail fast (`spawn_runtime` blocks on the isolate handle; this
//     blocks on a start semaphore);
//   * two channels in (work + control), one event stream out;
//   * the runtime announces `.pending` whenever it has no work and, in
//     `pauseUntilResumed` mode, blocks until the cell actor releases it;
//   * the event stream finishing is how the cell actor learns the runtime
//     closed — the same signal as the Rust `event_rx.recv() == None`.
//
// Divergences (all deliberate, see the slice integration notes):
//   * JavaScriptCore has no module compilation in its public API, so a cell
//     is evaluated as an async IIFE rather than an ES module. Top-level
//     `await` works identically; static `import` / `export` are rejected up
//     front with the Rust message rather than by the module resolver.
//   * Promise state is observed with `then` continuations instead of
//     `v8::Promise::state()`.

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// A running JavaScript cell: one thread, one context, one script.
///
/// The runtime is inert until commands arrive. It is safe to call `send`,
/// `sendControl`, and `beginTermination` from any task or thread.
public final class JavaScriptCellRuntime: @unchecked Sendable {
    private let commands = JavaScriptRuntimeMailbox<JavaScriptRuntimeCommand>()
    private let controls = JavaScriptRuntimeMailbox<JavaScriptRuntimeControlCommand>()
    private let watchdogLock = NSLock()
    private var watchdog: JavaScriptExecutionWatchdog?
    private var eventContinuation: AsyncStream<JavaScriptRuntimeEvent>.Continuation?
    private var terminationRequested = false
    private var subprocess: JavaScriptRuntimeSubprocess?

    /// Whether this host can bound a runaway JavaScript entry. When false,
    /// `beginTermination` still stops an idle or awaiting cell, but a cell
    /// spinning inside JavaScript runs until it returns to the host.
    public static var supportsExecutionCeiling: Bool {
        JavaScriptRuntimeSubprocess.workerExecutable() != nil
            || JavaScriptExecutionWatchdog.supportsExecutionCeiling
    }

    /// Whether production can stop a busy JavaScript entry immediately by
    /// killing its isolated worker process rather than waiting for JSC's
    /// per-entry time limit.
    public static var supportsHardInterrupt: Bool {
        JavaScriptRuntimeSubprocess.workerExecutable() != nil
    }

    private init() {}

    /// Start a cell. Returns the handle plus the event stream, which
    /// finishes when the runtime thread exits.
    ///
    /// Mirrors `spawn_runtime` (runtime/mod.rs:73): the call does not
    /// return until the engine exists, so an engine that cannot be created
    /// surfaces as a thrown error rather than as a silently dead cell.
    public static func start(
        configuration: JavaScriptCellConfiguration,
        pendingMode: JavaScriptPendingMode = .pauseUntilResumed
    ) throws -> (runtime: JavaScriptCellRuntime, events: AsyncStream<JavaScriptRuntimeEvent>) {
        #if canImport(JavaScriptCore)
        if let executable = JavaScriptRuntimeSubprocess.workerExecutable() {
            let runtime = JavaScriptCellRuntime()
            let (stream, continuation) = AsyncStream<JavaScriptRuntimeEvent>.makeStream(
                bufferingPolicy: .unbounded
            )
            runtime.subprocess = try JavaScriptRuntimeSubprocess.start(
                executable: executable,
                configuration: configuration,
                pendingMode: pendingMode,
                continuation: continuation
            )
            return (runtime, stream)
        }
        return try startInProcess(configuration: configuration, pendingMode: pendingMode)
        #else
        throw JavaScriptRuntimeError.unsupportedPlatform
        #endif
    }

    static func startInProcess(
        configuration: JavaScriptCellConfiguration,
        pendingMode: JavaScriptPendingMode = .pauseUntilResumed
    ) throws -> (runtime: JavaScriptCellRuntime, events: AsyncStream<JavaScriptRuntimeEvent>) {
        #if canImport(JavaScriptCore)
        let runtime = JavaScriptCellRuntime()
        let (stream, continuation) = AsyncStream<JavaScriptRuntimeEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let ready = DispatchSemaphore(value: 0)
        let startup = StartupResult()

        let thread = Thread {
            runtime.run(
                configuration: configuration,
                pendingMode: pendingMode,
                continuation: continuation,
                startup: startup,
                ready: ready
            )
        }
        thread.name = "open-grok.code-mode.cell"
        // Deep recursion in user JavaScript should hit JavaScriptCore's own
        // stack guard, not the thread's.
        thread.stackSize = 4 << 20
        thread.start()

        ready.wait()
        if let failure = startup.failure {
            continuation.finish()
            throw failure
        }
        return (runtime, stream)
        #else
        throw JavaScriptRuntimeError.unsupportedPlatform
        #endif
    }

    /// Queue work for the runtime thread. Mirrors sending on
    /// `RuntimeCommand`'s channel.
    public func send(_ command: JavaScriptRuntimeCommand) {
        if let subprocess {
            subprocess.send(.command(command))
            return
        }
        commands.send(command)
    }

    /// Release or stop a paused runtime thread. Mirrors sending on
    /// `RuntimeControlCommand`'s channel.
    public func sendControl(_ command: JavaScriptRuntimeControlCommand) {
        if let subprocess {
            subprocess.send(.control(command))
            return
        }
        controls.send(command)
    }

    /// The three actions Rust's `begin_termination`
    /// (cell_actor/mod.rs:592) performs together: a terminate command, a
    /// terminate control message, and an execution interrupt. Idempotent.
    ///
    /// The interrupt is not immediate here: a cell that is spinning inside
    /// a single JavaScript entry stops when that entry's ceiling elapses
    /// (see `JavaScriptExecutionWatchdog`). Every cell that is idle,
    /// awaiting a nested tool, or awaiting a timer stops at once.
    public func beginTermination() {
        watchdogLock.lock()
        let alreadyRequested = terminationRequested
        terminationRequested = true
        let watchdog = self.watchdog
        let subprocess = self.subprocess
        watchdogLock.unlock()

        guard !alreadyRequested else { return }
        if let subprocess {
            subprocess.terminate()
            return
        }
        watchdog?.requestTermination()
        commands.send(.terminate)
        controls.send(.terminate)
        // Close the event stream now rather than waiting for the thread to
        // notice. Rust's `terminate_execution` interrupts V8 immediately, so
        // the cell actor observes a closed runtime at once; here the thread
        // may still be finishing a JavaScript entry, and the caller must not
        // be held hostage to it. A thread that outlives this call is
        // reclaimed when its execution ceiling fires and can no longer
        // affect the cell — every later event is dropped.
        eventContinuation?.finish()
    }

    /// Set by the runtime thread once its engine exists; also applies a
    /// termination that raced startup.
    fileprivate func adoptWatchdog(
        _ watchdog: JavaScriptExecutionWatchdog,
        continuation: AsyncStream<JavaScriptRuntimeEvent>.Continuation
    ) {
        watchdogLock.lock()
        self.watchdog = watchdog
        eventContinuation = continuation
        let alreadyRequested = terminationRequested
        watchdogLock.unlock()
        if alreadyRequested {
            watchdog.requestTermination()
            continuation.finish()
        }
    }

    fileprivate func closeMailboxes() {
        commands.close()
        controls.close()
    }

    /// Carries a startup failure back to `start` across the thread boundary.
    fileprivate final class StartupResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: JavaScriptRuntimeError?

        var failure: JavaScriptRuntimeError? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func fail(_ error: JavaScriptRuntimeError) {
            lock.lock()
            stored = error
            lock.unlock()
        }
    }
}

#if canImport(JavaScriptCore)

extension JavaScriptCellRuntime {
    /// The runtime thread body. Mirrors `run_runtime` (runtime/mod.rs:168).
    fileprivate func run(
        configuration: JavaScriptCellConfiguration,
        pendingMode: JavaScriptPendingMode,
        continuation: AsyncStream<JavaScriptRuntimeEvent>.Continuation,
        startup: StartupResult,
        ready: DispatchSemaphore
    ) {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            startup.fail(.initializationFailed("failed to create the code mode JavaScript context"))
            ready.signal()
            continuation.finish()
            return
        }

        let engine = JavaScriptCellEngine(
            context: context,
            configuration: configuration,
            commands: commands,
            emit: { continuation.yield($0) }
        )
        let watchdog = JavaScriptExecutionWatchdog(
            context: context,
            ceilingMilliseconds: configuration.executionCeilingMs
        )
        engine.watchdog = watchdog
        adoptWatchdog(watchdog, continuation: continuation)

        if let errorText = engine.installGlobals() {
            ready.signal()
            continuation.yield(.result(storedValueWrites: [:], errorText: errorText))
            watchdog.dispose()
            continuation.finish()
            closeMailboxes()
            return
        }
        ready.signal()

        defer {
            engine.releasePendingCallbacks()
            watchdog.dispose()
            continuation.finish()
            closeMailboxes()
        }

        continuation.yield(.started)

        // Evaluate, then settle immediately if the cell had no pending work.
        if let errorText = engine.evaluateSource() {
            if watchdog.didStopLastEntry {
                if watchdog.isTerminationRequested { return }
                continuation.yield(
                    .result(
                        storedValueWrites: engine.storedValueWrites,
                        errorText: CODE_MODE_EXECUTION_CEILING_ERROR
                    )
                )
                return
            }
            continuation.yield(
                .result(storedValueWrites: engine.storedValueWrites, errorText: errorText)
            )
            return
        }
        if watchdog.didStopLastEntry {
            // The ceiling stopped a cell whose script never threw, e.g. a
            // synchronous infinite loop that JavaScriptCore unwound without
            // surfacing an exception.
            if watchdog.isTerminationRequested { return }
            continuation.yield(
                .result(
                    storedValueWrites: engine.storedValueWrites,
                    errorText: CODE_MODE_EXECUTION_CEILING_ERROR
                )
            )
            return
        }
        if let completion = engine.takeCompletion() {
            continuation.yield(
                .result(
                    storedValueWrites: engine.storedValueWrites,
                    errorText: completion.errorText
                )
            )
            return
        }

        // Mirrors the `while let Some(command) = next_runtime_command(...)`
        // loop in runtime/mod.rs:229.
        func settle(_ errorText: String?) {
            continuation.yield(
                .result(storedValueWrites: engine.storedValueWrites, errorText: errorText)
            )
        }
        /// A dispatched entry either produced an error, was stopped by the
        /// ceiling, or left the runtime ready for the next command.
        func stoppedByCeiling() -> Bool {
            guard watchdog.didStopLastEntry else { return false }
            // When a terminate was already requested the cell actor is in
            // termination and closing the stream is the terminal signal,
            // matching Rust; otherwise the cell blew its execution budget
            // and that is reported as an error.
            if !watchdog.isTerminationRequested {
                settle(CODE_MODE_EXECUTION_CEILING_ERROR)
            }
            return true
        }

        while let command = nextCommand(pendingMode: pendingMode, emit: { continuation.yield($0) })
        {
            var dispatchError: String?
            switch command {
            case .terminate:
                return
            case .toolResponse(let id, let result):
                dispatchError = engine.resolveToolCall(id: id, result: .success(result))
            case .toolError(let id, let errorText):
                dispatchError = engine.resolveToolCall(
                    id: id,
                    result: .failure(CodeModeError(errorText))
                )
            case .toolProgress(let id, let progress):
                // Progress is observation-only: stale calls, absent handlers,
                // and handler exceptions cannot fail the surrounding cell.
                engine.deliverToolProgress(id: id, progress: progress)
            case .timeoutFired(let id):
                dispatchError = engine.invokeTimeout(id: id)
            case .observePendingFrontier:
                break
            }
            if stoppedByCeiling() { return }
            if let dispatchError {
                settle(dispatchError)
                return
            }

            engine.drainMicrotasks()
            if let completion = engine.takeCompletion() {
                settle(completion.errorText)
                return
            }
            if stoppedByCeiling() { return }
        }
    }

    /// Mirrors `next_runtime_command` (runtime/mod.rs:280).
    private func nextCommand(
        pendingMode: JavaScriptPendingMode,
        emit: (JavaScriptRuntimeEvent) -> Void
    ) -> JavaScriptRuntimeCommand? {
        while true {
            if let command = commands.tryTake() { return command }

            emit(.pending)
            switch pendingMode {
            case .continueImmediately:
                return commands.take()
            case .pauseUntilResumed:
                guard let control = controls.take() else { return nil }
                switch control {
                case .continue: return commands.take()
                case .resume: continue
                case .terminate: return .terminate
                }
            }
        }
    }
}

// MARK: - Engine

/// Owns the `JSContext` and every host binding for one cell. Every member
/// is confined to the runtime thread.
private final class JavaScriptCellEngine {
    struct Completion {
        var errorText: String?
    }

    private let context: JSContext
    private let configuration: JavaScriptCellConfiguration
    private let commands: JavaScriptRuntimeMailbox<JavaScriptRuntimeCommand>
    private let emit: (JavaScriptRuntimeEvent) -> Void

    private var storedValues: [String: JSONValue]
    private(set) var storedValueWrites: [String: JSONValue] = [:]
    private var pendingToolCalls: [String: (resolve: JSValue, reject: JSValue)] = [:]
    private var pendingProgressCallbacks: [String: JSValue] = [:]
    private var pendingTimeouts: [UInt64: JSValue] = [:]
    private var nextToolCallId: UInt64 = 1
    private var nextTimeoutId: UInt64 = 1
    private var exitRequested = false
    private var budget: JavaScriptOutputBudget
    private var completion: Completion?
    private var recordedException: JSValue?
    /// Armed immediately before every VM entry; JavaScriptCore does not
    /// re-arm its execution ceiling on its own.
    var watchdog: JavaScriptExecutionWatchdog?
    private var cancelledTimeouts: Set<UInt64> = []
    /// Per-cell module loader mirroring V8's resolve/cache pipeline
    /// (runtime/module_loader.rs). Specifiers discovered by the source
    /// scanner are resolved and loaded (currently: rejected) through this
    /// loader so the rejection message and cache semantics match Rust.
    private let moduleLoader = JavaScriptModuleLoader()

    init(
        context: JSContext,
        configuration: JavaScriptCellConfiguration,
        commands: JavaScriptRuntimeMailbox<JavaScriptRuntimeCommand>,
        emit: @escaping (JavaScriptRuntimeEvent) -> Void
    ) {
        self.context = context
        self.configuration = configuration
        self.commands = commands
        self.emit = emit
        self.storedValues = configuration.storedValues
        self.budget = JavaScriptOutputBudget(maxOutputTokens: configuration.maxOutputTokens)
        context.exceptionHandler = { [weak self] _, exception in
            self?.recordedException = exception
        }
    }

    // MARK: Globals

    /// Mirrors `install_globals` (runtime/globals.rs:14). Returns error text
    /// on failure, matching the Rust `Result<(), String>`.
    func installGlobals() -> String? {
        // The Rust runtime deletes these outright. JavaScriptCore exposes no
        // `console` at all, so only the shared-memory and Wasm surfaces are
        // present to remove.
        context.evaluateScript(
            """
            delete globalThis.console;
            delete globalThis.Atomics;
            delete globalThis.SharedArrayBuffer;
            delete globalThis.WebAssembly;
            """
        )
        if let errorText = takeExceptionText() {
            return errorText
        }

        guard let tools = JSValue(newObjectIn: context),
            let allTools = JSValue(newArrayIn: context)
        else {
            return "failed to allocate the code mode tool namespace"
        }

        for (index, tool) in configuration.enabledTools.enumerated() {
            let invoke: @convention(block) (JSValue?) -> JSValue? = { [unowned self] argument in
                self.callTool(index: index, argument: argument)
            }
            tools.setObject(invoke, forKeyedSubscript: tool.globalName as NSString)

            guard let metadata = JSValue(newObjectIn: context) else {
                return "failed to allocate ALL_TOOLS metadata"
            }
            metadata.setObject(tool.globalName, forKeyedSubscript: "name" as NSString)
            metadata.setObject(tool.description, forKeyedSubscript: "description" as NSString)
            allTools.setObject(metadata, atIndexedSubscript: index)
        }

        let text: @convention(block) (JSValue?) -> Void = { [unowned self] value in
            self.emitText(value)
        }
        let image: @convention(block) (JSValue?) -> Void = { [unowned self] value in
            self.emitImage(value)
        }
        let generatedImage: @convention(block) (JSValue?) -> Void = { [unowned self] value in
            self.emitGeneratedImage(value)
        }
        let store: @convention(block) (JSValue?, JSValue?) -> Void = { [unowned self] key, value in
            self.storeValue(key: key, value: value)
        }
        let load: @convention(block) (JSValue?) -> JSValue? = { [unowned self] key in
            self.loadValue(key: key)
        }
        let notify: @convention(block) (JSValue?) -> Void = { [unowned self] value in
            self.emitNotification(value)
        }
        let yieldControl: @convention(block) () -> Void = { [unowned self] in
            self.emit(.yieldRequested)
        }
        let exit: @convention(block) () -> Void = { [unowned self] in
            self.requestExit()
        }
        let setTimeoutFn: @convention(block) (JSValue?, JSValue?) -> JSValue? = {
            [unowned self] callback, delay in
            self.scheduleTimeout(callback: callback, delay: delay)
        }
        let clearTimeoutFn: @convention(block) (JSValue?) -> Void = { [unowned self] identifier in
            self.clearTimeout(identifier: identifier)
        }

        context.setObject(tools, forKeyedSubscript: "tools" as NSString)
        context.setObject(allTools, forKeyedSubscript: "ALL_TOOLS" as NSString)
        context.setObject(text, forKeyedSubscript: "text" as NSString)
        context.setObject(image, forKeyedSubscript: "image" as NSString)
        context.setObject(generatedImage, forKeyedSubscript: "generatedImage" as NSString)
        context.setObject(store, forKeyedSubscript: "store" as NSString)
        context.setObject(load, forKeyedSubscript: "load" as NSString)
        context.setObject(notify, forKeyedSubscript: "notify" as NSString)
        context.setObject(yieldControl, forKeyedSubscript: "yield_control" as NSString)
        context.setObject(exit, forKeyedSubscript: "exit" as NSString)
        context.setObject(setTimeoutFn, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimeoutFn, forKeyedSubscript: "clearTimeout" as NSString)
        return takeExceptionText()
    }

    // MARK: Evaluation

    /// Compile and start the cell. Returns error text when the source could
    /// not be started at all; otherwise the cell is either already settled
    /// (see `takeCompletion`) or waiting on host work.
    ///
    /// Mirrors `evaluate_main_module` (runtime/module_loader.rs:9).
    func evaluateSource() -> String? {
        if let rawSpecifier = JavaScriptSourceScanner.firstStaticImportSpecifier(
            in: configuration.source
        ) {
            let resolved = moduleLoader.resolve(specifier: rawSpecifier)
            switch moduleLoader.load(resolved) {
            case .rejected(let error):
                return error
            }
        }

        // JavaScriptCore's public API cannot compile ES modules, so the cell
        // body runs as an async IIFE: top-level `await` behaves the same and
        // the call yields the promise the Rust port gets from module
        // evaluation.
        let wrapped = "(async () => {\n\(configuration.source)\n})()"
        watchdog?.armForEntry()
        let result = context.evaluateScript(wrapped, withSourceURL: URL(string: "exec_main.mjs"))
        if let errorText = takeExceptionText() {
            return errorText
        }
        guard let result, result.isObject, result.hasProperty("then") else {
            // A cell with no pending work finishes as soon as it is
            // evaluated (`CompletionState::Completed` with no promise).
            completion = Completion(errorText: nil)
            return nil
        }

        let onFulfilled: @convention(block) (JSValue?) -> Void = { [unowned self] _ in
            self.completion = Completion(errorText: nil)
        }
        let onRejected: @convention(block) (JSValue?) -> Void = { [unowned self] value in
            self.completion = Completion(errorText: self.rejectionErrorText(value))
        }
        watchdog?.armForEntry()
        result.invokeMethod("then", withArguments: [onFulfilled, onRejected])
        if let errorText = takeExceptionText() {
            return errorText
        }
        drainMicrotasks()
        return nil
    }

    /// Run any microtasks queued by the last host callback. Mirrors
    /// `scope.perform_microtask_checkpoint()`.
    func drainMicrotasks() {
        watchdog?.armForEntry()
        context.evaluateScript("undefined")
        _ = takeExceptionText()
    }

    /// Consume the settled state, if the cell has one. Mirrors
    /// `completion_state` (runtime/module_loader.rs:103).
    func takeCompletion() -> Completion? {
        guard let completion else { return nil }
        self.completion = nil
        return completion
    }

    /// Drop JS references held for work that will never arrive.
    func releasePendingCallbacks() {
        pendingToolCalls.removeAll()
        pendingProgressCallbacks.removeAll()
        pendingTimeouts.removeAll()
    }

    // MARK: Tool calls

    /// Mirrors `tool_callback` (runtime/callbacks.rs:13).
    private func callTool(index: Int, argument: JSValue?) -> JSValue? {
        guard index < configuration.enabledTools.count else {
            throwToJS("tool callback data is out of range")
            return nil
        }
        let tool = configuration.enabledTools[index]

        let input: JSONValue?
        switch jsonValue(from: argument) {
        case .success(let value): input = value
        case .failure(let error):
            throwToJS(error.message)
            return nil
        }

        var resolvers: (resolve: JSValue, reject: JSValue)?
        let promise = JSValue(newPromiseIn: context) { resolve, reject in
            if let resolve, let reject { resolvers = (resolve, reject) }
        }
        guard let promise, let resolvers else {
            throwToJS("failed to create tool promise")
            return nil
        }

        let id = "tool-\(nextToolCallId)"
        nextToolCallId = nextToolCallId == UInt64.max ? UInt64.max : nextToolCallId + 1
        let subscribe: @convention(block) (JSValue?) -> Void = { [weak self] handler in
            self?.registerProgressHandler(handler, callID: id)
        }
        promise.setObject(subscribe, forKeyedSubscript: "onProgress" as NSString)
        guard promise.hasProperty("onProgress") else {
            throwToJS("failed to attach onProgress to the tool promise")
            return nil
        }
        pendingToolCalls[id] = resolvers
        emit(.toolCall(id: id, name: tool.toolName, kind: tool.kind, input: input))
        return promise
    }

    /// `promise.onProgress(fn)` replaces the previous callback for this call.
    /// Its contract and error match runtime/callbacks.rs:98-120.
    private func registerProgressHandler(_ handler: JSValue?, callID: String) {
        guard let handler,
              handler.isObject,
              let function = context.objectForKeyedSubscript("Function"),
              handler.isInstance(of: function)
        else {
            throwToJS("onProgress expects a handler function")
            return
        }
        guard pendingToolCalls[callID] != nil else { return }
        pendingProgressCallbacks[callID] = handler
    }

    /// Delivers on the JavaScript thread only while the invocation remains
    /// pending. Exceptions belong to the observation callback, never the cell.
    func deliverToolProgress(id: String, progress: NestedToolProgress) {
        guard pendingToolCalls[id] != nil else {
            pendingProgressCallbacks.removeValue(forKey: id)
            return
        }
        guard let callback = pendingProgressCallbacks[id],
              let argument = jsValue(from: .object([
                "text": .string(progress.text),
                "payload": progress.payload ?? .null,
              ]))
        else { return }
        watchdog?.armForEntry()
        callback.call(withArguments: [argument])
        if takeExceptionText() != nil {
            return
        }
    }

    /// Mirrors `resolve_tool_response` (runtime/module_loader.rs:66).
    /// Returns error text when the runtime cannot continue.
    func resolveToolCall(id: String, result: Result<JSONValue, CodeModeError>) -> String? {
        guard let resolvers = pendingToolCalls.removeValue(forKey: id) else {
            return "unknown tool call `\(id)`"
        }
        pendingProgressCallbacks.removeValue(forKey: id)
        switch result {
        case .success(let value):
            guard let bridged = jsValue(from: value) else {
                return "failed to serialize tool response"
            }
            watchdog?.armForEntry()
            resolvers.resolve.call(withArguments: [bridged])
        case .failure(let errorText):
            // Rust rejects with the bare error string, not an Error object.
            watchdog?.armForEntry()
            resolvers.reject.call(withArguments: [errorText.message])
        }
        return takeExceptionText()
    }

    // MARK: Timers

    /// Mirrors `schedule_timeout` (runtime/timers.rs:12).
    private func scheduleTimeout(callback: JSValue?, delay: JSValue?) -> JSValue? {
        guard let callback, callback.isObject, callback.hasProperty("call") else {
            throwToJS("setTimeout expects a function callback")
            return nil
        }
        let requested = delay?.toDouble() ?? 0
        let delayMilliseconds: UInt64
        if requested.isFinite && requested > 0 {
            delayMilliseconds = UInt64(min(requested.rounded(.towardZero), 1_000_000_000))
        } else {
            delayMilliseconds = 0
        }

        let id = nextTimeoutId
        nextTimeoutId = nextTimeoutId == UInt64.max ? UInt64.max : nextTimeoutId + 1
        pendingTimeouts[id] = callback

        let commands = self.commands
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(delayMilliseconds)))
        {
            commands.send(.timeoutFired(id: id))
        }
        return JSValue(double: Double(id), in: context)
    }

    /// Mirrors `clear_timeout` (runtime/timers.rs:47).
    private func clearTimeout(identifier: JSValue?) {
        guard let identifier, !identifier.isNull, !identifier.isUndefined else { return }
        let raw = identifier.toDouble()
        guard raw.isFinite, raw > 0 else { return }
        let id = UInt64(raw.rounded(.towardZero))
        pendingTimeouts.removeValue(forKey: id)
        cancelledTimeouts.insert(id)
    }

    /// Mirrors `invoke_timeout_callback` (runtime/timers.rs:62).
    func invokeTimeout(id: UInt64) -> String? {
        cancelledTimeouts.remove(id)
        guard let callback = pendingTimeouts.removeValue(forKey: id) else { return nil }
        watchdog?.armForEntry()
        callback.call(withArguments: [])
        return takeExceptionText()
    }

    // MARK: Output helpers

    /// Mirrors `text_callback` (runtime/callbacks.rs:74) plus the output
    /// budget described in `JavaScriptOutputBudget`.
    private func emitText(_ value: JSValue?) {
        switch serializeOutputText(value) {
        case .failure(let error):
            throwToJS(error.message)
        case .success(let text):
            switch budget.admit(text) {
            case .emit(let admitted):
                emit(.contentItem(.inputText(text: admitted)))
            case .emitTruncated(let admitted):
                if !admitted.isEmpty {
                    emit(.contentItem(.inputText(text: admitted)))
                }
                emit(.contentItem(.inputText(text: CODE_MODE_OUTPUT_TRUNCATION_NOTICE)))
            case .suppress:
                break
            }
        }
    }

    /// Mirrors `image_callback` (runtime/callbacks.rs:99).
    private func emitImage(_ value: JSValue?) {
        var detailOverride: String?
        if let arguments = JSContext.currentArguments() as? [JSValue], arguments.count >= 2 {
            let detail = arguments[1]
            if detail.isString {
                detailOverride = detail.toString()
            } else if !detail.isNull && !detail.isUndefined {
                throwToJS("image detail must be a string when provided")
                return
            }
        }

        let json: JSONValue?
        switch jsonValue(from: value) {
        case .success(let parsed): json = parsed
        case .failure(let errorText):
            throwToJS(errorText.message)
            return
        }
        switch JavaScriptOutputImage.normalize(value: json, detailOverride: detailOverride) {
        case .success(let item): emit(.contentItem(item))
        case .failure(let error): throwToJS(error.message)
        }
    }

    /// Mirrors `generated_image_callback` (runtime/callbacks.rs:132): the
    /// image item is emitted first, the optional `output_hint` second.
    private func emitGeneratedImage(_ value: JSValue?) {
        let json: JSONValue?
        switch jsonValue(from: value) {
        case .success(let parsed): json = parsed
        case .failure(let errorText):
            throwToJS(errorText.message)
            return
        }
        let hint: String?
        switch JavaScriptOutputImage.generatedImageOutputHint(value: json) {
        case .success(let parsed): hint = parsed
        case .failure(let errorText):
            throwToJS(errorText.message)
            return
        }
        switch JavaScriptOutputImage.normalize(value: json, detailOverride: nil) {
        case .success(let item):
            emit(.contentItem(item))
            if let hint {
                emit(.contentItem(.inputText(text: hint)))
            }
        case .failure(let error):
            throwToJS(error.message)
        }
    }

    /// Mirrors `notify_callback` (runtime/callbacks.rs:244).
    private func emitNotification(_ value: JSValue?) {
        switch serializeOutputText(value) {
        case .failure(let error):
            throwToJS(error.message)
        case .success(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throwToJS("notify expects non-empty text")
                return
            }
            emit(.notify(callId: configuration.toolCallId, text: text))
        }
    }

    /// Mirrors `exit_callback` (runtime/callbacks.rs:313).
    private func requestExit() {
        exitRequested = true
        context.exception = JSValue(object: CODE_MODE_EXIT_SENTINEL, in: context)
    }

    // MARK: Stored values

    /// Mirrors `store_callback` (runtime/callbacks.rs:184).
    private func storeValue(key: JSValue?, value: JSValue?) {
        guard let keyText = key?.toString() else {
            throwToJS("store key must be a string")
            return
        }
        switch jsonValue(from: value) {
        case .failure(let error):
            throwToJS(error.message)
        case .success(nil):
            throwToJS(
                "Unable to store \"\(keyText)\". Only plain serializable objects can be stored."
            )
        case .success(.some(let serialized)):
            storedValues[keyText] = serialized
            storedValueWrites[keyText] = serialized
        }
    }

    /// Mirrors `load_callback` (runtime/callbacks.rs:217).
    private func loadValue(key: JSValue?) -> JSValue? {
        guard let keyText = key?.toString() else {
            throwToJS("load key must be a string")
            return nil
        }
        guard let stored = storedValues[keyText] else {
            return JSValue(undefinedIn: context)
        }
        guard let bridged = jsValue(from: stored) else {
            throwToJS("failed to load stored value")
            return nil
        }
        return bridged
    }

    // MARK: Value bridging

    /// Mirrors `v8_value_to_json` (runtime/value.rs:191): JSON text is the
    /// bridge, `undefined` becomes `nil`, and a throwing `toJSON` or a
    /// cycle becomes an error.
    private func jsonValue(from value: JSValue?) -> Result<JSONValue?, CodeModeError> {
        switch jsonText(from: value) {
        case .failure(let error):
            return .failure(error)
        case .success(let text):
            guard let text else { return .success(nil) }
            guard let parsed = JavaScriptJSONBridge.value(fromJSON: text) else {
                return .failure(CodeModeError("failed to serialize JavaScript value"))
            }
            return .success(parsed)
        }
    }

    /// Mirrors `json_to_v8` (runtime/value.rs:211).
    private func jsValue(from value: JSONValue) -> JSValue? {
        guard let json = context.objectForKeyedSubscript("JSON"),
            let parse = json.objectForKeyedSubscript("parse")
        else {
            return nil
        }
        let text = JavaScriptJSONBridge.string(from: value)
        let parsed = parse.call(withArguments: [text])
        if takeExceptionText() != nil { return nil }
        return parsed
    }

    /// Mirrors `serialize_output_text` (runtime/value.rs:16): primitives
    /// stringify directly, everything else goes through `JSON.stringify`.
    private func serializeOutputText(_ value: JSValue?) -> Result<String, CodeModeError> {
        guard let value else { return .success("undefined") }
        if value.isUndefined { return .success("undefined") }
        if value.isNull { return .success("null") }
        if value.isBoolean || value.isNumber || value.isString {
            return .success(value.toString() ?? "")
        }
        // Rust returns V8's own `JSON.stringify` output verbatim
        // (runtime/value.rs:32); re-serializing through Foundation would
        // reorder keys and reformat numbers.
        switch jsonText(from: value) {
        case .failure(let error):
            return .failure(error)
        case .success(let text):
            return .success(text ?? (value.toString() ?? ""))
        }
    }

    /// `JSON.stringify(value)` as text, or `nil` when the value is not
    /// serializable (`undefined`, a function, a symbol).
    private func jsonText(from value: JSValue?) -> Result<String?, CodeModeError> {
        guard let value, !value.isUndefined else { return .success(nil) }
        guard let json = context.objectForKeyedSubscript("JSON"),
            let stringify = json.objectForKeyedSubscript("stringify")
        else {
            return .failure(CodeModeError("failed to serialize JavaScript value"))
        }
        let serialized = stringify.call(withArguments: [value])
        if let errorText = takeExceptionText() {
            return .failure(CodeModeError(errorText))
        }
        guard let serialized, !serialized.isUndefined else { return .success(nil) }
        return .success(serialized.toString())
    }

    /// Mirrors `value_to_error_text` (runtime/value.rs:220), which returns an
    /// error's `stack`.
    ///
    /// One engine difference has to be repaired here: V8's `Error.stack`
    /// begins with `"Error: <message>"`, JavaScriptCore's contains only
    /// frames. Returning the frames alone would drop the message the model
    /// needs, so the description is prepended when the stack lacks it,
    /// reproducing V8's shape.
    private func errorText(for value: JSValue?) -> String {
        guard let value else { return "unknown code mode exception" }
        if value.isObject, let stack = value.objectForKeyedSubscript("stack"), stack.isString,
            let stackText = stack.toString()
        {
            let description = value.toString() ?? ""
            if stackText.isEmpty { return description }
            if description.isEmpty || stackText.contains(description) { return stackText }
            return "\(description)\n\(stackText)"
        }
        return value.toString() ?? "unknown code mode exception"
    }

    /// Rejection text for a settled cell, honoring the `exit()` sentinel
    /// (`is_exit_exception`, runtime/module_loader.rs:54).
    private func rejectionErrorText(_ value: JSValue?) -> String? {
        if exitRequested, let value, value.isString, value.toString() == CODE_MODE_EXIT_SENTINEL {
            return nil
        }
        return errorText(for: value)
    }

    /// Mirrors `throw_type_error` (runtime/value.rs:235): the thrown value
    /// is a bare string, exactly as in the Rust port.
    private func throwToJS(_ message: String) {
        context.exception = JSValue(object: message, in: context)
    }

    /// Consume any exception recorded at the API boundary.
    private func takeExceptionText() -> String? {
        var exception = recordedException
        recordedException = nil
        if exception == nil, let pending = context.exception, !pending.isUndefined, !pending.isNull {
            exception = pending
        }
        context.exception = nil
        guard let exception else { return nil }
        if exitRequested, exception.isString, exception.toString() == CODE_MODE_EXIT_SENTINEL {
            return nil
        }
        return errorText(for: exception)
    }
}

#endif

/// Static `import` / `export` detection.
///
/// The Rust runtime compiles the cell as a real module and lets V8's
/// `resolve_module_callback` (module_loader.rs:164) reject every
/// specifier. JavaScriptCore's public API has no module compilation, so
/// the same rejection is produced by scanning for a statement-position
/// `import` / `export` before evaluation and routing the specifier
/// through `JavaScriptModuleLoader` for resolution and rejection.
enum JavaScriptSourceScanner {
    static func firstStaticImportSpecifier(in source: String) -> String? {
        var inBlockComment = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                inBlockComment = false
                line = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("/*"), !line.contains("*/") {
                inBlockComment = true
                continue
            }
            if line.hasPrefix("//") { continue }
            guard isStaticModuleStatement(line) else { continue }
            return specifier(in: line) ?? line
        }
        return nil
    }

    private static func isStaticModuleStatement(_ line: String) -> Bool {
        for keyword in ["import", "export"] {
            guard line.hasPrefix(keyword) else { continue }
            let remainder = line.dropFirst(keyword.count)
            guard let next = remainder.first else { return true }
            // `import(` and `import.meta` are expressions, not declarations.
            if next == "(" || next == "." { return false }
            if next == " " || next == "\t" || next == "{" || next == "*" || next == "\"" {
                return true
            }
        }
        return false
    }

    private static func specifier(in line: String) -> String? {
        for quote in ["\"", "'"] {
            guard let open = line.range(of: quote),
                let close = line.range(of: quote, options: .backwards),
                open.upperBound < close.lowerBound
            else { continue }
            return String(line[open.upperBound..<close.lowerBound])
        }
        return nil
    }
}
