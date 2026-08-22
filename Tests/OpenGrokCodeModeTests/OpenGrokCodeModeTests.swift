// OpenGrokCodeModeTests.swift
//
// Engine tests for Code Mode: cell lifecycle, the nested-dispatch seam,
// termination, stale cells, and disposal. Behaviors the protocol fixtures do
// not pin cite the Rust source they encode
// (crates/codegen/xai-grok-code-mode).

// Every suite here drives a real JavaScript cell, and the runtime refuses with
// a typed "code mode requires JavaScriptCore, which is unavailable on this
// platform" wherever JSC is absent. Running them there does not test the
// refusal — it just reports the refusal as N failures — so they compile only
// where a cell can actually run. Cost: Linux gets no Code Mode coverage at all
// until a non-JSC engine exists; the refusal itself is the runtime's contract
// and belongs in a platform-agnostic test if someone wants it pinned.
#if canImport(JavaScriptCore)

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokJavaScriptRuntime
import OpenGrokShared
import Testing

@testable import OpenGrokCodeMode

// MARK: - Fake executor

/// A `CodeModeToolExecutor` standing in for the live composition's tool
/// dispatcher. Records every nested call and answers from a script.
private final class FakeToolExecutor: CodeModeToolExecutor, @unchecked Sendable {
    enum Behavior: Sendable {
        case respond(JSONValue)
        case fail(String)
        case stream([NestedToolProgress], result: JSONValue)
        case progressHandshake([NestedToolProgress], result: JSONValue)
        case streamThenBlock([NestedToolProgress])
        /// Park until the cell's cancellation token fires, then report the
        /// cancellation — the shape a well-behaved host dispatcher has.
        case blockUntilCancelled
    }

    private let lock = NSLock()
    private var behavior: Behavior
    private var invocations: [CodeModeNestedToolCall] = []
    private var progressSinks: [NestedToolProgressSink] = []
    private var pendingProgressAcknowledgement: CodeModeCancellationToken?
    private var observedCancellation = false
    private var notifications: [(callId: String, cellId: CellId, text: String)] = []
    private var closedCells: [CellId] = []
    private let started = DispatchSemaphore(value: 0)

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    /// Non-async so it stays usable from `async` callbacks, where
    /// `NSLock.lock()` is unavailable.
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func waitUntilFirstInvocation(timeout: DispatchTimeInterval = .seconds(10)) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    var recordedInvocations: [CodeModeNestedToolCall] {
        synchronized { invocations }
    }

    var recordedProgressSinks: [NestedToolProgressSink] {
        synchronized { progressSinks }
    }

    var sawCancellation: Bool {
        synchronized { observedCancellation }
    }

    var recordedNotifications: [(callId: String, cellId: CellId, text: String)] {
        synchronized { notifications }
    }

    var recordedClosedCells: [CellId] {
        synchronized { closedCells }
    }

    func replaceBehavior(_ behavior: Behavior) {
        synchronized { self.behavior = behavior }
    }

    private func recordInvocation(
        _ invocation: CodeModeNestedToolCall,
        progress: NestedToolProgressSink
    ) -> Behavior {
        synchronized {
            invocations.append(invocation)
            progressSinks.append(progress)
            return behavior
        }
    }

    private func recordCancellation() {
        synchronized { observedCancellation = true }
    }

    private func recordNotification(callId: String, cellId: CellId, text: String) {
        synchronized { notifications.append((callId, cellId, text)) }
    }

