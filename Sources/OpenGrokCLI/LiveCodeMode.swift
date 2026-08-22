// LiveCodeMode.swift
//
// Code Mode in a live session: tool-mode selection, the tool-surface
// projection each mode advertises, and the executor seam that runs a cell's
// nested `tools.*` calls back through the ordinary live dispatch pipeline.
//
// Rust reference:
//   * `session/tool_surface.rs` (`EffectiveToolSurface::build`) — which tools
//     stay top-level per mode, and where `exec` / `wait` are added.
//   * `session/code_mode.rs` (`is_code_mode_direct_only_tool`,
//     `create_exec_function_tool`, `create_wait_tool`,
//     `collect_code_mode_tool_definitions`) — the direct-only list, the
//     function-envelope tool shapes, and the nested namespace.
//   * `acp_session_impl/tool_calls.rs` (`dispatch_code_mode_nested_tool`) —
//     a nested call re-enters the same prepare / permission / dispatch path a
//     direct call takes, under a synthetic `exec-<uuid>` call id.
//   * `acp_session_impl/turn.rs:1998` — `exec` and `wait` never produce tool
//     cards; the cards come from the nested calls the cell made.
//
// Divergences from Rust are recorded in INTEGRATION-codemode-live.md.

import Foundation
import OpenGrokCodeMode
import OpenGrokCodeModeProtocol
import OpenGrokConfig
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase

// MARK: - Direct-only tools

/// Tools that stay top-level in every mode, quoted from
/// `is_code_mode_direct_only_tool` (session/code_mode.rs:68).
///
/// They park the turn on a user interaction or hold it until an aggregation
/// finishes, neither of which a cell's yield timer can survive: the timer
/// would hand control back to the model while the approval prompt is still
/// open. In `code_mode_only` these are the only ordinary tools the model can
/// still call directly.
let LIVE_CODE_MODE_DIRECT_ONLY_TOOLS: Set<String> = [
    "ask_user_question",
    "request_user_input",
    "enter_plan_mode",
    "exit_plan_mode",
    "task",
    "spawn_subagent",
    "agent_swarm",
    "workflow",
    "get_task_output",
    "get_command_or_subagent_output",
    "wait_tasks",
    "wait_commands_or_subagents",
    "kill_task",
    "kill_command_or_subagent",
    "list_agents",
    "send_message",
    "followup_task",
    "wait_agent",
    "list_sessions",
    "read_session",
    "message_session",
]

func isLiveCodeModeDirectOnlyTool(_ name: String) -> Bool {
    LIVE_CODE_MODE_DIRECT_ONLY_TOOLS.contains(name)
}

/// Yield windows the shell sends. `exec` gets 30 s and `wait` 10 s
/// (DEFAULT_EXEC_YIELD_TIME_MS / DEFAULT_WAIT_YIELD_TIME_MS,
/// xai-grok-code-mode-protocol/src/runtime.rs:11-12).
let LIVE_CODE_MODE_EXEC_YIELD_TIME_MS: UInt64 = DEFAULT_EXEC_YIELD_TIME_MS
let LIVE_CODE_MODE_WAIT_YIELD_TIME_MS: UInt64 = DEFAULT_WAIT_YIELD_TIME_MS

// MARK: - Tool mode resolution

enum LiveCodeModeSettings {
    /// Resolve the session's tool mode.
    ///
    /// Precedence, highest first:
    ///   1. `OPENGROK_TOOL_MODE` (canonical string or the legacy boolean),
    ///   2. the project config chain's `[ui] code_mode`,
    ///   3. `$OPENGROK_HOME/config.toml`'s `[ui] code_mode`,
    ///   4. `.direct`.
    ///
    /// `[ui] code_mode` is the only config path upstream defines
    /// (settings/defs.rs:129 `CODE_MODE_CHOICES`, documented at
    /// docs/user-guide/05-configuration.md:100). There is no
    /// `[features] code_mode` anywhere upstream, so none is read here.
    static func resolveToolMode(
        environment: [String: String],
        workingDirectory: URL,
        openGrokHome: URL,
        runtimeCapability: CodeModeRuntimeCapability = .current
    ) -> ToolModePreference {
        let requestedMode: ToolModePreference
        if let raw = environment["OPENGROK_TOOL_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let mode = parse(raw) {
            requestedMode = mode
        } else {
            let project = loadMergedProjectConfig(
                cwd: workingDirectory,
                environment: environment
            )
            if let mode = toolMode(in: project) {
                requestedMode = mode
            } else {
                let userConfig = try? loadConfigFile(
                    at: openGrokHome.appendingPathComponent("config.toml")
                )
                requestedMode = userConfig.flatMap { toolMode(in: $0) } ?? .direct
            }
        }

        guard runtimeCapability.isAvailable || requestedMode == .direct else {
            return .direct
        }
        return requestedMode
    }

