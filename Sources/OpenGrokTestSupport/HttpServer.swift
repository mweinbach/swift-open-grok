// HttpServer.swift
//
// Minimal HTTP/1.1 socket server for the mock inference and counting test
// servers. The Rust reference uses `axum` + `tokio::net::TcpListener`; the
// Swift port uses `Network.framework` (`NWListener`) on Apple platforms and
// BSD sockets on Linux/Windows. This is test-only infrastructure — no
// production code depends on it.
//
// The server is a single-threaded-per-connection accept loop that parses
// HTTP/1.1 request lines + headers + (Content-Length) bodies and hands them
// to a `HttpRequestHandler`. The handler returns an `HttpResponse` which the
// server serializes back to the wire. SSE responses are supported via
// `HttpResponse.body.chunked` (the mock server uses this to stream SSE
// events). Keep-alive is honored: the server loops on a connection until the
// client closes or sends a `Connection: close` header.

import Foundation
#if canImport(Network)
import Network
#endif

/// A parsed HTTP/1.1 request.
public struct HttpRequest: Sendable {
    public let method: String
    /// The full path including query string (e.g. `/v1/user?include=subscription`).
    public let path: String
    /// The path component without the query string.
    public let pathOnly: String
    /// The query string (e.g. `include=subscription`), or empty.
    public let query: String
    public let headers: [(String, String)]
    public let body: Data
    /// The raw header block as received (for the counting server's log).
    public let rawHead: String

    /// First value of `name` (case-insensitive), if the request carried it.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }

    /// The `Authorization` header value, if present.
    public var authorization: String? { header("Authorization") }

    /// Parse the request body as JSON.
    public func jsonBody() -> JSONValue? {
        try? JSONValue.decode(body)
    }
}

/// An HTTP response.
public struct HttpResponse: Sendable {
    public let status: UInt16
    public let headers: [(String, String)]
    public let body: HttpResponseBody

    public init(status: UInt16, headers: [(String, String)] = [], body: HttpResponseBody) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A plain text/JSON body served in one shot.
    public static func json(status: UInt16, _ value: JSONValue) -> HttpResponse {
        let bytes = (try? value.encode()) ?? Data()
        return HttpResponse(
            status: status,
            headers: [("content-type", "application/json")],
            body: .bytes(bytes)
        )
    }

    /// A raw text body served verbatim.
    public static func text(status: UInt16, _ string: String) -> HttpResponse {
        HttpResponse(
            status: status,
            headers: [("content-type", "text/plain; charset=utf-8")],
            body: .bytes(Data(string.utf8))
        )
    }

    /// A 404 with an empty body.
    public static let notFound = HttpResponse(status: 404, body: .bytes(Data()))

    /// A 401 with a JSON error body.
    public static func unauthorized(_ message: String = "Unauthorized") -> HttpResponse {
        .json(status: 401, .object([("error", .string(message))]))
    }

    /// The `Content-Length` / `Transfer-Encoding` header to emit for this
    /// response, derived from `body`.
    var transferHeaders: [(String, String)] {
        switch body {
        case .bytes:
            return []
        case .sse, .ssePaced:
            return [("content-type", "text/event-stream"), ("cache-control", "no-cache")]
        }
    }
}

/// The body of an `HttpResponse`.
public enum HttpResponseBody: Sendable {
    /// A fixed byte buffer served in one shot (with `Content-Length`).
    case bytes(Data)
    /// An SSE body: a list of `SseEvent`s streamed with `text/event-stream`.
    /// Each event is rendered and flushed; the connection closes after the
    /// last event.
    case sse([SseEvent])
    /// An SSE body with a pacing/hold config: each event is emitted after
    /// `config.delay` seconds, and the terminal event is held until
    /// `config.gate` is released (if non-nil). Used by the mock inference
    /// server to model `set_chunk_delay` and `hold_agent_completions`.
    case ssePaced([SseEvent], SseStreamConfig)
}

