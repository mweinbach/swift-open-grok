// Notification.swift
//
// Open Grok — Swift port of `xai-tool-runtime/src/notification.rs`.
//
// Typed notifications a running tool emits to subscribers. Internally
// tagged on `"type"` with PascalCase discriminators. Flattened base
// fields for bash variants match Rust `#[serde(flatten)]`.

import Foundation
import OpenGrokShared

// MARK: - Duration / SystemTime wire helpers

/// Serde-compatible Duration wire form: `{"secs":N,"nanos":M}`.
public struct WireDuration: Codable, Sendable, Hashable {
    public var secs: UInt64
    public var nanos: UInt32

    public init(secs: UInt64, nanos: UInt32 = 0) {
        self.secs = secs
        self.nanos = nanos
    }

    public init(seconds: Double) {
        let s = max(0, seconds)
        self.secs = UInt64(s)
        self.nanos = UInt32((s - Double(UInt64(s))) * 1_000_000_000)
    }

    public var asSeconds: Double {
        Double(secs) + Double(nanos) / 1_000_000_000
    }
}

/// Serde SystemTime wire form used by Rust: `{"secs_since_epoch":N,"nanos_since_epoch":M}`.
public struct WireSystemTime: Codable, Sendable, Hashable {
    public var secsSinceEpoch: UInt64
    public var nanosSinceEpoch: UInt32

    private enum CodingKeys: String, CodingKey {
        case secsSinceEpoch = "secs_since_epoch"
        case nanosSinceEpoch = "nanos_since_epoch"
    }

    public init(secsSinceEpoch: UInt64, nanosSinceEpoch: UInt32 = 0) {
        self.secsSinceEpoch = secsSinceEpoch
        self.nanosSinceEpoch = nanosSinceEpoch
    }
}

// MARK: - Bash

public struct BashNotificationBase: Codable, Sendable, Hashable {
    public var toolCallId: String
    public var command: String
    /// Captured output bytes. Wire form is a JSON array of integers (Rust `Vec<u8>`).
    public var output: Data
    public var totalBytes: Int
    public var truncated: Bool
    public var cwd: String

    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case command, output
        case totalBytes = "total_bytes"
        case truncated, cwd
    }

    public init(
        toolCallId: String,
        command: String,
        output: Data,
        totalBytes: Int,
        truncated: Bool,
        cwd: String
    ) {
        self.toolCallId = toolCallId
        self.command = command
        self.output = output
        self.totalBytes = totalBytes
        self.truncated = truncated
        self.cwd = cwd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.toolCallId = try c.decode(String.self, forKey: .toolCallId)
        self.command = try c.decode(String.self, forKey: .command)
        let bytes = try c.decode([UInt8].self, forKey: .output)
        self.output = Data(bytes)
        self.totalBytes = try c.decode(Int.self, forKey: .totalBytes)
        self.truncated = try c.decode(Bool.self, forKey: .truncated)
        self.cwd = try c.decode(String.self, forKey: .cwd)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolCallId, forKey: .toolCallId)
        try c.encode(command, forKey: .command)
        try c.encode([UInt8](output), forKey: .output)
        try c.encode(totalBytes, forKey: .totalBytes)
        try c.encode(truncated, forKey: .truncated)
        try c.encode(cwd, forKey: .cwd)
    }

    public var outputLossy: String {
        String(decoding: output, as: UTF8.self)
    }
}

public struct BashOutputChunk: Codable, Sendable, Hashable {
    public var base: BashNotificationBase
    public init(base: BashNotificationBase) { self.base = base }

    public init(from decoder: Decoder) throws {
        self.base = try BashNotificationBase(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
    }
}

public struct BashExecutionComplete: Codable, Sendable, Hashable {
    public var base: BashNotificationBase
    public var exitCode: Int?
    public var signal: String?

    private enum CodingKeys: String, CodingKey {
        case exitCode = "exit_code"
        case signal
    }

    public init(base: BashNotificationBase, exitCode: Int?, signal: String?) {
        self.base = base
        self.exitCode = exitCode
        self.signal = signal
    }

    public init(from decoder: Decoder) throws {
        self.base = try BashNotificationBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        self.signal = try c.decodeIfPresent(String.self, forKey: .signal)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(signal, forKey: .signal)
    }

