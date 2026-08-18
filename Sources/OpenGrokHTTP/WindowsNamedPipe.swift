import Foundation
import COpenGrokSockets

public enum WindowsNamedPipeName {
    public static func leafName(forPath path: String) -> String {
        let hash = SipHash13.hash(
            Array(path.utf8),
            key0: 0x6772_6f6b_6c65_6164,
            key1: 0x6572_5f70_6970_6521
        )
        return String(format: "grok-leader-%016llx", hash)
    }

    public static func fullName(forPath path: String) -> String {
        "\\\\.\\pipe\\\(leafName(forPath: path))"
    }
}

public enum WindowsNamedPipeError: Error, Sendable, Hashable, CustomStringConvertible {
    case operationFailed(code: Int, reason: String)
    case closed

    public var description: String {
        switch self {
        case .operationFailed(let code, let reason):
            return "Windows named-pipe operation failed (\(code)): \(reason)"
        case .closed:
            return "Windows named-pipe channel is closed"
        }
    }
}

#if os(Windows)
public final class WindowsNamedPipeChannel: WebSocketByteChannel, @unchecked Sendable {
    private let handle: OGSocketHandle
    private let stateLock = NSLock()
    private var closed = false

    init(handle: OGSocketHandle) {
        self.handle = handle
    }

    public func read() async throws -> [UInt8]? {
        guard !isClosed else { return nil }
        let handle = self.handle
        return try await Task.detached(priority: .utility) {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int64 in
                og_named_pipe_read(handle, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return nil }
            guard count > 0 else { throw Self.lastError() }
            return Array(buffer.prefix(Int(count)))
        }.value
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw WindowsNamedPipeError.closed }
        guard !bytes.isEmpty else { return }
        let handle = self.handle
        try await Task.detached(priority: .utility) {
            let count = bytes.withUnsafeBytes { rawBuffer -> Int64 in
                og_named_pipe_write_all(handle, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count == Int64(bytes.count) else { throw Self.lastError() }
        }.value
    }

    public func close() async {
        guard markClosed() else { return }
        _ = og_named_pipe_close(handle)
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

    private static func lastError() -> WindowsNamedPipeError {
        WindowsNamedPipeSupport.lastError()
    }
}

public final class WindowsNamedPipeListener: @unchecked Sendable {
    public let pipeName: String
    private let stateLock = NSLock()
    private var handle: OGSocketHandle = -1
    private var closed = false

    public init(pipeName: String) {
        self.pipeName = pipeName
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard handle == -1 else { return }
        var listener: OGSocketHandle = -1
        let result = pipeName.withCString { pointer in
            og_named_pipe_listener_create(pointer, &listener)
        }
        guard result == 0 else { throw WindowsNamedPipeSupport.lastError() }
        handle = listener
        closed = false
    }

    public func accept() async throws -> WindowsNamedPipeChannel {
        let listener = try activeHandle()
        return try await Task.detached(priority: .utility) {
            var accepted: OGSocketHandle = -1
            guard og_named_pipe_listener_accept(listener, &accepted) == 0 else {
                throw WindowsNamedPipeSupport.lastError()
            }
            return WindowsNamedPipeChannel(handle: accepted)
        }.value
    }

    public func close() {
        stateLock.lock()
        guard !closed, handle != -1 else {
            stateLock.unlock()
            return
        }
        closed = true
        let listener = handle
        stateLock.unlock()
        _ = og_named_pipe_listener_close(listener)
    }

    public func isReady() -> Bool {
        pipeName.withCString { og_named_pipe_is_ready($0) != 0 }
    }

    deinit {
        close()
        stateLock.lock()
        let listener = handle
        handle = -1
        stateLock.unlock()
        if listener != -1 { _ = og_named_pipe_listener_destroy(listener) }
    }

    private func activeHandle() throws -> OGSocketHandle {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, handle != -1 else { throw WindowsNamedPipeError.closed }
        return handle
    }
}

public enum WindowsNamedPipeDialer {
    public static func connect(
        pipeName: String,
        timeoutSeconds: Double = 10
    ) async throws -> WindowsNamedPipeChannel {
        try await Task.detached(priority: .utility) {
            var handle: OGSocketHandle = -1
            let result = pipeName.withCString { pointer in
                og_named_pipe_connect(pointer, timeoutSeconds, &handle)
            }
            guard result == 0 else { throw WindowsNamedPipeSupport.lastError() }
            return WindowsNamedPipeChannel(handle: handle)
        }.value
    }

    public static func isReady(pipeName: String) -> Bool {
        pipeName.withCString { og_named_pipe_is_ready($0) != 0 }
    }
}

public final class WindowsExclusiveFileLock: @unchecked Sendable {
    public let path: String
    private let stateLock = NSLock()
    private var handle: OGSocketHandle = -1

    public init(path: String) {
        self.path = path
    }

    public func acquire(contents: String) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard handle == -1 else { return }
        var acquired: OGSocketHandle = -1
        let result = path.withCString { pathPointer in
            contents.withCString { contentsPointer in
                og_file_lock_acquire(pathPointer, contentsPointer, &acquired)
            }
        }
        guard result == 0 else { throw WindowsNamedPipeSupport.lastError() }
        handle = acquired
    }

    public static func readContents(at path: String, maxBytes: Int = 64) -> String? {
        guard maxBytes > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: maxBytes)
        let count = path.withCString { pathPointer in
            bytes.withUnsafeMutableBytes { buffer in
                og_file_lock_read_contents(pathPointer, buffer.baseAddress, buffer.count)
            }
        }
        guard count >= 0 else { return nil }
        return String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
    }

