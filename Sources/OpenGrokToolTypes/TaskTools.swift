// TaskTools.swift
//
// Open Grok — Swift port of `xai-tool-types/src/task.rs`.
//
// Input/output types for the background-task / sub-agent task tools
// (`task`, `get_task_output`, `wait_tasks`, `kill_task`, `agent_swarm`,
// `workflow`), plus the built-in subagent catalog and the
// product-parameterised tool-description builders.
//
// Wire compatibility: every Codable type round-trips byte-significantly
// against the Rust `serde_json` fixtures. Optional fields use
// `encodeIfPresent` so `nil` is omitted on the wire, matching
// `#[serde(skip_serializing_if = "Option::is_none")]`. `run_in_background`
// defaults to `true` and uses the lenient bool decoder.
//
// Rust crate mapping: crates/common/xai-tool-types/src/task.rs. See
// CRATE_MAP.md (W1-S1).

import Foundation
import OpenGrokShared

// MARK: - Capability / Isolation modes

/// Capability mode controlling which tool classes a child agent can use.
///
/// Mirrors Rust `SubagentCapabilityMode`. Wire form is kebab-case
/// (`"read-only"`, `"read-write"`, `"execute"`, `"all"`), with serde
/// aliases for the common camelCase / underscore variants.
public enum SubagentCapabilityMode: String, Codable, Sendable, Hashable {
    case readOnly = "read-only"
    case readWrite = "read-write"
    case execute
    case all

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        switch s.lowercased() {
        case "read-only", "readonly", "read_only": self = .readOnly
        case "read-write", "readwrite", "read_write": self = .readWrite
        case "execute": self = .execute
        case "all": self = .all
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown SubagentCapabilityMode: \(s)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Canonical wire string.
    public var wireString: String { rawValue }
}

/// Isolation mode for subagent execution.
///
/// Mirrors Rust `SubagentIsolationMode`. Wire form is kebab-case
/// (`"none"`, `"worktree"`); `.none` is the default.
public enum SubagentIsolationMode: String, Codable, Sendable, Hashable, Defaultable {
    case none
    case worktree

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        switch s.lowercased() {
        case "none": self = .none
        case "worktree", "work_tree", "work-tree": self = .worktree
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown SubagentIsolationMode: \(s)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var wireString: String { rawValue }

    public static var defaultValue: SubagentIsolationMode { .none }
}

// MARK: - Defaultable helper

/// A marker protocol for types with a compile-time default value, used by
/// lenient decoders that fall back to the default when a field is absent
/// or malformed. Mirrors Rust's `#[serde(default)]` on `Default`-impl
/// types.
public protocol Defaultable {
    static var defaultValue: Self { get }
}

// MARK: - TaskToolInput (`task` spawn tool)

/// Input for the `task` tool — launches a subagent to handle a task
/// autonomously.
///
/// Mirrors Rust `TaskToolInput`. `run_in_background` defaults to `true`
/// and uses the lenient bool decoder. `subagent_type` defaults to
/// `"general-purpose"` when omitted.
public struct TaskToolInput: Codable, Sendable, Hashable {
    /// The full task prompt for the subagent to execute.
    public var prompt: String

    /// Short description of the task (3-5 words).
    public var description: String

    /// Name of the subagent type to launch. Defaults to
    /// `"general-purpose"` when omitted.
    public var subagentType: String

    /// Whether to run the subagent in the background. Defaults to `true`.
    /// Decoded leniently (accepts `"true"`/`"yes"`/`1`/etc.).
    public var runInBackground: Bool

    /// Capability mode controlling the child's tool access.
    public var capabilityMode: SubagentCapabilityMode?

    /// Isolation mode for the child's execution environment.
    public var isolation: SubagentIsolationMode?

    /// Resume a previous subagent's conversation instead of starting fresh.
    public var resumeFrom: String?

    /// Explicit working directory for the subagent.
    public var cwd: String?

    /// Optional model slug for this subagent.
    public var model: String?

    /// Server-injected before execution. Becomes the subagent's session ID.
    public var taskId: String?

    private enum CodingKeys: String, CodingKey {
        case prompt
        case description
        case subagentType = "subagent_type"
        case runInBackground = "run_in_background"
        case capabilityMode = "capability_mode"
        case isolation
        case resumeFrom = "resume_from"
        case cwd
        case model
        case taskId = "task_id"
    }

    public init(
        prompt: String,
        description: String,
        subagentType: String = defaultSubagentType,
        runInBackground: Bool = true,
        capabilityMode: SubagentCapabilityMode? = nil,
        isolation: SubagentIsolationMode? = nil,
        resumeFrom: String? = nil,
        cwd: String? = nil,
        model: String? = nil,
        taskId: String? = nil
    ) {
        self.prompt = prompt
        self.description = description
        self.subagentType = subagentType
        self.runInBackground = runInBackground
        self.capabilityMode = capabilityMode
        self.isolation = isolation
        self.resumeFrom = resumeFrom
        self.cwd = cwd
        self.model = model
        self.taskId = taskId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.description = try c.decode(String.self, forKey: .description)
        self.subagentType = try c.decodeIfPresent(String.self, forKey: .subagentType) ?? defaultSubagentType
        // Lenient bool with default true.
        if c.contains(.runInBackground) {
            let raw = try c.decode(JSONValue.self, forKey: .runInBackground)
            self.runInBackground = try decodeLenientBool(raw)
        } else {
            self.runInBackground = true
        }
        self.capabilityMode = try c.decodeIfPresent(SubagentCapabilityMode.self, forKey: .capabilityMode)
        self.isolation = try c.decodeIfPresent(SubagentIsolationMode.self, forKey: .isolation)
        self.resumeFrom = try c.decodeIfPresent(String.self, forKey: .resumeFrom)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
    }
}

/// Default `subagent_type` for `TaskToolInput` when the caller omits it.
public let defaultSubagentType: String = "general-purpose"

// MARK: - AgentSwarmToolInput

/// Input for `agent_swarm`, which launches a bounded foreground cohort of
/// subagents and returns their ordered results.
///
/// Mirrors Rust `AgentSwarmToolInput`.
public struct AgentSwarmToolInput: Codable, Sendable, Hashable {
    public var description: String
    public var subagentType: String
    public var model: String?
    public var promptTemplate: String?
    public var items: [String]?
    public var resumeAgentIds: OrderedResumeAgentMap?

