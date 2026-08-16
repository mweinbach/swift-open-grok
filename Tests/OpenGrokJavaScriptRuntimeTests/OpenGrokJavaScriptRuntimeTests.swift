// OpenGrokJavaScriptRuntimeTests.swift
//
// Behavior tests for the embedded per-cell JavaScript runtime. Where the
// protocol fixtures do not pin a behavior, each test cites the Rust source
// it encodes (crates/codegen/xai-grok-code-mode).

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared
import Testing

@testable import OpenGrokJavaScriptRuntime

#if canImport(JavaScriptCore)

// MARK: - Harness

/// Drains a runtime's event stream, with a deadline so a wedged runtime
/// fails the test instead of hanging the suite.
private final class EventCollector {
    private var iterator: AsyncStream<JavaScriptRuntimeEvent>.AsyncIterator

    init(_ stream: AsyncStream<JavaScriptRuntimeEvent>) {
        iterator = stream.makeAsyncIterator()
    }

    /// Next event, skipping the lifecycle noise (`.started` and the
    /// `.pending` heartbeats) that most tests do not care about.
    func next(skippingNoise: Bool = true) async -> JavaScriptRuntimeEvent? {
        while let event = await iterator.next() {
            if skippingNoise {
                if case .pending = event { continue }
                if case .started = event { continue }
            }
            return event
        }
        return nil
    }

    /// Collect until the stream produces a `.result`, returning everything
    /// seen (including the result).
    func drainToResult(timeout: Duration = .seconds(10)) async -> [JavaScriptRuntimeEvent] {
        var events: [JavaScriptRuntimeEvent] = []
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            guard let event = await next() else { return events }
            events.append(event)
            if case .result = event { return events }
        }
        return events
    }

    /// Consume events until the stream finishes. Returns false on timeout.
    func drainUntilClosed(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            guard await next() != nil else { return true }
        }
        return false
    }
}

private func configuration(
    source: String,
    tools: [EnabledToolMetadata] = [],
    storedValues: [String: JSONValue] = [:],
    maxOutputTokens: Int? = nil,
    executionCeilingMs: UInt64 = CODE_MODE_DEFAULT_EXECUTION_CEILING_MS
) -> JavaScriptCellConfiguration {
    JavaScriptCellConfiguration(
        toolCallId: "call_1",
        enabledTools: tools,
        source: source,
        storedValues: storedValues,
        maxOutputTokens: maxOutputTokens,
        executionCeilingMs: executionCeilingMs
    )
}

private func textItems(_ events: [JavaScriptRuntimeEvent]) -> [String] {
    events.compactMap { event in
        guard case .contentItem(.inputText(let text)) = event else { return nil }
        return text
    }
}

/// `.some(nil)` means the cell finished cleanly; `nil` means no result was
/// observed at all.
private func resultError(_ events: [JavaScriptRuntimeEvent]) -> String?? {
    for event in events {
        if case .result(_, let errorText) = event { return .some(errorText) }
    }
    return nil
}

private func storedWrites(_ events: [JavaScriptRuntimeEvent]) -> [String: JSONValue] {
    for event in events {
        if case .result(let writes, _) = event { return writes }
    }
    return [:]
}

private let demoTool = EnabledToolMetadata(
    toolName: ToolName.plain("demo"),
    globalName: "demo",
    description: "a demo tool",
    kind: .function
)

// MARK: - Evaluation