    func executeNestedTool(
        _ invocation: CodeModeNestedToolCall,
        cancellationToken: CodeModeCancellationToken,
        progress: NestedToolProgressSink
    ) async -> Result<JSONValue, CodeModeError> {
        let behavior = recordInvocation(invocation, progress: progress)
        started.signal()

        switch behavior {
        case .respond(let value):
            return .success(value)
        case .fail(let message):
            return .failure(CodeModeError(message))
        case .stream(let chunks, let result):
            for chunk in chunks {
                progress.push(chunk)
            }
            return .success(result)
        case .progressHandshake(let chunks, let result):
            for chunk in chunks {
                let acknowledgement = CodeModeCancellationToken()
                synchronized { pendingProgressAcknowledgement = acknowledgement }
                cancellationToken.onCancel { acknowledgement.cancel() }
                progress.push(chunk)
                await acknowledgement.waitUntilCancelled()
                guard !cancellationToken.isCancelled else {
                    return .failure(CodeModeError("cancelled"))
                }
            }
            synchronized { pendingProgressAcknowledgement = nil }
            return .success(result)
        case .streamThenBlock(let chunks):
            for chunk in chunks {
                progress.push(chunk)
            }
            await cancellationToken.waitUntilCancelled()
            recordCancellation()
            return .failure(CodeModeError("cancelled"))
        case .blockUntilCancelled:
            await cancellationToken.waitUntilCancelled()
            recordCancellation()
            return .failure(CodeModeError("cancelled"))
        }
    }

    func deliverNotification(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        recordNotification(callId: callId, cellId: cellId, text: text)
        if text == "progress-ack" {
            synchronized { pendingProgressAcknowledgement }?.cancel()
        }
        return .success(())
    }

    func cellDidClose(_ cellId: CellId) {
        synchronized { closedCells.append(cellId) }
    }
}

// MARK: - Helpers

private let demoDefinition = ToolDefinition(
    name: "demo",
    toolName: ToolName.plain("demo"),
    description: "a demo tool",
    kind: .function
)

private func execRequest(
    _ source: String,
    callId: String = "call_1",
    tools: [ToolDefinition] = [],
    yieldTimeMs: UInt64? = nil,
    maxOutputTokens: Int? = nil
) -> ExecuteRequest {
    ExecuteRequest(
        toolCallId: callId,
        enabledTools: tools,
        source: source,
        yieldTimeMs: yieldTimeMs,
        maxOutputTokens: maxOutputTokens
    )
}

private func session(
    executor: FakeToolExecutor,
    executionCeilingMs: UInt64 = CODE_MODE_DEFAULT_EXECUTION_CEILING_MS
) -> InProcessCodeModeSession {
    InProcessCodeModeSession(
        executor: executor,
        snapshot: CodeModeToolRegistrySnapshot(tools: [demoDefinition]),
        executionCeilingMs: executionCeilingMs
    )
}

/// Run one cell to its first frontier.
private func runToFirstResponse(
    _ session: InProcessCodeModeSession,
    _ request: ExecuteRequest
) async throws -> RuntimeResponse {
    let started = try requireSuccess(await session.execute(request))
    return try requireSuccess(await started.initialResponse())
}

private func requireSuccess<T, E: Error>(_ result: Result<T, E>) throws -> T {
    switch result {
    case .success(let value): return value
    case .failure(let error):
        Issue.record("expected success, got \(error)")
        throw error
    }
}

/// Poll until a condition holds. `cellDidClose` lands just after the
/// terminal response is handed to its waiter, so asserting on it directly
/// would race the cell's own cleanup.
private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

private func texts(_ response: RuntimeResponse) -> [String] {
    response.contentItems.compactMap { item in
        guard case .inputText(let text) = item else { return nil }
        return text
    }
}

// MARK: - Cell lifecycle

@Suite("Code mode cell lifecycle")
struct CodeModeCellLifecycleTests {
    @Test("a cell that finishes inside its yield window returns a Result")
    func completesWithinYieldWindow() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let response = try await runToFirstResponse(codeMode, execRequest("text('done');"))

