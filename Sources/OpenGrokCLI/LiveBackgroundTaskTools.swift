// LiveBackgroundTaskTools.swift
//
// The consumer half of background execution:
// `get_command_or_subagent_output`, `wait_commands_or_subagents` and
// `kill_command_or_subagent` — upstream's production names for the registry
// trio `get_task_output` / `wait_tasks` / `kill_task`.
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

    static let getTaskOutputName = "get_command_or_subagent_output"
    static let waitTasksName = "wait_commands_or_subagents"
    static let killTaskName = "kill_command_or_subagent"

    static let toolNames: Set<String> = [
        getTaskOutputName, waitTasksName, killTaskName,
    ]

    /// Registry names upstream's grok-build preset renames away from
    /// (`xai-grok-agent/src/config.rs:161-173`). Swift advertises the production
    /// names the way every profile in `AgentDefinitionSchema` spells them; the
    /// short registry names still resolve at dispatch for older prompts.
    static let aliases: [String: String] = [
        "get_task_output": getTaskOutputName,
        "wait_tasks": waitTasksName,
        "kill_task": killTaskName,
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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ToolSpec] {
        let cap = formatWaitCap(maxWaitBlockMilliseconds(environment: environment))
        return [
            getTaskOutputSpec(waitCap: cap),
            waitTasksSpec(waitCap: cap),
            killTaskSpec,
        ]
    }

    /// Wording mirrors `xai_tool_types::build_task_output_description` for the
    /// shape this session actually finalizes: bash present, no monitor tool and
    /// no subagent tool, so the target suffix and monitor note are both empty.
    static func getTaskOutputSpec(waitCap: String) -> ToolSpec {
        ToolSpec(
            name: getTaskOutputName,
            description: """
            Get output and status from a background task.

            Usage notes:
            - Pass task_ids with one or more ids from is_background=true commands; for a single task use a one-element array. Multiple ids with a positive timeout_ms wait until all complete
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
    /// `get_command_or_subagent_output` with a positive `timeout_ms` is the
    /// preferred path — but `wait_any` exists only here, so it is not purely
    /// redundant.
    static func waitTasksSpec(waitCap: String) -> ToolSpec {
        ToolSpec(
            name: waitTasksName,
            description: """
            Wait for multiple background tasks or subagents to complete.

            Prefer get_command_or_subagent_output with task_ids and a positive timeout_ms. This tool is kept for compatibility.

            Usage notes:
            - task_ids: list of task IDs from is_background=true commands
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
    /// `bash_present: true`, no monitor tool and no subagent tool.
    static let killTaskSpec = ToolSpec(
        name: killTaskName,
        description: """
        Terminate a running background task.

        Usage notes:
        - Pass its task_id.
        - Sends SIGTERM/SIGKILL to a bash task.
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

    // MARK: - Dispatch

    static func invoke(
        name: String,
        args: JSONValue,
        process: any OpenGrokShellProcessExecution,
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
            return await getTaskOutput(object, process: process, environment: environment)
        case waitTasksName:
            return await waitTasks(object, process: process, environment: environment)
        case killTaskName:
            return await killTask(object, process: process)
        default:
            return .failure(.unsupported("unknown tool '\(name)'"))
        }
    }

    // MARK: get_task_output

    private static func getTaskOutput(
        _ object: [String: JSONValue],
        process: any OpenGrokShellProcessExecution,
        environment: [String: String]
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let taskIDs = resolveTaskIDs(object)
        guard !taskIDs.isEmpty else {
            return .failure(.invalidCall("\(getTaskOutputName) requires a non-empty task_ids list"))
        }
        // Omitted or zero is a non-blocking snapshot; only a positive value waits.
        let requested = integer(object["timeout_ms"])
        let waits = (requested ?? 0) > 0
        let budget = waits
            ? min(requested ?? defaultWaitTimeoutMilliseconds, maxWaitBlockMilliseconds(environment: environment))
            : 0

        let snapshots: [String: ShellTaskSnapshot?]
        if waits {
            snapshots = await waitAll(taskIDs, budgetMilliseconds: budget, process: process)
        } else {
            var polled: [String: ShellTaskSnapshot?] = [:]
            for taskID in taskIDs {
                polled[taskID] = await process.taskSnapshot(taskID)
            }
            snapshots = polled
        }

        // A single id that resolves to nothing is a hard not-found, matching
        // upstream's `TaskOutputOutput::TaskNotFound`. In a multi-id call the
        // other ids still have answers worth returning, so unknown ids become
        // "not_found" rows instead of failing the whole call.
        if taskIDs.count == 1, snapshots[taskIDs[0]] ?? nil == nil {
            return .success(await notFoundResult(taskIDs[0], process: process))
        }

        let results = taskIDs.map { taskID -> JSONValue in
            guard let snapshot = snapshots[taskID] ?? nil else {
                return .object([
                    "task_id": .string(taskID),
                    "status": .string("not_found"),
                ])
            }
            return resultValue(for: snapshot)
        }

        if taskIDs.count == 1, case .object(let single) = results[0] {
            return .success(OpenGrokShellToolCallResult(
                value: .object(single),
                promptText: promptText(
                    for: snapshots[taskIDs[0]] ?? nil,
                    taskID: taskIDs[0],
                    waited: waits ? budget : nil
                )
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
        environment: [String: String]
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let taskIDs = resolveTaskIDs(object)
        guard !taskIDs.isEmpty else {
            return .failure(.invalidCall("\(waitTasksName) requires a non-empty task_ids list"))
        }
        let mode = string(object["mode"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "wait_all"
        guard mode == "wait_all" || mode == "wait_any" else {
            return .failure(.invalidCall("\(waitTasksName) mode must be 'wait_all' or 'wait_any'"))
        }
        // Unlike get_task_output, this tool is always in wait mode, so an
        // omitted timeout falls back to the default rather than polling.
        let budget = min(
            integer(object["timeout_ms"]).map { max(0, $0) } ?? defaultWaitTimeoutMilliseconds,
            maxWaitBlockMilliseconds(environment: environment)
        )

        let snapshots: [String: ShellTaskSnapshot?]
        if mode == "wait_any" {
            snapshots = await waitAny(taskIDs, budgetMilliseconds: budget, process: process)
        } else {
            snapshots = await waitAll(taskIDs, budgetMilliseconds: budget, process: process)
        }

        let results = taskIDs.map { taskID -> JSONValue in
            guard let snapshot = snapshots[taskID] ?? nil else {
                return .object([
                    "task_id": .string(taskID),
                    "status": .string("not_found"),
                ])
            }
            return resultValue(for: snapshot)
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
        process: any OpenGrokShellProcessExecution
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        guard let taskID = string(object["task_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !taskID.isEmpty
        else {
            return .failure(.invalidCall("\(killTaskName) requires a task_id"))
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
            let message = await notFoundMessage(taskID, process: process)
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

    /// Wait for every id, sharing one overall budget. Each `waitForCompletion`
    /// gets the remaining time rather than the full budget, so N ids cannot
    /// block for N × the ceiling the model was told about.
    private static func waitAll(
        _ taskIDs: [String],
        budgetMilliseconds: Int,
        process: any OpenGrokShellProcessExecution
    ) async -> [String: ShellTaskSnapshot?] {
        let deadline = Date().addingTimeInterval(TimeInterval(budgetMilliseconds) / 1_000)
        var snapshots: [String: ShellTaskSnapshot?] = [:]
        for taskID in taskIDs {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                snapshots[taskID] = await process.taskSnapshot(taskID)
                continue
            }
            let waited = await process.waitForCompletion(
                taskID,
                timeout: .seconds(remaining)
            )
            // A nil here can mean either "not owned" or "still running", so fall
            // back to a poll before concluding the id is unknown.
            if let waited {
                snapshots[taskID] = waited
            } else {
                snapshots[taskID] = await process.taskSnapshot(taskID)
            }
        }
        return snapshots
    }

    /// Return as soon as any one id completes, then poll the rest. The losing
    /// child waits are cancelled with the group.
    private static func waitAny(
        _ taskIDs: [String],
        budgetMilliseconds: Int,
        process: any OpenGrokShellProcessExecution
    ) async -> [String: ShellTaskSnapshot?] {
        let timeout = TimeInterval(budgetMilliseconds) / 1_000
        let winner: ShellTaskSnapshot? = await withTaskGroup(
            of: ShellTaskSnapshot?.self
        ) { group in
            for taskID in taskIDs {
                group.addTask {
                    await process.waitForCompletion(taskID, timeout: .seconds(timeout))
                }
            }
            for await snapshot in group where snapshot?.completed == true {
                group.cancelAll()
                return snapshot
            }
            return nil
        }
        var snapshots: [String: ShellTaskSnapshot?] = [:]
        for taskID in taskIDs {
            if let winner, winner.taskID == taskID {
                snapshots[taskID] = winner
            } else {
                snapshots[taskID] = await process.taskSnapshot(taskID)
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
        process: any OpenGrokShellProcessExecution
    ) async -> OpenGrokShellToolCallResult {
        let message = await notFoundMessage(taskID, process: process)
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
        process: any OpenGrokShellProcessExecution
    ) async -> String {
        let known = await process.listTasks().map(\.taskID)
        if known.isEmpty {
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