    /// Accepts the canonical strings and the legacy boolean form that the
    /// original setting used (`ui_config.rs:44` — `false` → direct,
    /// `true` → mixed code mode).
    static func parse(_ raw: String) -> ToolModePreference? {
        let lowered = raw.lowercased()
        switch lowered {
        case "false", "0", "off", "no": return .direct
        case "true", "1", "on", "yes": return .codeMode
        default: return ToolModePreference.fromCanonical(lowered)
        }
    }

    private static func toolMode(in table: TOMLValue) -> ToolModePreference? {
        guard let value = table[path: ["ui", "code_mode"]] else { return nil }
        switch value {
        case .string(let raw): return parse(raw)
        case .boolean(let flag): return flag ? .codeMode : .direct
        default: return nil
        }
    }
}

// MARK: - Tool surface projection

/// The tool list one mode advertises, plus the registry snapshot a code-mode
/// session is built from. Mirrors `EffectiveToolSurface::build`
/// (session/tool_surface.rs:189).
struct LiveCodeModeToolSurface: Sendable {
    let mode: ToolModePreference
    /// What the model is offered this session.
    let modelTools: [ToolSpec]
    /// The `tools.*` namespace a cell sees. Empty in `.direct`.
    let snapshot: CodeModeToolRegistrySnapshot

    var isCodeMode: Bool { mode != .direct }

    init(mode: ToolModePreference, baseTools: [ToolSpec]) {
        self.mode = mode
        guard mode != .direct else {
            self.modelTools = baseTools
            self.snapshot = CodeModeToolRegistrySnapshot(tools: [])
            return
        }

        // `exec` / `wait` are reserved: an ordinary tool that claims either
        // name loses it (tool_surface.rs:228).
        let ordinary = baseTools.filter { isCodeModeNestedTool($0.name) }
        let nested = ordinary
            .filter { !isLiveCodeModeDirectOnlyTool($0.name) }
            .map(Self.definition)
        let direct = mode == .codeModeOnly
            ? ordinary.filter { isLiveCodeModeDirectOnlyTool($0.name) }
            : ordinary

        self.snapshot = CodeModeToolRegistrySnapshot(tools: nested)
        self.modelTools = direct + [
            Self.execTool(nested: nested, codeModeOnly: mode == .codeModeOnly),
            Self.waitTool()
        ]
    }

    private static func definition(for tool: ToolSpec) -> ToolDefinition {
        ToolDefinition(
            name: tool.name,
            toolName: .plain(tool.name),
            description: tool.description ?? "",
            kind: .function,
            inputSchema: tool.parameters
        )
    }

    /// The function-envelope `exec` (`create_exec_function_tool`,
    /// code_mode.rs:923). The Codex native custom-grammar form is not built
    /// here: the live sampler advertises function tools only.
    private static func execTool(
        nested: [ToolDefinition],
        codeModeOnly: Bool
    ) -> ToolSpec {
        let native = buildExecToolDescription(
            enabledTools: nested.map(augmentToolDefinition),
            deferredTools: [],
            namespaceDescriptions: [:],
            codeModeOnly: codeModeOnly
        )
        return ToolSpec(
            name: PUBLIC_TOOL_NAME,
            description: "Pass the JavaScript source in the `source` field.\n\n\(native)",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "source": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Raw JavaScript source to run in the persistent Code Mode session."
                        )
                    ])
                ]),
                "required": .array([.string("source")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    /// `create_wait_tool` (code_mode.rs:956) — schema reproduced field for
    /// field, including the descriptions the model reads.
    private static func waitTool() -> ToolSpec {
        ToolSpec(
            name: WAIT_TOOL_NAME,
            description: "Waits on a yielded `exec` cell and returns new output or completion.\n"
                + buildWaitToolDescription(),
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "cell_id": .object([
                        "type": .string("string"),
                        "description": .string("Identifier of the running exec cell.")
                    ]),
                    "max_tokens": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Output token budget for this wait call. Defaults to 10000 tokens."
                        )
                    ]),
                    "terminate": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "True stops the running exec cell; false or omitted waits for output."
                        )
                    ]),
                    "yield_time_ms": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Wait before yielding more output. Defaults to 10000 ms."
                        )
                    ])
                ]),
                "required": .array([.string("cell_id")]),
                "additionalProperties": .bool(false)
            ])
        )
    }
}