    private enum CodingKeys: String, CodingKey {
        case description
        case subagentType = "subagent_type"
        case model
        case promptTemplate = "prompt_template"
        case items
        case resumeAgentIds = "resume_agent_ids"
    }

    public init(
        description: String,
        subagentType: String = defaultSubagentType,
        model: String? = nil,
        promptTemplate: String? = nil,
        items: [String]? = nil,
        resumeAgentIds: OrderedResumeAgentMap? = nil
    ) {
        self.description = description
        self.subagentType = subagentType
        self.model = model
        self.promptTemplate = promptTemplate
        self.items = items
        self.resumeAgentIds = resumeAgentIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.description = try c.decode(String.self, forKey: .description)
        self.subagentType = try c.decodeIfPresent(String.self, forKey: .subagentType) ?? defaultSubagentType
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.promptTemplate = try c.decodeIfPresent(String.self, forKey: .promptTemplate)
        self.items = try c.decodeIfPresent([String].self, forKey: .items)
        self.resumeAgentIds = try c.decodeIfPresent(OrderedResumeAgentMap.self, forKey: .resumeAgentIds)
    }
}

/// An insertion-ordered JSON object used for `AgentSwarm.resume_agent_ids`.
///
/// Mirrors Rust `OrderedResumeAgentMap`. Preserves the deserializer's
/// member order rather than sorting keys. Duplicate keys use normal map
/// semantics: the last supplied value wins while retaining its original
/// slot.
public struct OrderedResumeAgentMap: Codable, Sendable, Hashable {
    /// One key/value entry, preserving insertion order. We use a small
    /// `Entry` struct (not a bare tuple) so `OrderedResumeAgentMap`
    /// synthesises `Equatable`/`Hashable` conformance.
    public struct Entry: Codable, Sendable, Hashable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var entries: [Entry]

    public init(entries: [(String, String)] = []) {
        // Deduplicate by key, last value wins, original slot retained.
        var seen: [String: Int] = [:]
        var out: [Entry] = []
        for (k, v) in entries {
            if let idx = seen[k] {
                out[idx] = Entry(key: k, value: v)
            } else {
                seen[k] = out.count
                out.append(Entry(key: k, value: v))
            }
        }
        self.entries = out
    }

    public init(entries: [Entry]) {
        // Deduplicate by key, last value wins, original slot retained.
        var seen: [String: Int] = [:]
        var out: [Entry] = []
        for e in entries {
            if let idx = seen[e.key] {
                out[idx] = e
            } else {
                seen[e.key] = out.count
                out.append(e)
            }
        }
        self.entries = out
    }

    public init(from decoder: Decoder) throws {
        // Decode as an ordered sequence of key/value pairs. Swift's
        // KeyedDecodingContainer does not preserve order, so we decode
        // via the dynamic AnyCodingKey path and walk all keys.
        let dyn = try decoder.container(keyedBy: AnyCodingKey.self)
        var seen: [String: Int] = [:]
        var out: [Entry] = []
        for key in dyn.allKeys {
            let v = try dyn.decode(String.self, forKey: key)
            let k = key.stringValue
            if let idx = seen[k] {
                out[idx] = Entry(key: k, value: v)
            } else {
                seen[k] = out.count
                out.append(Entry(key: k, value: v))
            }
        }
        self.entries = out
    }