/// Streaming SSE config: optional per-event delay and an optional
/// completion gate that holds the terminal event. Mirrors the Rust
/// `paced_events` `delay` + `gate` parameters.
public struct SseStreamConfig: Sendable {
    /// Per-event delay (seconds). `nil` streams instantly.
    public var delay: TimeInterval?
    /// Optional gate invoked before the terminal event; the event is emitted
    /// only after the gate is released.
    public var gate: SseCompletionGate?

    public init(delay: TimeInterval? = nil, gate: SseCompletionGate? = nil) {
        self.delay = delay
        self.gate = gate
    }
}

/// A completion gate that holds an SSE stream's terminal event until
/// released. Conformers must be `Sendable` and idempotent under concurrent
/// `wait`/`release` calls. Used by `MockInferenceServer.holdAgentCompletions`.
public protocol SseCompletionGate: Sendable {
    /// Block the calling thread while the gate is held. Returns immediately
    /// when the gate is not held or has been released.
    func waitIfHeld()
}

/// A handler for HTTP requests. Returns the response to send back. The
/// handler is called on the server's connection queue; it must be
/// `Sendable`. The `request` is owned (no shared mutable state with the
/// server).
public protocol HttpRequestHandler: Sendable {
    func handle(_ request: HttpRequest) -> HttpResponse
}

/// A minimal HTTP/1.1 server bound to `127.0.0.1:0` (ephemeral port).
///
/// `HttpServer` is `Sendable` via an internal lock on the listener lifecycle.
/// `start()` returns the bound URL; `stop()` (called on `deinit`) closes the
/// listener and severs active connections.
public final class HttpServer: @unchecked Sendable {
    /// The base URL, e.g. `http://127.0.0.1:54321/v1`. Available after
    /// `start()`.
    public private(set) var baseURL: String = ""

    private let handler: HttpRequestHandler
    private let basePath: String
    #if canImport(Network)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "opengrok-test-http-server")
    #elseif !os(Windows)
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    #endif
    private let lifecycleLock = NSLock()
    private var stopped = false

    /// Create a server that serves `handler` under `basePath`.
    /// `basePath` is prepended to the URL returned by `baseURL` and is the
    /// path prefix the mock server's `url()` reports (e.g. `/v1`).
    public init(handler: HttpRequestHandler, basePath: String) {
        self.handler = handler
        self.basePath = basePath
    }

    /// Start listening on `127.0.0.1:0`. Throws on bind failure.
    public func start() throws {
        #if canImport(Network)
        try startWithNetwork()
        #elseif os(Windows)
        // Same reasoning as CountingServer: the backend below is POSIX-only,
        // and a Windows port belongs on the WinSock path COpenGrokSockets
        // already implements. Refused by name so a Windows test fails saying
        // so instead of timing out against a URL nothing ever served.
        throw HttpServerError.unsupportedPlatform
        #else
        try startWithSockets()
        #endif
    }