        guard case .result(let cellId, _, let errorText) = response else {
            Issue.record("expected a Result response, got \(response)")
            return
        }
        #expect(cellId == CellId("1"))
        #expect(errorText == nil)
        #expect(texts(response) == ["done"])
    }

    /// docs/code-mode-port.md contract item 6: the runtime is persistent for
    /// a compatible agent timeline, so cells share `store()` / `load()`.
    @Test("state persists across exec calls in one session")
    func statePersistsAcrossExecs() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let first = try await runToFirstResponse(
            codeMode,
            execRequest("store('counter', 41); text('stored');")
        )
        #expect(texts(first) == ["stored"])

        let second = try await runToFirstResponse(
            codeMode,
            execRequest("store('counter', load('counter') + 1); text(String(load('counter')));", callId: "call_2")
        )
        #expect(texts(second) == ["42"])
        #expect(second.cellId == CellId("2"))

        let stored = await codeMode.storedValues()
        #expect(stored["counter"] == .number(.int64(42)))
    }

    @Test("separate sessions do not share stored values")
    func sessionsAreIsolated() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let first = session(executor: executor)
        let second = session(executor: executor)
        defer {
            Task {
                _ = await first.shutdown()
                _ = await second.shutdown()
            }
        }

        _ = try await runToFirstResponse(first, execRequest("store('secret', 'a');"))
        let response = try await runToFirstResponse(
            second,
            execRequest("text(String(load('secret')));")
        )
        #expect(texts(response) == ["undefined"])
    }

    @Test("a cell that outruns its yield window yields, then terminate ends it")
    func yieldsThenTerminates() async throws {
        // The tool never answers within the 50ms window, so exec yields.
        let blocking = FakeToolExecutor(behavior: .blockUntilCancelled)
        let blockingSession = InProcessCodeModeSession(
            executor: blocking,
            snapshot: CodeModeToolRegistrySnapshot(tools: [demoDefinition])
        )
        defer { Task { _ = await blockingSession.shutdown() } }

        let response = try await runToFirstResponse(
            blockingSession,
            execRequest(
                "text('before'); await tools.demo({}); text('after');",
                tools: [demoDefinition],
                yieldTimeMs: 50
            )
        )
        guard case .yielded(let cellId, _) = response else {
            Issue.record("expected a Yielded response, got \(response)")
            return
        }
        #expect(texts(response) == ["before"])

        // The cell is still live: terminating it reports Terminated.
        let outcome = try requireSuccess(await blockingSession.terminate(cellId))
        guard case .liveCell(let terminal) = outcome else {
            Issue.record("expected a live cell, got \(outcome)")
            return
        }
        guard case .terminated = terminal else {
            Issue.record("expected Terminated, got \(terminal)")
            return
        }
    }
}

// MARK: - Nested dispatch seam

@Suite("Code mode nested tool dispatch")
struct CodeModeNestedDispatchTests {
    @Test("a nested call round-trips through the executor seam")
    func nestedToolRoundTrip() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.object(["answer": .string("42")])))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let response = try await runToFirstResponse(
            codeMode,
            execRequest(
                """
                const result = await tools.demo({ question: "meaning" });
                text(result.answer);
                """,
                tools: [demoDefinition]
            )
        )

        #expect(texts(response) == ["42"])
        let invocations = executor.recordedInvocations
        #expect(invocations.count == 1)
        #expect(invocations.first?.toolName == ToolName.plain("demo"))
        #expect(invocations.first?.toolKind == .function)
        #expect(invocations.first?.cellId == CellId("1"))
        #expect(invocations.first?.runtimeToolCallId == "tool-1")
        #expect(invocations.first?.input == .object(["question": .string("meaning")]))
    }

    @Test("an executor failure surfaces as a JavaScript rejection")
    func nestedToolFailure() async throws {
        let executor = FakeToolExecutor(behavior: .fail("permission denied"))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let response = try await runToFirstResponse(
            codeMode,
            execRequest(
                """
                try {
                  await tools.demo({});
                } catch (error) {
                  text(String(error));
                }
                """,
                tools: [demoDefinition]
            )
        )
        #expect(texts(response) == ["permission denied"])
    }

    /// The snapshot is the authority on what `tools.*` may reach; anything
    /// else fails closed (docs/code-mode-port.md).
    @Test("a tool outside the registry snapshot is refused")
    func unknownToolFailsClosed() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = InProcessCodeModeSession(
            executor: executor,
            snapshot: CodeModeToolRegistrySnapshot(tools: [])
        )
        defer { Task { _ = await codeMode.shutdown() } }

        let response = try await runToFirstResponse(
            codeMode,
            execRequest(
                """
                try {
                  await tools.demo({});
                } catch (error) {
                  text(String(error));
                }
                """,
                tools: [demoDefinition]
            )
        )
        #expect(texts(response) == ["unknown code mode tool `demo`"])
        #expect(executor.recordedInvocations.isEmpty)
    }

    @Test("notify() reaches the executor with the outer exec call id")
    func notificationsReachTheExecutor() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        _ = try await runToFirstResponse(
            codeMode,
            execRequest("notify('working on it'); text('done');", callId: "call_outer")
        )

        let notifications = executor.recordedNotifications
        #expect(notifications.count == 1)
        #expect(notifications.first?.callId == "call_outer")
        #expect(notifications.first?.text == "working on it")
    }
}