    public func encode(to encoder: Encoder) throws {
        var dyn = encoder.container(keyedBy: AnyCodingKey.self)
        for e in entries {
            try dyn.encode(e.value, forKey: AnyCodingKey(stringValue: e.key))
        }
    }
}

// MARK: - Sentinel helpers

/// `true` when `s` is not a model-emitted placeholder (`""`, `"null"`,
/// `"none"`, `"undefined"`, or whitespace-only after trim).
///
/// Mirrors Rust `is_not_sentinel`.
public func isNotSentinel(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return false }
    if t.lowercased() == "null" { return false }
    if t.lowercased() == "none" { return false }
    if t.lowercased() == "undefined" { return false }
    return true
}

/// Drop sentinels and trim; return `nil` for sentinel/whitespace values.
///
/// Mirrors Rust `sanitize_optional_arg`.
public func sanitizeOptionalArg(_ value: String?) -> String? {
    guard let s = value else { return nil }
    if !isNotSentinel(s) { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed
}

// MARK: - TaskOutputToolInput (`get_task_output`)

/// Maximum number of task IDs accepted by a single multi-id
/// `get_task_output` (or legacy `wait_tasks`) call. Shared by the tool
/// schema, the server-side fan-out, and the toolbox wait path so the cap
/// cannot drift.
public let maxMultiWaitIds: Int = 20

/// Input for the `get_task_output` tool.
///
/// Mirrors Rust `TaskOutputToolInput`.
public struct TaskOutputToolInput: Codable, Sendable, Hashable, Defaultable {
    public var taskIds: [String]
    public var timeoutMs: UInt64?

    private enum CodingKeys: String, CodingKey {
        case taskIds = "task_ids"
        case timeoutMs = "timeout_ms"
    }

    public init(taskIds: [String] = [], timeoutMs: UInt64? = nil) {
        self.taskIds = taskIds
        self.timeoutMs = timeoutMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskIds = try c.decodeIfPresent([String].self, forKey: .taskIds) ?? []
        self.timeoutMs = try c.decodeIfPresent(UInt64.self, forKey: .timeoutMs)
    }

    public static var defaultValue: TaskOutputToolInput { TaskOutputToolInput() }

    /// Resolved, de-duplicated task IDs preserving first-seen order.
    public func resolvedTaskIds() -> [String] {
        resolveTaskIds(taskIds)
    }

    /// `true` only when `timeoutMs` is set and greater than zero.
    public func waits() -> Bool {
        taskOutputWaits(timeoutMs)
    }
}

/// Trimmed, de-duplicated task IDs preserving first-seen order. Single
/// source of truth for how `task_ids` args resolve.
///
/// Mirrors Rust `resolve_task_ids`.
public func resolveTaskIds(_ ids: [String]) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    for id in ids {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && seen.insert(trimmed).inserted {
            out.append(trimmed)
        }
    }
    return out
}

/// Whether `get_task_output` should wait, from optional `timeout_ms`.
/// Positive `timeout_ms` waits; omit or `0` polls without blocking.
///
/// Mirrors Rust `task_output_waits`.
public func taskOutputWaits(_ timeoutMs: UInt64?) -> Bool {
    timeoutMs.map { $0 > 0 } ?? false
}

/// Same as `taskOutputWaits`, from raw tool-arg JSON (fingerprint /
/// doom-loop). Mirrors Rust `task_output_waits_from_json`.
public func taskOutputWaitsFromJSON(_ args: JSONValue) -> Bool {
    guard let timeoutVal = args["timeout_ms"] else { return false }
    let ms: UInt64?
    switch timeoutVal {
    case .number(let n):
        ms = n.uint64Value
    default:
        ms = nil
    }
    return taskOutputWaits(ms)
}

// MARK: - TaskOutputOutput

/// Output from the `get_task_output` tool.
///
/// Mirrors Rust `TaskOutputOutput`. Serializes as an internally-tagged
/// enum on `kind` with `snake_case` variant names, matching Rust's
/// `#[serde(...)]` (Rust uses untagged here but each variant is a struct
/// with a distinct shape; the Swift port uses an explicit tag for
/// forward-compat and to match the model-facing wire shape).
public enum TaskOutputOutput: Codable, Sendable, Hashable {
    case result(TaskOutputResult)
    case taskNotFound(String)
    case multiResult(MultiTaskOutputResult)

    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable {
        case result = "Result"
        case taskNotFound = "TaskNotFound"
        case multiResult = "MultiResult"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .result:
            self = .result(try TaskOutputResult(from: decoder))
        case .taskNotFound:
            // TaskNotFound carries a bare String in Rust; we wrap it.
            let s = try decoder.singleValueContainer().decode(String.self)
            self = .taskNotFound(s)
        case .multiResult:
            self = .multiResult(try MultiTaskOutputResult(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .result(let r):
            try c.encode(Kind.result, forKey: .kind)
            try r.encode(to: encoder)
        case .taskNotFound(let s):
            try c.encode(Kind.taskNotFound, forKey: .kind)
            var single = encoder.singleValueContainer()
            try single.encode(s)
        case .multiResult(let m):
            try c.encode(Kind.multiResult, forKey: .kind)
            try m.encode(to: encoder)
        }
    }

    /// `true` for terminal states (the multi-result is always terminal;
    /// `Result` depends on `status`; `TaskNotFound` is not terminal).
    public var isTerminal: Bool {
        switch self {
        case .result(let r): return r.isTerminal
        case .taskNotFound: return false
        case .multiResult: return true
        }
    }
}

/// Successful result from the `get_task_output` tool.
///
/// Mirrors Rust `TaskOutputResult`.
public struct TaskOutputResult: Codable, Sendable, Hashable, Defaultable {
    public var taskId: String
    public var command: String
    public var status: String
    public var exitCode: Int32?
    public var started: String
    public var ended: String?
    public var durationSecs: Double
    public var output: String
    public var outputFile: String
    public var truncated: Bool
    public var truncationHint: String
    public var rawOutputBytes: Int

    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case command
        case status
        case exitCode = "exit_code"
        case started
        case ended
        case durationSecs = "duration_secs"
        case output
        case outputFile = "output_file"
        case truncated
        case truncationHint = "truncation_hint"
        case rawOutputBytes = "raw_output_bytes"
    }

    public init(
        taskId: String = "",
        command: String = "",
        status: String = "",
        exitCode: Int32? = nil,
        started: String = "",
        ended: String? = nil,
        durationSecs: Double = 0,
        output: String = "",
        outputFile: String = "",
        truncated: Bool = false,
        truncationHint: String = "",
        rawOutputBytes: Int = 0
    ) {
        self.taskId = taskId
        self.command = command
        self.status = status
        self.exitCode = exitCode
        self.started = started
        self.ended = ended
        self.durationSecs = durationSecs
        self.output = output
        self.outputFile = outputFile
        self.truncated = truncated
        self.truncationHint = truncationHint
        self.rawOutputBytes = rawOutputBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = try c.decode(String.self, forKey: .taskId)
        self.command = try c.decode(String.self, forKey: .command)
        self.status = try c.decode(String.self, forKey: .status)
        self.exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        self.started = try c.decode(String.self, forKey: .started)
        self.ended = try c.decodeIfPresent(String.self, forKey: .ended)
        self.durationSecs = try c.decode(Double.self, forKey: .durationSecs)
        self.output = try c.decode(String.self, forKey: .output)
        self.outputFile = try c.decode(String.self, forKey: .outputFile)
        self.truncated = try c.decode(Bool.self, forKey: .truncated)
        self.truncationHint = try c.decodeIfPresent(String.self, forKey: .truncationHint) ?? ""
        self.rawOutputBytes = try c.decodeIfPresent(Int.self, forKey: .rawOutputBytes) ?? 0
    }