    /// Stop accepting and sever active connections. Idempotent.
    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !stopped else { return }
        stopped = true
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        #elseif !os(Windows)
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        acceptThread = nil
        #endif
    }

    deinit { stop() }

    #if canImport(Network)
    private func startWithNetwork() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(
            using: params,
            on: .any
        )
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        // Wait synchronously for the listener to be ready so `baseURL` is
        // populated when `start()` returns. The mock server's Rust source
        // does a 5s readiness probe; we use a dispatch semaphore.
        let ready = DispatchSemaphore(value: 0)
        let box = BoundURLBox()
        let basePath = self.basePath
        let stateHandler: @Sendable (NWListener.State) -> Void = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    box.url = "http://127.0.0.1:\(port)\(basePath)"
                }
                ready.signal()
            case .failed:
                ready.signal()
            default: break
            }
        }
        listener.stateUpdateHandler = stateHandler
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw HttpServerError.startupTimeout
        }
        self.baseURL = box.url
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(on: conn)
    }

    private func readRequest(on conn: NWConnection) {
        // Read up to the header terminator `\r\n\r\n`.
        readUntilHeaderEnd(on: conn, buffer: Data()) { [weak self] headBytes, rest in
            guard let self, let headBytes else { return }
            self.processHead(headBytes, rest: rest, on: conn)
        }
    }

    private func readUntilHeaderEnd(
        on conn: NWConnection,
        buffer: Data,
        completion: @escaping @Sendable (Data?, Data) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                _ = error
                completion(nil, Data())
                return
            }
            guard let data else {
                if buffer.isEmpty {
                    completion(nil, Data())
                } else {
                    completion(nil, buffer)
                }
                return
            }
            var combined = buffer
            combined.append(data)
            if let range = combined.range(of: Data("\r\n\r\n".utf8)) {
                let headEnd = range.upperBound
                let head = combined.prefix(upTo: headEnd)
                let rest = combined.suffix(from: headEnd)
                completion(Data(head), Data(rest))
            } else {
                // Header not yet complete; keep reading.
                self.readUntilHeaderEnd(on: conn, buffer: combined, completion: completion)
            }
        }
    }

    private func processHead(_ headBytes: Data, rest: Data, on conn: NWConnection) {
        guard let headString = String(data: headBytes, encoding: .utf8) else {
            conn.cancel()
            return
        }
        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            conn.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            conn.cancel()
            return
        }
        let method = String(parts[0])
        let fullPath = String(parts[1])
        let (pathOnly, query) = splitPath(fullPath)
        var headersBuilder: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headersBuilder.append((name, value))
            }
        }
        let headers = headersBuilder
        let contentLength = headers.first(where: { $0.0.lowercased() == "content-length" })?.1
        let expectedBody = Int(contentLength ?? "0") ?? 0
        if rest.count >= expectedBody {
            let body = rest.prefix(expectedBody)
            let request = HttpRequest(
                method: method, path: fullPath, pathOnly: pathOnly, query: query,
                headers: headers, body: Data(body), rawHead: headString
            )
            self.serve(request, on: conn)
        } else {
            // Read the remaining body bytes.
            let remaining = expectedBody - rest.count
            conn.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, _, error in
                guard let self else { return }
                if error != nil { conn.cancel(); return }
                var body = rest
                if let data { body.append(data) }
                let request = HttpRequest(
                    method: method, path: fullPath, pathOnly: pathOnly, query: query,
                    headers: headers, body: body, rawHead: headString
                )
                self.serve(request, on: conn)
            }
        }
    }

    private func serve(_ request: HttpRequest, on conn: NWConnection) {
        let response = handler.handle(request)
        writeResponse(response, on: conn)
    }

    private func writeResponse(_ response: HttpResponse, on conn: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(httpStatusText(response.status))\r\n"
        var allHeaders = response.transferHeaders + response.headers
        switch response.body {
        case .bytes(let data):
            allHeaders.append(("content-length", "\(data.count)"))
        case .sse, .ssePaced:
            // SSE: chunked or close-delimited. We use close-delimited (no
            // Transfer-Encoding) — the connection closes after the last event.
            allHeaders.append(("connection", "close"))
        }
        // Always send `Connection: close` for byte responses too: this is a
        // test-only server that does not implement keep-alive, so each
        // response ends the connection. Without this header, URLSession
        // assumes keep-alive and retries on the closed socket — surfacing as
        // `NSURLErrorNetworkConnectionLost` (-1005) on the next request.
        // SSE responses already set `connection: close` above; for bytes we
        // add it here unless the caller explicitly overrode it.
        if case .bytes = response.body,
           !allHeaders.contains(where: { $0.0.lowercased() == "connection" }) {
            allHeaders.append(("connection", "close"))
        }
        // Always send a Server header so wire tests can identify the mock.
        allHeaders.append(("server", "opengrok-test-mock/1.0"))
        for (k, v) in allHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        switch response.body {
        case .bytes(let data):
            payload.append(data)
            conn.send(content: payload, completion: .contentProcessed { _ in
                conn.cancel()
            })
        case .sse(let events):
            // Send the head first, then stream events one at a time.
            conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
                self?.streamSSE(events, on: conn)
            })
        case .ssePaced(let events, let config):
            // Send the head first, then stream events one at a time with the
            // configured per-event delay and terminal-event gate.
            conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
                self?.streamSSEPaced(events, config: config, on: conn)
            })
        }
    }

    private func streamSSE(_ events: [SseEvent], on conn: NWConnection) {
        guard !events.isEmpty else {
            conn.cancel()
            return
        }
        let first = events[0]
        let rest = Array(events.dropFirst())
        let chunk = Data(first.render().utf8)
        conn.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            self?.streamSSE(rest, on: conn)
        })
    }

    /// Stream SSE events with optional per-event delay and an optional
    /// terminal-event gate. The gate is waited on ONLY before the last event
    /// (the SSE terminator), so a held gate keeps the turn streaming-but-not-
    /// complete until released. Mirrors `mock_server::paced_events`.
    private func streamSSEPaced(_ events: [SseEvent], config: SseStreamConfig, on conn: NWConnection) {
        guard !events.isEmpty else {
            conn.cancel()
            return
        }
        let lastIndex = events.count - 1
        let delay = config.delay
        let gate = config.gate
        // Pre-wait on the gate before the terminal event: do this synchronously
        // on the queue, since `streamSSEPaced` is already on the connection
        // queue. The wait is bounded by the gate's release semantics (a test
        // calls `releaseAgentCompletions` to unblock).
        if lastIndex == 0, let gate {
            gate.waitIfHeld()
        }
        if let delay {
            // Synchronous sleep on the dispatch queue — the connection queue
            // is dedicated to this server and the delay is short (test-only).
            Thread.sleep(forTimeInterval: delay)
        }
        let first = events[0]
        let rest = Array(events.dropFirst())
        let chunk = Data(first.render().utf8)
        conn.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            // Re-enter with the remaining events; the gate is consulted again
            // before what is now the terminal event.
            self?.streamSSEPaced(rest, config: config, on: conn)
        })
    }
    #endif // canImport(Network)

    #if !canImport(Network) && !os(Windows)
    private func startWithSockets() throws {
        // BSD socket implementation for Linux/Windows.
        listenFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        if listenFD < 0 { throw HttpServerError.bindFailed }
        var reuse: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound < 0 { throw HttpServerError.bindFailed }
        if listen(listenFD, 128) < 0 { throw HttpServerError.bindFailed }
        // Get the bound port.
        var resolved = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        // Read the port back through `ptr`, not through `resolved`: naming the
        // variable inside the closure is a second access overlapping the
        // exclusive one `withUnsafeMutablePointer` already holds.
        let port = withUnsafeMutablePointer(to: &resolved) { ptr -> UInt16? in
            let rc = ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(listenFD, sa, &len)
            }
            guard rc == 0 else { return nil }
            return UInt16(bigEndian: ptr.pointee.sin_port)
        }
        guard let port, port != 0 else { throw HttpServerError.bindFailed }
        baseURL = "http://127.0.0.1:\(port)\(basePath)"
        // Accept loop on a background thread.
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
        acceptThread = thread
    }

    private func acceptLoop() {
        while !stopped {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }
            // Handle synchronously (test server: low throughput is fine).
            handleBSDClient(client)
        }
    }

    private func handleBSDClient(_ fd: Int32) {
        // Read until \r\n\r\n.
        var buffer = Data()
        var head: Data?
        while true {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n <= 0 { close(fd); return }
            buffer.append(byte)
            if buffer.count >= 4 {
                let tail = buffer.suffix(4)
                if String(data: tail, encoding: .utf8) == "\r\n\r\n" {
                    head = buffer
                    break
                }
            }
        }
        guard let headBytes = head, let headString = String(data: headBytes, encoding: .utf8) else {
            close(fd); return
        }
        // Parse head (same as Network path).
        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(fd); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { close(fd); return }
        let method = String(parts[0])
        let fullPath = String(parts[1])
        let (pathOnly, query) = splitPath(fullPath)
        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name, value))
            }
        }
        let contentLength = Int(headers.first(where: { $0.0.lowercased() == "content-length" })?.1 ?? "0") ?? 0
        var body = Data()
        while body.count < contentLength {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            body.append(byte)
        }
        let request = HttpRequest(
            method: method, path: fullPath, pathOnly: pathOnly, query: query,
            headers: headers, body: body, rawHead: headString
        )
        let response = handler.handle(request)
        writeBSDResponse(response, fd: fd)
        close(fd)
    }

    private func writeBSDResponse(_ response: HttpResponse, fd: Int32) {
        var head = "HTTP/1.1 \(response.status) \(httpStatusText(response.status))\r\n"
        var allHeaders = response.transferHeaders + response.headers
        switch response.body {
        case .bytes(let data): allHeaders.append(("content-length", "\(data.count)"))
        case .sse, .ssePaced: allHeaders.append(("connection", "close"))
        }
        // Always send `Connection: close` for byte responses too: this is a
        // test-only server that does not implement keep-alive. See the
        // Network path for the rationale.
        if case .bytes = response.body,
           !allHeaders.contains(where: { $0.0.lowercased() == "connection" }) {
            allHeaders.append(("connection", "close"))
        }
        allHeaders.append(("server", "opengrok-test-mock/1.0"))
        for (k, v) in allHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        _ = head.withCString { ptr -> Int in write(fd, ptr, strlen(ptr)) }
        switch response.body {
        case .bytes(let data):
            _ = data.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress, data.count)
            }
        case .sse(let events):
            for e in events {
                let rendered = e.render()
                _ = rendered.withCString { ptr -> Int in write(fd, ptr, strlen(ptr)) }
            }
        case .ssePaced(let events, let config):
            // Stream events with per-event delay and terminal-event gate.
            // BSD path is synchronous (single-threaded accept loop), so the
            // sleep and gate wait block the connection thread directly.
            let lastIndex = events.count - 1
            for (i, e) in events.enumerated() {
                if i == lastIndex, let gate = config.gate {
                    gate.waitIfHeld()
                }
                if let delay = config.delay {
                    Thread.sleep(forTimeInterval: delay)
                }
                let rendered = e.render()
                _ = rendered.withCString { ptr -> Int in write(fd, ptr, strlen(ptr)) }
            }
        }
    }
    #endif // !canImport(Network) && !os(Windows)
}

