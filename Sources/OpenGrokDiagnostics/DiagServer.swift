// DiagServer.swift
//
// In-guest diagnostics HTTP server (/ready, /statusz, /logs) for the
// standalone workspace-server. Swift port of `xai-grok-diag-server`.

import Foundation

#if canImport(Network)
import Network
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DiagServerError: Error, CustomStringConvertible {
    case bindFailed(String)
    case socketError(String)

    public var description: String {
        switch self {
        case .bindFailed(let detail):
            return "diagnostics server bind failed: \(detail)"
        case .socketError(let detail):
            return "diagnostics server socket error: \(detail)"
        }
    }
}

public enum LogTailError: Error {
    case notFound
    case ioError(String)
}

/// Read at most the last `maxBytes` bytes of `path`.
public func tailFile(path: String, maxBytes: UInt64) throws -> [UInt8] {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else {
        if errno == ENOENT {
            throw LogTailError.notFound
        }
        throw LogTailError.ioError(String(cString: strerror(errno)))
    }
    defer { close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0 else {
        throw LogTailError.ioError(String(cString: strerror(errno)))
    }
    let fileSize = UInt64(max(0, st.st_size))
    let offset = fileSize > maxBytes ? (fileSize - maxBytes) : 0
    guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else {
        throw LogTailError.ioError(String(cString: strerror(errno)))
    }

    var result: [UInt8] = []
    let toRead = Int(min(maxBytes, fileSize - offset))
    result.reserveCapacity(toRead)

    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var totalRead: UInt64 = 0
    while totalRead < maxBytes {
        let chunkLimit = Int(min(UInt64(buffer.count), maxBytes - totalRead))
        let bytesRead = read(fd, &buffer, chunkLimit)
        if bytesRead <= 0 {
            break
        }
        result.append(contentsOf: buffer[0..<bytesRead])
        totalRead += UInt64(bytesRead)
    }
    return result
}

/// A successfully bound diagnostics server.
public final class BoundDiag: @unchecked Sendable {
    /// Human-readable bound address for the startup log line.
    public let addr: String
    /// Bound TCP port (`nil` for Unix sockets).
    public let port: UInt16?
    /// The serve task; held by the production launcher for the process lifetime.
    public let task: Task<Void, Never>
    private let serverFd: Int32
    private let stateLock = NSLock()
    private var isStopped = false

    public init(
        addr: String,
        port: UInt16?,
        serverFd: Int32,
        task: Task<Void, Never>
    ) {
        self.addr = addr
        self.port = port
        self.serverFd = serverFd
        self.task = task
    }

    public func stop() {
        stateLock.lock()
        guard !isStopped else {
            stateLock.unlock()
            return
        }
        isStopped = true
        stateLock.unlock()

        task.cancel()
        close(serverFd)
    }
}

private struct DiagContext: Sendable {
    let handle: DiagHandle
    let logFile: String?
}

/// Bind the listener and spawn the server task. Binding happens before this
/// returns, so a bind failure surfaces synchronously. `logFile` is the
/// daemon log served by `/logs` (`nil` => `/logs` is 404).
public func serve(
    listener: DiagListener,
    handle: DiagHandle,
    logFile: String? = nil
) async throws -> BoundDiag {
    let ctx = DiagContext(handle: handle, logFile: logFile)
    switch listener {
    case .unix(let path):
        #if !os(Windows)
        unlink(path)
        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            let err = String(cString: strerror(errno))
            throw DiagServerError.bindFailed("bind \(path): \(err)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = path.utf8.count
        guard pathLen < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(serverFd)
            throw DiagServerError.bindFailed("bind \(path): socket path too long")
        }
        _ = path.withCString {
            strncpy(&addr.sun_path.0, $0, MemoryLayout.size(ofValue: addr.sun_path))
        }

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else {
            let err = String(cString: strerror(errno))
            close(serverFd)
            throw DiagServerError.bindFailed("bind \(path): \(err)")
        }

        chmod(path, S_IRUSR | S_IWUSR)

        guard listen(serverFd, 128) == 0 else {
            let err = String(cString: strerror(errno))
            close(serverFd)
            throw DiagServerError.bindFailed("bind \(path): \(err)")
        }

        let fdToRun = serverFd
        let task = Task.detached(priority: .userInitiated) { [ctx] in
            await runAcceptLoop(serverFd: fdToRun, ctx: ctx)
        }
        return BoundDiag(
            addr: "unix:\(path)",
            port: nil,
            serverFd: serverFd,
            task: task
        )
        #else
        throw DiagServerError.bindFailed("Unix sockets are not supported on Windows")
        #endif

    case .tcp(let port):
        let serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            let err = String(cString: strerror(errno))
            throw DiagServerError.bindFailed("bind 127.0.0.1:\(port): \(err)")
        }

        var reuse: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        var nosigpipe: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let err = String(cString: strerror(errno))
            close(serverFd)
            throw DiagServerError.bindFailed("bind 127.0.0.1:\(port): \(err)")
        }

        guard listen(serverFd, 128) == 0 else {
            let err = String(cString: strerror(errno))
            close(serverFd)
            throw DiagServerError.bindFailed("bind 127.0.0.1:\(port): \(err)")
        }

        var boundAddr = sockaddr_in()
        var boundAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverFd, $0, &boundAddrLen)
            }
        }
        let boundPort = UInt16(bigEndian: boundAddr.sin_port)

        let fdToRun = serverFd
        let task = Task.detached(priority: .userInitiated) { [ctx] in
            await runAcceptLoop(serverFd: fdToRun, ctx: ctx)
        }
        return BoundDiag(
            addr: "http://127.0.0.1:\(boundPort)",
            port: boundPort,
            serverFd: serverFd,
            task: task
        )
    }
}

