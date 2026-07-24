// OpenGrokCodeModeProtocolTests.swift
//
// Fixture-backed wire-contract + protocol tests for OpenGrokCodeModeProtocol.
// Translated from crates/codegen/xai-grok-code-mode-protocol (runtime wire
// shapes, description helpers, session oneshot semantics).

import Testing
import Foundation
@testable import OpenGrokCodeModeProtocol
import OpenGrokShared

// MARK: - Helpers

private func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try makeEncoder().encode(value)
    return String(data: data, encoding: .utf8)!
}

private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try decodeJSON(T.self, try encodeJSON(value))
}

// MARK: - External tagging wire goldens

@Suite("Code Mode external tagging")
struct CodeModeExternalTagTests {
    @Test("RuntimeResponse externally tagged PascalCase")
    func runtimeResponse() throws {
        let cell = CellId("1")
        let yielded = RuntimeResponse.yielded(cellId: cell, contentItems: [])
        #expect(try encodeJSON(yielded) == #"{"Yielded":{"cell_id":"1","content_items":[]}}"#)
        #expect(try roundTrip(yielded) == yielded)

        let terminated = RuntimeResponse.terminated(cellId: cell, contentItems: [
            .inputText(text: "hi")
        ])
        let tJSON = try encodeJSON(terminated)
        #expect(tJSON.hasPrefix(#"{"Terminated":"#))
        #expect(try roundTrip(terminated) == terminated)

        let result = RuntimeResponse.result(cellId: cell, contentItems: [], errorText: nil)
        let rJSON = try encodeJSON(result)
        #expect(rJSON.contains(#""Result""#))
        #expect(rJSON.contains(#""error_text":null"#))
        #expect(try roundTrip(result) == result)

        let errResult = RuntimeResponse.result(cellId: cell, contentItems: [], errorText: "boom")
        #expect(try roundTrip(errResult) == errResult)
    }

    @Test("WaitOutcome / ExecuteToPending / WaitToPending external tags")
    func waitOutcomes() throws {
        let response = RuntimeResponse.yielded(cellId: CellId("c"), contentItems: [])
        let live = WaitOutcome.liveCell(response)
        #expect(try encodeJSON(live).hasPrefix(#"{"LiveCell":"#))
        #expect(try roundTrip(live) == live)
        #expect(live.response == response)

        let missing = WaitOutcome.missingCell(
            .result(cellId: CellId("c"), contentItems: [], errorText: "gone")
        )
        #expect(try encodeJSON(missing).hasPrefix(#"{"MissingCell":"#))
        #expect(try roundTrip(missing) == missing)

        let pending = ExecuteToPendingOutcome.pending(
            cellId: CellId("c"),
            contentItems: [.inputText(text: "partial")],
            pendingToolCallIds: ["t1", "t2"]
        )
        let pJSON = try encodeJSON(pending)
        #expect(pJSON.hasPrefix(#"{"Pending":"#))
        #expect(pJSON.contains("\"pending_tool_call_ids\""))
        #expect(try roundTrip(pending) == pending)

        let completed = ExecuteToPendingOutcome.completed(response)
        #expect(try encodeJSON(completed).hasPrefix(#"{"Completed":"#))
        #expect(try roundTrip(completed) == completed)

        let wtpLive = WaitToPendingOutcome.liveCell(pending)
        #expect(try roundTrip(wtpLive) == wtpLive)
        let wtpMissing = WaitToPendingOutcome.missingCell(response)
        #expect(try roundTrip(wtpMissing) == wtpMissing)
    }

