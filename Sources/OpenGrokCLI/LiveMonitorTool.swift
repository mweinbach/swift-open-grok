// LiveMonitorTool.swift
//
// The `monitor` tool — a background monitor that streams stdout lines from a
// long-running script as model-facing events. Port of
// `xai-grok-tools/src/implementations/grok_build/monitor/` at the pinned
// commit: `tool.rs` (dispatch + pipeline), `event.rs` (line processing and
// the `<monitor-event>` wrap), `rate_limiter.rs` (token bucket + suppression
// + auto-kill), `types.rs` (input/output shapes and constants).
//
// What it monitors: a REAL background shell process, started through the
// session's own `OpenGrokShellProcessExecution` with `kind: .monitor` — the
// same store `run_terminal_cmd` backgrounds into, so `/tasks` lists it,
// `get_command_or_subagent_output` reads it, and `kill_command_or_subagent`
// stops it, with no parallel bookkeeping to drift. Upstream is the same
// shape: `terminal.run_background(TaskKind::Monitor)` (tool.rs:113-138).
//
// Determinism: the pipeline's poll body is `tick(taskID:now:)` with an
// injected instant, and the rate limiter takes `now` on every decision —
// production wraps `tick` in a 200ms sleep loop, tests drive it directly
// with fixed clocks (the `fireDue(now:)` pattern; zero real sleeps in tests).

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokToolTypes

// MARK: - Constants (`monitor/types.rs:1-27`)

enum LiveMonitorLimits {
    /// Max characters per individual stdout line before truncation.
    static let lineTruncationLimit = 500
    /// Max characters per batched event (multiple lines joined).
    static let batchTruncationLimit = 3_000
    /// Raw stdout buffer cap in bytes.
    static let bufferCapBytes = 1_048_576
    /// Debounce window for batching concurrent stdout lines (ms).
    static let debounceMS: UInt64 = 200
    /// Token bucket capacity.
    static let rateLimitCapacity: UInt32 = 10
    /// Token bucket refill interval in milliseconds.
    static let rateLimitRefillMS: UInt64 = 2_000
    /// Auto-kill after this many ms of continuous rate-limit violations.
    static let autoKillThresholdMS: UInt64 = 30_000
    /// Default monitor timeout (non-persistent): 10 hours.
    static let defaultTimeoutMS: UInt64 = 36_000_000
    /// Maximum monitor timeout: 10 hours.
    static let maxTimeoutMS: UInt64 = 36_000_000
    /// Single-read cap when draining the output file (tool.rs:354).
    static let maxSingleReadBytes = 1_024 * 1_024
}

// MARK: - Line processing (`monitor/event.rs`)

/// Processes raw stdout chunks into complete lines: buffers partials, splits
/// on `\n` BYTES (upstream splits on `b'\n'` and lets `trim()` eat the `\r`
/// of a CRLF — the byte-level delimiter scan handles CRLF by construction),
/// truncates lines at 500 chars, caps the buffer at 1 MB keeping the tail.
struct LiveMonitorLineProcessor {
    private var buffer: [UInt8] = []

