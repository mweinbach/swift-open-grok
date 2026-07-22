// OpenGrokTracing.swift
//
// Open Grok — Swift port of `xai-tracing` + `xai-tracing-macros` behavior.
//
// Structured spans, correlation IDs (session/turn/tool/provider/request/
// child-agent), W3C traceparent injection, and default redaction of
// credentials, prompts, private headers, filesystem paths, and tool payloads.
// Rust procedural macros are absorbed into ordinary Swift helpers.

import Foundation
import Dispatch
import OpenGrokShared


/// Portable lock over mutable state. Sync `withLock` is safe to call from async.
final class LockHolder<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    init(_ state: State) { self.state = state }
    @discardableResult
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

/// Portable monotonic timestamp (nanoseconds since boot).
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    public var nanoseconds: UInt64
    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    public static func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
    public func advanced(bySeconds seconds: TimeInterval) -> MonotonicInstant {
        if seconds >= 0 {
            return MonotonicInstant(nanoseconds: nanoseconds &+ UInt64(seconds * 1_000_000_000))
        } else {
            return MonotonicInstant(nanoseconds: nanoseconds &- UInt64((-seconds) * 1_000_000_000))
        }
    }
    public func seconds(until other: MonotonicInstant) -> TimeInterval {
        if other.nanoseconds >= nanoseconds {
            return TimeInterval(other.nanoseconds - nanoseconds) / 1_000_000_000
        }
        return -TimeInterval(nanoseconds - other.nanoseconds) / 1_000_000_000
    }
}


// MARK: - Correlation

/// Correlation keys preserved across session, turn, tool, provider, and
/// child-agent boundaries.
public struct TraceCorrelation: Sendable, Hashable, Equatable, Codable {
    public var sessionID: String?
    public var turnID: String?
    public var toolCallID: String?
    public var provider: String?
    public var requestID: String?
    public var childAgentID: String?
    public var parentSpanID: String?

    public init(
        sessionID: String? = nil,
        turnID: String? = nil,
        toolCallID: String? = nil,
        provider: String? = nil,
        requestID: String? = nil,
        childAgentID: String? = nil,
        parentSpanID: String? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.toolCallID = toolCallID
        self.provider = provider
        self.requestID = requestID
        self.childAgentID = childAgentID
        self.parentSpanID = parentSpanID
    }

    /// Merge, preferring non-nil fields from `other`.
    public func merging(_ other: TraceCorrelation) -> TraceCorrelation {
        TraceCorrelation(
            sessionID: other.sessionID ?? sessionID,
            turnID: other.turnID ?? turnID,
            toolCallID: other.toolCallID ?? toolCallID,
            provider: other.provider ?? provider,
            requestID: other.requestID ?? requestID,
            childAgentID: other.childAgentID ?? childAgentID,
            parentSpanID: other.parentSpanID ?? parentSpanID
        )
    }
}

// MARK: - Span attributes (redacted by default)

/// Attribute value that has already been redacted for export/logging.
public enum TraceAttributeValue: Sendable, Hashable, Equatable, Codable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    public var jsonValue: JSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .int(let i): return .number(.int64(i))
        case .double(let d): return .number(.double(d))
        case .bool(let b): return .bool(b)
        }
    }
}

/// Kind of span, aligned with OpenTelemetry span kinds used by the Rust port.
public enum TraceSpanKind: String, Sendable, Hashable, Equatable, Codable {
    case internalSpan = "internal"
    case client = "client"
    case server = "server"
    case producer = "producer"
    case consumer = "consumer"
}

/// Status recorded on span end.
public enum TraceSpanStatus: Sendable, Hashable, Equatable, Codable {
    case unset
    case ok
    case error(message: String)
}

/// A structured span with correlation and redacted attributes.
public struct TraceSpan: Sendable, Hashable, Equatable, Identifiable {
    public let id: String
    public let traceID: String
    public let name: String
    public let kind: TraceSpanKind
    public let correlation: TraceCorrelation
    public private(set) var attributes: [String: TraceAttributeValue]
    public private(set) var status: TraceSpanStatus
    public let startedAt: MonotonicInstant
    public private(set) var endedAt: MonotonicInstant?

