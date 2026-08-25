#if !canImport(JavaScriptCore) && canImport(COpenGrokQuickJS)

import COpenGrokQuickJS
import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared

extension QuickJSCellEngine {
    func installGlobals() -> String? {
        guard let global = value(taking: ogq_get_global(context)),
            let tools = value(taking: ogq_new_object(context)),
            let allTools = value(taking: ogq_new_array(context))
        else {
            return takeExceptionText() ?? "failed to allocate the code mode tool namespace"
        }

        for (index, tool) in configuration.enabledTools.enumerated() {
            guard let invoke = makeFunction(.tool(index), arity: 1),
                ogq_set_property(context, tools.pointer, tool.globalName, invoke.pointer) > 0,
                let metadata = value(taking: ogq_new_object(context)),
                let name = string(tool.globalName),
                let description = string(tool.description),
                ogq_set_property(context, metadata.pointer, "name", name.pointer) > 0,
                ogq_set_property(context, metadata.pointer, "description", description.pointer) > 0,
                index <= Int(UInt32.max),
                ogq_set_index(context, allTools.pointer, UInt32(index), metadata.pointer) > 0
            else {
                return takeExceptionText() ?? "failed to allocate ALL_TOOLS metadata"
            }
        }

        guard ogq_set_property(context, global.pointer, "tools", tools.pointer) > 0,
            ogq_set_property(context, global.pointer, "ALL_TOOLS", allTools.pointer) > 0
        else {
            return takeExceptionText() ?? "failed to install the code mode tool namespace"
        }

        let functions: [(String, QuickJSHostCallbackKind, Int32)] = [
            ("text", .text, 1),
            ("image", .image, 2),
            ("generatedImage", .generatedImage, 1),
            ("store", .store, 2),
            ("load", .load, 1),
            ("notify", .notify, 1),
            ("yield_control", .yieldControl, 0),
            ("exit", .exit, 0),
            ("setTimeout", .setTimeout, 2),
            ("clearTimeout", .clearTimeout, 1),
        ]
        for (name, kind, arity) in functions {
            guard let callback = makeFunction(kind, arity: arity),
                ogq_set_property(context, global.pointer, name, callback.pointer) > 0
            else {
                return takeExceptionText() ?? "failed to install the code mode \(name) callback"
            }
        }
        return takeExceptionText()
    }

    private func makeFunction(_ kind: QuickJSHostCallbackKind, arity: Int32) -> QuickJSValue? {
        guard nextCallbackID < Int32.max else { return nil }
        let callbackID = nextCallbackID
        nextCallbackID += 1
        callbackKinds[callbackID] = kind

        let callback = ogq_new_function(
            context,
            callbackID,
            { _, opaque, identifier, count, rawArguments, _ in
                guard let opaque else { return nil }
                let engine = Unmanaged<QuickJSCellEngine>.fromOpaque(opaque).takeUnretainedValue()
                var arguments: [OpaquePointer?] = []
                if let rawArguments, count > 0 {
                    arguments.reserveCapacity(Int(count))
                    for index in 0..<Int(count) {
                        arguments.append(rawArguments[index])
                    }
                }
                return engine.invokeHostCallback(id: identifier, arguments: arguments)?.relinquish()
            },
            arity
        )
        guard let function = value(taking: callback), !ogq_is_exception(function.pointer) else {
            callbackKinds.removeValue(forKey: callbackID)
            return nil
        }
        return function
    }

    private func invokeHostCallback(
        id: Int32,
        arguments: [OpaquePointer?]
    ) -> QuickJSValue? {
        guard let kind = callbackKinds[id] else {
            return throwToJS("JavaScript host callback is unavailable")
        }

        switch kind {
        case .text:
            return emitText(arguments.first ?? nil)
        case .image:
            return emitImage(arguments)
        case .generatedImage:
            return emitGeneratedImage(arguments.first ?? nil)
        case .store:
            return storeValue(
                key: arguments.first ?? nil,
                value: arguments.count > 1 ? arguments[1] : nil
            )
        case .load:
            return loadValue(key: arguments.first ?? nil)
        case .notify:
            return emitNotification(arguments.first ?? nil)
        case .yieldControl:
            emit(.yieldRequested)
            return undefined()
        case .exit:
            exitRequested = true
            return throwToJS(CODE_MODE_EXIT_SENTINEL)
        case .setTimeout:
            return scheduleTimeout(
                callback: arguments.first ?? nil,
                delay: arguments.count > 1 ? arguments[1] : nil
            )
        case .clearTimeout:
            clearTimeout(identifier: arguments.first ?? nil)
            return undefined()
        case .tool(let index):
            return callTool(index: index, argument: arguments.first ?? nil)
        case .progress(let callID):
            return registerProgressHandler(arguments.first ?? nil, callID: callID)
        }
    }

