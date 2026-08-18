// DiagServer.swift
//
// In-guest diagnostics HTTP server (/ready, /statusz, /logs) for the
// standalone workspace-server. Swift port of `xai-grok-diag-server`.

import Foundation
import COpenGrokSockets

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
    guard FileManager.default.fileExists(atPath: path) else {
        throw LogTailError.notFound
    }

    do {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let fileSize = try file.seekToEnd()
        let readSize = min(maxBytes, fileSize, UInt64(Int.max))
        try file.seek(toOffset: fileSize - readSize)
        return Array(try file.read(upToCount: Int(readSize)) ?? Data())
    } catch {
        if !FileManager.default.fileExists(atPath: path) {
            throw LogTailError.notFound
        }
        throw LogTailError.ioError(error.localizedDescription)
    }
}

/// A successfully bound diagnostics server.
public final class BoundDiag: @unchecked Sendable {
    /// Human-readable bound address for the startup log line.
    public let addr: String
    /// Bound TCP port (`nil` for Unix sockets).
    public let port: UInt16?
    /// The serve task; held by the production launcher for the process lifetime.
    public let task: Task<Void, Never>
    private let serverHandle: OGSocketHandle
    private let stateLock = NSLock()
    private var isStopped = false

    public init(
        addr: String,
        port: UInt16?,
        serverHandle: OGSocketHandle,
        task: Task<Void, Never>
    ) {
        self.addr = addr
        self.port = port
        self.serverHandle = serverHandle
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
        _ = og_socket_close(serverHandle)
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
        var serverHandle: OGSocketHandle = -1
        let listenResult = path.withCString { pathPointer in
            og_socket_unix_listen(pathPointer, &serverHandle)
        }
        guard listenResult == 0 else {
            throw DiagServerError.bindFailed("bind \(path): \(diagSocketErrorMessage())")
        }
        chmod(path, S_IRUSR | S_IWUSR)

        let listenerHandle = serverHandle
        let task = Task.detached(priority: .userInitiated) { [ctx] in
            await runAcceptLoop(serverHandle: listenerHandle, ctx: ctx)
        }
        return BoundDiag(
            addr: "unix:\(path)",
            port: nil,
            serverHandle: listenerHandle,
            task: task
        )
        #else
        throw DiagServerError.bindFailed("Unix sockets are not supported on Windows")
        #endif

    case .tcp(let port):
        var serverHandle: OGSocketHandle = -1
        var boundPort: UInt16 = 0
        let listenResult = "127.0.0.1".withCString { hostPointer in
            og_socket_tcp_listen(hostPointer, port, &serverHandle, &boundPort)
        }
        guard listenResult == 0 else {
            throw DiagServerError.bindFailed("bind 127.0.0.1:\(port): \(diagSocketErrorMessage())")
        }

        let listenerHandle = serverHandle
        let task = Task.detached(priority: .userInitiated) { [ctx] in
            await runAcceptLoop(serverHandle: listenerHandle, ctx: ctx)
        }
        return BoundDiag(
            addr: "http://127.0.0.1:\(boundPort)",
            port: boundPort,
            serverHandle: listenerHandle,
            task: task
        )
    }
}

private func runAcceptLoop(serverHandle: OGSocketHandle, ctx: DiagContext) async {
    while !Task.isCancelled {
        var clientHandle: OGSocketHandle = -1
        guard og_socket_accept(serverHandle, &clientHandle) == 0 else {
            break
        }

        Task.detached(priority: .userInitiated) { [ctx] in
            await handleConnection(clientHandle: clientHandle, ctx: ctx)
        }
    }
}

private func handleConnection(clientHandle: OGSocketHandle, ctx: DiagContext) async {
    defer {
        _ = og_socket_close(clientHandle)
    }

    var accumulated = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let maxHeaderSize = 16384

    while accumulated.count < maxHeaderSize {
        let count = buffer.withUnsafeMutableBytes { raw -> Int64 in
            og_socket_read(clientHandle, raw.baseAddress, raw.count)
        }
        if count <= 0 {
            break
        }
        accumulated.append(contentsOf: buffer.prefix(Int(count)))
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
            writeAll(handle: clientHandle, buffer: raw.baseAddress, length: raw.count)
        }
        return
    }

    let response = processRequest(requestString: requestString, ctx: ctx)
    _ = response.withUnsafeBytes { raw in
        writeAll(handle: clientHandle, buffer: raw.baseAddress, length: raw.count)
    }
}

private func writeAll(handle: OGSocketHandle, buffer: UnsafeRawPointer?, length: Int) -> Bool {
    guard let buffer, length > 0 else { return true }
    return og_socket_write_all(handle, buffer, length) == Int64(length)
}

private func diagSocketErrorMessage() -> String {
    let message = String(cString: og_socket_last_error_message())
    if !message.isEmpty {
        return message
    }
    return "native socket error \(og_socket_last_error_code())"
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