@Suite("Code mode nested tool progress lifecycle")
struct CodeModeNestedProgressTests {
    @Test("progress handlers run while the host tool is still waiting")
    func progressHandlerAndRunningHostCanHandshake() async throws {
        let executor = FakeToolExecutor(behavior: .progressHandshake([
            .text("a"), .text("b"), .text("c")
        ], result: .string("done")))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let response = try await runToFirstResponse(
            codeMode,
            execRequest(
                """
                const chunks = [];
                const pending = tools.demo({});
                pending.onProgress((chunk) => {
                  chunks.push(chunk.text);
                  notify("progress-ack");
                });
                text(JSON.stringify({ chunks, resolved: await pending }));
                """,
                tools: [demoDefinition],
                yieldTimeMs: 1_000
            )
        )

        #expect(texts(response) == [#"{"chunks":["a","b","c"],"resolved":"done"}"#])
        #expect(executor.recordedNotifications.map { $0.text } == [
            "progress-ack", "progress-ack", "progress-ack"
        ])
    }

    @Test("real cells receive ordered text and structured progress through the executor")
    func progressCrossesEveryRuntimeAndDelegateSeam() async throws {
        let executor = FakeToolExecutor(behavior: .stream([
            .text("first"),
            .withPayload("second", .object(["step": .number(.int64(2))])),
            .text("third"),
        ], result: .string("done")))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let response = try await runToFirstResponse(
            codeMode,
            execRequest(
                """
                const chunks = [];
                const pending = tools.demo({});
                pending.onProgress((chunk) => {
                  chunks.push([chunk.text, chunk.payload]);
                });
                text(JSON.stringify({ chunks, resolved: await pending }));
                """,
                tools: [demoDefinition]
            )
        )

        #expect(texts(response) == [
            #"{"chunks":[["first",null],["second",{"step":2}],["third",null]],"resolved":"done"}"#
        ])
        #expect(executor.recordedInvocations.count == 1)
    }

    @Test("throwing and absent JavaScript handlers never alter the nested result")
    func observationalHandlersCannotFailTheInvocation() async throws {
        let executor = FakeToolExecutor(behavior: .stream([
            .text("ignored")
        ], result: .string("done")))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let throwing = try await runToFirstResponse(
            codeMode,
            execRequest(
                """
                const pending = tools.demo({});
                pending.onProgress(() => { throw new Error("observation failed"); });
                text(String(await pending));
                """,
                tools: [demoDefinition]
            )
        )
        #expect(texts(throwing) == ["done"])

        let absent = try await runToFirstResponse(
            codeMode,
            execRequest("text(String(await tools.demo({})));", callId: "next", tools: [demoDefinition])
        )
        #expect(texts(absent) == ["done"])
    }

    @Test("terminating a cell closes stale progress before its call ID is reused")
    func terminatedCellProgressCannotLeakIntoNextCell() async throws {
        let executor = FakeToolExecutor(behavior: .streamThenBlock([.text("before-cancel")]))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let first = try await runToFirstResponse(
            codeMode,
            execRequest(
                """
                const pending = tools.demo({});
                pending.onProgress((chunk) => text(chunk.text));
                await pending;
                """,
                tools: [demoDefinition],
                yieldTimeMs: 50
            )
        )
        guard case .yielded(let firstCellID, _) = first else {
            Issue.record("expected a yielded cell before cancellation")
            return
        }
        #expect(texts(first) == ["before-cancel"])
        let staleSink = try #require(executor.recordedProgressSinks.first)

        let terminal = try requireSuccess(await codeMode.terminate(firstCellID))
        guard case .liveCell(.terminated) = terminal else {
            Issue.record("expected a terminated live cell")
            return
        }
        #expect(staleSink.isClosed)
        staleSink.push(.text("stale"))

        executor.replaceBehavior(.stream([.text("fresh")], result: .null))
        let second = try await runToFirstResponse(
            codeMode,
            execRequest(
                """
                const pending = tools.demo({});
                pending.onProgress((chunk) => text(chunk.text));
                await pending;
                """,
                callId: "next-cell",
                tools: [demoDefinition]
            )
        )
        #expect(texts(second) == ["fresh"])
        #expect(executor.recordedInvocations.map(\.runtimeToolCallId) == ["tool-1", "tool-1"])
    }
}

