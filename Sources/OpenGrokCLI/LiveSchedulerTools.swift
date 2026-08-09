// LiveSchedulerTools.swift
//
// The `scheduler_create` / `scheduler_delete` / `scheduler_list` tool
// handlers — specs, argument coercion, and dispatch onto the session's
// `LiveSchedulerHost`. Ports of `xai-grok-tools/src/implementations/
// grok_build/scheduler/{create,delete,list}.rs`, following the
// `LiveBackgroundTaskTools` handler shape (specs + a dispatch entry the
// executor routes to).
//
// These are session-state RPCs: no filesystem, no process. Upstream gates
// them with the standard PreToolUse hook pass and no permission-rule kind
// (`requires_expr` is `Expr::True` for create; delete/list only require the
// create surface, delete.rs:48-56 / list.rs:45-53) — the executor's
// `gateSchedulerTool` mirrors that.

import Foundation
import OpenGrokScheduler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokToolTypes
import OpenGrokToolsAPI

enum LiveSchedulerTools {
    // MARK: - Names

    /// `scheduler_create` — the canonical spelling lives in OpenGrokToolsAPI
    /// (the port of `xai-grok-tools-api`'s `SCHEDULER_CREATE_TOOL_NAME`) so
    /// the `/loop` gate and this handler cannot drift apart.
    static let createToolName = schedulerCreateToolName
    static let deleteToolName = "scheduler_delete"
    static let listToolName = "scheduler_list"

    static let toolNames: Set<String> = [
        createToolName, deleteToolName, listToolName,
    ]

    // MARK: - Specs

    static func toolSpecs() -> [ToolSpec] {
        [createSpec(), deleteSpec(), listSpec()]
    }