private func runAcceptLoop(serverFd: Int32, ctx: DiagContext) async {
    while !Task.isCancelled {
        var clientAddr = sockaddr_storage()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverFd, $0, &clientAddrLen)
            }
        }
        guard clientFd >= 0 else {
            break
        }
        #if canImport(Darwin)
        var nosigpipe: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        Task.detached(priority: .userInitiated) { [ctx] in
            await handleConnection(clientFd: clientFd, ctx: ctx)
        }
    }
}

private func handleConnection(clientFd: Int32, ctx: DiagContext) async {
    defer {
        close(clientFd)
    }

    var accumulated = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let maxHeaderSize = 16384

    while accumulated.count < maxHeaderSize {
        let count = buffer.withUnsafeMutableBytes { raw in
            read(clientFd, raw.baseAddress, raw.count)
        }
        if count <= 0 {
            break
        }
        accumulated.append(contentsOf: buffer[0..<count])
        if hasCompleteHTTPHeader(accumulated) {
            break
        }
    }

    guard !accumulated.isEmpty, let requestString = String(bytes: accumulated, encoding: .utf8) else {
        let badRequest = formatResponse(
            statusCode: 400,
            statusText: "Bad Request",
            headers: [],
            body: Array("Bad Request".utf8)
        )
        _ = badRequest.withUnsafeBytes { raw in
            writeAll(fd: clientFd, buffer: raw.baseAddress, length: raw.count)
        }
        return
    }

    let response = processRequest(requestString: requestString, ctx: ctx)
    _ = response.withUnsafeBytes { raw in
        writeAll(fd: clientFd, buffer: raw.baseAddress, length: raw.count)
    }
}

private func writeAll(fd: Int32, buffer: UnsafeRawPointer?, length: Int) -> Bool {
    guard let buffer, length > 0 else { return true }
    var totalWritten = 0
    while totalWritten < length {
        let ptr = buffer.advanced(by: totalWritten)
        let count = write(fd, ptr, length - totalWritten)
        if count <= 0 {
            return false
        }
        totalWritten += count
    }
    return true
}

private func hasCompleteHTTPHeader(_ data: [UInt8]) -> Bool {
    guard data.count >= 4 else { return false }
    for i in 0...(data.count - 4) {
        if data[i] == 0x0D && data[i + 1] == 0x0A && data[i + 2] == 0x0D && data[i + 3] == 0x0A {
            return true
        }
    }
    for i in 0...(data.count - 2) {
        if data[i] == 0x0A && data[i + 1] == 0x0A {
            return true
        }
    }
    return false
}