// MARK: - Termination

@Suite("Code mode termination")
struct CodeModeTerminationTests {
    /// cell_actor/mod.rs:142: cancelling the cell token cancels every
    /// in-flight callback exactly once.
    @Test("terminate cancels an in-flight nested tool call")
    func terminateCancelsNestedCall() async throws {
        let executor = FakeToolExecutor(behavior: .blockUntilCancelled)
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let started = try requireSuccess(
            await codeMode.execute(
                execRequest("await tools.demo({});", tools: [demoDefinition], yieldTimeMs: 50)
            )
        )
        #expect(executor.waitUntilFirstInvocation())

        let outcome = try requireSuccess(await codeMode.terminate(started.cellId))
        guard case .liveCell(let response) = outcome, case .terminated = response else {
            Issue.record("expected a terminated live cell, got \(outcome)")
            return
        }
        #expect(executor.sawCancellation)
        #expect(await eventually { executor.recordedClosedCells == [started.cellId] })
    }

    /// The ceiling is the only thing that reclaims a thread spinning inside
    /// JavaScript, so its availability is worth asserting directly rather
    /// than inferring from a downstream failure.
    ///
    /// Whether it *fires* is deliberately not asserted here: it does under a
    /// normal process (verified out of band) but not under
    /// `swiftpm-testing-helper`, and a test that depended on it would leave a
    /// thread spinning for the rest of the shared test run. Termination does
    /// not depend on it — see the test below.
    @Test("the JavaScriptCore execution ceiling is available on this host")
    func executionCeilingIsAvailable() {
        #expect(JavaScriptCellRuntime.supportsExecutionCeiling)
    }

    /// runtime/mod.rs:397 (`terminate_execution_stops_cpu_bound_module`): a
    /// CPU-bound cell must not hold the engine. The loop is bounded so the
    /// runtime thread reclaims itself even where the ceiling cannot fire,
    /// and `terminate` must return long before the loop would end on its own.
    @Test("terminate stops a cell that is busy inside JavaScript")
    func terminateBusyLoop() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let started = try requireSuccess(
            await codeMode.execute(
                execRequest(
                    "const until = Date.now() + 3000; while (Date.now() < until) {}",
                    yieldTimeMs: 50)))
        // The exec observation yields once its window elapses even though the
        // cell is pinned inside JavaScript.
        let yielded = try requireSuccess(await started.initialResponse())
        guard case .yielded = yielded else {
            Issue.record("expected a Yielded response, got \(yielded)")
            return
        }

        let start = ContinuousClock.now
        let outcome = try requireSuccess(await codeMode.terminate(started.cellId))
        let elapsed = ContinuousClock.now - start
        guard case .liveCell(let response) = outcome, case .terminated = response else {
            Issue.record("expected a terminated live cell, got \(outcome)")
            return
        }
        #expect(elapsed < .seconds(1), "terminate waited for the JavaScript loop")
        #expect(await eventually { executor.recordedClosedCells == [started.cellId] })
    }

    /// cell_actor/types.rs:178: a second terminate is rejected rather than
    /// producing a second terminal event.
    @Test("a second terminate reports that the cell is already terminating")
    func doubleTerminateRejected() async throws {
        let executor = FakeToolExecutor(behavior: .blockUntilCancelled)
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let started = try requireSuccess(
            await codeMode.execute(
                execRequest("await tools.demo({});", tools: [demoDefinition], yieldTimeMs: 50)
            )
        )
        #expect(executor.waitUntilFirstInvocation())
        _ = try requireSuccess(await codeMode.terminate(started.cellId))

        // The cell is gone now, so the second call is a stale-cell outcome.
        let second = try requireSuccess(await codeMode.terminate(started.cellId))
        guard case .missingCell(let response) = second else {
            Issue.record("expected a missing cell, got \(second)")
            return
        }
        #expect(
            response == .result(
                cellId: started.cellId,
                contentItems: [],
                errorText: "exec cell \(started.cellId) not found"
            )
        )
    }
}