    public init(
        name: String,
        kind: TraceSpanKind = .internalSpan,
        correlation: TraceCorrelation = TraceCorrelation(),
        attributes: [String: TraceAttributeValue] = [:],
        traceID: String? = nil,
        spanID: String? = nil,
        startedAt: MonotonicInstant = MonotonicInstant.now()
    ) {
        self.id = spanID ?? TraceIDs.newSpanID()
        self.traceID = traceID ?? TraceIDs.newTraceID()
        self.name = name
        self.kind = kind
        self.correlation = correlation
        self.attributes = TraceRedaction.redactAttributes(attributes)
        self.status = .unset
        self.startedAt = startedAt
        self.endedAt = nil
    }

    public mutating func setAttribute(_ key: String, _ value: TraceAttributeValue) {
        if let redacted = TraceRedaction.redactAttribute(key: key, value: value) {
            attributes[key] = redacted
        }
        // Dropped when the key is denylisted (credentials, prompts, …).
    }

    /// Ends the span. Returns `true` only on the first active→ended transition
    /// so sinks can enforce exactly-once completion reporting.
    @discardableResult
    public mutating func end(status: TraceSpanStatus = .ok) -> Bool {
        guard endedAt == nil else { return false }
        self.status = status
        self.endedAt = MonotonicInstant.now()
        return true
    }

    /// W3C `traceparent` for this span (`00-<trace>-<span>-01`).
    public var traceparent: String {
        "00-\(traceID)-\(id)-01"
    }
}

// MARK: - IDs

public enum TraceIDs {
    /// 32 lowercase hex characters.
    public static func newTraceID() -> String {
        randomHex(byteCount: 16)
    }

    /// 16 lowercase hex characters.
    public static func newSpanID() -> String {
        randomHex(byteCount: 8)
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a W3C `traceparent` into (version, traceID, spanID).
    public static func parseTraceparent(_ value: String) -> (version: String, traceID: String, spanID: String)? {
        let parts = value.split(separator: "-")
        guard parts.count >= 3 else { return nil }
        let version = String(parts[0])
        let traceID = String(parts[1])
        let spanID = String(parts[2])
        guard version.count == 2,
              traceID.count == 32,
              spanID.count == 16,
              traceID.allSatisfy(\.isHexDigit),
              spanID.allSatisfy(\.isHexDigit)
        else { return nil }
        return (version, traceID.lowercased(), spanID.lowercased())
    }
}

// MARK: - Redaction

/// Default redaction policy for tracing attributes and log fields.
public enum TraceRedaction {
    /// Keys that must never be exported (case-insensitive match on last path segment).
    public static let denylistedKeys: Set<String> = [
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api_key",
        "api-key",
        "apikey",
        "password",
        "passwd",
        "secret",
        "token",
        "access_token",
        "refresh_token",
        "cookie",
        "set-cookie",
        "prompt",
        "user_prompt",
        "system_prompt",
        "messages",
        "tool_input",
        "tool_payload",
        "tool_result",
        "file_contents",
        "filesystem_content",
        "body",
        "request_body",
        "response_body",
    ]

    /// Header names treated as private (never logged in full).
    public static let privateHeaders: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
    ]

    /// Returns `nil` when the attribute must be dropped entirely.
    public static func redactAttribute(
        key: String,
        value: TraceAttributeValue
    ) -> TraceAttributeValue? {
        let normalized = normalizeKey(key)
        if denylistedKeys.contains(normalized) {
            return nil
        }
        switch value {
        case .string(let s):
            return .string(redactString(s))
        case .int, .double, .bool:
            return value
        }
    }

    public static func redactAttributes(
        _ attributes: [String: TraceAttributeValue]
    ) -> [String: TraceAttributeValue] {
        var out: [String: TraceAttributeValue] = [:]
        out.reserveCapacity(attributes.count)
        for (k, v) in attributes {
            if let redacted = redactAttribute(key: k, value: v) {
                out[k] = redacted
            }
        }
        return out
    }

    /// Redact a free-form string: secret shapes + user paths.
    public static func redactString(_ input: String) -> String {
        var result = redactSecretShapes(input)
        result = redactUserPaths(result)
        return result
    }