    mutating func push(_ chunk: [UInt8]) -> [String] {
        buffer.append(contentsOf: chunk)
        if buffer.count > LiveMonitorLimits.bufferCapBytes {
            buffer.removeFirst(buffer.count - LiveMonitorLimits.bufferCapBytes)
        }
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let raw = Array(buffer[...newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            let text = String(decoding: raw, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            lines.append(Self.truncateLine(text))
        }
        return lines
    }

    /// Flush any remaining partial line from the buffer.
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let raw = buffer
        buffer = []
        let text = String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Self.truncateLine(text)
    }

    /// `truncate_line` (event.rs:54-61): over 500 BYTES → cut at the largest
    /// scalar boundary at or below 500 (`floor_char_boundary`) + marker.
    static func truncateLine(_ line: String) -> String {
        guard line.utf8.count > LiveMonitorLimits.lineTruncationLimit else { return line }
        return floorCharBoundaryPrefix(line, byteLimit: LiveMonitorLimits.lineTruncationLimit)
            + "...(truncated)"
    }

    /// `batch_lines` (event.rs:64-72): join with `\n`, truncating at 3000
    /// bytes on a scalar boundary with a newline-prefixed marker.
    static func batchLines(_ lines: [String]) -> String {
        let joined = lines.joined(separator: "\n")
        guard joined.utf8.count > LiveMonitorLimits.batchTruncationLimit else { return joined }
        return floorCharBoundaryPrefix(joined, byteLimit: LiveMonitorLimits.batchTruncationLimit)
            + "\n...(truncated)"
    }

    /// The longest prefix whose UTF-8 length is at most `byteLimit`, cut on
    /// a scalar boundary — Rust's `floor_char_boundary` slice.
    static func floorCharBoundaryPrefix(_ s: String, byteLimit: Int) -> String {
        let scalars = s.unicodeScalars
        var bytes = 0
        var end = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let width: Int
            switch scalars[index].value {
            case ..<0x80: width = 1
            case ..<0x800: width = 2
            case ..<0x1_0000: width = 3
            default: width = 4
            }
            if bytes + width > byteLimit { break }
            bytes += width
            index = scalars.index(after: index)
            end = index
        }
        return String(String.UnicodeScalarView(scalars[scalars.startIndex..<end]))
    }
}

/// `sanitize_monitor_description` (event.rs:78-80): `"` would break the
/// attribute quoting and newlines the single-line opening-tag shape.
func sanitizeMonitorDescription(_ description: String) -> String {
    description
        .replacingOccurrences(of: "\"", with: "'")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}

/// `wrap_monitor_event` (event.rs:83-90). The Rust `format!` uses `\`-
/// continuations, so the wrapped body has no indentation.
func wrapMonitorEvent(description: String, eventText: String, taskID: String) -> String {
    let sanitized = sanitizeMonitorDescription(description)
    return "<monitor-event description=\"\(sanitized)\" task_id=\"\(taskID)\">\n"
        + "\(eventText)\n"
        + "</monitor-event>"
}

// MARK: - Rate limiting (`monitor/rate_limiter.rs`)

/// Token bucket: starts full, one token per event, refills 1 per interval.
/// The clock is the caller's `now` — upstream reads `Instant::now()` inline,
/// which is exactly what makes its own tests sleep; the injected instant is
/// the port's determinism seam.
struct LiveMonitorTokenBucket {
    private let capacity: UInt32
    private var tokens: UInt32
    private let refillInterval: TimeInterval
    private var lastRefill: Date

    init(capacity: UInt32, refillIntervalMS: UInt64, now: Date) {
        self.capacity = capacity
        self.tokens = capacity
        self.refillInterval = TimeInterval(refillIntervalMS) / 1_000
        self.lastRefill = now
    }

    mutating func tryConsume(now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(lastRefill)
        if elapsed > 0, refillInterval > 0 {
            let refills = UInt32(min(elapsed / refillInterval, Double(UInt32.max)))
            if refills > 0 {
                tokens = min(tokens &+ refills, capacity)
                lastRefill = lastRefill.addingTimeInterval(refillInterval * Double(refills))
            }
        }
        guard tokens > 0 else { return false }
        tokens -= 1
        return true
    }
}

/// Result of processing an event through the limiter (rate_limiter.rs:59-67).
enum LiveMonitorRateLimitOutcome: Equatable {
    case allowed(catchUpNotice: String?)
    case suppressed
    case autoKill(message: String)
}

/// Suppression counting and the 30s sustained-overload auto-kill
/// (rate_limiter.rs:69-143).
struct LiveMonitorSuppressionTracker {
    var suppressedCount: UInt64 = 0
    var lastSuppression: Date?
    var suppressionStart: Date?
    var killed = false
    var killToolName: String = ""