// MARK: - Stale cells and disposal

@Suite("Code mode stale cells and disposal")
struct CodeModeDisposalTests {
    /// service.rs:410: a wait on a cell id the session no longer owns is a
    /// `MissingCell` stale outcome, not a hard error.
    @Test("waiting on a completed cell reports a stale cell")
    func staleCellRejection() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let started = try requireSuccess(await codeMode.execute(execRequest("text('quick');")))
        _ = try requireSuccess(await started.initialResponse())

        let outcome = try requireSuccess(
            await codeMode.wait(WaitRequest(cellId: started.cellId, yieldTimeMs: 50))
        )
        guard case .missingCell(let response) = outcome else {
            Issue.record("expected a missing cell, got \(outcome)")
            return
        }
        #expect(texts(response).isEmpty)
        guard case .result(_, _, let errorText) = response else {
            Issue.record("expected a Result payload")
            return
        }
        #expect(errorText == "exec cell \(started.cellId) not found")
    }

    @Test("waiting on a cell id that never existed reports a stale cell")
    func unknownCellRejection() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let outcome = try requireSuccess(
            await codeMode.wait(WaitRequest(cellId: CellId("nope"), yieldTimeMs: 10))
        )
        guard case .missingCell = outcome else {
            Issue.record("expected a missing cell, got \(outcome)")
            return
        }
    }

    @Test("shutdown is idempotent and disposes live cells")
    func shutdownIsIdempotent() async throws {
        let executor = FakeToolExecutor(behavior: .blockUntilCancelled)
        let codeMode = session(executor: executor)

        let started = try requireSuccess(
            await codeMode.execute(
                execRequest("await tools.demo({});", tools: [demoDefinition], yieldTimeMs: 50)
            )
        )
        #expect(executor.waitUntilFirstInvocation())

        _ = try requireSuccess(await codeMode.shutdown())
        _ = try requireSuccess(await codeMode.shutdown())
        _ = try requireSuccess(await codeMode.shutdown())

        #expect(executor.sawCancellation)
        #expect(executor.recordedClosedCells == [started.cellId])

        // Every entry point fails closed afterwards.
        switch await codeMode.execute(execRequest("text('after');")) {
        case .success:
            Issue.record("execute should fail after shutdown")
        case .failure(let error):
            #expect(error.message == "code mode session is shutting down")
        }
        let outcome = try requireSuccess(
            await codeMode.wait(WaitRequest(cellId: started.cellId, yieldTimeMs: 10))
        )
        guard case .missingCell = outcome else {
            Issue.record("expected a missing cell after shutdown, got \(outcome)")
            return
        }
    }

    /// Divergence from Rust, which never enforces `max_output_tokens`
    /// (cell_actor/conversions.rs:36). Requests that leave it unset behave
    /// exactly as the Rust engine does.
    @Test("an exec output budget truncates the cell's text")
    func boundedOutput() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let response = try await runToFirstResponse(
            codeMode,
            execRequest("text('z'.repeat(200)); text('dropped');", maxOutputTokens: 10)
        )
        let items = texts(response)
        #expect(items.count == 2)
        #expect(items.first == String(repeating: "z", count: 40))
        #expect(items.last == CODE_MODE_OUTPUT_TRUNCATION_NOTICE)
    }
}

// MARK: - Protocol projection

