#if os(Windows)
import COpenGrokSockets
import Dispatch
import Foundation
import OpenGrokFileUtils
import OpenGrokHTTP
import WinSDK

enum LiveSessionBusSocketSupport {
    static let maximumFrameBytes = 64 * 1024

    static func secureDirectory(at url: URL) throws {
        try LiveSessionBusPresenceStore.ensureSecureDirectory(url)
    }

    static func makeAddress(path: String) throws -> String {
        guard !path.utf8.contains(0), path.utf8.count <= 32_767 * 4 else {
            throw LiveSessionBusTransportError.socketPathTooLong(path.utf8.count)
        }
        try PathSecurity.rejectHostileLexical(path)
        return WindowsNamedPipeName.fullName(forPath: path, namespace: .sessionBus)
    }

    static func removeStaleSocketIfNeeded(at url: URL) throws {
        let attributes = url.path.withCString(encodedAs: UTF16.self) { pointer in
            GetFileAttributesW(pointer)
        }
        if attributes != DWORD(INVALID_FILE_ATTRIBUTES) {
            throw LiveSessionBusTransportError.insecurePath(url.path)
        }
        let failure = GetLastError()
        guard failure == DWORD(ERROR_FILE_NOT_FOUND)
            || failure == DWORD(ERROR_PATH_NOT_FOUND)
        else {
            throw LiveSessionBusTransportError.insecurePath(url.path)
        }
    }

    static func validateSocket(at url: URL) throws {
        try PathSecurity.rejectHostileLexical(url.path)
        let directory = url.deletingLastPathComponent()
        let secure = directory.path.withCString {
            og_path_is_private_to_current_user($0, 1)
        }
        guard secure == 1 else {
            throw LiveSessionBusTransportError.insecurePath(directory.path)
        }
        try removeStaleSocketIfNeeded(at: url)
    }

    static func validateFrame(_ payload: Data) throws {
        guard !payload.isEmpty else {
            throw LiveSessionBusTransportError.invalidFrame("session-bus frame is empty")
        }
        guard payload.count <= maximumFrameBytes else {
            throw LiveSessionBusTransportError.frameTooLarge(payload.count)
        }
        guard !payload.contains(0x0a) else {
            throw LiveSessionBusTransportError.invalidFrame("session-bus frame contains a newline")
        }
        guard String(data: payload, encoding: .utf8) != nil else {
            throw LiveSessionBusTransportError.invalidFrame("session-bus frame is not UTF-8")
        }
        do {
            let value = try JSONSerialization.jsonObject(with: payload)
            guard value is [String: Any] else {
                throw LiveSessionBusTransportError.invalidFrame("session-bus frame is not a JSON object")
            }
        } catch let error as LiveSessionBusTransportError {
            throw error
        } catch {
            throw LiveSessionBusTransportError.invalidFrame("session-bus frame is not valid JSON")
        }
    }

    static func deadline(after timeout: TimeInterval) throws -> UInt64 {
        let maximumSeconds = TimeInterval(UInt64.max / 1_000_000_000)
        guard timeout.isFinite, timeout > 0, timeout <= maximumSeconds else {
            throw LiveSessionBusTransportError.timedOut
        }
        let interval = UInt64((timeout * 1_000_000_000).rounded(.up))
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(interval)
        guard !overflow, interval > 0 else {
            throw LiveSessionBusTransportError.timedOut
        }
        return deadline
    }

    static func ioError(_ operation: String) -> LiveSessionBusTransportError {
        let code = Int(og_socket_last_error_code())
        let detail = String(cString: og_socket_last_error_message())
        if code == Int(ERROR_SEM_TIMEOUT) || code == Int(ERROR_TIMEOUT) {
            return .timedOut
        }
        return .connectionFailed(
            "\(operation): \(detail.isEmpty ? "Windows error \(code)" : detail)"
        )
    }
}