    mutating func process(tokenAvailable: Bool, now: Date) -> LiveMonitorRateLimitOutcome {
        if killed { return .suppressed }
        if tokenAvailable {
            var catchUp: String?
            if suppressedCount > 0 {
                let killName = killToolName.isEmpty ? "kill_command_or_subagent" : killToolName
                catchUp = "[\(suppressedCount) events suppressed -- output rate too high. "
                    + "Consider using \(killName) to restart this monitor "
                    + "with a more selective filter.]"
                suppressedCount = 0
                // Reset suppression start if the burst has subsided
                // (> 3x refill interval since last suppression).
                if let last = lastSuppression,
                   now.timeIntervalSince(last) > TimeInterval(LiveMonitorLimits.rateLimitRefillMS * 3) / 1_000 {
                    suppressionStart = nil
                }
            }
            return .allowed(catchUpNotice: catchUp)
        }
        suppressedCount += 1
        lastSuppression = now
        if suppressionStart == nil {
            suppressionStart = now
        }
        if let start = suppressionStart {
            let elapsed = now.timeIntervalSince(start)
            if elapsed > TimeInterval(LiveMonitorLimits.autoKillThresholdMS) / 1_000 {
                killed = true
                let secs = UInt64(max(0, elapsed))
                return .autoKill(message:
                    "[Monitor stopped -- your script produced too much output "
                    + "(\(suppressedCount) events suppressed over \(secs)s). "
                    + "Write a new monitor command that filters more aggressively -- "
                    + "pipe through grep --line-buffered, awk, or a wrapper script "
                    + "that only emits the specific events you need.]"
                )
            }
        }
        return .suppressed
    }
}

/// Combined limiter (rate_limiter.rs:145-173).
struct LiveMonitorRateLimiter {
    var bucket: LiveMonitorTokenBucket
    var suppression = LiveMonitorSuppressionTracker()

    init(killToolName: String, now: Date) {
        bucket = LiveMonitorTokenBucket(
            capacity: LiveMonitorLimits.rateLimitCapacity,
            refillIntervalMS: LiveMonitorLimits.rateLimitRefillMS,
            now: now
        )
        suppression.killToolName = killToolName
    }

    mutating func processEvent(now: Date) -> LiveMonitorRateLimitOutcome {
        let available = bucket.tryConsume(now: now)
        return suppression.process(tokenAvailable: available, now: now)
    }

    var isKilled: Bool { suppression.killed }
}

// MARK: - The monitor host: pipelines + the event delivery seam

/// One monitor event bound for the model. `eventText` is the full
/// `<monitor-event …>` wrap — what upstream's `InjectNotification` prompt
/// blocks carry (notification_bridge.rs:776-789).
struct LiveMonitorEvent: Sendable, Equatable {
    var taskID: String
    var eventText: String
}