/// Errors thrown by `HttpServer`.
public enum HttpServerError: Error, Equatable {
    case startupTimeout
    case bindFailed
    /// No loopback server backend for this platform. Distinct from
    /// `bindFailed` on purpose: a test that hits this has not found a busy
    /// port, it is running somewhere the harness was never ported to, and
    /// reporting it as a bind failure would send the reader hunting a
    /// nonexistent port conflict.
    case unsupportedPlatform
}

/// Lock-protected box for the bound URL, so the `@Sendable` state handler can
/// write it without crossing actor isolation.
private final class BoundURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: String = ""
    var url: String {
        get { lock.lock(); defer { lock.unlock() }; return _url }
        set { lock.lock(); defer { lock.unlock() }; _url = newValue }
    }
}

/// Split `/path?query` into (`/path`, `query`).
private func splitPath(_ fullPath: String) -> (String, String) {
    if let q = fullPath.firstIndex(of: "?") {
        let path = String(fullPath[..<q])
        let query = String(fullPath[fullPath.index(after: q)...])
        return (path, query)
    }
    return (fullPath, "")
}

/// RFC 7231 reason phrases for the common status codes.
public func httpStatusText(_ status: UInt16) -> String {
    switch status {
    case 200: return "OK"
    case 201: return "Created"
    case 204: return "No Content"
    case 301: return "Moved Permanently"
    case 302: return "Found"
    case 304: return "Not Modified"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 408: return "Request Timeout"
    case 409: return "Conflict"
    case 413: return "Payload Too Large"
    case 429: return "Too Many Requests"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    case 504: return "Gateway Timeout"
    default: return "Unknown"
    }
}