@Suite("JavaScript cell evaluation")
struct JavaScriptCellEvaluationTests {
    @Test("text() emits content items and the cell settles")
    func textOutput() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(source: "text('hello'); text({ a: 1 });"),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(textItems(collected) == ["hello", "{\"a\":1}"])
        #expect(resultError(collected) == .some(nil))
    }

    @Test("top-level await settles only after the awaited work resolves")
    func topLevelAwait() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    const value = await Promise.resolve(41);
                    text(String(value + 1));
                    """
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(textItems(collected) == ["42"])
        #expect(resultError(collected) == .some(nil))
    }

    @Test("a throwing cell reports error text, not a crash")
    func throwingCell() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(source: "text('before'); throw new Error('boom');"),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(textItems(collected) == ["before"])
        let error = try #require(resultError(collected))
        let text = try #require(error)
        #expect(text.contains("boom"))
    }

    /// runtime/callbacks.rs:313 + module_loader.rs:54: `exit()` throws the
    /// sentinel, and a rejection carrying the sentinel is a clean finish.
    @Test("exit() finishes the cell without an error")
    func exitIsClean() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(source: "text('done'); exit(); text('never');"),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(textItems(collected) == ["done"])
        #expect(resultError(collected) == .some(nil))
    }

    /// runtime/module_loader.rs:223: every module specifier is rejected.
    @Test("static imports are rejected with the Rust message")
    func staticImportsRejected() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(source: "import fs from 'node:fs';\ntext('nope');"),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        let outer = try #require(resultError(collected))
        let error = try #require(outer)
        #expect(error == "Unsupported import in exec: node:fs")
    }

    /// runtime/globals.rs:16 deletes these globals outright.
    @Test("shared-memory and Wasm globals are removed")
    func dangerousGlobalsRemoved() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    text(String(typeof globalThis.Atomics));
                    text(String(typeof globalThis.SharedArrayBuffer));
                    text(String(typeof globalThis.WebAssembly));
                    text(String(typeof globalThis.console));
                    """
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(textItems(collected) == ["undefined", "undefined", "undefined", "undefined"])
    }
}

// MARK: - Host bridge

@Suite("JavaScript host bridge")
struct JavaScriptHostBridgeTests {
    @Test("nested tool call suspends the cell and resumes with the result")
    func toolRoundTrip() async throws {
        let (runtime, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    const result = await tools.demo({ query: "swift" });
                    text(result.answer);
                    """,
                tools: [demoTool]
            ),
            pendingMode: .continueImmediately
        )
        let collector = EventCollector(events)

        let call = await collector.next()
        guard case .toolCall(let id, let name, let kind, let input) = try #require(call) else {
            Issue.record("expected a tool call event, got \(String(describing: call))")
            return
        }
        #expect(id == "tool-1")
        #expect(name == ToolName.plain("demo"))
        #expect(kind == .function)
        #expect(input == .object(["query": .string("swift")]))

        runtime.send(.toolResponse(id: id, result: .object(["answer": .string("ok")])))
        let collected = await collector.drainToResult()
        #expect(textItems(collected) == ["ok"])
        #expect(resultError(collected) == .some(nil))
    }

    @Test("tool errors reject the JavaScript promise with the bare message")
    func toolErrorRejects() async throws {
        let (runtime, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    try {
                      await tools.demo("x");
                    } catch (error) {
                      text(String(error));
                    }
                    """,
                tools: [demoTool]
            ),
            pendingMode: .continueImmediately
        )
        let collector = EventCollector(events)

        guard case .toolCall(let id, _, _, let input) = try #require(await collector.next()) else {
            Issue.record("expected a tool call event")
            return
        }
        #expect(input == .string("x"))
        runtime.send(.toolError(id: id, errorText: "tool exploded"))

        let collected = await collector.drainToResult()
        #expect(textItems(collected) == ["tool exploded"])
    }

    @Test("store() writes are reported with the result and load() reads them back")
    func storedValues() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    text(String(load('carried')));
                    store('fresh', { n: 7 });
                    text(String(load('fresh').n));
                    """,
                storedValues: ["carried": .string("from a previous cell")]
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(textItems(collected) == ["from a previous cell", "7"])
        #expect(storedWrites(collected) == ["fresh": .object(["n": .number(.int64(7))])])
    }

    /// runtime/callbacks.rs:184: only JSON-serializable values can be stored.
    @Test("store() rejects non-serializable values")
    func storeRejectsFunctions() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    try {
                      store('bad', () => {});
                    } catch (error) {
                      text(String(error));
                    }
                    """
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(
            textItems(collected) == [
                "Unable to store \"bad\". Only plain serializable objects can be stored."
            ]
        )
    }

    @Test("notify() emits a host notification carrying the exec call id")
    func notifyEmits() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(source: "notify('halfway');"),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        let notifications = collected.compactMap { event -> (String, String)? in
            guard case .notify(let callId, let text) = event else { return nil }
            return (callId, text)
        }
        #expect(notifications.count == 1)
        #expect(notifications.first?.0 == "call_1")
        #expect(notifications.first?.1 == "halfway")
    }

    @Test("yield_control() asks the cell actor to hand output back early")
    func yieldControlEmits() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(source: "text('partial'); yield_control();"),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        let yields = collected.filter {
            if case .yieldRequested = $0 { return true } else { return false }
        }
        #expect(yields.count == 1)
    }

    @Test("setTimeout resumes the cell through the command channel")
    func timersResumeTheCell() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    await new Promise((resolve) => setTimeout(resolve, 1));
                    text('after the timer');
                    """
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(textItems(collected) == ["after the timer"])
        #expect(resultError(collected) == .some(nil))
    }

    /// runtime/value.rs:44: only `data:` URLs may reach the wire.
    @Test("image() accepts data URLs and rejects remote ones")
    func imageNormalization() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    image('data:image/png;base64,AAAA');
                    try {
                      image('https://example.com/cat.png');
                    } catch (error) {
                      text(String(error));
                    }
                    """
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        let images = collected.compactMap { event -> FunctionCallOutputContentItem? in
            guard case .contentItem(let item) = event, case .inputImage = item else { return nil }
            return item
        }
        #expect(
            images == [
                .inputImage(imageUrl: "data:image/png;base64,AAAA", detail: DEFAULT_IMAGE_DETAIL)
            ]
        )
        #expect(textItems(collected) == [JavaScriptOutputImage.remoteURLError])
    }
}

