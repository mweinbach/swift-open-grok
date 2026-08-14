// MonitorToolTests.swift
//
// Tests for Background Monitor Tool, Token Bucket, Rate Limiter, and LineProcessor.

import Foundation
import OpenGrokExecutionTools
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import Testing

@Suite("Monitor Tool & Rate Limiter Tests")
struct MonitorToolTests {

    // MARK: - 1. Input Validation Tests

    @Test("default timeout is 10 hours")
    func defaultTimeoutIs10Hours() throws {
        let input = MonitorInput(
            command: "tail -f /var/log/app.log",
            description: "watch log",
            timeoutMs: nil,
            persistent: false
        )
        #expect(input.resolvedTimeoutMs() == DEFAULT_TIMEOUT_MS)
        #expect(DEFAULT_TIMEOUT_MS == 36_000_000)
        #expect(throws: Never.self) {
            try input.validate()
        }
    }

    @Test("persistent monitor has zero resolved timeout")
    func persistentHasZeroTimeout() throws {
        let input = MonitorInput(
            command: "tail -f /var/log/app.log",
            description: "watch log",
            timeoutMs: nil,
            persistent: true
        )
        #expect(input.resolvedTimeoutMs() == 0)
        #expect(throws: Never.self) {
            try input.validate()
        }
    }

    @Test("explicit timeout within max limit passes validation")
    func explicitTimeoutWithinMax() throws {
        let input = MonitorInput(
            command: "echo test",
            description: "short task",
            timeoutMs: 600_000,
            persistent: false
        )
        #expect(input.resolvedTimeoutMs() == 600_000)
        #expect(throws: Never.self) {
            try input.validate()
        }
    }

    @Test("timeout exceeding max without persistent fails validation")
    func timeoutExceedingMaxWithoutPersistentFails() {
        let input = MonitorInput(
            command: "echo test",
            description: "oversized timeout",
            timeoutMs: MAX_TIMEOUT_MS + 1,
            persistent: false
        )
        #expect(throws: MonitorError.timeoutExceedsMax) {
            try input.validate()
        }
    }

    @Test("timeout exceeding max with persistent passes validation")
    func timeoutExceedingMaxWithPersistentPasses() throws {
        let input = MonitorInput(
            command: "echo test",
            description: "persistent override",
            timeoutMs: MAX_TIMEOUT_MS + 1,
            persistent: true
        )
        #expect(input.resolvedTimeoutMs() == 0)
        #expect(throws: Never.self) {
            try input.validate()
        }
    }

    @Test("MonitorInput JSON decoding handles snake_case and lenient types")
    func monitorInputDecoding() throws {
        let json = """
        {
            "command": "python worker.py",
            "description": "worker process",
            "timeout_ms": 120000,
            "persistent": "true"
        }
        """
        let decoder = JSONDecoder()
        let input = try decoder.decode(MonitorInput.self, from: Data(json.utf8))
        #expect(input.command == "python worker.py")
        #expect(input.description == "worker process")
        #expect(input.timeoutMs == 120000)
        #expect(input.persistent == true)
        #expect(input.resolvedTimeoutMs() == 0)
    }

    // MARK: - 2. Token Bucket Tests

    @Test("bucket starts full at capacity")
    func bucketStartsFull() {
        let bucket = TokenBucket(capacity: 10, refillIntervalMs: 2_000)
        #expect(bucket.capacity == 10)
        #expect(bucket.tokens == 10)

        for _ in 0..<10 {
            #expect(bucket.tryConsume())
        }
        #expect(!bucket.tryConsume())
        #expect(bucket.tokens == 0)
    }

    @Test("bucket refills after interval with deterministic clock")
    func bucketRefillsAfterInterval() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = TokenBucket(capacity: 10, refillIntervalMs: 2_000, now: t0)

        // Drain bucket
        for _ in 0..<10 {
            #expect(bucket.tryConsume(now: t0))
        }
        #expect(!bucket.tryConsume(now: t0))

        // Advance 1.9s (not enough for 1 token)
        let t1 = t0.addingTimeInterval(1.9)
        #expect(!bucket.tryConsume(now: t1))

        // Advance 2.0s from t0 (exactly 1 token refill)
        let t2 = t0.addingTimeInterval(2.0)
        #expect(bucket.tryConsume(now: t2))
        #expect(!bucket.tryConsume(now: t2))

        // Advance 6.0s (3 tokens refilled)
        let t3 = t2.addingTimeInterval(6.0)
        #expect(bucket.tryConsume(now: t3))
        #expect(bucket.tryConsume(now: t3))
        #expect(bucket.tryConsume(now: t3))
        #expect(!bucket.tryConsume(now: t3))
    }

    @Test("bucket does not exceed capacity on long sleep")
    func bucketDoesNotExceedCapacity() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bucket = TokenBucket(capacity: 3, refillIntervalMs: 2_000, now: t0)

        // Drain all 3
        for _ in 0..<3 {
            #expect(bucket.tryConsume(now: t0))
        }
        #expect(!bucket.tryConsume(now: t0))

        // Advance 100 seconds (far more than needed for 3 tokens)
        let t1 = t0.addingTimeInterval(100.0)
        #expect(bucket.tryConsume(now: t1))
        #expect(bucket.tryConsume(now: t1))
        #expect(bucket.tryConsume(now: t1))
        #expect(!bucket.tryConsume(now: t1))
    }

    // MARK: - 3. Suppression Tracker Tests

    @Test("suppression tracker counts suppressed events")
    func suppressionTrackerCounts() {
        let tracker = SuppressionTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let outcome = tracker.process(tokenAvailable: false, description: "test", now: t0)
        #expect(outcome == .suppressed)
        #expect(tracker.suppressedCount == 1)
        #expect(tracker.lastSuppression == t0)
        #expect(tracker.suppressionStart == t0)
    }

    @Test("catch-up notice generated on recovery after suppression")
    func catchUpNoticeOnRecovery() {
        let tracker = SuppressionTracker(killToolName: "kill_command_or_subagent")
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Suppress 3 events
        _ = tracker.process(tokenAvailable: false, description: "test", now: t0)
        _ = tracker.process(tokenAvailable: false, description: "test", now: t0)
        _ = tracker.process(tokenAvailable: false, description: "test", now: t0)
        #expect(tracker.suppressedCount == 3)

        // Token becomes available
        let t1 = t0.addingTimeInterval(1.0)
        let outcome = tracker.process(tokenAvailable: true, description: "test", now: t1)

        guard case .allowed(let catchUpNotice) = outcome else {
            Issue.record("expected Allowed outcome, got \(outcome)")
            return
        }
        let notice = try! #require(catchUpNotice)
        #expect(notice.contains("3 events suppressed"))
        #expect(notice.contains("kill_command_or_subagent"))
        #expect(tracker.suppressedCount == 0)
    }

    @Test("no catch-up notice when no events were suppressed")
    func noCatchUpWhenNoSuppression() {
        let tracker = SuppressionTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let outcome = tracker.process(tokenAvailable: true, description: "test", now: t0)

        guard case .allowed(let catchUpNotice) = outcome else {
            Issue.record("expected Allowed outcome, got \(outcome)")
            return
        }
        #expect(catchUpNotice == nil)
    }

    @Test("killed tracker discards events")
    func killedTrackerDiscardsEvents() {
        let tracker = SuppressionTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.process(tokenAvailable: false, description: "test", now: t0)
        _ = tracker.process(tokenAvailable: false, description: "test", now: t0.addingTimeInterval(35.0))
        #expect(tracker.killed)

        let outcome = tracker.process(tokenAvailable: true, description: "test", now: t0.addingTimeInterval(40.0))
        #expect(outcome == .suppressed)
    }

    // MARK: - 4. Auto-Kill on 30-Second Sustained Overload

    @Test("auto-kill triggers after 30 seconds of continuous rate-limit violations")
    func autoKillOnSustainedOverload() {
        let tracker = SuppressionTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // First suppression at t0
        let outcome1 = tracker.process(tokenAvailable: false, description: "overload", now: t0)
        #expect(outcome1 == .suppressed)
        #expect(!tracker.killed)

        // Violation at t0 + 15s (below threshold)
        let t1 = t0.addingTimeInterval(15.0)
        let outcome2 = tracker.process(tokenAvailable: false, description: "overload", now: t1)
        #expect(outcome2 == .suppressed)
        #expect(!tracker.killed)

        // Violation at t0 + 30.1s (exceeds 30,000ms threshold)
        let t2 = t0.addingTimeInterval(30.1)
        let outcome3 = tracker.process(tokenAvailable: false, description: "overload", now: t2)

        guard case .autoKill(let message) = outcome3 else {
            Issue.record("expected AutoKill outcome, got \(outcome3)")
            return
        }
        #expect(tracker.killed)
        #expect(message.contains("Monitor stopped -- your script produced too much output"))
        #expect(message.contains("3 events suppressed over 30s"))
        #expect(message.contains("grep --line-buffered"))
    }

    @Test("combined MonitorRateLimiter processes events and respects capacity")
    func combinedRateLimiter() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let limiter = MonitorRateLimiter(capacity: 3, refillIntervalMs: 2_000, now: t0)

        // First 3 events allowed
        for _ in 0..<3 {
            let outcome = limiter.processEvent(description: "test", now: t0)
            guard case .allowed(let notice) = outcome else {
                Issue.record("expected Allowed, got \(outcome)")
                continue
            }
            #expect(notice == nil)
        }

        // 4th event suppressed
        let outcome4 = limiter.processEvent(description: "test", now: t0)
        #expect(outcome4 == .suppressed)

        // After 2 seconds, 1 token refilled -> event allowed with catch-up notice
        let t1 = t0.addingTimeInterval(2.0)
        let outcome5 = limiter.processEvent(description: "test", now: t1)
        guard case .allowed(let notice) = outcome5 else {
            Issue.record("expected Allowed with catch-up notice, got \(outcome5)")
            return
        }
        let catchUp = try! #require(notice)
        #expect(catchUp.contains("1 events suppressed"))
    }

    // MARK: - 5. Line and Batch Truncation Limits

    @Test("line processor extracts complete lines and skips empty lines")
    func lineProcessorSplitsLines() {
        var processor = LineProcessor()
        let lines = processor.push("hello\n\nworld\r\nfoo\n")
        #expect(lines == ["hello", "world", "foo"])
    }

    @Test("line processor buffers partial lines until newline or flush")
    func lineProcessorBuffersPartialLines() {
        var processor = LineProcessor()
        let lines1 = processor.push("partial")
        #expect(lines1.isEmpty)

        let lines2 = processor.push(" line\nsecond")
        #expect(lines2 == ["partial line"])

        let flushed = processor.flush()
        #expect(flushed == "second")
    }

    @Test("line processor strips ANSI escape sequences")
    func lineProcessorStripsAnsi() {
        var processor = LineProcessor()
        let lines = processor.push("\u{1b}[31m[ERROR]\u{1b}[0m Connection \u{1b}[1mreset\u{1b}[m\n")
        #expect(lines == ["[ERROR] Connection reset"])
    }

    @Test("line processor truncates individual line over 500 characters")
    func lineProcessorTruncatesLongLines() {
        var processor = LineProcessor()
        let longText = String(repeating: "A", count: 600) + "\n"
        let lines = processor.push(longText)

        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.hasPrefix(String(repeating: "A", count: 500)))
        #expect(line.hasSuffix("\u{2026} [truncated]"))
        #expect(line.count == 500 + "\u{2026} [truncated]".count)
    }

    @Test("batchLines joins with newline and truncates when over 3000 chars")
    func batchLinesTruncatesAtLimit() {
        let line1 = String(repeating: "x", count: 2_000)
        let line2 = String(repeating: "y", count: 2_000)
        let batched = LineProcessor.batchLines([line1, line2], limit: BATCH_TRUNCATION_LIMIT)

        #expect(batched.count == BATCH_TRUNCATION_LIMIT + "\n\u{2026} [truncated]".count)
        #expect(batched.hasSuffix("\n\u{2026} [truncated]"))
        #expect(batched.hasPrefix(String(repeating: "x", count: 2_000)))
    }

    @Test("buffer cap is enforced on huge chunk without newlines")
    func bufferCapEnforced() {
        var processor = LineProcessor(bufferCapBytes: 1_000)
        let huge = Data(repeating: 0x61, count: 2_000) // 2000 'a's
        let lines = processor.push(huge)
        #expect(lines.isEmpty)

        // After flushing, only at most bufferCapBytes should have been retained
        let flushed = processor.flush()
        let flushedText = try! #require(flushed)
        // Since line truncation limit is 500, flushed line will be truncated at 500
        #expect(flushedText.hasSuffix("\u{2026} [truncated]"))
    }

    // MARK: - 6. Description Sanitization & XML Event Wrapping

    @Test("sanitize description and wrap monitor event")
    func sanitizeAndWrapEvent() {
        let desc = "watch \"prod\"\nlogs\rnow"
        let sanitized = sanitizeMonitorDescription(desc)
        #expect(sanitized == "watch 'prod' logs now")

        let wrapped = wrapMonitorEvent(
            description: "watch \"prod\"\nlogs",
            eventText: "2026-08-14 ERROR: Out of memory",
            taskId: "task-42"
        )
        #expect(wrapped == """
        <monitor-event description="watch 'prod' logs" task_id="task-42">
        2026-08-14 ERROR: Out of memory
        </monitor-event>
        """)
    }

    // MARK: - 7. MonitorTool Execution Output

    @Test("MonitorTool produces expected output and description schema")
    func monitorToolOutput() async throws {
        let tool = MonitorTool()
        #expect(tool.id().stringValue == "monitor")

        let ctx = ToolCallContext(
            callId: try! ToolCallId("call-mon-1")
        )

        let args: JSONValue = .object([
            "command": .string("tail -f app.log"),
            "description": .string("app log stream"),
            "timeout_ms": .number(.uint64(120_000)),
            "persistent": .bool(false)
        ])

        let result = await tool.run(ctx: ctx, args: args)
        guard case .success(let output) = result else {
            Issue.record("expected successful MonitorOutput, got \(result)")
            return
        }
        #expect(output.taskId == "call-mon-1")
        #expect(output.timeoutMs == 120_000)
        #expect(output.persistent == false)

        let modelBlocks = output.modelOutput()
        #expect(modelBlocks.count == 1)
        guard case .text(let text) = modelBlocks[0] else {
            Issue.record("expected text block")
            return
        }
        #expect(text.contains("Monitor started (task call-mon-1, timeout 120000ms)"))
    }
}