    private func callTool(index: Int, argument: OpaquePointer?) -> QuickJSValue? {
        guard configuration.enabledTools.indices.contains(index) else {
            return throwToJS("tool callback data is out of range")
        }
        let input: JSONValue?
        switch jsonValue(from: argument) {
        case .failure(let error):
            return throwToJS(error.message)
        case .success(let parsed):
            input = parsed
        }

        var resolvePointer: OpaquePointer?
        var rejectPointer: OpaquePointer?
        guard let promise = value(
            taking: ogq_promise_new(context, &resolvePointer, &rejectPointer)
        ), !ogq_is_exception(promise.pointer),
            let resolve = value(taking: resolvePointer),
            let reject = value(taking: rejectPointer)
        else {
            if let resolvePointer { ogq_free_value(context, resolvePointer) }
            if let rejectPointer { ogq_free_value(context, rejectPointer) }
            return throwToJS("failed to create tool promise")
        }

        let id = "tool-\(nextToolCallID)"
        if nextToolCallID < UInt64.max { nextToolCallID += 1 }
        guard let subscribe = makeFunction(.progress(id), arity: 1),
            ogq_set_property(context, promise.pointer, "onProgress", subscribe.pointer) > 0
        else {
            return throwToJS("failed to attach onProgress to the tool promise")
        }

        pendingToolCalls[id] = PendingToolCall(resolve: resolve, reject: reject)
        let tool = configuration.enabledTools[index]
        emit(.toolCall(id: id, name: tool.toolName, kind: tool.kind, input: input))
        return promise
    }

    private func registerProgressHandler(_ pointer: OpaquePointer?, callID: String) -> QuickJSValue? {
        guard let pointer, ogq_is_function(context, pointer),
            let handler = duplicate(pointer)
        else {
            return throwToJS("onProgress expects a handler function")
        }
        guard pendingToolCalls[callID] != nil else { return undefined() }
        pendingProgressCallbacks[callID] = handler
        let buffered = pendingProgressChunks.removeValue(forKey: callID) ?? []
        for progress in buffered {
            deliverToolProgress(id: callID, progress: progress)
        }
        return undefined()
    }

    func deliverToolProgress(id: String, progress: NestedToolProgress) {
        guard pendingToolCalls[id] != nil else {
            pendingProgressCallbacks.removeValue(forKey: id)
            pendingProgressChunks.removeValue(forKey: id)
            return
        }
        guard let callback = pendingProgressCallbacks[id] else {
            var buffered = pendingProgressChunks[id] ?? []
            if buffered.count >= NESTED_TOOL_PROGRESS_CAPACITY {
                buffered.removeFirst()
            }
            buffered.append(progress)
            pendingProgressChunks[id] = buffered
            return
        }

        var object: [String: JSONValue] = ["text": .string(progress.text)]
        if let payload = progress.payload { object["payload"] = payload }
        guard let argument = jsValue(from: .object(object)) else { return }
        _ = call(callback, arguments: [argument])
        if ogq_has_exception(context) {
            _ = takeExceptionText()
        }
    }

    func resolveToolCall(id: String, result: Result<JSONValue, CodeModeError>) -> String? {
        guard let pending = pendingToolCalls.removeValue(forKey: id) else {
            return "unknown tool call `\(id)`"
        }
        pendingProgressCallbacks.removeValue(forKey: id)
        pendingProgressChunks.removeValue(forKey: id)

        let resolver: QuickJSValue
        let argument: QuickJSValue
        switch result {
        case .success(let response):
            guard let bridged = jsValue(from: response), !ogq_is_exception(bridged.pointer) else {
                return takeExceptionText() ?? "failed to serialize tool response"
            }
            resolver = pending.resolve
            argument = bridged
        case .failure(let error):
            guard let bridged = string(error.message) else {
                return "failed to allocate tool error"
            }
            resolver = pending.reject
            argument = bridged
        }
        return call(resolver, arguments: [argument])
    }