    public var wasSignaled: Bool { signal != nil }
}

public struct BashExecutionTimeout: Codable, Sendable, Hashable {
    public var base: BashNotificationBase
    public var elapsed: WireDuration
    public var timeout: WireDuration

    public init(base: BashNotificationBase, elapsed: WireDuration, timeout: WireDuration) {
        self.base = base
        self.elapsed = elapsed
        self.timeout = timeout
    }

    private enum CodingKeys: String, CodingKey {
        case elapsed, timeout
    }

    public init(from decoder: Decoder) throws {
        self.base = try BashNotificationBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.elapsed = try c.decode(WireDuration.self, forKey: .elapsed)
        self.timeout = try c.decode(WireDuration.self, forKey: .timeout)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elapsed, forKey: .elapsed)
        try c.encode(timeout, forKey: .timeout)
    }
}

public struct BashExecutionBackgrounded: Codable, Sendable, Hashable {
    public var base: BashNotificationBase
    public var outputFile: String
    public var taskId: String

    private enum CodingKeys: String, CodingKey {
        case outputFile = "output_file"
        case taskId = "task_id"
    }

    public init(base: BashNotificationBase, outputFile: String, taskId: String) {
        self.base = base
        self.outputFile = outputFile
        self.taskId = taskId
    }

    public init(from decoder: Decoder) throws {
        self.base = try BashNotificationBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.outputFile = try c.decode(String.self, forKey: .outputFile)
        self.taskId = try c.decode(String.self, forKey: .taskId)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outputFile, forKey: .outputFile)
        try c.encode(taskId, forKey: .taskId)
    }
}

public struct BashExecutionFailed: Codable, Sendable, Hashable {
    public var toolCallId: String
    public var command: String
    public var cwd: String
    public var error: String

    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case command, cwd, error
    }

    public init(toolCallId: String, command: String, cwd: String, error: String) {
        self.toolCallId = toolCallId
        self.command = command
        self.cwd = cwd
        self.error = error
    }
}

// MARK: - File / plan / question

public struct FileWritten: Codable, Sendable, Hashable {
    public var toolCallId: String
    public var absolutePath: String
    public var content: String
    public var previousContent: String?
    public var isNewFile: Bool

    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case absolutePath = "absolute_path"
        case content
        case previousContent = "previous_content"
        case isNewFile = "is_new_file"
    }

    public init(
        toolCallId: String,
        absolutePath: String,
        content: String,
        previousContent: String? = nil,
        isNewFile: Bool
    ) {
        self.toolCallId = toolCallId
        self.absolutePath = absolutePath
        self.content = content
        self.previousContent = previousContent
        self.isNewFile = isNewFile
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolCallId, forKey: .toolCallId)
        try c.encode(absolutePath, forKey: .absolutePath)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(previousContent, forKey: .previousContent)
        try c.encode(isNewFile, forKey: .isNewFile)
    }
}

public struct PlanModeEntered: Codable, Sendable, Hashable {
    public var toolCallId: String
    private enum CodingKeys: String, CodingKey { case toolCallId = "tool_call_id" }
    public init(toolCallId: String) { self.toolCallId = toolCallId }
}

public struct PlanModeExited: Codable, Sendable, Hashable {
    public var toolCallId: String
    public var planContent: String?
    public var planFilePath: String
    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case planContent = "plan_content"
        case planFilePath = "plan_file_path"
    }
    public init(toolCallId: String, planContent: String? = nil, planFilePath: String) {
        self.toolCallId = toolCallId
        self.planContent = planContent
        self.planFilePath = planFilePath
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolCallId, forKey: .toolCallId)
        try c.encodeIfPresent(planContent, forKey: .planContent)
        try c.encode(planFilePath, forKey: .planFilePath)
    }
}

public struct UserQuestionAsked: Codable, Sendable, Hashable {
    public var toolCallId: String
    public var questionsJson: JSONValue
    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case questionsJson = "questions_json"
    }
    public init(toolCallId: String, questionsJson: JSONValue) {
        self.toolCallId = toolCallId
        self.questionsJson = questionsJson
    }
}

// MARK: - LSP

