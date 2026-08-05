// CodexCompactionHTTP.swift
//
// The wire leg of Codex Remote Compaction V2.
//
// `CodexCompaction.swift` models the protocol — request body, stream events,
// the collector that turns those events into one durable encrypted item — but
// it never touches the network, which is why it stayed testable and unused.
// This file is the missing half: it POSTs the request over the injected
// `HTTPTransport` and feeds decoded SSE frames to whatever the caller supplies.
//
// It deliberately does NOT go through `SamplingClient`. A compaction request is
// not a sampling turn: it carries `compaction_trigger`, a `comp_hash` the
// sampler has no field for, and a beta header, and its response is a single
// opaque item rather than assistant text. Routing it through the sampler would
// mean widening the sampling request type for a body only this path sends.

import Foundation
import OpenGrokHTTP
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared

/// Posts Codex compaction requests over an `HTTPTransport`.
///
/// Credentials arrive as already-resolved headers rather than as a key: this
/// module has no business knowing how the live session authenticated, and a
/// refreshed Codex OAuth token has to be able to replace them between attempts
/// without rebuilding the transport.
public final class HTTPCodexCompactionTransport: CodexCompactionTransport, @unchecked Sendable {
    private let transport: any HTTPTransport
    private let baseURL: String
    private let model: String
    private let lock = NSLock()
    private var headers: [String: String]

    public init(
        transport: any HTTPTransport,
        baseURL: String,
        model: String,
        headers: [String: String]
    ) {
        self.transport = transport
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.model = model
        self.headers = headers
    }

    /// Swap in refreshed credentials after a 401, without losing the rest of
    /// the header set.
    public func replaceAuthorizationHeaders(_ replacement: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        for (name, value) in replacement {
            headers[name] = value
        }
    }

    private func currentHeaders() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return headers
    }

    public func send(
        _ request: CodexCompactionRequest,
        onEvent: @Sendable (CodexCompactionStreamEvent) async throws -> Void
    ) async throws {
        guard let url = URL(string: baseURL + request.endpointPath) else {
            throw CodexCompactionTransportError.transport("invalid Codex endpoint: \(baseURL)\(request.endpointPath)")
        }

        var wireHeaders = currentHeaders()
        wireHeaders["Content-Type"] = "application/json"
        wireHeaders["Accept"] = "text/event-stream, application/json"
        for header in request.headers {
            wireHeaders[header.name] = header.value
        }

        let body = try encodeBody(request)
        let httpRequest = HTTPRequest(
            method: .post,
            url: url,
            headers: wireHeaders,
            body: body,
            idempotency: .nonIdempotent
        )

        var status = 0
        var sawMetadata = false
        var errorBody = Data()
        var parser = ServerSentEventParser()

        for try await event in transport.stream(httpRequest) {
            try Task.checkCancellation()
            switch event {
            case .metadata(let metadata):
                sawMetadata = true
                status = metadata.statusCode
            case .body(let data):
                guard sawMetadata else {
                    errorBody.append(data)
                    continue
                }
                guard (200..<300).contains(status) else {
                    errorBody.append(data)
                    continue
                }
                for frame in parser.consume(data) {
                    guard let decoded = Self.decode(frame) else { continue }
                    try await onEvent(decoded)
                }
            case .end:
                continue
            }
        }

        if sawMetadata, (200..<300).contains(status) {
            for frame in parser.finish() {
                guard let decoded = Self.decode(frame) else { continue }
                try await onEvent(decoded)
            }
        }

        guard sawMetadata else {
            throw CodexCompactionTransportError.transport("no response headers from the Codex compaction endpoint")
        }
        guard (200..<300).contains(status) else {
            let message = Self.errorMessage(from: errorBody)
            if status == 401 || status == 403 {
                throw CodexCompactionTransportError.authentication(status: status)
            }
            throw CodexCompactionTransportError.http(status: status, message: message)
        }
    }

    func encodeBody(_ request: CodexCompactionRequest) throws -> Data {
        // The history must go on the wire in the Responses shape, not in
        // `ConversationItem`'s own Codable form — that encoding is the on-disk
        // session format, and the two are not the same. Reusing the sampler's
        // projection is what keeps a compaction request's `input` identical to
        // the `input` a normal turn sends, which matters because the server
        // validates the compaction against the same conversation it would
        // sample from.
        let projected = projectResponsesRequestBody(
            ConversationRequest(items: request.input, model: model),
            model: model,
            policy: ResponsesRequestPolicy(),
            adapter: providerAdapter(.codex)
        )
        guard case .object(var body) = projected else {
            throw CodexCompactionTransportError.transport("could not project the Codex compaction input")
        }

        // The compaction-specific fields the projection knows nothing about.
        body["stream"] = .bool(true)
        body["compaction_trigger"] = .bool(request.compactionTrigger)
        if let hash = request.compactionHash { body["comp_hash"] = .string(hash) }
        if let instructions = request.instructions { body["instructions"] = .string(instructions) }
        if let turnState = request.turnState { body["turn_state"] = .string(turnState) }
        if let tier = request.serviceTier { body["service_tier"] = .string(tier) }
        if let cacheKey = request.promptCacheKey { body["prompt_cache_key"] = .string(cacheKey) }
        if !request.tools.isEmpty { body["tools"] = .array(request.tools) }
        if let reasoning = request.reasoning { body["reasoning"] = reasoning }

        do {
            return try WireJSONEncoder.make().encode(JSONValue.object(body))
        } catch {
            throw CodexCompactionTransportError.transport(
                "could not encode the Codex compaction request: \(error)"
            )
        }
    }

    /// Decode one SSE `data:` payload. Frames this protocol does not model
    /// decode to `.unrelated` inside `CodexCompactionStreamEvent`; frames that
    /// are not JSON at all (`[DONE]`) are dropped.
    static func decode(_ payload: String) -> CodexCompactionStreamEvent? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[DONE]" else { return nil }
        return try? JSONDecoder().decode(
            CodexCompactionStreamEvent.self,
            from: Data(trimmed.utf8)
        )
    }

    static func errorMessage(from body: Data) -> String {
        guard !body.isEmpty else { return "empty error body" }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
        }
        return String(decoding: body.prefix(2_048), as: UTF8.self)
    }
}

