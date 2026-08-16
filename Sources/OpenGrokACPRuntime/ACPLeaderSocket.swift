// ACPLeaderSocket.swift
//
// Where the leader listens, and the advisory lock that makes "one leader per
// endpoint" true rather than hopeful.
//
// Rust reference: `crates/codegen/xai-grok-shell/src/leader/lock.rs` — socket
// and lock path derivation (:12-113), `flock` acquisition (:191-240), and the
// `Drop` cleanup that must not delete a live successor's socket (:275-316).

import Foundation
import OpenGrokHTTP

// MARK: - Paths

public enum ACPLeaderSocketPaths {
    /// `lock.rs:44` — `LEADER_SOCKET_ENV`. When set it bypasses the WS-URL
    /// suffix entirely, because the operator has named an exact socket.
    public static let socketEnvironmentVariable = "GROK_LEADER_SOCKET"

    /// The suffix that separates leaders talking to different relays.
    ///
    /// `lock.rs:13-33` returns `""` for the empty string or the production
    /// relay URL, and `-{hash:08x}` otherwise, so a leader pointed at a staging
    /// relay never adopts the production leader's socket.
    ///
    /// **Divergence:** upstream hashes with Rust's `DefaultHasher` (SipHash-1-3
    /// with unspecified keys); its output is explicitly not guaranteed stable
    /// across Rust releases and cannot be reproduced here. This uses FNV-1a.
    /// The suffix only has to be stable and collision-resistant *within one
    /// installation* — both the client and the leader deriving it are this same
    /// binary — so the value differs from Rust's while the behaviour does not.
    /// A Swift leader and a Rust leader pointed at the same non-production
    /// relay would not share a socket.
    public static func suffix(forRelayURL url: String?) -> String {
        guard let url, !url.isEmpty, url != ACPRelayConfiguration.productionURL else { return "" }
        var hash: UInt32 = 2_166_136_261
        for byte in Array(url.utf8) {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "-%08x", hash)
    }

    /// Socket and lock paths for a leader.
    ///
    /// The lock always sits beside the socket, including under the env
    /// override, so the two cannot end up describing different leaders.
    public static func resolve(
        openGrokHome: URL,
        relayURL: String?,
        environment: [String: String]
    ) -> (socket: URL, lock: URL) {
        resolve(
            openGrokHome: openGrokHome,
            relayURL: relayURL,
            environment: environment,
            socketOverride: environment[socketEnvironmentVariable]
        )
    }

    /// Resolve an endpoint while honoring an explicit CLI socket override.
    ///
    /// The command-line value must win over the environment so a client can
    /// attach to a deliberately selected leader without mutating its process
    /// environment. The daemon keeps using the environment-only overload.
    public static func resolve(
        openGrokHome: URL,
        relayURL: String?,
        environment: [String: String],
        socketOverride: String?
    ) -> (socket: URL, lock: URL) {
        if let override = socketOverride, !override.isEmpty {
            let socket = URL(fileURLWithPath: override)
            return (socket, socket.appendingPathExtension("lock"))
        }
        let suffix = suffix(forRelayURL: relayURL)
        return (
            openGrokHome.appendingPathComponent("leader\(suffix).sock"),
            openGrokHome.appendingPathComponent("leader\(suffix).lock")
        )
    }

    /// The `sockaddr_un.sun_path` limit — 104 on Darwin, 108 on Linux. A path
    /// over the limit is silently truncated by `bind(2)`, which produces a
    /// leader listening somewhere nobody looks for it, so it is checked.
    public static let maximumPathLength = 103
}

// MARK: - Lock

public enum ACPLeaderLockError: Error, Sendable, CustomStringConvertible {
    case held(byProcess: Int32?, path: String)
    case cannotOpen(path: String, reason: String)
    case unsupportedPlatform(path: String)

    public var description: String {
        switch self {
        case .held(let pid, let path):
            let owner = pid.map { "process \($0)" } ?? "another process"
            return "another leader is already running (\(owner)); lock held at \(path)"
        case .cannotOpen(let path, let reason):
            return "could not open the leader lock at \(path): \(reason)"
        case .unsupportedPlatform(let path):
            return "leader mode is unavailable on Windows: the leader lock at \(path) has no supported locking backend"
        }
    }
}

/// An advisory lock on the leader's lock file, holding this process's PID.
///
/// Advisory rather than a PID-file check because a PID file alone races: two
/// clients can both read "no leader" and both spawn one. `flock` makes the
/// decision atomic on Unix. Windows holds an exclusive file handle beside the
/// named pipe for the same lifetime and spawn-coordination guarantee.
public final class ACPLeaderLock: @unchecked Sendable {
    public let lockPath: URL
    public let socketPath: URL
    private var descriptor: Int32 = -1
    private var owned = false
    private let stateLock = NSLock()
    #if os(Windows)
    private var windowsLock: WindowsExclusiveFileLock?
    #endif

    public init(lockPath: URL, socketPath: URL) {
        self.lockPath = lockPath
        self.socketPath = socketPath
    }

