// CountingServer.swift
//
// Port of `xai-grok-test-support/src/counting_server.rs`. A minimal
// keep-alive HTTP/1.1 server: counts accepted TCP connections (not requests)
// and records each request's header block, for wire-level tests that assert
// TCP connection reuse (e.g. shared-client pooling).
//
// Per the Rust reference, the accept counter increments EXACTLY ONCE per
// accepted socket, then the same socket is reused for as many keep-alive
// requests as the client sends. This is the helper that proves a client
// implementation pools connections rather than opening a new socket per
// request. Routing it through the close-after-one-response `HttpServer`
// would defeat the purpose — this server has its own accept loop and its
// own per-connection keep-alive read/write loop.

import Foundation
#if canImport(Network)
import Network
#endif

/// Lock-protected state for the counting server.
private final class CountingState: @unchecked Sendable {
    private let acceptsLock = NSLock()
    private var accepts: UInt32 = 0
    private let headsLock = NSLock()
    private var heads: [String] = []

    @discardableResult
    func bumpAccepts() -> UInt32 {
        acceptsLock.lock()
        defer { acceptsLock.unlock() }
        accepts &+= 1
        return accepts
    }

    func acceptsValue() -> UInt32 {
        acceptsLock.lock()
        defer { acceptsLock.unlock() }
        return accepts
    }

    func recordHead(_ head: String) {
        headsLock.lock()
        defer { headsLock.unlock() }
        heads.append(head)
    }

    func headsSnapshot() -> [String] {
        headsLock.lock()
        defer { headsLock.unlock() }
        return heads
    }
}

/// The result of spawning a counting server: the base URL, the accept
/// counter, and the recorded header blocks.
public struct CountingServer: Sendable {
    public let baseURL: String
    public let accepts: UInt32Provider
    public let heads: HeadsProvider
}

/// A sendable provider for the accept count.
public protocol UInt32Provider: Sendable {
    func value() -> UInt32
}

/// A sendable provider for the recorded header blocks.
public protocol HeadsProvider: Sendable {
    func value() -> [String]
}

/// Spawn a connection-counting HTTP/1.1 server on `127.0.0.1:0`. Returns
/// the base URL plus the accept counter and header-block log.
///
/// The accept counter increments exactly once per accepted TCP connection
/// (not per request): the server keeps each socket open and serves multiple
/// requests over it, mirroring the Rust `spawn_counting_server`. The
/// response is always `200 OK` with `{}` and a `Content-Length: 2` header;
/// `Connection: keep-alive` is sent so well-behaved clients reuse the
/// socket. A `Connection: close` request header closes the socket after
/// the response.
@discardableResult
public func spawnCountingServer() throws -> CountingServer {
    let state = CountingState()
    let server = CountingServerImpl(state: state, basePath: "/v1")
    try server.start()
    // Keep the server alive until the test exits by leaking it via the
    // registry — mirrors the Rust source's `tokio::spawn` keeping the task
    // alive for the process lifetime. Tests are short-lived and the OS
    // reclaims the port on process exit.
    CountingServerRegistry.shared.register(server)

    let acceptsProvider = CountingAcceptsProvider(state: state)
    let headsProvider = CountingHeadsProvider(state: state)
    return CountingServer(
        baseURL: server.baseURL,
        accepts: acceptsProvider,
        heads: headsProvider
    )
}

/// A registry that keeps spawned counting servers alive for the test's
/// lifetime. `@unchecked Sendable` via internal `NSLock`.
private final class CountingServerRegistry: @unchecked Sendable {
    static let shared = CountingServerRegistry()
    private let lock = NSLock()
    private var servers: [CountingServerImpl] = []

    func register(_ server: CountingServerImpl) {
        lock.lock()
        defer { lock.unlock() }
        servers.append(server)
    }
}

private struct CountingAcceptsProvider: UInt32Provider {
    let state: CountingState
    func value() -> UInt32 { state.acceptsValue() }
}

private struct CountingHeadsProvider: HeadsProvider {
    let state: CountingState
    func value() -> [String] { state.headsSnapshot() }
}

/// The counting server implementation. Dedicated accept + per-connection
/// keep-alive loop, independent of `HttpServer` (which always closes after
/// one response and cannot validate connection pooling).
private final class CountingServerImpl: @unchecked Sendable {
    var baseURL: String = ""
    private let state: CountingState
    private let basePath: String
    #if canImport(Network)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "opengrok-counting-server")
    #else
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    #endif
    private let lifecycleLock = NSLock()
    private var stopped = false

    init(state: CountingState, basePath: String) {
        self.state = state
        self.basePath = basePath
    }

    func start() throws {
        #if canImport(Network)
        try startWithNetwork()
        #else
        try startWithSockets()
        #endif
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !stopped else { return }
        stopped = true
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        #else
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
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
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
        // Increment EXACTLY ONCE per accepted socket. This is the
        // keep-alive-aware counter the Rust reference exposes.
        _ = state.bumpAccepts()
        readKeepAliveRequest(on: conn, buffer: Data())
    }

