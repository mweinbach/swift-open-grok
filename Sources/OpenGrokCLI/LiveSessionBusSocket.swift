import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS) || os(Linux)

enum LiveSessionBusSocketSupport {
    static let maximumFrameBytes = 64 * 1024

    private static var streamSocketType: Int32 {
        #if os(Linux)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    static func secureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let metadata = try fileMetadata(at: url)
        guard fileType(metadata) == mode_t(S_IFDIR), metadata.st_uid == geteuid() else {
            throw LiveSessionBusTransportError.insecurePath(url.path)
        }
        if metadata.st_mode & 0o077 != 0 {
            guard url.path.withCString({ chmod($0, mode_t(0o700)) }) == 0 else {
                throw ioError("chmod session-bus directory")
            }
        }
        try validateDirectory(at: url)
    }

    static func validateDirectory(at url: URL) throws {
        let metadata = try fileMetadata(at: url)
        guard fileType(metadata) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw LiveSessionBusTransportError.insecurePath(url.path)
        }
    }

    static func validateSocket(at url: URL) throws {
        try validateDirectory(at: url.deletingLastPathComponent())
        let metadata = try fileMetadata(at: url)
        guard fileType(metadata) == mode_t(S_IFSOCK),
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw LiveSessionBusTransportError.insecurePath(url.path)
        }
    }

    static func removeStaleSocketIfNeeded(at url: URL) throws {
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        if result != 0 {
            guard errno == ENOENT else { throw ioError("inspect session-bus socket") }
            return
        }
        guard fileType(metadata) == mode_t(S_IFSOCK), metadata.st_uid == geteuid() else {
            throw LiveSessionBusTransportError.insecurePath(url.path)
        }

        let probe = try makeSocket()
        defer { close(probe) }
        var address = try makeAddress(path: url.path)
        var connected: Int32 = -1
        var failure: Int32 = 0
        for _ in 0..<3 {
            (connected, failure) = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    let result = connect(
                        probe,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                    return (result, result == 0 ? 0 : errno)
                }
            }
            if connected == 0 || failure != EINTR { break }
        }
        if connected == 0 {
            throw LiveSessionBusTransportError.addressInUse(url.path)
        }
        guard failure == ECONNREFUSED || failure == ENOENT || failure == ENOTCONN else {
            throw LiveSessionBusTransportError.connectionFailed(
                "cannot safely inspect existing socket: \(String(cString: strerror(failure)))"
            )
        }

        var current = stat()
        let currentResult = url.path.withCString { lstat($0, &current) }
        if currentResult != 0 {
            guard errno == ENOENT else { throw ioError("reinspect stale session-bus socket") }
            return
        }
        guard fileType(current) == mode_t(S_IFSOCK),
              current.st_uid == geteuid(),
              current.st_dev == metadata.st_dev,
              current.st_ino == metadata.st_ino
        else {
            throw LiveSessionBusTransportError.insecurePath(url.path)
        }
        guard url.path.withCString({ unlink($0) }) == 0 || errno == ENOENT else {
            throw ioError("remove stale session-bus socket")
        }
    }

    static func removeOwnedSocketIfPresent(at url: URL) {
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0,
              fileType(metadata) == mode_t(S_IFSOCK),
              metadata.st_uid == geteuid()
        else { return }
        _ = url.path.withCString { unlink($0) }
    }

    static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, streamSocketType, 0)
        guard descriptor >= 0 else { throw ioError("create session-bus socket") }
        let flags = fcntl(descriptor, F_GETFD)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
        }
        #if os(macOS)
        var enabled: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif
        return descriptor
    }

    static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.contains(0), bytes.count < capacity else {
            throw LiveSessionBusTransportError.socketPathTooLong(bytes.count)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.copyBytes(from: bytes)
        }
        return address
    }

    static func makeNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ioError("make session-bus socket nonblocking")
        }
    }

    static func verifyPeerOwner(_ descriptor: Int32) throws {
        #if os(macOS)
        var userID: uid_t = 0
        var groupID: gid_t = 0
        guard getpeereid(descriptor, &userID, &groupID) == 0 else {
            throw ioError("read session-bus peer credentials")
        }
        guard userID == geteuid() else {
            throw LiveSessionBusTransportError.peerNotOwner
        }
        #elseif os(Linux)
        struct PeerCredentials {
            var processID: pid_t = 0
            var userID: uid_t = 0
            var groupID: gid_t = 0
        }
        var credentials = PeerCredentials()
        var length = socklen_t(MemoryLayout<PeerCredentials>.size)
        let result = withUnsafeMutablePointer(to: &credentials) { pointer in
            getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, pointer, &length)
        }
        guard result == 0, length >= socklen_t(MemoryLayout<PeerCredentials>.size) else {
            throw ioError("read session-bus peer credentials")
        }
        guard credentials.userID == geteuid() else {
            throw LiveSessionBusTransportError.peerNotOwner
        }
        #endif
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
        let (deadline, deadlineOverflow) = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(interval)
        guard !deadlineOverflow, interval > 0 else {
            throw LiveSessionBusTransportError.timedOut
        }
        return deadline
    }

    static func ioError(_ operation: String) -> LiveSessionBusTransportError {
        let failure = errno
        return .connectionFailed("\(operation): \(String(cString: strerror(failure)))")
    }

    private static func fileMetadata(at url: URL) throws -> stat {
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0 else {
            throw ioError("inspect \(url.path)")
        }
        return metadata
    }

    private static func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(S_IFMT)
    }
}

