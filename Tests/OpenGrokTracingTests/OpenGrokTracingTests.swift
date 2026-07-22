// OpenGrokTracingTests.swift
//
// Correlation, redaction, traceparent, dispatcher activity, and span
// lifecycle tests for OpenGrokTracing.

import Foundation
import Testing
@testable import OpenGrokTracing

@Suite("Trace correlation")
struct TraceCorrelationTests {
    @Test func mergePrefersNonNilOther() {
        let base = TraceCorrelation(sessionID: "s1", turnID: "t1")
        let other = TraceCorrelation(turnID: "t2", toolCallID: "tool-9", provider: "xai")
        let merged = base.merging(other)
        #expect(merged.sessionID == "s1")
        #expect(merged.turnID == "t2")
        #expect(merged.toolCallID == "tool-9")
        #expect(merged.provider == "xai")
    }

    @Test func spanPreservesCorrelation() {
        let corr = TraceCorrelation(
            sessionID: "sess",
            turnID: "turn",
            toolCallID: "tc",
            provider: "openai",
            requestID: "req",
            childAgentID: "child"
        )
        let span = TraceSpan(name: "tool.call", correlation: corr)
        #expect(span.correlation.sessionID == "sess")
        #expect(span.correlation.childAgentID == "child")
        #expect(span.correlation.provider == "openai")
    }
}

@Suite("Redaction")
struct TraceRedactionTests {
    @Test func dropsDenylistedKeys() {
        let attrs: [String: TraceAttributeValue] = [
            "http.request.method": .string("POST"),
            "authorization": .string("Bearer secret-token-value"),
            "prompt": .string("user said hello"),
            "tool_payload": .string("{\"cmd\":\"rm\"}"),
            "file_contents": .string("private"),
        ]
        let redacted = TraceRedaction.redactAttributes(attrs)
        #expect(redacted["http.request.method"] == .string("POST"))
        #expect(redacted["authorization"] == nil)
        #expect(redacted["prompt"] == nil)
        #expect(redacted["tool_payload"] == nil)
        #expect(redacted["file_contents"] == nil)
    }

    @Test func scrubsBearerAndAPIKeys() {
        let out = TraceRedaction.redactString(
            "key Bearer abcdef0123456789abcdef and sk-CANARYabcdefghij1234567890 end"
        )
        #expect(!out.contains("abcdef0123456789abcdef"))
        #expect(!out.contains("CANARY"))
        #expect(out.contains("<redacted>"))
    }

    @Test func scrubsUserPaths() {
        let out = TraceRedaction.redactString("read /Users/alice/secret.txt please")
        #expect(!out.contains("alice"))
        #expect(out.contains("/Users/<redacted>"))
    }

    @Test func privateHeadersRedacted() {
        let headers = TraceRedaction.redactHeaders([
            "Authorization": "Bearer tok",
            "Content-Type": "application/json",
            "X-Api-Key": "sekrit",
        ])
        #expect(headers["Authorization"] == "<redacted>")
        #expect(headers["X-Api-Key"] == "<redacted>")
        #expect(headers["Content-Type"] == "application/json")
    }

    @Test func urlOriginDropsPathAndQuery() {
        #expect(
            TraceRedaction.urlOrigin("https://collector.corp.example:4318/v1/logs?token=CANARY")
                == "https://collector.corp.example:4318"
        )
    }

    @Test func setAttributeDropsSecrets() {
        var span = TraceSpan(name: "x")
        span.setAttribute("authorization", .string("Bearer x"))
        span.setAttribute("http.response.status_code", .int(200))
        #expect(span.attributes["authorization"] == nil)
        #expect(span.attributes["http.response.status_code"] == .int(200))
    }
}

@Suite("Traceparent")
struct TraceparentTests {
    @Test func roundTrip() {
        let span = TraceSpan(name: "http_request", kind: .client)
        let tp = span.traceparent
        let parsed = TraceIDs.parseTraceparent(tp)
        #expect(parsed != nil)
        #expect(parsed?.traceID == span.traceID)
        #expect(parsed?.spanID == span.id)
    }

    @Test func attachAndExtractHeaders() {
        var headers: [String: String] = [:]
        let span = TraceSpan(
            name: "c",
            correlation: TraceCorrelation(sessionID: "s", requestID: "r")
        )
        attachTraceToHTTPHeaders(&headers, span: span)
        #expect(headers["traceparent"] == span.traceparent)
        #expect(headers["x-opengrok-session-id"] == "s")
        #expect(headers["x-opengrok-request-id"] == "r")
        let extracted = extractTraceparent(from: headers)
        #expect(extracted?.traceID == span.traceID)
    }