final class LiveSessionBusSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: OGSocketHandle
    private var closed = false

    init(handle: OGSocketHandle, serverSide: Bool) throws {
        self.handle = handle
        let verified = og_named_pipe_peer_is_current_user(handle, serverSide ? 1 : 0)
        guard verified == 1 else {
            close()
            if verified == 0 { throw LiveSessionBusTransportError.peerNotOwner }
            throw LiveSessionBusSocketSupport.ioError("verify session-bus named-pipe peer")
        }
    }

    deinit { close() }

    static func connect(to url: URL, deadline: UInt64) async throws -> LiveSessionBusSocketConnection {
        try Task.checkCancellation()
        try LiveSessionBusSocketSupport.validateSocket(at: url)
        let pipeName = try LiveSessionBusSocketSupport.makeAddress(path: url.path)
        let attempt = ConnectionAttempt()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        while true {
                            guard !attempt.isCancelled else { throw CancellationError() }
                            let now = DispatchTime.now().uptimeNanoseconds
                            guard now < deadline else { throw LiveSessionBusTransportError.timedOut }
                            let seconds = min(0.05, Double(deadline - now) / 1_000_000_000)
                            var accepted: OGSocketHandle = -1
                            let result = pipeName.withCString {
                                og_named_pipe_connect($0, seconds, &accepted)
                            }
                            if result == 0 {
                                guard attempt.register(accepted) else {
                                    throw CancellationError()
                                }
                                attempt.transferOwnership()
                                let connection = try LiveSessionBusSocketConnection(
                                    handle: accepted,
                                    serverSide: false
                                )
                                guard !attempt.isCancelled else {
                                    connection.close()
                                    throw CancellationError()
                                }
                                continuation.resume(returning: connection)
                                return
                            }
                            let code = Int(og_socket_last_error_code())
                            guard code == Int(ERROR_SEM_TIMEOUT)
                                || code == Int(ERROR_PIPE_BUSY)
                            else {
                                throw LiveSessionBusSocketSupport.ioError(
                                    "connect session-bus named pipe"
                                )
                            }
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            attempt.cancel()
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        _ = og_named_pipe_close(handle)
    }

    func readFrame(deadline: UInt64) async throws -> Data {
        try await performIO(deadline: deadline) { [self] in
            var result = Data()
            result.reserveCapacity(256)
            var chunk = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = chunk.withUnsafeMutableBytes {
                    og_named_pipe_read(handle, $0.baseAddress, $0.count)
                }
                if count == 0 {
                    guard !result.isEmpty else {
                        throw LiveSessionBusTransportError.connectionClosed
                    }
                    try LiveSessionBusSocketSupport.validateFrame(result)
                    return result
                }
                guard count > 0 else {
                    throw LiveSessionBusSocketSupport.ioError("read session-bus named-pipe frame")
                }
                let bytes = chunk.prefix(Int(count))
                if let newline = bytes.firstIndex(of: 0x0a) {
                    guard result.count + newline <= LiveSessionBusSocketSupport.maximumFrameBytes else {
                        throw LiveSessionBusTransportError.frameTooLarge(result.count + newline)
                    }
                    result.append(contentsOf: bytes.prefix(newline))
                    try LiveSessionBusSocketSupport.validateFrame(result)
                    return result
                }
                guard result.count + Int(count) <= LiveSessionBusSocketSupport.maximumFrameBytes else {
                    throw LiveSessionBusTransportError.frameTooLarge(result.count + Int(count))
                }
                result.append(contentsOf: bytes)
            }
        }
    }

    func writeFrame(_ payload: Data, deadline: UInt64) async throws {
        try LiveSessionBusSocketSupport.validateFrame(payload)
        let framed: Data = {
            var result = payload
            result.append(0x0a)
            return result
        }()
        try await performIO(deadline: deadline) { [self] in
            let written = framed.withUnsafeBytes {
                og_named_pipe_write_all(handle, $0.baseAddress, $0.count)
            }
            guard written == Int64(framed.count) else {
                throw LiveSessionBusSocketSupport.ioError("write session-bus named-pipe frame")
            }
        }
    }

    private func performIO<Value: Sendable>(
        deadline: UInt64,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw LiveSessionBusTransportError.timedOut }
        let timeout = Task { [self] in
            do {
                try await Task.sleep(nanoseconds: deadline - now)
                close()
            } catch {
            }
        }
        defer { timeout.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            continuation.resume(returning: try operation())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: { [self] in
                close()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                throw LiveSessionBusTransportError.timedOut
            }
            throw error
        }
    }

    private final class ConnectionAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var pending: OGSocketHandle = -1

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func register(_ handle: OGSocketHandle) -> Bool {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                _ = og_named_pipe_close(handle)
                return false
            }
            pending = handle
            lock.unlock()
            return true
        }

        func transferOwnership() {
            lock.lock()
            pending = -1
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let handle = pending
            pending = -1
            lock.unlock()
            if handle != -1 { _ = og_named_pipe_close(handle) }
        }
    }
}

final class LiveSessionBusSocketListener: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: OGSocketHandle
    private var task: Task<Void, Never>?
    private var stopped = false

    init(socketURL: URL) throws {
        let pipeName = try LiveSessionBusSocketSupport.makeAddress(path: socketURL.path)
        var listener: OGSocketHandle = -1
        let result = pipeName.withCString {
            og_named_pipe_secure_listener_create($0, &listener)
        }
        guard result == 0 else {
            if Int(og_socket_last_error_code()) == Int(ERROR_ACCESS_DENIED) {
                throw LiveSessionBusTransportError.addressInUse(socketURL.path)
            }
            throw LiveSessionBusSocketSupport.ioError("create secure session-bus named pipe")
        }
        handle = listener
    }

    deinit {
        stop()
        _ = og_named_pipe_listener_destroy(handle)
    }

    func start(
        processID: Int32,
        accepting: @escaping @Sendable (LiveSessionBusSocketConnection) -> Void
    ) {
        _ = processID
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let connection = try await self.accept()
                    accepting(connection)
                } catch {
                    if self.isStopped || Task.isCancelled { return }
                }
            }
        }
        lock.lock()
        if stopped {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
        _ = og_named_pipe_listener_close(handle)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func accept() async throws -> LiveSessionBusSocketConnection {
        let handle = self.handle
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var accepted: OGSocketHandle = -1
                guard og_named_pipe_listener_accept(handle, &accepted) == 0 else {
                    continuation.resume(throwing: LiveSessionBusSocketSupport.ioError(
                        "accept session-bus named-pipe peer"
                    ))
                    return
                }
                do {
                    continuation.resume(returning: try LiveSessionBusSocketConnection(
                        handle: accepted,
                        serverSide: true
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
