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
// not a sampling turn: its final input is a `compaction_trigger`, it carries
// a beta header, and its streamed response is a single
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
public final class HTTPCodexCompactionTransport: CodexUnaryCompactionTransport, @unchecked Sendable {
    private let transport: any HTTPTransport
    private let baseURL: String
    private let model: String
    private let queryParams: [String: String]
    private let cacheAffinityID: String?
    private let requestPolicy: ResponsesRequestPolicy
    private let lock = NSLock()
    private var headers: [String: String]

    public init(
        transport: any HTTPTransport,
        baseURL: String,
        model: String,
        headers: [String: String],
        queryParams: [String: String] = [:],
        cacheAffinityID: String? = nil,
        requestPolicy: ResponsesRequestPolicy = ResponsesRequestPolicy()
    ) {
        self.transport = transport
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.model = model
        self.headers = headers
        self.queryParams = queryParams
        self.cacheAffinityID = cacheAffinityID
        self.requestPolicy = requestPolicy
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
        guard request.protocolVersion == .remoteV2 else {
            throw CodexCompactionTransportError.transport(
                "legacy Codex compaction requires the unary response transport"
            )
        }
        let httpRequest = try makeRequest(request)

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
        try Self.validateResponse(status: status, body: errorBody)
    }

    public func compactLegacy(_ request: CodexCompactionRequest) async throws -> [ConversationItem] {
        guard request.protocolVersion == .legacyUnary else {
            throw CodexCompactionTransportError.transport(
                "streaming Codex compaction cannot use the unary response transport"
            )
        }

        let response = try await transport.send(makeRequest(request))
        try Self.validateResponse(status: response.metadata.statusCode, body: response.body)

        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: response.body)
        } catch {
            throw CodexCompactionTransportError.transport(
                "could not decode the Codex compact response: \(error)"
            )
        }
        guard let output = value["output"]?.arrayValue,
              let history = codexCompactOutputToConversationItems(output),
              !history.isEmpty
        else {
            throw CodexCompactionTransportError.transport(
                "Codex compact response contained no replacement history"
            )
        }
        return history
    }

    private static func validateResponse(status: Int, body: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let message = Self.errorMessage(from: body)
        if status == 401 || status == 403 {
            throw CodexCompactionTransportError.authentication(status: status)
        }
        throw CodexCompactionTransportError.http(status: status, message: message)
    }

    private func makeRequest(_ request: CodexCompactionRequest) throws -> HTTPRequest {
        let basePath = URL(string: baseURL)?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpointPrefix = basePath.isEmpty ? "/v1" : ""
        guard let endpoint = URL(string: baseURL + endpointPrefix + request.endpointPath) else {
            throw CodexCompactionTransportError.transport("invalid Codex endpoint: \(baseURL)\(request.endpointPath)")
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        if !queryParams.isEmpty {
            var items = components?.queryItems ?? []
            items.append(contentsOf: queryParams.keys.sorted().compactMap { name in
                queryParams[name].map { URLQueryItem(name: name, value: $0) }
            })
            components?.queryItems = items
        }
        guard let url = components?.url else {
            throw CodexCompactionTransportError.transport("invalid Codex endpoint query parameters")
        }

        var wireHeaders = currentHeaders()
        let adapter = providerAdapter(.codex)
        adapter.sanitizeHeaders(&wireHeaders)
        wireHeaders = wireHeaders.filter { name, _ in
            let normalized = name.lowercased()
            return normalized != X_CODEX_TURN_METADATA_HEADER
                && normalized != CODEX_SESSION_ID_HEADER
                && normalized != CODEX_THREAD_ID_HEADER
                && normalized != CODEX_CLIENT_REQUEST_ID_HEADER
        }
        adapter.applySessionAffinityHeaders(
            &wireHeaders,
            sessionId: cacheAffinityID ?? requestPolicy.sessionID
        )
        wireHeaders["Content-Type"] = "application/json"
        wireHeaders["Accept"] = request.protocolVersion == .remoteV2
            ? "text/event-stream"
            : "application/json"
        for header in request.headers {
            if header.name.lowercased() == "x-codex-beta-features" {
                Self.mergeBetaFeature(header.value, into: &wireHeaders)
            } else {
                wireHeaders[header.name] = header.value
            }
        }

        let projected = try projectBody(request)
        if let metadata = projected["client_metadata"]?[X_CODEX_TURN_METADATA_HEADER]?.stringValue {
            wireHeaders[X_CODEX_TURN_METADATA_HEADER] = metadata
        }

        return HTTPRequest(
            method: .post,
            url: url,
            headers: wireHeaders,
            body: try encodeProjectedBody(projected),
            idempotency: .nonIdempotent
        )
    }

    private static func mergeBetaFeature(_ feature: String, into headers: inout [String: String]) {
        let matchingNames = headers.keys.filter { $0.lowercased() == "x-codex-beta-features" }
        var features: [String] = []
        for name in matchingNames {
            if let value = headers.removeValue(forKey: name) {
                for component in value.split(separator: ",") {
                    let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !features.contains(trimmed) {
                        features.append(trimmed)
                    }
                }
            }
        }
        if !features.contains(feature) { features.append(feature) }
        headers["x-codex-beta-features"] = features.joined(separator: ",")
    }

    func encodeBody(_ request: CodexCompactionRequest) throws -> Data {
        try encodeProjectedBody(projectBody(request))
    }

    private func projectBody(_ request: CodexCompactionRequest) throws -> JSONValue {
        // The history must go on the wire in the Responses shape, not in
        // `ConversationItem`'s own Codable form — that encoding is the on-disk
        // session format, and the two are not the same. Reusing the sampler's
        // projection is what keeps a compaction request's `input` identical to
        // the `input` a normal turn sends, which matters because the server
        // validates the compaction against the same conversation it would
        // sample from.
        let projected = projectResponsesRequestBody(
            ConversationRequest(
                items: request.input,
                model: model,
                xGrokSessionId: cacheAffinityID ?? requestPolicy.sessionID,
                xGrokTurnIdx: requestPolicy.turnID,
                reasoningEffort: requestPolicy.localEffort,
                serviceTier: request.serviceTier
            ),
            model: model,
            policy: requestPolicy,
            adapter: providerAdapter(.codex),
            applyResponseDefaults: request.protocolVersion == .remoteV2
        )
        guard case .object(var body) = projected else {
            throw CodexCompactionTransportError.transport("could not project the Codex compaction input")
        }

        body["parallel_tool_calls"] = .bool(true)
        if let instructions = request.instructions { body["instructions"] = .string(instructions) }
        if let cacheKey = request.promptCacheKey { body["prompt_cache_key"] = .string(cacheKey) }
        if !request.tools.isEmpty { body["tools"] = .array(request.tools) }
        if let reasoning = request.reasoning { body["reasoning"] = reasoning }

        let allowedFields: Set<String>
        switch request.protocolVersion {
        case .remoteV2:
            body["store"] = .bool(false)
            body["stream"] = .bool(true)
            if body["tool_choice"] == nil || body["tool_choice"] == .null {
                body["tool_choice"] = .string("auto")
            }
            var input = body["input"]?.arrayValue ?? []
            input.append(.object(["type": .string("compaction_trigger")]))
            body["input"] = .array(input)
            allowedFields = [
                "model", "input", "instructions", "tools", "tool_choice",
                "parallel_tool_calls", "reasoning", "service_tier", "prompt_cache_key",
                "text", "include", "store", "stream", "client_metadata",
            ]
        case .legacyUnary:
            allowedFields = [
                "model", "input", "instructions", "tools", "parallel_tool_calls",
                "reasoning", "service_tier", "prompt_cache_key", "text", "client_metadata",
            ]
        }
        body = body.filter { allowedFields.contains($0.key) }
        return .object(body)
    }

    private func encodeProjectedBody(_ body: JSONValue) throws -> Data {
        do {
            return try WireJSONEncoder.make().encode(body)
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