    public func release() {
        stateLock.lock()
        let acquired = handle
        handle = -1
        stateLock.unlock()
        if acquired != -1 { _ = og_file_lock_release(acquired) }
    }

    deinit { release() }
}

private enum WindowsNamedPipeSupport {
    static func lastError() -> WindowsNamedPipeError {
        let code = Int(og_socket_last_error_code())
        let message = String(cString: og_socket_last_error_message())
        return .operationFailed(
            code: code,
            reason: message.isEmpty ? "native operation failed" : message
        )
    }
}
#endif

private enum SipHash13 {
    static func hash(_ bytes: [UInt8], key0: UInt64, key1: UInt64) -> UInt64 {
        var v0 = key0 ^ 0x736f_6d65_7073_6575
        var v1 = key1 ^ 0x646f_7261_6e64_6f6d
        var v2 = key0 ^ 0x6c79_6765_6e65_7261
        var v3 = key1 ^ 0x7465_6462_7974_6573

        var offset = 0
        while offset + 8 <= bytes.count {
            var message: UInt64 = 0
            for index in 0..<8 {
                message |= UInt64(bytes[offset + index]) << UInt64(index * 8)
            }
            v3 ^= message
            round(&v0, &v1, &v2, &v3)
            v0 ^= message
            offset += 8
        }

        var final = UInt64(bytes.count) << 56
        for index in offset..<bytes.count {
            final |= UInt64(bytes[index]) << UInt64((index - offset) * 8)
        }
        v3 ^= final
        round(&v0, &v1, &v2, &v3)
        v0 ^= final
        v2 ^= 0xff
        for _ in 0..<3 { round(&v0, &v1, &v2, &v3) }
        return v0 ^ v1 ^ v2 ^ v3
    }

    private static func round(
        _ v0: inout UInt64,
        _ v1: inout UInt64,
        _ v2: inout UInt64,
        _ v3: inout UInt64
    ) {
        v0 &+= v1
        v1 = rotateLeft(v1, by: 13)
        v1 ^= v0
        v0 = rotateLeft(v0, by: 32)
        v2 &+= v3
        v3 = rotateLeft(v3, by: 16)
        v3 ^= v2
        v0 &+= v3
        v3 = rotateLeft(v3, by: 21)
        v3 ^= v0
        v2 &+= v1
        v1 = rotateLeft(v1, by: 17)
        v1 ^= v2
        v2 = rotateLeft(v2, by: 32)
    }

    private static func rotateLeft(_ value: UInt64, by amount: UInt64) -> UInt64 {
        (value << amount) | (value >> (64 - amount))
    }
}
