#if !canImport(JavaScriptCore) && canImport(COpenGrokQuickJS)

import COpenGrokQuickJS
import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared

/// Serializes interruption against destruction of the isolate. QuickJS may be
/// interrupted from another thread, but its runtime cannot be freed there.
final class QuickJSInterruptHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: OpaquePointer?
    private var terminationRequested = false

    init(runtime: OpaquePointer) {
        self.runtime = runtime
    }

    func requestTermination() {
        lock.lock()
        terminationRequested = true
        if let runtime {
            ogq_runtime_interrupt(runtime)
        }
        lock.unlock()
    }

    var isTerminationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }

    @discardableResult
    func armEntry(milliseconds: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let runtime, !terminationRequested else { return false }
        ogq_runtime_clear_interrupt(runtime)
        ogq_runtime_set_deadline_ms(runtime, max(milliseconds, 1))
        return true
    }

    func invalidate() {
        lock.lock()
        runtime = nil
        lock.unlock()
    }
}

/// Every boxed value is confined to the isolate thread and owns one QuickJS
/// reference. A host callback relinquishes ownership to the C trampoline.
final class QuickJSValue {
    private let context: OpaquePointer
    private var storage: OpaquePointer?

    init?(context: OpaquePointer, taking value: OpaquePointer?) {
        guard let value else { return nil }
        self.context = context
        storage = value
    }

    convenience init?(context: OpaquePointer, duplicating value: OpaquePointer?) {
        guard let value else { return nil }
        self.init(context: context, taking: ogq_dup(context, value))
    }

    deinit {
        if let storage {
            ogq_free_value(context, storage)
        }
    }

    var pointer: OpaquePointer {
        precondition(storage != nil, "a transferred QuickJS value cannot be reused")
        return storage!
    }

    func relinquish() -> OpaquePointer? {
        let pointer = storage
        storage = nil
        return pointer
    }
}

enum QuickJSHostCallbackKind {
    case text
    case image
    case generatedImage
    case store
    case load
    case notify
    case yieldControl
    case exit
    case setTimeout
    case clearTimeout
    case tool(Int)
    case progress(String)
}

final class QuickJSCellEngine {
    struct Completion {
        var errorText: String?
    }

    struct PendingToolCall {
        var resolve: QuickJSValue
        var reject: QuickJSValue
    }

    let runtime: OpaquePointer
    let context: OpaquePointer
    let configuration: JavaScriptCellConfiguration
    let commands: JavaScriptRuntimeMailbox<JavaScriptRuntimeCommand>
    let emit: (JavaScriptRuntimeEvent) -> Void
    let interrupt: QuickJSInterruptHandle

    var storedValues: [String: JSONValue]
    var storedValueWrites: [String: JSONValue] = [:]
    var pendingToolCalls: [String: PendingToolCall] = [:]
    var pendingProgressCallbacks: [String: QuickJSValue] = [:]
    var pendingProgressChunks: [String: [NestedToolProgress]] = [:]
    var pendingTimeouts: [UInt64: QuickJSValue] = [:]
    var callbackKinds: [Int32: QuickJSHostCallbackKind] = [:]
    var nextCallbackID: Int32 = 1
    var nextToolCallID: UInt64 = 1
    var nextTimeoutID: UInt64 = 1
    var exitRequested = false
    var budget: JavaScriptOutputBudget
    private var mainPromise: QuickJSValue?
    private var completedWithoutPromise = false