    @Test("ToolName is keyed object not bare string")
    func toolNameObject() throws {
        let plain = ToolName.plain("exec")
        #expect(try encodeJSON(plain) == #"{"name":"exec","namespace":null}"#)
        #expect(try roundTrip(plain) == plain)
        #expect(plain.description == "exec")

        let ns = ToolName.namespaced("mcp__ologs__", "get_profile")
        let json = try encodeJSON(ns)
        #expect(json.contains(#""name":"get_profile""#))
        #expect(json.contains(#""namespace":"mcp__ologs__""#))
        #expect(try roundTrip(ns) == ns)
        #expect(ns.description == "mcp__ologs__get_profile")

        // Reject bare string form
        #expect(throws: DecodingError.self) {
            try decodeJSON(ToolName.self, "\"exec\"")
        }
    }

    @Test("FunctionCallOutputContentItem internal tagging")
    func contentItems() throws {
        let text = FunctionCallOutputContentItem.inputText(text: "hello")
        #expect(try encodeJSON(text) == #"{"text":"hello","type":"input_text"}"#)
        #expect(try roundTrip(text) == text)

        let image = FunctionCallOutputContentItem.inputImage(
            imageUrl: "data:image/png;base64,xx",
            detail: .high
        )
        let iJSON = try encodeJSON(image)
        #expect(iJSON.contains(#""type":"input_image""#))
        #expect(iJSON.contains("\"image_url\""))
        #expect(iJSON.contains("\"high\""))
        #expect(try roundTrip(image) == image)

        let noDetail = FunctionCallOutputContentItem.inputImage(
            imageUrl: "data:image/png;base64,yy",
            detail: nil
        )
        let noDetailJSON = try encodeJSON(noDetail)
        #expect(!noDetailJSON.contains("\"detail\""))
        #expect(try roundTrip(noDetail) == noDetail)
        #expect(DEFAULT_IMAGE_DETAIL == .high)
    }

    @Test("ExecuteRequest / WaitRequest / nested tool call")
    func requestsAndNested() throws {
        let def = ToolDefinition(
            name: "read_file",
            toolName: .plain("read_file"),
            description: "Read a file",
            kind: .function,
            inputSchema: .object(["type": .string("object")]),
            outputSchema: nil
        )
        let exec = ExecuteRequest(
            toolCallId: "tc1",
            enabledTools: [def],
            source: "text('hi')",
            yieldTimeMs: 5000,
            maxOutputTokens: 1000
        )
        #expect(try roundTrip(exec) == exec)
        let eJSON = try encodeJSON(exec)
        #expect(eJSON.contains("\"tool_call_id\""))
        #expect(eJSON.contains("\"enabled_tools\""))
        #expect(eJSON.contains("\"yield_time_ms\""))

        let wait = WaitRequest(cellId: CellId("c"), yieldTimeMs: 10_000)
        #expect(try roundTrip(wait) == wait)

        let nested = CodeModeNestedToolCall(
            cellId: CellId("c"),
            runtimeToolCallId: "rt1",
            toolName: .namespaced("mcp__s__", "tool"),
            toolKind: .function,
            input: .object(["path": .string("/tmp")])
        )
        #expect(try roundTrip(nested) == nested)
        let nJSON = try encodeJSON(nested)
        #expect(nJSON.contains("\"runtime_tool_call_id\""))
        #expect(nJSON.contains("\"tool_name\""))
        #expect(nJSON.contains("\"tool_kind\""))
    }
}

// MARK: - Description / pragma

@Suite("Exec description + pragma")
struct CodeModeDescriptionTests {
    @Test("parse exec source without pragma")
    func withoutPragma() throws {
        switch parseExecSource("const x = 1;") {
        case .success(let parsed):
            #expect(parsed.code == "const x = 1;")
            #expect(parsed.yieldTimeMs == nil)
            #expect(parsed.maxOutputTokens == nil)
        case .failure(let err):
            Issue.record("unexpected failure: \(err)")
        }
    }

    @Test("parse exec source with pragma")
    func withPragma() throws {
        let src = """
        // @exec: {"yield_time_ms": 10000, "max_output_tokens": 1000}
        text('hello')
        """
        switch parseExecSource(src) {
        case .success(let parsed):
            #expect(parsed.yieldTimeMs == 10_000)
            #expect(parsed.maxOutputTokens == 1000)
            #expect(parsed.code.contains("text('hello')"))
        case .failure(let err):
            Issue.record("unexpected failure: \(err)")
        }
    }

    @Test("empty source rejected")
    func emptyRejected() {
        switch parseExecSource("   ") {
        case .success:
            Issue.record("expected failure")
        case .failure(let err):
            #expect(err.message.contains("non-empty"))
        }
    }

    @Test("pragma without following JS rejected")
    func pragmaOnlyRejected() {
        switch parseExecSource(#"// @exec: {"yield_time_ms": 1}"#) {
        case .success:
            Issue.record("expected failure")
        case .failure(let err):
            #expect(err.message.contains("subsequent lines"))
        }
    }

