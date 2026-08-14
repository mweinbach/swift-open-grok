// MonitorTool.swift
//
// Open Grok — Swift port of `xai-grok-tools/src/implementations/grok_build/monitor/`.
//
// Background monitor tool, line processor, and event XML formatting.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

// MARK: - Constants (`monitor/types.rs:1-27`)

/// Max characters per individual stdout line before truncation.
public let LINE_TRUNCATION_LIMIT: Int = 500

/// Max characters per batched event (multiple lines joined).
public let BATCH_TRUNCATION_LIMIT: Int = 3_000

/// Raw stdout buffer cap in bytes.
public let BUFFER_CAP_BYTES: Int = 1_048_576 // 1 MB

/// Debounce window for batching concurrent stdout lines (ms).
public let DEBOUNCE_MS: UInt64 = 200

/// Default monitor timeout (non-persistent). 10 hours.
public let DEFAULT_TIMEOUT_MS: UInt64 = 36_000_000

/// Maximum monitor timeout. 10 hours.
public let MAX_TIMEOUT_MS: UInt64 = 36_000_000

// MARK: - Monitor Error (`monitor/types.rs:81-85`)

public enum MonitorError: Error, Equatable, Sendable, CustomStringConvertible {
    case timeoutExceedsMax
    case invalidArguments(String)

    public var description: String {
        switch self {
        case .timeoutExceedsMax:
            return "persistent must be true when timeout_ms exceeds \(MAX_TIMEOUT_MS)ms"
        case .invalidArguments(let detail):
            return detail
        }
    }
}

// MARK: - Monitor Input & Output (`monitor/types.rs:33-77`)

public struct MonitorInput: Codable, Sendable, Hashable {
    /// Shell command or script. Each stdout line is an event; exit ends the watch.
    public var command: String
    /// Short human-readable description of what you are monitoring (shown in every notification).
    public var description: String
    /// Kill the monitor after this deadline (ms). Ignored when persistent is true.
    /// Default: 36000000 (10 hr). Max: 36000000 (10 hr).
    public var timeoutMs: UInt64?
    /// Run for the lifetime of the session (no timeout). Use for session-length watches.
    /// Stop with kill_command_or_subagent.
    public var persistent: Bool

    private enum CodingKeys: String, CodingKey {
        case command
        case description
        case timeoutMs = "timeout_ms"
        case timeoutMsCamel = "timeoutMs"
        case persistent
    }