private func processRequest(requestString: String, ctx: DiagContext) -> [UInt8] {
    guard let firstLine = requestString.split(whereSeparator: \.isNewline).first else {
        return formatResponse(
            statusCode: 400,
            statusText: "Bad Request",
            headers: [],
            body: Array("Bad Request".utf8)
        )
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2 else {
        return formatResponse(
            statusCode: 400,
            statusText: "Bad Request",
            headers: [],
            body: Array("Bad Request".utf8)
        )
    }
    let method = String(parts[0])
    let uri = String(parts[1])

    guard method == "GET" else {
        return formatResponse(
            statusCode: 404,
            statusText: "Not Found",
            headers: [],
            body: Array("Not Found".utf8)
        )
    }

    let pathAndQuery = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let path = String(pathAndQuery[0])
    let queryString = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : nil

    switch path {
    case "/ready":
        let ready = ctx.handle.readyBody()
        let encoder = JSONEncoder()
        let bodyData: [UInt8]
        do {
            bodyData = Array(try encoder.encode(ready))
        } catch {
            return formatResponse(
                statusCode: 500,
                statusText: "Internal Server Error",
                headers: [],
                body: Array("Failed to encode response".utf8)
            )
        }
        let statusCode = (ready.state == .connected) ? 200 : 503
        let statusText = (ready.state == .connected) ? "OK" : "Service Unavailable"
        return formatResponse(
            statusCode: statusCode,
            statusText: statusText,
            headers: [("Content-Type", "application/json")],
            body: bodyData
        )

    case "/statusz":
        let statusz = ctx.handle.statuszBody()
        let encoder = JSONEncoder()
        let bodyData: [UInt8]
        do {
            bodyData = Array(try encoder.encode(statusz))
        } catch {
            return formatResponse(
                statusCode: 500,
                statusText: "Internal Server Error",
                headers: [],
                body: Array("Failed to encode response".utf8)
            )
        }
        return formatResponse(
            statusCode: 200,
            statusText: "OK",
            headers: [("Content-Type", "application/json")],
            body: bodyData
        )

    case "/logs":
        guard let logPath = ctx.logFile else {
            return formatResponse(
                statusCode: 404,
                statusText: "Not Found",
                headers: [],
                body: Array("Not Found".utf8)
            )
        }
        var tailBytes = DEFAULT_LOG_TAIL_BYTES
        if let queryString {
            for param in queryString.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                if kv.count == 2 && kv[0] == "tail_bytes" {
                    if let parsed = UInt64(kv[1]) {
                        tailBytes = min(parsed, MAX_LOG_TAIL_BYTES)
                    }
                }
            }
        }
        do {
            let bytes = try tailFile(path: logPath, maxBytes: tailBytes)
            let lossyString = String(decoding: bytes, as: UTF8.self)
            return formatResponse(
                statusCode: 200,
                statusText: "OK",
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: Array(lossyString.utf8)
            )
        } catch LogTailError.notFound {
            return formatResponse(
                statusCode: 404,
                statusText: "Not Found",
                headers: [],
                body: Array("Not Found".utf8)
            )
        } catch {
            return formatResponse(
                statusCode: 500,
                statusText: "Internal Server Error",
                headers: [],
                body: Array("failed to read log".utf8)
            )
        }

    default:
        return formatResponse(
            statusCode: 404,
            statusText: "Not Found",
            headers: [],
            body: Array("Not Found".utf8)
        )
    }
}

private func formatResponse(
    statusCode: Int,
    statusText: String,
    headers: [(String, String)],
    body: [UInt8]
) -> [UInt8] {
    var headerString = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
    for (key, val) in headers {
        headerString += "\(key): \(val)\r\n"
    }
    headerString += "Content-Length: \(body.count)\r\n"
    headerString += "Connection: close\r\n"
    headerString += "\r\n"

    var responseData = Array(headerString.utf8)
    responseData.append(contentsOf: body)
    return responseData
}