    @Test("normalize identifier rewrites invalid characters")
    func normalize() {
        // Mirrors Rust `normalize_identifier_rewrites_invalid_characters`.
        #expect(normalizeCodeModeIdentifier("mcp__ologs__get_profile") == "mcp__ologs__get_profile")
        #expect(normalizeCodeModeIdentifier("hidden-dynamic-tool") == "hidden_dynamic_tool")
        #expect(normalizeCodeModeIdentifier("foo-bar") == "foo_bar")
        // Leading digit is invalid for a JS identifier start → rewritten to `_`.
        #expect(normalizeCodeModeIdentifier("123abc") == "_23abc")
        #expect(!isCodeModeNestedTool(PUBLIC_TOOL_NAME))
        #expect(!isCodeModeNestedTool(WAIT_TOOL_NAME))
        #expect(isCodeModeNestedTool("read_file"))
        #expect(PUBLIC_TOOL_NAME == "exec")
        #expect(WAIT_TOOL_NAME == "wait")
    }

    @Test("build wait/exec descriptions are non-empty")
    func descriptions() {
        let wait = buildWaitToolDescription()
        #expect(!wait.isEmpty)
        #expect(wait.lowercased().contains("wait") || wait.contains("cell"))

        let def = ToolDefinition(
            name: "echo",
            toolName: .plain("echo"),
            description: "Echo input",
            kind: .freeform
        )
        let exec = buildExecToolDescription(
            enabledTools: [def],
            deferredTools: [],
            namespaceDescriptions: [:],
            codeModeOnly: true
        )
        #expect(!exec.isEmpty)
        #expect(exec.contains("exec") || exec.contains("JavaScript") || exec.contains("tools"))

        let sample = renderCodeModeSample(
            description: def.description,
            toolName: def.name,
            inputName: "input",
            inputType: "string",
            outputType: "unknown"
        )
        #expect(!sample.isEmpty)

        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path"),
                ])
            ]),
            "required": .array([.string("path")]),
        ])
        let ts = renderJSONSchemaToTypeScript(schema)
        #expect(ts.contains("path") || ts.contains("string") || !ts.isEmpty)
    }

    @Test("augment tool definition + enabled metadata")
    func augmentAndMetadata() {
        let def = ToolDefinition(
            name: "read_file",
            toolName: .plain("read_file"),
            description: "Read",
            kind: .function,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")])
                ]),
            ])
        )
        let augmented = augmentToolDefinition(def)
        #expect(augmented.description.count >= def.description.count)
        let meta = enabledToolMetadata(def)
        #expect(meta.toolName == def.toolName)
        #expect(meta.globalName == "read_file")
        #expect(meta.kind == .function)
    }

    @Test("tool kind snake_case")
    func toolKind() throws {
        #expect(try encodeJSON(CodeModeToolKind.function) == "\"function\"")
        #expect(try encodeJSON(CodeModeToolKind.freeform) == "\"freeform\"")
        #expect(try roundTrip(CodeModeToolKind.function) == .function)
    }

    @Test("defaults match Rust constants")
    func defaults() {
        #expect(DEFAULT_EXEC_YIELD_TIME_MS == 10_000)
        #expect(DEFAULT_WAIT_YIELD_TIME_MS == 10_000)
        #expect(DEFAULT_MAX_OUTPUT_TOKENS_PER_EXEC_CALL == 10_000)
        #expect(CODE_MODE_PRAGMA_PREFIX == "// @exec:")
    }
}

// MARK: - StartedCell one-shot