// MARK: - Per-turn emitter

/// Holds the turn's update sink so nested calls dispatched from inside a cell
/// can raise the same tool lifecycle cards a direct call raises.
///
/// The box is deliberately separate from the coordinator: the code-mode
/// session retains the executor, so routing card emission through the
/// coordinator would close a retain cycle across the engine.
actor LiveCodeModeEmitter {
    typealias Sink = @Sendable (OpenGrokShellTurnUpdateKind) async -> Void

    private var sink: Sink?

    func attach(_ sink: @escaping Sink) { self.sink = sink }
    func detach() { sink = nil }

    func send(_ update: OpenGrokShellTurnUpdateKind) async {
        await sink?(update)
    }
}

/// Interim `notify(...)` text from running cells, keyed by cell.
///
/// Rust records each notification as an extra `custom_tool_call_output` for
/// the open `exec` call (tool_calls.rs:950). The live turn driver speaks the
/// function envelope, which has no second output slot, so the text is held
/// here and prepended to the cell's next observation instead — the ordering
/// the interaction-hold path preserves in Rust (code_mode.rs:1024).
actor LiveCodeModeNotifications {
    private var pending: [CellId: [String]] = [:]

    func append(_ text: String, for cellId: CellId) {
        pending[cellId, default: []].append(text)
    }

    func take(_ cellId: CellId) -> [String] {
        pending.removeValue(forKey: cellId) ?? []
    }

    func drop(_ cellId: CellId) {
        pending.removeValue(forKey: cellId)
    }
}

// MARK: - The executor seam

/// Runs one nested `tools.*` call by re-entering the live dispatch pipeline.
///
/// This is the whole point of the seam: the call goes through the same
/// `LiveToolExecutor.invoke` a direct call goes through, so the file tools'
/// permission gate sees a nested write exactly as it sees a direct one and
/// raises the same modal.
struct LiveCodeModeNestedExecutor: CodeModeToolExecutor {
    let toolExecutor: LiveToolExecutor
    let sessionID: String
    let workingDirectory: URL
    let emitter: LiveCodeModeEmitter
    let notifications: LiveCodeModeNotifications

    func executeNestedTool(
        _ invocation: CodeModeNestedToolCall,
        cancellationToken: CodeModeCancellationToken,
        progress: NestedToolProgressSink
    ) async -> Result<JSONValue, CodeModeError> {
        let name = invocation.toolName.name
        // Matches Rust's synthetic id for a cell-issued call
        // (tool_calls.rs:998), which is what keeps a nested card distinct
        // from the model's own call ids.
        let callID = "exec-\(UUID().uuidString)"
        let arguments = Self.argumentsJSON(invocation.input)

        await emitter.send(.tool(OpenGrokShellToolUpdate(
            callID: callID,
            name: name,
            input: arguments,
            state: .running
        )))

        let outcome = await Self.race(
            cancellationToken: cancellationToken,
            work: {
                await toolExecutor.invoke(
                    sessionID: sessionID,
                    workingDirectory: workingDirectory,
                    call: ToolCall(id: callID, name: name, arguments: arguments),
                    onOutput: { delta in
                        guard !cancellationToken.isCancelled, !progress.isClosed else { return }
                        progress.push(.text(delta.text))
                        await emitter.send(.tool(OpenGrokShellToolUpdate(
                            callID: delta.callID,
                            name: name,
                            input: arguments,
                            output: delta.text,
                            state: .running,
                            outputOp: delta.op == .replace ? .replace : .append
                        )))
                    }
                )
            }
        )

        switch outcome {
        case .cancelled:
            await emitter.send(.tool(OpenGrokShellToolUpdate(
                callID: callID,
                name: name,
                input: arguments,
                output: "Cancelled",
                state: .cancelled
            )))
            return .failure(CodeModeError("code mode nested tool call cancelled"))
        case .finished(.success(let result)):
            await emitter.send(.tool(OpenGrokShellToolUpdate(
                callID: callID,
                name: name,
                input: arguments,
                output: result.promptText,
                state: .succeeded
            )))
            return .success(result.value)
        case .finished(.failure(let error)):
            let message = "Tool \(name) failed: \(error.description)"
            await emitter.send(.tool(OpenGrokShellToolUpdate(
                callID: callID,
                name: name,
                input: arguments,
                output: message,
                state: .failed
            )))
            return .failure(CodeModeError(message))
        }
    }