    /// Redact HTTP headers for tracing export. Private headers become `"<redacted>"`.
    public static func redactHeaders(
        _ headers: [String: String]
    ) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in headers {
            if privateHeaders.contains(name.lowercased()) {
                out[name] = "<redacted>"
            } else {
                out[name] = redactString(value)
            }
        }
        return out
    }

    /// Reduce a URL to `scheme://host[:port]` so path/query cannot leak.
    public static func urlOrigin(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host else {
            return value
        }
        var origin = "\(url.scheme ?? "https")://\(host)"
        if let port = url.port {
            origin += ":\(port)"
        }
        return origin
    }

    public static func normalizeKey(_ key: String) -> String {
        key
            .split(separator: ".")
            .last
            .map(String.init)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            ?? key.lowercased()
    }

    /// Scrub common secret shapes (Bearer tokens, sk- keys, long hex secrets).
    public static func redactSecretShapes(_ input: String) -> String {
        var result = input
        // Bearer tokens
        if let regex = try? NSRegularExpression(
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9\-._~+/]+=*"#,
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "Bearer <redacted>"
            )
        }
        // sk- / xai- style API keys
        if let regex = try? NSRegularExpression(
            pattern: #"(?i)\b(sk|xai|api)[-_][A-Za-z0-9]{16,}\b"#,
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "$1-<redacted>"
            )
        }
        return result
    }

    /// Scrub absolute user home paths (`/Users/…`, `/home/…`).
    public static func redactUserPaths(_ input: String) -> String {
        var result = input
        if let regex = try? NSRegularExpression(
            pattern: #"(?i)(/Users/|/home/)[^/\s]+"#,
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "$1<redacted>"
            )
        }
        return result
    }
}

// MARK: - Span sink / dispatcher

/// Consumer of completed spans. When no sink is installed, spans are inert
/// (mirrors Rust `dispatcher_active` — no log spam without a consumer).
///
/// Both methods are required (no protocol-extension defaults) so existential
/// dispatch always hits the concrete sink implementation.
public protocol TraceSpanSink: Sendable {
    func onSpanStarted(_ span: TraceSpan)
    func onSpanEnded(_ span: TraceSpan)
}

/// In-memory sink for tests.
public final class RecordingTraceSink: TraceSpanSink, @unchecked Sendable {
    private struct State {
        var started: [TraceSpan]
        var ended: [TraceSpan]
    }

    private let state = LockHolder(State(started: [], ended: []))

    public init() {}

    public func onSpanStarted(_ span: TraceSpan) {
        state.withLock { $0.started.append(span) }
    }

    public func onSpanEnded(_ span: TraceSpan) {
        state.withLock { $0.ended.append(span) }
    }

    public var startedSpans: [TraceSpan] {
        state.withLock { $0.started }
    }

    public var endedSpans: [TraceSpan] {
        state.withLock { $0.ended }
    }

    public func reset() {
        state.withLock {
            $0.started.removeAll()
            $0.ended.removeAll()
        }
    }
}

/// Process-wide optional sink installation.
public enum TraceDispatcher {
    private struct State {
        var sink: (any TraceSpanSink)?
        var enabled: Bool
    }

    private static let state = LockHolder(State(sink: nil, enabled: true))

    /// Install (or replace) the active sink. Pass `nil` to clear.
    public static func install(sink: (any TraceSpanSink)?) {
        state.withLock { $0.sink = sink }
    }

    /// Global enable/disable for span emission (independent of telemetry).
    public static var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }

    public static var isActive: Bool {
        state.withLock { $0.enabled && $0.sink != nil }
    }

    public static func currentSink() -> (any TraceSpanSink)? {
        state.withLock { s in
            guard s.enabled else { return nil }
            return s.sink
        }
    }

    /// Test helper: clear sink and re-enable.
    public static func resetForTests() {
        state.withLock {
            $0.sink = nil
            $0.enabled = true
        }
    }
}

// MARK: - Tracer

/// Creates and ends spans with optional sink emission.
public struct Tracer: Sendable {
    public var correlation: TraceCorrelation
    /// Optional local sink; when set, used instead of the process-wide dispatcher.
    public var sink: (any TraceSpanSink)?

    public init(
        correlation: TraceCorrelation = TraceCorrelation(),
        sink: (any TraceSpanSink)? = nil
    ) {
        self.correlation = correlation
        self.sink = sink
    }

    private func activeSink() -> (any TraceSpanSink)? {
        sink ?? TraceDispatcher.currentSink()
    }