public struct LspServerStarting: Codable, Sendable, Hashable {
    public var serverName: String
    public var command: String
    private enum CodingKeys: String, CodingKey {
        case serverName = "server_name"
        case command
    }
    public init(serverName: String, command: String) {
        self.serverName = serverName
        self.command = command
    }
}

public struct LspServerReady: Codable, Sendable, Hashable {
    public var serverName: String
    private enum CodingKeys: String, CodingKey { case serverName = "server_name" }
    public init(serverName: String) { self.serverName = serverName }
}

public struct LspServerCrashed: Codable, Sendable, Hashable {
    public var serverName: String
    private enum CodingKeys: String, CodingKey { case serverName = "server_name" }
    public init(serverName: String) { self.serverName = serverName }
}

public struct LspServerRetrying: Codable, Sendable, Hashable {
    public var serverName: String
    public var attempt: UInt32
    public var maxRestarts: UInt32
    public var backoffMs: UInt64
    private enum CodingKeys: String, CodingKey {
        case serverName = "server_name"
        case attempt
        case maxRestarts = "max_restarts"
        case backoffMs = "backoff_ms"
    }
    public init(serverName: String, attempt: UInt32, maxRestarts: UInt32, backoffMs: UInt64) {
        self.serverName = serverName
        self.attempt = attempt
        self.maxRestarts = maxRestarts
        self.backoffMs = backoffMs
    }
}

public struct LspServerFailed: Codable, Sendable, Hashable {
    public var serverName: String
    public var error: String
    public var attempts: UInt32
    private enum CodingKeys: String, CodingKey {
        case serverName = "server_name"
        case error, attempts
    }
    public init(serverName: String, error: String, attempts: UInt32) {
        self.serverName = serverName
        self.error = error
        self.attempts = attempts
    }
}

// MARK: - Scheduler / monitor / task

public struct ScheduledTaskFired: Codable, Sendable, Hashable {
    public var taskId: String
    public var prompt: String
    public var humanSchedule: String
    public var nextFireAt: String?
    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case prompt
        case humanSchedule = "human_schedule"
        case nextFireAt = "next_fire_at"
    }
    public init(taskId: String, prompt: String, humanSchedule: String, nextFireAt: String? = nil) {
        self.taskId = taskId
        self.prompt = prompt
        self.humanSchedule = humanSchedule
        self.nextFireAt = nextFireAt
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(humanSchedule, forKey: .humanSchedule)
        try c.encodeIfPresent(nextFireAt, forKey: .nextFireAt)
    }
}

public struct ScheduledTaskRemoved: Codable, Sendable, Hashable {
    public var taskId: String
    private enum CodingKeys: String, CodingKey { case taskId = "task_id" }
    public init(taskId: String) { self.taskId = taskId }
}

public struct ScheduledTaskCreated: Codable, Sendable, Hashable {
    public var taskId: String
    public var prompt: String
    public var humanSchedule: String
    public var nextFireAt: String?
    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case prompt
        case humanSchedule = "human_schedule"
        case nextFireAt = "next_fire_at"
    }
    public init(taskId: String, prompt: String, humanSchedule: String, nextFireAt: String? = nil) {
        self.taskId = taskId
        self.prompt = prompt
        self.humanSchedule = humanSchedule
        self.nextFireAt = nextFireAt
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(humanSchedule, forKey: .humanSchedule)
        try c.encodeIfPresent(nextFireAt, forKey: .nextFireAt)
    }
}

public struct MonitorEvent: Codable, Sendable, Hashable {
    public var taskId: String
    public var description: String
    public var eventText: String
    public var rawText: String
    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case description
        case eventText = "event_text"
        case rawText = "raw_text"
    }
    public init(taskId: String, description: String, eventText: String, rawText: String) {
        self.taskId = taskId
        self.description = description
        self.eventText = eventText
        self.rawText = rawText
    }
}

public enum TaskKind: String, Codable, Sendable, Hashable {
    case bash
    case monitor
}