    @Test func childSpanSharesTraceID() {
        // No process-wide dispatcher: pure parent/child ID linkage.
        let tracer = Tracer(correlation: TraceCorrelation(sessionID: "s"))
        let parent = tracer.startSpan("parent")
        let child = tracer.startSpan("child", parent: parent)
        #expect(child.traceID == parent.traceID)
        #expect(child.id != parent.id)
        #expect(child.correlation.parentSpanID == parent.id)
    }
}

@Suite("Dispatcher", .serialized)
struct DispatcherTests {
    @Test func inactiveWithoutSink() {
        TraceDispatcher.resetForTests()
        #expect(!TraceDispatcher.isActive)
    }

    @Test func activeWithSink() {
        let sink = RecordingTraceSink()
        // Prefer an injected sink so hermetic tests do not race the
        // process-wide dispatcher with other suites/targets.
        let tracer = Tracer(sink: sink)
        var span = tracer.startSpan("work")
        tracer.endSpan(&span)
        #expect(sink.startedSpans.count == 1)
        #expect(sink.endedSpans.count == 1)
    }

    @Test func processDispatcherGate() {
        TraceDispatcher.resetForTests()
        let sink = RecordingTraceSink()
        TraceDispatcher.install(sink: sink)
        #expect(TraceDispatcher.isActive)
        TraceDispatcher.isEnabled = false
        #expect(!TraceDispatcher.isActive)
        TraceDispatcher.resetForTests()
        #expect(!TraceDispatcher.isActive)
    }

    @Test func disableStopsEmission() {
        TraceDispatcher.resetForTests()
        let sink = RecordingTraceSink()
        TraceDispatcher.install(sink: sink)
        TraceDispatcher.isEnabled = false
        defer { TraceDispatcher.resetForTests() }

        // No local sink — only the gated process dispatcher.
        let tracer = Tracer()
        var span = tracer.startSpan("noop")
        tracer.endSpan(&span)
        #expect(sink.startedSpans.isEmpty)
        #expect(sink.endedSpans.isEmpty)
    }

    @Test func withSpanRecordsErrorStatus() {
        let sink = RecordingTraceSink()
        struct Boom: Error {}
        let tracer = Tracer(sink: sink)
        #expect(throws: Boom.self) {
            try tracer.withSpan("fail") { _ in
                throw Boom()
            }
        }
        let ended = sink.endedSpans
        #expect(ended.count == 1)
        guard let first = ended.first else { return }
        if case .error = first.status {
            // ok
        } else {
            Issue.record("expected error status")
        }
    }

    @Test func endSpanIsExactlyOnce() {
        let sink = RecordingTraceSink()
        let tracer = Tracer(sink: sink)
        var span = tracer.startSpan("once")
        #expect(span.end(status: .ok) == true)
        #expect(span.end(status: .error(message: "second")) == false)
        // Tracer path also suppresses duplicate sink notifications.
        tracer.endSpan(&span, status: .ok)
        tracer.endSpan(&span, status: .ok)
        // Direct end already closed the span; Tracer.endSpan must not emit.
        #expect(sink.endedSpans.isEmpty)

        var span2 = tracer.startSpan("once-2")
        tracer.endSpan(&span2, status: .ok)
        tracer.endSpan(&span2, status: .error(message: "nope"))
        #expect(sink.endedSpans.count == 1)
        #expect(sink.endedSpans[0].status == .ok)
    }

    @Test func withSpanAsyncEndsExactlyOnce() async throws {
        let sink = RecordingTraceSink()
        let tracer = Tracer(sink: sink)
        let value = try await tracer.withSpan("async-work") { span in
            // Re-entrant completion from inside the body must not double-emit.
            tracer.endSpan(&span, status: .ok)
            return 7
        }
        #expect(value == 7)
        #expect(sink.endedSpans.count == 1)
    }

    @Test func concurrentEndReportsSingleRecord() async {
        let sink = RecordingTraceSink()
        let tracer = Tracer(sink: sink)
        // Class box so concurrent tasks mutate one span value under a lock.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            var span: TraceSpan
            init(_ span: TraceSpan) { self.span = span }
            func end(with tracer: Tracer) {
                lock.lock()
                defer { lock.unlock() }
                tracer.endSpan(&span, status: .ok)
            }
        }
        let box = Box(tracer.startSpan("race"))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    box.end(with: tracer)
                }
            }
        }
        #expect(sink.endedSpans.count == 1)
    }
}

@Suite("Timing")
struct TimingTests {
    @Test func timedReturnsResult() {
        let (value, elapsed) = timed("x") { 42 }
        #expect(value == 42)
        #expect(elapsed >= 0)
    }
}