    public static var defaultValue: TaskOutputResult { TaskOutputResult() }

    /// `true` for terminal statuses (`completed`, `failed`, `cancelled`).
    public var isTerminal: Bool {
        switch status {
        case "completed", "failed", "cancelled": return true
        default: return false
        }
    }

    /// Compute a progress signature from the semantically meaningful
    /// output fields. Two results with the same signature are considered
    /// stagnant. Used by the doom-loop detector.
    ///
    /// Mirrors Rust `TaskOutputResult::progress_signature`.
    public func progressSignature() -> UInt64 {
        var hasher = Hasher()
        hasher.combine(status)
        hasher.combine(exitCode)
        hasher.combine(ended != nil)
        hasher.combine(rawOutputBytes)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

/// Result from a multi-wait `get_task_output` / `wait_tasks` call.
///
/// Mirrors Rust `MultiTaskOutputResult`.
public struct MultiTaskOutputResult: Codable, Sendable, Hashable {
    public var mode: String
    public var results: [TaskOutputResult]
    public var summary: String

    private enum CodingKeys: String, CodingKey {
        case mode, results, summary
    }

    public init(mode: String = "", results: [TaskOutputResult] = [], summary: String = "") {
        self.mode = mode
        self.results = results
        self.summary = summary
    }
}

// MARK: - WaitTasksToolInput

/// How a multi-wait (`wait_tasks`) request should resolve.
///
/// Mirrors Rust `WaitMode`. Wire form is snake_case.
public enum WaitMode: String, Codable, Sendable, Hashable {
    case waitAny = "wait_any"
    case waitAll = "wait_all"
}

/// Input for the `wait_tasks` tool — blocks until multiple background
/// tasks / sub-agents reach a terminal state.
///
/// Mirrors Rust `WaitTasksToolInput`.
public struct WaitTasksToolInput: Codable, Sendable, Hashable {
    public var taskIds: [String]
    public var mode: WaitMode
    public var timeoutMs: UInt64?

    private enum CodingKeys: String, CodingKey {
        case taskIds = "task_ids"
        case mode
        case timeoutMs = "timeout_ms"
    }

    public init(taskIds: [String], mode: WaitMode, timeoutMs: UInt64? = nil) {
        self.taskIds = taskIds
        self.mode = mode
        self.timeoutMs = timeoutMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskIds = try c.decode([String].self, forKey: .taskIds)
        self.mode = try c.decode(WaitMode.self, forKey: .mode)
        self.timeoutMs = try c.decodeIfPresent(UInt64.self, forKey: .timeoutMs)
    }
}

// MARK: - KillTaskToolInput / KillTaskOutput

/// Input for the `kill_task` tool — terminates a running background task,
/// monitor, or subagent by id.
///
/// Mirrors Rust `KillTaskToolInput`.
public struct KillTaskToolInput: Codable, Sendable, Hashable {
    public var taskId: String

    private enum CodingKeys: String, CodingKey { case taskId = "task_id" }

    public init(taskId: String) {
        self.taskId = taskId
    }
}

/// Successful result from the `kill_task` tool.
///
/// Mirrors Rust `KillTaskResult`.
public struct KillTaskResult: Codable, Sendable, Hashable {
    public var taskId: String
    public var outcome: String
    public var message: String

    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case outcome
        case message
    }

    public init(taskId: String, outcome: String, message: String) {
        self.taskId = taskId
        self.outcome = outcome
        self.message = message
    }
}

/// Output from the `kill_task` tool.
///
/// Mirrors Rust `KillTaskOutput`.
public enum KillTaskOutput: Codable, Sendable, Hashable {
    case result(KillTaskResult)
    case taskNotFound(String)

    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable {
        case result = "Result"
        case taskNotFound = "TaskNotFound"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .result:
            self = .result(try KillTaskResult(from: decoder))
        case .taskNotFound:
            let s = try decoder.singleValueContainer().decode(String.self)
            self = .taskNotFound(s)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .result(let r):
            try c.encode(Kind.result, forKey: .kind)
            try r.encode(to: encoder)
        case .taskNotFound(let s):
            try c.encode(Kind.taskNotFound, forKey: .kind)
            var single = encoder.singleValueContainer()
            try single.encode(s)
        }
    }

    /// `true` when the kill actually killed a task (vs. already exited).
    public var wasKilled: Bool {
        if case .result(let r) = self, r.outcome == "killed" {
            return true
        }
        return false
    }
}

// MARK: - SubagentCompletedOutput

/// Structured completion output from a subagent (`task` tool).
///
/// Mirrors Rust `SubagentCompletedOutput`.
public struct SubagentCompletedOutput: Codable, Sendable, Hashable {
    public var output: String
    public var subagentId: String
    public var subagentType: String
    public var toolCalls: UInt32
    public var turns: UInt32
    public var durationMs: UInt64
    public var worktreePath: String?
    public var persona: String?
    public var resumeFromHint: String
    public var personaHint: String?

    private enum CodingKeys: String, CodingKey {
        case output
        case subagentId = "subagent_id"
        case subagentType = "subagent_type"
        case toolCalls = "tool_calls"
        case turns
        case durationMs = "duration_ms"
        case worktreePath = "worktree_path"
        case persona
        case resumeFromHint = "resume_from_hint"
        case personaHint = "persona_hint"
    }