    /// Start a span. When no dispatcher/sink is active, the span is still
    /// returned for local correlation but is not exported (no spam).
    public func startSpan(
        _ name: String,
        kind: TraceSpanKind = .internalSpan,
        attributes: [String: TraceAttributeValue] = [:],
        parent: TraceSpan? = nil
    ) -> TraceSpan {
        var corr = correlation
        if let parent {
            corr = corr.merging(
                TraceCorrelation(parentSpanID: parent.id)
            )
        }
        let span: TraceSpan
        if let parent {
            span = TraceSpan(
                name: name,
                kind: kind,
                correlation: corr,
                attributes: attributes,
                traceID: parent.traceID,
                spanID: TraceIDs.newSpanID(),
                startedAt: MonotonicInstant.now()
            )
        } else {
            span = TraceSpan(
                name: name,
                kind: kind,
                correlation: corr,
                attributes: attributes,
                traceID: nil,
                spanID: nil
            )
        }
        activeSink()?.onSpanStarted(span)
        return span
    }

    /// Ends `span` and reports to the sink only on the first completion.
    /// Subsequent calls are no-ops (exactly-once end records).
    public func endSpan(_ span: inout TraceSpan, status: TraceSpanStatus = .ok) {
        guard span.end(status: status) else { return }
        activeSink()?.onSpanEnded(span)
    }

    /// Run `body` inside a span, ending it on success or error.
    public func withSpan<T>(
        _ name: String,
        kind: TraceSpanKind = .internalSpan,
        attributes: [String: TraceAttributeValue] = [:],
        parent: TraceSpan? = nil,
        body: (inout TraceSpan) throws -> T
    ) rethrows -> T {
        var span = startSpan(name, kind: kind, attributes: attributes, parent: parent)
        do {
            let value = try body(&span)
            endSpan(&span, status: .ok)
            return value
        } catch {
            endSpan(&span, status: .error(message: TraceRedaction.redactString("\(error)")))
            throw error
        }
    }

    /// Async variant of ``withSpan``.
    public func withSpan<T>(
        _ name: String,
        kind: TraceSpanKind = .internalSpan,
        attributes: [String: TraceAttributeValue] = [:],
        parent: TraceSpan? = nil,
        body: (inout TraceSpan) async throws -> T
    ) async rethrows -> T {
        var span = startSpan(name, kind: kind, attributes: attributes, parent: parent)
        do {
            let value = try await body(&span)
            endSpan(&span, status: .ok)
            return value
        } catch {
            endSpan(&span, status: .error(message: TraceRedaction.redactString("\(error)")))
            throw error
        }
    }
}

// MARK: - HTTP trace propagation

/// Inject W3C `traceparent` (and optionally redacted baggage) into headers.
public func attachTraceToHTTPHeaders(
    _ headers: inout [String: String],
    span: TraceSpan
) {
    headers["traceparent"] = span.traceparent
    if let session = span.correlation.sessionID {
        headers["x-opengrok-session-id"] = session
    }
    if let request = span.correlation.requestID {
        headers["x-opengrok-request-id"] = request
    }
}

/// Extract a parent span context from inbound headers.
public func extractTraceparent(from headers: [String: String]) -> (traceID: String, spanID: String)? {
    let value = headers.first { $0.key.lowercased() == "traceparent" }?.value
    guard let value, let parsed = TraceIDs.parseTraceparent(value) else {
        return nil
    }
    return (parsed.traceID, parsed.spanID)
}

// MARK: - Timing helper (absorbs xai-tracing-macros `timed!`)

/// Simple operation timer that records duration on a span attribute.
public struct TraceTimer: Sendable {
    public let name: String
    public let startedAt: MonotonicInstant

    public init(_ name: String) {
        self.name = name
        self.startedAt = MonotonicInstant.now()
    }

    public func elapsed() -> TimeInterval {
        startedAt.seconds(until: MonotonicInstant.now())
    }

    public func elapsedMilliseconds() -> Double {
        let d = elapsed()
        return (d * 1000.0)
    }
}

/// Run `body` and return `(result, elapsed)`. Macro equivalent of `timed!`.
public func timed<T>(_ name: String, body: () throws -> T) rethrows -> (T, TimeInterval) {
    let timer = TraceTimer(name)
    let value = try body()
    return (value, timer.elapsed())
}