@Suite("StartedCell oneshot semantics")
struct StartedCellTests {
    @Test("preserves remote initial response errors")
    func preservesErrors() async {
        let started = StartedCell.fromResultContinuation(cellId: CellId("1")) {
            .failure(CodeModeError("remote runtime failed"))
        }
        let result = await started.initialResponse()
        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(let err):
            #expect(err.message == "remote runtime failed")
        }
    }

    @Test("second await rejects as already consumed")
    func oneShot() async {
        let started = StartedCell.fromResponseContinuation(cellId: CellId("2")) {
            .yielded(cellId: CellId("2"), contentItems: [.inputText(text: "ok")])
        }
        let first = await started.initialResponse()
        #expect(first.isSuccess)
        let second = await started.initialResponse()
        switch second {
        case .success:
            Issue.record("second await must not succeed")
        case .failure(let err):
            #expect(err == .initialResponseAlreadyConsumed)
        }
    }

    @Test("dropped response maps to runtimeEnded")
    func runtimeEnded() async {
        let started = StartedCell.fromResponseContinuation(cellId: CellId("3")) {
            nil
        }
        let result = await started.initialResponse()
        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(let err):
            #expect(err == .runtimeEnded)
        }
    }

    @Test("concurrent double-await: only one succeeds")
    func concurrent() async {
        let started = StartedCell.fromResponseContinuation(cellId: CellId("4")) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return .result(cellId: CellId("4"), contentItems: [], errorText: nil)
        }
        async let a = started.initialResponse()
        async let b = started.initialResponse()
        let (ra, rb) = await (a, b)
        let successes = [ra, rb].filter(\.isSuccess).count
        let failures = [ra, rb].filter { if case .failure = $0 { return true }; return false }.count
        #expect(successes == 1)
        #expect(failures == 1)
    }
}


// MARK: - Cancellation token

/// Tiny Sendable counter for cancel-handler assertions.
private final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.withLock {
            value += 1
        }
    }
    var count: Int {
        lock.withLock { value }
    }
}

@Suite("CodeModeCancellationToken")
struct CodeModeCancellationTokenTests {
    @Test("cancel is idempotent and fires handlers exactly once")
    func cancelOnce() async {
        let token = CodeModeCancellationToken()
        #expect(!token.isCancelled)

        let handlerHits = HitCounter()
        token.onCancel {
            handlerHits.increment()
        }
        token.cancel()
        token.cancel()
        token.cancel()
        #expect(token.isCancelled)
        #expect(handlerHits.count == 1)

        // Already-cancelled tokens invoke newly registered handlers immediately.
        let lateHits = HitCounter()
        token.onCancel { lateHits.increment() }
        #expect(lateHits.count == 1)

        await token.waitUntilCancelled()
    }

    @Test("childToken cancels with parent; child cancel does not parent-cancel")
    func childTokens() {
        let parent = CodeModeCancellationToken()
        let child = parent.childToken()
        #expect(!child.isCancelled)
        child.cancel()
        #expect(child.isCancelled)
        #expect(!parent.isCancelled)

        let child2 = parent.childToken()
        parent.cancel()
        #expect(child2.isCancelled)

        // Child created after parent cancel is born cancelled.
        let child3 = parent.childToken()
        #expect(child3.isCancelled)
    }
}

// MARK: - Session harness: terminate / shutdown cancel nested work

/// Recording delegate used to prove the protocol surface passes a live
/// per-cell cancellation token into nested tool invocations and
/// notifications, and that terminate/shutdown cancel it exactly once.
private final class RecordingDelegate: CodeModeSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invokeTokens: [CodeModeCancellationToken] = []
    private(set) var notifyTokens: [CodeModeCancellationToken] = []
    private(set) var closedCells: [CellId] = []
    private(set) var invokeCancelHits = 0
    private(set) var notifyCancelHits = 0

    /// Block inside invokeTool until the cancellation token fires, then
    /// return a cancelled error. Mirrors a host tool that cooperates with
    /// the per-cell token rather than ambient Task cancellation alone.
    func invokeTool(
        _ invocation: CodeModeNestedToolCall,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<JSONValue, CodeModeError> {
        lock.withLock {
            invokeTokens.append(cancellationToken)
        }
        await cancellationToken.waitUntilCancelled()
        lock.withLock {
            invokeCancelHits += 1
        }
        return .failure(CodeModeError("cancelled"))
    }

    func notify(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        lock.withLock {
            notifyTokens.append(cancellationToken)
        }
        await cancellationToken.waitUntilCancelled()
        lock.withLock {
            notifyCancelHits += 1
        }
        return .failure(CodeModeError("cancelled"))
    }

    func cellClosed(_ cellId: CellId) {
        lock.withLock {
            closedCells.append(cellId)
        }
    }
}

/// Minimal in-process session that owns one cancellation token per cell,
/// propagates it into the delegate, and cancels it exactly once from
/// `terminate` / `shutdown` — the contract the production runtime must
/// honour when implementing `CodeModeSession`.
private final class HarnessSession: CodeModeSession, @unchecked Sendable {
    struct CellState {
        let token: CodeModeCancellationToken
        var terminal: RuntimeResponse?
        var closed = false
    }