public struct TaskSnapshot: Codable, Sendable, Hashable {
    public var taskId: String
    public var command: String
    public var displayCommand: String?
    public var cwd: String
    public var startTime: WireSystemTime
    public var endTime: WireSystemTime?
    public var output: String
    public var outputFile: String
    public var truncated: Bool
    public var exitCode: Int?
    public var signal: String?
    public var completed: Bool
    public var kind: TaskKind

    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case command
        case displayCommand = "display_command"
        case cwd
        case startTime = "start_time"
        case endTime = "end_time"
        case output
        case outputFile = "output_file"
        case truncated
        case exitCode = "exit_code"
        case signal, completed, kind
    }

    public init(
        taskId: String,
        command: String,
        displayCommand: String? = nil,
        cwd: String,
        startTime: WireSystemTime,
        endTime: WireSystemTime? = nil,
        output: String,
        outputFile: String,
        truncated: Bool,
        exitCode: Int? = nil,
        signal: String? = nil,
        completed: Bool,
        kind: TaskKind = .bash
    ) {
        self.taskId = taskId
        self.command = command
        self.displayCommand = displayCommand
        self.cwd = cwd
        self.startTime = startTime
        self.endTime = endTime
        self.output = output
        self.outputFile = outputFile
        self.truncated = truncated
        self.exitCode = exitCode
        self.signal = signal
        self.completed = completed
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = try c.decode(String.self, forKey: .taskId)
        self.command = try c.decode(String.self, forKey: .command)
        self.displayCommand = try c.decodeIfPresent(String.self, forKey: .displayCommand)
        self.cwd = try c.decode(String.self, forKey: .cwd)
        self.startTime = try c.decode(WireSystemTime.self, forKey: .startTime)
        self.endTime = try c.decodeIfPresent(WireSystemTime.self, forKey: .endTime)
        self.output = try c.decode(String.self, forKey: .output)
        self.outputFile = try c.decode(String.self, forKey: .outputFile)
        self.truncated = try c.decode(Bool.self, forKey: .truncated)
        self.exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        self.signal = try c.decodeIfPresent(String.self, forKey: .signal)
        self.completed = try c.decode(Bool.self, forKey: .completed)
        self.kind = try c.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .bash
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(command, forKey: .command)
        try c.encodeIfPresent(displayCommand, forKey: .displayCommand)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(startTime, forKey: .startTime)
        try c.encodeIfPresent(endTime, forKey: .endTime)
        try c.encode(output, forKey: .output)
        try c.encode(outputFile, forKey: .outputFile)
        try c.encode(truncated, forKey: .truncated)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(signal, forKey: .signal)
        try c.encode(completed, forKey: .completed)
        try c.encode(kind, forKey: .kind)
    }

    public func durationSecs(nowSecs: UInt64? = nil) -> Double {
        let end = endTime?.secsSinceEpoch ?? nowSecs ?? UInt64(Date().timeIntervalSince1970)
        if end < startTime.secsSinceEpoch { return 0 }
        return Double(end - startTime.secsSinceEpoch)
    }
}

// MARK: - ToolNotification enum

/// A typed notification a tool emits during or after execution.
///
/// Internally tagged on `"type"` with PascalCase discriminators.
public enum ToolNotification: Codable, Sendable, Hashable {
    case bashOutputChunk(BashOutputChunk)
    case bashExecutionComplete(BashExecutionComplete)
    case bashExecutionTimeout(BashExecutionTimeout)
    case bashExecutionBackgrounded(BashExecutionBackgrounded)
    case bashExecutionFailed(BashExecutionFailed)
    case fileWritten(FileWritten)
    case taskCompleted(TaskSnapshot)
    case planModeEntered(PlanModeEntered)
    case planModeExited(PlanModeExited)
    case userQuestionAsked(UserQuestionAsked)
    case lspServerStarting(LspServerStarting)
    case lspServerReady(LspServerReady)
    case lspServerCrashed(LspServerCrashed)
    case lspServerRetrying(LspServerRetrying)
    case lspServerFailed(LspServerFailed)
    case scheduledTaskFired(ScheduledTaskFired)
    case scheduledTaskRemoved(ScheduledTaskRemoved)
    case scheduledTaskCreated(ScheduledTaskCreated)
    case monitorEvent(MonitorEvent)