/// Per-session monitor runtime: starts monitor processes through the real
/// shell execution, runs the stdout pipelines, and delivers wrapped events
/// into the composition-installed sink. Exists only where the interactive
/// controller does — the sink's idle half is the controller's queue, so a
/// composition with no controller advertises no `monitor` tool (AGENTS.md
/// §4; same shape as the scheduler host).
actor LiveMonitorHost {
    struct Context: Sendable {
        var sessionID: String
        /// Where `monitor-<callID>.log` output files land. The port's analog
        /// of upstream's `session_folder/terminal/` (tool.rs:110-112).
        var outputDirectory: URL
        var clock: @Sendable () -> Date = { Date() }
    }

    private struct Pipeline {
        var taskID: String
        var description: String
        var outputFile: URL
        var offset: UInt64 = 0
        var lineProcessor = LiveMonitorLineProcessor()
        var rateLimiter: LiveMonitorRateLimiter
        var finished = false
    }

    private let context: Context
    private var eventSink: (@Sendable (LiveMonitorEvent) async -> Void)?
    /// Events raised before the sink installs. The controller wires the sink
    /// during composition; a monitor can only be dispatched by a running
    /// turn, so this window is theoretical — buffered anyway so the silent-
    /// drop class (AGENTS.md §3) stays structurally impossible.
    private var pendingEvents: [LiveMonitorEvent] = []
    private var pipelines: [String: Pipeline] = [:]
    private var pollLoops: [String: Task<Void, Never>] = [:]
    /// The TaskCompleted auto-wake: fires exactly once per completed task
    /// through the interjection seam. Wired by the composition; `nil`
    /// until then (events before wiring are dropped — the wake has no
    /// buffering analog because the monitor host only exists inside a
    /// session that already owns an interjection buffer).
    private var completionWake: LiveTaskCompletionWake?

    init(context: Context) {
        self.context = context
    }

    var sessionID: String { context.sessionID }

    func outputFileURL(callID: String) -> URL {
        context.outputDirectory.appendingPathComponent("monitor-\(callID).log")
    }

    func setEventSink(_ sink: (@Sendable (LiveMonitorEvent) async -> Void)?) async {
        eventSink = sink
        guard let sink else { return }
        let held = pendingEvents
        pendingEvents = []
        for event in held {
            await sink(event)
        }
    }

    func setCompletionWake(_ wake: LiveTaskCompletionWake) {
        self.completionWake = wake
    }

    /// Register a monitor's pipeline. `startOffset` 0 for fresh pipelines
    /// (upstream's reparent re-spawn offset has no port source — one session,
    /// no reparenting).
    func track(taskID: String, description: String, outputFile: URL) {
        pipelines[taskID] = Pipeline(
            taskID: taskID,
            description: description,
            outputFile: outputFile,
            rateLimiter: LiveMonitorRateLimiter(
                killToolName: LiveBackgroundTaskTools.killTaskName,
                now: context.clock()
            )
        )
    }

    /// The production poll loop around `tick` — upstream's
    /// `run_monitor_pipeline` loop with its 200ms debounce sleep
    /// (tool.rs:261-330). Tests never call this; they drive `tick` directly.
    func spawnPollLoop(taskID: String, process: any OpenGrokShellProcessExecution) {
        pollLoops[taskID]?.cancel()
        pollLoops[taskID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let finished = await self.tick(taskID: taskID, process: process)
                if finished { return }
                try? await Task.sleep(nanoseconds: LiveMonitorLimits.debounceMS * 1_000_000)
            }
        }
    }

    /// One pipeline pass (the body of upstream's loop, tool.rs:261-330):
    /// completion check, output-file drain → line processor → batch → rate
    /// limiter → wrap → sink. Returns `true` when the pipeline is done.
    ///
    /// On completion the remaining partial line flushes, and deliberately NO
    /// terminal `[monitor ended]` event is emitted — upstream reserves the
    /// completion wake for `TaskCompleted` (tool.rs:312-318). The wake fires
    /// through `LiveTaskCompletionWake.reportIfNew`, routed into the
    /// interjection seam exactly once.
    @discardableResult
    func tick(
        taskID: String,
        process: any OpenGrokShellProcessExecution,
        now: Date? = nil
    ) async -> Bool {
        guard var pipeline = pipelines[taskID], !pipeline.finished else { return true }
        let instant = now ?? context.clock()

        let snapshot = await process.taskSnapshot(taskID)
        let completed = snapshot == nil || snapshot?.completed == true

        let newBytes = Self.readNewBytes(pipeline.outputFile, offset: &pipeline.offset)
        var deliveries: [String] = []
        if !newBytes.isEmpty {
            let lines = pipeline.lineProcessor.push(newBytes)
            if !lines.isEmpty {
                deliveries.append(LiveMonitorLineProcessor.batchLines(lines))
            }
        }
        if completed, let remaining = pipeline.lineProcessor.flush() {
            deliveries.append(remaining)
        }
        var events: [LiveMonitorEvent] = []
        for eventText in deliveries {
            events.append(contentsOf: Self.processEvent(
                taskID: taskID,
                description: pipeline.description,
                eventText: eventText,
                rateLimiter: &pipeline.rateLimiter,
                now: instant
            ))
        }
        let finished = completed || pipeline.rateLimiter.isKilled
        pipeline.finished = finished
        pipelines[taskID] = pipeline
        for event in events {
            await deliver(event)
        }
        if finished, completed, let completionWake {
            if let snapshot = await process.taskSnapshot(taskID) {
                await completionWake.reportIfNew(snapshot)
            }
        }
        return finished
    }

    /// `process_event` (tool.rs:363-408): allowed events deliver (preceded
    /// by a catch-up notice when suppression just ended); suppressed events
    /// drop silently; the auto-kill message delivers and the pipeline stops.
    private static func processEvent(
        taskID: String,
        description: String,
        eventText: String,
        rateLimiter: inout LiveMonitorRateLimiter,
        now: Date
    ) -> [LiveMonitorEvent] {
        switch rateLimiter.processEvent(now: now) {
        case .allowed(let catchUpNotice):
            var events: [LiveMonitorEvent] = []
            if let notice = catchUpNotice {
                events.append(LiveMonitorEvent(
                    taskID: taskID,
                    eventText: wrapMonitorEvent(description: description, eventText: notice, taskID: taskID)
                ))
            }
            events.append(LiveMonitorEvent(
                taskID: taskID,
                eventText: wrapMonitorEvent(description: description, eventText: eventText, taskID: taskID)
            ))
            return events
        case .suppressed:
            return []
        case .autoKill(let message):
            return [LiveMonitorEvent(
                taskID: taskID,
                eventText: wrapMonitorEvent(description: description, eventText: message, taskID: taskID)
            )]
        }
    }

    private func deliver(_ event: LiveMonitorEvent) async {
        if let eventSink {
            await eventSink(event)
        } else {
            pendingEvents.append(event)
        }
    }

    /// `read_new_bytes` (tool.rs:333-361): read from `offset`, cap one read
    /// at 1 MB, advance the offset by what was actually read.
    private static func readNewBytes(_ url: URL, offset: inout UInt64) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let fileLength = try? handle.seekToEnd(), fileLength > offset else { return [] }
        guard (try? handle.seek(toOffset: offset)) != nil else { return [] }
        let toRead = Int(min(fileLength - offset, UInt64(LiveMonitorLimits.maxSingleReadBytes)))
        guard let data = try? handle.read(upToCount: toRead) else { return [] }
        offset += UInt64(data.count)
        return [UInt8](data)
    }

    /// Executor teardown: stop every poll loop. The monitored processes die
    /// with the shell backend (`cancelAll`/backend teardown), matching the
    /// intent of upstream's Weak-handle pipeline exit (tool.rs:235-241);
    /// this port pins nothing across sessions because the loops are
    /// cancelled here, in the same shutdown that releases the executor.
    func shutdown() async {
        for loop_ in pollLoops.values {
            loop_.cancel()
        }
        pollLoops.removeAll()
        pipelines.removeAll()
        if let completionWake {
            await completionWake.shutdown()
        }
        completionWake = nil
    }
}

