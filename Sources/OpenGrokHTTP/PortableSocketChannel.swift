import Foundation
import COpenGrokSockets

enum PortableSocketError: Error, Sendable, CustomStringConvertible {
    case operationFailed(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .operationFailed(let reason): return reason
        case .unsupported(let reason): return reason
        }
    }
}

final class PortableSocketChannel: WebSocketByteChannel, @unchecked Sendable {
    private let handle: Int64
    private let stateLock = NSLock()
    private var closed = false

    init(handle: Int64) {
        self.handle = handle
    }

    func read() async throws -> [UInt8]? {
        guard !isClosed else { return nil }
        let handle = self.handle
        return try await Task.detached(priority: .utility) {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int64 in
                og_socket_read(handle, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return nil }
            guard count > 0 else {
                throw PortableSocketError.operationFailed(PortableSocketSupport.lastError())
            }
            return Array(buffer.prefix(Int(count)))
        }.value
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw WebSocketChannelError.closed }
        guard !bytes.isEmpty else { return }
        let handle = self.handle
        try await Task.detached(priority: .utility) {
            let count = bytes.withUnsafeBytes { rawBuffer -> Int64 in
                og_socket_write_all(handle, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count == Int64(bytes.count) else {
                throw PortableSocketError.operationFailed(PortableSocketSupport.lastError())
            }
        }.value
    }

    func close() async {
        guard markClosed() else { return }
        _ = og_socket_close(handle)
    }

    private func markClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return false }
        closed = true
        return true
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }
}

final class PortableSocketListener: @unchecked Sendable {
    let handle: Int64
    let port: UInt16?
    private let stateLock = NSLock()
    private var closed = false

    private init(handle: Int64, port: UInt16?) {
        self.handle = handle
        self.port = port
    }

    static func tcp(host: String, port: UInt16) throws -> PortableSocketListener {
        var handle: Int64 = -1
        var boundPort: UInt16 = 0
        let result = host.withCString { hostPointer in
            og_socket_tcp_listen(hostPointer, port, &handle, &boundPort)
        }
        guard result == 0 else {
            throw PortableSocketError.operationFailed(PortableSocketSupport.lastError())
        }
        return PortableSocketListener(handle: handle, port: boundPort)
    }

    static func unix(path: String) throws -> PortableSocketListener {
        #if os(Windows)
        throw PortableSocketError.unsupported("Windows leader IPC requires named pipes")
        #else
        var handle: Int64 = -1
        let result = path.withCString { pathPointer in
            og_socket_unix_listen(pathPointer, &handle)
        }
        guard result == 0 else {
            throw PortableSocketError.operationFailed(PortableSocketSupport.lastError())
        }
        return PortableSocketListener(handle: handle, port: nil)
        #endif
    }

    func accept() async throws -> PortableSocketChannel {
        guard !isClosed else { throw PortableSocketError.operationFailed("socket listener is closed") }
        let listener = handle
        return try await Task.detached(priority: .utility) {
            var accepted: Int64 = -1
            guard og_socket_accept(listener, &accepted) == 0 else {
                throw PortableSocketError.operationFailed(PortableSocketSupport.lastError())
            }
            return PortableSocketChannel(handle: accepted)
        }.value
    }

    func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        _ = og_socket_close(handle)
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }
}

enum PortableSocketConnector {
    static func tcp(host: String, port: UInt16, timeoutSeconds: Double) async throws -> PortableSocketChannel {
        var handle: Int64 = -1
        let result = host.withCString { hostPointer in
            og_socket_tcp_connect(hostPointer, port, timeoutSeconds, &handle)
        }
        guard result == 0 else {
            throw PortableSocketError.operationFailed(PortableSocketSupport.lastError())
        }
        return PortableSocketChannel(handle: handle)
    }

    static func unix(path: String, timeoutSeconds: Double) async throws -> PortableSocketChannel {
        #if os(Windows)
        throw PortableSocketError.unsupported("Windows leader IPC requires named pipes")
        #else
        var handle: Int64 = -1
        let result = path.withCString { pathPointer in
            og_socket_unix_connect(pathPointer, timeoutSeconds, &handle)
        }
        guard result == 0 else {
            throw PortableSocketError.operationFailed(PortableSocketSupport.lastError())
        }
        return PortableSocketChannel(handle: handle)
        #endif
    }
}

private enum PortableSocketSupport {
    static func lastError() -> String {
        let message = String(cString: og_socket_last_error_message())
        return message.isEmpty ? "portable socket operation failed" : message
    }
}