    /// Take the lock, or report who holds it.
    public func acquire() throws {
#if os(Windows)
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lock = WindowsExclusiveFileLock(path: lockPath.path)
        do {
            try lock.acquire(contents: "\(ProcessInfo.processInfo.processIdentifier)")
        } catch let error as WindowsNamedPipeError {
            if case .operationFailed(let code, _) = error, code == 32 || code == 33 {
                throw ACPLeaderLockError.held(
                    byProcess: Self.readPID(at: lockPath),
                    path: lockPath.path
                )
            }
            throw ACPLeaderLockError.cannotOpen(
                path: lockPath.path,
                reason: error.description
            )
        }
        stateLock.lock()
        windowsLock = lock
        owned = true
        stateLock.unlock()
#else
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockPath.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw ACPLeaderLockError.cannotOpen(
                path: lockPath.path,
                reason: String(cString: strerror(errno))
            )
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holder = Self.readPID(at: lockPath)
            close(fd)
            throw ACPLeaderLockError.held(byProcess: holder, path: lockPath.path)
        }
        ftruncate(fd, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        fsync(fd)

        stateLock.lock()
        descriptor = fd
        owned = true
        stateLock.unlock()
#endif
    }

    /// The PID recorded in a lock file, if it is readable and parseable.
    public static func readPID(at path: URL) -> Int32? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Release the lock and remove both files.
    ///
    /// Only an owner cleans up. `lock.rs:275-316` clears the ownership flag
    /// *before* unlocking for the same reason: a leader that never held the
    /// lock must never delete a live leader's socket.
    public func release() {
        stateLock.lock()
        let fd = descriptor
        let wasOwner = owned
        descriptor = -1
        owned = false
        stateLock.unlock()

#if !os(Windows)
        guard wasOwner, fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        try? FileManager.default.removeItem(at: socketPath)
        try? FileManager.default.removeItem(at: lockPath)
#else
        guard wasOwner else { return }
        stateLock.lock()
        let lock = windowsLock
        windowsLock = nil
        stateLock.unlock()
        lock?.release()
        try? FileManager.default.removeItem(at: lockPath)
#endif
    }

    deinit { release() }
}

// MARK: - Listener

/// Accepts leader IPC clients on a Unix domain socket.
///
/// A thin binding of `UnixSocketListener` to the leader's paths: the socket
/// itself carries no leader semantics, so the accept loop lives in
/// `OpenGrokHTTP` and only the stale-file removal — which is safe solely
/// because `ACPLeaderLock` was taken first — belongs here.
public actor ACPLeaderSocketListener {
    public let path: URL
    #if os(Windows)
    public let pipeName: String
    private let listener: WindowsNamedPipeListener
    private var stream: AsyncStream<any WebSocketByteChannel>?
    private var continuation: AsyncStream<any WebSocketByteChannel>.Continuation?
    private var acceptTask: Task<Void, Never>?
    #else
    private let listener: UnixSocketListener
    #endif

    public init(path: URL) {
        self.path = path
        #if os(Windows)
        let pipeName = WindowsNamedPipeName.fullName(forPath: path.path)
        self.pipeName = pipeName
        self.listener = WindowsNamedPipeListener(pipeName: pipeName)
        #else
        self.listener = UnixSocketListener(path: path.path)
        #endif
    }

    /// Bind and begin accepting. Returns the stream of client channels.
    ///
    /// Removing a leftover socket file is safe here and only here: a crashed
    /// leader leaves its socket behind and `bind` would fail with EADDRINUSE
    /// even though nothing is listening. Holding the advisory lock is what
    /// proves no live leader owns it.
    @discardableResult
    public func start() async throws -> AsyncStream<any WebSocketByteChannel> {
        #if os(Windows)
        if let stream { return stream }
        try listener.start()
        let (stream, continuation) = AsyncStream<any WebSocketByteChannel>.makeStream()
        self.stream = stream
        self.continuation = continuation
        acceptTask = Task { [weak self, listener] in
            while !Task.isCancelled {
                do {
                    let channel = try await listener.accept()
                    await self?.yield(channel)
                } catch {
                    break
                }
            }
        }
        return stream
        #else
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: path)
        return try await listener.start()
        #endif
    }

    public func stop() async {
        #if os(Windows)
        let task = acceptTask
        acceptTask = nil
        task?.cancel()
        listener.close()
        await task?.value
        continuation?.finish()
        continuation = nil
        stream = nil
        #else
        await listener.stop()
        #endif
    }

    #if os(Windows)
    private func yield(_ channel: any WebSocketByteChannel) {
        guard let continuation else {
            Task { await channel.close() }
            return
        }
        continuation.yield(channel)
    }
    #endif
}

public enum ACPLeaderSocketDialer {
    public static func connect(
        path: URL,
        timeoutSeconds: Double = 10
    ) async throws -> any WebSocketByteChannel {
        #if os(Windows)
        return try await WindowsNamedPipeDialer.connect(
            pipeName: WindowsNamedPipeName.fullName(forPath: path.path),
            timeoutSeconds: timeoutSeconds
        )
        #else
        return try await UnixSocketDialer.connect(path: path.path)
        #endif
    }

    public static func isReady(path: URL) -> Bool {
        #if os(Windows)
        return WindowsNamedPipeDialer.isReady(
            pipeName: WindowsNamedPipeName.fullName(forPath: path.path)
        )
        #else
        return FileManager.default.fileExists(atPath: path.path)
        #endif
    }
}