    private let lock = NSLock()
    private let delegate: RecordingDelegate
    private var cells: [String: CellState] = [:]
    private var nextId = 1
    private var shutDown = false

    init(delegate: RecordingDelegate) {
        self.delegate = delegate
    }

    func execute(_ request: ExecuteRequest) async -> Result<StartedCell, CodeModeError> {
        let id = lock.withLock { () -> CellId? in
            guard !shutDown else {
                return nil
            }
            let id = CellId(String(nextId))
            nextId += 1
            cells[id.rawValue] = CellState(token: CodeModeCancellationToken())
            return id
        }
        guard let id else {
            return .failure(CodeModeError("session shut down"))
        }

        let started = StartedCell.fromResponseContinuation(cellId: id) {
            // First yield so the caller can attach nested work.
            .yielded(cellId: id, contentItems: [.inputText(text: "started:\(request.toolCallId)")])
        }
        return .success(started)
    }

    /// Issue a nested tool call for a live cell, propagating its token.
    func nestedInvoke(cellId: CellId, tool: String) async -> Result<JSONValue, CodeModeError> {
        guard let token = token(for: cellId) else {
            return .failure(CodeModeError("missing cell"))
        }
        let invocation = CodeModeNestedToolCall(
            cellId: cellId,
            runtimeToolCallId: "rt-\(tool)",
            toolName: .plain(tool),
            toolKind: .function,
            input: .object(["x": .string("1")])
        )
        return await delegate.invokeTool(invocation, cancellationToken: token)
    }

    /// Issue a notify callback for a live cell, propagating its token.
    func nestedNotify(cellId: CellId, text: String) async -> Result<Void, CodeModeError> {
        guard let token = token(for: cellId) else {
            return .failure(CodeModeError("missing cell"))
        }
        return await delegate.notify(
            callId: "call-\(cellId.rawValue)",
            cellId: cellId,
            text: text,
            cancellationToken: token
        )
    }

    func wait(_ request: WaitRequest) async -> Result<WaitOutcome, CodeModeError> {
        lock.withLock {
            guard let state = cells[request.cellId.rawValue] else {
                let missing = RuntimeResponse.result(
                    cellId: request.cellId,
                    contentItems: [],
                    errorText: "stale cell"
                )
                return .success(.missingCell(missing))
            }
            if let terminal = state.terminal {
                return .success(.liveCell(terminal))
            }
            return .success(.liveCell(.yielded(cellId: request.cellId, contentItems: [])))
        }
    }

    func terminate(_ cellId: CellId) async -> Result<WaitOutcome, CodeModeError> {
        let termination = lock.withLock { () -> (CodeModeCancellationToken, RuntimeResponse)? in
            guard var state = cells[cellId.rawValue] else {
                return nil
            }
            let terminal = RuntimeResponse.terminated(cellId: cellId, contentItems: [
                .inputText(text: "terminated")
            ])
            state.terminal = terminal
            cells[cellId.rawValue] = state
            return (state.token, terminal)
        }
        guard let (token, terminal) = termination else {
            let missing = RuntimeResponse.result(
                cellId: cellId,
                contentItems: [],
                errorText: "stale cell"
            )
            return .success(.missingCell(missing))
        }

        // Cancel exactly once via the token; further cancel() is a no-op.
        token.cancel()
        token.cancel()

        closeIfNeeded(cellId)
        return .success(.liveCell(terminal))
    }

    func shutdown() async -> Result<Void, CodeModeError> {
        let entries = lock.withLock {
            shutDown = true
            return cells
        }
        for (id, state) in entries {
            state.token.cancel()
            closeIfNeeded(CellId(id))
        }
        return .success(())
    }

    private func token(for cellId: CellId) -> CodeModeCancellationToken? {
        lock.withLock {
            cells[cellId.rawValue]?.token
        }
    }

    private func closeIfNeeded(_ cellId: CellId) {
        let shouldClose = lock.withLock {
            guard var state = cells[cellId.rawValue], !state.closed else {
                return false
            }
            state.closed = true
            cells[cellId.rawValue] = state
            return true
        }
        if shouldClose {
            delegate.cellClosed(cellId)
        }
    }
}