/// Minimal SSE reassembler: accumulates bytes and yields the `data:` payload of
/// each complete event.
///
/// Split on a blank line rather than per line because a single event may carry
/// several `data:` lines, which the spec says to join with newlines — a JSON
/// body wrapped at some proxy's line limit arrives exactly that way, and
/// decoding the lines separately would silently drop the event.
struct ServerSentEventParser {
    private var buffer = Data()

    /// The three blank-line forms the SSE grammar allows, longest first so a
    /// `\r\n\r\n` is never mistaken for a `\r\r` starting at the same offset.
    ///
    /// Matching only `\n\n` looks fine against a hand-written fixture and fails
    /// completely against a real CRLF stream: no boundary is ever found, every
    /// event accumulates in the buffer, and the whole response finally emerges
    /// from `finish()` as one malformed payload that decodes to nothing. Swift
    /// hides this at the line level — it models `\r\n` as a single `Character`,
    /// so line splitting is already correct — which is exactly why the byte-level
    /// boundary scan needs saying out loud.
    private static let boundaries = ["\r\n\r\n", "\n\n", "\r\r"].map { Data($0.utf8) }

    mutating func consume(_ data: Data) -> [String] {
        buffer.append(data)
        var payloads: [String] = []
        while let boundary = nextBoundary() {
            let block = buffer[buffer.startIndex..<boundary.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<boundary.upperBound)
            if let payload = Self.payload(in: block) {
                payloads.append(payload)
            }
        }
        return payloads
    }

    /// The earliest blank line in the buffer, whichever form it takes.
    private func nextBoundary() -> Range<Data.Index>? {
        var earliest: Range<Data.Index>?
        for candidate in Self.boundaries {
            guard let found = buffer.firstRange(of: candidate) else { continue }
            if let current = earliest {
                if found.lowerBound < current.lowerBound {
                    earliest = found
                } else if found.lowerBound == current.lowerBound,
                          found.upperBound > current.upperBound {
                    earliest = found
                }
            } else {
                earliest = found
            }
        }
        return earliest
    }

    /// Flush a trailing event that arrived without its blank-line terminator,
    /// which is what a server that closes the connection right after the last
    /// frame produces.
    mutating func finish() -> [String] {
        defer { buffer = Data() }
        guard let payload = Self.payload(in: buffer[...]) else { return [] }
        return [payload]
    }

    private static func payload(in block: Data) -> String? {
        let text = String(decoding: block, as: UTF8.self)
        var lines: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            var value = line.dropFirst("data:".count)
            if value.hasPrefix(" ") { value = value.dropFirst() }
            lines.append(String(value))
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