// MARK: - Termination and bounds

@Suite("JavaScript termination and bounds")
struct JavaScriptTerminationTests {
    @Test("isolated worker hard-interrupts a CPU-bound JavaScript cell")
    func isolatedWorkerHardInterrupt() async throws {
        let executable = try #require(
            JavaScriptRuntimeSubprocess.workerExecutable(),
            "the safe test runner must provide the open-grok worker executable"
        )

        let (events, continuation) = AsyncStream<JavaScriptRuntimeEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let worker = try JavaScriptRuntimeSubprocess.start(
            executable: executable,
            configuration: configuration(
                source: "const until = Date.now() + 10000; while (Date.now() < until) {}"
            ),
            pendingMode: .continueImmediately,
            continuation: continuation
        )
        let collector = EventCollector(events)
        guard case .started = try #require(await collector.next(skippingNoise: false)) else {
            Issue.record("expected the isolated worker runtime to start")
            return
        }

        let start = ContinuousClock.now
        worker.terminate()
        #expect(await collector.drainUntilClosed(timeout: .seconds(2)))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    /// The ceiling is what reclaims a thread spinning inside JavaScript.
    /// Whether it *fires* is deliberately not asserted: it does under a
    /// normal process (verified out of band) but not under
    /// `swiftpm-testing-helper`, and a test that depended on it would leave a
    /// thread spinning for the rest of the shared test run.
    @Test("the execution ceiling is available on this host")
    func executionCeilingIsAvailable() {
        #expect(JavaScriptCellRuntime.supportsExecutionCeiling)
    }

    /// runtime/mod.rs:397 (`terminate_execution_stops_cpu_bound_module`): a
    /// CPU-bound cell must not hold the engine. V8 interrupts immediately;
    /// this port abandons the runtime thread instead, so the event stream
    /// closes at once and the bounded loop reclaims its own thread.
    @Test("terminate stops a cell that is busy inside JavaScript")
    func terminateBusyLoop() async throws {
        let (runtime, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: "const until = Date.now() + 3000; while (Date.now() < until) {}"),
            pendingMode: .continueImmediately
        )
        let collector = EventCollector(events)
        guard case .started = try #require(await collector.next(skippingNoise: false)) else {
            Issue.record("expected the runtime to start")
            return
        }

        let start = ContinuousClock.now
        runtime.beginTermination()
        #expect(await collector.drainUntilClosed(timeout: .seconds(2)), "the stream stayed open")
        #expect(
            ContinuousClock.now - start < .seconds(1),
            "termination waited for the JavaScript loop")
    }

    @Test("terminate stops a cell that is waiting on a nested tool")
    func terminateWaitingCell() async throws {
        let (runtime, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(source: "await tools.demo({});", tools: [demoTool]),
            pendingMode: .pauseUntilResumed
        )
        let collector = EventCollector(events)
        guard case .toolCall = try #require(await collector.next()) else {
            Issue.record("expected a tool call event")
            return
        }

        runtime.beginTermination()
        #expect(await collector.drainUntilClosed(), "the runtime thread did not stop")
    }

    /// Divergence from Rust, which accepts but ignores `max_output_tokens`
    /// (cell_actor/conversions.rs:36). The bound engages only when a caller
    /// sets it, so parity requests are unaffected.
    @Test("text output is bounded when a budget is set")
    func boundedOutput() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    text('x'.repeat(100));
                    text('this must not appear');
                    """,
                // 4 characters per token ⇒ a 40-character budget.
                maxOutputTokens: 10
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()
        let items = textItems(collected)

        #expect(items.count == 2)
        #expect(items.first == String(repeating: "x", count: 40))
        #expect(items.last == CODE_MODE_OUTPUT_TRUNCATION_NOTICE)
    }

    @Test("no budget means no truncation")
    func unboundedOutputByDefault() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(source: "text('y'.repeat(5000));"),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        #expect(textItems(collected) == [String(repeating: "y", count: 5000)])
    }
}

// MARK: - JSON bridge

@Suite("JavaScript JSON bridge")
struct JavaScriptJSONBridgeTests {
    @Test("round-trips every JSON shape")
    func roundTrip() {
        let value = JSONValue.object([
            "text": .string("hi"),
            "int": .number(.int64(-3)),
            "double": .number(.double(1.5)),
            "flag": .bool(true),
            "nothing": .null,
            "list": .array([.number(.int64(1)), .string("two")]),
        ])
        let text = JavaScriptJSONBridge.string(from: value)
        #expect(JavaScriptJSONBridge.value(fromJSON: text) == value)
    }

    @Test("top-level fragments survive the bridge")
    func fragments() {
        #expect(JavaScriptJSONBridge.value(fromJSON: "\"bare\"") == .string("bare"))
        #expect(JavaScriptJSONBridge.value(fromJSON: "7") == .number(.int64(7)))
        #expect(JavaScriptJSONBridge.value(fromJSON: "null") == .null)
        #expect(JavaScriptJSONBridge.string(from: .string("bare")) == "\"bare\"")
    }
}

// MARK: - Module loader

@Suite("JavaScript module loader")
struct JavaScriptModuleLoaderTests {
    // MARK: Specifier resolution

    /// module_loader.rs:164: the referrer's directory is the resolution base.
    @Test("bare specifiers pass through unchanged")
    func bareSpecifier() {
        let loader = JavaScriptModuleLoader()
        let spec = loader.resolve(specifier: "lodash")
        #expect(spec.raw == "lodash")
        #expect(spec.resolved == "lodash")
    }

    @Test("node: protocol specifiers pass through unchanged")
    func nodeProtocol() {
        let loader = JavaScriptModuleLoader()
        let spec = loader.resolve(specifier: "node:fs")
        #expect(spec.resolved == "node:fs")
    }

    @Test("relative specifier resolves against the referrer directory")
    func relativeToReferrer() {
        let loader = JavaScriptModuleLoader()
        let spec = loader.resolve(specifier: "./utils", referrer: "lib/main.mjs")
        #expect(spec.resolved == "lib/utils")
    }

    @Test("parent-traversal resolves against the referrer directory")
    func parentTraversal() {
        let loader = JavaScriptModuleLoader()
        let spec = loader.resolve(specifier: "../shared/helpers", referrer: "lib/sub/entry.mjs")
        #expect(spec.resolved == "lib/shared/helpers")
    }

    @Test("relative specifier against a bare referrer normalizes to the filename")
    func relativeAgainstBareReferrer() {
        let loader = JavaScriptModuleLoader()
        let spec = loader.resolve(
            specifier: "./utils",
            referrer: JavaScriptModuleLoader.mainModuleReferrer
        )
        #expect(spec.resolved == "utils")
    }

    @Test("dot segments are collapsed")
    func dotCollapsing() {
        let spec = JavaScriptModuleLoader.resolveSpecifier(
            "./a/./b/../c", relativeTo: "root/main.mjs"
        )
        #expect(spec == "root/a/c")
    }

    @Test("parent beyond root is dropped, not escaped")
    func parentBeyondRoot() {
        let spec = JavaScriptModuleLoader.resolveSpecifier(
            "../../escape", relativeTo: "single.mjs"
        )
        #expect(spec == "escape")
    }

    // MARK: Cache semantics

    /// V8's module map deduplicates by identity: the resolve callback fires
    /// at most once per specifier per instantiation. The loader mirrors this
    /// with a cache keyed by canonical specifier.
    @Test("repeated imports of the same specifier hit the cache")
    func cacheHit() {
        let loader = JavaScriptModuleLoader()
        let spec1 = loader.resolve(specifier: "lodash")
        let result1 = loader.load(spec1)
        #expect(loader.resolvedCount == 1)

        let spec2 = loader.resolve(specifier: "lodash")
        let result2 = loader.load(spec2)
        #expect(loader.resolvedCount == 1)
        #expect(result1 == result2)
    }

    @Test("different specifiers get separate cache entries")
    func cacheSeparation() {
        let loader = JavaScriptModuleLoader()
        _ = loader.load(loader.resolve(specifier: "a"))
        _ = loader.load(loader.resolve(specifier: "b"))
        #expect(loader.resolvedCount == 2)
    }

    @Test("relative and bare forms of the same canonical path share the cache")
    func cacheCanonical() {
        let loader = JavaScriptModuleLoader()
        _ = loader.load(loader.resolve(specifier: "./utils", referrer: "main.mjs"))
        #expect(loader.hasResolved("utils"))
        _ = loader.load(loader.resolve(specifier: "./utils", referrer: "main.mjs"))
        #expect(loader.resolvedCount == 1)
    }

    // MARK: Rejection

    /// module_loader.rs:223: every specifier is rejected with the Rust
    /// message format.
    @Test("all specifiers are rejected with the Rust error message")
    func rejectionMessage() {
        let loader = JavaScriptModuleLoader()
        let spec = loader.resolve(specifier: "node:fs")
        let result = loader.load(spec)
        #expect(result == .rejected(error: "Unsupported import in exec: node:fs"))
    }

    @Test("relative specifier rejection uses the raw specifier in the message")
    func relativeRejectionMessage() {
        let loader = JavaScriptModuleLoader()
        let spec = loader.resolve(specifier: "./helpers", referrer: "lib/main.mjs")
        let result = loader.load(spec)
        #expect(result == .rejected(error: "Unsupported import in exec: ./helpers"))
    }
}

// MARK: - Module loader integration

@Suite("JavaScript module loader integration")
struct JavaScriptModuleLoaderIntegrationTests {
    /// The existing static import test verifies the scanner → loader →
    /// rejection pipeline end to end. This test adds the relative-path
    /// case: the specifier is resolved and the error message uses the raw
    /// specifier text, matching Rust's resolve_module output.
    @Test("relative import specifiers are rejected with the raw specifier")
    func relativeImportRejected() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: "import utils from './helpers';\ntext('nope');"
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        let outer = try #require(resultError(collected))
        let error = try #require(outer)
        #expect(error == "Unsupported import in exec: ./helpers")
    }

    @Test("export statements are rejected before evaluation")
    func exportRejected() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: "export const x = 1;"
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        let outer = try #require(resultError(collected))
        let error = try #require(outer)
        #expect(error.contains("Unsupported import in exec"))
    }

    @Test("import() expression is not treated as a static import declaration")
    func dynamicImportNotStaticRejection() async throws {
        let (_, events) = try JavaScriptCellRuntime.start(
            configuration: configuration(
                source: """
                    try {
                      await import('./dynamic');
                    } catch (error) {
                      text('caught: ' + String(error));
                    }
                    """
            ),
            pendingMode: .continueImmediately
        )
        let collected = await EventCollector(events).drainToResult()

        let texts = textItems(collected)
        #expect(!texts.isEmpty, "dynamic import() should produce some output (caught error or native failure)")
        #expect(resultError(collected) == .some(nil), "the cell should settle cleanly via the catch")
    }
}

@Suite("JavaScript runtime capability")
struct JavaScriptRuntimeCapabilityTests {
    @Test("JavaScriptCore hosts report an available runtime")
    func available() {
        #expect(JavaScriptRuntimeCapability.current == .available)
        #expect(JavaScriptRuntimeCapability.current.unavailableError == nil)
    }
}

#else

@Suite("JavaScript runtime platform support")
struct JavaScriptRuntimeUnsupportedPlatformTests {
    @Test("starting a cell reports the unsupported platform")
    func unsupported() {
        #expect(JavaScriptRuntimeCapability.current == .unavailable)
        #expect(JavaScriptRuntimeCapability.current.unavailableError == .unsupportedPlatform)
        do {
            _ = try JavaScriptCellRuntime.start(
                configuration: JavaScriptCellConfiguration(toolCallId: "call_1", source: "text('x')")
            )
            Issue.record("expected JavaScriptCellRuntime.start to fail")
        } catch let error as JavaScriptRuntimeError {
            #expect(error == .unsupportedPlatform)
            #expect(error.kind == .unsupportedPlatform)
        } catch {
            Issue.record("expected JavaScriptRuntimeError, got \(error)")
        }
    }
}

#endif