    public init(
        output: String,
        subagentId: String,
        subagentType: String,
        toolCalls: UInt32,
        turns: UInt32,
        durationMs: UInt64,
        worktreePath: String? = nil,
        persona: String? = nil,
        resumeFromHint: String? = nil,
        personaHint: String? = nil
    ) {
        self.output = output
        self.subagentId = subagentId
        self.subagentType = subagentType
        self.toolCalls = toolCalls
        self.turns = turns
        self.durationMs = durationMs
        self.worktreePath = worktreePath
        self.persona = persona
        self.resumeFromHint = resumeFromHint ?? subagentId
        self.personaHint = personaHint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.output = try c.decode(String.self, forKey: .output)
        self.subagentId = try c.decode(String.self, forKey: .subagentId)
        self.subagentType = try c.decode(String.self, forKey: .subagentType)
        self.toolCalls = try c.decode(UInt32.self, forKey: .toolCalls)
        self.turns = try c.decode(UInt32.self, forKey: .turns)
        self.durationMs = try c.decode(UInt64.self, forKey: .durationMs)
        self.worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        self.persona = try c.decodeIfPresent(String.self, forKey: .persona)
        self.resumeFromHint = try c.decodeIfPresent(String.self, forKey: .resumeFromHint) ?? subagentId
        self.personaHint = try c.decodeIfPresent(String.self, forKey: .personaHint)
    }

    /// Render the resume footer showing the subagent ID and resume hint.
    public func resumeFooter() -> String {
        formatResumeFooter(subagentId: subagentId, subagentType: subagentType, persona: persona)
    }

    /// Render the full model-facing completion block.
    public func toModelText() -> String {
        formatSubagentCompleted(
            output: output,
            subagentId: subagentId,
            subagentType: subagentType,
            toolCalls: toolCalls,
            turns: turns,
            durationMs: durationMs,
            persona: persona
        )
    }
}

// MARK: - SubagentDescriptor

/// One entry in the dynamic `task` tool description: a subagent type the
/// model may launch, with a human-readable summary and an optional
/// fragment listing the tools that agent can use.
///
/// Mirrors Rust `SubagentDescriptor`.
public struct SubagentDescriptor: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var tools: String?

    public init(name: String, description: String, tools: String? = nil) {
        self.name = name
        self.description = description
        self.tools = tools
    }
}

// MARK: - BuiltinSubagent

/// A built-in subagent type shared by the CLI (`xai-grok-agent`) and other
/// agent hosts: its `subagent_type` name, canonical model-facing
/// description, tool-access fragment, and type-specific prompt body.
///
/// Mirrors Rust `BuiltinSubagent`. The prompt bodies are verbatim copies
/// of the Rust constants so the model-facing text is byte-identical.
public struct BuiltinSubagent: Sendable, Hashable {
    public let name: String
    public let description: String
    public let toolsTemplate: String
    public let promptTemplate: String

    public init(name: String, description: String, toolsTemplate: String, promptTemplate: String) {
        self.name = name
        self.description = description
        self.toolsTemplate = toolsTemplate
        self.promptTemplate = promptTemplate
    }

    /// Render the tool-access fragment, substituting each
    /// `${{ tools.by_kind.* }}` placeholder with the matching name from
    /// `naming`. Kinds the naming doesn't cover fall back to the bare
    /// kind name, so a partial map still renders.
    public func renderTools(_ naming: SubagentToolNaming) -> String {
        substituteToolPlaceholders(toolsTemplate) { kind in
            naming.toolForKind(kind)
        }
    }

    /// Build a `SubagentDescriptor`, rendering the tool-access fragment
    /// via `renderTools(_:)` with the supplied `naming`.
    public func toDescriptor(_ naming: SubagentToolNaming) -> SubagentDescriptor {
        SubagentDescriptor(
            name: name,
            description: description,
            tools: renderTools(naming)
        )
    }
}

/// The real tool names (by kind) substituted into the built-in subagents'
/// tool-access fragments when building the `task` description.
///
/// Mirrors Rust `SubagentToolNaming`.
public struct SubagentToolNaming: Sendable {
    public let execute: String
    public let read: String
    public let edit: String
    public let list: String
    public let search: String
    public let webSearch: String
    public let plan: String

    public init(execute: String, read: String, edit: String, list: String, search: String, webSearch: String, plan: String) {
        self.execute = execute
        self.read = read
        self.edit = edit
        self.list = list
        self.search = search
        self.webSearch = webSearch
        self.plan = plan
    }

    /// The tool name for a `${{ tools.by_kind.<kind> }}` placeholder, or
    /// `nil` for a kind this naming doesn't cover (the renderer then falls
    /// back to the bare kind name).
    public func toolForKind(_ kind: String) -> String? {
        switch kind {
        case "execute": return execute
        case "read": return read
        case "edit": return edit
        case "list": return list
        case "search": return search
        case "web_search": return webSearch
        case "plan": return plan
        default: return nil
        }
    }
}