final class LiveSessionBusSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var closed = false

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        do {
            try LiveSessionBusSocketSupport.makeNonBlocking(descriptor)
            try LiveSessionBusSocketSupport.verifyPeerOwner(descriptor)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    static func connect(to url: URL, deadline: UInt64) throws -> LiveSessionBusSocketConnection {
        try LiveSessionBusSocketSupport.validateSocket(at: url)
        let descriptor = try LiveSessionBusSocketSupport.makeSocket()
        var succeeded = false
        defer {
            if !succeeded {
                #if os(macOS)
                _ = Darwin.close(descriptor)
                #elseif os(Linux)
                _ = Glibc.close(descriptor)
                #endif
            }
        }
        try LiveSessionBusSocketSupport.makeNonBlocking(descriptor)
        var address = try LiveSessionBusSocketSupport.makeAddress(path: url.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Foundation.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else {
                throw LiveSessionBusSocketSupport.ioError("connect session-bus socket")
            }
            try wait(descriptor: descriptor, events: Int16(POLLOUT), until: deadline)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                throw LiveSessionBusSocketSupport.ioError("inspect session-bus connection")
            }
            guard socketError == 0 else {
                throw LiveSessionBusTransportError.connectionFailed(
                    "connect session-bus socket: \(String(cString: strerror(socketError)))"
                )
            }
        }
        succeeded = true
        // The initializer owns (and closes) the descriptor even when peer
        // credential validation fails; disarm our defer before transferring it.
        return try LiveSessionBusSocketConnection(descriptor: descriptor)
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        _ = shutdown(descriptor, Int32(SHUT_RDWR))
        #if os(macOS)
        _ = Darwin.close(descriptor)
        #elseif os(Linux)
        _ = Glibc.close(descriptor)
        #endif
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func readFrame(deadline: UInt64) async throws -> Data {
        try await performIO { [self] in
            var result = Data()
            result.reserveCapacity(256)
            var chunk = [UInt8](repeating: 0, count: 4096)

            while true {
                try Self.wait(
                    descriptor: descriptor,
                    events: Int16(POLLIN),
                    until: deadline,
                    isClosed: { [self] in isClosed }
                )
                let count = chunk.withUnsafeMutableBytes { bytes in
                    read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count == 0 {
                    guard !result.isEmpty else {
                        throw LiveSessionBusTransportError.connectionClosed
                    }
                    try LiveSessionBusSocketSupport.validateFrame(result)
                    return result
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw LiveSessionBusSocketSupport.ioError("read session-bus frame")
                }

                let bytes = chunk.prefix(count)
                if let newline = bytes.firstIndex(of: 0x0a) {
                    guard result.count + newline <= LiveSessionBusSocketSupport.maximumFrameBytes else {
                        throw LiveSessionBusTransportError.frameTooLarge(result.count + newline)
                    }
                    result.append(contentsOf: bytes.prefix(newline))
                    try LiveSessionBusSocketSupport.validateFrame(result)
                    return result
                }
                guard result.count + count <= LiveSessionBusSocketSupport.maximumFrameBytes else {
                    throw LiveSessionBusTransportError.frameTooLarge(result.count + count)
                }
                result.append(contentsOf: bytes)
            }
        }
    }

    func writeFrame(_ payload: Data, deadline: UInt64) async throws {
        try LiveSessionBusSocketSupport.validateFrame(payload)
        let framed: Data = {
            var value = payload
            value.append(0x0a)
            return value
        }()
        try await performIO { [self] in
            try framed.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    try Self.wait(
                        descriptor: descriptor,
                        events: Int16(POLLOUT),
                        until: deadline,
                        isClosed: { [self] in isClosed }
                    )
                    #if os(Linux)
                    let written = Glibc.send(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset,
                        Int32(MSG_NOSIGNAL)
                    )
                    #else
                    let written = Darwin.send(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset,
                        0
                    )
                    #endif
                    if written < 0 {
                        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                        throw LiveSessionBusSocketSupport.ioError("write session-bus frame")
                    }
                    guard written > 0 else {
                        throw LiveSessionBusTransportError.connectionClosed
                    }
                    offset += written
                }
            }
        }
    }

    private func performIO<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
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
    }

    private static func wait(
        descriptor: Int32,
        events: Int16,
        until deadline: UInt64,
        isClosed: (() -> Bool)? = nil
    ) throws {
        while true {
            if isClosed?() == true {
                throw LiveSessionBusTransportError.connectionClosed
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw LiveSessionBusTransportError.timedOut }
            let remaining = deadline - now
            let milliseconds = Int32(min(UInt64(50), max(1, (remaining + 999_999) / 1_000_000)))
            var entry = pollfd(
                fd: descriptor,
                events: events | Int16(POLLHUP | POLLERR | POLLNVAL),
                revents: 0
            )
            let ready = poll(&entry, 1, milliseconds)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw LiveSessionBusSocketSupport.ioError("poll session-bus socket")
            }
            if entry.revents & Int16(POLLNVAL) != 0 || isClosed?() == true {
                throw LiveSessionBusTransportError.connectionClosed
            }
            return
        }
    }
}