    private func scheduleTimeout(callback pointer: OpaquePointer?, delay: OpaquePointer?) -> QuickJSValue? {
        guard let pointer, ogq_is_function(context, pointer), let callback = duplicate(pointer) else {
            return throwToJS("setTimeout expects a function callback")
        }

        var requested: Double = 0
        if let delay, !ogq_is_undefined(delay), !ogq_is_null(delay),
            ogq_to_double(context, delay, &requested) < 0
        {
            let message = takeExceptionText() ?? "invalid timeout delay"
            return throwToJS(message)
        }
        let milliseconds: UInt64
        if requested.isFinite && requested > 0 {
            milliseconds = UInt64(min(requested.rounded(.towardZero), 1_000_000_000))
        } else {
            milliseconds = 0
        }

        let identifier = nextTimeoutID
        if nextTimeoutID < UInt64.max { nextTimeoutID += 1 }
        pendingTimeouts[identifier] = callback

        let mailbox = commands
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds))) {
            mailbox.send(.timeoutFired(id: identifier))
        }
        return value(taking: ogq_new_double(context, Double(identifier)))
    }

    private func clearTimeout(identifier: OpaquePointer?) {
        guard let identifier, !ogq_is_null(identifier), !ogq_is_undefined(identifier) else { return }
        var raw: Double = 0
        guard ogq_to_double(context, identifier, &raw) == 0,
            raw.isFinite, raw > 0, raw < Double(UInt64.max)
        else { return }
        pendingTimeouts.removeValue(forKey: UInt64(raw.rounded(.towardZero)))
    }

    func invokeTimeout(id: UInt64) -> String? {
        guard let callback = pendingTimeouts.removeValue(forKey: id) else { return nil }
        return call(callback, arguments: [])
    }

    private func emitText(_ pointer: OpaquePointer?) -> QuickJSValue? {
        let output: String
        switch serializeOutputText(pointer) {
        case .failure(let error):
            return throwToJS(error.message)
        case .success(let text):
            output = text
        }

        switch budget.admit(output) {
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
        return undefined()
    }

    private func emitImage(_ arguments: [OpaquePointer?]) -> QuickJSValue? {
        var detailOverride: String?
        if arguments.count > 1, let detail = arguments[1] {
            if ogq_is_string(detail) {
                detailOverride = stringValue(detail)
            } else if !ogq_is_null(detail) && !ogq_is_undefined(detail) {
                return throwToJS("image detail must be a string when provided")
            }
        }

        let image: JSONValue?
        switch jsonValue(from: arguments.first ?? nil) {
        case .failure(let error):
            return throwToJS(error.message)
        case .success(let parsed):
            image = parsed
        }
        switch JavaScriptOutputImage.normalize(value: image, detailOverride: detailOverride) {
        case .success(let item):
            emit(.contentItem(item))
            return undefined()
        case .failure(let error):
            return throwToJS(error.message)
        }
    }

    private func emitGeneratedImage(_ pointer: OpaquePointer?) -> QuickJSValue? {
        let image: JSONValue?
        switch jsonValue(from: pointer) {
        case .failure(let error):
            return throwToJS(error.message)
        case .success(let parsed):
            image = parsed
        }

        let hint: String?
        switch JavaScriptOutputImage.generatedImageOutputHint(value: image) {
        case .failure(let error):
            return throwToJS(error.message)
        case .success(let parsed):
            hint = parsed
        }
        switch JavaScriptOutputImage.normalize(value: image, detailOverride: nil) {
        case .failure(let error):
            return throwToJS(error.message)
        case .success(let item):
            emit(.contentItem(item))
            if let hint {
                emit(.contentItem(.inputText(text: hint)))
            }
            return undefined()
        }
    }

    private func emitNotification(_ pointer: OpaquePointer?) -> QuickJSValue? {
        let output: String
        switch serializeOutputText(pointer) {
        case .failure(let error):
            return throwToJS(error.message)
        case .success(let text):
            output = text
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return throwToJS("notify expects non-empty text")
        }
        emit(.notify(callId: configuration.toolCallId, text: output))
        return undefined()
    }

    private func storeValue(key: OpaquePointer?, value pointer: OpaquePointer?) -> QuickJSValue? {
        guard let key, let text = stringValue(key) else {
            return throwToJS("store key must be a string")
        }
        switch jsonValue(from: pointer) {
        case .failure(let error):
            return throwToJS(error.message)
        case .success(nil):
            return throwToJS("Unable to store \"\(text)\". Only plain serializable objects can be stored.")
        case .success(.some(let value)):
            storedValues[text] = value
            storedValueWrites[text] = value
            return undefined()
        }
    }

    private func loadValue(key: OpaquePointer?) -> QuickJSValue? {
        guard let key, let text = stringValue(key) else {
            return throwToJS("load key must be a string")
        }
        guard let stored = storedValues[text] else { return undefined() }
        guard let value = jsValue(from: stored), !ogq_is_exception(value.pointer) else {
            return throwToJS("failed to load stored value")
        }
        return value
    }

    private func serializeOutputText(_ pointer: OpaquePointer?) -> Result<String, CodeModeError> {
        guard let pointer else { return .success("undefined") }
        if ogq_is_undefined(pointer) { return .success("undefined") }
        if ogq_is_null(pointer) { return .success("null") }
        if ogq_is_bool(pointer) || ogq_is_number(pointer) || ogq_is_string(pointer) {
            return .success(stringValue(pointer) ?? "")
        }
        switch jsonText(from: pointer) {
        case .failure(let error):
            return .failure(error)
        case .success(let serialized):
            return .success(serialized ?? (stringValue(pointer) ?? ""))
        }
    }
}

#endif