    public init(
        command: String,
        description: String,
        timeoutMs: UInt64? = DEFAULT_TIMEOUT_MS,
        persistent: Bool = false
    ) {
        self.command = command
        self.description = description
        self.timeoutMs = timeoutMs
        self.persistent = persistent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""

        if let direct = try? container.decodeIfPresent(UInt64.self, forKey: .timeoutMs) {
            timeoutMs = direct
        } else if let camel = try? container.decodeIfPresent(UInt64.self, forKey: .timeoutMsCamel) {
            timeoutMs = camel
        } else if let jsonVal = try? container.decodeIfPresent(JSONValue.self, forKey: .timeoutMs) {
            timeoutMs = Self.decodeLenientUInt64(jsonVal)
        } else if let jsonValCamel = try? container.decodeIfPresent(JSONValue.self, forKey: .timeoutMsCamel) {
            timeoutMs = Self.decodeLenientUInt64(jsonValCamel)
        } else {
            timeoutMs = DEFAULT_TIMEOUT_MS
        }

        if let directBool = try? container.decodeIfPresent(Bool.self, forKey: .persistent) {
            persistent = directBool
        } else if let jsonVal = try? container.decodeIfPresent(JSONValue.self, forKey: .persistent) {
            persistent = Self.decodeLenientBool(jsonVal)
        } else {
            persistent = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
        try container.encode(persistent, forKey: .persistent)
    }

    /// Validate input constraints.
    public func validate() throws {
        if let timeout = timeoutMs, !persistent, timeout > MAX_TIMEOUT_MS {
            throw MonitorError.timeoutExceedsMax
        }
    }

    /// Resolved timeout in milliseconds (0 for persistent / no-deadline monitors).
    public func resolvedTimeoutMs() -> UInt64 {
        if persistent {
            return 0
        } else {
            return timeoutMs ?? DEFAULT_TIMEOUT_MS
        }
    }

    private static func decodeLenientUInt64(_ value: JSONValue) -> UInt64? {
        switch value {
        case .number(let n):
            return n.uint64Value
        case .string(let s):
            return UInt64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func decodeLenientBool(_ value: JSONValue) -> Bool {
        switch value {
        case .bool(let b):
            return b
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed == "true" || trimmed == "1" || trimmed == "yes"
        case .number(let n):
            return n.int64Value == 1 || n.uint64Value == 1
        default:
            return false
        }
    }
}

public struct MonitorOutput: Codable, Sendable, Hashable, ToolOutput {
    /// ID of the background monitor task (used with kill_command_or_subagent to cancel).
    public var taskId: String
    /// Timeout deadline in milliseconds. 0 when persistent.
    public var timeoutMs: UInt64
    /// Whether the monitor runs until kill_command_or_subagent or session end.
    public var persistent: Bool

    private enum CodingKeys: String, CodingKey {
        case taskId = "taskId"
        case taskIdSnake = "task_id"
        case timeoutMs = "timeoutMs"
        case timeoutMsSnake = "timeout_ms"
        case persistent
    }

    public init(taskId: String, timeoutMs: UInt64, persistent: Bool) {
        self.taskId = taskId
        self.timeoutMs = timeoutMs
        self.persistent = persistent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? container.decode(String.self, forKey: .taskId) {
            taskId = id
        } else {
            taskId = try container.decode(String.self, forKey: .taskIdSnake)
        }

        if let ms = try? container.decode(UInt64.self, forKey: .timeoutMs) {
            timeoutMs = ms
        } else {
            timeoutMs = try container.decode(UInt64.self, forKey: .timeoutMsSnake)
        }

        persistent = try container.decodeIfPresent(Bool.self, forKey: .persistent) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taskId, forKey: .taskId)
        try container.encode(timeoutMs, forKey: .timeoutMs)
        try container.encode(persistent, forKey: .persistent)
    }

    public func modelOutput() -> [ContentBlock] {
        let msg: String
        if persistent || timeoutMs == 0 {
            msg = "Monitor started (task \(taskId), persistent -- runs until kill_command_or_subagent or session end).\n"
                + "You will be notified on each event. Keep working -- do not poll or sleep.\n"
                + "Events may arrive while you are waiting for the user -- an event is not their reply."
        } else {
            msg = "Monitor started (task \(taskId), timeout \(timeoutMs)ms).\n"
                + "You will be notified on each event. Keep working -- do not poll or sleep.\n"
                + "Events may arrive while you are waiting for the user -- an event is not their reply."
        }
        return [.text(text: msg)]
    }
}

// MARK: - ANSI Stripping & Formatting Utilities (`monitor/event.rs`)

/// Strips ANSI escape codes from string.
public func stripAnsiSequences(_ text: String) -> String {
    let pattern = #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\].*?(?:\x07|\x1B\\))"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
}

/// Sanitize a model-supplied monitor description for embedding in the
/// `<monitor-event …>` attribute and in line labels: `"` would break the
/// attribute, and newlines would break the single-line opening-tag shape.
public func sanitizeMonitorDescription(_ description: String) -> String {
    description
        .replacingOccurrences(of: "\"", with: "'")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}

/// Wrap event text in XML tags for the LLM conversation.
public func wrapMonitorEvent(description: String, eventText: String, taskId: String) -> String {
    let sanitized = sanitizeMonitorDescription(description)
    return "<monitor-event description=\"\(sanitized)\" task_id=\"\(taskId)\">\n"
        + "\(eventText)\n"
        + "</monitor-event>"
}

// MARK: - Line Processor (`monitor/event.rs:4-72`)

/// Processes raw stdout chunks into complete lines.
///
/// Buffers partial lines, splits on `\n`, truncates individual lines at
/// `LINE_TRUNCATION_LIMIT` chars with `\u{2026} [truncated]`, and caps the internal buffer at `BUFFER_CAP_BYTES`.
public struct LineProcessor: Sendable {
    private var buffer: [UInt8] = []
    public let bufferCapBytes: Int

    public init(bufferCapBytes: Int = BUFFER_CAP_BYTES) {
        self.bufferCapBytes = bufferCapBytes
    }

    /// Push a raw stdout chunk. Returns any complete lines extracted.
    public mutating func push(_ chunk: [UInt8]) -> [String] {
        buffer.append(contentsOf: chunk)

        // Cap buffer at bufferCapBytes (keep the tail).
        if buffer.count > bufferCapBytes {
            buffer.removeFirst(buffer.count - bufferCapBytes)
        }

        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let raw = Array(buffer[...newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            let rawText = String(decoding: raw, as: UTF8.self)
            let stripped = stripAnsiSequences(rawText)
            let text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            lines.append(Self.truncateLine(text))
        }
        return lines
    }

    /// Push a raw Data chunk.
    public mutating func push(_ data: Data) -> [String] {
        push(Array(data))
    }

    /// Push a raw string chunk.
    public mutating func push(_ text: String) -> [String] {
        push(Array(text.utf8))
    }

    /// Flush any remaining partial line from the buffer.
    public mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let raw = buffer
        buffer = []
        let rawText = String(decoding: raw, as: UTF8.self)
        let stripped = stripAnsiSequences(rawText)
        let text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Self.truncateLine(text)
    }

    /// Truncate individual line exceeding character limit.
    public static func truncateLine(_ line: String, limit: Int = LINE_TRUNCATION_LIMIT) -> String {
        if line.count > limit {
            return String(line.prefix(limit)) + "\u{2026} [truncated]"
        }
        return line
    }

    /// Batch multiple lines into a single event string, truncating at `limit`.
    public static func batchLines(_ lines: [String], limit: Int = BATCH_TRUNCATION_LIMIT) -> String {
        let joined = lines.joined(separator: "\n")
        if joined.count > limit {
            return String(joined.prefix(limit)) + "\n\u{2026} [truncated]"
        }
        return joined
    }

    /// Sanitize monitor description.
    public static func sanitizeDescription(_ description: String) -> String {
        sanitizeMonitorDescription(description)
    }

    /// Wrap monitor event in XML tags.
    public static func wrapEvent(description: String, eventText: String, taskId: String) -> String {
        wrapMonitorEvent(description: description, eventText: eventText, taskId: taskId)
    }
}

// MARK: - Monitor Tool (`monitor/tool.rs`)

public struct MonitorTool: BlockingTool {
    public typealias Output = MonitorOutput
    public let runtime: ExecutionToolRuntime?

    public init(runtime: ExecutionToolRuntime? = nil) {
        self.runtime = runtime
    }

    public func id() -> ToolId { try! ToolId("monitor") }

    public func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command or script. Each stdout line is an event; exit ends the watch.")
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Short human-readable description of what you are monitoring (shown in every notification).")
                ]),
                "timeout_ms": .object([
                    "type": .string("integer"),
                    "description": .string("Kill the monitor after this deadline (ms). Default: 36000000 (10 hr). Max: 36000000 (10 hr).")
                ]),
                "persistent": .object([
                    "type": .string("boolean"),
                    "description": .string("Run for the lifetime of the session (no timeout). Stop with kill_command_or_subagent.")
                ])
            ]),
            "required": .array([.string("command"), .string("description")])
        ])
        return ToolDescription(
            name: "monitor",
            description: "Start a background monitor that streams events from a long-running script. Each stdout line is an event. Exit ends the watch."
        )
        .withKind("execute")
        .withArgumentsSchema(schema)
    }

    public func capabilities() -> ToolCapabilities {
        ToolCapabilities(
            streaming: nil,
            supportsCancel: true,
            isReadOnly: false,
            timeoutMs: MAX_TIMEOUT_MS,
            toolScope: .write
        )
    }

    public func run(ctx: ToolCallContext, args: JSONValue) async -> Result<MonitorOutput, ToolError> {
        do {
            let data = try JSONEncoder().encode(args)
            let input = try JSONDecoder().decode(MonitorInput.self, from: data)
            try input.validate()

            let taskId = ctx.callId.stringValue.isEmpty ? "monitor-\(UUID().uuidString.lowercased())" : ctx.callId.stringValue
            let resolvedTimeout = input.resolvedTimeoutMs()

            if let runtime {
                let execReq = ExecutionRequest(
                    command: input.command,
                    timeoutMilliseconds: resolvedTimeout == 0 ? executionBackgroundMaximumTimeoutMilliseconds : resolvedTimeout,
                    isBackground: true,
                    toolCallId: taskId,
                    description: "[monitor] \(input.description)"
                )
                let res = await runtime.execute(execReq)
                switch res {
                case .success(let output):
                    switch output {
                    case .background(let handle):
                        return .success(MonitorOutput(
                            taskId: handle.taskId,
                            timeoutMs: resolvedTimeout,
                            persistent: input.persistent || resolvedTimeout == 0
                        ))
                    case .foreground:
                        return .success(MonitorOutput(
                            taskId: taskId,
                            timeoutMs: resolvedTimeout,
                            persistent: input.persistent || resolvedTimeout == 0
                        ))
                    }
                case .failure(let err):
                    return .failure(err)
                }
            } else {
                return .success(MonitorOutput(
                    taskId: taskId,
                    timeoutMs: resolvedTimeout,
                    persistent: input.persistent || resolvedTimeout == 0
                ))
            }
        } catch let err as MonitorError {
            return .failure(.invalidArguments(err.description))
        } catch {
            return .failure(.invalidArguments("invalid monitor arguments: \(error)"))
        }
    }
}

public typealias RunMonitorTool = MonitorTool