/// Rewrite `${{ tools.by_kind.NAME }}` placeholders in a tool-access
/// fragment, substituting each with `resolve(NAME)` (the last dotted
/// segment) or the bare `NAME` when `resolve` returns `nil`. Non-
/// placeholder text is left intact and an unclosed `${{` is emitted
/// as-is.
///
/// Mirrors Rust `substitute_tool_placeholders`.
public func substituteToolPlaceholders(
    _ template: String,
    resolve: (String) -> String?
) -> String {
    var out = ""
    var rest = template[...]
    while let startRange = rest.range(of: "${{") {
        out += String(rest[..<startRange.lowerBound])
        let after = rest[startRange.upperBound...]
        if let endRange = after.range(of: "}}") {
            let expr = after[..<endRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            // Take the last dotted segment as the kind.
            let kind = expr.split(separator: ".").last.map(String.init) ?? String(expr)
            let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name = resolve(trimmedKind) {
                out += name
            } else {
                out += trimmedKind
            }
            rest = after[endRange.upperBound...]
        } else {
            // Unclosed `${{` — emit as-is.
            out += "${{"
            rest = after
        }
    }
    out += String(rest)
    return out
}

// MARK: - Built-in subagent catalog (verbatim prompt bodies)

/// Prompt body for the **general-purpose** subagent.
///
/// Verbatim copy of Rust `GENERAL_PURPOSE_PROMPT`.
public let generalPurposePrompt: String = """
Complete the assigned task directly. Do what was asked; nothing more, nothing less. \
Respond with a detailed writeup when done.

Strengths:
- Searching across large codebases for code, configurations, and patterns
- Multi-file analysis and architecture investigation
- Multi-step research requiring exploration of many files
Guidelines:${%- if tools.by_kind.search and tools.by_kind.list %}
- Use ${{ tools.by_kind.search }} or ${{ tools.by_kind.list }} for broad searches; ${{ tools.by_kind.read }} for known paths.${%- endif %}
- Start broad and narrow down. Try multiple search strategies.
- Be thorough: check multiple locations, consider different naming conventions.${%- if tools.by_kind.edit %}
- NEVER create files unless absolutely necessary. Prefer editing existing files.
- NEVER create documentation files (*.md) unless explicitly requested.${%- endif %}
- Return absolute file paths and relevant code snippets in your final response.

Workspace boundary:
- Default scope is the workspace in <user_info>. Stay within it unless told otherwise.
- Do not run whole-filesystem searches unless the user clearly requires it.
"""

/// Prompt body for the **explore** subagent.
///
/// Verbatim copy of Rust `EXPLORE_PROMPT`.
public let explorePrompt: String = """
You are a fast, read-only codebase exploration agent.

=== READ-ONLY MODE === \
You have NO file editing tools. Do not create, modify, or delete files.${%- if tools.by_kind.execute %} \
Use ${{ tools.by_kind.execute }} only for read-only commands \
(ls, git status, git log, git diff, find, cat, head, tail).${%- endif %}

Strengths:
- Rapidly finding files using glob patterns
- Searching code with regex patterns
- Reading and analyzing file contents

Guidelines:
- Use ${{ tools.by_kind.list }} for file pattern matching, ${{ tools.by_kind.search }} for content search, ${{ tools.by_kind.read }} for known paths.
- Adapt search approach based on the thoroughness level specified by the caller.
- Return absolute file paths in your final response.
- Maximize parallel tool calls for speed.

Workspace boundary:
- Your default search scope is the workspace in <user_info>. Do not search outside it unless asked.
- If not found in the workspace, report that rather than broadening scope.
"""

/// Prompt body for the **plan** subagent.
///
/// Verbatim copy of Rust `PLAN_PROMPT`.
public let planPrompt: String = """
You are a read-only software architect. Explore the codebase and design implementation plans.

=== READ-ONLY MODE === \
You have NO file editing tools. Do not create, modify, or delete files.${%- if tools.by_kind.execute %} \
Use ${{ tools.by_kind.execute }} only for read-only commands \
(ls, git status, git log, git diff, find, cat, head, tail).${%- endif %}

Process:
1. **Understand** the requirements and any assigned perspective.
2. **Explore**: read provided files, find patterns with ${{ tools.by_kind.list }}/${{ tools.by_kind.search }}/${{ tools.by_kind.read }}, trace relevant code paths.
3. **Design**: consider trade-offs, follow existing patterns, create implementation approach.
4. **Detail**: step-by-step strategy, dependencies, sequencing, potential challenges.

## Required Output

End your response with:

### Critical Files for Implementation
List 3-5 files most critical for implementing this plan:
- path/to/file1 - [Brief reason: e.g., \"Core logic to modify\"]
- path/to/file2 - [Brief reason: e.g., \"Interfaces to implement\"]
- path/to/file3 - [Brief reason: e.g., \"Pattern to follow\"]

Workspace boundary:
- Your default analysis scope is the workspace in <user_info>. Stay within it unless asked otherwise.
- Note explicitly if the design requires understanding external dependencies.
"""

/// The **general-purpose** built-in subagent.
public let generalPurposeSubagent = BuiltinSubagent(
    name: "general-purpose",
    description: "General purpose agent for multi-step tasks.",
    toolsTemplate: "Has access to all tools: " +
        "${{ tools.by_kind.execute }}, ${{ tools.by_kind.read }}, ${{ tools.by_kind.edit }}, " +
        "${{ tools.by_kind.list }}, ${{ tools.by_kind.search }}, ${{ tools.by_kind.web_search }}, " +
        "and ${{ tools.by_kind.plan }}.",
    promptTemplate: generalPurposePrompt
)

/// The **explore** built-in subagent.
public let exploreSubagent = BuiltinSubagent(
    name: "explore",
    description: "Fast, read-only agent specialized for codebase exploration.",
    toolsTemplate: "Read-only \u{2014} has access to: " +
        "${{ tools.by_kind.read }}, ${{ tools.by_kind.list }}, " +
        "${{ tools.by_kind.search }}.",
    promptTemplate: explorePrompt
)

/// The **plan** built-in subagent.
public let planSubagent = BuiltinSubagent(
    name: "plan",
    description: "Software architect for planning implementation strategies.",
    toolsTemplate: "Read-only \u{2014} has access to all tools except file editing " +
        "(${{ tools.by_kind.edit }} is not available): " +
        "${{ tools.by_kind.read }}, ${{ tools.by_kind.list }}, ${{ tools.by_kind.search }}, " +
        "${{ tools.by_kind.web_search }}, and ${{ tools.by_kind.plan }}.",
    promptTemplate: planPrompt
)

/// The built-in subagent types advertised to the model, in display order.
public let builtinSubagents: [BuiltinSubagent] = [
    generalPurposeSubagent,
    exploreSubagent,
    planSubagent,
]

/// Look up a built-in subagent by its `subagent_type` name
/// (e.g. `"explore"`), or `nil` for user-defined / unknown types.
public func builtinSubagentByName(_ name: String) -> BuiltinSubagent? {
    builtinSubagents.first { $0.name == name }
}

// MARK: - Format helpers

/// Render the model-facing notice for a subagent that was spawned in the
/// background and is still running.
///
/// Mirrors Rust `format_subagent_started_background`.
public func formatSubagentStartedBackground(
    subagentId: String,
    subagentType: String,
    description: String,
    taskOutputToolName: String
) -> String {
    """
    Subagent started in background.
    subagent_id: \(subagentId)
    type: \(subagentType)
    description: \(description)

    Use \(taskOutputToolName) with task_ids=[\"\(subagentId)\"] and timeout_ms to wait for results.
    """
}

/// Render the full model-facing completion block for a finished subagent.
///
/// Mirrors Rust `format_subagent_completed`.
public func formatSubagentCompleted(
    output: String,
    subagentId: String,
    subagentType: String,
    toolCalls: UInt32,
    turns: UInt32,
    durationMs: UInt64,
    persona: String?
) -> String {
    let footer = formatResumeFooter(
        subagentId: subagentId,
        subagentType: subagentType,
        persona: persona
    )
    return """
    \(output)

    <subagent_meta>id=\(subagentId), type=\(subagentType), \
    tool_calls=\(toolCalls), turns=\(turns), duration_ms=\(durationMs)</subagent_meta>

    \(footer)
    """
}

/// Render a resume footer from bare fields.
///
/// Mirrors Rust `format_resume_footer`.
public func formatResumeFooter(
    subagentId: String,
    subagentType: String,
    persona: String?
) -> String {
    var footer = """
    <subagent_result>
    subagent_id: \(subagentId)
    subagent_type: \(subagentType)
    To continue this subagent's conversation, use resume_from=\"\(subagentId)\".
    """
    if let persona = persona {
        footer += "\nThe subagent used persona=\"\(persona)\". Pass the same persona when resuming."
    }
    footer += "\n</subagent_result>"
    return footer
}

// MARK: - TaskToolNaming + description builders

/// Tool/parameter names (and optional features) that vary between products
/// when rendering the shared `task` tool description.
///
/// Mirrors Rust `TaskToolNaming`.
public struct TaskToolNaming: Sendable {
    public let taskTool: String
    public let subagentTypeParam: String
    public let runInBackgroundParam: String
    public let resumeFromParam: String
    public let backgroundRetrievalTool: String
    public let isolationParam: String

    public init(
        taskTool: String,
        subagentTypeParam: String,
        runInBackgroundParam: String,
        resumeFromParam: String,
        backgroundRetrievalTool: String,
        isolationParam: String
    ) {
        self.taskTool = taskTool
        self.subagentTypeParam = subagentTypeParam
        self.runInBackgroundParam = runInBackgroundParam
        self.resumeFromParam = resumeFromParam
        self.backgroundRetrievalTool = backgroundRetrievalTool
        self.isolationParam = isolationParam
    }
}

/// Build the `task` tool description from an effective subagent list.
///
/// Mirrors Rust `build_task_description`.
public func buildTaskDescription(
    subagents: [SubagentDescriptor],
    naming: TaskToolNaming
) -> String {
    let agentLines = subagents.map { s -> String in
        if let tools = s.tools {
            return "- **\(s.name)**: \(s.description) \(tools)"
        }
        return "- **\(s.name)**: \(s.description)"
    }.joined(separator: "\n")

    return """
    Start a subagent that works on a task independently and reports back.

    Agent types:

    \(agentLines)

    ## Usage notes
    - When the agent is done, it returns a single message with its agent ID. Use that ID to resume the agent later for follow-up work.
    - \(naming.runInBackgroundParam): Returns immediately with a subagent_id. Use \(naming.backgroundRetrievalTool) to retrieve results. This is set to true by default.
    - Subagents receive a compacted version of project instructions (AGENTS.md). If the task requires detailed conventions (e.g., build rules, testing patterns), include the relevant rules directly in the prompt.
    - When using the \(naming.taskTool) tool, you must specify a \(naming.subagentTypeParam) parameter to select which agent type to use.

    Resuming a previous agent (resume_from):
    - Use \(naming.resumeFromParam) to continue a previously completed subagent's conversation. Pass the subagent_id returned by a prior \(naming.taskTool) call. A resumed agent keeps its full transcript and tool state, so you only need to describe what changed since the last run — don't re-explain the original task.
    - The resumed agent must use the same subagent_type as the source.

    Isolation mode:
    - Use \(naming.isolationParam) to control the child's execution environment. With \"worktree\", the child runs in an isolated git worktree whose edits don't affect the parent workspace; the worktree is preserved after completion and its path is returned in the output.
    """
}

// MARK: - KillTaskToolNaming + build_kill_task_description

/// Naming/feature inputs for `buildKillTaskDescription(_:)`.
///
/// Mirrors Rust `KillTaskToolNaming`.
public struct KillTaskToolNaming: Sendable {
    public let monitorTool: String?
    public let subagentPresent: Bool
    public let bashPresent: Bool
    public let isWindows: Bool
    public let taskIdParam: String

    public init(
        monitorTool: String?,
        subagentPresent: Bool,
        bashPresent: Bool,
        isWindows: Bool,
        taskIdParam: String
    ) {
        self.monitorTool = monitorTool
        self.subagentPresent = subagentPresent
        self.bashPresent = bashPresent
        self.isWindows = isWindows
        self.taskIdParam = taskIdParam
    }
}

/// Shared `background task or subagent`-style target suffix used by the
/// `kill_task` / `get_task_output` opening line.
private func lifecycleTargetSuffix(monitorPresent: Bool, subagentPresent: Bool) -> String {
    switch (monitorPresent, subagentPresent) {
    case (true, true): return ", monitor, or subagent"
    case (true, false): return " or monitor"
    case (false, true): return " or subagent"
    case (false, false): return ""
    }
}

/// Optional "(a monitor's {id_name} is returned by {monitor})" clause.
private func monitorTaskIdNote(_ monitorTool: String?, _ idName: String) -> String {
    guard let m = monitorTool else { return "" }
    return " (a monitor's \(idName) is returned by \(m))"
}

/// Build the shared `kill_task` tool description.
///
/// Mirrors Rust `build_kill_task_description`.
public func buildKillTaskDescription(_ naming: KillTaskToolNaming) -> String {
    let monitorPresent = naming.monitorTool != nil
    let targetSuffix = lifecycleTargetSuffix(
        monitorPresent: monitorPresent,
        subagentPresent: naming.subagentPresent
    )
    let monitorNote = monitorTaskIdNote(naming.monitorTool, naming.taskIdParam)
    let verb = naming.isWindows ? "Terminates the Job Object of" : "Sends SIGTERM/SIGKILL to"

    let action: String
    if naming.bashPresent {
        var s = "\(verb) a bash task"
        if monitorPresent { s += " or monitor" }
        if naming.subagentPresent { s += "; sends Cancel+Shutdown to a subagent" }
        action = s
    } else if naming.subagentPresent {
        action = "Sends Cancel+Shutdown to a subagent"
    } else if monitorPresent {
        action = "\(verb) a monitor"
    } else {
        action = ""
    }

    return """
    Terminate a running background task\(targetSuffix).

    Usage notes:
    - Pass its \(naming.taskIdParam)\(monitorNote).
    - \(action).
    - Returns success if the task was killed or had already exited.
    """
}

// MARK: - TaskOutputToolNaming + build_task_output_description

/// Naming/feature inputs for `buildTaskOutputDescription(_:)`.
///
/// Mirrors Rust `TaskOutputToolNaming`.
public struct TaskOutputToolNaming: Sendable {
    public let monitorTool: String?
    public let readTool: String?
    public let bashBackgroundParam: String?
    public let subagentBackgroundParam: String?
    public let taskIdsParam: String
    public let timeoutMsParam: String
    public let taskIdParam: String

    public init(
        monitorTool: String?,
        readTool: String?,
        bashBackgroundParam: String?,
        subagentBackgroundParam: String?,
        taskIdsParam: String,
        timeoutMsParam: String,
        taskIdParam: String
    ) {
        self.monitorTool = monitorTool
        self.readTool = readTool
        self.bashBackgroundParam = bashBackgroundParam
        self.subagentBackgroundParam = subagentBackgroundParam
        self.taskIdsParam = taskIdsParam
        self.timeoutMsParam = timeoutMsParam
        self.taskIdParam = taskIdParam
    }
}

/// Build the shared `get_task_output` tool description.
///
/// Mirrors Rust `build_task_output_description`.
public func buildTaskOutputDescription(_ naming: TaskOutputToolNaming) -> String {
    let monitorPresent = naming.monitorTool != nil
    let subagentPresent = naming.subagentBackgroundParam != nil
    let targetSuffix = lifecycleTargetSuffix(
        monitorPresent: monitorPresent,
        subagentPresent: subagentPresent
    )

    var sources: [String] = []
    if let p = naming.bashBackgroundParam { sources.append("\(p)=true commands") }
    if let p = naming.subagentBackgroundParam { sources.append("\(p)=true subagents") }
    let sourcesStr = sources.joined(separator: " or ")

    let monitorNote = monitorTaskIdNote(naming.monitorTool, naming.taskIdParam)
    let readNote: String
    if let r = naming.readTool {
        readNote = "\n- If output is large, use \(r) on the output_file path"
    } else {
        readNote = ""
    }

    return """
    Get output and status from a background task\(targetSuffix).

    Usage notes:
    - Pass \(naming.taskIdsParam) with one or more ids from \(sourcesStr)\(monitorNote); for a single task use a one-element array. Multiple ids with a positive \(naming.timeoutMsParam) wait until all complete
    - Omit \(naming.timeoutMsParam) or pass 0 for a non-blocking status snapshot; set a positive \(naming.timeoutMsParam) to wait up to that many milliseconds, capped at ~10 min
    - Returns current output, status, and exit code if completed\(readNote)
    """
}

// MARK: - WaitTasksToolNaming + build_wait_tasks_description

/// Naming/feature inputs for `buildWaitTasksDescription(_:)`.
///
/// Mirrors Rust `WaitTasksToolNaming`.
public struct WaitTasksToolNaming: Sendable {
    public let backgroundRetrievalTool: String
    public let bashBackgroundParam: String?
    public let subagentBackgroundParam: String?

    public init(
        backgroundRetrievalTool: String,
        bashBackgroundParam: String?,
        subagentBackgroundParam: String?
    ) {
        self.backgroundRetrievalTool = backgroundRetrievalTool
        self.bashBackgroundParam = bashBackgroundParam
        self.subagentBackgroundParam = subagentBackgroundParam
    }
}

/// Build the shared `wait_tasks` tool description.
///
/// Mirrors Rust `build_wait_tasks_description`.
public func buildWaitTasksDescription(_ naming: WaitTasksToolNaming) -> String {
    var sources: [String] = []
    if let p = naming.bashBackgroundParam { sources.append("\(p)=true") }
    if let p = naming.subagentBackgroundParam { sources.append("\(p)=true") }
    let sourcesStr = sources.joined(separator: " or ")

    return """
    Wait for multiple background tasks or subagents to complete.

    Prefer \(naming.backgroundRetrievalTool) with task_ids and a positive timeout_ms. This tool is kept for compatibility.

    Usage notes:
    - task_ids: list of task IDs from \(sourcesStr)
    - mode: 'wait_all' or 'wait_any'
    - timeout_ms: optional max wait, default 30s, capped at ~10 min
    """
}
