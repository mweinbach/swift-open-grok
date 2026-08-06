// UdsProxy.swift
//
// Port of `xai-grok-test-support/src/uds_proxy.rs`. A frame-aware fault-
// injection proxy for unix-domain-socket IPC. Sits between a client and a
// real listener (`proxy.sock` → `real.sock`), parsing the leader IPC framing
// (4-byte big-endian length prefix + body) so faults land on exact frame
// boundaries: drop exactly the Nth frame, sever after a half-written length
// prefix, delay or duplicate one frame. Everything is path-addressed, so no
// production changes are needed — point `LeaderClient::connect` /
// `GROK_LEADER_SOCKET` at the proxy path.
//
// Frame numbering is 1-based and per proxied connection, per direction;
// reconnects restart the count. Unix-only (the leader transport on Windows
// is a named pipe, which cannot be interposed this way).
//
// Sever semantics: `FaultHandle.severNow()` cancels the CURRENT sever scope
// and immediately installs a FRESH scope for later connections. Connections
// accepted AFTER the sever are unaffected — they bind to the fresh scope.
// This mirrors the Rust `CancellationToken` swap in `FaultState::sever_now`.
// The previous global-Boolean implementation got this wrong: once severed,
// every subsequent connection died instantly, contradicting the documented
// "only connections active at sever time die" behavior.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if os(macOS) || os(Linux)

/// Cross-platform `SOCK_STREAM`: Darwin spells it as a bare `Int32`, glibc as
/// a `__socket_type` enum whose `rawValue` is the `Int32` `socket(2)` wants.
private var sockStreamType: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

/// Which pump direction a `FaultPlan` applies to.
public enum FaultDirection: Sendable, Equatable {
    case clientToLeader
    case leaderToClient
}

/// Frame-indexed fault schedule (1-based, per connection, per direction).
/// The default plan is a transparent pass-through.
public struct FaultPlan: Sendable {
    public var direction: FaultDirection
    /// Silently drop the Nth frame (never forwarded).
    public var dropFrame: UInt64?
    /// On the Nth frame, forward only 2 bytes of its 4-byte length prefix,
    /// then hard-close both sides of the connection.
    public var severMidFrame: UInt64?
    /// Hold the Nth frame for the given duration before forwarding it.
    public var delay: (UInt64, TimeInterval)?
    /// Forward the Nth frame twice.
    public var duplicateFrame: UInt64?

    public init(
        direction: FaultDirection = .clientToLeader,
        dropFrame: UInt64? = nil,
        severMidFrame: UInt64? = nil,
        delay: (UInt64, TimeInterval)? = nil,
        duplicateFrame: UInt64? = nil
    ) {
        self.direction = direction
        self.dropFrame = dropFrame
        self.severMidFrame = severMidFrame
        self.delay = delay
        self.duplicateFrame = duplicateFrame
    }
}

/// A per-generation cancellation scope. The proxy keeps one current scope
/// at all times; `severNow()` cancels it and swaps in a fresh one so later
/// connections bind to the new (uncancelled) scope. Each accepted connection
/// captures the scope that was current at accept time, so a sever kills
/// exactly the connections that were active then and leaves later ones
/// untouched — mirroring the Rust `CancellationToken` swap in
/// `FaultState::sever_now`.
final class SeverScope: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Bool = false

    /// Returns a child snapshot of the current scope: a value type that
    /// reports `cancelled` as it was at capture time AND continues to
    /// report later cancels on the parent (because the closure reads the
    /// parent's lock-protected flag). Used to bind a connection's lifetime
    /// to "the scope that was current when this connection was accepted".
    func childToken() -> CancellationToken {
        return CancellationToken { [weak self] in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            return self?.cancelled ?? true
        }
    }

    /// Cancel this scope (connections bound to it die) and return `true` if
    /// this is the first cancel (so the caller knows to install a fresh
    /// scope for later connections).
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasCancelled = cancelled
        cancelled = true
        return !wasCancelled
    }
}

/// A token that reports cancellation status via a closure. `Sendable` via
/// `@unchecked` because the closure captures a thread-safe `SeverScope`.
public struct CancellationToken: @unchecked Sendable {
    let isCancelled: @Sendable () -> Bool

    init(_ isCancelled: @escaping @Sendable () -> Bool) {
        self.isCancelled = isCancelled
    }

    public var cancelled: Bool { isCancelled() }
}