    /// Read one full request (head + Content-Length body) from `conn`,
    /// record the head, respond `200 OK` with `{}`, then loop for the next
    /// keep-alive request on the same connection. Closes on EOF, error,
    /// or `Connection: close`.
    private func readKeepAliveRequest(on conn: NWConnection, buffer: Data) {
        readUntilHeaderEnd(on: conn, buffer: buffer) { [weak self] headBytes, rest in
            guard let self, let headBytes else {
                conn.cancel()
                return
            }
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
            if error != nil {
                completion(nil, Data())
                return
            }
            guard let data else {
                if buffer.isEmpty {
                    completion(nil, Data())
                } else {
                    // Partial head with EOF before \r\n\r\n: treat as closed.
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
                self.readUntilHeaderEnd(on: conn, buffer: combined, completion: completion)
            }
        }
    }

    private func processHead(_ headBytes: Data, rest: Data, on conn: NWConnection) {
        guard let headString = String(data: headBytes, encoding: .utf8) else {
            conn.cancel()
            return
        }
        state.recordHead(headString)
        let lines = headString.components(separatedBy: "\r\n")
        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { return nil }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return Int(value)
        }.first ?? 0
        let connectionClose = lines.dropFirst().contains { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces).lowercased()
            return name == "connection" && value.contains("close")
        }
        // Read the request body if it has not yet arrived in `rest`.
        if rest.count >= contentLength {
            respondAndLoop(close: connectionClose, on: conn)
        } else {
            let remaining = contentLength - rest.count
            conn.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, _, error in
                guard let self else { return }
                if error != nil { conn.cancel(); return }
                self.respondAndLoop(close: connectionClose, on: conn)
            }
        }
    }

    private func respondAndLoop(close: Bool, on conn: NWConnection) {
        // The canonical counting-server response: 200 OK, Content-Length: 2,
        // `{}`. Keep-alive unless the client asked to close.
        let connectionHeader = close ? "close" : "keep-alive"
        let head = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: \(connectionHeader)\r\nserver: opengrok-test-mock/1.0\r\n\r\n{}"
        let payload = Data(head.utf8)
        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if close {
                conn.cancel()
                return
            }
            // Loop for the next request on the same socket — this is what
            // makes the accept counter meaningful: N requests over one
            // retained socket = 1 accept.
            self.readKeepAliveRequest(on: conn, buffer: Data())
        })
    }
    #endif // canImport(Network)

    #if !canImport(Network)
    private func startWithSockets() throws {
        listenFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        if listenFD < 0 { throw HttpServerError.bindFailed }
        var reuse: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound < 0 { throw HttpServerError.bindFailed }
        if listen(listenFD, 128) < 0 { throw HttpServerError.bindFailed }
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
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
        acceptThread = thread
    }

    private func acceptLoop() {
        while !stopped {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }
            // Increment exactly once per accepted socket.
            _ = state.bumpAccepts()
            // Pump the keep-alive loop on a fresh thread so the accept loop
            // can keep accepting other clients.
            let thread = Thread { [weak self] in self?.handleBSDClient(client) }
            thread.start()
        }
    }

    private func handleBSDClient(_ fd: Int32) {
        var buffer = Data()
        while !stopped {
            // Read until \r\n\r\n.
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
            state.recordHead(headString)
            let lines = headString.components(separatedBy: "\r\n")
            let contentLength = Int(lines.dropFirst().compactMap { line -> Int? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                guard name == "content-length" else { return nil }
                return Int(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)) ?? 0
            }.first ?? 0)
            let connectionClose = lines.dropFirst().contains { line in
                guard let colon = line.firstIndex(of: ":") else { return false }
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces).lowercased()
                return name == "connection" && value.contains("close")
            }
            // Read the body.
            buffer = Data()
            while buffer.count < contentLength {
                var byte: UInt8 = 0
                let n = read(fd, &byte, 1)
                if n <= 0 { break }
                buffer.append(byte)
            }
            let connectionHeader = connectionClose ? "close" : "keep-alive"
            // The canonical counting-server response: 200 OK,
            // Content-Length: 2, `{}`. The response string ALREADY ends
            // with `{}` — the previous implementation wrote the full
            // response string AND then wrote a separate `{}` body, sending
            // the JSON body TWICE. The extra two bytes remained on the
            // keep-alive connection and corrupted parsing of the next HTTP
            // response. Now we write the complete response (header + body)
            // exactly once using a write-all loop that handles partial
            // writes.
            let response = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: \(connectionHeader)\r\nserver: opengrok-test-mock/1.0\r\n\r\n{}"
            let wrote = response.withCString { ptr -> Bool in
                writeAll(fd: fd, bytes: ptr, count: strlen(ptr))
            }
            // A short write leaves a truncated response framed on a keep-alive
            // connection, which corrupts the *next* response the client parses.
            // Drop the connection instead so the failure is local.
            if !wrote || connectionClose { close(fd); return }
        }
        close(fd)
    }
    #endif // !canImport(Network)
}

/// Write all `count` bytes from `ptr` to `fd`, retrying partial writes.
/// Returns true on success, false on error. Used by the BSD (non-Network)
/// counting-server implementation to ensure the complete HTTP response is
/// written exactly once, even if the kernel only accepts part of it per
/// `write` syscall.
#if !canImport(Network)
@inline(__always)
private func writeAll(fd: Int32, bytes: UnsafePointer<CChar>, count: Int) -> Bool {
    var sent = 0
    while sent < count {
        let n = Foundation.write(fd, bytes.advanced(by: sent), count - sent)
        if n <= 0 { return false }
        sent += n
    }
    return true
}
#endif

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