@Suite("Session cancel + disposal harness")
struct CodeModeSessionCancelTests {
    @Test("terminate cancels in-flight nested tool invocation exactly once")
    func terminateCancelsInvoke() async throws {
        let delegate = RecordingDelegate()
        let session = HarnessSession(delegate: delegate)

        let started = try unwrap(await session.execute(ExecuteRequest(
            toolCallId: "tc-term",
            source: "await tools.read_file({path:'x'})"
        )))
        let cellId = started.cellId
        let initial = await started.initialResponse()
        #expect(initial.isSuccess)

        async let nested = session.nestedInvoke(cellId: cellId, tool: "read_file")
        // Give the nested call a moment to park on the token.
        try await Task.sleep(nanoseconds: 20_000_000)

        let term = try unwrap(await session.terminate(cellId))
        #expect(term.response.cellId == cellId)
        if case .terminated = term.response {
            // ok
        } else {
            Issue.record("expected terminated response, got \(term.response)")
        }

        let nestedResult = await nested
        switch nestedResult {
        case .failure(let err):
            #expect(err.message == "cancelled")
        case .success:
            Issue.record("nested invoke should observe cancel")
        }
        #expect(delegate.invokeCancelHits == 1)
        #expect(delegate.invokeTokens.count == 1)
        #expect(delegate.invokeTokens[0].isCancelled)
        #expect(delegate.closedCells == [cellId])

        // Second terminate against the same cell is still live (terminal
        // cached) but cancel remains a no-op (hits stay 1).
        _ = await session.terminate(cellId)
        #expect(delegate.invokeCancelHits == 1)
        #expect(delegate.closedCells.count == 1)
    }

    @Test("shutdown cancels in-flight notify and disposes the session")
    func shutdownCancelsNotify() async throws {
        let delegate = RecordingDelegate()
        let session = HarnessSession(delegate: delegate)

        let started = try unwrap(await session.execute(ExecuteRequest(
            toolCallId: "tc-shut",
            source: "notify('partial')"
        )))
        let cellId = started.cellId
        _ = await started.initialResponse()

        async let nested = session.nestedNotify(cellId: cellId, text: "partial")
        try await Task.sleep(nanoseconds: 20_000_000)

        let shut = await session.shutdown()
        #expect(shut.isSuccess)

        let nestedResult = await nested
        switch nestedResult {
        case .failure(let err):
            #expect(err.message == "cancelled")
        case .success:
            Issue.record("notify should observe cancel on shutdown")
        }
        #expect(delegate.notifyCancelHits == 1)
        #expect(delegate.notifyTokens.count == 1)
        #expect(delegate.notifyTokens[0].isCancelled)
        #expect(delegate.closedCells == [cellId])

        // Session is unusable after shutdown.
        let post = await session.execute(ExecuteRequest(toolCallId: "x", source: "1"))
        switch post {
        case .failure(let err):
            #expect(err.message.contains("shut down"))
        case .success:
            Issue.record("execute after shutdown must fail")
        }
    }

    @Test("wait on unknown cell returns MissingCell stale outcome")
    func staleMissingCell() async throws {
        let session = HarnessSession(delegate: RecordingDelegate())
        let outcome = try unwrap(await session.wait(WaitRequest(cellId: CellId("nope"), yieldTimeMs: 1)))
        if case .missingCell(let response) = outcome {
            #expect(response.cellId == CellId("nope"))
            if case .result(_, _, let errorText) = response {
                #expect(errorText == "stale cell")
            } else {
                Issue.record("expected result wrapper on stale cell")
            }
        } else {
            Issue.record("expected MissingCell")
        }

        // Wire golden for the missing-cell shape.
        let golden = WaitOutcome.missingCell(
            .result(cellId: CellId("nope"), contentItems: [], errorText: "stale cell")
        )
        let json = try encodeJSON(golden)
        #expect(json.hasPrefix(#"{"MissingCell":"#))
        #expect(json.contains("\"error_text\":\"stale cell\""))
        #expect(try roundTrip(golden) == golden)
    }
}

// MARK: - Malformed / unknown-field wire compatibility