/// Lock-protected fault state shared across connections. The sever scope is
/// per-generation: `severNow()` cancels the current scope and installs a
/// fresh one so later connections are unaffected.
final class FaultState: @unchecked Sendable {
    let severLock = NSLock()
    var severScope: SeverScope = SeverScope()
    let forwardedLock = NSLock()
    var forwardedC2L: UInt64 = 0
    var forwardedL2C: UInt64 = 0

    /// Capture the current sever scope. Called at accept time so each
    /// connection's lifetime is bound to "the scope that was current when
    /// this connection was accepted". Returns a token whose `cancelled`
    /// reflects later calls to `severNow()` against this scope.
    func connectionScope() -> CancellationToken {
        severLock.lock()
        defer { severLock.unlock() }
        return severScope.childToken()
    }

    /// Cancel the current scope (active connections die) and install a
    /// fresh scope for later connections. Idempotent on the same scope:
    /// subsequent calls hit the new scope and cancel THAT one.
    func severNow() {
        severLock.lock()
        let old = severScope
        severScope = SeverScope()
        severLock.unlock()
        _ = old.cancel()
    }

    func bumpForwarded(_ direction: FaultDirection) {
        forwardedLock.lock()
        defer { forwardedLock.unlock() }
        switch direction {
        case .clientToLeader: forwardedC2L &+= 1
        case .leaderToClient: forwardedL2C &+= 1
        }
    }

    func forwarded(_ direction: FaultDirection) -> UInt64 {
        forwardedLock.lock()
        defer { forwardedLock.unlock() }
        switch direction {
        case .clientToLeader: return forwardedC2L
        case .leaderToClient: return forwardedL2C
        }
    }
}

/// Runtime control over a running `UdsProxy`.
public final class FaultHandle: @unchecked Sendable {
    let state: FaultState
    /// File descriptors of currently active proxied connections, so
    /// `stop()` can close them in addition to stopping the accept loop.
    private let activeFdsLock = NSLock()
    private var activeFds: Set<Int32> = []
    init(state: FaultState) { self.state = state }

    /// Track an active connection's file descriptors so `stop()` can close
    /// them. Called by the accept loop when a connection starts.
    func trackActive(client: Int32, upstream: Int32) {
        activeFdsLock.lock()
        defer { activeFdsLock.unlock() }
        activeFds.insert(client)
        activeFds.insert(upstream)
    }

    /// Stop tracking a connection's file descriptors (called when the
    /// connection ends for any reason).
    func untrackActive(client: Int32, upstream: Int32) {
        activeFdsLock.lock()
        defer { activeFdsLock.unlock() }
        activeFds.remove(client)
        activeFds.remove(upstream)
    }