    public var variantName: String {
        switch self {
        case .bashOutputChunk: return "BashOutputChunk"
        case .bashExecutionComplete: return "BashExecutionComplete"
        case .bashExecutionTimeout: return "BashExecutionTimeout"
        case .bashExecutionBackgrounded: return "BashExecutionBackgrounded"
        case .bashExecutionFailed: return "BashExecutionFailed"
        case .fileWritten: return "FileWritten"
        case .taskCompleted: return "TaskCompleted"
        case .planModeEntered: return "PlanModeEntered"
        case .planModeExited: return "PlanModeExited"
        case .userQuestionAsked: return "UserQuestionAsked"
        case .lspServerStarting: return "LspServerStarting"
        case .lspServerReady: return "LspServerReady"
        case .lspServerCrashed: return "LspServerCrashed"
        case .lspServerRetrying: return "LspServerRetrying"
        case .lspServerFailed: return "LspServerFailed"
        case .scheduledTaskFired: return "ScheduledTaskFired"
        case .scheduledTaskRemoved: return "ScheduledTaskRemoved"
        case .scheduledTaskCreated: return "ScheduledTaskCreated"
        case .monitorEvent: return "MonitorEvent"
        }
    }

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let typeC = try decoder.container(keyedBy: TypeKey.self)
        let type = try typeC.decode(String.self, forKey: .type)
        switch type {
        case "BashOutputChunk":
            self = .bashOutputChunk(try BashOutputChunk(from: decoder))
        case "BashExecutionComplete":
            self = .bashExecutionComplete(try BashExecutionComplete(from: decoder))
        case "BashExecutionTimeout":
            self = .bashExecutionTimeout(try BashExecutionTimeout(from: decoder))
        case "BashExecutionBackgrounded":
            self = .bashExecutionBackgrounded(try BashExecutionBackgrounded(from: decoder))
        case "BashExecutionFailed":
            self = .bashExecutionFailed(try BashExecutionFailed(from: decoder))
        case "FileWritten":
            self = .fileWritten(try FileWritten(from: decoder))
        case "TaskCompleted":
            self = .taskCompleted(try TaskSnapshot(from: decoder))
        case "PlanModeEntered":
            self = .planModeEntered(try PlanModeEntered(from: decoder))
        case "PlanModeExited":
            self = .planModeExited(try PlanModeExited(from: decoder))
        case "UserQuestionAsked":
            self = .userQuestionAsked(try UserQuestionAsked(from: decoder))
        case "LspServerStarting":
            self = .lspServerStarting(try LspServerStarting(from: decoder))
        case "LspServerReady":
            self = .lspServerReady(try LspServerReady(from: decoder))
        case "LspServerCrashed":
            self = .lspServerCrashed(try LspServerCrashed(from: decoder))
        case "LspServerRetrying":
            self = .lspServerRetrying(try LspServerRetrying(from: decoder))
        case "LspServerFailed":
            self = .lspServerFailed(try LspServerFailed(from: decoder))
        case "ScheduledTaskFired":
            self = .scheduledTaskFired(try ScheduledTaskFired(from: decoder))
        case "ScheduledTaskRemoved":
            self = .scheduledTaskRemoved(try ScheduledTaskRemoved(from: decoder))
        case "ScheduledTaskCreated":
            self = .scheduledTaskCreated(try ScheduledTaskCreated(from: decoder))
        case "MonitorEvent":
            self = .monitorEvent(try MonitorEvent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: typeC,
                debugDescription: "unknown ToolNotification type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Encode payload object then inject `type` key.
        let payload: JSONValue
        switch self {
        case .bashOutputChunk(let v): payload = try JSONValue.encode(v)
        case .bashExecutionComplete(let v): payload = try JSONValue.encode(v)
        case .bashExecutionTimeout(let v): payload = try JSONValue.encode(v)
        case .bashExecutionBackgrounded(let v): payload = try JSONValue.encode(v)
        case .bashExecutionFailed(let v): payload = try JSONValue.encode(v)
        case .fileWritten(let v): payload = try JSONValue.encode(v)
        case .taskCompleted(let v): payload = try JSONValue.encode(v)
        case .planModeEntered(let v): payload = try JSONValue.encode(v)
        case .planModeExited(let v): payload = try JSONValue.encode(v)
        case .userQuestionAsked(let v): payload = try JSONValue.encode(v)
        case .lspServerStarting(let v): payload = try JSONValue.encode(v)
        case .lspServerReady(let v): payload = try JSONValue.encode(v)
        case .lspServerCrashed(let v): payload = try JSONValue.encode(v)
        case .lspServerRetrying(let v): payload = try JSONValue.encode(v)
        case .lspServerFailed(let v): payload = try JSONValue.encode(v)
        case .scheduledTaskFired(let v): payload = try JSONValue.encode(v)
        case .scheduledTaskRemoved(let v): payload = try JSONValue.encode(v)
        case .scheduledTaskCreated(let v): payload = try JSONValue.encode(v)
        case .monitorEvent(let v): payload = try JSONValue.encode(v)
        }
        guard case .object(var obj) = payload else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "notification payload must be object")
            )
        }
        obj["type"] = .string(variantName)
        try JSONValue.object(obj).encode(to: encoder)
    }
}