@Suite("Code Mode malformed + unknown-field wire")
struct CodeModeWireCompatibilityTests {
    @Test("RuntimeResponse rejects multi-key and empty external tags")
    func malformedExternalTags() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(RuntimeResponse.self, #"{"Yielded":{"cell_id":"1","content_items":[]},"Result":{}}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(RuntimeResponse.self, #"{}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(RuntimeResponse.self, #"{"NotAVariant":{"cell_id":"1","content_items":[]}}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(WaitOutcome.self, #"{"LiveCell":{},"MissingCell":{}}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(ExecuteToPendingOutcome.self, #"{"Pending":{"cell_id":"1"}}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(RuntimeResponse.self, #"{"Yielded":"not-an-object"}"#)
        }
    }

    @Test("unknown non-semantic fields are ignored (serde default)")
    func unknownFieldsIgnored() throws {
        // Extra fields inside a known variant payload must not break decode.
        let yielded = try decodeJSON(
            RuntimeResponse.self,
            #"{"Yielded":{"cell_id":"c1","content_items":[],"future_flag":true,"extra":{"n":1}}}"#
        )
        #expect(yielded == .yielded(cellId: CellId("c1"), contentItems: []))

        let result = try decodeJSON(
            RuntimeResponse.self,
            #"{"Result":{"cell_id":"c2","content_items":[{"type":"input_text","text":"ok","_meta":1}],"error_text":null,"trace":"x"}}"#
        )
        #expect(result == .result(
            cellId: CellId("c2"),
            contentItems: [.inputText(text: "ok")],
            errorText: nil
        ))

        let wait = try decodeJSON(
            WaitRequest.self,
            #"{"cell_id":"w","yield_time_ms":5,"client_hint":"ignore-me"}"#
        )
        #expect(wait == WaitRequest(cellId: CellId("w"), yieldTimeMs: 5))

        let nested = try decodeJSON(
            CodeModeNestedToolCall.self,
            #"{"cell_id":"c","runtime_tool_call_id":"r","tool_name":{"name":"echo","namespace":null},"tool_kind":"function","input":null,"host_meta":{}}"#
        )
        #expect(nested.cellId == CellId("c"))
        #expect(nested.input == nil)
    }

    @Test("image + generated-image content items round-trip")
    func imageContent() throws {
        // generatedImage(...) in the JS isolate surfaces as input_image content.
        let generated = FunctionCallOutputContentItem.inputImage(
            imageUrl: "data:image/png;base64,iVBORw0KGgo=",
            detail: .original
        )
        #expect(try roundTrip(generated) == generated)
        let json = try encodeJSON(generated)
        #expect(json.contains(#""type":"input_image""#))
        #expect(json.contains("\"original\""))

        let response = RuntimeResponse.result(
            cellId: CellId("img"),
            contentItems: [
                .inputText(text: "caption"),
                generated,
            ],
            errorText: nil
        )
        #expect(try roundTrip(response) == response)
        let rJSON = try encodeJSON(response)
        #expect(rJSON.contains("\"input_image\""))
        #expect(rJSON.contains("\"input_text\""))
    }

    @Test("pending + terminated goldens from Rust external tags")
    func pendingTerminatedGoldens() throws {
        let pendingJSON = #"{"Pending":{"cell_id":"p1","content_items":[{"type":"input_text","text":"partial"}],"pending_tool_call_ids":["t-a","t-b"]}}"#
        let pending = try decodeJSON(ExecuteToPendingOutcome.self, pendingJSON)
        #expect(try roundTrip(pending) == pending)
        if case .pending(let id, let items, let tools) = pending {
            #expect(id == CellId("p1"))
            #expect(items.count == 1)
            #expect(tools == ["t-a", "t-b"])
        } else {
            Issue.record("expected Pending")
        }

        let terminatedJSON = #"{"Terminated":{"cell_id":"t1","content_items":[]}}"#
        let terminated = try decodeJSON(RuntimeResponse.self, terminatedJSON)
        #expect(terminated == .terminated(cellId: CellId("t1"), contentItems: []))
        #expect(try encodeJSON(terminated) == terminatedJSON)
    }
}

/// Unwrap a protocol `Result` or record a failure.
private func unwrap<T>(_ result: Result<T, CodeModeError>) throws -> T {
    switch result {
    case .success(let value):
        return value
    case .failure(let err):
        Issue.record("unexpected failure: \(err.message)")
        throw err
    }
}


private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