    /// Description and field docs verbatim from `create.rs:14-121` (the Rust
    /// `\`-continuations join with a single space). `recurring` is accepted
    /// at dispatch as a legacy flag but never advertised — upstream's
    /// `#[schemars(skip)]` (create.rs:40), pinned by its
    /// `schema_hides_recurring_and_advertises_task_id` test.
    static func createSpec() -> ToolSpec {
        ToolSpec(
            name: createToolName,
            description: """
            Create a scheduled task that runs a prompt on a recurring interval, or update an existing one in place.

            Set fire_immediately: true to also fire once on creation; by default the first run waits for the interval.

            To change an existing task, pass its task_id: provided fields replace old values, omitted ones are unchanged, and the schedule keeps its phase. An unknown id errors.

            Usage notes:
            - Interval format: "5m" (minutes), "2h" (hours), "1d" (days), "60s" (seconds, min 60)
            - Maximum 50 scheduled tasks at once
            - Tasks auto-expire after 7 days
            - For one-time delayed work, run a background terminal command (e.g. `sleep 1800 && <command>`) instead; its completion notifies you
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "task_id": .object([
                        "type": .string("string"),
                        "description": .string("Id of an existing task to update in place: provided fields replace old values, omitted ones are unchanged, the schedule keeps its phase, and an unknown id errors. Omit to create a task."),
                    ]),
                    "interval": .object([
                        "type": .string("string"),
                        "description": .string("Interval between executions, e.g. \"5m\", \"2h\", \"1d\". Required to create; optional with task_id"),
                    ]),
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("The prompt text to execute on each scheduled fire. Required to create; optional with task_id"),
                    ]),
                    "durable": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the task persists across sessions. Default: false. Create-only: ignored with task_id"),
                    ]),
                    "foreground": .object([
                        "type": .string("boolean"),
                        "description": .string("Run each fire as a main-conversation turn instead of a background subagent; set true only when runs need the conversation's context. Default: false. Create-only: ignored with task_id"),
                    ]),
                    "fire_immediately": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether to fire immediately on creation (true) or wait for the first interval (false). Default: false. Create-only: ignored with task_id"),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// `delete.rs:38-42`, verbatim.
    static func deleteSpec() -> ToolSpec {
        ToolSpec(
            name: deleteToolName,
            description: """
            Cancel a scheduled task by ID.

            Returns success: true if the task was found and removed, false if no task with that ID exists.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("The task ID to cancel (from scheduler_create output)"),
                    ]),
                ]),
                "required": .array([.string("id")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// `list.rs:41-43`, verbatim.
    static func listSpec() -> ToolSpec {
        ToolSpec(
            name: listToolName,
            description: "List all active scheduled tasks with their IDs, prompts, intervals, and next fire times.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    // MARK: - Dispatch

    static func invoke(
        name: String,
        args: JSONValue,
        host: LiveSchedulerHost
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        guard case .object(let object) = args else {
            return .failure(.invalidCall("\(name) requires an object argument"))
        }
        switch name {
        case createToolName:
            return await create(object, host: host)
        case deleteToolName:
            return await delete(object, host: host)
        case listToolName:
            return await list(host: host)
        default:
            return .failure(.unsupported("unknown tool '\(name)'"))
        }
    }

    // MARK: scheduler_create

    /// Port of `SchedulerCreateTool::run` (`create.rs:163-274`), same check
    /// order: interval parse → update branch → legacy `recurring` refusal →
    /// required interval/prompt → create.
    private static func create(
        _ object: [String: JSONValue],
        host: LiveSchedulerHost
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let intervalSecs: UInt64?
        if let rawInterval = string(object["interval"]) {
            do {
                intervalSecs = try parseInterval(rawInterval)
            } catch let error as SchedulerError {
                // Upstream: `invalid_arguments(e.to_string())`
                // (create.rs:171-176) — the library's thrown message IS the
                // model-facing text; rewording it here would change what a
                // failed call reads back.
                return .failure(.invalidCall(error.description))
            } catch {
                return .failure(.invalidCall(String(describing: error)))
            }
        } else {
            intervalSecs = nil
        }

        if let taskID = string(object["task_id"]) {
            let prompt = string(object["prompt"])
            if prompt == nil, intervalSecs == nil {
                return .failure(.invalidCall(
                    "nothing to update: provide interval and/or prompt alongside task_id"
                ))
            }
            do {
                let updated = try await host.updateTask(
                    id: taskID,
                    prompt: prompt,
                    intervalSecs: intervalSecs
                )
                return createResult(
                    id: updated.id,
                    humanSchedule: intervalToHuman(updated.intervalSecs),
                    updated: true
                )
            } catch let error as SchedulerError {
                return .failure(.failed(error.description))
            } catch {
                return .failure(.failed(String(describing: error)))
            }
        }

        // Legacy flag, hidden from the schema: `recurring: false` is refused
        // with upstream's sleep guidance (create.rs:231-236).
        if lenientBool(object["recurring"], default: true) == false {
            return .failure(.invalidCall(
                "one-shot tasks are not supported; run a background terminal command instead (`sleep <secs> && <command>`, background: true) or do the work now"
            ))
        }

        guard let intervalSecs else {
            return .failure(.invalidCall("interval is required when creating a task"))
        }
        guard let prompt = string(object["prompt"]) else {
            return .failure(.invalidCall("prompt is required when creating a task"))
        }

        do {
            let created = try await host.createTask(
                intervalSecs: intervalSecs,
                prompt: prompt,
                durable: lenientBool(object["durable"], default: false),
                foreground: lenientBool(object["foreground"], default: false),
                fireImmediately: lenientBool(object["fire_immediately"], default: false)
            )
            return createResult(
                id: created.id,
                humanSchedule: intervalToHuman(intervalSecs),
                updated: false
            )
        } catch let error as SchedulerError {
            return .failure(.failed(error.description))
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    private static func createResult(
        id: String,
        humanSchedule: String,
        updated: Bool
    ) -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let value: JSONValue = .object([
            "id": .string(id),
            "humanSchedule": .string(humanSchedule),
            "updated": .bool(updated),
        ])
        return .success(OpenGrokShellToolCallResult(
            value: value,
            promptText: encodeJSON(value)
        ))
    }

    // MARK: scheduler_delete

    /// Port of `SchedulerDeleteTool::run` (`delete.rs:90-142`); messages
    /// verbatim.
    private static func delete(
        _ object: [String: JSONValue],
        host: LiveSchedulerHost
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        guard let id = string(object["id"]) else {
            return .failure(.invalidCall("\(deleteToolName) requires an id"))
        }
        let removed: Bool
        do {
            removed = try await host.deleteTask(id: id)
        } catch let error as SchedulerError {
            // The durable-removal barrier's failures — upstream maps them
            // through `scheduler_tool_error` (`types.rs:188-201`) and the
            // thrown display string is the model-facing text
            // (`delete.rs` → `scheduler_tool_error(e)`).
            return .failure(.failed(error.description))
        } catch {
            return .failure(.failed(String(describing: error)))
        }
        let message = removed
            ? "Scheduled task \(id) cancelled."
            : "No scheduled task with ID \(id) found. Use scheduler_list to see active tasks."
        let value: JSONValue = .object([
            "success": .bool(removed),
            "message": .string(message),
        ])
        return .success(OpenGrokShellToolCallResult(
            value: value,
            promptText: encodeJSON(value)
        ))
    }

    // MARK: scheduler_list

    /// Port of `SchedulerListTool::run` (`list.rs:83-145`): camelCase summary
    /// rows with the 80-byte prompt truncation.
    private static func list(
        host: LiveSchedulerHost
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let tasks = await host.list().map { task -> JSONValue in
            .object([
                "id": .string(task.id),
                "prompt": .string(truncatedPrompt(task.prompt)),
                "intervalHuman": .string(intervalToHuman(task.intervalSecs)),
                "nextFireAt": .string(RFC3339.string(from: task.nextFireAt())),
                "createdAt": .string(RFC3339.string(from: task.createdAt)),
                "recurring": .bool(task.recurring),
            ])
        }
        let value: JSONValue = .object(["tasks": .array(tasks)])
        return .success(OpenGrokShellToolCallResult(
            value: value,
            promptText: encodeJSON(value)
        ))
    }

    /// `list.rs:127-132`: prompts over 80 BYTES are cut at the largest scalar
    /// boundary at or below 80 (`floor_char_boundary`) and marked "...".
    static func truncatedPrompt(_ prompt: String) -> String {
        guard prompt.utf8.count > 80 else { return prompt }
        let scalars = prompt.unicodeScalars
        var bytes = 0
        var end = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let width = utf8Width(scalars[index])
            if bytes + width > 80 { break }
            bytes += width
            index = scalars.index(after: index)
            end = index
        }
        return String(String.UnicodeScalarView(scalars[..<end])) + "..."
    }

    /// UTF-8 encoded length of one scalar (RFC 3629 ranges).
    private static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case ..<0x80: return 1
        case ..<0x800: return 2
        case ..<0x1_0000: return 3
        default: return 4
        }
    }

    // MARK: - Helpers

    /// The model reads the tool result's prompt text, so the structured
    /// output must ride there (upstream returns the serde-serialized output
    /// struct). Keys are sorted for determinism; upstream emits declaration
    /// order — a cosmetic, recorded divergence.
    private static func encodeJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    /// Upstream's `deserialize_lenient_bool` semantics with a per-field
    /// default for the absent key; an unparseable value falls back to the
    /// default rather than failing the call (a divergence from upstream's
    /// deserialization error, recorded — strictly more permissive on inputs
    /// the schema already forbids).
    private static func lenientBool(_ value: JSONValue?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        return lenientBoolFromJSON(value) ?? defaultValue
    }
}