final class LiveSessionBusSocketListener: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private let socketURL: URL
    private var source: DispatchSourceRead?
    private var stopped = false

    init(socketURL: URL) throws {
        self.socketURL = socketURL
        descriptor = try LiveSessionBusSocketSupport.makeSocket()

        do {
            try LiveSessionBusSocketSupport.makeNonBlocking(descriptor)
            var address = try LiveSessionBusSocketSupport.makeAddress(path: socketURL.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw LiveSessionBusSocketSupport.ioError("bind session-bus socket")
            }
            guard socketURL.path.withCString({ chmod($0, mode_t(0o600)) }) == 0 else {
                throw LiveSessionBusSocketSupport.ioError("restrict session-bus socket permissions")
            }
            try LiveSessionBusSocketSupport.validateSocket(at: socketURL)
            guard listen(descriptor, 64) == 0 else {
                throw LiveSessionBusSocketSupport.ioError("listen on session-bus socket")
            }
        } catch {
            #if os(macOS)
            _ = Darwin.close(descriptor)
            #elseif os(Linux)
            _ = Glibc.close(descriptor)
            #endif
            LiveSessionBusSocketSupport.removeOwnedSocketIfPresent(at: socketURL)
            throw error
        }
    }

    deinit { stop() }

    func start(processID: Int32, accepting: @escaping @Sendable (LiveSessionBusSocketConnection) -> Void) {
        let queue = DispatchQueue(label: "open-grok.session-bus.accept.\(processID).\(UUID().uuidString)")
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailable(using: accepting)
        }
        source.setCancelHandler { [descriptor] in
            #if os(macOS)
            _ = Darwin.close(descriptor)
            #elseif os(Linux)
            _ = Glibc.close(descriptor)
            #endif
        }
        lock.lock()
        if stopped {
            lock.unlock()
            source.resume()
            source.cancel()
            return
        }
        self.source = source
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let source = self.source
        self.source = nil
        lock.unlock()

        _ = shutdown(descriptor, Int32(SHUT_RDWR))
        if let source {
            source.cancel()
        } else {
            #if os(macOS)
            _ = Darwin.close(descriptor)
            #elseif os(Linux)
            _ = Glibc.close(descriptor)
            #endif
        }
        LiveSessionBusSocketSupport.removeOwnedSocketIfPresent(at: socketURL)
    }

    private func acceptAvailable(using accepting: @Sendable (LiveSessionBusSocketConnection) -> Void) {
        while true {
            let accepted = accept(descriptor, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                return
            }
            do {
                accepting(try LiveSessionBusSocketConnection(descriptor: accepted))
            } catch {
                // Initializer closes rejected / foreign-owner connections.
            }
        }
    }
}

#endif