// MARK: - The tool: spec + dispatch

enum LiveMonitorTools {
    static let toolName = "monitor"

    /// `description_template` (tool.rs:29-35) with the template conditionals
    /// resolved for this session's real surface: system reminders are how
    /// events arrive (the sink delivers into the chat), and the kill tool is
    /// advertised as `kill_command_or_subagent` — the same rendered values
    /// upstream's finalize produces for the grok-build preset.
    static func toolSpec() -> ToolSpec {
        ToolSpec(
            name: toolName,
            description: """
            Start a background monitor that streams events from a long-running script. Each stdout line is an event - you can keep working and notifications arrive in the chat. Exit ends the watch.

            **Output volume**: Every stdout line is a main-agent wake. Print only `DONE`/`FAILED`/`CANCELLED`. No progress or CHANGE lines. Use `grep --line-buffered` in pipes (plain `grep` buffers and delays events by minutes).

            Set `persistent: true` for session-length watches (PR monitoring, log tails) -- the monitor runs until you call kill_command_or_subagent or until the session ends. Otherwise it stops at `timeout_ms` (default 10h).
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("Shell command or script. Each stdout line is an event; exit ends the watch."),
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Short human-readable description of what you are monitoring (shown in every notification)."),
                    ]),
                    "timeout_ms": .object([
                        "type": .string("integer"),
                        "description": .string("Kill the monitor after this deadline (ms). Default: 36000000 (10 hr). Max: 36000000 (10 hr)."),
                    ]),
                    "persistent": .object([
                        "type": .string("boolean"),
                        "description": .string("Run for the lifetime of the session (no timeout). Stop with kill_command_or_subagent."),
                    ]),
                ]),
                "required": .array([.string("command"), .string("description")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// `MonitorInput::validate` (types.rs:87-98), message verbatim.
    static let timeoutExceedsMaxMessage =
        "persistent must be true when timeout_ms exceeds \(LiveMonitorLimits.maxTimeoutMS)ms"

    /// `resolved_timeout_ms` (types.rs:100-107): 0 for persistent monitors.
    static func resolvedTimeoutMS(timeoutMS: UInt64?, persistent: Bool) -> UInt64 {
        persistent ? 0 : (timeoutMS ?? LiveMonitorLimits.defaultTimeoutMS)
    }

    /// `MonitorTool::run` (tool.rs:73-226): validate, start the background
    /// process with `kind: .monitor`, register the pipeline, and return the
    /// serialized `MonitorOutput`.
    static func invoke(
        args: JSONValue,
        callID: String,
        process: any OpenGrokShellProcessExecution,
        host: LiveMonitorHost
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        guard case .object(let object) = args else {
            return .failure(.invalidCall("\(toolName) requires an object argument"))
        }
        guard case .string(let command)? = object["command"],
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.invalidCall("\(toolName) requires a non-empty command"))
        }
        guard case .string(let description)? = object["description"] else {
            return .failure(.invalidCall("\(toolName) requires a description"))
        }
        let timeoutMS = unsignedInteger(object["timeout_ms"])
        let persistent = lenientBoolFromJSON(object["persistent"] ?? .bool(false)) ?? false
        if let timeoutMS, !persistent, timeoutMS > LiveMonitorLimits.maxTimeoutMS {
            return .failure(.invalidCall(timeoutExceedsMaxMessage))
        }
        let resolvedTimeout = resolvedTimeoutMS(timeoutMS: timeoutMS, persistent: persistent)

        let outputFile = await host.outputFileURL(callID: callID)
        try? FileManager.default.createDirectory(
            at: outputFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ShellCommandRequest(
            command: command,
            workingDirectory: process.workingDirectory,
            // PYTHONUNBUFFERED, upstream's one env override (tool.rs:117-120).
            environment: ["PYTHONUNBUFFERED": "1"],
            // 0 means persistent: upstream substitutes a year
            // (tool.rs:121-125, "long-running (until kill or session end)").
            timeout: resolvedTimeout == 0
                ? .seconds(86_400 * 365)
                : .milliseconds(Int64(resolvedTimeout)),
            outputByteLimit: 10 * 1_024 * 1_024,
            outputFile: outputFile,
            toolCallID: callID,
            displayCommand: "[monitor] \(description)",
            autoBackgroundOnTimeout: false,
            kind: .monitor,
            ownerSessionID: process.sessionID,
            description: trimmedDescription.isEmpty ? nil : description
        )
        let handle: ShellBackgroundHandle
        do {
            handle = try await process.runBackground(request)
        } catch {
            // Upstream: `ToolError::custom("process_manager", e)` (tool.rs:138).
            return .failure(.failed("process_manager: \(error)"))
        }

        await host.track(
            taskID: handle.taskID,
            description: description,
            outputFile: outputFile
        )
        await host.spawnPollLoop(taskID: handle.taskID, process: process)

        // `MonitorOutput` (types.rs:68-77), camelCase per its
        // `rename_all = "camelCase"`. Keys sorted for determinism — the
        // scheduler tools' recorded cosmetic divergence, shared.
        let value: JSONValue = .object([
            "taskId": .string(handle.taskID),
            "timeoutMs": .number(.uint64(resolvedTimeout)),
            "persistent": .bool(resolvedTimeout == 0),
        ])
        return .success(OpenGrokShellToolCallResult(
            value: value,
            promptText: encodeJSON(value)
        ))
    }

    private static func encodeJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func unsignedInteger(_ value: JSONValue?) -> UInt64? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            if let unsigned = number.uint64Value { return unsigned }
            if let integer = number.int64Value, integer >= 0 { return UInt64(integer) }
            return nil
        case .string(let string):
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
