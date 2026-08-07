// LiveBackgroundTaskTools.swift
//
// The consumer half of background execution: `get_task_output`, `wait_tasks`
// and `kill_task`.
//
// `run_terminal_cmd` can put a command in the background two ways — the model
// asks for it with `is_background: true`, or the command outruns the 10s
// foreground budget and `autoBackgroundOnTimeout` moves it there without being
// asked. Either way the model is handed a `task_id` and, until these three
// tools existed, no way to ever read it, wait on it, or stop it. Upstream ships
// all three in every preset that has bash for exactly that reason
// (`xai-grok-tools/src/registry/types.rs:694-701`).
//
// These live in OpenGrokCLI rather than OpenGrokExecutionTools because they
// need `OpenGrokShellProcessExecution`, which is wave 8; the tools target is
// wave 5 and the manifest forbids the back-edge.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase

enum LiveBackgroundTaskTools {
    // MARK: - Names

    static let getTaskOutputName = "get_task_output"
    static let waitTasksName = "wait_tasks"
    static let killTaskName = "kill_task"

    static let toolNames: Set<String> = [
        getTaskOutputName, waitTasksName, killTaskName,
    ]

    /// The names upstream's grok-build preset renames these to
    /// (`xai-grok-agent/src/config.rs:163-173`). Swift advertises the canonical
    /// registry names, matching how it advertises `run_terminal_cmd` rather
    /// than the renamed `run_terminal_command`, but a model primed on the
    /// renamed contract — or an agent profile written against it, as every
    /// profile in `AgentDefinitionSchema` is — must still resolve.
    static let aliases: [String: String] = [
        "get_command_or_subagent_output": getTaskOutputName,
        "wait_commands_or_subagents": waitTasksName,
        "kill_command_or_subagent": killTaskName,
    ]

    /// Canonical name for `name`, or nil when it is not one of these tools.
    static func canonicalName(for name: String) -> String? {
        if toolNames.contains(name) { return name }
        return aliases[name]
    }

    // MARK: - Wait budget

    /// Ceiling on a single blocking wait. Capping is safe: a wait that runs out
    /// costs the model one more poll, not the result.
    static let defaultMaxWaitBlockMilliseconds = 600_000

    /// Default wait when a caller is in wait mode but omitted `timeout_ms`.
    static let defaultWaitTimeoutMilliseconds = 30_000

    static func maxWaitBlockMilliseconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment["OPENGROK_MAX_WAIT_BLOCK_MS"],
              let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0
        else { return defaultMaxWaitBlockMilliseconds }
        return parsed
    }

    /// Render a wait ceiling the way upstream's `format_wait_cap_ms` does.
    /// Both branches round *down*: a cap must never read as longer than it is.
    static func formatWaitCap(_ milliseconds: Int) -> String {
        if milliseconds < 60_000 {
            return "\(milliseconds) (~\(milliseconds / 1_000) s)"
        }
        return "\(milliseconds) (~\(milliseconds / 60_000) min)"
    }

    // MARK: - Tool specs

    static func toolSpecs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        subagentsPresent: Bool = false
    ) -> [ToolSpec] {
        let cap = formatWaitCap(maxWaitBlockMilliseconds(environment: environment))
        return [
            getTaskOutputSpec(waitCap: cap, subagentsPresent: subagentsPresent),
            waitTasksSpec(waitCap: cap, subagentsPresent: subagentsPresent),
            killTaskSpec(subagentsPresent: subagentsPresent),
        ]
    }

    /// Wording mirrors `xai_tool_types::build_task_output_description` for the
    /// shape this session actually finalizes: bash present, no monitor tool,
    /// and the subagent suffix only when the session advertises
    /// `spawn_subagent` — the description must never name a surface the model
    /// cannot reach.
    static func getTaskOutputSpec(waitCap: String, subagentsPresent: Bool = false) -> ToolSpec {
        let target = subagentsPresent ? "background task or subagent" : "background task"
        let sources = subagentsPresent
            ? "is_background=true commands or background=true subagents"
            : "is_background=true commands"
        return ToolSpec(
            name: getTaskOutputName,
            description: """
            Get output and status from a \(target).

            Usage notes:
            - Pass task_ids with one or more ids from \(sources); for a single task use a one-element array. Multiple ids with a positive timeout_ms wait until all complete
            - Omit timeout_ms or pass 0 for a non-blocking status snapshot; set a positive timeout_ms to wait up to that many milliseconds, capped at \(waitCap)
            - Returns current output, status, and exit code if completed
            - If output is large, use read_file on the output_file path
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "task_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Task IDs to get output from. Pass one or more; for a single task use a one-element array. With a positive timeout_ms, multiple ids wait until all complete. Omit timeout_ms or pass 0 for a non-blocking snapshot."),
                    ]),
                    "timeout_ms": .object([
                        "type": .string("integer"),
                        "minimum": .number(.int64(0)),
                        "description": .string("Max wait time in milliseconds, up to \(waitCap). A positive value waits for completion; omit or pass 0 for a non-blocking status poll."),
                    ]),
                ]),
                "required": .array([.string("task_ids")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// Mirrors `xai_tool_types::build_wait_tasks_description`. Upstream keeps
    /// this tool only as a compatibility alias for prompts that still emit it —
    /// `get_task_output` with a positive `timeout_ms` is the preferred path —
    /// but `wait_any` exists only here, so it is not purely redundant.
    static func waitTasksSpec(waitCap: String, subagentsPresent: Bool = false) -> ToolSpec {
        let sources = subagentsPresent
            ? "is_background=true or background=true"
            : "is_background=true commands"
        return ToolSpec(
            name: waitTasksName,
            description: """
            Wait for multiple background tasks or subagents to complete.

            Prefer get_task_output with task_ids and a positive timeout_ms. This tool is kept for compatibility.

            Usage notes:
            - task_ids: list of task IDs from \(sources)
            - mode: 'wait_all' or 'wait_any'
            - timeout_ms: optional max wait, default 30s, capped at \(waitCap)
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "task_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Task IDs to wait for"),
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("wait_any"), .string("wait_all")]),
                        "description": .string("Wait mode: 'wait_any' (return when first completes) or 'wait_all' (wait for all)"),
                    ]),
                    "timeout_ms": .object([
                        "type": .string("integer"),
                        "minimum": .number(.int64(0)),
                        "description": .string("Max wait time in milliseconds, up to \(waitCap)"),
                    ]),
                ]),
                "required": .array([.string("task_ids"), .string("mode")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// Mirrors `xai_tool_types::build_kill_task_description` with
    /// `bash_present: true` and no monitor tool; the subagent clause appears
    /// exactly when the session can spawn one.
    static func killTaskSpec(subagentsPresent: Bool = false) -> ToolSpec {
        let target = subagentsPresent ? "background task or subagent" : "background task"
        let action = subagentsPresent
            ? "Sends SIGTERM/SIGKILL to a bash task; sends Cancel+Shutdown to a subagent."
            : "Sends SIGTERM/SIGKILL to a bash task."
        return ToolSpec(
            name: killTaskName,
            description: """
            Terminate a running \(target).

            Usage notes:
            - Pass its task_id.
            - \(action)
            - Returns success if the task was killed or had already exited.
            """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                    "description": .string("The task ID to terminate"),
                ]),
            ]),
            "required": .array([.string("task_id")]),
            "additionalProperties": .bool(false),
            ])
        )
    }

    // MARK: - Dispatch

    /// `subagents` is the session's subagent host when `spawn_subagent` is
    /// live. Task ids share one namespace (upstream unifies them in
    /// `task_output/mod.rs` / `kill_task/mod.rs`): an id the shell does not
    /// own falls through to the coordinator.
    static func invoke(
        name: String,
        args: JSONValue,
        process: any OpenGrokShellProcessExecution,
        subagents: (any LiveSubagentQuerying)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        guard let canonical = canonicalName(for: name) else {
            return .failure(.unsupported("unknown tool '\(name)'"))
        }
        guard case .object(let object) = args else {
            return .failure(.invalidCall("\(canonical) requires an object argument"))
        }
        switch canonical {
        case getTaskOutputName:
            return await getTaskOutput(object, process: process, subagents: subagents, environment: environment)
        case waitTasksName:
            return await waitTasks(object, process: process, subagents: subagents, environment: environment)
        case killTaskName:
            return await killTask(object, process: process, subagents: subagents)
        default:
            return .failure(.unsupported("unknown tool '\(name)'"))
        }
    }

    // MARK: get_task_output

    /// One resolved id: a shell task or a subagent, never both (the shell
    /// wins a collision, matching upstream's terminal-first order).
    private enum ResolvedTask {
        case shell(ShellTaskSnapshot)
        case subagent(LiveSubagentSnapshot)

        var completed: Bool {
            switch self {
            case .shell(let snapshot): return snapshot.completed
            case .subagent(let snapshot): return snapshot.completed
            }
        }
    }

    private static func getTaskOutput(
        _ object: [String: JSONValue],
        process: any OpenGrokShellProcessExecution,
        subagents: (any LiveSubagentQuerying)?,
        environment: [String: String]
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let taskIDs = resolveTaskIDs(object)
        guard !taskIDs.isEmpty else {
            return .failure(.invalidCall("get_task_output requires a non-empty task_ids list"))
        }
        // Omitted or zero is a non-blocking snapshot; only a positive value waits.
        let requested = integer(object["timeout_ms"])
        let waits = (requested ?? 0) > 0
        let budget = waits
            ? min(requested ?? defaultWaitTimeoutMilliseconds, maxWaitBlockMilliseconds(environment: environment))
            : 0

        let snapshots: [String: ResolvedTask?]
        if waits {
            snapshots = await waitAll(taskIDs, budgetMilliseconds: budget, process: process, subagents: subagents)
        } else {
            var polled: [String: ResolvedTask?] = [:]
            for taskID in taskIDs {
                if let shell = await process.taskSnapshot(taskID) {
                    polled[taskID] = .shell(shell)
                } else if let subagents, let subagent = await subagents.subagentSnapshot(id: taskID) {
                    polled[taskID] = .subagent(subagent)
                } else {
                    polled[taskID] = nil
                }
            }
            snapshots = polled
        }

        // A single id that resolves to nothing is a hard not-found, matching
        // upstream's `TaskOutputOutput::TaskNotFound`. In a multi-id call the
        // other ids still have answers worth returning, so unknown ids become
        // "not_found" rows instead of failing the whole call.
        if taskIDs.count == 1, snapshots[taskIDs[0]] ?? nil == nil {
            return .success(await notFoundResult(taskIDs[0], process: process, subagents: subagents))
        }

        let results = taskIDs.map { taskID -> JSONValue in
            guard let resolved = snapshots[taskID] ?? nil else {
                return .object([
                    "task_id": .string(taskID),
                    "status": .string("not_found"),
                ])
            }
            switch resolved {
            case .shell(let snapshot): return resultValue(for: snapshot)
            case .subagent(let snapshot): return subagentResultValue(for: snapshot)
            }
        }

        if taskIDs.count == 1, case .object(let single) = results[0] {
            let text: String
            switch snapshots[taskIDs[0]] ?? nil {
            case .shell(let snapshot):
                text = promptText(
                    for: snapshot,
                    taskID: taskIDs[0],
                    waited: waits ? budget : nil
                )
            case .subagent(let snapshot):
                text = subagentPromptText(for: snapshot, waited: waits ? budget : nil)
            case nil:
                text = "Task \(taskIDs[0]) not found."
            }
            return .success(OpenGrokShellToolCallResult(
                value: .object(single),
                promptText: text
            ))
        }

        let completed = taskIDs.filter { (snapshots[$0] ?? nil)?.completed == true }.count
        let summary = "\(completed) of \(taskIDs.count) task(s) complete."
        return .success(OpenGrokShellToolCallResult(
            value: .object([
                "mode": .string(waits ? "wait_all" : "poll"),
                "results": .array(results),
                "summary": .string(summary),
            ]),
            promptText: summary
        ))
    }

    // MARK: wait_tasks

    private static func waitTasks(
        _ object: [String: JSONValue],
        process: any OpenGrokShellProcessExecution,
        subagents: (any LiveSubagentQuerying)?,
        environment: [String: String]
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let taskIDs = resolveTaskIDs(object)
        guard !taskIDs.isEmpty else {
            return .failure(.invalidCall("wait_tasks requires a non-empty task_ids list"))
        }
        let mode = string(object["mode"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "wait_all"
        guard mode == "wait_all" || mode == "wait_any" else {
            return .failure(.invalidCall("wait_tasks mode must be 'wait_all' or 'wait_any'"))
        }
        // Unlike get_task_output, this tool is always in wait mode, so an
        // omitted timeout falls back to the default rather than polling.
        let budget = min(
            integer(object["timeout_ms"]).map { max(0, $0) } ?? defaultWaitTimeoutMilliseconds,
            maxWaitBlockMilliseconds(environment: environment)
        )

        let snapshots: [String: ResolvedTask?]
        if mode == "wait_any" {
            snapshots = await waitAny(taskIDs, budgetMilliseconds: budget, process: process, subagents: subagents)
        } else {
            snapshots = await waitAll(taskIDs, budgetMilliseconds: budget, process: process, subagents: subagents)
        }

        let results = taskIDs.map { taskID -> JSONValue in
            guard let resolved = snapshots[taskID] ?? nil else {
                return .object([
                    "task_id": .string(taskID),
                    "status": .string("not_found"),
                ])
            }
            switch resolved {
            case .shell(let snapshot): return resultValue(for: snapshot)
            case .subagent(let snapshot): return subagentResultValue(for: snapshot)
            }
        }
        let completed = taskIDs.filter { (snapshots[$0] ?? nil)?.completed == true }.count
        let summary = "\(completed) of \(taskIDs.count) task(s) complete."
        return .success(OpenGrokShellToolCallResult(
            value: .object([
                "mode": .string(mode),
                "results": .array(results),
                "summary": .string(summary),
            ]),
            promptText: summary
        ))
    }

    // MARK: kill_task

    private static func killTask(
        _ object: [String: JSONValue],
        process: any OpenGrokShellProcessExecution,
        subagents: (any LiveSubagentQuerying)?
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        guard let taskID = string(object["task_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !taskID.isEmpty
        else {
            return .failure(.invalidCall("kill_task requires a task_id"))
        }
        // `killTask` is ownership-scoped: a task this session did not start
        // reports `.notFound` rather than being signalled.
        switch await process.killTask(taskID) {
        case .killed:
            return .success(OpenGrokShellToolCallResult(
                value: .object([
                    "task_id": .string(taskID),
                    "outcome": .string("killed"),
                    "message": .string("Task \(taskID) terminated."),
                ]),
                promptText: "Task \(taskID) terminated."
            ))
        case .alreadyExited:
            return .success(OpenGrokShellToolCallResult(
                value: .object([
                    "task_id": .string(taskID),
                    "outcome": .string("already_exited"),
                    "message": .string("Task \(taskID) had already exited."),
                ]),
                promptText: "Task \(taskID) had already exited."
            ))
        case .notFound:
            // The id may name a subagent rather than a shell task (upstream
            // `kill_task/mod.rs:214-249`: terminal miss → coordinator cancel).
            if let subagents {
                switch await subagents.cancelSubagent(id: taskID) {
                case .cancelled:
                    return .success(OpenGrokShellToolCallResult(
                        value: .object([
                            "task_id": .string(taskID),
                            "outcome": .string("killed"),
                            "message": .string("Subagent cancellation initiated"),
                        ]),
                        promptText: "Subagent cancellation initiated"
                    ))
                case .alreadyFinished(let status):
                    let message = "Subagent already \(status)"
                    return .success(OpenGrokShellToolCallResult(
                        value: .object([
                            "task_id": .string(taskID),
                            "outcome": .string("already_exited"),
                            "message": .string(message),
                        ]),
                        promptText: message
                    ))
                case .notFound:
                    break
                }
            }
            let message = await notFoundMessage(taskID, process: process, subagents: subagents)
            return .success(OpenGrokShellToolCallResult(
                value: .object([
                    "task_id": .string(taskID),
                    "outcome": .string("not_found"),
                    "message": .string(message),
                ]),
                promptText: message
            ))
        }
    }

    // MARK: - Waiting

    /// Wait for every id, sharing one overall budget. Each wait gets the
    /// remaining time rather than the full budget, so N ids cannot block for
    /// N × the ceiling the model was told about. Shell-owned ids wait on the
    /// process backend; ids it disowns wait on the subagent coordinator.
    private static func waitAll(
        _ taskIDs: [String],
        budgetMilliseconds: Int,
        process: any OpenGrokShellProcessExecution,
        subagents: (any LiveSubagentQuerying)?
    ) async -> [String: ResolvedTask?] {
        let deadline = Date().addingTimeInterval(TimeInterval(budgetMilliseconds) / 1_000)
        var snapshots: [String: ResolvedTask?] = [:]
        for taskID in taskIDs {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                // The shell waits first, exactly as before the unification:
                // a positive timeout must reach `waitForCompletion` even for
                // an id a poll would already answer. A nil return means "not
                // owned" or "still running" — the poll below disambiguates.
                if let waited = await process.waitForCompletion(
                    taskID,
                    timeout: .seconds(remaining)
                ) {
                    snapshots[taskID] = .shell(waited)
                    continue
                }
            }
            if let shell = await process.taskSnapshot(taskID) {
                snapshots[taskID] = .shell(shell)
                continue
            }
            // Not a shell task: the id may name a subagent.
            if let subagents {
                let remainingAfterShell = deadline.timeIntervalSinceNow
                if remainingAfterShell > 0 {
                    snapshots[taskID] = await subagents
                        .awaitSubagent(id: taskID, timeoutMS: UInt64(remainingAfterShell * 1_000))
                        .map { .subagent($0) }
                } else {
                    snapshots[taskID] = await subagents.subagentSnapshot(id: taskID).map { .subagent($0) }
                }
                continue
            }
            snapshots[taskID] = nil
        }
        return snapshots
    }

    /// Return as soon as any one id completes, then poll the rest. The losing
    /// child waits are cancelled with the group.
    private static func waitAny(
        _ taskIDs: [String],
        budgetMilliseconds: Int,
        process: any OpenGrokShellProcessExecution,
        subagents: (any LiveSubagentQuerying)?
    ) async -> [String: ResolvedTask?] {
        let timeout = TimeInterval(budgetMilliseconds) / 1_000
        let winner: (String, ResolvedTask)? = await withTaskGroup(
            of: (String, ResolvedTask)?.self
        ) { group in
            for taskID in taskIDs {
                group.addTask {
                    if let snapshot = await process.waitForCompletion(taskID, timeout: .seconds(timeout)),
                       snapshot.completed {
                        return (taskID, .shell(snapshot))
                    }
                    if let subagents,
                       let snapshot = await subagents.awaitSubagent(id: taskID, timeoutMS: UInt64(timeout * 1_000)),
                       snapshot.completed {
                        return (taskID, .subagent(snapshot))
                    }
                    return nil
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        var snapshots: [String: ResolvedTask?] = [:]
        for taskID in taskIDs {
            if let winner, winner.0 == taskID {
                snapshots[taskID] = winner.1
            } else if let shell = await process.taskSnapshot(taskID) {
                snapshots[taskID] = .shell(shell)
            } else if let subagents, let subagent = await subagents.subagentSnapshot(id: taskID) {
                snapshots[taskID] = .subagent(subagent)
            } else {
                snapshots[taskID] = nil
            }
        }
        return snapshots
    }

    // MARK: - Rendering

    /// Upstream's terminal statuses are `completed` / `failed` / `cancelled`;
    /// anything else reads as still running.
    static func status(for snapshot: ShellTaskSnapshot) -> String {
        guard snapshot.completed else { return "running" }
        if snapshot.explicitlyKilled { return "cancelled" }
        if snapshot.signal != nil { return "failed" }
        if let exitCode = snapshot.exitCode { return exitCode == 0 ? "completed" : "failed" }
        return "completed"
    }

    private static func resultValue(for snapshot: ShellTaskSnapshot) -> JSONValue {
        var object: [String: JSONValue] = [
            "task_id": .string(snapshot.taskID),
            "command": .string(snapshot.displayCommand ?? snapshot.command),
            "status": .string(status(for: snapshot)),
            "exit_code": snapshot.exitCode.map { .number(.int64(Int64($0))) } ?? .null,
            "started": .string(iso8601.string(from: snapshot.startTime)),
            "ended": snapshot.endTime.map { .string(iso8601.string(from: $0)) } ?? .null,
            "duration_secs": .number(.double(snapshot.duration())),
            "output": .string(snapshot.output),
            "output_file": .string(snapshot.outputFile?.path ?? ""),
            "truncated": .bool(snapshot.truncated),
            "raw_output_bytes": .number(.int64(Int64(snapshot.outputTotalBytes))),
        ]
        if snapshot.truncated {
            object["truncation_hint"] = .string(
                snapshot.outputFile.map {
                    "Output was truncated. Use read_file on \($0.path) for the full output."
                } ?? "Output was truncated."
            )
        }
        if let signal = snapshot.signal {
            object["signal"] = .string(signal)
        }
        return .object(object)
    }

    /// The subagent twin of `resultValue(for:)` — the same
    /// `TaskOutputResult` shape upstream's `format_subagent_snapshot`
    /// produces, with no `output_file` (a subagent's output lives in the
    /// coordinator, not on disk).
    private static func subagentResultValue(for snapshot: LiveSubagentSnapshot) -> JSONValue {
        .object([
            "task_id": .string(snapshot.subagentID),
            "command": .string("[subagent:\(snapshot.subagentType)] \(snapshot.description)"),
            "status": .string(snapshot.status),
            "exit_code": snapshot.exitCode.map { .number(.int64(Int64($0))) } ?? .null,
            "started": .string(iso8601.string(from: snapshot.startedAt)),
            "ended": snapshot.completed
                ? .string(iso8601.string(from: snapshot.startedAt.addingTimeInterval(Double(snapshot.durationMS) / 1_000)))
                : .null,
            "duration_secs": .number(.double(Double(snapshot.durationMS) / 1_000)),
            "output": .string(snapshot.output),
            "output_file": .string(""),
            "truncated": .bool(false),
            "raw_output_bytes": .number(.int64(Int64(snapshot.output.utf8.count))),
        ])
    }

    /// The model-facing text for a subagent row. A terminal row's text is the
    /// output itself — unlike a shell task there is no `output_file` to point
    /// at, so a status-only line would hide the very answer the tool exists
    /// to return. A running row carries the live progress body plus the wait
    /// hint; the hint promises no completion notification because this
    /// composition has no auto-wake (deferred, recorded in the slice report).
    private static func subagentPromptText(for snapshot: LiveSubagentSnapshot, waited: Int?) -> String {
        guard !snapshot.completed else {
            return snapshot.output
        }
        guard let waited, waited > 0 else {
            return snapshot.output + "\n\nUse timeout_ms to wait for completion."
        }
        let label = waited < 1_000 ? "\(waited)ms" : "\(waited / 1_000)s"
        return snapshot.output + "\n\nWaited \(label); the subagent is still running. You do not need to call this again."
    }

    private static func promptText(
        for snapshot: ShellTaskSnapshot?,
        taskID: String,
        waited: Int?
    ) -> String {
        guard let snapshot else { return "Task \(taskID) not found." }
        let state = status(for: snapshot)
        guard state == "running" else {
            let code = snapshot.exitCode.map { " (exit \($0))" } ?? ""
            return "Task \(taskID) \(state)\(code)."
        }
        // Mirrors upstream's still-running hint: tell the model not to spin.
        guard let waited, waited > 0 else {
            return "Task \(taskID) is still running. Use timeout_ms to wait for completion."
        }
        let label = waited < 1_000 ? "\(waited)ms" : "\(waited / 1_000)s"
        return "Waited \(label); task \(taskID) is still running. You do not need to call this again."
    }

    private static func notFoundResult(
        _ taskID: String,
        process: any OpenGrokShellProcessExecution,
        subagents: (any LiveSubagentQuerying)?
    ) async -> OpenGrokShellToolCallResult {
        let message = await notFoundMessage(taskID, process: process, subagents: subagents)
        return OpenGrokShellToolCallResult(
            value: .object([
                "task_id": .string(taskID),
                "status": .string("not_found"),
                "message": .string(message),
            ]),
            promptText: message
        )
    }

    /// Upstream enumerates the ids this session does know, so a model that
    /// guessed or truncated an id can correct itself without another tool call.
    private static func notFoundMessage(
        _ taskID: String,
        process: any OpenGrokShellProcessExecution,
        subagents: (any LiveSubagentQuerying)?
    ) async -> String {
        let shellIDs = await process.listTasks().map(\.taskID)
        let subagentIDs = await subagents?.knownSubagentIDs() ?? []
        let known = shellIDs + subagentIDs
        if known.isEmpty {
            // With subagents live the empty message names them, matching
            // upstream's "No background tasks or subagents exist in this
            // session."; without them the original wording stands.
            if subagents != nil {
                return "Task \(taskID) not found. No background tasks or subagents exist in this session."
            }
            return "Task \(taskID) not found. No background tasks exist in this session."
        }
        return "Task \(taskID) not found. Known task IDs: [\(known.joined(separator: ", "))]"
    }

    /// `ISO8601DateFormatter` is not `Sendable`, but its formatting methods are
    /// documented as safe to call concurrently and nothing here ever mutates
    /// `formatOptions` after construction.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Argument coercion

    /// Trimmed, de-duplicated ids in first-seen order.
    ///
    /// Lenient the way upstream's deserializer is: the singular `task_id` key
    /// and a bare string both resolve. Upstream added that leniency after
    /// observing models mirror `kill_task`'s singular `task_id` here — 3 of 4
    /// organic calls in one rollout — and abandon the background workflow for
    /// shell polling once the call hard-failed.
    static func resolveTaskIDs(_ object: [String: JSONValue]) -> [String] {
        var raw: [String] = []
        for key in ["task_ids", "task_id"] {
            switch object[key] {
            case .array(let items):
                raw.append(contentsOf: items.compactMap(scalarString))
            case .some(let value):
                if let single = scalarString(value) { raw.append(single) }
            case .none:
                continue
            }
            if !raw.isEmpty { break }
        }
        var seen: Set<String> = []
        var out: [String] = []
        for id in raw {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    private static func scalarString(_ value: JSONValue) -> String? {
        switch value {
        case .string(let string): return string
        case .number(let number):
            if let integer = number.int64Value { return String(integer) }
            if let unsigned = number.uint64Value { return String(unsigned) }
            return nil
        default: return nil
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            if let integer = number.int64Value { return Int(exactly: integer) }
            if let unsigned = number.uint64Value { return Int(exactly: unsigned) }
            return Int(exactly: number.doubleValue.rounded())
        case .string(let string):
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