@Suite("Code mode protocol projection")
struct CodeModeProtocolProjectionTests {
    /// service.rs:36 and docs/code-mode-port.md: windows of at least ten
    /// seconds get a one-second runtime grace, shorter ones do not.
    @Test("the yield grace period applies only from ten seconds up")
    func yieldGrace() {
        #expect(codeModeYieldTimeout(yieldTimeMs: 50) == 50)
        #expect(codeModeYieldTimeout(yieldTimeMs: 9_999) == 9_999)
        #expect(codeModeYieldTimeout(yieldTimeMs: 10_000) == 11_000)
        #expect(codeModeYieldTimeout(yieldTimeMs: DEFAULT_EXEC_YIELD_TIME_MS) == 31_000)
        #expect(codeModeYieldTimeout(yieldTimeMs: 30_000) == 31_000)
    }

    @Test("a real cell's response encodes to the Rust external-tag wire form")
    func responseWireForm() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let response = try await runToFirstResponse(codeMode, execRequest("text('hi');"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(response), encoding: .utf8)
        #expect(
            json == """
                {"Result":{"cell_id":"1","content_items":[{"text":"hi","type":"input_text"}],"error_text":null}}
                """
        )

        let decoded = try JSONDecoder().decode(
            RuntimeResponse.self,
            from: try encoder.encode(response)
        )
        #expect(decoded == response)
    }

    @Test("a stale wait outcome matches the MissingCell golden")
    func missingCellWireForm() async throws {
        let executor = FakeToolExecutor(behavior: .respond(.null))
        let codeMode = session(executor: executor)
        defer { Task { _ = await codeMode.shutdown() } }

        let outcome = try requireSuccess(
            await codeMode.wait(WaitRequest(cellId: CellId("ghost"), yieldTimeMs: 10))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(outcome), encoding: .utf8)
        #expect(
            json == """
                {"MissingCell":{"Result":{"cell_id":"ghost","content_items":[],"error_text":"exec cell ghost not found"}}}
                """
        )
        #expect(try JSONDecoder().decode(WaitOutcome.self, from: try encoder.encode(outcome)) == outcome)
    }

    /// docs/code-mode-port.md item 8: `exec` / `wait` are transport, not
    /// user-visible tool cards, and cell transport detail stays hidden.
    @Test("transport projection hides cell plumbing from the UI")
    func transportProjection() {
        #expect(CodeModeTransportProjection.isTransportTool(ToolName.plain(PUBLIC_TOOL_NAME)))
        #expect(CodeModeTransportProjection.isTransportTool(ToolName.plain(WAIT_TOOL_NAME)))
        #expect(!CodeModeTransportProjection.isTransportTool(ToolName.plain("demo")))

        let response = RuntimeResponse.yielded(
            cellId: CellId("7"),
            contentItems: [.inputText(text: "partial")]
        )
        #expect(
            CodeModeTransportProjection.modelVisibleContent(response) == [
                .inputText(text: "partial")
            ]
        )
        #expect(!CodeModeTransportProjection.producesUserVisibleCard(response))

        let pending = ExecuteToPendingOutcome.pending(
            cellId: CellId("7"),
            contentItems: [],
            pendingToolCallIds: ["tool-1"]
        )
        let hidden = CodeModeTransportProjection.hiddenDetails(pending)
        #expect(hidden.cellId == CellId("7"))
        #expect(hidden.pendingToolCallIds == ["tool-1"])
        #expect(hidden.isPendingFrontier)
    }

    @Test("the registry snapshot generates the tools.* namespace")
    func registrySnapshot() {
        let snapshot = CodeModeToolRegistrySnapshot(
            tools: [
                demoDefinition,
                ToolDefinition(
                    name: "mcp__ologs__get_profile",
                    toolName: ToolName.namespaced("mcp__ologs__", "get_profile"),
                    description: "profile",
                    kind: .function
                ),
            ]
        )
        #expect(snapshot.globalNames == ["demo", "mcp__ologs__get_profile"])
        #expect(snapshot.definition(for: ToolName.plain("demo")) == demoDefinition)
        #expect(snapshot.definition(for: ToolName.plain("absent")) == nil)
        #expect(snapshot.executeRequestTools.count == 2)
    }
}

#endif /* canImport(JavaScriptCore) */