    func deliverNotification(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        guard !cancellationToken.isCancelled else {
            return .failure(CodeModeError("code mode notification cancelled"))
        }
        await notifications.append(text, for: cellId)
        return .success(())
    }

    private static func argumentsJSON(_ input: JSONValue?) -> String {
        guard let input else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private enum RaceOutcome {
        case cancelled
        case finished(Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>)
    }

    /// Return on whichever lands first: the tool, or the cell's cancellation.
    ///
    /// The engine drains outstanding callbacks before it publishes a terminal
    /// event, so a callback that ignores the token stalls `terminate`
    /// (INTEGRATION-codemode.md §1). Losing work is cancelled and abandoned
    /// rather than awaited, which is what makes the return prompt.
    private static func race(
        cancellationToken: CodeModeCancellationToken,
        work: @escaping @Sendable () async
            -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>
    ) async -> RaceOutcome {
        let task = Task(operation: work)
        let resolved = OneShotBox<RaceOutcome>()
        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<RaceOutcome, Never>) in
            resolved.arm(continuation)
            cancellationToken.onCancel { resolved.resume(.cancelled) }
            Task { resolved.resume(.finished(await task.value)) }
        }
        if case .cancelled = outcome { task.cancel() }
        return outcome
    }
}

/// Resumes a continuation exactly once, whichever racer gets there first.
private final class OneShotBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?
    private var done = false

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let pending, !done {
            done = true
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        guard let continuation else {
            pending = value
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// A persistent JavaScript VM must not capture the first turn's MCP roster.
/// The request advertises a per-turn snapshot, while every callback checks
/// the current live surface again so a removed server fails closed immediately.
private struct LiveDynamicCodeModeDelegate: CodeModeSessionDelegate {
    let executor: LiveCodeModeNestedExecutor
    let toolExecutor: LiveToolExecutor
    let mode: ToolModePreference

    func invokeTool(
        _ invocation: CodeModeNestedToolCall,
        cancellationToken: CodeModeCancellationToken,
        progress: NestedToolProgressSink
    ) async -> Result<JSONValue, CodeModeError> {
        let snapshot = LiveCodeModeToolSurface(
            mode: mode,
            baseTools: toolExecutor.currentToolSpecs()
        ).snapshot
        guard snapshot.definition(for: invocation.toolName) != nil else {
            return .failure(
                CodeModeError("unknown code mode tool `\(invocation.toolName)`")
            )
        }
        return await executor.executeNestedTool(
            invocation,
            cancellationToken: cancellationToken,
            progress: progress
        )
    }

    func notify(
        callId: String,
        cellId: CellId,
        text: String,
        cancellationToken: CodeModeCancellationToken
    ) async -> Result<Void, CodeModeError> {
        await executor.deliverNotification(
            callId: callId,
            cellId: cellId,
            text: text,
            cancellationToken: cancellationToken
        )
    }

    func cellClosed(_ cellId: CellId) {
        executor.cellDidClose(cellId)
    }
}

// MARK: - The coordinator

/// Owns one code-mode session for the life of an agent timeline: it answers
/// the model's `exec` / `wait` calls, tracks which cells are still live, and
/// implements the lifecycle rules — reset on an incompatible model switch,
/// terminate on turn cancel, dispose on session end.
actor LiveCodeModeCoordinator {
    let surface: LiveCodeModeToolSurface

    private let sessionID: String
    private let workingDirectory: URL
    private let executor: LiveCodeModeNestedExecutor
    private let toolExecutor: LiveToolExecutor
    private let emitter: LiveCodeModeEmitter
    private let notifications: LiveCodeModeNotifications
    /// `nil` keeps the engine's default per-entry ceiling.
    private let executionCeilingMs: UInt64?

    private var session: InProcessCodeModeSession?
    private var activeSnapshot: CodeModeToolRegistrySnapshot
    private var liveCells: Set<CellId> = []
    private var isShutDown = false

    init(
        surface: LiveCodeModeToolSurface,
        toolExecutor: LiveToolExecutor,
        sessionID: String,
        workingDirectory: URL,
        executionCeilingMs: UInt64? = nil
    ) {
        let emitter = LiveCodeModeEmitter()
        let notifications = LiveCodeModeNotifications()
        self.surface = surface
        self.activeSnapshot = surface.snapshot
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.toolExecutor = toolExecutor
        self.emitter = emitter
        self.notifications = notifications
        self.executionCeilingMs = executionCeilingMs
        self.executor = LiveCodeModeNestedExecutor(
            toolExecutor: toolExecutor,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            emitter: emitter,
            notifications: notifications
        )
    }

    /// `true` when the call is cell plumbing rather than a user-visible tool.
    nonisolated func isTransportCall(_ call: ToolCall) -> Bool {
        surface.isCodeMode
            && CodeModeTransportProjection.isTransportTool(.plain(call.name))
    }

    // MARK: Turn lifecycle

    func beginTurn(emit: @escaping LiveCodeModeEmitter.Sink) async {
        activeSnapshot = LiveCodeModeToolSurface(
            mode: surface.mode,
            baseTools: toolExecutor.currentToolSpecs()
        ).snapshot
        await emitter.attach(emit)
    }

    func endTurn() async {
        await emitter.detach()
    }

    /// Esc during a turn. Rust parks a cell's callbacks when the turn ends and
    /// only kills the cell on a runtime reset (code_mode.rs:773); Open Grok's
    /// live turn owns its cells outright, so a cancelled turn terminates every
    /// live cell instead of leaving one running with nothing to observe it.
    func cancelActiveCells() async {
        guard let session else { return }
        let cells = liveCells
        liveCells.removeAll()
        for cellId in cells {
            _ = await session.terminate(cellId)
            await notifications.drop(cellId)
        }
    }

    /// Replace the runtime, discarding every cell.
    ///
    /// `wait` on a cell id from before the reset then resolves as
    /// `MissingCell` — the stale-cell fail-closed rule.
    func reset() async {
        let previous = session
        session = nil
        liveCells.removeAll()
        if let previous { _ = await previous.shutdown() }
    }

    /// Model switch. Mirrors `code_mode_runtime_reset_required`
    /// (model_switch.rs:16): the provider changing resets the runtime, while
    /// staying on one provider keeps stored values and live cells. Compaction
    /// deliberately does not reset — Rust has no such edge, and a cell that
    /// outlives a compaction still resolves.
    func noteModelSwitch(from previous: ModelProvider, to next: ModelProvider) async {
        guard previous != next else { return }
        await reset()
    }

    /// Session end.
    func shutdown() async {
        isShutDown = true
        await reset()
        await emitter.detach()
    }

    // MARK: Transport calls

    /// Answer one `exec` or `wait` call.
    ///
    /// Nothing here emits a tool card: `exec` and `wait` are transport, and
    /// the cards come from the nested calls the cell made
    /// (CodeModeTransportProjection.producesUserVisibleCard).
    func handleTransportCall(_ call: ToolCall) async -> ToolResultItem {
        let text: String
        if call.name == PUBLIC_TOOL_NAME {
            text = await handleExec(call)
        } else {
            text = await handleWait(call)
        }
        return ToolResultItem(toolCallId: call.callId, content: text)
    }

    private func handleExec(_ call: ToolCall) async -> String {
        guard !isShutDown else { return "Code Mode is unavailable: the session has ended." }
        guard let source = Self.execSource(call.arguments) else {
            return "exec expects a `source` field carrying raw JavaScript."
        }
        let parsed: ParsedExecSource
        switch parseExecSource(source) {
        case .failure(let error): return error.message
        case .success(let value): parsed = value
        }

        let request = ExecuteRequest(
            toolCallId: call.callId,
            enabledTools: activeSnapshot.executeRequestTools,
            source: parsed.code,
            yieldTimeMs: parsed.yieldTimeMs ?? LIVE_CODE_MODE_EXEC_YIELD_TIME_MS,
            maxOutputTokens: parsed.maxOutputTokens
        )
        switch await currentSession().execute(request) {
        case .failure(let error):
            return "exec failed: \(error.message)"
        case .success(let started):
            liveCells.insert(started.cellId)
            switch await started.initialResponse() {
            case .failure(let error):
                liveCells.remove(started.cellId)
                return "exec failed: \(error.message)"
            case .success(let response):
                return await render(response)
            }
        }
    }

    private func handleWait(_ call: ToolCall) async -> String {
        guard !isShutDown else { return "Code Mode is unavailable: the session has ended." }
        guard let arguments = Self.object(call.arguments),
              case .string(let rawCellId)? = arguments["cell_id"] else {
            return "wait requires a `cell_id` naming a running exec cell."
        }
        guard let session else {
            return "exec cell \(rawCellId) not found"
        }
        let cellId = CellId(rawCellId)
        let terminate: Bool
        if case .bool(let flag)? = arguments["terminate"] { terminate = flag } else { terminate = false }

        let outcome: Result<WaitOutcome, CodeModeError>
        if terminate {
            outcome = await session.terminate(cellId)
        } else {
            let yieldTimeMs = Self.milliseconds(arguments["yield_time_ms"])
                ?? LIVE_CODE_MODE_WAIT_YIELD_TIME_MS
            outcome = await session.wait(
                WaitRequest(cellId: cellId, yieldTimeMs: yieldTimeMs)
            )
        }
        switch outcome {
        case .failure(let error):
            return "wait failed: \(error.message)"
        case .success(let waitOutcome):
            return await render(waitOutcome.response)
        }
    }

    private func currentSession() -> InProcessCodeModeSession {
        if let session { return session }
        let delegate = LiveDynamicCodeModeDelegate(
            executor: executor,
            toolExecutor: toolExecutor,
            mode: surface.mode
        )
        let created: InProcessCodeModeSession
        if let executionCeilingMs {
            created = InProcessCodeModeSession(
                delegate: delegate,
                executionCeilingMs: executionCeilingMs
            )
        } else {
            created = InProcessCodeModeSession(delegate: delegate)
        }
        session = created
        return created
    }

    // MARK: Projection

    /// The model-visible text for one observation.
    ///
    /// Only `RuntimeResponse.contentItems` crosses the boundary; the cell id
    /// is quoted for `wait` because the model has to name it, and nothing else
    /// the transport tracks — pending nested call ids, stored values — appears.
    private func render(_ response: RuntimeResponse) async -> String {
        let cellId = response.cellId
        var lines = await notifications.take(cellId)
        lines.append(contentsOf: CodeModeTransportProjection
            .modelVisibleContent(response)
            .map(Self.itemText))

        switch response {
        case .yielded:
            lines.append("Script running with cell ID \(cellId)")
        case .terminated:
            liveCells.remove(cellId)
            await notifications.drop(cellId)
            lines.append("Cell \(cellId) was terminated.")
        case .result(_, _, let errorText):
            liveCells.remove(cellId)
            await notifications.drop(cellId)
            if let errorText, !errorText.isEmpty {
                lines.append("Error: \(errorText)")
            }
        }
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? "(no output)" : text
    }

    private static func itemText(_ item: FunctionCallOutputContentItem) -> String {
        switch item {
        case .inputText(let text): return text
        case .inputImage: return "[image]"
        }
    }

    // MARK: Argument decoding

    /// The JavaScript body of an `exec` call.
    ///
    /// The function envelope carries it in `source`; Codex's native custom
    /// tool sends the raw body as the whole argument string, so a payload that
    /// is not an object with a `source` field is taken verbatim.
    private static func execSource(_ arguments: String) -> String? {
        if let object = object(arguments) {
            if case .string(let source)? = object["source"] { return source }
            return nil
        }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : arguments
    }

    /// `OpenGrokShared` and `OpenGrokCodeModeProtocol` both extend `JSONValue`
    /// with `uint64Value`, so the accessor is read here instead.
    private static func milliseconds(_ value: JSONValue?) -> UInt64? {
        guard case .number(let number)? = value else { return nil }
        if let unsigned = number.uint64Value { return unsigned }
        guard let signed = number.int64Value, signed >= 0 else { return nil }
        return UInt64(signed)
    }

    private static func object(_ arguments: String) -> [String: JSONValue]? {
        guard let data = arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else {
            return nil
        }
        return object
    }
}