// MARK: - Notification handle

/// Async notification fan-out handle. Tools push notifications; subscribers
/// consume via the stream. Cancellation closes the stream.
///
/// Subscription registration is synchronous with respect to the actor: after
/// `subscribe()` returns, the continuation is already registered, so an
/// immediately subsequent `send` cannot be lost.
public actor ToolNotificationHandle {
    private var continuations: [UUID: AsyncStream<ToolNotification>.Continuation] = [:]
    private var closed = false

    public init() {}

    /// Open a new subscriber stream.
    ///
    /// The subscriber is registered **before** this method returns, so
    /// notifications sent after the `await` completes are delivered.
    public func subscribe() -> AsyncStream<ToolNotification> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ToolNotification.self)
        if closed {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.remove(id) }
        }
        return stream
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    public func send(_ notification: ToolNotification) {
        guard !closed else { return }
        for cont in continuations.values {
            cont.yield(notification)
        }
    }

    public func close() {
        closed = true
        for cont in continuations.values {
            cont.finish()
        }
        continuations.removeAll()
    }

    // Convenience constructors kept in lockstep with variants.
    public func sendBashOutputChunk(_ v: BashOutputChunk) { send(.bashOutputChunk(v)) }
    public func sendBashExecutionComplete(_ v: BashExecutionComplete) { send(.bashExecutionComplete(v)) }
    public func sendBashExecutionTimeout(_ v: BashExecutionTimeout) { send(.bashExecutionTimeout(v)) }
    public func sendBashExecutionBackgrounded(_ v: BashExecutionBackgrounded) { send(.bashExecutionBackgrounded(v)) }
    public func sendBashExecutionFailed(_ v: BashExecutionFailed) { send(.bashExecutionFailed(v)) }
    public func sendFileWritten(_ v: FileWritten) { send(.fileWritten(v)) }
    public func sendTaskCompleted(_ v: TaskSnapshot) { send(.taskCompleted(v)) }
    public func sendPlanModeEntered(_ v: PlanModeEntered) { send(.planModeEntered(v)) }
    public func sendPlanModeExited(_ v: PlanModeExited) { send(.planModeExited(v)) }
    public func sendUserQuestionAsked(_ v: UserQuestionAsked) { send(.userQuestionAsked(v)) }
    public func sendLspServerStarting(_ v: LspServerStarting) { send(.lspServerStarting(v)) }
    public func sendLspServerReady(_ v: LspServerReady) { send(.lspServerReady(v)) }
    public func sendLspServerCrashed(_ v: LspServerCrashed) { send(.lspServerCrashed(v)) }
    public func sendLspServerRetrying(_ v: LspServerRetrying) { send(.lspServerRetrying(v)) }
    public func sendLspServerFailed(_ v: LspServerFailed) { send(.lspServerFailed(v)) }
    public func sendScheduledTaskFired(_ v: ScheduledTaskFired) { send(.scheduledTaskFired(v)) }
    public func sendScheduledTaskRemoved(_ v: ScheduledTaskRemoved) { send(.scheduledTaskRemoved(v)) }
    public func sendScheduledTaskCreated(_ v: ScheduledTaskCreated) { send(.scheduledTaskCreated(v)) }
    public func sendMonitorEvent(_ v: MonitorEvent) { send(.monitorEvent(v)) }
}