    init?(
        configuration: JavaScriptCellConfiguration,
        commands: JavaScriptRuntimeMailbox<JavaScriptRuntimeCommand>,
        emit: @escaping (JavaScriptRuntimeEvent) -> Void
    ) {
        guard let runtime = ogq_runtime_new() else { return nil }
        ogq_runtime_set_memory_limit(runtime, 128 << 20)
        ogq_runtime_set_stack_limit(runtime, 2 << 20)
        guard let context = ogq_context_new(runtime) else {
            ogq_runtime_free(runtime)
            return nil
        }

        self.runtime = runtime
        self.context = context
        self.configuration = configuration
        self.commands = commands
        self.emit = emit
        interrupt = QuickJSInterruptHandle(runtime: runtime)
        storedValues = configuration.storedValues
        budget = JavaScriptOutputBudget(maxOutputTokens: configuration.maxOutputTokens)
        ogq_set_opaque(context, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        releasePendingCallbacks()
        mainPromise = nil
        interrupt.invalidate()
        ogq_set_opaque(context, nil)
        ogq_context_free(context)
        ogq_runtime_free(runtime)
    }

    func value(taking pointer: OpaquePointer?) -> QuickJSValue? {
        QuickJSValue(context: context, taking: pointer)
    }

    func undefined() -> QuickJSValue? {
        value(taking: ogq_new_undefined(context))
    }

    func string(_ text: String) -> QuickJSValue? {
        value(taking: ogq_new_string(context, text))
    }

    func duplicate(_ pointer: OpaquePointer?) -> QuickJSValue? {
        QuickJSValue(context: context, duplicating: pointer)
    }

    @discardableResult
    func armForEntry() -> Bool {
        interrupt.armEntry(milliseconds: configuration.executionCeilingMs)
    }

    var didStopLastEntry: Bool {
        ogq_runtime_was_interrupted(runtime)
    }

    func evaluateSource() -> String? {
        if let specifier = JavaScriptSourceScanner.firstStaticImportSpecifier(
            in: configuration.source
        ) {
            let loader = JavaScriptModuleLoader()
            switch loader.load(loader.resolve(specifier: specifier)) {
            case .rejected(let error):
                return error
            }
        }

        guard armForEntry() else { return CODE_MODE_EXECUTION_CEILING_ERROR }
        let source = configuration.source
        let evaluated = source.withCString { sourcePointer in
            value(
                taking: ogq_eval(
                    context,
                    sourcePointer,
                    source.utf8.count,
                    JavaScriptModuleLoader.mainModuleReferrer,
                    1
                )
            )
        }
        guard let evaluated else {
            return takeExceptionText() ?? "failed to evaluate the code mode JavaScript module"
        }
        if ogq_is_exception(evaluated.pointer) {
            let error = takeExceptionText() ?? "unknown code mode exception"
            if exitRequested, error == CODE_MODE_EXIT_SENTINEL {
                completedWithoutPromise = true
                return nil
            }
            return error
        }
        if ogq_is_promise(evaluated.pointer) {
            mainPromise = evaluated
        } else {
            completedWithoutPromise = true
        }
        return drainMicrotasks()
    }

    func drainMicrotasks() -> String? {
        guard armForEntry() else { return CODE_MODE_EXECUTION_CEILING_ERROR }
        while ogq_runtime_job_pending(runtime) {
            let result = ogq_execute_pending_job(runtime)
            if result < 0 {
                return takeExceptionText() ?? "failed to execute a JavaScript promise job"
            }
            if didStopLastEntry { return CODE_MODE_EXECUTION_CEILING_ERROR }
        }
        return nil
    }

    func takeCompletion() -> Completion? {
        if completedWithoutPromise {
            completedWithoutPromise = false
            return Completion(errorText: nil)
        }
        guard let mainPromise else { return nil }
        switch ogq_promise_state(context, mainPromise.pointer) {
        case 0:
            return nil
        case 1:
            self.mainPromise = nil
            return Completion(errorText: nil)
        case 2:
            let rejected = value(taking: ogq_promise_result(context, mainPromise.pointer))
            self.mainPromise = nil
            if exitRequested, let rejected,
                ogq_is_string(rejected.pointer), stringValue(rejected.pointer) == CODE_MODE_EXIT_SENTINEL
            {
                return Completion(errorText: nil)
            }
            return Completion(errorText: errorText(for: rejected?.pointer))
        default:
            self.mainPromise = nil
            return Completion(errorText: "failed to read exec promise")
        }
    }

    func releasePendingCallbacks() {
        pendingToolCalls.removeAll()
        pendingProgressCallbacks.removeAll()
        pendingProgressChunks.removeAll()
        pendingTimeouts.removeAll()
        callbackKinds.removeAll()
    }

    func takeExceptionText() -> String? {
        guard ogq_has_exception(context),
            let exception = value(taking: ogq_take_exception(context))
        else { return nil }
        return errorText(for: exception.pointer)
    }

    func errorText(for pointer: OpaquePointer?) -> String {
        guard let pointer else { return "unknown code mode exception" }
        let description = stringValue(pointer) ?? "unknown code mode exception"
        guard ogq_is_object(pointer),
            let stack = value(taking: ogq_get_property(context, pointer, "stack")),
            ogq_is_string(stack.pointer),
            let stackText = stringValue(stack.pointer), !stackText.isEmpty
        else { return description }
        if stackText.contains(description) { return stackText }
        return "\(description)\n\(stackText)"
    }

    func stringValue(_ pointer: OpaquePointer?) -> String? {
        guard let pointer, let characters = ogq_to_string(context, pointer) else { return nil }
        defer { ogq_free_string(characters) }
        return String(cString: characters)
    }

    func throwToJS(_ message: String) -> QuickJSValue? {
        value(taking: ogq_throw_string(context, message))
    }

    func jsValue(from json: JSONValue) -> QuickJSValue? {
        let serialized = JavaScriptJSONBridge.string(from: json)
        return serialized.withCString { characters in
            value(taking: ogq_json_parse(context, characters, serialized.utf8.count))
        }
    }

    func jsonText(from pointer: OpaquePointer?) -> Result<String?, CodeModeError> {
        guard let pointer, !ogq_is_undefined(pointer) else { return .success(nil) }
        guard let serialized = value(taking: ogq_json_stringify(context, pointer)) else {
            return .failure(CodeModeError(takeExceptionText() ?? "failed to serialize JavaScript value"))
        }
        if ogq_is_exception(serialized.pointer) {
            return .failure(CodeModeError(takeExceptionText() ?? "failed to serialize JavaScript value"))
        }
        if ogq_is_undefined(serialized.pointer) { return .success(nil) }
        return .success(stringValue(serialized.pointer))
    }

    func jsonValue(from pointer: OpaquePointer?) -> Result<JSONValue?, CodeModeError> {
        switch jsonText(from: pointer) {
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

    func call(_ function: QuickJSValue, arguments: [QuickJSValue]) -> String? {
        guard armForEntry(), let thisValue = undefined() else {
            return CODE_MODE_EXECUTION_CEILING_ERROR
        }
        var pointers = arguments.map { Optional($0.pointer) }
        let result = pointers.withUnsafeMutableBufferPointer { buffer in
            value(
                taking: ogq_call(
                    context,
                    function.pointer,
                    thisValue.pointer,
                    Int32(buffer.count),
                    buffer.baseAddress
                )
            )
        }
        guard let result else {
            return takeExceptionText() ?? "failed to invoke a JavaScript callback"
        }
        if ogq_is_exception(result.pointer) {
            return takeExceptionText() ?? "unknown code mode exception"
        }
        return nil
    }
}

extension JavaScriptCellRuntime {
    func runQuickJS(
        configuration: JavaScriptCellConfiguration,
        pendingMode: JavaScriptPendingMode,
        continuation: AsyncStream<JavaScriptRuntimeEvent>.Continuation,
        startup: StartupResult,
        ready: DispatchSemaphore
    ) {
        guard let engine = QuickJSCellEngine(
            configuration: configuration,
            commands: commands,
            emit: { continuation.yield($0) }
        ) else {
            startup.fail(.initializationFailed("failed to create the code mode QuickJS isolate"))
            ready.signal()
            continuation.finish()
            return
        }
        adoptQuickJSInterrupt(engine.interrupt, continuation: continuation)

        if let error = engine.installGlobals() {
            ready.signal()
            continuation.yield(.result(storedValueWrites: [:], errorText: error))
            continuation.finish()
            closeMailboxes()
            return
        }
        ready.signal()

        defer {
            engine.releasePendingCallbacks()
            continuation.finish()
            closeMailboxes()
        }
        continuation.yield(.started)

        func settle(_ error: String?) {
            continuation.yield(.result(storedValueWrites: engine.storedValueWrites, errorText: error))
        }

        func stoppedByCeiling() -> Bool {
            guard engine.didStopLastEntry else { return false }
            if !engine.interrupt.isTerminationRequested {
                settle(CODE_MODE_EXECUTION_CEILING_ERROR)
            }
            return true
        }

        if let error = engine.evaluateSource() {
            if stoppedByCeiling() { return }
            if engine.interrupt.isTerminationRequested { return }
            settle(error)
            return
        }
        if stoppedByCeiling() { return }
        if let completion = engine.takeCompletion() {
            settle(completion.errorText)
            return
        }

        while let command = nextQuickJSCommand(pendingMode: pendingMode, emit: { continuation.yield($0) }) {
            var dispatchError: String?
            switch command {
            case .terminate:
                return
            case .toolResponse(let id, let result):
                dispatchError = engine.resolveToolCall(id: id, result: .success(result))
            case .toolError(let id, let error):
                dispatchError = engine.resolveToolCall(id: id, result: .failure(CodeModeError(error)))
            case .toolProgress(let id, let progress):
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
            if let error = engine.drainMicrotasks() {
                if stoppedByCeiling() { return }
                if engine.interrupt.isTerminationRequested { return }
                settle(error)
                return
            }
            if let completion = engine.takeCompletion() {
                settle(completion.errorText)
                return
            }
            if stoppedByCeiling() { return }
        }
    }

    private func nextQuickJSCommand(
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

#endif