    /// Hard-close every active proxied connection immediately (mid-stream
    /// sever, independent of the frame-indexed plan). Later connections
    /// through the same proxy are unaffected: `severNow()` cancels the
    /// current scope and installs a fresh one for new connections.
    public func severNow() {
        state.severNow()
        // Close any active FDs to surface the sever promptly rather than
        // waiting for in-flight `read`/`write` syscalls to observe the
        // token. Pump threads will see EOF/error and exit on their own.
        activeFdsLock.lock()
        let fds = activeFds
        activeFdsLock.unlock()
        for fd in fds {
            // `shutdown` closes both directions and unblocks `read`/`write`
            // on the peer side; `close` would also work but `shutdown`
            // surfaces the sever faster (the pump's read returns 0).
            _ = shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    /// Frames fully forwarded so far in the given direction.
    public func forwarded(_ direction: FaultDirection) -> UInt64 {
        state.forwarded(direction)
    }
}

/// A running proxy: listener on `proxyPath`, forwarding to the upstream path
/// it was spawned with. Dropping the struct stops the listener and severs
/// active connections.
public final class UdsProxy: @unchecked Sendable {
    public let proxyPath: String
    public let handle: FaultHandle
    private let state: FaultState
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let lifecycleLock = NSLock()
    private var stopped = false

    /// Bind `proxyPath` and forward each accepted connection to
    /// `upstreamPath`, applying `plan` per connection.
    public init(proxyPath: String, upstreamPath: String, plan: FaultPlan) throws {
        self.proxyPath = proxyPath
        self.state = FaultState()
        self.handle = FaultHandle(state: state)
        // Remove any stale socket file.
        unlink(proxyPath)
        let fd = socket(AF_UNIX, sockStreamType, 0)
        if fd < 0 { throw UdsProxyError.bindFailed(proxyPath) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        proxyPath.withCString { cPath in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let count = min(strlen(cPath), buf.count - 1)
                // cPath is [CChar] (Int8); copyBytes requires UInt8.
                let bytes = UnsafeBufferPointer(start: cPath, count: count)
                    .map { UInt8(bitPattern: $0) }
                buf.copyBytes(from: bytes)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bound < 0 {
            close(fd)
            throw UdsProxyError.bindFailed(proxyPath)
        }
        if listen(fd, 128) < 0 {
            close(fd)
            throw UdsProxyError.bindFailed(proxyPath)
        }
        self.listenFD = fd
        let thread = Thread { [weak self] in
            self?.acceptLoop(upstreamPath: upstreamPath, plan: plan)
        }
        thread.start()
        acceptThread = thread
    }

    deinit { stop() }

    /// Stop accepting and sever active connections. Idempotent.
    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !stopped else { return }
        stopped = true
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(proxyPath)
        // Sever active connections so their pumps exit and FDs are closed.
        handle.severNow()
    }

    private func acceptLoop(upstreamPath: String, plan: FaultPlan) {
        while !stopped {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }
            let upstream = connectUnixSocket(path: upstreamPath)
            if upstream < 0 {
                close(client)
                continue
            }
            // Capture the CURRENT sever scope at accept time so this
            // connection's lifetime tracks "the scope that was current when
            // this connection was accepted". A later `severNow()` cancels
            // the OLD scope (this connection dies) and installs a fresh
            // scope for connections accepted AFTER the sever.
            let scope = state.connectionScope()
            handle.trackActive(client: client, upstream: upstream)
            let connState = state
            let connPlan = plan
            let connHandle = handle
            let thread = Thread {
                pumpConnection(
                    client: client, upstream: upstream,
                    plan: connPlan, state: connState,
                    handle: connHandle, scope: scope
                )
            }
            thread.start()
        }
    }
}

/// Pump one connection: two threads (client→upstream, upstream→client),
/// each applying the plan to its direction. Both threads share the same
/// per-connection `CancellationToken` so a `severNow()` (or a
/// `severMidFrame`) kills both pumps together.
private func pumpConnection(
    client: Int32,
    upstream: Int32,
    plan: FaultPlan,
    state: FaultState,
    handle: FaultHandle,
    scope: CancellationToken
) {
    let c2lPlan = plan.direction == .clientToLeader ? plan : nil
    let l2cPlan = plan.direction == .leaderToClient ? plan : nil
    // Use a semaphore to wait for both pumps to finish. The previous
    // `Thread.isExecuting` poll was racy: `isExecuting` is false before the
    // thread starts running, so the wait loop could exit immediately and
    // close the FDs before the pumps ever ran — causing the client to see
    // EOF (nil echo). The semaphore approach blocks until each pump
    // explicitly signals completion.
    let done = DispatchSemaphore(value: 0)
    let t1 = Thread {
        pumpFrames(reader: client, writer: upstream, plan: c2lPlan, direction: .clientToLeader, state: state, handle: handle, scope: scope)
        done.signal()
    }
    let t2 = Thread {
        pumpFrames(reader: upstream, writer: client, plan: l2cPlan, direction: .leaderToClient, state: state, handle: handle, scope: scope)
        done.signal()
    }
    t1.start()
    t2.start()
    // Wait for both pumps to finish (EOF/error/sever) before closing.
    done.wait()
    done.wait()
    handle.untrackActive(client: client, upstream: upstream)
    close(client)
    close(upstream)
}

/// Pump length-prefixed frames from `reader` to `writer`, applying `plan`
/// (when non-nil) to this direction. Ends on EOF, IO error, or sever (the
/// per-connection `CancellationToken` reflects `severNow()` against the
/// scope captured at accept time).
private func pumpFrames(
    reader: Int32,
    writer: Int32,
    plan: FaultPlan?,
    direction: FaultDirection,
    state: FaultState,
    handle: FaultHandle,
    scope: CancellationToken
) {
    var frameIndex: UInt64 = 0
    while true {
        // Check sever-now scope: returns true if `severNow()` was called
        // against this connection's scope (the one captured at accept time).
        if scope.cancelled { return }
        // Read 4-byte length prefix.
        var lenPrefix = [UInt8](repeating: 0, count: 4)
        guard readExact(fd: reader, buffer: &lenPrefix, count: 4) else { return }
        // Decode the 4-byte big-endian prefix EXACTLY ONCE. The previous
        // expression wrapped the already-decoded integer in
        // `UInt32(bigEndian:)`, which re-interpreted the native value as a
        // big-endian representation — on a little-endian host this swapped
        // the bytes a second time, turning `[0,0,0,3]` into 50,331,648
        // instead of 3, causing the proxy to block reading a nonexistent
        // body. The single-shift decode below produces the correct native
        // integer directly.
        let len = UInt32(lenPrefix[0]) << 24
            | UInt32(lenPrefix[1]) << 16
            | UInt32(lenPrefix[2]) << 8
            | UInt32(lenPrefix[3])
        let bodyLen = Int(len)
        // Reject oversized frame lengths before allocating (prevents a
        // hostile upstream from causing a multi-GB allocation).
        if bodyLen > 64 * 1024 * 1024 { return } // MAX_FRAME_SIZE exceeded.
        var body = [UInt8](repeating: 0, count: bodyLen)
        if bodyLen > 0 {
            guard readExact(fd: reader, buffer: &body, count: bodyLen) else { return }
        }
        // Re-check scope after the read: a sever during the read should
        // still drop this connection before forwarding.
        if scope.cancelled { return }
        frameIndex &+= 1
        if let plan {
            if plan.dropFrame == frameIndex { continue }
            if plan.severMidFrame == frameIndex {
                // Half a length prefix, then a hard close of BOTH socket
                // directions. The previous implementation wrote two prefix
                // bytes and returned from only this pump without cancelling
                // the shared connection or shutting down both sockets, so
                // the opposite pump could remain blocked on its read
                // forever. Now we trigger the shared sever scope (which
                // unblocks the opposite pump via `scope.cancelled`) AND
                // shutdown both FDs so any in-flight read/write returns
                // immediately.
                _ = write(writer, [lenPrefix[0], lenPrefix[1]], 2)
                // Cancel the shared connection scope so the opposite pump
                // exits its read loop.
                handle.severNow()
                return
            }
            if let (nth, duration) = plan.delay, nth == frameIndex {
                // Hold the frame, but bail out if a sever arrives mid-delay.
                let deadline = Date().addingTimeInterval(duration)
                while Date() < deadline {
                    if scope.cancelled { return }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            let copies = plan.duplicateFrame == frameIndex ? 2 : 1
            for _ in 0..<copies {
                guard writeFrame(writer: writer, lenPrefix: lenPrefix, body: body) else { return }
                state.bumpForwarded(direction)
            }
            continue
        }
        guard writeFrame(writer: writer, lenPrefix: lenPrefix, body: body) else { return }
        state.bumpForwarded(direction)
    }
}

/// Read exactly `count` bytes from `fd` into `buffer`. Returns false on EOF
/// or error.
private func readExact(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
    var read = 0
    while read < count {
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            let base = ptr.baseAddress!.advanced(by: read)
            return Foundation.read(fd, base, count - read)
        }
        if n <= 0 { return false }
        read += n
    }
    return true
}

/// Write a length-prefixed frame to `fd`. Returns false on error.
private func writeFrame(writer: Int32, lenPrefix: [UInt8], body: [UInt8]) -> Bool {
    var written = 0
    while written < 4 {
        let n = Foundation.write(writer, lenPrefix.withUnsafeBufferPointer { $0.baseAddress!.advanced(by: written) }, 4 - written)
        if n <= 0 { return false }
        written += n
    }
    if !body.isEmpty {
        written = 0
        while written < body.count {
            let n = body.withUnsafeBufferPointer { buf -> Int in
                Foundation.write(writer, buf.baseAddress!.advanced(by: written), body.count - written)
            }
            if n <= 0 { return false }
            written += n
        }
    }
    return true
}

/// Connect a unix-domain socket to `path`. Returns the fd or -1 on error.
private func connectUnixSocket(path: String) -> Int32 {
    let fd = socket(AF_UNIX, sockStreamType, 0)
    if fd < 0 { return -1 }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { cPath in
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let count = min(strlen(cPath), buf.count - 1)
            let bytes = UnsafeBufferPointer(start: cPath, count: count)
                .map { UInt8(bitPattern: $0) }
            buf.copyBytes(from: bytes)
        }
    }
    let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Foundation.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if connected < 0 {
        close(fd)
        return -1
    }
    return fd
}

/// Errors thrown by `UdsProxy`.
public enum UdsProxyError: Error, Equatable {
    case bindFailed(String)
}

#endif // os(macOS) || os(Linux)
